// S2Arm（不是上游文件）：签名身份（一键装用 Apple ID / 我的开发者证书，installMode 作业只读）+ 游戏库「导出自签包」+ 更新 iPhone 上的 S2Arm。
//   11-15 维护者：导出不再是一种「装法」，设置里没有切换；「推到 iPhone」「导出自签包」两个按钮并排，导不导出只看这次请求。
//   更新：库页右上角按钮（catalog phoneUpdates：设备记录的壳号比本版旧）→ 有要重新出包的款先三选一 → installUpdate 作业只换壳、不重推资源。
import AppKit
import Foundation
import S2ArmAppleAdapter

extension S2ArmLauncherModel {
    // 失败不吞（剃刀 M13）：读失败保留原值、报一次原因；切换失败报原因（界面停在旧值是真实状态，不再像点了没反应）
    /// silent：App 启动时那一次。读不到（游戏库还没建、首次打开）保留缺省值、不弹框——启动就弹错误框不对，单测里模态框还会把测试挂死；
    ///   打开设置 / 装机页时的读照旧失败如实报
    func refreshInstallMode(silent: Bool = false) {
        Task {
            do { installMode = try await provider.installMode(); readOK("s2arm.fail.installMode") }
            catch { if !silent { reportFailure("s2arm.fail.installMode", error, passive: true) } }
        }
    }

    /// 出法（0.6.3）：layout = shell（通用 S2Arm）/ standalone（独立 App，一 App 一游戏）/ nil（撤掉选择：缺省回到按证书自动，单款回到跟随设置）；
    ///   gameId 给了只管这一款。下次推到 iPhone 时作业层按它分流（install.chosen_layout），这里不装任何东西
    func setLayout(_ layout: String?, gameId: String? = nil) {
        Task {
            do { layoutNotice = try await provider.layoutSet(layout, gameId: gameId) } catch { reportFailure("s2arm.fail.layoutSet", error) }
            refreshInstallMode()
        }
    }

    /// 游戏库「导出自签包」（11-15 维护者：1 下开始导出，不经装机窗）：iPhone 包能直接导出（新格式）的直接导出（不连手机、不签名）；
    ///   没出过、或包是旧格式的先出 iPhone 包、出完接着导出（selfSignAfterPack，出包会话结束后 pumpQueue 接上）——玩家点的是导出，就把导出做完
    func exportSelfSign(_ game: GameSummary) {
        if game.iphoneExportable { install(game, export: true); return }
        selfSignAfterPack.insert(game.id)
        if export(game, platforms: [.ios], mode: "export")?.stopsStart == true { selfSignAfterPack.remove(game.id); exportFor = game.id }   // 出不了（缺文件 / 缺密钥…）：去出包页看原因，不悄悄没反应
    }

    /// 出包页的「开始」：出 iPhone 时按「出完之后」那条路一步走完——装到 iPhone（出好接着装）或导出自签包（出好接着导出，不连手机）
    @discardableResult
    func startExport(_ game: GameSummary, location: String? = nil) -> ExportBlocker? {
        guard exportTargets.contains(.ios) else { return export(game, location: location) }
        let selfSign = iosAfterPack == "export"
        if selfSign { selfSignAfterPack.insert(game.id) } else { installAfterPack.insert(game.id) }
        let b = export(game, location: location, mode: selfSign ? "export" : nil)
        if b?.stopsStart == true { selfSignAfterPack.remove(game.id); installAfterPack.remove(game.id) }
        return b
    }

    /// 装机 / 更新失败的那页上「改为导出自签包」：不连手机也能走完（11-16 维护者：没插手机就卡死是我们自己设的障碍）
    func switchToSelfSign(_ session: JobSession, language: String) {
        // 只管这一次（11-19 自签走查结构 8）：不改出包页「出完之后」的记忆，原先改了就成了隐藏的全局开关——之后续签只导出、不动手机，7 天到点打不开
        if session.kind == .installUpdate, let a = lastUpdateArgs {
            updatePhone(acceptStale: a.acceptStale, repack: a.repack, language: language, accept: a.accept, mode: "export", sgradeUpgrade: a.sgradeUpgrade)
        } else if let id = session.gameID, let game = games.first(where: { $0.id == id }) {
            exportSelfSign(game)
        }
    }

    /// 签名身份（一键装时）：开发者证书开着 = devcert，否则 Apple ID（0.6.0 起在 S2Arm 里登录）
    var signIdentity: String { devCert?.active == true ? "devcert" : "xcode" }

    /// 游戏库右上角按钮对应的那台（多台时取第一台：按钮点下去装的是现在连着的那台，作业里按它自己的记录再判一遍）
    var phoneUpdate: PhoneUpdate? { phoneUpdates.first }

    /// 点「更新 iPhone 上的 S2Arm」：没有要重新出包的款直接更新；有就先弹三选一
    func requestPhoneUpdate(language: String) {
        guard let u = phoneUpdate else { return }   // 手机槽忙也能点：更新排到手机槽空出来（updatePhone）
        if u.stale.isEmpty { updatePhone(acceptStale: false, repack: [], language: language) } else { updateConfirm = u }
    }

    /// 三选一的结果：repack = 更新完要排进批量出包的款（「更新并重新出这几款」），空 = 「只更新，其他稍后」
    /// acceptDropped / ask 同 install：会让手机上别的电脑装的游戏暂时不能玩时，界面发起的（ask）弹同一个确认框，确认后带 acceptDropped 重跑；
    ///   控制口发起的不弹、原样失败，由调用方带 acceptDropped 再发
    func updatePhone(acceptStale: Bool, repack: [String], language: String, device: String? = nil, acceptDropped: Bool = false, accept: Set<String> = [], ask: Bool = true,
                     mode: String? = nil, sgradeUpgrade: Bool = false) {
        let accept = acceptDropped ? accept.union(["acceptDropped"]) : accept
        // 没指定这次怎么走 = 装到手机（11-19 自签走查结构 8）：出包页「出完之后」只管出包页那一次，不当续签 / 更新的全局开关；要导出就由调用方明确传 mode = "export"
        guard !phoneBusy else {   // 出包等主槽作业照跑也能更新（手机槽）；手机槽忙 → 排队
            phoneQueue.append((nil, { [weak self] in self?.updatePhone(acceptStale: acceptStale, repack: repack, language: language, device: device, accept: accept, ask: ask,
                                                                       mode: mode, sgradeUpgrade: sgradeUpgrade) })); return
        }
        updateConfirm = nil; updateRepack = repack
        // 更新哪台：壳旧了的那台（phoneUpdates 的设备记录键）；没有就是玩家选的那台。一律带上，作业层不自己挑（v0.3.0 验收测出连着两台报错；11-11 设备号贯穿所有装机入口）
        let device = mode == "export" ? nil : device ?? phoneUpdate?.device ?? installDeviceID
        phoneOutcome = nil
        selfSigning = mode == "export"
        lastUpdateArgs = UpdateArgs(acceptStale: acceptStale, repack: repack, language: language, device: device, accept: accept, mode: mode, sgradeUpgrade: sgradeUpgrade)
        start(JobSession(kind: .installUpdate, gameID: nil, name: BackendText.launcherText("update.running", language: language))) { [weak self] sink in
            do {
                let r = try await self?.provider.updatePhone(acceptStale: acceptStale, accept: accept, mode: mode, sgradeUpgrade: sgradeUpgrade, device: device, events: sink) ?? [:]
                let names = Dictionary((self?.games ?? []).map { ($0.id.uppercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
                self?.installTrustName = r["trustName"] as? String ?? ""   // 重装了 App（换团队 / 续签）：完成页同样说要点哪一项信任
                self?.phoneOutcome = PhoneOutcome(device: Self.deviceLabel(kind: r["deviceKind"] as? String ?? "", name: r["deviceName"] as? String ?? ""),
                                                  packFiles: (r["packFiles"] as? NSNumber)?.intValue, packBytes: (r["packBytes"] as? NSNumber)?.int64Value,
                                                  skipped: (r["skipped"] as? [String] ?? []).map { names[$0.uppercased()] ?? $0 },
                                                  version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                                                  exportFolder: r["exported"] as? Bool == true ? r["outputPath"] as? String ?? "" : "",
                                                  exportGames: (r["games"] as? [Any])?.count ?? 0, exportBytes: (r["exportBytes"] as? NSNumber)?.int64Value,
                                                  exportFresh: r["fresh"] as? [String] ?? [], exportReused: (r["reused"] as? NSNumber)?.intValue ?? 0,
                                                  exportUnwritten: r["unwritten"] as? [String] ?? [],
                                                  sgrade: (r["sgrade"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }
                                                      .map { SGradeGameResult(name: names[$0.key.uppercased()] ?? $0.key, outcome: SGradeOutcome($0.value as? [String: Any] ?? [:])) },
                                                  legacy: (r["legacy"] as? [[String: Any]] ?? []).compactMap { g in (g["gameId"] as? String).map { LegacyGame(id: $0.uppercased(), name: g["name"] as? String ?? $0) } },
                                                  legacyElsewhere: (r["legacyElsewhere"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String ?? $0["gameId"] as? String },
                                                  legacyDevice: r["legacyDevice"] as? String ?? "")
                if r["exported"] as? Bool == true, let folder = r["outputPath"] as? String { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
            }
            catch let f as JobFailure where ask && Self.confirmCodes[f.code ?? ""] != nil {
                self?.dropConfirm = DropConfirm(kind: .installUpdate, message: f.errorDescription ?? "",
                                                update: UpdateArgs(acceptStale: acceptStale, repack: repack, language: language, device: device, accept: accept, mode: mode, sgradeUpgrade: sgradeUpgrade),
                                                code: f.code ?? "", accept: accept.union([Self.confirmCodes[f.code ?? ""]!]))
                throw f
            }
            return nil
        }
    }

    /// 更新作业结束：重读游戏库（按钮随检测结果消失）；选了重新出的款 → 排进批量出包（只出 iPhone），出完逐款装上
    func phoneUpdateEnded(completed: Bool) {
        let repack = completed ? updateRepack : []
        updateRepack = []
        refresh()
        guard !repack.isEmpty else { return }
        Task {
            openBatch(repack)
            for i in batchDraft.indices { batchDraft[i].iphone = batchDraft[i].problem == nil; batchDraft[i].mac = false }
            batchInstallAfter = true
            if await createBatch() != nil { batchInstallAfter = false }
        }
    }

    /// 批次出完（没有下一个了）：由更新发起的那批，出好的 iPhone 包逐款装上（暂停 / 取消的不装）
    func batchFinished() {
        guard batchInstallAfter else { return }
        batchInstallAfter = false
        guard batchPaused == nil else { return }
        installAfterQueue = batchItems.compactMap { item in
            let r = item["results"] as? [String: [String: Any]] ?? [:]
            return r["iphone"]?["state"] as? String == "completed" ? item["gameId"] as? String : nil
        }
        installNextQueued()
    }

    func installNextQueued() {
        guard !phoneBusy, !installAfterQueue.isEmpty else { return }   // 手机槽空就装（主槽在出别的款也装）
        let id = installAfterQueue.removeFirst()
        installAfterPack.remove(id)
        if let game = games.first(where: { $0.id == id }) { install(game, export: selfSignAfterPack.remove(id) != nil) } else { installNextQueued() }
    }
}
