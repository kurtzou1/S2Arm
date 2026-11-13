// S2Arm（不是上游文件）：一个作业进行中的页面（一局、准备运行、打 iPhone 包、装到 iPhone、导入、一键处理环境）。
// 显示作业的阶段与事件、进度（第几步 / 本阶段计数与进度条 / 按实测速率算的剩余时间，JobProgress）、停止；作业结束后显示结局（iPhone 包可在访达里显示），回库。
// 阶段名、日志行是作业层的中文原句，按界面语言经 loc.backend 显示（适配层 BackendText）。
// 卡片样式沿用 NXLauncher（LauncherPalette / LauncherSecondaryButtonStyle / LauncherHeroActionLabel）。
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct JobSessionView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    let session: JobSession

    private var finished: JobOutcome.State? {
        if case .finished(let state) = session.phase { return state }
        return nil
    }

    /// 一局用 s2arm.play.*（同第一刀）；别的作业用 s2arm.job.*，完成那一条按作业说做成了什么。
    private var statusText: String {
        let play = session.kind == .play
        switch session.phase {
        case .running: return loc.t(play ? "s2arm.play.running" : "s2arm.job.running")
        case .stopping: return loc.t(play ? "s2arm.play.stopping" : "s2arm.job.stopping")
        case .finished(.completed): return play ? loc.t("s2arm.play.completed") : Self.text(loc, "s2arm.job.done." + session.kind.rawValue, fallback: "s2arm.job.done")
        case .finished(.cancelled): return loc.t(play ? "s2arm.play.cancelled" : "s2arm.job.cancelled")
        case .finished(.failed), .finished(.paused): return loc.t(play ? "s2arm.play.failed" : "s2arm.job.failed")   // paused：出包会话按「没全成」收尾，不会停在它
        case .finished(.interrupted): return loc.t(play ? "s2arm.play.interrupted" : "s2arm.job.interrupted")
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

    /// 文案查不到时退回通用句，不把键名上屏（11-11 截图里露出 S2ARM.JOB.DONE.INSTALLUPDATE）；各作业类型都有文案由单测守着
    static func text(_ loc: Localizer, _ key: String, fallback: String) -> String {
        let s = loc.t(key)
        return s == key ? loc.t(fallback) : s
    }

    var body: some View {
        if session.isPhoneJob { phonePage } else { generalPage }
    }

    /// 手机作业：统一的三态结局（PhoneJobPanel），下面一排按钮
    private var phonePage: some View {
        VStack(alignment: .leading, spacing: 26) {
            ScrollView { PhoneJobPanel(model: model, session: session).frame(maxWidth: .infinity, alignment: .leading) }
            HStack(spacing: 14) {
                if finished == nil {
                    Button { model.stop() } label: { LauncherHeroActionLabel(title: loc.t("s2arm.job.cancel"), symbol: "stop.fill") }
                        .buttonStyle(.plain).disabled(session.phase == .stopping).keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { model.backToLibrary() } label: { LauncherHeroActionLabel(title: loc.t("s2arm.play.back"), symbol: "chevron.left") }
                        .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 48).padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(statusText.uppercased()).font(.manrope(12, .bold)).tracking(1.3).foregroundStyle(statusColor)
                if session.kind != .play {
                    Text("· " + loc.t("s2arm.job.title." + session.kind.rawValue)).font(.manrope(12, .medium)).foregroundStyle(.secondary)
                }
            }
            // 一键处理环境的作业以检查项名为题（作业层原句）；游戏名不过翻译
            Text([.downloadMetal, .downloadIosPlatform, .installDotnet].contains(session.kind) ? loc.backend(session.name) : session.name)
                .font(.manrope(48, .heavy)).tracking(-1.4).lineLimit(2)
            if !session.stage.isEmpty, finished == nil {   // 结束了就不再挂最后一个阶段名（停了还写「游戏运行中」）
                Text(loc.backend(session.stage)).font(.manrope(16, .medium)).foregroundStyle(.secondary)
            }
            if finished == nil, session.kind != .play { progress }
            if case .finished(let state) = session.phase, state == .failed || state == .interrupted {
                CopyReportButton(model: model, gameID: session.gameID, operations: [], fallback: session.message)
                ReportHint()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(session.log.enumerated()), id: \.offset) { index, line in
                            Text(loc.backendLine(line)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id(index)
                        }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
                .onChange(of: session.log.count) { count in
                    if count > 0 { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(count - 1, anchor: .bottom) } }
                }
            }
            HStack(spacing: 14) {
                if finished == nil {
                    Button { model.stop() } label: {
                        LauncherHeroActionLabel(title: loc.t(session.kind == .play ? "s2arm.play.stop" : "s2arm.job.cancel"), symbol: "stop.fill")
                    }
                    .buttonStyle(.plain).disabled(session.phase == .stopping)
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { model.backToLibrary() } label: {
                        LauncherHeroActionLabel(title: loc.t("s2arm.play.back"), symbol: "chevron.left")
                    }
                    .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                    if let reveal = session.reveal, finished == .completed {
                        Button(loc.t("s2arm.job.reveal")) { revealInFinder(reveal) }
                            .buttonStyle(LauncherSecondaryButtonStyle())
                    }
                }
                Spacer()
            }
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 第几步 · 本阶段已用 · 还剩；有总量时加进度条与计数。
    @ViewBuilder private var progress: some View {
        let p = session.progress
        VStack(alignment: .leading, spacing: 8) {
            if let fraction = p.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).tint(LauncherPalette.building)
            }
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let parts = [p.index.flatMap { i in p.count.flatMap { $0 > 1 ? String(format: loc.t("s2arm.job.step"), i, $0) : nil } },
                             p.fraction.map { "\(Int($0 * 100))%" }, p.countText.isEmpty ? nil : p.countText,
                             p.rateText.isEmpty ? nil : p.rateText,
                             p.clock(at: timeline.date, left: loc.t("prog.eta"))]
                Text(parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.manrope(13, .medium)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)   // 每秒变：不换行，下面不跟着跳
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}
