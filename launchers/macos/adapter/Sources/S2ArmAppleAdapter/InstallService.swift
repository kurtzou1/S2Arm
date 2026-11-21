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
    /// 没好时启动器的本地动作（落点表唯一来源：共享规格 install_landing，BackendText.installLandingActions）；
    ///   好了、等前一步、不用人做的为 nil。清单按钮与控制口 /install-action 都按它派发
    public let action: String?
    /// 没好时要打开的官方网页（install_landing 里写 @url 的项，如证书设备不在描述文件里 → 苹果开发者网站设备页）
    public let url: String?

    public init(id: String, ok: Bool, waiting: Bool = false, title: String, detail: String = "", who: String = "human", action: String? = nil, url: String? = nil) {
        self.id = id; self.ok = ok; self.waiting = waiting; self.title = title; self.detail = detail; self.who = who; self.action = action; self.url = url
    }

    public init?(json i: [String: Any]) {
        guard let id = i["id"] as? String, let title = i["title"] as? String else { return nil }
        self.init(id: id, ok: i["ok"] as? Bool ?? false, waiting: i["waiting"] as? Bool ?? false, title: title,
                  detail: i["detail"] as? String ?? "", who: i["who"] as? String ?? "human", action: (i["action"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  url: (i["url"] as? String).flatMap { $0.hasPrefix("https://") ? $0 : nil })
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
    /// 分发 / ad hoc 描述文件（缺 get-task-allow）：照常导入、独立 App 能用；通用 S2Arm 里游戏打不开，界面给「改用 Apple ID 登录 / 复制给发放人的话」
    public let distribution: Bool
    public let warnings: [String]
    /// 描述文件缺权限时给证书发放人的一段话（作业层整句写好，界面翻译后一键复制，不在前端拼）；不缺为空
    public let requestText: String

    public init(result r: [String: Any]) {
        func s(_ k: String) -> String { r[k] as? String ?? "" }
        teamName = s("teamName"); teamId = s("teamId"); certName = s("certName"); certExpires = s("certExpires")
        profileName = s("profileName"); profileExpires = s("profileExpires"); bundleId = s("bundleId")
        wildcard = r["wildcard"] as? Bool ?? false; allDevices = r["allDevices"] as? Bool ?? false
        deviceCount = (r["deviceCount"] as? NSNumber)?.intValue ?? 0
        deviceListed = r["deviceListed"] as? Bool
        blocking = (r["blocking"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        distribution = r["distribution"] as? Bool ?? false
        warnings = (r["warnings"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        requestText = s("requestText")
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
    /// 导出模式（装法选了「导出，自己签名安装」）：没连手机，S2Arm.ipa + 各款 .img + 说明放进的文件夹（作业结果 exported / outputPath）；一键装为空
    public var exportFolder: String = ""
    /// 导出了几款、文件夹总字节数、没放进这次导出的款（要按新版重新出包，作业结果 skipped 是游戏名）
    public var exportGames: Int = 0
    public var exportBytes: Int64? = nil
    public var skipped: [String] = []
    /// 这次新写的 .img 文件名与沿用上次导出的款数（#1132：沿用的和上次逐字节相同，手机上已有就不用再拷；作业结果 fresh / reused）
    public var exportFresh: [String] = []
    public var exportReused: Int = 0
    /// 只新写点的那款时，别的款里这次没写 .img 的（游戏名，作业结果 unwritten）：手机上已有照常能玩，没有要点那款再导出
    public var exportUnwritten: [String] = []
    /// 签名证书名（作业结果 trustName，如「Apple Development: someone@example.com (ABCDE12345)」）：iPhone「VPN 与设备管理」里要点「信任」的那一项；读不到为空
    public var trustName: String = ""
    /// 独立 App（作业结果 layout = standalone，pack/jobs/install.py put_app / export_app）：主屏名、游戏文件夹里的 ipa / README、到期、下一步；通用壳为 nil
    public var app: StandaloneApp? = nil
}

/// 独立 App（一 App 一游戏）这次的产物与事实（作业结果原样读，不猜；失败结果的 appInstalled 同形）。成功页 A（直装）/ B（导出）按它画
public struct StandaloneApp: Equatable {
    public var name = "", version = "", gameFolder = "", ipaPath = "", readmePath = "", signMode = ""
    public var ipaBytes: Int64? = nil
    public var nextSteps: [String] = []
    /// 到期时刻；known = 读到的真值（签好的包 / 证书描述文件），否则按苹果规则估
    public var expiresAt: Date? = nil
    public var expiresKnown = false
    /// 导出（成功页 B）：游戏包、资源本体（linked = 硬链接进了游戏文件夹；否则 resourcePath 是游戏库里的原位置）、签名
    public var exported = false
    public var s2armPath = "", resourcePath = ""
    public var s2armBytes: Int64? = nil
    public var resourceBytes: Int64? = nil
    public var resourceLinked = false
    public var signedCert = ""
    public init() {}
    public init(_ r: [String: Any]) {
        name = r["appName"] as? String ?? ""; version = r["appVersion"] as? String ?? ""; gameFolder = r["gameFolder"] as? String ?? ""
        ipaPath = r["ipaPath"] as? String ?? ""; readmePath = r["readmePath"] as? String ?? ""; signMode = r["signMode"] as? String ?? ""
        ipaBytes = (r["ipaBytes"] as? NSNumber)?.int64Value; nextSteps = r["nextSteps"] as? [String] ?? []
        expiresAt = (r["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }; expiresKnown = r["expiresKnown"] as? Bool ?? false
        exported = r["exported"] as? Bool ?? false; s2armPath = r["s2armPath"] as? String ?? ""; resourcePath = r["resourcePath"] as? String ?? ""
        s2armBytes = (r["s2armBytes"] as? NSNumber)?.int64Value; resourceBytes = (r["resourceBytes"] as? NSNumber)?.int64Value; resourceLinked = r["resourceLinked"] as? Bool ?? false
        let signed = r["signedWith"] as? [String: Any] ?? [:]
        signedCert = signed["mode"] as? String == "devCert" ? (signed["name"] as? String ?? "") : ""
    }
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
    /// mode = "export"：游戏库「导出自签包」——不连手机、不签名，出未签名 S2Arm.ipa 和各款 .img 到文件夹（11-15 起导出只看这次请求）
    /// widget = false：玩家在设置里关了「装到 iPhone 时带主屏小组件」，作业层不带小组件扩展（不传 = 带）
    /// cloudSaves：玩家选的云存档文件夹（没开 = nil）。覆盖装前备份手机存档做不成时，作业层看这款在里面有没有快照：有就照装（覆盖装 App 不碰 iCloud 里那份）
    public func install(gameId: String, teamId: String? = nil, device: String? = nil, acceptDropped: Bool = false, accept: Set<String> = [], mode: String? = nil,
                        widget: Bool = true, cloudSaves: String? = nil, events: EventSink = .discard) async throws -> InstallResult {
        var extra: [String: Any] = ["gameId": gameId]
        if !widget { extra["widget"] = false }
        if let cloudSaves, !cloudSaves.isEmpty { extra["cloudSavesFolder"] = cloudSaves }
        if let mode { extra["mode"] = mode }
        if acceptDropped { extra["acceptDropped"] = true }
        for key in accept { extra[key] = true }   // 玩家在结局页确认过的（acceptDropped / acceptNoBackup / acceptStale，作业层按码认）
        if let teamId, !teamId.isEmpty { extra["teamId"] = teamId }
        if let device, !device.isEmpty { extra["device"] = device }
        let r = try await client.perform("install", extra: extra, events: events).result
        return InstallResult(device: r["device"] as? String ?? "", deviceKind: r["deviceKind"] as? String ?? "", deviceName: r["deviceName"] as? String ?? "",
                             packFiles: (r["packFiles"] as? NSNumber)?.intValue, outputPath: r["outputPath"] as? String, packBytes: (r["packBytes"] as? NSNumber)?.int64Value,
                             openToFinish: r["openToFinish"] as? Bool ?? false,
                             exportFolder: r["exported"] as? Bool == true ? ((r["s2armPath"] as? String).map { ($0 as NSString).deletingLastPathComponent } ?? r["outputPath"] as? String ?? "") : "",
                             exportGames: r["s2armPath"] is String ? 1 : (r["games"] as? [Any])?.count ?? 0,
                             exportBytes: (r["s2armBytes"] as? NSNumber)?.int64Value ?? (r["exportBytes"] as? NSNumber)?.int64Value,
                             skipped: r["skipped"] as? [String] ?? [],
                             exportFresh: r["fresh"] as? [String] ?? [], exportReused: (r["reused"] as? NSNumber)?.intValue ?? 0,
                             exportUnwritten: r["unwritten"] as? [String] ?? [],
                             trustName: r["trustName"] as? String ?? "",
                             app: r["layout"] as? String == "standalone" ? StandaloneApp(r) : nil)
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

    /// 出法（作业 layoutSet）：layout = shell / standalone / nil（nil = 撤掉选择、回到缺省）；gameId 给了只管这一款 → 结果里的 freeLimit（不用自己的证书选独立 App 时的苹果限制提示，只提示）
    public func layoutSet(_ layout: String?, gameId: String? = nil) async throws -> String {
        var extra: [String: Any] = [:]   // 不带 layout = 撤掉选择（作业层 c.r.get("layout") 为空）
        if let layout { extra["layout"] = layout }
        if let gameId, !gameId.isEmpty { extra["gameId"] = gameId }
        return try await client.perform("layoutSet", extra: extra).result["freeLimit"] as? String ?? ""
    }

    /// 签名方式三选一（作业 signModeSet：appleId / devCert / external）→ 生效后的选择
    public func signModeSet(_ mode: String) async throws -> String {
        try await client.perform("signModeSet", extra: ["mode": mode]).result["signMode"] as? String ?? mode
    }

    /// 出包装机用开发者证书（true）还是 Apple ID（false）。
    public func devCertUse(_ active: Bool) async throws {
        _ = try await client.perform("devCert", extra: ["action": "use", "active": active])
    }

    /// 删掉本机存的证书、描述文件和钥匙串里的密码（回到 Apple ID 签名）。
    public func devCertDelete() async throws {
        _ = try await client.perform("devCert", extra: ["action": "delete"])
    }

    // ---- Apple ID 登录（0.6.0 Mac：随包 plumesign 自己登录，pack/jobs/apple_login.py）----

    /// 登录：密码只经环境变量给这一次作业（S2A_APPLE_PASSWORD），不进请求文件、不进日志。
    ///   要两步验证码时作业发 stageKey = appleLogin.needCode 的事件（AppleLoginPrompt(event:) 认），界面拿到码后调 appleLoginCode 写进去；
    ///   「没收到？再发一次」= 取消这次（外层 Task 取消）再调一次。成功回账号；失败抛 JobFailure（码见作业层文件头）
    public func appleLogin(account: String, password: String, events: EventSink = .discard) async throws -> AppleAccount {
        AppleAccount(result: try await client.perform("appleLogin", extra: ["account": account], secrets: [Self.applePasswordEnv: password], events: events).result)
    }

    /// 当前登录的账号（没登录 → account 为空）
    public func appleAccount() async throws -> AppleAccount {
        AppleAccount(result: try await client.perform("appleAccount").result)
    }

    /// 把验证码（6 位数字）或 sms（改用短信接收）交给在等的登录作业：写 <私有目录>/login/<作业号>.code（作业读到即删）。
    ///   先写临时文件再改名，作业不会读到半截；目录与文件只归当前用户
    public func appleLoginCode(_ code: String, taskId: String) throws {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^\d{6}$"#, options: .regularExpression) != nil || text.lowercased() == "sms" else {
            throw JobClientError("验证码是 6 位数字。")
        }
        guard !taskId.isEmpty, !taskId.contains("/") else { throw JobClientError("登录作业还没开始。") }
        let dir = Self.appleLoginDir(privateRoot: client.environment.privateRoot)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent("." + taskId + ".code.tmp")
        guard fm.createFile(atPath: tmp.path, contents: Data(text.lowercased().utf8), attributes: [.posixPermissions: 0o600]) else {
            throw JobClientError("验证码没能交给登录作业：S2Arm 的数据目录写不进去，检查磁盘空间和权限后再试。")
        }
        let dest = dir.appendingPathComponent(taskId + ".code")
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
    }

    public static let applePasswordEnv = "S2A_APPLE_PASSWORD"
    /// 作业层 apple_login._code_file 的目录：<私有目录>/login
    public static func appleLoginDir(privateRoot: URL) -> URL { privateRoot.appendingPathComponent("login", isDirectory: true) }

    /// 生成给「没有签名团队」玩家用的 Xcode 引导项目，返回项目路径。
    public func signingProject() async throws -> String {
        try await client.perform("signingProject", extra: [:], events: .discard).result["path"] as? String ?? ""
    }

    /// 签名身份（installMode 作业只读；11-15 起导出不再是装法，旧版的装法设置由作业层迁移删掉）
    public func installMode() async throws -> InstallModeInfo {
        InstallModeInfo(result: try await client.perform("installMode").result)
    }

    /// 更新 iPhone 上的 S2Arm（installUpdate 作业，install.update_phone）：本版壳 + 已有程序模块，只装 App；
    ///   有要重新出包的款且没 acceptStale → 作业以 container_stale 失败（界面先问玩家）
    ///   device：连着多台时装到哪台（同 install；不给 = 只连着一台）
    /// acceptDropped：同 install——玩家已确认手机上只在别的电脑装过的游戏这次带不上（作业层 container_would_drop）
    /// mode：这次按「一键装到 iPhone」（install）/「导出自己签名安装」（export）走，nil = 按设置里的装法；sgradeUpgrade：「S 级优化升级」页发起，壳已是本版也重组装上
    /// cloudSaves：同 install
    public func updatePhone(acceptStale: Bool = false, acceptDropped: Bool = false, accept: Set<String> = [], mode: String? = nil, sgradeUpgrade: Bool = false, device: String? = nil,
                            widget: Bool = true, cloudSaves: String? = nil, events: EventSink = .discard) async throws -> [String: Any] {
        var extra: [String: Any] = acceptStale ? ["acceptStale": true] : [:]
        if !widget { extra["widget"] = false }
        if let cloudSaves, !cloudSaves.isEmpty { extra["cloudSavesFolder"] = cloudSaves }
        if acceptDropped { extra["acceptDropped"] = true }
        for key in accept { extra[key] = true }
        if let device { extra["device"] = device }
        if let mode { extra["mode"] = mode }
        if sgradeUpgrade { extra["sgradeUpgrade"] = true }
        return try await client.perform("installUpdate", extra: extra, events: events).result
    }

    /// 把这台电脑的签名身份交给手机上的 S2Arm（phoneIdentity 作业，install.phone_identity）：别的工具（AltStore / SideStore / 证书 App）装的 S2Arm 团队对得上也交。
    ///   device：交给哪台（不给 = 只连着一台）；force：交过了也重交。交过了且没 force → delivered = false
    public func phoneIdentity(device: String? = nil, force: Bool = false, events: EventSink = .discard) async throws -> PhoneIdentityResult {
        var extra: [String: Any] = force ? ["force": true] : [:]
        if let device, !device.isEmpty { extra["device"] = device }
        return PhoneIdentityResult(result: try await client.perform("phoneIdentity", extra: extra, events: events).result)
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

/// phoneIdentity 作业的结果：delivered = 这次真交了（false = 手机上已有这份）；certSha1 / team = 交的那份身份；source = 身份来源；device / bundleId = 交给的那台、那个 App
public struct PhoneIdentityResult: Equatable, Sendable {
    public let delivered: Bool
    public let certSha1: String
    public let team: String
    public let source: String
    public let device: String
    public let bundleId: String
    init(result r: [String: Any]) {
        delivered = r["delivered"] as? Bool ?? false
        certSha1 = r["certSha1"] as? String ?? ""; team = r["team"] as? String ?? ""; source = r["source"] as? String ?? ""
        device = r["device"] as? String ?? ""; bundleId = r["bundleId"] as? String ?? ""
    }
}

/// 签名身份（installMode 作业）：signMode = devcert（我的开发者证书）/ appleId；exportAvailable = 导出作业在不在；
///   signChoice = 玩家选的签名方式三选一（appleId / devCert / external = 我自己用 AltStore / SideStore 签，自签走查结构 6）
///   出法（0.6.3）：layout = 缺省现在按哪种推（shell 通用 S2Arm / standalone 独立 App，一 App 一游戏）；layoutDefault = 玩家选过的缺省（nil = 没选、按证书自动）；
///   layoutGames = 按款选过的 {游戏号: 出法}；distribution = 在用的是分发 / ad hoc 证书（通用 S2Arm 里游戏打不开，自动缺省独立 App）
public struct InstallModeInfo: Equatable, Sendable {
    public let exportAvailable: Bool
    public let signMode: String
    public let signChoice: String
    public var layout: String = "shell"
    public var layoutDefault: String? = nil
    public var layoutGames: [String: String] = [:]
    public var distribution: Bool = false
    /// 选独立 App 时按签名方式给的一句提示的码（作业层 install.standalone_hint：appleId / wildcard / external；nil = 不提示）→ 文案 install.layout.hint.<码>
    public var standaloneHint: String? = nil
    /// 按签名带不带调试权限推荐的出法（作业层 install.layout_recommend）：standalone / shell / nil（识别不了）；依据 distribution / devCertDebug / appleId / external / unknown
    public var recommend: String? = nil
    public var recommendWhy: String = "unknown"
    public init(exportAvailable: Bool = false, signMode: String = "appleId", signChoice: String = "appleId") {
        self.exportAvailable = exportAvailable; self.signMode = signMode; self.signChoice = signChoice
    }
    init(result r: [String: Any]) {
        self.init(exportAvailable: r["exportAvailable"] as? Bool ?? false, signMode: r["signMode"] as? String ?? "appleId",
                  signChoice: r["signChoice"] as? String ?? "appleId")
        let choice = r["layoutChoice"] as? [String: Any] ?? [:]
        layout = r["layout"] as? String ?? "shell"
        layoutDefault = choice["default"] as? String
        layoutGames = (choice["games"] as? [String: String] ?? [:]).reduce(into: [:]) { $0[$1.key.uppercased()] = $1.value }
        distribution = r["distribution"] as? Bool ?? false
        standaloneHint = r["standaloneHint"] as? String
        recommend = r["recommend"] as? String
        recommendWhy = r["recommendWhy"] as? String ?? "unknown"
    }
    /// 这款按哪种出法推：按款选过的 > 玩家选过的缺省 > 自动（作业层 install.chosen_layout 同序）
    public func layout(for gameId: String) -> String { layoutGames[gameId.uppercased()] ?? layout }
}

/// Apple ID 登录结果 / 当前账号（appleLogin / appleAccount 作业）：account 为空 = 没登录；enabled = false = 这台不用 Apple ID 登录（Windows / 证书模式）
public struct AppleAccount: Equatable, Sendable {
    public let account: String
    public let team: String
    public let teamName: String
    public let enabled: Bool
    public var signedIn: Bool { !account.isEmpty }
    public init(account: String = "", team: String = "", teamName: String = "", enabled: Bool = true) {
        self.account = account; self.team = team; self.teamName = teamName; self.enabled = enabled
    }
    init(result r: [String: Any]) {
        self.init(account: r["account"] as? String ?? "", team: r["team"] as? String ?? "", teamName: r["teamName"] as? String ?? "",
                  enabled: r["enabled"] as? Bool ?? true)
    }
}

/// 登录作业在等验证码（事件 stageKey = appleLogin.needCode）：taskId = 写验证码文件用的作业号；canSms = 能改用短信接收；sms = 这次是短信方式
public struct AppleLoginPrompt: Equatable, Sendable {
    public static let stageKey = "appleLogin.needCode"
    public let taskId: String
    public let canSms: Bool
    public let sms: Bool
    public init(taskId: String, canSms: Bool = false, sms: Bool = false) { self.taskId = taskId; self.canSms = canSms; self.sms = sms }
    /// 只认作业层发的那条 progress（带 canSms）；同阶段的 stage 事件不算（canSms / sms 只在 progress 上）
    public init?(event e: EngineEvent) {
        guard e.fields["stageKey"] as? String == Self.stageKey, e.ev == "progress", e.fields["canSms"] != nil,
              let task = e.fields["taskId"] as? String, !task.isEmpty else { return nil }
        self.init(taskId: task, canSms: e.fields["canSms"] as? Bool ?? false, sms: e.fields["sms"] as? Bool ?? false)
    }
}
