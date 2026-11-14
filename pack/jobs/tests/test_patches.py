"""社区补丁与金手指查库（pack/jobs/patches.py，11-13 起读我们下载站的统一包）：按程序号 / 主程序构建号要包、核包与条目 sha256、
生成 pack/cpatch.py 认的 INDEX.tsv，金手指交 cheats。不联网：下载站换成本地目录（S2A_PATCH_BASE）。期望按规则手写"""
import base64, gzip, hashlib, json, os, shutil, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import patches

GID = "01006F8002326000"
MAIN = "FF1D1C05670DB6021C85B624A710B963" + "0" * 32
SDK = "A226048605D3597F90CB1067D141CD36647B90CD"


class Ctx:
    def __init__(self, root): self.private = root / "priv"


def nso(path, bid_hex):
    path.parent.mkdir(parents=True, exist_ok=True)
    b = bytearray(0x100); b[0:4] = b"NSO0"; b[0x40:0x60] = bytes.fromhex(bid_hex); path.write_bytes(bytes(b))


def it(data, kind, cat, name, gids, bids, repo="o/r", path="x", member="", **kw):
    return dict(id=hashlib.sha256(data).hexdigest()[:16], kind=kind, cat=cat, name=name, gids=gids, bids=bids, target_fps=kw.get("fps", ""), aspect=kw.get("aspect", ""),
                source=dict(repo=repo, commit="a" * 40, path=path, member=member), license=kw.get("lic", ""), author=kw.get("author", ""),
                sha256=kw.get("sha", hashlib.sha256(data).hexdigest()), data=base64.b64encode(data).decode())


class PatchesTests(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.c = Ctx(self.t)
        self.exefs = self.t / "exefs"; nso(self.exefs / "main", MAIN); nso(self.exefs / "sdk", SDK + "0" * 24); (self.exefs / "main.npdm").write_bytes(b"x")
        self.fps, self.ws, self.ch = b"@nsobid-FF1D1C05670DB6021C85B624A710B963\n@enabled\n", b"ws", b"[Inf HP]\n04000000 00000010 00000001\n"
        self.base = self.t / "site"
        self.bundles = {
            f"g/{GID}": [it(self.ws, "pchtxt", "widescreen", "1.0.pchtxt", [GID], [], path=f"G [{GID}].zip", member="[21x9]/exefs/1.0.pchtxt", aspect="21:9"),   # 按程序号
                         it(self.ch, "cheat", "cheat", "FF1D1C05670DB602.txt", [GID], ["FF1D1C05670DB602"], repo="bad1dea/NXCheats", author="a", lic="MIT"),
                         it(b"other", "pchtxt", "gfx", "bad.pchtxt", [GID], [], sha="0" * 64)],                                                      # 内容与条目不符：不收
            "b/FF1D1C05670DB602": [it(self.fps, "pchtxt", "fps", "fps.pchtxt", [], ["FF1D1C05670DB6021C85B624A710B963"], path="a/fps.pchtxt", fps="60", lic="MIT")],   # 按主程序构建号
            f"b/{SDK[:16]}": [it(b"sdk60", "pchtxt", "fps", "sdk60.pchtxt", [], [SDK])],   # sdk 构建号各游戏相同：不按它要包
        }
        self.publish()
        os.environ["S2A_PATCH_BASE"] = str(self.base)

    def publish(self, bad=None):
        man = {}
        for k, items in self.bundles.items():
            blob = gzip.compress(json.dumps(dict(schema=2, key=k, items=items)).encode())
            (self.base / k).parent.mkdir(parents=True, exist_ok=True); (self.base / (k + ".json.gz")).write_bytes(blob)
            man[k] = dict(sha256="f" * 64 if k == bad else hashlib.sha256(blob).hexdigest(), size=len(blob), items=len(items))
        (self.base / "index.json").write_text(json.dumps(dict(schema=2, generated=1, upstreams={}, bundles=man)))

    def tearDown(self):
        os.environ.pop("S2A_PATCH_BASE", None); shutil.rmtree(self.t, ignore_errors=True)

    def test_ios_package_leaves_out_graphics_patches(self):
        # 期望手写：同一份统一包，Mac 收 fps / widescreen / gfx 三类，iPhone（target="ios"）不收 gfx（11-13 维护者「画面补丁 iOS 不进包」）
        self.bundles[f"g/{GID}"].append(it(b"lod", "pchtxt", "gfx", "lod.pchtxt", [GID], []))
        self.publish()
        self.assertEqual([Path(d).name for d in patches.fetch(self.c, dict(id=GID), str(self.exefs))], ["fps", "gfx", "widescreen"])
        self.assertEqual([Path(d).name for d in patches.fetch(self.c, dict(id=GID), str(self.exefs), "ios")], ["fps", "widescreen"])

    def test_fetch_by_gid_and_main_build_and_index(self):
        dirs = patches.fetch(self.c, dict(id=GID), str(self.exefs))
        self.assertEqual([Path(d).name for d in dirs], ["fps", "widescreen"])                     # 金手指不进画面补丁；内容不符的不收（gfx 没东西）；sdk 包不要
        fps = (Path(dirs[0]) / "INDEX.tsv").read_text().splitlines()
        self.assertEqual(fps[0].split("\t")[-2:], ["target_fps", "origin"])                         # cpatch.scan 按表头认帧率类；origin = 上游原路径
        row = dict(zip(fps[0].split("\t"), fps[1].split("\t")))
        self.assertEqual((row["title_id"], row["type"], row["license"], row["target_fps"], row["origin"]), (GID, "pchtxt", "MIT", "60", "o/r/a/fps.pchtxt"))
        self.assertEqual((Path(dirs[0]) / row["path"]).read_bytes(), self.fps)                      # 文件在索引目录之内、字节同上游
        ws = (Path(dirs[1]) / "INDEX.tsv").read_text().splitlines()
        row = dict(zip(ws[0].split("\t"), ws[1].split("\t")))
        self.assertEqual((Path(row["path"]).name, row["aspect"], row["origin"]), ("1.0.pchtxt", "21:9", f"o/r/G [{GID}].zip/[21x9]/exefs/1.0.pchtxt"))

    def test_pso_seeds_go_to_seed_stage_not_rewriter(self):
        # 期望手写：统一包里 kind = pso 的条目不进 S2A_CPATCH_DIRS（目录仍只有 fps / widescreen），字节原样落到 games/<程序号>/pso/<编号>.tsv，
        #   prepare 交 S2A_PSO_SOURCES_EXTRA；云端撤掉种子后再出包 → 旧文件清掉、不再交
        seed = b"R\t" + b"00" * 432 + b"\n"
        self.bundles[f"g/{GID}"].append(it(seed, "pso", "pso", "a.tsv", [GID], [], repo="S2Arm/pso-seeds"))
        self.publish()
        import cheats
        real = cheats.main_build; cheats.main_build = lambda c, g: "FF1D1C05670DB602"; self.addCleanup(setattr, cheats, "main_build", real)
        self.c.library = self.t / "lib"; self.c.engine = self.t / "engine"
        env = {}
        patches.prepare(self.c, dict(id=GID), self.t, env)
        self.assertEqual([Path(d).name for d in env["S2A_CPATCH_DIRS"].split(os.pathsep)], ["fps", "widescreen"])
        d = Path(env["S2A_PSO_SOURCES_EXTRA"])
        self.assertEqual([(f.name, f.read_bytes()) for f in d.iterdir()], [(hashlib.sha256(seed).hexdigest()[:16] + ".tsv", seed)])
        # 出包页取消「S 级优化（Beta）」（请求 sgrade = false）：不带社区补丁与金手指、改写阶段整体不编（S2A_CPATCH=none），管线种子照带
        self.c.r = {"sgrade": False}
        env = {"S2A_CPATCH_DIRS": "x", "S2A_CHEATS_DIRS": "y"}
        patches.prepare(self.c, dict(id=GID), self.t, env)
        self.assertEqual(env, {"S2A_CPATCH": "none", "S2A_PSO_SOURCES_EXTRA": str(d)})
        self.c.r = {}
        self.bundles[f"g/{GID}"].pop(); self.publish()
        env = {}
        patches.prepare(self.c, dict(id=GID), self.t, env)
        self.assertNotIn("S2A_PSO_SOURCES_EXTRA", env)
        self.assertFalse(d.exists())

    def test_cheat_rows(self):
        self.assertEqual(patches.cheat_rows(self.c, GID, {"FF1D1C05670DB602"}),
                         [("FF1D1C05670DB602", self.ch.decode(), "bad1dea/NXCheats", "a", "MIT", "x")])
        self.assertEqual(patches.cheat_rows(self.c, GID, {"0000000000000000"}), [])                 # 别的版本不取

    def test_bundle_hash_mismatch_is_rejected(self):
        self.publish(bad=f"g/{GID}")
        dirs = patches.fetch(self.c, dict(id=GID), str(self.exefs))
        self.assertEqual([Path(d).name for d in dirs], ["fps"])                                      # 程序号那个包对不上清单：整包不收

    def test_offline_uses_cache_then_skips(self):
        self.assertTrue(patches.fetch(self.c, dict(id=GID), str(self.exefs)))
        shutil.rmtree(self.base)
        self.assertEqual(len(patches.fetch(self.c, dict(id=GID), str(self.exefs))), 2)              # 下载站不可达：清单与包都用缓存
        shutil.rmtree(self.c.private)
        self.assertEqual(patches.fetch(self.c, dict(id=GID), str(self.exefs)), [])                   # 没缓存：跳过，不挡出包

    def snapshot(self, bundles):
        """随启动器安装的快照（tools/patch_pack.py snapshot 同格式）：index.json + 各包"""
        import io, tarfile
        p = self.t / "res" / "CommunityPatches" / "patches-v2.tar"; p.parent.mkdir(parents=True, exist_ok=True)
        man, blobs = {}, {}
        for k, items in bundles.items():
            blob = gzip.compress(json.dumps(dict(schema=2, key=k, items=items)).encode()); blobs[k] = blob
            man[k] = dict(sha256=hashlib.sha256(blob).hexdigest(), size=len(blob), items=len(items))
        with tarfile.open(p, "w") as t:
            for n, data in [("index.json", json.dumps(dict(schema=2, generated=1, upstreams={}, bundles=man)).encode())] + [(k + ".json.gz", b) for k, b in blobs.items()]:
                ti = tarfile.TarInfo(n); ti.size = len(data); t.addfile(ti, io.BytesIO(data))
        self.c.r = {"resources": str(self.t / "res")}
        return blobs

    def test_local_snapshot_first_cloud_increments(self):
        # 本地优先、云端兜底（11-13）：快照与云端同 sha 的包不下载；云端更新了的这一个增量下；云端不通只用快照
        same = {k: self.bundles[k] for k in ("b/FF1D1C05670DB602",)}
        old_g = [dict(self.bundles[f"g/{GID}"][0], name="old.pchtxt")]   # 快照里这款的包是旧的
        self.snapshot(dict(same, **{f"g/{GID}": old_g}))
        real, calls = patches._get, []
        patches._get = lambda url: (calls.append(url), real(url))[1]
        try:
            dirs = patches.fetch(self.c, dict(id=GID), str(self.exefs))
            self.assertEqual([Path(d).name for d in dirs], ["fps", "widescreen"])
            got = sorted(Path(u).name for u in calls)
            self.assertEqual(got, [f"{GID}.json.gz", "index.json"])                                  # 只下了云端更新了的那一个包（外加清单）
            self.assertEqual(Path(dict(zip(*[l.split("\t") for l in (Path(dirs[1]) / "INDEX.tsv").read_text().splitlines()[:2]]))["path"]).name, "1.0.pchtxt")   # 用的是云端新的
            shutil.rmtree(self.base); shutil.rmtree(self.c.private / "community-cache")
            calls.clear()
            dirs = patches.fetch(self.c, dict(id=GID), str(self.exefs))                                 # 云端不通、没有增量缓存：只用快照
            self.assertEqual(sorted(Path(d).name for d in dirs), ["fps", "widescreen"])
            ws = (Path(dirs[1]) / "INDEX.tsv").read_text().splitlines()
            self.assertEqual(Path(dict(zip(ws[0].split("\t"), ws[1].split("\t")))["path"]).name, "old.pchtxt")
        finally:
            patches._get = real

    def test_cloud_dropped_bundle_is_not_used(self):
        # 云端清单里已经没有的包（上游删了）：快照里有也不用
        self.snapshot({"b/FF1D1C05670DB602": self.bundles["b/FF1D1C05670DB602"]})
        del self.bundles["b/FF1D1C05670DB602"]; shutil.rmtree(self.base); self.base.mkdir(); self.publish()
        dirs = patches.fetch(self.c, dict(id=GID), str(self.exefs))
        self.assertEqual([Path(d).name for d in dirs], ["widescreen"])

    def test_match_for_the_pack_page(self):
        # 出包页 S 级优化（11-13）：解过包（知道构建号）= 这个版本命中几条各类；只命中游戏的按上游路径里的版本号列各支持哪几类
        import cheats
        self.c.library = self.t / "lib"; self.c.library.mkdir()
        (self.c.library / "catalog.json").write_text(json.dumps({"games": [{"id": GID, "packages": []}]}))
        self.c.r = {"gameId": GID}
        self.bundles[f"g/{GID}"].append(it(b"v13", "pchtxt", "fps", "1.3.0.pchtxt", [GID], ["AAAABBBBCCCCDDDD"], path=f"G/[{GID}]/1.3.0/60fps.pchtxt"))
        self.bundles[f"g/{GID}"].append(it(b"R\t00\n", "pso", "pso", "2.0.1.tsv", [GID], [], path=f"{GID}/2.0.1.tsv"))   # 管线种子：路径带版本号也不列
        self.publish()
        real = cheats.main_build
        try:
            cheats.main_build = lambda c, g: "FF1D1C05670DB602"
            r = patches.match(self.c)
            self.assertEqual((r["build"], r["exact"], r["total"]), ("FF1D1C05670DB602", {"widescreen": 0, "fps": 1, "gfx": 0, "cheat": 1}, 2))
            self.assertEqual(r["others"], [{"version": "1.0", "cats": ["widescreen"]}, {"version": "1.3.0", "cats": ["fps"]}])
            cheats.main_build = lambda c, g: ""                                    # 没解过包：不知道版本，精确命中为空，只列各版本
            r = patches.match(self.c)
            self.assertEqual((r["build"], r["total"]), ("", 0))
            self.assertEqual([o["version"] for o in r["others"]], ["1.0", "1.3.0"])
        finally:
            cheats.main_build = real

    def test_boost_counts_packed_patches_and_cheats(self):
        img = self.t / "image"; img.mkdir()
        (img / "cpatch.tsv").write_text("编号\t模块\nfps:a\tmain\nfps:a\tsdk\nwidescreen:b\tmain\ngfx:c\tmain\ncheat:d:1\tmain\n")
        import cheats
        real = cheats.listing
        cheats.listing = lambda c, g: dict(items=[dict(ok=True), dict(ok=True), dict(ok=False)], reason="")
        try:
            self.assertEqual(patches.boost(self.c, dict(id=GID), img), dict(cheats=2, fps=1, widescreen=1, gfx=1))   # 同编号两模块算一份；金手指只数这个版本能开的
        finally:
            cheats.listing = real

    def test_cheats_fetch_reads_the_unified_bundle(self):
        import cheats
        real = cheats.main_build
        cheats.main_build = lambda c, g: "FF1D1C05670DB602"
        try:
            self.c.library = self.t / "lib"; self.c.engine = self.t / "engine"
            got = cheats.fetch(self.c, dict(id=GID))
            d = cheats.cheats_dir(self.c, GID)
            self.assertEqual(got, ["bad1dea/NXCheats"])
            self.assertEqual(sorted(f.name for f in d.glob("*.txt")), ["FF1D1C05670DB602.nxcheats.txt"])   # 库简名同 11-12 起的文件名（玩家已开的开关键不变）
            src = json.loads((d / "sources.json").read_text())["FF1D1C05670DB602.nxcheats.txt"]
            self.assertEqual((src["repo"], src["author"], src["license"]), ("bad1dea/NXCheats", "a", "MIT"))
        finally:
            cheats.main_build = real


if __name__ == "__main__":
    unittest.main()
