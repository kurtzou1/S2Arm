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

    public static func launcherText(_ id: String, language: String) -> String {
        launcherItems[id]?[language] ?? "[\(id)]"
    }

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

    public static func errorTitle(_ code: String, language: String) -> String? {
        errorTitles[code]?[language]
    }

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

    /// 对照表 + 共享规格。读一次；资源缺了或坏了是装包错误，直接停（同旧启动器）。
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

    /// 一句作业层文字在 language（"en" = 英文，其余 = 中文）下的显示。
    public static func translate(_ text: String, language: String) -> String { translate(text, language: language, depth: 0) }

    static func translate(_ text: String, language: String, depth: Int) -> String {
        guard !text.isEmpty, depth < 4 else { return text }
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
