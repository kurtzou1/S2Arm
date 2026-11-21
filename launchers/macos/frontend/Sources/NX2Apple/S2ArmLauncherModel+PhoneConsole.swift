// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import S2ArmAppleAdapter

/// 0.6.0 iPhone 总控台（通用壳开关后面，《0.6.0 极简流程》界面一节「iPhone 总控台」）：游戏库首位固定「S2Arm」卡，选中它就是这台手机的总控台。
///   不加门、不加锁：要手机的按钮只在没连时灰并就近写原因，其余都能点。
extension S2ArmLauncherModel {
    /// 首位卡的选中号（不是游戏号，永远排第一、不能删不能挪、不算进游戏数）
    static let consoleID = "s2arm.console"
    var consoleSelected: Bool { selectedID == Self.consoleID }

    func refreshPhoneOverview(probe: Bool = false) {
        Task { await loadPhoneOverview(probe: probe) }
    }

    func loadPhoneOverview(probe: Bool) async {
        // 读不到不弹框（首位卡是附带的入口），但不吞：记日志，保持上次的值
        do {
            let o = try await provider.phoneOverview(probe: probe, device: consoleDevice)   // 带上总控台当前这台
            phoneOverview = o
            if let o, !o.phones.contains(where: { $0.device == consoleDevice }) { consoleDevice = nil }
            seedConsoleSelection()
        } catch { NSLog("S2Arm phoneOverview: %@", String(describing: error)) }
    }

    /// 介绍卡「连上 iPhone 开始」（11-19 自签走查结构 5：从连着的手机上实际装了什么出发）：先现查连着的手机（probe）；
    ///   查到手机上已有 S2Arm（别的工具装的 → 总控台「用别的工具装的」那套按钮；启动器装的 → 它自己的状态）就停在总控台，不装第二个；
    ///   什么都没装（或查不出）才接着原来的装机（安装 S2Arm）。只在玩家点了才 probe，启动时不多发
    func consoleIntroStart(language: String) {
        Task {
            await loadPhoneOverview(probe: true)
            if let p = consolePhone, p.installedBy != nil { consoleDevice = p.device; return }
            updatePhone(acceptStale: false, repack: [], language: language, device: consolePhone?.device)
        }
    }

    /// 总控台一台手机上的按钮（界面和控制口 GET /state 的 phoneConsole 同一个来源；动作名同控制口 POST /console-action）
    enum ConsoleAction: String, CaseIterable {
        case installShell, updateShell, renewShell   // ① 启动器装的：安装 / 更新 / 续签 S2Arm（同一颗按钮随状态变）
        case exportShellIpa                          // ① 别的工具装的：导出通用 S2Arm.ipa（玩家拿去用原来的工具签、覆盖装新版）
        case handOverIdentity                        // ① 把签名身份交给手机（作业 phoneIdentity）
        case updateSelected                          // ② 启动器装的：更新所选（作业 pushSelected）
        case pushS2arm                               // ② 别的工具装的：把所选推到 iPhone（同一单 pushSelected，作业层推未签名 .s2arm、手机自己签）
        case exportS2arm                             // ② 别的工具装的：导出所选的 .s2arm
        case chooseApp                               // ① 同一台手机上装着不止一个 S2Arm：选用哪一个（作业 phoneChooseApp）；选过了也能「换一个」
    }

    /// 这台手机显示哪些按钮。别的工具装的：按作业给的 actions（认不得的丢掉；作业没给按四个缺省），绝不出安装 / 续签 / 更新 S2Arm；
    ///   其余：① 安装 / 更新 / 续签 一颗 + 交签名身份，② 更新所选
    ///   装着不止一个、玩家还没选（needsChoice）：只出「选用哪个 S2Arm」；选过了、候选不止一个：末尾加「换一个」
    func consoleActions(_ p: PhoneOverview.Phone) -> [ConsoleAction] {
        if p.needsChoice { return [.chooseApp] }
        let change: [ConsoleAction] = p.candidates.count > 1 ? [.chooseApp] : []
        if p.installedBy == .external {
            let shell: Set<ConsoleAction> = [.installShell, .updateShell, .renewShell, .updateSelected, .chooseApp]
            let given = p.actions.compactMap(ConsoleAction.init).filter { !shell.contains($0) }
            return (given.isEmpty ? [.exportShellIpa, .pushS2arm, .exportS2arm, .handOverIdentity] : given) + change
        }
        // 还没装 S2Arm：只给「安装 S2Arm」——交签名身份、更新所选都要手机上先有 S2Arm，列出来新手会以为要先点它们
        if !p.installed { return [.installShell] + change }
        return [!p.shellCurrent ? .updateShell : .renewShell, .handOverIdentity, .updateSelected] + change
    }

    /// 候选的标签（文案键，按顺序拼）：这台电脑的启动器装的 / 别的工具装的；导入的签名证书团队与 App 团队对得上时追加「已导入签名证书」。
    ///   只陈述事实、不推荐哪一个（候选按作业给的包名顺序列）
    static func candidateLabelKeys(_ c: PhoneOverview.Candidate) -> [String] {
        [c.byThisLauncher ? "console.choose.byLauncher" : "console.choose.byOther"] + (c.certImported ? ["console.choose.certImported"] : [])
    }

    /// 「选用哪个 S2Arm」：作业 phoneChooseApp 核对它确在这台手机上后记进设备记录；成没成都重新现查总览（选的已不在 → 列表跟着变）。
    ///   选成了、这台手机有推送因「还没选」停着（pushChoice）：接着重推那一次（同一台、同样的游戏）
    func chooseApp(device: String, bundleId: String) {
        guard consoleChoosing == nil else { return }
        consoleChoosing = bundleId; consoleChooseError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            var retry: (() -> Void)?
            do {
                try await self.provider.phoneChooseApp(device: device, bundleId: bundleId)
                self.consoleRechoose = false
                if let p = self.pushChoice, p.device == device { retry = p.retry; self.pushChoice = nil }
            } catch { self.consoleChooseError = error.localizedDescription }
            self.consoleChoosing = nil
            await self.loadPhoneOverview(probe: true)
            retry?()
        }
    }

    /// 推送停在「装着不止一个 S2Arm、还没选」（phone_app_choice_required）时失败页就地列的候选（作业诊断 facts，install.owner_for_push），
    ///   retry = 选好后重推的那一次（推单款 / 更新所选，同样的参数）
    struct PushChoice {
        let device: String
        let candidates: [PhoneOverview.Candidate]
        let retry: () -> Void
    }

    /// 推送失败：是「还没选」就记下候选与重推（失败页据此列候选）；别的失败清掉
    func notePushChoice(_ f: JobFailure, retry: @escaping () -> Void) {
        pushChoice = PhoneOverview.choiceFacts(f.outcome.diagnostics).map { PushChoice(device: $0.device, candidates: $0.candidates, retry: retry) }
    }

    /// 点总控台按钮（界面和控制口走这同一个函数）。ids：推 / 导出哪几款（控制口可给；不给 = 总控台勾选的、按游戏库顺序）。→ 没做的原因（nil = 已发起）
    @discardableResult
    ///   bundleId：chooseApp 选哪一个（必须是这台手机的候选之一）
    func runConsoleAction(_ a: ConsoleAction, device: String, ids: [String]? = nil, bundleId: String? = nil, language: String) -> String? {
        let order = ids?.map { $0.uppercased() } ?? games.filter { consoleSelection.contains($0.id.uppercased()) }.map { $0.id.uppercased() }
        switch a {
        case .installShell, .updateShell, .renewShell:
            updatePhone(acceptStale: false, repack: [], language: language, device: device)
        case .exportShellIpa:
            updatePhone(acceptStale: false, repack: [], language: language, mode: "export")
        case .handOverIdentity:
            phoneIdentity(device: device)
        case .updateSelected, .pushS2arm:
            if order.isEmpty { return "没选游戏" }
            if consoleUpdating { return "正在更新所选" }
            updateSelected(ids: order, device: device)
        case .exportS2arm:
            let picked = order.compactMap { id in games.first { $0.id.uppercased() == id } }
            if picked.isEmpty { return "没选游戏" }
            picked.forEach(exportSelfSign)
        case .chooseApp:
            let cands = phoneOverview?.phones.first { $0.device == device }?.candidates ?? []
            guard let bid = bundleId, cands.contains(where: { $0.bundleId == bid }) else {
                return "bundleId 不在这台手机的候选里（此刻有：\(cands.map(\.bundleId).joined(separator: " / "))）"
            }
            if consoleChoosing != nil { return "正在记下上一次的选择" }
            chooseApp(device: device, bundleId: bid)
        }
        return nil
    }

    /// 总控台当前这台：选过的那台；没选过 → 连着的那台 → 最近同步过的那台
    var consolePhone: PhoneOverview.Phone? {
        guard let phones = phoneOverview?.phones, !phones.isEmpty else { return nil }
        if let d = consoleDevice, let p = phones.first(where: { $0.device == d }) { return p }
        if let p = phones.first(where: { if case .some(.some) = $0.online { return true }; return false }) { return p }
        return phones.max { ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast) }
    }

    /// 首位卡状态行（流程稿表格，自上而下取第一条成立的）
    enum ConsoleStatus: Equatable {
        case introduce                       // 从没装过、也没连过：「在 iPhone 上玩」介绍卡
        case updating(done: Int, total: Int) // 正在更新所选
        case notConnected(lastSeen: Date?)   // 问过 USB、没连
        case chooseApp                       // 装着不止一个 S2Arm、玩家还没选用哪一个
        case externalApp                     // 手机上的 S2Arm 是别的工具（AltStore / SideStore…）装的：没有我们的签名时刻与壳号，不判没装 / 有新版 / 到期
        case notInstalled
        case appOutdated
        case expired
        case expiring(days: Int)             // ≤ 2 天
        case suggested(count: Int)
        case ok(days: Int?)                  // 还剩约 N 天（证书用户没有估值时 nil）
    }

    func consoleStatus(now: Date = Date()) -> ConsoleStatus {
        guard let p = consolePhone else { return .introduce }
        if consoleUpdating { let p = consoleProgress; return .updating(done: p.done, total: p.total) }
        if case .some(.none) = p.online { return .notConnected(lastSeen: p.lastSeen) }
        if p.needsChoice { return .chooseApp }
        if p.installedBy == .external { return .externalApp }
        if !p.installed { return .notInstalled }
        if !p.shellCurrent { return .appOutdated }
        let days = p.expiresAtEstimate.map { Self.daysLeft(until: $0, now: now) }
        if let d = days, d <= 0 { return .expired }
        if let d = days, d <= 2 { return .expiring(days: d) }
        let n = p.games.filter { $0.state == .suggested }.count
        if n > 0 { return .suggested(count: n) }
        return .ok(days: days)
    }

    /// 还剩几天（不足一天按一天，过了就是 0）：到期时刻本来就是估的，界面写「约」
    static func daysLeft(until end: Date, now: Date) -> Int {
        let s = end.timeIntervalSince(now)
        return s <= 0 ? 0 : Int((s / 86_400).rounded(.up))
    }

    /// 这款在当前这台上的状态（② 一行）；表里没有的款按没推过
    func consoleGame(_ game: GameSummary) -> PhoneOverview.Game {
        consolePhone?.games.first { $0.gameId == game.id.uppercased() }
            ?? PhoneOverview.Game(gameId: game.id.uppercased(), state: .notPushed, reasons: [], dataOnComputer: nil)
    }

    /// 建议更新的默认勾上（每次读到新总览时补勾新出现的建议更新款；玩家取消的不重勾，直到它的状态变了）
    func seedConsoleSelection() {
        let suggested = Set(consolePhone?.games.filter { $0.state == .suggested }.map(\.gameId) ?? [])
        consoleSelection.formUnion(suggested.subtracting(consoleSeeded))
        consoleSeeded = suggested
    }

    /// 「更新所选」正在跑（作业 pushSelected 占着手机槽）
    var consoleUpdating: Bool { phoneBusy && phoneSession?.kind == .pushSelected }
    /// 这一轮推到第几款 / 共几款（作业每款 begin(i, n)）
    var consoleProgress: (done: Int, total: Int) {
        guard consoleUpdating, let p = phoneSession?.progress, let i = p.index, let n = p.count else { return (0, 0) }
        return (max(i - 1, 0), n)
    }

    /// 「更新所选」：一单作业 pushSelected 按游戏库顺序推总控台这台（作业层一款失败接着推下一款，做不下去的才整轮停）。
    /// ids / device 给了就推这几款到那台（「更新 S2Arm」成功页「更新这 N 款」：刚装好 App 的那台上的 0.5.x 老款）
    func updateSelected(resume: Bool = false, ids: [String]? = nil, device: String? = nil) {
        guard !consoleUpdating, let device = device ?? consolePhone?.device else { return }
        let order = ids ?? games.filter { consoleSelection.contains($0.id.uppercased()) }.map { $0.id.uppercased() }
        guard resume || !order.isEmpty else { return }
        guard !phoneBusy else { phoneQueue.append((nil, { [weak self] in self?.updateSelected(resume: resume, ids: ids, device: device) })); return }
        consolePushing = nil
        lastPushSelectedDevice = device
        start(JobSession(kind: .pushSelected, gameID: nil, name: BackendText.launcherText("console.updateSelected", language: dynamicLanguage)
            .replacingOccurrences(of: "{0}", with: "\(order.count)"))) { [weak self] sink in
            let watch = EventSink { ev in
                if let cur = ev.fields["current"] as? String { Task { @MainActor in self?.consolePushing = cur.uppercased() } }
                sink.emit(ev)
            }
            defer { Task { @MainActor in self?.consolePushing = nil; self?.refreshPhoneOverview() } }
            do { _ = try await self?.provider.pushSelected(gameIds: order, device: device, resume: resume, events: watch) }
            catch let f as JobFailure {   // 装着不止一个 S2Arm、还没选：失败页就地列候选，选好重推这一轮
                self?.notePushChoice(f) { [weak self] in self?.updateSelected(resume: resume, ids: order, device: device) }
                throw f
            }
            return nil
        }
    }

    /// 「把签名身份交给手机」：作业 phoneIdentity 把这台电脑的签名身份交给总控台这台手机上的 S2Arm（别的工具装的团队对得上也交），
    ///   以后手机上自己签导入的游戏包。成功记下 delivered（完成提示分「交好了」/「已经有了」）；失败走手机作业的失败页（PhoneJobPanel）
    func phoneIdentity(device: String? = nil, force: Bool = false) {
        guard let device = device ?? consolePhone?.device else { return }
        guard !phoneBusy else { phoneQueue.append((nil, { [weak self] in self?.phoneIdentity(device: device, force: force) })); return }
        identityDelivered = nil
        start(JobSession(kind: .phoneIdentity, gameID: nil, name: BackendText.launcherText("phone.title.phoneIdentity", language: dynamicLanguage))) { [weak self] sink in
            let r = try await self?.provider.phoneIdentity(device: device, force: force, events: sink)
            self?.identityDelivered = r?.delivered
            return nil
        }
    }

    /// 「更新所选」失败页的「重试」（#1756）：同一台续推（作业层 resume：只推上一轮没推成的）
    func retryUpdateSelected() {
        guard let device = lastPushSelectedDevice else { return }
        updateSelected(resume: true, device: device)
    }

    /// 「停下」：取消这一单（作业层推完的留着；没推完的那款下次续推）
    func stopUpdateSelected() { if consoleUpdating { stopPhone() } }

    // ---- 顶栏动态窗口（《0.6.0 极简流程》iPhone 总控台「五」）：正在做和 App 相关的作业时显示进度，做完闪 ✓，失败留橙色「!」 ----

    /// 正在跑的手机作业：进度（拿不到为 nil）+ 一行小字；没有 = 普通图标
    var dynamicJob: (fraction: Double?, label: String)? {
        guard phoneOverview != nil, phoneBusy, let s = phoneSession else { return nil }
        if s.kind == .pushSelected {   // 更新所选算一件：「推送 3/7」+ 总进度
            let p = consoleProgress, total = max(p.total, 1)
            let text = BackendText.launcherText("dynamic.batch", language: dynamicLanguage).replacingOccurrences(of: "{0}", with: "\(min(p.done + 1, total))").replacingOccurrences(of: "{1}", with: "\(total)")
            return (s.progress.overall ?? Double(p.done) / Double(total), text)
        }
        return (s.progress.fraction, s.name)
    }

    /// 界面语言（setUILanguage 写进作业环境的那个，共享文案同一套语言码）
    var dynamicLanguage: String { provider.client.environment.uiLanguage.flatMap { $0.isEmpty ? nil : $0 } ?? "zh-Hans" }

    func dynamicFinished(_ state: JobOutcome.State) {
        guard phoneOverview != nil else { return }
        if state == .completed {
            dynamicDone = true
            Task { try? await Task.sleep(for: .seconds(2)); dynamicDone = false }
        } else { dynamicAlert = true }
    }

    /// 点动态窗口：直接到总控台（选中首位卡），看过就收起橙色「!」
    func openConsoleFromTopBar() {
        dynamicAlert = false
        goToLibrary()
        selectedID = Self.consoleID
    }
}
