"""Xcode 的 iOS 平台组件自检与一键补（11-07 维护者：启动器零配置；pack/jobs/toolchain.py ios_platform / download_ios_platform）。
期望按 11-07 两台机器对照写死：本机 Xcode 26.6（iOS SDK 26.5，构建 23F81a）装了运行时 23F77 → 编得过；
gate-host 同版只装了 iOS 27.1 运行时（24A94425）→ xcodebuild 报「iOS 26.5 is not installed」。配套表（SDKToSimulatorIndexMapping.plist）里 23F81a 只配 23F77。"""
import plistlib
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

from jobcase import JobCase
from errors import RECOVERY, Failure, log_cause
import toolchain

REAL_RUN = subprocess.run

MINI_LINE = ("{ platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device, "
             "error:iOS 26.5 is not installed. Please download and install the platform from Xcode > Settings > Components. }")


class IosPlatform(JobCase):
    def setUp(self):
        super().setUp()
        self.mapping = self.root / "SDKToSimulatorIndexMapping.plist"
        self.mapping.write_bytes(plistlib.dumps([
            dict(sdkIdentifier="iphoneos26.5", sdkBuildUpdate="23F81a", simulatorBuildUpdate="23F77"),
            dict(sdkIdentifier="iphoneos26.5", sdkBuildUpdate="23F73", simulatorBuildUpdate="23F73"),
            dict(sdkIdentifier="iphoneos27.1", sdkBuildUpdate="24A94232", simulatorBuildUpdate="24A94425")]))
        self.sdk = ("26.5", "23F81a")
        self.runtimes = []          # [(版本, 构建号)]
        self.unready = set()        # 这些构建号存在、但 state 不是 Ready（下载完没注册）

    def _probe(self, c, args, timeout=15):
        if args[:3] == ["xcrun", "--sdk", "iphoneos"]:
            return True, self.sdk[0]
        if args[:2] == ["xcodebuild", "-version"]:
            return True, self.sdk[1]
        if "metal" in args:
            return True, "Apple metal version fixture"
        return True, "10.0.403"

    def _run(self, args, **kw):
        import json
        if list(args[:5]) == ["xcrun", "simctl", "runtime", "list", "-j"]:
            rows = {str(i): dict(version=v, build=b, state="Unusable" if b in self.unready else "Ready")
                    for i, (v, b) in enumerate(self.runtimes)}
            return subprocess.CompletedProcess(args, 0, json.dumps(rows), "")
        if list(args[:4]) == ["xcrun", "simctl", "list", "runtimes"]:
            rows = [dict(platform="iOS", isAvailable=b not in self.unready, version=v, buildversion=b) for v, b in self.runtimes]
            return subprocess.CompletedProcess(args, 0, json.dumps({"runtimes": rows}), "")
        return REAL_RUN(args, **kw)   # 其余（df 等）照真跑

    def judge(self):
        with patch.object(toolchain, "probe", self._probe), patch.object(toolchain, "SDK_SIM_MAPPING", self.mapping), \
             patch.object(toolchain.subprocess, "run", self._run):
            return toolchain.ios_platform(self.c)

    def test_mapped_runtime_decides(self):
        self.runtimes = [("27.1", "24A94425")]                       # gate-host 现场：只有 27.1
        self.assertEqual(self.judge()[:2], (False, "26.5"))
        self.runtimes = [("26.5", "23F77"), ("27.1", "24A94232")]   # 本机：有配套的 23F77
        self.assertEqual(self.judge()[:2], (True, "26.5"))
        self.runtimes = [("26.5", "23F73")]                         # 同版本号、但不是 23F81a 配的构建 → 按表判没装
        self.assertFalse(self.judge()[0])
        self.sdk = ("27.1", "24A94232"); self.runtimes = [("27.1", "24A94425")]   # gate-host 的 27.1：表里配得上
        self.assertTrue(self.judge()[0])

    def test_no_mapping_falls_back_to_version(self):
        self.mapping.unlink()
        self.runtimes = [("27.1", "24A94425")]
        self.assertFalse(self.judge()[0])
        self.runtimes = [("26.5", "23F77")]
        self.assertTrue(self.judge()[0])
        self.sdk = ("", ""); self.assertIsNone(self.judge()[0])   # 读不到 iOS SDK：不判（交「Xcode」那项）

    def test_preflight_item_and_one_click(self):
        developer = self.root / "Xcode.app/Contents/Developer"
        (developer / "usr/bin").mkdir(parents=True); (developer / "usr/bin/xcodebuild").touch()
        self.c.r["developerDir"] = str(developer)
        def checks():
            with patch.object(toolchain, "probe", self._probe), patch.object(toolchain, "SDK_SIM_MAPPING", self.mapping), \
                 patch.object(toolchain.subprocess, "run", self._run), patch.object(toolchain, "reader", return_value=Path("x.dll")), \
                 patch.object(toolchain, "input_interface", return_value=(True, "")), patch("platform.mac_ver", return_value=("26.0", (), "")):
                return {r["name"]: r for r in toolchain.preflight(self.c)["checks"]}
        self.runtimes = [("27.1", "24A94425")]
        miss = checks()["iOS 平台组件"]
        self.assertFalse(miss["ok"]); self.assertEqual(miss["action"], "downloadIosPlatform")
        self.assertEqual(miss["requiredFor"], ["ipa"])                     # 只挡打 iPhone 包，不挡 Mac 打包与启动
        self.assertEqual(miss["diagnostic"]["code"], "ios_platform_missing")
        self.assertIn("约 8 GB", miss["message"]); self.assertIn("iOS 26.5", miss["message"])
        self.runtimes = [("26.5", "23F77")]
        ok = checks()["iOS 平台组件"]
        self.assertTrue(ok["ok"]); self.assertIsNone(ok["action"]); self.assertNotIn("diagnostic", ok)

    def test_download_job_command_and_progress(self):
        seen, events = [], []
        self.runtimes = [("26.5", "23F77")]   # 下载完的运行时已就绪：收尾不等
        def run(args, on_line=None, **kw):
            seen.append([str(a) for a in args])
            for text in ("Downloading iOS 26.5 Simulator (23F77): 12.5%", "Downloading iOS 26.5 Simulator (23F77): 100%"):
                on_line(text)
        with patch.object(self.c, "run", run), patch.object(self.c, "emit", lambda *a, **k: events.append(k)), \
             patch.object(toolchain, "probe", self._probe), patch.object(toolchain, "SDK_SIM_MAPPING", self.mapping), \
             patch.object(toolchain.subprocess, "run", self._run):
            toolchain.download_ios_platform(self.c)
        self.assertEqual(seen, [["xcodebuild", "-downloadPlatform", "iOS", "-architectureVariant", "arm64"]])   # Apple 芯片只下 arm64 版（8.5 GB，不下 10.6 GB 通用版）
        self.assertEqual([e.get("done") for e in events if "done" in e], [12.5, 100.0])

    def _download_with_exits(self, exits):
        """假 xcodebuild：按次序给退出码，64 表示不认参数。"""
        seen = []
        self.runtimes = [("26.5", "23F77")]

        def run(args, on_line=None, **kw):
            seen.append([str(a) for a in args])
            self.c.last_rc = exits[len(seen) - 1]
            if self.c.last_rc:
                raise toolchain.Failure("用法帮助", code="tool_exit")
        with patch.object(self.c, "run", run), patch.object(self.c, "emit", lambda *a, **k: None), \
             patch.object(toolchain, "probe", self._probe), patch.object(toolchain, "SDK_SIM_MAPPING", self.mapping), \
             patch.object(toolchain.subprocess, "run", self._run):
            return seen, toolchain.download_ios_platform(self.c)

    def test_old_xcode_retries_without_architecture_variant(self):
        seen, result = self._download_with_exits([64, 0])
        self.assertEqual(seen, [["xcodebuild", "-downloadPlatform", "iOS", "-architectureVariant", "arm64"], ["xcodebuild", "-downloadPlatform", "iOS"]])
        self.assertEqual(result, {})

    def test_xcode_without_download_support_asks_to_update_not_usage_text(self):
        with self.assertRaises(toolchain.Failure) as caught:
            self._download_with_exits([64, 64])
        self.assertEqual(caught.exception.code, "xcode_sdk_too_old")
        self.assertIn("Xcode 更新到 26", str(caught.exception))
        self.assertNotIn("用法", str(caught.exception))

    def test_downloaded_but_unregistered_asks_for_recheck(self):
        self.runtimes = [("26.5", "23F77")]
        self.unready = {"23F77"}
        ok, ver, why, action = self.judge()
        self.assertFalse(ok); self.assertEqual(action, "recheck"); self.assertIn("还没就绪", why)

    def test_unreadable_runtime_list_is_not_judged(self):
        def fail(args, **kw):
            if "simctl" in args:
                raise subprocess.TimeoutExpired(args, 60)
            return REAL_RUN(args, **kw)
        with patch.object(toolchain, "probe", self._probe), patch.object(toolchain, "SDK_SIM_MAPPING", self.mapping), \
             patch.object(toolchain.subprocess, "run", fail):
            self.assertIsNone(toolchain.ios_platform(self.c)[0])   # 读不到 ≠ 没装：不判，也不提示下载

    def test_download_progress_reports_bytes(self):
        events, calls = [], []

        def run(args, on_line=None, until=None, **kw):
            calls.append(until)
            on_line("Downloading iOS 26.5 Simulator (23F77) (arm64): 12.5% (1.02 GB of 8.32 GB)")
            on_line("Downloading iOS 26.5 Simulator (23F77) (arm64): 100.0% (8.32 GB of 8.32 GB)")
        self.runtimes = [("26.5", "23F77")]
        with patch.object(self.c, "run", run), patch.object(self.c, "emit", lambda *a, **k: events.append(k)), \
             patch.object(toolchain, "probe", self._probe), patch.object(toolchain, "SDK_SIM_MAPPING", self.mapping), \
             patch.object(toolchain.subprocess, "run", self._run):
            toolchain.download_ios_platform(self.c)
        self.assertTrue(calls and calls[0] is not None)                    # 交给 run 的「就绪即结束」判据
        got = [e for e in events if "done" in e]
        self.assertEqual([e["unit"] for e in got], ["B", "B"])
        self.assertAlmostEqual(got[0]["done"], 1.02e9); self.assertAlmostEqual(got[0]["total"], 8.32e9)
        self.assertAlmostEqual(got[-1]["done"], 8.32e9)

    def _progress_events(self, lines, download=toolchain.download_ios_platform):
        events = []

        def run(args, on_line=None, **kw):
            for text in lines:
                on_line(text)

        with patch.object(self.c, "run", run), patch.object(self.c, "emit", lambda *a, **k: events.append(k)), \
             patch.object(toolchain, "_sdk_platform", return_value=(False, "", "")), \
             patch.object(toolchain, "_wait_runtime_ready", return_value=True):
            download(self.c)
        return [e for e in events if "done" in e]

    def test_download_progress_decimal_comma_reports_bytes(self):
        for separator in (".", ","):
            for space in (" ", "\u00a0", "\u202f"):
                with self.subTest(separator=separator, space=space):
                    lines = [f"Downloading iOS Simulator: 46{separator}2{space}% (3{separator}63 GB of 7{separator}85 GB)",
                             f"Downloading iOS Simulator: 47{separator}1{space}% (3{separator}7 GB of 7{separator}85 GB)"]
                    got = self._progress_events(lines)
                    self.assertEqual(len(got), 2)
                    self.assertEqual([e["unit"] for e in got], ["B", "B"])
                    self.assertAlmostEqual(got[0]["done"], 3.63e9)
                    self.assertAlmostEqual(got[1]["done"], 3.7e9)
                    self.assertAlmostEqual(got[0]["total"], 7.85e9)
                    self.assertAlmostEqual(got[1]["total"], 7.85e9)

    def test_download_progress_decimal_comma_percentage_only(self):
        got = self._progress_events(["Downloading: 46,2%", "Downloading: 47,1\u00a0%", "Downloading: 100%"])
        self.assertEqual([e["done"] for e in got], [46.2, 47.1, 100.0])
        self.assertEqual([e["total"] for e in got], [100.0] * 3)
        self.assertEqual([e["unit"] for e in got], ["%"] * 3)

    def test_metal_download_progress_decimal_comma(self):
        got = self._progress_events(["Downloading: 46,2%", "Downloading: 47,1\u00a0%", "Downloading: 100%"],
                                    toolchain.download_metal)
        self.assertEqual([e["done"] for e in got], [46.2, 47.1, 100.0])
        self.assertEqual([e["unit"] for e in got], ["%"] * 3)

    def _metal_download_fails(self, tail):
        """xcodebuild -downloadComponent 退出 70、日志末尾是 tail（诊断#f5eae9 三件的原文）→ 返回 download_metal 抛出的 Failure"""
        log = self.root / "dl.log"; log.write_text("Beginning asset download...\n" + tail, encoding="utf-8")
        def run(args, on_line=None, **kw):
            self.c.last_log = log
            raise Failure("下载 Metal 编译组件失败（退出码 70）：})", code="tool_exit")
        with patch.object(self.c, "run", run), patch.object(self.c, "emit", lambda *a, **k: None):
            with self.assertRaises(Failure) as e:
                toolchain.download_metal(self.c)
        return e.exception

    def test_metal_catalog_unreachable_gets_own_code(self):
        # 期望手写：两台 Mac（Xcode 27A266a / 27B47）原文「Failed fetching catalog … MetalToolchain」→ 码 metal_download_unreachable，
        #   上屏一句说「连不上苹果的组件服务器」，下一步里有 -importComponent 手动导入的办法；不再是「})」
        for build in ("27A266a", "27B47"):
            with self.subTest(build=build):
                f = self._metal_download_fails("xcodebuild: error: Failed fetching catalog for assetType (com.apple.MobileAsset.MetalToolchain), "
                                               "serverParameters ({\n    RequestedBuild = %s;\n})\n" % build)
                self.assertEqual(f.code, "metal_download_unreachable")
                self.assertIn("连不上苹果的组件服务器", str(f)); self.assertNotIn("})", str(f))
                self.assertIn("-importComponent MetalToolchain", RECOVERY["metal_download_unreachable"])

    def test_metal_download_xcode_plugin_broken_is_first_launch(self):
        # 期望手写：一台 Mac 原文「xcodebuild failed to load a required plug-in … -runFirstLaunch」（CoreSimulator 没装上）→ 码 xcode_setup_required
        f = self._metal_download_fails("Library not loaded: /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator\n"
                                       "xcodebuild failed to load a required plug-in. Ensure your system frameworks are up-to-date by running 'xcodebuild -runFirstLaunch'\n")
        self.assertEqual(f.code, "xcode_setup_required")

    def test_metal_download_unknown_failure_unchanged(self):
        # 期望手写：日志里没有认得的字样 → 原样抛 tool_exit，不猜
        self.assertEqual(self._metal_download_fails("something else went wrong\n").code, "tool_exit")

    def test_registration_error_does_not_redo_transfer_when_runtime_ready(self):
        def run(args, on_line=None, until=None, **kw):
            raise Failure("S2Arm 工具退出，当前阶段未完成。", code="tool_exit")
        self.runtimes = [("26.5", "23F77")]
        with patch.object(self.c, "run", run), patch.object(self.c, "emit", lambda *a, **k: None), \
             patch.object(toolchain, "probe", self._probe), patch.object(toolchain, "SDK_SIM_MAPPING", self.mapping), \
             patch.object(toolchain.subprocess, "run", self._run):
            self.assertEqual(toolchain.download_ios_platform(self.c), {})

    def test_tool_exit_without_runtime_still_fails(self):
        def run(args, on_line=None, until=None, **kw):
            raise Failure("S2Arm 工具退出，当前阶段未完成。", code="tool_exit")
        with patch.object(self.c, "run", run), patch.object(self.c, "emit", lambda *a, **k: None), \
             patch.object(toolchain, "probe", self._probe), patch.object(toolchain, "SDK_SIM_MAPPING", self.mapping), \
             patch.object(toolchain.subprocess, "run", self._run), patch.object(toolchain, "IOS_PLATFORM_REGISTER_WAIT", 0):
            with self.assertRaises(Failure):
                toolchain.download_ios_platform(self.c)

    def test_xcodebuild_text_classified_and_recovery(self):
        self.assertEqual(log_cause([("ensure_profile", MINI_LINE)])[0], "ios_platform_missing")
        self.assertIn("一键下载", RECOVERY["ios_platform_missing"])


if __name__ == "__main__":
    unittest.main()
