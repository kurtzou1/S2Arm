// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 游戏库「更新 / 导出」两件事（0.6.4 改版，维护者 11-21 定稿）：无头窗口按真实页面画，逐状态出图，期望手写——
//   ① 大卡三态：没做过 iPhone 版不出更新按钮；做过且有原因 = 可点「更新这款」+ 橙色原因行；做过且无原因 = 不可点「无需更新」；更新中按钮变进度、不可点；
//      大卡 / 列表卡上没有「推到 iPhone」「导出自签包」，有「导出…」；列表卡上的「建议更新」角标出现、点了选中这款。
//   ② 导出确认页：打开时设备一台都不勾；Apple ID 签 → 两台（本版 S2Arm、没装 S2Arm）都能勾、后者写「先装」；
//      自签 → 外部 S2Arm 导入了证书可勾 / 没导入可勾写「先导入」/ 启动器签的置灰；没做好 iPhone 版写「会先在电脑上做好」。
//   ③ 开始：勾两台 → 这一单的设备 = 勾的那两台（按列表顺序）、签名 = 选的那种，逐台各有结局（本机没有引擎，两台都失败——一台失败不挡下一台）；
//      都不勾 → 一单导出到文件夹（结局行键 ""）；没做好 iPhone 版 → 先出包（没有引擎出不成 → 停在「没做好」写原因）。
//   ④ 逐台结果（一台成功一台失败，失败那台有「重试」）、更新完成带黄字。调用方核退出码 0 和末行「✓」。
using System.Reflection;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Avalonia.VisualTree;
using S2Arm.Launcher;
using S2Arm.Launcher.Protocol;

static class UpdateExportProbe
{
    const BindingFlags F = BindingFlags.NonPublic | BindingFlags.Instance;

    public static int Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        var fails = new List<string>();
        var w = new EnvironmentWindow { Width = 1180, Height = 1000 };
        w.Show(); Settle(w);
        try
        {
            static LibraryGame G(string id, string name, bool ready, bool exportable = true) =>
                new(id, name, "v1.0.0", "", false, [], ready, null, false, [new("base", id, 0, "v1.0.0", 4_000_000_000L, "extract")],
                    IphoneExportable: ready && exportable);
            var fresh = G("0100F00A00000000", "示例游戏 A（没做过 iPhone 版）", ready: false);
            var stale = G("0100F00B00000000", "示例游戏 B（建议更新）", ready: true);
            var latest = G("0100F00C00000000", "示例游戏 C（已是最新）", ready: true);
            Set(w, "catalog", new LibraryCatalog([fresh, stale, latest], true, "密钥已就绪"));
            Set(w, "connectedFolder", "/tmp/s2arm-library"); Set(w, "libraryId", "mock-lib-id"); Set(w, "librarySummary", "library.completed");
            Set(w, "language", "zh-Hans");   // 期望文字按中文手写（本机系统语言可能是英文）
            Set(w, "updateHintsFor", "mock-lib-id");   // 不起 updateHints 作业（本机没有引擎，读失败会把下面放进去的原因清空）
            var hints = (Dictionary<string, string[]>)Get(w, "updateHints")!;
            hints[stale.Id] = ["rewriter", "shader"];

            // ① 大卡三态
            string? HeroUpdate(LibraryGame g, string shot)
            {
                Set(w, "selectedGame", g.Id); Navigate(w, "library"); Settle(w);
                Save(w, Path.Combine(outDir, shot));
                var b = Buttons(w).FirstOrDefault(x => Id(x) == "library.hero.update");
                return b is null ? null : (b.IsEnabled ? "on:" : "off:") + Text(b);
            }
            Check(fails, "大卡·没做过 iPhone 版：没有更新按钮", HeroUpdate(fresh, "hero_1_not_prepared.png") is null);
            Check(fails, "大卡·没做过 iPhone 版：有「导出…」", Buttons(w).Any(b => Id(b) == "library.hero.export" && b.IsEnabled));
            var s2 = HeroUpdate(stale, "hero_2_update_suggested.png");
            Check(fails, $"大卡·建议更新：可点「更新这款」（实际 {s2}）", s2 == "on:更新这款");
            Check(fails, "大卡·建议更新：有橙色原因行", Ids(w).Contains("update.hint"));
            var s3 = HeroUpdate(latest, "hero_3_up_to_date.png");
            Check(fails, $"大卡·已是最新：不可点「无需更新」（实际 {s3}）", s3 == "off:无需更新");
            Check(fails, "大卡·已是最新：没有原因行", !Ids(w).Contains("update.hint"));
            Check(fails, "游戏库页没有「推到 iPhone」「导出自签包」",
                !Ids(w).Any(i => i is "library.hero.install" or "library.hero.selfSign") && !Texts(w).Any(t => t is "推到 iPhone" or "导出自签包"));
            Check(fails, "列表卡片的按钮是「导出…」（3 张卡 + 大卡共 4 颗）", Buttons(w).Count(b => Id(b) == "library.hero.export") == 4);
            Check(fails, "游戏库页（大卡 + 列表卡）没有「出包」（只在右键菜单）", !Buttons(w).Any(b => Id(b) == "nav.build") && !Texts(w).Contains("出包")
                && !Buttons(w).Any(b => Text(b) == "出包"));
            var updating = (System.Collections.IDictionary)Get(w, "gameUpdating")!;
            updating[stale.Id] = ((double?)0.42, "重编着色器库");
            var s4 = HeroUpdate(stale, "hero_4_updating.png");
            Check(fails, $"大卡·更新中：按钮写进度、不可点（实际 {s4}）", s4 is { } u && u.StartsWith("off:⟳") && u.Contains("42%"));
            updating.Clear();
            // 列表卡「建议更新」角标：出现在 B 的缩略图上，点了选中 B
            Set(w, "selectedGame", latest.Id); Navigate(w, "library"); Settle(w);
            var badge = w.GetVisualDescendants().OfType<Control>().FirstOrDefault(c => Id(c) == "card.updateHint");
            Check(fails, "列表卡「建议更新」角标出现", badge is not null);
            badge?.RaiseEvent(new Avalonia.Input.PointerPressedEventArgs(badge, new Avalonia.Input.Pointer(1, Avalonia.Input.PointerType.Mouse, true), w,
                default, 0, new Avalonia.Input.PointerPointProperties(Avalonia.Input.RawInputModifiers.LeftMouseButton, Avalonia.Input.PointerUpdateKind.LeftButtonPressed),
                Avalonia.Input.KeyModifiers.None));
            Settle(w);
            Check(fails, "点角标选中这款", (string?)Get(w, "selectedGame") == stale.Id);

            // ② 导出确认页
            var overview = PhoneOverview.Parse(JsonDocument.Parse($$"""
            {"phones":[
             {"device":"OWN-0000000000000000000000000000000AAA111","name":"我的 iPhone","kind":"iPhone","installed":true,"installedBy":"launcher","shellCurrent":true,"online":"usb",
              "games":[{"gameId":"{{stale.Id}}","state":"suggested","reasons":["shader"]}]},
             {"device":"BARE-000000000000000000000000000000BBB222","name":"","kind":"iPad","installed":false,"online":"usb","games":[]},
             {"device":"EXT-CERT-0000000000000000000000000CCC333","name":"客厅","kind":"iPad","installed":true,"installedBy":"external","bundleId":"com.alt.s2arm","online":"usb",
              "candidates":[{"bundleId":"com.alt.s2arm","team":"T1","byThisLauncher":false,"identityTeam":"T1"},{"bundleId":"com.other.s2arm","team":"T2","byThisLauncher":false}],
              "games":[{"gameId":"{{stale.Id}}","state":"latest"}]},
             {"device":"EXT-NOCERT-00000000000000000000000DDD444","name":"备用机","installed":true,"installedBy":"external","bundleId":"com.alt.s2arm","online":"wifi",
              "candidates":[{"bundleId":"com.alt.s2arm","team":"T1","byThisLauncher":false},{"bundleId":"com.other.s2arm","team":"T2","byThisLauncher":false}],"games":[]}]}
            """).RootElement)!;
            Set(w, "devCert", (JsonElement?)JsonDocument.Parse("""{"imported":false,"active":false,"cert":null}""").RootElement.Clone());
            Set(w, "signChoice", "appleId"); Set(w, "layoutKnown", true); Set(w, "installModeTried", true);
            void OpenExport(LibraryGame g, string? sign = null)
            {
                Set(w, "phoneOverview", overview);
                w.GetType().GetMethod("OpenExport", F)!.Invoke(w, [g, null, sign]);
                WaitUntil(w, () => Get(w, "exportProbing") is false);   // 现查（本机没有引擎：作业失败，保持上次的总览）
                Set(w, "phoneOverview", overview); Call(w, "Render"); Settle(w);
            }
            CheckBox? Box(string device) => w.GetVisualDescendants().OfType<CheckBox>().FirstOrDefault(c => Id(c) == "exportgame.device." + device);
            OpenExport(stale);
            var boxes = w.GetVisualDescendants().OfType<CheckBox>().Where(c => Id(c)?.StartsWith("exportgame.device.") == true).ToList();
            Check(fails, $"确认页打开时设备一台都不勾（{boxes.Count} 台）", boxes.Count == 4 && boxes.All(b => b.IsChecked != true));
            Check(fails, "Apple ID 签：本版 S2Arm 那台可勾", Box("OWN-0000000000000000000000000000000AAA111")?.IsEnabled == true);
            Check(fails, "Apple ID 签：没装 S2Arm 那台可勾、写「先装」、给入口", Box("BARE-000000000000000000000000000000BBB222")?.IsEnabled == true
                && Texts(w).Contains("这台还没装 S2Arm（先装）") && Ids(w).Contains("exportgame.console.BARE-000000000000000000000000000000BBB222"));
            // 「去 S2Arm 卡」紧跟在那一行的说明后面：和「这台还没装 S2Arm（先装）」在同一个父容器里、在它右边、上下重叠（同一行），且在这台的勾选框下面
            {
                var link = Buttons(w).First(b => Id(b) == "exportgame.console.BARE-000000000000000000000000000000BBB222");
                var note = w.GetVisualDescendants().OfType<TextBlock>().First(t => Id(t) == "exportgame.note.BARE-000000000000000000000000000000BBB222");
                var lp = link.TranslatePoint(new Avalonia.Point(0, 0), w)!.Value; var np = note.TranslatePoint(new Avalonia.Point(0, 0), w)!.Value;
                var bp = Box("BARE-000000000000000000000000000000BBB222")!.TranslatePoint(new Avalonia.Point(0, 0), w)!.Value;
                var gap = lp.X - (np.X + note.Bounds.Width);
                Check(fails, $"「去 S2Arm 卡」紧跟说明文字（同一行、间距 {gap:F0}px）", ReferenceEquals(link.Parent, note.Parent) && gap is >= 0 and <= 24
                    && lp.Y < np.Y + note.Bounds.Height && np.Y < lp.Y + link.Bounds.Height && np.Y > bp.Y);
            }
            Check(fails, "设备行写类型 + 名字 + 这款状态", Texts(w).Contains("iPhone · 我的 iPhone") && Texts(w).Contains("已装旧版这款") && Texts(w).Contains("iPad · BBB222"));
            Check(fails, "没证书时「我的证书」不可选", w.GetVisualDescendants().OfType<RadioButton>().FirstOrDefault(r => Id(r) == "exportgame.sign.devCert")?.IsEnabled == false);
            Check(fails, "做好了 iPhone 版不写「会先做好」", !Ids(w).Contains("exportgame.prepare"));
            // 截图里只放两台（Apple ID 签 + 两台不同状态）
            Set(w, "phoneOverview", new PhoneOverview(overview.Phones.Take(2).ToList())); Call(w, "Render"); Settle(w);
            Save(w, Path.Combine(outDir, "export_1_appleid_two_devices.png"));
            Set(w, "phoneOverview", overview);
            // 自签：三种设备行
            Set(w, "exportSignPick", "none"); Call(w, "Render"); Settle(w);
            Check(fails, "自签：外部 S2Arm 导入了证书 → 可勾、不写先导入", Box("EXT-CERT-0000000000000000000000000CCC333")?.IsEnabled == true);
            Check(fails, "自签：外部 S2Arm 没导入证书 → 可勾、写「先导入」", Box("EXT-NOCERT-00000000000000000000000DDD444")?.IsEnabled == true
                && Texts(w).Any(t => t.StartsWith("先在手机上打开 S2Arm → 右上角齿轮 →「签名证书」导入")) && !Ids(w).Contains("exportgame.console.EXT-NOCERT-00000000000000000000000DDD444"));
            Check(fails, "自签：启动器签的那台置灰、写原因", Box("OWN-0000000000000000000000000000000AAA111")?.IsEnabled == false
                && Texts(w).Any(t => t.StartsWith("这台的 S2Arm 是启动器签的")));
            Check(fails, "自签：没装 S2Arm 那台置灰", Box("BARE-000000000000000000000000000000BBB222")?.IsEnabled == false);
            Check(fails, "类型读不到写「设备」", Texts(w).Contains("设备 · 备用机"));
            // 自签 + 独立 App：设备一律置灰、写「只能导出到文件夹」
            Set(w, "exportLayoutPick", "standalone"); Call(w, "Render"); Settle(w);
            Check(fails, "自签 + 独立 App：设备全灰、写「只能导出到文件夹」", w.GetVisualDescendants().OfType<CheckBox>().Where(c => Id(c)?.StartsWith("exportgame.device.") == true).All(c => !c.IsEnabled)
                && Texts(w).Count(t => t == "自签的独立 App 只能导出到文件夹") == 4);
            Set(w, "exportLayoutPick", null);
            Set(w, "phoneOverview", new PhoneOverview([overview.Phones[2], overview.Phones[3], overview.Phones[0]])); Call(w, "Render"); Settle(w);
            Save(w, Path.Combine(outDir, "export_2_selfsign_three_rows.png"));
            Set(w, "phoneOverview", overview);
            // 选「独立 App」时按这次的签名方式出提示（作业 standaloneHints）；切签名 / 切出法跟着变，通用 S2Arm 不出
            Set(w, "standaloneHints", (IReadOnlyDictionary<string, string>)new Dictionary<string, string> { ["appleId"] = "appleId", ["devCert"] = "explicit", ["none"] = "external" });
            Set(w, "devCert", (JsonElement?)JsonDocument.Parse("""{"imported":true,"active":true,"cert":null}""").RootElement.Clone());
            string? Note() => w.GetVisualDescendants().OfType<TextBlock>().FirstOrDefault(t => Id(t) == "exportgame.layout.note")?.Text;
            Set(w, "exportSignPick", "appleId"); Set(w, "exportLayoutPick", "shell"); Call(w, "Render"); Settle(w);
            Check(fails, "出法选通用 S2Arm：没有提示行", Note() is null);
            Set(w, "exportLayoutPick", "standalone"); Call(w, "Render"); Settle(w);
            Check(fails, "独立 App + Apple ID：免费账号那句", Note()?.StartsWith("免费 Apple ID") == true);
            Set(w, "exportSignPick", "none"); Call(w, "Render"); Settle(w);
            Check(fails, "独立 App + 自签：AltStore / SideStore 那句", Note()?.StartsWith("你选的是自己用 AltStore / SideStore 签") == true);
            Set(w, "exportSignPick", "devCert"); Call(w, "Render"); Settle(w);
            Check(fails, "独立 App + 我的证书（显式 App ID）：装一款顶掉前一款", Note()?.StartsWith("你的描述文件是显式 App ID") == true);
            Set(w, "phoneOverview", new PhoneOverview(overview.Phones.Take(1).ToList())); Call(w, "Render"); Settle(w);
            Save(w, Path.Combine(outDir, "export_5_standalone_explicit_profile.png"));
            Set(w, "phoneOverview", overview);
            Set(w, "exportSignPick", null); Set(w, "exportLayoutPick", null);
            Set(w, "devCert", (JsonElement?)JsonDocument.Parse("""{"imported":false,"active":false,"cert":null}""").RootElement.Clone());
            // 没做好 iPhone 版
            OpenExport(fresh);
            Check(fails, "没做好 iPhone 版：写「会先在电脑上做好」", Ids(w).Contains("exportgame.prepare") && Texts(w).Contains("这款还没做好 iPhone 版：开始后会先在电脑上做好"));
            Save(w, Path.Combine(outDir, "export_3_not_prepared.png"));

            // ③ 开始：勾两台（Apple ID 签）
            var runs = (System.Collections.IDictionary)Get(w, "exportRuns")!;
            OpenExport(stale);
            Box("BARE-000000000000000000000000000000BBB222")!.IsChecked = true; Settle(w);
            Box("OWN-0000000000000000000000000000000AAA111")!.IsChecked = true; Settle(w);
            Click(w, "exportgame.start");
            WaitUntil(w, () => runs[stale.Id] is { } r && !(bool)Prop(r, "Active")!, 60);
            var run = runs[stale.Id];
            var devices = run is null ? "" : string.Join(",", (IEnumerable<string>)Prop(run, "Devices")!);
            Check(fails, $"开始：这一单的设备 = 勾的两台、按列表顺序（实际 {devices}）",
                devices == "OWN-0000000000000000000000000000000AAA111,BARE-000000000000000000000000000000BBB222");
            Check(fails, "开始：签名 = Apple ID", run is not null && (string)Prop(run, "Sign")! == "appleId");
            var rows = run is null ? null : (System.Collections.IDictionary)run.GetType().GetField("Rows")!.GetValue(run)!;
            Check(fails, "开始：两台各有结局（第一台失败也接着起第二台）", rows is { Count: 2 } && rows.Values.Cast<object>().All(v => (string)v.GetType().GetField("Item1")!.GetValue(v)! is not "waiting"));
            Check(fails, "开始后同一页变逐台结果（有「重试」）", Ids(w).Count(i => i.StartsWith("exportgame.retry.")) == 2);
            // 都不勾 → 导出到文件夹（自签）
            runs.Remove(stale.Id);
            OpenExport(stale, sign: "none");
            Click(w, "exportgame.start");
            WaitUntil(w, () => runs[stale.Id] is { } r && !(bool)Prop(r, "Active")!, 60);
            run = runs[stale.Id];
            rows = run is null ? null : (System.Collections.IDictionary)run.GetType().GetField("Rows")!.GetValue(run)!;
            Check(fails, "都不勾：一单导出到文件夹（设备空、结局行键 \"\"、签名 none）", run is not null && ((IReadOnlyList<string>)Prop(run, "Devices")!).Count == 0
                && rows is { Count: 1 } && rows.Contains("") && (string)Prop(run, "Sign")! == "none");
            // 没做好 iPhone 版 → 先出包；本机出不成 → 停在「没做好」写原因
            OpenExport(fresh);
            Click(w, "exportgame.start");
            WaitUntil(w, () => runs[fresh.Id] is { } r && !(bool)Prop(r, "Active")!, 60);
            run = runs[fresh.Id];
            Check(fails, "没做好 iPhone 版：先出包，出不成停在「没做好」", run is not null && ((string)run.GetType().GetField("PackError")!.GetValue(run)!).Length > 0);
            Navigate(w, "library"); Settle(w);

            // ④ 逐台结果（一台成功一台失败）：直接放这一单的结局（不跑作业）
            var runType = w.GetType().GetNestedType("ExportRun", BindingFlags.NonPublic)!;
            var shown = Activator.CreateInstance(runType, [stale.Id, "appleId", "shell", (IReadOnlyList<string>)["OWN-0000000000000000000000000000000AAA111", "BARE-000000000000000000000000000000BBB222"]])!;
            var shownRows = (System.Collections.IDictionary)runType.GetField("Rows")!.GetValue(shown)!;
            shownRows["OWN-0000000000000000000000000000000AAA111"] = ("succeeded", "", (string?)null);
            shownRows["BARE-000000000000000000000000000000BBB222"] = ("failed", "手机上还没装 S2Arm：先点「安装 S2Arm」装好 App，再推游戏。", (string?)"shell_install_required");
            runs[stale.Id] = shown;
            Set(w, "selectedGame", stale.Id); Navigate(w, "exportgame"); Settle(w);
            Check(fails, "逐台结果：成功那台「已装到这台」、失败那台有原因 + 重试 + 去 S2Arm 卡",
                Texts(w).Contains("✓ 已装到这台") && Ids(w).Contains("exportgame.retry.BARE-000000000000000000000000000000BBB222")
                && !Ids(w).Contains("exportgame.retry.OWN-0000000000000000000000000000000AAA111") && Texts(w).Contains("去 S2Arm 卡"));
            Save(w, Path.Combine(outDir, "export_4_per_device_results.png"));
            Check(fails, "通用 S2Arm 成功页：不写旧独立 App 存档怎么搬", !Ids(w).Contains("exportgame.saveCarry"));
            // 独立 App：逐台成功 / 导出到文件夹成功都写「之前用独立 App 装过的游戏，存档在旧 App 里……」
            var standaloneRun = Activator.CreateInstance(runType, [stale.Id, "devCert", "standalone", (IReadOnlyList<string>)["OWN-0000000000000000000000000000000AAA111"]])!;
            ((System.Collections.IDictionary)runType.GetField("Rows")!.GetValue(standaloneRun)!)["OWN-0000000000000000000000000000000AAA111"] = ("succeeded", "", (string?)null);
            runs[stale.Id] = standaloneRun; Call(w, "Render"); Settle(w);
            Check(fails, "独立 App 装到设备成功：写旧独立 App 存档怎么搬", w.GetVisualDescendants().OfType<TextBlock>().Any(t => Id(t) == "exportgame.saveCarry" && t.Text?.StartsWith("之前用独立 App 装过的游戏") == true));
            Save(w, Path.Combine(outDir, "export_6_standalone_done_save_carry.png"));
            var folderRun = Activator.CreateInstance(runType, [stale.Id, "none", "standalone", (IReadOnlyList<string>)[]])!;
            ((System.Collections.IDictionary)runType.GetField("Rows")!.GetValue(folderRun)!)[""] = ("succeeded", "", (string?)null);
            runs[stale.Id] = folderRun; Call(w, "Render"); Settle(w);
            Check(fails, "独立 App 导出到文件夹成功：也写", Ids(w).Contains("exportgame.saveCarry"));
            runs.Remove(stale.Id);

            // 更新完成带黄字（作业 updateGame 结果 diagnostics 里 update_incomplete 的玩家句；结果 reasons 还剩 → 按钮仍可点）
            var updated = (System.Collections.IDictionary)Get(w, "gameUpdated")!;
            updated[stale.Id] = (true, "", (IReadOnlyList<string>)["这款电脑上没有游戏原件，着色器库这一项没更新：重新添加这款的游戏文件后再点一次「更新这款」。"]);
            ((Dictionary<string, string[]>)Get(w, "updateHints")!)[stale.Id] = ["shader"];   // 上面跑过的作业收尾会重读 updateHints（本机读失败 = 清空），重新放
            Set(w, "selectedGame", stale.Id); Navigate(w, "library"); Settle(w);
            Check(fails, "更新完成：黄字列在按钮下", Ids(w).Contains("update.outcome") && Texts(w).Any(t => t.StartsWith("⚠ 这款电脑上没有游戏原件")));
            Save(w, Path.Combine(outDir, "hero_5_update_done_warning.png"));
        }
        catch (Exception error) { fails.Add("探针异常：" + (error.InnerException ?? error)); }
        finally { w.Close(); Dispatcher.UIThread.RunJobs(); }
        if (fails.Count > 0) { Console.WriteLine("✗ 更新 / 导出：\n  " + string.Join("\n  ", fails)); return 1; }
        Console.WriteLine("✓ 更新 / 导出两件事");
        return 0;
    }

    static void Check(List<string> fails, string name, bool ok) { Console.WriteLine($"  {(ok ? "通过" : "不通")}：{name}"); if (!ok) fails.Add(name); }
    static string? Id(Control c) => Avalonia.Automation.AutomationProperties.GetAutomationId(c);
    static List<Button> Buttons(Window w) => w.GetVisualDescendants().OfType<Button>().ToList();
    static List<string> Ids(Window w) => w.GetVisualDescendants().OfType<Control>().Select(Id).OfType<string>().ToList();
    static List<string> Texts(Window w) => w.GetVisualDescendants().OfType<TextBlock>().Select(t => t.Text ?? "").ToList();
    static string Text(Button b) => b.Content as string ?? (b.Content as TextBlock)?.Text ?? "";
    static void Click(Window w, string id) =>
        (Buttons(w).FirstOrDefault(b => Id(b) == id) ?? throw new InvalidOperationException("找不到按钮 " + id)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    static void Navigate(EnvironmentWindow w, string page) => w.GetType().GetMethod("Navigate", F)!.Invoke(w, [page]);
    static void Save(Window w, string path)
    {
        var bmp = w.CaptureRenderedFrame();
        if (bmp is null) { Console.WriteLine("  WARN no frame: " + path); return; }
        using var s = File.Create(path); bmp.Save(s, new Avalonia.Media.Imaging.PngBitmapEncoderOptions()); Console.WriteLine("  saved: " + Path.GetFileName(path));
    }
    static void Settle(Window w) { Dispatcher.UIThread.RunJobs(); w.UpdateLayout(); Dispatcher.UIThread.RunJobs(); }
    static void WaitUntil(Window w, Func<bool> done, int seconds = 30)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!done() && DateTime.UtcNow < until) { Dispatcher.UIThread.RunJobs(); Thread.Sleep(20); }
        Settle(w);
    }
    static void Call(object target, string method) => (target.GetType().GetMethod(method, F, null, Type.EmptyTypes, null) ?? throw new MissingMethodException(method)).Invoke(target, null);
    static object? Get(object obj, string field) => obj.GetType().GetField(field, F)?.GetValue(obj) ?? obj.GetType().GetProperty(field, F)?.GetValue(obj);
    static object? Prop(object obj, string name) => obj.GetType().GetProperty(name)?.GetValue(obj);
    static void Set(object obj, string field, object? value)
    {
        var fi = obj.GetType().GetField(field, F);
        if (fi is not null) { fi.SetValue(obj, value); return; }
        (obj.GetType().GetProperty(field, F | BindingFlags.Public) ?? throw new MissingMemberException(field)).SetValue(obj, value);
    }
}
