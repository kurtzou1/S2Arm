"""下游深度方案（pack/jobs/downstream.py + pack/downstream/schemes.json）：登记表、命中、能不能选与原因、包件下载核对、程序版本核对。
期望值按规格直接写出（不调被测实现算期望）；不联网（包件用 file:// 地址）。"""
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import unittest.mock
import zipfile

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))
import downstream as ds
from core import Failure

TITLE = "0100726014352000"
COMMIT = "c" * 40


class FakeContext:
    def __init__(self, private, request=None):
        self.private, self.r = Path(private), request or {}


def game(*updates, gid=TITLE):
    pk = [dict(type="base", version=0, titleId=gid, sha256="b", display="1.0.0")]
    pk += [dict(type="update", version=v, titleId=gid[:13] + "800", sha256=f"u{v}", display=d) for v, d in updates]
    return dict(id=gid, name="x", packages=pk)


def scheme(**over):
    s = dict(id="demo", name="Demo", repo="o/demo", license="MIT", titleIds=["0100000000010000"], needs={}, targets={},
             bundle=dict(tag="v1", commit=COMMIT, urls=[], sha256=""), copy=dict(zh=dict(title="t")))
    s.update(over)
    return s


def write_registry(d, schemes):
    p = Path(d) / "schemes.json"
    p.write_text(json.dumps(dict(schema=1, schemes=schemes)), encoding="utf-8")
    return p


class RegistryTest(unittest.TestCase):
    def test_free_team_drops_paid_only_entitlements(self):
        # #897：期望按规则手写——免费个人团队只申请提高内存上限，付费团队两项都带；不知道团队类型按免费（宁可少申请、装得上）
        t = {"entitlements": ["com.apple.developer.kernel.increased-memory-limit", "com.apple.developer.kernel.extended-virtual-addressing"]}
        self.assertEqual(ds.install_entitlements(t, {"free": True}), ["com.apple.developer.kernel.increased-memory-limit"])
        self.assertEqual(ds.install_entitlements(t, {"free": False}), t["entitlements"])
        self.assertEqual(ds.install_entitlements(t, {}), ["com.apple.developer.kernel.increased-memory-limit"])
        self.assertEqual(ds.install_entitlements({}, {"free": False}), [])

    def test_real_registry_loads_and_matches_title(self):
        schemes = ds.load()
        s = ds.match(dict(id=TITLE.lower()), schemes)   # 程序号大小写不敏感
        self.assertEqual(s["id"], "d2r-mobile")
        self.assertIsNone(ds.match(dict(id="01006F8002326000"), schemes))

    def test_registry_text_has_no_game_name(self):
        # 公开仓文字不写游戏名：界面上的游戏名取玩家自己游戏包里的；登记表只写程序号与方案名
        text = ds.REGISTRY.read_text(encoding="utf-8")
        for word in ("暗黑", "Diablo", "Resurrected", "狱火"):
            self.assertNotIn(word, text)

    def test_rejects_bad_entries(self):
        with tempfile.TemporaryDirectory() as d:
            for bad, why in ((scheme(bundle=dict(tag="v1", commit="abc", urls=[], sha256="")), "40 位"),
                             (scheme(titleIds=["XYZ"]), "格式不对"),
                             ({k: v for k, v in scheme().items() if k != "copy"}, "缺字段")):
                with self.assertRaisesRegex(ds.SchemeError, why):
                    ds.load(write_registry(d, [bad]))
            with self.assertRaisesRegex(ds.SchemeError, "登记了两个"):
                ds.load(write_registry(d, [scheme(), scheme(id="other")]))


class AppLayoutTest(unittest.TestCase):
    """发版 App：作业代码在 Resources/Jobs，引擎快照在 Resources/Engine（v0.3.3 候选导入即红的根因：按本文件位置拼出 Resources/downstream）"""
    def test_registry_follows_engine_dir(self):
        with tempfile.TemporaryDirectory() as d:
            engine = Path(d) / "Engine"
            (engine / "pack/downstream").mkdir(parents=True)
            write_registry(engine / "pack/downstream", [scheme()])
            ctx = FakeContext(d); ctx.engine = engine
            self.assertEqual(ds.registry(ctx), engine / "pack/downstream/schemes.json")
            self.assertEqual(ds.match(dict(id="0100000000010000"), c=ctx)["id"], "demo")

    def test_missing_registry_means_no_scheme(self):
        with tempfile.TemporaryDirectory() as d:
            ctx = FakeContext(d); ctx.engine = Path(d) / "no-engine"
            self.assertEqual(ds.load(c=ctx), {})                                     # 缺文件：空表、不抛
            self.assertIsNone(ds.describe(ctx, dict(id=TITLE, packages=[])))         # 读库 / 导入照常（不命中下游）
            ctx.r = dict(scheme="d2r-mobile")
            self.assertIsNone(ds.requested(ctx, dict(id=TITLE)))                     # 出包也照常：按原版
            (Path(d) / "bad.json").write_text("{坏", encoding="utf-8")
            self.assertEqual(ds.load(Path(d) / "bad.json"), {})                      # 坏 JSON 同样当没有


class EngineSnapshotTest(unittest.TestCase):
    """v0.3.3 候选导入即红的回归锁：发版引擎快照（launchers/macos/bundle_engine.py，Windows bundle_win 同一份）里要有登记表，
    按 App 布局（作业代码在 Resources/Jobs、快照在 Resources/Engine）读得到"""
    def test_snapshot_ships_registry_and_app_layout_reads_it(self):
        import shutil, subprocess
        repo = JOBS.parents[1]
        try:
            files = subprocess.run([sys.executable, "-c", "import sys; sys.path.insert(0, 'launchers/macos'); import bundle_engine; "
                                    "print('\\n'.join(map(str, bundle_engine.snapshot_files())))"],
                                   cwd=repo, capture_output=True, text=True, check=True).stdout.split()
        except subprocess.CalledProcessError as e:
            self.fail(e.stderr[-800:])
        self.assertIn("pack/downstream/schemes.json", files)
        self.assertIn("pack/jobs/downstream.py", files)
        with tempfile.TemporaryDirectory() as d:
            res = Path(d) / "Resources"
            for rel in ("pack/downstream/schemes.json",):
                (res / "Engine" / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(repo / rel, res / "Engine" / rel)
            ctx = FakeContext(d); ctx.engine = res / "Engine"
            self.assertEqual(ds.match(dict(id=TITLE), c=ctx)["id"], "d2r-mobile")


class EligibilityTest(unittest.TestCase):
    s = scheme(name="D2R-Mobile", needs=dict(updateVersion=2228224, updateDisplay="1.0.34.0"))

    def test_right_update(self):
        self.assertEqual(ds.eligibility(self.s, game((2228224, "1.0.34.0"))), (True, ""))

    def test_other_update_says_only_which_and_what_to_do(self):
        self.assertEqual(ds.eligibility(self.s, game((2293760, "1.0.35.0"))),
                         (False, "D2R-Mobile 只支持 1.0.34.0 更新，你导入的是 1.0.35.0。导入 1.0.34.0 更新后可选"))

    def test_english_reason(self):
        self.assertEqual(ds.eligibility(self.s, game((2293760, "1.0.35.0")), "en"),
                         (False, "D2R-Mobile supports update 1.0.34.0 only, and you imported 1.0.35.0. Import update 1.0.34.0 to choose it"))

    def test_no_update(self):
        self.assertEqual(ds.eligibility(self.s, game()),
                         (False, "D2R-Mobile 只支持 1.0.34.0 更新，你还没导入更新。导入 1.0.34.0 更新后可选"))

    def test_newest_update_counts(self):
        self.assertEqual(ds.eligibility(self.s, game((2162688, "1.0.33.0"), (2228224, "1.0.34.0")))[0], True)


class RequestTest(unittest.TestCase):
    def stored(self, d, choice):
        p = Path(d) / "downstream.json"
        if choice is not None:
            p.write_text(json.dumps(dict(scheme=choice, at=0)), encoding="utf-8")
        return unittest.mock.patch.object(ds, "_choice_path", lambda c, gid, create=True: p)

    def test_no_scheme_and_nothing_stored_is_original_route(self):
        with tempfile.TemporaryDirectory() as d, self.stored(d, None):
            self.assertIsNone(ds.requested(FakeContext(d), dict(id=TITLE)))

    def test_stored_choice_is_used_when_request_says_nothing(self):
        # 出包编排的子作业、新版前端都不带 scheme：按玩家在确认页记下的选择走
        with tempfile.TemporaryDirectory() as d, self.stored(d, "d2r-mobile"):
            self.assertEqual(ds.requested(FakeContext(d), dict(id=TITLE))["id"], "d2r-mobile")

    def test_request_overrides_stored_choice(self):
        with tempfile.TemporaryDirectory() as d, self.stored(d, "d2r-mobile"):
            self.assertIsNone(ds.requested(FakeContext(d, dict(scheme="")), dict(id=TITLE)))

    def test_scheme_must_match_game(self):
        with self.assertRaises(Failure):
            ds.requested(FakeContext("/nonexistent", dict(scheme="d2r-mobile")), dict(id="01006F8002326000"))
        self.assertEqual(ds.requested(FakeContext("/nonexistent", dict(scheme="d2r-mobile")), dict(id=TITLE))["id"], "d2r-mobile")


class BundleTest(unittest.TestCase):
    def make(self, d, commit=COMMIT):
        z = Path(d) / "bundle.zip"
        with zipfile.ZipFile(z, "w") as zf:
            zf.writestr("bundle.json", json.dumps(dict(tag="v1", commit=commit, product="p")))
            zf.writestr("shell.zip", b"shell")
            zf.writestr("src/dm/tools/d2rm_pack.py", b"print(1)\n")
        return z, hashlib.sha256(z.read_bytes()).hexdigest()

    def test_fetch_unpacks_and_reuses(self):
        with tempfile.TemporaryDirectory() as d:
            z, sha = self.make(d)
            s = scheme(bundle=dict(tag="v1", commit=COMMIT, urls=[z.as_uri()], sha256=sha))
            c = FakeContext(Path(d) / "private"); c.private.mkdir()
            root = ds.fetch_bundle(c, s)
            self.assertEqual((root / "src/dm/tools/d2rm_pack.py").read_bytes(), b"print(1)\n")
            z.unlink()   # 第二次不再下载：已解开且核过
            self.assertEqual(ds.fetch_bundle(c, s), root)

    def test_wrong_sha_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            z, _ = self.make(d)
            s = scheme(bundle=dict(tag="v1", commit=COMMIT, urls=[z.as_uri()], sha256="0" * 64))
            c = FakeContext(Path(d) / "private"); c.private.mkdir()
            with self.assertRaises(Failure) as e:
                ds.fetch_bundle(c, s)
            self.assertEqual(e.exception.code, "download_failed")

    def test_other_commit_inside_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            z, sha = self.make(d, commit="d" * 40)
            s = scheme(bundle=dict(tag="v1", commit=COMMIT, urls=[z.as_uri()], sha256=sha))
            c = FakeContext(Path(d) / "private"); c.private.mkdir()
            with self.assertRaisesRegex(Failure, "不一致"):
                ds.fetch_bundle(c, s)

    def test_unpublished_bundle_says_so(self):
        with self.assertRaisesRegex(Failure, "还没上线"):
            ds.fetch_bundle(FakeContext("/nonexistent"), scheme())


class ExefsTest(unittest.TestCase):
    def test_exefs_must_be_the_pinned_build(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "exefs").mkdir()
            (Path(d) / "exefs" / "main").write_bytes(b"other build")
            s = scheme(needs=dict(updateDisplay="1.0.34.0", exefsSha256=dict(main=hashlib.sha256(b"pinned").hexdigest())))
            with self.assertRaises(Failure) as e:
                ds._check_exefs(s, d)
            self.assertEqual(e.exception.code, "downstream_ineligible")
            (Path(d) / "exefs" / "main").write_bytes(b"pinned")
            ds._check_exefs(s, d)


if __name__ == "__main__":
    unittest.main()
