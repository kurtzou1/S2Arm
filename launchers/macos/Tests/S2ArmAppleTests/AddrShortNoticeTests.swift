// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import XCTest
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

// 「地址空间不够这款」提示条（Mac）：宿主那条黄行 → 作业层 notice addr_short → 启动器在游戏窗口之上弹一条（每局一次）。期望手写：
//   ① 一局里收到 notice addr_short → 标记为已提示；② 只有别的事件（进度 / 别的 notice 码）→ 不提示；③ 新开一局清掉上局的标记
@MainActor final class AddrShortNoticeTests: XCTestCase {
    private func model() -> S2ArmLauncherModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-addrshort-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(privateRoot: root, resources: root)))
    }
    private func ev(_ type: String, code: String? = nil) -> EngineEvent {
        EngineEvent(ev: type, t: 1, code: code, severity: .info, fields: ["type": type, "message": ""].merging(code.map { ["code": $0] } ?? [:]) { a, _ in a })
    }

    func testNoticeShownOnceOnAddrShortOnly() {
        let m = model()
        m.playSession = JobSession(kind: .play, gameID: "0100965017338000", name: "Fixture")
        m.ingest(ev("progress"), slot: .game)
        m.ingest(ev("notice", code: "other"), slot: .game)
        XCTAssertFalse(m.addrShortNoticed, "没有那条黄行（只有进度 / 别的码）：不提示")
        m.ingest(ev("notice", code: "addr_short"), slot: .game)
        XCTAssertTrue(m.addrShortNoticed, "收到 notice addr_short：提示")
    }

    func testNewGameClearsNotice() {
        let m = model()
        m.addrShortNoticed = true
        m.playLanguage = "zh-Hans"; m.addrShortNoticed = false   // play() 开局时做的两件事（不起真局）
        m.playSession = JobSession(kind: .play, gameID: "0100965017338000", name: "Fixture")
        m.ingest(ev("progress"), slot: .game)
        XCTAssertFalse(m.addrShortNoticed, "新开一局：上局的提示标记不带过来")
    }
}
