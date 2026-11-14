import Foundation
import Testing
import ShellUI
@testable import S2ArmShellHost

// 首次进入引导（S2ArmGuideView）：这台设备第一次打开游戏库弹，关掉后重开（新建模型）不再弹；开着时手柄只管引导。期望按规则手写

@MainActor @Test func guideShowsOnceAndTheControllerDrivesIt() throws {
    let name = "s2a.test.guide." + UUID().uuidString
    let d = try #require(UserDefaults(suiteName: name)); defer { d.removePersistentDomain(forName: name) }
    let stores = S2ArmGameSettings.Stores(game: { _ in nil }, app: d)
    let cat = Catalogue.parse(Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"}]}"#.utf8), baseDirectory: URL(fileURLWithPath: "/"))
    let model = S2ArmShellHostModel(catalogue: cat, play: { _ in }, stores: stores, installState: { _ in 1 })
    #expect(model.guideOpen && model.guidePage == 0)
    model.guideInput(.left); #expect(model.guidePage == 0)            // 第一页往左不越界
    model.guideInput(.right); model.guideInput(.activate); #expect(model.guidePage == 2)
    model.guideInput(.right); #expect(model.guidePage == 2)           // 最后一页往右不越界
    model.guideInput(.up); #expect(model.guideOpen)                    // 不认识的键不关
    model.guideInput(.activate); #expect(!model.guideOpen)             // 最后一页 A = 开始玩，记看过
    let reopened = S2ArmShellHostModel(catalogue: cat, play: { _ in }, stores: stores, installState: { _ in 1 })
    #expect(!reopened.guideOpen)
}

@MainActor @Test func guideClosesWithBOnAnyPage() throws {
    let name = "s2a.test.guide." + UUID().uuidString
    let d = try #require(UserDefaults(suiteName: name)); defer { d.removePersistentDomain(forName: name) }
    let stores = S2ArmGameSettings.Stores(game: { _ in nil }, app: d)
    let cat = Catalogue.parse(Data(#"{"schema":1,"games":[]}"#.utf8), baseDirectory: URL(fileURLWithPath: "/"))
    let model = S2ArmShellHostModel(catalogue: cat, play: { _ in }, stores: stores, installState: { _ in 1 })
    model.guideInput(.right); model.guideInput(.back)
    #expect(!model.guideOpen && d.bool(forKey: S2ArmShellHostModel.guideSeenKey))
}
