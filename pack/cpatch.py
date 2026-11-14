#!/usr/bin/env python3
"""社区画面补丁应用层·出包期（直连线 10-27，维护者：社区资源集成进产品；10-30 维护者 改定：玩家包缺省不带上游补丁字节，只在 S2A_COMMUNITY_PATCHES=1 的内部开发 / 测试包里进包（pack/stage_rewrite.sh），宿主设置里运行时启停）：只解析补丁文本、不执行社区的任何脚本。
补丁（pchtxt / IPS）按「程序号 + 模块构建号」匹配本款 NSO；匹配上的每份（编号 × 模块）在改写阶段编成「双路 + 槽」，开关在运行时：
  · 代码段里原字是填充（全 0 / udf）的字：常写（补丁往空闲区写的新代码，关着时没有入口跳过来；照样经过改写器翻译）——改写器 w 行
  · 代码段里有效指令被改的字：双路跳板，读键页槽 2046 的本模块掩码、按本补丁的位分路——改写器 p 行（runtime/rewriter/rewriter.c cpatch_rows，Python 版同字节）
  · 代码段之后（ro / data）的字节：装载器按开关写补丁值或原值（runtime/src/cpatch.c）
  同一处被两份补丁改成不同值、模块内超过 64 份、改写器对某份记了缺口（点已是我方改写点 / 指令要翻译 / 解不出）→ 那份整份不进包，原因记 cpatch_plan.log

  cpatch.py scan <补丁索引目录（含 INDEX.tsv）>… --exefs <exefs 目录>
      标准输出：匹配上的补丁段，一行一段：模块 / 类别 / 段名 / 写入数 / 许可 / 路径
  cpatch.py plan <产物根> <缺省开的编号（逗号分隔，可空）> <补丁索引目录>…
      写 <产物根>/cpatch_rows.tsv（改写器输入，S2A_CPATCH_TSV）与 <产物根>/cpatch.tsv（装载器表）；标准错误：收 / 不收与原因
  cpatch.py prune <产物根>
      读各模块 <模块>.gaps.tsv 里的 cpatch 缺口，把出缺口的补丁记进 <产物根>/cpatch_excluded.tsv；退出码 0 = 没有要剔的，
      10 = 剔了：调用方重跑 plan（冲突重新判：被剔的那份让出位置，先前因与它冲突落选的可以轮上）再重跑改写
cpatch_rows.tsv：w|p <模块> <偏移> <原字> <新字> [位] # <编号>
cpatch.tsv：编号 / 模块 / 位 / 类别 / 段名 / 许可 / 来源 / 数据写入（偏移:原字节:新字节，空格分隔；偏移是模块映像偏移）/ 缺省开（0/1）/ 目标帧率 / 画幅（宽 ÷ 高）
编号：<widescreen|fps|gfx>:<补丁内容 sha256 前 16 位，没有用包内路径散列>，与启动器 pack/jobs/community.py 同一算法
pchtxt：@nsobid-<构建号>；行首偏移是含 0x100 文件头的偏移，@flag offset_shift <整数> 从该行起加位移（常见 0x100 即行首就是映像偏移）；@enabled / @disabled 开一段、空行收段、@stop 整个文件到此为止；
  只收字节行（偏移 + 十六进制），字符串行 / 模板占位（{hex1}）/ 其他写法的段整段不收。IPS / IPS32：文件名是构建号，偏移含 0x100 文件头"""
import bisect, csv, glob, hashlib, math, os, re, shutil, struct, subprocess, sys, tempfile
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '../tools')); from nso_plain import plain as _nso_plain   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段，不各写一份解码（tools/nso_plain.py）

HDR = 0x100   # NSO 文件头：IPS 与不带 offset_shift 的 pchtxt 偏移都含它


def module_bid(path):
    """NSO 头 0x40 起 32 字节的构建号（十六进制大写，去掉尾部 0 字节）"""
    return trim(open(path, 'rb').read()[0x40:0x60].hex().upper())


def trim(h):
    h = h.upper()
    while len(h) >= 2 and h.endswith('00'): h = h[:-2]
    return h


def bid_match(ours, patch):
    """补丁写的构建号可短于 32 字节、尾部 0 字节可省（Atmosphere exefs_patches 同口径）"""
    p = trim(patch)
    return len(p) >= 16 and ours.startswith(p)


def parse_pchtxt(text):
    """→ (首个构建号, [{bid, name, enabled, writes, bad}])；每段按自身 bid 匹配。切块即结束上一段，不要求额外 @stop。
    语义同 IPSwitch 规范与 Ryujinx IPSwitchPatcher（11-02 根修，docs/研究/情报/20261028_60帧补丁与宽屏补丁规律.md 2.3 三处出入）：
      @stop：整个文件到此为止（原先只收当前段，之后的 @enabled 会重新开段，作者放在 @stop 后的实验 / 旧版地址被收进包）；
      @flag offset_shift <整数>：十进制或 0x，可为负，从这一行起对后面的行生效（原先全块正则只认 0x100）；行首偏移 + 位移 = 含 0x100 文件头的偏移；
      空行：结束当前段（同 Ryujinx；之后的字节行没有段，不收）。
    """
    blocks, lines, have_bid = [], [], False
    for line in text.splitlines():
        if line.strip().split()[:1] == ['@stop']: break
        if line.strip().startswith('@nsobid'):
            if have_bid: blocks.append('\n'.join(lines)); lines = []
            have_bid = True
        lines.append(line)
    blocks.append('\n'.join(lines))
    secs, first_bid = [], ''
    for block in blocks:
        m = re.search(r'@nsobid-([0-9A-Fa-f]+)', block)
        bid = m.group(1).upper() if m else ''
        cur, name, shift = None, '', 0
        for line in block.splitlines():
            s = line.strip()
            if not s: cur = None; continue
            if s.startswith('//') or s.startswith('#'):
                if s.startswith('//') or s.startswith('#'): name = s.lstrip('/#').strip()
                continue
            if s.startswith('@'):
                w = s.split()[0]
                if w in ('@enabled', '@disabled'): cur = {'bid': bid, 'name': name, 'enabled': w == '@enabled', 'writes': [], 'bad': ''}; secs.append(cur)
                elif w == '@flag':
                    f = s.split()
                    if len(f) >= 3 and f[1] == 'offset_shift':
                        try: shift = int(f[2], 0)
                        except ValueError:
                            if cur is not None: cur['bad'] = cur['bad'] or f'offset_shift 值看不懂：{f[2][:20]}'
                elif not w.startswith('@nsobid'): name = s[1:].strip()
                continue
            if cur is None: continue
            mm = re.match(r'^([0-9A-Fa-f]{8})\s+(\S.*)$', s)
            if not mm: cur['bad'] = cur['bad'] or f'看不懂的行：{s[:40]}'; continue
            v = re.sub(r'\s*//.*$', '', mm.group(2)).strip()
            if not re.fullmatch(r'(?:[0-9A-Fa-f]{2})+', v): cur['bad'] = cur['bad'] or ('字符串 / 模板写法' if v.startswith('"') or '{' in v else f'不是十六进制字节：{v[:20]}'); continue
            off = int(mm.group(1), 16) + shift - HDR
            if off < 0: cur['bad'] = cur['bad'] or '偏移落在文件头里'; continue
            cur['writes'].append((off, bytes.fromhex(v)))
        if not first_bid: first_bid = bid
    return first_bid, secs


def parse_ips(data):
    """→ [(映像偏移, bytes)]；不是 IPS / IPS32 返回 None"""
    if data[:5] == b'PATCH': p, ow, end = 5, 3, b'EOF'
    elif data[:5] == b'IPS32': p, ow, end = 5, 4, b'EEOF'
    else: return None
    out = []
    while p + len(end) <= len(data):
        # 标记也可能是合法偏移；仅末尾（或三字节截断扩展前）才结束。
        if data[p:p + len(end)] == end and len(data) - p - len(end) in (0, 3):
            return out
        if p + ow + 2 > len(data): return None
        off = int.from_bytes(data[p:p + ow], 'big'); n = int.from_bytes(data[p + ow:p + ow + 2], 'big'); p += ow + 2
        if n == 0:
            if p + 3 > len(data): return None
            n = int.from_bytes(data[p:p + 2], 'big'); b = data[p + 2:p + 3] * n; p += 3
        else:
            b = data[p:p + n]; p += n
            if len(b) != n: return None
        if off < HDR: return None
        out.append((off - HDR, b))
    return None   # 没有结束标记 = 截断的补丁（下载 / 拷贝中断），整份不收（审计 #829 F-cpatch-ips-no-eof）


def program_id(npdm):
    b = open(npdm, 'rb').read(); a = struct.unpack_from('<I', b, 0x70)[0]
    return '%016X' % struct.unpack_from('<Q', b, a + 0x10)[0]


def fps_of(*texts):
    """目标帧率：索引 target_fps 列是单个数就用它；否则从路径 / 段名里找「<数> fps」（大小写不论、可带空格或连字符），各处只出现一个数才算；取不到 → None"""
    for t in texts:
        t = (t or '').strip()
        if re.fullmatch(r'\d{2,3}', t): return int(t)
        v = {int(x) for x in re.findall(r'(?<!\d)(\d{2,3})\s*-?\s*fps', t, re.I)}
        if len(v) == 1: return v.pop()
    return None


def aspect_of(col, origin):
    """宽屏补丁的画幅（宽 ÷ 高）：索引 aspect 列（21:9 / 16:10）优先，没有按上游原路径目录名（path_aspect）；取不到 → None"""
    m = re.fullmatch(r'\s*(\d{1,3}(?:\.\d+)?)\s*[:x/]\s*(\d{1,3}(?:\.\d+)?)\s*', col or '')
    if m and float(m[2]) and 0.4 <= float(m[1]) / float(m[2]) <= 6: return float(m[1]) / float(m[2])
    return path_aspect(origin or '')[0]


def romfs_need(path, romfs_roots):
    """补丁要不要 romfs 参数表（我方不打 romfs，要 = 缺）：补丁在「<模组根>/exefs/」下时，同一索引里有「<模组根>/romfs/…」行（不论进没进包）= 要（2）、
    没有 = 不要（0）；不在 exefs/ 目录里（Atmosphere exefs_patches/<名>/<构建号>.ips、压平的路径）看不出模组根 = 判不了（1）"""
    if '/exefs/' not in path: return 1
    return 2 if path.rsplit('/exefs/', 1)[0] in romfs_roots else 0


def scan(index_dirs, exefs, log=None):
    """→ [{module, cat, name, writes, license, path, base}]：程序号（前 13 位，含更新 / 追加内容的号）与模块构建号都对上的补丁段（只收开着的段、没有看不懂的行）。
    只比构建号会串款：sdk 等公共模块各游戏同一份二进制、构建号相同（10-27 暗黑3 的 sdk 匹配上古惑狼 / 奥日的帧率补丁）"""
    pid = program_id(os.path.join(exefs, 'main.npdm'))[:13]
    mods = {f: module_bid(os.path.join(exefs, f)) for f in sorted(os.listdir(exefs)) if f not in ('rtld',) and not f.endswith('.npdm') and os.path.isfile(os.path.join(exefs, f))}
    foreign = []   # 版本对不上的宽屏补丁段（跨版本移植的原料，见函数尾）
    out, skipped, taken = [], {}, {}   # taken：跨目录按编号去重（第二轮合集原样含第一轮文件，两轮同时在盘上时同一份补丁只收一次，否则写入翻倍）；编号 → 选份依据（重复出现时补全判不了的项）
    for base in index_dirs:
        cat = os.path.basename(os.path.normpath(base))
        idx = os.path.join(base, 'INDEX.tsv')
        if not os.path.exists(idx): continue
        seen = set(); rd = csv.DictReader(open(idx, encoding='utf-8', errors='replace'), delimiter='\t')
        # 编号（同启动器 pack/jobs/community.py：表头有 aspect 的是 widescreen、有 target_fps 的是 fps、其余 gfx；补丁内容 sha256 前 16 位，没有就用包内路径散列）
        kind_id = 'widescreen' if 'aspect' in (rd.fieldnames or []) else 'fps' if 'target_fps' in (rd.fieldnames or []) else 'gfx'
        rows = list(rd)
        romfs_roots = {(r.get('path') or '').split('/romfs/')[0] for r in rows if (r.get('title_id') or '').upper()[:13] == pid and '/romfs/' in (r.get('path') or '')}
        for r in rows:
            path = r.get('path') or ''; kind = (r.get('kind') or r.get('type') or '').lower()
            if (r.get('title_id') or '').upper()[:13] != pid: continue
            if path in seen or (r.get('in_pack') or 'yes') != 'yes': continue
            seen.add(path)
            # 社区索引来自下载的包，不当可信清单（审计 #829 F-cpatch-index-trust）：路径规范化后必须仍在索引目录内；
            # 编号取文件内容 SHA-256 前 16 位，索引列（有就核）与内容不符整份不收——合法索引下编号与索引列相同，启动器的编号不变
            root_real = os.path.realpath(base); full = os.path.realpath(os.path.join(base, path))
            if os.path.commonpath([root_real, full]) != root_real or full == root_real:
                skipped['路径逃出索引目录'] = skipped.get('路径逃出索引目录', 0) + 1; continue
            if not os.path.isfile(full): continue
            digest = hashlib.sha256(open(full, 'rb').read()).hexdigest()
            col = (r.get('sha256') or '').strip().lower()
            if col and not (len(col) >= 16 and digest.startswith(col)):
                skipped['索引哈希与内容不符'] = skipped.get('索引哈希与内容不符', 0) + 1; continue
            uid = f"{kind_id}:{digest[:16]}"
            meta = {'fps': fps_of(r.get('target_fps'), path), 'romfs': romfs_need(path, romfs_roots),
                    'aspect': aspect_of(r.get('aspect'), r.get('origin') or path) if kind_id == 'widescreen' else None}   # 画幅变体（运行时按屏幕比例选一份，见 plan）
            if uid in taken:
                m0 = taken[uid]
                if m0['fps'] is None: m0['fps'] = meta['fps']
                if m0['romfs'] == 1: m0['romfs'] = meta['romfs']
                continue
            taken[uid] = meta
            if kind == 'pchtxt' or path.endswith('.pchtxt'):
                _, secs = parse_pchtxt(open(full, encoding='utf-8', errors='replace').read())
                for s in secs:
                    ms = [m for m, b in mods.items() if s['bid'] and bid_match(b, s['bid'])]
                    if not ms:
                        if kind_id == 'widescreen' and s['enabled'] and s['writes'] and not s['bad']:
                            foreign.append(dict(s=s, path=path, base=base, cat=cat, digest=digest, meta=meta, license=r.get('license') or '', origin=r.get('origin') or path))
                        continue
                    if not s['enabled'] or not s['writes']: continue
                    if s['bad']: skipped[s['bad'][:12]] = skipped.get(s['bad'][:12], 0) + 1; continue
                    if meta['fps'] is None: meta['fps'] = fps_of(s['name'])
                    out.append({'module': ms[0], 'cat': cat, 'name': s['name'], 'writes': s['writes'], 'license': r.get('license') or '', 'path': path, 'base': base, 'id': uid, 'meta': meta,
                                'origin': r.get('origin') or path})   # 上游原路径（索引 origin 列，pack/jobs/patches.py；没有就用包内路径）：adapt_families 按它认族
            elif kind == 'fpsl' or path.lower().endswith('.yaml'):   # FPSLocker 配置（pack/fpslocker.py）：只认主程序，文件名是主程序构建号
                bid = os.path.splitext(os.path.basename(path))[0]
                if 'main' not in mods or not (re.fullmatch(r'[0-9A-Fa-f]{16,64}', bid) and bid_match(mods['main'], bid)): continue
                import fpslocker, miniyaml
                text_end, ro, ln, key = module_layout(os.path.join(exefs, 'main'))
                M = ((ln + 15) & ~15) + MIRROR_FPSL
                try:
                    w, rt = fpslocker.convert(miniyaml.load(open(full, encoding='utf-8', errors='replace').read()), (text_end, ro), (M, key))
                except (fpslocker.Unsupported, ValueError) as e:
                    skipped['FPSLocker：' + str(e)[:40]] = skipped.get('FPSLocker：' + str(e)[:40], 0) + 1; continue
                meta = dict(meta, fps=60, ext=True, fpsl=rt)   # ext：代码段尾巴放声明代码、映像结尾放变量（同金手指规则）
                out.append({'module': 'main', 'cat': 'fps', 'name': 'FPSLocker', 'writes': sorted(w.items()), 'license': r.get('license') or '', 'path': path, 'base': base, 'id': uid, 'meta': meta})
            elif kind == 'ips' or path.lower().endswith('.ips'):
                bid = os.path.splitext(os.path.basename(path))[0]
                ms = [m for m, b in mods.items() if re.fullmatch(r'[0-9A-Fa-f]{16,64}', bid) and bid_match(b, bid)]
                if not ms: continue
                w = parse_ips(open(full, 'rb').read())
                if w is None: skipped['IPS 格式不对'] = skipped.get('IPS 格式不对', 0) + 1; continue
                if w: out.append({'module': ms[0], 'cat': cat, 'name': os.path.basename(os.path.dirname(path)), 'writes': w, 'license': r.get('license') or '', 'path': path, 'base': base, 'id': uid, 'meta': meta})
    for k, v in sorted(skipped.items()): print(f'跳过 {v} 段：{k}', file=sys.stderr)
    # 跨版本移植（11-13 维护者：画幅补丁扩大泛化性，帧率 / 金手指不做）：主程序没有任何版本对得上的宽屏补丁时，同款别的版本的宽屏补丁逐段
    #   按「这一处原来是什么」移植到这份主程序（port_writes），移植成的照常进自适应合成。移植不了的（画幅值在新版里找不到）不收
    if foreign and 'main' in mods and not any(c['id'].startswith('widescreen:') and c['module'] == 'main' for c in out):
        mp = os.path.join(exefs, 'main'); text_end, ro, ln, key = module_layout(mp)
        _, segs = nso_image(mp); im = bytearray(ln)
        for mo, d in segs: im[mo:mo + len(d)] = d
        im = bytes(im); done = set()
        for f in foreign:
            s = f['s']; key2 = (f['digest'], s['name'])
            if key2 in done: continue
            done.add(key2)
            As = single_aspects({'origin': f['origin'], 'path': f['path'], 'meta': f['meta']})
            if not As: continue
            A = max(As, key=lambda B: (lambda r: len(r[0]) + 2 * len(r[1]))(aspect_classify(s['writes'], B)))
            got, why = port_writes(s['writes'], A, im, text_end)
            tag = f"widescreen:{f['digest'][:16]}"
            if log is not None: log.append(f"{'移植' if got else '移植不了'}\t{tag}\tmain\t{s['name'][:40]}\t自 {s['bid'][:16]} → {mods['main'][:16]}：" + '；'.join(why))
            if not got: continue
            out.append({'module': 'main', 'cat': f['cat'], 'name': s['name'], 'writes': got, 'license': f['license'], 'path': f['path'], 'base': f['base'],
                        'id': tag, 'meta': dict(f['meta'], ported=s['bid'][:16]), 'origin': f['origin']})
    return out



# —— 自适应画幅（11-12 夜，维护者：「满屏不只是宽屏或窄屏，是自适应满屏」）——
# 同一来源按画幅批量生成的一族宽屏补丁（如 0100F2C0115B6000 的一族：1:1 … 48:9 共 13 种，同一份 main）只差「随画幅变的值」。出包时把一族合成两份：
#   宽模板（画幅 > 16:9 的那些）与窄模板（< 16:9），各自里逐字比各变体：都一样 = 模板字；不一样 = 画幅值，按 A（画幅）、A÷(16/9)、(16/9)÷A、1÷A 拟合，
#   拟合不上整族不合成（各份照旧单独进包）。画幅值三种写法，都改成读键页值槽（槽 ADAPT_SLOT0 起 8 个：宽屏值区 16–1023 的顶上，pack 核本模块宽屏点数够不着）：
#     fmov 立即数（只能编约 2 位有效数字，原补丁 16:10 写成 1.625）→ p 行「@k」：改写器先 adrp x16 到键页再 ldr <St>, [x16, #槽×8]
#     补丁代码里的浮点字面量（adrp Xn + ldr <St>, [Xn, #lo] 读它）→ 读它的那对改指值槽：在填充区的写成 w 行 adrp「@k」+ ldr [Xn, #槽×8]；在原代码上的 ldr 改 p 行「@k」
#     ro / data 浮点 → 数据写入「偏移:原字节:@<式><字节数>」；值槽本身是「k<槽>::@<式><字节数>」。运行时按当前画幅算（runtime/src/cpatch.c）
#   宽 / 窄两份是兄弟（编号 wsauto:<族>:w / :n）：运行时按当前画幅只开一份；改写器同点可挂两路（各一位）。填充区新代码两套写在同一空隙且不同时，
#     窄模板的填充区代码整段挪到别的零空隙（PC 相对的跳转 / adrp 按新位置重编，原代码上的挂钩跟着改指新处 → 与宽模板成同点两路）。启动器只列一项 wsauto:<族>
ADAPT_R = 16 / 9
ADAPT_F = {'a': lambda A: A, 'w': lambda A: A / ADAPT_R, 'n': lambda A: ADAPT_R / A, 'i': lambda A: 1 / A}
ADAPT_SLOT0, ADAPT_NSLOT = 1016, 8   # runtime/src/widen.c 宽屏值槽 WSLOT 16 起按点序号用，最多 WMAX 1008 个；这里取顶上 8 个，本模块宽屏点超过 1000 个就不合成
_ASP_RE = re.compile(r"(?<![\d.])(\d{1,3}(?:\.\d+)?)[-:x'](\d{1,3}(?:\.\d+)?)(?![\d.])")   # 21-9 / 21:9 / 21x9 / 21'9（有的库目录名用撇号）
# 目录名只写分辨率的（11-13：一个超宽屏补丁库按「[3440x1440 21.9 Ultrawide v…]」「[1680x1050 16.10 v…]」分目录，画幅写成 21.9 认不出）：
#   取「宽x高」（各 3–5 位）算画幅，比名义画幅准（3440×1440 = 2.389，补丁里写的正是这个数）；族按整段目录名认（同一档案里各分辨率目录互为变体）
_RES_RE = re.compile(r'(?<![\d.])(\d{3,5})[x×](\d{3,5})(?![\d.])')


def path_aspect(path):
    """路径各级目录名里第一个像画幅的「宽-高」→ (画幅, 目录里的原样写法)；没有画幅写法、只有「宽x高」分辨率的 → (画幅, 整段目录名)；都没有 → (None, None)"""
    segs = path.split('/')[:-1]
    for seg in segs:
        for m in _ASP_RE.finditer(seg):
            a, b = float(m[1]), float(m[2])
            if b and 0.4 <= a / b <= 6: return a / b, m[0]
    for seg in segs:
        for m in _RES_RE.finditer(seg):
            a, b = int(m[1]), int(m[2])
            if b and 0.4 <= a / b <= 6: return a / b, seg
    return None, None


def _mov_imm(w):
    """MOVZ / MOVK 立即数（32 / 64 位）→ (形状 = 去掉立即数的字, 立即数, 移位档 hw, 目标寄存器)；不是 → None"""
    if w is None or (w & 0x1F800000) != 0x12800000 or (w >> 29) & 3 not in (2, 3): return None
    return w & ~(0xFFFF << 5), (w >> 5) & 0xFFFF, (w >> 21) & 3, w & 31


def _res_ok(a, b, A):
    """一对 MOV 立即数（_mov_imm 结果）像不像渲染尺寸：宽 ÷ 高 = A（1%）、宽 160–8192、高 90–8192，且不是「movz 低半 + movk hw1 高半」拼单精度
    （11-13 体检：一款 movz w9,#0x5555 / movk w9,#0x4015,lsl 16 = 2.333，被当成 21845×16405 的渲染尺寸）"""
    if not a or not b or not b[1] or a[2]: return False
    if b[2] == 1 and (b[0] >> 29) & 3 == 3 and b[3] == a[3]: return False
    return 160 <= a[1] <= 8192 and 90 <= b[1] <= 8192 and abs(a[1] / b[1] - A) <= 0.01 * A


def _res_pairs(offs, wm, As):
    """各变体里「宽 ÷ 高 = 该变体画幅」的一对 MOV 立即数（渲染尺寸：宽 hw 0、两条都是立即数）→ {宽偏移: 高偏移}。
    只认比例、不认值：PC 模拟器补丁的渲染尺寸各份高度不同（1050 / 1440 …），按画幅拟合不上，按「宽高比 = 画幅」认得出"""
    mv = {o: [_mov_imm(x.get(o)) for x in wm] for o in offs}
    mv = {o: v for o, v in mv.items() if all(v)}
    out = {}
    for o, v in mv.items():
        if any(q[2] for q in v): continue
        for p, h in mv.items():
            if p == o or p in out.values() or not all(q[1] for q in h): continue
            if all(_res_ok(a, b, A) for a, b, A in zip(v, h, As)): out[o] = p; break
    return out


def _fmov_imm(w):
    """fmov <Sd|Dd>, #imm → (精度 's'/'d', 寄存器)；不是 → None"""
    if w & 0xFFE01FE0 not in (0x1E201000, 0x1E601000): return None
    return ('d' if w & 0x00400000 else 's', w & 31)


def _fmov_val(w):
    """fmov 立即数 imm8 = a:b:cd:efgh 的值（VFPExpandImm）：符号 a，指数按单精度 NOT(b):bbbbb:cd − 127，尾数 1.efgh"""
    imm8 = (w >> 13) & 0xFF; b6 = (imm8 >> 6) & 1
    exp8 = ((b6 ^ 1) << 7) | ((0x1F if b6 else 0) << 2) | ((imm8 >> 4) & 3)
    v = (1 + (imm8 & 15) / 16) * 2.0 ** (exp8 - 127)
    return -v if imm8 >> 7 else v


def _fit(As, vs, tol, only=None):
    """各点都落在同一个画幅式上 → 式名；only 给了只试它（单画幅那侧借另一侧认出的式）"""
    for k, f in ((only, ADAPT_F[only]),) if only else ADAPT_F.items():
        if all(abs(v - f(A)) <= tol * max(1.0, abs(f(A))) for A, v in zip(As, vs)): return k
    return None


def _movpair(w0, w1):
    """movz Wd, #lo + movk Wd, #hi, lsl 16（相邻两条拼一个单精度）→ (Wd, 浮点值)；不是 → None"""
    if w0 is None or w1 is None or w0 & 0xFFE00000 != 0x52800000 or w1 & 0xFFE00000 != 0x72A00000 or (w0 ^ w1) & 31: return None
    return w0 & 31, struct.unpack('<f', struct.pack('<I', (((w1 >> 5) & 0xFFFF) << 16) | ((w0 >> 5) & 0xFFFF)))[0]


def _ldr_imm(w):
    """ldr <Rt>, [<Xn>, #imm]（无符号偏移；整数 32/64 位、浮点 S/D）→ (Rn, 偏移, 是否浮点, 字节数, Rt)；不是 → None"""
    if w & 0x3B400000 != 0x39400000 or (w >> 23) & 1: return None
    size = w >> 30; v = (w >> 26) & 1
    if not v and size < 2: return None
    return ((w >> 5) & 31, ((w >> 10) & 0xFFF) << size, bool(v), 1 << size, w & 31)


def _ldr_slot(w, slot):
    """ldr 的偏移换成键页槽 slot（×8 字节）；基址寄存器不变"""
    size = w >> 30
    return (w & ~(0xFFF << 10)) | (((slot * 8) >> size) << 10)


def _sx(v, bits): return v - (1 << bits) if v & (1 << (bits - 1)) else v


def _pcrel(w, pc):
    """PC 相对指令 → (种类, 目标)；adrp 的目标是页；不是 → None"""
    if w & 0x7C000000 == 0x14000000: return 'b', pc + _sx(w & 0x3FFFFFF, 26) * 4
    if w & 0xFF000010 == 0x54000000 or w & 0x7E000000 == 0x34000000: return 'c19', pc + _sx((w >> 5) & 0x7FFFF, 19) * 4
    if w & 0x7E000000 == 0x36000000: return 't14', pc + _sx((w >> 5) & 0x3FFF, 14) * 4
    if w & 0x3B000000 == 0x18000000: return 'c19', pc + _sx((w >> 5) & 0x7FFFF, 19) * 4   # LDR 字面量
    if w & 0x9F000000 == 0x10000000: return 'adr', pc + _sx((((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3), 21)
    if w & 0x9F000000 == 0x90000000: return 'adrp', (pc & ~0xFFF) + (_sx((((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3), 21) << 12)
    return None


def _pcrel_set(w, kind, pc, t):
    """把 PC 相对指令 w（种类 kind）放在 pc、指向 t 重编；够不着 → ValueError"""
    def chk(v, bits):
        if not -(1 << (bits - 1)) <= v < (1 << (bits - 1)): raise ValueError(f'{pc:#x} 处 PC 相对指令够不着 {t:#x}')
        return v & ((1 << bits) - 1)
    if kind == 'b': return (w & 0xFC000000) | chk((t - pc) >> 2, 26)
    if kind == 'c19': return (w & ~(0x7FFFF << 5)) | (chk((t - pc) >> 2, 19) << 5)
    if kind == 't14': return (w & ~(0x3FFF << 5)) | (chk((t - pc) >> 2, 14) << 5)
    d = chk(t - pc if kind == 'adr' else (t >> 12) - (pc >> 12), 21)
    return (w & 0x9F00001F) | ((d & 3) << 29) | ((d >> 2) << 5)


def _relocate(words, marks, im, fill_ok, avoid, text_end):
    """words（偏移 → 字）里填充区的连续段整段挪到别的零空隙（与原段同 16 字节对齐余数、不碰 avoid）；PC 相对的按新位置重编（目标在挪走的段里的跟着挪）。
    marks：偏移 → 'k'（w 行 adrp @k，改写器按位置重编，不动）/ 'kv'（p 行 @k）。→ (新 words, 新 marks)；挪不了 → ValueError"""
    fo = sorted(o for o in words if fill_ok(o))
    caves = []
    for o in fo:
        if caves and o == caves[-1][1]: caves[-1][1] = o + 4
        else: caves.append([o, o + 4])
    used = set(avoid) | set(words)
    zr = [(m.start(), m.end()) for m in re.finditer(rb'(?:\x00\x00\x00\x00)+', bytes(im[:text_end])) if m.end() - m.start() >= 8]
    delta = {}
    for c0, c1 in caves:
        n = c1 - c0; got = None
        for z0, z1 in zr:
            s = (z0 & ~15) | (c0 & 15)
            if s < z0: s += 16
            while s + n <= z1 and got is None:
                if all(x not in used for x in range(s, s + n, 4)): got = s
                s += 16
            if got is not None: break
        if got is None: raise ValueError(f'找不到放 {c0:#x}+{n} 的零空隙')
        used |= set(range(got, got + n, 4)); delta[(c0, c1)] = got - c0
    def mv(x):
        for (c0, c1), d in delta.items():
            if c0 <= x < c1: return x + d
        return x
    out, om = {}, {}
    for o, w in words.items():
        np_ = mv(o); k = marks.get(o)
        if k != 'k':
            r = _pcrel(w, o)
            if r:
                kind, tg = r
                if kind == 'adrp':   # 与下一条 ldr / add 成对：按完整目标挪
                    nx = words.get(o + 4); l = _ldr_imm(nx) if nx is not None else None
                    if l and l[0] == (w & 31):
                        full = tg + l[1]; nf = mv(full)
                        if nf != full:
                            w = _pcrel_set(w, 'adrp', np_, nf & ~0xFFF); size = nx >> 30
                            if (nf & 0xFFF) % (1 << size): raise ValueError(f'{o:#x} 的 adrp + ldr 挪后偏移不对齐')
                            words[o + 4] = (nx & ~(0xFFF << 10)) | (((nf & 0xFFF) >> size) << 10)
                            out[np_] = w; om[np_] = k; continue
                    w = _pcrel_set(w, 'adrp', np_, mv(tg) & ~0xFFF if mv(tg) != tg else tg)
                else: w = _pcrel_set(w, kind, np_, mv(tg))
        out[np_] = w
        if k: om[np_] = k
    return out, om


def _other_mode(im, text_end, words, pairs):
    """补丁只改了一档渲染尺寸（PC 补丁多半只改主机档）：在原代码里找另一档 → [(宽偏移, 高偏移, 原宽, 原高, 原比)]。
    pairs = 补丁改的那几对 [(宽偏移, 高偏移)]（原指令须是 MOV 立即数）。认法（只看游戏原代码）：那对宽偏移前后 0x80 字节内、补丁没改的
    MOVZ 宽（hw 0、≥ 160）+ 同目标寄存器的 MOV 立即数高，原宽高比与补丁那对的原比相同（2%）、尺寸更小（另一档 = 掌机档）。
    11-13 一款：主机档 1600×900（x8）、掌机档 1280×720（x9），游戏按「主机尺寸 × 0.8」算掌机视口——补丁只改主机档时掌机下渲染目标与视口对不上"""
    out = []
    for o, p in pairs:
        a, b = _mov_imm(int.from_bytes(im[o:o + 4], 'little')), _mov_imm(int.from_bytes(im[p:p + 4], 'little'))
        if not a or not b or not b[1]: continue
        for o2 in range(max(0, o - 0x80), min(text_end, o + 0x84), 4):
            if o2 in words or any(o2 in (x[0], x[1]) for x in out): continue
            c = _mov_imm(int.from_bytes(im[o2:o2 + 4], 'little'))
            if not c or c[2] or c[1] < 160 or c[1] >= a[1]: continue
            for p2 in range(max(0, o2 - 0x40), min(text_end, o2 + 0x44), 4):
                if p2 == o2 or p2 in words: continue
                d = _mov_imm(int.from_bytes(im[p2:p2 + 4], 'little'))
                if d and d[3] == c[3] and d[1] and abs(c[1] / d[1] - a[1] / b[1]) <= 0.02 * a[1] / b[1]:
                    out.append((o2, p2, c[1], d[1], d[1] / b[1])); break
            if out and out[-1][0] == o2: break
    return out


def _fill_other_mode(im, text_end, words, marks, ks, pairs, slot, log, tag):
    """补上另一档：宽改读值槽（运行时 = 高 × 当前画幅取偶，高随值槽式带在 @y4/<高> 里），高 = 手机口径 PHONE_H × 原两档之比。→ 补了几对"""
    n = 0
    for o2, p2, w2, h2, r in _other_mode(im, text_end, words, pairs):
        H2 = max(2, int(round(PHONE_H * r / 2)) * 2)
        words[o2] = _ldr_slot(0xB9400000 | (16 << 5) | (int.from_bytes(im[o2:o2 + 4], 'little') & 31), slot(f'y{H2}', 'i')); marks[o2] = 'kv'; ks[o2] = 'y'
        x = int.from_bytes(im[p2:p2 + 4], 'little'); words[p2] = (x & ~(0xFFFF << 5)) | (H2 << 5); ks[p2] = 'h'
        log.append(f'补另一档\t{tag}\tmain\t原 {w2}×{h2}（补丁改的那档的 {r:.3f} 倍）→ 高 {H2}、宽 = {H2} × 画幅（+{o2:#x} / +{p2:#x}）'); n += 1
    return n


def adapt_families(cands, exefs, log, root=None):
    """宽屏候选里按画幅成族的合成自适应两份，替换掉族里各份；合成不了的族原样留下（原因进 log）"""
    fam = {}
    for c in cands:
        if not c['id'].startswith('widescreen:'): continue
        org = c.get('origin') or c['path']
        A, tok = path_aspect(org)
        if A is None: continue
        whole = not _ASP_RE.search(tok)   # 按分辨率认的（path_aspect 返回整段目录名）：整段目录名就是变体名，段名（各份注释不同：「HUD is adjusted to 21:9」「USE 8GB DRAM MEMORY LAYOUT」）不进族键
        key = (c['module'], org.replace(tok, '{A}', 1), '' if whole else _ASP_RE.sub('{A}', c['name']), c['base'])   # 段名里的画幅写法可与目录不同（目录 21'9、段名 21:9）
        px = 0
        if whole:
            m = _RES_RE.search(tok); px = int(m[1]) * int(m[2])
        fam.setdefault(key, []).append((A, c, px))
    every = {k: [c for _, c, _ in v] for k, v in fam.items()}   # 去重前的全部份（档位取众数按全部份算）
    dup = {}   # 族键 → 同画幅落下的几份：族合成成了就一起换掉（自适应已覆盖这些画幅），合成不了照旧单独进包
    for key, ms in fam.items():   # 同画幅多份（3440×1440 与 5160×2160 都是 21:9）：只留像素最少的一份
        keep = {}
        for A, c, px in ms:
            k = round(A, 3)
            if k not in keep or px < keep[k][2]: keep[k] = (A, c, px)
        if len(keep) < len(ms): log.append(f'同画幅只取一份\t{key[1][-60:]}\t{len(ms)} 份 → {len(keep)} 种画幅（各画幅留像素最少的那份）')
        kept = {id(c) for _, c, _ in keep.values()}; dup[key] = [c for _, c, _ in ms if id(c) not in kept]
        fam[key] = [(A, c) for A, c, _ in keep.values()]
    allw = set()
    for c in cands:
        for off, b in c['writes']: allw |= set(range(off & ~3, off + len(b), 4))
    drop, out = set(), []
    for (mod, ptn, nm, base), ms in fam.items():
        if len({A for A, _ in ms}) < 3: continue
        losers = dup.get((mod, ptn, nm, base), [])
        fid = hashlib.sha256(ptn.encode()).hexdigest()[:12]
        text_end, ro, ln, key = module_layout(os.path.join(exefs, mod))
        _, segs = nso_image(os.path.join(exefs, mod)); im = bytearray(ln)
        for mo, d in segs: im[mo:mo + len(d)] = d
        code_end = (text_end + 0x3FFF) & ~0x3FFF
        isfill = lambda o: o < text_end and fill(im, o)
        why, slots, sides = '', {}, {}
        nwid = 0
        wp = os.path.join(root or '', 'widen_sites.tsv')
        if root and os.path.exists(wp): nwid = sum(1 for l in open(wp) if l.split('\t')[0] == mod and l.split('\t')[1:2] and l.split('\t')[1].startswith('0x'))
        if nwid > ADAPT_SLOT0 - 16: log.append(f'不合成\twsauto:{fid}\t{mod}\t{ptn[-60:]}\t本模块宽屏点 {nwid} 个，值槽与宽屏槽会重叠'); continue
        def slot(k, prec):
            if (k, prec) not in slots:
                if len(slots) >= ADAPT_NSLOT: raise ValueError('值槽不够')
                slots[(k, prec)] = ADAPT_SLOT0 + len(slots)
            return slots[(k, prec)]
        # 不随画幅变的 MOV 立即数各份不同（显存上限 896 / 1024 MiB、阴影贴图 1K / 2K / 4K：PC 补丁按各自分辨率顺带给的画质 / 预算档）：整族取最接近游戏原值的一档
        #   （原指令不是 MOV 立即数的取最小），宽 / 窄两套模板一致。我们要的是满屏，不是顺带提画质：越贴近游戏原样越稳。
        #   11-13 实测（Mac 主机模式）：取最大 → 显存 1024 MiB（那份写明要 8 GB 内存布局）起局断言崩溃；取众数 → 阴影 4K、同一处断言崩溃；
        #   不带阴影行的 21:9 那版（阴影 = 原值 1K、显存 896）稳定 120 帧。取舍进 log
        fam_max, wmx = {}, {}
        for c in every.get((mod, ptn, nm, base), [c for _, c in ms]):
            for off, b in c['writes']:
                for k, v in enumerate(b):
                    o = off + k; w0 = o & ~3; wmx.setdefault(id(c), {}).setdefault(w0, bytearray(im[w0:w0 + 4]))[o - w0] = v
        allv = [{o: int.from_bytes(v, 'little') for o, v in d.items()} for d in wmx.values()]
        for o in set().union(*allv) if allv else ():
            vs = [d.get(o) for d in allv]; mv = [_mov_imm(v) for v in vs]
            if all(mv) and len({q[1] for q in mv}) > 1 and len({(q[0], q[2]) for q in mv}) == 1:
                orig = _mov_imm(int.from_bytes(im[o:o + 4], 'little'))
                base_v = orig[1] if orig and orig[2] == mv[0][2] else None   # 原指令同移位档的 MOV 立即数才比距离
                fam_max[o] = min(set(vs), key=lambda v: (abs(_mov_imm(v)[1] - base_v) if base_v is not None else 0, _mov_imm(v)[1]))
        try:
            # 一侧只有一种画幅（如窄侧只有 16:10）：拟合不出式，借另一侧（≥2 种、式已验证）在同一位置认出的式，本侧的值也要落在那个式上才收
            sms = {side: sorted(((A, c) for A, c in ms if sel(A)), key=lambda x: x[0])
                   for side, sel in (('w', lambda A: A > ADAPT_R * 1.001), ('n', lambda A: A < ADAPT_R * 0.999))}
            for side in sorted(sms, key=lambda s: len(sms[s]) < 2):
                sm = sms[side]; ref = None
                if not sm: continue
                if len(sm) < 2:
                    ref = next((S['ks'] for S in sides.values()), None)
                    if ref is None: continue
                As = [A for A, _ in sm]; wm = []
                for A, c in sm:
                    w = {}
                    for off, b in c['writes']:
                        for k, v in enumerate(b):
                            o = off + k; w0 = o & ~3; w.setdefault(w0, bytearray(im[w0:w0 + 4]))[o - w0] = v
                    wm.append({o: int.from_bytes(v, 'little') for o, v in w.items()})
                offs = set(wm[0])
                if any(set(x) != offs for x in wm): raise ValueError(f'{side} 模板各变体改的位置不一样')
                words, marks, adata, lits, ks, skip = {}, {}, [], {}, {}, set()
                rp = _res_pairs(offs, wm, As)
                if ref is not None: rp = {o: p for o, p in rp.items() if ref.get(o) == 'x' and ref.get(p) == 'h'}
                elif any(len({_mov_imm(x[o])[1] for x in wm}) < 2 for o in rp): rp = {o: p for o, p in rp.items() if len({_mov_imm(x[o])[1] for x in wm}) > 1}
                for o in sorted(offs):
                    if o in skip: continue
                    ws = [x[o] for x in wm]; only = ref.get(o) if ref is not None else None
                    # 渲染尺寸（宽 ÷ 高 = 画幅的一对 MOV）：高写死手机口径 PHONE_H，宽改成读值槽（运行时 = PHONE_H × 当前画幅，取偶），同 phone_res 的口径
                    if o in rp:
                        if o >= text_end or isfill(o): raise ValueError(f'{side} 模板 {mod}+{o:#x} 的渲染宽度不在原代码上')
                        words[o] = _ldr_slot(0xB9400000 | (16 << 5) | (ws[0] & 31), slot('x', 'i')); marks[o] = 'kv'; ks[o] = 'x'; continue
                    if o in rp.values():
                        words[o] = (ws[0] & ~(0xFFFF << 5)) | (PHONE_H << 5); ks[o] = 'h'; continue
                    pr = [_movpair(x[o], x.get(o + 4)) for x in wm]   # movz / movk 拼单精度：改成从槽读整字、movk 换 nop
                    if o < text_end and all(pr) and len({q[0] for q in pr}) == 1 and (ref is not None or len({q[1] for q in pr}) > 1):
                        k = _fit(As, [q[1] for q in pr], 2e-3, only)
                        if k and (ref is None or only):
                            if isfill(o): raise ValueError(f'{side} 模板 {mod}+{o:#x} 的 movz / movk 在填充区')
                            words[o] = _ldr_slot(0xB9400000 | (16 << 5) | pr[0][0], slot(k, 's')); marks[o] = 'kv'; ks[o] = k
                            words[o + 4] = 0xD503201F; skip.add(o + 4); continue
                        if ref is None: raise ValueError(f'{side} 模板 {mod}+{o:#x} 的 movz / movk 值拟合不上画幅')
                    if all(v == ws[0] for v in ws) and not only:
                        words[o] = fam_max.get(o, ws[0]); continue
                    fm = [_fmov_imm(v) for v in ws]
                    if o < text_end and all(fm) and len(set(fm)) == 1:
                        k = _fit(As, [_fmov_val(v) for v in ws], 0.07, only)
                        if not k: raise ValueError(f'{side} 模板 {mod}+{o:#x} 的 fmov 立即数拟合不上画幅')
                        prec, rt = fm[0]
                        if isfill(o): raise ValueError(f'{side} 模板 {mod}+{o:#x} 的 fmov 在填充区')
                        words[o] = _ldr_slot((0xBD400000 if prec == 's' else 0xFD400000) | (16 << 5) | rt, slot(k, prec)); marks[o] = 'kv'; ks[o] = k; continue
                    k = _fit(As, [struct.unpack('<f', struct.pack('<I', v))[0] for v in ws], 2e-3, only)
                    if not k and o in fam_max: words[o] = fam_max[o]; continue
                    if not k: raise ValueError(f'{side} 模板 {mod}+{o:#x} 的值拟合不上画幅')
                    ks[o] = k
                    if o < code_end: lits[o] = k
                    else: adata.append((o, 4, k))
                for o, k in lits.items():   # 读字面量的：adrp Xn + ldr <St>, [Xn, #lo]（相邻两条）
                    rd = []
                    for q, wq in words.items():
                        l = _ldr_imm(wq); pa = words.get(q - 4)
                        r = _pcrel(pa, q - 4) if l and l[2] and pa is not None else None
                        if r and r[0] == 'adrp' and (pa & 31) == l[0] and r[1] + l[1] == o: rd.append((q, l))
                    if not rd: raise ValueError(f'{side} 模板 {mod}+{o:#x} 的画幅字面量找不到读它的 adrp + ldr')
                    for q, l in rd:
                        s = slot(k, 's' if l[3] == 4 else 'd')
                        if isfill(q) and isfill(q - 4): words[q - 4] = 0x90000000 | l[0]; marks[q - 4] = 'k'; words[q] = _ldr_slot(words[q], s)
                        elif not isfill(q): words[q] = _ldr_slot((words[q] & ~(31 << 5)) | (16 << 5), s); marks[q] = 'kv'
                        else: raise ValueError(f'{side} 模板 {mod}+{q:#x} 的读字面量 ldr 在填充区、adrp 不在')
                rpairs = [(o, q) for o, q in rp.items()]
                if rpairs and not any(v == 'y' for v in ks.values()): _fill_other_mode(im, text_end, words, marks, ks, rpairs, slot, log, f'wsauto:{fid}:{side}')
                sides[side] = dict(sm=sm, words=words, marks=marks, adata=adata, ks=ks)
            if not sides: raise ValueError('宽 / 窄两侧都不足两种画幅')
            if 'w' in sides and 'n' in sides:
                W, N = sides['w'], sides['n']
                clash = [o for o in N['words'] if isfill(o) and o in W['words'] and (W['words'][o] != N['words'][o] or W['marks'].get(o) != N['marks'].get(o))]
                if clash:
                    avoid = allw | set(W['words'])
                    N['words'], N['marks'] = _relocate(dict(N['words']), N['marks'], im, isfill, avoid, text_end)
                    left = [o for o in N['words'] if o in W['words'] and isfill(o) and W['words'][o] != N['words'][o]]
                    if left: raise ValueError(f'挪位后仍有填充区冲突 {left[0]:#x}')
                    log.append(f'挪位\twsauto:{fid}\t{mod}\t窄模板填充区代码挪到别的零空隙（与宽模板冲突 {len(clash)} 字）')
        except ValueError as e:
            log.append(f'不合成\twsauto:{fid}\t{mod}\t{ptn[-60:]}\t{e}'); continue
        sl = [(f'k{s}', f'4/{k[1:]}' if k.startswith('y') else 8 if prec == 'd' else 4, k[:1]) for (k, prec), s in sorted(slots.items(), key=lambda x: x[1])]
        made = []
        for side, S in sides.items():
            c0 = S['sm'][0][1]
            made.append(dict(module=mod, cat=c0['cat'], name=f'自适应满屏（{len(ms)} 种画幅合成 · {"宽" if side == "w" else "窄"}屏模板）',
                             writes=sorted((o, w.to_bytes(4, 'little')) for o, w in S['words'].items()), license=c0['license'], path=ptn, base=base,
                             id=f'wsauto:{fid}:{side}', meta=dict(c0['meta'], adapt=dict(side=side, marks=S['marks'], adata=S['adata'] + sl))))
        drop |= {id(c) for _, c in ms} | {id(c) for c in losers}; out += made
        took = sorted(o for S in sides.values() for o, w in S['words'].items() if o in fam_max and w == fam_max[o] and S['ks'].get(o) not in ('x', 'h'))
        if took: log.append(f'取常用档\twsauto:{fid}\t{mod}\t不随画幅变、各份不同的立即数取最接近游戏原值的一档（原值不是立即数取最小）：' + '、'.join(f'+{o:#x} = {_mov_imm(fam_max[o])[1]:#x}' for o in sorted(set(took))))
        log.append(f'合成\twsauto:{fid}\t{mod}\t{ptn[-60:]}\t{len(ms)} 种画幅 → ' + '、'.join(f"{u['id'][-1]} 模板 {len(u['writes'])} 字（读值槽 {sum(1 for v in u['meta']['adapt']['marks'].values())} 处）" for u in made) + f'，值槽 {len(slots)} 个')
    # 单份认值（11-13 补丁库体检：808 份宽屏补丁里 7 成「游戏 + 版本」只有一种画幅，多份对比合成覆盖不到）：没进上面合成的宽屏补丁，
    #   逐份认出值落在它自己画幅式上的写入（tools/ws_wash.py 同一规则）改成读值槽，渲染尺寸对按手机口径，其余照原样；认不出的原样留下
    #   同模块改同几处的别的定画幅变体（同款不同画幅 / 不同作者）已由它覆盖：一并去掉。代表那份挑画幅最接近手机屏（约 2.17）的
    #   宽 / 窄两侧分开挑代表：宽侧挑比 16:9 宽、最接近手机屏 2.17 的，窄侧挑比 16:9 窄、最接近平板 4:3 的；某一侧没有补丁就用另一侧的代表外推
    #   （同一画幅式；11-13 一款只有 21:9 / 32:9 补丁，外推到 1.594 全屏与关补丁同条件公平对照帧率相同——先前「外推就掉到 12.5 帧」是对照局没按键、
    #   停在标题画面，不同场景所致，关补丁进同一场景一样掉）。两侧同一族号（设置里一项）
    rest = [c for c in cands if id(c) not in drop and c['id'].startswith('widescreen:')]
    # 自相矛盾的补丁不收（11-13 体检：781 份能定画幅的里 47 份，多是一家作者「从 21:9 自动生成的窄屏 WIP 版」——界面比例改成 3:2，世界比例还是 2.389）：
    #   各处认出的画幅值要指向同一个画幅；另有画幅能认出主画幅认不出的写入 → 整份不收（不参数化、也不当定画幅变体进包）
    for c in list(rest):
        sus = aspect_conflict(c)
        if sus: rest.remove(c); drop.add(id(c)); log.append(f'可疑不收\t{c["id"]}\t{c["module"]}\t{c["name"][:40]}\t{sus}')
    A0 = lambda c: (single_aspects(c) or [ADAPT_R])[0]
    for mod in sorted({c['module'] for c in rest}):
        mc = [c for c in rest if c['module'] == mod]; made, fid = {}, None
        for side, sel, goal in (('w', lambda A: A > ADAPT_R * 1.001, 2.17), ('n', lambda A: A < ADAPT_R * 0.999, 4 / 3)):
            for c in sorted((c for c in mc if sel(A0(c))), key=lambda c: abs(math.log(A0(c) / goal))):
                u = _adapt_single(c, exefs, log, root, side, fid)
                if u: made[side] = (c, u); fid = u['id'].split(':')[1]; break
        for side, other in (('w', 'n'), ('n', 'w')):   # 缺的一侧用另一侧的代表外推
            if side not in made and other in made:
                u = _adapt_single(made[other][0], exefs, log, root, side, fid)
                if u: made[side] = (made[other][0], u)
        if not made: continue
        out += [u for _, u in made.values()]
        cov = set()
        for c, _ in made.values(): cov |= {(off + k) & ~3 for off, b in c['writes'] for k in range(len(b))}
        for c in mc:
            if any(c is x for x, _ in made.values()): drop.add(id(c)); continue
            if {(off + k) & ~3 for off, b in c['writes'] for k in range(len(b))} & cov:
                drop.add(id(c)); log.append(f'已覆盖\t{c["id"]}\t{mod}\t{c["name"][:40]}\t与 wsauto:{fid} 改同几处，由它按屏幕比例自适应')
    return [c for c in cands if id(c) not in drop] + out


# 名义画幅与补丁里实际写的值常不同（21:9 的补丁按 3440×1440 = 43:18 写 2.389、按 2560×1080 = 64:27 写 2.370）：名义 21:9 附带这几种候选（tools/ws_wash.py 同表）
ADAPT_NEAR = {round(21 / 9, 4): (64 / 27, 43 / 18, 12 / 5)}


def aspect_conflict(c):
    """一份宽屏补丁里各处画幅值是否指向不同画幅（候选画幅里认出最多的为主，另有相差 2% 以上的候选能认出主画幅认不出的写入）→ 说明；一致 → ''"""
    As = single_aspects(c)
    rec = {}
    for B in As:
        par, res, _ = aspect_classify(c['writes'], B)
        rec[B] = {o for o, _, _ in par} | {o for o, *_ in res}
    if not rec: return ''
    best = max(rec, key=lambda B: len(rec[B]))
    # 16:9 是游戏原生比例，不算「另一个画幅」：用 16:9 渲染尺寸配宽画面比例（拉伸到窗口）是正当做法（一份「[2560x1440 Ultrawide]」就这么写）
    other = [(B, sorted(rec[B] - rec[best])) for B in rec if abs(B / best - 1) > 0.02 and abs(B / ADAPT_R - 1) > 0.02 and rec[B] - rec[best]]
    return '；'.join(f'画幅值自相矛盾：{len(rec[best])} 处按 {best:.3f}，+{os_[0]:#x} 等 {len(os_)} 处按 {B:.3f}' for B, os_ in other)


def single_aspects(c):
    """单份补丁的候选画幅：上游路径里的分辨率（最准）→ 表里的画幅（索引 aspect 列 / 目录名）→ 名义 21:9 的常见实际值"""
    org = c.get('origin') or c['path']; out = []
    for m in _RES_RE.finditer(org):
        if int(m[2]) and 0.4 <= int(m[1]) / int(m[2]) <= 6: out.append(int(m[1]) / int(m[2]))
    if c['meta'].get('aspect'): out.append(c['meta']['aspect'])
    for A in list(out): out += ADAPT_NEAR.get(round(A, 4), ())
    seen = []
    for A in out:
        if all(abs(A - B) > 1e-6 for B in seen): seen.append(A)
    return seen


def aspect_classify(writes, A):
    """一份宽屏补丁的写入里认出随画幅变的值（只看补丁本身，不要游戏程序；tools/ws_wash.py 体检与跨版本移植共用）：
    → (画幅值 [(字偏移, 写法 fmov / movpair / float, 式)], 渲染尺寸对 [(宽偏移, 高偏移, 宽, 高)], 定值字数)。
    fmov 只能编约 2 位有效数字，容差 0.07，其余 2e-3；渲染尺寸 = 一对 MOV 立即数宽 ÷ 高 = A（1%）、宽 ≥ 160"""
    w = {}
    for off, b in writes:
        for k, v in enumerate(b):
            o = off + k; w.setdefault(o & ~3, {})[o & 3] = v
    words = {o: int.from_bytes(bytes(d.get(i, 0) for i in range(4)), 'little') for o, d in w.items() if len(d) == 4}
    par, used = [], set()
    for o, x in sorted(words.items()):
        if o in used: continue
        if _fmov_imm(x):
            k = _fit([A], [_fmov_val(x)], 0.07)
            if k: par.append((o, 'fmov', k)); used.add(o); continue
        mp = _movpair(x, words.get(o + 4))
        if mp:
            k = _fit([A], [mp[1]], 2e-3)
            if k: par.append((o, 'movpair', k)); used |= {o, o + 4}; continue
        f = struct.unpack('<f', struct.pack('<I', x))[0]
        if 0.05 < abs(f) < 50:
            k = _fit([A], [f], 2e-3)
            if k: par.append((o, 'float', k)); used.add(o); continue
    mv = {o: _mov_imm(x) for o, x in words.items() if o not in used and _mov_imm(x)}
    res = []
    for o, a in sorted(mv.items()):
        if a[2] or o in used: continue
        for q, b in sorted(mv.items()):
            if q == o or q in used or not b[1]: continue
            if _res_ok(a, b, A):
                res.append((o, q, a[1], b[1])); used |= {o, q}; break
    return par, res, len([o for o in words if o not in used])


PORT_WIN = 0x400   # 跨版本移植：其余行在新位置前后找同形指令的范围（±1 KB；一款 2.7.6→2.7.7 实测 ±64 KB 时阴影行错移 +0x1164）


def port_writes(writes, A, im, text_end):
    """宽屏补丁跨游戏版本移植（11-13 维护者：只做画幅，帧率 / 金手指不做）：旧版的写入 → 新版主程序（im 映像）上的同一份。
    按「这一处原来是什么」重新定位，不照搬地址：画幅值的原值必是同式的 16:9 值 → 找同写法、同目标寄存器、值 = 式(16/9) 的位置；
    渲染尺寸对 → 同寄存器、宽 ÷ 高 = 16/9、两条间距不变；其余行（原值不知道）只在新位置 ±1 KB 找去掉立即数后同一条的唯一一处。
    候选按离「旧地址 + 最近已定位处的平移」最近取。画幅值有一处找不到 → None（宁缺不错）。→ ([(新偏移, 4 字节)], 说明行列表)"""
    par, res, _ = aspect_classify(writes, A)
    w = {}
    for off, b in writes:
        for k, v in enumerate(b):
            o = off + k; w.setdefault(o & ~3, {})[o & 3] = v
    ww = {o: int.from_bytes(bytes(d.get(i, 0) for i in range(4)), 'little') for o, d in w.items() if len(d) == 4}
    if not par and not res: return None, ['认不出随画幅变的值，不移植']
    R16 = 16 / 9
    word = lambda o: int.from_bytes(im[o:o + 4], 'little')
    def scan_w(lo, hi, pred): return [o for o in range(max(0, lo) & ~3, min(len(im) - 4, hi), 4) if pred(word(o))]
    moved, rep, delta, used = {}, [], [], set()
    def near(cands, o):
        d = sorted(delta, key=lambda x: abs(x[0] - o))[0][1] if delta else 0
        return sorted(cands, key=lambda q: abs(q - (o + d)))
    for o, kind, k in par:
        x = ww[o]; t = ADAPT_F[k](R16)
        if kind == 'fmov':
            fm = _fmov_imm(x); cands = scan_w(0, text_end, lambda y: _fmov_imm(y) == fm and abs(_fmov_val(y) - t) <= 0.07)
        elif kind == 'movpair':
            rd = x & 31
            cands = [q for q in scan_w(0, text_end, lambda y: y & 0xFFE0001F == 0x52800000 | rd)
                     if (lambda pr: pr and pr[0] == rd and abs(pr[1] - t) <= 2e-3)(_movpair(word(q), word(q + 4)))]
        else:
            tb = struct.pack('<f', t); cands = [m.start() for m in re.finditer(re.escape(tb), im) if m.start() % 4 == 0 and m.start() >= text_end]
        cands = [q for q in near(cands, o) if q not in used]
        if not cands: return None, rep + [f'画幅值 {o:#x}（{kind} {k}）：新版里找不到原值 {t:.4f} 的同形指令，整份不移植']
        q = cands[0]; used.add(q); moved[o] = q; delta.append((o, q - o))
        if kind == 'movpair': moved[o + 4] = q + 4; used.add(q + 4)
        rep.append(f'画幅值 {o:#x} → {q:#x}（平移 {q - o:+#x}，候选 {len(cands)}）')
    for o, p, _, _ in res:
        a0, b0 = _mov_imm(ww[o]), _mov_imm(ww[p]); gap = p - o
        def is_pair(q):
            a, b = _mov_imm(word(q)), _mov_imm(word(q + gap))
            return a and b and not a[2] and a[0] == a0[0] and b[0] == b0[0] and b[1] and abs(a[1] / b[1] - R16) <= 0.01 * R16
        cands = [q for q in near(scan_w(0, text_end, lambda y: _mov_imm(y) is not None and _mov_imm(y)[0] == a0[0]), o) if q not in used and is_pair(q)]
        if not cands: rep.append(f'渲染尺寸 {o:#x}/{p:#x}：新版里找不到 16:9 的同形一对，这一对不移植'); continue
        q = cands[0]; moved[o] = q; moved[p] = q + gap; used |= {q, q + gap}; delta.append((o, q - o))
        rep.append(f'渲染尺寸 {o:#x}/{p:#x} → {q:#x}/{q + gap:#x}（候选 {len(cands)}）')
    for o, x in sorted(ww.items()):
        if o in moved: continue
        mv = _mov_imm(x)
        if not mv: rep.append(f'其余行 {o:#x}：不是 MOV 立即数，判不了同形，不移植'); continue
        d = sorted(delta, key=lambda z: abs(z[0] - o))[0][1] if delta else 0
        cands = near([q for q in scan_w(o + d - PORT_WIN, o + d + PORT_WIN, lambda y: (lambda m: m is not None and m[0] == mv[0] and m[2] == mv[2])(_mov_imm(y))) if q not in used], o)
        if not cands or (len(cands) > 1 and abs(cands[0] - (o + d)) == abs(cands[1] - (o + d))):
            rep.append(f'其余行 {o:#x}：附近同形指令{"没有" if not cands else "不止一处且一样近"}，不移植'); continue
        q = cands[0]; moved[o] = q; used.add(q); rep.append(f'其余行 {o:#x} → {q:#x}（平移 {q - o:+#x}）')
    return [(moved[o], ww[o].to_bytes(4, 'little')) for o in sorted(moved)], rep


def _adapt_single(c, exefs, log, root, side, fid=None):
    """一份定画幅宽屏补丁 → 它那一侧（side：w 比 16:9 宽 / n 比 16:9 窄）的自适应模板一份（编号 wsauto:<族号>:<侧>，族号缺省取份号）；一处画幅值也认不出 → None"""
    As = single_aspects(c)
    if not As: return None
    mod = c['module']; text_end, ro, ln, key = module_layout(os.path.join(exefs, mod))
    _, segs = nso_image(os.path.join(exefs, mod)); im = bytearray(ln)
    for mo, d in segs: im[mo:mo + len(d)] = d
    code_end = (text_end + 0x3FFF) & ~0x3FFF
    isfill = lambda o: o < text_end and fill(im, o)
    w = {}
    for off, b in c['writes']:
        for k, v in enumerate(b):
            o = off + k; w0 = o & ~3
            if w0 + 4 > len(im): return None
            w.setdefault(w0, bytearray(im[w0:w0 + 4]))[o - w0] = v
    wm = {o: int.from_bytes(v, 'little') for o, v in w.items()}
    def one(A):
        rec = {}
        mv = {o: _mov_imm(x) for o, x in wm.items() if _mov_imm(x)}
        for o, a in sorted(mv.items()):   # 渲染尺寸对：宽 ≥ 160（防小立即数碰巧成比例）
            if a[2] or a[1] < 160 or o in rec: continue
            for p, b in sorted(mv.items()):
                if p != o and p not in rec and _res_ok(a, b, A): rec[o] = ('x', None); rec[p] = ('h', None); break
        for o, x in sorted(wm.items()):
            if o in rec: continue
            pr = _movpair(x, wm.get(o + 4))
            if pr and o < text_end and not isfill(o):
                k = _fit([A], [pr[1]], 2e-3)
                if k: rec[o] = ('mp', k); rec[o + 4] = ('nop', None); continue
            fm = _fmov_imm(x)
            if fm and o < text_end and not isfill(o):
                k = _fit([A], [_fmov_val(x)], 0.07)
                if k: rec[o] = ('fm', k); continue
            if not fm and not pr:
                f = struct.unpack('<f', struct.pack('<I', x))[0]
                k = _fit([A], [f], 2e-3) if 0.05 < abs(f) < 50 else None
                if k and o >= code_end: rec[o] = ('fd', k)
        return rec
    A, rec = max(((B, one(B)) for B in As), key=lambda x: sum(1 for v in x[1].values() if v[0] in ('mp', 'fm', 'fd', 'x')))
    if not any(v[0] in ('mp', 'fm', 'fd', 'x') for v in rec.values()):
        log.append(f'不参数化\t{c["id"]}\t{mod}\t{c["name"][:40]}\t认不出随画幅变的值（画幅 {A:.3f}），照原样'); return None
    slots, words, marks, adata = {}, {}, {}, []
    def slot(k, prec):
        if (k, prec) not in slots: slots[(k, prec)] = ADAPT_SLOT0 + len(slots)
        return slots[(k, prec)]
    for o, x in wm.items():
        r = rec.get(o)
        if not r: words[o] = x
        elif r[0] == 'x': words[o] = _ldr_slot(0xB9400000 | (16 << 5) | (x & 31), slot('x', 'i')); marks[o] = 'kv'
        elif r[0] == 'h': words[o] = (x & ~(0xFFFF << 5)) | (PHONE_H << 5)
        elif r[0] == 'mp': words[o] = _ldr_slot(0xB9400000 | (16 << 5) | (x & 31), slot(r[1], 's')); marks[o] = 'kv'
        elif r[0] == 'nop': words[o] = 0xD503201F
        elif r[0] == 'fm':
            prec, rt = _fmov_imm(x); words[o] = _ldr_slot((0xBD400000 if prec == 's' else 0xFD400000) | (16 << 5) | rt, slot(r[1], prec)); marks[o] = 'kv'
        elif r[0] == 'fd': adata.append((o, 4, r[1]))
    fid = fid or c['id'].split(':', 1)[1][:12]
    hs = sorted(p for p, v in rec.items() if v[0] == 'h'); xs = sorted(o for o, v in rec.items() if v[0] == 'x')
    rpairs = list(zip(xs, hs))
    if rpairs: _fill_other_mode(im, text_end, words, marks, {}, rpairs, slot, log, f'wsauto:{fid}')
    if len(slots) > ADAPT_NSLOT: log.append(f'不参数化\t{c["id"]}\t{mod}\t{c["name"][:40]}\t值槽不够'); return None
    sl = [(f'k{s}', f'4/{k[1:]}' if k.startswith('y') else 8 if prec == 'd' else 4, k[:1]) for (k, prec), s in sorted(slots.items(), key=lambda x: x[1])]
    log.append(f'单份参数化\twsauto:{fid}\t{mod}\t{c["name"][:40]}\t画幅 {A:.4f}：' + '、'.join(f'+{o:#x} {v[0]}{"=" + v[1] if v[1] else ""}' for o, v in sorted(rec.items()) if v[0] != 'nop'))
    return dict(module=mod, cat=c['cat'], name=f'自适应满屏（单份补丁参数化 · {"宽" if side == "w" else "窄"}屏模板）',
                 writes=sorted((o, x.to_bytes(4, 'little')) for o, x in words.items()), license=c['license'], path=c.get('origin') or c['path'], base=c['base'],
                 id=f'wsauto:{fid}:{side}', meta=dict(c['meta'], aspect=None, adapt=dict(side=side, marks=marks, adata=adata + sl)))


# —— 金手指（11-12 维护者：出包时把能编进包的金手指带上；改代码的条目走本文件的双路 + 槽，运行时逐条开关）——
# 来源目录 S2A_CHEATS_DIRS（冒号分隔；每个目录里放 Atmosphere 格式 txt：玩家导入的、启动器从公开库取的），文件名是主程序构建号前 16 位（Atmosphere 惯例），
#   文件头 [游戏名 … BID=<构建号>] 写了 BID 的以它为准。构建号对不上主程序的整份不收，原因写进 cpatch_plan.log「版本不对」。
# 只收「每一行都是类型 0（写常量）、区域 0（主程序）」的条目；别的类型（按键 / 条件 / 堆 / 寄存器）留给运行时 Tamper（services/S2A.Services/Cheats.cs）。
#   20000000（条件块结束）在只有它的「分类标题」条目里是空操作，不算别的类型。主控（{…}）单独成一份，运行时同文件任一条开着就开（Atmosphere 约定）。
# 偏移寄存器 R：寄存器每轮从 0 起，只有少数指令写寄存器（_reg_writes）；整份文件里没有任何指令写 R 时 R 恒为 0、等于加 0（暗黑 3 这份写 R=E；
#   另一款写 R=7、同文件别的条目只用 RF 跑指针链——原先「文件里有别的类型就一律交运行时」把它整份改代码条目漏掉了，运行时又写不了代码页）。文件里有指令写 R 的条目交运行时。
# 编号 cheat:<文件内容 sha256 前 16 位>:<条目在文件里的序号>；段名 = 条目名，来源 = 文件名（Cheats.cs 按「文件名 + 条目名」认）
CHEAT_RE = re.compile(r'^0([1248])([0-9A-Fa-f])([0-9A-Fa-f])00([0-9A-Fa-f]{2})$')   # 0 T M R 00 AA：宽度 / 区域 / 偏移寄存器 / 地址高位


def _reg_writes(op):
    """一条非类型 0 指令（首字）可能写的寄存器号集合（Atmosphere 指令格式，同 Ryujinx AtmosphereCompiler）：3 循环 / 4 装常量 / 5 读内存 / 7 常量运算 /
    9 寄存器运算写第 4 位的 R；6 存常量、A 存寄存器在自增位（第 5 位）非 0 时改第 4 位的地址寄存器；0 / 1 / 2 / 8 / F 不写。C 类（存取 / 静态寄存器）与认不出的按全部 16 个算"""
    t = op[:1].upper()
    if t in '0128F': return set()
    if len(op) == 8 and t in '34579': return {int(op[3], 16)}
    if len(op) == 8 and t in '6A': return {int(op[3], 16)} if op[4] != '0' else set()
    return set(range(16))


def parse_cheats(text):
    """→ (文件头里的 BID 或 '', [{name, master, writes:[(偏移, 字节)] 或 None（有不能编进包的行）}])"""
    m = re.search(r'BID\s*=\s*([0-9A-Fa-f]{16,64})', text.split('\n', 1)[0])
    bid, out, cur, written = (m.group(1).upper() if m else ''), [], None, set()   # written：整份文件里有指令写的寄存器
    for line in text.splitlines():
        s = line.strip()
        h = re.match(r'^([\[{])(.*)[\]}]$', s)
        if h: cur = {'name': h.group(2).strip(), 'master': h.group(1) == '{', 'writes': [], 'other': False}; out.append(cur); continue
        if cur is None or not s or s.startswith('//') or s.startswith('#'): continue
        w = s.split()
        if len(w) == 1 and re.fullmatch(r'20[0-9A-Fa-f]{6}', w[0]): continue   # 条件块结束（Atmosphere 只看第 2 位：0 = 结束；有的文件写 20000001），在没有条件块的条目里是空操作
        c = CHEAT_RE.match(w[0]) if len(w) in (3, 4) else None
        if not c or c.group(2) != '0':   # 区域 0 = 主程序；别的类型 / 区域交运行时
            cur['other'] = True
            if not re.fullmatch(r'[0-9A-Fa-f]{8}', w[0]): written |= set(range(16))
            elif w[0][0] != '0': written |= _reg_writes(w[0])
            continue
        if c.group(3) != '0': cur.setdefault('regs', set()).add(int(c.group(3), 16))
        width = int(c.group(1)); off = int(c.group(4) + w[1], 16)
        val = int(''.join(w[2:]), 16)
        if val >> (8 * width): cur['other'] = True; continue
        cur['writes'].append((off, val.to_bytes(width, 'little')))
    return bid, [dict(e, writes=None if e['other'] or (e.get('regs', set()) & written) else e['writes']) for e in out if e['writes'] or e['other']]


def module_layout(path):
    """→ (代码段结尾, ro 开头, 映像结尾含 bss, 键页偏移下界)；键页偏移同 runtime/rewriter/rewriter.c load()：远布局 / 无前移按 16 KB 取整，
    Apple data 与代码段末页共页时基址前移 bias——两种取小的，平台不同也落在键页前"""
    hdr, segs = nso_image(path)
    text_end, ro, data = segs[0][0] + len(segs[0][1]), segs[1][0], segs[2][0]
    ln = data + len(segs[2][1]) + struct.unpack_from('<I', hdr, 0x3c)[0]
    bias = (0x4000 - (data & 0x3fff)) & 0x3fff if data < ((text_end + 0x3fff) & ~0x3fff) else 0
    return text_end, ro, ln, min((ln + 0x3fff) & ~0x3fff, ((ln + bias + 0x3fff) & ~0x3fff) - bias)


MIRROR_FPSL = 0x400   # 映像结尾可写空余的分区：前 0x400 字节给金手指空洞开关表，之后给 FPSLocker 变量（各管各的，不重叠）


def _cheat_mirror(entries, text_end, ro, ln, key, why):
    """一份金手指文件里改代码条目共用的「空洞开关表」搬到可写区（11-12 暗黑 3 实测：共享挂钩 + 空洞代码，
    各条只在空洞里写自己的开关字（+0x18 无限血 / +0x1c 无限资源 / +0x24 伤害倍数…），挂钩代码用 adrp + add 定位开关表）。
    开关表和代码同在代码段末页（只读可执行），运行时写不了，逐条开关就做不到；搬到映像结尾（bss 之后、键页之前的空余，运行时可写、
    runtime/src/cpatch.c 数据写入允许的范围）后，开关字成了普通数据写入，局内即时开关。
    entries: [{addr: byte}]（只含代码区写入），原地改。认不出的写法（adr / 字面量取数 / adrp 后不是 add）不搬，原因写进 why，返回 None"""
    U = {}
    for e in entries:
        for o, v in e.items():
            if text_end <= o < ro: U.setdefault(o, set()).add(v)
    if not U: return None
    def word(a):
        bs = [U.get(a + k) for k in range(4)]
        return None if any(x is None or len(x) != 1 for x in bs) else int.from_bytes(bytes(next(iter(x)) for x in bs), 'little')
    cs = _cs_one()
    def dec(a):
        w = word(a); return (w, next(cs.disasm(struct.pack('<I', w), a), None)) if w is not None else (None, None)
    starts = set()
    for e in entries:
        for w0 in {o & ~3 for o in e if o < text_end}:
            bs = bytes(e.get(w0 + k, 0) for k in range(4)) if all(w0 + k in e for k in range(4)) else None
            ins = next(cs.disasm(bs, w0), None) if bs else None
            if ins and ins.operands and ins.operands[-1].type == 2 and text_end <= ins.operands[-1].imm < ro: starts.add(ins.operands[-1].imm)   # 2 = 立即数
    code, todo = set(), sorted(starts)
    while todo:
        a = todo.pop()
        if a in code or not text_end <= a < ro: continue
        w, ins = dec(a)
        if ins is None or ins.mnemonic in ('udf', 'brk'): continue
        code.add(a); m = ins.mnemonic; tgt = ins.operands[-1].imm if ins.operands and ins.operands[-1].type == 2 else None
        if m in ('b', 'bl') or m.startswith('b.') or m in ('cbz', 'cbnz', 'tbz', 'tbnz'):
            if tgt is not None: todo.append(tgt)
            if m != 'b': todo.append(a + 4)
        elif m not in ('ret', 'br') and not m.startswith(('ret', 'bra', 'eret')): todo.append(a + 4)
    data = sorted(o for o in U if (o & ~3) not in code)
    if not data or not code: return None
    lo, hi = data[0] & ~3, (data[-1] + 4) & ~3
    if not (hi <= min(code) or lo > max(code)): why.append('空洞里代码和开关表交错，开关表没法整块搬走'); return None
    M = (ln + 15) & ~15
    if M + (hi - lo) > min(key, M + MIRROR_FPSL): why.append(f'空洞开关表 {hi - lo:#x} 字节，超出映像结尾给它的 {min(key - M, MIRROR_FPSL):#x} 字节'); return None
    fix = {}
    for a in sorted(code):
        w, ins = dec(a); m = ins.mnemonic
        if m == 'adr' or (m.startswith('ld') and ins.operands and ins.operands[-1].type == 2):
            tgt = ins.operands[-1].imm
            if lo <= tgt < hi: why.append(f'空洞代码 {a:#x} 用 {m} 直接取开关表，认不出'); return None
        if m != 'adrp': continue
        page = ins.operands[1].imm
        if not (lo & ~0xfff) <= page <= ((hi - 1) & ~0xfff): continue
        w2, i2 = dec(a + 4); rd = w & 31
        if i2 is None or (w2 & 0xffc00000) != 0x91000000 or (w2 & 31) != rd or (w2 >> 5) & 31 != rd:
            why.append(f'空洞代码 {a:#x} adrp 后不是 add 同一寄存器，开关表定位认不出'); return None
        base = page + ((w2 >> 10) & 0xfff)
        if not lo <= base < hi: continue
        t = M + (base - lo); im = (t >> 12) - (a >> 12)
        fix[a] = 0x90000000 | ((im & 3) << 29) | (((im >> 2) & 0x7ffff) << 5) | rd
        fix[a + 4] = (w2 & ~(0xfff << 10) & ~(1 << 22)) | ((t & 0xfff) << 10)
    if not fix: why.append('空洞代码没有用 adrp + add 定位开关表'); return None
    for e in entries:
        for a, nw in fix.items():
            if a in e: e.update({a + k: (nw >> 8 * k) & 0xff for k in range(4)})
        for o in [o for o in e if lo <= o < hi]: e[M + (o - lo)] = e.pop(o)
    return lo, hi, M


CHEAT_SHIP = 'cheat-src.'   # 随包金手指原文在产物根 / App 里的文件名前缀（runtime/src/cpatch.c 同名常量）


def scan_cheats(dirs, exefs, log, ship=None):
    """金手指目录里要改代码的条目 → 与 scan() 同形的单元（只认主程序）。只写可写内存（data / bss）的条目、条目里写可写内存的行
    不进包，照旧由运行时 Tamper 每帧执行（services/S2A.Services/Cheats.cs；Atmosphere 语义就是每帧写）；只有写代码区（代码段 + 末页尾巴）的部分
    运行时做不到，编进包。不收的整份 / 整条写进 log。ship 给了（列表）：版本对得上的整份原文 (文件名, 字节) 追加进去（随包带到手机，见 plan CHEAT_SHIP）"""
    path = os.path.join(exefs, 'main'); bid = module_bid(path); out = []
    text_end, ro, ln, key = module_layout(path)
    for d in dirs:
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if not f.lower().endswith('.txt') or f in ('enabled.txt', 'status.txt'): continue
            fp = os.path.join(d, f)
            try: raw = open(fp, 'rb').read()
            except OSError: continue
            if len(raw) > 4 << 20: log.append(f'不收\tcheat\tmain\t{f[:40]}\t文件超过 4 MB'); continue
            fbid, entries = parse_cheats(raw.decode('utf-8', 'replace'))
            stem = os.path.splitext(f)[0]
            want = fbid or (stem if re.fullmatch(r'[0-9A-Fa-f]{16}', stem) else '')
            if not want or not bid_match(bid, want):
                log.append(f'不收\tcheat\tmain\t{f[:40]}\t版本不对：金手指是 {want or "（没写构建号）"}，这份游戏的主程序是 {bid[:16]}'); continue
            if ship is not None and f not in {n for n, _ in ship}: ship.append((f, raw))
            sha = hashlib.sha256(raw).hexdigest()[:16]; picked = []
            for i, e in enumerate(entries):
                if e['writes'] is None: continue   # 有别的类型（按键 / 条件 / 堆）：整条交运行时
                m = {o + k: v for o, b in e['writes'] for k, v in enumerate(b) if o + k < ro}
                if m: picked.append((i, e, m))
            why = []
            mir = _cheat_mirror([m for _, _, m in picked], text_end, ro, ln, key, why)
            log.append(f'金手指\tcheat:{sha}\tmain\t{f[:40]}\t' + (f'空洞开关表 {mir[0]:#x}–{mir[1]:#x} 搬到 {mir[2]:#x}（可写，逐条即时开关）' if mir else '开关表不搬：' + ('；'.join(why) or '没有空洞开关表')))
            for i, e, m in picked:
                runs, cur = [], None
                for o in sorted(m):
                    if cur and o == cur[0] + len(cur[1]): cur[1].append(m[o]); continue
                    cur = [o, bytearray([m[o]])]; runs.append(cur)
                out.append({'module': 'main', 'cat': 'cheat', 'name': e['name'], 'writes': [(o, bytes(b)) for o, b in runs], 'license': '', 'path': f, 'base': d,
                            'id': f'cheat:{sha}:{"m" if e["master"] else i}', 'meta': {'romfs': 0, 'fps': None}})
    return out


def nso_image(path):
    """→ (头 0x100 字节, [(段内存偏移, 段字节)×3])，按段解压"""
    b = _nso_plain(open(path, 'rb').read(), path); fl = struct.unpack_from('<I', b, 0xC)[0]; segs = []
    for k in range(3):
        fo, mo, sz = struct.unpack_from('<III', b, 0x10 + 0x10 * k); csz = struct.unpack_from('<I', b, 0x60 + 4 * k)[0]; d = b[fo:fo + csz]
        if fl >> k & 1:
            import lz4.block
            d = lz4.block.decompress(d, uncompressed_size=sz)
        segs.append((mo, d[:sz]))
    return b[:HDR], segs


# —— 数据流旁路检查（11-01 01006F8002326000 3.0.3 fps:370eb70 冷启 4/4 崩定因后加，通用规则、不按款）——
# 补丁片段在区间里某处 D 设寄存器 R、后面某处 U 读 R（U 处原指令不读 R，是补丁新引入的依赖）：补丁作者假定「到 U 必先经过 D」。
# 若原版代码有路从区间外（直接 b / bl / 条件跳 / 可解析的跳转表 / 区间顶上顺序落入）进到 D 之后、U 之前，那条路上 R 是原代码留下的值
# （01006F8002326000：原版 7 条路跳到 +0x1468a68 / a6c，绕过 +0x1468a5c 的 ldr x24，+0x1468a74 读 x24(=1)+0x50 崩），且落点上原版已不再用 R（_live_orig：往后先写后读 /
# 到返回都不读）→ 整份不收、原因写进 cpatch_plan.log。落点上原版还读 R = 补丁接着原状态写（01006F8002326000 SpeedFix +0x7bcd5c 钩子，原指令 str w22,[x21]），不算。
# 补丁后走不到的来源（只能从被补丁改成跳走的指令落下来的原代码）不算入口（is_dead）。
# 换空闲寄存器修不了这一类：旁路上没有任何指令给 U 读的寄存器写补丁要的值，换成哪个寄存器读到的都是原代码的值；换寄存器只能修「补丁写坏
# 原代码还要读的活寄存器」那一类（后续项）。区间 = 本份改动字按间隔 ≤ 0x20 字节聚成的段（含段内没改的原指令）；分析走补丁后的指令流。
# 寄存器读写按操作数位置自己判（capstone 5 的 regs_access / 操作数 access 对 cmp、fmov 立即数、cbz 等是错的，实测），判不准的一律按「既读又写」
# ——对本检查是保守方向（读多 = 候选多；写不算定义 = 往回走不停，旁路照样找得到）
_GAP = 0x20
_FLAGS = 64
_NODEST = {'cmp', 'cmn', 'tst', 'ccmp', 'ccmn', 'fcmp', 'fcmpe', 'fccmp', 'fccmpe', 'cbz', 'cbnz', 'tbz', 'tbnz', 'br', 'blr', 'ret', 'b', 'bl',
           'msr', 'prfm', 'prfum', 'dc', 'ic', 'tlbi', 'at', 'sys', 'hint', 'nop', 'yield', 'wfe', 'wfi', 'sev', 'sevl', 'dmb', 'dsb', 'isb',
           'clrex', 'brk', 'hlt', 'svc', 'hvc', 'smc', 'udf', 'braa', 'brab', 'blraa', 'blrab', 'retaa', 'retab', 'braaz', 'brabz', 'blraaz', 'blrabz'}
_RW = {'movk', 'bfi', 'bfxil', 'bfm', 'bfc'}
_FLAG_W = {'cmp', 'cmn', 'tst', 'ccmp', 'ccmn', 'fcmp', 'fcmpe', 'fccmp', 'fccmpe', 'adds', 'subs', 'ands', 'bics', 'adcs', 'sbcs', 'negs', 'ngcs'}
_FLAG_R = {'csel', 'csinc', 'csinv', 'csneg', 'cset', 'csetm', 'cinc', 'cinv', 'cneg', 'fcsel', 'ccmp', 'ccmn', 'fccmp', 'fccmpe', 'adc', 'adcs', 'sbc', 'sbcs', 'ngc', 'ngcs'}
_ATOMIC = re.compile(r'^(ld(add|clr|eor|set|smax|smin|umax|umin)|swp|cas)[a-z]*$')
_cs = None


def _reg(name):
    """寄存器名 → 编号：x/w 0–30、fp 29、lr 30；b/h/s/d/q/v → 32+n；sp / 零寄存器 → None"""
    if name in ('fp', 'x29', 'w29'): return 29
    if name in ('lr', 'x30', 'w30'): return 30
    m = re.fullmatch(r'([xw])(\d+)|([bhsdqv])(\d+)', name)
    if not m: return None
    return int(m.group(2)) if m.group(1) else 32 + int(m.group(4))


def _rname(r):
    return 'nzcv' if r == _FLAGS else f'x{r}' if r < 32 else f'v{r - 32}'


_DEC = {}


def _dec(word, addr):
    """_dec_raw 加缓存（11-12 提速：动森 6727 字的 SpeedFix 出表 157 秒，同一地址被反复解码 254 万次）；返回不可变集合，调用方本来就只读"""
    v = _DEC.get((word, addr))
    if v is None:
        rd, wr, kind, t = _dec_raw(word, addr)
        v = _DEC[(word, addr)] = (frozenset(rd), frozenset(wr), kind, t)
    return v


def _dec_raw(word, addr):
    """→ (读集合, 写集合, 种类, 目标)；种类：seq 顺序 / b 无条件跳 / cond 条件跳（可落下）/ call bl（可落下）/ end 不落下（ret / br / brk / 解不出）"""
    global _cs
    if _cs is None:
        import capstone   # 出包解释器钉死 capstone 5.0.7（tools/rewriter-requirements.txt）；全是 nop 的补丁不走到这里
        _cs = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM); _cs.detail = True
    from capstone import arm64 as A
    ins = next(_cs.disasm(struct.pack('<I', word), addr), None)
    if ins is None or ins.mnemonic == 'udf': return set(), set(), 'end', None
    m = ins.mnemonic; base = m.split('.')[0]; rd, wr = set(), set(); regs = []; mem = []; has_mem = False
    for o in ins.operands:
        if o.type == A.ARM64_OP_REG:
            r = _reg(ins.reg_name(o.reg))
            if r is not None: regs.append((r, o.vector_index != -1))
        elif o.type == A.ARM64_OP_MEM:
            has_mem = True   # 基址是 sp 时 mem 列表为空，形状判断看这个
            for x in (o.mem.base, o.mem.index):
                r = _reg(ins.reg_name(x)) if x else None
                if r is not None: mem.append(r)
    rd |= set(mem)
    if ins.writeback and mem: wr.add(mem[0])
    if base in _NODEST or base.startswith('b.') or m.startswith('b.'):
        rd |= {r for r, _ in regs}
    elif m.startswith('st') and not m.startswith('stx') and not m.startswith('stlx'):
        rd |= {r for r, _ in regs}
    elif m.startswith(('stx', 'stlx')):
        if regs: wr.add(regs[0][0]); rd |= {r for r, _ in regs[1:]}
    elif _ATOMIC.match(m):
        rd |= {r for r, _ in regs}; wr |= {r for r, _ in regs}
    elif m.startswith('ld') and has_mem:
        lane = any(v for _, v in regs)
        wr |= {r for r, _ in regs}
        if lane: rd |= {r for r, _ in regs}
    elif regs:
        d, lane = regs[0]; wr.add(d); rd |= {r for r, _ in regs[1:]}
        neon = d >= 32 and (lane or re.search(r'\bv\d+\.', ins.op_str))
        if m in _RW or lane or neon: rd.add(d)   # 部分写 / 向量指令目的按读改写算（保守）
    if base in _FLAG_W or m in _FLAG_W: wr.add(_FLAGS)
    if base in _FLAG_R or m.startswith('b.'): rd.add(_FLAGS)
    if m in ('bl', 'blr'): wr.add(30)
    if m == 'ret' and not regs: rd.add(30)
    t = None
    if m in ('b', 'bl') or m.startswith('b.') or base in ('cbz', 'cbnz', 'tbz', 'tbnz'):
        t = ins.operands[-1].imm
    kind = 'b' if m == 'b' else 'call' if m == 'bl' else 'cond' if t is not None else 'end' if m in ('ret', 'br', 'brk', 'hlt') or m.startswith(('ret', 'bra', 'eret')) else 'seq'
    return rd, wr, kind, t


def _branch_pairs(text):
    """原版代码段里所有直接跳转（b / bl / b.cond / cbz / cbnz / tbz / tbnz）→ (目标, 来源) 按目标排好的两列；每模块算一次"""
    try:
        import numpy as np
        w = np.frombuffer(text[:len(text) & ~3], dtype='<u4').astype(np.int64); a = np.arange(len(w), dtype=np.int64) * 4
        b26 = w & 0x3ffffff; b26 = np.where(b26 & 0x2000000, b26 - 0x4000000, b26) * 4
        i19 = (w >> 5) & 0x7ffff; i19 = np.where(i19 & 0x40000, i19 - 0x80000, i19) * 4
        i14 = (w >> 5) & 0x3fff; i14 = np.where(i14 & 0x2000, i14 - 0x4000, i14) * 4
        m26 = (w & 0x7c000000) == 0x14000000; m19 = ((w & 0xff000010) == 0x54000000) | ((w & 0x7e000000) == 0x34000000); m14 = (w & 0x7e000000) == 0x36000000
        src = np.concatenate([a[m26], a[m19], a[m14]]); tgt = np.concatenate([a[m26] + b26[m26], a[m19] + i19[m19], a[m14] + i14[m14]])
        o = np.argsort(tgt, kind='stable'); return tgt[o].tolist(), src[o].tolist()
    except ImportError:
        pairs = []
        for k, (x,) in enumerate(struct.iter_unpack('<I', text[:len(text) & ~3])):
            if (x & 0x7c000000) == 0x14000000: d = (x & 0x3ffffff) - ((x & 0x2000000) << 1)
            elif (x & 0xff000010) == 0x54000000 or (x & 0x7e000000) == 0x34000000: d = ((x >> 5) & 0x7ffff) - (((x >> 5) & 0x40000) << 1)
            elif (x & 0x7e000000) == 0x36000000: d = ((x >> 5) & 0x3fff) - (((x >> 5) & 0x2000) << 1)
            else: continue
            pairs.append((k * 4 + d * 4, k * 4))
        pairs.sort(); return [t for t, _ in pairs], [s_ for _, s_ in pairs]


def _jump_tables(im, text_end, lo, hi, note, pairs=None):
    """[lo, hi) 附近（前后 64 KB）的跳转表 br：认 clang 两种形状「adrp+add 表基 / adr 锚点 / ldrb|ldrh|ldrsw 取项 / add 锚点, 项, lsl|sxtw #k / br」
    （锚点就是表基也认），表长取前面 cmp wI,#N + b.hi / b.hs；本块里没有就看跳进本块的条件跳（cmp wI,#N + b.ls / b.lo 跳来，pairs = _branch_pairs）；→ {目标: [br 地址…]}；形状像跳转表但解不出的记进 note（不当入口）"""
    out = {}; a0 = max(0, lo - 0x10000) & ~3; a1 = min(text_end, hi + 0x10000)
    word = lambda a: struct.unpack_from('<I', im, a)[0]
    for a in range(a0, a1, 4):
        w = word(a)
        if (w & 0xfffffc1f) != 0xd61f0000: continue
        d = (w >> 5) & 31; seq = []
        for k in range(1, 25):
            if a - 4 * k < 0: break
            seq.append((a - 4 * k, _dec(word(a - 4 * k), a - 4 * k)))
        add = next(((p, word(p)) for p, (_, wr, kind, _) in seq if d in wr), None)
        if not add or (add[1] & 0x7f200000) not in (0x0b000000, 0x0b200000): continue   # 不是 add 给出的目标：尾调用之类，跳到函数开头，不算区间内入口
        w2 = add[1]; xa, xb = (w2 >> 5) & 31, (w2 >> 16) & 31
        sh = (w2 >> 10) & 7 if w2 & 0x00200000 else (w2 >> 10) & 63
        def find(r, before):
            return next(((p, word(p)) for p, (_, wr, _, _) in seq if p < before and r in wr), (None, None))
        pl, wl = find(xb, add[0]); tbl = anchor = None; size = None; n = None
        try:
            if wl is None: raise ValueError
            if (wl & 0xffe0fc00) == 0x38606800 or (wl & 0xffe0fc00) == 0x38607800: size, signed = 1, False   # ldrb w, [xT, xI(, lsl #0)]
            elif (wl & 0xffe0ec00) == 0x78606800: size, signed = 2, False                                     # ldrh w, [xT, xI(, lsl #1)]
            elif (wl & 0xffe0ec00) == 0xb8a06800: size, signed = 4, True                                      # ldrsw x, [xT, xI(, lsl #2)]
            else: raise ValueError
            xt, xi = (wl >> 5) & 31, (wl >> 16) & 31
            ix = {xi}   # mov wI, wJ / and xI, xJ, #0xffffffff：表长判 J
            for p, _ in seq:
                x = word(p)
                if p < pl and x & 31 == xi:
                    if (x & 0x7fe0ffe0) == 0x2a0003e0: ix.add((x >> 16) & 31)
                    elif (x & 0xfffffc00) == 0x92407c00: ix.add((x >> 5) & 31)
            def addr_page(q, y): return (q & ~0xfff) + ((((((y >> 5) & 0x7ffff) << 2 | (y >> 29) & 3) ^ 0x100000) - 0x100000) << 12)   # adrp
            def addr_of(r, before):
                p, x = find(r, before)
                if x is None and r >= 19:   # 被调方保留寄存器里的表基：编译器提到函数开头算一次，按地址往回找最近一次写它（最多 4096 条）
                    for q in range(before - 4, max(0, before - 0x4000) - 4, -4):
                        if r in _dec(word(q), q)[1]:
                            p, x = q, word(q)
                            if (x & 0xff800000) == 0x91000000 and (word(q - 4) & 0x9f00001f) == 0x90000000 | ((x >> 5) & 31): return addr_page(q - 4, word(q - 4)) + ((x >> 10) & 0xfff) * (4096 if x & 0x400000 else 1)
                            break
                if x is None: raise ValueError
                if (x & 0x9f000000) == 0x10000000: return p + ((((x >> 5) & 0x7ffff) << 2 | (x >> 29) & 3) ^ 0x100000) - 0x100000   # adr
                if (x & 0xff800000) == 0x91000000:   # add xr, xs, #imm（前面 adrp）
                    q, y = find((x >> 5) & 31, p)
                    if y is None or (y & 0x9f000000) != 0x90000000: raise ValueError
                    return addr_page(q, y) + ((x >> 10) & 0xfff) * (4096 if x & 0x400000 else 1)
                raise ValueError
            tbl = addr_of(xt, pl); anchor = tbl if xa == xt else addr_of(xa, add[0])
            for p, (_, _, kind, _) in seq:
                x = word(p)
                if (x & 0x7f80001f) == 0x7100001f and (x >> 5) & 31 in ix:   # cmp wI, #N
                    nb = next((word(q) & 0xf for q, _ in seq if q > p and (word(q) & 0xff000010) == 0x54000000), None)
                    if nb == 8: n = ((x >> 10) & 0xfff) + 1
                    elif nb == 2: n = (x >> 10) & 0xfff
                    break
            for p, _ in seq:   # and wI, wX, #(2^k - 1)：项数 2^k
                x = word(p)
                if p < pl and (x & 0x7f800000) == 0x12000000 and x & 31 in ix and not n:
                    immr, imms = (x >> 16) & 63, (x >> 10) & 63
                    if immr == 0 and imms < 8: n = 1 << (imms + 1)
            if not n and pairs:   # 取表块是被「cmp wI,#N; b.ls / b.lo 取表块」跳来的
                import bisect
                st = next((p + 4 for p, (_, _, kind, _) in seq if kind in ('b', 'end', 'cond')), seq[-1][0])
                tg, sr = pairs
                for q in sr[bisect.bisect_left(tg, st):bisect.bisect_right(tg, st)]:
                    c = word(q)
                    if (c & 0xff000010) != 0x54000000 or c & 0xf not in (9, 3): continue
                    for k in range(1, 9):
                        x = word(q - 4 * k)
                        if (x & 0x7f80001f) == 0x7100001f and (x >> 5) & 31 in ix:
                            n = ((x >> 10) & 0xfff) + (1 if c & 0xf == 9 else 0); break
                    if n: break
            if not n or tbl < 0 or tbl + n * size > len(im): raise ValueError
            for k in range(n):
                v = int.from_bytes(im[tbl + k * size:tbl + (k + 1) * size], 'little', signed=signed)
                out.setdefault(anchor + (v << sh), []).append(a)
        except (ValueError, struct.error):
            note.append(f'{a:#x}')
    return out


_ARGS = set(range(0, 9)) | set(range(32, 40))                 # 调用时被调方会读：x0–x8、v0–v7
_KEEP = set(range(19, 31)) | set(range(40, 48))                # 被调方保留：x19–x30、v8–v15（过调用不变；返回 / 尾调用时是调用方的值）
_RETV = set(range(0, 8)) | set(range(32, 40)) | _KEEP          # 返回时有意义：返回值 x0–x7 / v0–v7 + 被调方保留的


def _live_orig(im, text_end, t, r, budget=2048):
    """原版程序在 t 处寄存器 r 是否还有用（从 t 往后某条路先读后写）：True 有用 / False 没用；走满预算仍判不出按没用（对本检查是收紧方向：判不安全）。
    调用约定（AAPCS64）：bl / blr 读 x0–x8、v0–v7，冲掉 x9–x17、v16–v31 与标志；ret / br（按尾调用）时返回值与被调方保留的寄存器有用"""
    seen, todo = set(), [t]
    while todo:
        a = todo.pop()
        if a in seen or not (0 <= a < text_end): continue
        seen.add(a)
        if len(seen) > budget: return False
        m = struct.unpack_from('<I', im, a)[0]; rd, wr, kind, tg = _dec(m, a)
        call = kind == 'call' or (m & 0xfffffc1f) == 0xd63f0000   # bl / blr
        if call:
            if r in _ARGS or r in rd: return True
            if r not in _KEEP or r == 30: continue   # 被调用冲掉（x30 由 bl 写返回地址）
        elif r in rd: return True
        elif r in wr: continue
        if kind == 'end':
            if (m & 0xfffffc1f) in (0xd65f0000, 0xd61f0000) and r in _RETV: return True   # ret / br
            continue
        if kind in ('b', 'cond'): todo.append(tg)
        if kind != 'b': todo.append(a + 4)
    return False


def fill(im, o):
    """o 所在字原来是填充（全 0 / udf #imm16）"""
    w0 = o & ~3; v = int.from_bytes(im[w0:w0 + 4], 'little'); return v == 0 or v >> 16 == 0


def flow_hazard(im, text_end, mod, changed, text_cache):
    """changed：{字地址: (原字, 新字)}（本份补丁代码段里真改了的字）→ 不收原因（空串 = 安全）"""
    if all(nw == 0xd503201f for _, nw in changed.values()): return ''   # 全是 nop：不引入读写
    addrs = sorted(changed); iv = []
    for a in addrs:
        if iv and a - iv[-1][1] <= _GAP: iv[-1][1] = a + 4
        else: iv.append([a, a + 4])
    starts = [s for s, _ in iv]
    def inside(a):   # 区间按起点有序、互不重叠：二分（原先逐段线性比，动森 SpeedFix 2621 段 × 1.45 亿次）
        k = bisect.bisect_right(starts, a) - 1
        return k >= 0 and a < iv[k][1]
    word0 = lambda a: struct.unpack_from('<I', im, a)[0] if 0 <= a and a + 4 <= text_end else 0
    P = lambda a: changed[a][1] if a in changed else word0(a)
    cache = {}
    def dp(a):
        if a not in cache: cache[a] = _dec(P(a), a)
        return cache[a]
    if mod not in text_cache: text_cache[mod] = _branch_pairs(im[:text_end])
    tg, sr = text_cache[mod]; ext = {}
    note = []; jt = {}
    for s, e in iv:   # 按段查：一份补丁的段可能散在整个代码段里
        for k in range(bisect.bisect_left(tg, s), bisect.bisect_left(tg, e)):
            if not inside(sr[k]): ext.setdefault(tg[k], []).append(sr[k])
    # 跳转表：每段看前后 64 KB（_jump_tables 自己外扩）；窗口相互重叠的段并成一次扫（结果本来就不筛到区间、合在一起用），同一个 br 只解一次
    win = []
    for s, e in iv:
        if win and s - 0x10000 <= win[-1][1] + 0x10000: win[-1][1] = e
        else: win.append([s, e])
    for s, e in win:
        for t, ss in _jump_tables(im, text_end, s, e, note, text_cache[mod]).items(): jt.setdefault(t, []).extend(ss)   # 不筛到区间：下面判死代码也要用
    internal = {}
    for s, e in iv:
        for a in range(s, e, 4):
            _, _, kind, t = dp(a)
            if t is not None and kind in ('b', 'cond', 'call'): internal.setdefault(t, []).append(a)
    def falls(a): return (dp(a) if inside(a) else _dec(word0(a), a))[2] not in ('b', 'end')
    def all_preds(x):   # 补丁后的指令流里 x 的全部前驱（任意地址）
        out = [x - 4] if x - 4 >= 0 and falls(x - 4) else []
        out += [s_ for s_ in sr[bisect.bisect_left(tg, x):bisect.bisect_right(tg, x)] if not inside(s_)]
        return out + internal.get(x, []) + jt.get(x, [])
    dead = {}
    def is_dead(src):
        """区间外的来源在补丁后走不到（补丁把它前面的代码改成跳走了：SpeedFix 整段重写后原循环尾 +0x8ce8d8 的回跳）→ 不算入口。
        往回找前驱：碰到区间里的指令、或可能是函数入口（补丁后与原版都没有前驱）、或走满 256 条 → 走得到（保守）。原版有前驱、补丁后全没了
        （唯一的来路是被补丁改掉的跳转：SpeedFix 45 帧把 +0x237531c 的 tbz 改成 msub，+0x23754b8 起的守卫初始化段就走不到了）→ 死代码"""
        if src in dead: return dead[src]
        seen, todo, res = set(), [src], True
        while todo:
            x = todo.pop()
            if x in seen: continue
            seen.add(x)
            if len(seen) > 256: res = False; break
            ps = all_preds(x)
            if any(inside(q) for q in ps): res = False; break
            if not ps and not (x - 4 >= 0 and _dec(word0(x - 4), x - 4)[2] not in ('b', 'end')) and bisect.bisect_left(tg, x) == bisect.bisect_right(tg, x):
                res = False; break   # 原版里也没有前驱（不是落下来的、没有直接跳进来的）：可能是经指针调用的函数入口
            todo += ps
        dead[src] = res
        return res
    def preds(a):
        out = []   # (来源, 是否区间内)
        if inside(a - 4):
            if dp(a - 4)[2] not in ('b', 'end'): out.append((a - 4, True))
        elif a - 4 >= 0 and falls(a - 4) and not is_dead(a - 4): out.append((a - 4, False))
        out += [(s, True) for s in internal.get(a, [])]
        out += [(s, False) for s in ext.get(a, []) + jt.get(a, []) if not is_dead(s)]
        return out
    for u in addrs:
        ow, nw = changed[u]
        new_reads = dp(u)[0] - _dec(ow, u)[0]
        for r in sorted(new_reads):
            pdef, entries, seen, todo = None, [], set(), [(u, x) for x in preds(u)]
            while todo:
                into, (n, inn) = todo.pop()
                if (n, into) in seen: continue
                seen.add((n, into))
                if not inn:   # 从区间外进来：原版在落点上 r 还有用 = 补丁读的是原代码有意义的值（作者接着原状态写），没用 = 读到废值
                    if not _live_orig(im, text_end, into, r): entries.append((n, into))
                    continue
                rd, wr, _, _ = dp(n)
                if r in wr and r not in rd:
                    if n in changed: pdef = pdef or n
                    continue
                todo += [(n, x) for x in preds(n)]
            if pdef and entries:
                entries.sort(key=lambda e: (e[1], e[0])); e0 = entries[0]
                return (f'旁路读寄存器 {mod}+{u:#x} 读 {_rname(r)}：补丁在 +{pdef:#x} 设，原版 {len(entries)} 条路从区间外进到两者之间绕过设置、落点上原版已不用 {_rname(r)}'
                        f'（如 +{e0[0]:#x} → +{e0[1]:#x}；换寄存器补不上这条路上的值）')
    note = sorted(set(note), key=lambda x: int(x, 16))
    if note: print(f'提示：{mod} 补丁区间附近 {len(note)} 处像跳转表的 br 解不出（{" ".join(note[:4])}），未当入口', file=sys.stderr)
    return ''


def tail_hazard(word):
    """代码段结尾到 ro 开头之间（末页尾巴）的新代码改写器不扫不翻（runtime/rewriter/rewriter.c cpatch_rows phase 0），
    这里挡掉改写器在代码段里会改写 / 报缺口的指令（同 rewriter.c scan()：svc / 线程寄存器 / 计时器 / ctr / 系统寄存器 / brk 0xB000–0xBFFF / x18）→ 原因或 ''"""
    if (word & 0xff000000) == 0xd4000000 and (word & 3):   # svc / hvc / smc
        return f'{word:08x} 是系统调用'
    if (word & 0xffe0001f) == 0xd4200000 and 0xb000 <= (word >> 5) & 0xffff <= 0xbfff:
        return f'{word:08x} 是 brk #0x{(word >> 5) & 0xffff:x}（macOS 截走）'
    if (word & 0xffc00000) == 0xd5000000 and (word & 0xfffff01f) != 0xd503201f and (word & 0xfffff0ff) not in (0xd503309f, 0xd50330bf, 0xd50330df):
        return f'{word:08x} 是系统指令（读写系统寄存器）'   # 只放行 hint（nop 等）与 dsb / dmb / isb
    ins = next(_cs_one().disasm(struct.pack('<I', word), 0), None)
    if ins and re.search(r'\b[xw]18\b', ins.op_str): return f'{word:08x}（{ins.mnemonic} {ins.op_str}）用到 x18'
    return ''


def _cs_one():
    global _cs
    if _cs is None:
        import capstone
        _cs = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM); _cs.detail = True
    return _cs


# 宽屏补丁里的渲染尺寸（11-13 手测：一份 21:9 宽屏补丁把渲染尺寸写死成 3440×1440，是给 PC 模拟器「拉伸到窗口」用的；iPhone 照这个尺寸画 3D，场景糊成大块）：
#   补丁改到我方宽屏扫描认出的宽 / 高点（movz / movzh 宽、i2h / f2h 高，graphics/widen/scan/wide_scan.py）、新指令是 MOVZ / MOVK 立即数时，
#   按「高 1080、宽按补丁比例」等比缩（只缩不放：补丁高度不超过 1080 的不动）；比例、界面、相机这些补丁其余写入照旧
PHONE_H = 1080
def phone_res(words, kinds):
    """words {字偏移: 新字节}（就地改）；kinds {偏移: 种类}。→ 改了的说明「3440×1440 → 2580×1080」，没改 → ''"""
    def mov(w): return (w & 0x1F800000) == 0x12800000 and (w >> 29) & 3 in (2, 3)   # MOVZ / MOVK（32 / 64 位）
    ws, hs = {}, {}
    for o, nb in words.items():
        k, w = kinds.get(o), int.from_bytes(nb, 'little')
        if not k or not mov(w): continue
        imm = (w >> 5) & 0xFFFF
        if k in ('movz', 'movzh') and not (w >> 21) & 3: ws[o] = imm
        elif k in ('i2h', 'f2h') or k == 'movzh': hs[o] = imm
    H = max(hs.values(), default=0)
    if H <= PHONE_H or not ws: return ''
    sc = PHONE_H / H; was = f'{max(ws.values())}×{H}'
    for o, imm in list(ws.items()) + list(hs.items()):
        n = max(2, int(round(imm * sc / 2)) * 2); w = int.from_bytes(words[o], 'little')
        words[o] = bytearray(((w & ~(0xFFFF << 5)) | (n << 5)).to_bytes(4, 'little'))
    return f'{was} → {max(int(round(v * sc / 2)) * 2 for v in ws.values())}×{PHONE_H}'


def plan(root, default_on, index_dirs):
    exefs = os.path.join(root, 'exefs'); log = []
    xp = os.path.join(root, 'cpatch_excluded.tsv')
    excluded = {l.split('\t')[0] for l in open(xp).read().splitlines()} if os.path.exists(xp) else set()
    units = {}   # (编号, 模块) → {cat, name, license, path, writes}
    cheat_dirs = [d for d in os.environ.get('S2A_CHEATS_DIRS', '').split(os.pathsep) if d]   # Windows 路径带盘符冒号：按系统分隔符
    # 金手指原文随包（11-13 维护者手测：iPhone 金手指页是空的）：页面与服务层 Cheats.cs 都只读这款文档根 cheats/*.txt，出包只把改代码的条目编进 cpatch.tsv、
    #   txt 本身没到手机 → 页面无项、只写内存的条目也不执行。版本对得上的整份原文写到产物根 CHEAT_SHIP<原文件名>（随包表，ship_ext 拷进 App），
    #   宿主起局时放进文档根 cheats/（runtime/src/cpatch.c seed_cheats：不覆盖玩家导入的同名文件）。Mac 读游戏文件夹 cheats/ 本来就有原文，不用这一步
    for old in os.listdir(root):
        if old.startswith(CHEAT_SHIP): os.remove(os.path.join(root, old))
    ship = []
    for c in adapt_families(scan(index_dirs, exefs, log), exefs, log, root) + (scan_cheats(cheat_dirs, exefs, log, ship) if cheat_dirs else []):
        if c['id'] in excluded: continue
        u = units.setdefault((c['id'], c['module']), {'cat': c['cat'], 'name': c['name'], 'license': c['license'], 'path': c['path'], 'writes': [], 'meta': c['meta']})
        u['writes'] += c['writes']
    # 抢同一处时按目标选，不按索引先后（11-01 维护者：先到先得 = 随机选，01006F8002326000收进了 SpeedFix 120 帧版）。排在前面的先占位，后面同处的按「改同一处」落选：
    #   ① 帧率类：目标帧率 = 60 在前，取不到的其次，明确不是 60 的最后（我方目标 60 帧、只提画面帧；非帧率类不参与，视同第一档）
    #   ② 不要 romfs 参数表的在前，判不了的其次，要的最后（我方不打 romfs，缺参数表 = 逻辑速度保证不了）；判不了的若与某份判得了的
    #      写入逐字节相同（同一补丁的 IPS 与 pchtxt 两种格式）就沿用它的结论
    #   ③ 原顺序（索引顺序）作最后的平手规则，结果确定
    def flat(u): return frozenset((o + k, v) for o, b in u['writes'] for k, v in enumerate(b))
    known = {}
    for (uid, mod), u in units.items():
        if u['meta']['romfs'] != 1: known.setdefault((mod, flat(u)), u['meta']['romfs'])
    order = list(units)
    def rank(key):
        uid, mod = key; u = units[key]; m = u['meta']; rf = m['romfs'] if m['romfs'] != 1 else known.get((mod, flat(u)), 1)
        # ⓪ 自适应满屏（wsauto:，adapt_families 合成，任何画幅都铺满）先占位：同模块定画幅的宽屏变体（别家按单一画幅出的）与它改同一处就让它
        return (0 if uid.startswith('wsauto:') else 1, 0 if not uid.startswith('fps:') or m['fps'] == 60 else 1 if m['fps'] is None else 2, rf, order.index(key))
    ranked = sorted(units, key=rank)
    if ranked != order:
        print('社区补丁按目标排序（帧率 60 优先、不缺 romfs 参数表优先）：' + ' '.join(f"{k[0]}/{k[1]}({units[k]['meta']['fps'] or '?'} 帧，参数表{('不缺', '判不了', '缺')[rank(k)[2]]})" for k in ranked), file=sys.stderr)
    units = {k: units[k] for k in ranked}
    images = {}
    def img(mod):
        if mod not in images:
            _, segs = nso_image(os.path.join(exefs, mod)); b = bytearray(module_layout(os.path.join(exefs, mod))[3])   # 到键页前：bss 与其后的空余（全 0）也能写（金手指开关表搬过去）
            for mo, d in segs: b[mo:mo + len(d)] = d
            images[mod] = (bytes(b), segs[0][0] + len(segs[0][1]), segs[1][0], max(mo + len(d) for mo, d in segs))
        return images[mod]
    taken = {}   # (模块, 是否算宽屏候选) → 占用集合。预筛：不带补丁时的改写点（<模块>.sites.tsv）与宽屏候选点（widen_sites.tsv；asp / aspcap 类占两条）——双路字落在这里 = 两套改动叠在同一条指令上，
    # 补丁优先（11-13 维护者「补丁的优先级比咱们自己的高，满画幅是一样的」）：社区宽屏类（widescreen: / wsauto:）不让我方宽屏候选点——
    #   改写器 widen() 把补丁表改到的点让给补丁（rewriter.c cp_claimed），宽屏补丁开着时我方满屏整体让位（runtime/src/widen.c widen_setting_on）；
    #   原先有我方宽屏表的款整族宽屏补丁都被这里剔掉，玩家拿不到补丁
    def taken_at(mod, widen=True):   # 不等改写器一轮剔一份（暗黑3 实测 13 轮）；改写器自己那道检查照旧兜底
        if (mod, widen) not in taken:
            t = set(); sp = os.path.join(root, f'{mod}.sites.tsv'); wp = os.path.join(root, 'widen_sites.tsv')
            if os.path.exists(sp): t |= {int(l.split('\t')[0], 16) for l in open(sp) if l.startswith('0x')}
            # 宽屏候选点只在本款有我方宽屏表（启用表 / 整套放宽 / 已验证名单，stage_rewrite.sh 拷进产物根）时才算占用：没表 = 我方宽屏在这款不开，
            #   候选点让给社区补丁（改写器 widen() 跳过补丁表里有的点），社区宽屏补丁才进得来（荒野大镖客一类：补丁改的正是我方扫出的 asp 点）
            if widen and os.path.exists(wp) and glob.glob(os.path.join(root, 'widen_enable*.tsv')) + glob.glob(os.path.join(root, 'widen_full*.tsv')) + glob.glob(os.path.join(root, 'widen_verified.tsv')):
                for l in open(wp):
                    c = l.rstrip('\n').split('\t')
                    if len(c) >= 3 and c[0] == mod and c[1].startswith('0x'): o = int(c[1], 16); t.add(o); t.add(o + 4) if c[2] in ('asp', 'aspcap', 'aspcaps') else None
            taken[(mod, widen)] = t
        return taken[(mod, widen)]
    fp = os.path.join(root, 'fps.tsv')   # 本款已有我方帧率表（c 行改指令）：社区帧率类不收，免得两套在同一款里各改各的（帧率能耗线 10-27 约定）
    own_fps = os.path.exists(fp) and any(l.split('#', 1)[0].split()[:1] == ['c'] for l in open(fp, encoding='utf-8', errors='replace'))
    claim = {}; bits = {}; rows = []; table = []; branch_cache = {}; cheats = []
    uasp = {uid: u['meta'].get('aspect') for (uid, _), u in units.items() if uid.startswith('widescreen:')}
    ufps = {uid: u['meta'].get('fps') for (uid, _), u in units.items() if uid.startswith('fps:')}   # 帧率档位（11-13 维护者：60 / 120 都带进去，玩家自己切）
    wk = {}
    def wkinds(mod):   # 本模块宽屏候选点 {偏移: 种类}（widen_sites.tsv；与有没有我方宽屏表无关）
        if mod not in wk:
            wp = os.path.join(root, 'widen_sites.tsv'); t = {}
            if os.path.exists(wp):
                for l in open(wp):
                    c = l.rstrip('\n').split('\t')
                    if len(c) >= 3 and c[0] == mod and c[1].startswith('0x'): t[int(c[1], 16)] = c[2]
            wk[mod] = t
        return wk[mod]
    asp_took = {}   # (模块, 画幅) → 已收的那份：同画幅只留排前的一份（变体之间互为兄弟可改同一处，同画幅的去重不能靠「改同一处」）
    npath = {}   # (模块, 字偏移) → 已挂的双路条数：同点画幅变体各占一路，改写器一点最多 CP_VAR_MAX（8）路
    for (uid, mod), u in units.items():
        im, text_end, ro, file_end = img(mod); words = {}; data = {}; why = ''; cheat = uid.startswith('cheat:')
        ad = u['meta'].get('adapt') or {}; marks = ad.get('marks', {}); adata = [x for x in ad.get('adata', []) if not str(x[0]).startswith('k')]   # 自适应画幅（adapt_families）：@k 行与按画幅算的数据写入
        A0 = u['meta'].get('aspect') if uid.startswith('widescreen:') else None
        # 宽 / 窄兄弟：运行时只开一份，可改同一处。画幅不同的宽屏补丁同理（runtime/src/cpatch.c 按当前屏幕比例只开最近的一份）；同画幅的两份照旧按「改同一处」落选（排前的留下）
        F0 = ufps.get(uid) if uid.startswith('fps:') else None
        # 兄弟（运行时只开其一，可改同一处）：自适应画幅宽 / 窄两份；画幅不同的定画幅宽屏变体；目标帧率不同的帧率补丁（60 / 120 …，运行时按玩家选的档只开一份，
        #   runtime/src/cpatch.c fps_pick）。目标相同的两份照旧按「改同一处」落选
        sib = lambda x: (uid.startswith('wsauto:') and x.startswith('wsauto:') and x.rsplit(':', 1)[0] == uid.rsplit(':', 1)[0]) or \
            (A0 is not None and x.startswith('widescreen:') and uasp.get(x) is not None and abs(uasp[x] - A0) > 1e-3) or \
            (F0 and x.startswith('fps:') and ufps.get(x) and ufps[x] != F0) or \
            (cheat and x.startswith('cheat:'))
        # 金手指之间改同一处代码（攻速 x2 / x3、伤害 x2 / x5 这类几档写法；几份文件各带一套同样的几档，11-13 实测）：都是兄弟——
        #   不同的新字分到不同的位（下面 owners 按「同处同值的条目集合」分位），改写器同一点按行序依次测位、多路并存（CP_VAR_MAX，超了记缺口、prune 剔掉）。
        #   只认「前一个占位者」不够：一份的 x3 占着时另一份的 x2 会被判冲突。几档同时开时 Atmosphere 每帧按顺序执行、后写的生效，
        #   所以金手指的 p 行按条目倒序输出（跳板先测到的生效）
        # 金手指专用（11-12）：映像到键页前（bss 与其后空余可写，开关表搬过去）、写原值的字节不占（暗黑 3 主控把空洞清零）、
        #   代码段结尾到 ro 开头的尾巴当代码字（金手指往这里写新代码，改写器按 w 行常写）。社区补丁照原判定
        ext = cheat or u['meta'].get('ext')   # FPSLocker 单元同此规则
        lim, code_end = (len(im), ro) if ext else (file_end, text_end)
        for off, b in u['writes']:
            if off < 0 or off + len(b) > lim: why = f'写入 {off:#x}+{len(b)} 超出模块映像'; break
            for k, v in enumerate(b):
                o = off + k
                if cheat and im[o] == v: continue
                if o < code_end: w0 = o & ~3; words.setdefault(w0, bytearray(words.get(w0) or im[w0:w0 + 4]))[o - w0] = v
                else: data[o] = v
        # 金手指写的全是原值（「… off / normal」这类：把某档改回原指令）：照样登记进表（位 -、无数据写入），运行时按「编进游戏」处理——开关只记一笔，
        #   写代码页的行由包接管、静默跳过。原先判「不用改」不进表，运行时照写代码页、标「改代码，不支持」（11-13 实测；那个字常是别的档的双路点，
        #   内存里已是跳板，运行时比不了原值）。与改同处的那档同时开时，那档生效（Atmosphere 是后写的生效，这种组合本身无意义）
        if not why and uid.startswith('widescreen:'):
            r = phone_res(words, wkinds(mod))
            if r: log.append(f'改值\t{uid}\t{mod}\t渲染尺寸按手机口径：{r}')
        if not why and any(fill(im, o) for o, k in marks.items() if k == 'kv'): why = f'取值点 {mod}+{min(o for o, k in marks.items() if k == "kv" and fill(im, o)):#x} 落在填充区（填充区常写，没有原路可分）'
        if not why:
            for o, n, k in adata:
                if o + n > lim or o < ((text_end + 0x3FFF) & ~0x3FFF): why = f'画幅值写入 {mod}+{o:#x} 不在可写数据区'; break
                for b in range(o, o + n):
                    if b in data: why = f'画幅值写入 {mod}+{o:#x} 与本份数据写入重叠'; break
                    prev = claim.get((mod, b))
                    if prev and prev[0] != uid and not sib(prev[0]): why = f'与 {prev[0]} 改同一处 {mod}+{b:#x}'; break
                if why: break
        if not why:
            for w0, nb in sorted(words.items()):
                h = tail_hazard(int.from_bytes(nb, 'little')) if w0 >= text_end else ''
                if h: why = f'代码段尾巴 {mod}+{w0:#x} 的新代码 {h}（改写器不翻译那一段）'; break
        if not why:   # 同处同值的填充字（常写）两份都要也不算冲突：写一次结果一样
            for o in list(words) + list(data):
                prev = claim.get((mod, o))
                # 金手指之间：同处同值的代码字共用（共享挂钩 / 共享空洞代码，任一条开着就生效）；数据重叠是互斥的变体（伤害 x2 / x5…），开关时按顺序写
                share = cheat and prev and prev[3] and (not prev[1] and o in data or prev[1] and o in words and prev[2] == bytes(words[o]))
                fsame = prev and prev[1] and o in words and prev[2] == bytes(words[o])
                if prev and prev[0] != uid and not share and not (fsame and fill(im, o)) and not (sib(prev[0]) and (o not in words or not fill(im, o) or fsame)): why = f'与 {prev[0]} 改同一处 {mod}+{o:#x}'; break
        if not why:   # 数据补丁运行时由装载器写：代码段末页（向上取整到 16 KB 之前）与代码同页、只读可执行，写不了（同 runtime/src/widen.c aspf 的可写范围）
            low = sorted(o for o in data if o < (text_end + 0x3FFF) & ~0x3FFF)
            if low: why = f'数据写入 {mod}+{low[0]:#x} 落在代码段末页上（只读可执行，运行时写不了）'
        if not why:
            hit = sorted(w0 for w0, nb in words.items() if w0 in taken_at(mod, not uid.startswith(('widescreen:', 'wsauto:'))) and int.from_bytes(im[w0:w0 + 4], 'little') >> 16)
            if hit: why = f'改到我方改写点 {mod}+{hit[0]:#x}（宽屏点 / x18 等，两套改动叠在同一条指令上）'
        if not why and A0 is not None and (mod, round(A0, 3)) in asp_took: why = f'同画幅（{A0:.3f}）已收 {asp_took[(mod, round(A0, 3))]}'
        if not why:
            full = sorted(w0 for w0, nb in words.items() if not fill(im, w0) and bytes(nb) != im[w0:w0 + 4] and npath.get((mod, w0), 0) >= 8)
            if full: why = f'{mod}+{full[0]:#x} 已挂满 8 路双路（同点画幅变体太多）'
        if not why and own_fps and uid.startswith('fps:'): why = '本款已有我方帧率表（fps.tsv），社区帧率类不收'
        # 金手指：改有效指令（p 行）才占槽 2046 的位，只写填充 / 数据的不占（运行时按 s2a_cpatch_cheat 开关数据）；社区补丁照旧每份一位（运行时按位与数据一起开关）
        needs_bit = not cheat or any(not fill(im, w0) and bytes(nb) != im[w0:w0 + 4] for w0, nb in words.items())
        if not why and needs_bit and not cheat and bits.get(mod, 0) >= 64: why = f'{mod} 已有 64 份补丁（槽 2046 位数用尽）'
        if not why:   # 数据流旁路（见 flow_hazard）：补丁设了又读的寄存器，原版有路从区间外跳进两者之间
            ch = {w0: (int.from_bytes(im[w0:w0 + 4], 'little'), int.from_bytes(nb, 'little')) for w0, nb in words.items() if bytes(nb) != im[w0:w0 + 4]}
            if ch: why = flow_hazard(im, text_end, mod, ch, branch_cache)
        if why: log.append(f'不收\t{uid}\t{mod}\t{u["name"][:40]}\t{why}'); continue
        if cheat:   # 位等全部收完再按「共用这条改动的条目集合」分（见下）
            for o in words: claim[(mod, o)] = (uid, True, bytes(words[o]), True)
            for o in data: claim[(mod, o)] = (uid, False, None, True)
            cheats.append((uid, mod, u, words, data)); continue
        if needs_bit: bit = bits.get(mod, 0); bits[mod] = bit + 1
        else: bit = '-'
        if A0 is not None: asp_took[(mod, round(A0, 3))] = uid
        for o in words: claim[(mod, o)] = (uid, True, bytes(words[o]), False)
        for o in data: claim[(mod, o)] = (uid, False, None, False)
        for o, n, k in adata:
            for b in range(o, o + n): claim[(mod, b)] = (uid, False, None, False)
        for w0, nb in sorted(words.items()):
            orig = int.from_bytes(im[w0:w0 + 4], 'little'); new = int.from_bytes(nb, 'little')
            if new == orig: continue
            if fill(im, w0):   # 填充（全 0 / udf #imm16）：常写；同处同值别的份已写过就不重复
                r = f'w\t{mod}\t{w0:x}\t{orig:08x}\t{new:08x}' + ('\t@k' if marks.get(w0) == 'k' else '')
                if not any(x.startswith(r + '\t') for x in rows): rows.append(f'{r}\t# {uid}')
            else:
                rows.append(f'p\t{mod}\t{w0:x}\t{orig:08x}\t{new:08x}\t{bit}' + ('\t@k' if marks.get(w0) == 'kv' else '') + f'\t# {uid}')
                npath[(mod, w0)] = npath.get((mod, w0), 0) + 1
        runs, cur = [], None
        for o in sorted(data):
            if cur and o == cur[0] + len(cur[1]): cur[1].append(data[o]); continue
            cur = [o, bytearray([data[o]])]; runs.append(cur)
        dw = ' '.join([f'{o:x}:{im[o:o + len(b)].hex()}:{bytes(b).hex()}' for o, b in runs] + [f'{o:x}:{im[o:o + n].hex()}:@{k}{n}' for o, n, k in adata] + [f'{o}::@{k}{n}' for o, n, k in ad.get('adata', []) if str(o).startswith('k')])
        table.append((uid, mod, bit, u, dw))
        log.append(f'收\t{uid}\t{mod}\t{u["name"][:40]}\t' + (f'位 {bit}' if needs_bit else '不占位（只写填充 / 数据）') + f'，代码 {len(words)} 字、数据 {len(data)} 字节')
    # 金手指的位：一条改有效指令的 p 行属于「写它的全部条目」，按这个条目集合分位（同一集合的 p 行共用一位）；条目开着 = 它所在的各集合的位置 1
    #   （runtime/src/cpatch.c 按「位」列的逗号表求掩码）。共享挂钩被几条共用时，任一条开着挂钩就生效，各条的效果由各自的开关字（数据写入）决定
    owners = {}
    for uid, mod, u, words, data in cheats:
        im = img(mod)[0]
        for w0, nb in words.items():
            if not fill(im, w0) and bytes(nb) != im[w0:w0 + 4]: owners.setdefault((mod, w0, bytes(nb)), []).append(uid)
    setbit = {}; ubits = {}; dropped = set()
    for (mod, w0, nb), us in owners.items():
        k = (mod, frozenset(us))
        if k not in setbit:
            if bits.get(mod, 0) >= 64: dropped |= set(us); continue
            setbit[k] = bits.get(mod, 0); bits[mod] = setbit[k] + 1
        for x in us: ubits.setdefault(x, set()).add(setbit[k])
    crows = []   # 金手指各条的行：倒序并进 rows（见上「后写的生效」）
    for uid, mod, u, words, data in cheats:
        if uid in dropped: log.append(f'不收\t{uid}\t{mod}\t{u["name"][:40]}\t{mod} 槽 2046 的 64 位用尽'); continue
        im = img(mod)[0]; mine = []
        for w0, nb in sorted(words.items()):
            orig = int.from_bytes(im[w0:w0 + 4], 'little'); new = int.from_bytes(nb, 'little')
            if new == orig: continue
            if fill(im, w0): r = f'w\t{mod}\t{w0:x}\t{orig:08x}\t{new:08x}'
            else: r = f'p\t{mod}\t{w0:x}\t{orig:08x}\t{new:08x}\t{setbit[(mod, frozenset(owners[(mod, w0, bytes(nb))]))]}'
            mine.append((r, f'{r}\t# ' + ','.join(owners.get((mod, w0, bytes(nb)), [uid]))))
        crows.append(mine)
        runs, cur = [], None
        for o in sorted(data):
            if cur and o == cur[0] + len(cur[1]): cur[1].append(data[o]); continue
            cur = [o, bytearray([data[o]])]; runs.append(cur)
        dw = ' '.join(f'{o:x}:{im[o:o + len(b)].hex()}:{bytes(b).hex()}' for o, b in runs)
        bl = ','.join(map(str, sorted(ubits.get(uid, ())))) or '-'
        table.append((uid, mod, bl, u, dw))
        log.append(f'收\t{uid}\t{mod}\t{u["name"][:40]}\t' + (f'位 {bl}，代码 {len(words)} 字、数据 {len(data)} 字节' if words or data else '全部写入与原值相同：空操作，登记为编进包'))
    for mine in reversed(crows):
        for r, line in mine:
            if not any(x.startswith(r + '\t') for x in rows): rows.append(line)
    on = set(x for x in default_on.split(',') if x)
    with open(os.path.join(root, 'cpatch_rows.tsv'), 'w') as f: f.write('\n'.join(rows) + ('\n' if rows else ''))
    # FPSLocker 收下的单元：定期写入表交运行时（services/S2A.Services/FpsLocker.cs，随包表 fpslocker.json）；没有就删掉旧表
    fl = [dict(id=uid, all_fps=u['meta']['fpsl']['all_fps']) for uid, mod, bit, u, dw in table if u['meta'].get('fpsl')]
    fp_json = os.path.join(root, 'fpslocker.json')
    if fl:
        import json
        with open(fp_json, 'w', encoding='utf-8') as f: json.dump(dict(schema=1, units=fl), f, ensure_ascii=False)
    elif os.path.exists(fp_json):
        os.remove(fp_json)
    for n, raw in ship:
        with open(os.path.join(root, CHEAT_SHIP + n), 'wb') as f: f.write(raw)
    if ship: log.append(f'金手指原文随包\t-\t-\t' + '、'.join(n for n, _ in ship))
    with open(os.path.join(root, 'cpatch.tsv'), 'w') as f:
        # 目标帧率（第 10 列，11-13 维护者「补丁优先：有 120 帧补丁就盖过我们的 60 帧」）：帧率类写补丁目标（索引 target_fps / 名字里的「<数> fps」），
        #   宿主按它定出图上限（runtime/src/cpatch.c：> 60 开 120 Hz 出图）；别的类与认不出的写空
        # 画幅（第 11 列）：宽屏类写补丁画幅（宽 ÷ 高，aspect_of），宿主在开着的几份里按当前屏幕比例只开最近的一份、上屏按它铺满（runtime/src/cpatch.c）；认不出的写空（照旧单独开关）
        f.write('编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅\t模式\n')
        for uid, mod, bit, u, dw in table:
            tf = (u.get('meta') or {}).get('fps') if uid.startswith('fps:') else None
            ta = (u.get('meta') or {}).get('aspect') if uid.startswith('widescreen:') else None
            # 第 12 列模式（自适应满屏，11-13）：both = 主机 / 掌机两档渲染尺寸都按画幅（出包补齐了另一档）；docked = 只有主机档（宿主切主机模式）；空 = 不涉渲染尺寸
            md = ('both' if '@y4/' in dw else 'docked') if uid.startswith('wsauto:') and '@x4' in dw else ''
            f.write('\t'.join([uid, mod, str(bit), u['cat'], re.sub(r'[\t\n]', ' ', u['name']), u['license'], u['path'], dw, '1' if uid in on else '0', str(tf) if tf else '', f'{ta:.4f}' if ta else '', md]) + '\n')
    with open(os.path.join(root, 'cpatch_plan.log'), 'a') as f: f.write('\n'.join(log) + '\n')
    print(f'社区补丁 {len(units)} 份匹配，进包 {len(table)} 份', file=sys.stderr)
    return 0


def prune(root):
    """改写器对某份补丁记了 cpatch 缺口 → 那份整份剔掉；退出码 10 = 剔了（要重跑改写），0 = 稳定"""
    rp = os.path.join(root, 'cpatch_rows.tsv')
    if not os.path.exists(rp): return 0
    rows = open(rp).read().splitlines(); owner = {}
    for l in rows:
        c = l.split('\t'); owner[(c[1], int(c[2], 16))] = l.rsplit('# ', 1)[-1]
    bad = {}
    for g in os.listdir(root):
        if not g.endswith('.gaps.tsv'): continue
        mod = g[:-len('.gaps.tsv')]
        for l in open(os.path.join(root, g), encoding='utf-8', errors='replace'):
            c = l.rstrip('\n').split('\t')
            if len(c) >= 2 and c[1] == 'cpatch':
                try: o = int(c[0], 16)
                except ValueError: continue
                for k in owner.get((mod, o), '').split(','):   # 金手指共用的行注释里是全部共用者：都剔（共用的挂钩生成不了，哪条都用不上）
                    if k: bad.setdefault(k, f'{mod}+{o:#x} {c[2] if len(c) > 2 else ""}')
    if not bad: return 0
    with open(os.path.join(root, 'cpatch_excluded.tsv'), 'a') as f: f.write(''.join(f'{k}\t改写器缺口：{v}\n' for k, v in bad.items()))
    with open(os.path.join(root, 'cpatch_plan.log'), 'a') as f: f.write(''.join(f'不收\t{k}\t改写器缺口：{v}\n' for k, v in bad.items()))
    print(f'社区补丁：改写器对 {len(bad)} 份记了缺口，记进排除清单、重跑 plan', file=sys.stderr)
    return 10


def main(a):
    if len(a) >= 3 and a[0] == 'scan' and '--exefs' in a:
        i = a.index('--exefs'); dirs = a[1:i]; exefs = a[i + 1]
        for c in scan(dirs, exefs): print(f"{c['module']}\t{c['cat']}\t{c['name'][:60]}\t{len(c['writes'])}\t{c['license']}\t{c['path']}")
        return 0
    if len(a) >= 3 and a[0] == 'plan': return plan(a[1], a[2], a[3:])
    if len(a) == 2 and a[0] == 'prune': return prune(a[1])
    sys.exit(__doc__)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
