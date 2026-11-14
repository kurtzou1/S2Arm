// S2Arm（不是上游文件）：顶栏手柄按钮与弹窗：连接状态、手动连接 / 断开、三个持久化开关。
import SwiftUI
import AppKit
import NXCore
import NXModel
import NXLauncher

struct Switch2ProConnectionPopover: View {
    @ObservedObject var controller: NS2LauncherController
    @ObservedObject var systems: SystemControllers
    let simplifiedChinese: Bool

    private var zh: Bool { simplifiedChinese }
    @State private var keyMonitor: Any?   // 分配中收键盘按键（键盘登记成一位玩家）

    private func unitGlyph(_ unit: PlayerAssignment.Unit) -> ControllerIcon.Glyph {
        switch unit {
        case .pair: return .pairHead
        case .single(_, let kind), .whole(_, let kind): return ControllerIcon.player(kind: kind) ?? .unknown
        case .system(let name, _): return ControllerIcon.systemPlayer(systems.pads.first { $0.name == name }?.family ?? .other)
        case .keyboard: return .keyboard
        case let .gen1(_, side): return side == 0 ? .gen1LeftSideways : .gen1RightSideways
        case .gen1Pair: return .gen1Pair
        }
    }
    private func unitName(_ unit: PlayerAssignment.Unit) -> String {
        switch unit {
        case .pair: return NS2LauncherController.title(kind: 4, simplifiedChinese: zh)
        case .single(_, let kind), .whole(_, let kind): return NS2LauncherController.title(kind: kind, simplifiedChinese: zh)
        case .system(let name, _): return name
        case .keyboard: return zh ? "键盘" : "Keyboard"
        case let .gen1(_, side): return side == 0 ? "Joy-Con (L)" : "Joy-Con (R)"
        case .gen1Pair: return "Joy-Con (L/R)"
        }
    }

    /// 「玩家」列表 = 现在的分配（接上手柄自动排进来；PlayerAssignment.reconcile），最多 8 位
    private var playerRows: [(glyph: ControllerIcon.Glyph, name: String)] {
        controller.assignment.units.map { (unitGlyph($0), unitName($0)) }
    }

    // 照 #520 UI 稿（#520 UI 稿）：标题 → 状态下一句 → 两只怎么用 → 开关 + 主按钮 → 玩家
    var body: some View {
        let status = controller.status
        VStack(alignment: .leading, spacing: 16) {
            // 分配中只放分配块（#520 讨论：省面板高度）；Switch 2 手柄那块、蓝牙手柄那块完成 / 取消后再出来
            if !controller.assigning {
            HStack(spacing: 12) {
                ControllerIcon(glyph: ControllerIcon.header(kind: controller.kind, players: controller.players) ?? .unknown)
                    .frame(width: 48, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.title(simplifiedChinese: zh)).font(.manrope(22, .bold)).lineLimit(1).fixedSize(horizontal: true, vertical: false)   // 标题一行、不缩字、不截断
                    HStack(spacing: 8) {
                        Circle().fill(Color(nsColor: NS2LauncherController.dotColor(status))).frame(width: 9, height: 9)
                        Text(NS2LauncherController.statusText(status, simplifiedChinese: zh)).font(.manrope(15, .semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("controller.status")

            // 状态下面不写小字（「点「连接」开始」之类多余）；状态词与主按钮已经说清楚

            // 连着时：两个开关 + 主按钮在同一段（稿 panels.html）；没连 / 搜索 / 连接中 / 失败时只有主按钮（稿 status.html）
            let connected = status == .connected || status == .inUse
            let mainButton = Button(NS2LauncherController.mainButton(status, simplifiedChinese: zh)) { controller.mainAction() }
                .buttonStyle(PanelButtonStyle())
                .accessibilityIdentifier("controller.main-action")
            if connected {
                PanelSection {
                    ToggleRow(label: zh ? "开启 S2Arm 时自动连接" : "Connect when S2Arm opens",
                              isOn: Binding(get: { controller.autoConnectOnOpen }, set: { controller.setAutoConnectOnOpen($0) }))
                    ToggleRow(label: zh ? "关闭游戏后断开手柄" : "Disconnect when game closes",
                              isOn: Binding(get: { controller.disconnectAfterGame }, set: { controller.setDisconnectAfterGame($0) }))
                    // 连接 / 断开合并成一个（稿）：文字和动作跟状态走
                    mainButton
                }
            } else if !controller.assigning {   // 分配中下面有「取消 / 完成」，这里不放「停止」（按了会把正在登记的手柄断开）
                mainButton
            }

            // 系统手柄（#520 UI 稿 system.html）：一块——图、标题（一只写系统给的名字，太长一行截断、悬停看全名；多只写数量）、已连接、「打开蓝牙设置」
            if !systems.pads.isEmpty {
                let pads = systems.pads
                let title = pads.count == 1 ? pads[0].name : (zh ? "\(pads.count) 个蓝牙手柄" : "\(pads.count) Bluetooth controllers")
                let family = Set(pads.map(\.family)).count == 1 ? pads[0].family : .other   // 多只同一类用那一类的图，混着用通用手柄图
                PanelSection {
                    HStack(spacing: 12) {
                        ControllerIcon(glyph: ControllerIcon.system(family)).frame(width: 48, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.manrope(22, .bold)).lineLimit(1).truncationMode(.tail)   // 蓝牙手柄名字太长照截断（缩字太小），悬停看全名
                                .help(pads.map(\.name).joined(separator: "\n"))
                            HStack(spacing: 8) {
                                Circle().fill(Color(nsColor: NS2LauncherController.dotColor(.connected))).frame(width: 9, height: 9)
                                Text(NS2LauncherController.statusText(.connected, simplifiedChinese: zh)).font(.manrope(15, .semibold)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Button(zh ? "打开蓝牙设置" : "Open Bluetooth Settings") { SystemControllers.openBluetoothSettings() }
                        .buttonStyle(PanelButtonStyle())
                }
            }

            }

            // 玩家（#520 UI 稿）：平时是玩家列表 +「分配玩家」；分配中换成分配块（system.html 第 5 栏）
            if controller.assigning {
                VStack(alignment: .leading, spacing: 12) {   // 只剩这一块：上面不画分隔线
                    Text(zh ? "分配玩家" : "Assign players").font(.manrope(15, .semibold))
                    HStack(spacing: 8) {
                        HowToTile(title: zh ? "两只合并 / 整只手柄" : "Pair two / Full pad", keys: zh ? "同时按 L + R" : "Press L + R together")
                        HowToTile(title: zh ? "单只 Joy-Con" : "Single Joy-Con", keys: zh ? "同时按 SL + SR" : "Press SL + SR together")
                    }
                    VStack(spacing: 8) {
                        let units = controller.assignment.units
                        // 至少 4 行（同稿），登记到第 4 位起每多一位再露一行「等待中」，最多 8 行（同原机最多 8 位）
                        ForEach(0..<min(PlayerAssignment.maxPlayers, max(4, units.count + 1)), id: \.self) { i in
                            if i < units.count { PlayerRow(number: i + 1, glyph: unitGlyph(units[i]), name: unitName(units[i]), clearLabel: zh ? "清空" : "Clear") { controller.removePlayer(at: i) } }
                            else { WaitingRow(number: i + 1, label: zh ? "等待中" : "Waiting") }
                        }
                    }
                    HStack(spacing: 8) {
                        Button(zh ? "取消" : "Cancel") { controller.cancelAssign() }.buttonStyle(PanelButtonStyle())
                        Button(zh ? "完成" : "Done") { controller.finishAssign() }.buttonStyle(PanelButtonStyle(selected: true))
                    }
                }
                .onAppear {
                    systems.watchAssign { controller.registerSystem(name: $0, index: $1) }
                    systems.watchGen1 { id, side, gesture in controller.registerGen1(id: id, side: side, gesture: gesture) }
                    // 键盘：分配中按任一键就登记成下一位（#520 讨论，不加提示）；这一下吞掉，不给 S2Arm 别处当快捷键 / 不响提示音
                    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { _ in controller.registerKeyboard(); return nil }
                }
                .onDisappear {
                    systems.watchAssign(nil)
                    systems.watchGen1(nil)
                    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                    keyMonitor = nil
                }
            } else {
                let rows = playerRows
                if !rows.isEmpty || controller.allDevices.count + systems.pads.count >= 2 {
                PanelSection {
                    if !rows.isEmpty {
                        Text(zh ? "玩家" : "Players").font(.manrope(15, .semibold))
                        VStack(spacing: 8) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                PlayerRow(number: index + 1, glyph: row.glyph, name: row.name)   // 平时不给 ×，分配中才有
                            }
                        }
                        .accessibilityIdentifier("controller.players")
                    }
                    // 两只以上手柄才有得分配（一对 Joy-Con 算两只、蓝牙手柄也算）
                    if controller.allDevices.count + systems.pads.count >= 2 {
                        Button(zh ? "分配玩家" : "Assign players") { controller.startAssign() }
                            .buttonStyle(PanelButtonStyle())
                            .accessibilityIdentifier("controller.assign")
                    }
                }
                }
            }
        }
        .padding(20)
        .frame(width: 380)   // 比稿（340）宽一些：标题不会整行撑满
        .preferredColorScheme(.dark)
    }
}

// 稿里的 .sec：上面一条细线、内容间距 12
private struct PanelSection<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            content
        }
    }
}

// 稿里的 .row：左边一句、右边开关（没有副标题）
private struct ToggleRow: View {
    let label: String
    let isOn: Binding<Bool>
    var body: some View {
        HStack(spacing: 16) {
            Text(label).font(.manrope(15, .semibold))
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).toggleStyle(LauncherSwitchStyle()).labelsHidden().accessibilityLabel(label)
        }
    }
}

// 稿里的 .btn：整宽、#34312e 底、12% 白边、圆角 12
private struct PanelButtonStyle: ButtonStyle {
    var selected = false   // 稿里「完成」那颗：反白（--sel）
    func makeBody(configuration: Configuration) -> some View {
        let fill = selected ? Color(red: 0xf2 / 255, green: 0xea / 255, blue: 0xd8 / 255) : Color(red: 0x34 / 255, green: 0x31 / 255, blue: 0x2e / 255)
        return configuration.label
            .font(.manrope(15, .semibold))
            .foregroundStyle(selected ? Color(red: 0x1b / 255, green: 0x1a / 255, blue: 0x18 / 255) : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill.opacity(configuration.isPressed ? 0.7 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? fill : Color.white.opacity(0.12), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

// 稿里的 .howto：深底小格，上面一行粗体、下面按键说明
private struct HowToTile: View {
    let title: String
    let keys: String
    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.manrope(13, .semibold)).foregroundStyle(.primary)
            Text(keys).font(.manrope(12)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(red: 0x1f / 255, green: 0x1d / 255, blue: 0x1b / 255)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

// 稿里的 .prow.empty：还没人登记的那一位——虚线框、玩家灯、「等待中」
private struct WaitingRow: View {
    let number: Int
    let label: String
    var body: some View {
        HStack(spacing: 10) {
            Text("P\(number)").font(.manrope(12, .bold)).foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(playerLights(number)[i] ? Color(red: 0x7b / 255, green: 0xe0 / 255, blue: 0x1e / 255) : Color(red: 0x5a / 255, green: 0x57 / 255, blue: 0x53 / 255))
                        .frame(width: 7, height: 7)
                }
            }
            Text(label).font(.manrope(13, .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

// 玩家灯（同原机）：P1–P4 亮 1–4 格，P5–P8 是 ●○○● / ●○●○ / ●○●● / ○●●○
func playerLights(_ number: Int) -> [Bool] {
    switch number {
    case 1: return [true, false, false, false]
    case 2: return [true, true, false, false]
    case 3: return [true, true, true, false]
    case 4: return [true, true, true, true]
    case 5: return [true, false, false, true]
    case 6: return [true, false, true, false]
    case 7: return [true, false, true, true]
    case 8: return [false, true, true, false]
    default: return [false, false, false, false]
    }
}

// 「玩家」列表的一行，照 #520 UI 稿 .prow：P 号、四格玩家灯（亮到第 P 格）、40×27 的手柄图、名称
private struct PlayerRow: View {
    let number: Int
    let glyph: ControllerIcon.Glyph
    let name: String
    var clearLabel = ""
    var onClear: (() -> Void)?

    private static let fill = Color(red: 0x34 / 255, green: 0x31 / 255, blue: 0x2e / 255)
    private static let ledOn = Color(red: 0x7b / 255, green: 0xe0 / 255, blue: 0x1e / 255)
    private static let ledOff = Color(red: 0x5a / 255, green: 0x57 / 255, blue: 0x53 / 255)

    var body: some View {
        HStack(spacing: 10) {
            Text("P\(number)").font(.manrope(12, .bold)).foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(playerLights(number)[i] ? Self.ledOn : Self.ledOff).frame(width: 7, height: 7)
                }
            }
            ControllerIcon(glyph: glyph).frame(width: 40, height: 27)
            Text(name).font(.manrope(13, .semibold)).lineLimit(1).truncationMode(.tail).help(name)   // 列表里的名称太长照截断（悬停看全名）
            Spacer(minLength: 8)
            // 最右边一个小 ×：清空这一位；名字截断在它前面，不会盖住
            if let onClear {
                Button(action: onClear) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(clearLabel)
                .accessibilityLabel(clearLabel)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Self.fill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

