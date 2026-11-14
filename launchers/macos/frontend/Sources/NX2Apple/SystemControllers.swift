// S2Arm（不是上游文件）：系统手柄列表（#520 F）。启动器自己看 GameController：PS5 / Xbox / 一代 Joy-Con / 一代 Pro 等经 macOS 蓝牙连上的手柄，
//   面板里每只一块（标题 + 「打开蓝牙设置」）、并进「玩家」列表（照 #520 UI 稿 system.html）。NS2 手柄走 S2Arm 自己的连接，不在这里重复列
import AppKit
import Combine
import GameController

@MainActor
final class SystemControllers: ObservableObject {
    enum Family: Equatable { case playstation, xbox, gen1Left, gen1Right, gen1Pair, nintendoPro, other }
    struct Pad: Identifiable, Equatable {
        let id: ObjectIdentifier
        let name: String
        let family: Family
    }

    @Published private(set) var pads: [Pad] = []
    /// 按设备看到的一代 Joy-Con（D2：几套都分得开，Gen1HIDWatcher）
    @Published private(set) var gen1: [PlayerAssignment.Gen1Device] = []
    private var observers: [NSObjectProtocol] = []
    private var gen1Watcher: Gen1HIDWatcher?

    init(observe: Bool = true) {
        guard observe else { return }
        let watcher = Gen1HIDWatcher()
        watcher.observe { [weak self] devices in Task { @MainActor in self?.gen1 = devices } }
        gen1Watcher = watcher
        let center = NotificationCenter.default
        // 蓝牙手柄接上 / 断开、启动器回到前台（后台接上的、启动前就配对连着的那几只，框架要到活跃才补齐）都重对一次
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect, NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let connected = note.name == .GCControllerDidConnect ? note.object as? GCController : nil
                Task { @MainActor in self?.refresh(connected: connected) }
            })
        }
        refresh()
        // 启动后稍等再对两次：GameController 的枚举快照在启动早期（窗口还没活跃）可能不全，
        //   蓝牙手柄的输入描述（physicalInputProfile）也是连上后才就绪——就绪前会被下面的过滤丢掉，之后没有新事件就再也对不上（#934）
        for delay in [0.5, 2.5] {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await MainActor.run { self?.refresh() }
            }
        }
    }

    /// 单测：直接给一组手柄（不碰 GameController）
    init(pads: [Pad], gen1: [PlayerAssignment.Gen1Device] = []) { self.pads = pads; self.gen1 = gen1 }

    /// 分配中认一代 Joy-Con 的手势：(设备 id, 0 左只 / 1 右只, 手势)；nil 停
    func watchGen1(_ onGesture: ((String, Int, Int) -> Void)?) {
        gen1Watcher?.watchGestures(onGesture.map { handler in { id, side, g in Task { @MainActor in handler(id, side, g) } } })
    }

    /// 枚举系统手柄。connected（连接通知里的那一只）是本次事件的真值：枚举快照还没更新时也要把它列进来，
    ///   不然这只手柄等不到下一次事件，面板就一直「没连接」（系统明明已连上，#934）；它的输入描述还没就绪也照列，晚点再补。
    func refresh(connected: GCController? = nil) {
        var controllers = GCController.controllers()
        if let connected, !controllers.contains(where: { $0 === connected }) { controllers.append(connected) }
        pads = controllers.compactMap { c in
            guard c.extendedGamepad != nil || !c.physicalInputProfile.buttons.isEmpty || c === connected else { return nil }
            let category = c.productCategory
            guard let family = Self.family(category: category, vendor: c.vendorName,
                                           xbox: c.extendedGamepad is GCXboxGamepad,
                                           playstation: c.extendedGamepad is GCDualSenseGamepad || c.extendedGamepad is GCDualShockGamepad) else { return nil }
            return Pad(id: ObjectIdentifier(c), name: c.vendorName ?? category, family: family)
        }
    }

    /// 分类（纯函数，单测）：返回 nil = 不列（NS2 手柄：S2Arm 自己连着读，同宿主 s2a_pad_is_ns2 去重）。
    ///   认不出的照列「其他手柄」，不丢
    nonisolated static func family(category: String, vendor: String?, xbox: Bool, playstation: Bool) -> Family? {
        let text = (category + " " + (vendor ?? "")).lowercased()
        if ["switch 2", "joy-con 2", "joycon 2"].contains(where: text.contains) { return nil }
        if playstation || text.contains("dualsense") || text.contains("dualshock") { return .playstation }
        if xbox || text.contains("xbox") { return .xbox }
        if text.contains("joy-con (l/r)") || text.contains("joy-con (l + r)") { return .gen1Pair }
        if text.contains("joy-con (l)") { return .gen1Left }
        if text.contains("joy-con (r)") { return .gen1Right }
        if text.contains("pro controller") && (text.contains("switch") || text.contains("nintendo")) { return .nintendoPro }
        return .other
    }

    /// 分配玩家时读 L1 + R1（同按的那一刻报一次）：name + 同名第几只，跟宿主认手柄的方法一样（macos/front_mac.m pad-order）
    private var assignTimer: Timer?
    private var held: Set<ObjectIdentifier> = []
    func watchAssign(_ onPress: ((String, Int) -> Void)?) {
        assignTimer?.invalidate(); assignTimer = nil; held.removeAll()
        guard let onPress else { return }
        assignTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAssign(onPress) }
        }
    }
    private func pollAssign(_ onPress: (String, Int) -> Void) {
        var seen: [String: Int] = [:]
        let listed = Set(pads.map(\.id))
        for c in GCController.controllers() where listed.contains(ObjectIdentifier(c)) {   // 同 pads 的筛法，第几只才对得上
            let name = c.vendorName ?? c.productCategory
            let index = seen[name, default: 0]; seen[name] = index + 1
            let p = c.physicalInputProfile
            let pressed = { (key: String) in p.buttons[key]?.isPressed ?? false }
            // L1 + R1 或 L2 + R2 同按都算
            let both = (pressed(GCInputLeftShoulder) && pressed(GCInputRightShoulder)) || (pressed(GCInputLeftTrigger) && pressed(GCInputRightTrigger))
            let key = ObjectIdentifier(c)
            if both, !held.contains(key) { held.insert(key); onPress(name, index) } else if !both { held.remove(key) }
        }
    }
    /// 现在在线的系统手柄（名字 + 同名第几只）：分配完成时算「在线却没登记」的那些
    var presentKeys: [PlayerAssignment.SystemKey] { Self.keys(for: pads) }
    nonisolated static func keys(for pads: [Pad]) -> [PlayerAssignment.SystemKey] {
        var seen: [String: Int] = [:]
        return pads.map { pad in let i = seen[pad.name, default: 0]; seen[pad.name] = i + 1; return PlayerAssignment.SystemKey(name: pad.name, index: i) }
    }

    static func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) }
    }
}

extension ControllerIcon {
    /// 玩家列表里的系统手柄：单只一代 Joy-Con 也横着画（一位玩家、横握；#520 讨论），其余同标题图
    static func systemPlayer(_ family: SystemControllers.Family) -> Glyph {
        switch family { case .gen1Left: return .gen1LeftSideways; case .gen1Right: return .gen1RightSideways; default: return system(family) }
    }
    static func system(_ family: SystemControllers.Family) -> Glyph {
        switch family {
        case .playstation: return .playstation
        case .xbox: return .xbox
        case .gen1Left: return .gen1Left
        case .gen1Right: return .gen1Right
        case .gen1Pair: return .gen1Pair
        case .nintendoPro: return .pro
        case .other: return .otherPad
        }
    }
}
