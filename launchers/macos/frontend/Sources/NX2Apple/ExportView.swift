// S2Arm（不是上游文件）：出包页（11-07 维护者：启动器围绕「出包」设计，iPhone / iPad、macOS 同为出包平台，安卓、鸿蒙留位置）。
// 自上而下：这款游戏（封面、名称、版本、本体 / 更新 / DLC，同旧启动器 ExportGameCard 的读法）→ 出包到哪些平台（带图多选卡，同上游
// TargetCard 的样子；安卓、鸿蒙置灰「即将上线，敬请期待」；勾选记住）→ 底栏（不能出包的原因，或「开始出包 · N 个平台」）。
// 出包页没有「游戏选项」：游戏语言（11-14 维护者确认玩家可选）、主机模式、帧率、满屏等逐款选项都在启动设置，出包时不用选。
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
    /// 当前页面的选择；打开时恢复上次手动选择，没有时由模型选缺省位置。
    @State private var location = ""
    @State private var hoveredPlatform: ExportPlatform?
    /// S 级优化卡片报了「这款什么都没有」的游戏号（整张卡不出）
    let game: GameSummary
    /// 打开装机页（已出过 iPhone 包的款直接装）。
    let install: () -> Void

    var body: some View {
        ExportPageLayout {
            VStack(alignment: .leading, spacing: 20) {
                ExportGameHeader(model: model, covers: covers, game: game)
                // The patch and Mod choices stay in the setup page.
                SGradeCard(model: model, gameID: game.id)
                downstream
                platformsSection
                optionsSection
            }
        } actions: {
            actionBar
        }
        .onExitCommand { model.exportFor = nil }
        // 批量出包（v0.2.4）：出包页上也能一次放进多款，识别完和这款一起列成清单、连续出包
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            LauncherView.fileURLs(providers) { urls in model.batchSeed = game.id; model.importGames(urls, partialResults: true) }
            return true
        }
    }

    // ---- 下游深度方案（#1272）：选过之后在这里看得到选的是哪套、能改。没选过不出（导出 iPhone 时确认页会问）----
    //   「更改」弹同一个确认页（DownstreamConfirmSheet）；没有待出的单，选完只记下选择，下次导出 iPhone 按新选择走
    @ViewBuilder private var downstream: some View {
        if let offer = game.downstream, let choice = offer.choice {
            let lang = loc.lang.sharedCode
            let current = choice.isEmpty ? (offer.text(lang)?.original ?? "") : offer.name
            CardGroup(BackendText.launcherText("export.downstream.group", language: lang), footnote: BackendText.launcherText("export.downstream.note", language: lang)) {
                CardRow(current) {
                    Button(BackendText.launcherText("export.downstream.change", language: lang)) { model.downstreamPromptFor = game.id }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle()).disabled(model.busy).controllerID("export.downstream.change")
                }
                .accessibilityIdentifier("export.downstream")
            }
        }
    }

    // ---- platforms ----

    private var platformsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(loc.t("s2arm.export.platforms")).font(.manrope(15, .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
                Spacer()
                if game.iphoneReady {
                    Button(loc.t(model.installKey("s2arm.export.installExisting")), action: install)
                        .controllerButtonStyle(.plain).font(.manrope(12.5, .semibold)).foregroundStyle(LauncherPalette.cream.opacity(0.85))
                        .controllerID("export.install").controllerShortcut(.rightTrigger, focused: true)
                }
                if game.appleTvReady {   // 已出过 Apple TV 包：直接装到 Apple TV（tvInstall 作业）
                    Button(x("installAppleTV")) { model.installAppleTV(game) }
                        .controllerButtonStyle(.plain).font(.manrope(12.5, .semibold)).foregroundStyle(LauncherPalette.cream.opacity(0.85))
                        .disabled(model.busy).controllerID("export.installAppleTV")
                    Button(x("exportAppleTV")) { model.exportAppleTV(game) }   // 导出安装包（.ipa，资源在包里）：玩家用自己的签名工具签名装（11-16）
                        .controllerButtonStyle(.plain).font(.manrope(12.5, .semibold)).foregroundStyle(LauncherPalette.cream.opacity(0.85))
                        .disabled(model.busy).controllerID("export.exportAppleTV")
                }
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(ExportPlatform.allCases) { platform in tile(platform) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { model.loadAndroidPhones() }   // 安卓卡开不开由作业层回报（开关缺省关：关着照旧「即将推出」）
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            locationRow
            if model.exportTargets.contains(.ios) { IosAfterPackPicker(model: model, gameId: game.id) }   // 出完之后：装到 iPhone / 导出自签 IPA（11-16 维护者：一个入口、两条分叉各走到底）
            if model.exportTargets.contains(.tvos) || game.appleTvReady {
                appleTVRow
                AppleTVXcodeTeam(model: model).padding(.leading, 2)   // Apple TV 装机仍用 Xcode 团队（tvos.install_tv）：引导项目 / 手填团队号只在这里
            }
            if model.exportTargets.contains(.android) { androidRow }   // 出好装到哪台安卓手机（adb 列出的）；不选 / 没连 = 只出 APK
            if let error = model.choiceError {
                Text(loc.backend(error)).font(.manrope(12)).foregroundStyle(LauncherPalette.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func x(_ id: String) -> String { BackendText.launcherText("export." + id, language: loc.lang.sharedCode) }

    /// 装到哪台安卓手机：adb 列出的手机成下拉（androidDevices 作业），加一项「不装，只出 APK」；没连时说怎么连，装的那一步再报真原因
    private var androidRow: some View {
        let phones = model.androidPhones.compactMap { d -> (value: String, label: String)? in
            guard let serial = d["serial"] as? String else { return nil }
            let name = (d["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? serial
            return (serial, d["state"] as? String == "device" ? name : x("android.unauthorized").replacingOccurrences(of: "{0}", with: name))
        }
        return HStack(spacing: 12) {
            LauncherRowIcon("iphone")
            Text(x("android.device")).font(.manrope(13)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if phones.isEmpty {
                Text(x("android.none")).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                LauncherDropdown(options: phones + [("", x("android.skip"))], selection: model.androidPhone ?? "", label: x("android.device")) { model.androidPhoneChoice = $0 }
                    .controllerID("export.android")
            }
            Button(x("android.refresh")) { model.loadAndroidPhones() }.controllerButtonStyle(.plain).font(.manrope(12.5, .semibold))
        }
        .onAppear { model.loadAndroidPhones() }
    }

    /// 装到哪台 Apple TV：配对过的电视列成下拉（tvDevices 作业）；一台都没有时说怎么配对，装的那一步再报真原因
    private var appleTVRow: some View {
        let options = model.appleTVs.compactMap { d -> (value: String, label: String)? in
            guard let id = d["id"] as? String else { return nil }
            let name = (d["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Apple TV"
            return (id, d["online"] as? Bool == false ? x("appleTV.offline").replacingOccurrences(of: "{0}", with: name) : name)
        }
        return HStack(spacing: 12) {
            LauncherRowIcon("appletv")
            Text(x("appleTV.device")).font(.manrope(13)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if options.isEmpty {
                Text(x("appleTV.none")).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                LauncherDropdown(options: options, selection: model.appleTVDevice ?? "", label: x("appleTV.device")) { model.appleTVChoice = $0 }
                    .controllerID("export.appleTV")
            }
            Button(x("appleTV.refresh")) { model.loadAppleTVs() }.controllerButtonStyle(.plain).font(.manrope(12.5, .semibold))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(LauncherPalette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LauncherTheme.Colors.border, lineWidth: 1))
        .onAppear { model.loadAppleTVs() }
    }

    /// 存放位置（游戏库结构 v3，像 Steam 的库文件夹）：这款游戏的文件夹放在哪；换了位置，出包前先整个搬过去（存档跟着走）。
    private var locationRow: some View {
        var options: [(value: String, label: String)] = model.locations.map { l in
            let free = l.freeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            let name = S2ArmLauncherModel.locationName(path: l.path, volume: l.volume)
            return (l.path, l.connected ? x("location.free").replacingOccurrences(of: "{0}", with: name).replacingOccurrences(of: "{1}", with: free ?? "?")
                                        : x("location.offline").replacingOccurrences(of: "{0}", with: name))
        }
        if !location.isEmpty, !options.contains(where: { $0.value == location }) {
            options.append((location, (location as NSString).abbreviatingWithTildeInPath))
        }
        options.append((Self.otherFolder, x("location.other")))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                LauncherRowIcon("externaldrive")
                Text(x("location.title")).font(.manrope(13)).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                LauncherDropdown(options: options, selection: location, label: x("location.title")) { value in
                    if value == Self.otherFolder { chooseLocation() } else { selectLocation(value) }
                }
                .controllerID("export.location")
            }
            if let slack = model.locationSlackText(location, language: loc.lang.sharedCode) {   // #444：大分配单元 / 不是 APFS
                Label(slack, systemImage: "exclamationmark.triangle").font(.manrope(12)).foregroundStyle(LauncherPalette.building)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("export.location.slack")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(LauncherPalette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LauncherTheme.Colors.border, lineWidth: 1))
        .onAppear {
            if location.isEmpty { location = model.defaultLocation(for: game) }
            model.loadLocations()
        }
        .onChange(of: model.locations) { _ in if location.isEmpty { location = model.defaultLocation(for: game) } }
        .onChange(of: model.lastLocation) { _ in if location.isEmpty { location = model.defaultLocation(for: game) } }
    }

    private static let otherFolder = "__other__"

    private func selectLocation(_ path: String) {
        location = path
        model.rememberExportLocation(path, game: game)
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = x("location.choose")
        if !location.isEmpty { panel.directoryURL = URL(fileURLWithPath: location, isDirectory: true) }
        if panel.runModal() == .OK, let url = panel.url { selectLocation(url.path); model.loadLocations(probe: url.path) }
    }


    private func note(_ platform: ExportPlatform) -> String {
        switch platform {
        case .ios: return loc.t("s2arm.export.note.ios")
        case .tvos: return x("note.tvos")
        case .mac: return loc.t(game.playable ? "s2arm.export.note.macReady" : "s2arm.export.note.mac")
        case .android: return platform.released ? x("note.android") : loc.t("s2arm.export.soon")   // 开关后（作业层 androidDevices 回报）
        case .ohos: return loc.t("s2arm.export.soon")
        }
    }

    private func tile(_ platform: ExportPlatform) -> some View {
        let on = model.exportTargets.contains(platform)
        let open = platform.released
        let hovered = open && hoveredPlatform == platform
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
                    Text(platform.title(loc)).font(.manrope(16, .semibold))
                    Text(note(platform)).font(.manrope(12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 126, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LauncherPalette.surface.opacity(on ? 0.90 : (open ? (hovered ? 0.68 : 0.54) : 0.32)))
                    .overlay {
                        if on {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(LauncherPalette.cream.opacity(hovered ? 0.13 : 0.08))
                        }
                    }
            }
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? LauncherPalette.cream.opacity(hovered ? 0.95 : 0.82) : (hovered ? Color.white.opacity(0.20) : LauncherTheme.Colors.border), lineWidth: on ? 1.5 : 1))
            .shadow(color: on ? LauncherPalette.cream.opacity(0.10) : .clear, radius: 10, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .opacity(open ? 1 : 0.5)
        }
        .controllerButtonStyle(.plain)
        .controllerID("export.platform." + platform.rawValue)
        .disabled(!open || model.mainBusy)
        .busyHint(model, disabled: open)
        .onHover { hoveredPlatform = $0 ? platform : (hoveredPlatform == platform ? nil : hoveredPlatform) }
        .accessibilityLabel(platform.title(loc))
        .accessibilityValue(open ? loc.t(on ? "s2arm.export.checked" : "s2arm.export.unchecked") : loc.t("s2arm.export.soon"))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("export.platform." + platform.rawValue)
    }

    // ---- action bar ----

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
        return HStack(spacing: 14) {
            if let blocker {
                Label(reason(blocker), systemImage: "info.circle").font(.manrope(13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("export.reason")
                if blocker == .keys {
                    Button(x("fix.keys")) { model.showKeys = true }.controllerButtonStyle(LauncherSecondaryButtonStyle())
                }
                if case .game = blocker, !game.missing.isEmpty {
                    Button(x("fix.readd")) { model.showAddGames = true }.controllerButtonStyle(LauncherSecondaryButtonStyle())
                }
            } else {
                Text(loc.t("s2arm.export.hint")).font(.manrope(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(loc.t("s2arm.job.cancel")) { model.exportFor = nil }
                .controllerButtonStyle(LauncherSecondaryButtonStyle(prominent: true))
                .keyboardShortcut(.cancelAction).controllerID("export.cancel").controllerShortcut(.back)
            Button { model.startExport(game, location: location.isEmpty ? nil : location) } label: {
                Label(model.mainBusy || model.phoneHolds(game.id) ? x("action.queue") : startTitle, systemImage: "shippingbox.fill")
            }
            .controllerButtonStyle(LauncherPrimaryButtonStyle(prominent: true))
            .disabled(blocker?.stopsStart == true)   // 缺文件 / 缺 keys 只在左边提示，不置灰（作业层核实）
            .busyHint(model, disabled: blocker == .busy)   // 别的任务（非出包）在跑：说在等谁（出包在跑时这里是「排队」，不置灰）
            .keyboardShortcut(.defaultAction)
            .controllerID("export.start").controllerShortcut(.rightTrigger)
            .padTarget("export.start", scope: "main", radius: LauncherTheme.Metrics.controlRadius) { model.startExport(game, location: location.isEmpty ? nil : location) }
            .accessibilityLabel(startTitle)
            .accessibilityIdentifier("export.start")
        }
    }
}

extension ExportView {
    /// 开始按钮：出 iPhone 时写清出完去哪（出包并装到 iPhone / 出包并导出自签包），只出 Mac 时照旧
    var startTitle: String {
        guard model.exportTargets.contains(.ios) else {
            let count = model.exportTargets.count
            return count > 1 ? String(format: loc.t("s2arm.export.startCount"), count) : loc.t("s2arm.export.start")
        }
        return BackendText.launcherText(model.iosAfterPack == "export" ? "export.start.selfsign" : "export.start.install", language: loc.lang.sharedCode)
    }
}

/// 出包页「出完之后」：两张卡二选一（记住到下次）。装到 iPhone → 下面是目标设备与签名身份；导出自签 IPA → 说清导到哪、用什么装、不用连手机
struct IosAfterPackPicker: View {
    @ObservedObject var model: S2ArmLauncherModel
    /// 这款：「装到手机」「导出」两条路下都给这款的出法行（0.6.4：出包页也能选通用 S2Arm / 独立 App，单款覆盖全局）
    var gameId: String? = nil
    @EnvironmentObject var loc: Localizer
    @State private var hoveredOption: String?
    private func x(_ id: String) -> String { BackendText.launcherText("export." + id, language: loc.lang.sharedCode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(x("after.title")).font(.manrope(13, .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
            HStack(alignment: .top, spacing: 12) {
                option("install", x("after.install"), x("after.install_note"), "iphone.and.arrow.forward")
                option("export", x("after.export"), x("after.export_note"), "square.and.arrow.up")
            }.fixedSize(horizontal: false, vertical: true)   // 两张卡同高：按较高那张撑齐
            if model.iosAfterPack != "export" {
                TargetDeviceRow(model: model)
                InstallModeLine(model: model)
            }
            if let gameId { InstallLayoutRow(model: model, gameId: gameId).padding(.top, 4) }
        }
    }

    private func option(_ id: String, _ title: String, _ note: String, _ symbol: String) -> some View {
        let on = model.iosAfterPack == id
        let hovered = hoveredOption == id
        return Button { model.iosAfterPack = id } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(on ? LauncherPalette.cream : .secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Label(title, systemImage: symbol).font(.manrope(14.5, .semibold)).foregroundStyle(.primary)
                    Text(note).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LauncherPalette.surface.opacity(on ? 0.95 : (hovered ? 0.75 : 0.55)), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? LauncherPalette.cream.opacity(hovered ? 0.9 : 0.75) : (hovered ? Color.white.opacity(0.18) : LauncherTheme.Colors.border), lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .controllerButtonStyle(.plain).controllerID("export.after." + id)
        .onHover { hoveredOption = $0 ? id : (hoveredOption == id ? nil : hoveredOption) }
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("export.after." + id)
    }
}

extension ExportPlatform {
    /// 平台卡上的名字：Apple TV 的文案在共享体验表（export.platform.tvos），其余照旧在前端表
    func title(_ loc: Localizer) -> String {
        self == .tvos ? BackendText.launcherText("export.platform.tvos", language: loc.lang.sharedCode) : loc.t("s2arm.export.platform." + rawValue)
    }

    /// 平台卡上的图（同旧启动器 BuildPlatform.symbol）。
    var symbol: String {
        switch self {
        case .ios: return "iphone"
        case .tvos: return "appletv"
        case .mac: return "laptopcomputer"
        case .android: return "apps.iphone"
        case .ohos: return "square.stack.3d.up"
        }
    }
}
