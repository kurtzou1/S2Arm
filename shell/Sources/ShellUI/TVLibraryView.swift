// S2Arm addition (not in upstream): the Apple TV library.
//
// 首页结构（上半屏大图 + 标题跟着焦点所在的游戏走，下面一排卡片；卡片「确定」= 开始，长按「确定」弹菜单，播放 / 暂停键开游戏设置）
// 借自 SwitchTV（MIT License，Copyright (c) 2026 Brad Norman）的 Sources/HomeView.swift（Backdrop / HeroInfo / GameRow / GameCard）。
// 设置、手柄、选项列表、按键映射、删除确认等页面沿用 iOS 库界面的同一套视图（GameDetailView / ShellSettingsView / ControllersView /
// ChoicePickerView / PadMappingCard / DeleteGameView / StateHelpView），焦点交给 tvOS 系统焦点引擎（遥控器与手柄都能移动）。
#if os(tvOS)
import SwiftUI

/// 电视上的游戏库：Siri 遥控器滑动 / 方向键、扩展手柄十字键与摇杆在卡片和按钮间移动系统焦点，「确定」/ A 按下，「返回」/ B 关掉最上面一层
/// （什么都没开时交还系统，回到 Apple TV 主屏）。手柄 X 与遥控器播放 / 暂停键开选中游戏的设置，手柄 Y 开「手柄」页（宿主经 `input` 递来）。
/// 和 iOS 的 `LibraryView` 一样只管界面状态，一切效果经 `actions` 交给宿主。
public struct TVLibraryView: View {
    public let games: [GameDetail]
    public let controllers: [ControllerInfo]
    public let globalPadMap: PadMap
    public var actions: ShellActions
    /// 宿主的手柄事件：电视上方向、确定、返回由系统焦点处理，这里只接「游戏设置」（X）与「手柄」（Y）
    public var input: ShellInputLog
    @State private var inputSeen: Int
    @State private var selectedID: String?
    @State private var settingsOpen = false
    @State private var shellSettingsOpen = false
    @State private var controllersOpen = false
    @State private var helpGameID: String?
    @State private var deleteGameID: String?
    @State private var deleteSaves = false
    @State private var choice: ChoiceRequest?
    @State private var padMapping: PadMappingState?
    /// 关掉一层后把焦点交回给谁（焦点 id，同 iOS）
    @State private var returnFocus: String?
    /// 请求把系统焦点交给某个焦点 id（`ShellFocusTarget` 在 tvOS 上接）
    @State private var request = FocusAppearance()
    @FocusState private var focusedTile: String?
    @State private var lastBack: Date?   // 上次关层的时刻（back() 去重）
    @FocusState private var focusedTop: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(games: [GameDetail], controllers: [ControllerInfo] = [], actions: ShellActions = ShellActions(),
                input: ShellInputLog = ShellInputLog(), initialSelection: String? = nil, globalPadMap: PadMap = PadMap()) {
        self.games = games
        self.controllers = controllers
        self.actions = actions
        self.input = input
        self.globalPadMap = globalPadMap
        _inputSeen = State(initialValue: input.last)
        _selectedID = State(initialValue: initialSelection ?? games.first?.id)
    }

    private var selected: GameDetail? { games.first { $0.id == selectedID } ?? games.first }
    /// 卡片宽度（点）：1920 宽的电视上一屏四张多，露出下一张的边，看得出还能往右
    static let cardWidth: CGFloat = 384
    /// 右侧面板（游戏设置 / App 设置 / 手柄）的宽度
    static let panelWidth: CGFloat = 1040

    public var body: some View {
        let askDelete: ((GameTile) -> Void)? = actions.onDeleteGame == nil ? nil : { openDelete($0.id) }
        // 「返回」：有东西开着就关最上面那层；什么都没开时不接（nil），系统照常回 Apple TV 主屏
        let exit: (() -> Void)? = topLayer == nil ? nil : { back() }
        return ZStack {
            base
            dialogs
            pages
            pickers
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: topLayer)
        .environment(\.shellFocus, request)
        .environment(\.shellPickChoice, { openChoice($0) })
        .environment(\.shellOpenPadMapping, { openPadMapping($0) })
        .environment(\.shellShowHelp, { openHelp($0.id) })
        .environment(\.shellAskDelete, askDelete)
        .environment(\.shellManageSaves, actions.onManageSaves)
        .foregroundStyle(.white)
        .font(ShellFonts.font(15)).tint(ShellPalette.cream).preferredColorScheme(.dark)
        .onExitCommand(perform: exit)
        .onChange(of: input) { _, log in hostInput(log) }
        .onChange(of: focusedTile) { _, id in if let id { select(id) } }
        .onChange(of: games.map(\.id)) { _, ids in gamesChanged(ids) }
        // 宿主主屏快捷操作「设置」：同右上角齿轮
        .onReceive(NotificationCenter.default.publisher(for: .shellOpenSettings)) { _ in openShellSettings() }
    }

    /// 宿主递来的手柄事件：接 X（游戏设置）、Y（手柄）与 B（关最上面那层）；方向、确定系统焦点已经处理过。
    ///   B：宿主在听 GameController，手柄 B 不一定再变成系统的「返回」（#1455 实测库界面按 B 没反应），这里接；什么都没开时不接（不退出 App）。
    ///   有的手柄 B 系统也会当「返回」送一次 onExitCommand：back() 记下时刻，0.3 秒内的第二次不再关一层
    private func hostInput(_ log: ShellInputLog) {
        for event in log.since(inputSeen) where !event.released {
            switch event.action {
            case .settings: if topLayer == nil, let selected { openSettings(selected.id) }
            case .controllers: if topLayer == nil { openControllers() }
            case .back: if topLayer != nil { back() }
            default: break
            }
        }
        inputSeen = log.last
    }
    /// 选中的那款不在了（删掉了）：选第一款，焦点给它
    private func gamesChanged(_ ids: [String]) {
        guard !ids.contains(selectedID ?? "") else { return }
        selectedID = ids.first
        settingsOpen = false
        if let first = ids.first { focus("lib.tile." + first) }
    }

    // MARK: 叠放（拆成几段，免得一个 ZStack 太大编译器推不动类型）

    @ViewBuilder private var base: some View {
        if let selected { TVBackdrop(game: selected.game) } else { ShellPalette.background.ignoresSafeArea() }
        Group {
            if let selected { home(selected) } else { emptyHome }
        }
        .disabled(topLayer != nil)
        .accessibilityHidden(topLayer != nil)
        if settingsOpen, let selected { layer(.settings) { panel { gameSettings(selected) } } }
    }

    @ViewBuilder private var dialogs: some View {
        if let id = helpGameID, let game = games.first(where: { $0.id == id })?.game {
            layer(.help) { card { StateHelpView(game: game, actions: actions, onClose: closeHelp) } }
        }
        if let id = deleteGameID, let game = games.first(where: { $0.id == id })?.game {
            layer(.delete) {
                card { DeleteGameView(game: game, saves: $deleteSaves, delete: { confirmDelete(id) }, cancel: closeDelete) }
            }
        }
    }

    @ViewBuilder private var pages: some View {
        if controllersOpen {
            layer(.controllers) {
                panel { ControllersView(controllers: controllers, onBack: closeControllers, padMap: globalPadMap,
                                        showsMapping: actions.onGlobalPadMapChange != nil) }
            }
        }
        if shellSettingsOpen {
            layer(.shellSettings) { panel { ShellSettingsView(actions: actions, onClose: closeShellSettings) } }
        }
    }

    @ViewBuilder private var pickers: some View {
        if let choice {
            layer(.choice) {
                ChoicePickerView(request: choice, pick: pickChoice, close: closeChoice)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        if let padMapping {
            layer(.padMapping) {
                PadMappingCard(title: padMappingTitle(padMapping.gameID), rows: padMappingRows(padMapping.gameID),
                               inherited: padMapping.gameID == ControllersView.mappingID ? nil : globalPadMap, openRow: padMapping.row,
                               open: openPadRow, pick: pickPadValue, backToList: closePadRow, reset: resetPadMapping, close: closePadMapping)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    // MARK: 首页

    private func home(_ selected: GameDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            Spacer(minLength: 24)
            hero(selected)
            shelf
        }
        .defaultFocus($focusedTile, selected.id)
    }

    private var emptyHome: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            EmptyLibraryView()
        }
        .focusSection()
        .defaultFocus($focusedTop, "settings")
    }

    /// 左上版本字（截图定版），右上玩家 / 手柄 / App 设置
    private var topBar: some View {
        HStack(spacing: 24) {
            LibraryVersionBadge()
            Spacer(minLength: 24)
            PlayerChip()
            Button(action: openControllers) {
                HStack(spacing: 10) {
                    Image(systemName: controllers.isEmpty ? "gamecontroller" : "gamecontroller.fill")
                    Text(verbatim: "\(controllers.count)").monospacedDigit()
                }
            }
            .buttonStyle(ChipButtonStyle())
            .focused($focusedTop, equals: "controllers")
            .accessibilityLabel(ShellStrings.text("Controllers") + ", \(controllers.count)")
            .accessibilityIdentifier("controllers.open")
            .shellTarget("lib.controllers", radius: 22, action: openControllers)
            Button(action: openShellSettings) { Image(systemName: "gearshape") }
                .buttonStyle(ChipButtonStyle())
                .focused($focusedTop, equals: "settings")
                .accessibilityLabel(ShellStrings.text("Settings"))
                .accessibilityIdentifier("shellSettings.open")
                .shellTarget("lib.shellSettings", radius: 22, action: openShellSettings)
        }
        .focusSection()
    }

    /// 焦点所在（或最后一个有焦点）的游戏：标题、状态、一句说明，主按钮与「游戏设置」
    private func hero(_ detail: GameDetail) -> some View {
        let game = detail.game
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if game.sgrade { SGradeBadge(size: 30) }
                StatusLabel(state: game.state, prominent: true)
            }
            Text(game.title).shellType(ShellType.heroTitle(36)).lineLimit(2).minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("detail.title")
            if !game.subtitle.isEmpty {
                Text(game.subtitle).shellType(ShellType.meta).foregroundStyle(.white.opacity(0.6))
            }
            if !game.state.explanation.isEmpty {
                Text(game.state.explanation).shellText(14.5).foregroundStyle(.white.opacity(0.72))
                    .lineLimit(3).frame(maxWidth: 1100, alignment: .leading)
            }
            HStack(spacing: 28) {
                GameStateView(game: game, actions: actions, showsExplanation: false).fixedSize()
                Button { openSettings(detail.id) } label: { Label(ShellStrings.text("Game settings"), systemImage: "slider.horizontal.3") }
                    .buttonStyle(ChipButtonStyle())
                    .accessibilityIdentifier("settings.open")
                    .shellTarget("lib.settings", radius: 22) { openSettings(detail.id) }
            }
            .padding(.top, 8)
            .focusSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(game.id).transition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: game.id)
    }

    /// 一排游戏卡：在自己的区域里横向滚，系统焦点带着滚
    private var shelf: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 48) {
                ForEach(games) { detail in TVGameCard(detail: detail, primary: { primary(detail) }, openSettings: { openSettings(detail.id) },
                                                       select: select)
                        .focused($focusedTile, equals: detail.id)
                }
            }
            .padding(.vertical, 40)   // 卡片得焦放大、带阴影，留出地方
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .focusSection()
    }

    // MARK: 各层

    /// 最上面那一层，顺序同 iOS（`FocusLayer`）
    private var topLayer: FocusLayer? {
        if padMapping != nil { return .padMapping }
        if choice != nil { return .choice }
        if controllersOpen { return .controllers }
        if shellSettingsOpen { return .shellSettings }
        if helpGameID != nil { return .help }
        if deleteGameID != nil { return .delete }
        if settingsOpen { return .settings }
        return nil
    }

    /// 一层：压暗底下，只有在最上面时可聚焦（底下各层 disabled，焦点出不了这一层）
    private func layer<Content: View>(_ which: FocusLayer, @ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().accessibilityHidden(true).transition(.opacity)
            content()
                .disabled(topLayer != which)
                .accessibilityHidden(topLayer != which)
                .accessibilityAddTraits(.isModal)
        }
    }

    /// 从右边滑进来的整高面板，底色铺到屏幕边，内容留在安全区里
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: Self.panelWidth)
            .frame(maxHeight: .infinity)
            .background { ShellPalette.background.ignoresSafeArea() }
            .overlay(alignment: .leading) { Rectangle().fill(ShellPalette.hairline).frame(width: 1).ignoresSafeArea() }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    /// 屏幕中间的对话卡（怎么修 / 删除确认）
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: 460 * ShellFonts.tvScale)
            .background(Color(red: 0.075, green: 0.075, blue: 0.082), in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.10)))
            .shadow(color: .black.opacity(0.5), radius: 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// 选中游戏的设置：封面、标题、状态与主按钮，然后各组设置行；系统焦点移到哪，滚动视图就带到哪
    private func gameSettings(_ detail: GameDetail) -> some View {
        ScrollView {
            GameDetailView(detail: detail, actions: actions, showsPrimaryAction: true, showsHeader: true)
                .padding(.horizontal, 48).padding(.vertical, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: 动作

    /// 把系统焦点交给某个焦点 id（`lib.tile.<游戏号>` 是卡片，其余由 `ShellFocusTarget` 接）；下一拍再给，等那一层变回可聚焦
    private func focus(_ id: String?) {
        guard let id else { return }
        if id.hasPrefix("lib.tile.") {
            let tile = String(id.dropFirst("lib.tile.".count))
            DispatchQueue.main.async { focusedTile = tile }
            return
        }
        request.id = id
        request.generation += 1
    }
    private func select(_ id: String) {
        guard id != selectedID else { return }
        selectedID = id
        actions.onSelect(id)
    }
    /// 卡片「确定」：同 iOS 的主按钮（开始 / 怎么修 / 选游戏数据 / 更新 App / 看日志 / 重试安装）
    private func primary(_ detail: GameDetail) {
        select(detail.id)
        if detail.game.state.needsHelp { openHelp(detail.id); return }
        switch detail.game.state {
        case .playable: actions.onPlay(detail.id)
        case .needsGameData: actions.onPickGameData(detail.id)
        case .needsAppUpdate: actions.onAppUpdate?()
        case .needsGameUpdate, .sourceOffline: break   // needsHelp：上面已展开说明
        case .needsLegacyUpdate, .needsProgram: actions.onImportProgram?(detail.id)   // 选这款的 .s2arm 导入（电脑「更新一次」是第二条路，写在说明里）
        case .needsCertificate: actions.onGetSigningCert?()   // 直接导证书（装了 SideStore 向它要，否则选 .p12），导好库自己回「可以玩」
        case .broken: actions.onShowLog?(detail.id)
        case .installing(let stage): if stage.phase == .failed { actions.onPlay(detail.id) }   // 重试解开；传着 / 解着按了不动
        }
    }
    private func openSettings(_ id: String) {
        // 从卡片开的回卡片，从「游戏设置」按钮开的回按钮
        returnFocus = focusedTile == id ? "lib.tile." + id : "lib.settings"
        select(id)
        settingsOpen = true
        focus("set.play")
    }
    private func closeSettings() { settingsOpen = false; focus(returnFocus) }
    private func openControllers() { controllersOpen = true; focus("ctl.close") }
    private func closeControllers() { controllersOpen = false; focus("lib.controllers") }
    private func openShellSettings() { shellSettingsOpen = true; focus("shs.close") }
    private func closeShellSettings() { shellSettingsOpen = false; focus("lib.shellSettings") }
    private func openHelp(_ id: String) { returnFocus = currentFocus; helpGameID = id; focus("help.done") }
    private func closeHelp() { helpGameID = nil; focus(returnFocus) }
    /// 删除确认从「取消」开始，存档默认保留（同 iOS）
    private func openDelete(_ id: String) { returnFocus = currentFocus; deleteSaves = false; deleteGameID = id; focus("del.cancel") }
    private func closeDelete() { deleteGameID = nil; focus(returnFocus) }
    private func confirmDelete(_ id: String) {
        let saves = deleteSaves
        deleteGameID = nil
        settingsOpen = false
        actions.onDeleteGame?(id, saves)
    }
    /// 打开某层之前焦点在哪：设置页里是那一页的删除 / 主按钮，首页是卡片
    private var currentFocus: String? {
        if settingsOpen { return "set.delete" }
        return selected.map { "lib.tile." + $0.id }
    }
    private func openChoice(_ request: ChoiceRequest) {
        choice = request
        focus("pick." + request.row.value)
    }
    private func closeChoice() {
        guard let request = choice else { return }
        choice = nil
        focus((request.gameID == ShellSettingsRows.gameID ? ShellSettingsRows.targetPrefix : "set.row.") + request.row.id)
    }
    private func pickChoice(_ value: String) {
        guard let request = choice else { return }
        if value != request.row.value {
            if request.gameID == ShellSettingsRows.gameID { ShellSettingsRows.apply(request.row.id, value: value, to: .current) }
            else { actions.onChange(request.gameID, request.row.id, value) }
        }
        closeChoice()
    }
    private func padMappingRows(_ id: String) -> [SettingRow] {
        if id == ControllersView.mappingID { return PadMappingRows.global(globalPadMap) }
        return games.first { $0.id == id }.map(PadMappingRows.game) ?? []
    }
    private func padMappingTitle(_ id: String) -> String {
        if id == ControllersView.mappingID { return ShellStrings.text("All games") }
        return games.first { $0.id == id }?.game.title ?? ""
    }
    private func openPadMapping(_ id: String) {
        padMapping = PadMappingState(gameID: id)
        let swap = padMappingRows(id).first
        focus(swap?.value == "custom" ? "map.row.pad.A" : "map.swap." + (swap?.value ?? ""))
    }
    private func closePadMapping() {
        guard let id = padMapping?.gameID else { return }
        padMapping = nil
        focus(id == ControllersView.mappingID ? "ctl.mapping" : "set.row.padMapping")
    }
    private func openPadRow(_ row: String) {
        padMapping?.row = row
        focus("map.opt." + (padMappingRows(padMapping?.gameID ?? "").first { $0.id == row }?.value ?? ""))
    }
    private func closePadRow() {
        guard let row = padMapping?.row else { return }
        padMapping?.row = nil
        focus("map.row." + row)
    }
    private func pickPadValue(_ row: String, _ value: String) {
        guard let id = padMapping?.gameID else { return }
        if id == ControllersView.mappingID { actions.onGlobalPadMapChange?(row, value) } else { actions.onChange(id, row, value) }
        closePadRow()
    }
    private func resetPadMapping() {
        guard let id = padMapping?.gameID else { return }
        let global = id == ControllersView.mappingID
        if global { actions.onGlobalPadMapReset?() } else { actions.onChange(id, PadMappingRows.resetID, "") }
        focus("map.swap." + (global ? "0" : PadMappingRows.follow))
    }
    /// 「返回」：关最上面那层，顺序同 iOS 的 back()
    private func back() {
        let now = Date()
        if let last = lastBack, now.timeIntervalSince(last) < 0.3 { return }   // 同一下 B：宿主事件与系统「返回」各来一次，只关一层
        lastBack = now
        if padMapping?.row != nil { closePadRow() }
        else if padMapping != nil { closePadMapping() }
        else if choice != nil { closeChoice() }
        else if helpGameID != nil { closeHelp() }
        else if deleteGameID != nil { closeDelete() }
        else if controllersOpen { closeControllers() }
        else if shellSettingsOpen { closeShellSettings() }
        else if settingsOpen { closeSettings() }
    }
}

/// 一张游戏卡：16:9 封面（状态点 / 金色 S / 安装蒙版同 iOS）与名字，系统卡片样式（得焦放大、视差）。
/// 「确定」= 主按钮；长按「确定」弹菜单（游戏设置 / 管理存档 / 删除游戏，同 iOS 长按）；播放 / 暂停键开游戏设置
private struct TVGameCard: View {
    let detail: GameDetail
    let primary: () -> Void
    let openSettings: () -> Void
    let select: (String) -> Void
    var body: some View {
        let game = detail.game
        Button(action: primary) {
            VStack(alignment: .leading, spacing: 12) {
                CoverView(game: game, radius: 0, showsState: true)
                    .frame(width: TVLibraryView.cardWidth, height: TVLibraryView.cardWidth * 9 / 16)
                HStack(spacing: 8) {
                    if game.showsNewNote { NewDot(size: 12) }
                    Text(game.title).shellText(13, .semibold).lineLimit(1)
                }
                .frame(width: TVLibraryView.cardWidth - 24, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .buttonStyle(.card)
        .accessibilityLabel(game.title + ", " + game.state.title)
        .accessibilityIdentifier("tile.\(game.id)")
        .onPlayPauseCommand(perform: openSettings)
        .modifier(GameTileMenu(detail: detail, select: select, openSettings: openSettings))
    }
}

/// 整屏背景：焦点所在游戏的图模糊铺满，四周与底部压暗，字和卡片在任何图上都看得清；换游戏时淡入淡出
private struct TVBackdrop: View {
    let game: GameTile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            ShellPalette.background
            ArtView(game: game, backdrop: true)
                .scaleEffect(1.2)
                .blur(radius: 50, opaque: true)
                .saturation(1.2)
                .opacity(0.7)
                .id(game.id)
                .transition(.opacity)
            LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.25),
                                   .init(color: ShellPalette.background.opacity(0.75), location: 0.6),
                                   .init(color: ShellPalette.background, location: 1)], startPoint: .top, endPoint: .bottom)
        }
        .animation(reduceMotion ? .linear(duration: 0.2) : .easeInOut(duration: 0.45), value: game.id)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
#endif
