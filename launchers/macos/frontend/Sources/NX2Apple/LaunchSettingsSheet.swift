// S2Arm（不是上游文件）：一款游戏的启动设置（「开始游戏」旁的齿轮、「更多」菜单里同一入口；11-09 维护者）。
//   设置项只从共享定义表 launchers/shared/game_settings.v1.json 读（iOS 游戏内菜单同一份），这里不另写文案和缺省；
//   读写走作业层 community / communitySave（存这款游戏文件夹的 launch.json），改完下次开始游戏生效，不用重新准备。
//   可用与否按这款的能力清单，不可用时显示原因。「手柄与按键」打开现有的按键设置页。
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

/// 一项的状态（作业层 community 结果的 mac 字段）：值是 Bool（开关）或 String（选项）。
struct LaunchOption {
    let available: Bool
    let value: Any?
    let reason: String
    /// 这款没有对应的社区补丁（11-13 起只用补丁，60 帧 / 满屏没补丁就是原生游戏）：这一行不出
    let hidden: Bool
    /// 游戏语言（11-14）：这款 control.nacp 支持的选项值（含「跟随系统」）；没有 = 不知道，列定义表全部
    let choices: [String]?
    /// 游戏语言：选的 / 系统语言这款不支持时，作业层写明起局实际用哪种（中英两份，不弹窗）
    let note: [String: String]

    init(_ raw: Any?) {
        let row = raw as? [String: Any] ?? [:]
        available = row["available"] as? Bool ?? false
        hidden = row["hidden"] as? Bool ?? false
        value = row["value"]
        reason = row["reason"] as? String ?? ""
        choices = row["choices"] as? [String]
        note = row["note"] as? [String: String] ?? [:]
    }
}

/// 画面补丁一项（community 结果的 graphics；玩家包一般没有）。
struct LaunchPatch: Identifiable {
    let id: String
    let label: String
    let enabled: Bool
    /// 上一局的实际结果（pack/jobs/community.py patch_result：没生效的原因 / 量到的效果；没有为空）
    var result = ""
}

/// 金手指一条（community 结果的 cheats.items；pack/jobs/cheats.py listing）：来源 library / player，版本不对时 ok 为假并带原因。
struct LaunchCheat: Identifiable {
    let id: String
    let name: String
    let enabled: Bool
    let ok: Bool
    let reason: String
    let fromLibrary: Bool
    let repo: String
    let author: String
    let license: String
    let status: String
    let fixed: Bool   // 写死地址（pack/jobs/cheats.py fixed_address）：标「地址写死，可能不生效」

    init?(_ raw: [String: Any]) {
        guard let key = raw["key"] as? String else { return nil }
        id = key; name = raw["name"] as? String ?? key; enabled = raw["enabled"] as? Bool ?? false; ok = raw["ok"] as? Bool ?? false
        reason = raw["reason"] as? String ?? ""; fromLibrary = raw["from"] as? String == "library"; repo = raw["repo"] as? String ?? ""
        author = raw["author"] as? String ?? ""; license = raw["license"] as? String ?? ""; status = raw["status"] as? String ?? ""
        fixed = raw["fixed"] as? Bool ?? false
    }
}

extension S2ArmLauncherModel {
    /// 读（change 为空）或改这款的启动设置；change 的键是定义表 id，值 Bool / String，NSNull = 回缺省。
    func launchSettings(_ gameID: String, change: [String: Any]? = nil, patches: [String: Bool]? = nil) async throws -> ([String: LaunchOption], [LaunchPatch]) {
        let all = try await launchSettingsAll(gameID, change: change, patches: patches)
        return (all.0, all.1)
    }

    /// 同上，另带金手指：cheats 改开关（键「文件名/条目名」），cheatsImport 导入 txt（作业层 communitySave，pack/jobs/cheats.py）
    func launchSettingsAll(_ gameID: String, change: [String: Any]? = nil, patches: [String: Bool]? = nil,
                           cheats: [String: Bool]? = nil, cheatsImport: [String]? = nil) async throws -> ([String: LaunchOption], [LaunchPatch], [LaunchCheat], String) {
        var extra: [String: Any] = [:]
        if let change { extra["settings"] = change }
        if let patches { extra["graphics"] = patches }
        if let cheats { extra["cheats"] = cheats }
        if let cheatsImport { extra["cheatsImport"] = cheatsImport }
        let result = try await saveJob(extra.isEmpty ? "community" : "communitySave", gameID: gameID, extra: extra)
        let mac = (result["mac"] as? [String: Any] ?? [:]).mapValues(LaunchOption.init)
        let gfx = (result["graphics"] as? [[String: Any]] ?? []).compactMap { g -> LaunchPatch? in
            guard let id = g["id"] as? String else { return nil }
            return LaunchPatch(id: id, label: g["label"] as? String ?? id, enabled: g["enabled"] as? Bool ?? false, result: g["result"] as? String ?? "")
        }
        let ch = result["cheats"] as? [String: Any] ?? [:]
        return (mac, gfx, (ch["items"] as? [[String: Any]] ?? []).compactMap(LaunchCheat.init), ch["reason"] as? String ?? "")
    }
}

struct LaunchSettingsSheet: View {
    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: S2ArmLauncherModel
    let gameID: String
    /// 「手柄与按键」：关掉本页、打开按键设置页
    var openInput: () -> Void = {}
    @State private var items: [GameSettingItem] = []
    @State private var options: [String: LaunchOption] = [:]
    @State private var patches: [LaunchPatch] = []
    @State private var cheats: [LaunchCheat] = []
    @State private var cheatsReason = ""
    @State private var failure: String?
    @State private var saving = false
    @State private var loaded = false

    private var lang: String { loc.lang == .zh ? "zh-Hans" : "en" }
    private func t(_ id: String) -> String { BackendText.launcherText(id, language: lang) }
    private var gameName: String { model.games.first { $0.id == gameID }?.name ?? gameID }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("display.title")).font(.manrope(26, .heavy)).tracking(-0.6)
                Text(gameName).font(.manrope(14)).foregroundStyle(.secondary).lineLimit(1)
                Text(t("display.hint")).font(.manrope(12.5)).foregroundStyle(.secondary).padding(.top, 6)
            }
            if let failure {
                Label { Text(loc.backend(failure)).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.circle.fill") }
                    .font(.manrope(12.5)).foregroundStyle(LauncherPalette.danger)
            }
            if !loaded && failure == nil {
                ProgressView().controlSize(.small)
            } else if loaded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // 分组顺序：画面 → S 级优化（社区补丁 + 金手指，金色卡）→ 手柄 → 其他（定义表 launchers/shared/game_settings.v1.json 的 group）
                        ForEach(["display", "sgrade", "controls", "other"], id: \.self) { group in
                            let rows = items.filter { $0.group == group && visible($0) }
                            if !rows.isEmpty {
                                if group == "sgrade" {
                                    SGradeGroupCard(t("display.group.sgrade"), note: t("export.sgrade.hit.note")) { sgradeRows(rows) }
                                } else {
                                    CardGroup(t("display.group." + group)) { groupRows(rows) }
                                }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(t("display.done")) { dismiss() }.buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(30)
        .frame(width: 600, height: 640)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
        .task { if !loaded { await load(nil) } }
    }

    /// S 级优化组：社区补丁 / 金手指两个小节（SGradeSettingsRows：小标题与各行文字同一条起始线、开关靠右）
    @ViewBuilder private func sgradeRows(_ rows: [GameSettingItem]) -> some View {
        let p = rows.first { $0.type == "patches" }, c = rows.first { $0.type == "cheats" }
        SGradeSettingsRows(
            patchesTitle: p?.text(lang) ?? "", patchesNote: p?.detail(lang) ?? "",
            patches: p == nil ? [] : patches.map { SGradeToggle(id: $0.id, label: $0.label, detail: $0.result.isEmpty ? "" : loc.backend($0.result), on: $0.enabled) },
            cheatsTitle: c?.text(lang) ?? "", cheatsNote: cheats.isEmpty && !cheatsReason.isEmpty ? loc.backend(cheatsReason) : (c?.detail(lang) ?? ""),
            cheats: c == nil ? [] : cheats.map { SGradeToggle(id: $0.id, label: $0.name, detail: cheatDetail($0), on: $0.enabled, enabled: $0.ok) },
            importTitle: t("display.cheats.import"), busy: saving || model.busy,
            onPatch: { id, on in Task { await load(nil, patches: [id: on]) } },
            onCheat: { id, on in Task { await load(nil, cheats: [id: on]) } },
            onImport: { importCheats() },
            summary: { on, all in t("display.cheats.summary").replacingOccurrences(of: "{0}", with: String(on)).replacingOccurrences(of: "{1}", with: String(all)) },
            searchPrompt: t("display.cheats.search"))
    }

    @ViewBuilder private func groupRows(_ rows: [GameSettingItem]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
            if i > 0 { CardDivider() }
            row(item)
        }
    }

    /// 补丁一栏只在这款列得出补丁时出现；开关 / 选项要作业层给了状态才画
    private func visible(_ item: GameSettingItem) -> Bool {
        switch item.type {
        case "patches": return !patches.isEmpty
        case "page", "cheats": return true
        default: return options[item.id].map { !$0.hidden } ?? false
        }
    }

    @ViewBuilder private func row(_ item: GameSettingItem) -> some View {
        let title = item.text(lang)
        switch item.type {
        case "page":
            CardRow(title, detail: item.detail(lang)) {
                Button(t("display.open")) { dismiss(); openInput() }.buttonStyle(LauncherSecondaryButtonStyle())
                    .accessibilityIdentifier("launch." + item.id)
            }
        case "patches":
            CardRow(title, detail: item.detail(lang)) { EmptyView() }
            ForEach(patches) { p in
                CardRow("  " + p.label, detail: p.result.isEmpty ? "" : loc.backend(p.result)) {
                    Toggle("", isOn: Binding(get: { p.enabled }, set: { on in Task { await load(nil, patches: [p.id: on]) } }))
                        .toggleStyle(LauncherSwitchStyle()).labelsHidden().accessibilityLabel(p.label).disabled(saving || model.busy)
                }
            }
        case "cheats":
            CardRow(title, detail: cheats.isEmpty && !cheatsReason.isEmpty ? loc.backend(cheatsReason) : item.detail(lang)) {
                Button(t("display.cheats.import")) { importCheats() }.buttonStyle(LauncherSecondaryButtonStyle())
                    .accessibilityIdentifier("launch.cheats.import").disabled(saving || model.busy)
            }
            ForEach(cheats) { ch in
                CardRow("  " + ch.name, detail: cheatDetail(ch)) {
                    Toggle("", isOn: Binding(get: { ch.enabled }, set: { on in Task { await load(nil, cheats: [ch.id: on]) } }))
                        .toggleStyle(LauncherSwitchStyle()).labelsHidden().accessibilityLabel(ch.name)
                        .accessibilityIdentifier("launch.cheat." + ch.id)
                        .disabled(!ch.ok || saving || model.busy)
                }
            }
        case "choice":
            let option = options[item.id]
            CardRow(title, detail: option?.available == false ? loc.backend(option?.reason ?? "") : option?.note[lang] ?? item.detail(lang)) {
                Picker("", selection: Binding(get: { option?.value as? String ?? "" }, set: { v in Task { await load([item.id: v]) } })) {
                    // 游戏语言只列这款支持的（作业层 choices）；当前值不在里面（旧版选过、这款没有）也留着，不让选择框空掉
                    ForEach(item.options.filter { o in option?.choices.map { $0.contains(o.value) || o.value == option?.value as? String } ?? true }, id: \.value) { o in
                        Text(o.label[lang] ?? o.value).tag(o.value) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 150).accessibilityLabel(title)
                .accessibilityIdentifier("launch." + item.id)
                .disabled(option?.available != true || saving || model.busy)
            }
        default:
            let option = options[item.id]
            CardRow(title, detail: option?.available == false ? loc.backend(option?.reason ?? "") : item.detail(lang)) {
                Toggle("", isOn: Binding(get: { option?.value as? Bool ?? false }, set: { on in Task { await load([item.id: on]) } }))
                    .toggleStyle(LauncherSwitchStyle()).labelsHidden().accessibilityLabel(title)
                    .accessibilityIdentifier("launch." + item.id)
                    .disabled(option?.available != true || saving || model.busy)
            }
        }
    }

    /// 每条写清来源与作者（维护者 11-12：每条在游戏内和启动器里写清作者和来源库）；版本不对写原因；运行中写 Cheats.cs 的状态
    private func cheatDetail(_ ch: LaunchCheat) -> String {
        if !ch.ok { return loc.backend(ch.reason) }
        var parts = [ch.fromLibrary ? t("display.cheats.library").replacingOccurrences(of: "{0}", with: ch.repo + (ch.license.isEmpty ? "" : "（\(ch.license)）"))
                                    : t("display.cheats.player")]
        if !ch.author.isEmpty { parts.append(t("display.cheats.author").replacingOccurrences(of: "{0}", with: ch.author)) }
        if !ch.status.isEmpty { parts.append(ch.status) }
        if ch.fixed { parts.append(t("display.cheats.fixedAddress")) }
        return parts.joined(separator: " · ")
    }

    private func importCheats() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let paths = panel.urls.map(\.path)
        Task { await load(nil, cheatsImport: paths) }
    }

    private func load(_ change: [String: Any]?, patches change2: [String: Bool]? = nil, cheats change3: [String: Bool]? = nil, cheatsImport: [String]? = nil) async {
        saving = true; defer { saving = false }
        do {
            if items.isEmpty { items = try GameSettingsSpec.macItems() }
            (options, patches, cheats, cheatsReason) = try await model.launchSettingsAll(gameID, change: change, patches: change2, cheats: change3, cheatsImport: cheatsImport)
            failure = nil; loaded = true
        } catch {
            failure = (error as? JobClientError)?.message ?? error.localizedDescription
        }
    }
}

/// 开局前的崩溃提示（维护者 11-12：「崩了再恢复」）：上次开着 X、Y 时游戏退出了，要先关掉它们吗？「关掉 / 继续开着」，不替玩家自动关
struct CrashPrompt: Identifiable {
    let id = UUID()
    let game: GameSummary
    let uiLanguage: String?
    let names: [String]
}

struct CrashPromptHost: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    private func t(_ id: String) -> String { BackendText.launcherText(id, language: loc.lang == .zh ? "zh-Hans" : "en") }
    var body: some View {
        let p = model.crashPrompt
        Color.clear.frame(width: 0, height: 0)
            .alert(t("crash.cheats.title"),
                   isPresented: Binding(get: { model.crashPrompt != nil }, set: { if !$0, model.crashPrompt?.id == p?.id { model.crashPrompt = nil } })) {
                Button(t("crash.cheats.ok"), role: .cancel) { model.crashPrompt = nil }
            } message: {
                Text(t("crash.cheats.body").replacingOccurrences(of: "{0}", with: (p?.names ?? []).joined(separator: loc.lang == .zh ? "、" : ", ")))
            }
    }
}
