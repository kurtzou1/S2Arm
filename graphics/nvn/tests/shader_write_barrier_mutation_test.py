#!/usr/bin/env python3
"""通道里着色器写之后的游戏屏障要拆通道（rp_pass.c rp_pass_barrier / rp_pass_prepare_draw，rp_draw.c prog_shader_writes）的点变异：
每个变异体撤掉 / 改坏一处判据，t_nvn_replay 的 t_shader_write_barrier_split 必须红在指定的那一行（用例名 + 期望值）上。
变异落在 rp_pass.c 或 rp_draw.c；每个变异体在 build/ 下的副本里只重编被改的那个文件再链接，源码树不动。

用法：python3 shader_write_barrier_mutation_test.py
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'build/shader-write-barrier-mutations'
OUT.mkdir(parents=True, exist_ok=True)
CC = os.environ.get('CC', 'cc')
PASS = 'graphics/nvn/replay/rp_pass.c'
DRAW = 'graphics/nvn/replay/rp_draw.c'

MASK = '(bits & (NVN_BARRIER_ORDER_PRIMITIVES_BIT | NVN_BARRIER_ORDER_FRAGMENTS_BIT | NVN_BARRIER_ORDER_FRAGMENTS_TILED_BIT | NVN_BARRIER_ORDER_INDIRECT_DATA_BIT))'
BARRIER = 'if (P.open && P.sw_pend && ' + MASK + ') P.sw_split = 1;'
CUT = 'if (P.open && P.sw_split) { rp_perf_add(RP_PERF_P_CUT_BAR, 1); rp_pass_end(c); }'
RESET = 'P.ndraw = 0; P.sw_pend = P.sw_split = 0;'
NOTE = 'if (note & RP_NOTE_SHADER_WRITE) P.sw_pend = 1;'
KINDS = '(e->src_kind == NVN_RB_IMG || e->src_kind == NVN_RB_IMGU || e->src_kind == NVN_RB_IMGA || e->src_kind == NVN_RB_SBUFP || e->src_kind == NVN_RB_GMEM)'
WACC = '(e->access & NVN_GPU_ACC_W) && ' + KINDS
CALL = '(prog_shader_writes(g_prog) ? RP_NOTE_SHADER_WRITE : 0)'


def barrier_mask(drop):   # 屏障位判据里去掉一个顺序位
    return MASK.replace(' | NVN_BARRIER_' + drop + '_BIT', '').replace('NVN_BARRIER_' + drop + '_BIT | ', '')


# (名字, 文件, [(锚点, 替换)], 期望红的那一行里必须出现的片段)
mutations = [
    ('屏障之后不拆通道（退回修前：只记位）', PASS, [(CUT, 'if (P.open && P.sw_split && 0) { rp_perf_add(RP_PERF_P_CUT_BAR, 1); rp_pass_end(c); }')],
     't_shader_write_barrier_split img=0 W b21 R：通道 1（期望 2）'),
    ('拆了通道不记读数', PASS, [(CUT, 'if (P.open && P.sw_split) { rp_pass_end(c); }')],
     't_shader_write_barrier_split img=0 W b21 R：通道 2（期望 2）被屏障结束 0（期望 1）'),
    ('通道里的着色器写不记（note_draw 不收写位）', PASS, [(NOTE, '')],
     't_shader_write_barrier_split img=0 W b21 R：通道 1（期望 2）'),
    ('任何屏障都拆（不看顺序位：只有缓存失效位的也拆）', PASS, [(MASK, '(bits)')],
     't_shader_write_barrier_split img=0 W b20 R：通道 2（期望 1）'),
    ('没有着色器写也拆（只读的通道遇到屏障也拆）', PASS, [('P.open && P.sw_pend && ' + MASK, 'P.open && ' + MASK)],
     't_shader_write_barrier_split img=0 R b21 R：通道 2（期望 1）'),
    ('不认 ORDER_PRIMITIVES', PASS, [(MASK, barrier_mask('ORDER_PRIMITIVES'))],
     't_shader_write_barrier_split img=0 W b21 R：通道 1（期望 2）'),
    ('不认 ORDER_FRAGMENTS', PASS, [(MASK, barrier_mask('ORDER_FRAGMENTS'))],
     't_shader_write_barrier_split img=0 W b02 R：通道 1（期望 2）'),
    ('不认 ORDER_FRAGMENTS_TILED', PASS, [(MASK, barrier_mask('ORDER_FRAGMENTS_TILED'))],
     't_shader_write_barrier_split img=0 W b04 R：通道 1（期望 2）'),
    ('不认 ORDER_INDIRECT_DATA', PASS, [(MASK, barrier_mask('ORDER_INDIRECT_DATA'))],
     't_shader_write_barrier_split img=0 W b08 R：通道 1（期望 2）'),
    ('新通道开头不清写标记（拆过的通道里没有写，下一次屏障又拆）', PASS, [(RESET, 'P.ndraw = 0;')],
     't_shader_write_barrier_split img=0 W b01 R b01 R：通道 3（期望 2）'),
    ('读也算着色器写（不看写访问位）', DRAW, [(WACC, KINDS)],
     't_shader_write_barrier_split img=0 R b21 R：通道 2（期望 1）'),
    ('存储缓冲的写不算', DRAW, [(KINDS, KINDS.replace('e->src_kind == NVN_RB_SBUFP || ', ''))],
     't_shader_write_barrier_split img=0 W b21 R：通道 1（期望 2）'),
    ('存储图像的写不算', DRAW, [(KINDS, KINDS.replace('(e->src_kind == NVN_RB_IMG || ', '('))],
     't_shader_write_barrier_split img=1 W b21 R：通道 1（期望 2）'),
    ('绘制收尾不告诉通道这笔有着色器写', DRAW, [(CALL, '0')],
     't_shader_write_barrier_split img=0 W b21 R：通道 1（期望 2）'),
]
others = ['graphics/nvn/tests/t_nvn_replay.c', 'graphics/nvn/tests/nvn_clear_view_unused.c',
          *('graphics/nvn/replay/' + x for x in ('rp_exec.c', 'rp_copy_t2b.c', 'rp_clear_tex.c', 'rp_draw_tex.c', 'rp_state.c', 'rp_entry.c', 'rp_res.c', 'rp_buf.c', 'rp_present.c', 'nvn_unimpl.c')),
          'graphics/nvn/gfx/nvn/nvn_tex.c', 'graphics/nvn/gfx/tex/nvn_deswizzle.c']
flags = ['-O1', '-g', '-Wall', '-Wextra', '-Wno-unused-parameter', '-std=c11', '-D_DEFAULT_SOURCE', '-DS2A_TEST_TS_ALLOC', '-DS2A_GPU_LAND_TEST', '-DS2A_TEST_TREG_SCRUB',
         *('-I' + str(ROOT / x) for x in ('.', 'graphics/nvn/gfx/nvn', 'graphics/nvn/gfx/nvn/include', 'graphics/nvn/gfx/tex', 'graphics/nvn/replay'))]
link = subprocess.run([sys.executable, str(ROOT / 'tools/weak_link_decl.py'), 'flags', 'replay'], check=True, capture_output=True, text=True).stdout.split() if sys.platform == 'darwin' else []
objs = []


def compile_one(d, rel, code, strict):
    src = d / Path(rel).name; src.write_text(code, encoding='utf-8')
    o = d / (Path(rel).stem + '.o')
    subprocess.run([CC, *flags, *(['-Werror'] if strict else ['-w']), '-c', str(src), '-o', str(o)], check=True, cwd=ROOT)
    return str(o)


def run(name, rel, code, base_objs):   # rel：被改的文件；base_objs：{rel: 未改的 .o}
    d = OUT / name
    shutil.rmtree(d, ignore_errors=True); d.mkdir(parents=True)
    mine = compile_one(d, rel, code, name == 'positive')
    exe = d / 't'
    subprocess.run([CC, *objs, *(v for k, v in base_objs.items() if k != rel), mine, *link, '-lm', '-o', str(exe)], check=True, cwd=ROOT)
    return subprocess.run([str(exe), str(ROOT / 'docs/直连_Vulkan回放接线表.tsv')], capture_output=True, text=True, cwd=ROOT, timeout=180)


def main():
    for x in others:
        o = OUT / ('obj_%s.o' % Path(x).stem)
        subprocess.run([CC, *flags, '-Werror', '-c', str(ROOT / x), '-o', str(o)], check=True, cwd=ROOT)
        objs.append(str(o))
    src = {rel: (ROOT / rel).read_text(encoding='utf-8') for rel in (PASS, DRAW)}
    base_objs = {}
    for rel in (PASS, DRAW):
        d = OUT / ('base_' + Path(rel).stem); shutil.rmtree(d, ignore_errors=True); d.mkdir(parents=True)
        base_objs[rel] = compile_one(d, rel, src[rel], True)
    pos = run('positive', PASS, src[PASS], base_objs)
    if pos.returncode:
        raise SystemExit('正对照没过\n' + pos.stdout[-2000:] + pos.stderr[-1000:])
    print('正对照：', [l for l in pos.stdout.splitlines() if '项检查' in l][-1:], flush=True)
    for i, (name, rel, edits, want) in enumerate(mutations):
        code = src[rel]
        for old, new in edits:
            assert code.count(old) == 1, (name, '变异锚点', old[:60])
            code = code.replace(old, new)
        assert code != src[rel], (name, '变异没改动任何东西')
        r = run('m%d' % i, rel, code, base_objs)
        out = r.stdout + r.stderr
        if r.returncode == 0:
            raise SystemExit(name + '：变异体居然通过了')
        if want not in out:
            reds = [l for l in out.splitlines() if '【红】' in l or 't_shader_write_barrier_split' in l]
            raise SystemExit('%s：红在别处，期望含 %r\n%s' % (name, want, '\n'.join(reds[:6])))
        print('  %s：已拦住（红在「%s」）' % (name, want), flush=True)
    print('PASS: 通道里着色器写之后的游戏屏障共 %d 个变异体全部被单测拦住' % len(mutations))


main()
