// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import XCTest
@testable import NX2AppleUI

/// S 级优化批量升级的进度条（玩家报修 D-QNA9，Mac 实机：在 50%、0%、80% 间来回跳）：界面只认作业层的整款进度 sgradeProgress，
///   同一款在升期间事件与轮询取较大值、只增不减。期望按规则手写。
final class SGradeProgressTests: XCTestCase {
    func testOnlyWholeGameProgressCountsAndNeverGoesBack() {
        // 事件先给整款 0.6，再来一条段内计数器的普通 progress（done / total = 1/10）：不认它，仍 0.6
        var live = SGradeLive.running(0.6, after: SGradeLive(state: "running", progress: 0))
        XCTAssertEqual(live.progress, 0.6)
        XCTAssertNil(SGradeLive.eventProgress(["done": 1, "total": 10]), "普通 progress 的 done / total 不是整款进度")
        XCTAssertEqual(SGradeLive.eventProgress(["done": 1, "total": 10, "sgradeProgress": 0.65]), 0.65)
        // 轮询慢一拍读到队列文件里的 0.5：不回退
        live = SGradeLive.running(0.5, after: live)
        XCTAssertEqual(live.progress, 0.6)
        live = SGradeLive.running(0.7, after: live)
        XCTAssertEqual(live.progress, 0.7)
        live = SGradeLive.running(nil, after: live)
        XCTAssertEqual(live.progress, 0.7, "轮询没给进度：保留在升时的值")
        // 上一次已做完（不在升）：新一轮从新读数起，不沿用旧值
        XCTAssertEqual(SGradeLive.running(0.1, after: SGradeLive(state: "done", progress: 1)).progress, 0.1)
    }
}
