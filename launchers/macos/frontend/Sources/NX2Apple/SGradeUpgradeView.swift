// S2Arm（不是上游文件）：「S 级优化升级」页（v0.4.0 维护者：已经导出在 Mac 游戏库 / iPhone 上的游戏不用重出包就能用上 S 级优化）。
//   打开即查（作业 sgradeScan，pack/jobs/sgrade.py）：逐款找原始程序（存下的 → 解包缓存 → Mac 版 → 原件），按本地补丁库报这个版本能补什么；
//   分组显示：可升级 / 没有对应补丁 / 出包时选了不打入 / 没找到原始程序（要重新出包覆盖更新）。一款都升不了 → 只给「确认」。
//   Mac 不用操作（启动器打开时后台补、开游戏时兜底）；iPhone 两个按钮都走 installUpdate（只换程序、资源包不推），sgradeUpgrade 让壳已是本版也重组。
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct SGradeScanGame: Identifiable, Equatable {
    let id: String, name: String, program: String, total: Int, patches: [String: Int], iphone: Bool, off: Bool
    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? ""; name = d["name"] as? String ?? id; program = d["program"] as? String ?? "none"
        total = (d["total"] as? NSNumber)?.intValue ?? 0; iphone = d["iphone"] as? Bool ?? false; off = d["off"] as? Bool ?? false
        patches = (d["patches"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
    }
    var found: Bool { program != "none" }
}

struct SGradeUpgradeView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    @State private var games: [SGradeScanGame]?
    @State private var failure: String?

    var body: some View {
        let lang = loc.lang == .zh ? "zh-Hans" : "en"
        SGradeUpgradeBody(games: games, failure: failure, zh: loc.lang == .zh, busy: model.busy,
                          x: { BackendText.launcherText("sgrade.upgrade." + $0, language: lang) },
                          upgrade: { mode in model.updatePhone(acceptStale: false, repack: [], language: lang, mode: mode, sgradeUpgrade: true); dismiss() },
                          close: { dismiss() })
            .task { await scan() }
    }

    private func scan() async {
        do {
            let r = try await model.saveJob("sgradeScan", gameID: "")
            games = (r["games"] as? [[String: Any]] ?? []).map(SGradeScanGame.init)
        } catch { failure = error.localizedDescription }
    }
}

/// 页面本体（不碰模型，单测离屏出图用）：games == nil 为查找中
struct SGradeUpgradeBody: View {
    let games: [SGradeScanGame]?
    let failure: String?
    let zh: Bool
    let busy: Bool
    let x: (String) -> String
    let upgrade: (String) -> Void
    let close: () -> Void
    var sImage: NSImage = SGradeCardView.sGold

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: sImage).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 34, height: 34)
                Text(x("title")).font(.manrope(20, .bold))
                    .foregroundStyle(LinearGradient(colors: [SGradeCardView.goldHi, SGradeCardView.gold, SGradeCardView.rose], startPoint: .leading, endPoint: .trailing))
                Spacer()
            }
            content
        }
        .padding(26).frame(width: 560)
        .accessibilityIdentifier("sgrade.upgrade")
    }

    @ViewBuilder private var content: some View {
        if let failure {
            Text(failure).font(.manrope(13)).foregroundStyle(.secondary)
            okRow
        } else if let games {
            let found = games.filter(\.found)
            let yes = found.filter { $0.total > 0 && !$0.off }, no = found.filter { $0.total == 0 }, off = found.filter { $0.total > 0 && $0.off }
            let missing = games.filter { !$0.found }
            if found.isEmpty {
                Text(x("nothing")).font(.manrope(14)).fixedSize(horizontal: false, vertical: true)
                okRow
            } else if yes.isEmpty {
                if !no.isEmpty { Text(x("none")).font(.manrope(14)); list(no.map { ($0.name, "") }) }
                if !off.isEmpty { group(x("off"), off.map { ($0.name, "") }) }
                okRow
            } else {
                Text(x("found").replacingOccurrences(of: "{0}", with: String(found.count))).font(.manrope(14, .medium))
                let groups = VStack(alignment: .leading, spacing: 14) {
                    group(x("yes"), yes.map { ($0.name, gains($0)) }, gold: true)
                    if !no.isEmpty { group(x("no"), no.map { ($0.name, "") }) }
                    if !off.isEmpty { group(x("off"), off.map { ($0.name, "") }) }
                    if !missing.isEmpty { group(x("missing"), missing.map { ($0.name, "") }) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if games.count > 10 { ScrollView { groups }.frame(height: 300) } else { groups }   // 款多才滚动，少的直接排开
                Text(x("macNote")).font(.manrope(12.5)).foregroundStyle(.secondary)
                if yes.contains(where: \.iphone) {
                    Text(x("iphoneNote")).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(x("install")) { upgrade("install") }.buttonStyle(.borderedProminent).accessibilityIdentifier("sgrade.upgrade.install")
                        Button(x("export")) { upgrade("export") }.buttonStyle(.bordered).accessibilityIdentifier("sgrade.upgrade.export")
                        Spacer()
                        Button(x("close")) { close() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }.disabled(busy)
                } else {
                    okRow
                }
            }
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(x("scanning")).font(.manrope(13)).foregroundStyle(.secondary) }
        }
    }

    private func gains(_ g: SGradeScanGame) -> String {
        var parts: [String] = []
        if (g.patches["widescreen"] ?? 0) > 0 { parts.append(x("cat.widescreen")) }
        if (g.patches["fps"] ?? 0) > 0 { parts.append(x("cat.fps")) }
        if (g.patches["gfx"] ?? 0) > 0 { parts.append(x("cat.gfx")) }
        if let n = g.patches["cheat"], n > 0 { parts.append(x("cat.cheat").replacingOccurrences(of: "{0}", with: String(n))) }
        return parts.joined(separator: zh ? "、" : ", ")
    }

    private func group(_ title: String, _ rows: [(String, String)], gold: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.manrope(13, .semibold)).foregroundStyle(gold ? SGradeCardView.gold : .primary)
            list(rows)
        }
    }

    private func list(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline) {
                    Text(r.0).font(.manrope(13)).lineLimit(1)
                    Spacer(minLength: 12)
                    if !r.1.isEmpty { Text(r.1).font(.manrope(12)).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var okRow: some View {
        HStack { Spacer(); Button(x("ok")) { close() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
    }
}
