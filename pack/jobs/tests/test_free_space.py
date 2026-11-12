# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""启动器「释放空间」+ 游戏库位置预检（11-07）：云盘同步目录、卷格式（Mac / Windows 同一套判法）、按部件统计与删除。
全为合成路径 / 合成文件，期望值按规则手写。"""
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from jobcase import JobCase, ROOT, as_windows
from core import Context, Failure
import filelock
import libloc
import layout
import library

sys.path.insert(0, str(ROOT))
from pack.contracts.validate import validate, ContractError

MIB = 1 << 20
SLACK = 64 * 1024   # 目录元数据余量（APFS 目录 0 块）
GID = "0100F2C0115B6000"
OTHER = "0100000000000001"


def write(path, size):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(os.urandom(size))   # 随机内容：不让文件系统压缩 / 稀疏
    return path


class CloudFolder(unittest.TestCase):
    def test_mac(self):
        home = "/Users/player"
        cases = {
            "/Users/player/Library/Mobile Documents/com~apple~CloudDocs/S2Arm 游戏库": "iCloud 云盘",
            "/Users/player/Library/Mobile Documents": "iCloud 云盘",
            "/Users/player/Library/CloudStorage/OneDrive-Personal/库": "云盘（文件提供程序）",
            "/Users/player/Library/CloudStorage/Dropbox/库": "云盘（文件提供程序）",
            "/Users/player/Library/Mobile Documents2/库": None,   # 只是前缀相同，不是同一个目录
            "/Users/player/Library/Application Support/S2Arm/library": None,   # 缺省位置
            "/Volumes/Example/游戏库": None,
            "/Users/player/Documents/S2Arm": None,   # 没给 exists：不判「桌面与文稿」
        }
        for path, want in cases.items():
            with self.subTest(path=path):
                self.assertEqual(libloc.cloud_folder(path, system="Darwin", home=home), want)

    def test_mac_desktop_documents_only_when_synced(self):
        home = "/Users/player"
        marker = "/Users/player/Library/Mobile Documents/com~apple~CloudDocs/Desktop"
        synced, local = (lambda p: p == marker), (lambda p: False)
        for path in ("/Users/player/Documents/S2Arm", "/Users/player/Desktop/库"):
            with self.subTest(path=path):
                self.assertEqual(libloc.cloud_folder(path, system="Darwin", home=home, exists=synced), "iCloud 云盘（桌面与文稿同步）")
                self.assertIsNone(libloc.cloud_folder(path, system="Darwin", home=home, exists=local))
        self.assertIsNone(libloc.cloud_folder("/Users/player/Downloads/库", system="Darwin", home=home, exists=synced))

    def test_windows(self):
        home = "C:\\Users\\player"
        env = {"OneDrive": "C:\\Users\\player\\OneDrive", "OneDriveCommercial": "D:\\OneDrive - 公司"}
        cases = {
            "C:\\Users\\player\\OneDrive\\S2Arm": "OneDrive",
            "c:\\users\\player\\onedrive\\s2arm": "OneDrive",   # Windows 路径不分大小写
            "C:/Users/player/OneDrive/S2Arm": "OneDrive",   # 正斜杠也认
            "D:\\OneDrive - 公司\\库": "OneDrive",
            "C:\\Users\\player\\OneDriveX\\库": None,
            "C:\\Users\\player\\iCloudDrive\\库": "iCloud 云盘",
            "C:\\Users\\player\\Dropbox\\库": "Dropbox",
            "C:\\Users\\player\\Google Drive\\库": "Google 云端硬盘",
            "D:\\S2Arm\\游戏库": None,
            "C:\\Users\\player\\AppData\\Local\\S2Arm\\library": None,
        }
        for path, want in cases.items():
            with self.subTest(path=path):
                self.assertEqual(libloc.cloud_folder(path, system="Windows", home=home, env=env), want)
        self.assertIsNone(libloc.cloud_folder("C:\\Users\\player\\OneDrive\\x", system="Windows", home=home, env={}))   # 没装 OneDrive：缺省目录名不算

    def test_format_ok(self):
        for fmt, mac, win in (("apfs", True, False), ("APFS", True, False), ("hfs", True, False), ("exfat", True, False), ("msdos", False, False),
                              ("ntfs", False, True), ("NTFS", False, True), ("refs", False, True), ("fat32", False, False), ("", True, True)):
            with self.subTest(fmt=fmt):
                self.assertEqual(libloc.format_ok(fmt, system="Darwin"), mac)
                self.assertEqual(libloc.format_ok(fmt, system="Windows"), win)

    def test_problems_codes(self):
        self.assertEqual(libloc.problems("/Volumes/Example/库", system="Darwin", home="/Users/player", fmt="apfs"), [])
        self.assertEqual(libloc.problems("/Volumes/Example/库", system="Darwin", home="/Users/player", fmt="exfat"), [])
        got = libloc.problems("/Users/player/Library/Mobile Documents/x", system="Darwin", home="/Users/player", fmt="msdos")
        self.assertEqual([p["code"] for p in got], ["library_in_cloud", "library_not_apfs"])
        self.assertIn("iCloud 云盘", got[0]["message"]); self.assertIn("MSDOS", got[1]["message"])
        got = libloc.problems("E:\\库", system="Windows", home="C:\\Users\\player", fmt="exfat")
        self.assertEqual([p["code"] for p in got], ["library_bad_format"]); self.assertIn("NTFS", got[0]["message"])


class LocationSlack(unittest.TestCase):
    """#444：存放位置所在卷会让出包多占空间时提示（只提示不拦），原因说对。期望按规则手写：分配单元 ≥ 64 KB → cluster（先判）；格式不是推荐格式 → format"""
    def test_rule(self):
        K = 1024
        for fmt, cluster, system, want in [
                ("apfs", 4 * K, "Darwin", None),          # Mac 推荐格式、4 KB 块
                ("exfat", 512 * K, "Darwin", "cluster"),  # #444 玩家的外置盘：大簇优先
                ("exfat", 4 * K, "Darwin", "format"),     # 小簇 exFAT：不能克隆，多一份拷贝，不是「多占数倍」
                ("hfs", 4 * K, "Darwin", "format"),
                ("apfs", 64 * K, "Darwin", "cluster"),    # 分配单元到 64 KB 就提示
                ("apfs", 64 * K - 1, "Darwin", None),
                ("ntfs", 4 * K, "Windows", None),
                ("refs", 64 * K, "Windows", "cluster"),   # 推荐格式但大簇
                ("ntfs", 2048 * K, "Windows", "cluster"), # NTFS 大簇
                ("fat32", 32 * K, "Windows", "format"),
                ("exfat", 128 * K, "Windows", "cluster"),
                ("", 0, "Darwin", None),                  # 都读不到：不提示
                ("", 512 * K, "Darwin", "cluster"),       # 格式读不到、簇大
                ("APFS", 0, "Darwin", None)]:             # 大写也认、簇读不到
            with self.subTest(fmt=fmt, cluster=cluster, system=system):
                self.assertEqual(libloc.slack_reason(fmt, cluster, system=system), want)

    def test_location_slack_fields(self):
        probes = {"/外接盘/库": ("exfat", 512 << 10), "/小簇盘/库": ("exfat", 4096)}
        with patch.object(library, "volume_format", side_effect=lambda p: probes.get(str(p), ("apfs", 4096))[0]), \
             patch.object(library, "volume_cluster", side_effect=lambda p: probes.get(str(p), ("apfs", 4096))[1]), \
             patch.object(library.os, "name", "posix"):
            self.assertEqual(library.location_slack(Path("/外接盘/库")), dict(format="exfat", clusterBytes=512 << 10, slackWarning=True, slackReason="cluster"))
            self.assertEqual(library.location_slack(Path("/小簇盘/库")), dict(format="exfat", clusterBytes=4096, slackWarning=True, slackReason="format"))
            self.assertEqual(library.location_slack(Path("/本机盘/S2Arm")), dict(format="apfs", clusterBytes=4096, slackWarning=False, slackReason=None))


class LibraryGate(JobCase):
    def test_setup_rejects_cloud_before_writing(self):
        lib = self.root / "云盘里的库"; self.c.library = lib
        with patch.object(libloc, "cloud_folder", return_value="iCloud 云盘"), self.assertRaises(Failure) as e:
            library.setup(self.c)
        self.assertEqual(e.exception.code, "library_in_cloud"); self.assertIn("iCloud 云盘", str(e.exception))
        self.assertFalse(lib.exists())   # 拦在建目录之前

    def test_setup_cloud_confirmed_proceeds_and_is_remembered(self):
        # v0.3.1：云盘目录是认得出的风险——玩家确认（acceptCloud）后照建，选择记进游戏库标识（cloudAccepted）；
        #   之后再打开同一个库（启动时连已保存的库也走 setup，不带 acceptCloud）不再问、照常打开；别的云盘目录照旧先问
        lib = self.root / "云盘里的库"; self.c.library = lib; self.c.r["acceptCloud"] = True
        with patch.object(libloc, "cloud_folder", return_value="iCloud 云盘"):
            r = library.setup(self.c)
        self.assertEqual(r["outcome"], "created")
        self.assertTrue(libloc.cloud_accepted(str(lib)))
        self.assertFalse(libloc.cloud_accepted(str(self.root / "别的库")))   # 没记过 / 读不到：False
        self.c.r.pop("acceptCloud")
        with patch.object(libloc, "cloud_folder", return_value="iCloud 云盘"):
            self.assertEqual(library.setup(self.c)["outcome"], "opened")
        self.assertTrue(libloc.cloud_accepted(str(lib)))
        self.c.library = self.root / "另一个云盘里的库"
        with patch.object(libloc, "cloud_folder", return_value="iCloud 云盘"), self.assertRaises(Failure) as e:
            library.setup(self.c)
        self.assertEqual(e.exception.code, "library_in_cloud")

    def test_windows_exfat_library_confirmed_proceeds_and_is_remembered(self):
        # v0.3.1：Windows 游戏库在 exFAT / FAT32 上是认得出的风险——不带 acceptFormat 报 library_bad_format（文案说清多占空间、断电要重出），
        #   带了照建、选择记进标识（formatAccepted）；同一个库再打开不再问；别的 exFAT 文件夹照旧先问
        lib = self.root / "exFAT 盘上的库"; self.c.library = lib
        with as_windows(library), patch.object(library, "volume_format", return_value="exfat"), patch.object(libloc, "cloud_folder", return_value=None):
            with self.assertRaises(Failure) as e:
                library.setup(self.c)
            self.assertEqual(e.exception.code, "library_bad_format"); self.assertIn("多占", str(e.exception)); self.assertIn("NTFS", str(e.exception))
            self.c.r["acceptFormat"] = True
            self.assertEqual(library.setup(self.c)["outcome"], "created")
            self.assertTrue(libloc.format_accepted(str(lib)))
            self.c.r.pop("acceptFormat")
            self.assertEqual(library.setup(self.c)["outcome"], "opened")
            self.c.library = self.root / "另一个 exFAT 库"
            with self.assertRaises(Failure):
                library.setup(self.c)

    def test_exfat_message_says_how_much_more_space(self):
        # 文案只写玩家能据此选择的（11-12 维护者：不写断电之类）：按要搬过来的库里现有的款算多占多少。期望手算：
        #   两款原件 10 GB、3 GB → 每款多两份解包（× 1.1）：2 × (11 + 3.3) = 28.6 GB → 「多占约 29 GB」；exFAT 不提 4 GB，FAT32 提
        old = self.root / "旧库"; old.mkdir()
        g = lambda tid, size: dict(id=tid, packages=[dict(type="base", version=0, titleId=tid, sha256=tid.lower() * 4, size=size)])
        (old / "catalog.json").write_text(json.dumps(dict(schema=1, games=[g("0100000000000000", 10 * 10**9), g("0100000000001000", 3 * 10**9)])), encoding="utf-8")
        self.c.library = self.root / "exFAT 新库"; self.c.r["moveFrom"] = str(old)
        for fmt, has4g in (("exfat", False), ("fat32", True)):
            with self.subTest(fmt=fmt), as_windows(library), patch.object(library, "volume_format", return_value=fmt), \
                    patch.object(libloc, "cloud_folder", return_value=None), self.assertRaises(Failure) as e:
                library.setup(self.c)
            text = str(e.exception)
            self.assertIn("按现有 2 款游戏算，出包会多占约 29 GB", text); self.assertNotIn("断电", text)
            self.assertEqual("4 GB" in text, has4g)

    def test_fat32_stops_before_writing_only_when_image_over_4gb(self):
        # FAT32 单个文件 ≤ 4 GiB − 1：打 iPhone 包要写约等于游戏内容大小的单一 IMG。5 GiB 的款 → 出包开头 fat32_file_too_large、列出 NTFS 盘；
        #   3 GiB 的款照常；NTFS 存放位置不管多大都照常；Mac 打包（不写 IMG）不判
        def game(size):
            return dict(id="0100000000000000", packages=[dict(type="base", version=0, titleId="0100000000000000", sha256="a" * 64, size=size)])
        self.c.operation = "ipa"
        with as_windows(library), patch.object(library, "ntfs_drives", return_value=[("D:\\", "NTFS", 900 * 10**9)]):
            with patch.object(library, "volume_format", return_value="fat32"):
                with self.assertRaises(Failure) as e:
                    library.require_fat32_fits(self.c, game(5 << 30), "E:\\库")
                self.assertEqual(e.exception.code, "fat32_file_too_large"); self.assertIn("D:", str(e.exception)); self.assertIn("4 GB", str(e.exception))
                library.require_fat32_fits(self.c, game(3 << 30), "E:\\库")
                self.c.operation = "build"; library.require_fat32_fits(self.c, game(5 << 30), "E:\\库"); self.c.operation = "ipa"
            with patch.object(library, "volume_format", return_value="ntfs"):
                library.require_fat32_fits(self.c, game(50 << 30), "D:\\库")

    def test_copy_tree_links_materializes_when_target_has_no_links(self):
        # 搬库 / 移动游戏到建不了链接的盘：链接指向的目录整份拷过来；产物根的 <款>@现行 拷成真目录、版本名记进 .root_tag（roots 实目录模式按它认）
        src = self.root / "src"; (src / "roots" / "款@v1").mkdir(parents=True); (src / "roots" / "款@v1" / "f").write_bytes(b"v1")
        os.symlink("款@v1", src / "roots" / "款@现行")
        dst = self.root / "dst"
        real = os.symlink
        def no_dir_links(a, b, target_is_directory=False, **kw):
            if target_is_directory:
                raise OSError(1, "Incorrect function")
            return real(a, b, **kw)
        with patch.object(library.os, "symlink", no_dir_links):
            library.copy_tree_links(src, dst)
        live = dst / "roots" / "款@现行"
        self.assertFalse(live.is_symlink()); self.assertEqual((live / "f").read_bytes(), b"v1")
        self.assertEqual((live / ".root_tag").read_text(encoding="utf-8").strip(), "款@v1")

    def test_require_apfs_windows_wants_ntfs(self):
        with as_windows(library):
            for fmt in ("exfat", "fat32"):
                with self.subTest(fmt=fmt), patch.object(library, "volume_format", return_value=fmt), self.assertRaises(Failure) as e:
                    library.require_apfs("E:\\库")
                self.assertEqual(e.exception.code, "library_bad_format"); self.assertIn(fmt.upper(), str(e.exception))
            for fmt in ("ntfs", "refs", ""):
                with self.subTest(fmt=fmt), patch.object(library, "volume_format", return_value=fmt):
                    self.assertEqual(library.require_apfs("D:\\库"), fmt)

    def test_mac_preflight_reports_cloud(self):
        import toolchain
        seen = []
        def run(path):
            seen.clear()
            self.c.r["library"] = path
            with patch.object(library, "volume_format", return_value="apfs"), \
                 patch.object(self.c, "emit", lambda kind, *a, **kw: seen.append(kw.get("check")) if kind == "check" else None):
                try:
                    toolchain.preflight(self.c)
                except Exception:
                    pass   # 后面的工具探测与本测无关
            return next((x for x in seen if x and x["name"] == "游戏库所在位置"), None)
        row = run(str(Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/S2Arm"))
        self.assertIsNotNone(row)
        self.assertEqual((row["ok"], row["group"], row["action"], row["diagnostic"]["code"]), (False, "storage", "library", "library_in_cloud"))
        row = run("/Volumes/Example/游戏库")
        self.assertTrue(row["ok"])
        # 玩家确认过放在云盘里（游戏库标识 cloudAccepted）：照提示（已按你的选择继续用），不算要处理
        lib = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/S2Arm"
        with patch.object(libloc, "cloud_accepted", side_effect=lambda p: p == str(lib)):
            row = run(str(lib))
        self.assertTrue(row["ok"]); self.assertIn("已按你的选择继续用", str(row))


class FreeSpace(JobCase):
    def setUp(self):
        super().setUp()
        games = [dict(id=g, name=n, packages=[]) for g, n in ((GID, "异度神剑3"), (OTHER, "别款"))]
        library.atomic(self.c.library / "catalog.json", dict(schema=1, games=games))
        L, P, W = self.c.library, self.c.private, self.c.work_root
        ios = layout.ios_work(self.c, GID)   # iPhone 出包工作目录 build/ios
        self.files = {
            "legacy": [write(layout.build_dir(self.c, GID) / "extract" / "romfs.bin", 1 * MIB), write(ios / "roots" / "r@1" / "a.bin", 2 * MIB), write(ios / "build.tmp", 1 * MIB)],
            "shaders": [write(W / "run" / "s2arm" / "cache" / "direct" / GID / "lib.bin", 2 * MIB),
                        write(W / "run" / "s2arm" / "cache" / "bake" / f"{GID.lower()}-x" / "b.bin", 1 * MIB)],
            "mac": [write(layout.image_mac(self.c, GID) / "app.bin", 1 * MIB)],
            "ipa": [write(layout.image_ios(self.c, GID) / "kit" / "main.patched.bin", 3 * MIB), write(layout.image_ios(self.c, GID) / "pack" / "r.bin", 1 * MIB)],
            "saves": [write(layout.path(self.c, GID, "saves") / "slot0.bin", 1 * MIB)],
            "logs": [write(ios / "logs" / "build.log", 1 * MIB)],   # 在 build/ 里，但不算「旧版残留」，只报不删
        }
        self.mib = {"legacy": 4, "shaders": 3, "mac": 1, "ipa": 4, "saves": 1, "logs": 1}
        self.shared = [write(W / "cache" / "air" / "shared.bin", 1 * MIB)]   # 各款共用的编库缓存：不归任何一款
        self.other = [write(layout.build_dir(self.c, OTHER) / "x.bin", 1 * MIB), write(layout.image_ios(self.c, OTHER) / "pack" / "o.bin", 1 * MIB)]

    def context(self, operation, **extra):
        self.sequence += 1
        return Context(self.request | dict(taskId=f"free-{self.sequence}", operation=operation) | extra)

    def assert_mib(self, got, mib):
        self.assertGreaterEqual(got, mib * MIB); self.assertLess(got, mib * MIB + SLACK)

    def test_survey_lists_each_part(self):
        out = library.space_survey(self.context("spaceSurvey", gameId=GID))
        self.assertEqual(len(out["games"]), 1)
        g = out["games"][0]
        self.assertEqual((g["gameId"], g["name"]), (GID, "异度神剑3"))
        self.assertEqual([p["id"] for p in g["parts"]], ["legacy", "shaders", "mac", "ipa"])
        self.assertEqual([k["id"] for k in g["kept"]], ["saves", "logs"])
        for row in g["parts"] + g["kept"]:
            with self.subTest(part=row["id"]):
                self.assert_mib(row["bytes"], self.mib[row["id"]])
        self.assertTrue(all(p["title"] and p["rebuild"] for p in g["parts"]))
        self.assert_mib(g["sharedBytes"], 0)   # 这套合成文件各项不共用
        self.assert_mib(g["combos"]["ipa+mac"], 5)
        everyone = library.space_survey(self.context("spaceSurvey"))
        self.assertEqual([g["gameId"] for g in everyone["games"]], [GID, OTHER])
        other = everyone["games"][1]
        self.assert_mib(sum(p["bytes"] for p in other["parts"] if p["id"] == "legacy"), 1)
        self.assert_mib(sum(p["bytes"] for p in other["parts"] if p["id"] == "ipa"), 1)
        with self.assertRaises(Failure):
            library.space_survey(self.context("spaceSurvey", gameId="0100000000000FFF"))

    def test_free_deletes_only_chosen_parts(self):
        out = library.space_free(self.context("spaceFree", gameId=GID, library=str(self.c.library), parts=["ipa", "shaders"]))
        self.assertEqual(out["gameId"], GID)
        self.assertEqual([p["id"] for p in out["parts"]], ["shaders", "ipa"])   # 按部件表顺序
        self.assert_mib(out["parts"][0]["bytes"], 3); self.assert_mib(out["parts"][1]["bytes"], 4)
        self.assertEqual(out["freedBytes"], sum(p["bytes"] for p in out["parts"]))
        for k, paths in self.files.items():
            for p in paths:
                with self.subTest(part=k, path=p.name):
                    self.assertEqual(p.exists(), k not in ("ipa", "shaders"))
        for p in self.shared + self.other:
            self.assertTrue(p.exists(), p)   # 共用缓存、别款都不动
        self.assertTrue(self.files["logs"][0].exists())

    def test_free_everything_keeps_saves_and_logs(self):
        ids = [k for k, _, _ in library.SPACE_PARTS]
        out = library.space_free(self.context("spaceFree", gameId=GID, library=str(self.c.library), parts=ids))
        self.assert_mib(out["freedBytes"], sum(self.mib[k] for k in ids))
        for k, paths in self.files.items():
            for p in paths:
                self.assertEqual(p.exists(), k in ("saves", "logs"), p)

    def test_free_rejects_bad_parts_and_busy_library(self):
        for bad in (["saves"], ["logs"], ["ipa", "games"]):
            with self.subTest(parts=bad), self.assertRaises(Failure):
                library.space_free(self.context("spaceFree", gameId=GID, library=str(self.c.library), parts=bad))
        with (self.c.library / ".execution.lock").open("a") as f:   # 另一个任务在跑
            filelock.try_lock(f)
            try:
                with self.assertRaises(Failure) as e:
                    library.space_free(self.context("spaceFree", gameId=GID, library=str(self.c.library), parts=["ipa"]))
                self.assertIn("另一个任务", str(e.exception))
            finally:
                filelock.unlock(f)
        self.assertTrue(all(p.exists() for p in self.files["ipa"]))

    def test_request_contract(self):
        base = dict(schema=1, contract="s2a.job-request.v1", privateRoot="/p", library="/l", gameId=GID)
        validate("request", base | dict(operation="spaceFree", parts=["ipa"]))
        validate("request", base | dict(operation="spaceSurvey"))
        for bad in (dict(operation="spaceFree"), dict(operation="spaceFree", parts=[]), dict(operation="spaceFree", parts=["saves"])):
            with self.subTest(bad=bad), self.assertRaises(ContractError):
                validate("request", base | bad)

    def test_worker_end_to_end(self):
        # 真 worker 协议（main.py --request）：两项作业已登记，结果走终态事件
        result, event = self.worker("spaceSurvey", gameId=GID)
        self.assertEqual((result.returncode, event["state"]), (0, "succeeded"), result.stderr)
        self.assertEqual(event["result"]["games"][0]["gameId"], GID)
        result, event = self.worker("spaceFree", gameId=GID, parts=["legacy"])
        self.assertEqual((result.returncode, event["state"]), (0, "succeeded"), result.stderr)
        self.assert_mib(event["result"]["freedBytes"], 4)
        self.assertFalse(self.files["legacy"][0].exists()); self.assertTrue(self.files["ipa"][0].exists())



class SharedBlocks(JobCase):
    """几项共用的块（APFS 克隆族 / 硬链接）只在都勾上时才算腾出。玩家报：Mac 运行版本和 iPhone 包的 romfs 是同一组克隆块，
    各项单独量相加显示 15.45 + 15.13 GB，单删 iPhone 包实际只腾出约 1.5 GB。期望值按文件大小手算（各项另有独占文件）"""
    def setUp(self):
        super().setUp()
        self.d = self.root / "parts"
        self.mac, self.ipa, self.elsewhere = self.d / "mac", self.d / "ipa", self.d / "elsewhere"

    def clone(self, src, dst):
        import subprocess
        dst.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["cp", "-c", str(src), str(dst)], check=True)
        if library._CloneInfo.get(str(dst)) is None:
            self.skipTest("这块盘取不到 APFS 克隆信息")

    def assert_mib(self, got, mib):
        self.assertGreaterEqual(got, mib * MIB); self.assertLess(got, mib * MIB + SLACK)

    @unittest.skipUnless(sys.platform == "darwin", "APFS 克隆只在 macOS")
    def test_clone_family_freed_only_when_every_copy_is_chosen(self):
        write(self.mac / "romfs" / "big.bin", 4 * MIB); self.clone(self.mac / "romfs" / "big.bin", self.ipa / "pack" / "romfs" / "big.bin")
        write(self.mac / "app.bin", 1 * MIB); write(self.ipa / "kit.bin", 2 * MIB)
        got = library.freeable({"mac": [self.mac], "ipa": [self.ipa]})
        self.assert_mib(got["mac"], 1); self.assert_mib(got["ipa"], 2); self.assert_mib(got["ipa+mac"], 7)

    @unittest.skipUnless(sys.platform == "darwin", "APFS 克隆只在 macOS")
    def test_copy_outside_the_chosen_parts_keeps_the_blocks(self):
        write(self.mac / "romfs" / "big.bin", 4 * MIB)
        self.clone(self.mac / "romfs" / "big.bin", self.ipa / "romfs" / "big.bin")
        self.clone(self.mac / "romfs" / "big.bin", self.elsewhere / "big.bin")   # 第三份在两项之外（别款 / 没列的目录）
        got = library.freeable({"mac": [self.mac], "ipa": [self.ipa]})
        self.assert_mib(got["ipa+mac"], 0)

    def test_hard_link_freed_only_when_every_link_is_chosen(self):
        a = write(self.mac / "a.bin", 3 * MIB); self.ipa.mkdir(parents=True); os.link(a, self.ipa / "a.bin")
        write(self.ipa / "own.bin", 1 * MIB)
        got = library.freeable({"mac": [self.mac], "ipa": [self.ipa]})
        self.assert_mib(got["mac"], 0); self.assert_mib(got["ipa"], 1); self.assert_mib(got["ipa+mac"], 4)
        os.link(a, self.root / "outside.bin")   # 还有一条链接在外面：都勾也腾不出
        self.assert_mib(library.freeable({"mac": [self.mac], "ipa": [self.ipa]})["ipa+mac"], 1)

    def test_nested_roots_count_once(self):
        write(self.mac / "sub" / "x.bin", 2 * MIB)
        self.assert_mib(library.freeable({"mac": [self.mac, self.mac / "sub"]})["mac"], 2)


if __name__ == "__main__":
    unittest.main()
