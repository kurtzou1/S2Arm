import CryptoKit
import Foundation

/// 本地玩家（#623，维护者 11-11）：iPhone / iPad 外壳（shell S2ArmShellHost）和 Mac 启动器共用这一份（放在存档共享包里：玩家就是「这是谁的存档」），不依赖界面。
///   一台设备几个人轮流玩，游戏库顶部选「谁在玩」，同一款游戏的存档跟着玩家走（同 Switch 选用户），离线、游戏只装一次。
///   存在 App 偏好（按本机，不在游戏数据目录里，删游戏不丢）：S2ALocalPlayers = [{uid, name, folder}]（第一项是第一个玩家），S2ALocalPlayer = 当前玩家的 uid。
///   起局时 iOS 宿主 ios/settings.m（s2a_ios_local_player）读这两项、Mac 启动器把当前玩家放进 launch 请求（pack/jobs/build.py runtime_env），
///   给服务层 S2A_PLAYER_USER / S2A_PLAYER_NAME 和这个玩家的存档位置 S2A_SAVE_FOLDER（services/S2A.Services/LocalPlayer.cs）。没建过玩家时什么都不存，走旧行为。
///   - 第一个玩家：uid 空串 = 这款游戏原来的用户（升级前那份进度，升级后不选任何东西照常接着玩），存档位置仍是 SaveData；不能删
///   - 其余玩家：uid = 建的时候按名字算的 32 位十六进制（SHA-256 前 16 字节），之后改名不变；同名玩家在另一台设备上算出同一个用户号，
///     iCloud / 备份恢复过去还是她的存档；删掉再用同一个名字建回来，存档也回来（删玩家不删存档）。存档位置 = SaveData-<建时的名字>
public struct LocalPlayer: Equatable, Identifiable, Sendable {
    /// 空串 = 第一个玩家
    public var uid: String
    /// 玩家起的名字；第一个玩家没改过名时为空（显示「玩家 1」）
    public var name: String
    /// 本款文档根下这个玩家的存档位置文件夹名
    public var folder: String
    public var id: String { uid }
    public var isFirst: Bool { uid.isEmpty }
    public init(uid: String, name: String, folder: String) { self.uid = uid; self.name = name; self.folder = folder }
    /// 界面上显示的名字；第一个玩家没改过名时用界面给的缺省名（「玩家 1」，按界面语言）
    public func displayName(firstDefault: String) -> String { name.isEmpty ? firstDefault : name }
    /// 起局要给服务层的玩家号：第一个玩家 = first（services LocalPlayer.First），否则用户号
    public var serviceUser: String { uid.isEmpty ? "first" : uid }
}

public struct LocalPlayers {
    public static let listKey = "S2ALocalPlayers", currentKey = "S2ALocalPlayer"
    public static let firstFolder = "SaveData"
    let defaults: UserDefaults
    /// 第一个玩家没改过名时界面显示的名字（重名判断也按它：不许再建一个「玩家 1」）
    let firstDefault: String
    public init(defaults: UserDefaults, firstDefault: String = "Player 1") { self.defaults = defaults; self.firstDefault = firstDefault }

    public enum NameError: Error, Equatable { case empty, taken }

    /// 全部玩家，第一个玩家在最前；没存过 = 只有第一个玩家
    public var all: [LocalPlayer] {
        let first = LocalPlayer(uid: "", name: "", folder: Self.firstFolder)
        guard let list = defaults.array(forKey: Self.listKey) as? [[String: String]], !list.isEmpty else { return [first] }
        var players: [LocalPlayer] = []
        var seen = Set<String>()
        for item in list {
            guard let uid = item["uid"], uid.isEmpty || Self.validUID(uid), seen.insert(uid).inserted else { continue }
            players.append(LocalPlayer(uid: uid, name: item["name"] ?? "", folder: uid.isEmpty ? Self.firstFolder : (item["folder"] ?? "SaveData-" + uid)))
        }
        if let i = players.firstIndex(where: \.isFirst) { players.insert(players.remove(at: i), at: 0) } else { players.insert(first, at: 0) }
        return players
    }

    /// 当前玩家：存的 uid 不在表里 = 第一个玩家
    public var current: LocalPlayer {
        let players = all, want = defaults.string(forKey: Self.currentKey) ?? ""
        return players.first { $0.uid == want } ?? players[0]
    }

    public func select(_ uid: String) {
        guard all.contains(where: { $0.uid == uid }) else { return }
        save(all, current: uid)
    }

    /// 加一个玩家并选上；名字去掉首尾空白后不能空、不能和已有的重名（不分大小写）；不限长度（11-13 不许堵门：游戏里显示的昵称由服务层截到 32 字节 UTF-8，存档文件夹不按名字长短起名）
    @discardableResult
    public func add(_ raw: String) throws(NameError) -> LocalPlayer {
        let name = try check(raw, except: nil)
        var players = all
        let uid = Self.uid(for: name)
        let folders = Set(players.map(\.folder))
        var folder = Self.folder(for: name)
        if folders.contains(folder) { folder += "-" + uid.prefix(6) }
        let player = LocalPlayer(uid: uid, name: name, folder: folder)
        players.append(player)
        save(players, current: uid)
        return player
    }

    /// 改名：只改显示和游戏里的昵称，用户号和存档位置不变（存档还是这个人的）
    public func rename(_ uid: String, to raw: String) throws(NameError) {
        let name = try check(raw, except: uid)
        var players = all
        guard let i = players.firstIndex(where: { $0.uid == uid }) else { return }
        players[i].name = name
        save(players, current: current.uid)
    }

    /// 从表里拿掉（第一个玩家不能拿）；存档不删。拿掉的是当前玩家 → 回第一个玩家
    public func remove(_ uid: String) {
        guard !uid.isEmpty else { return }
        let players = all.filter { $0.uid != uid }
        let now = current.uid
        save(players, current: now == uid ? "" : now)
    }

    private func check(_ raw: String, except uid: String?) throws(NameError) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty else { throw .empty }
        let key = name.lowercased()
        guard !all.contains(where: { $0.uid != uid && $0.displayName(firstDefault: firstDefault).lowercased() == key }) else { throw .taken }
        return name
    }

    private func save(_ players: [LocalPlayer], current uid: String) {
        defaults.set(players.map { ["uid": $0.uid, "name": $0.name, "folder": $0.folder] }, forKey: Self.listKey)
        defaults.set(uid, forKey: Self.currentKey)
    }

    /// 按名字算用户号：SHA-256("S2Arm local player\n" + 名字的小写) 的前 16 字节；全 0 或撞上 Ryujinx 缺省用户（第一个玩家的）时再加一次盐
    public static func uid(for name: String) -> String {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
        var salt = ""
        while true {
            let hex = SHA256.hash(data: Data(("S2Arm local player\n" + key + salt).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
            if hex != String(repeating: "0", count: 32), hex != "00000000000000010000000000000000" { return hex }
            salt += "\n"
        }
    }

    /// 存档位置文件夹名：SaveData-<名字>，路径分隔符换成 -、去掉开头的点（「文件」App / 访达里看得懂是谁的）
    public static func folder(for name: String) -> String {
        var cleaned = String(name.map { "/\\:".contains($0) ? "-" : $0 })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        // 文件名上限 255 字节（APFS / NTFS）：名字不限长，文件夹名按 UTF-8 在整字处截到 200 字节（留给「SaveData-」与重名时的「-用户号」后缀）；
        //   旧上限 20 字以内的名字最多 80 字节，原有文件夹名不变
        while cleaned.utf8.count > 200 { cleaned.removeLast() }
        return cleaned.isEmpty ? "SaveData-" + uid(for: name).prefix(8) : "SaveData-" + cleaned
    }

    static func validUID(_ uid: String) -> Bool {
        uid.count == 32 && uid.allSatisfy { "0123456789abcdef".contains($0) } && uid != String(repeating: "0", count: 32)
    }
}
