// S2Arm（不是上游文件）：补丁打入结果（11-14 维护者：哪些打上了、哪些没打上和为什么；出包完成页、更新 iPhone / 自签导出完成页都列，不影响成败）。
//   数据来自作业层 pack/jobs/patches.py outcome / record：applied = [{id, cat, name}]，failed = [{id, cat, name, why（文案键 result.why.*）}]，
//   error = 整款没打成（改写器在这款上出错等）→「不匹配，补丁打入失败」
import SwiftUI
import NXCore
import NXLauncher

struct SGradeOutcome: Equatable {
    struct Item: Equatable { let cat: String, name: String, why: String }
    var applied: [Item] = []
    var failed: [Item] = []
    var error = ""
    var cheats = 0   // 随包金手指条数（不逐条列：一款几十条；默认关、进游戏后逐条开）
    init() {}
    init(_ raw: [String: Any]) {
        func items(_ k: String) -> [Item] {
            (raw[k] as? [[String: Any]] ?? []).map { Item(cat: $0["cat"] as? String ?? "", name: $0["name"] as? String ?? "", why: $0["why"] as? String ?? "") }
        }
        applied = items("applied"); failed = items("failed"); error = raw["error"] as? String ?? ""
        cheats = (raw["cheats"] as? NSNumber)?.intValue ?? 0
    }
    var isEmpty: Bool { applied.isEmpty && failed.isEmpty && error.isEmpty && cheats == 0 }
    var hasProblem: Bool { !failed.isEmpty || !error.isEmpty }
}

struct SGradeGameResult: Equatable { let name: String; let outcome: SGradeOutcome }

/// 一款或几款（或一款的 Mac / iPhone 两端）的结果；多份时每份前面写名字
struct SGradeResultView: View {
    let results: [SGradeGameResult]
    let text: (String) -> String

    private func cat(_ c: String) -> String { text("export.sgrade.cat." + (["widescreen", "fps", "gfx", "cheat"].contains(c) ? c : "gfx")) }

    var body: some View {
        let shown = results.filter { !$0.outcome.isEmpty }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(text("sgrade.result.title")).font(.manrope(15, .semibold))
                ForEach(Array(shown.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 6) {
                        if shown.count > 1 { Text(r.name).font(.manrope(13.5, .semibold)) }
                        if !r.outcome.error.isEmpty {
                            row("xmark.circle.fill", .orange, text("sgrade.result.error"))
                        }
                        if !r.outcome.applied.isEmpty {
                            row("checkmark.circle.fill", SGradeCardView.gold, text("sgrade.result.applied") + r.outcome.applied.map { "\(cat($0.cat)) · \($0.name)" }.joined(separator: "、"))
                        }
                        if r.outcome.cheats > 0 {
                            row("checkmark.circle.fill", SGradeCardView.gold, text("export.sgrade.hit.cheat").replacingOccurrences(of: "{0}", with: "\(r.outcome.cheats)"))
                        }
                        ForEach(Array(r.outcome.failed.enumerated()), id: \.offset) { _, f in
                            row("exclamationmark.triangle.fill", .orange, text("sgrade.result.failed")
                                .replacingOccurrences(of: "{0}", with: f.name).replacingOccurrences(of: "{1}", with: cat(f.cat))
                                .replacingOccurrences(of: "{2}", with: text("sgrade." + f.why)))
                        }
                    }
                }
                Text(text("sgrade.result.note")).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
            .accessibilityIdentifier("result.sgrade")
        }
    }

    private func row(_ symbol: String, _ color: Color, _ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 12, weight: .semibold))
            Text(s).font(.manrope(13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
