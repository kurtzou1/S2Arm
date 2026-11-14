// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
@testable import NX2AppleUI

/// 补丁打入结果（11-14）：解析作业层 applied / failed / error，三种情况离屏出图（S2A_SGRADE_SHOT=<目录> 存图看样子）
@MainActor final class SGradeResultTests: XCTestCase {
    static let texts = ["sgrade.result.title": "补丁打入结果", "sgrade.result.applied": "已打上：", "sgrade.result.failed": "没打上：{0}（{1}）——补丁打入失败，{2}",
                        "sgrade.result.error": "不匹配，补丁打入失败，这款先保留原来的程序（游戏照常能玩）。", "sgrade.result.note": "没打上的不影响游戏本身；补丁库更新后再出包或升级会重新尝试。",
                        "sgrade.result.why.mismatch": "和你这份游戏对不上", "sgrade.result.why.translate": "这一处暂时转译不了",
                        "export.sgrade.cat.widescreen": "满屏", "export.sgrade.hit.cheat": "金手指 {0} 条，打入后默认关，进游戏后可逐条打开", "export.sgrade.cat.fps": "帧率", "export.sgrade.cat.cheat": "金手指", "export.sgrade.cat.gfx": "画面"]

    func testParse() {
        let o = SGradeOutcome(["applied": [["id": "fps:a", "cat": "fps", "name": "60 FPS"]], "failed": [["id": "gfx:b", "cat": "gfx", "name": "阴影", "why": "result.why.mismatch"]], "cheats": 3])
        XCTAssertEqual(o.applied, [.init(cat: "fps", name: "60 FPS", why: "")]); XCTAssertEqual(o.failed.map(\.why), ["result.why.mismatch"]); XCTAssertTrue(o.hasProblem)
        XCTAssertTrue(SGradeOutcome(["fps": 1]).isEmpty, "只有补丁份数（旧作业层）：不出这块")
        XCTAssertEqual(SGradeOutcome(["cheats": 3]).cheats, 3); XCTAssertFalse(SGradeOutcome(["cheats": 3]).isEmpty, "随包金手指也是结果的一部分")
        XCTAssertFalse(SGradeOutcome(["error": "x"]).isEmpty)
    }

    func render(_ r: [SGradeGameResult], _ name: String) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let v = SGradeResultView(results: r, text: { Self.texts[$0] ?? $0 }).frame(width: 720).padding(20)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12)).environment(\.colorScheme, .dark)
        let rr = ImageRenderer(content: v); rr.scale = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(rr.nsImage?.tiffRepresentation)))
        if let dir = ProcessInfo.processInfo.environment["S2A_SGRADE_SHOT"] { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("result_\(name).png")) }
        return rep
    }

    func testRenders() throws {
        let mixed = SGradeOutcome(["applied": [["cat": "widescreen", "name": "满屏 21:9"], ["cat": "fps", "name": "60 FPS"], ["cat": "cheat", "name": "无限血"]],
                                   "failed": [["cat": "gfx", "name": "阴影质量", "why": "result.why.mismatch"], ["cat": "cheat", "name": "秒杀", "why": "result.why.translate"]]])
        let one = try render([SGradeGameResult(name: "Mac", outcome: mixed)], "mixed")
        let two = try render([SGradeGameResult(name: "暗黑破坏神 III", outcome: mixed), SGradeGameResult(name: "Hades", outcome: SGradeOutcome(["error": "改写器出错"])),
                              SGradeGameResult(name: "空洞骑士", outcome: SGradeOutcome(["cheats": 5]))], "games")
        let none = try render([SGradeGameResult(name: "Mac", outcome: SGradeOutcome())], "none")
        XCTAssertGreaterThan(two.pixelsHigh, one.pixelsHigh, "两款比一款多一节")
        XCTAssertEqual(none.pixelsHigh, 80, "没有结果不出这块：只剩上下各 20 点内边距 = 40 点 × 2 倍 = 80 像素")
    }
}
