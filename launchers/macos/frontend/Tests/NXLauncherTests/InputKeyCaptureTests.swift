// S2Arm（不是上游文件）：键位弹窗录键规则（InputKeyCapture，#1606 ④ 键盘录入改进，Ting2024）。期望照规则手写：
//   Mac 键码 Shift 56 / 右 Shift 60、Control 59 / 右 62、Option 58 / 右 61、A 0、Esc 53；修饰位 Shift 1 / Control 2 / Option 4
import XCTest
@testable import NX2AppleUI

final class InputKeyCaptureTests: XCTestCase {
    func testModifierHeldThenKeyRecordsTheCombo() {
        var c = InputKeyCapture()
        XCTAssertNil(c.event(code: 56, modifiers: 1, flagsChanged: true), "按下 Shift 先不录：可能要按组合")
        XCTAssertEqual(c.event(code: 0, modifiers: 1, flagsChanged: false), .bind(KeyBinding(code: 0, modifiers: 1)), "按着 Shift 按 A → Shift+A")
        XCTAssertNil(c.event(code: 56, modifiers: 0, flagsChanged: true), "随后松开 Shift 不再录一次")
    }
    func testModifierAloneRecordsOnRelease() {
        var c = InputKeyCapture()
        XCTAssertNil(c.event(code: 60, modifiers: 1, flagsChanged: true))
        XCTAssertEqual(c.event(code: 60, modifiers: 0, flagsChanged: true), .bind(KeyBinding(code: 56, modifiers: 0)), "单按右 Shift 松开 → 录成 Shift（左右并成一个）")
    }
    func testEscapeCancelsRepeatsAndCommandAreIgnored() {
        var c = InputKeyCapture()
        XCTAssertEqual(c.event(code: 53, modifiers: 0, flagsChanged: false), .cancel)
        XCTAssertNil(c.event(code: 0, modifiers: 0, flagsChanged: false, repeatKey: true), "自动重复不录")
        XCTAssertNil(c.event(code: 0, modifiers: 0, flagsChanged: false, command: true), "带 ⌘ 的交给系统")
        XCTAssertEqual(c.event(code: 0, modifiers: 0, flagsChanged: false), .bind(KeyBinding(code: 0, modifiers: 0)))
    }
    func testReleaseWithoutPressAndResetRecordNothing() {
        var c = InputKeyCapture()
        XCTAssertNil(c.event(code: 59, modifiers: 0, flagsChanged: true), "没见到按下的松开不录")
        XCTAssertNil(c.event(code: 59, modifiers: 2, flagsChanged: true))
        c.reset()   // 失焦 / 停止录入
        XCTAssertNil(c.event(code: 59, modifiers: 0, flagsChanged: true), "reset 之后的松开不录")
    }
}
