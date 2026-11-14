import Foundation
import Observation
import S2ArmShellBridge
import SaveSync
import ShellControllers
import ShellUI

/// 我方宿主层的最小实现：清单 → 库界面条目；手柄 / 键盘语义输入（上游 ShellControllers 原样）；Play → C 出口 s2a_shell_play。
/// 只借上游 ShellHostModel 的设计（@Observable 模型 + actions + startControllers），不带它的 EngineLaunchPlan / DM_* / framework 扫描。
/// 设置行：每款游戏的「画面」「虚拟手柄」两组（S2ArmGameSettings，11-07 维护者）；数据目录、云存档等动作本刀不接（ShellActions 缺省空操作）。
/// 删除游戏（#227）：删本机这款的游戏数据（Documents/games/<游戏号>），勾了连存档才删存档；删完重判，库里随即不再显示（App 里的程序随下次从电脑装机摘掉）。
@MainActor @Observable
public final class S2ArmShellHostModel {
    /// 清单里的全部款（容器里的）
    private var allGames: [GameDetail]
    /// 不在库里显示的款：玩家在这台设备上删掉的、资源也确实不在（审计 P1-155：资源没到位但玩家没删的款留在库里，显示「需要游戏数据」、点进去看说明）
    private var notOnDevice: Set<String> = []
    /// 库里显示的款：清单列着、且不是玩家删掉的（资源没到位的显示「需要游戏数据」）
    public var games: [GameDetail] { allGames.filter { !notOnDevice.contains($0.id) } }
    public private(set) var controllers: [ControllerInfo] = []
    public private(set) var input = ShellInputLog()
    public private(set) var padSnapshot: PadSnapshot?
    @ObservationIgnored private let adapter = GamepadAdapter()
    @ObservationIgnored private let play: (String) -> Void
    /// 本款装机阶段（宿主按 Documents/games/<游戏号> 判，见 s2a_shell.h）：1 就绪 / 2 传完待解开 / 3 传输中 / 0 没有（不显示）
    @ObservationIgnored private let installState: (String) -> Int32
    /// 在后台解开阶段 2 的那款（同时只解一款；正在解别的返回 false）；正在解的这款的进度（已解开包数, 总包数）
    @ObservationIgnored private let installGame: (String) -> Bool
    @ObservationIgnored private let installWait: () -> Int32
    @ObservationIgnored private let installProgress: (String) -> (Int, Int)?
    /// 单一 IMG 的分段进度（宿主 s2a_shell_install_phase）：正在解这款时 (阶段 1/2/3，这一段的比例，不知道总量为 nil)，否则 nil
    @ObservationIgnored private let installPhase: (String) -> (Int, Double?)?
    /// 这一款最后一次解开失败的原因（宿主 s2a_shell_install_failure）；没失败过为 nil
    @ObservationIgnored private let installFailure: (String) -> String?
    @ObservationIgnored private let now: () -> Date
    /// 这次打开 App 已经起过解包的款：解完仍是阶段 2 = 没解成，显示「安装没完成」，点重试才再起（不自动反复解）
    @ObservationIgnored private var installTried: Set<String> = []
    /// 库开着就每秒重判一次（只判各款自己目录下的几个小文件，每款几次 stat / 读几十字节）：电脑随时可能开始推——
    ///   没显示的款一开始传就出现（真机实测：App 先被拉起、推包随后才写传输清单），已经能玩的款重推 / 装更新时也立刻画上蒙版
    ///   （#399 真机验收：原先「全都能玩了就停」，开着库重推一款已装好的游戏，整个推送过程库里一直显示可玩、没有进度）。App 退到后台时计时器随之暂停
    @ObservationIgnored private var ticker: Timer?
    var watching: Bool { ticker != nil }
    /// 传输清单和它列的文件这么久都没动 = 传断了（拔线、电脑那边停了）。90 秒：电脑经 devicectl 写 ≤1 GB 的一批要写完才落盘，实测约 33 秒，留余量
    static let transferStall: TimeInterval = 90
    @ObservationIgnored private let pickGameData: (String) -> Void
    /// 这台设备上每款数据的根（宿主同一取法：launch.ctx 的 docs = @home/Documents/games/<游戏号>）；单测可换
    @ObservationIgnored private let gamesRoot: URL
    /// 资源包的新位置（宿主同一取法，runtime/include/s2a_docs.h s2a_pack_root）：<家>/Library/Application Support/S2Arm/games/<游戏号>/资源包，
    ///   不进「文件」App、不进 iCloud 备份；游戏根不是 <家>/Documents/games 时（单测换了根）没有新位置，只认老位置 <游戏根>/<游戏号>/资源包
    @ObservationIgnored private let packGamesRoot: URL?
    /// 清单里写的状态（重判资源包时以它为底，不叠加）
    @ObservationIgnored private let listedStates: [String: GameState]
    @ObservationIgnored private let stores: S2ArmGameSettings.Stores
    @ObservationIgnored private let layoutState: (String) -> S2ArmGameSettings.LayoutState
    /// 正在调整虚拟手柄布局的那款（非空时宿主视图盖上编辑页）
    public var editingLayout: String?
    /// 正在改名字和封面的那款（非空时宿主视图盖上编辑页）
    public var editingIdentity: String?
    /// 编辑页上次点保存没存成的原因（存成 / 关页清掉）
    public private(set) var identityError: String?
    @ObservationIgnored private let identityStore: GameIdentityStore
    /// 清单里写的条目：恢复默认时回到它
    @ObservationIgnored private var listedTiles: [String: GameTile] = [:]
    @ObservationIgnored private var listedBanners: [String: URL] = [:]
    /// 编辑页底图：游戏号 → 封面文件
    public private(set) var bannerURLs: [String: URL]
    /// 本地玩家（#623，LocalPlayers.swift）：表与当前玩家（存在 App 偏好 stores.app）；切换页开着时 playersOpen
    @ObservationIgnored private let playerStore: LocalPlayers
    public private(set) var players: [LocalPlayer]
    public private(set) var currentPlayer: LocalPlayer
    public private(set) var playersOpen = false

    /// play 缺省走 C 出口；单测可换
    public init(catalogue: Catalogue, play: ((String) -> Void)? = nil, stores: S2ArmGameSettings.Stores = .live,
                layoutState: @escaping (String) -> S2ArmGameSettings.LayoutState = S2ArmGameSettings.layoutState,
                installState: ((String) -> Int32)? = nil, installGame: ((String) -> Bool)? = nil, installProgress: ((String) -> (Int, Int)?)? = nil,
                installPhase: ((String) -> (Int, Double?)?)? = nil, installFailure: ((String) -> String?)? = nil, installWait: (() -> Int32)? = nil,
                now: @escaping () -> Date = Date.init, pickGameData: ((String) -> Void)? = nil, identityStore: GameIdentityStore = .live,
                gamesRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/games"), packGamesRoot: URL? = nil) {
        self.gamesRoot = gamesRoot
        self.packGamesRoot = packGamesRoot ?? Self.packGamesRoot(for: gamesRoot)
        self.stores = stores; self.layoutState = layoutState; bannerURLs = catalogue.bannerURLs
        playerStore = LocalPlayers(shellDefaults: stores.app)
        players = playerStore.all; currentPlayer = playerStore.current
        self.identityStore = identityStore
        listedTiles = Dictionary(catalogue.tiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        listedBanners = catalogue.bannerURLs
        let strays = Self.otherComputerGames(gamesRoot, packRoot: self.packGamesRoot, listed: Set(catalogue.tiles.map(\.id)))
        allGames = catalogue.tiles.map { tile in
            var state = layoutState(tile.id); state.customIdentity = identityStore.load(tile.id) != nil
            return GameDetail(game: tile, sections: S2ArmGameSettings.sections(for: tile.id, stores: stores, state: state))
        } + strays.map { GameDetail(game: $0) }
        listedStates = Dictionary((catalogue.tiles + strays).map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        self.play = play ?? { id in _ = id.withCString { s2a_shell_play($0) } }
        self.installState = installState ?? { id in id.withCString { s2a_shell_game_install_state($0) } }
        self.installGame = installGame ?? { id in id.withCString { s2a_shell_install_game($0) } != 0 }
        self.installWait = installWait ?? { s2a_shell_install_wait() }
        self.installProgress = installProgress ?? { id in
            var done: Int32 = 0, total: Int32 = 0
            return id.withCString { s2a_shell_install_progress($0, &done, &total) } != 0 ? (Int(done), Int(total)) : nil
        }
        self.installPhase = installPhase ?? { id in
            var phase: Int32 = 0, fraction: Double = -1
            return id.withCString { s2a_shell_install_phase($0, &phase, &fraction) } != 0 ? (Int(phase), fraction < 0 ? nil : fraction) : nil
        }
        self.installFailure = installFailure ?? { id in id.withCString { s2a_shell_install_failure($0) }.map { String(cString: $0) } }
        self.now = now
        self.pickGameData = pickGameData ?? { id in id.withCString { s2a_shell_pick_game_data($0) } }
        let savedOrder = stores.app.stringArray(forKey: "S2ALibraryOrder") ?? []
        var remaining = allGames
        allGames = savedOrder.compactMap { id in
            guard let index = remaining.firstIndex(where: { $0.id == id }) else { return nil }
            return remaining.remove(at: index)
        } + remaining
        for tile in catalogue.tiles { applyIdentity(tile.id) }
        for p in catalogue.problems { NSLog("S2Arm 游戏库：%@", p) }
        Self.sweepDeleting(gamesRoot)
        refreshGameData()
        // 测试开关（真机自动化要 XCTest 触控 ID 授权、人不在时点不进去；同 diag.m S2A_OPEN_SETTINGS，环境变量只有 devicectl / Xcode 起 App 能给，玩家碰不到）：
        //   S2A_SHELL_OPEN_LAYOUT_EDITOR=<游戏号> 起来直接盖上这款的「调整位置」编辑页
        //   S2A_SHELL_PLAY=<游戏号> 起来 2 秒后替人点这款的 Play（走同一条 requestPlay → C 出口；截图局别带 S2A_AUTOPLAY=1：没有视觉驾驶员时自动玩家判卡住、优雅退出）
        let env = ProcessInfo.processInfo.environment
        if let id = env["S2A_SHELL_OPEN_LAYOUT_EDITOR"], allGames.contains(where: { $0.id == id }) {
            editingLayout = id; NSLog("S2Arm 游戏库：S2A_SHELL_OPEN_LAYOUT_EDITOR 直接开 %@ 的调整位置页", id)
        }
        if let id = env["S2A_SHELL_PLAY"], allGames.contains(where: { $0.id == id }) {
            NSLog("S2Arm 游戏库：S2A_SHELL_PLAY 2 秒后开始 %@", id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.requestPlay(id) }
        }
    }

    /// 手机上有、容器清单里没有的款：同一台手机在另一台电脑上装过，这台电脑重组容器时带不上（App 里的游戏程序读不回电脑）。
    /// 存档和资源包都还在，显示成不可玩并告诉玩家回原来那台电脑重装。只认目录名是 16 位游戏号、资源包已解开（资源包/.applied）的，别的跳过；
    /// 名字和图标取这款资源包自带的 ctl/control.nacp 与 icon_*.dat，读不到用游戏号、占位图
    static func otherComputerGames(_ root: URL, packRoot: URL?, listed: Set<String>) -> [GameTile] {
        let fm = FileManager.default
        let ids = Set([root, packRoot].compactMap { $0 }.flatMap { (try? fm.contentsOfDirectory(atPath: $0.path)) ?? [] })
        return ids.sorted().compactMap { id in
            let pack = packDir(id, games: root, packs: packRoot)
            guard isTitleID(id), !listed.contains(id), fm.fileExists(atPath: pack.appendingPathComponent(".applied").path) else { return nil }
            let ctl = pack.appendingPathComponent("ctl")
            let icon = ["SimplifiedChinese", "AmericanEnglish"].lazy.compactMap { try? Data(contentsOf: ctl.appendingPathComponent("icon_\($0).dat")) }.first
            NSLog("S2Arm 游戏库：%@ 在机上、不在这个 App 的清单里（别的电脑装的），显示需要重装", id)
            return GameTile(id: id, title: nacpTitle(try? Data(contentsOf: ctl.appendingPathComponent("control.nacp"))) ?? id,
                            icon: icon.flatMap { Artwork(id: id + ".icon", data: $0) },
                            state: .broken(reason: shellText("Reinstall from the original computer"),
                                           detail: shellText("This game was installed from another computer. Its saves and game data are still on this iPhone; on that computer, choose “Install to iPhone” again to bring it back.")))
        }
    }

    /// NACP 标题：16 种语言各 0x300 字节（名字占前 0x200）；中文界面先取简体中文（14）再英文（0），否则反过来
    static func nacpTitle(_ data: Data?) -> String? {
        guard let data, data.count >= 16 * 0x300 else { return nil }
        let order = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? [14, 0] : [0, 14]
        for i in order {
            let start = data.startIndex + i * 0x300
            if let t = String(data: data[start ..< start + 0x200].prefix { $0 != 0 }, encoding: .utf8), !t.isEmpty { return t }
        }
        return nil
    }

    /// 重判各款装机阶段（建好、回前台、解完、宿主说明里「重新检查」后，库开着时每秒一次）：
    ///   就绪 → 清单写的状态；传着 → 按传输清单画进度（久不动 → 传输中断）；传完 → 后台解开、画解包进度（没解成 → 安装没完成）；没有 → 不显示
    public func refreshGameData() {
        var missing = Set<String>()
        defer {
            if missing != notOnDevice { notOnDevice = missing; NSLog("S2Arm 游戏库：这台设备上 %d / %d 款可显示", allGames.count - missing.count, allGames.count) }
            startTicker()
        }
        for i in allGames.indices {
            let id = allGames[i].id, listed = listedStates[id] ?? allGames[i].game.state
            let want: GameState
            switch installState(id) {
            case 1, 4: want = listed; installTried.remove(id)   // 4 = 只缺非核心文件：库里照样可玩，点开始时宿主问一次「仍要启动」（v0.3.1）
            case 2: want = .installing(unpackStage(id))
            case 3: want = .installing(transferStage(id))   // 断了也接着看：电脑重新插上续传时字节又涨
            default:   // 资源不在：玩家删掉的不显示；没删过的留在库里显示「需要游戏数据」，Play 点到只给导入说明，不放行（审计 P1-155）
                if removed.contains(id) { missing.insert(id) }
                want = listed == .playable ? .needsGameData : listed
            }
            if installState(id) != 0, removed.contains(id) { removed.remove(id); saveRemoved() }   // 资源又回来了（电脑重装）：不再当删掉的
            noteDataSize(i, ready: [1, 4].contains(installState(id)))
            let fresh = want == .playable && isFresh(id)
            if allGames[i].game.isNew != fresh { allGames[i].game.isNew = fresh }
            if allGames[i].game.state != want {
                if want.installPhase != allGames[i].game.state.installPhase { NSLog("S2Arm 游戏库：%@ → %@", id, String(describing: want)) }
                allGames[i].game.state = want
            }
        }
    }

    /// 游戏设置页「游戏数据」那一栏（11-11 宿主梳理：原先永远「未选择数据」、点「选择…」没反应）：资源已就绪的款显示
    ///   「已就绪 · 本机占用 X」，只读。占用要遍历这款整个数据根（一款约 10 万文件），后台算一次、按游戏缓存；不就绪（没有 / 传着 /
    ///   解着）就清掉缓存和显示，装好或删除后下一次重判重新算。显示「选择…」只在还没有数据时（ShellUI GameDetailView）
    @ObservationIgnored private var dataSizes: [String: Int64] = [:]
    @ObservationIgnored private var sizing: Set<String> = []
    private func noteDataSize(_ i: Int, ready: Bool) {
        let id = allGames[i].id
        guard ready else {
            dataSizes[id] = nil
            if !allGames[i].dataSource.isEmpty { allGames[i].dataSource = "" }
            return
        }
        if let size = dataSizes[id] {
            let img = FileManager.default.fileExists(atPath: packDir(id).appendingPathComponent("game.img").path)
            let text = shellText("Ready · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) on this device") + " · "
                + (img ? shellText("single game file") : shellText("separate files"))
            if allGames[i].dataSource != text { allGames[i].dataSource = text }
            return
        }
        guard !sizing.contains(id) else { return }
        sizing.insert(id)
        let dirs = [gamesRoot.appendingPathComponent(id), packGamesRoot?.appendingPathComponent(id)].compactMap { $0 }   // 存档等 + 新位置的资源包
        Task { [weak self] in
            let size = await Task.detached(priority: .utility) { dirs.reduce(Int64(0)) { $0 + Self.allocatedSize($1) } }.value
            guard let self else { return }
            self.sizing.remove(id); self.dataSizes[id] = size
            self.refreshGameData()
        }
    }
    /// 目录下全部文件占用的空间（按分配大小，与「设置 → 储存空间」同口径）
    nonisolated static func allocatedSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        var total: Int64 = 0
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        for case let file as URL in walk {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// 传完了：没起过就在后台解开（正在解别的款 → 排着，下一秒再试）；起过、宿主说已不在解、还是阶段 2 → 没解成
    private func unpackStage(_ id: String) -> InstallStage {
        // 单一 IMG：解开推送包 / 解小文件 / 核对三段各画一圈，卡片上写正在做哪一步；引擎没报阶段时照旧按包数画一段
        if let (phase, fraction) = installPhase(id), phase > 0 { return InstallStage(.installing, fraction: fraction, step: phase) }
        if let (done, total) = installProgress(id) { return InstallStage(.installing, fraction: total > 0 ? Double(done) / Double(total) : nil) }
        if installTried.contains(id) { return InstallStage(.failed, reason: installFailure(id)) }
        // 宿主拒了：说清在等什么（4 等另一款装完 / 5 正在整理游戏目录，ShellUI GameState installLabel），下一秒再试
        guard installGame(id) else { let wait = installWait(); return InstallStage(.installing, step: wait == 2 ? 5 : wait == 1 ? 4 : 0) }
        installTried.insert(id)
        return InstallStage(.installing, fraction: 0)
    }

    /// 传着：电脑开推时写的 资源包/.transfer 列了这次要传的文件和字节数，各文件已到多少字节（正在写的也算）÷ 总字节 = 进度；
    ///   传输清单和这些文件里最新的改动时刻离现在超过 transferStall → 传断了。只读这款自己的这几个文件
    private func transferStage(_ id: String) -> InstallStage {
        let pack = packDir(id), list = pack.appendingPathComponent(".transfer")
        let fm = FileManager.default
        func info(_ url: URL) -> (Int64, Date)? {
            guard let a = try? fm.attributesOfItem(atPath: url.path), let size = a[.size] as? NSNumber, let at = a[.modificationDate] as? Date else { return nil }
            return (size.int64Value, at)
        }
        guard let data = try? Data(contentsOf: list), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = (json["total"] as? NSNumber)?.int64Value, total > 0, let files = json["files"] as? [[Any]], let listed = info(list) else {
            // 没有传输清单（老电脑端推的、被删了）或读不出：看不了进度，但照样按资源包里这几样最新的改动判传断了（iOS 装机剃刀 #41：原先永远「传输中」）。
            //   一样都看不到时只能说在传
            let incoming = pack.appendingPathComponent(".incoming")
            let tars = (try? fm.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil)) ?? []
            let seen = ([pack, incoming, list, pack.appendingPathComponent("manifest.json"), pack.appendingPathComponent("index.tsv"),
                         pack.appendingPathComponent("game.img")] + tars).compactMap { info($0)?.1 }
            if let latest = seen.max(), now().timeIntervalSince(latest) > Self.transferStall { return InstallStage(.interrupted) }
            return InstallStage(.transferring)
        }
        var got: Int64 = 0, latest = listed.1
        for f in files {
            guard f.count == 2, let rel = f[0] as? String, let want = (f[1] as? NSNumber)?.int64Value, !rel.hasPrefix("/"), !rel.contains(".."),
                  let (size, at) = info(pack.appendingPathComponent(rel)) else { continue }
            got += min(size, want); latest = max(latest, at)
        }
        // base = 这款已在手机上的字节（续传 / 重装只传剩下的）：进度按整款算，从断点接着涨、不往回掉
        let base = max(0, (json["base"] as? NSNumber)?.int64Value ?? 0), fraction = Double(base + got) / Double(base + total)
        if got < total, now().timeIntervalSince(latest) > Self.transferStall { return InstallStage(.interrupted, fraction: fraction) }
        return InstallStage(.transferring, fraction: fraction)
    }

    /// 装好（或更新）后还没点开过：资源包解开的时刻（资源包/.applied）比这款最后一次点开始（.played，requestPlay 写）新。
    ///   没有 .played、但有存档目录 S2A/（这版之前就玩过）→ 算玩过，不因升级让每款都亮蓝点
    private func isFresh(_ id: String) -> Bool {
        let dir = gamesRoot.appendingPathComponent(id), fm = FileManager.default
        func mtime(_ url: URL) -> Date? { (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }
        guard let applied = mtime(packDir(id).appendingPathComponent(".applied")) else { return false }
        if let played = mtime(dir.appendingPathComponent(Self.playedMark)) { return applied > played }
        return !fm.fileExists(atPath: dir.appendingPathComponent(Self.saveRoot).path)
    }
    static let playedMark = ".played"

    /// 这款资源包在哪：新位置有就是新位置；只有老位置（还没迁、或电脑往老位置推着）就是老位置；都没有算新位置。
    ///   同电脑端 pack/jobs/install.py pick_pack_root 的推送规则，宿主迁移（pack_apply.c s2a_pack_migrate_one）后老位置不再存在
    nonisolated static func packDir(_ id: String, games: URL, packs: URL?) -> URL {
        let old = games.appendingPathComponent(id).appendingPathComponent("资源包")
        guard let packs else { return old }
        let new = packs.appendingPathComponent(id).appendingPathComponent("资源包")
        let fm = FileManager.default
        return !fm.fileExists(atPath: new.path) && fm.fileExists(atPath: old.path) ? old : new
    }
    private func packDir(_ id: String) -> URL { Self.packDir(id, games: gamesRoot, packs: packGamesRoot) }
    /// 游戏根是 <家>/Documents/games（宿主的取法）→ <家>/Library/Application Support/S2Arm/games；别的根（单测换了根）→ nil
    nonisolated static func packGamesRoot(for gamesRoot: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL? {
        guard gamesRoot.standardizedFileURL.path == home.appendingPathComponent("Documents/games").standardizedFileURL.path else { return nil }
        return home.appendingPathComponent("Library/Application Support/S2Arm/games")
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshGameData() } }
    }

    public var actions: ShellActions {
        var actions = ShellActions(onPlay: { [weak self] id in self?.requestPlay(id) },
                     onChange: { [weak self] id, setting, value in self?.change(id, setting, value) },
                     onPickGameData: { [weak self] id in self?.requestGameData(id) },
                     onPickShellCloud: Self.pickCloudFolder, onClearShellCloud: Self.pickCloudFolder == nil ? nil : { CloudSaves.forget() },
                     onButtonTest: { [weak self] open in self?.buttonTest(open) },
                     onDeleteGame: { [weak self] id, saves in self?.deleteGame(id, saves: saves) },
                     onManageSaves: { [weak self] id in self?.manageSaves(id) })
        actions.onReorderGames = { [weak self] sources, before in self?.reorderGames(sources, before: before) ?? false }
        actions.onReportProblem = { s2a_shell_report_problem() }   // 故障报修（宿主 ios/diag.m：可不填的一句说明 + 打包上传、给短码）
        return actions
    }

    /// Native reordering supplies stable IDs and an insertion point after the drag finishes.
    private func reorderGames(_ sources: [String], before destination: String?) -> Bool {
        let moving = Set(sources)
        let visible = Set(games.map(\.id))
        guard !sources.isEmpty, moving.count == sources.count, moving.isSubset(of: visible) else { return false }
        if let destination {
            guard visible.contains(destination), !moving.contains(destination) else { return false }
        }
        let entries = Dictionary(uniqueKeysWithValues: allGames.map { ($0.id, $0) })
        var reordered = allGames.filter { !moving.contains($0.id) }
        let insertion = destination.flatMap { id in reordered.firstIndex { $0.id == id } } ?? reordered.count
        reordered.insert(contentsOf: sources.compactMap { entries[$0] }, at: insertion)
        allGames = reordered
        stores.app.set(allGames.map(\.id), forKey: "S2ALibraryOrder")
        return true
    }

    /// 库设置「云存档 → 选择文件夹…」（iCloud 存档同步，见 CloudSaves.swift）：iOS 弹系统文件夹选择器；Mac 上跑单测时没有界面
    static var pickCloudFolder: (() -> Void)? {
        #if canImport(UIKit)
        return { CloudFolderPicker.present() }
        #else
        return nil
        #endif
    }

    /// 只放行可运行的那款（界面本身也只在 playable 时调 onPlay，这里再守一道）；放行前当场重判资源包（库开着时资源被删 / 换机拷走）
    /// 长按卡片「管理存档…」（11-11 宿主梳理：原先在主屏快捷菜单里，库里不知道是哪款，一进 App 就弹退出框）：记下这一款
    ///   「下次开局先进存档管理」（ios/save_transfer.m 同一个按游戏的键 S2ASaveManageOnOpen.<游戏号>），再照常开始这一款，起局前就进存档管理页
    public func manageSaves(_ id: String) {
        guard allGames.contains(where: { $0.id == id }), id.allSatisfy({ $0.isHexDigit }) else { return }
        stores.app.set(true, forKey: "S2ASaveManageOnOpen." + id)
        requestPlay(id)
    }

    public func requestPlay(_ id: String) {
        if allGames.first(where: { $0.id == id })?.game.state.installPhase == .failed { installTried.remove(id) }   // 「安装没完成」点重试：再解一次
        refreshGameData()
        if allGames.first(where: { $0.id == id })?.game.state == .needsGameData { requestGameData(id); return }
        guard let g = allGames.first(where: { $0.id == id }), g.game.state == .playable else {
            NSLog("S2Arm 游戏库：Play %@ 被拒（不在列表或不可运行）", id)
            return
        }
        try? Data().write(to: gamesRoot.appendingPathComponent(id).appendingPathComponent(Self.playedMark))   // 点开过：蓝点消掉
        if let i = allGames.firstIndex(where: { $0.id == id }) { allGames[i].game.isNew = false }
        play(id)
    }

    /// 存档在这款数据根下的 S2A/（Ryujinx 数据根 <文档根>/S2A/ryujinx，存档 bis/user/save，同 pack/jobs/install.py SAVE_REL）
    static let saveRoot = "S2A"
    /// 玩家在这台设备上删掉的游戏号（一行一个，<游戏根>/.s2a-removed.txt）：资源不在时这些款不显示，别的款显示「需要游戏数据」
    nonisolated static let removedList = ".s2a-removed.txt"
    @ObservationIgnored private lazy var removed: Set<String> = {
        let text = (try? String(contentsOf: gamesRoot.appendingPathComponent(Self.removedList), encoding: .utf8)) ?? ""
        return Set(text.split(whereSeparator: \.isNewline).map(String.init).filter { $0.allSatisfy(\.isHexDigit) && !$0.isEmpty })
    }()
    private func saveRemoved() {   // 写不进只记日志：最坏是删掉的款下次显示成「需要游戏数据」
        let text = removed.sorted().joined(separator: "\n")
        do {
            try FileManager.default.createDirectory(at: gamesRoot, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: gamesRoot.appendingPathComponent(Self.removedList), options: .atomic)
        } catch { NSLog("S2Arm 游戏库：记删除名单失败：%@", error.localizedDescription) }
    }

    /// 删除这款的本机数据：saves = 连存档一起删（整个数据根），否则留下 S2A/（存档与用户资料）、其余（资源包、名字封面等）删掉。
    /// v0.2.6 玩家反馈「点删除完全没反应」：原先在主线程上同步 removeItem，一款资源包约 10 万文件，删完前界面整个冻住、对话框都不关，
    ///   失败只进日志（模拟器 10 万文件实测点下到卡片消失 17.8 秒）。现在分两步：
    ///   ① 主线程上只把要删的东西改名挪进 <游戏根>/.deleting/<游戏号>-<随机>（同卷改名，毫秒级），随即重判，这款当场离开列表；
    ///   ② 后台把 .deleting 里那份真删掉，边删边累计占用的空间，删完提示「已删除，释放 X」；挪不动 / 删不掉提示失败原因。
    ///   删到一半 App 被结束：下次打开时后台接着清 .deleting（init 里 sweepDeleting）
    public func deleteGame(_ id: String, saves: Bool) {
        guard allGames.contains(where: { $0.id == id }), id.allSatisfy({ $0.isHexDigit }) else { return }
        let title = allGames.first(where: { $0.id == id })?.game.title ?? id
        let fm = FileManager.default, dir = gamesRoot.appendingPathComponent(id)
        let trash = gamesRoot.appendingPathComponent(Self.deletingDir).appendingPathComponent("\(id)-\(UUID().uuidString)")
        var moved = false, moveError: Error?
        do {
            try fm.createDirectory(at: trash, withIntermediateDirectories: true)
            if saves {
                if fm.fileExists(atPath: dir.path) { try fm.moveItem(at: dir, to: trash.appendingPathComponent(id)); moved = true }
            } else {
                for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where item.lastPathComponent != Self.saveRoot {
                    try fm.moveItem(at: item, to: trash.appendingPathComponent(item.lastPathComponent)); moved = true
                }
            }
            // 新位置的资源包（Library 下，同一个 App 容器、同卷改名）一起挪进待删目录
            if let packs = packGamesRoot?.appendingPathComponent(id), fm.fileExists(atPath: packs.path) {
                try fm.moveItem(at: packs, to: trash.appendingPathComponent(".pack")); moved = true
            }
        } catch { moveError = error }
        if moveError == nil { removed.insert(id); saveRemoved() }   // 玩家删的：资源不在时不再显示（没删成的照旧留在库里）
        refreshGameData()
        if let moveError {   // 挪了一半的照样后台删掉，提示失败原因
            NSLog("S2Arm 游戏库：删除 %@ 失败（挪进待删目录）：%@", id, moveError.localizedDescription)
            show(DeleteNotice(gameID: id, title: title, phase: .failed(moveError.localizedDescription)))
        } else if moved {
            NSLog("S2Arm 游戏库：%@ 的本机数据%@已挪进待删目录，后台删除", id, saves ? "（含存档）" : "（存档保留）")
            show(DeleteNotice(gameID: id, title: title, phase: .deleting))
        } else {   // 本来就没有可删的
            show(DeleteNotice(gameID: id, title: title, phase: .done(freed: 0)))
        }
        let report = moveError == nil && moved
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Self.purge(trash) }.value
            switch result {
            case .success(let freed): NSLog("S2Arm 游戏库：%@ 删完，释放 %lld 字节", id, freed)
            case .failure(let error): NSLog("S2Arm 游戏库：%@ 后台删除失败：%@", id, error.localizedDescription)
            }
            guard report, let self else { return }
            switch result {
            case .success(let freed): self.show(DeleteNotice(gameID: id, title: title, phase: .done(freed: freed)))
            case .failure(let error): self.show(DeleteNotice(gameID: id, title: title, phase: .failed(error.localizedDescription)))
            }
        }
    }

    /// 删除进度与结果（宿主视图在库上方画一条提示）：正在删除 → 已删除（释放多少）/ 失败原因；结果停留 4 秒后自动收起
    public struct DeleteNotice: Equatable, Sendable {
        public enum Phase: Equatable, Sendable { case deleting, done(freed: Int64), failed(String) }
        public let gameID: String, title: String, phase: Phase
    }
    public private(set) var deleteNotice: DeleteNotice?
    @ObservationIgnored private var noticeDismiss: Task<Void, Never>?
    static let noticeSeconds: Double = 4
    /// 换上新提示；结果（已删除 / 失败）停留 noticeSeconds 后收起，正在删除的一直显示到有结果
    private func show(_ notice: DeleteNotice) {
        deleteNotice = notice
        noticeDismiss?.cancel()
        guard notice.phase != .deleting else { return }
        noticeDismiss = Task { [weak self, notice] in
            try? await Task.sleep(for: .seconds(Self.noticeSeconds))
            guard !Task.isCancelled, let self, self.deleteNotice == notice else { return }
            self.deleteNotice = nil
        }
    }
    public func dismissDeleteNotice() { if deleteNotice?.phase != .deleting { deleteNotice = nil } }

    /// 待删目录名：点开头、不是 16 位游戏号，扫游戏根的地方（otherComputerGames、宿主按款核资源包）都不认它
    nonisolated static let deletingDir = ".deleting"
    /// 删掉 url 整棵树，返回删掉的文件占用的空间（字节，按分配大小算，与「设置 → 储存空间」同口径）
    nonisolated static func purge(_ url: URL) -> Result<Int64, Error> {
        let fm = FileManager.default
        var freed: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        if let walk = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
            for case let file as URL in walk {
                guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { continue }
                freed += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
        }
        do { try fm.removeItem(at: url) } catch { return .failure(error) }
        return .success(freed)
    }
    /// 上次删到一半 App 被结束留下的待删条目：后台接着删（不提示）。只删此刻已在 .deleting 里的那几项、不删 .deleting 本身——
    ///   打开 App 马上又删一款时，新挪进去的那份由它自己那次删除负责，两边不抢同一个目录
    nonisolated static func sweepDeleting(_ gamesRoot: URL) {
        let dir = gamesRoot.appendingPathComponent(deletingDir)
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard !leftovers.isEmpty else { return }
        Task.detached(priority: .utility) {
            var freed: Int64 = 0
            for item in leftovers { if case .success(let n) = purge(item) { freed += n } }
            NSLog("S2Arm 游戏库：清掉上次没删完的 %d 项待删数据，释放 %lld 字节", leftovers.count, freed)
        }
    }

    /// 「需要游戏数据」那款：交宿主给导入说明（宿主「重新检查」后经 s2a_shell_refresh 回到 refreshGameData）
    public func requestGameData(_ id: String) { pickGameData(id) }

    /// 设置行改了：存下、刷新这一款的设置行；选「调整位置…」打开编辑页
    public func change(_ id: String, _ setting: String, _ value: String) {
        if setting == S2ArmGameSettings.identity {
            if value == S2ArmGameSettings.editIdentity { editingIdentity = id; identityError = nil }
            refresh(id)
            return
        }
        if S2ArmGameSettings.apply(id: id, setting: setting, value: value, stores: stores) { editingLayout = id }
        refresh(id)
    }
    /// 编辑页关了（存了 / 取消 / 恢复默认）：布局行跟着刷新
    public func closeLayoutEditor() { if let id = editingLayout { editingLayout = nil; refresh(id) } }
    func refresh(_ id: String) {
        guard let i = allGames.firstIndex(where: { $0.id == id }) else { return }
        var state = layoutState(id); state.customIdentity = identityStore.load(id) != nil
        allGames[i].sections = S2ArmGameSettings.sections(for: id, stores: stores, state: state)
    }

    /// 改名字和封面的编辑页要用：当前显示的名字，以及有没有自定义
    public func identityName(_ id: String) -> String { allGames.first(where: { $0.id == id })?.game.title ?? "" }
    public func hasCustomIdentity(_ id: String) -> Bool { identityStore.load(id) != nil }

    /// 名字和封面一次提交（GameIdentityStore.save）。存成了关编辑页；没存成不关页、留着玩家填的，identityError 给编辑页显示原因
    public func saveIdentity(_ id: String, name: String, cover: Data?) {
        // 名字没动时不存成自定义，否则电脑端以后改名就传不到这台手机
        let keep = name == listedTiles[id]?.title ? "" : name
        do { try identityStore.save(id, name: keep, cover: cover) }
        catch {
            NSLog("S2Arm 游戏库：保存 %@ 的名字和封面失败：%@", id, error.localizedDescription)
            identityError = error.localizedDescription
            return
        }
        closeIdentityEditor(id)
    }
    public func resetIdentity(_ id: String) { identityStore.clear(id); closeIdentityEditor(id) }
    public func closeIdentityEditor(_ id: String) { editingIdentity = nil; identityError = nil; applyIdentity(id); refresh(id) }

    /// 把这台手机上的名字和封面叠到清单条目上；没有就回到清单原样，状态保持不变。
    private func applyIdentity(_ id: String) {
        guard let i = allGames.firstIndex(where: { $0.id == id }), var tile = listedTiles[id] else { return }
        tile.state = allGames[i].game.state
        bannerURLs[id] = listedBanners[id]
        if let custom = identityStore.load(id) {
            if !custom.name.isEmpty { tile.title = custom.name }
            if let url = custom.cover, let data = try? Data(contentsOf: url), let art = Artwork(id: id + ".custom.\(data.hashValue)", data: data) {
                tile.banner = art; tile.icon = art; bannerURLs[id] = url
            }
        }
        allGames[i].game = tile
    }

    // MARK: 本地玩家（#623）

    /// 游戏库顶部玩家按钮：开切换页。开着时停手柄监听（页只用触屏），不然按 A 会落到背后库界面的 Play 上
    public func openPlayers() { playersOpen = true; stopControllers() }
    public func closePlayers() { guard playersOpen else { return }; playersOpen = false; startControllers() }
    /// 换玩家：下一局按这个玩家起（宿主 ios/settings.m 起局时读），关页
    public func selectPlayer(_ uid: String) {
        playerStore.select(uid); reloadPlayers()
        NSLog("S2Arm 游戏库：本地玩家切换为 %@", currentPlayer.isFirst ? "第一个玩家" : currentPlayer.uid)
        closePlayers()
    }
    /// 加玩家并选上；名字不行回给玩家看的原因（nil = 成了）
    public func addPlayer(_ name: String) -> String? {
        do { let p = try playerStore.add(name); reloadPlayers(); NSLog("S2Arm 游戏库：新建本地玩家 %@（存档位置 %@）", p.uid, p.folder); return nil }
        catch { return Self.reason(error) }
    }
    public func renamePlayer(_ uid: String, _ name: String) -> String? {
        do { try playerStore.rename(uid, to: name); reloadPlayers(); return nil } catch { return Self.reason(error) }
    }
    /// 从表里拿掉（存档不删）
    public func removePlayer(_ uid: String) {
        playerStore.remove(uid); reloadPlayers()
        NSLog("S2Arm 游戏库：拿掉本地玩家 %@（存档留在各款数据里）", uid)
    }
    private func reloadPlayers() { players = playerStore.all; currentPlayer = playerStore.current }
    static func reason(_ error: LocalPlayers.NameError) -> String {
        switch error {
        case .empty: shellText("Enter a name.")
        case .taken: shellText("That name is already taken.")
        }
    }

    public func startControllers() {
        adapter.onInput = { [weak self] action, device in self?.input.append(action, device: device) }
        adapter.onRelease = { [weak self] action, device in self?.input.append(action, device: device, released: true) }
        adapter.onControllersChange = { [weak self] connected in
            self?.controllers = connected.map {
                ControllerInfo(id: $0.id, name: $0.name, player: "P\($0.player)", batteryPercent: $0.batteryPercent, charging: $0.charging)
            }
        }
        adapter.start()
    }

    public func stopControllers() { adapter.stop() }

    func buttonTest(_ open: Bool) {
        adapter.onSnapshot = open ? { [weak self] in self?.padSnapshot = $0 } : nil
        if !open { padSnapshot = nil }
    }
}
