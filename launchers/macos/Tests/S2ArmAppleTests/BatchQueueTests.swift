// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// 批量出包的两条队列（启动器剃刀审查 M1 / M2，11-11）：
//   M1 批量出完自动装机：装机不该被「装机页清单」门槛挡住（批量流程从没打开过装机页，原先悄悄 return、队列停住）
//   M2 批次进行中又单独点了出包：那一款排进队，批次结束后要接着出（原先批次结束只看自动装机，单款永远「排队中」）
// 假作业进程：记下每次起的作业；出包编排作业（export，剃刀 H13）可以扣住不放，模拟「正在出」。
@MainActor final class BatchQueueTests: XCTestCase {
    private var root: URL!
    private var runner: QueueRunner!
    private var model: S2ArmLauncherModel!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-queue-" + UUID().uuidString)
        let jobs = root.appendingPathComponent("Jobs")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try Data().write(to: jobs.appendingPathComponent("main.py"))
        runner = QueueRunner()
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"),
            runner: runner))
        model.refresh()
        for _ in 0..<300 where model.games.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.games.map(\.id), ["0100A", "0100B"])
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testBatchAutoInstallIsNotGatedByInstallPage() async {
        model.installAfterQueue = ["0100A"]
        model.installNextQueued()
        for _ in 0..<300 where runner.started("install").isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.started("install"), ["0100A"], "批量出完的款要直接开始装（装机页没打开过也一样）")
    }

    func testSingleExportQueuedDuringBatchRunsAfterBatchEnds() async {
        // 环境检查本身失败不挡出包（作业自己校验）：让检查作业失败，免得夹具去拼一整套检查项
        model.checkEnvironment()
        for _ in 0..<300 where model.checking { try? await Task.sleep(for: .milliseconds(10)) }
        runner.holdExports = true
        let b = model.games[1]
        model.runBatchExport()   // 批量出包：一个编排作业按批次文件出（批次清单脚本的回执本测试不关心）
        for _ in 0..<300 where runner.started("export").isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.export(b, platforms: [.ios]), "批次进行中单独点出包：排队")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runner.started("export"), ["batch"], "排队的那一款不在批次出完前起")
        runner.holdExports = false
        runner.releaseHeld()
        for _ in 0..<300 where runner.started("export").count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.started("export"), ["batch", "0100B"], "批次结束后接着出排队的那一款")
        XCTAssertFalse(model.batchRunning)
    }
}

private final class QueueRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }

    private(set) var requests: [[String: Any]] = []
    var holdExports = false
    private var held: [() -> Void] = []

    func started(_ operation: String) -> [String] {
        requests.filter { $0["operation"] as? String == operation }.compactMap { r in
            if let plan = r["plan"] as? [String: Any] {   // 出包编排：批次 = "batch"，就地出 = 计划里的那一款
                return plan["source"] as? String == "batch" ? "batch" : ((plan["items"] as? [[String: Any]])?.first?["gameId"] as? String)
            }
            return (r["game"] ?? r["gameId"] ?? (r["arguments"] as? [String: Any])?["game"]) as? String
        }
    }

    func releaseHeld() { let h = held; held = []; h.forEach { $0() } }

    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        // updater.py / batch.py 这类小脚本：最后一个参数不是请求文件，回一个空结果
        guard let last = arguments.last, last.hasSuffix(".json"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            DispatchQueue.main.async { onLine(Data("{}".utf8)); onExit(0) }
            return Handle()
        }
        requests.append(request)
        let operation = request["operation"] as? String ?? ""
        let result: [String: Any] = operation == "catalog"
            ? ["games": [["id": "0100A", "name": "Alpha", "ready": true, "missing": []],
                         ["id": "0100B", "name": "Beta", "ready": true, "missing": []]], "keys": [:]]
            : [:]
        let state = operation == "catalog" || operation == "export" || operation == "install" ? "succeeded" : "failed"
        let finish = {
            let event: [String: Any] = ["schema": 1, "taskId": request["taskId"] ?? "", "type": "result",
                                        "state": state, "result": result, "message": state == "failed" ? "Fixture failure" : ""]
            onLine(try! JSONSerialization.data(withJSONObject: event))
            onExit(state == "succeeded" ? 0 : 1)
        }
        if operation == "export" && holdExports { held.append { DispatchQueue.main.async(execute: finish) } }
        else { DispatchQueue.main.async(execute: finish) }
        return Handle()
    }
}
