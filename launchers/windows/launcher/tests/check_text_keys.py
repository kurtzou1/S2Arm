#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""扫描 App/*.cs 中所有 T("...") 调用，检查 id 是否存在于 experience.v1.json launcher.items。缺键 → 非零退出。"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]  # 仓库根
APP_DIR = Path(__file__).resolve().parents[1] / "App"
EXPERIENCE = ROOT / "launchers" / "shared" / "experience.v1.json"


def main() -> int:
    with open(EXPERIENCE, encoding="utf-8") as f:
        data = json.load(f)
    items = data.get("launcher", {}).get("items", [])
    known = {it["id"] for it in items if it.get("id")}

    # 扫描所有 T("...") 调用（单双引号均考虑，C# 只用双引号）
    pattern = re.compile(r'\bT\("([^"]+)"\)')
    missing: dict[str, list[str]] = {}  # id → 出现的文件列表

    for cs_file in sorted(APP_DIR.glob("*.cs")):
        text = cs_file.read_text(encoding="utf-8")
        for m in pattern.finditer(text):
            key = m.group(1)
            # 跳过动态拼接键（包含 +、{ 等的不做静态分析）
            if any(c in key for c in ("+", "{", "}")):
                continue
            # 跳过在代码里已知是动态前缀的模式（如 "errors." + code）
            if key not in known:
                missing.setdefault(key, []).append(cs_file.name)

    # 手机作业结局卡（App/PhoneJobCard.cs）的键是按作业类型拼的，上面的字面量扫描看不到：按「作业类型 × 结局状态」整张矩阵核，
    #   每一格用到的键中英都要有、不为空（11-11 维护者截图里缺文案露出机读码；运行时退回只是兜底，缺一格就红）
    by_id = {it["id"]: it for it in items if it.get("id")}
    phone_kinds = ("install", "installRemove", "installRestore", "installUpdate")
    phone_states = {
        "running": ["phone.title.{k}", "phone.status.running.{k}", "export.overall", "phone.steps.more", "phone.details"],
        "succeeded": ["phone.title.{k}", "phone.headline.{k}", "phone.done.{k}", "phone.stat.time", "phone.stat.device", "phone.stat.games",
                      "phone.stat.no_push", "phone.fact.no_push", "phone.fact.pushed", "phone.fact.skipped", "phone.details"],
        "needsPlayer": ["phone.title.{k}", "install.needs_player", "phone.details"],
        "cancelled": ["phone.title.{k}", "phone.cancelled", "phone.details"],
        "failed": ["phone.title.{k}", "phone.failed.{k}", "phone.next", "phone.retry", "phone.details"],
        "drop": ["phone.title.{k}", "install.drop_title", "install.drop_confirm", "phone.drop.cancel"],
    }
    for kind in phone_kinds:
        for state, keys in phone_states.items():
            for key in (k.format(k=kind) for k in keys):
                row = by_id.get(key, {})
                for lang in ("zh-Hans", "en"):
                    if not str(row.get(lang) or "").strip():
                        missing.setdefault(key, []).append(f"PhoneJobCard {kind}×{state} {lang}")

    if missing:
        print(f"MISSING TEXT KEYS ({len(missing)}):", file=sys.stderr)
        for key, files in sorted(missing.items()):
            print(f"  [{key}] in {', '.join(sorted(set(files)))}", file=sys.stderr)
        return 1

    print(f"text key check: {len(known)} keys known, all T() calls resolved")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
