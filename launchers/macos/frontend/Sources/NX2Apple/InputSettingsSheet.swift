// S2Arm（不是上游文件）：手柄 / 键位设置弹窗（同旧启动器 InputEditor：看键位、改键、恢复默认、保存）。
// 左边是 Joy-Con 按键图（自旧启动器 ControllerMap 搬来），点一个键在右边改它的键盘 / 鼠标 / 手柄绑定；下面是鼠标与摇杆选项。
// 保存走 saveInput 作业（S2ArmLauncherModel+Input），成了自动关；没成的原因留在弹窗里。改键下次开始游戏时生效。
import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct InputSettingsSheet: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    let gameID: String
    @State private var config = InputConfig.standard
    @State private var baseline = InputConfig.standard
    @State private var loaded = false
    @State private var loadProblem = false
    @State private var selected = "A"
    @State private var recording: String?
    @State private var saving = false
    @State private var failure: String?

    init(model: S2ArmLauncherModel, gameID: String) {
        self.model = model
        self.gameID = gameID
    }

    private var language: String { loc.lang == .zh ? "zh-Hans" : "en" }
    private func t(_ id: String) -> String { BackendText.launcherText("input." + id, language: language) }

    /// 要绑的键已经给了别的功能（v0.3.1：原先存成冲突、保存键置灰，玩家被挡住）：先问「改给这个功能？」，确认就解开旧绑定再绑（摇杆两边互换方向），
    ///   存进去的配置照样没有重复绑定（运行时 input_config.c、作业层 validate_input 都拒收重复）
    struct Rebind: Identifiable { let id = UUID(); let kind: String; let key: String; let from: String; let to: String; let apply: () -> Void }
    @State private var rebind: Rebind?
    private func bind(_ kind: String, key: String, target: String, holder: String?, apply: @escaping () -> Void) {
        if let holder, holder != target { rebind = Rebind(kind: kind, key: key, from: holder, to: target, apply: apply) } else { apply() }
    }
    private func rebindText(_ r: Rebind) -> String {
        let name = { (x: String) in r.kind == "axes" ? names.axis(x) : names.target(x) }
        return t(r.kind == "axes" ? "rebind.axes" : "rebind.body").replacingOccurrences(of: "{0}", with: name(r.from))
            .replacingOccurrences(of: "{1}", with: name(r.to)).replacingOccurrences(of: "{2}", with: r.key)
    }
    private func setKey(_ key: KeyBinding, for target: String) {
        let holder = config.keyboard.first { $0.key != target && $0.value == key }?.key
        bind("keyboard", key: names.key(key), target: target, holder: holder) {
            if let holder { config.keyboard[holder] = nil }
            config.keyboard[target] = key; failure = nil
        }
    }
    private var names: InputNames { InputNames(text: t) }
    private var game: GameSummary? { model.games.first { $0.id == gameID } }
    private var canSave: Bool { loaded && !saving && recording == nil && config.conflicts.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 16) {
                        InputControllerMap(config: config, selected: $selected, recording: recording, names: names, text: t) { _ in recording = nil }
                        selectedPanel.frame(maxWidth: .infinity)
                    }
                    if !config.conflicts.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(config.conflicts.enumerated()), id: \.offset) { _, c in
                                Text(conflictText(c)).font(.manrope(12.5)).foregroundStyle(LauncherPalette.danger)
                            }
                        }
                    }
                    CardGroup(loc.lang == .zh ? "Switch 2 Pro 背键" : "Switch 2 Pro back buttons",
                              footnote: loc.lang == .zh ? "按游戏保存，下次开始游戏时生效。原有按键仍可正常使用。" : "Saved per game; applies on the next launch. Original buttons remain available.") {
                        ForEach(["GL", "GR"], id: \.self) { side in
                            CardRow(side) {
                                LauncherDropdown(options: [("", t("unbound"))] + Array(zip(InputConfig.padCodes, InputConfig.targets.prefix(16))).map { ($0.0, names.target($0.1)) },
                                                 selection: config.backButtons?[side] ?? "", label: side, style: .button) { value in
                                    var back = config.backButtons ?? [:]
                                    back[side] = value.isEmpty ? nil : value
                                    config.backButtons = back.isEmpty ? nil : back
                                    failure = nil
                                }
                            }
                        }
                    }
                    options
                }
                .padding(.horizontal, 30).padding(.bottom, 24)
            }
            Divider().opacity(0.3)
            footer
        }
        .alert(t("rebind.title"), isPresented: Binding(get: { rebind != nil }, set: { if !$0 { rebind = nil } })) {
            Button(t("rebind.confirm")) { rebind?.apply(); rebind = nil }
            Button(t("cancel"), role: .cancel) { rebind = nil }
        } message: { Text(rebind.map(rebindText) ?? "") }
        .background(InputKeyRecorder(active: recording != nil) { key in
            if let target = recording, let key { setKey(key, for: target) }
            recording = nil
        })
        .onAppear {
            guard !loaded else { return }
            let input = model.loadInput(gameID: gameID)
            config = input.config; baseline = input.config; loadProblem = input.problem; loaded = true
        }
        .frame(width: 640, height: 720)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
        .launcherDropdownHost()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t("title")).font(.manrope(26, .heavy)).tracking(-0.6)
            Text(game?.name ?? gameID).font(.manrope(14, .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Text(t("subtitle")).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if loadProblem {
                Text(t("loadProblem")).font(.manrope(12.5)).foregroundStyle(LauncherPalette.building)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        }
        .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 18)
    }

    // ---- 选中的那个键 ----

    private var selectedPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t("selected")).font(.manrope(12)).foregroundStyle(.secondary)
                Text(names.target(selected)).font(.manrope(20, .heavy)).foregroundStyle(LauncherPalette.cream)
            }
            VStack(alignment: .leading, spacing: 7) {
                Label(t("keyboard"), systemImage: "keyboard").font(.manrope(13, .semibold))
                keyField
                LauncherDropdown(options: [("", t("key.common"))] + Self.commonKeys.map { (String($0), names.key(KeyBinding(code: $0))) },
                                 selection: "", label: t("key.common"), style: .button, fill: true) { value in
                    if let code = Int(value) { setKey(KeyBinding(code: code), for: selected) }
                    recording = nil
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Label(t("mouse"), systemImage: "computermouse").font(.manrope(13, .semibold))
                LauncherDropdown(options: [("", t("unbound"))] + (0...4).map { (String($0), names.mouseButton($0)) },
                                 selection: config.mouse[selected].map(String.init) ?? "", label: t("mouse"), style: .button, fill: true, leading: true) { value in
                    recording = nil
                    let button = Int(value), target = selected
                    let holder = button.flatMap { b in config.mouse.first { $0.key != target && $0.value == b }?.key }
                    bind("mouse", key: button.map(names.mouseButton) ?? "", target: target, holder: holder) {
                        if let holder { config.mouse[holder] = nil }
                        config.mouse[target] = button; failure = nil
                    }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Label(t("gamepad"), systemImage: "gamecontroller").font(.manrope(13, .semibold))
                LauncherDropdown(options: [("", t("unbound"))] + InputConfig.padCodes.map { ($0, names.pad($0)) },
                                 selection: config.gamepad[selected] ?? "", label: t("gamepad"), style: .button, fill: true, leading: true) { value in
                    recording = nil
                    let pad = value.isEmpty ? nil : value, target = selected
                    let holder = pad.flatMap { p in config.gamepad.first { $0.key != target && $0.value == p }?.key }
                    bind("gamepad", key: pad.map(names.pad) ?? "", target: target, holder: holder) {
                        if let holder { config.gamepad[holder] = nil }
                        config.gamepad[target] = pad; failure = nil
                    }
                }
            }
            if config.conflictingTargets.contains(selected) {
                Label(t("conflict.here"), systemImage: "exclamationmark.triangle").font(.manrope(12.5)).foregroundStyle(LauncherPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { config.restoreTarget(selected, from: baseline); recording = nil } label: { Text(t("restoreKey")).frame(maxWidth: .infinity) }
                .buttonStyle(LauncherSecondaryButtonStyle())
            Text(t("iconNote")).font(.manrope(11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
    }

    /// 键盘绑定：点一下进入录入（按新键，Esc 取消），右侧 × 清掉。
    private var keyField: some View {
        let on = recording == selected
        return Button { recording = on ? nil : selected } label: {
            Text(on ? t("key.record") : names.key(config.keyboard[selected]))
                .font(.manrope(14, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.leading, 12).padding(.trailing, 36)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(on ? LauncherPalette.cream.opacity(0.10) : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(on ? LauncherPalette.cream : Color.white.opacity(0.10), lineWidth: on ? 1.5 : 1).allowsHitTesting(false))
        .overlay(alignment: .trailing) {
            Button { config.keyboard[selected] = nil; recording = nil } label: {
                Image(systemName: "xmark.circle").frame(width: 30, height: 38).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(t("key.clear")).padding(.trailing, 4)
        }
        .accessibilityLabel(t("keyboard")).accessibilityValue(names.key(config.keyboard[selected]))
    }

    /// 「常用键」里给的键（Return、Esc、空格、Tab、Shift、Ctrl、Option）：Esc 录入时是取消键，只能从这里选。
    private static let commonKeys = [36, 53, 49, 48, 56, 59, 58]

    // ---- 鼠标与摇杆 ----

    private var options: some View {
        VStack(alignment: .leading, spacing: 20) {
            CardGroup(t("mouseOptions"), footnote: t("mouseOptions.note")) {
                CardRow(t("mouse.mode")) {
                    LauncherSegmented(options: [("camera", t("mouse.mode.camera")), ("off", t("mouse.mode.off"))],
                                      selection: config.mouseOptions.mode) { config.mouseOptions.mode = $0 }
                        .frame(width: 240)
                }
                CardDivider()
                slider(t("mouse.sensX"), value: config.mouseOptions.sensitivityX, range: 0.1...10, step: 0.1,
                       readout: String(format: "%.1f", config.mouseOptions.sensitivityX)) { config.mouseOptions.sensitivityX = $0 }
                CardDivider()
                slider(t("mouse.sensY"), value: config.mouseOptions.sensitivityY, range: 0.1...10, step: 0.1,
                       readout: String(format: "%.1f", config.mouseOptions.sensitivityY)) { config.mouseOptions.sensitivityY = $0 }
                CardDivider()
                toggle(t("mouse.invertX"), $config.mouseOptions.invertX)
                CardDivider()
                toggle(t("mouse.invertY"), $config.mouseOptions.invertY)
                CardDivider()
                toggle(t("mouse.recenter"), $config.mouseOptions.recenter)
            }
            CardGroup(t("sticks"), footnote: t("sticks.note")) {
                slider(t("deadzone"), value: config.deadzone, range: 0...0.8, step: 0.01,
                       readout: String(format: "%.0f%%", config.deadzone * 100)) { config.deadzone = $0 }
                ForEach(InputConfig.axisTargets, id: \.self) { target in
                    CardDivider()
                    CardRow(names.axis(target)) {
                        HStack(spacing: 8) {
                            Text(t("axis.invert")).font(.manrope(12.5)).foregroundStyle(.secondary)
                            Toggle("", isOn: Binding(get: { config.axes[target]?.invert ?? false },
                                                     set: { config.axes[target] = AxisBinding(source: config.axes[target]?.source ?? Self.ownSource(target), invert: $0) }))
                                .toggleStyle(LauncherSwitchStyle()).labelsHidden().accessibilityLabel(names.axis(target) + " " + t("axis.invert"))
                                .padding(.trailing, 4)
                            LauncherDropdown(options: InputConfig.axisSources.map { ($0, names.axis($0)) },
                                             selection: config.axes[target]?.source ?? Self.ownSource(target), label: names.axis(target), style: .button) { source in
                                let old = config.axes[target]?.source ?? Self.ownSource(target)
                                let holder = config.axes.first { $0.key != target && $0.value.source == source }?.key
                                bind("axes", key: names.axis(source), target: target, holder: holder) {   // 摇杆不能留空：两边互换方向
                                    if let holder { config.axes[holder] = AxisBinding(source: old, invert: config.axes[holder]?.invert ?? false) }
                                    config.axes[target] = AxisBinding(source: source, invert: config.axes[target]?.invert ?? false)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func ownSource(_ target: String) -> String {
        ["LX": "leftX", "LY": "leftY", "RX": "rightX", "RY": "rightY"][target] ?? "leftX"
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, step: Double, readout: String,
                        change: @escaping (Double) -> Void) -> some View {
        CardRow(title) {
            HStack(spacing: 12) {
                LauncherSlider(value: value, range: range, step: step, change: change).frame(width: 180)
                Text(readout).font(.manrope(12.5, .semibold)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
        }
    }

    private func toggle(_ title: String, _ isOn: Binding<Bool>) -> some View {
        CardRow(title) { Toggle("", isOn: isOn).toggleStyle(LauncherSwitchStyle()).labelsHidden().accessibilityLabel(title) }
    }

    // ---- 底栏 ----

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if saving {
                ProgressView().progressViewStyle(.linear).tint(LauncherPalette.cream)
            }
            if let failure {
                Text(failure).font(.manrope(12.5)).foregroundStyle(LauncherPalette.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(t("restoreDefault")) { config = .standard; recording = nil; failure = nil }
                    .buttonStyle(LauncherSecondaryButtonStyle()).disabled(saving)
                LauncherDropdown(options: [("", t("preset"))] + InputConfig.Preset.allCases.map { ($0.rawValue, t("preset." + $0.rawValue)) },
                                 selection: "", label: t("preset"), style: .button) { value in
                    if let p = InputConfig.Preset(rawValue: value) { config = .preset(p); failure = nil }
                    recording = nil
                }
                .disabled(saving)
                Spacer(minLength: 8)
                if saving {
                    Text(t("saving")).font(.manrope(12)).foregroundStyle(.secondary)
                } else if config != baseline {
                    Text(t("unsaved")).font(.manrope(12)).foregroundStyle(.secondary)
                }
                Button(t("cancel")) { dismiss() }
                    .buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.cancelAction).disabled(saving)
                Button { save() } label: {
                    Text(t("save")).font(.manrope(13.5, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(LauncherPalette.cream, in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(!canSave).opacity(canSave ? 1 : 0.45)
            }
        }
        .padding(.horizontal, 30).padding(.vertical, 16)
    }

    private func save() {
        guard canSave else { return }
        saving = true; failure = nil
        let config = config
        Task {
            do {
                try await model.saveInput(config, gameID: gameID)
                baseline = config; saving = false
                dismiss()
            } catch {
                failure = names.saveFailure(error.localizedDescription, backend: loc.backend)
                saving = false
            }
        }
    }

    private func conflictText(_ c: InputConfig.Conflict) -> String {
        let a = c.kind == "axes" ? names.axis(c.first) : names.target(c.first)
        let b = c.kind == "axes" ? names.axis(c.second) : names.target(c.second)
        return t("conflict." + c.kind).replacingOccurrences(of: "{0}", with: a).replacingOccurrences(of: "{1}", with: b)
    }
}

/// 键位里各样东西的显示名（文案全在共享规格 launcher.items 的 input.*）。A / B / X / Y / L / R / ZL / ZR 与键帽符号两种语言相同，不进文案。
struct InputNames {
    let text: (String) -> String

    func target(_ t: String) -> String {
        ["A","B","X","Y","L","R","ZL","ZR"].contains(t) ? t : text("target." + t)
    }
    func pad(_ code: String) -> String { text("pad." + code) }
    /// 摇杆轴（LX…）与它的来源（leftX…）同名。
    func axis(_ code: String) -> String {
        text("axis." + (["leftX": "LX", "leftY": "LY", "rightX": "RX", "rightY": "RY"][code] ?? code))
    }
    func mouseButton(_ code: Int) -> String { (0...4).contains(code) ? text("mouseButton.\(code)") : text("unbound") }

    func key(_ b: KeyBinding?) -> String {
        guard let b else { return text("unbound") }
        let keys: [Int: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"Return",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",49:text("key.space"),50:"`",51:text("key.delete"),53:"Esc",56:"Shift",58:"Option",59:"Ctrl",123:"←",124:"→",125:"↓",126:"↑"]
        let mods = (b.modifiers & 1 != 0 ? "⇧" : "") + (b.modifiers & 2 != 0 ? "⌃" : "") + (b.modifiers & 4 != 0 ? "⌥" : "")
        return mods + (keys[b.code] ?? text("key.code").replacingOccurrences(of: "{0}", with: String(b.code)))
    }

    /// 键位图上一个键底下的小字：先键盘，再鼠标，只有手柄时写「手柄」。
    func short(_ config: InputConfig, _ target: String) -> String {
        if let binding = config.keyboard[target] { return key(binding) }
        if let button = config.mouse[target] { return mouseButton(button) }
        return config.gamepad[target] == nil ? text("unbound") : text("short.gamepad")
    }

    /// 保存没成的原因：作业层 validate_input 的几句换成玩家看得懂的话，其余照作业层原句（经 loc.backend 翻）。
    func saveFailure(_ message: String, backend: (String) -> String) -> String {
        let known = ["不支持的输入映射格式。": "format", "输入映射不完整。": "incomplete", "无效输入目标。": "target", "无效键盘映射。": "keyboard",
                     "无效鼠标映射。": "mouse", "无效手柄映射。": "gamepad", "无效摇杆映射。": "axis", "输入映射存在重复绑定。": "duplicate",
                     "摇杆死区必须在 0 到 1 之间。": "deadzone", "无效鼠标选项。": "mouseOptions", "鼠标灵敏度必须在 0.1 到 10 之间。": "sensitivity"]
        if let id = known[message] { return text("error." + id) }
        return text("error.failed").replacingOccurrences(of: "{0}", with: backend(message))
    }
}

/// 录键：录入时接本窗口的按键（同旧启动器 EventRecorder 的规则）。Esc 取消（交回 nil）；带 ⌘ 的不收；左右修饰键并成一个；
/// 单按 Shift / Ctrl / Option 录成那个键，同时按着修饰键再按别的键录成组合。录入时按键不再往下传（不触发弹窗的快捷键）。
struct InputKeyRecorder: NSViewRepresentable {
    var active: Bool
    var onKey: (KeyBinding?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView { let v = NSView(); context.coordinator.install(v); return v }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.parent = self }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }

    final class Coordinator {
        var parent: InputKeyRecorder
        var monitor: Any?
        weak var view: NSView?
        init(_ parent: InputKeyRecorder) { self.parent = parent }
        func install(_ v: NSView) {
            view = v
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
                guard let self, self.parent.active, NSApp.isActive, self.view?.window?.isKeyWindow == true else { return e }
                if e.type == .keyUp { return nil }
                if e.modifierFlags.contains(.command) { return e }
                let code = [60: 56, 62: 59, 61: 58][Int(e.keyCode)] ?? Int(e.keyCode)
                var mods = (e.modifierFlags.contains(.shift) ? 1 : 0) | (e.modifierFlags.contains(.control) ? 2 : 0) | (e.modifierFlags.contains(.option) ? 4 : 0)
                if e.type == .flagsChanged {
                    let bit = code == 56 ? 1 : code == 59 ? 2 : code == 58 ? 4 : 0
                    if bit == 0 || mods & bit == 0 { return e }   // 松开修饰键不算
                    mods = 0
                }
                let key: KeyBinding? = e.type == .keyDown && code == 53 ? nil : KeyBinding(code: code, modifiers: mods)
                DispatchQueue.main.async { self.parent.onKey(key) }
                return nil
            }
        }
        func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

/// Switch 的按键位置（不是 Xbox 字母）：A 在右、B 在下、X 在上、Y 在左。
enum ControllerMapLayout {
    static let face = [["", "X", ""], ["Y", "", "A"], ["", "B", ""]]
    static let dpad = [["", "UP", ""], ["LEFT", "", "RIGHT"], ["", "DOWN", ""]]
}

/// 一代 Joy-Con 正面比例（任天堂规格 H102 × W35.9 mm），各键位置按任天堂支持页正面图标定（同旧启动器 ControllerMap），
/// 整体缩到弹窗里放得下的高度；圆形按键保持正圆。
enum JoyConGeometry {
    static let height: CGFloat = 340
    static let width: CGFloat = height * 35.9 / 102
    static let upperY: CGFloat = height * 0.255
    static let lowerY: CGFloat = height * 0.535
    static let auxiliaryY: CGFloat = height * 0.72
    static let clusterStep: CGFloat = height * 0.075
    static let buttonDiameter: CGFloat = height * 0.076
    static let stickDiameter: CGFloat = height * 0.156
    static let blue = Color(red: 0, green: 0.765, blue: 0.890)
    static let red = Color(red: 1, green: 0.271, blue: 0.329)
    static let ink = Color(red: 0.17, green: 0.18, blue: 0.20)
}

/// 一只 Joy-Con 的轮廓（内侧是平的滑轨），矢量画；按键是单独的原生按钮，不是截图。
struct JoyConShell: Shape {
    var right = false
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, radius = rect.width * 0.61
        var p = Path()
        p.move(to: CGPoint(x: w - 9, y: 0))
        p.addLine(to: CGPoint(x: radius, y: 0))
        p.addCurve(to: CGPoint(x: 0, y: radius), control1: CGPoint(x: radius * 0.45, y: 0), control2: CGPoint(x: 0, y: radius * 0.45))
        p.addLine(to: CGPoint(x: 0, y: h - radius))
        p.addCurve(to: CGPoint(x: radius, y: h), control1: CGPoint(x: 0, y: h - radius * 0.45), control2: CGPoint(x: radius * 0.45, y: h))
        p.addLine(to: CGPoint(x: w - 9, y: h))
        p.addQuadCurve(to: CGPoint(x: w, y: h - 9), control: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: w, y: 9))
        p.addQuadCurve(to: CGPoint(x: w - 9, y: 0), control: CGPoint(x: w, y: 0))
        p.closeSubpath()
        return right ? p.applying(CGAffineTransform(translationX: w, y: 0).scaledBy(x: -1, y: 1)) : p
    }
}

/// 两只 Joy-Con 并排，每个键可点；肩键底下写着它现在的绑定，有重复的键描红框，选中的描奶油色框。
struct InputControllerMap: View {
    let config: InputConfig
    @Binding var selected: String
    var recording: String?
    let names: InputNames
    let text: (String) -> String
    var onSelect: ((String) -> Void)?

    init(config: InputConfig, selected: Binding<String>, recording: String?, names: InputNames, text: @escaping (String) -> String,
         onSelect: ((String) -> Void)? = nil) {
        self.config = config; _selected = selected; self.recording = recording; self.names = names; self.text = text; self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text("map.title")).font(.manrope(13, .semibold))
                Text(text("map.hint")).font(.manrope(11.5)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 20) {
                joycon(right: false)
                joycon(right: true)
            }
            Text(text("map.note")).font(.manrope(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(width: JoyConGeometry.width * 2 + 20, alignment: .leading)
        }
        .padding(14)
        .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
    }

    private func pick(_ target: String) { selected = target; onSelect?(target) }

    private func joycon(right: Bool) -> some View {
        let w = JoyConGeometry.width, h = JoyConGeometry.height
        return VStack(spacing: 6) {
            HStack(spacing: 6) { key(right ? "R" : "ZL", wide: true); key(right ? "ZR" : "L", wide: true) }
            ZStack {
                JoyConShell(right: right)
                    .fill(right ? JoyConGeometry.red : JoyConGeometry.blue)
                    .overlay(JoyConShell(right: right).stroke(.black.opacity(0.20), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.25), radius: 7, y: 5)
                RoundedRectangle(cornerRadius: 2).fill(JoyConGeometry.ink.opacity(0.28)).frame(width: 4, height: h * 0.94)
                    .position(x: right ? 3 : w - 3, y: h * 0.50).accessibilityHidden(true)
                key(right ? "PLUS" : "MINUS", auxiliary: true).position(x: w * (right ? 0.22 : 0.78), y: h * 0.10)
                if right {
                    cluster(ControllerMapLayout.face).position(x: w / 2, y: JoyConGeometry.upperY)
                    stick(right: true).position(x: w / 2, y: JoyConGeometry.lowerY)
                } else {
                    stick(right: false).position(x: w / 2, y: JoyConGeometry.upperY)
                    cluster(ControllerMapLayout.dpad).position(x: w / 2, y: JoyConGeometry.lowerY)
                }
                Image(systemName: right ? "house.fill" : "record.circle")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.82))
                    .frame(width: 20, height: 20)
                    .background(JoyConGeometry.ink.opacity(0.84), in: right ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))
                    .position(x: w * (right ? 0.35 : 0.65), y: JoyConGeometry.auxiliaryY).accessibilityHidden(true)
            }
            .frame(width: w, height: h)
        }
    }

    private func cluster(_ rows: [[String]]) -> some View {
        let side = JoyConGeometry.width, mid = side / 2
        return ZStack {
            ForEach(rows.indices, id: \.self) { row in
                ForEach(rows[row].indices, id: \.self) { column in
                    let target = rows[row][column]
                    if !target.isEmpty {
                        key(target).position(x: mid + CGFloat(column - 1) * JoyConGeometry.clusterStep, y: mid + CGFloat(row - 1) * JoyConGeometry.clusterStep)
                    }
                }
            }
        }
        .frame(width: side, height: side)
    }

    private func stick(right: Bool) -> some View {
        let prefix = right ? "RS" : "LS", side = JoyConGeometry.width, mid = side / 2, reach = side * 0.34
        return ZStack {
            key(prefix, onStick: true).position(x: mid, y: mid)
            direction(prefix + "_UP", symbol: "arrow.up").position(x: mid, y: mid - reach)
            direction(prefix + "_DOWN", symbol: "arrow.down").position(x: mid, y: mid + reach)
            direction(prefix + "_LEFT", symbol: "arrow.left").position(x: mid - reach, y: mid)
            direction(prefix + "_RIGHT", symbol: "arrow.right").position(x: mid + reach, y: mid)
        }
        .frame(width: side, height: side)
    }

    private func direction(_ target: String, symbol: String) -> some View {
        let active = selected == target
        return Button { pick(target) } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .foregroundStyle(config.conflictingTargets.contains(target) ? LauncherPalette.danger : JoyConGeometry.ink)
                .background(active ? Color.white.opacity(0.95) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(active ? LauncherPalette.cream : .clear, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(names.target(target)).accessibilityValue(names.short(config, target))
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .help(names.target(target) + " · " + names.short(config, target))
    }

    private func key(_ target: String, wide: Bool = false, onStick: Bool = false, auxiliary: Bool = false) -> some View {
        let active = selected == target
        let conflict = config.conflictingTargets.contains(target)
        let symbol: String? = ["UP": "arrow.up", "DOWN": "arrow.down", "LEFT": "arrow.left", "RIGHT": "arrow.right"][target]
        let label = ["MINUS": "−", "PLUS": "+", "LS": "L3", "RS": "R3"][target] ?? target
        let diameter = onStick ? JoyConGeometry.stickDiameter : auxiliary ? 18 : JoyConGeometry.buttonDiameter
        let shape = RoundedRectangle(cornerRadius: wide ? 7 : diameter / 2)
        return Button { pick(target) } label: {
            VStack(spacing: 3) {
                Group {
                    if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                    else { Text(label).font(.system(size: onStick ? 12 : auxiliary ? 13 : 10.5, weight: .semibold, design: .rounded)) }
                }
                .frame(width: wide ? 52 : diameter, height: wide ? 26 : diameter)
                .foregroundStyle(.white)
                .background(JoyConGeometry.ink, in: shape)
                .overlay(shape.strokeBorder(conflict ? LauncherPalette.danger : active ? LauncherPalette.cream : .black.opacity(0.30),
                                            lineWidth: active || conflict ? 2.5 : 1))
                .shadow(color: .black.opacity(onStick ? 0.25 : 0.08), radius: onStick ? 3 : 1, y: onStick ? 3 : 1)
                if wide {
                    Text(recording == target ? "…" : names.short(config, target))
                        .font(.manrope(10, active ? .bold : .medium))
                        .foregroundStyle(conflict ? LauncherPalette.danger : .secondary)
                        .lineLimit(1).minimumScaleFactor(0.7).frame(width: 54)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(names.target(target)).accessibilityValue(names.short(config, target))
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .help(names.target(target) + " · " + names.short(config, target))
    }
}
