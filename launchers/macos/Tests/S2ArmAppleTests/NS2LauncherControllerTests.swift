import XCTest
import AppKit
import Darwin
import GameController
import CoreBluetooth
import LauncherPadBridge
@testable import NX2AppleUI

// 手柄弹窗标题照连接程序报的型号写（#520）。期望按 ns2_kind 数值手写：1 Pro、2 Joy-Con 左、3 右、4 左右一对；
//   没连 / 旧连接程序没报 kind 时写「Joy-Con 2 · Pro 2」（中英同）
final class NS2LauncherControllerTests: XCTestCase {
    @MainActor
    func testSystemControllerConnectionNotification() async {
        let notifications = NotificationCenter()
        let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"),
                                              systemControllers: { [] }, notifications: notifications)
        let pad = NamedSystemController("DualSense Wireless Controller (test)")
        notifications.post(name: .GCControllerDidConnect, object: pad)
        // 连接通知从主队列交给模型；不接管手柄的输入回调。
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(controller.title(lang: "zh"), "DualSense Wireless Controller (test)")
        XCTAssertEqual(controller.buttonStatus, "已连接")
        XCTAssertEqual(controller.buttonColor, .systemGreen)
        XCTAssertFalse(controller.detail.contains("SYNC"))
        notifications.post(name: .GCControllerDidDisconnect, object: pad)
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(controller.hasSystemController)
        XCTAssertEqual(controller.buttonStatus, "未连接")
    }

    @MainActor
    func testAlreadyConnectedSystemControllerNeedsNoSwitchHelper() {
        let pad = NamedSystemController("DualSense Wireless Controller")
        var inputs = 0
        pad.extendedGamepad?.valueChangedHandler = { _, _ in inputs += 1 }
        let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"),
                                              systemControllers: { [pad] }, notifications: NotificationCenter())
        controller.startIfEnabled()
        XCTAssertEqual(controller.title(lang: "zh"), "DualSense Wireless Controller")
        XCTAssertEqual(controller.buttonStatus, "已连接")
        controller.gameDidStart()
        controller.gameDidExit()
        XCTAssertEqual(controller.buttonStatus, "已连接", "关闭游戏不能把系统仍连接的手柄显示成断开")
        let gamepad = pad.extendedGamepad!
        gamepad.valueChangedHandler?(gamepad, gamepad.buttonA)
        XCTAssertEqual(inputs, 1, "状态观察不能接管游戏的输入回调")
    }

    @MainActor
    func testDisconnectExcludesStaleSnapshotAndKeepsOtherController() async {
        let dualSense = NamedSystemController("DualSense Wireless Controller")
        let xbox = NamedSystemController("Xbox Wireless Controller")
        var connected: [GCController] = [dualSense, xbox]
        let notifications = NotificationCenter()
        let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"),
                                              systemControllers: { connected }, notifications: notifications)
        XCTAssertEqual(controller.title(lang: "en"), "DualSense Wireless Controller")
        notifications.post(name: .GCControllerDidDisconnect, object: dualSense)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(controller.title(lang: "en"), "Xbox Wireless Controller")
        XCTAssertEqual(controller.buttonStatus, "已连接")
        connected = [xbox] // 枚举仍包含本次断开的设备，不能靠快照假定它还连着。
        notifications.post(name: .GCControllerDidDisconnect, object: xbox)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(controller.buttonStatus, "未连接")
        connected = [dualSense]
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(controller.title(lang: "en"), "DualSense Wireless Controller")
    }

    @MainActor
    func testSystemControllerDoesNotTakeOverSwitch2Title() {
        // 回归：系统蓝牙手柄连着时，Switch 2 区块标题仍是 Switch 2 自己的（面板另有蓝牙区块），不写系统手柄名（DualSense 出现两次）；
        //   顶栏照两条通道合并：已连接、绿点、提示写蓝牙手柄名
        let pad = NamedSystemController("DualSense Wireless Controller")
        let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"),
                                              systemControllers: { [pad] }, notifications: NotificationCenter())
        XCTAssertTrue(controller.hasSystemController)
        XCTAssertNotEqual(controller.switch2Title(lang: "en"), "DualSense Wireless Controller")
        XCTAssertEqual(controller.switch2Title(lang: "en"), NS2LauncherController.title(kind: 0, lang: "en"))
        XCTAssertEqual(controller.status, .notConnected, "Switch 2 区块照自己的状态")
        XCTAssertFalse(controller.detail.contains("DualSense"))
        XCTAssertEqual(controller.title(lang: "en"), "DualSense Wireless Controller")
        XCTAssertEqual(controller.buttonStatus, "已连接")
        XCTAssertEqual(controller.buttonColor, .systemGreen)
    }

    @MainActor
    func testBluetoothDeniedTurnsReconnectIntoAllow() {
        // 玩家选过「不允许」：系统不会再弹授权框，主按钮改「允许蓝牙」（去隐私设置页），状态写清是权限没开；蓝牙关着时照旧「重新连接」
        var auth = CBManagerAuthorization.denied
        let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"),
                                              systemControllers: { [] }, notifications: NotificationCenter(), bluetoothAuthorization: { auth })
        controller.apply(status: 6, ["status": 6])
        XCTAssertEqual(controller.status, .bluetoothUnavailable)
        XCTAssertTrue(controller.bluetoothDenied)
        XCTAssertEqual(NS2LauncherController.mainButton(controller.status, lang: "en", bluetoothDenied: controller.bluetoothDenied), "Allow Bluetooth")
        XCTAssertEqual(NS2LauncherController.statusText(controller.status, lang: "zh", bluetoothDenied: controller.bluetoothDenied), "蓝牙权限未允许")
        auth = .allowedAlways
        XCTAssertFalse(controller.bluetoothDenied)
        XCTAssertEqual(NS2LauncherController.mainButton(controller.status, lang: "zh", bluetoothDenied: controller.bluetoothDenied), "重新连接")
        XCTAssertEqual(NS2LauncherController.mainButton(.failed, lang: "zh", bluetoothDenied: true), "重新连接", "只有蓝牙不可用才改")
    }

    @MainActor
    func testHelperUnauthorizedStateCountsAsDenied() {
        // 本进程读到的授权不一定是 denied（权限记在谁名下由系统定）；连接程序报 state 3（unauthorized）也算没允许
        let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"),
                                              systemControllers: { [] }, notifications: NotificationCenter(), bluetoothAuthorization: { .allowedAlways })
        controller.apply(status: 6, ["status": 6, "message": "Bluetooth unavailable (state 3). Check Bluetooth power and permission."])
        XCTAssertTrue(controller.bluetoothDenied)
        XCTAssertEqual(NS2LauncherController.mainButton(controller.status, lang: "en", bluetoothDenied: controller.bluetoothDenied), "Allow Bluetooth")
        controller.apply(status: 6, ["status": 6, "message": "Bluetooth unavailable (state 4). Check Bluetooth power and permission."])
        XCTAssertFalse(controller.bluetoothDenied, "state 4 = 蓝牙关着：照旧重新连接")
        XCTAssertFalse(NS2LauncherController.reportedUnauthorized(nil))
    }

    @MainActor
    func testAutoConnectWaitsForPanelWhenPermissionNotAsked() {
        // 还没问过蓝牙权限：开着自动连接也不在启动 S2Arm 时起连接程序（会弹系统授权框），等打开手柄面板再问
        let suite = "s2arm-perm-test-" + UUID().uuidString
        let store = UserDefaults(suiteName: suite)!
        store.set(true, forKey: "S2AMacNS2AutoConnectOnOpen")
        let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"), store: store,
                                              orderFile: FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json"),
                                              systemControllers: { [] }, notifications: NotificationCenter(), bluetoothAuthorization: { .notDetermined })
        controller.startIfEnabled()
        XCTAssertFalse(controller.hasConnectionProcess, "启动时不起连接程序")
        XCTAssertEqual(controller.status, .notConnected)
    }

    @MainActor
    func testPermissionAnswerUpdatesPanel() {
        // 授权框按「不允许」：面板马上变「蓝牙权限未允许 / 允许蓝牙」；已被拒时打开面板也直接是这样
        var auth = CBManagerAuthorization.denied
        let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"),
                                              systemControllers: { [] }, notifications: NotificationCenter(), bluetoothAuthorization: { auth })
        controller.bluetoothPermissionAnswered()
        XCTAssertFalse(controller.requestingBluetoothPermission)
        XCTAssertEqual(controller.status, .bluetoothUnavailable)
        XCTAssertEqual(NS2LauncherController.mainButton(controller.status, lang: "en", bluetoothDenied: controller.bluetoothDenied), "Allow Bluetooth")
        let fresh = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"),
                                         systemControllers: { [] }, notifications: NotificationCenter(), bluetoothAuthorization: { auth })
        fresh.panelDidOpen()
        XCTAssertEqual(fresh.status, .bluetoothUnavailable, "已被拒：打开面板直接显示允许蓝牙")
        auth = .notDetermined
        let asking = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"),
                                          systemControllers: { [] }, notifications: NotificationCenter(), bluetoothAuthorization: { auth })
        asking.bluetoothPermissionAnswered()   // 授权框没选就关了：本次当不允许，「允许蓝牙」再问一次（不去设置页）
        XCTAssertTrue(asking.permissionDismissedThisSession)
        XCTAssertEqual(asking.status, .bluetoothUnavailable)
        XCTAssertEqual(NS2LauncherController.mainButton(asking.status, lang: "en", bluetoothDenied: asking.bluetoothDenied), "Allow Bluetooth")
        let relaunch = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"),
                                            systemControllers: { [] }, notifications: NotificationCenter(), bluetoothAuthorization: { auth })
        XCTAssertFalse(relaunch.bluetoothDenied, "下次打开 S2Arm 不当成拒绝")
        relaunch.panelDidOpen()
        XCTAssertEqual(relaunch.status, .notConnected)
    }

    @MainActor
    func testScanWindowEndShowsNotConnectedNotError() {
        // 扫 10 秒没找到（状态 9）、或直连记住的手柄过了扫描窗口还没连上：灰点「未连接」+「连接」，红点只给真的出错（状态 5 断开等）
        let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"),
                                              systemControllers: { [] }, notifications: NotificationCenter())
        controller.apply(status: 1, ["status": 1])
        controller.apply(status: 9, ["status": 9])
        XCTAssertEqual(controller.status, .notConnected)
        XCTAssertEqual(controller.buttonColor, NS2LauncherController.dotColor(.notConnected))
        XCTAssertEqual(NS2LauncherController.mainButton(controller.status, lang: "en"), "Connect")
        controller.apply(status: 2, ["status": 2])
        XCTAssertEqual(controller.status, .connecting, "新一轮连接中照常橙点")
        controller.connectingWindowEnded()
        XCTAssertEqual(controller.status, .notConnected, "过了扫描窗口还在等记住的手柄：灰点")
        controller.apply(status: 4, ["status": 4, "kind": 1])
        XCTAssertEqual(controller.status, .connected, "按了手柄连上：照常已连接")
        controller.apply(status: 5, ["status": 5])
        XCTAssertEqual(controller.status, .failed, "真的断开 / 出错仍是红点")
    }

    @MainActor
    func testSyncHintWhenJoyConWakesAnotherHost() {
        // #2318：连接程序扫到唤醒别的主机的 Joy-Con 2、没去连，状态行带 syncHint → 搜索中 / 扫完都提示长按导轨侧 SYNC 再连；不带就是原来的文案
        let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"),
                                              systemControllers: { [] }, notifications: NotificationCenter())
        controller.apply(status: 1, ["status": 1])
        XCTAssertFalse(controller.detail.contains("滑轨"), "反证：没带 syncHint 照旧")
        controller.apply(status: 1, ["status": 1, "syncHint": true])
        XCTAssertTrue(controller.detail.contains("SL / SR 之间的小 SYNC") && controller.detail.contains("再点「连接」"))
        controller.apply(status: 9, ["status": 9, "syncHint": true])
        XCTAssertEqual(controller.detail, NS2LauncherController.syncHintDetail, "扫完没连上：提示留着")
        XCTAssertEqual(controller.status, .notConnected, "不是出错：灰点")
        controller.apply(status: 9, ["status": 9])
        XCTAssertFalse(controller.detail.contains("滑轨"), "反证：下一轮没带就换回原文案")
        // #2318 真因是 Switch 2 主机开着把手柄抢回去：没找到 / 唤醒别的主机 / 断开 三处都提示先关主机或拿远
        XCTAssertTrue(controller.detail.contains("先彻底关机或拿远"), "没找到")
        controller.apply(status: 9, ["status": 9, "syncHint": true])
        XCTAssertTrue(controller.detail.contains("先彻底关机或拿远"), "唤醒别的主机")
        controller.apply(status: 5, ["status": 5])
        XCTAssertTrue(controller.detail.contains("先彻底关机或拿远"), "断开 / 没连上")
    }

    @MainActor
    func testHelperPlainLinesGoToLogFile() throws {
        // #2318 / D-6338：连接程序不是 JSON 的行（[NS2Transport] 扫到广播、BLE 超时…）写进 <私有目录>/logs/ns2-connection.log；JSON 状态行不写
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-ns2-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = NS2HelperLog(socketURL: dir.appendingPathComponent("ns2-relay.sock"))
        XCTAssertEqual(log.url.path, dir.appendingPathComponent("logs/ns2-connection.log").path, "和 Xbox 中继日志同一个 logs/（诊断导出收这里的 .log）")
        let helper = NS2SecondHelper(executable: URL(fileURLWithPath: "/usr/bin/true"), upstream: dir.appendingPathComponent("side.sock"), rememberDevice: true, group: 2, log: log)
        helper.consume(Data("[NS2Transport] NS2 扫到手柄广播 id=X kind=3 RSSI=-50 accepts=1 wake=唤醒其他主机\n{\"status\":1,\"message\":\"\"}\n[NS2Transport] 半行".utf8))
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertTrue(text.contains("[组 3] [NS2Transport] NS2 扫到手柄广播 id=X kind=3 RSSI=-50 accepts=1 wake=唤醒其他主机\n"), text)
        XCTAssertFalse(text.contains("\"status\""), "反证：JSON 状态行不进日志")
        XCTAssertFalse(text.contains("半行"), "没收到换行的半行等下一块再写")
        helper.consume(Data("后半\n".utf8))
        XCTAssertTrue(try String(contentsOf: log.url, encoding: .utf8).contains("[NS2Transport] 半行后半\n"))
        // 超过上限从头重写：不无限长
        try Data(count: NS2HelperLog.maxBytes + 1).write(to: log.url)
        log.append([Data("重写后第一行".utf8)], group: 0)
        let after = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertTrue(after.hasSuffix("[组 1] 重写后第一行\n") && after.utf8.count < 200, "超上限重写（实长 \(after.utf8.count)）")
    }

    @MainActor
    func testPressFlashesThatPlayerRow() {
        // 认手柄：连接程序报某只按了键（{"press": {"id"}}）→ 那位玩家那一行亮；一对 Joy-Con 任一只都算那一位；认不出的 id 不亮
        let suite = "s2arm-press-test-" + UUID().uuidString
        let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"), store: UserDefaults(suiteName: suite),
                                              orderFile: FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json"),
                                              systemControllers: { [] }, notifications: NotificationCenter())
        controller.apply(status: 4, ["status": 4, "kind": 1, "players": 1, "kinds": [1], "devices": [["kind": 1, "id": "PRO"]]])
        controller.updateSystem([PlayerAssignment.SystemKey(name: "DualSense", index: 0)])
        let units = controller.assignment.units
        XCTAssertEqual(units.count, 2)
        let pro = units.firstIndex(of: .whole(id: "PRO", kind: 1))!
        controller.receivePress(["link": 0, "id": "PRO", "buttons": 1 << 9, "side": 0])
        XCTAssertEqual(controller.flashingPlayers, [pro])
        XCTAssertEqual(controller.flashingKeys[pro], "ZR", "按键位 9 = ZR")
        controller.flashPlayer { $0 == .system(name: "DualSense", index: 0) }
        XCTAssertEqual(controller.flashingPlayers.count, 2)
        controller.receivePress(["link": 0, "id": "NOPE"])
        XCTAssertEqual(controller.flashingPlayers.count, 2, "认不出的不亮")
        let exp = expectation(description: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertTrue(controller.flashingPlayers.isEmpty, "0.6 秒后熄")
    }

    func testGen1ButtonsFromReport() {
        // 一代 Joy-Con 报告里按着的键：全报告 0x30 第 3–5 字节；简单报告 0x3F 第 1–2 字节 + 方向（8 = 没按）
        var full = [UInt8](repeating: 0, count: 49); full[0] = 0x30
        XCTAssertEqual(Gen1HIDWatcher.buttons(report: full), 0)
        full[3] = 0x08
        XCTAssertNotEqual(Gen1HIDWatcher.buttons(report: full), 0)
        XCTAssertEqual(Gen1HIDWatcher.buttons(report: [0x3f, 0, 0, 8]), 0)
        XCTAssertNotEqual(Gen1HIDWatcher.buttons(report: [0x3f, 0, 0, 2]), 0, "方向键")
        XCTAssertNotEqual(Gen1HIDWatcher.buttons(report: [0x3f, 0x01, 0, 8]), 0)
        // 显示的字：全报告右只 A（第 3 字节 0x08）、左只 ZL（第 5 字节 0x80）；简单报告右只第 1 字节 0x01 = A、左只 = ←
        full[3] = 0x08
        XCTAssertEqual(Gen1HIDWatcher.keyName(Gen1HIDWatcher.buttons(report: full), side: 1), "A")
        var left = [UInt8](repeating: 0, count: 49); left[0] = 0x30; left[5] = 0x80
        XCTAssertEqual(Gen1HIDWatcher.keyName(Gen1HIDWatcher.buttons(report: left), side: 0), "ZL")
        XCTAssertEqual(Gen1HIDWatcher.keyName(Gen1HIDWatcher.buttons(report: [0x3f, 0x01, 0, 8]), side: 1), "A")
        XCTAssertEqual(Gen1HIDWatcher.keyName(Gen1HIDWatcher.buttons(report: [0x3f, 0x01, 0, 8]), side: 0), NS2LauncherController.keyLeft)
        XCTAssertEqual(Gen1HIDWatcher.keyName(Gen1HIDWatcher.buttons(report: [0x3f, 0, 0, 0]), side: 0), NS2LauncherController.keyUp, "摇杆往上推")
        XCTAssertEqual(NS2LauncherController.ns2Key(buttons: 0, side: 4), "SL")
        XCTAssertEqual(NS2LauncherController.ns2Key(buttons: 1 << 16, side: 0), "Home")
        XCTAssertEqual(NS2LauncherController.ns2Key(buttons: 1 << 17, side: 0), "Capture")
        XCTAssertEqual(SystemControllers.keyLabel(GCInputButtonHome, family: .playstation), "sf:logo.playstation")
        XCTAssertEqual(SystemControllers.keyLabel(GCInputButtonHome, family: .xbox), "sf:logo.xbox")
        XCTAssertEqual(SystemControllers.keyLabel(GCInputButtonOptions, family: .xbox), "View")
        XCTAssertEqual(SystemControllers.keyLabel(GCInputXboxPaddleOne, family: .xbox), "P1")
        XCTAssertEqual(SystemControllers.keyLabel(GCInputButtonA, family: .other), "B", "认不出的手柄：下面那颗照 Switch 写 B")
        XCTAssertEqual(SystemControllers.keyLabel(GCInputRightTrigger, family: .nintendoPro), "ZR")
        XCTAssertEqual(SystemControllers.keyLabel(GCInputButtonMenu, family: .other), "+")
        XCTAssertEqual(SystemControllers.keyLabel(GCInputLeftThumbstickButton, family: .xbox), "LS", "Xbox 自己没列的键：用 Switch 的")
        XCTAssertEqual(SystemControllers.keyLabel(GCInputButtonA, family: .playstation), "sf:xmark")
        XCTAssertEqual(SystemControllers.keyLabel("Direction Pad Up", family: .playstation), NS2LauncherController.keyUp, "方向键也列在 buttons 里")
        XCTAssertEqual(SystemControllers.keyLabel("Left Thumbstick.left", family: .playstation), NS2LauncherController.keyLeft, "摇杆方向")
        XCTAssertEqual(NS2LauncherController.ns2Key(buttons: 1 << 34, side: 0), NS2LauncherController.keyLeft, "Switch 2 摇杆往左")
        XCTAssertEqual(SystemControllers.keyLabel(GCInputLeftShoulder, family: .xbox), "LB")
    }

    @MainActor
    func testKeyboardRegistrationSurvivesRelaunch() throws {
        // 玩家在「分配玩家」里登记过的键盘位，重开 S2Arm 仍在（玩家自己排的优先，同 main 上整份分配持久化）
        let suite = "s2arm-kb-test-" + UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        let order = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json")
        var saved = PlayerAssignment()
        saved.keyboard()
        store.set(try JSONEncoder().encode(saved), forKey: "S2AMacNS2PlayerAssignment")
        XCTAssertEqual(saved.units, [.keyboard])
        let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"), store: store, orderFile: order,
                                              systemControllers: { [] }, notifications: NotificationCenter())
        XCTAssertEqual(controller.assignment.units, [.keyboard], "重开后键盘的登记仍在")
        let reread = try JSONDecoder().decode(PlayerAssignment.self, from: try XCTUnwrap(store.data(forKey: "S2AMacNS2PlayerAssignment")))
        XCTAssertEqual(reread.units, [.keyboard], "存档里也没被清")
    }

    func testTitleFollowsKind() {
        XCTAssertEqual(NS2LauncherController.title(kind: 2, lang: "zh"), "Joy-Con 2 (L)")
        XCTAssertEqual(NS2LauncherController.title(kind: 3, lang: "en"), "Joy-Con 2 (R)")
        XCTAssertEqual(NS2LauncherController.title(kind: 4, lang: "zh"), "Joy-Con 2 (L + R)")
        XCTAssertEqual(NS2LauncherController.title(kind: 1, lang: "zh"), "Switch 2 Pro")
        XCTAssertEqual(NS2LauncherController.title(kind: 0, lang: "zh"), "Joy-Con 2 · Pro 2")
        XCTAssertEqual(NS2LauncherController.title(kind: 0, lang: "en"), "Joy-Con 2 · Pro 2")
    }

    func testKindFromStatusLine() throws {
        let line = #"{"status":4,"message":"","name":"Joy-Con 2 (R)","identifier":"x","kind":3}"#
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(NS2LauncherController.kind(from: object), 3)
        XCTAssertEqual(NS2LauncherController.kind(from: ["status": 4]), 0, "旧连接程序没报 kind")
    }

    // 记住这台设备（#521）：开了才给连接程序 S2A_NS2_REMEMBER_DEVICE=1；关着时连继承来的同名变量也去掉（负对照），通道与偏好域照旧
    func testRememberDeviceEnvironment() {
        let on = NS2LauncherController.helperEnvironment(base: ["PATH": "/usr/bin"], socketPath: "/tmp/s.sock", rememberDevice: true)
        XCTAssertEqual(on["S2A_NS2_REMEMBER_DEVICE"], "1")
        XCTAssertEqual(on["S2A_NS2_SOCKET"], "/tmp/s.sock")
        XCTAssertEqual(on["S2A_NS2_DEFAULTS_SUITE"], "org.s2arm.macos.game")
        XCTAssertEqual(on["PATH"], "/usr/bin")
        let off = NS2LauncherController.helperEnvironment(base: ["S2A_NS2_REMEMBER_DEVICE": "1"], socketPath: "/tmp/s.sock", rememberDevice: false)
        XCTAssertNil(off["S2A_NS2_REMEMBER_DEVICE"], "关着时不能从启动器自己的环境漏给连接程序")
    }

    // 连接中的说明：开了记住这台设备时连接程序可能正挂着直连等按键唤醒，要告诉玩家按任一键；关着时同改前
    func testConnectingDetail() {
        XCTAssertTrue(NS2LauncherController.connectingDetail(rememberDevice: true).contains("任一键"))
        XCTAssertEqual(NS2LauncherController.connectingDetail(rememberDevice: false), "已找到手柄，正在连接。")
    }

    // 剃刀 M16：停连接程序不再在主线程无上限 waitUntilExit。期望按信号语义手写：
    //   ① 收到 SIGTERM 就退的子进程：terminate 回来时已退出、没动用 SIGKILL，用时远小于宽限
    //   ② 忽略 SIGTERM 的子进程（trap '' TERM）：宽限 0.5 秒到点 SIGKILL，回来时已退出，用时在 [0.5, 0.5 + 2) 秒内（改前会一直等下去）
    func testTerminateIsBounded() throws {
        func spawn(_ script: String) throws -> Process {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", script]; try p.run(); usleep(200_000); return p
        }
        let polite = try spawn("sleep 30")
        var t0 = Date()
        XCTAssertFalse(NS2LauncherController.terminate(polite, grace: 0.5), "SIGTERM 就退，不该动用 SIGKILL")
        XCTAssertFalse(polite.isRunning); XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
        let stubborn = try spawn("trap '' TERM; while :; do sleep 0.05; done")
        t0 = Date()
        XCTAssertTrue(NS2LauncherController.terminate(stubborn, grace: 0.5), "忽略 SIGTERM 的要到点 SIGKILL")
        let took = Date().timeIntervalSince(t0)
        XCTAssertFalse(stubborn.isRunning); XCTAssertGreaterThanOrEqual(took, 0.5); XCTAssertLessThan(took, 2.5)
    }

    @MainActor
    func testConnectNotificationShowsBeforeInputProfileIsReady() async {
        // #934：蓝牙手柄刚接上那一下输入描述（physicalInputProfile）可能还没就绪——连接通知是本次事件的真值，照常显示「已连接」，
        //   不等描述就绪（系统蓝牙已连上、面板却一直「未连接」）；断开通知照旧清掉
        let notifications = NotificationCenter()
        let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/s2arm-controller-test.sock"),
                                              systemControllers: { [] }, notifications: notifications)
        let pad = BareSystemController("Bare pad (test)")
        notifications.post(name: .GCControllerDidConnect, object: pad)
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(controller.hasSystemController)
        XCTAssertEqual(controller.title(lang: "zh"), "Bare pad (test)")
        XCTAssertEqual(controller.buttonStatus, "已连接")
        XCTAssertEqual(controller.buttonColor, .systemGreen)
        notifications.post(name: .GCControllerDidDisconnect, object: pad)
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(controller.hasSystemController)
        XCTAssertEqual(controller.buttonStatus, "未连接")
    }

    @MainActor
    func testSystemControllersRefreshListsNotifiedControllerBeforeProfileIsReady() {
        // #934：枚举快照还没更新时，连接通知里的那只就是真值；输入描述没就绪也照列（晚一拍补）——
        //   系统已连上的手柄不能因为快照滞后 / 描述未就绪就一直不出现
        let systems = SystemControllers(observe: false)
        let pad = BareSystemController("Bare pad (refresh)")
        systems.refresh(connected: pad)
        XCTAssertTrue(systems.pads.contains { $0.name == "Bare pad (refresh)" })
        systems.refresh(connected: nil)
        XCTAssertFalse(systems.pads.contains { $0.name == "Bare pad (refresh)" }, "通知没带上它时照枚举快照，不残留")
    }

    func testXboxGipRelaySurvivesSequentialGameHandoff() throws {
        // 启动器常驻独占 Xbox GIP：不碰真实 USB，用 server-only 模式验证切游戏（客户端 A 断开 → 客户端 B 连入）
        // 不会丢在线快照，第二局一连上立刻收到在线状态与新按键。
        let sockPath = "/tmp/s2arm-xbox-relay-test-\(getpid()).sock"
        s2a_xbox_gip_relay_stop()   // 同进程里别处起过的中继先停掉（只能有一个），否则这里的路径不会被监听
        XCTAssertEqual(s2a_xbox_gip_relay_start_ex(sockPath, 0, nil, nil), 0)
        defer { s2a_xbox_gip_relay_stop() }

        func makePacket(flags: UInt16, buttons: UInt32, lx: Int16) -> Data {
            var d = Data(count: 128)
            d.withUnsafeMutableBytes { raw in
                let p = raw.baseAddress!
                p.storeBytes(of: UInt32(0x53584258), toByteOffset: 0, as: UInt32.self)
                p.storeBytes(of: UInt16(1), toByteOffset: 4, as: UInt16.self)
                p.storeBytes(of: flags, toByteOffset: 6, as: UInt16.self)
                p.storeBytes(of: UInt8(0), toByteOffset: 8, as: UInt8.self)
                p.storeBytes(of: UInt32(0x045E), toByteOffset: 12, as: UInt32.self)
                p.storeBytes(of: UInt32(0x02D1), toByteOffset: 16, as: UInt32.self)
                p.storeBytes(of: buttons, toByteOffset: 20, as: UInt32.self)
                p.storeBytes(of: lx, toByteOffset: 24, as: Int16.self)
                let name = Array("Xbox Test".utf8)
                for (i, b) in name.enumerated() { p.storeBytes(of: b, toByteOffset: 32 + i, as: UInt8.self) }
            }
            return d
        }
        func connectClient(_ path: String) -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(fd, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                    _ = path.withCString { strncpy(dst, $0, 103) }
                }
            }
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            XCTAssertEqual(rc, 0)
            return fd
        }
        func readPacket(_ fd: Int32) -> Data {
            var buf = [UInt8](repeating: 0, count: 128)
            var got = 0
            while got < 128 {
                let n = Darwin.read(fd, &buf[got], 128 - got)
                XCTAssertGreaterThan(n, 0, "expected 128-byte relay packet")
                if n <= 0 { break }
                got += n
            }
            return Data(buf)
        }

        // 先在线挂一只手柄（模拟启动器已独占接管）
        let initial = makePacket(flags: 1, buttons: 0, lx: 0)
        XCTAssertEqual(initial.withUnsafeBytes { s2a_xbox_gip_relay_publish_for_test($0.baseAddress, $0.count) }, 1)

        // 第一局游戏连入：立刻收到在线快照 + 实时按键
        let gameA = connectClient(sockPath)
        let snapA = readPacket(gameA)
        XCTAssertEqual(snapA.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }, 1)
        let pressA = makePacket(flags: 1, buttons: 0x1, lx: 16000)
        XCTAssertEqual(pressA.withUnsafeBytes { s2a_xbox_gip_relay_publish_for_test($0.baseAddress, $0.count) }, 1)
        let recvA = readPacket(gameA)
        XCTAssertEqual(recvA.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }, 0x1)
        XCTAssertEqual(recvA.withUnsafeBytes { $0.load(fromByteOffset: 24, as: Int16.self) }, 16000)
        close(gameA)   // 第一局退出

        // 第二局游戏连入：中继未释放手柄，立刻收到在线快照 + 新的按键
        let gameB = connectClient(sockPath)
        let snapB = readPacket(gameB)
        XCTAssertEqual(snapB.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }, 1)
        let pressB = makePacket(flags: 1, buttons: 0x2, lx: -16000)
        XCTAssertEqual(pressB.withUnsafeBytes { s2a_xbox_gip_relay_publish_for_test($0.baseAddress, $0.count) }, 1)
        let recvB = readPacket(gameB)
        XCTAssertEqual(recvB.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }, 0x2)
        XCTAssertEqual(recvB.withUnsafeBytes { $0.load(fromByteOffset: 24, as: Int16.self) }, -16000)
        close(gameB)
    }

    func testXboxGipRelayWritesDiagnosticLogFile() throws {
        // 中继日志落盘：启动器 GUI 进程 stderr 不可见，设置 log_path 后必须写入带时间戳的启动记录（供诊断包与排查读取）。
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-xbox-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("xbox-gip-relay.log")
        let sockPath = "/tmp/s2arm-xbox-relay-logtest-\(getpid()).sock"
        s2a_xbox_gip_relay_set_log_path(logURL.path)
        defer { s2a_xbox_gip_relay_set_log_path(nil) }
        XCTAssertEqual(s2a_xbox_gip_relay_start_ex(sockPath, 0, nil, nil), 0)
        defer { s2a_xbox_gip_relay_stop() }
        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("[输入] Xbox GIP 中继服务已启动：\(sockPath)"), "中继启动日志必须落盘到指定文件")
    }
}

private final class BareSystemController: GCController {
    private let name: String
    init(_ name: String) { self.name = name; super.init() }
    override var vendorName: String? { name }
}

final class NamedSystemController: GCController {   // 面板截图测试（NS2PanelSnapshotTests #1151）也用
    private let name: String
    private let gamepadSnapshot = GCController.withExtendedGamepad()

    init(_ name: String) { self.name = name; super.init() }
    override var vendorName: String? { name }
    override var productCategory: String { "Fixture Controller" }
    override var extendedGamepad: GCExtendedGamepad? { gamepadSnapshot.extendedGamepad }
}
