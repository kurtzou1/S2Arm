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
        foreach (var item in root.GetProperty("errors").GetProperty("items").EnumerateArray())
        {
            var code = item.GetProperty("code").GetString()!;
            Flatten(item.GetProperty("title"), "errors." + code + ".title");
            Flatten(item.GetProperty("detail"), "errors." + code + ".detail");
        }
    }

    /// <summary>规格里有没有这个键（没有时 Get 返回「[键]」原样，界面不该显示它）。</summary>
    public bool Has(string key) => texts.ContainsKey(key);

    /// 报错页统一的「故障报修」指引（11-13）：report.hint 里的 {button} 换成顶栏按钮名 report.button（Mac BackendText.reportHint 同一取法）
    public string ReportHint(string language) => Get("report.hint", language).Replace("{button}", Get("report.button", language));

    public string Get(string key, string language) =>
        texts.TryGetValue(key, out var value) && value.TryGetValue(language, out var text) ? text : $"[{key}]";

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
            var values = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var language in new[] { "zh-Hans", "en" })
            {
                if (!item.TryGetProperty(language, out var value) || value.ValueKind != JsonValueKind.String ||
                    string.IsNullOrWhiteSpace(value.GetString()))
                    throw new FormatException("Launcher resource requires both language values.");
                values.Add(language, value.GetString()!);
            }
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
