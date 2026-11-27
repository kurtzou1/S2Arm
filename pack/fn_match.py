#!/usr/bin/env python3
"""逐款表按函数指纹跨版本匹配（runtime/fix、runtime/fps 的 match/<程序号>.tsv）。

精确表 runtime/{fix,fps}/<main 构建号前 16 位>.tsv 只对一个构建号生效；游戏一更新就得逐版本重找。
指纹规则记「改哪个函数的第几个字」，出包时在这一版的 main 里按函数指纹找到同一个函数，再展开成精确行交改写器，
改写器（runtime/rewriter/rewriter.c fix_rows / fps_rows）一行不改。思路同 seedds/nxnative dm/tools/nso_match.py（MIT）。

指纹：
  函数边界只认 main 自带的 eh_frame（.eh_frame_hdr 二分表），不猜边界。
  函数体逐字归一化，只掩与地址有关的位：跳出本函数的 b / bl / b.cond / cbz / cbnz / tbz / tbnz 的偏移位，
  adrp 的页号位（及其后 8 条内以它为基址的 add / ldr / str 低 12 位），跳出本函数的 adr、字面量 ldr 的偏移位；
  函数内跳转、常量、寄存器、结构体偏移原样保留。sha256(归一化字) 为函数体摘要。
  指纹 = sha256(函数体摘要 + 每个跳出点（偏移、被调者）)：被调者是有边界的函数记（大小、函数体摘要），
  是导入记符号名，是 svc 包装（svc #n; ret）记调用号；都不是 → 这个函数不能当锚点（MatchError）。

规则文件（runtime/fix/match/<程序号>.tsv、runtime/fps/match/<程序号>.tsv）：
  group <组名>                         组内的函数要么全部恰好命中一个、全部核过原字，要么整组不打
  checked <bid16> [<bid16> …]          这一组在哪些构建号上人核过（缺陷修补类只在这些构建号上打；帧率 / 步长类命中即打）
  match <规则名> <模块> <函数大小> <指纹> 定位一个函数；后面的 c 行属于它
  c <模块> +<相对偏移> <种类> <原字> …   同精确表 c 行，偏移相对函数起点；跳板体里 bl:@<规则名>+<相对偏移> 换算成模块偏移
  end                                  组结束
  when fix <组名>                      （只帧率表）文件里的非 c 行（build / present / speed / slot …）只在这一修补组打上时随包
  其余非 c 行（帧率表的 present / speed / slot / present30）原样带进展开结果；build 行由展开时写本构建号。
  w 行（数据段地址）不支持：要跨版本换算得另解 adrp 配对，带 w 行的表留在精确表。

匹配不唯一不猜：0 个命中 → 这一组在本版不适用（记一行黄）；≥2 个 → 打红、整组不打；
定位后原字有一处不符 → 打红、整组不打（指纹相同字却不同，要人查）。
精确表优先：本构建号有精确表就用精确表，同类的 match 不展开。

用法：
  fn_match.py derive <精确表.tsv> <exefs/main> [--out <match.tsv>]   从精确表生成规则（只给本版本的 main），并核展开后逐字一致
  fn_match.py expand <match.tsv> <exefs/main> --kind fix|fps [--out <表>]
  fn_match.py tables <程序号> <exefs/main> <工作目录>                   出包用：打印「fix\\t<路径或 ->」「fps\\t<路径或 ->」，过程写标准错误
"""
import bisect
import hashlib
import re
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'graphics/nvn/tools'))


class MatchError(ValueError):
    pass


def _signed(n, bits):
    return n - (1 << bits) if n & (1 << (bits - 1)) else n


def _relative(w):
    """直接跳转：(偏移位掩码, 有符号字节位移)；不是 → None"""
    if w & 0x7c000000 == 0x14000000: return 0x03ffffff, _signed(w & 0x3ffffff, 26) * 4        # b / bl
    if w & 0xff000010 == 0x54000000 or w & 0x7e000000 == 0x34000000:                          # b.cond / cbz / cbnz
        return 0x00ffffe0, _signed((w >> 5) & 0x7ffff, 19) * 4
    if w & 0x7e000000 == 0x36000000: return 0x0007ffe0, _signed((w >> 5) & 0x3fff, 14) * 4    # tbz / tbnz
    return None


def load_nso(path):
    """exefs/main（NSO）→ (内存映像, 代码段末尾, 构建号十六进制)"""
    from lz4blk import lz4_block
    d = Path(path).read_bytes()
    if d[:4] != b'NSO0': raise MatchError(f'{path} 不是 NSO')
    flags = struct.unpack_from('<I', d, 0xc)[0]
    segs = [struct.unpack_from('<III', d, 0x10 + i * 0x10) for i in range(3)]
    csz = struct.unpack_from('<III', d, 0x60)
    img = bytearray(segs[2][1] + segs[2][2])
    for i, (fo, mo, sz) in enumerate(segs):
        raw = d[fo:fo + csz[i]]
        img[mo:mo + sz] = lz4_block(raw, sz) if flags >> i & 1 else raw
    return bytes(img), segs[0][1] + segs[0][2], d[0x40:0x50].hex()


class Image:
    def __init__(self, img, text_end):
        self.img, self.text_end = img, min(text_end, len(img))
        self.functions = self._eh_frame()
        self.starts = sorted(self.functions)
        self._bodies, self._fps, self._imports = {}, {}, None

    def _eh_frame(self):
        img = self.img
        m0 = struct.unpack_from('<I', img, 4)[0]
        if img[m0:m0 + 4] != b'MOD0': raise MatchError('没有 MOD0，读不了函数边界')
        ehs = m0 + struct.unpack_from('<i', img, m0 + 16)[0]
        _, penc, cenc, tenc = img[ehs:ehs + 4]
        if (penc, cenc, tenc) != (0x1b, 0x03, 0x3b): raise MatchError(f'eh_frame_hdr 编码 {penc:#x} {cenc:#x} {tenc:#x} 不认')
        out = {}
        for i in range(struct.unpack_from('<I', img, ehs + 8)[0]):
            loc, fde = struct.unpack_from('<ii', img, ehs + 12 + i * 8)
            loc, fde = loc + ehs, fde + ehs
            pc0 = fde + 8 + struct.unpack_from('<i', img, fde + 8)[0]
            size = struct.unpack_from('<I', img, fde + 12)[0]
            if pc0 != loc or loc % 4 or size % 4 or not 0 <= loc < loc + size <= self.text_end: continue
            if loc in out and out[loc] != size: raise MatchError(f'{loc:#x} 处函数边界冲突')
            out[loc] = size
        if not out: raise MatchError('eh_frame 里没有函数')
        return out

    def containing(self, off):
        i = bisect.bisect_right(self.starts, off) - 1
        if i >= 0 and off < self.starts[i] + self.functions[self.starts[i]]: return self.starts[i]
        return None

    def word(self, off):
        return struct.unpack_from('<I', self.img, off)[0]

    def body(self, start):
        """(归一化后的函数体摘要, [(相对偏移, 跳出目标)])"""
        if start in self._bodies: return self._bodies[start]
        end = start + self.functions[start]
        words = list(struct.unpack_from(f'<{(end - start) // 4}I', self.img, start))
        norm, outs = words.copy(), []
        for i, w in enumerate(words):
            pc = start + i * 4
            rel = _relative(w)
            if rel:
                mask, delta = rel
                if not start <= pc + delta < end:
                    norm[i] &= ~mask & 0xffffffff
                    outs.append((i * 4, pc + delta))
                continue
            if w & 0x1f000000 == 0x10000000:   # adr / adrp
                imm = _signed(((w >> 29) & 3) | (((w >> 5) & 0x7ffff) << 2), 21)
                if w & 0x80000000 or not start <= pc + imm < end:
                    norm[i] &= 0x9f00001f
                if w & 0x80000000:   # adrp：其后以它为基址的 add / ldr / str 低 12 位是页内地址
                    rd = w & 31
                    for j in range(i + 1, min(i + 9, len(words))):
                        u = words[j]
                        if (u & 0xff800000 == 0x91000000 or u & 0x3b000000 == 0x39000000) and (u >> 5) & 31 == rd:
                            norm[j] &= ~0x3ffc00 & 0xffffffff
                            break
                        if _relative(u) or u & 0xfffffc1f == 0xd61f0000 or u == 0xd65f03c0: break   # 跳转 / br / ret
                        if u & 31 == rd and u & 0x9f000000 != 0x90000000 and u & 0x3b000000 != 0x39000000: break   # 目的寄存器被别的指令改写
                continue
            if w & 0x3b000000 == 0x18000000:   # 字面量 ldr
                if not start <= pc + _signed((w >> 5) & 0x7ffff, 19) * 4 < end:
                    norm[i] &= 0xff00001f
        digest = hashlib.sha256(struct.pack(f'<{len(norm)}I', *norm)).hexdigest()
        self._bodies[start] = digest, outs
        return digest, outs

    def _import_slots(self):
        """GOT 槽 → 导入符号名（DT_JMPREL 的 R_AARCH64_JUMP_SLOT）；读不出就空"""
        if self._imports is not None: return self._imports
        self._imports, img = {}, self.img
        try:
            m0 = struct.unpack_from('<I', img, 4)[0]
            dyn = m0 + struct.unpack_from('<i', img, m0 + 4)[0]
            tags = {}
            for pos in range(dyn, min(len(img) - 15, dyn + 4096 * 16), 16):
                tag, val = struct.unpack_from('<qQ', img, pos)
                if tag == 0: break
                tags[tag] = val
            if tags.get(20) != 7: return self._imports            # DT_PLTREL 须为 DT_RELA
            for pos in range(tags[23], tags[23] + tags[2], 24):    # DT_JMPREL, DT_PLTRELSZ
                slot, info, _ = struct.unpack_from('<QQq', img, pos)
                if info & 0xffffffff != 1026: continue             # R_AARCH64_JUMP_SLOT
                name = struct.unpack_from('<I', img, tags[6] + (info >> 32) * 24)[0] + tags[5]   # DT_SYMTAB, DT_STRTAB
                self._imports[slot] = img[name:img.index(0, name)].decode('utf-8', 'replace')
        except (KeyError, ValueError, IndexError, struct.error):
            self._imports = {}
        return self._imports

    def _callee(self, target):
        if target in self.functions:
            return ('f', self.functions[target], self.body(target)[0])
        if 0 <= target <= self.text_end - 16:
            a, b, c, d = struct.unpack_from('<4I', self.img, target)
            if a & 0xffe0001f == 0xd4000001 and b == 0xd65f03c0:   # svc #n; ret
                return ('svc', (a >> 5) & 0xffff)
            if a & 0x9f00001f == 0x90000010 and b & 0xffc003ff == 0xf9400211 and c & 0xffc003ff == 0x91000210 and d == 0xd61f0220:   # PLT 项
                page = (target & ~0xfff) + (_signed(((a >> 29) & 3) | (((a >> 5) & 0x7ffff) << 2), 21) << 12)
                name = self._import_slots().get(page + ((b >> 10) & 0xfff) * 8)
                if name: return ('imp', name)
        raise MatchError(f'被调者 {target:#x} 既没有函数边界也不是导入 / svc 包装')

    def fingerprint(self, start):
        if start not in self._fps:
            digest, outs = self.body(start)
            h = hashlib.sha256(digest.encode())
            for off, target in outs:
                h.update(f'|{off:x}:{self._callee(target)!r}'.encode())
            self._fps[start] = h.hexdigest()
        return self._fps[start]

    def find(self, size, prints):
        """大小为 size、指纹在 prints 里的全部函数起点（指纹算不出的函数不算命中）"""
        out = []
        for s, n in self.functions.items():
            if n != size: continue
            try:
                if self.fingerprint(s) in prints: out.append(s)
            except MatchError:
                pass
        return sorted(out)


def _bl_tokens(fields):
    return [i for i, f in enumerate(fields) if f.startswith('bl:')]


def derive(table_text, img, bid16, module='main'):
    """精确表 → 规则文本（一组，checked = 本构建号）。表里每个改字点所在函数都要在本版本里指纹唯一"""
    rows, carry = [], []
    for line in table_text.splitlines():
        body = line.split('#', 1)[0].split()
        if not body: continue
        if body[0] == 'w': raise MatchError('w 行是数据段地址，指纹规则暂不支持：这张表留在精确表')
        if body[0] == 'build': continue
        if body[0] != 'c': carry.append(line.rstrip()); continue
        if body[1] != module: raise MatchError(f'只支持 {module} 模块的行：{line.strip()}')
        rows.append((line, body))
    if not rows: raise MatchError('表里没有 c 行，没有可当锚点的代码')
    funcs, out_rows = {}, []

    def anchor(off):
        s = img.containing(off)
        if s is None: raise MatchError(f'{off:#x} 不在任何有边界的函数里')
        if s not in funcs:
            fp = img.fingerprint(s)
            hits = img.find(img.functions[s], {fp})
            if hits != [s]: raise MatchError(f'{s:#x} 处函数在本版本里指纹不唯一（{len(hits)} 个），不能当锚点')
            funcs[s] = (f'f{s:x}', img.functions[s], fp)
        return s

    for line, body in rows:
        off = int(body[2], 16)
        s = anchor(off)
        fields = body[:]
        fields[2] = f'+{off - s:#x}'
        for i in _bl_tokens(fields):
            t = int(fields[i][3:], 16)
            ts = anchor(t)
            fields[i] = f'bl:@{funcs[ts][0]}+{t - ts:#x}'
        reason = line.split('#', 1)[1].strip() if '#' in line else ''
        out_rows.append((s, '\t'.join(fields) + (f'\t# {reason}' if reason else '')))
    text = [f'# 由 {bid16}.tsv 生成（pack/fn_match.py derive）：偏移相对函数起点，按函数指纹在别的版本里定位', f'group {bid16}', f'checked {bid16}']
    for s in sorted(funcs):
        name, size, fp = funcs[s]
        text.append(f'match\t{name}\t{module}\t{size:#x}\t{fp}')
        text += [r for rs, r in out_rows if rs == s]
    text.append('end')
    return '\n'.join(text + carry) + '\n'


def parse(text):
    """规则文本 → {'groups': [...], 'carry': [...], 'when': 组名 | None}"""
    groups, carry, when, cur, rule = [], [], None, None, None
    for n, line in enumerate(text.splitlines(), 1):
        body = line.split('#', 1)[0].split()
        if not body: continue
        k = body[0]
        if k == 'group':
            if cur: raise MatchError(f'第 {n} 行：group 没有 end 就开了新组')
            cur = dict(name=body[1], checked=set(), rules=[])
        elif k == 'end':
            if not cur: raise MatchError(f'第 {n} 行：end 前没有 group')
            groups.append(cur); cur = rule = None
        elif k == 'checked':
            if not cur: raise MatchError(f'第 {n} 行：checked 要在组里')
            cur['checked'] |= {b.lower()[:16] for b in body[1:]}
        elif k == 'match':
            if not cur: raise MatchError(f'第 {n} 行：match 要在组里')
            rule = dict(name=body[1], module=body[2], size=int(body[3], 16), prints=set(body[4:]), rows=[])
            cur['rules'].append(rule)
        elif k == 'c':
            if not rule: raise MatchError(f'第 {n} 行：c 行前没有 match')
            if not body[2].startswith('+'): raise MatchError(f'第 {n} 行：规则里的偏移要写成相对函数起点（+0x…）')
            rule['rows'].append((body, line.split('#', 1)[1].strip() if '#' in line else ''))
        elif k == 'when':
            if body[1:2] != ['fix'] or len(body) != 3: raise MatchError(f'第 {n} 行：只认 when fix <组名>')
            when = body[2]
        elif k == 'w':
            raise MatchError(f'第 {n} 行：w 行（数据段地址）规则里不支持')
        elif k == 'build':
            continue
        else:
            if cur: raise MatchError(f'第 {n} 行：组里只认 checked / match / c / end')
            carry.append(line.rstrip())
    if cur: raise MatchError('文件末尾组没有 end')
    return dict(groups=groups, carry=carry, when=when)


def expand(text, img, bid16, kind, fix_applied=()):
    """规则 → (精确表文本 | None, 已打的组名, 日志行)。kind = fix：只在 checked 的构建号上打；fps：命中即打"""
    spec, bid16 = parse(text), bid16.lower()[:16]
    lines, applied, log = [], [], []
    for g in spec['groups']:
        where, ok = {}, True
        for r in g['rules']:
            hits = img.find(r['size'], r['prints']) if r['module'] == 'main' else []
            if len(hits) != 1:
                ok = False
                log.append(f'【红】fn_match {g["name"]}/{r["name"]}：本版有 {len(hits)} 个函数指纹相同，不唯一、整组不打' if hits
                           else f'【黄】fn_match {g["name"]}/{r["name"]}：本版没找到（不是这段代码），整组不适用')
                break
            where[r['name']] = hits[0]
        if not ok: continue
        out = []
        for r in g['rules']:
            s = where[r['name']]
            for body, reason in r['rows']:
                off = s + int(body[2][1:], 16)
                fields = body[:]
                fields[2] = f'{off:#x}'
                for i in _bl_tokens(fields):
                    m = re.fullmatch(r'bl:@([^+]+)\+(0x[0-9a-f]+)', fields[i])
                    if not m or m.group(1) not in where: ok = False; log.append(f'【红】fn_match {g["name"]}：{fields[i]} 指向组外或写法不对'); break
                    fields[i] = f'bl:{where[m.group(1)] + int(m.group(2), 16):x}'
                if not ok: break
                if not 0 <= off <= img.text_end - 4 or img.word(off) != int(body[4], 16):
                    ok = False
                    have = f'{img.word(off):08x}' if 0 <= off <= img.text_end - 4 else '越界'
                    log.append(f'【红】fn_match {g["name"]}/{r["name"]}：{off:#x} 原字 {have}，规则写的是 {body[4]}（指纹相同字却不同），整组不打')
                    break
                out.append('\t'.join(fields) + (f'\t# {reason}' if reason else ''))
            if not ok: break
        if not ok: continue
        if kind == 'fix' and bid16 not in g['checked']:
            log.append(f'【黄】fn_match {g["name"]}：指纹在本版（{bid16}）命中，但这一版没核过；缺陷修补只报不打（人核后把 {bid16} 加进 checked）')
            continue
        lines += out; applied.append(g['name'])
        log.append(f'fn_match {g["name"]}：命中 {", ".join(f"{n}@{s:#x}" for n, s in where.items())}，打 {len(out)} 处')
    carry = spec['carry']
    if spec['when'] is not None:
        if spec['when'] not in fix_applied:
            log.append(f'fn_match：帧率表跟随的修补组 {spec["when"]} 没打上，非 c 行不随包')
            carry = []
    if not lines and not carry: return None, applied, log
    head = [f'# 由 match 规则按函数指纹展开（pack/fn_match.py）：{", ".join(applied) or "只有随包行"}']
    return '\n'.join(head + ([f'build {bid16}'] if kind == 'fps' else []) + carry + lines) + '\n', applied, log


def tables(pid, main, work, repo=REPO):
    """出包挑表：(修补表路径 | None, 帧率表路径 | None, 日志行)。精确表优先；没有才展开 match 规则写进 work。
    构建号先只读 NSO 头；真要展开规则才解压 main（纯 Python 的 lz4 解码慢，精确表或没有规则的款不付这份钱）"""
    with open(main, 'rb') as f:
        head = f.read(0x50)
    bid16, log, img = head[0x40:0x48].hex(), [], None   # 同 stage_rewrite.sh：构建号取 main 头 0x40 起；NSO 格式只在要展开规则时核（load_nso）
    out, fix_applied = {}, ()
    for kind in ('fix', 'fps'):
        exact = Path(repo) / f'runtime/{kind}/{bid16}.tsv'
        rules = Path(repo) / f'runtime/{kind}/match/{pid.upper()}.tsv'
        if exact.is_file():
            out[kind] = exact
            if rules.is_file(): log.append(f'fn_match {kind}：本构建号有精确表 {exact.name}，规则不展开')
            continue
        out[kind] = None
        if not rules.is_file(): continue
        try:
            img = img or Image(*load_nso(main)[:2])
            text, applied, lg = expand(rules.read_text(encoding='utf-8'), img, bid16, kind, fix_applied)
        except MatchError as e:
            log.append(f'【红】fn_match {kind}：{e}'); continue
        log += lg
        if kind == 'fix': fix_applied = applied
        if text:
            p = Path(work) / f'fn_match_{kind}.tsv'
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text, encoding='utf-8')
            out[kind] = p
    return out['fix'], out['fps'], log


def main(argv):
    if len(argv) >= 3 and argv[0] == 'derive':
        data, text_end, bid = load_nso(argv[2])
        img, table = Image(data, text_end), Path(argv[1]).read_text(encoding='utf-8')
        text = derive(table, img, bid[:16])
        kind = 'fps' if Path(argv[1]).parent.name == 'fps' else 'fix'
        back, _, log = expand(text, img, bid[:16], kind)
        want = [l for l in (x.split('#', 1)[0].split() for x in table.splitlines()) if l and l[0] == 'c']
        have = [l for l in (x.split('#', 1)[0].split() for x in (back or '').splitlines()) if l and l[0] == 'c']
        norm = lambda rows: sorted(' '.join([r[0], r[1], f'{int(r[2], 16):#x}'] + [f.lower() for f in r[3:]]) for r in rows)
        if norm(want) != norm(have):
            print('\n'.join(log), file=sys.stderr)
            print('【红】derive：规则在原版本上展开与精确表不一致，不输出', file=sys.stderr); return 1
        if '--out' in argv: Path(argv[argv.index('--out') + 1]).write_text(text, encoding='utf-8')
        else: sys.stdout.write(text)
        print(f'derive：{len(want)} 行，展开后与精确表逐字一致', file=sys.stderr); return 0
    if len(argv) >= 3 and argv[0] == 'expand':
        data, text_end, bid = load_nso(argv[2])
        kind = argv[argv.index('--kind') + 1] if '--kind' in argv else 'fix'
        text, _, log = expand(Path(argv[1]).read_text(encoding='utf-8'), Image(data, text_end), bid[:16], kind)
        print('\n'.join(log), file=sys.stderr)
        if text is None: return 2
        if '--out' in argv: Path(argv[argv.index('--out') + 1]).write_text(text, encoding='utf-8')
        else: sys.stdout.write(text)
        return 0
    if len(argv) == 4 and argv[0] == 'tables':
        fix, fps, log = tables(argv[1], argv[2], argv[3])
        if log: print('\n'.join(log), file=sys.stderr)
        print(f'fix\t{fix or "-"}\nfps\t{fps or "-"}')
        return 0
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except MatchError as e:
        print(f'【红】fn_match：{e}', file=sys.stderr); sys.exit(1)
