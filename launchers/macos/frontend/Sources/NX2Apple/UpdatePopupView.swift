// S2Arm（不是上游文件）：更新流程（11-13 维护者定稿草图）。打开时最多一个弹窗，只给最新一期：
//   ① 有新版：版本 + 这版的更新说明（签名清单 notes 的 sections），在同一张弹窗查看更新状态与操作；
//   ② 更新后第一次打开：「已更新到 vX」+ 这版的亮点（notes.highlights），「知道了」。
// 「消息」面板：公告（最新在前）和更新说明都在这里，旧的只在这里看、不弹不算未读。判定全在 pack/jobs/updater.py inbox，这里只显示。
import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

enum UpdateNoteCopy {
    private static let englishHeadings = [
        "这一版的重点": "Highlights",
        "新功能": "New Features",
        "改进": "Improvements",
        "修复": "Fixes",
        "从 0.5 升级": "Upgrading from 0.5",
        "系统要求": "System Requirements",
        "已知问题": "Known Issues",
        "数字": "By the Numbers",
    ]

    private static func prefersChinese(_ language: String) -> Bool {
        language == "zh-Hans" || language == "zh-Hant"
    }

    static func text(_ item: [String: Any], language: String) -> String {
        let english = prefersChinese(language) ? nil : item["en"] as? String
        return LauncherCopy.note(english ?? item["zh-Hans"] as? String ?? "")
    }

    static func heading(_ title: String, language: String) -> String {
        prefersChinese(language) ? title : englishHeadings[title] ?? title
    }
}

private func releasePage(_ version: String) -> URL? { URL(string: "https://github.com/jhaizhou-ops/S2Arm/releases/tag/v" + version) }

struct UpdatePopupView: View {
    @ObservedObject var model: S2ArmLauncherModel
    let language: String

    /// 关窗时 model.updatePopup 先清空、弹窗还在淡出：留住最后一份内容，免得淡出那一下闪成「有新版」的版面
    @State private var shown: [String: Any] = [:]

    private func t(_ id: String) -> String { BackendText.launcherText(id, language: language) }
    private var popup: [String: Any] { model.updatePopup ?? shown }
    private var version: String { popup["version"] as? String ?? "" }
    private var notes: [String: Any] { popup["notes"] as? [String: Any] ?? [:] }
    private var kind: String? { popup["kind"] as? String }

    var body: some View {
        Group {
            switch kind {
            case "afterUpdate":
                confirmationBody(title: t("update.after.title").replacingOccurrences(of: "{0}", with: version),
                                 subtitle: t("update.after.lead"),
                                 highlights: notes["highlights"] as? [[String: Any]] ?? [])
                    .accessibilityIdentifier("update.after")
            case "upToDate":
                confirmationBody(title: t("update.upToDate.title"), subtitle: version.isEmpty ? "" : "v" + version)
                    .accessibilityIdentifier("update.upToDate")
            default:
                updateBody.accessibilityIdentifier("update.popup")
            }
        }
        .launcherSheet(.form, height: nil)
        .onReceive(model.$updatePopup) { if let next = $0 { shown = next } }
    }

    private var updateBody: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                updateHeader
                releaseNotes
                updateStatus
                if model.updateGate != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(t("update.gate.confirm.title")).font(.manrope(14, .bold))
                        Text(model.updateRestartImpactText(t)).font(LauncherTheme.TypeStyle.detail)
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Spacer()
                            Button(t("update.gate.confirm.cancel")) { model.updateGate = nil }
                                .controllerButtonStyle(LauncherSecondaryButtonStyle())
                                .keyboardShortcut(.defaultAction)
                                .accessibilityIdentifier("update.gate.cancel").controllerID("update.gate.cancel")
                            Button(t("update.gate.confirm.restart")) { model.restartToUpdate(confirmed: true) }
                                .controllerButtonStyle(LauncherSecondaryButtonStyle())
                                .accessibilityIdentifier("update.gate.restart").controllerID("update.gate.restart")
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LauncherPalette.building.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("update.gate")
                }
            }
            .padding(LauncherTheme.Space.page)
            updateFooter
        }
    }

    private var updateHeader: some View {
        VStack(alignment: .leading, spacing: LauncherTheme.Space.small) {
            HStack(spacing: LauncherTheme.Space.medium) {
                Text("S2Arm v" + version).font(LauncherTheme.TypeStyle.title)
                Text(t("update.popup.kicker"))
                    .font(LauncherTheme.TypeStyle.detail)
                    .foregroundStyle(LauncherPalette.cream)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.black.opacity(0.25), in: Capsule())
                    .overlay(Capsule().strokeBorder(LauncherPalette.cream.opacity(0.4)))
                Spacer()
                Button { model.closeUpdatePopup() } label: {
                    Label(t("update.popup.close"), systemImage: "xmark")
                }
                .controllerButtonStyle(ConsoleIconButtonStyle(size: 32))
                .help(t("update.popup.close"))
                .controllerID("update.popup.close")
            }
            Text(t("update.popup.meta")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var releaseNotes: some View {
        let sections = notes["sections"] as? [[String: Any]] ?? []
        return LauncherReadingPane {
            VStack(alignment: .leading, spacing: 14) {
                if sections.isEmpty {
                    Text(t("update.popup.noNotes")).font(LauncherTheme.TypeStyle.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(UpdateNoteCopy.heading(section["title"] as? String ?? "", language: language))
                                .font(.manrope(14, .semibold)).foregroundStyle(LauncherPalette.cream)
                            bullets(section["items"] as? [[String: Any]] ?? [])
                        }
                    }
                }
            }
            .padding(LauncherTheme.Metrics.cardInset)
        }
        .launcherPanel()
    }

    @ViewBuilder private var updateStatus: some View {
        switch model.updateState {
        case .idle:
            EmptyView()
        case .working(let id, let percent):
            let downloading = id == "update.downloading"
            let title = t(downloading ? "update.menu.downloadingPlain" : id)
            updateProgress(title, detail: progressDetail(downloading: downloading, percent: percent), percent: percent, tint: LauncherPalette.cream)
        case .ready:
            let title = t("update.settings.ready").replacingOccurrences(of: "{0}", with: version)
            updateProgress(title, detail: "100%", percent: 100, tint: LauncherPalette.ready)
        case .failed(let code):
            downloadError(code)
        }
    }

    private func progressDetail(downloading: Bool, percent: Int?) -> String {
        var parts: [String] = []
        if downloading {
            let (received, expected) = model.updateDownloadBytes
            if received > 0 || expected > 0 {
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let receivedText = formatter.string(fromByteCount: Int64(clamping: received))
                if expected > 0 {
                    parts.append(receivedText + " / " + formatter.string(fromByteCount: Int64(clamping: expected)))
                } else {
                    parts.append(receivedText)
                }
            }
        }
        if let percent { parts.append("\(percent)%") }
        return parts.joined(separator: " · ")
    }

    private func updateProgress(_ title: String, detail: String, percent: Int?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: LauncherTheme.Space.small) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.manrope(13, .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: LauncherTheme.Space.small)
                if !detail.isEmpty {
                    Text(detail).font(LauncherTheme.TypeStyle.detail).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            LauncherProgressBar(value: percent.map { Double($0) / 100 }, height: 8, tint: tint)
                .accessibilityLabel(title)
        }
    }

    private func downloadError(_ code: String) -> some View {
        HStack(alignment: .top, spacing: LauncherTheme.Space.small) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(LauncherPalette.danger)
                .padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LauncherTheme.Space.xSmall) {
                Text(t("update.error." + code)).font(.manrope(13, .semibold)).foregroundStyle(LauncherPalette.cream)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: LauncherTheme.Space.small) {
                    Text(t("update.code").replacingOccurrences(of: "{0}", with: code))
                    Button { NSWorkspace.shared.open(S2ArmLauncherModel.downloadPage) } label: {
                        Text(t("update.download_page")).underline()
                    }
                    .controllerButtonStyle(.plain).foregroundStyle(LauncherPalette.cream)
                }
                .font(.manrope(12)).foregroundStyle(.secondary)
            }
        }
        .padding(LauncherTheme.Space.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPalette.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LauncherPalette.danger.opacity(0.4)).allowsHitTesting(false))
        .textSelection(.enabled)
    }

    private var updateFooter: some View {
        let actions = model.updateState.popupActions
        // 「完整更新说明」和按钮同一行、垂直居中；勾选框单独一行放在按钮下方右侧
        return LauncherSheetFooter {
            VStack(alignment: .trailing, spacing: LauncherTheme.Space.medium) {
                HStack(spacing: LauncherTheme.Space.small) {
                    if let link = releasePage(version) {
                        Button { NSWorkspace.shared.open(link) } label: {
                            Text(t("update.popup.fullLog")).font(LauncherTheme.TypeStyle.detail).underline()
                        }
                        .controllerButtonStyle(.plain).foregroundStyle(LauncherPalette.cream).controllerShortcut(.secondary)
                    }
                    Spacer(minLength: LauncherTheme.Space.medium)
                    Button(t(actions.secondary)) { model.closeUpdatePopup() }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle(capsule: true))
                        .keyboardShortcut(.cancelAction).controllerID("update.popup.later").controllerShortcut(.back)
                    Button {
                        if model.updateState == .ready { model.restartToUpdate() }
                        else { model.downloadUpdate() }
                    } label: {
                        HStack(spacing: LauncherTheme.Space.small) {
                            if !actions.primaryEnabled {
                                ProgressView().controlSize(.small).accessibilityHidden(true)
                            }
                            Text(t(actions.primary))
                        }
                    }
                    .controllerButtonStyle(LauncherPrimaryButtonStyle(capsule: true)).disabled(!actions.primaryEnabled || model.updateGate != nil)
                    .controllerID("update.popup.now").controllerPreferredFocus(true).controllerShortcut(.rightTrigger)
                }
                if actions.showsAutoRestart {
                    Toggle(t("update.popup.autoRestart"), isOn: $model.autoRestartWhenReady)
                        .toggleStyle(PadToggleStyle(.checkbox)).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
                        .controllerID("update.popup.autoRestart")
                }
            }
        }
    }

    private func confirmationBody(title: String, subtitle: String, highlights: [[String: Any]] = []) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle").font(.system(size: 26)).foregroundStyle(LauncherPalette.ready)
                LauncherSheetHeading(title, subtitle: subtitle)
            }
            if !highlights.isEmpty { bullets(highlights) }
            HStack {
                if !version.isEmpty, let link = releasePage(version) {
                    Button { NSWorkspace.shared.open(link) } label: { Text(t("update.popup.fullLog")).font(LauncherTheme.TypeStyle.detail).underline() }
                        .controllerButtonStyle(.plain).foregroundStyle(LauncherPalette.cream).controllerShortcut(.secondary)
                }
                Spacer()
                Button(t("update.after.ok")) { model.closeUpdatePopup() }
                    .controllerButtonStyle(LauncherPrimaryButtonStyle(capsule: true))
                    .keyboardShortcut(.defaultAction)
                    .controllerID("update.after.ok").controllerPreferredFocus(true).controllerShortcut(.rightTrigger, .back)
            }
        }
        .padding(LauncherTheme.Space.page)
    }

    private func bullets(_ items: [[String: Any]]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(UpdateNoteCopy.text(item, language: language)).font(LauncherTheme.TypeStyle.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }
}

/// 「消息」面板：公告（最新在前）+ 更新说明。打开即看过最新那条公告（model.openMessages）
struct MessagesPanel: View {
    @ObservedObject var model: S2ArmLauncherModel
    let language: String
    @Environment(\.dismiss) private var dismiss

    private func t(_ id: String) -> String { BackendText.launcherText(id, language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t("messages.title")).font(LauncherTheme.TypeStyle.panelTitle).padding(.horizontal, 4).padding(.bottom, 6)
            if model.messages.isEmpty {
                Text(t("messages.empty")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary).padding(4)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.messages.enumerated()), id: \.offset) { _, message in row(message) }
                }
            }
            .frame(maxHeight: 420)
        }
        .padding(LauncherTheme.Metrics.cardInset).frame(width: 440)
        .background(.regularMaterial)
        .environment(\.colorScheme, .dark)
        .controllerBackAction("messages.close") { dismiss() }
        .accessibilityIdentifier("messages.panel")
    }

    @ViewBuilder private func row(_ m: [String: Any]) -> some View {
        let unread = m["unread"] as? Bool == true
        VStack(alignment: .leading, spacing: 6) {
            if m["kind"] as? String == "feature" {   // 新功能大窗看过后留在这里：点了再看一遍（11-19 维护者定）
                Text(t("messages.kind.feature")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                let badge = m["badge"] as? [String: Any] ?? [:]
                Text((language == "en" ? badge["en"] as? String : nil) ?? badge["zh-Hans"] as? String ?? "").font(LauncherTheme.TypeStyle.body)
                Button { dismiss(); model.reopenFeature(m) } label: { Text(t("feature.reopen")).font(LauncherTheme.TypeStyle.detail).underline() }
                    .controllerButtonStyle(.plain).foregroundStyle(LauncherPalette.cream).accessibilityIdentifier("messages.feature.reopen")
            } else if m["kind"] as? String == "update" {
                let version = m["version"] as? String ?? ""
                Text(t("messages.kind.update").replacingOccurrences(of: "{0}", with: version) + " · " + t(m["installed"] as? Bool == true ? "messages.installed" : "messages.available"))
                    .font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                let notes = m["notes"] as? [String: Any] ?? [:]
                let items = (notes["highlights"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (notes["sections"] as? [[String: Any]] ?? []).flatMap { $0["items"] as? [[String: Any]] ?? [] }
                ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, item in
                    Text("• " + UpdateNoteCopy.text(item, language: language)).font(LauncherTheme.TypeStyle.body).fixedSize(horizontal: false, vertical: true)
                }
                if let link = releasePage(version) {
                    Button { NSWorkspace.shared.open(link) } label: { Text(t("update.popup.fullLog")).font(LauncherTheme.TypeStyle.detail).underline() }
                        .controllerButtonStyle(.plain).foregroundStyle(LauncherPalette.cream)
                }
            } else {
                HStack(spacing: 8) {
                    if unread { Circle().fill(LauncherPalette.danger).frame(width: 7, height: 7) }
                    Text(t(m["level"] as? String == "important" ? "messages.kind.important" : "messages.kind.notice")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                }
                Text(LauncherCopy.note((m["text"] as? [String: String])?[language] ?? ""))
                    .font(LauncherTheme.TypeStyle.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let link = (m["url"] as? String).flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.open(link) } label: { Text(t("notice.details")).font(LauncherTheme.TypeStyle.detail).underline() }
                        .controllerButtonStyle(.plain).foregroundStyle(LauncherPalette.cream)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(unread ? 0.07 : 0.0), in: RoundedRectangle(cornerRadius: 12))
    }
}
