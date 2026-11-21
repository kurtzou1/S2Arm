# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""0.6.0 通用壳：证书签名用户把证书交给 App（pack/jobs/devcert.py identity、pack/jobs/install.py deliver_identity / phone_identity / install_shell）。
p12 是本测试现场用 openssl 生成的一次性自签证书（假名字），期望值（PKCS#1 私钥 DER、证书 DER）由 openssl 另行导出，不跑被测实现推。"""
import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))
sys.path.insert(0, str(JOBS.parent / "orch"))
import devcert  # noqa: E402
import install  # noqa: E402
import install_win  # noqa: E402
import program_pack  # noqa: E402
from core import Failure  # noqa: E402
from test_identity_delivery import FakeClient  # noqa: E402

OSSL = "/usr/bin/openssl"
PW = "test-pw"


def ossl(*args, **k):
    return subprocess.run([OSSL, *args], check=True, capture_output=True, **k).stdout


@unittest.skipUnless(os.name != "nt" and Path(OSSL).is_file(), "要系统 openssl（Mac / Linux 那条读法）")
class ReadP12(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        self.c = types.SimpleNamespace(engine=self.t / "no-engine")
        key, crt = self.t / "k.pem", self.t / "c.pem"
        ossl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(crt), "-days", "1", "-subj", "/CN=Fake S2Arm Test")
        self.p12 = self.t / "cert.p12"
        ossl("pkcs12", "-export", "-inkey", str(key), "-in", str(crt), "-passout", f"pass:{PW}", "-out", str(self.p12))
        self.want_key = ossl("rsa", "-in", str(key), "-outform", "DER")          # PKCS#1 RSAPrivateKey（LibreSSL / OpenSSL rsa 缺省）
        self.want_cert = ossl("x509", "-in", str(crt), "-outform", "DER")
        assert self.want_key[:1] == b"\x30"

    def test_key_and_cert_match_openssl(self):
        key, cert = devcert._read_p12(self.c, self.p12, PW)
        self.assertEqual((key, cert), (self.want_key, self.want_cert))

    def test_chain_in_p12_picks_signing_cert(self):
        # 钥匙串导出的 p12 常带中间证书：取有私钥的那张（签名用的），不取链上的
        ca = self.t / "ca.pem"
        ossl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(self.t / "cak.pem"), "-out", str(ca), "-days", "1", "-subj", "/CN=Fake Intermediate")
        p12 = self.t / "chain.p12"
        ossl("pkcs12", "-export", "-inkey", str(self.t / "k.pem"), "-in", str(self.t / "c.pem"), "-certfile", str(ca), "-passout", f"pass:{PW}", "-out", str(p12))
        self.assertEqual(devcert._read_p12(self.c, p12, PW), (self.want_key, self.want_cert))

    def test_wrong_password(self):
        with self.assertRaises(Failure) as e:
            devcert._read_p12(self.c, self.p12, "wrong")
        self.assertEqual(e.exception.code, "devcert_invalid")

    def test_windows_params_rebuild_same_pkcs1(self):
        # Windows 那条：.NET RSAParameters（大端无符号、无前导零）→ PKCS#1；字段从 openssl 导出的 DER 里取，拼回来应逐字节相同
        der = self.want_key
        _, s, e = install_win._tlv(der, 0)
        ints = [der[a:b] for _, a, b in install_win._children(der, s, e)][1:]
        params = {k: base64.b64encode(v.lstrip(b"\0")).decode() for k, v in zip(("Modulus", "Exponent", "D", "P", "Q", "DP", "DQ", "InverseQ"), ints)}
        self.assertEqual(devcert._pkcs1_from_params(params), der)

    def test_identity_checks_key_matches_cert(self):
        st = dict(active=True, certSha1="x", teamId="TEAM-CERT")
        d = self.t / "devcert"; d.mkdir(); shutil.copy(self.p12, d / "cert.p12"); (d / "profile.mobileprovision").write_bytes(b"p")
        # 多张证书（#487）后 identity 经 stored(c) 取本作业那张（p12、描述文件、密码），按入口替身，不按旧版单张的目录布局
        with patch.object(devcert, "active", lambda c: st["active"]), patch.object(devcert, "team", lambda c: dict(id=st["teamId"])), \
                patch.object(devcert, "stored", lambda c, eid=None: (d / "cert.p12", b"p", PW)):
            got = devcert.identity(self.c)
            self.assertEqual((got["key"], got["cert"], got["team"]), (self.want_key, self.want_cert, "TEAM-CERT"))
            self.assertEqual(got["key_fp"], hashlib.sha256(self.p12.read_bytes()).hexdigest()[:16])
            other = self.t / "o.pem"
            ossl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(self.t / "ok.pem"), "-out", str(other), "-days", "1", "-subj", "/CN=Other")
            with patch.object(devcert, "_read_p12", lambda c, p, pw: (self.want_key, ossl("x509", "-in", str(other), "-outform", "DER"))):
                with self.assertRaises(Failure) as e:
                    devcert.identity(self.c)
            self.assertEqual(e.exception.code, "devcert_invalid")
            st["active"] = False
            self.assertIsNone(devcert.identity(self.c))


class DevcertDelivery(unittest.TestCase):
    """作业层：证书签名用户两端都交（Mac 手机对象也行）；单独作业 strict：交不了报真原因、交过了 delivered False、force 重交"""
    IDENT = dict(key=b"\x30\x01PRIVATE", cert=b"\x30\x02CERT", created="2026-01-01", team="TEAM-CERT")

    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        (self.t / "cert.p12").write_bytes(b"p12-bytes")
        self.store = {}
        self.c = types.SimpleNamespace(r={}, logs=self.t, private=str(self.t), task="t1")

    def run_deliver(self, ph, active=True, ident=IDENT, **k):
        with patch.object(install.layout, "load_device", lambda c, key: dict(self.store.get(key, {}))), \
                patch.object(install.layout, "save_device", lambda c, key, rec: self.store.__setitem__(key, rec)), \
                patch.object(install.devcert, "active", lambda c: active), patch.object(install.devcert, "team", lambda c: {"id": "TEAM-CERT"}), \
                patch.object(install.devcert, "stored", lambda c, eid=None: (self.t / "cert.p12", b"", "pw")), \
                patch.object(install.devcert, "identity", lambda c: ident), \
                patch.object(install, "trace", lambda *a, **kw: None):
            return install.deliver_identity(self.c, ph, **k)

    def mac_phone(self, cl=None):
        cl = cl or FakeClient()
        return types.SimpleNamespace(key="UDID1", client=lambda w: cl), cl

    def test_mac_phone_devcert_delivered(self):
        ph, cl = self.mac_phone()
        sha1 = hashlib.sha1(self.IDENT["cert"]).hexdigest()
        self.assertEqual(self.run_deliver(ph), sha1)
        meta = json.loads(cl.files[f"{install.IDENTITY_INCOMING}/identity.json"])
        self.assertEqual(meta, dict(schema=1, team="TEAM-CERT", cert_sha1=sha1, created="2026-01-01", source="devCert"))
        self.assertEqual(cl.files[f"{install.IDENTITY_INCOMING}/key.der"], self.IDENT["key"])
        self.assertEqual(self.store["UDID1"]["identity"]["key_fp"], hashlib.sha256(b"p12-bytes").hexdigest()[:16])

    def test_strict_already_force_and_reimport(self):
        ph, cl = self.mac_phone()
        r = self.run_deliver(ph, strict=True)
        self.assertEqual((r["delivered"], r["source"], r["team"]), (True, "devCert", "TEAM-CERT"))
        n = len(cl.ops)
        r = self.run_deliver(ph, strict=True)
        self.assertEqual(r["delivered"], False, "同一张证书手机上还等着导入：不重交")
        self.assertFalse(any(op[0] == "put" for op in cl.ops[n:]))
        self.assertTrue(self.run_deliver(ph, strict=True, force=True)["delivered"], "force 照样重交")
        (self.t / "cert.p12").write_bytes(b"new-p12")   # 玩家重新导入了证书：指纹变了，重交
        self.assertTrue(self.run_deliver(ph, strict=True)["delivered"])

    def test_strict_reports_real_reason(self):
        ph, cl = self.mac_phone()
        for kw, code in ((dict(active=False), "devcert_missing"), (dict(ident=None), "job_failed")):
            with self.assertRaises(Failure) as e:
                self.run_deliver(ph, strict=True, **kw)
            self.assertEqual(e.exception.code, code)
        ph, _ = self.mac_phone(FakeClient(fail_put=True))
        with self.assertRaises(Failure) as e:
            self.run_deliver(ph, strict=True)
        self.assertEqual(e.exception.code, "job_failed")
        self.assertIsNone(self.run_deliver(ph), "顺带交（不 strict）推不进不挡")
        self.assertNotIn("UDID1", self.store)
        def bad(c):
            raise Failure("读不出", code="devcert_invalid")
        ph, _ = self.mac_phone()
        with patch.object(install.layout, "load_device", lambda c, key: {}), \
                patch.object(install.devcert, "active", lambda c: True), patch.object(install.devcert, "team", lambda c: {"id": "TEAM-CERT"}), \
                patch.object(install.devcert, "stored", lambda c, eid=None: (self.t / "cert.p12", b"", "pw")), patch.object(install.devcert, "identity", bad), \
                patch.object(install, "trace", lambda *a, **kw: None):
            with self.assertRaises(Failure) as e:
                install.deliver_identity(self.c, ph, strict=True)
            self.assertEqual(e.exception.code, "devcert_invalid", "证书读不出：单独作业原样报这个原因")
            self.assertIsNone(install.deliver_identity(self.c, ph), "顺带交：读不出不挡装机")

    def test_install_shell_delivers_identity(self):
        import ipa as packer
        seen = []
        ph = types.SimpleNamespace(key="UDID1", bid="io.example.app", info={"device": "d"}, install=lambda ipa, g, steps=False: seen.append("install"))
        with patch.object(install, "deliver_identity", lambda c, p: seen.append("deliver")), patch.object(packer, "assemble_shell", lambda c: ("x.ipa", [], "S1")), \
                patch.object(packer, "commit_phone_ipa", lambda *a: None), \
                patch.object(install.layout, "load_device", lambda c, k: {}), patch.object(install.layout, "save_device", lambda *a: None), \
                patch.object(install.layout, "phone_ipa", lambda c: self.t / "S2Arm.ipa"), patch.object(install, "note", lambda *a: None), \
                patch.object(install, "signer_kind", lambda c, p: "devCert"):
            install.install_shell(self.c, ph, steps=False)
        self.assertEqual(seen, ["install", "deliver"])

if __name__ == "__main__":
    unittest.main()
