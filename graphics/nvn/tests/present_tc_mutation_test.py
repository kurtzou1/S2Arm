#!/usr/bin/env python3
"""上屏线程 CPU（rp_present.c rp_present_tc_note / _take，#1501 差距 9）的点变异：每条撤掉一处判据，t_nvn_replay 的 t_present_thread_cpu 与上屏接线检查必须红。"""
import os
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'build/present-tc-mutations'
OUT.mkdir(parents=True, exist_ok=True)
TARGET = 'graphics/nvn/replay/rp_present.c'
source = (ROOT/TARGET).read_text()
mutations = [
    # 跨线程也相减
    ('cross-thread', 'if (pthread_equal(me, g_tc_tid) && wall_ns >= g_tc_wall0', 'if ((pthread_equal(me, g_tc_tid) || 1) && wall_ns >= g_tc_wall0', 'tc[0] == 400 && tc[1] == 70'),
    # 时间倒退也计
    ('backwards', '&& wall_ns >= g_tc_wall0 && cpu_ns >= g_tc_cpu0)', '&& (wall_ns >= g_tc_wall0 || 1) && cpu_ns >= g_tc_cpu0)', 'tc[0] == 400 && tc[1] == 70'),
    # 第一次也当样本（起点为 0）
    ('first-counted', '    if (g_tc_have) {', '    if (g_tc_have || 1) {', 'tc[2] == 0 && tc[3] == 0 && tc[0] == 0'),
    # 取走不清零
    ('take-keeps', '    g_tc_wall = g_tc_cpu = g_tc_n = g_tc_cross = 0;\n    pthread_mutex_unlock(&g_tc_mu);\n}', '    pthread_mutex_unlock(&g_tc_mu);\n}', 'tc[0] == 0 && tc[2] == 0 && tc[3] == 0'),
    # 会话 reset 不清起点
    ('reset-keeps', 'pthread_mutex_lock(&g_tc_mu); g_tc_have = 0;', 'pthread_mutex_lock(&g_tc_mu); g_tc_have = g_tc_have + 0 * g_tc_have;', 'tc[2] == 0 && tc[3] == 0'),
    # 上屏路径没接
    ('not-wired', '{ const uint64_t cpu = tc_thread_cpu_ns(); if (cpu) rp_present_tc_note(now, cpu); }', '{ const uint64_t cpu = tc_thread_cpu_ns(); if (cpu && 0) rp_present_tc_note(now, cpu); }', 'tc[2] + tc[3] >= 1'),
]
sources = ['graphics/nvn/tests/t_nvn_replay.c','graphics/nvn/tests/nvn_clear_view_unused.c',
           *('graphics/nvn/replay/'+x for x in ('rp_exec.c','rp_copy_t2b.c','rp_clear_tex.c','rp_state.c','rp_entry.c','rp_res.c','rp_draw.c','rp_pass.c','rp_buf.c','nvn_unimpl.c')),
           'graphics/nvn/gfx/nvn/nvn_tex.c','graphics/nvn/gfx/tex/nvn_deswizzle.c']
base = [os.environ.get('CC','cc'),'-O2','-g','-DS2A_GPU_LAND_TEST','-pthread','-Wall','-Wextra','-Wno-unused-parameter','-std=c11','-D_DEFAULT_SOURCE','-Werror',
        *('-I'+str(ROOT/x) for x in ('.','graphics/nvn/gfx/nvn','graphics/nvn/gfx/nvn/include','graphics/nvn/gfx/tex','graphics/nvn/replay'))]
# 回放核心对平台 / 后端可选件的弱引用：苹果 ld 默认不认未定义弱符号，逐个允许缺；清单只从源码登记生成（tools/weak_link_decl.py flags replay）
import sys
if sys.platform == 'darwin':
    base += subprocess.run([sys.executable, str(ROOT/'tools/weak_link_decl.py'), 'flags', 'replay'], check=True, capture_output=True, text=True).stdout.split()
def run(name, code):
    path = OUT/(name+'.c'); path.write_text(code)
    exe = OUT/name
    subprocess.run(base + [str(ROOT/x) for x in sources] + [str(path),'-lm','-o',str(exe)], check=True, cwd=ROOT)
    return subprocess.run([str(exe), str(ROOT/'docs/直连_Vulkan回放接线表.tsv')], capture_output=True, text=True, cwd=ROOT)
pos = run('positive', source)
if pos.returncode: raise SystemExit('positive failed: ' + pos.stdout + pos.stderr)
print('positive:', pos.stdout.splitlines()[-1], flush=True)
for name, old, new, want in mutations:
    if source.count(old) != 1: raise SystemExit(name + ': mutation anchor invalid')
    r = run(name, source.replace(old,new))
    if r.returncode == 0 or want not in r.stdout: raise SystemExit(name + ': wrong failure: ' + r.stdout + r.stderr)
    print(name + ': expected assertion ' + want, flush=True)
print('PASS: 上屏线程 CPU %d 个变异体全部被单测拦住' % len(mutations))
