#!/usr/bin/env python3
"""一包通用（10-30 维护者）：出 iPhone 包不要目标设备（pack/jobs/ipa.py resolve_target）。
   新用例单独成文件（列车线 10-30：公用大测试文件人人往里加，合入时互相冲突）。"""
import unittest
from unittest.mock import patch

from jobcase import JobCase
from core import Failure
import ipa
import target


class DirectTargetOptional(JobCase):

    def test_direct_pack_target_is_optional(self):
        """一包通用（10-30）：不要目标设备；SDK 比目标旧不拦；目标装不了照旧拦"""
        self.c.r.pop("target", None)
        for devices in ([], [dict(gpuArch="applegpu_g17p", os=26), dict(gpuArch="applegpu_g18p", os=27)]):
            with self.subTest(devices=devices), patch.object(target, "connected", return_value=devices):
                self.assertIsNone(ipa.resolve_target(self.c))
        with patch.object(target, "connected", side_effect=target.TargetError("probe broke", code="target_unsupported")):
            self.assertIsNone(ipa.resolve_target(self.c))
        self.c.r["target"] = dict(model="fixture", gpuArch="applegpu_g18p", os=27)
        with patch.object(target, "os_choices", return_value=[26]):
            self.assertEqual(ipa.resolve_target(self.c)["os"], 27)
        self.c.r["target"] = dict(model="fixture", gpuArch="applegpu_g17p", os=17)
        with patch.object(target, "os_choices", return_value=[27]), patch.object(self.c, "diagnostic") as warn:   # 目标装不了也照出包、提醒一句（11-13）
            self.assertEqual(ipa.resolve_target(self.c)["os"], 17)
        self.assertEqual(warn.call_args.kwargs["code"], "target_unsupported")

    def test_unknown_gpu_does_not_block(self):
        """诊断 D-6FTP：玩家的 iPhone19,7 比所用 Xcode 的设备特征库新，前端带来的目标 gpuArch 为空。期望手写：
        不拦、照常出包，交回请求里的目标（地址窗口提示只读 os = 27）"""
        self.c.r["target"] = dict(model="iPhone 4", productType="iPhone19,7", gpuArch="", os=27)
        with patch.object(target, "os_choices", return_value=[26]):
            self.assertEqual(ipa.resolve_target(self.c), dict(model="iPhone 4", productType="iPhone19,7", gpuArch="", os=27))


if __name__ == "__main__":
    unittest.main()
