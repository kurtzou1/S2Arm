// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import XCTest
@testable import NX2AppleUI

/// 控制口 /snapshot 只走视图层级离屏截图（不弹屏幕录制授权框），要把弹出层叠上去：
///   主窗口开着 sheet 时系统把主窗口压暗，只画主窗口就是一张整体发灰的图，看着像界面卡了一层蒙层。
@MainActor final class SnapshotSheetTests: XCTestCase {
    private func window(_ frame: NSRect, _ color: NSColor) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size)); v.wantsLayer = true; v.layer?.backgroundColor = color.cgColor
        w.contentView = v; w.setFrame(frame, display: false)
        return w
    }

    private func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ yFromTop: Int) -> NSColor {
        rep.colorAt(x: x, y: yFromTop)!.usingColorSpace(.deviceRGB)!
    }

    // 期望（手写）：主窗口 200×100 全蓝，弹出层 100×50 全红、居中（主窗口左下原点 50,25）；叠完后中心是红、左上角仍是蓝。
    func testOverlayDrawsSheetAtItsPositionOverMainWindow() throws {
        _ = NSApplication.shared
        let main = window(NSRect(x: 0, y: 0, width: 200, height: 100), .blue)
        let sheet = window(NSRect(x: 50, y: 25, width: 100, height: 50), .red)
        let base = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4,
                                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let ctx = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: base))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 200, height: 100).fill()
        NSGraphicsContext.restoreGraphicsState()

        let out = try XCTUnwrap(S2ArmControl.overlay([sheet], on: base, main: main))
        let mid = pixel(out, 100, 50), corner = pixel(out, 5, 5)
        XCTAssertGreaterThan(mid.redComponent, 0.8, "弹出层叠在中间"); XCTAssertLessThan(mid.blueComponent, 0.2)
        XCTAssertGreaterThan(corner.blueComponent, 0.8, "弹出层外面还是主窗口"); XCTAssertLessThan(corner.redComponent, 0.2)
        XCTAssertNil(S2ArmControl.overlay([], on: base, main: main), "没有弹出层不动原图")
    }
}
