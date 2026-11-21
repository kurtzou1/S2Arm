"""下游深度方案（pack/jobs/downstream.py + pack/downstream/schemes.json）：登记表、命中、能不能选与原因、包件下载核对、程序版本核对。
期望值按规格直接写出（不调被测实现算期望）；不联网（包件用 file:// 地址）。"""
import hashlib
import io
import json
from pathlib import Path
import plistlib
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

    def lock(self, *a, **k):   # 装机类作业的手机锁（ipa.phone_lock）
        import contextlib
        return contextlib.nullcontext()


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


class WorkDirTest(unittest.TestCase):
    """#1915：DM_ROOT 跨出包复用，换了包件还留着上一版工具放的翻译器 → 用错。工作目录归属某一份包件，换包件整个清掉"""
    def test_same_bundle_keeps_work_other_bundle_clears_it(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "out"
            old = scheme(bundle=dict(tag="v2.3.1", commit=COMMIT, urls=[], sha256="a" * 64))
            new = scheme(bundle=dict(tag="v2.3.3", commit=COMMIT, urls=[], sha256="b" * 64))
            w = ds.work_dir(out, old)
            stale = w / "build/gfx/dmsh_xlate/dmsh_xlate"; stale.parent.mkdir(parents=True); stale.write_bytes(b"old")
            self.assertEqual(ds.work_dir(out, old), out / "work")
            self.assertEqual(stale.read_bytes(), b"old")                      # 同一份包件：照旧复用
            w = ds.work_dir(out, new)
            self.assertFalse(stale.exists())                                  # 换包件：上一版放的东西清掉
            self.assertEqual((w / ".bundle").read_text(), "b" * 64)

    def test_work_left_by_old_version_without_mark_is_cleared(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "out"
            stale = out / "work/build/gfx/dmsh_xlate/dmsh_xlate"; stale.parent.mkdir(parents=True); stale.write_bytes(b"old")
            ds.work_dir(out, scheme(bundle=dict(tag="v1", commit=COMMIT, urls=[], sha256="c" * 64)))
            self.assertFalse(stale.exists())                                  # 修复前留下的、没记归属：清一次


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

    def test_corrupt_download_is_fetched_again(self):
        """维护者 11-17（玩家判断不了的我们替他判）：下载的包件 SHA 不对 → 不用它、自动重下；重下对了就照常用。期望手写：
        第一次读到坏字节、第二次读到原样 → 照常解开，同一地址共请求 2 次"""
        import io, unittest.mock as um
        with tempfile.TemporaryDirectory() as d:
            z, sha = self.make(d)
            good = z.read_bytes(); calls = []
            class Resp(io.BytesIO):
                headers = {}
                def __enter__(self): return self
                def __exit__(self, *a): return False
            def fake(req, timeout=None):
                calls.append(req.full_url)
                return Resp(b"bad" if len(calls) == 1 else good)
            s = scheme(bundle=dict(tag="v1", commit=COMMIT, urls=["https://example.invalid/b.zip"], sha256=sha))
            c = FakeContext(Path(d) / "private"); c.private.mkdir()
            with um.patch.object(ds.urllib.request, "urlopen", fake):
                root = ds.fetch_bundle(c, s)
            self.assertEqual((root / "src/dm/tools/d2rm_pack.py").read_bytes(), b"print(1)\n")
            self.assertEqual(len(calls), 2)

    def test_other_commit_is_fetched_again_then_refused_and_not_kept(self):
        """内容和登记的不一致：删掉这份、整件重下一遍；还不对才报（说明重下过），且不留这份 zip（下次不再用它）。期望手写：请求 2 次"""
        import unittest.mock as um
        with tempfile.TemporaryDirectory() as d:
            z, sha = self.make(d, commit="d" * 40)
            s = scheme(bundle=dict(tag="v1", commit=COMMIT, urls=[z.as_uri()], sha256=sha))
            c = FakeContext(Path(d) / "private"); c.private.mkdir()
            real = ds.urllib.request.urlopen; calls = []
            with um.patch.object(ds.urllib.request, "urlopen", lambda req, timeout=None: (calls.append(1), real(req, timeout=timeout))[1]):
                with self.assertRaisesRegex(Failure, "重新下载后还是不对"):
                    ds.fetch_bundle(c, s)
            self.assertEqual(len(calls), 2)
            self.assertFalse(list((c.private / "downstream").rglob("*.zip")))

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


IML = "com.apple.developer.kernel.increased-memory-limit"
EVA = "com.apple.developer.kernel.extended-virtual-addressing"


class WinContext:
    """Windows 装机要用到的作业上下文：begin / emit 只记、run 记命令并在跑 rcodesign 时读下它要签进的权限文件"""
    def __init__(self, d, request=None):
        self.private, self.engine, self.task, self.r = Path(d) / "private", Path(d) / "engine", "t1", request or {}
        self.private.mkdir(parents=True)
        self.steps, self.messages, self.runs, self.ents = [], [], [], None

    def begin(self, name, i, n): self.steps.append((i, n, name))
    def emit(self, kind, m): self.messages.append(m)

    def run(self, cmd, log, env=None, cwd=None):
        self.runs.append([str(x) for x in cmd]); self.cwds = getattr(self, "cwds", []) + [cwd]
        if "-e" in self.runs[-1]:
            self.ents = plistlib.loads((Path(cwd or ".") / self.runs[-1][self.runs[-1].index("-e") + 1]).read_bytes())


class FakeWin:
    """pack/orch/install_win.py 的替身：记 install_app 收到的参数（与那时 ipa 里的文件）、push_pack 的参数"""
    class Fail(Exception):
        def __init__(self, msg, code=1, err=None):
            super().__init__(msg); self.err = err

    def __init__(self, team="ABCDE12345", fail=None):
        self.ns = self.names = self.pushed = None
        self.fail = fail
        self.impactor = unittest.mock.Mock(bundled=lambda r: {"plumesign": "plumesign.exe"}, select_only_account=lambda exe: None, selected_team=lambda: team)

    def plumesign_path(self, given): return given

    def install_app(self, ns, say=None):
        self.ns = ns
        self.names = zipfile.ZipFile(ns.ipa).namelist()
        if self.fail: raise self.fail
        return ns.bundle

    def push_pack(self, udid, bid, pack, devpush=None, **kw):
        self.pushed = dict(udid=udid, bid=bid, pack=str(pack), **kw)
        return 3, 100


class WinInstallTest(unittest.TestCase):
    """Windows 装下游独立 App（install_ios_win）：入参、返回、出包记录与 Mac 同形；签名装机 / 推送走 install_win（这里打桩）"""
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); d = Path(self.d.name)
        self.c = WinContext(d)
        self.s = scheme(targets=dict(ios=dict(tool="t.py", entitlements=[IML, EVA])))
        out = d / "lib" / "downstream" / "demo"; out.mkdir(parents=True)
        ipa = out / "demo.ipa"
        with zipfile.ZipFile(ipa, "w") as z:
            z.writestr("Payload/Demo.app/Info.plist", plistlib.dumps(dict(CFBundleIdentifier="org.demo")))
            z.writestr("Payload/Demo.app/Demo", b"bin")
        (out / "pack").mkdir(); (out / "pack" / "manifest.json").write_text("{}")
        self.rec = dict(scheme="demo", ipa=str(ipa), pack=str(out / "pack"))
        self.out = out
        import install as inst
        self.inst = inst

    def tearDown(self): self.d.cleanup()

    def go(self, W):
        import devcert
        with unittest.mock.patch.object(ds, "last_record", lambda c, gid, s: self.rec), \
             unittest.mock.patch.object(ds, "out_dir", lambda c, gid, s: self.out), \
             unittest.mock.patch.object(self.inst, "win_install_mod", lambda c: W), \
             unittest.mock.patch.object(self.inst, "win_udid", lambda c, w: "UDID1"), \
             unittest.mock.patch.object(devcert, "rcodesign_path", lambda c: "rcodesign.exe"):
            return ds.install_ios_win(self.c, dict(id="0100000000010000"), self.s)

    def test_signs_installs_and_pushes(self):
        W = FakeWin()
        r = self.go(W)
        # 包名同 Mac：io.s2arm.ds.<方案>.<小写团队号>；权限按免费团队只申请提高内存上限（扩展寻址免费团队签不了）
        self.assertEqual(W.ns.bundle, "io.s2arm.ds.demo.abcde12345")
        self.assertEqual(self.c.ents, {IML: True})
        self.assertEqual(self.c.runs[0][:3], ["rcodesign.exe", "sign", "-e"])
        self.assertTrue(self.c.runs[0][-1].endswith("Demo.app"))
        # D-J7CH：rcodesign 的 -e 是「作用范围:值」、按第一个冒号拆，Windows 盘符路径会把权限挂到「C」上（os error 3）
        #   → 只传不含冒号的文件名、在权限文件所在目录里跑；被签的 .app 传绝对路径（运行目录换了也找得到）
        e = self.c.runs[0][self.c.runs[0].index("-e") + 1]
        self.assertNotIn(":", e); self.assertEqual(e, "downstream.entitlements")
        self.assertIsNotNone(self.c.cwds[0]); self.assertTrue(Path(self.c.runs[0][-1]).is_absolute())
        self.assertIn("Payload/Demo.app/Demo", W.names)   # 交给 plumesign 的是重新打好的 .ipa
        self.assertEqual((W.ns.udid, W.ns.plumesign), ("UDID1", "plumesign.exe"))
        self.assertEqual((W.pushed["udid"], W.pushed["bid"], W.pushed["pack"]), ("UDID1", "io.s2arm.ds.demo.abcde12345", self.rec["pack"]))
        self.assertNotIn("docs", W.pushed); self.assertNotIn("apply_after", W.pushed)   # 单款 App：Documents 为根、不起 App 解包（同 Mac）
        self.assertEqual((r["bundleId"], r["packFiles"], r["packBytes"], r["openToFinish"]), ("io.s2arm.ds.demo.abcde12345", 3, 100, True))
        saved = json.loads((self.out / "record.json").read_text())
        self.assertEqual(saved["installed"]["bundleId"], "io.s2arm.ds.demo.abcde12345")
        self.assertEqual([i for i, n, _ in self.c.steps], [1, 2, 3, 4])

    def test_no_selected_account_stops_before_signing(self):
        W = FakeWin(team=None)
        with self.assertRaises(Failure) as e:
            self.go(W)
        self.assertEqual(e.exception.code, "apple_not_signed_in")
        self.assertIsNone(W.ns)

    def test_signing_failure_keeps_its_code(self):
        W = FakeWin()
        W.fail = FakeWin.Fail("签名装机失败（free_appid_limit）：Developer API error 9120", err="free_appid_limit")
        with self.assertRaises(Failure) as e:
            self.go(W)
        self.assertEqual(e.exception.code, "free_appid_limit")
        self.assertIsNone(W.pushed)

    def test_windows_dispatch(self):
        with unittest.mock.patch.object(ds.os, "name", "nt"), unittest.mock.patch.object(ds, "install_ios_win", lambda c, g, s: "win") as _:
            self.assertEqual(ds.install_ios(None, dict(id="x"), self.s), "win")


class ExportTest(unittest.TestCase):
    def test_export_with_scheme_says_install_only(self):
        import install as inst
        with tempfile.TemporaryDirectory() as d:
            c = FakeContext(d, dict(gameId="0100000000010000", mode="export"))
            with unittest.mock.patch.object(ds, "requested", lambda c, g: scheme()), \
                 unittest.mock.patch.object(ds, "install_ios", lambda *a: self.fail("导出不该去装机")):
                with self.assertRaises(Failure) as e:
                    inst.install(c)
            self.assertEqual(e.exception.code, "downstream_export_unsupported")


class HostTest(unittest.TestCase):
    """方案能在哪些电脑上出包（登记表 targets.ios.hosts，#1272）：本机平台不在里面 → 不能选、原因说只能在 Mac 上出"""
    def test_mac_only_scheme_on_windows(self):
        s = scheme(targets=dict(ios=dict(tool="t.py", hosts=["mac"])))
        ok, why = ds.eligibility(s, game(), host="windows")
        self.assertFalse(ok); self.assertIn("Mac", why)
        self.assertFalse(ds.eligibility(s, game(), "en", host="windows")[0])
        self.assertEqual(ds.eligibility(s, game(), host="mac"), (True, ""))

    def test_hosts_default_is_mac_only(self):
        s = scheme(targets=dict(ios=dict(tool="t.py")))
        self.assertFalse(ds.eligibility(s, game(), host="windows")[0])
        self.assertTrue(ds.eligibility(s, game(), host="mac")[0])

    def test_windows_listed_opens_it(self):
        s = scheme(targets=dict(ios=dict(tool="t.py", hosts=["mac", "windows"])))
        self.assertEqual(ds.eligibility(s, game(), host="windows"), (True, ""))

    def test_real_registry_opens_windows(self):
        # 下游 v2.3.3 起做包不再要 C 编译器 / .NET / spirv-cross（壳里自带预编件，#1272），Windows 也能出：登记表放开
        real = ds.load()
        self.assertEqual(ds.hosts(real["d2r-mobile"]), ["mac", "windows"])


class DownstreamInput(unittest.TestCase):
    """#1570：共用解包只有 RomFS 镜像 romfs.std 时，交给下游做包工具的目录要有逐文件的 romfs/。期望手写：
    ① 只有 romfs.std → 工具拿到 work/downstream-input：exefs、ctl 里的文件是解包目录对应文件的硬链接（同 inode），romfs/ 下每个文件与镜像里逐字节相同，镜像不放进去；
    ② 解包目录本来就有 romfs/ 真目录 → 原样交解包目录、不展开；③ 两种都没有 → 原样交（缺什么由工具自己报）"""
    def setUp(self):
        from test_onerom import std_romfs
        self.d = Path(tempfile.mkdtemp()); self.addCleanup(lambda: __import__("shutil").rmtree(self.d, ignore_errors=True))
        self.ex = self.d / "extract"; (self.ex / "exefs").mkdir(parents=True); (self.ex / "ctl").mkdir()
        (self.ex / "exefs/main").write_bytes(b"MAIN")
        self.files = {"build_manifest.psv": b"psv" * 1000, "a.bin": bytes(range(256)) * 300, "empty": b""}
        self.std = std_romfs(self.files)
        c = unittest.mock.Mock(); c.engine = str(JOBS.parents[1]); self.c = c

    def test_image_is_expanded(self):
        (self.ex / "romfs.std").write_bytes(self.std)
        got, expanded = ds._downstream_input(self.c, self.ex, self.d / "work")
        self.assertEqual((got, expanded), (self.d / "work/downstream-input", self.d / "work/downstream-input/romfs"))
        self.assertEqual(sorted(p.name for p in got.iterdir()), ["ctl", "exefs", "romfs"])
        self.assertEqual(((got / "exefs/main").read_bytes(), (got / "exefs/main").stat().st_ino), (b"MAIN", (self.ex / "exefs/main").stat().st_ino))
        self.assertEqual({p.name: p.read_bytes() for p in (got / "romfs").iterdir()}, self.files)

    def test_real_romfs_dir_passes_through(self):
        (self.ex / "romfs").mkdir(); (self.ex / "romfs/x").write_bytes(b"x")
        self.assertEqual(ds._downstream_input(self.c, self.ex, self.d / "work"), (self.ex, None))
        self.assertFalse((self.d / "work").exists())

    def test_no_romfs_passes_through(self):
        self.assertEqual(ds._downstream_input(self.c, self.ex, self.d / "work"), (self.ex, None))


if __name__ == "__main__":
    unittest.main()
