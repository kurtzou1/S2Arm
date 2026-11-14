// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// S2Arm（不是上游文件）：手机作业（装到 iPhone / 续签、从手机删一款、装回上一版、更新手机上的 S2Arm）的进行中与结局，一份。
// 装机页（InstallView）与通用作业页（JobSessionView，更新手机上的 S2Arm）都用它，Windows 对应 PhoneJobCard（ExportPages.cs）。
// 11-11 维护者看「更新 iPhone 上的 S2Arm」做完的页面：成功了大标题还写「正在更新」、露出机读码、原始日志堆在黑框里、只换壳也说「资源包 0.0 GB 第一次全拷」、
//   成功失败分不清。这里三态分开：进行中（只增不减的整体进度 + 第几步）、成功（结论句 + 用时 + 推送情况）、失败（原因 + 下一步 + 复制错误摘要）；
//   日志只在「详细过程」里，机读码不上屏（文案查不到时退回通用句，不显示键名）。
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct PhoneJobPanel: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    let session: JobSession
    /// 成功页额外的提示（装机页：第一次打开前要信任、免费 Apple ID 7 天到期……）
    var notes: [String] = []
    @State private var showDetails = false

    private var language: String { loc.lang == .zh ? "zh-Hans" : "en" }
    /// 共用体验表的文案；查不到（不该发生，单测守着）退回 fallback，不把键名上屏
    private func t(_ id: String, _ fallback: String = "") -> String {
        let s = BackendText.launcherText(id, language: language)
        return s.hasPrefix("[") && s.hasSuffix("]") ? fallback : s
    }
    private var device: String {
        // 作业结果里的那台（实际装上的）优先；进行中还没有结果时用这次要装的那台。不用 installedTo（那是上一次装机的设备）
        let d = model.phoneOutcome?.device ?? ""
        return d.isEmpty ? model.installTargetLabel : d
    }

    /// 导出模式（装法「导出，自己签名安装」）：装机 / 更新作业不连手机、出到文件夹。完成后看结果，进行中看当前装法
    private var exporting: Bool {
        guard session.kind == .install || session.kind == .installUpdate else { return false }
        if case .finished(.completed) = session.phase { return !(model.phoneOutcome?.exportFolder ?? "").isEmpty }
        return model.installMode.mode == "export"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            // 这是什么操作（维护者：原先只看得到「更新中 · …」一小行）
            Text(t(exporting ? "phone.title.export" : "phone.title." + session.kind.rawValue)).font(.manrope(18, .bold)).accessibilityIdentifier("phone.operation")
            switch session.phase {
            case .running, .stopping: running
            case .finished(.failed) where pendingConfirm != nil: dropAsk
            case .finished(.completed) where exporting: exported
            case .finished(.completed): success
            case .finished(.cancelled): headline(seal: AnyView(StatusSeal(symbol: "xmark", color: LauncherPalette.unbuilt)), title: t("phone.cancelled", "已取消"), subtitle: "")
            case .finished: failure
            }
            details
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    // ---- 进行中：状态行、整体进度（只增不减，作业层 overall）、步骤 ----
    private var running: some View {
        let p = session.progress
        let value = p.overall ?? 0
        return VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                Circle().fill(LauncherPalette.building).frame(width: 9, height: 9)
                Text(t(exporting ? "phone.status.running.export" : "phone.status.running." + session.kind.rawValue)).font(.manrope(14, .bold)).foregroundStyle(LauncherPalette.building)
                if !exporting { Text("· " + device).font(.manrope(13, .medium)).foregroundStyle(.secondary) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(Int(value * 100))%").font(.manrope(58, .heavy)).tracking(-2).monospacedDigit()
                    .contentTransition(.numericText()).animation(.easeOut(duration: 0.5), value: Int(value * 100))
                Text(t("export.overall")).font(.manrope(14, .semibold)).foregroundStyle(.secondary)
            }
            LauncherProgressBar(value: value, height: 10)
            // 要玩家动手（钥匙串授权：作业事件 keychainPrompt）：步骤上方一块醒目的提示，不只埋在步骤列表里
            if p.keychainPrompt {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("phone.action")).font(.manrope(15, .bold)).foregroundStyle(LauncherPalette.building)
                    Text(t("install.keychain")).font(.manrope(14)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                .background(LauncherPalette.building.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LauncherPalette.building.opacity(0.8)))
                .accessibilityIdentifier("phone.action")
            }
            steps
        }
        .accessibilityIdentifier("phone.running")
    }

    /// 走过的阶段打勾，当前这步脉冲点，后面还有几步一行带过（手机作业没有 plan，后面几步叫什么要等作业层走到才知道）
    private var steps: some View {
        let names = session.stages
        let total = session.progress.count ?? names.count
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(names.enumerated()), id: \.offset) { k, name in
                let current = k == names.count - 1
                HStack(spacing: 12) {
                    Group {
                        if current { PulseDot() } else { Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(LauncherPalette.ready) }
                    }
                    .frame(width: 22, height: 22)
                    Text(loc.backend(name)).font(.manrope(current ? 16 : 14, current ? .bold : .medium)).foregroundStyle(current ? .primary : .secondary)
                }
            }
            if total > names.count {
                HStack(spacing: 12) {
                    Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5).frame(width: 13, height: 13).frame(width: 22, height: 22)
                    Text(t("phone.steps.more").replacingOccurrences(of: "{0}", with: "\(total - names.count)")).font(.manrope(14, .medium)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // ---- 成功：封章、大字、结论句、成果数字 ----
    private var success: some View {
        let o = model.phoneOutcome
        let sentence = t("phone.done." + session.kind.rawValue, t("phone.done.install"))
            .replacingOccurrences(of: "{0}", with: device)
            .replacingOccurrences(of: "{1}", with: o?.version.isEmpty == false ? "v" + o!.version : "")
        var stats: [(String, String)] = []
        if let ended = session.ended { stats.append((t("phone.stat.time"), Self.duration(ended.timeIntervalSince(session.started), language: language))) }
        stats.append((t("phone.stat.device"), device))
        if session.kind == .install || session.kind == .installUpdate, let o {
            stats.append((t("phone.stat.games"), (o.packBytes ?? 0) == 0 ? t("phone.stat.no_push")
                          : ByteCountFormatter.string(fromByteCount: o.packBytes ?? 0, countStyle: .file)))
        }
        var lines: [String] = []
        if session.kind == .install || session.kind == .installUpdate, let o {
            lines.append((o.packBytes ?? 0) == 0 ? t("phone.fact.no_push")
                         : t("phone.fact.pushed").replacingOccurrences(of: "{0}", with: ByteCountFormatter.string(fromByteCount: o.packBytes ?? 0, countStyle: .file))
                            .replacingOccurrences(of: "{1}", with: "\(o.packFiles ?? 0)"))
            if !o.skipped.isEmpty { lines.append(t("phone.fact.skipped").replacingOccurrences(of: "{0}", with: o.skipped.joined(separator: "、"))) }
        }
        return VStack(alignment: .leading, spacing: 26) {
            headline(seal: AnyView(SuccessSeal()), title: t("phone.headline." + session.kind.rawValue, t("phone.headline.install")), subtitle: sentence)
            HStack(alignment: .top, spacing: 52) {
                ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.0).font(.manrope(14, .semibold)).foregroundStyle(.secondary)
                        Text(s.1).font(.manrope(30, .heavy)).tracking(-0.6).monospacedDigit().lineLimit(1)
                    }
                }
            }
            if !(lines + notes).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((lines + notes).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.manrope(14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityIdentifier("phone.done")
    }

    // ---- 导出好了：放进哪个文件夹、几款、多大，怎么装一句话，打开文件夹（作业完成时已自动打开一次）----
    private var exported: some View {
        let o = model.phoneOutcome ?? PhoneOutcome()
        var stats: [(String, String)] = []
        if let ended = session.ended { stats.append((t("phone.stat.time"), Self.duration(ended.timeIntervalSince(session.started), language: language))) }
        stats.append((t("phone.stat.games"), "\(o.exportGames)"))
        if let b = o.exportBytes { stats.append((t("phone.stat.size"), ByteCountFormatter.string(fromByteCount: b, countStyle: .file))) }
        var lines = [t("phone.fact.export")]
        if !o.skipped.isEmpty { lines.append(t("phone.fact.export_skipped").replacingOccurrences(of: "{0}", with: o.skipped.joined(separator: "、"))) }
        // 紧凑排：勾与大字同一行、路径家目录写成 ~（装机窗 600×520，原先几款 / 多大 / 打开文件夹都被挤到第一屏下面）
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 18) {
                SuccessSeal()
                Text(t("phone.headline.export")).font(.manrope(44, .heavy)).tracking(-1.4).accessibilityIdentifier("phone.title")
            }
            // 路径可点：点了在访达打开（维护者 11-11：界面上的路径一律可点打开）
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: o.exportFolder)) } label: {
                Text(t("phone.done.export").replacingOccurrences(of: "{0}", with: (o.exportFolder as NSString).abbreviatingWithTildeInPath))
                    .font(.manrope(16)).foregroundStyle(.secondary).underline().fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain).accessibilityIdentifier("phone.export.path")
            HStack(alignment: .top, spacing: 52) {
                ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.0).font(.manrope(14, .semibold)).foregroundStyle(.secondary)
                        Text(s.1).font(.manrope(30, .heavy)).tracking(-0.6).monospacedDigit().lineLimit(1)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.manrope(14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            // 推到手机（11-13）：推进去了说一句；没推成写作业给的原因（缺线 / 没信任 / 没装 S2Arm…）+「推到手机」重试
            if !o.pushed.isEmpty {
                Label(t("phone.export.pushed").replacingOccurrences(of: "{0}", with: o.pushed.joined(separator: "、")), systemImage: "checkmark.circle")
                    .font(.manrope(14)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("phone.export.pushed")
            } else {
                Text(o.pushNote.isEmpty ? t("phone.export.push_hint") : loc.backend(o.pushNote))
                    .font(.manrope(14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("phone.export.pushNote")
            }
            HStack(spacing: 12) {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: o.exportFolder)) } label: { LauncherHeroActionLabel(title: t("phone.export.open"), symbol: "folder") }
                    .buttonStyle(.plain).accessibilityIdentifier("phone.export.open")
                if o.pushed.isEmpty {
                    Button { model.pushExportToPhone(gameID: session.gameID) } label: {
                        LauncherHeroActionLabel(title: model.exportPushing ? t("phone.export.pushing") : t("phone.export.push"), symbol: "iphone.and.arrow.forward")
                    }
                    .buttonStyle(.plain).disabled(model.exportPushing).accessibilityIdentifier("phone.export.push")
                }
            }
        }
        .accessibilityIdentifier("phone.done")
    }

    // ---- 失败：红色标记、大字、原因、下一步、复制错误摘要 ----
    private var failure: some View {
        VStack(alignment: .leading, spacing: 24) {
            headline(seal: AnyView(StatusSeal(symbol: "exclamationmark", color: LauncherPalette.danger)),
                     title: t("phone.failed." + session.kind.rawValue, t("phone.failed.install")), subtitle: loc.backend(session.message))
            if !session.suggestion.isEmpty {
                PhoneJobFact(label: t("phone.next"), text: loc.backend(session.suggestion))
            }
            ReportHint()
            HStack(spacing: 12) {
                if session.kind == .installUpdate {
                    Button { model.retryPhoneUpdate() } label: { LauncherHeroActionLabel(title: t("phone.retry"), symbol: "arrow.clockwise") }
                        .buttonStyle(.plain).disabled(model.busy).accessibilityIdentifier("phone.retry")
                }
                CopyReportButton(model: model, gameID: session.gameID, operations: [session.kind.rawValue], fallback: session.message)
            }
        }
        .accessibilityIdentifier("phone.failed")
    }

    /// 这次失败是作业层可确认继续的停装（会挤掉别处装的游戏 / 存档没能备份 / 都要按新版重出……，S2ArmLauncherModel.confirmCodes），且待确认的就是这一单
    private var pendingConfirm: S2ArmLauncherModel.DropConfirm? {
        guard let d = model.dropConfirm, d.kind == session.kind, session.failureCode == d.code else { return nil }
        return d
    }

    // ---- 认得出的风险：就在这页里问（「仍然继续」/「先不」），不弹散的对话框（维护者 11-11：玩家主动点了装机，认得出的让他确认，确认了就装）----
    //   标题取这个码在体验规格表里的 title（作业层那边写），正文是作业层的原句（说清是哪几款 / 为什么）
    private var dropAsk: some View {
        let code = pendingConfirm?.code ?? "container_would_drop"
        let title = BackendText.errorTitle(code, language: language) ?? t("install.drop_title")
        return VStack(alignment: .leading, spacing: 24) {
            headline(seal: AnyView(StatusSeal(symbol: "exclamationmark", color: LauncherPalette.building)), title: title, subtitle: loc.backend(session.message))
            HStack(spacing: 12) {
                Button { if let d = model.dropConfirm { model.confirmDrop(d) } } label: { LauncherHeroActionLabel(title: t("install.drop_confirm"), symbol: "arrow.right") }
                    .buttonStyle(.plain).accessibilityIdentifier("phone.drop.confirm")
                Button(t("phone.drop.cancel")) { model.dropConfirm = nil; model.backToLibrary() }
                    .buttonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("phone.drop.cancel")
            }
        }
        .accessibilityIdentifier("phone.drop")
    }

    private func headline(seal: AnyView, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            seal
            Text(title).font(.manrope(52, .heavy)).tracking(-1.6).accessibilityIdentifier("phone.title")
            if !subtitle.isEmpty {
                Text(subtitle).font(.manrope(18)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // ---- 详细过程（日志收起来，默认不展开）----
    @ViewBuilder private var details: some View {
        if !session.log.isEmpty {
            DisclosureGroup(isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(session.log.enumerated()), id: \.offset) { _, line in
                        Text(loc.backendLine(line)).font(.manrope(12)).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(t("phone.details")).font(.manrope(14, .semibold)).foregroundStyle(.secondary)
            }
            .tint(LauncherPalette.cream).accessibilityIdentifier("phone.details")
        }
    }

    /// 「1 分 5 秒」「45 秒」/「1 min 5 s」
    static func duration(_ seconds: Double, language: String) -> String {
        let s = max(0, Int(seconds.rounded())), m = s / 60, r = s % 60
        if language == "en" { return m > 0 ? "\(m) min \(r) s" : "\(r) s" }
        return m > 0 ? "\(m) 分 \(r) 秒" : "\(r) 秒"
    }
}

/// 失败 / 取消的标记：和成功的 SuccessSeal 同尺寸（84），实心圆 + 黑色符号
struct StatusSeal: View {
    let symbol: String
    let color: Color
    var body: some View {
        ZStack {
            Circle().fill(color).frame(width: 84, height: 84)
            Image(systemName: symbol).font(.system(size: 36, weight: .bold)).foregroundStyle(.black)
        }
        .frame(width: 84, height: 84).accessibilityHidden(true)
    }
}

/// 失败页的一条事实：灰色小标题 + 正文（「原因」「下一步」）
struct PhoneJobFact: View {
    let label: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.manrope(12, .bold)).tracking(0.6).foregroundStyle(.secondary)
            Text(text).font(.manrope(14)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}
