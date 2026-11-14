// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
@testable import NX2AppleUI

// 手柄弹窗「两只怎么用」（#520 D）：连着两只 Joy-Con 才出这一段，标题 / 选中的那格跟连接程序报的玩家数走。
//   设 S2A_SNAPSHOT_OUT=<目录> 存 ns2_single / ns2_pair / ns2_split（中英各一）供肉眼核对。
@MainActor final class NS2PanelSnapshotTests: XCTestCase {
    /// 不碰本机真的分配（偏好与 pad-order.json 都换成临时的）
    static func isolated() -> NS2LauncherController {
        let suite = "s2arm-panel-test-" + UUID().uuidString
        return NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-panel-test.sock"), store: UserDefaults(suiteName: suite),
                                     orderFile: FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json"))
    }
    /// 面板：蓝牙手柄照工具栏那样交给分配整理（自动排进玩家位）
    static func panel(_ c: NS2LauncherController, _ systems: SystemControllers, _ zh: Bool) -> Switch2ProConnectionPopover {
        c.updateSystem(systems.presentKeys)
        return Switch2ProConnectionPopover(controller: c, systems: systems, simplifiedChinese: zh)
    }
    private func controller(kind: Int, players: Int, kinds: [Int]? = nil) -> NS2LauncherController {
        let c = Self.isolated()
        var line: [String: Any] = ["status": 4, "kind": kind, "players": players, "name": "Joy-Con 2", "battery": 8]
        if let kinds {
            line["kinds"] = kinds
            line["devices"] = kinds.enumerated().flatMap { i, k in k == 4 ? [["kind": 2, "id": "L\(i)"], ["kind": 3, "id": "R\(i)"]] : [["kind": k, "id": "D\(i)"]] }
        }
        c.apply(status: 4, line)
        return c
    }

    func testJoyconUseSection() throws {
        let single = controller(kind: 2, players: 1)
        XCTAssertTrue(single.rememberDevice, "记住这台设备一律开（面板没有开关，#520 UI 稿）")
        XCTAssertEqual(ControllerIcon.header(kind: 4, players: 1), .pairHead)
        XCTAssertEqual(ControllerIcon.header(kind: 2, players: 2), .pairHead, "两只各一位玩家：标题图同一对")
        XCTAssertEqual(ControllerIcon.header(kind: 2, players: 1), .left)
        let pro = controller(kind: 1, players: 1)
        XCTAssertNil(ControllerIcon.header(kind: 0, players: 1), "还不知道型号：通用手柄图")
        XCTAssertEqual(ControllerIcon.player(kind: 2), .leftSideways, "玩家列表里单只 Joy-Con 横着画")
        XCTAssertEqual(ControllerIcon.player(kind: 4), .pairHead)
        XCTAssertEqual(ControllerIcon.systemPlayer(.gen1Right), .gen1RightSideways, "一代单只也横着画")
        XCTAssertEqual(ControllerIcon.systemPlayer(.gen1Pair), .gen1Pair)
        XCTAssertEqual(single.title(simplifiedChinese: true), "Joy-Con 2 (L)")
        let pair = controller(kind: 4, players: 1, kinds: [4])
        XCTAssertEqual(pair.title(simplifiedChinese: true), "Joy-Con 2 (L + R)")
        let split = controller(kind: 3, players: 2, kinds: [3, 2])
        XCTAssertEqual(split.title(simplifiedChinese: true), "2 个 Switch 2 手柄", "两只各一位：标题写手柄数量（玩家在列表里）")
        XCTAssertEqual(split.title(simplifiedChinese: false), "2 Switch 2 controllers")
        XCTAssertEqual(split.playerKinds, [3, 2], "玩家列表：P1 右只、P2 左只（照连接程序报的顺序）")
        XCTAssertEqual(pair.playerKinds, [4], "一对合成一位：P1 是一对")
        XCTAssertEqual(NS2LauncherController.playerKinds(from: ["kind": 4]), [4], "旧连接程序没报 kinds：用 kind 当 P1")
        XCTAssertEqual(NS2LauncherController.playerKinds(from: ["kind": 0]), [], "没连：不出玩家列表")
        XCTAssertEqual(NS2LauncherController.deviceCount(from: ["kind": 4]), 2, "一对 Joy-Con 算两只手柄（出「分配玩家」）")
        XCTAssertEqual(NS2LauncherController.deviceCount(from: ["kind": 3, "devices": [["id": "a"]]]), 1, "单只：不出「分配玩家」")
        // 负对照：旧连接程序不报 players → 当 1 位玩家
        XCTAssertEqual(NS2LauncherController.players(from: ["kind": 4]), 1)
        for (name, c) in [("ns2_single", single), ("ns2_pair", pair), ("ns2_split", split), ("ns2_pro", pro)] {
            try snapshot(name + "_zh", Self.panel(c, SystemControllers(pads: []), true))
            try snapshot(name + "_en", Self.panel(c, SystemControllers(pads: []), false))
        }
    }

    // 连接状态 7 种（#520 UI 稿 status.html）：状态词、下一句、主按钮都照稿；还不知道型号时标题通用标题、虚线图
    func testConnectionStates() throws {
        typealias C = NS2LauncherController
        let expect: [(C.Status, String, String)] = [
            (.notConnected, "未连接", "连接"), (.searching, "搜索中", "停止"), (.connecting, "连接中", "停止"), (.connected, "已连接", "断开"),
            (.inUse, "游戏使用中", "断开"), (.failed, "连接失败", "重新连接"), (.bluetoothUnavailable, "蓝牙不可用", "重新连接")]
        for (status, text, button) in expect {
            XCTAssertEqual(C.statusText(status, simplifiedChinese: true), text)
            XCTAssertEqual(C.mainButton(status, simplifiedChinese: true), button)
        }
        XCTAssertEqual(C.statusText(.inUse, simplifiedChinese: false), "In use by game")
        XCTAssertEqual(C.dotColor(.inUse), C.dotColor(.connected), "游戏使用中是绿点（原先灰点）")

        func make(_ code: Int?, kind: Int = 0, phase: C.Phase? = nil) -> C {
            let c = Self.isolated()
            if let code { c.apply(status: code, ["status": code, "kind": kind]) }
            if let phase { c.setPhaseForTesting(phase) }
            return c
        }
        let states: [(String, C, C.Status)] = [
            ("status_off", make(nil), .notConnected), ("status_searching", make(1), .searching), ("status_connecting", make(2), .connecting),
            ("status_inuse", make(4, kind: 3, phase: .handedOff), .inUse), ("status_failed", make(5), .failed),
            ("status_bluetooth", make(6), .bluetoothUnavailable)]
        for (name, c, status) in states {
            XCTAssertEqual(c.status, status, name)
            try snapshot(name + "_zh", Self.panel(c, SystemControllers(pads: []), true))
        }
        XCTAssertNil(ControllerIcon.header(kind: make(5).kind, players: 1), "失败：型号未知 → 虚线图")
        XCTAssertEqual(make(5).title(simplifiedChinese: true), "Switch 手柄")
    }

    // 系统手柄（#520 F，UI 稿 system.html）：分类、去重、混用时的玩家顺序；图示全套另存一张（含稿里没有、待定的 Xbox / 一代右只 / 其他）
    func testSystemControllers() throws {
        typealias S = SystemControllers
        XCTAssertEqual(S.family(category: "DualSense", vendor: "DualSense Wireless Controller", xbox: false, playstation: true), .playstation)
        XCTAssertEqual(S.family(category: "Xbox One", vendor: "Xbox Wireless Controller", xbox: true, playstation: false), .xbox)
        XCTAssertEqual(S.family(category: "Nintendo Switch Joy-Con (L)", vendor: "Joy-Con (L)", xbox: false, playstation: false), .gen1Left)
        XCTAssertEqual(S.family(category: "Nintendo Switch Joy-Con (L/R)", vendor: "Joy-Con (L/R)", xbox: false, playstation: false), .gen1Pair)
        XCTAssertEqual(S.family(category: "Switch Pro Controller", vendor: "Pro Controller", xbox: false, playstation: false), .nintendoPro)
        XCTAssertEqual(S.family(category: "MFi", vendor: "8BitDo", xbox: false, playstation: false), .other, "认不出照列「其他手柄」")
        XCTAssertNil(S.family(category: "Nintendo Switch 2 Pro Controller", vendor: nil, xbox: false, playstation: false), "Switch 2 手柄 S2Arm 自己读，不重复列")

        let c = Self.isolated()
        c.apply(status: 4, ["status": 4, "kind": 3, "players": 1, "kinds": [3], "devices": [["kind": 3, "id": "R0"]]])
        let ps = S.Pad(id: ObjectIdentifier(NSObject()), name: "DualSense", family: .playstation)
        try snapshot("system_mixed_zh", Self.panel(c, S(pads: [ps]), true))
        let edge = S.Pad(id: ObjectIdentifier(NSObject()), name: "DualSense Edge Wireless Controller", family: .playstation)
        try snapshot("system_only_zh", Self.panel(Self.isolated(), S(pads: [edge]), true))
        let four = Self.isolated()
        four.apply(status: 4, ["status": 4, "kind": 1, "players": 1, "kinds": [1, 2, 3, 1], "devices": [["kind": 1, "id": "a"], ["kind": 2, "id": "b"], ["kind": 3, "id": "c"], ["kind": 1, "id": "d"]]])
        try snapshot("title_four_en", Self.panel(four, S(pads: []), false))
        try snapshot("title_four_zh", Self.panel(four, S(pads: []), true))
        let xb = S.Pad(id: ObjectIdentifier(NSObject()), name: "Xbox Wireless Controller", family: .xbox)
        let gen1 = [S.Pad(id: ObjectIdentifier(NSObject()), name: "Joy-Con (L)", family: .gen1Left), S.Pad(id: ObjectIdentifier(NSObject()), name: "Joy-Con (R)", family: .gen1Right)]
        try snapshot("system_gen1_zh", Self.panel(c, S(pads: gen1), true))
        try snapshot("system_long_zh", Self.panel(c, S(pads: [edge, S.Pad(id: ObjectIdentifier(NSObject()), name: "Xbox Wireless Controller", family: .xbox)]), true))
        try snapshot("system_only_en", Self.panel(Self.isolated(), S(pads: [edge]), false))
        try snapshot("system_long_en", Self.panel(c, S(pads: [edge, S.Pad(id: ObjectIdentifier(NSObject()), name: "Xbox Wireless Controller", family: .xbox)]), false))
        try snapshot("system_two_zh", Self.panel(c, S(pads: [ps, xb]), true))
        let all: [(ControllerIcon.Glyph, String)] = [(.left, "Joy-Con 2 (L)"), (.right, "Joy-Con 2 (R)"), (.leftSideways, "Joy-Con 2 (L) 单只玩家"), (.rightSideways, "Joy-Con 2 (R) 单只玩家"), (.pairHead, "Joy-Con 2 (L + R)"), (.pro, "Switch 2 Pro / Pro"),
            (.gen1Left, "Joy-Con (L)"), (.gen1Right, "Joy-Con (R) *"), (.gen1LeftSideways, "Joy-Con (L) 单只玩家"), (.gen1RightSideways, "Joy-Con (R) 单只玩家"), (.gen1Pair, "Joy-Con (L/R) *"), (.playstation, "PlayStation"),
            (.xbox, "Xbox *"), (.otherPad, "其他（同 Pro）"), (.unknown, "未知型号"), (.keyboard, "键盘 *")]
        try snapshot("icons", VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(all.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 14) { ControllerIcon(glyph: item.0).frame(width: 72, height: 54); Text(item.1).font(.system(size: 15, weight: .semibold)) }
            }
            Text("* 稿里没有，照稿的形状推的草稿").font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(20).frame(width: 320, alignment: .leading))
    }

    // 分配玩家（#520 E）：登记规则手算——单只 SL + SR、两只各按 L / R（0.5 秒内）合成一对、Pro L + R、系统手柄 L1 + R1；最多 4 位、同一只不重复
    func testPlayerAssignment() throws {
        var a = PlayerAssignment()
        a.ns2(id: "L1", kind: 2, gesture: 3, at: 10.0)
        a.ns2(id: "R1", kind: 3, gesture: 3, at: 10.3)
        XCTAssertEqual(a.units, [.pair(left: "L1", right: "R1")], "两只 0.5 秒内各按 L / R：一对")
        a.ns2(id: "L1", kind: 2, gesture: 1, at: 11)   // 已在一对里的再按整只手势：不动（SL + SR 才拆，见下面 rg）
        XCTAssertEqual(a.units.count, 1, "已登记的那只再按不重复算")
        a.system(name: "DualSense", index: 0)
        a.system(name: "DualSense", index: 0)
        XCTAssertEqual(a.units.count, 2, "同一只系统手柄不重复")
        let devs = [PlayerAssignment.Device(id: "L1", kind: 2), PlayerAssignment.Device(id: "R1", kind: 3)]
        XCTAssertEqual(a.helperPlan(devices: devs)["split"] as? Bool, false)
        XCTAssertEqual(a.helperPlan(devices: devs)["first"] as? String, "L1")
        XCTAssertEqual(a.helperPlan(devices: devs)["keep"] as? [String], ["L1", "R1"], "完成后谁都不断开")
        a.finish(presentSystem: [.init(name: "DualSense", index: 0), .init(name: "Xbox Wireless Controller", index: 0)], devices: devs)
        let file = a.orderFile()
        XCTAssertEqual((file["order"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((file["dropped"] as? [[String: Any]])?.first?["name"] as? String, "Xbox Wireless Controller", "在线却没分配：连着、没有玩家位")

        var b = PlayerAssignment()
        b.ns2(id: "R1", kind: 3, gesture: 2, at: 0)
        b.ns2(id: "L1", kind: 2, gesture: 2, at: 1)
        XCTAssertEqual(b.units, [.single(id: "R1", kind: 3), .single(id: "L1", kind: 2)], "各按 SL + SR：两位单只，按的顺序就是 P1、P2")
        XCTAssertEqual(b.helperPlan(devices: devs)["split"] as? Bool, true)
        XCTAssertEqual(b.helperPlan(devices: devs)["first"] as? String, "R1", "先按的那只是玩家 1")

        // 只分配了一只 Joy-Con：另一只连着但没有玩家位（游戏 dropped 里是通道玩家 1）
        var one = PlayerAssignment()
        one.ns2(id: "R1", kind: 3, gesture: 2, at: 0)
        one.finish(presentSystem: [], devices: devs)
        XCTAssertEqual(one.helperPlan(devices: devs)["split"] as? Bool, true, "两只拆开，没分配的那只单独不给位")
        XCTAssertEqual((one.orderFile()["dropped"] as? [[String: Any]])?.first?["player"] as? Int, 1)
        XCTAssertFalse(one.reconcile(devices: devs, mergedPair: false, system: []), "没分配的那只不会被自动排回来")

        // 自动分配：接上就排进下一位；一对缺省一位；断开就让出；单只登记过、另一只接上并成一对
        var auto = PlayerAssignment()
        XCTAssertTrue(auto.reconcile(devices: devs, mergedPair: true, system: [.init(name: "DualSense", index: 0)]))
        XCTAssertEqual(auto.units, [.pair(left: "L1", right: "R1"), .system(name: "DualSense", index: 0)])
        auto.reconcile(devices: [devs[0]], mergedPair: false, system: [.init(name: "DualSense", index: 0)])
        XCTAssertEqual(auto.units, [.single(id: "L1", kind: 2), .system(name: "DualSense", index: 0)], "一对断了一只：剩单只、原位")
        auto.reconcile(devices: devs, mergedPair: true, system: [.init(name: "DualSense", index: 0)])
        XCTAssertEqual(auto.units, [.pair(left: "L1", right: "R1"), .system(name: "DualSense", index: 0)], "另一只接回来：原位并成一对")
        auto.reconcile(devices: devs, mergedPair: true, system: [])
        XCTAssertEqual(auto.units, [.pair(left: "L1", right: "R1")], "蓝牙手柄断开：让出玩家位")
        // ×：平时清掉一位 = 连着但没有玩家位、不自动排回来；分配中再按键登记就回来
        var x = PlayerAssignment()
        x.reconcile(devices: devs, mergedPair: true, system: [.init(name: "DualSense", index: 0)])
        x.remove(at: 1, keepConnectedWithoutSlot: true)
        XCTAssertEqual(x.units, [.pair(left: "L1", right: "R1")])
        XCTAssertFalse(x.reconcile(devices: devs, mergedPair: true, system: [.init(name: "DualSense", index: 0)]), "× 掉的不自动排回来")
        x.system(name: "DualSense", index: 0)
        XCTAssertEqual(x.units.count, 2, "分配时按 L1 + R1 又登记回来")
        XCTAssertTrue(x.orderFile()["dropped"].map { ($0 as? [Any])?.isEmpty ?? false } ?? false, "重新登记后不再 dropped")
        var y = PlayerAssignment()
        y.system(name: "Pad", index: 0)
        y.remove(at: 0, keepConnectedWithoutSlot: false)
        XCTAssertTrue(y.units.isEmpty && (y.orderFile()["dropped"] as? [Any])?.isEmpty == true, "分配中 × 只是空出位子")
        // 游戏的手柄设置画面（front_mac.m s2a_vpad_assign）：请求文件 request → 面板接下（open）、进分配；完成写 done + 几位玩家
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-assign-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let game = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-panel-test.sock"), store: UserDefaults(suiteName: "s2arm-assign-" + UUID().uuidString),
                                         orderFile: dir.appendingPathComponent("pad-order.json"))
        let request = dir.appendingPathComponent("assign-request.json")
        try JSONSerialization.data(withJSONObject: ["token": "t1", "state": "request", "min": 1, "max": 4]).write(to: request)
        game.updateSystem([.init(name: "DualSense", index: 0)])
        game.checkGameRequest()
        func state() -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: request))) as? [String: Any] ?? [:] }
        XCTAssertTrue(game.assigning && game.panelRequested, "游戏来请求：面板弹出、进分配玩家")
        XCTAssertEqual(state()["state"] as? String, "open", "接下了：宿主就等，不自动应答")
        game.registerSystem(name: "DualSense", index: 0)
        game.finishAssign()
        XCTAssertEqual(state()["state"] as? String, "done")
        XCTAssertEqual(state()["players"] as? Int, 1, "回给游戏登记了几位")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("pad-order.json").path), "顺序表先写好")
        try JSONSerialization.data(withJSONObject: ["token": "t2", "state": "request", "min": 1, "max": 4]).write(to: request)
        game.checkGameRequest(); game.cancelAssign()
        XCTAssertEqual(state()["state"] as? String, "cancel", "取消：游戏照旧自动应答")
        try? FileManager.default.removeItem(at: dir)
        // 没连着手柄：上次存的分配不显示（#520 讨论「没有手柄怎么会有玩家位」）
        let suite = "s2arm-stale-" + UUID().uuidString
        let store = UserDefaults(suiteName: suite)!
        var stale = PlayerAssignment(); stale.system(name: "DualSense", index: 0); stale.system(name: "DualSense", index: 1)
        store.set(try JSONEncoder().encode(stale), forKey: "S2AMacNS2PlayerAssignment")
        let fresh = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-panel-test.sock"), store: store,
                                          orderFile: FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json"))
        fresh.updateSystem([])
        XCTAssertTrue(fresh.assignment.units.isEmpty, "启动时没有手柄：没有玩家位")
        // 只有完成分配才换代（游戏才整个重排）；接上新手柄自动排进来不换代，已在玩的人留原位
        var g = PlayerAssignment()
        g.reconcile(devices: [], mergedPair: false, system: [.init(name: "DualSense", index: 0)])
        let gen0 = g.orderFile()["generation"] as? Int
        g.reconcile(devices: [], mergedPair: false, system: [.init(name: "DualSense", index: 0), .init(name: "DualSense", index: 1)])
        XCTAssertEqual(g.orderFile()["generation"] as? Int, gen0, "第二只接上：不换代")
        g.finish(presentSystem: [], devices: [])
        XCTAssertEqual(g.orderFile()["generation"] as? Int, (gen0 ?? 0) + 1, "完成分配：换代")
        // 键盘：只有分配中按键才登记、平时不自动加；登记了才进顺序表，× 掉回到并进 P1
        var k = PlayerAssignment()
        k.reconcile(devices: devs, mergedPair: true, system: [])
        XCTAssertFalse(k.units.contains(.keyboard), "不自动加键盘")
        k.keyboard(); k.keyboard()
        XCTAssertEqual(k.units.filter { $0 == .keyboard }.count, 1, "按几次都只一位")
        XCTAssertEqual((k.orderFile()["order"] as? [[String: Any]])?.last?["type"] as? String, "keyboard")
        XCTAssertFalse(k.reconcile(devices: devs, mergedPair: true, system: []), "键盘一直在，整理时不拿掉")
        k.remove(at: 1, keepConnectedWithoutSlot: true)
        XCTAssertFalse(k.units.contains(.keyboard) || ((k.orderFile()["dropped"] as? [[String: Any]]) ?? []).contains { $0["type"] as? String == "keyboard" })
        let kb = Self.isolated()
        kb.apply(status: 4, ["status": 4, "kind": 4, "players": 1, "kinds": [4], "devices": [["kind": 2, "id": "L"], ["kind": 3, "id": "R"]]])
        var shownK = kb.assignment; shownK.keyboard()
        kb.setAssignmentForTesting(shownK)
        try snapshot("assign_keyboard_zh", Self.panel(kb, SystemControllers(pads: []), true))
        // 最多 4 只（第二个连接程序管第二组）：玩家号照连接程序报的（第二组 +2）；新来的左 + 右只在同一组里才配一对；计划按组
        let four = [PlayerAssignment.Device(id: "A-L", kind: 2, player: 0, group: 0), PlayerAssignment.Device(id: "A-R", kind: 3, player: 0, group: 0),
                    PlayerAssignment.Device(id: "B-L", kind: 2, player: 2, group: 1), PlayerAssignment.Device(id: "B-P", kind: 1, player: 3, group: 1)]
        var q = PlayerAssignment()
        q.reconcile(devices: four, mergedGroups: [0], system: [])
        XCTAssertEqual(q.units, [.pair(left: "A-L", right: "A-R"), .single(id: "B-L", kind: 2), .whole(id: "B-P", kind: 1)], "第一组一对一位；第二组的左只不跟第一组的右只配")
        let qo = q.orderFile(playerOf: Dictionary(four.map { ($0.id, $0.player) }, uniquingKeysWith: { a, _ in a }))
        XCTAssertEqual((qo["order"] as? [[String: Any]])?.compactMap { $0["player"] as? Int }, [0, 2, 3], "顺序表用通道玩家号（第二组 2、3）")
        XCTAssertEqual(q.helperPlan(devices: Array(four[2...]))["first"] as? String, "B-L", "第二组的计划只看第二组")
        XCTAssertEqual(NS2SecondHelper.environment(base: ["S2A_NS2_SOCKET": "/x"], upstream: "/u", rememberDevice: true)["S2A_NS2_DEFAULTS_SUITE"], "org.s2arm.macos.game.2", "第二个连接程序用自己的重连记忆")
        XCTAssertNil(NS2SecondHelper.environment(base: ["S2A_NS2_SOCKET": "/x"], upstream: "/u", rememberDevice: true)["S2A_NS2_SOCKET"], "第二个不收游戏")
        let parsed = NS2LauncherController.devices(from: ["status": 4, "kind": 2, "players": 2, "kinds": [2, 3], "devices": [["id": "x", "kind": 3], ["id": "y", "kind": 2]]], group: 1)
        XCTAssertEqual(parsed.map(\.player), [3, 2], "第二组拆开：同 kinds[0] 那只是玩家 2、另一只 3")
        // 分配中接上的手柄（#520 讨论）：自动排进下一个空位；完成后不算「没分配」
        let mid = Self.isolated()
        mid.updateSystem([.init(name: "DualSense Wireless Controller", index: 0)])
        XCTAssertEqual(mid.assignment.units.count, 1)
        mid.setAssignmentForTesting(mid.assignment)
        mid.updateSystem([.init(name: "DualSense Wireless Controller", index: 0), .init(name: "DualSense Wireless Controller", index: 1)])
        XCTAssertEqual(mid.assignment.units.last, .system(name: "DualSense Wireless Controller", index: 1), "分配中接上第二只：自动排进来")
        mid.finishAssign()
        XCTAssertEqual(mid.assignment.units.count, 2, "完成后两只都有玩家位")
        XCTAssertTrue((mid.assignment.orderFile()["dropped"] as? [Any])?.isEmpty ?? false, "分配中接上的不算没分配")
        // 分配中直接拆 / 拼（不用先 ×）：一对里按 SL + SR → 拆开、另一只排在后面；两位单只各按 L / R → 合回一对
        var rg = PlayerAssignment()
        rg.system(name: "Pad", index: 0)
        rg.ns2(id: "L", kind: 2, gesture: 3, at: 0); rg.ns2(id: "R", kind: 3, gesture: 3, at: 0.2)
        XCTAssertEqual(rg.units, [.system(name: "Pad", index: 0), .pair(left: "L", right: "R")])
        rg.ns2(id: "R", kind: 3, gesture: 2, at: 1)
        XCTAssertEqual(rg.units, [.system(name: "Pad", index: 0), .single(id: "R", kind: 3), .single(id: "L", kind: 2)], "右只 SL + SR：拆开，右只留原位")
        rg.ns2(id: "L", kind: 2, gesture: 3, at: 2); rg.ns2(id: "R", kind: 3, gesture: 3, at: 2.3)
        XCTAssertEqual(rg.units, [.system(name: "Pad", index: 0), .pair(left: "L", right: "R")], "两位单只各按 L / R：合回一对、占前面那位")
        rg.ns2(id: "L", kind: 2, gesture: 3, at: 5); rg.ns2(id: "R", kind: 3, gesture: 3, at: 5.1)
        XCTAssertEqual(rg.units.count, 2, "负对照：已经是一对时再按 L / R 不动")
        // D2：一代 Joy-Con 按设备拆 / 合（启动器 HID 读手势）。手算报告：0x30 左只 SL + SR、右只 R；0x3F 简单报告 SL + SR；负对照：只按 SL、太短
        XCTAssertEqual(Gen1HIDWatcher.gesture(pid: 0x2006, report: [0x30, 0, 0x8e, 0, 0, 0x30] + Array(repeating: 0, count: 43)), 2)
        XCTAssertEqual(Gen1HIDWatcher.gesture(pid: 0x2007, report: [0x30, 0, 0x8e, 0x40, 0, 0] + Array(repeating: 0, count: 43)), 3)
        XCTAssertEqual(Gen1HIDWatcher.gesture(pid: 0x2006, report: [0x3f, 0x30, 0x00]), 2)
        XCTAssertEqual(Gen1HIDWatcher.gesture(pid: 0x2006, report: [0x30, 0, 0x8e, 0, 0, 0x20] + Array(repeating: 0, count: 43)), 0, "只按 SL 不算")
        XCTAssertEqual(Gen1HIDWatcher.gesture(pid: 0x2006, report: [0x30, 0]), 0, "太短")
        // 游戏的手柄设置画面先照它要的自动拆 / 拼（autoFit）：够就不弹面板（同原机）
        typealias W = PlayerAssignment.GameWants
        let jcDevs: [PlayerAssignment.Device] = [.init(id: "L", kind: 2, group: 0), .init(id: "R", kind: 3, player: 1, group: 0)]
        var fitA = PlayerAssignment(); fitA.reconcile(devices: jcDevs, mergedPair: true, system: [])
        XCTAssertTrue(fitA.autoFit(W(styles: 2 | 1 << 13 | 1 << 14, min: 2, max: 2), devices: jcDevs))
        XCTAssertEqual(fitA.units, [.single(id: "L", kind: 2), .single(id: "R", kind: 3)], "拼着、游戏要两人各一只单只：自动拆开")
        XCTAssertTrue(fitA.autoFit(W(styles: 2 | 4, min: 1, max: 1), devices: jcDevs))
        XCTAssertEqual(fitA.units, [.pair(left: "L", right: "R")], "拆着、游戏要一人一对：自动拼回")
        var fitB = PlayerAssignment(); fitB.reconcile(devices: jcDevs, mergedPair: false, system: [])
        XCTAssertTrue(fitB.autoFit(W(styles: 2 | 4, min: 2, max: 2), devices: jcDevs))
        XCTAssertEqual(fitB.units.count, 2, "两人、只收一对：两只单只各当一位（双手模式只接一侧），不拼")
        var fitC = PlayerAssignment(); fitC.reconcile(devices: [jcDevs[1]], mergedPair: false, system: [])
        XCTAssertTrue(fitC.autoFit(W(styles: 2 | 1 << 12, min: 1, max: 1), devices: [jcDevs[1]]), "单人、只收 Joy-Con 2 一对、手上一只右只：直接过（不弹面板）")
        let otherGroup: [PlayerAssignment.Device] = [.init(id: "L", kind: 2, group: 0), .init(id: "R2", kind: 3, player: 2, group: 1)]
        var fitD = PlayerAssignment(); fitD.reconcile(devices: otherGroup, mergedPair: false, system: [])
        fitD.autoFit(W(styles: 4, min: 1, max: 1), devices: otherGroup)
        XCTAssertEqual(fitD.units.count, 2, "负对照：不同组的左右只拼不起来（连接程序各管一组）")
        var fitE = PlayerAssignment()
        XCTAssertFalse(fitE.autoFit(W(styles: 1 | 4, min: 1, max: 1), devices: []), "负对照：一只手柄都没有 → 弹面板")
        var fitF = PlayerAssignment()
        fitF.reconcile(devices: [], mergedPair: false, system: [], gen1: [.init(id: "a", side: 0), .init(id: "b", side: 1)])
        fitF.gen1(id: "a", side: 0, gesture: 2, at: 0, present: [.init(id: "a", side: 0), .init(id: "b", side: 1)])
        fitF.gen1(id: "b", side: 1, gesture: 2, at: 1, present: [.init(id: "a", side: 0), .init(id: "b", side: 1)])
        XCTAssertTrue(fitF.autoFit(W(styles: 4, min: 1, max: 1), devices: []))
        XCTAssertEqual(fitF.units, [.gen1Pair(left: "a", right: "b")], "一代同一套：游戏要一对时自动拼（同 Joy-Con 2）")

        // D2 多套一代（同原机「更改握法 / 顺序」）：每只按设备 id 认（序列号 = 蓝牙地址）；系统合成的那一位按 L + R 时学到里面是哪两只，
        //   一只按 SL + SR 只拆它那一套、别的套照旧合成；两位单只各按 L / R 合成一位；认不出时只登记按的那只
        XCTAssertEqual(Gen1HIDWatcher.deviceID(serial: "98-b6-e9-01-02-03", location: 0x1234), "98-b6-e9-01-02-03")
        XCTAssertEqual(Gen1HIDWatcher.deviceID(serial: "", location: 0x1a2b), "loc-1a2b", "没序列号：LocationID，同宿主 loc-%x")
        XCTAssertNil(Gen1HIDWatcher.deviceID(serial: nil, location: nil))
        XCTAssertEqual(PlayerAssignment.gen1Sides("Joy-Con (L/R)"), [0, 1]); XCTAssertEqual(PlayerAssignment.gen1Sides("Joy-Con (R)"), [1])
        XCTAssertEqual(PlayerAssignment.gen1Sides("Joy-Con 2 (L)"), [], "负对照：Joy-Con 2 不算一代")
        let combined = "Joy-Con (L/R)"
        let c0 = PlayerAssignment.SystemKey(name: combined, index: 0), c1 = PlayerAssignment.SystemKey(name: combined, index: 1)
        let two = [c0, c1]
        let jc: [PlayerAssignment.Gen1Device] = [.init(id: "L1", side: 0), .init(id: "R1", side: 1), .init(id: "L2", side: 0), .init(id: "R2", side: 1)]
        var g1 = PlayerAssignment()
        g1.reconcile(devices: [], mergedPair: false, system: two, gen1: jc)
        XCTAssertEqual(g1.units, [.system(name: combined, index: 0), .system(name: combined, index: 1)], "两套合成的：缺省各一位")
        // 学：第一套按 L + R（HID 先到、系统那一位后到），第二套同样
        g1.gen1(id: "L1", side: 0, gesture: 3, at: 1, present: jc, system: two); g1.gen1(id: "R1", side: 1, gesture: 3, at: 1.05, present: jc, system: two)
        g1.system(name: combined, index: 0, at: 1.1)
        g1.system(name: combined, index: 1, at: 2); g1.gen1(id: "L2", side: 0, gesture: 3, at: 2.05, present: jc, system: two); g1.gen1(id: "R2", side: 1, gesture: 3, at: 2.1, present: jc, system: two)
        XCTAssertEqual(g1.combinedHalves[c0], ["L1", "R1"]); XCTAssertEqual(g1.combinedHalves[c1], ["L2", "R2"])
        XCTAssertEqual(g1.units.count, 2, "按 L + R 只是学，不多登记")
        g1.gen1(id: "R1", side: 1, gesture: 2, at: 5, present: jc, system: two)
        XCTAssertEqual(g1.units, [.gen1(id: "R1", side: 1), .gen1(id: "L1", side: 0), .system(name: combined, index: 1)], "第一套右只 SL + SR：只拆这一套，按的留原位、同套左只排后面；第二套照旧合成")
        XCTAssertFalse(g1.reconcile(devices: [], mergedPair: false, system: two, gen1: jc), "拆开的那一位不再自动排回来")
        let g1File = g1.orderFile()
        XCTAssertEqual((g1File["order"] as? [[String: Any]])?.map { $0["type"] as? String }, ["gen1", "gen1", "system"])
        XCTAssertTrue(((g1File["dropped"] as? [[String: Any]]) ?? []).contains { $0["type"] as? String == "system" && $0["index"] as? Int == 0 }, "拆开的那一位列进 dropped：宿主不读它")
        g1.gen1(id: "L1", side: 0, gesture: 3, at: 6, present: jc, system: two); g1.system(name: combined, index: 0, at: 6.05); g1.gen1(id: "R1", side: 1, gesture: 3, at: 6.1, present: jc, system: two)
        XCTAssertEqual(g1.units, [.gen1Pair(left: "L1", right: "R1"), .system(name: combined, index: 1)], "两位单只各按 L / R：合成一位、占前面那位；系统那一位不重复登记")
        XCTAssertEqual((g1.orderFile()["order"] as? [[String: Any]])?.first?["left"] as? String, "L1")
        g1.gen1(id: "R1", side: 1, gesture: 2, at: 8, present: jc, system: two)
        XCTAssertEqual(g1.units, [.gen1(id: "R1", side: 1), .gen1(id: "L1", side: 0), .system(name: combined, index: 1)], "一对里一只 SL + SR：再拆开")
        g1.reconcile(devices: [], mergedPair: false, system: two, gen1: jc.filter { $0.id != "L1" })
        XCTAssertEqual(g1.units, [.gen1(id: "R1", side: 1), .system(name: combined, index: 1)], "断开一只只拿掉那一只，别人不动")
        g1.remove(at: 0, keepConnectedWithoutSlot: true)
        XCTAssertFalse(g1.reconcile(devices: [], mergedPair: false, system: two, gen1: jc.filter { $0.id != "L1" }), "× 掉的那只连着、不自动排回来")
        XCTAssertEqual((g1.orderFile()["dropped"] as? [[String: Any]])?.last?["id"] as? String, "R1")
        let saved = try JSONDecoder().decode(PlayerAssignment.self, from: JSONEncoder().encode(g1))
        XCTAssertEqual(saved, g1, "按设备的分配也存偏好、下次照用")
        // 只连一套、没学过：认得出（只有一位合成的），同套另一只就是另一侧那只
        var one1 = PlayerAssignment()
        one1.reconcile(devices: [], mergedPair: false, system: [c0], gen1: Array(jc.prefix(2)))
        one1.gen1(id: "L1", side: 0, gesture: 2, at: 0, present: Array(jc.prefix(2)), system: [c0])
        XCTAssertEqual(one1.units, [.gen1(id: "L1", side: 0), .gen1(id: "R1", side: 1)], "只有一套：不用学也认得出")
        // 负对照：两套都没学过、直接按 SL + SR：认不出是哪一套，只登记按的那只、别的不动
        var unknown = PlayerAssignment()
        unknown.reconcile(devices: [], mergedPair: false, system: two, gen1: jc)
        unknown.gen1(id: "L2", side: 0, gesture: 2, at: 0, present: jc, system: two)
        XCTAssertEqual(unknown.units, [.system(name: combined, index: 0), .system(name: combined, index: 1), .gen1(id: "L2", side: 0)], "认不出：只登记这一只，不拆别人")
        XCTAssertTrue(unknown.splitCombined.isEmpty)
        // 四套一代 → 学过后四套各拆开 = 8 位；拆一套时其余三套照旧合成
        let gen1Eight = (1...4).flatMap { [PlayerAssignment.Gen1Device(id: "l\($0)", side: 0), .init(id: "r\($0)", side: 1)] }
        let gen1Four = (0..<4).map { PlayerAssignment.SystemKey(name: combined, index: $0) }
        var g8 = PlayerAssignment()
        g8.reconcile(devices: [], mergedPair: false, system: gen1Four, gen1: gen1Eight)
        for k in 0..<4 {
            let t = Double(k * 10)
            g8.gen1(id: "l\(k + 1)", side: 0, gesture: 3, at: t, present: gen1Eight, system: gen1Four)
            g8.gen1(id: "r\(k + 1)", side: 1, gesture: 3, at: t + 0.05, present: gen1Eight, system: gen1Four)
            g8.system(name: combined, index: k, at: t + 0.1)
        }
        XCTAssertEqual(g8.units.count, 4, "四套合成的：四位")
        g8.gen1(id: "l3", side: 0, gesture: 2, at: 100, present: gen1Eight, system: gen1Four)
        XCTAssertEqual(g8.units.count, 5, "拆一套：多一位，其余三套照旧"); XCTAssertEqual(g8.registeredGen1, ["l3", "r3"])
        for (k, id) in [(1, "r1"), (2, "l2"), (4, "r4")] { g8.gen1(id: id, side: id.hasPrefix("l") ? 0 : 1, gesture: 2, at: 100 + Double(k), present: gen1Eight, system: gen1Four) }
        XCTAssertEqual(g8.units.count, 8, "四套都拆开：8 位"); XCTAssertEqual(g8.registeredGen1, Set(gen1Eight.map(\.id)))
        g8.reconcile(devices: [], mergedPair: false, system: [], gen1: [])
        XCTAssertTrue(g8.units.isEmpty, "一代 Joy-Con 全断开：让位")
        let roundTrip = try JSONDecoder().decode(PlayerAssignment.self, from: JSONEncoder().encode(one))
        XCTAssertEqual(roundTrip, one, "分配存偏好、下次照用")

        var c = PlayerAssignment()
        c.ns2(id: "L1", kind: 2, gesture: 3, at: 0)
        c.ns2(id: "R1", kind: 3, gesture: 3, at: 2)
        XCTAssertTrue(c.units.isEmpty, "负对照：隔 2 秒各按一边不算一对")
        c.ns2(id: "L1", kind: 2, gesture: 3, at: 2.2)
        XCTAssertEqual(c.units, [.pair(left: "L1", right: "R1")])
        for i in 0..<9 { c.system(name: "Pad", index: i) }
        XCTAssertEqual(c.units.count, 8, "最多 8 位（同原机）")
        XCTAssertEqual(playerLights(5), [true, false, false, true], "P5 灯同原机")
        XCTAssertEqual(playerLights(8), [false, true, true, false], "P8 灯同原机")
        XCTAssertEqual(NS2SecondHelper.environment(base: [:], upstream: "/u", rememberDevice: true, group: 3)["S2A_NS2_GROUP"], "3", "第 4 组连接程序")
        XCTAssertEqual(NS2SecondHelper.environment(base: [:], upstream: "/u", rememberDevice: true, group: 3)["S2A_NS2_DEFAULTS_SUITE"], "org.s2arm.macos.game.4", "每组自己的重连记忆")
        let eight = Self.isolated()
        var full = PlayerAssignment()
        full.reconcile(devices: [], mergedPair: false, system: (0..<6).map { .init(name: "DualSense Wireless Controller", index: $0) })
        full.ns2(id: "L", kind: 2, gesture: 2, at: 0)
        eight.setAssignmentForTesting(full)
        try snapshot("assign_eight_zh", Self.panel(eight, SystemControllers(pads: []), true))

        let ctl = Self.isolated()
        ctl.apply(status: 4, ["status": 4, "kind": 4, "players": 1, "kinds": [4]])
        var shown = PlayerAssignment()
        shown.system(name: "DualSense", index: 0)
        shown.ns2(id: "L1", kind: 2, gesture: 2, at: 0)
        ctl.setAssignmentForTesting(shown)
        XCTAssertEqual(ctl.status, .searching, "分配中状态是搜索中")
        let ps = SystemControllers.Pad(id: ObjectIdentifier(NSObject()), name: "DualSense", family: .playstation)
        try snapshot("assign_zh", Self.panel(ctl, SystemControllers(pads: [ps]), true))
        try snapshot("assign_en", Self.panel(ctl, SystemControllers(pads: [ps]), false))
    }

    private func snapshot<V: View>(_ name: String, _ root: V) throws {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: root.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3)); view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        if let o = ProcessInfo.processInfo.environment["S2A_SNAPSHOT_OUT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: o).appendingPathComponent(name + ".png"))
        }
    }
}
