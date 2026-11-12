import XCTest
import AppKit
import SwiftUI
@testable import S2ArmLauncher

// 11-02 用户体验线：AI 代劳（统一出包入口、装机前清单进状态快照、连接到 Claude）。期望按接口约定手写
@MainActor final class AIConnectTests: XCTestCase {
    private func tempRoot() -> URL {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-ai-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true); return r
    }
    private func body(_ d: Data) -> [String:Any] { (try? JSONSerialization.jsonObject(with: d) as? [String:Any]) ?? [:] }

    // 安卓、鸿蒙回 409「即将上线，敬请期待」且不发起任何任务；不认识的目标、没有的游戏回 400
    func testBuildEndpointTargets() throws {
        _ = NSApplication.shared
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root)
        store.games = [.init(id: "0100535012974000", name: "Hades", display: "1.0", packages: [], hidden: false, compatibility: "experimental")]
        let server = try ControlServer(store: store); ControlServer.shared = server
        defer { ControlServer.stop(store: store) }
        func post(_ b: [String:Any]) -> (Int, [String:Any]) { let r = server.handle(Request(method: "POST", path: "/build", headers: [:], body: b)); return (r.0, body(r.2)) }
        for t in ["android", "harmony", "ohos"] {
            let (code, b) = post(["gameId": "0100535012974000", "target": t])
            XCTAssertEqual(code, 409, t); XCTAssertEqual(b["error"] as? String, "即将上线，敬请期待"); XCTAssertEqual(b["comingSoon"] as? Bool, true)
        }
        XCTAssertEqual(post(["gameId": "0100535012974000", "target": "xbox"]).0, 400)
        XCTAssertEqual(post(["gameId": "nope", "target": "ios"]).0, 400)
        XCTAssertTrue(store.tasks.isEmpty); XCTAssertNil(store.executionTask)
        let help = body(server.handle(Request(method: "GET", path: "/help", headers: [:], body: [:])).2)
        let calls = (help["endpoints"] as? [[String:String]] ?? []).compactMap { $0["call"] }
        XCTAssertTrue(calls.contains("POST /build {gameId, target}")); XCTAssertTrue(calls.contains("POST /installCheck {gameId}"))
    }

    // 后端 readiness 的结果原样进 GET /state 的 installReadiness（AI 读它）
    func testInstallReadinessRoundTripsIntoState() throws {
        _ = NSApplication.shared
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root)
        let raw: [String:Any] = ["gameId": "g1", "ready": false, "device": "测试设备2", "account": "我",
            "items": [["id": "appleId", "ok": true, "waiting": false, "title": "Xcode 里已登录 Apple ID", "detail": "", "who": "human"],
                      ["id": "developerMode", "ok": false, "waiting": false, "title": "iPhone 已打开开发者模式", "detail": "打开开发者模式", "who": "human"]]]
        let rd = InstallReadiness(raw)
        XCTAssertEqual(rd.items.map(\.id), ["appleId", "developerMode"]); XCTAssertEqual(rd.account, "我")
        XCTAssertEqual(InstallReadiness(rd.json), rd)
        store.installReadiness = rd
        let server = try ControlServer(store: store); ControlServer.shared = server
        defer { ControlServer.stop(store: store) }
        let st = server.state()["installReadiness"] as? [String:Any]
        XCTAssertEqual(st?["gameId"] as? String, "g1"); XCTAssertEqual((st?["items"] as? [[String:Any]])?.count, 2)
    }

    // 装机清单页：中英文都能渲染、清单文案都有英文；设了 S2ARM_GUI_PREVIEW_DIR 就把画面存下来给人看（数据取 11-02 本机真读数：已登录、连着 3 台、还没出包）
    func testInstallChecklistRendersAndIsTranslated() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root)
        store.games = [.init(id: "01008FC00D964000", name: "SAMURAI SHODOWN", display: "1.40", packages: [], hidden: false, compatibility: "experimental")]
        store.installGuideGame = "01008FC00D964000"
        func it(_ id: String, _ ok: Bool, _ waiting: Bool, _ title: String, _ detail: String) -> InstallCheckItem { .init(id: id, title: title, detail: detail, who: "human", ok: ok, waiting: waiting) }
        store.installReadiness = InstallReadiness(gameId: "01008FC00D964000", items: [
            it("package", false, false, "这款游戏的 iPhone 版已经做好", "还没做好：先做 iPhone 版，做好后这里自动打勾。"),
            it("appleId", true, false, "Xcode 里已登录 Apple ID", ""),
            it("connected", false, false, "iPhone 已用数据线连上", "连着不止一台 iPhone / iPad：只留要装的那一台。"),
            it("trusted", false, true, "iPhone 已信任这台 Mac", ""),
            it("developerMode", false, true, "iPhone 已打开开发者模式", "")], ready: false, account: "示例账号")
        store.installWhenReady = true
        store.installCheckStarted = Date()   // 页面的定时检查不在单测里真起后台任务
        let previous = Localization.preference
        defer { Localization.preference = previous }
        for language in [AppLanguage.simplifiedChinese, .english] {
            Localization.preference = language
            let view = NSHostingView(rootView: InstallGuideView().environmentObject(store))
            view.frame = NSRect(x: 0, y: 0, width: 600, height: 540); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png: Data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            if let dir = ProcessInfo.processInfo.environment["S2ARM_GUI_PREVIEW_DIR"] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("install-checklist-\(language.rawValue).png"))
            }
        }
        Localization.preference = .english
        for text in InstallGuideView.pendingItems + ["下面几项齐了就能装，这里每隔几秒自动检查一次。", "齐了会自动开始装", "开始装", "其他安装方式：AltStore",
                     "还没做好：先做 iPhone 版，做好后这里自动打勾。", "打开 Xcode →「设置」→「账户」，点左下角「+」，登录你的 Apple ID（免费的就可以）。",
                     "连着不止一台 iPhone / iPad：只留要装的那一台。", "用数据线把 iPhone 连到这台 Mac，并解锁手机。", "在 iPhone 上点「信任」，再输入手机的锁屏密码。",
                     "在 iPhone 上打开「设置 → 隐私与安全性 → 开发者模式」，按提示重启手机；重启后解锁，这里会自动打勾。"] {
            XCTAssertNotEqual(L(text), text)
        }
    }

    // 11-02 维护者：导出默认一个都不勾；顺序 iPhone / iPad、macOS、安卓、鸿蒙；不勾不能导出；勾选下次打开还在；未开放的勾不上
    func testExportSelectionDefaultsEmptyAndPersists() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root)
        XCTAssertEqual(BuildPlatform.allCases.map(\.name), [L("iPhone / iPad"), "macOS", L("安卓"), L("鸿蒙")])
        XCTAssertEqual(store.exportPicked, [])
        let game = Game(id: "g", name: "G", display: "1.0", packages: [], hidden: false, compatibility: "experimental")
        store.games = [game]; store.exportTargets(game)
        XCTAssertNil(store.executionTask); XCTAssertTrue(store.queue.isEmpty); XCTAssertTrue(store.tasks.isEmpty)   // 一个不勾：什么都不发起
        store.toggleExport(.android); store.toggleExport(.ohos)
        XCTAssertEqual(store.exportPicked, [])   // 未开放的勾不上
        store.toggleExport(.mac); store.toggleExport(.ios)
        XCTAssertEqual(store.exportPicked, [.ios, .mac])   // 按页面顺序，不按点击顺序
        XCTAssertEqual(Store(privateRoot: root).exportPicked, [.ios, .mac])   // 重开还在
        store.toggleExport(.ios)
        XCTAssertEqual(store.exportPicked, [.mac])
    }

    // 复制给 AI 的提示词：带内置操作手册和命令行工具的路径、先问 / 停下 / 底线；跟着界面语言；非缺省数据目录带 --data-root
    func testAIPromptPointsToSkillAndTool() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root.appendingPathComponent("data"))
        let previous = Localization.preference; defer { Localization.preference = previous }
        Localization.preference = .simplifiedChinese
        let zh = store.aiHandoffText
        XCTAssertTrue(zh.contains(store.resources.appendingPathComponent("skill/s2arm-operator/SKILL.md").path))
        XCTAssertTrue(zh.contains(store.resources.appendingPathComponent("s2armctl").path))
        XCTAssertTrue(zh.contains("--data-root '" + root.appendingPathComponent("data").path + "'"))
        for need in ["start", "next", "停下来", "删除任何东西前先问我"] { XCTAssertTrue(zh.contains(need), need) }
        XCTAssertFalse(zh.contains("Claude Code 可直接"))
        Localization.preference = .english
        XCTAssertTrue(store.aiHandoffText.hasPrefix("Please use S2Arm"))
        // 手册在仓库里真有、带 skill 头，提示词指向的文件名对得上
        let skill = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("skill/s2arm-operator/SKILL.md")
        let text = try String(contentsOf: skill, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\nname: s2arm-operator\n"))
        for need in ["还没装 S2Arm", "遇到问题怎么办", "install-check", "diag export"] { XCTAssertTrue(text.contains(need), need) }
        XCTAssertFalse(text.contains("--compat"), "兼容模式重出已拆（11-07）：手册不再指它")
    }

    // 数据目录两种写法都认；整体写法（s2armctl 拉起 App 用的）优先。11-02 走查：分开写在 --control 后面会让 App 不建窗口
    func testDataRootArgumentForms() {
        XCTAssertEqual(Store.dataRoot(from: ["S2Arm", "--control", "--data-root=/d/数据 目录"])?.path, "/d/数据 目录")
        XCTAssertEqual(Store.dataRoot(from: ["S2Arm", "--data-root", "/d/x", "--control"])?.path, "/d/x")
        XCTAssertNil(Store.dataRoot(from: ["S2Arm", "--control"]))
        XCTAssertNil(Store.dataRoot(from: ["S2Arm", "--data-root"]))
    }

    // 游戏库可放 APFS / exFAT（11-02 / 11-10）：选库时读所在卷格式；普通文件夹、还不存在的子路径都按上级卷读（FAT32 等判定在后端单测打桩）
    func testLibraryVolumeFormat() throws {
        let tmp = FileManager.default.temporaryDirectory
        XCTAssertEqual(Store.volumeFormat(tmp), "apfs")
        XCTAssertEqual(Store.volumeFormat(tmp.appendingPathComponent("还没建/游戏库")), "apfs")
    }
}
