"""通用壳程序包（pack/jobs/program_pack.py、pack/ship_ext.py program、pack/orch/install_win.py sign_dylibs、tools/push_pack.py Devpush.mv）。
期望值不靠被测代码算：
  ① build：出的 dylib 与直接跑 ship_ext.py program 的逐字节相同；第二次键没变不重出（目录修改时间不变）；程序件里一个文件变了就重出
  ② sign：假签名器收到的团队 / 包名就是给的；catalogue.json 字段按约定手写，image_sha256 = 本测试对签好的文件算的 SHA-256；同团队同包名第二次不再签
  ③ need：六种原因各一例 + 都对得上 = 空集
  ④ sign_dylibs：假 plumesign 收到 --custom-identifier <包名>、没有 --register-and-install；小 IPA 里没有 PlugIns/；签好的 dylib 原地换回
  ⑤ Devpush.mv：假工具收到「mv <源> <目标>」
  ⑦（已删：签名器按模式选的 signer_for 随旧 Mac Xcode 路径一起撤了）
  ⑧ install.push_program（写入规则 11-17 定稿）：手写的调用顺序（版本目录 v-<sha16>-pc/ 下 dylib → Games 各文件 → catalogue.json.pc.tmp → 改名覆盖 catalogue.json），
     清单带 dir；换上后只删换上前清单指着的旧版本目录（没有旧清单 / 指的就是这次的 → 不删）；续推时机上已完整（长度 + 开头一页对）的文件跳过；改名失败报红
  ⑨ install.push_programs：设备记录与要推的包对得上 → 不推、记录原样；没推过 → 推、记录换成这次的
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

from jobcase import JobCase, ROOT
import program_pack

sys.path.insert(0, str(ROOT))
from pack.shell import manifest as shell_manifest   # noqa: E402

GID = "0100000000010000"
INFO = dict(host_abi=7, chain="abcdef012345", rewriter_id="rw01")


def make_shell(d):
    r = Path(d) / "shell/root"; r.mkdir(parents=True)
    (r / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "S2Arm", "CFBundleIdentifier": "dev.s2arm.shell", "CFBundlePackageType": "APPL", "CFBundleName": "S2Arm"}))
    (r / "S2Arm").write_bytes(b"\xcf\xfa\xed\xfe" + bytes(60))
    (r / "Frameworks").mkdir(); (r / "PlugIns/W.appex").mkdir(parents=True); (r / "PlugIns/W.appex/W").write_bytes(b"x")
    (r / "S2AShell.tables").write_text("addr_need.tsv\n")
    shell_manifest.seal(r, Path(d) / "shell/manifest.json", *shell_manifest._defaults())
    return Path(d) / "shell"


def make_kit(d):
    k = Path(d) / "kit"; k.mkdir(parents=True)
    (k / "main.patched.bin").write_bytes(bytes((i * 7) & 0xFF for i in range(0xD000)))
    (k / "main.fixups.tsv").write_text("# TEXT_END 0x5000\n# PATCH_OFF 0xc000\n# KEY_PAGE_OFF 0x8000\n# KEY_PAGE_SIZE 0x4000\n")
    (k / "main.gates.tsv").write_text("g\n")
    b = bytearray(0x80 + 0x38); b[0:4] = b"META"; b[0x0C] = 3 << 1
    struct.pack_into("<I", b, 0x70, 0x80); b[0x80:0x84] = b"ACI0"; struct.pack_into("<Q", b, 0x90, int(GID, 16))
    (k / "main.npdm").write_bytes(bytes(b)); (k / "addr_need.tsv").write_text("a\n"); (k / "icon.jpg").write_bytes(b"JPGicon")
    nacp = bytearray(0x4000); t = "甲游戏".encode(); nacp[14 * 0x300:14 * 0x300 + len(t)] = t; nacp[0x3060:0x3065] = b"1.2.0"
    (k / "ctl").mkdir(); (k / "ctl/control.nacp").write_bytes(bytes(nacp))
    return k


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


class ProgramPackTests(JobCase):
    def setUp(self):
        super().setUp()
        self.shell = make_shell(self.root / "s"); self.kit = make_kit(self.root / "k")

    def build(self, banner=""):
        return program_pack.build(self.c, GID, kit=self.kit, shell=self.shell, info=INFO, banner=banner)

    def test_banner_goes_into_package_and_key(self):
        b = self.root / "banner.jpg"; b.write_bytes(b"JPGbanner")
        pkg = self.build(banner=b)
        self.assertEqual((pkg / "Games" / GID / "banner.jpg").read_bytes(), b"JPGbanner")
        out = program_pack.sign(self.c, GID, "T", "io.b", lambda d, t, bd: None, pkg=pkg)
        self.assertEqual(json.loads((out / "catalogue.json").read_text(encoding="utf-8"))["banner"], f"Games/{GID}/banner.jpg")
        t0 = (pkg / "meta.json").stat().st_mtime_ns
        b.write_bytes(b"JPGbanner2"); self.build(banner=b)
        self.assertNotEqual((pkg / "meta.json").stat().st_mtime_ns, t0, "横图换了要重出")

    def test_tvos_package_marked_tvos_and_cached_apart(self):
        # Apple TV 也走通用壳（11-19）。期望（手写，不跑被测的判法）：同一份程序件，iPhone 版镜像包 LC_BUILD_VERSION 平台 2（iOS）、
        #   Apple TV 版平台 3（tvOS，tvOS 的 dyld 不加载标 iOS 的库）；两份放不同目录（package / package-tvos、signed / signed-tvos），互不覆盖
        def platform(dylib):
            d = Path(dylib).read_bytes(); n = struct.unpack_from("<I", d, 16)[0]; at = 32
            for _ in range(n):
                cmd, size = struct.unpack_from("<II", d, at)
                if cmd == 0x32:
                    return struct.unpack_from("<I", d, at + 8)[0]
                at += size
            return None
        ios = self.build()
        tv = program_pack.build(self.c, GID, kit=self.kit, shell=self.shell, info=INFO, banner="", platform="tvos")
        self.assertEqual((ios.name, tv.name), ("package", "package-tvos"))
        self.assertEqual((platform(ios / program_pack.image_name(GID)), platform(tv / program_pack.image_name(GID))), (2, 3))
        s_ios = program_pack.sign(self.c, GID, "T", "io.b", lambda d, t, bd: None, pkg=ios)
        s_tv = program_pack.sign(self.c, GID, "T", "io.b", lambda d, t, bd: None, pkg=tv, platform="tvos")
        self.assertEqual((s_ios.parent.name, s_tv.parent.name), ("signed", "signed-tvos"))
        self.assertEqual(platform(s_tv / program_pack.image_name(GID)), 3)

    def test_build_matches_ship_ext_and_caches(self):
        pkg = self.build()
        ref = self.root / "ref/program"
        subprocess.run([sys.executable, str(ROOT / "pack/ship_ext.py"), "program", "--shell", str(self.shell), "--root", str(self.kit), "--out", str(ref)], check=True, capture_output=True)
        self.assertEqual((pkg / f"S2AImages-{GID}.dylib").read_bytes(), (ref / f"S2AImages-{GID}.dylib").read_bytes())
        meta = json.loads((pkg / "meta.json").read_text(encoding="utf-8"))
        self.assertEqual((meta["host_abi"], meta["chain"], meta["rewriter_id"], meta["name"], meta["display_version"]), (7, "abcdef012345", "rw01", "甲游戏", "1.2.0"))
        t0 = (pkg / "meta.json").stat().st_mtime_ns
        self.assertEqual(self.build(), pkg); self.assertEqual((pkg / "meta.json").stat().st_mtime_ns, t0, "键没变不重出")
        (self.kit / "addr_need.tsv").write_text("b\n")
        self.build(); self.assertNotEqual((pkg / "meta.json").stat().st_mtime_ns, t0, "程序件变了要重出")

    def test_sign_writes_catalogue_and_caches_per_team(self):
        pkg = self.build(); calls = []
        def signer(dylib, team, bundle):
            calls.append((Path(dylib).name, team, bundle)); Path(dylib).write_bytes(Path(dylib).read_bytes() + team.encode())
        out = program_pack.sign(self.c, GID, "TEAMA", "io.example.games", signer, pkg=pkg)
        self.assertEqual(calls, [(f"S2AImages-{GID}.dylib", "TEAMA", "io.example.games")])
        cat = json.loads((out / "catalogue.json").read_text(encoding="utf-8"))
        want = dict(schema=1, title_id=GID, name="甲游戏", display_version="1.2.0", host_abi=7, chain="abcdef012345", rewriter_id="rw01",
                    image=f"S2AImages-{GID}.dylib", image_sha256=sha(out / f"S2AImages-{GID}.dylib"), team="TEAMA", icon=f"Games/{GID}/icon.jpg")
        self.assertEqual(cat, want)
        self.assertEqual(sorted(p.name for p in out.iterdir() if not p.name.startswith(".")), ["Games", f"S2AImages-{GID}.dylib", "catalogue.json"])
        program_pack.sign(self.c, GID, "TEAMA", "io.example.games", signer, pkg=pkg); self.assertEqual(len(calls), 1, "同团队同包名不再签")
        program_pack.sign(self.c, GID, "TEAMB", "io.example.games", signer, pkg=pkg); self.assertEqual(len(calls), 2, "换团队要重签")

    def test_sign_cache_follows_signer_kind(self):
        # 同团队同包名、换了签法（Mac 从 Xcode 钥匙串换到 plumesign + s2a-selfsign）：不能命中旧签法的缓存，要重签，签好的哈希随之变（推送按哈希判要不要推）
        pkg = self.build(); calls = []
        def mk(kind):
            def run(dylib, team, bundle):
                calls.append(kind); Path(dylib).write_bytes(Path(dylib).read_bytes() + kind.encode())
            run.kind = kind
            return run
        a = program_pack.sign(self.c, GID, "TEAMA", "io.b", mk("xcode"), pkg=pkg)
        sha_a = json.loads((a / "catalogue.json").read_text(encoding="utf-8"))["image_sha256"]
        program_pack.sign(self.c, GID, "TEAMA", "io.b", mk("xcode"), pkg=pkg)
        self.assertEqual(calls, ["xcode"], "同签法不再签")
        b = program_pack.sign(self.c, GID, "TEAMA", "io.b", mk("selfsign:abc"), pkg=pkg)
        self.assertEqual(calls, ["xcode", "selfsign:abc"], "换签法要重签")
        self.assertNotEqual(json.loads((b / "catalogue.json").read_text(encoding="utf-8"))["image_sha256"], sha_a)

    def test_sign_keeps_only_signed_copy(self):
        # 0.6.0 程序缓存瘦身：生产路径（不传 pkg，sign 自己出未签名包）签好后删掉未签名 dylib，只留键与元数据；
        #   同团队再要 → 直接用签好的（不重出未签名包、不重签）；换团队 → 按键重出未签名包再签，签完照样删。期望手写
        from unittest import mock
        import programs
        calls, builds = [], []
        def signer(dylib, team, bundle):
            calls.append(team); Path(dylib).write_bytes(Path(dylib).read_bytes() + team.encode())
        real = program_pack.build
        def build(c, gid, **k):
            builds.append(1); return real(c, gid, kit=self.kit, shell=self.shell, info=INFO, banner="")
        with mock.patch.object(program_pack, "build", build), mock.patch.object(programs, "kit_dir", lambda c, g: self.kit), \
             mock.patch.object(program_pack, "compat", lambda c: INFO), mock.patch("layout.path", lambda *a, **k: self.root / "no-banner.jpg"):
            out = program_pack.sign(self.c, GID, "TEAMA", "io.b", signer)
            pkg = programs.cache(self.c, GID) / program_pack.PACKAGE
            self.assertFalse((pkg / f"S2AImages-{GID}.dylib").exists(), "签好后未签名 dylib 删掉")
            self.assertTrue((pkg / ".key").is_file() and (pkg / "meta.json").is_file(), "键与元数据留着")
            self.assertTrue((out / f"S2AImages-{GID}.dylib").read_bytes().endswith(b"TEAMA"))
            self.assertEqual(program_pack.sign(self.c, GID, "TEAMA", "io.b", signer), out)
            self.assertEqual((calls, len(builds)), (["TEAMA"], 1), "同团队再要：直接用签好的，不重出不重签")
            out_b = program_pack.sign(self.c, GID, "TEAMB", "io.b", signer)
            self.assertEqual((calls, len(builds)), (["TEAMA", "TEAMB"], 2), "换团队：重出未签名包再签")
            self.assertTrue((out_b / f"S2AImages-{GID}.dylib").read_bytes().endswith(b"TEAMB"))
            self.assertFalse((pkg / f"S2AImages-{GID}.dylib").exists(), "签完照样删")

    def test_rebuild_survives_exfat_companion_vanishing(self):
        # D-6P5D（诊断#e178e8）：工具缓存在 exFAT 盘上，每个文件旁有 AppleDouble 伴随文件 ._<名>，删本体时系统连带删掉它，
        #   rmtree 事先列出的 ._<名> 再删就是 FileNotFoundError → 换旧 package-tvos / signed 时整个装 Apple TV 失败。
        #   期望（手写）：程序件变了照样重出、重签，新包换上；别的删除错误照抛。
        #   随包运行时是 Python 3.12（它的 rmtree 遇到 FileNotFoundError 就抛，3.13 起自己容忍）：负对照要用 3.12 跑才红
        real = os.unlink
        def unlink(path, *a, **k):   # 模拟非 APFS 盘：删到 ._<名> 时它已随本体消失
            real(path, *a, **k)
            if Path(str(path)).name.startswith("._"):
                raise FileNotFoundError(2, "No such file or directory", str(path))
        pkg = program_pack.build(self.c, GID, kit=self.kit, shell=self.shell, info=INFO, banner="", platform="tvos")
        out = program_pack.sign(self.c, GID, "T", "io.b", lambda d, t, bd: None, pkg=pkg, platform="tvos")
        keys = [(d / ".key").read_text(encoding="utf-8") for d in (pkg, out)]
        for d in (pkg, out):
            (d / "._meta").write_bytes(b"x")
        (self.kit / "addr_need.tsv").write_text("b\n")   # 程序件变了：要重出、重签，换掉旧目录
        with mock.patch("os.unlink", unlink):
            pkg2 = program_pack.build(self.c, GID, kit=self.kit, shell=self.shell, info=INFO, banner="", platform="tvos")
            out2 = program_pack.sign(self.c, GID, "T", "io.b", lambda d, t, bd: None, pkg=pkg2, platform="tvos")
        self.assertEqual((pkg2, out2), (pkg, out))
        self.assertFalse((pkg / "._meta").exists() or (out / "._meta").exists(), "旧目录整个换掉")
        self.assertTrue(all((d / ".key").read_text(encoding="utf-8") != k for d, k in zip((pkg, out), keys)), "新包已换上")
        (self.kit / "addr_need.tsv").write_text("c\n")
        def denied(path, *a, **k):
            raise PermissionError(13, "Permission denied", str(path))
        with mock.patch("os.unlink", denied), self.assertRaises(PermissionError):
            program_pack.build(self.c, GID, kit=self.kit, shell=self.shell, info=INFO, banner="", platform="tvos")

    def test_need_reasons(self):
        want = dict(host_abi=7, rewriter_id="rw01", image_sha256="s1")
        ok = dict(sha="s1", team="T", cert="C", host_abi=7, rewriter_id="rw01")
        N = lambda phone, team="T", cert="C": program_pack.need(self.c, GID, phone, team, cert, want=want)
        self.assertEqual(N(None), {"missing"})
        self.assertEqual(N(ok), set())
        self.assertEqual(N(dict(ok, host_abi=6)), {"abi"})
        self.assertEqual(N(dict(ok, rewriter_id="rw00")), {"rewriter"})
        self.assertEqual(N(dict(ok, sha="s0")), {"sha"})
        self.assertEqual(N(ok, team="U"), {"team"})
        self.assertEqual(N(ok, cert="D"), {"cert"})


class SignDylibsTests(unittest.TestCase):
    def test_custom_identifier_no_register_no_plugins(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d); shell = make_shell(d) / "root"
            dy = d / f"S2AImages-{GID}.dylib"; dy.write_bytes(b"UNSIGNED")
            argv, seen = d / "argv.json", d / "seen.json"
            fake = d / "plumesign"
            fake.write_text(f"""#!{sys.executable}
import json, sys, zipfile
a = sys.argv[1:]; json.dump(a, open({str(argv)!r}, "w"))
src, out = a[a.index("--package") + 1], a[a.index("-o") + 1]
with zipfile.ZipFile(src) as zi, zipfile.ZipFile(out, "w") as zo:
    json.dump(zi.namelist(), open({str(seen)!r}, "w"))
    for n in zi.namelist(): zo.writestr(n, zi.read(n) + (b"+SIGNED" if n.endswith(".dylib") else b""))
""")
            fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
            sys.path.insert(0, str(ROOT))
            from pack.orch import install_win
            install_win.sign_dylibs(str(fake), shell, [dy], "io.example.games.team", d / "sign.log")
            a = json.loads(argv.read_text())
            self.assertIn("--custom-identifier", a); self.assertEqual(a[a.index("--custom-identifier") + 1], "io.example.games.team")
            self.assertNotIn("--register-and-install", a)
            names = json.loads(seen.read_text())
            self.assertIn(f"Payload/S2Arm.app/Frameworks/S2AImages-{GID}.dylib", names)
            self.assertFalse(any("/PlugIns/" in n for n in names), "小 IPA 不带小组件扩展")
            self.assertEqual(dy.read_bytes(), b"UNSIGNED+SIGNED")


    def test_win_signer_keeps_plumesign_code(self):
        # D-39W8（Windows 0.6.9）：导出 / 推送前「准备这款的程序」签程序库时 plumesign 报 Apple 1100 登录过期，install_win 抛的 Fail 带 code=apple_session_expired，
        #   作业结果却是 job_failed「本地任务失败」——win_signer 原样抛 install_win.Fail，作业层不认这个类。
        #   期望（手写）：win_signer 转成作业失败，码 = apple_session_expired，上屏是重新登录的办法，plumesign 原文进 internal
        import errors
        with tempfile.TemporaryDirectory() as d:
            d = Path(d); shell = make_shell(d) / "root"
            dy = d / f"S2AImages-{GID}.dylib"; dy.write_bytes(b"UNSIGNED")
            fake = d / "plumesign"
            fake.write_text(f"""#!{sys.executable}
import sys
print("Error: Developer API error 1100: Your session has expired. Please log in.")
sys.exit(1)
""")
            fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
            c = mock.Mock(engine=ROOT, logs=d, task="t1", device_kind="")
            run = program_pack.win_signer(c, str(fake), shell)
            with self.assertRaises(errors.Failure) as e:
                run(dy, "TEAMX", "io.example.games.teamx")
            self.assertEqual(e.exception.code, "apple_session_expired")
            self.assertIn(errors.RECOVERY["apple_session_expired"], str(e.exception))
            self.assertIn("1100", e.exception.internal)


class DevpushMvTests(unittest.TestCase):
    def test_mv_calls_tool(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d); rec = d / "argv.json"; fake = d / "devpush"
            fake.write_text(f"#!{sys.executable}\nimport json, sys\njson.dump(sys.argv[1:], open({str(rec)!r}, 'w'))\nprint('mv ok')\n")
            fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
            sys.path.insert(0, str(ROOT / "tools"))
            import push_pack
            dp = push_pack.Devpush(str(fake), "UDID", "io.example", d)
            ok, _ = dp.mv("Library/x/catalogue.json.tmp", "Library/x/catalogue.json")
            self.assertTrue(ok)
            self.assertEqual(json.loads(rec.read_text())[-3:], ["mv", "Library/x/catalogue.json.tmp", "Library/x/catalogue.json"])


class FakeClient:
    """机上导入文件夹的替身：ls 列文档根、head 读机上文件长度与开头、put 记下写了什么"""
    def __init__(self, have=None, dirs=None):
        self.calls, self.have, self.dirs, self.puts = [], dict(have or {}), list(dirs or []), {}
    def ls(self, rel):
        self.calls.append(("ls", rel)); return list(self.dirs)
    def head(self, rel, n):
        b = self.have.get(rel); return (-1, b"") if b is None else (len(b), b[:n])
    def put(self, src, rel):
        self.calls.append(("put", rel)); self.puts[rel] = Path(src).read_bytes()


def unpack_s2arm(data):
    """推出去的 .s2arm → [(条目名, 内容)]（解 zstd 帧、读 ustar；按顺序）"""
    import io
    import programs
    import tarfile
    with tarfile.open(fileobj=io.BytesIO(programs._decompress(data)), mode="r:") as t:
        return [(m.name, t.extractfile(m).read()) for m in t.getmembers()]


class ImportClient:
    """手机侧替身：ls(导入文件夹) 按轮给结果；get 清单写出这一轮的 dir"""
    def __init__(self, rounds):
        self.rounds, self.n = rounds, 0   # [(导入文件夹里的名字, 清单 dir | None)]
    def ls(self, rel):
        if rel == "Documents":
            return ["Import Here"]
        self.n += 1   # 每看一次导入文件夹算一轮
        names, _ = self.rounds[min(self.n - 1, len(self.rounds) - 1)]
        return list(names)
    def get(self, rel, dst):
        _, d = self.rounds[min(self.n - 1, len(self.rounds) - 1)]
        if d is None:
            return False
        Path(dst).write_text(json.dumps({"dir": d})); return True


class FakePhone:
    def __init__(self, running, cl):
        self.running, self.cl, self.made = running, cl, 0
    def app_running(self):
        return self.running
    def client(self, w):
        self.made += 1; return self.cl


class AwaitImportTests(JobCase):
    """11-19 推完程序包照实报：App 开着等它导入换上清单才算装好；没开 / 等不到 → 「已送到手机，打开 S2Arm 时自动装好。」。期望手写"""
    def setUp(self):
        super().setUp()
        import install
        self.install = install
        self.sleep = mock.patch.object(install.time, "sleep", lambda s: None); self.sleep.start(); self.addCleanup(self.sleep.stop)

    def test_app_closed_says_sent_without_waiting(self):
        ph = FakePhone(False, None)
        self.assertEqual(self.install.await_import(self.c, ph, GID, "v-a-s2arm"), "已送到手机，打开 S2Arm 时自动装好。")
        self.assertEqual(ph.made, 0)

    def test_app_open_waits_until_catalogue_switched(self):
        cl = ImportClient([([f"{GID}.s2arm"], "v-old-pc"), ([], "v-old-pc"), ([], "v-a-s2arm")])   # 还在导 → 导走了清单还没换 → 换上
        self.assertIsNone(self.install.await_import(self.c, FakePhone(True, cl), GID, "v-a-s2arm"))

    def test_open_but_never_imported_says_sent(self):
        cl = ImportClient([([f"{GID}.s2arm"], "v-old-pc")])
        with mock.patch.object(self.install, "IMPORT_WAIT_S", (0, 0)):
            self.assertEqual(self.install.await_import(self.c, FakePhone(True, cl), GID, "v-a-s2arm"), "已送到手机，打开 S2Arm 时自动装好。")

    def test_unknown_running_uses_short_window(self):
        cl = ImportClient([([f"{GID}.s2arm"], None)])
        with mock.patch.object(self.install, "IMPORT_WAIT_S", (999, 0)):
            self.assertEqual(self.install.await_import(self.c, FakePhone(None, cl), GID, "v-a-s2arm"), "已送到手机，打开 S2Arm 时自动装好。")


class PushProgramTests(JobCase):
    """11-19 电脑推送也只推一个 .s2arm（同电脑导出 / 玩家分享的格式），App 用导入同一条代码解开、换上清单。期望手写"""
    def setUp(self):
        super().setUp()
        import install
        self.install = install
        pkg = self.root / "pkg"; (pkg / "Games" / GID / "sub").mkdir(parents=True)
        (pkg / f"S2AImages-{GID}.dylib").write_bytes(b"dy" * 3000)
        (pkg / "Games" / GID / "main.npdm").write_bytes(b"n"); (pkg / "Games" / GID / "sub/t.tsv").write_text("t")
        (pkg / ".key").write_text("k"); (pkg / "meta.json").write_text("{}")   # 缓存键与元数据：不进 .s2arm
        (pkg / "catalogue.json").write_text(json.dumps(dict(title_id=GID, name="甲游戏", image=f"S2AImages-{GID}.dylib", image_sha256="0123456789abcdef" + "f" * 48,
                                                            team="T", host_abi=7, chain="c1", rewriter_id="rw")))
        self.pkg = pkg
        self.inbox = "Documents/Import Here"

    def test_one_s2arm_with_signed_program(self):
        cl = FakeClient()
        got = self.install.push_program(cl, GID.lower(), self.pkg, self.inbox)
        self.assertEqual([c for c in cl.calls if c[0] == "put"], [("put", f"Documents/Import Here/{GID}.s2arm")], "整款只推一个文件")
        ents = unpack_s2arm(cl.puts[f"Documents/Import Here/{GID}.s2arm"])
        self.assertEqual([n for n, _ in ents], ["s2arm.json", "program/catalogue.json", f"program/Games/{GID}/main.npdm", f"program/Games/{GID}/sub/t.tsv",
                                                f"program/S2AImages-{GID}.dylib"], "第一个条目是 s2arm.json（手机按它认文件）；缓存键 / 元数据不进")
        head = json.loads(ents[0][1]); cat = json.loads(ents[1][1])
        self.assertEqual((head["format"], head["title_id"], head["image_sha256"]), ("s2arm", GID, "0123456789abcdef" + "f" * 48))
        self.assertEqual(cat["team"], "T", "清单带团队号：程序已在电脑上签好，手机导入不再签")
        self.assertEqual(dict(ents)[f"program/S2AImages-{GID}.dylib"], b"dy" * 3000)
        self.assertEqual(got, dict(sha="0123456789abcdef" + "f" * 48, team="T", host_abi=7, rewriter_id="rw", dir="v-0123456789abcdef-s2arm", look=self.install.look_of(None)),
                         "记录的版本目录 = 手机导入写的那个（pack_apply.c s2a_s2arm_import：v-<sha 前 16 位>-s2arm）")

    def test_inbox_follows_existing_folder(self):
        # App 按界面语言只建一个导入文件夹：已有「放这里导入」就写进它（不让「文件」里多出一个）；都没有 / 列不出 → Import Here
        self.assertEqual(self.install.import_inbox(FakeClient(dirs=["Inbox", "放这里导入"])), "Documents/放这里导入")
        self.assertEqual(self.install.import_inbox(FakeClient(dirs=["Import Here"])), "Documents/Import Here")
        self.assertEqual(self.install.import_inbox(FakeClient(dirs=[])), "Documents/Import Here")
        self.assertEqual(self.install.import_inbox(object(), "Library/Caches/S2Arm"), "Library/Caches/S2Arm/Import Here", "电视客户端没有 ls")

    def test_resume_same_file_not_repushed(self):
        cl = FakeClient(); self.install.push_program(cl, GID, self.pkg, self.inbox)
        data = cl.puts[f"Documents/Import Here/{GID}.s2arm"]
        cl = FakeClient(have={f"Documents/Import Here/{GID}.s2arm": data})   # App 还没导走、机上已是同一份
        self.install.push_program(cl, GID, self.pkg, self.inbox)
        self.assertEqual([c for c in cl.calls if c[0] == "put"], [], "同一份：不重推")
        cl = FakeClient(have={f"Documents/Import Here/{GID}.s2arm": data[:100]})   # 推了一半
        self.install.push_program(cl, GID, self.pkg, self.inbox)
        self.assertEqual([c for c in cl.calls if c[0] == "put"], [("put", f"Documents/Import Here/{GID}.s2arm")], "没推完：整份重推")

    def test_custom_name_and_cover(self):
        # 只有壳的 App 不带各款条目：启动器里改的名字写进清单、封面换掉程序包里的 Games/<号>/icon.jpg
        cover = self.root / "my.jpg"; cover.write_bytes(b"JPGmine")
        cl = FakeClient()
        got = self.install.push_program(cl, GID, self.pkg, self.inbox, custom=dict(custom=True, name="我的名字", cover=str(cover)))
        ents = dict(unpack_s2arm(cl.puts[f"Documents/Import Here/{GID}.s2arm"]))
        cat = json.loads(ents["program/catalogue.json"])
        self.assertEqual((cat["name"], cat["icon"], ents[f"program/Games/{GID}/icon.jpg"]), ("我的名字", f"Games/{GID}/icon.jpg", b"JPGmine"))
        self.assertEqual(got["look"], self.install.look_of(dict(name="我的名字", cover=str(cover))))
        self.assertNotEqual(got["look"], self.install.look_of(None), "改了名字封面指纹要变")

    def test_push_programs_by_record(self):
        from unittest import mock
        import ipa
        same = dict(sha="0123456789abcdef" + "f" * 48, team="T", host_abi=7, rewriter_id="rw", dir="v-0123456789abcdef-s2arm", look=self.install.look_of(None))
        with mock.patch.object(program_pack, "sign", lambda c, g, team, bundle, signer: self.pkg), mock.patch.object(ipa, "container_custom", lambda c: {}):
            cat = f"Library/Application Support/S2Arm/games/{GID}/program/catalogue.json"
            cl = FakeClient(have={cat: b"{}"})
            got = self.install.push_programs(self.c, cl, [GID], dict(games={GID: dict(program=same)}), "T", "io.b", None)
            self.assertEqual((cl.calls, got), ([], {GID: same}), "对得上、机上清单在：什么都不推，连导入文件夹都不列")
            # D-TW8E：记录说推过、机上清单不在（玩家在 App 里删过）→ 补推；导入文件夹里还有没导走的 .s2arm → 不重推
            cl = FakeClient()
            self.install.push_programs(self.c, cl, [GID], dict(games={GID: dict(program=same)}), "T", "io.b", None)
            self.assertEqual([c for c in cl.calls if c[0] == "put"], [("put", f"Documents/Import Here/{GID}.s2arm")], "机上没有：补推")
            cl = FakeClient(have={f"Documents/Import Here/{GID}.s2arm": b"x" * 10})
            self.install.push_programs(self.c, cl, [GID], dict(games={GID: dict(program=same)}), "T", "io.b", None)
            self.assertEqual([c for c in cl.calls if c[0] == "put"], [], "还在导入文件夹里等导入：不重推")
            cl = FakeClient(dirs=["放这里导入"])
            got = self.install.push_programs(self.c, cl, [GID], dict(games={}), "T", "io.b", None)
            self.assertEqual([c for c in cl.calls if c[0] == "put"], [("put", f"Documents/放这里导入/{GID}.s2arm")])
            self.assertEqual(got, {GID: same}, "没推过：推了、记录换成这次的")
        with mock.patch.object(program_pack, "sign", lambda c, g, team, bundle, signer: self.pkg), \
             mock.patch.object(ipa, "container_custom", lambda c: {GID: dict(custom=True, name="新名字", cover="")}):
            cl = FakeClient()
            got = self.install.push_programs(self.c, cl, [GID], dict(games={GID: dict(program=same)}), "T", "io.b", None)
        self.assertEqual(json.loads(dict(unpack_s2arm(cl.puts[f"Documents/Import Here/{GID}.s2arm"]))["program/catalogue.json"])["name"], "新名字", "只改了名字：照推")
        self.assertNotEqual(got[GID]["look"], same["look"])


if __name__ == "__main__":
    unittest.main()
