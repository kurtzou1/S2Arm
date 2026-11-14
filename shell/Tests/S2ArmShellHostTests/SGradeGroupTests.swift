// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import Testing
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import ShellUI

/// 游戏设置里社区补丁与金手指合成一块「S 级优化」专区（SGradeGroup.swift）：两组只出一块、出在两组里第一组的位置、别的组照旧；
/// 离屏渲染成 PNG（S2A_SGRADE_SHOT=<目录> 时存图看样子）
@MainActor @Test func sGradeBlockMergesPatchesAndCheats() throws {
    let on = SettingKind.toggle(on: "on", off: "off")
    let sections = [
        SettingSection(id: "s2a.picture", title: "Picture", rows: [SettingRow(id: "fps60", label: "60 FPS", kind: on, value: "on")]),
        SettingSection(id: "s2a.patches", title: "Community patches", rows: [SettingRow(id: "patch.wsauto:1", label: "Adaptive full screen", note: "Full screen · verified", kind: on, value: "on"),
                                                                             SettingRow(id: "patch.fps:1", label: "60 FPS (FPSLocker)", note: "Frame rate", kind: on, value: "on")]),
        SettingSection(id: "s2a.cheats", title: "Cheats", rows: (1...40).map { SettingRow(id: "cheat.a.txt/\($0)", label: "Cheat \($0)", note: "From the community library", kind: on, value: $0 <= 2 ? "on" : "off") }),
        SettingSection(id: "s2a.vpad", title: "Virtual controller", rows: []),
    ]
    #expect(SGradeGroup.ids == ["s2a.patches", "s2a.cheats"])
    #if os(macOS)
    _ = NSApplication.shared
    // 收起 / 展开两态：放进真的 AppKit 视图再截（ImageRenderer 画不了输入框 / 滚动区）。期望：收起态金手指只占一行汇总，展开只多出限高 320 点的列表与搜索框
    func shot(_ open: Bool) throws -> NSBitmapImageRep {
        let picked = sections.filter { SGradeGroup.ids.contains($0.id) }
        let view = SGradeGroup(gameID: "0100F2C0115B6000", sections: picked, onChange: { _, _ in }, startOpen: open)
            .frame(width: 430).padding(20).background(Color(red: 0.04, green: 0.04, blue: 0.05)).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view); host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false); window.contentView = host
        host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["S2A_SGRADE_SHOT"] { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ios_sgrade_\(open ? "open" : "closed").png")) }
        return rep
    }
    let closed = try shot(false), opened = try shot(true)
    #expect(closed.pixelsHigh < 1300, "收起态高 \(closed.pixelsHigh)（40 条金手指只占一行汇总）")
    #expect(opened.pixelsHigh - closed.pixelsHigh < 820, "展开只多出限高的列表与搜索框：多了 \(opened.pixelsHigh - closed.pixelsHigh)")
    #endif
}
