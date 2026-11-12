#!/usr/bin/env python3
# 改写器回归语料执行器（#149 / #58 H04）：run.py <改写器：C 可执行文件（python3 pack/rewriter.py c-path 末行）> [用例名前缀…]；环境 STRICT=1 时「已知缺口」也按期望判。
# 每例：clang 汇编（xcrun clang -arch arm64，otool -t 取字）→ 拼合成 NSO（骨架同 tests/rewrite_jt_open_test.sh：代码段 0x100 起，一个 FDE 覆盖代码）→
#   苹果 / 安卓各改写一遍 → 按 cases.py 的期望判。落点的取法与分派策略无关：原指令处的 B 进补丁区，改写块 = [入口, 下一个改写块入口)，
#   块里所有直接跳转（b / b.cond / cbz / cbnz / tbz / tbnz）中跳出本块的目标集合就是落点（各种分派的落地垫最后都是 b 原目标；块内的计算跳转只到本块的垫）；
#   br 处本身没有入口时取它前面 0x40 内最近的入口（经典 / 通用相对表把 ldrsw…br 合成一处，入口在 ldrsw）。按值跳（尾调用 / blr）= 块里有 br / blr 寄存器且没有落点。
# 输出：每例一行「通 / 不通 / 已知缺口 / 已知缺口已修」，末行「rewrite_corpus：N 例，通 a、已知缺口 b、已知缺口已修 c、不通 d」；退出 0 = 没有不通
import os, re, struct, subprocess, sys, tempfile
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
H = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, H)
from cases import CASES
REW = sys.argv[1] if len(sys.argv) > 1 else ""; PICK = sys.argv[2:]; STRICT = os.environ.get('STRICT') == '1'
PY = os.environ.get('PY') or sys.executable
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
T = tempfile.mkdtemp(prefix='rwc')

def assemble(name, src):
    s, o = os.path.join(T, name + '.s'), os.path.join(T, name + '.o')
    open(s, 'w').write('.text\n.p2align 2\n' + src)
    subprocess.run(['xcrun', 'clang', '-arch', 'arm64', '-c', s, '-o', o], check=True, capture_output=True)
    out = subprocess.run(['otool', '-t', o], check=True, capture_output=True, text=True).stdout.split('\n')[2:]
    return [int(w, 16) for l in out for w in l.split()[1:]]

def nso(code, ro_tabs, fde_len, path, tsz=0x1000):
    """tsz = 代码段长（缺省 0x1000），ro 段紧跟其后：放大代码段的用例 adrp 页号按 ro 在 tsz 处手填"""
    text = bytearray(tsz); struct.pack_into('<II', text, 0, 0x14000040, tsz); struct.pack_into('<%dI' % len(code), text, 0x100, *code)
    ro = bytearray(0x1000); EH, EF = 0x100, 0x200
    struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
    struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (tsz + EF) - (tsz + EH + 4), 1, 0x100 - (tsz + EH), (tsz + EF + 0x18) - (tsz + EH))
    cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
    ro[EF:EF + 0x18] = cie; f = tsz + EF + 0x18
    struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (tsz + EF), 0x100 - (f + 8), fde_len)
    for off, (kind, vals) in ro_tabs.items():
        struct.pack_into({'i32': '<%di', 'u16': '<%dH'}[kind] % len(vals), ro, off, *vals)
    text, ro, data = bytes(text), bytes(ro), bytes(0x1000)
    h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100
    for k, (mo, seg) in enumerate(((0, text), (tsz, ro), (tsz + 0x1000, data))):
        struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + (0 if k == 0 else tsz + 0x1000 * (k - 1)), mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
    h[0x40:0x50] = bytes(range(16))
    open(path, 'wb').write(bytes(h) + text + ro + data)

def rewrite(path, outdir, target):
    os.makedirs(outdir, exist_ok=True)
    r = subprocess.run(([PY, REW] if REW.endswith(".py") else [REW]) + [path, outdir, 'main'], capture_output=True, text=True, env=dict(os.environ, S2A_TARGET=target))
    gaps = [(int(l.split('\t')[2], 16), l.split('\t')[3].split(':')[0]) for l in r.stdout.split('\n') if l.startswith('GAP\t')]
    m = re.search(r"main (\{.*?\}) patch", r.stdout); stat = eval(m.group(1)) if m else {}
    return r.returncode, gaps, stat, r.stdout + r.stderr

def b_target(w, a):
    if w >> 26 != 0b000101: return None
    imm = w & 0x3ffffff; return a + 4 * (imm - (1 << 26) if imm >> 25 else imm)

def landings(outdir, text_len):
    """{原地址: (落点集合, 有无按值跳)}：每个被改成 B 进补丁区的原指令一项"""
    b = open(os.path.join(outdir, 'main.patched.bin'), 'rb').read()
    hdr = {l.split('\t')[0][2:]: l.rstrip('\n').split('\t')[1] for l in open(os.path.join(outdir, 'main.fixups.tsv')) if l.startswith('# ')}
    po = int(hdr['PATCH_OFF'], 16); assert po > 0, '合成模块的补丁区应在映像后'
    ent = {}
    for a in range(0x100, 0x100 + text_len, 4):
        t = b_target(struct.unpack_from('<I', b, a)[0], a)
        if t is not None and t >= po: ent[a] = t
    starts = sorted(set(ent.values())) + [len(b)]
    out = {}
    for a, s in ent.items():
        e = starts[starts.index(s) + 1]; tg = set(); dyn = False
        for i in md.disasm(b[s:e], s):
            m = i.mnemonic
            if m in ('br', 'blr'): dyn = True
            elif m in ('b', 'bl', 'cbz', 'cbnz', 'tbz', 'tbnz') or m.startswith('b.'):
                t = int(i.op_str.split('#')[-1], 16)
                if not s <= t < e: tg.add(t)
        out[a] = (tg, dyn)
    return out

def fmt(s):
    s = sorted(s); return ','.join(f'{x:#x}' for x in s) if len(s) <= 6 else f'{len(s)} 个（{s[0]:#x}…{s[-1]:#x}）'

def judge(c, code, d):
    """返回 (是否符合期望, 说明)"""
    msgs = []; ok = True
    for tgt in ('apple', 'android', 'ohos'):
        o = os.path.join(d, tgt); rc, gaps, stat, log = rewrite(os.path.join(d, 'main'), o, tgt)
        if 'gap' in c:
            want = sorted(c['gap']); got = sorted(gaps)
            good = rc == 3 and got == want and os.path.exists(os.path.join(o, 'main.patched.bin'))   # v0.3.1 拿不准不停：有缺口照出产物
            msgs.append(f'{tgt} 退出码 {rc} 缺口 {[(hex(a), k) for a, k in got]}'); ok &= good; continue
        if rc != 0 or gaps:
            msgs.append(f'{tgt} 退出码 {rc} 缺口 {[(hex(a), k) for a, k in gaps]}'); ok = False; continue
        L = landings(o, 4 * len(code)); parts = []
        for a, want in c.get('br', {}).items():
            must, may = want if isinstance(want, tuple) else (want, want)   # （必含, 至多）：精确集合 ⊆ 落点 ⊆ 安全超集
            e = a if a in L else max((x for x in L if a - 0x40 <= x < a), default=None)
            tg = L[e][0] if e is not None else None
            good = tg is not None and must <= tg <= may; ok &= good
            parts.append(f'{a:#x}{f"（入口 {e:#x}）" if e is not None and e != a else ""}→{fmt(tg) if tg is not None else "没改写"}')
        for a in c.get('dyn', []):
            tg, dyn = L.get(a, (None, None)); good = dyn is True and tg == set(); ok &= good
            parts.append(f'{a:#x}→{"按值跳" if dyn else "不是按值跳"}{"、静态落点 " + fmt(tg) if tg else ""}')
        for k, n in c.get('stat', {}).items():
            good = stat.get(k, 0) == n; ok &= good; parts.append(f'{k}={stat.get(k, 0)}')
        if 'abi' in c:   # fixups 表头 # REWRITE_ABI：安卓/鸿蒙期望 <tgt>-<abi>；苹果不出这行
            hdr = {l.split('\t')[0][2:]: l.rstrip('\n').split('\t')[1] for l in open(os.path.join(o, 'main.fixups.tsv')) if l.startswith('# ')}
            got = hdr.get('REWRITE_ABI'); want = None if tgt == 'apple' else f'{tgt}-{c["abi"]}'
            good = got == want; ok &= good; parts.append(f'REWRITE_ABI={got or "无"}')
        msgs.append(f'{tgt} ' + '；'.join(parts))
    return ok, ' | '.join(msgs)

def sanity(c, code):
    """用例自身核对（与被测改写器无关）：期望里写的 br 地址处确实是 br x18 / blr x18，写错地址当场报出"""
    for a in list(c.get('br', {})) + c.get('dyn', []) + [a for a, k in c.get('gap', []) if k == 'br_x18']:
        i = next(md.disasm(struct.pack('<I', code[(a - 0x100) // 4]), a), None)
        if not i or i.mnemonic not in ('br', 'blr') or i.op_str != 'x18': return f'用例写错：{a:#x} 处是 {i.mnemonic if i else "?"} {i.op_str if i else ""}，不是 br / blr x18'
    return ''

if __name__ == '__main__':
    n = {'通': 0, '已知缺口': 0, '已知缺口已修': 0, '不通': 0}
    for c in CASES:
        if PICK and not any(c['name'].startswith(p) for p in PICK): continue
        d = os.path.join(T, c['name']); os.makedirs(d)
        code = assemble(c['name'], c['asm']); err = sanity(c, code)
        if err: n['不通'] += 1; print(f'不通 {c["name"]}：{err}'); continue
        nso(code, c.get('ro', {}), c.get('fde', 4 * len(code)), os.path.join(d, 'main'), c.get('text', 0x1000))
        ok, why = judge(c, code, d); kn = c.get('known')
        if ok: res = '已知缺口已修' if kn and not STRICT else '通'
        else: res = '已知缺口' if kn and not STRICT else '不通'
        n[res] += 1
        print(f'{res} {c["name"]}{f"（{kn}）" if kn else ""}：{c["doc"]}\n    {why}')
    print(f'rewrite_corpus：{sum(n.values())} 例，' + '、'.join(f'{k} {v}' for k, v in n.items()) + ('（STRICT）' if STRICT else ''))
    sys.exit(1 if n['不通'] else 0)
