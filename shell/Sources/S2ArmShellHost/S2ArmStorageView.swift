// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import ShellUI
import SwiftUI

/// 设置 →「存储」：只看不删（S2ArmStorage 扫整个沙盒）。每款一行（游戏数据、存档分开写），其余几类各一行；删游戏在游戏的菜单里（已有的删除流程）
struct S2ArmStorageView: View {
    let names: [String: String]
    let root: URL
    @Environment(\.dismiss) private var dismiss
    @State private var report: S2ArmStorage.Report?
    @State private var failed = false

    private func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file) }
    private func otherTitle(_ id: String) -> String {
        switch id {
        case "cache": return shellText("Cache")
        case "application": return shellText("App settings and data")
        case "systemTemporary": return shellText("Temporary files")
        case "deleting": return shellText("Being deleted")
        case "trash": return shellText("Trash")
        default: return shellText("Other")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let report {
                    let (games, others) = S2ArmStorage.rows(report)
                    Section {
                        LabeledContent(shellText("Total"), value: bytes(report.allocatedBytes))
                        if report.incomplete {
                            Text(shellText("Some folders could not be read, so the total may be a little low.")).font(.footnote).foregroundStyle(.orange)
                        }
                    } footer: {
                        Text(shellText("Space used by S2Arm's data on this device, not counting the app itself. To free space, delete a game from its menu in the library."))
                    }
                    if !games.isEmpty {
                        Section(shellText("Games")) {
                            ForEach(games) { row in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(names[row.id] ?? row.id)
                                    Text(detail(row)).font(.footnote).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    if !others.isEmpty {
                        Section(shellText("Other data")) {
                            ForEach(others) { item in LabeledContent(otherTitle(item.id), value: bytes(item.allocatedBytes)) }
                        }
                    }
                } else if failed {
                    Text(shellText("Could not read the app's data. Try again later."))
                } else {
                    ProgressView(shellText("Calculating…"))
                }
            }
            .navigationTitle(shellText("Storage"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(shellText("Done")) { dismiss() } } }
            .task {
                let root = root
                let got = await Task.detached(priority: .utility) { try? S2ArmStorage.scan(root: root) }.value
                if let got { report = got } else { failed = true }
            }
        }
    }

    private func detail(_ row: S2ArmStorage.GameRow) -> String {
        var parts = [shellText("Game data \(bytes(row.game))"), shellText("Saves \(bytes(row.saves))")]
        if row.incoming > 0 { parts.append(shellText("Still arriving \(bytes(row.incoming))")) }
        return parts.joined(separator: " · ")
    }
}
