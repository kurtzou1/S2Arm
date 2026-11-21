import Foundation
import XCTest
@testable import S2ArmAppleAdapter

/// 签名方式三选一（自签走查结构 6）：installMode 作业的 signChoice 读进 InstallModeInfo；缺省（旧作业层没有这个字段）按 Apple ID。期望手写
final class SignChoiceTests: XCTestCase {
    func testSignChoiceParsed() {
        XCTAssertEqual(InstallModeInfo(result: ["exportAvailable": true, "signMode": "appleId", "signChoice": "external"]).signChoice, "external")
        XCTAssertEqual(InstallModeInfo(result: ["signMode": "devcert", "signChoice": "devCert"]).signChoice, "devCert")
        XCTAssertEqual(InstallModeInfo(result: ["signMode": "appleId"]).signChoice, "appleId", "旧作业层不带 signChoice：按 Apple ID")
        XCTAssertEqual(InstallModeInfo().signChoice, "appleId")
    }

    /// 出法没读回（缺省构造）≠ 读回了 shell：界面据此决定两张卡画不画选中（0.6.2 前端走查）
    func testInstallModeLoadedOnlyFromJobResult() {
        XCTAssertFalse(InstallModeInfo().loaded)
        XCTAssertTrue(InstallModeInfo(result: [:]).loaded)
        XCTAssertEqual(InstallModeInfo(result: ["layout": "standalone"]).layout, "standalone")
    }
}
