// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// 0.6.0 iPhone 总控台（通用壳开关后面）。期望按《0.6.0 极简流程》界面一节手写：
//   首位卡状态行自上而下取第一条成立的（介绍卡 → 正在更新 → 没连 → 没装 → 有新版 → 已到期 / 快到期 → N 款建议更新 → 已装好还剩约 N 天）；
//   建议更新的默认勾上，玩家取消的不重勾；「更新所选」按游戏库顺序一款款推到总控台这台，「停下」停在当前这款、排着的不推
@MainActor final class PhoneConsoleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func phone(online: String?? = nil, installed: Bool = true, current: Bool = true, expires: TimeInterval? = 6 * 86_400 - 60,
                       games: [PhoneOverview.Game] = [], device: String = "D1", lastSeen: Date? = nil) -> PhoneOverview.Phone {
        PhoneOverview.Phone(device: device, name: "我的手机", installed: installed, shellCurrent: current, bundleId: "io.s2arm.games.T", signedAt: nil, free: true,
                            expiresAtEstimate: expires.map { now.addingTimeInterval($0) }, online: online, lastSeen: lastSeen, signMode: .appleId, games: games)
    }
    private func game(_ id: String, _ s: PhoneOverview.GameState) -> PhoneOverview.Game { .init(gameId: id, state: s, reasons: s == .suggested ? ["shader"] : [], dataOnComputer: true) }

    private func makeModel(_ runner: JobProcessRunner = ConsoleRunner()) throws -> S2ArmLauncherModel {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-console-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        return S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
    }

    func testParseResult() {
        XCTAssertNil(PhoneOverview(result: [:]), "结果里没有 phones（作业层太旧）→ 不出首位卡")
        let o = PhoneOverview(result: ["phones": [
            ["device": "D1", "name": "我的手机", "installed": true, "shellCurrent": false, "free": true, "expiresAtEstimate": 2_000_000_000, "lastSeen": 1_999_990_000,
             "online": NSNull(), "signMode": "devCert",
             "games": [["gameId": "0100a", "state": "suggested", "reasons": ["hostAbi"]], ["gameId": "0100B", "state": "needsData", "dataOnComputer": false],
                       ["gameId": "0100C", "state": "weird"]]],
            ["device": "D2", "name": "旧手机"]]])
        XCTAssertEqual(o?.phones.count, 2)
        let p = try? XCTUnwrap(o?.phones.first)
        XCTAssertEqual(p?.signMode, .devCert); XCTAssertEqual(p?.shellCurrent, false)
        XCTAssertEqual(p?.online.map { $0 == nil }, true, "带了 online 键、值为空 = 问过、没连")
        XCTAssertNil(o?.phones.last?.online ?? nil, "没带 online 键 = 没问")
        XCTAssertEqual(p?.games.map(\.gameId), ["0100A", "0100B"], "游戏号转大写；不认识的状态丢掉")
        XCTAssertEqual(p?.games.last?.dataOnComputer, false)
    }

    func testParseApps() {
        // 独立 App（0.6.4，作业 apps）：游戏号转大写、到期与签名时刻按秒转日期；旧作业层不带 apps = 空。期望手写
        let o = PhoneOverview(result: ["phones": [["device": "D1", "apps": [["gameId": "010026300ba4a000", "bundleId": "io.s2arm.games.t.010026300ba4a000", "shellCurrent": false,
                                                                         "signedAt": 1000.0, "expiresAtEstimate": 865000.0], ["bundleId": "缺游戏号的丢掉"]]],
                                                  ["device": "D2"]]])!
        XCTAssertEqual(o.phones[0].apps, [PhoneOverview.App(gameId: "010026300BA4A000", bundleId: "io.s2arm.games.t.010026300ba4a000", shellCurrent: false,
                                                            signedAt: Date(timeIntervalSince1970: 1000), expiresAtEstimate: Date(timeIntervalSince1970: 865000))])
        XCTAssertEqual(o.phones[1].apps, [])
    }

    func testStatusOrder() throws {
        let m = try makeModel()
        XCTAssertEqual(m.consoleStatus(now: now), .introduce, "从没装过也没连过：介绍卡")
        m.phoneOverview = PhoneOverview(phones: [phone(online: .some(nil), installed: false, lastSeen: now)])
        XCTAssertEqual(m.consoleStatus(now: now), .notConnected(lastSeen: now), "没连排在没装前面")
        m.phoneOverview = PhoneOverview(phones: [phone(installed: false)])
        XCTAssertEqual(m.consoleStatus(now: now), .notInstalled)
        m.phoneOverview = PhoneOverview(phones: [phone(current: false, expires: -10)])
        XCTAssertEqual(m.consoleStatus(now: now), .appOutdated, "有新版排在到期前面")
        m.phoneOverview = PhoneOverview(phones: [phone(expires: -10)])
        XCTAssertEqual(m.consoleStatus(now: now), .expired)
        m.phoneOverview = PhoneOverview(phones: [phone(expires: 86_400 + 5, games: [game("0100A", .suggested)])])
        XCTAssertEqual(m.consoleStatus(now: now), .expiring(days: 2), "1 天多一点按 2 天；快到期排在建议更新前面")
        m.phoneOverview = PhoneOverview(phones: [phone(games: [game("0100A", .suggested), game("0100B", .suggested), game("0100C", .latest)])])
        XCTAssertEqual(m.consoleStatus(now: now), .suggested(count: 2))
        m.phoneOverview = PhoneOverview(phones: [phone(games: [game("0100C", .latest)])])
        XCTAssertEqual(m.consoleStatus(now: now), .ok(days: 6))
        m.phoneOverview = PhoneOverview(phones: [phone(expires: nil)])
        XCTAssertEqual(m.consoleStatus(now: now), .ok(days: nil), "没有到期估值（证书用户）不写天数")
    }

    func testWhichPhone() throws {
        let m = try makeModel()
        m.phoneOverview = PhoneOverview(phones: [phone(device: "OLD", lastSeen: now.addingTimeInterval(-99)), phone(device: "NEW", lastSeen: now)])
        XCTAssertEqual(m.consolePhone?.device, "NEW", "没选过：最近同步过的那台")
        m.phoneOverview = PhoneOverview(phones: [phone(online: .some("usb"), device: "OLD", lastSeen: now.addingTimeInterval(-99)), phone(device: "NEW", lastSeen: now)])
        XCTAssertEqual(m.consolePhone?.device, "OLD", "连着的那台优先")
        m.consoleDevice = "NEW"
        XCTAssertEqual(m.consolePhone?.device, "NEW", "顶部切过就管那台")
    }

    func testSuggestedTickedOnceAndUntickRespected() throws {
        let m = try makeModel()
        m.phoneOverview = PhoneOverview(phones: [phone(games: [game("0100A", .suggested), game("0100B", .latest)])])
        m.seedConsoleSelection()
        XCTAssertEqual(m.consoleSelection, ["0100A"], "建议更新的默认勾上，其余不勾")
        m.consoleSelection.remove("0100A"); m.seedConsoleSelection()
        XCTAssertEqual(m.consoleSelection, [], "玩家取消的不重勾")
        m.phoneOverview = PhoneOverview(phones: [phone(games: [game("0100A", .suggested), game("0100B", .suggested)])])
        m.seedConsoleSelection()
        XCTAssertEqual(m.consoleSelection, ["0100B"], "新出现的建议更新款补勾")
    }

    // 顶栏动态窗口：做完闪 ✓（2 秒后收起，一轮里还有排着的不闪），失败 / 停下留橙色「!」直到点开；开关关着都不出。期望手写
    func testDynamicWindowDoneAndAlert() async throws {
        let m = try makeModel()
        m.dynamicFinished(.completed)
        XCTAssertFalse(m.dynamicDone, "开关关着不出")
        m.phoneOverview = PhoneOverview(phones: [phone()])
        m.dynamicFinished(.completed)
        XCTAssertTrue(m.dynamicDone, "做完闪一下")
        for _ in 0..<300 where m.dynamicDone { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(m.dynamicDone, "2 秒后回普通图标")
        m.dynamicFinished(.failed)
        XCTAssertTrue(m.dynamicAlert, "失败留橙色「!」")
        m.openConsoleFromTopBar()
        XCTAssertFalse(m.dynamicAlert, "点开看过就收起"); XCTAssertTrue(m.consoleSelected, "点它直接到总控台")
    }

    func testUpdateSelectedIsOneJobInOrderToThisPhoneAndStopCancelsIt() async throws {
        let runner = ConsoleRunner(holdPush: true)
        let m = try makeModel(runner)
        m.refresh()   // 假 catalog 给 A、B、C 三款；假 phoneOverview 给一台 D9
        for _ in 0..<300 where m.games.count < 3 || m.phoneOverview == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(m.consolePhone?.device, "D9")
        m.consoleSelection = ["0100C", "0100A", "0100B"]
        m.updateSelected()
        for _ in 0..<300 where runner.pushes.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.pushes.count, 1, "更新所选是一单作业（pushSelected），不是三单装机")
        XCTAssertEqual(runner.pushes.first?["gameIds"] as? [String], ["0100A", "0100B", "0100C"], "按游戏库顺序")
        XCTAssertEqual(runner.pushes.first?["device"] as? String, "D9", "推总控台这台")
        XCTAssertTrue(m.consoleUpdating)
        if case .updating = m.consoleStatus(now: now) {} else { XCTFail("首位卡写正在更新") }
        m.stopUpdateSelected()
        for _ in 0..<300 where m.consoleUpdating { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(m.consoleUpdating, "停下 = 取消这一单")
        XCTAssertEqual(runner.installs.count, 0, "不再一款款排装机作业")
    }

    // ---- 11-19 自签走查结构 4、5：别的工具（AltStore / SideStore）装的 S2Arm。期望按作业契约（host_update.phone_overview）手写 ----
    private let alt = "io.s2arm.games.example01"
    private let externalFour: [S2ArmLauncherModel.ConsoleAction] = [.exportShellIpa, .pushS2arm, .exportS2arm, .handOverIdentity]
    private func externalPhone(online: String?? = .some("usb"), actions: [String] = ["exportShellIpa", "pushS2arm", "exportS2arm", "handOverIdentity"]) -> PhoneOverview.Phone {
        PhoneOverview.Phone(device: "ALT-1", name: "备用手机", installed: true, shellCurrent: false, bundleId: alt, signedAt: nil, free: true,
                            expiresAtEstimate: nil, online: online, lastSeen: nil, signMode: .external, games: [], installedBy: .external, actions: actions)
    }

    func testParseInstalledByAndActions() {
        let o = PhoneOverview(result: ["phones": [
            ["device": "ALT-1", "installed": true, "installedBy": "external", "bundleId": alt, "shellCurrent": NSNull(), "signMode": "external",
             "actions": ["exportShellIpa", "pushS2arm", "exportS2arm", "handOverIdentity"]],
            ["device": "P1", "installed": true, "installedBy": "launcher", "shellCurrent": true],
            ["device": "OLD", "installed": true, "shellCurrent": true]]])
        let ps = o?.phones ?? []
        XCTAssertEqual(ps.map(\.installedBy), [.external, .launcher, nil], "旧作业不带 installedBy → nil")
        XCTAssertEqual(ps.first?.actions, ["exportShellIpa", "pushS2arm", "exportS2arm", "handOverIdentity"])
        XCTAssertEqual(ps.first?.bundleId, alt); XCTAssertEqual(ps.first?.shellCurrent, false, "shellCurrent = null 按 false 解")
        XCTAssertEqual(ps.last?.actions, [], "没给 actions = 空")
    }

    func testExternalPhoneOwnStateAndFourButtonsNoInstall() throws {
        let m = try makeModel()
        m.phoneOverview = PhoneOverview(phones: [externalPhone()])
        XCTAssertEqual(m.consoleStatus(now: now), .externalApp, "没有签名时刻与壳号：不走没装 / 有新版 / 到期，进自己的状态")
        let acts = m.consoleActions(m.consolePhone!)
        XCTAssertEqual(acts, externalFour, "按作业给的 actions 出四个按钮、顺序不变")
        XCTAssertTrue(Set(acts).isDisjoint(with: [.installShell, .updateShell, .renewShell]), "绝不出安装 / 更新 / 续签 S2Arm")
        m.phoneOverview = PhoneOverview(phones: [externalPhone(actions: ["installShell", "renewShell", "handOverIdentity"])])
        XCTAssertEqual(m.consoleActions(m.consolePhone!), [.handOverIdentity], "作业就算给了安装 / 续签也不出")
        m.phoneOverview = PhoneOverview(phones: [externalPhone(actions: [])])
        XCTAssertEqual(m.consoleActions(m.consolePhone!), externalFour, "作业没给 actions：按四个缺省")
        m.phoneOverview = PhoneOverview(phones: [externalPhone(online: .some(nil))])
        XCTAssertEqual(m.consoleStatus(now: now), .notConnected(lastSeen: nil), "没连照旧排在前面")
        // 启动器装的照旧：一颗随状态变 + 交身份 + 更新所选
        m.phoneOverview = PhoneOverview(phones: [phone()])
        XCTAssertEqual(m.consoleActions(m.consolePhone!), [.renewShell, .handOverIdentity, .updateSelected])
        m.phoneOverview = PhoneOverview(phones: [phone(installed: false)])
        XCTAssertEqual(m.consoleActions(m.consolePhone!).first, .installShell)
        m.phoneOverview = PhoneOverview(phones: [phone(current: false)])
        XCTAssertEqual(m.consoleActions(m.consolePhone!).first, .updateShell)
    }

    func testControlStatePhoneConsoleSameSourceAsUI() throws {
        let m = try makeModel()
        let o = PhoneOverview(phones: [externalPhone(), phone(device: "P1"), phone(installed: false, device: "NEW")])
        m.phoneOverview = o
        let rows = S2ArmControl.phoneConsole(o, model: m)
        func row(_ d: String) -> [String: Any] { rows.first { $0["device"] as? String == d } ?? [:] }
        let ext = row("ALT-1"), ins = ext["installed"] as? [String: Any] ?? [:]
        XCTAssertEqual(ins["by"] as? String, "other"); XCTAssertEqual(ins["bundleId"] as? String, alt)
        XCTAssertEqual(ext["actions"] as? [String], ["exportShellIpa", "pushS2arm", "exportS2arm", "handOverIdentity"], "验收判据：没有 installShell、有 handOverIdentity")
        XCTAssertEqual((row("P1")["installed"] as? [String: Any])?["by"] as? String, nil, "测试替身 phone() 没给 installedBy → null")
        XCTAssertTrue((row("P1")["installed"] as? [String: Any])?["by"] is NSNull)
        XCTAssertEqual(row("P1")["actions"] as? [String], ["renewShell", "handOverIdentity", "updateSelected"])
        XCTAssertEqual(row("NEW")["actions"] as? [String], ["installShell", "handOverIdentity", "updateSelected"])
        let launcher = PhoneOverview(phones: [PhoneOverview.Phone(device: "L", name: "", installed: true, shellCurrent: true, bundleId: "", signedAt: nil, free: true,
                                                                  expiresAtEstimate: nil, online: nil, lastSeen: nil, signMode: .appleId, games: [], installedBy: .launcher)])
        let l = S2ArmControl.phoneConsole(launcher, model: m).first?["installed"] as? [String: Any]
        XCTAssertEqual(l?["by"] as? String, "s2arm"); XCTAssertTrue(l?["bundleId"] is NSNull, "没有包名 = null")
    }

    func testIntroStartProbesFirstAndStopsOnExternalApp() async throws {
        let runner = ConsoleRunner(probePhones: [["device": "ALT-1", "name": "备用手机", "installed": true, "installedBy": "external", "bundleId": alt,
                                                  "shellCurrent": NSNull(), "signMode": "external", "online": "usb",
                                                  "actions": ["exportShellIpa", "pushS2arm", "exportS2arm", "handOverIdentity"], "games": [[String: Any]]()]])
        let m = try makeModel(runner)
        m.consoleIntroStart(language: "zh-Hans")
        for _ in 0..<300 where m.phoneOverview == nil { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runner.overviewProbes, [true], "介绍卡主动作先现查（probe），只查一次")
        XCTAssertEqual(m.consoleStatus(now: now), .externalApp)
        XCTAssertEqual(m.consoleDevice, "ALT-1")
        XCTAssertFalse(runner.operations.contains("installUpdate"), "手机上已有别的工具装的 S2Arm：不装第二个（不新建证书）")
    }

    func testIntroStartInstallsWhenProbeFindsNothing() async throws {
        let runner = ConsoleRunner(probePhones: [])
        let m = try makeModel(runner)
        m.consoleIntroStart(language: "zh-Hans")
        for _ in 0..<300 where !runner.operations.contains("installUpdate") { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.overviewProbes.first, true, "先现查")
        XCTAssertEqual(runner.overviewProbes.filter { $0 }.count, 1, "只现查一次（装完那次照旧不带 probe 地重读）")
        XCTAssertEqual(runner.operations.filter { $0 == "phoneOverview" || $0 == "installUpdate" }.prefix(2), ["phoneOverview", "installUpdate"],
                       "什么都没装：现查完才接着原来的装机")
    }

    func testExternalButtonsDispatch() async throws {
        let runner = ConsoleRunner()
        let m = try makeModel(runner)
        m.refresh()
        for _ in 0..<300 where m.games.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        m.phoneOverview = PhoneOverview(phones: [externalPhone()])
        XCTAssertEqual(m.runConsoleAction(.pushS2arm, device: "ALT-1", language: "zh-Hans"), "没选游戏", "没勾就不发")
        m.consoleSelection = ["0100B", "0100A"]
        XCTAssertNil(m.runConsoleAction(.pushS2arm, device: "ALT-1", language: "zh-Hans"))
        for _ in 0..<300 where runner.pushes.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.pushes.first?["gameIds"] as? [String], ["0100A", "0100B"], "推游戏 = 同一单 pushSelected、按游戏库顺序")
        XCTAssertEqual(runner.pushes.first?["device"] as? String, "ALT-1")
        for _ in 0..<300 where m.phoneBusy { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(m.runConsoleAction(.exportShellIpa, device: "ALT-1", language: "zh-Hans"))
        for _ in 0..<300 where runner.updates.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.updates.first?["mode"] as? String, "export", "导出 S2Arm.ipa = installUpdate + mode export（作业 export_shell_ipa）")
        XCTAssertNil(runner.updates.first?["device"], "导出不连手机、不带设备")
    }

    // ---- 同一台 iPhone 上装着不止一个 S2Arm：玩家选、选一次记住（作业契约 host_update.phone_overview needsChoice / candidates、作业 phoneChooseApp）。期望手写 ----
    private let launcherBid = "io.s2arm.games.example02"
    private var twoCandidates: [[String: Any]] {
        [["bundleId": alt, "team": "TEAMALT", "byThisLauncher": false, "identityTeam": "TEAMALT"],
         ["bundleId": launcherBid, "team": "TEAMOWN", "byThisLauncher": true, "identityTeam": NSNull()]]
    }
    private var choosePhoneRow: [String: Any] {
        ["device": "DUO-1", "name": "我的手机", "installed": true, "bundleId": "", "shellCurrent": NSNull(), "signMode": NSNull(), "online": "usb",
         "needsChoice": true, "actions": ["chooseApp"], "candidates": twoCandidates, "games": [[String: Any]]()]
    }

    func testParseNeedsChoiceAndCandidates() {
        let o = PhoneOverview(result: ["phones": [choosePhoneRow,
            ["device": "P1", "installed": true, "installedBy": "launcher", "bundleId": launcherBid, "candidates": twoCandidates],
            ["device": "OLD", "installed": true],
            ["device": "BAD", "candidates": [["team": "TEAMALT"], ["bundleId": "", "team": "X"]]]]])
        let ps = o?.phones ?? []
        XCTAssertEqual(ps.map(\.needsChoice), [true, false, false, false], "没带 needsChoice = 不用选")
        XCTAssertEqual(ps[0].candidates, [.init(bundleId: alt, team: "TEAMALT", byThisLauncher: false, identityTeam: "TEAMALT"),
                                          .init(bundleId: launcherBid, team: "TEAMOWN", byThisLauncher: true, identityTeam: nil)], "按作业给的顺序；identityTeam = null → nil")
        XCTAssertEqual(ps[0].bundleId, ""); XCTAssertTrue(ps[0].installed); XCTAssertNil(ps[0].installedBy)
        XCTAssertEqual(ps[1].candidates.count, 2, "选过了也带候选")
        XCTAssertEqual(ps[2].candidates, [], "没带 candidates = 空")
        XCTAssertEqual(ps[3].candidates, [], "没有包名的候选丢掉")
    }

    func testCandidateLabels() {
        typealias C = PhoneOverview.Candidate
        let keys = S2ArmLauncherModel.candidateLabelKeys
        XCTAssertEqual(keys(C(bundleId: alt, team: "TEAMALT", byThisLauncher: false, identityTeam: nil)), ["console.choose.byOther"])
        XCTAssertEqual(keys(C(bundleId: alt, team: "TEAMALT", byThisLauncher: false, identityTeam: "TEAMALT")), ["console.choose.byOther", "console.choose.certImported"],
                       "导入的证书团队与 App 团队对得上：追加「已导入签名证书」")
        XCTAssertEqual(keys(C(bundleId: alt, team: "TEAMALT", byThisLauncher: false, identityTeam: "TEAMOTHER")), ["console.choose.byOther"], "团队对不上不算")
        XCTAssertEqual(keys(C(bundleId: alt, team: "", byThisLauncher: false, identityTeam: nil)), ["console.choose.byOther"], "团队空、没导入不算")
        XCTAssertEqual(keys(C(bundleId: launcherBid, team: "TEAMOWN", byThisLauncher: true, identityTeam: nil)), ["console.choose.byLauncher"])
        XCTAssertEqual(BackendText.launcherText("console.choose.byLauncher", language: "zh-Hans"), "这台电脑的启动器装的")
        XCTAssertEqual(BackendText.launcherText("console.choose.byOther", language: "zh-Hans"), "别的工具装的（AltStore / SideStore 等）")
        XCTAssertEqual(BackendText.launcherText("console.choose.certImported", language: "zh-Hans"), "已导入签名证书")
    }

    func testNeedsChoiceOnlyChooseAndChosenGetsChange() throws {
        let m = try makeModel()
        let o = PhoneOverview(result: ["phones": [choosePhoneRow]])!
        m.phoneOverview = o
        XCTAssertEqual(m.consoleStatus(now: now), .chooseApp, "要选时状态行写装着不止一个")
        XCTAssertEqual(m.consoleActions(m.consolePhone!), [.chooseApp], "只出「选用哪个 S2Arm」，不出安装 / 更新 S2Arm")
        let row = S2ArmControl.phoneConsole(o, model: m).first ?? [:]
        XCTAssertEqual(row["needsChoice"] as? Bool, true)
        XCTAssertEqual(row["actions"] as? [String], ["chooseApp"])
        XCTAssertTrue((row["installed"] as? [String: Any])?["bundleId"] is NSNull, "没选时当前包名 = null")
        let cands = row["candidates"] as? [[String: Any]] ?? []
        XCTAssertEqual(cands.map { $0["bundleId"] as? String }, [alt, launcherBid])
        XCTAssertEqual(cands.map { $0["byThisLauncher"] as? Bool }, [false, true]); XCTAssertTrue(cands.last?["identityTeam"] is NSNull)
        // 选过了：启动器装的那个照旧三颗 + 末尾「换一个」；别的工具装的照旧四颗 + 「换一个」
        let chosen = PhoneOverview(result: ["phones": [["device": "DUO-1", "installed": true, "installedBy": "launcher", "bundleId": launcherBid, "shellCurrent": true,
                                                        "online": "usb", "candidates": twoCandidates]]])!
        m.phoneOverview = chosen
        XCTAssertEqual(m.consoleActions(m.consolePhone!), [.renewShell, .handOverIdentity, .updateSelected, .chooseApp])
        let c = S2ArmControl.phoneConsole(chosen, model: m).first ?? [:]
        XCTAssertEqual((c["installed"] as? [String: Any])?["bundleId"] as? String, launcherBid, "选中的就是 installed.bundleId")
        XCTAssertEqual(c["needsChoice"] as? Bool, false)
        m.phoneOverview = PhoneOverview(phones: [externalPhone()])
        XCTAssertEqual(m.consoleActions(m.consolePhone!), externalFour, "只装着一个：没有「换一个」")
    }

    func testChooseAppRunsJobThenReprobesThisPhone() async throws {
        let runner = ConsoleRunner(probePhones: [choosePhoneRow])
        let m = try makeModel(runner)
        m.phoneOverview = PhoneOverview(result: ["phones": [choosePhoneRow]])
        XCTAssertNotNil(m.runConsoleAction(.chooseApp, device: "DUO-1", bundleId: "io.s2arm.games.example09", language: "zh-Hans"), "不在候选里的不发")
        XCTAssertNotNil(m.runConsoleAction(.chooseApp, device: "DUO-1", language: "zh-Hans"), "没给包名不发")
        XCTAssertNil(m.runConsoleAction(.chooseApp, device: "DUO-1", bundleId: alt, language: "zh-Hans"))
        for _ in 0..<300 where runner.chooses.isEmpty || m.consoleChoosing != nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.chooses.count, 1, "一次选择一单作业")
        XCTAssertEqual(runner.chooses.first?["device"] as? String, "DUO-1"); XCTAssertEqual(runner.chooses.first?["bundleId"] as? String, alt)
        for _ in 0..<300 where runner.overviewProbes.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.overviewProbes, [true], "选完重新现查总览")
        XCTAssertNil(m.consoleChooseError)
        m.consoleDevice = "DUO-1"
        await m.loadPhoneOverview(probe: true)
        XCTAssertEqual(runner.overviewDevices.last ?? nil, "DUO-1", "现查带上总控台这台")
    }

    func testChoiceFactsParse() {
        let facts = PhoneOverview.choiceFacts([["code": "phone_app_choice_required", "severity": "error", "facts": ["device": "DUO-1", "candidates": twoCandidates]]])
        XCTAssertEqual(facts?.device, "DUO-1")
        XCTAssertEqual(facts?.candidates, [.init(bundleId: alt, team: "TEAMALT", byThisLauncher: false, identityTeam: "TEAMALT"),
                                           .init(bundleId: launcherBid, team: "TEAMOWN", byThisLauncher: true, identityTeam: nil)])
        XCTAssertNil(PhoneOverview.choiceFacts([["code": "device_not_ready", "facts": ["device": "DUO-1", "candidates": twoCandidates]]]), "别的码不算")
        XCTAssertNil(PhoneOverview.choiceFacts([["code": "phone_app_choice_required"]]), "没带事实")
        XCTAssertNil(PhoneOverview.choiceFacts([["code": "phone_app_choice_required", "facts": ["device": "DUO-1", "candidates": [[String: Any]]()]]]), "没有候选")
    }

    /// 推送停在「装着不止一个 S2Arm、还没选」：失败页就地列候选（pushChoice），点一个跑 phoneChooseApp，成了自动重推同一台、同样的游戏
    func testPushSelectedChoiceFailureChooseThenRetries() async throws {
        let runner = ConsoleRunner(probePhones: [choosePhoneRow])
        runner.choiceFailures = 1
        runner.choiceCandidates = twoCandidates
        let m = try makeModel(runner)
        m.updateSelected(ids: ["0100B", "0100A"], device: "DUO-1")
        for _ in 0..<300 where m.pushChoice == nil || m.phoneBusy { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.pushes.count, 1)
        XCTAssertEqual(m.phoneSession?.failureCode, "phone_app_choice_required")
        XCTAssertEqual(m.pushChoice?.device, "DUO-1")
        XCTAssertEqual(m.pushChoice?.candidates.map(\.bundleId), [alt, launcherBid], "候选来自失败事实")
        m.chooseApp(device: "DUO-1", bundleId: alt)
        for _ in 0..<300 where runner.pushes.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.chooses.first?["bundleId"] as? String, alt)
        XCTAssertEqual(runner.pushes.count, 2, "选好自动重推")
        XCTAssertEqual(runner.pushes.last?["gameIds"] as? [String], ["0100B", "0100A"], "同样的游戏")
        XCTAssertEqual(runner.pushes.last?["device"] as? String, "DUO-1", "同一台")
        XCTAssertNil(m.pushChoice, "用掉了")
    }
}

/// 假作业进程：记下 install / pushSelected 请求；holdPush 时 pushSelected 挂着直到取消，其余作业照常成功
private final class ConsoleRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    final class Held: JobProcessHandle {
        var onTerminate: (() -> Void)?
        func terminate() { onTerminate?(); onTerminate = nil }
    }
    var installs: [[String: Any]] = []
    var pushes: [[String: Any]] = []
    var updates: [[String: Any]] = []
    var operations: [String] = []
    var overviewProbes: [Bool] = []
    var overviewDevices: [String?] = []
    var chooses: [[String: Any]] = []
    /// 前几单 pushSelected 按「装着不止一个 S2Arm、还没选」失败（诊断带 facts {device, candidates}，同 install.owner_for_push）
    var choiceFailures = 0
    var choiceCandidates: [[String: Any]] = []
    let holdPush: Bool
    /// 给了：phoneOverview 按这份回（介绍卡测试用）；没给：照旧一台 D9
    let probePhones: [[String: Any]]?
    init(holdPush: Bool = false, probePhones: [[String: Any]]? = nil) { self.holdPush = holdPush; self.probePhones = probePhones }
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        objc_sync_enter(self); defer { objc_sync_exit(self) }   // 作业客户端在并发线程池里同时调 start：替身状态串行改（无锁并发追加数组会 SIGSEGV 带崩整个测试进程）
        var taskId = ""; var request: [String: Any] = [:]
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { request = r; taskId = r["taskId"] as? String ?? "" }
        let result: [String: Any] = switch request["operation"] as? String ?? "" {
        case "catalog": ["games": ["0100A", "0100B", "0100C"].map { ["id": $0, "name": $0, "ready": true, "missing": [String]()] }]
        case "phoneOverview" where probePhones != nil: ["phones": probePhones!]
        case "phoneOverview": ["phones": [["device": "D9", "name": "测试手机", "installed": true, "shellCurrent": true, "games": [[String: Any]]()]]]
        default: [:]
        }
        let event: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": "succeeded", "result": result, "message": ""]
        let finish = { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(0) }
        if request["operation"] as? String == "install" { installs.append(request) }
        if request["operation"] as? String == "installUpdate" { updates.append(request) }
        if request["operation"] as? String == "phoneOverview" { overviewProbes.append(request["probe"] as? Bool == true); overviewDevices.append(request["device"] as? String) }
        if request["operation"] as? String == "phoneChooseApp" { chooses.append(request) }
        operations.append(request["operation"] as? String ?? "")
        if request["operation"] as? String == "pushSelected" {
            pushes.append(request)
            if choiceFailures > 0 {
                choiceFailures -= 1
                let ev: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": "failed", "result": [:], "message": "这台 iPhone 上装着不止一个 S2Arm",
                                         "diagnostics": [["code": "phone_app_choice_required", "severity": "error",
                                                          "facts": ["device": request["device"] as? String ?? "", "candidates": choiceCandidates]]]]
                DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: ev)); onExit(1) }
                return Handle()
            }
            if holdPush {   // 挂着直到取消（SIGTERM）：作业层以取消收尾、退出码 130
                let h = Held()
                h.onTerminate = { DispatchQueue.main.async {
                    let ev: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": "cancelled", "result": [:], "message": ""]
                    onLine(try! JSONSerialization.data(withJSONObject: ev)); onExit(130) } }
                return h
            }
        }
        DispatchQueue.main.async(execute: finish)
        return Handle()
    }
}
