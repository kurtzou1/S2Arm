import Foundation

/// 一款游戏登记的一个原件（catalog 的 packages 一项）：本体 / 更新 / DLC。
public struct GamePackage: Equatable {
    /// base / update / dlc。
    public let type: String
    public let titleId: String
    public let version: Int
    /// 版本号的显示（如 1.2.0）；没有为空。
    public let display: String
    public let size: Int64
    public let sha256: String
    /// 原件形态：空 = NSP / XCI（要密钥）；nup / dump / extract / loose 不加密，不要密钥。
    public let format: String

    public init(type: String, titleId: String = "", version: Int = 0, display: String = "", size: Int64 = 0, sha256: String = "", format: String = "") {
        self.type = type; self.titleId = titleId; self.version = version; self.display = display; self.size = size; self.sha256 = sha256; self.format = format
    }

    init?(catalog p: [String: Any]) {
        guard let type = p["type"] as? String else { return nil }
        self.init(type: type, titleId: p["titleId"] as? String ?? "", version: (p["version"] as? NSNumber)?.intValue ?? 0,
                  display: p["display"] as? String ?? "", size: (p["size"] as? NSNumber)?.int64Value ?? 0, sha256: p["sha256"] as? String ?? "",
                  format: p["format"] as? String ?? "")
    }
}

/// 游戏库里的一款（catalog 作业 result.games 的一项，只取界面要的字段）。
/// 下游深度方案（pack/downstream/schemes.json）：方案、能不能选与原因、确认页文案（中英）、玩家上次的选择（nil = 没选过；"" = 仍用原版）
public struct DownstreamOffer: Equatable {
    public struct Copy: Equatable { public let title: String; public let body: String; public let points: [String]; public let recommend: String; public let original: String }
    public let id: String
    public let name: String
    public let eligible: Bool
    public let reason: [String: String]
    public let copy: [String: Copy]
    public let choice: String?
    public init?(catalog d: [String: Any]) {
        guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
        self.id = id; self.name = name; self.eligible = d["eligible"] as? Bool ?? false
        self.reason = d["reason"] as? [String: String] ?? [:]
        var copy: [String: Copy] = [:]
        for (lang, v) in d["copy"] as? [String: [String: Any]] ?? [:] {
            copy[lang] = Copy(title: v["title"] as? String ?? "", body: v["body"] as? String ?? "", points: v["points"] as? [String] ?? [],
                              recommend: v["recommend"] as? String ?? "", original: v["original"] as? String ?? "")
        }
        self.copy = copy; self.choice = d["choice"] as? String
    }
    /// 按界面语言挑（zh-Hans → zh；没有就退回中文）
    public func text(_ language: String) -> Copy? { copy[language.hasPrefix("zh") ? "zh" : String(language.prefix(2))] ?? copy["zh"] }
    public func why(_ language: String) -> String { reason[language.hasPrefix("zh") ? "zh" : String(language.prefix(2))] ?? reason["zh"] ?? "" }
    /// 选了下游且条件满足（出包会走下游）
    public var chosen: Bool { eligible && !(choice ?? "").isEmpty }
}

public struct GameSummary: Identifiable, Equatable {
    public let id: String
    public let name: String
    /// 导入版本（catalog 的 display），不宣称为当前运行版本。
    public let display: String
    /// 封面文件路径（游戏库 games/<id>/cover.jpg）；没有为 nil。
    public let cover: String?
    /// 玩家改过名字 / 封面（可以恢复默认）
    public let customName: Bool
    public let customCover: Bool
    /// 运行文件已准备好、可以启动。
    public let ready: Bool
    public let needsPreparation: Bool
    public let compatibility: String
    public let missing: [String]
    /// 登记的原件（本体 / 更新 / DLC），出包页的游戏信息用。
    public let packages: [GamePackage]
    /// iPhone 包已经出好（IPA 和资源包都在）。
    public let iphoneReady: Bool
    /// 上次装到 iPhone 的时刻（秒）和是不是免费账号签的；没装过为 nil。
    public let iphoneInstalledAt: Double?
    public let iphoneFree: Bool
    /// 上次装的那台设备（设备记录键，UDID）：「续签」装回当初那台，不换别的（pack/jobs/layout.py install_record 的 deviceKey）
    public var iphoneInstallDevice: String? = nil
    /// 下游深度方案（pack/jobs/downstream.py describe）：这款有下游项目的专门移植时，导出 iPhone 前问玩家一次用哪套
    public var downstream: DownstreamOffer? = nil
    /// 只换宿主（pack/jobs/host_update.py）：none / current / swap / incompatible（要重新准备才能用上新版修复）/ failed
    public let hostUpdate: String
    /// 存放位置（游戏库结构 v3）：state = ok / offline（位置没连上）/ missing（文件夹找不到）/ none（还没出过包）
    public let location: GameLocation
    /// 手机上的 S2Arm 换过新宿主、游戏库留着上一版：可以「装回上一版」（installRestore 作业）
    public let iphoneRestorable: Bool
    /// 各部分大小（catalog 的 sizes；pack/jobs/sizes.py 在出包 / 清缓存等之后量好记下）
    public let sizes: GameSizes

    public init(id: String, name: String, display: String = "", cover: String? = nil, ready: Bool = false,
                needsPreparation: Bool = false, compatibility: String = "experimental", missing: [String] = [], packages: [GamePackage] = [],
                iphoneReady: Bool = false, iphoneInstalledAt: Double? = nil, iphoneFree: Bool = false, customName: Bool = false, customCover: Bool = false, hostUpdate: String = "none", location: GameLocation = GameLocation(), iphoneRestorable: Bool = false, sizes: GameSizes = GameSizes()) {
        self.customName = customName; self.customCover = customCover; self.hostUpdate = hostUpdate; self.location = location; self.iphoneRestorable = iphoneRestorable; self.sizes = sizes
        self.iphoneReady = iphoneReady; self.iphoneInstalledAt = iphoneInstalledAt; self.iphoneFree = iphoneFree
        self.id = id; self.name = name; self.display = display; self.cover = cover; self.ready = ready
        self.needsPreparation = needsPreparation; self.compatibility = compatibility; self.missing = missing; self.packages = packages
    }

    /// 从 catalog 的一项读；没有 id / 名字的、标了 hidden 的不要。
    public init?(catalog g: [String: Any]) {
        guard let id = g["id"] as? String, !id.isEmpty, let name = g["name"] as? String, g["hidden"] as? Bool != true else { return nil }
        let cover = (g["cover"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(id: id, name: name, display: g["display"] as? String ?? "", cover: cover, ready: g["ready"] as? Bool ?? false,
                  needsPreparation: g["needsPreparation"] as? Bool ?? false, compatibility: g["compatibility"] as? String ?? "experimental",
                  missing: g["missing"] as? [String] ?? [],
                  packages: (g["packages"] as? [[String: Any]] ?? []).compactMap(GamePackage.init(catalog:)),
                  iphoneReady: g["iphoneReady"] as? Bool ?? false,
                  iphoneInstalledAt: ((g["iphoneInstall"] as? [String: Any])?["at"] as? NSNumber)?.doubleValue,
                  iphoneFree: (g["iphoneInstall"] as? [String: Any])?["free"] as? Bool ?? false,
                  customName: g["customName"] as? Bool ?? false, customCover: g["customCover"] as? Bool ?? false,
                  hostUpdate: g["hostUpdate"] as? String ?? "none", location: GameLocation(catalog: g["location"] as? [String: Any] ?? [:]), iphoneRestorable: g["iphoneRestorable"] as? Bool ?? false,
                  sizes: GameSizes(catalog: g["sizes"] as? [String: Any] ?? [:]))
        self.iphoneInstallDevice = (g["iphoneInstall"] as? [String: Any])?["deviceKey"] as? String
        self.downstream = (g["downstream"] as? [String: Any]).flatMap(DownstreamOffer.init(catalog:))
    }

    /// 某类原件里版本最新的那个的显示版本（base / update）；没有这类为 nil。
    public func version(_ type: String) -> String? {
        packages.filter { $0.type == type }.max { $0.version < $1.version }.map { $0.display.isEmpty ? "v\($0.version)" : $0.display }
    }

    /// DLC 个数（按程序号去重）。
    public var dlcCount: Int { Set(packages.filter { $0.type == "dlc" }.map(\.titleId)).count }

    /// 原件总大小（同一个文件里的多项只算一次，同旧启动器 ExportGameCard）。
    public var totalBytes: Int64 {
        Dictionary(grouping: packages, by: \.sha256).values.compactMap(\.first).reduce(0) { $0 + $1.size }
    }

    /// 免费签名还剩几天（到期 = 0）；付费账号或没装过为 nil。
    public func iphoneDaysLeft(now: Date = Date()) -> Int? {
        guard iphoneFree, let at = iphoneInstalledAt else { return nil }
        return max(0, Int(((at + 7 * 86400 - now.timeIntervalSince1970) / 86400).rounded(.up)))
    }

    /// 出包要不要 prod.keys：只有加密原件（NSP / XCI）要，解包好的游戏和 NUP 不要。
    public var needsKeys: Bool { packages.contains { !["nup", "dump", "extract", "loose"].contains($0.format) } }

    /// 能不能直接 Play：运行文件在、且不需要重新准备（同旧启动器起局前提；不能时先 build 的 prepare）。
    public var playable: Bool { ready && !needsPreparation }

    /// 能不能准备 / 出包：不是不支持的款、文件齐（同旧启动器 Game.buildable）。
    public var buildable: Bool { compatibility != "unsupported" && missing.isEmpty }
}

/// 游戏库：交 catalog 作业，读结果。
public final class LibraryProvider {
    private let client: JobClient
    private let lock = NSLock()
    private var keys: Bool?
    private var updates: [PhoneUpdate] = []
    /// 上次读游戏库时 prod.keys 齐没齐（catalog 的 keys.ready）；还没读过为 nil。
    public var keysReady: Bool? { lock.withLock { keys } }
    /// 上次读游戏库时，壳比本版旧的手机（catalog 的 phoneUpdates，只按本机设备记录判）：游戏库右上角「更新 iPhone 上的 S2Arm」
    public var phoneUpdates: [PhoneUpdate] { lock.withLock { updates } }

    public init(client: JobClient) { self.client = client }

    private func remember(_ result: [String: Any]) {
        let ready = (result["keys"] as? [String: Any])?["ready"] as? Bool
        let phones = (result["phoneUpdates"] as? [[String: Any]] ?? []).map(PhoneUpdate.init(catalog:))
        lock.withLock { keys = ready; updates = phones }
    }

    private var snapshotFile: URL { client.environment.privateRoot.appendingPathComponent("library-snapshot.json") }

    /// 上一次读到的游戏列表：启动时先显示它，catalog 作业在后台跑完再替换。换了游戏库（libraryId 不符）或没读过时为 nil。
    public func lastKnownGames() -> [GameSummary]? {
        guard !client.environment.libraryId.isEmpty, let data = try? Data(contentsOf: snapshotFile),
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              saved["libraryId"] as? String == client.environment.libraryId,
              let result = saved["result"] as? [String: Any] else { return nil }
        remember(result)
        return Self.games(in: result)
    }

    private func saveSnapshot(_ result: [String: Any]) {
        let saved: [String: Any] = ["libraryId": client.environment.libraryId,
                                    "result": ["games": result["games"] ?? [], "keys": result["keys"] ?? [:]]]
        guard JSONSerialization.isValidJSONObject(saved), let data = try? JSONSerialization.data(withJSONObject: saved) else { return }
        try? data.write(to: snapshotFile, options: .atomic)
    }

    public static let noLibraryMessage = "还没有游戏库：请先在 S2Arm 启动器里选择游戏库并导入游戏。"

    /// 读一遍游戏库。没配游戏库时不起作业，直接回失败。
    /// startup：启动器这次打开后的第一次读（剃刀 H14）：作业层只在这一次清残留、判一天一次的任务目录清理；其余刷新只读。
    @discardableResult
    public func load(startup: Bool = false, _ completion: @escaping (Result<[GameSummary], JobClientError>) -> Void) -> JobHandle? {
        guard !client.environment.library.isEmpty else {
            completion(.failure(JobClientError(Self.noLibraryMessage)))
            return nil
        }
        do {
            return try client.start(operation: "catalog", extra: startup ? ["startup": true] : [:], onFinish: { outcome in
                guard outcome.state == .completed else {
                    completion(.failure(JobClientError(outcome.message.isEmpty ? JobOutcome.interruptedMessage : outcome.message)))
                    return
                }
                self.remember(outcome.result)
                self.saveSnapshot(outcome.result)
                completion(.success(Self.games(in: outcome.result)))
            })
        } catch let error as JobClientError {
            completion(.failure(error))
        } catch {
            completion(.failure(JobClientError(error.localizedDescription)))
        }
        return nil
    }

    /// 同 load，async（EngineProvider 用）：没配游戏库直接抛错，不起作业。
    public func games() async throws -> [GameSummary] {
        guard !client.environment.library.isEmpty else { throw JobClientError(Self.noLibraryMessage) }
        let result = try await client.perform("catalog").result
        remember(result)
        return Self.games(in: result)
    }

    /// 新玩家还没有游戏库：建在 ~/S2Arm（S2ArmPaths.defaultLibrary，同旧启动器 defaultLibraryURL），玩家不用选；放密钥、添加游戏前调用。已有游戏库不动。
    public func ensureLibrary(events: EventSink = .discard) async throws {
        guard client.environment.library.isEmpty else { return }
        let folder = S2ArmPaths.defaultLibrary(privateRoot: client.environment.privateRoot)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await change(to: folder, events: events)
    }

    /// 换游戏库（同旧启动器 chooseLibrary → setupLibrary）：setup 作业建好 / 认出这个文件夹（作业层拦不支持的盘格式、云盘同步目录、非空的生文件夹），
    /// 成了把 library / libraryId 写回 preferences.json，本进程之后的作业都用新库。没成抛错、什么都不改。
    @discardableResult
    /// accept：玩家在换库确认里同意过的参数（v0.3.1：library_in_cloud → acceptCloud、library_folder_not_empty → acceptForeign），逐次累积
    public func change(to folder: URL, moveFrom: String? = nil, accept: Set<String> = [], events: EventSink = .discard) async throws -> String {
        var extra: [String: Any] = ["library": folder.path, "libraryId": ""]
        if let moveFrom { extra["moveFrom"] = moveFrom }
        for key in accept { extra[key] = true }
        let r = try await client.perform("setup", extra: extra, events: events).result
        let library = r["library"] as? String ?? folder.path
        let libraryId = r["libraryId"] as? String ?? ""
        try JobEnvironment.saveLibrary(privateRoot: client.environment.privateRoot, library: library, libraryId: libraryId)
        client.environment.library = library
        client.environment.libraryId = libraryId
        return library
    }

    /// catalog 结果里的游戏（没 id / 名字、标了 hidden 的不要）。
    static func games(in result: [String: Any]) -> [GameSummary] {
        (result["games"] as? [[String: Any]] ?? []).compactMap(GameSummary.init(catalog:))
    }
}


/// 一款游戏在哪个存放位置（游戏库结构 v3；catalog 的 location 字段）。
public struct GameLocation: Equatable {
    public var state = "none"
    public var path = ""
    public var folder = ""
    public var volume = ""
    public init() {}
    public init(catalog l: [String: Any]) {
        state = l["state"] as? String ?? "none"; path = l["path"] as? String ?? ""; folder = l["folder"] as? String ?? ""; volume = l["volume"] as? String ?? ""
    }
    /// 这款自己文件夹里的文件（按 catalog 给的文件夹，英文名或游戏号命名都行；不按游戏号自己拼路径）。位置没连上 / 文件夹找不到 → nil
    public func file(_ name: String) -> URL? {
        state == "ok" && !folder.isEmpty ? URL(fileURLWithPath: folder).appendingPathComponent(name) : nil
    }
}

/// 一款的各部分大小（字节，catalog 的 sizes）：Mac 镜像、iPhone 镜像、存档、缓存（出包缓存 + 着色器缓存）、原件（多款共用的按款数均摊）。
/// measured = 量过（没量过时前四项是 0，界面显示「未统计」）。
public struct GameSizes: Equatable {
    public var imageMac: Int64 = 0
    public var imageIos: Int64 = 0
    public var saves: Int64 = 0
    public var cache: Int64 = 0
    public var sources: Int64 = 0
    public var measured = false
    public init() {}
    public init(imageMac: Int64, imageIos: Int64, saves: Int64, cache: Int64, sources: Int64, measured: Bool) {
        self.imageMac = imageMac; self.imageIos = imageIos; self.saves = saves; self.cache = cache; self.sources = sources; self.measured = measured
    }
    public init(catalog s: [String: Any]) {
        func n(_ k: String) -> Int64 { (s[k] as? NSNumber)?.int64Value ?? 0 }
        imageMac = n("imageMac"); imageIos = n("imageIos"); saves = n("saves"); cache = n("cache"); sources = n("sources")
        measured = s["measured"] as? Bool ?? false
    }
}

/// 一个存放位置（locations 作业）：出包页下拉框的一项。
public struct StorageLocation: Identifiable, Equatable {
    public let id: String
    public let path: String
    public let volume: String
    public let connected: Bool
    public let freeBytes: Int64?
    public let isDefault: Bool
    /// 这块盘会让出包多占空间的原因（#444，后端 libloc.slack_reason；只提示不拦）：cluster 大分配单元 / format 不能克隆；nil 没问题
    public let slack: LocationSlack?
    public init?(_ r: [String: Any]) {
        guard let id = r["id"] as? String, let path = r["path"] as? String else { return nil }
        self.id = id; self.path = path; volume = r["volume"] as? String ?? ""; connected = r["connected"] as? Bool ?? false
        freeBytes = (r["freeBytes"] as? NSNumber)?.int64Value; isDefault = r["default"] as? Bool ?? false
        slack = LocationSlack(r)
    }
}

/// 存放位置所在盘会让出包多占空间：原因（cluster / format）与分配单元字节数（提示里写「每个小文件至少占 N」）
public struct LocationSlack: Equatable {
    public let reason: String
    public let clusterBytes: Int64
    public init?(_ r: [String: Any]) {
        guard r["slackWarning"] as? Bool == true, let reason = r["slackReason"] as? String else { return nil }
        self.reason = reason; clusterBytes = (r["clusterBytes"] as? NSNumber)?.int64Value ?? 0
    }
}

/// 一台手机上的 S2Arm 壳比本版旧（catalog 的 phoneUpdates 一项，pack/jobs/install.py phone_updates）：
///   games = 这台手机上的各款，stale = 新壳认不得、要按新版重新出包的（[(游戏号, 名字)]）
public struct PhoneUpdate: Equatable, Sendable {
    public let device: String
    public let name: String
    public let games: [GameRef]
    public let stale: [GameRef]
    public struct GameRef: Equatable, Sendable { public let id: String; public let name: String }
    init(catalog u: [String: Any]) {
        func refs(_ k: String) -> [GameRef] {
            (u[k] as? [[String: Any]] ?? []).compactMap { g in (g["gameId"] as? String).map { GameRef(id: $0, name: g["name"] as? String ?? $0) } }
        }
        device = u["device"] as? String ?? ""; name = u["name"] as? String ?? ""; games = refs("games"); stale = refs("stale")
    }
}
