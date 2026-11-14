// S2Arm（不是上游文件）：游戏库结构 v3「查」：每款四项大小（catalog sizes，作业收尾量好的，不现场量）与存储总览（storageOverview 作业）。
// 四项大小显示在游戏库「更多」菜单顶上；总览是「释放空间」页的第二页：各存放位置的 S2Arm 占用 / 剩余 / 总量、公共文件、各款大小。
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

private func size(_ bytes: Int64) -> String { FreeSpaceView.size(bytes) }

/// 一款的四项大小 + 原件（共用的按款数平摊）。没量过显示「未统计」。
struct GameSizesList: View {
    @EnvironmentObject var loc: Localizer
    let sizes: GameSizes
    var compact = false

    private func t(_ id: String) -> String { BackendText.launcherText("library.sizes." + id, language: loc.lang == .zh ? "zh-Hans" : "en") }

    static func rows(_ s: GameSizes) -> [(id: String, bytes: Int64)] {
        [("imageMac", s.imageMac), ("imageIos", s.imageIos), ("saves", s.saves), ("cache", s.cache), ("sources", s.sources)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            ForEach(Self.rows(sizes), id: \.id) { row in
                HStack {
                    Text(t(row.id)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(sizes.measured || row.id == "sources" ? size(row.bytes) : "-").monospacedDigit()
                }
                .help(row.id == "sources" ? t("sourcesNote") : "")
            }
            if !sizes.measured {
                Text(t("unmeasured")).font(.manrope(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.manrope(compact ? 12 : 13))
    }
}

/// 存储总览：进来先起一次 storageOverview（作业层会补量没量过的款）。
struct StorageOverviewSection: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer

    private func t(_ id: String) -> String { BackendText.launcherText("storage." + id, language: loc.lang == .zh ? "zh-Hans" : "en") }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let error = model.overviewError {
                Text(loc.backend(error)).font(.manrope(12)).foregroundStyle(LauncherPalette.danger).fixedSize(horizontal: false, vertical: true)
            }
            if let o = model.overview {
                CardGroup(t("locations")) {
                    ForEach(o.locations) { l in
                        // 行首给具体路径（不再给卷名、路径缩到副行）：几行都叫「系统盘」分不清（名字同出包页下拉框 locationName）
                        CardRow(S2ArmLauncherModel.locationName(path: l.path, volume: l.volume), detail: detail(l), dot: l.connected ? LauncherPalette.ready : LauncherPalette.unbuilt) {
                            Text(l.isDefault ? t("location.default") : "").font(.manrope(12)).foregroundStyle(.secondary)
                        }
                        if l.id != o.locations.last?.id { CardDivider() }
                    }
                }
                CardGroup(t("shared")) {
                    ForEach(o.shared) { part in
                        CardRow(t("shared." + part.id)) {
                            Text(size(part.bytes)).font(.manrope(13, .semibold)).monospacedDigit()
                        }
                        if part.id != o.shared.last?.id { CardDivider() }
                    }
                }
                CardGroup(t("games"), footnote: BackendText.launcherText("library.sizes.sourcesNote", language: loc.lang == .zh ? "zh-Hans" : "en")) {
                    ForEach(o.games) { g in
                        // 与 CardRow 同一套边距（18 + 圆点位 7 + 间距 12），游戏名和上面两张卡的行标题、分隔线对齐。
                        HStack(alignment: .top, spacing: 12) {
                            Color.clear.frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(g.name).font(.manrope(14, .semibold)).fixedSize(horizontal: false, vertical: true)
                                GameSizesList(sizes: g.sizes, compact: true)
                            }
                        }
                        .padding(.horizontal, 18).padding(.vertical, 13)
                        if g.id != o.games.last?.id { CardDivider() }
                    }
                }
            } else if model.overviewLoading {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(t("loading")).foregroundStyle(.secondary) }
            }
        }
        .onAppear { model.loadOverview() }
    }

    private func detail(_ l: StorageOverview.Location) -> String {
        guard l.connected, let free = l.freeBytes, let total = l.totalBytes else { return t("location.offline") }
        return t("location.usage").replacingOccurrences(of: "{0}", with: size(l.usedBytes ?? 0))
            .replacingOccurrences(of: "{1}", with: size(free)).replacingOccurrences(of: "{2}", with: size(total))
    }
}
