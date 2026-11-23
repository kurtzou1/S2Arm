import Foundation

/// S2Arm 作为 NX2Apple 启动器里的一个引擎（设计稿 2.13 EngineProvider）。每个方法都是交 S2Arm 作业层（pack/jobs/main.py）的作业：
///
/// | 设计稿 | S2Arm 作业 |
/// |---|---|
/// | inspect | import（读原件、登记进游戏库）+ catalog（读回这几款） |
/// | build | Mac：build（作业层的 prepare，出运行文件）；iPhone：ipa（缺 .NET SDK 先 installDotnet） |
/// | settingsSchema | 空表：每款的游戏选项不走这里，在启动设置（共享定义表 game_settings.v1.json + 作业层 community；游戏语言 11-14 维护者确认玩家可选） |
/// | run | launch（作业层校验运行文件、恢复存档、起 s2arm-host 并等它退出） |
/// | control | stop = 请 launch 作业停（SIGTERM） |
///
/// 现有服务（LibraryProvider / SettingsProvider / PlayService / EnvironmentService / InstallService / SpaceService）是它的内部实现，也照旧对外可用：
/// 设计稿的协议没有的事（环境检查、装到 iPhone、释放空间、换游戏库）走这些服务或本类型的扩展方法。
public struct ImportSource: Decodable, Identifiable {
    public enum Status: String, Decodable { case imported, duplicate, failed, unprocessed }
    public let id: String
    public let path: String
    public let name: String
    public let fileName: String
    public let needsKeys: Bool
    public let status: Status
    public let code: String?
    public let reason: String
    public let diagnostic: String

    public var succeeded: Bool { status == .imported || status == .duplicate }

    public static func rows(in result: [String: Any]) -> [Self] {
        guard let rows = result["sources"] as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: rows) else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }
}

public struct ImportBatchResult {
    public let games: [GameInfo]
    public let sources: [ImportSource]
    /// #797：这次放进来、但游戏库里只有更新 / DLC 没有本体的游戏号（作业结果 imports[].missingBase，按整批加完后的库判）
    public let missingBase: [String]
}

public final class S2ArmEngineProvider: EngineProvider {
    public let id = EngineID("s2arm")
    /// 两个目标都出；Switch 2 款同一条出包 / 起局路径（NVN2，11-06 金刚 Switch 2 纯 Windows 出包进局）；宽屏 / 60 帧是宿主开关（按款有表才可用）；
    /// Mac 局首遇的着色器现编（runtime shaders）。没有的：120 帧、渲染倍率、金手指、云存档（作业层没有对应作业）。
    public let capabilities = EngineCapabilities(targets: [.mac, .iPhone], switch2: true, runtimeShaders: true, widescreen: true, fps60: true)

    public let client: JobClient
    public let library: LibraryProvider
    public let settings: SettingsProvider
    public let play: PlayService
    public let environment: EnvironmentService
    public let installer: InstallService
    public let space: SpaceService

    public init(client: JobClient, xcodeLocator: @escaping () -> String? = XcodeLocator.detect) {
        self.client = client
        library = LibraryProvider(client: client)
        let settings = SettingsProvider(client: client)
        self.settings = settings
        play = PlayService(client: client)
        // 玩家在环境页自己选过、而且是完整的 Xcode 就用它（玩家自选优先）；没选或选的不可用照旧自动找
        environment = EnvironmentService(client: client, xcodeLocator: { settings.xcodeApp.flatMap(XcodeLocator.developerDir(app:)) ?? xcodeLocator() })
        installer = InstallService(client: client)
        space = SpaceService(client: client)
    }

    // MARK: inspect

    /// 设计稿 inspect：放进来的文件里第一款。一次放进多款用 importGames。
    public func inspect(_ inputs: GameInputs) async throws -> GameInfo {
        guard let first = try await importGames(inputs).first else { throw JobClientError(Self.nothingImported) }
        return first
    }

    public static let nothingImported = "没有读到游戏：放进来的文件里没有可导入的 NSP / XCI。"

    /// import 作业登记进游戏库（原件留在原处、只读不复制），再 catalog 读回这几款（已在库里的也算，按导入顺序）。
    public func importGames(_ inputs: GameInputs, events: EventSink = .discard) async throws -> [GameInfo] {
        try await importGames(inputs, partialResults: false, events: events).games
    }

    public func importGames(_ inputs: GameInputs, partialResults: Bool, events: EventSink = .discard) async throws -> ImportBatchResult {
        guard !inputs.paths.isEmpty else { throw JobClientError(Self.nothingImported) }
        try await library.ensureLibrary(events: events)
        try Task.checkCancellation()
        var extra: [String: Any] = ["paths": inputs.paths.map(\.path)]
        if partialResults { extra["partialResults"] = true }
        let result = try await client.perform("import", extra: extra, events: events).result
        let games = partialResults ? await importedGames(in: result) : try await resolveImportedGames(in: result)
        var missingBase: [String] = []
        for item in result["imports"] as? [[String: Any]] ?? [] where item["missingBase"] as? Bool == true {
            if let id = item["id"] as? String, !id.isEmpty, !missingBase.contains(id) { missingBase.append(id) }
        }
        return ImportBatchResult(games: games, sources: ImportSource.rows(in: result), missingBase: missingBase)
    }

    public func importedGames(in result: [String: Any]) async -> [GameInfo] {
        (try? await resolveImportedGames(in: result)) ?? []
    }

    private func resolveImportedGames(in result: [String: Any]) async throws -> [GameInfo] {
        var ids: [String] = []
        for item in result["imports"] as? [[String: Any]] ?? [] {
            if let id = item["id"] as? String, !id.isEmpty, !ids.contains(id) { ids.append(id) }
        }
        let games = try await library.games()
        return ids.compactMap { id in games.first { $0.id == id }.map(GameInfo.init(summary:)) }
    }

    /// 游戏库全部（catalog）。
    public func catalog() async throws -> [GameSummary] { try await library.games() }

    // MARK: build

    public static let dotnetRecheckFailed = ".NET SDK 装完复查仍不通过：打开环境检查看缺什么，处理后再打 iPhone 包。"

    public func build(_ job: BuildJob, events: EventSink) async throws -> BuildResult {
        switch job.target {
        case .mac:
            var extra: [String: Any] = ["gameId": job.gameId]
            if job.spaceOverride { extra["spaceOverride"] = true }
            if let location = job.location { extra["location"] = location }
            let r = try await client.perform("build", extra: extra, events: events).result
            return BuildResult(gameId: job.gameId, target: .mac, outputPath: r["outputPath"] as? String, ipa: nil, raw: r)
        case .iPhone:
            // 打 iPhone 包要 .NET SDK：上次检查说没装就先一键装好再接着出（同旧启动器 packIPhone：玩家只点一次）
            if dotnetMissing {
                _ = try await environment.repair("installDotnet", events: events)
                if dotnetMissing { throw JobClientError(Self.dotnetRecheckFailed) }
            }
            var extra: [String: Any] = ["gameId": job.gameId]
            if let target = job.deviceTarget { extra["target"] = target }
            if job.spaceOverride { extra["spaceOverride"] = true }
            if job.followUp { extra["followUp"] = true }
            if let location = job.location { extra["location"] = location }
            let r = try await client.perform("ipa", extra: extra, events: events).result
            return BuildResult(gameId: job.gameId, target: .iPhone, outputPath: r["outputPath"] as? String, ipa: r["ipa"] as? String, raw: r)
        case .appleTV:
            // Apple TV：同一个 ipa 作业，platform = "tvos"（tvOS 壳与 image/tvos 由出包流程出）
            var extra: [String: Any] = ["gameId": job.gameId, "platform": "tvos"]
            if job.spaceOverride { extra["spaceOverride"] = true }
            if let location = job.location { extra["location"] = location }
            let r = try await client.perform("ipa", extra: extra, events: events).result
            return BuildResult(gameId: job.gameId, target: .appleTV, outputPath: r["outputPath"] as? String, ipa: r["ipa"] as? String, raw: r)
        }
    }

    /// 记玩家对这款的下游深度方案选择（scheme = 方案 id；"" = 仍用原版）。之后的出包 / 装机作业按它走（pack/jobs/downstream.py requested）
    public func setDownstreamChoice(gameId: String, scheme: String, events: EventSink) async throws {
        _ = try await client.perform("downstreamChoice", extra: ["gameId": gameId, "scheme": scheme], events: events)
    }

    /// 出包编排（剃刀 H13，pack/jobs/export_plan.py）：plan = {source: inline, items, location, deviceTarget, spaceOverride} 或 {source: batch}。
    /// 每一步是作业层的普通子作业，事件经 sink 原样过来（step / child / stepEnded）；终态 paused 时抛 JobFailure（state = .paused，结果里有 pausedReason / stoppedAt）。
    /// 计划里有 iPhone 时先确认 .NET SDK（同 build：玩家只点一次）
    public func export(plan: [String: Any], hasIPhone: Bool, mode: String? = nil, events: EventSink) async throws -> JobOutcome {
        if hasIPhone, dotnetMissing {
            _ = try await environment.repair("installDotnet", events: events)
            if dotnetMissing { throw JobClientError(Self.dotnetRecheckFailed) }
        }
        var extra: [String: Any] = ["plan": plan]
        if let mode { extra["mode"] = mode }   // 子作业照带（export_plan._run_step 复制父请求）
        return try await client.perform("export", extra: extra, events: events)
    }

    private var dotnetMissing: Bool { environment.checks?.first { $0.action == "installDotnet" }?.ok == false }

    // MARK: 本机控制口用到的几个作业（AI 操作，11-07；参数同旧启动器 Store 的同名动作）

    /// 放密钥（keys 作业：校验 prod.keys、放进游戏库；新玩家的游戏库先建好）；完了重读游戏库，keysReady 跟着更新。
    public func importKeys(_ file: URL, events: EventSink = .discard) async throws -> String {
        try await library.ensureLibrary(events: events)
        let r = try await client.perform("keys", extra: ["path": file.path], events: events).result
        _ = try? await library.games()
        return r["message"] as? String ?? ""
    }

    /// 删这款（delete 作业：IPA / 资源包 / 出包中间产物 / 缓存，存档与原始游戏文件保留）。
    public func deleteGame(_ gameId: String, events: EventSink = .discard) async throws {
        _ = try await client.perform("delete", extra: ["gameId": gameId], events: events)
    }

    // MARK: 存放位置（游戏库结构 v3，pack/jobs/layout.py）

    /// 各存放位置（出包页下拉框）和上次用的位置号。
    /// probe：刚在「选择其他文件夹…」里选的路径，另查它所在盘会不会让解包多占数倍空间（#444）
    public func locations(probe: String? = nil) async throws -> (rows: [StorageLocation], last: String, probeSlack: LocationSlack??) {
        let r = try await client.perform("locations", extra: probe.map { ["probe": $0] } ?? [:], events: .discard).result
        return ((r["locations"] as? [[String: Any]] ?? []).compactMap(StorageLocation.init), r["last"] as? String ?? "",
                (r["probe"] as? [String: Any]).map { LocationSlack($0) })
    }

    /// 把这款整个搬到另一个存放位置（同一卷改名，跨卷拷完核对再删旧的；存档跟着走）。
    public func moveGame(_ gameId: String, to location: String, events: EventSink = .discard) async throws {
        _ = try await client.perform("moveGame", extra: ["gameId": gameId, "location": location], events: events)
    }

    /// 「重新指定文件夹」：选到的文件夹里 game.json 的游戏号对得上才接受。
    public func relinkGame(_ gameId: String, folder: String) async throws {
        _ = try await client.perform("relinkGame", extra: ["gameId": gameId, "folder": folder], events: .discard)
    }

    /// 「从游戏库移除」：清单和索引里去掉，磁盘上的文件不动。
    public func forgetGame(_ gameId: String) async throws {
        _ = try await client.perform("forgetGame", extra: ["gameId": gameId], events: .discard)
    }

    /// 清这款的缓存（出包缓存 + 运行时着色器缓存）。
    public func clearCache(_ gameId: String, events: EventSink = .discard) async throws {
        _ = try await client.perform("clean", extra: ["gameId": gameId, "kind": "cache"], events: events)
    }

    /// 改游戏显示名 / 封面：nil 不动，空字符串恢复默认。
    public func customizeGame(_ gameId: String, name: String?, coverPath: String?, events: EventSink = .discard) async throws {
        var extra: [String: Any] = ["gameId": gameId]
        if let name { extra["name"] = name }
        if let coverPath { extra["coverPath"] = coverPath }
        _ = try await client.perform("customize", extra: extra, events: events)
    }

    /// Mac 端诊断包写到 path（diagnostics 作业）。
    public func exportDiagnostics(to path: URL, events: EventSink = .discard) async throws {
        _ = try await client.perform("diagnostics", extra: ["path": path.path], events: events)
    }

    /// 拉回连着的 iPhone 上各款的诊断（pullDiagnostics 作业）→ 结果（outputPath、apps）。
    public func pullDiagnostics(events: EventSink = .discard) async throws -> [String: Any] {
        try await client.perform("pullDiagnostics", events: events).result
    }

    // MARK: Apple TV（tvOS 版，pack/jobs/tvos.py）

    /// 配对过的 Apple TV（tvDevices 作业）→ [{id, udid, name, model, os, kind, online}]；没有 / 读不到 = 空表。
    public func appleTVDevices() async throws -> [[String: Any]] {
        try await client.perform("tvDevices").result["devices"] as? [[String: Any]] ?? []
    }

    /// 装到 Apple TV（tvInstall 作业）：device = 选的那台（设备号 / UDID），nil = 只连着一台时用它。
    ///   teamId：出包页「Apple TV 用的 Xcode 团队」里手填的团队号（作业层 tvos.install_tv → install.pick_team(xcode_teams, teamId)）；没填不带
    public func installAppleTV(gameId: String, device: String?, teamId: String? = nil, events: EventSink = .discard) async throws -> [String: Any] {
        var extra: [String: Any] = ["gameId": gameId]
        if let device { extra["device"] = device }
        if let teamId, !teamId.isEmpty { extra["teamId"] = teamId }
        return try await client.perform("tvInstall", extra: extra, events: events).result
    }

    /// 导出 Apple TV 安装包（tvExport 作业，11-16）：未签名 .ipa、游戏资源在 App 本体里，玩家用自己的签名工具签名装；结果 ipa = 文件位置。
    public func exportAppleTV(gameId: String, events: EventSink = .discard) async throws -> [String: Any] {
        try await client.perform("tvExport", extra: ["gameId": gameId], events: events).result
    }

    /// 电视存档自动备份一轮（tvSaveBackup 作业）：没连电视不算错（state = unreachable）。
    public func appleTVSaveBackup() async throws -> [String: Any] {
        try await client.perform("tvSaveBackup").result
    }

    /// 打 iPhone 包的目标设备探测（targetDevice 作业）：connected / models / osChoices；quick 只给静态机型表、不读设备。
    /// 已连接的安卓手机（androidDevices 作业，adb devices -l）→ {enabled, adb, devices: [{serial, state, model}]}；enabled = 安卓出包开没开。
    public func androidDevices() async throws -> [String: Any] {
        try await client.perform("androidDevices").result
    }

    public func targetDevices(quick: Bool = false) async throws -> [String: Any] {
        try await client.perform("targetDevice", extra: quick ? ["quick": true] : [:]).result
    }

    // MARK: settings

    public func settingsSchema(for game: GameInfo) -> SettingsSchema { SettingsSchema(rows: []) }

    // MARK: run / control

    /// 起一局：settings 只用 uiLanguage 与 Switch 2 Pro 的本机转发通道；游戏语言跟系统、主机模式、宽屏 / 60 帧都由作业层定。
    /// 事件：作业事件按序转出，最后一条是这局的结局（result）。
    public func run(_ game: InstalledGame, settings s: Settings, events: EventSink) throws -> RunningGame {
        var arguments = Self.launchArguments(s)
        if settings.launchFullscreen { arguments["launchFullscreen"] = true }   // 启动器设置「启动游戏时自动全屏」（#575）
        let handle = try play.play(gameId: game.gameId, uiLanguage: s.uiLanguage, arguments: arguments,
                                   onEvent: { if !$0.isFinal { events.emit(EngineEvent(job: $0)) } },
                                   onFinish: { events.emit(EngineEvent(outcome: $0)) })
        return RunningGame(gameId: game.gameId, taskId: handle.id)
    }

    /// launch 请求里设置带的字段（作业层 pack/jobs/build.py runtime_env 读）
    static func launchArguments(_ s: Settings) -> [String: Any] {
        var arguments: [String: Any] = [:]
        if let autoConnect = s.values["switch2ProAutoConnect"] { arguments["switch2ProAutoConnect"] = autoConnect == "1" }
        if let relaySocket = s.values["switch2ProRelaySocket"] { arguments["switch2ProRelaySocket"] = relaySocket }
        if let xboxRelay = s.values["xboxGipRelaySocket"] { arguments["xboxGipRelaySocket"] = xboxRelay }
        // 本地玩家（#623）：player 字段 {user, name, folder}；没带 = 旧行为
        if let user = s.values["playerUser"] {
            arguments["player"] = ["user": user, "name": s.values["playerName"] ?? "", "folder": s.values["playerFolder"] ?? "SaveData"]
        }
        if let localPlayers = s.values["localPlayers"] {
            arguments["localPlayers"] = localPlayers
        }
        return arguments
    }

    public func control(_ game: RunningGame, _ cmd: ControlCommand) {
        switch cmd {
        case .stop:
            guard play.current?.id == game.taskId else { return }   // 不是这一局（已结束 / 别的局）不动
            play.stop()
        }
    }

    // MARK: iPhone 安装（设计稿协议之外）

    public func signingProject() async throws -> String { try await installer.signingProject() }
    public func installReadiness(gameId: String, device: String? = nil) async throws -> InstallReadiness { try await installer.readiness(gameId: gameId, device: device) }
    public func devCertStatus(device: String? = nil) async throws -> DevCertStatus { try await installer.devCertStatus(device: device) }
    public func devCertImport(p12: String, profile: String, password: String, device: String? = nil, add: Bool = false) async throws -> DevCertInfo {
        try await installer.devCertImport(p12: p12, profile: profile, password: password, device: device, add: add)
    }
    public func devCertUse(_ active: Bool) async throws { try await installer.devCertUse(active) }
    public func devCertChoose(device: String, cert: String) async throws { try await installer.devCertChoose(device: device, cert: cert) }
    public func devCertDelete(cert: String? = nil) async throws { try await installer.devCertDelete(cert: cert) }
    public func signModeSet(_ mode: String) async throws -> String { try await installer.signModeSet(mode) }
    public func diagCodeSet(_ code: String) async throws -> String { try await installer.diagCodeSet(code) }
    public func layoutSet(_ layout: String?, gameId: String? = nil) async throws -> String { try await installer.layoutSet(layout, gameId: gameId) }
    public func appleLogin(account: String, password: String, events: EventSink = .discard) async throws -> AppleAccount {
        try await installer.appleLogin(account: account, password: password, events: events)
    }
    public func appleAccount() async throws -> AppleAccount { try await installer.appleAccount() }
    public func appleLoginCode(_ code: String, taskId: String) throws { try installer.appleLoginCode(code, taskId: taskId) }

    public func install(gameId: String, teamId: String? = nil, device: String? = nil, acceptDropped: Bool = false, accept: Set<String> = [], mode: String? = nil,
                        sign: String? = nil, events: EventSink = .discard) async throws -> InstallResult {
        try await installer.install(gameId: gameId, teamId: teamId, device: device, acceptDropped: acceptDropped, accept: accept, mode: mode, sign: sign,
                                    widget: settings.homeWidget, cloudSaves: settings.cloudSavesFolder, events: events)
    }

    public func installMode() async throws -> InstallModeInfo { try await installer.installMode() }
    /// 0.6.0 通用壳（开关后面）的快速比对「建议更新」（作业 updateHints，pack/jobs/host_update.py）：每款只读 game.json。
    ///   开关关着 → nil（界面什么都不出）；开着 → 游戏号（大写）→ 原因（rewriter / hostAbi / shader），没对不上的款不在表里
    /// 0.6.0 总控台「更新所选」（作业 pushSelected，pack/jobs/install.py push_selected）：所选几款按顺序各推一次，一款失败接着推下一款，
    ///   换哪款都做不下去（没装 App / 手机断开）才整轮停；停 = 取消作业，推完的留着；resume = 从上一轮没推成的接着推
    public func pushSelected(gameIds: [String], device: String?, resume: Bool = false, events: EventSink = .discard) async throws -> [String: Any] {
        var extra: [String: Any] = resume ? ["resume": true] : ["gameIds": gameIds]
        if let device, !device.isEmpty { extra["device"] = device }
        return try await client.perform("pushSelected", extra: extra, events: events).result
    }
    /// 0.6.0 iPhone 总控台：所有见过的手机与每款在那台上的状态（作业 phoneOverview）；开关关着 → nil。probe：顺带问 USB 上连着谁（要几秒）
    ///   device：总控台当前这台（随现查请求带上）
    public func phoneOverview(probe: Bool = false, device: String? = nil) async throws -> PhoneOverview? {
        var extra: [String: Any] = probe ? ["probe": true] : [:]
        extra["liveContainer"] = true
        if probe, let device, !device.isEmpty { extra["device"] = device }
        return PhoneOverview(result: try await client.perform("phoneOverview", extra: extra).result)
    }
    public func updateHints() async throws -> [String: [String]]? {
        let r = try await client.perform("updateHints").result
        guard r["games"] is [Any] else { return nil }
        var out: [String: [String]] = [:]
        for g in r["games"] as? [[String: Any]] ?? [] {
            if let id = g["gameId"] as? String, let why = g["reasons"] as? [String], !why.isEmpty { out[id.uppercased()] = why }
        }
        return out
    }
    /// 「更新这款」（0.6.4，作业 updateGame）：只在电脑上按原因做齐这一款（重编 iPhone 与 Mac 两份着色器库、按本版改写器刷新程序），不找设备、不推、不签名。
    ///   结果 reasons = 做完后还剩的建议更新原因（空 = 已是最新）；做不齐的项作业照常成功、另给 warning 诊断 update_incomplete（summary 是玩家句），原样带回
    /// 「重新添加原件…」（#1961）：import 作业带 expectGameId，只认这一款——是 → 改记原件新位置（不动已有出包）；不是 → input_wrong_game、不记进库
    public func relinkSource(gameId: String, source: URL, events: EventSink = .discard) async throws {
        try await library.ensureLibrary(events: events)
        _ = try await client.perform("import", extra: ["paths": [source.path], "expectGameId": gameId], events: events)
    }

    public func updateGame(gameId: String, events: EventSink = .discard) async throws -> UpdateGameResult {
        let o = try await client.perform("updateGame", extra: ["gameId": gameId], events: events)
        return UpdateGameResult(outcome: o.result, diagnostics: o.diagnostics)
    }
    public func updatePhone(acceptStale: Bool = false, acceptDropped: Bool = false, accept: Set<String> = [], mode: String? = nil, sgradeUpgrade: Bool = false,
                            device: String? = nil, events: EventSink = .discard) async throws -> [String: Any] {
        try await installer.updatePhone(acceptStale: acceptStale, acceptDropped: acceptDropped, accept: accept, mode: mode, sgradeUpgrade: sgradeUpgrade, device: device,
                                        widget: settings.homeWidget, cloudSaves: settings.cloudSavesFolder, events: events)
    }

    /// 同一台手机上装着不止一个 S2Arm 时，玩家选用哪一个（总控台「选用哪个 S2Arm」，作业 phoneChooseApp）：记进设备记录，之后推送 / 总控台都用它
    public func phoneChooseApp(device: String, bundleId: String) async throws {
        _ = try await client.perform("phoneChooseApp", extra: ["device": device, "bundleId": bundleId])
    }

    /// 「把签名身份交给手机」（总控台 ① 手机与 App，作业 phoneIdentity）
    public func phoneIdentity(device: String? = nil, force: Bool = false, events: EventSink = .discard) async throws -> PhoneIdentityResult {
        try await installer.phoneIdentity(device: device, force: force, events: events)
    }

    public func restorePhone(device: String? = nil, events: EventSink = .discard) async throws {
        try await installer.restorePrevious(device: device, events: events)
    }

    public func removeFromPhone(gameId: String, acceptDropped: Bool = false, accept: Set<String> = [], device: String? = nil, events: EventSink = .discard) async throws -> RemoveResult {
        try await installer.remove(gameId: gameId, acceptDropped: acceptDropped, accept: accept, device: device, events: events)
    }
}

/// 「更新这款」的结果（作业 updateGame）：reasons = 做完后还剩的原因码（同 updateHints），incomplete = 这次没做齐的几项（作业层玩家句，warning 诊断 update_incomplete）
public struct UpdateGameResult: Equatable {
    public let reasons: [String]
    public let incomplete: [String]
    /// 黄字里有「原件也不在」那句（诊断 facts.action = relinkSource，#1961）：按钮下给「重新添加原件…」
    public let relinkSource: Bool
    public init(reasons: [String], incomplete: [String], relinkSource: Bool = false) { self.reasons = reasons; self.incomplete = incomplete; self.relinkSource = relinkSource }
    public init(outcome r: [String: Any], diagnostics: [[String: Any]]) {
        reasons = r["reasons"] as? [String] ?? []
        relinkSource = diagnostics.contains { $0["code"] as? String == "update_incomplete" && ($0["facts"] as? [String: Any])?["action"] as? String == "relinkSource" }
        // 玩家句在诊断的 summary（作业层 c.diagnostic 的形状，没有 message 字段；#1961）；suggestion 是通用句，不拼进来（整句才能按翻译表译）
        incomplete = diagnostics.filter { $0["code"] as? String == "update_incomplete" }.compactMap { ($0["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    }
}
