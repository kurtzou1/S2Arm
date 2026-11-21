// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

/// 0.6.4「更新 / 导出」两件事（维护者 11-21 定稿 + 作业层契约）。期望全部按规则手写，看替身作业收到的请求与模型状态：
///   更新：没做过 iPhone 版不显示 / 做过没原因「无需更新」/ 有原因「更新这款」；点了发 updateGame（只带 gameId，不带设备），结果 reasons 空 → 变「无需更新」，update_incomplete 黄字留着。
///   导出：设备行按签名分可勾 / 不可勾与说明；默认都不勾；开始后勾了设备逐台发 install(gameId, device, sign)、不带 mode / onlyInstalled，没勾发 install mode = export + sign；
///   开始前先 layoutSet 记这款的出法；失败的那台单独重试，不重推成功的那台
@MainActor final class UpdateExportTests: XCTestCase {
    private var root: URL!
    private var model: S2ArmLauncherModel!
    private var runner: RecordingRunner!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-uxmac-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        runner = RecordingRunner()
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        model.runAlert = { _ in .alertFirstButtonReturn }   // 读失败的报错框不弹真窗口
        model.refresh()
        for _ in 0..<300 where model.games.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func game(_ id: String) throws -> GameSummary { try XCTUnwrap(model.games.first { $0.id == id }) }

    private func waitRequests(_ op: String, count: Int) async -> [[String: Any]] {
        for _ in 0..<400 {
            let r = runner.requests.filter { $0["operation"] as? String == op }
            if r.count >= count { return r }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return runner.requests.filter { $0["operation"] as? String == op }
    }

    // ---- 更新 ----

    func testUpdateButtonThreeStates() throws {
        let ready = try game("0100A"), never = try game("0100B")
        XCTAssertEqual(model.updateButton(never), .hidden, "从没做过 iPhone 版：不显示更新按钮")
        model.updateHints = [:]
        XCTAssertEqual(model.updateButton(ready), .upToDate, "做过、没有原因：灰色「无需更新」")
        model.updateHints = ["0100A": ["shader", "hostAbi"]]
        XCTAssertEqual(model.updateButton(ready), .update(["shader", "hostAbi"]), "有原因：「更新这款」+ 原因")
        model.updateHints = ["0100B": ["shader"]]
        XCTAssertEqual(model.updateButton(never), .hidden, "没做过 iPhone 版：就算有提示也不出（作业层本就不判它）")
    }

    func testUpdateGameRunsOnComputerOnlyAndClearsHint() async throws {
        let g = try game("0100A")
        model.updateHints = ["0100A": ["shader"]]
        runner.updateDiagnostics = [["severity": "warning", "code": "update_incomplete", "message": "缺原件，这一项没更新：重新添加这款的游戏文件"]]
        model.updateGame(g)
        XCTAssertEqual(model.gameUpdate(g)?.running, true, "点了当场就是进度态，不二次确认")
        let reqs = await waitRequests("updateGame", count: 1)
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(reqs.first?["gameId"] as? String, "0100A")
        XCTAssertNil(reqs.first?["device"], "更新只在电脑上做，不带设备")
        for _ in 0..<300 where model.gameUpdate(g)?.running != false { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.updateButton(g), .upToDate, "结果 reasons 空：当场变「无需更新」")
        XCTAssertEqual(model.gameUpdate(g)?.incomplete, ["缺原件，这一项没更新：重新添加这款的游戏文件"], "update_incomplete 列成黄字，不当失败")
        XCTAssertNil(model.gameUpdate(g)?.failure)
        XCTAssertFalse(runner.requests.contains { $0["operation"] as? String == "install" }, "更新不推设备")
        model.updateGame(try game("0100B"))
        XCTAssertNil(model.gameUpdate(try game("0100B")), "没做过 iPhone 版的款不发 updateGame")
    }

    // ---- 导出确认页：设备行 ----

    private func phone(_ device: String, installed: Bool = true, by: PhoneOverview.InstalledBy? = nil, shellCurrent: Bool = true, online: String? = "usb",
                       cert: Bool? = nil, kind: String? = "iPhone", state: PhoneOverview.GameState? = nil) -> PhoneOverview.Phone {
        var p = PhoneOverview.Phone(device: device, name: device, installed: installed, shellCurrent: shellCurrent, bundleId: "com.example.s2arm", signedAt: nil, free: true,
                                    expiresAtEstimate: nil, online: .some(online), lastSeen: nil, signMode: nil,
                                    games: state.map { [PhoneOverview.Game(gameId: "0100A", state: $0, reasons: [], dataOnComputer: nil)] } ?? [], installedBy: by)
        p.kind = kind; p.certImported = cert
        return p
    }

    func testSelfSignDeviceRowsThreeKinds() {
        let row = { (p: PhoneOverview.Phone) in S2ArmLauncherModel.exportDeviceRow(p, gameId: "0100a", sign: "none", layout: "shell") }
        let withCert = row(phone("A", by: .external, cert: true, state: .latest))
        XCTAssertTrue(withCert.selectable); XCTAssertNil(withCert.note, "外部 S2Arm 已导入证书：可勾、不写说明")
        XCTAssertEqual(withCert.game, .latest)
        let noCert = row(phone("B", by: .external, cert: false, state: .suggested))
        XCTAssertTrue(noCert.selectable); XCTAssertEqual(noCert.note, .needCert, "外部 S2Arm 没导入证书：可勾，写「先导入签名证书」")
        XCTAssertFalse(noCert.hasLink, "导入证书在手机上做：说明句写全步骤，不给跳到电脑别处的入口")
        XCTAssertEqual(noCert.game, .old)
        let launcher = row(phone("C", by: .launcher))
        XCTAssertFalse(launcher.selectable); XCTAssertEqual(launcher.note, .launcherSigned, "启动器签的 S2Arm：置灰写原因")
        XCTAssertEqual(launcher.game, .none, "这台没有这款的记录 = 没装过")
        let none = row(phone("D", installed: false))
        XCTAssertFalse(none.selectable); XCTAssertEqual(none.note, .noShell, "没装 S2Arm：置灰")
        let offline = row(phone("E", by: .external, online: nil, cert: true))
        XCTAssertFalse(offline.selectable); XCTAssertEqual(offline.note, .offline, "没连着：置灰")
    }

    func testSignedDeviceRowsAllSelectable() {
        let row = { (p: PhoneOverview.Phone) in S2ArmLauncherModel.exportDeviceRow(p, gameId: "0100A", sign: "appleId", layout: "shell") }
        XCTAssertEqual(row(phone("A", by: .launcher)).note, nil)
        XCTAssertTrue(row(phone("A", by: .launcher)).selectable)
        XCTAssertEqual(row(phone("B", installed: false)).note, .noShell, "没装 S2Arm 也能勾，写「还没装 S2Arm」")
        XCTAssertTrue(row(phone("B", installed: false)).selectable)
        XCTAssertEqual(row(phone("C", by: .launcher, shellCurrent: false)).note, .shellOld)
        XCTAssertTrue(row(phone("D", by: .external, cert: false)).selectable, "别的工具装的：作业层自动走不签那条路")
        XCTAssertNil(row(phone("D", by: .external, cert: false)).note)
        XCTAssertEqual(S2ArmLauncherModel.exportDeviceRow(phone("E", installed: false), gameId: "0100A", sign: "devCert", layout: "standalone").note, nil, "独立 App 不需要 S2Arm")
    }

    /// 11-21 玩家反馈「独立 App 装一个顶掉前一款」：确认页 ② 选独立 App 时按 ① 这次选的签名方式给提示（作业 standaloneHints），不按设置。期望手写
    func testStandaloneHintFollowsExportSign() {
        let info = InstallModeInfo(result: ["signMode": "appleId", "signChoice": "appleId", "standaloneHint": "appleId",
                                            "standaloneHints": ["appleId": "appleId", "devCert": "explicit", "none": "external"]])
        XCTAssertEqual(info.standaloneHints, ["appleId": "appleId", "devCert": "explicit", "none": "external"])
        let hints = info.standaloneHints
        let cert = InstallLayoutRow.exportNote(now: "standalone", sign: "devCert", hints: hints, why: "appleId")
        XCTAssertEqual(cert?.0, "install.layout.hint.explicit", "我的证书 + 显式描述文件 + 独立 App → 装一款顶掉前一款那句（设置里是 Apple ID 也照样）")
        XCTAssertEqual(cert?.1, "yellow")
        let apple = InstallLayoutRow.exportNote(now: "standalone", sign: "appleId", hints: hints, why: "appleId")
        XCTAssertEqual(apple?.0, "install.layout.hint.appleId", "改选 Apple ID → 换成免费 Apple ID 那句")
        XCTAssertEqual(apple?.1, "orange")
        XCTAssertEqual(InstallLayoutRow.exportNote(now: "standalone", sign: "none", hints: hints, why: "appleId")?.0, "install.layout.hint.external")
        XCTAssertNil(InstallLayoutRow.exportNote(now: "shell", sign: "devCert", hints: hints, why: "appleId"), "选通用 S2Arm → 不出")
        let unread = InstallModeInfo(result: ["standaloneHints": ["appleId": "appleId", "devCert": NSNull(), "none": "external"]])
        XCTAssertNil(InstallLayoutRow.exportNote(now: "standalone", sign: "devCert", hints: unread.standaloneHints, why: "unknown"), "描述文件读不到（null）→ 不出，也不退回设置那句")
        XCTAssertFalse(BackendText.launcherText("install.layout.hint.explicit", language: "zh-Hans").hasPrefix("["))
    }

    /// 成功页的独立 App 存档说明（export.done.standaloneSaveCarry）：出法是独立 App 就出（不论签名方式、装到设备或导出到文件夹）；通用 S2Arm 不出。期望手写
    func testStandaloneSaveCarryNote() async throws {
        var done = ExportFlow(gameID: "0100A", sign: "devCert", rows: [ExportFlow.Row(device: "P1", kind: "iPhone", name: "甲", state: .done)], layout: "standalone")
        XCTAssertTrue(ExportSheetView.showsSaveCarry(done, folderDone: false), "独立 App 装好一台 → 出")
        done.layout = "shell"
        XCTAssertFalse(ExportSheetView.showsSaveCarry(done, folderDone: false), "通用 S2Arm → 不出")
        let failed = ExportFlow(gameID: "0100A", sign: "appleId", rows: [ExportFlow.Row(device: "P1", kind: "iPhone", name: "甲", state: .failed)], layout: "standalone")
        XCTAssertFalse(ExportSheetView.showsSaveCarry(failed, folderDone: false), "一台都没装好不是成功页 → 不出")
        let folder = ExportFlow(gameID: "0100A", sign: "none", rows: [], layout: "standalone")
        XCTAssertTrue(ExportSheetView.showsSaveCarry(folder, folderDone: true), "独立 App 导出到文件夹成功 → 出（自签也出）")
        XCTAssertFalse(ExportSheetView.showsSaveCarry(folder, folderDone: false))
        XCTAssertFalse(BackendText.launcherText("export.done.standaloneSaveCarry", language: "zh-Hans").hasPrefix("["))
        // 开始时把确认页 ② 选的出法记进这一单
        model.startExportSheet(try game("0100A"), sign: "devCert", layout: "standalone", devices: [])
        for _ in 0..<300 where model.exportFlows["0100A"] == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.exportFlows["0100A"]?.layout, "standalone")
    }

    func testFailedRowShellButtonFollowsCode() {
        XCTAssertEqual(ExportSheetView.shellLinkKey("shell_install_required"), "exportsheet.link.installShell", "没装 →「先装 S2Arm」")
        XCTAssertEqual(ExportSheetView.shellLinkKey("shell_update_required"), "exportsheet.link.updateShell", "不是本版 →「先更新 S2Arm」")
        XCTAssertNil(ExportSheetView.shellLinkKey("device_not_connected"), "别的失败码不给这个按钮")
        XCTAssertEqual(BackendText.launcherText("exportsheet.row.installed", language: "zh-Hans"), "已装到这台")
        for lang in ["zh-Hant", "en", "ja", "es", "fr"] {
            XCTAssertFalse(BackendText.launcherText("exportsheet.row.installed", language: lang).hasPrefix("["), "缺 \(lang)")
        }
    }

    func testDefaultsNothingPreselectedExceptRenew() {
        model.openExportSheet("0100A")
        XCTAssertNil(model.exportSheet?.preselect, "默认都不勾")
        model.openExportSheet("0100A", preselect: "PHONE-1")
        XCTAssertEqual(model.exportSheet?.preselect, "PHONE-1", "续签：预勾原来那台")
        model.installMode = InstallModeInfo(exportAvailable: true, signMode: "appleId", signChoice: "external")
        XCTAssertEqual(model.defaultExportSign(), "none", "设置里选了自己签 → 自签")
        model.installMode = InstallModeInfo(exportAvailable: true, signMode: "devcert", signChoice: "devCert")
        model.devCert = nil
        XCTAssertEqual(model.defaultExportSign(), "appleId", "选了证书却没导入过 → Apple ID")
    }

    // ---- 开始之后 ----

    func testStartWithDevicesInstallsEachInTurn() async throws {
        runner.failDevice = "PAD-2"
        let g = try game("0100A")
        model.startExportSheet(g, sign: "devCert", layout: "standalone",
                               devices: [.init(key: "PHONE-1", kind: "iPhone", name: "甲"), .init(key: "PAD-2", kind: "iPad", name: "乙")])
        let installs = await waitRequests("install", count: 2)
        XCTAssertEqual(installs.map { $0["device"] as? String }, ["PHONE-1", "PAD-2"], "逐台排队，一台一单")
        for r in installs {
            XCTAssertEqual(r["sign"] as? String, "devCert")
            XCTAssertNil(r["mode"], "推到设备不带 mode")
            XCTAssertNil(r["onlyInstalled"], "不带 onlyInstalled")
            XCTAssertEqual(r["gameId"] as? String, "0100A")
        }
        let layout = runner.requests.firstIndex { $0["operation"] as? String == "layoutSet" }
        let first = runner.requests.firstIndex { $0["operation"] as? String == "install" }
        XCTAssertNotNil(layout); XCTAssertLessThan(layout ?? .max, first ?? 0, "开始前先 layoutSet 记这款的出法")
        XCTAssertEqual(runner.requests.first { $0["operation"] as? String == "layoutSet" }?["layout"] as? String, "standalone")
        for _ in 0..<300 where model.exportFlows["0100A"]?.running != false { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.exportFlows["0100A"]?.rows.map(\.state), [.done, .failed], "每台各出结果")
        XCTAssertEqual(model.exportFlows["0100A"]?.rows.last?.code, "shell_install_required")
        model.retryExportRow("0100A", device: "PAD-2")
        let again = await waitRequests("install", count: 3)
        XCTAssertEqual(again.map { $0["device"] as? String }, ["PHONE-1", "PAD-2", "PAD-2"], "只重试失败的那台")
    }

    func testStartWithoutDevicesExportsToFolder() async throws {
        model.startExportSheet(try game("0100A"), sign: "none", layout: "shell", devices: [])
        let r = await waitRequests("install", count: 1).first
        XCTAssertEqual(r?["mode"] as? String, "export", "都不勾 = 导出到文件夹")
        XCTAssertEqual(r?["sign"] as? String, "none")
        XCTAssertNil(r?["device"], "导出不连设备")
        XCTAssertNil(runner.requests.first { $0["operation"] as? String == "export" }, "做好了的不再出包")
    }

    func testNotPreparedBuildsIPhoneFirst() async throws {
        model.runExportPlan(try game("0100C"), ExportPlan(sign: "appleId", devices: [.init(key: "PHONE-1")]))
        XCTAssertEqual(model.exportAfterPack["0100C"]?.devices.map(\.key), ["PHONE-1"], "记下出完接着导入哪几台")
        XCTAssertEqual(model.exportAfterPack["0100C"]?.sign, "appleId")
        let r = await waitRequests("export", count: 1).first
        let items = ((r?["plan"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        XCTAssertEqual(items.first?["platforms"] as? [String], ["iphone"], "没做好 iPhone 版（旧格式）：先只出 iPhone")
        XCTAssertNil(runner.requests.first { $0["operation"] as? String == "install" }, "出完之前不推")
        XCTAssertNil(r?["mode"], "要导入设备的：出包不带 mode = export")
    }
}

/// 离屏出图（不进任何窗口、不上屏、不整屏截）：NSHostingView 排版后画进位图，appearance = darkAqua。S2A_UXMAC_SHOT=<目录> 时存 PNG 看样子（不给也照跑）；
///   判据只核画得出东西（离屏 NSHostingView 不进窗口时读不到辅助功能树），每台可不可勾、谁能重试由 UpdateExportTests 按模型核；排版看存下的图
@MainActor final class UpdateExportScreensTests: XCTestCase {
    private var root: URL!
    private var model: S2ArmLauncherModel!
    private var savedLanguage: String?

    override func setUp() async throws {
        _ = NSApplication.shared
        savedLanguage = UserDefaults.standard.string(forKey: "appLanguage")
        UserDefaults.standard.set("zh", forKey: "appLanguage")   // 截图按中文界面
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-uxmac-shot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: RecordingRunner()))
        model.runAlert = { _ in .alertFirstButtonReturn }
        model.refresh()
        for _ in 0..<300 where model.games.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        model.installMode = InstallModeInfo(result: ["signMode": "appleId", "signChoice": "appleId", "layout": "shell", "recommend": "shell", "recommendWhy": "appleId"])
        model.appleAccount = AppleAccount(account: "player@example.com")
        model.devCert = DevCertStatus(imported: false, active: false, cert: nil)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedLanguage, forKey: "appLanguage")
        try? FileManager.default.removeItem(at: root)
    }

    private func game(_ id: String) throws -> GameSummary { try XCTUnwrap(model.games.first { $0.id == id }) }

    private func shot<V: View>(_ view: V, _ name: String, width: CGFloat, height: CGFloat) throws {
        let host = NSHostingView(rootView: AnyView(view.s2aLocalized().frame(width: width, height: height, alignment: .topLeading)
            .background(Color(red: 0.07, green: 0.07, blue: 0.08)).environment(\.colorScheme, .dark)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
        var ink = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) { for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent + c.greenComponent + c.blueComponent > 0.9 { ink += 1 } } }
        XCTAssertGreaterThan(ink, 100, "\(name)：离屏画出来是空的")
        if let dir = ProcessInfo.processInfo.environment["S2A_UXMAC_SHOT"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// 详情区（标题 + 更新按钮 + 「导出…」+ 按钮下几行）：同首页 homePreview 里这一段
    private func detail(_ g: GameSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(g.name).font(.system(size: 34, weight: .bold))
            HStack(spacing: 14) {
                HeroUpdateButton(model: model, game: g)
                Button {} label: { Label(BackendText.launcherText("exportsheet.open", language: "zh-Hans"), systemImage: "square.and.arrow.up") }
                    .buttonStyle(ConsolePillButtonStyle())
            }
            HeroUpdateLines(model: model, game: g)
        }.padding(32)
    }

    func testDetailAreaStates() throws {
        model.updateHints = [:]
        try shot(detail(try game("0100B")), "1a_详情区_没做过iPhone版_不显示更新", width: 720, height: 260)
        try shot(detail(try game("0100A")), "1b_详情区_无需更新", width: 720, height: 260)
        model.updateHints = ["0100A": ["shader", "hostAbi", "libGen"]]
        try shot(detail(try game("0100A")), "1c_详情区_更新这款_橙色原因", width: 720, height: 260)
        model.gameUpdates["0100A"] = GameUpdateRun()
        try shot(detail(try game("0100A")), "1d_详情区_更新中", width: 720, height: 260)
        model.updateHints = [:]
        model.gameUpdates["0100A"] = GameUpdateRun(running: false, incomplete: ["缺原件，这一项没更新：重新添加这款的游戏文件"])
        try shot(detail(try game("0100A")), "1e_详情区_更新完成带黄字", width: 720, height: 260)
    }

    private func phone(_ device: String, name: String, kind: String?, by: PhoneOverview.InstalledBy?, installed: Bool = true, cert: Bool? = nil,
                       state: PhoneOverview.GameState?) -> PhoneOverview.Phone {
        var p = PhoneOverview.Phone(device: device, name: name, installed: installed, shellCurrent: true, bundleId: "com.example.s2arm", signedAt: nil, free: true,
                                    expiresAtEstimate: nil, online: .some("usb"), lastSeen: nil, signMode: nil,
                                    games: state.map { [PhoneOverview.Game(gameId: "0100A", state: $0, reasons: [], dataOnComputer: nil)] } ?? [], installedBy: by)
        p.kind = kind; p.certImported = cert
        return p
    }

    func testExportSheetStates() throws {
        model.exportPhones = [phone("P1", name: "我的 iPhone", kind: "iPhone", by: .launcher, state: .suggested),
                              phone("P2", name: "客厅", kind: "iPad", by: .launcher, state: nil)]
        try shot(ExportSheetView(model: model, request: ExportSheetRequest(gameID: "0100A"), refreshOnAppear: false, sign: "appleId", layout: "shell", picked: []),
                 "2a_导出确认页_AppleID签_两台设备", width: 820, height: 700)
        model.exportPhones = [phone("E1", name: "我的 iPhone", kind: "iPhone", by: .external, cert: true, state: .latest),
                              phone("E2", name: "备用机", kind: nil, by: .external, cert: false, state: nil),
                              phone("L3", name: "客厅", kind: "iPad", by: .launcher, state: .suggested)]
        try shot(ExportSheetView(model: model, request: ExportSheetRequest(gameID: "0100A"), refreshOnAppear: false, sign: "none", layout: "shell", picked: []),
                 "2b_导出确认页_自签_三种设备行_默认都不勾", width: 820, height: 700)
        try shot(ExportSheetView(model: model, request: ExportSheetRequest(gameID: "0100A"), refreshOnAppear: false, sign: "none", layout: "shell", picked: ["E1"]),
                 "2b2_导出确认页_自签_玩家勾了一台", width: 820, height: 700)
        model.exportPhones = [phone("P1", name: "我的 iPhone", kind: "iPhone", by: .launcher, state: nil)]
        try shot(ExportSheetView(model: model, request: ExportSheetRequest(gameID: "0100C"), refreshOnAppear: false, sign: "appleId", layout: "shell", picked: []),
                 "2c_导出确认页_没做好iPhone版", width: 820, height: 700)
    }

    /// 我的证书（显式 App ID 描述文件）+ 独立 App：② 下面黄字「装一款会顶掉前一款」
    func testStandaloneExplicitProfileHint() throws {
        model.installMode = InstallModeInfo(result: ["signMode": "devcert", "signChoice": "devCert", "layout": "standalone", "recommend": "standalone", "recommendWhy": "devCertDebug",
                                                     "standaloneHint": "explicit", "standaloneHints": ["appleId": "appleId", "devCert": "explicit", "none": "external"]])
        model.devCert = DevCertStatus(imported: true, active: true, cert: nil)
        model.exportPhones = [phone("P1", name: "我的 iPhone", kind: "iPhone", by: .launcher, state: .latest)]
        try shot(ExportSheetView(model: model, request: ExportSheetRequest(gameID: "0100A"), refreshOnAppear: false, sign: "devCert", layout: "standalone", picked: []),
                 "4_导出确认页_我的证书_显式描述文件_独立App提示", width: 820, height: 700)
        try shot(ExportSheetView(model: model, request: ExportSheetRequest(gameID: "0100A"), refreshOnAppear: false, sign: "appleId", layout: "standalone", picked: []),
                 "4b_导出确认页_改选AppleID_独立App提示", width: 820, height: 700)
    }

    /// 独立 App 装好：逐台结果下面那段「之前用独立 App 装过的游戏，存档在旧 App 里……」（普通说明色）
    func testStandaloneSaveCarryShot() throws {
        model.exportFlows["0100A"] = ExportFlow(gameID: "0100A", sign: "devCert", rows: [ExportFlow.Row(device: "P1", kind: "iPhone", name: "我的 iPhone", state: .done,
                                                 next: [.key("exportsheet.phone.openApp", "甲")])], layout: "standalone")
        try shot(ExportSheetView(model: model, request: ExportSheetRequest(gameID: "0100A", results: true), refreshOnAppear: false, sign: "devCert", layout: "standalone"),
                 "5_独立App装好_存档怎么搬说明", width: 820, height: 700)
    }

    func testPerDeviceResults() throws {
        var flow = ExportFlow(gameID: "0100A", sign: "appleId", rows: [ExportFlow.Row(device: "P1", kind: "iPhone", name: "我的 iPhone"),
                                                                       ExportFlow.Row(device: "P2", kind: "iPad", name: "客厅"),
                                                                       ExportFlow.Row(device: "P3", kind: "iPhone", name: "备用机")])
        flow.rows[0].state = .done
        flow.rows[1].state = .failed; flow.rows[1].code = "shell_install_required"   // 码与原因句取作业层同一对（pack/jobs/install.py SHELL_INSTALL_FIRST / SHELL_UPDATE_FIRST）
        flow.rows[1].message = "手机上还没装 S2Arm：先点「安装 S2Arm」，装好后再把这款推到 iPhone。"
        flow.rows[2].state = .failed; flow.rows[2].code = "shell_update_required"
        flow.rows[2].message = "手机上的 S2Arm 不是这一版：先点「更新 S2Arm」，再把这款推到 iPhone。"
        model.exportFlows["0100A"] = flow
        try shot(ExportSheetView(model: model, request: ExportSheetRequest(gameID: "0100A", results: true), refreshOnAppear: false, sign: "appleId", layout: "shell"),
                 "3_逐台结果页_一台装好_没装S2Arm_S2Arm旧", width: 820, height: 700)
    }
}

/// 替身作业：记下每个请求。catalog 回三款：甲（做好 iPhone 版、新格式）、乙（没做过）、丙（做过但旧格式）；
///   updateGame 回 reasons 空 + 给定诊断；install 推到 failDevice 那台失败（shell_install_required），其余一律成功
private final class RecordingRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    private let lock = NSLock()
    private var seen: [[String: Any]] = []
    var failDevice: String?
    var updateDiagnostics: [[String: Any]] = []
    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return seen }
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        objc_sync_enter(self); defer { objc_sync_exit(self) }
        var request: [String: Any] = [:]
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { request = r }
        lock.lock(); seen.append(request); lock.unlock()
        let op = request["operation"] as? String ?? ""
        var event: [String: Any] = ["schema": 1, "taskId": request["taskId"] as? String ?? "", "type": "result", "state": "succeeded", "result": [String: Any](), "message": ""]
        switch op {
        case "catalog":
            event["result"] = ["games": [["id": "0100A", "name": "甲", "ready": true, "missing": [], "display": "1.0.0", "iphoneReady": true, "iphoneExportable": true],
                                         ["id": "0100B", "name": "乙", "ready": true, "missing": [], "display": "1.0.0"],
                                         ["id": "0100C", "name": "丙", "ready": true, "missing": [], "display": "1.0.0", "iphoneReady": true, "iphoneExportable": false]], "keys": [:]]
        case "updateGame":
            event["result"] = ["gameId": request["gameId"] ?? "", "reasons": [String]()]
            event["diagnostics"] = updateDiagnostics
        case "install" where request["device"] as? String == failDevice && failDevice != nil:
            event["state"] = "failed"; event["message"] = "手机上还没装 S2Arm"
            event["diagnostics"] = [["severity": "error", "code": "shell_install_required", "message": "手机上还没装 S2Arm"]]
        default: break
        }
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(0) }
        return Handle()
    }
}
