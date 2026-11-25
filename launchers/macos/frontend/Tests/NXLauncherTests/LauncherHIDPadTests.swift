// S2Arm（不是上游文件）：启动器游戏库读 HID 兜底手柄（#1151：PowerA WLC001「Lic Pro Controller」在游戏库里推摇杆 / 按十字键选不动）。
//   期望照 Switch Pro 报告格式与 Npad 位手写（第 0 位 A、第 12 / 14 位 左 / 右），不由被测实现推出
import XCTest
import LauncherPadBridge
@testable import NX2AppleUI

@MainActor final class LauncherHIDPadTests: XCTestCase {
    private let left: UInt32 = 1 << 12, right: UInt32 = 1 << 14, a: UInt32 = 1 << 0
    private func pad(_ name: String, buttons: UInt32 = 0, lx: Int16 = 0, ly: Int16 = 0) -> s2a_launcher_hid_pad {
        var p = s2a_launcher_hid_pad(); p.buttons = buttons; p.lx = lx; p.ly = ly; p.pro = 1
        withUnsafeMutableBytes(of: &p.name) { raw in for (i, c) in name.utf8.prefix(raw.count - 1).enumerated() { raw[i] = c } }
        return p
    }
    private func read(_ s: OpaquePointer) -> s2a_launcher_hid_pad { var out = s2a_launcher_hid_pad(); s2a_launcher_hid_state_pad(s, &out); return out }

    func testProSimpleReportElements() {
        let s = s2a_launcher_hid_state_new(1)!; defer { s2a_launcher_hid_state_free(s) }
        s2a_launcher_hid_value(s, 1, 0x39, 6, 0, 7)            // 方向键：0 上，顺时针，6 = 左
        s2a_launcher_hid_value(s, 9, 2, 1, 0, 1)               // 简单报告按键号 2 = A
        s2a_launcher_hid_value(s, 1, 0x30, 0, 0, 65535)        // 左摇杆横轴推到最左
        let p = read(s)
        XCTAssertEqual(p.buttons, left | a, "简单报告：方向键左 + A → Npad 第 12 位 + 第 0 位")
        XCTAssertEqual(p.lx, -32767)
    }

    func testProFullReportAfterTheHostSwitchedIt() {
        let s = s2a_launcher_hid_state_new(1)!; defer { s2a_launcher_hid_state_free(s) }
        // 0x30：按键第 3 字节右侧、第 4 字节共用、第 5 字节左侧（0x08 = 十字键左）；左摇杆 x = 2048 − 1003 = 1045（缺省行程推到底），y = 2048；右摇杆居中
        var r = [UInt8](repeating: 0, count: 49); r[0] = 0x30; r[5] = 0x08
        r[6] = 0x15; r[7] = 0x04; r[8] = 0x80; r[9] = 0x00; r[10] = 0x08; r[11] = 0x80
        XCTAssertEqual(s2a_launcher_hid_report(s, r, r.count), 1)
        s2a_launcher_hid_value(s, 9, 2, 1, 0, 1)               // 收过 0x30 之后元素那一路不再算
        let p = read(s)
        XCTAssertEqual(p.buttons, left, "完整报告：十字键左；之后的元素值不混进来")
        XCTAssertEqual(p.lx, -32767); XCTAssertEqual(p.ly, 0)
    }

    func testGenericPadByPosition() {
        let s = s2a_launcher_hid_state_new(0)!; defer { s2a_launcher_hid_state_free(s) }
        s2a_launcher_hid_has_axis(s, 1, 0x30); s2a_launcher_hid_has_axis(s, 1, 0x31)
        s2a_launcher_hid_value(s, 9, 2, 1, 0, 1)               // 缺省按位置映射：按键号 2 = A
        s2a_launcher_hid_value(s, 1, 0x39, 2, 0, 7)            // 方向键 2 = 右
        XCTAssertEqual(read(s).buttons, a | right)
    }

    func testFallbackPadMovesTheLibrarySelection() {
        let source = LauncherPadSource()
        var hid = [pad("Lic Pro Controller")]
        source.controllers = { [] }; source.isActive = { true }; source.hidPads = { hid }
        var got: [LauncherPadAction] = []
        source.receive = { got.append($0) }
        source.tick(now: 0)                                      // 先松手（返回游戏库后按着的键不算）
        hid = [pad("Lic Pro Controller", buttons: right)]; source.tick(now: 0.1)
        hid = [pad("Lic Pro Controller")]; source.tick(now: 0.2)
        hid = [pad("Lic Pro Controller", lx: -30000)]; source.tick(now: 0.3)
        XCTAssertEqual(got, [.right, .left], "PowerA 十字键右 → 右；摇杆推左 → 左（原先只读 GameController，两次都没有）")
    }

    func testGameControllerListedPadIsNotReadTwice() {
        let hid = [pad("Lic Pro Controller"), pad("Stadia Controller rev. A")]
        let kept = LauncherPadInput.fallback(hid, system: ["stadia controller REV. A"]).map(LauncherPadInput.hidName)
        XCTAssertEqual(kept, ["Lic Pro Controller"], "GameController 已列出同名（大小写不敏感）的让位")
    }
}
