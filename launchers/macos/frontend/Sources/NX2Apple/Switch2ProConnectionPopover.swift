// S2Arm（不是上游文件）：顶栏手柄按钮与弹窗：连接状态、手动连接 / 断开、三个持久化开关。
import SwiftUI
import NXCore
import NXModel
import NXLauncher

struct Switch2ProConnectionPopover: View {
    @ObservedObject var controller: NS2LauncherController
    let simplifiedChinese: Bool

    private var zh: Bool { simplifiedChinese }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 20, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.title(simplifiedChinese: zh)).font(.manrope(17, .bold))
                    HStack(spacing: 7) {
                        Circle().fill(Color(nsColor: controller.buttonColor)).frame(width: 8, height: 8)
                        Text(controller.buttonStatus).font(.manrope(12.5, .semibold)).foregroundStyle(.secondary)
                    }
                }
            }

            Text(controller.detail)
                .font(.manrope(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().opacity(0.3)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(zh ? "开启 S2Arm 时自动连接手柄" : "Connect controller when S2Arm opens")
                        .font(.manrope(13.5, .semibold))
                    Text(zh ? "只在下次打开 S2Arm 时自动连接。" : "Used the next time S2Arm opens.")
                        .font(.manrope(11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { controller.autoConnectOnOpen },
                                         set: { controller.setAutoConnectOnOpen($0) }))
                    .toggleStyle(LauncherSwitchStyle())
                    .labelsHidden()
                    .accessibilityLabel(zh ? "开启 S2Arm 时自动连接手柄" : "Connect controller when S2Arm opens")
            }

            HStack(spacing: 10) {
                Button(controller.phase == .failed ? (zh ? "重新连接" : "Reconnect") : (zh ? "连接手柄" : "Connect")) {
                    if controller.phase == .failed { controller.retry() } else { controller.connectManually() }
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .frame(maxWidth: .infinity)
                .disabled(controller.hasConnectionProcess && controller.phase != .failed)

                Button(controller.hasConnectionProcess && controller.phase != .ready && controller.phase != .handedOff
                        ? (zh ? "取消连接" : "Cancel")
                        : (zh ? "断开连接" : "Disconnect")) {
                    controller.disconnectManually()
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .frame(maxWidth: .infinity)
                .disabled(!controller.hasConnectionProcess)
            }
            .accessibilityIdentifier("controller.manual-actions")

            Divider().opacity(0.3)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(zh ? "关闭游戏后自动断开手柄" : "Disconnect controller after closing the game")
                        .font(.manrope(13.5, .semibold))
                    Text(zh ? "关闭这个选项时，连接会继续保留。" : "Keep the controller connected when disabled.")
                        .font(.manrope(11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { controller.disconnectAfterGame },
                                         set: { controller.setDisconnectAfterGame($0) }))
                    .toggleStyle(LauncherSwitchStyle())
                    .labelsHidden()
                    .accessibilityLabel(zh ? "关闭游戏后自动断开手柄" : "Disconnect controller after closing the game")
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(zh ? "记住这台设备" : "Remember this device")
                        .font(.manrope(13.5, .semibold))
                    Text(zh ? "打开后长按 SYNC 连一次，之后按任一键重连；连过其他设备需重按 SYNC。"
                            : "Turn on, then connect once with SYNC; afterwards any button reconnects. After using another device, press SYNC again.")
                        .font(.manrope(11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { controller.rememberDevice },
                                         set: { controller.setRememberDevice($0) }))
                    .toggleStyle(LauncherSwitchStyle())
                    .labelsHidden()
                    .accessibilityLabel(zh ? "记住这台设备" : "Remember this device")
            }

            Text(controller.autoConnectOnOpen
                 ? (zh ? "未连接手柄时仍可直接开始游戏；游戏运行中重新连接后会自动接回。"
                       : "Play remains available without a controller. A running game picks the controller up again after reconnecting.")
                 : (zh ? "未连接手柄时仍可直接开始游戏；S2Arm 打开时不会自动搜索或弹窗。"
                       : "Play remains available without a controller. S2Arm does not scan or prompt when it opens."))
                .font(.manrope(11.3))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 350)
        .preferredColorScheme(.dark)
    }

}
