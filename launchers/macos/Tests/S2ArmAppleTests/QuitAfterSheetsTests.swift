import XCTest
import AppKit
@testable import NX2AppleUI

// 更新弹窗里点「现在更新」没反应（11-14，0.3.5 → 0.3.6）：窗口挂着 sheet 时 NSApp.terminate 被 AppKit 忽略。
// 期望手写（AppKit 行为另用最小程序实测：挂着 sheet 调 terminate 3 秒后进程还在，没有 sheet 立刻退）：
//   挂着 sheet 时不调退出；sheet 摘掉后调一次，且调的那一刻窗口上没有 sheet。退出动作是注入的，不真退测试进程。
@MainActor final class QuitAfterSheetsTests: XCTestCase {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        return NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    }

    func testNoSheetQuitsAtOnce() {
        let host = window()
        var calls = 0
        QuitAfterSheets.run(windows: { [host] }) { calls += 1 }
        XCTAssertEqual(calls, 1, "没有 sheet：当场退")
    }

    func testWaitsUntilSheetIsGone() async {
        let host = window(), sheet = window()
        host.beginSheet(sheet, completionHandler: nil)
        XCTAssertNotNil(host.attachedSheet, "前提：sheet 挂上了")
        var calls = 0, attachedAtQuit: Bool?
        QuitAfterSheets.run(windows: { [host] }) { calls += 1; attachedAtQuit = host.attachedSheet != nil }
        XCTAssertEqual(calls, 0, "挂着 sheet：这时退出会被系统忽略，不能调")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(calls, 0, "sheet 还在就一直不调")
        host.endSheet(sheet)
        for _ in 0..<80 where calls == 0 { try? await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertEqual(calls, 1, "sheet 摘掉后退一次")
        XCTAssertEqual(attachedAtQuit, false, "退的那一刻窗口上没有 sheet")
    }

    func testClosesSheetThatStaysUp() async {
        let host = window(), sheet = window()
        host.beginSheet(sheet, completionHandler: nil)
        var calls = 0, attachedAtQuit: Bool?
        QuitAfterSheets.run(windows: { [host] }) { calls += 1; attachedAtQuit = host.attachedSheet != nil }
        // 没人摘：forcePolls × pollSeconds = 1 秒后主动摘，再退
        for _ in 0..<160 where calls == 0 { try? await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertEqual(calls, 1, "一直挂着的 sheet 由它摘掉再退")
        XCTAssertEqual(attachedAtQuit, false)
    }
}
