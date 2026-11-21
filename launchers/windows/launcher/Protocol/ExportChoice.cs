// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;

namespace S2Arm.Launcher.Protocol;

/// <summary>
/// 游戏库「更新 / 导出」两件事的判定（0.6.4 改版，维护者 11-21 定稿；作业层契约：updateGame / layoutSet / phoneOverview / install）。
/// 只放规则，不碰界面：更新按钮三态、导出确认页每台设备一行（类型 + 名字 + 这款状态、能不能勾、行内提示）、开始后起哪几单 install。
/// </summary>
public static class ExportChoice
{
    /// <summary>详情区更新按钮：没做过 iPhone 版不出（导出时会先做好）；做过且全对上 = 灰色「无需更新」；有原因 = 主色「更新这款」</summary>
    public enum Update { Hidden, UpToDate, Suggested }

    public static Update UpdateState(bool iphoneReady, IReadOnlyCollection<string> reasons) =>
        !iphoneReady ? Update.Hidden : reasons.Count == 0 ? Update.UpToDate : Update.Suggested;

    /// <summary>签名方式（请求字段 sign）：Apple ID / 我的证书 / 自签（AltStore / SideStore 自己签）</summary>
    public const string AppleId = "appleId", DevCert = "devCert", SelfSign = "none";

    /// <summary>导出确认页的缺省签名：设置里当前的签名方式（installMode 的 signChoice；external → 自签）；选的是证书但没导入过证书 → Apple ID</summary>
    public static string DefaultSign(string signChoice, bool certImported) => signChoice switch
    {
        "external" or "none" => SelfSign,
        "devCert" when certImported => DevCert,
        _ => AppleId,
    };

    /// <summary>导出确认页的一行设备。Kind：作业回的类型（iPhone / iPad），读不到为 ""（界面写「设备」，不写死 iPhone）；
    /// GameKey：这款在这台的状态文案键；Checkable：能不能勾；NoteKey：行内提示（null = 不写）；ConsoleLink：提示后面紧跟「去 S2Arm 卡」
    /// （只在「这台还没装 S2Arm / 不是本版」时给；「先导入签名证书」是在手机上做的，去 S2Arm 卡帮不上，不给）</summary>
    public sealed record DeviceRow(string Device, string Kind, string Name, string GameKey, bool Checkable, string? NoteKey, bool ConsoleLink);

    /// <summary>这台手机上的这款状态：latest = 已是最新，suggested = 已装旧版这款，其余（notPushed / needsData / 找不到）= 没装过这款</summary>
    public static string GameKey(PhoneOverview.Phone p, string gameId) =>
        p.Games.FirstOrDefault(g => string.Equals(g.GameId, gameId, StringComparison.OrdinalIgnoreCase))?.State switch
        {
            PhoneOverview.GameState.Latest => "export.device.game.latest",
            PhoneOverview.GameState.Suggested => "export.device.game.old",
            _ => "export.device.game.none",
        };

    /// <summary>别的工具装的 S2Arm 导没导入签名证书：先读作业给这台的 certImported；没给再看候选里就是它那一个的 CertImported；都没有 = 不知道（null）</summary>
    public static bool? CertImported(PhoneOverview.Phone p) => p.CertImported ??
        ((p.Candidates ?? []).FirstOrDefault(c => string.Equals(c.BundleId, p.BundleId, StringComparison.OrdinalIgnoreCase)) is { } c ? c.CertImported : null);

    /// <summary>一台设备在导出确认页上怎么画（契约「③ 导到哪」的可勾规则，自上而下取第一条成立的）：
    /// 没连着 → 灰；自签 + 独立 App → 一律灰（只能导出到文件夹）；自签 → 别的工具装的 S2Arm 可勾（没导入证书写「先在手机上导入」），没装 / 启动器签的 → 灰并写原因；
    /// 已签名 → 都可勾，通用 S2Arm 出法下这台没装 / 不是本版写「先装 / 先更新」、给入口（开始后那台单独失败，不挡别的）</summary>
    public static DeviceRow Row(PhoneOverview.Phone p, string gameId, string sign, string layout)
    {
        var game = GameKey(p, gameId);
        DeviceRow R(bool checkable, string? note = null, bool link = false) => new(p.Device, p.Kind, p.Name, game, checkable, note, link);
        if (!p.Probed || p.Online is null) return R(false, "export.device.notConnected");
        // 自签 + 独立 App：独立 App 推到设备要在电脑上签（作业层 install.put_app），自签推不上去 → 一律置灰，只能导出到文件夹（两端同一规则）
        if (sign == SelfSign && layout == "standalone") return R(false, "export.device.selfSignStandalone");
        if (sign == SelfSign)
        {
            if (p.External) return CertImported(p) == false ? R(true, "export.device.importCert") : R(true);
            if (p.NeedsChoice) return R(true);   // 装着不止一个：开始后那台的结果页就地让玩家选用哪一个（install 失败码 phone_app_choice_required）
            return p.InstalledBy == "launcher" || p.Installed ? R(false, "export.device.launcherSigned") : R(false, "export.device.noShell.selfSign");
        }
        if (layout == "standalone" || p.External || p.NeedsChoice) return R(true);   // 独立 App 不需要 S2Arm；别的工具装的照旧走手机自己签那条路
        if (!p.Installed) return R(true, "export.device.noShell", link: true);
        if (!p.ShellCurrent) return R(true, "export.device.shellOld", link: true);
        return R(true);
    }

    /// <summary>开始后起哪几单 install（契约「开始后」2 / 3）：勾了设备 → 每台一单 {device, sign}（不带 mode、不带别的限制），按列表顺序逐台排队；
    /// 一台都没勾 → 一单 {mode: export, sign}（导出到文件夹）</summary>
    public static IReadOnlyList<Dictionary<string, object?>> InstallRequests(string sign, IReadOnlyList<string> devices) =>
        devices.Count == 0
            ? [new() { ["mode"] = "export", ["sign"] = sign }]
            : devices.Select(d => new Dictionary<string, object?> { ["device"] = d, ["sign"] = sign }).ToList();

    /// <summary>作业 installMode / layoutSet 结果的 standaloneHints：{appleId, devCert, none} → 选「独立 App」时按这次签名方式给的提示码
    /// （appleId → "appleId"；devCert → "wildcard" | "explicit" | null；none → "external"）。只留值是非空字符串的；旧作业层没有这个字段 = 空</summary>
    public static IReadOnlyDictionary<string, string> StandaloneHints(JsonElement result)
    {
        var hints = new Dictionary<string, string>(StringComparer.Ordinal);
        if (result.ValueKind == JsonValueKind.Object && result.TryGetProperty("standaloneHints", out var h) && h.ValueKind == JsonValueKind.Object)
            foreach (var p in h.EnumerateObject())
                if (p.Name is AppleId or DevCert or SelfSign && p.Value.ValueKind == JsonValueKind.String && p.Value.GetString() is { Length: > 0 } code)
                    hints[p.Name] = code;
        return hints;
    }

    /// <summary>导出确认页 ② 出法下面那一行：只在选了独立 App 时出，按 ① 当前的签名方式取提示码 → (文案键 install.layout.hint.&lt;码&gt;, 颜色)；
    /// 显式 App ID / 通配描述文件黄色，免费 Apple ID 与自签（AltStore / SideStore）橙色；没有提示 → null（玩家反馈「独立 App 装一个就覆盖前一款」：要在选的时候就说）</summary>
    public static (string Key, string Color)? StandaloneNote(IReadOnlyDictionary<string, string> hints, string sign, string layout) =>
        layout != "standalone" || !hints.TryGetValue(sign, out var code) ? null
        : ("install.layout.hint." + code, code is "explicit" or "wildcard" ? "#FFD60A" : "#FF9F0A");

    /// <summary>导出成功页（逐台结果、导出到文件夹）要不要写「之前用独立 App 装过的游戏，存档怎么搬」（export.done.standaloneSaveCarry）：
    /// 这次出法是独立 App、且至少一台 / 文件夹那一行成功了；不论签名方式；通用 S2Arm 不写</summary>
    public static bool ShowsStandaloneSaveCarry(string layout, IEnumerable<string> rowStates) =>
        layout == "standalone" && rowStates.Any(s => s == "succeeded");

    /// <summary>开始前要不要先在电脑上做好 iPhone 版：没做过；或导出到文件夹而包还不是能直接导出的新格式（单一 IMG）</summary>
    public static bool NeedsPack(bool iphoneReady, bool iphoneExportable, int devices) => !iphoneReady || (devices == 0 && !iphoneExportable);
}
