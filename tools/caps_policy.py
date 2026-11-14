#!/usr/bin/env python3
"""全能力出包的开关判定（维护者 10-29 07:0x「自适应满屏、解锁 60 帧都做成泛化默认支持的，只有强信号无法支持的时候才关闭」；
口径 docs/能力卡_数据口径.md 第 7 节）。pack/gen_caps.sh 与 tools/compatibility_report.py 只调这里，不各写一份：
  caps_policy.py decide <仓库> <产物根> [--all-caps | --both]   → 一行 TSV（--both：发布 / --all-caps 两行，引擎推导只做一次）：fps60 值 / 原因 / widen 值 / 原因 / fps60_display（1 = 来源是引擎通用全引擎档，宿主要放开出图间隔）
  caps_policy.py retest [<仓库>]                       → 复测清单：过时的强信号（登记哈希 ≠ 当前实现哈希），一行一条
  caps_policy.py hash <产物根> [<仓库>]                → 一行「widen=<哈希> fps60=<哈希>」（能力内容哈希 = 包里数据 + 宿主实现代码，验证账的键，见 cap_hashes）
每键：命中强信号 → 0（原因「强信号：…」）；否则本包有任一来源 → 1（原因「默认开：来源 …」）；一个来源都没有 → 0（静态强信号「无来源」；满屏有第三层、60 帧有全引擎档，实际不会出现）。
满屏例外（维护者 11-02 19:0x）：发布口径缺省关，只有本包带 widen_verified.tsv（真机验过）才开；有补丁的款由宿主读补丁打开；--all-caps 照旧有来源即开。
--all-caps（测试包）：不看登记的强信号，有来源即开。「判不出」「没跑到」不是强信号，照开。
来源（产物根里出包阶段写下的文件）：
  widen：第三层通用满屏（每款都有，所以宽屏缺省开，只看强信号）、widen_enable.<档位>.tsv（仓库表 / 闭环自动表）、widen_verified.tsv、widen_full.<档位>.tsv、cpatch.tsv 的 widescreen: 编号（社区宽屏补丁）、
         <模块>.widen.tsv 非空（通用宽屏改写点）
  fps60：fps.tsv（我方帧率表，含跨版本重定位 tools/fps_relocate.py 带过来的表）、cpatch.tsv 的 fps: 编号（社区帧率补丁，跟 60 帧开关走，runtime/src/cpatch.c）、
         引擎通用第一层（Unity / UE4，engine_l1；直连宿主放开交换间隔，L3 need_l3 才退回）；以上都没有 → 引擎通用（全引擎，清单 fps60_display 1 放开出图间隔）
强信号（只认这几种，登记在 docs/名单_能力强信号/：程序号 / 构建号 / 能力 / 信号 / 依据 / 日期；另外自动收 docs/名单_60帧/ 逻辑速度=红）：
  fps60：逻辑速度红（游戏变快 / 变慢）、开 60 帧后崩溃或卡死且归因到它、真机 60 帧档实测达不到且定因到实现瓶颈（帧率达不到：依据写帧率 / 提交线程 CPU / GPU 读数与局目录；
         10-31 维护者：下面的实测自动退回按实现哈希匹配，宿主实现每批都变、实际很少命中，定过因的款登记这一条、复测过删行）；
         实测未达标（自动，不用登记）：验证账同内容哈希、60 帧开着的局持续帧率 < 57 或整机 > 4.8 W（fps60_measured）
  widen：快检 AI 判宽屏后画面坏（把握 ≥ 0.8；含 Vulkan 款整幅横拉，如银河2）、开宽屏后崩溃且归因到它；
         实测对照（自动，不用登记）：验证账同构建开宽屏画面不过（同宽屏哈希）+ 关宽屏画面过（widen_measured）
  两键：静态无来源（本函数自动判）"""
import csv, functools, hashlib, os, re, sys

STRONG = 'docs/名单_能力强信号.tsv'   # 逻辑路径：tools/reglist.py name_of 映射到按款目录 docs/名单_能力强信号/<程序号>.tsv（10-30）
FPS = 'docs/名单_60帧.tsv'
FPS_AB = 'docs/名单_60帧逻辑速度.tsv'   # 普查同局 A/B 结论（11-02，tools/fps_ab_ledger.py 入账）：红 = 强信号关（立即）；绿只进来源说明（全引擎默认开，不再等放行）
SIGNALS = {'fps60': {'逻辑速度红', '崩溃归因', '卡死归因', '帧率达不到'}, 'widen': {'宽屏画面坏', '崩溃归因'}}


def rows(path):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import reglist
    n = reglist.name_of(path)
    if n:   # 按款登记表（docs/<表名>/<程序号>.tsv，10-30）：合并读
        t = reglist.text(os.path.dirname(os.path.dirname(os.path.abspath(path))), n)
        return list(csv.DictReader((l for l in t.splitlines() if not l.startswith('#')), delimiter='\t'))
    if not os.path.exists(path): return []
    with open(path, encoding='utf-8') as f:
        return list(csv.DictReader((l for l in f if not l.startswith('#')), delimiter='\t'))


def build_match(reg, bid):   # 登记的构建号可以是 main 头 0x40 起 16 字节的前缀（与名单表同口径），不许空
    reg = (reg or '').strip().lower()
    return len(reg) >= 16 and bid.lower().startswith(reg)


def strong(repo, pid, bid, hashes=None):
    """→ ({'fps60': 原因或 None, 'widen': 原因或 None}, [过时的登记])；登记行信号不在 SIGNALS 里、或没填内容哈希 → ValueError（不认的不当强信号，也不悄悄忽略）。
    登记行带「内容哈希」= 登记时这项能力的实现哈希（caps_policy.py signal-hash；SIGNAL_IMPL 里的宿主实现 + 数据选择代码，能力卡同算）。
    10-30 改（泛化线，强信号一小时内被别线合入三次带过时、马车8 / 动森已知坏能力回到开）：实现哈希变了强信号照旧生效（保持关），
    原因注明「实现已变，待重新实测」、过时的那条带回给调用方；只有复测过（tools/ab_pair.sh / 真机局）后删掉这行才放开——出包与能力卡同判。
    nvn_mtl.m 这类大文件几乎每批都有人改，按哈希自动撤销会把已知坏的能力悄悄发出去"""
    out, stale = {'fps60': None, 'widen': None}, {'fps60': [], 'widen': []}
    for i, r in enumerate(rows(os.path.join(repo, STRONG)), 2):
        cap, sig, h = r.get('能力', ''), r.get('信号', ''), (r.get('内容哈希') or '').strip()
        if cap not in SIGNALS or sig not in SIGNALS[cap]: raise ValueError(f'{STRONG}:{i}: 能力 / 信号不在口径里（{cap} / {sig}）')
        if len(h) != 16: raise ValueError(f'{STRONG}:{i}: 内容哈希要填登记时的 16 位实现哈希（python3 tools/caps_policy.py signal-hash），现为「{h}」')
        if r.get('程序号', '').upper() == pid.upper() and build_match(r.get('构建号'), bid) and not out[cap]:
            why = r.get("依据", "").strip() or "无依据"
            if hashes and hashes.get(cap) != h:   # 实现改过：强信号照旧生效（保持关），只标待重新实测；复测过了由复测的人删这行
                stale[cap].append(f'{sig}（登记哈希 {h}，本包 {hashes.get(cap)}）')
                out[cap] = f'强信号（过时·待重新实测）：{sig}（强信号可能过时：登记哈希 {h}、本包 {hashes.get(cap)}，本包实现下实测过才放开；{why}）'; continue
            out[cap] = f'强信号：{sig}（{why}）'
    for r in rows(os.path.join(repo, FPS)):
        if r.get('逻辑速度') == '红' and r.get('程序号', '').upper() == pid.upper() and build_match(r.get('构建号'), bid) and not out['fps60']:
            out['fps60'] = f'强信号：逻辑速度红（{FPS} {r.get("依据局", "").strip()[:60]}）'
    a = ab_row(repo, pid, bid)
    if a and a.get('结论') == '红' and not out['fps60']:
        out['fps60'] = f'强信号：逻辑速度红（同局 A/B ρ {a.get("ρ")}、q {a.get("q")}，{a.get("日期", "")}；{FPS_AB}）'
    return out, stale


def ab_row(repo, pid, bid):   # 本款本构建号的同局 A/B 结论行（同键多行取最后一行 = 最新）；没有 → None
    m = [r for r in rows(os.path.join(repo, FPS_AB)) if r.get('程序号', '').upper() == pid.upper() and build_match(r.get('构建号'), bid)]
    return m[-1] if m else None


def sources(root):
    def has(n): return os.path.exists(os.path.join(root, n))
    fs = os.listdir(root) if os.path.isdir(root) else []
    cp = rows(os.path.join(root, 'cpatch.tsv'))
    def nonempty(n):
        with open(os.path.join(root, n), encoding='utf-8', errors='replace') as f:
            return any(l.strip() and not l.startswith('#') for l in f)
    # 第三层不靠逐款表、每款都有（10-29 画面线：八方2 / 0100152000022000 第二层 0 个点也满屏、多档过），逐款表只是增强
    w = ['第三层通用满屏'] + [n for n in sorted(fs) if n.startswith('widen_enable.') and n.endswith('.tsv')] + (['widen_verified.tsv'] if has('widen_verified.tsv') else []) \
        + [n for n in sorted(fs) if n.startswith('widen_full.') and n.endswith('.tsv')]
    if any(r.get('编号', '').startswith('widescreen:') for r in cp): w.append('社区宽屏补丁')
    if any(n.endswith('.widen.tsv') and nonempty(n) for n in fs): w.append('通用宽屏改写')
    f = (['fps.tsv'] if has('fps.tsv') else []) + (['社区帧率补丁'] if any(r.get('编号', '').startswith('fps:') for r in cp) else [])
    if not f and engine_l1(root): f.append('引擎通用第一层（Unity / UE4 放开交换间隔）')
    return {'widen': w, 'fps60': f}


# 同一进程里按产物根只推导一次（decide --both 两种口径共用；推导要读 RomFS 文件头，火纹 27 万文件）
@functools.lru_cache(maxsize=None)
def engine_l1(root):
    """引擎通用第一层（10-29 60 帧泛化）：graphics/nvn/games/profile_guess.engine 对 Unity / UE4 主程序推导 present_interval_derived=display
    （引擎自己的 targetFrameRate / t.MaxFPS 管限帧，交换间隔放开后逻辑按真实时间推进）。直连宿主按 game_tsv.h s2a_present_decide 放开出图间隔，
    逻辑速度红（L3 need_l3 / 名单_60帧 红 / 强信号表）才关。产物根没有 exefs + romfs → False；推导失败 → False 并在错误输出打【红】行（不算来源、不中断）"""
    ex, rf = os.path.join(root, 'exefs'), os.path.join(root, 'romfs')
    if not (os.path.isdir(ex) and os.path.exists(rf)): return False
    try:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'graphics', 'nvn', 'games')); import profile_guess
        F = profile_guess.facts_of(ex, rf); profile_guess.guess(F)
        return (profile_guess.engine(F).get('present_interval_derived') or ('',))[0] == 'display'
    except Exception as e:   # 审计 P1-138：推导出错照旧不算来源、不中断出包（60 帧还有名单 / 补丁等来源），但必须响亮报出来，不能静默当「不是 Unity / UE」
        print(f'【红】caps_policy 引擎推导出错（{root}），本次不把引擎通用算作 60 帧来源：{type(e).__name__}: {e}', file=sys.stderr)
        return False


# 实现这项能力的宿主代码（维护者 10-29：能力内容哈希要把实现也算进去——宿主这些文件一改，对应能力就重验；没改就复用验证结论）
#   按出包平台分（#1574 F7，#996 防重演）：apple = iOS / Mac 同一套实现；android = 安卓宿主那一套。两个平台的实现分开算哈希——
#   苹果验过的行不会放行安卓包，安卓宿主的改动也不会误伤苹果的验证结论（impl 缺文件记「缺」：F2 将新增的安卓宽屏层还没落库）
IMPL = {'apple': {'widen': ('runtime/src/widen.c', 'graphics/metal/gal_present.m', 'graphics/metal/fit_judge.h', 'graphics/nvn/gfx/nvn/nvn_mtl.m', 'runtime/src/caps.c',
                          'graphics/nvn/widen_glue.inc', 'graphics/widen/WidenFrame.cs', 'graphics/widen/WidenSession.cs', 'graphics/widen/export/s2a_widen.h'),   # 保留原苹果哈希；GAL 包装层是否纳入另由 owner 定
                  'fps60': ('runtime/src/fps.c', 'runtime/src/cpatch.c', 'runtime/src/caps.c')},   # 帧率表装载与限帧 / 社区帧率补丁运行时 / 开关
        'android': {'widen': ('runtime/src/widen.c', 'runtime/src/caps.c', 'graphics/widen/WidenFrame.cs', 'graphics/widen/WidenSession.cs',
                            'graphics/widen/gal/WidenRenderer.cs', 'android/native/screen_metrics.c',
                            'graphics/vulkan/wsi/AndroidPresentFit.cs',
                            'graphics/vulkan/runtime/AndroidWidenComposition.cs', 'graphics/vulkan/runtime/AndroidWidenProgramCache.cs'),   # 后两个由 F2 落库
                    'fps60': ('android/native/fps_provider.c', 'runtime/src/cpatch.c', 'runtime/src/caps.c')}}   # 安卓编译面（Runtime.cmake）：fps_provider + 补丁运行时 + 开关；runtime/src/fps.c 不在安卓链接清单里


# 强信号失效键（10-29 维护者：强信号随修复自动失效，能力卡与包里清单要一致）：只取仓库里就有的文件——能力的宿主实现 + 决定包里数据的选择 / 生成代码。
#   出包（caps_policy 读工作树）与能力卡（compatibility_report 读固定提交）算同一份，判「过时」结果一致；不含包里数据（能力卡没有产物根）。
#   不放改写器全文：它天天改，崩溃类强信号会被频繁解除、把崩的配置放回发布包
#   安卓（F7）：宽屏数据（已验证标记 + 随包宽屏表）由 stage_caps.sh / make_pack.py 按平台选——它们是安卓的「选择代码」，进失效键；
#   安卓没有逐款帧率表 / 社区补丁打包流程，fps60 就是实现集本身
SIGNAL_IMPL = {'apple': {'widen': IMPL['apple']['widen'] + ('tools/widen_accept.py',),
                         'fps60': IMPL['apple']['fps60'] + ('pack/cpatch.py', 'tools/fps_generic.py', 'tools/ue_cvar_loc.py', 'tools/fps_warehouse.py', 'tools/fps_relocate.py')},
               'android': {'widen': IMPL['android']['widen'] + ('pack/stage_caps.sh', 'android/tools/make_pack.py'),
                           'fps60': IMPL['android']['fps60']}}


# 日志调用（10-30 维护者：只剔已知日志函数调用实参里的字符串，其余字符串一律计入——MSL 模板、命令行 / 输出格式串含空格也直接决定画面）。
#   C 系：我方日志宏（宿主 LOG / die、nvn_mtl MLOG / MDIE / PD / TESS_SKIP / FJ_LOG、gal GLOG / GRED_ONCE）、NSLog、s2a_log*、fixture_log、
#   fprintf / vfprintf 只在第一个实参是 stderr 时；C# 只认 Console.Error.Write*。printf / 往文件写的 fprintf / 裸 print（stdout 可能就是数据，
#   如 pack/cpatch.py 打 TSV）照算。Python：print(..., file=sys.stderr) 与 logging.* / log.*
LOG_CALLS = {'LOG', 'die', 'MLOG', 'MDIE', 'PD', 'TESS_SKIP', 'FJ_LOG', 'GLOG', 'GRED_ONCE', 'NSLog', 'fixture_log', 's2a_log', 's2a_log_line'}
_C_EXT = ('.c', '.h', '.m', '.inc', '.cs', '.cpp', '.mm')


def _c_tokens(t):
    """C 系粗词法：→ [(类型, 文本)]，类型 id / str / chr / sp / op；注释去掉（换成空白）"""
    out, i, n = [], 0, len(t)
    while i < n:
        c = t[i]
        if t.startswith('//', i):
            j = t.find('\n', i); i = n if j < 0 else j
        elif t.startswith('/*', i):
            j = t.find('*/', i + 2); i = n if j < 0 else j + 2; out.append(('sp', ' '))
        elif c == '"' or (c in '@$' and i + 1 < n and t[i + 1] == '"') or (t.startswith(('$@"', '@$"'), i)):
            pre = 3 if t.startswith(('$@"', '@$"'), i) else (2 if c in '@$' else 1)
            verb = '@' in t[i:i + pre - 1] and t[i] != '"'; j = i + pre
            while j < n:
                if verb and t[j] == '"' and j + 1 < n and t[j + 1] == '"': j += 2; continue
                if not verb and t[j] == '\\': j += 2; continue
                if t[j] == '"' or (t[j] == '\n' and not verb): break
                j += 1
            out.append(('str', t[i:j + 1])); i = j + 1
        elif c == "'":
            j = i + 1
            while j < n and t[j] != "'" and t[j] != '\n': j += 2 if t[j] == '\\' else 1
            out.append(('chr', t[i:j + 1])); i = j + 1
        elif c.isspace():
            while i < n and t[i].isspace(): i += 1
            out.append(('sp', ' '))
        elif c.isalnum() or c == '_':
            j = i
            while j < n and (t[j].isalnum() or t[j] == '_'): j += 1
            out.append(('id', t[i:j])); i = j
        else: out.append(('op', c)); i += 1
    return out


def _c_log_at(tk, k):
    """tk[k] 起是不是日志调用名：→ 名字占的 token 个数（含 Console.Error.WriteLine 这类点号链），不是 → 0"""
    def nxt(m):   # 跳过空白的下一个 token 下标
        while m < len(tk) and tk[m][0] == 'sp': m += 1
        return m
    if tk[k][0] != 'id' or (k and tk[k - 1] == ('op', '.')): return 0, 0
    name = tk[k][1]
    if name == 'Console':
        seq, m = [], k
        for want in ('Console', '.', 'Error', '.'):
            m = nxt(m)
            if m >= len(tk) or tk[m][1] != want: return 0, 0
            m += 1
        m = nxt(m)
        if m < len(tk) and tk[m][0] == 'id' and tk[m][1].startswith('Write'): return k, m + 1
        return 0, 0
    if name in LOG_CALLS: return k, k + 1
    if name in ('fprintf', 'vfprintf'):
        m = nxt(k + 1)
        if m < len(tk) and tk[m] == ('op', '('):
            m = nxt(m + 1)
            if m < len(tk) and tk[m] == ('id', 'stderr'): return k, k + 1
    return 0, 0


def _c_norm(t):
    tk = _c_tokens(t); out, k, n = [], 0, len(tk)
    while k < n:
        st, en = _c_log_at(tk, k)
        if en:
            m = en
            while m < n and tk[m][0] == 'sp': m += 1
            if m < n and tk[m] == ('op', '('):   # 日志调用：实参里的字符串换成 ""（表达式照算），括号配对
                out.extend(x[1] for x in tk[k:m + 1]); depth, m = 1, m + 1
                while m < n and depth:
                    ty, v = tk[m]
                    if v == '(' and ty == 'op': depth += 1
                    elif v == ')' and ty == 'op': depth -= 1
                    out.append('""' if ty == 'str' else v); m += 1
                k = m; continue
        out.append(tk[k][1]); k += 1
    return re.sub(r' +', ' ', ''.join(out)).strip()


def _py_norm(t):
    import io, tokenize
    toks = [x for x in tokenize.generate_tokens(io.StringIO(t).readline)
            if x.type not in (tokenize.COMMENT, tokenize.NL, tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT, tokenize.ENDMARKER)]
    FS = {getattr(tokenize, n) for n in ('FSTRING_START', 'FSTRING_MIDDLE', 'FSTRING_END') if hasattr(tokenize, n)}
    out, k, n = [], 0, len(toks)
    while k < n:
        v = toks[k].string
        log = False
        if toks[k].type == tokenize.NAME and (k == 0 or toks[k - 1].string != '.') and k + 1 < n:
            if v in ('logging', 'log', 'logger') and toks[k + 1].string == '.': log = True
            elif v == 'print' and toks[k + 1].string == '(':   # print 只有 file=sys.stderr 才算日志
                d, m = 0, k + 1
                while m < n:
                    d += {'(': 1, ')': -1}.get(toks[m].string, 0) if toks[m].type == tokenize.OP else 0
                    if d == 0: break
                    m += 1
                seg = ' '.join(x.string for x in toks[k:m + 1]); log = re.search(r'\bfile = sys \. stderr\b', seg) is not None
        if log:
            m = k
            while m < n and toks[m].string != '(': out.append(toks[m].string); m += 1
            d = 0
            while m < n:
                x = toks[m]
                if x.type == tokenize.OP and x.string == '(': d += 1
                elif x.type == tokenize.OP and x.string == ')': d -= 1
                out.append('""' if x.type == tokenize.STRING else ('' if x.type in FS and x.type != getattr(tokenize, 'FSTRING_START', -1) else x.string))
                m += 1
                if d == 0: break
            k = m; continue
        out.append(v); k += 1
    return ' '.join(out)


def impl_text(name, b):
    """实现文件 → 判定逻辑的规范文本（10-30 维护者：日志文本和判定逻辑分开）：去注释、空白压成一个、只把已知日志调用（LOG_CALLS 等）实参里的
    字符串换成 ""；其余字符串一律原样计入（着色器模板、格式串、环境变量名、文档字符串都算）。读不懂（解码 / 词法出错）退回原字节——宁可多重验，不漏验"""
    if b is None: return None
    ext = os.path.splitext(name)[1]
    try: t = b.decode('utf-8')
    except UnicodeDecodeError: return b
    if ext == '.py':
        import tokenize
        try: return _py_norm(t).encode()
        except (tokenize.TokenError, IndentationError, SyntaxError): return b
    if ext in _C_EXT: return _c_norm(t).encode()
    return b


def signal_hashes(read, target='apple'):
    """→ {'widen': 16 位, 'fps60': 16 位}；read(相对路径) → bytes 或 None（缺文件记「缺」）。强信号表「内容哈希」列登记的就是它。
    target ∈ IMPL 的键（apple / android）：安卓平台盐 + 该平台的实现文件集，苹果保留原算法，登记哈希按平台分（F7）"""
    out = {}
    for cap, names in SIGNAL_IMPL[target].items():
        d = hashlib.sha256()
        if target == 'android': d.update(b'plat:' + target.encode() + b'\0')
        for n in names: b = impl_text(n, read(n)); d.update(b'impl:' + n.encode() + b'\0' + (b if b is not None else '缺'.encode()) + b'\0')
        out[cap] = d.hexdigest()[:16]
    return out


def repo_reader(repo):   # 工作树读法（出包用）
    def read(n):
        f = os.path.join(repo, n)
        return open(f, 'rb').read() if os.path.isfile(f) else None
    return read


def cap_hashes(root, repo=None, target='apple'):
    """这项能力的内容哈希（验证账的键之一，tools/caps_ledger.py；10-29 维护者「验证只做一次」）：包里的数据 + 实现它的宿主代码，
    逐个「名字 + 内容」喂 SHA-256，取前 16 位。包里：widen = widen_enable* / widen_full* / widen_verified / 非空 <模块>.widen.tsv / cpatch.tsv 的
    widescreen: 行；fps60 = fps.tsv / cpatch.tsv 的 fps: 行。宿主：IMPL[target] 里的文件（repo 缺省本仓库，读工作树；缺文件记「缺」）。
    target 是 IMPL 的键（apple / android）：仅安卓在摘要前加平台盐 plat:android，苹果保留原摘要——同一组包里文件名，安卓哈希与苹果哈希不同（F7），
    苹果「过」的账行不会放行安卓包。两样都没变 = 哈希不变 = 不用重验。验证账只管能力验证类局；崩溃 / 冷启 / 收局这类稳定性复验不走账，
    宿主或运行时一改就照常上真机"""
    repo = repo or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    fs = sorted(os.listdir(root)) if os.path.isdir(root) else []
    cp = [l for l in (open(os.path.join(root, 'cpatch.tsv'), encoding='utf-8', errors='replace').read().splitlines() if 'cpatch.tsv' in fs else [])]
    def h(names, prefix, impl):
        d = hashlib.sha256()
        if target == 'android': d.update(b'plat:' + target.encode() + b'\0')
        for n in names: d.update(n.encode() + b'\0' + open(os.path.join(root, n), 'rb').read() + b'\0')
        for n in impl:
            f = os.path.join(repo, n); b = impl_text(n, open(f, 'rb').read()) if os.path.isfile(f) else None; d.update(b'impl:' + n.encode() + b'\0' + (b if b is not None else '缺'.encode()) + b'\0')
        for l in cp:
            if l.startswith(prefix): d.update(l.encode() + b'\n')
        return d.hexdigest()[:16]
    w = [n for n in fs if (n.startswith(('widen_enable.', 'widen_full.')) and n.endswith('.tsv')) or n == 'widen_verified.tsv' or n.endswith('.widen.tsv')]
    return {'widen': h(w, 'widescreen:', IMPL[target]['widen']), 'fps60': h([n for n in fs if n == 'fps.tsv'], 'fps:', IMPL[target]['fps60'])}


def ident(root):   # 产物根 → (程序号, main 构建号前 16 字节十六进制)
    pid = next((r[1].upper() for r in csv.reader(open(os.path.join(root, 'unpack.tsv'), encoding='utf-8', errors='replace'), delimiter='\t') if len(r) > 1 and r[0] == 'title_id'), '') \
        if os.path.exists(os.path.join(root, 'unpack.tsv')) else ''
    try:
        with open(os.path.join(root, 'exefs', 'main'), 'rb') as f: f.seek(0x40); bid = f.read(16).hex()
    except OSError: bid = ''
    return pid, bid


def native60(repo, pid, bid):   # 能力覆盖表 L1交换间隔 = L2引擎限帧 = 不需要：游戏自己就跑 60 帧（无表时宿主跟随游戏，写 1 不触发改写；口径第 7 节「原生 60 帧」）
    return any(r.get('程序号', '').upper() == pid.upper() and build_match(r.get('构建号'), bid) and r.get('L1交换间隔') == '不需要' and r.get('L2引擎限帧') == '不需要'
               for r in rows(os.path.join(repo, 'docs/名单_60帧能力覆盖.tsv')))


FPS60_MIN = 57.0   # 60 帧开着的持续平均帧率下限（10-29 维护者：一款第一方动作冒险游戏 32 帧 / 怪猎崛起 52.5 帧 / 巫师3 38 帧——开了达不到，退回原帧率）
W30_MAX = 3.7      # 30 帧能耗线（同 score_cells.W_MAX）：自适应款主要稳在 30 档时按它判（10-29 维护者「按实际稳住的档用对应能耗线」）
W60_MAX = 4.8      # 60 帧能耗线（维护者 10-26，与 tools/score_cells.py W_MAX60 同值，tests/caps_policy_test 核一致；不 import 它：改写阶段键不想带 score_cells 全文）


def fps60_measured(repo, root, pid, bid, target='apple'):
    """实测退回（10-29 维护者：通用规则，不是逐款开关）：验证账（tools/caps_ledger.py）里本程序号 + 构建号、fps60 内容哈希与本包相同、
    且那局 60 帧是开着的（实测两列有数）——持续平均帧率 < FPS60_MIN，或整机功率 > 60 帧能耗线（W60_MAX）→ 原因字符串；否则 None。
    内容哈希含帧率数据 + 宿主实现（cap_hashes 按 target 平台算），实现或数据一改哈希就变、退回自动解除、回到默认开重新实测"""
    import caps_ledger
    h = cap_hashes(root, repo, target)['fps60']
    # 自适应款（包里帧率表带 speed 行：游戏速度读宿主步长、宿主帧步每帧保持整数 vsync，60 撑不住稳定落 30、速度不变；10-29 维护者「不再整个退回」）：
    #   平均帧率低不是能力坏了，只按能耗线判；没有 speed 行的固定 60 款照旧两条都判
    try: adaptive = any(l.split()[:1] == ['speed'] for l in open(os.path.join(root, 'fps.tsv'), encoding='utf-8', errors='replace'))
    except OSError: adaptive = False
    for r in caps_ledger.load(repo):
        if (r['程序号'].upper(), r['构建号'].lower(), r['能力'], r['内容哈希']) != (pid.upper(), bid.lower(), 'fps60', h): continue
        try: f = float(r['实测帧率']) if r['实测帧率'] != '-' else None; w = float(r['实测瓦']) if r['实测瓦'] != '-' else None
        except ValueError: continue
        try: h60 = float(r.get('60档占比', '-'))
        except ValueError: h60 = None
        lim = W30_MAX if adaptive and h60 is not None and h60 < 0.5 else W60_MAX   # 自适应款按主档位选线；占比未知按 60 帧线（宽的那条，不误关）
        bad = ([f'持续 {f:.1f} 帧 < {FPS60_MIN:g}'] if f is not None and f < FPS60_MIN and not adaptive else []) + \
              ([f'{w:.2f} W > {lim:g} W' + (f'（自适应，60 档占比 {h60 * 100:.0f}%）' if adaptive and h60 is not None else '')] if w is not None and w > lim else [])
        if bad: return f'强信号：实测未达标（{" / ".join(bad)}；机型 {r["机型"]}，报告 {r["报告指纹"]}，{caps_ledger.LEDGER}）'
    return None


def retest_pass(repo, root, pid, bid, cap, target='apple'):
    """验证账里本包实现下这项能力实测过 → 报告指纹说明串；否则空串。键 = 程序号 + 构建号 + 能力 + 本包内容哈希（cap_hashes 按 target 平台算），
    结论「过」、信任不是「冲突」"""
    import caps_ledger
    h = cap_hashes(root, repo, target)[cap]
    for r in caps_ledger.load(repo):
        if (r['程序号'].upper(), r['构建号'].lower(), r['能力'], r['内容哈希']) == (pid.upper(), bid.lower(), cap, h) and r['结论'] == '过' and r['信任'] != '冲突':
            return f'机型 {r["机型"]}，报告 {r["报告指纹"]}，{r["信任"]}'
    return ''


def retest_list(repo, target='apple'):
    """复测清单（10-30 维护者：过时的强信号自动进复测清单）：登记哈希 ≠ 当前实现哈希（按 target 平台算）的强信号行 → [(程序号, 构建号, 能力, 信号, 登记哈希, 当前哈希, 依据)]。
    复测过了删行（修复作者在修复 PR 里删，或测试恢复后按清单复测）；没过按当前哈希重新登记"""
    cur = signal_hashes(repo_reader(repo), target); out = []
    for r in rows(os.path.join(repo, STRONG)):
        h = (r.get('内容哈希') or '').strip()
        if r.get('能力') in cur and h != cur[r['能力']]:
            out.append((r.get('程序号', ''), r.get('构建号', ''), r['能力'], r.get('信号', ''), h, cur[r['能力']], (r.get('依据') or '').strip()))
    return out


def widen_measured(repo, root, pid, bid, target='apple'):
    """宽屏自动强信号（10-30 #996：丝之歌 iPhone 15 Pro 宽屏放开后两侧缺渲染 / 暂停层不全 / 字变扁，作者同包同机只关宽屏五条全消；「缺省开、强信号才关」
    缺的是自动强信号）：验证账里本程序号 + 构建号，有一份「宽屏开着」的快检报告画面判不过、且那份报告的 widen 内容哈希 = 本包；又有一份「宽屏关着」的报告画面判过
    → 单变量对照成立，原因字符串；否则 None。看图判画面是快检 AI 判官（tools/quality_check.py），这里只按账里的结论做规则判断。
    宽屏实现或数据一改，开着那份报告的哈希对不上，信号自动解除、回到默认开重新实测"""
    import caps_ledger
    hw = cap_hashes(root, repo, target)['widen']
    rs = [r for r in caps_ledger.load(repo) if r['程序号'].upper() == pid.upper() and r['构建号'].lower() == bid.lower()]
    wh = {r['报告指纹']: r['内容哈希'] for r in rs if r['能力'] == 'widen'}
    pic = [r for r in rs if r['能力'] == '画面']
    bad = [r for r in pic if r.get('本局满屏') == '开' and r['结论'] == '不过' and wh.get(r['报告指纹']) == hw]
    good = [r for r in pic if r.get('本局满屏') == '关' and r['结论'] == '过']
    if bad and good:
        return f'强信号：宽屏画面坏（实测对照：开宽屏画面不过 报告 {bad[0]["报告指纹"]}，关宽屏画面过 报告 {good[0]["报告指纹"]}；{caps_ledger.LEDGER}）'
    return None


# 只用社区补丁（11-13 维护者：「补丁方案已经彻底覆盖咱们通用满屏和60帧解锁的功能……撤掉咱们的60帧和通用满屏这一层，用开关实现……
#   玩家拿到的就是干净的补丁方案或者原生游戏方案」）：fps60 只在有社区帧率补丁时开（60 帧开关此后只是「开关帧率补丁」），其余款原帧率；
#   widen（我方满屏层）一律关——社区宽屏补丁走自己的开关（runtime/src/cpatch.c、widen.c ws_yield），不看这一键。
#   S2A_CAPS_OWN=1 回到旧口径（我方帧率表 / 全引擎放开 / 我方满屏各来源照旧算），只给内部对照用
def patch_only(): return os.environ.get('S2A_CAPS_OWN') != '1'


def decide(repo, root, all_caps=False, target='apple'):
    """target ∈ IMPL 的键（apple / android）：强信号失效键、验证账内容哈希、已实测行全部按该平台口径查（F7：苹果验过的行不放行安卓包）"""
    pid, bid = ident(root); src = sources(root)
    if patch_only():
        fps = '社区帧率补丁' in src['fps60']
        return {'fps60': (1, '默认开：来源 社区帧率补丁（只用社区补丁）') if fps else (0, '原帧率：没有社区帧率补丁（只用社区补丁，维护者 11-13 撤掉我方 60 帧）'),
                'widen': (0, '我方满屏不用（只用社区宽屏补丁，维护者 11-13 撤掉我方通用满屏）'), 'fps60_display': 0}
    if pid and bid and native60(repo, pid, bid): src['fps60'].append('游戏原生 60 帧')
    st, stale = ({'fps60': None, 'widen': None}, {'fps60': [], 'widen': []}) if all_caps or not (pid and bid) else strong(repo, pid, bid, signal_hashes(repo_reader(repo), target))
    for cap in ('fps60', 'widen'):   # 过时的强信号：本包实现下实测过（验证账同程序号 + 构建号 + 能力 + 本包内容哈希、结论过、没冲突）才放开（10-30 维护者定 (B)）
        if st[cap] and st[cap].startswith('强信号（过时'):
            ok = retest_pass(repo, root, pid, bid, cap, target)
            if ok: st[cap] = None; stale[cap] = [f'{x}，本包实现下实测过（{ok}），已放开——请删掉这行登记' for x in stale[cap]]
    # 引擎通用（11-02 维护者：60 帧扩到所有引擎，同满屏「默认开、强信号才关」）：没有帧率表 / 社区补丁 / Unity·UE 推导的款，清单写 fps60_display 1 让宿主放开出图间隔
    #   （交换间隔是游戏要 30 帧最常见的上限手段，按真实时间推进的款放开就是正确 60 帧）；按帧推进的款由普查同局 A/B 判红自动关（strong()），玩家运行中可回退
    disp = 0
    if not src['fps60']:
        a = ab_row(repo, pid, bid) if pid and bid else None
        src['fps60'].append(f'逻辑速度同局 A/B 绿（ρ {a.get("ρ")}、q {a.get("q")}，放开出图间隔）' if a and a.get('结论') == '绿'
                            else '引擎通用：放开出图间隔（全引擎，同局 A/B 判红才关）'); disp = 1
    if not (all_caps or st['fps60']) and pid and bid and src['fps60']: st['fps60'] = fps60_measured(repo, root, pid, bid, target)   # 有来源、没登记强信号：再看实测
    if not (all_caps or st['widen']) and pid and bid and src['widen']: st['widen'] = widen_measured(repo, root, pid, bid, target)   # 宽屏同理：开 / 关实测对照
    # 满屏发布缺省关（维护者 11-02 19:0x：保持 16:9 两侧黑边，有补丁的款由补丁打开——补丁 [caps] widen 1 在宿主压过本清单，runtime/src/caps.c）：
    #   --all-caps（实验 / 调试包）照旧有来源即开；本包带 widen_verified.tsv（真机验过的逐款表）照旧开；玩家在设置里手动开照旧生效；
    #   安卓同口径（F7：标记只由 stage_caps.sh 按平台列写进产物根，apple 行验过的款不会冒出安卓标记）
    if not all_caps and not st['widen'] and 'widen_verified.tsv' not in src['widen']:
        st['widen'] = '发布缺省关（维护者 11-02：满屏默认关、16:9 两侧黑边，有补丁或真机验过的款才开）'
    out = {}
    for cap, name in (('fps60', '帧率'), ('widen', '宽屏')):
        if st[cap]: out[cap] = (0, st[cap])
        elif src[cap]: out[cap] = (1, '默认开：来源 ' + '、'.join(src[cap]) + ''.join(f'；强信号 {x}' for x in stale[cap]))
        else: out[cap] = (0, f'强信号：静态无来源（没有任何{name}来源）')
    out['fps60_display'] = disp if out['fps60'][0] == 1 else 0
    return out


if __name__ == '__main__':
    a = sys.argv[1:]
    # --target <apple|android>（F7：所有命令通用；缺省 apple = 原 iOS / Mac 口径，位置参数照旧）
    target = 'apple'
    if '--target' in a:
        i = a.index('--target'); target = a[i + 1] if i + 1 < len(a) else ''; del a[i:i + 2]
        if target not in IMPL: print(__doc__.strip().splitlines()[0]); sys.exit(2)
    if len(a) in (1, 2) and a[0] == 'signal-hash':   # 登记强信号时填的「内容哈希」：打一行 widen=<哈希> fps60=<哈希>；第 2 个参数 = 仓库（缺省本仓库）
        print(' '.join(f'{k}={v}' for k, v in signal_hashes(repo_reader(a[1] if len(a) == 2 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), target).items()))
    elif a == ['signal-files']:   # 强信号失效键覆盖的实现文件（冒号分隔、仓库相对路径、按 target 平台）：本模块读它们只按去注释的判定文本算哈希，pack/stage_caps.sh 交给 S2A_DEPS_KEYED、不再按原始字节整份进键
        print(':'.join(sorted({n for v in SIGNAL_IMPL[target].values() for n in v})))
    elif len(a) in (2, 3) and a[0] == 'hash':   # 排局前查验证账用（基础设施线）：打一行 widen=<哈希> fps60=<哈希>；第 3 个参数 = 仓库（缺省本仓库）
        print(' '.join(f'{k}={v}' for k, v in cap_hashes(a[1], a[2] if len(a) == 3 else None, target).items()))
    elif len(a) in (1, 2) and a[0] == 'retest':   # 复测清单：过时的强信号（登记哈希 ≠ 当前实现哈希），一行一条；第 2 个参数 = 仓库
        L = retest_list(a[1] if len(a) == 2 else os.path.dirname(os.path.dirname(os.path.abspath(__file__))), target)
        print('程序号\t构建号\t能力\t信号\t登记哈希\t当前哈希\t依据')
        for x in L: print('\t'.join(' '.join(str(v).split()) for v in x))
    elif len(a) in (3, 4) and a[0] == 'decide':
        # --both：一个进程里先发布口径、再 --all-caps 口径各打一行（引擎推导只做一次，pack/stage_caps.sh 一次出两份清单）
        clean = lambda s: ' '.join(str(s).replace('\t', ' ').split())
        for all_caps in ((False, True) if '--both' in a else ('--all-caps' in a,)):
            d = decide(a[1], a[2], all_caps, target)
            print('\t'.join([str(d['fps60'][0]), clean(d['fps60'][1]), str(d['widen'][0]), clean(d['widen'][1]), str(d['fps60_display'])]))
    else:
        print(__doc__.strip().splitlines()[0]); sys.exit(2)
