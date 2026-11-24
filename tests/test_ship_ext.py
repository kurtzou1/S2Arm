#!/usr/bin/env python3
"""阶段 0 外置镜像包与预编壳组装单测（ios/macho_dylib.py、ios/embed.py --ext、pack/ship_ext.py）。

期望值都由本测试按 Mach-O / 偏移表格式手算，不调被测实现算期望：
  ① 写出器：节文件偏移 / 16K 对齐、LC_CODE_SIGNATURE 在最后、自带 CodeDirectory 为 adhoc + linker-signed、页哈希 = 本测试对 [0, 签名区) 逐 4K 算的 SHA-256；
     同输入换路径逐字节同、内容变则 UUID 变
  ② embed.py：造一个模块（TEXT_END / PATCH_OFF / 键页手定），偏移表三块（x0 / W / x1）的（偏移, 长度）与节内容按切法手算
  ③ ship_ext：主程序内嵌表项数读法；壳编号不配套 / 壳文件被改都报红；配套时组装出外置包与随行表
  ④ ship_ext container（多款容器）：布局 / 目录清单 / 不产出窗口表（窗口需求宿主构造期自己算，runtime/tests/t_vawin_container.c 按同一组夹具手算）/
     地址空间类型不一致拒绝（新款之间、新款与已有款）/ 加一款已有款逐字节不变 / 换一款保序、别的壳组装的已有款不混装
"""
import hashlib
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "ios"))
sys.path.insert(0, str(REPO))
import macho_dylib  # noqa: E402
from pack.shell import manifest as shell_manifest  # noqa: E402
PG = 0x4000


def sections(data):
    """返回 {(段, 节): (文件偏移, 长度, 标志)} 与加载命令号列表"""
    ncmds = struct.unpack_from("<I", data, 16)[0]; o = 32; out = {}; cmds = []
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", data, o); cmds.append((cmd, o))
        if cmd == 0x19:
            for k in range(struct.unpack_from("<I", data, o + 64)[0]):
                q = o + 72 + 80 * k
                sn = data[q:q + 16].rstrip(b"\0").decode(); seg = data[q + 16:q + 32].rstrip(b"\0").decode()
                _, size, off, _, _, _, flags = struct.unpack_from("<QQIIIII", data, q + 32)
                out[(seg, sn)] = (off, size, flags)
        o += sz
    return out, cmds


class MachoDylibTest(unittest.TestCase):
    def write(self, d, code, data, name="x.dylib"):
        p = Path(d) / name
        macho_dylib.write(p, "@rpath/T.dylib", text=[("__swcode", 14, macho_dylib.PURE_INSTRUCTIONS, [code])],   # code：字节或（路径, 偏移, 长度）
                          data=("__SWDATA", [("__img", 14, 0, [data])]))
        return p.read_bytes()

    def test_layout_and_signature(self):
        code, data = bytes(range(256)) * 80, b"\x5a" * 0x4000      # 代码 20 KB → 两页
        with tempfile.TemporaryDirectory() as d:
            b = self.write(d, code, data)
        secs, cmds = sections(b)
        self.assertEqual(secs[("__TEXT", "__swcode")][:2], (0x4000, len(code)))      # 头页之后
        self.assertEqual(secs[("__SWDATA", "__img")][:2], (0xC000, 0x4000))          # 0x4000 + 圆整 16K(20 KB) = 0xC000
        self.assertEqual(secs[("__TEXT", "__swcode")][2], 0x80000400)
        self.assertEqual(b[0x4000:0x4000 + len(code)], code)
        self.assertEqual(b[0xC000:0x10000], data)
        self.assertEqual(cmds[-1][0], 0x1D, "LC_CODE_SIGNATURE 要在最后（与 ld 一致）")
        cs_off, cs_size = struct.unpack_from("<II", b, cmds[-1][1] + 8)
        self.assertEqual(len(b), cs_off + cs_size)
        magic, _, count = struct.unpack_from(">III", b, cs_off)
        self.assertEqual((magic, count), (0xFADE0CC0, 1))
        cd = cs_off + struct.unpack_from(">I", b, cs_off + 16)[0]
        cdmagic, _, ver, flags, hoff, _, nspecial, ncode, limit = struct.unpack_from(">IIIIIIIII", b, cd)
        self.assertEqual((cdmagic, ver, flags, nspecial, limit), (0xFADE0C02, 0x20400, 0x20002, 0, cs_off))
        want = [hashlib.sha256(b[i:min(i + 4096, cs_off)]).digest() for i in range(0, cs_off, 4096)]
        self.assertEqual(ncode, len(want))
        self.assertEqual([b[cd + hoff + 32 * i:cd + hoff + 32 * i + 32] for i in range(ncode)], want)

    def test_path_independent_and_uuid_by_content(self):
        code, data = b"\x01\x02\x03\x04" * 1000, b"\x09" * 100
        with tempfile.TemporaryDirectory() as d1, tempfile.TemporaryDirectory() as d2:
            for d in (d1, d2): Path(d, "code.bin").write_bytes(code)   # 同一份内容放在两个不同路径，按（路径, 偏移, 长度）块读
            a = self.write(d1, (str(Path(d1, "code.bin")), 0, len(code)), data)
            b = self.write(d2, (str(Path(d2, "code.bin")), 0, len(code)), data, "other_name.dylib")
            c = self.write(d1, code[:-4] + b"\xff\xff\xff\xff", data, "c.dylib")
        self.assertEqual(a, b)
        uuid = lambda x: next(x[o + 8:o + 24] for cmd, o in sections(x)[1] if cmd == 0x1B)
        self.assertNotEqual(uuid(a), uuid(c))


def make_module(root, name="main"):
    """造一个模块：TEXT_END 0x5000 → 切点 a = 0x8000；键页 0x8000 + 0x4000；PATCH_OFF 0xC000；patched.bin 长 0xD000"""
    blob = bytes((i * 7) & 0xFF for i in range(0xD000))
    (root / f"{name}.patched.bin").write_bytes(blob)
    (root / f"{name}.fixups.tsv").write_text("# TEXT_END 0x5000\n# PATCH_OFF 0xc000\n# KEY_PAGE_OFF 0x8000\n# KEY_PAGE_SIZE 0x4000\n")
    (root / f"{name}.gates.tsv").write_text("g\n")
    return blob


class EmbedExtTest(unittest.TestCase):
    def test_index_and_blocks(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); blob = make_module(root)
            r = subprocess.run([sys.executable, str(REPO / "ios/embed.py"), str(root), str(root / "S2AImages.dylib"), "main"],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            b = (root / "S2AImages.dylib").read_bytes()
        secs, _ = sections(b)
        co, cl, _ = secs[("__TEXT", "__swcode")]; wo, wl, _ = secs[("__SWDATA", "__img")]; io, il, _ = secs[("__TEXT", "__swidx")]
        self.assertEqual((co % PG, wo % PG), (0, 0))
        self.assertEqual(b[io:io + 16], b"S2AEMB01" + struct.pack("<II", 1, 88))
        ent = struct.unpack_from("<24s8Q", b, io + 16)
        self.assertEqual(ent[0].rstrip(b"\0"), b"main")
        # x0 = [0, 0x8000)、W = [0x8000, 0xC000)、x1 = [0xC000, 0x10000)（文件只到 0xD000，补零）、x2 空
        self.assertEqual(ent[1:], (0, 0x8000, 0, 0x4000, 0x8000, 0x4000, 0, 0))
        self.assertEqual(cl, 0xC000)
        self.assertEqual(b[co:co + 0x8000], blob[:0x8000])
        self.assertEqual(b[co + 0x8000:co + 0xC000], blob[0xC000:0xD000] + b"\0" * 0x3000)
        self.assertEqual(b[wo:wo + wl], blob[0x8000:0xC000])


class ShipExtTest(unittest.TestCase):
    def shell(self, d, commit_ok=True):
        r = Path(d) / "shell/root"; r.mkdir(parents=True)
        info = {"CFBundleExecutable": "S2Arm", "CFBundleIdentifier": "dev.s2arm.shell", "CFBundleDisplayName": "S2Arm",
                "CFBundlePackageType": "APPL", "CFBundleName": "S2Arm"}
        (r / "Info.plist").write_bytes(plistlib.dumps(info))
        (r / "S2Arm").write_bytes(b"\xcf\xfa\xed\xfe" + bytes(60))
        (r / "Frameworks").mkdir()
        (r / "S2AShell.tables").write_text("addr_need.tsv\nwiden_enable.*.tsv\n")
        ident = shell_manifest._defaults() if commit_ok else ("0" * 40, "f" * 16, "x", "1.0", "27")
        shell_manifest.seal(r, Path(d) / "shell/manifest.json", *ident)
        return Path(d) / "shell"

    def run_build(self, d, shell):
        root = Path(d) / "root"; root.mkdir(exist_ok=True); make_module(root)
        (root / "main.npdm").write_bytes(b"META"); (root / "addr_need.tsv").write_text("a\n"); (root / "widen_enable.1.tsv").write_text("w\n")
        nacp = bytearray(0x4000); nacp[14 * 0x300:14 * 0x300 + 12] = "测试游戏".encode()   # 旧格式：头 0x3000 = 16 项 × 0x300，第 14 项 = 简中
        (root / "ctl").mkdir(exist_ok=True); (root / "ctl/control.nacp").write_bytes(bytes(nacp))
        from PIL import Image
        Image.new("RGB", (64, 64), (10, 20, 30)).save(root / "icon.png")
        return subprocess.run([sys.executable, str(REPO / "pack/ship_ext.py"), "build", "--shell", str(shell), "--root", str(root),
                               "--out", str(Path(d) / "out/S2Arm.app"), "--bundle-id", "dev.example.game",
                               "--icon", str(root / "icon.png")], capture_output=True, text=True)

    def test_swidx_count(self):
        sys.path.insert(0, str(REPO / "pack"))
        import ship_ext
        with tempfile.TemporaryDirectory() as d:
            for n in (0, 2):
                p = Path(d) / f"e{n}"
                macho_dylib.write(p, "@rpath/E", text=[("__swidx", 3, 0, [b"S2AEMB01" + struct.pack("<II", n, 88) + bytes(88 * n)])])
                self.assertEqual(ship_ext.swidx_count(p), n)

    def test_build_ok(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_build(d, self.shell(d))
            self.assertEqual(r.returncode, 0, r.stderr)
            app = Path(d) / "out/S2Arm.app"
            for f in ("Frameworks/S2AImages.dylib", "main.fixups.tsv", "main.gates.tsv", "main.npdm", "addr_need.tsv", "widen_enable.1.tsv"):
                self.assertTrue((app / f).is_file(), f)
            self.assertFalse((app / "S2AShell.tables").exists())
            info = plistlib.loads((app / "Info.plist").read_bytes())
            self.assertEqual(info["CFBundleIdentifier"], "dev.example.game")
            # Info.plist 显示名 ASCII（侧载工具建 App ID 用；夹具 nacp 只有简中标题 → 退回品牌名「S2Arm」），中文「<游戏名> S2Arm」进 zh-Hans / zh-Hant 本地化
            self.assertEqual(info["CFBundleDisplayName"], "S2Arm")
            for lang in ("zh-Hans", "zh-Hant"):
                self.assertEqual((app / f"{lang}.lproj/InfoPlist.strings").read_text(encoding="utf-8"), '"CFBundleDisplayName" = "测试游戏 S2Arm";\n')

    def test_build_multi_program(self):   # 多程序合集（11-06 维护者：iOS 同 Mac 带全部序号）：programs/1 的模块进同一个镜像包、包内名 p1/<名>；随行表与 main.npdm 拷到 App programs/1/
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "root"; p1 = root / "programs/1"; p1.mkdir(parents=True)
            make_module(p1); blob1 = bytes((i * 13 + 5) & 0xFF for i in range(0xD000)); (p1 / "main.patched.bin").write_bytes(blob1); (p1 / "main.npdm").write_bytes(b"META1"); (p1 / "widen_enable.2.tsv").write_text("w1\n")
            r = self.run_build(d, self.shell(d))
            self.assertEqual(r.returncode, 0, r.stderr)
            app = Path(d) / "out/S2Arm.app"
            for f in ("programs/1/main.fixups.tsv", "programs/1/main.gates.tsv", "programs/1/main.npdm", "programs/1/widen_enable.2.tsv", "main.fixups.tsv", "main.npdm"):
                self.assertTrue((app / f).is_file(), f)
            self.assertEqual((app / "programs/1/main.npdm").read_bytes(), b"META1")
            b = (app / "Frameworks/S2AImages.dylib").read_bytes()
        secs, _ = sections(b); io, _, _ = secs[("__TEXT", "__swidx")]; co, _, _ = secs[("__TEXT", "__swcode")]
        self.assertEqual(struct.unpack_from("<I", b, io + 8)[0], 2)   # 两个模块：main（序号 0）、p1/main
        e0 = struct.unpack_from("<24s8Q", b, io + 16); e1 = struct.unpack_from("<24s8Q", b, io + 16 + 88)
        self.assertEqual((e0[0].rstrip(b"\0"), e1[0].rstrip(b"\0")), (b"main", b"p1/main"))
        self.assertEqual(b[co + e1[1]:co + e1[1] + 0x8000], blob1[:0x8000])   # p1/main 的 x0 块就是 programs/1/main.patched.bin 的头 32K

    def test_pkg_srcs_programs(self):   # 资源包源：序号 1 的游戏数据与直连库带上（programs/1/…），系统数据 / 补丁表各序号共用根上的、不重复带；序号断了（没有 2）就停
        sys.path.insert(0, str(REPO / "pack"))
        import pkg_srcs
        with tempfile.TemporaryDirectory() as d:
            w = Path(d)
            for r in (w, w / "programs/1", w / "programs/3"):
                (r / "exefs").mkdir(parents=True); (r / "exefs/main.npdm").write_bytes(b"M"); (r / "romfs").mkdir(); (r / "systemdata").mkdir()
                (r / "shaders/direct").mkdir(parents=True); (r / "shaders/direct/keys.tsv").write_text("k\n"); (r / "patch.tsv").write_text("p\n")
            (w / "programs/1/ctl").mkdir(); (w / "programs/1/ctl/control.nacp").write_bytes(b"N")
            old = os.environ.get("S2A_DUAL"); os.environ["S2A_DUAL"] = "1"
            try: got = [x for x, _ in pkg_srcs.srcs(str(w))]
            finally:
                if old is None: os.environ.pop("S2A_DUAL", None)
                else: os.environ["S2A_DUAL"] = old
        for want in ("exefs/main.npdm", "romfs", "systemdata", "patch.tsv", "shaders/direct/keys.tsv",
                     "programs/1/exefs/main.npdm", "programs/1/romfs", "programs/1/ctl/control.nacp", "programs/1/shaders/direct/keys.tsv"):
            self.assertIn(want, got)
        for no in ("programs/1/systemdata", "programs/1/patch.tsv"):
            self.assertNotIn(no, got)
        self.assertFalse([x for x in got if x.startswith("programs/3/")])   # 序号 2 不在 → 3 不算（同运行时连续段规则）

    # 维护者 11-17：校验不过不再拒绝出包。期望手写：壳编号不配套 / 壳文件被改 → 黄字点名、照常组装出 App；清单读不了 → 照旧报红
    def test_build_warns_on_foreign_shell(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_build(d, self.shell(d, commit_ok=False))
            self.assertEqual(r.returncode, 0, r.stderr); self.assertIn("🟡", r.stderr); self.assertIn("游戏包要壳", r.stderr)
            self.assertTrue((Path(d) / "out/S2Arm.app").exists())

    def test_build_warns_on_tampered_shell(self):
        with tempfile.TemporaryDirectory() as d:
            s = self.shell(d); (s / "root/S2Arm").write_bytes(b"\xcf\xfa\xed\xfe" + bytes(59) + b"\x01")
            r = self.run_build(d, s)
            self.assertIn("🟡", r.stderr); self.assertIn("被改：S2Arm", r.stderr); self.assertNotIn("不能用", r.stderr)

    def test_build_refuses_unreadable_shell_manifest(self):
        with tempfile.TemporaryDirectory() as d:
            s = self.shell(d); (s / "manifest.json").write_text("{")
            r = self.run_build(d, s)
            self.assertEqual(r.returncode, 1); self.assertIn("不能用", r.stderr)
            self.assertFalse((Path(d) / "out/S2Arm.app").exists())


def make_npdm(path, as_type, sysres, pid):
    """手造 NPDM：META 头 0x80（+0x0C 地址空间类型 << 1、+0x14 SystemResourceSize、+0x1C 主线程栈、+0x70 ACI0 偏移、+0x78 ACID 偏移 0），
    ACI0 在 0x80（+0x10 程序号，内核能力 0 项）；文件不到 ACID +0x300，不是 Switch 2"""
    b = bytearray(0x80 + 0x38)
    b[0:4] = b"META"; b[0x0C] = as_type << 1
    struct.pack_into("<I", b, 0x14, sysres); struct.pack_into("<I", b, 0x1C, 0x100000); struct.pack_into("<I", b, 0x70, 0x80)
    b[0x80:0x84] = b"ACI0"; struct.pack_into("<Q", b, 0x90, pid)
    Path(path).write_bytes(bytes(b))


class ContainerTest(unittest.TestCase):
    """多款容器（ship_ext.py container）。地址窗口需求不在组装期算（宿主构造期对 Games/ 下各款算、取最大，runtime/src/vawin.c；
       同一组夹具 A 32770 MB / B 69944 MB 的手算与宿主读数在 runtime/tests/t_vawin_container.c），组装期只核各款地址空间类型一致：
       A、B：类型 3；C：类型 1（36 位），与 A / B 不同"""
    A, B, C = "0100000000010000", "0100000000020000", "0100000000030000"

    def game(self, d, name, as_type, sysres, pid, title, version=b"1.2.0"):
        root = Path(d) / name; root.mkdir(parents=True); make_module(root)
        make_npdm(root / "main.npdm", as_type, sysres, pid)
        (root / "addr_need.tsv").write_text(f"{name}\n"); (root / "icon.jpg").write_bytes(b"JPG" + name.encode())
        nacp = bytearray(0x4000); t = title.encode(); nacp[14 * 0x300:14 * 0x300 + len(t)] = t; nacp[0x3060:0x3060 + len(version)] = version
        (root / "ctl").mkdir(); (root / "ctl/control.nacp").write_bytes(bytes(nacp))
        return root

    def run_c(self, d, shell, out, roots, base=None, version=None, display_version=None, extra=()):
        from PIL import Image
        icon = Path(d) / "brand.png"
        if not icon.exists(): Image.new("RGB", (64, 64), (1, 2, 3)).save(icon)
        cmd = [sys.executable, str(REPO / "pack/ship_ext.py"), "container", "--shell", str(shell), "--out", str(out), "--bundle-id", "dev.example.games", "--icon", str(icon), "--host-abi", "7"]
        cmd += [x for r in roots for x in ("--game", str(r))] + (["--base", str(base)] if base else []) + (["--version", version] if version else [])
        cmd += (["--display-version", display_version] if display_version else []) + list(extra)
        return subprocess.run(cmd, capture_output=True, text=True,
                              env={**os.environ, "S2A_BANNER_FETCH": "0"})   # 单测零联网：抓图关掉，A 的 banner 走产物根自带拷贝路径

    def setUp(self):
        self.td = tempfile.TemporaryDirectory(); self.d = Path(self.td.name)
        self.shell = ShipExtTest.shell(None, self.d)
        self.a = self.game(self.d, "a", 3, 0, 0x0100000000010000, "甲游戏")
        (self.a / "banner.jpg").write_bytes(b"JPGbanner-a")   # A 的产物根自带横版图：组装走拷贝路径，目录期望里的 banner 与联网无关
        self.b = self.game(self.d, "b", 3, 0x1000, 0x0100000000020000, "乙游戏", b"")

    def tearDown(self): self.td.cleanup()

    def test_version_written_into_info_plist(self):
        # 三端同号：电脑上 S2Arm 的发版号写进容器 Info.plist 的 CFBundleShortVersionString；不给 --version 就沿用壳里的
        import plistlib
        # 界面版本字同理写 S2ADisplayVersion（设置页 / 游戏库顶部读）；不给就不写
        r = self.run_c(self.d, self.shell, self.d / "v1/S2Arm.app", [self.a], version="9.8.7", display_version="v9.8.7-dev+abc1234")
        self.assertEqual(r.returncode, 0, r.stderr)
        p1 = plistlib.loads((self.d / "v1/S2Arm.app/Info.plist").read_bytes())
        self.assertEqual((p1["CFBundleShortVersionString"], p1["S2ADisplayVersion"]), ("9.8.7", "v9.8.7-dev+abc1234"))
        r = self.run_c(self.d, self.shell, self.d / "v2/S2Arm.app", [self.a])
        self.assertEqual(r.returncode, 0, r.stderr)
        shell_v = plistlib.loads((self.shell / "root/Info.plist").read_bytes()).get("CFBundleShortVersionString")
        p2 = plistlib.loads((self.d / "v2/S2Arm.app/Info.plist").read_bytes())
        self.assertEqual(p2.get("CFBundleShortVersionString"), shell_v)
        self.assertNotIn("S2ADisplayVersion", p2)

    def test_ctx_text_tvos_paths(self):
        # Apple TV 容器（组装时 S2A_APPLE_OS=tvos）：文档根 Library/Caches/S2Arm/games/<号>、资源包 <文档根>/资源包（同 runtime/include/s2a_docs.h 电视口径）
        import unittest.mock as um
        sys.path.insert(0, str(REPO / "pack")); import ship_ext
        g = "0100000000010000"
        with um.patch.dict(os.environ, {"S2A_APPLE_OS": "tvos"}):
            tv = ship_ext.ctx_text(g)
        self.assertEqual(tv, f"version\t1\ngame_id\t{g}\nimages\t@bundle/Frameworks/S2AImages-{g}.dylib\nmodule_dir\t@bundle/Games/{g}\n"
                             f"game_data\t@home/Library/Caches/S2Arm/games/{g}/资源包\ndocs\t@home/Library/Caches/S2Arm/games/{g}\n")
        with um.patch.dict(os.environ, {"S2A_APPLE_OS": "ios"}):
            self.assertIn(f"docs\t@home/Documents/games/{g}\n", ship_ext.ctx_text(g))   # iPhone 照旧

    def test_layout_catalogue_and_window_max(self):
        r = self.run_c(self.d, self.shell, self.d / "o1/S2Arm.app", [self.a, self.b])
        self.assertEqual(r.returncode, 0, r.stderr)
        app = self.d / "o1/S2Arm.app"
        for gid in (self.A, self.B):
            for f in ("main.fixups.tsv", "main.gates.tsv", "main.npdm", "addr_need.tsv", "icon.jpg", "launch.ctx"):
                self.assertTrue((app / "Games" / gid / f).is_file(), f"{gid}/{f}")
            self.assertTrue((app / f"Frameworks/S2AImages-{gid}.dylib").is_file())
        for no in ("main.npdm", "main.fixups.tsv", "Frameworks/S2AImages.dylib", "S2AShell.tables", "addr_need.tsv"):   # 根上没有单款文件（宿主不会误走单款兼容）
            self.assertFalse((app / no).exists(), no)
        self.assertEqual([p.relative_to(app).as_posix() for p in app.rglob("s2a_win_need.tsv")], [])   # 不产出窗口表（根上、各款目录里都没有）
        self.assertEqual((app / "Games" / self.A / "addr_need.tsv").read_text(), "a\n")
        self.assertEqual((app / "Games" / self.B / "icon.jpg").read_bytes(), b"JPGb")
        cat = json.loads((app / "s2a_catalogue.json").read_text(encoding="utf-8"))
        chain = json.loads((self.shell / "manifest.json").read_text(encoding="utf-8"))["details"]["chain"]   # 每款记 --host-abi 与壳清单的链号（只换宿主判兼容用）
        self.assertEqual(cat, {"schema": 1, "shell_id": shell_manifest.current_id(), "games": [
            {"title_id": self.A, "name": "甲游戏", "display_version": "1.2.0", "icon": f"Games/{self.A}/icon.jpg", "banner": f"Games/{self.A}/banner.jpg", "state": "playable", "host_abi": 7, "chain": chain},
            {"title_id": self.B, "name": "乙游戏", "icon": f"Games/{self.B}/icon.jpg", "state": "playable", "host_abi": 7, "chain": chain}]})
        self.assertEqual((app / "Games" / self.A / "launch.ctx").read_text(encoding="utf-8"),
                         f"version\t1\ngame_id\t{self.A}\nimages\t@bundle/Frameworks/S2AImages-{self.A}.dylib\nmodule_dir\t@bundle/Games/{self.A}\n"
                         f"game_data\t@home/Library/Application Support/S2Arm/games/{self.A}/资源包\ndocs\t@home/Documents/games/{self.A}\n")   # 资源包挪出 Documents（11-11）
        info = plistlib.loads((app / "Info.plist").read_bytes())
        self.assertEqual((info["CFBundleIdentifier"], info["CFBundleDisplayName"]), ("dev.example.games", "S2Arm"))

    def test_standalone_name_and_icon(self):
        # 独立 App（--standalone，一 App 一游戏）：主屏名 = 游戏自带标题、不带「S2Arm」；Info.plist 本体取英文标题（ASCII）；图标 = 这款 icon.jpg 缩成 120 / 180。
        #   期望手写：A 的 nacp 0 号槽（美式英语）「Game A」、14 号槽（简中）「甲游戏」；封面纯色 (200, 10, 10)；品牌图标 (1, 2, 3)
        import plistlib
        from PIL import Image
        n = bytearray((self.a / "ctl/control.nacp").read_bytes()); n[0:6] = b"Game A"; (self.a / "ctl/control.nacp").write_bytes(bytes(n))
        Image.new("RGB", (64, 64), (200, 10, 10)).save(self.a / "icon.jpg", quality=100)
        r = self.run_c(self.d, self.shell, self.d / "s1/S2Arm.app", [self.a], extra=["--standalone"])
        self.assertEqual(r.returncode, 0, r.stderr)
        app = self.d / "s1/S2Arm.app"
        info = plistlib.loads((app / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleDisplayName"], "Game A")
        self.assertEqual(info["S2AKind"], "standalone", "电脑认独立 App 按这个键，不靠包名（install.installed_s2arm_on）")
        self.assertEqual(info["CFBundleIcons"], {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon60x60"]}})
        self.assertIn('"CFBundleDisplayName" = "甲游戏";', (app / "zh-Hans.lproj/InfoPlist.strings").read_text(encoding="utf-8"))
        self.assertIn('"CFBundleDisplayName" = "Game A";', (app / "en.lproj/InfoPlist.strings").read_text(encoding="utf-8"))
        with Image.open(app / f"AppIcon60x60@{3}x.png") as im:
            self.assertEqual(im.size, (180, 180))
            px = im.convert("RGB").getpixel((90, 90))
        self.assertTrue(all(abs(x - y) <= 6 for x, y in zip(px, (200, 10, 10))), px)
        # 不带 --standalone：同一款照旧 S2Arm 名、S2Arm 图标
        r = self.run_c(self.d, self.shell, self.d / "s2/S2Arm.app", [self.a])
        self.assertEqual(r.returncode, 0, r.stderr)
        app = self.d / "s2/S2Arm.app"
        self.assertEqual(plistlib.loads((app / "Info.plist").read_bytes())["CFBundleDisplayName"], "S2Arm")
        self.assertEqual(plistlib.loads((app / "Info.plist").read_bytes())["S2AKind"], "container")
        self.assertFalse((app / "zh-Hans.lproj/InfoPlist.strings").exists() and "甲游戏" in (app / "zh-Hans.lproj/InfoPlist.strings").read_text(encoding="utf-8"))
        with Image.open(app / f"AppIcon60x60@{3}x.png") as im:
            self.assertEqual(im.convert("RGB").getpixel((90, 90)), (1, 2, 3))
        # 两款不行
        r = self.run_c(self.d, self.shell, self.d / "s3/S2Arm.app", [self.a, self.b], extra=["--standalone"])
        self.assertNotEqual(r.returncode, 0); self.assertIn("--standalone 只装一款", r.stdout + r.stderr)

    def test_as_type_mismatch_refused(self):
        c = self.game(self.d, "c", 1, 0, 0x0100000000030000, "丙游戏")
        r = self.run_c(self.d, self.shell, self.d / "o2/S2Arm.app", [self.a, c])
        self.assertEqual(r.returncode, 1); self.assertIn("地址空间类型不一致", r.stderr)
        self.assertIn(f"{self.A} 类型 3", r.stderr); self.assertIn(f"{self.C} 类型 1", r.stderr)
        self.assertFalse((self.d / "o2/S2Arm.app").exists())

    def test_as_type_mismatch_with_base_refused(self):   # 已有款的类型从容器里它的 Games/<游戏号>/main.npdm 读（同宿主构造期读的那份）
        r = self.run_c(self.d, self.shell, self.d / "o8/S2Arm.app", [self.a]); self.assertEqual(r.returncode, 0, r.stderr)
        c = self.game(self.d, "c", 1, 0, 0x0100000000030000, "丙游戏")
        r = self.run_c(self.d, self.shell, self.d / "o9/S2Arm.app", [c], base=self.d / "o8/S2Arm.app")
        self.assertEqual(r.returncode, 1); self.assertIn("地址空间类型不一致", r.stderr)
        self.assertIn(f"{self.A} 类型 3", r.stderr); self.assertIn(f"{self.C} 类型 1", r.stderr)
        self.assertFalse((self.d / "o9/S2Arm.app").exists())

    def test_add_game_keeps_existing_bytes(self):
        r = self.run_c(self.d, self.shell, self.d / "o3/S2Arm.app", [self.a]); self.assertEqual(r.returncode, 0, r.stderr)
        base = self.d / "o3/S2Arm.app"
        before = {p.relative_to(base).as_posix(): p.read_bytes() for p in list((base / "Games" / self.A).rglob("*")) + [base / f"Frameworks/S2AImages-{self.A}.dylib"] if p.is_file()}
        r = self.run_c(self.d, self.shell, self.d / "o4/S2Arm.app", [self.b], base=base); self.assertEqual(r.returncode, 0, r.stderr)
        app = self.d / "o4/S2Arm.app"
        after = {p.relative_to(app).as_posix(): p.read_bytes() for p in list((app / "Games" / self.A).rglob("*")) + [app / f"Frameworks/S2AImages-{self.A}.dylib"] if p.is_file()}
        self.assertEqual(after, before)                                                                     # 已有款逐字节不变
        self.assertEqual([g["title_id"] for g in json.loads((app / "s2a_catalogue.json").read_text())["games"]], [self.A, self.B])

    def test_replace_keeps_order_and_foreign_shell_refused(self):
        r = self.run_c(self.d, self.shell, self.d / "o5/S2Arm.app", [self.a, self.b]); self.assertEqual(r.returncode, 0, r.stderr)
        base = self.d / "o5/S2Arm.app"
        a2 = self.game(self.d / "v2", "a", 3, 0, 0x0100000000010000, "甲游戏新版", b"2.0.0")
        r = self.run_c(self.d, self.shell, self.d / "o6/S2Arm.app", [a2], base=base); self.assertEqual(r.returncode, 0, r.stderr)
        games = json.loads((self.d / "o6/S2Arm.app/s2a_catalogue.json").read_text())["games"]
        self.assertEqual([(g["title_id"], g["name"], g.get("display_version")) for g in games], [(self.A, "甲游戏新版", "2.0.0"), (self.B, "乙游戏", None)])
        cat = json.loads((base / "s2a_catalogue.json").read_text()); cat["shell_id"] = "0" * 16
        (base / "s2a_catalogue.json").write_text(json.dumps(cat))
        r = self.run_c(self.d, self.shell, self.d / "o7/S2Arm.app", [a2], base=base)
        self.assertEqual(r.returncode, 1); self.assertIn("要按本壳重出", r.stderr); self.assertIn(self.B, r.stderr)   # 已有款 B 是别的壳组装的：不混装


class ProgramPackTest(unittest.TestCase):
    """程序包（通用壳，ship_ext.py program）：一款程序出成 <out>/{S2AImages-<游戏号>.dylib, Games/<游戏号>/}，不签名、不写清单。
       期望不靠被测代码算：同一份产物根用现有的 container 组一次，程序包里的 dylib 与容器里 Frameworks/S2AImages-<游戏号>.dylib 逐字节相同、
       随行目录逐文件相同（同一个 place_game，只差容器自己的 launch.ctx）；目标已在报红；失败不留半个目录"""
    def setUp(self):
        self.td = tempfile.TemporaryDirectory(); self.d = Path(self.td.name)
        self.shell = ShipExtTest.shell(None, self.d)
        self.root = ContainerTest.game(None, self.d, "a", 3, 0, 0x0100000000010000, "甲游戏")

    def tearDown(self): self.td.cleanup()

    def run_p(self, root, out):
        return subprocess.run([sys.executable, str(REPO / "pack/ship_ext.py"), "program", "--shell", str(self.shell), "--root", str(root), "--out", str(out)],
                              capture_output=True, text=True)

    def test_program_matches_container_bytes(self):
        out = self.d / "p/program"
        r = self.run_p(self.root, out); self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        gid = ContainerTest.A
        self.assertEqual(json.loads(r.stdout.strip().splitlines()[-1]), {"gid": gid, "image": f"S2AImages-{gid}.dylib", "ast": 3, "name": "甲游戏", "display_version": "1.2.0"})
        self.assertEqual(sorted(p.name for p in out.iterdir()), ["Games", f"S2AImages-{gid}.dylib"])
        app = self.d / "c/S2Arm.app"
        c = ContainerTest.run_c(None, self.d, self.shell, app, [self.root]); self.assertEqual(c.returncode, 0, c.stdout + c.stderr)
        self.assertEqual((out / f"S2AImages-{gid}.dylib").read_bytes(), (app / f"Frameworks/S2AImages-{gid}.dylib").read_bytes())
        mine = {p.relative_to(out / "Games" / gid): p.read_bytes() for p in (out / "Games" / gid).rglob("*") if p.is_file()}
        theirs = {p.relative_to(app / "Games" / gid): p.read_bytes() for p in (app / "Games" / gid).rglob("*") if p.is_file() and p.name != "launch.ctx"}
        self.assertEqual(mine, theirs)   # 只差容器自己的启动上下文 launch.ctx（自动化起局用，程序包不带）
        self.assertIn(Path("main.npdm"), mine); self.assertIn(Path("main.fixups.tsv"), mine); self.assertIn(Path("addr_need.tsv"), mine); self.assertIn(Path("icon.jpg"), mine)

    def test_program_carries_save_identity_like_container(self):
        # 11-17 与 iOS 加载侧定：程序包款宿主按模块目录（program/Games/<号>/）读存档身份（ios/save_transfer.m），所以随程序包走；
        #   期望 = 同一份产物根组出的容器里 Games/<号>/save-identity.json（逐字节）；身份不合法 → 报红、不留目录
        gid = ContainerTest.A
        (self.root / "save-identity.json").write_text(json.dumps(dict(id=gid, name="甲游戏", version=65536, contentIdentity="ab" * 32)))
        out = self.d / "p/program"
        r = self.run_p(self.root, out); self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        app = self.d / "c/S2Arm.app"
        c = ContainerTest.run_c(None, self.d, self.shell, app, [self.root]); self.assertEqual(c.returncode, 0, c.stdout + c.stderr)
        self.assertEqual((out / "Games" / gid / "save-identity.json").read_bytes(), (app / "Games" / gid / "save-identity.json").read_bytes())
        (self.root / "save-identity.json").write_text(json.dumps(dict(id=gid, name="甲游戏")))
        out2 = self.d / "q/program"
        r = self.run_p(self.root, out2); self.assertNotEqual(r.returncode, 0); self.assertIn("存档游戏身份校验失败", r.stdout + r.stderr)
        self.assertFalse(out2.exists())

    def test_program_refuses_existing_and_leaves_nothing_on_failure(self):
        out = self.d / "p/program"; out.mkdir(parents=True)
        r = self.run_p(self.root, out); self.assertNotEqual(r.returncode, 0); self.assertIn("不覆盖已有目标", r.stdout + r.stderr)
        (self.root / "main.npdm").unlink(); out2 = self.d / "q/program"
        r = self.run_p(self.root, out2); self.assertNotEqual(r.returncode, 0)
        self.assertFalse(out2.exists()); self.assertFalse(any((self.d / "q").glob(".program-*")) if (self.d / "q").exists() else False)


class ShellOnlyTest(unittest.TestCase):
    """只有壳的容器（通用壳 0.6.0，container --shell-only）：期望手写——清单 games 为空、壳号 = 同一壳组的普通容器的壳号；
       App 里没有 Games/ 下任何一款、没有 Frameworks/S2AImages-*；除此之外的文件与同一壳组的普通容器同名同在；带 --game 报红"""
    def setUp(self):
        self.td = tempfile.TemporaryDirectory(); self.d = Path(self.td.name)
        self.shell = ShipExtTest.shell(None, self.d)
        self.a = ContainerTest.game(None, self.d, "a", 3, 0, 0x0100000000010000, "甲游戏")

    def tearDown(self): self.td.cleanup()

    def run_s(self, out, extra=()):
        from PIL import Image
        icon = self.d / "brand.png"
        if not icon.exists(): Image.new("RGB", (64, 64), (1, 2, 3)).save(icon)
        return subprocess.run([sys.executable, str(REPO / "pack/ship_ext.py"), "container", "--shell-only", "--shell", str(self.shell), "--out", str(out),
                               "--bundle-id", "dev.example.games", "--icon", str(icon), "--host-abi", "7", *extra], capture_output=True, text=True)

    def test_shell_only(self):
        app = self.d / "s/S2Arm.app"
        r = self.run_s(app); self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        ref = self.d / "c/S2Arm.app"
        c = ContainerTest.run_c(None, self.d, self.shell, ref, [self.a]); self.assertEqual(c.returncode, 0, c.stdout + c.stderr)
        cat, rc = (json.loads((x / "s2a_catalogue.json").read_text(encoding="utf-8")) for x in (app, ref))
        self.assertEqual(cat, dict(schema=1, shell_id=rc["shell_id"], games=[]))
        self.assertFalse(list(app.glob("Frameworks/S2AImages-*"))); self.assertFalse((app / "Games").exists() and any((app / "Games").iterdir()))
        mine = {p.relative_to(app).as_posix() for p in app.rglob("*") if p.is_file()}
        theirs = {p.relative_to(ref).as_posix() for p in ref.rglob("*") if p.is_file() and not p.relative_to(ref).as_posix().startswith(("Games/", "Frameworks/S2AImages-"))}
        self.assertEqual(mine, theirs)

    def test_shell_only_refuses_games(self):
        r = self.run_s(self.d / "x/S2Arm.app", ["--game", str(self.a)])
        self.assertNotEqual(r.returncode, 0); self.assertIn("--shell-only 只装壳", r.stdout + r.stderr)


class BannerPlaceTest(unittest.TestCase):
    """_place_banner 的联网分支打桩测（进程内直调 ship_ext，mock 掉 banner_fetch.fetch_banner，零真联网；#101 评审 1 项）。
    子进程组装测（ContainerTest）已用 S2A_BANNER_FETCH=0 + 产物根自带图保证离线确定性，这里补抓图分支本身。"""
    GID = "0100000000010000"

    def setUp(self):
        self.td = tempfile.TemporaryDirectory(); self.d = Path(self.td.name)
        self.gd = self.d / "Games" / self.GID; self.gd.mkdir(parents=True)
        self.root = self.d / "root"; self.root.mkdir()   # 无 banner.jpg 的产物根 → 逼出联网分支

    def tearDown(self): self.td.cleanup()

    def test_library_banner_copied_never_network(self):
        # 横图是游戏库的元数据（作业层导入时抓好）：给了 --banner 那份就拷；组装本身绝不联网
        from pack import ship_ext
        lib = self.d / "lib-banner.jpg"; lib.write_bytes(b"LIB")
        with mock.patch("urllib.request.urlopen", side_effect=AssertionError("组装不许联网")):
            entry = {}
            ship_ext._place_banner(self.GID, self.root, self.gd, entry, lib)
        self.assertEqual(entry.get("banner"), f"Games/{self.GID}/banner.jpg")
        self.assertEqual((self.gd / "banner.jpg").read_bytes(), b"LIB")

    def test_no_banner_anywhere_keeps_icon_only(self):
        from pack import ship_ext
        with mock.patch("urllib.request.urlopen", side_effect=AssertionError("组装不许联网")):
            entry = {}
            ship_ext._place_banner(self.GID, self.root, self.gd, entry)
        self.assertNotIn("banner", entry)
        self.assertFalse((self.gd / "banner.jpg").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
