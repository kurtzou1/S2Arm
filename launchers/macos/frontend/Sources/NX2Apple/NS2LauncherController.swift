// S2Arm（不是上游文件）：系统手柄与 Switch 2 Pro 连接状态。系统手柄由 GameController 枚举和通知更新，不接管游戏的输入回调；
//   Switch 手柄启动并监看启动器旁的 S2ArmNS2Connection 进程（独占蓝牙连接，游戏经本机通道读输入），
//   持久化「开启 S2Arm 时自动连接」「关闭游戏后自动断开」「记住这台设备」三个开关（docs/mac-switch2-pro.md）。
import AppKit
import Combine
import Foundation
import GameController

@MainActor
final class NS2LauncherController: ObservableObject {
    enum Phase: Equatable {
        case off, starting, scanning, connecting, initializing, ready, failed, handedOff
    }

    @Published private(set) var autoConnectOnOpen: Bool
    @Published private(set) var disconnectAfterGame: Bool
    /// 记住这台设备（#521）：长按 SYNC 连上的手柄写入本机地址，之后按任一键即可重连。一律开、面板不给开关（#520 UI 稿）
    @Published private(set) var rememberDevice: Bool
    @Published private(set) var phase: Phase = .off
    @Published private var helperDetail = ""
    @Published private(set) var systemControllerName: String?
    @Published private(set) var deviceName = "Switch 2 Pro"
    /// 连接程序报的对外输出型号（ns2_kind：1 Pro、2 Joy-Con 左、3 右、4 左右一对；0 = 没连 / 旧连接程序没报）
    @Published private(set) var kind = 0
    /// 连接程序报的玩家数（两只 Joy-Con 各一位玩家时 2；旧连接程序没这个字段时当 1）
    @Published private(set) var players = 1
    /// 每位玩家的型号（P1 起，同 kind 的编号；面板「玩家」列表）。旧连接程序没报时用 kind 当 P1
    @Published private(set) var playerKinds: [Int] = []
    /// 连着的 NS2 手柄有几只（一对 Joy-Con 算 2 只；连接程序报 devices，旧的没报时按型号推）
    @Published private(set) var deviceCount = 0
    nonisolated static func deviceCount(from object: [String: Any]) -> Int {
        if let devices = object["devices"] as? [Any] { return devices.count }
        switch Self.kind(from: object) { case 0: return 0; case 4: return 2; default: return 1 }
    }
    /// 分配玩家（#520 E）：开着时状态是「搜索中」（继续搜更多手柄），面板下面换成分配块
    @Published private(set) var assigning = false
    /// 玩家分配（存偏好、跨次保留；接上 / 断开手柄自动整理，PlayerAssignment.reconcile）
    @Published private(set) var assignment = PlayerAssignment()
    private var beforeAssign = PlayerAssignment()
    /// 游戏打开了系统的手柄设置画面（front_mac.m s2a_vpad_assign 写 assign-request.json）：面板要弹出来、直接进分配玩家
    @Published var panelRequested = false
    private var gameAssignToken: String?
    private var requestTimer: Timer?
    private let requestURL: URL
    /// 连着的 NS2 手柄（连接程序 devices）
    @Published private(set) var devices: [PlayerAssignment.Device] = []
    private var systemKeys: [PlayerAssignment.SystemKey] = []
    private var gen1Devices: [PlayerAssignment.Gen1Device] = []   // 按设备看到的一代 Joy-Con（D2，SystemControllers.gen1）
    /// 连接程序的 devices 加上通道玩家号：拆开时种类同 kinds[0] 的是这一组的玩家 0、另一只玩家 1；拼着 / Pro 都是玩家 0。group 1（第二个连接程序）的 +2
    nonisolated static func devices(from object: [String: Any], group: Int = 0) -> [PlayerAssignment.Device] {
        let split = players(from: object) >= 2
        let first = playerKinds(from: object).first ?? 0
        return (object["devices"] as? [[String: Any]] ?? []).compactMap { d in
            guard let id = d["id"] as? String, !id.isEmpty else { return nil }
            let kind = (d["kind"] as? NSNumber)?.intValue ?? 0
            return PlayerAssignment.Device(id: id, kind: kind, player: group * 2 + (split && kind != first ? 1 : 0), group: group)
        }
    }
    /// 两个连接程序的手柄合起来（最多 4 只）
    var allDevices: [PlayerAssignment.Device] { devices + extras.flatMap(\.devices) }
    private var playerOf: [String: Int] { Dictionary(allDevices.map { ($0.id, $0.player) }, uniquingKeysWith: { a, _ in a }) }

    /// 弹窗标题：照连着的型号写；没连 / 还不知道型号时写通用的「Switch 手柄」（不分代：一代 Joy-Con 以后也在这里）（#520）
    /// 标题：一只写型号；一对 Joy-Con 2 合成一位写「Joy-Con 2 (L + R)」；其余两只以上写「N 个 NS2 手柄」（同蓝牙手柄那块写数量，玩家在玩家列表）
    func title(simplifiedChinese zh: Bool) -> String {
        if hasSystemController, let systemControllerName { return systemControllerName }   // #901：只有系统手柄连着时写它的真实名字
        let mergedPair = kind == 4 && players == 1
        let count = max(deviceCount, 0) + extras.reduce(0) { $0 + $1.devices.count }
        if count >= 2 && !(mergedPair && count == 2) { return zh ? "\(count) 个 Switch 2 手柄" : "\(count) Switch 2 controllers" }
        return Self.title(kind: kind, simplifiedChinese: zh)
    }
    nonisolated static func players(from object: [String: Any]) -> Int { max(1, (object["players"] as? NSNumber)?.intValue ?? 1) }
    nonisolated static func playerKinds(from object: [String: Any]) -> [Int] {
        if let kinds = object["kinds"] as? [NSNumber] { return kinds.map(\.intValue).filter { $0 > 0 } }
        let kind = Self.kind(from: object)
        return kind > 0 ? [kind] : []
    }
    /// 状态行里的型号；连接程序报的是 ns2_kind 数字，旧连接程序没这个字段时当 0
    nonisolated static func kind(from object: [String: Any]) -> Int {
        (object["kind"] as? NSNumber)?.intValue ?? 0
    }
    nonisolated static func title(kind: Int, simplifiedChinese zh: Bool) -> String {
        switch kind {
        case 1: return "Switch 2 Pro"
        case 2: return "Joy-Con 2 (L)"
        case 3: return "Joy-Con 2 (R)"
        case 4: return "Joy-Con 2 (L + R)"
        default: return zh ? "Switch 手柄" : "Switch Controller"
        }
    }

    private let defaults: UserDefaults
    private let systemControllers: () -> [GCController]
    private let notifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    let socketURL: URL
    private var process: Process?
    private var output: Pipe?
    private var input: Pipe?   // 运行中改设定（两只怎么用）经 stdin 一行命令交给连接程序，不用重连
    private var buffer = Data()
    private var intentionalStop = false

    private let orderFileURL: URL
    /// defaults / orderFile 单测换成临时的（不碰本机真的分配与顺序表）
    init(socketURL: URL, store: UserDefaults? = nil, orderFile: URL = PlayerAssignment.orderFileURL, watchGame: Bool = false,
         systemControllers: @escaping () -> [GCController] = { GCController.controllers() }, notifications: NotificationCenter = .default) {
        self.socketURL = socketURL
        self.systemControllers = systemControllers
        self.notifications = notifications
        orderFileURL = orderFile
        requestURL = orderFile.deletingLastPathComponent().appendingPathComponent("assign-request.json")
        defaults = store ?? UserDefaults(suiteName: "org.s2arm.macos.game") ?? .standard
        autoConnectOnOpen = defaults.object(forKey: "S2AMacNS2AutoConnectOnOpen") as? Bool ?? false
        disconnectAfterGame = defaults.object(forKey: "S2AMacNS2DisconnectAfterGame") as? Bool ?? false
        // 记住这台设备一律开（#520 UI 稿没有这个开关）：长按 SYNC 连过一次，之后按任一键就重连。以前存过的「关」不再读
        rememberDevice = true
        if let data = defaults.data(forKey: "S2AMacNS2PlayerAssignment"), let saved = try? JSONDecoder().decode(PlayerAssignment.self, from: data) { assignment = saved }
        if watchGame {
            requestTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkGameRequest() } }
        }
        // 系统手柄（#901）：GameController 连接 / 断开 / 回前台时更新顶栏的名字和状态；不接管游戏的输入回调
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect, NSApplication.didBecomeActiveNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let connected = note.name == .GCControllerDidConnect ? note.object as? GCController : nil
                let disconnected = note.name == .GCControllerDidDisconnect ? note.object as? GCController : nil
                Task { @MainActor [weak self] in self?.refreshSystemControllers(connected: connected, disconnected: disconnected) }
            })
        }
        refreshSystemControllers()
    }
    deinit {
        for observer in observers { notifications.removeObserver(observer) }
    }

    // #901：游戏在 Switch 专用通道就绪时优先用它（front_mac.m sample_input）；其余时候顶栏照系统手柄显示「已连接」
    var hasSystemController: Bool { systemControllerName != nil && phase != .ready && phase != .handedOff }
    var detail: String {
        if hasSystemController, let systemControllerName { return "\(systemControllerName) 已通过 macOS 连接。开始游戏后会自动接收手柄输入。" }
        return helperDetail
    }
    private func refreshSystemControllers(connected: GCController? = nil, disconnected: GCController? = nil) {
        var controllers = systemControllers().filter { $0 !== disconnected }
        // 通知里的设备是本次事件的真值；枚举快照尚未更新时也要及时显示连接 / 断开
        if let connected { controllers.insert(connected, at: 0) }
        let controller = controllers.first { $0.extendedGamepad != nil || !$0.physicalInputProfile.buttons.isEmpty }
        systemControllerName = controller.map { $0.vendorName.flatMap { $0.isEmpty ? nil : $0 } ?? "Game Controller" }
    }

    /// 面板状态（#520 UI 稿「连接状态」：固定 7 种，状态行只写这几个词；细节放下面一行）
    enum Status: Equatable { case notConnected, searching, connecting, connected, inUse, failed, bluetoothUnavailable }
    var status: Status {
        if assigning { return .searching }
        switch phase {
        case .off: return .notConnected
        case .starting, .scanning: return .searching
        case .connecting, .initializing: return .connecting
        case .ready: return .connected
        case .handedOff: return .inUse
        case .failed: return bluetoothUnavailable ? .bluetoothUnavailable : .failed
        }
    }
    /// 连接程序报过蓝牙不可用（状态 6：关着 / 没给权限）；下次启动连接程序清掉
    @Published private(set) var bluetoothUnavailable = false

    nonisolated static func statusText(_ status: Status, simplifiedChinese zh: Bool) -> String {
        switch status {
        case .notConnected: return zh ? "未连接" : "Not connected"
        case .searching: return zh ? "搜索中" : "Searching"
        case .connecting: return zh ? "连接中" : "Connecting"
        case .connected: return zh ? "已连接" : "Connected"
        case .inUse: return zh ? "游戏使用中" : "In use by game"
        case .failed: return zh ? "连接失败" : "Connection failed"
        case .bluetoothUnavailable: return zh ? "蓝牙不可用" : "Bluetooth unavailable"
        }
    }
    /// 连接 / 断开合并成一个主按钮（稿）：未连接「连接」、搜索 / 连接中「停止」、连着「断开」、失败「重新连接」
    nonisolated static func mainButton(_ status: Status, simplifiedChinese zh: Bool) -> String {
        switch status {
        case .notConnected: return zh ? "连接" : "Connect"
        case .searching, .connecting: return zh ? "停止" : "Stop"
        case .connected, .inUse: return zh ? "断开" : "Disconnect"
        case .failed, .bluetoothUnavailable: return zh ? "重新连接" : "Reconnect"
        }
    }
    func mainAction() {
        switch status {
        case .notConnected: connectManually()
        case .searching, .connecting, .connected, .inUse: disconnectManually()
        case .failed, .bluetoothUnavailable: retry()
        }
    }

    /// 顶栏（#901）：只有系统手柄连着时写「已连接」、绿点；面板里 Switch 2 手柄那块仍照它自己的状态（status），连接按钮照常可用
    var buttonStatus: String { hasSystemController ? "已连接" : Self.statusText(status, simplifiedChinese: true) }
    /// 状态点颜色（稿：灰 #8a857e 未连接、橙 #f0a43a 搜索 / 连接中、绿 #5fd068 已连接 / 游戏使用中、红 #e5534b 失败 / 蓝牙不可用）
    var buttonColor: NSColor { hasSystemController ? .systemGreen : Self.dotColor(status) }
    nonisolated static func dotColor(_ status: Status) -> NSColor {
        switch status {
        case .notConnected: return NSColor(srgbRed: 0x8a / 255, green: 0x85 / 255, blue: 0x7e / 255, alpha: 1)
        case .searching, .connecting: return NSColor(srgbRed: 0xf0 / 255, green: 0xa4 / 255, blue: 0x3a / 255, alpha: 1)
        case .connected, .inUse: return NSColor(srgbRed: 0x5f / 255, green: 0xd0 / 255, blue: 0x68 / 255, alpha: 1)
        case .failed, .bluetoothUnavailable: return NSColor(srgbRed: 0xe5 / 255, green: 0x53 / 255, blue: 0x4b / 255, alpha: 1)
        }
    }

    var hasConnectionProcess: Bool { process != nil }

    func startIfEnabled() {
        // 系统手柄连着也照玩家的「开启 S2Arm 时自动连接」走：Switch 2 Pro 系统认不到，两只都在时要靠它连
        guard autoConnectOnOpen else {
            phase = .off
            helperDetail = "手柄未连接。需要时可在上方手动连接。"
            return
        }
        connectManually()
    }

    func setAutoConnectOnOpen(_ value: Bool) {
        autoConnectOnOpen = value
        defaults.set(value, forKey: "S2AMacNS2AutoConnectOnOpen")
    }

    func setDisconnectAfterGame(_ value: Bool) {
        disconnectAfterGame = value
        defaults.set(value, forKey: "S2AMacNS2DisconnectAfterGame")
    }


    /// 交给连接程序的环境变量：偏好域、通道路径、旁路 socket；开了「记住这台设备」再加 S2A_NS2_REMEMBER_DEVICE=1（macos/ns2_connection_helper.m）；
    ///   关着时连继承来的同名变量也去掉。两只 Joy-Con 拼 / 拆由分配玩家定（assign done），不经环境变量
    nonisolated static func helperEnvironment(base: [String: String], socketPath: String, rememberDevice: Bool) -> [String: String] {
        var environment = base
        environment["S2A_NS2_DEFAULTS_SUITE"] = "org.s2arm.macos.game"
        environment["S2A_NS2_SOCKET"] = socketPath
        if rememberDevice { environment["S2A_NS2_REMEMBER_DEVICE"] = "1" } else { environment.removeValue(forKey: "S2A_NS2_REMEMBER_DEVICE") }
        // 旁路 socket：第二个连接程序（第二组手柄）接到这里（与游戏通道同目录）
        environment["S2A_NS2_SIDE_SOCKET"] = URL(fileURLWithPath: socketPath).deletingLastPathComponent().appendingPathComponent("ns2-relay-2.sock").path
        environment.removeValue(forKey: "S2A_NS2_UPSTREAM")
        return environment
    }

    /// 连接中（状态 2）的说明：开了「记住这台设备」时，连接程序可能正挂着直连等绑定过的手柄按键唤醒
    nonisolated static func connectingDetail(rememberDevice: Bool) -> String {
        rememberDevice ? "正在等手柄。按手柄任一键即可连上；没反应时长按顶部 SYNC。" : "已找到手柄，正在连接。"
    }

    func connectManually() {
        guard process == nil else { return }
        startProcess()
    }

    func disconnectManually(then done: (@MainActor () -> Void)? = nil) {
        stopProcess(then: done)
        phase = .off
        helperDetail = "手柄已断开。开始游戏不受影响。"
    }

    func retry() {
        guard process != nil else { connectManually(); return }
        disconnectManually { [weak self] in self?.connectManually() }   // 旧连接程序退干净（放开蓝牙）再起新的
    }

    /// 通道路径固定，开局时手柄还没连也照样交给游戏：游戏没接上时每秒重试，玩家开局后再连手柄，游戏也会接回
    ///   （以前没连接程序就不给，游戏开着时再连手柄，游戏这边一直没反应）。连接本身始终留在 S2Arm 的连接程序内。
    func relaySocketForGame() -> String? {
        socketURL.path
    }

#if DEBUG
    /// 单测（面板截图）：直接摆到某个阶段，不起连接程序
    func setPhaseForTesting(_ value: Phase) { phase = value }
    func setAssignmentForTesting(_ value: PlayerAssignment) { assignment = value; assigning = true }
#endif

    func gameDidStart() {
        guard process != nil && phase == .ready else { return }
        phase = .handedOff
        helperDetail = "游戏正在使用 Switch 2 Pro；关闭游戏后连接会保留。"
    }

    func gameDidExit() {
        guard process != nil else {
            phase = .off
            helperDetail = "手柄未连接。需要时可在上方手动连接。"
            return
        }
        if disconnectAfterGame {
            stopProcess()
            phase = .off
            helperDetail = "游戏已关闭，已按设置断开手柄。"
        } else if phase == .handedOff {
            phase = .ready
            helperDetail = "\(deviceName) 仍保持连接，可以继续使用。"
        }
    }

    func shutdown() {
        stopProcess(wait: true)   // 启动器退出：就地等（有上限），不留没退的连接程序
    }

    private func startProcess() {
        guard let helper = helperURL else {
            phase = .failed
            helperDetail = "找不到启动器的手柄连接组件。"
            return
        }
        phase = .starting
        helperDetail = "正在启动蓝牙连接。首次使用时，请在 macOS 提示中允许。"
        deviceName = "Switch 2 Pro"
        kind = 0
        players = 1
        players = 1
        playerKinds = []
        deviceCount = 0
        bluetoothUnavailable = false
        buffer.removeAll(keepingCapacity: true)
        intentionalStop = false

        let task = Process()
        let pipe = Pipe()
        task.executableURL = helper
        task.environment = Self.helperEnvironment(base: ProcessInfo.processInfo.environment, socketPath: socketURL.path, rememberDevice: rememberDevice)
        let commands = Pipe()
        // 连接程序先退了再写也只是写失败（EPIPE），不给启动器发 SIGPIPE
        _ = fcntl(commands.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        task.standardInput = commands
        task.standardOutput = pipe
        task.standardError = pipe
        process = task
        output = pipe
        input = commands
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        task.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.process === finished else { return }
                self.process = nil
                self.extras.forEach { $0.stop() }; self.extras = []
                self.kind = 0
                self.players = 1
                self.devices = []
                self.reconcile()
                self.playerKinds = []
                self.deviceCount = 0
                self.input = nil
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.output = nil
                if !self.intentionalStop {
                    self.phase = .failed
                    self.helperDetail = "连接程序已停止，请手动重新连接。"
                }
            }
        }
        do {
            try task.run()
        } catch {
            process = nil
            output = nil
            phase = .failed
            helperDetail = error.localizedDescription
        }
    }

    /// 停连接程序（剃刀 M16）：原先主线程上 terminate 后 waitUntilExit() 不设上限，连接程序不退出时整个启动器冻住。
    ///   现在后台等（stopGrace 秒），不退就 SIGKILL；done 在确认退出后回主线程调。wait = true（启动器退出）就地等同样有上限
    private func stopProcess(wait: Bool = false, then done: (@MainActor () -> Void)? = nil) {
        intentionalStop = true
        extras.forEach { $0.stop() }; extras = []
        kind = 0
        players = 1
        devices = []
        defer { reconcile() }   // 断开：NS2 手柄让出玩家位
        players = 1
        playerKinds = []
        input = nil
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        guard let task = process else { done?(); return }
        process = nil
        task.terminationHandler = nil
        if wait { Self.terminate(task, grace: Self.stopGrace); done?(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            Self.terminate(task, grace: Self.stopGrace)
            Task { @MainActor in done?() }
        }
    }

    static let stopGrace: TimeInterval = 3
    /// SIGTERM → 最多等 grace 秒 → 还在就 SIGKILL 并收尸。回来时进程一定已退出；返回是否动用了 SIGKILL。不要在主线程调
    @discardableResult nonisolated static func terminate(_ task: Process, grace: TimeInterval) -> Bool {
        guard task.isRunning else { return false }
        task.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while task.isRunning && Date() < deadline { usleep(20_000) }
        guard task.isRunning else { return false }
        kill(task.processIdentifier, SIGKILL)
        task.waitUntilExit()
        return true
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let event = object["assign"] as? [String: Any] { receiveAssign(event); continue }
            guard let code = (object["status"] as? NSNumber)?.intValue else { continue }
            apply(status: code, object)
        }
    }

    // —— 分配玩家（#520 E）——
    /// 蓝牙手柄变了（SystemControllers.pads）
    private var systemSeen = false
    func updateSystem(_ keys: [PlayerAssignment.SystemKey]) {
        guard keys != systemKeys || !systemSeen else { return }   // 第一次（启动时）一定对一次：上次存的分配里没连着的拿掉
        systemSeen = true
        systemKeys = keys
        reconcile()
    }
    /// 一代 Joy-Con 按设备变了（连上 / 断开；几套各认各的）
    func updateGen1(_ devices: [PlayerAssignment.Gen1Device]) {
        guard devices != gen1Devices else { return }
        gen1Devices = devices
        if systemSeen { reconcile() }   // 启动时等系统手柄第一次对过再一起对
    }
    /// 照连着的手柄整理分配（新连上的排后面、断开的拿掉），变了就存、写顺序表给游戏；两只 Joy-Con 拆 / 拼跟分配对齐
    func reconcile() {
        // 分配中也照排：新连上的手柄直接排进下一个空位（#520 讨论：分配时接上手柄也自动分一个）；存偏好 / 发计划等完成时再做
        if assigning {
            var merged: Set<Int> = []
            if kind == 4 && players == 1 { merged.insert(0) }
            for extra in extras where extra.kind == 4 && extra.players == 1 { merged.insert(extra.group) }
            assignment.reconcile(devices: allDevices, mergedGroups: merged, system: systemKeys, gen1: gen1Devices)
            syncSecond()
            return
        }
        var merged: Set<Int> = []
        if kind == 4 && players == 1 { merged.insert(0) }
        for extra in extras where extra.kind == 4 && extra.players == 1 { merged.insert(extra.group) }
        if assignment.reconcile(devices: allDevices, mergedGroups: merged, system: systemKeys, gen1: gen1Devices) { persist() }
        let split = players == 2
        if !devices.isEmpty && (phase == .ready || phase == .handedOff) && assignment.wantsSplit(devices: devices) != split {
            sendPlan()   // 例：上次分配成两位单只，这次重连时传输层缺省拼成一对 → 照分配拆开
        }
        if extras.contains(where: { !$0.devices.isEmpty && assignment.wantsSplit(devices: $0.devices) != ($0.players == 2) }) { sendPlan() }
        syncSecond()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(assignment) { defaults.set(data, forKey: "S2AMacNS2PlayerAssignment") }
        Self.writeOrderFile(assignment.orderFile(playerOf: playerOf), to: orderFileURL)
    }
    private func sendPlan() {
        if let json = try? JSONSerialization.data(withJSONObject: assignment.helperPlan(devices: devices)), let text = String(data: json, encoding: .utf8) {
            send("assign done \(text)\n")
        }
        for extra in extras where !extra.devices.isEmpty {
            if let json = try? JSONSerialization.data(withJSONObject: assignment.helperPlan(devices: extra.devices)), let text = String(data: json, encoding: .utf8) {
                extra.send("assign done \(text)\n")
            }
        }
    }

    // —— 另起的连接程序（每组一只 Pro 或一套 Joy-Con，最多 8 组 = 同原机最多 8 只手柄，#520）——
    private(set) var extras: [NS2SecondHelper] = []
    static let maxGroups = 8
    private var sideSocketURL: URL { socketURL.deletingLastPathComponent().appendingPathComponent("ns2-relay-2.sock") }
    /// 第一个已有手柄起，总留一个空着在搜的（它只收别的连接程序没占、也不在等的那几台）；有手柄了再开下一个，直到 8 组；
    ///   多出来的空程序收掉；第一个停了全部跟着停
    private func syncSecond() {
        if process == nil || devices.isEmpty {
            if devices.isEmpty && process == nil { extras.forEach { $0.stop() }; extras = [] }
            return
        }
        let spare = extras.filter { $0.devices.isEmpty }
        if spare.count > 1 { for extra in spare.dropFirst() { extra.stop() }; extras.removeAll { e in spare.dropFirst().contains { $0 === e } } }
        if extras.allSatisfy({ !$0.devices.isEmpty }), extras.count + 1 < Self.maxGroups, allDevices.count < PlayerAssignment.maxPlayers, let helper = helperURL {
            let group = (1..<Self.maxGroups).first { g in !extras.contains { $0.group == g } } ?? extras.count + 1
            let extra = NS2SecondHelper(executable: helper, upstream: sideSocketURL, rememberDevice: rememberDevice, group: group)
            extra.onChange = { [weak self] in self?.reconcile() }
            extra.onAssign = { [weak self] event in self?.receiveAssign(event) }
            extras.append(extra)
            extra.start()
            if assigning { extra.send("assign start\n") }
        }
        // 别抢同一台：每个连接程序都排除别人已占的；有谁只连着单只 Joy-Con，另一侧留给组号最小的那个（别人不收那一侧）
        let groups: [(send: (String) -> Void, group: Int, devices: [PlayerAssignment.Device])] =
            [({ [weak self] in self?.send($0) }, 0, devices)] + extras.map { e in ({ e.send($0) }, e.group, e.devices) }
        let lone = groups.filter { $0.devices.count == 1 && ($0.devices[0].kind == 2 || $0.devices[0].kind == 3) }.min { $0.group < $1.group }
        for g in groups {
            let others = groups.filter { $0.group != g.group }.flatMap { $0.devices.map(\.id) }
            g.send("exclude " + others.joined(separator: " ") + "\n")
            let reserve = lone.flatMap { l in l.group == g.group ? nil : (l.devices[0].kind == 2 ? "R" : "L") } ?? "none"
            g.send("missing \(reserve)\n")
        }
    }

    /// 游戏的手柄设置画面来请求：接下（state → open），面板弹出、进分配玩家；完成 / 取消时回给游戏（state → done / cancel）
    func checkGameRequest() {
        guard let data = try? Data(contentsOf: requestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String, object["state"] as? String == "request", token != gameAssignToken else { return }
        gameAssignToken = token
        // 先照游戏要的自动拆 / 拼（同原机：手柄够、样式对就直接过，不弹面板）；不够才弹面板让玩家接手柄 / 按键
        if !assigning, let styles = (object["styles"] as? NSNumber)?.intValue {
            var fitted = assignment
            let wants = PlayerAssignment.GameWants(styles: styles, min: (object["min"] as? NSNumber)?.intValue ?? 1, max: (object["max"] as? NSNumber)?.intValue ?? 0)
            if fitted.autoFit(wants, devices: allDevices) {
                let changed = fitted.units != assignment.units
                assignment = fitted
                if changed {
                    assignment.finish(presentSystem: systemKeys, devices: allDevices, gen1: gen1Devices)
                    sendPlan()
                    persist()
                }
                gameAssignToken = nil
                writeRequest(token: token, state: "done", players: min(assignment.units.count, wants.max > 0 ? wants.max : PlayerAssignment.maxPlayers))
                return
            }
        }
        writeRequest(token: token, state: "open")
        if !assigning { startAssign() }
        panelRequested = true
        NSApp.activate(ignoringOtherApps: true)
    }
    private func answerGame(_ state: String) {
        guard let token = gameAssignToken else { return }
        gameAssignToken = nil
        writeRequest(token: token, state: state, players: assignment.units.count)
    }
    private func writeRequest(token: String, state: String, players: Int = 0) {
        let body: [String: Any] = ["token": token, "state": state, "players": players]
        if let data = try? JSONSerialization.data(withJSONObject: body) { try? data.write(to: requestURL, options: .atomic) }
    }

    /// 分配玩家：已分配的留着，新按的补进空位；取消回到按之前
    func startAssign() {
        beforeAssign = assignment
        assigning = true
        if process == nil { startProcess() }   // 没连着也能分配：先起连接程序搜手柄
        send("assign start\n")
        extras.forEach { $0.send("assign start\n") }
    }
    /// 玩家列表的 ×：分配中空出那一位；平时手柄保持连接、没有玩家位（游戏马上照新顺序表）
    func removePlayer(at index: Int) {
        assignment.remove(at: index, keepConnectedWithoutSlot: !assigning)
        guard !assigning else { return }
        persist()
        if !devices.isEmpty && assignment.wantsSplit(devices: devices) != (players == 2) { sendPlan() }
    }
    func cancelAssign() {
        guard assigning else { return }
        assigning = false
        assignment = beforeAssign
        send("assign cancel\n")
        extras.forEach { $0.send("assign cancel\n") }
        answerGame("cancel")
        reconcile()   // 分配中接上的手柄：取消后照常排进来
    }
    /// 完成：连接程序照计划拼 / 拆、断开没登记的；顺序表写给游戏（开着的游戏马上照排，没开的开局时读）
    func finishAssign() {
        guard assigning else { return }
        assigning = false
        assignment.finish(presentSystem: systemKeys, devices: allDevices, gen1: gen1Devices)
        sendPlan()
        persist()
        answerGame("done")   // 顺序表先写好，游戏再照它排
        reconcile()
    }
    func registerGen1(id: String, side: Int, gesture: Int, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard assigning else { return }
        assignment.gen1(id: id, side: side, gesture: gesture, at: time, present: gen1Devices, system: systemKeys)
    }
    func registerKeyboard() {
        guard assigning else { return }
        assignment.keyboard()
    }
    func registerSystem(name: String, index: Int, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard assigning else { return }
        assignment.system(name: name, index: index, at: time)
    }
    func receiveAssign(_ event: [String: Any], at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard assigning, let id = event["id"] as? String else { return }
        assignment.ns2(id: id, kind: (event["kind"] as? NSNumber)?.intValue ?? 0, gesture: (event["gesture"] as? NSNumber)?.intValue ?? 0, at: time)
    }
    nonisolated static func writeOrderFile(_ object: [String: Any], to url: URL = PlayerAssignment.orderFileURL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
    private func send(_ line: String) {
        if let data = line.data(using: .utf8) { try? input?.fileHandleForWriting.write(contentsOf: data) }
    }

    func apply(status code: Int, _ object: [String: Any]) {   // 单测（@testable）直接喂连接程序的状态行
        if let name = object["name"] as? String, !name.isEmpty { deviceName = name }
        kind = Self.kind(from: object)
        players = Self.players(from: object)
        playerKinds = code == 4 ? Self.playerKinds(from: object) : []
        deviceCount = code == 4 ? Self.deviceCount(from: object) : 0
        devices = code == 4 ? Self.devices(from: object) : []
        reconcile()   // 每次状态都对一次：没连着的不留玩家位
        bluetoothUnavailable = code == 6
        switch code {
        case 0:
            phase = .starting
            helperDetail = "正在启动蓝牙连接。"
        case 1:
            phase = .scanning
            helperDetail = "正在搜索手柄。请按一下手柄；未出现时长按顶部 SYNC。"
        case 2:
            phase = .connecting
            helperDetail = Self.connectingDetail(rememberDevice: rememberDevice)
        case 3:
            phase = .initializing
            helperDetail = "已连接，正在读取校准资料。"
        case 4:
            phase = .ready
            if let battery = (object["battery"] as? NSNumber)?.intValue {
                helperDetail = "\(deviceName) 已连接，电量约 \(battery * 10)%。关闭游戏后仍会保持连接。"
            } else {
                helperDetail = "\(deviceName) 已连接。关闭游戏后仍会保持连接。"
            }
        case 5, 9:
            phase = .failed
            helperDetail = "手柄未连接。请唤醒手柄后按 SYNC，再点「重新连接」。"
        case 6:
            phase = .failed
            helperDetail = "蓝牙不可用，请检查 macOS 蓝牙权限。"
        case 7:
            phase = .failed
            helperDetail = (object["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "连接失败，请重试。"
        case 8:
            if phase != .handedOff {
                phase = .failed
                helperDetail = "连接已停止。"
            }
        default:
            break
        }
    }

    private var helperURL: URL? {
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("S2ArmNS2Connection")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
#if DEBUG
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let built = root.appendingPathComponent("build/S2ArmNS2Connection")
        if FileManager.default.isExecutableFile(atPath: built.path) { return built }
#endif
        return nil
    }
}

/// 第二个连接程序（最多 4 只时的第二组；macos/ns2_connection_helper.m 的 S2A_NS2_UPSTREAM 模式）：不收游戏、连到第一个的旁路 socket；
///   重连记忆用自己的偏好域（不抢第一个记住的手柄）。状态行只取设备 / 型号 / 玩家数；分配手势照样报
@MainActor
final class NS2SecondHelper {
    private(set) var devices: [PlayerAssignment.Device] = []
    private(set) var kind = 0
    private(set) var players = 1
    var onChange: (() -> Void)?
    var onAssign: (([String: Any]) -> Void)?
    private let executable: URL, upstream: URL, rememberDevice: Bool
    let group: Int   // 第几组（1–7）：玩家号 2·group、2·group+1
    private var task: Process?
    private var input: Pipe?
    private var buffer = Data()

    init(executable: URL, upstream: URL, rememberDevice: Bool, group: Int = 1) {
        self.executable = executable; self.upstream = upstream; self.rememberDevice = rememberDevice; self.group = group
    }

    nonisolated static func environment(base: [String: String], upstream: String, rememberDevice: Bool, group: Int = 1) -> [String: String] {
        var e = base
        e["S2A_NS2_DEFAULTS_SUITE"] = "org.s2arm.macos.game.\(group + 1)"   // 每组自己的重连记忆
        e["S2A_NS2_GROUP"] = String(group)
        e["S2A_NS2_UPSTREAM"] = upstream
        e.removeValue(forKey: "S2A_NS2_SOCKET"); e.removeValue(forKey: "S2A_NS2_SIDE_SOCKET")
        if rememberDevice { e["S2A_NS2_REMEMBER_DEVICE"] = "1" } else { e.removeValue(forKey: "S2A_NS2_REMEMBER_DEVICE") }
        return e
    }

    func start() {
        let t = Process(), out = Pipe(), cmd = Pipe()
        _ = fcntl(cmd.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        t.executableURL = executable
        t.environment = Self.environment(base: ProcessInfo.processInfo.environment, upstream: upstream.path, rememberDevice: rememberDevice, group: group)
        t.standardInput = cmd; t.standardOutput = out; t.standardError = out
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        t.terminationHandler = { [weak self] _ in Task { @MainActor [weak self] in self?.devices = []; self?.onChange?() } }
        do { try t.run(); task = t; input = cmd } catch { task = nil }
    }
    func stop() {
        guard let t = task else { return }
        task = nil; input = nil
        t.terminationHandler = nil
        DispatchQueue.global(qos: .userInitiated).async { _ = NS2LauncherController.terminate(t, grace: NS2LauncherController.stopGrace) }
    }
    func send(_ line: String) { if let d = line.data(using: .utf8) { try? input?.fileHandleForWriting.write(contentsOf: d) } }

    /// 一行状态 / 分配手势（单测直接喂）
    func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 10) {
            let line = buffer[..<nl]; buffer.removeSubrange(...nl)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let event = object["assign"] as? [String: Any] { onAssign?(event); continue }
            guard let code = (object["status"] as? NSNumber)?.intValue else { continue }
            kind = code == 4 ? NS2LauncherController.kind(from: object) : 0
            players = NS2LauncherController.players(from: object)
            devices = code == 4 ? NS2LauncherController.devices(from: object, group: group) : []
            onChange?()
        }
    }
}

