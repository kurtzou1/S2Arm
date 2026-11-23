# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Windows Apple ID 签名前的证书核对（pack/orch/install_win.py cert_check + pack/jobs/install.py win_cert_gate）：
plumesign 要新建开发证书、账号证书又满了时，会不问就撤掉苹果列表里的第一张。判据只用确定的事实：
  列表里有本机私钥（<APPDATA>/PlumeImpactor/keys/<团队>/key.pem）、机器名 AltStore 的证书 → 不新建，不问（原版 plumesign 两样都对上才认）；
  自编补丁 0006 的 plumesign（--version 带 +s2a-keycert）只比公钥：机器名是别的（SideStore 建的）也不问；
  没有本机的、列表里也没有别人的（空）→ 不问；
  没有本机的、有别人的 → 问，点名列表第一张（名字 / 机器名 / 生效日期）；
  列不出来（plumesign 失败）→ 不问，照原来签。
证书与私钥按 DER 规则手工拼（模数是随手写的大整数，不是真密钥），plumesign 的输出按同版 v2.7.2 的 Rust Debug 形式手写；团队号、名字全是假的。
期望由拼进去的值直接得出，不跑被测实现推。"""
import base64
import sys
import tempfile
import types
import unittest
from pathlib import Path

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))
sys.path.insert(0, str(JOBS.parent / "orch"))
import install  # noqa: E402
import install_win  # noqa: E402
from core import Failure  # noqa: E402

TEAM = "TEAM-FAKE"
MOD_MINE = int("C3" + "5A" * 255, 16)     # 2048 位、最高位为 1（编码时要补 0x00）
MOD_XCODE = int("B1" + "27" * 255, 16)
MOD_OTHER = int("9D" + "E4" * 255, 16)


def tlv(tag, body):
    n = len(body)
    head = bytes([n]) if n < 0x80 else bytes([0x80 | ((n.bit_length() + 7) // 8)]) + n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([tag]) + head + body


def integer(v):
    raw = v.to_bytes((v.bit_length() + 7) // 8 or 1, "big")
    return tlv(0x02, (b"\x00" + raw) if raw[0] & 0x80 else raw)


def seq(*items):
    return tlv(0x30, b"".join(items))


RSA_ALG = seq(tlv(0x06, bytes.fromhex("2a864886f70d010101")), tlv(0x05, b""))


def cert_der(modulus, not_before, generalized=False):
    """最小的 X.509 证书：TBS = [0]版本, 序列号, 算法, 签发者, 有效期, 主体, 公钥信息"""
    t = tlv(0x18 if generalized else 0x17, not_before.encode())
    spki = seq(RSA_ALG, tlv(0x03, b"\x00" + seq(integer(modulus), integer(65537))))
    name = seq(tlv(0x31, seq(tlv(0x06, b"\x55\x04\x03"), tlv(0x0C, b"Fake"))))
    tbs = seq(tlv(0xA0, integer(2)), integer(4242), RSA_ALG, name, seq(t, t), name, spki)
    return seq(tbs, RSA_ALG, tlv(0x03, b"\x00" + b"\x11" * 8))


def key_pem(modulus):
    rsa = seq(integer(0), integer(modulus), integer(65537), integer(3), integer(5), integer(7), integer(11), integer(13), integer(17))
    der = seq(integer(0), RSA_ALG, tlv(0x04, rsa))
    b = base64.b64encode(der).decode()
    return "-----BEGIN PRIVATE KEY-----\n" + "\n".join(b[i:i + 64] for i in range(0, len(b), 64)) + "\n-----END PRIVATE KEY-----\n"


def block(name, machine, der):
    nums = ",\n".join(f"                {x}" for x in der)
    mach = f'Some(\n            "{machine}",\n        )' if machine is not None else "None"
    return (f'    Cert {{\n        name: "{name}",\n        certificate_id: "FAKEID",\n        serial_number: "0F0F",\n        status: "Issued",\n'
            f'        cert_content: Some(\n            [\n{nums},\n            ],\n        ),\n        machine_id: None,\n        machine_name: {mach},\n    }},\n')


def listing(*certs):
    return "[\n" + "".join(block(*c) for c in certs) + "]\n"


UPSTREAM = "plumesign 2.7.3"
KEYCERT = "plumesign 2.7.3+s2a-keycert"


class Run:
    """plumesign 的替身：account certificates 给定输出 / 退出码，--version 给定版本行（缺省上游原版）；记下列证书的命令"""
    def __init__(self, out, rc=0, version=UPSTREAM):
        self.out, self.rc, self.version, self.calls = out, rc, version, []

    def __call__(self, cmd, **kw):
        if cmd[1:] == ["--version"]:
            return types.SimpleNamespace(returncode=0, stdout=self.version + "\n", stderr="")
        self.calls.append(cmd)
        return types.SimpleNamespace(returncode=self.rc, stdout=self.out, stderr="")


class CertCheck(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.appdata = Path(self.tmp.name)

    def mine(self, modulus=MOD_MINE):
        k = self.appdata / "PlumeImpactor/keys" / TEAM / "key.pem"
        k.parent.mkdir(parents=True); k.write_text(key_pem(modulus), encoding="utf-8")

    def check(self, out, rc=0, version=UPSTREAM):
        run = Run(out, rc, version)
        got = install_win.cert_check("plumesign.exe", TEAM, appdata=self.appdata, log=self.appdata / "certs.log", run=run)
        self.assertEqual(run.calls, [["plumesign.exe", "account", "certificates", "--team", TEAM]])
        return got

    def test_parse_reads_modulus_and_date(self):
        self.assertEqual(install_win.cert_modulus_and_start(cert_der(MOD_XCODE, "250301120000Z")), (MOD_XCODE, "2025-03-01"))
        self.assertEqual(install_win.cert_modulus_and_start(cert_der(MOD_XCODE, "20260102000000Z", generalized=True)), (MOD_XCODE, "2026-01-02"))
        self.assertEqual(install_win.key_modulus(key_pem(MOD_MINE)), MOD_MINE)
        self.assertEqual(install_win.cert_modulus_and_start(b"\x30\x03\x02\x01\x00"), (None, ""))

    def test_mine_listed_no_ask(self):
        # 本机私钥的证书在列表里（不是第一张）→ plumesign 直接用它，不新建、不撤
        self.mine()
        self.assertIsNone(self.check(listing(("Apple Development: Fake Xcode", "Fake-Mac", cert_der(MOD_XCODE, "250301120000Z")),
                                             ("Apple Development: Fake S2Arm", "AltStore", cert_der(MOD_MINE, "251101000000Z")))))

    def test_mine_key_other_machine_name_asks(self):
        # 公钥是本机的、机器名却不是 AltStore：plumesign 认不出（要名字和公钥都对上），照样新建 → 要问
        self.mine()
        got = self.check(listing(("Apple Development: Fake Xcode", "Fake-Mac", cert_der(MOD_XCODE, "250301120000Z")),
                                 ("Apple Development: Fake S2Arm", "Fake-PC", cert_der(MOD_MINE, "251101000000Z"))))
        self.assertEqual(got, dict(name="Apple Development: Fake Xcode", machine="Fake-Mac", created="2025-03-01"))

    def test_keycert_build_reuses_other_machine_name(self):
        # 补丁 0006 的 plumesign：公钥是本机的、机器名是 SideStore 建的 → 它复用这张，不新建、不问（#2015）
        self.mine()
        self.assertIsNone(self.check(listing(("Apple Development: Fake Xcode", "Fake-Mac", cert_der(MOD_XCODE, "250301120000Z")),
                                             ("Apple Development: Fake SideStore", "SideStore - iPhone", cert_der(MOD_MINE, "251101000000Z"))),
                                     version=KEYCERT))

    def test_keycert_build_still_asks_without_my_key(self):
        # 补丁版也只认本机私钥的：列表里全是别人的 → 照样问
        self.mine()
        got = self.check(listing(("Apple Development: Fake Xcode", "SideStore - iPhone", cert_der(MOD_XCODE, "250301120000Z"))), version=KEYCERT)
        self.assertEqual(got, dict(name="Apple Development: Fake Xcode", machine="SideStore - iPhone", created="2025-03-01"))

    def test_others_listed_asks_first_one(self):
        # 本机私钥的证书不在、有别人的 → 问，点名列表第一张（满了撤的就是它）
        self.mine()
        got = self.check(listing(("Apple Development: Fake Xcode", "Fake-Mac", cert_der(MOD_XCODE, "250301120000Z")),
                                 ("Apple Development: Fake Other", None, cert_der(MOD_OTHER, "250401000000Z"))))
        self.assertEqual(got, dict(name="Apple Development: Fake Xcode", machine="Fake-Mac", created="2025-03-01"))

    def test_no_local_key_others_listed_asks(self):
        # 这台电脑没有私钥（第一次用这个账号）、列表里有别人的 → 问
        got = self.check(listing(("Apple Development: Fake Other", "Fake-PC", cert_der(MOD_OTHER, "20240505000000Z", generalized=True))))
        self.assertEqual(got, dict(name="Apple Development: Fake Other", machine="Fake-PC", created="2024-05-05"))

    def test_empty_list_no_ask(self):
        self.mine()
        self.assertIsNone(self.check("[]\n"))

    def test_listing_fails_no_ask(self):
        # 列不出来（会话过期 / 没联网）→ 判不了就不加阻碍，照原来签
        self.mine()
        self.assertIsNone(self.check("Error: session expired\n", rc=1))
        self.assertIn("session expired", (self.appdata / "certs.log").read_text(encoding="utf-8"))

    def test_log_folds_cert_bytes(self):
        self.mine()
        self.check(listing(("Apple Development: Fake Xcode", "Fake-Mac", cert_der(MOD_XCODE, "250301120000Z"))))
        log = (self.appdata / "certs.log").read_text(encoding="utf-8")
        self.assertIn("Fake Xcode", log); self.assertIn("[…]", log); self.assertNotIn(" 48,\n", log)


class KeyCert(unittest.TestCase):
    """补丁 0006 标记、私钥格式转换、导入私钥（adopt_key）、手机自签身份（plume_identity）按同一口径认证书"""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.appdata = Path(self.tmp.name)
        self.key = self.appdata / "PlumeImpactor/keys" / TEAM / "key.pem"

    def test_keycert_mark(self):
        self.assertTrue(install_win.keycert("p", run=Run("", version=KEYCERT)))
        self.assertFalse(install_win.keycert("p", run=Run("", version=UPSTREAM)))
        def gone(cmd, **kw): raise OSError("no such file")
        self.assertFalse(install_win.keycert("p", run=gone))

    def test_pkcs8_round_trip(self):
        # PKCS#1 → PKCS#8 PEM：模数不变，再取回的 PKCS#1 逐字节相同（plumesign 读的是 PKCS#8）
        pkcs1 = install_win.pkcs1_der(key_pem(MOD_MINE))
        pem = install_win.pkcs8_pem(pkcs1)
        self.assertTrue(pem.startswith("-----BEGIN PRIVATE KEY-----\n") and pem.endswith("-----END PRIVATE KEY-----\n"))
        self.assertEqual(install_win.key_modulus(pem), MOD_MINE)
        self.assertEqual(install_win.pkcs1_der(pem), pkcs1)
        self.assertEqual(pem, key_pem(MOD_MINE))   # 与手拼的 PKCS#8 逐字相同

    def adopt(self, out, rc=0, now=None):
        return install_win.adopt_key("p", TEAM, install_win.pkcs1_der(key_pem(MOD_MINE)), appdata=self.appdata, run=Run(out, rc, KEYCERT), now=now)

    def test_adopt_listed_writes_key_and_keeps_old(self):
        self.key.parent.mkdir(parents=True); self.key.write_text(key_pem(MOD_OTHER), encoding="utf-8")
        got = self.adopt(listing(("Apple Development: Fake Xcode", "Fake-Mac", cert_der(MOD_XCODE, "250301120000Z")),
                                 ("Apple Development: Fake SideStore", "SideStore - iPhone", cert_der(MOD_MINE, "251101000000Z"))), now=1795000000)
        self.assertEqual(got, dict(name="Apple Development: Fake SideStore", machine="SideStore - iPhone", created="2025-11-01"))
        self.assertEqual(self.key.read_text(encoding="utf-8"), key_pem(MOD_MINE))
        bak = [p for p in self.key.parent.iterdir() if p.name.startswith("key.pem.bak-")]
        self.assertEqual([p.read_text(encoding="utf-8") for p in bak], [key_pem(MOD_OTHER)])   # 原来那把留着
        self.assertEqual(sorted(p.name for p in self.key.parent.iterdir() if p.name.endswith(".part")), [])

    def test_adopt_same_key_no_backup(self):
        self.key.parent.mkdir(parents=True); self.key.write_text(key_pem(MOD_MINE), encoding="utf-8")
        self.assertIsNotNone(self.adopt(listing(("S", "SideStore", cert_der(MOD_MINE, "251101000000Z")))))
        self.assertEqual(sorted(p.name for p in self.key.parent.iterdir()), ["key.pem"])

    def test_adopt_absent_or_unlisted_changes_nothing(self):
        self.assertEqual(self.adopt(listing(("Other", "SideStore", cert_der(MOD_OTHER, "251101000000Z")))), "absent")
        self.assertIsNone(self.adopt("Error: session expired\n", rc=1))
        self.assertFalse(self.key.exists())

    def test_identity_follows_build(self):
        # 手机自签身份：补丁版认 SideStore 建的那张，原版认不出（与 plumesign 自己选的证书一致）
        self.key.parent.mkdir(parents=True); self.key.write_text(key_pem(MOD_MINE), encoding="utf-8")
        out = listing(("Apple Development: Fake SideStore", "SideStore - iPhone", cert_der(MOD_MINE, "251101000000Z")))
        got = install_win.plume_identity("p", TEAM, appdata=self.appdata, run=Run(out, version=KEYCERT))
        self.assertEqual((got["cert"], got["created"]), (cert_der(MOD_MINE, "251101000000Z"), "2025-11-01"))
        self.assertIsNone(install_win.plume_identity("p", TEAM, appdata=self.appdata, run=Run(out, version=UPSTREAM)))


class Gate(unittest.TestCase):
    """作业层：要问时抛 cert_revoke_confirm（文案照实点名），玩家点继续（acceptCertRevoke）就不再核"""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)

    def ctx(self, **r):
        return types.SimpleNamespace(r=r, logs=Path(self.tmp.name), task="t1")

    def W(self, hit, team=TEAM):
        calls = []
        def cert_check(exe, t, log=None):
            calls.append((exe, t)); return hit
        return types.SimpleNamespace(impactor=types.SimpleNamespace(selected_team=lambda: team), cert_check=cert_check), calls

    def gate(self, c, W, exe="plumesign.exe"):
        orig = install.devcert.active
        install.devcert.active = lambda c: False
        try:
            install.win_cert_gate(c, W, exe)
        finally:
            install.devcert.active = orig

    def test_ask_names_the_certificate(self):
        W, calls = self.W(dict(name="Apple Development: Fake Xcode", machine="Fake-Mac", created="2025-03-01"))
        with self.assertRaises(Failure) as e:
            self.gate(self.ctx(), W)
        self.assertEqual(e.exception.code, "cert_revoke_confirm")
        self.assertIn("第一张「Apple Development: Fake Xcode」（在 Fake-Mac 上创建，2025-03-01 生效）。", str(e.exception))
        self.assertIn("在 AltStore / SideStore 上创建的那张就是它们在用的证书", str(e.exception))   # 11-19 Duo 实测撤的就是点名的这张（在 AltStore 上创建）；不再说「可能」
        self.assertNotIn("没满就什么都不撤", str(e.exception))
        self.assertEqual(calls, [("plumesign.exe", TEAM)])

    def test_ask_without_machine_name(self):
        # 苹果列表里这张没记机器名：换不带「在 … 上创建」的那句，不出现「?」
        W, _ = self.W(dict(name="Apple Development: Fake Other", machine="", created="2024-05-05"))
        with self.assertRaises(Failure) as e:
            self.gate(self.ctx(), W)
        self.assertIn("第一张「Apple Development: Fake Other」（2024-05-05 生效）。", str(e.exception))
        self.assertNotIn("?", str(e.exception)); self.assertNotIn("（在 ", str(e.exception))

    def test_accepted_skips(self):
        W, calls = self.W(dict(name="X", machine="M", created="2025-03-01"))
        self.gate(self.ctx(acceptCertRevoke=True), W)
        self.assertEqual(calls, [])

    def test_no_ask_passes(self):
        W, calls = self.W(None)
        self.gate(self.ctx(), W)
        self.assertEqual(len(calls), 1)

    def test_no_team_skips(self):
        W, calls = self.W(dict(name="X", machine="M", created="2025-03-01"), team=None)
        self.gate(self.ctx(), W)
        self.assertEqual(calls, [])

    def test_recovery_text_exists(self):
        self.assertIn("仍然继续", install.recovery("cert_revoke_confirm", packaged=True))


if __name__ == "__main__":
    unittest.main()
