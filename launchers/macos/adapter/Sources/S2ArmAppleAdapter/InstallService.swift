import Foundation

/// 装机前清单的一项（installCheck 作业，pack/jobs/install.py readiness）。
public struct InstallItem: Identifiable, Equatable {
    public let id: String
    public let ok: Bool
    /// 前一项没好，这一项先不判（不给说明）。
    public let waiting: Bool
    public let title: String
    public let detail: String
    /// human = 只能玩家本人做；app = 启动器自己能做（如先做 iPhone 版）。
    public let who: String

    public init(id: String, ok: Bool, waiting: Bool = false, title: String, detail: String = "", who: String = "human") {
        self.id = id; self.ok = ok; self.waiting = waiting; self.title = title; self.detail = detail; self.who = who
    }

    public init?(json i: [String: Any]) {
        guard let id = i["id"] as? String, let title = i["title"] as? String else { return nil }
        self.init(id: id, ok: i["ok"] as? Bool ?? false, waiting: i["waiting"] as? Bool ?? false, title: title,
                  detail: i["detail"] as? String ?? "", who: i["who"] as? String ?? "human")
    }
}

/// 装机前清单：ready 由作业层判定（只有 iPhone 版没做好才挡），其余项只提示。
public struct InstallReadiness: Equatable {
    public let items: [InstallItem]
    public let ready: Bool
    /// 连着的设备名（只连一台时）。
    public let device: String
    /// 本机签名团队名。
    public let account: String
    /// 这款最新的 .ipa；还没做好 iPhone 版时为空。
    public let ipaPath: String
    /// 诊断用：Xcode 版本和账号、团队、证书的数量，不含账号和团队名。
    public let signing: String

    public init(items: [InstallItem], ready: Bool, device: String = "", account: String = "", ipaPath: String = "", signing: String = "") {
        self.items = items; self.ready = ready; self.device = device; self.account = account; self.ipaPath = ipaPath; self.signing = signing
    }

    public init(result r: [String: Any]) {
        let items = (r["items"] as? [[String: Any]] ?? []).compactMap(InstallItem.init(json:))
        self.init(items: items, ready: r["ready"] as? Bool ?? false,
                  device: r["device"] as? String ?? "", account: r["account"] as? String ?? "", ipaPath: r["ipaPath"] as? String ?? "", signing: r["signing"] as? String ?? "")
    }
}

/// 开发者证书体检（devCert 作业，pack/jobs/devcert.py inspect）：问题只提示、不挡；blocking 非空 = 根本签不了。
public struct DevCertInfo: Equatable {
    public let teamName, teamId, certName, certExpires, profileName, profileExpires, bundleId: String
    public let wildcard, allDevices: Bool
    public let deviceCount: Int
    /// 连着的手机在不在设备列表：nil = 没连手机 / 不知道。
    public let deviceListed: Bool?
    public let blocking: [String]
    public let warnings: [String]

    public init(result r: [String: Any]) {
        func s(_ k: String) -> String { r[k] as? String ?? "" }
        teamName = s("teamName"); teamId = s("teamId"); certName = s("certName"); certExpires = s("certExpires")
        profileName = s("profileName"); profileExpires = s("profileExpires"); bundleId = s("bundleId")
        wildcard = r["wildcard"] as? Bool ?? false; allDevices = r["allDevices"] as? Bool ?? false
        deviceCount = (r["deviceCount"] as? NSNumber)?.intValue ?? 0
        deviceListed = r["deviceListed"] as? Bool
        blocking = (r["blocking"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        warnings = (r["warnings"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    }
}

/// 开发者证书现况：导入过没有、出包装机用不用它、体检结果。
public struct DevCertStatus: Equatable {
    public let imported: Bool
    public let active: Bool
    public let cert: DevCertInfo?
    public init(imported: Bool, active: Bool, cert: DevCertInfo?) { self.imported = imported; self.active = active; self.cert = cert }
    public init(result r: [String: Any]) {
        self.init(imported: r["imported"] as? Bool ?? false, active: r["active"] as? Bool ?? false, cert: (r["cert"] as? [String: Any]).map(DevCertInfo.init(result:)))
    }
}

/// 装好的结果。
public struct InstallResult: Equatable {
    public let device: String
    /// 实际装上的那台：类型「iPhone」/「iPad」与设备名（完成页、顶部胶囊写这个，不写死 iPhone；Windows 拿不到设备名时为空）
    public var deviceKind: String = ""
    public var deviceName: String = ""
    /// 推到手机上的资源包文件数（没推为 nil）。
    public let packFiles: Int?
    public let outputPath: String?
    /// 这次实际推到手机上的资源包字节数（作业结果 packBytes；0 = 一个都没推）
    public var packBytes: Int64? = nil
    /// 这次推的全是单一 IMG：已传到手机、打开 S2Arm 会自动完成安装（作业结果 openToFinish）
    public var openToFinish: Bool = false
}

/// 从手机删一款的结果（installRemove 作业，pack/jobs/install.py remove_from_phone）。
public struct RemoveResult: Equatable {
    /// 删除的游戏号。
    public let removed: String
    /// 手机上 S2Arm 里还剩的游戏号列表。
    public let games: [String]
    /// 本机备份的存档路径（为空表示没有存档或备份失败）。
    public let saveBackup: String
    /// 是否成功删除了手机上这款的文档数据。
    public let dataRemoved: Bool

    public init(removed: String, games: [String], saveBackup: String, dataRemoved: Bool) {
        self.removed = removed; self.games = games; self.saveBackup = saveBackup; self.dataRemoved = dataRemoved
    }

    public init(result r: [String: Any]) {
        self.init(removed: r["removed"] as? String ?? "",
                  games: r["games"] as? [String] ?? [],
                  saveBackup: r["saveBackup"] as? String ?? "",
                  dataRemoved: r["dataRemoved"] as? Bool ?? false)
    }
}

/// 装到 iPhone（10-26 维护者：Xcode 做主路）：用玩家在 Xcode 登录的 Apple ID 重签自签 IPA、数据线装上、拷资源包并逐文件核对（pack/jobs/install.py）。
public final class InstallService {
    private let client: JobClient
    public init(client: JobClient) { self.client = client }

    /// 装机前清单。只读：不申请描述文件、不签名、不碰设备上的 App。
    /// device：玩家选的那台（清单只看它、每次现查；不给时作业不替玩家挑，「已连上」那项不打勾）
    public func readiness(gameId: String, device: String? = nil) async throws -> InstallReadiness {
        var extra: [String: Any] = ["gameId": gameId]
        if let device, !device.isEmpty { extra["device"] = device }
        return InstallReadiness(result: try await client.perform("installCheck", extra: extra).result)
    }

    /// 装。
    /// device：要装的那台（UDID / 设备名），必须给：作业层不替玩家挑，不给即报 device_required（pack/jobs/install.py phone）
    /// acceptDropped：玩家已确认「手机上只在别的电脑装过的游戏这次带不上」（作业层 container_would_drop 之后再点）
    public func install(gameId: String, teamId: String? = nil, device: String? = nil, acceptDropped: Bool = false, accept: Set<String> = [], events: EventSink = .discard) async throws -> InstallResult {
        var extra: [String: Any] = ["gameId": gameId]
        if acceptDropped { extra["acceptDropped"] = true }
        for key in accept { extra[key] = true }   // 玩家在结局页确认过的（acceptDropped / acceptNoBackup / acceptStale，作业层按码认）
        if let teamId, !teamId.isEmpty { extra["teamId"] = teamId }
        if let device, !device.isEmpty { extra["device"] = device }
        let r = try await client.perform("install", extra: extra, events: events).result
        return InstallResult(device: r["device"] as? String ?? "", deviceKind: r["deviceKind"] as? String ?? "", deviceName: r["deviceName"] as? String ?? "",
                             packFiles: (r["packFiles"] as? NSNumber)?.intValue, outputPath: r["outputPath"] as? String, packBytes: (r["packBytes"] as? NSNumber)?.int64Value,
                             openToFinish: r["openToFinish"] as? Bool ?? false)
    }

    // ---- 开发者证书（v0.2.4，pack/jobs/devcert.py）----

    /// 现况 + 体检；device = 连着的手机 UDID（判在不在设备列表），不给就不判。
    public func devCertStatus(device: String? = nil) async throws -> DevCertStatus {
        var extra: [String: Any] = ["action": "status"]
        if let device, !device.isEmpty { extra["device"] = device }
        return DevCertStatus(result: try await client.perform("devCert", extra: extra).result)
    }

    /// 导入 .p12 + .mobileprovision；密码只经环境变量给这一次作业（S2A_DEVCERT_PASSWORD），不写进请求文件。导入成功即切到证书签名。
    public func devCertImport(p12: String, profile: String, password: String, device: String? = nil) async throws -> DevCertInfo {
        var extra: [String: Any] = ["action": "import", "p12Path": p12, "profilePath": profile]
        if let device, !device.isEmpty { extra["device"] = device }
        return DevCertInfo(result: try await client.perform("devCert", extra: extra, secrets: ["S2A_DEVCERT_PASSWORD": password]).result)
    }

    /// 出包装机用开发者证书（true）还是 Apple ID（false）。
    public func devCertUse(_ active: Bool) async throws {
        _ = try await client.perform("devCert", extra: ["action": "use", "active": active])
    }

    /// 删掉本机存的证书、描述文件和钥匙串里的密码（回到 Apple ID 签名）。
    public func devCertDelete() async throws {
        _ = try await client.perform("devCert", extra: ["action": "delete"])
    }

    /// 生成给「没有签名团队」玩家用的 Xcode 引导项目，返回项目路径。
    public func signingProject() async throws -> String {
        try await client.perform("signingProject", extra: [:], events: .discard).result["path"] as? String ?? ""
    }

    /// 装到 iPhone 的方式（installMode 作业，pack/jobs/install.py install_mode_job）：mode 给了就改，返回现况
    public func installMode(set mode: String? = nil) async throws -> InstallModeInfo {
        InstallModeInfo(result: try await client.perform("installMode", extra: mode.map { ["mode": $0] } ?? [:], events: .discard).result)
    }

    /// 更新 iPhone 上的 S2Arm（installUpdate 作业，install.update_phone）：本版壳 + 已有程序模块，只装 App；
    ///   有要重新出包的款且没 acceptStale → 作业以 container_stale 失败（界面先问玩家）
    ///   device：连着多台时装到哪台（同 install；不给 = 只连着一台）
    /// acceptDropped：同 install——玩家已确认手机上只在别的电脑装过的游戏这次带不上（作业层 container_would_drop）
    public func updatePhone(acceptStale: Bool = false, acceptDropped: Bool = false, accept: Set<String> = [], device: String? = nil, events: EventSink = .discard) async throws -> [String: Any] {
        var extra: [String: Any] = acceptStale ? ["acceptStale": true] : [:]
        if acceptDropped { extra["acceptDropped"] = true }
        for key in accept { extra[key] = true }
        if let device { extra["device"] = device }
        return try await client.perform("installUpdate", extra: extra, events: events).result
    }

    /// 装回只换宿主前的那一版手机 S2Arm（installRestore 作业，pack/jobs/install.py restore_previous）。
    public func restorePrevious(device: String? = nil, events: EventSink = .discard) async throws {
        _ = try await client.perform("installRestore", extra: device.map { ["device": $0] } ?? [:], events: events)
    }

    /// 从手机容器删一款（installRemove 作业）。
    /// accept：同 install——玩家在结局页确认过的参数（删前没能备份存档 save_backup_failed → acceptNoBackup 等）
    public func remove(gameId: String, acceptDropped: Bool = false, accept: Set<String> = [], device: String? = nil, events: EventSink = .discard) async throws -> RemoveResult {
        var extra: [String: Any] = ["gameId": gameId]
        if let device, !device.isEmpty { extra["device"] = device }
        if acceptDropped { extra["acceptDropped"] = true }
        for key in accept { extra[key] = true }
        let r = try await client.perform("installRemove", extra: extra, events: events).result
        return RemoveResult(result: r)
    }
}

/// 装到 iPhone 的方式：device = 一键装到 iPhone（启动器签名并装），export = 导出、自己签名安装；导出作业合入前 exportAvailable 为 false（界面置灰）
public struct InstallModeInfo: Equatable, Sendable {
    public let mode: String
    public let exportAvailable: Bool
    public let signMode: String
    public init(mode: String = "device", exportAvailable: Bool = false, signMode: String = "appleId") {
        self.mode = mode; self.exportAvailable = exportAvailable; self.signMode = signMode
    }
    init(result r: [String: Any]) {
        self.init(mode: r["mode"] as? String == "export" ? "export" : "device", exportAvailable: r["exportAvailable"] as? Bool ?? false,
                  signMode: r["signMode"] as? String ?? "appleId")
    }
}
