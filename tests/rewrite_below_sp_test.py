#!/usr/bin/env python3
"""改写器补丁岛不写游戏 sp 以下的活数据（11-11 一款第一方动作游戏 / #515）：REW=<C 改写器> python3 tests/rewrite_below_sp_test.py
游戏有个函数用变长数组开栈后马上 mov sp, x29 恢复 sp，之后照读写数组（数组在 sp 以下）。旧的 x18 补丁岛先 stp …, [sp, #-0x90]! 压 16 字节存临时寄存器，
正好盖掉数组，下标成垃圾 → 野指针段错误（1.0.0 / 1.4.0 同一函数）。修法：这类函数里的 x18 点改用活跃分析证明已死的寄存器当临时，不压栈。
合成模块按那个函数的形态手写，期望值按输入手写、不跑被测实现：
  ① 危险函数（开栈 → 恢复 sp → 再读写 x18 与数组）：两处 x18 都改写、0 缺口、统计 x18_spdyn = 2，补丁区里没有一条以 sp 为基址往下写的指令
  ② 负对照：同一函数去掉「mov sp, x12」（没有动态开栈）：普通函数照旧写法，补丁区里有 stp …, [sp, #-0x90]!，统计里没有 x18_spdyn
#704 一款 Switch 2 游戏 27 处挑不出临时 → 整份报红。三处放宽，各一项：
  ③ 危险函数里、恢复 sp 之前的点（数组还在 sp 以上）照旧压栈：3 处改写 0 缺口，x18_spdanger = 2（只算恢复后两处），往下写 1 条
  ④ 恢复后的点、旧候选 x2–x17 / v16–v31 全活（后面都读），x0 / x1 已死：放宽候选借 x0 / x1，0 缺口、往下写 0 条
  ⑤ 恢复后的 cbz x18、两个去向都读遍通用寄存器：借死向量寄存器暂存（x18_deadv_cond = 1），0 缺口、往下写 0 条
v0.3.1 拿不准不停：挑不出任何临时的点不再整份报红，退回旧写法（压栈）、记兼容写法 x18_compat：
  ⑥ 恢复后的普通 x18 点、通用 x0–x17 / x19–x28 与向量 v0–v31 全活：退出 0、0 缺口、x18_compat = 1、往下写 1 条
  ⑦ 同 ⑥ 但改写点是 cbz x18：退出 0、0 缺口、x18_compat = 1、往下写 1 条（v0.3.0 二者都退出 3）"""
import os, re, struct, subprocess, sys, tempfile

last = ''

REW = os.environ['REW']
bad = 0


def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok; print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')


def nso(path, code, funcs):   # 同 tests/rewrite_scale_test.py：code 从 0x100 起；funcs = [(起点, 长度)] 各一条 FDE
    tsz = (0x100 + 4 * len(code) + 0xfff) & ~0xfff
    text = bytearray(tsz); struct.pack_into('<II', text, 0, 0x14000040, tsz); struct.pack_into('<%dI' % len(code), text, 0x100, *code)
    nf = len(funcs); EH = 0x100; TB = EH + 12; EF = (TB + 8 * nf + 15) & ~15
    rosz = (EF + 0x18 + 0x10 * nf + 0x10 + 0xfff) & ~0xfff
    ro = bytearray(rosz)
    struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
    struct.pack_into('<BBBBiI', ro, EH, 1, 0x1B, 0x03, 0x3B, (tsz + EF) - (tsz + EH + 4), nf)
    ro[EF:EF + 0x18] = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
    for k, (fa, fl) in enumerate(funcs):
        f = tsz + EF + 0x18 + 0x10 * k
        struct.pack_into('<IIii', ro, EF + 0x18 + 0x10 * k, 0x0c, (f + 4) - (tsz + EF), fa - (f + 8), fl)
        struct.pack_into('<ii', ro, TB + 8 * k, fa - (tsz + EH), f - (tsz + EH))
    segs = ((0, bytes(text)), (tsz, bytes(ro)), (tsz + rosz, bytes(0x1000)))
    h = bytearray(0x100); h[:4] = b'NSO0'
    for k, (mo, seg) in enumerate(segs):
        struct.pack_into('<III', h, 0x10 + 0x10 * k, 0x100 + sum(len(s[1]) for s in segs[:k]), mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
    h[0x40:0x50] = bytes(range(16))
    open(path, 'wb').write(bytes(h) + b''.join(s[1] for s in segs))


def sp_down_stores(img, start):
    """补丁区里以 sp 为基址、往 sp 以下写的指令数：stp / str 先变址（[sp, #-k]!）、stur 负偏移、stp 负偏移"""
    n = 0
    for o in range(start, len(img) - 3, 4):
        w = struct.unpack_from('<I', img, o)[0]
        if (w >> 5) & 31 != 31:
            continue
        if (w & 0x7fc00000) == 0x29800000 and (w >> 15) & 0x40:   # stp 先变址、imm7 为负
            n += 1
        elif (w & 0x7fc00000) == 0x29000000 and (w >> 15) & 0x40:   # stp 带偏移、imm7 为负
            n += 1
        elif (w & 0xbfe00c00) == 0xb8000000 and (w >> 12) & 0x100:   # stur 32/64、imm9 为负
            n += 1
        elif (w & 0xbfe00c00) == 0xb8000c00 and (w >> 12) & 0x100:   # str 先变址、imm9 为负
            n += 1
    return n


def run(code):
    with tempfile.TemporaryDirectory() as t:
        src = os.path.join(t, 'main'); nso(src, code, [(0x100, 4 * len(code))])
        r = subprocess.run([REW, src, os.path.join(t, 'o'), 'main'], capture_output=True, text=True, timeout=120, env=dict(os.environ, S2A_TARGET='ios'))
        m = re.search(r'PFRW mod=main need=(\d+) gaps=(\d+)', r.stdout)
        po = re.search(r'PATCH_OFF (0x[0-9a-f]+)', r.stdout)
        sp = re.search(r"'x18_spdyn': (\d+)", r.stdout)
        global last; last = r.stdout
        img = open(os.path.join(t, 'o', 'main.patched.bin'), 'rb').read() if r.returncode == 0 else b''
        down = sp_down_stores(img, int(po[1], 16)) if img and po else None
        return r.returncode, (int(m[1]), int(m[2])) if m else None, int(sp[1]) if sp else 0, down


# 一款第一方动作游戏（1.0.0 main+0x7b67a0）的形态：开栈 → 恢复 sp → 出栈 → 读写 x18 与 sp 以下的数组
FN = [0xa9bf7bfd,   # stp x29, x30, [sp, #-0x10]!
      0x910003fd,   # mov x29, sp
      0x910003ec,   # mov x12, sp
      0xcb0a018c,   # sub x12, x12, x10
      0x9100019f,   # mov sp, x12          ← 动态开栈（负对照换成 nop）
      0x910003bf,   # mov sp, x29          ← 恢复 sp，数组此后在 sp 以下
      0xa8c17bfd,   # ldp x29, x30, [sp], #0x10   （之后不是 ret：恢复 sp 后代码还在走）
      0xb9401c32,   # ldr w18, [x1, #0x1c]  ← x18 点 1
      0xb81fc192,   # stur w18, [x12, #-4]  ← x18 点 2：写 sp 以下的数组
      0xb85fc180,   # ldr w0, [x12, #-4]
      0xd65f03c0]   # ret
NOP = 0xd503201f

rc, stat, spdyn, down = run(FN)
chk('① 危险函数：退出 0、需改写 2 处、0 缺口', (0, (2, 0)), (rc, stat))
chk('① 统计 x18_spdyn = 2（两处 x18 都在危险函数里）', 2, spdyn)
chk('① 补丁区里以 sp 为基址往下写的指令', 0, down)

neg = list(FN); neg[4] = NOP
rc, stat, spdyn, down = run(neg)
chk('② 负对照（没有动态开栈）：退出 0、需改写 2 处、0 缺口', (0, (2, 0)), (rc, stat))
chk('② 负对照不算危险函数：x18_spdyn = 0', 0, spdyn)
chk('② 负对照照旧写法：补丁区里有往 sp 以下压栈的指令（每处 1 条）', 2, down)


def stat(k):
    m = re.search(r"'%s': (\d+)" % k, last); return int(m[1]) if m else 0


def stp(a, b, n=12): return 0xa9000000 | b << 10 | n << 5 | a   # stp xA, xB, [xN]
def st1x4(t, n=12): return 0x4c002000 | n << 5 | t               # st1 {vT.16b–vT+3.16b}, [xN]


HEAD = FN[:7]   # 开栈 → 恢复 sp → 出栈（之后的点都在恢复后）
RET = 0xd65f03c0

pre = FN[:4] + [0xb9401c32] + FN[4:]   # ldr w18, [x1, #0x1c] 插在「mov sp, x12」之前：数组还没开出来
rc, stat3, spdyn, down = run(pre)
chk('③ 恢复前的点照旧：退出 0、需改写 3 处、0 缺口', (0, (3, 0)), (rc, stat3))
chk('③ x18_spdanger 只算恢复后的 2 处', 2, stat('x18_spdanger'))
chk('③ 补丁区往 sp 以下压栈的指令只有恢复前那处 1 条', 1, down)

reads = [stp(r, r + 1) for r in range(2, 18, 2)] + [st1x4(t) for t in (16, 20, 24, 28)]
f4 = HEAD + [0xb9400192] + reads + [0xd2800020, 0xd2800041, RET]   # ldr w18, [x12]；读 x2–x17、v16–v31；mov x0, #1；mov x1, #2；ret
rc, stat4, spdyn, down = run(f4)
chk('④ 旧候选全活、借 x0 / x1：退出 0、需改写 1 处、0 缺口', (0, (1, 0)), (rc, stat4))
chk('④ 走死寄存器（x18_dead = 1）', 1, stat('x18_dead'))
chk('④ 补丁区往 sp 以下写的指令', 0, down)

allgp = [stp(a, a + 1) for a in (0, 2, 4, 6, 8, 10, 12, 14, 16, 19, 21, 23, 25, 27)]
f5 = HEAD + [0xb4000052, 0xd503201f] + allgp + [RET]   # cbz x18, +8（跳过 nop，两个去向都读遍 x0–x17、x19–x28）；ret 读 x30
rc, stat5, spdyn, down = run(f5)
chk('⑤ 条件跳转借死向量寄存器：退出 0、需改写 1 处、0 缺口', (0, (1, 0)), (rc, stat5))
chk('⑤ x18_deadv_cond = 1', 1, stat('x18_deadv_cond'))
chk('⑤ 补丁区往 sp 以下写的指令', 0, down)

allv = [st1x4(t) for t in (0, 4, 8, 12, 16, 20, 24, 28)]
f6 = HEAD + [0xb9400192] + allgp + allv + [RET]   # ldr w18, [x12]；之后读遍通用与向量寄存器；ret 读 x30
rc, stat6, spdyn, down = run(f6)
chk('⑥ 挑不出任何临时的普通点：退出 0、需改写 1 处、0 缺口', (0, (1, 0)), (rc, stat6))
chk('⑥ x18_compat = 1', 1, stat('x18_compat'))
chk('⑥ 退回旧写法：补丁区往 sp 以下压栈 1 条', 1, down)
f7 = HEAD + [0xb4000052, 0xd503201f] + allgp + allv + [RET]
rc, stat7, spdyn, down = run(f7)
chk('⑦ 挑不出任何临时的 cbz x18：退出 0、需改写 1 处、0 缺口', (0, (1, 0)), (rc, stat7))
chk('⑦ x18_compat = 1', 1, stat('x18_compat'))
chk('⑦ 退回旧写法：补丁区往 sp 以下压栈 1 条', 1, down)

print(f'{"✓" if not bad else "✗"} rewrite_below_sp_test：{bad} 处不符')
sys.exit(1 if bad else 0)
