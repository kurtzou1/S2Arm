#!/usr/bin/env python3
"""普查规则层（tools/census/census.sh 调；驱动只管解包 / 派局，判定与汇总都在这里，可单测）：
  census.py inventory <源目录[:源目录…]> <批次目录>   盘点：源目录顶层每个 .nsp / .xci / .nsz / .xcz 用 nx_unpack --inspect 读内容清单（单进程顺序读，机械盘只许一个读者），
                                             读成功的缓存在 <批次>/inventory/（换批次可拷过去复用），读不出的每次重读（nx_unpack 修好就自动认出）
  census.py plan <批次目录>                 排队：按本体程序号分组 → <批次>/queue.tsv（按字节从小到大，总表已有的款跳过）；不起局直接记总表的只有 0 字节文件（源文件坏）。
                                             32 位不在盘点预判：补丁可能把 32 位本体换成 64 位（奇诺比奥队长 1.1.0），压缩件的指令集 nx_unpack --inspect 报不准
                                             （10-29 马车8 xcz 本体 + 3.0.0 补丁都报 aarch32，实为 64 位），一律走解包、按解出的 main.npdm 判（one_game.sh 记「不支持：32位」）。
                                             清单读不出的文件每个单独排一款（键 f_<名字哈希>），照样解包，解包失败由 one_game.sh 归类（维护者 10-26：解包失败是我方缺陷）；
                                             例外是原件结构坏（src_bad），记「源文件坏」：
                                             · .xci 头（0x100 或带 key area 的 0x1100）没有 HEAD = 不是 XCI 结构，实际大小 < 头里有效数据结束地址
                                               （0x118，单位 0x200）× 0x200 = 截断（10-29：宝可梦朱本体应有 6.63 GB 实际 1.47 GB；修剪过的转储剪到最后一个有效字节、
                                               最后一个单位只留一部分，逆转裁判456 比结束地址 × 0x200 多 384 字节，算完整）
                                             · .nsp / .nsz 都是 PFS0 容器（NSZ 只是条目里换成压缩的 NCZ，外壳结构一样）：头里写着文件数 n（@4）、字符串表长 s（@8），
                                               条目从 0x10 起每条 0x18（偏移 u64 / 大小 u64 / 名字偏移 u32 / 保留 u32）；应有大小 = 数据区起点 0x10 + 0x18×n + s +
                                               max(偏移 + 大小)，实际更小 = 截断（10-29 普查：#934 前截断的 NSP 走到解包被记「解包失败」，算成我方缺陷）；
                                               头里没有 PFS0 = 不是 NSP 结构；实际更大不算坏（末尾填充 / 对齐 / 转储修剪都会多）。看不出坏（头不足 0x10、文件数 0）不判，交给解包
  census.py row <键> <名称> <版本> <机器> <源GB> <结果.tsv> [<解包秒>]   one_game.sh 结果.tsv 末行 → 总表一行（打到标准输出）
  census.py native60 <批次目录> <仓库>       原生 60 候选（60 帧关、请求间隔 1、实测 ≥ 58 帧）写进 <仓库>/docs/名单_60帧能力覆盖/<程序号>.tsv（L1 / L2 不需要），已有的不重复
  census.py dock <批次目录> <仓库>    掌机档点触卡页、主机档复跑进局的款写进 <仓库>/docs/名单_进局档位.tsv，已有不重复
  census.py direct_defects <批次目录> <仓库>  直连缺陷表（直连单轨口径下没过的款：失败 / 退到通用 / 没进局）→ <批次目录>/直连缺陷表.tsv
  census.py widen_cliff <批次目录> <仓库>    宽屏两侧缺渲染（进局截图 16:9 边界断崖 ≥ 0.5）写进 <仓库>/docs/名单_能力强信号/<程序号>.tsv（widen 宽屏画面坏），已有不重复
  census.py sum <批次目录>                  三率 + 逐类失败 → <批次>/汇总.md，并打三率 + 能力生效率（满屏 / 60 帧 / 无清单局数）两行
  census.py rejudge <批次目录>              判据改了（tools/quicktest/verdict.py）不重跑局：按拉回的 <批次>/work/<键>/r/logs/<键>/ 日志拼局目录，
                                             重算结论 / 第一个失败点 / 崩溃 / 进局等列与「不卡」（卡死判定 + 卡顿读数）、一次成功，打改了几行
  census.py redo <批次目录> <键,…> <原因>   根修合入后重跑：这几款改记「未判」、第一个失败点「重排：<原因>」，下次 census.sh 启动时 plan 重排
                                             （10-29 Minecraft 出包被改写器 hlt 缺口挡住，原生层修好后重跑）
三率口径（10-28 维护者：普查三率 解包 / 进局 / 首 5 分钟 0 崩）：
  解包率 = 解包成功 / 尝试解包（不含解出来是 32 位的、源文件坏、未判）
  进局率 = 进局 / 普查款数（不含源文件坏、未判、进局列「未判」——没截图或判官失败、测不出；32 位算没进局）。
           进局 = AI 看这局最后几张截图（到 MARK + 视觉测试员最后两张 + last_vision）任一张「已在可玩的游戏画面」（entry_ai，维护者 10-29 06:2x：
           推摇杆看位移认不出进局——失落城堡 / ShakesOnAPlane 截图在可玩场景、位移 0）；位移探测（one_game 末列）只留在 host.log 作诊断
  0 崩率 = 局内 0 崩 / 起了 Mac 局的款（局时长 census.sh --run-s，缺省 300 秒；到 MARK 后接着玩到局时长，见 one_game.sh）；
           到点收局时才崩（崩溃列「收局」，verdict.py）算局内 0 崩，汇总单列条数
  未判 = 局没起（独占局槽排队超时、远端失败）：基础设施问题，不进分母、单列条数，重跑 census.sh 会补
一次成功（11-02 16:3x 维护者：普查目标 = 原生帧率 + 原生画幅一次成功；11-03 08:3x 维护者 改口径：Mac 普查只判出包、进局、不崩、不卡死，
  卡顿 / 帧率 / 能耗留给真机实测，也不再因本机负载判「受扰作废」）：四件全满足才算——
  出包一次成功（第一个失败点不是 解包 / 出包 / 不支持 / 直连库没出）、进局（自动玩家判出，或 维护者 手测 手测结果.tsv 记 是）、
  不崩（结论「通过」：局内跑满时长没崩）、不卡死（「不卡」列以「未卡死」开头）。进局 否 / 未判 而其余三件都过 → 记「待手测」（进手测队列）。
  卡死 = 帧进度停住、到收局都没再走：最后一帧到收局 ≥ HANG_S（60）秒没有新帧（收局时刻 = host.log 最后一条 Ryujinx 时间戳行，
    宿主收不了局被 run_mac.sh 墙钟杀时取「超墙钟 N 秒」；最后一帧时刻 = 「首帧上屏」行前最近的时间戳 + frames.tsv 帧间隔累加，只会估早、不会估晚）。
    60 秒与自动玩家「局内段出图停 60 秒，提前收局」同口径。只看帧最后有没有再走、不看快慢：停了又走回来的是慢（负载下编管线 / 存档提交拖长，
    11-02 Ori 首遇 110 条管线一帧 62 秒、泡泡龙4 盘忙存档提交 18 秒，之后照常出帧），只进卡顿读数、不算卡死。
  「不卡」列另记卡顿读数（给真机参考，不进过不过）：帧时间 > 2 × max(锁帧间隔, 实测中位帧时间) 记一次卡顿，取 MARK 之后（没 MARK 取局末）最多 1200 帧，
    「卡顿 x%｜最长 y ms｜锁 L｜实测 F」；取不到帧节拍或不足 300 帧只记卡死与否。
  旧表行（11-03 前「过 / 不过 / 作废」开头）没有卡死判定，按未卡死算；census.py rejudge 按拉回的局日志重算这一列。
逐类：第一个失败点去掉地址 / 载荷等变量（「稳定崩溃：客体代码（main+0x…）」→「稳定崩溃：客体代码」），起来了没到 MARK 记「没进局」；
  每类给属主（按失败层：解包 = 泛化线，出包 / 跑局机 = 出包线，客体代码 / Break / 运行时异常 = 原生线，首帧 / GPU / 直连 = 画面线）。
单测：tests/census_test.sh"""
import collections, csv, glob, hashlib, json, os, re, shutil, struct, subprocess, sys
from datetime import date, datetime

EXTS = ('.nsp', '.xci', '.nsz', '.xcz')
QH = ['键', '名称', '版本', '本体文件', '全部文件', '字节', '压缩件', '指令集']
TH = ['键', '名称', '版本', '机器', '源GB', '款', '结论', '第一个失败点', '解包秒', '出包秒', 'Mac局秒', '首帧', '首帧毫秒', '帧数',
      '图形模式', '直连异常', '崩溃', '红行前3', '进局', '满屏', '60帧', '强信号', '日期', '归约变体', '原生帧率', '首遇现建', '宽屏断崖', '口径', '系统版本', '直连编不过', '接口缺口', '满屏能力', '原生档', '手测', '不卡', '一次成功', '补丁包修复']   # 新列只往日期后加：旧表头的总表续跑追加新行时不错位
OWNERS = [('解包', '泛化线'), ('不支持', '-'), ('源文件坏', '-'), ('局没起', '出包线'), ('直连缺口', '画面线'), ('出包', '出包线'),
          ('首帧', '画面线'), ('直连异常', '画面线'), ('没走直连', '画面线'), ('直连图形层', '画面线'), ('GPU', '画面线'), ('没进局', '泛化线'), ('疑似进局', '泛化线'), ('进局未判', '出包线'), ('环境', '环境（复跑再判）'), ('旧读数待重测', '环境（复跑再判）')]
# 七条线（10-30 维护者）：画面线 / 原生线 / 出包线 / 列车线 / 泛化线（原「能力与泛化线」）/ 真机线 / 众包线；原「基础设施线」按问题落点拆到出包线（出包、跑局机：局没起、视觉判官密钥）或列车线（门禁）


def tsv(p):
    if not os.path.exists(p):
        return []
    with open(p, encoding='utf-8') as f:
        rows = [l.rstrip('\n').split('\t') for l in f if l.strip()]
    return [dict(zip(rows[0], r)) for r in rows[1:]] if rows else []


def write_tsv(p, head, rows):   # 先写同目录临时文件再改名：普查各跑局道每款跑完都重出缺陷表，并发写不能留半截表给读的人
    t = f'{p}.{os.getpid()}.tmp'
    with open(t, 'w', encoding='utf-8') as f:
        f.write('\t'.join(head) + '\n')
        f.writelines('\t'.join(str(r.get(k, '-')) for k in head) + '\n' for r in rows)
    os.replace(t, p)


def nxu(repo):
    """nx_unpack 路径，并把 pack/srcs.sh 入口补齐的 .NET 环境（DOTNET_ROOT / PATH）带进本进程：盘点直接起 nx_unpack 启动壳，
    不经 srcs.sh 的话 launchctl submit 这类只有系统 PATH 的环境下全部退出 131（11-05 after_r2 v4：367 个文件 0 个读出）"""
    out = subprocess.run(['bash', '-c', 'source pack/srcs.sh > /dev/null 2>&1; printf "%s\\n%s\\n%s\\n" "$SRC_N" "${DOTNET_ROOT:-}" "$PATH"'],
                         cwd=repo, capture_output=True, text=True).stdout.split('\n')
    if len(out) >= 3:
        if out[1] and not os.environ.get('DOTNET_ROOT'): os.environ['DOTNET_ROOT'] = out[1]
        if out[2]: os.environ['PATH'] = out[2]
    return out[0].strip()


def seed_inventory(b, inv):
    """新批次不重读上一批已读过的包（10-31 维护者：只跑 1 款 0.4 GB 的 Slay 却先盘点 406 个文件约 40 分钟）：
    本批 inspect.tsv 还没有时，从同级各批的盘点里逐个文件取最新一份有效行（rc=0、路径 + 大小相同、文件修改时间不晚于那份盘点、清单文件在）沿用，变了的留给后面照常重读。
    逐文件取、不只看最新一批（11-05：最新一批恰是没 .NET 运行时的坏批，367 个文件 0 个读出，v5 沿用 0 个、全量重探 8 分钟）。
    候选另含运行区普查目录（11-02 运维线：各线验证批次放 2T_B 的 s2arm_run_b/census，同级没有盘点，三四批同时整盘直读机械盘，普查拷件掉到 5 MB/s）"""
    dst = os.path.join(inv, 'inspect.tsv')
    if os.path.exists(dst): return
    me = os.path.realpath(b); run = os.path.join(os.environ.get('S2A_RUN_ROOT', os.path.expanduser('~/.s2arm/run')), 's2arm', 'census')
    sibs = {os.path.realpath(p) for d in (os.path.dirname(os.path.abspath(b)), run) for p in glob.glob(os.path.join(d, '*', 'inventory', 'inspect.tsv'))}
    sibs = [p for p in sibs if os.path.dirname(os.path.dirname(p)) != me]
    if not sibs: return
    best = {}   # 文件 → (盘点时刻, 行, 那份盘点目录)
    for src in sibs:
        try: stamp = os.path.getmtime(src); rows = tsv(src)
        except (OSError, ValueError, KeyError): continue
        for r in rows:
            f = r.get('文件', '')
            if r.get('rc') != '0' or (f in best and best[f][0] >= stamp): continue
            try: ok = os.path.getsize(f) == int(r['字节']) and os.path.getmtime(f) <= stamp
            except (OSError, ValueError, KeyError): ok = False
            if ok and os.path.exists(os.path.join(os.path.dirname(src), r['清单'])): best[f] = (stamp, r, os.path.dirname(src))
    rows = []
    for f in sorted(best):
        _, r, d = best[f]; shutil.copyfile(os.path.join(d, r['清单']), os.path.join(inv, r['清单'])); rows.append(r)
    write_tsv(dst, ['文件', '字节', 'rc', '清单'], rows)
    print(f'盘点沿用 {len({best[f][2] for f in best})} 批盘点里的 {len(rows)} 个文件（路径 + 大小 + 修改时间没变，逐文件取最新）')


def src_files(src):
    """原件文件清单。src = @<索引表>（11-04 资料盘：按表取路径，不扫目录；表头 程序号 款名 版本 角色 路径 字节 sha256，sha256 为「-」的整目录行不算原件文件）
    或 冒号分隔的源目录（贡献者自有原件，列一层）。"""
    if src.startswith('@'):
        return sorted(r['路径'] for r in tsv(src[1:]) if r.get('sha256', '-') != '-' and r['路径'].lower().endswith(EXTS))
    return sorted(os.path.join(d, n) for d in src.split(':') for n in os.listdir(d) if n.lower().endswith(EXTS) and not n.startswith('.'))   # 多个源目录用 : 隔开（10-29 茶杯头补件在家目录盘）


def inventory(src, b, repo):
    inv = os.path.join(b, 'inventory'); os.makedirs(inv, exist_ok=True)
    seed_inventory(b, inv)
    cache = {r['文件']: r for r in tsv(os.path.join(inv, 'inspect.tsv')) if r['rc'] == '0'}
    files = src_files(src)
    tool, keys = nxu(repo), os.path.expanduser(os.environ.get('S2A_KEYS', '~/.switch/prod.keys'))
    rows = []
    for f in files:
        if f in cache:
            rows.append(cache[f]); continue
        j = os.path.join(inv, hashlib.sha1(f.encode()).hexdigest()[:16] + '.json')
        try:
            r = subprocess.run([tool, keys, '--inspect', f], capture_output=True, timeout=300)
            rc, out, err = r.returncode, r.stdout, r.stderr
        except (OSError, subprocess.TimeoutExpired) as e:
            rc, out, err = 99, b'', str(e).encode()
        open(j, 'wb').write(out if rc == 0 else err)
        rows.append({'文件': f, '字节': str(os.path.getsize(f)), 'rc': str(rc), '清单': os.path.basename(j)})
    write_tsv(os.path.join(inv, 'inspect.tsv'), ['文件', '字节', 'rc', '清单'], rows)
    bad = sum(r['rc'] != '0' for r in rows)
    print(f'盘点 {len(rows)} 个文件（读出 {len(rows) - bad}、读不出 {bad}，其中这次新读 {len(rows) - len(cache)} 个）')
    # --inspect 退出码（pack/nx_unpack/Inspect.cs）：0 读出、3 容器读不出（按内容的结论，照旧单列一款去解包）；其余（131 没有 .NET 运行时、
    #   126 / 127 起不来、128+ 被杀、2 用法错、99 本处超时 / 起不了）= 工具没跑成，是机器原因：不能当「读不出」排成游戏，停批报红（读出的已缓存，修好重跑很快）
    mach = [r for r in rows if r['rc'] not in ('0', '3')]
    for r in mach[:5]:
        try: why = ' '.join(l for l in open(os.path.join(inv, r['清单']), encoding='utf-8', errors='replace').read().splitlines() if l.strip())[-240:]
        except OSError: why = ''
        print(f'【红】机器原因：盘点 nx_unpack --inspect 退出 {r["rc"]}，不是游戏的问题：{why}（{r["文件"]}）')
    if mach:
        print(f'【红】盘点有 {len(mach)} 个文件工具没跑成（机器原因），停批：修好环境重跑（读出的已缓存）')
        return 1
    return 0


def groups(b):
    inv = os.path.join(b, 'inventory')
    g = collections.defaultdict(lambda: {'files': set(), 'name': '', 'ver': '', 'upd': -1, 'base': '', 'isa': ''})
    loose = []
    for r in tsv(os.path.join(inv, 'inspect.tsv')):
        if r['rc'] != '0':
            loose.append(r); continue
        for p in json.load(open(os.path.join(inv, r['清单']), encoding='utf-8'))['packages']:
            x = g[p['baseId']]; x['files'].add(r['文件'])
            if p['type'] == 'base':
                x['name'], x['base'], x['isa'] = p['name'], r['文件'], p.get('guestIsa', '')
                x['ver'] = x['ver'] or p.get('display', '')
            elif p['type'] == 'update' and p['version'] > x['upd']:
                x['upd'], x['ver'] = p['version'], p.get('display', ''); x['name'] = x['name'] or p['name']
            elif p['type'] == 'dlc' and not x['name']:
                x['name'] = p['name']
    out = []
    for k, x in g.items():
        if not x['base']:
            continue   # 只有补丁 / DLC、没有本体：不是一款
        fs = sorted(x['files'])
        out.append({'键': k, '名称': x['name'] or '-', '版本': x['ver'] or '-', '本体文件': x['base'], '全部文件': '|'.join(fs),
                    '字节': str(sum(os.path.getsize(f) for f in fs)), '压缩件': str(sum(f.lower().endswith(('.nsz', '.xcz')) for f in fs)),
                    '指令集': x['isa'] or '-'})
    for r in loose:   # 清单读不出：单独一款，照样走解包（解包失败 = 我方缺陷，由 one_game 归类）
        n = os.path.basename(r['文件'])
        out.append({'键': 'f_' + hashlib.sha1(n.encode()).hexdigest()[:12], '名称': n, '版本': '-', '本体文件': r['文件'], '全部文件': r['文件'],
                    '字节': r['字节'], '压缩件': str(int(n.lower().endswith(('.nsz', '.xcz')))), '指令集': '?'})
    return out


def pfs0_bad(f):
    """PFS0（NSP / NSZ）实际大小 < 应有大小 = 截断；头里没有 PFS0 = 不是 NSP 结构；头不足 0x10 或文件数 0 看不出坏，返回 None。
    应有大小 = 数据区起点（0x10 + 0x18×n + 字符串表长）+ max(条目偏移 + 条目大小)；实际更大不算坏（末尾填充 / 对齐）"""
    try:
        size = os.path.getsize(f)
        with open(f, 'rb') as fh:
            h = fh.read(0x10)
            if len(h) < 0x10:
                return None
            if h[:4] != b'PFS0':
                return '源文件坏：不是 NSP 结构（头里没有 PFS0）'
            n, stsz = struct.unpack_from('<II', h, 4)
            if not n:   # 没有条目：没有内容可比，交给解包
                return None
            ent = fh.read(min(0x18 * n, size - 0x10))   # 条目表本身可能被截断：只读文件里有的部分，缺的部分算在应有大小里
    except OSError:
        return None
    data = 0x10 + 0x18 * n + stsz   # 数据区起点
    want = data
    for i in range(len(ent) // 0x18):
        off, sz = struct.unpack_from('<QQ', ent, 0x18 * i)
        want = max(want, data + off + sz)
    return None if size >= want else f'源文件坏：截断（应有 {want / 2**30:.2f} GB，实际 {size / 2**30:.2f} GB）'


def src_bad(f):
    """原件结构坏的原因（不是我方读不出）；看不出坏返回 None。
    .xci：头里有魔数与有效数据结束地址；.nsp / .nsz：PFS0 头里写着每个条目的偏移与大小，能算出应有大小"""
    if f.lower().endswith(('.nsp', '.nsz')):
        return pfs0_bad(f)
    if not f.lower().endswith('.xci'):
        return None
    try:
        with open(f, 'rb') as fh:
            h = fh.read(0x1200)
        size = os.path.getsize(f)
    except OSError:
        return None
    for base in (0, 0x1000):   # 带 key area 的整卡转储：头在 0x1100
        if h[base + 0x100:base + 0x104] == b'HEAD':
            want = base + struct.unpack_from('<I', h, base + 0x118)[0] * 0x200
            return f'源文件坏：截断（应有 {want / 2**30:.2f} GB，实际 {size / 2**30:.2f} GB）' if size < want else None
    return '源文件坏：不是 XCI 结构（头里没有 HEAD）' if size >= 0x200 else None


def plan(b):
    t = os.path.join(b, '总表.tsv')
    done = {r['键'] for r in tsv(t) if r.get('结论') != '未判'}
    keep = [r for r in tsv(t) if r.get('结论') != '未判']   # 未判（局没起）重排
    q, pre = [], []
    for r in groups(b):
        if r['键'] in done:
            continue
        gb = f"{int(r['字节']) / 2 ** 30:.1f}"
        base = {'键': r['键'], '名称': r['名称'], '版本': r['版本'], '机器': '不起局', '源GB': gb, '款': '-', '日期': date.today().isoformat()}
        bad = '源文件坏：0 字节' if r['字节'] == '0' else src_bad(r['本体文件'])
        if bad:
            pre.append({**base, '结论': '源文件坏', '口径': '源文件坏', '第一个失败点': bad})
        else:
            q.append(r)
    q.sort(key=lambda r: int(r['字节']))
    write_tsv(os.path.join(b, 'queue.tsv'), QH, q)
    write_tsv(t, TH, keep + pre)
    print(f'排队 {len(q)} 款（{sum(int(r["字节"]) for r in q) / 1e12:.2f} TB），直接记表 {len(pre)} 行，总表已有 {len(keep)} 行')


STUB = '跑局机缺链接桩（出包机与跑局机 GPU / 系统版本不同，直连读数不作数）'


def stub_missing(r, lg):
    """跑局机缺直连链接桩时记的「直连异常」是普查流水线的缺陷、不是游戏的（10-29 画面线：本机 g17s / macOS 26 出包、Spare-host g15g / macOS 27 跑局，
    host.log「linked stand-ins: no stub archive …」，Sayonara 第 43 帧停 45 秒被记直连异常；Spare-host 自己出包同款 0 停住）→ 改记未判，修好重跑。
    不论结论（10-29 c1029c：送小羊回家缺桩照样「通过」，原先只查失败 + 直连异常而漏标）：缺桩的局不是发布配置，过也不作数；补跑局 host_2.log 同样看"""
    for n in ('host.log', 'host_2.log'):
        try:
            if 'no stub archive' in open(os.path.join(lg, n), encoding='utf-8', errors='replace').read(): return True
        except OSError: pass
    return False


MACHINE = '机器原因：出包开工时盘不够（不是游戏的问题，下次启动重排）'
# 出包失败行自己的红行属于环境 / 工具缺件或出包进程被外部收掉（11-05 维护者：Windows 出包机普查 AM2R「OpenGL 款要 glslangValidator」、勇者XI S「set DM_OODLE_HOST」、
#   01009B500007C000 轻阶段 rc=75、被另一线 pkill 收掉的 rc=143、无人深空Windows 出包机 [WinError 31] 都记成了游戏「失败」；WinError 只在Windows 出包机出包道出现，归Windows 出包机环境）。只看本行的第一个失败点 + 红行前3（决定性的那行），不扫全目录日志（日志里提到环境的旁支不算）
PACK_ENV_RE = re.compile(r'环境未就绪|环境缺件|缺工具|要 glslangValidator|brew install|DM_OODLE_HOST|rc=75\b|退出 75\b|被外部收掉|WinError')


def pack_machine(r, lg):
    """出包失败是机器自己的原因 → 返回写进「第一个失败点」的机器原因说明（改记未判，下次重排）；不是 = None。
    ① 盘不够（10-29 JDM Racing：本机可用 69 G < 出包闸门 130 G，暂停超 3600 秒放弃，记成「出包：刷新其它」）：lg = 这款的出包日志目录（one_game 的 <输出>/logs/<键>/），
       看各 .red / pack_logs / oneclick.log 里有没有盘不够的报法：出包开工判盘（tools/disk_low.sh disk_need：「…产物根所在卷…只剩 N GB」）或「磁盘不足」（disk_low）
    ② 环境 / 工具缺件、出包进程被外部收掉（PACK_ENV_RE，只看本行文字）"""
    if not (r.get('结论') == '失败' and r.get('第一个失败点', '').startswith(('出包', '解包'))): return None
    fp = r.get('第一个失败点', '')
    if PACK_ENV_RE.search(fp + ' ' + (r.get('红行前3') or '')): return f'机器原因：{fp}'[:200]
    if not fp.startswith('出包'): return None
    for d, _, fs in os.walk(lg):
        for f in fs:
            try:
                t = open(os.path.join(d, f), encoding='utf-8', errors='replace').read()
                if '产物根所在卷' in t or '磁盘不足' in t: return MACHINE
            except OSError: pass
    return None


def entry_ai(lg, judge=None):
    """拉回的日志目录 → (是 / 否 / 未判, 说明)。截图按名字取：ap_mark + run*/vision/vNN 最后两张 + last_vision（没有视觉截图时补 ap_mid / ap_end），
    内容去重、最多 4 张，交快检同一个 AI 判官（tools/quality_check.py ai_judge，缓存共用）；没截图 / 判官失败 = 未判"""
    if not os.path.isdir(lg): return '未判', '没有日志目录'
    # 自动玩家已打 MARK（模型说可操控 + 每帧绘制 / 渲染遍数到场景量级，ap_summary.json marked）→ 是，不再交判官；没到 MARK 才交 AI 判官看截图
    for sp in (os.path.join(lg, 'ap_summary.json'), os.path.join(lg, 'run', 'ap_summary.json'), os.path.join(lg, 'run2', 'ap_summary.json')):
        try: sj = json.load(open(sp, encoding='utf-8'))
        except (OSError, ValueError): continue
        if sj.get('marked'): return '是', f'自动玩家 MARK：模型说可操控 + 读数到场景量级（首帧后 {sj.get("first_frame_to_mark_s", -1)} 秒、按键 {sj.get("presses", 0)} 下、模型 {sj.get("vision_asks", 0)} 次）'
    # ap_summary.json 没拉回来（11-02 c1102_v2_air 01007E3006DDA000：04:42 本机重启前收局，局目录里没有它，进局落到判官、判官失败记「未判」）：
    #   打没打 MARK 的原始事实在 host.log——自动玩家写「S2A 标记 MARK：帧 N」与「导航 → 局内段（依据：…）」两行，都在就算进局
    try: hl = open(os.path.join(lg, 'host.log'), encoding='utf-8', errors='replace').read()
    except OSError: hl = ''
    mk = re.search(r'S2A 标记 MARK：帧 (\d+)', hl)
    if mk and '导航 → 局内段' in hl: return '是', f'自动玩家 MARK（host.log：帧 {mk.group(1)}；ap_summary.json 没拉回）'
    f = lambda *n: [os.path.join(lg, x) for x in n if os.path.exists(os.path.join(lg, x))]
    vis = sorted((os.path.join(d, x) for d in (os.path.join(lg, 'run', 'vision'), os.path.join(lg, 'run2', 'vision')) if os.path.isdir(d)
                  for x in os.listdir(d) if re.fullmatch(r'v\d+\.png', x)), key=lambda p: int(re.sub(r'\D', '', os.path.basename(p))))
    cand = f('ap_mark.png') + vis[-2:] + f('last_vision.png') + ([] if vis else f('ap_mid.png', 'ap_end.png'))
    pick, seen = [], set()
    for p in cand:
        h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
        if h not in seen: seen.add(h); pick.append(p)
    pick = pick[-4:]
    if not pick: return '未判', '没有截图'
    if judge is None:
        sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__)))); from quality_check import ai_judge as judge
    try: ans = judge(pick)
    except Exception as e: return '未判', f'判官失败：{e}'
    hit = [os.path.basename(p) for p, a in zip(pick, ans) if a.get('游戏画面') == '是']
    return ('是' if hit else '否'), f'AI 看 {len(pick)} 张，游戏画面 {",".join(hit) or "无"}'


RED_RE = re.compile(r'归约变体：程序号 ([0-9A-Fa-f]{16}) 着色器 (\S+) (?:后台编|同步现编)(完成|失败)\s*([0-9.]+)?(?: ?ms)?')   # 宿主格式（nvn_mtl.m，wire-c/se-want）：<后台编|同步现编><完成|失败> <x.y> ms[：<原因>]


def reduce_state(lg):
    """真绑归约变体（10-29 画面线 #800 验收要的）：host.log「[s2a] 归约变体：程序号 <16 位> 着色器 <键> <后台编|同步现编><完成|失败> <毫秒> ms[：<原因>]」，
    按着色器键去重计支数、取最大毫秒（失败行多半没有毫秒），失败另计 → 「3 支 / 最大 42.1 ms」「…（失败 1）」；一行都没有 = 空串"""
    try: t = open(os.path.join(lg, 'host.log'), encoding='utf-8', errors='replace').read()
    except OSError: return ''
    keys, fail, ms = set(), set(), []
    for pid, k, what, v in RED_RE.findall(t):   # 最大毫秒只取编成的（失败的耗时不代表绑上的变体）
        keys.add(k)
        if what == '失败': fail.add(k)
        elif v: ms.append(float(v))
    if not keys: return ''
    return f'{len(keys)} 支 / 最大 ' + (f'{max(ms):.1f} ms' if ms else '-') + (f'（失败 {len(fail)}）' if fail else '')


NATIVE60_MIN = 58.0   # 原生 60 判据：游戏自己请求交换间隔 1，且 60 帧关着时局末实测 ≥ 这个帧率（大航海时代Ⅳ 请求 1 却实测 30：引擎内部另限帧，光看间隔会误判）


TIMING = re.compile(r'timing up to frame (\d+): frame time p50 ([0-9.]+)')
AB_IN, AB_OUT = ('逻辑速度同局 A/B 放开', '逻辑速度同局 A/B 回游戏原帧率'), '逻辑速度同局 A/B 测完'   # 宿主帧率表行（runtime/src/fps.c s2a_fps_ab_set）


def steady_timing(hl):
    """timing 窗口 [(帧号, p50)]，去掉逻辑速度同局 A/B 段里的（11-04 提前收局：A/B 切 60 帧开 / 关、不是照常帧率；原先局内段跑满 300 秒，
    照常窗口占多数压住了 A/B 窗口，提前收局后 A/B 段占 MARK 后窗口的一半以上，60 帧关的款中位会被开段拉成 60）。A/B 开始行之后、测完行之后第一窗（跨进照常）都不算"""
    out, ab, tail = [], False, False
    for line in hl.splitlines():
        if any(k in line for k in AB_IN): ab = True; continue
        if AB_OUT in line: ab, tail = False, True; continue
        m = TIMING.search(line)
        if not m or float(m.group(2)) <= 0: continue
        if ab or tail: tail = False; continue
        out.append((int(m.group(1)), float(m.group(2))))
    return out
L2_MAX = 34.0   # L2 卡点（10-30 grokbot 按引擎 60 帧 S 级②）：局内实测 ≤ 这个帧率（p50 ≥ 约 30 ms）且 60 帧开或游戏请求间隔 1 = 引擎自己限帧


def mark_frame(lg):
    """自动玩家打 MARK 的帧号（ap_summary.json marked + mark_frame）；没到 MARK / 没小结 = None"""
    try: a = json.load(open(os.path.join(lg, 'ap_summary.json'), encoding='utf-8'))
    except (OSError, ValueError): return None
    return int(a.get('mark_frame') or 0) if a.get('marked') is True else None


def native_rate(lg, entered=False):
    """局内帧率（10-30 grokbot S 级③：只按 MARK 之后的局内窗口判——无双深渊 c1029c 没到 MARK，局末 54.2 帧是菜单，Warehouse 却列它锁 30）：
    host.log 帧节拍行（tools/game_fps.target）给出游戏请求的间隔；MARK 之后整段落在里面的 timing 窗口（「timing up to frame N … frame time p50」，
    每窗 300 帧，直连局每局都有；逻辑速度同局 A/B 段里的窗口不算，见 steady_timing）p50 的中位 → 帧率；没有 timing 行（通用局）退到局目录 run/frames.tsv（没有就 run2/、本目录）MARK 之后最多 1200 帧的平均。
    普查里自动玩家打 MARK 的少（c1029c 13 份小结 0 份 marked），「进局」列是 AI 看收尾几张截图判的：没 MARK 但 entered（进局 = 是）时取局末
    最后 2 个窗口（600 帧，紧挨 AI 判为游戏画面的收尾截图）/ frames.tsv 最后 600 帧。
    →「60.0（请求间隔 1）」；没 MARK 又没进局、取不到帧节拍、窗口不足 300 帧 = 空串。负载高的跑局机实测偏低只会漏判原生 60、不会误判"""
    try: hl = open(os.path.join(lg, 'host.log'), encoding='utf-8', errors='replace').read()
    except OSError: return ''
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__)))); from game_fps import target
    fps, _, ok = target(hl)
    mf = mark_frame(lg)
    if not ok or (mf is None and not entered): return ''
    k = round(60 / fps); tm = steady_timing(hl)
    ws = sorted(p for n, p in (tm[-2:] if mf is None else [x for x in tm if x[0] - 300 >= mf]))
    if ws: return f'{1000 / ws[len(ws) // 2]:.1f}（请求间隔 {k}）'
    for d in ('run', 'run2', '.'):
        f = os.path.join(lg, d, 'frames.tsv')
        if not os.path.exists(f): continue
        import ab_span; sp = ab_span.spans(hl)   # A/B 段（改出帧状态）里的帧不算，同 steady_timing
        rs = [r for r in csv.DictReader(open(f, encoding='utf-8', errors='replace'), delimiter='\t') if (r.get('wall_us') or '').isdigit() and int(r.get('frame') or 0) > (mf or 0) and ab_span.keep(int(r.get('frame') or 0), sp)]
        col = 'disp_us' if any((r.get('disp_us') or '0').isdigit() and int(r.get('disp_us') or 0) > 0 for r in rs) else 'wall_us'
        w = [int(r[col]) for r in rs if (r.get(col) or '').isdigit() and int(r[col]) > 0][-1200 if mf is not None else -600:]
        if len(w) >= 300: return f'{len(w) * 1e6 / sum(w):.1f}（请求间隔 {k}）'
    return ''


def l2_hit(r):   # 总表一行 → L2 卡点：局内 ≤ L2_MAX 帧，且 60 帧开（第一层已放开）或游戏自己请求间隔 1 —— 卡在引擎限帧（第二层）
    m = re.match(r'([0-9.]+)（请求间隔 (\d+)）', r.get('原生帧率') or '')
    return bool(m) and float(m.group(1)) <= L2_MAX and (r.get('60帧') == '开' or m.group(2) == '1')


def native60_hit(r):   # 总表一行 → 是不是原生 60：60 帧关、请求间隔 1、实测 ≥ NATIVE60_MIN
    m = re.match(r'([0-9.]+)（请求间隔 1）', r.get('原生帧率') or '')
    return r.get('60帧') == '关' and bool(m) and float(m.group(1)) >= NATIVE60_MIN


FIRST_RE = re.compile(r'首遇现建：(?:MARK ?|预热)后提交线程现建管线 (\d+) 条，最长 ([0-9.]+) ms，合计 ([0-9.]+) ms')
FRAME_MS = 1000 / 60   # 首遇超一帧：最长一条现建 > 16.7 ms（60 帧一帧）


def first_build(lg):
    """首遇现建（10-29 画面线：链接预编删掉、改用读数监控首遇）：宿主收局行「首遇现建：MARK 后（或 预热后）提交线程现建管线 <N> 条，最长 <x> ms，合计 <y> ms」
    →「12 条 / 最长 34.5 ms」（取最后一行：补跑局在后）；没有这行 = 空串"""
    try: t = open(os.path.join(lg, 'host.log'), encoding='utf-8', errors='replace').read()
    except OSError: return ''
    m = FIRST_RE.findall(t)
    return f'{m[-1][0]} 条 / 最长 {float(m[-1][1]):.1f} ms' if m else ''


def first_slow(r):   # 总表一行 → 首遇最长一条超一帧
    m = re.match(r'\d+ 条 / 最长 ([0-9.]+) ms', r.get('首遇现建') or '')
    return bool(m) and float(m.group(1)) > FRAME_MS


def sys_version(lg):
    """跑局机的系统与芯片（11-01 维护者：同一份着色器异度3 在 M3 / macOS 27 编译器内部错误、M5 / macOS 26 正常，按版本归因）：
    host.log「机器：系统 <版本>，芯片 <名>」→「27.0 / Apple M3」；旧宿主没有这行，只取「Metal device <名>」→「? / Apple M3」；都没有 = 空串"""
    try: t = open(os.path.join(lg, 'host.log'), encoding='utf-8', errors='replace').read()
    except OSError: return ''
    m = re.search(r'机器：系统 (\S+)，芯片 ([^\n]+)', t)
    if m: return f'{m.group(1)} / {m.group(2).strip()}'
    m = re.search(r'Metal device ([^\n]+)', t)
    return f'? / {m.group(1).strip()}' if m else ''


def widen_cliff(lg):
    """宽屏两侧缺渲染（10-30 #996 + 画面线）：进局截图 ap_mark.png 的 16:9 边界断崖（tools/widen_cliff.py，纯像素规则）→「0.84」；没加宽 / 没截图 = 空串"""
    p = os.path.join(lg, 'ap_mark.png')
    if not os.path.exists(p): return ''
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__)))); import widen_cliff as wc
    c = wc.cliff(p); return '' if c is None else f'{c:.2f}'


def cliff_bad(r):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__)))); import widen_cliff as wc
    try: return r.get('满屏能力') == '开' and float(r.get('宽屏断崖') or 'x') >= wc.CLIFF_BAD
    except ValueError: return False


def caps_state(lg):
    """这局实际生效的能力（10-29 维护者：普查按发布口径全能力跑，总表按每款实际生效的状态记）：读 host.log——
    满屏：宽屏名单门的结论「宽屏：本款在宽屏已验证名单…」= 开 /「…不在宽屏已验证名单…」= 关（runtime/src/widen.c widen_gate；没走到门 = -）；
    60帧：包内能力清单行「能力清单：60 帧开 / 关」（runtime/src/caps.c），帧率表起局行说关就记关（runtime/src/fps.c）；
    强信号：清单里写 0 的能力连同原因（gen_caps：「强信号：…」），都开 = -；
    host.log 没有对应的「能力清单：…」行 = 无清单（这局没按发布配置跑，判据红，summarize 单列局数）"""
    try: t = open(os.path.join(lg, 'host.log'), encoding='utf-8', errors='replace').read()
    except OSError: return {}
    # 新写法「宽屏：不放 / 放开（来源：…）」（10-30 #996 分开记来源）；旧日志「本款（不）在宽屏已验证名单」照认
    w = '关' if '宽屏：不放（来源' in t or '本款不在宽屏已验证名单' in t else '开' if '宽屏：放开（来源' in t or '本款在宽屏已验证名单' in t else '-'
    if '能力清单：满屏' not in t: w = '无清单'
    m = re.search(r'能力清单：60 帧(开|关)', t); f = m.group(1) if m else '无清单'
    if re.search(r'帧率表 \S+：60 帧关', t): f = '关'
    why = [f'{n}：{r.strip()}' for n, r in re.findall(r'能力清单：(满屏|60 帧)关（[^）]*）原因：([^\n]*)', t)]
    return {'满屏': fs_state(lg)[0], '满屏能力': w, '60帧': f, '强信号': '；'.join(why).replace('\t', ' ') or '-'}


AB_RE = re.compile(r'逻辑速度同局 A/B：(绿|红|判不出)：(?:(推左摇杆走|推右摇杆转|不按键)画面运动 关 ([0-9.]+) → 开 ([0-9.]+) 像素/秒、出图 ([0-9.]+) → ([0-9.]+) 帧/秒，ρ = ([0-9.]+)、q = ([0-9.]+))?(.*)')
AB_HEAD = ['键', '名称', '版本', '构建号', '结论', 'ρ', 'q', '量法', '关段像素每秒', '开段像素每秒', '关段帧率', '开段帧率', '说明', '日期', '局目录']
def fps_ab(lg):
    """60 帧逻辑速度同局 A/B 结论（tests/autoplay speed_ab 打的最后一行「逻辑速度同局 A/B：绿|红|判不出：…」）→ dict（AB_HEAD 第 4 列起），没有这一行 = None"""
    try: hl = open(os.path.join(lg, 'host.log'), encoding='utf-8', errors='replace').read()
    except OSError: return None
    ms = list(AB_RE.finditer(hl))
    if not ms: return None
    m = ms[-1]; g = [x or '' for x in m.groups()]; b = re.search(r'主程序构建号 ([0-9a-f]{32})', hl)
    return {'构建号': b.group(1) if b else '', '结论': g[0], 'ρ': g[6], 'q': g[7], '量法': g[1], '关段像素每秒': g[2], '开段像素每秒': g[3], '关段帧率': g[4], '开段帧率': g[5],
            '说明': g[8].strip().strip('（）')[:120], '日期': date.today().isoformat(), '局目录': lg}
def fps_ab_note(key, name, ver, lg):   # 普查驱动给了 CENSUS_FPS_AB_LIST（批次目录下的逻辑速度.tsv）就追加一行；tools/fps_ab_ledger.py 合进 docs/名单_60帧逻辑速度.tsv
    out = os.environ.get('CENSUS_FPS_AB_LIST'); v = fps_ab(lg) if out else None
    if not v: return
    new = not os.path.exists(out)
    with open(out, 'a', encoding='utf-8') as f:
        if new: f.write('\t'.join(AB_HEAD) + '\n')
        f.write('\t'.join([key, name, ver] + [str(v[k]).replace('\t', ' ') for k in AB_HEAD[3:]]) + '\n')


def row(key, name, ver, host, gb, res, us=None):
    out = row_dict(key, name, ver, host, gb, res, us)
    if out is None:
        print(f'【红】{res} 没有结果行', file=sys.stderr); return 1
    out['补丁包修复'] = patch_fix(key, os.environ.get('CENSUS_PATCH_RES'))
    print('\t'.join(str(out[k]) for k in TH))
    return 0


def patch_fix(key, res):
    """补丁包修复（11-03 维护者：补丁修复不计入一次成功，另列）：主局一次成功≠是、本款有 <补丁根>/<程序号>/patch.tsv 时，tools/census/patch_run.sh 带 S2A_PATCH_DIR
    同一解包目录另出包跑一局，结果在 CENSUS_PATCH_RES（<款>/r_patch/结果.tsv）→ 那局按同一口径的一次成功（是 / 否 / 待手测 / 未判）+「｜」+ 第一个失败点；
    没跑补丁局（无补丁 / 主局已一次成功 / 没给）= '-'。"""
    if not res: return '-'
    p = row_dict(key, '', '', '', '', res, notes=False)
    if p is None: return '-'
    return f"{one_shot(p)}｜{p.get('第一个失败点') or '-'}".replace('\t', ' ')


def oneshot_res(key, res):
    """一个局结果表（one_game.sh 结果.tsv + 同目录 logs/<键>/）按总表口径的一次成功：打 是 / 否 / 待手测 / 未判；没有结果行打 否。patch_run.sh 用它决定要不要跑补丁局。"""
    p = row_dict(key, '', '', '', '', res, notes=False)
    print(one_shot(p) if p is not None else '否')
    return 0


def row_dict(key, name, ver, host, gb, res, us=None, notes=True):
    """一个局结果表的末行 → 总表一行的各列（不含补丁包修复）；没有结果行 = None。notes=False：不往逻辑速度表追加（补丁局 / 判断用）。"""
    rs = tsv(res)
    if not rs:
        return None
    r = rs[-1]
    out = {'键': key, '名称': name, '版本': ver, '机器': host, '源GB': gb, '日期': date.today().isoformat()}
    for k in TH[5:]:
        if k in ('日期', '归约变体', '原生帧率', '首遇现建', '宽屏断崖', '口径', '系统版本', '直连编不过', '接口缺口', '原生档', '手测', '不卡', '一次成功'): continue   # 日期上面已填；这几列只从局的日志读（没起局 = 空）
        out[k] = (r.get(k) or '-').replace('\t', ' ')
    out['归约变体'] = out['原生帧率'] = out['首遇现建'] = out['宽屏断崖'] = out['系统版本'] = ''
    if us is not None:
        out['解包秒'] = us
    lg = os.path.join(os.path.dirname(res), 'logs', key)
    if os.path.exists(os.path.join(lg, 'host.log')): out['进局'] = entry_ai(lg)[0]; out.update(caps_state(lg)); out['归约变体'] = reduce_state(lg); out['原生帧率'] = native_rate(lg, out['进局'] == '是'); out['首遇现建'] = first_build(lg); out['宽屏断崖'] = widen_cliff(lg); out['系统版本'] = sys_version(lg)   # 起了 Mac 局：进局按 AI 看截图；能力按实际生效记
    if stub_missing(out, lg): out.update({'结论': '未判', '第一个失败点': STUB})
    mr = pack_machine(out, lg)
    if mr: out.update({'结论': '未判', '第一个失败点': mr})
    if notes: fps_ab_note(key, name, ver, lg)
    out['口径'] = caliber(out)
    out['直连编不过'] = direct_fail(key, lg)
    out['接口缺口'] = api_gap()
    out['原生档'] = native_tier(lg)
    out['不卡'] = stall_cell(lg) if os.path.exists(os.path.join(lg, 'host.log')) else '-'
    out['手测'] = '-'   # 维护者 手测结论另记在 手测结果.tsv，汇总时按键并入（manual_results）
    out['一次成功'] = one_shot(out)
    return out


def native_tier(lg):
    """原生档（11-02 维护者）：one_game.sh 写的 logs/<键>/.原生档（结论 / 第一个失败点 / 首帧 / 进局）→ 总表一格「结论｜失败点｜首帧 X｜进局 Y」；没跑原生档 = '-'。"""
    try: f = open(os.path.join(lg, '.原生档'), encoding='utf-8').readline().rstrip('\n').split('\t')
    except OSError: return '-'
    f = (f + ['-'] * 4)[:4]
    return f'{f[0]}｜{f[1] or "-"}｜首帧 {f[2] or "-"}｜进局 {f[3] or "-"}'.replace('\t', ' ')


def tier_outcome(r):
    """16:9 原生档下这款的（出包成功, 不崩出画面, 进局）：跑过原生档的用原生档那局，没跑过的（主局已通过且出图，或出包就失败）用主局。"""
    fp = r.get('第一个失败点') or ''
    packed = not fp.startswith(('解包', '出包', '不支持', '直连库没出'))
    c, first, ent = r['结论'], r.get('首帧'), r.get('进局')
    nt = r.get('原生档') or '-'
    if nt != '-':
        p = nt.split('｜'); c = p[0]; first = p[2].replace('首帧 ', '') if len(p) > 2 else '-'; ent = p[3].replace('进局 ', '') if len(p) > 3 else '-'
    return packed, packed and c == '通过' and first == '是', packed and (ent == '是' or r.get('手测') == '是')   # 进局 = 自动玩家判出或 维护者 手测确认


STALL_X, HANG_S = 2.0, 60   # 卡顿读数：帧时间 > 2 × 基准记一次（只记不判）；卡死：最后一帧到收局 ≥ 60 秒（见文件头「一次成功」）
RYU_TS = re.compile(r'^(\d\d):(\d\d):(\d\d)\.(\d{3}) \|', re.M)   # Ryujinx 日志行时间戳（进程起来后的墙钟，时:分:秒.毫秒）
WALL_KILL = re.compile(r'超墙钟 (\d+) 秒没收局')


def _frames(d):
    """局目录 d 的 frames.tsv → [(帧号, 行)]；没有文件 = []"""
    f = os.path.join(d, 'frames.tsv')
    if not os.path.exists(f): return []
    return [(int(r['frame']), r) for r in csv.DictReader(open(f, encoding='utf-8', errors='replace'), delimiter='\t')
            if (r.get('frame') or '').isdigit() and (r.get('wall_us') or '').isdigit()]


def smooth(lg):
    """卡顿读数（只记不判，给真机参考）：「卡顿 0.2%｜最长 71 ms｜锁 60｜实测 60」；取不到帧节拍或帧数不足 300 = '-'。"""
    try: hl = open(os.path.join(lg, 'host.log'), encoding='utf-8', errors='replace').read()
    except OSError: return '-'
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__)))); from game_fps import target
    fps, _, ok = target(hl)
    if not ok or not fps: return '-'
    mf = mark_frame(lg); import ab_span; sp = ab_span.spans(hl)   # A/B 段（改出帧状态）里的帧不算，同 steady_timing
    for d in ('run', 'run2', '.'):
        rs = [r for n, r in _frames(os.path.join(lg, d)) if n > (mf or 0) and ab_span.keep(n, sp)]
        if not rs: continue
        col = 'disp_us' if sum((r.get('disp_us') or '').isdigit() and int(r['disp_us']) > 0 for r in rs) > len(rs) // 2 else 'wall_us'
        w = [int(r[col]) for r in rs if (r.get(col) or '').isdigit() and int(r[col]) > 0][-1200:]
        if len(w) < 300: continue
        md = sorted(w)[len(w) // 2]; t = max(1e6 / fps, md)   # 基准 = 锁帧间隔与实测中位取大：游戏自己按 30 帧出帧而交换间隔报 1（大逆转裁判 11-02）不算卡
        return f'卡顿 {100 * sum(x > STALL_X * t for x in w) / len(w):.1f}%｜最长 {max(w) / 1000:.0f} ms｜锁 {fps:.0f}｜实测 {1e6 / md:.0f}'
    return '-'


def hang(lg):
    """卡死判定（11-03 维护者：Mac 普查只判卡死不判卡顿）：按帧进度、不按快慢——(是否卡死, 说明)；没有帧 = (None, '')。
    局目录取 run / run2 / 本目录里第一个有帧的（frames.tsv 与 host.log 同目录）。卡死 = 最后一帧到收局 ≥ HANG_S 秒：
    收局时刻 = host.log 最后一个 Ryujinx 时间戳（被墙钟杀时取「超墙钟 N 秒」，取大），最后一帧时刻 = 「首帧上屏」行之前最近的时间戳 + 全部帧间隔之和；
    取不到这两个时刻 = 未卡死（停了又走回来的长帧不算卡死，见文件头）。"""
    for d in ('run', 'run2', '.'):
        fr = _frames(os.path.join(lg, d))
        if not fr: continue
        w = [int(r['wall_us']) for _, r in fr]
        try: h = open(os.path.join(lg, d, 'host.log'), encoding='utf-8', errors='replace').read()
        except OSError: h = ''
        ts = [(m.start(), int(m[1]) * 3600 + int(m[2]) * 60 + int(m[3]) + int(m[4]) / 1000) for m in RYU_TS.finditer(h)]
        ff = h.find('首帧上屏'); t0 = [t for p, t in ts if p < ff] if ff >= 0 else []
        end = max(([ts[-1][1]] if ts else []) + [float(x) for x in WALL_KILL.findall(h)], default=None)
        tail = end - t0[-1] - sum(w) / 1e6 if t0 and end is not None else None
        return (True, f'第 {fr[-1][0]} 帧后 {tail:.0f} 秒到收局无新帧') if tail is not None and tail >= HANG_S else (False, '')
    return None, ''


def stall_cell(lg):
    """「不卡」列：「卡死｜第 F 帧后 N 秒到收局无新帧｜卡顿读数」/「未卡死｜卡顿读数」；没有帧 = '-'（一次成功记未判）。"""
    hung, why = hang(lg)
    if hung is None: return '-'
    sm = smooth(lg)
    return '｜'.join(x for x in ('卡死' if hung else '未卡死', why, sm if sm != '-' else '') if x)


def hung_cell(sm):
    """「不卡」列是否卡死（旧口径行「过 / 不过 / 作废…」没有卡死判定 = 否，rejudge 重算）。"""
    return sm.startswith('卡死')


def one_shot(r):
    """一次成功（见文件头）：是 / 否 / 待手测（只差进局没判出）/ 未判（进了局但没有帧读数，判不了卡没卡死）。"""
    fp = r.get('第一个失败点') or ''
    if fp.startswith(('解包', '出包', '不支持', '直连库没出')) or r.get('结论') != '通过': return '否'
    sm = r.get('不卡') or '-'
    if hung_cell(sm): return '否'
    if r.get('进局') != '是' and r.get('手测') != '是': return '否' if r.get('手测') == '否' else '待手测'
    return '未判' if sm == '-' else '是'


QUEUE_TH = ['键', '名称', '批次', '出包提交号', '结论', '第一个失败点', '进局', '档']   # 档 = 热门度档（1 任天堂第一方 / 一款第一方 RPG，2 百万级大作与知名系列，3 其余），人工排


def manual_queue(table, queue, batch, sha):
    """手测队列（11-02 维护者）：总表最后一行出包成功、进局为 否 / 未判 → 追加进队列（已在队列的键不重复）。按队列文件已有表头的列写（缺的列填 -）。返回追加条数。"""
    rs = tsv(table)
    if not rs: return 0
    r = rs[-1]
    fp = r.get('第一个失败点') or ''
    if fp.startswith(('解包', '出包', '不支持', '直连库没出')) or r.get('进局') not in ('否', '未判'): return 0
    old = os.path.exists(queue) and os.path.getsize(queue) > 0
    if old:
        with open(queue, encoding='utf-8') as f: head = f.readline().rstrip('\n').split('\t')
        if r['键'] in {q['键'] for q in tsv(queue)}: return 0
    else: head = QUEUE_TH
    v = {'键': r['键'], '名称': r.get('名称', '-'), '批次': batch, '出包提交号': sha, '结论': r['结论'], '第一个失败点': fp or '-', '进局': r.get('进局') or '-'}
    with open(queue, 'a', encoding='utf-8') as f:
        if not old: f.write('\t'.join(head) + '\n')
        f.write('\t'.join(v.get(h, '-') for h in head) + '\n')
    return 1


def deductions(b):
    """一次成功扣除（11-02 维护者：主数字另报「扣除测试存档 / 判据误判后的一次成功率」）：批次上一级 一次成功扣除.tsv（键 / 原因 测试存档错配|判据误判 / 备注）→ {键: 原因}；
    这些款没判成一次成功时从第二个分母里拿掉。CENSUS_DEDUCT 可另指；没有文件 = 空。"""
    p = os.environ.get('CENSUS_DEDUCT') or os.path.join(os.path.dirname(os.path.abspath(b)), '一次成功扣除.tsv')
    try: return {r['键']: r.get('原因', '-') for r in tsv(p)}
    except OSError: return {}


def pending_fix(b):
    """已修待复判（11-02 维护者：主数字旁单列一栏，复判后再并）：批次上一级 已修待复判.tsv（键 / 修复 / 备注）→ {键: 修复}；
    运维线在属主线报「修复已合入 / 在冷窗口」时登记、复判出结论后删行。CENSUS_PENDING_FIX 可另指；没有文件 = 空。"""
    p = os.environ.get('CENSUS_PENDING_FIX') or os.path.join(os.path.dirname(os.path.abspath(b)), '已修待复判.tsv')
    try: return {r['键']: r.get('修复', '-') for r in tsv(p)}
    except OSError: return {}


def manual_results(b):
    """维护者 手测结论：批次上一级的 手测结果.tsv（键 / 手测 是|否 / 备注）→ {键: 是|否}；没有文件 = 空。CENSUS_MANUAL_RESULTS 可另指。"""
    p = os.environ.get('CENSUS_MANUAL_RESULTS') or os.path.join(os.path.dirname(os.path.abspath(b)), '手测结果.tsv')
    try: return {r['键']: r.get('手测', '-') for r in tsv(p)}
    except OSError: return {}


def api_gap():
    """接口缺口（11-01 维护者：常设预检并进普查）：census.sh 跑完局后用 api_census.py --gap 写的一格（CENSUS_API_GAP）——
    「N（类别 n、…）」/ 0 / 「32 位」（暂不支持）/ 「读不动」；没有文件 = 「-」（解包失败 / 旧流程没解包目录）"""
    try: return open(os.environ['CENSUS_API_GAP'], encoding='utf-8').read().strip().replace('\t', ' ') or '-'
    except (KeyError, OSError): return '-'


def direct_fail(key, lg):
    """直连库编不过的支数（11-01 维护者：确定性编不过是翻译缺陷，玩家首遇卡顿、设备上编不过少画东西，目标归零）：读局日志 direct_fail.tsv
    （direct_lib.py 出库成功就写、快测拷来）→ 「N（类别 n、…）」，没有清单 = 「-」（没出直连库 / 没读到）；
    各键追加进 CENSUS_FAIL_LIST（census.sh 给批次的「直连编不过清单.tsv」：款 / 键 / 类别 / 错误），按款汇总交直连缺陷线归族"""
    p = os.path.join(lg, 'direct_fail.tsv')
    if not os.path.exists(p): return '-'
    rs = tsv(p)
    if rs and os.environ.get('CENSUS_FAIL_LIST'):
        new = not os.path.exists(os.environ['CENSUS_FAIL_LIST'])
        with open(os.environ['CENSUS_FAIL_LIST'], 'a') as f:
            if new: f.write('款\t键\t类别\t错误\n')
            f.writelines(f"{key}\t{r.get('键', '')}\t{r.get('类别', '')}\t{r.get('错误', '')}\n" for r in rs)
    c = collections.Counter(r.get('类别', '?') for r in rs)
    return f"{len(rs)}（{'、'.join(f'{k} {v}' for k, v in c.most_common())}）" if rs else '0'


def caliber(r):
    """总表「结论=通过」只是 verdict.py 的「不崩 + 无 Break + 首帧出图 + 无直连异常」（11-01 维护者：不能把没进局的记成通过）：
    口径列把它拆开——未进局（通过但进局=否，答不了画面 / 帧率 / 满屏）/ 不崩出图（通过且进局=是，五问另判）/ 进局未判 / 没走直连 / 失败 / 未判 / 源文件坏"""
    c = r.get('结论')
    if c == '通过':
        if (r.get('图形模式') or '').startswith('通用'): return '没走直连'
        return {'是': '不崩出图', '否': '未进局', '未判': '进局未判'}.get(r.get('进局'), '未进局')
    return c or '-'


def fiveq_pass(b, rows):
    """五问全过款数：取我方运行区 packq/autorun/五问.tsv（贡献者机器没有这个文件 = 返回 None）同单号 <批次名>-<键> 行，
    进局 是 + 画面 / 帧率 / 满屏 / 直连 都以「过」开头"""
    fp = os.environ.get('S2A_FIVEQ_TSV', os.path.expanduser('~/.s2arm/run/s2arm/packq/autorun/五问.tsv'))
    if not os.path.exists(fp): return None
    bn = os.path.basename(os.path.abspath(b)); five = {r['单号']: r for r in tsv(fp)}
    n = 0
    for r in rows:
        f = five.get(f"{bn}-{r.get('键', '')}")
        if r.get('进局') == '是' and f and all((f.get(k) or '').startswith('过') for k in ('画面', '帧率', '满屏', '直连')): n += 1
    return n


def klass(r):
    f = r.get('第一个失败点', '-')
    if r.get('结论') == '通过' and (r.get('图形模式') or '').startswith('通用'):   # 直连单轨：退到通用跑起来 = 直连库没覆盖 / 没走直连（10-30）
        return '没走直连（退到通用）'
    if r.get('结论') == '通过':
        return {'是': '进局', '未判': '进局未判（视觉判官不在）'}.get(r.get('进局'), '没进局')
    if f.startswith('游戏Break'):
        return '游戏Break'
    head, _, rest = f.partition('：')
    if rest and head in ('稳定崩溃', '偶发崩溃', '崩溃', '出包', '解包', '不支持', '源文件坏'):
        return head + '：' + re.split(r'[（(：]', rest)[0]
    return re.split(r'[（(：]', f)[0]


def owner(k):
    if re.search(r'客体代码|abort|C#|GC|游戏Break|局异常退出|崩溃', k) and 'GPU' not in k and '直连图形层' not in k:
        return '原生线'
    for p, o in OWNERS:
        if p in k:
            return o
    return '-'


def rejudge(b, repo):
    import shutil, tempfile
    sys.path.insert(0, os.path.join(repo, 'tools/quicktest')); import verdict as vd
    t = os.path.join(b, '总表.tsv'); rows = tsv(t); fix = {}
    srcs = {g['键']: g['本体文件'] for g in groups(b)} if os.path.exists(os.path.join(b, 'inventory', 'inspect.tsv')) else {}
    drop = set()
    for r in rows:   # 记成「解包」失败的：原件结构坏就改「源文件坏」（不算我方缺陷）；记成结构坏、复核没坏的撤回（删行，下次 plan 重排）
        if r['键'] not in srcs: continue
        if r['第一个失败点'].startswith('解包'):
            bad = src_bad(srcs[r['键']])
            if bad: fix[r['键']] = {'结论': '源文件坏', '第一个失败点': bad}
        elif r['第一个失败点'].startswith(('源文件坏：截断', '源文件坏：不是 XCI')) and src_bad(srcs[r['键']]) is None:
            drop.add(r['键'])
    for r in rows:   # 本机出包失败、出包是被机器闸暂停超时放弃的 → 未判（机器原因）；机器列现记 local（旧表记本机），出包日志在 p/logs（只解包）或 r/logs（出包 + 跑局）
        mr = next((m for x in ('p', 'r') for m in [pack_machine(r, os.path.join(b, 'work', r['键'], x, 'logs', r['键']))] if m), None) if r['机器'] in ('本机', 'local') else None
        if mr: fix[r['键']] = {'结论': '未判', '第一个失败点': mr}
    for r in rows:
        if r['机器'] in ('本机', '不起局') or r['结论'] == '未判': continue
        lg = os.path.join(b, 'work', r['键'], 'r', 'logs', r['键'])
        if not os.path.exists(os.path.join(lg, 'host.log')): continue
        tmp = tempfile.mkdtemp(prefix='census-rejudge-'); dirs = []
        for suf in ('', '_2'):
            if not os.path.exists(os.path.join(lg, f'host{suf}.log')): continue
            d = os.path.join(tmp, 'run' + suf); os.makedirs(d); dirs.append(d)
            for src, dst in ((f'host{suf}.log', 'host.log'), (f'run_mac{suf}.out', 'run.out'), (f'ap_summary{suf}.json', 'ap_summary.json')):
                if os.path.exists(os.path.join(lg, src)): shutil.copy(os.path.join(lg, src), os.path.join(d, dst))
        v = vd.verdict(dirs[0])
        if v[7] not in ('否', '收局', '-') and len(dirs) > 1: v = vd.verdict(dirs[0], dirs[1])   # 同 one_game：局内崩了才看补跑局
        shutil.rmtree(tmp)
        new = {'结论': v[0], '第一个失败点': v[1], '崩溃': v[7], '进局': (ne := entry_ai(lg)[0]), **caps_state(lg), '归约变体': reduce_state(lg), '原生帧率': native_rate(lg, ne == '是'), '首遇现建': first_build(lg), '宽屏断崖': widen_cliff(lg), '不卡': stall_cell(lg)}
        if stub_missing(new, lg): new.update({'结论': '未判', '第一个失败点': STUB})
        if any(r.get(k) != x for k, x in new.items()): fix[r['键']] = new
    cur = [r for r in tsv(t) if r['键'] not in drop]   # 普查驱动同时在追加：写回前重读最新总表，只按键改，临时文件原子替换
    for r in cur:
        if r['键'] in fix: r.update(fix[r['键']]); r['一次成功'] = one_shot(r)
    write_tsv(t + '.rejudge', TH, cur); os.replace(t + '.rejudge', t)
    print(f'重判 {len(fix)} 行、撤回误判 {len(drop)} 行（{t}）')
    return 0


def redo(b, keys, why):
    t = os.path.join(b, '总表.tsv'); ks = set(keys.split(','))
    cur = tsv(t); hit = [r for r in cur if r['键'] in ks]
    for r in hit: r.update({'结论': '未判', '第一个失败点': f'重排：{why}'})
    write_tsv(t + '.redo', TH, cur); os.replace(t + '.redo', t)   # 驱动同时在追加：读完立刻原子替换
    miss = ks - {r['键'] for r in hit}
    print(f'重排 {len(hit)} 款' + (f'；总表里没有：{",".join(sorted(miss))}' if miss else ''))
    return 1 if miss else 0


def runnable(b, rows):
    """直连能跑（10-30 维护者：别让自动玩家的缺陷算成直连的缺陷）。分母 = 起了直连 Mac 局、进局判得出的款（同口径并列报进局）；
    能跑 = 没崩，且进了局、或出图 ≥ 1000 帧且局里没有挡进局 / 致崩的红行（key_red 空：满屏判据红不算）。回 (进局, 能跑, 分母)"""
    d = runnable_rows(rows)
    return sum(r.get('进局') == '是' for r in d), sum(runs_ok(b, r) for r in d), len(d)


def runnable_rows(rows):   # 直连能跑的分母：起了直连 Mac 局、进局判得出
    return [r for r in rows if r['结论'] in ('通过', '失败') and r.get('Mac局秒', '0') not in ('0', '-', '') and r.get('进局') != '未判'
            and (r.get('图形模式') or '').startswith('直连')]


def runs_ok(b, r):   # 直连能跑：没崩，且进了局、或出图 ≥ 1000 帧且没有挡进局 / 致崩的红行
    if r.get('崩溃') not in ('否', '收局', '收局超时'): return False
    if r.get('进局') == '是': return True
    try: n = int(r.get('帧数') or 0)
    except ValueError: n = 0
    return n >= 1000 and not key_red(os.path.join(b, 'work', r['键'], 'r', 'logs', r['键'], 'host.log'))


def count_rates(rows):
    """输入已去重的行列表，返回解包 / 进局 / 0 崩的 (分子, 分母)。"""
    rows = [r for r in rows if r['结论'] not in ('源文件坏', '未判')]
    tried = [r for r in rows if not r['第一个失败点'].startswith('不支持')]
    unp = [r for r in tried if not r['第一个失败点'].startswith('解包')]
    # 直连单轨（维护者 10-30：开发期只出直连，「把直连打通关才是长期正确的」）：退到通用模式跑起来的局不算进局、不算 0 崩——通用兜底能跑不掩盖直连缺陷
    direct = lambda r: (r.get('图形模式') or '').startswith('直连')
    ent = [r for r in rows if r.get('进局') == '是' and direct(r)]; ment = [r for r in rows if r.get('进局') != '未判']   # 进局分母去掉测不出的
    ran = [r for r in rows if r.get('Mac局秒', '0') not in ('0', '-', '') and r['结论'] in ('通过', '失败')]
    ok = [r for r in ran if r.get('崩溃') in ('否', '收局', '收局超时') and direct(r)]
    return ((len(unp), len(tried)), (len(ent), len(ment)), (len(ok), len(ran)))


def native60(b, repo):
    """原生 60 候选写进 docs/名单_60帧能力覆盖/（L1 / L2 = 不需要，依据写本批实测）：caps_policy.native60 据此给「游戏原生 60 帧」来源。
    构建号取局 host.log「构建号 <32 位>」；表里已有同程序号 + 构建号的行不重复写。返回 0"""
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__)))); import reglist   # 按款登记目录（10-30）：合并读、追加、拆回写
    p = os.path.join(repo, 'docs', '名单_60帧能力覆盖'); have = reglist.text(repo, '名单_60帧能力覆盖')
    add = []
    for r in tsv(os.path.join(b, '总表.tsv')):
        if not native60_hit(r) or not re.fullmatch(r'[0-9A-F]{16}', r['键']): continue
        try: m = re.search(r'构建号 ([0-9a-fA-F]{32})', open(os.path.join(b, 'work', r['键'], 'r', 'logs', r['键'], 'host.log'), encoding='utf-8', errors='replace').read())
        except OSError: m = None
        if not m: continue
        bid = m.group(1).lower()
        if f'{r["键"]}\t{bid}' in have: continue
        why = f'{os.path.basename(os.path.abspath(b))} Mac 局 host.log 帧节拍「游戏请求交换间隔 1」、60 帧关实测 {r["原生帧率"].split("（")[0]} 帧（work/{r["键"]}）'
        add.append('\t'.join([r['键'], bid, r['键'].lower(), '不需要', why, '不需要', why, '未知', '-', '—']))
    if add:
        if not have.strip(): raise SystemExit(f'{p}：没有 _表头.tsv（按款登记目录，tools/reglist.py）')
        reglist.write(repo, '名单_60帧能力覆盖', have + ('' if have.endswith('\n') else '\n') + '\n'.join(add) + '\n')
    print(f'原生 60 写入 {len(add)} 行（{p}）'); return 0


def dock_register(b, repo):
    """主机档才进局的款写进 docs/名单_进局档位.tsv（10-30 维护者 S 级 ①）：one_game.sh 掌机档点触卡页、主机档复跑进了局 → 局日志目录写 .进局档位
    （「docked<TAB>原因」）。按程序号登记，已有不重复写；one_game.sh 下次起局直接用主机档"""
    p = os.path.join(repo, 'docs', '名单_进局档位.tsv')
    have = open(p, encoding='utf-8').read() if os.path.exists(p) else '# 进局档位：掌机档点触卡页、主机档（S2A_DOCKED=1）才进局的款；tools/quicktest/one_game.sh 按程序号直接主机档起局（census.py dock 写）\n程序号\t档位\t依据\t日期\n'
    known = {l.split('\t')[0] for l in have.splitlines() if l and not l.startswith('#')}
    add = []
    for r in tsv(os.path.join(b, '总表.tsv')):
        if r['键'] in known or not re.fullmatch(r'[0-9A-F]{16}', r['键']): continue
        try: mode, why = (open(os.path.join(b, 'work', r['键'], 'r', 'logs', r['键'], '.进局档位'), encoding='utf-8').read().strip().split('\t') + [''])[:2]
        except OSError: continue
        if mode != 'docked': continue
        add.append('\t'.join([r['键'], 'docked', f'{os.path.basename(os.path.abspath(b))} 掌机档{why}、主机档进局（{r["名称"][:40]}）', date.today().isoformat()])); known.add(r['键'])
    if add or not os.path.exists(p):
        with open(p, 'w', encoding='utf-8') as f: f.write(have + ('' if have.endswith('\n') else '\n') + ''.join(l + '\n' for l in add))
    print(f'主机档进局写入 {len(add)} 行（{p}）'); return 0
def widen_cliff_register(b, repo):
    """宽屏两侧缺渲染的款写进 docs/名单_能力强信号.tsv（widen 宽屏画面坏；内容哈希 = 当前宽屏实现哈希 caps_policy.signal_hashes，宽屏实现一改自动过时重新实测）。
    构建号取局 host.log「构建号 <32 位>」；表里已有同程序号 + 构建号的 widen 行不重复写"""
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__)))); import caps_policy
    h = caps_policy.signal_hashes(caps_policy.repo_reader(repo))['widen']
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__)))); import reglist   # 按款登记目录（10-30）：合并读、追加、拆回写
    p = os.path.join(repo, 'docs', '名单_能力强信号'); have = reglist.text(repo, '名单_能力强信号')
    add = []
    for r in tsv(os.path.join(b, '总表.tsv')):
        if not cliff_bad(r) or not re.fullmatch(r'[0-9A-F]{16}', r['键']): continue
        try: m = re.search(r'构建号 ([0-9a-fA-F]{32})', open(os.path.join(b, 'work', r['键'], 'r', 'logs', r['键'], 'host.log'), encoding='utf-8', errors='replace').read())
        except OSError: m = None
        if not m or f'{r["键"]}\t{m.group(1).lower()}\twiden\t' in have: continue
        why = f'{os.path.basename(os.path.abspath(b))} Mac 局进局截图 16:9 边界断崖 {r["宽屏断崖"]}：两侧缺渲染（引擎按 16:9 剔除，tools/widen_cliff.py；work/{r["键"]}/r/logs/{r["键"]}/ap_mark.png）'
        add.append('\t'.join([r['键'], m.group(1).lower(), 'widen', h, '宽屏画面坏', why, date.today().isoformat()]))
    if add:
        if not have.strip(): raise SystemExit(f'{p}：没有 _表头.tsv（按款登记目录，tools/reglist.py）')
        reglist.write(repo, '名单_能力强信号', have + ('' if have.endswith('\n') else '\n') + '\n'.join(add) + '\n')
    print(f'宽屏两侧缺渲染写入 {len(add)} 行（{p}）'); return 0


def direct_register(b, repo):
    """直连实测写进 docs/名单_直连实测/（10-30 发布清单「兼容性清单」对外版的数据源：tools/compatibility_report.py 的 direct 键读它）。
    一行 = 程序号 + 构建号 + 平台（普查局都是 Mac）的最近一次直连局：直连能跑 是 / 否（runs_ok 同口径）、进局 是 / 否；
    同键已有行就换成本批结果（以最近一次实测为准）。构建号取局 host.log「构建号 <32 位>」，取不到的款不写。依据只写批次 + 读数，不写本机路径"""
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__)))); import reglist
    n = '名单_直连实测'; have = reglist.text(repo, n)
    if not have.strip(): raise SystemExit(f'{reglist.dir_of(n)}：没有 _表头.tsv（按款登记目录，tools/reglist.py）')
    bat = os.path.basename(os.path.abspath(b)); new = {}
    for r in runnable_rows(tsv(os.path.join(b, '总表.tsv'))):
        if not re.fullmatch(r'[0-9A-F]{16}', r['键']): continue
        try: m = re.search(r'构建号 ([0-9a-fA-F]{32})', open(os.path.join(b, 'work', r['键'], 'r', 'logs', r['键'], 'host.log'), encoding='utf-8', errors='replace').read())
        except OSError: m = None
        if not m: continue
        ok = runs_ok(b, r)
        why = f'{bat} 普查 Mac 局：出图 {r.get("帧数") or 0} 帧、崩溃 {r.get("崩溃") or "-"}、进局 {r["进局"]}' + ('' if ok else f'；挡在：{(r.get("第一个失败点") or "-")[:60]}')
        new[(r['键'], m.group(1).lower(), 'Mac')] = [r['键'], m.group(1).lower(), r['键'].lower(), 'Mac', '是' if ok else '否', r['进局'], why.replace('\t', ' '), date.today().isoformat()]
    keep = [l for l in have.splitlines() if not (l and not l.startswith('#') and tuple(l.split('\t')[:2] + l.split('\t')[3:4]) in new)]
    reglist.write(repo, n, '\n'.join(keep) + '\n' + ''.join('\t'.join(v) + '\n' for v in new.values()))
    print(f'直连实测写入 {len(new)} 行（能跑 {sum(v[4] == "是" for v in new.values())}；{reglist.dir_of(n)}）'); return 0


UPSTREAM = 'docs/名单_直连缺陷上游'   # 按款登记目录（<程序号>.tsv / _无程序号.tsv，tools/reglist.py）   # 直连缺陷 → 上游对应（程序号 / 关键词 → Ryujinx 等上游的提交 / issue），手填，没有记「未查」


FS_RE = re.compile(r'出图未满屏')   # 满屏判据红（native 上屏判据）：画面质量问题，不挡进局（10-30 维护者：单独记一列、归画面线，不当没进局的原因）


FS_ON = '满屏判据 已开'   # host.log 的判据起局行（直连上屏）：没有这行 = 判据没跑，不能把没报红当绿
FS_N = re.compile(r'出图未满屏（[^，]*，第 (\d+) 次出图起')
FS_PNG = re.compile(r'满屏判据第 1 次红的那一帧.*?存到 (\S+)')


def fs_state(lg):
    """满屏看判据、不看能力清单开关（10-31 维护者：「能力清单：满屏开」只说放开了宽屏，不说画面铺满）：
    回 (结论, 第 1 次红的截图路径)。结论按五问同一口径三档（tools/score_cells.py fs_tier + 五问判官缓存里的自动分层，11-02 维护者）：过 / 局内红（说明）/ 待分层（说明）；
    没有 host.log 或判据没起 = 未判（判据缺席不当绿）"""
    try: t = open(os.path.join(lg, 'host.log'), encoding='utf-8', errors='replace').read()
    except OSError: return ('未判', '')
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__)))); import score_cells, quality_check
    tier, why = score_cells.fs_tier(t, quality_check.fs_layer(lg, t, ask=False))   # 自动分层只读五问问过的判官缓存（汇总循环里不发问）
    if tier is None: return ('未判', '')
    if tier == '过': return ('过', '')
    p = FS_PNG.search(t)
    return (f'{tier}（{why}）'.replace('\t', ' ')[:300], p.group(1) if p else '')


def fs_red(lg):
    """满屏判据的第一条红行；没有 = 空串"""
    try: return next((' '.join(l.strip().split())[:200] for l in open(lg, encoding='utf-8', errors='replace') if '【红】' in l and FS_RE.search(l)), '')
    except OSError: return ''


def key_red(lg):
    """关键红行（挡进局 / 致崩的那条）：FATAL 行（直连层 MDIE，不带【红】）> 崩溃 / Break 标志之前最后一条红行 > 第一条红行；没有 = 空串。
    第一条红行常是开局就打的无关红行（「GPU deswizzle init failed」），不能当 abort 的原因；满屏判据红（FS_RE）不挡进局，不当关键红行"""
    try: L = [' '.join(l.strip().split()) for l in open(lg, encoding='utf-8', errors='replace')]
    except OSError: return ''
    fat = [l for l in L if 'FATAL' in l]   # 直连层 MDIE 打「[nvn-mtl] FATAL …」，不带【红】
    if fat: return fat[0][:200]
    reds = [(i, l) for i, l in enumerate(L) if '【红】' in l and not FS_RE.search(l)]
    if not reds: return ''
    end = next((i for i, l in enumerate(L) if re.search(r'CRASH 信号|崩溃原始现场|收到信号|致命信号|Break 原因', l)), None)
    before = [l for i, l in reds if end is not None and i < end]
    return (before[-1] if before else reds[0][1])[:200]


ENV_RE = re.compile(r'Unable to reach MTLCompilerService|GPU deswizzle init failed|does not identify an argument buffer')   # 本机 Metal 编译服务失效（10-30 画面线：c1029c 07–09 点 7 局三项全出、之前 50 多局全 0）
# 已删机制的红行（机制合入 main 后不可能再出）：局早于删除合入时刻 → 旧读数待重测，不当缺陷派（10-30 维护者）。（红行特征, 删除合入 main 的时刻, 说明）
GONE = [(re.compile(r'linked stand-in'), datetime(2026, 10, 30, 10, 35, 54).timestamp(), '链接版已删（wire-c/rm-gal-linked，main d1afbe982 10-30 10:35）')]


DGL_RE = re.compile(r'\[nvn-mtl\]|\[vk\]|NVN address lookup|NVN unimplemented')   # 直连图形层的红行（直连翻译层 / Vulkan 后端 / NVN 函数表）


def nav_why(lg, r):
    """没进局、没有挡进局的红行时，局是不是一直在正常出图、卡在自动玩家导航（我方工具）：没崩、出图 ≥ 1000 帧、自动玩家在按键 → 回一句定位；否则空串（未定因）。
    10-30 c1029c 12 款未定因逐张看 last_vision.png：全是画面正常、停在菜单 / 过场 / 弹窗 / 已在可玩画面判据没认出，第一个挡进局的点都是导航"""
    try: n = int(r.get('帧数') or 0)
    except ValueError: n = 0
    if r.get('崩溃') not in ('否', '收局', '收局超时') or n < 1000: return ''
    try: t = open(lg, encoding='utf-8', errors='replace').read()
    except OSError: return ''
    if '自动玩家：导航' not in t and '自动玩家：视觉测试员' not in t: return ''
    m = re.search(r'自动玩家结论：没到 MARK；([^；\n]+)', t)
    return f'自动玩家导航没进可玩（出图 {n} 帧、没崩）：' + (m.group(1).strip() if m else '局墙钟先到、自动玩家没出结论')


def gone_why(red, lg):
    """关键红行出自已删机制、且局（host.log 修改时刻）早于删除合入 → 回说明；否则空串"""
    try: m = os.path.getmtime(lg)
    except OSError: return ''
    return next((w for rx, ts, w in GONE if rx.search(red) and m < ts), '')


def no_direct_why(kl):
    """退到通用的局：为什么包里没有直连库（读 oneclick.log / refresh.log.red；远端出包、通过的局不留出包日志 → 空串）"""
    t = ''
    for n in ('oneclick.log', 'refresh.log.red'):
        try: t += open(os.path.join(kl, n), encoding='utf-8', errors='replace').read()
        except OSError: pass
    m = re.search(r'unsupported graphics API: ([^\n（]+)', t)
    if m: return f'非 NVN 款（{m.group(1).strip()[:60]}，GL / Vulkan）：直连 GL / Vulkan 路缺口'
    m = re.search(r'直连库失败：([^\n]{0,120})', t)
    if m: return f'直连库出包失败：{m.group(1).strip()}'
    return ''


def next_step(k, red):
    """直连缺陷表「下一步」（按类别给能直接开工的动作；上游对照表有该款的下一步时以对照表为准）"""
    if k.startswith('环境'): return '本机 Metal 编译服务那段时间失效（不算游戏缺陷）：管线修好后复跑再判'
    if '直连缺口' in k: return '只出直连后出包停在直连配置推导 / 直连库（按关键红行看缺口：非 NVN 款走直连 GL / Vulkan 路，NVN 从别的模块导入的补推导）'
    if '没走直连' in k: return '包里没出本链直连库（one_game 直连优先，根里没有直连库就改通用起局）：出包日志没留，重出一次看 oneclick.log 的直连缺口原因'
    if '直连异常' in k or '直连图形层' in k: return '按关键红行修直连层（FATAL / nvn-mtl 红行指到的着色器或 NVN 函数），修后单款重跑 tools/quicktest/one_game.sh'
    if '首帧' in k or 'GPU' in k or '黑屏' in k: return '首帧前停住：看 host.log 线程现场（S2A_STALL_DUMP_S），定是等 GPU 还是等服务'
    if 'Break' in k: return '游戏自己报错退出：S2A_IPC_RECORD 录两边调用流，tools/ipc_diff.py 找与 Ryujinx 第一处分歧'
    if '客体代码' in k or 'subsdk' in k or 'abort' in k: return '先在 Ryujinx 上同版本对拍；崩溃现场带客体回溯（S2A_DIAG_DUMP）往前找出错的服务返回值 / 装载'
    if k.startswith('旧读数'): return '关键红行出自已删机制、局早于删除合入：下一轮普查复跑再判，不当缺陷派'
    if '卡在导航' in k: return '游戏正常出图、卡在自动玩家导航（我方工具）：看 last_vision.png 停在哪页（菜单 / 过场 / 弹窗 / 已在可玩画面判据没认出），看 vision/vNN.json 模型怎么答、改进局判据'
    if '未定因' in k: return '没进局、局里没有挡进局的红行：下一轮普查补截图（last_vision.png）定卡在哪页'
    if k == '没进局': return '自动玩家导航：看 last_vision.png 卡在哪页，看 vision/vNN.json 模型怎么答、改视觉题面'
    if '进局未判' in k: return '跑局机缺视觉判官密钥：配好后 census.py rejudge 重判'
    if '局没起' in k: return '跑局机局槽 / 宿主构建：看 entry.out 红行，修机器后重排'
    if k.startswith('出包'): return '出包阶段失败：看 pack_logs / pack_failed 阶段日志'
    return '看关键红行定因'


def direct_defects(b, repo):
    """直连缺陷表（10-30 维护者：开发期只出直连，这张表是画面线和原生线的主活清单）→ <批次>/直连缺陷表.tsv，返回行数。
    一行 = 起了 Mac 局、在直连单轨口径下没过的款：结论失败（崩溃 / Break / 首帧 / 直连异常…）、退到通用模式、或没进局（工具没进局归泛化线，照列）。
    列：款 / 程序号 / 版本 / 第一个失败点（总表没记就取关键红行）/ 类别 / 归属 / 下一步 / 图形模式 / 进局 / 上游对应 / host.log / 首个红行（关键红行，满屏判据红不算）/ 满屏判据红（画面线）。
    上游对应读 docs/名单_直连缺陷上游/（列 程序号 或 关键词 / 上游 / 下一步）：程序号相同或关键词出现在第一个失败点 / 首个红行里就填，否则「未查」；
    下一步优先用对照表那一列，没有按类别给（next_step）"""
    up = []
    try:
        sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__)))); import reglist
        L = [l.split('\t') for l in reglist.text(repo, '名单_直连缺陷上游').splitlines() if l.strip() and not l.startswith('#')]   # 按款登记目录合并读；表头前的 # 说明行跳过
        up = [dict(zip(L[0], r)) for r in L[1:]] if L else []
    except OSError: pass
    out = []
    for r in tsv(os.path.join(b, '总表.tsv')):
        if r.get('机器') in ('不起局', '') or r.get('结论') in ('源文件坏', '未判'): continue
        k = klass(r); nav = ''
        if k.startswith('出包') and 'direct' not in k:   # 只出直连后出包停在直连推导 / 直连库 = 直连缺陷（10-30）；旧行记成「出包：改写」的按出包日志改判
            try: pk = open(os.path.join(b, 'work', r.get('键', ''), 'r', 'logs', r.get('键', ''), 'oneclick.log'), encoding='utf-8', errors='replace').read()
            except OSError: pk = ''
            if '直连单轨停在' in pk or k == '出包：直连缺口': k = '出包：直连缺口'
            else: continue   # 别的出包失败不是直连缺陷（出包线的事，汇总里照列）
        elif r.get('Mac局秒', '0') in ('0', '-', ''): continue
        if k == '进局': continue
        key = r.get('键', ''); lg = os.path.join(b, 'work', key, 'r', 'logs', key, 'host.log'); red = key_red(lg)
        if not red and k == '出包：直连缺口':   # 没起局：关键红行取出包日志里最后一条红行（直连单轨停在哪一步）
            try: red = next((' '.join(l.split())[:200] for l in reversed(pk.split('\n')) if '【红】' in l), '')
            except NameError: red = ''
        if not os.path.exists(lg): lg = '-'
        # 崩在直连层里 = 直连缺陷归画面线：宿主 abort 且关键红行出自直连图形层（[nvn-mtl] / [gal]），或任何类别关键红行是 NVN 函数缺失 / 直连异常；
        #   客体代码崩溃（pc 在游戏模块）不因崩溃前碰巧有图形红行就改归属
        try: env = ENV_RE.search(open(lg, encoding='utf-8', errors='replace').read())
        except OSError: env = None
        if env and r.get('结论') == '失败': k = '环境：编译服务失效'   # 编译服务失效那段时间的崩溃先不算游戏缺陷（10-30 画面线：5 款 abort 同一断言）
        if gone_why(red, lg): k = '旧读数待重测'
        elif k == '没进局' and not red: k, nav = ('没进局：卡在导航', nav_why(lg, r)) if nav_why(lg, r) else ('没进局：未定因', '')   # 没有挡进局的红行（满屏判据红不算）
        elif k == '没进局' and DGL_RE.search(red) and 'pipeline archive' not in red: k = '没进局（直连图形层）'   # 挡进局的是直连图形层红行 → 画面线（10-30 维护者：同一块代码只留一个属主）；管线存档删目录是缓存工具的事，不算
        why = no_direct_why(os.path.dirname(lg)) if '没走直连' in k else ''
        if owner(k) == '原生线' and (('abort' in k and re.search(r'\[nvn-mtl\]|\[gal\]', red)) or re.search(r'NVN unimplemented|NVN address lookup|直连异常', red)): k += '（直连图形层）'
        u = [x for x in up if (x.get('程序号') and x['程序号'].upper() == key.upper()) or (x.get('关键词') and x['关键词'] in (r.get('第一个失败点', '') + red))]
        ff = r.get('第一个失败点', '') or '-'
        if k == '没进局：卡在导航': ff = nav
        if ff == '-' and red: ff = red   # 总表没记失败点（没进局等）：取挡进局的关键红行（10-30 维护者：不拿满屏判据红当原因）
        if gone_why(red, lg): ff = f'旧读数待重测：{gone_why(red, lg)}'
        out.append({'款': r.get('名称', '')[:40], '程序号': key, '版本': r.get('版本', ''), '第一个失败点': ff[:120], '类别': k,
                    '归属': owner(k), '图形模式': r.get('图形模式', '-') or '-', '进局': r.get('进局', '-') or '-',
                    '上游对应': '；'.join(x.get('上游', '') for x in u) or '未查',
                    '下一步': '；'.join(x['下一步'] for x in u if x.get('下一步')) or (why + '；按缺口补直连' if why else next_step(k, red)), 'host.log': lg, '首个红行': red or '-',
                    '满屏判据红（画面线）': (fs_red(lg) if lg != '-' else '') or '-'})
    order = {'画面线': 0, '原生线': 1, '泛化线': 2, '出包线': 3, '列车线': 4, '环境（复跑再判）': 6}
    out.sort(key=lambda x: (order.get(x['归属'], 5), x['类别'], x['款']))
    head = ['款', '程序号', '版本', '第一个失败点', '类别', '归属', '下一步', '图形模式', '进局', '上游对应', 'host.log', '首个红行', '满屏判据红（画面线）']
    write_tsv(os.path.join(b, '直连缺陷表.tsv'), head, out)
    n = collections.Counter(x['归属'] for x in out)
    fs = sum(x['满屏判据红（画面线）'] != '-' for x in out)
    print(f'直连缺陷 {len(out)} 款（' + '、'.join(f'{k} {v}' for k, v in n.most_common()) + f'；另 {fs} 款带满屏判据红，归画面线）→ {os.path.join(b, "直连缺陷表.tsv")}'); return len(out)


def summarize(b):
    rows = tsv(os.path.join(b, '总表.tsv'))
    bad = [r for r in rows if r['结论'] == '源文件坏']; und = [r for r in rows if r['结论'] == '未判']
    rows = [r for r in rows if r['结论'] not in ('源文件坏', '未判')]
    man = manual_results(b)
    for r in rows: r['手测'] = man.get(r.get('键'), r.get('手测') or '-')   # 维护者 手测结论按键并入（进局 = 自动或手测）
    auto = {id(r): one_shot({**r, '手测': '-'}) for r in rows}   # ① 只看自动判定（手测不并入）
    for r in rows: r['一次成功'] = one_shot(r)   # 手测并入后重算
    rates = count_rates(rows)
    shut = [r for r in rows if r.get('Mac局秒', '0') not in ('0', '-', '') and r['结论'] in ('通过', '失败') and r.get('崩溃') == '收局']
    pct = lambda a, n: f'{a}/{n}（{100 * a / n:.1f}%）' if n else '0/0'
    judged = [r for r in rows if r['结论'] in ('通过', '失败')]; fq = fiveq_pass(b, judged)
    head5 = f'五问全过 {fq if fq is not None else "?（无五问表）"} / 已判 {len(judged)}（口径：不崩出图 {sum(caliber(r) == "不崩出图" for r in judged)}、未进局 {sum(caliber(r) == "未进局" for r in judged)}、失败 {sum(r["结论"] == "失败" for r in judged)}；「通过」＝不崩出图，不等于五问）'
    to = [tier_outcome(r) for r in rows]   # 主数字（11-02 维护者）：16:9 原生档三率；满屏三档、60 帧 A/B 是第二层
    n = len(rows); ok = sum(r['一次成功'] == '是' for r in rows); pend = sum(r['一次成功'] == '待手测' for r in rows)
    pk = sum(t[0] for t in to); en = sum(r.get('进局') == '是' or r.get('手测') == '是' for r in rows)
    sm = sum(r.get('结论') == '通过' and (r.get('不卡') or '-') != '-' and not hung_cell(r['不卡']) for r in rows)
    ded = deductions(b); n2 = sum(1 for r in rows if not (r.get('键') in ded and r['一次成功'] != '是'))
    # 主数字报三个（11-02 维护者：维护者 手测 10 款过 9，只报自动判定会低估）：①自动判定 ②并入手测（待手测里手测过的按手测算，没测的单列）
    #   ③扣除测试存档错配 / 普查环境 / 判据误判（一次成功扣除.tsv 登记、带证据）后；另列已修待复判（已修待复判.tsv），复判后再并
    oka = sum(auto[id(r)] == '是' for r in rows); mt = [r for r in rows if auto[id(r)] == '待手测' and man.get(r.get('键')) in ('是', '否')]
    pf = pending_fix(b); pfr = [r.get('名称') or r['键'] for r in rows if r.get('键') in pf and r['一次成功'] != '是']
    head5 = (f'一次成功（主数字：原生帧率 + 16:9，出包 / 进局 / 不崩 / 不卡死四件全过）①自动判定 {pct(oka, n)}'
             f' ｜②并入手测 {pct(ok, n)}（待手测里已手测 {len(mt)} 款过 {sum(man[r["键"]] == "是" for r in mt)}，未测 {pend} 款）'
             f' ｜③扣除测试存档错配 / 普查环境 / 判据误判后 {pct(ok, n2)}（扣 {n - n2} 款）'
             f' ｜已修待复判 {len(pfr)} 款' + (f'（{"、".join(pfr)}）' if pfr else '') +
             f' ｜出包成功 {pct(pk, n)} ｜进局（自动 + 手测）{pct(en, n)} ｜不崩不卡死 {pct(sm, n)}'
             f' ｜补丁包修复 {sum(str(r.get("补丁包修复") or "").startswith("是") for r in rows)} 款（主局没一次成功、带补丁那局过，不计入一次成功）**\n\n**第二层（能力开）：' + head5)
    line = f'普查三率：解包 {pct(*rates[0])} ｜进局 {pct(*rates[1])} ｜0 崩 {pct(*rates[2])}'
    # 能力实际生效率（10-29 维护者：每轮可比）：分母同 0 崩率 = 起了 Mac 局的款；无清单 = host.log 没有能力清单行、没按发布配置跑的局（判据红）
    cr = [r for r in rows if r.get('Mac局秒', '0') not in ('0', '-', '') and r['结论'] in ('通过', '失败')]
    nat = [r for r in cr if native60_hit(r)]   # 60 帧关但游戏自己就跑 60：缺的是来源登记不是能力（census.py native60 补登记）
    jin = [r for r in rows if r.get('进局') == '是']
    fs_pass = sum(r.get('满屏') == '过' for r in jin)
    fs_red_rows = [r for r in rows if str(r.get('满屏', '')).startswith(('红', '局内红'))]   # 「红（…）」= 三档前的旧行，按局内红算
    fs_mid_rows = [r for r in rows if str(r.get('满屏', '')).startswith('待分层')]
    line += f'\n满屏判据（三档）：过 {pct(fs_pass, len(jin))}（分母 = 进局款）｜局内红 {len(fs_red_rows)} 款｜待分层 {len(fs_mid_rows)} 款（红段在界面页或分不清，不算过也不算局内红）｜未判 {sum(r.get("满屏") == "未判" for r in jin)} 款'
    for tag, rr in (('局内红', fs_red_rows), ('待分层', fs_mid_rows)):
        for r in rr:
            png = fs_state(os.path.join(b, 'work', r['键'], 'r', 'logs', r['键']))[1]   # 现场已被清掉就读不到截图路径：写「现场已清」
            line += f'\n  满屏{tag} {r["名称"]}：{r["满屏"]}，截图 {png or "现场已清"}'
    line += (f'\n能力生效（能力清单开关，不是画面结论）：满屏 {pct(sum(r.get("满屏能力") == "开" for r in cr), len(cr))} ｜60 帧 {pct(sum(r.get("60帧") == "开" for r in cr), len(cr))}（另原生 60 {len(nat)} 款）'
             f' ｜无清单 {sum(r.get("满屏能力") == "无清单" or r.get("60帧") == "无清单" for r in cr)} 局')
    # 没进局拆两类（10-29 维护者：跑局工具的缺陷不混进产品进局率）：工具没进局 = 局正常（结论通过：没崩、没直连异常）只是自动玩家没走进去；
    #   游戏没进局 = 其余（崩溃 / Break / 黑屏 / 出包失败 / 不支持）。另给去掉工具缺陷的进局率 = 进局 /（进局 + 游戏没进局）
    noent = [r for r in rows if r.get('进局') not in ('是', '未判')]
    tool = [r for r in noent if r.get('进局') == '否' and r['结论'] == '通过']
    line += (f'\n没进局 {len(noent)} = 工具没进局 {len(tool)}（局正常、自动玩家没走进去）+ 游戏没进局 {len(noent) - len(tool)}（崩溃 / Break / 黑屏 / 出包 / 不支持）'
             f' ｜去掉工具缺陷的进局率 {pct(rates[1][0], rates[1][0] + len(noent) - len(tool))}')
    # 直连缺陷表（10-30：开发期只出直连，画面线 / 原生线主活清单）随汇总一起出；三率按直连单轨口径（退到通用不算进局 / 0 崩）
    import contextlib, io
    with contextlib.redirect_stdout(io.StringIO()): dd = direct_defects(b, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    dn = collections.Counter(x['归属'] for x in tsv(os.path.join(b, '直连缺陷表.tsv')))
    line += f'\n直连缺陷 {dd} 款（' + '、'.join(f'{k} {v}' for k, v in dn.most_common()) + '；直连单轨口径，表：直连缺陷表.tsv）'
    e, ok, n = runnable(b, rows); line += f'\n直连局（起了直连 Mac 局、进局判得出）：进局 {pct(e, n)} ｜直连能跑 {pct(ok, n)}（出图 ≥ 1000 帧、不崩、没有挡进局红行；差额是自动玩家没导航进去）'
    c = collections.Counter(klass(r) for r in rows)
    with open(os.path.join(b, '汇总.md'), 'w', encoding='utf-8') as f:
        f.write(f'# 普查汇总（{os.path.basename(os.path.abspath(b))}，{date.today().isoformat()}）\n\n**' + head5 + '**\n\n' + line.replace('\n', '\n\n') + '\n\n')
        f.write(f'普查款数 {len(rows)}（另：源文件坏 {len(bad)}、未判 {len(und)}，不进分母）；到点收局时崩 {len(shut)} 款（算局内 0 崩，单列）；口径见 tools/census/census.py 文件头\n\n')
        f.write('| 类别 | 款数 | 属主 | 例 |\n|---|---|---|---|\n')
        for k, n in c.most_common():
            ex = '、'.join(r['名称'][:24] for r in rows if klass(r) == k)
            ex = ex if len(ex) <= 160 else ex[:160] + '…'
            f.write(f'| {k} | {n} | {owner(k) if k != "进局" else "-"} | {ex} |\n')
        f.write(f'\n## 原生 60 候选（{len(nat)} 款，判据：60 帧关、请求间隔 1、MARK 后局内实测 ≥ {NATIVE60_MIN:g} 帧）\n\n')
        if nat:
            f.write('| 款 | 程序号 | 原生帧率 |\n|---|---|---|\n')
            for r in nat: f.write(f'| {r["名称"][:40]} | {r["键"]} | {r["原生帧率"]} |\n')
        l2 = [r for r in cr if l2_hit(r)]   # 引擎自己限帧（10-30 grokbot S 级②：L1 放开了仍 30，修法在第二层——通用帧率表 / 社区补丁形状）
        f.write(f'\n## L2 卡点（{len(l2)} 款，判据：MARK 后局内 ≤ {L2_MAX:g} 帧，且 60 帧开或游戏请求间隔 1）\n\n')
        if l2:
            f.write('| 款 | 程序号 | 局内帧率 | 60 帧 |\n|---|---|---|---|\n')
            for r in l2: f.write(f'| {r["名称"][:40]} | {r["键"]} | {r["原生帧率"]} | {r.get("60帧", "")} |\n')
        # 直连异常的款带着色器映射表条数（10-29 画面线：先分「直连库覆盖缺口」（条数很少）和「画面错」两类；太鼓 70 条、绘制全丢）
        dx = [r for r in rows if r['第一个失败点'].startswith('直连异常')]
        f.write(f'\n## 直连异常（{len(dx)} 款，带着色器映射表条数）\n\n')
        if dx:
            f.write('| 款 | 程序号 | 映射表条数 | 第一个失败点 |\n|---|---|---|---|\n')
            for r in dx:
                try: m = re.search(r'shader map (\d+) entries', open(os.path.join(b, 'work', r['键'], 'r', 'logs', r['键'], 'host.log'), encoding='utf-8', errors='replace').read())
                except OSError: m = None
                f.write(f'| {r["名称"][:40]} | {r["键"]} | {m.group(1) if m else "-"} | {r["第一个失败点"][:60]} |\n')
        # 首遇超一帧的款（10-29 画面线：当轮补预热种子表）
        fs = [r for r in tsv(os.path.join(b, '总表.tsv')) if first_slow(r)]
        f.write(f'\n## 首遇超一帧的款（{len(fs)} 款，最长一条现建 > {FRAME_MS:.1f} ms）\n\n')
        if fs:
            f.write('| 款 | 程序号 | 首遇现建 | 局目录 |\n|---|---|---|---|\n')
            for r in fs: f.write(f'| {r["名称"][:40]} | {r["键"]} | {r["首遇现建"]} | work/{r["键"]}/r/logs/{r["键"]} |\n')
        # 宽屏两侧缺渲染（10-30 #996：16:9 边界断崖 ≥ 0.5；census.py widen_cliff 写进强信号表）
        cb = [r for r in tsv(os.path.join(b, '总表.tsv')) if cliff_bad(r)]
        f.write(f'\n## 宽屏两侧缺渲染（{len(cb)} 款，进局截图 16:9 边界断崖 ≥ 0.5）\n\n')
        if cb:
            f.write('| 款 | 程序号 | 断崖 | 局目录 |\n|---|---|---|---|\n')
            for r in cb: f.write(f'| {r["名称"][:40]} | {r["键"]} | {r["宽屏断崖"]} | work/{r["键"]}/r/logs/{r["键"]} |\n')
        # 真绑归约的款（10-29 画面线 #800 验收：当轮按这份单子同局同帧看图）
        red = [r for r in tsv(os.path.join(b, '总表.tsv')) if (r.get('归约变体') or '-') not in ('', '-')]
        f.write(f'\n## 真绑归约的款（{len(red)} 款）\n\n')
        if red:
            f.write('| 款 | 程序号 | 支数 / 最大毫秒 | 局目录 |\n|---|---|---|---|\n')
            for r in red: f.write(f'| {r["名称"][:40]} | {r["键"]} | {r["归约变体"]} | work/{r["键"]}/r/logs/{r["键"]} |\n')
    print(line)
    return 0


if __name__ == '__main__':
    a = sys.argv[1:]
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    if len(a) == 3 and a[0] == 'inventory':
        sys.exit(inventory(a[1], a[2], repo))
    elif len(a) == 2 and a[0] == 'plan':
        plan(a[1])
    elif len(a) in (7, 8) and a[0] == 'row':
        sys.exit(row(*a[1:]))
    elif len(a) == 3 and a[0] == 'oneshot_res':
        sys.exit(oneshot_res(a[1], a[2]))
    elif len(a) == 5 and a[0] == 'manual_queue':
        manual_queue(*a[1:])
    elif len(a) == 2 and a[0] == 'rejudge':
        sys.exit(rejudge(a[1], repo))
    elif len(a) == 4 and a[0] == 'redo':
        sys.exit(redo(*a[1:]))
    elif len(a) == 3 and a[0] == 'native60':
        sys.exit(native60(a[1], a[2]))
    elif len(a) == 3 and a[0] == 'dock':
        sys.exit(dock_register(a[1], a[2]))
    elif len(a) == 3 and a[0] == 'direct_defects':
        direct_defects(a[1], a[2]); sys.exit(0)
    elif len(a) == 3 and a[0] == 'direct_reg':
        sys.exit(direct_register(a[1], a[2]))
    elif len(a) == 3 and a[0] == 'widen_cliff':
        sys.exit(widen_cliff_register(a[1], a[2]))
    elif len(a) == 2 and a[0] == 'sum':
        sys.exit(summarize(a[1]))
    else:
        print(__doc__.strip().splitlines()[0]); sys.exit(2)
