// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import SwiftUI
import NXLauncher

/// Compact controls keep the artwork visible; labels remain available to VoiceOver and on hover.
struct ConsoleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 40
    var backgroundless = false   // 顶栏等只要图标的圆钮：不画底与描边，按下变淡（main）
    var accent: Color? = nil     // 强调色（收藏等）：图标、底色与描边按它着色（外部贡献 #1537）
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let hot = enabled && hovered
        let tint = accent ?? .white
        let activeTint = accent != nil
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: size > 44 ? 20 : 16, weight: .medium))
            .frame(width: size, height: size)
            .foregroundStyle((activeTint ? tint : .white).opacity(enabled ? 0.95 : 0.35))
            .opacity(backgroundless && configuration.isPressed ? 0.6 : 1)
            .background {
                if !backgroundless {
                    Circle()
                        .fill(.thinMaterial)
                        .overlay(Circle().fill(tint.opacity(configuration.isPressed ? (activeTint ? 0.24 : 0.12) : (hot ? (activeTint ? 0.16 : 0.06) : (activeTint ? 0.11 : 0)))))
                }
            }
            .overlay {
                if !backgroundless { Circle().strokeBorder(tint.opacity(hot ? (activeTint ? 0.44 : 0.20) : (activeTint ? 0.30 : 0.12))) }
            }
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.14), value: hovered)
            .onHover { hovered = $0 }
    }
}

/// 首页主操作（开始游戏 / 出包 / 装到 iPhone / 查看当前任务）：奶油底胶囊，图标 + 文字（11-16 维护者：只有图标时只有 ▶ 看得懂）。
///   高度与次要操作（ConsolePillButtonStyle）、圆钮（ConsoleIconButtonStyle size 52）同为 52，一行只差颜色不差形状
struct ConsolePlayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let hot = enabled && hovered
        configuration.label
            .labelStyle(ConsoleLabelStyle())
            .font(.manrope(16, .bold))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 24)
            .frame(minWidth: 92, minHeight: 52, maxHeight: 52)
            .foregroundStyle(.black.opacity(0.85))
            .background(LauncherPalette.cream.opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.4), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 16, y: 5)
            .scaleEffect(enabled && configuration.isPressed ? 0.985 : (hot ? 1.03 : 1))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.14), value: hovered)
            .onHover { hovered = $0 }
    }
}

/// 首页次要操作（导出… / 无需更新 / 出包）：与主按钮同高同胶囊，深色磨砂底 + 细边（同圆钮），只是不用奶油底
struct ConsolePillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let hot = enabled && hovered
        configuration.label
            .labelStyle(ConsoleLabelStyle())
            .font(.manrope(15, .semibold))
            .lineLimit(1)
            .padding(.horizontal, 20)
            .frame(minHeight: 52, maxHeight: 52)
            .foregroundStyle(.white.opacity(enabled ? 0.95 : 0.35))
            .background {
                Capsule()
                    .fill(.thinMaterial)
                    .overlay(Capsule().fill(.white.opacity(configuration.isPressed ? 0.12 : (hot ? 0.06 : 0))))
            }
            .overlay(Capsule().strokeBorder(.white.opacity(hot ? 0.20 : 0.12)))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.14), value: hovered)
            .onHover { hovered = $0 }
    }
}

/// 图标 + 文字，图标比文字略大、垂直居中
struct ConsoleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 17, weight: .semibold))
            configuration.title
        }
    }
}

// 圆钮 / 胶囊：焦点框跟着画成圆 / 胶囊
extension ConsoleIconButtonStyle: PadRingShaped { var padRingRadius: CGFloat { .infinity } }
extension ConsolePillButtonStyle: PadRingShaped { var padRingRadius: CGFloat { .infinity } }
extension ConsolePlayButtonStyle: PadRingShaped {   // 白底胶囊：贴边的奶油框看不见，改外扩 3 pt
    var padRingRadius: CGFloat { .infinity }
    var padRingOutset: CGFloat { 3 }
}
