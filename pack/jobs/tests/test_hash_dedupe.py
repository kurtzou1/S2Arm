"""v0.2.3 去重哈希的行为单测（期望按规则手写）：
① 发版应用（请求带 engineBundle）的产物根键不再哈希引擎源码（engine.json 的 id 已在键里）；源码树开发照旧给源码摘要；
② snapshot 只记大小（第二项空串），validate_files 缺省按它核得过；
③ 取资源包时清单没有 index_sha256 → 按 index.tsv 现算资源包号，不拦（11-13）"""
import json
import unittest

from jobcase import JobCase
from core import Failure, atomic
import build
import install
import layout


class HashDedupe(JobCase):
    def test_release_skips_source_hash(self):
        self.c.r["engineBundle"] = "/Applications/S2Arm.app/Contents/Resources/engine"
        self.assertIsNone(build.source_fingerprint(self.c))
        del self.c.r["engineBundle"]
        fp = build.source_fingerprint(self.c)
        self.assertIsInstance(fp, str); self.assertEqual(len(fp), 64)

    def test_snapshot_records_sizes_only(self):
        root = self.root / "img"; (root / "romfs").mkdir(parents=True); (root / "romfs" / "a.bin").write_bytes(b"abc"); (root / "main").write_bytes(b"x")
        snap = build.snapshot(self.c, root)
        self.assertEqual(snap, {"main": [1, ""], "romfs/a.bin": [3, ""]})
        build.validate_files(self.c, root, snap)
        (root / "main").write_bytes(b"xy")
        with self.assertRaises(Failure):
            build.validate_files(self.c, root, snap)

    def test_pack_without_index_sha_falls_back_to_index_tsv(self):
        # 预检清单 #16（11-13）：清单没写 index_sha256 不再整单不装；资源包号按推送实际用的 index.tsv 现算（期望用 hashlib 独立算）
        import hashlib
        gid = "0100000000000001"
        kit = layout.ios_kit(self.c, gid); kit.mkdir(parents=True); (kit / "main.npdm").write_bytes(b"n")
        pack = layout.ios_pack(self.c, gid); pack.mkdir(parents=True); atomic(pack / "manifest.json", {"version": 2})
        self.assertEqual(install.ios_pack(self.c, gid), pack)
        self.assertEqual(install.pack_id(pack), "")   # 连 index.tsv 都没有：没有号（推送那一步会因缺 index.tsv 照实报）
        (pack / "index.tsv").write_bytes(b"a\t1\t-\n")
        self.assertEqual(install.pack_id(pack), hashlib.sha256(b"a\t1\t-\n").hexdigest())
        atomic(pack / "manifest.json", {"version": 2, "index_sha256": "ab"})
        self.assertEqual(install.pack_id(pack), "ab")

    def test_finder_junk_never_fails_validation(self):   # #382：清单不记 .DS_Store / ._；生成后访达写入 / 改动 / 删掉它都不判红；旧清单里记着的也不核
        root = self.root / "img2"; (root / "romfs").mkdir(parents=True); (root / "romfs" / "a.bin").write_bytes(b"abc")
        (root / "romfs" / ".DS_Store").write_bytes(b"x" * 10); (root / "romfs" / "._a.bin").write_bytes(b"y")
        snap = build.snapshot(self.c, root)
        self.assertEqual(snap, {"romfs/a.bin": [3, ""]})
        (root / "romfs" / ".DS_Store").write_bytes(b"changed size")
        build.validate_files(self.c, root, snap)
        old = dict(snap, **{"romfs/.DS_Store": [10, ""]})   # 旧清单记过、现在被访达删掉
        (root / "romfs" / ".DS_Store").unlink()
        build.validate_files(self.c, root, old)


if __name__ == "__main__":
    unittest.main()
