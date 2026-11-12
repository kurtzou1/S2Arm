import SwiftUI

package enum LauncherPalette {
    package static let background = Color(red: 0.055, green: 0.055, blue: 0.06)
    package static let surface = Color(red: 0.10, green: 0.10, blue: 0.11)
    package static let cream = Color(red: 1, green: 0.94, blue: 0.84)
    package static let ready = Color(red: 0.25, green: 0.84, blue: 0.47)
    package static let building = Color(red: 1, green: 0.78, blue: 0.24)
    package static let unbuilt = Color(red: 0.57, green: 0.58, blue: 0.61)
    package static let danger = Color(red: 1, green: 0.42, blue: 0.40)
}

/// 卡片行打头的图标（出包页「存放位置」、设备行、安装方式、证书……）：固定宽度的一列，图标在列里居中。
/// SF Symbols 各图标的固有宽度不同（externaldrive / iphone / signature），原先各行手写 HStack，同样的间距下文字起点各差几个点（v0.3.0 出包页维护者指出）
package struct LauncherRowIcon: View {
    package static let width: CGFloat = 22
    let symbol: String
    let color: Color
    package init(_ symbol: String, color: Color = LauncherPalette.cream) { self.symbol = symbol; self.color = color }
    package var body: some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .light)).foregroundStyle(color)
            .frame(width: Self.width, alignment: .center)
    }
}
