// S2Arm（不是上游文件）：出包进行中与做完的页面（JobSessionView 的出包版，11-07 维护者「要让客户有参与感和期待感」）。
// 进行中：第 k / N 个平台、各平台排队情况；总用时、预计还需（倒数）与预计完成时刻；步骤清单（做完的打勾 + 实际用时，当前步高亮 +
// 进度条 + 本步已用，后面的排队）；详细记录收起。时间推算用适配层 MilestoneEstimate（只用真读数：本机历史 / 本步实际速度，
// 10-25 维护者：没有本机记录就不显示整单预计，不编数字）。
// 做完：按平台给结果与下一步（macOS：开始游戏、在访达中显示；iPhone / iPad：装到 iPhone、在访达中显示 .ipa；没成的：原因 + 复制错误摘要）。
// 11-08 维护者 重做：左栏是这款游戏的信息和磁盘空间；右栏是整体进度（分段条，段数 = 步骤）、三个时间，和每一步的名称、含义、单项进度与用时。
import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct ExportSessionView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @ObservedObject var covers: CoverCache
    @EnvironmentObject var loc: Localizer
    let session: JobSession
    let run: ExportRun
    /// 打开装机页。
    let install: (String) -> Void
    /// 打开释放空间。
    let freeSpace: (String) -> Void
    let uiLanguage: String
    @State private var logOpen = false
    @State private var copied: ExportPlatform?

    private var finished: JobOutcome.State? {
        if case .finished(let state) = session.phase { return state }
        return nil
    }

    private var statusText: String {
        switch session.phase {
        case .running: return loc.t("s2arm.export.running")
        case .stopping: return loc.t("s2arm.job.stopping")
        case .finished(.completed): return loc.t("s2arm.job.done.export")
        case .finished(.cancelled): return loc.t("s2arm.job.cancelled")
        case .finished: return loc.t(run.outcomes.values.contains { $0.state == .completed } ? "s2arm.export.partial" : "s2arm.job.failed")
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

    private func x(_ id: String) -> String { BackendText.launcherText("export." + id, language: uiLanguage) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                HStack(alignment: succeeded.isEmpty ? .top : .center, spacing: 48) {
                    VStack(alignment: .leading, spacing: 22) {
                        if let game { GameInfoPanel(covers: covers, game: game) }
                        if let space = session.space { spaceCard(space) }
                    }
                    .frame(width: 270)
                    VStack(alignment: .leading, spacing: 26) {
                        if succeeded.isEmpty { heading }
                        if finished == nil {
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                VStack(alignment: .leading, spacing: 26) {
                                    overall(at: timeline.date)
                                    steps(at: timeline.date)
                                }
                            }
                        } else {
                            results
                        }
                        log
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
    }

    // ---- heading: status and platform queue ----

    private var heading: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(statusText).font(.manrope(14, .bold)).foregroundStyle(statusColor)
                if finished == nil {
                    Text("· " + String(format: loc.t("s2arm.export.platformOf"), run.index + 1, run.platforms.count, platformName(run.current)))
                        .font(.manrope(13, .medium)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("export.platformOf")
                }
            }
            .accessibilityElement(children: .combine)
            if run.platforms.count > 1 {
                HStack(spacing: 8) {
                    ForEach(Array(run.platforms.enumerated()), id: \.element) { k, platform in pill(k, platform) }
                }
            }
        }
    }

    // ---- disk space ----

    private func spaceCard(_ space: PackSpace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(x("space.title")).font(.manrope(13, .bold))
            if let need = space.need, let free = space.free, free > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10))
                        Capsule().fill(need > free ? LauncherPalette.danger : LauncherPalette.cream)
                            .frame(width: max(4, g.size.width * min(1, Double(need) / Double(free))))
                    }
                }
                .frame(height: 6)
            }
            HStack {
                spaceFigure(x("space.need"), space.need)
                Spacer()
                spaceFigure(x("space.free"), space.free)
            }
            if space.basis == "rule" {
                Text(x("space.basis." + space.basis)).font(.manrope(11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(LauncherPalette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }

    private func spaceFigure(_ label: String, _ bytes: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.manrope(11.5)).foregroundStyle(.secondary)
            Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "-").font(.manrope(14, .bold)).monospacedDigit()
        }
    }

    private func platformName(_ p: ExportPlatform) -> String { loc.t("s2arm.export.platform." + p.rawValue) }

    /// 一个平台的排队情况：做完（勾 + 用时）、在做（转圈）、排队、没成。
    private func pill(_ k: Int, _ platform: ExportPlatform) -> some View {
        let outcome = run.outcomes[platform]
        let active = outcome == nil && k == run.index && finished == nil
        let (symbol, color): (String, Color) = {
            switch outcome?.state {
            case .completed?: return ("checkmark.circle.fill", LauncherPalette.ready)
            case .failed?, .interrupted?, .paused?: return ("exclamationmark.circle.fill", LauncherPalette.danger)   // paused：平台结局不会是它（作业层 stepEnded 只给 completed / failed / cancelled）
            case .cancelled?: return ("minus.circle", LauncherPalette.unbuilt)
            case nil: return (active ? "circle.dotted" : "circle", active ? LauncherPalette.building : LauncherPalette.unbuilt)
            }
        }()
        let detail = outcome.map { $0.state == .completed ? clock($0.seconds) : "" } ?? (active ? "" : loc.t("s2arm.export.queued"))
        return HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            Text(platformName(platform)).font(.manrope(12.5, .semibold))
            if !detail.isEmpty { Text(detail).font(.manrope(12)).monospacedDigit().foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.white.opacity(active ? 0.09 : 0.045), in: Capsule())
        .overlay(Capsule().strokeBorder(active ? LauncherPalette.building.opacity(0.55) : Color.white.opacity(0.06)))
        .accessibilityElement(children: .combine)
    }

    // ---- timing: elapsed, time left, done at ----

    private func estimate(at now: Date) -> MilestoneEstimate {
        session.progress.estimate(at: now)
    }

    /// 这一步在整单里占的比重：各步都有本机记录就按时间算，否则每步一样重（不编时间）。
    private func weights(_ plan: [Milestone]) -> [Double] {
        let measured = plan.map { $0.measured ?? -1 }
        return measured.contains(-1) || measured.reduce(0, +) <= 0 ? plan.map { _ in 1 } : measured.map { max($0, 1) }
    }

    /// 第 k 步的填充：作业层给了整单进度（overall）就按同一套权重从它切出这一段，各段和大百分比永远一致、只增不减；没有时照旧按估计
    private func fill(_ k: Int, _ e: MilestoneEstimate, weights w: [Double]) -> Double {
        guard let o = session.progress.overall, k < w.count else { return e.fill(k) }
        let total = w.reduce(0, +), before = w[..<k].reduce(0, +)
        return w[k] > 0 && total > 0 ? min(1, max(0, (o * total - before) / w[k])) : 0
    }

    /// 整单完成比例（多平台时算上前面做完的平台）。本平台这部分 = 作业层的 overall（没有时按各步估计）
    private func overallFraction(_ e: MilestoneEstimate, plan: [Milestone]) -> Double {
        let w = weights(plan), total = w.reduce(0, +)
        let thisPlatform = session.progress.overall ?? (total > 0 ? zip(plan.indices, w).reduce(0) { $0 + e.fill($1.0) * $1.1 } / total : 0)
        return min(1, (Double(run.index) + thisPlatform) / Double(max(1, run.platforms.count)))
    }

    @ViewBuilder private func overall(at now: Date) -> some View {
        let e = estimate(at: now)
        let plan = session.progress.track.plan
        let fraction = overallFraction(e, plan: plan)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(Int(fraction * 100))%").font(.manrope(58, .heavy)).tracking(-2).monospacedDigit()
                    .contentTransition(.numericText()).animation(.easeOut(duration: 0.5), value: Int(fraction * 100))
                Text(x("overall")).font(.manrope(14, .semibold)).foregroundStyle(.secondary)
            }
            segmented(e, plan: plan)
            HStack(alignment: .top, spacing: 44) {
                figure(loc.t("s2arm.export.elapsed"), clock(now.timeIntervalSince(run.started)), note: "")
                if let left = e.remaining {
                    figure(loc.t(run.platforms.count > 1 ? "s2arm.export.remainingPlatform" : "s2arm.export.remaining"), duration(left), note: "", accent: true)
                        .accessibilityIdentifier("export.remaining")
                    figure(x("finishLabel"), time(now.addingTimeInterval(left)),
                           note: "")
                } else if let step = e.stepRemainingByRate {
                    figure(loc.t("s2arm.export.stepRemaining"), duration(step), note: "", accent: true)
                        .accessibilityIdentifier("export.remaining")
                }
                Spacer(minLength: 0)
            }
            if e.remaining == nil && e.stepRemainingByRate == nil && !plan.isEmpty {
                Text(loc.t("s2arm.export.noHistory")).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 整体进度条：一步一段，当前段上有一道光。
    private func segmented(_ e: MilestoneEstimate, plan: [Milestone]) -> some View {
        let w = weights(plan), total = max(w.reduce(0, +), 1)
        return GeometryReader { g in
            HStack(spacing: 3) {
                ForEach(Array(plan.enumerated()), id: \.element.id) { k, m in
                    let width = max(10, (g.size.width - 3 * Double(plan.count - 1)) * w[k] / total)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.10))
                        Rectangle().fill(LauncherPalette.cream).frame(width: width * fill(k, e, weights: w))
                            .animation(.easeOut(duration: 0.9), value: fill(k, e, weights: w))
                        if k == e.index { ProgressSweep() }
                    }
                    .frame(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .accessibilityLabel(loc.backend(m.label))
                }
            }
        }
        .frame(height: 10)
    }

    private func figure(_ label: String, _ value: String, note: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.manrope(13, .semibold)).foregroundStyle(.secondary)
            Text(value).font(.manrope(30, .bold)).tracking(-0.6).monospacedDigit()
                .foregroundStyle(accent ? LauncherPalette.cream : .primary)
            if !note.isEmpty { Text(note).font(.manrope(12.5)).monospacedDigit().foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }

    // ---- steps ----

    @ViewBuilder private func steps(at now: Date) -> some View {
        let track = session.progress.track
        let e = estimate(at: now)
        VStack(alignment: .leading, spacing: 0) {
            if track.plan.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(session.stage.isEmpty ? loc.t("s2arm.export.waiting") : loc.backend(session.stage)).font(.manrope(14, .semibold))
                }
                .padding(.vertical, 14)
            }
            ForEach(Array(track.plan.enumerated()), id: \.element.id) { k, m in
                stepRow(k, m, current: track.index, e: e, now: now, last: k == track.plan.count - 1)
            }
        }
    }

    @ViewBuilder private func stepRow(_ k: Int, _ m: Milestone, current: Int?, e: MilestoneEstimate, now: Date, last: Bool) -> some View {
        let track = session.progress.track
        let state: StepState = current.map { k < $0 ? .done : (k == $0 ? .running : .pending) } ?? .pending
        let skipped = state == .done && track.started[m.id] == nil
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Group {
                    switch state {
                    case .done:
                        Image(systemName: skipped ? "arrow.uturn.right.circle" : "checkmark.circle.fill")
                            .font(.system(size: 18)).foregroundStyle(skipped ? LauncherPalette.unbuilt : LauncherPalette.ready)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    case .running: PulseDot()
                    default: Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5).frame(width: 14, height: 14)
                    }
                }
                .frame(width: 26, height: 26)
                if !last { Rectangle().fill(Color.white.opacity(0.09)).frame(width: 1).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(loc.backend(m.label)).font(.manrope(state == .running ? 17 : 14.5, state == .pending ? .medium : .bold))
                        .foregroundStyle(state == .pending ? .secondary : .primary)
                    if m.reuse == true {
                        Text(loc.t("s2arm.export.reuse")).font(.manrope(11, .semibold)).foregroundStyle(LauncherPalette.ready)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(LauncherPalette.ready.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 12)
                    stepTime(k, m, state: state, e: e)
                }
                if !m.purpose.isEmpty {
                    Text(loc.backend(m.purpose)).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if state == .running { stepProgress(k, m, e: e) }
            }
            .padding(.bottom, last ? 0 : 16)
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: state)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func stepTime(_ k: Int, _ m: Milestone, state: StepState, e: MilestoneEstimate) -> some View {
        let text: String = {
            switch state {
            case .done: return session.progress.track.duration(m.id).map(clock) ?? loc.t("s2arm.export.skipped")
            case .running: return String(format: loc.t("s2arm.export.stepElapsed"), clock(e.stepElapsed))
            default: return m.measured.flatMap { $0 > 0 ? x("step.expected").replacingOccurrences(of: "{0}", with: duration($0)) : nil } ?? ""
            }
        }()
        Text(text).font(.manrope(12.5)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
    }

    /// 当前步：单项进度条、百分比 / 数量 / 速度 / 还需，再加作业此刻在做什么（真实作业消息）。
    private func stepProgress(_ k: Int, _ m: Milestone, e: MilestoneEstimate) -> some View {
        let p = session.progress
        let value = p.fraction ?? (m.measured != nil ? e.fill(k) : nil)
        let left = e.stepRemainingByRate.map { x("step.left").replacingOccurrences(of: "{0}", with: duration($0)) }
        let parts = [p.fraction.map { "\(Int($0 * 100))%" }, p.unit == "%" ? "" : p.countText, p.unit == "B" ? p.rateText : "", left]
        let detail = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .leading) {
                LauncherProgressBar(value: value, height: 6)
                if value != nil { ProgressSweep().frame(height: 6).clipShape(Capsule()) }
            }
            .padding(.top, 6)
            // 这两行随作业事件有无、长短在变：恒占一行、不换行（空时透明占位），下面的步骤和日志不跟着上下跳
            Text(detail.isEmpty ? " " : detail).font(.manrope(12.5, .medium)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            let showMessage = !session.message.isEmpty && session.message != m.label && session.message != session.stage
            Text(showMessage ? loc.backend(session.message) : " ").font(.manrope(12)).foregroundStyle(Color.white.opacity(0.58)).lineLimit(1).truncationMode(.middle)
                .id(session.message).transition(.opacity).animation(.easeOut(duration: 0.25), value: session.message)
        }
    }

    // ---- results ----

    private var game: GameSummary? { model.games.first { $0.id == session.gameID } }

    private var succeeded: [ExportPlatform] {
        guard finished != nil else { return [] }
        return run.platforms.filter { run.outcomes[$0]?.state == .completed }
    }

    /// 结果：有做成的平台就是庆祝页（封章、大字、成果数字、下一步按钮）；没成的平台在下面列原因。
    private var results: some View {
        VStack(alignment: .leading, spacing: 30) {
            if !succeeded.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    SuccessSeal()
                    Text(finished == .completed ? x("done.title") : statusText).font(.manrope(52, .heavy)).tracking(-1.6)
                    Text(x(succeeded.contains(.ios) ? "done.ios" : "done.mac")).font(.manrope(18)).foregroundStyle(.secondary)
                }
                ForEach(succeeded, id: \.self) { platform in success(platform) }
            }
            let others = run.platforms.filter { !succeeded.contains($0) }
            if !others.isEmpty {
                CardGroup(loc.t("s2arm.export.results")) {
                    ForEach(Array(others.enumerated()), id: \.element) { k, platform in
                        if k > 0 { CardDivider() }
                        resultRow(platform)
                    }
                }
            }
        }
    }

    private func success(_ platform: ExportPlatform) -> some View {
        let o = run.outcomes[platform]!
        return VStack(alignment: .leading, spacing: 24) {
            if run.platforms.count > 1 { Text(platformName(platform)).font(.manrope(15, .bold)) }
            HStack(alignment: .top, spacing: 52) {
                bigStat(x("done.time"), clock(o.seconds))
                if let bytes = o.appBytes { bigStat(x(platform == .ios ? "done.ipa" : "done.macSize"), size(bytes)) }
                if platform == .ios, let bytes = o.packBytes { bigStat(x("done.pack"), size(bytes)) }
                Spacer(minLength: 0)
            }
            if !o.notes.isEmpty {   // 降级继续的玩家提示（作业层原句）：出成了照常给按钮，这里说清哪里用了兼容做法
                VStack(alignment: .leading, spacing: 8) {
                    Label(x("done.notes"), systemImage: "exclamationmark.triangle.fill").font(.manrope(14, .bold)).foregroundStyle(LauncherPalette.building)
                    ForEach(o.notes, id: \.self) { note in
                        Text(note).font(.manrope(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine).accessibilityIdentifier("result.\(platform == .ios ? "ios" : "mac").notes")
            }
            HStack(spacing: 14) {
                if platform == .ios {
                    Button { install(session.gameID ?? "") } label: { LauncherHeroActionLabel(title: x("done.install"), symbol: "iphone") }
                        .buttonStyle(.plain).keyboardShortcut(.defaultAction).accessibilityIdentifier("result.ios.install")
                    // 出包这步没有 IPA（装机时才组装、整库共用一份）：给「打开游戏文件夹」；真有 IPA 才给「显示 .ipa」
                    if let ipa = o.ipa, !ipa.isEmpty { finderButton(loc.t("s2arm.export.revealIpa")) { model.revealIpa(ipa) } }
                    if let game { finderButton(loc.t("s2arm.export.openGameFolder")) { model.reveal(game) } }
                } else {
                    Button { if let game { model.backToLibrary(); model.play(game, uiLanguage: uiLanguage) } } label: {
                        LauncherHeroActionLabel(title: loc.t("library.play"), symbol: "play.fill")
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("result.mac.play")
                    if let game { finderButton(loc.t("s2arm.export.openGameFolder")) { model.reveal(game) } }
                }
            }
            if platform == .ios {
                Text(x("done.installNote")).font(.manrope(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func finderButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "folder").font(.manrope(15, .bold)).foregroundStyle(LauncherPalette.cream)
                .padding(.horizontal, 24).frame(height: LauncherHeroAction.height)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(LauncherPalette.cream.opacity(0.3)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func bigStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.manrope(14, .semibold)).foregroundStyle(.secondary)
            Text(value).font(.manrope(34, .heavy)).tracking(-0.8).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// 出包结束的时刻：各平台用时加起来（做完以后页面不再走表）。
    private var lastEnd: Date { run.started.addingTimeInterval(run.outcomes.values.reduce(0) { $0 + $1.seconds }) }

    @ViewBuilder private func resultRow(_ platform: ExportPlatform) -> some View {
        let outcome = run.outcomes[platform]
        let name = platformName(platform)
        switch outcome?.state {
        case .completed?:
            CardRow(name, detail: String(format: loc.t("s2arm.export.readyTook"), clock(outcome!.seconds)), dot: LauncherPalette.ready) {
                HStack(spacing: 8) {
                    if platform == .mac {
                        Button(loc.t("library.play")) { if let game { model.backToLibrary(); model.play(game, uiLanguage: uiLanguage) } }
                            .accessibilityIdentifier("result.mac.play")
                        if let game { Button(loc.t("s2arm.export.openGameFolder")) { model.reveal(game) } }
                    } else {
                        Button(loc.t(model.installKey("s2arm.action.install"))) { install(session.gameID ?? "") }
                            .accessibilityIdentifier("result.ios.install")
                        if let ipa = outcome?.ipa, !ipa.isEmpty { Button(loc.t("s2arm.export.revealIpa")) { model.revealIpa(ipa) } }
                        if let game { Button(loc.t("s2arm.export.openGameFolder")) { model.reveal(game) } }
                    }
                }
                .launcherRowControls()
            }
        case .cancelled?, nil:
            CardRow(name, detail: loc.t(outcome == nil ? "s2arm.export.notStarted" : "s2arm.job.cancelled"), dot: LauncherPalette.unbuilt) { EmptyView() }
        case .some:
            failureRow(platform, name: name, outcome: outcome!)
        }
    }

    /// 没成：人话原因、下一步、能重试；错误摘要带齐电脑和游戏信息，告诉玩家发到哪。
    private func failureRow(_ platform: ExportPlatform, name: String, outcome: ExportRun.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.manrope(14.5, .bold))
            Text(loc.backend(outcome.message.isEmpty ? JobOutcome.interruptedMessage : outcome.message)).font(.manrope(13.5)).fixedSize(horizontal: false, vertical: true)
            if !outcome.suggestion.isEmpty { Text(loc.backend(outcome.suggestion)).font(.manrope(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            ReportHint()
            HStack(spacing: 8) {
                if outcome.code == "disk_full" {
                    Button(x("fix.space")) { freeSpace(session.gameID ?? "") }.buttonStyle(LauncherSecondaryButtonStyle())
                    Button(x("fix.continue")) { if let game { model.export(game, platforms: [platform], spaceOverride: true) } }.buttonStyle(LauncherSecondaryButtonStyle())
                }
                // 剃刀 M4：出包前不再按前端的环境检查结果挡人；作业因环境缺东西失败时（作业层错误码），这里给环境检查页的入口
                if let code = outcome.code, S2ArmLauncherModel.environmentCodes.contains(code) {
                    Button(loc.t("s2arm.env.title")) { model.showEnvironment = true }.buttonStyle(LauncherSecondaryButtonStyle())
                }
                Button(x("fail.retry")) { if let game { model.export(game, platforms: [platform]) } }.buttonStyle(LauncherSecondaryButtonStyle())
                Button(copied == platform ? loc.t("s2arm.export.copied") : loc.t("s2arm.export.copyError")) {
                    let fallback = S2ArmLauncherModel.reportUnavailable(loc.backend(outcome.message), code: outcome.code)
                    Task {
                        await model.copyErrorReport(platform: name, gameID: session.gameID, operations: [platform == .ios ? "ipa" : "build"], fallback: fallback)
                        copied = platform
                        try? await Task.sleep(for: .seconds(2))
                        if copied == platform { copied = nil }
                    }
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
            }
            HStack(spacing: 10) {
                Text(x("fail.feedback")).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link(x("fail.github"), destination: URL(string: "https://github.com/jhaizhou-ops/S2Arm/issues")!).font(.manrope(12.5, .semibold))
                Link(x("fail.x"), destination: URL(string: "https://x.com/happyjoejiang")!).font(.manrope(12.5, .semibold))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)   // 每行按内容宽度居中会让上下两个平台错开
    }

    // ---- log ----

    @ViewBuilder private var log: some View {
        if !session.log.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button { withAnimation(.easeInOut(duration: 0.18)) { logOpen.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text(loc.t("s2arm.export.log")).font(.manrope(15, .semibold)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(logOpen ? 90 : 0))
                    }
                    .padding(.leading, 2).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if logOpen {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(session.log.suffix(80).enumerated()), id: \.offset) { _, line in
                            Text(loc.backendLine(line)).font(.mono(12)).foregroundStyle(.secondary)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                    .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
                }
            }
        }
    }

    // ---- action bar ----

    private var actionBar: some View {
        HStack(spacing: 14) {
            if finished == nil {
                Button { model.stop() } label: { LauncherHeroActionLabel(title: loc.t("s2arm.job.cancel"), symbol: "stop.fill") }
                    .buttonStyle(.plain).disabled(session.phase == .stopping)
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityLabel(loc.t("s2arm.job.cancel"))
                Button { model.sessionHidden = true } label: { Text(x("running.back")).font(.manrope(13, .semibold)) }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                Text(loc.t("s2arm.export.hint")).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Button { model.backToLibrary() } label: { Label(loc.t("s2arm.play.back"), systemImage: "chevron.left").font(.manrope(13, .semibold)) }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .accessibilityLabel(loc.t("s2arm.play.back"))
            }
            Spacer()
        }
        .padding(.horizontal, 40).padding(.vertical, 16)
        .frame(maxWidth: 1180)
        .frame(maxWidth: .infinity)
    }

    // ---- time text ----

    /// 用时：「4 分 12 秒」/「4m 12s」。
    private func clock(_ seconds: Double) -> String { duration(seconds, exact: true) }

    /// 剩余：一分钟以上只写到分（倒数时不让秒数跳），「约 6 分钟」/「6 min」。
    private func duration(_ seconds: Double, exact: Bool = false) -> String {
        let s = max(0, Int(seconds.rounded()))
        let zh = loc.lang == .zh
        if s >= 3600 {
            let h = s / 3600, m = s % 3600 / 60
            return zh ? "\(h) 小时 \(m) 分" : "\(h)h \(m)m"
        }
        if s >= 60 {
            let m = exact ? s / 60 : Int((Double(s) / 60).rounded(.up)), r = s % 60
            if exact { return zh ? "\(m) 分 \(r) 秒" : "\(m)m \(r)s" }
            return zh ? "\(m) 分钟" : "\(m) min"
        }
        return zh ? "\(s) 秒" : "\(s)s"
    }

    private func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: loc.lang == .zh ? "zh_CN" : "en_US")
        f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: date)
    }
}
