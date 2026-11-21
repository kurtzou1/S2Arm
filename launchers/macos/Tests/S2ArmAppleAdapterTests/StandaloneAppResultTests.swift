import Foundation
import XCTest
@testable import S2ArmAppleAdapter

/// 独立 App（0.6.4）的作业结果读进 StandaloneApp：成功页 A / B 与失败页 appInstalled 同一个解析。期望手写
final class StandaloneAppResultTests: XCTestCase {
    func testInstalledFields() {
        let a = StandaloneApp(["appName": "Game One", "ipaPath": "/l/games/G/Game One v1.2.0.ipa", "gameFolder": "/l/games/G", "signMode": "appleId",
                               "expiresAt": NSNumber(value: 1_800_000_000.0), "expiresKnown": false, "nextSteps": ["a"], "ipaBytes": NSNumber(value: 42)])
        XCTAssertEqual(a.name, "Game One"); XCTAssertEqual(a.ipaBytes, 42); XCTAssertEqual(a.nextSteps, ["a"])
        XCTAssertEqual(a.expiresAt, Date(timeIntervalSince1970: 1_800_000_000)); XCTAssertFalse(a.expiresKnown); XCTAssertFalse(a.exported)
        XCTAssertEqual(a.signedCert, "")
    }
    func testExportFields() {
        let a = StandaloneApp(["appName": "G", "exported": true, "s2armPath": "/f/G.s2arm", "resourcePath": "/f/G.img", "resourceLinked": true,
                               "signedWith": ["mode": "devCert", "name": "Acme"]])
        XCTAssertTrue(a.exported); XCTAssertTrue(a.resourceLinked); XCTAssertEqual(a.signedCert, "Acme")
        XCTAssertEqual(StandaloneApp(["signedWith": ["mode": "none", "name": "x"]]).signedCert, "", "未签名不写证书名")
    }
    func testStandaloneHint() {
        XCTAssertEqual(InstallModeInfo(result: ["standaloneHint": "wildcard"]).standaloneHint, "wildcard")
        XCTAssertNil(InstallModeInfo(result: [:]).standaloneHint)
    }
}
