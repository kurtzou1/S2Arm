// UI synchronized from LumaNX 8872342 (MIT); S2Arm actions remain local.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class DroppedURLs: @unchecked Sendable {
    private let lock=NSLock();private var urls:[URL]=[]
    func append(_ u:URL){lock.lock();urls.append(u);lock.unlock()}
    func result()->[URL]{lock.lock();defer{lock.unlock()};return urls}
}
struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    var body: some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:20) {
                HStack(spacing:10) { BrandMark(); VStack(alignment:.leading,spacing:3) { Text(Brand.name).font(.title2.bold()); Text(L("Mac 游戏启动器")).font(.caption.weight(.medium)).tracking(1.2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7) } }.padding(.top,16).padding(.leading,4)
                List(selection:$store.selection) {
                    Label(L("游戏库"),systemImage:"square.grid.2x2").tag("library")
                    Label(L("编译任务"),systemImage:"arrow.triangle.2.circlepath").badge(store.visibleTasks.filter(\.active).count + store.queue.count).tag("tasks")
                    Label(L("导出"),systemImage:"square.and.arrow.up.on.square").tag("platforms")
                    Label(L("设置"),systemImage:"gearshape").tag("settings")
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                VStack(alignment:.leading,spacing:6) {
                    Label(store.executionBusy ? L("任务进行中") : L("本地运行"),systemImage:store.executionBusy ? "circle.dotted" : "checkmark.shield")
                    Text(L("游戏与密钥由玩家自行导入")).font(.caption).foregroundStyle(.secondary)
                    Text("S2Arm · " + (Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.2.6")).font(.caption2).foregroundStyle(.tertiary)
                }.font(.caption).padding(12).frame(maxWidth:.infinity,alignment:.leading).glassSurface(16).padding(.bottom,16)
            }.padding(.horizontal,12).navigationSplitViewColumnWidth(min:205,ideal:225,max:270)
        } detail: {
            Group {
                switch store.selection {
                case "tasks": TasksView()
                case "settings": SettingsView()
                case "platforms": PlatformBuildView()
                default: library
                }
            }
            .id(Localization.language)
            .safeAreaInset(edge:.bottom,spacing:0) {
                if !store.showOnboarding,store.selection != "tasks",store.activeTasks.contains(where:{$0.id != store.pageTask?.id}) {ActiveTaskBanner()}
            }
            .background(LibraryBackdrop()).navigationTitle(store.selection=="tasks" ? L("编译任务") : store.selection=="settings" ? L("设置") : store.selection=="platforms" ? L("导出") : L("游戏库"))
                .toolbar {
                    ToolbarItemGroup(placement:.primaryAction) {
                        if store.selection == "library" || store.selection == nil {
                            Button(action:store.chooseGames){Label(L("添加游戏"),systemImage:"plus")}.help(L("添加游戏文件夹或 NSP / XCI，放进来自动编译（⌘O）"))
                        }
                    }
                }
        }
        .frame(minWidth:1100,minHeight:720)
        .onAppear {store.checkEnvironmentAtStartup()}
        .sheet(isPresented:$store.showOnboarding,onDismiss:store.onboardingDismissed) { OnboardingView().environmentObject(store).tint(Brand.accent) }
        .sheet(isPresented:$store.editingInput) { InputEditor(game:store.inputGame, initial:store.input(for:store.inputGame)).environmentObject(store) }
        .sheet(item:$store.inputGuide,onDismiss:store.inputGuideDismissed) { guide in InputGuideView(presentation:guide).environmentObject(store) }
        .sheet(item:$store.saveManagerGame) { game in SaveManagementView(game:game).environmentObject(store) }
        .alert(L("操作未完成"),isPresented:Binding(get:{!store.showOnboarding && store.saveManagerGame == nil && store.error != nil},set:{if !$0 && !store.showOnboarding && store.saveManagerGame == nil {store.error=nil}})) {
            let diagnostic=store.errorDiagnostic
            Button(L("知道了"),role:.cancel) {store.error=nil}
            if let game=store.saveRecoveryGame {   // 存档回退失败：确认后仍可启动、或先去备份（同 iPhone 存档页，审计 18:00 P0-3）
                Button(L("仍要启动（可能丢掉没做完的导入 / 恢复）"),role:.destructive) {store.launchOverridingRecovery(game)}
                Button(L("先去备份存档")) {store.error=nil;store.saveManagerGame=game}
            } else if let diagnostic {
                Button(L("查看失败任务")) {store.showFailedTask()}
                Button(L("复制错误摘要")) {store.copyDiagnostic(diagnostic)}
            } else {Button(L("打开日志")) {store.reveal(store.diagnosticLogURL(nil))}}
        } message: {Text(store.failureMessage)}
        .overlay(alignment:.top) { VStack(spacing:0) {
            // 等系统授权（审计 18:00 P1-2）：持续状态单独常驻，转圈不打勾、不 6 秒消失，授权框点完（允许或拒绝）才收
            if let wait = store.accessWaitNotice { AccessWaitBanner(text:wait) }
            if let notice = store.notice, !(notice == store.stickyNotice && store.selection == "tasks" && store.completionHeroTask != nil) { HStack { Image(systemName:"checkmark.circle.fill").foregroundStyle(Brand.accent); Text(L(notice))
                if notice == store.stickyNotice { Button(L("查看装机步骤")) {store.showInstallGuide=true} }   // 出完 iPhone 包：常驻、带装机步骤（10-26）
                Button {store.notice=nil} label:{Image(systemName:"xmark")}.buttonStyle(.plain).accessibilityLabel(L("关闭提示")) }.padding().glassSurface().padding().id(notice)   // 换一条提示就重新计时，常驻提示之后的普通提示照样 6 秒消失
                .onAppear {DispatchQueue.main.asyncAfter(deadline:.now()+6){ if store.notice != store.stickyNotice {store.notice=nil} }} } } }
        .alert(L("工作数据放到这台 Mac 上"), isPresented:Binding(get:{store.libraryFormatProblem != nil}, set:{ if !$0 { store.libraryFormatProblem = nil } }), presenting:store.libraryFormatProblem) { _ in
            Button(L("好，用这台 Mac 上的默认位置")) { store.libraryFormatProblem = nil; store.useDefaultLibrary() }
            Button(L("重新选一个文件夹")) { store.libraryFormatProblem = nil; store.chooseLibrary() }
            Button(L("取消"), role:.cancel) { store.libraryFormatProblem = nil }
        } message: { p in Text(L("这个文件夹在 ") + p.format.uppercased() + L(" 格式的磁盘上。游戏原件放在这里没问题：放游戏时直接选它们，S2Arm 只读、不复制也不改。导出时的工作数据（游戏库）要放在 APFS 或 exFAT 格式的磁盘上，会放到这台 Mac 上的默认位置。想把工作数据也放外接盘，请选一块 APFS / exFAT 盘（FAT32 单文件有 4 GB 上限，不适合做游戏库）。")) }
        .sheet(isPresented:$store.showInstallGuide,onDismiss:store.installGuideDismissed) { InstallGuideView().environmentObject(store).tint(Brand.accent) }
    }
    var library: some View {
        HStack(spacing:16) {
            VStack(alignment:.leading,spacing:18) {
                VStack(alignment:.leading,spacing:6) { Text(L("随时，开启下一段旅程。")).font(.system(size:26,weight:.bold)); Text(L("让喜爱的游戏，在 Mac 上继续。")).foregroundStyle(.secondary) }.padding(.top,8)
                if store.refreshingLibrary {ProgressView(L("正在读取游戏库…")).progressViewStyle(.linear)}
                PlatformGlassContainer(spacing:16) {
                    HStack(spacing:12) {
                        LibraryStat(title:L("款游戏"),value:store.games.count,symbol:"square.stack.3d.up")
                            .fixedSize()
                        LibraryStat(title:L("可启动"),value:store.games.filter{$0.ready==true}.count,symbol:"play.fill")
                            .fixedSize()
                        HStack(spacing:10) {
                            Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                            TextField(L("搜索游戏或 Title ID"),text:$search).textFieldStyle(.plain).accessibilityLabel(L("搜索游戏"))
                        }.padding(.horizontal,12).frame(minWidth:140,maxWidth:.infinity).libraryControlSurface()
                    }
                }
                if store.games.isEmpty {
                    VStack(spacing:16) {
                        BrandMark(size:104)
                        Text(L("收藏你的第一段旅程")).font(.title2.bold())
                        Text(!store.environmentReady ? L("先检查系统、Xcode 与 Metal 组件，\n再导入密钥和游戏。") : store.hasImportedKeys ? L("添加 NSP、XCI、NSZ 或 XCZ 游戏文件。\n压缩文件自动解压，文件齐全后自动准备。") : L("先导入 prod.keys，\n再添加游戏、准备运行文件。")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button(action:store.hasImportedKeys && store.environmentReady ? store.chooseGames : store.openOnboarding){Label(store.hasImportedKeys && store.environmentReady ? L("添加游戏") : L("继续设置"),systemImage:store.hasImportedKeys && store.environmentReady ? "plus" : "arrow.right")}.platformButtonStyle(prominent:true).controlSize(.large)
                        Text(L("游戏、密钥与固件均需自行提供")).font(.caption).foregroundStyle(.tertiary)
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                } else {
                    List(selection:$store.selectedGame) {
                        ForEach(store.games.filter {search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.contains(search)}) { game in
                            HStack(spacing:16) {
                                GameCover(game:game).frame(width:76,height:76).clipShape(RoundedRectangle(cornerRadius:12)).accessibilityHidden(true)
                                VStack(alignment:.leading,spacing:8) {
                                    Text(game.name).font(.headline).lineLimit(2)
                                    Text(game.display.isEmpty ? L("版本待识别") : game.display).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName:game.ready == true ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(game.ready == true ? .teal : .secondary)
                            }.padding(12).padding(.vertical,3).tag(game.id).listRowSeparator(.hidden)
                        }
                        if !search.isEmpty && !store.games.contains(where:{ $0.name.localizedCaseInsensitiveContains(search) || $0.id.contains(search) }) {
                            ContentUnavailableView.search(text:search)
                        }
                    }.id(Localization.language).listStyle(.inset).scrollContentBackground(.hidden)

                }
            }.frame(minWidth:390)
            if let game = store.selected {GameDetail(game:game).frame(width:360).contentCard(22)}
        }.padding(24).onDrop(of:[UTType.fileURL],isTargeted:nil) { providers in
            let group=DispatchGroup();let urls=DroppedURLs();for provider in providers {group.enter();_ = provider.loadObject(ofClass:URL.self){url,_ in if let url{urls.append(url)};group.leave()}};group.notify(queue:.main){store.addGames(urls.result())};return true
        }
    }
}
struct GameCover: View {
    let game:Game
    var body:some View {
        if let path=game.cover,let ns=NSImage(contentsOfFile:path),let cg=ns.cgImage(forProposedRect:nil,context:nil,hints:nil) {
            Image(decorative:cg,scale:1).resizable().scaledToFit()
        } else {ZStack{Color.teal.opacity(0.12);Image(systemName:"gamecontroller.fill").font(.system(size:36)).foregroundStyle(.teal)}}
    }
}
struct GameDetail: View {
    @EnvironmentObject var store:Store
    let game:Game
    @State private var cleanKind="cache"
    @State private var confirmClean=false
    @State private var confirmDelete=false
    @State private var managementExpanded=false
    @State private var detailsExpanded=true
    var body:some View {
        ScrollView {
        PlatformGlassContainer(spacing:12) {
        VStack(alignment:.leading,spacing:12) {
            HStack(alignment:.top,spacing:12) {
                GameCover(game:game).frame(width:64,height:64).clipShape(RoundedRectangle(cornerRadius:12)).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:6) {
                    Text(game.name).font(.headline).lineLimit(3).fixedSize(horizontal:false,vertical:true)
                    Text(displayedVersion).font(.callout).foregroundStyle(.secondary)
                }
            }
            if game.ready==true && game.needsPreparation==true {
                Label(L("有更新待准备"),systemImage:"arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                    .help(L("新增内容或引擎更新尚未准备；启动将使用上次成功版本。"))
            }
            if game.ready==true {
                Button {store.launch(game)} label:{Label(L("启动游戏"),systemImage:"play.fill").frame(maxWidth:.infinity)}.platformButtonStyle(prominent:true).controlSize(.large).disabled(store.executionBusy || !store.queue.isEmpty)
            } else {
                Button {store.enqueue(game)} label:{Label(L("准备运行文件"),systemImage:"hammer").frame(maxWidth:.infinity)}.platformButtonStyle(prominent:true).controlSize(.large).disabled(!game.buildable)
                if !(game.missing ?? []).isEmpty {
                    Label((game.missing ?? []).map {L($0)}.joined(separator:"\n"),systemImage:"exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
                }
            }
            GameToolGroup(title:"游戏详情",symbol:"info.circle",expanded:$detailsExpanded) {
                VStack(alignment:.leading,spacing:10) {
                    HStack(alignment:.top,spacing:16) {
                        GameDetailField(title:"Title ID",value:game.id,monospaced:true)
                        if game.ready==true {GameDetailField(title:"导入版本",value:displayedVersion)}
                    }
                    LabeledContent(L("兼容性"),value:game.compatibilityName)
                        .help(game.compatibility=="startup" ? L("已验证启动；完整游戏流程仍需玩家验证。") : L("编译成功不代表游戏已通过兼容性验证。"))
                    if !game.packages.isEmpty {
                        Divider()
                        Text(L("导入内容")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        VStack(alignment:.leading,spacing:12) {
                            ForEach(game.packages){package in
                                VStack(alignment:.leading,spacing:4){
                                    HStack(alignment:.firstTextBaseline,spacing:8){
                                        Text(package.kindName)
                                        Spacer(minLength:8)
                                        Text(package.display.isEmpty ? "v\(package.version)" : package.display).monospacedDigit()
                                    }.font(.callout.weight(.medium))
                                    HStack(alignment:.firstTextBaseline,spacing:8){
                                        Text(package.titleId).monospaced().textSelection(.enabled)
                                        Spacer(minLength:8)
                                        Text(ByteCountFormatter.string(fromByteCount:game.ownBytes(package),countStyle:.file)).fixedSize()
                                    }.font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth:.infinity,alignment:.leading)
                            }
                        }
                    }
                }.font(.callout).padding(.horizontal,12).padding(.bottom,12).frame(maxWidth:.infinity,alignment:.leading)
                .id(Localization.language)
            }
            gameTools
        }.padding(16)
        }
        }
        .onChange(of:game.id) {managementExpanded=false;detailsExpanded=true}
        .alert(cleanKind=="sources" ? L("删除托管 NSP 副本？") : L("清理构建缓存？"),isPresented:$confirmClean) {
            Button(L("取消"),role:.cancel){}
            Button(L("确认清理"),role:.destructive){store.clean(game,kind:cleanKind)}
        } message:{Text(L("仅处理托管副本；原始文件、存档和上次成功的运行版本保留。"))}
        .alert(L("删除这款游戏？"),isPresented:$confirmDelete) {
            Button(L("取消"),role:.cancel){}
            Button(L("删除"),role:.destructive){store.deleteGame(game)}
        } message:{Text(L("会删除这款游戏的 iPhone 包（IPA）、资源包、出包中间产物和缓存，并从游戏库移除；存档和原始游戏文件保留。"))}
    }
    private var displayedVersion:String {
        return game.display.isEmpty ? L("版本待识别") : game.display
    }
    private var gameTools:some View {
        GameToolGroup(title:"管理游戏",symbol:"slider.horizontal.3",expanded:$managementExpanded) {
            VStack(spacing:0) {
                toolDivider
                Button {store.inputGame=game;store.editingInput=true} label: {
                    GameToolLabel(title:"键鼠与手柄映射",symbol:"keyboard",accessory:"chevron.right")
                }.buttonStyle(GameToolButtonStyle())
                toolDivider
                Button {store.saveManagerGame=game} label: {
                    GameToolLabel(title:"存档备份与恢复…",symbol:"clock.arrow.circlepath",accessory:"chevron.right")
                }.buttonStyle(GameToolButtonStyle())
                toolDivider
                Button {
                    let url=store.libraryURL.appendingPathComponent("saves/\(game.id)")
                    try? FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);store.reveal(url)
                } label: {
                    GameToolLabel(title:"在访达中查看存档",symbol:"folder",accessory:"arrow.up.forward")
                }.buttonStyle(GameToolButtonStyle())
                toolDivider
                if game.ready==true {
                    Button {store.enqueue(game)} label:{GameToolLabel(title:"重新检查并准备",symbol:"hammer",accessory:"chevron.right")}.buttonStyle(GameToolButtonStyle())
                        .disabled(!game.buildable)
                    toolDivider
                }
                // 审计 P2-8：游戏详情里直接打 iPhone 包（主产品路径），不必先去跨平台页启用 iOS
                Button {store.packIPhone(game)} label:{GameToolLabel(title:"打 iPhone 包",symbol:"iphone",accessory:"chevron.right")}.buttonStyle(GameToolButtonStyle())
                    .disabled(!game.buildable || store.executionBusy)
                toolDivider
                Button {store.selectedGame=game.id;store.selection="platforms"} label:{GameToolLabel(title:"导出到 iPhone / Mac…",symbol:"square.and.arrow.up.on.square",accessory:"chevron.right")}.buttonStyle(GameToolButtonStyle())
                    .help(L("选择目标平台并使用 S2Arm 现有工具出包。"))
                toolDivider
                DisclosureGroup {
                    CommunitySection(game:game,showsHeading:false).padding(12).buttonStyle(.bordered).controlSize(.small)
                } label:{GameToolLabel(title:"社区资源",symbol:"shippingbox")}
                    .disclosureGroupStyle(GameToolDisclosureStyle())
                toolDivider
                DisclosureGroup {
                    VStack(alignment:.leading,spacing:4) {
                        Button {store.remove(game)} label:{GameToolLabel(title:"移出游戏库（保留文件与存档）",symbol:"minus.circle")}.buttonStyle(GameToolButtonStyle())
                        Button(role:.destructive) {cleanKind="cache";confirmClean=true} label:{GameToolLabel(title:"清理构建缓存…",symbol:"trash",destructive:true)}.buttonStyle(GameToolButtonStyle())
                        // 只有旧版（0.1.0-beta.3 及以前）复制进游戏库的托管副本才有得删；原地导入的原件是玩家的文件，不给删
                        if game.packages.contains(where:{ !$0.path.hasPrefix("/") }) { Button(role:.destructive) {cleanKind="sources";confirmClean=true} label:{GameToolLabel(title:"删除托管 NSP 副本…",symbol:"trash",destructive:true)}.buttonStyle(GameToolButtonStyle()) }
                        Button(role:.destructive) {confirmDelete=true} label:{GameToolLabel(title:"删除这款游戏…",symbol:"trash",destructive:true)}.buttonStyle(GameToolButtonStyle())
                    }.padding(6).background(.primary.opacity(0.025))
                } label: {
                    GameToolLabel(title:"清理与移除",symbol:"trash")
                }.disclosureGroupStyle(GameToolDisclosureStyle()).disabled(store.executionBusy)
            }
        }
    }
    private var toolDivider:some View {Divider().padding(.leading,44)}
}
private struct GameDetailField:View {
    let title:String
    let value:String
    var monospaced=false
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            Text(L(title)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(monospaced ? .callout.monospaced().weight(.medium) : .callout.weight(.medium)).textSelection(.enabled)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
private struct GameToolGroup<Content:View>:View {
    let title:String
    let symbol:String
    @Binding var expanded:Bool
    @ViewBuilder var content:Content
    var body:some View {
        DisclosureGroup(isExpanded:$expanded) {content} label:{GameToolLabel(title:title,symbol:symbol)}
            .disclosureGroupStyle(GameToolDisclosureStyle())
            .clipShape(RoundedRectangle(cornerRadius:14)).glassSurface(14)
    }
}
private struct GameToolLabel:View {
    let title:String
    let symbol:String
    var accessory:String?=nil
    var destructive=false
    var body:some View {
        HStack(spacing:10) {
            Image(systemName:symbol).font(.system(size:15,weight:.medium)).foregroundStyle(destructive ? Color.red : Brand.accent).frame(width:20)
            Text(L(title)).font(.callout.weight(.medium)).fixedSize(horizontal:false,vertical:true)
                .foregroundStyle(destructive ? Color.red : Color.primary)
            Spacer(minLength:4)
            if let accessory {Image(systemName:accessory).font(.system(size:10,weight:.semibold)).foregroundStyle(.tertiary)}
        }.padding(.horizontal,12).padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
    }
}
private struct GameToolButtonStyle:ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering=false
    func makeBody(configuration:Configuration)->some View {
        configuration.label
            .background(Brand.accent.opacity(configuration.isPressed ? 0.14 : hovering && isEnabled ? 0.07 : 0))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover {hovering=$0}
    }
}
private struct GameToolDisclosureStyle:DisclosureGroupStyle {
    func makeBody(configuration:Configuration)->some View {
        VStack(spacing:0) {
            Button {withAnimation(.easeInOut(duration:0.18)){configuration.isExpanded.toggle()}} label: {
                configuration.label.overlay(alignment:.trailing) {
                    Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0)).padding(.trailing,12)
                }
            }.buttonStyle(GameToolButtonStyle()).accessibilityValue(configuration.isExpanded ? L("已展开") : L("已折叠"))
            if configuration.isExpanded {configuration.content}
        }
    }
}
struct TaskCard: View {
    @EnvironmentObject var store: Store
    let task: TaskRecord
    var logLines = 3   // 进行中「实时日志」行数：编译任务页给 12（铺满、看得出确实在做），别处嵌入 3
    var gameHeader = false   // 编译任务页：顶部换成这款游戏的信息头（图标、名称、版本、本体 / 更新 / DLC / 大小，10-26 维护者），标题行不再重复游戏名
    var body: some View {
        let game = store.games.first(where:{$0.id==task.gameId})
        VStack(alignment:.leading,spacing:8) {
            if gameHeader, let game, ["ipa","build"].contains(task.operation) { TaskGameHeader(game:game, task:task) } else {
            HStack { Label(task.title,systemImage:task.state=="failed" || task.hasWarnings || task.hasErrors ? "exclamationmark.triangle.fill" : task.state=="completed" ? "checkmark.circle.fill" : "circle.dotted").font(.headline); Text(game?.name ?? "").lineLimit(1);Spacer();Text(task.stateName).foregroundStyle(task.hasWarnings ? .orange : .secondary) }
            }
            // 阶段名：里程碑 id 换成里程碑的中文名；有里程碑进度条时它自己会写，不重复；与下面的消息相同时也不重复（10-23 走查）
            let stageName = task.stage.map { st in task.milestones?.first(where:{$0.id==st})?.label ?? st }
            let hasBar = task.active && !(task.milestones ?? []).isEmpty && task.milestone != nil
            if let stage=stageName, !task.active, !hasBar, stage != task.message { Text(SharedExperience.stageLabel(stage)).font(.callout) }
            // 一键出包（打 iPhone 包）：阶段条按现有里程碑事件画，结束页再写这一包的画面模式（#377）；
            //   有阶段条就不再画里程碑分段条（同一件事两根条，10-25 维护者 去重复）
            let packTask = task.operation == "ipa"
            let strip = packTask && !(task.milestones ?? []).isEmpty
            if strip {
                PackStageStrip(task:task)
            }
            if task.active {TaskProgressView(task:task,compact:true,showsMilestoneBar:!strip)}
            if task.active, let counters=task.counters, !counters.isEmpty {LiveCountersView(counters:counters)}   // 着色器总数 / 已编数实时跳（10-26 维护者）
            if task.active {
                DisclosureGroup(L("实时日志")) {TaskLogTail(task:task,lines:logLines,showsHeading:false)}
                    .disclosureGroupStyle(GlassDisclosureStyle())
            }
            if packTask, task.state == "completed" {
                PackModeCard(mode:store.packMode(for:task))
            }
            TaskBudgetView(task:task)
            if let msg=task.message,!msg.isEmpty,(msg != stageName || !hasBar && stageName == nil),(task.diagnostics ?? []).isEmpty {Text(L(msg)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
            ForEach(task.diagnostics ?? []) {diagnostic in TaskDiagnosticCard(diagnostic:diagnostic)}
            if task.state=="completed",let path=task.outputPath {
                Button(L("在访达中查看产物")) {store.reveal(URL(fileURLWithPath:path))}
            }
            HStack {if !task.active {TaskLogDeleteButton(task:task)};Spacer();if task.active {Button(task.operation=="launch" ? L("结束游戏") : L("取消任务")) {store.cancel(task)}.disabled(task.state=="cancelling")} else if ["failed","interrupted","cancelled"].contains(task.state),task.gameId != nil {
                // 空间预检拦下（预计偏保守）：玩家可不清空间直接试，真写满中途停下报错
                if task.spacePreflightBlocked {Button(L("仍然继续")) {store.continueDespiteSpace(task)}.disabled(store.executionBusy)}
                Button(L("重试")) {store.retry(task)}.disabled(store.executionBusy)} }
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).glassSurface(16)
    }
}
struct TaskDiagnosticCard: View {
    @EnvironmentObject var store: Store
    let diagnostic: TaskDiagnostic
    @State private var expanded=false
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Label(L(diagnostic.summary),systemImage:diagnostic.isWarning ? "exclamationmark.triangle" : "xmark.octagon")
                .font(.callout.weight(.medium)).foregroundStyle(diagnostic.isWarning ? .orange : .red)
            DisclosureGroup(L("诊断详情"),isExpanded:$expanded) {
                VStack(alignment:.leading,spacing:6) {
                    if !diagnostic.suggestion.isEmpty {Text(L(diagnostic.suggestion)).font(.caption).textSelection(.enabled)}
                    Text(diagnostic.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let stage=diagnostic.stage,!stage.isEmpty {Text(L("失败阶段：")+L(stage)).font(.caption).foregroundStyle(.secondary)}
                    if !diagnostic.detail.isEmpty {
                        Text(L("编译器输出（已脱敏）")).font(.caption).foregroundStyle(.secondary)
                        ScrollView {Text(diagnostic.detail).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.frame(maxHeight:160)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(.top,4)
            }.disclosureGroupStyle(InlineGlassDisclosureStyle {
                Button(L("打开对应日志")) {
                    let url=store.diagnosticLogURL(diagnostic)
                    store.reveal(url.pathExtension == "log" && !FileManager.default.fileExists(atPath:url.path) ? url.deletingLastPathComponent() : url)
                }
                Button(L("复制错误摘要")) {store.copyDiagnostic(diagnostic)}
                Spacer(minLength:0)
            }).font(.caption)
        }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
            .glassSurface(12)
    }
}
struct SettingsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        WorkspacePage {
            WorkspaceHeading(title:"设置",subtitle:"",symbol:"slider.horizontal.3") {
                Button(L("导出诊断包…"),action:store.exportDiagnostics).platformButtonStyle()
            }
            HStack(alignment:.top,spacing:WorkspaceLayout.sectionSpacing) {
                GlassPanel(title:"语言与外观",symbol:"paintpalette") {
                    HStack(spacing:8) {Text(L("语言")).font(.caption).foregroundStyle(.secondary).fixedSize().frame(width:72,alignment:.leading);LanguagePicker().labelsHidden()}
                    HStack(spacing:8) {Text(L("外观")).font(.caption).foregroundStyle(.secondary).fixedSize().frame(width:72,alignment:.leading);AppearancePicker().labelsHidden()}
                    CompactDisclosure(title:"语言说明",symbol:"character.bubble") {
                        Text(L("界面语言立即生效；系统文件对话框的内置按钮跟随 macOS 语言。"))
                    }.font(.caption).foregroundStyle(.secondary)
                }
                GlassPanel(title:"游戏库与玩家数据",symbol:"externaldrive") {
                    HStack {
                        Image(systemName:"folder").foregroundStyle(WorkspacePalette.accent)
                        Text((store.preferences.library.isEmpty ? store.defaultLibraryURL : store.libraryURL).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(L("选择或切换游戏库…"),action:store.chooseLibrary).disabled(store.executionBusy).controlSize(.small)
                    }
                    Text(L("游戏库放导出时的工作数据和存档，要在 APFS 或 exFAT 格式的磁盘上；游戏原件留在原处（哪块盘都行），S2Arm 只读、不复制。")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Label(L(store.keyStatus),systemImage:"key").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("导入 prod.keys…"),action:{store.importKeys()}).disabled(store.importingKeys).controlSize(.small)
                    }
                    Divider()
                    CompactDisclosure(title:"存储与导入说明",symbol:"folder.badge.gearshape") {
                        LabeledContent(L("存储位置"),value:store.preferences.library.isEmpty ? store.defaultLibraryURL.path : store.libraryURL.path).textSelection(.enabled)
                        Text(L("游戏库默认自动创建，也可切换位置。导入密钥后添加游戏。密钥通常只需导入一次，可供多款游戏共用；仅保存在本机私有目录，不随诊断包导出。"))
                        Text(L("添加的游戏放进来就自动编译，更新和 DLC 自动按版本合并。准备完成后由你点击启动。"))
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            GlassPanel {
                HStack {
                    Label(L("运行与构建环境"),systemImage:"cpu").font(.headline)
                    Spacer()
                    Button(L("重新检查")) {store.savePreferences();store.checkEnvironment()}.disabled(store.checkingEnvironment || store.executionBusy).controlSize(.small)
                }
                EnvironmentSummary()
                CompactDisclosure(title:"环境详情与工具",subtitle:store.checks.isEmpty ? "Xcode · Metal · S2Arm" : "\(store.checks.filter{!$0.ok}.count) 项检查待处理",symbol:"wrench.and.screwdriver") {
                    ToolChecks()
                    Divider()
                    EngineSettingsView()
                }
            }
            GlassPanel {
                HStack(spacing:12) {
                    Label(L("控制与诊断"),systemImage:"gamecontroller").font(.headline)
                    Spacer()
                    Button(L("设置全局键鼠与手柄映射")) {store.inputGame=nil;store.editingInput=true}
                    Menu {
                        Button(L("重新打开首次运行向导"),action:store.openOnboarding)
                        Button(L("拉回 iPhone 诊断…"),action:store.pullDeviceDiagnostics)
                    } label:{Label(L("更多工具"),systemImage:"ellipsis.circle")}
                        .menuStyle(.borderlessButton).fixedSize()
                }
                Divider()
                HStack(spacing:12) {
                    Label(L("导出"),systemImage:"square.and.arrow.up.on.square").font(.headline)
                    Spacer()
                    Button(L("打开导出页")) {store.selection="platforms"}
                    Button(L("iPhone 装机步骤")) {store.showInstallGuide=true}
                }
            }
            GlassPanel {
                // 让 AI 帮你操作（11-02 维护者）：一键复制提示词，粘给任何 AI；开关留着给想关掉的人
                VStack(alignment:.leading,spacing:8) {
                    HStack(spacing:12) {
                        Label(L("让 AI 帮你操作"),systemImage:"sparkles").font(.headline)
                        Spacer()
                        Button { store.copyAIPrompt() } label: { Label(L("复制给 AI 的提示词"),systemImage:"doc.on.doc") }.platformButtonStyle(prominent:true)
                    }
                    Text(L("把提示词粘贴给你常用的 AI，它会按 S2Arm 内置的操作手册替你放密钥、放游戏、导出、装到 iPhone，出问题也会自己排查。你能在这个窗口里看到它的每一步。只在本机，别的设备连不进来。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Toggle(L("允许 AI 操作 S2Arm"),isOn:Binding(get:{store.aiControl},set:{store.aiControl=$0})).font(.caption)
                }
                Divider()
                CompactDisclosure(title:"关于S2Arm",subtitle:S2ArmRelease.settingsLabel,symbol:"info.circle") {
                    if !S2ArmRelease.buildID.isEmpty {LabeledContent(L("包号"),value:S2ArmRelease.buildID).textSelection(.enabled)}
                    Text(L("S2Arm 原生 Mac 启动器，界面同步自 LumaNX。与 Nintendo 无隶属或认可关系。")).font(.caption).foregroundStyle(.secondary)
                    Text(L("使用应用内置 S2Arm 引擎与工具。")).font(.caption).foregroundStyle(.secondary)
                    Button(L("开源许可与版权说明")){store.openDocumentation(.licenses)}
                }
            }
        }.disclosureGroupStyle(GlassDisclosureStyle()).navigationTitle(L("设置"))
    }
}

struct ToolChecks: View {
    @EnvironmentObject var store: Store
    @State private var showPassed=false
    private let groups=[("system","Mac 与图形"),("apple","Apple 工具链"),("engine","S2Arm 引擎"),("bundled","应用内置组件"),("storage","游戏库存储")]
    var body: some View {
        let passed=store.checks.filter(\.ok)
        VStack(alignment:.leading,spacing:12) {
            checkGroups(store.checks.filter{!$0.ok})
            if !passed.isEmpty {
                DisclosureGroup(isExpanded:$showPassed) {
                    VStack(alignment:.leading,spacing:12) {checkGroups(passed)}.padding(.top,8)
                } label: {
                    Label(L("已通过的检查（\(passed.count) 项）"),systemImage:"checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.teal)
                }
            }
        }.id(Localization.language)
            .onChange(of:store.checkingEnvironment) {_,checking in if checking {showPassed=false}}
    }
    @ViewBuilder private func checkGroups(_ checks:[ToolCheck])->some View {
        ForEach(groups,id:\.0) { group,title in
            let items=checks.filter {
                let key=$0.group ?? "system"
                return (groups.contains(where:{$0.0==key}) ? key : "system")==group
            }
            if !items.isEmpty {
                VStack(alignment:.leading,spacing:12) {
                    Text(L(title)).font(.headline)
                    ForEach(items) {check in EnvironmentCheckRow(check:check)}
                }
            }
        }
    }
}
struct EnvironmentCheckRow: View {
    @EnvironmentObject var store: Store
    let check: ToolCheck
    private var actionTitle:String {
        switch check.action {
        case "prepareEngine":return "准备引擎工具"
        case "reinstall":return "下载完整应用"
        case "systemUpdate":return "打开软件更新"
        case "library":return "选择游戏库"
        case "appStoreXcode":return "去 App Store 安装"
        case "openXcode":return "打开 Xcode"
        case "downloadMetal":return "一键下载"
        case "downloadIosPlatform":return "一键下载（约 8 GB）"
        case "recheck":return "重新检查"
        case "installDotnet":return "一键安装"
        default:return ""
        }
    }
    var body:some View {
        HStack(alignment:.top,spacing:10) {
            Image(systemName:check.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(check.ok ? .teal : .orange).padding(.top,2)
            VStack(alignment:.leading,spacing:5) {
                HStack {
                    Text(L(check.name)).fontWeight(.medium)
                    Spacer()
                    Text(L(check.required(for:"launch") ? "编译与启动都要" : check.required(for:"prepare") ? "编译时需要" : check.required(for:"ipa") ? "打 iPhone 包时需要" : "首次准备工具时需要")).font(.caption2).foregroundStyle(.secondary)
                }
                Text(L(check.message)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !check.ok, !actionTitle.isEmpty, let action=check.action {
                    Button(L(actionTitle)){store.repairEnvironment(action)}.buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(store.checkingEnvironment || store.executionBusy || action=="library" && !store.queue.isEmpty)
                }
                if let location=check.location {
                    DisclosureGroup(L("组件位置")) {
                        VStack(alignment:.leading,spacing:4) {
                            Text(L(check.group == "engine" ? "S2Arm 内置引擎的私有工具缓存。" : "随应用安装位置动态解析，以下是当前完整路径。")).font(.caption).foregroundStyle(.secondary)
                            Text(location).font(.caption.monospaced()).textSelection(.enabled)
                        }.padding(.top,4)
                    }.font(.caption)
                }
                if let help=check.help {
                    DisclosureGroup(L("安装与修复方法")) {
                        VStack(alignment:.leading,spacing:8) {
                            Text(L(help)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if let detail=check.detail,!detail.isEmpty {Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)}
                            if let command=check.repairCommand,!command.isEmpty {
                                Text(command).font(.caption.monospaced()).textSelection(.enabled)
                                Button(L("复制修复命令")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(command,forType:.string)
                                    store.notice="已复制修复命令，请在终端中手动执行。"
                                }
                            }
                        }.padding(.top,6)
                    }.font(.caption)
                }
            }
        }
    }
}
struct EnvironmentSummary: View {
    @EnvironmentObject var store:Store
    var body:some View {
        HStack {
            if store.checkingEnvironment {
                VStack(alignment:.leading,spacing:6) {
                    Text(L("正在逐项验证环境，请稍候…"))
                    if let task=store.tasks.first(where:{$0.operation=="preflight" && $0.active}) {TaskProgressView(task:task,compact:true)}
                    else {ProgressView().progressViewStyle(.linear)}
                }
            }
            else if store.environmentReady {Label(L("构建与启动环境均已就绪"),systemImage:"checkmark.shield.fill").foregroundStyle(.teal)}
            else if store.runtimeReady {Label(L("已编译的游戏可以启动，编译环境还需修复"),systemImage:"checkmark.circle").foregroundStyle(.secondary)}
            else {Label(L("完成环境检查后再导入游戏"),systemImage:"wrench.and.screwdriver").foregroundStyle(.secondary)}
        }.font(.callout)
    }
}
// 重新检查：跟在环境状态那一行的右边（维护者 10-23：换个好看的位置；Xcode 自动找、不再有「选择 Xcode」与「环境与数据说明」）
struct RecheckButton: View {
    @EnvironmentObject var store:Store
    var body:some View {
        Button {store.savePreferences();store.checkEnvironment()} label:{Label(L("重新检查"),systemImage:"arrow.clockwise")}
            .buttonStyle(.bordered).controlSize(.small).disabled(store.checkingEnvironment || store.executionBusy)
    }
}
// 引导页底部环境行：全过只一行；不过时展开不过的项（含修复办法）与操作按钮
struct OnboardingEnvironmentLine: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if store.checkingEnvironment { EnvironmentSummary() }
            else if store.environmentReady {
                Label(L("本机环境就绪：游戏引擎、Python、.NET 均随应用内置，无需另装。"),systemImage:"checkmark.shield.fill").font(.callout).foregroundStyle(.teal)
            } else {
                HStack { Label(L("本机环境还差以下几项："),systemImage:"exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange); Spacer(); RecheckButton() }
                ScrollView { VStack(alignment:.leading,spacing:10) { ForEach(store.checks.filter{!$0.ok && $0.required(for:"prepare")}) { EnvironmentCheckRow(check:$0) } } }.frame(maxHeight:180)
                if let task=store.tasks.first(where:{$0.operation=="downloadMetal" && $0.active}) {TaskProgressView(task:task,compact:true)}
            }
        }
    }
}
struct DropCard: View {
    let number: Int; let title: String; let hint: String; let done: Bool; let enabled: Bool
    @Binding var targeted: Bool
    let busy: Bool; let onClick: () -> Void; let onDrop: ([URL]) -> Void
    var body: some View {
        Button(action:onClick) {
            VStack(alignment:.leading,spacing:8) {
                HStack {
                    Image(systemName:done ? "checkmark.circle.fill" : "\(number).circle").font(.title).foregroundStyle(done ? Color.teal : (enabled ? Color.primary : Color.secondary))
                    Text(title).font(.title3.bold()).foregroundStyle(enabled || done ? Color.primary : Color.secondary)
                    Spacer(); if busy {ProgressView().controlSize(.small)}
                }
                Text(hint).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth:.infinity,alignment:.leading)
                Spacer(minLength:0)
                HStack { Spacer(); Image(systemName:"square.and.arrow.down").font(.system(size:30)).foregroundStyle(enabled ? Color.teal : Color.secondary.opacity(0.5)); Spacer() }
            }
            .padding(WorkspaceLayout.cardInset).frame(maxWidth:.infinity,minHeight:180,maxHeight:180,alignment:.topLeading)
            .background(targeted && enabled ? Color.teal.opacity(0.14) : Color.secondary.opacity(0.07),in:RoundedRectangle(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(style:StrokeStyle(lineWidth:2,dash:[7,5])).foregroundStyle(targeted && enabled ? Color.teal : Color.secondary.opacity(0.35)))
            .contentShape(RoundedRectangle(cornerRadius:16))
        }.buttonStyle(.plain).disabled(!enabled)
        .dropDestination(for:URL.self) { urls,_ in guard enabled, !urls.isEmpty else { return false }; onDrop(urls); return true } isTargeted:{ targeted = $0 }
    }
}
struct EnvironmentSetupView: View {
    @EnvironmentObject var store:Store
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text(L("S2Arm、Python、.NET 和共享字体随应用内置。编译还需要 Xcode 与 Metal 编译组件，缺了在检测项旁一键处理；玩家只需放入密钥和游戏。"))
            EngineSettingsView()
            EnvironmentSummary()
            RecheckButton()
            ToolChecks()
        }
    }
}
struct EngineSettingsView: View {
    @EnvironmentObject var store:Store
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text(L("S2Arm 引擎与工具")).font(.headline)
            Text(L("S2Arm 引擎随应用内置，包含 Mac 宿主、NSP/XCI 读取器和游戏编译工具。玩家数据与构建缓存独立保存。")).font(.caption).foregroundStyle(.secondary)
            LabeledContent(L("引擎来源"),value:store.engineBundle == nil ? L("开发目录（编译后内置）") : L("应用内置"))
            if store.engineBundle == nil {Button(L("准备开发工具"),action:store.prepareEngine).disabled(!store.canManageToolchain)}
            LabeledContent(L("Python 与依赖"),value:L("应用内置，无需单独安装"))
            LabeledContent(L("Xcode（编译时需要，自动找到）"),value:store.preferences.developerDir.isEmpty ? L("没找到：装 Xcode 后重开本应用") : store.preferences.developerDir).textSelection(.enabled)
            LabeledContent(L("共享字体"),value:store.preferences.fontsDir ?? L("应用自带（开源字体）"))
            HStack { Button(L("换成原版字体…"),action:store.chooseFontsDir); if store.preferences.fontsDir != nil {Button(L("改回应用自带")){store.setFontsDir(nil)}} }
            Toggle(L("S2Arm 诊断浮层"),isOn:Binding(get:{store.preferences.devHud ?? false},set:{store.preferences.devHud=$0;store.savePreferences()}))
            Text(L("显示目标帧率、慢帧比例、图形路径、首遇编译、音频和包号。下次启动游戏时生效。")).font(.caption).foregroundStyle(.secondary)
            Toggle(L("Metal HUD"),isOn:Binding(get:{store.preferences.metalHud ?? false},set:{store.preferences.metalHud=$0;store.savePreferences()}))
            Text(L("显示帧率、GPU 时间和帧间隔曲线，仅供手动观察；开启时截图、存帧、自动玩家和满屏判据不可用。下次启动游戏时生效。")).font(.caption).foregroundStyle(.secondary)
            if let task=store.tasks.first(where:{$0.id==store.executionTask && $0.operation=="prepareEngine"}) {TaskProgressView(task:task)}
        }.textFieldStyle(.roundedBorder).controlSize(.small)
    }
}
struct OnboardingView: View {
    // 首次打开一页完成（维护者 10-23：减少交互）：玩家只做非他不可的两件事——给密钥、给游戏；游戏库用缺省位置，环境全过就只占一行
    @EnvironmentObject var store: Store
    @State private var keysTargeted = false
    @State private var gamesTargeted = false
    private var gamesEnabled: Bool { store.hasImportedKeys && !store.importingKeys && store.environmentReady }
    private var importingGames: Bool { store.tasks.contains { $0.operation == "import" && $0.active } }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:12) {
                BrandMark(size:48)
                VStack(alignment:.leading,spacing:5) {
                    Text(L("欢迎使用S2Arm")).font(.title2.bold())
                    Text(L("放入你的密钥和游戏，就可以开始。")).foregroundStyle(.secondary)
                }
                Spacer()
                LanguageSwitch()
            }
            HStack(alignment:.top,spacing:12) {
                DropCard(number:1,title:L("放入 prod.keys"),
                         hint:store.hasImportedKeys ? L("已放入，只保存在本机。") : L("把你的 prod.keys 拖到这里，或点击选择文件。只保存在本机，不上传。"),
                         done:store.hasImportedKeys,enabled:!store.importingKeys,targeted:$keysTargeted,
                         busy:store.importingKeys) { store.importKeys() } onDrop:{ urls in if let u = urls.first { store.importKeys(from:u) } }
                DropCard(number:2,title:L("放入游戏"),
                         hint:!store.hasImportedKeys ? L("先放入密钥。") : !store.environmentReady ? L("本机环境还没就绪，见下方。")
                            : store.games.isEmpty ? L("把游戏文件夹，或本体 / 更新 / DLC 的 NSP、XCI 拖到这里，或点击选择。")
                            : L("已放入：") + store.games.map(\.name).joined(separator:"、") + L("。可继续放入，好了点右下角「开始编译」。"),
                         done:!store.games.isEmpty,enabled:gamesEnabled,targeted:$gamesTargeted,busy:importingGames) {
                    store.chooseGamesFromOnboarding()
                } onDrop:{ urls in store.addGamesFromOnboarding(urls) }
            }
            // 导入密钥 / 游戏时显示进度（10-23 本机走查：9 GB 游戏读几十秒，原来只有卡片角落一个小转圈）
            if let task=store.tasks.first(where:{($0.operation=="keys" || $0.operation=="import") && $0.active}) {TaskProgressView(task:task,compact:true)}
            OnboardingEnvironmentLine()
            Spacer()
            // 底部（维护者 10-23）：左「稍后再说」，右主按钮「开始编译」= 把放进来的游戏全部开始准备并转到任务页
            HStack {
                Button(store.preferences.onboardingComplete ? L("关闭") : L("稍后再说"),action:store.deferOnboarding).keyboardShortcut(.cancelAction)
                Button { store.copyAIPrompt() } label: { Label(L("复制给 AI 的提示词"),systemImage:"sparkles") }   // 让 AI 从这里接手（11-02 维护者）
                    .help(L("把提示词粘贴给你常用的 AI，它会替你做完后面的步骤，你在这个窗口里看着就行。"))
                Spacer()
                // 不能点时也看得清（白底上灰掉的主按钮几乎看不见，10-23 本机真窗口走查），旁边一句话说还差什么
                let canPack = store.canStartPacking && !importingGames
                if !canPack {
                    Text(!store.hasImportedKeys ? L("先放入密钥") : !store.environmentReady ? L("本机环境还没就绪") : importingGames ? L("正在读取游戏…") : L("再放入游戏"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if canPack {
                    Button {store.startPackingFromOnboarding()} label:{Label(L("开始编译"),systemImage:"shippingbox").padding(.horizontal,8)}
                        .buttonStyle(.borderedProminent).controlSize(.small).keyboardShortcut(.defaultAction)
                } else {
                    Label(L("开始编译"),systemImage:"shippingbox").font(.body.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal,16).padding(.vertical,7).background(Color.secondary.opacity(0.14),in:Capsule())
                }
            }
        }.padding(WorkspaceLayout.pageInset).frame(width:820,height:560).background(LibraryBackdrop())
        .onAppear {store.checkEnvironmentAtStartup()}
        .alert(L("操作未完成"),isPresented:Binding(get:{store.error != nil},set:{if !$0 {store.error=nil}})) {
            let diagnostic=store.errorDiagnostic
            Button(L("知道了"),role:.cancel) {store.error=nil}
            if let diagnostic {
                Button(L("查看失败任务")) {store.showFailedTask()}
                Button(L("复制错误摘要")) {store.copyDiagnostic(diagnostic)}
            } else {Button(L("打开日志")) {store.reveal(store.diagnosticLogURL(nil))}}
        } message:{Text(store.failureMessage)}
    }
}

// 引导页右上角：界面语言缺省跟随系统，这里一键切到另一种语言（维护者 10-23：不让玩家先选）
struct LanguageSwitch: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let other: AppLanguage = Localization.language == "zh-Hans" ? .english : .simplifiedChinese
        Button {store.language = other} label:{Label(other.name,systemImage:"globe")}.buttonStyle(.bordered).controlSize(.small)
    }
}
struct LanguagePicker: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Picker(L("语言"),selection:Binding(get:{store.language},set:{store.language=$0})) {
            ForEach(AppLanguage.allCases) { language in Text(language.name).tag(language) }
        }.pickerStyle(.segmented).id("app-language-"+Localization.language)
    }
}

struct AppearancePicker: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Picker(L("外观"),selection:Binding(get:{store.appearance},set:{store.appearance=$0})) {
            ForEach(AppAppearance.allCases) { appearance in Text(appearance.name).tag(appearance) }
        }.pickerStyle(.segmented).id("app-appearance-"+Localization.language)
    }
}

// 跨平台编译 iOS 页的目标设备（机型 · 系统）。连着设备时自动认出，不用选；没连时从菜单选机型和系统版本，记住上次的选择
struct IPhoneTargetRow: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let probe = store.targetProbe, current = store.iphoneTarget
        VStack(alignment:.leading,spacing:4) {
        HStack(spacing:6) {
            Image(systemName:current?.connected == true ? "cable.connector" : "iphone").foregroundStyle(.secondary)
            Text(current.map { L("目标设备：") + $0.label + ($0.connected ? L("（已连接）") : "") } ?? L("没连设备：出包不需要；装到 iPhone 时再用数据线连上")).font(.caption).foregroundStyle(current == nil ? .secondary : .secondary).lineLimit(2)
            Spacer(minLength:4)
            Menu(L(current == nil ? "选机型" : "更换")) {
                if probe.connected.count > 1 {
                    Section(L("已连接")) { ForEach(probe.connected.filter{!$0.gpuArch.isEmpty},id:\.self) { t in Button(t.label) { store.chooseTarget(t) } } }
                }
                ForEach(probe.osChoices,id:\.self) { os in
                    Menu("iOS \(os)") { ForEach(probe.models,id:\.self) { m in Button(m.model) { var t=m; t.os=os; store.chooseTarget(t) } } }
                }
                Divider()
                Button(L("重新检测连接的设备")) { store.probeTarget() }
            }.menuStyle(.borderlessButton).fixedSize().font(.caption).disabled(probe.models.isEmpty)
        }
        }
        .help(L("包与机型无关：iOS 18 以上的 iPhone / iPad 都能装，第一次进游戏在设备上编一遍着色器。这里的设备只用来提示内存窗口。"))
        .task { store.probeTarget() }
    }
}

// 等 macOS 文件夹授权框的常驻条（审计 18:00 P1-2）：转圈表示还在等，不用完成图标、没有关闭钮（关掉也不会让系统框消失）
struct AccessWaitBanner: View {
    let text: String
    var body: some View {
        HStack(spacing:10) { ProgressView().controlSize(.small); Text(text) }
            .padding().glassSurface().padding()
            .accessibilityElement(children:.combine)
    }
}
