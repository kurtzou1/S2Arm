// S2Arm（不是上游文件）：S2Arm × NX2Apple 界面的状态，接 S2ArmAppleAdapter 的 S2ArmEngineProvider（设计稿 2.13 EngineProvider）。
// 只持有界面要画的状态、把动作转给适配层；作业怎么起、请求长什么样都在适配层。
import AppKit
import Foundation
import Combine
import NXModel
import S2ArmAppleAdapter
import SaveSync

/// 一次出包（勾了几个平台就几个作业，按页面顺序排队，ExportPlatform.picked）：现在做到第几个、每个平台的结局。
struct ExportRun: Equatable {
    struct Outcome: Equatable {
        var state: JobOutcome.State
        /// 没成时的原因（作业层原句，显示经 loc.backend）。
        var message = ""
        var code: String?
        /// Mac：运行文件目录；iPhone：IPA 与资源包所在文件夹。
        var output: String?
        /// iPhone：IPA 文件。
        var ipa: String?
        /// 成品大小（字节）：iPhone = IPA，Mac = 运行版本。作业层量的，量不出为 nil。
        var appBytes: Int64?
        /// iPhone 资源包大小（字节）。
        var packBytes: Int64?
        /// 作业层给的下一步建议（玩家话术）。
        var suggestion = ""
        /// 这个平台用了多久（秒）。
        var seconds: Double = 0
        /// 作业层给的失败事实（阶段、退出码、原文，英文标签）；没有为 nil。
        var failureSummary: String?
        /// 出成了、但有阶段降级继续（v0.3.1，产物根 degrade.*.tsv 的「玩家提示」）：完成卡逐条显示
        var notes: [String] = []
    }
    let platforms: [ExportPlatform]
    /// 正在做的那个平台（platforms 的下标）。
    var index = 0
    var outcomes: [ExportPlatform: Outcome] = [:]
    /// 整次出包、当前平台开始的时刻。
    let started: Date
    var platformStarted: Date
    var current: ExportPlatform { platforms[min(index, platforms.count - 1)] }
    var failed: [ExportPlatform] { platforms.filter { outcomes[$0].map { $0.state != .completed } ?? false } }

    init(platforms: [ExportPlatform], now: Date = Date()) {
        self.platforms = platforms; started = now; platformStarted = now
    }
}

/// 出包没全成（有平台失败）：作业页按平台写结局，整次记失败。
struct ExportIncomplete: Error {}

/// 出包页底栏「为什么还不能出包」。
enum ExportBlocker: Equatable {
    case noPlatform, game(String), keys, busy
    /// 这款已在出包或排队（同一款再点一次 / 控制口重发）：原先静默当成功、什么也不做，控制口回 ok 却没建任务
    case alreadyQueued
    /// 挡不挡开始：缺文件 / 缺 keys 只提示、不挡（v0.3.1 维护者「拿不准不停」）——这两项来自游戏库读数，可能是旧的（刚插上盘、刚导入 keys），
    ///   出包作业开头自己核（library.requirement_errors：找不到原件 input_missing、缺 prod.keys keys_missing），真缺才停、说清怎么办
    var stopsStart: Bool { switch self { case .game, .keys: return false; default: return true } }
}

/// 正在跑 / 刚结束的一个作业（一局、出包、准备运行、装到 iPhone、导入、一键处理环境、换游戏库）。同一时刻只有一个（同旧启动器「执行位」互斥）。
struct JobSession: Equatable {
    enum Kind: String, CaseIterable { case play, export, prepare, install, installRemove, installRestore, installUpdate, importGames = "import", downloadMetal, downloadIosPlatform, installDotnet, setupLibrary = "setup",
                        keys, delete, diagnostics, moveGame, clearCache }
    enum Phase: Equatable { case running, stopping, finished(JobOutcome.State) }
    let kind: Kind
    let gameID: String?
    let name: String
    var phase: Phase = .running
    var stage = ""
    var message = ""
    /// 最近的作业事件（阶段 / 消息），最新在后。
    var log: [String] = []
    /// 第几步、本阶段计数、剩余时间（JobProgress，从作业事件来）。
    var progress = JobProgress()
    /// 做完可以在访达里显示的东西。
    var reveal: String?
    /// 出包：平台队列与各平台结局（别的作业为 nil）。
    var export: ExportRun?
    /// 出包前的磁盘预算（作业层 space 事件，check_pack_space）；没有为 nil。
    var space: PackSpace?
    /// 作业层给的失败码与下一步（JobFailure 的第一条诊断）：启动页按码显示一句人话 + 下一步，原文只进「复制错误摘要」
    var failureCode: String?
    var suggestion = ""
    /// 正在跑的那个作业层任务号（最近一个事件的 taskId；出包一个平台一个任务）。控制口 GET /state 的 executionTask 报它（原先恒为空，s2armctl next 判不出「本游戏正在运行」）
    var taskID: String?
    /// 开工 / 结束的时刻：手机作业结局页的「用时」
    var started = Date()
    var ended: Date?
    /// 走过的阶段（阶段事件的作业层原句，按出现顺序、不重复）：手机作业进行中页的步骤列表
    var stages: [String] = []
    /// 手机作业（装到手机 / 续签、删除、装回、更新手机上的 S2Arm）：结局页统一用 PhoneJobPanel
    var isPhoneJob: Bool { [.install, .installRemove, .installRestore, .installUpdate].contains(kind) }
}

/// 手机作业做完后结局页要说的事实（从作业结果读，不猜）：装到哪台、这次推了多少、哪几款被跳过
struct PhoneOutcome: Equatable {
    var device = ""
    var packFiles: Int? = nil
    var packBytes: Int64? = nil
    var skipped: [String] = []
    var version = ""
}

/// 排队的一次出包。
struct QueuedExport {
    let game: GameSummary
    let platforms: [ExportPlatform]
    let target: [String: Any]?
    let spaceOverride: Bool
    /// 存放位置（游戏库结构 v3）：nil = 这款现在的位置 / 上次用的位置（后端定）
    var location: String? = nil
}

/// 这次出包要占多少、盘上还有多少（只取游戏库所在的卷）。
struct PackSpace: Equatable {
    let need: Int64?
    let free: Int64?
    let basis: String

    init?(_ value: Any?) {
        guard let v = value as? [String: Any], let volumes = v["volumes"] as? [[String: Any]],
              let volume = volumes.first(where: { $0["role"] as? String == "library" }) ?? volumes.first else { return nil }
        need = (volume["needBytes"] as? NSNumber)?.int64Value
        free = (volume["freeBytes"] as? NSNumber)?.int64Value
        basis = volume["basis"] as? String ?? ""
    }
}

@MainActor
public final class S2ArmLauncherModel: ObservableObject {
    @Published private(set) var games: [GameSummary] = []
    @Published private(set) var loading = false
    /// 游戏库读回来过（成功或失败）：之前库是空的只说明还没读完，不能显示「还没有游戏」。
    @Published private(set) var libraryLoaded = false
    @Published private(set) var libraryError: String?
    /// 库页上的列表是上次读到的快照（启动时先显示的，或这次刷新没成）：库页要标明，并在刷新失败时给重试（审计 P1-148）。
    @Published private(set) var showingSnapshot = false
    /// 刷新没成、库页仍显示上次的列表：这时的失败原因（没能刷新提示用；第一次就没读成、列表是空的走欢迎页的报错）。
    var staleLibraryError: String? { showingSnapshot && !games.isEmpty ? libraryError : nil }
    @Published var selectedID: String?
    /// 出包平台的勾选没能写盘。
    @Published private(set) var choiceError: String?
    @Published var session: JobSession?   // 批量出包时编排作业一步换一款，+Batch.swift batchStepStarted 换会话
    /// 出包页开着的那一款（nil = 游戏库）。
    @Published var exportFor: String?
    /// 存放位置（游戏库结构 v3）：出包页下拉框的各项、上次用的位置号
    @Published var locations: [StorageLocation] = []
    @Published var lastLocation = ""
    /// 「选择其他文件夹…」选的路径所在盘会不会让解包多占数倍空间（#444；已登记的位置看 StorageLocation.slackWarning）
    @Published var probedSlack: [String: LocationSlack?] = [:]
    /// 出包页记住的平台勾选（平台 id）。
    @Published private(set) var exportChoice: [String] = []
    /// 动作没能开始的原因（缺东西、没选游戏库等），显示在主按钮下面。只属于出错的那一款（导入等不针对某款的为 nil）：
    /// 换选别的游戏不显示上一款的报错（11-07 界面验收：丝之歌缺原件的红字挂到了 Hades 下面）。
    @Published private(set) var actionError: String?
    private(set) var actionErrorGameID: String?
    func actionError(for gameID: String?) -> String? { actionErrorGameID == nil || actionErrorGameID == gameID ? actionError : nil }
    private func failAction(_ text: String?, game: String?) { actionErrorGameID = game; actionError = text }
    // 环境检查
    @Published private(set) var checks: [ToolCheck] = []
    @Published private(set) var checking = false
    @Published private(set) var environmentError: String?
    @Published var showEnvironment = false
    /// 装到 iPhone 的方式（环境检查「装到 iPhone 的方式」卡，installMode 作业）与壳比本版旧的手机（catalog phoneUpdates，库页右上角按钮）
    @Published var installMode = InstallModeInfo()
    @Published var phoneUpdates: [PhoneUpdate] = []
    /// 点了更新、有要重新出包的款：三选一弹框；选「更新并重新出这几款」时更新完把它们排进批量出包（只出 iPhone），批次出完逐款装上
    @Published var updateConfirm: PhoneUpdate?
    var updateRepack: [String] = []
    var batchInstallAfter = false
    var installAfterQueue: [String] = []
    /// 添加游戏 / 放密钥弹窗（ImportSheet）：这两个作业的进度和失败原因都留在弹窗里，不换页。
    @Published var updateState: UpdateState = .idle
    @Published var notice: [String: Any]?   // 顶部公告条（S2ArmLauncherModel+Update.swift loadNotice）；nil = 不显示
    var updateReady: [String: Any]?
    @Published var showAddGames = false
    @Published var showKeys = false
    /// 选好了但缺密钥（作业层 keys_missing）：等放入密钥后接着导入。解包好的游戏不要密钥，不经过这里。
    @Published private(set) var pendingImport: [URL] = []
    /// 留在原页显示的作业没成的原因（换作业、关弹窗时清掉）。
    @Published private(set) var inlineFailure: (kind: JobSession.Kind, message: String, suggestion: String)?
    /// 最近一次手机作业的结局事实（PhoneJobPanel 成功页用）；每个手机作业开工时清空
    @Published var phoneOutcome: PhoneOutcome?
    /// 最近一次结束的手机作业（装机页的结局区读它：作业结束后 session 可能已被别的作业替换）
    @Published private(set) var lastPhoneSession: JobSession?
    /// 欢迎页上排着队的一键下载（作业同一时刻只有一个）。
    @Published private(set) var repairQueue: [ToolCheck] = []
    /// 新手流程刚导入的那款：欢迎页留着，右下角「一键出包」（点了就回到正常的游戏库）。
    @Published private(set) var welcomeGameID: String?
    /// 这份密钥读不了选的游戏：放密钥弹窗提示换一份。
    @Published private(set) var keysRejected = false
    /// 刚装好的那款（装机弹窗显示完成页）。
    @Published var installDone: String?
    /// 刚装完的那次是单一 IMG：成功页多写一句「打开 S2Arm 会自动完成安装」
    @Published var installOpenToFinish = false
    /// 最近一次手机作业（装到 iPhone / 从手机删 / 装回上一版）的结局，玩家还没回去看：顶部胶囊「已装好 · 查看结果」靠它（#308：关掉装机弹窗后找不回结果）。
    /// 新的手机作业开始、或打开这款的装机弹窗时清掉。
    @Published var phoneResult: (gameID: String, name: String, ok: Bool)?
    static let phoneKinds: Set<JobSession.Kind> = [.install, .installRemove, .installRestore]
    /// 连着的手机、可选机型（出包页用）；玩家选的机型（productType）。
    @Published private(set) var connectedDevices: [[String: Any]] = []
    @Published private(set) var targetModels: [[String: Any]] = []
    @Published private(set) var targetOS: [Int] = []
    @Published var chosenModel: String?
    /// 连着多台 iPhone / iPad 时玩家在出包页选的那台（设备号，记住到下次；#272）。按机型优化和装到设备都用它
    @Published var chosenDevice: String? = UserDefaults.standard.string(forKey: S2ArmLauncherModel.exportDeviceKey) {
        didSet { UserDefaults.standard.set(chosenDevice, forKey: Self.exportDeviceKey) }
    }
    static let exportDeviceKey = "S2AExportDevice"
    /// 排队等着出的；运行页被收起（后台继续）；本次打开以来每款最近一次的出包结果；正在查看的结果。
    @Published private(set) var exportQueue: [QueuedExport] = []
    /// 批量出包（v0.2.4，S2ArmLauncherModel+Batch.swift）：清单页开着；出包前每款的勾选行；一批共用的存放位置；
    ///   后端批次（pack/jobs/batch.py show 的结果，出包中途关掉启动器也在）；这批是不是正在一款接一款地出；放进来但认不出的
    @Published var batchShown = false
    @Published var batchDraft: [BatchRow] = []
    @Published var batchLocation = ""
    @Published var batchState: [String: Any]?
    @Published var batchRunning = false
    /// 正在跑的那个批量出包编排作业（取消 = 取消它，剃刀 H13）
    var batchWork: Task<Void, Never>?
    /// 批次记录（batch.py mark / 命令）没写成的原因：整批停住、批量页显示（剃刀 M7：原先失败照样往下走，状态和真实结局分叉）；nil = 没出错
    @Published var batchError: String?
    @Published var batchUnrecognized: [ImportSource] = []
    /// 在单款出包页又放进游戏：导入完列清单时这款排第一
    var batchSeed: String?
    @Published var sessionHidden = false
    @Published private(set) var finishedExports: [String: JobSession] = [:]
    @Published var viewingResult: JobSession?
    var showsWelcome: Bool { games.isEmpty || welcomeGameID != nil || welcomeHome }
    /// 点了顶栏品牌名：游戏库页先显示欢迎页（社区贡献者补丁 #2；点「游戏库」回到列表）
    @Published var welcomeHome = false
    /// 设置页「磁盘空间」：关掉设置、给这款打开磁盘空间面板（LauncherView 收到就开）
    @Published var spaceRequest: String?
    var welcomeGame: GameSummary? { games.first { $0.id == welcomeGameID } }
    // 装到 iPhone 前的清单
    @Published private(set) var installReadiness: InstallReadiness?
    /// 开发者证书（v0.2.4，S2ArmLauncherModel+DevCert.swift）：现况与体检；导入弹窗开着没有
    @Published var devCert: DevCertStatus?
    var failingReads: Set<String> = []   // 被动刷新正在连续失败的那几类（reportFailure 只报头一次）
    @Published var showDevCertImport = false
    @Published private(set) var customizing = false
    /// 非会话作业（换封面 / 改名、释放空间、存档）在等库锁时作业层的原句「在等「…」结束…」（phase=waiting_lock）；拿到锁或做完清空。
    /// 剃刀 M3：原先这几处只转圈，别的任务占着库时最长等 120 秒，玩家不知道在等什么
    @Published var lockWaitNote: String?

    /// 交给作业的事件去处：只认等锁进度，其余丢弃
    func lockWaitSink() -> EventSink {
        EventSink { [weak self] e in
            guard e.ev == "progress" else { return }
            let note = e.fields["phase"] as? String == "waiting_lock" ? e.message : nil
            Task { @MainActor in self?.lockWaitNote = note }
        }
    }
    @Published private(set) var customizeError: String?
    @Published private(set) var installChecking = false
    /// 当前这份装机前清单是给哪台设备查的（控制口 GET /state 的 installReadiness.checkedDevice）：换了设备先清掉旧清单，
    ///   s2armctl install-check --device 等到这台的结果才读（11-11 真机验收：连查两台，第二台读到了第一台的清单）
    @Published private(set) var installReadinessDevice: String?
    /// 正在查时又来了另一台（或另一款）的请求：记下，这次查完接着查它（原先直接丢掉）
    private var pendingInstallCheck: (game: String, device: String?)?
    @Published private(set) var installError: String?
    private(set) var installGameID: String?
    // 释放空间（spaceSurvey / spaceFree，FreeSpaceView）：只看一款
    @Published private(set) var space: GameSpace?
    @Published private(set) var spaceLoading = false
    @Published private(set) var spaceFreeing = false
    @Published private(set) var spaceError: String?
    /// 上一次释放了多少（字节）；换一款或重新打开时清掉。
    @Published private(set) var spaceFreed: Int64?
    private var spaceGameID: String?
    /// 游戏库页顶部一条操作提示（删除游戏 / 清除缓存）：点下就有「正在…」，结束换成「已…」或失败原因；有别的作业在跑时说清楚在等什么
    struct LibraryNotice: Equatable { enum Kind { case running, done, failed }; let kind: Kind; let key: String; let name: String; var detail: String = "" }
    @Published var libraryNotice: LibraryNotice?
    /// 读不到设备列表的原因（targetDevice 的 connectedError / 探测出错）：出包页设备那一行显示它，而不是「把 iPhone 插上」
    @Published var deviceProbeError: String?
    // 存储总览（storageOverview，FreeSpaceView 的「总览」）
    @Published private(set) var overview: StorageOverview?
    @Published private(set) var overviewLoading = false
    @Published private(set) var overviewError: String?

    let provider: S2ArmEngineProvider
    let controller: NS2LauncherController
    private var running: RunningGame?
    /// iCloud 存档同步进行中（开局前 / 退出后）：不重复开局
    @Published var cloudSyncing = false
    private var work: Task<Void, Never>?
    private var refreshWaiters: [() -> Void] = []
    /// 正在列时又要刷新（导入完、出包完、切回窗口……）：记一笔，这一轮列完再补列一次；这期间挂的回调归补的那一轮（剃刀 M8：原先直接丢掉，
    /// 刚导入的游戏要等下一次别的刷新才出现）。nil = 没有要补的
    private var refreshAgain: [() -> Void]?
    private var startupCatalogSent = false
    private var controllerGameStarted = false
    /// 导入后排着等准备的游戏（同旧启动器：放进来就自动准备，维护者 10-23 不让玩家选）。
    private static let logLimit = 200

    public init(client: JobClient) {
        provider = S2ArmEngineProvider(client: client)
        controller = NS2LauncherController(
            socketURL: provider.client.environment.privateRoot.appendingPathComponent("ns2-relay.sock"))
        exportChoice = provider.settings.exportTargets
    }

    var selected: GameSummary? { games.first { $0.id == selectedID } ?? games.first }
    /// 有作业在跑（一局、准备、出包、装机……）：别的动作先不让点。
    var busy: Bool { if let session, case .finished = session.phase { return false }; return session != nil }

    /// 启动时（启动器剃刀 M6）：碰游戏库 / 私有目录的后端作业一个接一个起——先列游戏库，再恢复批次，再查环境。
    /// 原先 onAppear 一次并发起这几个作业，每个作业开头都做迁移 / 收日志：两个作业同时收私有目录日志、老库搬家时旧库目录被建回来（坑记录）。
    /// 不碰游戏库的（控制口、更新、公告、手柄中继）照常一起起。
    func startup() {
        startControl(); finishPendingUpdate(); checkForUpdate(); loadNotice(); startControllerConnection()
        refresh { [weak self] in self?.recoverBatch { self?.checkEnvironment() } }
    }

    /// done：这次列完（成功或失败）后调；已经在列时不再起新作业，等那一次列完再调
    public func refresh(_ done: (() -> Void)? = nil) {
        guard !loading else { refreshAgain = (refreshAgain ?? []) + (done.map { [$0] } ?? []); return }
        if let done { refreshWaiters.append(done) }
        // 启动时先显示上次的列表，不等作业；能不能玩在真正启动时还会完整校验
        if !libraryLoaded, games.isEmpty, let known = provider.library.lastKnownGames(), !known.isEmpty {
            games = known
            selectedID = known.first?.id
            libraryLoaded = true
            showingSnapshot = true
        }
        loading = true
        // 启动器这次打开后的第一次读带 startup（剃刀 H14）：作业层只在这一次清残留 / 判任务目录清理，之后每次刷新只读
        let startup = !startupCatalogSent; startupCatalogSent = true
        provider.library.load(startup: startup) { [weak self] result in
            guard let self else { return }
            self.loading = false
            self.libraryLoaded = true
            switch result {
            case .success(let games):
                self.games = games; self.libraryError = nil; self.showingSnapshot = false
                self.phoneUpdates = self.provider.library.phoneUpdates
                if self.selectedID == nil || !games.contains(where: { $0.id == self.selectedID }) { self.selectedID = games.first?.id }
            case .failure(let error):
                self.libraryError = error.message
                self.showingSnapshot = !self.games.isEmpty   // 列表没换：还是上次的
            }
            let waiters = self.refreshWaiters; self.refreshWaiters = []
            waiters.forEach { $0() }
            if let again = self.refreshAgain { self.refreshAgain = nil; self.refreshWaiters = again; self.refresh() }
        }
    }

    // ---- environment ----

    /// 作业层「这台 Mac 缺东西」的错误码（pack/jobs/errors.py RECOVERY）：失败行据此给环境检查页入口（剃刀 M4）
    static let environmentCodes: Set<String> = ["xcode_unavailable", "xcode_setup_required", "metal_unavailable", "ios_platform_missing",
        "ios_platform_unregistered", "dotnet_unavailable", "dotnet_sdk_missing", "os_unsupported", "architecture_unsupported",
        "engine_incomplete", "engine_toolchain_newer"]

    enum EnvironmentState { case unknown, ready, readyMac, missing }
    /// ready = 准备、启动、打 iPhone 包都齐；readyMac = Mac 上准备/启动齐了、但打 iPhone 包还缺（如 iOS 平台组件只挡 ipa）。
    var environmentState: EnvironmentState {
        if checks.isEmpty { return .unknown }
        guard provider.environment.ready(for: "prepare") else { return .missing }
        return checks.contains { !$0.ok && $0.required(for: "ipa") } ? .readyMac : .ready
    }

    func checkEnvironment() {
        guard !checking else { return }
        checking = true; environmentError = nil
        Task {
            do { checks = try await provider.environment.check() }
            catch { environmentError = error.localizedDescription }
            checking = false
        }
    }

    /// 一键处理：Xcode 去 App Store / 打开 Xcode / 系统设置交给系统打开；Metal 组件、iOS 平台组件、.NET SDK 交作业，做完自动重新检查。
    func repair(_ check: ToolCheck) {
        guard let action = check.action else { return }
        switch provider.environment.repairStep(for: action) {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .job(let operation):
            if busy { if !repairQueue.contains(check) { repairQueue.append(check) }; return }
            inlineFailure = nil
            showEnvironment = false
            start(JobSession.Kind(rawValue: operation) ?? .installDotnet, game: nil, name: check.name) { [weak self] sink in
                let list = try await self?.provider.environment.repair(operation, events: sink)
                if let list { self?.checks = list }
                return nil
            }
        case .chooseLibrary:
            break   // 选目录面板由环境检查页开（面板文案走界面语言），选好交 changeLibrary
        case .recheck:
            checkEnvironment()   // 组件已下载、只是没注册就绪：重查一遍，不再下一遍 8 GB
        case .unavailable:
            environmentError = check.message
        }
    }

    /// 换游戏库：setup 作业（作业层拦不支持的盘格式、云盘同步目录、非空的生文件夹）→ 写回偏好、重读游戏库、重新检查环境。
    /// 作业跑在作业页，没成的原因（如选的还在云盘里）在作业页显示；成了作业页可在访达中显示新游戏库。
    /// 换游戏库时作业层报认得出的风险（v0.3.1：认得出的风险让玩家确认）：问玩家「仍然继续 / 先不」，同意带对应参数重发，参数累积
    ///   library_in_cloud：选的文件夹在云盘同步目录里；library_folder_not_empty：文件夹里已有别的文件、又不是游戏库（S2Arm 只动自己建的文件）
    static let libraryConfirmCodes = ["library_in_cloud": "acceptCloud", "library_folder_not_empty": "acceptForeign"]
    struct LibraryConfirm: Equatable { let url: URL; let move: Bool; let message: String; var code = "library_in_cloud"; var accept: Set<String> = [] }
    @Published var libraryConfirm: LibraryConfirm?

    func changeLibrary(to url: URL, move: Bool = false, accept: Set<String> = []) {
        guard !busy else { return }
        showEnvironment = false
        failAction(nil, game: nil)
        start(.setupLibrary, game: nil, name: url.lastPathComponent) { [weak self] sink in
            guard let self else { return nil }
            let library: String
            do {
                library = try await self.provider.library.change(to: url, moveFrom: move ? self.provider.client.environment.library : nil, accept: accept, events: sink)
            } catch let f as JobFailure where Self.libraryConfirmCodes[f.code ?? ""].map({ !accept.contains($0) }) == true {
                self.libraryConfirm = LibraryConfirm(url: url, move: move, message: f.errorDescription ?? "", code: f.code ?? "",
                                                     accept: accept.union([Self.libraryConfirmCodes[f.code ?? ""]!]))
                throw f
            }
            self.games = []; self.selectedID = nil; self.libraryLoaded = false
            self.checks = (try? await self.provider.environment.check()) ?? self.checks
            return library
        }
    }

    // ---- free space ----

    /// 读这款的占用（spaceSurvey）。换了一款先清掉上一款的。
    func clearSpaceFreed() { spaceFreed = nil }

    func loadOverview() {
        guard !overviewLoading else { return }
        overviewLoading = true; overviewError = nil
        Task {
            do { overview = try await provider.space.overview() }
            catch { overviewError = error.localizedDescription }
            overviewLoading = false
        }
    }

    func loadSpace(_ gameID: String) {
        if spaceGameID != gameID { spaceGameID = gameID; space = nil; spaceFreed = nil }
        spaceError = nil
        // 还在读上一款：读完按现在要的这款再读（原先直接返回，上一款的结果因游戏号对不上被丢，这一款永远读不出来，「释放」按钮一直灰着）
        guard !spaceLoading else { return }
        spaceLoading = true
        Task {
            do {
                let list = try await provider.space.survey(gameId: gameID)
                if spaceGameID == gameID { space = list.first { $0.gameId == gameID } }
            } catch {
                if spaceGameID == gameID { spaceError = error.localizedDescription }
            }
            spaceLoading = false
            if let want = spaceGameID, want != gameID { loadSpace(want) }
        }
    }

    /// 删勾选的部件（spaceFree，直接删、不进废纸篓）。有作业在跑不让点；作业层拒绝（别的任务在用游戏库）显示它的原话。删完重读占用与游戏库。
    func freeSpace(_ gameID: String, parts: Set<String>) {
        guard !busy, !spaceFreeing, !parts.isEmpty, spaceGameID == gameID else { return }
        spaceFreeing = true; spaceError = nil; spaceFreed = nil
        // 按作业层部件顺序交
        let ordered = (space?.parts.map(\.id) ?? []).filter { parts.contains($0) }
        Task {
            do {
                let freed = try await provider.space.free(gameId: gameID, parts: ordered, events: lockWaitSink())
                if spaceGameID == gameID { spaceFreed = freed.freedBytes }
            } catch {
                if spaceGameID == gameID { spaceError = error.localizedDescription }
            }
            spaceFreeing = false; lockWaitNote = nil
            loadSpace(gameID)
            refresh()   // 删了 Mac 运行版本，这款要重新准备
            if overview != nil { loadOverview() }
        }
    }


    // ---- import ----

    enum ImportPage { case selection, keys, results }
    @Published private(set) var importPage: ImportPage?
    @Published private(set) var importSources: [ImportSource] = []
    @Published private(set) var importBatchFailure: String?
    private var importUsesResults = false

    var pendingSources: [ImportSource] { importSources.filter { !$0.succeeded } }
    var importedSourceCount: Int { importSources.filter(\.succeeded).count }

    func importGames(_ urls: [URL], partialResults: Bool) {
        guard !urls.isEmpty, !busy else { return }
        if partialResults {
            importSources = []
            importPage = nil
            pendingImport = []
            if !showKeys { showAddGames = true }
        }
        submitImport(urls, partialResults: partialResults)
    }

    private func submitImport(_ urls: [URL], partialResults: Bool) {
        guard let first = urls.first, !busy else { return }
        importUsesResults = partialResults
        importBatchFailure = nil
        failAction(nil, game: nil)
        inlineFailure = nil
        start(.importGames, game: nil, name: first.lastPathComponent + (urls.count > 1 ? " +\(urls.count - 1)" : "")) { [weak self] sink in
            guard let self else { return nil }
            let wasEmpty = self.games.isEmpty
            do {
                let result = try await self.provider.importGames(GameInputs(paths: urls), partialResults: partialResults, events: sink)
                try Task.checkCancellation()
                if partialResults { self.mergeImportSources(result.sources, submitted: urls) }
                self.selectImportedGame(result.games.first, forWelcome: wasEmpty)
                // 批量出包（v0.2.4）：一次放进多款、或在出包页又放进游戏 → 识别完列成清单（出包页那款排第一）；认不出的也列上、写原因
                let seed = self.batchSeed; self.batchSeed = nil
                let ids = (seed.map { [$0] } ?? []) + result.games.map(\.titleId).filter { $0 != seed }
                if ids.count > 1 { self.openBatch(ids, unrecognized: self.pendingSources) }
            } catch let failure as JobFailure where partialResults {
                try Task.checkCancellation()
                let rows = ImportSource.rows(in: failure.outcome.result)
                self.mergeImportSources(rows, submitted: urls)
                if failure.code == "keys_missing" {
                    self.pendingImport = self.pendingSources.isEmpty ? urls : self.pendingImportURLs
                    if wasEmpty && !self.showKeys && self.importedSourceCount == 0 {
                        // The welcome flow shows the selection and offers its existing keys step.
                        self.showAddGames = false
                        self.importPage = nil
                    } else {
                        self.importPage = .keys
                    }
                    return nil
                }
                if let imports = failure.outcome.result["imports"] as? [[String: Any]], !imports.isEmpty {
                    let games = await self.provider.importedGames(in: failure.outcome.result)
                    try Task.checkCancellation()
                    self.selectImportedGame(games.first, forWelcome: wasEmpty)
                }
                if !rows.contains(where: { $0.status == .failed && $0.code == failure.code }) {
                    self.importBatchFailure = failure.errorDescription
                }
                throw failure
            } catch {
                if partialResults && !Task.isCancelled { self.importBatchFailure = error.localizedDescription }
                throw error
            }
            return nil
        }
    }

    private var pendingImportURLs: [URL] { pendingSources.map { URL(fileURLWithPath: $0.path) } }

    private func selectImportedGame(_ game: GameInfo?, forWelcome: Bool) {
        guard let game else { return }
        selectedID = game.titleId
        if forWelcome { welcomeGameID = game.titleId }
    }

    private func mergeImportSources(_ rows: [ImportSource], submitted: [URL]) {
        guard !rows.isEmpty else { return }
        // A failed folder scan may expand to child sources on retry.
        let submittedPaths = Set(submitted.map(\.path))
        let returnedIDs = Set(rows.map(\.id))
        importSources.removeAll { !$0.succeeded && submittedPaths.contains($0.path) && !returnedIDs.contains($0.id) }
        var positions = Dictionary(uniqueKeysWithValues: importSources.enumerated().map { ($0.element.id, $0.offset) })
        for row in rows {
            if let index = positions[row.id] {
                if !importSources[index].succeeded { importSources[index] = row }
            } else {
                positions[row.id] = importSources.count
                importSources.append(row)
            }
        }
        if !pendingSources.isEmpty { importPage = .results }
    }

    func retryImport() {
        submitImport(pendingImportURLs, partialResults: true)
    }

    func backFromImportResults() {
        guard !busy else { return }
        if pendingSources.contains(where: \.needsKeys) {
            pendingImport = pendingImportURLs
            keysRejected = pendingSources.contains { $0.code == "keys_outdated" }
            importPage = .keys
        } else {
            importPage = .selection
        }
    }

    func cancelImport() {
        if let session, [.importGames, .keys].contains(session.kind) { stop() }
        closeImport()
        clearInlineFailure()
    }

    private func closeImport() {
        showAddGames = false
        showKeys = false
        importPage = nil
        importSources = []
        pendingImport = []
        importBatchFailure = nil
        keysRejected = false
    }

    // ---- export ----

    /// 勾了的平台，按页面顺序（也是排队顺序）。
    var exportTargets: [ExportPlatform] { ExportPlatform.picked(exportChoice) }

    /// 勾上 / 取消一个平台，当场记住（未开放的点不动）。
    func toggleExport(_ platform: ExportPlatform) {
        guard platform.released else { return }
        exportChoice = ExportPlatform.toggled(exportChoice, platform)
        do { try provider.settings.setExportTargets(exportChoice) } catch { choiceError = error.localizedDescription }
    }

    /// 现在不能出包的原因（nil = 能出）。顺序同旧启动器导出页：没勾平台 → 游戏缺文件 → 缺 keys → 有任务在跑。
    ///   环境不挡（剃刀 M4）：前端的检查结果可能是旧的（玩家在外面修好 Xcode 回来仍被挡），作业层开头自己校验环境、缺什么回真实原因
    func exportBlocker(_ game: GameSummary, platforms chosen: [ExportPlatform]? = nil) -> ExportBlocker? {
        let platforms = chosen ?? exportTargets
        if platforms.isEmpty { return .noPlatform }
        if !game.buildable { return .game(Self.requirementsText(game)) }
        if game.needsKeys, provider.library.keysReady == false { return .keys }
        if busy, session?.export == nil { return .busy }   // 别的出包在跑可以排队
        return nil
    }

    /// 出包：勾了几个平台就几个作业（Mac = build、iPhone / iPad = ipa），按页面顺序一个接一个；解包等平台无关阶段作业层共用（游戏库/cache/<程序号>/extract）。
    /// 一个平台没成不挡后面的平台；取消就整次停。
    /// platforms 不给 = 出包页勾的；本机控制口（AI 操作）按命令给一个平台，deviceTarget 只用于 iPhone 出包（提示地址窗口）。
    @discardableResult
    func export(_ game: GameSummary, platforms chosen: [ExportPlatform]? = nil, deviceTarget: [String: Any]? = nil, spaceOverride: Bool = false, location: String? = nil) -> ExportBlocker? {
        if let blocker = exportBlocker(game, platforms: chosen), blocker.stopsStart { return blocker }
        let item = QueuedExport(game: game, platforms: chosen ?? exportTargets, target: deviceTarget ?? currentDeviceTarget, spaceOverride: spaceOverride, location: location)
        exportFor = nil
        welcomeGameID = nil
        if busy || batchRunning {   // 正在出别的 / 一批正在出：排队，出完接着出（11-08 维护者：出好一个接着出下一个）
            if session?.gameID == game.id || exportQueue.contains(where: { $0.game.id == game.id }) { return .alreadyQueued }
            exportQueue.append(item)
            return nil
        }
        sessionHidden = false
        runExport(item)
        return nil
    }

    /// 空闲时接着做排着的事（启动器剃刀 M2）：先装批量出完的款，再出批次进行中单独点的款。批次结束、装机结束都从这里走，
    ///   原先批次结束只看自动装机，批次期间排进 exportQueue 的单款永远「排队中」
    func pumpQueue() {
        guard !busy, !batchRunning else { return }
        if !installAfterQueue.isEmpty { installNextQueued(); return }
        if !exportQueue.isEmpty { let next = exportQueue.removeFirst(); session = nil; runExport(next) }
    }

    /// 出一款：起一个出包编排作业（剃刀 H13，pack/jobs/export_plan.py），计划只有这一款的这几个平台、不写批次文件。
    /// 平台顺序、iPhone 之后还有平台时先不清解包（followUp）、这台电脑出不了的平台都在作业层；这里只按它的事件画每个平台的进度与结局。
    func runExport(_ item: QueuedExport) {
        failAction(nil, game: nil)
        let game = item.game, platforms = item.platforms
        var session = JobSession(kind: .export, gameID: game.id, name: game.name)
        session.export = ExportRun(platforms: platforms)
        var plan: [String: Any] = ["source": "inline", "items": [["gameId": game.id, "name": game.name, "platforms": platforms.compactMap(Self.batchPlatform)]]]
        if let location = item.location { plan["location"] = location }
        if let target = item.target { plan["deviceTarget"] = target }
        if item.spaceOverride { plan["spaceOverride"] = true }
        start(session) { [weak self] sink in
            guard let self else { return nil }
            do { _ = try await self.provider.export(plan: plan, hasIPhone: platforms.contains(.ios), events: self.exportSink(sink)) }
            catch let pause as JobFailure where pause.state == .paused { throw ExportIncomplete() }   // 磁盘满：那个平台已按 stepEnded 记失败（码 disk_full），整次算没全成
            if self.session?.export?.failed.isEmpty == false { throw ExportIncomplete() }
            return nil
        }
    }

    /// 出包编排作业的事件 → 现有的出包会话：step 换到这个平台（批量出包时换到这一款的会话）、child 当成普通作业事件、stepEnded 记这个平台的结局
    func exportSink(_ sink: EventSink) -> EventSink {
        var failure: [String: Any] = [:]   // 子作业终态里的诊断（建议、失败事实），stepEnded 时并进结局
        return EventSink { [weak self] event in
            guard let self else { return }
            let step = event.fields["step"] as? [String: Any] ?? [:]
            let platform = (step["platform"] as? String).flatMap(Self.exportPlatform)
            switch event.ev {
            case "step":
                if let gid = step["gameId"] as? String { self.batchStepStarted(gid) }
                if let platform, let k = self.session?.export?.platforms.firstIndex(of: platform) { self.beginPlatform(k) }
                failure = [:]
            case "child":
                guard let inner = event.fields["event"] as? [String: Any], let job = JobEvent(json: inner) else { return }
                if job.isFinal { failure = (job.fields["diagnostics"] as? [[String: Any]] ?? []).last(where: { ($0["severity"] as? String) == "error" }) ?? [:]; return }
                sink.emit(EngineEvent(job: job))
            case "stepEnded":
                guard let platform, let o = event.fields["outcome"] as? [String: Any] else { return }
                let state = JobOutcome.State(rawValue: o["state"] as? String ?? "") ?? .failed
                self.endPlatform(platform, ExportRun.Outcome(state: state, message: o["message"] as? String ?? "", code: o["code"] as? String,
                                                             output: o["outputPath"] as? String ?? o["output"] as? String, ipa: o["ipa"] as? String,
                                                             appBytes: ((o["ipaBytes"] ?? o["outputBytes"]) as? NSNumber)?.int64Value,
                                                             packBytes: (o["packBytes"] as? NSNumber)?.int64Value,
                                                             suggestion: failure["suggestion"] as? String ?? "", failureSummary: failure["failureSummary"] as? String,
                                                             notes: o["notes"] as? [String] ?? []))
                if self.batchRunning { self.batchStepEnded() }
            default:
                sink.emit(event)
            }
        }
    }

    /// 界面上的目标设备：玩家选过 → 只认那台（连着就是它；不连着为 nil，界面说「它不在线」，不替玩家换成别的——11-11 玩家实报：
    ///   续签时选的 iPhone 拔了线，同网的 iPad 被装上）。没选过 → 有线连着的那台，否则第一台（#272），装的就是界面上显示的这台
    nonisolated static func pickDevice(_ connected: [[String: Any]], chosen: String?) -> [String: Any]? {
        if let chosen { return connected.first(where: { $0["id"] as? String == chosen || $0["udid"] as? String == chosen }) }
        return connected.first(where: { $0["wired"] as? Bool == true }) ?? connected.first
    }

    /// 装机 / 续签 / 更新手机上的 S2Arm 一律带上的设备号：玩家选的那台（此刻不在线也照样带上，作业层如实说「iPhone「名字」不在线」），
    /// 没选过时就是界面上显示的那台。作业层收不到设备号就拒绝，不自己挑
    var installDeviceID: String? { chosenDevice ?? (selectedDevice?["udid"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? selectedDevice?["id"] as? String }

    /// 选过的设备此刻不在线（不在连着的列表里）：界面提示并让玩家改选
    var chosenDeviceOffline: Bool { chosenDevice != nil && selectedDevice == nil }

    /// 续签：装回这款当初装的那台（装机记录里的设备号），不换别的；那台不在线时作业层如实说
    func targetInstalledDevice(of game: GameSummary) {
        if let key = game.iphoneInstallDevice, !key.isEmpty { chosenDevice = key }
    }

    /// 这次实际装上的那台（装机结果的 deviceKind / deviceName）：完成页、顶部胶囊写「已装到 iPad「名字」」，不写死 iPhone
    @Published var installedTo: String = ""
    nonisolated static func deviceLabel(kind: String, name: String) -> String {
        let k = kind.isEmpty ? "iPhone / iPad" : kind
        return name.isEmpty ? k : "\(k)「\(name)」"
    }
    /// 正在装 / 要装的那台的称呼（进度胶囊用）：选中且连着 → 类型 + 名字；否则「iPhone / iPad」
    var installTargetLabel: String {
        guard let d = selectedDevice else { return "iPhone / iPad" }
        let pad = (d["productType"] as? String)?.hasPrefix("iPad") == true
        return Self.deviceLabel(kind: pad ? "iPad" : "iPhone", name: d["name"] as? String ?? "")
    }

    var selectedDevice: [String: Any]? { Self.pickDevice(connectedDevices, chosen: chosenDevice) }

    /// 选中的设备是 iPad 时，「装到 iPhone」这几处入口文字换成「装到 iPad」（#487）；没连设备照旧写 iPhone
    var installTargetIsPad: Bool { (selectedDevice?["productType"] as? String)?.hasPrefix("iPad") == true }
    /// 入口文字的键：iPad 版键名 = 原键 + "Pad"（zh / en 两份 l10n 同步）
    func installKey(_ key: String) -> String { installTargetIsPad ? key + "Pad" : key }

    /// 出 iPhone 包的目标：连着的手机优先（多台时用选中的那台），其次玩家选的机型；都没有交给作业层按常见机型出。
    var currentDeviceTarget: [String: Any]? {
        if let device = selectedDevice { return device }
        guard let chosenModel, var model = targetModels.first(where: { $0["productType"] as? String == chosenModel }), let os = targetOS.first else { return nil }
        model["os"] = os
        return model
    }

    func refreshTargets() async {
        // 读失败 = 设备状态不明，不留上一次的列表（原先保留旧值：拔了手机还显示已插入，11-11 玩家反馈）；原因照实显示在设备行（deviceProbeError），
        //   并按剃刀 M13 只报一次（5 秒轮询不重复弹）
        let probe: [String: Any]
        do { probe = try await provider.targetDevices(); readOK("s2arm.fail.targets") }
        catch { connectedDevices = []; deviceProbeError = error.localizedDescription; reportFailure("s2arm.fail.targets", error, passive: true); return }
        connectedDevices = probe["connected"] as? [[String: Any]] ?? []
        deviceProbeError = (probe["connectedError"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        targetModels = probe["models"] as? [[String: Any]] ?? []
        targetOS = probe["osChoices"] as? [Int] ?? []
    }

    /// 换到第 k 个平台：进度、里程碑从头算（日志接着记）。
    func beginPlatform(_ k: Int) {
        guard var session, var run = session.export else { return }
        run.index = k; run.platformStarted = Date()
        session.export = run; session.progress = JobProgress(); session.stage = ""
        self.session = session
    }

    func endPlatform(_ platform: ExportPlatform, _ outcome: ExportRun.Outcome) {
        guard var session, var run = session.export else { return }
        var outcome = outcome
        outcome.seconds = Date().timeIntervalSince(run.platformStarted)
        run.outcomes[platform] = outcome
        session.export = run; session.progress.finish()
        self.session = session
    }

    /// 后端错误摘要（作业层 report）拿不到时复制的内容（剃刀 M19）：原先前端另拼一份格式不同的完整摘要，反馈时分不清贴的是哪份；
    ///   现在只留后端那一份，拿不到就明说，附界面上那句原因和错误码
    static func reportUnavailable(_ message: String, code: String?) -> String {
        Localizer().t("s2arm.report.unavailable") + "\n" + message + (code.map { " (\($0))" } ?? "")
    }

    /// 把最近一次失败作业的错误摘要放进剪贴板。正文由作业层生成（带任务号、阶段、错误码、真实日志）；没有作业记录才用 fallback。
    func copyErrorReport(platform: String?, gameID: String?, operations: [String]?, fallback: String) async {
        let info = Bundle.main.infoDictionary ?? [:]
        var extra: [String: Any] = ["app": info["CFBundleShortVersionString"] as? String ?? "", "build": info["S2ABuildID"] as? String ?? "",
                                    "xcode": provider.client.environment.developerDir.replacingOccurrences(of: "/Contents/Developer", with: ""),
                                    "checks": checks.filter { !$0.ok }.map { ["name": $0.name, "message": $0.message] }]
        if let platform { extra["platform"] = platform }
        if let device = currentDeviceTarget.flatMap({ ($0["model"] ?? $0["name"]) as? String }) { extra["device"] = device }
        let report = operations == nil ? nil : await provider.client.errorReport(gameID: gameID, operations: operations ?? [], extra: extra)
        let text = report ?? fallback
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }

    /// 装机前清单（装机页开着时每几秒调一次）。换了一款先清掉上一款的清单。
    func checkInstall(_ gameID: String, device: String? = nil) {
        let target = device ?? installDeviceID
        if installGameID != gameID || installReadinessDevice != target {   // 换了款或换了设备：旧清单不能当这台的
            installGameID = gameID; installReadinessDevice = target; installReadiness = nil; installError = nil
        }
        if installChecking { pendingInstallCheck = (gameID, target); return }
        installChecking = true
        Task {
            do {
                let readiness = try await provider.installReadiness(gameId: gameID, device: target)
                if installGameID == gameID && installReadinessDevice == target { installReadiness = readiness; installError = nil }
            } catch {
                if installGameID == gameID && installReadinessDevice == target { installError = error.localizedDescription }
            }
            installChecking = false
            if let next = pendingInstallCheck { pendingInstallCheck = nil; checkInstall(next.game, device: next.device) }
        }
    }

    /// 在 Xcode 打开引导项目；玩家运行一次后，装机页每 5 秒的重查会自动打勾。
    func openSigningProject() {
        Task {
            do { NSWorkspace.shared.open(URL(fileURLWithPath: try await provider.signingProject())) }
            catch { installError = error.localizedDescription }
        }
    }

    /// 装机 / 删除会让手机上别的电脑装的游戏暂时不能玩（作业层 container_would_drop）：界面弹确认，确认了带 acceptDropped 重跑。
    /// ask = false（控制口发起）不弹，原样失败，由调用方带 acceptDropped 再发。
    /// 更新手机上的 S2Arm 也会撞上（v0.3.0 只换壳验收：原先这条路没接确认，界面说「确认继续再点一次」却永远过不去）：update 记着当时的参数，确认后原样带 acceptDropped 重跑
    struct UpdateArgs { let acceptStale: Bool; let repack: [String]; let language: String; let device: String?; var accept: Set<String> = [] }
    /// 作业层可确认继续的停装码 → 玩家点「仍然继续」后重发时带的参数（维护者 11-11 装机原则：认得出的风险让玩家确认，确认了就装）。
    ///   结局页（PhoneJobPanel）按码在页内问「仍然继续 / 先不」，不弹散的对话框；参数累积（先确认挤掉、再撞上备份失败，第二次重发两个都带）
    static let confirmCodes: [String: String] = ["container_would_drop": "acceptDropped", "save_backup_failed": "acceptNoBackup", "container_stale": "acceptStale"]
    struct DropConfirm { let kind: JobSession.Kind; var game: GameSummary? = nil; let message: String; var update: UpdateArgs? = nil
                         var code = "container_would_drop"; var accept: Set<String> = []
                         /// 当初装到哪台：确认后原样带回（不能退回「界面选中的那台」，控制口指定的设备会被换掉）
                         var device: String? = nil }
    @Published var dropConfirm: DropConfirm?
    /// 上一次「更新手机上的 S2Arm」的参数：失败页「重试」按它再来
    var lastUpdateArgs: UpdateArgs?
    func retryPhoneUpdate() {
        guard let a = lastUpdateArgs else { return }
        updatePhone(acceptStale: a.acceptStale, repack: a.repack, language: a.language, device: a.device, accept: a.accept)   // 已确认过的照带
    }

    /// 环境检查「装到 iPhone 的方式」里手填的 Xcode 团队号（10 位）：一键装、不用证书时每次装机都带上（原先只在装机页点「用这个团队」那一次带）
    static let teamCodeKey = "s2arm.enteredTeamCodeId"
    static var enteredTeam: String? {
        let t = (UserDefaults.standard.string(forKey: teamCodeKey) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        return t.count == 10 ? t : nil
    }

    func install(_ game: GameSummary, teamId: String? = nil, device: String? = nil, acceptDropped: Bool = false, accept: Set<String> = [], ask: Bool = true) {
        let accept = acceptDropped ? accept.union(["acceptDropped"]) : accept
        // 不在这里再核装机页清单（启动器剃刀 M1）：装机页按钮和控制口调用前各自核过；批量出完自动装的款从没打开过装机页，原先在这里被悄悄挡掉、队列停住
        guard !busy else { return }
        let teamId = teamId ?? Self.enteredTeam
        failAction(nil, game: nil)
        // 装到玩家选的那台（控制口明说了 device 的照它；s2armctl 不带就是空，作业层拒绝）。界面发起的一律带上，不靠作业层挑
        let device = device ?? installDeviceID
        installedTo = ""
        phoneOutcome = nil
        start(.install, game: game, name: game.name) { [weak self] sink in
            do {
                let r = try await self?.provider.install(gameId: game.id, teamId: teamId, device: device, accept: accept, events: sink)
                if let r {
                    self?.installedTo = Self.deviceLabel(kind: r.deviceKind, name: r.deviceName)
                    self?.phoneOutcome = PhoneOutcome(device: Self.deviceLabel(kind: r.deviceKind, name: r.deviceName), packFiles: r.packFiles, packBytes: r.packBytes)
                }
                self?.installOpenToFinish = r?.openToFinish ?? false
            }
            catch let f as JobFailure where ask && Self.confirmCodes[f.code ?? ""] != nil {
                self?.dropConfirm = DropConfirm(kind: .install, game: game, message: f.errorDescription ?? "", code: f.code ?? "",
                                                accept: accept.union([Self.confirmCodes[f.code ?? ""]!]), device: device)
                throw f
            }
            return nil
        }
    }

    /// 确认框点了「仍然继续」
    func confirmDrop(_ d: DropConfirm) {
        dropConfirm = nil; clearInlineFailure()
        if let u = d.update { updatePhone(acceptStale: u.acceptStale || d.accept.contains("acceptStale"), repack: u.repack, language: u.language, device: u.device, accept: d.accept); return }
        guard let game = d.game else { return }
        if d.kind == .installRemove { removeFromPhone(game, device: d.device, accept: d.accept) } else { install(game, device: d.device, accept: d.accept) }
    }

    /// 装回上一版手机 S2Arm（只换宿主后新宿主不好用时）。
    func restorePhone(_ game: GameSummary, device: String? = nil) {
        guard !busy else { return }
        failAction(nil, game: nil)
        let device = device ?? game.iphoneInstallDevice ?? installDeviceID   // 装回当初那台
        phoneOutcome = PhoneOutcome(device: installTargetLabel)
        start(.installRestore, game: game, name: game.name) { [weak self] sink in
            try await self?.provider.restorePhone(device: device, events: sink)
            return nil
        }
    }

    /// accept：玩家确认过的参数（同 install：container_would_drop → acceptDropped、删前没能备份存档 save_backup_failed → acceptNoBackup），逐次累积
    func removeFromPhone(_ game: GameSummary, acceptDropped: Bool = false, ask: Bool = true, device: String? = nil, accept: Set<String> = []) {
        let accept = acceptDropped ? accept.union(["acceptDropped"]) : accept
        guard !busy else { return }
        failAction(nil, game: nil)
        let device = device ?? game.iphoneInstallDevice ?? installDeviceID   // 从装着它的那台删
        phoneOutcome = PhoneOutcome(device: installTargetLabel)
        start(.installRemove, game: game, name: game.name) { [weak self] sink in
            do { _ = try await self?.provider.removeFromPhone(gameId: game.id, accept: accept, device: device, events: sink) }
            catch let f as JobFailure where ask && Self.confirmCodes[f.code ?? ""] != nil {
                self?.dropConfirm = DropConfirm(kind: .installRemove, game: game, message: f.errorDescription ?? "", code: f.code ?? "",
                                                accept: accept.union([Self.confirmCodes[f.code ?? ""]!]), device: device)
                throw f
            }
            return nil
        }
    }

    static func requirementsText(_ game: GameSummary) -> String {
        game.compatibility == "unsupported" ? "这款游戏暂不支持。" : "这款还缺文件：" + game.missing.joined(separator: "；")
    }

    // ---- play ----

    func play(_ game: GameSummary, uiLanguage: String?) {
        guard !busy, !cloudSyncing else { return }
        failAction(nil, game: nil)
        // 不按前端的环境检查结果拦（剃刀 M4）：launch 作业自己校验运行文件与环境，缺什么回真实原因
        // 开了 iCloud 存档：先取回 / 处理冲突再开局（S2ArmLauncherModel+CloudSaves）；同步失败本地存档没动，照常开局、错误行写原因
        if cloudFolder != nil {
            cloudSyncing = true
            Task {
                let why = await cloudSync(game.id)
                cloudSyncing = false
                // 同步期间别的作业（导出 / 导入）可能已经开始：这时不开局，免得盖掉它的会话（11-09 审查）
                if busy { failAction(Self.cloudBusyAfterSync, game: game.id); return }
                startPlay(game, uiLanguage: uiLanguage)
                if let why { failAction(Self.cloudFailure(why), game: game.id) }
            }
            return
        }
        startPlay(game, uiLanguage: uiLanguage)
    }

    private func startPlay(_ game: GameSummary, uiLanguage: String?) {
        let relaySocket = controller.relaySocketForGame()
        var controllerArguments: [String: String] = [
            "switch2ProAutoConnect": relaySocket == nil ? "0" : "1",   // 有通道就让游戏自己接（还没连上时游戏会重试）
        ]
        if let relaySocket { controllerArguments["switch2ProRelaySocket"] = relaySocket }
        // 本地玩家（#623）：顶栏选的玩家随 launch 请求给作业层（pack/jobs/build.py runtime_env → 服务层 S2A_PLAYER_USER / 这个玩家的 SaveData）；没建过玩家不带（旧行为）
        if let player = Self.launchPlayer() {
            controllerArguments["playerUser"] = player.serviceUser
            controllerArguments["playerName"] = player.name
            controllerArguments["playerFolder"] = player.folder
        }
        controllerGameStarted = false
        do {
            let sink = EventSink { [weak self] event in self?.ingest(event) }
            running = try provider.run(InstalledGame(gameId: game.id, name: game.name),
                                       settings: S2ArmAppleAdapter.Settings(
                                        values: controllerArguments,
                                        uiLanguage: uiLanguage), events: sink)
            session = JobSession(kind: .play, gameID: game.id, name: game.name)
        } catch {
            failAction(error.localizedDescription, game: game.id)
        }
    }

    func startControllerConnection() { controller.startIfEnabled() }

    // ---- 本地玩家（#623，规则在共享包 SaveSync LocalPlayers，同 iPhone / iPad）----

    /// 本机的玩家表（App 偏好，不在游戏库文件夹里）；firstDefault = 第一个玩家没改过名时显示的名字（按界面语言）
    static func playerStore(firstDefault: String = "Player 1", defaults: UserDefaults = .standard) -> LocalPlayers {
        LocalPlayers(defaults: defaults, firstDefault: firstDefault)
    }
    /// 起局要带的玩家：没建过玩家 = nil（旧行为，作业层不设玩家）
    static func launchPlayer(_ defaults: UserDefaults = .standard) -> LocalPlayer? {
        defaults.object(forKey: LocalPlayers.listKey) == nil ? nil : playerStore(defaults: defaults).current
    }
    /// 作业请求里的 player 字段（起局 pack/jobs/build.py、导入社区存档 saves.py 都按 saves.requested_player 校验）；没建过玩家 = nil
    static func playerRequest(_ defaults: UserDefaults = .standard) -> [String: String]? {
        launchPlayer(defaults).map { ["user": $0.serviceUser, "name": $0.name, "folder": $0.folder] }
    }
    func shutdownControllerConnection() { controller.shutdown() }

    // ---- 放密钥 / 删除 / 诊断（本机控制口用；参数与作业同旧启动器）----

    /// 放密钥：作业页显示进度，完了重读游戏库（keysReady 跟着更新）。
    func importKeys(_ file: URL) {
        guard !busy else { return }
        failAction(nil, game: nil)
        inlineFailure = nil
        keysRejected = false
        if !showAddGames { showKeys = true }
        start(.keys, game: nil, name: file.lastPathComponent) { [weak self] sink in
            _ = try await self?.provider.importKeys(file, events: sink)
            return nil
        }
    }

    // ---- 存放位置（游戏库结构 v3）----

    /// 重读各存放位置（出包页打开时调；剩余空间是当时的）。
    func loadLocations(probe: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await self.provider.locations(probe: probe); self.readOK("s2arm.fail.locations")
                self.locations = r.rows; self.lastLocation = r.last
                if let probe, let slack = r.probeSlack { self.probedSlack[probe] = slack }
            } catch { self.reportFailure("s2arm.fail.locations", error, passive: true) }   // 读不到就保留上次的列表
        }
    }

    /// 出包页「存放位置」下拉框一项显示什么名字（批量出包页、存储总览行首同）：具体路径（家目录缩写成 ~），不是卷名——
    /// 同一块盘上的几个位置卷名一样（内置盘一律「系统盘」），只给卷名分不清是哪个文件夹；卷名收进来是为了在判据里明确不取它
    nonisolated static func locationName(path: String, volume: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// 存放位置下面那行提示（#444），只提示不拦；按原因说对：大分配单元「每个小文件至少占 N、多占数倍」/ 不是 APFS「不能克隆、多占一份」。没问题给 nil
    func locationSlackText(_ path: String, language: String) -> String? {
        let row = locations.first(where: { $0.path == path })
        guard let slack = row != nil ? row?.slack : probedSlack[path] ?? nil else { return nil }
        if slack.reason == "cluster" {
            let size = ByteCountFormatter.string(fromByteCount: slack.clusterBytes, countStyle: .binary)
            return BackendText.launcherText("export.location.slack_cluster", language: language).replacingOccurrences(of: "{0}", with: size)
        }
        return BackendText.launcherText("export.location.slack_format", language: language)
    }

    /// 出包页「存放位置」缺省选哪个：这款现在的位置 → 上次用的位置 → 默认位置。
    func defaultLocation(for game: GameSummary) -> String {
        if game.location.state == "ok" || game.location.state == "offline", !game.location.path.isEmpty { return game.location.path }
        return locations.first(where: { $0.id == lastLocation && $0.connected })?.path ?? locations.first(where: \.isDefault)?.path ?? ""
    }

    /// 移动到其他位置（整个文件夹，存档跟着走）。
    func moveGame(_ game: GameSummary, to folder: URL) {
        guard !busy else { return }
        failAction(nil, game: nil)
        start(.moveGame, game: game, name: game.name) { [weak self] sink in
            try await self?.provider.moveGame(game.id, to: folder.path, events: sink)
            self?.loadLocations()
            return nil
        }
    }

    /// 清除缓存（出包缓存 + 运行时着色器缓存；镜像、存档不动）。
    func clearCache(_ game: GameSummary) {
        guard !busy else { libraryNotice = LibraryNotice(kind: .failed, key: "s2arm.notice.waitBusy", name: game.name, detail: session?.name ?? ""); return }
        failAction(nil, game: nil)
        libraryNotice = LibraryNotice(kind: .running, key: "s2arm.notice.clearCache", name: game.name)
        start(.clearCache, game: game, name: game.name) { [weak self] sink in
            try await self?.provider.clearCache(game.id, events: sink)
            return nil
        }
    }

    /// 「找不到游戏文件」→ 重新指定文件夹 / 从游戏库移除：很快，不进作业页，失败写在游戏库页上。
    func relinkGame(_ game: GameSummary, folder: URL) {
        Task { [weak self] in
            do { try await self?.provider.relinkGame(game.id, folder: folder.path); self?.refresh() }
            catch { self?.failAction(error.localizedDescription, game: game.id) }
        }
    }

    func forgetGame(_ game: GameSummary) {
        Task { [weak self] in
            do { try await self?.provider.forgetGame(game.id); if self?.selectedID == game.id { self?.selectedID = nil }; self?.refresh() }
            catch { self?.failAction(error.localizedDescription, game: game.id) }
        }
    }

    /// 在访达中选中这款的文件夹（catalog 给的 location.folder：按索引解析、可能在玩家另选的存放位置，不按游戏号拼）；文件夹不在就显示所在的存放位置；
    /// 两个都不在 → 系统提示框说明原因，不在访达里打开空窗口。
    func reveal(_ game: GameSummary) {
        guard let path = [game.location.folder, game.location.path].first(where: { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }) else {
            explainMissing("s2arm.reveal.folderMissing"); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 存档位置（services/S2A.Services/SaveFolder.cs）：这款游戏文件夹里的 SaveData/，没有就建出来再在访达里打开（打开的是文件夹里面，玩家直接往里放）
    ///   本地玩家（#623）：当前玩家的那个（第一个玩家 SaveData，其他人 SaveData-<名字>，同 iOS）
    func openSaveFolder(_ game: GameSummary) {
        guard !game.location.folder.isEmpty, FileManager.default.fileExists(atPath: game.location.folder) else { explainMissing("s2arm.reveal.folderMissing"); return }
        let url = URL(fileURLWithPath: game.location.folder).appendingPathComponent(Self.launchPlayer()?.folder ?? LocalPlayers.firstFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
    /// 存档位置里放的存档上次起局没读进来的原因（服务层写在数据根 saves/savedata-problem.txt，读进来后删掉）；没有 = nil
    func saveFolderProblem(_ game: GameSummary) -> String? {
        guard !game.location.folder.isEmpty else { return nil }
        // 本地玩家（#623）：原因按玩家分文件（services SaveFolder.ProblemPath），第一个玩家仍是原文件名
        let player = Self.launchPlayer()
        let file = URL(fileURLWithPath: game.location.folder).appendingPathComponent(player.map { $0.isFirst ? "saves/savedata-problem.txt" : "saves/savedata-problem-\($0.uid).txt" } ?? "saves/savedata-problem.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let why = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return why.isEmpty ? nil : why
    }

    /// 「在访达中显示 .ipa」：装机时组装、整个游戏库共用的那份（默认位置根 S2Arm.ipa）；不在 → 提示框说明，不打开空窗口
    func revealIpa(_ path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { explainMissing("s2arm.reveal.ipaMissing"); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 失败如实报（剃刀 G9 M12 / M13）：原先 try? 吞掉，读失败当成「没有」、切换失败界面停在旧值像点了没反应。
    ///   弹一行原因（标题按 titleKey，正文是后端 / 系统给的原因句）；值保持原样，不拿失败当结果。
    ///   passive（打开页面时的被动刷新）：同一类连续失败只报头一次，成功一次后复位（readOK）
    func reportFailure(_ titleKey: String, _ error: Error, passive: Bool = false) {
        if passive { guard failingReads.insert(titleKey).inserted else { return } }
        let alert = NSAlert()
        alert.messageText = Localizer().t(titleKey)
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
    func readOK(_ titleKey: String) { failingReads.remove(titleKey) }

    private func explainMissing(_ key: String) {
        let alert = NSAlert()
        alert.messageText = Localizer().t(key)
        alert.runModal()
    }

    /// 删这款（IPA / 资源包 / 中间产物 / 缓存；存档与原始游戏文件保留）。
    func deleteGame(_ game: GameSummary) {
        guard !busy else { libraryNotice = LibraryNotice(kind: .failed, key: "s2arm.notice.waitBusy", name: game.name, detail: session?.name ?? ""); return }
        failAction(nil, game: nil)
        libraryNotice = LibraryNotice(kind: .running, key: "s2arm.notice.delete", name: game.name)
        start(.delete, game: game, name: game.name) { [weak self] sink in
            try await self?.provider.deleteGame(game.id, events: sink)
            if self?.selectedID == game.id { self?.selectedID = nil }
            return nil
        }
    }

    /// 改名字 / 换封面（nil 不动，空字符串恢复默认）：很快，不进作业页，失败写在出包页上。
    func customize(_ game: GameSummary, name: String? = nil, coverPath: String? = nil) {
        guard !busy, !customizing else { return }
        customizing = true; customizeError = nil
        Task {
            do { try await provider.customizeGame(game.id, name: name, coverPath: coverPath, events: lockWaitSink()); refresh() }
            catch { customizeError = error.localizedDescription }
            customizing = false; lockWaitNote = nil
        }
    }

    /// 导出 Mac 端诊断包（path）或拉回连着的 iPhone 上的诊断（path 为 nil）；做完可在访达里显示。
    func diagnostics(exportTo path: URL?) {
        guard !busy else { return }
        failAction(nil, game: nil)
        start(.diagnostics, game: nil, name: path?.lastPathComponent ?? "iPhone") { [weak self] sink in
            guard let self else { return nil }
            if let path { try await self.provider.exportDiagnostics(to: path, events: sink); return path.path }
            return try await self.provider.pullDiagnostics(events: sink)["outputPath"] as? String
        }
    }

    // ---- 允许 AI 操作 S2Arm（本机控制口，见 S2ArmControl）----

    /// 开关状态（--control / S2ARM_CONTROL=1 启动时恒为开）。
    @Published private(set) var aiControl = false
    @Published private(set) var aiControlError: String?
    private var control: S2ArmControl?

    /// 窗口出来时调：开关开着（或强制开）就起控制口。
    public func startControl() {
        aiControl = provider.settings.aiControl || ControlPort.forced
        if aiControl { openControl() }
    }

    /// 环境页的开关：记住选择，当场起 / 停控制口。
    func setAIControl(_ on: Bool) {
        aiControlError = nil
        do { try provider.settings.setAIControl(on) } catch { aiControlError = error.localizedDescription }
        aiControl = on || ControlPort.forced
        if aiControl { openControl() } else { control?.stop(); control = nil }
    }

    private func openControl() {
        guard control == nil else { return }
        do {
            control = try S2ArmControl(model: self) { [weak self] why in
                // 起不来 / control.json 写不上：不算已开，开关退回关，原因摆在环境页（审计 18:00 P2-35，同旧启动器）
                guard let self else { return }
                self.control = nil
                if !ControlPort.forced { try? self.provider.settings.setAIControl(false); self.aiControl = false }
                self.aiControlError = why
                ControlPort.reportStartFailure(privateRoot: self.provider.client.environment.privateRoot, why: why)
            }
        } catch {
            aiControlError = error.localizedDescription
            ControlPort.reportStartFailure(privateRoot: provider.client.environment.privateRoot, why: error.localizedDescription)
            if !ControlPort.forced { try? provider.settings.setAIControl(false); aiControl = false }
        }
    }

    /// 关掉界面上的提示 / 错误（同旧启动器「知道了」）。
    func dismissErrors() { failAction(nil, game: nil); environmentError = nil; aiControlError = nil; installError = nil }

    /// 密钥齐没齐（游戏库读回来的；nil = 还没读过）。
    var keysReady: Bool? { provider.library.keysReady }

    // ---- jobs ----

    /// 起一个作业：body 交适配层（事件进 sink），回来的路径做完后可在访达里显示。可停（stop = 取消这个 Task，适配层请作业停）。
    func start(_ kind: JobSession.Kind, game: GameSummary?, name: String,
                       _ body: @escaping @MainActor (EventSink) async throws -> String?) {
        start(JobSession(kind: kind, gameID: game?.id, name: name), body)
    }

    func start(_ fresh: JobSession, _ body: @escaping @MainActor (EventSink) async throws -> String?) {
        session = fresh
        if Self.phoneKinds.contains(fresh.kind) { phoneResult = nil }
        let sink = EventSink { [weak self] event in self?.ingest(event) }
        work = Task { [weak self] in
            do {
                let reveal = try await body(sink)
                self?.finish(.completed, message: "", reveal: reveal)
            } catch let failure as JobFailure {
                self?.finish(failure.state, message: failure.errorDescription ?? "", code: failure.code,
                             suggestion: failure.outcome.diagnostics.first?["suggestion"] as? String ?? "")
            } catch is CancellationError {
                self?.finish(.cancelled, message: "")
            } catch is ExportIncomplete {
                self?.finish(.failed, message: "")
            } catch {
                self?.finish(.failed, message: error.localizedDescription)
            }
        }
    }

    func ingest(_ event: EngineEvent) {
        guard var session = session, !isFinished(session) else { return }
        if let id = event.fields["taskId"] as? String, !id.isEmpty, session.taskID != id { session.taskID = id; self.session = session }
        if event.ev == "heartbeat" { return }
        if event.ev == "space", let space = PackSpace(event.fields["space"]) { session.space = space; self.session = session; return }
        if let stage = event.stage, !stage.isEmpty {
            session.stage = stage
            if event.ev == "stage", session.stages.last != stage { session.stages.append(stage) }
            if session.kind == .play, event.fields["stageKey"] as? String == "game_running" {   // 后端固定机读名（build.py begin key），不认中文阶段名
                controllerGameStarted = true
                controller.gameDidStart()
            }
        }
        session.progress.ingest(event)
        if !event.message.isEmpty {
            session.message = event.message
            let line = event.ev == "stage" ? "▸ " + event.message : event.message
            if session.log.last != line { session.log.append(line) }
            if session.log.count > Self.logLimit { session.log.removeFirst(session.log.count - Self.logLimit) }
        }
        self.session = session
        // 一局的结局只从事件来（run 是同步起的）；别的作业由 Task 结束收尾（中间可能有好几个作业，如先装 .NET 再出包）
        if session.kind == .play, event.isFinal {
            let state = JobOutcome.State(rawValue: event.fields["state"] as? String ?? "") ?? .interrupted
            finish(state, message: event.message)
            // 游戏里点了「切换游戏」（宿主菜单栏，pack/jobs/build.py launch 结果带 returnToLibrary）：不停在结果页，回到游戏库并切到前台，玩家直接点下一款
            if state == .completed, (event.fields["result"] as? [String: Any])?["returnToLibrary"] as? Bool == true {
                backToLibrary()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func isFinished(_ s: JobSession) -> Bool { if case .finished = s.phase { return true }; return false }

    func finish(_ state: JobOutcome.State, message: String, reveal: String? = nil, code: String? = nil, suggestion: String = "") {
        guard var session = session, !isFinished(session) else { return }
        session.phase = .finished(state)
        session.failureCode = code; session.suggestion = suggestion
        if !message.isEmpty {
            session.message = message
            if session.log.last != message { session.log.append(message) }
        }
        session.reveal = reveal
        session.progress.finish()
        session.ended = Date()
        self.session = session
        if session.isPhoneJob { lastPhoneSession = session }
        running = nil; work = nil
        if session.kind == .play, controllerGameStarted {
            controllerGameStarted = false
            controller.gameDidExit()
        }
        // 放密钥、添加游戏、欢迎页上的下载：结果留在原页（弹窗 / 欢迎页那一行），不换到日志页（11-08 维护者）；环境页发起的下载成了也直接回来
        if isInline(session) || (state == .completed && Self.repairKinds.contains(session.kind)) {
            self.session = nil
            inlineFailure = (state == .failed || state == .interrupted) ? (session.kind, session.message, session.suggestion) : nil
        }
        if state == .completed && session.kind == .install { installDone = session.gameID }
        if session.kind == .installUpdate { phoneUpdateEnded(completed: state == .completed) }
        if session.kind == .install { Task { pumpQueue() } }
        if [.delete, .clearCache].contains(session.kind), let n = libraryNotice, n.kind == .running {   // 删除 / 清缓存的结果写进游戏库页顶部那条提示
            libraryNotice = LibraryNotice(kind: state == .completed ? .done : .failed, key: n.key, name: n.name,
                                          detail: state == .completed ? "" : (session.message.isEmpty ? JobOutcome.interruptedMessage : session.message))
        }
        if Self.phoneKinds.contains(session.kind), let id = session.gameID { phoneResult = (id, session.name, state == .completed) }
        // 一局结束：开了 iCloud 存档就上传这局的进度（失败写在出包页错误行上，本地存档不动）
        if session.kind == .play, let id = session.gameID, cloudFolder != nil {
            cloudSyncing = true
            Task {
                let why = await cloudSync(id)
                cloudSyncing = false
                if let why { failAction(Self.cloudFailure(why), game: id) }
            }
        }
        if state == .completed && session.kind == .diagnostics, let reveal { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: reveal)]) }
        if session.kind == .export, let id = session.gameID {
            finishedExports[id] = session
            if batchRunning {   // 批量出包：下一款由编排作业的 step 事件换（batchStepStarted），这里不管
            } else if state == .cancelled {
                exportQueue = []
            } else if !exportQueue.isEmpty {
                let next = exportQueue.removeFirst()
                self.session = nil
                runExport(next)
            }
        }
        if state == .completed && session.kind == .keys {
            if pendingImport.isEmpty {
                closeImport()
            } else {
                let urls = pendingImport
                pendingImport = []
                submitImport(urls, partialResults: true)
            }
        }
        if state == .completed && session.kind == .importGames && importUsesResults &&
            pendingImport.isEmpty && pendingSources.isEmpty {
            closeImport()
        }
        if Self.repairKinds.contains(session.kind) {
            if state == .completed, !repairQueue.isEmpty { repair(repairQueue.removeFirst()) } else if state != .completed { repairQueue = [] }
        }
        refresh()   // 运行文件 / 存档 / 游戏库状态可能变了
    }

    private static let repairKinds: Set<JobSession.Kind> = [.downloadMetal, .downloadIosPlatform, .installDotnet]

    /// 这个作业的进度留在原页（弹窗 / 欢迎页），不换到作业日志页。
    func isInline(_ s: JobSession) -> Bool {
        [.keys, .importGames, .install, .installRemove, .installRestore, .delete, .clearCache, .diagnostics].contains(s.kind) || (showsWelcome && Self.repairKinds.contains(s.kind))
    }

    /// 欢迎页的「一键出包」：进和游戏库同一张出包页（维护者 11-11：首次出包缺设置项、选不了 iPhone / Mac），
    ///   平台、存放位置、目标设备、安装方式都在那页由玩家定；同 Windows 欢迎页（StartOneClick → 出包页）。
    func oneClickExport() {
        guard let game = welcomeGame else { return }
        exportFor = game.id
        welcomeGameID = nil
    }

    func clearInlineFailure() { inlineFailure = nil }

    func stop() {
        guard var session = session, session.phase == .running else { return }
        session.phase = .stopping
        self.session = session
        if session.kind == .play, let running { provider.control(running, .stop) }
        else if batchRunning, session.kind == .export { batchWork?.cancel() }   // 批量出包：取消整个编排作业（正在出的那步停下，已出好的保留）
        else { work?.cancel() }
    }

    /// 回库：只有作业结束了才能关掉作业页。
    /// 顶栏「游戏库」：从任何页面回到游戏库；出包还在跑就留在后台，游戏库上的进度条可以回去。
    func goToLibrary() {
        exportFor = nil; viewingResult = nil; showEnvironment = false; welcomeHome = false
        guard let current = session else { return }
        if isFinished(current) { session = nil } else { sessionHidden = true }
    }

    func backToLibrary() {
        if viewingResult != nil { viewingResult = nil; return }
        sessionHidden = false
        guard let current = session, isFinished(current) else { return }
        session = nil
    }
}
