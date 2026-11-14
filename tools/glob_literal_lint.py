#!/usr/bin/env python3
"""glob 路径字面量守卫：出货代码里 glob.glob / glob.iglob 拼进去的目录（游戏库、工作目录、原件、主目录、安装目录）要先 glob.escape，
否则目录名里的 [ ] * ? 被当成模式（#1009：游戏库在「D:\\…\\[2]NS…」下，[2] 被当成字符类，一份 .pk 都找不到，出包整个失败）。
用法：glob_literal_lint.py <仓库根>：扫 pack/ launchers/ graphics/tools/direct/ graphics/tools/shbake/srcpack.py 的 .py（tests/ 除外），
调用参数里没有 glob.escape( 的逐行打印「文件:行」，有就退 1。参数整段是字符串常量（不含路径变量）的不算。行尾写 `glob-literal-ok: 原因` 可豁免。"""
import ast, os, sys

SCOPES = ("pack", "launchers", os.path.join("graphics", "tools", "direct"), os.path.join("graphics", "tools", "shbake", "srcpack.py"))


def files(root):
    for s in SCOPES:
        p = os.path.join(root, s)
        if os.path.isfile(p):
            yield p
        for d, dn, fn in os.walk(p):
            dn[:] = [x for x in dn if x != "tests"]
            yield from (os.path.join(d, f) for f in fn if f.endswith(".py"))


def bad_calls(path):
    src = open(path, encoding="utf-8").read()
    lines = src.splitlines()
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return []
    out = []
    for n in ast.walk(tree):
        if not (isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr in ("glob", "iglob")
                and isinstance(n.func.value, ast.Name) and n.func.value.id == "glob" and n.args):
            continue
        arg = n.args[0]
        if isinstance(arg, ast.Constant):
            continue
        seg = ast.get_source_segment(src, arg) or ""
        if "glob.escape(" in seg or "glob-literal-ok" in lines[n.lineno - 1]:
            continue
        out.append(n.lineno)
    return out


def main(root):
    hits = [f"{os.path.relpath(p, root)}:{ln}" for p in sorted(files(root)) for ln in bad_calls(p)]
    for h in hits:
        print(h)
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
