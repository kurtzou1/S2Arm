// S2Arm（不是上游文件）：更新流程（11-13 维护者定稿草图）。打开时最多一个弹窗，只给最新一期：
//   ① 有新版：版本 + 这版的更新说明（签名清单 notes 的 sections），「以后再说」/「现在更新并重启」；
//   ② 更新后第一次打开：「已更新到 vX」+ 这版的亮点（notes.highlights），「知道了」。
// 「消息」面板：公告（最新在前）和更新说明都在这里，旧的只在这里看、不弹不算未读。判定全在 pack/jobs/updater.py inbox，这里只显示。
import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

/// 更新说明里的一条：{zh-Hans, en?}；英文没有就用中文
private func noteText(_ item: [String: Any], _ language: String) -> String {
    (language == "en" ? item["en"] as? String : nil) ?? item["zh-Hans"] as? String ?? ""
}

private func releasePage(_ version: String) -> URL? { URL(string: "https://github.com/jhaizhou-ops/S2Arm/releases/tag/v" + version) }

struct UpdatePopupView: View {
    @ObservedObject var model: S2ArmLauncherModel
    let language: String

    private func t(_ id: String) -> String { BackendText.launcherText(id, language: language) }
    private var popup: [String: Any] { model.updatePopup ?? [:] }
    private var version: String { popup["version"] as? String ?? "" }
    private var notes: [String: Any] { popup["notes"] as? [String: Any] ?? [:] }
    private var after: Bool { popup["kind"] as? String == "afterUpdate" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if after { afterBody } else { updateBody }
        }
        .padding(.horizontal, 36).padding(.vertical, 32)
        .frame(width: after ? 600 : 680)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier(after ? "update.after" : "update.popup")
    }

    private var updateBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(t("update.popup.kicker")).font(.manrope(13, .semibold)).foregroundStyle(LauncherPalette.cream.opacity(0.8))
                Text("S2Arm v" + version).font(.manrope(28, .heavy))
                Text(t("update.popup.meta")).font(.manrope(13)).foregroundStyle(.secondary)
            }
            let sections = notes["sections"] as? [[String: Any]] ?? []
            if sections.isEmpty {
                Text(t("update.popup.noNotes")).font(.manrope(14)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section["title"] as? String ?? "").font(.manrope(14, .semibold)).foregroundStyle(LauncherPalette.cream)
                                bullets(section["items"] as? [[String: Any]] ?? [])
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
            }
            if case .working = model.updateState {
                Text(t("update.popup.downloading")).font(.manrope(12.5)).foregroundStyle(.secondary)
            }
            if let gate = model.updateGate {   // 草图④：点了「现在更新并重启」但有局 / 任务在跑，先拦下、说清，弹窗不关
                VStack(alignment: .leading, spacing: 4) {
                    Text(t(gate)).font(.manrope(14, .bold))
                    Text(t(gate + ".body")).font(.manrope(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(LauncherPalette.building.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("update.gate")
            }
            HStack {
                if let link = releasePage(version) {
                    Button { NSWorkspace.shared.open(link) } label: { Text(t("update.popup.fullLog")).font(.manrope(13)).underline() }
                        .buttonStyle(.plain).foregroundStyle(LauncherPalette.cream)
                }
                Spacer()
                Button(t("update.popup.later")) { model.closeUpdatePopup() }.buttonStyle(LauncherSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("update.popup.later")
                Button { model.restartToUpdate() } label: { Text(t("update.popup.now")).font(.manrope(14, .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 20).frame(height: 40).background(LauncherPalette.cream, in: Capsule()) }
                    .buttonStyle(.plain).disabled(model.updateState != .ready).opacity(model.updateState == .ready ? 1 : 0.5)
                    .accessibilityIdentifier("update.popup.now")
            }
        }
    }

    private var afterBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle").font(.system(size: 26)).foregroundStyle(LauncherPalette.ready)
                Text(t("update.after.title").replacingOccurrences(of: "{0}", with: version)).font(.manrope(26, .heavy))
            }
            Text(t("update.after.lead")).font(.manrope(14)).foregroundStyle(.secondary)
            bullets(notes["highlights"] as? [[String: Any]] ?? [])
            HStack {
                if let link = releasePage(version) {
                    Button { NSWorkspace.shared.open(link) } label: { Text(t("update.popup.fullLog")).font(.manrope(13)).underline() }
                        .buttonStyle(.plain).foregroundStyle(LauncherPalette.cream)
                }
                Spacer()
                Button { model.closeUpdatePopup() } label: { Text(t("update.after.ok")).font(.manrope(14, .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 22).frame(height: 40).background(LauncherPalette.cream, in: Capsule()) }
                    .buttonStyle(.plain).keyboardShortcut(.defaultAction).accessibilityIdentifier("update.after.ok")
            }
        }
    }

    private func bullets(_ items: [[String: Any]]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(noteText(item, language)).font(.manrope(14)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }
}

/// 「消息」面板：公告（最新在前）+ 更新说明。打开即看过最新那条公告（model.openMessages）
struct MessagesPanel: View {
    @ObservedObject var model: S2ArmLauncherModel
    let language: String

    private func t(_ id: String) -> String { BackendText.launcherText(id, language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t("messages.title")).font(.manrope(16, .bold)).padding(.horizontal, 4).padding(.bottom, 6)
            if model.messages.isEmpty {
                Text(t("messages.empty")).font(.manrope(13)).foregroundStyle(.secondary).padding(4)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.messages.enumerated()), id: \.offset) { _, message in row(message) }
                }
            }
            .frame(maxHeight: 420)
        }
        .padding(18).frame(width: 440)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("messages.panel")
    }

    @ViewBuilder private func row(_ m: [String: Any]) -> some View {
        let unread = m["unread"] as? Bool == true
        VStack(alignment: .leading, spacing: 6) {
            if m["kind"] as? String == "update" {
                let version = m["version"] as? String ?? ""
                Text(t("messages.kind.update").replacingOccurrences(of: "{0}", with: version) + " · " + t(m["installed"] as? Bool == true ? "messages.installed" : "messages.available"))
                    .font(.manrope(12)).foregroundStyle(.secondary)
                let notes = m["notes"] as? [String: Any] ?? [:]
                let items = (notes["highlights"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (notes["sections"] as? [[String: Any]] ?? []).flatMap { $0["items"] as? [[String: Any]] ?? [] }
                ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, item in
                    Text("• " + noteText(item, language)).font(.manrope(13.5)).fixedSize(horizontal: false, vertical: true)
                }
                if let link = releasePage(version) {
                    Button { NSWorkspace.shared.open(link) } label: { Text(t("update.popup.fullLog")).font(.manrope(12.5)).underline() }
                        .buttonStyle(.plain).foregroundStyle(LauncherPalette.cream)
                }
            } else {
                HStack(spacing: 8) {
                    if unread { Circle().fill(LauncherPalette.danger).frame(width: 7, height: 7) }
                    Text(t(m["level"] as? String == "important" ? "messages.kind.important" : "messages.kind.notice")).font(.manrope(12)).foregroundStyle(.secondary)
                }
                Text((m["text"] as? [String: String])?[language] ?? "").font(.manrope(13.5)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let link = (m["url"] as? String).flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.open(link) } label: { Text(t("notice.details")).font(.manrope(12.5)).underline() }
                        .buttonStyle(.plain).foregroundStyle(LauncherPalette.cream)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(unread ? 0.07 : 0.0), in: RoundedRectangle(cornerRadius: 12))
    }
}
