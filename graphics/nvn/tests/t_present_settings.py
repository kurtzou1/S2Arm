#!/usr/bin/env python3
"""t_present_settings.sh 的链接清单工具（graphics/nvn/tests/t_present_settings.link.txt 是唯一来源：构建只编、只链它列的宿主源文件，
门禁按同一份清单算这两支单测的输入，见 tools/gate_route.py「门禁清单」）。
  python3 t_present_settings.py sources <清单>                       清单里要编的源文件（.c / .m / .S），一行一个
  python3 t_present_settings.py depcheck <清单> <仓库根> <.d 文件…>    编译器实读的仓库内头文件都要在清单里；缺了逐个报、退出 1
  python3 t_present_settings.py weak <目标文件 / 静态库…>             链接放行参数：这些输入里只被弱引用、谁都不定义的符号（同 android/tests/host_link.py 按目标文件实算）
  python3 t_present_settings.py libcheck <清单> <链接映射> <仓库根> <静态库…> 链进来的库成员的源文件与实读头文件（DWARF）都要在清单「lib」行（或 src / hdr）里；缺了逐个报、退出 1
  python3 t_present_settings.py dyncheck <清单> <可执行文件> [<链接输入…>]           链出来的程序里运行期才查找的符号都要在清单「dyn」行里（新多出一个 = 清单外的文件可能提供它，重生成清单）
清单格式：# 开头是注释；「src <路径>」编译链接的源文件；「lib <路径>」链进来的静态库（libnvn / libnxgal / libdsx）成员的源文件与实读头文件（门禁输入用：
库成员改了引用也会改链接结果，11-26 #2242 改 libnvn 里的 nvn2_codec.c 没触发本测、下一笔属主背锅）；「hdr <路径>」这些源文件与 t_present_settings.m 实读的头文件；「dyn <符号>」运行期查找的弱符号。
清单由 graphics/nvn/tests/t_present_settings_closure.py 按链接器实算生成，宿主 / 前端代码改动让链接报未定义符号或上面两项核对报红时重跑它。"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = "graphics/nvn/tests/t_present_settings.m"   # 单测主文件：本身就是本测输入，不进清单
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools"))
import weak_link_decl  # noqa: E402  放行参数的唯一生成处


def entries(lst):
    out = {"src": [], "hdr": [], "lib": [], "dyn": []}
    with open(lst, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            kind, _, val = s.partition(" ")
            if kind not in out or not val.strip():
                sys.exit(f"【红】{lst}:{n} 认不出的行：{s}")
            out[kind].append(val.strip())
    return out


def deps(dfile):
    """编译器 -MD 写的依赖文件 → 编译实读的文件（含被编源文件本身与 SDK 文件）"""
    txt = open(dfile, encoding="utf-8", errors="replace").read().replace("\\\n", " ")
    _, _, rest = txt.partition(":")
    return [p.replace("\\ ", " ") for p in re.split(r"(?<!\\)\s+", rest) if p]


def depcheck(lst, root, dfiles):
    root = os.path.realpath(root)
    listed = set(entries(lst)["hdr"]) | set(entries(lst)["src"]) | {MAIN}
    missing = {}
    for d in dfiles:
        for p in deps(d):
            rp = os.path.realpath(p if os.path.isabs(p) else os.path.join(root, p))
            if not rp.startswith(root + "/"):
                continue   # 系统 / SDK 头
            rel = rp[len(root) + 1:]
            if rel.startswith("build/"):
                continue   # 构建产物（本测宿主侧不生成头，留作防御）
            if rel not in listed:
                missing.setdefault(rel, os.path.basename(d))
    for rel, d in sorted(missing.items()):
        print(f"【红】链接清单缺头文件 {rel}（{d} 实读）：清单过期，重跑 graphics/nvn/tests/t_present_settings_closure.py")
    return 1 if missing else 0


def symbols(paths):
    """nm -m → (定义的, 强引用的, 弱引用的) 外部符号"""
    r = subprocess.run(["nm", "-m", *paths], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"【红】nm 读不了链接输入：{r.stderr.strip()[-300:]}")
    defined, strong, weak = set(), set(), set()
    for line in r.stdout.splitlines():
        m = re.search(r"\(undefined\) (weak )?external (\S+)", line)
        if m:
            (weak if m.group(1) else strong).add(m.group(2))
            continue
        m = re.search(r"\) (?:weak )?external (?:\[[^\]]*\] )?(\S+)$", line)
        if m:
            defined.add(m.group(1))
    return defined, strong, weak


def map_members(mapf):
    """链接映射的「# Object files:」段 → 链进来的静态库成员 {(库路径, 成员名)}"""
    out, on = set(), False
    for line in open(mapf, encoding="utf-8", errors="replace"):
        if line.startswith("# Object files:"):
            on = True; continue
        if line.startswith("# Sections:"):
            break
        m = re.match(r"\[\s*\d+\]\s+(.*\.a)\((.+)\)$", line.rstrip("\n")) if on else None
        if m:
            out.add((os.path.realpath(m.group(1)), m.group(2)))
    return out


def _repo_rel(path, root):
    """DWARF 里的路径（相对库的构建目录写的 ../../x 或绝对路径）→ 仓库内相对路径；仓库外 / build/ 下 / 不存在 → None"""
    if os.path.isabs(path):
        rp = os.path.realpath(path)
        rel = rp[len(root) + 1:] if rp.startswith(root + "/") else None
    else:
        rel = os.path.normpath(re.sub(r"^(\.\./)+", "", re.sub(r"^(\./)+", "", path)))
    if not rel or rel.startswith(("build/", "../")) or not os.path.isfile(os.path.join(root, rel)):
        return None
    return rel


def lib_files(lib, root):
    """静态库每个成员 → 行号表 file_names 里的全部文件（编译单元源文件 + 实读头文件），换成仓库内路径：{成员名: {路径…}}。
    成员都带 -g 编（graphics/nvn、metal、dsx 的 Makefile）；取不到行号表的成员记空集，由调用方报红（不猜）"""
    root = os.path.realpath(root)
    r = subprocess.run(["xcrun", "dwarfdump", "--debug-line", lib], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"【红】dwarfdump 读不了 {lib}：{r.stderr.strip()[-300:]}")
    res, cur, dirs, name = {}, None, [], None
    for line in r.stdout.splitlines():
        m = re.match(r"^\S.*\((.+?)\):\s+file format", line)
        if m:
            cur, dirs, name = m.group(1), [], None
            res.setdefault(cur, set()); continue
        if cur is None:
            continue
        m = re.match(r'^include_directories\[\s*(\d+)\] = "(.*)"', line)
        if m:
            dirs.append(m.group(2)); continue
        m = re.match(r'^\s+name: "(.*)"', line)
        if m:
            name = m.group(1); continue
        m = re.match(r"^\s+dir_index: (\d+)", line)
        if m and name is not None:
            i = int(m.group(1)); d = dirs[i] if i < len(dirs) else "."
            # 两种写法都见过：目录 + 相对名（../../../../graphics/…，相对库的构建目录）；或编译时做过路径前缀映射、名字本身就是 ./graphics/…，
            #   目录 0 却是已删的临时编译目录（拼起来落到 build/ 下）。依次试，取第一个落在仓库里的
            rel = None if os.path.isabs(name) else _repo_rel(os.path.join(d, name), root)
            rel = rel or _repo_rel(name, root)
            if rel:
                res[cur].add(rel)
            name = None
    return res


SRC_EXT = (".c", ".m", ".mm", ".cpp", ".cc", ".S", ".s")


def cu_names(lib, root):
    """debug-info 的编译单元名（汇编 / 只有数据的成员没有行号表时兜底）→ {成员名: 仓库内路径}"""
    root = os.path.realpath(root)
    r = subprocess.run(["xcrun", "dwarfdump", "--debug-info", "--recurse-depth=0", lib], capture_output=True, text=True)
    out, cur = {}, None
    for line in r.stdout.splitlines():
        m = re.match(r"^\S.*\((.+?)\):\s+file format", line)
        if m:
            cur = m.group(1); continue
        m = re.match(r'^\s+DW_AT_name\s+\("(.*)"\)', line)
        if m and cur and cur not in out:
            rel = _repo_rel(m.group(1), root)
            if rel:
                out[cur] = rel
    return out


def by_name(member, tracked):
    """成员名 → 仓库里同名的源文件（成员名有两种写法：源路径 / 换成 _ 加 .o，或去掉扩展名加 .o）；重名全收（宁多不漏）"""
    stem = member[:-2] if member.endswith(".o") else member
    src = [f for f in tracked if f.endswith(SRC_EXT)]
    flat = [f for f in src if "/" in f and stem.endswith("_" + f.replace("/", "_"))]   # 绝对路径换 _ 的成员名（graphics/nvn 的 tex / gl 子目录）
    if flat:
        return flat
    return [f for f in src if os.path.basename(f) == stem or os.path.splitext(os.path.basename(f))[0] == stem]


def pulled_files(mapf, root, libs):
    """链进来的库成员 → 它们的仓库内源文件 / 头文件集合；以及哪种办法都对不上源文件的成员。
    先看行号表（源文件 + 实读头文件）；没有行号表的（汇编、只有数据的源文件）退到编译单元名，再退到按成员名找同名源文件"""
    root = os.path.realpath(root)
    want = {os.path.realpath(l) for l in libs}
    mem = map_members(mapf)
    files, blind, tracked = set(), [], None
    for lib in sorted(want):
        names = {m for l, m in mem if l == lib}
        if not names:
            continue
        info, cus = lib_files(lib, root), None
        for m in sorted(names):
            fs = info.get(m)
            if not fs:
                cus = cus if cus is not None else cu_names(lib, root)
                if m in cus:
                    fs = {cus[m]}
                else:
                    if tracked is None:
                        tracked = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True).stdout.split("\n")
                    fs = set(by_name(m, tracked))
            if fs:
                files |= fs
            else:
                blind.append(f"{os.path.basename(lib)}({m})")
    return files, blind


def libcheck(lst, mapf, root, libs):
    e = entries(lst)
    listed = set(e["lib"]) | set(e["src"]) | set(e["hdr"]) | {MAIN}
    files, blind = pulled_files(mapf, root, libs)
    for b in blind:
        print(f"【红】链进来的库成员 {b} 对不上源文件（行号表、编译单元名、同名源文件都没有），门禁输入会漏：查这个库的编译参数是否带 -g、成员名怎么来的")
    missing = sorted(files - listed)
    for rel in missing:
        print(f"【红】链接清单缺库成员文件 {rel}（链进来的静态库成员读了它）：清单过期，重跑 graphics/nvn/tests/t_present_settings_closure.py")
    return 1 if missing or blind else 0


def referrers(sym, inputs):
    """链接输入里谁引用了 sym（未定义）→ 「文件」或「库(成员)」列表"""
    r = subprocess.run(["nm", "-A", "-u", *inputs], capture_output=True, text=True)
    out = []
    for line in r.stdout.splitlines():
        head, _, name = line.rpartition(" ")
        if name == sym:
            out.append(head.rstrip(":").replace(".a:", ".a(").rstrip() + (")" if ".a:" in head else ""))
    return out


def dynamic(exe):
    r = subprocess.run(["nm", "-m", exe], capture_output=True, text=True, check=True)
    return {m.group(1) for m in re.finditer(r"\(undefined\) (?:weak )?external (\S+) \(dynamically looked up\)", r.stdout)}


def main(a):
    if len(a) == 2 and a[0] == "sources":
        print("\n".join(entries(a[1])["src"]))
        return 0
    if len(a) >= 3 and a[0] == "depcheck":
        return depcheck(a[1], a[2], a[3:])
    if len(a) >= 2 and a[0] == "weak":
        defined, strong, weak = symbols(a[1:])
        print(" ".join(weak_link_decl.u_flags(s[1:] for s in weak - defined - strong if s.startswith("_"))))
        return 0
    if len(a) >= 5 and a[0] == "libcheck":
        return libcheck(a[1], a[2], a[3], a[4:])
    if len(a) >= 3 and a[0] == "dyncheck":
        extra = sorted(dynamic(a[2]) - set(entries(a[1])["dyn"]))
        for s in extra:
            who = referrers(s, a[3:]) if len(a) > 3 else []
            print(f"【红】{s} 链接后成了运行期查找（清单 dyn 行里没有）{'：引用方 ' + '、'.join(who) if who else ''}。"
                  f"若是有意的（提供者不链进本测），清单加一行「dyn {s}」；否则是缺定义。重跑 graphics/nvn/tests/t_present_settings_closure.py 会同时补齐")
        return 1 if extra else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
