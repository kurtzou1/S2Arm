// S2Arm（不是上游文件）：设置页「诊断码」一栏（#1449，作业层 pack/jobs/diagcode.py；同 Windows DiagCodeCard.cs）。
//   维护者在帖子里给的诊断码粘进来点「使用」：下次把那款推到 iPhone（或在这台 Mac 上开它）时生效一局，玩完自动失效。
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct DiagCodeView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @State private var code = ""
    @State private var said: String?
    @State private var failed = false
    @State private var working = false

    var body: some View {
        CardGroup(s("settings.diagCode")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(s("settings.diagCode.hint")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    TextField("S2A-DIAG1-…", text: $code).textFieldStyle(LauncherTextFieldStyle())
                        .accessibilityLabel(s("settings.diagCode")).accessibilityIdentifier("settings.diagCode.input")
                    Button(s("settings.diagCode.use")) { use() }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle()).disabled(working || code.isEmpty)
                        .accessibilityIdentifier("settings.diagCode.use")
                }
                if let said {
                    Text(loc.backend(said)).font(LauncherTheme.TypeStyle.detail).foregroundStyle(failed ? LauncherPalette.danger : .primary)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("settings.diagCode.result")
                }
            }
        }
    }

    private func s(_ id: String) -> String { BackendText.launcherText(id, language: loc.lang.sharedCode) }   // 共享体验表文案（同 Windows T）

    private func use() {
        working = true
        Task {
            do { said = try await model.provider.diagCodeSet(code); failed = false; code = "" }
            catch { said = error.localizedDescription; failed = true }
            working = false
        }
    }
}
