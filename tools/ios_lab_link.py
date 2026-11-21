#!/usr/bin/env python3
"""iOS 输入工作台（ios/lab/project.yml）只编链不跑：按工程里的源文件 / 框架 / 部署版本 / 宏 / 头文件路径，用 iPhoneOS SDK 的 clang 逐个编、再链成可执行文件。

  python3 tools/ios_lab_link.py [--spec <project.yml>] [--out <目录>]     退出 0 = 链得过；链接失败时打印未定义符号

11-01 维护者：c3c296ac1（10-28）让 settings.m 调 s2a_caps_apply，工作台工程没带 caps.c，main 上链不过三天没人发现——它不在门禁里。
不依赖 xcodegen / 签名 / 设备（门禁机未必装 xcodegen）；放行参数与 build.sh 同一来源（tools/weak_link_decl.py flags lab）。
工程文件只用到下面几个键，按行读（不引入 yaml 依赖）；出现认不得的写法就报红，不猜。
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import weak_link_decl  # noqa: E402


def parse(spec, srcroot):
    """→ dict(sources, frameworks, libs, ios_min, defines, includes)；认不得的形态抛 ValueError"""
    out = dict(sources=[], frameworks=[], libs=[], ios_min=None, defines=[], includes=[])
    section = None
    for raw in Path(spec).read_text().splitlines():
        line = raw.split(" #", 1)[0].rstrip()
        if not line.strip():
            continue
        key = re.match(r"^\s*([A-Za-z_]+):\s*(.*)$", line)
        item = re.match(r"^\s*-\s*(.*)$", line)
        if key and not item:
            name, value = key.groups()
            section = name if value == "" else None
            if name == "iOS" and value:
                out["ios_min"] = value.strip('"')
            elif name == "GCC_PREPROCESSOR_DEFINITIONS":
                out["defines"] = [d.strip().strip('"') for d in value.strip("[]").split(",") if d.strip() and "$(inherited)" not in d]
            continue
        if not item or section not in ("sources", "dependencies", "HEADER_SEARCH_PATHS"):
            continue
        value = re.sub(r"\s+#.*$", "", item.group(1)).strip().strip('"')   # 行尾注释不算值
        if section == "sources":
            out["sources"].append(value)
        elif section == "dependencies":
            dep = re.fullmatch(r"sdk:\s*(\S+)", value)
            if not dep:
                raise ValueError(f"认不得的依赖写法：{value}")
            name = dep.group(1)
            if name.endswith(".framework"):
                out["frameworks"].append(name[:-len(".framework")])
            elif name.startswith("lib") and name.endswith(".tbd"):
                out["libs"].append(name[3:-len(".tbd")])
            else:
                raise ValueError(f"认不得的 SDK 依赖：{name}")
        else:
            if not value.startswith("$(SRCROOT)/"):
                raise ValueError(f"认不得的头文件路径：{value}")
            out["includes"].append(os.path.normpath(Path(srcroot) / value[len("$(SRCROOT)/"):]))
    if not out["sources"] or not out["ios_min"]:
        raise ValueError("工程里没读到 sources 或 deploymentTarget.iOS")
    return out


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", default=str(ROOT / "ios/lab/project.yml"))
    ap.add_argument("--srcroot", default=str(ROOT / "build/f01-lab"), help="$(SRCROOT)：生成工程所在目录（同 ios/lab/build.sh 的 --project）")
    ap.add_argument("--out")
    a = ap.parse_args(argv[1:])
    try:
        p = parse(a.spec, a.srcroot)
    except ValueError as e:
        print(f"【红】iOS 输入工作台编链：{e}")
        return 1
    out = Path(a.out or tempfile.mkdtemp(prefix="s2a-ioslab-"))
    out.mkdir(parents=True, exist_ok=True)
    cc = ["xcrun", "-sdk", "iphoneos", "clang", "-arch", "arm64", f"-miphoneos-version-min={p['ios_min']}"]
    flags = ["-fobjc-arc", "-fmodules", *[f"-D{d}" for d in p["defines"]], *[f"-I{i}" for i in p["includes"]]]
    objs = []
    src_of = {}   # 目标文件 → 源文件（点名用）
    for src in p["sources"]:
        if Path(src).suffix not in (".c", ".m", ".mm", ".cpp"):   # 资源（如 ios/l10n 字符串表，#316）只进包、不编
            continue
        obj = out / (src.replace("/", "_") + ".o")
        r = subprocess.run(cc + flags + ["-c", str(ROOT / src), "-o", str(obj)], capture_output=True, text=True)
        if r.returncode:
            print(f"【红】iOS 输入工作台编链：编 {src} 失败\n{r.stderr[-2000:]}")
            return 1
        objs.append(str(obj)); src_of[str(obj)] = src
    weak = weak_link_decl.flags("lab")
    link = cc + objs + [f for fw in p["frameworks"] for f in ("-framework", fw)] + [f"-l{l}" for l in p["libs"]] + weak + ["-o", str(out / "S2ArmInputLab")]
    r = subprocess.run(link, capture_output=True, text=True)
    if r.returncode:
        undef = sorted(set(re.findall(r'^\s+"(_[A-Za-z0-9_]+)", referenced from', r.stderr, re.M)))
        print(f"【红】iOS 输入工作台编链：链接失败，未定义 {' '.join(undef) or '（见下）'}——工程 sources 缺了提供它的源文件，或它该登记「// 弱链接[lab]：<符号>」\n{r.stderr[-1500:]}")
        return 1
    # #1953：-U 放行对整个符号生效，同一符号只要一处按弱引用登记过，别处的普通声明（强引用）照样链得过，真机一启动 dyld 就因找不到它退出。
    #   所以链过之后逐个目标文件核：放行的符号在每个引用它的目标文件里都得是弱引用（nm -m 记「weak external」）
    left = subprocess.run(["xcrun", "nm", "-u", str(out / "S2ArmInputLab")], capture_output=True, text=True).stdout.split()
    allowed = weak_link_decl.registered("lab") & {u[1:] for u in left}   # 只核链完仍未定义的（工作台自己编了提供方的不算）
    strong = []
    for obj in objs:
        nm = subprocess.run(["xcrun", "nm", "-m", obj], capture_output=True, text=True).stdout
        for m in re.finditer(r"^\s*\(undefined\) (weak )?external _([A-Za-z0-9_]+)", nm, re.M):
            if m.group(2) in allowed and not m.group(1):
                strong.append(f"{src_of[obj]}：{m.group(2)}")
    if strong:
        print(f"【红】iOS 输入工作台编链：放行的弱符号在这些源文件里是普通声明（强引用），工作台一启动就找不到符号退出——声明加 __attribute__((weak_import))、调用前判空：{'；'.join(strong)}")
        return 1
    print(f"iOS 输入工作台编链：{len(p['sources'])} 个源文件、{len(p['frameworks'])} 个框架、放行 {len(weak)} 个弱符号（逐个目标文件核过都是弱引用）→ 链得过")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
