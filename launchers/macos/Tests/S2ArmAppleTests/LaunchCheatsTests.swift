// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

/// 启动设置页的金手指（11-12，作业层 pack/jobs/cheats.py）：假作业执行器回 community 结果，模型读出列表（来源 / 作者 / 版本不对的原因），
/// 开关与导入走 communitySave、请求带 cheats / cheatsImport 键。期望值手写
@MainActor final class LaunchCheatsTests: XCTestCase {
    private var root: URL!
    private var runner: CheatsRunner!
    private var model: S2ArmLauncherModel!
    private let gid = "01001B300B9BE000"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let jobs = root.appendingPathComponent("Jobs")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try Data().write(to: jobs.appendingPathComponent("main.py"))
        runner = CheatsRunner()
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testListToggleAndImport() async throws {
        let (_, _, list, reason) = try await model.launchSettingsAll(gid)
        XCTAssertEqual(runner.requests.last?["operation"] as? String, "community")
        XCTAssertEqual(reason, "")
        XCTAssertEqual(list.map(\.id), ["2607A74F5DF7754C.nxcheats.txt/Infinite Health", "old.txt/A"])
        XCTAssertEqual(list.map(\.fromLibrary), [true, false])
        XCTAssertEqual([list[0].repo, list[0].author, list[0].license, "\(list[0].ok)"], ["bad1dea/NXCheats", "bad1dea", "MIT", "true"])
        XCTAssertEqual(["\(list[1].ok)", list[1].reason], ["false", "版本不对：金手指是 1111111111111111，这份游戏是 2607A74F5DF7754C。"])

        _ = try await model.launchSettingsAll(gid, cheats: ["2607A74F5DF7754C.nxcheats.txt/Infinite Health": true])
        let save = try XCTUnwrap(runner.requests.last)
        XCTAssertEqual(save["operation"] as? String, "communitySave")
        XCTAssertEqual(save["cheats"] as? [String: Bool], ["2607A74F5DF7754C.nxcheats.txt/Infinite Health": true])

        _ = try await model.launchSettingsAll(gid, cheatsImport: ["/tmp/a.txt"])
        XCTAssertEqual(runner.requests.last?["cheatsImport"] as? [String], ["/tmp/a.txt"])
    }

    /// 上次开着某几条时异常退出（11-13 维护者改定：不问）：作业层已关掉；开始游戏照常开局，同时通知关了什么、回 crashAnswer=ack 清记录
    func testCrashNoticeDoesNotBlockPlay() async throws {
        runner.crashed = ["Infinite Health", "One Hit Kill"]
        let game = GameSummary(id: gid, name: "D3")
        model.play(game, uiLanguage: nil)
        for _ in 0..<200 where !runner.requests.contains(where: { $0["operation"] as? String == "launch" }) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.crashPrompt?.names, ["Infinite Health", "One Hit Kill"])                       // 通知内容
        XCTAssertEqual(runner.requests.first { $0["crashAnswer"] != nil }?["crashAnswer"] as? String, "ack")
        XCTAssertTrue(runner.requests.contains { $0["operation"] as? String == "launch" })               // 照常开局
    }
}

/// 假作业执行器：community / communitySave 都回同一份带金手指的结果，记下请求
private final class CheatsRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    var requests: [[String: Any]] = []
    var crashed: [String] = []

    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        let url = URL(fileURLWithPath: try XCTUnwrap(arguments.last))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        DispatchQueue.main.async { [self] in
            requests.append(request)
            let cheats: [String: Any] = ["reason": "", "items": [
                ["key": "2607A74F5DF7754C.nxcheats.txt/Infinite Health", "name": "Infinite Health", "enabled": false, "ok": true, "reason": "",
                 "from": "library", "repo": "bad1dea/NXCheats", "author": "bad1dea", "license": "MIT", "status": ""],
                ["key": "old.txt/A", "name": "A", "enabled": false, "ok": false, "reason": "版本不对：金手指是 1111111111111111，这份游戏是 2607A74F5DF7754C。",
                 "from": "player", "repo": "", "author": "", "license": "", "status": ""]]]
            let event: [String: Any] = ["schema": 1, "taskId": request["taskId"]!, "type": "result", "state": "succeeded",
                                        "result": ["mac": [:], "graphics": [], "cheats": cheats,
                                                   "crashed": crashed.map { ["kind": "cheat", "key": "f.txt/" + $0, "name": $0] }], "message": ""]
            onLine(try! JSONSerialization.data(withJSONObject: event))
            onExit(0)
        }
        return Handle()
    }
}
