#!/usr/bin/env python3
"""VM 跑器端点核对：svc_*.c 引用的 core 符号必须在 run.py 链接集合里有定义。

svc_mem.c 往 core 加新外部符号时，run.py 的合成 / 真实端点集合要同步登记；
漏登记此前只在 Linux 真链时才红（10-28 guest_page_test、11-06 四符号同类）。
本检查在任意宿主（含 macOS）直接编译 svc_*.c、用 nm 取未定义符号，与 run.py
链接清单里各源的顶层定义核对，漏登记当场红，不等链接期。

口径：
- 引用侧 = run.py 实际编译的 svc 对象（缺省 runtime/src/svc_*.c 全部）经 cc -c
  产物的 nm 未定义符号；weak 未定义是「可选接缝」（缺省 NULL 为设计语义），点名不判红。
- 提供侧 = run.py 的 sources 清单 + 其编译的 svc/track 源 + 各源 #include 的
  .inc/.c（core_endpoints.inc 由此进集合）里扫到的顶层函数 / 变量定义，两种编译
  宏环境（svc 的 -D__ANDROID__ 与其余源）的并集；static 定义不算提供。
- libc / 工具链运行时 / 夹具宏生成名在 SYSTEM_EXTERNALS 逐名登记，新增系统引用
  或新生成宏往那里补一行并注明来由。
"""
import argparse
import ast
import platform
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))  # android/core-link
import link_symbols as ls


# libc / 语言运行时 / 夹具宏展开名：svc_*.c 可以引用、不算 core 端点缺口，逐名登记。
SYSTEM_EXTERNALS = {
    # libc / libdl / pthread
    "abort", "bzero", "calloc", "clock_gettime", "dlsym", "fclose", "fgets",
    "fopen", "fread", "fscanf", "fseek", "free", "getenv", "getline", "madvise",
    "malloc", "memcpy", "memset", "mmap", "mprotect", "munmap", "mremap",
    "nanosleep", "pause", "pthread_create", "pthread_detach",
    "pthread_mutex_lock", "pthread_mutex_trylock", "pthread_mutex_unlock",
    "pthread_self", "snprintf", "sscanf", "strcmp", "strrchr", "strstr",
    "strtoull", "vsnprintf", "write", "fallocate", "getpid", "gettid",
    "sched_yield", "syscall", "usleep", "sysconf", "prctl", "sigaction",
    "sigemptyset", "sigprocmask", "dladdr",
    "_exit",      # native.h 的 quiet fatal 路径：libc 进程退出，不是 core 端点
    "strcspn",   # 11-05 b273f2ef6 svc_mem.c 解析布局提示行（去掉行尾换行）
    # 工具链 / 运行库内部（GCC / clang / Mach-O 各自形态）
    "_GLOBAL_OFFSET_TABLE_", "__errno_location", "__error", "__getdelim",
    "__isoc23_fscanf", "__isoc23_sscanf", "__isoc23_strtoull", "__popcountdi2",
    "__snprintf_chk", "__stack_chk_fail", "__stack_chk_guard",
    "_tlv_bootstrap", "__udivti3", "__vsnprintf_chk", "__isoc99_fscanf",
    "__isoc99_sscanf",
    # GCC aarch64 LSE 原子辅助
    "__aarch64_cas1_acq_rel", "__aarch64_cas2_acq_rel",
    "__aarch64_cas4_acq_rel", "__aarch64_cas8_acq_rel",
    "__aarch64_cas16_acq_rel", "__aarch64_ldadd1_acq_rel",
    "__aarch64_ldadd2_acq_rel", "__aarch64_ldadd4_acq_rel",
    "__aarch64_ldadd8_acq_rel", "__aarch64_ldclr1_acq_rel",
    "__aarch64_ldclr2_acq_rel", "__aarch64_ldclr4_acq_rel",
    "__aarch64_ldclr8_acq_rel", "__aarch64_ldset1_acq_rel",
    "__aarch64_ldset2_acq_rel", "__aarch64_ldset4_acq_rel",
    "__aarch64_ldset8_acq_rel", "__aarch64_swp1_acq_rel",
    "__aarch64_swp2_acq_rel", "__aarch64_swp4_acq_rel",
    "__aarch64_swp8_acq_rel", "__aarch64_swp16_acq_rel",
    # vm_test.c:89 S2A_TEST_MOD_TABLE(64) 宏展开的夹具全局（宏体扫不到定义）
    "g_mod", "g_mod_cap",
}


def cc_args(root, cc, source, obj, android):
    """与 run.py 的 svc 编译同口径；去掉 -Werror（不同宿主编译器告警面不同）。"""
    args = [cc, "-D_GNU_SOURCE", "-DS2A_UNIT_TEST", "-std=gnu11", "-O2",
            "-Wall", "-Wextra", "-Wno-implicit-function-declaration",
            "-pthread", "-Iruntime/include", "-Iruntime/src",
            "-Iandroid/native"]
    if android:
        args.append("-D__ANDROID__")
    return args + ["-c", str(source), "-o", str(obj)]


def undefined_symbols(cc, root, source, work):
    """编译一个 svc 源到 work/，返回 (硬性未定义集, weak 未定义集)。"""
    obj = Path(work) / (Path(source).stem + ".o")
    build = subprocess.run(cc_args(root, cc, source, obj, android=True),
                           cwd=root, capture_output=True, text=True)
    if build.returncode:
        raise SystemExit("【红】端点核对：%s 按 -D__ANDROID__ 编译失败，无法取符号：\n%s"
                         % (source, (build.stderr or build.stdout)[-2000:]))
    required, weak = set(), set()
    if platform.system() == "Darwin":
        # Mach-O：'(undefined) [weak] external _name'；C 符号带 '_' 前缀，剥一层。
        out = subprocess.run(["nm", "-m", str(obj)], capture_output=True, text=True)
        for line in out.stdout.splitlines():
            m = re.search(r"\(undefined\)\s+(weak\s+)?external\s+(\S+)", line)
            if not m:
                continue
            name = m.group(2)
            if name.startswith("_"):
                name = name[1:]
            (weak if m.group(1) else required).add(name)
    else:
        out = subprocess.run(["nm", "-P", "-u", str(obj)], capture_output=True, text=True)
        for line in out.stdout.splitlines():
            m = re.match(r"(\S+)\s+(\S)", line)
            if not m:
                continue
            (weak if m.group(2) in ("w", "v") else required).add(m.group(1))
    if not required and not weak:
        raise SystemExit("【红】端点核对：nm 没有读出 %s 的未定义符号（空集 = 口径失效）" % obj)
    return required, weak


def link_inputs(run_py):
    """从 run.py 源码取链接集合：sources 清单 + svc/track 编译对象源；解析失败报红。"""
    text = run_py.read_text(encoding="utf-8")
    m = re.search(r"\bsources\s*=\s*(\[[^\]]*\])", text, re.S)
    if not m:
        raise SystemExit("【红】端点核对：run.py 找不到 sources=[...] 链接清单")
    sources = list(ast.literal_eval(m.group(1)))
    m = re.search(r"for\s+label\s*,\s*src\s*,\s*extra\s+in\s*(\[)", text)
    if not m:
        raise SystemExit("【红】端点核对：run.py 找不到编译对象循环")
    depth, i = 0, m.start(1)
    while i < len(text):
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
            if not depth:
                break
        elif text[i] in "'\"":
            q = text[i]
            i = text.find(q, i + 1)
            if i < 0:
                break
        i += 1
    objects = re.findall(r"'([^']+\.c)'", text[m.start(1):i + 1])
    if not objects:
        raise SystemExit("【红】端点核对：run.py 编译对象循环里读不到 .c 源")
    return sources, objects


def statement_definitions(text, defines):
    """扫顶层定义：函数（非 static）与变量（非 static、非 extern、非 typedef）。"""
    text = ls.preprocess_active_lines(text, defines)
    text = ls.strip_c_comments(text)
    defs = {}
    depth, i, n = 0, 0, len(text)
    boundary = True
    while i < n:
        c = text[i]
        if c == "{":
            depth += 1
            i += 1
            boundary = True
            continue
        if c == "}":
            depth = max(0, depth - 1)
            i += 1
            boundary = True
            continue
        if c == ";":
            boundary = True
            i += 1
            continue
        if depth or not boundary or c.isspace():
            i += 1
            continue
        boundary = False
        j = i
        while j < n and text[j] not in ";{}":
            j += 1
        stmt = text[i:j]
        terminal = text[j] if j < n else ""
        if "(" in stmt and terminal == "{":
            # 函数定义：取「形参表后紧跟 {」的那个 name(。
            for fm in re.finditer(r"([A-Za-z_]\w*)\s*\(", stmt):
                p = stmt.find("(", fm.start())
                pd, k = 0, p
                while k < len(stmt):
                    if stmt[k] == "(":
                        pd += 1
                    elif stmt[k] == ")":
                        pd -= 1
                        if not pd:
                            break
                    k += 1
                rest = re.sub(r"__attribute__\s*\(\([^)]*\)\)", "", stmt[k + 1:])
                if not rest.strip():
                    defs[fm.group(1)] = "static" in stmt[:fm.start()].split()
                    break
        elif terminal == "{" and "=" in stmt:
            # 花括号初始化的变量：int x[] = {...}
            for piece in stmt.split("=", 1)[0].split(","):
                names = re.findall(r"([A-Za-z_]\w*)", piece)
                if names:
                    defs[names[-1]] = "static" in stmt.split()
        elif terminal == ";" and "typedef" not in stmt.split() and "extern" not in stmt.split():
            # 变量定义：逐 declarator 取名（*a, b[4], (*fp)(args), c=1）；原型声明不进。
            for piece in re.split(r",(?![^()]*\))", stmt):
                fp = re.search(r"\(\s*\*\s*([A-Za-z_]\w*)\s*\)", piece)
                if fp:
                    defs[fp.group(1)] = "static" in stmt.split()
                elif "(" in piece:
                    continue  # 函数原型 / 函数指针之外的括号形态
                else:
                    names = re.findall(r"([A-Za-z_]\w*)", piece)
                    if names:
                        defs[names[-1]] = "static" in stmt.split()
        i = j if j > i else i + 1
    return {name for name, is_static in defs.items() if not is_static}


def provided_symbols(root, files):
    """两种编译宏环境（svc 的 __ANDROID__ 与其余源）下扫到的顶层非 static 定义并集。"""
    env_templates = []
    for android in (True, False):
        d = ls.Defines("diagnostic")
        d.values["S2A_UNIT_TEST"] = "1"
        if not android:
            for key in ("__ANDROID__", "ANDROID", "S2A_ANDROID_GAME_RUNTIME",
                        "S2A_CS_STATIC", "VK_USE_PLATFORM_ANDROID_KHR",
                        "__aarch64__", "__arm64__"):
                d.values[key] = "0"
        env_templates.append(dict(d.values))
    provided = set()
    for path in ls.expand_local_includes(files, root):
        if path.suffix not in (".c", ".inc"):
            continue
        if not path.is_file():
            continue
        raw = path.read_text(encoding="utf-8", errors="replace")
        for template in env_templates:
            defines = ls.Defines("diagnostic")
            defines.values = dict(template)  # 每文件一份干净模板，不吃别文件的 #define
            provided |= statement_definitions(raw, defines)
    return provided


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path,
                    default=Path(__file__).resolve().parents[4])
    ap.add_argument("--cc", default="cc")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--svc-source", type=Path, action="append",
                    help="追加核对的 svc 源（run.py --svc-source 口径）")
    args = ap.parse_args()
    root = args.root.resolve()
    work = args.out or Path(tempfile.mkdtemp(prefix="s2a-vm-endpoints-"))
    work.mkdir(parents=True, exist_ok=True)

    vm_dir = root / "android/core-link/runtime-tests/vm"
    sources, objects = link_inputs(vm_dir / "run.py")
    svc_files = sorted(root.glob("runtime/src/svc_*.c"))
    if args.svc_source:
        svc_files += [p.resolve() for p in args.svc_source]
    if not svc_files:
        raise SystemExit("【红】端点核对：runtime/src 下没有 svc_*.c")

    # 提供侧：链接清单 + 编译对象源；--svc-source 替换缺省 svc_mem.c（run.py 同口径）。
    svc_stem_names = {p.name for p in svc_files}
    provider_files = [root / s for s in sources]
    provider_files += [root / s for s in objects
                       if Path(s).name in svc_stem_names or s == "graphics/track/track.c"]
    provided = provided_symbols(root, provider_files)

    missing, weak_names, checked = [], [], 0
    for src in svc_files:
        required, weak = undefined_symbols(args.cc, root, src, work)
        checked += len(required)
        weak_names += sorted(weak - provided - SYSTEM_EXTERNALS)
        for name in sorted(required - provided - SYSTEM_EXTERNALS):
            missing.append("%s:%s" % (src.relative_to(root), name))
    if missing:
        print("【红】VM 端点核对：svc_*.c 引用的符号不在 run.py 链接集合里（共 %d 个）：" % len(missing))
        for name in missing:
            print("  %s" % name)
        print("修法：优先把真实生产源加进 run.py sources（无平台依赖时），"
              "否则在 core_endpoints.inc 按生产语义实现合成端点。")
        return 1
    print("VM 端点核对：%d 个 svc 对象 %d 个未定义符号全部有着落；weak 可选接缝 %d 个"
          % (len(svc_files), checked, len(set(weak_names))))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
