import tempfile
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""出包空间按实测（11-07）：实测记账口径、预算三档依据、拦截文案、「仍然继续」放行。全为合成文件，期望值手算。"""
import collections
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from jobcase import JobCase, ROOT, as_windows
from core import Context, Failure
import layout
import library

sys.path.insert(0, str(ROOT))
from pack.contracts.validate import validate, ContractError

MIB = 1 << 20
GID = "01007EF00011E000"
DU = collections.namedtuple("du", "total used free")


def write(path, size):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(os.urandom(size))   # 随机内容：不让文件系统压缩 / 稀疏，1 MiB 就占 1 MiB 块
    return path


class SpaceMeasured(JobCase):
    def setUp(self):
        super().setUp()
        env = patch.dict(os.environ, {})   # 只有直连（11-07）；实测账只认直连行
        env.start(); self.addCleanup(env.stop)

    def context(self, operation="ipa", **extra):
        self.sequence += 1
        return Context(self.request | dict(taskId=f"space-{self.sequence}", operation=operation, gameId=GID) | extra)

    def game(self, size, gid=GID, name="塞尔达传说 旷野之息"):
        pkg = dict(titleId=gid, baseId=gid, type="base", version=0, path="sources/x.nsp", sha256=gid.lower() * 4, size=size, guestIsa="aarch64")
        return dict(id=gid, name=name, packages=[pkg])

    def ledger(self, *rows):
        # time gameId target direct inputBytes footprintBytes name
        with (self.c.library / library.SPACE_LEDGER).open("a", encoding="utf-8") as f:
            for r in rows:
                f.write("\t".join(map(str, list(r) + [""] * (7 - len(r)) + [library.SPACE_LEDGER_FORMAT])) + "\n")

    def budget(self, c, game, free=45 * 10**9):
        with patch("shutil.disk_usage", return_value=DU(0, 0, free)):
            return library.space_budget(c, game)["volumes"][0]

    # —— 实测记账口径 ——
    def test_disk_bytes_skips_named_dirs_only_under_given_roots(self):
        root = Path(self.t if hasattr(self, "t") else tempfile.mkdtemp())
        keep = root / "cache" / "romfs"; clone = root / "iphone" / "romfs"
        keep.mkdir(parents=True); clone.mkdir(parents=True)
        (keep / "a").write_bytes(b"x" * MIB); (clone / "a").write_bytes(b"x" * MIB)
        dev = root.stat().st_dev
        both = library.disk_bytes([root], dev)
        one = library.disk_bytes([root], dev, skip_names=library.CLONED_DIRS, skip_under=[str(root / "iphone")])
        self.assertGreaterEqual(both - one, MIB)       # 克隆那份不算
        self.assertGreaterEqual(one, MIB)              # 解包那份还算

    @unittest.skipUnless(sys.platform == "darwin", "APFS 克隆只在 macOS")
    def test_apfs_clones_count_shared_blocks_once(self):
        """#303：同一份 RomFS 的克隆（解包 / 各层产物根 / .romfs_store / Mac 运行版本，cp -c）只算一份共享块。
        8 MiB 随机文件克隆成 4 份 → 约 8 MiB（不是 32 MiB）；其中一份改 1 字节（换新克隆族、份数 1）→ 它按整份再算一遍：约 16 MiB（偏大、保守）"""
        import subprocess
        root = Path(tempfile.mkdtemp(dir=self.c.library))
        src = write(root / "build" / "extract" / "romfs" / "data.arc", 8 * MIB)
        if library._CloneInfo.get(src) is None:
            self.skipTest("这台机器取不到 APFS 克隆信息（非 APFS 卷）")
        for rel in ("build/k/roots/a@1/romfs", "build/k/roots/.romfs_store/x", "image/mac/romfs"):
            (root / rel).mkdir(parents=True)
            subprocess.run(["cp", "-c", str(src), str(root / rel / "data.arc")], check=True)
        dev = root.stat().st_dev
        got = library.disk_bytes([root], dev)
        self.assertGreaterEqual(got, 8 * MIB); self.assertLess(got, 8 * MIB + 2 * MIB, got)   # 余量 = 目录元数据
        with open(root / "image/mac/romfs/data.arc", "r+b") as f:
            f.seek(100); f.write(b"\x00" if f.read(1) != b"\x00" else b"\x01")
        got = library.disk_bytes([root], dev)
        self.assertGreaterEqual(got, 16 * MIB); self.assertLess(got, 16 * MIB + 2 * MIB, got)
        # 负对照：stat 口径（不认克隆）是 4 份满额
        stat_sum = sum(p.stat().st_blocks * 512 for p in root.rglob("data.arc"))
        self.assertGreaterEqual(stat_sum, 32 * MIB)

    @unittest.skipUnless(sys.platform == "darwin", "APFS 克隆只在 macOS")
    def test_pack_footprint_counts_romfs_clones_once_and_skips_saves(self):
        """#303 记账：宝可梦 Z-A 一类，解包 + 多层产物根 + Mac 运行版本都是同一份 RomFS 的克隆 → 记一份；存档 / 运行时着色器缓存不算出包占用"""
        import subprocess
        c = self.context("build")
        library.atomic(self.c.library / "catalog.json", dict(schema=1, games=[self.game(8 * MIB)]))
        d = layout.game_dir(c, GID, english="Zelda")
        src = write(d / "build" / "extract" / "romfs" / "data.arc", 8 * MIB)
        if library._CloneInfo.get(src) is None:
            self.skipTest("这台机器取不到 APFS 克隆信息（非 APFS 卷）")
        for rel in ("build/k/roots/a@1/romfs", "build/k/roots/b@1/romfs", "build/k/roots/.romfs_store/x", "image/mac/romfs"):
            (d / rel).mkdir(parents=True)
            subprocess.run(["cp", "-c", str(src), str(d / rel / "data.arc")], check=True)
        write(d / "saves" / "s.bin", 4 * MIB); write(d / "shader-cache" / "p.bin", 4 * MIB)
        got = library.pack_footprint(c, GID)
        self.assertGreaterEqual(got, 8 * MIB); self.assertLess(got, 8 * MIB + 2 * MIB, got)

    def test_disk_bytes_counts_hardlink_once_skips_symlink_and_other_volume(self):
        root = self.root / "measure"
        a = write(root / "a.bin", MIB)
        base = library.disk_bytes([root], root.stat().st_dev)
        self.assertGreaterEqual(base, MIB); self.assertLess(base, MIB + 64 * 1024)   # 1 MiB 文件 + 目录元数据（APFS 目录 0 块）
        (root / "sub").mkdir()
        os.link(a, root / "sub" / "a-link.bin")
        (root / "a-sym.bin").symlink_to(a)
        sub = library.disk_bytes([root], root.stat().st_dev) - base   # 硬链接 + 软链：数据不重复算，只多一个子目录的元数据
        self.assertLess(sub, 64 * 1024)
        write(root / "b.bin", MIB)
        self.assertEqual(library.disk_bytes([root], root.stat().st_dev) - base - sub, MIB)   # 新增一份真数据 = 正好 1 MiB
        self.assertEqual(library.disk_bytes([root, root / "sub", a], root.stat().st_dev), base + sub + MIB)   # 根互相包含也只算一次
        self.assertEqual(library.disk_bytes([root], root.stat().st_dev + 1), 0)   # 别的卷上的不算

    def test_record_measures_library_dirs_before_prune(self):
        # 打 iPhone 包成功后的自动清理（prune_build）先记一行：要清掉的中间产物也算进去（量的是峰值，不是清完剩下的）
        c = self.context("ipa")
        game = self.game(10 * 10**9)
        library.atomic(self.c.library / "catalog.json", dict(schema=1, games=[game]))
        ios = layout.ios_work(self.c, GID)   # iPhone 出包工作目录 build/ios
        extract = write(layout.build_dir(self.c, GID) / "extract" / "romfs.bin", MIB)
        write(ios / "junk.tmp", 2 * MIB)   # 成功后会被清掉的中间产物
        (ios / "roots" / "r@1").mkdir(parents=True)
        os.link(extract, ios / "roots" / "r@1" / "romfs.bin")   # 产物根硬链解包：不重复算
        write(self.c.library / "runtime-cache" / GID / "play.bin", MIB)   # 玩的时候才长的运行时缓存：不算
        write(layout.ios_work(self.c, "0100000000000001") / "other.bin", MIB)   # 别款：不算
        library.prune_build(c, GID)
        self.assertFalse((ios / "junk.tmp").exists())   # 清理照常
        lines = [l.split("\t") for l in (self.c.library / library.SPACE_LEDGER).read_text(encoding="utf-8").splitlines() if not l.startswith("#")]
        self.assertEqual(len(lines), 1)
        r = dict(zip(library.SPACE_LEDGER_FIELDS, lines[0]))
        self.assertEqual((r["gameId"], r["target"], r["direct"], r["inputBytes"], r["name"]), (GID, "ipa", "1", str(10 * 10**9), "塞尔达传说 旷野之息"))
        fp = int(r["footprintBytes"])
        self.assertGreaterEqual(fp, 3 * MIB); self.assertLess(fp, 3 * MIB + 64 * 1024)   # 1 MiB 解包（硬链接那份不重算）+ 2 MiB 中间产物
        self.assertTrue((self.c.library / library.SPACE_LEDGER).read_text(encoding="utf-8").startswith("# time\tgameId"))

    # —— 预算三档依据 ——
    # 期望值手算：29.13 GB × 1.1 + 15 GB；验收数 火纹 ≈ 47、0100F2C0115B6000 ≈ 34、小游戏 ≈ 8（维护者 11-08）。单文件镜像不再存进库（#329），不另加一份
    def need(self, size, **kw):
        return library.pack_need_bytes([dict(size=size, sha256="a" * 64)], **kw)

    def test_formula_acceptance_numbers(self):
        self.assertEqual(self.need(29_130_000_000, windows=False), 32_043_000_000 + 15_000_000_000)
        self.assertEqual(self.need(17_480_000_000, windows=False), 19_228_000_000 + 15_000_000_000)
        self.assertEqual(self.need(2_700_000_000, windows=False), 2_970_000_000 + 5_000_000_000)

    def test_shared_original_sums_item_contents(self):
        # #444：一个压缩合集（XCZ）装本体 + 更新，原件 10 GB，两项解开各 8 GB、6 GB → 要按 14 GB 算；原先只留最后一项 → max(10, 6) = 10 GB
        shared = [dict(size=10_000_000_000, contentBytes=8_000_000_000, sha256="b" * 64),
                  dict(size=10_000_000_000, contentBytes=6_000_000_000, sha256="b" * 64)]
        self.assertEqual(library.pack_input_bytes(shared), 14_000_000_000)
        # 不压缩的合集 / NUP：各项之和不超过原件 → 仍按原件；另一个原件照加
        nup = [dict(size=10_000_000_000, contentBytes=7_000_000_000, sha256="c" * 64),
               dict(size=10_000_000_000, contentBytes=2_000_000_000, sha256="c" * 64),
               dict(size=3_000_000_000, sha256="d" * 64)]
        self.assertEqual(library.pack_input_bytes(nup), 13_000_000_000)

    def test_nup_items_overlap_take_largest(self):
        # NUP 容器内按块去重，更新是整份文件系统、和本体共用数据块：0400486024DEC000 实测文件 25.62 GB、本体与更新各 26.27 GB
        #   → 按 26.27 GB 算（取大值）；相加会成 52.54 GB（v0.2.5 的回退）。同一 sha 里只要有一项是 nup 就按这条算
        nup = [dict(size=25_622_267_860, contentBytes=26_270_000_000, sha256="e" * 64, format="nup"),
               dict(size=25_622_267_860, contentBytes=26_270_000_000, sha256="e" * 64, format="nup")]
        self.assertEqual(library.pack_input_bytes(nup), 26_270_000_000)
        # 另一个原件（非 nup）照旧单独加上
        self.assertEqual(library.pack_input_bytes(nup + [dict(size=3_000_000_000, sha256="f" * 64, format="nsp")]), 29_270_000_000)

    def test_unpacked_counts_zero_and_windows_adds_a_copy(self):
        self.assertEqual(self.need(10_000_000_000, unpacked=True, windows=False), 15_000_000_000)
        self.assertEqual(self.need(10_000_000_000, windows=True), 11_000_000_000 * 2 + 15_000_000_000)
        # v0.3.1 Mac 放开 HFS+：不能克隆，同 Windows 多算一份（11 + 11 + 15）
        self.assertEqual(library.pack_need_bytes([dict(size=10_000_000_000, sha256="a" * 64)], windows=False, clones=False), 11_000_000_000 * 2 + 15_000_000_000)

    def test_windows_exfat_location_counts_two_more_copies(self):
        # v0.3.1：Windows 存放位置在 exFAT / FAT32（建不了目录链接，实目录模式 + 工作根整份拷）：再多两份。原件 10 GB 的 iPhone 包：
        #   NTFS = 解包 11 + Windows 不克隆 11 + 直连 15 = 37 GB（IMG 边写边腾解包、不另占，#746）；exFAT 再加 22 = 59 GB
        c = self.context("ipa")
        for fmt, need in (("ntfs", 37_000_000_000), ("exfat", 59_000_000_000)):
            import space_rule
            with self.subTest(fmt=fmt), as_windows(library, space_rule), patch.object(library, "volume_format", return_value=fmt):
                b = self.budget(c, self.game(10 * 10**9))
                self.assertEqual(b["needBytes"], need)
                self.assertEqual("建不了目录链接" in b.get("note", ""), fmt == "exfat")

    def test_budget_counts_extra_copy_on_hfs(self):
        # 存放位置读到是 HFS+：预算按不克隆多算一份、说明里写清；读到 APFS / 读不到：不多算。原件 10 GB 的 Mac 出包（不写 IMG）：
        #   APFS 11 + 15 = 26 GB；HFS+ 再加 11 = 37 GB
        c = self.context("build")
        for fmt, need in (("apfs", 26_000_000_000), ("", 26_000_000_000), ("hfs", 37_000_000_000)):
            with self.subTest(fmt=fmt), patch.object(library, "volume_format", return_value=fmt):
                b = self.budget(c, self.game(10 * 10**9))
                self.assertEqual(b["needBytes"], need)
                self.assertEqual("不能克隆" in b.get("note", ""), fmt == "hfs")

    def test_budget_splits_location_and_cache_volumes(self):
        # P1-165：存放位置与工具缓存在两块盘时，各按自己那份需求和自己的余量判；期望手算：原件 16 GB → 存放位置 16 × 1.1 = 17.6 GB
        #   （打 iPhone 包写 game.img 在存放位置，边写边腾解包、不另占，#746），工具缓存 15 GB（≥ 3 GB 档）
        c = self.context("ipa")
        loc, cache = Path(self.root) / "ext", Path(self.root) / "cache"
        class St:   # 两个假卷号
            def __init__(self, dev): self.st_dev = dev
        disks = {str(loc): (1, 20 * 10**9), str(cache): (2, 10 * 10**9)}
        fake = lambda path: type("V", (), {"stat": lambda self, d=disks[str(path)][0]: St(d), "__fspath__": lambda self, p=str(path): p,
                                           "__str__": lambda self, p=str(path): p})()
        with patch.object(library, "_existing", side_effect=lambda p: fake(loc if p != c.work_root else cache)), \
                patch("shutil.disk_usage", side_effect=lambda p: DU(0, 0, disks[os.fspath(p)][1])), \
                patch.object(library, "_volume", side_effect=lambda p: os.fspath(p)):
            vols = library.space_budget(c, self.game(16 * 10**9))["volumes"]
        self.assertEqual([(v["role"], v["needBytes"], v["freeBytes"], v["enough"]) for v in vols],
                         [("library", 17_600_000_000, 20 * 10**9, True), ("cache", 15_000_000_000, 10 * 10**9, False)])
        # 同一块盘：合成一项，需求 = 两份之和（同原来）
        self.assertEqual(self.budget(c, self.game(16 * 10**9))["needBytes"], 17_600_000_000 + 15_000_000_000)

    def test_direct_cache_follows_game_volume(self):
        # 11-10 网友：存放位置设到外接盘，系统盘仍被写满。直连缓存（含编译中的翻译中间产物）跟着游戏的存放位置走：
        #   同一块盘 → 工具缓存下（同原来）；游戏在另一块盘 → 这款文件夹第一层 direct-cache/；还没有游戏文件夹 → 工具缓存
        c = self.context("ipa")
        tool = c.work_root / "run" / "s2arm" / "cache" / "direct" / GID
        game_dir = Path(self.root) / "ext" / "games" / GID
        class St:
            def __init__(self, dev): self.st_dev = dev
        def existing(dev_of_game):
            return lambda p: type("V", (), {"stat": lambda self: St(dev_of_game if Path(p) == game_dir else 1)})()
        with patch.object(library.layout, "find_game", return_value=game_dir), patch.object(library, "_existing", side_effect=existing(1)):
            self.assertEqual(library.direct_cache_dir(c, GID), tool)
        with patch.object(library.layout, "find_game", return_value=game_dir), patch.object(library, "_existing", side_effect=existing(2)):
            self.assertEqual(library.direct_cache_dir(c, GID), game_dir / "direct-cache")
        with patch.object(library.layout, "find_game", return_value=None):
            self.assertEqual(library.direct_cache_dir(c, GID), tool)

    def test_ledger_does_not_change_budget(self):
        c = self.context("ipa")
        self.ledger(("2026-11-07T10:00:00", GID, "ipa", "1", 16 * 10**9, 500 * 10**9, "旧账"))
        v = self.budget(c, self.game(16 * 10**9))
        self.assertEqual((v["basis"], v["needBytes"]), ("rule", 17_600_000_000 + 15_000_000_000))   # 解包 17.6 + 直连 15（IMG 边写边腾解包）

    def test_rejection_names_need_and_free(self):
        with patch("shutil.disk_usage", return_value=DU(0, 0, 20 * 10**9)):
            with self.assertRaises(Failure) as e:
                library.check_pack_space(self.context("ipa"), self.game(16 * 10**9))
        self.assertEqual(e.exception.code, "disk_full")
        self.assertIn("要 33 GB", str(e.exception));   # 16 × 1.1 + 直连 15 = 32.6 → 33 GB（IMG 边写边腾解包，#746）
        self.assertIn("解包 18 GB", str(e.exception)); self.assertIn("直连着色器上限 15 GB", str(e.exception))   # 分项（#746）
        self.assertIn("只剩 20 GB", str(e.exception)); self.assertIn("「仍然继续」", str(e.exception))

    def test_mac_build_has_no_image_and_ocarina_peak_is_covered(self):
        # 单一 IMG 只在打 iPhone 包时写（Mac 打包不写）。#746：写 IMG 时边写边腾解包，iPhone 包和 Mac 打包一样多；
        #   同一款接着还要出别的平台（followUp）留着解包，IMG 照旧另占一份。
        #   11-11 实测 0400486024DEC000（NUP，资源 26.27 GB）冷出 iPhone 包、不边写边腾时整次峰值 57.90 GiB（写 game.img 时）：留解包的预留须 ≥ 峰值且 ≤ 峰值 × 1.2。
        #   手算：26.27 × 1.1 + IMG 26.27 + 直连 15 = 70.167 GB；峰值 57.90 GiB = 62.17 GB；比值 1.13
        mac, ipa = self.budget(self.context("build"), self.game(16 * 10**9))["needBytes"], self.budget(self.context("ipa"), self.game(16 * 10**9))["needBytes"]
        self.assertEqual(ipa, mac)
        keep = self.budget(self.context("ipa", followUp=True), self.game(16 * 10**9))["needBytes"]
        self.assertEqual(keep - mac, 16 * 10**9)
        need = library.pack_need_bytes([dict(size=25_622_267_860, contentBytes=26_270_000_000, sha256="b" * 64, format="nup")], windows=False, image=True, keep_unpack=True)
        self.assertEqual(need, 70_167_000_000)
        peak = int(57.90 * 2**30)
        self.assertGreaterEqual(need, peak)
        self.assertLessEqual(need, peak * 1.2)

    def test_old_iphone_pack_counts_as_reclaimable_and_override_drops_it_first(self):
        # #746：这款上一次出的 iPhone 资源包出完会被新包换掉。空间不够时失败页点名它、说「仍然继续会先删掉它」；
        #   点了「仍然继续」先删掉它再出（旧包和新包同时在盘上那段原先是峰值的一部分）；一键装 / Mac 打包不算它
        c = self.context("ipa")
        old = library.layout.image_ios(c, GID) / library.layout.IOS_PACK
        write(old / "game.img", 1 << 20)
        v = self.budget(c, self.game(16 * 10**9), free=20 * 10**9)
        self.assertGreaterEqual(v["reclaimBytes"], 1 << 20)
        self.assertEqual(self.budget(self.context("build"), self.game(16 * 10**9))["reclaimBytes"], 0)
        with patch("shutil.disk_usage", return_value=DU(0, 0, 20 * 10**9)):
            with self.assertRaises(Failure) as e:
                library.check_pack_space(c, self.game(16 * 10**9))
        self.assertIn("点「仍然继续」会先删掉这款上一次的 iPhone 包，腾出", str(e.exception))
        self.assertTrue(old.is_dir())   # 只问，不删
        c = self.context("ipa", spaceOverride=True)
        with patch("shutil.disk_usage", return_value=DU(0, 0, 20 * 10**9)):
            library.check_pack_space(c, self.game(16 * 10**9))
        self.assertFalse(old.exists())
        [d] = c.job["diagnostics"]
        self.assertIn("已按你的选择先删掉这款上一次的 iPhone 包", d["summary"])

    def test_player_746_numbers(self):
        # #746 玩家原数：NUP 原件 43.46 GB、可用 36.86 GB、库里旧 iPhone 包 29 GB（升级后解包不在盘上）。独立手算：
        #   预估 = 解包 43.46 × 1.1 = 47.806（显示 48 GB）+ 直连 15 = 62.806 → 「要 63 GB」（原先再加 IMG 43.46 = 106.27）；
        #   不够 → 失败页给「仍然继续」并说会先删旧包腾出 29 GB；删后 36.86 + 29 = 65.86 ≥ 62.8，放得下
        c = self.context("ipa")
        old = library.layout.image_ios(c, GID) / library.layout.IOS_PACK
        write(old / "game.img", 1 << 20)
        nup = dict(id=GID, name="x", packages=[dict(titleId=GID, baseId=GID, type="base", version=0, path="sources/x.nsp", sha256="c" * 64,
                                                     size=43_460_000_000, contentBytes=43_460_000_000, format="nup", guestIsa="aarch64")])
        with patch.object(library, "_part_bytes", return_value=29 * 10**9), patch("shutil.disk_usage", return_value=DU(0, 0, 36_860_000_000)):
            v = library.space_budget(c, nup)["volumes"][0]
            self.assertEqual((v["needBytes"], v["reclaimBytes"]), (62_806_000_000, 29 * 10**9))
            self.assertLessEqual(v["needBytes"], v["freeBytes"] + v["reclaimBytes"])
            with self.assertRaises(Failure) as e:
                library.check_pack_space(c, nup)
        msg = str(e.exception)
        for want in ("要 63 GB", "解包 48 GB", "直连着色器上限 15 GB", "只剩 37 GB", "点「仍然继续」会先删掉这款上一次的 iPhone 包，腾出 29 GB"):
            self.assertIn(want, msg)

    def test_space_override_passes_with_warning(self):
        c = self.context("ipa", spaceOverride=True)
        with patch("shutil.disk_usage", return_value=DU(0, 0, 20 * 10**9)):
            budget = library.check_pack_space(c, self.game(16 * 10**9))
        self.assertTrue(budget["override"]); self.assertFalse(budget["volumes"][0]["enough"])
        [d] = c.job["diagnostics"]
        self.assertEqual((d["code"], d["severity"]), ("disk_full", "warning"))
        self.assertIn("已按你的选择仍然继续", d["summary"])

    def test_follow_up_request_contract(self):
        # 剃刀 M21：followUp 只给打 iPhone 包、只认布尔值（期望按 pack/contracts/README.md 手写）
        self.context("ipa", followUp=True); self.context("ipa", followUp=False)
        for op, value in (("build", True), ("ipa", "true"), ("catalog", True)):
            with self.subTest(op=op, value=value), self.assertRaises(Failure):
                self.context(op, followUp=value)
        base = dict(schema=1, contract="s2a.job-request.v1", privateRoot="/p", library="/l", libraryId="x", gameId=GID)
        validate("request", base | dict(operation="ipa", followUp=True))
        with self.assertRaises(ContractError):
            validate("request", base | dict(operation="ipa", followUp="yes"))

    def test_space_override_request_contract(self):
        self.context("build", spaceOverride=True); self.context("ipa", spaceOverride=False)
        for op, value in (("catalog", True), ("ipa", "true"), ("build", 1), ("launch", True)):
            with self.subTest(op=op, value=value), self.assertRaises(Failure):
                self.context(op, spaceOverride=value)
        base = dict(schema=1, contract="s2a.job-request.v1", privateRoot="/p", library="/l", libraryId="x", gameId=GID)
        validate("request", base | dict(operation="build", spaceOverride=True))
        validate("request", base | dict(operation="ipa", spaceOverride=False))
        for bad in (dict(operation="catalog", spaceOverride=True), dict(operation="ipa", spaceOverride="true")):
            with self.subTest(bad=bad), self.assertRaises(ContractError):
                validate("request", base | bad)


if __name__ == "__main__":
    unittest.main()
