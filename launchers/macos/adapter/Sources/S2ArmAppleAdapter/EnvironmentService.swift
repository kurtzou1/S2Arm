import Foundation

/// 环境检查的一项（preflight 作业 result.checks 的一项，同旧启动器 ToolCheck）。
public struct ToolCheck: Identifiable, Equatable {
    /// 稳定的英文检查项 id（作业层 toolchain.preflight 给：xcode / metal / ios_platform / apple_team …）；界面按它认项，不按中文 name（剃刀 M11）
    public let id: String
    public let name: String
    public let ok: Bool
    public let message: String
    /// 一键处理：appStoreXcode / openXcode / downloadMetal / downloadIosPlatform / installDotnet / systemUpdate / reinstall / library / prepareEngine；没有为 nil。
    public let action: String?
    /// system / apple / engine / bundled / storage。
    public let group: String
    /// 这项挡哪些事：prepare / launch / ipa。
    public let requiredFor: [String]
    /// 失败诊断的恢复码。
    public let code: String?

    public init(id: String? = nil, name: String, ok: Bool, message: String = "", action: String? = nil, group: String = "system",
                requiredFor: [String] = ["prepare"], code: String? = nil) {
        self.id = id ?? name; self.name = name; self.ok = ok; self.message = message; self.action = action; self.group = group
        self.requiredFor = requiredFor; self.code = code
    }

    public init?(json c: [String: Any]) {
        guard let id = c["id"] as? String, let name = c["name"] as? String, let ok = c["ok"] as? Bool else { return nil }
        let message = (c["help"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? c["message"] as? String ?? ""
        self.init(id: id, name: name, ok: ok, message: message, action: (c["action"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  group: c["group"] as? String ?? "system", requiredFor: c["requiredFor"] as? [String] ?? ["prepare", "launch"],
                  code: (c["diagnostic"] as? [String: Any])?["code"] as? String)
    }

    public func required(for scope: String) -> Bool { requiredFor.contains(scope) }
}

/// 一键处理怎么做：交给系统打开（App Store / Xcode / 系统设置 / 下载页）、交一个作业、选游戏库文件夹、或本前端没有入口。
public enum RepairStep: Equatable {
    case open(URL)
    case job(String)
    /// 选一个文件夹当游戏库（LibraryProvider.change）：界面开选目录面板。
    case chooseLibrary
    /// 组件已经下载、只是还没注册就绪：重新跑一遍环境检查，不再重复下载。
    case recheck
    case unavailable
}

/// 环境检查：交 preflight 作业，读清单；缺东西给一键处理（维护者 10-23：外部依赖只有 Xcode 与 Metal 组件，缺了一键跳官方页 / 一键下载）。
public final class EnvironmentService {
    private let client: JobClient
    private let xcodeLocator: () -> String?
    private let lock = NSLock()
    private var latest: [ToolCheck]?
    /// 最近一次检查的清单（还没查过为 nil）。async 作业回来的线程不定，读写都过锁。
    public var checks: [ToolCheck]? { lock.lock(); defer { lock.unlock() }; return latest }

    public static let appStoreXcode = URL(string: "macappstore://apps.apple.com/app/id497799835")!
    public static let softwareUpdate = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!
    public static let releases = URL(string: "https://github.com/jhaizhou-ops/S2Arm/releases")!

    public init(client: JobClient, xcodeLocator: @escaping () -> String? = XcodeLocator.detect) {
        self.client = client; self.xcodeLocator = xcodeLocator
    }

    /// 查一遍。先跟到装着的最新 Xcode（不让玩家选，同旧启动器 detectXcode；只改本进程的作业环境，不回写 preferences.json）。
    public func check(events: EventSink = .discard) async throws -> [ToolCheck] {
        if let found = xcodeLocator(), found != client.environment.developerDir { client.environment.developerDir = found }
        let outcome = try await client.perform("preflight", events: events)
        let list = (outcome.result["checks"] as? [[String: Any]] ?? []).compactMap(ToolCheck.init(json:))
        lock.withLock { latest = list }
        return list
    }

    /// 这件事（prepare / launch / ipa）的前提都齐了没有；还没查过算没齐。ignoring：这些一键处理的项不算（如 installDotnet：出 iPhone 包时适配层自己先装）。
    public func ready(for scope: String, ignoring actions: Set<String> = []) -> Bool {
        guard let checks, !checks.isEmpty else { return false }
        return checks.filter { $0.required(for: scope) && !actions.contains($0.action ?? "") }.allSatisfy(\.ok)
    }

    /// 一键处理的做法。
    public func repairStep(for action: String) -> RepairStep {
        switch action {
        case "appStoreXcode": return .open(Self.appStoreXcode)
        case "openXcode":
            // developerDir 是 <Xcode.app>/Contents/Developer：打开 Xcode.app 本身，玩家同意许可
            let dev = client.environment.developerDir
            guard !dev.isEmpty else { return .open(Self.appStoreXcode) }
            // 显式按目录建 URL：不让结果取决于这台机上 Xcode.app 在不在（fileURLWithPath 不给 isDirectory 时要查磁盘，11-07 gate-host 上测试红）
            let app = ((dev as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            return .open(URL(fileURLWithPath: app, isDirectory: true))
        case "downloadMetal", "downloadIosPlatform", "installDotnet": return .job(action)
        case "recheck": return .recheck   // 运行时已下载未注册：别让人再下 8 GB
        case "systemUpdate": return .open(Self.softwareUpdate)
        case "reinstall": return .open(Self.releases)
        case "library": return .chooseLibrary   // 游戏库在不支持的盘格式 / 云盘同步目录里：换游戏库
        default: return .unavailable   // prepareEngine（开发模式）本前端没有入口
        }
    }

    /// 交一键处理的作业（downloadMetal / downloadIosPlatform / installDotnet），做完重新查一遍。
    public func repair(_ action: String, events: EventSink = .discard) async throws -> [ToolCheck] {
        switch repairStep(for: action) {
        case .job(let operation):
            _ = try await client.perform(operation, events: events)
            return try await check()
        case .recheck:
            return try await check()
        case .open, .chooseLibrary, .unavailable:
            throw JobClientError("这一项不能在这里一键处理。")
        }
    }
}

/// 找装着的 Xcode（旧启动器 Store.detectXcode 原样迁出）：xcode-select 指的那份与 /Applications、~/Applications 里的 Xcode*.app，取版本最高的完整一份。
/// iPhone 包的着色器按目标设备系统大版本出，老 SDK 出不了新系统的，所以取最新。
public enum XcodeLocator {
    public static func detect() -> String? {
        func full(_ dev: String) -> Bool { FileManager.default.isExecutableFile(atPath: dev + "/usr/bin/xcodebuild") && dev.hasSuffix(".app/Contents/Developer") }
        var apps: [String] = []
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); p.arguments = ["-p"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let sel = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0, full(sel) { apps.append(String(sel.dropLast("/Contents/Developer".count))) }
        }
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix("Xcode") && name.hasSuffix(".app") {
                apps.append(dir + "/" + name)
            }
        }
        var best: (dev: String, version: String)?
        for app in apps {
            guard let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist"), info["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode",
                  full(app + "/Contents/Developer") else { continue }
            let v = info["CFBundleShortVersionString"] as? String ?? "0"
            if best == nil || v.compare(best!.version, options: .numeric) == .orderedDescending { best = (app + "/Contents/Developer", v) }
        }
        return best?.dev
    }
}
