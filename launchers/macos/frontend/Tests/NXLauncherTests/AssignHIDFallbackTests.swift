// S2Arm（不是上游文件）：分配玩家收 HID 兜底手柄（#1151：PowerA WLC001「Lic Pro Controller」GameController 认不出、宿主按 HID 读，
//   游戏里能用，分配页却没有它、按 L + R 也没反应）。期望照规则手写：兜底手柄并在系统手柄后面、按「名字 + 同名第几只」认、
//   GameController 已列出的同名手柄不重复；接上即自动排进玩家位（同系统手柄）
import XCTest
@testable import NX2AppleUI

@MainActor final class AssignHIDFallbackTests: XCTestCase {
    private let ds = "DualSense Wireless Controller", powerA = "Lic Pro Controller"
    private func pad(_ name: String) -> SystemControllers.Pad { .init(id: ObjectIdentifier(NSObject()), name: name, family: .playstation) }

    func testFallbackPadsJoinTheSystemKeys() {
        let keys = SystemControllers.assignmentKeys(pads: [pad(ds)], hidNames: [powerA, ds, powerA])
        XCTAssertEqual(keys, [.init(name: ds, index: 0), .init(name: powerA, index: 0), .init(name: powerA, index: 1)],
                       "系统手柄在前；兜底两只同名各算一只；GameController 已列出的 DualSense 不重复")
        XCTAssertEqual(SystemControllers.assignmentKeys(pads: [], hidNames: [powerA]), [.init(name: powerA, index: 0)], "只连 PowerA 也有它")
    }
    func testFallbackPadAutoJoinsWithoutLR() {
        var a = PlayerAssignment()
        _ = a.reconcile(devices: [], mergedPair: false, system: SystemControllers.assignmentKeys(pads: [], hidNames: [powerA]))
        XCTAssertEqual(a.units, [.system(name: powerA, index: 0)], "只连 PowerA：接上即是 P1，不用按 L + R")
        _ = a.reconcile(devices: [], mergedPair: false, system: SystemControllers.assignmentKeys(pads: [pad(ds)], hidNames: [powerA]))
        XCTAssertEqual(a.units, [.system(name: powerA, index: 0), .system(name: ds, index: 0)], "再连 DualSense 排 P2，PowerA 仍是 P1")
    }
}
