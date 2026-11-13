// S2Arm（不是上游文件）：启动游戏页（11-11 维护者：原来的跳转页「太丑、太不 S2Arm」——红点 + 大标题 + 一大块黑框铺英文原始日志）。
// 版式同出包页（ExportSessionView）：左边这款游戏的封面卡（GameInfoPanel），右边状态与两个阶段（验证运行文件 → 游戏运行中，作业层 build.launch 的 c.begin），
//   结束后一张结果卡。失败只写一句人话（按作业层错误码取共享规格 errors.items 的标题）+ 下一步（errors.py RECOVERY，诊断里的 suggestion），
//   原始日志不上屏：进「上传给开发者」（上传没成退回导出诊断包）。底栏：在跑 = 停止游戏；结束 = 回到游戏库。
import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct PlaySessionView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @ObservedObject var covers: CoverCache
    @EnvironmentObject var loc: Localizer
    let session: JobSession
    let uiLanguage: String

    private var game: GameSummary? { model.games.first { $0.id == session.gameID } }
    private var finished: JobOutcome.State? { if case .finished(let s) = session.phase { return s }; return nil }
    private var failed: Bool { finished == .failed || finished == .interrupted }

    /// 作业层的两段（build.launch）：顺序固定；当前段 = 最近的 stage 事件
    private static let stages = ["验证运行文件", "游戏运行中"]
    private var currentStage: Int? { Self.stages.firstIndex(of: session.stage) }

    private var statusText: String {
        switch session.phase {
        case .running: return loc.t(currentStage == 1 ? "s2arm.play.running" : "s2arm.play.starting")
        case .stopping: return loc.t("s2arm.play.stopping")
        case .finished(.completed): return loc.t("s2arm.play.completed")
        case .finished(.cancelled): return loc.t("s2arm.play.cancelled")
        case .finished(.failed): return loc.t(currentStage == 1 ? "s2arm.play.crashed" : "s2arm.play.failed")   // 已经进了游戏才退出的不叫「启动失败」
        case .finished(.interrupted), .finished(.paused): return loc.t("s2arm.play.interrupted")   // 开局作业不会暂停（只有出包编排会），归到「被打断」
        }
    }

    private var statusColor: Color {
        switch session.phase {
        case .running, .stopping: return LauncherPalette.building
        case .finished(.completed): return LauncherPalette.ready
        case .finished(.cancelled): return LauncherPalette.unbuilt
        case .finished: return LauncherPalette.danger
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 48) {
                    if let game { GameInfoPanel(covers: covers, game: game).frame(width: 270) }
                    VStack(alignment: .leading, spacing: 26) {
                        heading
                        if failed { failureCard } else { stages }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 40)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            Divider().opacity(0.3)
            actionBar
        }
        .accessibilityIdentifier("play.page")
    }

    // ---- 状态 + 游戏名 ----

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(statusText).font(.manrope(14, .bold)).foregroundStyle(statusColor)
            }
            .accessibilityElement(children: .combine).accessibilityIdentifier("play.status")
            if game == nil {   // 游戏名在左边封面卡上（同出包页）；库里找不到这款时才在这里写
                Text(session.name).font(.manrope(40, .heavy)).tracking(-1.2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // ---- 两个阶段（在跑 / 正常结束 / 取消）----

    private var stages: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.stages.enumerated()), id: \.offset) { k, label in stageRow(k, label, last: k == Self.stages.count - 1) }
            if currentStage == 1, finished == nil {
                Text(loc.t("s2arm.play.windowHint")).font(.manrope(13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 40).padding(.top, 14)
            }
        }
    }

    private func stageRow(_ k: Int, _ label: String, last: Bool) -> some View {
        let done = finished == .completed || (currentStage.map { k < $0 } ?? false)
        let running = finished == nil && currentStage == k
        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Group {
                    if done { Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(LauncherPalette.ready) }
                    else if running { PulseDot() }
                    else { Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5).frame(width: 14, height: 14) }
                }
                .frame(width: 26, height: 26)
                if !last { Rectangle().fill(Color.white.opacity(0.09)).frame(width: 1, height: 22) }
            }
            Text(loc.backend(label)).font(.manrope(running ? 17 : 14.5, running || done ? .bold : .medium))
                .foregroundStyle(running || done ? .primary : .secondary)
                .padding(.top, 3)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: running)
        .accessibilityElement(children: .combine)
    }

    // ---- 失败：一句人话 + 下一步，原文只进摘要 / 诊断包 ----

    private var reasonTitle: String {
        session.failureCode.flatMap { BackendText.errorTitle($0, language: uiLanguage) } ?? loc.t("s2arm.play.failedGeneric")
    }

    private var failureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(LauncherPalette.danger)
                Text(reasonTitle).font(.manrope(22, .bold)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("play.reason")
            }
            if !session.suggestion.isEmpty {
                Text(loc.backend(session.suggestion)).font(.manrope(14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("play.next")
            }
            ReportHint()
            HStack(spacing: 10) {
                if let game {
                    Button { model.play(game, uiLanguage: uiLanguage) } label: {
                        Label(loc.t("s2arm.play.again"), systemImage: "play.fill").font(.manrope(13, .semibold))
                    }
                    .buttonStyle(LauncherSecondaryButtonStyle()).disabled(model.busy)
                    .accessibilityIdentifier("play.again")
                }
                CopyReportButton(model: model, gameID: session.gameID, operations: ["launch"], fallback: session.message)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(maxWidth: 640, alignment: .leading)
        .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(LauncherPalette.danger.opacity(0.25)))
    }

    // ---- 底栏 ----

    private var actionBar: some View {
        HStack(spacing: 14) {
            if finished == nil {
                Button { model.stop() } label: { LauncherHeroActionLabel(title: loc.t("s2arm.play.stop"), symbol: "stop.fill") }
                    .buttonStyle(.plain).disabled(session.phase == .stopping)
                    .keyboardShortcut(".", modifiers: .command).accessibilityIdentifier("play.stop")
            } else {
                Button { model.backToLibrary() } label: { LauncherHeroActionLabel(title: loc.t("s2arm.play.back"), symbol: "chevron.left") }
                    .buttonStyle(.plain).keyboardShortcut(.defaultAction).accessibilityIdentifier("play.back")
            }
            Spacer()
        }
        .padding(.horizontal, 40).padding(.vertical, 16)
        .frame(maxWidth: 1180)
        .frame(maxWidth: .infinity)
    }
}
