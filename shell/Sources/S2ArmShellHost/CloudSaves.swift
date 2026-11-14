import Foundation
import S2ArmShellBridge
import SaveSync
import ShellUI

/// iCloud 存档同步的 iOS 一侧（方案见 launchers/shared/SaveSync）：
///   玩家在库设置「云存档」里选 iCloud 云盘的一个文件夹（Mac 上选同一个），书签存在 ShellSettingsStore；
///   选好游戏、起宿主之前，宿主（ios/app.m）问 s2a_shell_cloud_sync_vc 要同步页：导出本地存档 → 和云盘比 → 上传 / 下载恢复 / 冲突让玩家选。
///   存档作业全部走服务层 S2A_SaveTransfer（经 s2a_shell_save_request），这里不碰存档目录。同步失败不改本地存档，照常开始游戏。
///   限制（直说）：游戏和库同进程，游戏运行中不导出，手机上玩完要下次打开 App 选游戏时才上传。
enum CloudSaves {
    static let deviceKey = "S2ASaveSync.device"

    /// 选的云盘文件夹此刻能不能用：没开 / 能用（书签解析成功、已开始访问、目录读得出）/ 授权失效（带一句给玩家看的原因）
    enum Access { case off, ready(URL), lost(String) }
    /// 授权失效（11-13 玩家反馈：自签后选不了之前用的 iCloud 文件夹，Code=257）：书签绑的是当初签名时的 App 身份，换证书重签后系统不认旧授权——
    ///   书签解析失败、或解析得出但读目录被拒（NSFileReadNoPermissionError 257）。原先只记日志返回 nil，这次同步悄悄跳过、玩家看不到原因
    /// 本次运行里玩家刚选的文件夹（选择器给的 URL 本进程内一直能访问）：书签存不上时也照样用它，玩家选了就能用，不让他换别的文件夹
    nonisolated(unsafe) static var picked: URL?   // 只在主线程读写（选择器回调、起局前同步页、库设置）
    static var enabled: Bool { picked != nil || ShellSettingsStore.current.cloudSavesBookmark != nil }
    static func access(_ store: ShellSettingsStore = .current) -> Access {
        if let picked { return .ready(picked) }
        guard let data = store.cloudSavesBookmark else { return .off }   // 没开云存档：正常情况，不打日志
        var stale = false
        let url: URL
        do { url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) }
        catch { NSLog("S2Arm 云存档：【红】读不出选的文件夹（书签 %d 字节）：%@", data.count, String(describing: error)); return .lost(lostReason) }
        let scoped = url.startAccessingSecurityScopedResource()
        // 试读一次目录：解析得出但系统不给访问的（换签名后旧授权不认）在这里就暴露，不拖到同步中途才报
        do { _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
        catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            NSLog("S2Arm 云存档：【红】选的文件夹 %@ 打不开（访问授权 %@）：%@", url.lastPathComponent, scoped ? "拿到" : "没拿到", String(describing: error))
            return .lost(lostReason)
        }
        NSLog("S2Arm 云存档：文件夹 %@（%@，访问授权 %@）", url.lastPathComponent, stale ? "书签已过期、已刷新" : "书签有效", scoped ? "拿到" : "没拿到")
        if stale, let fresh = try? url.bookmarkData() { store.defaults.set(fresh, forKey: ShellSettingsStore.cloudSavesKey) }
        return .ready(url)
    }
    static var lostReason: String { shellText("The system no longer lets S2Arm open the iCloud folder you chose before (this happens after the app is signed again with a different certificate). Choose the same folder again to keep syncing.") }

    /// 收下玩家选的文件夹：选了就能用（本进程内一直访问它、设置里显示它的名字），再尽量存书签留给下次打开 App。
    ///   书签存不上（11-13 玩家反馈：自签后选之前用的 iCloud 文件夹，点「打开」没反应）只记日志、不拦：这次照常同步，下次授权没了时同步页让他点一下重新选同一个。返回书签存没存上
    @discardableResult static func remember(_ url: URL, store: ShellSettingsStore = .current) -> Bool {
        _ = url.startAccessingSecurityScopedResource()   // 不停：本进程内一直访问（进程结束系统收回）
        picked = url
        store.storeCloudSavesFolderName(url.lastPathComponent)
        do { store.defaults.set(try url.bookmarkData(), forKey: ShellSettingsStore.cloudSavesKey); return true }
        catch { NSLog("S2Arm 云存档：【红】选的文件夹 %@ 书签没存上（这次照常用）：%@", url.lastPathComponent, String(describing: error)); return false }
    }

    static func forget(store: ShellSettingsStore = .current) {
        picked = nil
        store.defaults.removeObject(forKey: ShellSettingsStore.cloudSavesKey)
        store.clearCloudSavesFolderName()
    }

    /// 本设备固定的 uuid（第一次用时生成）
    static func deviceID(_ defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: deviceKey) { return id }
        let id = UUID().uuidString.lowercased(); defaults.set(id, forKey: deviceKey); return id
    }

    static func baseKey(folder: URL, gameID: String) -> String { "S2ASaveSync.base.\(folder.lastPathComponent).\(gameID)" }

    struct ServiceError: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// 一次服务层存档作业：context 是 s2a_shell_save_context 给的公共字段，op 是本次的字段
    static func call(_ context: [String: Any], _ op: [String: Any]) throws -> [String: Any] {
        let request = context.merging(op) { _, new in new }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        guard let raw = json.withCString({ s2a_shell_save_request($0) }) else { throw ServiceError(message: shellText("This package has no save service, so iCloud saves weren’t synced.")) }
        defer { free(raw) }
        let response = (try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8))) as? [String: Any] ?? [:]
        guard response["ok"] as? Bool == true else {
            throw ServiceError(message: ((response["error"] as? [String: Any])?["message"] as? String) ?? shellText("The save service didn’t return a valid result."))
        }
        return response["result"] as? [String: Any] ?? [:]
    }

    static func ports(_ context: [String: Any]) -> SaveSyncPorts {
        nonisolated(unsafe) let context = context
        return SaveSyncPorts(
            export: { url in
                guard try call(context, ["operation": "status"])["hasSave"] as? Bool == true else { return false }
                _ = try call(context, ["operation": "export", "path": url.path]); return true
            },
            inspect: { url in try files(call(context, ["operation": "inspect", "path": url.path])) },
            restore: { url in
                let preview = try call(context, ["operation": "inspect", "path": url.path])
                _ = try call(context, ["operation": "restore", "path": url.path,
                                       "archiveSha256": preview["archiveSha256"] ?? "", "targetFingerprint": preview["targetFingerprint"] ?? ""])
                // 收掉已提交的事务记录，不然下次起局会先进存档管理页。此时存档已经换了：失败要照实说（基线不前进，下次同步内容相同只记基线）
                do { _ = try call(context, ["operation": "recover"]) }
                catch { throw ServiceError(message: shellText("The save was switched to the iCloud progress, but finishing up didn’t complete (\(error.localizedDescription)). Save management will open before the game next starts to finish it.")) }
            })
    }

    /// 同步页「这次没同步上」下面那句：SaveSyncError 只带文件名 / 设备名 / 原因，文字在这里按 App 语言取（#316）；ServiceError 已是本地化好的句子
    static func message(_ error: Error) -> String {
        switch error {
        case SaveSyncError.notDownloaded(let name): shellText("iCloud hasn’t downloaded \(name) to this device yet, so your save wasn’t changed. Connect to the internet, wait a moment, and try again.")
        case SaveSyncError.corrupt(let name): shellText("\(name) in iCloud is incomplete, so your save wasn’t changed. Sync again on the other device.")
        case SaveSyncError.cloudWriteAfterRestore(let from, let why): shellText("Switched to the progress from \(from), but couldn’t write it back to iCloud (\(why)). The save itself is fine; the next sync will write it again.")
        case let e as ServiceError: e.message
        default: error.localizedDescription
        }
    }

    static func files(_ inspect: [String: Any]) throws -> [SaveFile] {
        guard let list = (inspect["manifest"] as? [String: Any])?["files"] as? [[String: Any]] else { throw ServiceError(message: shellText("The save list couldn’t be read completely.")) }
        return try list.map {
            guard let path = $0["path"] as? String, let sha = $0["sha256"] as? String else { throw ServiceError(message: shellText("The save list couldn’t be read completely.")) }
            return SaveFile(path: path, sha256: sha)
        }
    }
}

/// 签名身份对不对得上（#968：第三方签名把描述文件的 application-identifier 换成别的固定 App ID、包名仍是原来的，
///   系统文件服务认为 App 身份对不上，选文件夹点「打开」时拒绝交出文件夹（Cocoa 257、交回空列表），App 一点回调都收不到）。
///   打开选择器前比一次：对不上就先说清原因和改法，照样打开（不挡）
enum SigningIdentity {
    /// 描述文件（embedded.mobileprovision，CMS 包着的 XML plist）里 application-identifier 去掉团队前缀后的应用部分，与包名不一致时回它；
    ///   一致、通配符能匹配、读不到描述文件（App Store / 模拟器）都回 nil
    static func mismatch(provision: Data?, bundleID: String?) -> String? {
        guard let provision, let bundleID, let lo = provision.range(of: Data("<?xml".utf8)), let hi = provision.range(of: Data("</plist>".utf8), in: lo.lowerBound..<provision.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: provision[lo.lowerBound..<hi.upperBound], format: nil) as? [String: Any],
              let full = (plist["Entitlements"] as? [String: Any])?["application-identifier"] as? String, let dot = full.firstIndex(of: ".") else { return nil }
        let app = String(full[full.index(after: dot)...])
        if app == bundleID || app == "*" { return nil }
        if app.hasSuffix(".*"), bundleID.hasPrefix(String(app.dropLast(1))) { return nil }
        return app
    }
    static var current: String? {
        mismatch(provision: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) }, bundleID: Bundle.main.bundleIdentifier)
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 库设置「云存档 → 选择文件夹…」：系统文件夹选择器，选完记书签
@MainActor final class CloudFolderPicker: NSObject, UIDocumentPickerDelegate {
    static var current: CloudFolderPicker?
    /// 选好的文件夹先由 CloudSaves.remember 收下（选了就能用），再交给 picked（同步页「重新选择」用：接着按它同步）
    var picked: ((URL) -> Void)?
    static func present(from host: UIViewController? = nil, picked: ((URL) -> Void)? = nil) {
        let show = {
            let picker = makePicker()
            let me = CloudFolderPicker(); me.picked = picked; current = me; picker.delegate = me
            (host ?? topController())?.present(picker, animated: true)
        }
        // 签名身份对不上（#968）：先说原因和改法，点「继续选择」照样打开选择器
        guard let appID = SigningIdentity.current, let bundle = Bundle.main.bundleIdentifier else { show(); return }
        NSLog("S2Arm 云存档：【黄】签名的 App ID %@ 与包名 %@ 不一致，系统可能不肯交出选的文件夹", appID, bundle)
        let alert = UIAlertController(title: shellText("Signing doesn’t match the bundle ID"),
                                      message: shellText("This copy of S2Arm was signed with the App ID “\(appID)”, but its bundle ID is “\(bundle)”. iOS may refuse to hand the folder you pick to S2Arm, so tapping Open may do nothing. If that happens, change the bundle ID to “\(appID)” in your signing tool and sign again."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: shellText("Continue to Choose"), style: .default) { _ in show() })
        (host ?? topController())?.present(alert, animated: true)
    }
    /// 起始目录给 S2Arm 的 Documents：不给时落在「最近项目」，那一页要汇总机上所有开了文件共享的 App，被大容器拖住时一直「正在加载」，
    ///   玩家看着像卡死（11-11 真机复现：几分钟不出内容，App 主线程空闲）。玩家要的云盘文件夹从左栏点进去
    static func makePicker() -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return picker
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        defer { Self.current = nil }
        guard let url = urls.first else { return }
        NSLog("S2Arm 云存档：选了文件夹 %@（书签%@）", url.lastPathComponent, CloudSaves.remember(url) ? "已存" : "没存上，这次照常用")
        picked?(url)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { Self.current = nil }
}

/// 测试开关 S2A_TEST_PICKER=cloud（ios/app.m test_picker）：弹出和库设置「云存档 → 选择文件夹…」同一个选择器
@_cdecl("s2a_shell_test_cloud_picker") public func s2aShellTestCloudPicker() { MainActor.assumeIsolated { CloudFolderPicker.present() } }

@MainActor func topController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
    while let next = top?.presentedViewController { top = next }
    return top
}

/// 起局前的同步页（11-09 维护者：别是黑底一行竖字）：卡片里写清哪款游戏、在做什么；冲突在卡片里列出各份存档让玩家点选；
///   失败写原因、本机存档没动、照常开始。配色用游戏库同一套（ShellPalette），字重 / 圆角同库界面
@MainActor @Observable final class CloudSyncModel {
    enum Phase { case syncing, choosing([SaveSyncChoice]), finished(String), failed(String), needsFolder(String) }
    var phase: Phase = .syncing
    let game: String
    var pick: ((SaveSyncChoice?) -> Void)?
    var start: () -> Void = {}
    /// 同步中「跳过」：取消这次同步（已经开始的恢复会做完），本机存档照旧开始
    var skip: () -> Void = {}
    /// 授权失效时「重新选择文件夹」
    var repick: () -> Void = {}
    init(game: String) { self.game = game }

    /// 冲突：卡片里列出各份存档，等玩家点一份（nil = 先不选）
    func ask(_ choices: [SaveSyncChoice]) async -> SaveSyncChoice? {
        await withCheckedContinuation { (k: CheckedContinuation<SaveSyncChoice?, Never>) in
            pick = { [weak self] c in self?.pick = nil; self?.phase = .syncing; k.resume(returning: c) }
            phase = .choosing(choices)
        }
    }
}

struct CloudSyncView: View {
    let model: CloudSyncModel
    private static let time: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true; return f }()
    private var localName: String { UIDevice.current.userInterfaceIdiom == .pad ? shellText("This iPad") : shellText("This iPhone") }

    var body: some View {
        ZStack {
            ShellPalette.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(ShellPalette.background)
                        .frame(width: 30, height: 30).background(ShellPalette.cream, in: Circle())
                    Text(shellText("ICLOUD SAVES")).font(.system(size: 11.5, weight: .bold)).tracking(1.3).foregroundStyle(ShellPalette.muted)
                }
                Text(model.game).font(.system(size: 24, weight: .heavy)).tracking(-0.5).foregroundStyle(.white).lineLimit(2)
                content
            }
            .padding(26)
            .frame(maxWidth: 480, alignment: .leading)
            .background(ShellPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .padding(.horizontal, 24)
        }
    }

    private var icon: String {
        switch model.phase {
        case .failed, .needsFolder: "exclamationmark.icloud"
        case .finished: "checkmark.icloud"
        default: "icloud"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .syncing:
            HStack(spacing: 10) {
                ProgressView().tint(ShellPalette.cream)
                Text(shellText("Checking saves with iCloud…")).font(.system(size: 15, weight: .medium)).foregroundStyle(ShellPalette.muted)
            }
            Button(shellText("Skip sync and start")) { model.skip() }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(ShellPalette.muted).frame(maxWidth: .infinity)
        case .finished(let text):
            Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(ShellPalette.ready)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(shellText("Couldn’t sync this time")).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text(message).font(.system(size: 14)).foregroundStyle(ShellPalette.muted).fixedSize(horizontal: false, vertical: true)
                Text(shellText("The save on this device wasn’t changed. You can play as usual.")).font(.system(size: 14)).foregroundStyle(ShellPalette.muted)
            }
            primary(shellText("Start Game")) { model.start() }
        case .needsFolder(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Text(shellText("Choose the iCloud folder again")).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text(reason).font(.system(size: 14)).foregroundStyle(ShellPalette.muted).fixedSize(horizontal: false, vertical: true)
            }
            primary(shellText("Choose Folder…")) { model.repick() }
            Button(shellText("Don’t sync this time and start")) { model.start() }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(ShellPalette.muted).frame(maxWidth: .infinity)
        case .choosing(let choices):
            VStack(alignment: .leading, spacing: 6) {
                Text(shellText("Both sides have new progress. Pick one to keep playing")).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text(shellText("The one you don’t pick is kept as a backup, so nothing is lost.")).font(.system(size: 14)).foregroundStyle(ShellPalette.muted)
            }
            VStack(spacing: 10) {
                ForEach(Array(choices.enumerated()), id: \.offset) { _, c in
                    Button { model.pick?(c) } label: { row(c) }.buttonStyle(.plain)
                }
            }
            Button(shellText("Decide later and start")) { model.pick?(nil) }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(ShellPalette.muted).frame(maxWidth: .infinity)
        }
    }

    private func row(_ c: SaveSyncChoice) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: c.bytes, countStyle: .file)
        let saved = c.savedAt.map { Self.time.string(from: $0) } ?? shellText("Unknown time")
        let detail = c.isLocal ? shellText("On this device · \(size)") : shellText("Saved \(saved) · \(size)")
        return HStack(spacing: 14) {
            Image(systemName: Self.symbol(c.platform))
                .font(.system(size: 20)).foregroundStyle(ShellPalette.cream).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.isLocal ? localName : c.deviceName).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.system(size: 13)).foregroundStyle(ShellPalette.muted)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(ShellPalette.muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    /// 设备图标：head 里记的设备类型；旧 head 没记的画通用图标
    static func symbol(_ platform: String?) -> String {
        switch platform {
        case "mac": "laptopcomputer"
        case "iphone": "iphone"
        case "ipad": "ipad"
        default: "externaldrive.badge.icloud"
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(ShellPalette.background)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(ShellPalette.cream, in: Capsule())
        }.buttonStyle(.plain)
    }
}

@MainActor final class CloudSyncController: UIHostingController<CloudSyncView> {
    var engine: SaveSyncEngine?
    let make: (URL) -> SaveSyncEngine
    let model: CloudSyncModel
    let onDone: () -> Void
    var work: Task<SaveSyncOutcome, Error>?
    var finished = false
    /// access 授权失效时先显示「重新选择」：当场弹系统文件夹选择器，选好就按新文件夹同步这一次（书签也重存）
    init(make: @escaping (URL) -> SaveSyncEngine, access: CloudSaves.Access, game: String, done: @escaping () -> Void) {
        self.make = make; self.onDone = done
        model = CloudSyncModel(game: game)
        if case .ready(let url) = access { engine = make(url) }
        super.init(rootView: CloudSyncView(model: model))
        if case .lost(let reason) = access { model.phase = .needsFolder(reason) }
        model.start = { [weak self] in self?.done() }
        model.skip = { [weak self] in NSLog("S2Arm 云存档：玩家跳过这次同步"); self?.work?.cancel() }
        model.repick = { [weak self] in
            guard let self else { return }
            CloudFolderPicker.present(from: self) { [weak self] url in
                guard let self else { return }
                NSLog("S2Arm 云存档：重新选了文件夹 %@，按它同步", url.lastPathComponent)
                self.engine = self.make(url); self.model.phase = .syncing; self.run()
            }
        }
    }
    /// 只回调一次（跳过与同步结束可能前后脚到）
    func done() { if !finished { finished = true; onDone() } }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard work == nil, engine != nil else { return }
        run()
    }
    func run() {
        guard let engine else { return }
        let model = model
        let work = Task.detached { try await engine.sync { choices in await model.ask(choices) } }
        self.work = work
        Task {
            do {
                let outcome = try await work.value
                NSLog("S2Arm 云存档：%@", String(describing: outcome))
                // 结果停一下让玩家看清（取回 / 上传 / 已是最新），再进游戏
                model.phase = .finished(Self.describe(outcome))
                try? await Task.sleep(nanoseconds: 900_000_000)
                done()
            } catch is CancellationError {
                done()   // 玩家点了跳过：本机存档没动，直接开始
            } catch {
                NSLog("S2Arm 云存档：【红】同步失败：%@", error.localizedDescription)
                model.phase = .failed(CloudSaves.message(error))
            }
        }
    }

    static func describe(_ outcome: SaveSyncOutcome) -> String {
        switch outcome {
        case .upToDate: shellText("Saves are up to date")
        case .uploaded: shellText("Saved this device’s progress to iCloud")
        case .downloaded(let from), .tookRemote(let from): shellText("Switched to the progress from \(from)")
        case .keptLocal: shellText("Kept this device’s progress and saved it to iCloud")
        case .conflictSkipped: shellText("Not syncing this time; starting with this device’s save")
        }
    }
}

/// 本款的同步引擎与显示名：没开云存档 / 没有存档身份或服务 / 游戏号无效时回 nil（原因已记日志）
@MainActor func cloudEngine(_ gameID: UnsafePointer<CChar>?) -> (SaveSyncEngine, String)? {
    guard case .ready(let folder) = CloudSaves.access(), let (make, name) = cloudSetup(gameID) else { return nil }
    return (make(folder), name)
}
/// 本款的「按文件夹造同步引擎」与显示名（不碰文件夹授权）：没开云存档 / 没有存档身份或服务 / 游戏号无效时回 nil（原因已记日志）
@MainActor func cloudSetup(_ gameID: UnsafePointer<CChar>?) -> ((URL) -> SaveSyncEngine, String)? {
    guard CloudSaves.enabled else { return nil }   // 没开云存档
    guard let raw = s2a_shell_save_context() else { NSLog("S2Arm 云存档：本款没有存档身份或存档服务，不同步"); return nil }
    defer { free(raw) }
    // 云盘按存档身份里的游戏号分目录（单款包的启动上下文没有游戏号；容器里两者相同）
    guard let context = (try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8))) as? [String: Any],
          let gameID = ((context["game"] as? [String: Any])?["id"] as? String).map({ $0.uppercased() }) ?? gameID.map({ String(cString: $0) }),
          gameID.count == 16, gameID.allSatisfy(\.isHexDigit) else { NSLog("S2Arm 云存档：【红】存档身份里没有有效游戏号，不同步"); return nil }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("s2a-cloud-sync", isDirectory: true)
    let ports = CloudSaves.ports(context)
    let make = { (folder: URL) -> SaveSyncEngine in
        let key = CloudSaves.baseKey(folder: folder, gameID: gameID)
        return SaveSyncEngine(folder: CloudSaveFolder(root: folder, gameID: gameID), device: CloudSaves.deviceID(), deviceName: UIDevice.current.name, platform: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone",
                              work: work, ports: ports,
                              loadBase: { UserDefaults.standard.string(forKey: key) }, storeBase: { UserDefaults.standard.set($0, forKey: key) })
    }
    return (make, (context["game"] as? [String: Any])?["name"] as? String ?? gameID)
}

/// app.m 用的 C 入口（声明在 S2ArmShellBridge/include/s2a_shell.h）
@MainActor @_cdecl("s2a_shell_cloud_sync_vc")
public func s2a_shell_cloud_sync_vc(_ gameID: UnsafePointer<CChar>?, _ done: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
                                    _ ctx: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let (make, name) = cloudSetup(gameID) else { return nil }
    let access = CloudSaves.access()
    if case .off = access { return nil }
    nonisolated(unsafe) let ctx = ctx
    let vc = CloudSyncController(make: make, access: access, game: name) { done?(ctx) }
    return Unmanaged.passRetained(vc as UIViewController).toOpaque()
}

/// 游戏进行中切到后台：本机存档比云端新就上传（同 D2R-Mobile：切后台向系统要后台收尾时间，传完再交还）。
///   只上传：云端有更新或有冲突时不动，留给下次起局前的同步。上一次还没传完（后台任务还在）时不叠一次
@MainActor enum CloudBackgroundUpload {
    static var task = UIBackgroundTaskIdentifier.invalid
    static func finish() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task); task = .invalid
    }
}
@MainActor @_cdecl("s2a_shell_cloud_upload_background")
public func s2a_shell_cloud_upload_background(_ gameID: UnsafePointer<CChar>?) {
    guard CloudBackgroundUpload.task == .invalid, let (engine, _) = cloudEngine(gameID) else { return }
    CloudBackgroundUpload.task = UIApplication.shared.beginBackgroundTask(withName: "s2a.cloud") {
        NSLog("S2Arm 云存档：【红】切后台上传：系统给的后台时间到了，没传完（下次起局前同步会补上）")
        MainActor.assumeIsolated { CloudBackgroundUpload.finish() }
    }
    Task.detached {
        do {
            switch try await engine.uploadIfAhead() {
            case .uploaded?: NSLog("S2Arm 云存档：切后台，已把本机进度传到 iCloud")
            case nil: NSLog("S2Arm 云存档：切后台，云端有别的设备的新进度，这次不传，下次起局前同步处理")
            default: NSLog("S2Arm 云存档：切后台，存档已是最新")
            }
        } catch {
            NSLog("S2Arm 云存档：【红】切后台上传失败：%@（下次起局前同步会再试）", CloudSaves.message(error))
        }
        await MainActor.run { CloudBackgroundUpload.finish() }
    }
}
#endif
