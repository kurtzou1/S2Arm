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
    /// 外层已用大标题写明是什么操作（导出自签包弹层）时不再画这一行，免得「导出自签包」下面又一行「导出，自己签名安装」
    var showsOperation = true
    @State private var showDetails = false
    /// 「更新这 N 款」里玩家取消勾的老款（缺省全勾）
    @State private var legacyOff: Set<String> = []

    private var language: String { loc.lang.sharedCode }
    /// 共用体验表的文案；查不到（不该发生，单测守着）退回 fallback，不把键名上屏
    private func t(_ id: String, _ fallback: String = "") -> String {
        let s = BackendText.launcherText(id, language: language)
        return s.hasPrefix("[") && s.hasSuffix("]") ? fallback : s
    }
    /// 文案用的作业名：手机上原来没有 S2Arm、这次「更新 iPhone 上的 S2Arm」其实是第一次装 → 写「安装」（installShell），不写「更新 / 已更新到」
    private var kindKey: String { session.kind == .installUpdate && model.shellFirstInstall ? "installShell" : session.kind.rawValue }
    private var device: String {
        // 作业结果里的那台（实际装上的）优先；进行中还没有结果时用这次要装的那台。不用 installedTo（那是上一次装机的设备）
        let d = model.phoneOutcome?.device ?? ""
        return d.isEmpty ? model.installTargetLabel : d
    }

    /// 导出自签包（游戏库「导出自签包」、S 级升级页「自签导出」）：装机 / 更新作业不连手机、出到文件夹。完成后看结果，进行中看这次会话
    private var exporting: Bool {
        guard session.kind == .install || session.kind == .installUpdate else { return false }
        if case .finished(.completed) = session.phase { return !(model.phoneOutcome?.exportFolder ?? "").isEmpty }
        return model.selfSigning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            // 这是什么操作（维护者：原先只看得到「更新中 · …」一小行）
            if showsOperation {
                Text(t(exporting ? "phone.title.export" : "phone.title." + kindKey)).font(.manrope(18, .bold)).accessibilityIdentifier("phone.operation")
            }
            switch session.phase {
            case .running, .stopping: running
            case .finished(.failed) where pendingConfirm != nil: dropAsk
            case .finished(.completed) where session.kind == .install && model.phoneOutcome?.app != nil: appDone(model.phoneOutcome!.app!)
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(LauncherPalette.building).frame(width: 9, height: 9)
                Text(t(exporting ? "phone.status.running.export" : "phone.status.running." + kindKey)).font(.manrope(14, .bold)).foregroundStyle(LauncherPalette.building)
                if !exporting { Text("· " + device).font(.manrope(13, .medium)).foregroundStyle(.secondary) }
            }
            .lineLimit(1)
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
            if p.unit == "files", !p.countText.isEmpty {
                Text(p.countText).font(.manrope(14, .medium)).monospacedDigit()
            }
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
        let sentence = t("phone.done." + kindKey, t("phone.done.install"))
            .replacingOccurrences(of: "{0}", with: device)
            .replacingOccurrences(of: "{1}", with: o?.version.isEmpty == false ? "v" + o!.version : "")
        var stats: [(String, String)] = []
        if let ended = session.ended { stats.append((t("phone.stat.time"), Self.duration(ended.timeIntervalSince(session.started), language: language))) }
        stats.append((t("phone.stat.device"), device))
        if session.kind == .install || session.kind == .installUpdate, kindKey != "installShell", let o {   // 第一次装 S2Arm：还没有游戏，不写「不用重推」
            stats.append((t("phone.stat.games"), (o.packBytes ?? 0) == 0 ? t("phone.stat.no_push")
                          : ByteCountFormatter.string(fromByteCount: o.packBytes ?? 0, countStyle: .file)))
        }
        var lines: [String] = []
        if session.kind == .install || session.kind == .installUpdate, kindKey != "installShell", let o {
            lines.append((o.packBytes ?? 0) == 0 ? t("phone.fact.no_push")
                         : t("phone.fact.pushed").replacingOccurrences(of: "{0}", with: ByteCountFormatter.string(fromByteCount: o.packBytes ?? 0, countStyle: .file))
                            .replacingOccurrences(of: "{1}", with: "\(o.packFiles ?? 0)"))
            if !o.skipped.isEmpty { lines.append(t("phone.fact.skipped").replacingOccurrences(of: "{0}", with: o.skipped.joined(separator: "、"))) }
        }
        return VStack(alignment: .leading, spacing: 26) {
            headline(seal: AnyView(SuccessSeal()), title: t("phone.headline." + kindKey, t("phone.headline.install")), subtitle: sentence)
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
            if let o { SGradeResultView(results: o.sgrade, text: { t($0) }) }   // 补进 S 级优化的各款：打上 / 没打上（11-14）
            if session.kind == .installUpdate, let o, !(o.legacy.isEmpty && o.legacyElsewhere.isEmpty) { legacySection(o) }
        }
        .accessibilityIdentifier("phone.done")
    }

    // ---- 0.5.x 老款：装好 App 的同一页接着列出、默认全勾，点「更新这 N 款」按「更新所选」逐款推（排队、有进度、可停）；别处装的只写一行 ----
    private func legacySection(_ o: PhoneOutcome) -> some View {
        let picked = o.legacy.filter { !legacyOff.contains($0.id) }
        return VStack(alignment: .leading, spacing: 12) {
            if !o.legacy.isEmpty {
                Text(t("phone.legacy.title").replacingOccurrences(of: "{0}", with: "\(o.legacy.count)")).font(.manrope(20, .heavy)).foregroundStyle(LauncherPalette.building)
                Text(t("phone.legacy.note")).font(.manrope(14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(o.legacy) { g in
                    Toggle(isOn: Binding(get: { !legacyOff.contains(g.id) }, set: { on in if on { legacyOff.remove(g.id) } else { legacyOff.insert(g.id) } })) {
                        Text(g.name).font(.manrope(15))
                    }.toggleStyle(PadToggleStyle(.checkbox)).controllerID("phone.legacy." + g.id)
                }
                Button { model.updateSelected(ids: picked.map(\.id), device: o.legacyDevice.isEmpty ? nil : o.legacyDevice) } label: {
                    Label(t("phone.legacy.button").replacingOccurrences(of: "{0}", with: "\(picked.count)"), systemImage: "arrow.up.circle")
                }.controllerButtonStyle(LauncherPrimaryButtonStyle(size: .prominent)).disabled(picked.isEmpty || model.phoneBusy).controllerID("phone.legacy.update").controllerShortcut(.rightTrigger)
            }
            if !o.legacyElsewhere.isEmpty {
                Text(t("phone.legacy.elsewhere").replacingOccurrences(of: "{0}", with: "\(o.legacyElsewhere.count)").replacingOccurrences(of: "{1}", with: o.legacyElsewhere.joined(separator: "、")))
                    .font(.manrope(14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("phone.legacy")
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
                LauncherHeadingLine {
                    Text(t("phone.headline.export")).font(.manrope(44, .heavy)).tracking(-1.4).accessibilityIdentifier("phone.title")
                } subtitle: {
                    // 路径可点：点了在访达打开。
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: o.exportFolder)) } label: {
                        Text(t("phone.done.export").replacingOccurrences(of: "{0}", with: (o.exportFolder as NSString).abbreviatingWithTildeInPath))
                            .font(.manrope(16)).foregroundStyle(.secondary).underline()
                    }
                    .controllerButtonStyle(.plain).help(o.exportFolder).controllerID("phone.export.path")
                }
            }
            if o.exportReused > 0 {
                Text(LauncherCopy.note(o.exportFresh.isEmpty ? t("phone.done.export.same")
                    : t("phone.done.export.fresh").replacingOccurrences(of: "{0}", with: o.exportFresh.joined(separator: "、")).replacingOccurrences(of: "{1}", with: "\(o.exportReused)")))
                    .font(.manrope(15, .semibold)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("phone.export.fresh")
            }
            if !o.exportUnwritten.isEmpty {   // 只新写了点的那款：别的款这次没写 .img，说清手机上已有照常能玩、没有怎么办（Windows PhoneJobCard 同）
                Text(LauncherCopy.note(t("phone.done.export.unwritten").replacingOccurrences(of: "{0}", with: o.exportUnwritten.joined(separator: "、"))))
                    .font(.manrope(15, .semibold)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("phone.export.unwritten")
            }
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
            HStack(spacing: 12) {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: o.exportFolder)) } label: { Label(t("phone.export.open"), systemImage: "folder") }
                    .controllerButtonStyle(LauncherPrimaryButtonStyle(size: .prominent)).accessibilityIdentifier("phone.export.open")
            }
            SGradeResultView(results: o.sgrade, text: { t($0) })   // 补进 S 级优化的各款：打上 / 没打上（11-14）
        }
        .accessibilityIdentifier("phone.done")
    }

    // ---- 独立 App（0.6.4）：A = 直接装到手机（装到哪台、手机上叫什么、哪天到期）；B = 只导出 ipa（文件夹、文件、签名、按签名方式的下一步）----
    //   两页都有「在访达中显示」（选中 ipa）；关闭在外层（装机页「关闭」）。各条分叉各自走到这里，不靠说明句指路（修流程不加提示）
    private func appDone(_ a: StandaloneApp) -> some View {
        let o = model.phoneOutcome ?? PhoneOutcome()
        let size = { (b: Int64?) in b.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "" }
        var stats: [(String, String)] = []
        var lines: [String] = []
        if !a.exported {
            stats.append((t("app.done.name"), a.name))
            if let end = a.expiresAt {
                let days = max(0, Int(ceil(end.timeIntervalSinceNow / 86400)))
                let day = end.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: language)))
                stats.append((t("app.done.expires"), t(a.expiresKnown ? "app.done.expiresValue" : "app.done.expiresEstimate")
                    .replacingOccurrences(of: "{0}", with: day).replacingOccurrences(of: "{1}", with: "\(days)")))
            }
            stats.append((t("app.done.data"), (o.packBytes ?? 0) == 0 ? t("app.done.pushedNone")
                : t("app.done.pushed").replacingOccurrences(of: "{0}", with: "\(o.packFiles ?? 0)").replacingOccurrences(of: "{1}", with: size(o.packBytes))))
            lines.append(t("app.done.open").replacingOccurrences(of: "{0}", with: a.name))
            lines += notes   // 第一次装要信任开发者、免费 Apple ID 的限制（装机页给的）
        } else {
            lines.append(a.signedCert.isEmpty ? t("app.export.unsigned") : t("app.export.signedCert").replacingOccurrences(of: "{0}", with: a.signedCert))
        }
        let files: [(String, String)] = a.exported
            ? [((a.ipaPath as NSString).lastPathComponent, size(a.ipaBytes)), ((a.s2armPath as NSString).lastPathComponent, size(a.s2armBytes))]
                + (a.resourceLinked && !a.resourcePath.isEmpty ? [((a.resourcePath as NSString).lastPathComponent,
                    [size(a.resourceBytes), t("app.export.noExtraSpace")].filter { !$0.isEmpty }.joined(separator: " · "))] : [])
            : []
        return VStack(alignment: .leading, spacing: 22) {
            // 大标题用短句（装机窗只有 600 宽）：装到哪台 / 哪款游戏放副标题，各项事实逐行「名称 + 值」，长值换行不截断
            headline(seal: AnyView(SuccessSeal()), title: t(a.exported ? "phone.headline.export" : "phone.headline.install"),
                     subtitle: a.exported ? t("app.export.title").replacingOccurrences(of: "{0}", with: a.name) : t("phone.done.install").replacingOccurrences(of: "{0}", with: device))
            if a.exported {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.ipaPath)]) } label: {
                    Text(t("app.export.folder").replacingOccurrences(of: "{0}", with: (a.gameFolder as NSString).abbreviatingWithTildeInPath))
                        .font(.manrope(14)).foregroundStyle(.secondary).underline().fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                .controllerButtonStyle(.plain).help(a.gameFolder).controllerID("app.export.folder")
            }
            ForEach(Array(stats.enumerated()), id: \.offset) { _, s in PhoneJobFact(label: s.0, text: s.1) }
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("app.export.files")).font(.manrope(14, .semibold)).foregroundStyle(.secondary)
                    ForEach(Array(files.enumerated()), id: \.offset) { _, f in
                        HStack(spacing: 10) {
                            Image(systemName: "doc").foregroundStyle(.secondary)
                            Text(f.0).font(.manrope(15, .medium)).lineLimit(1).truncationMode(.middle)
                            if !f.1.isEmpty { Text(f.1).font(.manrope(13)).foregroundStyle(.secondary).monospacedDigit() }
                        }
                    }
                    if a.exported, !a.resourceLinked, !a.resourcePath.isEmpty {
                        Text(t("app.export.imgElsewhere").replacingOccurrences(of: "{0}", with: a.resourcePath)).font(.manrope(13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                .accessibilityIdentifier("app.export.files")
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.manrope(14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if a.exported, !a.nextSteps.isEmpty {   // 下一步：只给这次签名方式那一段（作业层 app_folder.next_steps，按界面语言写好）
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("phone.next")).font(.manrope(15, .bold))
                    ForEach(Array(a.nextSteps.enumerated()), id: \.offset) { k, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(k + 1)").font(.manrope(13, .bold)).frame(width: 20, height: 20).background(LauncherPalette.ready.opacity(0.25), in: Circle())
                            Text(step).font(.manrope(14)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !a.readmePath.isEmpty {
                        Text(t("app.export.readme").replacingOccurrences(of: "{0}", with: (a.readmePath as NSString).lastPathComponent)).font(.manrope(13)).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("app.export.next")
            }
            LauncherFlowRow(spacing: 12, rowSpacing: 10) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.ipaPath)]) } label: { Label(t("app.done.reveal"), systemImage: "folder") }
                    .controllerButtonStyle(LauncherPrimaryButtonStyle(size: .prominent)).disabled(a.ipaPath.isEmpty).controllerID("app.reveal").accessibilityIdentifier("app.reveal")
                if a.exported, !a.readmePath.isEmpty {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: a.readmePath)) } label: { Label(t("app.export.openReadme"), systemImage: "doc.text") }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle(size: .prominent)).controllerID("app.readme").accessibilityIdentifier("app.readme")
                }
            }
            SGradeResultView(results: o.sgrade, text: { t($0) })
        }
        .accessibilityIdentifier(a.exported ? "app.exported" : "app.installed")
    }

    // ---- 失败：红色标记、大字、原因、下一步、复制错误摘要 ----
    /// 独立 App 已装上、资源没推完（作业失败结果 appInstalled）
    private var partial: Bool { session.kind == .install && model.phoneAppPartial != nil }

    private var failure: some View {
        VStack(alignment: .leading, spacing: 24) {
            headline(seal: AnyView(StatusSeal(symbol: "exclamationmark", color: LauncherPalette.danger)),
                     title: partial ? t("app.failed.partial") : exporting ? t("phone.failed.export") : t("phone.failed." + kindKey, t("phone.failed.install")),
                     subtitle: loc.backend(session.message))
            if partial {   // 独立 App 装上了、资源没推完：重试只推剩下的（推送只推变了的文件）
                PhoneJobFact(label: t("phone.next"), text: t("app.failed.partialNext"))
            } else if !session.suggestion.isEmpty {
                PhoneJobFact(label: t("phone.next"), text: loc.backend(session.suggestion))
            }
            if let choice = model.pushChoice, session.failureCode == PhoneOverview.choiceRequiredCode, session.kind == .install || session.kind == .pushSelected {
                chooser(choice)
            }
            ReportHint()
            LauncherFlowRow(spacing: 12, rowSpacing: 10) {
                // 还没用 Apple ID 登录 / 登录过期（0.6.0 Mac：S2Arm 自己登录）：就在这里登录，登录好再点一次（RECOVERY 的「登录 Apple ID」指的就是它）
                if let code = session.failureCode, let reason = S2ArmLauncherModel.appleLoginCodes[code] {
                    Button { model.openAppleLogin(host: model.installViewOpen != nil ? "install" : "main", reason: reason) } label: {
                        Label(t("install.login.open"), systemImage: "person.crop.circle")
                    }
                    .controllerButtonStyle(LauncherPrimaryButtonStyle(size: .prominent)).controllerID("phone.appleLogin").controllerShortcut(.rightTrigger)
                }
                if session.kind == .pushSelected {   // 「更新所选」有款没推成（#1756）：续推没推成的那几款
                    Button { model.retryUpdateSelected() } label: { Label(t("phone.retry"), systemImage: "arrow.clockwise") }
                        .controllerButtonStyle(LauncherPrimaryButtonStyle(size: .prominent)).disabled(model.phoneBusy).controllerID("phone.retry").controllerShortcut(.rightTrigger)
                }
                if session.kind == .install, let retry = model.lastInstallRetry {   // 单款推到 iPhone / 导出没走成：同样的参数再来一次（0.6.4）
                    Button { retry() } label: { Label(t("phone.retry"), systemImage: "arrow.clockwise") }
                        .controllerButtonStyle(LauncherPrimaryButtonStyle(size: .prominent)).disabled(model.phoneBusy).controllerID("phone.retry").controllerShortcut(.rightTrigger)
                }
                if session.kind == .installUpdate {
                    Button { model.retryPhoneUpdate() } label: { Label(t("phone.retry"), systemImage: "arrow.clockwise") }
                        .controllerButtonStyle(LauncherPrimaryButtonStyle(size: .prominent)).disabled(model.phoneBusy).controllerID("phone.retry").controllerShortcut(.rightTrigger)
                }
                // 装到 iPhone / 更新没走成（没连手机、签不上…）：换另一条路——导出自签包，不连手机也能一步走完
                if !exporting, session.kind == .install || session.kind == .installUpdate {
                    Button { model.switchToSelfSign(session, language: language) } label: { Label(t("phone.switch_export"), systemImage: "square.and.arrow.up") }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle(size: .prominent)).disabled(model.phoneBusy).controllerID("phone.switchExport")
                }
                CopyReportButton(model: model, gameID: session.gameID, operations: [session.kind.rawValue], fallback: session.message, size: .prominent)
            }
        }
        .accessibilityIdentifier("phone.failed")
    }

    /// 推送停在「装着不止一个 S2Arm、还没选」：就在失败页列出候选（同总控台「选用哪个 S2Arm」：只写事实、不推荐），点一个记住并自动重推刚才那一次
    private func chooser(_ choice: S2ArmLauncherModel.PushChoice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("console.choose.title").replacingOccurrences(of: "{0}", with: model.deviceKind(of: choice.device))).font(.manrope(13)).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            ForEach(choice.candidates, id: \.bundleId) { c in
                Button { model.chooseApp(device: choice.device, bundleId: c.bundleId) } label: {
                    HStack(spacing: 10) {
                        if model.consoleChoosing == c.bundleId { ProgressView().controlSize(.small) } else { Image(systemName: "app.badge.checkmark") }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(S2ArmLauncherModel.candidateLabelKeys(c).map { t($0) }.joined(separator: " · ")).font(.manrope(13, .medium))
                            Text(c.bundleId + (c.team.isEmpty ? "" : " · " + t("console.choose.team").replacingOccurrences(of: "{0}", with: c.team)))
                                .font(.manrope(11)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
                .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("phone.chooseApp." + c.bundleId)
                .disabled(model.consoleChoosing != nil || model.phoneBusy)
                .accessibilityIdentifier("phone.chooseApp." + c.bundleId)
            }
            if let why = model.consoleChooseError {
                Text(loc.backend(why)).font(.manrope(12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("phone.chooseApp")
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
        let title = BackendText.errorTitle(code, language: language, device: model.installTargetKind) ?? t("install.drop_title")
        return VStack(alignment: .leading, spacing: 24) {
            headline(seal: AnyView(StatusSeal(symbol: "exclamationmark", color: LauncherPalette.building)), title: title, subtitle: loc.backend(session.message))
            LauncherFlowRow(spacing: 12, rowSpacing: 10) {
                Button { if let d = model.dropConfirm { model.confirmDrop(d) } } label: { Label(t("install.drop_confirm"), systemImage: "arrow.right") }
                    .controllerButtonStyle(LauncherPrimaryButtonStyle(size: .prominent)).controllerID("phone.drop.confirm").controllerShortcut(.rightTrigger)
                // 这个码有并列的另一条路（共享体验表 alternate，如新建证书确认的「改用已有证书」）：玩家自己选，点了不重发、去那个动作的落点
                if let d = pendingConfirm, let alt = S2ArmLauncherModel.confirmAlternates[d.code] {
                    Button(t(alt.labelKey)) { model.takeConfirmAlternate(d) }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle(size: .prominent)).accessibilityIdentifier("phone.drop.alternate")
                }
                Button(t("phone.drop.cancel")) { model.dropConfirm = nil; model.backFromPhone() }
                    .controllerButtonStyle(LauncherSecondaryButtonStyle(size: .prominent)).accessibilityIdentifier("phone.drop.cancel")
            }
        }
        .accessibilityIdentifier("phone.drop")
    }

    private func headline(seal: AnyView, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            seal
            LauncherHeadingLine {
                Text(title).font(.manrope(52, .heavy)).tracking(-1.6).accessibilityIdentifier("phone.title")
            } subtitle: {
                if !subtitle.isEmpty {
                    Text(subtitle).font(.manrope(18)).foregroundStyle(.secondary).help(subtitle)
                }
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
        let s = max(0, Int(seconds.rounded()))
        return ExportSessionView.duration(seconds: s, exact: true, language: language)   // 同出包页一套写法（共享文案表 duration.*）
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
