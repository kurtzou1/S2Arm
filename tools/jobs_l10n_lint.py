#!/usr/bin/env python3
"""作业层玩家句要有翻译（11-14 i18n 第四批）：pack/jobs 只说中文原句，两端显示时按对照表翻（Mac / Windows 同一份
launchers/macos/adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json，加上共享体验表 experience.v1.json 里状态 / 结局 / 画面模式 / 阶段名几类）。
这里扫 pack/jobs/*.py（不含 tests/）里含中文的字符串字面量与 f-string，对照表里查不到的就是「英文界面会露中文」。

- 整句查；f-string 的 {表达式} 当 {0} 占位，对照表里带 {N} 的句式能套上也算；按「\\n」「；」拆开每段都查得到也算（同 BackendText.translate）。
- 不算：docstring、日志调用（名字含 log / print / debug / warn / trace）的参数、行尾带「# 非玩家句」的行：内部键、正则、比对用的原句、
  必须逐字保留的中文（问题模板选项），以及用 + 拼句的片段（拼出来的整句句式另写进对照表）。
- 存量缺口记在 tools/jobs_l10n_baseline.json（文件名 + 原句），只许变少：新增的缺口退出 1、点名文件:行；基线里已补上的只提示，不报红（别的支删代码不该打红你）。

用法：jobs_l10n_lint.py [仓库根]            检查
      jobs_l10n_lint.py [仓库根] --baseline 按当前缺口重写基线（补完一批翻译后用）
"""
import ast
import json
import re
import sys
from pathlib import Path

HAN = re.compile(r"[一-鿿]")
LOG = re.compile(r"(log|print|debug|warn|trace)", re.I)
MARK = "# 非玩家句"
TABLE = "launchers/macos/adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json"
SHARED = "launchers/shared/experience.v1.json"
BASELINE = "tools/jobs_l10n_baseline.json"


def known(root):
    sources = {e["source"] for e in json.loads((root / TABLE).read_text(encoding="utf-8"))}

    # 共享体验表只取两端翻译时真用的那几类（同 BackendText.sharedEntries / Windows BackendText）：
    #   states 里 running / failed 的标题、event_map.terminal_results 的 job.succeeded / job.cancelled、pack_graphics_mode.labels、stage_labels
    shared = root / SHARED
    if shared.exists():
        spec = json.loads(shared.read_text(encoding="utf-8"))
        picked = [s.get("title") for s in spec.get("states", []) if isinstance(s, dict) and s.get("id") in ("running", "failed")]
        results = (spec.get("event_map") or {}).get("terminal_results") or {}
        picked += [(results.get(k) or {}).get("title") for k in ("job.succeeded", "job.cancelled")]
        picked += list(((spec.get("pack_graphics_mode") or {}).get("labels") or {}).values())
        picked += list((spec.get("stage_labels") or {}).values())
        sources.update(t["zh-Hans"] for t in picked if isinstance(t, dict) and isinstance(t.get("zh-Hans"), str))
    patterns = [re.compile(r"\A" + re.sub(r"\\\{\d+\\\}", "(.+?)", re.escape(s)) + r"\Z", re.S)
                for s in sources if re.search(r"\{\d+\}", s)]
    return sources, patterns


def covered(text, sources, patterns):
    if text in sources or any(p.match(text) for p in patterns):
        return True
    parts = [x for x in re.split(r"[\n；]", text) if x.strip()]
    return parts != [text] and bool(parts) and all(covered(x, sources, patterns) for x in parts)   # 拆开有变化（含「；」开头的拼句片段）且每段都翻得了


def literals(path):
    """(行号, 原句)：f-string 的表达式段换成 {0}"""
    source = path.read_text(encoding="utf-8")
    lines = source.splitlines()
    tree = ast.parse(source)
    parent = {c: n for n in ast.walk(tree) for c in ast.iter_child_nodes(n)}
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if isinstance(parent.get(node), ast.JoinedStr):
                continue
            text = node.value
        elif isinstance(node, ast.JoinedStr):
            text = "".join(v.value if isinstance(v, ast.Constant) else "{0}" for v in node.values)
        else:
            continue
        if not HAN.search(text):
            continue
        up = parent.get(node)
        if isinstance(up, ast.Expr):
            continue   # docstring / 裸字符串
        if isinstance(up, ast.Call) and LOG.search(ast.unparse(up.func).split(".")[-1]):
            continue
        span = lines[node.lineno - 1:(node.end_lineno or node.lineno)]
        if any(MARK in line for line in span):
            continue
        yield node.lineno, text


def gaps(root):
    sources, patterns = known(root)
    out = []
    for path in sorted((root / "pack/jobs").glob("*.py")):
        for line, text in literals(path):
            if not covered(text, sources, patterns):
                out.append((path.name, line, text))
    return out


def misplaced(root):
    """四语翻译表里落在顶层、不在 text 表里的中文键（11-21：合并时把新句子追加到文件末尾的 } 前，JSON 合法、检查全过，
    但前端只查 text 表，这几句在四种语言里都显示回中文）"""
    out = []
    for path in sorted((root / "launchers/shared/l10n").glob("*.json")):
        out += [(path.name, k) for k in json.loads(path.read_text(encoding="utf-8")) if HAN.search(k)]
    return out


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    root = Path(args[0] if args else Path(__file__).resolve().parents[1]).resolve()
    found = gaps(root)
    if "--baseline" in argv:
        rows = sorted({(f, t) for f, _, t in found})
        (root / BASELINE).write_text(json.dumps([{"file": f, "text": t} for f, t in rows], ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"基线重写：{len(rows)} 条")
        return 0
    base_path = root / BASELINE
    base = {(e["file"], e["text"]) for e in json.loads(base_path.read_text(encoding="utf-8"))} if base_path.exists() else set()
    new = [(f, l, t) for f, l, t in found if (f, t) not in base]
    stale = base - {(f, t) for f, _, t in found}
    for f, l, t in new:
        print(f"🔴 pack/jobs/{f}:{l} 玩家句没有英文：「{t[:80]}」→ 加进 {TABLE}，或行尾写「{MARK}」")
    print(f"作业层中文句：缺翻译 {len(found)} 处（基线 {len(base)} 条），新增 {len(new)} 处" +
          (f"；基线里 {len(stale)} 条已补上，可跑 --baseline 收紧" if stale else ""))
    wrong = misplaced(root)
    for f, k in wrong:
        print(f"🔴 launchers/shared/l10n/{f} 顶层有中文键、不在 text 表里（前端查不到、显示回中文）：「{k[:80]}」→ 挪进 text")
    print(f"四语翻译表：放错层 {len(wrong)} 处")
    return 1 if new or wrong else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
