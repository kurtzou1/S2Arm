"""开发者证书签名（pack/jobs/devcert.py，v0.2.4）：期望值都按描述文件内容手算，不跑被测实现推。
rcodesign / openssl 只在「真工具」一组用（S2A_RCODESIGN 指向 rcodesign 且本机有 /usr/bin/openssl 才跑）；其余组替身掉证书读取，各端都跑。
测试证书一律现场自造，不用任何真实证书。"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
import jobcase  # noqa: E402（作业上下文替身统一工厂 jobcase.fake_context）
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import devcert   # noqa: E402
from core import Failure   # noqa: E402

TEAM = "ABCDE12345"
DER = b"\x30\x82fake-cert-der"              # 描述文件 DeveloperCertificates 里的那张
SHA1 = hashlib.sha1(DER).hexdigest()
NOW = datetime.datetime(2026, 11, 9, tzinfo=datetime.timezone.utc)
IML, EVA = devcert.WANT


def profile(appid=f"{TEAM}.*", ents=None, devices=("00000000-000A1B2C3D4E5F60",), all_devices=False, expires=NOW + datetime.timedelta(days=200), certs=(DER,)):
    e = {"application-identifier": appid, "com.apple.developer.team-identifier": TEAM, "get-task-allow": True, IML: True, EVA: True,
         "keychain-access-groups": [f"{TEAM}.*"]}
    e.update(ents or {})
    p = {"ApplicationIdentifierPrefix": [TEAM], "TeamIdentifier": [TEAM], "TeamName": "S2Arm Test Co", "Name": "Test Profile",
         "ExpirationDate": expires.replace(tzinfo=None), "DeveloperCertificates": list(certs), "Entitlements": {k: v for k, v in e.items() if v is not None}}
    if all_devices:
        p["ProvisionsAllDevices"] = True
    else:
        p["ProvisionedDevices"] = list(devices)
    # 真描述文件是 CMS 包着 plist：前后垫上非 plist 字节，解析只认中间那段
    return b"\x30\x80\x06\x09cms-header" + plistlib.dumps(p) + b"\x00\x00cms-signature"


def cert(sha1=SHA1, end=NOW + datetime.timedelta(days=300)):
    return {"Subject CN": f"iPhone Developer: Test ({TEAM})", "Team ID": TEAM, "SHA-1 fingerprint": sha1, "Not Valid After": end.isoformat()}


class Parse(unittest.TestCase):
    def test_profile_inside_cms(self):
        self.assertEqual(devcert.parse_profile(profile())["TeamName"], "S2Arm Test Co")
        for bad in (b"not a profile", plistlib.dumps({"Name": "x"})):
            with self.subTest(bad=bad[:12]), self.assertRaises(Failure) as e:
                devcert.parse_profile(bad)
            self.assertEqual(e.exception.code, "devcert_invalid")

    def test_bundle_id(self):
        # 通配 * → io.s2arm.games.<小写团队号>（同 Apple ID 模式）；前缀通配 → 前缀 + s2arm；明确的 → 原样
        cases = {f"{TEAM}.*": ("io.s2arm.games.abcde12345", True), f"{TEAM}.com.foo.*": ("com.foo.s2arm", True), f"{TEAM}.com.foo.bar": ("com.foo.bar", False)}
        for appid, want in cases.items():
            with self.subTest(appid=appid):
                self.assertEqual(devcert.bundle_id(devcert.parse_profile(profile(appid))), want)

    def test_standalone_bundle_id(self):
        # 独立 App 按款（0.6.3）：通配 → io.s2arm.games.<小写团队号>.<完整 16 位程序号小写>；前缀通配 → 前缀 + s2arm.<程序号>；显式 → 只有它那一个（False = 定不了）
        gid = "0100ABCD0000E000"
        cases = {f"{TEAM}.*": ("io.s2arm.games.abcde12345.0100abcd0000e000", True), f"{TEAM}.com.foo.*": ("com.foo.s2arm.0100abcd0000e000", True),
                 f"{TEAM}.com.foo.bar": ("com.foo.bar", False)}
        for appid, want in cases.items():
            with self.subTest(appid=appid):
                self.assertEqual(devcert.bundle_id(devcert.parse_profile(profile(appid)), gid), want)

    def test_entitlements_are_profile_intersection(self):
        # 描述文件只开了提高内存上限：签进去的只有身份三项 + 这一项；钥匙串组等 S2Arm 不要的不带
        p = devcert.parse_profile(profile(ents={EVA: None}))
        self.assertEqual(devcert.entitlements(p, "io.s2arm.games.abcde12345"),
                         {"application-identifier": f"{TEAM}.io.s2arm.games.abcde12345", "com.apple.developer.team-identifier": TEAM, "get-task-allow": True, IML: True})
        # 签进去的权限照抄描述文件（false 照带 false）；分发描述文件能不能用由 inspect 判（Inspect.test_distribution_profile_blocks）
        p = devcert.parse_profile(profile(ents={"get-task-allow": False}))
        self.assertIs(devcert.entitlements(p, "x")["get-task-allow"], False)

    def test_cert_info_reads_first_certificate(self):
        out = ("# Certificate 0\nSubject CN:                  iPhone Distribution: A (T1)\nTeam ID:                     T1\n"
               "SHA-1 fingerprint:           aa11\nNot Valid After:             2027-01-02T00:00:00+00:00\n"
               "# Certificate 1\nSubject CN:                  Apple WWDR\nSHA-1 fingerprint:           bb22\n")
        with patch.object(devcert.subprocess, "run", return_value=types.SimpleNamespace(returncode=0, stdout=out, stderr="")) as run:
            got = devcert.cert_info("rcs", Path(tempfile.gettempdir()) / "x.p12", "pw")
        self.assertEqual((got["Subject CN"], got["SHA-1 fingerprint"], got["Team ID"]), ("iPhone Distribution: A (T1)", "aa11", "T1"))
        self.assertNotIn("pw", run.call_args[0][0])   # 密码走文件，不上命令行
        with patch.object(devcert.subprocess, "run", return_value=types.SimpleNamespace(returncode=1, stdout="", stderr="incorrect password")), \
             self.assertRaises(Failure) as e:
            devcert.cert_info("rcs", Path(tempfile.gettempdir()) / "x.p12", "pw")
        self.assertEqual(e.exception.code, "devcert_password")


class Inspect(unittest.TestCase):
    def check(self, prof, c=None, udid=None):
        with patch.object(devcert, "cert_info", return_value=c or cert()):
            return devcert.inspect("rcs", "x.p12", "pw", prof, udid=udid, now=NOW)

    def codes(self, r):
        return [w["id"] for w in r["blocking"]], [w["id"] for w in r["warnings"]]

    def test_all_good(self):
        r = self.check(profile(), udid="00000000-000a1b2c3d4e5f60")   # UDID 大小写不同也算在列
        self.assertEqual(self.codes(r), ([], []))
        self.assertEqual((r["bundleId"], r["teamName"], r["deviceListed"], r["certExpires"], r["profileExpires"], r["entitlements"]),
                         ("io.s2arm.games.abcde12345", "S2Arm Test Co", True, "2027-09-05", "2027-05-28", sorted([IML, EVA])))

    def test_mismatch_is_the_only_blocker(self):
        r = self.check(profile(certs=(b"other",)))
        self.assertEqual(self.codes(r), (["devcert_mismatch"], []))

    # 三项权限各自的「中文名（技术名）——后果」与给证书发放人的话：手写期望，不从 devcert 里取
    GTA_LINE = "调试权限（get-task-allow）——没有它，通用 S2Arm 里的游戏打不开（「独立 App」不受影响）"
    IML_LINE = "提高内存上限（com.apple.developer.kernel.increased-memory-limit）——没有它大游戏可能内存不够、起不来"
    EVA_LINE = "扩展寻址（com.apple.developer.kernel.extended-virtual-addressing）——没有它大游戏可能地址不够、起不来"
    UDID = "00000000-000A1B2C3D4E5F60"

    @staticmethod
    def request(udid):
        return ("请提供 Apple Development 开发证书（.p12，附密码）和对应的 iOS App Development 开发描述文件。描述文件要求：用显式 App ID（不要通配 *），"
                f"包含我的设备 UDID：{udid}，并开启以下权限：调试权限（get-task-allow）、提高内存上限（com.apple.developer.kernel.increased-memory-limit）、"
                "扩展寻址（com.apple.developer.kernel.extended-virtual-addressing）。")

    def test_distribution_profile_warns(self):
        # 分发描述文件（0.6.3）：get-task-allow 是 false（或干脆没有）、两项内核权限都没有 → 照常导入（独立 App 能用），降为提醒、distribution 为真；
        #   三项全列、说清通用 S2Arm 里打不开，给发放人的话照旧带连着的 UDID
        for gta in (False, None):
            with self.subTest(get_task_allow=gta):
                r = self.check(profile(ents={"get-task-allow": gta, IML: None, EVA: None}), udid=self.UDID)
                self.assertEqual((self.codes(r), r["distribution"]), (([], ["devcert_distribution"]), True))
                self.assertEqual(r["missingEntitlements"], ["get-task-allow", IML, EVA])
                self.assertEqual(r["warnings"][0]["text"].split("\n"), [
                    "这是分发（发布）证书的描述文件，缺下面的权限：可以照常用它装「独立 App」（一个 App 一款游戏），通用 S2Arm 里的游戏用它签了打不开。",
                    self.GTA_LINE, self.IML_LINE, self.EVA_LINE,
                    "要用通用 S2Arm：改用 Apple ID 登录签名，或复制下面这段话发给证书发放人，换成开发证书和开发描述文件后再导入。"])
                self.assertEqual(r["requestText"], self.request(self.UDID))
        # 和不配套一起出现：只有不配套挡导入
        self.assertEqual(self.codes(self.check(profile(certs=(b"other",), ents={"get-task-allow": False}))), (["devcert_mismatch"], ["devcert_distribution"]))
        self.assertIs(self.check(profile())["distribution"], False)

    def test_missing_iml_dev_profile_warns(self):
        # 开发描述文件只缺提高内存上限：照常导入（不 blocking），只列这一项；没连手机 → UDID 写占位、提示玩家自己填
        r = self.check(profile(ents={IML: None}))
        self.assertEqual((self.codes(r), r["missingEntitlements"]), (([], ["devcert_entitlements"]), [IML]))
        self.assertEqual(r["warnings"][0]["text"].split("\n"), [
            "描述文件缺下面的权限，小游戏照常，大游戏可能起不来：", self.IML_LINE,
            "可以复制下面这段话发给证书发放人，补开后重新下载描述文件再导入。",
            "没连着 iPhone：复制后把「<你的设备 UDID>」换成你手机的 UDID。"])
        self.assertEqual(r["requestText"], self.request("<你的设备 UDID>"))

    def test_complete_dev_profile_clean(self):
        r = self.check(profile(), udid=self.UDID)
        self.assertEqual((self.codes(r), r["missingEntitlements"]), (([], []), []))
        self.assertNotIn("requestText", r)

    def test_device_listing(self):
        self.assertEqual(self.codes(self.check(profile(), udid="00000000-FFFFFFFFFFFFFFFF")), ([], ["devcert_device"]))
        r = self.check(profile(all_devices=True), udid="00000000-FFFFFFFFFFFFFFFF")   # 企业描述文件：没有列表，不报不在列
        self.assertEqual((self.codes(r), r["deviceListed"], r["allDevices"]), (([], []), True, True))
        self.assertIsNone(self.check(profile())["deviceListed"])            # 没连手机：不知道，不瞎报

    def test_expiry(self):
        r = self.check(profile(expires=NOW - datetime.timedelta(days=1)), c=cert(end=NOW + datetime.timedelta(days=10)))
        self.assertEqual(self.codes(r), ([], ["devcert_expiring", "devcert_expired"]))
        self.assertIn("还剩 10 天", r["warnings"][0]["text"])

    def test_missing_entitlement_named(self):
        r = self.check(profile(ents={EVA: None}))
        self.assertEqual((self.codes(r), r["missingEntitlements"]), (([], ["devcert_entitlements"]), [EVA]))
        self.assertIn(self.EVA_LINE, r["warnings"][0]["text"])
        self.assertNotIn("提高内存上限", r["warnings"][0]["text"])

class Secrets:
    def __init__(self):
        self.d = {}

    def save(self, a, p): self.d[a] = p
    def load(self, a): return self.d.get(a)
    def delete(self, a): self.d.pop(a, None)


class Operation(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        (self.t / "in.p12").write_bytes(b"p12"); (self.t / "in.mobileprovision").write_bytes(profile())
        self.sec = Secrets()
        for name, fake in (("normalize_p12", lambda src, dest, pw: Path(dest).write_bytes(Path(src).read_bytes())),
                           ("cert_info", lambda rcs, p12, pw: cert()), ("rcodesign_path", lambda c: "rcs")):
            p = patch.object(devcert, name, fake); p.start(); self.addCleanup(p.stop)

    def ctx(self, password=None, **r):
        return types.SimpleNamespace(r=r, private=self.t / "private", engine=self.t, devcert_secrets=self.sec, devcert_password=password, begin=lambda *a: None)

    def imp(self, password="pw", **extra):
        return devcert.operation(self.ctx(password, action="import", p12Path=str(self.t / "in.p12"), profilePath=str(self.t / "in.mobileprovision"), **extra))

    def test_import_use_delete(self):
        r = self.imp()
        d = self.t / "private/devcert"
        self.assertEqual((r["active"], r["bundleId"]), (True, "io.s2arm.games.abcde12345"))
        self.assertEqual(self.sec.d, {SHA1: "pw"})
        self.assertEqual(sorted(p.name for p in d.iterdir()), ["cert.p12", "profile.mobileprovision", "state.json"])
        self.assertNotIn("pw", (d / "state.json").read_text())
        c = self.ctx()
        self.assertTrue(devcert.active(c))
        self.assertEqual(devcert.team(c), dict(id=TEAM, name="S2Arm Test Co", free=False))
        self.assertEqual(devcert.operation(self.ctx(action="use", active=False)), dict(active=False))
        self.assertIsNone(devcert.team(self.ctx()))
        self.assertTrue(devcert.operation(self.ctx(action="status"))["imported"])
        devcert.operation(self.ctx(action="delete"))
        self.assertEqual((sorted(p.name for p in d.iterdir()), self.sec.d), ([], {}))
        self.assertEqual(devcert.operation(self.ctx(action="status")), dict(imported=False, active=False, cert=None))

    def test_blocked_import_keeps_previous(self):
        self.imp()
        (self.t / "in.mobileprovision").write_bytes(profile(certs=(b"other",)))
        with self.assertRaises(Failure) as e:
            self.imp(password="new")
        self.assertEqual(e.exception.code, "devcert_mismatch")
        self.assertEqual(self.sec.d, {SHA1: "pw"})   # 旧证书和密码原样留着
        self.assertEqual(devcert.parse_profile((self.t / "private/devcert/profile.mobileprovision").read_bytes())["DeveloperCertificates"], [DER])

    def test_distribution_import_kept_and_recorded(self):
        # 0.6.3：分发描述文件照常导入（独立 App 能用），按存着的描述文件认出分发；缺项和给发放人的话照旧随结果给（导入页「复制」用）；导入请求没带设备 → UDID 是占位
        self.imp()
        self.assertIs(devcert.distribution(self.ctx()), False)
        (self.t / "in.mobileprovision").write_bytes(profile(ents={"get-task-allow": False}))
        r = self.imp(password="new")
        self.assertEqual(([w["id"] for w in r["warnings"]], r["missingEntitlements"], r["distribution"], r["active"]),
                         (["devcert_distribution"], ["get-task-allow"], True, True))
        self.assertIn("包含我的设备 UDID：<你的设备 UDID>，", r["requestText"])
        self.assertIs(devcert.distribution(self.ctx()), True)
        self.assertNotIn("distribution", json.loads((self.t / "private/devcert/state.json").read_text()))   # 不另记一份，免得与描述文件不一致
        self.assertEqual(self.sec.d, {SHA1: "new"})   # 同一张证书换了密码：存新的
        kept = devcert.parse_profile((self.t / "private/devcert/profile.mobileprovision").read_bytes())
        self.assertIs(kept["Entitlements"]["get-task-allow"], False)
        self.assertTrue(devcert.active(self.ctx()))

    def test_distribution_of_import_before_the_flag(self):
        # 11-20 前导入的证书：state.json 只有 active / certSha1 / bundleId / teamId / teamName / imported，没有分发标记。
        #   描述文件 get-task-allow 为假或缺 → 分发；为真 → 不是；描述文件没了 / 坏了 → 不算（期望按描述文件内容手写）
        d = self.t / "private/devcert"; d.mkdir(parents=True, exist_ok=True)
        (d / "state.json").write_text(json.dumps(dict(active=True, certSha1=SHA1, bundleId="io.s2arm.games.abcde12345", teamId=TEAM, teamName="T", imported="2026-11-01T00:00:00+00:00")))
        for prof, want in ((profile(ents={"get-task-allow": False}), True), (profile(ents={"get-task-allow": None}), True),
                           (profile(), False), (b"broken", False), (None, False)):
            with self.subTest(want=want, prof=prof and prof[-40:]):
                (d / "profile.mobileprovision").unlink(missing_ok=True)
                if prof is not None:
                    (d / "profile.mobileprovision").write_bytes(prof)
                self.assertIs(devcert.distribution(self.ctx()), want)

    def test_no_password(self):
        with self.assertRaises(Failure) as e:
            self.imp(password=None)
        self.assertEqual(e.exception.code, "devcert_password")
        with self.assertRaises(Failure) as e:
            devcert.operation(self.ctx(action="use", active=True))
        self.assertEqual(e.exception.code, "devcert_missing")


class PasswordNeverInRequest(unittest.TestCase):
    def test_run_request_takes_password_from_env(self):
        # 启动器经环境变量给密码：run_request 一开始就摘掉（之后起的子进程都拿不到），交给作业；请求文件里没有
        from jobcase import ROOT, _windows_private_request
        from core import atomic
        import main
        t = Path(tempfile.mkdtemp(prefix="s2arm-devcert ")); self.addCleanup(shutil.rmtree, t, True)
        req = dict(schema=1, taskId="dc1", operation="devCert", action="status", engineDir=str(ROOT), privateRoot=str(t / "private"), library=str(t / "lib"))
        path = t / "request.json"
        (_windows_private_request if sys.platform == "win32" else atomic)(path, req)
        seen = {}
        def op(c):
            seen.update(env=os.environ.get(devcert.PASSWORD_ENV), given=c.devcert_password)
            return {}
        with patch.dict(os.environ, {devcert.PASSWORD_ENV: "s3cret"}), patch("sys.stdout", new=__import__("io").StringIO()):
            main.run_request(path, operation_overrides={"devCert": op})
        self.assertEqual(seen, dict(env=None, given="s3cret"))
        for f in (t / "private").rglob("*.json"):
            self.assertNotIn("s3cret", f.read_text(encoding="utf-8", errors="replace"))


class InstallWiring(unittest.TestCase):
    """装机接线：证书模式下 Windows 不碰 Impactor 账号、签完 plumesign 只装不签；清单换成证书两项；Mac 不读 Xcode 账号"""

    def setUp(self):
        import install
        self.m = install
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        (self.t / "lib").mkdir(); (self.t / "logs").mkdir()
        self.c = jobcase.fake_context(self.t, r={}, library=self.t / "lib", work_root=self.t / "work", private=self.t, logs=self.t / "logs", task="k", engine=self.t,
                                       emit=lambda *a, **k: None, begin=lambda *a, **k: None, last_log=None)
        d = self.t / "devcert"; d.mkdir()
        (d / "cert.p12").write_bytes(b"p12")
        (d / "state.json").write_text(json.dumps(dict(active=True, certSha1=SHA1, bundleId="io.s2arm.games.abcde12345", teamId=TEAM, teamName="S2Arm Test Co")))

    def test_windows_signs_then_installs_only(self):
        from test_win_jobs import FakeW
        from jobcase import as_windows
        import layout
        w = FakeW([("U1", "USB", 3)])
        w.team = "FGHIJ67890"   # Impactor 里登的账号：证书模式不该用它算包名
        w.installed = []
        w.install_signed = lambda exe, app, udid, log: w.installed.append((exe, Path(app).name, udid))
        ipa = self.t / "S2Arm.ipa"
        import zipfile
        with zipfile.ZipFile(ipa, "w") as z:
            z.writestr("Payload/S2Arm.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "t", "CFBundleExecutable": "S2Arm"}))
        signed = []
        def fake_sign(c, app, log):
            signed.append(Path(app).name)
            return "io.s2arm.games.abcde12345", {}
        with patch.object(self.m, "win_install_mod", return_value=w), as_windows(self.m), \
             patch.object(devcert, "sign_app", fake_sign), patch.object(self.m.WinPhone, "backup", lambda self, g: None):
            self.c.r["device"] = "U1"   # 装机一律带玩家选的那台（设备号贯穿所有装机入口，不带被拒 device_required）
            ph = self.m.WinPhone(self.c)
            self.assertEqual((ph.bid, ph.bundle_for_signing()), ("io.s2arm.games.abcde12345", "io.s2arm.games.abcde12345"))
            ph.install(ipa, ["0100000000000047"])
        self.assertEqual((signed, w.installed, w.calls), (["S2Arm.app"], [("C:/plumesign.exe", "S2Arm.app", "U1")], []))   # 没走 plumesign 签名
        self.assertEqual(layout.load_device(self.c, "U1")["bundleId"], "io.s2arm.games.abcde12345")
        self.assertTrue((self.t / "lib/S2Arm.signed.ipa").is_file())

    def test_windows_readiness_items(self):
        from test_win_jobs import FakeW
        from jobcase import ios_fixture
        ios_fixture(self.c, "0100000000000047")
        self.c.catalog = lambda: {"schema": 1, "games": []}
        got = dict(blocking=[], warnings=[], allDevices=False, deviceListed=False, teamName="S2Arm Test Co")
        with patch.object(self.m, "win_install_mod", return_value=FakeW([("U1", "USB", 3)], impactor="missing")), \
             patch.object(devcert, "summary", lambda c, udid=None: dict(got, udid=udid)):
            r = self.m.readiness_windows(self.c, "0100000000000047")
        self.assertEqual([(i["id"], i["ok"], i["blocking"]) for i in r["items"]],
                         [("package", True, False), ("connected", True, False), ("devcert", True, False), ("devcertDevice", False, False)])
        self.assertEqual((r["ready"], r["signMode"], r["account"], r["devcert"]["udid"]), (True, "devcert", "S2Arm Test Co", "U1"))

    def test_mac_phone_uses_cert_team(self):
        def no_xcode(*a, **k):
            raise AssertionError("证书模式不该读 Xcode 账号")
        with patch.object(self.m, "xcode_teams", no_xcode), patch.object(self.m, "phone", lambda c: {"id": "D1", "name": "iPhone"}):
            ph = self.m.MacPhone(self.c, udid="U1")
        self.assertEqual((ph.team["id"], ph.bid, ph.info["team"]), (TEAM, "io.s2arm.games.abcde12345", "S2Arm Test Co"))


@unittest.skipUnless(os.environ.get("S2A_RCODESIGN") and Path("/usr/bin/openssl").is_file(), "要 S2A_RCODESIGN 指向 rcodesign、本机有 /usr/bin/openssl")
class RealTools(unittest.TestCase):
    """真 openssl 自造 PBES2 p12 + 自签描述文件 → 规整 → 体检 → 签一个最小 App，核签名里的包名 / 团队号 / 权限"""

    def test_end_to_end(self):
        # 目录名带冒号：rcodesign -e 按第一个冒号拆「作用范围:值」，绝对路径带冒号（Windows 盘符同理）权限会挂错地方、主程序没权限
        t = Path(tempfile.mkdtemp(prefix="dev:cert-")); self.addCleanup(shutil.rmtree, t, True)
        osl = "/usr/bin/openssl"
        env = dict(os.environ, P="test1234")
        subprocess.run([osl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", t / "k.pem", "-out", t / "c.pem", "-days", "365",
                        "-subj", f"/UID={TEAM}/CN=iPhone Distribution: S2Arm Test Co ({TEAM})/OU={TEAM}/O=S2Arm Test Co/C=US"], check=True, capture_output=True)
        der = subprocess.run([osl, "x509", "-in", t / "c.pem", "-outform", "DER"], check=True, capture_output=True).stdout
        subprocess.run([osl, "pkcs12", "-export", "-inkey", t / "k.pem", "-in", t / "c.pem", "-passout", "env:P", "-out", t / "in.p12"], check=True, capture_output=True, env=env)
        raw = profile(certs=(der,), ents={EVA: None})
        plist = raw[raw.find(b"<?xml"):raw.rfind(b"</plist>") + 8]
        (t / "p.plist").write_bytes(plist)
        subprocess.run([osl, "smime", "-sign", "-binary", "-nodetach", "-in", t / "p.plist", "-signer", t / "c.pem", "-inkey", t / "k.pem",
                        "-outform", "DER", "-out", t / "in.mobileprovision"], check=True, capture_output=True)
        app = t / "Payload/S2Arm.app"
        (app / "Frameworks").mkdir(parents=True)
        shutil.copy2(sys.executable if Path(sys.executable).read_bytes()[:4] in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe") else "/bin/ls", app / "S2Arm")
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "io.s2arm.template", "CFBundleExecutable": "S2Arm", "CFBundlePackageType": "APPL"}))
        sec = Secrets()
        log = t / "sign.log"
        # 签名不许依赖网络（#794：rcodesign 缺省向苹果时间戳服务器要时间戳，连不上就整次失败）：代理指到不通的端口，要网就会失败
        offline = dict(os.environ, HTTP_PROXY="http://127.0.0.1:9", HTTPS_PROXY="http://127.0.0.1:9", http_proxy="http://127.0.0.1:9", https_proxy="http://127.0.0.1:9")
        def run(args, logp, cwd=None):
            r = subprocess.run(list(map(str, args)), capture_output=True, text=True, cwd=cwd, env=offline)
            Path(logp).write_text(r.stdout + r.stderr)
            self.assertEqual(r.returncode, 0, r.stderr[-500:])
        c = types.SimpleNamespace(r=dict(action="import", p12Path=str(t / "in.p12"), profilePath=str(t / "in.mobileprovision")), private=t / "private",
                                  engine=t, library=t, devcert_secrets=sec, devcert_password="test1234", begin=lambda *a: None, run=run)
        got = devcert.operation(c)
        self.assertEqual((got["blocking"], got["bundleId"], got["missingEntitlements"]), ([], "io.s2arm.games.abcde12345", [EVA]))
        bid, _ = devcert.sign_app(c, app, log)
        self.assertEqual(bid, "io.s2arm.games.abcde12345")
        info = subprocess.run([os.environ["S2A_RCODESIGN"], "print-signature-info", app / "S2Arm"], capture_output=True, text=True).stdout
        self.assertIn(f"team_name: {TEAM}", info)
        self.assertIn(f"{TEAM}.io.s2arm.games.abcde12345", info)
        self.assertIn(IML, info)
        self.assertNotIn(EVA, info)
        self.assertEqual((app / "embedded.mobileprovision").read_bytes(), (t / "in.mobileprovision").read_bytes())
        out = devcert.export_ipa(c, t / "Payload")
        import zipfile
        self.assertIn("Payload/S2Arm.app/_CodeSignature/CodeResources", zipfile.ZipFile(out).namelist())


class RcodesignEnts(unittest.TestCase):
    """rcodesign_ents：给 rcodesign 传权限文件的唯一口子（D-J7CH：下游装机直接传盘符路径，-e 按第一个冒号拆成「作用范围 C」、os error 3）。
    期望手写：参数只含文件名、不含冒号；运行目录 = 权限文件所在目录"""
    def test_drive_path_passes_name_only(self):
        p = Path("C:") / "Users" / "p" / "downstream.entitlements"   # 带冒号的一段同 Windows 盘符（rcodesign 按第一个冒号拆）
        args, cwd = devcert.rcodesign_ents(p)
        self.assertEqual(args, ["-e", "downstream.entitlements"])
        self.assertEqual(cwd, Path("C:") / "Users" / "p")
        self.assertFalse(any(":" in a for a in args))


if __name__ == "__main__":
    unittest.main()
