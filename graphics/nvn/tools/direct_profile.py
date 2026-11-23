#!/usr/bin/env python3
"""Survey an extracted S2Arm root; publish provisional direct-layer data outside source.
No build, device access, SDK interception, heap probe or runtime readiness assertion.
See README.profile.md. The rules are ../games/profile_guess.py (the one imported; provenance in SOURCE.profile.json).
"""
import argparse
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '../../../tools')); from nso_plain import plain as _nso_plain, NsoPlainError as _NsoPlainError   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段，不各写一份解码（tools/nso_plain.py）
import collections
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "games"))
import game
import profile_guess as pg
import profile_write as pw
# 同目录：仓库里唯一的 RomFS 遍历与清单
import romfs_list
import gfx_api   # 同目录（tools/）：出包分流的图形接口判法

HERE = Path(__file__).resolve().parent
NX = HERE.parent
NO_STATIC_SIGNAL = (
    "present_interval", "fps_hold", "render_cond", "tex_flush_upload",
    "tex_dirty_upload", "tex_dyn_slots", "gpu_timestamps", "vconv_range",
    "feedback_snap", "alpha_from_red",
)
# Local generation policy, never a static deduction or an upstream rule change.
PROFILE_POLICY = {
    "version": 3,   # 3（10-25 晚）：上传只传字节真变了的页（nvn_mtl.m NvPkg ph / pgpu）后按 Switch 语义写回 on；版本变了旧推导档（v2 写 off）的阶段键随之失效、重出时重推
    "defaults": {"tex_flush_upload": "on", "tex_dirty_upload": "on"},
}
DEFAULT_REASON = "默认值，非静态推断（Switch 上 CPU / GPU 同一份内存：CPU 写过的贴图要上传，只传字节真变了的页）"
MAX_IMAGE = 1 << 30
MAX_SYMBOLS = 1_000_000


class Invalid(ValueError):
    pass


class Unsupported(Invalid):
    """本款用了直连还没实现的结构（内容缺口，10-25 维护者）：出包打黄、走通用；Invalid（输入坏了 / 缺文件）照旧报红"""


def require(ok, message):
    if not ok:
        raise Invalid(message)


def unsupported(ok, message):
    if not ok:
        raise Unsupported(message)


def span(data, off, size, what):
    require(0 <= off <= len(data) and 0 <= size <= len(data) - off,
            f"{what}: range outside input")
    return data[off:off + size]


def validate_symbols(img):
    """Bound all pointers/counts before the upstream MOD0/dynamic-symbol reader."""
    require(len(img) >= 8, "module has no MOD0 pointer")
    mod = struct.unpack_from("<I", img, 4)[0]
    require(span(img, mod, 8, "MOD0")[:4] == b"MOD0", "module has no MOD0")
    dyn = mod + struct.unpack_from("<i", img, mod + 4)[0]
    tags = {}
    for i in range(4096):
        t, v = struct.unpack("<qQ", span(img, dyn + i * 16, 16, "dynamic table"))
        if not t:
            break
        # Pointer/count tags read below must be unambiguous. Repeatable
        # metadata such as DT_NEEDED is not a duplicate symbol-table layout.
        require(t not in tags or t not in (4, 5, 6, 10, 11), "duplicate dynamic layout tag")
        tags.setdefault(t, v)
    else:
        raise Invalid("unterminated dynamic table")
    unsupported(all(t in tags for t in (5, 6, 10, 11)),
            "unsupported dynamic layout: STRTAB/SYMTAB/STRSZ/SYMENT required")
    unsupported(tags[11] == 24, "unsupported dynamic symbol entry size")
    strings = span(img, tags[5], tags[10], "dynamic strings")
    if 4 in tags:
        buckets, count = struct.unpack("<II", span(img, tags[4], 8, "DT_HASH"))
        require(1 <= count <= MAX_SYMBOLS and buckets <= MAX_SYMBOLS, "invalid dynamic hash count")
        span(img, tags[4] + 8, 4 * (buckets + count), "dynamic hash")
    else:
        # 新版 SDK 的 sdk / subsdk / rtld 只有 DT_GNU_HASH：符号数按读取方 nso_syms.dynsyms 同一口径
        # （符号表紧挨在字符串表前：(STRTAB - SYMTAB) / 24），10-25 动森 / 塞尔达 / 丝之歌原先在这里整款拒绝
        require(tags[5] > tags[6] and (tags[5] - tags[6]) % 24 == 0, "dynamic symbols not directly before strings")
        count = (tags[5] - tags[6]) // 24
        require(1 <= count <= MAX_SYMBOLS, "invalid dynamic symbol count")
    syms = span(img, tags[6], 24 * count, "dynamic symbols")
    # 「name 处往后还有 NUL」⇔ name ≤ 字符串表里最后一个 NUL 的位置。原先 b"\0" in strings[name:] 每个符号都切一份表尾拷贝：
    #   UE4 大主程序（真人快打 11 main 72 MB）几十万个符号 × 几十 MB 表尾，本机 78 秒、Windows 出包机约 170 秒一次（11-06 出包速度线）
    last = strings.rfind(b"\0")
    for i in range(1, count):
        name = struct.unpack_from("<I", syms, i * 24)[0]
        require(name < len(strings) and name <= last, "invalid symbol name")


def validate_nso(path):
    from lz4blk import lz4_block
    require(path.stat().st_size <= MAX_IMAGE, f"{path.name}: oversized NSO file")
    d = path.read_bytes()
    require(len(d) >= 0x100 and d[:4] == b"NSO0", f"{path.name}: invalid NSO header")
    try:
        d = _nso_plain(d, path.name)
    except _NsoPlainError as e:
        require(False, str(e))
    version, reserved, flags = struct.unpack_from("<III", d, 4)
    # 0x40：Switch 2 新出现的标志位，与段解码无关（事实取自 Eden-NS2 加载器，GPL，代码自写：只认 0-5 位与 0x80 ZBIC）；0x80 ZBIC 已在上面经 _nso_plain 解成不压缩段
    require(version == 0 and reserved == 0 and flags & ~0x7f == 0,
            f"{path.name}: unsupported NSO version/flags")
    segs = [struct.unpack_from("<III", d, 0x10 + i * 16) for i in range(3)]
    compressed = struct.unpack_from("<III", d, 0x60)
    unsupported(segs[0][1] == 0, f"{path.name}: unsupported text memory offset")
    end = 0
    regions = []
    for i, (fo, mo, size) in enumerate(segs):
        require(mo >= end and mo + size <= MAX_IMAGE, f"{path.name}: overlapping/oversized segments")
        end = mo + size
        stored = compressed[i]
        require(fo >= 0x100, f"{path.name}: segment overlaps header")
        raw = span(d, fo, stored, f"{path.name}: segment {i}")
        require(not any(fo < b and a < fo + stored for a, b in regions),
                f"{path.name}: overlapping file segments")
        regions.append((fo, fo + stored))
        if flags & (1 << i):
            require(size > 0, f"{path.name}: compressed empty segment")
            raw = lz4_block(raw, size)
        require(len(raw) == size, f"{path.name}: segment size mismatch")
        if flags & (1 << (i + 3)):
            require(hashlib.sha256(raw).digest() == d[0xa0 + i * 32:0xc0 + i * 32],
                    f"{path.name}: segment hash mismatch")
    require(end + struct.unpack_from("<I", d, 0x3c)[0] <= 2 * MAX_IMAGE,
            f"{path.name}: oversized BSS")
    img = pg.nso(path)[0]
    validate_symbols(img)


def validate_npdm(path):
    d = path.read_bytes()
    require(len(d) >= 0x80 and d[:4] == b"META", "main.npdm: invalid META header")
    off, size = struct.unpack_from("<II", d, 0x70)
    aci = span(d, off, size, "ACI0")
    require(off >= 0x80 and len(aci) >= 0x40 and aci[:4] == b"ACI0", "main.npdm: invalid ACI0")
    # Upstream npdm() uses the first ACI0 marker; do not allow a decoy before it.
    require(d.find(b"ACI0") == off, "main.npdm: ambiguous ACI0")
    pid = struct.unpack_from("<Q", aci, 0x10)[0]
    require(pid != 0, "main.npdm: missing program ID")
    return f"{pid:016X}"


def manifest_check(path):
    seen = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        require(len(cols) == 3, "RomFS manifest: expected path, size, head-hex")
        name, size, head = cols
        require(name.startswith("/") and all(p not in (".", "..") for p in name.split("/")),
                "RomFS manifest: invalid path")
        require(not any(c in name for c in "\r\n\t\0"), "RomFS manifest: control character in path")
        require(name not in seen, "RomFS manifest: duplicate path")
        seen.add(name)
        require(size.isdecimal() and int(size) >= 0, "RomFS manifest: invalid size")
        require(re.fullmatch(r"(?:[0-9a-fA-F]{2}){0,32}", head) is not None,
                "RomFS manifest: invalid header hex")
        require(len(head) // 2 <= int(size), "RomFS manifest: header exceeds file size")


_WALKS = None         # one_walk() 期间：{romfs 路径: [romfs_list.Entry]}，同一进程内各项检查共用一次遍历
_LISTING_DIR = None   # one_walk(listing_dir) 期间：RomFS 清单目录（跨进程、跨阶段共用读头结果），见 README.profile.md「RomFS 清单」


@contextlib.contextmanager
def one_walk(listing_dir=None):
    """进程内 RomFS 只遍历一次：文件名校验、facts_of、provenance 都只要（路径、大小、前 32 字节），共用 romfs_walk 的同一份结果。
    只在本次调用期内有效；嵌套时沿用外层。期间 RomFS 不得改动（输出目录由 validate_output 保证在 romfs 之外）。
    listing_dir：给了就按 RomFS 内容身份在这个目录里找 / 写清单（跨进程、跨阶段共用读头结果）；清单不进任何键。"""
    global _WALKS, _LISTING_DIR
    outer = _WALKS, _LISTING_DIR
    if _WALKS is None:
        _WALKS = {}
    if listing_dir is not None:
        _LISTING_DIR = Path(listing_dir)
    try:
        yield
    finally:
        _WALKS, _LISTING_DIR = outer


def romfs_walk(romfs):
    """RomFS 目录的全部条目（目录与文件）：盘点、读头、清单都在 romfs_list.py（仓库里唯一的 RomFS 遍历）。语义对齐原先 rglob("*") + is_file() + open().read(32) + stat()：
    不进软链目录、软链文件跟随读、扫不开的目录跳过。库函数不给清单目录就照常现读（不落盘）"""
    key = os.fspath(romfs)
    if _WALKS is not None and key in _WALKS:
        return _WALKS[key]
    entries = romfs_list.heads(romfs, _LISTING_DIR).entries
    if _WALKS is not None:
        _WALKS[key] = entries
    return entries


def input_facts(root, manifest=None, title=None):
    exefs = root / "exefs"
    require(exefs.is_dir() and (exefs / "main").is_file(), "missing exefs/main")
    actual = validate_npdm(exefs / "main.npdm")
    require(title is None or title.upper() == actual, "title ID differs from NPDM program ID")
    for p in sorted(exefs.iterdir()):
        if p.name == "main.npdm":
            continue
        standard = re.fullmatch(r"main|sdk|rtld|subsdk[0-9]+", p.name) is not None
        if standard:
            require(p.is_file(), f"{p.name}: module is not a regular file")
            validate_nso(p)  # A damaged named module must never disappear from facts.
        elif p.is_file():
            with p.open("rb") as stream:
                unsupported(stream.read(4) != b"NSO0", f"unsupported module name: {p.name}")
    romfs = Path(manifest) if manifest else root / "romfs"
    # romfs_list.exists / is_dir：RomFS 不落散文件（romfs/ 不在、只有 romfs.std 镜像）时也算 RomFS 目录，条目经 romfs_walk 从镜像盘点
    require(romfs_list.exists(romfs), "missing RomFS directory/manifest")
    if romfs.is_file():
        manifest_check(romfs)
        facts = pg.facts_of(exefs, romfs)
    else:
        require(romfs_list.is_dir(romfs), "invalid RomFS input")
        entries = romfs_walk(romfs)
        for e in entries:
            unsupported(not e.symlink, "RomFS symlinks unsupported")
            unsupported(not any(c in e.rel for c in "\r\n\t\0"),
                    "RomFS control characters in path unsupported")
        # 上游 facts_of 的 RomFS 部分只读 romfs_files 给的（路径、大小、前 32 字节）：换成同一次遍历的结果，上游规则文件不动
        upstream = pg.romfs_files
        pg.romfs_files = lambda _: (("/" + e.rel, *e.read()) for e in entries if e.file)
        try:
            facts = pg.facts_of(exefs, romfs)
        finally:
            pg.romfs_files = upstream
    # Upstream folder scans are unordered; preserve counts but stabilize ties in
    # write_profile's shader-group naming (Counter.most_common).
    for key, value in facts["romfs"].items():
        if isinstance(value, collections.Counter):
            facts["romfs"][key] = collections.Counter(dict(sorted(value.items())))
    # 顶层目录名带空格或「=」写不进 shader_groups：profile_write 跳过它们（归 other），不整款拒（D-PVCK）
    unsupported("main" in facts["mods"], "main is not an NSO")
    # 图形接口与出包分流同一判法（gfx_api.py，单一来源）：NVN 不一定由 main 导入——引擎可在 subsdk 或 romfs 的 NRO 里（11-02 EA SPORTS FC 26），
    #   只认 main 会把这类 NVN 款拒掉；不是 NVN 时报出实际接口与依据（GL / Vulkan / 判不出），普查按这行归「非 NVN 款」
    api, why = gfx_api.classify(gfx_api.features(str(exefs), str(romfs) if romfs_list.is_dir(romfs) else None))
    unsupported(api == "nvn", f"unsupported graphics API: {api}（{why}）")
    return actual, facts


def clean(value):
    """Stable JSON facts with no executable bytes, paths to local inputs, or secrets."""
    if isinstance(value, dict):
        return {str(k): clean(v) for k, v in sorted(value.items())}
    if isinstance(value, set):
        return sorted(clean(v) for v in value)
    if isinstance(value, (list, tuple)):
        return [clean(v) for v in value]
    return value


def file_digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def provenance(root, manifest):
    records = []
    for p in sorted((root / "exefs").iterdir()):
        if p.is_file():
            records.append([f"exefs/{p.name}", p.stat().st_size, file_digest(p)])
    if manifest:
        p = Path(manifest)
        records.append(["romfs_manifest.tsv", p.stat().st_size, file_digest(p)])
    else:
        # The upstream guess reads file names, lengths and first 32 bytes, not the payload.
        # 顺序同原先 sorted(Path)：PurePath 按 / 拆开的各段逐段比较
        for e in sorted((e for e in romfs_walk(root / "romfs") if e.file), key=lambda e: e.rel.split("/")):
            size, head = e.read()
            records.append([f"romfs/{e.rel}", size, hashlib.sha256(head).hexdigest()])
    rules = {p.name: file_digest(p) for p in
             (NX / "games/profile_guess.py", HERE / "profile_write.py", HERE / "nso_syms.py", HERE / "lz4blk.py",
              NX / "games/game.py", HERE / "romfs_list.py", Path(__file__))}
    return {"inputs": records, "rules": rules, "policy": PROFILE_POLICY}


def validate_profile(directory, title):
    g = game.Game(directory)
    require(g.get("title_id") == title and g.get("program_id") == title,
            "existing profile identity differs from input")
    for key in ("name", "package", "shader_versions", "modules", "shader_groups"):
        g.get(key)
    game.header(g)  # Existing direct-layer schema/enum validation, including coupled switches.
    return g


def inspect_inputs(root, *, title=None, name=None, version, display="unknown", manifest=None):
    root = Path(root).resolve()
    require(re.fullmatch(r"v[0-9]+", version) is not None, "version must be v<integer>")
    for value in (name or "", display):
        require(not any(c in value for c in "\n\r\t\0"), "metadata contains control characters")
    with one_walk():
        tid, facts = input_facts(root, manifest, title)
        source = provenance(root, manifest)
    source["metadata"] = {"version": version, "display": display, "name": name or tid}
    fingerprint = hashlib.sha256(json.dumps(source, sort_keys=True).encode()).hexdigest()
    return tid, facts, source, fingerprint


def input_fingerprint(root, tid, *, version, display="unknown", name=None, manifest=None):
    """= inspect_inputs(...)[3]，不跑 input_facts：指纹只由 provenance 与元数据定，facts（主程序正则扫描，Spare-host 喷射战士3 约 6 秒）不进指纹。
    给只核「档是不是这份输入推导的」的调用（direct_profile_stage.py --selected、已有推导档的 plan）：一次出包关键链上原先要重扫 4 次（11-06 出包速度线）。
    tid 由调用方按 NPDM 核过（validate_npdm），同 inspect_inputs 里 input_facts 认出的那个"""
    root = Path(root).resolve()
    require(re.fullmatch(r"v[0-9]+", version) is not None, "version must be v<integer>")
    for value in (name or "", display):
        require(not any(c in value for c in "\n\r\t\0"), "metadata contains control characters")
    with one_walk():
        source = provenance(root, manifest)
    source["metadata"] = {"version": version, "display": display, "name": name or tid}
    return hashlib.sha256(json.dumps(source, sort_keys=True).encode()).hexdigest()


def verify_generated(directory, tid, fingerprint, version):
    validate_profile(directory, tid)
    old = Path(directory) / "survey.json"
    require(old.is_file(), "existing manual profile has no survey provenance; preserved")
    state = json.loads(old.read_text())
    require(state.get("format") == 1 and state.get("provisional") is True,
            "invalid generated profile provenance; preserved")
    require(state.get("fingerprint") == fingerprint and state.get("version") == version,
            "existing profile belongs to different inputs/version; preserved, choose another --out")
    return state


def validate_output(root, out):
    root, out = Path(root).resolve(), Path(out).resolve()
    for protected in (NX.parents[1], root / "exefs", root / "romfs", root / "aoc"):
        require(out != protected and protected not in out.parents, "output must be outside source/input root")
    return out


def prepare(root, out, *, title=None, name=None, version, display="unknown", manifest=None):
    root, out = Path(root).resolve(), Path(out).resolve()
    validate_output(root, out)
    tid, facts, source, fingerprint = inspect_inputs(
        root, title=title, name=name, version=version, display=display, manifest=manifest)
    # Empty hook set: do NOT inherit the upstream host's SDK interception policy.
    guesses = pg.guess(facts, hooks=set())
    directory = out / tid
    if (directory / "game.tsv").exists():
        verify_generated(directory, tid, fingerprint, version)
        return {"title_id": tid, "profile": str(directory), "reused": True, "provisional": True}
    require(not directory.exists(), "incomplete existing profile directory; preserved")
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".direct-profile-", dir=out) as temp:
        work = Path(temp) / tid
        pw.write_profile(work, int(tid, 16), {"F": facts, "name": name or tid,
                         "survey": "survey.md", "version": version, "display": display})
        # tex_flush_upload / tex_dirty_upload 仍是本地缺省：写入器不推断它们。
        # 只追加到这份新的临时档，不动已有 / 手写 / 已注册的档，也不改上游规则文件。
        with (work / "game.tsv").open("a", encoding="utf-8") as stream:
            stream.write("\n# " + DEFAULT_REASON + "\n")
            for key, value in PROFILE_POLICY["defaults"].items():
                stream.write(f"{key}\t{value}\n")
        # present_interval_derived 是静态推导，不是上面的缺省。write_profile 猜到就写进正文；
        # 这里再补一次，避免只走其中一条调用时漏掉。已有该行则不重复写。
        pw.append_present_derived(work / "game.tsv", guesses.get(pw.PRESENT_DERIVED_KEY))
        validate_profile(work, tid)
        defaults = {k: {"value": v, "origin": "default-not-inferred", "reason": DEFAULT_REASON}
                    for k, v in PROFILE_POLICY["defaults"].items()}
        # The upstream shader groups name packages. Do not assert shader/PSO coverage.
        report = {"format": 1, "title_id": tid, "version": version, "display": display,
                  "provisional": True, "runtime_verified": False,
                  "fingerprint": fingerprint, "provenance": source,
                  "facts": clean(facts), "guesses": clean(guesses),
                  "defaults": defaults,
                  "unknown": list(NO_STATIC_SIGNAL),
                  "limitations": ["upstream memory/module suggestions do not configure S2Arm loader",
                                  "no heap probe, rewritten-memory measurement, shader coverage or game run",
                                  "runtime external-profile consumer is owned by the direct line"]}
        (work / "survey.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        lines = ["# 直连静态勘察（临时档，未实跑）", "",
                 f"程序号：{tid}；版本：{version} / {display}",
                 f"输入/规则指纹：{fingerprint}", "",
                 "## 模块（静态导入/导出，非运行覆盖）", ""]
        for n, m in facts["mods"].items():
            lines.append(f"- {n}: build {m['bid']}, {len(m['imports'])} imports / {len(m['exports'])} exports")
        lines += ["", "## 上游候选键与理由", ""]
        for k, (v, why) in guesses.items():
            lines.append(f"- {k}: {v} — {why or '同一组上游内存划分规则'}")
        lines += ["", "## 临时档默认值（非静态推断）", ""]
        for k, item in defaults.items():
            lines.append(f"- {k}: {item['value']} — {item['reason']}")
        lines += ["", "## 无静态结论", "", ", ".join(NO_STATIC_SIGNAL),
                  "", "临时档仅供后续出库/试跑。空着色器表不代表覆盖；没有真实日志/截图时不得判起局成功。", "",
                  "上游按主程序导入决定模块，内存划分供上游宿主使用；S2Arm 加载器不消费这些键。",
                  "本工具没有 SDK 拦截、运行游戏、堆探测、自动调优或启用直连。"]
        (work / "survey.md").write_text("\n".join(lines) + "\n")
        os.rename(work, directory)  # complete directory becomes visible in one operation
    return {"title_id": tid, "profile": str(directory), "reused": False, "provisional": True}


def compare(generated, reference):
    """Every explicit key in either TSV; absent keys remain missing, never guessed right."""
    a, b = game.Game(generated), game.Game(reference)
    rows = []
    for k in sorted({k for k, _ in a.rows} | {k for k, _ in b.rows}):
        av, bv = a.values(k), b.values(k)
        # Compare numeric spelling by value; do not treat defaults as measured predictions.
        norm = lambda v: int(v, 0) if k.startswith("mem_") or k in ("app_pool", "sys_resource") else v
        aa = [[norm(v) for v in row] for row in av]
        bb = [[norm(v) for v in row] for row in bv]
        status = "missing" if not av else "generated_only" if not bv else "match" if aa == bb else "different"
        rows.append({"key": k, "status": status, "generated": av, "reference": bv})
    return {"format": 1, "kind": "static-key-comparison", "runtime_verified": False,
            "counts": dict(collections.Counter(r["status"] for r in rows)), "rows": rows}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("generate")
    p.add_argument("root", type=Path)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--title-id")
    p.add_argument("--name")
    p.add_argument("--version", required=True)
    p.add_argument("--display", default="unknown")
    p.add_argument("--manifest", type=Path)
    p = sub.add_parser("compare")
    p.add_argument("generated", type=Path)
    p.add_argument("reference", type=Path)
    a = parser.parse_args(argv)
    try:
        if a.command == "compare":
            result = compare(a.generated, a.reference)
        else:
            result = prepare(a.root, a.out, title=a.title_id, name=a.name,
                             version=a.version, display=a.display, manifest=a.manifest)
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0
    except (ValueError, OSError, KeyError, struct.error, RuntimeError) as e:
        print(f"【红】直连勘察拒绝：{e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
