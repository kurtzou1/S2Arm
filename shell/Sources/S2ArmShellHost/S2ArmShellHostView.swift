import SwiftUI
import ShellUI
import S2ArmShellBridge

/// 库界面 = 上游 LibraryView 挂在我方模型上；出现时开手柄监听、消失时关（Play 后游戏接管输入，两边不同时听）。
public struct S2ArmShellHostView: View {
    let model: S2ArmShellHostModel
    public init(model: S2ArmShellHostModel) { self.model = model }
    public var body: some View {
        LibraryView(games: model.games, controllers: model.controllers, actions: model.actions, input: model.input,
                    padSnapshot: model.padSnapshot)
            // 本地玩家（#623）：顶部玩家按钮显示这次用谁的身份玩，点开切换页
            .environment(\.shellPlayer, ShellPlayer(name: model.currentPlayer.displayName, open: { model.openPlayers() }))
            .overlay {
                if model.playersOpen {
                    S2ArmPlayersView(players: model.players, current: model.currentPlayer.uid,
                                     select: { model.selectPlayer($0) }, add: { model.addPlayer($0) },
                                     rename: { model.renamePlayer($0, $1) }, remove: { model.removePlayer($0) },
                                     close: { model.closePlayers() })
                }
            }
            .onAppear {
                model.startControllers(); s2a_shell_library_appeared()
                // 主屏快捷操作「设置」冷启动：库界面出现后打开游戏库设置（LibraryView 已经订阅，下一拍再发）
                if s2a_shell_take_open_settings() != 0 { DispatchQueue.main.async { NotificationCenter.default.post(name: .shellOpenSettings, object: nil) } }
            }
            .onDisappear { model.stopControllers() }
            // 删除游戏的进度与结果（正在删除 → 已删除，释放多少 / 失败原因）：库顶上一条，点一下收起结果
            .overlay(alignment: .top) {
                if let notice = model.deleteNotice {
                    DeleteNoticeBar(notice: notice).onTapGesture { model.dismissDeleteNotice() }
                        .padding(.top, 12).padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.25), value: model.deleteNotice)
            // 首次进入引导（三页横滑：设置 / 金手指 / 故障报修），盖在最上面；看过一次就不再弹
            .overlay {
                if model.guideOpen {
                    S2ArmGuideView(page: Binding(get: { model.guidePage }, set: { model.guidePage = $0 }), close: { model.closeGuide() })
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: model.guideOpen)
        #if canImport(UIKit)
            // 回前台重判资源包：玩家去「文件」/ 访达拷完资源包回来，不用重开 App
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.refreshGameData() }
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
        #endif
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
            Text(Self.text(notice)).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Color(red: 0.075, green: 0.075, blue: 0.082).opacity(0.96), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.45), radius: 20)
        .frame(maxWidth: 560)
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

/// app.m 用的 C 入口（声明在 S2ArmShellBridge/include/s2a_shell.h）：返回 +1 的 UIHostingController。
/// 只在主线程调（头文件约定）；@MainActor 让 Swift 侧按主线程隔离编译。
@MainActor @_cdecl("s2a_shell_library_vc")
public func s2a_shell_library_vc(_ cataloguePath: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer {
    let path = cataloguePath.map { String(cString: $0) } ?? ""
    let model = S2ArmShellHostModel(catalogue: Catalogue.load(path: path))
    // 宿主「重新检查」/ 后台解包完成 → 重判资源包。登记给 C 的是不持有的指针，所以由 g_refreshModel 强持有当前这份模型：
    //   原先假定「vc 由 app.m 持有到进程结束」，可开游戏时 window.rootViewController 换成游戏页，库的 vc 与模型随之释放，
    //   游戏里后台解包完成再回调就是用已释放的模型（11-14 诊断#7f30f6：refreshGameData+0x9c 读 0x10）。再建库页时换成新的那份，只留一个
    g_refreshModel = model
    s2a_shell_set_refresh_handler({ ctx in
        guard let ctx else { return }
        MainActor.assumeIsolated { Unmanaged<S2ArmShellHostModel>.fromOpaque(ctx).takeUnretainedValue().refreshGameData() }
    }, Unmanaged.passUnretained(model).toOpaque())
    let vc = UIHostingController(rootView: S2ArmShellHostView(model: model))
    return Unmanaged.passRetained(vc as UIViewController).toOpaque()
}
#endif
