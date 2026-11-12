#!/usr/bin/env python3
"""gl_shaders.py 两个目标各剔各的编不过（审计 P1-176）：python3 tests/gl_shaders_target_test.py
翻译 / Metal 编译 / 链库全用替身，不调 glslang、spirv-cross、metal。三支 a b c，iPhone 全编得过，Mac 编不过的支按场景给。期望（手写）：
  Mac 只 a 编不过 → Mac 表 b c、iPhone 表 a b c（原先 iPhone 也只剩 b c）、汇总「成功 3、失败 1」、退 0
  Mac 三支全编不过 → Mac 只有表头且没有库、iPhone 表 a b c 且库在（原先两边都只出表头）、汇总「成功 3、失败 3」、退 0
  两个目标都全编不过 → 两边只有表头、汇总「成功 0、失败 3」、退 0（v0.3.1 照出空表）"""
import contextlib, io, os, sys, tempfile
from pathlib import Path
from unittest import mock
R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / 'translator'))
import gl_shaders as gs
bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok; print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')

def run(mac_bad, ios_bad=''):
    with tempfile.TemporaryDirectory() as t:
        out, ios = Path(t) / 'mac', Path(t) / 'ios'
        srcs = [(f'void main(){{}} // {k}'.encode(), 'vert', f'romfs/{k}.vsh') for k in 'abc']
        def one(task, temp, components):
            i, (src, stage, where) = task; k = where[6]
            m = Path(temp) / f'{k}.metal'; m.write_text('x'); s = Path(temp) / f'{k}.spv'; s.write_bytes(b'x')
            return [{'key': k * 16, 'stage': stage, 'function': f'gl_{k}', 'msl': str(m), 'spv': str(s), 'fields': ['-'], 'source': where, 'unsupported': []}], [], 0
        def compile_msl(task, temp):
            identity, row, sdk, extra = task; k = row['source'][6]
            if k in (mac_bad if sdk == 'macosx' else ios_bad): return identity, sdk, None, f"{row['source']} [{sdk}]: synthetic error"
            return identity, sdk, f'{k}.{sdk}.air', None
        def library(airs, destination, sdk):
            p = Path(destination) / f'gl_shaders.{sdk}.metallib'; Path(destination).mkdir(parents=True, exist_ok=True); p.write_bytes(b'lib'); return p
        o = io.StringIO()
        with mock.patch.object(gs, 'sources', lambda roots: srcs), mock.patch.object(gs, 'one', one), mock.patch.object(gs, 'compile_msl', compile_msl), \
             mock.patch.object(gs, 'library', library), mock.patch.object(gs, 'tool_version', lambda c: 'v'), \
             mock.patch.object(sys, 'argv', ['gl_shaders.py', t, str(out), '--ios', str(ios), '-j', '1']), contextlib.redirect_stdout(o), contextlib.redirect_stderr(io.StringIO()):
            rc = gs.main()
        rows = lambda d: [l.split('\t')[0][0] for l in (d / 'gl' / 'gl_shaders.tsv').read_text(encoding='utf-8').splitlines() if not l.startswith('#')]
        lib = lambda d: (d / 'gl' / 'gl_shaders.metallib').exists()
        return rc, rows(out), lib(out), rows(ios), lib(ios), [l for l in o.getvalue().splitlines() if l.startswith('GLSL 汇总')]
rc, m, ml, i, il, s = run('a')
chk('Mac 只 a 编不过：退出码', 0, rc)
chk('Mac 只 a 编不过：Mac 表 / iPhone 表仍有 a', (['b', 'c'], ['a', 'b', 'c']), (m, i))
chk('Mac 只 a 编不过：汇总行', ['GLSL 汇总：成功 3、失败 1、跳过 0'], s)
rc, m, ml, i, il, s = run('abc')
chk('Mac 全编不过：退出码', 0, rc)
chk('Mac 全编不过：Mac 只有表头、没有库', ([], False), (m, ml))
chk('Mac 全编不过：iPhone 表与库都在', (['a', 'b', 'c'], True), (i, il))
chk('Mac 全编不过：汇总行', ['GLSL 汇总：成功 3、失败 3、跳过 0'], s)
rc, m, ml, i, il, s = run('abc', 'abc')
chk('两边全编不过：退出码 / 两边只有表头', (0, [], False, [], False), (rc, m, ml, i, il))
chk('两边全编不过：汇总行', ['GLSL 汇总：成功 0、失败 3、跳过 0'], s)
print(f'{"✓" if not bad else "✗"} gl_shaders_target：{bad} 不通')
sys.exit(1 if bad else 0)
