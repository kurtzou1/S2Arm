#if canImport(UIKit)
import SwiftUI
import UIKit
import ShellUI
import S2ArmShellBridge

/// 虚拟手柄布局编辑页（11-07 维护者：游戏库 → 这款的设置 → 按键布局 →「调整位置…」）：这款的封面当范例底图，按键按游戏里同一套描线样式画，
/// 拖哪个挪哪个；「完成」存本款「我的布局」并选中，「恢复默认」切回默认布局（我的布局文件保留）。
/// 下方按键透明度拉杆（11-07 维护者：去掉「取消」，两键居中，拉杆配一行说明）：写 App 级 S2AVPadOpacity（全部游戏共用，同设置页那一行），拖动时本页按键跟着变。
/// 几何与游戏内 vpad.m 同口径：可放区域 = 安全区（左右至少 16、底至少 8 点），按键 x / y 是区域宽高比例、尺寸是区域短边比例。
/// 数据只经 C 接口 s2a_shell_vpad_*（宿主 ios/vpad_shell.m），与游戏内拖动编辑同一份文件。
struct S2ArmTouchEditorView: View {
    let gameID: String
    let banner: URL?
    @State var opacity: Double
    let close: () -> Void

    struct Key: Identifiable { let id: String; var center: CGPoint; let size: CGSize; let radius: CGFloat }
    @State private var keys: [Key] = []
    @State private var area: CGRect = .zero
    @State private var game: CGRect = .zero
    @State private var division: CGRect = .null
    @State private var split = false
    @State private var stickRadius: CGFloat = 60
    @State private var lastPreview: Data?
    @State private var problem: String?

    // 方案三「描线」+ 摇杆区方案二「石墨」（同 vpad.m vp_line / vp_face / 摇杆圈）
    private let line = Color.white.opacity(0.78), face = Color(red: 150 / 255, green: 215 / 255, blue: 230 / 255).opacity(0.9)

    var body: some View {
        GeometryReader { proxy in
            let full = proxy.size
            ZStack(alignment: .topLeading) {
                background(full)
                if split {
                    Color.black.opacity(0.8).frame(width: full.width, height: max(0, full.height - area.minY))
                        .position(x: full.width / 2, y: (full.height + area.minY) / 2)
                }
                TouchEditorSurface(split: split, changed: load).allowsHitTesting(false)
                if stickRadius > 0 { sticks }
                ForEach($keys) { $k in keyView(k).position(k.center).gesture(drag($k)) }
                bar(full)
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
    }

    private func background(_ size: CGSize) -> some View {
        Group {
            if let banner, let image = UIImage(contentsOfFile: banner.path) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: size.width, height: size.height).clipped()
            } else { Color(white: 0.15) }
        }
        .overlay(Color.black.opacity(0.25))
        .frame(width: size.width, height: size.height)
    }

    /// 摇杆是浮动的（左 / 右半屏任意处按下），这里只画石墨圈示意大致的拇指位，不能拖
    private var sticks: some View {
        let r = stickRadius
        let homes = split ? [(0.13, 0.63, shellText("Left stick: press in the blank left half")), (0.65, 0.75, shellText("Right stick: press in the blank right half"))] :
                            [(0.075, 0.69, shellText("Left stick: press anywhere on the left half")), (0.70, 0.81, shellText("Right stick: press anywhere on the right half"))]
        return ForEach(homes, id: \.2) { x, y, text in
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(Color(red: 20 / 255, green: 22 / 255, blue: 26 / 255).opacity(0.32)).frame(width: 2 * r, height: 2 * r)
                    Circle().fill(Color(red: 210 / 255, green: 214 / 255, blue: 220 / 255).opacity(0.59)).frame(width: r * 52 / 60, height: r * 52 / 60)
                }
                Text(text).font(.caption2).foregroundStyle(.white.opacity(0.85))
            }
            .opacity(opacity)
            .position(x: area.minX + x * area.width, y: area.minY + y * area.height)
            .allowsHitTesting(false)
        }
    }

    private func keyView(_ k: Key) -> some View {
        let isFace = ["A", "B", "X", "Y"].contains(k.id)
        let labels = ["PLUS": "＋", "MINUS": "－", "UP": "▲", "DOWN": "▼", "LEFT": "◀︎", "RIGHT": "▶︎", "LS": "L3", "RS": "R3"]
        return Text(labels[k.id] ?? k.id)
            .font(.system(size: isFace ? 17 : 13, weight: .bold))
            .foregroundStyle(isFace ? face : Color.white.opacity(0.86))
            .frame(width: k.size.width, height: k.size.height)
            .overlay(RoundedRectangle(cornerRadius: k.radius).stroke(line, lineWidth: 1.6))
            .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
            .contentShape(Rectangle())
            .opacity(opacity)
            .accessibilityLabel(k.id)
    }

    private func drag(_ k: Binding<Key>) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { g in
            let hw = k.wrappedValue.size.width / 2, hh = k.wrappedValue.size.height / 2   // 整个键不出可放区域
            let center = CGPoint(x: min(area.maxX - hw, max(area.minX + hw, g.location.x)),
                                 y: min(area.maxY - hh, max(area.minY + hh, g.location.y)))
            let frame = CGRect(x: center.x - hw, y: center.y - hh, width: hw * 2, height: hh * 2)
            if split && !division.isNull && frame.intersects(division) { return }
            k.wrappedValue.center = center
        }
    }

    private func bar(_ size: CGSize) -> some View {
        let canvas = split ? game : CGRect(origin: .zero, size: size)
        let placement = toolbarArea(canvas)
        let width = max(1, min(340, placement.width - 32))
        return VStack(spacing: 10) {
            Picker(shellText("Edit layout"), selection: $split) {
                Text(shellText("Normal")).tag(false)
                Text(shellText("Split screen")).tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("vpad.editor.profile")
            if let problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
            else { Text(shellText("Drag a button to move it (this game only)")).font(.footnote).foregroundStyle(.white) }
            HStack(spacing: 16) {
                button(shellText("Reset to default")) {
                    let ok = gameID.withCString { s2a_shell_vpad_select($0, "default", split ? 1 : 0) }
                    if ok == 1 { close() } else { problem = shellText("Reset wasn’t completed. Try again.") }
                }
                button(shellText("Done")) { save() }
            }
                VStack(spacing: 4) {
                    HStack(spacing: 10) {
                        Text(shellText("Button opacity")).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        Slider(value: $opacity, in: 0.1...1, step: 0.05) { editing in
                            if !editing { UserDefaults.standard.set(min(1, max(0.1, opacity)), forKey: "S2AVPadOpacity") }
                        }
                        .tint(.white)
                        Text("\(Int((opacity * 100).rounded()))%").font(.footnote.monospacedDigit()).foregroundStyle(.white).frame(width: 40, alignment: .trailing)
                    }
                    Text(shellText("Applies to all games; drag to preview here")).font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
        }
        .frame(width: width)
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
        .position(x: placement.midX, y: placement.midY)
    }

    private func toolbarArea(_ canvas: CGRect) -> CGRect {
        guard !division.isNull, division.height > division.width, canvas.intersects(division) else { return canvas }
        let left = CGRect(x: canvas.minX, y: canvas.minY, width: max(0, division.minX - canvas.minX), height: canvas.height)
        let right = CGRect(x: division.maxX, y: canvas.minY, width: max(0, canvas.maxX - division.maxX), height: canvas.height)
        return left.width >= right.width ? left : right
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 36)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// 宿主直接计算生产的区域、按键尺寸、折痕避让；在 updateConstraints 中读取，兼顾同尺寸下折叠变化。
    private func load(_ view: UIView) {
        guard let p = gameID.withCString({ s2a_shell_vpad_preview($0, Unmanaged.passUnretained(view).toOpaque(), split ? 1 : 0) }) else {
            DispatchQueue.main.async { problem = shellText("Couldn’t read this game’s button layout"); keys = [] }
            return
        }
        defer { free(p) }
        let data = Data(String(cString: p).utf8)
        DispatchQueue.main.async { applyPreview(data) }
    }

    private func applyPreview(_ data: Data) {
        guard data != lastPreview, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["split"] as? Bool == split, let a = obj["area"] as? [Double], a.count == 4,
              let g = obj["game"] as? [Double], g.count == 4 else { return }
        lastPreview = data; problem = nil
        area = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        game = CGRect(x: g[0], y: g[1], width: g[2], height: g[3])
        if let d = obj["division"] as? [Double], d.count == 4 { division = CGRect(x: d[0], y: d[1], width: d[2], height: d[3]) } else { division = .null }
        stickRadius = obj["stickRadius"] as? Double ?? 60
        keys = (obj["buttons"] as? [[String: Any]] ?? []).compactMap { b in
            guard let id = b["id"] as? String, let x = b["x"] as? Double, let y = b["y"] as? Double,
                  let bw = b["width"] as? Double, let bh = b["height"] as? Double else { return nil }
            let size = CGSize(width: bw, height: bh)
            let radius = min(b["cornerRadius"] as? Double ?? 0, min(size.width, size.height) / 2)
            return Key(id: id, center: CGPoint(x: x, y: y), size: size, radius: radius)
        }
    }

    private func save() {
        var centers: [String: [Double]] = [:]
        for k in keys { centers[k.id] = [Double(k.center.x - area.minX), Double(k.center.y - area.minY)] }   // 区域坐标（原点左上）
        guard let data = try? JSONSerialization.data(withJSONObject: centers), let json = String(data: data, encoding: .utf8) else { problem = shellText("Button positions weren’t saved"); return }
        let ok = gameID.withCString { g in json.withCString { s2a_shell_vpad_save(g, $0, Double(area.width), Double(area.height), split ? 1 : 0) } }
        if ok == 1 { close() } else { problem = shellText("Button positions weren’t saved. Try again.") }
    }
}

/// 读取系统保留区必须发生在 updateConstraints；仅监听 GeometryReader 的尺寸变化会漏掉同尺寸半折。
private struct TouchEditorSurface: UIViewRepresentable {
    let split: Bool
    let changed: @MainActor (UIView) -> Void
    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.changed = changed; view.setNeedsUpdateConstraints(); view.setNeedsLayout()
    }
    final class Surface: UIView {
        var changed: (@MainActor (UIView) -> Void)?
        override func updateConstraints() { changed?(self); super.updateConstraints() }
        override func layoutSubviews() { super.layoutSubviews(); changed?(self) }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsUpdateConstraints() }
    }
}
#endif
