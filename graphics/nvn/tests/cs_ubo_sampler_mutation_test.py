#!/usr/bin/env python3
"""计算派发里「贴图字在游戏常量缓冲里的类型 3 句柄」（rp_draw.c rp_dispatch 的 NVN_RB_TEXU 分支，#1594 片 10）的点变异：
每个变异体撤掉 / 改坏一处判据，t_nvn_replay 的 t_cs_ubo_const_sampler 必须红在指定的断言上。
每个变异体在 build/ 下的副本里重编 rp_draw.c 再链接，源码树不动。

用法：python3 cs_ubo_sampler_mutation_test.py
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'build/cs-ubo-sampler-mutations'
OUT.mkdir(parents=True, exist_ok=True)
CC = os.environ.get('CC', 'cc')
DRAW = 'graphics/nvn/replay/rp_draw.c'

HEAD = 'if (e->src_kind == NVN_RB_TEXU) {   // 贴图字在游戏用户常量缓冲里的类型 3 句柄（#1594 片 10）'
SHAPE = 'if (e->count != 1 || e->src_reg2 >= pg->nusrc) { skip("uniform_handle_shape", rec); goto done; }'
STAGE = 'const char *bad = usrc_ids(5, &pg->usrc[e->src_reg2], &tid, &sid);'
VIEW = 'tv[i] = rp_view_by_ubo_handle_decl(tid, pg->dtt[0][i], pg->dcls[0][i], c, NULL);'
SAMP = 'ts[i] = const_samp ? rp_samp_for_const_handle(sid, tid, rp_S.samp_base, rp_S.samp_pool_n) : rp_samp_for_tex(sid, tid);'
FAIL = 'if (!ts[i] && const_samp) { skip("const_sampler_unresolved", rec); goto done; }'

mutations = [
    ('计算阶段不处理 NVN_RB_TEXU（退回修前：这一项落到「不是 NVN_RB_TEX 就略过」）', [(HEAD, 'if (0 && e->src_kind == NVN_RB_TEXU) {   // 变异')],
     'g_ndisp == d0 + 1 && g_ncb == 1'),
    ('贴图字取图形阶段（1）绑的常量缓冲，不取计算阶段（5）绑的那一份', [(STAGE, 'const char *bad = usrc_ids(1, &pg->usrc[e->src_reg2], &tid, &sid);')],
     'g_cb[0].u.ts.view->of->d.d.width == 2 && g_cb[0].u.ts.samp && g_cb[0].u.ts.samp->x == 1'),
    ('采样器一律按登记号原值取（不或字高位、不加池起点、没登记不绑默认采样器）', [(SAMP, 'ts[i] = rp_samp_for_tex(sid, tid);')],
     'g_ndisp == d0 + 5 && g_cb[0].u.ts.view'),
    ('登记了但后端建不出的采样器不具名跳过', [(FAIL, '')],
     'nvn_unimpl_count("draw", "const_sampler_unresolved") == 1 && rp_const_samp_default_count() == fail_csd0'),
    ('形状校验不看数组（count > 1 照样往下取）', [(SHAPE, 'if (e->src_reg2 >= pg->nusrc) { skip("uniform_handle_shape", rec); goto done; }')],
     'nvn_unimpl_count("draw", "uniform_handle_shape") == 1'),
    ('形状校验不看句柄来源表下标（越界下标照样往下取）', [(SHAPE, 'if (e->count != 1) { skip("uniform_handle_shape", rec); goto done; }')],
     'nvn_unimpl_count("draw", "uniform_handle_shape") == 2'),
    ('取视图时不带着色器声明的目标 / 数值类（空槽建不出声明类型的零贴图）', [(VIEW, 'tv[i] = rp_view_by_ubo_handle_decl(tid, 0, 0, c, NULL);')],
     'g_cb[0].u.ts.view->of->d.d.width == 1 && g_cb[0].u.ts.view->of->d.d.format == NVN_FORMAT_RGBA8 && rp_ubo_zero_count() == uz0 + 1'),
]
others = ['graphics/nvn/tests/t_nvn_replay.c', 'graphics/nvn/tests/nvn_clear_view_unused.c',
          *('graphics/nvn/replay/' + x for x in ('rp_exec.c', 'rp_copy_t2b.c', 'rp_clear_tex.c', 'rp_draw_tex.c', 'rp_state.c', 'rp_entry.c', 'rp_res.c', 'rp_buf.c', 'rp_pass.c', 'rp_present.c', 'nvn_unimpl.c')),
          'graphics/nvn/gfx/nvn/nvn_tex.c', 'graphics/nvn/gfx/tex/nvn_deswizzle.c']
flags = ['-O1', '-g', '-Wall', '-Wextra', '-Wno-unused-parameter', '-std=c11', '-D_DEFAULT_SOURCE', '-DS2A_TEST_TS_ALLOC', '-DS2A_GPU_LAND_TEST', '-DS2A_TEST_TREG_SCRUB',
         *('-I' + str(ROOT / x) for x in ('.', 'graphics/nvn/gfx/nvn', 'graphics/nvn/gfx/nvn/include', 'graphics/nvn/gfx/tex', 'graphics/nvn/replay'))]
link = subprocess.run([sys.executable, str(ROOT / 'tools/weak_link_decl.py'), 'flags', 'replay'], check=True, capture_output=True, text=True).stdout.split() if sys.platform == 'darwin' else []
objs = []


def run(name, code):
    d = OUT / name
    shutil.rmtree(d, ignore_errors=True); d.mkdir(parents=True)
    src = d / 'rp_draw.c'; src.write_text(code, encoding='utf-8')
    o = d / 'rp_draw.o'
    subprocess.run([CC, *flags, *(['-Werror'] if name == 'positive' else ['-w']), '-c', str(src), '-o', str(o)], check=True, cwd=ROOT)
    exe = d / 't'
    subprocess.run([CC, *objs, str(o), *link, '-lm', '-o', str(exe)], check=True, cwd=ROOT)
    return subprocess.run([str(exe), str(ROOT / 'docs/直连_Vulkan回放接线表.tsv')], capture_output=True, text=True, cwd=ROOT, timeout=180)


def main():
    for x in others:
        o = OUT / ('obj_%s.o' % Path(x).stem)
        subprocess.run([CC, *flags, '-Werror', '-c', str(ROOT / x), '-o', str(o)], check=True, cwd=ROOT)
        objs.append(str(o))
    base = (ROOT / DRAW).read_text(encoding='utf-8')
    pos = run('positive', base)
    if pos.returncode:
        raise SystemExit('正对照没过\n' + pos.stdout[-2000:] + pos.stderr[-1000:])
    print('正对照：', [l for l in pos.stdout.splitlines() if '项检查' in l][-1:], flush=True)
    for i, (name, edits, want) in enumerate(mutations):
        code = base
        for old, new in edits:
            assert code.count(old) == 1, (name, '变异锚点', old[:60])
            code = code.replace(old, new)
        r = run('m%d' % i, code)
        out = r.stdout + r.stderr
        if r.returncode == 0:
            raise SystemExit(name + '：变异体居然通过了')
        if want not in out:
            reds = [l for l in out.splitlines() if '【红】' in l]
            raise SystemExit('%s：红在别处，期望含 %r\n%s' % (name, want, '\n'.join(reds[:6])))
        print('  %s：已拦住（红在「%s」）' % (name, want), flush=True)
    print('PASS: 计算阶段常量缓冲类型 3 句柄共 %d 个变异体全部被单测拦住' % len(mutations))


main()
