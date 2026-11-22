"""FPSLocker 配置（masagrator/FPSLocker-Warehouse，每构建号一份 YAML）→ S2Arm 帧率单元（11-12 维护者：帧率能打的都打上）。
插件本体是 GPL，这里不搬它的代码：自己解析 YAML 子集（pack/miniyaml.py）、自己把 [助记符, 操作数…] 拼成汇编文本交 clang 汇编（与位置有关的 adrp / 跳转自己算）。
产出：
  · writes：主程序偏移 → 字节（MASTER_WRITE 的 asm_a64 / bytes，与 DECLARATIONS 的代码块放进代码段末页尾巴后的字节），交 pack/cpatch.py 当一份 fps 补丁编进包（跟「60 帧」开关）
  · runtime：ALL_FPS 条目（地址里的 VARIABLE 换成主程序偏移）+ 变量表，写进产物根 fpslocker.json，运行时服务层（services/S2A.Services/FpsLocker.cs）在 60 帧生效时按目标帧率定期写
认不出的写法（a32、自带帮助函数 _fpsLock() 等、跳不到的符号）整份不收，原因写回调用方"""
import os, re, shutil, struct, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # 同目录的 miniyaml（Signed：写了 + / - 的跳转目标）；调用方按文件路径装载时也找得到
import miniyaml  # noqa: E402

BR = {'b', 'bl', 'cbz', 'cbnz', 'tbz', 'tbnz'} | {'b.' + c for c in 'eq ne cs hs cc lo mi pl vs vc hi ls ge lt gt le al nv'.split()}
VT = {'uint8': 'B', 'int8': 'b', 'uint16': 'H', 'int16': 'h', 'uint32': 'I', 'int32': 'i', 'uint64': 'Q', 'int64': 'q', 'float': 'f', 'double': 'd'}


class Unsupported(Exception):
    pass


class Const(int):
    """DECLARATIONS 里 type: const 的值（与变量 / 代码块的主程序偏移区分：mov / movk 里取的是值的 16 位片段，不是页内偏移）"""


# FPSLocker 自带帮助函数的我方实现（按 Horizon 语义自写，不搬插件代码）：
#   convertTickToTimeSpan：nn::os::ConvertToTimeSpan——系统计时器计数（19.2 MHz，cntpct_el0）→ 纳秒 = 计数 × 625 ÷ 12；
#   入参 x0 = 计数、返回 x0 = 纳秒，只改 x0 / x1（调用约定里本就可被冲掉）。帧间隔量级的计数（30 帧约 64 万）× 625 远不到 64 位上限
HELPERS = {
    'convertTickToTimeSpan': [['mov', 'x1', 625], ['mul', 'x0', 'x0', 'x1'], ['mov', 'x1', 12], ['udiv', 'x0', 'x0', 'x1'], ['ret']],
}


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
    if isinstance(t, miniyaml.Signed): return site + int(t)   # 写了 + / - 的数：相对当前指令（[b, +160]）；没写符号的是主程序里的绝对偏移（[b, 0x580B064]）
    if isinstance(t, int): return t
    s = str(t)
    if s.endswith('()'):
        for n in (s[:-2], s[1:-2]):   # 调用写 _名字()，声明里的代码块名不带下划线
            if n in syms and isinstance(syms[n], int): return syms[n]
        raise Unsupported(f'调用 {s}：FPSLocker 自带的帮助函数，S2Arm 没有')
    raise Unsupported(f'跳转目标 {t} 看不懂')


def _clang_command():
    """FPSLocker 汇编器入口。macOS 继续经 xcrun 选工具链；Windows 找 LLVM clang。"""
    if sys.platform == 'darwin':
        return ['xcrun', 'clang'] if shutil.which('xcrun') else None
    configured = os.environ.get('S2A_CLANG')
    if configured and os.path.isfile(configured): return [configured]
    found = shutil.which('clang')
    if found: return [found]
    if os.name == 'nt':
        for root in (os.environ.get('ProgramFiles'), os.environ.get('ProgramW6432'), r'C:\Program Files'):
            if root:
                candidate = os.path.join(root, 'LLVM', 'bin', 'clang.exe')
                if os.path.isfile(candidate): return [candidate]
    return None


def _macho_text(data):
    """从 clang 的 64 位 arm64 Mach-O object 中取 __TEXT,__text 原始机器码。"""
    if len(data) < 32: raise Unsupported('AArch64 汇编结果太短')
    magic, cpu, _, filetype, ncmds, sizeofcmds, _, _ = struct.unpack_from('<IiiIIIII', data)
    if magic != 0xFEEDFACF or cpu != 0x0100000C or filetype != 1:
        raise Unsupported('AArch64 汇编结果不是 64 位 arm64 Mach-O object')
    end = 32 + sizeofcmds
    if end > len(data): raise Unsupported('AArch64 汇编结果的 load commands 越界')
    at, found = 32, None
    for _ in range(ncmds):
        if at + 8 > end: raise Unsupported('AArch64 汇编结果的 load command 不完整')
        cmd, cmdsize = struct.unpack_from('<II', data, at)
        if cmdsize < 8 or at + cmdsize > end: raise Unsupported('AArch64 汇编结果的 load command 长度无效')
        if cmd == 0x19:  # LC_SEGMENT_64
            if cmdsize < 72: raise Unsupported('AArch64 汇编结果的 segment command 不完整')
            seg = struct.unpack_from('<16sQQQQiiII', data, at + 8)
            nsects = seg[-2]
            if 72 + nsects * 80 > cmdsize: raise Unsupported('AArch64 汇编结果的 section 列表越界')
            sec_at = at + 72
            for _ in range(nsects):
                sect = struct.unpack_from('<16s16sQQIIIIIIII', data, sec_at)
                sectname, secseg, size, offset = sect[0].split(b'\0', 1)[0], sect[1].split(b'\0', 1)[0], sect[3], sect[4]
                # Mach-O relocatable objects commonly leave LC_SEGMENT_64.segname empty;
                # the authoritative segment name is the section_64.segname field.
                if secseg == b'__TEXT' and sectname == b'__text':
                    if found is not None: raise Unsupported('AArch64 汇编结果含多个 __TEXT,__text sections')
                    if size % 4 or offset + size > len(data): raise Unsupported('AArch64 汇编结果的 __text 范围无效')
                    found = data[offset:offset + size]
                sec_at += 80
        at += cmdsize
    if at != end: raise Unsupported('AArch64 汇编结果的 load command 总长度不匹配')
    if found is None: raise Unsupported('AArch64 汇编结果没有 __TEXT,__text section')
    return found


def _assemble(lines):
    with tempfile.TemporaryDirectory() as d:
        source, obj = os.path.join(d, 'a.s'), os.path.join(d, 'a.o')
        with open(source, 'w', encoding='utf-8', newline='\n') as f:
            f.write('.text\n' + ''.join(f'{l}\n' for l in lines))
        try:
            clang = _clang_command()
            if not clang:
                raise Unsupported('本机没有 AArch64 汇编器（需要 LLVM clang；可通过 S2A_CLANG 指定）')
            r = subprocess.run([*clang, '-c', '-target', 'arm64-apple-macos13', source, '-o', obj], capture_output=True, text=True)
            if r.returncode: raise Unsupported('汇编不了：' + (r.stderr.strip().splitlines() or ['?'])[-1][:120])
            if sys.platform == 'darwin':
                out = subprocess.run(['xcrun', 'otool', '-t', '-X', obj], capture_output=True, text=True)
                if out.returncode: raise Unsupported('读取汇编结果失败：' + (out.stderr.strip().splitlines() or ['otool 退出异常'])[-1][:120])
                return [int(w, 16) for w in out.stdout.split() if re.fullmatch(r'[0-9a-f]{8}', w)]
            with open(obj, 'rb') as f:
                try: code = _macho_text(f.read())
                except struct.error as e: raise Unsupported('AArch64 汇编结果结构损坏') from e
        except OSError as e:
            raise Unsupported(f'本机 AArch64 汇编器无法启动：{e.strerror or e}') from e
        return list(struct.unpack(f'<{len(code) // 4}I', code))


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
    # mov / movz / movk 里的 $常量 → 值的 16 位片段（mov 取低 16 位，movk ..., lsl #N 取右移 N 位后的 16 位）。
    #   11-15 #934 旷野之息 1.9.0：mov w0, $default_frame_nanoseconds / movk ..., 16 原先按下面变量的页内偏移取低 12 位，33333333 编成 0x00550055，
    #   每帧时长小 6 倍、游戏步长一直卡在上限 2.0（双倍速）
    if m in ('mov', 'movz', 'movk') and len(args) >= 2 and isinstance(args[1], str) and args[1].startswith('$') and isinstance(syms.get(args[1][1:]), Const):
        sh = int(args[2]) if m == 'movk' and len(args) == 3 else 0
        args[1] = (int(syms[args[1][1:]]) >> sh) & 0xffff
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
    decl = list(doc.get('DECLARATIONS') or [])
    # FPSLocker 自带的帮助函数里我们自己实现的（11-15 #934：旷野之息 1.8.2 / 1.9.0 的动态步长配置调 _convertTickToTimeSpan()，原先整份不收，
    #   开关开着游戏却按原生 30 帧跑）：配置里引用了、又没自己声明同名代码块时，补一个合成代码块，与声明的代码块一起排进代码段末页尾巴
    def _calls(d):
        return [i for i in d.get('instructions', []) if isinstance(i, list) and len(i) > 1 and str(i[0]).lower() == 'bl' and str(i[1]).endswith('()')]
    used = {str(i[1])[:-2].lstrip('_') for d in list(decl) + list(doc.get('MASTER_WRITE') or []) for i in _calls(d)}
    declared = {d.get('name') for d in decl}
    for n, body in HELPERS.items():
        if n in used and n not in declared: decl.append(dict(type='code', name=n, instructions=body))
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
            v = d.get('value'); syms[name] = Const(v) if isinstance(v, int) and not isinstance(v, bool) else v
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
    # 声明变量带 evaluate（#2053：旷野之息 1.9.0 的 min_delta = 30 / FPS_TARGET、dr_factor = (FPS_TARGET / 30) * 100）：FPSLocker 按目标帧率求值写进变量，
    #   原先只取 default_value，60 帧档下步长仍按 30 帧算、游戏两倍速。转成一条 evaluate_write（地址就是排好的变量偏移），与 ALL_FPS 同一套运行时写法：
    #   选中按选中档写、退回原帧率时按 30 写（services/S2A.Services/FpsLocker.cs）。没写 evaluate 的变量（运行中由声明代码改的）照旧只放初值
    rt = [dict(type='evaluate_write', address=['MAIN', syms[d['name']]], value_type=d.get('value_type', 'uint32'), value=str(d['evaluate']))
          for d in decl if d.get('type') == 'variable' and d.get('evaluate') is not None]
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
