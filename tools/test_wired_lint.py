#!/usr/bin/env python3
# 单测接线扫描（10-26 维护者：#281 t_rt_recover.py 合入时没登记进门禁，main 上 9 失败 1 报错一天没人知道）：
#   各 tests/ 目录下的单文件单测 t_*.py / t_*.sh 不会被自动收集，要有门禁脚本调它。从门禁入口（graphics/gate.sh、runtime/gate.sh、tools/gate.sh、各钩子（gate_route.py hooks 实际发现的）、
#   被 tools/gate.sh 自动收的 tests/*_test.sh）出发，沿「已接线脚本的命令位置调用单测，或 Python import 同路径模块」逐层传下去，
#   已接线脚本里的 make 调用（make [-C 目录] [-f 文件] 目标…）只跟进被调到的目标（含 include 进来的 *.mk、前置目标、配方里再调的 $(MAKE)）的配方：
#   Makefile 里写了不等于钩子会跑（11-01 审计 P1-39：帧节奏目标只挂在顶层 make test，没有任何门禁 make 它，原先把 graphics/ runtime/ 下全部 Makefile 当入口、算成已接线），
#   传不到的就是没接线。要私有游戏数据 / 要传参数、不能在门禁里跑的，在单测自己的文件头写「门禁手动：<原因>」（# / // / <!-- --> 注释），原因必填；
#   白名单里的单测其实已经接上了只提示、不算红（白名单过期，可删那一行；10-29 起白名单 merge=union，并行删相邻行合并时会把删掉的行合回来）。
# 用法：python3 tools/test_wired_lint.py [仓库根]   退出 0 = 全部接线或在白名单；1 = 有没接线的 / 白名单不对（逐条点名）
import ast, fnmatch, glob, os, re, shlex, subprocess, sys

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
SKIP = {'.git', 'build', 'compat', 'node_modules', '.s2arm-local'}
TEST = re.compile(r'(^|/)tests(/[^/]+)*/(t_[^/]+\.(py|sh)|[^/]+_test\.(py|sh))$')   # 10-28 质量线：*_test.py 也要接线（门禁只自动收 tests/*_test.sh；tests/widen_accept_test.py、#835 的 redact_cases_test.py 没人调也报 0 漏）
# 分母不按命名（11-01 维护者：只认 t_* / *_test 等于不按命名写的回归脚本没接线也查不出，#1243 graphics/vulkan/wsi/tests/stop_after_acquire.py）：
#   tests 目录（任意层，含 *-tests / *_tests）下的测试入口——.sh，或带 shebang / __main__ 入口的 .py；纯被导入的模块不算入口，跟着导入它的单测走
TESTDIR = re.compile(r'(^|/)([^/]*[-_])?tests(/[^/]+)*/[^/]+\.(py|sh)$')
def is_entry(p):
    if p.endswith('.sh'): return True
    try: t = open(os.path.join(root, p), encoding='utf-8', errors='replace').read()
    except OSError: return False
    return t.startswith('#!') or re.search(r'''__name__\s*==\s*['"]__main__['"]''', t) is not None
files = []
for dp, ds, fs in os.walk(root):
    ds[:] = [d for d in ds if d not in SKIP]
    files += [os.path.relpath(os.path.join(dp, f), root) for f in fs]
# 镜像内容不是入口：同目录 Dockerfile 用 COPY / ADD 拷进镜像的脚本（tests/vulkan/entrypoint.sh、result.sh 是容器 ENTRYPOINT，镜像一跑就执行；
#   改它们的文件头还会换镜像身份、要重新联网备镜像），跟着跑这个镜像的单测走
def image_payload():
    out = set()
    for d in (p for p in files if re.fullmatch(r'(.*/)?Dockerfile[^/]*', p)):
        try: t = open(os.path.join(root, d), encoding='utf-8', errors='replace').read()
        except OSError: continue
        for m in re.finditer(r'(?im)^\s*(?:COPY|ADD)\s+(?:--\S+\s+)*(.+)$', t):
            for src in m[1].split()[:-1]:
                c = os.path.normpath(os.path.join(os.path.dirname(d), src))
                if c in files: out.add(c)
    return out
PAYLOAD = image_payload()
tests = sorted(p for p in files if (TEST.search(p) or (TESTDIR.search(p) and is_entry(p))) and not re.fullmatch(r'tests/[^/]+_test\.sh', p) and p not in PAYLOAD)   # 顶层 tests/*_test.sh 由 tools/gate.sh 自动收（入口），子目录里的 *_test.sh 要有人调（11-01 审计 P1-64：tests/visual/widen_lib_key_test.sh 没人调、扫描看不见）
# C# 单测工程（10-29 基础设施线：#867 改 graphics/vulkan/core/**，那里的 C# 单测从来没有门禁跑，本扫描也看不见）：tests/ 或 *-tests/ 目录下、或名字带 Test 的 .csproj；
#   已接线脚本的命令里解析出的路径是这个工程文件或它所在目录（cd 进去再 dotnet build、dotnet build <工程>、dotnet run --project <工程>）就算接上
CSTEST = re.compile(r'(^|/)([^/]*-)?tests?/[^/]+\.csproj$|Tests?\.csproj$', re.I)
def cs_is_lib(p):   # 库工程（<OutputType>Library 且不是 IsTestProject）是被单测引用的夹具，不是单测本身
    try: t = open(os.path.join(root, p), encoding='utf-8', errors='replace').read()
    except OSError: return False
    return re.search(r'<OutputType>\s*Library\s*</OutputType>', t, re.I) is not None and re.search(r'<IsTestProject>\s*true', t, re.I) is None
csp = sorted(p for p in files if p.endswith('.csproj') and CSTEST.search(p) and not cs_is_lib(p))
csdir = {os.path.dirname(p): p for p in csp}
tests = sorted(set(tests) | set(csp))
# 手动声明仍由 gate_decl 收；钩子必须复用实际路由入口，未声明路由的浅层钩子也会执行。
DECL = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'gate_decl.py')
def decl(mode):
    if not os.path.exists(DECL): return []
    return [l.split('\t') for l in subprocess.run([sys.executable, DECL, mode, root], capture_output=True, text=True).stdout.splitlines() if l]
ROUTE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'gate_route.py')
# 过渡的无钩子路径（gate_route.py 的 NOHOOK；11-20 起为空，android/ 由新钩子 android/gate.sh 接线）：列在那里的单测暂无钩子接线，不报
nohook = tuple(subprocess.run([sys.executable, ROUTE, 'nohook'], cwd=root, capture_output=True, text=True).stdout.split()) if os.path.exists(ROUTE) else ()
tests = [t for t in tests if not t.startswith(nohook)] if nohook else tests
routed = subprocess.run([sys.executable, ROUTE, 'hooks'], cwd=root, capture_output=True, text=True)
if routed.returncode:
    sys.exit('【红】test_wired：门禁钩子发现失败：' + routed.stderr.strip())
hooks = [h for h in routed.stdout.splitlines() if h in files]
entry = sorted({p for p in ('graphics/gate.sh', 'runtime/gate.sh', 'tools/gate.sh') if p in files} | set(hooks)) + sorted(p for p in files if re.fullmatch(r'tests/[^/]+_test\.sh', p))
entry += sorted(p for p in files if nohook and p.startswith(nohook) and is_entry(p))   # 无钩子路径里的脚本调到的别处单测（android/test.sh → runtime/tests/support/…）同属那条流水线，过渡期一并不报

# make 跟进（11-01 审计 P1-39）：节点 'make:<主 Makefile>\0<目标通配>'，只读配方文本、不执行 make
def mk_glob(t):   # 目标里的 make / shell 变量当通配
    return re.sub(r'\$\((?:[^()]|\([^()]*\))*\)|\$\{[^}]*\}|\$[A-Za-z_]\w*|\$.', '*', t)

_mk_files, _mk_rules = {}, {}
def make_files(mf):   # 主 Makefile + 按出现顺序 include 进来的文件（字面路径与 $(wildcard …) / $(sort $(wildcard …))）
    if mf in _mk_files: return _mk_files[mf]
    out, todo = [], [mf]
    while todo:
        f = todo.pop(0)
        if f in out or f not in files: continue
        out.append(f)
        try: text = open(os.path.join(root, f), encoding='utf-8', errors='replace').read()
        except OSError: continue
        for line in text.splitlines():
            m = re.match(r'\s*-?s?include\s+([^#]+)', line)
            if not m: continue
            pats = re.findall(r'\$\(wildcard\s+([^)]+)\)', m[1]) or [m[1]]
            for pat in (w for ps in pats for w in ps.split()):
                if '$' in pat: continue
                todo += sorted(os.path.relpath(g, root) for g in glob.glob(os.path.join(root, pat)))
    _mk_files[mf] = out
    return out

def make_rules(mf):   # [(所在文件, [目标通配], [前置通配], 配方文本)]，define 体里的模板规则照样认
    if mf in _mk_rules: return _mk_rules[mf]
    rules = []
    for f in make_files(mf):
        cur = None
        for line in open(os.path.join(root, f), encoding='utf-8', errors='replace').read().splitlines():
            if line.startswith('\t'):
                if cur is not None: cur[3].append(line.lstrip().lstrip('@-+'))
                continue
            cur = None
            m = re.match(r'([^\s:=#][^:=#]*?)\s*::?(?!=)([^=]*)$', line.split('#')[0].rstrip())
            if not m or re.match(r'(ifn?eq|ifn?def|else|endif|define|endef|export|override|-?s?include)\b', m[1]): continue
            cur = (f, [mk_glob(t) for t in m[1].split()], [mk_glob(t) for t in m[2].replace('|', ' ').split()], [])
            rules.append(cur)
    _mk_rules[mf] = [(f, ts, ps, '\n'.join(rc)) for f, ts, ps, rc in rules]
    return _mk_rules[mf]

def make_invocation(args, variables, here, cwd):   # 一条 make 命令 → 被调到的目标节点；-n / -p / -q 不执行配方，不算
    d, mfile, targets, i = cwd, None, [], 0
    while i < len(args):
        a = args[i]; w = path_word(a, variables, here)
        if a in ('-C', '-f', '--directory', '--file', '-I', '-o', '-W') or (a in ('-j', '-l') and i + 1 < len(args) and re.fullmatch(r'[0-9]+', args[i + 1])):
            v = path_word(args[i + 1], variables, here) if i + 1 < len(args) else None
            if a in ('-C', '--directory', '-f', '--file') and v is None: return set()
            if a in ('-C', '--directory'): d = os.path.normpath(os.path.join(d, v))
            elif a in ('-f', '--file'): mfile = v
            i += 2; continue
        if w is not None and re.fullmatch(r'-[A-Za-z]*[npq][A-Za-z]*|--(dry-run|just-print|recon|question|print-data-base)', w): return set()
        if a.startswith('-') or re.match(r'[A-Za-z_]\w*=', a): i += 1; continue
        targets.append(w if w is not None else mk_glob(a.replace('"', '').replace("'", ''))); i += 1
    mf = os.path.normpath(os.path.join(d, mfile or 'Makefile'))
    if mf not in files: return set()
    if not targets:   # 缺省目标 = 第一条不以 . 开头的规则
        first = next((t for _, ts, _, _ in make_rules(mf) for t in ts if not t.startswith('.')), None)
        targets = [first] if first else []
    return {'make:' + mf + '\0' + t for t in targets if t and t.strip('*')}

def make_references(node):
    mf, want = node[5:].split('\0', 1)
    found = set()
    for f, ts, ps, recipe in make_rules(mf):
        if not any(t == want or fnmatch.fnmatchcase(t, want) or fnmatch.fnmatchcase(want, t) for t in ts): continue
        found |= shell_references(f, recipe, True, os.path.dirname(mf))
        found |= {'make:' + mf + '\0' + q for q in ps if q.strip('*')}
    return found

def expansion_end(text, start):
    # 只跳过 $() / ${} 的配对词法边界；不执行，也不把内部命令算登记。
    opening = text[start + 1]
    closing = ')' if opening == '(' else '}'
    depth, quote, i = 1, '', start + 2
    while i < len(text):
        c = text[i]
        if c == '\\' and quote != "'": i += 2; continue
        if (text.startswith('$(', i) or text.startswith('${', i)) and quote != "'":
            i = expansion_end(text, i); continue
        if quote:
            if c == quote: quote = ''
        elif c in "\"'": quote = c
        elif c == opening: depth += 1
        elif c == closing:
            depth -= 1
            if not depth: return i + 1
        i += 1
    raise ValueError('命令替换未闭合' if opening == '(' else '参数展开未闭合')


def substitution_end(text, start):
    return expansion_end(text, start)


def skip_heredocs(text, start, commands):
    # delimiter 只做 quote removal，不展开变量，也不解释正文的命令替换。
    for command in commands:
        words = iter(command)
        for word in words:
            if not word.startswith('<<') or word.startswith('<<<'): continue
            strip_tabs = word.startswith('<<-')
            raw = word[3 if strip_tabs else 2:] or next(words, '')
            delimiters = shlex.split(raw, comments=False, posix=True)
            if len(delimiters) != 1: raise ValueError('heredoc 缺字面结束词')
            while start < len(text):
                end = text.find('\n', start)
                if end < 0: end = len(text)
                line = text[start:end]
                start = min(end + 1, len(text))
                if (line.lstrip('\t') if strip_tabs else line) == delimiters[0]: break
            else: raise ValueError('heredoc 未闭合')
    return start


def shell_commands(text):
    # 保留词中的引号（含相邻引号、跨行字串）；只有未引用的分隔符才切命令。
    commands, command, word, quote, i, line_start = [], [], '', '', 0, 0
    while i < len(text):
        c = text[i]
        if c == '\\' and quote != "'" and i + 1 < len(text):
            if text[i + 1] != '\n': word += text[i:i + 2]
            i += 2; continue
        if text.startswith('$(', i) and quote != "'":
            end = substitution_end(text, i); word += text[i:end]; i = end; continue
        if text.startswith('${', i) and quote != "'":
            end = expansion_end(text, i)
            word += text[i:end]; i = end; continue
        if quote:
            word += c
            if c == quote: quote = ''
        elif c in "\"'": quote = c; word += c
        elif c == '#' and not word:
            end = text.find('\n', i)
            i = len(text) if end < 0 else end
            continue   # 注释里的反斜杠不能吞掉下一行真调用
        elif text.startswith('<<<', i):
            if word: command.append(word)
            word = '<<<'; i += 3; continue   # here-string 没有跨行正文
        elif text.startswith('<<', i):
            if word: command.append(word)
            word = '<<-' if text.startswith('<<-', i) else '<<'
            i += len(word); continue
        elif c.isspace() or c in ';&|(){}':
            if word: command.append(word); word = ''
            if c == '\n' or c in ';&|(){}':
                if command: commands.append(command); command = []
            if c == '\n':
                i = skip_heredocs(text, i + 1, commands[line_start:])
                line_start = len(commands); continue
        else: word += c
        i += 1
    if quote: raise ValueError('引号未闭合')
    if word: command.append(word)
    if command: commands.append(command)
    return commands


def path_word(raw, variables, here):
    # 只解析字面词和已知目录变量；单引号 / 转义的 $ 保持字面量。
    value, quote, i = '', '', 0
    while i < len(raw):
        c = raw[i]
        if c == '\\' and quote != "'" and i + 1 < len(raw):
            if quote == '"' and raw[i + 1] not in '$`"\\': value += c; i += 1; continue
            value += raw[i + 1]; i += 2; continue
        if c in "\"'":
            if not quote: quote = c; i += 1; continue
            if quote == c: quote = ''; i += 1; continue
        if c == '$' and quote != "'":
            directory = re.match(r'\$\(cd "\$\(dirname "\$0"\)([^"]*)" && pwd(?: -P)?\)', raw[i:])
            if directory:
                value += os.path.normpath(here + directory[1]); i += directory.end(); continue
            directory = re.match(r'\$\(cd "(\$\{?[A-Za-z_]\w*\}?[^"$`]*)" && pwd(?: -P)?\)', raw[i:])   # $(cd "$已知目录变量/../.." && pwd)（threaded_host_suites.sh 的 repo_dir）
            if directory:
                inner = path_word(directory[1], variables, here)
                if inner is None: return None
                value += os.path.normpath(inner); i += directory.end(); continue
            if raw.startswith('$(dirname "$0")', i):
                value += here; i += len('$(dirname "$0")'); continue
            variable = re.match(r'\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))', raw[i:])
            if not variable: return None
            name = variable[1] or variable[2]
            if name not in variables: return None
            value += variables[name]; i += variable.end(); continue
        if c == '`' and quote != "'": return None
        value += c; i += 1
    return value


parse_errors = {}


def substituted(text):
    """$( … ) 里的命令同样会执行（10-29 基础设施线：services/gate.sh 的 out=$(bash services/test.sh 2>&1) 原先不算调用，服务层 C# 单测判没接线）：
    找出未在单引号里的每个 $( 的配对边界，把里面当一段脚本再切命令（嵌套的递归）"""
    out, quote, i = [], '', 0
    while i < len(text):
        c = text[i]
        if c == '\\' and quote != "'": i += 2; continue
        if c == "'" and quote != '"': quote = '' if quote == "'" else "'"
        elif c == '"' and quote != "'": quote = '' if quote == '"' else '"'
        elif quote != "'" and text.startswith('$(', i) and not text.startswith('$((', i):
            end = expansion_end(text, i); inner = text[i + 2:end - 1]
            out += shell_commands(inner) + substituted(inner); i = end; continue
        elif c == '#' and not quote and (i == 0 or text[i - 1] in ' \t\n;'):
            nl = text.find('\n', i); i = len(text) if nl < 0 else nl; continue
        i += 1
    return out


def discover_files(argv, variables, here):
    start, pat, i, pos = None, 'test*.py', 0, []
    while i < len(argv):
        # 命令到重定向 / 控制符为止（11-14：「discover -s 目录 -v > 日志 2>&1 &」原先把「>」当位置参数、改写成模式，launchers/macos 的 gui_jobs 单测被判没接线）
        if re.fullmatch(r'\d*[<>]{1,2}(&\d+|&-)?|&{1,2}|\|{1,2}|;', argv[i]):
            break
        a = path_word(argv[i], variables, here)
        if a in ('-s', '--start-directory', '-p', '--pattern', '-t', '--top-level-directory'):
            v = path_word(argv[i + 1], variables, here) if i + 1 < len(argv) else None
            if v is None: return set()
            if a in ('-s', '--start-directory'): start = v
            elif a in ('-p', '--pattern'): pat = v
            i += 2; continue
        if a is None: return set()
        if not a.startswith('-'): pos.append(a)
        i += 1
    if start is None and pos: start, pos = pos[0], pos[1:]   # 位置参数：起始目录、模式（与 -s / -p 同义）
    elif start is None: start = '.'
    if pos and pat == 'test*.py': pat = pos[0]
    out = set()
    for d in {os.path.normpath(start), os.path.normpath(os.path.join(here, start))}:
        stack = [d]
        while stack:
            c = stack.pop()
            for f in files:
                if os.path.dirname(f) == c and fnmatch.fnmatch(os.path.basename(f), pat) and f.endswith('.py'): out.add(f)
                elif os.path.basename(f) == '__init__.py' and os.path.dirname(os.path.dirname(f)) == c: stack.append(os.path.dirname(f))
    return out


def references(p):
    """只读静态登记，不执行被扫文件；不推断条件、函数调用或动态 shell。"""
    if p.startswith('make:'): return make_references(p)
    try: text = open(os.path.join(root, p), encoding='utf-8', errors='replace').read()
    except OSError: return set()
    found = set()
    here = os.path.dirname(p)
    if p.endswith('.py'):
        try: tree = ast.parse(text)
        except SyntaxError as error:
            parse_errors[p] = f'第 {error.lineno} 行：{error.msg}'
            return found
        nodes = list(ast.walk(tree))   # 整棵树只遍历一次，下面几类登记共用（原先每类各 ast.walk 一遍，全仓 4 遍约占扫描一半时间）
        for node in nodes:
            if isinstance(node, ast.Import): names = [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom):
                names = [node.module] if node.module else [a.name for a in node.names]
            else: continue
            for name in names:
                path = name.replace('.', '/') + '.py'
                # 脚本所在目录优先；不再用同名模块匹配另一目录的测试。
                for base in (here, ''):
                    target = os.path.normpath(os.path.join(base, path))
                    if target in files:
                        found.add(target); break
        # Python 跑器（11-01：graphics/vulkan/cache/tests/test_profile_runner.py 用 subprocess.run([sys.executable, Path(__file__).with_name("x.py")]) 调同目录脚本）：
        #   subprocess.* 调用的第一个参数是列表、首项是 sys.executable / 'python3' / 'bash' 时，列表里字符串常量拼出的 .py / .sh 路径按脚本目录或仓库根解析，
        #   列表项是本文件赋值过的名字（SWAP = os.path.join(H, 'x.py')）也跟进一层；只认这种调用，不认字符串提及
        assigns = {}
        for node in nodes:
            if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name): assigns[node.targets[0].id] = node.value
        #   表达式里嵌的名字同样跟进（11-01：tests/metal_prof_test.py 的 gen = ROOT / 'tests' / ... ; subprocess.run([sys.executable, str(gen), …])）；按源码顺序深度优先取常量，ROOT / 'a' / 'b.py' 拼回 a/b.py
        def consts(n, depth=0):
            if isinstance(n, ast.Constant): return [n.value] if isinstance(n.value, str) else []
            if isinstance(n, ast.Name): return consts(assigns[n.id], depth + 1) if n.id in assigns and depth < 2 else []
            return [c for ch in ast.iter_child_nodes(n) for c in consts(ch, depth)]
        for node in nodes:
            if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in ('run', 'call', 'check_call', 'check_output', 'Popen')
                    and isinstance(node.func.value, ast.Name) and node.func.value.id == 'subprocess' and node.args and isinstance(node.args[0], ast.List) and node.args[0].elts): continue
            head = node.args[0].elts[0]
            if not ((isinstance(head, ast.Attribute) and head.attr == 'executable') or (isinstance(head, ast.Constant) and re.fullmatch(r'python[0-9.]*|bash|sh', str(head.value)))): continue
            for el in node.args[0].elts[1:]:
                parts = [c for c in consts(el) if c and not c.startswith('-')]
                if not parts or not parts[-1].endswith(('.py', '.sh')): continue
                for c in (os.path.normpath(os.path.join(here, *parts)), os.path.normpath(os.path.join(*parts)), os.path.normpath(os.path.join(here, parts[-1]))):
                    if c in files: found.add(c); break
        # Python 编跑 C# 单测工程（11-01 审计 P1-64：安卓 audio-lifetime-tests/run.py 的 here / 'AudioLifetime.csproj'、codecs managed_test.py 的 here/'managed/Avc.Tests.csproj'）：
        #   字符串常量以 .csproj 结尾、按脚本目录或仓库根解析正是那个工程才算；只认工程文件，不认 .py / .sh 的字符串提及
        for node in nodes:
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and node.value.endswith('.csproj'):
                for c in (os.path.normpath(os.path.join(here, node.value)), os.path.normpath(node.value)):
                    if c in csp: found.add(c)
        return found

    return shell_references(p, text, False, '')


_sh_refs = {}


def shell_references(p, text, make, cwd):   # 同一段文本（make 配方被多个目标点到）只解析一次；结果只取决于这四个参数
    k = (p, text, make, cwd)
    if k not in _sh_refs: _sh_refs[k] = _shell_references(p, text, make, cwd)
    return set(_sh_refs[k])


def _shell_references(p, text, make, cwd):   # make=True：text 是 make 配方（cwd 是 make 的工作目录，配方里的 $(MAKE) 从这里起）
    found = set()
    here = os.path.dirname(p)
    # 只展开仓库现有的静态路径写法；未知变量不按 basename 猜测试。
    variables = {}
    try: commands = shell_commands(text) + substituted(text)
    except ValueError as error:
        parse_errors[p] = str(error)
        return found
    # 本文件里定义的转调函数（11-01 审计 P1-64：android/tests/threaded_host_suites.sh 的 run() { echo …; shift; "$@"; }）：
    #   函数体在 shift N 之后直接执行 "$@" → 调用处去掉函数名和前 N 个参数，剩下的按命令认；只看函数体文本，不执行
    wrappers = {}
    for name, body in re.findall(r'(?m)^\s*(?:function\s+)?([A-Za-z_]\w*)\s*\(\)\s*\{(.*?)(?:\}\s*$|^\})', text, re.S | re.M):
        call = re.search(r'(?:^|[;{\n]|&&|\|\|)\s*"\$@"', body)
        if call: wrappers[name] = sum(int(n or 1) for n in re.findall(r'\bshift(?:\s+([0-9]+))?\b', body[:call.start()]))
    def script_in(value):   # 命令串放进环境变量交给被测工具执行（11-01：tests/sched_test.sh 等 S2A_DEVICECTL="python3 $H/tests/fake_devicectl.py"）：值是「解释器 脚本」才算
        try: words = shlex.split(value or '')
        except ValueError: return None
        if len(words) < 2 or not re.fullmatch(r'python[0-9.]*|bash|sh', os.path.basename(words[0])) or words[1].startswith('-'): return None
        return next((c for c in (os.path.normpath(words[1]), os.path.normpath(os.path.join(here, words[1]))) if c in files and c.endswith(('.py', '.sh'))), None)
    for command in commands:
        while command and command[0] in ('if', 'then', 'elif', 'else', 'do', '!', 'exec'): command.pop(0)
        assignments = {}
        if command and command[0] in ('export', 'local', 'declare', 'readonly'):
            for raw in command[1:]:
                if re.match(r'^[A-Za-z_]\w*=', raw):
                    hit = script_in(path_word(raw.split('=', 1)[1], variables, here))
                    if hit: found.add(hit)
        while command and re.match(r'^[A-Za-z_]\w*=', command[0]):
            name, raw = command.pop(0).split('=', 1)
            assignments[name] = path_word(raw, variables, here)
            hit = script_in(assignments[name])
            if hit: found.add(hit)
        if not command:
            for name, value in assignments.items():
                if value is None: variables.pop(name, None)
                else: variables[name] = value
            continue
        if command[0] == 'unset':
            # 只迁移字面变量名的失效；不把 unset -f（函数）误当目录变量删除。
            names = [path_word(raw, {}, here) for raw in command[1:]]
            if names and names[0] in ('-v', '--'): names = names[1:]
            if all(name is not None and re.fullmatch(r'[A-Za-z_]\w*', name) for name in names):
                # 已知被 unset 的值为空，不是从未绑定的 PY/PYV 配置解释器接口。
                for name in names: variables[name] = ''
            continue
        for raw in command:   # C# 单测工程：命令里任何位置解析出的路径是工程文件或它的目录
            w = path_word(raw, variables, here)
            if not w: continue
            for c in {os.path.normpath(w), os.path.normpath(os.path.join(here, w))}:
                if c in csdir: found.add(csdir[c])
                elif c.endswith('.csproj') and c in csp: found.add(c)
        # Android gate's streaming failure-summary wrapper invokes its argv
        # directly; it is not a textual mention or a skipped test.
        if command and command[0] == 's2a_gate_step': command = command[1:]
        if command and command[0] in wrappers: command = command[1 + wrappers[command[0]]:]
        if command and command[0] == 'timeout':   # 秒数也可以是变量（runtime/gate.sh：timeout -k 15 "$GT" make …）；先跳过 timeout 自己的选项（-k / -s 带一个参数、--x=y 与单独开关不带）
            rest = command[1:]
            while rest and rest[0].startswith('-'):
                rest = rest[2:] if rest[0] in ('-k', '-s', '--kill-after', '--signal') else rest[1:]
            if len(rest) > 1 and re.fullmatch(r'[0-9.]+[smhd]?|"?\$\{?[A-Za-z_]\w*\}?"?', rest[0]): command = rest[1:]
        # 无进展看门狗包装（tools/nostall.py <秒> [--watch …] -- <命令…>、bash tools/idle_timeout.sh <无进展秒> <硬上限秒> <盯的文件>… -- <命令…>，
        #   钩子判挂死的标准写法）：被测命令在 -- 之后（11-25 dsh 改用 idle_timeout 后 t_dsh.sh 调的 t_push / t_uvx 被判没接线）
        if len(command) > 2 and os.path.basename(path_word(command[1], variables, here) or '') in ('nostall.py', 'idle_timeout.sh') and '--' in command[2:]:
            command = command[command.index('--', 2) + 1:]
        if command and command[0] == 'env':
            command = command[1:]
            while command and re.match(r'^[A-Za-z_]\w*=', command[0]): command.pop(0)
        # source / . 把脚本读进当前 shell 执行（11-01：tests/vulkan/run.sh 的 source "$here/image.sh"、各单测失败时 . "$(dirname "$0")/keep_scene.sh"）
        if command and command[0] in ('.', 'source') and len(command) > 1:
            w = path_word(command[1], variables, here)
            if w is not None:
                hit = next((c for c in ([os.path.normpath(os.path.join(here, w))] if make else []) + [os.path.normpath(w)] if c in files), None)
                if hit and hit.endswith('.sh'): found.add(hit)
            continue
        if command and (command[0] in ('make', 'gmake', '$(MAKE)', '${MAKE}') or os.path.basename(path_word(command[0], variables, here) or '') == 'make'):
            found |= make_invocation(command[1:], variables, here, cwd); continue
        if len(command) < 2: continue
        executable = path_word(command[0], variables, here)
        interpreter = os.path.basename(executable or '')
        # 主线 PY/PYV 是配置解释器接口；已知为 echo 等非解释器时不能冒认。
        #   10-28 质量线：「${S2A_PY:-python3}」「${S2A_CONTRACT_PY:-…/python3}」这类带缺省值、名字含 PY 的解释器变量也算（tests/*_test.sh 包装 *_test.py 多半这么写，原先 11 支因此判没接线）
        configured = executable is None and re.fullmatch(r'"?\$\{?[A-Za-z0-9_]*PY[A-Za-z0-9_]*(:-[^}]*)?\}?"?', command[0], re.I) is not None   # 小写变量名也算（threaded_host_suites.sh 的 "$test_python"）
        if not (re.fullmatch(r'python[0-9.]*|bash|sh', interpreter) or configured): continue
        args = command[1:]
        while args:
            option = path_word(args[0], {}, here)
            if not option or not option.startswith('-'): break
            args.pop(0)
            # 仅支持会执行文件且不另取参数的常用开关；help/version/-c/-n 不算调用。
            # -m 单独处理：认出 unittest / 直接模块三种写法（T140 / #936）。
            if interpreter not in ('bash', 'sh') and option == '-m':
                if not args:
                    break
                mod = path_word(args[0], variables, here)
                rest = args[1:]
                specs = []
                if mod == 'unittest':
                    if not rest:
                        args = []
                        break
                    first = path_word(rest[0], variables, here)
                    # discover：按 -s 起始目录 + -p 模式（缺省 test*.py）精确展开——起始目录与带 __init__.py 的子包里匹配的文件；
                    #   起始目录或模式是看不出的变量就不认（不把整目录都算接上）。11-01：pack/jobs/tests 经 launchers/macos/test.sh discover 实跑，原先全判没接线
                    if first == 'discover':
                        found |= discover_files(rest[1:], variables, here)
                        args = []
                        break
                    # 其他子命令不能把整目录都算接上
                    if first is None or first.startswith('-'):
                        args = []
                        break
                    specs.append(first)
                elif mod is not None:
                    specs.append(mod)
                for spec in specs:
                    if spec.endswith('.py'):
                        rel = spec
                    else:
                        rel = spec.replace('.', '/') + '.py'
                    cand = [os.path.normpath(os.path.join(here, rel))] if make else []
                    cand.append(os.path.normpath(rel))
                    hit = next((c for c in cand if c in files), None)
                    if hit and hit.endswith('.py'):
                        found.add(hit)
                args = []
                break
            allowed = ('--', '-e', '-u', '-x', '-eu', '-eux', '-ue') if interpreter in ('bash', 'sh') else ('--', '-B', '-u', '-E', '-I', '-s', '-S', '-O', '-OO')
            if option not in allowed: args = []; break
            if option == '--': break
        if not args: continue
        target = path_word(args[0], variables, here)
        if target is None: continue
        # 门禁以仓库根为 cwd；make 配方以 Makefile 所在目录为 cwd。
        cand = [os.path.normpath(os.path.join(here, target))] if make else []
        cand.append(os.path.normpath(target))   # make 配方里也常写仓库根相对路径（runtime/tests/mk/game_tsv.mk：python3 tests/game_tsv_test.py，由仓库根 make -f 调）
        target = next((c for c in cand if c in files), cand[0])
        if target in files and target.endswith(('.sh', '.py')): found.add(target)   # 中间脚本也记（10-28 质量线：钩子 → android/test.sh → 单测，原先只跟「单测 → 单测」，中间那层断了，24 支安卓单测全判没接线）
    return found

wired, seen, todo = set(entry) & set(tests), set(entry), list(entry)   # 门禁入口自己就在跑（11-01：tests/visual/gate.sh 是钩子，分母改按 tests 目录后被当成没人调）
# 间接调用（单测文件头「门禁间接：<调用方> <说明>」，tools/gate_decl.py indirect）：调用方按通配或在进程内拼路径调它，静态引用追不到。
#   只有调用方本身被门禁调到（在已追到的闭包里）才算接线，并接着追它自己引用的脚本；调用方不存在 / 没写说明 = 声明不对，报红。
indirect = decl('indirect'); indirect_bad = []
for row in indirect:
    f, caller, why = (row + ['', ''])[:3]
    if not why.strip(): indirect_bad.append(f'文件头「门禁间接」 {f} 没写说明')
    elif caller not in files: indirect_bad.append(f'文件头「门禁间接」 {f} 的调用方 {caller} 不是仓库里的文件')
changed = True
while todo or changed:
    while todo:
        for t in references(todo.pop()):
            if t in tests: wired.add(t)
            if t not in seen: seen.add(t); todo.append(t)
    changed = False
    for row in indirect:
        f, caller, why = (row + ['', ''])[:3]
        if why.strip() and caller in seen and f in tests and f not in wired:
            wired.add(f); changed = True
            if f not in seen: seen.add(f); todo.append(f)

def verdict(okl, okp):
    """按一份白名单出结论：(文本行, 退出码)。同一次扫描可按多份白名单出结论（S2A_WIRED_EMPTY_OUT），不必整仓重扫"""
    ok, bad = {}, [f'{p}：解析失败（{why}）' for p, why in sorted(parse_errors.items())] + indirect_bad
    stale = []
    for n, l in enumerate(okl, 1):
        lab = f'白名单第 {n} 行' if okp else '文件头「门禁手动」'
        if not l.strip() or l.startswith('#'): continue
        p, _, why = l.rstrip('\n').partition('\t')
        if not why.strip(): bad.append(f'{lab} {p} 没写原因')
        elif p not in tests: stale.append(f'{lab} {p} 不是现存的单测（改名 / 删了就删这一行）')   # 同上只提示：写错路径时那支本身照报没接线
        elif p in wired: stale.append(f'{lab} {p} 已经有门禁脚本调它了，可以删掉这一行')   # 只提示不算红（10-29 列车线：白名单 merge=union 后两支并行删相邻行会把删掉的行合回来，过期行不掩盖任何没接线的单测）
        else: ok[p] = why   # 不合格的行不豁免
    miss = [t for t in tests if t not in wired and t not in ok]
    bad += negctl_bad; stale += negctl_stale
    for t in miss: bad.append(f'{t} 没有门禁脚本调它（graphics/gate.sh 等登记一行；跑不了的在它文件头写「门禁手动：<原因>」）')
    out = ['  ✗ ' + b for b in bad] + ['  · 提示：' + b for b in stale]
    out.append(f'期望 0 处没接线 / 白名单不对 → 真结果 {len(bad)} 处（扫 {len(tests)} 支单测：门禁调到 {len(wired)}、白名单 {len(ok)}、没接线 {len(miss)}）')
    return out, (1 if bad else 0)


# 负对照标记（11-23 维护者：反证输出混进门禁红步摘要，误导两轮定位）：单测入口里做负对照 / 变异（文中提到 负对照 / negative control / mutant）的，
#   反证那次的输出要包在「【负对照开始】」「【负对照结束】」之间（tools/gate.sh red_view、gate2 red_reason 据此剔除，按设计红出的行不进摘要与签名）。
#   存量在 tools/negctl_unmarked.tsv（11-23 生成，只减不增：改到哪支顺手加标记、删这一行）；新单测不在表里又没标记 → 红
NEGCTL = re.compile(r'负对照|negative control|mutant', re.I)
negctl_base = {l.split('\t', 1)[0] for l in open(os.path.join(root, 'tools/negctl_unmarked.tsv'), encoding='utf-8') if l.strip() and not l.startswith('#')} \
    if os.path.exists(os.path.join(root, 'tools/negctl_unmarked.tsv')) else set()
negctl_bad, negctl_stale, negctl_unmarked = [], [], []
NEGCTL_FILE = re.compile(r'(^|/)(t_[^/]+|[^/]+_test)\.(sh|py)$')   # 所有单测脚本（含顶层 tests/*_test.sh 自动入口、android/tools/*_test.sh 这类不在 tests 目录的）
for t in sorted(set(t for t in tests if t.endswith(('.sh', '.py'))) | {p for p in files if NEGCTL_FILE.search(p) and p not in PAYLOAD}):
    try: txt = open(os.path.join(root, t), encoding='utf-8', errors='replace').read()
    except OSError: continue
    if NEGCTL.search(txt) and '【负对照开始】' not in txt:
        negctl_unmarked.append(t)
        if t not in negctl_base: negctl_bad.append(f'{t} 做了负对照但反证输出没包进「【负对照开始】」「【负对照结束】」（门禁红步摘要靠它剔除按设计红出的行）')
negctl_stale = [f'tools/negctl_unmarked.tsv 里的 {t} 已加标记 / 已不在，可以删掉这一行' for t in sorted(negctl_base - set(negctl_unmarked))]
if os.environ.get('S2A_NEGCTL_LIST'):   # 生成存量表用：只打没标记的单测、不出结论
    print('\n'.join(negctl_unmarked)); sys.exit(0)

# 白名单 = 各单测文件头「门禁手动：<原因>」（tools/gate_decl.py manual；原 tests/test_wired_ok.tsv 中央表已拆回各文件，10-30 维护者批）；S2A_WIRED_OK：换一份白名单文件（单测反证用）
okp = os.environ.get('S2A_WIRED_OK')
okl = open(okp, encoding='utf-8').read().splitlines() if okp and os.path.exists(okp) else ['\t'.join(r) for r in decl('manual')]
# S2A_WIRED_EMPTY_OUT=<文件>：同一次扫描再按空白名单出一份结论写进该文件（末行「退出码 N」）——单测反证空白名单时不必整仓再扫一遍（11-16 门禁提速）
eo = os.environ.get('S2A_WIRED_EMPTY_OUT')
if eo:
    lines, rc = verdict([], 'empty')
    open(eo, 'w', encoding='utf-8').write('\n'.join(lines + [f'退出码 {rc}']) + '\n')
lines, rc = verdict(okl, okp)
print('\n'.join(lines))
sys.exit(rc)
