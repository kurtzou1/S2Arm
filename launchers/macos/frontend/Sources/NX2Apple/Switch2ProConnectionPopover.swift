// S2Arm（不是上游文件）：顶栏手柄按钮与弹窗：连接状态、手动连接 / 断开、持久化开关（收在齿轮选单）。
//   区块按连接通道分：Switch 2 区块只给 S2Arm 直连（controller），蓝牙区块只给系统蓝牙手柄（systems.pads）——
//   两条通道不同，Switch 2 区块的标题 / 状态不可借用蓝牙手柄的名字（#901 曾把系统手柄名写进 Switch 2 标题，DualSense 出现两次）
//
// 【方案建议：手机当手柄（Mobile），功能未做，给之后开发的人】
//   - 不另开首页面板：手机就是第三条输入通道，放在这个弹窗里，排在「蓝牙」区块下面，样式同其他区块
//     （小标头 Mobile / 手机、ControllerIcon(.mobile)、标题、StatusLine、整宽主按钮），不加卡中卡、色标或说明小字。
//   - 标题：一台写手机名，多台写数量（同蓝牙区块「N 个蓝牙手柄」）；状态行沿用 NS2LauncherController.Status 的词。
//   - 配对：主按钮「连接手机」→ 在按钮上弹 .popover 显示 QR 码（局域网地址 + 一次性配对码），手机扫码后打开手柄页面；
//     同一 Wi-Fi 用 Bonjour 找主机。连上后主按钮变「断开」；设定（如自动接受已配对手机）放进同样的齿轮选单，面板不变高。
//   - 玩家：每台手机是 PlayerAssignment.Unit 的一种新来源（如 .mobile(id)），完全走现有分配玩家流程——
//     连上时由 PlayerAssignment.reconcile 自动排进下一个空位，「分配玩家」里按手机上的按钮登记 / 换位、× 清空；
//     不写死手机是 P1 / P2 / P3，也不给手机保留玩家位。玩家列表用 ControllerIcon(.mobile)。
//   - 顶栏：三条通道合并看（任一通道连着 = 绿点「已连接」，见 NS2LauncherController.buttonStatus / title）。
//   - 上线前面板不显示 Mobile 区块，只预留 ControllerIcon.Glyph.mobile。
import SwiftUI
import GameController
import AppKit
import NXCore
import NXModel
import NXLauncher

struct Switch2ProConnectionPopover: View {
    @ObservedObject var controller: NS2LauncherController
    @ObservedObject var systems: SystemControllers
    let lang: String   // 界面语言代码（Lang.code）
    var onClose: () -> Void = {}   // 手柄 B 关面板（顶栏传进来）
    /// 面板最高多高（#1400：接上 PS5 等蓝牙手柄后内容变多，面板比屏幕可用高度还高，顶部被裁、又滚不动）。
    ///   缺省 = 当前屏幕可用高度减去顶栏与弹窗边距；内容超出就在面板里纵向滚动。单测可以传小值模拟矮屏
    var maxHeight: CGFloat? = nil
    @State private var contentHeight: CGFloat = 0
    private var heightLimit: CGFloat { maxHeight ?? max(320, (NSScreen.main?.visibleFrame.height ?? 800) - 96) }

    private func t(_ key: String) -> String { NS2LauncherController.text("s2arm.controller." + key, lang) }
    @Environment(\.padControls) private var padControls   // 界面导航（分配中把手柄按键送进来）
    @State private var keyMonitor: Any?   // 分配中收键盘按键（键盘登记成一位玩家）
    @State private var showSettings = false   // 齿轮选单
    @State private var pressKeyMonitor: Any?   // 认手柄：键盘按键让键盘那一位亮一下（不吞键）
    @State private var selectedPlayer = 0   // 玩家列表选中的一位（四键子页面照这一位的手柄画键帽）
    @State private var showFaceMap = false   // 四键布局浮层（同齿轮选单，画在面板里，不改面板高度）
    @State private var faceMapHeight: CGFloat = 0
    private var zh: Bool { lang.hasPrefix("zh") }
    private var faceMapTitle: String { t("faceMap.title") }
    /// 浮层编辑哪一份、画哪种键帽：选中玩家的手柄 → 专用通道的任天堂手柄 → 第一只蓝牙手柄 → 其他手柄（不挡：没手柄也能先设好）
    private var faceMapFamily: ControllerFaceFamily {
        if let pad = controller.assignment.pad(forPlayer: currentPlayer, in: systems.pads) { return ControllerFaceFamily(pad.family) }
        if controller.assignment.isNintendo(player: currentPlayer) { return .nintendo }
        if let pad = systems.pads.first { return ControllerFaceFamily(pad.family) }
        return controller.allDevices.isEmpty ? .other : .nintendo
    }
    private var currentPlayer: Int {
        let slots = controller.assignment.slots
        if slots.indices.contains(selectedPlayer), slots[selectedPlayer] != nil { return selectedPlayer }
        return slots.firstIndex(where: { $0 != nil }) ?? 0
    }

    private func unitGlyph(_ unit: PlayerAssignment.Unit) -> ControllerIcon.Glyph {
        switch unit {
        case .pair: return .pairHead
        case .single(_, let kind), .whole(_, let kind): return ControllerIcon.player(kind: kind) ?? .unknown
        case .system(let name, _): return ControllerIcon.systemPlayer(systems.pads.first { $0.name == name }?.family ?? .other)
        case .keyboard: return .keyboard
        case let .gen1(_, side): return side == 0 ? .gen1LeftSideways : .gen1RightSideways
        case .gen1Pair: return .gen1Pair
        }
    }
    /// 这一位能不能改四键布局：键盘没有四键，其余手柄（含任天堂与各类蓝牙手柄）都可以；
    ///   任天堂手柄使用独立的 `nintendo` 映射，不与非任天堂手柄共用
    private func faceMappable(_ unit: PlayerAssignment.Unit) -> Bool {
        if case .keyboard = unit { return false }
        return true
    }
    private func unitName(_ unit: PlayerAssignment.Unit) -> String {
        switch unit {
        case .pair: return NS2LauncherController.title(kind: 4, lang: lang)
        case .single(_, let kind), .whole(_, let kind): return NS2LauncherController.title(kind: kind, lang: lang)
        case .system(let name, _): return name
        case .keyboard: return t("keyboard")
        case let .gen1(_, side): return side == 0 ? "Joy-Con (L)" : "Joy-Con (R)"
        case .gen1Pair: return "Joy-Con (L/R)"
        }
    }

    /// 有没有键盘以外的输入（玩家区块与「分配玩家」照这个显示）：Switch 2 手柄、蓝牙手柄、HID 兜底手柄、一代 Joy-Con。
    ///   新的输入来源加在这里——例如以后的 Mobile（同一 Wi-Fi 的手机手柄），或分得出设备的多组键盘（现在系统把所有键盘并成一路，不算）
    private var hasInputBesidesKeyboard: Bool {
        !controller.allDevices.isEmpty || !systems.pads.isEmpty || !systems.fallback.isEmpty || !systems.gen1.isEmpty
    }

    /// 「玩家」列表 = 现在的分配槽位（含中间空槽，尾端无玩家时自动省略），最多 8 位
    @ObservedObject private var colorSim = ControllerColorSimulator.shared   // 模拟彩色手柄（本地 / 自测构建的 App 菜单），接在真的后面
    private var playerRows: [(glyph: ControllerIcon.Glyph, name: String, colors: ControllerColors)?] {
        controller.assignment.slots.map { unit in unit.map { (unitGlyph($0), unitName($0), unitColors($0)) } }
    }
    /// 这一位的手柄颜色（图示动态上色）：一代 Joy-Con 用读到的出厂颜色；其余（含第三方、还没读到）用缺省色
    private func unitColors(_ unit: PlayerAssignment.Unit) -> ControllerColors {
        switch unit {
        case let .gen1(id, side): return side == 0 ? ControllerColors(left: systems.gen1Colors[id]) : ControllerColors(right: systems.gen1Colors[id])
        case let .gen1Pair(l, r): return ControllerColors(left: systems.gen1Colors[l], right: systems.gen1Colors[r])
        // Joy-Con 2 的颜色还没从手柄读（出厂资料区的位置待真机确认）：现在只有模拟手柄有
        case let .pair(l, r): return ControllerColors(left: colorSim.ns2Tint(l), right: colorSim.ns2Tint(r))
        case let .single(id, kind): return kind == 2 ? ControllerColors(left: colorSim.ns2Tint(id)) : ControllerColors(right: colorSim.ns2Tint(id))
        case let .system(name, index):   // 系统合成的一代 Joy-Con：模拟的那几套有颜色
            let same = systems.pads.filter { $0.name == name }
            return same.indices.contains(index) ? colorSim.systemColors(same[index].id) ?? .none : .none
        default: return .none
        }
    }

    // 照 #520 UI 稿：区块由上到下 Switch 2 → 蓝牙 → 玩家，每块一个小标头，细线分隔（间距一律 4 的倍数）
    var body: some View {
        let status = controller.status
        ScrollView(.vertical, showsIndicators: contentHeight > heightLimit) {
        VStack(alignment: .leading, spacing: 16) {
            // 分配中只放分配块（#520 讨论：省面板高度）；Switch 2 手柄那块、蓝牙手柄那块完成 / 取消后再出来
            if !controller.assigning {
            // Switch 2 区块：只给 S2Arm 直连（Joy-Con 2 / Pro 2）用。蓝牙手柄走下面 systems.pads 那块——两条连接通道不同，标题 / 状态不可共用
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(text: "Switch 2")
                let title = controller.switch2Title(lang: lang)   // 只讲 Switch 2 手柄（#1151），不借系统手柄名
                HStack(spacing: 12) {
                    ControllerIcon(glyph: ControllerIcon.header(kind: controller.kind, players: controller.players) ?? .unknown)
                        .frame(width: 48, height: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.manrope(20, .bold)).lineLimit(1).truncationMode(.tail).help(title)   // 太长一行截断（同蓝牙那块），悬停看全名
                        StatusLine(color: NS2LauncherController.dotColor(status), text: NS2LauncherController.statusText(status, lang: lang, bluetoothDenied: controller.bluetoothDenied))
                    }
                }
                .accessibilityElement(children: .combine)
                .controllerID("controller.status")

                // 主按钮（连接 / 停止 / 断开 / 重新连接）在左、齿轮在右，不论状态都一样；两个开关收进齿轮选单（之后新设定也加进去，面板不再变高）
                HStack(spacing: 8) {
                    Button(NS2LauncherController.mainButton(status, lang: lang, bluetoothDenied: controller.bluetoothDenied)) { controller.mainAction() }
                        .buttonStyle(LauncherSecondaryButtonStyle(fill: true))
                        // ⚠️ 不要改回 controllerButtonStyle / controllerID（不要把这颗注册进手柄导航）。
                        //   连接 / 断开只给鼠标点：连着时它是「断开」，面板一开手柄焦点若落在这里，玩家按 A（例如想认手柄、看玩家行亮键）
                        //   就把正在用的 Joy-Con 2 自己断掉（11-16 实机踩过）；没连时手柄本来就按不到「连接」，注册了也没用。
                        //   要断开请按手柄上的 sync 钮，或用鼠标点这颗。controllerExcluded 连 AX 兜底扫描也一起排除，见 PadExclusion
                        .controllerExcluded("controller.main-action")
                    Button { setSettings(!showSettings) } label: { Image(systemName: "gearshape").font(.system(size: 15, weight: .semibold)) }
                        .controllerButtonStyle(LauncherIconButtonStyle())   // 方钮，高度同左边主按钮
                        .help(t("settings"))
                        .accessibilityLabel(t("settings"))
                        .controllerID("controller.settings")
                        .anchorPreference(key: GearAnchorKey.self, value: .bounds) { $0 }
                }
            }

            // 蓝牙区块（#520 UI 稿 system.html）：系统蓝牙手柄——图、标题（一只写系统给的名字，太长一行截断、悬停看全名；多只写数量）、状态、「打开蓝牙设置」
            //   HID 兜底手柄（#1151：GameController 认不出、游戏里按 HID 直读的）一并列在这一块：「… Pro Controller」按 Pro 样式手柄算，别的通用手柄按其他手柄算
            //   没有任何蓝牙手柄时也显示（同 Switch 2 区块）：虚线图、「游戏手柄 / Game controller」（同 macOS 的叫法，不列品牌）、未连接，按钮照样能去系统蓝牙设置配对
            do {
                let fallback = systems.fallback
                let names = systems.pads.map(\.name) + fallback
                let families = systems.pads.map(\.family) + fallback.map { HIDFallbackPads.isPro($0) ? SystemControllers.Family.nintendoPro : .other }
                let title = names.isEmpty ? t("gameController")
                    : names.count == 1 ? names[0] : t("bluetoothCount").replacingOccurrences(of: "{0}", with: "\(names.count)")
                let glyph: ControllerIcon.Glyph = names.isEmpty ? .unknown
                    : ControllerIcon.system(Set(families).count == 1 ? families[0] : .other)   // 多只同一类用那一类的图，混着用通用手柄图
                let state: NS2LauncherController.Status = names.isEmpty ? .notConnected : .connected
                PanelSection {
                    SectionHeader(text: t("bluetooth"))
                    HStack(spacing: 12) {
                        ControllerIcon(glyph: glyph).frame(width: 48, height: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(.manrope(20, .bold)).lineLimit(1).truncationMode(.tail)   // 蓝牙手柄名字太长照截断（缩字太小），悬停看全名
                                .help(names.isEmpty ? title : names.joined(separator: "\n"))
                            StatusLine(color: NS2LauncherController.dotColor(state), text: NS2LauncherController.statusText(state, lang: lang))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("controller.system.status")
                    // 第三方手柄（八位堂、盖世小鸡等 Xbox 外形）切到 Switch 模式才有体感（11-16，同 iPhone 齿轮菜单「手柄与体感」）
                    Text(t("thirdPartyMotion")).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("controller.system.motionHint")
                    // 四键布局的按钮挪到玩家那一行最右边（11-20：Switch 2 也能自定按键，每位玩家各开各的）
                    Button(t("openBluetooth")) { SystemControllers.openBluetoothSettings() }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle(fill: true))
                        .controllerID("controller.system.settings")
                }
            }

            }

            // 玩家（#520 UI 稿）：平时是玩家列表 +「分配玩家」；分配中换成分配块（system.html 第 5 栏）
            if controller.assigning {
                VStack(alignment: .leading, spacing: 12) {   // 只剩这一块：上面不画分隔线
                    SectionHeader(text: t("assignPlayers"))
                    HStack(spacing: 8) {
                        HowToTile(title: t("howPair"), keys: t("howPairKeys"))
                        HowToTile(title: t("howSingle"), keys: t("howSingleKeys"))
                        HowToTile(title: t("howOther"), keys: t("howOtherKeys"))   // #1151：其他手柄（含 HID 兜底）接上即加入，不用按 L + R
                    }
                    VStack(spacing: 8) {
                        let slots = controller.assignment.slots
                        // 至少 4 行（同稿），有更高槽位玩家（如 P8）时一直显示到该槽位（未满 8 时多露一行「等待中」）；确认后面全空才省略 P5–P8
                        ForEach(0..<min(PlayerAssignment.maxPlayers, max(4, slots.count + 1)), id: \.self) { i in
                            if i < slots.count, let unit = slots[i] {
                                PlayerRow(number: i + 1, glyph: unitGlyph(unit), colors: unitColors(unit), name: unitName(unit), flashing: controller.flashingPlayers.contains(i), clearLabel: t("clear")) { controller.removePlayer(at: i) }
                            } else {
                                Button { controller.toggleAssignTargetSlot(i) } label: {
                                    WaitingRow(number: i + 1, label: t("waiting"), selected: controller.assignTargetSlot == i)
                                }
                                .controllerButtonStyle(.plain)
                                .controllerID("controller.assign.slot.\(i)")
                                .controllerRingRadius(LauncherTheme.Metrics.controlRadius)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Button(t("cancel")) { controller.cancelAssign() }.controllerButtonStyle(LauncherSecondaryButtonStyle(fill: true)).controllerShortcut(.back)   // B
                            .controllerID("controller.assign.cancel")
                        Button(t("done")) { controller.finishAssign() }.controllerButtonStyle(LauncherPrimaryButtonStyle(fill: true))
                            // A 才通用（单只 Joy-Con 没有 ZR）：分配中焦点先落在「完成」，提示也显示 A；R2 / ZR 照样能按
                            .controllerShortcut(.primary, .rightTrigger).controllerPreferredFocus(true)
                            .controllerID("controller.assign.done")
                    }
                }
                .onAppear {
                    // 进分配画面焦点落在「完成」：按「分配玩家」那一下时这两颗还没注册，导航会先挑最左边的「取消」，等注册好再放一次
                    DispatchQueue.main.async { (padControls as? LauncherPadNavigation)?.focus("controller.assign.done") }
                    systems.watchAssign { controller.registerSystem(name: $0, index: $1) }
                    systems.watchGen1 { id, side, gesture in controller.registerGen1(id: id, side: side, gesture: gesture) }
                    // 键盘：分配中按任一键就登记成下一位（#520 讨论，不加提示）；这一下吞掉，不给 S2Arm 别处当快捷键 / 不响提示音
                    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { _ in controller.registerKeyboard(); return nil }
                }
                .onDisappear {
                    // 完成 / 取消回来：焦点回到「分配玩家」那颗（不然导航会挑最上面别的按钮，例如蓝牙设置）
                    DispatchQueue.main.async { (padControls as? LauncherPadNavigation)?.focus("controller.assign") }
                    systems.watchAssign(nil)
                    systems.watchGen1(nil)
                    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                    keyMonitor = nil
                }
            } else {
                let rows = playerRows
                if hasInputBesidesKeyboard || !rows.isEmpty {
                PanelSection {
                    if !rows.isEmpty {
                        SectionHeader(text: t("players"))
                        let firstOccupied = rows.firstIndex(where: { $0 != nil }) ?? 0
                        VStack(spacing: 8) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                if let row {
                                    // 点一行选中这一位（框线变奶油色）；按键时名字亮绿 + 按键小框照旧。平时不给 ×，分配中才有
                                    //   最右边一颗四键布局钮（键盘那一位没有）：盖在行上、不包进行的按钮里，点它不会先选中整行；
                                    //   任天堂手柄（Switch 2 / Switch Pro / Joy-Con）使用独立的四键配置，不与其他手柄共用
                                    let unit = controller.assignment.slots.indices.contains(index) ? controller.assignment.slots[index] : nil
                                    let faceMappable = unit.map(faceMappable) ?? false
                                    ZStack(alignment: .trailing) {
                                    Button { selectedPlayer = index } label: {
                                        PlayerRow(number: index + 1, glyph: row.glyph, colors: row.colors, name: row.name, selected: currentPlayer == index,
                                                  flashing: controller.flashingPlayers.contains(index), showKey: true, key: controller.flashingKeys[index],
                                                  reserve: faceMappable ? 32 : 0)
                                    }
                                    .controllerButtonStyle(.plain)
                                    .controllerID("controller.player.\(index)")
                                    .controllerRingRadius(LauncherTheme.Metrics.controlRadius)   // 玩家行圆角同主题控件
                                    // 面板一开手柄焦点先落在第一个在线玩家，不落在主按钮：连着时主按钮是「断开」，按 A 认手柄会把手柄断掉
                                    .controllerPreferredFocus(index == firstOccupied)
                                    .accessibilityLabel("P\(index + 1) \(row.name)")
                                    .accessibilityAddTraits(currentPlayer == index ? .isSelected : [])
                                    if faceMappable {
                                        Button { selectedPlayer = index; setFaceMap(!(showFaceMap && currentPlayer == index)) } label: {
                                            Image(systemName: "circle.grid.cross").font(.system(size: 13, weight: .semibold))
                                        }
                                        .controllerButtonStyle(LauncherIconButtonStyle(size: 28, cornerRadius: 8))
                                        .help(faceMapTitle)
                                        .accessibilityLabel("P\(index + 1) \(faceMapTitle)")
                                        .controllerID("controller.player.\(index).faceMap")
                                        .anchorPreference(key: FaceMapAnchorKey.self, value: .bounds) { index == currentPlayer ? $0 : nil }
                                        .padding(.trailing, 8)
                                    }
                                    }
                                } else {
                                    // 中间空槽（如 P1 或 P4 暂时断开、后面仍有玩家）：原位保留等待行，不隐藏后面的玩家槽
                                    WaitingRow(number: index + 1, label: t("waiting"))
                                }
                            }
                        }
                        .accessibilityIdentifier("controller.players")
                    }
                    // 「分配玩家」跟着玩家区块：有键盘以外的输入（或列表已有人）就显示，不要再改回「两只以上手柄才显示」。
                    //   键盘只能在分配画面按任一键加入成 P1–P8（登记过的跨次保留）；以前两只以上才显示时，
                    //   只接一只手柄就进不了分配画面、键盘加不进来，键盘 + 一只手柄时列表有 P1 + P2 也没有按钮，换不了顺序、也 × 不掉。
                    //   只有键盘时不显示：键盘本来就并进 P1，没有可分配的
                    Button(t("assignPlayers")) { controller.startAssign() }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle(fill: true))
                        .controllerID("controller.assign")
                }
                }
            }
        }
        .padding(20)
        .background(GeometryReader { g in Color.clear.preference(key: PanelContentHeightKey.self, value: g.size.height) })
        }
        // 内容多高面板就多高，封顶 heightLimit；超出部分在面板里滚动（量到之前先按内容自然高度排，不压成一条）
        .frame(height: contentHeight > 0 ? min(contentHeight, heightLimit) : nil)
        .onPreferenceChange(PanelContentHeightKey.self) { contentHeight = $0 }
        // 手柄 B：面板自己接住，不落到系统「取消」/ Esc（没人接时 macOS 会「叮」一声）。
        //   分配中 = 取消分配（同「取消」钮）；齿轮选单开着只关选单；其他时候关面板。一直挂着（用 if 切换会让整个面板换身份、状态重设）
        .controllerBackAction("controller.panel.back") {
            if controller.assigning { controller.cancelAssign() } else if showSettings { setSettings(false) }
            else if showFaceMap { setFaceMap(false) } else { onClose() }
        }
        .onAppear { controller.panelDidOpen(); startPressWatch() }   // 已被拒 / 这次没选就关了授权框：面板直接显示「允许蓝牙」
        .onDisappear { stopPressWatch(); controller.panelDidClose() }
        .frame(width: 380)   // 比稿（340）宽一些：标题不会整行撑满
        // 齿轮选单画在面板里（齿轮下方浮层），不另开弹窗：弹窗里再开弹窗时 macOS 会重建外层弹窗、沿用旧高度，
        //   面板内容被上下裁掉（11-16 实机：先没连、面板里连上后再开选单改开关就跑版）。同一窗口，手柄 / B 也简单
        .overlayPreferenceValue(GearAnchorKey.self) { anchor in
            GeometryReader { g in
                if showSettings, let anchor {
                    let gear = g[anchor]
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { setSettings(false) }
                            .accessibilityHidden(true)
                        Switch2SettingsMenu(controller: controller, lang: lang) { setSettings(false) }
                            .offset(x: max(10, min(gear.maxX - Switch2SettingsMenu.width, g.size.width - Switch2SettingsMenu.width - 10)), y: gear.maxY + 8)
                    }
                }
            }
        }
        // 四键布局：同齿轮选单的浮层，不另开弹窗、不改面板高度。方钮下方放得下就放下方，放不下贴着面板底边往上收
        .overlayPreferenceValue(FaceMapAnchorKey.self) { anchor in
            GeometryReader { g in
                if showFaceMap, let anchor {
                    let button = g[anchor]
                    let below = button.maxY + 8
                    let y = below + faceMapHeight + 10 <= g.size.height ? below : max(10, g.size.height - faceMapHeight - 10)
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { setFaceMap(false) }
                            .accessibilityHidden(true)
                        // 改了立刻生效（11-20：不要取消 / 确认，手柄操作才不会断一下）；B 由面板的返回键关浮层
                        ControllerFaceMappingEditor(store: controller.faceMaps, family: faceMapFamily, lang: lang)
                            .id(faceMapFamily)
                            .padding(20)   // 同面板内边距
                            .frame(width: Switch2SettingsMenu.width)
                            .launcherDropdownSurface()
                            .controllerScope("layer")   // 手柄方向键只在浮层里走（B 照样由面板接住、关浮层）
                            .onExitCommand { setFaceMap(false) }   // 键盘 Esc；手柄 B 由面板的 PanelBack 处理
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { faceMapHeight = $0 }
                            .offset(x: (g.size.width - Switch2SettingsMenu.width) / 2, y: y)
                    }
                }
            }
        }
        .background(.regularMaterial)
        .launcherDropdownHost()
        .preferredColorScheme(.dark)
    }
}

private struct FaceMapAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

private struct GearAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

extension Switch2ProConnectionPopover {
    /// 开 / 关齿轮选单：开时手柄焦点进第一个开关，关时回齿轮
    func setSettings(_ open: Bool) {
        showSettings = open
        let navigation = padControls as? LauncherPadNavigation
        DispatchQueue.main.async { navigation?.focus(open ? "controller.settings.autoConnect" : "controller.settings") }
    }
    /// 开 / 关四键浮层：开时手柄焦点进「四键布局」选单，关时回四键方钮
    func setFaceMap(_ open: Bool) {
        showFaceMap = open
        let navigation = padControls as? LauncherPadNavigation
        let back = "controller.player.\(currentPlayer).faceMap"
        DispatchQueue.main.async { navigation?.focus(open ? "controller.face.layout" : back) }
    }
}

// 认手柄：面板开着时，哪只手柄按了键，玩家列表那一行的名字亮一下（Switch 2 经连接程序、蓝牙手柄 / 一代 Joy-Con / 键盘在本进程读）
extension Switch2ProConnectionPopover {
    func startPressWatch() {
        controller.setPressWatch(true)
        // 分配中所有手柄都能操作界面：Switch 2 / 一代 Joy-Con 的按键转成导航动作（系统手柄本来就走 GameController 导航）
        let navigation = padControls as? LauncherPadNavigation
        controller.onAssignNavigate = { navigation?.handle($0) }
        systems.watchPress { name, index, key in controller.flashPlayer(key: key) { $0 == .system(name: name, index: index) } }
        systems.watchGen1Press { id, key in
            if controller.assigning, let key, let navigation,
               let action = Self.gen1AssignAction(id: id, key: key, units: controller.assignment.units, gen1: systems.gen1,
                   systemPads: GCController.controllers().map { (name: $0.vendorName ?? $0.productCategory, extended: $0.extendedGamepad != nil) }) {
                navigation.handle(action)
            }
            controller.flashPlayer(key: key) { unit in
                switch unit {
                case let .gen1(unitID, _): return unitID == id
                case let .gen1Pair(left, right): return left == id || right == id
                default: return false
                }
            }
        }
        if pressKeyMonitor == nil {
            // 分配中键盘另有用处（按任一键登记成一位，那边的监听会吞掉这一下），这里只在平时亮一下、不吞键
            pressKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if !controller.assigning { controller.flashPlayer(key: Self.keyLabel(event)) { $0 == .keyboard } }
                return event
            }
        }
    }
    /// 分配中一代 Joy-Con 的一下按键（HID 直读）→ 界面导航：已登记的照登记方式（单只横握、一对竖握），没登记的按这只的侧当横握；
    ///   系统已当整只手柄读的那一侧返回 nil（导航交给系统手柄那一路 LauncherPadInput，见 gen1ReadBySystem）
    nonisolated static func gen1AssignAction(id: String, key: String, units: [PlayerAssignment.Unit], gen1: [PlayerAssignment.Gen1Device],
                                             systemPads: [(name: String, extended: Bool)]) -> LauncherPadAction? {
        var side = -1, sideways = true
        for unit in units {
            if case let .gen1(unitID, s) = unit, unitID == id { side = s }
            if case let .gen1Pair(l, r) = unit, l == id || r == id { side = l == id ? 0 : 1; sideways = false }
        }
        if side < 0 { side = gen1.first { $0.id == id }?.side ?? 1 }
        guard !gen1ReadBySystem(side: side, systemPads: systemPads) else { return nil }
        return NS2LauncherController.padAction(gen1Key: key, side: side, sideways: sideways)
    }
    /// 一代 Joy-Con 这一侧（0 左只 / 1 右只）是否已被系统当整只手柄读（GameController 有 extendedGamepad 的「Joy-Con (L/R)」「Joy-Con (L)」等）：
    ///   是 = 分配中的导航交给系统手柄那一路，HID 直读只认手、亮行，不再换算导航
    nonisolated static func gen1ReadBySystem(side: Int, systemPads: [(name: String, extended: Bool)]) -> Bool {
        systemPads.contains { $0.extended && PlayerAssignment.gen1Sides($0.name).contains(side) }
    }
    /// 键盘按键 → 显示的字（最多两个字）
    static func keyLabel(_ event: NSEvent) -> String? {
        switch event.keyCode {
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 36, 76: return "↩"
        case 48: return "⇥"
        case 49: return "␣"
        case 51, 117: return "⌫"
        case 53: return "⎋"
        default:
            let text = (event.charactersIgnoringModifiers ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return text.isEmpty ? nil : String(text.prefix(2))
        }
    }
    func stopPressWatch() {
        controller.setPressWatch(false)
        controller.onAssignNavigate = nil
        systems.watchPress(nil)
        systems.watchGen1Press(nil)
        if let pressKeyMonitor { NSEvent.removeMonitor(pressKeyMonitor) }
        pressKeyMonitor = nil
    }
}

// 稿里的 .sec：上面一条细线、内容间距 12
private struct PanelContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PanelSection<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            content
        }
    }
}

// 区块小标头（Switch 2 / 蓝牙 / 玩家）：13 semibold、次要色
private struct SectionHeader: View {
    let text: String
    var body: some View { Text(text).font(.manrope(13, .semibold)).foregroundStyle(.secondary) }
}

// 状态行：8×8 圆点 + 15 semibold 次要色
private struct StatusLine: View {
    let color: NSColor
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(nsColor: color)).frame(width: 8, height: 8)
            Text(text).font(.manrope(15, .semibold)).foregroundStyle(.secondary)
        }
    }
}

// 齿轮选单：Switch 2 连接的持久化开关（行为与存法不变）；之后新设定加在这里
struct Switch2SettingsMenu: View {
    @ObservedObject var controller: NS2LauncherController
    let lang: String
    let close: () -> Void
    static let width: CGFloat = 360   // 稿上 300；Manrope 15 下英文开关字会折行，放宽到 360
    private func t(_ key: String) -> String { NS2LauncherController.text("s2arm.controller." + key, lang) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 开着时 S2Arm 一启动就连（不必打开面板）：起连接程序扫 10 秒，之后只挂着等记住的手柄回来，不持续扫描
            ToggleRow(label: t("autoConnect"),
                      isOn: Binding(get: { controller.autoConnectOnOpen }, set: { controller.setAutoConnectOnOpen($0) }))
                .controllerID("controller.settings.autoConnect")
            ToggleRow(label: t("disconnectOnClose"),
                      isOn: Binding(get: { controller.disconnectAfterGame }, set: { controller.setDisconnectAfterGame($0) }))
                .controllerID("controller.settings.disconnectOnClose")
        }
        .padding(16)
        .frame(width: Self.width)
        .launcherDropdownSurface()   // 同主题下拉：材质底、边框、阴影
        .onExitCommand { close() }   // 键盘 Esc：只关齿轮选单（手柄 B 由面板的 PanelBack 处理）
    }
}

// 稿里的 .row：左边一句、右边开关（没有副标题）
private struct ToggleRow: View {
    let label: String
    let isOn: Binding<Bool>
    var body: some View {
        HStack(spacing: 16) {
            Text(label).font(.manrope(15, .semibold))
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).toggleStyle(LauncherSwitchStyle()).labelsHidden().accessibilityLabel(label)
        }
    }
}

// 稿里的 .howto：深底小格，上面一行粗体、下面按键说明
private struct HowToTile: View {
    let title: String
    let keys: String
    var body: some View {
        VStack(spacing: 2) {   // 两行字间距 2（使用者 11-15 指定保留，不套 4 倍数）
            Text(title).font(.manrope(13, .semibold)).foregroundStyle(.primary)
            Text(keys).font(.manrope(12)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(8)
        // 主题的半透明控件底 + 边框（同按钮），不用不透明深灰：面板的材质与背景色透得出来
        .background(LauncherTheme.Colors.control, in: RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius, style: .continuous).strokeBorder(LauncherTheme.Colors.border))
    }
}

// 稿里的 .prow.empty：还没人登记的那一位——虚线框、玩家灯、「等待中」
private struct WaitingRow: View {
    let number: Int
    let label: String
    var selected: Bool = false
    var body: some View {
        HStack(spacing: 8) {
            Text("P\(number)").font(.manrope(12, .bold)).foregroundStyle(selected ? .primary : .secondary).frame(width: 20, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(playerLights(number)[i] ? Color(red: 0x7b / 255, green: 0xe0 / 255, blue: 0x1e / 255) : Color(red: 0x5a / 255, green: 0x57 / 255, blue: 0x53 / 255))
                        .frame(width: 8, height: 8)
                }
            }
            Text(label).font(.manrope(13, .semibold)).foregroundStyle(selected ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .overlay(
            RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius, style: .continuous)
                .strokeBorder(selected ? LauncherPalette.cream.opacity(0.7) : LauncherTheme.Colors.border,
                              style: selected ? StrokeStyle(lineWidth: 1.5) : StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}

// 玩家灯（同原机）：P1–P4 亮 1–4 格，P5–P8 是 ●○○● / ●○●○ / ●○●● / ○●●○
func playerLights(_ number: Int) -> [Bool] {
    switch number {
    case 1: return [true, false, false, false]
    case 2: return [true, true, false, false]
    case 3: return [true, true, true, false]
    case 4: return [true, true, true, true]
    case 5: return [true, false, false, true]
    case 6: return [true, false, true, false]
    case 7: return [true, false, true, true]
    case 8: return [false, true, true, false]
    default: return [false, false, false, false]
    }
}

// 「玩家」列表的一行，照 #520 UI 稿 .prow：P 号、四格玩家灯（亮到第 P 格）、40×28 的手柄图、名称
private struct PlayerRow: View {
    let number: Int
    let glyph: ControllerIcon.Glyph
    var colors: ControllerColors = .none
    let name: String
    var selected = false   // 平时列表里点选的那一位：框线奶油色
    var flashing = false   // 这只手柄刚按了键：名字亮一下（玩家灯同色，比边框明显）
    var showKey = false    // 平时的玩家列表：最右边留一个按键小框（分配中不放）
    var key: String?       // 亮着时按的是哪个键
    var clearLabel = ""
    var onClear: (() -> Void)?
    var reserve: CGFloat = 0   // 最右边留给盖在行上的小钮（四键布局）

    private static let ledOn = Color(red: 0x7b / 255, green: 0xe0 / 255, blue: 0x1e / 255)
    private static let ledOff = Color(red: 0x5a / 255, green: 0x57 / 255, blue: 0x53 / 255)

    var body: some View {
        HStack(spacing: 8) {
            Text("P\(number)").font(.manrope(12, .bold)).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(playerLights(number)[i] ? Self.ledOn : Self.ledOff).frame(width: 8, height: 8)
                }
            }
            ControllerIcon(glyph: glyph, colors: colors).frame(width: 40, height: 28)
            Text(name).font(.manrope(13, .semibold)).lineLimit(1).truncationMode(.tail).help(name)   // 列表里的名称太长照截断（悬停看全名）
                .foregroundStyle(flashing ? Self.ledOn : Color.primary)
                .animation(.easeOut(duration: flashing ? 0.05 : 0.35), value: flashing)
            Spacer(minLength: 8)
            // 按键小框：有边线的 chip，宽度跟字走（至少两个字宽）；亮着才显示（按的哪个键），平时透明但位置保留，名字截断在它前面
            if showKey {
                Group {
                    // 「sf:」开头 = 长宽一致的图示（方向、PlayStation ✕ ○ □ △），其余照字写
                    if let key, key.hasPrefix("sf:") { Image(systemName: String(key.dropFirst(3))).font(.system(size: 10, weight: .bold)).frame(width: 12, height: 12) }
                    else { Text(key ?? "").font(.manrope(12, .bold)).lineLimit(1).fixedSize() }
                }
                    .foregroundStyle(Self.ledOn)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 32, minHeight: 20)
                    .overlay(Capsule().stroke(Self.ledOn, lineWidth: 1))
                    .opacity(flashing && key != nil ? 1 : 0)
                    .animation(.easeOut(duration: flashing ? 0.05 : 0.35), value: flashing)
                    .accessibilityHidden(true)
            }
            // 最右边一个小 ×：清空这一位；名字截断在它前面，不会盖住
            if let onClear {
                Button(action: onClear) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .controllerButtonStyle(.plain)
                .help(clearLabel)
                .accessibilityLabel(clearLabel)
            }
            if reserve > 0 { Color.clear.frame(width: reserve - 4, height: 1).accessibilityHidden(true) }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        // 主题的半透明控件底 + 边框（同按钮）；选中那一位框线奶油色
        .background(LauncherTheme.Colors.control, in: RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius, style: .continuous).strokeBorder(selected ? LauncherPalette.cream.opacity(0.7) : LauncherTheme.Colors.border))
        .accessibilityElement(children: .contain)
    }
}

