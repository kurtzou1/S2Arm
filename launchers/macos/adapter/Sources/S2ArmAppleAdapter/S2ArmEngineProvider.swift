import Foundation

/// S2Arm 作为 NX2Apple 启动器里的一个引擎（设计稿 2.13 EngineProvider）。每个方法都是交 S2Arm 作业层（pack/jobs/main.py）的作业：
///
/// | 设计稿 | S2Arm 作业 |
/// |---|---|
/// | inspect | import（读原件、登记进游戏库）+ catalog（读回这几款） |
/// | build | Mac：build（作业层的 prepare，出运行文件）；iPhone：ipa（缺 .NET SDK 先 installDotnet） |
/// | settingsSchema | 空表：没有每款的游戏选项（11-07 维护者：语言跟系统、Mac 主机模式、60 帧 / 满屏缺省开 + 自动降级，作业层定） |
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
        settings = SettingsProvider(client: client)
        play = PlayService(client: client)
        environment = EnvironmentService(client: client, xcodeLocator: xcodeLocator)
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
        return ImportBatchResult(games: games, sources: ImportSource.rows(in: result))
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
        }
    }

    /// 出包编排（剃刀 H13，pack/jobs/export_plan.py）：plan = {source: inline, items, location, deviceTarget, spaceOverride} 或 {source: batch}。
    /// 每一步是作业层的普通子作业，事件经 sink 原样过来（step / child / stepEnded）；终态 paused 时抛 JobFailure（state = .paused，结果里有 pausedReason / stoppedAt）。
    /// 计划里有 iPhone 时先确认 .NET SDK（同 build：玩家只点一次）
    public func export(plan: [String: Any], hasIPhone: Bool, events: EventSink) async throws -> JobOutcome {
        if hasIPhone, dotnetMissing {
            _ = try await environment.repair("installDotnet", events: events)
            if dotnetMissing { throw JobClientError(Self.dotnetRecheckFailed) }
        }
        return try await client.perform("export", extra: ["plan": plan], events: events)
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

    /// 打 iPhone 包的目标设备探测（targetDevice 作业）：connected / models / osChoices；quick 只给静态机型表、不读设备。
    public func targetDevices(quick: Bool = false) async throws -> [String: Any] {
        try await client.perform("targetDevice", extra: quick ? ["quick": true] : [:]).result
    }

    // MARK: settings

    public func settingsSchema(for game: GameInfo) -> SettingsSchema { SettingsSchema(rows: []) }

    // MARK: run / control

    /// 起一局：settings 只用 uiLanguage 与 Switch 2 Pro 的本机转发通道；游戏语言跟系统、主机模式、宽屏 / 60 帧都由作业层定。
    /// 事件：作业事件按序转出，最后一条是这局的结局（result）。
    public func run(_ game: InstalledGame, settings s: Settings, events: EventSink) throws -> RunningGame {
        let handle = try play.play(gameId: game.gameId, uiLanguage: s.uiLanguage, arguments: Self.launchArguments(s),
                                   onEvent: { if !$0.isFinal { events.emit(EngineEvent(job: $0)) } },
                                   onFinish: { events.emit(EngineEvent(outcome: $0)) })
        return RunningGame(gameId: game.gameId, taskId: handle.id)
    }

    /// launch 请求里设置带的字段（作业层 pack/jobs/build.py runtime_env 读）
    static func launchArguments(_ s: Settings) -> [String: Any] {
        var arguments: [String: Any] = [:]
        if let autoConnect = s.values["switch2ProAutoConnect"] { arguments["switch2ProAutoConnect"] = autoConnect == "1" }
        if let relaySocket = s.values["switch2ProRelaySocket"] { arguments["switch2ProRelaySocket"] = relaySocket }
        // 本地玩家（#623）：player 字段 {user, name, folder}；没带 = 旧行为
        if let user = s.values["playerUser"] {
            arguments["player"] = ["user": user, "name": s.values["playerName"] ?? "", "folder": s.values["playerFolder"] ?? "SaveData"]
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
    public func devCertImport(p12: String, profile: String, password: String, device: String? = nil) async throws -> DevCertInfo {
        try await installer.devCertImport(p12: p12, profile: profile, password: password, device: device)
    }
    public func devCertUse(_ active: Bool) async throws { try await installer.devCertUse(active) }
    public func devCertDelete() async throws { try await installer.devCertDelete() }

    public func install(gameId: String, teamId: String? = nil, device: String? = nil, acceptDropped: Bool = false, accept: Set<String> = [], events: EventSink = .discard) async throws -> InstallResult {
        try await installer.install(gameId: gameId, teamId: teamId, device: device, acceptDropped: acceptDropped, accept: accept, events: events)
    }

    public func installMode(set mode: String? = nil) async throws -> InstallModeInfo { try await installer.installMode(set: mode) }
    public func updatePhone(acceptStale: Bool = false, acceptDropped: Bool = false, accept: Set<String> = [], device: String? = nil, events: EventSink = .discard) async throws -> [String: Any] {
        try await installer.updatePhone(acceptStale: acceptStale, acceptDropped: acceptDropped, accept: accept, device: device, events: events)
    }

    public func restorePhone(device: String? = nil, events: EventSink = .discard) async throws {
        try await installer.restorePrevious(device: device, events: events)
    }

    public func removeFromPhone(gameId: String, acceptDropped: Bool = false, accept: Set<String> = [], device: String? = nil, events: EventSink = .discard) async throws -> RemoveResult {
        try await installer.remove(gameId: gameId, acceptDropped: acceptDropped, accept: accept, device: device, events: events)
    }
}
