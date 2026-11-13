// S2Arm（不是上游文件）：新前端的本机控制口命令表（11-07 启动器线）。新前端 11-07 成了发版缺省，原先只有旧启动器有控制口，
//   App 自带的 s2armctl / skill（launchers/macos/skill/s2arm-operator，维护者 10-23：玩家用自己的 AI 完成移植）对缺省 App 全部连不上。
// 收发、令牌、control.json 用适配层 ControlPort（与旧启动器同一份）；协议同旧启动器（launchers/macos/s2armctl.py 不用改）。
// 每个命令调界面按钮背后的同一个模型方法（S2ArmLauncherModel），屏幕上的作业页照常显示；选文件的对话框改成直接给路径。
// GET /state 的 tasks 读作业层自己写的作业记录（固定 <私有目录>/logs/jobs/<任务>.json，剃刀 H6；S2ArmPaths.jobsDir），新界面没有任务表也照样有据。
import AppKit
import Foundation
import S2ArmAppleAdapter

@MainActor final class S2ArmControl {
    private let port: ControlPort
    private weak var model: S2ArmLauncherModel?
    /// AI 选的打 iPhone 包目标设备（/target；只用来提示地址窗口）和最近一次探测结果（/targets）。
    private var deviceTarget: [String: Any]?
    private var probe: [String: Any] = [:]
    private var lastSnapshotPath = ""

    init(model: S2ArmLauncherModel, failed: @escaping @MainActor (String) -> Void) throws {
        self.model = model
        var me: S2ArmControl?
        port = try ControlPort(privateRoot: model.provider.client.environment.privateRoot,
                               state: { me?.state() ?? [:] },
                               handle: { r in await me?.handle(r) ?? .bad("控制口已停") },
                               failed: failed)
        me = self
        port.refreshCache()
    }

    var portNumber: UInt16 { port.port }
    func stop() { port.stop() }

    // MARK: 命令

    func handle(_ r: ControlRequest) async -> ControlReply {
        guard let model else { return .bad("界面已关") }
        let a = r.body
        func str(_ k: String) -> String? { a[k] as? String }
        let spaceOverride = a["spaceOverride"] as? Bool ?? false   // 同界面「仍然继续」：磁盘预检不够也照出，真写满会停下报错
        func game(_ k: String = "gameId") -> GameSummary? { str(k).flatMap { id in model.games.first { $0.id == id } } }
        func busy() -> ControlReply? { model.busy ? .bad("有作业在跑（\(model.session?.name ?? "")）：等它结束或 cancel 再来", code: 409) : nil }
        func blocked(_ b: ExportBlocker?) -> ControlReply {
            guard let b else { return .ok() }
            switch b {
            case .noPlatform: return .bad("没选平台")
            case .game(let why): return .bad(why)
            case .keys: return .bad("还没放密钥：s2armctl keys <prod.keys>")
            case .busy: return .bad("有作业在跑：等它结束或 cancel 再来", code: 409)
            case .alreadyQueued: return .bad("这款已在出包或排队，没有新建任务：等它结束再发", code: 409)
            }
        }
        switch (r.method, r.path) {
        case ("GET", "/state"):
            return .object(state())
        case ("GET", "/help"):
            let info = Bundle.main.infoDictionary ?? [:]
            return .object(["version": info["CFBundleShortVersionString"] as? String ?? "", "build": info["CFBundleVersion"] as? String ?? "",
                            "buildId": info["S2ABuildID"] as? String ?? "", "frontend": "S2Arm × NX2Apple", "endpoints": Self.endpoints])
        case ("GET", "/targets"):
            do { probe = try await model.provider.targetDevices() } catch { return .bad(error.localizedDescription) }
            let connected = probe["connected"] as? [[String: Any]] ?? []
            return .object(["current": deviceTarget ?? connected.first.map { $0.merging(["connected": true]) { a, _ in a } } ?? NSNull(),
                            "connected": connected, "models": probe["models"] as? [[String: Any]] ?? [], "osChoices": probe["osChoices"] as? [Int] ?? []])
        case ("GET", "/snapshot"):
            guard let png = snapshot() else { return .bad("没有可截的窗口") }
            return ControlReply(code: 200, type: "image/png", body: png)
        case ("POST", "/target"):
            if str("action") == "probe" {
                do { probe = try await model.provider.targetDevices() } catch { return .bad(error.localizedDescription) }
                return .ok()
            }
            guard let pt = str("productType"), let os = a["os"] as? Int,
                  var t = (probe["models"] as? [[String: Any]] ?? []).first(where: { $0["productType"] as? String == pt }) else {
                return .bad("缺 productType / os，或机型不在可选列表（先 target probe 或 targets）")
            }
            t["os"] = os; deviceTarget = t
            return .ok()
        case ("POST", "/keys"):
            guard let p = str("path") else { return .bad("缺 path") }
            if let b = busy() { return b }
            model.importKeys(URL(fileURLWithPath: p)); return .ok()
        case ("POST", "/games"):
            guard let ps = a["paths"] as? [String], !ps.isEmpty else { return .bad("缺 paths") }
            if let b = busy() { return b }
            model.importGames(ps.map { URL(fileURLWithPath: $0) }, partialResults: false); return .ok()
        case ("POST", "/prepare"):
            guard let g = game() else { return .bad("没有这个 gameId") }
            return blocked(model.export(g, platforms: [.mac], spaceOverride: spaceOverride))
        case ("POST", "/ipa"):
            guard let g = game() else { return .bad("没有这个 gameId") }
            return blocked(model.export(g, platforms: [.ios],
                                        deviceTarget: deviceTarget ?? (probe["connected"] as? [[String: Any]])?.first, spaceOverride: spaceOverride))
        case ("POST", "/batch"):   // 批量出包（v0.2.4）：同界面清单页——建批次后一款接一款地出，进度看 GET /state 的 batch
            if let r = busy() { return r }
            if model.batchState != nil, model.batchSummary["done"] as? Bool != true {   // 上一批暂停着 / 没出完：不盖掉（审计 P2-270），同 Windows 回 409
                return ControlReply(code: 409, body: ControlReply.json(["ok": false, "error": "上一批还没出完：在 S2Arm 的批量出包页「重试」/「继续」，或点「完成」清掉再建"]))
            }
            guard let rows = a["games"] as? [[String: Any]], !rows.isEmpty else { return .bad("games 要给 [{gameId, platforms:[mac|iphone]}]") }
            var want: [String: [String]] = [:]
            for row in rows {
                guard let id = row["gameId"] as? String, model.games.contains(where: { $0.id == id }) else { return .bad("没有这个 gameId：\(row["gameId"] ?? "")") }
                let ps = (row["platforms"] as? [String] ?? ["iphone"]).map { $0 == "ios" ? "iphone" : $0 }
                guard !ps.isEmpty, ps.allSatisfy({ $0 == "iphone" || $0 == "mac" }) else { return .bad("platforms 只认 mac / iphone") }
                want[id] = ps
            }
            if let loc = str("location") { model.batchLocation = loc }
            model.openBatch(rows.compactMap { $0["gameId"] as? String })
            for i in model.batchDraft.indices { let ps = want[model.batchDraft[i].id] ?? []; model.batchDraft[i].iphone = ps.contains("iphone"); model.batchDraft[i].mac = ps.contains("mac") }
            let skipped = model.batchDraft.filter { $0.problem != nil }.map { ["gameId": $0.id, "reason": $0.problem ?? ""] }
            // 一款都不能出 / 建批次失败：回 409、ok false（同 Windows），不先回成功让 s2armctl 空等或读上一批（审计 P1-166）
            if let why = await model.createBatch() { return ControlReply(code: 409, body: ControlReply.json(["ok": false, "error": why, "skipped": skipped])) }
            return .object(["ok": true, "skipped": skipped])
        case ("POST", "/build"):
            guard let g = game() else { return .bad("没有这个 gameId") }
            switch str("target") ?? "ios" {
            case "ios", "iphone", "ipad": return blocked(model.export(g, platforms: [.ios], spaceOverride: spaceOverride))
            case "mac", "macos": return blocked(model.export(g, platforms: [.mac], spaceOverride: spaceOverride))
            case "android", "harmony", "ohos": return ControlReply(code: 409, body: ControlReply.json(["error": "即将上线，敬请期待", "comingSoon": true]))
            default: return .bad("target 只认 ios / mac / android / harmony")
            }
        case ("POST", "/installCheck"):
            guard let g = game() else { return .bad("没有这个 gameId") }
            model.checkInstall(g.id, device: str("device")); return .ok()   // device：查哪一台（s2armctl install-check --device），不给按界面上选中的那台
        case ("POST", "/install"):
            guard let g = game() else { return .bad("没有这个 gameId") }
            if let b = busy() { return b }
            // 往设备上装东西一律要说明装到哪台（11-11：作业层不替玩家挑，控制口也不拿界面上选中的那台顶替）；s2armctl targets 列设备号。
            //   装法是「导出，自己签名安装」时不连手机、出到文件夹，不要 device（同界面按钮、同 Windows 控制口）
            let device = str("device")
            if device == nil, model.installMode.mode != "export" { return .bad(Self.deviceRequired) }
            model.install(g, teamId: str("teamId"), device: device, acceptDropped: a["acceptDropped"] as? Bool ?? false,
                          accept: Set(["acceptNoBackup", "acceptStale"].filter { a[$0] as? Bool == true }), ask: false); return .ok()
        case ("POST", "/signingProject"):
            model.openSigningProject(); return .ok()
        case ("POST", "/update-phone"):   // 更新 iPhone 上的 S2Arm（v0.3.0）：同库页右上角按钮；有要重新出包的款没给 acceptStale → 409 列出它们
            if let b = busy() { return b }
            guard let u = model.phoneUpdate else { return ControlReply(code: 409, body: ControlReply.json(["ok": false, "error": "按这台电脑的装机记录，手机上的 S2Arm 已是本版"])) }
            let accept = a["acceptStale"] as? Bool ?? false
            let stale = u.stale.map { ["gameId": $0.id, "name": $0.name] }
            if a["ask"] as? Bool == true {   // 同玩家点库页右上角按钮：有要重新出包的款弹三选一（玩家在窗口里选），没有就直接更新
                model.requestPhoneUpdate(language: "zh-Hans"); return .object(["ok": true, "asked": !u.stale.isEmpty, "stale": stale])
            }
            if !u.stale.isEmpty, !accept {
                return ControlReply(code: 409, body: ControlReply.json(["ok": false, "error": "这几款要按新版重新出包，重新出包前暂时打不开：带 acceptStale 确认（repack 为真时更新完把它们排进批量出包、出完自动装）", "stale": stale]))
            }
            model.updatePhone(acceptStale: accept, repack: a["repack"] as? Bool == true ? u.stale.map(\.id) : [], language: "zh-Hans",
                              device: (a["device"] as? String).flatMap { $0.isEmpty ? nil : $0 },   // 同 /install：连着多台时指定哪台
                              acceptDropped: a["acceptDropped"] as? Bool ?? false, accept: Set(["acceptNoBackup"].filter { a[$0] as? Bool == true }), ask: false)   // 同 /install：会挤掉别的电脑装的款时原样失败，带 acceptDropped 再发
            return .object(["ok": true, "stale": stale])
        case ("POST", "/restore-iphone"):
            guard let g = game() else { return .bad("没有这个 gameId") }
            guard g.iphoneRestorable else { return .bad("没有可以装回的上一版手机 S2Arm") }
            if let b = busy() { return b }
            guard let device = str("device") else { return .bad(Self.deviceRequired) }
            model.restorePhone(g, device: device); return .ok()
        case ("POST", "/uninstall"):
            guard let g = game() else { return .bad("没有这个 gameId") }
            if let b = busy() { return b }
            guard let device = str("device") else { return .bad(Self.deviceRequired) }
            model.removeFromPhone(g, ask: false, device: device, accept: Set(["acceptDropped", "acceptNoBackup"].filter { a[$0] as? Bool == true })); return .ok()
        case ("POST", "/customize"):
            guard let g = game() else { return .bad("没有这个 gameId") }
            if let b = busy() { return b }
            model.customize(g, name: str("name"), coverPath: str("coverPath")); return .ok()
        case ("POST", "/delete"):
            guard let g = game() else { return .bad("没有这个 gameId") }
            if let b = busy() { return b }
            model.deleteGame(g); return .ok()
        case ("POST", "/launch"):
            guard let g = game() else { return .bad("没有这个 gameId") }
            if let b = busy() { return b }
            model.play(g, uiLanguage: nil)
            if let e = model.actionError(for: g.id) { return .bad(e) }
            return .ok()
        case ("POST", "/cancel"):
            // 按任务号取消（启动器剃刀 M23）：原先不管传什么都停当前那个；任务号对不上回 409，不停错作业
            guard let id = str("taskId") else { return .bad("缺 taskId") }
            guard model.busy else { return .bad("没有在跑的作业") }
            guard let current = model.session?.taskID, current == id else {
                return .bad("这个 taskId 不是正在跑的作业（正在跑：\(model.session?.taskID ?? "还没拿到任务号")）", code: 409)
            }
            model.stop(); return .ok()
        case ("POST", "/retry"):
            guard let id = str("taskId"), let t = ControlJournal.tasks(privateRoot: model.provider.client.environment.privateRoot, limit: 500).first(where: { $0["id"] as? String == id }) else {
                return .bad("没有这个 taskId")
            }
            let g = (t["gameId"] as? String).flatMap { gid in model.games.first { $0.id == gid } }
            switch (t["operation"] as? String, g) {
            case ("build", let g?): return blocked(model.export(g, platforms: [.mac]))
            case ("ipa", let g?): return blocked(model.export(g, platforms: [.ios], deviceTarget: deviceTarget))
            case ("install", let g?):
                model.install(g, ask: false); return .ok()
            case ("installRemove", let g?): model.removeFromPhone(g, ask: false); return .ok()
            case ("installRestore", let g?): model.restorePhone(g); return .ok()
            default: return .bad("这条任务（\(t["operation"] as? String ?? "?")）不能直接重试：照原样再发一次命令（keys / games 带路径）")
            }
        case ("POST", "/update"):
            switch str("action") {
            case "restart":
                guard model.updateState == .ready else { return .bad("新版还没下载好", code: 409) }
                if let b = busy() { return b }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.restartToUpdate() }   // 先把回复发出去，再退出
                return .ok()
            case "retry":
                model.downloadUpdate(); return .ok()
            default: return .bad("action 只认 restart / retry")
            }
        case ("POST", "/library"):
            guard let p = str("path") else { return .bad("缺 path") }
            if let b = busy() { return b }
            model.changeLibrary(to: URL(fileURLWithPath: p), move: a["move"] as? Bool ?? false); return .ok()
        case ("POST", "/display"):
            guard let id = str("gameId") else { return .bad("缺 gameId") }
            if let b = busy() { return b }
            // 启动设置：settings 的键 = 共享定义表 id（launchers/shared/game_settings.v1.json），值 bool / 选项 / null（回缺省），作业层按表校验
            let change = a["settings"] as? [String: Any] ?? [:]
            do {
                let (options, _) = try await model.launchSettings(id, change: change.isEmpty ? nil : change)
                return .object(options.mapValues { ["available": $0.available, "value": $0.value ?? NSNull(), "reason": $0.reason] })
            } catch { return .bad(error.localizedDescription) }
        case ("POST", "/cloudFolder"):
            // iCloud 存档同步的云盘文件夹（同环境页「选择文件夹…」）：path 为空 = 关闭
            let path = str("path") ?? ""
            do { try model.setCloudFolder(path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)) } catch { return .bad(error.localizedDescription) }
            return .ok(["folder": model.cloudFolder?.path ?? ""])
        case ("POST", "/cloudSync"):
            // 对一款立即同步一次（开局前 / 退出后自动做的同一件事）；冲突时弹窗等人选
            guard let id = str("gameId") else { return .bad("缺 gameId") }
            guard model.cloudFolder != nil else { return .bad("还没开 iCloud 存档：先 cloud-folder <iCloud 云盘里的文件夹>") }
            if let b = busy() { return b }
            if let why = await model.cloudSyncNow(id) { return .bad(why) }
            return .ok()
        case ("POST", "/select"):
            if let id = str("gameId") { model.selectedID = id }
            return .ok()
        case ("POST", "/onboarding"):
            return .ok(["note": "新界面没有引导页，已忽略"])
        case ("POST", "/environment"):
            model.checkEnvironment(); return .ok()
        case ("POST", "/show"):   // 打开某一页（同玩家点标题栏「环境检查」/ 游戏的「出包」/ 回游戏库）：AI 照手册操作、截图核界面用
            switch str("page") ?? "" {
            case "environment": model.exportFor = nil; model.showEnvironment = true
            case "export":
                guard let g = game() else { return .bad("没有这个 gameId") }
                model.showEnvironment = false; model.exportFor = g.id
            case "library": model.showEnvironment = false; model.exportFor = nil
            case "install":   // 装机窗（进度 / 完成页）：同点顶栏「查看结果」
                guard let g = game() else { return .bad("没有这个 gameId") }
                model.showEnvironment = false; model.showInstallFor = g.id
            default: return .bad("page 只认 environment / export / library / install")
            }
            return .ok()
        case ("POST", "/refresh"):
            model.refresh(); return .ok()
        case ("POST", "/dismiss"):
            model.dismissErrors(); return .ok()
        case ("POST", "/diagnostics"):
            if let b = busy() { return b }
            switch str("action") {
            case "pull": model.diagnostics(exportTo: nil); return .ok()
            case "export":
                guard let p = str("path") else { return .bad("缺 path") }
                model.diagnostics(exportTo: URL(fileURLWithPath: p)); return .ok()
            case "upload":   // 打开「上传给开发者」弹窗（同游戏库「更多」菜单）；gameId 可省
                if str("gameId") != nil, game() == nil { return .bad("没有这个 gameId") }
                model.diagUploadFor = game()?.id ?? ""; return .ok()
            case "uploadSend", "uploadCopy", "uploadClose":   // 替玩家点弹窗里的「上传 / 复制 / 完成」；结果看 GET /snapshot
                guard model.diagUploadFor != nil else { return .bad("上传弹窗没开") }
                model.diagUploadCommand = .init(action: String(str("action")!.dropFirst("upload".count)).lowercased()); return .ok()
            default: return .bad("action 只认 pull / export / upload / uploadSend / uploadCopy / uploadClose")
            }
        case ("POST", "/fonts"):
            return .bad("新界面用应用自带的开源字体，不能换", code: 409)
        default:
            return .bad("不认识 \(r.method) \(r.path)", code: 404)
        }
    }

    /// 自描述：AI 先 GET /help 就知道能做什么（s2armctl help 打的就是这张表）。
    /// 往设备上装 / 删 / 装回不带 device：拒绝（作业层也拒），告诉怎么查设备号
    static let deviceRequired = "缺 device：说明装到哪台（s2armctl targets 列出连着的设备、设备名和设备号），不替你挑"

    static let endpoints: [[String: String]] = [
        ["GET /state", "当前界面状态：环境检查（checks）、密钥、游戏列表（id / 能否出包 / 缺什么）、作业页（session）、任务（tasks：作业记录，进度、里程碑、diagnostics 错误码 / 原因 / 建议 / 日志）"],
        ["GET /targets", "打 iPhone 包的目标设备：当前目标、连着的设备、可选机型、可选系统大版本（会现读一次设备）"],
        ["GET /snapshot", "主窗口截图（PNG）"],
        ["POST /keys {path}", "导入 prod.keys"],
        ["POST /games {paths:[…]}", "放入游戏（NSP / XCI 文件或文件夹；本体、更新、DLC 一起放）；放完会自动准备 Mac 运行"],
        ["POST /prepare {gameId}", "Mac 准备运行（出 Mac 版）"],
        ["POST /ipa {gameId, spaceOverride?}", "打 iPhone 包（出 IPA + 资源包）；没装 .NET SDK 会先自动装；spaceOverride = true 同界面「仍然继续」"],
        ["POST /batch {games:[{gameId, platforms:[mac|iphone]}], location?}", "批量出包：一批几款、每款出哪些平台（同一款先 Mac 后 iPhone，解包只做一次），location = 一批共用的存放位置；一款接一款地出，失败不挡后面、磁盘满暂停；进度看 GET /state 的 batch（summary / items）"],
        ["POST /build {gameId, target, spaceOverride?}", "出包：spaceOverride = true 同界面「仍然继续」，磁盘预检不够也照出；target = ios（iPhone / iPad，缺省）| mac | android | harmony；安卓、鸿蒙回 409「即将上线，敬请期待」"],
        ["POST /customize {gameId, name?, coverPath?}", "改游戏显示名 / 封面（JPG、PNG）；不传的不动，传空字符串恢复默认；下次装到 iPhone 时带上"],
        ["POST /installCheck {gameId}", "装机前清单（只读）：几秒后看 GET /state 的 installReadiness"],
        ["POST /install {gameId, acceptDropped?, acceptNoBackup?, acceptStale?}", "装到 iPhone（不用先 installCheck，缺什么作业报真实原因）；可确认的失败码先问玩家、同意了带对应参数再发：container_would_drop → acceptDropped（手机上有别的电脑装的游戏这次带不上）、save_backup_failed → acceptNoBackup（覆盖前没能备份存档）、container_stale → acceptStale（旧资源包要重出）"],
        ["POST /uninstall {gameId, acceptDropped?, acceptNoBackup?}", "从 iPhone 上的 S2Arm 删一款（备份存档 → 更新容器 → 删数据；其余游戏不动）；acceptDropped / acceptNoBackup 同 /install"],
        ["POST /delete {gameId}", "删除这款游戏：IPA / 资源包 / 出包中间产物 / 缓存全删；存档与原始游戏文件保留"],
        ["POST /target {action:probe} | {productType, os}", "重新检测连接的设备 / 选出包提示用的机型和系统大版本"],
        ["POST /launch {gameId}", "在 Mac 上启动游戏"],
        ["POST /cancel {taskId} | /retry {taskId}", "停掉在跑的作业 / 重试出包、装机任务"],
        ["POST /environment", "重新检查环境"], ["POST /refresh", "刷新游戏库"],
        ["POST /diagnostics {action:pull} | {action:export, path} | {action:upload, gameId?} | {action:uploadSend|uploadCopy|uploadClose}", "拉回 iPhone 诊断 / 导出 Mac 诊断包 / 打开「上传给开发者」并替玩家点里面的按钮"],
        ["POST /update {action:restart|retry}", "更新：restart = 重启并换上已下载好的新版，retry = 重试下载；进度看 GET /state 的 update"],
        ["POST /library {path}", "换游戏库位置（外接盘也行，换后要重新放游戏）"],
        ["POST /dismiss", "关掉提示"], ["POST /select {gameId}", "选中一款"],
    ].map { ["call": $0[0], "what": $0[1]] }

    // MARK: 状态快照（字段同旧启动器，s2armctl brief / next / wait / errors 读这些）

    func state() -> [String: Any] {
        guard let m = model else { return [:] }
        let privateRoot = m.provider.client.environment.privateRoot
        let keys = m.keysReady
        let rd: Any = m.installReadiness.map { r -> [String: Any] in
            ["gameId": m.installGameID ?? "", "checkedDevice": m.installReadinessDevice ?? "", "ready": r.ready, "device": r.device, "account": r.account, "signing": r.signing,
             "items": r.items.map { ["id": $0.id, "ok": $0.ok, "waiting": $0.waiting, "title": $0.title, "detail": $0.detail, "who": $0.who] }]
        } ?? NSNull()
        let session: Any = m.session.map { s -> [String: Any] in
            let phase: String
            switch s.phase { case .running: phase = "running"; case .stopping: phase = "cancelling"; case .finished(let st): phase = st.rawValue }
            return ["kind": s.kind.rawValue, "gameId": s.gameID ?? NSNull(), "name": s.name, "phase": phase, "stage": s.stage, "message": s.message]
        } ?? NSNull()
        return [
            "frontend": "S2Arm × NX2Apple",
            "selection": "library", "selectedGame": m.selectedID ?? NSNull(),
            "showOnboarding": false, "onboardingStep": 0, "inputGuide": NSNull(),
            "iphoneTarget": deviceTarget ?? NSNull(),
            "targetProbe": ["connected": probe["connected"] as? [[String: Any]] ?? [], "models": (probe["models"] as? [Any])?.count ?? 0,
                            "osChoices": probe["osChoices"] as? [Int] ?? []],
            "keyStatus": keys == true ? "已导入" : keys == false ? "没有密钥" : "还没读到", "hasImportedKeys": keys == true,
            "waitingForAccess": NSNull(),
            // 控制口的「就绪」= Mac 上能准备/启动（同 ready(for:"prepare")）；readyMac 只是打 iPhone 包还缺项，不算没就绪
            "environmentReady": m.environmentState == .ready || m.environmentState == .readyMac,
            "runtimeReady": m.environmentState == .ready || m.environmentState == .readyMac,
            "checkingEnvironment": m.checking || (m.checks.isEmpty && m.environmentError == nil),
            "checks": m.checks.map { ["name": $0.name, "ok": $0.ok, "message": $0.message, "group": $0.group, "action": $0.action ?? NSNull()] as [String: Any] },
            "fontsDir": NSNull(), "library": m.provider.client.environment.library,
            "games": m.games.map { g -> [String: Any] in
                ["id": g.id, "name": g.name, "customName": g.customName, "customCover": g.customCover, "cover": g.cover ?? "", "display": g.display, "compatibility": g.compatibility, "ready": g.playable, "iphoneRestorable": g.iphoneRestorable,
                 "needsPreparation": g.needsPreparation, "needsKeys": g.needsKeys, "buildable": g.buildable, "missing": g.missing,
                 "baseBytes": g.packages.filter { $0.type == "base" }.reduce(Int64(0)) { $0 + $1.size }, "bytes": g.totalBytes] },
            "session": session, "busy": m.busy,
            "tasks": ControlJournal.tasks(privateRoot: privateRoot), "queue": [String](),
            "executionTask": m.busy ? (m.session?.taskID.map { $0 as Any } ?? NSNull()) : NSNull(),   // 在跑的作业层任务号（同旧前端 Store.executionTask），s2armctl next 据此判「本游戏正在运行」
            "notice": NSNull(),
            "error": (m.actionError ?? (m.libraryError == LibraryProvider.noLibraryMessage ? nil : m.libraryError) ?? m.environmentError ?? m.installError ?? m.aiControlError).map { $0 as Any } ?? NSNull(),
            "installReadiness": rd,
            "update": m.updateStatus,
            "installMode": ["mode": m.installMode.mode, "exportAvailable": m.installMode.exportAvailable],
            "phoneUpdates": m.phoneUpdates.map { u in ["device": u.device, "games": u.games.map(\.id), "stale": u.stale.map(\.id)] as [String: Any] },
            "batch": m.batchState.map { s -> [String: Any] in ["running": m.batchRunning, "summary": s["summary"] ?? [:], "next": s["next"] ?? NSNull(),
                                                                   "items": ((s["batch"] as? [String: Any])?["items"]) ?? [], "paused": ((s["batch"] as? [String: Any])?["paused"]) ?? NSNull()] } ?? NSNull(),
            "cachedAt": Date().timeIntervalSince1970,
            "screenCaptureAllowed": Self.screenCaptureAllowed, "lastSnapshotPath": lastSnapshotPath,
            "overlays": [(m.showEnvironment, "环境检查页"), (m.exportFor != nil, "出包页")].filter { $0.0 }.map { $0.1 },
            // 窗口在屏幕上的位置（左上角原点，单位点），给客户端用系统 screencapture -R 截真画面
            "windows": NSApp.windows.filter(\.isVisible).map { w -> [String: Any] in
                let top = (NSScreen.screens.first?.frame.maxY ?? 0) - w.frame.maxY
                return ["title": w.title, "number": w.windowNumber, "sheet": w.sheetParent != nil, "main": w.isMainWindow,
                        "rect": [w.frame.minX, top, w.frame.width, w.frame.height]] },
        ]
    }

    static var screenCaptureAllowed: Bool {
        typealias P = @convention(c) () -> Bool
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGPreflightScreenCaptureAccess") else { return false }
        return unsafeBitCast(sym, to: P.self)()
    }

    /// 主窗口 + 盖在上面的弹出层：窗口服务器按窗口号合成（截自己的窗口不要屏幕录制权限）；出不了图再退回只画主窗口视图层级。
    func snapshot() -> Data? {
        let vis = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        guard let main = vis.first(where: { $0.sheetParent == nil && $0.frame.width > 200 }) else { return nil }
        let ids = ([main] + vis.filter { $0 !== main && ($0.sheetParent === main || $0.parent === main) }).reversed().map { NSNumber(value: CGWindowID($0.windowNumber)) }
        typealias Fn = @convention(c) (CGRect, CFArray, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray"),
           let img = unsafeBitCast(sym, to: Fn.self)(.null, ids as CFArray, 1, 0)?.takeRetainedValue(), img.width > 1 {
            lastSnapshotPath = "window-server"
            return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        }
        guard let v = main.contentView?.superview ?? main.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        lastSnapshotPath = "视图层级（不含弹出层、毛玻璃）"
        return rep.representation(using: .png, properties: [:])
    }
}
