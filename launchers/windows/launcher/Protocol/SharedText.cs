// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;

namespace S2Arm.Launcher.Protocol;

public sealed class SharedText
{
    private readonly Dictionary<string, Dictionary<string, string>> texts = new(StringComparer.Ordinal);
    public SharedText(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.GetProperty("schema").GetInt32() != 1 ||
            root.GetProperty("contract").GetString() != "s2a.experience.v1")
            throw new FormatException("Unsupported shared experience contract.");
        if (root.TryGetProperty("launcher", out var launcher)) ReadLauncher(launcher);
        // 两端共用的表只在共享体验表一处（11-19 结构 9）：可确认停装码的续跑参数 = errors 各码的 accept（带 accept_ui 的由专门页面带，如选盘页，不进通用确认）；
        //   「建议更新」原因 → 文案键 = update_reasons
        if (root.TryGetProperty("update_reasons", out var reasons) && reasons.ValueKind == JsonValueKind.Object)
            foreach (var r in reasons.EnumerateObject())
                if (r.Name != "note" && r.Value.ValueKind == JsonValueKind.String) updateReasonKeys[r.Name] = r.Value.GetString()!;
        // 装机前清单按钮落点的动作表（11-19 落点契约 / 结构 9：唯一来源 install_landing.actions，Mac 读同一处）：动作名 → 按钮文案键
        if (root.TryGetProperty("install_landing", out var landing) && landing.TryGetProperty("actions", out var acts) && acts.ValueKind == JsonValueKind.Object)
            foreach (var a in acts.EnumerateObject())
                if (a.Value.ValueKind == JsonValueKind.String) installActionLabels[a.Name] = a.Value.GetString()!;
        foreach (var item in root.GetProperty("errors").GetProperty("items").EnumerateArray())
        {
            var code = item.GetProperty("code").GetString()!;
            if (item.TryGetProperty("accept", out var accept) && accept.ValueKind == JsonValueKind.String && !item.TryGetProperty("accept_ui", out _))
                confirmFlags[code] = accept.GetString()!;
            // 确认页上与「仍然继续」并列的另一条路（自签走查结构 7）：alternate = {action: install_landing.actions 里的动作, label: 按钮文案键}
            if (item.TryGetProperty("alternate", out var alt) && alt.ValueKind == JsonValueKind.Object &&
                alt.TryGetProperty("action", out var altAction) && altAction.ValueKind == JsonValueKind.String &&
                alt.TryGetProperty("label", out var altLabel) && altLabel.ValueKind == JsonValueKind.String)
                confirmAlternates[code] = (altAction.GetString()!, altLabel.GetString()!);
            Flatten(item.GetProperty("title"), "errors." + code + ".title");
            Flatten(item.GetProperty("detail"), "errors." + code + ".detail");
        }
    }

    private readonly Dictionary<string, string> installActionLabels = new(StringComparer.Ordinal);

    /// <summary>清单动作的按钮文案键（install_landing.actions）；表里没有 / 写 null（那一端自画）→ null，不画按钮</summary>
    public string? InstallActionLabel(string action) => installActionLabels.TryGetValue(action, out var key) ? key : null;

    /// <summary>指代「这一台」的共享文案用 {0} 占位设备类型（#1962，同作业层 errors.on_device、Mac BackendText.deviceKind）：
    /// "ipad" / "iPad" → iPad，"iphone" / "iPhone" → iPhone，认不出（空 / null）→「iPhone / iPad」</summary>
    public static string DeviceKind(string? kind) => kind?.ToLowerInvariant() switch { "ipad" => "iPad", "iphone" => "iPhone", _ => "iPhone / iPad" };

    /// <summary>错误码的标题 / 正文（errors.&lt;码&gt;.title / .detail）；指代这一台的句子里 {0} 填 kind（作业结果 deviceKind / 清单 DeviceKind），不知道填「iPhone / iPad」</summary>
    public string Error(string? code, string part, string language, string? kind = null) => Get("errors." + code + "." + part, language).Replace("{0}", DeviceKind(kind));

    /// <summary>规格里有没有这个键（没有时 Get 返回「[键]」原样，界面不该显示它）。</summary>
    public bool Has(string key) => texts.ContainsKey(key);

    /// 报错页统一的「故障报修」指引（11-13）：report.hint 里的 {button} 换成顶栏按钮名 report.button（Mac BackendText.reportHint 同一取法）
    public string ReportHint(string language) => Get("report.hint", language).Replace("{button}", Get("report.button", language));

    private readonly Dictionary<string, string> confirmFlags = new(StringComparer.Ordinal), updateReasonKeys = new(StringComparer.Ordinal);

    /// <summary>可确认停装码 → 玩家点「仍然继续」后重发带的参数（共享体验表 errors 的 accept；装机 / 更新 / 换游戏库共用一张）</summary>
    public IReadOnlyDictionary<string, string> ConfirmFlags => confirmFlags;

    private readonly Dictionary<string, (string Action, string Label)> confirmAlternates = new(StringComparer.Ordinal);

    /// <summary>确认页上与「仍然继续」并列的另一条路（共享体验表 errors 的 alternate，同 Mac BackendText.confirmAlternates）：
    /// 码 → (装机前清单动作名：点了走 RunInstallAction 同一个派发、不重发；按钮文案键)</summary>
    public IReadOnlyDictionary<string, (string Action, string Label)> ConfirmAlternates => confirmAlternates;

    /// <summary>「建议更新」原因的文案键（共享体验表 update_reasons）；不认识的原因 → null（不显示）</summary>
    public string? UpdateReasonKey(string reason) => updateReasonKeys.TryGetValue(reason, out var key) ? key : null;

    private readonly Dictionary<string, Dictionary<string, string>> overlays = new(StringComparer.Ordinal);

    /// <summary>一门语言的叠加文案（共享 l10n/<语言>.json 的 launcher 块，按 id）：11-14 加新语言，同 Mac BackendText.overlay。</summary>
    public void AddOverlay(string language, string json)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        using var doc = JsonDocument.Parse(json);
        if (doc.RootElement.TryGetProperty("launcher", out var launcher) && launcher.ValueKind == JsonValueKind.Object)
            foreach (var p in launcher.EnumerateObject())
                if (p.Value.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(p.Value.GetString())) map[p.Name] = p.Value.GetString()!;
        overlays[language] = map;
    }

    /// <summary>这门语言还没翻的回落：繁中回落简中，其余回落英文（同 Mac BackendText.fallback）。</summary>
    public static string Fallback(string language) => language == "zh-Hant" ? "zh-Hans" : "en";

    /// <summary>叠加文案 → 文案表里这门语言的列 → 回落语言 → 英文；键本身不存在才显示「[键]」。</summary>
    public string Get(string key, string language)
    {
        if (!texts.TryGetValue(key, out var value)) return $"[{key}]";
        if (overlays.TryGetValue(language, out var o) && o.TryGetValue(key, out var hit)) return hit;
        return value.TryGetValue(language, out var text) || value.TryGetValue(Fallback(language), out text) || value.TryGetValue("en", out text) ? text : $"[{key}]";
    }

    private void ReadLauncher(JsonElement launcher)
    {
        if (launcher.ValueKind != JsonValueKind.Object ||
            !launcher.TryGetProperty("items", out var items) || items.ValueKind != JsonValueKind.Array)
            throw new FormatException("Launcher resource items must be an array.");
        foreach (var item in items.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object || !item.TryGetProperty("id", out var id) ||
                id.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(id.GetString()))
                throw new FormatException("Launcher resource id is missing.");
            // 每列一种语言（zh-Hans / en 必有，以后加的 zh-Hant / ja …可以逐键补，缺的 Get 回落英文；11-14 i18n 打底）
            var values = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var column in item.EnumerateObject())
            {
                if (column.Name == "id" || column.Value.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(column.Value.GetString())) continue;
                values[column.Name] = column.Value.GetString()!;
            }
            if (!values.ContainsKey("zh-Hans") || !values.ContainsKey("en"))
                throw new FormatException("Launcher resource requires both language values.");
            if (!texts.TryAdd(id.GetString()!, values))
                throw new FormatException("Duplicate launcher resource id.");
        }
    }

    private void Flatten(JsonElement element, string prefix)
    {
        if (element.ValueKind != JsonValueKind.Object) return;
        if ((element.TryGetProperty("zh-Hans", out var chinese) && chinese.ValueKind == JsonValueKind.String) ||
            (element.TryGetProperty("en", out var english) && english.ValueKind == JsonValueKind.String))
        {
            var value = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var lang in new[] { "zh-Hans", "en" })
                if (element.TryGetProperty(lang, out var text) && text.ValueKind == JsonValueKind.String &&
                    !string.IsNullOrWhiteSpace(text.GetString())) value.Add(lang, text.GetString()!);
            texts.Add(prefix, value);
            return;
        }
        foreach (var property in element.EnumerateObject())
            Flatten(property.Value, prefix.Length == 0 ? property.Name : prefix + "." + property.Name);
    }
}
