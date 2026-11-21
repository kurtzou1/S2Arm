# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""0.6.0 通用壳 Mac 的 Apple ID（方案 A，pack/jobs/apple_login.py + install.mac_plume / PlumeMacPhone / signerSwitched）。
plumesign 用一个 Python 小脚本替身：照同版 v2.7.2 account.rs login 的交互（stdin 读密码 → 提示「Enter 2FA code:」→ stdin 读验证码 → 写账号存档 →
「Successfully logged in」），把自己收到的命令行与环境记进文件，测试据此核「密码只走标准输入」。账号、团队号、密码都是假的；期望由写进去的值直接得出。"""
import json
import os
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch

JOBS = Path(__file__).resolve().parents[1]
ROOT = JOBS.parents[1]
sys.path.insert(0, str(JOBS))
sys.path.insert(0, str(JOBS / "tests"))
import apple_login  # noqa: E402
import install  # noqa: E402
import jobcase  # noqa: E402
from core import Failure  # noqa: E402

PASSWORD = "Pw-Unit-7f3a9c"   # 测试密码：不许出现在日志、作业记录、子进程参数 / 环境里
ACCOUNT = "player@example.com"
TEAM = "FAKE" + "TEAMAB"   # 拆开写：公开仓扫描把「TEAM = 十位字母数字」当真团队号

FAKE = textwrap.dedent('''\
    import json, os, sys
    rec = os.environ["FAKE_PLUME_RECORD"]
    json.dump(dict(argv=sys.argv[1:], env=dict(os.environ)), open(rec, "w"))
    mode = os.environ.get("FAKE_PLUME_MODE", "ok")
    if sys.argv[1:3] != ["account", "login"]:
        sys.exit(2)
    sys.stdout.write("Enter password: "); sys.stdout.flush()
    pw = sys.stdin.readline().strip()
    open(rec + ".stdin", "w").write(pw + "\\n")
    if mode == "echo":
        print("Enter password: " + pw)   # 回显密码（终端交互登录时 plumesign 会显示）：作业层要抹掉
        print("Error: Authentication failed: -20101 Your Apple ID or password was entered incorrectly."); sys.exit(1)
    if mode == "badpw":
        print("Error: Authentication failed: -20101 Your Apple ID or password was entered incorrectly."); sys.exit(1)
    if mode == "badpw22406":   # D-W2VH：plumesign 实际原句
        print("Error: Authentication SRP error -22406: Enter the correct password for this Apple Account."); sys.exit(1)
    print("Logging in...")
    if mode in ("sms", "smsmany", "smsloop"):   # 设备方式、账号有受信任手机号（同版 account.rs tfa_closure 原句）
        print("[INFO plumesign::commands::account] Enter the code sent to your device, or type 'sms' to receive it by text message: ", flush=True)
    else:
        print("[INFO plumesign::commands::account] Enter 2FA code: ", flush=True)
    code = sys.stdin.readline().strip()
    open(rec + ".stdin", "a").write(code + "\\n")
    if code == "sms" and mode == "smsmany":   # 多个受信任手机号：dialoguer 选号菜单在管道里起不来
        print("Error: Authentication SRP error 0: Failed to get 2FA code: IO error: not a terminal"); sys.exit(1)
    if code == "sms":
        print("[INFO plumesign::commands::account] Enter the code sent via SMS: ", flush=True)
        code = sys.stdin.readline().strip()
        open(rec + ".stdin", "a").write(code + "\\n")
    if mode == "badcode":
        print("Error: -21669 Incorrect verification code"); sys.exit(1)
    if mode == "smsloop":   # 上游的循环：码被接受、重登又要短信，永远要下去
        for _ in range(20):
            print("[INFO plumesign::commands::account] Enter the code sent via SMS: ", flush=True)
            code = sys.stdin.readline().strip()
            if not code: sys.exit(1)
            open(rec + ".stdin", "a").write(code + "\\n")
    if mode == "repeat":   # 打了补丁 0002 的 plumesign：重登又要码就自己停
        print("Error: Authentication SRP error -2: S2A_2FA_REPEAT: Apple accepted the verification code but asked for another one on the next sign-in"); sys.exit(1)
    home = os.path.join(os.environ["XDG_CONFIG_HOME"], "PlumeImpactor"); os.makedirs(home, exist_ok=True)
    user = sys.argv[sys.argv.index("-u") + 1]
    json.dump(dict(selected_account=user, accounts={user: dict(email=user, first_name="Tester", adsid="x", xcode_gs_token="y", team_id=os.environ["FAKE_PLUME_TEAM"])}),
              open(os.path.join(home, "accounts.json"), "w"))
    print("[INFO plumesign::commands::account] Successfully logged in and account saved.")
''')


@unittest.skipIf(os.name == "nt", "Mac 通用壳专用")
class AppleLogin(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp(prefix="s2arm-login ")); self.addCleanup(__import__("shutil").rmtree, self.t, True)
        fake = self.t / "plumesign"
        fake.write_text(f"#!{sys.executable}\n" + FAKE, encoding="utf-8"); fake.chmod(0o755)
        self.rec = self.t / "record.json"
        env = patch.dict(os.environ, {"S2A_UNIVERSAL_SHELL": "1", "S2A_PLUMESIGN": str(fake), "FAKE_PLUME_RECORD": str(self.rec), "FAKE_PLUME_TEAM": TEAM})
        env.start(); self.addCleanup(env.stop)
        os.environ.pop("S2A_PLUME_HOME", None)
        (self.t / "logs").mkdir(); (self.t / "private").mkdir()
        self.keys = []
        self.c = jobcase.fake_context(self.t, r=dict(account=ACCOUNT), engine=ROOT, task="login1", apple_password=PASSWORD)
        self.c.begin = lambda stage, number=1, count=1, key=None, keychain=False: self.keys.append(key)

    def code(self, digits="123456"):
        d = self.t / "private/login"; d.mkdir(parents=True, exist_ok=True)
        (d / "login1.code").write_text(digits, encoding="utf-8")   # 界面填好的验证码（作业问到时读、读完删）

    def test_login_password_only_on_stdin(self):
        self.code()
        got = apple_login.login(self.c)
        self.assertEqual(got, dict(account=ACCOUNT, team=TEAM, teamName="Tester", enabled=True))
        self.assertEqual(self.keys, ["appleLogin", "appleLogin.needCode", "appleLogin"])
        self.assertIn(("progress", ""), self.c.events)
        seen = json.loads(self.rec.read_text())
        self.assertEqual(seen["argv"], ["account", "login", "-u", ACCOUNT])
        self.assertEqual(Path(str(self.rec) + ".stdin").read_text(), PASSWORD + "\n123456\n")   # 密码与验证码都从标准输入进
        self.assertEqual(seen["env"]["XDG_CONFIG_HOME"], str(self.t / "private/plumesign"))   # 账号存档落私有目录
        self.assertNotIn(PASSWORD, json.dumps(seen["env"]))
        self.assertNotIn(PASSWORD, json.dumps(self.c.r))
        for f in self.t.rglob("*"):
            if f.is_file() and not f.name.endswith(".stdin"):
                self.assertNotIn(PASSWORD, f.read_text(encoding="utf-8", errors="replace"), f)
        self.assertFalse((self.t / "private/login/login1.code").exists())   # 验证码读完即删
        self.assertIsNone(self.c.apple_password)
        self.assertEqual(apple_login.account(self.c), dict(account=ACCOUNT, team=TEAM, teamName="Tester", enabled=True))

    def answer(self, replies):
        """界面替身：每收到一次 needCode 事件，按顺序往验证码文件写下一句（记下事件带的 canSms / sms）"""
        self.prompts = []
        def emit(kind="progress", message="", *a, **k):
            self.c.events.append((kind, message))
            if kind == "progress" and "canSms" in k:
                self.prompts.append((k["canSms"], k["sms"]))
                self.code(replies[len(self.prompts) - 1])
        self.c.emit = emit

    def test_sms_switch(self):
        # 设备方式能改短信 → 界面写 sms → plumesign 改发短信、再要码 → 写短信里的码 → 登录成功
        with patch.dict(os.environ, {"FAKE_PLUME_MODE": "sms"}):
            self.answer(["sms", "654321"])
            got = apple_login.login(self.c)
        self.assertEqual(got["account"], ACCOUNT)
        self.assertEqual(self.prompts, [(True, False), (False, True)])
        self.assertEqual(Path(str(self.rec) + ".stdin").read_text(), PASSWORD + "\nsms\n654321\n")
        self.assertEqual(self.keys, ["appleLogin", "appleLogin.needCode", "appleLogin", "appleLogin.needCode", "appleLogin"])

    def test_code_accepted_then_asked_again_stops(self):
        # 兜底：交过一次码后同一次登录又要码 → 不再弹给界面、不再往 plumesign 送码，报定句（玩家「输入验证码后无限循环」）
        with patch.dict(os.environ, {"FAKE_PLUME_MODE": "smsloop"}):
            self.answer(["sms", "654321", "111111", "222222"])
            with self.assertRaises(Failure) as e:
                apple_login.login(self.c)
        self.assertEqual((e.exception.code, str(e.exception)), ("login_identity_rejected", apple_login.SAY_2FA_REPEAT))
        self.assertEqual(self.prompts, [(True, False), (False, True)])   # 只问了改短信 + 一次短信码
        self.assertEqual(Path(str(self.rec) + ".stdin").read_text(), PASSWORD + "\nsms\n654321\n")

    def test_patched_plumesign_repeat_marker(self):
        # plumesign 自己停下（补丁 0002 的 S2A_2FA_REPEAT）→ 同一句定句
        with patch.dict(os.environ, {"FAKE_PLUME_MODE": "repeat"}):
            self.answer(["123456"])
            with self.assertRaises(Failure) as e:
                apple_login.login(self.c)
        self.assertEqual((e.exception.code, str(e.exception)), ("login_identity_rejected", apple_login.SAY_2FA_REPEAT))
        self.assertIn("S2A_2FA_REPEAT", e.exception.internal)

    def test_sms_many_numbers_fails_readably(self):
        # 受信任手机号不止一个：plumesign 要终端选号、在管道里退出 → 定句失败，不卡住
        with patch.dict(os.environ, {"FAKE_PLUME_MODE": "smsmany"}):
            self.answer(["sms"])
            with self.assertRaises(Failure) as e:
                apple_login.login(self.c)
        self.assertEqual(e.exception.code, "two_factor_wrong")
        self.assertEqual(str(e.exception), apple_login.SAY_SMS_PICK)
        self.assertIn("not a terminal", e.exception.internal)

    def test_sms_not_offered_is_ignored(self):
        # 提示里没有 type 'sms'（没有受信任手机号）：界面写的 sms 不转给 plumesign，读到即删、接着等真验证码
        class Proc:
            def poll(self): return None
        f = self.t / "private/login/login1.code"
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text("sms", encoding="utf-8")
        with patch.object(apple_login, "CODE_WAIT", 1):
            self.assertIsNone(apple_login._wait_code(self.c, Proc()))
        self.assertFalse(f.exists())
        f.write_text("sms", encoding="utf-8")
        self.assertEqual(apple_login._wait_code(self.c, Proc(), allow_sms=True), "sms")
        f.write_text("12345", encoding="utf-8")
        with patch.object(apple_login, "CODE_WAIT", 1):
            self.assertIsNone(apple_login._wait_code(self.c, Proc(), allow_sms=True), "不是 6 位数字不收")

    def test_wrong_password_and_code(self):
        for mode, want in (("badpw", "apple_id_wrong"), ("badpw22406", "apple_id_wrong"), ("badcode", "two_factor_wrong")):   # badpw22406：D-W2VH 的 -22406 原句
            with self.subTest(mode=mode), patch.dict(os.environ, {"FAKE_PLUME_MODE": mode}):
                self.c.apple_password = PASSWORD; self.code()
                with self.assertRaises(Failure) as e:
                    apple_login.login(self.c)
                self.assertEqual(e.exception.code, want)
                self.assertNotIn(PASSWORD, str(e.exception) + e.exception.internal)

    def test_echoed_password_scrubbed(self):
        with patch.dict(os.environ, {"FAKE_PLUME_MODE": "echo"}):
            with self.assertRaises(Failure) as e:
                apple_login.login(self.c)
        self.assertEqual(e.exception.code, "apple_id_wrong")
        log = (self.t / "logs/login1-login.log").read_text(encoding="utf-8")
        self.assertIn("Enter password: ***", log)
        self.assertNotIn(PASSWORD, log + str(e.exception) + e.exception.internal)

    def test_not_signed_in(self):
        self.assertEqual(apple_login.account(self.c), dict(account=None, team=None, teamName="", enabled=True))
        with patch.object(install, "phone", lambda c: dict(id="dev", name="iPhone")), patch.object(install, "udid_of", lambda c, d: "UDID-1"):
            with self.assertRaises(Failure) as e:
                install.phone_for(self.c)
        self.assertEqual(e.exception.code, "apple_not_signed_in")


class PlumeMacPhoneBorrowsWinInstall(unittest.TestCase):
    """PlumeMacPhone 借 WinPhone.install 签名装机：install 里用到的 self 成员它都得有（11-18 真机：没借 say，Mac 免费账号装 App 一调就 AttributeError）。
    期望由源码直接得出：WinPhone.install 里出现的每个 self.<名字>，PlumeMacPhone 的类成员或两个 __init__ 里赋值的实例属性都有"""

    def test_members_used_by_install_exist(self):
        import ast
        import inspect
        def self_attrs(fn, assigned=False):
            tree = ast.parse(textwrap.dedent(inspect.getsource(fn)))
            return {n.attr for n in ast.walk(tree) if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name) and n.value.id == "self"
                    and (not assigned or isinstance(n.ctx, ast.Store))}
        used = self_attrs(install.WinPhone.install)
        have = set(dir(install.PlumeMacPhone)) | self_attrs(install.MacPhone.__init__, True) | self_attrs(install.PlumeMacPhone.__init__, True)
        self.assertTrue(used, "WinPhone.install 里应当用到 self 成员")
        self.assertEqual(sorted(used - have), [], "PlumeMacPhone 缺这些 WinPhone.install 用到的成员")


class SignerSwitched(unittest.TestCase):
    """换签名方式后第一次装才带 signerSwitched：老记录没 signer 字段时按当时只有的签法推"""

    def test_last_signer(self):
        self.assertIsNone(install.last_signer({}))
        self.assertEqual(install.last_signer(dict(signer="plumesign", bundleId="b")), "plumesign")
        self.assertEqual(install.last_signer(dict(bundleId="b", signed=dict(mode="devCert"))), "devCert")
        self.assertEqual(install.last_signer(dict(bundleId="b", signed=dict(mode="appleId"))), "plumesign" if os.name == "nt" else "xcode")


@unittest.skipIf(os.name == "nt", "Mac 打包")
class BundlePlumesign(unittest.TestCase):
    def test_hash_pinned(self):
        # 随包的是自编修改版：缓存有就用，没有从固定来源下；下不来 / 哈希不符拒打并说清地址；补丁原文与「修改版」说明随包
        sys.path.insert(0, str(ROOT / "launchers/macos"))
        import build_app
        import impactor
        import hashlib
        t = Path(tempfile.mkdtemp()); self.addCleanup(__import__("shutil").rmtree, t, True)
        def down(url, to): raise OSError("连不上")
        with self.assertRaises(SystemExit) as e:
            build_app.bundle_plumesign(t / "res0", cache=t / "empty", fetch=down)
        self.assertIn(impactor.OWN_RELEASE + "plumesign-macos-universal", str(e.exception)); self.assertIn("连不上", str(e.exception))
        (t / "cache").mkdir(); (t / "cache/plumesign-macos-universal").write_bytes(b"not it")
        with patch.object(impactor, "BUNDLED_MAC", {"plumesign-macos-universal": "00" * 32}):
            with self.assertRaises(SystemExit) as e:
                build_app.bundle_plumesign(t / "res", cache=t / "cache", fetch=lambda url, to: Path(to).write_bytes(b"still not"))
            self.assertIn("拒打", str(e.exception))
        body = b"fake plumesign"
        (t / "cache/plumesign-macos-universal").write_bytes(body)
        with patch.object(impactor, "BUNDLED_MAC", {"plumesign-macos-universal": hashlib.sha256(body).hexdigest()}):
            build_app.bundle_plumesign(t / "res2", cache=t / "cache", fetch=lambda url, to: self.fail("缓存里有且哈希对就不下"))
        d = t / "res2" / impactor.BUNDLE_DIR
        out = d / "plumesign-macos-universal"
        self.assertEqual(out.read_bytes(), body)
        self.assertTrue(os.access(out, os.X_OK))
        self.assertEqual(impactor.bundled(str(t / "res2")), {"plumesign": str(out)})
        self.assertTrue((d / "0001-anisette-v3-server.patch").is_file())
        self.assertIn("修改版", (d / "README-来源与许可.txt").read_text(encoding="utf-8"))

    def test_pinned_mac_hash_is_own_build(self):
        import impactor
        self.assertEqual(impactor.BUNDLED_MAC, {"plumesign-macos-universal": "f3f8be40ebb05abc0e732e09a846bbbcbefaded87f9fd6bfe857adf8d100bcd9"})


if __name__ == "__main__":
    unittest.main()
