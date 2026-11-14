// S2Arm（不是上游文件）：出包页「S 级优化（Beta）」（11-13 维护者：根据游戏和版本自动匹配社区补丁并展示；命中的默认打上，用户少做选择、不阻断）。
//   数据：作业层 patchMatch（pack/jobs/patches.py match）——这个版本命中的各类条数、只命中游戏的其他版本各支持什么。
//   命中的出包时自动打入（满屏 / 帧率默认开，画面类只进 Mac 包，金手指打入但默认关）；版本不对的只告知、不给勾选（核不上原字节、写不进去）。
//   没解过包的款不知道实际版本：先说「出包时自动匹配」，完成页（boost）列实际打进去的
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct PatchMatch: Equatable {
    var build = ""
    var version = ""   // 玩家这份游戏的显示版本号（解过包才有；patches.match）
    var exact: [String: Int] = [:]
    var port = false                // 满屏跨版本：这份没有同版本的满屏补丁，出包时尝试把别的版本的移植过来（patches.match）
    var portVersions: [String] = []
    var others: [(version: String, cats: [String])] = []
    static func == (a: PatchMatch, b: PatchMatch) -> Bool { a.build == b.build && a.exact == b.exact && a.port == b.port && a.others.map(\.version) == b.others.map(\.version) }
    init() {}
    init(_ raw: [String: Any]) {
        build = raw["build"] as? String ?? ""
        version = raw["version"] as? String ?? ""
        port = raw["port"] as? Bool ?? false
        portVersions = raw["portVersions"] as? [String] ?? []
        exact = (raw["exact"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Int }
        others = (raw["others"] as? [[String: Any]] ?? []).compactMap { o in (o["version"] as? String).map { ($0, o["cats"] as? [String] ?? []) } }
    }
    var total: Int { exact.values.reduce(0, +) }
}

struct SGradeCard: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    let gameID: String
    /// 作业层答「这个版本没命中、别的版本也没有」：上层整张不出
    var nothing: () -> Void = {}
    @State private var match: PatchMatch?
    @State private var failed = false

    var body: some View {
        SGradeCardView(match: match, failed: failed, zh: loc.lang == .zh, on: Binding(get: { model.sgradeOn(gameID) }, set: { model.setSgrade(gameID, $0) })) {
            BackendText.launcherText("export.sgrade." + $0, language: loc.lang == .zh ? "zh-Hans" : "en") }
            .task(id: gameID) {
                match = nil; failed = false
                if let r = try? await model.saveJob("patchMatch", gameID: gameID) { let m = PatchMatch(r); match = m; if m.total == 0, !m.port, m.others.isEmpty, !m.build.isEmpty { nothing() } } else { failed = true }
            }
    }
}

/// 卡片本身（只看数据，离屏渲染单测 SGradeCardTests 直接喂 PatchMatch 出图）
struct SGradeCardView: View {
    let match: PatchMatch?
    let failed: Bool
    let zh: Bool
    /// 「出包时打入」勾选（v0.4.0 维护者：作为 Beta 功能出包页默认勾上，玩家可取消；取消 = 这次出包不带社区补丁与金手指）；nil = 不出勾选（单测旧图）
    var on: Binding<Bool>? = nil
    /// export.sgrade.<键> → 当前语言的文字
    let x: (String) -> String
    /// 金色 S（缺省读 App 资源 s-gold.png；单测传仓库里的原图）
    var sImage: NSImage = SGradeCardView.sGold
    private func catName(_ c: String) -> String { x("cat." + c) }

    // 金色（11-13 维护者：这个功能很牛，做得精致高级、显眼一点，用金色版 logo 的 S）：高光 / 主金 / 古铜三档，命中时整张卡亮起来
    //   配色跟金色 S 同一套双色：上半香槟金、下半玫瑰金（launchers/macos/Branding/make_s_gold.py），标题 / 描边 / 图标钮都从香槟金过渡到玫瑰金
    static let goldHi = Color(red: 1, green: 0.92, blue: 0.70), gold = Color(red: 0.93, green: 0.77, blue: 0.42), rose = Color(red: 0.93, green: 0.62, blue: 0.52), goldDeep = Color(red: 0.55, green: 0.36, blue: 0.24)
    static let sGold: NSImage = Bundle.main.url(forResource: "s-gold", withExtension: "png").flatMap(NSImage.init(contentsOf:)) ?? NSImage()
    private var lit: Bool { ((match?.total ?? 0) > 0 || match?.port == true) && on?.wrappedValue != false }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(nsImage: sImage).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: lit ? 56 : 44, height: lit ? 56 : 44)
                .shadow(color: Self.gold.opacity(lit ? 0.55 : 0.18), radius: lit ? 16 : 6)
                .saturation(match == nil || lit ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(x("title")).font(.manrope(18, .bold))
                        .foregroundStyle(LinearGradient(colors: [Self.goldHi, Self.gold, Self.rose], startPoint: .leading, endPoint: .trailing))
                    Text("BETA").font(.manrope(9.5, .bold)).tracking(1.4).padding(.horizontal, 7).padding(.vertical, 2.5)
                        .foregroundStyle(Self.gold).overlay(Capsule().strokeBorder(Self.gold.opacity(0.55), lineWidth: 1))
                    if let on {
                        Spacer(minLength: 12)
                        Toggle(x("toggle"), isOn: on).toggleStyle(.checkbox).font(.manrope(12.5, .medium)).tint(Self.gold)
                            .accessibilityIdentifier("export.sgrade.toggle")
                    }
                }
                if on?.wrappedValue == false { note(x("off")) } else { content }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(LauncherPalette.surface.opacity(0.92))
                RoundedRectangle(cornerRadius: 16).fill(RadialGradient(colors: [Self.gold.opacity(lit ? 0.18 : 0.06), .clear], center: .topLeading, startRadius: 0, endRadius: 420))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(LinearGradient(colors: [Self.goldHi.opacity(lit ? 0.75 : 0.30), Self.gold.opacity(0.12), Self.rose.opacity(lit ? 0.55 : 0.18)],
                                                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .shadow(color: Self.gold.opacity(lit ? 0.14 : 0), radius: 22, y: 6)
        .animation(.easeOut(duration: 0.35), value: lit)
        .accessibilityIdentifier("export.sgrade")
    }

    private static let catSymbol = ["widescreen": "arrow.up.left.and.arrow.down.right", "fps": "speedometer", "gfx": "wand.and.stars", "cheat": "gamecontroller.fill"]

    /// 玩家这份游戏的版本：显示版本号优先，没有就用构建号前 16 位
    private func mine(_ m: PatchMatch) -> String { m.version.isEmpty ? m.build.prefix(16).uppercased() : m.version }

    @ViewBuilder private var content: some View {
        if failed {
            note(x("unknown"))
        } else if let m = match {
            if m.total > 0 || m.port {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(["widescreen", "fps", "gfx", "cheat"], id: \.self) { c in
                        if let n = m.exact[c], n > 0 { hitRow(x("hit." + c).replacingOccurrences(of: "{0}", with: String(n)), symbol: Self.catSymbol[c] ?? "checkmark") }
                        if c == "widescreen", m.port { hitRow(x("port").replacingOccurrences(of: "{0}", with: m.portVersions.isEmpty ? x("port.any") : m.portVersions.prefix(3).joined(separator: zh ? "、" : ", ")), symbol: Self.catSymbol[c] ?? "checkmark") }
                    }
                }
                if m.total > 0 { note(x("hit.version").replacingOccurrences(of: "{0}", with: mine(m))) } else if m.build.isEmpty { note(x("later")) }
                note(x("hit.note"))
            } else {
                note(m.build.isEmpty ? x("later") : x("none").replacingOccurrences(of: "{0}", with: mine(m)))
            }
            if m.total == 0, !m.others.isEmpty {   // 补丁按版本生效（11-14 维护者）：列出的版本和玩家这份不同（或还不知道玩家是哪版）就不会打入，说清楚
                note(x(m.build.isEmpty ? "listed" : "others") + m.others.prefix(6).map { "\($0.version)\(zh ? "（" : " (")\($0.cats.map(catName).joined(separator: zh ? "、" : ", "))\(zh ? "）" : ")")" }
                    .joined(separator: zh ? "；" : "; "))
            }
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small).tint(Self.gold); Text(x("loading")).font(.manrope(12.5)).foregroundStyle(.secondary) }
        }
    }

    // 命中的一类：金色图标钮 + 一句话（几条、打进去了、默认开 / 关）
    private func hitRow(_ text: String, symbol: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Self.goldHi)
                .frame(width: 26, height: 26)
                .background(Circle().fill(LinearGradient(colors: [Self.gold.opacity(0.30), Self.rose.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [Self.goldHi.opacity(0.6), Self.rose.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
            Text(text).font(.manrope(13.5, .medium)).foregroundStyle(LauncherPalette.cream)
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// 游戏库封面左上角的金色 S（v0.4.0 维护者：已导出的游戏自动补上 S 级优化，封面点亮金色 S；只要这个 S，不加外框和底色）：
///   一层淡投影让它在浅色封面上也看得清
struct SGradeBadge: View {
    var size: CGFloat = 28
    var sImage: NSImage = SGradeCardView.sGold
    var body: some View {
        let s = Image(nsImage: sImage).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        s.overlay(s).overlay(s)   // 毛玻璃 S 本身半透明：叠两层更实
            .brightness(0.22).saturation(1.35)   // 整体调亮（v0.4.0 维护者：叠在游戏封面上要看得清）
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.45), radius: size * 0.12, y: size * 0.04)
            .padding(8)
            .accessibilityLabel("S")
            .accessibilityIdentifier("card.sgrade")
    }
}

/// 启动设置里的「S 级优化」一组（社区补丁 + 金手指，11-13 维护者：各界面入口与样式统一一次）：同出包页卡片一套金色——
///   金色毛玻璃 S、香槟金到玫瑰金的标题与描边、一句崩溃兜底的说明；下面的行照常（CardRow / 开关），只是放在金色描边的卡里
struct SGradeGroupCard<Content: View>: View {
    let title: String
    let note: String
    let content: Content
    /// 金色 S（缺省读 App 资源；单测传仓库里的原图）
    var sImage: NSImage = SGradeCardView.sGold
    init(_ title: String, note: String, sImage: NSImage = SGradeCardView.sGold, @ViewBuilder _ content: () -> Content) { self.title = title; self.note = note; self.sImage = sImage; self.content = content() }
    typealias G = SGradeCardView
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: sImage).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 34, height: 34)
                    .shadow(color: G.gold.opacity(0.5), radius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title).font(.manrope(16, .bold))
                            .foregroundStyle(LinearGradient(colors: [G.goldHi, G.gold, G.rose], startPoint: .leading, endPoint: .trailing))
                        Text("BETA").font(.manrope(9, .bold)).tracking(1.3).padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(G.gold).overlay(Capsule().strokeBorder(G.gold.opacity(0.55), lineWidth: 1))
                    }
                    if !note.isEmpty { Text(note).font(.manrope(11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            VStack(spacing: 0) { content }
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(LauncherPalette.surface.opacity(0.85))
                        RoundedRectangle(cornerRadius: 14).fill(RadialGradient(colors: [G.gold.opacity(0.12), .clear], center: .topLeading, startRadius: 0, endRadius: 360))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LinearGradient(colors: [G.goldHi.opacity(0.6), G.gold.opacity(0.10), G.rose.opacity(0.45)],
                                                                                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                .shadow(color: G.gold.opacity(0.10), radius: 16, y: 4)
        }
        .accessibilityIdentifier("launch.sgrade")
    }
}

/// S 级优化组里的一行开关（社区补丁一份 / 金手指一条）
struct SGradeToggle: Identifiable {
    let id: String
    let label: String
    let detail: String
    let on: Bool
    var enabled = true
}

/// S 级优化组的内容：「社区补丁」「金手指」两个小节，每节一个金色小标题（文字与下面各行的文字同一条起始线：行左边留 7 点圆点位 + 12 点间距，
///   小标题照留）+ 逐条开关行（CardRow，开关靠右）；金手指小标题右边是「导入」。启动设置与离屏单测共用
struct SGradeSettingsRows: View {
    let patchesTitle: String, patchesNote: String, patches: [SGradeToggle]
    let cheatsTitle: String, cheatsNote: String, cheats: [SGradeToggle]
    let importTitle: String
    var busy = false
    var onPatch: (String, Bool) -> Void = { _, _ in }
    var onCheat: (String, Bool) -> Void = { _, _ in }
    var onImport: () -> Void = {}
    typealias G = SGradeCardView

    /// 金手指一节默认收起（11-13 维护者：一款几十条会把框顶得很长）：只出一行「已开 n 条 · 共 m 条」，点开才列；列表限高、自己滚，多于 10 条带搜索
    @State private var cheatsOpen: Bool?
    /// 一打开就展开（离屏单测出展开态用）；玩家点过之后按玩家的
    var startOpen = false
    private var open: Bool { cheatsOpen ?? startOpen }
    @State private var query = ""
    static let listMaxHeight: CGFloat = 300
    var summary: (Int, Int) -> String = { on, all in "已开 \(on) 条 · 共 \(all) 条" }
    var searchPrompt = "搜索金手指"

    var body: some View {
        VStack(spacing: 0) {
            if !patches.isEmpty {
                subhead(patchesTitle, note: patchesNote) { EmptyView() }
                rows(patches, prefix: "launch.patch.", onPatch)
                CardDivider()
            }
            subhead(cheatsTitle, note: cheatsNote) {
                Button(importTitle) { onImport() }.buttonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("launch.cheats.import").disabled(busy)
            }
            if !cheats.isEmpty {
                // 汇总行：点一下展开 / 收起
                Button { withAnimation(.easeOut(duration: 0.2)) { cheatsOpen = !open } } label: {
                    CardRow(summary(cheats.filter(\.on).count, cheats.count), open: open) { EmptyView() }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("launch.cheats.toggleList")
                if open {
                    if cheats.count > 10 {
                        TextField(searchPrompt, text: $query).textFieldStyle(.roundedBorder).font(.manrope(12.5))
                            .padding(.leading, 18 + 7 + 12).padding(.trailing, 18).padding(.bottom, 6)   // 与各行文字同一条起始线（CardRow 左边 18 + 圆点位 7 + 间距 12）
                            .accessibilityIdentifier("launch.cheats.search")
                    }
                    let shown = query.isEmpty ? cheats : cheats.filter { $0.label.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }
                    ScrollView { VStack(spacing: 0) { rows(shown, prefix: "launch.cheat.", onCheat) } }
                        .frame(maxHeight: Self.listMaxHeight)
                        .fixedSize(horizontal: false, vertical: shown.count <= 4)   // 条数少就按内容高，不留空白
                }
            }
        }
    }

    private func subhead<T: View>(_ title: String, note: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.manrope(13, .bold)).tracking(0.4)
                    .foregroundStyle(LinearGradient(colors: [G.goldHi, G.gold], startPoint: .leading, endPoint: .trailing))
                if !note.isEmpty { Text(note).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
    }

    @ViewBuilder private func rows(_ list: [SGradeToggle], prefix: String, _ set: @escaping (String, Bool) -> Void) -> some View {
        ForEach(list) { r in
            CardRow(r.label, detail: r.detail) {
                Toggle("", isOn: Binding(get: { r.on }, set: { set(r.id, $0) }))
                    .toggleStyle(LauncherSwitchStyle()).labelsHidden().accessibilityLabel(r.label)
                    .accessibilityIdentifier(prefix + r.id).disabled(!r.enabled || busy)
            }
        }
    }
}
