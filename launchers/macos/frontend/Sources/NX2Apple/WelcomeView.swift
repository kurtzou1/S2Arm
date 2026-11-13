// S2Arm（不是上游文件）：游戏库还是空的时候的欢迎页，同时就是环境检查（11-08 维护者：不做卡片引导，玩家照着做就行）。
// 准备这台 Mac → 添加游戏 → 放入密钥（只有 NSP / XCI 要；解包好的游戏导入后直接进游戏库，不经过这步）。
// 任何时候只有一个主按钮，落在当前该做的那件事上；做完的步骤收成一行。下载进度就在对应工具那一行。
// 工具来自 preflight 作业（model.checks），只列要玩家动手的；文案在共享规格 launcher.items（welcome.*）。
// 回到 App 自动重查；还没装 Xcode 时每 5 秒看一眼，装好了 Metal / iOS 组件那两行自动亮起，玩家不用点「重新检查」。
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct WelcomeView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer

    private enum Step: Int { case mac, games, keys }

    private struct Tool: Identifiable {
        enum State { case ok, needs(ToolCheck), waiting }
        let id: String, symbol: String, name: String, what: String, meta: String, state: State
        var isOK: Bool { if case .ok = state { return true }; return false }
    }

    private static let appleTools: Set<String> = ["xcode", "metal", "ios_platform", "apple_team"]   // 检查项稳定 id（剃刀 M11）

    private var language: String { loc.lang == .zh ? "zh-Hans" : "en" }
    private func w(_ id: String) -> String { BackendText.launcherText("welcome." + id, language: language) }
    private func check(_ id: String) -> ToolCheck? { model.checks.first { $0.id == id } }

    private var macReady: Bool { model.environmentState == .ready || model.environmentState == .readyMac }
    private var keysReady: Bool { model.keysReady == true && !model.keysRejected }
    private var gamesChosen: Bool { !model.pendingImport.isEmpty || model.welcomeGame != nil }
    private var keysSettled: Bool { keysReady || model.welcomeGame != nil }
    private var current: Step { !macReady ? .mac : !gamesChosen ? .games : .keys }
    private func isDone(_ s: Step) -> Bool {
        switch s { case .mac: return macReady; case .games: return gamesChosen; case .keys: return keysSettled }
    }
    private var xcodeNotInstalled: Bool { check("xcode")?.action == "appStoreXcode" && check("xcode")?.ok == false }

    /// Xcode 还没走完首次设置时，后端把「打开 Xcode」挂在 Metal 这一项上；对玩家这是 Xcode 的事。
    private var tools: [Tool] {
        let xcode = check("xcode"), metal = check("metal"), ios = check("ios_platform")
        let firstLaunch = metal?.action == "openXcode"
        let hasXcode = xcode?.ok == true || firstLaunch
        let xcodeState: Tool.State = firstLaunch ? .needs(metal!) : (xcode.map { $0.ok ? .ok : .needs($0) } ?? .waiting)
        let metalState: Tool.State = !hasXcode || firstLaunch ? .waiting : (metal.map { $0.ok ? .ok : .needs($0) } ?? .waiting)
        let appleState: Tool.State = !hasXcode || firstLaunch ? .waiting : (check("apple_team").map { $0.ok ? .ok : .needs($0) } ?? .waiting)
        let iosState: Tool.State = !hasXcode || firstLaunch ? .waiting : (ios.map { $0.ok ? .ok : .needs($0) } ?? .waiting)
        return [
            Tool(id: "xcode", symbol: "hammer", name: w("tool.xcode.name"), what: w(firstLaunch ? "tool.xcode.open" : "tool.xcode.what"),
                 meta: firstLaunch ? "" : w("tool.xcode.meta"), state: xcodeState),
            Tool(id: "metal", symbol: "square.stack.3d.up", name: w("tool.metal.name"), what: w("tool.metal.what"), meta: w("tool.metal.meta"), state: metalState),
            Tool(id: "ios", symbol: "iphone", name: w("tool.ios.name"), what: w("tool.ios.what"), meta: w("tool.ios.meta"), state: iosState),
            Tool(id: "apple", symbol: "person.crop.circle", name: w("tool.apple.name"), what: w("tool.apple.what"), meta: "", state: appleState),
        ]
    }

    /// 苹果工具以外还没过的项（系统版本、游戏库放在云盘等）：不常见，照后端原话列出，不藏。
    private var otherFailing: [ToolCheck] {
        model.checks.filter { !$0.ok && !Self.appleTools.contains($0.id) && ($0.required(for: "prepare") || $0.required(for: "ipa")) }
    }

    /// 当前步骤里唯一配主按钮的那一项：第一个要动手的、且不是「只有 iPhone 才要」的。
    private var primaryToolID: String? {
        guard current == .mac else { return nil }
        return tools.first { t in if case .needs = t.state, t.id != "ios", t.id != "apple" { return true }; return false }?.id
    }

    var body: some View {
        HStack(spacing: 0) {
            intro.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            GeometryReader { column in ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    step(.mac, title: macReady ? w("step.mac.done") : w("step.mac.title"), last: false) { macContent }
                    step(.games, title: gamesChosen ? w("step.games.done") : w("step.games.title"), last: false) { gamesContent }
                    step(.keys, title: keysReady ? w("step.keys.done") : model.welcomeGame != nil ? w("step.keys.notNeeded") : w("step.keys.title"), last: true) { keysContent }
                    if let error = model.actionError(for: nil) ?? model.environmentError ?? visibleLibraryError {
                        Text(loc.backend(error)).font(.manrope(12.5)).foregroundStyle(LauncherPalette.danger)
                            .fixedSize(horizontal: false, vertical: true).padding(.leading, 46).padding(.top, 14)
                    }
                }
                .padding(.vertical, 44).padding(.trailing, 48)
                .frame(maxWidth: .infinity, minHeight: column.size.height, alignment: .leading)   // 内容短时和左栏一样垂直居中，长了再滚动
            } }
            .frame(width: 560)
        }
        .overlay(alignment: .bottomTrailing) {
            if macReady, model.welcomeGame != nil {
                Button { model.oneClickExport() } label: { LauncherHeroActionLabel(title: w("oneclick"), symbol: "shippingbox.fill") }
                    .buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(model.busy)
                    .padding(36)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: model.welcomeGame?.id)
        .background(alignment: .bottomLeading) {
            RadialGradient(colors: [LauncherPalette.cream.opacity(0.10), .clear], center: .bottomLeading, startRadius: 0, endRadius: 620)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.28), value: current)
        .animation(.spring(response: 0.42, dampingFraction: 0.68), value: keysReady)
        .task(id: xcodeNotInstalled) {
            guard xcodeNotInstalled else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let found = await Task.detached { XcodeLocator.detect() != nil }.value
                if found && !Task.isCancelled { model.checkEnvironment(); return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !model.busy { model.checkEnvironment() }
        }
    }

    /// 「还没有游戏库」是新玩家的常态（放密钥时自动建），不算错误。
    private var visibleLibraryError: String? {
        model.libraryError == LibraryProvider.noLibraryMessage ? nil : model.libraryError
    }

    // ---- 左：这是什么 ----

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            journey.padding(.bottom, 34)
            Text(w("title")).font(.manrope(44, .heavy)).tracking(-1.4).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Text(w("lead")).font(.manrope(16)).foregroundStyle(.secondary).lineSpacing(5)
                .frame(maxWidth: 440, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)
            Text(w("soon")).font(.manrope(14, .semibold)).foregroundStyle(LauncherPalette.cream.opacity(0.75))
                .padding(.top, 14)
            Spacer(minLength: 24)
            Text(loc.t("library.localNote")).font(.manrope(12)).foregroundStyle(.secondary)
        }
        .padding(48)
    }

    /// 一眼看懂这个 App 干什么：手柄 → iPhone、Mac。
    private var journey: some View {
        HStack(spacing: 18) {
            Image(systemName: "gamecontroller").font(.system(size: 40, weight: .thin))
            Capsule().fill(LauncherPalette.cream.opacity(0.35)).frame(width: 56, height: 1)
            Image(systemName: "iphone").font(.system(size: 40, weight: .thin))
            Image(systemName: "laptopcomputer").font(.system(size: 40, weight: .thin))
        }
        .foregroundStyle(LauncherPalette.cream)
        .accessibilityHidden(true)
    }

    // ---- 右：三步 ----

    private func step<Content: View>(_ s: Step, title: String, last: Bool, @ViewBuilder content: () -> Content) -> some View {
        let done = isDone(s)
        let active = s == current
        return HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(done ? LauncherPalette.ready : .clear)
                    Circle().strokeBorder(done ? .clear : (active ? LauncherPalette.cream : Color.white.opacity(0.18)), lineWidth: 1.5)
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    } else {
                        Text("\(s.rawValue + 1)").font(.manrope(14, .bold)).foregroundStyle(active ? LauncherPalette.cream : Color.secondary)
                    }
                }
                .frame(width: 30, height: 30)
                if !last { Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(title).font(.manrope(active ? 22 : 18, .bold)).tracking(-0.4)
                        .foregroundStyle(active || done ? Color.primary : Color.secondary)
                    if s == .mac && model.checking { ProgressView().controlSize(.small) }
                }
                .frame(minHeight: 30)
                content()
            }
            .padding(.bottom, last ? 0 : 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var macContent: some View {
        if model.checks.isEmpty {
            Text(w("step.mac.checking")).font(.manrope(14)).foregroundStyle(.secondary)
        } else if macReady && tools.allSatisfy(\.isOK) {
            Text(w("step.mac.doneDetail")).font(.manrope(14)).foregroundStyle(.secondary)
        } else {
            if !macReady { Text(w("step.mac.what")).font(.manrope(14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            VStack(spacing: 0) {
                ForEach(tools.filter { !$0.isOK || !macReady }) { tool in
                    toolRow(tool)
                    Divider().opacity(0.25)
                }
                ForEach(otherFailing) { other in
                    otherRow(other)
                    Divider().opacity(0.25)
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder private func toolRow(_ tool: Tool) -> some View {
        HStack(alignment: tool.isOK ? .center : .top, spacing: 12) {
            Image(systemName: tool.symbol).font(.system(size: 18, weight: .light)).foregroundStyle(LauncherPalette.cream)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.name).font(.manrope(14.5, .bold))
                if !tool.isOK {
                    Text(tool.what).font(.manrope(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !tool.meta.isEmpty { Text(tool.meta).font(.manrope(12)).foregroundStyle(Color.white.opacity(0.58)) }
                    if tool.id == "apple", case .needs(let c) = tool.state { appleGuide(pending: c.code == "xcode_team_pending") }
                    if let job = downloading(tool) { InlineProgress(session: job).padding(.top, 8) }
                    if let failed = failure(of: tool) {
                        Text(loc.backend(failed)).font(.manrope(12.5)).foregroundStyle(LauncherPalette.danger).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                        ReportHint()
                    }
                }
            }
            Spacer(minLength: 12)
            switch tool.state {
            case .ok: Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(LauncherPalette.ready)
            case .waiting: Text(w("tool.waiting")).font(.manrope(12)).foregroundStyle(Color.white.opacity(0.58)).fixedSize()
            case .needs(let c):
                if downloading(tool) != nil {
                    Button(w("tool.cancel")) { model.stop() }.buttonStyle(LauncherSecondaryButtonStyle())
                        .disabled(model.session?.phase == .stopping)
                } else if tool.id == "apple" {
                    VStack(alignment: .trailing, spacing: 8) {
                        repairButton(c, primary: false)
                        Button(loc.t("s2arm.env.recheck")) { model.checkEnvironment() }.buttonStyle(LauncherSecondaryButtonStyle()).disabled(model.checking)
                    }
                } else if model.repairQueue.contains(c) {
                    Text(w("tool.queued")).font(.manrope(12.5, .semibold)).foregroundStyle(.secondary).fixedSize()
                } else {
                    repairButton(c, primary: tool.id == primaryToolID)
                }
            }
        }
        .padding(.vertical, 12)
    }

    /// 登录 Apple ID 的分步指引（判据是团队号出现，所以最后一步是等团队列表）。
    private func appleGuide(pending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if pending { Text(w("tool.apple.pending")).font(.manrope(12.5, .semibold)).foregroundStyle(LauncherPalette.building).fixedSize(horizontal: false, vertical: true) }
            ForEach(1...4, id: \.self) { n in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(n)").font(.manrope(12, .bold)).monospacedDigit().foregroundStyle(LauncherPalette.cream).frame(width: 12)
                    Text(w("tool.apple.step\(n)")).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(w("tool.apple.note")).font(.manrope(12)).foregroundStyle(Color.white.opacity(0.58)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private func downloading(_ tool: Tool) -> JobSession? {
        guard case .needs(let c) = tool.state, let s = model.session, s.kind.rawValue == c.action else { return nil }
        return s
    }

    private func failure(of tool: Tool) -> String? {
        guard case .needs(let c) = tool.state, let f = model.inlineFailure, f.kind.rawValue == c.action else { return nil }
        return f.message
    }

    @ViewBuilder private func otherRow(_ c: ToolCheck) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 18, weight: .light)).foregroundStyle(LauncherPalette.danger).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(loc.backend(c.name)).font(.manrope(14.5, .bold))
                Text(loc.backend(c.message)).font(.manrope(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            repairButton(c, primary: false)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder private func repairButton(_ c: ToolCheck, primary: Bool) -> some View {
        if let action = c.action, case let key = "s2arm.env.action." + action, loc.t(key) != key {
            // 已有一个下载在跑时，另一个下载可以点（排队）；别的作业在跑时不能点
            let queueable = { if case .job = model.provider.environment.repairStep(for: action) { return true }; return false }() && model.session.map { model.isInline($0) && ![.keys, .importGames].contains($0.kind) } == true
            actionButton(loc.t(key), primary: primary, enabled: !model.checking && (!model.busy || queueable)) {
                // 换游戏库要选目录，选目录面板在环境检查页
                if model.provider.environment.repairStep(for: action) == .chooseLibrary { model.showEnvironment = true } else { model.repair(c) }
            }
        }
    }

    @ViewBuilder private var gamesContent: some View {
        if let game = model.welcomeGame {
            Text(game.name + (game.display.isEmpty ? "" : " · " + game.display)).font(.manrope(14)).foregroundStyle(.secondary).lineLimit(1)
        } else if gamesChosen {
            let urls = model.pendingImport
            Text(urls[0].lastPathComponent + (urls.count > 1 ? " +\(urls.count - 1)" : ""))
                .font(.manrope(14)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        } else {
            if current == .games {
                Text(w("step.games.what")).font(.manrope(14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // Xcode 下载很久：不是当前步骤也能先把游戏选了
            actionButton(w("step.games.action"), primary: current == .games, enabled: !model.busy) { model.showAddGames = true }
                .padding(.top, 2)
        }
    }

    @ViewBuilder private var keysContent: some View {
        if !keysSettled {
            if current == .keys {
                Text(w("step.keys.what")).font(.manrope(14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                actionButton(w("step.keys.action"), primary: true, enabled: !model.busy) { model.showKeys = true }
                    .padding(.top, 2)
            } else {
                Text(w("step.keys.skip")).font(.manrope(13.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func actionButton(_ title: String, primary: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Group {
            if primary {
                Button(action: action) {
                    Text(title).font(.manrope(14, .bold)).foregroundStyle(.black).fixedSize()
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(LauncherPalette.cream, in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button(action: action) { Text(title).font(.manrope(13, .semibold)).fixedSize() }
                    .buttonStyle(LauncherSecondaryButtonStyle())
            }
        }
        .disabled(!enabled).opacity(enabled ? 1 : 0.5)
    }
}
