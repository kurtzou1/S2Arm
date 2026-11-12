// S2Arm（不是上游文件）：出包页（11-07 维护者：启动器围绕「出包」设计，iPhone / iPad、macOS 同为出包平台，安卓、鸿蒙留位置）。
// 自上而下：这款游戏（封面、名称、版本、本体 / 更新 / DLC，同旧启动器 ExportGameCard 的读法）→ 出包到哪些平台（带图多选卡，同上游
// TargetCard 的样子；安卓、鸿蒙置灰「即将上线，敬请期待」；勾选记住）→ 底栏（不能出包的原因，或「开始出包 · N 个平台」）。
// 没有「游戏选项」（11-07 维护者）：游戏语言跟设备系统语言，Mac 主机模式 / 手机掌机模式，60 帧缺省开、起不来自动降级，满屏缺省通用 + 补丁包，都不用玩家选。
import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct ExportView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @ObservedObject var covers: CoverCache
    @State private var renaming = false
    @State private var renameText = ""
    /// 存放位置（游戏库结构 v3）：选中的文件夹路径；空 = 还没定（出现时按这款现在的 / 上次用的位置填）
    @State private var location = ""
    /// 「选择其他文件夹…」选过、还不在位置表里的
    @State private var pickedLocation: String?
    let game: GameSummary
    /// 打开装机页（已出过 iPhone 包的款直接装）。
    let install: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 34) {
                    header
                    Text(BackendText.launcherText("batch.hint", language: loc.lang == .zh ? "zh-Hans" : "en")).font(.manrope(12.5)).foregroundStyle(.secondary)
                    platforms
                }
                .padding(.horizontal, 40).padding(.top, 22).padding(.bottom, 40)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            Divider().opacity(0.3)
            actionBar
        }
        .onExitCommand { model.exportFor = nil }
        // 批量出包（v0.2.4）：出包页上也能一次放进多款，识别完和这款一起列成清单、连续出包
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            LauncherView.fileURLs(providers) { urls in model.batchSeed = game.id; model.importGames(urls, partialResults: true) }
            return true
        }
    }

    // ---- the game ----

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            Button { model.exportFor = nil } label: {
                Label(loc.t("s2arm.export.back"), systemImage: "chevron.left").font(.manrope(12.5, .semibold))
            }
            .buttonStyle(LauncherSecondaryButtonStyle())
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityIdentifier("export.back")
            HStack(alignment: .center, spacing: 24) {
                Button { chooseCover(game) } label: {
                    GameArtwork(covers: covers, cover: game.cover)
                    .frame(width: 236, height: 236 / 1.8).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08)))
                    .overlay(alignment: .bottomTrailing) { editBadge.padding(8) }
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                }
                .buttonStyle(.plain).disabled(model.busy || model.customizing)
                .help(loc.t("s2arm.custom.cover.help"))
                .accessibilityLabel(loc.t("s2arm.custom.cover.help"))
                .accessibilityIdentifier("export.cover")
                VStack(alignment: .leading, spacing: 10) {
                    Button { renameText = game.name; renaming = true } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(game.name).font(.manrope(36, .heavy)).tracking(-1.0).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                            Image(systemName: "pencil").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain).disabled(model.busy || model.customizing)
                    .help(loc.t("s2arm.custom.name.help"))
                    .accessibilityIdentifier("export.name")
                    .alert(loc.t("s2arm.custom.name.title"), isPresented: $renaming) {
                        TextField(loc.t("s2arm.custom.name.placeholder"), text: $renameText)
                        Button(loc.t("s2arm.custom.save")) { model.customize(game, name: renameText) }
                        if game.customName { Button(loc.t("s2arm.custom.name.reset")) { model.customize(game, name: "") } }
                        Button(loc.t("s2arm.custom.cancel"), role: .cancel) {}
                    }
                    if game.customCover {
                        Button(loc.t("s2arm.custom.cover.reset")) { model.customize(game, coverPath: "") }
                            .buttonStyle(.plain).font(.manrope(12.5)).foregroundStyle(.secondary).underline()
                            .disabled(model.busy || model.customizing).accessibilityIdentifier("export.cover.reset")
                    }
                    if model.customizing, let note = model.lockWaitNote {
                        Text(loc.backend(note)).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let failed = model.customizeError {
                        Text(loc.backend(failed)).font(.manrope(12.5)).foregroundStyle(LauncherPalette.danger).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(String(format: loc.t("s2arm.export.version"), game.display.isEmpty ? (game.version("base") ?? "-") : game.display))
                        .font(.manrope(14)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if let v = game.version("base") { chip(String(format: loc.t("s2arm.export.base"), v), "shippingbox") }
                        if let v = game.version("update") { chip(String(format: loc.t("s2arm.export.update"), v), "arrow.triangle.2.circlepath") }
                        chip(game.dlcCount > 0 ? String(format: loc.t("s2arm.export.dlc"), game.dlcCount) : loc.t("s2arm.export.noDlc"),
                             "puzzlepiece.extension", muted: game.dlcCount == 0)
                        if game.totalBytes > 0 {
                            chip(ByteCountFormatter.string(fromByteCount: game.totalBytes, countStyle: .file), "internaldrive", muted: true)
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func chip(_ text: String, _ symbol: String, muted: Bool = false) -> some View {
        Label(text, systemImage: symbol).font(.manrope(12, .semibold)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(muted ? Color.secondary : LauncherPalette.cream)
            .background((muted ? Color.white : LauncherPalette.cream).opacity(muted ? 0.06 : 0.10), in: Capsule())
    }

    // ---- platforms ----

    private var platforms: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(loc.t("s2arm.export.platforms")).font(.manrope(15, .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
                Spacer()
                if game.iphoneReady {
                    Button(loc.t(model.installKey("s2arm.export.installExisting")), action: install)
                        .buttonStyle(.plain).font(.manrope(12.5, .semibold)).foregroundStyle(LauncherPalette.cream.opacity(0.85))
                        .accessibilityIdentifier("export.install")
                }
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(ExportPlatform.allCases) { platform in tile(platform) }
            }
            locationRow
            if model.exportTargets.contains(.ios) { TargetDeviceRow(model: model); InstallModeLine(model: model) }   // 签名 / 安装方式收进环境检查（v0.3.0），这里只读 + 更改
            if let error = model.choiceError {
                Text(loc.backend(error)).font(.manrope(12)).foregroundStyle(LauncherPalette.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func x(_ id: String) -> String { BackendText.launcherText("export." + id, language: loc.lang == .zh ? "zh-Hans" : "en") }

    /// 存放位置（游戏库结构 v3，像 Steam 的库文件夹）：这款游戏的文件夹放在哪；换了位置，出包前先整个搬过去（存档跟着走）。
    private var locationRow: some View {
        var options: [(value: String, label: String)] = model.locations.map { l in
            let free = l.freeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            let name = S2ArmLauncherModel.locationName(path: l.path, volume: l.volume)
            return (l.path, l.connected ? x("location.free").replacingOccurrences(of: "{0}", with: name).replacingOccurrences(of: "{1}", with: free ?? "?")
                                        : x("location.offline").replacingOccurrences(of: "{0}", with: name))
        }
        if let picked = pickedLocation, !options.contains(where: { $0.value == picked }) {
            options.append((picked, (picked as NSString).abbreviatingWithTildeInPath))
        }
        options.append((Self.otherFolder, x("location.other")))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                LauncherRowIcon("externaldrive")
                Text(x("location.title")).font(.manrope(13)).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                LauncherDropdown(options: options, selection: location, label: x("location.title"), style: .button) { value in
                    if value == Self.otherFolder { chooseLocation() } else { location = value }
                }
                .accessibilityIdentifier("export.location")
            }
            if let slack = model.locationSlackText(location, language: loc.lang == .zh ? "zh-Hans" : "en") {   // #444：大分配单元 / 不是 APFS
                Label(slack, systemImage: "exclamationmark.triangle").font(.manrope(12)).foregroundStyle(LauncherPalette.building)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("export.location.slack")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(LauncherPalette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 4)
        .onAppear { model.loadLocations() }
        .onChange(of: model.locations) { _ in if location.isEmpty { location = model.defaultLocation(for: game) } }
    }

    private static let otherFolder = "__other__"

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = x("location.choose")
        if panel.runModal() == .OK, let url = panel.url { pickedLocation = url.path; location = url.path; model.loadLocations(probe: url.path) }
    }


    private func note(_ platform: ExportPlatform) -> String {
        switch platform {
        case .ios: return loc.t("s2arm.export.note.ios")
        case .mac: return loc.t(game.playable ? "s2arm.export.note.macReady" : "s2arm.export.note.mac")
        case .android, .ohos: return loc.t("s2arm.export.soon")
        }
    }

    private func tile(_ platform: ExportPlatform) -> some View {
        let on = model.exportTargets.contains(platform)
        let open = platform.released
        return Button { model.toggleExport(platform) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: platform.symbol).font(.system(size: 26, weight: .light))
                        .foregroundStyle(on ? LauncherPalette.cream : .secondary)
                        .frame(height: 30)
                    Spacer()
                    if open {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5).fill(on ? LauncherPalette.cream : .clear)
                            RoundedRectangle(cornerRadius: 5).strokeBorder(on ? LauncherPalette.cream : Color.white.opacity(0.25), lineWidth: 1.5)
                            if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.black) }
                        }
                        .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "lock").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white.opacity(0.3))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t("s2arm.export.platform." + platform.rawValue)).font(.manrope(16, .semibold))
                    Text(note(platform)).font(.manrope(12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18).frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
            .background(on ? LauncherPalette.cream.opacity(0.05) : LauncherPalette.surface.opacity(open ? 0.75 : 0.4), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? LauncherPalette.cream.opacity(0.7) : Color.white.opacity(0.06), lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .opacity(open ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!open || model.busy)
        .busyHint(model, disabled: open)
        .padTarget("export." + platform.rawValue, scope: "main", radius: 16) { model.toggleExport(platform) }
        .accessibilityLabel(loc.t("s2arm.export.platform." + platform.rawValue))
        .accessibilityValue(open ? loc.t(on ? "s2arm.export.checked" : "s2arm.export.unchecked") : loc.t("s2arm.export.soon"))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("export.platform." + platform.rawValue)
    }

    // ---- action bar ----

    private var editBadge: some View {
        Image(systemName: "photo").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .padding(7).background(.black.opacity(0.55), in: Circle())
    }

    private func chooseCover(_ game: GameSummary) {
        let panel = NSOpenPanel()
        panel.title = loc.t("s2arm.custom.cover.help")
        panel.allowedContentTypes = [.jpeg, .png]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.customize(game, coverPath: url.path)
    }

    private func reason(_ blocker: ExportBlocker) -> String {
        switch blocker {
        case .noPlatform: return loc.t("s2arm.export.block.noPlatform")
        case .game(let text): return loc.backend(text)
        case .keys: return loc.t("s2arm.export.block.keys")
        case .busy: return loc.t("s2arm.export.block.busy")
        case .alreadyQueued: return loc.t("s2arm.export.block.alreadyQueued")
        }
    }

    private var actionBar: some View {
        let blocker = model.exportBlocker(game)
        let count = model.exportTargets.count
        return HStack(spacing: 14) {
            if let blocker {
                Label(reason(blocker), systemImage: "info.circle").font(.manrope(13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("export.reason")
                if blocker == .keys {
                    Button(x("fix.keys")) { model.showKeys = true }.buttonStyle(LauncherSecondaryButtonStyle())
                }
                if case .game = blocker, !game.missing.isEmpty {
                    Button(x("fix.readd")) { model.showAddGames = true }.buttonStyle(LauncherSecondaryButtonStyle())
                }
            } else {
                Text(loc.t("s2arm.export.hint")).font(.manrope(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button { model.export(game, location: location.isEmpty ? nil : location) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.fill")
                    Text(model.busy ? x("action.queue") : count > 1 ? String(format: loc.t("s2arm.export.startCount"), count) : loc.t("s2arm.export.start")).lineLimit(1)
                }
                .font(.manrope(16, .bold)).foregroundStyle(.black)
                .padding(.horizontal, 26).frame(height: 48)
                .background(LauncherPalette.cream, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(blocker?.stopsStart == true)   // 缺文件 / 缺 keys 只在左边提示，不置灰（作业层核实）
            .opacity(blocker?.stopsStart == true ? 0.4 : 1)
            .busyHint(model, disabled: blocker == .busy)   // 别的任务（非出包）在跑：说在等谁（出包在跑时这里是「排队」，不置灰）
            .keyboardShortcut(.defaultAction)
            .padTarget("export.start", scope: "main", radius: 26) { model.export(game, location: location.isEmpty ? nil : location) }
            .accessibilityLabel(count > 1 ? String(format: loc.t("s2arm.export.startCount"), count) : loc.t("s2arm.export.start"))
            .accessibilityIdentifier("export.start")
        }
        .padding(.horizontal, 40).padding(.vertical, 16)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }
}

extension ExportPlatform {
    /// 平台卡上的图（同旧启动器 BuildPlatform.symbol）。
    var symbol: String {
        switch self {
        case .ios: return "iphone"
        case .mac: return "laptopcomputer"
        case .android: return "apps.iphone"
        case .ohos: return "square.stack.3d.up"
        }
    }
}
