#!/bin/bash
# 门禁覆盖：pack/fpslocker.py pack/miniyaml.py
# FPSLocker 配置转换单测（pack/miniyaml.py + pack/fpslocker.py，约 2 秒；有 AArch64 clang 时做实际汇编）：bash tests/fpslocker_test.sh
# 期望（按 FORMAT.md 与 A64 编码手算，不跑被测实现推期望）：
#   ① 小 YAML：流式列表里的 :标签、"!" 写回、跨行流式列表、键下缩进的「- 值」块列表、# 注释（引号内不算）
#   ② MASTER_WRITE asm_a64：cmp x26, 3 = 0xF1000F5F；mov w1, 3 = 0x52800061；adrp x10, 0x30a7000 放在 0x193cea8 处 = 页差 0x176b → 0xF000B5AA
#   ③ bytes：uint32 列表按小端连写
#   ④ DECLARATIONS：变量排在变量区（8 对齐）、初值非 0 才写；ALL_FPS 里 [VARIABLE, $名] 换成 [MAIN, 偏移]；block 丢弃
#   ⑤ 调 FPSLocker 自带帮助函数 _fpsLock() → 不收（Unsupported）
#   ⑥ 没有 clang / 汇编器进程起不来 → 这份不收（Unsupported），不冲垮补丁出表（#1173）
#   ⑩ 声明变量带 evaluate（#2053 旷野之息 1.9.0）：转成 evaluate_write 写到变量偏移、排在 ALL_FPS 前；没写 evaluate 的变量不出运行时条目
#   ⑦⑧ 见对应段落：_convertTickToTimeSpan() 我方实现；mov / movk 里的常量按 16 位片段
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$H" <<'EOF'
import struct, subprocess, sys
sys.path.insert(0, sys.argv[1] + '/pack'); import miniyaml, fpslocker as F
bad = 0
def ck(name, ok):
    global bad; print(('通 ' if ok else '不通 ') + name); bad |= not ok
doc = miniyaml.load('''# 头注释
MASTER_WRITE:
  # 段注释
  -
    type: asm_a64
    main_offset: 0x100
    instructions: [
      [b.ne, :skip],
      [nop],
      :skip, [str, x8, [x0, 0x10], "!"]
    ]
  -
    type: bytes
    main_offset: 0x200
    value_type: uint32
    value:
      - 0xD503201F # NOP
      - 0x52800061
DECLARATIONS:
  -
    type: variable
    name: fps_target
    value_type: float
    default_value: 30
ALL_FPS:
  -
    type: evaluate_write
    address: [VARIABLE, $fps_target]
    value_type: float
    value: "FPS_TARGET # 不是注释"
  -
    type: block
    what: timing
''')
mw = doc['MASTER_WRITE']
ck('① 流式列表：标签 / "!" / 嵌套', mw[0]['instructions'] == [['b.ne', ':skip'], ['nop'], ':skip', ['str', 'x8', ['x0', 16], '!']])
ck('① 缩进块列表与行尾注释', mw[1]['value'] == [0xD503201F, 0x52800061])
ck('① 引号内 # 不算注释', doc['ALL_FPS'][0]['value'] == 'FPS_TARGET # 不是注释')
have_clang = F._clang_command() is not None
def macho_fixture(code):
    seg_size = 72 + 80
    header = struct.pack('<IiiIIIII', 0xFEEDFACF, 0x0100000C, 0, 1, 1, seg_size, 0, 0)
    segment = struct.pack('<II16sQQQQiiII', 0x19, seg_size, b'__TEXT', 0, len(code), 0, len(code), 7, 5, 1, 0)
    section = struct.pack('<16s16sQQIIIIIIII', b'__text', b'__TEXT', 0, len(code), 32 + seg_size, 2, 0, 0, 0, 0, 0, 0)
    return header + segment + section + code
ck('Mach-O __TEXT,__text 提取', F._macho_text(macho_fixture(struct.pack('<I', 0xD503201F))) == struct.pack('<I', 0xD503201F))
wrong_arch = bytearray(macho_fixture(struct.pack('<I', 0xD503201F))); struct.pack_into('<i', wrong_arch, 4, 7)
try:
    F._macho_text(wrong_arch); ok = False
except F.Unsupported:
    ok = True
ck('Mach-O 负对照：拒绝非 arm64 object', ok)
w, rt = F.convert(dict(MASTER_WRITE=[dict(type='bytes', main_offset=0x200, value_type='uint32', value=[0xD503201F, 0x52800061])]), (0, 0), (0x1000, 0x2000))
ck('③ bytes 小端连写', w == {0x200: struct.pack('<II', 0xD503201F, 0x52800061)})
if have_clang:
    w, _ = F.convert(miniyaml.load('''MASTER_WRITE:
  -
    type: asm_a64
    main_offset: 0xF45DFC
    instructions: [
      [cmp, x26, 3],
      [mov, w1, 3]
    ]
  -
    type: asm_a64
    main_offset: 0x193CEA8
    instructions: [
      [adrp, x10, 0x30a7000]
    ]
'''), (0, 0), (0x1000, 0x2000))
    ck('② cmp x26,3 / mov w1,3', w[0xF45DFC] == struct.pack('<II', 0xF1000F5F, 0x52800061))
    im = (0x30a7000 >> 12) - (0x193CEA8 >> 12)
    ck(f'② adrp 页差 {im:#x}', w[0x193CEA8] == struct.pack('<I', 0x90000000 | ((im & 3) << 29) | (((im >> 2) & 0x7ffff) << 5) | 10))
    patch_ops, _ = F.convert(miniyaml.load('''MASTER_WRITE:
  -
    type: asm_a64
    main_offset: 0x1000
    instructions: [
      [nop],
      [fmov, s0, 1.0],
      [ldr, x0, [x1]],
      [cbz, x0, +8]
    ]
'''), (0, 0), (0x1000, 0x2000))
    ck('② FC27 汇编类别 nop / fmov / ldr / cbz', patch_ops[0x1000] == struct.pack('<IIII', 0xD503201F, 0x1E2E1000, 0xF9400020, 0xB4000040))
else:
    print('跳过 ② 汇编（本机没有 AArch64 clang）')
w, rt = F.convert(dict(DECLARATIONS=doc['DECLARATIONS'], ALL_FPS=doc['ALL_FPS']), (0, 0), (0x1003, 0x2000))
ck('④ 变量 8 对齐、初值 30.0 写进去', w == {0x1008: struct.pack('<f', 30.0)} and rt['variables']['fps_target']['offset'] == 0x1008)
ck('④ VARIABLE 地址换成 MAIN 偏移、block 丢弃', rt['all_fps'] == [dict(type='evaluate_write', address=['MAIN', 0x1008], value_type='float', value='FPS_TARGET # 不是注释')])
w10, rt10 = F.convert(miniyaml.load('''DECLARATIONS:
  -
    type: variable
    name: min_delta
    value_type: float
    default_value: 1.0
    evaluate: 30 / FPS_TARGET
  -
    type: variable
    name: frame_tick
    value_type: uint64
    default_value: 0
ALL_FPS:
  -
    type: write
    address: [MAIN, 0x500]
    value_type: uint8
    value: 1
'''), (0, 0), (0x1000, 0x2000))
ck('⑩ 带 evaluate 的变量出 evaluate_write（地址 = 变量偏移 0x1000）、排在 ALL_FPS 前；frame_tick 没有运行时条目', rt10['all_fps'] == [
    dict(type='evaluate_write', address=['MAIN', 0x1000], value_type='float', value='30 / FPS_TARGET'),
    dict(type='write', address=['MAIN', 0x500], value_type='uint8', value=1)] and w10 == {0x1000: struct.pack('<f', 1.0)})
try:
    F.convert(dict(MASTER_WRITE=[dict(type='asm_a64', main_offset=0x100, instructions=[['bl', '_fpsLock()']])]), (0, 0), (0x1000, 0x2000)); ok = False
except F.Unsupported as e:
    ok = '_fpsLock' in str(e)
ck('⑤ 自带帮助函数不收', ok)
# ⑥ #1173：汇编器起不来（Windows 没有 xcrun → FileNotFoundError WinError 2）→ 这份不收（Unsupported），不让异常冲垮整个补丁出表
# ⑦ 我方实现的帮助函数 _convertTickToTimeSpan()（11-15 #934，计时器计数 → 纳秒 = 计数 × 625 ÷ 12）：配置里调了、没自己声明 → 补一个合成代码块，
#    排在声明的代码块之后（代码区起 0x1000：dynamicSpeed 3 条占 0x1000–0x100b，帮助函数从 0x100c 起），bl 跳到它；帮助函数逐字（按 A64 手册手算）：
#    mov x1, #625 = 0xD2804E21；mul x0, x0, x1 = 0x9B017C00；mov x1, #12 = 0xD2800181；udiv x0, x0, x1 = 0x9AC10800；ret = 0xD65F03C0
#    bl 0x100c 放在 0x1000：偏移 +0xc → 0x94000003
# ⑧ mov / movk 里的 $常量取值的 16 位片段（原先按变量页内偏移取低 12 位：33333333 编成 0x00550055，每帧时长小 6 倍）：
#    33333333 = 0x01FCA055 → mov w0, #0xa055 = 0x52940AA0；movk w0, #0x1fc, lsl #16 = 0x72A03F80
doc7 = miniyaml.load('''DECLARATIONS:
  -
    type: const
    name: frame_ns
    value: 33333333
  -
    type: code
    name: dynamicSpeed
    instructions: [
      [bl, _convertTickToTimeSpan()],
      [mov, w0, $frame_ns],
      [movk, w0, $frame_ns, 16]
    ]
''')
try:
    w7, _ = F.convert(doc7, (0x1000, 0x2000), (0x8000, 0x9000))
    words = lambda off: list(struct.unpack('<%dI' % (len(w7[off]) // 4), w7[off]))
    ck('⑦ 帮助函数补在 0x100c、bl 跳到它', sorted(w7) == [0x1000, 0x100c] and words(0x1000)[0] == 0x94000003
       and words(0x100c) == [0xD2804E21, 0x9B017C00, 0xD2800181, 0x9AC10800, 0xD65F03C0])
    ck('⑧ mov / movk 里的常量按 16 位片段编码', words(0x1000)[1:] == [0x52940AA0, 0x72A03F80])
except F.Unsupported as e:
    if 'AArch64 汇编器' in str(e): print('跳过 ⑦⑧：本机没有汇编器')
    else: ck(f'⑦⑧ 不该不收：{e}', False)
# ⑨ D-7AQ2：跳转目标写了 + / - 的是相对当前指令（[b, +160]），没写符号的是主程序里的绝对偏移（[b, 0x1000]）。原先 +160 读成 160、按绝对跳到 main+0xa0。
#   期望按 A64 B 编码手算（0x14000000 | ((目标 − 本条) / 4 的低 26 位)）：0x1000 处 b +160 → 0x10a0 = 0x14000028；0x1004 处 b -8 → 0xffc = 0x17fffffe；
#   0x1008 处 b 0x1000 → 0x1000 = 0x17fffffe
y9 = miniyaml.load('MASTER_WRITE:\n  -\n    type: asm_a64\n    main_offset: 0x1000\n    instructions: [\n      [b, +160],\n      [b, -8],\n      [b, 0x1000]\n    ]\n')
ins9 = y9['MASTER_WRITE'][0]['instructions']
ck('⑨ 小 YAML：+160 / -8 记成带符号的整数，0x1000 是普通整数',
   [type(i[1]).__name__ for i in ins9] == ['Signed', 'Signed', 'int'] and [int(i[1]) for i in ins9] == [160, -8, 0x1000])
if have_clang:
    try:
        w9, _ = F.convert(y9, (0, 0), (0x10000, 0x20000))
        ck('⑨ 带符号的跳转按相对编码、不带符号的按绝对', w9 == {0x1000: struct.pack('<III', 0x14000028, 0x17FFFFFE, 0x17FFFFFE)})
    except F.Unsupported as e:
        ck(f'⑨ 不该不收：{e}', False)
else:
    print('跳过 ⑨ 编码：本机没有汇编器')
real_clang = F._clang_command
F._clang_command = lambda: None
try:
    F._assemble(['nop']); ok = False
except F.Unsupported as e:
    ok = 'LLVM clang' in str(e)
except Exception:
    ok = False
finally:
    F._clang_command = real_clang
ck('⑥ 没有汇编器：这份不收、不抛别的异常', ok)
print(('🔴 fpslocker_test 有不通项' if bad else '✅ fpslocker_test 全过'))
sys.exit(bad)
EOF
