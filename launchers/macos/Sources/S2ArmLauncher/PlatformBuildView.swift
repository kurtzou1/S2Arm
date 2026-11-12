import SwiftUI
import AppKit

enum BuildPlatform: String, CaseIterable, Identifiable {
    case ios, mac, android, ohos   // 11-02 维护者：可导出 iPhone / iPad（同一个 iOS 包）、macOS、安卓、鸿蒙，按这个顺序列
    var id: String { rawValue }
    var name: String { ["ios":L("iPhone / iPad"), "mac":"macOS", "android":L("安卓"), "ohos":L("鸿蒙")][rawValue]! }
    /// 对玩家开放的目标（11-02 维护者：安卓、鸿蒙留出位置、置灰，标「即将上线，敬请期待」）。开放某个平台只改这里。
    ///   只管玩家能选什么（选项卡、选中、AI 的 POST /build）；执行层（runPlatform / canBuildPlatform、重试）仍按 platformAvailable 的引擎探测，开发通路不受影响
    var released: Bool { self == .ios || self == .mac }
    var symbol: String { ["ios":"iphone", "mac":"laptopcomputer", "android":"apps.iphone", "ohos":"square.stack.3d.up"][rawValue]! }
    var entry: String {
        switch self {
        case .ios: return "pack/oneclick/oneclick.sh"
        case .mac: return "pack/jobs/build.py"
        case .android: return "android/docker/build.sh"
        case .ohos: return "runtime/ohos/build.sh"
        }
    }
    var artifact: String {
        switch self {
        case .ios: return L("IPA 与游戏资源包")
        case .mac: return L("可在本机游戏库直接游玩的 Mac 版本")
        case .android: return L("APK、游戏资源包与账本")
        case .ohos: return L("原生目标文件（.o）")
        }
    }
    var detail: String {
        switch self {
        case .ios: return L("iPhone 和 iPad 共用一个 IPA，着色器按所连设备或所选机型预编。")
        case .mac: return L("使用游戏库中的游戏，在这台 Mac 上准备好即可在游戏库直接开始游戏，与游戏库里的「准备」是同一功能。")
        case .android: return L("使用游戏库中的游戏生成 Android APK 和与之绑定的资源包。")
        case .ohos: return L("直接使用 S2Arm 已有的鸿蒙原生层构建功能。当前仅生成目标文件，尚未提供 HAP 编译功能。")
        }
    }
}

struct PlatformBuildConfiguration: Codable, Equatable {
    var enabled = false
}

extension Store {
    // 与 pack/targets/android/package.py 的运行时判据一致，检查实际用于出包的引擎。
    func platformAvailable(_ platform: BuildPlatform) -> Bool {
        if platform == .ohos { return false }
        if platform != .android { return true }
        guard let engine = engineBundle ?? preferences.engineDir.map({URL(fileURLWithPath:$0)}),
              let gradle = try? String(contentsOf:engine.appendingPathComponent("android/app/build.gradle"),encoding:.utf8),
              gradle.contains("s2arm.nativeMode") else { return false }
        let activity = engine.appendingPathComponent("android/app/src/main/java/org/s2arm/android/LibraryActivity.java")
            .resolvingSymlinksInPath()
        return (try? activity.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true
    }
    /// 玩家能不能选这个目标：已开放且本机引擎支持
    func platformSelectable(_ platform: BuildPlatform) -> Bool { platform.released && platformAvailable(platform) }
    func platformUnavailableReason(_ platform: BuildPlatform) -> String? {
        if !platform.released { return L("即将上线，敬请期待") }
        if platformAvailable(platform) { return nil }
        if platform == .android { return L("开发中：现有构建只出调试 APK，游戏加载与渲染还在开发") }
        if platform == .ohos { return L("开发中：现有构建只出原生目标文件，还没有 HAP 编译") }
        return nil
    }
    var displayedBuildPlatform: BuildPlatform { platformSelectable(buildPlatform) ? buildPlatform : .mac }
    func selectBuildPlatform(_ platform: BuildPlatform) {
        guard platformSelectable(platform) else { return }
        buildPlatform = platform
    }
    var buildPlatform: BuildPlatform {
        get { BuildPlatform(rawValue:preferences.selectedBuildPlatform ?? "") ?? .mac }
        set { preferences.selectedBuildPlatform = newValue.rawValue; savePreferences() }
    }
    func platformConfiguration(_ platform: BuildPlatform) -> PlatformBuildConfiguration {
        preferences.platformBuilds?[platform.rawValue] ?? .init(enabled:platform == .mac || platform == .ios)   // iOS 是主产品，缺省启用（审计 P2-8）
    }
    func setPlatformConfiguration(_ config: PlatformBuildConfiguration, for platform: BuildPlatform) {
        var configs = preferences.platformBuilds ?? [:]
        configs[platform.rawValue] = config
        preferences.platformBuilds = configs
        platformChecks[platform.rawValue] = nil
        savePreferences()
    }
    func platformRequest(_ platform: BuildPlatform) -> [String:Any] {
        var request: [String:Any] = ["target":platform.rawValue, "developerDir":preferences.developerDir,
                "keysPath":privateRoot.appendingPathComponent("keys/prod.keys").path,
                "fontsDir":preferences.fontsDir ?? ""]
        if platform == .android, let game = platformGame { request["gameId"] = game.id }
        return request
    }
    func platformComponentsAvailable(_ platform: BuildPlatform) -> Bool {
        let builtIn = engineBundle ?? preferences.engineDir.map{URL(fileURLWithPath:$0)}
        let roots = (platform == .android ? [builtIn] : [builtIn,
                     privateRoot.appendingPathComponent("platform-sources/\(platform.rawValue)")]).compactMap{$0}
        return roots.contains {FileManager.default.fileExists(atPath:$0.appendingPathComponent(platform.entry).path)}
    }
    func canBuildPlatform(_ platform: BuildPlatform) -> Bool {
        if platform == .android && !platformAvailable(platform) { return false }
        if platform == .mac {
            return platformConfiguration(platform).enabled && canManageToolchain && environmentReady && hasImportedKeys && platformGame?.buildable == true
        }
        if platform == .ios {
            return platformConfiguration(platform).enabled && canManageToolchain && environmentReady && hasImportedKeys &&
                platformGame?.buildable == true   // 一包通用（10-30）：不要求目标设备、不按目标系统卡 Xcode 版本（直连库按 iOS 18 下限编，与机型无关）
        }
        let checks = currentPlatformChecks(platform)
        let hasGame = platform != .android || (hasImportedKeys && platformGame?.buildable == true)
        return platformConfiguration(platform).enabled && canManageToolchain && hasGame && !checks.isEmpty && checks.allSatisfy(\.ok)
    }
    func currentPlatformChecks(_ platform: BuildPlatform) -> [ToolCheck] {
        if platform == .ios { return checks.filter { $0.required(for:"prepare") || $0.required(for:"ipa") } }
        if platform == .mac { return checks.filter { $0.required(for:"prepare") } }
        guard platformCheckRequests[platform.rawValue]?.isEqual(to:platformRequest(platform)) == true else {return []}
        return platformChecks[platform.rawValue] ?? []
    }
    func runPlatform(_ platform: BuildPlatform, operation: String, installSerial: String? = nil) {
        if platform == .android && !platformAvailable(platform) { return }
        guard platformConfiguration(platform).enabled, canManageToolchain else { return }
        if operation == "platformBuild", !canBuildPlatform(platform) { return }
        if platform == .ios || platform == .mac {
            if operation == "platformCheck" { checkEnvironment() }
            else if operation == "platformBuild", let game = platformGame { platform == .ios ? packIPhone(game) : enqueue(game) }
            return
        }
        var request = platformRequest(platform)
        if platform == .android, operation == "platformBuild", let serial = installSerial, !serial.isEmpty {
            request["installSerial"] = serial
        }
        executionTask = worker(operation, extra:request) { result in
            // Discard a report if settings changed while the worker was checking.
            if operation == "platformCheck", NSDictionary(dictionary:self.platformRequest(platform)).isEqual(to:request),
               let checks = Self.decode([ToolCheck].self, result["checks"]) {
                self.platformChecks[platform.rawValue] = checks
                self.platformCheckRequests[platform.rawValue] = NSDictionary(dictionary:request)
            }
            if operation != "platformCheck" { self.platformChecks[platform.rawValue] = nil }
        }
    }
    var platformGame: Game? {
        games.first { $0.id == selectedGame }
    }
    /// 跨平台编译页整卡显示的任务（选中平台 + 选中游戏）
    func platformTask(_ platform: BuildPlatform) -> TaskRecord? {
        tasks.first {
            platform == .ios ? $0.operation == "ipa" && $0.gameId == selectedGame :
            platform == .mac ? $0.operation == "build" && $0.gameId == selectedGame :
                $0.target == platform.rawValue && $0.operation != "platformCheck"
        }
    }
    /// 当前页面已经整卡显示的任务：窗口底部的任务条不再重复它（10-25 维护者：去掉重复信息）
    var pageTask: TaskRecord? {
        guard selection == "platforms", let g = platformGame ?? games.first else { return nil }
        return exportTasks(for:g).first(where:\.active)   // 导出页下面已整卡显示在跑的那条：窗口底部任务条不重复
    }
    func guiJobURL() throws -> URL {
        let packaged = resources.appendingPathComponent("GUIJobs/main.py")
        if FileManager.default.fileExists(atPath:packaged.path) { return packaged }
        let checkout = resources.appendingPathComponent("gui_jobs/main.py")
        guard FileManager.default.fileExists(atPath:checkout.path) else {
            throw NSError(domain:"S2Arm",code:2,userInfo:[NSLocalizedDescriptionKey:L("跨平台界面组件缺失，请重新安装完整应用。")])
        }
        return checkout
    }
}

// 导出页（11-02 维护者 重做）：上面是这款游戏（游戏包里读出的图标、名称、版本、本体 / 更新 / DLC），下面是带图的平台勾选，
//   勾几个就一次导出几个（不再一个平台一个页面）。默认一个都不勾、不勾不能导出（维护者 11-02）；勾选记在 preferences.exportTargets，下次打开还在。
//   安卓、鸿蒙留位置、置灰「即将上线，敬请期待」。安卓 Docker / 鸿蒙目标文件这些开发通路不在玩家页面上（runPlatform 照旧可调）
struct PlatformBuildView: View {
    @EnvironmentObject var store: Store
    private var game: Game? { store.platformGame ?? store.games.first }
    private var picked: [BuildPlatform] { store.exportPicked }
    var body: some View {
        WorkspacePage {
            WorkspaceHeading(title:"导出",subtitle:"",symbol:"square.and.arrow.up.on.square") {EmptyView()}
            if let game {
                ExportGameCard(game:game)
                if let d = game.downstream { DownstreamRow(game:game, d:d) }
                VStack(alignment:.leading,spacing:12) {
                    Text(L("导出到哪些设备")).font(.headline)
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:12),count:4),spacing:12) {
                        ForEach(BuildPlatform.allCases) { p in ExportTargetTile(platform:p, game:game) }
                    }
                    if picked.contains(.ios) { IPhoneTargetRow() }   // 兼容画面出包要按机型出；标准包与机型无关，这行只是提示
                }
                actionBar(game)
                ForEach(store.exportTasks(for:game)) { TaskCard(task:$0) }
            } else if store.refreshingLibrary {
                ProgressView(L("正在读取游戏库…")).progressViewStyle(.linear).padding(WorkspaceLayout.cardInset).glassSurface(WorkspaceLayout.cardRadius)   // 启动时读库要几秒：别先说「没有游戏」
            } else {
                VStack(spacing:12) {
                    Image(systemName:"square.stack.3d.up").font(.system(size:40)).foregroundStyle(.secondary)
                    Text(L("游戏库里还没有游戏")).font(.headline)
                    Button(L("添加游戏")) { store.chooseGames() }.platformButtonStyle(prominent:true)
                }.frame(maxWidth:.infinity).padding(40).glassSurface(WorkspaceLayout.cardRadius)
            }
        }.id(Localization.language)
        .onAppear { if store.platformGame == nil, let g = store.games.first { store.selectedGame = g.id } }
        .sheet(item:$store.downstreamPrompt) { g in if let d = g.downstream { DownstreamConfirmView(game:g, d:d) } }
    }
    @ViewBuilder private func actionBar(_ game: Game) -> some View {
        let reason: String? = picked.isEmpty ? L("先勾选要导出的平台")
            : !game.buildable ? ((game.missing ?? []).map { L($0) }.joined(separator:"；").nilIfEmpty ?? L("这款游戏暂不支持导出"))
            : !store.hasImportedKeys ? L("先在「设置」里放入 prod.keys")
            : !store.environmentReady ? L("这台 Mac 还缺导出要用的组件")
            : store.executionBusy || !store.queue.isEmpty ? L("正在做别的任务，做完再导出") : nil
        HStack(spacing:12) {
            if let reason {
                Label(reason,systemImage:"info.circle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if !store.environmentReady || !store.hasImportedKeys { Button(L("去设置处理")) { store.selection = "settings" } }
            } else {
                Text(L("大游戏第一次导出要几十分钟，请插上电源、别让 Mac 睡眠。")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if reason == nil {
                Button { store.exportChecked(game) } label: { Label(picked.count > 1 ? L("开始导出") + " · \(picked.count) " + L("个平台") : L("开始导出"),systemImage:"square.and.arrow.up") }
                    .platformButtonStyle(prominent:true).controlSize(.large).keyboardShortcut(.defaultAction)
            } else {
                Label(L("开始导出"),systemImage:"square.and.arrow.up").font(.body.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal,16).padding(.vertical,7).background(Color.secondary.opacity(0.14),in:Capsule())
            }
        }.padding(WorkspaceLayout.cardInset).glassSurface(WorkspaceLayout.cardRadius)
    }
}

/// 这款游戏：游戏包里读出的图标、名称、版本，本体 / 更新 / DLC 各一枚标签，总大小；库里不止一款时右上角换
struct ExportGameCard: View {
    @EnvironmentObject var store: Store
    let game: Game
    private func version(_ kind: String) -> String? {
        game.packages.filter { $0.type == kind }.map { $0.display.isEmpty ? "v\($0.version)" : $0.display }.last
    }
    var body: some View {
        let dlc = Set(game.packages.filter { $0.type == "dlc" }.map(\.titleId)).count
        let bytes = game.sourceBytes   // 同一个文件里的多项只算一次
        HStack(alignment:.top,spacing:18) {
            GameCover(game:game).frame(width:112,height:112).clipShape(RoundedRectangle(cornerRadius:22,style:.continuous))
                .shadow(color:.black.opacity(0.12),radius:6,y:3).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:8) {
                Text(game.name).font(.title2.bold()).lineLimit(2).fixedSize(horizontal:false,vertical:true)
                Text(game.display.isEmpty ? L("版本待识别") : L("版本") + " " + game.display).font(.callout).foregroundStyle(.secondary)
                HStack(spacing:6) {
                    if let v = version("base") { ExportChip(text:L("本体") + " " + v, symbol:"shippingbox") }
                    if let v = version("update") { ExportChip(text:L("更新") + " " + v, symbol:"arrow.triangle.2.circlepath") }
                    ExportChip(text:dlc > 0 ? "DLC × \(dlc)" : L("无 DLC"), symbol:"puzzlepiece.extension", muted:dlc == 0)
                    if bytes > 0 { ExportChip(text:ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file), symbol:"internaldrive", muted:true) }
                }
            }
            Spacer(minLength:8)
            if store.games.count > 1 {
                Menu {
                    ForEach(store.games) { g in Button(g.name) { store.selectedGame = g.id } }
                } label: { Label(L("换一款"),systemImage:"arrow.left.arrow.right") }.menuStyle(.borderlessButton).fixedSize()
            }
        }.padding(WorkspaceLayout.cardInset).frame(maxWidth:.infinity,alignment:.leading).glassSurface(WorkspaceLayout.cardRadius)
    }
}

struct ExportChip: View {
    let text: String; let symbol: String; var muted = false
    var body: some View {
        Label(text,systemImage:symbol).font(.caption.weight(.medium)).lineLimit(1)
            .padding(.horizontal,8).padding(.vertical,4)
            .background((muted ? Color.secondary : Brand.accent).opacity(0.12),in:Capsule())
            .foregroundStyle(muted ? Color.secondary : Brand.accent)
    }
}

/// 带图的勾选卡：点一下勾上 / 取消；未开放的置灰，写「即将上线，敬请期待」
struct ExportTargetTile: View {
    @EnvironmentObject var store: Store
    let platform: BuildPlatform
    let game: Game
    private var on: Bool { store.exportPicked.contains(platform) }
    private var note: String {
        switch platform {
        case .ios: return store.packShelf.first(where:{ $0.gameId == game.id })?.latest != nil ? L("已导出过，可再导出") : L("一个包，iPhone 和 iPad 都能装")
        case .mac: return game.ready == true ? L("已做好，可在游戏库直接玩") : L("在这台 Mac 上直接玩")
        default: return L("即将上线，敬请期待")
        }
    }
    var body: some View {
        Button {
            store.toggleExport(platform)
        } label: {
            VStack(alignment:.leading,spacing:10) {
                HStack(alignment:.top) {
                    Image(systemName:platform.symbol).font(.system(size:30,weight:.regular)).frame(height:36)
                    Spacer()
                    Image(systemName:on ? "checkmark.circle.fill" : "circle").font(.title3)
                        .foregroundStyle(on ? Brand.accent : Color.secondary.opacity(platform.released ? 0.6 : 0.3))
                }
                Text(platform.name).font(.headline)
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
            }
            .foregroundStyle(on ? Brand.accent : .primary)
            .padding(14).frame(maxWidth:.infinity,minHeight:132,alignment:.topLeading)
            .background(on ? Brand.accent.opacity(0.10) : Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(on ? Brand.accent : Color.secondary.opacity(0.18),lineWidth:on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius:14))
        }
        .buttonStyle(.plain).disabled(!platform.released).opacity(platform.released ? 1 : 0.5)
        .accessibilityLabel(platform.name).accessibilityValue(on ? L("已勾选") : platform.released ? L("未勾选") : L("即将上线，敬请期待"))
    }
}

extension Store {
    /// 导出勾选的平台（11-02 维护者：一次导出多个）：有 iPhone / iPad 先出它，Mac 排在它后面；只勾 Mac 就直接排 Mac
    /// 导出页勾了哪些（按页面顺序；未开放的永远不算）
    var exportPicked: [BuildPlatform] { BuildPlatform.allCases.filter { $0.released && (preferences.exportTargets ?? []).contains($0.rawValue) } }
    func toggleExport(_ p: BuildPlatform) {
        guard p.released else { return }
        var s = preferences.exportTargets ?? []
        if let i = s.firstIndex(of:p.rawValue) { s.remove(at:i) } else { s.append(p.rawValue) }
        preferences.exportTargets = s; savePreferences(); objectWillChange.send()
    }
    func exportTargets(_ game: Game) {
        let picked = exportPicked
        if picked.contains(.ios) {
            if picked.contains(.mac) { macAfterIPA.insert(game.id) }
            packIPhone(game)
        } else if picked.contains(.mac) { enqueue(game) }
    }
    /// 导出页下面列的任务：这款游戏的 iPhone 版 / Mac 版，各取最近一条（在跑的优先）
    func exportTasks(for game: Game) -> [TaskRecord] {
        ["ipa","build"].compactMap { op in
            let ts = tasks.filter { $0.gameId == game.id && $0.operation == op }
            return ts.first(where:\.active) ?? ts.max { ($0.started ?? 0) < ($1.started ?? 0) }
        }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
