#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""逐款测过的缺省（11-27）：launchers/shared/game_defaults.v1.tsv 按程序号 + 构建号给设置项一个「本款缺省」，盖过定义表 game_settings.v1.json 的 default。

优先级（全仓一条）：启动环境 > 玩家选过的 > 逐款缺省 > 定义表 default（含 caps）。
  宿主（runtime/src/gdefaults.c s2a_game_defaults_apply，Mac / iOS / 安卓同一份）按编进去的 runtime/include/s2a_game_defaults.h 未设才写环境变量；
  Mac 启动设置页（pack/jobs/community.py）用本模块 lookup 显示「本款推荐」。两边取同一份表，头文件由本模块 emit 生成，单测核新鲜度。

表一行：<程序号 16 位大写十六进制>\\t<构建号前 16 位小写十六进制 | *>\\t<平台 ios|mac|android|*>\\t<设置 id>\\t<值>\\t# <依据>
  设置 id 只认定义表里带 env 的项（含 engine 引擎档案键）；值在这一项的 options 里。
  依据必须有对照读数（含「vs」）和测过的构建号（「测过」后跟至少一个 16 位构建号）；* 行同样要写（维护者 11-27：* 直接生效，哪版实测不对再加精确构建号行覆盖）。
  匹配：精确构建号优先于 *，同一构建层里精确平台优先于 *。只写程序号，不写游戏名（公开仓规矩，公开仓扫描另核）。
CLI：game_defaults.py lint | emit [输出] | check（头文件与表一致）"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TABLE = ROOT / "launchers/shared/game_defaults.v1.tsv"
SETTINGS = ROOT / "launchers/shared/game_settings.v1.json"
HEADER = ROOT / "runtime/include/s2a_game_defaults.h"
PLATS = ("ios", "mac", "android", "*")
PID = re.compile(r"^[0-9A-F]{16}$")
BID = re.compile(r"^[0-9a-f]{16}$")
TESTED = re.compile(r"测过[^\n]*?[0-9a-f]{16}")


def settings_items(path=SETTINGS):
    """定义表里带 env 的项：{id: 项}"""
    items = json.loads(Path(path).read_text(encoding="utf-8"))["items"]
    return {it["id"]: it for it in items if it.get("env")}


def parse(text):
    """表文本 → 行列表 [{pid, bid, plat, key, value, why, line}]；格式不对的行带 bad 原因（lint 报出来，lookup 跳过）"""
    rows = []
    for n, raw in enumerate(text.splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        body, _, why = raw.partition("#")
        cols = [c.strip() for c in body.rstrip().split("\t")]
        r = dict(line=n, why=why.strip())
        if len(cols) != 5:
            r["bad"] = "要 5 列（程序号 构建号 平台 设置 值）再跟 # 依据，实得 %d 列" % len(cols)
        else:
            r.update(pid=cols[0], bid=cols[1], plat=cols[2], key=cols[3], value=cols[4])
        rows.append(r)
    return rows


def lint(rows, items):
    """→ 错误行列表（空 = 表合格）"""
    errs, seen = [], {}
    for r in rows:
        at = "第 %d 行" % r["line"]
        if "bad" in r:
            errs.append(f"{at}：{r['bad']}"); continue
        if not PID.match(r["pid"]): errs.append(f"{at}：程序号要 16 位大写十六进制（{r['pid']}）")
        if r["bid"] != "*" and not BID.match(r["bid"]): errs.append(f"{at}：构建号要前 16 位小写十六进制或 *（{r['bid']}）")
        if r["plat"] not in PLATS: errs.append(f"{at}：平台只认 {' / '.join(PLATS)}（{r['plat']}）")
        it = items.get(r["key"])
        if not it:
            errs.append(f"{at}：设置 {r['key']} 不在定义表里、或没有 env（宿主不认）")
        elif r["value"] not in [o["value"] for o in it.get("options", [])]:
            errs.append(f"{at}：{r['key']} 的值 {r['value']} 不在定义表 options 里")
        if "vs" not in r["why"]: errs.append(f"{at}：依据要有对照读数（逐款值 vs 全局缺省）")
        if not TESTED.search(r["why"]): errs.append(f"{at}：依据要写测过的构建号（「测过」后跟 16 位构建号）")
        k = (r["pid"], r["bid"], r["plat"], r["key"])
        if k in seen: errs.append(f"{at}：与第 {seen[k]} 行重复（同款、同构建号、同平台、同设置）")
        seen.setdefault(k, r["line"])
    return errs


def lookup(rows, pid, bid, plat, key):
    """本款这一项的逐款缺省 → (值, 依据)；没有 → None。bid 取前 16 位小写比"""
    pid, bid = (pid or "").upper(), (bid or "").lower()[:16]
    good = [r for r in rows if "bad" not in r and r["pid"] == pid and r["key"] == key]
    for b in (bid, "*"):
        for p in (plat, "*"):
            for r in good:
                if r["bid"] == b and r["plat"] == p:
                    return r["value"], r["why"]
    return None


def env_of(item, value):
    """设置值 → (环境变量名, 值)：env_values 换算，没有按原值"""
    return item["env"], str((item.get("env_values") or {}).get(value, value))


def load(table=TABLE):
    return parse(Path(table).read_text(encoding="utf-8")) if Path(table).is_file() else []


def _c(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def emit(rows, items):
    """→ runtime/include/s2a_game_defaults.h 全文（只收合格行；表有错先 lint）"""
    out = ["// 生成文件，别手改：tools/game_defaults.py emit 按 launchers/shared/game_defaults.v1.tsv + game_settings.v1.json 的 env 映射生成（11-27 逐款缺省）。",
           "// 宿主 runtime/src/gdefaults.c s2a_game_defaults_apply 读；Mac 启动设置页读同一份表（tools/game_defaults.py lookup）。新鲜度由单测核（game_defaults.py check）",
           "#pragma once",
           '#include "gdefaults.h"   // s2a_game_default_row',
           "static const s2a_game_default_row s2a_game_default_rows[] = {"]
    for r in rows:
        if "bad" in r or r.get("key") not in items:
            continue
        name, ev = env_of(items[r["key"]], r["value"])
        out.append("    {%s}," % ", ".join(_c(x) for x in (r["pid"], r["bid"], r["plat"], r["key"], r["value"], name, ev, r["why"])))
    out += ["    {0, 0, 0, 0, 0, 0, 0, 0}   // 表尾（空表也有这一行，C 不收零长数组）", "};", ""]
    return "\n".join(out)


def peek_pid(module_dir):
    """模块目录 main.npdm 里的程序号（ACI0 +0x10）→ 16 位大写十六进制；读不到 → ""（同宿主 runtime/src/gfxmode.c npdm_read）"""
    try:
        b = (Path(module_dir) / "main.npdm").read_bytes()
        if b[:4] != b"META": return ""
        off = int.from_bytes(b[0x70:0x74], "little")
        if b[off:off + 4] != b"ACI0": return ""
        return "%016X" % int.from_bytes(b[off + 0x10:off + 0x18], "little")
    except (OSError, ValueError):
        return ""


def peek_bid(module_dir):
    """main 的构建号（随行表「# BUILD_ID」行，同宿主 runtime/src/loader.c read_layout_text）：nro_tables.tsv 的 @fixups main 段，没有再看 main.fixups.tsv；读不到 → \"\""""
    d = Path(module_dir)
    try:
        t = d / "nro_tables.tsv"
        if t.is_file():
            inside = False
            with t.open(encoding="utf-8", errors="replace") as f:
                for ln in f:
                    if ln.startswith("@"):
                        if inside: break
                        inside = ln.rstrip("\r\n") == "@fixups\tmain"
                    elif inside and ln.startswith("# BUILD_ID\t"):
                        return ln[11:].strip().lower()
        m = d / "main.fixups.tsv"
        if m.is_file():
            with m.open(encoding="utf-8", errors="replace") as f:
                for ln in f:
                    if ln.startswith("# BUILD_ID\t"):
                        return ln[11:].strip().lower()
    except OSError:
        pass
    return ""


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "lint"
    items, rows = settings_items(), load()
    errs = lint(rows, items)
    if errs:
        print("\n".join("【红】逐款缺省表 " + e for e in errs)); return 1
    if cmd == "lint":
        print(f"✓ 逐款缺省表 {len(rows)} 行合格"); return 0
    if cmd == "emit":
        text = emit(rows, items)
        if len(argv) > 2: Path(argv[2]).write_text(text, encoding="utf-8")
        else: sys.stdout.write(text)
        return 0
    if cmd == "check":
        if not HEADER.is_file() or HEADER.read_text(encoding="utf-8") != emit(rows, items):
            print(f"【红】{HEADER.relative_to(ROOT)} 与表不一致：改了 game_defaults.v1.tsv / 定义表 env 后要跑 python3 tools/game_defaults.py emit {HEADER.relative_to(ROOT)}"); return 1
        print(f"✓ {HEADER.relative_to(ROOT)} 与表一致（{len(rows)} 行）"); return 0
    print("用法：game_defaults.py lint | emit [输出] | check"); return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
