# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""P1-44: SDK 探测不能把失败当作 SDK 18；只用受控 subprocess，不需要 Xcode。"""
import contextlib
import io
import json
import subprocess
from unittest.mock import patch

from jobcase import JobCase
from core import Failure
import applenv
import ipa
import target

CMD = ["xcrun", "--sdk", "iphoneos", "--show-sdk-version"]


class SdkChoicesTests(JobCase):
    def test_valid_versions_and_invocation(self):
        env = {"DEVELOPER_DIR": "/synthetic/Xcode"}
        for raw, expected in (("18.0\n", [18]), ("27.1\n", [27, 26, 25, 24, 23, 22, 21, 20, 19, 18])):
            with self.subTest(raw=raw), patch.object(target.subprocess, "run", return_value=subprocess.CompletedProcess(CMD, 0, raw, "")) as run:
                self.assertEqual(target.os_choices(env), expected)
                run.assert_called_once_with(CMD, env=env, capture_output=True, text=True, timeout=60)

    def test_failure_boundaries(self):
        cases = [(subprocess.CompletedProcess(CMD, 7, "27.1", "first\nlast diagnostic\n"), "xcode_unavailable", "7", "last diagnostic")]
        for raw in ("", " \n", "garbage", "27.bad", "27.1\nextra", "-1", "27."):
            cases.append((subprocess.CompletedProcess(CMD, 0, raw, "invalid output\n"), "xcode_unavailable", "0", "invalid output"))
        cases.append((subprocess.CompletedProcess(CMD, 0, "17.4", "old sdk\n"), "xcode_sdk_too_old", "0", "old sdk"))
        cases.append((subprocess.TimeoutExpired(CMD, 60, stderr=b"first\ntimeout tail\n"), "xcode_unavailable", "未取得", "timeout tail"))
        cases.append((FileNotFoundError("synthetic missing xcrun"), "xcode_unavailable", "未启动", "synthetic missing xcrun"))
        for result, code, rc, tail in cases:
            with self.subTest(result=result), patch.object(target.subprocess, "run", **({"side_effect": result} if isinstance(result, Exception) else {"return_value": result})):
                with self.assertRaises(target.TargetError) as raised:
                    target.os_choices({})
                self.assertEqual(raised.exception.code, code)
                for text in (" ".join(CMD), "退出码", rc, "stderr", tail):
                    self.assertIn(text, str(raised.exception))

    def test_worker_callers_preserve_sdk_failure(self):
        self.c.r.update(developerDir="/synthetic/Xcode", quick=True, target=dict(model="fixture", gpuArch="applegpu_g18p", os=27))
        with patch.object(target, "models", return_value=[]), patch.object(target.subprocess, "run", return_value=subprocess.CompletedProcess(CMD, 9, "", "sdk rejected")):
            with self.assertRaises(Failure) as raised:   # 设备 / 机型探测（界面列表）照实报
                target.probe(self.c)
            self.assertEqual(raised.exception.code, "xcode_unavailable")
            self.assertIn("sdk rejected", str(raised.exception))
            # 出包读目标（预检清单 #42，11-13）：SDK 读不出不拦出包，目标原样交回；Xcode 真坏了由后面编 Metal 那一步按原文报
            self.assertEqual(ipa.resolve_target(self.c)["os"], 27)

    def test_applenv_reports_sdk_failure_in_json_and_text(self):
        def run(cmd, **kwargs):
            return subprocess.CompletedProcess(cmd, 8, "", "SDK probe refused") if cmd == CMD else subprocess.CompletedProcess(cmd, 0, "", "")
        for argv in (["--json"], []):
            output = io.StringIO()
            with self.subTest(argv=argv), patch.object(applenv, "context", return_value=(self.c, "/synthetic/Xcode")), patch.object(applenv.toolchain, "preflight", return_value={"checks": []}), patch.object(target.subprocess, "run", side_effect=run), patch.object(applenv.tempfile, "mkdtemp", return_value=str(self.root)), contextlib.redirect_stdout(output):
                self.assertEqual(applenv.main(argv), 1)
            self.assertIn("SDK probe refused", output.getvalue())
            if argv:
                result = json.loads(output.getvalue())
                self.assertIsNone(result["iosSdkMajor"])
                failure = next(c for c in result["checks"] if c.get("code") == "xcode_unavailable")
                self.assertFalse(failure["ok"])
                self.assertIn("ipa", failure["requiredFor"])
