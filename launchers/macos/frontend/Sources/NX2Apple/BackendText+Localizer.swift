// S2Arm（不是上游文件）：作业层（pack/jobs）给的文字按界面语言显示。作业层只说中文原句（检查项名、阶段名、日志、报错），
// 翻译走适配层 BackendText（与旧启动器 L() 同一套对照表与共享体验文案），语言跟界面的 loc.lang：中文界面显示原句，其余显示英文。
import NXModel
import S2ArmAppleAdapter

extension Localizer {
    /// 报错页的「故障报修」指引（BackendText.reportHint，按界面语言）
    nonisolated var reportHint: String { BackendText.reportHint(language: lang == .zh ? "zh-Hans" : "en") }
    /// 一句作业层文字在当前界面语言下的显示。
    nonisolated func backend(_ text: String) -> String {
        BackendText.translate(text, language: lang == .zh ? "zh-Hans" : "en")
    }

    /// 作业页日志行：阶段行带「▸ 」前缀（S2ArmLauncherModel.ingest），前缀不进翻译。
    nonisolated func backendLine(_ line: String) -> String {
        line.hasPrefix("▸ ") ? "▸ " + backend(String(line.dropFirst(2))) : backend(line)
    }
}
