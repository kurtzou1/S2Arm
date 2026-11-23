// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation

extension S2ArmLauncherModel {
    /// 自动更新的后台作业失败不静默（0.5.0 候选验收）：每次失败写一行 <私有目录>/logs/phone-auto-update.log（诊断包收 logs/），带「连续第几次」；成功一次归零。同 Windows PhoneAutoUpdate.cs
    func notePhoneAuto(_ operation: String, _ failure: String?) {
        guard let failure else { phoneAutoFails[operation] = nil; return }
        let n = (phoneAutoFails[operation] ?? 0) + 1
        phoneAutoFails[operation] = n
        let dir = provider.client.environment.privateRoot.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("phone-auto-update.log")
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        let line = Data("\(stamp) \(operation) 失败（连续第 \(n) 次）：\(failure)\n".utf8)
        if let h = try? FileHandle(forWritingTo: file) { _ = try? h.seekToEnd(); try? h.write(contentsOf: line); try? h.close() }
        else { try? line.write(to: file) }
    }

    var phoneUpdatePercent: Int? {
        guard phoneBusy, !selfSigning, !shellFirstInstall,
              let phone = phoneSession, phone.kind == .installUpdate else { return nil }
        return Int(((phone.progress.overall ?? 0) * 100).rounded())
    }
}
