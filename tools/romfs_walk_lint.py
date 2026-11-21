#!/usr/bin/env python3
"""RomFS 目录遍历守卫（11-03 维护者根修「RomFS 只遍历一次」）：仓库里遍历 RomFS 目录只许出现在 graphics/nvn/tools/romfs_list.py 一处，
其余代码一律经它（walk / scan / heads / listdir，shell 用 romfs_list.py has-ext / files0）。出处：一键出包里 6–8 个步骤各自 os.walk + 逐个打开读头，
火纹 27 万文件配置推导单次 337 秒、GLSLC 判要不要 82 秒、能力清单 326 秒。

判法（静态，按「这次遍历的目标是不是 RomFS」）：
  Python（.py，以及 .sh 里内嵌的 Python 段）：遍历调用 = os.walk / os.fwalk / os.scandir / os.listdir / glob.glob / glob.iglob / 任意对象的 .rglob / .iterdir / .glob
    （re.glob 之类不算；romfs_list.* 本身不算）。目标是 RomFS ⇔ 参数（含方法的接收者）文字里有 romfs，或参数里的变量在同一函数里由含 romfs 的式子赋值 / 循环取值；
    递归类（os.walk / os.fwalk / os.scandir / .rglob / 带 ** 的 glob）另加：所在函数里有含 romfs 的字符串常量（文档字符串不算，那是说明文字）。
  shell（.sh）：find / ls -R / du 的同一条命令里出现 romfs（字面或由含 romfs 的变量给出）；内嵌 Python 段（<<'X' … X）开头那行带 romfs、段里有遍历调用。
  C#（.cs）：Directory.EnumerateFiles / GetFiles / EnumerateDirectories / GetDirectories / EnumerateFileSystemEntries / GetFileSystemEntries，文件里提到 romfs。
不扫：compat/（上游树）、tests 目录（单测自建夹具）、romfs_list.py 本身、本文件。
白名单 ALLOW：确实要自己读 RomFS 目录的运行期 / 非出包代码，或误判（目标不是 RomFS），逐条写理由；白名单里的条目已不再命中时报「白名单过期」（也算红，删掉那行）。
用法：romfs_walk_lint.py [仓库根]   退出 0 = 没有；1 = 逐条点名「文件:行: 范围: 原文」
"""
import ast
import os
import re
import subprocess
import sys

MODULE = "graphics/nvn/tools/romfs_list.py"
SELF = "tools/romfs_walk_lint.py"
R = re.compile("romfs", re.I)
# shell 里作目录名的 romfs（romfs_list.py、romfs.s2aidx 不算）
RDIR = re.compile(r"romfs(?![\w.])", re.I)
CALLS = {"walk", "fwalk", "scandir", "listdir", "glob", "iglob", "rglob", "iterdir"}
RECURSIVE = {"walk", "fwalk", "scandir", "rglob"}
CS = re.compile(r"Directory\.(Enumerate|Get)(Files|Directories|FileSystemEntries)\s*\(")

# (文件, 范围（Python 函数名 / shell 行内特征串 / C# 方法外层：*）) → 理由
ALLOW = {
    ("pack/img.py", "convert:walk"):
        "误判：删的是出包目录 pack_dir 里搬进 game.img 后留下的空目录（自下而上），不是 RomFS",
    ("translator/shader_split.py", "main:listdir"):
        "误判：列的是 RomFS 旁边的 glslc_capture/、ue_shaders/ 与输出目录（路径由 RomFS 路径的上一级拼出），不是 RomFS；RomFS 本身经 romfs_list.walk",
    ("pack/stage_uilayout.sh", "$T/romfs"):
        "误判：$T/romfs 是界面布局生成器刚写出的覆盖层（只含改过的几个包），不是游戏 RomFS",
    ("pack/stage_uilayout.sh", "$OV/romfs"):
        "误判：$OV/romfs 是界面布局覆盖包（只含改过的几个包），列出来进键，不是游戏 RomFS",
    ("tools/clonedir.py", "mac_snapshot:walk"):
        "误判：pack/roots.sh 给 clonedir 的 romfs 是「跳过名单」（RomFS 是共享存储软链，克隆时跳过、另建软链），不是要它遍历的目录；"
        "这处 os.walk 是克隆完给目录补写权限，整根快照本来就要逐目录走",
    ("services/S2A.Services/RomFsIndex.cs", "*"):
        "不给清单时的现枚举只给运行期 / 单测（安卓 core-runtime 单测直接调 Write(目录, 输出)）；出包期 romfsidx 阶段一律带 --list（romfs_list.py sizes 盘点）",
    ("services/S2A.Services/Application.cs", "*"):
        "运行期（起局）：没有预建索引时现建 RomFS 镜像，要在设备上枚举游戏目录；出包期不经这里",
    ("services/S2A.Services/Host.cs", "*"):
        "运行期（宿主服务）：设备上读游戏数据目录，不是出包步骤",
    ("pack/jobs/mods.py", "_find:rglob"):
        "误判：导入 / 列出的是玩家给的 mod 压缩包或文件夹（只有 mod 自己的几个文件），不是游戏 RomFS；不进出包流程",
    ("services/S2A.Services/RomFsMods.cs", "*"):
        "运行期（起局）：列的是玩家放进 <文档根>/mods/ 的 mod 文件夹（只有 mod 自己的几个文件），不是游戏 RomFS；游戏 RomFS 经 LibHac 文件表读，不遍历目录",
}


def tracked(root):
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True, check=True).stdout
    for f in out.decode("utf-8", "surrogateescape").split("\0"):
        if not f or f in (MODULE, SELF) or f.startswith("compat/") or re.search(r"(^|/)[^/]*tests?/", f, re.I):
            continue
        if f.endswith((".py", ".sh", ".cs")):
            yield f


def _call_name(call):
    """遍历调用的名字；不是遍历调用 → None。os.walk / os.fwalk / os.scandir / os.listdir、glob.glob / glob.iglob、任意对象的 .rglob / .iterdir / .glob（re.* 与 romfs_list.* 除外）"""
    fn = call.func
    if not isinstance(fn, ast.Attribute) or fn.attr not in CALLS:
        return None
    base = fn.value.id if isinstance(fn.value, ast.Name) else None
    if base in ("re", "romfs_list"):
        return None
    if fn.attr in ("walk", "fwalk", "scandir", "listdir") and base != "os":
        return None
    if fn.attr == "iglob" and base != "glob":
        return None
    return fn.attr


def python_hits(src, offset=0, scope_hint=None, every=False, receiver=False):
    """→ [(行号, 范围名「函数:调用」, 原文)]；every = 段里的遍历调用一律算（shell 内嵌段开头那行已表明目标是 RomFS）；
    receiver = 本文件是收 RomFS 目录作参数的工具（shell 阶段把 RomFS 交给它）：递归遍历一律算"""
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return []
    parent = {}
    for p in ast.walk(tree):
        for c in ast.iter_child_nodes(p):
            parent[c] = p
    lines = src.split("\n")
    # 文档字符串是说明文字、不是代码：函数说明里提到 romfs（比如「推 romfs.img 后核大小」）不算这个函数在遍历 RomFS
    docs = {id(n.body[0].value) for n in ast.walk(tree)
            if isinstance(n, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and n.body
            and isinstance(n.body[0], ast.Expr) and isinstance(n.body[0].value, ast.Constant) and isinstance(n.body[0].value.value, str)}
    out = []
    for call in ast.walk(tree):
        if not isinstance(call, ast.Call):
            continue
        name = _call_name(call)
        if not name:
            continue
        scope = call
        while scope in parent and not isinstance(scope, (ast.FunctionDef, ast.AsyncFunctionDef)):
            scope = parent[scope]
        scope_name = getattr(scope, "name", scope_hint or "<module>")
        seg = lambda n: ast.get_source_segment(src, n) or ""
        targets = list(call.args) + ([call.func.value] if isinstance(call.func, ast.Attribute) else [])
        text = " ".join(seg(a) for a in targets)
        names = {n.id for a in targets for n in ast.walk(a) if isinstance(n, ast.Name)}
        hit = every or bool(R.search(text))
        if not hit:
            for a in ast.walk(scope):
                tg, value = None, None
                if isinstance(a, ast.Assign):
                    tg, value = a.targets, a.value
                elif isinstance(a, (ast.AnnAssign, ast.AugAssign)) and a.value is not None:
                    tg, value = [a.target], a.value
                elif isinstance(a, (ast.For, ast.comprehension)):
                    tg, value = [a.target], a.iter
                if tg and any(isinstance(t, ast.Name) and t.id in names for x in tg for t in ast.walk(x)) and R.search(seg(value)):
                    hit = True
                    break
        recursive = name in RECURSIVE or (name in ("glob", "iglob") and "**" in text)
        if not hit and recursive and receiver:
            hit = True
        if not hit and recursive:
            # romfs_list.*(…) 参数里的常量不算（已经经模块了）
            skip = {id(c) for n in ast.walk(scope) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                    and isinstance(n.func.value, ast.Name) and n.func.value.id == "romfs_list" for c in ast.walk(n)}
            hit = any(isinstance(c, ast.Constant) and isinstance(c.value, str) and R.search(c.value) and id(c) not in skip and id(c) not in docs
                      for c in ast.walk(scope))
        if hit:
            out.append((call.lineno + offset, f"{scope_name}:{name}", lines[call.lineno - 1].strip()))
    return out


HEREDOC = re.compile(r"<<-?\s*['\"]?(\w+)['\"]?")


def shell_hits(src):
    out = []
    lines = src.split("\n")
    romfs_vars = set()
    for l in lines:
        for m in re.finditer(r"\b([A-Za-z_]\w*)=([^\s;]*)", l):
            if RDIR.search(m.group(2)):
                romfs_vars.add(m.group(1))
    i = 0
    while i < len(lines):
        l = lines[i]
        m = HEREDOC.search(l) if not l.lstrip().startswith("#") else None
        if m and re.search(r"\bpython3?\b|\$\{?\w*PY\w*\}?\"?\s+-(\s|$)", l):
            end = next((j for j in range(i + 1, len(lines)) if lines[j].strip() == m.group(1)), len(lines))
            body = "\n".join(lines[i + 1:end])
            opener = bool(RDIR.search(l)) or bool(set(re.findall(r"\$\{?([A-Za-z_]\w*)", l)) & romfs_vars)
            out += [(ln, "内嵌 Python", text) for ln, _, text in python_hits(body, i + 1, "内嵌 Python", every=opener)]
            i = end + 1
            continue
        if not l.lstrip().startswith("#"):
            for seg in re.split(r"\|\||&&|[;|]|\$\(", l):
                if not re.search(r"(^|\s)(find|du)\s|(^|\s)ls\s+-\w*R", seg):
                    continue
                # romfs 作目录名才算（romfs_list.py、romfs.s2aidx 不算）；目标可能是同一行前一段 cd 进去的目录（cd "$X/romfs" && find .）
                used = set(re.findall(r"\$\{?([A-Za-z_]\w*)", seg))
                cd = re.search(r"\bcd\s+(\S*" + RDIR.pattern + r"\S*)", l)
                if RDIR.search(seg) or used & romfs_vars or (cd and re.search(r"\bfind\s+\.(\s|$)", seg)):
                    key = next((t for t in re.findall(r"\$\{?\w+\}?/romfs", seg if RDIR.search(seg) else cd.group(1) if cd else seg)), None)
                    out.append((i + 1, key or "find", l.strip()))
        i += 1
    return out


def cs_hits(src):
    if not R.search(src):
        return []
    return [(i, "*", l.strip()) for i, l in enumerate(src.split("\n"), 1) if CS.search(l) and not l.lstrip().startswith("//")]


# shell 命令里点到的 .py（去掉打头的 $R/ 之类变量前缀）
PYARG = re.compile(r"(?:\$\{?(\w+)\}?/)?([\w./-]+\.py)\b")


def receivers(root, files):
    """收 RomFS 目录作参数的 Python 工具：shell 里同一条命令既点了 <某>.py、参数里又有 RomFS 目录（字面 …/romfs 或由它赋值的变量）"""
    out = set()
    for f in files:
        if not f.endswith(".sh"):
            continue
        src = open(os.path.join(root, f), encoding="utf-8", errors="surrogateescape").read()
        assigns = {}
        for m in re.finditer(r"(?m)\b([A-Za-z_]\w*)=(\S+)", src):
            assigns.setdefault(m.group(1), []).append(m.group(2))
        rvars = {v for v, vals in assigns.items() if any(RDIR.search(x) for x in vals)}
        for l in src.split("\n"):
            if l.lstrip().startswith("#"):
                continue
            for seg in re.split(r"\|\||&&|[;|]", l):
                used = set(re.findall(r"\$\{?([A-Za-z_]\w*)", seg))
                if not (RDIR.search(re.sub(r"\S+\.py\b", "", seg)) or used & rvars):
                    continue
                pys = PYARG.findall(seg)
                for v in used:
                    pys += [x for val in assigns.get(v, []) for x in PYARG.findall(val)]
                for var, py in pys:
                    # 前缀变量是仓库里的目录（NX=$R/graphics/nvn）就接上它
                    base = next((m.group(1) for val in assigns.get(var, []) for m in [re.match(r"\$\{?\w+\}?/([\w./-]+)$", val)] if m), "")
                    rel = (base.rstrip("/") + "/" + py.lstrip("./")) if base else py.lstrip("./")
                    if rel in files:
                        out.add(rel)
    return out


def main(argv):
    root = os.path.abspath(argv[0] if argv else os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    bad, used = [], set()
    files = list(tracked(root))
    takes = receivers(root, files)
    for f in files:
        try:
            src = open(os.path.join(root, f), encoding="utf-8", errors="surrogateescape").read()
        except OSError:
            continue
        hits = python_hits(src, receiver=f in takes) if f.endswith(".py") else shell_hits(src) if f.endswith(".sh") else cs_hits(src)
        for ln, scope, text in hits:
            if (f, scope) in ALLOW:
                used.add((f, scope))
                continue
            bad.append(f"{f}:{ln}: {scope}: {text[:200]}")
    for key in ALLOW:
        if key not in used and os.path.exists(os.path.join(root, key[0])):
            bad.append(f"白名单过期（{key[0]} 的 {key[1]} 已不再命中，删掉 ALLOW 里这一条）")
    for b in bad:
        print(b)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
