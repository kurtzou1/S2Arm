# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""0.6.0 通用壳：手机自签要的私钥 + 证书交给 App（pack/orch/install_win.py plume_identity / pkcs1_der，pack/jobs/install.py deliver_identity）。
私钥与证书按 DER 规则手工拼（模数是随手写的大整数，不是真密钥），plumesign 列证书的输出按同版 v2.7.2 的 Rust Debug 形式手写，团队号、名字都是假的。
期望由拼进去的值直接得出，不跑被测实现推。"""
import hashlib
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))
sys.path.insert(0, str(JOBS.parent / "orch"))
import install  # noqa: E402
import install_win  # noqa: E402
from test_win_cert_gate import MOD_MINE, MOD_XCODE, Run, cert_der, integer, key_pem, listing, seq  # noqa: E402

TEAM = "TEAM-FAKE"


def rsa_der(modulus):   # 与 test_win_cert_gate.key_pem 包进 PKCS#8 的那份 RSAPrivateKey 逐字节相同
    return seq(integer(0), integer(modulus), integer(65537), integer(3), integer(5), integer(7), integer(11), integer(13), integer(17))


class PlumeIdentity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.appdata = Path(self.tmp.name)

    def mine(self):
        k = self.appdata / "PlumeImpactor/keys" / TEAM / "key.pem"
        k.parent.mkdir(parents=True); k.write_text(key_pem(MOD_MINE), encoding="utf-8")
        return k.read_text(encoding="utf-8")

    def test_pkcs1_from_pkcs8_and_pkcs1(self):
        self.assertEqual(install_win.pkcs1_der(key_pem(MOD_MINE)), rsa_der(MOD_MINE))
        import base64
        b = base64.b64encode(rsa_der(MOD_MINE)).decode()
        self.assertEqual(install_win.pkcs1_der("-----BEGIN RSA PRIVATE KEY-----\n" + b + "\n-----END RSA PRIVATE KEY-----\n"), rsa_der(MOD_MINE))
        self.assertIsNone(install_win.pkcs1_der("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"))

    def test_picks_our_certificate(self):
        pem = self.mine()
        ours = cert_der(MOD_MINE, "251101000000Z")
        run = Run(listing(("Apple Development: Fake Xcode", "Fake-Mac", cert_der(MOD_XCODE, "250301120000Z")),
                          ("Apple Development: Fake S2Arm", "AltStore", ours)))
        got = install_win.plume_identity("plumesign.exe", TEAM, appdata=self.appdata, run=run)
        self.assertEqual(got, dict(key=rsa_der(MOD_MINE), cert=ours, created="2025-11-01", key_fp=hashlib.sha256(pem.encode()).hexdigest()[:16]))
        self.assertEqual(install_win.key_fingerprint(TEAM, appdata=self.appdata), got["key_fp"])

    def test_no_identity_when_not_reusable(self):
        # 公钥对、机器名不是 AltStore（plumesign 认不出，会新建）/ 列表里没有 / 列不出 / 本机没私钥：都不交
        self.mine()
        for out, rc in ((listing(("Apple Development: Fake S2Arm", "Fake-PC", cert_der(MOD_MINE, "251101000000Z"))), 0),
                        (listing(("Apple Development: Fake Xcode", "Fake-Mac", cert_der(MOD_XCODE, "250301120000Z"))), 0),
                        ("Error: session expired\n", 1)):
            self.assertIsNone(install_win.plume_identity("plumesign.exe", TEAM, appdata=self.appdata, run=Run(out, rc)))
        run = Run("[]\n")
        self.assertIsNone(install_win.plume_identity("plumesign.exe", "TEAM-NOKEY", appdata=self.appdata, run=run))
        self.assertEqual(run.calls, [], "没私钥不联网列证书")


class FakeClient:
    def __init__(self, fail_put=False):
        self.ops, self.files, self.fail_put = [], {}, fail_put

    def put(self, src, rel):
        if self.fail_put:
            raise RuntimeError("资源包写进 iPhone 时中断")
        self.ops.append(("put", rel)); self.files[rel] = Path(src).read_bytes()

    def mv(self, src, dst):
        self.ops.append(("mv", src, dst)); self.files[dst] = self.files.pop(src); return True, ""

    def get(self, rel, dst):   # 手机上的文件：按 files 里有的回给调用方
        self.ops.append(("get", rel))
        if rel not in self.files:
            return False
        Path(dst).write_bytes(self.files[rel]); return True


class DeliverIdentity(unittest.TestCase):
    """作业层：第一次交三份（identity.json 最后改名就位、不含私钥）、记下私钥指纹；指纹没变不联网不重交；交不出 / 推不进不挡推送"""
    IDENT = dict(key=b"\x30\x01PRIVATE", cert=b"\x30\x02CERT", created="2025-11-01", key_fp="fp1")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.store = {}
        self.c = types.SimpleNamespace(r={}, logs=Path(self.tmp.name), private=self.tmp.name, task="t1")

    def phone(self, fp="fp1", ident=IDENT, client=None):
        calls = []
        def plume_identity(exe, team, log=None):
            calls.append((exe, team)); return ident
        W = types.SimpleNamespace(impactor=types.SimpleNamespace(selected_team=lambda: TEAM, bundled=lambda r: {"plumesign": "p.exe"}),
                                  plumesign_path=lambda given=None: "C:/plumesign.exe", key_fingerprint=lambda team: fp, plume_identity=plume_identity)
        cl = client or FakeClient()
        return types.SimpleNamespace(W=W, key="UDID1", client=lambda w: cl), calls, cl

    def deliver(self, ph, devcert=False, shell=True):
        import program_pack
        with patch.object(install.layout, "load_device", lambda c, k: dict(self.store.get(k, {}))), \
                patch.object(install.layout, "save_device", lambda c, k, rec: self.store.__setitem__(k, rec)), \
                patch.object(install.devcert, "active", lambda c: devcert), patch.object(install, "trace", lambda *a, **k: None):
            return install.deliver_identity(self.c, ph)

    def test_first_delivery_three_files_metadata_last(self):
        ph, calls, cl = self.phone()
        sha1 = hashlib.sha1(self.IDENT["cert"]).hexdigest()
        self.assertEqual(self.deliver(ph), sha1)
        base = install.IDENTITY_INCOMING
        self.assertEqual(base, "Library/Application Support/S2Arm/identity/incoming")
        self.assertEqual(cl.ops, [("put", f"{base}/key.der"), ("put", f"{base}/cert.der"), ("put", f"{base}/identity.json.pc.tmp"),
                                  ("mv", f"{base}/identity.json.pc.tmp", f"{base}/identity.json")])
        self.assertEqual(cl.files[f"{base}/key.der"], self.IDENT["key"])
        meta = json.loads(cl.files[f"{base}/identity.json"])
        self.assertEqual(meta, dict(schema=1, team=TEAM, cert_sha1=sha1, created="2025-11-01", source="appleId"))
        self.assertNotIn(b"PRIVATE", cl.files[f"{base}/identity.json"], "清单里不带私钥")
        rec = self.store["UDID1"]["identity"]
        self.assertEqual((rec["team"], rec["key_fp"], rec["cert_sha1"]), (TEAM, "fp1", sha1))
        self.assertEqual(calls, [("C:/plumesign.exe", TEAM)])

    def test_same_key_pending_import_not_redelivered_no_network(self):
        # 交过、App 还没导入（incoming 清单还在）：不联网、不重交，只读了一下手机上的清单
        ph, calls, cl = self.phone()
        self.deliver(ph)
        ph2, calls2, _ = self.phone(client=cl)
        n = len(cl.ops)
        self.assertIsNone(self.deliver(ph2))
        self.assertEqual(calls2, [])
        self.assertTrue(all(op[0] == "get" for op in cl.ops[n:]), cl.ops[n:])

    def test_imported_by_app_not_redelivered(self):
        # App 已导入：incoming 删了、写了 current.json（同一张证书）→ 不联网、不重交
        ph, calls, cl = self.phone()
        sha1 = self.deliver(ph)
        cl.files = {install.IDENTITY_CURRENT: json.dumps(dict(team=TEAM, cert_sha1=sha1)).encode()}
        ph2, calls2, _ = self.phone(client=cl)
        n = len(cl.ops)
        self.assertIsNone(self.deliver(ph2))
        self.assertEqual(calls2, []); self.assertFalse(any(op[0] == "put" for op in cl.ops[n:]))

    def test_phone_has_neither_delivered_again(self):
        # 手机上两样都没有（App 删了重装、数据容器换新）：同一把私钥也重交
        ph, calls, cl = self.phone()
        self.deliver(ph)
        cl.files = {}
        ph2, calls2, _ = self.phone(client=cl)
        n = len(cl.ops)
        self.assertIsNotNone(self.deliver(ph2))
        self.assertEqual(calls2, [("C:/plumesign.exe", TEAM)])
        self.assertEqual([op[0] for op in cl.ops[n:]].count("put"), 3)

    def test_new_key_delivered_again(self):
        self.deliver(self.phone()[0])
        ph, calls, cl = self.phone(fp="fp2", ident=dict(self.IDENT, key_fp="fp2"))
        self.assertIsNotNone(self.deliver(ph))
        self.assertEqual(len(cl.ops), 4)
        self.assertEqual(self.store["UDID1"]["identity"]["key_fp"], "fp2")

    def test_nothing_to_deliver_or_push_failure_does_not_raise(self):
        ph, calls, cl = self.phone(ident=None)
        self.assertIsNone(self.deliver(ph)); self.assertEqual(cl.ops, []); self.assertNotIn("UDID1", self.store)
        ph, calls, cl = self.phone(client=FakeClient(fail_put=True))
        self.assertIsNone(self.deliver(ph)); self.assertNotIn("UDID1", self.store)

    def test_modes_that_cannot_deliver(self):
        ph, calls, cl = self.phone()
        self.assertIsNone(self.deliver(types.SimpleNamespace(key="UDID1")))   # Mac Apple ID（借 Xcode 钥匙串）：手机对象没有 W，交不了
        self.assertEqual((calls, cl.ops), ([], []))   # 证书签名用户两端都交：见 test_devcert_identity


if __name__ == "__main__":
    unittest.main()


class IdentityTarget(unittest.TestCase):
    """11-19：交签名身份不只认启动器装的 App——AltStore / SideStore / ESign 装的 S2Arm 包名被改过，按手机上实际装着、团队对得上的那个交（期望手写）"""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.c = types.SimpleNamespace(r={}, private=self.tmp.name, library=Path(self.tmp.name))
        self.ph = types.SimpleNamespace(udid="UDID1", key="UDID1", bid="io.s2arm.games.team1")

    def target(self, rows, team="TEAM1"):
        cl = types.SimpleNamespace(apps=lambda: rows)
        with patch.object(install, "devpush_client", lambda c, udid, bid, w: cl), patch.object(install, "main_executable", lambda c: "S2Arm"):
            return install.identity_target(self.c, self.ph, team)

    def test_altstore_renamed_bundle_same_team(self):
        rows = [("com.example.other", "Other", "TEAM1"), ("io.s2arm.games.team1.TEAM1", "S2Arm", "TEAM1")]
        self.assertEqual(self.target(rows), "io.s2arm.games.team1.TEAM1", "启动器的包名没装：交给 AltStore 改过名的那个")

    def test_own_bundle_preferred_and_by_executable(self):
        rows = [("io.s2arm.games.team1", "S2Arm", "TEAM1"), ("io.s2arm.games.team1.TEAM1", "S2Arm", "TEAM1")]
        self.assertEqual(self.target(rows), "io.s2arm.games.team1", "两份都在：启动器装的优先")
        self.assertEqual(self.target([("com.esign.renamed", "S2Arm", "TEAM1")]), "com.esign.renamed", "包名全改了：按主程序名认")

    def test_team_unknown_still_delivers(self):
        self.assertEqual(self.target([("io.s2arm.games.x", "S2Arm", "")]), "io.s2arm.games.x", "读不到团队号：照交，手机侧核团队")

    def test_other_team_reports_which(self):
        with self.assertRaises(install.Failure) as e:
            self.target([("io.s2arm.games.team9.TEAM9", "S2Arm", "TEAM9")])
        self.assertEqual(e.exception.code, "identity_team_mismatch")
        self.assertIn("团队 TEAM9", str(e.exception)); self.assertIn("团队 TEAM1", str(e.exception))

    def test_none_installed_and_cannot_list(self):
        with self.assertRaises(install.Failure) as e:
            self.target([("com.example.other", "Other", "TEAM1")])
        self.assertEqual(e.exception.code, "shell_install_required")
        self.assertEqual(self.target(None), "io.s2arm.games.team1", "列不出（工具旧 / 断开）：照旧用启动器的包名")


class DevpushApps(unittest.TestCase):
    def test_parse_rows(self):
        sys.path.insert(0, str(JOBS.parents[1] / "tools"))
        import push_pack as P
        d = P.Devpush("x", "U", "-", tempfile.mkdtemp())
        with patch.object(d, "call", lambda *a: (0, "a.b\tA\tT1\nio.s2arm.games.t\tS2Arm\t\n\n")):
            self.assertEqual(d.apps(), [("a.b", "A", "T1"), ("io.s2arm.games.t", "S2Arm", "")])
        with patch.object(d, "call", lambda *a: (1, "不认识的操作 apps")):
            self.assertIsNone(d.apps(), "工具太旧：None，调用方照旧用启动器的包名")


class FreeAccountGuide(unittest.TestCase):
    """11-19 实测：AltServer 新建证书会顶掉 AltStore 正在用的那张。交签名身份时这台电脑上没有可交的证书：不新建，引导在 AltStore / SideStore 导出证书、
    在手机 S2Arm 里导入；只有玩家自己点「安装 S2Arm」才新建（期望手写）"""
    def test_no_identity_guides_to_export_never_creates(self):
        c = types.SimpleNamespace(r={}, logs=Path(tempfile.mkdtemp()), private=tempfile.mkdtemp(), task="t1")
        created = []
        W = types.SimpleNamespace(impactor=types.SimpleNamespace(selected_team=lambda: TEAM, bundled=lambda r: {}), plumesign_path=lambda given=None: "p",
                                  key_fingerprint=lambda team: None, plume_identity=lambda *a, **k: created.append(a))
        ph = types.SimpleNamespace(W=W, key="UDID1", client=lambda w: self.fail("不该碰手机"))
        with patch.object(install.devcert, "active", lambda c: False):
            with self.assertRaises(install.Failure) as e:
                install.deliver_identity(c, ph, strict=True)
            self.assertIsNone(install.deliver_identity(c, ph), "推游戏顺带交：没有就跳过、不报错")
        self.assertEqual(e.exception.code, "identity_unavailable")
        for want in ("导出签名证书", "不会为此新建", "安装 S2Arm"):
            self.assertIn(want, str(e.exception))
        self.assertEqual(created, [], "没调过取身份，更没新建")
