// S2Arm（不是上游文件）：键位设置（InputSettingsSheet）的数据与读写。键位格式同旧启动器 Models.swift 的 InputConfig
// （作业层 pack/jobs/library.py validate_input 的契约：schema 1、keyboard / mouse / gamepad / axes / mouseOptions / deadzone），
// 按玩家保存（键位设置里选玩家 1–4）：玩家 1 读这款文件夹里的 input.json → 私有目录 default-input.json → 标准键位（同起局 build.py 的取法）；
// 玩家 2–4 读这款文件夹里的 input-pN.json → 标准键位；写：saveInput 作业（作业层校验后原子写，起局时玩家 2–4 的经 S2A_INPUT_CONFIG_P2..P4
// 交给宿主，front_mac.m 槽 i = 玩家 i+1 各照各的映射采样），下次开始游戏时生效。
import Foundation
import S2ArmAppleAdapter

struct KeyBinding: Codable, Equatable { var code: Int; var modifiers: Int = 0 }
struct AxisBinding: Codable, Equatable { var source: String; var invert: Bool = false }
struct MouseOptions: Codable, Equatable {
    var mode = "camera"; var sensitivityX = 1.0; var sensitivityY = 1.0; var invertX = false; var invertY = false; var recenter = true
}
// 契约允许省略 modifiers / invert 等：按宿主的缺省解，不悄悄换成别的键位。
extension KeyBinding {
    enum CodingKeys: String, CodingKey { case code, modifiers }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(Int.self, forKey: .code); modifiers = try c.decodeIfPresent(Int.self, forKey: .modifiers) ?? 0
    }
}
extension AxisBinding {
    enum CodingKeys: String, CodingKey { case source, invert }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source); invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
    }
}
extension MouseOptions {
    enum CodingKeys: String, CodingKey { case mode, sensitivityX, sensitivityY, invertX, invertY, recenter }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(String.self, forKey: .mode); sensitivityX = try c.decode(Double.self, forKey: .sensitivityX); sensitivityY = try c.decode(Double.self, forKey: .sensitivityY)
        invertX = try c.decodeIfPresent(Bool.self, forKey: .invertX) ?? false; invertY = try c.decodeIfPresent(Bool.self, forKey: .invertY) ?? false; recenter = try c.decodeIfPresent(Bool.self, forKey: .recenter) ?? true
    }
}

struct InputConfig: Codable, Equatable {
    var schema = 1; var keyboard: [String: KeyBinding]; var mouse: [String: Int]; var gamepad: [String: String]; var axes: [String: AxisBinding]
    var mouseOptions: MouseOptions = .init(); var deadzone = 0.15
    var backButtons: [String: String]?
    static let targets = ["A","B","X","Y","LS","RS","L","R","ZL","ZR","PLUS","MINUS","LEFT","UP","RIGHT","DOWN","LS_UP","LS_DOWN","LS_LEFT","LS_RIGHT","RS_UP","RS_DOWN","RS_LEFT","RS_RIGHT"]
    static let padCodes = ["east","south","north","west","leftStick","rightStick","leftShoulder","rightShoulder","leftTrigger","rightTrigger","menu","options","dpadLeft","dpadUp","dpadRight","dpadDown"]
    static let axisTargets = ["LX","LY","RX","RY"]
    static let axisSources = ["leftX","leftY","rightX","rightY"]
    static var standard: InputConfig {
        let keys = ["A":14,"B":56,"X":49,"L":12,"R":5,"ZR":15,"LS":59,"RS":8,"PLUS":48,"MINUS":46,"LEFT":123,"UP":126,"RIGHT":124,"DOWN":125,"LS_UP":13,"LS_DOWN":1,"LS_LEFT":0,"LS_RIGHT":2]
        return .init(keyboard: keys.mapValues { KeyBinding(code: $0) }, mouse: ["Y":0,"ZL":1],
                     gamepad: Dictionary(uniqueKeysWithValues: zip(targets.prefix(16), padCodes).map { ($0, $1) }),
                     axes: ["LX":.init(source:"leftX"),"LY":.init(source:"leftY"),"RX":.init(source:"rightX"),"RY":.init(source:"rightY")])
    }
    /// 三类玩法预设（同旧启动器 F06）：都以标准键位为底，只改这类玩法最常用的键，其余照旧；套用后仍可逐项改再保存。
    enum Preset: String, CaseIterable { case action, racing, turnBased }
    static func preset(_ p: Preset) -> InputConfig {
        var c = standard
        switch p {
        case .action:   // 2 主攻击、空格闪避、E 交互、Q 道具、T / 6 肩键、Ctrl 蹲、C 锁定；右键视角、左键 ZL、中键 ZR
            c.keyboard.merge(["A":.init(code:19),"B":.init(code:49),"X":.init(code:14),"Y":.init(code:12),"L":.init(code:17),"R":.init(code:22),
                              "LS":.init(code:59),"RS":.init(code:8)], uniquingKeysWith: { $1 })
            c.mouse = ["Y":0, "ZL":1, "ZR":2]
            c.mouseOptions.mode = "camera"; c.mouseOptions.sensitivityX = 1.2; c.mouseOptions.sensitivityY = 1.2; c.mouseOptions.recenter = true; c.deadzone = 0.15
        case .racing:   // 空格加速、Shift 刹车、3 道具、E 备用油门、T / 6 换挡、C 换视角；视角灵敏度低、不回中
            c.keyboard.merge(["A":.init(code:49),"B":.init(code:56),"X":.init(code:20),"ZR":.init(code:14),"L":.init(code:17),"R":.init(code:22),
                              "RS":.init(code:8)], uniquingKeysWith: { $1 })
            c.mouse = ["Y":0]
            c.mouseOptions.mode = "camera"; c.mouseOptions.sensitivityX = 0.6; c.mouseOptions.sensitivityY = 0.6; c.mouseOptions.recenter = false; c.deadzone = 0.2
        case .turnBased:   // Return 确认、Esc 取消、Tab 菜单、删除返回、6 快捷栏、2 / 3 翻页、空格换单位；鼠标不转视角
            c.keyboard.merge(["A":.init(code:36),"B":.init(code:53),"PLUS":.init(code:48),"MINUS":.init(code:51),"X":.init(code:22),"L":.init(code:19),
                              "R":.init(code:20),"LS":.init(code:49)], uniquingKeysWith: { $1 })
            c.mouse = [:]
            c.mouseOptions.mode = "off"; c.deadzone = 0.25
        }
        return c
    }

    /// 一处重复绑定：哪类输入（keyboard / mouse / gamepad / axes）、哪两个键。作业层 validate_input 同样拒收重复。
    struct Conflict: Equatable { let kind: String; let first: String; let second: String }
    var conflicts: [Conflict] {
        func dupes<V: Hashable>(_ kind: String, _ map: [String: V]) -> [Conflict] {
            var seen: [V: String] = [:]; var out: [Conflict] = []
            for target in map.keys.sorted() {
                let v = map[target]!
                if let old = seen[v] { out.append(.init(kind: kind, first: old, second: target)) } else { seen[v] = target }
            }
            return out
        }
        return dupes("keyboard", keyboard.mapValues { "\($0.code):\($0.modifiers)" }) + dupes("mouse", mouse) + dupes("gamepad", gamepad)
            + dupes("axes", axes.mapValues(\.source))
    }
    var conflictingTargets: Set<String> { Set(conflicts.filter { $0.kind != "axes" }.flatMap { [$0.first, $0.second] }) }

    mutating func restoreTarget(_ target: String, from original: InputConfig) {
        keyboard[target] = original.keyboard[target]; mouse[target] = original.mouse[target]; gamepad[target] = original.gamepad[target]
    }

    /// 是不是同一套键位（#1987，同作业层 _same_input）：没有背键与空的背键一样；其余解码时已按宿主缺省补齐，按值比
    func same(_ other: InputConfig) -> Bool {
        var a = self, b = other
        if a.backButtons?.isEmpty == true { a.backButtons = nil }
        if b.backButtons?.isEmpty == true { b.backButtons = nil }
        a.schema = 1; b.schema = 1
        return a == b
    }

    /// 导入键位文件（#1987，同 iPad 导入的几道检查）：读不了 / 太大 / 不是 JSON / 不是 schema 1 / 缺项或值不对 / 有重复绑定 → 对应的拒收原因；
    ///   过了只进弹窗的工作副本，点「保存」时作业层 validate_input 再完整校验一遍
    enum ImportProblem: String, Error { case read, tooLarge, json, schema, invalid, duplicate }
    static let importLimit = 64 * 1024
    static func imported(from url: URL) -> Result<InputConfig, ImportProblem> {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > importLimit { return .failure(.tooLarge) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.read) }
        if data.count > importLimit { return .failure(.tooLarge) }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return .failure(.json) }
        guard let dict = object as? [String: Any], let schema = dict["schema"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1 else { return .failure(.schema) }   // true 也会桥成 NSNumber 1
        guard let config = try? JSONDecoder().decode(InputConfig.self, from: data) else { return .failure(.invalid) }
        if !config.conflicts.isEmpty { return .failure(.duplicate) }
        return .success(config)
    }

    /// 导出用的文件内容（同 input.json 的格式，iPad 能导入）
    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// 读到的键位与出处：读不懂已存的文件时 problem 为真（先显示默认键位，保存会覆盖它）；
///   inherited 为真是玩家 2–4 没存过自己的键位、沿用玩家 1 的那份（与起局一致，保存后单独生效）。
///   source 同作业层 effective_input：game（这款单独存的）/ default（所有游戏的默认）/ standard（标准键位）/ player1（沿用玩家 1）
struct LoadedInput { let config: InputConfig; let problem: Bool; var inherited = false; var source = "standard" }

/// 一次读出的四位玩家键位，加上「所有游戏的默认」（#1987：「恢复默认」回到它；没设过时 = 标准键位，defaultSet 为假）
struct InputLoad {
    var players: [Int: LoadedInput] = [:]
    var allGamesDefault = InputConfig.standard
    var defaultSet = false
}

extension S2ArmLauncherModel {
    /// 这款四位玩家实际生效的键位（#2081：读取与「能不能用」交作业层 loadInput，和起局 build.py 同一条规则——
    ///   玩家 1：这款的 input.json → default-input.json → 标准键位，读不出或不合规都往下一份走；玩家 2–4：自己的 input-pN.json 能用就用，否则沿用玩家 1 的）。
    ///   原先这里自己解码文件，只看结构不看 validate_input，弹窗显示的和游戏里实际用的会不是同一套
    func loadInputs(gameID: String) async throws -> InputLoad {
        guard !provider.client.environment.library.isEmpty else { throw JobClientError(LibraryProvider.noLibraryMessage) }
        let r = try await provider.client.perform("loadInput", extra: ["gameId": gameID]).result
        func decode(_ object: Any?) -> InputConfig? {
            guard let object, !(object is NSNull), let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JSONDecoder().decode(InputConfig.self, from: data)
        }
        var out = InputLoad()
        for row in r["players"] as? [[String: Any]] ?? [] {
            guard let player = (row["player"] as? NSNumber)?.intValue else { continue }
            let source = row["source"] as? String ?? "standard"
            out.players[player] = LoadedInput(config: decode(row["config"]) ?? .standard, problem: row["problem"] as? Bool ?? false,
                                              inherited: source == "player1", source: source)
        }
        // #1987：所有游戏的默认（default-input.json 能用时的那份；null = 没设过，回到标准键位）
        if let dflt = decode(r["default"]) { out.allGamesDefault = dflt; out.defaultSet = true }
        return out
    }

    /// 存这款的键位（saveInput 作业，player 1–4：1 = input.json，2–4 = input-pN.json，作业层校验后原子写）。
    /// 玩家 1 和所有游戏的默认一样时作业层删掉这款的 input.json（这款跟着默认走），返回真。
    /// 没配游戏库不起作业；作业层拒收抛 JobFailure，message 是作业层原句。
    @discardableResult
    func saveInput(_ config: InputConfig, gameID: String, player: Int = 1) async throws -> Bool {
        guard !provider.client.environment.library.isEmpty else { throw JobClientError(LibraryProvider.noLibraryMessage) }
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
        let r = try await provider.client.perform("saveInput", extra: ["config": object, "gameId": gameID, "player": player]).result
        return r["followsDefault"] as? Bool ?? false
    }

    /// 玩家 2–4 回到沿用玩家 1（resetInput 作业：删掉这位的 input-pN.json）
    func resetInput(gameID: String, player: Int) async throws {
        guard !provider.client.environment.library.isEmpty else { throw JobClientError(LibraryProvider.noLibraryMessage) }
        _ = try await provider.client.perform("resetInput", extra: ["gameId": gameID, "player": player])
    }

    /// 设为所有游戏的默认（#1987，Mac 上点「保存」时才调）：写 default-input.json（设成标准键位 = 删掉它），这款的 input.json 删掉、跟着默认走
    func setDefaultInput(_ config: InputConfig, gameID: String) async throws {
        guard !provider.client.environment.library.isEmpty else { throw JobClientError(LibraryProvider.noLibraryMessage) }
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
        _ = try await provider.client.perform("setDefaultInput", extra: ["config": object, "gameId": gameID, "player": 1])
    }
}
