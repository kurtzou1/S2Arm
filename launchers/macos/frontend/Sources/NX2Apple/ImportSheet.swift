// S2Arm（不是上游文件）：添加游戏 / 放密钥弹窗（11-08 维护者）。拖进来或点按钮选；作业的进度和失败原因都留在弹窗里，成了自动关。
// 游戏能不能不要密钥由作业层判（解包好的游戏不要，NSP / XCI 要，keys_missing），这里不判格式。
// InlineProgress 是欢迎页下载行和这里共用的进度条。
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct ImportSheet: View {
    enum Kind { case games, keys }

    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    let kind: Kind
    @State private var targeted = false
    @State private var dropHint: String?
    @State private var detail: ImportSource?
    @State private var copyFeedback: UUID?
    @FocusState private var focusedSource: String?

    var page: S2ArmLauncherModel.ImportPage { model.importPage ?? (kind == .games ? .selection : .keys) }
    private var language: String { loc.lang == .zh ? "zh-Hans" : "en" }

    private func w(_ id: String) -> String {
        BackendText.launcherText("welcome.sheet." + (page == .selection ? "games." : "keys.") + id, language: language)
    }
    private func common(_ id: String) -> String { BackendText.launcherText("welcome.sheet." + id, language: loc.lang == .zh ? "zh-Hans" : "en") }

    private var job: JobSession? {
        guard let s = model.session, [.keys, .importGames].contains(s.kind) else { return nil }
        return s
    }
    private var failure: String? {
        guard let f = model.inlineFailure, [.keys, .importGames].contains(f.kind) else { return nil }
        return f.message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if page == .results {
                ZStack(alignment: .topLeading) {
                    results
                        .opacity(detail == nil ? 1 : 0)
                        .accessibilityHidden(detail != nil)
                        .allowsHitTesting(detail == nil)
                        .disabled(detail != nil)
                    if let detail { sourceDetails(detail) }
                }
            } else {
                picker
            }
            Spacer(minLength: 16)
            footer
                .layoutPriority(1)
        }
        .padding(30)
        .frame(width: 560, height: 500)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
        .onExitCommand {
            if let detail { backFromDetails(detail) }
            else if page == .results { model.cancelImport() }
            else { cancel() }
        }
    }

    private func resultText(_ id: String, count: Int? = nil) -> String {
        let text = common("result." + id)
        return count.map { text.replacingOccurrences(of: "{0}", with: String($0)) } ?? text
    }

    private func reason(_ source: ImportSource) -> String {
        if source.status == .unprocessed { return resultText("unprocessed") }
        // content_truncated 按码取共享规格的标题（「游戏文件不完整」，各格式通用；剃刀 M14：原先这里按扩展名另换一句）
        return source.code.flatMap { BackendText.errorTitle($0, language: language) } ??
            (source.reason.isEmpty ? resultText("unreadable") : loc.backend(source.reason))
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            let count = model.importedSourceCount
            let remaining = model.pendingSources.count
            Text(resultText(count == 0 ? "none" : count == 1 ? "one" : "many", count: count))
                .font(.manrope(26, .heavy)).tracking(-0.6)
                .accessibilityAddTraits(.isHeader)
            Text(resultText(remaining == 1 ? "pendingOne" : "pendingMany", count: remaining) +
                 (count == 0 ? "" : " " + resultText("inLibrary")))
                .font(.manrope(14)).foregroundStyle(.secondary).padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.pendingSources) { source in
                        HStack(spacing: 13) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 19)).foregroundStyle(.yellow)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.name).font(.manrope(14, .bold)).lineLimit(1).truncationMode(.middle)
                                Text(reason(source)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button(resultText("view")) { detail = source }
                                .buttonStyle(LauncherSecondaryButtonStyle())
                                .disabled(model.busy)
                                .accessibilityIdentifier("import.details." + source.id)
                                .focusable()
                                .focused($focusedSource, equals: source.id)
                        }
                        .padding(.vertical, 12)
                        Divider()
                    }
                }
                .padding(.horizontal, 13)
            }
            .scrollIndicators(.visible)
            // Let long lists use the available space above the fixed footer.
            .frame(height: min(CGFloat(remaining) * 65, job != nil || model.importBatchFailure != nil ? 266 : 310))
            .background(fieldBackground)
            .padding(.top, 20)
            if let job { InlineProgress(session: job).padding(.top, 12) }
            if let message = model.importBatchFailure {
                Text(loc.backend(message)).foregroundStyle(LauncherPalette.danger)
                    .lineLimit(3).padding(.top, 12)
            }
        }
    }

    private static let footerButtonWidth: CGFloat = 84

    private var footer: some View {
        HStack {
            if page == .results, detail == nil {
                Button(common("cancel")) { model.cancelImport() }
                    .buttonStyle(LauncherSecondaryButtonStyle())
            }
            Spacer()
            if let detail, page == .results {
                Button(resultText("back")) { backFromDetails(detail) }
                    .buttonStyle(LauncherSecondaryButtonStyle())
            } else if page == .results {
                Button(resultText("back")) { model.backFromImportResults() }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .disabled(model.busy)
                Button { model.retryImport() } label: {
                    Text(resultText("retry")).font(.manrope(13, .bold))
                        .foregroundStyle(.black)
                        .frame(width: Self.footerButtonWidth, height: LauncherControl.height)
                        .background(LauncherPalette.cream.opacity(model.busy ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
            } else {
                Button(common("cancel")) { cancel() }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .disabled(job?.phase == .stopping)
            }
        }
        .environment(\.launcherControlWidth, Self.footerButtonWidth)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(LauncherPalette.surface.opacity(0.45))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.17)) }
    }

    private func sourceDetails(_ source: ImportSource) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(reason(source)).font(.manrope(26, .heavy)).tracking(-0.6)
                .accessibilityAddTraits(.isHeader)
            Text(resultText("fileName")).font(.manrope(14, .bold)).padding(.top, 22)
            Text(source.fileName)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(fieldBackground).padding(.top, 6)
            HStack {
                Text(resultText("details")).font(.manrope(14, .bold))
                Spacer()
                Button {
                    if Self.copyDiagnostic(source) { copyFeedback = UUID() }
                } label: {
                    Image(systemName: copyFeedback == nil ? "document.on.document" : "checkmark")
                        .frame(width: 30, height: 30)
                        .background(fieldBackground)
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(source.diagnostic.isEmpty)
                .accessibilityLabel(resultText("copy"))
                .accessibilityValue(copyFeedback == nil ? "" : resultText("copied"))
                .help(resultText(copyFeedback == nil ? "copy" : "copied"))
                .task(id: copyFeedback) {
                    guard copyFeedback != nil else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    copyFeedback = nil
                }
            }
            .padding(.top, 14)
            ImportDiagnosticView(text: source.diagnostic.isEmpty ? reason(source) : source.diagnostic) {
                backFromDetails(source)
            }
                .padding(3).frame(height: 194)
                .background(fieldBackground).padding(.top, 5)
        }
    }

    private func backFromDetails(_ source: ImportSource) {
        guard detail?.id == source.id else { return }
        detail = nil
        copyFeedback = nil
        Task { @MainActor in
            await Task.yield()
            focusedSource = source.id
        }
    }

    static func copyDiagnostic(_ source: ImportSource, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(source.diagnostic, forType: .string)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(w("title")).font(.manrope(26, .heavy)).tracking(-0.6)
            Text(w("what")).font(.manrope(14)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            Group {
                if let job {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(job.name).font(.manrope(16, .bold)).lineLimit(1)
                        InlineProgress(session: job)
                        if !job.message.isEmpty, job.message != job.stage, job.message != "操作完成" {
                            Text(loc.backend(job.message)).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    dropZone
                }
            }
            .frame(height: 220)
            .padding(.top, 20)
            .animation(.easeOut(duration: 0.2), value: job == nil)
            if page == .keys, model.keysRejected, job == nil {
                Text(BackendText.launcherText("welcome.keys.unusable", language: loc.lang == .zh ? "zh-Hans" : "en")).font(.manrope(13)).foregroundStyle(LauncherPalette.danger)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            if page == .selection, job == nil, !model.importNoBase.isEmpty {   // #797：刚添加的款缺本体
                Text(model.importNoBase.map { BackendText.launcherText("import.noBase", language: loc.lang == .zh ? "zh-Hans" : "en").replacingOccurrences(of: "{0}", with: $0) }.joined(separator: "\n"))
                    .font(.manrope(13)).foregroundStyle(LauncherPalette.building)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12).accessibilityIdentifier("import.noBase")
            }
            if let dropHint, job == nil {
                Text(dropHint).font(.manrope(13)).foregroundStyle(LauncherPalette.danger)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            if let failure {
                Text(loc.backend(failure)).font(.manrope(13)).foregroundStyle(LauncherPalette.danger)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                CopyReportButton(model: model, gameID: nil, operations: ["import", "keys", "setup"], fallback: failure).padding(.top, 8)
                ReportHint().padding(.top, 4)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: page == .selection ? "square.and.arrow.down" : "key").font(.system(size: 34, weight: .light))
                .foregroundStyle(LauncherPalette.cream)
            Text(w("drop")).font(.manrope(18, .bold))
            Text(common("or")).font(.manrope(12.5)).foregroundStyle(.secondary)
            Button { browse() } label: { Text(w("browse")).font(.manrope(14, .bold)).foregroundStyle(.black).padding(.horizontal, 20).padding(.vertical, 9).background(LauncherPalette.cream, in: Capsule()).contentShape(Capsule()) }
                .buttonStyle(.plain).disabled(model.busy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(targeted ? LauncherPalette.cream.opacity(0.07) : LauncherPalette.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(targeted ? LauncherPalette.cream : Color.white.opacity(0.18), style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: [7, 5])))
        .animation(.easeOut(duration: 0.15), value: targeted)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            LauncherView.fileURLs(providers) { accept($0) }
            return true
        }
    }

    private func accept(_ urls: [URL]) {
        dropHint = urls.isEmpty ? common("dropUnreadable") : model.busy ? common("dropBusy") : nil
        guard dropHint == nil else { return }
        if page == .selection { model.importGames(urls, partialResults: true) } else { model.importKeys(urls[0]) }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.title = w("browse")
        panel.canChooseFiles = true
        panel.canChooseDirectories = page == .selection
        panel.allowsMultipleSelection = page == .selection
        if panel.runModal() == .OK { accept(panel.urls) }
    }

    private func cancel() {
        if job != nil { model.stop(); return }
        dropHint = nil
        model.cancelImport()
    }
}

private struct ImportDiagnosticView: NSViewRepresentable {
    final class TextView: NSTextView {
        var onExit: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { onExit?() }
    }

    let text: String
    let onExit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = true
        let editor = TextView()
        editor.isEditable = false
        editor.isSelectable = true
        editor.drawsBackground = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textContainerInset = NSSize(width: 7, height: 6)
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? TextView else { return }
        editor.onExit = onExit
        if editor.string != text { editor.string = text }
    }
}

/// 进度条 + 「百分比 · 已下 / 总量 · 速度 · 已用 · 还剩」，每秒走一次倒计时。没有读数时显示作业当前阶段。
struct InlineProgress: View {
    let session: JobSession
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let p = session.progress
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = p.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).tint(LauncherPalette.cream)
            } else {
                ProgressView().progressViewStyle(.linear).tint(LauncherPalette.cream)
            }
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let parts = [p.fraction.map { "\(Int($0 * 100))%" }, p.unit == "%" ? "" : p.countText, p.unit == "B" ? p.rateText : "",
                             p.fraction == nil ? loc.backend(session.stage) : p.clock(at: timeline.date, left: loc.t("prog.eta"))]
                Text(parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.manrope(12.5, .medium)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// 「上传给开发者」（11-13 诊断一键上传，取代原来的「复制错误摘要 / 导出诊断包」两个入口）：点了先说清传什么、不传什么，玩家确认才传。
///   作业层打一份和「导出诊断包」相同的脱敏包，带上这次失败的错误摘要（operations 为 nil = 没有作业记录的失败，如环境检查，带 fallback 正文），
///   传完只给一个短码、只复制码。上传没成（服务没开通 / 没网 / 被拒收）就说明原因、退回「导出诊断包」，玩家照旧手动发
/// 报错页统一的一句指引（11-13 全局「故障报修」）：凡有「上传给开发者」/ 失败下一步的地方都挂它（tests/report_hint_test.py 核）
struct ReportHint: View {
    @EnvironmentObject var loc: Localizer
    var body: some View {
        Text(loc.reportHint).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("report.hint")
    }
}

struct CopyReportButton: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    let gameID: String?
    let operations: [String]?
    let fallback: String
    @State private var showing = false

    var body: some View {
        Button(loc.t("s2arm.diagUpload.button")) { showing = true }
            .buttonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("diag.upload")
            .sheet(isPresented: $showing) {
                UploadDiagnosticsSheet(model: model, gameID: gameID, operations: operations, fallback: fallback) { showing = false }
                    .environmentObject(loc)
            }
    }
}

struct UploadDiagnosticsSheet: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    let gameID: String?
    let operations: [String]?
    let fallback: String
    let close: () -> Void
    enum Phase: Equatable { case confirm, uploading, done(S2ArmLauncherModel.DiagUploadReceipt), failed(String) }
    @State private var phase = Phase.confirm
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc.t("s2arm.diagUpload.title")).font(.manrope(17, .semibold))
            switch phase {
            case .confirm:
                Text(loc.t("s2arm.diagUpload.what")).font(.manrope(13)).fixedSize(horizontal: false, vertical: true)
                Text(loc.t("s2arm.diagUpload.not")).font(.manrope(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(loc.t("s2arm.diagUpload.cancel")) { close() }.buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                    Button(loc.t("s2arm.diagUpload.send")) { send() }.buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("diag.upload.send")
                }
            case .uploading:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(loc.t("s2arm.diagUpload.sending")).font(.manrope(13)) }
            case .done(let receipt):
                Text(loc.t("s2arm.diagUpload.done")).font(.manrope(13)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Text(receipt.code).font(.system(size: 26, weight: .semibold, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("diag.upload.code")
                    Button(copied ? loc.t("s2arm.export.copied") : loc.t("s2arm.diagUpload.copy")) { copy(receipt.code) }.buttonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("diag.upload.copy")
                }
                Text(loc.t("s2arm.diagUpload.repo").replacingOccurrences(of: "{0}", with: receipt.repo)).font(.manrope(12.5)).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Spacer()
                    Button(loc.t("s2arm.diagUpload.close")) { close() }.buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                    if let url = receipt.issueURL {   // 主按钮：系统浏览器打开预填好诊断码 / 版本 / 平台的新帖页
                        Button(loc.t("s2arm.diagUpload.github")) { NSWorkspace.shared.open(url) }.buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("diag.upload.github")
                    }
                }
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle").font(.manrope(13)).foregroundStyle(LauncherPalette.danger).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("diag.upload.failed")
                HStack {
                    Spacer()
                    Button(loc.t("s2arm.diagUpload.close")) { close() }.buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                    Button(loc.t("s2arm.play.diagnostics")) { exportInstead() }.buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("diag.upload.export")
                }
            }
        }
        .padding(22).frame(width: 440)
        .onReceive(model.$diagUploadCommand) { command in   // 控制口替玩家点（只认当前这一步有的按钮）
            guard let command else { return }
            model.diagUploadCommand = nil
            switch (command.action, phase) {
            case ("send", .confirm): send()
            case ("copy", .done(let receipt)): copy(receipt.code)
            case ("close", _): close()
            default: break
            }
        }
    }

    private func copy(_ code: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string); copied = true }

    private func send() {
        phase = .uploading
        Task {
            do { phase = .done(try await model.uploadDiagnostics(gameID: gameID, operations: operations, fallback: fallback)) }
            catch { phase = .failed(error.localizedDescription) }
        }
    }

    /// 退回导出：同游戏库「更多」里的导出（文件名、脱敏规则一样）
    private func exportInstead() {
        let panel = NSSavePanel()
        let stamp = DateFormatter(); stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "MMdd-HHmm"
        panel.nameFieldStringValue = "S2Arm-\(loc.lang == .zh ? "诊断" : "diag")-\(stamp.string(from: Date())).zip"
        if panel.runModal() == .OK, let url = panel.url { close(); model.diagnostics(exportTo: url) }
    }
}
