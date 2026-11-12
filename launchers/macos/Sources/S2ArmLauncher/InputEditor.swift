// UI adapted from LumaDock (MIT); see ../../README.md.
import SwiftUI
import AppKit
import GameController

@MainActor final class ControllerMonitor: ObservableObject {
    @Published var name = L("未连接手柄")
    @Published var value = L("等待输入")
    var observers: [NSObjectProtocol] = []
    init() {
        for n in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] { observers.append(NotificationCenter.default.addObserver(forName:n,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.refresh() } }) }
        refresh()
    }
    func refresh() {
        for c in GCController.controllers() {c.extendedGamepad?.valueChangedHandler=nil}
        guard let c = GCController.controllers().first,let pad=c.extendedGamepad else {name=L("未连接手柄");value=L("所有输入已清空");return}
        name=c.vendorName ?? L("已连接手柄")
        pad.valueChangedHandler = { [weak self] p,_ in DispatchQueue.main.async {
            guard let self else {return}
            self.value=String(format:L("左摇杆 %.2f, %.2f · 右摇杆 %.2f, %.2f · L2 %.2f · R2 %.2f"),p.leftThumbstick.xAxis.value,p.leftThumbstick.yAxis.value,p.rightThumbstick.xAxis.value,p.rightThumbstick.yAxis.value,p.leftTrigger.value,p.rightTrigger.value)
            if p.buttonA.isPressed {self.value += " · south"};if p.buttonB.isPressed{self.value += " · east"};if p.buttonX.isPressed{self.value += " · west"};if p.buttonY.isPressed{self.value += " · north"}
        } }
    }
    deinit {for o in observers {NotificationCenter.default.removeObserver(o)}}
}
struct InputEditor: View {
    @EnvironmentObject var store: Store
    let game: Game?
    @State var config: InputConfig
    @State private var baseline: InputConfig
    @State private var selectedTarget = "A"
    @State private var recording: String?
    @State private var test = false
    @State private var testText = L("点击“开始输入测试”后按键或移动鼠标")
    @State private var tab = "bindings"
    @StateObject private var controller = ControllerMonitor()
    init(game:Game?,initial:InputConfig,initialTab:String = "bindings") { self.game=game;_config=State(initialValue:initial);_baseline=State(initialValue:initial);_tab=State(initialValue:initialTab) }
    var body: some View {
        PlatformGlassContainer(spacing:4) {
        VStack(alignment:.leading,spacing:WorkspaceLayout.sectionSpacing) {
            WorkspaceHeading(title:game.map {"\($0.name) · 输入映射"} ?? "全局输入映射",subtitle:"保存后在下次启动游戏时生效，无需重新编译。",symbol:"gamecontroller") {
                Button(L("关闭")) {store.editingInput=false}.platformButtonStyle().tint(nil as Color?).keyboardShortcut(.cancelAction)
            }
            if !(game?.inputConfig ?? store.engineSupportsInput) {
                VStack(alignment:.leading,spacing:2) {
                    Text(L("当前引擎未声明 S2A_INPUT_CONFIG 支持。映射可保存，但游戏将使用引擎自己的默认操作；选择支持该接口的引擎并重新编译后才会应用。")).font(.caption).foregroundStyle(.orange)
                    // 具体原因来自宿主二进制的实际探测（toolchain.input_interface），不是笼统一句「不支持」
                    if !store.engineInputReason.isEmpty {
                        Text(L("判定依据：\(store.engineInputReason)")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            SwitchSettingsTabs(selection: $tab)
                .onChange(of: tab) { _, _ in recording = nil; test = false }
            if tab=="bindings" { bindings }
            else if tab=="list" { bindingList }
            else if tab=="options" { options }
            else { inputTest }
            if !config.conflicts.isEmpty { Text(config.conflicts.joined(separator:L("；"))).font(.callout).foregroundStyle(.red) }
            Divider()
            HStack {
                Button(L("恢复默认")) {config = .standard}.platformButtonStyle().tint(nil as Color?)
                // 三类玩法预设：选中即整体套用，之后仍可逐项微调再保存（预设只是起点，不是锁定模式）
                SwitchSettingsMenu(title: L("套用预设"), compact: true, onOpen: { recording = nil }, options: InputConfig.Preset.allCases.map { preset in
                    SwitchSettingsMenuOption(title: preset.title, detail: preset.detail) { config = .preset(preset) }
                }).frame(width: 130).disabled(recording != nil)
                if game != nil {Button(L("复制全局配置")) {config=store.globalInput}.platformButtonStyle().tint(nil as Color?)}
                Spacer()
                if config != baseline { Text(L("有未保存的更改")).font(.caption).foregroundStyle(.primary) }
                Button(L("保存配置")) {store.saveInput(config,for:game)}.platformButtonStyle(prominent:true).keyboardShortcut(.defaultAction).disabled(!config.conflicts.isEmpty || recording != nil)
            }
        }.padding(WorkspaceLayout.pageInset)
        }.frame(width:1040,height:720).background(LibraryBackdrop()).tint(WorkspacePalette.accent)
        .background(EventRecorder(recording:recording != nil,test:test && tab=="test",onKey:{ b in
            if let t=recording {if b.code != 53 {config.keyboard[t]=b};recording=nil}
            else {if b.code==53 {test=false;testText=L("输入测试已结束")} else {testText=L("键盘：\(keyName(b))")}}
        },onMouse:{v in testText=v}))
    }
    var bindings: some View {
        HStack(alignment: .top, spacing: 18) {
            ControllerMapView(config: config, selected: $selectedTarget, recording: recording) { _ in recording = nil }
                .frame(width: 558)
            selectedBinding.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxHeight: .infinity, alignment: .top)
    }
    var selectedBinding: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("正在设置")).font(.caption).foregroundStyle(.secondary)
                    Text(targetName(selectedTarget)).font(.title2.bold()).foregroundStyle(WorkspacePalette.accent)
                }
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Label(L("键盘"), systemImage: "keyboard").font(.headline)
                keyboardField(for: selectedTarget)
                HStack(spacing: 8) {
                    Button { config.keyboard[selectedTarget] = KeyBinding(code: 36); recording = nil } label: { Text("Return").frame(maxWidth: .infinity) }.platformButtonStyle().tint(nil as Color?)
                    Button { config.keyboard[selectedTarget] = KeyBinding(code: 53); recording = nil } label: { Text("Esc").frame(maxWidth: .infinity) }.platformButtonStyle().tint(nil as Color?)
                    SwitchSettingsMenu(title: L("常用键"), compact: true, onOpen: { recording = nil }, options: [36,53,49,48,56,59,58].map { code in
                        SwitchSettingsMenuOption(title: keyName(KeyBinding(code: code)), selected: config.keyboard[selectedTarget] == KeyBinding(code: code)) {
                            config.keyboard[selectedTarget] = KeyBinding(code: code); recording = nil
                        }
                    })
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(L("鼠标"), systemImage: "computermouse").font(.headline)
                mouseMenu(for: selectedTarget)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(L("手柄物理位置"), systemImage: "gamecontroller").font(.headline)
                gamepadMenu(for: selectedTarget)
                Text(L(controller.name)).font(.caption).foregroundStyle(.secondary)
            }
            if config.conflictingTargets.contains(selectedTarget) {
                Label(L("此按键存在重复绑定，请调整后保存。"), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Button { config.restoreTarget(selectedTarget, from: baseline); recording = nil } label: {
                    Text(L("恢复此键")).frame(maxWidth: .infinity)
                }.platformButtonStyle().tint(nil as Color?)
                Text(L("修改的是本机输入，游戏内的手柄图标不会变化。")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(22).switchSettingsPanel()
    }
    var bindingList: some View {
        ScrollView {
            Grid(alignment:.leading,horizontalSpacing:16,verticalSpacing:8) {
                GridRow {
                    Text(L("Switch 输入")).frame(width:160,alignment:.leading)
                    Text(L("键盘（点击录入）")).frame(width:260,alignment:.leading)
                    Text(L("鼠标")).frame(width:180,alignment:.leading)
                    Text(L("手柄物理位置")).frame(width:260,alignment:.leading)
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider().gridCellColumns(4)
                ForEach(InputConfig.targets,id:\.self) { target in
                    GridRow {
                        Text(targetName(target)).fontWeight(.medium).frame(width:160,alignment:.leading)
                        keyboardField(for: target, compact: true).frame(width:260)
                        mouseMenu(for: target, compact: true).frame(width:180)
                        gamepadMenu(for: target, compact: true).frame(width:260)
                    }
                }
            }.padding(WorkspaceLayout.cardInset).id(Localization.language)
        }.frame(maxWidth:.infinity,maxHeight:.infinity).switchSettingsPanel()
    }
    var options: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Label(L("鼠标"), systemImage:"computermouse").font(.headline)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("模式")).font(.callout.weight(.medium))
                    SwitchSettingsMenu(title: L(config.mouseOptions.mode == "camera" ? "转动视角" : "仅使用鼠标按键"), accessibilityTitle: L("模式"), options: ["camera", "off"].map { mode in
                        SwitchSettingsMenuOption(title: L(mode == "camera" ? "转动视角" : "仅使用鼠标按键"), selected: config.mouseOptions.mode == mode) { config.mouseOptions.mode = mode }
                    })
                }
                settingSlider(L("横向灵敏度"), value:$config.mouseOptions.sensitivityX, range:0.1...10, readout:String(format:"%.1f",config.mouseOptions.sensitivityX))
                settingSlider(L("纵向灵敏度"), value:$config.mouseOptions.sensitivityY, range:0.1...10, readout:String(format:"%.1f",config.mouseOptions.sensitivityY))
                Toggle(L("横向反转"),isOn:$config.mouseOptions.invertX).toggleStyle(.switch).controlSize(.small)
                Toggle(L("纵向反转"),isOn:$config.mouseOptions.invertY).toggleStyle(.switch).controlSize(.small)
                Text(L("在「转动视角」模式下，点击游戏画面锁定鼠标视角；鼠标锁定时 Esc 只释放，不触发映射的游戏按键。释放后再次按 Esc 才触发映射；窗口失焦时释放鼠标并清空输入。全屏时按 Esc 退出全屏；Esc 映射了游戏按键时，短按照常给游戏，按住 1 秒退出全屏。⌃⌘F 和菜单「显示 → 退出全屏幕」也能退出。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
            }.padding(12).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).switchSettingsPanel()
            VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                Label(L("手柄"), systemImage:"gamecontroller").font(.headline)
                Text(L(controller.name)).font(.caption).foregroundStyle(.secondary)
                settingSlider(L("摇杆死区"), value:$config.deadzone, range:0...0.8, readout:String(format:"%.0f%%",config.deadzone*100))
                Divider()
                ForEach(["LX","LY","RX","RY"],id:\.self) { target in
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Text(axisName(target)).font(.callout.weight(.medium))
                            Spacer()
                            Toggle(L("反转"),isOn:Binding(get:{config.axes[target]?.invert ?? false},set:{config.axes[target]?.invert=$0})).toggleStyle(.switch).controlSize(.small)
                        }
                        SwitchSettingsMenu(title:axisName(config.axes[target]?.source ?? "leftX"),compact:true,accessibilityTitle:axisName(target),options:["leftX","leftY","rightX","rightY"].map { source in
                            SwitchSettingsMenuOption(title:axisName(source),selected:config.axes[target]?.source == source) { config.axes[target]=AxisBinding(source:source,invert:config.axes[target]?.invert ?? false) }
                        })
                    }
                }
                Text(L("默认按 Switch 物理位置映射；单玩家。断开手柄立即清空该设备输入。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
            }.padding(12).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).switchSettingsPanel()
        }.frame(maxHeight:.infinity).id(Localization.language)
    }
    var inputTest: some View {
        VStack(alignment:.leading,spacing:12) {
            Label(L(controller.name),systemImage:"gamecontroller.fill").font(.headline)
            Text(L(controller.value)).font(.system(.callout,design:.monospaced))
            Divider();Toggle(L("开始输入测试"),isOn:$test).toggleStyle(.switch).controlSize(.small).onChange(of:test){_,v in if v {recording=nil}}
            Text(L(testText)).font(.title3.monospaced()).frame(maxWidth:.infinity,minHeight:130).contentCard(14)
            Text(L("测试只在此窗口接收输入，不会启动游戏。Esc 结束键盘测试。")).foregroundStyle(.secondary)
            Spacer()
        }.padding(12).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).switchSettingsPanel()
    }
    func keyboardField(for target: String, compact: Bool = false) -> some View {
        Button { test = false; recording = target } label: {
            Text(recording == target ? L("请按新键，Esc 取消") : keyName(config.keyboard[target]))
                .font(.system(compact ? .body : .title3, design:.monospaced))
                .padding(.leading,12).padding(.trailing,40)
                .frame(maxWidth:.infinity,minHeight:compact ? 32 : 40,alignment:.leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(L("录入键盘按键")).accessibilityValue(keyName(config.keyboard[target]))
            .background(recording == target ? WorkspacePalette.accent.opacity(0.10) : Color(nsColor:.controlBackgroundColor).opacity(0.65),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(recording == target ? WorkspacePalette.accent : .primary.opacity(0.10),lineWidth:recording == target ? 1.5 : 1).allowsHitTesting(false))
            .overlay(alignment:.trailing) {
            Button { config.keyboard[target] = nil; recording = nil } label: {
                Image(systemName:"xmark.circle").frame(width:32,height:compact ? 32 : 40).contentShape(Rectangle())
            }.buttonStyle(.borderless).accessibilityLabel(L("解除键盘绑定"))
                .padding(.trailing,4)
            }
    }
    func mouseMenu(for target: String, compact: Bool = false) -> some View {
        SwitchSettingsMenu(title:config.mouse[target].map(mouseButtonName) ?? L("未绑定"),compact:compact,accessibilityTitle:L("鼠标按键"),onOpen:{ recording = nil },options:([-1] + Array(0...4)).map { code in
            SwitchSettingsMenuOption(title:code < 0 ? L("未绑定") : mouseButtonName(code),selected:(config.mouse[target] ?? -1) == code) { config.mouse[target] = code < 0 ? nil : code; recording = nil }
        })
    }
    func gamepadMenu(for target: String, compact: Bool = false) -> some View {
        SwitchSettingsMenu(title:config.gamepad[target].map(padName) ?? L("未绑定"),compact:compact,accessibilityTitle:L("手柄物理位置"),onOpen:{ recording = nil },options:([""] + InputConfig.padCodes).map { code in
            SwitchSettingsMenuOption(title:code.isEmpty ? L("未绑定") : padName(code),selected:(config.gamepad[target] ?? "") == code) { config.gamepad[target] = code.isEmpty ? nil : code; recording = nil }
        })
    }
    func settingSlider(_ title:String,value:Binding<Double>,range:ClosedRange<Double>,readout:String) -> some View {
        VStack(alignment:.leading,spacing:8) {
            HStack { Text(title).font(.callout.weight(.medium));Spacer();Text(readout).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value:value,in:range).labelsHidden().accessibilityLabel(title)
        }
    }
}
struct EventRecorder: NSViewRepresentable {
    var recording: Bool; var test: Bool; var onKey: (KeyBinding)->Void; var onMouse: (String)->Void
    func makeCoordinator()->Coordinator { Coordinator(self) }
    func makeNSView(context:Context)->NSView {let v=NSView();context.coordinator.install(v);return v}
    func updateNSView(_ view:NSView,context:Context) {context.coordinator.parent=self}
    static func dismantleNSView(_ view:NSView,coordinator:Coordinator){coordinator.remove()}
    final class Coordinator {
        var parent:EventRecorder; var monitor:Any?; weak var view:NSView?
        init(_ p:EventRecorder){parent=p}
        func install(_ v:NSView){view=v;monitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp,.flagsChanged,.mouseMoved,.leftMouseDown,.rightMouseDown,.otherMouseDown]){[weak self] e in
            guard let self,(self.parent.recording || self.parent.test),NSApp.isActive,self.view?.window?.isKeyWindow == true else{return e}
            if [.mouseMoved,.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(e.type){if self.parent.test {self.parent.onMouse(e.type == .mouseMoved ? String(format:L("鼠标位移：%.1f, %.1f"),e.deltaX,e.deltaY) : L("鼠标按钮：\(e.buttonNumber)"))};return e}
            if e.type == .keyUp {if self.parent.test {self.parent.onMouse(L("键盘已松开：\(keyName(.init(code:Int(e.keyCode))))"))};return self.parent.recording ? nil : e}
            let code = [60:56,62:59,61:58][Int(e.keyCode)] ?? Int(e.keyCode)
            var mods=(e.modifierFlags.contains(.shift) ? 1 : 0)|(e.modifierFlags.contains(.control) ? 2 : 0)|(e.modifierFlags.contains(.option) ? 4 : 0)
            if e.modifierFlags.contains(.command){return e}
            if e.type == .flagsChanged {let bit=code==56 ? 1 : code==59 ? 2 : code==58 ? 4 : 0;if bit==0 || mods & bit == 0{if self.parent.test {self.parent.onMouse(L("修饰键已松开"))};return e};mods=0}
            self.parent.onKey(.init(code:code,modifiers:mods));return nil
        }}
        func remove(){if let monitor {NSEvent.removeMonitor(monitor)};monitor=nil}
    }
}
