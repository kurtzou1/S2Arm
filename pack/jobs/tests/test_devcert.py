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


def profile(appid=f"{TEAM}.*", ents=None, devices=("00000000-000A1B2C3D4E5F60",), all_devices=False, expires=NOW + datetime.timedelta(days=200), certs=(DER,), uuid=None, name="Test Profile"):
    e = {"application-identifier": appid, "com.apple.developer.team-identifier": TEAM, "get-task-allow": True, IML: True, EVA: True,
         "keychain-access-groups": [f"{TEAM}.*"]}
    e.update(ents or {})
    p = {"ApplicationIdentifierPrefix": [TEAM], "TeamIdentifier": [TEAM], "TeamName": "S2Arm Test Co", "Name": name,
         "ExpirationDate": expires.replace(tzinfo=None), "DeveloperCertificates": list(certs), "Entitlements": {k: v for k, v in e.items() if v is not None}}
    if uuid:
        p["UUID"] = uuid
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


@unittest.skipIf(os.name == "nt", "Windows 走 DPAPI，不经 security")
class KeychainLoad(unittest.TestCase):
    """读密码按 security 退出码分开：44 = 没有这一项（要重新导入）；36 = 这个会话读不了（ssh 下钥匙串锁着，重新导入没用）；其他非 0 照实报"""
    def load(self, rc, out=""):
        with patch.object(devcert.subprocess, "run", return_value=types.SimpleNamespace(returncode=rc, stdout=out, stderr="boom")):
            return devcert.Secrets(Path(tempfile.gettempdir())).load(SHA1)

    def test_found(self):
        self.assertEqual(self.load(0, "cHfDpA==\n"), "pwä")   # base64("pwä")，手算

    def test_not_found(self):
        self.assertIsNone(self.load(44))

    def test_locked(self):
        with self.assertRaises(Failure) as e:
            self.load(36)
        self.assertEqual(e.exception.code, "devcert_keychain")
        self.assertIn("图形会话", str(e.exception))
        self.assertNotIn("重新导入", str(e.exception))

    def test_other(self):
        with self.assertRaises(Failure) as e:
            self.load(51)
        self.assertEqual(e.exception.code, "devcert_keychain")
        self.assertIn("退出 51", str(e.exception))


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
        self.assertEqual(sorted(p.name for p in d.iterdir()), [".state.lock", "cert.p12", "entries", "entries.json", "profile.mobileprovision", "state.json"])   # 根下一份给旧版
        self.assertEqual(sorted(p.name for p in (d / "entries" / SHA1).iterdir()), ["cert.p12", "profile.mobileprovision"])
        self.assertNotIn("pw", (d / "state.json").read_text())
        c = self.ctx()
        self.assertTrue(devcert.active(c))
        self.assertEqual(devcert.team(c), dict(id=TEAM, name="S2Arm Test Co", free=False))
        self.assertEqual(devcert.operation(self.ctx(action="use", active=False)), dict(active=False))
        self.assertIsNone(devcert.team(self.ctx()))
        self.assertTrue(devcert.operation(self.ctx(action="status"))["imported"])
        devcert.operation(self.ctx(action="delete"))
        self.assertEqual((sorted(p.name for p in d.iterdir()), self.sec.d), ([".state.lock"], {}))
        self.assertEqual(devcert.operation(self.ctx(action="status")), dict(imported=False, active=False, cert=None, certs=[], chosen=None, current=None, needsChoice=False))

    def test_blocked_import_keeps_previous(self):
        self.imp()
        (self.t / "in.mobileprovision").write_bytes(profile(certs=(b"other",)))
        with self.assertRaises(Failure) as e:
            self.imp(password="new")
        self.assertEqual(e.exception.code, "devcert_mismatch")
        self.assertEqual(self.sec.d, {SHA1: "pw"})   # 旧证书和密码原样留着
        self.assertEqual(devcert.parse_profile((self.t / "private/devcert/entries" / SHA1 / "profile.mobileprovision").read_bytes())["DeveloperCertificates"], [DER])

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


class MultiCert(unittest.TestCase):
    """几张证书一台一张（#487）：add 加一张、不删别的密码；每台按选定的那张签；没选过按现装包名 > 描述文件 > 只有一张挑，挑不出报 devcert_choose；
    同一张 .p12 配每台各自的描述文件 = 几个条目；不带 add 的导入保持旧义「换一个」（Windows 证书页）；旧版单证书就地迁移、根下留一份给旧版"""
    U1, U2, U3 = "00000000-000A1B2C3D4E5F61", "00000000-000A1B2C3D4E5F62", "00000000-000A1B2C3D4E5F63"
    DER2 = b"\x30\x82second-cert-der"
    SHA2 = hashlib.sha1(DER2).hexdigest()
    PA, PB, PC = "aaaaaaaa-0000-0000-0000-000000000001", "bbbbbbbb-0000-0000-0000-000000000002", "cccccccc-0000-0000-0000-000000000003"

    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        (self.t / "lib").mkdir()
        (self.t / "a.p12").write_bytes(b"A"); (self.t / "b.p12").write_bytes(b"B")
        (self.t / "a.mobileprovision").write_bytes(profile(devices=(self.U1,), uuid=self.PA, name="iPhone profile"))
        (self.t / "b.mobileprovision").write_bytes(profile(appid=f"{TEAM}.com.foo.ipad", devices=(self.U2,), certs=(self.DER2,), uuid=self.PB, name="iPad profile"))
        # 同一张证书 A、给 U2 的另一份描述文件（按设备买证书常见：一张 .p12、每台一份描述文件）
        (self.t / "c.mobileprovision").write_bytes(profile(appid=f"{TEAM}.com.foo.second", devices=(self.U2,), uuid=self.PC, name="second profile"))
        self.sec = Secrets()
        shas = {b"A": SHA1, b"B": self.SHA2}
        self.clock = iter(range(10, 99))
        for name, fake in (("normalize_p12", lambda src, dest, pw: Path(dest).write_bytes(Path(src).read_bytes())),
                           ("cert_info", lambda rcs, p12, pw: cert(sha1=shas[Path(p12).read_bytes()])), ("rcodesign_path", lambda c: "rcs")):
            p = patch.object(devcert, name, fake); p.start(); self.addCleanup(p.stop)

    def ctx(self, password=None, **r):
        return types.SimpleNamespace(r=r, private=self.t / "private", library=self.t / "lib", engine=self.t, devcert_secrets=self.sec,
                                     devcert_password=password, begin=lambda *a: None)

    def imp(self, p12, prof, password="pw", **extra):
        # imported 时间戳逐次递增（同档几张取最新导入的）
        with patch.object(devcert, "_now", lambda: (NOW + datetime.timedelta(minutes=next(self.clock))).isoformat()):
            return devcert.operation(self.ctx(password, action="import", p12Path=str(self.t / f"{p12}.p12"), profilePath=str(self.t / f"{prof}.mobileprovision"), **extra))

    def on(self, udid):
        c = self.ctx(); devcert.bind(c, udid); return c

    def installed(self, udid, bid):
        import layout
        layout.save_device(self.ctx(), udid, dict(games={}, bundleId=bid))

    def test_two_certs_each_device_its_own(self):
        self.imp("a", "a", password="pa"); self.imp("b", "b", password="pb", add=True)
        self.assertEqual(self.sec.d, {SHA1: "pa", self.SHA2: "pb"})   # 第二张不顶掉第一张的密码
        self.assertEqual(devcert.state(self.on(self.U1))["bundleId"], "io.s2arm.games.abcde12345")
        self.assertEqual(devcert.state(self.on(self.U2.lower()))["bundleId"], "com.foo.ipad")   # 描述文件只有一张管这台：自动挑它
        self.assertEqual(devcert.stored(self.on(self.U2))[2], "pb")
        with self.assertRaises(Failure) as e:   # 哪张都不管、又有两张：不猜
            devcert.state(self.on(self.U3))
        self.assertEqual(e.exception.code, "devcert_choose")
        with self.assertRaises(Failure) as e:   # 签名时没绑设备、两张：同样不猜
            devcert.stored(self.ctx())
        self.assertEqual(e.exception.code, "devcert_choose")
        self.assertTrue(devcert.active(self.ctx()))
        st = devcert.operation(self.ctx(action="status"))   # 没选设备的出包页：照常显示缺省那张，不报错
        self.assertEqual((st["cert"]["entry"], st["needsChoice"]), (self.PA, False))

    def test_one_p12_two_profiles(self):
        self.imp("a", "a"); self.imp("a", "c", add=True)
        s = devcert.store(self.ctx())
        self.assertEqual(list(s["entries"]), [self.PA, self.PC])
        self.assertEqual((devcert.state(self.on(self.U1))["entry"], devcert.state(self.on(self.U2))["entry"]), (self.PA, self.PC))
        devcert.operation(self.ctx(action="delete", cert=self.PC))
        self.assertEqual(self.sec.d, {SHA1: "pw"})   # 另一条还用这张证书：密码留着

    def test_installed_app_wins_then_newest(self):
        self.imp("a", "a"); self.imp("a", "c", add=True)
        (self.t / "a2.mobileprovision").write_bytes(profile(appid=f"{TEAM}.com.foo.third", devices=(self.U1, self.U2), uuid="dddddddd-0000-0000-0000-000000000004", name="both"))
        self.imp("a", "a2", add=True)
        self.assertEqual(devcert.state(self.on(self.U2))["entry"], "dddddddd-0000-0000-0000-000000000004")   # 两条都管这台：取新导入的（不挡玩家）
        self.installed(self.U2, "com.foo.second")
        self.assertEqual(devcert.state(self.on(self.U2))["entry"], self.PC)   # 这台现装的是 PC 签的 App：用它，不另装一个
        self.assertFalse(devcert.needs_choice(self.ctx(), self.U2))   # 老玩家已在用的那台不问
        self.assertTrue(devcert.needs_choice(self.ctx(), self.U3))

    def test_choice_wins_and_is_remembered(self):
        self.imp("a", "a"); self.imp("b", "b", add=True)
        devcert.operation(self.ctx(action="choose", device=self.U3, cert=self.PB))
        self.assertEqual(devcert.state(self.on(self.U3))["entry"], self.PB)
        devcert.operation(self.ctx(action="choose", device=self.U1, cert=self.PB))   # 玩家明选不管这台的那张：照用（装机前清单另报不在列表）
        self.assertEqual(devcert.state(self.on(self.U1))["entry"], self.PB)
        with self.assertRaises(Failure) as e:
            devcert.operation(self.ctx(action="choose", device=self.U1, cert="nope"))
        self.assertEqual(e.exception.code, "devcert_missing")
        c = self.on(self.U2); devcert.stored(c); devcert.remember(c)   # 自动挑的签好装好了：记下
        self.assertEqual(devcert.store(self.ctx())["devices"], {self.U3: self.PB, self.U1: self.PB, self.U2: self.PB})

    def test_status_asks_once_per_device(self):
        self.imp("a", "a")
        st = devcert.operation(self.ctx(action="status", device=self.U2))
        self.assertEqual((st["needsChoice"], st["chosen"], st["current"]), (False, None, self.PA))   # 只有一张不问：同旧版，就用它
        self.assertEqual([(x["entry"], x["deviceListed"]) for x in st["certs"]], [(self.PA, False)])
        self.imp("a", "c", add=True)   # 出包页「再导入一张」（不带设备）：有两张了，没选过的那台要问
        self.assertTrue(devcert.operation(self.ctx(action="status", device=self.U3))["needsChoice"])
        self.imp("b", "b", device=self.U2, add=True)   # 选证书窗里「导入新证书」：导入即给这台选它
        st = devcert.operation(self.ctx(action="status", device=self.U2))
        self.assertEqual((st["needsChoice"], st["chosen"], st["cert"]["bundleId"]), (False, self.PB, "com.foo.ipad"))
        self.assertEqual({x["entry"]: x["deviceListed"] for x in st["certs"]}, {self.PA: False, self.PC: True, self.PB: True})
        devcert.operation(self.ctx(action="use", active=False))
        self.assertFalse(devcert.operation(self.ctx(action="status", device=self.U3))["needsChoice"])   # Apple ID 签名时不问

    def test_installed_bid_needs_profile_cover(self):
        # 同团队两份通配描述文件（A 管 U1、D 管 U2）算出的包名一样：U1 现装的那个包名不能把 D 挑给 U1（签出来装不上）
        self.imp("a", "a")
        (self.t / "d.mobileprovision").write_bytes(profile(devices=(self.U2,), uuid="dddddddd-0000-0000-0000-000000000004", name="iPad wildcard"))
        self.imp("a", "d", add=True)
        self.installed(self.U1, "io.s2arm.games.abcde12345")
        self.installed(self.U2, "io.s2arm.games.abcde12345")
        self.assertEqual(devcert.state(self.on(self.U1))["entry"], self.PA)
        self.assertEqual(devcert.state(self.on(self.U2))["entry"], "dddddddd-0000-0000-0000-000000000004")
        self.installed(self.U3, "io.s2arm.games.abcde12345")   # 哪份都不管 U3：包名对得上也不算，要问
        self.assertTrue(devcert.needs_choice(self.ctx(), self.U3))

    def test_remember_writes_entry_used_for_signing(self):
        # 签名和记录之间导入了一张更新、也管这台的：记下的仍是签名时用的那张，下次包名不变
        self.imp("a", "a")
        c = self.on(self.U1)
        self.assertEqual(devcert.stored(c)[0].parent.name, self.PA)
        (self.t / "e.mobileprovision").write_bytes(profile(appid=f"{TEAM}.com.foo.newer", devices=(self.U1,), uuid="eeeeeeee-0000-0000-0000-000000000005", name="newer"))
        self.imp("a", "e", add=True)
        self.assertEqual(devcert.state(c)["entry"], self.PA)   # 同一作业里不换
        devcert.remember(c)
        self.assertEqual(devcert.store(self.ctx())["devices"], {self.U1: self.PA})
        c2 = self.ctx(); devcert.remember(c2)   # 没签过名的作业：不记
        self.assertEqual(devcert.store(self.ctx())["devices"], {self.U1: self.PA})

    def test_lock_reentry_is_per_thread(self):
        # 同一作业对象、另一线程：要等主线程放锁，不能当成重入直接进
        import threading
        self.imp("a", "a")
        c, order = self.ctx(), []
        with devcert._locked(c):
            th = threading.Thread(target=lambda: (devcert._locked(c).__enter__(), order.append("thread")))
            th.start(); th.join(0.5)
            order.append("main")
        th.join(5)
        self.assertEqual(order, ["main", "thread"])

    def test_sign_mode_set_with_two_certs(self):
        # 设置里切签名方式（没有设备）：几张证书时不报 devcert_choose，开关经证书库改
        import install
        with self.assertRaises(Failure) as e:
            install.sign_mode_set(self.ctx(mode="devCert"))
        self.assertEqual(e.exception.code, "devcert_missing")
        self.imp("a", "a"); self.imp("b", "b", add=True)
        patch.object(install, "chosen_sign_mode", lambda c: "x").start(); self.addCleanup(patch.stopall)
        install.sign_mode_set(self.ctx(mode="appleId"))
        self.assertFalse(devcert.store(self.ctx())["active"])
        self.assertFalse(json.loads((self.t / "private/devcert/state.json").read_text())["active"])
        install.sign_mode_set(self.ctx(mode="devCert"))
        self.assertTrue(devcert.store(self.ctx())["active"])

    def test_installed_here_marks_current_app(self):
        self.imp("a", "a"); self.imp("b", "b", add=True)
        self.installed(self.U1, "io.s2arm.games.abcde12345")
        self.assertEqual({x["entry"]: x["installedHere"] for x in devcert.listing(self.ctx(), self.U1)}, {self.PA: True, self.PB: False})

    def test_legacy_import_replaces(self):
        # 不带 add（Windows 证书页「换一个证书」、旧前端）：顶掉缺省那张，条目号不变，选过它的设备跟着换；旧证书的密码删掉
        self.imp("a", "a", password="pa")
        devcert.operation(self.ctx(action="choose", device=self.U1, cert=self.PA))
        self.imp("b", "b", password="pb")
        s = devcert.store(self.ctx())
        self.assertEqual((list(s["entries"]), s["entries"][self.PA]["certSha1"], s["devices"], self.sec.d), ([self.PA], self.SHA2, {self.U1: self.PA}, {self.SHA2: "pb"}))

    def test_renewed_profile_keeps_entry(self):
        self.imp("a", "a"); self.imp("b", "b", add=True)
        devcert.operation(self.ctx(action="choose", device=self.U3, cert=self.PA))
        (self.t / "a.mobileprovision").write_bytes(profile(devices=(self.U1, self.U3), uuid="eeeeeeee-0000-0000-0000-000000000005", name="iPhone profile"))   # 续期：新 UUID、同名
        self.imp("a", "a", add=True)
        s = devcert.store(self.ctx())
        self.assertEqual((list(s["entries"]), s["devices"]), ([self.PA, self.PB], {self.U3: self.PA}))
        self.assertTrue(devcert.covers(self.ctx(), self.PA, self.U3))

    def test_delete_one_keeps_other(self):
        self.imp("a", "a"); self.imp("b", "b", add=True)
        devcert.operation(self.ctx(action="choose", device=self.U3, cert=self.PA))
        devcert.operation(self.ctx(action="delete", cert=self.PA))
        s = devcert.store(self.ctx())
        self.assertEqual((list(s["entries"]), s["devices"], self.sec.d), ([self.PB], {}, {self.SHA2: "pw"}))
        self.assertEqual(devcert.state(self.on(self.U3))["entry"], self.PB)   # 只剩一张：同旧版，就用它
        self.assertEqual(json.loads((self.t / "private/devcert/state.json").read_text())["certSha1"], self.SHA2)   # 给旧版的那份跟着换
        devcert.operation(self.ctx(action="delete"))
        self.assertEqual(sorted(p.name for p in (self.t / "private/devcert").iterdir()), [".state.lock"])

    def test_migrates_single_cert(self):
        d = self.t / "private/devcert"; d.mkdir(parents=True)
        (d / "cert.p12").write_bytes(b"A"); (d / "profile.mobileprovision").write_bytes(profile(devices=(self.U1,), uuid=self.PA))
        old = dict(active=True, certSha1=SHA1, bundleId="io.s2arm.games.abcde12345", teamId=TEAM, teamName="S2Arm Test Co", imported="2026-11-10T00:00:00+00:00")
        (d / "state.json").write_text(json.dumps(old))
        self.sec.d[SHA1] = "pw"
        self.installed(self.U2, "io.s2arm.games.abcde12345")   # 用这张装过的另一台（描述文件不管它也一样）：认包名，不问
        s = devcert.store(self.ctx())
        self.assertEqual((list(s["entries"]), s["devices"], s["active"]), ([self.PA], {}, True))
        self.assertFalse(devcert.needs_choice(self.ctx(), self.U2))
        self.assertTrue((d / "cert.p12").is_file())   # 根下那份留给旧版
        self.assertEqual({k: json.loads((d / "state.json").read_text())[k] for k in old if k != "imported"}, {k: v for k, v in old.items() if k != "imported"})
        self.assertEqual(devcert.stored(self.on(self.U1))[2], "pw")
        self.assertEqual(devcert.store(self.ctx()), s)   # 再读不再迁

    def test_windows_style_secrets_replace_and_delete(self):
        # Windows 密码按目录存（<条目>/password.dpapi，删的是整份文件、不分账户）：换证书先删旧的再存新的，不能把刚存的删掉
        class DirSecrets:
            def __init__(self, folder): self.f = Path(folder) / "password.dpapi"
            def save(self, a, p): self.f.parent.mkdir(parents=True, exist_ok=True); self.f.write_text(p)
            def load(self, a): return self.f.read_text() if self.f.is_file() else None
            def delete(self, a): self.f.unlink(missing_ok=True)
        with patch.object(devcert, "secrets", lambda c, eid=None: DirSecrets(devcert.entry_dir(c, eid) if eid else devcert.folder(c))):
            self.imp("a", "a", password="pa")
            self.imp("b", "b", password="pb")   # 旧义换一个
            self.assertEqual(devcert.stored(self.on(self.U2))[2], "pb")
            self.assertEqual(self.imp("a", "a", password="pa", add=True)["entry"], self.PA + "-2")   # PA 号还被换过的那条占着：新条目加后缀
            devcert.operation(self.ctx(action="delete", cert=self.PA + "-2"))
            self.assertEqual(devcert.stored(self.on(self.U2))[2], "pb")
            self.assertEqual((self.t / "private/devcert/password.dpapi").read_text(), "pb")   # 给旧版的那份跟着缺省条目

    def test_schema1_then_write_actions_no_deadlock(self):
        d = self.t / "private/devcert"; d.mkdir(parents=True)
        (d / "cert.p12").write_bytes(b"A"); (d / "profile.mobileprovision").write_bytes(profile(devices=(self.U1,), uuid=self.PA))
        (d / "state.json").write_text(json.dumps(dict(active=True, certSha1=SHA1, bundleId="io.s2arm.games.abcde12345", teamId=TEAM, teamName="S2Arm Test Co")))
        with patch.object(devcert, "LOCK_WAIT_S", 0.2):   # 自己等自己 = 卡到超时报错
            devcert.operation(self.ctx(action="use", active=True))
            devcert.operation(self.ctx(action="choose", device=self.U1, cert=self.PA))
            self.imp("b", "b", add=True)
        self.assertEqual(list(devcert.store(self.ctx())["entries"]), [self.PA, self.PB])

    def test_status_does_not_claim_legacy_record(self):
        import layout
        self.imp("a", "a")
        layout.save_device(self.ctx(), "legacy", dict(games={"0100000000000047": {}}, bundleId="io.s2arm.games.abcde12345"))
        devcert.operation(self.ctx(action="status", device=self.U2))
        devcert.listing(self.ctx(), self.U2); devcert.needs_choice(self.ctx(), self.U2)
        self.assertTrue(layout.device_path(self.ctx(), "legacy").is_file())
        self.assertFalse(layout.device_path(self.ctx(), self.U2).is_file())

    def test_same_name_other_device_is_new_entry(self):
        (self.t / "a.mobileprovision").write_bytes(profile(devices=(self.U1,), uuid=self.PA, name="iOS Team Provisioning Profile"))
        (self.t / "c.mobileprovision").write_bytes(profile(devices=(self.U2,), uuid=self.PC, name="iOS Team Provisioning Profile"))
        self.imp("a", "a"); self.imp("a", "c", add=True)
        self.assertEqual(list(devcert.store(self.ctx())["entries"]), [self.PA, self.PC])

    def test_same_cert_new_password_both_entries_sign(self):
        self.imp("a", "a", password="old"); self.imp("a", "c", password="new", add=True)
        for u in (self.U1, self.U2):
            self.assertEqual(devcert.stored(self.on(u))[2], "new")
        self.assertEqual((devcert.entry_dir(self.ctx(), self.PA) / "cert.p12").read_bytes(), (devcert.entry_dir(self.ctx(), self.PC) / "cert.p12").read_bytes())

    def test_old_launcher_import_keeps_entries(self):
        self.imp("a", "a"); self.imp("b", "b", add=True)
        devcert.operation(self.ctx(action="choose", device=self.U3, cert=self.PB))
        d = self.t / "private/devcert"   # 降级后旧版「换一个证书」：只改根下那份
        (d / "cert.p12").write_bytes(b"A"); (d / "profile.mobileprovision").write_bytes(profile(devices=(self.U3,), uuid="ffffffff-0000-0000-0000-000000000006", name="third"))
        (d / "state.json").write_text(json.dumps(dict(active=True, certSha1=SHA1, bundleId="io.s2arm.games.abcde12345", teamId=TEAM, teamName="S2Arm Test Co")))
        s = devcert.store(self.ctx())
        self.assertEqual((list(s["entries"]), s["devices"]), ([self.PA, self.PB, "ffffffff-0000-0000-0000-000000000006"], {self.U3: self.PB}))

    def test_legacy_replace_for_unassigned_device_adds(self):
        self.imp("a", "a"); self.imp("b", "b", add=True)
        (self.t / "c.mobileprovision").write_bytes(profile(appid=f"{TEAM}.com.foo.u3", devices=(self.U3,), uuid=self.PC, name="u3"))
        self.imp("a", "c", device=self.U3)   # Mac 行上「换一个证书…」、选中的是还没选过的 U3：加一张给它，不顶掉 U1 / U2 的
        s = devcert.store(self.ctx())
        self.assertEqual((list(s["entries"]), s["devices"]), ([self.PA, self.PB, self.PC], {self.U3: self.PC}))

    def test_remember_never_raises(self):
        self.imp("a", "a")
        with patch.object(devcert, "_locked", side_effect=Failure("busy")):
            devcert.remember(self.on(self.U1))   # 不抛


    def test_mac_phone_binds_before_team(self):
        # 装机：先认设备、再按这台挑证书读团队 / 包名（#487 B2）；App 装好才记下这台的选择，装失败不记
        import install
        self.imp("a", "a"); self.imp("b", "b", add=True)
        def no_xcode(*a, **k):
            raise AssertionError("证书模式不该读 Xcode 账号")
        c = self.ctx(); c.env = lambda: {}
        with patch.object(install, "xcode_teams", no_xcode), patch.object(install, "phone", lambda c: {"id": "D", "name": "iPad"}):
            ph = install.MacPhone(c, udid=self.U2)
            self.assertEqual(ph.bid, "com.foo.ipad")
            with patch.object(install, "sign_and_install", side_effect=Failure("x", code="device_install_failed")), self.assertRaises(Failure):
                ph.install("ipa", [])
            self.assertEqual(devcert.store(self.ctx())["devices"], {})
            with patch.object(install, "sign_and_install", lambda *a, **k: None):
                ph.install("ipa", [])
            self.assertEqual(devcert.store(self.ctx())["devices"], {self.U2: self.PB})
            self.assertEqual(install.MacPhone(c, udid=self.U1).bid, "io.s2arm.games.abcde12345")   # 同一作业换一台：重新绑

    def test_readiness_items_two_certs(self):
        import install
        self.imp("a", "a"); self.imp("b", "b", add=True)
        items = []
        item = lambda i, ok, title, why="", **k: items.append((i, bool(ok), why))
        with patch.object(devcert, "summary", lambda c, udid=None: dict(blocking=[], warnings=[], allDevices=False, deviceListed=True)):
            install.devcert_items(self.ctx(), item, "")             # 没选设备：照常显示缺省那张，不报错
            install.devcert_items(self.ctx(), item, self.U3)        # 这台还没选：只说「先选一张」
        self.assertEqual(items, [("devcert", True, ""), ("devcert", False, devcert.CHOOSE)])


class StateUnreadable(unittest.TestCase):
    """D-BW75（Windows 0.6.2，×14）：devcert\\state.json 读时拒绝访问（WinError 5、连属性都取不到），原先抛到 update_phone、整单装机失败。
    期望手写：读不了 = 当作没启用证书——state() 回 {}、active() False、team() None；作业日志记一行黄字、结果页一条黄色诊断，同一作业只各记一次"""
    def test_denied_counts_as_not_active(self):
        import io, contextlib
        t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, t, True)
        diags = []
        c = types.SimpleNamespace(private=t / "private", diagnostic=lambda msg, **k: diags.append((msg, k.get("code"), k.get("severity"))))
        denied = PermissionError(13, "拒绝访问。（属性 取不到 5；权限 取不到 5）")
        err = io.StringIO()
        with patch.object(devcert, "read", side_effect=denied), contextlib.redirect_stderr(err):
            got = (devcert.state(c), devcert.active(c), devcert.team(c))
        self.assertEqual(got, ({}, False, None))
        lines = [l for l in err.getvalue().splitlines() if "开发者证书设置读不了" in l]
        self.assertEqual(len(lines), 1, err.getvalue())
        # 不悄悄换签法：结果页一条黄字（码 devcert_unreadable、warning），说清这次没读到证书设置、改按 Apple ID 签名
        self.assertEqual([(d[1], d[2]) for d in diags], [("devcert_unreadable", "warning")])
        self.assertIn("按 Apple ID 签名", diags[0][0])


class AdoptP12Only(unittest.TestCase):
    """#2015：只选了 .p12（免费 Apple ID 没有描述文件，例如 SideStore 导出的证书）→ 交给 Apple ID 签名沿用这张证书（devcert.adopt）。
    不动开发者证书的存档、不切签名方式；没登录 / 工具不认 / 证书不在账号里 / 列不出 → 失败说清下一步，私钥交接一次都不发生。"""
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        (self.t / "in.p12").write_bytes(b"p12")
        self.handed = []
        for name, fake in (("normalize_p12", lambda src, dest, pw: Path(dest).write_bytes(Path(src).read_bytes())),
                           ("_read_p12", lambda c, p12, pw: (b"PKCS1-KEY", b"CERT"))):
            q = patch.object(devcert, name, fake); q.start(); self.addCleanup(q.stop)
        import install
        self.homes = []
        for name, fake in (("plume_home", lambda c: self.homes.append(1)), ("win_install_mod", lambda c: self.W),
                           ("plumesign_exe", lambda c, W: "plumesign")):
            q = patch.object(install, name, fake); q.start(); self.addCleanup(q.stop)
        self.team, self.mark, self.result = TEAM, True, dict(name="Apple Development: x", machine="SideStore - iPhone", created="2025-11-01")
        self.W = types.SimpleNamespace(impactor=types.SimpleNamespace(selected_team=lambda: self.team), keycert=lambda exe: self.mark,
                                       adopt_key=lambda exe, team, key, log=None: self.handed.append((exe, team, key)) or self.result)

    def run_import(self):
        c = types.SimpleNamespace(r=dict(action="import", p12Path=str(self.t / "in.p12"), profilePath=""), private=self.t / "private", engine=self.t,
                                  devcert_secrets=Secrets(), devcert_password="", begin=lambda *a: None, logs=self.t, task="t1")
        return devcert.operation(c), c

    def test_adopts_and_leaves_devcert_store_alone(self):
        r, c = self.run_import()
        self.assertEqual(self.handed, [("plumesign", TEAM, b"PKCS1-KEY")])
        self.assertEqual((r["adopted"], r["team"], r["machine"]), (True, TEAM, "SideStore - iPhone"))
        self.assertIn("不会撤销 SideStore / AltStore 正在用的证书", r["message"])
        self.assertFalse(devcert.active(c))   # 签名方式没被切到开发者证书
        self.assertEqual(self.homes, [] if os.name == "nt" else [1])   # Mac 先定 plumesign 数据目录

    def failure(self):
        with self.assertRaises(Failure) as e:
            self.run_import()
        return e.exception

    def test_not_signed_in(self):
        self.team = None
        e = self.failure()
        self.assertEqual((e.code, self.handed), ("apple_not_signed_in", []))
        self.assertIn("先用 Apple ID 登录再导入", str(e)); self.assertIn("描述文件（.mobileprovision）", str(e))

    def test_upstream_tool_refused(self):
        self.mark = False
        e = self.failure()
        self.assertEqual((e.code, self.handed), ("devcert_invalid", []))
        self.assertIn("还不能沿用导入的证书", str(e))

    def test_not_in_account(self):
        self.result = "absent"
        e = self.failure()
        self.assertEqual(e.code, "devcert_invalid")
        self.assertIn(f"团队 {TEAM}", str(e))

    def test_unlisted(self):
        self.result = None
        self.assertIn("这次什么都没改", str(self.failure()))

    def test_both_files_still_import_devcert(self):
        # 两个都选了：照旧导入成开发者证书签名，不走 Apple ID 交接
        (self.t / "in.mobileprovision").write_bytes(profile())
        with patch.object(devcert, "cert_info", lambda rcs, p12, pw: cert()), patch.object(devcert, "rcodesign_path", lambda c: "rcs"):
            c = types.SimpleNamespace(r=dict(action="import", p12Path=str(self.t / "in.p12"), profilePath=str(self.t / "in.mobileprovision")),
                                      private=self.t / "private", engine=self.t, devcert_secrets=Secrets(), devcert_password="pw", begin=lambda *a: None)
            self.assertTrue(devcert.operation(c)["active"])
        self.assertEqual(self.handed, [])


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
