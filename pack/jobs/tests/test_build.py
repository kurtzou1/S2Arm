"""Mac 准备（pack/jobs/build.py）单测（从 test_error_recovery.py 拆出，10-26；夹具 jobcase.JobCase）。"""
import os
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch

from jobcase import JobCase, ROOT


class BuildTests(JobCase):
    def test_player_launch_disables_iphone_va_in_real_child_only(self):
        import build
        game = dict(id="0100000000000000", name="Test title")
        for inherited in (None, "0", "1"):
            with self.subTest(inherited=inherited), patch.dict(os.environ):
                os.environ.pop("S2A_IPHONE_VA", None)
                if inherited is not None:
                    os.environ["S2A_IPHONE_VA"] = inherited
                self.assertNotIn("S2A_IPHONE_VA", self.c.env())
                env = build.runtime_env(self.c, game, self.root / "runtime")
                lines = []
                self.c.run([sys.executable, "-c",
                            "import os; print(os.getenv('S2A_IPHONE_VA', 'unset'))"],
                           env=env, on_line=lines.append)
                self.assertEqual(lines, ["0"])
                self.assertEqual(os.environ.get("S2A_IPHONE_VA"), inherited)
                self.assertNotIn("S2A_IPHONE_VA", self.c.env())

    @unittest.skipUnless(sys.platform == "darwin", "Mac development launch adapter")
    def test_developer_run_mac_preserves_iphone_va_default_and_overrides(self):
        # Run the real adapter with a synthetic host; no game, saves or GPU.
        repo = self.root / "dev repo"
        for directory in ("runtime", "tools", "build", "input", "home"):
            (repo / directory).mkdir(parents=True)
        shutil.copyfile(ROOT / "runtime/run_mac.sh", repo / "runtime/run_mac.sh")
        (repo / "input/main.patched.bin").touch()
        fixtures = {
            "tools/mac_chain_check.py": "raise SystemExit(0)\n",
            "tools/mac_save.sh": "mac_save_prep() { :; }\n",
            "tools/phys_footprint.py": "print('0 0')\n",
            "build/s2arm-host": "#!/bin/sh\nprintf '%s\\n' \"${S2A_IPHONE_VA-unset}\"\n",
        }
        for name, content in fixtures.items():
            (repo / name).write_text(content)
        (repo / "build/s2arm-host").chmod(0o755)
        for override in (None, "0", "1"):
            with self.subTest(override=override):
                env = dict(PATH=os.defpath, HOME=str(repo / "home"),
                           S2A_PY=sys.executable, S2A_IN=str(repo / "input"),
                           S2A_HOST_PREBUILT="1", S2A_MAC_SLOT_HELD="1")
                if override is not None:
                    env["S2A_IPHONE_VA"] = override
                run = repo / ("run-" + str(override))
                result = subprocess.run(["/bin/bash", str(repo / "runtime/run_mac.sh"),
                                         "synthetic", str(run), "5"],
                                        env=env, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((run / "host.log").read_text().strip(),
                                 "unset" if override is None else override)

    def test_runtime_extras_do_not_enter_the_mac_image(self):
        # 出包收尾（pack/ipa_tail.py）在产物根里留下的 pkg/（打包工作区，打 iPhone 包时资源包与 ipa 的暂存处）与 build/（组装临时 App）
        # 不是运行依赖。原先 prepare() 克隆产物根时只剔了顶层 *.log 与三个标记文件，它们跟着进了 image/mac，
        # 此后没有任何一步回收（实测 0100F43008C44000：image/mac 的 du 11.40 GiB、真独占 209.8 MiB，其中 pkg/pack 独占 120 KiB）。
        import build
        root = self.root / "product"
        (root / "romfs" / "arc").mkdir(parents=True)
        (root / "romfs" / "arc" / "data.trpfs").write_bytes(b"game data")
        (root / "exefs").mkdir()
        (root / "exefs" / "main.npdm").write_bytes(b"npdm")
        (root / "unpack.tsv").write_text("runtime dependency\n")
        for name in ("pkg", "build"):
            (root / name / "nested").mkdir(parents=True)
            (root / name / "nested" / "junk.bin").write_bytes(b"packaging only")
        for name in ("pkg/build.log", "sign.log", "seed.txt", ".root_src", ".root_base"):
            (root / name).write_bytes(b"transient")
        build.prune_runtime_extras(root)
        self.assertEqual(sorted(p.name for p in root.iterdir()),
                         ["exefs", "romfs", "unpack.tsv"],
                         "pkg/ 与 build/ 必须留在产物根，不能进运行版本；运行依赖 unpack.tsv 与 romfs/、exefs/ 不能动")
        self.assertEqual((root / "romfs" / "arc" / "data.trpfs").read_bytes(), b"game data")

    def test_runtime_extras_never_follow_a_link_out_of_the_image(self):
        # pkg/ 与 build/ 同名项若是软链（他人或旧版本留下的），只能删链接本身，不跟进去删目标（同 test_cleanup_links.py 的口径）。
        import build
        root = self.root / "product"
        root.mkdir()
        (root / "romfs").mkdir()
        player = self.root / "player data"
        (player / "saves").mkdir(parents=True)
        keep = player / "saves" / "0.sav"
        keep.write_bytes(b"must survive")
        for name in ("pkg", "build"):
            (root / name).symlink_to(player, target_is_directory=True)
        (root / "sign.log").symlink_to(keep)
        build.prune_runtime_extras(root)
        self.assertEqual(keep.read_bytes(), b"must survive")
        self.assertEqual(sorted(p.name for p in root.iterdir()), ["romfs"])

    def test_runtime_extras_removes_read_only_packaging_dirs(self):
        # pkg/pack/romfs 克隆自产物根，可能带只读目录（产物根 RomFS 共享存储整棵只读）。期望整个 pkg/ 删掉，不留半棵进运行版本
        import build
        root = self.root / "product"
        (root / "romfs").mkdir(parents=True)
        sealed = root / "pkg" / "pack" / "romfs" / "sealed"
        sealed.mkdir(parents=True)
        (sealed / "data.bin").write_bytes(b"cloned")
        sealed.chmod(0o555)
        try:
            build.prune_runtime_extras(root)
        finally:
            if sealed.exists():
                sealed.chmod(0o755)
        self.assertEqual(sorted(p.name for p in root.iterdir()), ["romfs"])

    def test_launch_env_carries_cover_for_dock_icon(self):
        # #994：起局把游戏库列表同一张封面文件交给宿主（S2A_GAME_COVER；封面三级取法在 library.catalog：玩家换的 → 游戏自带 → 商店横图），
        #   宿主起 App 后把 Dock / Cmd+Tab 图标换成它（macos/front_mac.m）。没有封面 / 文件不在了就不带，宿主用包内默认图标
        import build
        cover = self.root / "cover.jpg"
        cover.write_bytes(b"cover fixture")
        for provided, expect in ((str(cover), str(cover)), ("", None), (str(self.root / "none.jpg"), None)):
            with self.subTest(cover=provided):
                game = dict(id="0100000000000000", name="Test title", cover=provided)
                env = build.runtime_env(self.c, game, self.root / "runtime")
                self.assertEqual(env.get("S2A_GAME_COVER"), expect)

    def test_launch_env_cover_from_game_folder_when_record_has_none(self):
        # #994 实测（0.6.4）：起局拿的是 catalog.json 原始记录（c.game()），没有 cover 字段，封面只在游戏库列表那边现算 →
        #   宿主环境里没有 S2A_GAME_COVER、Dock 仍是 S2Arm 标志。期望起局按列表同一份三级取法现取：玩家换的 → cover.jpg → banner.jpg
        import build, library, layout
        from unittest.mock import patch
        folder = self.root / "game-folder"; folder.mkdir()
        custom = self.root / "custom.png"
        real = layout.path
        def path(c, gid, *parts, create=True):   # 只把封面两张图指到夹具文件夹，别的路径（存档、金手指等）照原样
            return folder.joinpath(*parts) if parts in (("cover.jpg",), ("banner.jpg",)) else real(c, gid, *parts, create=create)
        game = dict(id="0100000000000000", name="Test title")   # 同 catalog.json 原始记录：没有 cover
        cases = (({}, None, None), ({"banner.jpg"}, None, folder / "banner.jpg"), ({"banner.jpg", "cover.jpg"}, None, folder / "cover.jpg"),
                 ({"banner.jpg", "cover.jpg"}, custom, custom))
        for files, mine, expect in cases:
            with self.subTest(files=sorted(files), custom=bool(mine)):
                for p in folder.iterdir():
                    p.unlink()
                for name in files:
                    (folder / name).write_bytes(b"img")
                if mine:
                    mine.write_bytes(b"img")
                with patch.object(layout, "path", path), patch.object(library, "game_custom", lambda c, g: dict(name="", cover=mine)):
                    env = build.runtime_env(self.c, dict(game), self.root / "runtime")
                self.assertEqual(env.get("S2A_GAME_COVER"), str(expect) if expect else None)

    def test_host_bundle_default_icon_written_from_branding(self):
        # #994：宿主包编进默认图标（与启动器 App 同一原图、同一配方 launchers/macos/make_icns.sh），
        #   没有游戏封面时 Dock / Cmd+Tab 回退到它；更早的引擎快照没有配方 / 原图 → 不写、返回 False，照旧不挡编宿主
        import build
        app = self.root / "S2ArmGame.app"
        self.assertTrue(build.write_host_icon(self.c, app, self.root / "icon.log"))
        icon = app / "Contents/Resources" / build.HOST_ICON
        self.assertTrue(icon.is_file())
        self.assertEqual(icon.read_bytes()[:4], b"icns")
        with patch.object(self.c, "engine", self.root / "old-engine"):
            self.assertFalse(build.write_host_icon(self.c, app, self.root / "icon.log"))


if __name__ == "__main__":
    unittest.main()


class HeapLearned(unittest.TestCase):
    """D-NGH9：Mac 局非零退出时，这一局（起局时刻之后）运行时写过 <文档根>/wire/<程序号>/heap_need → 按「需要更多内存、已记下」报（game_heap_learned）。期望手写"""
    def test_heap_learned_now(self):
        import build, os, tempfile, time
        from pathlib import Path
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / "wire" / "0100ABCD00000000" / "heap_need"
            env = {"S2A_DOCS": t}
            self.assertFalse(build.heap_learned_now(env, "0100abcd00000000", time.time()), "没有记录")
            p.parent.mkdir(parents=True); p.write_text("3292528640\n")
            now = time.time()
            os.utime(p, (now, now))
            self.assertTrue(build.heap_learned_now(env, "0100abcd00000000", now - 5), "这一局写的")
            os.utime(p, (now - 3600, now - 3600))
            self.assertFalse(build.heap_learned_now(env, "0100abcd00000000", now - 5), "上一局留下的旧记录不算")
            self.assertFalse(build.heap_learned_now({}, "0100abcd00000000", 0), "没有文档根")
