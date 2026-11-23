// S2Arm（不是上游文件）：开发者证书签名的 Mac 一侧（v0.2.4，作业层 pack/jobs/devcert.py）。
//   出包页「签名方式」选 Apple ID 或「我的开发者证书」；证书导入后出包装机都用它签。
//   几张证书（#487）：按设备买的证书一台一张。导入了不止一张时，选中的设备（插线或经隧道连着、有 UDID）第一次在证书签名下出现、还没给它选过证书时，
//   弹窗问这台用哪张（或导入一张新的），记在作业层 devcert/state.json；之后这台装机 / 更新都用它，不再问。
//   体检里的问题只提示、不挡出包和装机；密码只经环境变量交给导入那一次作业，不写进请求文件。
import AppKit
import Foundation
import S2ArmAppleAdapter

/// 要问「这台用哪张证书」的那台设备（devCertChoice 非空 = 弹窗开着）
struct DevCertChoice: Identifiable, Equatable {
    let udid: String
    let name: String
    let status: DevCertStatus
    var id: String { udid }
}

extension S2ArmLauncherModel {
    /// 重读证书现况（出包页出现、换了手机、导入 / 删除之后）；按选中的手机判在不在设备列表
    ///   失败不吞（剃刀 M12）：读失败保留原值并报原因——原先当成「没导入」，切到证书签名时又弹导入窗
    func refreshDevCert() {
        Task { await reloadDevCert() }
    }

    func reloadDevCert() async {
        do { devCert = try await provider.devCertStatus(device: selectedDevice?["udid"] as? String); readOK("s2arm.fail.devCert") }
        catch { reportFailure("s2arm.fail.devCert", error, passive: true) }
    }

    /// 几张证书（#487）：证书签名开着、导入了不止一张时，不管在哪一页都每 5 秒看一次连着的设备（同出包页设备行的探测），新插上的那台没选过证书就弹窗。
    ///   出包页的设备行自己也在探测，两边都走 refreshTargets → askDevCertIfNew；Apple ID 签名、或只有一张证书（不会问）时不探测
    func devCertWatchLoop() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                guard let self else { return }
                guard NSApp.isActive else { continue }
                if self.devCert == nil { await self.reloadDevCert() }
                guard self.devCert?.active == true, (self.devCert?.certs.count ?? 0) > 1, self.devCertChoice == nil else { continue }
                await self.refreshTargets()
            }
        }
    }

    /// 设备探测之后（refreshTargets）：选中的那台插线 / 经隧道连着、有 UDID、本次启动没问过 → 问作业层要不要给它选证书，要就弹窗。
    ///   只靠同一 Wi-Fi 配对着的不算「连上」（离线也会列出来），不为它弹
    func askDevCertIfNew() async {
        guard devCertChoice == nil, !showDevCertImport, let d = selectedDevice, let udid = d["udid"] as? String, !udid.isEmpty,
              d["wired"] as? Bool == true || d["tunnel"] as? Bool == true, !devCertAsked.contains(udid) else { return }
        devCertAsked.insert(udid)
        guard let st = try? await provider.devCertStatus(device: udid) else { devCertAsked.remove(udid); return }
        if !st.active { devCertAsked.remove(udid); return }   // Apple ID 签名时不问；之后切到证书签名再问
        if st.needsChoice { devCertChoice = DevCertChoice(udid: udid, name: d["name"] as? String ?? "", status: st) }
    }

    /// 出包页「换这台的证书…」：不管选没选过都弹
    func openDevCertChoice() {
        guard let d = selectedDevice, let udid = d["udid"] as? String, !udid.isEmpty else { return }
        Task {
            do { devCertChoice = DevCertChoice(udid: udid, name: d["name"] as? String ?? "", status: try await provider.devCertStatus(device: udid)) }
            catch { reportFailure("s2arm.fail.devCert", error) }
        }
    }

    /// 给这台选定一张；失败回原因句（弹窗里显示）
    func chooseDevCert(_ entry: String, for udid: String) async -> String? {
        do { try await provider.devCertChoose(device: udid, cert: entry) } catch { return error.localizedDescription }
        devCertChoice = nil
        await reloadDevCert()
        return nil
    }

    /// 导入：成功即切到证书签名，回 nil；失败回原因句、失败码和给证书发放人的话（弹窗里显示；码 / 那段话决定同一页给不给出路按钮）。
    ///   只选了 .p12（profile 空，#2015）成了：交给 Apple ID 签名沿用这张证书，回那句说明、adopted = true（弹窗留着显示，不是失败）
    ///   add = true：加一张，只有选证书窗给 device（顺手给那台选它）——出包页「再导入一张」不带设备，不改任何一台的选择；
    ///   false = 旧义「换一个」：顶掉选中那台在用的
    func importDevCert(p12: String, profile: String, password: String, add: Bool = false, device: String? = nil) async -> (text: String, code: String?, request: String, adopted: Bool)? {
        do {
            let info = try await provider.devCertImport(p12: p12, profile: profile, password: password, device: add ? device : (device ?? selectedDevice?["udid"] as? String), add: add)
            if !info.adoptedMessage.isEmpty { return (info.adoptedMessage, nil, "", true) }
            if add, device != nil { devCertChoice = nil }
            await reloadDevCert()
            return nil
        } catch {
            let facts = (error as? JobFailure)?.outcome.failureDiagnostic?["facts"] as? [String: Any]
            return (error.localizedDescription, (error as? JobFailure)?.code, facts?["requestText"] as? String ?? "", false)
        }
    }

    /// 分发证书描述文件签不了游戏（devcert_distribution）的出路：签名方式切到 Apple ID，并直接打开 Apple ID 登录面板（host：挂在哪一层弹）
    func switchToAppleIdLogin(host: String) {
        setSignChoice("apple")
        openAppleLogin(host: host)
    }

    /// 出包页切签名方式：选证书但还没导入 → 先开导入弹窗（导入成功才算切过去）
    func setDevCertActive(_ on: Bool) {
        if on && devCert?.imported != true { showDevCertImport = true; return }
        Task {
            do { try await provider.devCertUse(on) } catch { reportFailure("s2arm.fail.devCertUse", error) }
            await reloadDevCert()
        }
    }

    /// 签名方式三选一（自签走查结构 6）：apple = Apple ID（在 S2Arm 里登录）；certificate = 我的证书（没导入先弹导入）；
    ///   external = 我自己用 AltStore / SideStore 签（S2Arm 不在电脑上签名，导出 .s2arm 不签、手机上用导入的证书签）。作业层 signModeSet 记下，之后导出照这个
    func setSignChoice(_ choice: String) {
        if choice == "certificate" && devCert?.imported != true { showDevCertImport = true; return }
        let mode = choice == "certificate" ? "devCert" : choice == "external" ? "external" : "appleId"
        Task {
            do { _ = try await provider.signModeSet(mode) } catch { reportFailure("s2arm.fail.devCertUse", error) }
            await reloadDevCert()
            refreshInstallMode()
        }
    }

    /// 删除：entry 给了只删这一张（几张证书时），nil = 全删
    func deleteDevCert(entry: String? = nil) {
        Task {
            do { try await provider.devCertDelete(cert: entry) } catch { reportFailure("s2arm.fail.devCertDelete", error) }
            await reloadDevCert()
        }
    }
}
