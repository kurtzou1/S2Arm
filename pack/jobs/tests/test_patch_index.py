"""补丁索引生成（tools/patch_index.py，11-13：压缩包里的补丁与金手指、按内容去重）。临时镜像目录，期望按规则手写"""
import hashlib, io, json, os, shutil, sys, tempfile, unittest, zipfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tools"))
import patch_index
os.environ["S2A_PATCH_INDEX_NO_GH"] = "1"   # 单测不联网


class PatchIndexTests(unittest.TestCase):
    def setUp(self):
        self.m = Path(tempfile.mkdtemp())
        ws = b"@nsobid-FF1D1C05670DB6021C85B624A710B963\n@enabled\n"
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("[21x9 Ultrawide]/exefs/1.0.pchtxt", ws)
            z.writestr("[60FPS]/cheats/FF1D1C05670DB602.txt", b"[x]\n04000000 00000010 00000001\n")
            z.writestr("[21x9 Ultrawide]/romfs/ui.bfres", b"data")          # 游戏数据：不收
            z.writestr("readme.md", b"hi")
        for repo in ("orig__mods", "ADEMOLA200__mods"):                   # 合集库里是同一个包
            d = self.m / repo / "Game [01006F8002326000]"; d.mkdir(parents=True)
            (d / "mods.zip").write_bytes(buf.getvalue())
        (self.m / "SOURCES.tsv").write_text("来源\tURL\t提交号\n" + "".join(f"{r}\tu\t{'c' * 40}\n" for r in ("orig__mods", "ADEMOLA200__mods")))
        self.ws = ws

    def tearDown(self):
        shutil.rmtree(self.m, ignore_errors=True)

    def test_classify_ignores_urls_and_knows_unlock(self):
        # 期望手写（11-13 实例）：署名网址里的「60fps」不算帧率；「Unlock / Uncap FPS」不带数字也是帧率（目标空）；带数字的照旧取数字
        foot = "\n@StevensND\nhttps://github.com/StevensND/ue4-emuswitch-60fps\n"
        self.assertEqual(patch_index.classify("G/[0100D7C01F254000]/Disable AA (Anti-Aliasing)/1.0.1.pchtxt", "// Disable AA\n@enabled\n" + foot), ("gfx", "", ""))
        self.assertEqual(patch_index.classify("G/FPS/Uncap FPS/exefs/1.0.1.pchtxt", foot), ("fps", "", ""))
        self.assertEqual(patch_index.classify("010093801237C000/2.1.0 by x/Unlock FPS/exefs/2.1.0.pchtxt"), ("fps", "", ""))
        self.assertEqual(patch_index.classify("G/FPS/60FPS/1.0.1.pchtxt", foot), ("fps", "60", ""))
        self.assertEqual(patch_index.classify("Mods/Graphics - Disable Dynamic resolution when low FPS/exefs/1.0.0.pchtxt"), ("gfx", "", ""))

    def test_archive_members_and_dedupe(self):
        rows = patch_index.dedupe(patch_index.scan(str(self.m)))
        got = sorted((r["repo"], r["member"], r["kind"], r["cat"], r["aspect"], tuple(r["gids"]), tuple(r["bids"])) for r in rows)
        self.assertEqual(got, [
            ("orig/mods", "[21x9 Ultrawide]/exefs/1.0.pchtxt", "pchtxt", "widescreen", "21:9", ("01006F8002326000",), ("FF1D1C05670DB6021C85B624A710B963",)),
            ("orig/mods", "[60FPS]/cheats/FF1D1C05670DB602.txt", "cheat", "cheat", "", ("01006F8002326000",), ("FF1D1C05670DB602",)),
        ])                                                                # 合集库那份去掉、原作者库留下；romfs / readme 不收
        r = next(r for r in rows if r["kind"] == "pchtxt")
        self.assertEqual((r["path"], r["sha256"], r["archive_sha256"]),
                         ("Game [01006F8002326000]/mods.zip", hashlib.sha256(self.ws).hexdigest(), hashlib.sha256((self.m / "orig__mods/Game [01006F8002326000]/mods.zip").read_bytes()).hexdigest()))

    def test_cheat_libraries_are_not_indexed_twice(self):
        os.rename(self.m / "orig__mods", self.m / "ChanseyIsTheBest__NX-60FPS-RES-GFX-Cheats")
        (self.m / "SOURCES.tsv").write_text("来源\tURL\t提交号\n" + "".join(f"{r}\tu\t{'c' * 40}\n" for r in ("ChanseyIsTheBest__NX-60FPS-RES-GFX-Cheats", "ADEMOLA200__mods")))
        kinds = {(r["repo"], r["kind"]) for r in patch_index.scan(str(self.m))}
        self.assertNotIn(("ChanseyIsTheBest/NX-60FPS-RES-GFX-Cheats", "cheat"), kinds)   # 金手指专门通道已取的库：不重复收金手指
        self.assertIn(("ADEMOLA200/mods", "cheat"), kinds)


class CaseTests(unittest.TestCase):
    def test_fix_case_by_git_blob(self):
        data = b"zip"; sha = hashlib.sha1(b"blob 3\0zip").hexdigest()
        tree = {sha: ["Some Game/a.zip"], "0" * 40: ["SOME GAME/a.zip"]}
        self.assertEqual(patch_index.fix_case("SOME GAME/a.zip", data, tree), "Some Game/a.zip")   # 同内容那条
        self.assertEqual(patch_index.fix_case("x/b.zip", data, tree), "x/b.zip")                                     # 对不上照本地
        self.assertEqual(patch_index.fix_case("x/b.zip", data, None), "x/b.zip")


class PatchPackTests(unittest.TestCase):
    """统一包（tools/patch_pack.py）：按程序号 / 构建号分包、条目字节同上游、汇总库 JSON 拆成按构建号的金手指、同输入同输出"""
    def setUp(self):
        self.m = Path(tempfile.mkdtemp()); self.o = Path(tempfile.mkdtemp())
        a = self.m / "orig__mods"; (a / "G [01006F8002326000]/exefs").mkdir(parents=True); (a / "loose/cheats").mkdir(parents=True)
        self.ws = b"@nsobid-FF1D1C05670DB6021C85B624A710B963\n// 21:9 ultrawide\n@enabled\n"
        (a / "G [01006F8002326000]/exefs/1.0.pchtxt").write_bytes(self.ws)
        (a / "loose/cheats/AAAABBBBCCCCDDDD.txt").write_bytes(b"[x]\n04000000 00000010 00000001\n")   # 没写程序号：按构建号分包
        h = self.m / "HamletDuFromage__switch-cheats-db/cheats"; h.mkdir(parents=True)
        (h / "01006F8002326000.json").write_text(json.dumps({"FF1D1C05670DB602": {"[A]": "[A]\n04000000 0 1\n", "[B]": "[B]\n04000000 4 1\n"}, "attribution": {"x": "someone"}}))
        (self.m / "SOURCES.tsv").write_text("来源\tURL\t提交号\n" + "".join(f"{r}\tu\t{'c' * 40}\n" for r in ("orig__mods", "HamletDuFromage__switch-cheats-db")))
        import patch_pack; self.pp = patch_pack

    def tearDown(self):
        shutil.rmtree(self.m, ignore_errors=True); shutil.rmtree(self.o, ignore_errors=True)

    def test_bundles(self):
        import base64, gzip, json as js
        idx = self.pp.build(str(self.m), str(self.o))
        self.assertEqual(sorted(idx["bundles"]), ["b/AAAABBBBCCCCDDDD", "g/01006F8002326000"])
        g = js.loads(gzip.decompress((self.o / "g/01006F8002326000.json.gz").read_bytes()))["items"]
        self.assertEqual(sorted((i["kind"], i["cat"], tuple(i["bids"])) for i in g),
                         [("cheat", "cheat", ("FF1D1C05670DB602",)), ("pchtxt", "widescreen", ("FF1D1C05670DB6021C85B624A710B963",))])
        ws = next(i for i in g if i["kind"] == "pchtxt")
        self.assertEqual(base64.b64decode(ws["data"]), self.ws)                                   # 字节同上游、不转格式
        ch = next(i for i in g if i["kind"] == "cheat")
        self.assertEqual((base64.b64decode(ch["data"]), ch["author"], ch["source"]["member"]), (b"[A]\n04000000 0 1\n[B]\n04000000 4 1\n", "someone", "FF1D1C05670DB602"))
        # 管线种子目录（<目录>/<程序号>/*.tsv）：进这款 g/ 包、kind = cat = pso、字节原样；不算上游；不是程序号的目录 / 非 .tsv 不收
        sd = self.m / "seeds"; (sd / "01006F8002326000").mkdir(parents=True); (sd / "notagame").mkdir()
        seed = b"R\t" + b"00" * 432 + b"\n"
        (sd / "01006F8002326000/run1.tsv").write_bytes(seed); (sd / "01006F8002326000/x.txt").write_bytes(b"x"); (sd / "notagame/a.tsv").write_bytes(b"S\tx\t0\n")
        so = Path(tempfile.mkdtemp())
        try:
            sidx = self.pp.build(str(self.m), str(so), str(sd))
            self.assertEqual(sorted(sidx["bundles"]), ["b/AAAABBBBCCCCDDDD", "g/01006F8002326000"])
            self.assertEqual(sidx["upstreams"], idx["upstreams"])
            sg = js.loads(gzip.decompress((so / "g/01006F8002326000.json.gz").read_bytes()))["items"]
            ps = [i for i in sg if i["kind"] == "pso"]
            self.assertEqual([(i["cat"], i["gids"], i["name"], base64.b64decode(i["data"])) for i in ps], [("pso", ["01006F8002326000"], "run1.tsv", seed)])
        finally:
            shutil.rmtree(so, ignore_errors=True)
        first = {k: (self.o / (k + ".json.gz")).read_bytes() for k in idx["bundles"]}
        self.pp.build(str(self.m), str(self.o))
        self.assertEqual(first, {k: (self.o / (k + ".json.gz")).read_bytes() for k in idx["bundles"]})   # 同输入同输出：只传变了的
        # 快照：同输入同字节；自洽核得过；放进启动器资源（S2A_PATCH_SNAPSHOT 指本机文件）；改坏一个字节就不放
        s1 = open(self.pp.snapshot(str(self.o)), "rb").read(); s2 = open(self.pp.snapshot(str(self.o)), "rb").read()
        self.assertEqual(s1, s2)
        res = Path(tempfile.mkdtemp())
        os.environ["S2A_PATCH_SNAPSHOT"] = str(self.o / "snapshot.tar")
        try:
            self.assertIsNone(self.pp.stage_snapshot(str(res / "CommunityPatches")))
            self.assertEqual((res / "CommunityPatches/patches-v2.tar").read_bytes(), s1)
            bad = bytearray(s1); i = bad.index(b"\x1f\x8b"); bad[i + 40] ^= 0xFF; (self.o / "bad.tar").write_bytes(bytes(bad))
            os.environ["S2A_PATCH_SNAPSHOT"] = str(self.o / "bad.tar")
            self.assertIsNotNone(self.pp.stage_snapshot(str(res / "x")))
            self.assertFalse((res / "x/patches-v2.tar").exists())
        finally:
            os.environ.pop("S2A_PATCH_SNAPSHOT", None); shutil.rmtree(res, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
