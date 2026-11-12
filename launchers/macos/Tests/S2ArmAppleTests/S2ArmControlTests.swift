import XCTest
import AppKit
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

// 新前端（S2Arm × NX2Apple，11-07 起发版缺省）的控制口命令表：协议同旧启动器，s2armctl 不改就能连。期望按旧启动器 / s2armctl 的约定手写；
//   这里只测不起作业的分支（参数不对、即将上线、不支持、状态字段），起作业的命令走的是界面按钮背后的同一个模型方法（S2ArmLauncherModel）
@MainActor final class S2ArmControlTests: XCTestCase {
    private var root: URL!
    private var model: S2ArmLauncherModel!
    private var control: S2ArmControl!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-ctl-apple-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("logs/jobs"), withIntermediateDirectories: true)
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path)))
        control = try S2ArmControl(model: model) { XCTFail($0) }
    }
    override func tearDown() async throws { control.stop(); try? FileManager.default.removeItem(at: root) }

    func testDisplayNeedsAGame() async {
        let (code, body) = await post("/display", ["settings": ["enhance": true]])
        XCTAssertEqual(code, 400); XCTAssertEqual(body["error"] as? String, "缺 gameId")
    }

    private func post(_ path: String, _ body: [String: Any] = [:]) async -> (Int, [String: Any]) {
        let r = await control.handle(ControlRequest(method: "POST", path: path, headers: [:], body: body))
        return (r.code, (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:])
    }

    func testRejectsBadArgumentsWithoutStartingJobs() async {
        for t in ["android", "harmony", "ohos"] {
            let (code, b) = await post("/build", ["gameId": "nope", "target": t])
            XCTAssertEqual(code, 400, "没有这款先报 400（\(t)）"); _ = b
        }
        do { let c = await post("/keys").0; XCTAssertEqual(c, 400) }
        do { let c = await post("/games", ["paths": []]).0; XCTAssertEqual(c, 400) }
        do { let c = await post("/prepare", ["gameId": "nope"]).0; XCTAssertEqual(c, 400) }
        do { let c = await post("/ipa", ["gameId": "nope"]).0; XCTAssertEqual(c, 400) }
        do { let c = await post("/install", ["gameId": "nope"]).0; XCTAssertEqual(c, 400) }
        do { let c = await post("/target", ["productType": "iPhone17,1", "os": 26]).0; XCTAssertEqual(c, 400, "机型表没探过不能选") }
        do { let c = await post("/diagnostics", ["action": "x"]).0; XCTAssertEqual(c, 400) }
        do { let c = await post("/cancel", ["taskId": "t"]).0; XCTAssertEqual(c, 400, "没有在跑的作业") }
        do { let c = await post("/retry", ["taskId": "t"]).0; XCTAssertEqual(c, 400) }
        do { let c = await post("/fonts", ["path": ""]).0; XCTAssertEqual(c, 409) }
        do { let c = await post("/onboarding", ["action": "finish"]).0; XCTAssertEqual(c, 200, "新界面没有引导页：忽略、不报错（旧剧本照跑）") }
        do { let c = await post("/nope").0; XCTAssertEqual(c, 404) }
        XCTAssertNil(model.session, "上面这些一个作业都没起")
    }

    func testHelpListsTheSameCallsS2armctlUses() async {
        let r = await control.handle(ControlRequest(method: "GET", path: "/help", headers: [:], body: [:]))
        let calls = ((try? JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["endpoints"] as? [[String: String]] ?? []).compactMap { $0["call"] }
        for c in ["GET /state", "GET /targets", "POST /keys {path}", "POST /games {paths:[…]}", "POST /build {gameId, target, spaceOverride?}",
                  "POST /installCheck {gameId}", "POST /install {gameId, acceptDropped?, acceptNoBackup?, acceptStale?}", "POST /delete {gameId}", "POST /launch {gameId}"] {
            XCTAssertTrue(calls.contains(c), c)
        }
    }

    func testStateHasTheFieldsS2armctlReadsAndJournalTasks() throws {
        try JSONSerialization.data(withJSONObject: ["id": "t1", "operation": "ipa", "gameId": "g", "state": "failed", "started": 1.0,
                                                     "diagnostics": [["code": "signing_failed", "summary": "s", "suggestion": "x", "logPath": "/tmp/l"]]])
            .write(to: root.appendingPathComponent("logs/jobs/t1.json"))
        let s = control.state()
        for k in ["selection", "showOnboarding", "onboardingStep", "keyStatus", "hasImportedKeys", "environmentReady", "checkingEnvironment",
                  "checks", "games", "tasks", "queue", "notice", "error", "installReadiness", "waitingForAccess", "cachedAt", "windows", "overlays"] {
            XCTAssertNotNil(s[k], k)
        }
        let t = (s["tasks"] as? [[String: Any]])?.first
        XCTAssertEqual(t?["id"] as? String, "t1"); XCTAssertEqual(t?["operation"] as? String, "ipa")
        XCTAssertEqual(((t?["diagnostics"] as? [[String: Any]])?.first)?["code"] as? String, "signing_failed")
    }

    func testAIControlSwitchPersistsAndStopsPort() throws {
        control.stop(); control = nil
        model.setAIControl(true)
        XCTAssertTrue(model.aiControl)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("apple-frontend/launch-settings.json"))) as? [String: Any]
        XCTAssertEqual(saved?["aiControl"] as? Bool, true)
        let end = Date().addingTimeInterval(5)
        while Date() < end && !FileManager.default.fileExists(atPath: root.appendingPathComponent("control.json").path) { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("control.json").path), "开了就写 control.json")
        model.setAIControl(false)
        XCTAssertFalse(model.aiControl)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("control.json").path), "关了就删 control.json")
        control = try S2ArmControl(model: model) { XCTFail($0) }
    }
}

/// #272 连着多台时用哪台：选过且还连着的 → 它；选过但不在 → 没有（不替玩家换成别的，11-11 续签时 iPad 被装上）；没选过 → 有线第一台，否则第一台。期望手写
final class ExportDevicePickTests: XCTestCase {
    private let phone = ["id": "A", "name": "我的 iPhone", "wired": false] as [String: Any]
    private let pad = ["id": "B", "name": "iPad", "wired": true] as [String: Any]
    func testChosenWiredFirstOrNone() {
        XCTAssertEqual(S2ArmLauncherModel.pickDevice([phone, pad], chosen: "A")?["id"] as? String, "A")
        XCTAssertEqual(S2ArmLauncherModel.pickDevice([phone, pad], chosen: nil)?["id"] as? String, "B")
        XCTAssertNil(S2ArmLauncherModel.pickDevice([phone, pad], chosen: "gone"))
        XCTAssertNil(S2ArmLauncherModel.pickDevice([phone], chosen: "gone"))
        XCTAssertNil(S2ArmLauncherModel.pickDevice([], chosen: "A"))
    }
}
