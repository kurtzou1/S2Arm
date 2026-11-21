// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import S2ArmAppleAdapter

/// 「更新这款」的进度与结果（一款一份）：running 时详情区按钮画进度；做完 incomplete = 作业层 update_incomplete 的玩家句（黄字列在按钮下）、failure = 没做成的原因
struct GameUpdateRun: Equatable {
    var running = true
    var progress = JobProgress()
    var incomplete: [String] = []
    var failure: String?
}

/// 详情区「更新」按钮的三种样子：没做过 iPhone 版不显示；做过、没有原因 → 灰色「无需更新」；有原因 → 主色「更新这款」+ 橙色原因行
enum UpdateButtonState: Equatable { case hidden, upToDate, update([String]) }

/// 0.6.0「建议更新」：启动器打开、出包 / 手机作业做完时快速比对（作业 updateHints，只读指纹），对不上的款封面出角标、详情区写原因。
/// 0.6.4「更新这款」只在电脑上做（作业 updateGame）：按原因做齐这一款，不找设备、不推、不二次确认；推到设备只走「导出」（S2ArmLauncherModel+ExportSheet）
extension S2ArmLauncherModel {
    func refreshUpdateHints() {
        Task {
            // 读不到不弹框（附带的提示，不是玩家点的操作），但不吞：原因记日志，提示清空、界面照旧
            do { updateHints = try await provider.updateHints() ?? [:] }
            catch { updateHints = [:]; NSLog("S2Arm updateHints: %@", String(describing: error)) }
        }
    }

    /// 这款对不上的原因（空 = 不用提示）
    func updateReasons(_ game: GameSummary) -> [String] { updateHints[game.id.uppercased()] ?? [] }

    /// 详情区更新按钮：判据只看做没做过 iPhone 版（iphoneReady）和 updateHints 的原因——updateHints 只判做过 iPhone 版的款
    func updateButton(_ game: GameSummary) -> UpdateButtonState {
        guard game.iphoneReady else { return .hidden }
        let reasons = updateReasons(game)
        return reasons.isEmpty ? .upToDate : .update(reasons)
    }

    func gameUpdate(_ game: GameSummary) -> GameUpdateRun? { gameUpdates[game.id.uppercased()] }

    /// 点「更新这款」：起 updateGame 作业（不占作业槽：只在电脑上做这一款，同款的出包 / 推送在跑时按钮置灰）。
    ///   做完按结果的 reasons 当场改这款的提示（空 = 变「无需更新」），再重读一次 updateHints；做不齐的项（update_incomplete）列黄字、不当失败
    func updateGame(_ game: GameSummary) {
        let id = game.id.uppercased()
        guard game.iphoneReady, gameUpdates[id]?.running != true else { return }
        gameUpdates[id] = GameUpdateRun()
        let sink = EventSink { [weak self] event in
            guard let self, var run = self.gameUpdates[id], run.running else { return }
            run.progress.ingest(event)
            self.gameUpdates[id] = run
        }
        Task { [weak self] in
            guard let self else { return }
            var run = self.gameUpdates[id] ?? GameUpdateRun()
            do {
                let r = try await self.provider.updateGame(gameId: game.id, events: sink)
                run.incomplete = r.incomplete
                if r.reasons.isEmpty { self.updateHints[id] = nil } else { self.updateHints[id] = r.reasons }
            } catch {
                run.failure = (error as? JobFailure)?.errorDescription ?? error.localizedDescription
            }
            run.running = false
            run.progress.finish()
            self.gameUpdates[id] = run
            self.refreshUpdateHints()
        }
    }

    /// 原因 → 共享文案键（libGen = 库缺新代数内容，用着色器那条文案）（launchers/shared/experience.v1.json launcher.items，六种语言）；不认识的原因不显示
    static func updateReasonKey(_ reason: String) -> String? { BackendText.updateReasonKeys[reason] }   // 共享体验表 update_reasons（11-19 结构 9）
}
