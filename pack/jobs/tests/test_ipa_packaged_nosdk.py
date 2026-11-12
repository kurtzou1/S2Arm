#!/usr/bin/env python3
"""Mac 发版应用打 iPhone 包不要 .NET SDK（11-07 启动器线；维护者：Mac 只留 Xcode + Metal 组件）：
   请求带 engineBundle（发版应用）→ 不查外部 SDK、不改 DOTNET_ROOT，随包壳交 S2A_SHELL、应用自带读取器包成可执行壳交 S2A_NX_UNPACK；
   源码树（不带 engineBundle）照旧要 SDK（反证）。随包壳缺 → tool_missing（请重装），不提示去装 SDK。期望手写。
   新用例单独成文件（列车线 10-30：公用大测试文件合入时互相冲突）。"""
import os
from pathlib import Path
import unittest
import unittest.mock as um

import test_jobs
from test_jobs import ROOT, img_step, oneclick_done, shared_extract
from core import Failure
import ipa
import target as tg


class PackagedNoSdk(unittest.TestCase):
    # 借 test_jobs 的夹具方法（不继承：继承会把那边全部用例再跑一遍）
    setUp, tearDown = test_jobs.JobsTests.setUp, test_jobs.JobsTests.tearDown
    catalogue, package, game, player_keys = test_jobs.JobsTests.catalogue, test_jobs.JobsTests.package, test_jobs.JobsTests.game, test_jobs.JobsTests.player_keys

    def prepare(self):
        base = self.package("base")
        self.catalogue([self.game(packages=[base])])
        self.player_keys()   # 加密原件出包开头要 prod.keys（library.require_game，v0.3.1）
        res = self.root / "res"; (res / "Fonts").mkdir(parents=True); (res / "Fonts/a.bfttf").write_bytes(b"x")
        (res / "Shell/root").mkdir(parents=True); (res / "Shell/manifest.json").write_text("{}")
        self.c.r.update(resources=str(res), gameId="0100000000000000", engineBundle=str(ROOT))
        um.patch.object(tg, "connected", return_value=[]).start(); self.addCleanup(um.patch.stopall)
        return res

    def run_build(self, sdk=AssertionError("发版应用不许查外部 SDK")):
        seen = {}
        def run(args, log=None, env=None, cwd=None, on_line=None):
            if img_step(args, cwd, env): return   # 出包收尾转单一 IMG（ipa.to_img 经 c.run）：真跑
            if not any("oneclick" in str(a) for a in args):   # 出包收尾组库根 S2Arm.ipa（refresh_library_ipa）：这条不测它，组装失败按设计只警告
                raise Failure("这条测试不组装容器")
            seen.update(args=[str(a) for a in args], env=env)
            out = Path(args[args.index("--out") + 1]); (out / "x.ipa").write_bytes(b"ipa")
            oneclick_done(args, out / "x.ipa", build_id="b", graphics_mode="direct")
        with um.patch.object(ipa, "dotnet_sdk", side_effect=sdk), um.patch.object(self.c, "run", run), \
             um.patch.object(self.c, "engine", ROOT), um.patch("toolchain.reader", return_value=Path("/App/Engine/Binaries/Reader/nx_unpack.dll")):
            return ipa.build(self.c), seen

    @shared_extract
    def test_packaged_uses_bundled_shell_and_reader(self):
        res = self.prepare()
        before = self.c.env()["DOTNET_ROOT"] if "DOTNET_ROOT" in self.c.env() else None
        r, seen = self.run_build()
        env = seen["env"]
        self.assertEqual(env["S2A_SHELL"], str(res / "Shell"))
        nxu = Path(env["S2A_NX_UNPACK"])
        self.assertEqual(nxu.read_text(), '#!/bin/sh\nexec dotnet /App/Engine/Binaries/Reader/nx_unpack.dll "$@"\n')
        self.assertTrue(os.access(nxu, os.X_OK))
        self.assertEqual(env.get("DOTNET_ROOT"), before, "不换成外部 SDK")
        self.assertTrue((Path(r["outputPath"]) / "kit" / "main.npdm").is_file())   # 交付件进了这款的 image/ios（不再留单款 ipa）

    @shared_extract
    def test_packaged_missing_shell_is_reinstall(self):
        res = self.prepare()
        (res / "Shell/manifest.json").unlink()
        with self.assertRaises(Failure) as e:
            self.run_build()
        self.assertEqual(e.exception.code, "tool_missing")
        self.assertNotIn("一键安装", str(e.exception))

    @shared_extract
    def test_source_tree_still_needs_sdk(self):
        self.prepare()
        self.c.r.pop("engineBundle")
        with self.assertRaises(Failure) as e:
            self.run_build(sdk=lambda: (None, None))
        self.assertEqual(e.exception.code, "dotnet_sdk_missing")


if __name__ == "__main__":
    unittest.main()
