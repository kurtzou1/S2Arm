// S2Arm（不是上游文件）：手柄图示，照 #520 UI 稿的 SVG（#520 UI 稿 的 symbol：i1 / i1l / i2 / pair / two-v / ipro）一比一画，
//   坐标就是稿里 viewBox 的坐标（Joy-Con 60×40、Pro 64×44），按显示尺寸等比缩放。Joy-Con 2 深灰机身、左只蓝边、右只红边
import SwiftUI

struct ControllerIcon: View {
    enum Glyph { case left, right, leftSideways, rightSideways, gen1LeftSideways, gen1RightSideways, pairHead, pro, unknown, playstation, xbox, gen1Left, gen1Right, gen1Pair, otherPad, keyboard }
    let glyph: Glyph

    /// 按连接程序报的型号挑图（ns2_kind：1 Pro、2 左、3 右、4 一对；players 2 = 两只各一位玩家，标题图同一对）
    /// 玩家列表里的一位：单只 Joy-Con 横着画（它就是一位玩家、横握），其余同标题图
    static func player(kind: Int) -> Glyph? {
        switch kind { case 2: return .leftSideways; case 3: return .rightSideways; default: return header(kind: kind, players: 1) }
    }
    static func header(kind: Int, players: Int) -> Glyph? {
        if players == 2 || kind == 4 { return .pairHead }
        switch kind { case 1: return .pro; case 2: return .left; case 3: return .right; default: return nil }
    }

    var body: some View {
        Canvas { context, size in
            let wide: Set<Glyph> = [.pro, .playstation, .xbox, .otherPad, .unknown, .keyboard]
            let box: CGSize = wide.contains(glyph) ? CGSize(width: 64, height: 44) : CGSize(width: 60, height: 40)
            let scale = min(size.width / box.width, size.height / box.height)
            context.translateBy(x: (size.width - box.width * scale) / 2, y: (size.height - box.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            switch glyph {
            case .left: Self.half(&context, left: true, inner: 40)
            // 单只当一位玩家：横着画（同握法）——左只逆时针、右只顺时针转 90°，两种摇杆都在左边
            case .leftSideways, .rightSideways, .gen1LeftSideways, .gen1RightSideways:
                let left = glyph == .leftSideways || glyph == .gen1LeftSideways
                context.translateBy(x: 30, y: 20); context.rotate(by: .degrees(left ? -90 : 90)); context.translateBy(x: -30, y: -20)
                Self.half(&context, left: left, inner: left ? 40 : 20, gen1: glyph == .gen1LeftSideways || glyph == .gen1RightSideways)
            case .right: Self.half(&context, left: false, inner: 20)
            case .pairHead: Self.half(&context, left: true, inner: 29); Self.half(&context, left: false, inner: 31)
            case .pro: Self.pro(&context)
            case .unknown: Self.unknown(&context)
            case .keyboard: Self.keyboardGlyph(&context)
            case .playstation: Self.pad(&context, body: Color(white: 0.95), touchpad: true, guide: nil)
            case .xbox: Self.pad(&context, body: Color(white: 0.95), touchpad: false, guide: Color(red: 0x10 / 255, green: 0x7c / 255, blue: 0x10 / 255))
            case .otherPad: Self.pro(&context)   // 认不出的手柄：同 Pro 手柄图
            case .gen1Left: Self.half(&context, left: true, inner: 40, gen1: true)
            case .gen1Right: Self.half(&context, left: false, inner: 20, gen1: true)
            case .gen1Pair: Self.half(&context, left: true, inner: 29, gen1: true); Self.half(&context, left: false, inner: 31, gen1: true)
            }
        }
    }

    static let leftAccent = Color(red: 0x41 / 255, green: 0xb8 / 255, blue: 0xe8 / 255)    // --l
    static let rightAccent = Color(red: 0xef / 255, green: 0x5a / 255, blue: 0x5a / 255)   // --r
    private static let shell = Color(red: 0x3b / 255, green: 0x3b / 255, blue: 0x3f / 255)
    private static let shellEdge = Color(red: 0x62 / 255, green: 0x61 / 255, blue: 0x66 / 255)
    private static let stickFill = Color(red: 0x1d / 255, green: 0x1d / 255, blue: 0x1f / 255)
    private static let key = Color(red: 0xe2 / 255, green: 0xdf / 255, blue: 0xd9 / 255)

    /// 一只 Joy-Con：inner 是贴中间那条直边的 x；机身宽 20、外侧圆角 10，内侧 3.2 宽的色条，摇杆 / 四键 / −（左）或 +（右）
    private static func half(_ c: inout GraphicsContext, left: Bool, inner x: CGFloat, gen1: Bool = false) {
        let outer = left ? x - 20 : x + 20
        var body = Path()
        body.move(to: CGPoint(x: x, y: 1))
        body.addLine(to: CGPoint(x: left ? outer + 10 : outer - 10, y: 1))
        body.addArc(center: CGPoint(x: left ? outer + 10 : outer - 10, y: 11), radius: 10,
                    startAngle: .degrees(-90), endAngle: .degrees(left ? 180 : 0), clockwise: left)
        body.addLine(to: CGPoint(x: outer, y: 29))
        body.addArc(center: CGPoint(x: left ? outer + 10 : outer - 10, y: 29), radius: 10,
                    startAngle: .degrees(left ? 180 : 0), endAngle: .degrees(90), clockwise: left)
        body.addLine(to: CGPoint(x: x, y: 39))
        body.closeSubpath()
        // 一代 Joy-Con（稿里 ijcl1）：整只彩色机身（左蓝 #0ab9e6、右红 #ff3c28）、没有色条，摇杆和键是深色
        let gen1Body = left ? Color(red: 0x0a / 255, green: 0xb9 / 255, blue: 0xe6 / 255) : Color(red: 0xff / 255, green: 0x3c / 255, blue: 0x28 / 255)
        let gen1Edge = left ? Color(red: 0x07 / 255, green: 0x94 / 255, blue: 0xbb / 255) : Color(red: 0xc9 / 255, green: 0x2a / 255, blue: 0x1b / 255)
        c.fill(body, with: .color(gen1 ? gen1Body : shell))
        c.stroke(body, with: .color(gen1 ? gen1Edge : shellEdge), lineWidth: 1)
        let accent = left ? leftAccent : rightAccent
        if !gen1 { c.fill(Path(roundedRect: CGRect(x: left ? x - 3.2 : x, y: 1, width: 3.2, height: 38), cornerRadius: 1.4), with: .color(accent)) }
        let cx = left ? x - 11.5 : x + 11.5
        let stick = CGRect(x: cx - 4.6, y: (left ? 13 : 28) - 4.6, width: 9.2, height: 9.2)
        c.fill(Path(ellipseIn: stick), with: .color(stickFill))
        if gen1 { c.fill(Path(ellipseIn: stick.insetBy(dx: 2, dy: 2)), with: .color(Color(red: 0x3a / 255, green: 0x3a / 255, blue: 0x3c / 255))) }
        else { c.stroke(Path(ellipseIn: stick), with: .color(accent), lineWidth: 1.9) }
        let keyColor = gen1 ? stickFill : key
        let keys = CGPoint(x: cx, y: left ? 28 : 13)
        for (dx, dy) in [(0.0, -3.6), (3.6, 0.0), (0.0, 3.6), (-3.6, 0.0)] {
            c.fill(Path(ellipseIn: CGRect(x: keys.x + dx - 1.7, y: keys.y + dy - 1.7, width: 3.4, height: 3.4)), with: .color(keyColor))
        }
        var sign = Path()
        let sx = left ? x - 8.4 : x + 5.6
        sign.move(to: CGPoint(x: sx, y: 4.6)); sign.addLine(to: CGPoint(x: sx + 2.8, y: 4.6))
        if !left { sign.move(to: CGPoint(x: sx + 1.4, y: 3.2)); sign.addLine(to: CGPoint(x: sx + 1.4, y: 6)) }
        c.stroke(sign, with: .color(keyColor), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
    }

    /// 系统手柄外形（稿里 ips 的轮廓，viewBox 64×44）
    private static func padPath() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 14, y: 8)); p.addLine(to: CGPoint(x: 50, y: 8))
        p.addCurve(to: CGPoint(x: 63, y: 25), control1: CGPoint(x: 58, y: 8), control2: CGPoint(x: 62, y: 15))
        p.addCurve(to: CGPoint(x: 55, y: 40), control1: CGPoint(x: 64, y: 34), control2: CGPoint(x: 60, y: 40))
        p.addCurve(to: CGPoint(x: 43, y: 34), control1: CGPoint(x: 50, y: 40), control2: CGPoint(x: 47, y: 34))
        p.addLine(to: CGPoint(x: 21, y: 34))
        p.addCurve(to: CGPoint(x: 9, y: 40), control1: CGPoint(x: 17, y: 34), control2: CGPoint(x: 14, y: 40))
        p.addCurve(to: CGPoint(x: 1, y: 25), control1: CGPoint(x: 4, y: 40), control2: CGPoint(x: 0, y: 34))
        p.addCurve(to: CGPoint(x: 14, y: 8), control1: CGPoint(x: 2, y: 15), control2: CGPoint(x: 6, y: 8))
        p.closeSubpath()
        return p
    }

    /// 系统手柄（稿里 ips，viewBox 64×44）：PlayStation 带上面一条触控板；Xbox 去掉触控板、中间一颗绿色导引键（草稿，稿里没有）
    private static func pad(_ c: inout GraphicsContext, body color: Color, touchpad: Bool, guide: Color?) {
        let p = padPath()
        c.fill(p, with: .color(color))
        let dark = Color(red: 0x2a / 255, green: 0x28 / 255, blue: 0x26 / 255)
        if touchpad { c.fill(Path(CGRect(x: 22, y: 8, width: 20, height: 9)), with: .color(Color(red: 0x2b / 255, green: 0x2b / 255, blue: 0x2b / 255))) }
        if let guide { c.fill(Path(ellipseIn: CGRect(x: 28.5, y: 12.5, width: 7, height: 7)), with: .color(guide)) }
        c.fill(Path(ellipseIn: CGRect(x: 44.4, y: 17.4, width: 5.2, height: 5.2)), with: .color(dark))
        c.fill(Path(ellipseIn: CGRect(x: 49.4, y: 22.4, width: 5.2, height: 5.2)), with: .color(dark))
        var plus = Path()
        plus.move(to: CGPoint(x: 14, y: 23)); plus.addLine(to: CGPoint(x: 23, y: 23))
        plus.move(to: CGPoint(x: 18.5, y: 18.5)); plus.addLine(to: CGPoint(x: 18.5, y: 27.5))
        c.stroke(plus, with: .color(dark), style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }

    /// 还不知道型号：虚线手柄轮廓（#520 讨论 定，取代稿里的两只虚线 Joy-Con iq）；形状同系统手柄图
    private static func unknown(_ c: inout GraphicsContext) {
        let gray = Color(red: 0x8a / 255, green: 0x85 / 255, blue: 0x7e / 255)
        c.stroke(padPath(), with: .color(gray), style: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: [3.5, 3]))
    }

    /// 键盘（分配成一位玩家时，#520 E；稿里没有，同 Pro 图的米色机身 + 深色键）：三排键 + 空格
    private static func keyboardGlyph(_ c: inout GraphicsContext) {
        let body = Color(red: 0xe8 / 255, green: 0xe3 / 255, blue: 0xda / 255), key = Color(red: 0x2a / 255, green: 0x28 / 255, blue: 0x26 / 255)
        c.fill(Path(roundedRect: CGRect(x: 2, y: 9, width: 60, height: 28), cornerRadius: 5), with: .color(body))
        for row in 0..<3 {
            let count = row == 1 ? 7 : 8, inset: CGFloat = row == 1 ? 9.5 : 7
            for i in 0..<count {
                c.fill(Path(roundedRect: CGRect(x: inset + CGFloat(i) * 6.4, y: 13 + CGFloat(row) * 5.6, width: 4.4, height: 3.6), cornerRadius: 1), with: .color(key))
            }
        }
        c.fill(Path(roundedRect: CGRect(x: 18, y: 30, width: 28, height: 3.6), cornerRadius: 1.2), with: .color(key))
    }

    /// NS2 Pro（稿里 ipro，viewBox 64×44）
    private static func pro(_ c: inout GraphicsContext) {
        var p = Path()
        p.move(to: CGPoint(x: 14, y: 6)); p.addLine(to: CGPoint(x: 50, y: 6))
        p.addCurve(to: CGPoint(x: 63, y: 24), control1: CGPoint(x: 58, y: 6), control2: CGPoint(x: 62, y: 14))
        p.addCurve(to: CGPoint(x: 55, y: 40), control1: CGPoint(x: 64, y: 33), control2: CGPoint(x: 61, y: 40))
        p.addCurve(to: CGPoint(x: 44, y: 34), control1: CGPoint(x: 50, y: 40), control2: CGPoint(x: 48, y: 34))
        p.addLine(to: CGPoint(x: 20, y: 34))
        p.addCurve(to: CGPoint(x: 9, y: 40), control1: CGPoint(x: 16, y: 34), control2: CGPoint(x: 14, y: 40))
        p.addCurve(to: CGPoint(x: 1, y: 24), control1: CGPoint(x: 3, y: 40), control2: CGPoint(x: 0, y: 33))
        p.addCurve(to: CGPoint(x: 14, y: 6), control1: CGPoint(x: 2, y: 14), control2: CGPoint(x: 6, y: 6))
        p.closeSubpath()
        c.fill(p, with: .color(Color(red: 0xe8 / 255, green: 0xe3 / 255, blue: 0xda / 255)))
        let dark = Color(red: 0x2a / 255, green: 0x28 / 255, blue: 0x26 / 255)
        c.fill(Path(ellipseIn: CGRect(x: 43, y: 15, width: 6, height: 6)), with: .color(dark))
        c.fill(Path(ellipseIn: CGRect(x: 49, y: 21, width: 6, height: 6)), with: .color(dark))
        var plus = Path()
        plus.move(to: CGPoint(x: 15, y: 21)); plus.addLine(to: CGPoint(x: 25, y: 21))
        plus.move(to: CGPoint(x: 20, y: 16)); plus.addLine(to: CGPoint(x: 20, y: 26))
        c.stroke(plus, with: .color(dark), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
    }
}
