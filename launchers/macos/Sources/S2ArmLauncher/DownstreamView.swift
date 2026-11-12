import SwiftUI

// 下游深度方案（pack/downstream/schemes.json、pack/jobs/downstream.py）：这款有下游项目做的专门移植时，导出前问一次玩家用哪套方案。
//   文案来自登记表（只写玩家据此选择的事实），游戏名用玩家自己游戏包里的名字。选「仍用原版方案」照原版出，不拦；
//   只有物理上做不出来（下游只支持某一版更新）时推荐按钮置灰，旁边写原因和办法。选择记在这款文件夹（downstreamChoice），之后不再问，导出页那一行可改。
extension Store {
    /// 这一单带不带下游方案：玩家选了下游且条件满足 → 方案 id；选了原版、没选过、没命中 → nil
    func downstreamScheme(_ game: Game) -> String? {
        guard let d = game.downstream, d.eligible, let c = d.choice, !c.isEmpty else { return nil }
        return c
    }
    /// 导出页「开始导出」：命中方案、没选过、又勾了 iPhone → 先弹确认页；否则照常导出
    func exportChecked(_ game: Game) {
        if let d = game.downstream, d.choice == nil, exportPicked.contains(.ios) { downstreamPrompt = game; return }
        exportTargets(game)
    }
    /// 记下选择（scheme = 方案 id；"" = 仍用原版），读库后接着导出
    func chooseDownstream(_ game: Game, scheme: String, thenExport: Bool) {
        downstreamPrompt = nil
        worker("downstreamChoice",extra:["gameId":game.id,"scheme":scheme],visible:false) { _ in
            self.refresh { if thenExport, let g = self.games.first(where:{ $0.id == game.id }) { self.exportTargets(g) } }
        }
    }
}

struct DownstreamConfirmView: View {
    @EnvironmentObject var store: Store
    let game: Game
    let d: Downstream
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            if let t = d.text {
                Text(game.name + " · " + t.title).font(.title3.weight(.semibold)).fixedSize(horizontal:false,vertical:true)
                Text(t.body).fixedSize(horizontal:false,vertical:true)
                VStack(alignment:.leading,spacing:6) {
                    ForEach(t.points, id:\.self) { Label($0,systemImage:"checkmark.circle").font(.callout).fixedSize(horizontal:false,vertical:true) }
                }
                if !d.eligible { Label(d.why,systemImage:"info.circle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                HStack {
                    Spacer()
                    Button(t.original) { store.chooseDownstream(game,scheme:"",thenExport:true) }
                    Button(t.recommend) { store.chooseDownstream(game,scheme:d.id,thenExport:true) }
                        .platformButtonStyle(prominent:true).disabled(!d.eligible).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width:540)
    }
}

/// 导出页游戏卡下面一行：这款用哪套方案，可改（改了只记下，不导出）
struct DownstreamRow: View {
    @EnvironmentObject var store: Store
    let game: Game
    let d: Downstream
    var body: some View {
        HStack(spacing:10) {
            Image(systemName:"sparkles")
            Text(L("深度优化方案") + "：" + (store.downstreamScheme(game) != nil ? d.name : d.choice == nil ? (d.text?.title ?? d.name) : (d.text?.original ?? ""))).font(.callout)
            Spacer()
            Button(L("更改")) { store.downstreamPrompt = game }
        }.padding(WorkspaceLayout.cardInset).glassSurface(WorkspaceLayout.cardRadius)
    }
}
