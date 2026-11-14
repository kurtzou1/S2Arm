// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
@testable import NX2AppleUI

/// 「S 级优化升级」页（v0.4.0）四态离屏出图（S2A_SGRADE_SHOT=<目录> 时存图看样子）：
///   有可升级且有 iPhone 件 → 两个升级按钮；全没找到原始程序 → 只给确认；找到但全无补丁 → 只给确认；查找中。
///   判据：分组按 sgradeScan 的字段分对（文案用键名代替，直接看渲染出的可访问文本不可靠，故核分组函数的输入输出与图非空）
@MainActor final class SGradeUpgradeTests: XCTestCase {
    static func g(_ id: String, _ name: String, program: String = "saved", patches: [String: Int] = [:], iphone: Bool = true, off: Bool = false) -> SGradeScanGame {
        SGradeScanGame(["id": id, "name": name, "program": program, "total": patches.values.reduce(0, +), "patches": patches, "iphone": iphone, "off": off])
    }
    static let texts = ["title": "S 级优化升级", "scanning": "正在查找游戏库里各款游戏的原始程序…", "found": "找到了 {0} 款游戏的原始程序。",
                        "yes": "可以升级到 S 级优化", "no": "没有对应补丁", "off": "出包时选了不打入，不升级", "missing": "没找到原始程序，需要重新出包覆盖更新",
                        "none": "以下游戏均不支持 S 级优化。", "nothing": "很遗憾，本游戏库中没有找到可供升级的源文件，需要麻烦您重新出包覆盖更新。",
                        "macNote": "macOS 玩家无需额外操作，下次启动游戏自动生效。", "install": "插上手机，一键升级并安装", "export": "自签导出 IPA",
                        "iphoneNote": "只换程序，手机上的游戏资源和存档都不动；自签导出请用原来的包名签名。", "ok": "确认", "close": "关闭",
                        "cat.widescreen": "满屏", "cat.fps": "帧率", "cat.cheat": "金手指 {0} 条", "cat.gfx": "画面"]

    func render(_ games: [SGradeScanGame]?, _ name: String) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Branding/s-gold.png").standardized
        let img = try XCTUnwrap(NSImage(contentsOf: src))
        let view = SGradeUpgradeBody(games: games, failure: nil, zh: true, busy: false, x: { Self.texts[$0] ?? $0 }, upgrade: { _ in }, close: {}, sImage: img)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12)).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view); r.scale = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(r.nsImage?.tiffRepresentation)))
        if let dir = ProcessInfo.processInfo.environment["S2A_SGRADE_SHOT"] { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("upgrade_\(name).png")) }
        return rep
    }

    func testScanFieldsParse() {
        let a = SGradeScanGame(["id": "0100A", "name": "甲", "program": "none", "total": 0, "patches": ["fps": 2], "iphone": true])
        XCTAssertFalse(a.found); XCTAssertEqual(a.patches["fps"], 2); XCTAssertFalse(a.off)
        XCTAssertTrue(SGradeScanGame(["id": "0100B", "program": "mac"]).found)
        XCTAssertEqual(SGradeScanGame(["id": "0100B"]).name, "0100B", "没名字用程序号")
    }

    func testFourStatesRender() throws {
        let mixed = [Self.g("A", "甲", patches: ["widescreen": 1, "fps": 2, "cheat": 12]), Self.g("B", "乙"), Self.g("C", "丙", patches: ["fps": 1], off: true),
                     Self.g("D", "丁", program: "none")]
        let big = try render(mixed, "mixed"), nothing = try render([Self.g("D", "丁", program: "none")], "nothing")
        let none = try render([Self.g("B", "乙"), Self.g("E", "戊", program: "mac", iphone: false)], "none"), scanning = try render(nil, "scanning")
        XCTAssertGreaterThan(big.pixelsHigh, nothing.pixelsHigh, "可升级页列了四组 + 按钮，比「没找到」页高")
        XCTAssertGreaterThan(none.pixelsHigh, scanning.pixelsHigh)
    }
}
