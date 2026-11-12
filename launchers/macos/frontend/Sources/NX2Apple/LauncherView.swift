// Derived from NX2Apple frontend/Sources/NX2Apple/LauncherView.swift (908e4e84, MIT; see ../../UPSTREAM.md).
// S2Arm changes: one page, the Library (the Builds and Settings pages, engine sync banner, artwork editor, Manage menu, console mode
// and gamepad driver are not taken); the state is S2ArmLauncherModel (adapter services) instead of LauncherStores; while a game runs
// the library gives way to JobSessionView (the launch job's events and Stop), and Back returns to the library. Second cut: the top bar
// adds Add games (open panel, or drop files on the window → import job) and the environment check (EnvironmentView); the options
// sheet is joined by the install-to-iPhone sheet (InstallView); any job (prepare, install, import) runs in JobSessionView. Export
// (11-07): a game's Export opens ExportView in place of the library (platforms, options, start), and an export runs in
// ExportSessionView (platform queue, steps, time left, per-platform results); the free-up-space sheet (FreeSpaceView) and
// change library (JobSessionView, setup job) sit beside them.
// Switch 2 Pro: the top bar adds the controller button and popover (Switch2ProConnectionPopover), and the library starts the
//   controller connection on appear when the user enabled it (NS2LauncherController).
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct LauncherView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @StateObject var padFocus = PadFocus()
    @StateObject var row = RowScroller()
    @StateObject var covers = CoverCache()
    @State var installFor: String?
    @State var spaceFor: String?
    @State var moreFor: String?
    @State var saveFor: String?
    /// 拖到卡片上的存档：随存档窗口一起打开、先检查（SaveManageSheet.source）
    @State var saveDrop: URL?
    /// 拖动经过的那张卡片（描边提示）
    @State var dropCard: String?
    @State var displayFor: String?
    @State var inputFor: String?
    @State var deleteFor: GameSummary?
    /// 「找不到游戏文件」的那款（点了卡片）：重新指定文件夹 / 从游戏库移除
    @State var missingFor: GameSummary?
    @State private var showController = false
    @State private var dropTargeted = false
    @State var collectionHeight: CGFloat = 300
    let brand: String

    /// Room for the controller's focus ring, which sits 4 pt outside a card.
    static let ringRoom: CGFloat = 6

    /// What the host's own messages use: the launch job takes zh-Hans or en.
    var uiLanguage: String { loc.lang == .zh ? "zh-Hans" : "en" }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.3)
            noticeBar
            libraryNoticeBar
            if model.batchShown {
                BatchExportView(model: model, covers: covers, install: { installFor = $0 }, freeSpace: { spaceFor = $0 }, uiLanguage: uiLanguage)
            } else if let result = model.viewingResult, let run = result.export {
                ExportSessionView(model: model, covers: covers, session: result, run: run, install: { installFor = $0 }, freeSpace: { spaceFor = $0 }, uiLanguage: uiLanguage)
            } else if let session = model.session, let run = session.export, !model.sessionHidden {
                ExportSessionView(model: model, covers: covers, session: session, run: run, install: { installFor = $0 }, freeSpace: { spaceFor = $0 }, uiLanguage: uiLanguage)
            } else if let session = model.session, session.export == nil, !model.isInline(session) {
                if session.kind == .play { PlaySessionView(model: model, covers: covers, session: session, uiLanguage: uiLanguage) }
                else { JobSessionView(model: model, session: session) }
            } else if let id = model.exportFor, let game = model.games.first(where: { $0.id == id }) {
                ExportView(model: model, covers: covers, game: game) { installFor = game.id }
            } else {
                libraryPage
                    .overlay {
                        if dropTargeted {
                            RoundedRectangle(cornerRadius: 18).strokeBorder(LauncherPalette.cream, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                                .padding(16).allowsHitTesting(false)
                        }
                    }
                    .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                        Self.fileURLs(providers) { urls in
                            // 拖进来的是 prod.keys 就当密钥放，别当游戏报错
                            if urls.count == 1, urls[0].pathExtension.lowercased() == "keys" { model.importKeys(urls[0]) } else { model.importGames(urls, partialResults: true) }
                        }
                        return true
                    }
            }
        }
        .padScope("main", padFocus)
        .environmentObject(padFocus)
        .launcherDropdownHost()
        .background(LauncherPalette.background)
        .background(LauncherWindowChrome())
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
        .font(.manrope(13))
        .frame(minWidth: 900, idealWidth: 1280, minHeight: 680, idealHeight: 900)
        .onAppear { model.startup() }
        .sheet(item: Binding(get: { installFor.map(OptionsTarget.init) }, set: { installFor = $0?.id })) { target in
            InstallView(model: model, gameID: target.id).environmentObject(loc)
        }
        .onChange(of: model.spaceRequest) { id in if let id { spaceFor = id; model.spaceRequest = nil } }   // 设置页「磁盘空间」
        .sheet(item: Binding(get: { spaceFor.map(OptionsTarget.init) }, set: { spaceFor = $0?.id })) { target in
            FreeSpaceView(model: model, gameID: target.id).environmentObject(loc)
        }
        .sheet(item: Binding(get: { displayFor.map(OptionsTarget.init) }, set: { displayFor = $0?.id })) { target in
            LaunchSettingsSheet(model: model, gameID: target.id, openInput: { inputFor = target.id }).environmentObject(loc)
        }
        .sheet(item: Binding(get: { saveFor.map(OptionsTarget.init) }, set: { saveFor = $0?.id; if $0 == nil { saveDrop = nil } })) { target in
            SaveManageSheet(model: model, gameID: target.id, source: saveDrop).environmentObject(loc)
        }
        .sheet(item: Binding(get: { inputFor.map(OptionsTarget.init) }, set: { inputFor = $0?.id })) { target in
            InputSettingsSheet(model: model, gameID: target.id).environmentObject(loc)
        }
        .background(DownstreamPromptHost(model: model))   // 下游深度方案确认页（DownstreamConfirmSheet.swift）
        .alert(txt("game.delete.title").replacingOccurrences(of: "{0}", with: deleteFor?.name ?? ""), isPresented: Binding(get: { deleteFor != nil }, set: { if !$0 { deleteFor = nil } })) {
            Button(txt("game.cancel"), role: .cancel) { deleteFor = nil }
            Button(txt("game.delete.confirm"), role: .destructive) { if let g = deleteFor { model.deleteGame(g) }; deleteFor = nil }
        } message: { Text(txt("game.delete.body")) }
        .alert(txt("library.missing.title").replacingOccurrences(of: "{0}", with: missingFor?.name ?? ""), isPresented: Binding(get: { missingFor != nil }, set: { if !$0 { missingFor = nil } })) {
            Button(txt("library.missing.relink")) { if let g = missingFor { relinkGame(g) }; missingFor = nil }
            Button(txt("library.missing.forget"), role: .destructive) { if let g = missingFor { model.forgetGame(g) }; missingFor = nil }
            Button(txt("game.cancel"), role: .cancel) { missingFor = nil }
        } message: { Text(txt("library.missing.body")) }
        // 换游戏库撞上认得出的风险（云盘同步目录 / 有别的文件的文件夹，S2ArmLauncherModel.libraryConfirmCodes）：讲清后果，玩家选「仍然继续」带上对应参数重来（v0.3.1）
        .alert(BackendText.errorTitle(model.libraryConfirm?.code ?? "library_in_cloud", language: uiLanguage) ?? txt("install.drop_title"), isPresented: Binding(get: { model.libraryConfirm != nil }, set: { if !$0 { model.libraryConfirm = nil } })) {
            Button(txt("install.drop_confirm")) { if let c = model.libraryConfirm { model.libraryConfirm = nil; model.changeLibrary(to: c.url, move: c.move, accept: c.accept) } }
            Button(txt("phone.drop.cancel"), role: .cancel) { model.libraryConfirm = nil }
        } message: { Text(loc.backend(model.libraryConfirm?.message ?? "")) }
        .sheet(isPresented: $model.showAddGames) { ImportSheet(model: model, kind: .games).environmentObject(loc) }
        .sheet(isPresented: $model.showKeys) { ImportSheet(model: model, kind: .keys).environmentObject(loc) }
        .sheet(isPresented: $model.showEnvironment) {
            EnvironmentView(model: model).environmentObject(loc)
        }
    }

    /// 删除游戏 / 清除缓存的进行中与结果（S2ArmLauncherModel.libraryNotice）：点下就出现，成功几秒后自己收起，失败留着等玩家关
    @ViewBuilder private var libraryNoticeBar: some View {
        if let n = model.libraryNotice {
            let text = loc.t(n.key + "." + { switch n.kind { case .running: "running"; case .done: "done"; case .failed: "failed" } }())
                .replacingOccurrences(of: "{0}", with: n.name).replacingOccurrences(of: "{1}", with: loc.backend(n.detail))
            HStack(spacing: 10) {
                switch n.kind {
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LauncherPalette.danger)
                }
                Text(text).font(.manrope(13, .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if n.kind != .running {
                    Button { model.libraryNotice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityIdentifier("notice.library.close")
                }
            }
            .padding(.horizontal, 34).padding(.vertical, 10)
            .background((n.kind == .failed ? LauncherPalette.danger : LauncherPalette.cream).opacity(0.10))
            .accessibilityIdentifier("notice.library")
            .task(id: n) { if n.kind == .done { try? await Task.sleep(nanoseconds: 6_000_000_000); if model.libraryNotice == n { model.libraryNotice = nil } } }
        }
    }

    static var displayVersion: String {
        let info = Bundle.main.infoDictionary
        if let shown = info?["S2ADisplayVersion"] as? String, !shown.isEmpty { return shown }
        return (info?["CFBundleShortVersionString"] as? String).map { "v" + $0 + "-dev" } ?? "dev"   // swift run 等不经 build_app 的开发构建
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            // 点品牌名回欢迎页（社区贡献者补丁 #2）
            Button { installFor = nil; model.goToLibrary(); model.welcomeHome = true } label: {
                Text(brand).font(.manrope(22, .bold)).tracking(-0.6).lineLimit(1).fixedSize()
            }
            .buttonStyle(.plain).accessibilityIdentifier("top.brand")
            // 版本号（11-11 维护者：玩家截图时我们一眼看出是哪一版）：正式版 v0.3.0，开发版 v0.2.9-dev+短提交号（build_app.py 写进 Info.plist）
            Text(verbatim: Self.displayVersion).font(.manrope(12.5, .semibold)).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).fixedSize().textSelection(.enabled).accessibilityIdentifier("topbar.version")
            Spacer()
        }
        .padding(.leading, 90).padding(.trailing, 24)   // the window's traffic lights sit in the transparent title bar
        .frame(height: 52)   // = a unified toolbar's title bar: the system centres the traffic lights in it, so they share this bar's midline
        .background(TitlebarDoubleClick())
        .background(UnifiedTitlebar(actions: topActions))
    }

    /// 顶栏右侧的按钮放进标题栏本身：工具栏盖在窗口内容上，内容里的按钮收不到真实点击（11-08 维护者）。
    private var topActions: some View {
        HStack(spacing: 12) {
                if model.loading { ProgressView().controlSize(.small) }
                PlayerToolbarButton(loc: loc)   // 本地玩家（#623）：这次用谁的身份玩，点开切换 / 添加；标题栏另起视图树、环境对象传不进去，显式给
                exportPill
                batchPill
                PhoneUpdateButton(model: model, language: uiLanguage)
                phonePill
                ControllerToolbarButton(controller: model.controller, show: $showController,
                                        simplifiedChinese: loc.lang == .zh)
                updateButton
                Button { installFor = nil; model.goToLibrary() } label: {
                    Label(loc.t("s2arm.nav.library"), systemImage: "square.grid.2x2").font(.manrope(12.5, .semibold))
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .accessibilityIdentifier("top.library")
                Button { model.showAddGames = true } label: {
                    Label(loc.t("s2arm.action.import"), systemImage: "plus").font(.manrope(12.5, .semibold))
                }
                .buttonStyle(LauncherSecondaryButtonStyle()).disabled(model.busy)
                Button { model.showEnvironment = true } label: {
                    HStack(spacing: 7) {
                        Circle().fill(environmentColor).frame(width: 7, height: 7)
                        Text(BackendText.launcherText("nav.settings", language: uiLanguage)).font(.manrope(12.5, .semibold))   // 设置：语言 / 存放位置 / 装机方式 / 环境检查（入口整理）
                    }
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
        }
        .padding(.trailing, 8)
        .fixedSize()   // 放在标题栏里没有宽度约束，不固定的话按钮文字会被压成省略号
        .labelStyle(.titleAndIcon)   // 工具栏里 Label 缺省只显示图标
        .tint(LauncherPalette.cream)
        .environment(\.colorScheme, .dark)
    }

    /// A unified toolbar makes the (transparent) title bar as tall as the top bar, and macOS then centres the close / minimise / zoom
    /// buttons vertically in it. The right-hand actions are its one item, so real clicks reach them.
    private struct UnifiedTitlebar<Actions: View>: NSViewRepresentable {
        let actions: Actions

        final class Coordinator: NSObject, NSToolbarDelegate {
            let host: NSHostingView<Actions>
            init(_ actions: Actions) { host = NSHostingView(rootView: actions) }
            func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] }
            func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] }
            func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }
        }

        final class Host: NSView {
            var coordinator: Coordinator?
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window, window.toolbar == nil else { return }
                let toolbar = NSToolbar(identifier: "s2arm.titlebar")
                toolbar.delegate = coordinator
                toolbar.displayMode = .iconOnly
                toolbar.allowsUserCustomization = false
                window.toolbar = toolbar
                window.toolbarStyle = .unified
                window.titlebarSeparatorStyle = .none
                // 工具栏只负责标题栏高度。按钮直接放进标题栏：放进工具栏项时 macOS 26 会在整组下面再垫一层玻璃胶囊，和按钮自己的胶囊叠在一起
                guard let close = window.standardWindowButton(.closeButton), let bar = close.superview, let host = coordinator?.host else { return }
                host.translatesAutoresizingMaskIntoConstraints = false
                bar.addSubview(host)
                NSLayoutConstraint.activate([host.trailingAnchor.constraint(equalTo: bar.trailingAnchor), host.centerYAnchor.constraint(equalTo: close.centerYAnchor)])
            }
        }

        func makeCoordinator() -> Coordinator { Coordinator(actions) }
        func makeNSView(context: Context) -> NSView { let h = Host(); h.coordinator = context.coordinator; return h }
        func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.host.rootView = actions }
    }

    private struct OptionsTarget: Identifiable { let id: String }

    private var environmentColor: Color {
        switch model.environmentState {
        case .unknown: return LauncherPalette.unbuilt
        case .ready, .readyMac: return LauncherPalette.ready   // readyMac：Mac 上能玩，只差打 iPhone 包的项（环境检查页里单列）
        case .missing: return LauncherPalette.danger
        }
    }

    /// 顶部公告条（v0.2.3）：醒目的琥珀色底、整条宽，压在内容上方但不盖住任何按钮；× 关掉后同一条不再出现。文字取自 notice.json，代码里不写公告内容
    @ViewBuilder private var noticeBar: some View {
        if let notice = model.notice, let text = (notice["text"] as? [String: String])?[uiLanguage] {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LauncherPalette.building)
                (Text(txt("notice.label") + "  ").font(.manrope(13, .bold)) + Text(text).font(.manrope(13)))
                    .foregroundStyle(LauncherPalette.cream).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: 8)
                if let link = (notice["url"] as? String).flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.open(link) } label: { Text(txt("notice.details")).font(.manrope(12.5, .semibold)).underline() }
                        .buttonStyle(.plain).foregroundStyle(LauncherPalette.cream)
                }
                Button { model.dismissNotice() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(LauncherPalette.cream.opacity(0.8)).help(txt("notice.close")).accessibilityLabel(txt("notice.close"))
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            .background(LauncherPalette.building.opacity(0.16))
            .overlay(alignment: .bottom) { Rectangle().fill(LauncherPalette.building.opacity(0.45)).frame(height: 1) }
        }
    }

    /// 有新版：后台下载时一行小字，下好后一颗「更新并重启」，都在顶栏，不打断玩家。
    @ViewBuilder private var updateButton: some View {
        switch model.updateState {
        case .working(let id, let percent):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(txt(id).replacingOccurrences(of: "{0}", with: "\(percent ?? 0)")).font(.manrope(12)).monospacedDigit().foregroundStyle(.secondary)
            }
        case .ready:
            Button { model.restartToUpdate() } label: {
                Label(txt(model.busy ? "update.restart.busy" : "update.restart"), systemImage: "arrow.down.circle").font(.manrope(12.5, .semibold))
            }
            .buttonStyle(LauncherSecondaryButtonStyle()).disabled(model.busy)
        case .failed(let code):
            // 失败原因直接写在按钮旁（人话 + 错误码），并给「打开下载页」：自动更新连不上 GitHub 时玩家能自己下（不再只藏在悬停提示里）
            HStack(spacing: 8) {
                Button { model.downloadUpdate() } label: { Text(txt("update.retry")).font(.manrope(12.5, .semibold)) }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                Text(txt("update.error." + code) + " · " + txt("update.code").replacingOccurrences(of: "{0}", with: code))
                    .font(.manrope(11.5)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 340, alignment: .leading)
                    .help(txt("update.error." + code)).textSelection(.enabled)
                Button { NSWorkspace.shared.open(S2ArmLauncherModel.downloadPage) } label: { Text(txt("update.download_page")).font(.manrope(12.5, .semibold)) }
                    .buttonStyle(LauncherSecondaryButtonStyle())
            }
        case .idle: EmptyView()
        }
    }

    func txt(_ id: String) -> String { BackendText.launcherText(id, language: uiLanguage) }

    /// 批量出包（v0.2.4）：清单页没开着时，这批正在出 / 上次还有没出完的 → 顶部胶囊回到清单页
    @ViewBuilder private var batchPill: some View {
        if !model.batchShown, model.batchRunning || model.batchUnfinished > 0 {
            Button { model.batchShown = true } label: {
                HStack(spacing: 7) {
                    if model.batchRunning { ProgressView().controlSize(.mini) } else { Image(systemName: "list.bullet.rectangle") }
                    Text(model.batchRunning ? BackendText.launcherText("batch.title", language: uiLanguage)
                         : BackendText.launcherText("batch.unfinished", language: uiLanguage).replacingOccurrences(of: "{0}", with: "\(model.batchUnfinished)"))
                        .font(.manrope(12.5, .semibold)).lineLimit(1)
                }
            }
            .buttonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("top.batch")
        }
    }

    /// 收起运行页、或还有排队时：顶部这颗胶囊回到出包页。
    @ViewBuilder private var exportPill: some View {
        if let session = model.session, session.export != nil, model.sessionHidden {
            Button { model.sessionHidden = false } label: {
                HStack(spacing: 7) {
                    if model.busy { ProgressView().controlSize(.mini) } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(LauncherPalette.ready) }
                    Text(txt(model.busy ? "export.pill.running" : "export.pill.done").replacingOccurrences(of: "{0}", with: session.name)).font(.manrope(12.5, .semibold)).lineLimit(1)
                    if !model.exportQueue.isEmpty {
                        Text(txt("export.pill.queue").replacingOccurrences(of: "{0}", with: "\(model.exportQueue.count)")).font(.manrope(12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .buttonStyle(LauncherSecondaryButtonStyle())
        }
    }

    /// 装机弹窗关着时：手机作业在跑 → 「正在装到 iPhone · 查看进度」，点了回到同一个作业（弹窗显示 model.session，不新起安装）；
    /// 跑完还没回去看 → 「已装好 / 没装完 · 查看结果」（#308，Mac 与 Windows 同一套入口）。
    @ViewBuilder private var phonePill: some View {
        if installFor == nil {
            if let s = model.session, S2ArmLauncherModel.phoneKinds.contains(s.kind), let id = s.gameID {
                Button { installFor = id } label: {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text(txt("install.pill.running").replacingOccurrences(of: "{0}", with: s.name).replacingOccurrences(of: "{1}", with: model.installTargetLabel)).font(.manrope(12.5, .semibold)).lineLimit(1)
                        if let f = s.progress.fraction { Text("\(Int(f * 100))%").font(.manrope(12)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("install.pill")
            } else if let r = model.phoneResult {
                Button { installFor = r.gameID } label: {
                    HStack(spacing: 7) {
                        Image(systemName: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(r.ok ? LauncherPalette.ready : LauncherPalette.danger)
                        Text(txt(r.ok ? "install.pill.done" : "install.pill.failed").replacingOccurrences(of: "{0}", with: r.name)
                             .replacingOccurrences(of: "{1}", with: r.ok && !model.installedTo.isEmpty ? model.installedTo : model.installTargetLabel)).font(.manrope(12.5, .semibold)).lineLimit(1)
                    }
                }
                .buttonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("install.pill")
            }
        }
    }

    /// The file URLs of a drop, delivered together on the main queue.
    static func fileURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(urls) }
    }
}

private struct ControllerToolbarButton: View {
    @ObservedObject var controller: NS2LauncherController
    @Binding var show: Bool
    let simplifiedChinese: Bool

    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 7) {
                Circle().fill(Color(nsColor: controller.buttonColor)).frame(width: 7, height: 7)
                Text(simplifiedChinese ? "手柄" : "Controller").font(.manrope(12.5, .semibold))
            }
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
        .help("Switch 2 Pro：" + controller.buttonStatus)
        .accessibilityLabel("Switch 2 Pro：" + controller.buttonStatus)
        .accessibilityIdentifier("top.controller")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            Switch2ProConnectionPopover(controller: controller, simplifiedChinese: simplifiedChinese)
        }
    }
}
