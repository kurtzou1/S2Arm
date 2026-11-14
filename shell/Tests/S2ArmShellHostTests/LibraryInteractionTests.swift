// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import Testing
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import ShellUI
@testable import S2ArmShellHost

@MainActor @Test func libraryOrderPersistsAndReconcilesCatalogue() throws {
    let suite = "s2a.test.order.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let stores = S2ArmGameSettings.Stores(game: { _ in nil }, app: defaults)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let tiles = (1...4).map { GameTile(id: String(format: "%016X", $0), title: "Game \($0)") }
    let ids = tiles.map(\.id)
    func model(_ entries: [GameTile]) -> S2ArmShellHostModel {
        S2ArmShellHostModel(catalogue: Catalogue(tiles: entries, problems: []), stores: stores,
                           installState: { _ in 1 }, gamesRoot: root)
    }
    let first = model(Array(tiles.prefix(3)))
    #expect(first.games.map(\.id) == Array(ids.prefix(3)))
    let move = try #require(first.actions.onReorderGames)
    #expect(move([ids[0]], nil))
    #expect(first.games.map(\.id) == [ids[1], ids[2], ids[0]])
    first.refreshGameData()
    #expect(first.games.map(\.id) == [ids[1], ids[2], ids[0]])
    let reopened = model(tiles)
    #expect(reopened.games.map(\.id) == [ids[1], ids[2], ids[0], ids[3]])
    let moveBack = try #require(reopened.actions.onReorderGames)
    #expect(moveBack([ids[0]], ids[1]))
    #expect(reopened.games.map(\.id) == ids)
    #expect(!moveBack([ids[0]], ids[0]))
    #expect(!moveBack(["unknown"], ids[1]))
    #expect(!moveBack([ids[0]], "unknown"))
    #expect(reopened.games.map(\.id) == ids)
    defaults.set([ids[2], ids[2], "removed", ids[0]], forKey: "S2ALibraryOrder")
    #expect(model(tiles).games.map(\.id) == [ids[2], ids[0], ids[1], ids[3]])
    #expect(model([tiles[1], tiles[3]]).games.map(\.id) == [ids[1], ids[3]])
}

@MainActor @Test func carouselTitleTracksCentreBeforeScrollSettles() {
    let games = (1...5).map { GameDetail(game: GameTile(id: "\($0)", title: "Title \($0)")) }
    func title(_ offset: CGFloat, selected: Int = 0, scrolling: Bool = true) -> String {
        CoverFlowSelection.game(games: games, selected: games[selected], offset: offset, stride: 100, scrolling: scrolling).game.title
    }
    #expect(title(49) == "Title 1")
    #expect(title(51) == "Title 2")
    #expect(title(260) == "Title 4")
    #expect(title(140, selected: 3) == "Title 2")
    #expect(title(-80) == "Title 1")
    #expect(title(700) == "Title 5")
    #expect(title(100, selected: 3, scrolling: false) == "Title 4")
    #expect(CoverFlowSelection.game(games: [], selected: games[0], offset: 100, stride: 100, scrolling: true).id == "1")
}

@MainActor @Test func nativeReorderCommitsInsertionAndPersists() throws {
    let suite = "s2a.test.native-order.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tiles = (1...5).map { GameTile(id: "\($0)", title: "Game \($0)") }
    let stores = S2ArmGameSettings.Stores(game: { _ in nil }, app: defaults)
    func model() -> S2ArmShellHostModel {
        S2ArmShellHostModel(catalogue: Catalogue(tiles: tiles, problems: []), stores: stores,
                           installState: { _ in 1 })
    }
    let library = model()
    let reorder = try #require(library.actions.onReorderGames)
    // Native reordering previews positions without changing the model until the drop callback.
    #expect(defaults.stringArray(forKey: "S2ALibraryOrder") == nil)
    #expect(reorder(["1"], "4"))
    #expect(library.games.map(\.id) == ["2", "3", "1", "4", "5"])
    #expect(reorder(["3", "1"], nil))
    #expect(library.games.map(\.id) == ["2", "4", "5", "3", "1"])
    #expect(reorder(["5"], "2"))
    #expect(model().games.map(\.id) == ["5", "2", "4", "3", "1"])
    let saved = defaults.stringArray(forKey: "S2ALibraryOrder")
    #expect(!reorder([], nil))
    #expect(!reorder(["5", "5"], nil))
    #expect(!reorder(["unknown"], nil))
    #expect(!reorder(["5"], "unknown"))
    #expect(!reorder(["5"], "5"))
    #expect(defaults.stringArray(forKey: "S2ALibraryOrder") == saved)
}

@MainActor @Test func nativeReorderRejectsHiddenItemsAndKeepsPendingGames() throws {
    let suite = "s2a.test.native-hidden.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tiles = (1...4).map { GameTile(id: "\($0)", title: "Game \($0)") }
    var ready = Set(["1", "3", "4"])
    // 隐藏项 = 玩家在这台设备上删掉、资源也不在的款（审计 P1-155 起，资源没到位但没删过的款留在库里）
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2a-hidden-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("2".utf8).write(to: root.appendingPathComponent(".s2a-removed.txt"))
    let model = S2ArmShellHostModel(catalogue: Catalogue(tiles: tiles, problems: []),
        stores: .init(game: { _ in nil }, app: defaults), installState: { ready.contains($0) ? 1 : 0 }, gamesRoot: root)
    let reorder = try #require(model.actions.onReorderGames)
    #expect(!reorder(["1", "2"], "4"))
    #expect(!reorder(["1"], "2"))
    #expect(model.games.map(\.id) == ["1", "3", "4"])
    #expect(reorder(["4"], "1"))
    ready.insert("2")
    model.refreshGameData()
    #expect(model.games.map(\.id) == ["4", "1", "2", "3"])
}

@Test func listReorderConvertsOriginalOffsetsToStableInsertionIDs() throws {
    let ids = ["a", "b", "c", "d", "e"]
    let down = try #require(GameOrderMove(ids: ids, offsets: IndexSet(integer: 0), destination: 3))
    #expect(down.sources == ["a"])
    #expect(down.before == "d")
    let up = try #require(GameOrderMove(ids: ids, offsets: IndexSet(integer: 4), destination: 0))
    #expect(up.before == "a")
    let end = try #require(GameOrderMove(ids: ids, offsets: IndexSet([1, 3]), destination: 5))
    #expect(end.sources == ["b", "d"])
    #expect(end.before == nil)
    #expect(GameOrderMove(ids: ids, offsets: IndexSet(integer: 1), destination: 2) == nil)
    #expect(GameOrderMove(ids: ids, offsets: IndexSet(), destination: 1) == nil)
    #expect(GameOrderMove(ids: ids, offsets: IndexSet(integer: 5), destination: 0) == nil)
    #expect(GameOrderMove(ids: ids, offsets: IndexSet(integer: 0), destination: 6) == nil)
}

@Test func carouselWindowKeepsTransformedNeighboursAndBoundsMountedCards() {
    // 678-point viewport, 160-point covers. Far centres are 78.4 points apart with a 43.2-point offset.
    // At centre 15, cards 11 through 19 intersect the viewport; 9 through 21 include edge preload.
    #expect(CoverFlowWindow.indices(count: 30, offset: 15 * 166.4, width: 678, cover: 160) == 9..<22)
    #expect(CoverFlowWindow.indices(count: 30, offset: 0, width: 678, cover: 160) == 0..<7)
    #expect(CoverFlowWindow.indices(count: 30, offset: 29 * 166.4, width: 678, cover: 160) == 23..<30)
    #expect(CoverFlowWindow.indices(count: 300, offset: 150 * 166.4, width: 678, cover: 160) == 144..<157)
    #expect(CoverFlowWindow.indices(count: 30, offset: 15.5 * 166.4, width: 678, cover: 160) == 9..<23)
    #expect(CoverFlowWindow.indices(count: 0, offset: 0, width: 678, cover: 160).isEmpty)
    #expect(CoverFlowWindow.indices(count: 30, offset: .infinity, width: 678, cover: 160).isEmpty)
}

#if os(macOS)
@MainActor @Test func carouselControlsFitNarrowLandscapeAndSingleGameHidesReorder() async throws {
    for count in [1, 30] {
        for showsHints in [false, true] {
            let games = (1...count).map { GameDetail(game: GameTile(id: "\($0)", title: "Game \($0)")) }
            let targets = FocusTargetBuffer()
            let view = CoverFlowView(games: games, selected: games[0], controllers: 1, showsHints: showsHints,
                                     select: { _ in }, primary: { _ in }, openSettings: {},
                                     openControllers: {}, openShellSettings: {})
                .environment(\.shellOpenGameOrder, {})
                .frame(width: 678, height: 320)
                .coordinateSpace(name: "shell")
                .onPreferenceChange(FocusTargets.self) { targets.values = $0 }
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 678, height: 320),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let controls = targets.values.filter { ["lib.reorder", "lib.settings", "lib.controllers", "lib.shellSettings"].contains($0.id) }
            #expect(controls.contains { $0.id == "lib.reorder" } == (count > 1))
            for id in ["lib.settings", "lib.controllers", "lib.shellSettings"] {
                let control = try #require(controls.first { $0.id == id })
                #expect(control.frame.minX >= 0 && control.frame.maxX <= 678)
                #expect(control.frame.width >= 40)
                #expect(control.frame.minY >= 0 && control.frame.maxY <= 64)
            }
            if count == 30 {
                let mounted = targets.values.filter { $0.id.hasPrefix("lib.tile.") }
                #expect(!mounted.isEmpty)
                #expect(mounted.count < 15)
                #expect(mounted.contains { $0.id == "lib.tile.2" })
            }
        }
    }
}
#endif

#if canImport(SwiftUI)
@Test func phoneUprightGetsASplitScreenForTheEditor() {
    // 11-13 不许堵门：普通 iPhone 也能开上下分屏，编辑器原先只给折叠屏 / iPad 竖屏，iPhone 改不了分屏布局。
    //   手算：440×956 点竖屏、上安全区 62、下有主屏指示条 → 竖屏画布 440×956、上 62 下 34；无折痕按中线 478 分：上区 (0,62,440,416)、按键区从 478 起
    let s = TouchLayoutScreens.device(window: CGSize(width: 440, height: 956), insets: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0), isPad: false)
    #expect(s.upright?.size == CGSize(width: 440, height: 956))
    #expect(s.upright?.insets.top == 62 && s.upright?.insets.bottom == 34 && s.upright?.division == nil)
    let r = PadGeo.region(s.upright!)
    #expect(r.separated && r.controls.minY == 478 && r.game.width == 440)
}
#endif
