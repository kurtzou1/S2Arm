// 本机控制口（用户体验线 10-23，维护者：测试时前端照常开窗口给人看，AI 不看屏幕也能操作）。
// 玩家在「设置 → 允许 AI 操作 S2Arm」打开（维护者 10-23：玩家用自己的 AI 完成移植），或带 --control 启动（环境变量 S2ARM_CONTROL=1）；只听 127.0.0.1；每次启动随机令牌，
// 端口与令牌写进 <私有目录>/control.json（0600），客户端 launchers/macos/s2armctl.py 读它连进来。
// 每个命令都调界面按钮背后的同一个 Store 方法，所以屏幕上看到的和人点的一样；选文件的对话框改成直接给路径。
// 收发（监听、令牌、control.json、快照缓存、请求解析）11-07 抽到适配层 ControlPort，新前端 S2ArmApple 用同一份；这里只剩命令表与状态快照。
import Foundation
import AppKit
import S2ArmAppleAdapter

typealias Request = ControlRequest

@MainActor final class ControlServer {
    static var shared: ControlServer?
    static var forced: Bool { ControlPort.forced }
    private let store: Store
    private var transport: ControlPort!
    nonisolated let token: String
    var port: UInt16 { transport?.port ?? 0 }

    static func start(store: Store) {
        guard forced || store.preferences.aiControl == true, shared == nil else { return }
        do { shared = try ControlServer(store: store) } catch { failed(store: store, error.localizedDescription) }
    }
    // 起不来或 control.json 写不上（审计 18:00 P2-35）：不算已开，开关退回关，原因报给玩家
    private static func failed(store: Store, _ why: String) {
        NSLog("S2Arm 控制口起不来：\(why)")
        if !forced { store.preferences.aiControl = false; store.savePreferences(); store.objectWillChange.send() }
        store.error = L("AI 操作没有打开：") + why
    }
    // 令牌（审计 18:00 P2-35）：系统随机数失败时不能退成 32 个 0，抛错由 start 报出
    static func makeToken(_ random: (inout [UInt8]) -> OSStatus = { SecRandomCopyBytes(kSecRandomDefault, $0.count, &$0) }) throws -> String {
        do { return try ControlPort.makeToken(random) }
        catch let e as NSError { throw NSError(domain: e.domain, code: e.code, userInfo: [NSLocalizedDescriptionKey: L("系统随机数生成失败") + "（\(e.code)）"]) }
    }
    // 设置里关掉：停听、删 control.json（AI 立刻连不上）
    static func stop(store: Store) {
        guard !forced, let s = shared else { return }
        s.transport.stop(); shared = nil
    }

    init(store: Store) throws {
        self.store = store
        var t: ControlPort?
        var me: ControlServer? = nil
        t = try ControlPort(privateRoot: store.privateRoot,
                            state: { me?.state() ?? [:] },
                            handle: { r in guard let me else { return .bad("控制口已停") }; let (c, ty, b) = me.handle(r); return ControlReply(code: c, type: ty, body: b) },
                            failed: { why in
                                // 写不上 control.json / 监听失败：不算已开（审计 18:00 P2-35）
                                if Self.shared === me { Self.shared = nil }
                                Self.failed(store: store, why.hasPrefix("写不了 ") ? L("写不了 ") + why.dropFirst("写不了 ".count) : why)
                            })
        token = t!.token
        transport = t
        me = self
        transport.refreshCache()
    }

    nonisolated static func json(_ o: Any) -> Data { ControlReply.json(o) }
    private func ok(_ extra: [String: Any] = [:]) -> (Int, String, Data) { (200, "application/json", Self.json(extra.merging(["ok": true]) { a, _ in a })) }
    private func bad(_ msg: String) -> (Int, String, Data) { (400, "application/json", Self.json(["error": msg])) }

    func handle(_ r: Request) -> (Int, String, Data) {
        let a = r.body
        func str(_ k: String) -> String? { a[k] as? String }
        func game(_ k: String = "gameId") -> Game? { str(k).flatMap { id in store.games.first { $0.id == id } } }
        switch (r.method, r.path) {
        case ("GET", "/state"): return (200, "application/json", Self.json(state()))
        case ("GET", "/help"): return (200, "application/json", Self.json(["version": S2ArmRelease.version, "build": S2ArmRelease.build, "buildId": S2ArmRelease.buildID, "endpoints": Self.endpoints]))
        case ("GET", "/targets"):
            let enc = JSONEncoder(); func obj<T: Encodable>(_ v: T) -> Any { (try? JSONSerialization.jsonObject(with: enc.encode(v))) ?? NSNull() }
            let p = store.targetProbe
            return (200, "application/json", Self.json(["current": store.iphoneTarget.map { obj($0) } ?? NSNull(), "connected": p.connected.map { obj($0) },
                                                        "models": p.models.map { ["model": $0.model, "productType": $0.productType, "gpuArch": $0.gpuArch] }, "osChoices": p.osChoices]))
        case ("POST", "/diagnostics"):
            // pull = 拉回连着的 iPhone 上的诊断；export = Mac 端诊断包写到 path（同设置里两个按钮）
            switch str("action") {
            case "pull": store.pullDeviceDiagnostics(); return ok()
            case "export":
                guard let p = str("path") else { return bad("缺 path") }
                store.worker("diagnostics", extra: ["path": p]) { _ in }; return ok()
            default: return bad("action 只认 pull / export")
            }
        case ("GET", "/snapshot"):
            guard let png = snapshot() else { return bad("没有可截的窗口") }
            return (200, "image/png", png)
        case ("POST", "/keys"):
            guard let p = str("path") else { return bad("缺 path") }
            store.importKeys(from: URL(fileURLWithPath: p)); return ok()
        case ("POST", "/fonts"):
            store.setFontsDir(str("path")); return ok()
        case ("POST", "/games"):
            guard let ps = a["paths"] as? [String], !ps.isEmpty else { return bad("缺 paths") }
            let urls = ps.map { URL(fileURLWithPath: $0) }
            // 前置条件不齐（环境没过 / 没选游戏库 / 没导密钥）照实报，不回成功让调用方干等（检查还在跑的不算，由 addGames 等它跑完）
            if !store.checkingEnvironment, !store.importPrerequisitesReady() { return bad("还不能放游戏：" + store.importBlocker) }
            if store.showOnboarding { store.addGamesFromOnboarding(urls) } else { store.addGames(urls) }
            return ok()
        case ("POST", "/prepare"):
            guard let g = game() else { return bad("没有这个 gameId") }
            closeOnboarding(); store.enqueue(g); return ok()
        case ("POST", "/ipa"):
            guard let g = game() else { return bad("没有这个 gameId") }
            closeOnboarding(); store.packIPhone(g); return ok()
        case ("POST", "/install"):
            guard let g = game() else { return bad("没有这个 gameId") }
            closeOnboarding(); store.installToPhone(g); return ok()
        case ("POST", "/installCheck"):
            // 装机前清单（只读）：结果几秒后出现在 GET /state 的 installReadiness（带 gameId，旧的同款结果先清掉免得读到上一次）
            guard let g = game() else { return bad("没有这个 gameId") }
            if store.installReadiness?.gameId == g.id { store.installReadiness = nil }
            store.checkInstallReadiness(gameId: g.id); return ok()
        case ("POST", "/build"):
            // 统一出包入口（11-02 维护者：导出目标 iPhone / iPad、macOS、安卓、鸿蒙）：ios = 打 iPhone 包，mac = Mac 编译；安卓、鸿蒙未开放
            guard let g = game() else { return bad("没有这个 gameId") }
            switch str("target") ?? "ios" {
            case "ios", "iphone", "ipad": closeOnboarding(); store.packIPhone(g); return ok()
            case "mac", "macos":
                if let why = store.enqueueBlocker(g) { return (409, "application/json", Self.json(["error": why])) }
                closeOnboarding(); store.enqueue(g); return ok()
            case "android", "harmony", "ohos": return (409, "application/json", Self.json(["error": "即将上线，敬请期待", "comingSoon": true]))
            default: return bad("target 只认 ios / mac / android / harmony")
            }
        case ("POST", "/delete"):
            guard let g = game() else { return bad("没有这个 gameId") }
            store.deleteGame(g); return ok()
        case ("POST", "/launch"):
            guard let g = game() else { return bad("没有这个 gameId") }
            store.launch(g, inputGuideHandled: true); return ok()
        case ("POST", "/cancel"):
            guard let id = str("taskId"), let t = store.tasks.first(where: { $0.id == id }) else { return bad("没有这个 taskId") }
            store.cancel(t); return ok()
        case ("POST", "/retry"):
            guard let id = str("taskId"), let t = store.tasks.first(where: { $0.id == id }) else { return bad("没有这个 taskId") }
            store.retry(t); return ok()
        case ("POST", "/select"):
            if let s = str("selection") { store.selection = s }
            if let g = str("gameId") { store.selectedGame = g }
            return ok()
        case ("POST", "/onboarding"):
            switch str("action") {
            case "open": store.openOnboarding()
            case "finish": store.finishOnboarding(addGames: false)
            case "defer": store.deferOnboarding()
            case "step": if let n = a["step"] as? Int { store.onboardingStep = n }
            default: return bad("action 只认 open / finish / defer / step")
            }
            return ok()
        case ("POST", "/target"):
            // {"action":"probe"} 重新检测连接的设备；{"productType":"iPhone17,1","os":26} 选机型 / 系统（同界面「更换」菜单）
            if str("action") == "probe" { store.probeTarget(); return ok() }
            guard let pt = str("productType"), let os = a["os"] as? Int, var t = store.targetProbe.models.first(where: { $0.productType == pt }) else { return bad("缺 productType / os，或机型不在可选列表（先 probe）") }
            t.os = os; store.chooseTarget(t); return ok()
        case ("POST", "/environment"):
            store.checkEnvironment(); return ok()
        case ("POST", "/refresh"):
            store.refresh(); return ok()
        case ("POST", "/dismiss"):
            store.error = nil; store.notice = nil; return ok()
        default: return (404, "application/json", Self.json(["error": "不认识 \(r.method) \(r.path)"]))
        }
    }

    // AI 开始编译时收起引导页（等同玩家点引导页的「开始编译」），否则引导页一直盖着、玩家看不到编译进度（10-23 AI 第二轮试用）
    private func closeOnboarding() { if store.showOnboarding { store.finishOnboarding(addGames: false) } }

    // 自描述：AI 先 GET /help 就知道能做什么（s2armctl help 打的就是这张表）
    static let endpoints: [[String: String]] = [
        ["GET /state", "当前界面状态：环境检查、密钥、弹出层（overlays：引导页 / 输入映射页 / 提示框，开着时先处理）、游戏列表（id / 能否编译 / 缺什么）、任务（进度、里程碑、diagnostics：错误码 code、summary、suggestion、logPath）"],
        ["GET /targets", "打 iPhone 包的目标设备：当前目标、连着的设备、可选机型、可选系统大版本"],
        ["GET /snapshot", "主窗口截图（PNG）"],
        ["POST /keys {path}", "导入 prod.keys"],
        ["POST /games {paths:[…]}", "放入游戏（NSP / XCI 文件或文件夹；本体、更新、DLC 一起放）"],
        ["POST /prepare {gameId}", "Mac 编译（排队，一款一款来）"],
        ["POST /ipa {gameId}", "打 iPhone 包（出 IPA + 资源包）；没装 .NET SDK 会先自动装"],
        ["POST /build {gameId, target}", "出包：target = ios（iPhone / iPad，缺省）| mac | android | harmony；安卓、鸿蒙回 409「即将上线，敬请期待」"],
        ["POST /installCheck {gameId}", "装机前清单（只读）：iPhone 版做好没有、Xcode 登录 Apple ID、iPhone 连上、信任、开发者模式；几秒后看 GET /state 的 installReadiness"],
        ["POST /install {gameId}", "装到 iPhone：用 Xcode 登录的 Apple ID 签名、数据线安装、拷资源包并逐文件核对（要连着 iPhone）"],
        ["POST /delete {gameId}", "删除这款游戏：IPA / 资源包 / 出包中间产物 / 缓存全删、从游戏库移除；存档与原始游戏文件保留"],
        ["POST /target {action:probe} | {productType, os}", "重新检测连接的设备 / 没连设备时选机型和系统大版本"],
        ["POST /launch {gameId}", "在 Mac 上启动游戏；AI / 脚本直接启动，不等待键位卡确认"],
        ["POST /cancel {taskId} | /retry {taskId}", "取消 / 重试任务"],
        ["POST /environment", "重新检查环境"], ["POST /refresh", "刷新游戏库"],
        ["POST /diagnostics {action:pull} | {action:export, path}", "拉回 iPhone 诊断 / 导出 Mac 诊断包"],
        ["POST /fonts {path}", "换成原版字体目录（空串 = 用应用自带）"],
        ["POST /onboarding {action:open|finish|defer|step}", "引导页"], ["POST /select {selection, gameId}", "切页面"], ["POST /dismiss", "关掉提示框"],
    ].map { ["call": $0[0], "what": $0[1]] }

    func state() -> [String: Any] {
        let enc = JSONEncoder()
        func obj<T: Encodable>(_ v: T) -> Any { (try? JSONSerialization.jsonObject(with: enc.encode(v))) ?? NSNull() }
        let s = store
        return [
            "selection": s.selection ?? NSNull(), "selectedGame": s.selectedGame ?? NSNull(),
            "showOnboarding": s.showOnboarding, "onboardingStep": s.onboardingStep,
            "inputGuide": s.inputGuide.map { ["gameId": $0.game.id, "name": $0.game.name, "mappingSupported": $0.supported] as [String:Any] } ?? NSNull(),
            "iphoneTarget": s.iphoneTarget.map { obj($0) } ?? NSNull(),
            "targetProbe": ["connected": s.targetProbe.connected.map { obj($0) }, "models": s.targetProbe.models.count, "osChoices": s.targetProbe.osChoices],
            "keyStatus": s.keyStatus, "hasImportedKeys": s.hasImportedKeys, "waitingForAccess": s.waitingForAccess ?? NSNull(),
            "environmentReady": s.environmentReady, "runtimeReady": s.runtimeReady, "checkingEnvironment": s.checkingEnvironment,
            "checks": s.checks.map { ["name": $0.name, "ok": $0.ok, "message": $0.message, "group": $0.group ?? NSNull()] as [String: Any] },
            "fontsDir": s.preferences.fontsDir ?? NSNull(), "library": s.preferences.library,
            "games": s.games.map { g -> [String: Any] in
                ["id": g.id, "name": g.name, "display": g.display, "compatibility": g.compatibility ?? NSNull(), "ready": g.ready ?? NSNull(),
                 "needsPreparation": g.needsPreparation ?? NSNull(), "buildable": g.buildable, "missing": g.missing ?? [],
                 // 本体 / 全部包字节数（AI 代操作：同一文件夹里的游戏 + 同系列小工具导入后是两款，按本体大小认主游戏，10-26）
                 "baseBytes": g.packages.filter { $0.type == "base" }.reduce(Int64(0)) { $0 + g.ownBytes($1) }, "bytes": g.sourceBytes] },
            "tasks": s.tasks.map { obj($0) }, "queue": s.queue, "executionTask": s.executionTask ?? NSNull(),
            "notice": s.notice ?? NSNull(), "error": s.error ?? NSNull(),
            "installReadiness": s.installReadiness?.json ?? NSNull(),
            "cachedAt": Date().timeIntervalSince1970,   // 快照时刻：客户端见它停在 20 秒前 = 主线程卡住，改按作业记录判（s2armctl.py wait）
            "lastSnapshotPath": lastSnapshotPath, "overlays": overlays(),
            // 窗口在屏幕上的位置（左上角原点，单位点）
            "windows": NSApp.windows.filter(\.isVisible).map { w -> [String: Any] in
                let top = (NSScreen.screens.first?.frame.maxY ?? 0) - w.frame.maxY
                return ["title": w.title, "number": w.windowNumber, "sheet": w.sheetParent != nil, "main": w.isMainWindow,
                        "rect": [w.frame.minX, top, w.frame.width, w.frame.height]] },
        ]
    }

    // 窗口截图只走离屏渲染：逐窗口画视图层级（cacheDisplay），不走系统截屏 / 窗口服务器合成——那两条会弹屏幕录制授权框、挂着等人点
    var lastSnapshotPath = ""
    // 当前盖在主窗口上的弹出层（从界面状态读）：给 AI 看「有没有弹框挡着」，截图口径也拿它核对弹出层叠全了没有
    func overlays() -> [String] {
        [(store.showOnboarding, "引导页"), (store.editingInput, "输入映射页"), (store.inputGuide != nil, "键位引导"), (store.error != nil, "「操作未完成」提示框")].filter { $0.0 }.map { $0.1 }
    }
    func snapshot() -> Data? {
        let vis = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        guard let main = vis.first(where: { $0.title == "S2Arm" && $0.sheetParent == nil }) ?? vis.first(where: { $0.sheetParent == nil }) else { return nil }
        // 逐窗口画视图层级，弹出层（引导页等）按屏幕位置叠到主窗口上；毛玻璃画不出（显示成纯色）
        func draw(_ w: NSWindow) -> NSBitmapImageRep? {
            guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
            v.cacheDisplay(in: v.bounds, to: rep); return rep
        }
        guard let base = draw(main) else { return nil }
        let sheets = vis.filter { $0 !== main && ($0.sheetParent === main || $0.parent === main) }
        let scale = CGFloat(base.pixelsWide) / main.frame.width
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        base.draw(in: NSRect(x: 0, y: 0, width: base.pixelsWide, height: base.pixelsHigh))
        for w in sheets { if let r = draw(w) {
            r.draw(in: NSRect(x: (w.frame.minX - main.frame.minX) * scale, y: (w.frame.minY - main.frame.minY) * scale, width: w.frame.width * scale, height: w.frame.height * scale))
        } }
        NSGraphicsContext.restoreGraphicsState()
        lastSnapshotPath = "视图层级（弹出层 \(sheets.count) 个已叠上；毛玻璃画不出）"
        // 界面状态说开着的弹出层比实际叠上的多（某个弹出层不是单独窗口、画不出）时明说截不全，不给一张像是「什么都没弹」的图
        let open = overlays()
        if open.count > sheets.count {
            lastSnapshotPath += "；截不全：\(open.joined(separator: "、"))开着，App 自绘没把它叠上"
        }
        return canvas.representation(using: .png, properties: [:])
    }
}
