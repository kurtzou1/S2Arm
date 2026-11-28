#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""翻译器修复的受影响键：新旧两版翻译器对同一批着色器各翻一遍、比产物，变了的键记进 translator/xlate_affected.tsv（读法 pack/jobs/xlate_affected.py）。

用法（在维护者机器上跑，要 .NET SDK 与出库同一套 spirv-cross）：
  python3 translator/xlate_affected_gen.py --old <改前的仓库树> --new <改后的仓库树> --work <工作目录> [-j <并行>] [--append] <资源包的 shaders/direct 目录…>
输入：已出好的资源包（库里要带客体输入：LIB_GEN 1 起出的包都有；更早的包没有，跳过并报出来）。每个键的客体输入（库容器种类 56，与宿主 graphics/nvn/lib_pack.inc lp_guest_get 同一格式）拆成 <键>.ctl / <键>.code，
  只取包 keys.tsv 里的键；配置档表（shader_map / shader_facts / shader_pairs）取包里同目录那份。
翻译：两棵树各编一份 graphics/tools/direct/tests/dsh_cmp（项目引用 S2A.Dsh，翻译器跟着树走），--capi --shd 走宿主同一个导出入口 s2a_dsh_compile 的本体。
比较：每键 <键>_b.metal 逐字节、<键>_b.json 去掉 xfp（翻译器指纹，改翻译器必变）后按内容比；一边出成一边出不成也算变了。
输出：<work>/affected.tsv（键、哪款），--append 时往新树的清单追加 step <改前指纹> <改后指纹> <扫了几款> <说明> 与 key 行。
对照：同一棵树翻两遍的产物应逐字节相同（--self-check 只翻改前那棵两遍，变了的键数应为 0），不然比出来的「变了」不可信。"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "graphics/tools/direct"))
from repair_compute import Library  # noqa: E402  库容器（lib.idx + lib.NNN.pak）读法，与运行时 lib_pack.inc 同一格式

GUEST = 56
HEAD = 8


def guest_inputs(lib, key):
    """库容器里一个键的客体输入 → (ctl, code)；没有 / 坏了 → None（同 lp_guest_get：头 8 字节 + zlib 流；块 = 键数、阶段、版本 1，每键 24 字节目录）"""
    if (key, GUEST) not in lib.records:
        return None
    seg = lib.read(key, GUEST)
    rawlen = int.from_bytes(seg[:4], "little")
    try:
        raw = zlib.decompress(seg[HEAD:])
    except zlib.error:
        return None
    if len(raw) != rawlen or len(raw) < HEAD:
        return None
    n = int.from_bytes(raw[:4], "little")
    if not 0 < n <= 16 or raw[5] != 1 or HEAD + 24 * n > len(raw):
        return None
    for i in range(n):
        e = HEAD + 24 * i
        if int.from_bytes(raw[e:e + 8], "little") == key:
            at, c, d = (int.from_bytes(raw[e + o:e + o + 4], "little") for o in (8, 12, 16))
            return (raw[at:at + c], raw[at + c:at + c + d]) if at + c + d <= len(raw) else None
    return None


def extract(direct, dst):
    """一份资源包的 shaders/direct → dst/in/<键>.ctl|.code 与 dst/tables/*；返回 (程序号, 取到的键数, keys.tsv 键数)"""
    libs = [p for p in sorted(Path(direct).glob("b-*")) if p.is_dir() and not p.name.endswith("-vk") and (p / "lib.idx").is_file()]
    if len(libs) != 1:
        raise SystemExit(f"[RED] {direct}：库目录 b-<链> 不是正好一份（{len(libs)}）")
    lib = Library(libs[0])
    want = [l.strip().lower() for l in (Path(direct) / "keys.tsv").read_text().splitlines() if l.strip()]
    game = next((l.split("\t", 1)[1].strip() for l in (libs[0] / "inputs.tsv").read_text().splitlines() if l.startswith("game\t")), Path(direct).parent.name)
    inp, tab = dst / "in", dst / "tables"
    inp.mkdir(parents=True, exist_ok=True); tab.mkdir(parents=True, exist_ok=True)
    for n in ("shader_facts.tsv", "shader_pairs.tsv", "shader_map.tsv", "shader_map.tsv.conflicts.tsv"):
        if (Path(direct) / n).is_file():
            shutil.copy(Path(direct) / n, tab / n)
    got = 0
    for k in want:
        g = guest_inputs(lib, int(k, 16))
        if g is None:
            continue
        (inp / f"{k}.ctl").write_bytes(g[0]); (inp / f"{k}.code").write_bytes(g[1]); got += 1
    return game, got, len(want)


def build_cmp(tree, out):
    """在这棵树里编 dsh_cmp（翻译器 = 这棵树的 S2A.Dsh）→ 可执行入口；同时算这棵树的翻译器指纹"""
    dn = os.environ.get("DOTNET") or (str(Path.home() / ".dotnet/dotnet") if (Path.home() / ".dotnet/dotnet").exists() else shutil.which("dotnet"))
    proj = Path(tree) / "graphics/tools/direct/tests/dsh_cmp/dsh_cmp.csproj"
    r = subprocess.run([dn, "build", str(proj), "-c", "Release", "-o", str(out), "-v", "quiet", "-nologo"], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"[RED] 编 dsh_cmp 失败（{tree}）：{(r.stdout + r.stderr).strip()[-400:]}")
    # 直连翻译库 libdsx（SPIRV-Cross 与共享内存 / 半精度导出改写，也参与翻译：出库工具指纹里有它）：每棵树编自己那份（同门禁 graphics/gate.sh）
    dsx = Path(tree).resolve() / "build/dsx/libdsx.dylib"
    r = subprocess.run(["make", "-s", "-j4", "-C", str(Path(tree) / "graphics/dsx"), str(dsx)], capture_output=True, text=True)
    if r.returncode or not dsx.is_file():
        raise SystemExit(f"[RED] 编 libdsx 失败（{tree}）：{(r.stdout + r.stderr).strip()[-400:]}")
    xfp = subprocess.run([sys.executable, str(Path(tree) / "translator/dmsh_chain.py"), "--xfp"], capture_output=True, text=True).stdout.strip().splitlines()
    return [dn, str(Path(out) / "dsh_cmp.dll"), "--backend", "nxgal", "--dsx", str(dsx)], (xfp[-1] if xfp else "")


def translate(cmd, game_dir, side, jobs):
    """按键分 jobs 片并行翻 → game_dir/<side>/ 下各键产物"""
    keys = sorted(p.stem for p in (game_dir / "in").glob("*.ctl"))
    out = game_dir / side; out.mkdir(exist_ok=True)
    parts = [keys[i::jobs] for i in range(jobs)]
    def one(i):
        lst = game_dir / f".{side}.{i}.keys"; lst.write_text("".join(k + "\n" for k in parts[i]))
        r = subprocess.run(cmd + ["--capi", "--shd", str(game_dir / "in"), "--keys", f"file:{lst}", "--tables", str(game_dir / "tables"), "--out", str(out / f"p{i}")],   # 每片自己的输出目录：dsh_cmp 收尾删 <out>/.work，共用一个会删掉别片正在用的
                           capture_output=True, text=True)
        return r.stdout
    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        logs = list(ex.map(one, [i for i in range(jobs) if parts[i]]))
    (game_dir / f"{side}.log").write_text("".join(logs))


def product(out, key):
    """一个键的产物指纹：_b.metal 字节 + _b.json 去掉 xfp 后的内容；没出成 → None"""
    hit = next((p for p in sorted(Path(out).glob("p*")) if (p / f"{key}_b.metal").is_file()), Path(out))   # 产物在哪一片的输出目录
    m, j = hit / f"{key}_b.metal", hit / f"{key}_b.json"
    if not m.is_file() or not j.is_file():
        return None
    doc = json.loads(j.read_text())
    if isinstance(doc, dict):
        doc.pop("xfp", None)
    return hashlib.sha256(m.read_bytes() + b"\0" + json.dumps(doc, sort_keys=True).encode()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", required=True); ap.add_argument("--new"); ap.add_argument("--work", required=True)
    ap.add_argument("-j", type=int, default=4); ap.add_argument("--append", action="store_true"); ap.add_argument("--note", default="")
    ap.add_argument("--self-check", action="store_true", help="改前那棵翻两遍，比出的变了应为 0")
    ap.add_argument("packs", nargs="+")
    a = ap.parse_args()
    work = Path(a.work); work.mkdir(parents=True, exist_ok=True)
    old_cmd, old_x = build_cmp(a.old, work / "bin-old")
    new_cmd, new_x = (old_cmd, old_x) if a.self_check else build_cmp(a.new, work / "bin-new")
    print(f"翻译器：改前 {old_x}，改后 {new_x}{'（对照：同一棵翻两遍）' if a.self_check else ''}")
    affected, games, total = {}, 0, 0
    for i, d in enumerate(a.packs):
        gd = work / f"g{i:02d}"
        shutil.rmtree(gd, ignore_errors=True)
        game, got, want = extract(d, gd)
        if not got:
            print(f"{game}：库里没有客体输入（早于 LIB_GEN 1 的包），跳过（{d}）", flush=True); continue
        translate(old_cmd, gd, "old", a.j); translate(new_cmd, gd, "new", a.j)
        keys = sorted(p.stem for p in (gd / "in").glob("*.ctl"))
        oks = {side: sum(product(gd / side, k) is not None for k in keys) for side in ("old", "new")}
        if not oks["old"] or not oks["new"]:   # 一边一个都没翻出来：比出的「没变」是空读数（判据坏了），停下报红
            raise SystemExit(f"[RED] {game}：改前翻出 {oks['old']} / 改后翻出 {oks['new']} / 共 {len(keys)} 键，有一边是 0，比不了（看 {gd}/old.log、new.log）")
        diff = [k for k in keys if product(gd / "old", k) != product(gd / "new", k)]
        for k in diff:
            affected.setdefault(k, set()).add(game)
        games += 1; total += got
        print(f"{game}：取到客体输入 {got} / keys.tsv {want} 键，翻出 改前 {oks['old']} / 改后 {oks['new']}，产物变了 {len(diff)} 键（{d}）", flush=True)
    (work / "affected.tsv").write_text("".join(f"{k}\t{','.join(sorted(g))}\n" for k, g in sorted(affected.items())))
    print(f"合计：{games} 款、{total} 键，变了 {len(affected)} 键 → {work / 'affected.tsv'}")
    if a.append and not a.self_check:
        lst = Path(a.new) / "translator/xlate_affected.tsv"
        with lst.open("a", encoding="utf-8") as f:
            f.write(f"step\t{old_x}\t{new_x}\t{games}\t{a.note}\n")
            f.write("".join(f"key\t{new_x}\t{k}\n" for k in sorted(affected)))
        print(f"已追加进 {lst}")


if __name__ == "__main__":
    main()
