// S2Arm（不是上游文件）：释放空间（spaceSurvey / spaceFree 作业）。列这款可删的 5 项（解包、中间产物、着色器缓存、Mac 运行版本、
// iPhone 包），每项给大小与「删了会怎样」（作业层定句），可勾选；存档、日志只显示大小、不能删。底部是勾选合计与「释放」：
// 直接删除、不进废纸篓，点了先二次确认；删完重读大小并显示释放了多少。有作业在跑时「释放」置灰，作业层拒绝时显示它的原话。
// 顶上切到「存储总览」（游戏库结构 v3「查」，StorageOverview.swift）：各存放位置占用 / 剩余、公共文件、各款大小。
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct FreeSpaceView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    let gameID: String
    @State private var chosen: Set<String> = []
    @State private var confirming = false
    @State private var overviewMode = false

    private var game: GameSummary? { model.games.first { $0.id == gameID } }
    private var space: GameSpace? { model.space?.gameId == gameID ? model.space : nil }
    private var total: Int64 { space?.bytes(of: chosen) ?? 0 }
    private var canFree: Bool { !chosen.isEmpty && total > 0 && !model.busy && !model.spaceFreeing && !model.spaceLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    // 标题跟着所在的页走；游戏名只在这一款的页显示，一行，太长截尾（总览不是某一款的）。
                    Text(overviewMode ? storage("title") : loc.t("s2arm.space.title")).font(.manrope(26, .heavy)).tracking(-0.6)
                        .lineLimit(1).fixedSize()
                    if !overviewMode {
                        Text(game?.name ?? space?.name ?? gameID).font(.manrope(14)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 12)
                if model.spaceFreeing, let note = model.lockWaitNote { Text(loc.backend(note)).font(.manrope(12)).foregroundStyle(.secondary) }
                if model.spaceLoading || model.spaceFreeing || model.overviewLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 16)
            // 切换单独一行、水平居中，夹在页头与内容之间。两段都是固定的短词，不放游戏名。
            Picker("", selection: $overviewMode) {
                Text(loc.t("s2arm.space.title")).tag(false)
                Text(storage("title")).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().accessibilityIdentifier("space.mode")
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 30).padding(.bottom, 20)
            if let error = model.spaceError {
                Text(loc.backend(error)).font(.manrope(12)).foregroundStyle(LauncherPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30).padding(.bottom, 12)
            }
            if let freed = model.spaceFreed {
                Text(String(format: loc.t("s2arm.space.freed"), Self.size(freed))).font(.manrope(12.5, .semibold))
                    .foregroundStyle(LauncherPalette.ready)
                    .padding(.horizontal, 30).padding(.bottom, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if overviewMode {
                        StorageOverviewSection(model: model)
                    } else if let space {
                        CardGroup(loc.t("s2arm.space.parts"), footnote: space.sharedBytes > 0 ? String(format: loc.t("s2arm.space.sharedNote"), Self.size(space.sharedBytes)) : "") {
                            ForEach(space.parts) { part in
                                CardRow(loc.backend(part.title), detail: loc.backend(part.rebuild)) {
                                    HStack(spacing: 14) {
                                        Text(Self.size(part.bytes)).font(.manrope(13, .semibold)).monospacedDigit()
                                            .foregroundStyle(part.bytes > 0 ? .primary : .secondary)
                                        Toggle("", isOn: binding(part.id)).toggleStyle(.checkbox).labelsHidden()
                                            .disabled(part.bytes == 0 || model.spaceFreeing)
                                            .accessibilityLabel(loc.backend(part.title))
                                    }
                                }
                                if part.id != space.parts.last?.id { CardDivider() }
                            }
                        }
                        CardGroup(loc.t("s2arm.space.kept"), footnote: loc.t("s2arm.space.keptNote")) {
                            ForEach(space.kept) { item in
                                CardRow(keptTitle(item.id)) {
                                    Text(Self.size(item.bytes)).font(.manrope(13, .semibold)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                if item.id != space.kept.last?.id { CardDivider() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 30).padding(.bottom, 24)
            }
            Divider().opacity(0.3)
            HStack(spacing: 14) {
                // 总览页没有可删的东西：不显示「已选」与「直接删除」。
                if !overviewMode {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(format: loc.t("s2arm.space.total"), Self.size(total))).font(.manrope(14, .bold)).monospacedDigit()
                        Text(loc.t("s2arm.space.direct")).font(.manrope(12)).foregroundStyle(LauncherPalette.danger)
                        if model.busy { Text(loc.t("s2arm.space.busy")).font(.manrope(12)).foregroundStyle(.secondary) }
                    }
                }
                Spacer(minLength: 8)
                if overviewMode {
                    Button(storage("refresh")) { model.loadOverview() }.buttonStyle(LauncherSecondaryButtonStyle()).disabled(model.overviewLoading)
                }
                Button(loc.t("launch.done")) { dismiss() }.buttonStyle(LauncherSecondaryButtonStyle())
                if !overviewMode { Button { confirming = true } label: {
                    Text(loc.t("s2arm.space.free")).font(.manrope(13.5, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(LauncherPalette.cream, in: Capsule())
                }
                .buttonStyle(.plain).disabled(!canFree).opacity(canFree ? 1 : 0.45) }
            }
            .padding(.horizontal, 30).padding(.vertical, 16)
        }
        .alert(String(format: loc.t("s2arm.space.confirmTitle"), Self.size(total)), isPresented: $confirming) {
            Button(loc.t("s2arm.space.confirm"), role: .destructive) {
                let parts = chosen
                chosen = []
                model.freeSpace(gameID, parts: parts)
            }
            Button(loc.t("s2arm.job.cancel"), role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .onAppear { model.loadSpace(gameID) }
        .frame(width: 640, height: 640)
        .onDisappear { model.clearSpaceFreed() }
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
    }

    private func storage(_ id: String) -> String { BackendText.launcherText("storage." + id, language: loc.lang == .zh ? "zh-Hans" : "en") }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { chosen.contains(id) }, set: { on in if on { chosen.insert(id) } else { chosen.remove(id) } })
    }

    /// 勾选的几项（显示名）+「直接删除、不能撤销」。
    private var confirmMessage: String {
        let names = (space?.parts ?? []).filter { chosen.contains($0.id) }.map { loc.backend($0.title) }.joined(separator: loc.lang == .zh ? "、" : ", ")
        return String(format: loc.t("s2arm.space.confirmMessage"), names)
    }

    private func keptTitle(_ id: String) -> String {
        let key = "s2arm.space.kept." + id
        return loc.t(key) == key ? id : loc.t(key)
    }

    /// 字节 → 「1.2 GB」（同访达：十进制）。
    static func size(_ bytes: Int64) -> String {
        bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
