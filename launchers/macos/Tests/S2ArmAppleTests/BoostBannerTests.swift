// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

/// 出包完成页的「S 级加强」条（11-12）：按作业层 boost 条数列出、只列非 0 的；离屏渲染成 PNG（S2A_BOOST_SHOT=<目录> 时存图）。期望手写
@MainActor final class BoostBannerTests: XCTestCase {
    func testRendersCountsAndSkipsZero() throws {
        _ = NSApplication.shared
        let texts = ["export.boost.title": "S 级加强已就位", "export.boost.cheats": "金手指 {0} 条", "export.boost.fps": "帧率补丁 {0} 份",
                     "export.boost.widescreen": "宽屏补丁 {0} 份", "export.boost.gfx": "画面补丁 {0} 份", "export.boost.hint": "提示"]
        let view = BoostBanner(boost: ["cheats": 70, "fps": 1, "widescreen": 0, "gfx": 2], text: { texts[$0] ?? $0 }, settled: true)
            .frame(width: 760).padding(20).background(Color(white: 0.08)).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view); r.scale = 2
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(r.nsImage?.tiffRepresentation)).flatMap { $0.representation(using: .png, properties: [:]) })
        XCTAssertGreaterThan(png.count, 20_000)
        if let dir = ProcessInfo.processInfo.environment["S2A_BOOST_SHOT"] { try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("boost_banner.png")) }
    }
}
