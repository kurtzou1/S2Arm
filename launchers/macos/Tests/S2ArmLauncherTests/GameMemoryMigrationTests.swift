import XCTest
@testable import S2ArmLauncher

@MainActor final class GameMemoryMigrationTests: XCTestCase {
    func testOldLayoutPreferenceIsRemovedWithoutChangingOtherSettings() throws {
        var preferences = Preferences()
        preferences.appearance = "dark"
        preferences.devHud = true
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        saved["gameVammLayouts"] = ["first": "balanced", "second": "unknown-layout"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-memory-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: saved).write(to: root.appendingPathComponent("preferences.json"))
        let store = Store(privateRoot: root)
        XCTAssertEqual(store.preferences.appearance, "dark")
        XCTAssertEqual(store.preferences.devHud, true)
        XCTAssertNil(store.launchOptions(for: "first")["gameLanguage"])   // 请求不带游戏语言：玩家选的语言走启动设置 launch.json（作业层 community）
        XCTAssertNil(store.launchOptions(for: "first")["vammLayout"])
        XCTAssertNil(store.launchOptions(for: "second")["vammLayout"])
        store.savePreferences()
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("preferences.json"))) as? [String: Any])
        XCTAssertNil(written["gameVammLayouts"])
        XCTAssertEqual(store.preferences.devHud, true)
        XCTAssertTrue(store.processes.isEmpty)
        XCTAssertTrue(store.queue.isEmpty)
    }
}
