// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
@testable import NX2AppleUI

// 手柄弹窗「两只怎么用」（#520 D）：连着两只 Joy-Con 才出这一段，标题 / 选中的那格跟连接程序报的玩家数走。
//   设 S2A_SNAPSHOT_OUT=<目录> 存 ns2_single / ns2_pair / ns2_split（中英各一）供肉眼核对。
@MainActor final class NS2PanelSnapshotTests: XCTestCase {
    /// 不碰本机真的分配，也不读取本机已连接手柄；状态与设备均由用例提供。
    static func isolated() -> NS2LauncherController {
        let suite = "s2arm-panel-test-" + UUID().uuidString
        return NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-panel-test.sock"), store: UserDefaults(suiteName: suite),
                                     orderFile: FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json"),
                                     systemControllers: { [] }, notifications: NotificationCenter())
    }
    /// 面板：蓝牙手柄照工具栏那样交给分配整理（自动排进玩家位）
    static func panel(_ c: NS2LauncherController, _ systems: SystemControllers, _ zh: Bool) -> Switch2ProConnectionPopover {
        c.updateSystem(systems.presentKeys)
        return Switch2ProConnectionPopover(controller: c, systems: systems, lang: zh ? "zh" : "en")
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
        XCTAssertEqual(single.title(lang: "zh"), "Joy-Con 2 (L)")
        let pair = controller(kind: 4, players: 1, kinds: [4])
        XCTAssertEqual(pair.title(lang: "zh"), "Joy-Con 2 (L + R)")
        let split = controller(kind: 3, players: 2, kinds: [3, 2])
        XCTAssertEqual(split.title(lang: "zh"), "2 个 Switch 2 手柄", "两只各一位：标题写手柄数量（玩家在列表里）")
        XCTAssertEqual(split.title(lang: "en"), "2 Switch 2 controllers")
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
            XCTAssertEqual(C.statusText(status, lang: "zh"), text)
            XCTAssertEqual(C.mainButton(status, lang: "zh"), button)
        }
        XCTAssertEqual(C.statusText(.inUse, lang: "en"), "In use by game")
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
        // 连着：主按钮「断开」+ 齿轮；开关收进齿轮选单（选单另存一张）
        let connected = make(4, kind: 2)
        try snapshot("status_connected_zh", Self.panel(connected, SystemControllers(pads: []), true))
        try snapshot("status_connected_en", Self.panel(connected, SystemControllers(pads: []), false))
        try snapshot("settings_menu_zh", Switch2SettingsMenu(controller: connected, lang: "zh", close: {}))
        try snapshot("settings_menu_en", Switch2SettingsMenu(controller: connected, lang: "en", close: {}))
        try snapshot("bluetooth_empty_en", Self.panel(make(nil), SystemControllers(pads: []), false))   // 没蓝牙手柄也有蓝牙区块
        try snapshot("status_searching_en", Self.panel(make(1), SystemControllers(pads: []), false))
        XCTAssertNil(ControllerIcon.header(kind: make(5).kind, players: 1), "失败：型号未知 → 虚线图")
        XCTAssertEqual(make(5).switch2Title(lang: "zh"), "Joy-Con 2 · Pro 2", "看面板标题（switch2Title）：title() 在本机连着蓝牙手柄时会写它的名字（#901）")
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
        // #1151：真机上只连着系统手柄时，控制器自己也认到它（systemControllerName）。面板顶部是 Switch 2 手柄那一块，
        //   不能借系统手柄的名字（原先写「DualSense Wireless Controller · 未连接」，下面系统手柄块又写「已连接」，同一只两种状态），
        //   长名也不能把整块撑出面板宽度（原先标题 fixedSize，左边图标和「玩家」被裁）
        for zh in [true, false] {
            let real = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-panel-test.sock"),
                                             store: UserDefaults(suiteName: "s2arm-panel-test-" + UUID().uuidString),
                                             orderFile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"),
                                             systemControllers: { [NamedSystemController("DualSense Wireless Controller")] }, notifications: NotificationCenter())
            real.startIfEnabled()
            let dualsense = S.Pad(id: ObjectIdentifier(NSObject()), name: "DualSense Wireless Controller", family: .playstation)
            try snapshot(zh ? "system_real_zh" : "system_real_en", Self.panel(real, S(pads: [dualsense]), zh))
            XCTAssertEqual(real.title(lang: zh ? "zh" : "en"), "DualSense Wireless Controller", "顶栏按钮照旧写系统手柄的真名（#901）")
            XCTAssertEqual(real.switch2Title(lang: zh ? "zh" : "en"), "Joy-Con 2 · Pro 2", "面板顶部只讲 Switch 2 手柄（型号未知：Joy-Con 2 · Pro 2）")
        }
        // #1151 ①：HID 兜底手柄（GameController 认不出，宿主 hid_pad.m 按 HID 读）面板也列。认法同宿主（hid_generic.h）：名字带「Pro Controller」的都列，
        //   别的通用手柄（Stadia、八位堂 D-input 等）除微软 / 索尼 / 任天堂外也列；GameController 已列出的同名不重复
        XCTAssertEqual(HIDFallbackPads.listed(hid: ["Lic Pro Controller", "Stadia Controller", "PRO CONTROLLER", "Pro Controller"], system: ["Pro Controller"]),
                       ["Lic Pro Controller", "Stadia Controller"], "通用手柄也列；PRO CONTROLLER / Pro Controller 与系统已列的同名（不分大小写）不重复")
        XCTAssertTrue(HIDFallbackPads.hostReads(name: "Stadia Controller", vendor: 0x18d1) && HIDFallbackPads.hostReads(name: "", vendor: 0x2dc8), "非原生厂商的通用手柄宿主读")
        XCTAssertTrue(HIDFallbackPads.hostReads(name: "Pro Controller", vendor: 0x057e) && HIDFallbackPads.hostReads(name: "Lic Pro Controller", vendor: 0), "Pro 那一支不看厂商号")
        XCTAssertFalse(HIDFallbackPads.hostReads(name: "Xbox Wireless Controller", vendor: 0x045e) || HIDFallbackPads.hostReads(name: "Wireless Controller", vendor: 0x054c)
                       || HIDFallbackPads.hostReads(name: "Joy-Con (L)", vendor: 0x057e), "微软 / 索尼 / 任天堂通用手柄交给 GameController，面板不另列")
        XCTAssertEqual(HIDFallbackPads.listed(hid: ["Lic Pro Controller", "Lic Pro Controller"], system: []), ["Lic Pro Controller", "Lic Pro Controller"], "两只同名各算一只")
        XCTAssertEqual(HIDFallbackPads.listed(hid: [], system: ["DualSense Wireless Controller"]), [])
        try snapshot("system_hid_only_zh", Self.panel(Self.isolated(), S(pads: [], hidNames: ["Lic Pro Controller"]), true))
        try snapshot("system_hid_mixed_en", Self.panel(Self.isolated(), S(pads: [S.Pad(id: ObjectIdentifier(NSObject()), name: "DualSense Wireless Controller", family: .playstation)],
                                                                         hidNames: ["Lic Pro Controller", "DualSense Wireless Controller"]), false))
        try snapshot("system_long_en", Self.panel(c, S(pads: [edge, S.Pad(id: ObjectIdentifier(NSObject()), name: "Xbox Wireless Controller", family: .xbox)]), false))
        try snapshot("system_two_zh", Self.panel(c, S(pads: [ps, xb]), true))
        let all: [(ControllerIcon.Glyph, String)] = [(.left, "Joy-Con 2 (L)"), (.right, "Joy-Con 2 (R)"), (.leftSideways, "Joy-Con 2 (L) 单只玩家"), (.rightSideways, "Joy-Con 2 (R) 单只玩家"), (.pairHead, "Joy-Con 2 (L + R)"), (.pro2, "Switch 2 Pro"), (.pro, "Switch Pro"),
            (.gen1Left, "Joy-Con (L)"), (.gen1Right, "Joy-Con (R) *"), (.gen1LeftSideways, "Joy-Con (L) 单只玩家"), (.gen1RightSideways, "Joy-Con (R) 单只玩家"), (.gen1Pair, "Joy-Con (L/R) *"), (.playstation, "PlayStation"),
            (.xbox, "Xbox *"), (.otherPad, "其他 / 第三方（缺省）"), (.unknown, "未知型号"), (.keyboard, "键盘 *"), (.mobile, "手机（预留，面板不显示）")]
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
        // 已按 SL + SR 登记成横握单只：同组另一侧之后接上不自动拼成一对，新来的自己一位、两只拆开（不用再按一次 SL + SR）
        var side = PlayerAssignment()
        side.reconcile(devices: [devs[0]], mergedPair: false, system: [])
        side.ns2(id: "L1", kind: 2, gesture: 2, at: 0)   // 已有位的那只按 SL + SR（不重复登记，但记成横握）
        XCTAssertEqual(side.units, [.single(id: "L1", kind: 2)])
        XCTAssertEqual(side.sideways, ["L1"])
        side.reconcile(devices: devs, mergedPair: true, system: [])
        XCTAssertEqual(side.units, [.single(id: "L1", kind: 2), .single(id: "R1", kind: 3)], "先自动排进来、之后按了 SL + SR 的单只也算横握")
        var sideFresh = PlayerAssignment()
        sideFresh.ns2(id: "L1", kind: 2, gesture: 2, at: 0)   // 分配中按 SL + SR 登记
        sideFresh.reconcile(devices: devs, mergedPair: true, system: [])
        XCTAssertEqual(sideFresh.units, [.single(id: "L1", kind: 2), .single(id: "R1", kind: 3)], "SL + SR 登记过的单只：另一侧接上自己一位，不并成一对")
        XCTAssertTrue(sideFresh.wantsSplit(devices: devs), "传输层缺省拼成一对时要照分配拆开")
        XCTAssertEqual(sideFresh.helperPlan(devices: devs)["split"] as? Bool, true)
        // 拔掉再接：横握标记留着（11-20：拆开的一对断开重连不能自己拼回），要拼回就按 L + R
        sideFresh.reconcile(devices: [], mergedPair: false, system: [])
        sideFresh.reconcile(devices: [devs[0]], mergedPair: false, system: [])
        sideFresh.reconcile(devices: devs, mergedPair: true, system: [])
        XCTAssertEqual(sideFresh.units, [.single(id: "L1", kind: 2), .single(id: "R1", kind: 3)], "拆开过的：拔掉再接仍各自一位")
        sideFresh.ns2(id: "L1", kind: 2, gesture: 3, at: 20); sideFresh.ns2(id: "R1", kind: 3, gesture: 3, at: 20.1)
        XCTAssertEqual(sideFresh.units, [.pair(left: "L1", right: "R1")], "按 L + R 拼回一对")
        // 同侧两只（L + L / R + R）永远不拼：第二只左只自己一位
        var sameSide = PlayerAssignment()
        sameSide.reconcile(devices: [devs[0]], mergedPair: false, system: [])
        let twoLeft = [devs[0], PlayerAssignment.Device(id: "L2", kind: 2)]
        sameSide.reconcile(devices: twoLeft, mergedPair: true, system: [])
        XCTAssertEqual(sameSide.units, [.single(id: "L1", kind: 2), .single(id: "L2", kind: 2)], "两只左只不会拼成一对")
        // 横握标记存进偏好
        var savedSide = PlayerAssignment()
        savedSide.ns2(id: "R1", kind: 3, gesture: 2, at: 0)
        let decoded = try JSONDecoder().decode(PlayerAssignment.self, from: JSONEncoder().encode(savedSide))
        XCTAssertEqual(decoded.sideways, [], "横握记号不存偏好：重开 App 后第一次连上照常拼成一对")
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
        XCTAssertEqual(g1.slots, [.gen1(id: "R1", side: 1), .system(name: combined, index: 1), .gen1(id: "L1", side: 0)], "第一套右只 SL + SR：只拆这一套，按的留原位、第二套留在 P2 不被挤动、同套左只进空槽 P3")
        XCTAssertFalse(g1.reconcile(devices: [], mergedPair: false, system: two, gen1: jc), "拆开的那一位不再自动排回来")
        let g1File = g1.orderFile()
        XCTAssertEqual((g1File["order"] as? [[String: Any]])?.map { $0["type"] as? String }, ["gen1", "system", "gen1"])
        XCTAssertTrue(((g1File["dropped"] as? [[String: Any]]) ?? []).contains { $0["type"] as? String == "system" && $0["index"] as? Int == 0 }, "拆开的那一位列进 dropped：宿主不读它")
        g1.gen1(id: "L1", side: 0, gesture: 3, at: 6, present: jc, system: two); g1.system(name: combined, index: 0, at: 6.05); g1.gen1(id: "R1", side: 1, gesture: 3, at: 6.1, present: jc, system: two)
        XCTAssertEqual(g1.slots, [.gen1Pair(left: "L1", right: "R1"), .system(name: combined, index: 1)], "两位单只各按 L / R：合成一位、占前面那位；第二套仍留原位")
        XCTAssertEqual((g1.orderFile()["order"] as? [[String: Any]])?.first?["left"] as? String, "L1")
        g1.gen1(id: "R1", side: 1, gesture: 2, at: 8, present: jc, system: two)
        XCTAssertEqual(g1.slots, [.gen1(id: "R1", side: 1), .system(name: combined, index: 1), .gen1(id: "L1", side: 0)], "一对里一只 SL + SR：再拆开，不挤动 P2")
        g1.reconcile(devices: [], mergedPair: false, system: two, gen1: jc.filter { $0.id != "L1" })
        XCTAssertEqual(g1.slots, [.gen1(id: "R1", side: 1), .system(name: combined, index: 1)], "断开一只只拿掉那一只，别人不动")
        g1.remove(at: 0, keepConnectedWithoutSlot: true)
        XCTAssertFalse(g1.reconcile(devices: [], mergedPair: false, system: two, gen1: jc.filter { $0.id != "L1" }), "× 掉的那只连着、不自动排回来")
        XCTAssertEqual((g1.orderFile()["dropped"] as? [[String: Any]])?.last?["id"] as? String, "R1")
        let saved = try JSONDecoder().decode(PlayerAssignment.self, from: JSONEncoder().encode(g1))
        XCTAssertEqual(saved, g1, "按设备的分配也存偏好、下次照用")

        // 断连保槽 / 重连回原槽 / 指定空槽分配 / 满 8 槽时合体 Joy-Con 不强拆
        var keep = PlayerAssignment()
        let k1 = PlayerAssignment.SystemKey(name: "DualSense", index: 0)
        let k2 = PlayerAssignment.SystemKey(name: "Xbox", index: 0)
        let k3 = PlayerAssignment.SystemKey(name: "Pro Controller", index: 0)
        keep.reconcile(devices: [], mergedPair: false, system: [k1, k2])
        XCTAssertEqual(keep.slots, [.system(name: "DualSense", index: 0), .system(name: "Xbox", index: 0)])
        // P1 断开：P2 留在槽 1（不往前递补），顺序表槽 0 写 empty，P2 灯号仍为 2
        keep.reconcile(devices: [], mergedPair: false, system: [k2])
        XCTAssertEqual(keep.slots, [nil, .system(name: "Xbox", index: 0)], "P1 断开时 P2 保持在原槽 1")
        XCTAssertEqual(keep.systemPlayers()[k2], 2, "P2 玩家灯仍为 P2")
        XCTAssertEqual((keep.orderFile()["order"] as? [[String: Any]])?.map { $0["type"] as? String }, ["empty", "system"])
        // 新手柄 P3 接入：不抢 P1 预留槽 0，排进槽 2
        keep.reconcile(devices: [], mergedPair: false, system: [k2, k3])
        XCTAssertEqual(keep.slots, [nil, .system(name: "Xbox", index: 0), .system(name: "Pro Controller", index: 0)], "新手柄不抢断连手柄的预留槽")
        // P1 重连：回到原槽 0
        keep.reconcile(devices: [], mergedPair: false, system: [k2, k3, k1])
        XCTAssertEqual(keep.slots, [.system(name: "DualSense", index: 0), .system(name: "Xbox", index: 0), .system(name: "Pro Controller", index: 0)], "P1 重连恢复到原槽 0")

        // 指定空槽分配（例如点选 P8，中间 P4 等为空时 slots.count 仍为 8，不隐藏 P8；P8 移除后尾部空槽自动省略）
        var target = PlayerAssignment()
        target.system(name: "DualSense", index: 0, targetSlot: 0)
        target.system(name: "Xbox", index: 0, targetSlot: 7)
        XCTAssertEqual(target.slots.count, 8, "P8 有玩家时保留到槽 7（P8），中间空槽不隐藏后面玩家")
        XCTAssertEqual(target.slots[0], .system(name: "DualSense", index: 0))
        XCTAssertNil(target.slots[3])
        XCTAssertEqual(target.slots[7], .system(name: "Xbox", index: 0))
        // 已分配的手柄再按不换槽，必须先 × 才能换到其他槽
        target.system(name: "Xbox", index: 0, targetSlot: 2)
        XCTAssertNil(target.slots[2], "已分配手柄不直接换槽")
        XCTAssertEqual(target.slots[7], .system(name: "Xbox", index: 0))
        target.remove(at: 7, keepConnectedWithoutSlot: false)
        XCTAssertEqual(target.slots.count, 1, "确认后面全空后尾部空槽省略")
        target.system(name: "Xbox", index: 0, targetSlot: 2)
        XCTAssertEqual(target.slots, [.system(name: "DualSense", index: 0), nil, .system(name: "Xbox", index: 0)], "× 清除后再分配可进指定槽 P3")

        // Joy-Con 合 -> 分需要有空槽才可拆；满 8 槽时不拆，空出一槽后再拆不挤动其他玩家
        var full8 = PlayerAssignment()
        full8.ns2(id: "JL", kind: 2, gesture: 3, at: 0)
        full8.ns2(id: "JR", kind: 3, gesture: 3, at: 0.1)
        for i in 1..<8 { full8.system(name: "Pad\(i)", index: 0) }
        XCTAssertEqual(full8.slots.count, 8)
        full8.ns2(id: "JL", kind: 2, gesture: 2, at: 1)
        XCTAssertEqual(full8.slots[0], .pair(left: "JL", right: "JR"), "满 8 槽无空位时不拆合体 Joy-Con")
        full8.remove(at: 3, keepConnectedWithoutSlot: false)   // 空出槽 3（P4）
        full8.ns2(id: "JL", kind: 2, gesture: 2, at: 2)
        XCTAssertEqual(full8.slots[0], .single(id: "JL", kind: 2), "有空槽时拆分成功，原只留槽 0")
        XCTAssertEqual(full8.slots[3], .single(id: "JR", kind: 3), "另一只放进空槽 3，不挤动其他玩家")
        XCTAssertEqual(full8.slots[1], .system(name: "Pad1", index: 0))
        XCTAssertEqual(full8.slots[7], .system(name: "Pad7", index: 0))
        // 分 -> 合：空出后面那槽，不移动其他玩家
        full8.ns2(id: "JL", kind: 2, gesture: 3, at: 3)
        full8.ns2(id: "JR", kind: 3, gesture: 3, at: 3.1)
        XCTAssertEqual(full8.slots[0], .pair(left: "JL", right: "JR"))
        XCTAssertNil(full8.slots[3], "分 -> 合空出原高槽位，后面玩家不动")
        XCTAssertEqual(full8.slots[7], .system(name: "Pad7", index: 0))
        // 只连一套、没学过：认得出（只有一位合成的），同套另一只就是另一侧那只
        var one1 = PlayerAssignment()
        one1.reconcile(devices: [], mergedPair: false, system: [c0], gen1: Array(jc.prefix(2)))
        one1.gen1(id: "L1", side: 0, gesture: 2, at: 0, present: Array(jc.prefix(2)), system: [c0])
        XCTAssertEqual(one1.units, [.gen1(id: "L1", side: 0), .gen1(id: "R1", side: 1)], "只有一套：不用学也认得出")
        // 两套都没学过、直接按 SL + SR：照连接先后认出是第 2 套，只拆第 2 套（11-20：不再多出一只）
        var unknown = PlayerAssignment()
        unknown.reconcile(devices: [], mergedPair: false, system: two, gen1: jc)
        unknown.gen1(id: "L2", side: 0, gesture: 2, at: 0, present: jc, system: two)
        XCTAssertEqual(unknown.units, [.system(name: combined, index: 0), .gen1(id: "L2", side: 0), .gen1(id: "R2", side: 1)], "照先后认出第 2 套：只拆它")
        XCTAssertEqual(unknown.splitCombined, [c1])
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
        // 手柄上的玩家灯：灯型位 0–3 = 四颗灯（同 playerLights）；一对两只同一位
        XCTAssertEqual([1, 2, 4, 5, 8, 9].map { PlayerAssignment.lightMask(player: $0) }, [0x1, 0x3, 0xF, 0x9, 0x6, 0x0])
        var lit = PlayerAssignment()
        lit.reconcile(devices: [.init(id: "L1", kind: 2), .init(id: "R1", kind: 3), .init(id: "P1", kind: 1)], mergedPair: true,
                      system: [.init(name: "DualSense Wireless Controller", index: 0)])
        let masks = lit.lightMasks()
        XCTAssertEqual(masks["L1"], masks["R1"], "一对两只亮同一位")
        XCTAssertEqual(Set(masks.keys), ["L1", "R1", "P1"], "系统手柄不在这张表（走 playerIndex）")
        XCTAssertEqual(lit.systemPlayers().count, 1)
        XCTAssertEqual(SystemControllers.playerIndex(2), .index2)
        XCTAssertEqual(SystemControllers.playerIndex(5), .indexUnset, "GameController 只有 1–4 号")
        // 系统合成的一代 Joy-Con 断一只 / 接回：名字变了（(L/R) → (L) → (L/R)）也留在原位（同 Joy-Con 2），不跑到最后
        typealias U = PlayerAssignment.Unit
        var jc1 = PlayerAssignment()
        let lr = PlayerAssignment.SystemKey(name: "Joy-Con (L/R)", index: 0), lOnly = PlayerAssignment.SystemKey(name: "Joy-Con (L)", index: 0)
        let ds = PlayerAssignment.SystemKey(name: "DualSense Wireless Controller", index: 0)
        let hidLR: [PlayerAssignment.Gen1Device] = [.init(id: "jl", side: 0), .init(id: "jr", side: 1)]
        jc1.reconcile(devices: [], mergedPair: false, system: [lr, ds], gen1: hidLR)
        XCTAssertEqual(jc1.units, [U.system(name: lr.name, index: 0), U.system(name: ds.name, index: 0)])
        jc1.reconcile(devices: [], mergedPair: false, system: [ds, lOnly], gen1: [hidLR[0]])
        XCTAssertEqual(jc1.units.first, U.system(name: lOnly.name, index: 0), "断了右只：剩左只，还是 P1")
        jc1.reconcile(devices: [], mergedPair: false, system: [ds, lr], gen1: [hidLR[0]])   // 系统表先到、HID 表还没看到右只
        jc1.reconcile(devices: [], mergedPair: false, system: [ds, lr], gen1: hidLR)
        XCTAssertEqual(jc1.units.first, U.system(name: lr.name, index: 0), "接回：原位并回（两张表一前一后到也一样）")
        // 两套一代各连一只（系统给两位单只「Joy-Con (L)」「Joy-Con (R)」）：分配中左只按 L、右只按 R 同一刻 → 合成一对（同 Joy-Con 2）
        var cross = PlayerAssignment()
        let sl = PlayerAssignment.SystemKey(name: "Joy-Con (L)", index: 0), sr = PlayerAssignment.SystemKey(name: "Joy-Con (R)", index: 0)
        let halves: [PlayerAssignment.Gen1Device] = [.init(id: "a-L", side: 0), .init(id: "b-R", side: 1)]
        cross.reconcile(devices: [], mergedPair: false, system: [sl, sr], gen1: halves)
        XCTAssertEqual(cross.units.count, 2)
        cross.gen1(id: "a-L", side: 0, gesture: 3, at: 10, present: halves, system: [sl, sr])
        cross.gen1(id: "b-R", side: 1, gesture: 3, at: 10.1, present: halves, system: [sl, sr])
        XCTAssertEqual(cross.units, [U.gen1Pair(left: "a-L", right: "b-R")])
        cross.reconcile(devices: [], mergedPair: false, system: [sl, sr], gen1: halves)
        XCTAssertEqual(cross.units.count, 1, "合成后系统那两位不再排回来")
        // 两只单只左手一代（系统给「Joy-Con (L)」第 0、1 只）：第 2 只按 SL + SR 改按设备读，再拿掉第 1 只——
        //   第 2 只的系统号码挪成第 0 只，不能又以系统那一位多排一次（11-20 模拟手柄移除后玩家列表多一只）
        var g1TwoLeft = PlayerAssignment()
        let l0 = PlayerAssignment.SystemKey(name: "Joy-Con (L)", index: 0), l1 = PlayerAssignment.SystemKey(name: "Joy-Con (L)", index: 1)
        let both: [PlayerAssignment.Gen1Device] = [.init(id: "A", side: 0), .init(id: "B", side: 0)]
        g1TwoLeft.reconcile(devices: [], mergedPair: false, system: [l0, l1], gen1: both)
        g1TwoLeft.gen1(id: "B", side: 0, gesture: 2, at: 1, present: both, system: [l1])
        XCTAssertTrue(g1TwoLeft.units.contains(U.gen1(id: "B", side: 0)))
        g1TwoLeft.reconcile(devices: [], mergedPair: false, system: [l0], gen1: [.init(id: "B", side: 0)])
        XCTAssertEqual(g1TwoLeft.units, [U.gen1(id: "B", side: 0)], "同一只只占一位")
        // 左只单独连着、分配时按 SL + SR（横握单只），之后右只接上（系统合成「Joy-Con (L/R)」）：右只自己排一位，不消失、也不把左只算两次
        var lateRight = PlayerAssignment()
        let lOnly0 = PlayerAssignment.SystemKey(name: "Joy-Con (L)", index: 0), lr0 = PlayerAssignment.SystemKey(name: "Joy-Con (L/R)", index: 0)
        lateRight.reconcile(devices: [], mergedPair: false, system: [lOnly0], gen1: [.init(id: "a", side: 0)])
        lateRight.gen1(id: "a", side: 0, gesture: 2, at: 1, present: [.init(id: "a", side: 0)], system: [lOnly0])
        XCTAssertEqual(lateRight.units, [U.gen1(id: "a", side: 0)])
        let pair: [PlayerAssignment.Gen1Device] = [.init(id: "a", side: 0), .init(id: "b", side: 1)]
        lateRight.reconcile(devices: [], mergedPair: false, system: [lr0], gen1: [.init(id: "a", side: 0)])   // 系统表先到、HID 表还没看到右只
        lateRight.reconcile(devices: [], mergedPair: false, system: [lr0], gen1: pair)
        lateRight.reconcile(devices: [], mergedPair: false, system: [lr0], gen1: pair)
        XCTAssertEqual(lateRight.units, [U.gen1(id: "a", side: 0), U.gen1(id: "b", side: 1)], "右只自己一位（同 Joy-Con 2）")
        // 两套合成的一对（「Joy-Con (L/R)」第 0、1 只，没按过 L + R 学到），第 1 套的左只按 SL + SR：拆的是第 1 套（照连接先后对），不多出一只
        var twoPairs = PlayerAssignment()
        let p0 = PlayerAssignment.SystemKey(name: "Joy-Con (L/R)", index: 0), p1 = PlayerAssignment.SystemKey(name: "Joy-Con (L/R)", index: 1)
        let g1Four: [PlayerAssignment.Gen1Device] = [.init(id: "aL", side: 0), .init(id: "aR", side: 1), .init(id: "bL", side: 0), .init(id: "bR", side: 1)]
        twoPairs.reconcile(devices: [], mergedPair: false, system: [p0, p1], gen1: g1Four)
        twoPairs.gen1(id: "aL", side: 0, gesture: 2, at: 1, present: g1Four, system: [p0, p1])
        XCTAssertEqual(twoPairs.slots, [U.gen1(id: "aL", side: 0), U.system(name: p1.name, index: 1), U.gen1(id: "aR", side: 1)])
        twoPairs.reconcile(devices: [], mergedPair: false, system: [p0, p1], gen1: g1Four)
        XCTAssertEqual(twoPairs.units.count, 3, "拆完不多出一只")
        // Joy-Con 2 对照：一对断一只剩单只、接回拼回原位
        var jc2 = PlayerAssignment()
        jc2.reconcile(devices: [.init(id: "L", kind: 2), .init(id: "R", kind: 3)], mergedPair: true, system: [ds])
        jc2.reconcile(devices: [.init(id: "L", kind: 2)], mergedPair: true, system: [ds])
        XCTAssertEqual(jc2.units.first, U.single(id: "L", kind: 2))
        jc2.reconcile(devices: [.init(id: "L", kind: 2), .init(id: "R", kind: 3)], mergedPair: true, system: [ds])
        XCTAssertEqual(jc2.units.first, U.pair(left: "L", right: "R"))
        // 模拟手柄开关：偏好开着且没有更新源才有（同模拟更新）
        XCTAssertTrue(ControllerColorSimulator.isAllowed(preference: true, info: [:]))
        XCTAssertFalse(ControllerColorSimulator.isAllowed(preference: false, info: [:]))
        XCTAssertFalse(ControllerColorSimulator.isAllowed(preference: true, info: ["SUFeedURL": "https://example.invalid/appcast.xml"]), "发行版没有")
        // 一代 Joy-Con SPI 0x6050 应答 → 机身 / 按键颜色；全 FF（第三方没写颜色）不算
        var reply = [UInt8](repeating: 0, count: 49); reply[0] = 0x21; reply[13] = 0x90; reply[14] = 0x10; reply[15] = 0x50; reply[16] = 0x60; reply[19] = 6
        reply.replaceSubrange(20..<26, with: [0x0a, 0xb9, 0xe6, 0x00, 0x1e, 0x1e])
        XCTAssertEqual(Gen1HIDWatcher.color(report: reply), ControllerTint(body: 0x0ab9e6, buttons: 0x001e1e))
        reply.replaceSubrange(20..<26, with: Array(repeating: 0xff, count: 6))
        XCTAssertNil(Gen1HIDWatcher.color(report: reply), "全 FF = 没写过颜色，照缺省色")
        reply[15] = 0x3d
        XCTAssertNil(Gen1HIDWatcher.color(report: reply), "别的地址的 SPI 应答不当颜色")
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

    /// 模拟手柄面板（本地 / 自测构建的开发工具）：加两只一代（同一套）、一只 Joy-Con 2（断开）、一台 PS5，看排版
    @MainActor
    func testControllerSimulatorPanel() throws {
        let sim = ControllerColorSimulator.shared
        sim.clear()
        sim.setColor(.joyCon1, left: true, ControllerColorSimulator.gen1Presets[5])
        sim.setColor(.joyCon1, left: false, ControllerColorSimulator.gen1Presets[4])
        sim.addJoyCon(.joyCon1, left: true)
        sim.addJoyCon(.joyCon1, left: false)
        XCTAssertEqual(sim.kits.count, 1, "另一边连着：补进同一套")
        XCTAssertEqual(sim.systemPads().map(\.name), ["Joy-Con (L/R)"], "一代两只都连着：系统合成一个")
        sim.addJoyCon(.joyCon2, left: true)
        sim.toggleConnected(sim.rows[2])
        sim.addWhole(.ps5)
        XCTAssertEqual(sim.rows.count, 4)
        sim.selected = Set(sim.rows.prefix(2).map(\.id))
        XCTAssertTrue(sim.canPressSelected)
        try snapshot("controller_simulator", ControllerSimulatorPanelView().frame(width: 440, height: 400))
        sim.clear()
    }

    /// 一代 Joy-Con 全情境（11-20 一次对齐）：几套一代各左右只连 / 断，系统手柄表与 HID 表照连接顺序生成（同真机、同模拟手柄），
    ///   每一步看玩家列表。规则：同一只实体手柄最多一位；一套里有一只按设备登记了，系统那一位就不排，另一侧自己一位（同 Joy-Con 2）
    func testGen1JoyConScenarios() {
        struct Kit { var l: String?; var r: String? }
        func feed(_ kits: [Kit]) -> ([PlayerAssignment.SystemKey], [PlayerAssignment.Gen1Device]) {
            var keys: [PlayerAssignment.SystemKey] = [], gen1: [PlayerAssignment.Gen1Device] = [], seen: [String: Int] = [:]
            for k in kits {
                let name: String? = k.l != nil && k.r != nil ? "Joy-Con (L/R)" : k.l != nil ? "Joy-Con (L)" : k.r != nil ? "Joy-Con (R)" : nil
                if let name { keys.append(.init(name: name, index: seen[name, default: 0])); seen[name, default: 0] += 1 }
                if let l = k.l { gen1.append(.init(id: l, side: 0)) }
                if let r = k.r { gen1.append(.init(id: r, side: 1)) }
            }
            return (keys, gen1)
        }
        func step(_ a: inout PlayerAssignment, _ kits: [Kit]) { let (s, g) = feed(kits); a.reconcile(devices: [], mergedPair: false, system: s, gen1: g) }
        func press(_ a: inout PlayerAssignment, _ kits: [Kit], _ id: String, _ side: Int, _ gesture: Int, at t: TimeInterval) {
            let (s, g) = feed(kits); a.gen1(id: id, side: side, gesture: gesture, at: t, present: g, system: s)
        }
        func show(_ a: PlayerAssignment) -> [String] {
            a.units.map { u -> String in
                switch u {
                case let .system(n, i): return "\(n)#\(i)"
                case let .gen1(id, _): return id
                case let .gen1Pair(l, r): return l + "+" + r
                default: return "?"
                }
            }
        }
        // A 一对拆开（左只 SL + SR）→ 两位；右只断开 → 剩左只；右只接回 → 右只自己一位（不并回、不多一只）
        var a = PlayerAssignment(); var k = [Kit(l: "a", r: "b")]
        step(&a, k); XCTAssertEqual(show(a), ["Joy-Con (L/R)#0"], "A 连上缺省合成一位")
        press(&a, k, "a", 0, 2, at: 1); step(&a, k); XCTAssertEqual(show(a), ["a", "b"], "A SL + SR 拆成两位")
        k[0].r = nil; step(&a, k); step(&a, k); XCTAssertEqual(show(a), ["a"], "A 右只断开")
        k[0].r = "b"; step(&a, k); step(&a, k); XCTAssertEqual(show(a), ["a", "b"], "A 右只接回自己一位")
        // B 一对没拆：右只断开 → 原位剩左只；接回 → 原位并回一对
        var b = PlayerAssignment(); var kb = [Kit(l: "x", r: nil), Kit(l: "a", r: "b")]
        kb[0].l = nil; step(&b, kb)
        kb[1].r = nil; step(&b, kb); XCTAssertEqual(show(b), ["Joy-Con (L)#0"], "B 右只断开")
        kb[1].r = "b"; step(&b, kb); XCTAssertEqual(show(b), ["Joy-Con (L/R)#0"], "B 接回并回一对")
        // C 两套合成的一对，第 1 套左只 SL + SR → 拆的是第 1 套
        var c = PlayerAssignment(); var kc = [Kit(l: "a1", r: "b1"), Kit(l: "a2", r: "b2")]
        step(&c, kc); XCTAssertEqual(show(c), ["Joy-Con (L/R)#0", "Joy-Con (L/R)#1"])
        press(&c, kc, "a1", 0, 2, at: 1); step(&c, kc); XCTAssertEqual(show(c), ["a1", "Joy-Con (L/R)#1", "b1"], "C 拆第 1 套（不挤动 P2）")
        // E 接着两只右只都断开 → 第 1 套剩 a1（按设备）、第 2 套剩系统的左只；不重复、不少
        kc[0].r = nil; kc[1].r = nil; step(&c, kc); step(&c, kc); XCTAssertEqual(show(c), ["a1", "Joy-Con (L)#1"], "E 两只右只断开")
        // K 两套，拆第 2 套
        var kk = PlayerAssignment(); let k2 = [Kit(l: "a1", r: "b1"), Kit(l: "a2", r: "b2")]
        step(&kk, k2); press(&kk, k2, "a2", 0, 2, at: 1); step(&kk, k2)
        XCTAssertEqual(show(kk), ["Joy-Con (L/R)#0", "a2", "b2"], "K 拆第 2 套")
        // D 两套没拆，两只右只都断开 → 各剩左只、原位
        var d = PlayerAssignment(); var kd = [Kit(l: "a1", r: "b1"), Kit(l: "a2", r: "b2")]
        step(&d, kd); kd[0].r = nil; kd[1].r = nil; step(&d, kd); XCTAssertEqual(show(d), ["Joy-Con (L)#0", "Joy-Con (L)#1"], "D")
        // F 两套各只连左只，移除第 1 套 → 剩一位
        var f = PlayerAssignment(); var kf = [Kit(l: "A", r: nil), Kit(l: "B", r: nil)]
        step(&f, kf); XCTAssertEqual(show(f), ["Joy-Con (L)#0", "Joy-Con (L)#1"], "F 两只左只各一位")
        kf.removeFirst(); step(&f, kf); XCTAssertEqual(show(f), ["Joy-Con (L)#0"], "F 移除一套")
        // G 两只单只左手，第 2 只 SL + SR，再移除第 1 只 → 只剩第 2 只（按设备），不重复
        var g = PlayerAssignment(); var kg = [Kit(l: "A", r: nil), Kit(l: "B", r: nil)]
        step(&g, kg); press(&g, kg, "B", 0, 2, at: 1); step(&g, kg); XCTAssertEqual(show(g), ["Joy-Con (L)#0", "B"], "G 第 2 只改按设备")
        kg.removeFirst(); step(&g, kg); step(&g, kg); XCTAssertEqual(show(g), ["B"], "G 移除第 1 只")
        // H 左只单独连、SL + SR，之后右只接上同一套 → 右只自己一位
        var h = PlayerAssignment(); var kh = [Kit(l: "a", r: nil)]
        step(&h, kh); press(&h, kh, "a", 0, 2, at: 1); step(&h, kh); XCTAssertEqual(show(h), ["a"])
        kh[0].r = "b"; step(&h, kh); step(&h, kh); XCTAssertEqual(show(h), ["a", "b"], "H 后接上的右只自己一位")
        // I 两套各只连一边（一左一右），同按 L + R → 合成一对；之后不重复
        var i = PlayerAssignment(); let ki = [Kit(l: "a", r: nil), Kit(l: nil, r: "b")]
        step(&i, ki); XCTAssertEqual(show(i), ["Joy-Con (L)#0", "Joy-Con (R)#0"])
        press(&i, ki, "a", 0, 3, at: 5); press(&i, ki, "b", 1, 3, at: 5.1); step(&i, ki); XCTAssertEqual(show(i), ["a+b"], "I 跨套 L + R 合成")
        // L 四套一代（P1–P4 各一对），各种拆 / 合 / 断 / 接回交错，每一步每只实体手柄都只在一位里
        var m = PlayerAssignment()
        var km = [Kit(l: "1L", r: "1R"), Kit(l: "2L", r: "2R"), Kit(l: "3L", r: "3R"), Kit(l: "4L", r: "4R")]
        step(&m, km); XCTAssertEqual(show(m), ["Joy-Con (L/R)#0", "Joy-Con (L/R)#1", "Joy-Con (L/R)#2", "Joy-Con (L/R)#3"], "L 四套各一位")
        press(&m, km, "3R", 1, 2, at: 1); step(&m, km)
        XCTAssertEqual(show(m), ["Joy-Con (L/R)#0", "Joy-Con (L/R)#1", "3R", "Joy-Con (L/R)#3", "3L"], "L 拆第 3 套（按的那只留原位、第 4 套仍留 P4 不被挤动、另一只进空槽 P5）")
        press(&m, km, "1L", 0, 2, at: 2); step(&m, km)
        XCTAssertEqual(show(m), ["1L", "Joy-Con (L/R)#1", "3R", "Joy-Con (L/R)#3", "3L", "1R"], "L 再拆第 1 套（另一只进空槽 P6）")
        km[1].r = nil; step(&m, km); step(&m, km)   // 第 2 套断右只（没拆过）
        XCTAssertEqual(show(m), ["1L", "Joy-Con (L)#0", "3R", "Joy-Con (L/R)#2", "3L", "1R"], "L 第 2 套断右只：原位剩左只；第 4 套号码挪成 #2 也跟着走")
        km[0].r = nil; step(&m, km); step(&m, km)   // 第 1 套断右只（拆过）
        XCTAssertEqual(show(m), ["1L", "Joy-Con (L)#1", "3R", "Joy-Con (L/R)#1", "3L"], "L 第 1 套断右只")
        km[1].r = "2R"; step(&m, km); step(&m, km)   // 第 2 套接回
        XCTAssertEqual(Set(show(m)).count, show(m).count, "L 不重复")
        XCTAssertEqual(show(m).count, 5, "L 第 2 套接回：1L、2 一对、3R、3L、4 一对")
        km[0].r = "1R"; step(&m, km); step(&m, km)   // 第 1 套接回（拆过：右只自己一位）
        XCTAssertTrue(show(m).contains("1R") && show(m).contains("1L"), "L 第 1 套右只接回自己一位")
        press(&m, km, "3R", 1, 3, at: 10); press(&m, km, "3L", 0, 3, at: 10.1); step(&m, km)   // 第 3 套按 L + R 合回
        XCTAssertTrue(show(m).contains("3L+3R"), "L 第 3 套合回一对")
        XCTAssertEqual(show(m).count, 5, "L 合回后：1L、1R、2 一对、3 一对、4 一对")
        let allIDs = ["1L", "1R", "2L", "2R", "3L", "3R", "4L", "4R"]
        let (keysNow, devsNow) = feed(km)
        let owners = m.gen1Owners(system: keysNow, gen1: devsNow)
        for id in allIDs {
            let direct = m.units.filter { if case let .gen1(x, _) = $0 { return x == id }; if case let .gen1Pair(l, r) = $0 { return l == id || r == id }; return false }.count
            let viaSystem = m.units.filter { if case let .system(n, i) = $0 { return owners[.init(name: n, index: i)]?.values.contains(id) == true }; return false }.count
            XCTAssertEqual(direct + viaSystem, 1, "L \(id) 恰好一位")
        }
        // M 两套，分配时拆第 1 套、按「完成」，第 1 套两只都断开再接回 → 照常回来（接回是新连上：缺省合成一位，同 Joy-Con 2 断开后忘了横握）
        var mm = PlayerAssignment(); var km2 = [Kit(l: "1L", r: "1R"), Kit(l: "2L", r: "2R")]
        step(&mm, km2); press(&mm, km2, "1L", 0, 2, at: 1)
        do { let (s0, g0) = feed(km2); mm.finish(presentSystem: s0, devices: [], gen1: g0) }
        step(&mm, km2); XCTAssertEqual(show(mm), ["1L", "Joy-Con (L/R)#1", "1R"], "M 拆完按完成")
        km2[0] = Kit(l: nil, r: nil); step(&mm, km2); step(&mm, km2); XCTAssertEqual(show(mm), ["Joy-Con (L/R)#0"], "M 第 1 套断开：第 2 套号码挪成 #0 跟着走")
        km2[0] = Kit(l: "1L", r: "1R"); step(&mm, km2); step(&mm, km2)
        XCTAssertEqual(show(mm).count, 2, "M 第 1 套接回：两套都在，现在是 \(show(mm))")
        // N 同 M，但照真机 / 模拟手柄的样子：一只一只断开 / 接回，系统手柄表与 HID 表一前一后到（两种先后都试）
        for systemFirst in [true, false] {
            var n = PlayerAssignment(); var kn = [Kit(l: "1L", r: "1R"), Kit(l: "2L", r: "2R")]
            func lag(_ next: [Kit]) {
                let (s0, g0) = feed(kn), (s1, g1) = feed(next)
                if systemFirst { n.reconcile(devices: [], mergedPair: false, system: s1, gen1: g0) } else { n.reconcile(devices: [], mergedPair: false, system: s0, gen1: g1) }
                n.reconcile(devices: [], mergedPair: false, system: s1, gen1: g1); kn = next
            }
            lag(kn); press(&n, kn, "1L", 0, 2, at: 1)
            do { let (s0, g0) = feed(kn); n.finish(presentSystem: s0, devices: [], gen1: g0) }
            lag(kn); XCTAssertEqual(show(n), ["1L", "Joy-Con (L/R)#1", "1R"], "N\(systemFirst) 拆完")
            var k1 = kn; k1[0].l = nil; lag(k1)
            k1[0].r = nil; lag(k1); XCTAssertEqual(show(n), ["Joy-Con (L/R)#0"], "N\(systemFirst) 第 1 套两只都断开")
            k1[0].l = "1L"; lag(k1)
            k1[0].r = "1R"; lag(k1)
            XCTAssertEqual(show(n).count, 2, "N\(systemFirst) 第 1 套接回：两套都在，现在是 \(show(n))")
        }
        // O 11-20 日志重现：两套，拆第 2 套（左只 SL + SR）、按完成；第 2 套左只断开再接回 → 左只回来自己一位，不消失
        for systemFirst in [true, false] {
            var o = PlayerAssignment(); var ko = [Kit(l: "1L", r: "1R"), Kit(l: "2L", r: "2R")]
            func lag(_ next: [Kit]) {
                let (s0, g0) = feed(ko), (s1, g1) = feed(next)
                if systemFirst { o.reconcile(devices: [], mergedPair: false, system: s1, gen1: g0) } else { o.reconcile(devices: [], mergedPair: false, system: s0, gen1: g1) }
                o.reconcile(devices: [], mergedPair: false, system: s1, gen1: g1); ko = next
            }
            lag(ko); press(&o, ko, "2L", 0, 2, at: 1)
            do { let (s0, g0) = feed(ko); o.finish(presentSystem: s0, devices: [], gen1: g0) }
            lag(ko); XCTAssertEqual(show(o), ["Joy-Con (L/R)#0", "2L", "2R"], "O\(systemFirst) 拆第 2 套")
            var k2 = ko; k2[1].l = nil; lag(k2); XCTAssertEqual(show(o), ["Joy-Con (L/R)#0", "2R"], "O\(systemFirst) 左只断开")
            k2[1].l = "2L"; lag(k2); XCTAssertEqual(show(o), ["Joy-Con (L/R)#0", "2L", "2R"], "O\(systemFirst) 左只接回原槽 P2")
        }
        // P 11-20 日志重现：拆开后又按 L + R 合回一对（按设备读的一对），右只断开 → 剩左只；右只接回 → 原位并回一对（没重新配对也一样，同 Joy-Con 2）
        for systemFirst in [true, false] {
            var q = PlayerAssignment(); var kq = [Kit(l: "1L", r: "1R"), Kit(l: "2L", r: "2R")]
            func lag(_ next: [Kit]) {
                let (s0, g0) = feed(kq), (s1, g1) = feed(next)
                if systemFirst { q.reconcile(devices: [], mergedPair: false, system: s1, gen1: g0) } else { q.reconcile(devices: [], mergedPair: false, system: s0, gen1: g1) }
                q.reconcile(devices: [], mergedPair: false, system: s1, gen1: g1); kq = next
            }
            lag(kq); press(&q, kq, "1L", 0, 2, at: 1); lag(kq)
            press(&q, kq, "1L", 0, 3, at: 5); press(&q, kq, "1R", 1, 3, at: 5.1); lag(kq)
            XCTAssertEqual(show(q), ["1L+1R", "Joy-Con (L/R)#1"], "P\(systemFirst) 合回一对")
            var k3 = kq; k3[0].r = nil; lag(k3); XCTAssertEqual(show(q), ["1L", "Joy-Con (L/R)#0"], "P\(systemFirst) 右只断开（第 2 套号码挪成 #0）")
            k3[0].r = "1R"; lag(k3); XCTAssertEqual(show(q), ["1L+1R", "Joy-Con (L/R)#1"], "P\(systemFirst) 右只接回：原位并回")
            // 剩下那只先按 SL + SR（要横握单只）→ 接回的另一只自己一位
            k3[0].r = nil; lag(k3); press(&q, k3, "1L", 0, 2, at: 9); k3[0].r = "1R"; lag(k3)
            XCTAssertEqual(show(q), ["1L", "Joy-Con (L/R)#1", "1R"], "P\(systemFirst) 按过 SL + SR 就不并")
        }
        // J 全部移除
        step(&i, []); step(&a, []); step(&c, []); XCTAssertEqual(show(i) + show(a) + show(c), [], "J 全部移除")
    }

    /// Joy-Con 2 两套都拆开（SL + SR），任一只断开再接回都不拼回一组；没拆过的一对断一只再接回照旧拼回原位
    func testJoyCon2SplitSurvivesReconnect() {
        struct Kit { var l: Bool; var r: Bool }
        func devices(_ kits: [Kit]) -> (devs: [PlayerAssignment.Device], merged: Set<Int>) {
            var devs: [PlayerAssignment.Device] = [], merged = Set<Int>()
            for (n, k) in kits.enumerated() {
                if k.l { devs.append(.init(id: "\(n + 1)L", kind: 2, group: 100 + n)) }
                if k.r { devs.append(.init(id: "\(n + 1)R", kind: 3, group: 100 + n)) }
                if k.l && k.r { merged.insert(100 + n) }
            }
            return (devs, merged)
        }
        func show(_ a: PlayerAssignment) -> [String] {
            a.units.map { u in switch u { case let .pair(l, r): return l + "+" + r; case let .single(id, _): return id; default: return "?" } }
        }
        for victim in ["1L", "1R", "2L", "2R"] {
            var a = PlayerAssignment(); var kits = [Kit(l: true, r: true), Kit(l: true, r: true)]
            func step() { let d = devices(kits); a.reconcile(devices: d.devs, mergedGroups: d.merged, system: []) }
            step(); XCTAssertEqual(show(a), ["1L+1R", "2L+2R"])
            a.ns2(id: "1L", kind: 2, gesture: 2, at: 1); a.ns2(id: "2R", kind: 3, gesture: 2, at: 2); step()
            XCTAssertEqual(show(a), ["1L", "2R", "1R", "2L"], "两套都拆开（不挤动已有玩家位）")
            let n = Int(String(victim.first!))! - 1, left = victim.hasSuffix("L")
            if left { kits[n].l = false } else { kits[n].r = false }; step()
            if left { kits[n].l = true } else { kits[n].r = true }; step()
            XCTAssertEqual(show(a).count, 4, "\(victim) 断开重连：仍是四位，不拼回一组（现在 \(show(a))）")
        }
        // 11-20 日志重现：两套都拆开，1L 断开重连、再 1R 断开重连；再两只一起断开重连 → 都不拼回
        var c = PlayerAssignment(); var kc = [Kit(l: true, r: true), Kit(l: true, r: true)]
        func stepC() { let d = devices(kc); c.reconcile(devices: d.devs, mergedGroups: d.merged, system: []) }
        stepC(); c.ns2(id: "1L", kind: 2, gesture: 2, at: 1); c.ns2(id: "2L", kind: 2, gesture: 2, at: 2); stepC()
        kc[0].l = false; stepC(); kc[0].l = true; stepC()
        kc[0].r = false; stepC(); kc[0].r = true; stepC()
        XCTAssertEqual(show(c).count, 4, "一只一只断开重连：仍是四位（现在 \(show(c))）")
        kc[0] = Kit(l: false, r: false); stepC(); kc[0] = Kit(l: true, r: true); stepC()
        XCTAssertEqual(show(c).count, 4, "两只一起断开重连：仍是四位（现在 \(show(c))）")
        // 按 L + R 才拼回
        c.ns2(id: "1L", kind: 2, gesture: 3, at: 10); c.ns2(id: "1R", kind: 3, gesture: 3, at: 10.1); stepC()
        XCTAssertEqual(show(c).count, 3, "按 L + R 拼回一对")
        // 11-20 日志重现：跨套按 L + R 拼成一对（2L + 1R），1R 断开再接回 → 原位并回，不变成单只
        var x = PlayerAssignment(); var kx = [Kit(l: true, r: true), Kit(l: true, r: true)]
        func stepX() { let d = devices(kx); x.reconcile(devices: d.devs, mergedGroups: d.merged, system: []) }
        stepX(); x.ns2(id: "1L", kind: 2, gesture: 2, at: 1); x.ns2(id: "2L", kind: 2, gesture: 2, at: 2); stepX()
        x.ns2(id: "2L", kind: 2, gesture: 3, at: 5); x.ns2(id: "1R", kind: 3, gesture: 3, at: 5.1); stepX()
        XCTAssertTrue(show(x).contains("2L+1R"), "跨套拼成一对")
        kx[0].r = false; stepX(); XCTAssertFalse(show(x).contains("2L+1R"))
        kx[0].r = true; stepX(); XCTAssertTrue(show(x).contains("2L+1R"), "1R 接回：原位并回（现在 \(show(x))）")
        XCTAssertEqual(show(x).count, 3)
        // 对照：没拆过的一对断一只再接回 → 原位拼回
        var b = PlayerAssignment(); var kb = [Kit(l: true, r: true)]
        func stepB() { let d = devices(kb); b.reconcile(devices: d.devs, mergedGroups: d.merged, system: []) }
        stepB(); kb[0].r = false; stepB(); XCTAssertEqual(show(b), ["1L"]); kb[0].r = true; stepB(); XCTAssertEqual(show(b), ["1L+1R"], "没拆过：接回拼回原位")
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
