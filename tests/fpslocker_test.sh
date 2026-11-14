#!/bin/bash
# 门禁覆盖：pack/fpslocker.py pack/miniyaml.py
# FPSLocker 配置转换单测（pack/miniyaml.py + pack/fpslocker.py，约 2 秒；汇编那几项要 xcrun clang，没有就跳过并说明）：bash tests/fpslocker_test.sh
# 期望（按 FORMAT.md 与 A64 编码手算，不跑被测实现推期望）：
#   ① 小 YAML：流式列表里的 :标签、"!" 写回、跨行流式列表、键下缩进的「- 值」块列表、# 注释（引号内不算）
#   ② MASTER_WRITE asm_a64：cmp x26, 3 = 0xF1000F5F；mov w1, 3 = 0x52800061；adrp x10, 0x30a7000 放在 0x193cea8 处 = 页差 0x176b → 0xF000B5AA
#   ③ bytes：uint32 列表按小端连写
#   ④ DECLARATIONS：变量排在变量区（8 对齐）、初值非 0 才写；ALL_FPS 里 [VARIABLE, $名] 换成 [MAIN, 偏移]；block 丢弃
#   ⑤ 调 FPSLocker 自带帮助函数 _fpsLock() → 不收（Unsupported）
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
have_clang = subprocess.run(['xcrun', '--find', 'clang'], capture_output=True).returncode == 0
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
else:
    print('跳过 ② 汇编（本机没有 xcrun clang）')
w, rt = F.convert(dict(DECLARATIONS=doc['DECLARATIONS'], ALL_FPS=doc['ALL_FPS']), (0, 0), (0x1003, 0x2000))
ck('④ 变量 8 对齐、初值 30.0 写进去', w == {0x1008: struct.pack('<f', 30.0)} and rt['variables']['fps_target']['offset'] == 0x1008)
ck('④ VARIABLE 地址换成 MAIN 偏移、block 丢弃', rt['all_fps'] == [dict(type='evaluate_write', address=['MAIN', 0x1008], value_type='float', value='FPS_TARGET # 不是注释')])
try:
    F.convert(dict(MASTER_WRITE=[dict(type='asm_a64', main_offset=0x100, instructions=[['bl', '_fpsLock()']])]), (0, 0), (0x1000, 0x2000)); ok = False
except F.Unsupported as e:
    ok = '_fpsLock' in str(e)
ck('⑤ 自带帮助函数不收', ok)
print(('🔴 fpslocker_test 有不通项' if bad else '✅ fpslocker_test 全过'))
sys.exit(bad)
EOF
