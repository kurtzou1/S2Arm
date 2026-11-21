// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

/// <summary>
/// 0.6.0「建议更新」（通用壳开关后面，同 Mac S2ArmLauncherModel+UpdateHints）：每份游戏列表读一次作业 updateHints（只读 game.json），
/// 对不上的款封面右上出「建议更新」（点了选中这款），选中写原因 + 末行 +「更新这款」（作业 updateGame 只在电脑上重做这一款，ExportFlow.cs）。不点照旧能用；开关关着什么都不出。
/// </summary>
public sealed partial class EnvironmentWindow
{
    private Dictionary<string, string[]> updateHints = new(StringComparer.OrdinalIgnoreCase);
    private string? updateHintsFor;   // 已比过的游戏库号

    /// <summary>游戏库页渲染时：这个游戏库打开后还没比过就比一次（同 Mac 只在启动器打开时读）。之后只在出包 / 手机作业做完时再读
    /// （AfterArtifactJob），不跟着每次重读游戏库起：出包过程中会重读好几次，每次多起两个作业进程是浪费</summary>
    private void EnsureUpdateHints()
    {
        if (catalog is null || libraryId is null || updateHintsFor == libraryId) return;
        updateHintsFor = libraryId;
        _ = RefreshUpdateHintsAsync();
        _ = RefreshPhoneOverviewAsync();   // 总控台（PhoneConsole.cs）：只读设备记录，秒回；选中首位卡时再探 USB
    }

    /// <summary>出包 / 手机作业（出包、装机、删除、装回、更新 S2Arm）做完：game.json 的产物记录和设备记录才会变，
    /// 建议更新和总控台再读一次（开关关着不读）</summary>
    private void AfterArtifactJob()
    {
        if (phoneOverview is null) return;
        _ = RefreshUpdateHintsAsync();
        _ = RefreshPhoneOverviewAsync();
    }

    private async Task RefreshUpdateHintsAsync()
    {
        var hints = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("updateHints", ""), null, CancellationToken.None);
            if (job.Report.Succeeded && job.Report.Result.TryGetProperty("games", out var games) && games.ValueKind == System.Text.Json.JsonValueKind.Array)
                foreach (var g in games.EnumerateArray())
                {
                    if (!g.TryGetProperty("gameId", out var id) || id.GetString() is not { Length: > 0 } gid || !g.TryGetProperty("reasons", out var rs)
                        || rs.ValueKind != System.Text.Json.JsonValueKind.Array) continue;
                    var why = rs.EnumerateArray().Select(r => r.GetString() ?? "").Where(r => UpdateReasonKey(r) is not null).ToArray();
                    if (why.Length > 0) hints[gid] = why;
                }
        }
        // 读不到不弹框（附带的提示，不是玩家点的操作），但不吞：记日志，提示清空、界面照旧
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception) { Console.Error.WriteLine("S2Arm updateHints: " + error.Message); }
        updateHints = hints;
        Render();
    }

    /// <summary>原因 → 文案键：只认共享体验表 update_reasons（11-19 结构 9，Mac 读同一处；原先这里另写一份，缺 libGen / shaderMiss）</summary>
    private string? UpdateReasonKey(string reason) => text.UpdateReasonKey(reason);

    private string[] UpdateReasons(LibraryGame game) => updateHints.TryGetValue(game.Id, out var why) ? why : [];

    /// <summary>封面右上角「建议更新」小角标（同 Mac：收藏心旁边）。点了选中这款、滚回顶部看大卡上的「更新这款」（0.6.4：原先没有点击，列表缩略图上也不出）</summary>
    private Control WithUpdateHintBadge(LibraryGame game, Control cover, int size)
    {
        if (UpdateReasons(game).Length == 0) return cover;
        var small = size < 80;   // 列表缩略图（72）：角标缩小一号，照样出、照样能点
        var badge = new Border { Margin = new Thickness(small ? 3 : 6), Padding = small ? new Thickness(4, 1.5) : new Thickness(7, 3), CornerRadius = new CornerRadius(10),
            Background = Brush.Parse("#AD000000"), BorderBrush = Brush.Parse("#99FF9F0A"), BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Child = new TextBlock { Text = T("update.hint.badge"), FontSize = small ? 8.5 : 10.5, FontWeight = FontWeight.Bold, Foreground = Brush.Parse("#FF9F0A") } };
        Avalonia.Automation.AutomationProperties.SetAutomationId(badge, "card.updateHint");
        ToolTip.SetTip(badge, T("update.hint.button"));
        ClickToSelect(badge, game);
        return new Panel { Width = size, Height = size, Children = { cover, badge } };
    }
}
