"""目标设备探测（pack/jobs/target.py）单测（从 test_error_recovery.py 拆出，10-26；夹具 jobcase.JobCase）。"""
import subprocess
import unittest
from unittest.mock import patch

from jobcase import JobCase
from core import Failure
import target


class TargetTests(JobCase):
    def test_connected_keeps_two_devices_with_same_arch_and_os(self):
        import diag
        self.c.r["developerDir"] = str(self.root / "synthetic-developer")
        # 两台实体设备恰好同架构 / 系统，不能按编译目标去重丢掉设备身份。
        devices = [
            dict(identifier=identity,
                 hardwareProperties=dict(reality="physical", platform="iOS",
                                         productType="iPhone18,2", udid=identity + "-udid"),
                 deviceProperties=dict(name=identity, osVersionNumber="27.1"),
                 connectionProperties=dict(tunnelState="connected"))
            for identity in ("synthetic-phone-a", "synthetic-phone-b")
        ]
        with patch.object(diag, "devicectl", return_value=(0, {"result": {"devices": devices}}, "")) as probe, \
             patch.object(target, "gpu_arch", return_value="applegpu_g18p"):
            rows = target.connected(self.c)
        probe.assert_called_once_with(self.c, "list", "devices", timeout=60)
        self.assertEqual([row["id"] for row in rows], ["synthetic-phone-a", "synthetic-phone-b"])
        self.assertEqual([row["udid"] for row in rows],
                         ["synthetic-phone-a-udid", "synthetic-phone-b-udid"])
        self.assertEqual([(row["gpuArch"], row["os"]) for row in rows],
                         [("applegpu_g18p", 27), ("applegpu_g18p", 27)])

    def test_connected_excludes_other_platforms_but_keeps_ios_and_ipados(self):
        import diag
        self.c.r["developerDir"] = str(self.root / "synthetic-developer")
        # 所有条目均为 physical 且已连通，拒绝项只能由平台判据排除。
        platforms = ("iOS", "iPadOS", "macOS", "tvOS", "watchOS", "")
        devices = [
            dict(identifier="synthetic-" + platform,
                 hardwareProperties=dict(reality="physical", platform=platform,
                                         productType="synthetic-model"),
                 deviceProperties=dict(name=platform, osVersionNumber="27.1"),
                 connectionProperties=dict(tunnelState="connected"))
            for platform in platforms
        ]
        with patch.object(diag, "devicectl", return_value=(0, {"result": {"devices": devices}}, "")) as probe, \
             patch.object(target, "gpu_arch", return_value="applegpu_g18p") as arch:
            rows = target.connected(self.c)
        probe.assert_called_once_with(self.c, "list", "devices", timeout=60)
        # 11-13：只排除物理上装不了的 Mac / 电视 / 手表；平台没写的照收（不按元数据猜着筛掉，装不装得上让装的那一步说）
        self.assertEqual([row["id"] for row in rows], ["synthetic-iOS", "synthetic-iPadOS", "synthetic-"])
        self.assertEqual(arch.call_count, 3)

    def test_vision_pro_kept_as_ipad_with_ios_equivalent_os(self):
        """Apple Vision Pro 按 iPad 兼容装（理论支持、未真机验证）：devicectl 报的 platform 没有公开资料，visionOS / xrOS / 没见过的写法
        只要机型号是 RealityDevice* 都收下；系统大版本按 iOS 口径（visionOS 2 → 18，26 原样），否则 visionOS 2 会被判低于下限 18"""
        import diag, install
        self.c.r["developerDir"] = str(self.root / "synthetic-developer")
        devices = [dict(identifier="vp-" + plat, hardwareProperties=dict(reality="physical", platform=plat, productType="RealityDevice14,1"),
                        deviceProperties=dict(name="我的 Vision Pro", osVersionNumber=ver), connectionProperties=dict(tunnelState="connected"))
                   for plat, ver in (("xrOS", "2.4"), ("visionOS", "26.1"), ("realityOS-unknown", "26.0"))]
        with patch.object(diag, "devicectl", return_value=(0, {"result": {"devices": devices}}, "")), \
             patch.object(target, "gpu_arch", return_value="applegpu_g14g"):
            rows = target.connected(self.c)
        self.assertEqual([(r["id"], r["os"]) for r in rows], [("vp-xrOS", 18), ("vp-visionOS", 26), ("vp-realityOS-unknown", 26)])
        self.assertEqual(install.device_kind(devices[0]), "iPad")
        self.assertTrue(diag.is_vision(rows[0]) and diag.is_mobile(rows[0]))

    def test_vision_pro_gpu_from_xros_traits(self):
        """GPU 架构：Vision Pro 的机型号只在 XROS.platform 的设备特征库（iPhone 平台库里只有「Apple Vision」家族占位 RealityFamily*）。
        合成两份库按 target.JOIN 的表结构，期望手写：RealityDevice14,1 → applegpu_g14g；iPhone 机型照旧查 iPhone 库"""
        import sqlite3
        dev = self.root / "synthetic-developer"
        def db(platform, rows):
            p = dev / f"Platforms/{platform}.platform/usr/standalone/device_traits.db"; p.parent.mkdir(parents=True, exist_ok=True)
            con = sqlite3.connect(p)
            con.executescript("create table Devices(ProductType, ProductDescription, Target); create table DeploymentVariant(DeviceTarget, DeviceTraitSet);"
                              "create table DeviceTraits(DeviceTraitSetID, GPUArchName);")
            for i, (pt, name, arch) in enumerate(rows):
                con.execute("insert into Devices values (?,?,?)", (pt, name, f"t{i}"))
                con.execute("insert into DeploymentVariant values (?,?)", (f"t{i}", i)); con.execute("insert into DeviceTraits values (?,?)", (i, arch))
            con.commit(); con.close()
        db("iPhoneOS", [("RealityFamily22,1", "Apple Vision", "applegpu_g14g"), ("iPhone18,2", "iPhone 17 Pro Max", "applegpu_g18p")])
        db("XROS", [("RealityDevice14,1", "Apple Vision Pro", "applegpu_g14g"), ("RealityDevice17,1", "Apple Vision Pro (M5)", "applegpu_g17g")])
        self.assertEqual(target.gpu_arch("RealityDevice14,1", str(dev)), "applegpu_g14g")
        self.assertEqual(target.gpu_arch("RealityDevice17,1", str(dev)), "applegpu_g17g")
        self.assertEqual(target.gpu_arch("iPhone18,2", str(dev)), "applegpu_g18p")

    def test_missing_reality_field_falls_back_to_physical_traits(self):
        """devicectl 缺 reality 字段（据报有 Xcode 测试版不再输出）：有硬件 UDID 且有配对 / 连接方式的照收，模拟器样（无 UDID、无配对）不收；
        有 reality 字段的照旧按它（simulated 不收）"""
        import diag
        self.c.r["developerDir"] = str(self.root / "synthetic-developer")
        devices = [
            dict(identifier="real-no-reality", hardwareProperties=dict(platform="iOS", productType="iPhone18,2", udid="U1"),
                 deviceProperties=dict(name="a", osVersionNumber="27.1"), connectionProperties=dict(pairingState="paired", transportType="wired", tunnelState="connected")),
            dict(identifier="sim-no-reality", hardwareProperties=dict(platform="iOS", productType="iPhone18,2"),
                 deviceProperties=dict(name="b", osVersionNumber="27.1"), connectionProperties=dict(tunnelState="connected")),
            # 诊断#091bcf：键在、值为 null（报告里只见 reality=None）——同缺键，按真机特征认
            dict(identifier="real-null-reality", hardwareProperties=dict(reality=None, platform="iOS", productType="iPhone18,2", udid="U4"),
                 deviceProperties=dict(name="d", osVersionNumber="27.1"), connectionProperties=dict(pairingState="paired", transportType="wired", tunnelState="disconnected")),
            dict(identifier="sim-with-reality", hardwareProperties=dict(reality="simulated", platform="iOS", productType="iPhone18,2", udid="U3"),
                 deviceProperties=dict(name="c", osVersionNumber="27.1"), connectionProperties=dict(pairingState="paired", tunnelState="connected")),
        ]
        with patch.object(diag, "devicectl", return_value=(0, {"result": {"devices": devices}}, "")), \
             patch.object(target, "gpu_arch", return_value="applegpu_g18p"):
            rows = target.connected(self.c)
        self.assertEqual([r["id"] for r in rows], ["real-no-reality", "real-null-reality"])

    def test_target_probe_preserves_error_code(self):
        with patch.object(target, "device_list", return_value=([], "", None, None)), \
             patch.object(target, "models", side_effect=target.TargetError("missing database", code="xcode_unavailable")):
            with self.assertRaises(Failure) as raised:
                target.probe(self.c)
        self.assertEqual(raised.exception.code, "xcode_unavailable")

    def test_target_probe_quick_skips_device_list(self):
        # quick：只给机型 / 系统静态表，不读连着的设备（出包页立刻能选机型；10-26 维护者：机型表等设备探测 61 秒）
        fixture = [dict(name="fixture", productType="iPhone18,2", gpuArch="applegpu_g18p")]
        self.c.r["quick"] = True
        with patch.object(target, "device_list", side_effect=AssertionError("quick 不该读设备")), \
             patch.object(target, "models", return_value=fixture), patch.object(target, "os_choices", return_value=[27, 26]):
            self.assertEqual(target.probe(self.c), dict(connected=[], connectedError="", models=fixture, osChoices=[27, 26]))   # quick 没读设备：不是读失败
        self.c.r.pop("quick")
        with patch.object(target, "device_list", return_value=(["raw"], "", None, None)) as seen, \
             patch.object(target, "_keep_device", lambda d: True), patch.object(target, "_row", lambda d, dev_dir, link: "dev"), \
             patch.object(target, "models", return_value=fixture), patch.object(target, "os_choices", return_value=[27]):
            self.assertEqual(target.probe(self.c)["connected"], ["dev"])   # 完整探测读设备列表（打桩，不碰真手机）
        seen.assert_called_once()

    def test_target_probe_survives_device_list_timeout(self):
        # devicectl 超时只丢「连着的设备」，可选机型与系统照常给（10-26 Spare-host：超时冲掉整个探测，机型 0 种）
        import diag
        fixture = [dict(name="fixture", productType="iPhone18,2", gpuArch="applegpu_g18p")]
        with patch.object(diag, "devicectl", side_effect=subprocess.TimeoutExpired(["xcrun", "devicectl"], 60)), \
             patch.object(target, "models", return_value=fixture), patch.object(target, "os_choices", return_value=[27, 26]):
            result = target.probe(self.c)
        self.assertEqual(result, dict(connected=[], connectedError="读取设备列表超时：解锁手机，重新插一次数据线再试。", models=fixture, osChoices=[27, 26]))   # 读失败要说出来，不当「没连」

    def test_min_os_is_18_metal3_range_accepted(self):
        # 期望（10-26 维护者：直连下限 iOS 18 / macOS 15，18–25 走 Metal 3 兼容路径）：A14（applegpu_g13p）+ iOS 18 能出包；iOS 17 拒、提示写「iOS 18」；A13（g12）拒
        ok = target.check(dict(gpuArch="applegpu_g13p", os=18, model="iPhone 12"))
        self.assertEqual(ok["os"], 18)
        with self.assertRaises(target.TargetError) as e:
            target.check(dict(gpuArch="applegpu_g13p", os=17, model="iPhone 12"))
        self.assertIn("iOS 18", str(e.exception))
        with self.assertRaises(target.TargetError):
            target.check(dict(gpuArch="applegpu_g12p", os=18, model="iPhone 11"))

    def test_os_choices_span_sdk_down_to_18(self):
        # 期望：所用 iOS SDK 27.1 → 可选系统 27、26 … 18 共 10 个（手算）
        with patch.object(target.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "27.1\n", "")):
            self.assertEqual(target.os_choices({}), list(range(27, 17, -1)))


if __name__ == "__main__":
    unittest.main()
