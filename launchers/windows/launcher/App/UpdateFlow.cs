// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

// 覆盖更新：v0.3.10 起下载、Ed25519 验签、静默运行安装程序替换、重启都交给 NetSparkle（维护者拍板换业界标准组件，不再自写换版）。
// 这里只管状态和按钮；有没有新版、更新说明、公告仍由 pack/jobs/updater.py inbox 给。出包等作业进行中不提示、不替换。
public sealed partial class EnvironmentWindow
{
    private string updateProgress = "";
    private NetSparkleUpdater.AppCastItem? updateReady;   // 下载并验签好的那一版（NetSparkle 条目）
    private string updateReadyPath = "";                    // 它下载到的安装程序
    private NetSparkleUpdater.SparkleUpdater? sparkle;
    private string updateFailure = "";   // 错误码
    private string updateFailureMessage = "";   // 后端给的那句（updater.py 每个失败都带 message）：文案表没有这个码时显示它（剃刀 W11）
    private static readonly Uri DownloadPage = new("https://jhaizhou-ops.github.io/S2Arm/");   // 自动更新失败时「打开下载页」，系统浏览器打开
    private static string InstallDir => Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);
    // The release version lives in version.txt (written by bundle_win.py); the assembly version is always 1.0.0.0.
    private static string AppVersion => UpdateClient.CurrentVersion(InstallDir) is { Length: > 0 } version ? version : "-";
    private string UpdatesFolder => Path.Combine(privateRoot, "updates");
    private bool UpdateBlocked => AnyJob;

    private Dictionary<string, object?> UpdateStatus => updateProgress.Length > 0
        ? new() { ["state"] = "working", ["detail"] = updateProgress }
        : updateReady is { } ready ? new() { ["state"] = "ready", ["detail"] = ready.Version, ["via"] = "netsparkle" }
        : updateFailure.Length > 0 ? new() { ["state"] = "failed", ["detail"] = updateFailure, ["reason"] = updateFailureMessage }
        : new() { ["state"] = "idle" };

    /// <summary>上一版换版留下的东西（旧自写更新器的 updates/ 下的标记）不再有人读：NetSparkle 的状态在它自己的配置文件里</summary>
    private void FinishPendingUpdate() { }

    // ── 打开时给玩家看什么（11-13 维护者定稿草图，判定在 pack/jobs/updater.py inbox，两端共用「永远只给最新一期」）：
    //    最多一个弹窗（这版更新了什么 / 有新版）、横幅（最新一条没看过的重要公告）、「消息」列表与未读数（只算最新那条公告）
    private JsonElement? updatePopup;   // {kind: update | afterUpdate, version, notes?}
    private JsonElement? availableUpdate;   // 有新版那一版 {version, notes?}：顶栏「有新版 vX」点开回到弹窗
    private JsonElement[] messages = [];
    private int unreadMessages;
    private bool messagesOpen;
    private string updateGate = "";   // 点「现在更新并重启」时有任务在跑：先拦下说明（草图④前置检查）

    private async Task LoadInboxAsync()
    {
        var current = UpdateClient.CurrentVersion(InstallDir);
        if (current.Length == 0 || EnvironmentProbe.BundleIncomplete(paths)) return;
        var result = await UpdateClient.RunAsync(paths, ["inbox", "--private-root", privateRoot, "--platform", "windows", "--current", current], null, TimeSpan.FromSeconds(30));
        if (result is not { ValueKind: JsonValueKind.Object } value || !value.TryGetProperty("messages", out var list) || list.ValueKind != JsonValueKind.Array) return;
        notice = value.TryGetProperty("banner", out var banner) && banner.ValueKind == JsonValueKind.Object ? banner : null;
        messages = list.EnumerateArray().ToArray();
        unreadMessages = value.TryGetProperty("unread", out var unread) && unread.ValueKind == JsonValueKind.Number ? unread.GetInt32() : 0;
        if (value.TryGetProperty("update", out var update) && update.ValueKind == JsonValueKind.Object && update.TryGetProperty("available", out var available) && available.ValueKind == JsonValueKind.True)
            availableUpdate = update;
        updatePopup = value.TryGetProperty("popup", out var popup) && popup.ValueKind == JsonValueKind.Object ? popup : null;
        Render();
        if (availableUpdate is not null) await DownloadUpdateAsync();   // 后台下好，不打断玩家
    }

    private void Seen(params string[] args) => _ = UpdateClient.RunAsync(paths, new[] { "inbox-seen", "--private-root", privateRoot }.Concat(args), null, TimeSpan.FromSeconds(20));

    /// <summary>关掉弹窗（以后再说 / 知道了 / Esc）：这一版不再弹</summary>
    private void CloseUpdatePopup()
    {
        updateGate = "";
        if (updatePopup is not { } popup) return;
        updatePopup = null;
        var version = popup.TryGetProperty("version", out var v) ? v.GetString() ?? "" : "";
        var after = popup.TryGetProperty("kind", out var k) && k.GetString() == "afterUpdate";
        if (version.Length > 0) Seen(after ? "--after" : "--update", version);
        Render();
    }

    private void ShowUpdatePopup()
    {
        if (availableUpdate is not { } update) return;
        var version = update.GetProperty("version").GetString() ?? "";
        var notes = update.TryGetProperty("notes", out var n) ? n.GetRawText() : "null";
        using var doc = JsonDocument.Parse($"{{\"kind\":\"update\",\"version\":{JsonSerializer.Serialize(version)},\"notes\":{notes}}}");
        updatePopup = doc.RootElement.Clone(); Render();
    }

    private void OpenMessages()
    {
        messagesOpen = true; unreadMessages = 0;
        var latest = messages.FirstOrDefault(m => m.TryGetProperty("kind", out var k) && k.GetString() == "notice");
        if (latest.ValueKind == JsonValueKind.Object && latest.GetProperty("id").GetString() is { Length: > 0 } id) Seen("--notice", id);
        Render();
    }

    private string NoteText(JsonElement item) =>
        (language == "en" && item.TryGetProperty("en", out var en) ? en.GetString() : null) ?? (item.TryGetProperty("zh-Hans", out var zh) ? zh.GetString() ?? "" : "");

    private static IEnumerable<JsonElement> Items(JsonElement owner, string key) =>
        owner.ValueKind == JsonValueKind.Object && owner.TryGetProperty(key, out var list) && list.ValueKind == JsonValueKind.Array ? list.EnumerateArray() : [];

    private static Uri ReleasePage(string version) => new("https://github.com/jhaizhou-ops/S2Arm/releases/tag/v" + version);

    private void AddBullets(StackPanel panel, IEnumerable<JsonElement> items, double size = 14)
    {
        foreach (var item in items)
            panel.Children.Add(new SelectableTextBlock { Text = "• " + NoteText(item), FontSize = size, Foreground = Ink, TextWrapping = TextWrapping.Wrap });
    }

    /// <summary>更新弹窗（整页，同添加游戏弹窗的做法）：① 有新版 + 这版说明；② 更新后第一次打开「已更新到 vX」+ 亮点</summary>
    private void RenderUpdatePopup(StackPanel body)
    {
        var popup = updatePopup!.Value;
        var version = popup.TryGetProperty("version", out var v) ? v.GetString() ?? "" : "";
        var notes = popup.TryGetProperty("notes", out var n) ? n : default;
        var after = popup.TryGetProperty("kind", out var k) && k.GetString() == "afterUpdate";
        var panel = new StackPanel { Spacing = 14, MaxWidth = 680, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center };
        if (after)
        {
            panel.Children.Add(Label("✓ " + T("update.after.title").Replace("{0}", version), 26));
            panel.Children.Add(Muted(T("update.after.lead"), 14));
            AddBullets(panel, Items(notes, "highlights"));
        }
        else
        {
            panel.Children.Add(Muted(T("update.popup.kicker"), 13));
            panel.Children.Add(Label("S2Arm v" + version, 28));
            panel.Children.Add(Muted(T("update.popup.meta"), 13));
            var sections = Items(notes, "sections").ToArray();
            if (sections.Length == 0) panel.Children.Add(Muted(T("update.popup.noNotes"), 14));
            foreach (var section in sections)
            {
                var title = Label(section.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "", 14); title.Foreground = Accent;
                panel.Children.Add(title);
                AddBullets(panel, Items(section, "items"));
            }
            if (updateProgress.Length > 0) panel.Children.Add(Muted(T("update.popup.downloading"), 12.5));
            if (updateGate.Length > 0)
            {
                var gate = new StackPanel { Spacing = 4 };
                gate.Children.Add(Label(T(updateGate), 14));
                gate.Children.Add(Muted(T(updateGate + ".body"), 13));
                var box = new Border { Child = gate, Padding = new Thickness(14), CornerRadius = new CornerRadius(12), Background = new SolidColorBrush(Color.Parse("#FFC857"), 0.14) };
                AutomationId(box, "update.gate");
                panel.Children.Add(box);
            }
        }
        var buttons = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 12, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right };
        buttons.Children.Add(Action("update.popup.fullLog", () => _ = OpenOfficialAsync(ReleasePage(version))));
        if (after) buttons.Children.Add(Action("update.after.ok", CloseUpdatePopup));
        else
        {
            buttons.Children.Add(Action("update.popup.later", CloseUpdatePopup));
            buttons.Children.Add(Action("update.popup.now", RestartToUpdate, updateReady is not null));
        }
        panel.Children.Add(buttons);
        body.Children.Add(Card(panel, 32));
    }

    /// <summary>「消息」页：公告（最新在前）+ 更新说明；旧的只在这里、不弹不算未读</summary>
    private void RenderMessages(StackPanel body)
    {
        var panel = new StackPanel { Spacing = 10, MaxWidth = 560, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center };
        panel.Children.Add(Label(T("messages.title"), 22));
        if (messages.Length == 0) panel.Children.Add(Muted(T("messages.empty"), 13));
        foreach (var m in messages)
        {
            var row = new StackPanel { Spacing = 6 };
            if (m.TryGetProperty("kind", out var kind) && kind.GetString() == "update")
            {
                var version = m.GetProperty("version").GetString() ?? "";
                var installed = m.TryGetProperty("installed", out var i) && i.ValueKind == JsonValueKind.True;
                row.Children.Add(Muted(T("messages.kind.update").Replace("{0}", version) + " · " + T(installed ? "messages.installed" : "messages.available"), 12));
                var notes = m.TryGetProperty("notes", out var n) ? n : default;
                var items = Items(notes, "highlights").ToArray();
                if (items.Length == 0) items = Items(notes, "sections").SelectMany(s => Items(s, "items")).ToArray();
                AddBullets(row, items.Take(3), 13.5);
                row.Children.Add(Action("update.popup.fullLog", () => _ = OpenOfficialAsync(ReleasePage(version))));
            }
            else
            {
                var important = m.TryGetProperty("level", out var level) && level.GetString() == "important";
                var unread = m.TryGetProperty("unread", out var u) && u.ValueKind == JsonValueKind.True;
                row.Children.Add(Muted((unread ? "● " : "") + T(important ? "messages.kind.important" : "messages.kind.notice"), 12));
                var texts = m.TryGetProperty("text", out var tx) ? tx : default;
                if (texts.ValueKind == JsonValueKind.Object && texts.TryGetProperty(language == "en" ? "en" : "zh-Hans", out var said))
                    row.Children.Add(new SelectableTextBlock { Text = said.GetString() ?? "", FontSize = 13.5, Foreground = Ink, TextWrapping = TextWrapping.Wrap });
                if (m.TryGetProperty("url", out var url) && Uri.TryCreate(url.GetString(), UriKind.Absolute, out var link))
                    row.Children.Add(Action("notice.details", () => _ = OpenOfficialAsync(link)));
            }
            panel.Children.Add(Card(row, 14));
        }
        panel.Children.Add(Action("update.after.ok", () => { messagesOpen = false; Render(); }));
        body.Children.Add(panel);
    }

    /// <summary>顶栏「消息」：未读只算最新那条公告</summary>
    private Button MessagesButton()
    {
        var button = new Button { Content = T("messages.button") + (unreadMessages > 0 ? $"  ● {unreadMessages}" : ""), Padding = new Thickness(14, 8),
            CornerRadius = new CornerRadius(8), Background = Brush.Parse("#29292D"), Foreground = Ink };
        AutomationId(button, "top.messages");
        button.Click += (_, _) => OpenMessages();
        return button;
    }

    /// <summary>NetSparkle：appcast（缺省 dl.s2arm.com/appcast/windows.xml；验收 / 联调用 S2A_UPDATE_FEED 指本机假 appcast）+ Ed25519 严格验签
    /// （appcast 本身与安装程序都要签名，公钥同 Mac 的 SUPublicEDKey，私钥只在发版机）。版本按 version.txt 比</summary>
    private NetSparkleUpdater.SparkleUpdater Sparkle()
    {
        if (sparkle is not null) return sparkle;
        var feed = Environment.GetEnvironmentVariable("S2A_UPDATE_FEED") is { Length: > 0 } f ? f : UpdateFeed;
        var updater = new NetSparkleUpdater.SparkleUpdater(feed, new NetSparkleUpdater.SignatureVerifiers.Ed25519Checker(NetSparkleUpdater.Enums.SecurityMode.Strict, UpdatePublicKey))
        {
            UIFactory = null,
            UserInteractionMode = NetSparkleUpdater.Enums.UserInteractionMode.DownloadNoInstall,
            Configuration = new NetSparkleUpdater.Configurations.JSONConfiguration(new VersionAccessor(AppVersion), Path.Combine(UpdatesFolder, "netsparkle.json")),
            RelaunchAfterUpdate = true,
            // 静默装进现在这个目录（便携版也原地更新，不另装一份）；数据不在程序目录里（私有目录、游戏库），装新版不碰
            CustomInstallerArguments = $"/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR=\"{InstallDir}\"",
            RelaunchAfterUpdateCommandSuffix = string.Join(" ", Environment.GetCommandLineArgs().Skip(1).Select(a => "\"" + a.Replace("\"", "") + "\"")),
            LogWriter = new UpdateLog(Path.Combine(privateRoot, "logs", "update.log")),
        };
        updater.CloseApplicationAsync += () => { Dispatcher.UIThread.Post(Close); return Task.CompletedTask; };
        updater.DownloadMadeProgress += (_, item, e) => Dispatcher.UIThread.Post(() =>
        { updateProgress = T("update.downloading").Replace("{0}", e.ProgressPercentage.ToString()); RefreshLive(); });
        updater.DownloadFinished += (item, path) => Dispatcher.UIThread.Post(() =>
        { updateProgress = ""; updateReady = item; updateReadyPath = path; Render(); });
        updater.DownloadHadError += (item, path, error) => Dispatcher.UIThread.Post(() => Fail("update_failed", error.Message));
        updater.InstallUpdateFailed += (reason, path) => { Dispatcher.UIThread.Post(() => Fail("update_failed", reason.ToString())); return true; };
        return sparkle = updater;
    }

    private const string UpdateFeed = "https://dl.s2arm.com/appcast/windows.xml";
    private const string UpdatePublicKey = "WoZkGLOTuLU2zl0gsPX+4sTKRsIN9ahBEfj0ulkqOqc=";

    private void Fail(string code, string why)
    {
        updateProgress = ""; updateReady = null; updateFailure = code; updateFailureMessage = why;
        UpdateLog.Write(Path.Combine(privateRoot, "logs", "update.log"), $"更新失败（{code}）：{why}");
        Render();
    }

    private async Task DownloadUpdateAsync()
    {
        if (updateProgress.Length > 0) return;
        updateFailure = ""; updateFailureMessage = ""; updateProgress = T("update.downloading").Replace("{0}", "0"); Render();
        SaveUpdateNotes();
        try
        {
            var info = await Sparkle().CheckForUpdatesQuietly(true);
            if (info.Status != NetSparkleUpdater.Enums.UpdateStatus.UpdateAvailable || info.Updates is not { Count: > 0 } updates)
            {
                updateProgress = "";
                if (info.Status == NetSparkleUpdater.Enums.UpdateStatus.UpdateNotAvailable) { Render(); return; }
                Fail("update_failed", $"查新版没成（{info.Status}）"); return;
            }
            await Sparkle().InitAndBeginDownload(updates[0]);   // 下载、验签完成走 DownloadFinished，失败走 DownloadHadError
        }
        catch (Exception error) { Fail("update_failed", error.Message); }
    }

    /// <summary>换上新版后第一次打开要弹「这版更新了什么」（updater.py inbox 读 updates/notes/&lt;版本&gt;.json）：说明随查到的新版记在本机</summary>
    private void SaveUpdateNotes()
    {
        if (availableUpdate is not { } update || !update.TryGetProperty("version", out var v) || !update.TryGetProperty("notes", out var notes)
            || notes.ValueKind != JsonValueKind.Object) return;
        try
        {
            var folder = Path.Combine(UpdatesFolder, "notes"); Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, v.GetString() + ".json"), notes.GetRawText());
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    private void RestartToUpdate()
    {
        // 草图④：有任务在跑先拦下说明，弹窗不关
        if (UpdateBlocked) { updateGate = "update.gate.busy"; if (updatePopup is null) ShowUpdatePopup(); Render(); return; }
        if (updateReady is not { } ready || sparkle is null) return;
        UpdateLog.Write(Path.Combine(privateRoot, "logs", "update.log"), $"玩家点了更新并重启：交给 NetSparkle 运行安装程序 {ready.Version}");
        _ = sparkle.InstallUpdate(ready, updateReadyPath);   // 写好等本程序退出再跑安装程序、装完拉起的脚本，再经 CloseApplicationAsync 关掉本程序
    }

    // ── 顶部公告条（v0.2.3，同 Mac LauncherView.noticeBar）：只放最新一条没看过的重要公告（inbox banner）；内容是数据（notice.json），代码里不写公告内容。
    //    × 关掉 = 看过它和更旧的，不再出现；取不到、起不来都不显示、不报错
    private JsonElement? notice;

    private void DismissNotice()
    {
        if (notice is not { } value) return;
        var id = value.GetProperty("id").GetString() ?? "";
        notice = null;   // 当场收起，再记下
        if (messages.FirstOrDefault().ValueKind == JsonValueKind.Object && messages[0].TryGetProperty("id", out var first) && first.GetString() == id) unreadMessages = 0;
        Render();
        Seen("--notice", id);
    }

    private void AddNoticeBar(StackPanel body)
    {
        if (notice is not { } value || !value.TryGetProperty("text", out var texts) || !texts.TryGetProperty(language == "en" ? "en" : "zh-Hans", out var textValue)) return;
        var amber = Color.Parse("#FFC73D");
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto,Auto"), ColumnSpacing = 10 };
        row.Children.Add(new TextBlock { Text = "⚠", FontSize = 15, Foreground = new SolidColorBrush(amber), VerticalAlignment = Avalonia.Layout.VerticalAlignment.Top });
        var message = new SelectableTextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 13, Foreground = Ink };
        message.Inlines!.Add(new Avalonia.Controls.Documents.Run(T("notice.label") + "  ") { FontWeight = FontWeight.Bold });
        message.Inlines.Add(new Avalonia.Controls.Documents.Run(textValue.GetString() ?? ""));
        Avalonia.Automation.AutomationProperties.SetAutomationId(message, "notice.text");
        Grid.SetColumn(message, 1); row.Children.Add(message);
        if (value.TryGetProperty("url", out var url) && Uri.TryCreate(url.GetString(), UriKind.Absolute, out var link))
        {
            var details = new Button { Content = T("notice.details"), Padding = new Thickness(10, 4), Background = Brushes.Transparent, Foreground = Ink,
                VerticalAlignment = Avalonia.Layout.VerticalAlignment.Top };
            Avalonia.Automation.AutomationProperties.SetAutomationId(details, "notice.details");
            details.Click += (_, _) => _ = OpenOfficialAsync(link);
            Grid.SetColumn(details, 2); row.Children.Add(details);
        }
        var close = new Button { Content = "✕", Padding = new Thickness(8, 4), Background = Brushes.Transparent, Foreground = Ink,
            VerticalAlignment = Avalonia.Layout.VerticalAlignment.Top };
        ToolTip.SetTip(close, T("notice.close"));
        Avalonia.Automation.AutomationProperties.SetName(close, T("notice.close"));
        Avalonia.Automation.AutomationProperties.SetAutomationId(close, "notice.close");
        close.Click += (_, _) => DismissNotice();
        Grid.SetColumn(close, 3); row.Children.Add(close);
        body.Children.Add(new Border { Child = row, Padding = new Thickness(16, 10), CornerRadius = new CornerRadius(10),
            Background = new SolidColorBrush(amber, 0.16), BorderBrush = new SolidColorBrush(amber, 0.45), BorderThickness = new Thickness(1) });
    }

    /// <summary>顶栏的自更新状态（下载中百分比 / 重启更新 / 失败原因）；没有可显示的返回 null。是顶栏的活格子，下载进度事件只刷新它。</summary>
    private Control? UpdateControls()
    {
        var bar = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 10, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
        if (updateProgress.Length > 0)
            bar.Children.Add(new TextBlock { Text = updateProgress, FontSize = 12, Foreground = Brush.Parse("#A8A6A1"), VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center });
        else if (updateReady is not null && availableUpdate is { } update)   // 草图：「以后再说」后顶栏留「有新版 vX」，点开回到弹窗；重启只在弹窗里点
        {
            var available = new Button { Content = T("update.top.available").Replace("{0}", update.GetProperty("version").GetString() ?? ""), Padding = new Thickness(14, 8),
                CornerRadius = new CornerRadius(8), Background = Accent, Foreground = Canvas };
            AutomationId(available, "top.update");
            available.Click += (_, _) => ShowUpdatePopup();
            bar.Children.Add(available);
        }
        else if (updateFailure.Length > 0)
        {
            // 失败原因直接写在按钮旁（人话 + 错误码），并给「打开下载页」：自动更新连不上 GitHub 时玩家能自己下（不再只藏在悬停提示里）
            bar.Children.Add(Action("update.retry", () => _ = DownloadUpdateAsync()));
            // 文案表有这个码就用表里的（中英都有）；没有（如 update_none）就用后端那句，不显示「[update.error.…]」原样键名（剃刀 W11）
            var reason = text.Has("update.error." + updateFailure) || updateFailureMessage.Length == 0 ? T("update.error." + updateFailure) : B(updateFailureMessage);
            var why = new TextBlock { Text = reason + " · " + T("update.code").Replace("{0}", updateFailure), FontSize = 12,
                Foreground = Brush.Parse("#A8A6A1"), MaxWidth = 360, TextWrapping = Avalonia.Media.TextWrapping.Wrap, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
            Avalonia.Automation.AutomationProperties.SetAutomationId(why, "update.failure");
            bar.Children.Add(why);
            bar.Children.Add(Action("update.download_page", () => _ = OpenOfficialAsync(DownloadPage)));
        }
        return bar.Children.Count > 0 ? bar : null;
    }
}
