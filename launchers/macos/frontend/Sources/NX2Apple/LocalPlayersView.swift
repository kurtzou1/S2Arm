// S2Arm addition (not in upstream NX2Apple): local players (#623), the same rules as the iPhone / iPad library
// (launchers/shared/SaveSync LocalPlayers). The top bar shows who the next game starts as; its popover picks, adds, renames
// and removes players. The launch job gets the current player (S2ArmLauncherModel.startPlay → pack/jobs/build.py runtime_env).
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import SaveSync

/// 本地玩家（#623）：Mac 启动器顶栏的玩家按钮 + 弹出面板。玩家表存在本机 App 偏好（UserDefaults.standard，同 iOS 的键），不在游戏库文件夹里
struct PlayerToolbarButton: View {
    /// 显式传入：按钮放在标题栏里（UnifiedTitlebar 另起的视图树），环境对象传不进去，用 @EnvironmentObject 起 App 当场崩（11-11 实机发现）
    @ObservedObject var loc: Localizer
    @State private var show = false
    @State private var players: [LocalPlayer] = []
    @State private var current = ""
    @State private var editing: Editing = .none
    @State private var text = ""
    @State private var error: String?
    private enum Editing: Equatable { case none, adding, renaming(String), removing(String) }

    private var store: LocalPlayers { S2ArmLauncherModel.playerStore(firstDefault: loc.t("s2arm.players.first")) }
    private func name(_ p: LocalPlayer) -> String { p.displayName(firstDefault: loc.t("s2arm.players.first")) }
    private var currentPlayer: LocalPlayer? { players.first { $0.uid == current } }

    var body: some View {
        Button { reload(); show.toggle() } label: {
            Label(currentPlayer.map(name) ?? loc.t("s2arm.players.first"), systemImage: "person.crop.circle")
                .lineLimit(1).frame(maxWidth: 140)
        }
        .controllerButtonStyle(ConsoleIconButtonStyle(backgroundless: true))
        .launcherTooltip((currentPlayer.map(name) ?? loc.t("s2arm.players.first")) + " · " + loc.t("s2arm.players.help"), placement: .below)
        .accessibilityLabel(loc.t("s2arm.players.player") + "：" + (currentPlayer.map(name) ?? ""))
        .controllerID("top.player")
        .onAppear(perform: reload)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            popover.frame(width: 340).padding(LauncherTheme.Metrics.cardInset).background(.regularMaterial)
                .controllerButtonStyle(LauncherSecondaryButtonStyle())
                .controllerBackAction("players.back") { if editing != .none { finish() } else { show = false } }
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 说明放标题下、整句换行，不截断（面板只有 340 宽，并排会被「…」吃掉）
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t("s2arm.players.title")).font(LauncherTheme.TypeStyle.panelTitle)
                Text(loc.t("s2arm.players.intro")).font(.manrope(12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(players) { row($0) }
            if editing == .adding { field(loc.t("s2arm.players.add.confirm")) { commit { try store.add(text) } } }
            else { Button { start(.adding, "") } label: { Label(loc.t("s2arm.players.add"), systemImage: "plus") }.controllerButtonStyle(.borderless).accessibilityIdentifier("players.add") }
            if let error { Text(error).font(.manrope(12, .semibold)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
    }

    @ViewBuilder private func row(_ p: LocalPlayer) -> some View {
        switch editing {
        case .renaming(let uid) where uid == p.uid:
            field(loc.t("s2arm.players.rename.confirm")) { commit { try store.rename(p.uid, to: text) } }
        case .removing(let uid) where uid == p.uid:
            VStack(alignment: .leading, spacing: 8) {
                Text(loc.t("s2arm.players.remove.body").replacingOccurrences(of: "{0}", with: name(p))).font(.manrope(12)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(loc.t("s2arm.players.cancel")) { finish() }.controllerShortcut(.back)
                    Button(loc.t("s2arm.players.remove")) { store.remove(p.uid); finish(); reload() }.controllerShortcut(.rightTrigger)
                }
            }
        default:
            HStack(spacing: 10) {
                Button { store.select(p.uid); reload(); show = false } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.uid == current ? "checkmark.circle.fill" : "circle").foregroundStyle(p.uid == current ? LauncherPalette.cream : .secondary)
                        Text(name(p)).font(.manrope(13.5, .semibold)).lineLimit(1)
                        if p.uid == current { Text(loc.t("s2arm.players.now")).font(.manrope(11, .semibold)).foregroundStyle(.green) }
                        Spacer()
                    }.contentShape(Rectangle())
                }.controllerButtonStyle(.plain).accessibilityIdentifier("players.row." + (p.isFirst ? "first" : p.uid))
                Button { start(.renaming(p.uid), p.name) } label: { Image(systemName: "pencil") }
                    .controllerButtonStyle(LauncherIconButtonStyle()).help(loc.t("s2arm.players.rename")).accessibilityLabel(loc.t("s2arm.players.rename"))
                if !p.isFirst {
                    Button { start(.removing(p.uid), "") } label: { Image(systemName: "trash") }
                        .controllerButtonStyle(LauncherIconButtonStyle()).help(loc.t("s2arm.players.remove")).accessibilityLabel(loc.t("s2arm.players.remove"))
                }
            }
        }
    }

    private func field(_ confirm: String, _ action: @escaping () -> Void) -> some View {
        HStack {
            TextField(loc.t("s2arm.players.name"), text: $text, prompt: Text(loc.t("s2arm.players.name")).foregroundColor(LauncherTheme.Colors.secondary))
                .textFieldStyle(LauncherTextFieldStyle()).onSubmit(action).accessibilityLabel(loc.t("s2arm.players.name"))
            Button(loc.t("s2arm.players.cancel")) { finish() }.controllerShortcut(.back)
            Button(confirm, action: action).keyboardShortcut(.defaultAction).controllerShortcut(.rightTrigger)
        }
    }
    private func commit(_ body: () throws -> Void) {
        do { try body(); finish(); reload() }
        catch {
            switch error as? LocalPlayers.NameError ?? .empty {
            case .empty: self.error = loc.t("s2arm.players.error.empty")
            case .taken: self.error = loc.t("s2arm.players.error.taken")
            }
        }
    }
    private func start(_ mode: Editing, _ initial: String) { editing = mode; text = initial; error = nil }
    private func finish() { editing = .none; text = ""; error = nil }
    private func reload() { players = store.all; current = store.current.uid }
}
