#!/usr/bin/env python3
"""Synthetic NSO/MOD0/NPDM inputs: no proprietary files and no runtime substitutes."""
import ast
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import unittest.mock

REPO = Path(__file__).resolve().parents[1]
os.environ["S2A_DISK_FREE_G"] = "999"   # 盘判定不看本机实况：出库开工前的空间复核（pack/jobs/space_rule.py）与刷新磁盘闸都按注入余量判（11-09 门禁机余量紧时假红）
sys.path.insert(0, str(REPO / "graphics/nvn/tools"))
import direct_profile as dp

spec = importlib.util.spec_from_file_location("stage", REPO / "pack/direct_profile_stage.py")
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)
TID = "0100ABCD00000000"


def cur_of(roots, game):
    """产物根里 game 的现行版本目录：<款>@现行 是指针文件，内容 = 版本目录名（pack/orch/current.py）"""
    return (Path(roots) / (Path(roots) / f"{game}@现行").read_text(encoding="utf-8").strip()).resolve()


def lz4_literal(raw):
    """A valid LZ4 block holding raw as one literal run (no matches): the fixture needs no python-lz4, like the tools (graphics/nvn/tools/lz4blk.py)"""
    n = len(raw); out = bytearray([min(n, 15) << 4])
    if n >= 15:
        r = n - 15
        while r >= 255: out.append(255); r -= 255
        out.append(r)
    return bytes(out) + raw


def module(path, imports=("nvnBootstrapLoader",), exports=(), compressed=False, needed=(), gnu_only=False, payload=b""):
    """A real synthetic NSO with DT_HASH and valid segment hashes.
    gnu_only: no DT_HASH (newer SDK sdk / subsdk / rtld carry only DT_GNU_HASH); the symbol table then sits right before
    the strings (0x800 - 24 * 8 = 0x740, 8 entries; unused entries are zero = unnamed)."""
    img = bytearray(0x1000)
    struct.pack_into("<I", img, 4, 0x40)
    img[0x40:0x44] = b"MOD0"
    struct.pack_into("<i", img, 0x44, 0x40)
    symbols = [(x, 0) for x in imports] + [(x, 1) for x in exports]
    strings = bytearray(b"\0")
    table = bytearray(24)
    for name, defined in symbols:
        offset = len(strings); strings += name.encode() + b"\0"
        table += struct.pack("<IBBHQQ", offset, 0x10, 0, defined, 0, 0)
    needed_tags = []
    for dependency in needed:
        needed_tags.append((1, len(strings)))
        strings += dependency.encode() + b"\0"
    symtab = 0x740 if gnu_only else 0x300
    layout = [(0x6ffffef5, 0x200), (5, 0x800), (6, symtab)] if gnu_only else [(4, 0x200), (5, 0x800), (6, symtab)]
    for i, (tag, val) in enumerate(layout + [(10, len(strings)), (11, 24)] + needed_tags + [(0, 0)]):
        struct.pack_into("<qQ", img, 0x80 + 16 * i, tag, val)
    count = 1 + len(symbols)
    struct.pack_into("<II", img, 0x200, 1, count)
    assert len(table) <= 0x800 - symtab
    img[symtab:symtab+len(table)] = table
    img[0x800:0x800+len(strings)] = strings
    img[0xa00:0xa00+len(b"NintendoSDK_nnSdk-16_0_0")] = b"NintendoSDK_nnSdk-16_0_0"
    if isinstance(payload, str):
        payload = payload.encode()
    if payload:
        at = 0xb00
        if at + len(payload) > len(img):
            raise RuntimeError("payload does not fit in the synthetic text segment")
        img[at:at + len(payload)] = payload
    d = bytearray(0x100)
    d[:4] = b"NSO0"
    struct.pack_into("<I", d, 0xc, 0x38 | (7 if compressed else 0))
    d[0x40:0x60] = hashlib.sha256(path.name.encode()).digest()
    for i, raw in enumerate((bytes(img), bytes(32), bytes(32))):
        encoded = lz4_literal(raw) if compressed else raw
        struct.pack_into("<III", d, 0x10+i*16, len(d), i*0x1000, len(raw))
        struct.pack_into("<I", d, 0x60+i*4, len(encoded))
        d[0xa0+i*32:0xc0+i*32] = hashlib.sha256(raw).digest()
        d += encoded
    path.write_bytes(d)


def extraction(root, *, title=TID, compressed=False, imports=("nvnBootstrapLoader",), main_payload=b"", sdk_payload=b""):
    (root / "exefs").mkdir(parents=True)
    (root / "romfs/Data").mkdir(parents=True)
    (root / "romfs/Data/test.bnsh").write_bytes(b"BNSH" + bytes(40))
    module(root / "exefs/main", imports=imports, compressed=compressed, payload=main_payload)
    module(root / "exefs/sdk", imports=(), exports=("sdkFunction",), compressed=compressed, payload=sdk_payload)
    d = bytearray(0xc0)
    d[:4] = b"META"
    d[0xc] = 1   # 64 位指令集标志（真游戏都置；gfx_api.py 见 0 判 32 位、不支持）
    struct.pack_into("<II", d, 0x70, 0x80, 0x40)
    d[0x80:0x84] = b"ACI0"
    struct.pack_into("<Q", d, 0x90, int(title, 16))
    (root / "exefs/main.npdm").write_bytes(d)
    (root / "unpack.tsv").write_text("title_id\t" + title.lower() + "\ndisplay_version\t1.1.0\nupdate\t65536\n")


def tsv_rows(text, key):
    """Non-comment values for key. Exact column match, same as s2a_game_tsv_find: present_interval_derived is not present_interval."""
    rows = []
    for line in text.splitlines():
        p = line
        # 空串是任何字符串的子串，不能用 `p[:1] in whitespace` 剥空行。
        while p and p[0] in " \t\r":
            p = p[1:]
        if not p or p[0] == "#":
            continue
        tab = p.find("\t")
        col = p if tab < 0 else p[:tab]
        while col and col[-1] in " \r":
            col = col[:-1]
        if col != key:
            continue
        val = "" if tab < 0 else p[tab + 1:]
        nxt = val.find("\t")
        if nxt >= 0:
            val = val[:nxt]
        while val and val[0] in " \r":
            val = val[1:]
        while val and val[-1] in " \r":
            val = val[:-1]
        rows.append(val)
    return rows


def present_decide_inputs(text):
    """(explicit_set, explicit_display, derived_display) for s2a_present_decide, read off game.tsv the way host_adapt.m does."""
    explicit = tsv_rows(text, "present_interval")
    derived = tsv_rows(text, "present_interval_derived")
    explicit_set = 1 if explicit else 0
    explicit_display = 1 if explicit[:1] == ["display"] else 0
    derived_display = 1 if derived[:1] == ["display"] else 0
    return explicit_set, explicit_display, derived_display


def present_decide(explicit_set, explicit_display, derived_display, l3_result):
    """Transcription of graphics/nvn/host/game_tsv.h s2a_present_decide. The expected number is this function, not the writer."""
    if explicit_set:
        return explicit_display
    if not derived_display:
        return 0
    return 1 if l3_result == "ok" else 0


class Profiles(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()   # macOS: /var is /private/var; the code under test compares resolved paths
        # 内存准入账本隔离（11-04）：refresh.sh 真 source tools/mem_admit.sh，缺省记进运行区共享账本 locks/mem，
        #   旧树按估值表 dsh * 50 给 dsh/fixture 预留 50 GB、把真出库排在后面；单测一律用本用例自己的账本
        mem = self.base / "mem"; mem.mkdir()
        # 11-05 维护者：刷新锁、运行区、HOME 也一律指本用例临时目录（原先 refresh.sh 缺省往真实 ~/.s2arm/run/s2arm/locks 写 refresh_fixture 锁）；
        #   收尾断言真实运行区没被写：没有新的 refresh_fixture 锁、真实内存账本没有新的 dsh/fixture 行
        home = self.base / "home"; home.mkdir(); (self.base / "locks").mkdir(); (self.base / "run").mkdir()
        real_run = Path(os.path.expanduser("~/.s2arm/run/s2arm"))
        real_locks = sorted(p.name for p in (real_run / "locks").glob("refresh_fixture*")) if (real_run / "locks").is_dir() else []
        real_log = real_run / "locks" / "mem" / "admit.log"
        real_n = real_log.read_text(errors="replace").count("dsh/fixture") if real_log.exists() else 0
        envp = unittest.mock.patch.dict(os.environ, {"S2A_MEM_DIR": str(mem), "S2A_MEM_LOCK": str(self.base / "mem.flock"),
                                                     "S2A_REFRESH_LOCKS": str(self.base / "locks"), "S2A_RUN_ROOT": str(self.base / "run"),
                                                     "HOME": str(home)})
        envp.start(); self.addCleanup(envp.stop)
        def real_untouched():
            now_locks = sorted(p.name for p in (real_run / "locks").glob("refresh_fixture*")) if (real_run / "locks").is_dir() else []
            now_n = real_log.read_text(errors="replace").count("dsh/fixture") if real_log.exists() else 0
            self.assertEqual((now_locks, now_n), (real_locks, real_n), "单测写进了真实运行区（refresh_fixture 锁 / 内存账本 dsh/fixture 行）")
        self.addCleanup(real_untouched)
        self.root = self.base / "input"
        extraction(self.root)
        self.out = self.base / "profiles"

    def generate(self, **kwargs):
        return dp.prepare(self.root, self.out, version="v65536", **kwargs)

    def edit_main(self, offset, value):
        p = self.root / "exefs/main"
        d = bytearray(p.read_bytes())
        struct.pack_into("<I", d, offset, value)
        p.write_bytes(d)

    def reject(self):
        with self.assertRaises((dp.Invalid, OSError, RuntimeError, KeyError)):
            self.generate()
        self.assertFalse((self.out / TID).exists())

    def test_profile_key_ignores_reports_tracks_build_files(self):
        # 直连阶段键里的推导档内容键：推导报告（含推导脚本哈希）变了键不变，出库读的档文件变一个字节键就变（期望按规则手写）
        d = self.base / "keyprof"; d.mkdir()
        (d / "game.tsv").write_text("title_id\t" + TID + "\n"); (d / "shader_map.tsv").write_text("# empty\n")
        (d / "survey.json").write_text('{"provenance": {"rules": {"direct_profile.py": "aaaa"}}}'); (d / "survey.md").write_text("report\n")
        k0 = stage.profile_key(d)
        (d / "survey.json").write_text('{"provenance": {"rules": {"direct_profile.py": "bbbb"}}}'); (d / "survey.md").write_text("report changed\n")
        self.assertEqual(k0, stage.profile_key(d))
        (d / "shader_map.tsv").write_text("# empty \n")
        self.assertNotEqual(k0, stage.profile_key(d))

    def test_real_uncompressed_nso_to_loadable_provisional(self):
        result = self.generate()
        g = dp.game.Game(result["profile"])
        self.assertEqual(g.get("modules"), "main sdk")
        self.assertEqual(g.get("program_id"), TID)
        self.assertEqual(g.get("package"), "v65536")
        self.assertIn("DM_GAME_APP_POOL", dp.game.header(g))
        report = json.loads((Path(result["profile"]) / "survey.json").read_text())
        self.assertFalse(report["runtime_verified"])
        self.assertIn("tex_dirty_upload", report["unknown"])
        self.assertIn("main", report["facts"]["mods"])
        self.assertTrue((Path(result["profile"]) / "survey.md").is_file())

    def test_generated_upload_defaults_reach_final_tsv_and_header(self):
        result = self.generate()
        directory = Path(result["profile"])
        g = dp.game.Game(directory)
        text = (directory / "game.tsv").read_text()
        for key in ("tex_flush_upload", "tex_dirty_upload"):
            self.assertEqual(g.get(key, "off"), "on")
            self.assertIn(key + "\ton\n", text)
        header = dp.game.header(g)
        self.assertIn("#define DM_GAME_TEX_FLUSH_UPLOAD 1", header)
        self.assertIn("#define DM_GAME_TEX_DIRTY_UPLOAD 1", header)

    def test_upload_policy_report_separates_defaults_from_static_guesses(self):
        directory = Path(self.generate()["profile"])
        report = json.loads((directory / "survey.json").read_text())
        markdown = (directory / "survey.md").read_text()
        self.assertTrue(report["provisional"])
        self.assertFalse(report["runtime_verified"])
        for key in ("tex_flush_upload", "tex_dirty_upload"):
            item = report["defaults"][key]
            self.assertEqual(item["value"], "on")
            self.assertEqual(item["origin"], "default-not-inferred")
            self.assertIn("默认值，非静态推断", item["reason"])
            self.assertNotIn(key, report["guesses"])
            self.assertIn(key, report["unknown"])
            self.assertIn(key + ": on", markdown)
        self.assertIn("临时档默认值（非静态推断）", markdown)

    def test_policy_change_refreshes_stage_key_and_preserves_old_output(self):
        current = dp.PROFILE_POLICY["version"]
        try:
            dp.PROFILE_POLICY["version"] = current - 1
            previous = stage.plan(self.root)
            old = stage.select(self.root, self.out / previous["key"])
        finally:
            dp.PROFILE_POLICY["version"] = current
        old_dir = Path(old["profile"])
        before = {p.name: p.read_bytes() for p in old_dir.iterdir()}
        updated = stage.plan(self.root)
        self.assertNotEqual(previous["key"], updated["key"])
        new = stage.select(self.root, self.out / updated["key"])
        self.assertFalse(new["reused"])
        for key in dp.PROFILE_POLICY["defaults"]:
            self.assertEqual(dp.game.Game(new["profile"]).get(key), "on")
        with self.assertRaisesRegex(dp.Invalid, "different inputs/version"):
            dp.prepare(self.root, old_dir.parent, version="v65536", display="1.1.0")
        self.use_external(old_dir.parent)
        with self.assertRaisesRegex(dp.Invalid, "different inputs/version"):
            stage.select(self.root, self.base / "external-copy")
        self.assertFalse((self.base / "external-copy").exists())
        self.assertEqual(before, {p.name: p.read_bytes() for p in old_dir.iterdir()})

    def test_manual_disabled_uploads_in_generated_profile_are_preserved(self):
        first = self.generate()
        directory = Path(first["profile"])
        path = directory / "game.tsv"
        text = path.read_text()
        for key in ("tex_flush_upload", "tex_dirty_upload"):
            text = text.replace(key + "\ton", key + "\toff")
        path.write_text(text)
        before = {p.name: p.read_bytes() for p in directory.iterdir()}
        self.assertTrue(self.generate()["reused"])
        self.assertEqual(before, {p.name: p.read_bytes() for p in directory.iterdir()})
        self.use_external(directory.parent)
        # Match the metadata used by generate(), not unpack.tsv's display.
        selected = stage.select(self.root, self.base / "snapshot", display="unknown")
        self.assertTrue(selected["provisional"])
        self.assertEqual(path.read_bytes(), (Path(selected["profile"]) / "game.tsv").read_bytes())
        header = dp.game.header(dp.game.Game(selected["profile"]))
        self.assertIn("#define DM_GAME_TEX_FLUSH_UPLOAD 0", header)
        self.assertIn("#define DM_GAME_TEX_DIRTY_UPLOAD 0", header)

    def test_update_changes_key_and_generates_new_policy_profile(self):
        first_plan = stage.plan(self.root)
        first = stage.select(self.root, self.out / first_plan["key"])
        old_path = Path(first["profile"]) / "game.tsv"
        before = old_path.read_bytes()
        (self.root / "unpack.tsv").write_text("title_id\t" + TID + "\nupdate\t131072\n")
        second_plan = stage.plan(self.root)
        self.assertNotEqual(first_plan["key"], second_plan["key"])
        second = stage.select(self.root, self.out / second_plan["key"])
        g = dp.game.Game(second["profile"])
        self.assertEqual(g.get("package"), "v131072")
        for key in dp.PROFILE_POLICY["defaults"]:
            self.assertEqual(g.get(key), "on")
        self.assertEqual(before, old_path.read_bytes())

    def test_report_fingerprint_includes_actual_rule_hashes_and_policy(self):
        report = json.loads((Path(self.generate()["profile"]) / "survey.json").read_text())
        source = report["provenance"]
        self.assertEqual(source["policy"], dp.PROFILE_POLICY)
        self.assertEqual(report["fingerprint"],
                         hashlib.sha256(json.dumps(source, sort_keys=True).encode()).hexdigest())
        for name, value in source["rules"].items():
            path = dp.NX / "games" / name if name in ("game.py", "profile_guess.py") else dp.HERE / name
            self.assertEqual(value, dp.file_digest(path))

    def test_unreal4_marker_needs_word_start(self):
        # 11-16 出包提速：「Unreal 4」特征从带后顾断言的正则换成字节查找 + 看前一个字节（逐字等价 (?<![A-Za-z])UE4）。期望手写：
        #   VALUE4（暗黑3 main 里的误报源）不算；UE4Game / 开头的 UE4 / 前面是 _ 或 . 的算；只出现在字母后面的不算，后面又有一处独立的就算
        sys.path.insert(0, str(REPO / "graphics/nvn/games")); sys.path.insert(0, str(REPO / "graphics/nvn/tools"))
        import profile_guess as g
        pat = next(p for p, name in g.MARKERS if name == "Unreal 4")
        cases = [(b"xx VALUE4 yy", False), (b"UE4Game", True), (b"UE4", True), (b"_UE4", True), (b"aUE4 bUE4", False), (b"aUE4 .UE4", True), (bytearray(b"\x00UE4"), True)]
        self.assertEqual([g.hit(pat, img) for img, _ in cases], [want for _, want in cases])

    def test_compressed_segments_and_hashes(self):
        shutil.rmtree(self.root)
        extraction(self.root, compressed=True)
        self.generate()

    def test_switch2_flag_0x40_read_zbic_red(self):
        # Splatoon Raiders（SDK 21.4）main 头标志 0x7f：比 0x3f（三段 LZ4 + 校验）多 0x40，段解码不变；
        # 0x80 = 段压缩方式是 ZBIC（事实取自 Eden-NS2 nso.h），经 tools/nso_plain.py 交 nx_unpack 解；这里段是 LZ4 不是 ZBIC 帧，必须报红
        shutil.rmtree(self.root)
        extraction(self.root, compressed=True)
        self.edit_main(0xc, 0x7f)
        self.generate()
        shutil.rmtree(self.out)
        self.edit_main(0xc, 0xff)
        self.reject()

    def test_idempotent_and_preserves_manual_edits(self):
        first = self.generate()
        p = Path(first["profile"]) / "game.tsv"
        p.write_text(p.read_text() + "\nrender_cond\ton\n")
        before = {f.name: f.read_bytes() for f in p.parent.iterdir()}
        self.assertTrue(self.generate()["reused"])
        self.assertEqual(before, {f.name: f.read_bytes() for f in p.parent.iterdir()})

    def test_changed_inputs_refuse_to_reuse(self):
        self.generate()
        p = self.root / "exefs/main"
        d = bytearray(p.read_bytes()); d[0x40] ^= 1; p.write_bytes(d)
        with self.assertRaisesRegex(dp.Invalid, "different inputs"):
            self.generate()

    def test_metadata_change_never_reuses_stale_profile(self):
        self.generate(display="1.1.0", name="Synthetic")
        with self.assertRaisesRegex(dp.Invalid, "different inputs"):
            self.generate(display="1.2.0", name="Synthetic")
        with self.assertRaisesRegex(dp.Invalid, "different inputs"):
            self.generate(display="1.1.0", name="Renamed")

    def test_cache_fingerprint_covers_reader_and_schema(self):
        p = Path(self.generate()["profile"]) / "survey.json"
        rules = json.loads(p.read_text())["provenance"]["rules"]
        self.assertIn("nso_syms.py", rules)
        self.assertIn("game.py", rules)

    def test_manual_profile_no_provenance_preserved(self):
        self.generate()
        p = self.out / TID
        (p / "survey.json").unlink()
        content = (p / "game.tsv").read_bytes()
        with self.assertRaisesRegex(dp.Invalid, "no survey provenance"):
            self.generate()
        self.assertEqual(content, (p / "game.tsv").read_bytes())

    def test_no_main(self):
        (self.root / "exefs/main").unlink()
        self.reject()

    def test_truncated_header(self):
        (self.root / "exefs/main").write_bytes(b"NSO0")
        self.reject()

    def test_invalid_file_range(self):
        self.edit_main(0x10, 0xfffffff0)
        self.reject()

    def test_oversized_image_no_allocation(self):
        self.edit_main(0x34, 0x7ffff000)
        self.reject()

    def test_bad_hash(self):
        p = self.root / "exefs/main"
        d = bytearray(p.read_bytes()); d[0x110] ^= 1; p.write_bytes(d)
        self.reject()

    def test_invalid_dynamic_layout(self):
        # Clear hash checking so the dynamic reader itself must reject this pointer.
        self.edit_main(0xc, 0)
        self.edit_main(0x104, 0xfffffff0)
        self.reject()

    def test_gnu_hash_only_modules_are_read(self):
        # 10-25 动森 / 塞尔达 / 丝之歌：sdk / subsdk / rtld 只有 DT_GNU_HASH，原先整款拒绝。期望：照常推导，sdk 的导出照读到
        module(self.root / "exefs/sdk", imports=(), exports=("sdkFunction",), gnu_only=True)
        self.generate()
        report = json.loads((self.out / TID / "survey.json").read_text())
        self.assertEqual(report["facts"]["mods"]["sdk"]["exports"], ["sdkFunction"])

    def test_gnu_hash_symbols_must_sit_before_strings(self):
        # 没有 DT_HASH 时符号数 = (STRTAB - SYMTAB) / 24：两表之间不是 24 的整数倍就拒绝（不按错位的表读符号）
        img = bytearray(0x1000)
        struct.pack_into("<I", img, 4, 0x40); img[0x40:0x44] = b"MOD0"; struct.pack_into("<i", img, 0x44, 0x40)
        for i, (tag, val) in enumerate([(0x6ffffef5, 0x200), (5, 0x800), (6, 0x741), (10, 1), (11, 24), (0, 0)]):
            struct.pack_into("<qQ", img, 0x80 + 16 * i, tag, val)
        with self.assertRaisesRegex(dp.Invalid, "before strings"):
            dp.validate_symbols(bytes(img))
        struct.pack_into("<qQ", img, 0x80 + 32, 6, 0x740)   # 对齐后照常通过
        dp.validate_symbols(bytes(img))

    def test_nacp_identity_without_unpack_tsv(self):
        # 播种的产物根只带 ctl/control.nacp、没有 unpack.tsv：名字取第一个非空语言项，显示版本取 +0x3060
        (self.root / "unpack.tsv").unlink()
        nacp = bytearray(0x4000)
        nacp[0x300:0x300 + 9] = b"Test Game"          # 项 0 空，项 1 有名字
        nacp[0x3060:0x3065] = b"2.0.1"
        (self.root / "ctl").mkdir(); (self.root / "ctl/control.nacp").write_bytes(nacp)
        opts = stage.options(self.root, TID, "v65536", None, None)
        self.assertEqual((opts["name"], opts["display"]), ("Test Game", "2.0.1"))

    def test_invalid_npdm(self):
        (self.root / "exefs/main.npdm").write_bytes(bytes(0x80))
        self.reject()

    def test_mismatched_identity(self):
        with self.assertRaisesRegex(dp.Invalid, "differs"):
            self.generate(title="0100111122220000")

    def test_no_nvn_never_assumes_supported(self):
        module(self.root / "exefs/main", imports=("vkCreateInstance",))
        self.reject()

    def test_nvn_export_is_not_an_import(self):
        module(self.root / "exefs/main", imports=(), exports=("nvnBootstrapLoader",))
        self.reject()

    def test_stage_cli_gap_yellow_invalid_red(self):
        # 10-25 维护者：本款用了直连还没实现的结构（内容缺口）→ 阶段退 3、【黄】「直连缺口」，refresh 走通用；输入坏了（Invalid）→ 退 1、【红】
        module(self.root / "exefs/main", imports=("vkCreateInstance",))
        p = subprocess.run([sys.executable, str(REPO / "pack/direct_profile_stage.py"), str(self.root), "--out", str(self.out), "--version", "v65536"], capture_output=True, text=True)
        self.assertEqual((p.returncode, p.stdout), (3, ""), p.stderr)
        self.assertIn("【黄】直连缺口：配置推导不支持本款", p.stderr)
        (self.root / "exefs/main").write_bytes(b"NSO0")
        p = subprocess.run([sys.executable, str(REPO / "pack/direct_profile_stage.py"), str(self.root), "--out", str(self.out), "--version", "v65536"], capture_output=True, text=True)
        self.assertEqual((p.returncode, p.stdout), (1, ""), p.stderr)
        self.assertIn("【红】", p.stderr)

    def test_romfs_names_cannot_inject_profile_keys(self):
        for name in ("bad\nrender_cond\ton", "bad group", "bad=group"):
            with self.subTest(name=name):
                directory = self.root / "romfs" / name
                directory.mkdir()
                (directory / "file").write_bytes(b"x")
                self.reject()
                shutil.rmtree(directory)

    def test_missing_romfs(self):
        shutil.rmtree(self.root / "romfs")
        self.reject()

    def test_manifest_matches_directory(self):
        manifest = self.base / "romfs.tsv"
        p = self.root / "romfs/Data/test.bnsh"
        manifest.write_text("/Data/test.bnsh\t44\t" + p.read_bytes()[:32].hex() + "\n")
        _, a = dp.input_facts(self.root)
        _, b = dp.input_facts(self.root, manifest)
        self.assertEqual(dp.clean(a), dp.clean(b))
        self.generate(manifest=manifest)

    def test_bad_manifest_cases(self):
        for line in ("/x\t-1\t", "/../x\t3\t", "/x\t3\t00ffgg",
                     "/x\t1\t0000", "/x\t1\t00\n/x\t1\t00"):
            with self.subTest(line=line):
                p = self.base / "manifest.tsv"; p.write_text(line + "\n")
                with self.assertRaises(dp.Invalid):
                    self.generate(manifest=p)
        self.assertFalse((self.out / TID).exists())

    def test_output_source_and_raw_input_are_protected(self):
        for out in (REPO / "build/auto-profile", self.root / "exefs/auto",
                    self.root / "romfs/auto", self.root / "aoc/auto"):
            with self.subTest(out=out), self.assertRaisesRegex(dp.Invalid, "outside"):
                dp.prepare(self.root, out, version="v65536")

    def test_artifact_profile_beside_input_is_allowed(self):
        dp.prepare(self.root, self.root / "direct-profile", version="v65536")

    def test_compare_all_keys_and_explicit_unknowns(self):
        a = Path(self.generate()["profile"])
        b = self.base / "reference"; shutil.copytree(a, b)
        p = b / "game.tsv"
        p.write_text(p.read_text().replace("app_pool\t0xCD500000", "app_pool\t3444572160")
                     + "\nrender_cond\ton\n")
        report = dp.compare(a, b)
        rows = {r["key"]: r for r in report["rows"]}
        self.assertEqual(rows["app_pool"]["status"], "match")
        self.assertEqual(rows["render_cond"]["status"], "missing")
        self.assertFalse(report["runtime_verified"])

    def test_stage_unregistered_prepares_no_runtime_claim(self):
        report = stage.select(self.root, self.out)
        self.assertEqual(report["source"], "generated")
        self.assertFalse(report["runtime_verified"])
        self.assertEqual(report["DM_GAMES_DIR"], str(self.out))

    def test_stage_registered_preserves_profile(self):
        # Real repository reference, synthetic executable; NOT an accuracy measurement.
        tid = "01006F8002326000"
        shutil.rmtree(self.root); extraction(self.root, title=tid)
        selected = dp.NX / "games" / tid / "game.tsv"
        before = selected.read_bytes()
        report = stage.select(self.root, self.out)
        self.assertFalse(report["provisional"])
        self.assertFalse(self.out.exists())
        self.assertEqual(before, selected.read_bytes())

    def test_stage_actual_update_metadata_and_conflict(self):
        result = stage.select(self.root, self.out)
        report = json.loads((Path(result["profile"]) / "survey.json").read_text())
        self.assertEqual(report["version"], "v65536")
        self.assertEqual(report["display"], "1.1.0")
        with self.assertRaisesRegex(dp.Invalid, "differs"):
            stage.select(self.root, self.out, version="v131072")

    def test_base_version_not_invented_from_empty_update(self):
        p = self.root / "unpack.tsv"
        p.write_text("title_id\t" + TID + "\nupdate\t\n")
        with self.assertRaisesRegex(dp.Invalid, "content version"):
            stage.select(self.root, self.out)
        stage.select(self.root, self.out, version="v0")

    def test_base_only_without_sidecar_uses_base_version(self):
        # #36：Mac 打包不写旁注，只有本体的游戏。手算期望：update 空、base=4096 → v4096
        (self.root / "unpack.tsv").write_text("title_id\t" + TID + "\nupdate\t\nbase\t4096\n")
        (self.root / "direct-profile-input.json").unlink(missing_ok=True)
        self.assertEqual(stage.options(self.root, TID, None, None, None)["version"], "v4096")

    def test_stage_metadata_identity_and_duplicates_reject(self):
        p = self.root / "unpack.tsv"
        for text in ("title_id\t0100000000000000\nupdate\t65536\n",
                     "update\t65536\nupdate\t131072\n"):
            p.write_text(text)
            with self.assertRaises(dp.Invalid):
                stage.select(self.root, self.out)
        self.assertFalse(self.out.exists())

    def test_stage_cannot_invent_content_version(self):
        (self.root / "unpack.tsv").unlink()
        with self.assertRaisesRegex(dp.Invalid, "content version"):
            stage.select(self.root, self.out)

    def test_cli_failure_nonzero_no_stdout(self):
        (self.root / "exefs/main").write_bytes(b"NSO0")
        p = subprocess.run([sys.executable, str(REPO / "graphics/nvn/tools/direct_profile.py"),
                            "generate", str(self.root), "--out", str(self.out),
                            "--version", "v65536"], capture_output=True, text=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")
        self.assertIn("拒绝", p.stderr)

    def test_module_dependency_never_pruned_by_upstream_hooks(self):
        module(self.root / "exefs/main",
               imports=("nvnBootstrapLoader", "_ZN2nn2os17SetMemoryHeapSizeEm"))
        module(self.root / "exefs/subsdk0", imports=(),
               exports=("_ZN2nn2os17SetMemoryHeapSizeEm",))
        result = self.generate()
        g = dp.game.Game(result["profile"])
        report = json.loads((Path(result["profile"]) / "survey.json").read_text())
        self.assertEqual(g.get("modules"), "main subsdk0 sdk")
        self.assertEqual(g.get("modules"), report["guesses"]["modules"][0])

    def test_repeatable_needed_metadata_not_rejected_as_ambiguous_layout(self):
        module(self.root / "exefs/main", needed=("libsdk.so", "libsubsdk.so"))
        self.generate()

    def test_duplicate_layout_pointer_still_rejected(self):
        p = self.root / "exefs/main"
        data = bytearray(p.read_bytes())
        struct.pack_into("<qQ", data, 0x1d0, 6, 0x300)
        struct.pack_into("<qQ", data, 0x1e0, 0, 0)
        data[0xa0:0xc0] = hashlib.sha256(data[0x100:0x1100]).digest()
        p.write_bytes(data)
        self.reject()

    def test_unknown_dynamic_count_rejected(self):
        self.edit_main(0xc, 0)
        self.edit_main(0x304, dp.MAX_SYMBOLS + 1)
        self.reject()

    def test_unterminated_symbol_rejected(self):
        self.edit_main(0xc, 0)
        self.edit_main(0x418, 0xfffffff0)
        self.reject()

    def test_source_files_unchanged_and_no_host_hook_scan(self):
        before = {p.name: p.read_bytes() for p in (self.root / "exefs").iterdir()}
        original = dp.pg.host_hooks
        def forbidden():
            raise AssertionError("upstream host hooks used")
        dp.pg.host_hooks = forbidden
        try:
            self.generate()
        finally:
            dp.pg.host_hooks = original
        self.assertEqual(before, {p.name: p.read_bytes() for p in (self.root / "exefs").iterdir()})

    def test_shell_stage_json_and_failure_exit(self):
        env = dict(os.environ, S2A_PYTHON=sys.executable)
        cmd = ["bash", str(REPO / "pack/stage_direct_profile.sh"), str(self.root), str(self.out)]
        p = subprocess.run(cmd, env=env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)["source"], "generated")
        (self.root / "exefs/main").unlink()
        # Existing registered profiles need no static resurvey; generated ones
        # are rechecked against their input by the stage.
        p = subprocess.run(cmd, env=env, capture_output=True, text=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")

    def use_external(self, directory):
        previous = os.environ.get("DM_GAMES_DIR")
        os.environ["DM_GAMES_DIR"] = str(directory)
        def restore():
            if previous is None:
                os.environ.pop("DM_GAMES_DIR", None)
            else:
                os.environ["DM_GAMES_DIR"] = previous
        self.addCleanup(restore)

    def test_external_generated_stale_is_rejected_not_promoted(self):
        first = stage.select(self.root, self.out)
        self.use_external(first["DM_GAMES_DIR"])
        p = self.root / "exefs/main"
        data = bytearray(p.read_bytes()); data[0x40] ^= 1; p.write_bytes(data)
        (self.root / "unpack.tsv").write_text("title_id\t" + TID + "\nupdate\t131072\n")
        with self.assertRaisesRegex(dp.Invalid, "different inputs/version"):
            stage.select(self.root, self.base / "second")
        self.assertFalse((self.base / "second").exists())
        self.assertEqual(dp.game.Game(first["profile"]).get("package"), "v65536")

    def test_external_generated_still_provisional_and_manual_edits_snapshotted(self):
        first = stage.select(self.root, self.out)
        game_file = Path(first["profile"]) / "game.tsv"
        game_file.write_text(game_file.read_text() + "\nrender_cond\ton\n")
        self.use_external(first["DM_GAMES_DIR"])
        selected = stage.select(self.root, self.base / "second")
        self.assertTrue(selected["provisional"])
        self.assertFalse(selected["runtime_verified"])
        self.assertEqual(selected["source"], "generated")
        self.assertEqual(game_file.read_bytes(), (Path(selected["profile"]) / "game.tsv").read_bytes())

    def test_generated_marker_without_provenance_never_becomes_manual(self):
        first = stage.select(self.root, self.out)
        self.use_external(first["DM_GAMES_DIR"])
        (Path(first["profile"]) / "survey.json").unlink()
        with self.assertRaisesRegex(dp.Invalid, "no survey provenance"):
            stage.select(self.root, self.base / "second")

    def test_external_manual_is_distinct_and_consumer_not_assumed(self):
        first = stage.select(self.root, self.out)
        profile = Path(first["profile"])
        (profile / "survey.json").unlink()
        p = profile / "game.tsv"
        text = p.read_text().replace("# Provisional game profile", "# Manually maintained profile", 1)
        for key in ("tex_flush_upload", "tex_dirty_upload"):
            text = text.replace(key + "\ton", key + "\toff")
        p.write_text(text)
        before = p.read_bytes()
        self.use_external(first["DM_GAMES_DIR"])
        selected = stage.select(self.root, self.base / "second")
        self.assertEqual(selected["source"], "external-manual")
        self.assertEqual(before, p.read_bytes())
        for key in ("tex_flush_upload", "tex_dirty_upload"):
            self.assertEqual(dp.game.Game(selected["profile"]).get(key), "off")
        self.assertFalse(selected["provisional"])
        self.assertFalse(selected["runtime_verified"])
        self.assertFalse((self.base / "second").exists())

    def test_generated_snapshot_output_protected(self):
        first = stage.select(self.root, self.out)
        self.use_external(first["DM_GAMES_DIR"])
        for out in (REPO / "build/auto-profile", self.root / "romfs/auto"):
            with self.subTest(out=out), self.assertRaisesRegex(dp.Invalid, "outside"):
                stage.select(self.root, out)

    def test_corrupt_named_sdk_never_disappears(self):
        module(self.root / "exefs/main", imports=("nvnBootstrapLoader", "sdkFunction"))
        (self.root / "exefs/sdk").write_bytes(b"NSO")
        self.reject()

    def test_corrupt_named_subsdk_never_disappears(self):
        module(self.root / "exefs/main", imports=("nvnBootstrapLoader", "subsdkFunction"))
        (self.root / "exefs/subsdk0").write_bytes(b"BAD!")
        self.reject()

    def test_named_module_directory_rejected(self):
        (self.root / "exefs/sdk").unlink()
        (self.root / "exefs/sdk").mkdir()
        self.reject()

    def picker(self, packages):
        """跑一键出包「从原件认」的共用模块 pack/source_pick.py（Mac oneclick.sh 与 Windows oneclick_win.py 同调它；原先是 oneclick.sh 里的内联 Python），返回 stdout 行。
        版本旁注不再由它写（算法搬到 pack/direct_profile_input.py，只按解包产物算），这里只说认游戏的结果。"""
        directory = self.base / "inspect"
        directory.mkdir(exist_ok=True)
        (directory / "idx").write_text("1\tsynthetic.nsp\n")
        (directory / "i1.json").write_text(json.dumps({"packages": packages}))
        self.assertIn('python3 "$P/source_pick.py" "$TMP"', (REPO / "pack/oneclick/oneclick.sh").read_text())   # 一键出包确实调它
        result = subprocess.run([sys.executable, str(REPO / "pack/source_pick.py"), str(directory)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def sidecar(self, text):
        """按解包目录的 unpack.tsv 跑共享算法（pack/direct_profile_input.py），返回写出的旁注。"""
        root = self.base / "sidecar-root"
        if root.exists():
            shutil.rmtree(root)
        root.mkdir()
        (root / "unpack.tsv").write_text(text)
        result = subprocess.run([sys.executable, str(REPO / "pack/direct_profile_input.py"), str(root)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads((root / "direct-profile-input.json").read_text())

    def test_actual_oneclick_picker_selects_base_and_latest_update(self):
        base = {"baseId": TID, "type": "base", "version": 7,
                "guestIsa": "aarch64", "name": "Synthetic", "display": "1.0"}
        lines = self.picker([base])
        self.assertEqual(lines[0], TID)
        self.assertEqual(lines[1], "Synthetic")
        self.assertEqual(lines[2], "1.0")
        updates = [dict(base, type="update", version=v, display=display)
                   for v, display in ((65536, "1.1"), (131072, "1.2"))]
        lines = self.picker([base] + updates)
        self.assertEqual(lines[0], TID)
        self.assertEqual(lines[2], "1.2")   # 显示版本取最新更新
        self.assertTrue(any(line.endswith("synthetic.nsp") for line in lines[4:]))

    def test_sidecar_base_only_package_uses_base_version(self):
        # 只有本体、没有更新的款（11-03 御天之剑HD）：content_version = 本体 CNMT 版本，不是显示版本、不是 0
        data = self.sidecar("title_id\t" + TID.lower() + "\nname\tBase Only\ndisplay_version\t9.9.9\nupdate\t\nbase\t4096\n")
        self.assertEqual(data, {"format": 1, "title_id": TID, "content_version": 4096,
                                "display": "9.9.9", "name": "Base Only"})

    def test_sidecar_prefers_latest_update_version(self):
        data = self.sidecar("title_id\t" + TID + "\nname\tUpdated\ndisplay_version\t1.2\nupdate\t131072\nbase\t7\n")
        self.assertEqual(data["content_version"], 131072)

    def test_sidecar_without_any_version_rejected_not_zeroed(self):
        root = self.base / "sidecar-root"
        root.mkdir()
        (root / "unpack.tsv").write_text("title_id\t" + TID + "\ndisplay_version\t1.0\n")
        result = subprocess.run([sys.executable, str(REPO / "pack/direct_profile_input.py"), str(root)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("没有更新也没有本体内容版本", result.stderr)
        self.assertFalse((root / "direct-profile-input.json").exists())

    def test_sidecar_keeps_existing_and_rejects_duplicates(self):
        root = self.base / "sidecar-root"
        root.mkdir()
        (root / "unpack.tsv").write_text("title_id\t" + TID + "\nbase\t7\n")
        (root / "direct-profile-input.json").write_text('{"format": 1, "title_id": "KEEP"}')
        subprocess.run([sys.executable, str(REPO / "pack/direct_profile_input.py"), str(root)], check=True)
        self.assertEqual((root / "direct-profile-input.json").read_text(), '{"format": 1, "title_id": "KEEP"}')
        (root / "direct-profile-input.json").unlink()
        (root / "unpack.tsv").write_text("title_id\t" + TID + "\nbase\t7\nbase\t8\n")
        result = subprocess.run([sys.executable, str(REPO / "pack/direct_profile_input.py"), str(root)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("重复", result.stderr)

    def test_inspected_base_version_used_and_conflicts_rejected(self):
        (self.root / "unpack.tsv").write_text("title_id\t" + TID + "\nupdate\t\n")
        sidecar = self.root / "direct-profile-input.json"
        data = {"format": 1, "title_id": TID, "content_version": 7,
                "display": "1.0", "name": "Synthetic"}
        sidecar.write_text(json.dumps(data))
        report = stage.select(self.root, self.out)
        self.assertEqual(dp.game.Game(report["profile"]).get("package"), "v7")
        (self.root / "unpack.tsv").write_text("update\t65536\n")
        with self.assertRaisesRegex(dp.Invalid, "differs"):
            stage.select(self.root, self.base / "second")

    def test_invalid_inspected_version_or_identity_rejected(self):
        sidecar = self.root / "direct-profile-input.json"
        for data in ({"format": 1, "title_id": "0100000000000000", "content_version": 65536},
                     {"format": 1, "title_id": TID, "content_version": True},
                     {"format": 1, "title_id": TID, "content_version": -1}):
            with self.subTest(data=data):
                sidecar.write_text(json.dumps(data))
                with self.assertRaises(dp.Invalid):
                    stage.select(self.root, self.out)
        self.assertFalse(self.out.exists())

    def seed(self, dual):
        roots = self.base / ("seed-dual" if dual else "seed-generic")
        env = dict(os.environ, S2A_DISK_FREE_G="999", S2A_ROOTS=str(roots), S2A_ROOTS_SHARED=str(self.base / "shared"),   # 盘判定不看本机实况
                   S2A_ROOTS_PRIV=str(self.base / "private"), S2A_ROOTS_NO_BOOT="1",
                   S2A_DUAL="1" if dual else "0", S2A_PYTHON=sys.executable,
                   PATH=str(Path(sys.executable).parent) + os.pathsep + os.environ["PATH"])
        result = subprocess.run(["bash", str(REPO / "pack/seed_root.sh"), "fixture", "seed", str(self.root)],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return cur_of(roots, "fixture"), env

    def test_dual_seed_metadata_reaches_real_configuration_stage(self):
        sidecar = self.root / "direct-profile-input.json"
        sidecar.write_text(json.dumps({"format": 1, "title_id": TID, "content_version": 65536,
                                      "display": "1.1.0", "name": "Synthetic"}))
        current, env = self.seed(True)
        self.assertEqual(sidecar.read_bytes(), (current / sidecar.name).read_bytes())
        self.assertEqual((self.root / "unpack.tsv").read_bytes(), (current / "unpack.tsv").read_bytes())
        result = self.run_stage(env, require=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def versioned(self, title=TID):
        roots = self.base / "roots"
        seed = roots / "fixture@seed"
        extraction(seed, title=title)
        (seed / "ctl").mkdir()
        (seed / "ctl/control.nacp").write_bytes(b"synthetic-only")
        (roots / "fixture@现行").write_text(seed.name + '\n')
        env = dict(os.environ, S2A_DISK_FREE_G="999", S2A_ROOTS=str(roots), S2A_ROOTS_SHARED=str(self.base / "shared"),   # 盘判定不看本机实况
                   S2A_ROOTS_PRIV=str(self.base / "private"), S2A_ROOTS_NO_BOOT="1",
                   S2A_PYTHON=sys.executable, S2A_PY=sys.executable,
                   PATH=str(Path(sys.executable).parent) + os.pathsep + os.environ["PATH"])
        return roots, seed, env

    def run_stage(self, env, require=False):
        cmd = ["bash", str(REPO / "pack/stage_direct_profile.sh"), "fixture"]
        if require:
            cmd.append("--require-consumer")
        return subprocess.run(cmd, env=env, capture_output=True, text=True)

    def test_versioned_stage_commits_relative_candidate_and_reuses(self):
        roots, seed, env = self.versioned()
        p = self.run_stage(env)
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        current = cur_of(roots, "fixture")
        self.assertNotEqual(current, seed)
        data = json.loads((current / "direct_profile.json").read_text())
        self.assertFalse(Path(data["profile"]).is_absolute())
        self.assertNotIn(".tmp", data["profile"])
        self.assertTrue((current / data["profile"] / "game.tsv").is_file())
        self.assertTrue((current / ".stage_direct_profile").is_file())
        self.assertFalse((current / ".stage_direct").exists())
        self.assertFalse(data["runtime_verified"])
        again = self.run_stage(env)
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertEqual(current, cur_of(roots, "fixture"))

    def test_versioned_for_build_keeps_candidate_unverified(self):
        roots, seed, env = self.versioned()
        p = self.run_stage(env, require=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        current = cur_of(roots, "fixture")
        self.assertTrue((current / "direct_profile.json").is_file())
        self.assertFalse((current / ".stage_direct").exists())
        self.assertFalse(stage.selected(current)["runtime_verified"])

    def test_versioned_invalid_input_aborts_without_switch_or_marker(self):
        roots, seed, env = self.versioned()
        (seed / "exefs/main").write_bytes(b"NSO0")
        p = self.run_stage(env)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(seed, cur_of(roots, "fixture"))
        self.assertFalse(list(roots.glob("*.tmp")))
        self.assertFalse(list(roots.glob("*@dp-*")))

    def test_registered_versioned_stage_no_transaction(self):
        roots, seed, env = self.versioned("01006F8002326000")
        p = self.run_stage(env, require=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(seed, cur_of(roots, "fixture"))
        self.assertFalse((seed / "direct-profile").exists())

    def test_direct_entry_no_shader_container_runtime_only(self):
        # 11-06：原「编译器失败 → 退 1、不写成功标记」这项是假绿——夹具没有认得出的着色器容器，旧 direct_lib.py 在抽取退 3 时报「抽取失败」退 1，
        #   编译器失败那条路从没走到（xcrun 桩记的「被调用」是别处顺带调的）。抽取缺口现按 11-05 定的规矩出运行时现编空库（graphics/tools/direct/runtime_only_lib.sh），
        #   这里如实核这条路：退 0、现行 shaders/direct 带 runtime_only.txt 与 b-<链>/lib.idx、键记成功。编译器失败要另做带真着色器容器的夹具（后续项）
        roots, seed, env = self.versioned()
        bin_dir = self.base / "sentinel-bin"; bin_dir.mkdir()
        stub = bin_dir / "xcrun"   # 同原测试的桩环境：工具链解析只问 SDK / Metal 版本，照常答；其余调用一律失败
        stub.write_text("#!/bin/sh\ncase \" $* \" in *' --show-sdk-version '*) echo 27.0; exit 0;; *' metal --version '*) echo 'Apple metal version 1'; exit 0;; esac\nexit 1\n")
        stub.chmod(0o755)
        env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
        # 调用方给了直连翻译库 → 阶段不现编 libdsx（同 tests/stage_direct_test.sh）：这条路夹具里没有着色器、出的是运行时现编空库，用不到它；
        #   原先没给，全新工作树（门禁预检每次都是）里阶段先 make 一遍真的 libdsx，单这条用例冷跑 31 秒
        dsx = self.base / "libdsx-unused.dylib"; dsx.write_bytes(b"")
        env["DSX_LIB"] = str(dsx)
        p = subprocess.run(["bash", str(REPO / "pack/stage_direct.sh"), "fixture"], env=env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("离线 0 支、运行时首遇现编", p.stdout + p.stderr)
        d = cur_of(roots, "fixture") / "shaders/direct"
        self.assertTrue((d / "runtime_only.txt").is_file())
        self.assertTrue(list(d.glob("b-*/lib.idx")))
        self.assertTrue((cur_of(roots, "fixture") / ".stage_direct").exists())

    def refresh_harness(self):
        # Actual refresh/producer/root transaction; earlier unrelated stages
        # are boundary stubs, later stages are sentinels. No game/build runs.
        sandbox = self.base / "wiring"
        pack = sandbox / "pack"; pack.mkdir(parents=True)
        for filename in ("refresh.sh", "stage_direct_profile.sh"):
            shutil.copyfile(REPO / "pack" / filename, pack / filename)
        for filename in ("roots.sh", "direct_profile_stage.py", "stage_keyfiles.sh", "decoder_need.sh"):   # stage_keyfiles：各阶段实际读入进键（10-30）；decoder_need：只剩直连快路后刷新必 source 它（11-08）
            (pack / filename).symlink_to(REPO / "pack" / filename)
        (sandbox / "tools").symlink_to(REPO / "tools")
        (pack / "orch").symlink_to(REPO / "pack/orch")   # roots.sh 写现行指针（pack/orch/current.py）
        (sandbox / "graphics/nvn/tools").mkdir(parents=True); shutil.copyfile(REPO / "graphics/nvn/tools/gfx_api.py", sandbox / "graphics/nvn/tools/gfx_api.py")   # 出包分流判法
        # romfs_list.py：判法扫 RomFS 经它（仓库里唯一的 RomFS 遍历）
        for _f in ("nso_syms.py", "lz4blk.py", "romfs_list.py"): shutil.copyfile(REPO / "graphics/nvn/tools" / _f, sandbox / "graphics/nvn/tools" / _f)   # 判法读 NSO 导入表要它们
        called = self.base / "later-stages"
        for name in ("rewrite", "sysdata", "uilayout", "aoc", "caps"):   # caps：能力清单轻阶段（10-29 出包线）
            (pack / ("stage_" + name + ".sh")).write_text("#!/bin/sh\nexit 0\n")
        (pack / "srcver.sh").write_text("#!/bin/sh\nexit 0\n")   # 原件版本核对桩（真脚本会现编 nx_unpack、扫本机原件；自身单测 tests/srcver_test.sh）
        for name in ("romfsidx", "extract", "shaders", "direct"):
            (pack / ("stage_" + name + ".sh")).write_text(
                "#!/bin/sh\nprintf '" + name + "\\n' >> '" + str(called) + "'\n")
        return pack / "refresh.sh", called

    def test_refresh_dual_prepares_before_shader_and_library_stages(self):
        roots, seed, env = self.versioned()
        refresh, called = self.refresh_harness()
        env["S2A_DUAL"] = "1"
        p = subprocess.run(["bash", str(refresh), "fixture"], env=env,
                           capture_output=True, text=True)
        # 桩不出 keys.tsv = 直连库没出成 → 直连单轨（10-30 维护者）：报红、退出 1，不退成通用包、不跑着色器
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("直连单轨停在 直连库", p.stdout + p.stderr)
        seen = called.read_text().splitlines()
        self.assertEqual(seen[:2], ["romfsidx", "extract"])   # 10-25 抽着色器只做一次：抽取阶段在直连之前
        self.assertEqual(seen[2:], ["direct"])
        current = cur_of(roots, "fixture")
        self.assertTrue((current / "direct_profile.json").is_file())
        self.assertFalse(stage.selected(current)["runtime_verified"])

    def test_selected_profile_digest_changes_on_manual_adjustment(self):
        roots, seed, env = self.versioned()
        result = self.run_stage(env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        current = cur_of(roots, "fixture")
        first = stage.selected(current)
        p = Path(first["profile"]) / "game.tsv"
        p.write_text(p.read_text() + "\nrender_cond\ton\n")
        second = stage.selected(current)
        self.assertNotEqual(first["profile_key"], second["profile_key"])
        self.assertFalse(second["runtime_verified"])

    def test_selected_artifact_cannot_escape_root(self):
        roots, seed, env = self.versioned()
        self.assertEqual(self.run_stage(env).returncode, 0)
        current = cur_of(roots, "fixture")
        record = current / "direct_profile.json"
        data = json.loads(record.read_text())
        data["profile"] = "../outside"
        record.write_text(json.dumps(data))
        with self.assertRaisesRegex(dp.Invalid, "must stay"):
            stage.selected(current)

    def test_real_direct_library_script_selects_external_and_carries_game_tsv(self):
        # Actual consumer shell; compiler/extractor processes are explicit
        # boundaries producing synthetic tables, never real shader/GPU evidence.
        generated = stage.select(self.root, self.out)
        sandbox = self.base / "library-repo"
        nx = sandbox / "graphics/nvn"
        tools = sandbox / "translator"; tools.mkdir(parents=True)
        games = nx / "games"; games.mkdir(parents=True)
        shutil.copyfile(REPO / "graphics/nvn/games/game.py", games / "game.py")
        shutil.copyfile(REPO / "graphics/nvn/games/zero_skip.tsv", games / "zero_skip.tsv")   # 出库按程序号挑零源跳过事实写进 game.tsv（direct_lib.py）
        pack = sandbox / "pack"; pack.mkdir()
        (pack / "jobs").mkdir(); shutil.copyfile(REPO / "pack/jobs/space_rule.py", pack / "jobs" / "space_rule.py"); shutil.copyfile(REPO / "pack/jobs/library.py", pack / "jobs" / "library.py")   # 出库开工前的空间复核（#265，direct_lib.py 调）
        consumer = sandbox / "graphics/tools/direct"; consumer.mkdir(parents=True)
        shutil.copyfile(REPO / "graphics/tools/direct/direct_lib.py", consumer / "direct_lib.py")
        shutil.copyfile(REPO / "graphics/tools/direct/extract.py", consumer / "extract.py")   # 10-25「抽着色器只做一次」：产物根没有 extract/ 时当场抽（真脚本，抽取器是下面的合成桩）
        (sandbox / "tools").mkdir(exist_ok=True); shutil.copyfile(REPO / "tools/clonedir.py", sandbox / "tools/clonedir.py")   # test/directlib12 起临时目录由它整目录克隆上次的库
        for _f in ("progress.py", "pool_workers.py", "nostall.py", "addr_need.py", "nso_plain.py"): shutil.copy2(REPO / "tools" / _f, sandbox / "tools" / _f)   # 进度协议、无进展看门狗、程序号（没有 unpack.tsv 时读 main.npdm）
        (nx / "tools").mkdir(exist_ok=True); shutil.copyfile(REPO / "graphics/nvn/tools/gfx_api.py", nx / "tools/gfx_api.py")   # 出包分流判法
        # romfs_list.py：判法 / extract.py 列 RomFS 经它（仓库里唯一的 RomFS 遍历）
        for _f in ("nso_syms.py", "lz4blk.py", "romfs_list.py"): shutil.copyfile(REPO / "graphics/nvn/tools" / _f, nx / "tools" / _f)   # 判法读 NSO 导入表要它们
        (tools / "shader_split.py").write_text(
            "import sys\nfrom pathlib import Path\n"
            "for x in sys.argv[4:7]: Path(x).write_text('# synthetic\\n')\n")
        (tools / "glslc_offline.py").write_text("print('GLSLC 离线编：不需要（合成桩）')\n")   # 10-29 起 extract.py 先问运行时 GLSLC 款要不要离线编
        # 翻译链口径（11-01 出库链挪进 C#）：dmsh_chain.py --build-env <profile-rows 文件> 给「链号\t程序号\t摘要」（合成边界：不核工具锁，摘要固定）；version() 照旧给链号
        (tools / "dmsh_chain.py").write_text(
            "import os, sys\nSTAMP = 'inputs.tsv'\ndef version(): return 'fixture'\n"
            "if __name__ == '__main__':\n"
            "    a = sys.argv[1:]\n"
            "    if len(a) == 2 and a[0] == '--build-env':\n"
            "        print(\"note: built with this Mac's compilers (synthetic)\", file=sys.stderr)\n"
            "        open(a[1], 'w').write(''); print('fixture\\t' + os.environ['DM_GAME'] + '\\tsynthetic')\n"
            "    elif len(a) == 2 and a[0] == '--check-stamp':\n"   # 11-06 出库后核库印章（direct_lib.py）：合成边界不核翻译器指纹，只核库目录在
            "        sys.exit(0 if os.path.isdir(a[1]) else 'dmsh_chain.py stub: --check-stamp on a missing library ' + a[1])\n"
            "    elif not a: print(version())\n"
            "    else: sys.exit('dmsh_chain.py stub: unexpected ' + ' '.join(a))\n")
        # 整份直连出库 = C# dsh_batch build（graphics/tools/direct/dsh/batch/Build.cs 头注的接口）：dsh_batch.get() 给的命令换成下面的合成桩，按接口核参数、写出发布形态的产物
        (tools / "spvc_inproc.py").write_text("def lib_path(): return '/synthetic/libspvc.dylib'\n")   # direct_lib.py 先取 spirv-cross 进程内库路径交给 --spvc（合成边界：不编库）
        stub = tools / "dsh_batch_stub.py"
        (tools / "dsh_batch.py").write_text(
            "import sys\nfrom pathlib import Path\n"
            "CMD = [sys.executable, str(Path(__file__).with_name('dsh_batch_stub.py'))]\n"
            "def get(): return CMD, 'fixture'\n"
            "def build(): return CMD, 'fixture'\n"
            "def export(env): return env\n"
            "if __name__ == '__main__':\n    import os; os.execv(CMD[0], CMD + sys.argv[1:])\n")   # 同真 dsh_batch.py：direct_lib.py 经 python3 dsh_batch.py build … 调
        stub.write_text(
            "import sys\nfrom pathlib import Path\n"
            "a = sys.argv[1:]\n"
            "if not a or a[0] != 'build': sys.exit('dsh_batch stub: only the build mode, got ' + ' '.join(a))\n"
            "o, i = {}, 1\n"
            "while i < len(a):\n"
            "    if a[i] in ('--no-mac', '--no-ios', '--bf'): o[a[i]] = True; i += 1\n"
            "    elif i + 1 < len(a): o[a[i]] = a[i + 1]; i += 2\n"
            "    else: sys.exit('dsh_batch stub: ' + a[i] + ' without a value')\n"
            "miss = [k for k in ('--pkg', '--profile', '--game', '--chain', '--inputs', '--profile-rows', '--out', '--cas', '--spvc') if k not in o]\n"
            "if miss: sys.exit('dsh_batch stub: missing ' + ' '.join(miss))\n"
            "if not Path(o['--pkg']).is_dir() or not (Path(o['--profile']) / 'game.tsv').is_file(): sys.exit('dsh_batch stub: --pkg / --profile is not the merged package / profile copy')\n"
            "if '--iosout' not in o or o.get('--publish') not in ('ios', 'mac'): sys.exit('dsh_batch stub: a package build publishes one side (--iosout + --publish ios|mac)')\n"
            "ch = o['--chain']; st = '# synthetic\\ngame\\t' + o['--game'] + '\\ninputs\\t' + o['--inputs'] + '\\n'\n"
            "m = Path(o['--out']) / ('b-' + ch); m.mkdir(parents=True, exist_ok=True)\n"
            "(m / '_b_build.json').write_text('[{\"key\": \"aaaaaaaaaaaaaaaa\", \"st\": \"ok\", \"err\": \"\"}]'); (m / 'inputs.tsv').write_text(st)\n"
            "top = Path(o['--iosout']); d = top / ('b-' + ch); d.mkdir(parents=True, exist_ok=True)\n"
            "(d / 'lib.idx').write_bytes(b'synthetic'); (d / 'lib.000.pak').write_bytes(b'synthetic'); (d / 'inputs.tsv').write_text(st)\n"
            "(top / 'keys.tsv').write_text('aaaaaaaaaaaaaaaa\\n'); (top / 'ps_inputs.tsv').write_text('# synthetic\\n')\n"
            "for t in ('c1_full.tsv', 'cb_extent.tsv'): (Path(o['--profile']) / t).write_text('# chain b-' + ch + ' inputs ' + o['--inputs'] + ' synthetic\\n')\n"
            "print('shaders 1: ok 1'); print('shader cache: hit 0, rebuilt 1'); print('[直连库] 打包：1 键 2 段（合成）')\n"
            "print('store: 1 entries kept, 0 dropped')\n")
        shutil.copyfile(REPO / "graphics/tools/direct/run_pairs.py", consumer / "run_pairs.py")   # 10-26 起 ③ 后把跑局 P 行并进配对表（真工具，来源不存在时只出汇总行）
        for _f in ("fout_want.py", "pso_layout.py", "pso_layout.json"): shutil.copyfile(REPO / "graphics/tools/direct" / _f, consumer / _f)   # 10-26 起 ③ 后算输出类型变体请求表（真工具，来源不存在时出空表；11-04 起 Python 读提交的管线键布局）
        shutil.copyfile(REPO / "graphics/tools/direct/se_want.py", consumer / "se_want.py")   # 11-01 起输出类型变体请求表之后算采样模拟变体请求表（真工具，同目录 import run_pairs；来源不存在时出空表）
        shutil.copyfile(REPO / "graphics/tools/direct/run_knowledge.py", consumer / "run_knowledge.py")   # 审计 #1534 P1-54：出库只读跑局知识快照（真工具；单独调用时 direct_lib.py 现出一份，来源不存在时四张表全空）
        shutil.copyfile(REPO / "graphics/tools/direct/pso_seed.py", consumer / "pso_seed.py")   # 单独调用时 ⑤ 后照旧零配置生成种子表（真工具，读快照 seen.tsv）
        (consumer / "merge_extract.py").write_text(
            "import sys,json\nfrom pathlib import Path\n"
            "p=Path(sys.argv[4]);p.mkdir(parents=True);(p/'pkg').mkdir()\n"
            "(p/'shader_map.tsv').write_text('# synthetic\\n')\n"
            "(p/'key_map.tsv').write_text('s2a\\taaaaaaaaaaaaaaaa\\n')\n"
            "(p/'union_keys.tsv').write_text('aaaaaaaaaaaaaaaa\\n')\n"
            "(p/'merge.json').write_text('{}')\n")
        shbake = sandbox / "graphics/tools/shbake"; shbake.mkdir()
        (shbake / "nxsh_extract.py").write_text(
            "import sys\nfrom pathlib import Path\nPath(sys.argv[1]).mkdir(parents=True)\n"
            "(Path(sys.argv[1]) / 'rows.tsv').write_text('aaaaaaaaaaaaaaaa\\tvs\\tsynthetic\\t0\\n')\n")   # 10-29 起两边抽取都 0 支时 extract.py 按缺口退 3：给 1 行，出库走到底
        output = self.base / "direct-output"
        # 出包不读「文稿」（10-26 交付线：受保护目录，玩家机一碰就弹授权框；审计 #1534 P1-54 B4：我方机器也不读，Mac 局收局拷进 pso_seed/，同一提交 Mac 与Windows 出包机出同一个根）：
        #   假家目录里放一份 ~/Documents/wire/<程序号>/pso_user.tsv，不设 / 设 S2A_CPU_LEDGER=1 两次出库的跑局知识快照都是 0 个来源
        home = self.base / "home"; wire = home / "Documents/wire" / TID; wire.mkdir(parents=True)
        (wire / "pso_user.tsv").write_text("bbbbbbbbbbbbbbbb\t1\t0\n")
        env = dict(os.environ, DM_GAMES_DIR=generated["DM_GAMES_DIR"], DM_GAMES_FIRST="1", HOME=str(home),
                   S2A_DIRECT_CACHE=str(self.base / "library-cache"),
                   S2A_PYTHON=sys.executable,
                   PATH=str(REPO / "tools/bin") + os.pathsep + os.environ["PATH"])
        result = subprocess.run([sys.executable, str(consumer / "direct_lib.py"), str(self.root), str(output)],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("note: built with this Mac's compilers (synthetic)", result.stderr)
        self.assertIn("跑局知识快照：来源 0 份", result.stdout, "玩家机缺省读了 ~/Documents")
        self.assertEqual((Path(generated["profile"]) / "game.tsv").read_bytes(),
                         (output / "game.tsv").read_bytes())
        self.assertEqual((output / "keys.tsv").read_text(), "aaaaaaaaaaaaaaaa\n")
        # 写入器给的临时配置档只带表头的空种子表：出库要零配置生成（10-26 六款随包种子表 0 行，就是把这份空表当维护过的原样带了）；direct_lib.json 记 pso_seed=gen
        self.assertIn("Generated by graphics/tools/direct/pso_seed.py", (output / "pso_manifest.tsv").read_text(), "空种子表被当成维护过的原样带")
        self.assertEqual(json.loads((output / "direct_lib.json").read_text())["pso_seed"], "gen")
        self.assertFalse((games / TID).exists(), "consumer wrote a repository registration")
        # 第二次另设 S2A_PSO_SEED_STAGE=1（= 经 pack/stage_direct.sh 出库，审计 #1534 P1-54 B3）：种子表归轻阶段 pack/stage_direct_seed.sh，出库不生成、不发布配置档那份空表
        ours = subprocess.run([sys.executable, str(consumer / "direct_lib.py"), str(self.root), str(self.base / "direct-output-ours")],
                              env=dict(env, S2A_CPU_LEDGER="1", S2A_PSO_SEED_STAGE="1"), capture_output=True, text=True)
        self.assertEqual(ours.returncode, 0, ours.stdout + ours.stderr)
        self.assertFalse((self.base / "direct-output-ours/pso_manifest.tsv").exists(), "经阶段出库仍生成 / 发布了种子表")
        self.assertEqual(json.loads((self.base / "direct-output-ours/direct_lib.json").read_text())["pso_seed"], "gen")
        self.assertIn("跑局知识快照：来源 0 份", ours.stdout, "我方机器出库读了 ~/Documents（要先由 Mac 局收局拷进 pso_seed/）")
        # 第三次：种子工具坏了（审计 #1592 P1-100：种子表是锦上添花）→ 单独出库（Windows 出包路径）照常退 0、库照常发布，
        #   种子表换成只有表头的空表并写明缺了什么，打一行 🟡；原先 exit 1 在换进位之前、这次库不发布、包不出
        (consumer / "pso_seed.py").write_text("import sys\nsys.exit('模拟种子工具坏了')\n")
        soft = subprocess.run([sys.executable, str(consumer / "direct_lib.py"), str(self.root), str(self.base / "direct-output-soft")], env=env, capture_output=True, text=True)
        self.assertEqual(soft.returncode, 0, soft.stdout + soft.stderr)
        self.assertEqual((self.base / "direct-output-soft/keys.tsv").read_text(), "aaaaaaaaaaaaaaaa\n", "种子表失败时库没发布")
        seed = (self.base / "direct-output-soft/pso_manifest.tsv").read_text()
        self.assertTrue(all(l.startswith("#") for l in seed.splitlines()) and "generation failed" in seed, seed)
        self.assertIn(f"{TID} 管线种子表这次没生成", soft.stdout + soft.stderr, "【黄】行要带程序号，首遇卡顿排查能顺着找到原因")

    def test_writer_output_is_a_loadable_profile(self):
        # 写入器的真实行为（10-25 起替代与上游逐字的语法树哈希校验）：game.tsv 能被 game.py 解析，身份 / 模块 / 内存 / 版本键都在且取值对；
        # 三张空着色器表与 EMPTY_TABLES 逐字相同（出库按它们读、dmsh_chain 的输入指纹也算它们）
        profile = Path(self.generate()["profile"])
        sys.path.insert(0, str(dp.NX / "games"))
        import game as G
        g = G.Game(profile)
        self.assertEqual(g.get("title_id"), TID)
        self.assertEqual(g.get("program_id"), TID)
        self.assertIn("main", g.words("modules"))
        self.assertEqual(int(g.get("app_pool"), 0), 0xCD500000)
        self.assertEqual(g.values("build")[0][0], "v65536")
        for name, text in dp.pw.EMPTY_TABLES.items():
            self.assertEqual((profile / name).read_text(), text, name)
        self.assertTrue((profile / "game.tsv").read_text().startswith("# Provisional game profile"))   # direct_profile_stage.py 按这行认推导档

    def test_directory_order_does_not_change_profile(self):
        for dirname in ("Zed", "Alpha"):
            (self.root / "romfs" / dirname).mkdir(parents=True)
            (self.root / "romfs" / dirname / "shader.bnsh").write_bytes(b"BNSH")
        first = Path(self.generate()["profile"])
        expected = (first / "game.tsv").read_bytes()
        # Reverse directory insertion order without changing names/content.
        shutil.rmtree(self.root / "romfs")
        for dirname in ("Alpha", "Zed", "Data"):
            (self.root / "romfs" / dirname).mkdir(parents=True)
            name, raw = ("test.bnsh", b"BNSH" + bytes(40)) if dirname == "Data" else ("shader.bnsh", b"BNSH")
            (self.root / "romfs" / dirname / name).write_bytes(raw)
        result = dp.prepare(self.root, self.base / "second", version="v65536")
        self.assertEqual(expected, (Path(result["profile"]) / "game.tsv").read_bytes())

    def test_single_walk_provenance_matches_rglob_reference(self):
        # 单次遍历（romfs_walk）给出的 provenance 记录与原先 sorted(rglob) + open().read(32) + stat() 逐条相同：
        #   「a/b」与「a-c」「a.b」的先后按路径段比（'/' 在 '-' '.' 之后，按整串比会排反），期望由 pathlib 独立算
        romfs = self.root / "romfs"
        for rel, raw in (("a/b", b"BNSH" + bytes(40)), ("a-c", b"x"), ("a.b", b""), ("a/c/z", b"SARC" * 20), ("B", b"y" * 31)):
            (romfs / rel).parent.mkdir(parents=True, exist_ok=True)
            (romfs / rel).write_bytes(raw)
        expected = [[f"romfs/{p.relative_to(romfs)}", p.stat().st_size, hashlib.sha256(p.read_bytes()[:32]).hexdigest()]
                    for p in sorted(romfs.rglob("*")) if p.is_file()]
        self.assertEqual(dp.provenance(self.root, None)["inputs"][-len(expected):], expected)
        with dp.one_walk():
            self.assertIs(dp.romfs_walk(romfs), dp.romfs_walk(romfs))   # 同一进程内各项检查共用一份结果
        self.assertIsNot(dp.romfs_walk(romfs), dp.romfs_walk(romfs))   # 出了范围不留旧结果
        # RomFS 清单（README.profile.md「RomFS 清单」）：首次现读并写一份 <标签>-<32 位身份>.json；再来按身份命中、不再读盘
        lists = self.base / "walks"
        with dp.one_walk(lists):
            self.assertEqual(dp.provenance(self.root, None)["inputs"][-len(expected):], expected)
        first = sorted(p.name for p in lists.iterdir())
        self.assertEqual(len(first), 1); self.assertRegex(first[0], r"^" + self.root.name.split("@")[0] + r"-[0-9a-f]{32}\.json$")
        target = romfs / "a-c"; st = target.stat()
        target.write_bytes(b"z"); os.utime(target, ns=(st.st_atime_ns, st.st_mtime_ns))   # 大小、修改时间都没变 = 身份没变：读清单（不碰盘，仍是旧头）
        with dp.one_walk(lists):
            self.assertEqual(dp.provenance(self.root, None)["inputs"][-len(expected):], expected)
        os.utime(target, ns=(st.st_atime_ns, st.st_mtime_ns + 1))   # 修改时间变 = 身份变：重读，拿到新头，另写一份
        with dp.one_walk(lists):
            rows = {r[0]: r for r in dp.provenance(self.root, None)["inputs"]}
        self.assertEqual(rows["romfs/a-c"][2], hashlib.sha256(b"z").hexdigest())
        self.assertEqual(len(list(lists.iterdir())), 2)

    def test_romfs_symlink_rejected(self):
        (self.root / "romfs/Data/link.bnsh").symlink_to(self.root / "romfs/Data/test.bnsh")
        with self.assertRaisesRegex(dp.Unsupported, "RomFS symlinks unsupported"):
            self.generate()
        self.assertFalse((self.out / TID).exists())

    def test_rules_provenance_pinned(self):
        meta = json.loads((dp.HERE / "SOURCE.profile.json").read_text())
        self.assertEqual(dp.file_digest(dp.HERE / meta["files"][0]["local"]),
                         meta["files"][0]["local_sha256"])

    def _fresh(self, name, **kwargs):
        root = self.base / name
        extraction(root, **kwargs)
        return root

    def test_present_interval_derived_written_when_main_engine_marker(self):
        """Unity / Unreal bytes in main must land in game.tsv. Before the writer fix the guess has the key and the file does not."""
        cases = (
            ("unity", b"UnityEngine", "Unity"),
            ("il2cpp", b"global-metadata.dat", "Unity IL2CPP"),
            ("unreal", b"Unreal", "Unreal"),
            ("ue4", b"UE4", "Unreal 4"),
        )
        for name, payload, marker in cases:
            with self.subTest(marker=marker):
                root = self._fresh("eng-" + name, main_payload=payload)
                if marker.startswith("Unreal"):   # Unreal 推导要有资源包（同 Unreal 内存预设）；没有 .pak 的见 ..._without_unreal_pak
                    (root / "romfs/Data/game.pak").write_bytes(b"\0" * 64)
                result = dp.prepare(root, self.base / ("out-" + name), version="v65536")
                text = (Path(result["profile"]) / "game.tsv").read_text(encoding="utf-8")
                self.assertEqual(tsv_rows(text, "present_interval_derived"), ["display"])
                self.assertEqual(tsv_rows(text, "present_interval"), [])
                inputs = present_decide_inputs(text)
                self.assertEqual(inputs, (0, 0, 1))
                self.assertEqual(present_decide(*inputs, "ok"), 1)
                self.assertEqual(present_decide(*inputs, None), 0)
                self.assertEqual(present_decide(*inputs, "need_l3"), 0)
                self.assertEqual(present_decide(*inputs, "untested"), 0)
                report = json.loads((Path(result["profile"]) / "survey.json").read_text(encoding="utf-8"))
                self.assertIn(marker, report["facts"]["main_markers"])
                self.assertEqual(report["guesses"]["present_interval_derived"][0], "display")
                self.assertNotIn("present_interval_derived", report["unknown"])
                self.assertIn("present_interval", report["unknown"])
        # The other call path: write_profile alone, without prepare's append.
        root = self._fresh("writer-unreal", main_payload=b"Unreal")
        (root / "romfs/Data/game.pak").write_bytes(b"\0" * 64)
        tid, facts, _, _ = dp.inspect_inputs(root, version="v65536")
        dest = self.base / "writer-only" / tid
        dp.pw.write_profile(dest, int(tid, 16), {"F": facts, "name": tid, "survey": "survey.md",
                                                  "version": "v65536", "display": "unknown"})
        written = (dest / "game.tsv").read_text(encoding="utf-8")
        self.assertEqual(tsv_rows(written, "present_interval_derived"), ["display"])
        self.assertEqual(present_decide_inputs(written), (0, 0, 1))

    def test_unreal_marker_needs_token_and_pak(self):
        """10-29 情报核实：暗黑3 main 的「UE4」来自 VALUE4，子串命中误标 Unreal、推导出 display。
        期望：VALUE4 不标 Unreal 4；UE4Game 照标；有 Unreal 字样但 romfs 没有 .pak / .utoc 不推导 present_interval_derived"""
        for name, payload, want in (("value4", b"VALUE4", False), ("ue4game", b"UE4Game", True)):
            with self.subTest(payload=payload):
                root = self._fresh("tok-" + name, main_payload=payload)
                report = json.loads((Path(dp.prepare(root, self.base / ("tok-out-" + name), version="v65536")["profile"]) / "survey.json").read_text(encoding="utf-8"))
                self.assertEqual("Unreal 4" in report["facts"]["main_markers"], want)
        root = self._fresh("nopak", main_payload=b"Unreal")
        text = (Path(dp.prepare(root, self.base / "nopak-out", version="v65536")["profile"]) / "game.tsv").read_text(encoding="utf-8")
        self.assertEqual(tsv_rows(text, "present_interval_derived"), [])

    def test_unity6_version(self):
        """Unity 6 起版本号是 6000.x（丝之歌 6000.0.50f1），旧正则只认 20xx"""
        root = self._fresh("unity6", main_payload=b"UnityEngine 6000.0.50f1\0")
        report = json.loads((Path(dp.prepare(root, self.base / "unity6-out", version="v65536")["profile"]) / "survey.json").read_text(encoding="utf-8"))
        self.assertIn("6000.0.50f1", str(report["facts"].get("unity")))

    def test_present_interval_derived_omitted_without_main_engine_marker(self):
        plain = (Path(self.generate()["profile"]) / "game.tsv").read_text(encoding="utf-8")
        self.assertEqual(tsv_rows(plain, "present_interval_derived"), [])
        self.assertNotIn("present_interval_derived", plain)
        self.assertEqual(present_decide_inputs(plain), (0, 0, 0))
        self.assertEqual(present_decide(0, 0, 0, "ok"), 0)

        root = self._fresh("sdk-only", sdk_payload=b"UnityEngine")
        (root / "romfs/Data/level.bundle").write_bytes(b"UnityFS\0" + bytes(24))
        result = dp.prepare(root, self.base / "sdk-only-out", version="v65536")
        text = (Path(result["profile"]) / "game.tsv").read_text(encoding="utf-8")
        self.assertEqual(tsv_rows(text, "present_interval_derived"), [])
        self.assertNotIn("present_interval_derived", text)
        report = json.loads((Path(result["profile"]) / "survey.json").read_text(encoding="utf-8"))
        self.assertNotIn("Unity", report["facts"].get("main_markers", []))
        self.assertIn("Unity", report["facts"]["markers"])

        havok = self._fresh("havok", main_payload=b"Havok")
        havok_text = (Path(dp.prepare(havok, self.base / "havok-out", version="v65536")["profile"]) / "game.tsv").read_text(encoding="utf-8")
        self.assertEqual(tsv_rows(havok_text, "present_interval_derived"), [])
        self.assertEqual(present_decide_inputs(havok_text), (0, 0, 0))

    def test_present_interval_derived_rejects_illegal_and_writes_game(self):
        original = dp.pg.engine

        def illegal(facts):
            out = original(facts)
            out["present_interval_derived"] = ("yes", "not an interval")
            return out

        def as_game(facts):
            out = original(facts)
            out["present_interval_derived"] = ("game", "derived game, L3 must not promote it")
            return out

        dp.pg.engine = illegal
        try:
            with self.assertRaises(ValueError):
                self.generate()
            dest = self.base / "illegal-writer"
            tid, facts, _, _ = dp.inspect_inputs(self.root, version="v65536")
            with self.assertRaises(ValueError):
                dp.pw.write_profile(dest, int(tid, 16), {"F": facts, "name": tid, "survey": "survey.md",
                                                          "version": "v65536", "display": "unknown"})
        finally:
            dp.pg.engine = original
        self.assertFalse((self.out / TID).exists())
        self.assertFalse((self.base / "illegal-writer" / "game.tsv").exists())
        self.assertFalse(any(self.base.rglob("game.tsv")))

        dp.pg.engine = as_game
        try:
            text = (Path(self.generate()["profile"]) / "game.tsv").read_text(encoding="utf-8")
        finally:
            dp.pg.engine = original
        self.assertEqual(tsv_rows(text, "present_interval_derived"), ["game"])
        self.assertEqual(present_decide_inputs(text), (0, 0, 0))
        self.assertEqual(present_decide(0, 0, 0, "ok"), 0)
        self.assertEqual(text.count("present_interval_derived\tgame"), 1)

    def test_append_present_derived_does_not_duplicate_or_invent(self):
        path = self.base / "append" / "game.tsv"
        path.parent.mkdir()
        path.write_text("title_id\t" + TID + "\n", encoding="utf-8")
        before = path.read_bytes()
        self.assertEqual(dp.pw.append_present_derived(path, None), [])
        self.assertEqual(path.read_bytes(), before)
        with self.assertRaises(ValueError):
            dp.pw.append_present_derived(path, ("boost", "no"))
        self.assertEqual(path.read_bytes(), before)
        self.assertFalse(dp.pw.tsv_key_present(path.read_text(encoding="utf-8"), "present_interval"))
        wrote = dp.pw.append_present_derived(path, ("display", "Unity marker"))
        self.assertEqual(tsv_rows(path.read_text(encoding="utf-8"), "present_interval_derived"), ["display"])
        self.assertTrue(wrote)
        self.assertEqual(dp.pw.append_present_derived(path, ("display", "again")), [])
        self.assertEqual(path.read_text(encoding="utf-8").count("\npresent_interval_derived\t"), 1)
        sample = "present_interval_derived\tdisplay\n"
        self.assertTrue(dp.pw.tsv_key_present(sample, "present_interval_derived"))
        self.assertFalse(dp.pw.tsv_key_present(sample, "present_interval"))


if __name__ == "__main__":
    unittest.main()
