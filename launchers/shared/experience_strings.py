#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""从共用体验规格生成 iOS .strings 片段：错误码的「标题 + 下一步」，只留一个来源（launchers/shared/experience.v1.json）。

用法：python3 launchers/shared/experience_strings.py --lang zh-Hans|zh-Hant|en [--prefix ios_install_ --prefix ios_import_] [--spec <experience.v1.json>]
缺省前缀只取手机端装机 / 导入的码（ios_platform_* 是电脑端 Xcode iOS 平台组件的码，不进 App）。
输出（标准输出，UTF-8）：每个码两行 .strings 键值
    "error.<码>.title" = "…";
    "error.<码>.next" = "…";
标题取规格 errors.items[].title；下一步按规格约定取 pack/jobs/errors.py RECOVERY（中文），英文取 Mac 端 Localizable.json 里同一句的译文；
繁中（iOS 宿主 zh-Hant 界面，11-13）按简中原句查 launchers/shared/experience_zh_hant.json（台港用语，手写，不是简繁直转）。
iOS 出包时（runtime/build.mk 拷 ios/l10n/*.lproj 之后）把输出追加进包里的 S2ArmHost.strings；仓库里的 .strings 不放生成内容。
缺英文译文、缺标题即退出 1 并点名，不出半套。"""
import argparse
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
SPEC = ROOT / "launchers/shared/experience.v1.json"
ERRORS_PY = ROOT / "pack/jobs/errors.py"
LOCALIZABLE = ROOT / "launchers/macos/adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json"
ZH_HANT = ROOT / "launchers/shared/experience_zh_hant.json"


def recovery():
    spec = importlib.util.spec_from_file_location("s2a_errors_for_strings", ERRORS_PY)
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(ERRORS_PY.parent))
    spec.loader.exec_module(module)
    return dict(module.RECOVERY)


def quote(text):
    """.strings 字符串字面量：反斜杠、双引号、换行转义"""
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


DEFAULT_PREFIXES = ("ios_install_", "ios_import_")


def entries(lang, prefixes=DEFAULT_PREFIXES, spec_path=SPEC):
    """→ [(键, 文案)]，按码排序；缺东西抛 ValueError 点名"""
    if lang == "zh-Hant":   # 繁中：简中整套逐句查对照表，缺一句就点名、不出半套
        hant = json.loads(ZH_HANT.read_text(encoding="utf-8"))
        rows = entries("zh-Hans", prefixes, spec_path)
        miss = sorted({t for _, t in rows if t not in hant})
        if miss:
            raise ValueError("experience_zh_hant.json 缺这些句子的繁中：" + " | ".join(miss))
        return [(k, hant[t]) for k, t in rows]
    items = json.loads(Path(spec_path).read_text(encoding="utf-8"))["errors"]["items"]
    rec = recovery()
    en = {i["source"]: i.get("en", "") for i in json.loads(LOCALIZABLE.read_text(encoding="utf-8"))}
    out, missing = [], []
    for item in sorted((i for i in items if i["code"].startswith(tuple(prefixes))), key=lambda i: i["code"]):
        code = item["code"]
        title = (item.get("title") or {}).get(lang, "")
        nxt = rec.get(code, "")
        if lang == "en":
            nxt = en.get(nxt, "")
        if not title: missing.append(f"{code} 缺 {lang} 标题")
        if not nxt: missing.append(f"{code} 缺 {lang} 下一步" + ("（Localizable.json 里没有这句的英文）" if lang == "en" else "（errors.py RECOVERY 没有）"))
        out += [(f"error.{code}.title", title), (f"error.{code}.next", nxt)]
    if missing:
        raise ValueError("；".join(missing))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--lang", required=True, choices=("zh-Hans", "zh-Hant", "en"))
    ap.add_argument("--prefix", action="append", help="只出这些前缀的码（可重复）；缺省 ios_install_ 与 ios_import_")
    ap.add_argument("--spec", default=str(SPEC))
    a = ap.parse_args(argv)
    try:
        prefixes = tuple(a.prefix or DEFAULT_PREFIXES)
        rows = entries(a.lang, prefixes, a.spec)
    except (ValueError, KeyError, OSError) as e:
        print(f"【红】生成 .strings 失败：{e}", file=sys.stderr)
        return 1
    sys.stdout.reconfigure(encoding="utf-8")
    print(f"/* 由 launchers/shared/experience_strings.py 从 experience.v1.json 生成（{a.lang}，前缀 {' / '.join(prefixes)}），不要手改 */")
    for key, text in rows:
        print(f"{quote(key)} = {quote(text)};")
    return 0


if __name__ == "__main__":
    sys.exit(main())
