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


if __name__ == "__main__":
    unittest.main()
