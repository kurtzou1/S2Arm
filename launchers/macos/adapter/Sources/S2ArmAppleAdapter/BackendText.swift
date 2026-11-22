import Foundation

/// 作业层（pack/jobs）文字的显示翻译。作业记录、事件、报错一律存中文原句（缓存键、旧任务记录、存档都不随界面语言变），
/// 只在显示时翻：中英对照表 Localizable.json（source → en）+ 共享体验规格（launchers/shared/experience.v1.json）里的状态 / 结局 /
/// 画面模式 / 出包标签 / 阶段名。新旧两个 Mac 前端共用这一份（旧启动器的 L() 与新前端的作业页 / 环境检查 / 报错都调它）。
///
/// 翻法（自旧启动器 Localization 迁来，行为不变）：整句对照 → 带 {0} 占位的句式（占位里的值再翻）→ 按「\n」「；」拆开逐句翻再拼。
/// 认不出的原样显示。language 是 "en" 时译成英文；别的值当中文（英文原句反查回中文，中文原句原样）。
public enum BackendText {
    public struct Entry: Decodable, Equatable {
        public let source: String
        public let en: String
        public init(source: String, en: String) { self.source = source; self.en = en }
    }

    public struct ResourceError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// 本包资源包的名字（build_app.py 把它放进 .app 的 Contents/Resources）。
    public static let bundleName = "S2ArmAppleAdapter_S2ArmAppleAdapter.bundle"

    /// 资源包：.app 里只认 Contents/Resources 下那份（缺了明说，不退回源码路径）；swift run / swift test 用 SwiftPM 的 Bundle.module。
    public static func resourceBundle() throws -> Bundle {
        resourceReadsLock.lock(); resourceReads += 1; resourceReadsLock.unlock()
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let resources = Bundle.main.resourceURL,
                  let packaged = Bundle(url: resources.appendingPathComponent(bundleName)) else {
                throw ResourceError(message: "Resource bundle is missing: " + bundleName)
            }
            return packaged
        }
        return .module
    }

    /// 共享体验规格在资源包里的位置（旧启动器 SharedExperience 也从这里读完整规格）。
    public static func experienceURL() throws -> URL {
        guard let url = try resourceBundle().url(forResource: "experience.v1", withExtension: "json") else {
            throw ResourceError(message: "Specification is missing")
        }
        return url
    }

    /// 启动器界面文案（共享规格 launcher.items，Windows 客户端同一份）：id → 语言 → 文字。缺键显示 [键名]，同 Windows，不在客户端存副本。
    private static let launcherItems: [String: [String: String]] = {
        guard let data = try? Data(contentsOf: experienceURL()),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (spec["launcher"] as? [String: Any])?["items"] as? [[String: String]] else { return [:] }
        return Dictionary(items.compactMap { i in i["id"].map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
    }()

    /// 各语言叠加文案（launchers/shared/l10n/<语言>.json，资源包里叫 l10n.<语言>.json）：launcher 按 id、text 按简中原句。
    ///   读不到某门语言就当它还没翻（回落），不当装包错误：新语言可以分批补
    struct Overlay { var launcher: [String: String] = [:]; var text: [String: String] = [:] }
    private static let overlayLock = NSLock()
    nonisolated(unsafe) private static var overlays: [String: Overlay] = [:]
    static func overlay(_ language: String) -> Overlay {
        overlayLock.lock(); defer { overlayLock.unlock() }
        if let o = overlays[language] { return o }
        var o = Overlay()
        if let url = try? resourceBundle().url(forResource: "l10n." + language, withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            o.launcher = doc["launcher"] as? [String: String] ?? [:]
            o.text = doc["text"] as? [String: String] ?? [:]
        }
        overlays[language] = o
        return o
    }

    /// 启动时把对照表、界面文案和所有叠加语言一次读进内存。之后显示文字不再碰盘：
    ///   App 开着时包被挪走 / 删掉（拖进「应用程序」、更新换包的空档），首次显示某句报错才去读文件会读不到而停
    ///   （0.5.1 欢迎页崩溃）。资源真缺仍在这里当场停，装包错误照旧不放过
    public static func preload() {
        _ = entries; _ = english; _ = chinese; _ = forward; _ = reverse; _ = launcherItems; _ = installLandingActions
        let resources = (try? resourceBundle().resourceURL) ?? nil
        let names = resources.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        for name in names where name.hasPrefix("l10n.") && name.hasSuffix(".json") {
            _ = overlay(String(name.dropFirst("l10n.".count).dropLast(".json".count)))
        }
        for language in ["zh-Hans", "en"] { _ = overlay(language) }   // 简中 / 英文没有叠加文件：也先查一次、记空，之后不再去读资源包（同 510a74d1d 那份）
    }

    /// 这门语言还没翻的回落：繁中回落简中（中文读者看简中比英文顺），其余回落英文（11-14 i18n）
    static func fallback(_ language: String) -> String { language == "zh-Hant" ? "zh-Hans" : "en" }

    /// 界面文案：叠加文件 → 文案表里这门语言的列 → 回落语言 → 英文；键本身不存在才显示 [键名]
    public static func launcherText(_ id: String, language: String) -> String {
        guard let item = launcherItems[id] else { return "[\(id)]" }
        return overlay(language).launcher[id] ?? item[language] ?? item[fallback(language)] ?? item["en"] ?? "[\(id)]"
    }

    /// 装机前清单按钮落点的动作表（共享规格 install_landing.actions，Windows SharedText.InstallActionLabel 同一处）：动作名 → 按钮文案键；
    ///   值为 nil = 表里写 null（这一端自画文案）。不在表里的动作不画按钮、不派发（两端不另写一份动作表）
    public static let installLandingActions: [String: String?] = {
        guard let data = try? Data(contentsOf: experienceURL()),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actions = (spec["install_landing"] as? [String: Any])?["actions"] as? [String: Any] else { return [:] }
        return actions.mapValues { $0 as? String }
    }()

    /// 报错页统一的一句「故障报修」指引（11-13）：文字只在共享规格 report.hint 一处，{button} 换成顶栏按钮名 report.button（Windows SharedText.ReportHint 同一取法）
    public static func reportHint(language: String) -> String {
        launcherText("report.hint", language: language).replacingOccurrences(of: "{button}", with: launcherText("report.button", language: language))
    }

    private static let errorTitles: [String: [String: String]] = {
        guard let data = try? Data(contentsOf: experienceURL()),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = spec["errors"] as? [String: Any],
              let items = errors["items"] as? [[String: Any]] else { return [:] }
        return Dictionary(items.compactMap { item in
            guard let code = item["code"] as? String, let title = item["title"] as? [String: String] else { return nil }
            return (code, title)
        }, uniquingKeysWith: { first, _ in first })
    }()

    /// 指代「这一台」的共享文案用 {0} 占位设备类型（#1962，同作业层 errors.on_device）：iPad / iPhone 照填，认不出（空、nil）填「iPhone / iPad」
    public static func deviceKind(_ kind: String?) -> String {
        switch kind?.lowercased() {
        case "ipad": return "iPad"
        case "iphone": return "iPhone"
        default: return "iPhone / iPad"
        }
    }

    /// 错误码的标题（共享规格 errors.items）；指代这一台的标题里 {0} 填 device（作业结果 deviceKind / 总控台 kind），不知道是哪台填「iPhone / iPad」
    public static func errorTitle(_ code: String, language: String, device: String? = nil) -> String? {
        errorTitles[code]?[language]?.replacingOccurrences(of: "{0}", with: deviceKind(device))
    }

    /// 两端共用的表只在共享体验表一处（11-19 结构 9：Mac / Windows 原先各写一份，Mac 缺 cert_revoke_confirm、两端缺 shaderMiss）：
    /// 可确认停装码 → 玩家点「仍然继续」后重发带的参数 = errors 各码的 accept（带 accept_ui 的由专门页面带，不进通用确认）
    public static let confirmFlags: [String: String] = {
        guard let data = try? Data(contentsOf: experienceURL()),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = spec["errors"] as? [String: Any],
              let items = errors["items"] as? [[String: Any]] else { return [:] }
        return Dictionary(items.compactMap { item in
            guard let code = item["code"] as? String, let accept = item["accept"] as? String, item["accept_ui"] == nil else { return nil }
            return (code, accept)
        }, uniquingKeysWith: { first, _ in first })
    }()

    /// 确认页上与「仍然继续」并列的另一条路 = errors 各码的 alternate（自签走查结构 7：新建证书确认可「改用已有证书」）：
    ///   码 → (action：装机前清单动作表 install_landing.actions 里的动作名，点了走同一个派发、不重发；labelKey：按钮文案键)
    public static let confirmAlternates: [String: (action: String, labelKey: String)] = {
        guard let data = try? Data(contentsOf: experienceURL()),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = spec["errors"] as? [String: Any],
              let items = errors["items"] as? [[String: Any]] else { return [:] }
        return Dictionary(items.compactMap { item in
            guard let code = item["code"] as? String, let alt = item["alternate"] as? [String: Any],
                  let action = alt["action"] as? String, let label = alt["label"] as? String else { return nil }
            return (code, (action: action, labelKey: label))
        }, uniquingKeysWith: { first, _ in first })
    }()

    /// 「建议更新」原因 → 共享文案键 = update_reasons（不认识的原因不显示）
    public static let updateReasonKeys: [String: String] = {
        guard let data = try? Data(contentsOf: experienceURL()),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reasons = spec["update_reasons"] as? [String: Any] else { return [:] }
        return reasons.compactMapValues { $0 as? String }.filter { $0.key != "note" }
    }()

    /// 共享规格里要进翻译表的那些中英文（同旧启动器 SharedExperience.translations 的取法）：
    /// running / failed 两个状态名、作业结局（成功 / 取消）、出包画面模式标签、阶段名。
    public static func sharedEntries(_ data: Data) throws -> [Entry] {
        guard let spec = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResourceError(message: "Specification is not an object")
        }
        func text(_ value: Any?) throws -> Entry {
            guard let t = value as? [String: Any], let zh = t["zh-Hans"] as? String, let en = t["en"] as? String,
                  !zh.isEmpty, !en.isEmpty else { throw ResourceError(message: "Shared presentation text is invalid") }
            return Entry(source: zh, en: en)
        }
        let states = spec["states"] as? [[String: Any]] ?? []
        let results = (spec["event_map"] as? [String: Any])?["terminal_results"] as? [String: Any] ?? [:]
        let labels = (spec["pack_graphics_mode"] as? [String: Any])?["labels"] as? [String: Any] ?? [:]
        let stages = spec["stage_labels"] as? [String: Any] ?? [:]
        var entries: [Entry] = []
        for state in states where ["running", "failed"].contains(state["id"] as? String ?? "") { entries.append(try text(state["title"])) }
        for id in ["job.succeeded", "job.cancelled"] { entries.append(try text((results[id] as? [String: Any])?["title"])) }
        for key in labels.keys.sorted() { entries.append(try text(labels[key])) }
        for key in stages.keys.sorted() { entries.append(try text(stages[key])) }
        return entries
    }

    /// 读资源包的次数（单测核：preload 之后再翻译 / 取界面文案一次都不读盘）
    private static let resourceReadsLock = NSLock()
    nonisolated(unsafe) static var resourceReads = 0

    /// 对照表 + 共享规格。读一次（App 启动时 preload 读）；资源缺了或坏了是装包错误，直接停（同旧启动器）。
    public static let entries: [Entry] = {
        do {
            let bundle = try resourceBundle()
            guard let table = bundle.url(forResource: "Localizable", withExtension: "json") else {
                throw ResourceError(message: "Localizable.json is missing")
            }
            let own = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: table))
            let shared = try sharedEntries(Data(contentsOf: experienceURL()))
            if !Set(own.map(\.source)).isDisjoint(with: Set(shared.map(\.source))) {
                throw ResourceError(message: "Localizable.json duplicates shared experience text")
            }
            return own + shared
        } catch {
            preconditionFailure("S2Arm localization resources: \(error.localizedDescription)")
        }
    }()

    private struct Pattern {
        let regex: NSRegularExpression
        let indices: [Int]
        let replacement: String
        static let slots = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)

        init?(_ template: String, replacement: String) {
            let ns = template as NSString
            let matches = Self.slots.matches(in: template, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return nil }
            var pattern = "\\A", cursor = 0, indices: [Int] = []
            for match in matches {
                pattern += NSRegularExpression.escapedPattern(for: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))) + "(.*?)"
                indices.append(Int(ns.substring(with: match.range(at: 1)))!)
                cursor = NSMaxRange(match.range)
            }
            pattern += NSRegularExpression.escapedPattern(for: ns.substring(from: cursor)) + "\\z"
            regex = try! NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
            self.indices = indices; self.replacement = replacement
        }

        func apply(_ text: String, language: String, depth: Int) -> String? {
            let ns = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
            // 按模板拼，不在原句上替换：玩家给的值里可能有花括号、$、%、换行
            var arguments: [Int: String] = [:]
            for (group, index) in indices.enumerated() {
                arguments[index] = BackendText.translate(ns.substring(with: match.range(at: group + 1)), language: language, depth: depth + 1)
            }
            let template = replacement as NSString
            var result = "", cursor = 0
            for slot in Self.slots.matches(in: replacement, range: NSRange(location: 0, length: template.length)) {
                result += template.substring(with: NSRange(location: cursor, length: slot.range.location - cursor))
                result += arguments[Int(template.substring(with: slot.range(at: 1)))!] ?? ""
                cursor = NSMaxRange(slot.range)
            }
            return result + template.substring(from: cursor)
        }
    }

    private static let english = Dictionary(entries.map { ($0.source, $0.en) }, uniquingKeysWith: { first, _ in first })
    private static let chinese = Dictionary(entries.map { ($0.en, $0.source) }, uniquingKeysWith: { first, _ in first })
    private static func specificity(_ template: String) -> Int {
        template.replacingOccurrences(of: #"\{\d+\}"#, with: "", options: .regularExpression).count
    }
    private static let forward = entries.sorted { specificity($0.source) > specificity($1.source) }.compactMap { Pattern($0.source, replacement: $0.en) }
    private static let reverse = entries.sorted { specificity($0.en) > specificity($1.en) }.compactMap { Pattern($0.en, replacement: $0.source) }

    /// 一句作业层文字在 language 下的显示：en 英文；zh-Hans（及没认出的值）中文原句；其余（zh-Hant / ja / es / fr …）查这门语言的叠加文件，
    ///   没翻的句子回落（繁中回落简中原句、其余回落英文）
    public static func translate(_ text: String, language: String) -> String { translate(text, language: language, depth: 0) }

    /// 叠加语言的整句表与句式：原句 → 叠加译文，没有就回落
    private struct Localized { let whole: [String: String]; let patterns: [Pattern] }
    private static let localizedLock = NSLock()
    nonisolated(unsafe) private static var localized: [String: Localized] = [:]
    private static func localizedTable(_ language: String) -> Localized {
        localizedLock.lock(); defer { localizedLock.unlock() }
        if let t = localized[language] { return t }
        let text = overlay(language).text, chineseFallback = fallback(language) == "zh-Hans"
        func target(_ e: Entry) -> String { text[e.source] ?? (chineseFallback ? e.source : e.en) }
        let whole = Dictionary(entries.map { ($0.source, target($0)) }, uniquingKeysWith: { first, _ in first })
        let patterns = entries.sorted { specificity($0.source) > specificity($1.source) }.compactMap { Pattern($0.source, replacement: target($0)) }
        let t = Localized(whole: whole, patterns: patterns)
        localized[language] = t
        return t
    }

    static func translate(_ text: String, language: String, depth: Int) -> String {
        guard !text.isEmpty, depth < 4 else { return text }
        if language != "en" && !(language.hasPrefix("zh") && language != "zh-Hant") {   // 叠加语言（含还没翻的：整表回落）
            let table = localizedTable(language)
            if let result = table.whole[text] { return result }
            for pattern in table.patterns {
                if let result = pattern.apply(text, language: language, depth: depth) { return result }
            }
            for separator in ["\n", "；"] where text.contains(separator) {
                let pieces = text.components(separatedBy: separator)
                let translated = pieces.map { translate($0, language: language, depth: depth + 1) }
                if translated != pieces { return translated.joined(separator: separator == "；" && !language.hasPrefix("zh") && language != "ja" ? "; " : separator) }
            }
            return text
        }
        if language == "en" {
            if let result = english[text] { return result }
            if text.range(of: #"[\p{Han}]"#, options: .regularExpression) == nil { return text }
        } else {
            if english[text] != nil { return text }
            if let result = chinese[text] { return result }
        }
        for pattern in language == "en" ? forward : reverse {
            if let result = pattern.apply(text, language: language, depth: depth) { return result }
        }
        // 检查要求、报错可能是几句定句拼起来的
        for separator in ["\n", "；"] where text.contains(separator) {
            let pieces = text.components(separatedBy: separator)
            let translated = pieces.map { translate($0, language: language, depth: depth + 1) }
            if translated != pieces { return translated.joined(separator: separator == "；" && language == "en" ? "; " : separator) }
        }
        return text
    }
}
