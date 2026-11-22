// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// S2Arm（不是上游文件）：导出确认页（0.6.4 维护者：游戏详情区 iPhone 这一侧只有「更新」「导出」两件事）。
//   ① 怎么签名（Apple ID / 我的证书〔导入过才可选〕/ 自签）② 出法（通用 S2Arm / 独立 App）③ 导到哪（设备多选，默认都不勾 = 导出到文件夹并打开）→［取消］［开始］。
//   开始之后同一页换成结果：勾了设备每台一行（失败的那台单独重试）；没勾就是现有「导出好了」那张卡。作业与参数见 S2ArmLauncherModel+ExportSheet
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct ExportSheetView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    let request: ExportSheetRequest
    /// 出现时现查设备、签名方式、证书、Apple ID；离屏截图测试关掉（测试环境没有作业入口）
    var refreshOnAppear = true
    @State private var sign: String
    @State private var layout: String
    @State private var picked: Set<String>
    @State private var seeded: Bool
    @State private var started = false
    @State private var importCert = false

    init(model: S2ArmLauncherModel, request: ExportSheetRequest, refreshOnAppear: Bool = true, sign: String? = nil, layout: String? = nil, picked: Set<String>? = nil) {
        self.model = model; self.request = request; self.refreshOnAppear = refreshOnAppear
        _sign = State(initialValue: sign ?? "appleId")
        _layout = State(initialValue: layout ?? "shell")
        _picked = State(initialValue: picked ?? Set([request.preselect].compactMap { $0 }))
        _seeded = State(initialValue: sign != nil)
    }

    private var id: String { request.gameID }
    private var game: GameSummary? { model.games.first { $0.id == id } }
    private var flow: ExportFlow? { model.exportFlows[id] }
    private var showsResults: Bool {
        started || request.results || flow?.running == true || (flow?.folder == true && model.phoneBusy && model.phoneSession?.gameID == id)
            || model.exportAfterPack[id] != nil   // 先出 iPhone 版、出完接着做：这一单已开始，看结果（还没轮到写「已排队」）
    }
    private func t(_ key: String) -> String { BackendText.launcherText(key, language: loc.lang.sharedCode) }

    /// 设备的称呼：类型照实写（iPhone / iPad；读不到写「设备」）+ 名字
    static func deviceLabel(kind: String?, name: String, language: String) -> String {
        let k = kind.flatMap { $0.isEmpty ? nil : $0 } ?? BackendText.launcherText("exportsheet.device.generic", language: language)
        return S2ArmLauncherModel.named(k, name, language: language)
    }

    /// 失败那一行的「去首位 S2Arm 卡」按钮按失败码分：没装 →「先装 S2Arm」，不是本版 →「先更新 S2Arm」；别的码不给
    static func shellLinkKey(_ code: String?) -> String? {
        switch code {
        case "shell_install_required": return "exportsheet.link.installShell"
        case "shell_update_required": return "exportsheet.link.updateShell"
        default: return nil
        }
    }

    /// 这次能勾的设备行（顺序同作业给的）
    var rows: [ExportDeviceRow] {
        (model.exportPhones ?? []).map { S2ArmLauncherModel.exportDeviceRow($0, gameId: id, sign: sign, layout: layout) }
    }
    /// 真正会导入的那几台：勾了、而且按现在的签名 / 出法还能勾（换了签名后不能勾的自动不算）
    var chosen: [ExportDeviceRow] { rows.filter { $0.selectable && picked.contains($0.device) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LauncherSheetHeading(t("exportsheet.title").replacingOccurrences(of: "{0}", with: game?.name ?? ""))
                .padding(.horizontal, LauncherTheme.Space.page).padding(.top, LauncherTheme.Space.page).padding(.bottom, 16)
            ScrollView {
                Group { if showsResults { results } else { form } }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LauncherTheme.Space.page).padding(.bottom, LauncherTheme.Space.section)
            }
            Divider().opacity(0.3)
            footer.padding(.horizontal, LauncherTheme.Space.page).padding(.vertical, LauncherTheme.Space.large)
        }
        .onAppear {
            if model.phoneResult?.gameID == id { model.phoneResult = nil }   // 回来看过结果，顶部胶囊收起
            guard refreshOnAppear else { return }
            model.loadExportPhones(); model.refreshInstallMode(); model.refreshDevCert(); model.refreshAppleAccount()
            seed()
        }
        .onChange(of: model.installMode) { _ in seed() }
        .onExitCommand { dismiss() }
        .appleLoginSheet(model, host: "exportSheet")   // ① 选了 Apple ID 还没登录：就地登录，不离开这页
        .sheet(isPresented: $importCert) { DevCertSheet(model: model).environmentObject(loc) }   // ① 选我的证书还没导入：就地导入
        .onChange(of: importCert) { open in if !open { model.refreshDevCert() } }
        .launcherSheet()
        .font(LauncherTheme.TypeStyle.detail)
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
    }

    /// 缺省：签名 = 设置里当前的；出法 = 这款现在按哪种推。玩家动过就不再改
    private func seed() {
        guard !seeded else { return }
        sign = model.defaultExportSign()
        layout = model.installMode.layout(for: id)
        if model.installMode.loaded { seeded = true }
    }

    // ---- 确认页 ----

    private var form: some View {
        VStack(alignment: .leading, spacing: 22) {
            section(t("exportsheet.sign.title")) {
                let account = model.appleAccount?.account ?? ""
                radio("appleId", account.isEmpty ? t("exportsheet.sign.appleId") : t("exportsheet.sign.appleIdAccount").replacingOccurrences(of: "{0}", with: account))
                if sign == "appleId", account.isEmpty {   // 没登录：装到设备会失败（apple_not_signed_in）。就地给登录，不等开始后才报
                    HStack(spacing: 10) {
                        Text(t("exportsheet.sign.notSignedIn")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Button(t("exportsheet.sign.login")) { model.openAppleLogin(host: "exportSheet") }.controllerButtonStyle(.link).font(LauncherTheme.TypeStyle.caption)
                            .controllerID("exportsheet.sign.login")
                    }.padding(.leading, 25)
                }
                HStack(spacing: 10) {
                    radio("devCert", t("exportsheet.sign.devCert"), note: model.devCert?.imported == true ? nil : t("exportsheet.sign.devCertMissing"),
                          enabled: model.devCert?.imported == true)
                    if model.devCert?.imported != true {   // 买了证书还没导入：就地导入，导好这一项就能选
                        Button(t("exportsheet.sign.importCert")) { importCert = true }.controllerButtonStyle(.link).font(LauncherTheme.TypeStyle.caption)
                            .controllerID("exportsheet.sign.importCert")
                    }
                }
                radio("none", t("exportsheet.sign.none"))
            }
            section(t("exportsheet.layout.title")) {
                InstallLayoutRow(model: model, gameId: id, refreshOnAppear: false, selection: $layout, exportSign: sign)
            }
            section(t("exportsheet.devices.title")) {
                if model.exportPhones == nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(t("exportsheet.devices.loading")).foregroundStyle(.secondary) }
                } else if rows.isEmpty {
                    Text(t("exportsheet.devices.none")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) { ForEach(rows) { deviceRow($0) } }
                }
                Text(t("exportsheet.devices.hint")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
            }
            if let game, !game.iphoneExportable {   // 没做好 iPhone 版：开始后先在电脑上做好再导出，按钮不擅自开始
                Label(t("exportsheet.prepare"), systemImage: "hammer")
                    .font(.manrope(13, .medium)).foregroundStyle(LauncherPalette.building).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("exportsheet.prepare")
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.manrope(14, .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func radio(_ value: String, _ title: String, note: String? = nil, enabled: Bool = true) -> some View {
        let on = sign == value
        return LauncherRadioRow(selected: on, action: { sign = value; seeded = true }) {
            Text(title).font(.manrope(14, .semibold))
            if let note { Text(note).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary) }
        }
        .disabled(!enabled)
        .controllerID("exportsheet.sign." + value)
    }

    private func gameStateText(_ s: ExportDeviceRow.GameState) -> String {
        switch s {
        case .latest: return t("exportsheet.game.latest")
        case .old: return t("exportsheet.game.old")
        case .none: return t("exportsheet.game.none")
        case .present: return t("console.game.present")
        case .unknown: return t("console.game.unknown")
        case .pending: return t("console.game.pending")
        case .removed: return t("console.game.removed")
        }
    }

    private func noteText(_ n: ExportDeviceRow.Note) -> String {
        switch n {
        case .offline: return t("exportsheet.note.offline")
        case .needCert: return t("exportsheet.note.needCert")
        case .launcherSigned: return t("exportsheet.note.launcherSigned")
        case .noShell: return t(sign == "none" ? "exportsheet.note.noShellSelfSign" : "exportsheet.note.noShell")
        case .shellOld: return t("exportsheet.note.shellOld")
        case .standaloneSelfSign: return t("exportsheet.note.standaloneSelfSign")
        case .deviceAccess(let error): return loc.backend(error)
        }
    }

    private func linkTitle(_ n: ExportDeviceRow.Note?) -> String {
        n == .shellOld ? t("exportsheet.link.updateShell") : t("exportsheet.link.installShell")
    }

    /// 去首位 S2Arm 卡（总控台）管这台：装 / 更新 S2Arm、别的工具装的 S2Arm 怎么导入证书都在那里
    private func openConsole(_ device: String) {
        model.consoleDevice = device
        dismiss()
        model.openConsoleFromTopBar()
    }

    private func deviceRow(_ row: ExportDeviceRow) -> some View {
        let on = row.selectable && picked.contains(row.device)
        return HStack(alignment: .top, spacing: 10) {
            Button { if on { picked.remove(row.device) } else { picked.insert(row.device) } } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(on ? LauncherPalette.cream : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 10) {
                            Text(Self.deviceLabel(kind: row.kind, name: row.name, language: loc.lang.sharedCode)).font(.manrope(14, .semibold))
                            Text(gameStateText(row.game)).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                        }
                        if let note = row.note {
                            Text(noteText(note)).font(LauncherTheme.TypeStyle.caption)
                                .foregroundStyle(row.selectable ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .controllerButtonStyle(.plain).controllerRingRadius(8).disabled(!row.selectable).opacity(row.selectable ? 1 : 0.5)
            .controllerID("exportsheet.device." + row.device).accessibilityIdentifier("exportsheet.device." + row.device)
            .accessibilityAddTraits(on ? .isSelected : [])
            if row.hasLink {
                Button(linkTitle(row.note)) { openConsole(row.device) }
                    .controllerButtonStyle(.link).font(LauncherTheme.TypeStyle.caption).controllerID("exportsheet.link." + row.device)
            }
        }
        .padding(12)
        .background(Color.white.opacity(on ? 0.07 : 0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? LauncherPalette.cream.opacity(0.7) : Color.white.opacity(0.12)))
    }

    // ---- 开始之后 ----

    /// 这款在手机槽里那一单（导出到文件夹时的进度 / 「导出好了」卡）
    private var phoneJob: JobSession? {
        if let s = model.phoneSession, s.kind == .install, s.gameID == id { return s }
        if let s = model.lastPhoneSession, s.kind == .install, s.gameID == id { return s }
        return nil
    }

    /// 成功页的独立 App 存档说明（export.done.standaloneSaveCarry）：这次出法是独立 App、而且至少一台装好 / 导出到文件夹成了才出；通用 S2Arm 不出
    static func showsSaveCarry(_ flow: ExportFlow?, folderDone: Bool) -> Bool {
        guard let flow, flow.layout == "standalone" else { return false }
        return flow.folder ? folderDone : flow.rows.contains { $0.state == .done }
    }

    @ViewBuilder private var saveCarry: some View {
        if Self.showsSaveCarry(flow, folderDone: phoneJob?.phase == .finished(.completed)) {
            Text(t("export.done.standaloneSaveCarry")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("exportsheet.saveCarry")
        }
    }

    @ViewBuilder private var results: some View {
        if let flow, !flow.folder {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("exportsheet.results.title")).font(.manrope(14, .semibold)).foregroundStyle(.secondary)
                ForEach(flow.rows) { resultRow($0) }
                saveCarry
            }
        } else if let job = phoneJob, flow?.folder == true {
            VStack(alignment: .leading, spacing: 16) {
                PhoneJobPanel(model: model, session: job, showsOperation: false)
                saveCarry
            }
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(t("install.queued")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func resultRow(_ row: ExportFlow.Row) -> some View {
        let label = Self.deviceLabel(kind: row.kind, name: row.name, language: loc.lang.sharedCode)
        let live = model.phoneSession.flatMap { $0.kind == .install && $0.gameID == id ? $0 : nil }
        return HStack(alignment: .top, spacing: 10) {
            Group {
                switch row.state {
                case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(LauncherPalette.ready)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LauncherPalette.danger)
                case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
            }.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.manrope(14, .semibold))
                switch row.state {
                case .queued: Text(t("exportsheet.row.queued")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                case .running:
                    Text(live.map { $0.stage.isEmpty ? t("exportsheet.row.running") : loc.backend($0.stage) } ?? t("exportsheet.row.running"))
                        .font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                case .done:
                    Text(t("exportsheet.row.installed")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(LauncherPalette.ready)
                    if !row.next.isEmpty {   // 装好后手机上还要做的几步（打开 S2Arm / 信任开发者 / 7 天到期）：没这几句玩家会以为点开就能玩
                        Text(t("exportsheet.phone.next")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).padding(.top, 4)
                        ForEach(Array(row.next.enumerated()), id: \.offset) { _, step in
                            Label(stepText(step), systemImage: "iphone").font(LauncherTheme.TypeStyle.caption).foregroundStyle(.primary.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .cancelled: Text(t("exportsheet.row.cancelled")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                case .failed:
                    Text(loc.backend(row.message)).font(LauncherTheme.TypeStyle.caption).foregroundStyle(LauncherPalette.danger).fixedSize(horizontal: false, vertical: true)
                    if let choice = model.exportRowChoice(row) {
                        chooser(choice)   // #1966：就在这一行选用哪个 S2Arm，选好自动接着推这一台（原先只给「重试」，点了必然再失败）
                    } else if !row.suggestion.isEmpty {
                        Text(loc.backend(row.suggestion)).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 8)
            if row.state == .failed || row.state == .cancelled {
                if let key = Self.shellLinkKey(row.code) {   // 这台没装 / 不是本版 S2Arm：去首位 S2Arm 卡装 / 更新，不挡别的设备
                    Button(t(key)) { openConsole(row.device) }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle())
                }
                let confirm = row.code.flatMap { S2ArmLauncherModel.confirmCodes[$0] } != nil
                if model.exportRowChoice(row) == nil {   // 要选用哪个 S2Arm 时不给「重试」：没选之前重试必然再失败
                    Button(t(confirm ? "install.drop_confirm" : "phone.retry")) { model.retryExportRow(id, device: row.device) }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("exportsheet.retry." + row.device)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain).accessibilityIdentifier("exportsheet.row." + row.device)
    }

    /// 导出页这一行停在「装着不止一个 S2Arm、还没选」：就地列候选（同推送失败页 / 总控台：只写事实、不推荐），点一个记住并接着推这一台
    private func chooser(_ choice: S2ArmLauncherModel.PushChoice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t("console.choose.title").replacingOccurrences(of: "{0}", with: model.deviceKind(of: choice.device)))
                .font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(choice.candidates, id: \.bundleId) { c in
                Button { model.chooseApp(device: choice.device, bundleId: c.bundleId) } label: {
                    HStack(spacing: 8) {
                        if model.consoleChoosing == c.bundleId { ProgressView().controlSize(.small) } else { Image(systemName: "app.badge.checkmark") }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(S2ArmLauncherModel.candidateLabelKeys(c).map { t($0) }.joined(separator: " · ")).font(LauncherTheme.TypeStyle.caption)
                            Text(c.bundleId + (c.team.isEmpty ? "" : " · " + t("console.choose.team").replacingOccurrences(of: "{0}", with: c.team)))
                                .font(.manrope(11)).foregroundStyle(.secondary)
                        }
                    }
                }
                .controllerButtonStyle(LauncherSecondaryButtonStyle()).disabled(model.consoleChoosing != nil || model.phoneBusy)
                .accessibilityIdentifier("exportsheet.chooseApp." + c.bundleId)
            }
            if let why = model.consoleChooseError {
                Text(loc.backend(why)).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("exportsheet.chooseApp." + choice.device)
    }

    // ---- 底栏 ----

    @ViewBuilder private var footer: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 8)
            if showsResults {
                if flow?.running == true || (flow?.folder == true && model.phoneBusy && model.phoneSession?.gameID == id) {
                    Button(t("install.background")) { dismiss() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerShortcut(.back)
                    Button(t("exportsheet.stop")) { model.stopPhone() }.controllerButtonStyle(LauncherSecondaryButtonStyle())
                        .disabled(!(model.phoneBusy && model.phoneSession?.gameID == id))
                } else {
                    Button(t("install.close")) { dismiss() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.defaultAction)
                        .controllerShortcut(.rightTrigger, .back)
                }
            } else {
                Button(t("exportsheet.cancel")) { dismiss() }.controllerButtonStyle(LauncherSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction).controllerShortcut(.back).accessibilityIdentifier("exportsheet.cancel")
                Button(startTitle) { start() }
                    .controllerButtonStyle(LauncherPrimaryButtonStyle()).keyboardShortcut(.defaultAction).controllerShortcut(.rightTrigger)
                    .disabled(game == nil).accessibilityIdentifier("exportsheet.start")
            }
        }
    }

    private func stepText(_ s: ExportFlow.Step) -> String {
        switch s {
        case .backend(let line): return loc.backend(line)
        case .key(let key, let arg, let more): return t(key).replacingOccurrences(of: "{0}", with: arg).replacingOccurrences(of: "{1}", with: more)
        }
    }

    /// 开始按钮写清这次去哪：都不勾 =「导出到文件夹」，勾了 =「装到 N 台设备」
    var startTitle: String {
        chosen.isEmpty ? t("exportsheet.start.folder") : t("exportsheet.start.devices").replacingOccurrences(of: "{0}", with: "\(chosen.count)")
    }

    private func start() {
        guard let game else { return }
        let devices = chosen.map { ExportPlan.Device(key: $0.device, kind: $0.kind, name: $0.name) }
        model.startExportSheet(game, sign: sign, layout: layout, devices: devices)
        if game.iphoneExportable { started = true } else { dismiss() }   // 要先出 iPhone 包：主页面显示出包进度，出完自动接着导出 / 导入
    }
}
