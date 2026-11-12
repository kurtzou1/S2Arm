// UI adapted from LumaDock (MIT); see ../../README.md.
import Foundation
import AppKit
import SwiftUI
import S2ArmAppleAdapter

struct NSPPackage: Codable, Identifiable {
    var id: String { sha256 + ":" + titleId + ":" + String(version) }
    var titleId: String; var baseId: String; var version: Int; var type: String; var name: String; var display: String
    var path: String; var size: Int64; var sha256: String; var builds: [String:String]
    /// 读取器记的本项内容字节（同一原件里装了多项时 size 是整个原件，见 Game.ownBytes）；老记录没有
    var contentBytes: Int64?
    var kindName: String { ["base":L("本体"),"update":L("更新"),"dlc":"DLC"][type] ?? L("未知内容") }
}
struct Game: Codable, Identifiable {
    var id: String; var name: String; var display: String; var packages: [NSPPackage]; var hidden: Bool
    var compatibility: String?; var missing: [String]?; var cover: String?; var ready: Bool?; var needsPreparation: Bool?; var inputConfig:Bool?
    var requirementDiagnostics: [TaskDiagnostic]?
    var downstream: Downstream?   // 下游深度方案（pack/jobs/downstream.py describe）：命中时导出前弹确认页
    var compatibilityName: String { ["startup":L("仅验证启动"),"verified":L("Mac 已验证"),"experimental":L("实验性"),"unsupported":L("暂不支持")][compatibility ?? "unsupported"] ?? L("实验性") }
    var buildable: Bool { compatibility != "unsupported" && (missing ?? []).isEmpty }
    /// 这一项自己的字节：同一个原件里装了多项（合集 XCI / NUP 容器）时用本项内容字节，否则用原件大小（同 pack/jobs/report.py own_bytes；#141）
    func ownBytes(_ p: NSPPackage) -> Int64 {
        let shared = !p.sha256.isEmpty && packages.filter { $0.sha256 == p.sha256 }.count > 1
        return shared ? (p.contentBytes.flatMap { $0 > 0 ? $0 : nil } ?? p.size) : p.size
    }
    /// 原包合计：同一个原件里的多项只算一次
    var sourceBytes: Int64 { Dictionary(grouping:packages, by:\.sha256).values.compactMap(\.first).reduce(Int64(0)) { $0 + $1.size } }
}
/// 下游深度方案（pack/downstream/schemes.json）：方案、能不能选与原因、确认页文案（按界面语言挑）、玩家上次的选择（nil = 没选过；"" = 仍用原版）
struct Downstream: Codable {
    struct Copy: Codable { var title: String; var body: String; var points: [String]; var recommend: String; var original: String }
    var id: String; var name: String; var eligible: Bool; var reason: [String:String]; var copy: [String:Copy]; var choice: String?
    var text: Copy? { copy[Localization.language] ?? copy["zh"] }
    var why: String { reason[Localization.language] ?? reason["zh"] ?? "" }
}
/// 里程碑与它的时间推算在适配层（S2ArmAppleAdapter Milestones.swift），新旧两个前端共用一份
typealias Milestone = S2ArmAppleAdapter.Milestone
extension Milestone {
    var estimateSource: String {
        if source == "history", let samples, samples > 0 { return L("本机历史 · \(samples) 次记录") }
        if source == "reuse" { return L("复用缓存，本机还没有复用记录，按 0 秒计") }
        if source == "default" { return L("默认参考值") }
        return L("估时来源未知")
    }
}
/// 阶段里还没做完的逐项计数（出包：直连库·翻译 + 编库 n / 23502…；pack/jobs/core.py stage_progress）。rate = 每秒完成数，刚开始没有
struct TaskCounter: Codable, Hashable, Identifiable {
    var name: String; var done: Double; var total: Double; var rate: Double?
    var id: String { name }
    var fraction: Double { total > 0 ? min(1, max(0, done / total)) : 0 }
    var remaining: Double? { guard let r = rate, r > 0, total > done else { return nil }; return (total - done) / r }
}
struct PendingIPhonePack {
    let game: Game
    var spaceOverride = false
    var id: String { game.id }
}

struct TaskRecord: Codable, Identifiable {
    var id: String; var operation: String; var state: String; var gameId: String?; var stage: String?; var message: String?
    var stageIndex: Int?; var stageCount: Int?; var started: Double?; var ended: Double?
    var done: Double?; var total: Double?; var elapsed: Double?; var unit: String?
    var outputPath: String?
    var ipaPath: String?
    var device: String?
    var target: String?
    // 装到 iPhone：这次推了几个资源包文件（成功句按它写，审计 18:00 P1-58）
    var packFiles: Int?
    // 装到 iPhone：资源传完但电脑没拉起 App 解开时的那句（作业结果 unpackPending，11-09 #336）；有它就不说「已装到 iPhone」
    var unpackPending: String?
    var diagnostics: [TaskDiagnostic]?
    var space: SpaceBudget?
    // 里程碑进度（准备任务）：计划、当前里程碑、各里程碑开始时刻（前端收到切换事件时记）
    var milestones: [Milestone]?; var milestone: String?; var milestoneStarted: [String:Double]?
    var counters: [TaskCounter]?
    var hasWarnings: Bool { diagnostics?.contains(where:\.isWarning) == true }
    // 完成了但带报错级诊断（10-26：直连没出成、只出通用包——维护者要响亮报红，不能显示成绿色「完成」）
    var hasErrors: Bool { state == "completed" && diagnostics?.contains(where:{ !$0.isWarning }) == true }
    var progressFraction: Double? {
        guard let done,let total,done.isFinite,total.isFinite,total>0 else {return nil}
        return min(1,max(0,done/total))
    }
    var stageFraction: Double? {
        guard let index=stageIndex,let count=stageCount,count>1,index>0 else {return nil}
        return min(1,max(0,(Double(index-1)+(progressFraction ?? 0))/Double(count)))
    }
    var stateName: String {
        if hasErrors { return L("完成（有报错）") }
        switch state {
        case "running", "failed": return SharedExperience.stateTitle(state)
        case "cancelled": return SharedExperience.terminalTitle("job.cancelled")
        case "completed": return hasWarnings ? L("完成（有警告）") : SharedExperience.terminalTitle("job.succeeded")
        default: return ["queued":L("排队"),"cancelling":L("取消中"),"interrupted":L("中断")][state] ?? state
        }
    }
    var active: Bool { ["running","queued","cancelling"].contains(state) }
    /// 出包被空间预检拦下（disk_full 且预算里有盘 enough=false、还没「仍然继续」过）：失败页给「仍然继续」。
    ///   出包中途真写满也报 disk_full，但那时预检是过了的（enough 全 true），不给这个按钮
    var spacePreflightBlocked: Bool {
        guard state == "failed", ["build","ipa"].contains(operation), let space, space.override != true,
              diagnostics?.last(where:{ !$0.isWarning })?.code == "disk_full" else { return false }
        return space.volumes.contains { $0.enough == false }
    }
    var title: String {
        if let platform = BuildPlatform(rawValue:target ?? ""), operation.hasPrefix("platform") {
            return platform.name + " · " + L(["platformCheck":"检查环境", "platformBuild":"编译", "platformSource":"添加平台支持", "platformSetup":"准备工具链"][operation] ?? operation)
        }
        return ["saveBackup":L("备份存档"),"saveInspect":L("检查存档备份"),"saveRestore":L("恢复存档"),"catalog":L("读取游戏库"),"saveInput":L("保存映射"),"worker":L("本地任务"),"setup":L("创建游戏库"),"clean":L("清理游戏文件"),"remove":L("移出游戏库"),"delete":L("删除游戏"),"diagnostics":L("导出诊断"),"prepareEngine":L("准备引擎工具"),"downloadMetal":L("下载 Metal 编译组件"),"downloadIosPlatform":L("下载 iOS 平台组件"),"pullDiagnostics":L("拉回 iPhone 诊断"),"ipa":L("编译 iPhone 应用"),"install":L("装到 iPhone"),"installDotnet":L("安装 .NET SDK"),"import":L("导入游戏"),"build":L("编译游戏"),"launch":L("运行游戏"),"keys":L("导入密钥"),"preflight":L("环境检查")][operation] ?? operation }
}
struct ToolCheck: Decodable, Identifiable {
    var id: String { name }; var name: String; var ok: Bool; var message: String
    var help: String?; var action: String?; var group: String?; var requiredFor: [String]?; var detail: String?; var location:String?; var repairCommand:String?
    var diagnostic: TaskDiagnostic?
    func required(for scope:String) -> Bool { requiredFor?.contains(scope) ?? true }
}
struct GameProfile: Decodable, Identifiable { var id: String; var name: String; var compatibility: String; var version: String }
struct KeyBinding: Codable, Equatable { var code: Int; var modifiers: Int = 0 }
struct AxisBinding: Codable, Equatable { var source: String; var invert: Bool = false }
struct MouseOptions: Codable, Equatable {
    var mode = "camera"; var sensitivityX = 1.0; var sensitivityY = 1.0; var invertX = false; var invertY = false; var recenter = true
}
// The saveInput contract permits omitted modifiers / inversions. Decode those
// as the native host does, rather than silently falling back to another mapping.
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
    var schema = 1; var keyboard: [String:KeyBinding]; var mouse: [String:Int]; var gamepad: [String:String]; var axes: [String:AxisBinding]; var mouseOptions: MouseOptions = .init(); var deadzone = 0.15
    static let targets = ["A","B","X","Y","LS","RS","L","R","ZL","ZR","PLUS","MINUS","LEFT","UP","RIGHT","DOWN","LS_UP","LS_DOWN","LS_LEFT","LS_RIGHT","RS_UP","RS_DOWN","RS_LEFT","RS_RIGHT"]
    static let padCodes = ["east","south","north","west","leftStick","rightStick","leftShoulder","rightShoulder","leftTrigger","rightTrigger","menu","options","dpadLeft","dpadUp","dpadRight","dpadDown"]
    static var standard: InputConfig {
        let keys = ["A":14,"B":56,"X":49,"L":12,"R":5,"ZR":15,"LS":59,"RS":8,"PLUS":48,"MINUS":46,"LEFT":123,"UP":126,"RIGHT":124,"DOWN":125,"LS_UP":13,"LS_DOWN":1,"LS_LEFT":0,"LS_RIGHT":2]
        return .init(keyboard: keys.mapValues { KeyBinding(code:$0) }, mouse:["Y":0,"ZL":1], gamepad:Dictionary(uniqueKeysWithValues:zip(targets.prefix(16),padCodes).map { ($0,$1) }), axes:["LX":.init(source:"leftX"),"LY":.init(source:"leftY"),"RX":.init(source:"rightX"),"RY":.init(source:"rightY")])
    }
    // 三类玩法预设（F06）：都以标准映射为底，只改动这类玩法最常用的键位，其余保持标准，便于玩家再逐项微调。
    // 预设只是起点，不是一个锁定模式：套用后照常编辑、保存，与 standard 走同一条落盘与注入链路。
    enum Preset: String, CaseIterable, Identifiable {
        case action, racing, turnBased
        var id: String { rawValue }
        var title: String {
            switch self {
            case .action: return L("动作")
            case .racing: return L("赛车")
            case .turnBased: return L("回合制")
            }
        }
        var detail: String {
            switch self {
            case .action: return L("WASD 走位、鼠标转视角、左右键分担攻击与闪避，适合动作 / 开放世界")
            case .racing: return L("WASD 转向与油门刹车、鼠标视角灵敏度调低并关闭回中，适合赛车 / 飞行")
            case .turnBased: return L("方向键选单、空格确认、加减键翻页，鼠标不驱动视角，适合回合制 / 战棋")
            }
        }
    }
    /// 动作：左手 WASD 走位，右手鼠标视角；E 主攻击、Q 副攻击、空格跳跃（对应 A），Shift 闪避（对应 B）。
    /// WASD 留给摇杆方向（standard 已经是 W/S/A/D），A/B/X/Y 换到右手附近的键，始终保证无重复绑定。
    static var action: InputConfig {
        var c = standard
        c.keyboard.merge(["A":KeyBinding(code:19),          // 2 主攻击
                          "B":KeyBinding(code:49),          // 空格 闪避 / 取消
                          "X":KeyBinding(code:14),          // E 副攻击 / 交互
                          "Y":KeyBinding(code:12),          // Q 投掷 / 道具
                          "L":KeyBinding(code:17),          // T 左肩
                          "R":KeyBinding(code:22),          // 6 右肩
                          "LS":KeyBinding(code:59),         // Ctrl 蹲下
                          "RS":KeyBinding(code:8)],         // C 锁定 / 视角回正
                         uniquingKeysWith: { $1 })
        c.mouse = ["Y":0, "ZL":1, "ZR":2]                  // 右键视角、左键 ZL、中键 ZR
        c.mouseOptions.mode = "camera"; c.mouseOptions.sensitivityX = 1.2; c.mouseOptions.sensitivityY = 1.2
        c.mouseOptions.recenter = true; c.deadzone = 0.15
        return c
    }
    /// 赛车：WASD 转向与油门刹车（走摇杆方向），空格确认（A）、Shift 刹车（B），鼠标灵敏度调低并关闭回中。
    static var racing: InputConfig {
        var c = standard
        c.keyboard.merge(["A":KeyBinding(code:49),          // 空格 = A（加速 / 确认）
                          "B":KeyBinding(code:56),          // Shift = B（刹车 / 手刹）
                          "X":KeyBinding(code:20),          // 3 = X（氮气 / 道具）
                          "ZR":KeyBinding(code:14),         // E = ZR（备用油门）
                          "L":KeyBinding(code:17),          // T 左肩（换挡向下）
                          "R":KeyBinding(code:22),          // 6 右肩（换挡向上）
                          "RS":KeyBinding(code:8)],         // C 切换视角
                         uniquingKeysWith: { $1 })
        c.mouse = ["Y":0]
        c.mouseOptions.mode = "camera"; c.mouseOptions.sensitivityX = 0.6; c.mouseOptions.sensitivityY = 0.6
        c.mouseOptions.recenter = false                    // 赛车视角不回中，跟车更稳
        c.deadzone = 0.2
        return c
    }
    /// 回合制：方向键走格子与选单，空格确认、Esc 取消，鼠标不驱动视角；摇杆死区调大防止误选。
    static var turnBased: InputConfig {
        var c = standard
        c.keyboard.merge(["A":KeyBinding(code:36),          // Return = 确认（A）
                          "B":KeyBinding(code:53),          // Esc = 取消（B）
                          "PLUS":KeyBinding(code:48),       // Tab = 菜单（＋）
                          "MINUS":KeyBinding(code:51),      // 删除 = 返回（－）
                          "X":KeyBinding(code:22),          // 6 快捷栏
                          "L":KeyBinding(code:19),          // 2 左肩页签
                          "R":KeyBinding(code:20),          // 3 右肩页签
                          "LS":KeyBinding(code:49)],        // 空格 切换单位
                         uniquingKeysWith: { $1 })
        c.mouse = [:]
        c.mouseOptions.mode = "off"                        // 回合制不需要鼠标驱动视角
        c.deadzone = 0.25
        return c
    }
    /// 按预设取配置（下拉选择用）。
    static func preset(_ p: Preset) -> InputConfig {
        switch p { case .action: return action; case .racing: return racing; case .turnBased: return turnBased }
    }
    var conflicts: [String] {
        var out: [String] = []; var seen: [String:String] = [:]
        for (t,b) in keyboard { let key = "k\(b.code):\(b.modifiers)"; if let old = seen[key] { out.append(L("键盘：\(old) 与 \(t) 重复")) }; seen[key] = t }
        seen = [:]; for (t,b) in mouse { let k = String(b); if let old = seen[k] { out.append(L("鼠标：\(old) 与 \(t) 重复")) }; seen[k] = t }
        seen = [:]; for (t,b) in gamepad { if let old = seen[b] { out.append(L("手柄：\(old) 与 \(t) 重复")) }; seen[b] = t }
        seen = [:]; for (t,b) in axes { if let old = seen[b.source] { out.append(L("手柄轴：\(old) 与 \(t) 重复")) }; seen[b.source] = t }
        return out
    }
}
struct Preferences: Codable { var library: String = ""; var libraryId: String = ""; var developerDir = ""; var onboardingComplete = false; var language: String?; var appearance: String?; var engineDir: String?; var pythonPath: String?; var fontsDir: String?; var devHud: Bool?; var metalHud: Bool?; var iphoneTarget: IPhoneTarget?; var platformBuilds: [String:PlatformBuildConfiguration]?; var selectedBuildPlatform: String?; var aiControl: Bool?; var exportTargets: [String]? }
// 打 iPhone 包的目标设备（pack/jobs/target.py）：着色器按它的 GPU 架构 + 系统大版本预编
struct IPhoneTarget: Codable, Equatable, Hashable { var model: String; var productType: String; var gpuArch: String; var os: Int; var connected = false; var deviceName: String? = nil
    var label: String { "\(model) · iOS \(os)" }
    var request: [String:Any] { ["model":model,"productType":productType,"gpuArch":gpuArch,"os":os] } }
struct TargetProbe { var connected: [IPhoneTarget] = []; var models: [IPhoneTarget] = []; var osChoices: [Int] = [] }

func keyName(_ b: KeyBinding?) -> String {
    guard let b else { return L("未绑定") }
    let keys: [Int:String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"Return",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",49:L("空格"),50:"`",51:L("删除"),53:"Esc",56:"Shift",58:"Option",59:"Ctrl",123:"←",124:"→",125:"↓",126:"↑"]
    return (b.modifiers & 1 != 0 ? "⇧" : "") + (b.modifiers & 2 != 0 ? "⌃" : "") + (b.modifiers & 4 != 0 ? "⌥" : "") + (keys[b.code] ?? L("键码 \(b.code)"))
}
func targetName(_ t: String) -> String {
    ["LS":L("左摇杆按下"),"RS":L("右摇杆按下"),"PLUS":"＋","MINUS":"－","LEFT":L("十字键左"),"UP":L("十字键上"),"RIGHT":L("十字键右"),"DOWN":L("十字键下"),"LS_UP":L("左摇杆上"),"LS_DOWN":L("左摇杆下"),"LS_LEFT":L("左摇杆左"),"LS_RIGHT":L("左摇杆右"),"RS_UP":L("右摇杆上"),"RS_DOWN":L("右摇杆下"),"RS_LEFT":L("右摇杆左"),"RS_RIGHT":L("右摇杆右")][t] ?? t
}

func padName(_ code:String) -> String {
    ["east":L("右侧按钮"),"south":L("下侧按钮"),"north":L("上侧按钮"),"west":L("左侧按钮"),"leftStick":L("左摇杆按下"),"rightStick":L("右摇杆按下"),"leftShoulder":L("左肩键"),"rightShoulder":L("右肩键"),"leftTrigger":L("左扳机"),"rightTrigger":L("右扳机"),"menu":L("菜单（＋）"),"options":L("选项（－）"),"dpadLeft":L("方向键左"),"dpadUp":L("方向键上"),"dpadRight":L("方向键右"),"dpadDown":L("方向键下")][code] ?? code
}
func axisName(_ code:String) -> String {
    ["LX":L("左摇杆横向"),"LY":L("左摇杆纵向"),"RX":L("右摇杆横向"),"RY":L("右摇杆纵向"),"leftX":L("左摇杆横向"),"leftY":L("左摇杆纵向"),"rightX":L("右摇杆横向"),"rightY":L("右摇杆纵向")][code] ?? code
}

// 发布标识：launchers/macos/build_app.py 写进 Info.plist，设置页和 AI 控制口 /help 读同一份，
// 内测回报要填的包号就是 S2ABuildID（<短提交号>[-dirty]-<引擎源码指纹前 8>）。
enum S2ArmRelease {
    static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    static var version: String { info["CFBundleShortVersionString"] as? String ?? "dev" }
    static var build: String { info["CFBundleVersion"] as? String ?? "" }
    static var buildID: String { info["S2ABuildID"] as? String ?? "" }
    /// 设置页显示「0.1.0（769）」；源码里直接跑、没有构建号时只显示版本
    static func display(_ version: String, _ build: String) -> String { build.isEmpty ? version : "\(version)（\(build)）" }
    static var label: String { display(version, build) }
    /// 设置页显示用：源码里直接跑（Info.plist 没有版本号）时用本地化的「开发版本」，
    /// 控制口 /help 仍返回 version（"dev"）——两处用途不同，不能共用同一个字符串。
    static func settingsLabel(_ version: String?, _ build: String) -> String {
        guard let v = version, !v.isEmpty else { return L("开发版本") }
        return display(v, build)
    }
    static var settingsLabel: String { settingsLabel(info["CFBundleShortVersionString"] as? String, build) }
}
