// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import S2ArmAppleAdapter

/// 导出确认页（0.6.4 维护者：游戏详情区只有「更新」「导出」两件事）：① 怎么签名 ② 出法 ③ 导到哪（设备多选，默认都不勾 = 导出到文件夹并打开）→ 开始。
///   作业沿用现有：layoutSet 记这款的出法 →（没做好 iPhone 版先出 iPhone 包）→ 勾了设备逐台排队 install（gameId, device, sign）、每台一行结果；
///   没勾 → install mode = export + sign，现有「导出好了」页并打开访达
struct ExportSheetRequest: Identifiable, Equatable {
    let gameID: String
    /// 打开时预勾的那一台：只有续签（免费签名到期）从原来「推到 iPhone」改过来时给——续签就是把这款重新签给原来那台，玩家不用再找；其余入口一律不预勾
    var preselect: String? = nil
    /// 直接看这款这次导出的结果（顶栏胶囊点进来）；false = 确认页
    var results = false
    var id: String { gameID }
}

/// 开始那一刻定下的这次导出：sign = appleId / devCert / none（nil = 按设置里的，控制口 / 总控台的导出）；devices 空 = 导出到文件夹
struct ExportPlan: Equatable {
    struct Device: Equatable { let key: String; var kind: String? = nil; var name = "" }
    var sign: String?
    var devices: [Device]
    /// 出法（导出确认页 ② 选的）；nil = 按这款现在的设置（控制口 / 总控台的导出）
    var layout: String? = nil
}

/// 导出确认页上的一台设备（phoneOverview 的一台 + 这款在它上面的状态 + 这次能不能勾）
struct ExportDeviceRow: Equatable, Identifiable {
    enum GameState: Equatable { case latest, old, none, present, unknown, pending, removed }
    /// 行内说明；link = 说明旁边给的入口（去首位 S2Arm 卡装 / 更新、去看怎么导入证书）
    enum Note: Equatable { case offline, needCert, launcherSigned, noShell, shellOld, standaloneSelfSign, deviceAccess(String) }
    let device: String
    let kind: String?
    let name: String
    let game: GameState
    let selectable: Bool
    let note: Note?
    var id: String { device }
    /// 说明旁边给不给入口（打开首位 S2Arm 卡、切到这台装 / 更新 S2Arm）。没导入证书不给：那一步在手机上做，说明句里写全了
    var hasLink: Bool { selectable && [.noShell, .shellOld].contains(note) }
}

/// 这款这次导出的进度（导出确认页「开始」之后那一页）：rows 空 = 导出到文件夹（看手机槽那一单），否则逐台一行
struct ExportFlow: Equatable {
    enum State: Equatable { case queued, running, done, failed, cancelled }
    struct Row: Equatable, Identifiable {
        let device: String
        let kind: String?
        let name: String
        var state: State = .queued
        var message = ""
        var suggestion = ""
        var code: String?
        /// 失败页点过「仍然继续」后重试带上的确认参数（同装机：container_would_drop → acceptDropped …）
        var accept: Set<String> = []
        /// 装好后在手机上还要做的几步（作业结果当场读：独立 App 的 nextSteps，或「打开 S2Arm 会自动装完」/ 信任开发者 / 免费 7 天）
        var next: [ExportFlow.Step] = []
        var id: String { device }
    }
    /// 一句手机上的下一步：作业层原句（界面经 loc.backend 翻）或共享文案键 + 参数
    /// key(文案键, {0}, {1})：{1} 只有指代这一台的句子用（设备类型，#1962），不用的留空
    enum Step: Equatable { case backend(String), key(String, String, String = "") }
    let gameID: String
    let sign: String?
    var rows: [Row]
    /// 开始的时刻：出包完成页据此认出「这一单是那次出包接着做的」
    var started = Date()
    /// 这次的出法（shell / standalone）：成功页按它给独立 App 的存档说明
    var layout = "shell"
    var folder: Bool { rows.isEmpty }
    var running: Bool { rows.contains { $0.state == .running || $0.state == .queued } }
}

extension S2ArmLauncherModel {
    /// 打开导出确认页；设备列表、签名方式、证书、Apple ID 每次打开现查一次
    func openExportSheet(_ gameID: String, preselect: String? = nil, results: Bool = false) {
        exportSheet = ExportSheetRequest(gameID: gameID, preselect: preselect.flatMap { $0.isEmpty ? nil : $0 }, results: results)
    }

    func loadExportPhones() {
        exportPhones = nil
        Task {
            // 读不到不弹框：列表空着照样能导出到文件夹；原因记日志
            do { exportPhones = try await provider.phoneOverview(probe: true)?.phones ?? [] }
            catch { exportPhones = []; NSLog("S2Arm export phones: %@", String(describing: error)) }
        }
    }

    /// ① 签名的缺省：设置里当前的签名方式（installMode signChoice：appleId / devCert / external → none）；选了证书却没导入过 → Apple ID
    func defaultExportSign() -> String {
        switch installMode.signChoice {
        case "external": return "none"
        case "devCert": return devCert?.imported == true ? "devCert" : "appleId"
        default: return "appleId"
        }
    }

    /// ③ 一台设备这次能不能勾、行内写什么（作业层契约：自签时只有别的工具装的 S2Arm 能用；已签名都能勾，没装 / 不是本版 S2Arm 那台开始后单独失败、不挡别的）
    nonisolated static func exportDeviceRow(_ p: PhoneOverview.Phone, gameId: String, sign: String, layout: String) -> ExportDeviceRow {
        let found = p.games.first { $0.gameId == gameId.uppercased() }
        let state = found?.state
        let game: ExportDeviceRow.GameState
        switch state {
        case .latest: game = .latest
        case .suggested: game = .old
        case .present: game = .present
        case .unknown: game = .unknown
        case .pending: game = .pending
        case .notPushed: game = found?.reasons.contains("removed") == true ? .removed : .none
        default: game = .none
        }
        func row(_ ok: Bool, _ note: ExportDeviceRow.Note?) -> ExportDeviceRow {
            ExportDeviceRow(device: p.device, kind: p.kind, name: p.name, game: game, selectable: ok, note: note)
        }
        guard (p.online ?? nil) != nil else { return row(false, .offline) }   // 没连着（或没现查到）：置灰，不替玩家换成别的那台
        if layout != "standalone", let error = p.liveContainerProbeError, !p.installed || p.bundleId.hasPrefix("lc:") {
            return row(false, .deviceAccess(error))
        }
        let external = p.installedBy == .external || (p.needsChoice && p.candidates.contains { !$0.byThisLauncher })
        if sign == "none" {
            if layout == "standalone" { return row(false, .standaloneSelfSign) }   // 独立 App 推到设备要在电脑上签（install.put_app），自签只能导出到文件夹
            if external { return row(true, p.bundleId.hasPrefix("lc:") || p.signCertImported == true ? nil : .needCert) }
            return row(false, p.installed ? .launcherSigned : .noShell)
        }
        if layout == "standalone" || external { return row(true, nil) }   // 独立 App 不需要 S2Arm；别的工具装的 S2Arm 作业层自动走不签那条路
        if !p.installed { return row(true, .noShell) }
        if p.installedBy == .launcher, !p.shellCurrent { return row(true, .shellOld) }
        return row(true, nil)
    }

    /// 导出确认页「开始」：先记这款的出法（layoutSet，同出包 / 装机读的那一份），再按计划导出
    func startExportSheet(_ game: GameSummary, sign: String, layout: String, devices: [ExportPlan.Device]) {
        let plan = ExportPlan(sign: sign, devices: devices, layout: layout)
        Task {
            do { layoutNotice = try await provider.layoutSet(layout, gameId: game.id) } catch { reportFailure("s2arm.fail.layoutSet", error) }
            refreshInstallMode()
            runExportPlan(game, plan)
        }
    }

    /// 按计划导出：没做好 iPhone 版（或旧格式、不能直接导出）先出 iPhone 包，出完接着走（exportAfterPack → installNextQueued）；
    ///   勾了设备逐台排队导入；没勾导出到文件夹（作业做完打开访达，install 里）
    func runExportPlan(_ game: GameSummary, _ plan: ExportPlan) {
        let id = game.id
        guard game.iphoneExportable else {
            exportAfterPack[id] = plan
            // 出不了（缺文件 / 缺密钥…）：去出包页看原因，不悄悄没反应
            if export(game, platforms: [.ios], mode: plan.devices.isEmpty ? "export" : nil)?.stopsStart == true { exportAfterPack[id] = nil; exportFor = id }
            return
        }
        exportFlows[id] = ExportFlow(gameID: id, sign: plan.sign, rows: plan.devices.map { ExportFlow.Row(device: $0.key, kind: $0.kind, name: $0.name) },
                                     layout: plan.layout ?? installMode.layout(for: id))
        if plan.devices.isEmpty { install(game, export: true, sign: plan.sign); return }
        pumpExportFlow(id)
    }

    /// 起下一台：一次只推一台（手机槽一次一单），前一台结束（done 回调）再起下一台
    func pumpExportFlow(_ id: String) {
        guard var flow = exportFlows[id], !flow.rows.contains(where: { $0.state == .running }),
              let i = flow.rows.firstIndex(where: { $0.state == .queued }), let game = games.first(where: { $0.id == id }) else { return }
        flow.rows[i].state = .running; flow.rows[i].message = ""; flow.rows[i].suggestion = ""; flow.rows[i].code = nil
        exportFlows[id] = flow
        let row = flow.rows[i]
        // 不带 mode（玩家亲手勾的设备，首次安装就是推给没装过的那台，不限只推装过的）；那台没连着作业层报 device_not_connected，不换装到别的设备
        install(game, device: row.device, accept: row.accept, ask: false, sign: flow.sign) { [weak self] error in self?.exportRowEnded(id, device: row.device, error) }
    }

    func exportRowEnded(_ id: String, device: String, _ error: Error?) {
        guard var flow = exportFlows[id], let i = flow.rows.firstIndex(where: { $0.device == device }) else { return }
        if let error {
            if error is CancellationError || (error as? JobFailure)?.state == .cancelled {   // 玩家停了：这台和后面排着的都算取消，不接着推
                for j in flow.rows.indices where j == i || flow.rows[j].state == .queued { flow.rows[j].state = .cancelled }
            } else {
                let f = error as? JobFailure
                flow.rows[i].state = .failed
                flow.rows[i].message = f?.errorDescription ?? error.localizedDescription
                flow.rows[i].suggestion = f?.outcome.failureDiagnostic?["suggestion"] as? String ?? ""
                flow.rows[i].code = f?.code
            }
        } else {
            flow.rows[i].state = .done
            flow.rows[i].next = phoneNextSteps(sign: flow.sign, gameID: id)
        }
        exportFlows[id] = flow
        pumpExportFlow(id)
    }

    /// 这一台刚装好后，玩家在手机上还要做什么（install 作业结果在 done 回调前已写进 phoneOutcome / installOpenToFinish / installTrustName）
    func phoneNextSteps(sign: String?, gameID: String) -> [ExportFlow.Step] {
        var n: [ExportFlow.Step] = []
        // 打开哪个 App：独立 App = 主屏上这款自己的图标；通用 S2Arm = 打开 S2Arm（只传到了手机的，打开后自动装完）。
        //   不用独立 App 结果里的 nextSteps：那是导出 / README 用的整段说明（讲怎么装 ipa），装好以后读着会让人以为还要再装一遍
        if let app = phoneOutcome?.app, !app.exported { n.append(.key("exportsheet.phone.openApp", app.name)) }
        else if installOpenToFinish { n.append(.key("install.done.open", "")) }
        else { n.append(.key("exportsheet.phone.openShell", "")) }
        if !installTrustName.isEmpty { n.append(.key("install.done.trustNamed", installTrustName, BackendText.deviceKind(installTrustKind))) }
        else if sign == "appleId" { n.append(.key("install.done.trust", "")) }
        if sign == "appleId", games.first(where: { $0.id == gameID })?.iphoneFree == true { n.append(.key("install.done.free", "")) }
        return n
    }

    /// 导出页这一行要不要就地列「选用哪个 S2Arm」的候选（#1966）：这一行停在 phone_app_choice_required、且记下的候选就是这台。
    ///   选好后 chooseApp 调 install 失败时记下的重推，完成回调仍是这一行的 exportRowEnded，结果照常落回这一行
    func exportRowChoice(_ row: ExportFlow.Row) -> PushChoice? {
        guard row.state == .failed, row.code == PhoneOverview.choiceRequiredCode, let c = pushChoice, c.device == row.device else { return nil }
        return c
    }

    /// 失败的那台单独重试（不重做已成功的、不重做电脑上那一步）；失败码是可确认的（会挤掉别处装的游戏…）就带上确认参数 =「仍然继续」
    func retryExportRow(_ id: String, device: String) {
        guard var flow = exportFlows[id], let i = flow.rows.firstIndex(where: { $0.device == device }), [.failed, .cancelled].contains(flow.rows[i].state) else { return }
        if let code = flow.rows[i].code, let key = Self.confirmCodes[code] { flow.rows[i].accept.insert(key) }
        flow.rows[i].state = .queued
        exportFlows[id] = flow
        pumpExportFlow(id)
    }
}
