import Foundation
import S2ArmShellBridge
import ShellUI

/// 每款游戏的设置行（11-07 维护者：游戏库按住游戏 / 点设置弹出；60 帧、宽屏强制启用点一下切换就生效，虚拟手柄布局进二级页，
/// 全部按键透明度一个全局拉杆）。只放数据：上游 GameDetailView 原样画（开关 / 多选 / 拉杆），改动经 ShellActions.onChange 回到这里。
///
/// 存哪：
/// - 60 帧 / 宽屏强制启用：按游戏，独立偏好 `S2AGame.<游戏号>`（键 S2AFps60、S2AWidenForce）；起局时宿主 ios/settings.m 先读这一款的
/// - 按键透明度：App 级 `S2AVPadOpacity`（0.1–1，缺省 1），全部游戏共用；宿主 ios/vpad.m 进游戏时读
/// - 虚拟手柄布局：按游戏，走 C 接口 s2a_shell_vpad_*（宿主 ios/vpad_shell.m），与游戏内拖动编辑同一份文件
public enum S2ArmGameSettings {
    public static let fps60 = "fps60", widenForce = "widenForce", opacity = "vpadOpacity", layout = "vpadLayout", holdLock = "vpadHoldLock", identity = "gameIdentity", editIdentity = "edit"
    /// 布局多选里打开二级编辑页的那一项（不是一个方案）
    public static let editLayout = "edit"
    public static let splitScreen = "splitScreen", screenOrientation = "screenOrientation"

    /// 存偏好的地方；单测换成临时 suite
    public struct Stores {
        public var game: (String) -> UserDefaults?
        public var app: UserDefaults
        public init(game: @escaping (String) -> UserDefaults?, app: UserDefaults) { self.game = game; self.app = app }
        public static var live: Stores { Stores(game: { UserDefaults(suiteName: "S2AGame." + $0) }, app: .standard) }
    }

    /// 本款布局的当前状态（宿主接口给的 JSON）；读不到（Mac 单测、宿主没链）按「默认、没有我的布局」
    public struct LayoutState: Equatable { public var selected: String; public var hasMine: Bool; public var holdLock = true; public var customIdentity = false }
    public static func layoutState(_ id: String) -> LayoutState {
        guard let p = id.withCString({ s2a_shell_vpad_layout_json($0, 832, 419, 0) }) else { return LayoutState(selected: "default", hasMine: false) }
        defer { free(p) }
        let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: p).utf8)) as? [String: Any]
        return LayoutState(selected: obj?["selected"] as? String ?? "default", hasMine: obj?["hasMine"] as? Bool ?? false, holdLock: obj?["holdLock"] as? Bool ?? true)
    }

    // 与原生窗口、设置 App 及共享表使用相同 app scope id；旧键只作迁移来源。
    // 生产入口不注册这两项缺省；未保存时为 nil，缺省由读取逻辑返回。
    private static func playChoice(_ key: String, legacy: String, values: [String], app: UserDefaults) -> String {
        var value = app.object(forKey: key)
        if value == nil, let old = app.string(forKey: legacy), values.contains(old) {
            value = old; app.set(old, forKey: key)
        }
        if app.object(forKey: legacy) != nil { app.removeObject(forKey: legacy) }
        guard let selected = value as? String, values.contains(selected) else {
            if value != nil { app.removeObject(forKey: key) }
            return "auto"
        }
        return selected
    }

    public static func sections(for id: String, stores: Stores = .live, state: LayoutState) -> [SettingSection] {
        let g = stores.game(id)
        // 这款没设过就看「所有游戏的默认」（App 级，起局时 ios/settings.m 的 s2a_ios_settings_defaults 同一分层），再没有才是开
        let on60 = (g?.object(forKey: "S2AFps60") as? Bool) ?? (stores.app.object(forKey: "S2AFps60") as? Bool) ?? true
        let force = g?.bool(forKey: "S2AWidenForce") ?? false
        let op = (stores.app.object(forKey: "S2AVPadOpacity") as? Double).map { min(1, max(0.1, $0)) } ?? 1
        var options = [SettingOption("default", "Default layout")]
        if state.hasMine { options.append(SettingOption("mine", "My layout")) }
        options.append(SettingOption(editLayout, "Adjust positions…"))
        let current = state.selected == "mine" && state.hasMine ? "mine" : "default"
        let splitValue = playChoice(splitScreen, legacy: "S2ASplitScreen", values: ["auto", "on", "off"], app: stores.app)
        let direction = playChoice(screenOrientation, legacy: "S2AScreenOrientation", values: ["auto", "landscape", "portrait"], app: stores.app)
        return [
            SettingSection(id: "s2a.identity", title: "Display", rows: [
                SettingRow(id: identity, label: "Name and Cover", note: "Only changes how it appears on this iPhone", kind: .choice([SettingOption("current", state.customIdentity ? "Customized" : "Default"), SettingOption(editIdentity, "Edit…")]), value: "current"),
            ]),
            SettingSection(id: "s2a.picture", title: "Picture", rows: [
                SettingRow(id: splitScreen, label: "Split screen", note: "Applies to all games; Automatic enables split screen only when partially folded", kind: .choice([SettingOption("auto", "Automatic"), SettingOption("on", "On"), SettingOption("off", "Off")]), value: ["auto", "on", "off"].contains(splitValue) ? splitValue : "auto"),
                SettingRow(id: screenOrientation, label: "Screen orientation", note: "Applies to all games; Automatic uses portrait for split screen and landscape otherwise", kind: .choice([SettingOption("auto", "Automatic"), SettingOption("landscape", "Landscape"), SettingOption("portrait", "Portrait")]), value: ["auto", "landscape", "portrait"].contains(direction) ? direction : "auto"),
                SettingRow(id: fps60, label: "60 FPS", note: "Off returns to the game’s own frame rate (usually 30 FPS) and saves power", kind: .toggle(on: "on", off: "off"), value: on60 ? "on" : "off"),
                SettingRow(id: widenForce, label: "Force widescreen", note: "Fills the screen even for unverified games; falls back to 16:9 if the picture stretches", kind: .toggle(on: "on", off: "off"), value: force ? "on" : "off"),
            ]),
            SettingSection(id: "s2a.vpad", title: "Virtual controller", rows: [
                SettingRow(id: layout, label: "Button layout", note: "Adjust normal and split positions separately; applies to this game only", kind: .choice(options), value: current),
                SettingRow(id: holdLock, label: "Hold-lock ZL / ZR", note: "Hold for 2 s to lock, tap again to unlock; this game only", kind: .toggle(on: "on", off: "off"), value: state.holdLock ? "on" : "off"),
                SettingRow(id: opacity, label: "Button opacity", note: "Shared by all games; takes effect the next time you enter a game", kind: .range(min: 10, max: 100, step: 5, unit: "%"), value: String(Int((op * 100).rounded()))),
            ]),
        ]
    }

    /// 改动：返回 true = 要打开布局编辑页（不是存值）
    @discardableResult
    public static func apply(id: String, setting: String, value: String, stores: Stores = .live) -> Bool {
        switch setting {
        case splitScreen: if ["auto", "on", "off"].contains(value) { stores.app.set(value, forKey: splitScreen); stores.app.removeObject(forKey: "S2ASplitScreen") }
        case screenOrientation: if ["auto", "landscape", "portrait"].contains(value) { stores.app.set(value, forKey: screenOrientation); stores.app.removeObject(forKey: "S2AScreenOrientation") }
        case fps60: stores.game(id)?.set(value == "on", forKey: "S2AFps60")
        case widenForce: stores.game(id)?.set(value == "on", forKey: "S2AWidenForce")
        case opacity: if let v = Double(value) { stores.app.set(min(1, max(0.1, v / 100)), forKey: "S2AVPadOpacity") }
        case holdLock: _ = id.withCString { s2a_shell_vpad_set_hold_lock($0, value == "on" ? 1 : 0) }
        case layout:
            if value == editLayout { return true }
            if value == "default" || value == "mine" { _ = id.withCString { i in value.withCString { s2a_shell_vpad_select(i, $0, 0) } } }
        default: break
        }
        return false
    }
}
