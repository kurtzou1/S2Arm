import ShellUI
import SwiftUI

/// 首次进入游戏库的引导（11-14 维护者：「ios 也做个首次进入弹窗，分三页可滑动，展示一下从哪进入设置、金手指和故障报修」）。
///   三页横滑：① 设置在哪（右上角齿轮 = App 设置；选中游戏点「游戏设置」= 这款的设置；游戏里左上角齿轮）② 金手指在哪开 ③ 故障报修。
///   示意图用 SwiftUI 现画（不带图片资源，文字跟 App 语言走）。看过一次就不再弹（UserDefaults seenKey）；关掉 / 跳过 / 最后一页「开始玩」都算看过。
///   手柄：开着时宿主把手柄输入转给这里（S2ArmShellHostModel.guideInput）：左右翻页、A 下一页 / 完成、B 关。
struct S2ArmGuideView: View {
    @Binding var page: Int
    let close: () -> Void
    static let pages = 3

    private static let gold = Color(red: 0.96, green: 0.83, blue: 0.55)

    var body: some View {
        GeometryReader { geo in
            // 手机横屏（高度不到 520 点）：左图右文；其余（iPad、竖屏）：上图下文
            let compact = geo.size.height < 520
            let width = min(compact ? 760 : 720, geo.size.width - 32)
            let height = compact ? min(geo.size.height - 24, 360) : min(geo.size.height - 24, 240 + 180 + 61)   // 上图下文：图 240 + 三行说明约 180 + 底栏；Duo 展开屏原先固定 560，下半截空（11-14）；大字号放不下时说明区自己滚
            ZStack {
                Color.black.opacity(0.72).ignoresSafeArea().accessibilityHidden(true)
                VStack(spacing: 0) {
                    #if os(iOS)
                    TabView(selection: $page) {   // 系统分页：手指左右滑翻页
                        ForEach(0..<Self.pages, id: \.self) { i in
                            pageView(i, compact: compact, width: width).tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    #else
                    pageView(page, compact: compact, width: width)   // macOS 只为本机跑宿主层单测编译
                    #endif
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    footer.padding(.horizontal, 20).frame(height: 60)
                }
                .frame(width: width, height: height)
                .background(ShellPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityAddTraits(.isModal)
                .accessibilityIdentifier("guide")
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(.easeInOut(duration: 0.25), value: page)
    }

    // MARK: 每页

    @ViewBuilder private func art(_ i: Int) -> some View {
        Group {
            switch i {
            case 0: SettingsArt()
            case 1: CheatsArt()
            default: ReportArt()
            }
        }
        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.10), Color(red: 0.07, green: 0.09, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func words(_ i: Int) -> some View {
        let body = VStack(alignment: .leading, spacing: 8) {
            Text(shellText(kicker(i))).font(.system(size: 12, weight: .bold)).tracking(1).foregroundStyle(Self.gold)
            Text(shellText(title(i))).font(.system(size: 21, weight: .heavy)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(lines(i).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Self.gold).frame(width: 5, height: 5).offset(y: -2)
                    Text(Self.rich(shellText(line))).font(.system(size: 14)).foregroundStyle(Color(white: 0.86)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 放得下就不滚；大字号 / 小屏放不下才滚
        return ViewThatFits(in: .vertical) { body; ScrollView { body }.scrollBounceBehavior(.basedOnSize) }
    }

    @ViewBuilder private func pageView(_ i: Int, compact: Bool, width: CGFloat) -> some View {
        if compact {
            HStack(spacing: 0) {
                art(i).frame(width: width * 0.46).frame(maxHeight: .infinity)
                words(i).frame(maxHeight: .infinity, alignment: .center)
            }
        } else {
            VStack(spacing: 0) {
                art(i).frame(height: 240)
                words(i).frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// 「**…**」加粗
    private static func rich(_ s: String) -> AttributedString { (try? AttributedString(markdown: s)) ?? AttributedString(s) }

    private func kicker(_ i: Int) -> String.LocalizationValue {
        switch i { case 0: "Settings"; case 1: "Cheats"; default: "Report a problem" }
    }
    private func title(_ i: Int) -> String.LocalizationValue {
        switch i {
        case 0: "Where to find the settings"
        case 1: "Turn cheats on one by one"
        default: "Stuck? Send us a report"
        }
    }
    private func lines(_ i: Int) -> [String.LocalizationValue] {
        switch i {
        case 0: ["**Gear at the top right**: settings for the whole app, such as interface, sound and reporting a problem.",
                 "**Select a game, then the sliders button at the top (Game settings)**: this game's picture, controls, community patches and cheats.",
                 "**In a game, the gear at the top left** opens the same game settings at any time."]
        case 1: ["Cheats matched to your game's version come built in, and they start **off**.",
                 "In a game: **top-left gear → S-grade enhancements → Cheats**, then switch on the ones you want. Each takes effect in about a second.",
                 "Or set them up before playing: **select a game → sliders button at the top → Cheats**."]
        default: ["**Gear at the top right → Report a problem** at the bottom.",
                  "Add a sentence about what happened (optional) and upload. You get a short code starting with **D-**; paste it in the group chat or a GitHub issue.",
                  "In a game: **top-left gear → Report a problem**."]
        }
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                ForEach(0..<Self.pages, id: \.self) { i in
                    Capsule().fill(i == page ? ShellPalette.cream : Color.white.opacity(0.2)).frame(width: i == page ? 22 : 8, height: 8)
                        .contentShape(Rectangle().inset(by: -8)).onTapGesture { page = i }
                }
            }
            .accessibilityElement().accessibilityLabel("\(page + 1) / \(Self.pages)")
            Spacer()
            Button(shellText(page == 0 ? "Skip" : "Back")) { if page == 0 { close() } else { page -= 1 } }
                .buttonStyle(.plain).font(.system(size: 15, weight: .semibold)).foregroundStyle(ShellPalette.muted)
                .accessibilityIdentifier("guide.back")
            Button { if page >= Self.pages - 1 { close() } else { page += 1 } } label: {
                Text(shellText(page >= Self.pages - 1 ? "Start playing" : "Next")).font(.system(size: 15.5, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 22).frame(height: 40).background(ShellPalette.cream, in: Capsule())
            }
            .buttonStyle(.plain).accessibilityIdentifier("guide.next")
        }
    }
}

// MARK: 示意图（SwiftUI 现画，不是截图）

/// 横屏手机框 + 里面的内容：示意图按固定设计尺寸（300×146 点）画，再整体缩放到可用区域，任何屏幕上比例都一样、不会互相压住
private struct PhoneFrame<Content: View>: View {
    @ViewBuilder let content: Content
    static var design: CGSize { CGSize(width: 300, height: 146) }
    var body: some View {
        GeometryReader { g in
            let outer = CGSize(width: Self.design.width + 12, height: Self.design.height + 12)
            let scale = min((g.size.width - 24) / outer.width, (g.size.height - 24) / outer.height)
            content
                .frame(width: Self.design.width, height: Self.design.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(6)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5))
                .scaleEffect(max(scale, 0.1))
                .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// 金色圈：指出要点哪里
private struct Ring: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(Capsule().strokeBorder(Color(red: 0.96, green: 0.83, blue: 0.55), lineWidth: 1.8).padding(-3))
            .shadow(color: Color(red: 0.96, green: 0.72, blue: 0.3).opacity(0.6), radius: 5)
    }
}

private struct Chip: View {
    let symbol: String
    var label: String? = nil
    var ring = false
    var body: some View {
        let chip = HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold))
            if let label { Text(label).font(.system(size: 8, weight: .semibold)).lineLimit(1) }
        }
        .foregroundStyle(.white).padding(.horizontal, 6).frame(height: 17)
        .background(Color.white.opacity(0.14), in: Capsule())
        if ring { chip.modifier(Ring()) } else { chip }
    }
}

/// 风景（游戏画面的示意）
private struct Scene: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.95, green: 0.64, blue: 0.35), Color(red: 0.89, green: 0.44, blue: 0.35), Color(red: 0.36, green: 0.24, blue: 0.45)], startPoint: .top, endPoint: .bottom)
            GeometryReader { g in
                Circle().fill(Color(red: 1, green: 0.89, blue: 0.65)).frame(width: g.size.height * 0.36).position(x: g.size.width * 0.66, y: g.size.height * 0.36)
                Path { p in
                    let w = g.size.width, h = g.size.height
                    p.move(to: CGPoint(x: 0, y: h * 0.72)); p.addLine(to: CGPoint(x: w * 0.18, y: h * 0.48)); p.addLine(to: CGPoint(x: w * 0.36, y: h * 0.66))
                    p.addLine(to: CGPoint(x: w * 0.55, y: h * 0.40)); p.addLine(to: CGPoint(x: w * 0.76, y: h * 0.62)); p.addLine(to: CGPoint(x: w, y: h * 0.50))
                    p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath()
                }.fill(Color(red: 0.23, green: 0.16, blue: 0.33))
            }
        }
    }
}

/// 第 1 页：游戏库——顶栏的「游戏设置」（调节图标）和右上角齿轮都圈出来（设计尺寸 300×146）；按真机游戏库顶栏的排法：排序 / 游戏设置 / 玩家 / 手柄 / 齿轮
private struct SettingsArt: View {
    var body: some View {
        PhoneFrame {
            ZStack(alignment: .topLeading) {
                Color(red: 0.07, green: 0.07, blue: 0.08)
                HStack(spacing: 5) {
                    Chip(symbol: "arrow.up.arrow.down"); Chip(symbol: "slider.horizontal.3", ring: true)
                    Chip(symbol: "person.crop.circle"); Chip(symbol: "gamecontroller"); Chip(symbol: "gearshape", ring: true)
                }
                .frame(width: 300, alignment: .trailing).padding(.top, 9).padding(.trailing, 10)
                HStack(alignment: .center, spacing: 12) {
                    tile(false, 48); tile(true, 74); tile(false, 48)
                }
                .frame(width: 300).padding(.top, 46)
            }
        }
    }
    private func tile(_ selected: Bool, _ size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(LinearGradient(colors: selected ? [Color(red: 0.95, green: 0.6, blue: 0.35), Color(red: 0.36, green: 0.24, blue: 0.45)] : [Color(white: 0.24), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? ShellPalette.cream : .clear, lineWidth: 1.5))
    }
}

/// 第 2 页：游戏里——左上角齿轮 → S 级优化 → 金手指（设计尺寸 300×146）
private struct CheatsArt: View {
    var body: some View {
        PhoneFrame {
            ZStack(alignment: .topLeading) {
                Scene()
                Image(systemName: "gearshape.fill").font(.system(size: 10)).foregroundStyle(.white).frame(width: 20, height: 20)
                    .background(Color.black.opacity(0.45), in: Circle()).modifier(Ring())
                    .padding(.leading, 9).padding(.top, 8)
                VStack(alignment: .leading, spacing: 0) {
                    menuRow("square.grid.2x2", shellText("Button layout"))
                    menuRow("circle.circle", shellText("Sticks"))
                    menuRow("star.fill", shellText("S-grade"), gold: true, chevron: true)
                    menuRow("gearshape", shellText("Settings…"))
                }
                .frame(width: 124).background(Color(white: 0.16).opacity(0.96), in: RoundedRectangle(cornerRadius: 8))
                .padding(.leading, 9).padding(.top, 34)
                VStack(alignment: .leading, spacing: 0) {
                    menuRow("square.stack.3d.up.fill", shellText("Community patches…"))
                    menuRow("wand.and.stars", shellText("Cheats…"), gold: true)
                }
                .frame(width: 140).background(Color(white: 0.2).opacity(0.97), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(red: 0.96, green: 0.83, blue: 0.55), lineWidth: 1.5))
                .padding(.leading, 140).padding(.top, 70)
            }
        }
    }
    private func menuRow(_ symbol: String, _ title: String, gold: Bool = false, chevron: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 8)).frame(width: 11)
            Text(title).font(.system(size: 8.5, weight: gold ? .bold : .regular)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            if chevron { Image(systemName: "chevron.right").font(.system(size: 7)) }
        }
        .foregroundStyle(gold ? Color(red: 0.96, green: 0.83, blue: 0.55) : .white).padding(.horizontal, 8).frame(height: 18)
    }
}

/// 第 3 页：游戏库设置最下面的「故障报修」→ 拿到的短码（设计尺寸 300×146）
private struct ReportArt: View {
    var body: some View {
        PhoneFrame {
            ZStack(alignment: .topLeading) {
                Color(red: 0.07, green: 0.07, blue: 0.08)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach([shellText("Interface"), shellText("Sound")], id: \.self) { t in
                        Text(t).font(.system(size: 7.5, weight: .semibold)).foregroundStyle(ShellPalette.muted)
                        RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)).frame(height: 14)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.bubble").font(.system(size: 8.5))
                        Text(shellText("Report a problem")).font(.system(size: 8.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 4)
                        Text(shellText("Report…")).font(.system(size: 7.5, weight: .bold)).foregroundStyle(.black).lineLimit(1)
                            .padding(.horizontal, 7).frame(height: 15).background(ShellPalette.cream, in: Capsule())
                    }
                    .foregroundStyle(.white).padding(.horizontal, 7).frame(height: 24)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6)).modifier(Ring())
                }
                .frame(width: 150).padding(.leading, 12).padding(.top, 14)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(red: 0.96, green: 0.83, blue: 0.55))
                    .padding(.leading, 172).padding(.top, 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "D-96EB").font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    Text(shellText("Paste this code in the group chat or a GitHub issue")).font(.system(size: 7.5)).foregroundStyle(ShellPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8).frame(width: 96, alignment: .leading)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .padding(.leading, 192).padding(.top, 72)
            }
        }
    }
}
