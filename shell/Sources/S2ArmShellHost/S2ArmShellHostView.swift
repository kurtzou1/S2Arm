import SwiftUI
import ShellUI
import S2ArmShellBridge

/// 库界面 = 上游 LibraryView 挂在我方模型上；出现时开手柄监听、消失时关（Play 后游戏接管输入，两边不同时听）。
public struct S2ArmShellHostView: View {
    let model: S2ArmShellHostModel
    public init(model: S2ArmShellHostModel) { self.model = model }
    public var body: some View {
        library
            #if os(tvOS)
            .disabled(model.playersOpen)   // 玩家页开着时焦点不落到背后的库界面上
            #endif
            // 本地玩家（#623）：顶部玩家按钮显示这次用谁的身份玩，点开切换页
            .environment(\.shellPlayer, ShellPlayer(name: model.currentPlayer.displayName, open: { model.openPlayers() }))
            .overlay {
                if model.playersOpen {
                    S2ArmPlayersView(players: model.players, current: model.currentPlayer.uid,
                                     select: { model.selectPlayer($0) }, add: { model.addPlayer($0) },
                                     rename: { model.renamePlayer($0, $1) }, remove: { model.removePlayer($0) },
                                     close: { model.closePlayers() })
                    #if os(tvOS)
                        .onExitCommand { model.closePlayers() }   // 遥控器「返回」/ 手柄 B 关玩家页，不退到主屏
                    #endif
                }
            }
            .onAppear {
                model.startControllers(); s2a_shell_library_appeared(); model.rescanCatalogue()   // 游戏库页出现：重读清单（电脑端推进来的新款，0.6.0）
                // 主屏快捷操作「设置」冷启动：库界面出现后打开游戏库设置（LibraryView 已经订阅，下一拍再发）
                if s2a_shell_take_open_settings() != 0 { DispatchQueue.main.async { NotificationCenter.default.post(name: .shellOpenSettings, object: nil) } }
            }
            .onDisappear { model.stopControllers() }
            // 库顶上的提示：这次安装丢了「提高内存上限」权限（可关，只管这次打开；「了解详情」看各装法怎么带上）；删除游戏的进度与结果（点一下收起结果）
            .overlay(alignment: .top) {
                VStack(spacing: 10) {
                    if let iml = model.imlNotice, !model.guideOpen, !model.featureOpen {   // 首次引导 / 新功能介绍开着时先不出（盖在上面、点不到关闭），关了再出
                        IMLNoticeBar(notice: iml, close: { model.closeIMLNotice() }, more: { model.openIMLGuide() })
                            .onAppear { s2a_shell_iml_notice_seen() }   // 真显示出来才记（起局那条不再重复）
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let notice = model.deleteNotice {
                        DeleteNoticeBar(notice: notice).onTapGesture { model.dismissDeleteNotice() }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.top, 56).padding(.horizontal, 16)   // 让开游戏库顶栏（LibraryView：安全区下 6 pt + 高 44 pt），不挡玩家 / 手柄 / 设置按钮
            }
            .animation(.smooth(duration: 0.25), value: model.deleteNotice)
            .animation(.smooth(duration: 0.25), value: model.imlNotice)
            .sheet(isPresented: Binding(get: { model.imlGuideOpen }, set: { model.imlGuideOpen = $0 })) { IMLGuideView() }
            .sheet(isPresented: Binding(get: { model.storageOpen }, set: { model.storageOpen = $0 })) {
                S2ArmStorageView(names: model.storageNames, root: S2ArmStorage.liveRoot)
            }
            // 首次进入引导（三页横滑：设置 / 金手指 / 故障报修），盖在最上面；看过一次就不再弹
            .overlay {
                if model.guideOpen {
                    S2ArmGuideView(page: Binding(get: { model.guidePage }, set: { model.guidePage = $0 }), close: { model.closeGuide() })
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: model.guideOpen)
        #if !os(tvOS)
            // 这一版的新功能介绍（iPhone 两页）：排在首次引导之后，同样盖在最上面、手柄能翻页能关；设置里「再看一遍」再开
            .overlay {
                if model.featureOpen, let intro = model.featureIntroContent {
                    FeatureIntroView(intro: intro, index: Binding(get: { model.featurePage }, set: { model.featurePage = $0 }), close: { model.closeFeature() })
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: model.featureOpen)
            .onReceive(NotificationCenter.default.publisher(for: .shellOpenFeatureIntro)) { _ in model.openFeature() }
        #endif
        #if canImport(UIKit) && !os(tvOS)
            // 回前台重判资源包：玩家去「文件」/ 访达拷完资源包回来，不用重开 App
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.rescanCatalogue() }
            // 虚拟手柄布局编辑页（设置里「按键布局 → 调整位置…」）：盖在库界面上，关了回到设置
            .overlay {
                if let id = model.editingLayout {
                    S2ArmTouchEditorView(gameID: id, banner: model.bannerURLs[id],
                                         opacity: (UserDefaults.standard.object(forKey: "S2AVPadOpacity") as? Double).map { min(1, max(0.1, $0)) } ?? 1,
                                         close: { model.closeLayoutEditor() })
                }
                if let id = model.editingIdentity {
                    S2ArmGameIdentityView(title: model.identityName(id), initialName: model.identityName(id), hasCustom: model.hasCustomIdentity(id), error: model.identityError,
                                          save: { model.saveIdentity(id, name: $0, cover: $1) }, reset: { model.resetIdentity(id) }, close: { model.closeIdentityEditor(id) })
                }
            }
        #elseif os(tvOS)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.rescanCatalogue() }
        #endif
    }

    /// iOS：触屏 + 自绘手柄焦点的库界面；tvOS：遥控器 / 手柄走系统焦点的电视库界面（TVLibraryView）。两边同一个模型、同一套 actions
    @ViewBuilder private var library: some View {
        #if os(tvOS)
        TVLibraryView(games: model.games, controllers: model.controllers, actions: model.actions, input: model.input)
        #else
        LibraryView(games: model.games, controllers: model.controllers, actions: model.actions, input: model.input,
                    padSnapshot: model.padSnapshot)
        #endif
    }
}

/// 丢了「提高内存上限」权限的提示：黄色警示、发生了什么（标题）+ 后果与怎么办（正文），右上角关闭；不挡库里的操作
struct IMLNoticeBar: View {
    let notice: S2ArmShellHostModel.IMLNotice
    let close: () -> Void
    var more: (() -> Void)? = nil   // 「了解详情」：给了才出这个按钮
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "memorychip").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color(red: 1, green: 0.78, blue: 0.28))
                .padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                Text(notice.body).font(.system(size: 13)).foregroundStyle(.white.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
                if let more {
                    Button(action: more) {
                        Text(shellText("Learn more")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(red: 1, green: 0.78, blue: 0.28))
                            .padding(.top, 2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("iml.notice.more")
                }
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.7)).frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(shellText("Close")).accessibilityIdentifier("iml.notice.close")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color(red: 0.075, green: 0.075, blue: 0.082).opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(red: 1, green: 0.78, blue: 0.28).opacity(0.45)))
        .shadow(color: .black.opacity(0.45), radius: 20)
        .frame(maxWidth: 620)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("iml.notice")
    }
}

/// 删除提示条：正在删除带转圈，已删除带对勾和释放的空间，失败带原因（红）
struct DeleteNoticeBar: View {
    let notice: S2ArmShellHostModel.DeleteNotice
    var body: some View {
        HStack(spacing: 10) {
            switch notice.phase {
            case .deleting: ProgressView().tint(.white)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(red: 1, green: 0.42, blue: 0.40))
            }
            Text(Self.text(notice)).font(.system(size: 15 * ShellFonts.tvScale, weight: .semibold)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Color(red: 0.075, green: 0.075, blue: 0.082).opacity(0.96), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.45), radius: 20)
        .frame(maxWidth: 560 * ShellFonts.tvScale)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("delete.notice")
    }
    static func text(_ n: S2ArmShellHostModel.DeleteNotice) -> String {
        switch n.phase {
        case .deleting: shellText("Deleting “\(n.title)”…")
        case .done(let freed): shellText("Deleted “\(n.title)”. \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) freed.")
        case .failed(let why): shellText("Couldn’t delete “\(n.title)”: \(why)")
        }
    }
}

#if canImport(UIKit)
import UIKit

@MainActor private var g_refreshModel: S2ArmShellHostModel?   // 刷新回调指向的模型（见 s2a_shell_library_vc）

/// 游戏库页的根控制器：关掉 iPhone Duo 的竖栏。系统缺省给竖向状态栏留一整列（iOS 27.1 preferredVerticalBarBehavior = automatic，
/// 外屏竖着安全区右 84 / 下 34），库页右侧和底部就空成黑边；关掉后状态栏回到顶部横放，整屏归库页。没有竖栏的机型系统不问这个属性
final class LibraryHostingController<Content: View>: UIHostingController<Content> {
    #if os(iOS)
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }   // 跟随系统：四个方向都给（UIHostingController 在 iPhone 上缺省「除倒置外」），没有倒置方向的机型系统自己不转
    #endif
    // 按 SDK 判、不按编译器判：Xcode 27.0 与 27.1 都是 Swift 6.4，但只有 27.1 的 iOS SDK 有 UIVerticalBarBehavior（UIKit 9127.0.85 起）——
    //   原先 compiler(>=6.4) 在 27.0 上也成立，门禁机每个 Xcode 各编一遍时 27.0 报找不到类型（同 ios/play_layout.h 按 __IPHONE_27_1 判）
    //   Intel 出壳走 swift build --sdk，UIKit 没有 user version number（Swift 警告 #ModuleVersionMissing），
    //     canImport(..., _underlyingVersion:) 里的版本会被忽略、在 26.5 SDK 上误成立；那条路径打 -DS2A_UIKIT_VERSION_UNKNOWN 关掉这段覆盖。
    #if os(iOS) && canImport(UIKit, _underlyingVersion: 9127.0.85) && !S2A_UIKIT_VERSION_UNKNOWN
    @available(iOS 27.1, *)
    override var preferredVerticalBarBehavior: UIVerticalBarBehavior { .disabled }
    #endif
}

/// app.m 用的 C 入口（声明在 S2ArmShellBridge/include/s2a_shell.h）：返回 +1 的 UIHostingController。
/// 只在主线程调（头文件约定）；@MainActor 让 Swift 侧按主线程隔离编译。
@MainActor @_cdecl("s2a_shell_library_vc")
public func s2a_shell_library_vc(_ cataloguePath: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer {
    let path = cataloguePath.map { String(cString: $0) } ?? ""
    let model = S2ArmShellHostModel(catalogue: Catalogue.load(path: path), reloadCatalogue: { Catalogue.load(path: path) })
    // 宿主「重新检查」/ 后台解包完成 → 重判资源包。登记给 C 的是不持有的指针，所以由 g_refreshModel 强持有当前这份模型：
    //   原先假定「vc 由 app.m 持有到进程结束」，可开游戏时 window.rootViewController 换成游戏页，库的 vc 与模型随之释放，
    //   游戏里后台解包完成再回调就是用已释放的模型（11-14 诊断#7f30f6：refreshGameData+0x9c 读 0x10）。再建库页时换成新的那份，只留一个
    g_refreshModel = model
    s2a_shell_set_refresh_handler({ ctx in
        guard let ctx else { return }
        MainActor.assumeIsolated { Unmanaged<S2ArmShellHostModel>.fromOpaque(ctx).takeUnretainedValue().rescanCatalogue() }   // 重读清单再重判：导入文件夹里新导入的 .s2arm（App 开着 / 冷启动 / 在「文件」里点开）马上列出，不用切后台再回来（0.6.0 自签走查 B1 / B5）
    }, Unmanaged.passUnretained(model).toOpaque())
    let vc = LibraryHostingController(rootView: S2ArmShellHostView(model: model))
    return Unmanaged.passRetained(vc as UIViewController).toOpaque()
}
#endif
