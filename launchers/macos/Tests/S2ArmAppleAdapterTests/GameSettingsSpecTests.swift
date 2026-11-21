import XCTest
@testable import S2ArmAppleAdapter

/// 启动设置页按共享定义表画：资源包里那份表要读得出来，Mac 有的项按表顺序全在。期望按 launchers/shared/game_settings.v1.json 手抄。
final class GameSettingsSpecTests: XCTestCase {
    func testMacItemsComeFromTheSharedTable() throws {
        let items = try GameSettingsSpec.macItems()
        XCTAssertEqual(items.map(\.id), ["quality", "fps60", "fpsPick", "resolutionScale", "fpsLimit", "widescreen", "docked", "language", "patches", "input", "rumble", "rumbleLevel", "motion", "motionInvertY", "motionInvertX", "ldnMode", "ldnHost", "ldnAddress", "padFace", "snapshot", "hud", "cheats", "mods", "pauseUnfocused", "audioLatency", "audioDevice", "vsSpeakers", "vsHeadphones", "diagRun"])
        // 输出设备类型（#189 后续，5.1 虚拟环绕第二片）：四选一，external 档带「不使用虚拟环绕」的说明
        let device = try XCTUnwrap(items.first { $0.id == "audioDevice" })
        XCTAssertEqual(device.options.map(\.value), ["auto", "builtin", "headphones", "external"])
        XCTAssertEqual(device.options.map { $0.label["zh-Hans"] ?? "" }, ["自动", "内置扬声器", "耳机", "外接 / 电视音箱"])
        XCTAssertEqual(device.options.map { $0.detail("zh-Hans") }, ["按输出设备真实声道判：≥6 声道直通 5.1，不足 6 声道折为立体声", "可开「扬声器虚拟环绕」", "可开「耳机虚拟环绕」", "≥6 声道直通 5.1；<6 声道普通下混；不使用虚拟环绕"])
        // 画质提升（11-15 取代「画面增强模式」）：四档（FSR 后加），只有锐利放大带一句代价（选中时写在标题下）
        let quality = try XCTUnwrap(items.first { $0.id == "quality" })
        XCTAssertEqual(quality.text("zh-Hans"), "画质提升")
        XCTAssertEqual(quality.options.map(\.value), ["Bilinear", "Nearest", "MetalFX", "Fsr"])
        XCTAssertEqual(quality.options.map { $0.label["zh-Hans"] ?? "" }, ["标准", "2D 游戏专用", "锐利放大（MetalFX）", "FSR 锐化放大"])
        XCTAssertEqual(quality.options.map { $0.detail("zh-Hans") }, [nil, nil, "锐利放大（MetalFX）会每帧多花一点显卡时间，帧率和能耗会略有影响。", nil])
        XCTAssertEqual(quality.detail("zh-Hans"), "")
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == "docked" }).options.map(\.value), ["docked", "handheld"])
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == "rumbleLevel" }).options.count, 6)
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == "ldnMode" }).options.map(\.value), ["auto", "manual", "switch"])
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == "ldnAddress" }).type, "text")
    }

    func testBrokenTableIsAnError() {
        XCTAssertThrowsError(try GameSettingsSpec.macItems(Data(#"{"contract":"other","items":[]}"#.utf8)))
        XCTAssertThrowsError(try GameSettingsSpec.macItems(Data(#"{"contract":"s2a.game-settings.v1","items":[{"platforms":["mac"]}]}"#.utf8)))
    }
}
