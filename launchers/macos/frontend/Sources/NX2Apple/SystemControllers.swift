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
    /// 一代 Joy-Con 读到的出厂颜色（设备 id → 颜色；Gen1HIDWatcher 读 SPI 0x6050），图示照它上色
    @Published private(set) var gen1Colors: [String: ControllerTint] = [:]
    /// 现在的玩家灯（分配一变就更新；手柄重连 / 系统手柄枚举变了照它再写一次）
    private var lightMasks: [String: Int] = [:]
    private var systemPlayers: [PlayerAssignment.SystemKey: Int] = [:]
    /// 接着的 HID 手柄名（HIDFallbackPads）；面板列 fallback（GameController 认不出、宿主按 HID 兜底读的，#1151）
    @Published private(set) var hidNames: [String] = []
    var fallback: [String] { HIDFallbackPads.listed(hid: hidNames, system: pads.map(\.name)) }
    private var observers: [NSObjectProtocol] = []
    private var gen1Watcher: Gen1HIDWatcher?
    private var hidWatcher: HIDFallbackPads?

    private var observing = false   // 单测（init(pads:)）不并模拟手柄
    init(observe: Bool = true) {
        guard observe else { return }
        observing = true
        let watcher = Gen1HIDWatcher()
        watcher.observe { [weak self] devices in Task { @MainActor in self?.realGen1 = devices; self?.mergeSimulated() } }
        watcher.observeColors { [weak self] colors in Task { @MainActor in self?.realGen1Colors = colors; self?.mergeSimulated() } }
        if ControllerColorSimulator.allowed {   // 模拟手柄（本地 / 自测构建的 App 菜单）：并进下面三张表，走真的分配逻辑
            let sim = ControllerColorSimulator.shared
            sim.onChange.append { [weak self] in self?.mergeSimulated() }
            sim.systemPadsInOrder = { [weak self] in self?.pads ?? [] }
        }
        gen1Watcher = watcher
        let hid = HIDFallbackPads()
        hid.observe { [weak self] names in Task { @MainActor in self?.hidNames = names } }
        hidWatcher = hid
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect, NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let connected = note.name == .GCControllerDidConnect ? note.object as? GCController : nil
                let disconnected = note.name == .GCControllerDidDisconnect ? note.object as? GCController : nil
                Task { @MainActor in self?.refresh(connected: connected, disconnected: disconnected) }
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
    init(pads: [Pad], gen1: [PlayerAssignment.Gen1Device] = [], hidNames: [String] = []) { self.pads = pads; self.gen1 = gen1; self.hidNames = hidNames }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        assignTimer?.invalidate()
    }

    /// 分配中认一代 Joy-Con 的手势：(设备 id, 0 左只 / 1 右只, 手势)；nil 停
    func watchGen1(_ onGesture: ((String, Int, Int) -> Void)?) {
        gen1Watcher?.watchGestures(onGesture.map { handler in { id, side, g in Task { @MainActor in handler(id, side, g) } } })
    }

    func refresh(connected: GCController? = nil, disconnected: GCController? = nil) {
        realPads = Self.snapshot(GCController.controllers(), connected: connected, disconnected: disconnected)
        mergeSimulated()
        applySystemLights(connected: connected)
    }
    // 真的手柄（GameController / HID 看到的）；pads / gen1 / gen1Colors = 真的 + 模拟的
    private var realPads: [Pad] = []
    private var realGen1: [PlayerAssignment.Gen1Device] = []
    private var realGen1Colors: [String: ControllerTint] = [:]
    private func mergeSimulated() {
        let sim = observing && ControllerColorSimulator.allowed ? ControllerColorSimulator.shared : nil
        let nextPads = realPads + (sim?.systemPads() ?? [])
        let nextGen1 = realGen1 + (sim?.gen1Devices ?? [])
        let nextColors = realGen1Colors.merging(sim?.gen1Colors ?? [:]) { a, _ in a }
        if nextPads != pads { pads = nextPads }
        if nextGen1 != gen1 { gen1 = nextGen1 }
        if nextColors != gen1Colors { gen1Colors = nextColors }
    }

    /// 手柄上的玩家灯跟着分配（同原机）：一代 Joy-Con 按设备写子命令 0x30；系统手柄（GameController：一代 Pro、合成的一代 Joy-Con、
    ///   PlayStation 等）设 playerIndex，系统自己点灯。GameController 只有 1–4 号，第 5 位起不设（灯照系统原样）
    func applyPlayerLights(_ assignment: PlayerAssignment) {
        lightMasks = assignment.lightMasks()
        systemPlayers = assignment.systemPlayers()
        gen1Watcher?.setLights(lightMasks)
        applySystemLights()
    }
    private func applySystemLights(connected: GCController? = nil) {
        guard !systemPlayers.isEmpty else { return }
        var current = GCController.controllers()
        if let connected, !current.contains(where: { $0 === connected }) { current.insert(connected, at: 0) }
        let byID = Dictionary(current.map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { a, _ in a })
        for (pad, key) in zip(pads, Self.keys(for: pads)) {
            guard let number = systemPlayers[key], let gc = byID[pad.id] else { continue }
            let index = Self.playerIndex(number)
            if gc.playerIndex != index { gc.playerIndex = index }
        }
    }
    /// 第几位（1 起）→ GameController 的玩家号；5 起没有对应的，不设
    nonisolated static func playerIndex(_ number: Int) -> GCControllerPlayerIndex {
        switch number { case 1: return .index1; case 2: return .index2; case 3: return .index3; case 4: return .index4; default: return .indexUnset }
    }

    /// 顶栏与弹窗共用同一设备判据；通知对象优先于尚未更新的枚举快照，按对象身份去重而非名称。
    static func snapshot(_ controllers: [GCController], connected: GCController? = nil, disconnected: GCController? = nil) -> [Pad] {
        var current = controllers.filter { $0 !== disconnected }
        if let connected, connected !== disconnected { current.insert(connected, at: 0) }
        var seen = Set<ObjectIdentifier>()
        return current.compactMap { c in
            guard seen.insert(ObjectIdentifier(c)).inserted else { return nil }
            guard c.extendedGamepad != nil || !c.physicalInputProfile.buttons.isEmpty || c === connected else { return nil }
            let category = c.productCategory
            guard let family = Self.family(category: category, vendor: c.vendorName,
                                           xbox: c.extendedGamepad is GCXboxGamepad,
                                           playstation: c.extendedGamepad is GCDualSenseGamepad || c.extendedGamepad is GCDualShockGamepad) else { return nil }
            let name = c.vendorName.flatMap { $0.isEmpty ? nil : $0 } ?? (category.isEmpty ? "Game Controller" : category)
            return Pad(id: ObjectIdentifier(c), name: name, family: family)
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
    /// 认手柄（玩家列表亮一下）：面板开着时，哪只系统手柄有新按下的键就报一次（name + 同名第几只，同分配玩家）；nil 停。
    ///   只读不接管输入回调（同 pollAssign，轮询 isPressed）
    private var pressTimer: Timer?
    private var pressHeld: [ObjectIdentifier: Set<String>] = [:]   // 每只手柄上一次按着的键
    func watchPress(_ onPress: ((String, Int, String?) -> Void)?) {
        pressTimer?.invalidate(); pressTimer = nil; pressHeld.removeAll()
        guard let onPress else { return }
        for c in GCController.controllers() { pressHeld[ObjectIdentifier(c)] = Self.pressedKeys(c) }   // 打开那一刻已按着的不算
        pressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPress(onPress) }
        }
    }
    /// 现在按着的键（GameController 的按键名；方向键写成 dpad 名 + .up 之类）
    private static func pressedKeys(_ c: GCController) -> Set<String> {
        let p = c.physicalInputProfile
        var keys = Set(p.buttons.filter { $0.value.isPressed }.map(\.key))
        for (name, pad) in p.dpads {
            for (dir, button) in [("up", pad.up), ("down", pad.down), ("left", pad.left), ("right", pad.right)] where button.isPressed { keys.insert(name + "." + dir) }
        }
        return keys
    }
    private func pollPress(_ onPress: (String, Int, String?) -> Void) {
        var seen: [String: Int] = [:]
        let listed = Dictionary(pads.map { ($0.id, $0.family) }, uniquingKeysWith: { a, _ in a })
        for c in GCController.controllers() {
            let key = ObjectIdentifier(c)
            guard let family = listed[key] else { continue }
            let name = c.vendorName ?? c.productCategory
            let index = seen[name, default: 0]; seen[name] = index + 1
            let now = Self.pressedKeys(c)
            let fresh = now.subtracting(pressHeld[key] ?? [])
            pressHeld[key] = now
            // 同一下可能同时出现好几个名字（方向键既是 dpad 也列在 buttons 里，如「Direction Pad Up」）：取第一个认得出的
            if !fresh.isEmpty { onPress(name, index, fresh.sorted().lazy.compactMap { Self.keyLabel($0, family: family) }.first) }
        }
    }
    /// GameController 按键名 → 显示的字：先照这只手柄自己的印字（PlayStation ✕ ○ □ △ 图示 / L1 R1，Xbox A B X Y / LB RB，Home 用标志），
    ///   认不出的手柄、或这只手柄认不出的键，一律照位置写成 Switch 手柄上那颗的名字（switchLabel）；方向用图示
    nonisolated static func keyLabel(_ input: String, family: Family) -> String? {
        let lower = input.lowercased()
        // 方向：方向键和摇杆（dpads 里「Direction Pad」「Left Thumbstick」…，或 buttons 里「Direction Pad Up」之类）都显示上下左右
        if lower.hasSuffix(".up") || lower.hasSuffix(" up") { return NS2LauncherController.keyUp }
        if lower.hasSuffix(".down") || lower.hasSuffix(" down") { return NS2LauncherController.keyDown }
        if lower.hasSuffix(".left") || lower.hasSuffix(" left") { return NS2LauncherController.keyLeft }
        if lower.hasSuffix(".right") || lower.hasSuffix(" right") { return NS2LauncherController.keyRight }
        return ownLabel(input, family: family) ?? switchLabel(input)
    }
    /// 这只手柄自己印的字（只有 PlayStation、Xbox 有；其余 nil → 用 Switch 的）
    nonisolated static func ownLabel(_ input: String, family: Family) -> String? {
        switch family {
        case .playstation:
            switch input {
            case GCInputButtonA: return "sf:xmark"
            case GCInputButtonB: return "sf:circle"
            case GCInputButtonX: return "sf:square"
            case GCInputButtonY: return "sf:triangle"
            case GCInputLeftShoulder: return "L1"
            case GCInputRightShoulder: return "R1"
            case GCInputLeftTrigger: return "L2"
            case GCInputRightTrigger: return "R2"
            case GCInputLeftThumbstickButton: return "L3"
            case GCInputRightThumbstickButton: return "R3"
            case GCInputButtonMenu: return "Options"   // 右边那颗
            case GCInputButtonOptions: return "Create"  // 左边那颗
            case GCInputButtonHome: return "sf:logo.playstation"
            case GCInputButtonShare: return "Mute"
            case GCInputDualShockTouchpadButton: return "Touchpad"
            default: return nil
            }
        case .xbox:
            switch input {
            case GCInputButtonA: return "A"
            case GCInputButtonB: return "B"
            case GCInputButtonX: return "X"
            case GCInputButtonY: return "Y"
            case GCInputLeftShoulder: return "LB"
            case GCInputRightShoulder: return "RB"
            case GCInputLeftTrigger: return "LT"
            case GCInputRightTrigger: return "RT"
            case GCInputButtonMenu: return "Menu"   // 右边那颗（三横线）
            case GCInputButtonOptions: return "View" // 左边那颗（两个方块）
            case GCInputButtonHome: return "sf:logo.xbox"
            case GCInputButtonShare: return "Share"
            // Elite 背面四个拨片（GCXboxGamepad paddleButton1–4，手柄背面印 P1–P4）
            case GCInputXboxPaddleOne: return "P1"
            case GCInputXboxPaddleTwo: return "P2"
            case GCInputXboxPaddleThree: return "P3"
            case GCInputXboxPaddleFour: return "P4"
            default: return nil
            }
        default: return nil
        }
    }
    /// 照位置写成 Switch 手柄上那颗的名字（GameController 的 A / B / X / Y 是下 / 右 / 左 / 上，Switch 的下 / 右 / 左 / 上是 B / A / Y / X）；
    ///   连这里也认不出的键不显示
    nonisolated static func switchLabel(_ input: String) -> String? {
        switch input {
        case GCInputButtonA: return "B"
        case GCInputButtonB: return "A"
        case GCInputButtonX: return "Y"
        case GCInputButtonY: return "X"
        case GCInputLeftShoulder: return "L"
        case GCInputRightShoulder: return "R"
        case GCInputLeftTrigger: return "ZL"
        case GCInputRightTrigger: return "ZR"
        case GCInputLeftThumbstickButton: return "LS"
        case GCInputRightThumbstickButton: return "RS"
        case GCInputButtonMenu: return "+"
        case GCInputButtonOptions: return "−"
        case GCInputButtonHome: return "Home"
        case GCInputButtonShare: return "Capture"
        default: return nil
        }
    }
    /// 认手柄：一代 Joy-Con 按设备有新按下的键就报（设备 id）；nil 停
    func watchGen1Press(_ onPress: ((String, String?) -> Void)?) {
        gen1Watcher?.watchPresses(onPress.map { handler in { id, key in Task { @MainActor in handler(id, key) } } })
    }

    /// 现在在线的系统手柄（名字 + 同名第几只）：分配完成时算「在线却没登记」的那些
    var presentKeys: [PlayerAssignment.SystemKey] { Self.keys(for: pads) }
    nonisolated static func keys(for pads: [Pad]) -> [PlayerAssignment.SystemKey] {
        var seen: [String: Int] = [:]
        return pads.map { pad in let i = seen[pad.name, default: 0]; seen[pad.name] = i + 1; return PlayerAssignment.SystemKey(name: pad.name, index: i) }
    }
    /// 分配玩家认的「系统手柄」（纯函数，单测）：GameController 的手柄 + HID 兜底手柄（#1151：PowerA 这类 GameController 认不出、
    ///   宿主 macos/hid_pad.m 按 HID 读的）。兜底手柄同样按「名字 + 同名第几只」认——宿主排顺序表时对兜底手柄也是这一套（front_mac.m
    ///   s2a_pad_order_rank：名字取 HID 产品名，同 HIDFallbackPads），接上即自动排进玩家位，同系统手柄；GameController 已列出的同名手柄不重复
    nonisolated static func assignmentKeys(pads: [Pad], hidNames: [String]) -> [PlayerAssignment.SystemKey] {
        var seen: [String: Int] = [:]
        let fallback = HIDFallbackPads.listed(hid: hidNames, system: pads.map(\.name)).map { name in
            let i = seen[name, default: 0]; seen[name] = i + 1; return PlayerAssignment.SystemKey(name: name, index: i)
        }
        return keys(for: pads) + fallback
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
