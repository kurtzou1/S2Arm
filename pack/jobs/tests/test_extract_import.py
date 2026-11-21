"""解包目录导入单测（pack/jobs/library.py import_games 支持 dump / extract / loose 三种解包目录，11-08）。"""
import unittest
from pathlib import Path

from jobcase import JobCase, synthetic_npdm, synthetic_nacp


class ExtractImportTests(JobCase):
    """三种解包目录导入：dump（Switch 2 导出）、extract（S2Arm 解包）、loose（通用解包），都不要 prod.keys"""

    def make_dump(self, root, tid, name="DumpGame"):
        """Switch 2 导出目录：base/exefs/main.npdm + main，可选 ctl/control.nacp + icon.jpg"""
        (root / "base" / "exefs").mkdir(parents=True)
        (root / "base" / "exefs" / "main.npdm").write_bytes(synthetic_npdm(tid))
        (root / "base" / "exefs" / "main").write_bytes(b"\x01" * 500)
        (root / "base" / "romfs").mkdir(parents=True)
        (root / "base" / "romfs" / "data.bin").write_bytes(b"BASE_DATA" * 100)
        # 可选控制分区
        if name != "DumpGame":
            (root / "ctl").mkdir(parents=True)
            (root / "ctl" / "control.nacp").write_bytes(synthetic_nacp(name, "1.0.0"))
            (root / "ctl" / "icon.jpg").write_bytes(b"DUMP_ICON")
        return root

    def make_extract(self, root, tid, name="ExtractGame", name_zh="提取游戏"):
        """S2Arm 解包目录：exefs/main + main.npdm，unpack.tsv"""
        (root / "exefs").mkdir(parents=True)
        (root / "exefs" / "main").write_bytes(b"\x02" * 400)
        (root / "exefs" / "main.npdm").write_bytes(synthetic_npdm(tid))
        (root / "romfs").mkdir(parents=True)
        (root / "romfs" / "data.bin").write_bytes(b"EXTRACT_DATA" * 80)
        tsv = f"title_id\t{tid:016X}\nname\t{name}\nname_zh\t{name_zh}\ndisplay_version\t2.1.0\n"
        (root / "unpack.tsv").write_text(tsv, encoding="utf-8")
        # 可选封面
        (root / "exefs" / "icon.jpg").write_bytes(b"EXTRACT_ICON")
        return root

    def make_loose(self, root, tid, name="LooseGame"):
        """通用解包目录：exefs/main + main.npdm + control.nacp，romfs/ 目录，没有 unpack.tsv"""
        (root / "exefs").mkdir(parents=True)
        (root / "exefs" / "main").write_bytes(b"\x03" * 600)
        (root / "exefs" / "main.npdm").write_bytes(synthetic_npdm(tid))
        (root / "exefs" / "control.nacp").write_bytes(synthetic_nacp(name, "3.0.0"))
        (root / "exefs" / "icon.jpg").write_bytes(b"LOOSE_ICON")
        (root / "romfs").mkdir(parents=True)
        (root / "romfs" / "data.bin").write_bytes(b"LOOSE_DATA" * 90)
        return root

    def test_dump_import_without_keys(self):
        # Switch 2 导出目录（有 base/exefs/main.npdm）：不要密钥能导入，format=dump，程序号从 main.npdm 读，
        # 有 ctl/control.nacp 用它，没有用目录名；封面取 ctl/icon.jpg
        tid = 0x0100123456789000
        dump = self.make_dump(self.root / "dump1", tid, "Zelda NS2")
        result, done = self.worker("import", paths=[str(dump)])
        self.assertEqual(done["state"], "succeeded", result.stderr + str(done.get("diagnostics")))
        [game] = self.c.catalog()["games"]
        [pkg] = game["packages"]
        self.assertEqual((game["id"], game["name"], pkg["type"], pkg["format"], pkg["version"]),
                         (f"{tid:016X}", "Zelda NS2", "base", "dump", 0))
        self.assertEqual(pkg["path"], str(dump.resolve()))
        self.assertTrue(pkg["size"] > 0)  # 目录内文件总字节
        self.assertEqual((self.c.library / "games" / "Zelda NS2" / "cover.jpg").read_bytes(), b"DUMP_ICON")   # 文件夹按英文名（NACP 美式英语）
        # 没有控制分区：标题取目录名
        dump2 = self.make_dump(self.root / "RawDump", 0x0100AABBCCDD0000)
        (self.c.library / "catalog.json").write_text('{"schema": 1, "games": []}')
        result, done = self.worker("import", paths=[str(dump2)])
        self.assertEqual(done["state"], "succeeded", result.stderr)
        self.assertEqual(self.c.catalog()["games"][0]["name"], "RawDump")

    def test_extract_import_without_keys(self):
        # S2Arm 解包目录（有 exefs/main 与 unpack.tsv）：不要密钥能导入，format=extract，元数据取 unpack.tsv（优先中文名）
        tid = 0x01002468ACE00000
        extract = self.make_extract(self.root / "extract1", tid, "Mario", "马力欧")
        result, done = self.worker("import", paths=[str(extract)])
        self.assertEqual(done["state"], "succeeded", result.stderr)
        [game] = self.c.catalog()["games"]
        [pkg] = game["packages"]
        self.assertEqual((game["id"], game["name"], pkg["type"], pkg["format"], pkg["display"]),
                         (f"{tid:016X}", "马力欧", "base", "extract", "2.1.0"))
        self.assertEqual(pkg["path"], str(extract.resolve()))
        # 界面名取中文、文件夹按英文名（unpack.tsv 的 name），英文名记进 catalog
        self.assertEqual(game["englishName"], "Mario")
        self.assertEqual((self.c.library / "games" / "Mario" / "cover.jpg").read_bytes(), b"EXTRACT_ICON")

    def test_loose_folder_reaches_ns2_dump(self):
        # 玩家 #9：已解包目录出包走 extract_folder 的 loose 分支，用到 tempfile（曾漏 import，NameError）。手算期望：起 ns2_dump.py 一次，第一个位置参数 = 临时目录（空、不建链接），
        #   本体目录经 --base 直接交进去（玩家诊断 #0fd185：链接可能建不了）
        import os
        import tempfile as tf
        from types import SimpleNamespace
        from unittest import mock
        import build
        with tf.TemporaryDirectory() as d:
            root = Path(d); src = root / "src"; src.mkdir(); (root / "priv").mkdir(); calls = []
            def run(args, log, env):
                stage = Path(args[4])
                calls.append((Path(args[3]).name, os.path.lexists(stage / "base"), args[args.index("--base") + 1] if "--base" in args else None))
            c = SimpleNamespace(private=root / "priv", engine=root, run=run)
            with mock.patch.object(build, "source_path", return_value=src), mock.patch.object(build, "reader_program", return_value="r"):
                build.extract_folder(c, dict(name="G"), [dict(format="loose")], root / "x", {}, root)
            self.assertEqual(calls, [("ns2_dump.py", False, str(src))])

    def test_loose_import_without_keys(self):
        # 通用解包目录（有 exefs/main、exefs/main.npdm 和 romfs/ 目录，没有 unpack.tsv）：不要密钥能导入，format=loose，
        # 程序号从 main.npdm 读，名称取 exefs/control.nacp 或目录名
        tid = 0x0100FFEEDDCCBB00
        loose = self.make_loose(self.root / "loose1", tid, "Splatoon")
        result, done = self.worker("import", paths=[str(loose)])
        self.assertEqual(done["state"], "succeeded", result.stderr)
        [game] = self.c.catalog()["games"]
        [pkg] = game["packages"]
        self.assertEqual((game["id"], game["name"], pkg["type"], pkg["format"]),
                         (f"{tid:016X}", "Splatoon", "base", "loose"))
        self.assertEqual((self.c.library / "games" / "Splatoon" / "cover.jpg").read_bytes(), b"LOOSE_ICON")

    def test_program_hash_mismatch_imports_with_warning(self):
        # #1522：导出目录 / 散文件导入时先试解程序文件（NSO）、核段哈希。解不开（LZ4）的分支要 lz4，在 tests/ns2_dump_test.sh（钉版解释器）测；夹具：第一段不压缩（标志 0x38 = 三段都核哈希，同真件的核验位），期望句手写
        import hashlib
        import struct

        def nso(text, good=True):
            b = bytearray(0x100); b[:4] = b"NSO0"; struct.pack_into("<I", b, 0x0C, 0x38)
            struct.pack_into("<III", b, 0x10, 0x100, 0, len(text)); struct.pack_into("<I", b, 0x60, len(text))
            for i, seg in enumerate((text, b"", b"")):
                b[0xA0 + i * 32:0xC0 + i * 32] = hashlib.sha256(seg if (good or i) else seg + b"x").digest()
            return bytes(b) + text
        tid = 0x0400A3A01EE4C000
        # 段哈希对不上但解得开（打过补丁 / mod 的程序）：照常入库，记一条黄色诊断（维护者 11-17：校验不过不拒收）
        off = self.make_dump(self.root / "off", tid); (off / "base" / "exefs" / "main").write_bytes(nso(b"CODE" * 64, good=False))
        _, done = self.worker("import", paths=[str(off)])
        self.assertEqual(done["state"], "succeeded")
        warn = [d for d in done.get("diagnostics", []) if d.get("code") == "source_integrity_skipped"]
        self.assertEqual(len(warn), 1, done.get("diagnostics")); self.assertEqual(warn[0]["severity"], "warning")
        self.assertEqual(len(self.c.catalog()["games"]), 1)

    def test_extract_dir_in_subfolder(self):
        # 解包目录嵌在子目录里：扫描时能找到，认到就不再往里走
        folder = self.root / "downloads"
        self.make_dump(folder / "sub1" / "game_dump", 0x0100111111110000, "Sub1Game")
        self.make_extract(folder / "sub2" / "game_extract", 0x0100222222220000, "Sub2Game", "子游戏2")
        result, done = self.worker("import", paths=[str(folder)])
        self.assertEqual(done["state"], "succeeded", result.stderr)
        games = sorted(self.c.catalog()["games"], key=lambda g: g["id"])
        self.assertEqual(len(games), 2)
        self.assertEqual((games[0]["name"], games[0]["packages"][0]["format"]), ("Sub1Game", "dump"))
        self.assertEqual((games[1]["name"], games[1]["packages"][0]["format"]), ("子游戏2", "extract"))

    def test_nsp_and_extract_dir_without_keys_rejected(self):
        # 同一文件夹里 NSP + 解包目录并存，没有密钥：整单 keys_missing（NSP 要密钥）
        self.install_reader_fixture()
        folder = self.root / "mixed"
        nsp = folder / "game.nsp"; nsp.parent.mkdir(); nsp.write_bytes(b"synthetic game fixture")
        self.make_dump(folder / "dumped", 0x0100AAAAAAA00000)
        result, done = self.worker("import", paths=[str(folder)])
        self.assert_failure(done, "keys_missing")

    def test_only_extract_dir_without_keys_succeeds(self):
        # 只有解包目录、没有 NSP：没有密钥照样成功，密钥状态不动（没用到密钥）
        self.install_reader_fixture()
        dump = self.make_dump(self.root / "only_dump", 0x0100BBBBBBBB0000)
        result, done = self.worker("import", paths=[str(dump)])
        self.assertEqual(done["state"], "succeeded", result.stderr)
        self.assertFalse((self.c.private / "keys/status.json").exists())


class DefaultPathUnchangedTests(JobCase):
    """#124 逐来源结果只给开了 partialResults 的调用方：默认路径（不开）结果形状、任务记录、错误码都同 #124 之前（期望按 #124 之前的行为手写）"""
    make_extract = ExtractImportTests.make_extract
    def test_default_result_has_only_imports_and_record_has_no_sources(self):
        import json
        extract = self.make_extract(self.root / "e1", 0x01002468ACE00000, "Mario", "马力欧")
        result, done = self.worker("import", paths=[str(extract)])
        self.assertEqual(done["state"], "succeeded", result.stderr)
        self.assertEqual(sorted(done["result"]), ["imports"])
        record = json.loads((self.c.private / "logs" / "jobs" / (done["taskId"] + ".json")).read_text())
        self.assertNotIn("sources", record)
        result, done = self.worker("import", paths=[str(self.root / "nope" / "x.nsp")])   # 失败：结果为空，同以前
        self.assertEqual((done["state"], done.get("result") or {}), ("failed", {}))

    def test_default_catalog_write_error_keeps_original_code(self):
        # catalog 写不进（非盘满）：默认路径照旧抛原始 OSError，explain 归 permission_denied（#124 曾统一成 job_failed）
        import library, errors
        from unittest.mock import patch
        extract = self.make_extract(self.root / "e2", 0x01002468ACE00000, "Mario", "马力欧")
        real = library.atomic
        def atomic(path, data, *a, **k):
            if Path(path).name == "catalog.json" and data.get("games"):
                raise PermissionError(13, "Permission denied", str(path))
            return real(path, data, *a, **k)
        self.c.r.update(paths=[str(extract)])
        self.c.r.pop("partialResults", None)
        with patch.object(library, "atomic", atomic), self.assertRaises(OSError) as e:
            library.import_games(self.c)
        # 作业里 explain 带本作业的玩家侧路径（Context.failure_roots，启动器剃刀 H8）：catalog.json 在游戏库下 → 仍归 permission_denied
        self.assertEqual(errors.explain(e.exception, **self.c.failure_roots()).code, "permission_denied")

    def test_catalog_lock_free_while_reading_sources_held_only_for_write(self):
        # 剃刀 H27：读原件（元数据、身份）期间目录锁空着，别的任务改名 / 换封面不报忙；只在记进 catalog、写 catalog.json 那一下持锁。
        #   读第一款时插一个「别的任务」往 catalog 里加一款 → 导入锁里重读，两款都在（旧代码整段持锁：读的时候目录锁拿不到）
        import filelock, json, library
        from unittest.mock import patch
        extract = self.make_extract(self.root / "e3", 0x01002468ACE00000, "Mario", "马力欧")
        real, seen = library.extract_inspect, []
        def reading(c, source, icons):
            with filelock.held(c.library / ".catalog.lock"):   # 拿得到 = 读的时候没人持目录锁（拿不到抛 Busy，导入失败）
                cat = json.loads((c.library / "catalog.json").read_text())
                cat["games"].append(dict(id="0100AAAAAAAA0000", name="别的任务刚加的", packages=[]))
                (c.library / "catalog.json").write_text(json.dumps(cat))
                seen.append("free")
            return real(c, source, icons)
        written = []
        real_atomic = library.atomic
        def atomic(path, data, *a, **k):
            if Path(path).name == "catalog.json":
                written.append(filelock.read_holder(self.c.library / ".catalog.lock").get("taskId"))   # 写 catalog 时本任务持着目录锁
            return real_atomic(path, data, *a, **k)
        self.c.r.update(paths=[str(extract)])
        self.c.r.pop("partialResults", None)
        with patch.object(library, "extract_inspect", reading), patch.object(library, "atomic", atomic):
            library.import_games(self.c)
        self.assertEqual((seen, written), (["free"], [self.c.task]))
        ids = sorted(g["id"] for g in json.loads((self.c.library / "catalog.json").read_text())["games"])
        self.assertEqual(ids, sorted(["0100AAAAAAAA0000", "01002468ACE00000"]))

    def test_record_sources_caps_each_and_total(self):
        import core
        big = "头" + "x" * 50_000 + "尾"
        rows = core.record_sources([dict(status="failed", code="content_invalid", reason="r", diagnostic=big) for _ in range(30)])
        self.assertTrue(all(len(r["diagnostic"]) <= core.IMPORT_RECORD_SOURCE_DIAGNOSTIC for r in rows))
        self.assertTrue(rows[0]["diagnostic"].startswith("头") and rows[0]["diagnostic"].endswith("尾"))
        self.assertLessEqual(sum(len(r["diagnostic"]) for r in rows), core.IMPORT_RECORD_DIAGNOSTICS_TOTAL)
        self.assertEqual(rows[-1]["diagnostic"], "")                       # 超出总量的来源只留 code / reason / status
        self.assertEqual((rows[-1]["code"], rows[-1]["status"]), ("content_invalid", "failed"))


if __name__ == "__main__":
    unittest.main()
