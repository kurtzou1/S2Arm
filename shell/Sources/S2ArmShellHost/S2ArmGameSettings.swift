import Foundation
import S2ArmShellBridge
import ShellUI

/// 每款游戏的设置行（11-07 维护者：游戏库按住游戏 / 点设置弹出；虚拟手柄布局进二级页，全部按键透明度一个全局拉杆）。
/// 只放数据：上游 GameDetailView 原样画（开关 / 多选 / 拉杆），改动经 ShellActions.onChange 回到这里。
///
/// 存哪：
/// - 60 帧 / 满屏 / 社区补丁 / 金手指（11-13 维护者：长按设置里也要有，并记住选择）：读写都经宿主 ios/game_options.m
///   （s2a_shell_game_options_json / s2a_shell_game_option_set），与游戏内设置页、社区补丁页、金手指面板同一份存储同一口径，
///   这里不自己读偏好、不自己判缺省（60 帧没选过按包里清单、满屏没选过按已验证名单，都在宿主）
/// - 按键透明度：App 级 `S2AVPadOpacity`（0.1–1，缺省 1），全部游戏共用；宿主 ios/vpad.m 进游戏时读
/// - 虚拟手柄布局：按游戏，走 C 接口 s2a_shell_vpad_*（宿主 ios/vpad_shell.m），与游戏内拖动编辑同一份文件
public enum S2ArmGameSettings {
    public static let fps60 = "fps60", fpsPick = "fpsPick", volume = "gameVolume", gameLanguage = "gameLanguage", fullscreen = "fullscreen", opacity = "vpadOpacity", layout = "vpadLayout", holdLock = "vpadHoldLock", identity = "gameIdentity", editIdentity = "edit"
    /// 社区补丁 / 金手指的行号前缀（后接补丁编号 / 「文件名/条目名」）
    public static let patchPrefix = "patch.", cheatPrefix = "cheat."
    /// 布局多选里打开二级编辑页的那一项（不是一个方案）
    public static let editLayout = "edit"
    public static let splitScreen = "splitScreen", screenOrientation = "screenOrientation"
    /// 输出设备类型 + 两个虚拟环绕开关（#189 后续，5.1 虚拟环绕第二片；定义表 game_settings.v1.json 的同 id 项，本文件不另写文案与缺省）
    public static let audioDevice = "audioDevice", vsSpeakers = "vsSpeakers", vsHeadphones = "vsHeadphones"
    /// S4「SDR 转 HDR」（#625 第二阶段 PR-B 评审终稿；定义表 game_settings.v1.json 的同 id 项，iOS 独有、只放每款游戏的设置页——Mac v1 只有环境开关 S2A_HDR_SDR_MAP）
    public static let hdrSdrMap = "hdrSdrMap"

    /// 宿主给的这款画面与金手指选项（ios/game_options.m 的 JSON）
    public struct Options: Equatable, Sendable {
        /// title：宿主给了就用它当这一行的名字（补丁接管时「帧率」），没给用缺省（「60 FPS」/「Full screen」）
        /// hidden：这款没有对应的社区补丁（11-13 起只用补丁，没有补丁 = 原生游戏），这一行不出
        /// levels / pick / levelsTitle：帧率档位（11-13：60 / 120 帧补丁都带进去，玩家自选；两档以上宿主才给，第一项「自动」值 "0"）
        public struct Level: Equatable, Sendable { public var value: String; public var label: String }
        public struct Switch: Equatable, Sendable { public var on: Bool; public var enabled = true; public var note = ""; public var title = ""; public var hidden = false; public var levels: [Level] = []; public var pick = "0"; public var levelsTitle = "" }
        public struct Item: Equatable, Sendable { public var id: String; public var title: String; public var note = ""; public var on: Bool }
        public var fps: Switch; public var fullscreen: Switch; public var patches: [Item] = []; public var cheats: [Item] = []
        /// 游戏音量 0–100（#1186，同齿轮菜单「声音」）；宿主没给 = nil，不出这一行
        public var volume: Int? = nil
        /// 游戏语言（#1252，同游戏内设置页「游戏语言」）：levels 第一项跟随系统（"system"），只列这款支持的；note = 选的这款不支持时起局用哪种。宿主没给 = nil，不出这一行
        public struct Language: Equatable, Sendable { public var pick: String; public var levels: [Level]; public var note = "" }
        public var language: Language? = nil
        /// 输出设备类型 + 两个虚拟环绕开关（#189 后续，5.1 虚拟环绕第二片；按游戏存，ios/game_options.m 读写）：
        ///   device = "auto"（没选 = 按设备真实声道判，5.1 直通缺省不变）/ "builtin" / "headphones" / "external"；
        ///   两个开关各存各的、只在对应类型下生效（驱动侧判），没拨过按关。宿主没给 = nil，这三行不出
        public struct Audio: Equatable, Sendable { public var device: String; public var vsSpeakers: Bool; public var vsHeadphones: Bool }
        public var audio: Audio? = nil
        /// S4「SDR 转 HDR」（#625 第二阶段 PR-B 评审终稿；按款存 S2AHdrSdrMap，宿主 ios/game_options.m 给标题与说明——值照宿主给的）。宿主没给 = nil，不出这一行
        public var hdrSdrMap: Switch? = nil
        public init(fps: Switch, fullscreen: Switch, patches: [Item] = [], cheats: [Item] = [], audio: Audio? = nil, hdrSdrMap: Switch? = nil) { self.fps = fps; self.fullscreen = fullscreen; self.patches = patches; self.cheats = cheats; self.audio = audio; self.hdrSdrMap = hdrSdrMap }
        static func parse(_ json: String) -> Options? {
            guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
            func sw(_ v: Any?) -> Switch {
                let d = v as? [String: Any] ?? [:]
                let lv = (d["levels"] as? [[String: Any]] ?? []).compactMap { e in (e["value"] as? String).map { Level(value: $0, label: e["label"] as? String ?? $0) } }
                return Switch(on: d["on"] as? Bool ?? false, enabled: d["enabled"] as? Bool ?? true, note: d["note"] as? String ?? "", title: d["title"] as? String ?? "", hidden: d["hidden"] as? Bool ?? false,
                              levels: lv, pick: d["pick"] as? String ?? "0", levelsTitle: d["levelsTitle"] as? String ?? "")
            }
            func items(_ v: Any?, _ idKey: String, _ titleKey: String) -> [Item] {
                (v as? [[String: Any]] ?? []).compactMap { d in (d[idKey] as? String).map { Item(id: $0, title: d[titleKey] as? String ?? $0, note: d["note"] as? String ?? "", on: d["on"] as? Bool ?? false) } }
            }
            var out = Options(fps: sw(o["fps"]), fullscreen: sw(o["fullscreen"]), patches: items(o["patches"], "id", "title"), cheats: items(o["cheats"], "key", "name"))
            out.volume = (o["volume"] as? NSNumber)?.intValue
            if let l = o["language"] as? [String: Any] {
                let lv = (l["levels"] as? [[String: Any]] ?? []).compactMap { e in (e["value"] as? String).map { Level(value: $0, label: e["label"] as? String ?? $0) } }
                if !lv.isEmpty { out.language = Language(pick: l["pick"] as? String ?? "system", levels: lv, note: l["note"] as? String ?? "") }
            }
            if let a = o["audio"] as? [String: Any] {
                let device = (a["device"] as? String).flatMap { ["auto", "builtin", "headphones", "external"].contains($0) ? $0 : nil } ?? "auto"
                out.audio = Audio(device: device, vsSpeakers: (a["vsSpeakers"] as? Bool) ?? false, vsHeadphones: (a["vsHeadphones"] as? Bool) ?? false)
            }
            if let h = o["hdrSdrMap"] as? [String: Any] { out.hdrSdrMap = sw(h) }   // S4「SDR 转 HDR」（#625 第二阶段 PR-B 评审终稿）：宿主按款给的布尔行
            return out
        }
    }

    /// 存偏好的地方；单测换成临时 suite 与桩
    public struct Stores {
        public var game: (String) -> UserDefaults?
        public var app: UserDefaults
        public var options: (String) -> Options?
        public var setOption: (String, String, String, Bool) -> Bool
        public init(game: @escaping (String) -> UserDefaults?, app: UserDefaults,
                    options: @escaping (String) -> Options? = { _ in nil }, setOption: @escaping (String, String, String, Bool) -> Bool = { _, _, _, _ in false }) {
            self.game = game; self.app = app; self.options = options; self.setOption = setOption
        }
        public static var live: Stores {
            Stores(game: { UserDefaults(suiteName: "S2AGame." + $0) }, app: .standard,
                   options: { id in
                       guard let p = id.withCString({ s2a_shell_game_options_json($0) }) else { return nil }
                       defer { free(p) }
                       return Options.parse(String(cString: p)) },
                   setOption: { id, kind, key, on in id.withCString { i in kind.withCString { k in key.withCString { s2a_shell_game_option_set(i, k, $0, on ? 1 : 0) } } } == 1 })
        }
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
        let op = (stores.app.object(forKey: "S2AVPadOpacity") as? Double).map { min(1, max(0.1, $0)) } ?? 1
        var options = [SettingOption("default", "Default layout")]
        if state.hasMine { options.append(SettingOption("mine", "My layout")) }
        options.append(SettingOption(editLayout, "Adjust positions…"))
        let current = state.selected == "mine" && state.hasMine ? "mine" : "default"
        let splitValue = playChoice(splitScreen, legacy: "S2ASplitScreen", values: ["auto", "on", "off"], app: stores.app)
        let direction = playChoice(screenOrientation, legacy: "S2AScreenOrientation", values: ["auto", "landscape", "portrait"], app: stores.app)
        func toggle(_ id: String, _ label: String, _ s: Options.Switch) -> SettingRow {
            SettingRow(id: id, label: label, note: s.note, kind: .toggle(on: "on", off: "off"), value: s.on ? "on" : "off", enabled: s.enabled)
        }
        #if os(tvOS)
        // 电视：没有改名字和封面（tvOS 没有相册选图）、没有分屏 / 屏幕朝向（折叠屏与手机转向才有），也没有触屏虚拟手柄（见下）
        _ = (splitValue, direction)
        var out: [SettingSection] = []
        var picture: [SettingRow] = []
        #else
        var out = [SettingSection(id: "s2a.identity", title: "Display", rows: [
            SettingRow(id: identity, label: "Name and Cover", note: "Only changes how it appears on this iPhone", kind: .choice([SettingOption("current", state.customIdentity ? "Customized" : "Default"), SettingOption(editIdentity, "Edit…")]), value: "current"),
        ])]
        // 画面：分屏 / 朝向是所有游戏共用的 App 级选择，一直出；60 帧 / 满屏要宿主读得到（Mac 单测没链宿主、游戏号不合规就不出这两行，不拿猜的缺省冒充实际状态）
        var picture = [
            SettingRow(id: splitScreen, label: "Split screen", note: "Applies to all games; Automatic enables split screen only when partially folded", kind: .choice([SettingOption("auto", "Automatic"), SettingOption("on", "On"), SettingOption("off", "Off")]), value: ["auto", "on", "off"].contains(splitValue) ? splitValue : "auto"),
            SettingRow(id: screenOrientation, label: "Screen orientation", note: "Applies to all games; Automatic uses portrait for split screen and landscape otherwise", kind: .choice([SettingOption("auto", "Automatic"), SettingOption("landscape", "Landscape"), SettingOption("portrait", "Portrait")]), value: ["auto", "landscape", "portrait"].contains(direction) ? direction : "auto"),
        ]
        #endif
        let o = stores.options(id)
        if let o {
            if !o.fps.hidden { picture.append(toggle(fps60, o.fps.title.isEmpty ? "60 FPS" : o.fps.title, o.fps)) }
            if !o.fps.hidden && o.fps.levels.count > 1 {
                picture.append(SettingRow(id: fpsPick, label: o.fps.levelsTitle.isEmpty ? "Frame rate level" : o.fps.levelsTitle, note: "",
                                          kind: .choice(o.fps.levels.map { SettingOption($0.value, $0.label) }), value: o.fps.levels.contains { $0.value == o.fps.pick } ? o.fps.pick : "0"))
            }
            if !o.fullscreen.hidden { picture.append(toggle(fullscreen, o.fullscreen.title.isEmpty ? "Full screen" : o.fullscreen.title, o.fullscreen)) }
            // S4「SDR 转 HDR」（#625 第二阶段 PR-B 评审终稿：只放每款游戏的设置页）：宿主给了才出（老宿主 / 这款读不到不给，不拿猜的缺省冒充实际状态）；标题 / 说明宿主已按语言给好
            if let h = o.hdrSdrMap { picture.append(toggle(hdrSdrMap, h.title.isEmpty ? "SDR to HDR" : h.title, h)) }
        }
        if !picture.isEmpty { out.append(SettingSection(id: "s2a.picture", title: "Picture", rows: picture)) }
        if let o {
            if !o.patches.isEmpty {
                out.append(SettingSection(id: "s2a.patches", title: "Community patches", rows: o.patches.map {
                    SettingRow(id: patchPrefix + $0.id, label: $0.title, note: $0.note, kind: .toggle(on: "on", off: "off"), value: $0.on ? "on" : "off") }))
            }
            if !o.cheats.isEmpty {
                out.append(SettingSection(id: "s2a.cheats", title: "Cheats", rows: o.cheats.map {
                    SettingRow(id: cheatPrefix + $0.id, label: $0.title, note: $0.note, kind: .toggle(on: "on", off: "off"), value: $0.on ? "on" : "off") }))
            }
        }
        // 声音（#1186）：游戏音量五档，同齿轮菜单；静音就是 0 那一档，不另设开关
        var sound: [SettingRow] = []
        if let v = o?.volume {
            let levels = [0, 25, 50, 75, 100]
            sound.append(SettingRow(id: volume, label: "Game volume", note: "This game only; doesn't change the system volume or other apps",
                           kind: .choice(levels.map { SettingOption(String($0), $0 == 0 ? "Mute" : "\($0)%") }),
                           value: String(levels.min { abs($0 - v) < abs($1 - v) } ?? 100)))
        }
        // 输出设备类型 + 两个虚拟环绕开关（#189 后续，5.1 虚拟环绕第二片，定义表 game_settings.v1.json 同一份定义）：按游戏存（经宿主），
        //   device "auto" = 没选 = 按设备真实声道判（5.1 直通缺省不变）；两个开关只在对应类型下可用（external / 没选时置灰，
        //   external 的说明 = ≥6 声道直通、<6 普通下混、不使用虚拟环绕）。起局 ios/settings.m 落成 S2A_AUDIO_*，下次启动生效
        if let a = o?.audio {
            sound.append(SettingRow(id: audioDevice, label: "Output device",
                                     note: "Pick what the sound plays on; Automatic follows the output device's channels (6 or more passes 5.1 through). Takes effect the next time this game starts.",
                                     kind: .choice([SettingOption("auto", "Automatic"), SettingOption("builtin", "Built-in speakers"),
                                                    SettingOption("headphones", "Headphones"), SettingOption("external", "External / TV speakers")]),
                                     value: a.device))
            let offNote = a.device == "external"
                ? "6-channel devices pass 5.1 through; fewer channels fold down to stereo. No virtual surround."
                : "Only while the device type is Built-in speakers."
            sound.append(SettingRow(id: vsSpeakers, label: "Speaker virtual surround",
                                    note: a.device == "builtin" ? "The game outputs 5.1; S2Arm folds it back to the speakers with spatial audio." : offNote,
                                    kind: .toggle(on: "on", off: "off"), value: a.vsSpeakers ? "on" : "off", enabled: a.device == "builtin"))
            sound.append(SettingRow(id: vsHeadphones, label: "Headphone virtual surround",
                                    note: a.device == "headphones" ? "The game outputs 5.1; S2Arm folds it back to the headphones with binaural rendering."
                                        : a.device == "external" ? offNote : "Only while the device type is Headphones.",
                                    kind: .toggle(on: "on", off: "off"), value: a.vsHeadphones ? "on" : "off", enabled: a.device == "headphones"))
        }
        if !sound.isEmpty { out.append(SettingSection(id: "s2a.sound", title: "Sound", rows: sound)) }
        // 游戏语言（#1252）：开局前在这里选好，进游戏直接生效，不用先进游戏再重开
        if let l = o?.language {
            var row = SettingRow(id: gameLanguage, label: "Game language", note: "This game only; takes effect when the game starts", kind: .choice(l.levels.map { SettingOption($0.value, $0.label) }),
                                 value: l.levels.contains { $0.value == l.pick } ? l.pick : "system")
            if !l.note.isEmpty { row.note += " · " + l.note }   // 宿主那句已按当前语言，不再查表
            out.append(SettingSection(id: "s2a.language", title: "Language", rows: [row]))
        }
        #if !os(tvOS)   // 触屏虚拟手柄（布局 / 按住锁定 / 透明度）：电视上没有触屏
        out.append(SettingSection(id: "s2a.vpad", title: "Virtual controller", rows: [
            SettingRow(id: layout, label: "Button layout", note: "Adjust normal and split positions separately; applies to this game only", kind: .choice(options), value: current),
            SettingRow(id: holdLock, label: "Hold-lock ZL / ZR", note: "Hold for 2 s to lock, tap again to unlock; this game only", kind: .toggle(on: "on", off: "off"), value: state.holdLock ? "on" : "off"),
            SettingRow(id: opacity, label: "Button opacity", note: "Shared by all games; takes effect the next time you enter a game", kind: .range(min: 10, max: 100, step: 5, unit: "%"), value: String(Int((op * 100).rounded()))),
        ]))
        #else
        _ = (op, options, current)
        #endif
        return out
    }

    /// 改动：返回 true = 要打开布局编辑页（不是存值）
    @discardableResult
    public static func apply(id: String, setting: String, value: String, stores: Stores = .live) -> Bool {
        switch setting {
        case splitScreen: if ["auto", "on", "off"].contains(value) { stores.app.set(value, forKey: splitScreen); stores.app.removeObject(forKey: "S2ASplitScreen") }
        case screenOrientation: if ["auto", "landscape", "portrait"].contains(value) { stores.app.set(value, forKey: screenOrientation); stores.app.removeObject(forKey: "S2AScreenOrientation") }
        case fps60: _ = stores.setOption(id, "fps", "", value == "on")
        case fpsPick: _ = stores.setOption(id, "fpspick", value, true)
        case volume: if Int(value) != nil { _ = stores.setOption(id, "volume", value, true) }
        case audioDevice: _ = stores.setOption(id, "audiodevice", value, true)   // "auto" = 未选择（宿主删掉这款的值）
        case vsSpeakers: _ = stores.setOption(id, "audiovs", "speakers", value == "on")
        case vsHeadphones: _ = stores.setOption(id, "audiovs", "headphones", value == "on")
        case gameLanguage: _ = stores.setOption(id, "language", value, true)
        case fullscreen: _ = stores.setOption(id, "fullscreen", "", value == "on")
        case hdrSdrMap: _ = stores.setOption(id, "hdrsdrmap", "", value == "on")   // S4「SDR 转 HDR」（#625 第二阶段 PR-B 评审终稿）：按款布尔行，下次起局生效
        case _ where setting.hasPrefix(patchPrefix): _ = stores.setOption(id, "patch", String(setting.dropFirst(patchPrefix.count)), value == "on")
        case _ where setting.hasPrefix(cheatPrefix): _ = stores.setOption(id, "cheat", String(setting.dropFirst(cheatPrefix.count)), value == "on")
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
