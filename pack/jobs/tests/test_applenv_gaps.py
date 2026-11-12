# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""#449：applenv.py 全绿、一键出包却红的几处——.NET SDK 版本、iOS SDK 主版本、改写器固定依赖、cmake / ninja / meson / GNU Make、共享字体的 Python。
合成环境：假 xcrun 版本、假 dotnet 列表、假解释器目录（一键出包会放到 PATH 最前），不要 Xcode / .NET / Homebrew。"""
import contextlib
import io
import json
import os
import subprocess
from pathlib import Path
from unittest.mock import patch

from jobcase import JobCase, ROOT
import applenv
import ipa
import target

XCRUN = ["xcrun", "--sdk", "iphoneos", "--show-sdk-version"]
REAL_RUN = subprocess.run


class ApplenvGapTests(JobCase):
    def setUp(self):
        super().setUp()
        self.venv = self.root / "venv/bin"
        self.venv.mkdir(parents=True)
        # 什么都能 import 的假解释器：只有按 S2A_PYTHON 查才会绿（PATH 上的 python3 没有 fontTools / pathops）
        self.tool("python3", "exit 0")
        self.deps = self.root / "deps"
        (self.deps / "capstone-5.0.7/src").mkdir(parents=True)
        (self.deps / "capstone-5.0.7/src/CMakeLists.txt").write_text("")
        (self.deps / "lz4-4.4.5/lz4libs").mkdir(parents=True)
        (self.deps / "lz4-4.4.5/lz4libs/lz4.c").write_text("")
        self.bare = self.root / "bare"
        self.bare.mkdir()
        for name in ("bash", "tail", "head"):   # PATH 只留跑 tools/gmake.sh 要的几样，cmake / ninja / meson / gmake 只在假解释器目录里
            os.symlink(next(Path(d) / name for d in ("/bin", "/usr/bin") if (Path(d) / name).exists()), self.bare / name)

    def tool(self, name, body):
        p = self.venv / name
        p.write_text("#!/bin/bash\n" + body + "\n")
        p.chmod(0o755)

    def check(self, sdk, sdks, **env):
        def run(cmd, *args, **kwargs):
            if list(cmd) == XCRUN:
                return subprocess.CompletedProcess(cmd, 0, f"{sdk}.0\n", "")
            return REAL_RUN(cmd, *args, **kwargs)
        base = dict(S2A_PYTHON=str(self.venv / "python3"), S2A_REWRITER_DEPS=str(self.deps), S2A_RUN_ROOT=str(self.root / "run"),
                    PATH=str(self.bare), S2A_REWRITER_C="", S2A_REWRITER_BUNDLED="", S2A_SHELL="", S2A_SHELL_SOURCE="", S2A_DAV1D="1", S2A_GMAKE="",
                    S2A_FONTS="", S2A_OPENFONTS_DIR=str(self.root / "no-fonts"))
        base.update(env)
        out = io.StringIO()
        with patch.dict(os.environ, base), patch.object(applenv, "context", return_value=(self.c, "/synthetic/Xcode")), \
                patch.object(applenv.toolchain, "preflight", return_value={"checks": [
                    dict(name=".NET 10", ok=True, requiredFor=["prepare"]), dict(name=".NET SDK（打 iPhone 包）", ok=False, requiredFor=["ipa"]),
                    dict(name="Python", ok=False, requiredFor=["prepare"])]}), \
                patch.object(ipa, "_listed_sdks", side_effect=lambda: iter(sdks)), patch.object(target.subprocess, "run", side_effect=run), \
                patch.object(applenv.tempfile, "mkdtemp", return_value=str(self.root)), contextlib.redirect_stdout(out):
            rc = applenv.main(["--json"])
        return rc, {x["name"]: x for x in json.loads(out.getvalue())["checks"]}

    def all_tools(self):
        for name in ("cmake", "ninja", "meson"):
            self.tool(name, "exit 0")
        self.tool("gmake", 'echo "GNU Make 4.4.1"')

    def test_dotnet_too_old_is_not_reported_as_missing(self):
        self.all_tools()
        old = Path("/synthetic/dotnet")
        _, checks = self.check(applenv.sdk_pin(), [(old, "10.0.301", Path("/synthetic/sdk"))])
        for name in (".NET 10", ".NET SDK（打 iPhone 包）"):
            self.assertFalse(checks[name]["ok"], "10.0.301 低于 global.json，preflight 的「10.x 就算有」要被改掉")
            self.assertIn("版本太旧", checks[name]["message"])
            self.assertIn("10.0.301", checks[name]["message"])
            self.assertIn("10.0.403", checks[name]["message"])
        _, checks = self.check(applenv.sdk_pin(), [])
        self.assertIn("没有 .NET 10 SDK", checks[".NET 10"]["message"])

    def test_sdk_major_must_match_pin(self):
        self.all_tools()
        pin = applenv.sdk_pin()
        self.assertIsNotNone(pin, "tools/toolchain.env 里有 IPHONEOS_SDK_MAJOR")
        rc, checks = self.check(pin - 1, [])
        self.assertFalse(checks["iOS SDK 主版本"]["ok"])
        self.assertIn(f"Xcode {pin}", checks["iOS SDK 主版本"]["message"])
        self.assertEqual(rc, 1)
        _, checks = self.check(pin, [])
        self.assertTrue(checks["iOS SDK 主版本"]["ok"])
        _, checks = self.check(pin - 1, [], S2A_SHELL=str(self.root / "shell"))
        self.assertTrue(checks["iOS SDK 主版本"]["ok"], "给了现成的壳就不在本机出壳，不要求 SDK 主版本")

    def test_build_tools_found_where_oneclick_looks(self):
        _, checks = self.check(applenv.sdk_pin(), [])
        for name in ("cmake", "ninja", "meson", "GNU Make 4"):
            self.assertFalse(checks[name]["ok"], name)
        self.assertNotIn("meson", self.check(applenv.sdk_pin(), [], S2A_DAV1D="0")[1], "S2A_DAV1D=0 不编 dav1d，不要 meson")
        self.all_tools()
        _, checks = self.check(applenv.sdk_pin(), [])
        for name in ("cmake", "ninja", "meson", "GNU Make 4"):
            self.assertTrue(checks[name]["ok"], f"{name} 在一键出包解释器的目录里（PATH 最前），要认")

    def test_rewriter_deps_and_fonts_python(self):
        self.all_tools()
        _, checks = self.check(applenv.sdk_pin(), [])
        self.assertTrue(checks["改写器固定依赖"]["ok"])
        self.assertTrue(checks["共享字体"]["ok"], "生成器依赖按 S2A_PYTHON 查（PATH 上没有能 import fontTools 的 python3）")
        self.assertTrue(checks["Python"]["ok"])
        if (ROOT / "build/rewriter-deps").is_dir():
            self.skipTest("本树 build/rewriter-deps 在，缺依赖那一半测不了")
        _, checks = self.check(applenv.sdk_pin(), [], S2A_REWRITER_DEPS=str(self.root / "absent"))
        self.assertFalse(checks["改写器固定依赖"]["ok"])
        self.assertIn("prepare_deps.py", checks["改写器固定依赖"]["message"])
