"""金手指（pack/jobs/cheats.py，11-12）：出包时查公开库、玩家导入、启动器列出与开关。不联网：库函数换成桩。期望按规则手写"""
import json, shutil, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cheats
import community
from core import Failure

GID = "01001B300B9BE000"
BID = "2607A74F5DF7754C"
REPO = Path(__file__).resolve().parents[3]
TEXT = "{Master}\n040E0000 00BE1238 D503201F\n\n[Infinite Health]\n080E0000 00C72FB0 17E8B62C B9000D17\n\n[Gold x2]\n040E0000 00C72FB8 00000002\n"


class Ctx:
    def __init__(self, root):
        self.library, self.engine, self.private, self.r = root / "lib", root / "engine", root / "priv", {"gameId": GID}
        table = self.engine / community.SETTINGS_TABLE
        table.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(REPO / community.SETTINGS_TABLE, table)
    def begin(self, *a): pass


class CheatsTests(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.c = Ctx(self.t)
        p = self.c.library / "catalog.json"; p.parent.mkdir(parents=True)
        p.write_text(json.dumps({"games": [{"id": GID, "packages": [{"type": "base", "version": 0, "display": "1.0.0", "builds": {"main": BID.lower() + "c0357b5df7e49693"}}]}]}))
        self.game = community.game_of(self.c, GID)
        self.d = cheats.cheats_dir(self.c, GID)
        self.real = cheats.main_build
        cheats.main_build = lambda c, g: self.bid   # 真构建号取自解包目录（单测不解包）：按用例给
        self.bid = BID

    def tearDown(self):
        cheats.main_build = self.real
        shutil.rmtree(self.t, ignore_errors=True)

    def test_fetch_writes_header_and_source_skips_failures(self):
        calls = []
        def ok(gid, bids): calls.append((gid, bids)); return [(BID, dict(text=TEXT, path=f"x/{BID}.txt", author="bad1dea", license="MIT"))]
        def boom(gid, bids): raise OSError("离线")
        def none(gid, bids): return []
        got = cheats.fetch(self.c, self.game, (("a/one", "one", ok), ("b/two", "two", boom), ("c/three", "three", none)))
        self.assertEqual((got, calls), (["a/one"], [(GID, {BID})]))                    # 按程序号 + 真构建号前 16 位取；离线 / 没有静默跳过
        text = (self.d / f"{BID}.one.txt").read_text()
        self.assertTrue(text.startswith(f"[a/one BID={BID}]\n"))                       # 文件头补上 BID（出包与运行时都按它核版本）
        src = json.loads((self.d / "sources.json").read_text())[f"{BID}.one.txt"]
        self.assertEqual((src["from"], src["repo"], src["author"], src["license"]), ("library", "a/one", "bad1dea", "MIT"))

    def test_fetch_other_build_not_written(self):
        other = "[x BID=0000000000000000]\n[A]\n04000000 00000010 00000001\n"
        cheats.fetch(self.c, self.game, (("a/one", "one", lambda g, b: [(BID, dict(text=other, path="p", author="", license=""))]),))
        self.assertFalse((self.d / f"{BID}.one.txt").exists())                         # 文件头构建号与库里的文件名不符：不收

    def test_unknown_build_fetches_all_versions_list_hides_others(self):
        self.bid = ""                                                                  # 还没解过包：各版本都取
        seen = []
        def lib(gid, bids):
            seen.append(bids)
            return [(BID, dict(text=TEXT, path="a", author="", license="")), ("0000000000000000", dict(text=TEXT, path="b", author="", license=""))]
        cheats.fetch(self.c, self.game, (("a/one", "one", lib),))
        self.assertEqual((seen, sorted(p.name for p in self.d.glob("*.one.txt"))), ([set()], ["0000000000000000.one.txt", f"{BID}.one.txt"]))
        self.bid = BID                                                                 # 解过包后：库里别的版本不列
        self.assertEqual({it["file"] for it in cheats.listing(self.c, self.game)["items"]}, {f"{BID}.one.txt"})

    def test_listing_save_and_version_reason(self):
        self.d.mkdir(parents=True, exist_ok=True)
        (self.d / f"{BID}.txt").write_text(TEXT)
        (self.d / "old.txt").write_text("[D BID=1111111111111111]\n[A]\n04000000 00000010 00000001\n")
        r = cheats.listing(self.c, self.game)
        keys = [(it["key"], it["ok"], it["from"]) for it in r["items"]]
        self.assertEqual(keys, [(f"{BID}.txt/Infinite Health", True, "player"), (f"{BID}.txt/Gold x2", True, "player"), ("old.txt/A", False, "player")])   # 主代码不列
        self.assertEqual(r["items"][2]["reason"], f"版本不对：金手指是 1111111111111111，这份游戏是 {BID}。")
        cheats.save(self.c, self.game, {f"{BID}.txt/Infinite Health": True})
        self.assertEqual((self.d / "enabled.txt").read_text(), f"{BID}.txt/Infinite Health\n")
        cheats.save(self.c, self.game, {f"{BID}.txt/Gold x2": True, f"{BID}.txt/Infinite Health": False})
        self.assertEqual((self.d / "enabled.txt").read_text(), f"{BID}.txt/Gold x2\n")
        with self.assertRaises(Failure):
            cheats.save(self.c, self.game, {"nope.txt/X": True})

    def test_fixed_address_by_opcode(self):
        # 期望按 Atmosphere 指令表手判：0 / 1 型第 3 位区号非 0、5 型区号非 0 且第 5 位（以寄存器为基址）为 0 → 写死地址
        text = ("[Coins]\n02100000 5C27B318 0000270f\n\n[Health]\n11160000 5C3BE7DC 00000000\n01100000 5C3BE7DC 00000006\n20000000\n\n"
                "[Moonjump]\n80000002\n580F0000 0149D940\n580F1000 00000090\n780F0000 00000038\n640F0000 00000000 42000000\n20000000\n\n"
                "[Wide]\n041F0000 73759AC8 401851EC\n\n[Code]\n040E0000 00C72FB8 00000002\n\n[HeapPtr]\n58100000 00001000\n")
        self.assertEqual([(n, fx) for n, _, _, fx in cheats.parse(text)[1]],
                         [("Coins", True), ("Health", True), ("Moonjump", False), ("Wide", True), ("Code", False), ("HeapPtr", True)])
        self.d.mkdir(parents=True, exist_ok=True)
        (self.d / f"{BID}.txt").write_text(text)
        self.assertEqual({it["name"]: it["fixed"] for it in cheats.listing(self.c, self.game)["items"]},
                         {"Coins": True, "Health": True, "Moonjump": False, "Wide": True, "Code": False, "HeapPtr": True})

    def test_no_cheats_reason(self):
        self.assertEqual(cheats.listing(self.c, self.game), dict(items=[], reason="这个版本没有现成的金手指。"))

    def test_import_via_community_save(self):
        src = self.t / "mine.txt"; src.write_text(TEXT)
        bad = self.t / "bad.txt"; bad.write_text("hello\n")
        self.c.r = {"gameId": GID, "cheatsImport": [str(src)], "cheats": {"mine.txt/Gold x2": True}}
        r = community.save(self.c)
        self.assertEqual([(it["key"], it["enabled"]) for it in r["cheats"]["items"]], [("mine.txt/Infinite Health", False), ("mine.txt/Gold x2", True)])
        self.assertEqual(json.loads((self.d / "sources.json").read_text())["mine.txt"]["from"], "player")
        self.c.r = {"gameId": GID, "cheatsImport": [str(bad)]}
        with self.assertRaises(Failure):
            community.save(self.c)

    def test_crash_turns_them_off_then_notice_is_acknowledged(self):
        # 11-13 维护者改定：异常退出时开着的几条当场关掉、记下来；下次开始时启动器只通知（不问），看过（ack）清记录、开关不再动
        self.d.mkdir(parents=True, exist_ok=True)
        (self.d / f"{BID}.txt").write_text(TEXT)
        cheats.save(self.c, self.game, {f"{BID}.txt/Infinite Health": True, f"{BID}.txt/Gold x2": True})
        cheats.note_crash(self.c, self.game)
        self.c.r = {"gameId": GID}
        r = community.listing(self.c)
        self.assertEqual([(x["kind"], x["name"]) for x in r["crashed"]], [("cheat", "Gold x2"), ("cheat", "Infinite Health")])
        self.assertEqual(sum(it["enabled"] for it in r["cheats"]["items"]), 0)                                              # 已当场关掉
        cheats.save(self.c, self.game, {f"{BID}.txt/Gold x2": True})                                                         # 玩家看到通知后自己又打开一条
        self.c.r = {"gameId": GID, "crashAnswer": "ack"}
        r = community.save(self.c)
        self.assertEqual((r["crashed"], sum(it["enabled"] for it in r["cheats"]["items"])), ([], 1))                       # 看过：记录清掉、玩家重开的不动
        self.c.r = {"gameId": GID, "crashAnswer": "keep"}
        with self.assertRaises(Failure):
            community.save(self.c)

    def test_crash_with_nothing_on_records_nothing(self):
        cheats.note_crash(self.c, self.game)
        self.assertEqual(cheats.crashed(self.c, self.game), [])


if __name__ == "__main__":
    unittest.main()
