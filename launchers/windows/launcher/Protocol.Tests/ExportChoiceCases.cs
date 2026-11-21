// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;
using S2Arm.Launcher.Protocol;

// 0.6.4「更新 / 导出」两件事（维护者 11-21 定稿 + 作业层契约）。期望全部按定稿 / 契约的文字手写，不跑被测实现推：
//   更新按钮：没做过 iPhone 版不出、做过且无原因灰色「无需更新」、有原因主色「更新这款」；
//   导出确认页设备行：自签三种（外部 S2Arm 导入了证书可勾 / 没导入可勾写「先导入」/ 没装或启动器签的置灰写原因），已签名都可勾，没连着置灰；
//   默认签名跟设置；开始后起的 install 单：勾了设备每台 {device, sign}、不带 mode，都不勾一单 {mode: export, sign}
internal static class ExportChoiceCases
{
    public static void Run(Action<bool, string> check)
    {
        // 更新三态
        check(ExportChoice.UpdateState(false, []) == ExportChoice.Update.Hidden, "update: never prepared for iPhone → no button");
        check(ExportChoice.UpdateState(false, ["shader"]) == ExportChoice.Update.Hidden, "update: no iPhone version, even with a stray reason → no button");
        check(ExportChoice.UpdateState(true, []) == ExportChoice.Update.UpToDate, "update: prepared and all fingerprints match → grey up to date");
        check(ExportChoice.UpdateState(true, ["rewriter", "hostAbi"]) == ExportChoice.Update.Suggested, "update: a reason → primary update button");

        // 缺省签名：设置里的签名方式；external → 自签；选了证书但没导入 → Apple ID
        check(ExportChoice.DefaultSign("appleId", true) == "appleId", "sign default: Apple ID");
        check(ExportChoice.DefaultSign("devCert", true) == "devCert", "sign default: imported certificate");
        check(ExportChoice.DefaultSign("devCert", false) == "appleId", "sign default: certificate chosen but none imported → Apple ID");
        check(ExportChoice.DefaultSign("external", false) == "none", "sign default: external tool → self-sign");

        static JsonElement J(string s) => JsonDocument.Parse(s).RootElement.Clone();
        // 夹具：作业 phoneOverview（probe）形状；这款 0100AAAA00000000
        const string game = "0100aaaa00000000";
        var o = PhoneOverview.Parse(J("""
        {"phones":[
         {"device":"EXT-CERT","name":"客厅","kind":"iPad","installed":true,"installedBy":"external","bundleId":"com.alt.s2arm","online":"usb",
          "candidates":[{"bundleId":"com.alt.s2arm","team":"T1","byThisLauncher":false,"identityTeam":"T1"},{"bundleId":"com.other.s2arm","team":"T2","byThisLauncher":false}],
          "games":[{"gameId":"0100AAAA00000000","state":"suggested","reasons":["shader"]}]},
         {"device":"EXT-NOCERT","name":"备用","kind":"iphone","installed":true,"installedBy":"external","bundleId":"com.alt.s2arm","online":"wifi",
          "candidates":[{"bundleId":"com.alt.s2arm","team":"T1","byThisLauncher":false},{"bundleId":"com.other.s2arm","team":"T2","byThisLauncher":false}],
          "games":[{"gameId":"0100AAAA00000000","state":"latest"}]},
         {"device":"EXT-ONE","name":"","installed":true,"installedBy":"external","bundleId":"com.alt.s2arm","online":"usb","games":[]},
         {"device":"OWN","name":"我的 iPhone","kind":"iPhone","installed":true,"installedBy":"launcher","shellCurrent":true,"online":"usb",
          "games":[{"gameId":"0100AAAA00000000","state":"notPushed"}]},
         {"device":"OWN-OLD","name":"旧壳","installed":true,"installedBy":"launcher","shellCurrent":false,"online":"usb","games":[]},
         {"device":"BARE","name":"新手机","installed":false,"online":"usb","games":[{"gameId":"0100AAAA00000000","state":"needsData"}]},
         {"device":"AWAY","name":"不在","installed":true,"installedBy":"launcher","shellCurrent":true,"online":null,"games":[]},
         {"device":"UNPROBED","name":"没现查","installed":true,"installedBy":"launcher","shellCurrent":true,"games":[]}]}
        """))!;
        PhoneOverview.Phone P(string id) => o.Phones.First(p => p.Device == id);
        check(P("EXT-CERT").Kind == "iPad" && P("EXT-NOCERT").Kind == "iPhone" && P("EXT-ONE").Kind == "", "kind: iPad / iPhone read from the job (case folded); missing → empty, shown as 「设备」");

        // 这款在这台的状态
        check(ExportChoice.GameKey(P("EXT-CERT"), game) == "export.device.game.old", "game state: suggested → older version installed");
        check(ExportChoice.GameKey(P("EXT-NOCERT"), game) == "export.device.game.latest", "game state: latest → up to date");
        check(ExportChoice.GameKey(P("OWN"), game) == "export.device.game.none" && ExportChoice.GameKey(P("BARE"), game) == "export.device.game.none"
            && ExportChoice.GameKey(P("OWN-OLD"), game) == "export.device.game.none", "game state: notPushed / needsData / absent → not installed");

        string R(string id, string sign, string layout = "shell")
        {
            var r = ExportChoice.Row(P(id), game, sign, layout);
            return (r.Checkable ? "on" : "off") + "|" + (r.NoteKey ?? "") + "|" + (r.ConsoleLink ? "link" : "");
        }
        // 自签：设备行三种
        check(R("EXT-CERT", "none") == "on||", "self-sign: external S2Arm with an imported certificate → can tick");
        check(R("EXT-NOCERT", "none") == "on|export.device.importCert|", "self-sign: external S2Arm without a certificate → can tick, says import it on the device; no S2Arm-card link (that can't help)");
        check(R("EXT-ONE", "none") == "on||", "self-sign: external S2Arm, certificate unknown (single app, no candidates) → can tick, no claim either way");
        // 作业层给这台的 certImported 优先于候选（只装着一个外部 S2Arm 时作业层也给）
        check(ExportChoice.Row(P("EXT-ONE") with { CertImported = false }, game, "none", "shell") is { Checkable: true, NoteKey: "export.device.importCert", ConsoleLink: false },
            "self-sign: phone.certImported false (single external app) → import-first note");
        check(ExportChoice.Row(P("EXT-NOCERT") with { CertImported = true }, game, "none", "shell").NoteKey is null, "self-sign: phone.certImported true wins over candidates saying not imported");
        check(PhoneOverview.Parse(J("""{"phones":[{"device":"X","installedBy":"external","certImported":false},{"device":"Y","installedBy":"external","certImported":true},{"device":"Z"}]}"""))!.Phones
            .Select(p => p.CertImported).SequenceEqual(new bool?[] { false, true, null }), "parse: phone certImported true / false / absent → null");
        check(R("OWN", "none") == "off|export.device.launcherSigned|", "self-sign: launcher-signed S2Arm → greyed with the reason");
        check(R("OWN-OLD", "none") == "off|export.device.launcherSigned|", "self-sign: launcher-signed (old shell) → greyed");
        check(R("BARE", "none") == "off|export.device.noShell.selfSign|", "self-sign: no S2Arm at all → greyed with the reason");
        // 自签 + 独立 App：设备一律置灰，写「只能导出到文件夹」（独立 App 推到设备要在电脑上签）
        check(new[] { "EXT-CERT", "EXT-NOCERT", "OWN", "BARE" }.All(id => R(id, "none", "standalone") == "off|export.device.selfSignStandalone|"),
            "self-sign + standalone app: every device greyed, folder export only");
        check(R("AWAY", "none", "standalone") == "off|export.device.notConnected|", "self-sign + standalone: an offline device still says not connected");
        // 已签名：都可勾；通用 S2Arm 出法下没装 / 不是本版给提示和入口
        check(R("OWN", "appleId") == "on||", "signed: current launcher S2Arm → can tick");
        check(R("BARE", "appleId") == "on|export.device.noShell|link", "signed: no S2Arm → can tick, install-first note + link");
        check(R("OWN-OLD", "devCert") == "on|export.device.shellOld|link", "signed: old S2Arm → can tick, update-first note + link");
        check(R("BARE", "appleId", "standalone") == "on||", "signed + standalone app: no S2Arm needed");
        check(R("EXT-NOCERT", "appleId") == "on||", "signed: external S2Arm still goes the phone-signs-it way");
        // 没连着 / 没现查：置灰
        check(R("AWAY", "appleId") == "off|export.device.notConnected|" && R("AWAY", "none") == "off|export.device.notConnected|", "offline → greyed whatever the signing");
        check(R("UNPROBED", "appleId") == "off|export.device.notConnected|", "not probed yet → not offered as connected");

        // 开始后起的 install 单
        static string Q(IReadOnlyList<Dictionary<string, object?>> qs) =>
            string.Join(";", qs.Select(q => string.Join(",", q.OrderBy(kv => kv.Key).Select(kv => kv.Key + "=" + kv.Value))));
        check(Q(ExportChoice.InstallRequests("appleId", ["OWN", "BARE"])) == "device=OWN,sign=appleId;device=BARE,sign=appleId",
            "start: ticked devices → one install per device in list order, {device, sign}, no mode");
        check(Q(ExportChoice.InstallRequests("none", ["EXT-CERT"])) == "device=EXT-CERT,sign=none", "start: self-sign to an external S2Arm carries sign none");
        check(Q(ExportChoice.InstallRequests("none", [])) == "mode=export,sign=none", "start: nothing ticked → one export-to-folder install with the sign");
        check(Q(ExportChoice.InstallRequests("devCert", [])) == "mode=export,sign=devCert", "start: nothing ticked, signed → export with that sign");

        // 选「独立 App」时的提示：作业 standaloneHints 按这次签名方式取码（显式 App ID 的描述文件装一款顶掉前一款，玩家反馈）
        var hints = ExportChoice.StandaloneHints(J("""{"layout":"shell","standaloneHint":"wildcard","standaloneHints":{"appleId":"appleId","devCert":"explicit","none":"external","bogus":"x"}}"""));
        check(hints.Count == 3 && hints["devCert"] == "explicit", "standalone hints: three sign keys parsed, unknown key dropped");
        check(ExportChoice.StandaloneHints(J("""{"standaloneHints":{"appleId":"appleId","devCert":null,"none":"external"}}""")).ContainsKey("devCert") == false,
            "standalone hints: devCert null (ordinary development profile) → no hint");
        check(ExportChoice.StandaloneHints(J("""{"standaloneHint":"wildcard"}""")).Count == 0, "standalone hints: absent → empty");
        check(ExportChoice.StandaloneNote(hints, "devCert", "standalone") == ("install.layout.hint.explicit", "#FFD60A"), "note: certificate + standalone + explicit profile → yellow explicit");
        check(ExportChoice.StandaloneNote(hints, "appleId", "standalone") == ("install.layout.hint.appleId", "#FF9F0A"), "note: Apple ID + standalone → orange free-account limits");
        check(ExportChoice.StandaloneNote(hints, "none", "standalone") == ("install.layout.hint.external", "#FF9F0A"), "note: self-sign + standalone → orange external");
        check(ExportChoice.StandaloneNote(ExportChoice.StandaloneHints(J("""{"standaloneHints":{"devCert":"wildcard"}}""")), "devCert", "standalone") == ("install.layout.hint.wildcard", "#FFD60A"),
            "note: wildcard profile → yellow wildcard");
        check(ExportChoice.StandaloneNote(hints, "devCert", "shell") is null, "note: universal S2Arm chosen → no line");
        check(ExportChoice.StandaloneNote(new Dictionary<string, string>(), "devCert", "standalone") is null, "note: no hint for this sign → no line");

        // 导出成功页的「旧独立 App 的存档怎么搬」：独立 App 且有一行成功才写；通用 S2Arm 不写；还没成 / 全失败不写
        check(ExportChoice.ShowsStandaloneSaveCarry("standalone", ["succeeded", "failed"]), "save carry: standalone, one device succeeded → shown");
        check(ExportChoice.ShowsStandaloneSaveCarry("standalone", ["succeeded"]), "save carry: standalone exported to a folder → shown");
        check(!ExportChoice.ShowsStandaloneSaveCarry("shell", ["succeeded"]), "save carry: universal S2Arm → not shown");
        check(!ExportChoice.ShowsStandaloneSaveCarry("standalone", ["waiting", "failed"]), "save carry: nothing succeeded yet → not shown");

        // 要不要先在电脑上做好 iPhone 版
        check(ExportChoice.NeedsPack(false, false, 2) && ExportChoice.NeedsPack(false, false, 0), "prepare: no iPhone version → prepare first");
        check(!ExportChoice.NeedsPack(true, false, 1), "prepare: iPhone version (old format) pushing to a device → no repack");
        check(ExportChoice.NeedsPack(true, false, 0), "prepare: export to a folder needs the new single-IMG format");
        check(!ExportChoice.NeedsPack(true, true, 0), "prepare: exportable already → export straight away");
    }
}
