// S2Arm（不是上游文件）：Switch 2 Pro 连接状态。启动并监看启动器旁的 S2ArmNS2Connection 进程（独占蓝牙连接，游戏经本机通道读输入），
//   持久化「开启 S2Arm 时自动连接」「关闭游戏后自动断开」「记住这台设备」三个开关（docs/mac-switch2-pro.md）。
import AppKit
import Combine
import Foundation

@MainActor
final class NS2LauncherController: ObservableObject {
    enum Phase: Equatable {
        case off, starting, scanning, connecting, initializing, ready, failed, handedOff
    }

    @Published private(set) var autoConnectOnOpen: Bool
    @Published private(set) var disconnectAfterGame: Bool
    /// 记住这台设备（#521）：长按 SYNC 连上的手柄写入本机地址，之后按任一键即可重连。缺省关；下次启动连接程序时生效
    @Published private(set) var rememberDevice: Bool
    @Published private(set) var phase: Phase = .off
    @Published private(set) var detail = ""
    @Published private(set) var deviceName = "Switch 2 Pro"
    /// 连接程序报的对外输出型号（ns2_kind：1 Pro、2 Joy-Con 左、3 右、4 左右一对；0 = 没连 / 旧连接程序没报）
    @Published private(set) var kind = 0

    /// 弹窗标题：照连着的型号写；没连 / 还不知道型号时写通用的「Switch 手柄」（不分代：一代 Joy-Con 以后也在这里）（#520）
    func title(simplifiedChinese zh: Bool) -> String { Self.title(kind: kind, simplifiedChinese: zh) }
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
    let socketURL: URL
    private var process: Process?
    private var output: Pipe?
    private var buffer = Data()
    private var intentionalStop = false

    init(socketURL: URL) {
        self.socketURL = socketURL
        defaults = UserDefaults(suiteName: "org.s2arm.macos.game") ?? .standard
        autoConnectOnOpen = defaults.object(forKey: "S2AMacNS2AutoConnectOnOpen") as? Bool ?? false
        disconnectAfterGame = defaults.object(forKey: "S2AMacNS2DisconnectAfterGame") as? Bool ?? false
        rememberDevice = defaults.object(forKey: "S2AMacNS2RememberDevice") as? Bool ?? false
    }

    var buttonStatus: String {
        switch phase {
        case .ready: return "已连接"
        case .starting: return "启动中"
        case .scanning: return "搜索中"
        case .connecting, .initializing: return "连接中"
        case .failed: return "未连接"
        case .handedOff: return "游戏使用中"
        case .off: return "未连接"
        }
    }

    var buttonColor: NSColor {
        switch phase {
        case .ready: return .systemGreen
        case .starting, .scanning, .connecting, .initializing: return .systemOrange
        case .failed: return .systemRed
        case .handedOff, .off: return .secondaryLabelColor
        }
    }

    var hasConnectionProcess: Bool { process != nil }

    func startIfEnabled() {
        guard autoConnectOnOpen else {
            phase = .off
            detail = "手柄未连接。需要时可在上方手动连接。"
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

    func setRememberDevice(_ value: Bool) {
        guard value != rememberDevice else { return }
        rememberDevice = value
        defaults.set(value, forKey: "S2AMacNS2RememberDevice")
        // 设置交给连接程序的环境变量，要重启它才生效；游戏正用着手柄时不打断，下次连接生效
        if process != nil && phase != .handedOff { retry() }
    }

    /// 交给连接程序的环境变量：偏好域、通道路径；开了「记住这台设备」再加 S2A_NS2_REMEMBER_DEVICE=1（macos/ns2_connection_helper.m）
    nonisolated static func helperEnvironment(base: [String: String], socketPath: String, rememberDevice: Bool) -> [String: String] {
        var environment = base
        environment["S2A_NS2_DEFAULTS_SUITE"] = "org.s2arm.macos.game"
        environment["S2A_NS2_SOCKET"] = socketPath
        if rememberDevice { environment["S2A_NS2_REMEMBER_DEVICE"] = "1" } else { environment.removeValue(forKey: "S2A_NS2_REMEMBER_DEVICE") }
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
        detail = "手柄已断开。开始游戏不受影响。"
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

    func gameDidStart() {
        guard process != nil else { return }
        phase = .handedOff
        detail = "游戏正在使用 Switch 2 Pro；关闭游戏后连接会保留。"
    }

    func gameDidExit() {
        guard process != nil else {
            phase = .off
            detail = "手柄未连接。需要时可在上方手动连接。"
            return
        }
        if disconnectAfterGame {
            stopProcess()
            phase = .off
            detail = "游戏已关闭，已按设置断开手柄。"
        } else if phase == .handedOff {
            phase = .ready
            detail = "\(deviceName) 仍保持连接，可以继续使用。"
        }
    }

    func shutdown() {
        stopProcess(wait: true)   // 启动器退出：就地等（有上限），不留没退的连接程序
    }

    private func startProcess() {
        guard let helper = helperURL else {
            phase = .failed
            detail = "找不到启动器的手柄连接组件。"
            return
        }
        phase = .starting
        detail = "正在启动蓝牙连接。首次使用时，请在 macOS 提示中允许。"
        deviceName = "Switch 2 Pro"
        kind = 0
        buffer.removeAll(keepingCapacity: true)
        intentionalStop = false

        let task = Process()
        let pipe = Pipe()
        task.executableURL = helper
        task.environment = Self.helperEnvironment(base: ProcessInfo.processInfo.environment, socketPath: socketURL.path, rememberDevice: rememberDevice)
        task.standardOutput = pipe
        task.standardError = pipe
        process = task
        output = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        task.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.process === finished else { return }
                self.process = nil
                self.kind = 0
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.output = nil
                if !self.intentionalStop {
                    self.phase = .failed
                    self.detail = "连接程序已停止，请手动重新连接。"
                }
            }
        }
        do {
            try task.run()
        } catch {
            process = nil
            output = nil
            phase = .failed
            detail = error.localizedDescription
        }
    }

    /// 停连接程序（剃刀 M16）：原先主线程上 terminate 后 waitUntilExit() 不设上限，连接程序不退出时整个启动器冻住。
    ///   现在后台等（stopGrace 秒），不退就 SIGKILL；done 在确认退出后回主线程调。wait = true（启动器退出）就地等同样有上限
    private func stopProcess(wait: Bool = false, then done: (@MainActor () -> Void)? = nil) {
        intentionalStop = true
        kind = 0
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
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let code = (object["status"] as? NSNumber)?.intValue else { continue }
            apply(status: code, object)
        }
    }

    private func apply(status code: Int, _ object: [String: Any]) {
        if let name = object["name"] as? String, !name.isEmpty { deviceName = name }
        kind = Self.kind(from: object)
        switch code {
        case 0:
            phase = .starting
            detail = "正在启动蓝牙连接。"
        case 1:
            phase = .scanning
            detail = "正在搜索手柄。请按一下手柄；未出现时长按顶部 SYNC。"
        case 2:
            phase = .connecting
            detail = Self.connectingDetail(rememberDevice: rememberDevice)
        case 3:
            phase = .initializing
            detail = "已连接，正在读取校准资料。"
        case 4:
            phase = .ready
            if let battery = (object["battery"] as? NSNumber)?.intValue {
                detail = "\(deviceName) 已连接，电量约 \(battery * 10)%。关闭游戏后仍会保持连接。"
            } else {
                detail = "\(deviceName) 已连接。关闭游戏后仍会保持连接。"
            }
        case 5, 9:
            phase = .failed
            detail = "手柄未连接。请唤醒手柄后按 SYNC，再点「重新连接」。"
        case 6:
            phase = .failed
            detail = "蓝牙不可用，请检查 macOS 蓝牙权限。"
        case 7:
            phase = .failed
            detail = (object["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "连接失败，请重试。"
        case 8:
            if phase != .handedOff {
                phase = .failed
                detail = "连接已停止。"
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
