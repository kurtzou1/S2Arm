// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation

/// 0.6.0 通用壳（开关后面）iPhone 总控台用的「这台手机的全貌」（作业 phoneOverview，pack/jobs）：每台见过的手机、App 状态、每款在这台上的状态。
///   probe = false 只读设备记录（秒回）；true 才问 USB 上连着谁（online）。开关关着作业回 enabled = false → nil
public struct PhoneOverview: Equatable {
    public enum SignMode: String { case appleId, devCert, external }
    /// 手机上的 S2Arm 是谁装的（作业 installedBy）：启动器装的 / 别的工具（AltStore、SideStore…）装的；nil = 没装或判不出（旧作业不带这个键也是 nil）
    public enum InstalledBy: String { case launcher, external }
    public enum GameState: String { case latest, suggested, notPushed, needsData }
    /// 同一台手机上装着不止一个 S2Arm 时让玩家选的候选（作业 candidates，install.s2arm_candidates）：byThisLauncher = 这台电脑的启动器装的；
    ///   identityTeam = 这个 S2Arm 导入的签名证书的团队（没导入为 nil）
    public struct Candidate: Equatable {
        public let bundleId: String
        public let team: String
        public let byThisLauncher: Bool
        public let identityTeam: String?
        public init(bundleId: String, team: String, byThisLauncher: Bool, identityTeam: String?) {
            self.bundleId = bundleId; self.team = team; self.byThisLauncher = byThisLauncher; self.identityTeam = identityTeam
        }
        /// 导入的签名证书团队与 App 团队对得上（界面追加「已导入签名证书」）
        public var certImported: Bool { identityTeam.map { !$0.isEmpty && $0 == team } ?? false }
    }
    public struct Game: Equatable {
        public let gameId: String
        public let state: GameState
        public let reasons: [String]
        /// 电脑上这款的资源（game.img）还在不在：needsData / notPushed 的款，不在就要原件
        public let dataOnComputer: Bool?
        public init(gameId: String, state: GameState, reasons: [String], dataOnComputer: Bool?) {
            self.gameId = gameId; self.state = state; self.reasons = reasons; self.dataOnComputer = dataOnComputer
        }
    }
    /// 这台手机上的独立 App（一 App 一游戏，作业 apps，host_update._app_rows）：壳号是不是本版、签名与到期（同手机那行的口径）
    public struct App: Equatable {
        public let gameId: String
        public let bundleId: String
        public let shellCurrent: Bool
        public let signedAt: Date?
        public let expiresAtEstimate: Date?
        public init(gameId: String, bundleId: String, shellCurrent: Bool, signedAt: Date?, expiresAtEstimate: Date?) {
            self.gameId = gameId; self.bundleId = bundleId; self.shellCurrent = shellCurrent; self.signedAt = signedAt; self.expiresAtEstimate = expiresAtEstimate
        }
    }
    public struct Phone: Equatable {
        public let device: String
        public let name: String
        public let installed: Bool
        public let shellCurrent: Bool
        public let bundleId: String
        public let signedAt: Date?
        public let free: Bool
        /// 按苹果规则估的到期（免费 7 天、付费一年）；界面写「约」，准数以手机上 App 为准
        public let expiresAtEstimate: Date?
        /// 只有 probe 时才有：nil = 没问（没 probe），.some(nil) = 问了、没连
        public let online: String??
        public let lastSeen: Date?
        public let signMode: SignMode?
        public let games: [Game]
        public let installedBy: InstalledBy?
        /// 作业给的这台手机的按钮（别的工具装的才有：exportShellIpa / pushS2arm / exportS2arm / handOverIdentity，按此顺序）；没给 = 空
        public let actions: [String]
        /// 装着不止一个 S2Arm、玩家还没选（作业 needsChoice）：只出「选用哪个 S2Arm」
        public let needsChoice: Bool
        /// 装着不止一个时的全部候选（选没选过都带，选过的据此给「换一个」）；只有一个或没探测 = 空
        public let candidates: [Candidate]
        /// 这台上的独立 App（按游戏号排）；旧作业层不带 = 空
        public var apps: [App] = []
        /// 设备类型（作业 kind，0.6.4）：「iPhone」/「iPad」；读不到为 nil，界面写「设备」，不写死 iPhone
        public var kind: String? = nil
        /// 手机上的 S2Arm 导入了签名证书没有（作业 certImported）；作业不带为 nil，导出确认页再看候选里同包名那一个的 certImported
        public var certImported: Bool? = nil
        /// 这台的 S2Arm 有没有导入签名证书：作业直给的 > 候选里同包名那一个 > 不知道（nil）
        public var signCertImported: Bool? {
            certImported ?? candidates.first(where: { $0.bundleId == bundleId && !bundleId.isEmpty })?.certImported
        }
        public init(device: String, name: String, installed: Bool, shellCurrent: Bool, bundleId: String, signedAt: Date?, free: Bool,
                    expiresAtEstimate: Date?, online: String??, lastSeen: Date?, signMode: SignMode?, games: [Game],
                    installedBy: InstalledBy? = nil, actions: [String] = [], needsChoice: Bool = false, candidates: [Candidate] = []) {
            self.device = device; self.name = name; self.installed = installed; self.shellCurrent = shellCurrent; self.bundleId = bundleId
            self.signedAt = signedAt; self.free = free; self.expiresAtEstimate = expiresAtEstimate; self.online = online; self.lastSeen = lastSeen
            self.signMode = signMode; self.games = games; self.installedBy = installedBy; self.actions = actions
            self.needsChoice = needsChoice; self.candidates = candidates
        }
    }
    public let phones: [Phone]

    public init(phones: [Phone]) { self.phones = phones }

    /// 作业结果 → 总览；结果里没有 phones（作业层太旧）→ nil
    public init?(result r: [String: Any]) {
        guard r["phones"] is [Any] else { return nil }
        func date(_ v: Any?) -> Date? { (v as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
        phones = (r["phones"] as? [[String: Any]] ?? []).compactMap { p in
            guard let device = p["device"] as? String, !device.isEmpty else { return nil }
            let online: String?? = p.keys.contains("online") ? .some(p["online"] as? String) : nil
            let games: [Game] = (p["games"] as? [[String: Any]] ?? []).compactMap { g in
                guard let id = g["gameId"] as? String, let s = (g["state"] as? String).flatMap(GameState.init) else { return nil }
                return Game(gameId: id.uppercased(), state: s, reasons: g["reasons"] as? [String] ?? [], dataOnComputer: g["dataOnComputer"] as? Bool)
            }
            let candidates = Self.candidates(p["candidates"])
            let apps: [App] = (p["apps"] as? [[String: Any]] ?? []).compactMap { a in
                guard let id = a["gameId"] as? String, let bid = a["bundleId"] as? String else { return nil }
                return App(gameId: id.uppercased(), bundleId: bid, shellCurrent: a["shellCurrent"] as? Bool == true, signedAt: date(a["signedAt"]),
                           expiresAtEstimate: date(a["expiresAtEstimate"]))
            }
            var phone = Phone(device: device, name: p["name"] as? String ?? "", installed: p["installed"] as? Bool == true, shellCurrent: p["shellCurrent"] as? Bool == true,
                         bundleId: p["bundleId"] as? String ?? "", signedAt: date(p["signedAt"]), free: p["free"] as? Bool == true,
                         expiresAtEstimate: date(p["expiresAtEstimate"]), online: online, lastSeen: date(p["lastSeen"]),
                         signMode: (p["signMode"] as? String).flatMap(SignMode.init), games: games,
                         installedBy: (p["installedBy"] as? String).flatMap(InstalledBy.init), actions: p["actions"] as? [String] ?? [],
                         needsChoice: p["needsChoice"] as? Bool == true, candidates: candidates)
            phone.apps = apps
            phone.kind = (p["kind"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            phone.certImported = p["certImported"] as? Bool
            return phone
        }
    }

    /// 作业的候选数组（总览 candidates、推送失败 facts.candidates 同一形状）→ 候选；没有包名的丢掉
    public static func candidates(_ v: Any?) -> [Candidate] {
        (v as? [[String: Any]] ?? []).compactMap { c in
            guard let bid = c["bundleId"] as? String, !bid.isEmpty else { return nil }
            return Candidate(bundleId: bid, team: c["team"] as? String ?? "", byThisLauncher: c["byThisLauncher"] as? Bool == true,
                             identityTeam: (c["identityTeam"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    public static let choiceRequiredCode = "phone_app_choice_required"

    /// 推送（推单款 install、更新所选 pushSelected）失败「装着不止一个 S2Arm、还没选」时作业诊断带的机读事实 facts {device, candidates}
    ///   （install.owner_for_push；同 Windows PhoneOverview.ChoiceFacts）：失败页就地列出候选让玩家选，选好自动重推。不是这个码 / 没带候选 → nil
    public static func choiceFacts(_ diagnostics: [[String: Any]]) -> (device: String, candidates: [Candidate])? {
        for d in diagnostics where d["code"] as? String == choiceRequiredCode {
            guard let f = d["facts"] as? [String: Any], let device = f["device"] as? String, !device.isEmpty else { continue }
            let c = candidates(f["candidates"])
            if !c.isEmpty { return (device, c) }
        }
        return nil
    }
}
