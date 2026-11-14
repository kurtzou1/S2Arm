import SwiftUI

struct InputGuidePresentation: Identifiable {
    let id = UUID()
    let game: Game
    let config: InputConfig
    let supported: Bool

    var launchArguments: [String: Any] {
        var result: [String: Any] = ["gameId": game.id, "inputGuideHandled": true]
        if supported, let data = try? JSONEncoder().encode(config),
           let object = try? JSONSerialization.jsonObject(with: data) { result["launchInputConfig"] = object }
        return result
    }
}

extension Store {
    func launchOptions(for gameID: String) -> [String: Any] {
        // 不带 gameLanguage / docked：逐款的游戏语言 / 主机模式在启动设置里选（作业层 community 存这款的 launch.json、起局 launch_env 转成宿主变量；11-14 维护者确认玩家可选，推翻 11-07 的「不给玩家选」）；没选过 = 跟 Mac 系统首选语言、主机模式
        var options: [String: Any] = ["uiLanguage": language.resolved()]
        if recoveryOverride == gameID { options["overrideRecovery"] = true }
        return options
    }
    /// 启动失败在存档回退（save_recovery）上的那一款：错误框据此给「仍要启动」「去备份存档」
    var saveRecoveryGame: Game? {
        guard errorDiagnostic?.code == "save_recovery", let id = tasks.last(where:{$0.operation == "launch" && $0.state == "failed"})?.gameId else { return nil }
        return games.first(where:{$0.id == id})
    }
    func launchOverridingRecovery(_ game: Game) { recoveryOverride = game.id; error = nil; launch(game) }
    func inputGuideShown(for gameID: String) -> Bool {
        let path = privateRoot.appendingPathComponent("input-guides/\(gameID).json")
        guard let data = try? Data(contentsOf: path), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["gameId"] as? String == gameID, let show = value["show"] as? Bool else { return true }
        return show
    }
    func setInputGuideShown(_ shown: Bool, for gameID: String) {
        do {
            let path = privateRoot.appendingPathComponent("input-guides/\(gameID).json")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["schema": 1, "gameId": gameID, "show": shown]).write(to: path, options: .atomic)
            // The preference binding reads a file, so successful writes must
            // explicitly invalidate the currently visible guide.
            objectWillChange.send()
        } catch { self.error = "无法保存键位引导偏好：\(error.localizedDescription)" }
    }
    func prepareInputGuide(_ game: Game, handled: Bool = false) {
        do {
            let path = libraryURL.appendingPathComponent("mappings/\(game.id).json")
            let config = FileManager.default.fileExists(atPath: path.path) ? try JSONDecoder().decode(InputConfig.self, from: Data(contentsOf: path)) : globalInput
            let presentation = InputGuidePresentation(game: game, config: config, supported: game.inputConfig ?? engineSupportsInput)
            if !handled && inputGuideShown(for: game.id) { inputGuide = presentation }
            else { inputGuide = nil; beginGuidedLaunch(presentation) }
        } catch { self.error = "此游戏的输入映射无法读取，请先修复或重新保存键位。" }
    }
    func confirmInputGuide(_ presentation: InputGuidePresentation) {
        guard inputGuide?.id == presentation.id else { return }
        inputGuide = nil; beginGuidedLaunch(presentation)
    }
    func beginGuidedLaunch(_ presentation: InputGuidePresentation) {
        guard !executionBusy, queue.isEmpty, runtimeReady else { error = "当前任务或运行环境已变化，请重新启动游戏。"; return }
        guard presentation.config.conflicts.isEmpty else { error = "输入映射存在冲突，请先修改键位。"; return }
        var arguments = presentation.launchArguments
        for (key, value) in launchOptions(for: presentation.game.id) { arguments[key] = value }
        recoveryOverride = nil   // 确认只管这一次启动；记录留着，下次启动后端照常先试恢复
        executionTask = worker("launch", extra: arguments)
    }
    func editInputFromGuide(_ game: Game) {
        pendingGuideEditor = game; inputGuide = nil
    }
    func inputGuideDismissed() {
        if let game = pendingGuideEditor { pendingGuideEditor = nil; inputGame = game; editingInput = true }
    }
}

struct InputGuideView: View {
    @EnvironmentObject var store: Store
    let presentation: InputGuidePresentation
    private var mapping: InputConfig { presentation.config }
    @State private var selectedTarget = "A"
    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
            WorkspaceHeading(title:presentation.game.name,subtitle:"开始前，先认识这款游戏的操作。",symbol:"gamecontroller") {EmptyView()}
            ScrollView {
            VStack(alignment:.leading,spacing:WorkspaceLayout.sectionSpacing) {
            if presentation.supported {
                Text(L("点选手柄上的按键，在右侧查看本次启动使用的输入。具体功能以游戏提示为准。")).font(.callout)
                HStack(alignment: .top, spacing: 18) {
                    ControllerMapView(config: mapping, selected: $selectedTarget).frame(width: 558)
                    ReadOnlyBindingPanel(config: mapping, target: selectedTarget)
                }.frame(maxHeight: .infinity, alignment: .top)
                Text(L(mapping.mouseOptions.mode != "camera" ? "鼠标移动不驱动摇杆。" : mapping.mouseOptions.recenter ? "鼠标移动控制右摇杆，停止移动后回中。" : "鼠标移动控制右摇杆，停手后保持在原处，不回中。")).font(.callout).foregroundStyle(.secondary)
            } else {
                Label(L("当前游戏宿主未确认支持输入映射，不能将已保存配置当作实际生效键位。请重新准备支持映射的运行版本。"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Spacer()
            }
            if !mapping.conflicts.isEmpty { Text(mapping.conflicts.joined(separator: L("；"))).foregroundStyle(.red) }
            Text(L("新版 Mac 宿主可从游戏菜单或菜单栏手柄图标查看本局键位。旧包需重新编译，改键下次启动生效。")).font(.callout).foregroundStyle(.secondary)
            }
            }
            Divider()
            HStack {
                Toggle(L("下次启动仍显示"), isOn: Binding(get: { store.inputGuideShown(for: presentation.game.id) }, set: { store.setInputGuideShown($0, for: presentation.game.id) })).toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button(L("取消")) { store.inputGuide = nil }.platformButtonStyle().tint(nil as Color?).keyboardShortcut(.cancelAction)
                Button(L("修改键位")) { store.editInputFromGuide(presentation.game) }.platformButtonStyle().tint(nil as Color?)
                Button(L("开始游戏")) { store.confirmInputGuide(presentation) }.platformButtonStyle(prominent:true).keyboardShortcut(.defaultAction).disabled(!mapping.conflicts.isEmpty)
            }
        }.padding(WorkspaceLayout.pageInset).frame(width: 1040, height: 720).background(SwitchSettingsBackground()).tint(SwitchControlsPalette.focus)
    }
}
