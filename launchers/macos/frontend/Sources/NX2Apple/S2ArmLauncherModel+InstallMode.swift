// S2Arm（不是上游文件）：「怎么签、怎么装」收成一套（v0.3.0，维护者 11-11 定）+ 更新 iPhone 上的 S2Arm。
//   装到 iPhone 的方式存在作业层 install.json（installMode 作业，Mac / Windows 同一份）：一键装到 iPhone（签名身份 = Xcode 账号 / 我的开发者证书）
//   或导出自己签名安装（导出作业合入前置灰）。完成页可临时换一次，不改这里。
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

    func setInstallMode(_ mode: String) {
        Task {
            do { installMode = try await provider.installMode(set: mode) }
            catch { reportFailure("s2arm.fail.installModeSet", error) }
        }
    }

    /// 签名身份（一键装时）：开发者证书开着 = devcert，否则 Xcode 账号
    var signIdentity: String { devCert?.active == true ? "devcert" : "xcode" }

    /// 游戏库右上角按钮对应的那台（多台时取第一台：按钮点下去装的是现在连着的那台，作业里按它自己的记录再判一遍）
    var phoneUpdate: PhoneUpdate? { phoneUpdates.first }

    /// 点「更新 iPhone 上的 S2Arm」：没有要重新出包的款直接更新；有就先弹三选一
    func requestPhoneUpdate(language: String) {
        guard let u = phoneUpdate, !busy else { return }
        if u.stale.isEmpty { updatePhone(acceptStale: false, repack: [], language: language) } else { updateConfirm = u }
    }

    /// 三选一的结果：repack = 更新完要排进批量出包的款（「更新并重新出这几款」），空 = 「只更新，其他稍后」
    /// acceptDropped / ask 同 install：会让手机上别的电脑装的游戏暂时不能玩时，界面发起的（ask）弹同一个确认框，确认后带 acceptDropped 重跑；
    ///   控制口发起的不弹、原样失败，由调用方带 acceptDropped 再发
    func updatePhone(acceptStale: Bool, repack: [String], language: String, device: String? = nil, acceptDropped: Bool = false, accept: Set<String> = [], ask: Bool = true) {
        let accept = acceptDropped ? accept.union(["acceptDropped"]) : accept
        guard !busy else { return }
        updateConfirm = nil; updateRepack = repack
        // 更新哪台：壳旧了的那台（phoneUpdates 的设备记录键）；没有就是玩家选的那台。一律带上，作业层不自己挑（v0.3.0 验收测出连着两台报错；11-11 设备号贯穿所有装机入口）
        let device = device ?? phoneUpdate?.device ?? installDeviceID
        phoneOutcome = nil
        lastUpdateArgs = UpdateArgs(acceptStale: acceptStale, repack: repack, language: language, device: device, accept: accept)
        start(JobSession(kind: .installUpdate, gameID: nil, name: BackendText.launcherText("update.running", language: language))) { [weak self] sink in
            do {
                let r = try await self?.provider.updatePhone(acceptStale: acceptStale, accept: accept, device: device, events: sink) ?? [:]
                let names = Dictionary((self?.games ?? []).map { ($0.id.uppercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
                self?.phoneOutcome = PhoneOutcome(device: Self.deviceLabel(kind: r["deviceKind"] as? String ?? "", name: r["deviceName"] as? String ?? ""),
                                                  packFiles: (r["packFiles"] as? NSNumber)?.intValue, packBytes: (r["packBytes"] as? NSNumber)?.int64Value,
                                                  skipped: (r["skipped"] as? [String] ?? []).map { names[$0.uppercased()] ?? $0 },
                                                  version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                                                  exportFolder: r["exported"] as? Bool == true ? r["outputPath"] as? String ?? "" : "",
                                                  exportGames: (r["games"] as? [Any])?.count ?? 0, exportBytes: (r["exportBytes"] as? NSNumber)?.int64Value)
                if r["exported"] as? Bool == true, let folder = r["outputPath"] as? String { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
            }
            catch let f as JobFailure where ask && Self.confirmCodes[f.code ?? ""] != nil {
                self?.dropConfirm = DropConfirm(kind: .installUpdate, message: f.errorDescription ?? "",
                                                update: UpdateArgs(acceptStale: acceptStale, repack: repack, language: language, device: device, accept: accept),
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
        guard batchInstallAfter || installMode.mode == "export" else { return }   // 导出模式：批量出完也接着导出（D-9ZF9）
        batchInstallAfter = false
        guard batchPaused == nil else { return }
        installAfterQueue = batchItems.compactMap { item in
            let r = item["results"] as? [String: [String: Any]] ?? [:]
            return r["iphone"]?["state"] as? String == "completed" ? item["gameId"] as? String : nil
        }
        installNextQueued()
    }

    func installNextQueued() {
        guard !busy, !installAfterQueue.isEmpty else { return }
        let id = installAfterQueue.removeFirst()
        if let game = games.first(where: { $0.id == id }) { install(game) } else { installNextQueued() }
    }
}
