// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import XCTest
import S2ArmAppleAdapter
@testable import NX2AppleUI

// 剃刀 M3：换封面 / 释放空间 / 存档在等库锁时，界面显示作业层原句「在等「…」结束…」（progress、phase=waiting_lock）；
// 拿到锁后的普通进度清空。期望手写，不复述实现
final class LockWaitNoteTests: XCTestCase {
    private func progress(_ fields: [String: Any]) -> EngineEvent {
        EngineEvent(ev: "progress", t: 0, code: nil, severity: .info, fields: fields)
    }

    @MainActor func testWaitingLockShowsHolderThenClears() async {
        let model = S2ArmLauncherModel(client: .init(environment: .init(privateRoot: FileManager.default.temporaryDirectory, resources: FileManager.default.temporaryDirectory, library: "", libraryId: "")))
        let sink = model.lockWaitSink()
        sink.emit(progress(["message": "在等「出包 · 某款」结束…", "phase": "waiting_lock"]))
        for _ in 0..<50 where model.lockWaitNote == nil { await Task.yield() }
        XCTAssertEqual(model.lockWaitNote, "在等「出包 · 某款」结束…")
        sink.emit(progress(["message": "备份存档", "stage": "saveBackup"]))
        for _ in 0..<50 where model.lockWaitNote != nil { await Task.yield() }
        XCTAssertNil(model.lockWaitNote, "拿到锁、进入正常进度后不再显示在等谁")
        sink.emit(EngineEvent(ev: "log", t: 0, code: nil, severity: .info, fields: ["message": "x", "phase": "waiting_lock"]))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(model.lockWaitNote, "只认 progress 事件")
    }
}
