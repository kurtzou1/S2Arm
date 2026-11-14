"""FPSLocker 配置（masagrator/FPSLocker-Warehouse，每构建号一份 YAML）→ S2Arm 帧率单元（11-12 维护者：帧率能打的都打上）。
插件本体是 GPL，这里不搬它的代码：自己解析 YAML 子集（pack/miniyaml.py）、自己把 [助记符, 操作数…] 拼成汇编文本交 clang 汇编（与位置有关的 adrp / 跳转自己算）。
产出：
  · writes：主程序偏移 → 字节（MASTER_WRITE 的 asm_a64 / bytes，与 DECLARATIONS 的代码块放进代码段末页尾巴后的字节），交 pack/cpatch.py 当一份 fps 补丁编进包（跟「60 帧」开关）
  · runtime：ALL_FPS 条目（地址里的 VARIABLE 换成主程序偏移）+ 变量表，写进产物根 fpslocker.json，运行时服务层（services/S2A.Services/FpsLocker.cs）在 60 帧生效时按目标帧率定期写
认不出的写法（a32、自带帮助函数 _fpsLock() 等、跳不到的符号）整份不收，原因写回调用方"""
import os, re, struct, subprocess, sys, tempfile

BR = {'b', 'bl', 'cbz', 'cbnz', 'tbz', 'tbnz'} | {'b.' + c for c in 'eq ne cs hs cc lo mi pl vs vc hi ls ge lt gt le al nv'.split()}
VT = {'uint8': 'B', 'int8': 'b', 'uint16': 'H', 'int16': 'h', 'uint32': 'I', 'int32': 'i', 'uint64': 'Q', 'int64': 'q', 'float': 'f', 'double': 'd'}


class Unsupported(Exception):
    pass


def _opnd(x, syms):
    if isinstance(x, list): return '[' + ', '.join(_opnd(v, syms) for v in x) + ']'
    if isinstance(x, bool): raise Unsupported('布尔操作数')
    if isinstance(x, int): return f'#{x:#x}' if x >= 0 else f'#-{-x:#x}'
    if isinstance(x, float): return f'#{x}'
    s = str(x)
    if s.startswith('$'): raise Unsupported(f'变量 {s} 只能出现在 adrp / add / ldr / str 的地址里')
    return s


def _target(t, site, labels, syms):
    if isinstance(t, str) and t.startswith(':'):
        if t not in labels: raise Unsupported(f'标签 {t} 没定义')
        return labels[t]
    if isinstance(t, str) and t[:1] in '+-': return site + int(t, 0)
    if isinstance(t, int): return t
    s = str(t)
    if s.endswith('()'):
        for n in (s[:-2], s[1:-2]):   # 调用写 _名字()，声明里的代码块名不带下划线
            if n in syms and isinstance(syms[n], int): return syms[n]
        raise Unsupported(f'调用 {s}：FPSLocker 自带的帮助函数，S2Arm 没有')
    raise Unsupported(f'跳转目标 {t} 看不懂')


def _assemble(lines):
    with tempfile.TemporaryDirectory() as d:
        open(f'{d}/a.s', 'w').write('.text\n' + ''.join(f'{l}\n' for l in lines))
        r = subprocess.run(['xcrun', 'clang', '-c', '-target', 'arm64-apple-macos13', f'{d}/a.s', '-o', f'{d}/a.o'], capture_output=True, text=True)
        if r.returncode: raise Unsupported('汇编不了：' + (r.stderr.strip().splitlines() or ['?'])[-1][:120])
        out = subprocess.run(['xcrun', 'otool', '-t', '-X', f'{d}/a.o'], capture_output=True, text=True).stdout.split()
        return [int(w, 16) for w in out if re.fullmatch(r'[0-9a-f]{8}', w)]


def _encode(ins, site, labels, syms):
    """一条 [助记符, …] → 32 位字（site = 它在主程序里的偏移；syms：变量 / 声明代码名 → 主程序偏移）"""
    m, args = str(ins[0]).lower(), list(ins[1:])
    pre = bool(args) and args[-1] == '!'
    if pre: args = args[:-1]
    if m == 'adrp':
        rd = int(str(args[0])[1:]); t = args[1]
        t = syms[t[1:]] if isinstance(t, str) and t.startswith('$') and t[1:] in syms else t
        if not isinstance(t, int): raise Unsupported(f'adrp 目标 {t}')
        im = (t >> 12) - (site >> 12)
        return 0x90000000 | ((im & 3) << 29) | (((im >> 2) & 0x7ffff) << 5) | rd
    # add / ldr / str 里的 $变量 → 该变量页内偏移（与前面的 adrp 配对，FPSLocker 写法同此）
    def low(x):
        if isinstance(x, str) and x.startswith('$'):
            if x[1:] not in syms: raise Unsupported(f'变量 {x} 没声明')
            return syms[x[1:]] & 0xfff
        if isinstance(x, list): return [low(v) for v in x]
        return x
    args = [low(a) for a in args]
    if m in BR:
        *head, t = args
        off = _target(t, site, labels, syms) - site
        txt = f"{m} {', '.join(_opnd(h, syms) for h in head) + (', ' if head else '')}.{off:+#x}".replace('.+-', '.-')
    elif m == 'movk' and len(args) == 3:
        txt = f'movk {args[0]}, #{args[1]:#x}, lsl #{args[2]}'
    else:
        txt = (f"{m} {', '.join(_opnd(a, syms) for a in args)}".strip()) + ('!' if pre else '')
    w = _assemble([txt])
    if len(w) != 1: raise Unsupported(f'{txt} 汇编出 {len(w)} 个字')
    return w[0]


def _block(ins_list, site0, syms):
    labels, seq = {}, []
    for it in ins_list:
        if isinstance(it, str) and it.startswith(':'): labels[it] = site0 + 4 * len(seq); continue
        if not isinstance(it, list) or not it: raise Unsupported(f'指令 {it} 看不懂')
        seq.append(it)
    return b''.join(struct.pack('<I', _encode(it, site0 + 4 * k, labels, syms)) for k, it in enumerate(seq)), len(seq)


def _values(e):
    vt = e.get('value_type', 'uint8')
    if vt not in VT: raise Unsupported(f'值类型 {vt}')
    vals = e['value'] if isinstance(e['value'], list) else [e['value']]
    return b''.join(struct.pack('<' + VT[vt], float(v) if VT[vt] in 'fd' else int(v)) for v in vals)


def convert(doc, code_room, var_room):
    """doc：解析好的 YAML；code_room：(起, 止) 主程序偏移，放声明代码（代码段末页尾巴）；var_room：(起, 止) 放变量（映像结尾可写空余）。
    → (writes {偏移: 字节}, runtime {all_fps, variables})，认不出抛 Unsupported"""
    decl = doc.get('DECLARATIONS') or []
    syms, writes, var_init = {}, {}, {}
    vp, cp = (var_room[0] + 7) & ~7, (code_room[0] + 3) & ~3
    for d in decl:   # 先排地址（代码块之间可互相 bl）
        t, name = d.get('type'), d.get('name')
        if t == 'variable':
            vt = d.get('value_type', 'uint32')
            if vt not in VT: raise Unsupported(f'变量类型 {vt}')
            size = struct.calcsize(VT[vt]); vp = (vp + size - 1) & ~(size - 1)
            if vp + size > var_room[1]: raise Unsupported('映像结尾空余放不下变量')
            syms[name] = vp; var_init[name] = (vp, vt, d.get('default_value', 0))
            dv = d.get('default_value', 0) or 0
            if dv: writes[vp] = struct.pack('<' + VT[vt], float(dv) if VT[vt] in 'fd' else int(dv))   # 空余全 0：初值非 0 才写
            vp += size
        elif t == 'code':
            n = sum(1 for it in d.get('instructions', []) if not (isinstance(it, str) and it.startswith(':')))
            if cp + 4 * n > code_room[1]: raise Unsupported('代码段末页尾巴放不下声明的代码')
            syms[name] = cp; cp += 4 * n
        elif t == 'const':
            syms[name] = d.get('value')
        else:
            raise Unsupported(f'声明类型 {t}')
    for d in decl:
        if d.get('type') == 'code':
            b, _ = _block(d.get('instructions', []), syms[d['name']], syms); writes[syms[d['name']]] = b
    for e in doc.get('MASTER_WRITE') or []:
        t = e.get('type')
        if t == 'bytes': writes[e['main_offset']] = _values(e)
        elif t == 'asm_a64': writes[e['main_offset']], _ = _block(e.get('instructions', []), e['main_offset'], syms)
        else: raise Unsupported(f'MASTER_WRITE 类型 {t}')
    def addr(a):
        if not isinstance(a, list) or not a: raise Unsupported(f'地址 {a}')
        a = list(a)
        if a[0] == 'VARIABLE':
            if len(a) < 2 or str(a[1]).lstrip('$') not in syms: raise Unsupported(f'VARIABLE 地址 {a}')
            return ['MAIN', syms[str(a[1]).lstrip('$')]] + a[2:]
        if a[0] not in ('MAIN', 'HEAP', 'ALIAS'): raise Unsupported(f'地址区 {a[0]}')
        return a
    rt = []
    for e in doc.get('ALL_FPS') or []:
        e = dict(e); t = e.get('type')
        if t in ('write', 'evaluate_write', 'compare', 'evaluate_compare'):
            if e.get('value_type') == 'refresh_rate': continue   # 刷新率锁交给 S2Arm 自己的 60 帧开关
            e['address'] = addr(e['address'])
            if 'compare_address' in e: e['compare_address'] = addr(e['compare_address'])
        elif t == 'block':
            continue   # FPSLocker 内部帧延迟：S2Arm 不用
        else:
            raise Unsupported(f'ALL_FPS 类型 {t}')
        rt.append(e)
    return writes, dict(all_fps=rt, variables={k: dict(offset=v[0], value_type=v[1], default=v[2]) for k, v in var_init.items()})
