# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""0.6.0 着色器覆盖度并进「建议重新出包」（pack/jobs/host_update.py shader_hint / built_older / update_hints / phone_overview；install.pull_shader_counts）。
游戏库与设备记录是真的（library.setup + layout），当前启动器版本用替身给定（0.6.0），期望按写进去的计数与 builtBy 手写。"""
import json
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import core  # noqa: E402
import host_update  # noqa: E402
import install  # noqa: E402
import layout  # noqa: E402
import program_pack  # noqa: E402
import rewrite_refresh  # noqa: E402
import tests.test_jobs as tj  # noqa: E402
from tests.jobcase import ios_fixture  # noqa: E402

A, B = "0100000000010000", "0100000000020000"
OK = dict(rewriterId="RID", hostAbi=2, dmshChain="chain1", libGen=host_update.LIB_GEN)


class ShaderMissHint(unittest.TestCase):
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown

    def fixture(self):
        ios_fixture(self.c, A, compat=dict(OK, builtBy=dict(version="0.5.4")))   # 旧版打的
        ios_fixture(self.c, B, compat=dict(OK, builtBy=dict(version="0.6.0")))   # 当前版打的
        self.c.catalog = lambda: {"games": [{"id": A, "name": "甲"}, {"id": B, "name": "乙"}]}

    def run_hints(self):
        with patch.object(core, "release_version", lambda e: "0.6.0"), \
                patch.object(rewrite_refresh, "rewriter_id", lambda c: "RID"), patch.object(host_update, "engine_compat", lambda c: dict(hostAbi=2, dmshChain="chain1")), \
                patch.object(host_update, "ios_direct_lib", lambda c, g: True):
            return {g["gameId"]: g["reasons"] for g in host_update.update_hints(self.c)["games"]}

    def test_counts_and_build_version(self):
        self.fixture()
        self.assertEqual(self.run_hints(), {}, "没有现场翻译计数：不标")
        layout.save_device(self.c, "PHONE-1", dict(shaderFallback={A: dict(count=12), B: dict(count=40)}))
        self.assertEqual(self.run_hints(), {A: ["shaderMiss"]}, "A 旧包且有计数 → 标；B 已是当前版打的 → 重出也没用，不标")

    def test_no_built_by_counts_as_old(self):
        ios_fixture(self.c, A, compat=OK)   # 这条判据之前出的包：没有 builtBy
        self.c.catalog = lambda: {"games": [{"id": A, "name": "甲"}]}
        layout.save_device(self.c, "PHONE-1", dict(shaderFallback={A: dict(count=1)}))
        self.assertEqual(self.run_hints(), {A: ["shaderMiss"]})

    def test_mac_counter_from_library_temp(self):
        self.fixture()
        mac = layout.image_mac(self.c, B); mac.mkdir(parents=True, exist_ok=True)
        (mac / "manifest.json").write_text(json.dumps(dict(builtBy=dict(version="0.5.0"), libGen=host_update.LIB_GEN)))
        t = Path(self.c.library) / "temp" / B; t.mkdir(parents=True)
        (t / host_update.SHADER_FALLBACK).write_text(json.dumps(dict(count=5, at=1, app="0.5.0")))
        self.assertEqual(self.run_hints(), {B: ["shaderMiss"]}, "Mac 局现场翻译过、Mac 运行版本是旧版打的 → 标")

    def test_mac_only_game_gets_no_phone_hint(self):
        """#1712：只在 Mac 出包、从没打过 iPhone 包的款（没有 game.json ios 记录）——「更新这款」是推到 iPhone，不该弹。
        即使 Mac 运行版本是旧代数、旧版打的、Mac 局现场翻译过，也不标"""
        self.c.catalog = lambda: {"games": [{"id": A, "name": "甲"}]}
        mac = layout.image_mac(self.c, A); mac.mkdir(parents=True, exist_ok=True)
        (mac / "manifest.json").write_text(json.dumps(dict(builtBy=dict(version="0.5.0"), libGen=0)))
        t = Path(self.c.library) / "temp" / A; t.mkdir(parents=True)
        (t / host_update.SHADER_FALLBACK).write_text(json.dumps(dict(count=5, at=1, app="0.5.0")))
        self.assertEqual(layout.program_info(self.c, A), {}, "前提：这款没有 iPhone 程序记录")
        self.assertEqual(self.run_hints(), {}, "没推过手机的款不弹手机提示")

    def test_overview_uses_this_phone_count(self):
        self.fixture()
        layout.save_device(self.c, "PHONE-1", dict(shellId="S", games={A: dict(program=dict(sha="s", host_abi=2, rewriter_id="RID"), pack="P")},
                                                   shaderFallback={A: dict(count=3)}))
        layout.save_device(self.c, "PHONE-2", dict(shellId="S", games={A: dict(program=dict(sha="s", host_abi=2, rewriter_id="RID"), pack="P")}))
        with patch.object(core, "release_version", lambda e: "0.6.0"), \
                patch.object(rewrite_refresh, "rewriter_id", lambda c: "RID"), patch.object(host_update, "engine_compat", lambda c: dict(hostAbi=2, dmshChain="chain1")), \
                patch.object(host_update, "ios_direct_lib", lambda c, g: True):
            ph = {p["device"]: {g["gameId"]: g for g in p["games"]} for p in host_update.phone_overview(self.c)["phones"]}
        self.assertEqual(ph["PHONE-1"][A], dict(gameId=A, state="suggested", reasons=["shaderMiss"]))
        self.assertEqual(ph["PHONE-2"][A]["state"], "latest", "另一台没现场翻译过：不标")

    def test_built_by_written_at_pack_time(self):
        with patch.object(core, "release_version", lambda e: "0.6.0"), patch.object(core, "display_version", lambda e: "v0.6.0"):
            self.assertEqual(host_update.built_by(self.c), dict(version="0.6.0", display="v0.6.0"))

    def test_pull_counts_from_phone(self):
        files = {f"{install.game_docs(A)}/{host_update.SHADER_FALLBACK}": json.dumps(dict(count=7, at=9, app="0.6.0")).encode()}
        class Cl:
            def get(self, rel, dst):
                if rel in files:
                    Path(dst).write_bytes(files[rel]); return True
                return False
        ph = types.SimpleNamespace(key="PHONE-1", client=lambda w: Cl())
        with patch.object(install, "trace", lambda *a, **k: None):
            got = install.pull_shader_counts(self.c, ph, [A.lower(), B])
        self.assertEqual(got, {A: dict(count=7, at=9, app="0.6.0")}, "手机上没有的款不记")
        self.assertEqual(layout.load_device(self.c, "PHONE-1")["shaderFallback"], {A: dict(count=7, at=9, app="0.6.0")})


if __name__ == "__main__":
    unittest.main()
