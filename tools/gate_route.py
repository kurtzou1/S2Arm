#!/usr/bin/env python3
"""门禁按改动路由（10-20 维护者：回归测试拖慢开发，按改动跑最小充分证据）。在仓库根跑：
  python3 tools/gate_route.py tests  <改到的文件…>   → 要跑的根单测与已登记独立单测入口，一行一个
  python3 tools/gate_route.py hooks  <改到的文件…>   → 要跑的 <目录>/gate.sh 钩子
  python3 tools/gate_route.py claimed <改到的文件…>  → 文件头「# 门禁路由：」明确点到这些改动的钩子（tool 档也跑这些；不含表外兜底）
  python3 tools/gate_route.py ios    <改到的文件…>   → 要不要跑 iOS 全量编译：yes / no
  python3 tools/gate_route.py why    <改到的文件…>   → 一行人读的路由结论（门禁日志用）
  python3 tools/gate_route.py owns <钩子> <改到的文件…> → 改动里让这个钩子跑起来的文件（列车判红的钩子与本批有没有关），一行一个
  python3 tools/gate_route.py evidence <改到的文件…> → 这次改动要的最小充分证据（合入前自验 / 起不起局、起哪几款），一行一条
改到的文件为空 = 不知道改了啥 → 全跑（手动跑门禁时的缺省）。
单测的覆盖面自动推：单测文本里出现的文件名（*.sh *.py *.c *.h *.tsv *.mk）按文件名对上仓库里 tools/ pack/ tests/ 的文件，
再顺着被测脚本里出现的文件名传递闭包（dev_run.sh → devlock.sh …）；单测自己被改也跑。
含中文的引号段（echo / fail / print 的提示、单测标签）里的文件名不算点名，像命令的段照算（drop_prose）。
单测头部可加「# 门禁覆盖：<通配…>」补推不出的面（例：shell_lint 覆盖 *.sh），「# 门禁：每次」= 每次都跑，
「# 门禁只看：<通配…>」= 覆盖面只有单测自己 + 这些（不推闭包：文本推导把提示字符串里的文件名、被单测换成桩的下游脚本都算进去，
  10-28 出包槽 / sched / remote 三支各被推到 124–128 个文件、几乎每批都跑；清单按执行追踪写，被测脚本新调用了别的脚本同笔补进来），
「# 门禁闭包：[--table <表>] <入口…>」= 改动落在这些入口经 tools/stage_inputs.py 算出的依赖闭包里就跑（阶段键单测：新文件进了阶段闭包要核登记）。
钩子与 iOS 编译按各钩子文件头「# 门禁路由：<前缀…>」（tools/gate_decl.py route）；哪个钩子都没声明到的代码目录 = 全跑（宁多勿漏）。"""
import fnmatch, os, re, subprocess, sys, tempfile

TOK = re.compile(r'(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.(?:sh|py|c|h|m|mm|cc|cpp|swift|cs|tsv|mk|json)\b')   # 带目录的写法整段取（graphics/tools/shbake/xc_key.sh），见 refs
LOCAL = ('tools/', 'pack/', 'tests/')   # 本线目录：单测覆盖面只在这里面推
DOC = re.compile(r'^docs/|\.md$|^\.github/ISSUE_TEMPLATE/')   # 与 tools/gate_plan.sh GATE_DOC_RE 同一条
# 无钩子路径（过渡，11-11 维护者：旧安卓三钩子删除）：改到 android/ 不算表外、不触发钩子全跑（文件头路由点到的钩子照常选中，
#   如安卓新层的 android/native/gfx_plat/gate.sh）；test_wired 也跳过这里旧层单测的接线检查（清空后约 162 处没接线，多是旧图形层单测）。
#   留到安卓线删旧层源码那一笔一并删（单测照旧按覆盖面路由）
NOHOOK = ('android/',)

# 独立测试的显式覆盖合同（#925）：已有 shell 引用推导不解析 MSBuild 项目，
# 中文说明中的 .cs 名字也不是可用的路径通配。按测试消费者合同登记，不能仅凭同名猜。
# key 可登记现有根单测或可无参数直跑的嵌套入口；value 与「门禁覆盖」同为触发路径。
# 只选择既有命令，不改变各 gate.sh 的步骤、消费者代码或编译参数。
DECLARED_TEST_COVERAGE = {
    'graphics/track/tests/drain_readflush/build_run.sh': (
        'graphics/metal/cs/NxTrack.cs', 'graphics/track/tests/drain_readflush/*'),
    'tests/shader_garbage_guard_test.sh': (
        'compat/tree/src/Ryujinx.Graphics.Gpu/Shader/ShaderCache.cs',
        'compat/tree/src/Ryujinx.Graphics.Gpu/Engine/Threed/StateUpdater.cs',
        'tests/shader_garbage_guard/*'),
    'tests/shader_fault_cache_test.sh': (
        'compat/tree/src/Ryujinx.Graphics.Gpu/Shader/ShaderCache.cs',
        'compat/tree/src/Ryujinx.Graphics.Gpu/Engine/Threed/StateUpdater.cs',
        'compat/tree/src/Ryujinx.Graphics.Gpu/Shader/S2AShaderFaultCache.cs',
        'tests/shader_fault_cache/*'),
}


def repo_files():
    out = subprocess.run(['git', 'ls-files'], capture_output=True, text=True, check=True).stdout
    return [f for f in out.split('\n') if f]


def drop_docstrings(txt):
    """Python 文档字符串里提到的文件名不是依赖（10-23：gate_route.py / redline.py / pack.py 的说明里写了 dev_run.sh，
    改 dev_run.sh 牵出 25 个单测，其中 17 个只经这几条说明边）：模块 / 类 / 函数开头的字符串整段换成空行；解析不了就原样返回（宁多勿漏）"""
    import ast
    try: tree = ast.parse(txt)
    except SyntaxError: return txt
    ls = txt.split('\n')
    for n in ast.walk(tree):
        if isinstance(n, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) and n.body:
            d = n.body[0]
            if isinstance(d, ast.Expr) and isinstance(getattr(d, 'value', None), ast.Constant) and isinstance(d.value.value, str):
                for i in range(d.lineno - 1, d.end_lineno): ls[i] = ''
    return '\n'.join(ls)


QSEG = re.compile(r'"(?:[^"\\\n]|\\.)*"|\'[^\'\n]*\'')   # 一行里的引号段（左起先到先得：双引号段里的单引号不另算）
CJK = re.compile(r'[\u3000-\u303f\u3400-\u9fff\uff00-\uffef]')   # 中文字与全角标点
CODEISH = re.compile(r'\$\(|`|;|&&|\|\||\|\s|\bsource\s|^["\']\s*(?:\.\s|bash\b|sh\b|python3?\b|exec\b|env\b|[\w./$-]+\.(?:sh|py)\b)')   # 像要执行的段：命令替换、语句分隔、管道、source、以命令开头


def drop_prose(code):
    """提示文字里提到的文件名不是依赖（10-29 维护者：改纯工具 tools/caps_policy.py 路由出 83 个单测，73 个只经
    pack/ipa.sh 的报错提示「先 pack/stage_rewrite.sh」这条边；执行追踪 89 支单测：oneclick_test 真跑 pack/ipa.sh 78 次，
    stage_rewrite.sh / caps_policy.py 一次没执行，真执行 caps_policy.py 的 5 支全部仍被路由到）：
    含中文的引号段是给人看的话（echo / fail / print 的提示、单测标签），整段换成空串。
    像要执行的段原样留（宁多勿漏）：带命令替换 / 语句分隔 / 管道 / source、以 bash / python3 / 脚本路径开头、或紧跟在 -c / eval 后面的
    （bash -c 'source ./devlock.sh; devlock_acquire 单测' 这类参数带中文的命令串是真执行）"""
    def sub(m):
        g = m.group(0)
        if not CJK.search(g) or CODEISH.search(g) or re.search(r'(?:-c|eval)\s*$', m.string[:m.start()]): return g
        return '""'
    return '\n'.join(QSEG.sub(sub, l) for l in code.split('\n'))


_REFS = {}   # (路径, direct) → (点名的文件, 全文)：一次运行里每个文件只解析一次（193 份单测的闭包反复经过同一批脚本，不缓存时 refs 调 5608 次、单次路由 7 秒）


def refs(path, by_name, direct=False):
    k = (path, direct)
    if k not in _REFS: _REFS[k] = _refs(path, by_name, direct)
    return _REFS[k]


def _refs(path, by_name, direct):
    try: txt = open(path, encoding='utf-8', errors='replace').read()
    except OSError: return frozenset(), ''
    got = set()   # 只看代码行：整行注释里提到的文件名（「见 oneshot.sh」）不是依赖
    src = drop_docstrings(txt) if path.endswith('.py') else txt
    code = '\n'.join(re.sub(r'\s#\s.*$', '', l) for l in src.split('\n') if not l.lstrip().startswith('#'))   # 行尾「  # 说明」也去掉
    code = drop_prose(code)
    toks = set(TOK.findall(code)) | {m + '.py' for m in re.findall(r'^\s*(?:from|import)\s+(\w+)', code, re.M)}   # Python 同目录模块 import
    for t in toks:
        # 单测自己（direct）带目录点名的文件按仓库路径认，不限本线目录、不按文件名猜：从整段起逐级去掉开头一段，取第一个与仓库文件路径相同的（「$H/graphics/…」取出来是 H/gfx/…）。
        #   10-22：tests/xc_key_test.sh 写的是 $H/graphics/tools/shbake/xc_key.sh，原先只按文件名在本线目录里找、找不到就丢，11 份单测的本线外依赖都不进路由。
        #   只认单测自己点名的：顺着编排脚本（gate.sh → 钩子、维护方工具 → ipa.sh → shader_pack.sh）一路认下去，会把在假仓库里跑桩的单测都挂到 gfx 工具上
        hit = None
        if direct and '/' in t:
            ps = t.split('/')
            for i in range(len(ps) - 1):
                q = '/'.join(ps[i:])
                if q in FILESET: hit = q; break
            if not hit:   # 相对某个目录写的（services/ 下跑的 opus/build.sh）：末两段只对上仓库里唯一一个文件才认
                m = TAIL2.get('/'.join(ps[-2:]), ())
                if len(m) == 1: hit = m[0]
        # 带目录、所在目录名仓库里根本没有的（部署出去的运行时副本：run/s2arm/bin/train-now/train.sh）不是仓库依赖，不按文件名猜
        #   （10-29 列车线：tools/ledger_post.sh 调部署的列车副本，按文件名挂到 tools/train.sh，72 个单测经它被推到，改列车一批跑 79 个单测）
        #   只认至少两层目录、末两段以上没有任何后缀是仓库路径的写法；「$HERE/x.c」「$TOOLS/dev_run.sh」这类变量加文件名照旧按文件名认
        if not hit and t.count('/') >= 2 and t.split('/')[-2] not in DIRNAMES \
           and not any('/'.join(t.split('/')[i:]) in FILESET for i in range(t.count('/'))): continue
        got |= {hit} if hit else by_name.get(os.path.basename(t), set())
    return frozenset(got), txt


# 列车入队预检（tools/train.sh pre()）固定跑的单测：shell_lint / shared_path / test_wired / shell_pyimports + 全部 tests/*lint*_test.sh。
#   列车门禁也必须每次跑它们：11-10 feat/img-read 改 pack/img.py 带进 os.walk，文本推导没路由到 romfs_walk_lint，合进 main 后所有支的入队预检都被拒。
#   规则与 pre() 同一条（改这里要同笔改 train.sh pre() 的 PL）
PRECHECK_TESTS = ('shell_lint_test', 'shared_path_test', 'test_wired_test', 'shell_pyimports_test')


def precheck_test(test):
    n = os.path.basename(test)
    if not (n.endswith('.sh') and os.path.dirname(test) == 'tests'): return False
    n = n[:-3]
    return n in PRECHECK_TESTS or fnmatch.fnmatch(n, '*lint*_test')


def test_cover(test, files, by_name, full=False):
    """单测的覆盖面：自身 + 文本里点名的本线文件的传递闭包 + 头部「门禁覆盖」通配。
    full=True（缓存键用）：「门禁只看」不截断闭包，只并进去——路由可以窄，缓存输入只能宽（10-30：train_test「门禁只看」漏 known_red.py，
    缓存一直沿用改判定前的绿，核干净 main 给了假绿）"""
    seen, todo, always, globs, closures, only = {test}, [test], False, list(DECLARED_TEST_COVERAGE.get(test, ())), [], None
    first, txt = refs(test, by_name, direct=True)
    for l in txt.split('\n')[:15]:
        m = re.match(r'#\s*门禁覆盖：(.*)', l)
        if m: globs += m.group(1).split()
        m = re.match(r'#\s*门禁只看：(.*)', l)
        if m: only = (only or []) + m.group(1).split()
        if re.match(r'#\s*门禁：每次', l): always = True
        m = re.match(r'#\s*门禁闭包：(.*)', l)   # 「门禁闭包：[--table <表>] <入口…>」：改动落在入口经 tools/stage_inputs.py 算出的依赖闭包里就跑（含新增文件）
        if m: closures.append(m.group(1).split())
    if precheck_test(test): always = True
    if only is not None:
        gone = [g for g in only if not re.search(r'[*?\[]', g) and g not in FILESET]   # 写错 / 改名的路径永远对不上 = 这支单测再也不跑，报红
        if gone: sys.exit(f'【红】gate_route：{test} 的「门禁只看」里 {" ".join(gone)} 不在仓库里（改名了要同笔改这行）')
        if not full: return {test} | build_cover([txt] + [read_text(f) for f in FILESET if f.endswith(('.sh', '.py')) and any(fnmatch.fnmatch(f, g) for g in only)]), globs + only, always
        globs = globs + only
    while todo:
        f = todo.pop()
        if not f.endswith(('.sh', '.py')) and f != test: continue
        got = first if f == test else refs(f, by_name)[0]
        for g in got - seen: seen.add(g); todo.append(g)
    for a in closures:   # 10-27 维护者：#550 改 runtime/run_mac.sh、新增 tools/mac_chain_check.py，落进直连阶段闭包，门禁没选 stage_keys_test，main 红
        seen |= stage_closure(tuple(a))
    seen |= build_cover([read_text(f) for f in seen if f.endswith(('.sh', '.py')) or f == test])
    return seen, globs, always


# 构建清单（11-09 维护方：feat/launch-settings 改 macos/front_mac.m，present_settings_test 现算 HOST_SRCS 把它编进来，
#   头上「门禁只看」手写清单没有它，列车没跑、合入后 main 红；同日 input_config_apple 同因退回一次——靠人手写覆盖面记不住）：
#   单测本身或它覆盖到的 .sh / .py 里用美元号加括号展开这些构建清单 → 覆盖面并进 make 从仓库根现算的清单（Mac 前端开 / 关两种取并集），「门禁只看」也并
BUILD_VARS = ('HOST_SRCS', 'IOS_SRCS')
_BUILD = {}


def read_text(f):
    try: return open(f, encoding='utf-8', errors='replace').read()
    except OSError: return ''


def build_files(var):
    if var not in _BUILD:
        out = set()
        # BUILD 指到临时目录、S2A_CS 置空（11-09）：Makefile 解析时就会改写 $(BUILD)/.host_cfg 配置戳（带 S2A_MAC_FRONTEND=1 时内容不同），
        #   原先落在本树 build/ 上，门禁里一算路由就把宿主 / NVN 单测目标文件全判旧，runtime/gate.sh 并行各组同时重编同一批 .o，链接读到空 / 半截文件；
        #   S2A_CS=1 从环境带进来还会在解析时起 NativeAOT 构建。只要源文件清单，不许有副作用
        with tempfile.TemporaryDirectory(prefix='gate_route_mk.') as tb:
            for extra in ([], ['S2A_MAC_FRONTEND=1']):
                p = subprocess.run(['make', '-s', '-f', 'Makefile', '-f', '-', '_gate_route_list', f'BUILD={tb}', 'S2A_CS=', *extra],
                                   input=f'_gate_route_list:;@echo $({var})\n', capture_output=True, text=True)
                if p.returncode: sys.exit(f'【红】gate_route：make 算不出构建清单 {var}（{p.stderr.strip()[:200]}）——推不出覆盖面不能静默放过')
                out |= {f for f in p.stdout.split() if f in FILESET}
        out |= {f for f in FILESET if f == 'Makefile' or f.endswith('/build.mk')}   # 清单本身由根 Makefile 与各 build.mk 拼出：改清单（加删源文件）也跑
        _BUILD[var] = out
    return _BUILD[var]


def build_cover(texts):
    out = set()
    for v in BUILD_VARS:
        if any('$(' + v + ')' in t for t in texts): out |= build_files(v)   # 只认构建命令里展开清单（美元号加括号取值）；单纯提到这个词（说明文字、定义清单的 .mk）不算
    return out


_CLOSURE = {}


def stage_closure(args):
    """tools/stage_inputs.py 算的依赖闭包（仓库跟踪文件集合）；算不出来报红退出（宁多勿漏不能靠静默）"""
    if args not in _CLOSURE:
        r = subprocess.run([sys.executable, 'tools/stage_inputs.py', *args], capture_output=True, text=True)
        if r.returncode: sys.exit(f'【红】gate_route：stage_inputs.py {" ".join(args)} 失败：{r.stderr.strip()[-200:]}')
        _CLOSURE[args] = {l for l in r.stdout.split('\n') if l}
    return _CLOSURE[args]


def load_table(root='.'):
    # 路由声明在各钩子自己的文件头「# 门禁路由：<前缀…>」（iOS 全量编译写在 tools/gate_ios.sh 头里），由 tools/gate_decl.py 收；
    #   原中央表 tools/gate_route.tsv 已删（10-30 维护者批：公用登记表是文件锁，三天 59 次冲突退回里 7 次在它上面）
    dp = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'gate_decl.py')
    if not os.path.exists(dp): return []   # 没有声明收集器（只拷了路由器的合成仓）= 没有任何钩子声明路由
    out = subprocess.run([sys.executable, dp, 'route', root], capture_output=True, text=True, check=True).stdout
    return [(k, v.split()) for k, _, v in (l.partition('\t') for l in out.splitlines() if l)]


def hit(changed, prefixes):
    return [f for f in changed if any(f == p or f.startswith(p) or fnmatch.fnmatch(f, p) for p in prefixes)]


FILESET = set()
DIRNAMES = set()   # 仓库里出现过的全部目录名（任一层）
TAIL2 = {}   # 末两段路径 → 以「/<末两段>」结尾的仓库文件（refs 相对目录写法用；逐个 endswith 扫全仓库要 390 万次）


def index():
    """读仓库文件表、建 refs 用的索引（在仓库根调；一个进程一次）→ (仓库文件, 文件名 → 本线文件)"""
    files = repo_files(); FILESET.update(files); DIRNAMES.update(d for f in files for d in f.split('/')[:-1])
    for f in files:
        ps = f.split('/')
        if len(ps) >= 3: TAIL2.setdefault('/'.join(ps[-2:]), []).append(f)
    by_name = {}
    for f in files:
        if f.startswith(LOCAL) and not f.startswith('tests/visual/'): by_name.setdefault(os.path.basename(f), set()).add(f)
    return files, by_name


def cover_files(test, files, by_name, full=False):
    """单测覆盖面落到具体文件（tools/test_cache.py 的缓存输入用；先 index()）：test_cover 的闭包 + 通配展开成仓库文件；「门禁：每次」→ None（与全部改动相关）"""
    seen, globs, always = test_cover(test, files, by_name, full)
    if always: return None
    return set(seen) | {f for f in files for g in globs if fnmatch.fnmatch(f, g)}


def main():
    mode, changed = sys.argv[1], [f for f in sys.argv[2:] if f]
    if mode == 'nohook':   # 过渡的无钩子路径（tools/test_wired_lint.py 读：这些前缀下的单测暂无钩子接线，不报没接线）
        if NOHOOK: print('\n'.join(NOHOOK))
        return
    if mode == 'owns':   # 10-25 维护者：vk/wp6 改了 graphics/nvn、红在 graphics/gate.sh，列车却报「与本批无关的步」——钩子与本批有关 = 本批有文件路由到它
        h, changed = changed[0], changed[1:]; ps = dict(load_table()).get(h)
        if ps is None: own = [f for f in changed if f.startswith(os.path.dirname(h) + '/')]   # 表里没登记的钩子：每次都跑，「负责的」按它自己的目录算
        else:
            known = [p for _, q in load_table() for p in q]
            code = [f for f in changed if f.startswith('tests/visual/') or not (DOC.search(f) or f.startswith(LOCAL + ('scripts/',) + NOHOOK))]
            own = hit(changed, ps) + [f for f in code if not hit([f], known) and f not in hit(changed, ps)]   # 表外代码路径让全部钩子跑，也算
        if own: print('\n'.join(own))
        return
    files, by_name = index()
    tests = sorted({f for f in files if re.match(r'^tests/[^/]+_test\.sh$', f)} | (set(DECLARED_TEST_COVERAGE) & FILESET))
    table = load_table()
    hooks_all = sorted(f for f in files if f.endswith('/gate.sh') and f != 'tools/gate.sh' and f.count('/') <= 3)
    known = [p for _, ps in table for p in ps]
    code = [f for f in changed if f.startswith('tests/visual/') or not (DOC.search(f) or f.startswith(LOCAL + ('scripts/',) + NOHOOK))]   # 代码改动（本线目录与文档以外）
    unknown = [f for f in code if not hit([f], known)]   # 表里没列到的代码路径 → 钩子全跑
    if mode == 'tests':
        for t in tests:
            cov, globs, always = test_cover(t, files, by_name)
            if not changed or always or set(changed) & cov or any(fnmatch.fnmatch(c, g) for c in changed for g in globs): print(t)
    elif mode == 'claimed':   # 10-31 合入线：tool 档原先一个钩子都不跑，钩子明写路由的本线目录（pack/jobs/、tests/autoplay/ …）改了也不跑
        for k, ps in table:
            if changed and hit(changed, ps) and k in hooks_all: print(k)
    elif mode in ('hooks', 'ios'):
        want = []
        for k, ps in table:
            if not changed or unknown or hit(changed, ps): want.append(k)
        if mode == 'ios': print('yes' if 'ios' in want else 'no')
        else:
            for h in hooks_all:
                if h in want or h not in dict(table): print(h)   # 表里没登记的新钩子：每次都跑（宁多勿漏），登记后才路由
    elif mode == 'evidence':   # 证据阶梯：能用回放证的不起整局（tests/回放契约.md）
        need = []
        if not changed: need.append('不知道改了啥 → 门禁全跑 + 整局：Mac 健康表九款')
        gal = ['graphics/', 'compat/tree/src/Ryujinx.Graphics.', 'tests/visual/']
        ipc = ['services/', 'compat/tree/src/Ryujinx.HLE', 'compat/tree/src/Ryujinx.Horizon', 'compat/tree/src/Ryujinx.Audio']
        ryu_other = [f for f in changed if f.startswith('compat/') and not hit([f], gal + ipc)]   # ARMeilleure / Cpu / Memory / 补丁 = 执行模型
        if hit(changed, ['runtime/', 'Makefile', '*/build.mk']) or unknown or ryu_other:
            need.append('整局：Mac 健康表九款（native / 宿主 / 执行模型改动；tools/mac_health.sh，每局 ≤300 秒）')
        if hit(changed, gal):
            need.append('GAL 录像回放：九款逐帧对拍（tests/visual/gate.sh，门禁自动跑）——不起整局')
        if hit(changed, ipc):
            need.append('IPC 录制回放：比应答（services/gate.sh，门禁自动跑）——不起整局')
        if hit(changed, ['tests/autoplay/']): need.append('自动玩家：假宿主 + 假驾驶员单测（tests/autoplay_test.sh，门禁自动跑）——不起整局')
        if not need: need.append('单测即可（门禁自动跑）——不起局')
        print('\n'.join(need))
    elif mode == 'why':
        if not changed: print('不知道改了啥（GATE_CHANGED 空）→ 全跑'); return
        ts = subprocess.run([sys.executable, __file__, 'tests', *changed], capture_output=True, text=True).stdout.split()
        hs = subprocess.run([sys.executable, __file__, 'hooks', *changed], capture_output=True, text=True).stdout.split()
        io = subprocess.run([sys.executable, __file__, 'ios', *changed], capture_output=True, text=True).stdout.strip()
        if os.environ.get('GATE_TIER') == 'tool':   # tool 档不跑 iOS 编译，钩子只跑路由明确点到的（tools/gate.sh、claimed）
            cl = subprocess.run([sys.executable, __file__, 'claimed', *changed], capture_output=True, text=True).stdout.split()
            print(f'改 {len(changed)} 个文件 → 单测 {len(ts)}/{len(tests)}、路由点到的钩子 {len(cl)}/{len(hooks_all)}（tool 档不跑 iOS 编译）'); return
        print(f'改 {len(changed)} 个文件 → 单测 {len(ts)}/{len(tests)}、钩子 {len(hs)}/{len(hooks_all)}、iOS 编译 {"跑" if io == "yes" else "不跑"}'
              + (f'（表外代码路径 {unknown[0]} 等 {len(unknown)} 个 → 钩子全跑）' if unknown else ''))
    else:
        sys.exit('用法：gate_route.py tests|hooks|ios|why|evidence <改到的文件…>')


if __name__ == '__main__':
    main()
