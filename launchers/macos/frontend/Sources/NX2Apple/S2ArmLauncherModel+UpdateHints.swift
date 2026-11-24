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
    /// 黄字带「重新添加原件…」（#1961，作业 facts.action = relinkSource）；relinking = 正在核对选的原件；relinked = 已找回（随即自动排进整款重出）
    var relinkSource = false
    /// 上一次做完时作业要这款整款重出、原件在（facts.action = repack）：按钮下写「要整款重新出包」，并已自动排进批量出包
    var repack = false
    var relinking = false
    var relinked = false
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

    /// 黄字旁「重新添加原件…」（#1961）：选这款的原件 → import 作业只认这一款（expectGameId）→ 记下新位置；选错了说清楚、不改记录。
    ///   找回后接着从原件整款重出（repackWholeGame 排进批量出包，约几分钟到几十分钟），黄字换成「原件已找回，正在从原件整款重新出包」
    func relinkSource(_ game: GameSummary, source: URL) {
        let id = game.id.uppercased()
        guard var run = gameUpdates[id], !run.running, !run.relinking else { return }
        run.relinking = true; run.failure = nil
        gameUpdates[id] = run
        Task { [weak self] in
            guard let self else { return }
            var run = self.gameUpdates[id] ?? GameUpdateRun(running: false)
            do {
                try await self.provider.relinkSource(gameId: game.id, source: source)
                run.relinked = true; run.relinkSource = false
                self.refresh()
            } catch {
                run.failure = (error as? JobFailure)?.errorDescription ?? error.localizedDescription
            }
            run.relinking = false
            self.gameUpdates[id] = run
            // #1961：原件找回来了 → 接着从原件整款重出（玩家不必自己去找出包页）
            if run.relinked { self.repackWholeGame(game) }
        }
    }

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
                run.relinkSource = r.relinkSource
                run.repack = r.repack
                if r.reasons.isEmpty { self.updateHints[id] = nil } else { self.updateHints[id] = r.reasons }
            } catch {
                run.failure = (error as? JobFailure)?.errorDescription ?? error.localizedDescription
            }
            run.running = false
            run.progress.finish()
            self.gameUpdates[id] = run
            self.refreshUpdateHints()
            // #1961：作业说这款要整款重出、原件还在 → 当场排进整款重出，玩家不用再找别处
            if run.repack { self.repackWholeGame(game) }
        }
    }

    /// 要整款重新出包的那行字（按钮下）：这款的原因里有 hostAbi（宿主约定号变了、只换库不够），或上一次「更新这款」回了要整款重出
    func repackNoteNeeded(_ game: GameSummary) -> Bool {
        updateReasons(game).contains("hostAbi") || gameUpdate(game)?.repack == true
    }

    /// 把这款排进从原件整款重出（#1961）：复用「更新并重新出这几款」那条（update.confirm.repack → updatePhone(repack:) → phoneUpdateEnded 的 openBatch → createBatch），
    ///   不新造出包流程、不连手机：只出 iPhone 一份，不设 installAfterDevice / batchInstallAfter（出完不装到设备）。
    ///   弄不成（正在出别的批 / 正在玩）就把原因留在清单页上，不静默
    func repackWholeGame(_ game: GameSummary) {
        Task {
            openBatch([game.id])
            for i in batchDraft.indices { batchDraft[i].iphone = batchDraft[i].problem == nil; batchDraft[i].mac = false }
            if let reason = await createBatch() { batchError = reason }
        }
    }

    /// 原因 → 共享文案键（libGen = 库缺新代数内容，用着色器那条文案）（launchers/shared/experience.v1.json launcher.items，六种语言）；不认识的原因不显示
    static func updateReasonKey(_ reason: String) -> String? { BackendText.updateReasonKeys[reason] }   // 共享体验表 update_reasons（11-19 结构 9）
}
