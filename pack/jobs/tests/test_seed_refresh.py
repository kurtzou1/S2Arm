"""推送 / 导出前补预热表（pack/jobs/seed_refresh.py，11-25 #1842）。期望值都按输入手算：
① update_pack_file：资源包 index.tsv 两行（game.img 100 字节、预热表 4 字节），换成 9 字节新表 → 那一行变「9<TAB>sha256(新)」，game.img 行原样；
   manifest.json files 2、total 109、index_sha256 = sha256(新 index 文本)；文件内容 = 新表。同内容再写 → 回 False、不动；清单没这一行 → 回 False、不建文件
② refresh：假产物根（ios_work/roots/<款>@现行 → 版本目录）+ 替身生成函数 → 资源包与产物根都写进新表、回 True；生成结果与包里相同 → 回 False；
   没有产物根 → 回 False（照推）；查云端补丁包抛错 → 照样按本机种子生成、回 True"""
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import seed_refresh  # noqa: E402
import layout  # noqa: E402
import patches  # noqa: E402

G = "01007EF00011E000"
REL = "shaders/direct/pso_manifest.tsv"


def make_pack(d, old=b"#h\n"):
    p = Path(d) / "pack"; (p / "shaders/direct").mkdir(parents=True)
    (p / REL).write_bytes(old)
    ix = f"game.img\t100\t{'a' * 64}\n{REL}\t{len(old)}\t{hashlib.sha256(old).hexdigest()}\n"
    (p / "index.tsv").write_text(ix, encoding="utf-8")
    (p / "manifest.json").write_text(json.dumps({"version": 3, "format": "img", "files": 2, "total": 100 + len(old),
                                                 "index_sha256": hashlib.sha256(ix.encode()).hexdigest()}), encoding="utf-8")
    return p


class Pack(unittest.TestCase):
    def test_update(self):
        with tempfile.TemporaryDirectory() as d:
            p = make_pack(d, b"#h\n\n")
            new = b"S\tabcdef\n"   # 9 字节
            self.assertEqual(len(new), 9)
            self.assertTrue(seed_refresh.update_pack_file(p, REL, new))
            ix = f"game.img\t100\t{'a' * 64}\n{REL}\t9\t{hashlib.sha256(new).hexdigest()}\n"
            self.assertEqual((p / "index.tsv").read_text(encoding="utf-8"), ix)
            mf = json.loads((p / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual((mf["files"], mf["total"], mf["index_sha256"], mf["version"]), (2, 109, hashlib.sha256(ix.encode()).hexdigest(), 3))
            self.assertEqual((p / REL).read_bytes(), new)
            self.assertFalse(seed_refresh.update_pack_file(p, REL, new))   # 同内容不动
            self.assertFalse(seed_refresh.update_pack_file(p, "shaders/direct/other.tsv", b"x"))   # 清单没这一行
            self.assertFalse((p / "shaders/direct/other.tsv").exists())


class Refresh(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory(); d = Path(self.td.name)
        self.work = d / "work"; ver = self.work / "roots" / "t01007ef00011e000@v1"
        (ver / "shaders/direct").mkdir(parents=True); (ver / REL).write_bytes(b"#h\n"); self.ver = ver
        (self.work / "roots" / ("t01007ef00011e000" + layout.CURRENT)).write_text("t01007ef00011e000@v1\n", encoding="utf-8")
        self.pack = make_pack(d)
        class C: engine = str(d); private = str(d)
        self.c = C()

    def tearDown(self):
        self.td.cleanup()

    def run_refresh(self, gen, fetch=None):
        with patch.object(layout, "ios_work", lambda c, g, create=True: self.work), \
             patch.object(layout, "current_root", lambda c, ptr: self.ver), \
             patch.object(patches, "fetch", fetch or (lambda *a, **k: [])), \
             patch.object(patches, "seed_sources", lambda c, g: None), \
             patch.object(seed_refresh, "generate", lambda *a, **k: gen):
            return seed_refresh.refresh(self.c, G, self.pack)

    def test_writes_new_table(self):
        new = b"#h\nS\tk1\tk2\n"
        self.assertTrue(self.run_refresh(new))
        self.assertEqual((self.pack / REL).read_bytes(), new)
        self.assertEqual((self.ver / REL).read_bytes(), new)

    def test_same_table_noop(self):
        self.assertFalse(self.run_refresh(b"#h\n"))

    def test_no_root(self):
        with patch.object(layout, "ios_work", lambda c, g, create=True: Path(self.td.name) / "nope"):
            self.assertFalse(seed_refresh.refresh(self.c, G, self.pack))

    def test_fetch_error_still_generates(self):
        def boom(*a, **k): raise OSError("offline")
        self.assertTrue(self.run_refresh(b"#h\nS\tk\tk\n", fetch=boom))


if __name__ == "__main__":
    unittest.main()
