import Foundation

/// 设置表的一行（设计稿 EngineProvider.settingsSchema 的行，JSON 字段与 NX2Apple 的 LaunchSetting——dm/launcher.json 一行——同格式），
/// 另加 unavailableReason：这款没有这项能力时说明原因。S2Arm 现在一行都不给（见 SettingsProvider），类型留着对齐设计稿协议。
public struct LaunchSettingRow: Codable, Identifiable, Equatable {
    public let env: String
    public let kind: String
    public var label: String
    public var note: String
    public let def: String
    public let section: String?
    public var options: [[String]]?
    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let on: String?
    public let off: String?
    public var level: String?
    public var needs: String?
    public var unavailableReason: String?

    public init(env: String, kind: String, label: String, note: String = "", def: String, section: String? = "Game",
                options: [[String]]? = nil, min: Double? = nil, max: Double? = nil, step: Double? = nil,
                on: String? = nil, off: String? = nil, level: String? = "basic", needs: String? = nil, unavailableReason: String? = nil) {
        self.env = env; self.kind = kind; self.label = label; self.note = note; self.def = def; self.section = section
        self.options = options; self.min = min; self.max = max; self.step = step; self.on = on; self.off = off
        self.level = level; self.needs = needs; self.unavailableReason = unavailableReason
    }

    enum CodingKeys: String, CodingKey {
        case env, kind, label, note, def = "default", section, options, min, max, step, on, off, level, needs, unavailableReason
    }

    public var id: String { env }
}

/// 本适配层自己记的前端选择（<数据目录>/apple-frontend/launch-settings.json）：现在只有出包页的平台勾选。
/// 这里没有每款的游戏选项：游戏语言、主机模式、帧率、满屏等逐款选项都在启动设置（LaunchSettingsSheet，共享定义表 + 作业层 community 存 launch.json；
/// 游戏语言 11-14 维护者确认玩家可选，推翻 11-07「不给玩家选」）。旧文件里的 games（语言 / 底座）读时丢掉。
public final class SettingsProvider {
    private let client: JobClient
    private let store: URL
    /// EngineProvider 的 async 方法会从别的线程进来：读写都过锁。
    private let lock = NSLock()
    /// 出包页记住的平台勾选（同一个文件的 exportTargets；没存过为 nil，读旧启动器 preferences.exportTargets）。
    private var targets: [String]?
    /// 「允许 AI 操作 S2Arm」（本机控制口，见 ControlPort）：缺省关；--control / S2ARM_CONTROL=1 启动时强制开、不写这里。
    private var ai: Bool
    /// iCloud 存档同步的云盘文件夹（玩家在环境页选的；iPhone 上选同一个）。没选 = 不同步
    private var cloud: String?

    public init(client: JobClient, store: URL? = nil) {
        self.client = client
        self.store = store ?? client.environment.privateRoot.appendingPathComponent("apple-frontend/launch-settings.json")
        targets = Self.read(self.store)
        ai = Self.object(self.store)?["aiControl"] as? Bool ?? false
        cloud = Self.object(self.store)?["cloudSavesFolder"] as? String
    }

    private static func object(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["schema"] as? Int == 1 else { return nil }
        return obj
    }

    private static func read(_ url: URL) -> [String]? { object(url)?["exportTargets"] as? [String] }

    /// 「允许 AI 操作 S2Arm」开没开（玩家在环境页的开关）。
    public var aiControl: Bool { lock.withLock { ai } }

    public func setAIControl(_ on: Bool) throws {
        let before = lock.withLock { () -> Bool in let b = ai; ai = on; return b }
        do { try write() } catch { lock.withLock { ai = before }; throw JobClientError("「允许 AI 操作」的开关没能写进磁盘（\(error.localizedDescription)）。") }
    }

    public var cloudSavesFolder: String? { lock.withLock { cloud } }

    public func setCloudSavesFolder(_ path: String?) throws {
        // 写盘失败把内存改回原值（审计 P2-273：原先内存已是新路径、磁盘还是旧的，之后的同步按没存下的路径走、下次启动又回到旧的）
        let before = lock.withLock { () -> String? in let b = cloud; cloud = path; return b }
        do { try write() } catch { lock.withLock { cloud = before }; throw JobClientError("iCloud 存档文件夹没能写进磁盘（\(error.localizedDescription)）。") }
    }

    /// 出包页勾了哪些平台（平台 id，ExportPlatform.rawValue）。缺省一个都不勾（维护者 11-02）；新前端没存过就接着用旧启动器的勾选。
    public var exportTargets: [String] {
        lock.lock(); defer { lock.unlock() }
        return targets ?? client.environment.exportTargets ?? []
    }

    /// 记住平台勾选（写本文件，不回写旧启动器的 preferences.json）。
    public func setExportTargets(_ ids: [String]) throws {
        let before = lock.withLock { () -> [String]? in let b = targets; targets = ids; return b }
        do { try write() } catch { lock.withLock { targets = before }; throw JobClientError("出包平台的勾选没能写进磁盘（\(error.localizedDescription)）。") }
    }

    private func write() throws {
        let dir = store.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var file: [String: Any] = ["schema": 1]
        if let saved = lock.withLock({ targets }) { file["exportTargets"] = saved }
        if lock.withLock({ ai }) { file["aiControl"] = true }
        if let folder = lock.withLock({ cloud }) { file["cloudSavesFolder"] = folder }
        let data = try JSONSerialization.data(withJSONObject: file, options: [.sortedKeys])
        try data.write(to: store, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path)
    }
}
