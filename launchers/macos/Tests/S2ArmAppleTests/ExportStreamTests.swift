// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// 出包编排作业（export，剃刀 H13）的事件 → 出包页每个平台的结局。事件按 pack/jobs/export_plan.py 打出的形状手写，期望值手写：
//   Mac 那步成功（产物路径）、iPhone 那步磁盘满（码、建议取自子作业终态的诊断），整次出包「没全成」；只起一个 export 作业。
@MainActor final class ExportStreamTests: XCTestCase {
    func testExportEventsBecomePerPlatformOutcomes() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ExportRunner()
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        model.refresh()
        for _ in 0..<300 where model.games.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(model.games.first)
        model.runExport(QueuedExport(game: game, platforms: [.ios, .mac], target: nil, spaceOverride: false))
        for _ in 0..<300 where !(model.session.map { if case .finished = $0.phase { return true }; return false } ?? false) { try? await Task.sleep(for: .milliseconds(10)) }
        let session = try XCTUnwrap(model.session)
        XCTAssertEqual(session.phase, .finished(.failed), "有平台没成：整次算没全成")
        let mac = try XCTUnwrap(session.export?.outcomes[.mac]), iphone = try XCTUnwrap(session.export?.outcomes[.ios])
        XCTAssertEqual(mac.state, .completed); XCTAssertEqual(mac.output, "/out/mac")
        XCTAssertEqual(iphone.state, .failed); XCTAssertEqual(iphone.code, "disk_full")
        XCTAssertEqual(iphone.message, "磁盘空间不足"); XCTAssertEqual(iphone.suggestion, "释放空间后重试")
        XCTAssertEqual(runner.operations.filter { $0 != "catalog" && $0 != "storeMeta" }, ["export"], "只起一个出包编排作业")
        let plan = try XCTUnwrap(runner.exportPlan)
        XCTAssertEqual(plan["source"] as? String, "inline")
        XCTAssertEqual(((plan["items"] as? [[String: Any]])?.first?["platforms"] as? [String]), ["iphone", "mac"])
    }

    // 重开启动器后「上次停在第几款」：被打断的那款优先，其次第一款还有排队的；都没有是 0（同 Windows BatchState.StoppedAt）
    func testBatchStoppedAt() {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-stopped-" + UUID().uuidString)
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(privateRoot: root, resources: root, library: root.path, libraryId: "x")))
        func item(_ gid: String, _ r: [String: Any]) -> [String: Any] { ["gameId": gid, "platforms": ["iphone"], "results": ["iphone": r]] }
        let done = ["state": "completed"], pending = ["state": "pending"], interrupted: [String: Any] = ["state": "pending", "interrupted": true]
        model.batchState = ["batch": ["items": [item("A", done), item("B", ["state": "failed"]), item("C", pending), item("D", interrupted)]]]
        XCTAssertEqual(model.batchStoppedAt, 4, "被打断的那款（启动器退出时正在出）")
        model.batchState = ["batch": ["items": [item("A", done), item("B", pending), item("C", pending)]]]
        XCTAssertEqual(model.batchStoppedAt, 2, "没有被打断的：第一款排着队的")
        model.batchState = ["batch": ["items": [item("A", ["state": "cancelled"])]]]
        XCTAssertEqual(model.batchStoppedAt, 0)
    }
}

private final class ExportRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    private(set) var operations: [String] = []
    private(set) var exportPlan: [String: Any]?

    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        guard let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            DispatchQueue.main.async { onLine(Data("{}".utf8)); onExit(0) }
            return Handle()
        }
        let operation = request["operation"] as? String ?? "", task = request["taskId"] as? String ?? ""
        operations.append(operation)
        var lines: [[String: Any]] = []
        func event(_ type: String, _ extra: [String: Any]) { lines.append(["schema": 1, "taskId": task, "operation": operation, "type": type, "state": "running"].merging(extra) { $1 }) }
        if operation == "catalog" {
            lines.append(["schema": 1, "taskId": task, "type": "result", "state": "succeeded",
                          "result": ["games": [["id": "0100A", "name": "Alpha", "ready": true, "missing": []]], "keys": [:]]])
        } else if operation == "export" {
            exportPlan = request["plan"] as? [String: Any]
            let mac: [String: Any] = ["gameId": "0100A", "platform": "mac", "task": "\(task)-1", "index": 1, "count": 2]
            let iphone: [String: Any] = ["gameId": "0100A", "platform": "iphone", "task": "\(task)-2", "index": 2, "count": 2]
            event("step", ["step": mac])
            event("child", ["step": mac, "event": ["schema": 1, "taskId": "\(task)-1", "type": "progress", "state": "running", "done": 1, "total": 2, "message": "打包"]])
            event("stepEnded", ["step": mac, "outcome": ["state": "completed", "message": "操作完成", "outputPath": "/out/mac", "output": "/out/mac"]])
            event("step", ["step": iphone])
            event("child", ["step": iphone, "event": ["schema": 1, "taskId": "\(task)-2", "type": "result", "state": "failed", "message": "磁盘空间不足", "result": [:],
                                                       "diagnostics": [["severity": "error", "code": "disk_full", "summary": "磁盘空间不足", "suggestion": "释放空间后重试"]]]])
            event("stepEnded", ["step": iphone, "outcome": ["state": "failed", "message": "磁盘空间不足", "code": "disk_full"]])
            lines.append(["schema": 1, "taskId": task, "type": "result", "state": "succeeded", "message": "操作完成", "result": ["summary": ["total": 1]]])
        } else {
            lines.append(["schema": 1, "taskId": task, "type": "result", "state": "failed", "message": "Fixture failure", "result": [:]])
        }
        let ok = (lines.last?["state"] as? String) == "succeeded"
        DispatchQueue.main.async {
            for (n, l) in lines.enumerated() { var e = l; e["seq"] = n + 1; onLine(try! JSONSerialization.data(withJSONObject: e)) }
            onExit(ok ? 0 : 1)
        }
        return Handle()
    }
}
