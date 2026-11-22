// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

/// 0.6.4「更新 / 导出」人类走查的逐步截图（六个玩家角色，从打开启动器走到装上设备；手机上那几步只有文字，不在这里出图）。
///   全部离屏：NSHostingView 不进任何窗口、appearance = darkAqua，整个启动器主窗口内容（1280×800）或整个 sheet（820×700）。
///   S2A_WALK_SHOT=<目录> 时存 PNG，按「角色_步骤_说明.png」命名；不给也照跑，只核每张画出了东西。每步的界面状态与玩家那一刻一致（作业结果按作业层原句给）
@MainActor final class MacWalkthroughTests: XCTestCase {
    private var root: URL!
    private var model: S2ArmLauncherModel!
    private var runner: WalkRunner!
    private var savedLanguage: String?

    override func setUp() async throws {
        _ = NSApplication.shared
        savedLanguage = UserDefaults.standard.string(forKey: "appLanguage")
        UserDefaults.standard.set("zh", forKey: "appLanguage")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-walk-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        runner = WalkRunner()
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedLanguage, forKey: "appLanguage")
        try? FileManager.default.removeItem(at: root)
    }

    static let gid = "0100A9B01D3D0000"

    /// 一个角色一个新启动器：游戏库里这一款（flags 同 catalog 作业），先把主窗口画一遍让启动时的读作业跑完，再摆这一步的状态
    private func launch(_ game: [String: Any]) async throws {
        runner.game = game
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "walk"), runner: runner))
        model.runAlert = { _ in .alertFirstButtonReturn }
        model.refresh()
        for _ in 0..<300 where model.games.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        _ = try render(AnyView(S2ArmAppleRootView(model: model, brand: "S2Arm")), width: 1280, height: 800)   // 启动：读设置、环境检查…
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        model.selectedID = Self.gid
    }

    private func render(_ view: AnyView, width: CGFloat, height: CGFloat) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(view.s2aLocalized().frame(width: width, height: height)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12)).environment(\.colorScheme, .dark)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func shot(_ view: some View, _ name: String, sheet: Bool = false) throws {
        let rep = try render(AnyView(view), width: sheet ? 820 : 1280, height: sheet ? 700 : 800)
        var ink = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 6) { for x in stride(from: 0, to: rep.pixelsWide, by: 6) {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent + c.greenComponent + c.blueComponent > 0.9 { ink += 1 } } }
        XCTAssertGreaterThan(ink, 100, "\(name)：离屏画出来是空的")
        if let dir = ProcessInfo.processInfo.environment["S2A_WALK_SHOT"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    private func home(_ name: String) throws { try shot(S2ArmAppleRootView(model: model, brand: "S2Arm"), name) }
    private func sheet(_ name: String, sign: String, layout: String = "shell", picked: Set<String> = [], results: Bool = false, preselect: String? = nil) throws {
        try shot(ExportSheetView(model: model, request: ExportSheetRequest(gameID: Self.gid, preselect: preselect, results: results), refreshOnAppear: false,
                                 sign: sign, layout: layout, picked: picked), name, sheet: true)
    }

    private func phone(_ device: String, _ name: String, kind: String?, by: PhoneOverview.InstalledBy?, installed: Bool = true, shellCurrent: Bool = true,
                       online: String? = "usb", cert: Bool? = nil, state: PhoneOverview.GameState? = nil, free: Bool = true) -> PhoneOverview.Phone {
        var p = PhoneOverview.Phone(device: device, name: name, installed: installed, shellCurrent: shellCurrent, bundleId: installed ? "com.s2arm.app" : "",
                                    signedAt: installed ? Date().addingTimeInterval(-86400) : nil, free: free,
                                    expiresAtEstimate: installed ? Date().addingTimeInterval(6 * 86400) : nil, online: .some(online), lastSeen: nil,
                                    signMode: by == .external ? .external : installed ? .appleId : nil,
                                    games: state.map { [PhoneOverview.Game(gameId: Self.gid, state: $0, reasons: [], dataOnComputer: true)] } ?? [], installedBy: by)
        p.kind = kind; p.certImported = cert
        return p
    }

    private func flow(sign: String, _ rows: [(String, String, String, ExportFlow.State)]) -> ExportFlow {
        ExportFlow(gameID: Self.gid, sign: sign, rows: rows.map { ExportFlow.Row(device: $0.0, kind: $0.1, name: $0.2, state: $0.3) })
    }

    private func exportSession(_ phase: JobSession.Phase, stage: String) -> JobSession {
        var run = ExportRun(platforms: [.ios])
        if phase == .finished(.completed) { run.outcomes[.ios] = .init(state: .completed, appBytes: 48_000_000, packBytes: 1_200_000_000, seconds: 312) }
        var s = JobSession(kind: .export, gameID: Self.gid, name: "Chants of Sennaar", phase: phase, export: run)
        s.stage = stage; s.message = stage; s.stages = ["检查游戏输入", "一键出包", stage]
        return s
    }

    static let fresh: [String: Any] = ["id": gid, "name": "Chants of Sennaar", "ready": false, "missing": [], "display": "1.0.2"]   // 只在手机上玩：没出过 Mac 版
    static let ready: [String: Any] = fresh.merging(["iphoneReady": true, "iphoneExportable": true]) { $1 }

    // ① 第一次用、只有免费 Apple ID 的新手：手机上没装 S2Arm，这款从没做过 iPhone 版
    func testRole1FreshFreeAppleID() async throws {
        try await launch(Self.fresh)
        let p = phone("U1", "小明的 iPhone", kind: "iPhone", by: nil, installed: false)
        model.phoneOverview = PhoneOverview(phones: [p])
        model.installMode = InstallModeInfo(result: ["signMode": "appleId", "signChoice": "appleId", "layout": "shell", "recommend": "shell", "recommendWhy": "appleId"])
        model.appleAccount = AppleAccount(account: "")
        model.devCert = DevCertStatus(imported: false, active: false, cert: nil)
        try home("1_01_首页_选中这款")
        model.exportPhones = [p]
        try sheet("1_02_点导出_确认页_没登录_没装S2Arm", sign: "appleId")
        try shot(AppleLoginSheet(model: model), "1_03_点登录AppleID_登录面板", sheet: true)
        model.appleAccount = AppleAccount(account: "xiaoming@example.com", team: "TEAM-XM", teamName: "Xiaoming (Personal Team)")
        try sheet("1_04_登录好_回到确认页", sign: "appleId")
        model.consoleDevice = "U1"; model.selectedID = S2ArmLauncherModel.consoleID
        try home("1_05_点先装S2Arm_首位S2Arm卡")
        var upd = JobSession(kind: .installUpdate, gameID: nil, name: "更新 iPhone 上的 S2Arm", phase: .finished(.completed))
        upd.started = Date().addingTimeInterval(-95); upd.ended = Date()
        model.phoneSession = upd
        model.phoneOutcome = PhoneOutcome(device: "iPhone「小明的 iPhone」", version: "0.6.4")
        model.installTrustName = "Apple Development: xiaoming@example.com (TEAM-XM)"
        model.shellFirstInstall = true
        try home("1_06_安装S2Arm完成")
        model.phoneSession = nil; model.phoneOutcome = nil
        let p2 = phone("U1", "小明的 iPhone", kind: "iPhone", by: .launcher)
        model.phoneOverview = PhoneOverview(phones: [p2]); model.exportPhones = [p2]
        model.selectedID = Self.gid
        try home("1_07_回到这款")
        try sheet("1_08_再点导出_勾上这台", sign: "appleId", picked: ["U1"])
        model.exportAfterPack[Self.gid] = ExportPlan(sign: "appleId", devices: [.init(key: "U1", kind: "iPhone", name: "小明的 iPhone")])
        model.session = exportSession(.running, stage: "一键出包：翻译程序、预编着色器")
        try home("1_09_开始_先在电脑上做iPhone版")
        model.session = exportSession(.finished(.completed), stage: "清理出包中间产物")
        try home("1_10_做好了_接着装到勾的设备")
        model.exportAfterPack[Self.gid] = nil
        var f = flow(sign: "appleId", [("U1", "iPhone", "小明的 iPhone", .done)])
        f.rows[0].next = [.key("install.done.open", ""), .key("install.done.trustNamed", "Apple Development: xiaoming@example.com (TEAM-XM)", "iPhone"), .key("install.done.free", "")]
        model.exportFlows[Self.gid] = f; model.session = nil
        try sheet("1_11_右上角胶囊点开_已装到这台", sign: "appleId", results: true)
    }

    // ② 用买来的 P12（分发证书）：还没导入证书
    func testRole2DistributionP12() async throws {
        try await launch(Self.ready)
        let p = phone("P2", "我的 iPhone", kind: "iPhone", by: nil, installed: false, free: false)
        model.phoneOverview = PhoneOverview(phones: [p]); model.exportPhones = [p]
        model.installMode = InstallModeInfo(result: ["signMode": "appleId", "signChoice": "devCert", "layout": "shell", "recommendWhy": "unknown"])
        model.appleAccount = AppleAccount(account: "")
        model.devCert = DevCertStatus(imported: false, active: false, cert: nil)
        try home("2_01_首页_选中这款")
        try sheet("2_02_点导出_我的证书还不能选", sign: "appleId")
        try shot(DevCertSheet(model: model), "2_03_点导入证书_导入面板", sheet: true)
        model.devCert = DevCertStatus(imported: true, active: true, cert: nil)
        model.installMode = InstallModeInfo(result: ["signMode": "devcert", "signChoice": "devCert", "layout": "standalone", "distribution": true,
                                                     "recommend": "standalone", "recommendWhy": "distribution"])
        try sheet("2_04_导入好_选我的证书_独立App_勾上", sign: "devCert", layout: "standalone", picked: ["P2"])
        model.phoneOutcome = PhoneOutcome(device: "iPhone「我的 iPhone」", app: StandaloneApp(["appName": "Chants of Sennaar", "signMode": "devCert"]))
        var f = flow(sign: "devCert", [("P2", "iPhone", "我的 iPhone", .done)])
        f.rows[0].next = model.phoneNextSteps(sign: "devCert", gameID: Self.gid)
        model.exportFlows[Self.gid] = f
        try sheet("2_05_已装到这台", sign: "devCert", layout: "standalone", results: true)
    }

    // ③ 用 AltStore / SideStore 装了 S2Arm（自签）
    func testRole3AltStore() async throws {
        try await launch(Self.ready)
        let p = phone("A3", "我的 iPhone", kind: "iPhone", by: .external, cert: false)
        model.phoneOverview = PhoneOverview(phones: [p]); model.exportPhones = [p]
        model.installMode = InstallModeInfo(result: ["signMode": "appleId", "signChoice": "external", "layout": "shell", "recommend": "shell", "recommendWhy": "external"])
        model.appleAccount = AppleAccount(account: "")
        model.devCert = DevCertStatus(imported: false, active: false, cert: nil)
        try home("3_01_首页_选中这款")
        try sheet("3_02_点导出_自签_没导入证书", sign: "none")
        try sheet("3_03_勾上这台", sign: "none", picked: ["A3"])
        model.installOpenToFinish = true; model.installTrustName = ""
        var f = flow(sign: "none", [("A3", "iPhone", "我的 iPhone", .done)])
        f.rows[0].next = model.phoneNextSteps(sign: "none", gameID: Self.gid)
        model.exportFlows[Self.gid] = f
        try sheet("3_04_已装到这台", sign: "none", results: true)
    }

    // ④ 同时有 iPhone 和 iPad
    func testRole4PhoneAndPad() async throws {
        try await launch(Self.ready.merging(["iphoneInstall": ["at": Date().timeIntervalSince1970 - 86400 * 3, "free": true, "deviceKey": "I4"]]) { $1 })
        let a = phone("I4", "我的 iPhone", kind: "iPhone", by: .launcher, state: .suggested)
        let b = phone("D4", "客厅", kind: "iPad", by: .launcher, online: "network")
        model.phoneOverview = PhoneOverview(phones: [a, b]); model.exportPhones = [a, b]
        model.installMode = InstallModeInfo(result: ["signMode": "appleId", "signChoice": "appleId", "layout": "shell", "recommend": "shell", "recommendWhy": "appleId"])
        model.appleAccount = AppleAccount(account: "player@example.com")
        model.devCert = DevCertStatus(imported: false, active: false, cert: nil)
        try home("4_01_首页_选中这款")
        try sheet("4_02_点导出_两台都勾上", sign: "appleId", picked: ["I4", "D4"])
        var run = JobSession(kind: .install, gameID: Self.gid, name: "Chants of Sennaar")
        run.stage = "把这款的资源推进 iPhone（只推变了的文件；第一次大游戏要几分钟）"
        model.phoneSession = run
        model.exportFlows[Self.gid] = flow(sign: "appleId", [("I4", "iPhone", "我的 iPhone", .running), ("D4", "iPad", "客厅", .queued)])
        try sheet("4_03_开始_一台一台装", sign: "appleId", results: true)
        model.phoneSession = nil
        model.installOpenToFinish = true; model.installTrustName = "Apple Development: player@example.com (TEAM-PL)"
        var f = flow(sign: "appleId", [("I4", "iPhone", "我的 iPhone", .done), ("D4", "iPad", "客厅", .done)])
        f.rows[0].next = model.phoneNextSteps(sign: "appleId", gameID: Self.gid); f.rows[1].next = f.rows[0].next
        model.exportFlows[Self.gid] = f
        try sheet("4_04_两台都装好", sign: "appleId", results: true)
    }

    // ⑤ 手机没连、只想导出文件
    func testRole5FolderOnly() async throws {
        try await launch(Self.ready)
        let p = phone("O5", "我的 iPhone", kind: "iPhone", by: .external, online: nil, cert: true, state: .latest)
        model.phoneOverview = PhoneOverview(phones: [p]); model.exportPhones = [p]
        model.installMode = InstallModeInfo(result: ["signMode": "appleId", "signChoice": "external", "layout": "shell", "recommend": "shell", "recommendWhy": "external"])
        model.appleAccount = AppleAccount(account: "")
        model.devCert = DevCertStatus(imported: false, active: false, cert: nil)
        try home("5_01_首页_选中这款")
        try sheet("5_02_点导出_没连着_都不勾", sign: "none")
        model.exportFlows[Self.gid] = ExportFlow(gameID: Self.gid, sign: "none", rows: [])
        var s = JobSession(kind: .install, gameID: Self.gid, name: "Chants of Sennaar", phase: .finished(.completed))
        s.started = Date().addingTimeInterval(-20); s.ended = Date()
        model.phoneSession = s; model.selfSigning = true
        model.phoneOutcome = PhoneOutcome(exportFolder: "/Users/player/S2Arm 游戏库/S2Arm 游戏包", exportGames: 1, exportBytes: 1_250_000_000,
                                          exportFresh: ["Chants of Sennaar.img"])
        try sheet("5_03_导出到文件夹_导出好了", sign: "none", results: true)
    }

    // ⑥ 游戏旧了想更新（建议更新）：手机上装着旧版
    func testRole6Update() async throws {
        try await launch(Self.ready.merging(["iphoneInstall": ["at": Date().timeIntervalSince1970 - 86400 * 2, "free": true, "deviceKey": "S6"]]) { $1 })
        let p = phone("S6", "我的 iPhone", kind: "iPhone", by: .launcher, state: .suggested)
        model.phoneOverview = PhoneOverview(phones: [p]); model.exportPhones = [p]
        model.installMode = InstallModeInfo(result: ["signMode": "appleId", "signChoice": "appleId", "layout": "shell", "recommend": "shell", "recommendWhy": "appleId"])
        model.appleAccount = AppleAccount(account: "player@example.com")
        model.devCert = DevCertStatus(imported: false, active: false, cert: nil)
        model.updateHints = [Self.gid: ["shader", "rewriter"]]
        try home("6_01_首页_建议更新")
        model.gameUpdates[Self.gid] = GameUpdateRun()
        try home("6_02_点更新这款_按钮变进度")
        model.updateHints = [:]
        model.gameUpdates[Self.gid] = GameUpdateRun(running: false)
        try home("6_03_更新完_无需更新_提示手机上要再导一次")
        try sheet("6_04_点导出_勾上装着旧版的那台", sign: "appleId", picked: ["S6"])
        model.installOpenToFinish = true; model.installTrustName = ""
        var f = flow(sign: "appleId", [("S6", "iPhone", "我的 iPhone", .done)])
        f.rows[0].next = model.phoneNextSteps(sign: "appleId", gameID: Self.gid)
        model.exportFlows[Self.gid] = f
        try sheet("6_05_已装到这台", sign: "appleId", results: true)
    }
}

/// 假作业进程：catalog 回这一款（角色给的 flags），其余作业回空结果
private final class WalkRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    var game: [String: Any] = [:]
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        objc_sync_enter(self); defer { objc_sync_exit(self) }
        var request: [String: Any] = [:]
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { request = r }
        var result: [String: Any] = [:]
        if request["operation"] as? String == "catalog" { result = ["games": [game], "keys": [:]] }
        let event: [String: Any] = ["schema": 1, "taskId": request["taskId"] as? String ?? "", "type": "result", "state": "succeeded", "result": result, "message": ""]
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(0) }
        return Handle()
    }
}
