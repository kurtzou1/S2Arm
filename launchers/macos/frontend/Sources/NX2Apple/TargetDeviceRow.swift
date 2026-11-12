// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

/// 目标设备一行（出包页、装机页同一份）：连着手机就按它优化、装也装到它；连着多台时列出来选；
/// 选过的那台不在线时如实说「它不在线」并让玩家改选连着的，不替玩家换成别的（11-11 玩家实报：续签时 iPad 被装上）。没连也可以选机型（不挡出包）。
struct TargetDeviceRow: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer

    private func x(_ id: String) -> String { BackendText.launcherText("export." + id, language: loc.lang == .zh ? "zh-Hans" : "en") }

    var body: some View {
        let device = model.selectedDevice
        let name = (device?["model"] as? String) ?? (device?["name"] as? String) ?? ""
        let many = model.connectedDevices.count > 1
        let offline = model.chosenDeviceOffline
        return HStack(spacing: 12) {
            LauncherRowIcon(offline ? "iphone.slash" : "iphone", color: offline ? LauncherPalette.danger : LauncherPalette.cream)
            Text(offline ? x("device.offline") : device == nil ? (model.deviceProbeError.map { loc.backend($0) } ?? x("device.none"))   // 读不到设备列表：说原因，不说没插（玩家反馈 11-11）
                 : many ? x("device.many") : x(device?["wired"] as? Bool == true ? "device.connected" : "device.connected_network").replacingOccurrences(of: "{0}", with: name))   // 只靠同一网络连着：明说
                .font(.manrope(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("device.status")
            Spacer(minLength: 12)
            // 连着两台以上（#272），或选过的那台不在线：列出连着的每台，选中的那台用于按机型优化和装到设备，记住到下次
            if many || (offline && !model.connectedDevices.isEmpty) {
                Picker(x("device.choose"), selection: Binding(get: { device?["id"] as? String }, set: { model.chosenDevice = $0 })) {
                    ForEach(Array(model.connectedDevices.enumerated()), id: \.offset) { _, d in
                        Text(deviceLabel(d)).tag(d["id"] as? String)
                    }
                }
                .labelsHidden().frame(width: 300).accessibilityIdentifier("export.device")
            }
            if device == nil, !offline, !model.targetModels.isEmpty {
                Picker(x("device.pick"), selection: $model.chosenModel) {
                    Text(x("device.default")).tag(String?.none)
                    ForEach(Array(model.targetModels.enumerated()), id: \.offset) { _, m in
                        Text(m["name"] as? String ?? "").tag(m["productType"] as? String)
                    }
                }
                .labelsHidden().frame(width: 190)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(LauncherPalette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 4)
        // 设备列表每 5 秒问一次（插拔手机、点信任后界面自己变过来），只在启动器在前台时问；切回来立刻问一次。
        //   剃刀 M17：原先切到别的程序也一直每 5 秒起一次设备探测（devicectl 子进程），同 M5 装机清单（32d91e49）
        .task { while !Task.isCancelled { if NSApp.isActive { await model.refreshTargets() }; try? await Task.sleep(nanoseconds: 5_000_000_000) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.refreshTargets() } }
    }

    /// 「名字 · 机型 · iOS 版本 · 有线 / 同一网络」
    private func deviceLabel(_ d: [String: Any]) -> String {
        let os = (d["os"] as? Int).map { "iOS \($0)" } ?? ""
        let link = d["wired"] as? Bool == true ? x("device.wired") : x("device.network")
        return [d["name"] as? String ?? "", d["model"] as? String ?? "", os, link].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
