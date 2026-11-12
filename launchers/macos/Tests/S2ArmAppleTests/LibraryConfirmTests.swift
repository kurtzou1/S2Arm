// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// v0.3.1 换游戏库撞上认得出的风险：作业层报码，界面问「仍然继续 / 先不」，同意后带对应参数重发、参数累积。期望手写：
//   第一次报 library_in_cloud → 待确认 accept = [acceptCloud]；第二次报 library_folder_not_empty → [acceptCloud, acceptForeign]；第三次两个都带、换库成功
@MainActor final class LibraryConfirmTests: XCTestCase {
    func testLibraryConfirmsAccumulate() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-libconfirm-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let runner = SetupRunner(codes: ["library_in_cloud", "library_folder_not_empty"], library: root.appendingPathComponent("新库").path)
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        let target = root.appendingPathComponent("新库")
        model.changeLibrary(to: target)
        for _ in 0..<300 where model.busy || model.libraryConfirm == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let first = try XCTUnwrap(model.libraryConfirm)
        XCTAssertEqual(first.code, "library_in_cloud"); XCTAssertEqual(first.accept, ["acceptCloud"])
        model.libraryConfirm = nil; model.changeLibrary(to: first.url, move: first.move, accept: first.accept)
        for _ in 0..<300 where model.busy || model.libraryConfirm == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let second = try XCTUnwrap(model.libraryConfirm)
        XCTAssertEqual(second.code, "library_folder_not_empty"); XCTAssertEqual(second.accept, ["acceptCloud", "acceptForeign"])
        model.libraryConfirm = nil; model.changeLibrary(to: second.url, move: second.move, accept: second.accept)
        for _ in 0..<300 where model.busy || runner.setups.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<100 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.setups.count, 3)
        XCTAssertEqual(runner.setups[2]["acceptCloud"] as? Bool, true); XCTAssertEqual(runner.setups[2]["acceptForeign"] as? Bool, true)
        XCTAssertNil(model.libraryConfirm)
    }
}

/// 假作业进程：setup 请求按 codes 依次失败（每个码只在还没带对应参数时失败一次），之后成功；别的请求一律成功
private final class SetupRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    var setups: [[String: Any]] = []
    let codes: [String]; let library: String
    init(codes: [String], library: String) { self.codes = codes; self.library = library }
    static let param = ["library_in_cloud": "acceptCloud", "library_folder_not_empty": "acceptForeign"]
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        var taskId = ""; var request: [String: Any] = [:]
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { request = r; taskId = r["taskId"] as? String ?? "" }
        var event: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": "succeeded", "result": [:], "message": ""]
        if request["operation"] as? String == "setup" {
            setups.append(request)
            event["result"] = ["library": library, "libraryId": "new-id", "outcome": "created"]
            if let code = codes.first(where: { request[Self.param[$0]!] == nil }) {
                event = ["schema": 1, "taskId": taskId, "type": "result", "state": "failed", "result": [:], "message": "需要确认：\(code)",
                         "diagnostics": [["code": code, "severity": "error", "summary": code]]]
            }
        }
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(event["state"] as? String == "succeeded" ? 0 : 1) }
        return Handle()
    }
}
