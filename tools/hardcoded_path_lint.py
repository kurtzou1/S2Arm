#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""写死机器路径检查（11-27）：代码里（注释、Python 文档字符串不算）不许把某一台出包机的路径当缺省值或常量写死，要走环境变量或配置。
起因：launchers/windows/bundle_runtime_win.py 的 zstd 目录缺省写死一台出包机的 R: 盘，换出包机后发版 Windows 组装整段红；只给那一个文件加断言防不住下一处。
规则：
  ① 全仓：盘符 + 出包机布局目录 s2a（如 D:\\s2a、R:/s2a、U:\\s2a_resident）
  ② 非测试代码：R: / T: / U: 盘开头的绝对路径（出包机专用盘，玩家机和系统都不用）；/Users/<名字>（放行 player、synthetic 等占位名）
  ③ 私有规则表（环境变量 S2A_PRIVATE_SCAN_RULES 或 ~/.config/s2arm/scan_private_rules.json 的 machine_path_rules：正则列表，如出包机用户名）：全仓；
     表不在就跳过这一条（公开仓不写具体用户名），打一行提示
  测试代码（tests/、*/tests/、*.Tests/、UI.Snapshots、test_* / *_test.*）只查 ① ③：夹具里的假路径（R:\\lib、家目录假名）是故意造的。
  行尾写 hardcoded-path-ok 的行放行（扫描器自己的坏样例等）。上游原样代码（compat/tree、third_party）不扫。
用法：hardcoded_path_lint.py <仓库根> [文件…]   → 有命中逐行打「路径:行: [命中] 原行」、退 1；没有退 0"""
import io
import json
import os
import re
import subprocess
import sys
import tokenize
from pathlib import Path

EXT = (".py", ".sh", ".cs", ".swift", ".m", ".mm", ".c", ".h", ".cpp", ".js", ".ts", ".json", ".yml", ".yaml", ".ps1", ".cmd", ".bat", ".mk",
       ".java", ".kt", ".gradle", ".toml", ".csproj", ".props", ".targets")
SKIP = ("compat/tree/", "third_party/")
SELF_FIXTURES = ("tests/hardcoded_path_lint_test.sh",)   # 本检查自己的正反夹具（heredoc 里故意写的坏路径），同 public_repo_scan 的 scanner_synthetic
LAYOUT = re.compile(r"(?<![A-Za-z0-9])[A-Za-z]:[\\/]{1,2}s2a(?=[\\/_]|\b)")
PLACEHOLDER = r"Shared|player|players|synthetic|user|username|name|me|you|someone|test|tester|example|foo|bar|alice|bob|private|nobody|demo|dev|runner"
WEAK = re.compile(r"(?<![A-Za-z0-9])[RTU]:[\\/]{1,2}[A-Za-z]|/Users/(?!(?:" + PLACEHOLDER + r")\b)[A-Za-z][A-Za-z0-9_.-]*")
LINE_COMMENT = {".py": "#", ".sh": "#", ".mk": "#", ".yml": "#", ".yaml": "#", ".toml": "#", ".ps1": "#", ".cmd": "::", ".bat": "::"}
OK = "hardcoded-path-ok"


def is_test(rel):
    return (rel.startswith("tests/") or "/tests/" in rel or "/Tests/" in rel or ".Tests/" in rel or "UI.Snapshots" in rel
            or re.search(r"(^|/)(test_|t_)[^/]*$|_test\.[a-z]+$", rel) is not None)


def private_rules():
    p = Path(os.environ.get("S2A_PRIVATE_SCAN_RULES") or Path.home() / ".config/s2arm/scan_private_rules.json")
    try:
        pats = json.loads(p.read_text(encoding="utf-8")).get("machine_path_rules") or []
    except (OSError, ValueError):
        print(f"提示：私有规则表 {p} 读不到，跳过出包机用户名检查（③）", file=sys.stderr)
        return []
    return [re.compile(x) for x in pats]


def py_code(text):
    """行号 → 该行的代码 token 拼接（去掉注释与独立字符串语句即文档字符串）；分词失败返回 None（按普通行扫）"""
    keep, prev = {}, None
    try:
        toks = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except (tokenize.TokenError, SyntaxError, IndentationError):
        return None
    for tk in toks:
        if tk.type == tokenize.COMMENT:
            continue
        if tk.type == tokenize.STRING and (prev is None or prev.type in (tokenize.NEWLINE, tokenize.NL, tokenize.INDENT, tokenize.DEDENT)):
            prev = tk
            continue
        if tk.type not in (tokenize.NL, tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT, tokenize.ENDMARKER):
            if tk.start[0] == tk.end[0]:
                keep.setdefault(tk.start[0], []).append(tk.string)
            else:   # 跨行的 token（多行字符串，常是嵌进去的整段远端脚本）：每个物理行只挂它自己那一行的原文，不把整段摊到每一行（11-28 私有工具里一处命中被摊成几十行）
                for k, part in enumerate(tk.string.split("\n")):
                    keep.setdefault(tk.start[0] + k, []).append(part)
        prev = tk
    return {k: " ".join(v) for k, v in keep.items()}


def scan(rel, text, priv):
    ext = os.path.splitext(rel)[1]
    lines = py_code(text) if ext == ".py" else None
    pats = [LAYOUT, *priv] + ([] if is_test(rel) else [WEAK])
    out = []
    for i, raw in enumerate(text.split("\n"), 1):
        if OK in raw:
            continue
        if lines is not None:
            code = lines.get(i, "")
        else:
            s = raw.strip()
            if s.startswith(("#", "//", "*", "/*", "::", "rem ", "REM ")):
                continue
            c = LINE_COMMENT.get(ext)
            code = raw.split(" " + c, 1)[0] if c else raw.split(" //", 1)[0]
        got = [m.group(0) for p in pats for m in p.finditer(code)]
        if got:   # 一行只报一次（同一处可能被布局规则和专用盘规则同时命中）
            out.append(f"{rel}:{i}: [{' | '.join(dict.fromkeys(got))}] {raw.strip()[:160]}")
    return out


def main(argv):
    if not argv:
        sys.exit("用法：hardcoded_path_lint.py <仓库根> [文件…]")
    root = Path(argv[0]).resolve()
    rels = argv[1:] or subprocess.run(["git", "-C", str(root), "ls-files"], capture_output=True, text=True, check=True).stdout.splitlines()
    priv, bad = private_rules(), []
    for rel in rels:
        if not (rel.endswith(EXT) or rel.endswith("Makefile")) or any(s in rel for s in SKIP) or rel in SELF_FIXTURES:
            continue
        try:
            text = (root / rel).read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        bad += scan(rel, text, priv)
    for b in bad:
        print(b)
    if bad:
        print(f"🔴 写死机器路径 {len(bad)} 处：改走环境变量或配置（有意保留的行尾写 {OK}）", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
