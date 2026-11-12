// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

// 手机作业结局页三态（11-11 维护者：更新手机上的 S2Arm 做完「成功了也看不出成功」「还写着正在更新」「露出机读码」「太丑」）：
//   同一个会话走真实那条路（model.start → 作业体发阶段 / 进度事件，或抛带下一步的 JobFailure → finish），整窗渲染；
//   设 S2A_SNAPSHOT_OUT=<目录> 存 phone_running.png / phone_done.png / phone_failed.png 供肉眼核对。
@MainActor final class PhoneJobSnapshotTests: XCTestCase {
    private var root: URL!
    private var model: S2ArmLauncherModel!

    private var savedLanguage: String?

    override func setUp() async throws {
        _ = NSApplication.shared
        savedLanguage = UserDefaults.standard.string(forKey: "appLanguage")
        UserDefaults.standard.set(ProcessInfo.processInfo.environment["S2A_SNAPSHOT_LANG"] ?? "zh", forKey: "appLanguage")   // 截图按中文界面
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-phone-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"),
            runner: PhoneCatalogRunner()))
        model.refresh()
        for _ in 0..<300 where model.games.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        if let savedLanguage { UserDefaults.standard.set(savedLanguage, forKey: "appLanguage") } else { UserDefaults.standard.removeObject(forKey: "appLanguage") }
    }

    private func emit(_ sink: EventSink, _ ev: String, _ fields: [String: Any]) {
        sink.emit(EngineEvent(ev: ev, t: 0, code: nil, severity: .info, fields: fields))
    }

    private func session() -> JobSession {
        var s = JobSession(kind: .installUpdate, gameID: nil, name: "正在更新 iPhone 上的 S2Arm")
        s.started = Date().addingTimeInterval(-47)
        return s
    }

    func testRunningDoneAndFailedPages() async throws {
        // 进行中：第 5 / 6 步，作业层整体进度 0.62
        model.start(session()) { sink in
            self.emit(sink, "stage", ["stage": "找签名账号与 iPhone", "message": "找签名账号与 iPhone", "stageIndex": 1, "stageCount": 6, "overall": 0.0])
            self.emit(sink, "stage", ["stage": "把这款放进手机上的 S2Arm", "message": "把这款放进手机上的 S2Arm", "stageIndex": 2, "stageCount": 6, "overall": 0.17])
            self.emit(sink, "stage", ["stage": "用你的 Apple ID 签名", "message": "用你的 Apple ID 签名", "stageIndex": 4, "stageCount": 6, "overall": 0.5, "keychainPrompt": true])
            try await Task.sleep(for: .seconds(30)); return nil
        }
        for _ in 0..<100 where model.session?.stage != "用你的 Apple ID 签名" { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.session?.progress.overall, 0.5)
        XCTAssertEqual(model.session?.progress.keychainPrompt, true, "要玩家动手的阶段：页面在步骤上方挂醒目提示")
        try snapshot("phone_running")
        model.stop()
        for _ in 0..<300 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }

        // 成功：只换壳，一个资源包都没推
        model.start(session()) { sink in
            self.emit(sink, "stage", ["stage": "找签名账号与 iPhone", "message": "找签名账号与 iPhone", "stageIndex": 1, "stageCount": 6])
            self.emit(sink, "message", ["message": "▸ 组装容器：本版壳 + 手机上已有的 3 款"])
            self.model.phoneOutcome = PhoneOutcome(device: "iPhone「我的 iPhone」", packFiles: 0, packBytes: 0, version: "0.3.0")
            return nil
        }
        for _ in 0..<300 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.session?.phase, .finished(.completed))
        XCTAssertNotNil(model.session?.ended)
        XCTAssertEqual(model.lastPhoneSession?.kind, .installUpdate, "手机作业结束记成最近一次手机作业，装机页结局区读它")
        try snapshot("phone_done")

        // 失败：原因 + 下一步落到会话上
        // 失败的例子用真正做不下去的情况（签名失败）：读不出手机上有哪些游戏这类，维护者 11-11 定了不阻断、作业层直接继续
        let next = "在 Xcode 的「设置 › 账户」里重新登录这个 Apple ID，再点一次。"
        model.start(session()) { sink in
            self.emit(sink, "stage", ["stage": "找签名账号与 iPhone", "message": "找签名账号与 iPhone", "stageIndex": 1, "stageCount": 6])
            throw JobFailure(JobOutcome(taskId: "t", state: .failed, exitCode: 1, message: "签名没成功：Xcode 里的 Apple ID 登录已过期。", result: [:],
                                        diagnostics: [["code": "apple_session_expired", "suggestion": next, "summary": "apple_session_expired"]], stderr: ""))
        }
        for _ in 0..<300 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.session?.suggestion, next)
        try snapshot("phone_failed")

        // 会挤掉别处装的游戏：就在更新页里问（不弹框）；「仍然继续」按同样的参数带 acceptDropped 再来
        let drop = "这次会让手机上的 1 款游戏暂时不能玩：示例游戏。它们不是在这台电脑上装的，存档和资源包都还在手机上，到原来那台电脑上再点一次「装到 iPhone」就能回来。"
        model.dropConfirm = S2ArmLauncherModel.DropConfirm(kind: .installUpdate, message: drop,
                                                         update: S2ArmLauncherModel.UpdateArgs(acceptStale: true, repack: [], language: "zh-Hans", device: "D1"))
        model.start(session()) { _ in
            throw JobFailure(JobOutcome(taskId: "t", state: .failed, exitCode: 1, message: drop, result: [:],
                                        diagnostics: [["code": "container_would_drop", "summary": drop]], stderr: ""))
        }
        for _ in 0..<300 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.session?.failureCode, "container_would_drop")
        try snapshot("phone_drop")
    }

    /// 文案矩阵：全部作业类型 × 全部结局状态，每一格用的是界面实际取的那条文案，中英都要有，缺一格就红
    ///   （原先缺了就把键名大写上屏：S2ARM.JOB.DONE.INSTALLUPDATE；运行时退回通用句只是兜底，不能代替这条）
    func testTextMatrixEveryKindEveryState() {
        let l10n = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("frontend/l10n")
        let states: [JobSession.Phase] = [.running, .stopping, .finished(.completed), .finished(.cancelled), .finished(.failed), .finished(.interrupted), .finished(.paused)]
        var missing: [String] = []
        for lang in ["zh", "en"] {
            let table = (try? JSONSerialization.jsonObject(with: Data(contentsOf: l10n.appendingPathComponent(lang + ".json")))) as? [String: Any] ?? [:]
            XCTAssertFalse(table.isEmpty, "读到 \(lang).json")
            let language = lang == "zh" ? "zh-Hans" : "en"
            for k in JobSession.Kind.allCases {
                let job = JobSession(kind: k, gameID: nil, name: "")
                for state in states {
                    if job.isPhoneJob {   // 手机作业：PhoneJobPanel 按状态取共用体验表
                        for key in Self.phoneKeys(k, state) where BackendText.launcherText(key, language: language).hasPrefix("[") {
                            missing.append("\(lang) \(k.rawValue) \(state) → \(key)")
                        }
                    } else if k != .play {   // 别的作业：JobSessionView 状态行 + 标题
                        for key in Self.jobKeys(k, state) where table[key] as? String == nil { missing.append("\(lang) \(k.rawValue) \(state) → \(key)") }
                    }
                }
            }
        }
        XCTAssertEqual(missing, [], "缺文案")
        XCTAssertEqual(PhoneJobPanel.duration(65, language: "zh-Hans"), "1 分 5 秒")
        XCTAssertEqual(PhoneJobPanel.duration(45, language: "en"), "45 s")
    }

    /// 同 JobSessionView.statusText / 标题行
    static func jobKeys(_ k: JobSession.Kind, _ p: JobSession.Phase) -> [String] {
        let title = "s2arm.job.title." + k.rawValue
        switch p {
        case .running: return ["s2arm.job.running", title]
        case .stopping: return ["s2arm.job.stopping", title]
        case .finished(.completed): return ["s2arm.job.done." + k.rawValue, title]
        case .finished(.cancelled): return ["s2arm.job.cancelled", title]
        case .finished(.failed), .finished(.paused): return ["s2arm.job.failed", title]
        case .finished(.interrupted): return ["s2arm.job.interrupted", title]
        }
    }

    /// 同 PhoneJobPanel：进行中（状态词 + 标题 + 整体进度 + 后面还有几步）、成功（大字 + 结论句 + 三个数字）、取消、失败（大字 + 下一步 + 详细过程）
    static func phoneKeys(_ k: JobSession.Kind, _ p: JobSession.Phase) -> [String] {
        switch p {
        case .running, .stopping: return ["phone.title." + k.rawValue, "phone.status.running." + k.rawValue, "export.overall", "phone.steps.more", "phone.action", "install.keychain", "phone.details"]
        case .finished(.completed): return ["phone.title." + k.rawValue, "phone.headline." + k.rawValue, "phone.done." + k.rawValue, "phone.stat.time", "phone.stat.device",
                                            "phone.stat.games", "phone.stat.no_push", "phone.fact.no_push", "phone.fact.pushed", "phone.fact.skipped", "phone.details"]
        case .finished(.cancelled): return ["phone.title." + k.rawValue, "phone.cancelled", "phone.details"]
        case .finished(.failed), .finished(.interrupted), .finished(.paused): return ["phone.title." + k.rawValue, "phone.failed." + k.rawValue, "phone.next", "phone.retry",
                                                                  "install.drop_title", "install.drop_confirm", "phone.drop.cancel", "phone.details"]
        }
    }

    private func snapshot(_ name: String) throws {
        let view = NSHostingView(rootView: S2ArmAppleRootView(model: model, brand: "S2Arm × NX2Apple")
            .frame(width: 1280, height: 800).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8)); view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        if let o = ProcessInfo.processInfo.environment["S2A_SNAPSHOT_OUT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: o).appendingPathComponent(name + ".png"))
        }
    }
}

/// 假作业进程：只回游戏库（一款）；别的作业回空结果
private final class PhoneCatalogRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        var result: [String: Any] = [:]; var taskId = ""
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            taskId = request["taskId"] as? String ?? ""
            if request["operation"] as? String == "catalog" {
                result = ["games": [["id": "0100A", "name": "测试游戏", "ready": true, "missing": [], "display": "1.0.0"]], "keys": [:]]
            }
        }
        let event: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": "succeeded", "result": result, "message": ""]
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(0) }
        return Handle()
    }
}
