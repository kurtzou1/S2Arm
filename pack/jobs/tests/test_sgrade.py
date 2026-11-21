# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""S 级优化升级（pack/jobs/sgrade.py，v0.4.0）：原始程序存一份 / 按顺序找 / 升级前查找的分组 / Mac 逐款补。游戏库换成临时目录，期望手写"""
import contextlib
import sys
import os
import json
import shutil
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import jobcase  # noqa: F401
import build
import layout
import sgrade
from core import Failure


def nso(d, bid):
    d.mkdir(parents=True, exist_ok=True)
    b = bytearray(0x100); b[0:4] = b"NSO0"; b[0x40:0x48] = bytes.fromhex(bid); (d / "main").write_bytes(bytes(b)); (d / "main.npdm").write_bytes(b"npdm")
    (d / "sdk").write_bytes(b"sdk"); (d / "rtld").write_bytes(b"rtld")
    return d


class SGradeTests(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())
        self.events = []
        self.c = types.SimpleNamespace(private=self.t, emit=lambda k, text, **_: self.events.append(text), begin=lambda *a, **k: None,
                                       lock=lambda name: contextlib.nullcontext(), idle=lambda name: contextlib.nullcontext(self.free),
                                       catalog=lambda: {"games": [{"id": g, "name": n} for g, n in self.games]})
        self.games = []
        self.free = True   # execution 锁是不是没人用（c.idle）
        self.info = {}
        def game_path(c, gid, *parts, create=True):
            d = self.t / "lib" / gid.upper()
            return d.joinpath(*parts)
        for p in (patch.object(layout, "path", side_effect=game_path),
                  patch.object(layout, "image_mac", side_effect=lambda c, g, create=True: game_path(c, g, "image", "mac")),
                  patch.object(layout, "ios_kit", side_effect=lambda c, g: game_path(c, g, "image", "ios", "kit")),
                  patch.object(layout, "program_exefs", side_effect=lambda c, g: game_path(c, g, "original-exefs")),
                  patch.object(layout, "has_ios_kit", side_effect=lambda c, g: (game_path(c, g, "image", "ios", "kit") / "main.npdm").is_file()),
                  patch("programs.save_exefs", side_effect=lambda c, g, src: (shutil.rmtree(game_path(c, g, "original-exefs"), ignore_errors=True),
                                                                               shutil.copytree(src, game_path(c, g, "original-exefs")))[1]),   # 常驻归档另有单测（test_programs_store）
                  patch.object(layout, "game_info", side_effect=lambda c, g: self.info.get(g.upper(), {})),
                  patch.object(build, "extract_valid", return_value=False)):
            p.start(); self.addCleanup(p.stop)

    def test_save_program_copies_modules_once(self):
        src = nso(self.t / "x", "AABBCCDD00112233")
        d = sgrade.save_program(self.c, "0100A", src)
        self.assertEqual(sorted(p.name for p in d.iterdir()), ["main", "main.npdm", "sdk"], "只存模块与 main.npdm，rtld 这类不存")
        (d / "sdk").write_bytes(b"mine")
        sgrade.save_program(self.c, "0100A", src)
        self.assertEqual((d / "sdk").read_bytes(), b"mine", "同一主程序（构建号相同）不重复写")
        self.assertIsNone(sgrade.save_program(self.c, "0100B", self.t / "empty"), "源目录不完整不存")

    def test_find_program_order(self):
        g = {"id": "0100A"}
        nso(self.t / "lib/0100A/image/mac/exefs", "1111111111111111")
        self.assertEqual(sgrade.find_program(self.c, g, extract=False)[0], "mac", "没存下、没解包缓存 → Mac 运行版本")
        nso(self.t / "lib/0100A/original-exefs", "2222222222222222")
        self.assertEqual(sgrade.find_program(self.c, g, extract=False)[0], "saved", "存下的优先")
        self.assertEqual(sgrade.find_program(self.c, {"id": "0100B"}, extract=False), ("none", None))
        import rewrite_refresh
        with patch.object(rewrite_refresh, "original_exefs", side_effect=lambda c, game, work: nso(Path(work) / "x", "3333333333333333")):
            where, d = sgrade.find_program(self.c, {"id": "0100C"})
        self.assertEqual(where, "source"); self.assertEqual(d, self.t / "lib/0100C/original-exefs", "从原件解出来的存进游戏文件夹")

    def test_scan_groups(self):
        # A：iPhone 件 + 存下的原始程序 + 有补丁；B：有原始程序没补丁；C：只有 Mac 版、找不到原始程序以外的路 → Mac 版自带；D：iPhone 件但找不到原始程序；E：没出过包不列
        self.games = [("0100A", "甲"), ("0100B", "乙"), ("0100C", "丙"), ("0100D", "丁"), ("0100E", "戊")]
        for g in ("0100A", "0100B", "0100D"):
            (self.t / "lib" / g / "image/ios/kit").mkdir(parents=True); (self.t / "lib" / g / "image/ios/kit/main.npdm").write_bytes(b"x")
        nso(self.t / "lib/0100A/original-exefs", "AAAAAAAAAAAAAAAA"); nso(self.t / "lib/0100B/original-exefs", "BBBBBBBBBBBBBBBB")
        nso(self.t / "lib/0100C/image/mac/exefs", "CCCCCCCCCCCCCCCC")
        self.info["0100C"] = {"sgradeOff": True}
        pats = {"AAAAAAAAAAAAAAAA": {"widescreen": 1, "fps": 2, "gfx": 0, "cheat": 3}, "CCCCCCCCCCCCCCCC": {"widescreen": 1, "fps": 0, "gfx": 0, "cheat": 0}}
        import patches, rewrite_refresh
        with patch.object(sgrade, "local_patches", side_effect=lambda c, g, bid, others=None: pats.get(bid, {"widescreen": 0, "fps": 0, "gfx": 0, "cheat": 0})), \
             patch.object(rewrite_refresh, "original_exefs", return_value=None), \
             patch.object(patches, "display_version", return_value="1.0.0"), patch.object(patches, "own_widen", return_value=False):
            r = sgrade.scan(self.c)
        got = {x["id"]: (x["program"], x["total"], x["iphone"], x["mac"], x["off"]) for x in r["games"]}
        self.assertEqual(got, {"0100A": ("saved", 6, True, False, False), "0100B": ("saved", 0, True, False, False),
                               "0100C": ("mac", 1, False, True, True), "0100D": ("none", 0, True, False, False)})
        self.assertEqual((r["found"], r["upgradable"], r["noPatch"], r["missing"]), (3, 1, 1, 1), "丙出包时取消过 S 级优化，不算可升级")

    def _manual_fixture(self, gid="0100A"):
        self.games = [("0100A", "甲"), ("0100B", "乙")]
        for g in ("0100A", "0100B"):
            nso(self.t / "lib" / g / "image/mac/exefs", "1111111111111111")
        kit = self.t / "lib" / gid / "image/ios/kit"; kit.mkdir(parents=True, exist_ok=True); (kit / "main.npdm").write_bytes(b"M")
        self.c.r = {"gameId": gid}; self.c.task = "sg1"
        self.progress = []
        self.c.emit = lambda k, text="", **kw: self.progress.append((kw["done"], kw["total"])) if k == "progress" else self.events.append(text)
        p = patch.object(layout, "game_dir", side_effect=lambda c, g: self.t / "lib" / g.upper()); p.start(); self.addCleanup(p.stop)
        import ipa
        p = patch.object(ipa, "program_locks", lambda c, games: contextlib.nullcontext()); p.start(); self.addCleanup(p.stop)

    def test_mac_all_without_game_does_nothing(self):
        # 11-17 维护者：「改成不自动运行，玩家手动点击 S 级优化再升级」——旧启动器打开时照旧起 sgradeMac（不带 gameId）：一款都不碰
        self.games = [("0100A", "甲")]
        nso(self.t / "lib" / "0100A" / "image/mac/exefs", "1111111111111111")
        self.c.r = {}
        import rewrite_refresh
        import sgrade_bf
        with patch.object(rewrite_refresh, "refresh_mac", side_effect=AssertionError("打开启动器不该自动补")), \
             patch.object(sgrade_bf, "upgrade_mac", side_effect=AssertionError("打开启动器不该重出直连库")):
            self.assertEqual(sgrade.mac_all(self.c), {"updated": [], "checked": 0, "manual": True})

    @unittest.skipUnless(sys.platform == "darwin", "Mac 运行版本只在 Mac 上补")
    def test_upgrade_game_only_this_game_and_clears_marker(self):
        # 玩家对 0100A 点「S 级优化」：只补这一款——Mac 运行版本 S 级补丁、_bf、iPhone 程序件三步各一次，0100B 不碰；做完未完成标记删掉
        self._manual_fixture("0100A")
        import rewrite_refresh
        import sgrade_bf
        seen = []
        def mark(step):
            def f(c, g, *a, **k):
                seen.append((step, g if isinstance(g, str) else tuple(g)))
                self.assertTrue((self.t / "lib/0100A" / sgrade.UPGRADING).is_file(), "做的时候标记在（中途退出 = 未完成）")
                return True
            return f
        with patch.object(rewrite_refresh, "refresh_mac", side_effect=mark("mac")), patch.object(sgrade_bf, "upgrade_mac", side_effect=mark("bf")), \
             patch.object(rewrite_refresh, "refresh_ios", side_effect=mark("ios")):
            r = sgrade.upgrade_game(self.c)
        self.assertEqual(seen, [("mac", "0100A"), ("bf", "0100A"), ("ios", ("0100A",))])
        self.assertEqual(self.progress, [(0, 3), (1, 3), (2, 3), (3, 3)], "进度 done / total：开始 0、每做完一段进一格")
        self.assertEqual((r["updated"], r["steps"]), (["0100A"], {"mac": True, "bf": True, "ios": True}))
        self.assertFalse((self.t / "lib/0100A" / sgrade.UPGRADING).exists())

    @unittest.skipUnless(sys.platform == "darwin", "Mac 运行版本只在 Mac 上补")
    def test_upgrade_progress_one_monotone_value(self):
        # 玩家报修 D-QNA9（Mac 实机）：段内计数器各自的 done / total 与按段的粗进度互相盖，进度条在 50%、0%、80% 间来回跳。
        # 两段（Mac 运行版本 + 片上读取着色器，没有 iPhone 件），整款进度 = (第几段 − 1 + 段内完成度) ÷ 2，只增不减，期望逐条手算：
        #   开始 0；段一 A 1/4 → 0.125、A 2/4 → 0.25、B 从 0 重数 0/100 → 仍 0.25、B 20/100（0.05）→ 仍 0.25、B 60/100 → 0.3、C 5/6 → 5/12 ≈ 0.4167、段一做完 0.5；
        #   段二 D 0/8 → 0.5、D 2/8 → 0.625、E 1/10 → 仍 0.625、一条文字消息也带 0.625、D 6/8 → 0.875、整款做完 1.0
        self._manual_fixture("0100A")
        shutil.rmtree(self.t / "lib/0100A/image/ios")
        self.c.r = {"gameIds": ["0100A"]}; self.c.library = self.t; self.c.logs = self.t
        seen = []   # (类型, sgradeProgress, done, total)
        self.c.emit = lambda k, text="", **kw: seen.append((k, kw.get("sgradeProgress"), kw.get("done"), kw.get("total")))
        queue = []   # 段内读到的队列文件进度（别的窗口 / 轮询看到的）
        def read_queue():
            queue.append(sgrade.queue_status(self.c)["games"][0]["progress"])
        def seg_mac(c, g, *a, **k):
            for d, t in ((1, 4), (2, 4), (0, 100), (20, 100), (60, 100), (5, 6)):
                c.emit("progress", done=d, total=t)
            read_queue()
            return True
        def seg_bf(c, g, *a, **k):
            read_queue()
            c.emit("progress", done=0, total=8); c.emit("progress", done=2, total=8); c.emit("progress", done=1, total=10)
            c.emit("message", "编着色器库")
            c.emit("progress", done=6, total=8)
            return True
        import rewrite_refresh
        import sgrade_bf
        with patch.object(rewrite_refresh, "refresh_mac", side_effect=seg_mac), patch.object(sgrade_bf, "upgrade_mac", side_effect=seg_bf), \
             patch.object(rewrite_refresh, "refresh_ios", side_effect=AssertionError("没有 iPhone 件不补")):
            r = sgrade.upgrade_batch(self.c)
        inner = [(k, p) for k, p, d, t in seen if k != "batch"]
        self.assertEqual([p for _, p in inner], [0.0, 0.125, 0.25, 0.25, 0.25, 0.3, 0.4167, 0.5, 0.5, 0.625, 0.625, 0.625, 0.875, 1.0],
                         "每条事件都带整款进度，计数器换一个 / 从 0 重数都不回退")
        self.assertEqual([(d, t) for k, p, d, t in seen if k == "progress" and p in (0.0, 0.5, 1.0) and t == 2], [(0, 2), (1, 2), (2, 2)],
                         "按段的 done / total 照发，段边界整款进度 0、0.5、1.0")
        self.assertEqual(queue, [0.4167, 0.5], "队列文件（轮询读的）与最后一次发出的整款进度一致：段一末 5/12、段二开头 = 段一做完 0.5")
        self.assertEqual((r["games"][0]["state"], r["games"][0]["progress"]), ("done", 1.0))
        self.assertEqual(self.c.emit.__name__, "<lambda>", "收尾还原成原来的 c.emit（不是删掉）")

    def test_upgrade_game_refused_while_playing(self):
        # 这款正在运行（开始游戏拿着这款的 S 级锁）：点升级报原因、什么都不做、不写标记
        self._manual_fixture("0100A")
        self.free = False
        import rewrite_refresh
        with patch.object(rewrite_refresh, "refresh_mac", side_effect=AssertionError("不该开始")):
            with self.assertRaises(Failure) as e:
                sgrade.upgrade_game(self.c)
        self.assertEqual(e.exception.code, "library_busy")
        self.assertFalse((self.t / "lib/0100A" / sgrade.UPGRADING).exists())

    def test_upgrade_state(self):
        # 标记在、作业进程在 → upgrading（界面画进度、禁开始）；进程不在（中途退出启动器）→ incomplete；没标记 → None
        self._manual_fixture("0100A")
        m = self.t / "lib/0100A" / sgrade.UPGRADING
        self.assertIsNone(sgrade.upgrade_state(self.c, "0100A"))
        m.write_text(json.dumps(dict(task="t", pid=os.getpid())))
        self.assertEqual(sgrade.upgrade_state(self.c, "0100A"), "upgrading")
        m.write_text(json.dumps(dict(task="t", pid=2 ** 22 + 12345)))
        self.assertEqual(sgrade.upgrade_state(self.c, "0100A"), "incomplete")

    def test_launch_refused_while_this_game_upgrading(self):
        # 开始游戏：这款的 S 级锁拿不到（正在升级）→ sgrade_upgrading，起局前什么都不做；锁名按款，别的款拿的是自己的锁
        c = types.SimpleNamespace(r={"gameId": "0100A"}, lock=lambda name, **k: contextlib.nullcontext(), library=self.t,
                                  idle=lambda name: contextlib.nullcontext(name != sgrade.game_lock("0100A")),
                                  game=lambda: (_ for _ in ()).throw(AssertionError("被拒前不该往下走")))
        holder = self.t / ("." + sgrade.game_lock("0100A") + ".lock.holder")
        holder.write_text(json.dumps(dict(taskId="u", operation="sgradeUpgradeGame")))
        with self.assertRaises(Failure) as e:
            build.launch(c)
        self.assertEqual(e.exception.code, "sgrade_upgrading")
        self.assertNotEqual(sgrade.game_lock("0100A"), sgrade.game_lock("0100B"))
        # 执行锁读写化（11-19）：拿着这款锁的是另一局 / 出包（执行锁只拿共享，不再在执行锁上排队）→ 同原先的「游戏库忙」，带占锁者
        for op in ("launch", "build", "ipa"):
            holder.write_text(json.dumps(dict(taskId="p", operation=op)))
            with self.assertRaises(Failure) as e:
                build.launch(c)
            self.assertEqual((e.exception.code, e.exception.holder["operation"]), ("library_busy", op))

if __name__ == "__main__":
    unittest.main()
