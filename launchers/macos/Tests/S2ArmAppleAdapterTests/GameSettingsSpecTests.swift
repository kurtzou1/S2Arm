import XCTest
@testable import S2ArmAppleAdapter

/// 启动设置页按共享定义表画：资源包里那份表要读得出来，Mac 有的项按表顺序全在。期望按 launchers/shared/game_settings.v1.json 手抄。
final class GameSettingsSpecTests: XCTestCase {
    func testMacItemsComeFromTheSharedTable() throws {
        let items = try GameSettingsSpec.macItems()
        XCTAssertEqual(items.map(\.id), ["enhance", "fps60", "widescreen", "widenForce", "docked", "language", "patches", "input", "rumble", "rumbleLevel", "motion", "padFace", "hud", "pauseUnfocused", "diagRun"])
        let enhance = try XCTUnwrap(items.first { $0.id == "enhance" })
        XCTAssertEqual(enhance.text("zh-Hans"), "画面增强模式")
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == "docked" }).options.map(\.value), ["docked", "handheld"])
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == "rumbleLevel" }).options.count, 6)
    }

    func testBrokenTableIsAnError() {
        XCTAssertThrowsError(try GameSettingsSpec.macItems(Data(#"{"contract":"other","items":[]}"#.utf8)))
        XCTAssertThrowsError(try GameSettingsSpec.macItems(Data(#"{"contract":"s2a.game-settings.v1","items":[{"platforms":["mac"]}]}"#.utf8)))
    }
}
