#!/usr/bin/env python3
"""头文件改动 → 受影响的源文件（runtime/gate.sh 只编模式按改动收窄用，11-24）。
用法：include_closure.py <改动的头文件…>   （路径相对仓库根；在仓库根跑）
输出：每行一个受影响的 C 系源文件（.c .m .mm .cpp .cc .S .s），即直接或经别的头文件间接 include / import 了这些头文件的源。
做法：扫仓库里所有登记的 C 系文件的 #include / #import（引号、尖括号都扫），按「被改头文件路径以 include 串结尾」匹配，
  只认文件名相同的才算（宁可多算不可漏）；从改动头文件出发反向找，直到不再有新的头文件。用宏拼出来的 include 认不出——这种照旧会漏，
  调用方只在「改动全是 C 源 / 头文件」时才用本结果收窄，其余全跑。"""
import os
import re
import subprocess
import sys

SRC = (".c", ".m", ".mm", ".cpp", ".cc", ".S", ".s")
HDR = (".h", ".inc", ".hpp", ".hh", ".def")
INC = re.compile(rb'^\s*#\s*(?:include|import)\s*[<"]([^>"]+)[>"]', re.M)


def tracked():
    out = subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True).stdout
    return [p.decode() for p in out.split(b"\0") if p and p.decode().endswith(SRC + HDR)]


def includes_of(path):
    try:
        with open(path, "rb") as f:
            return [m.decode(errors="replace") for m in INC.findall(f.read())]
    except OSError:
        return []


def hits(header, inc):
    """include 串 inc 指的可能是 header：文件名相同，且 header 路径以 inc 结尾（按目录边界）"""
    inc = inc.lstrip("./")
    return os.path.basename(inc) == os.path.basename(header) and (header == inc or header.endswith("/" + inc))


def closure(changed, files):
    by_name = {}
    for f in files:
        for inc in includes_of(f):
            by_name.setdefault(os.path.basename(inc), []).append((f, inc))
    todo, seen, srcs = list(changed), set(changed), set()
    while todo:
        h = todo.pop()
        for f, inc in by_name.get(os.path.basename(h), []):
            if not hits(h, inc) or f in seen:
                continue
            seen.add(f)
            if f.endswith(SRC):
                srcs.add(f)
            else:
                todo.append(f)
    return sorted(srcs)


def main(argv):
    changed = [a.lstrip("./") for a in argv[1:] if a.endswith(HDR)]
    if not changed:
        return 0
    for s in closure(changed, tracked()):
        print(s)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
