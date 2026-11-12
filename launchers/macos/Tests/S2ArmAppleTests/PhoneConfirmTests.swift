// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// 维护者 11-11 装机原则：认得出的风险让玩家确认、确认了就装。作业层可确认继续的停装码（会挤掉别处装的游戏 / 存档没能备份 / 都要按新版重出）
//   在结局页里问「仍然继续 / 先不」；确认后同一请求带上对应参数重发，参数累积（先确认挤掉、再撞上备份失败，第三次重发两个都带）。期望手写
@MainActor final class PhoneConfirmTests: XCTestCase {
    func testInstallConfirmsAccumulate() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-confirm-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let runner = ConfirmRunner(codes: ["container_would_drop", "save_backup_failed"])
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        let game = GameSummary(id: "0100A", name: "示例游戏")
        model.install(game, device: "D1")
        for _ in 0..<300 where model.busy || model.dropConfirm == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let first = try XCTUnwrap(model.dropConfirm)
        XCTAssertEqual(first.code, "container_would_drop"); XCTAssertEqual(first.accept, ["acceptDropped"])
        model.confirmDrop(first)
        for _ in 0..<300 where model.busy || model.dropConfirm == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let second = try XCTUnwrap(model.dropConfirm)
        XCTAssertEqual(second.code, "save_backup_failed"); XCTAssertEqual(second.accept, ["acceptDropped", "acceptNoBackup"])
        model.confirmDrop(second)
        for _ in 0..<300 where model.busy || runner.installs.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.installs.count, 3)
        XCTAssertNil(runner.installs[0]["acceptDropped"])
        XCTAssertEqual(runner.installs[1]["acceptDropped"] as? Bool, true); XCTAssertNil(runner.installs[1]["acceptNoBackup"])
        XCTAssertEqual(runner.installs[2]["acceptDropped"] as? Bool, true); XCTAssertEqual(runner.installs[2]["acceptNoBackup"] as? Bool, true)
        XCTAssertEqual(runner.installs[2]["device"] as? String, "D1", "还是同一台")
        for _ in 0..<300 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.lastPhoneSession?.phase, .finished(.completed), "两次确认后装成")
    }

    // 删除前也要备份存档（作业层 installRemove 同样报 save_backup_failed）：原先删除只认 container_would_drop，
    //   「仍然继续」只带 acceptDropped，删前备份失败就在确认里来回转。期望：先确认挤掉、再确认没备份，第三次两个参数都带、删成
    func testRemoveConfirmsAccumulate() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-confirm-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let runner = ConfirmRunner(codes: ["container_would_drop", "save_backup_failed"])
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        let game = GameSummary(id: "0100A", name: "示例游戏")
        model.removeFromPhone(game, device: "D1")
        for _ in 0..<300 where model.busy || model.dropConfirm == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let first = try XCTUnwrap(model.dropConfirm)
        XCTAssertEqual(first.kind, .installRemove); XCTAssertEqual(first.accept, ["acceptDropped"])
        model.confirmDrop(first)
        for _ in 0..<300 where model.busy || model.dropConfirm == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let second = try XCTUnwrap(model.dropConfirm)
        XCTAssertEqual(second.code, "save_backup_failed"); XCTAssertEqual(second.accept, ["acceptDropped", "acceptNoBackup"])
        model.confirmDrop(second)
        for _ in 0..<300 where model.busy || runner.installs.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.installs.count, 3)
        XCTAssertEqual(runner.installs[2]["operation"] as? String, "installRemove")
        XCTAssertEqual(runner.installs[2]["acceptDropped"] as? Bool, true); XCTAssertEqual(runner.installs[2]["acceptNoBackup"] as? Bool, true)
        XCTAssertEqual(runner.installs[2]["device"] as? String, "D1", "还是同一台")
    }
}

/// 假作业进程：装机 / 删除请求按 codes 依次失败（每个码只在还没带对应参数时失败一次），之后成功
private final class ConfirmRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    var installs: [[String: Any]] = []
    let codes: [String]
    init(codes: [String]) { self.codes = codes }
    static let param = ["container_would_drop": "acceptDropped", "save_backup_failed": "acceptNoBackup"]
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        var taskId = ""; var request: [String: Any] = [:]
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { request = r; taskId = r["taskId"] as? String ?? "" }
        var event: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": "succeeded", "result": [:], "message": ""]
        if ["install", "installRemove"].contains(request["operation"] as? String ?? "") {
            installs.append(request)
            if let code = codes.first(where: { request[Self.param[$0]!] == nil }) {
                event = ["schema": 1, "taskId": taskId, "type": "result", "state": "failed", "result": [:], "message": "需要确认：\(code)",
                         "diagnostics": [["code": code, "severity": "error", "summary": code]]]
            }
        }
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(event["state"] as? String == "succeeded" ? 0 : 1) }
        return Handle()
    }
}
