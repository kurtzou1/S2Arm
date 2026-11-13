#!/usr/bin/env python3
"""GLSL 改写工具先用启动器预编件（#852）：python3 tests/gl_es_prebuilt_test.py，约 2 秒
背景：Windows 玩家机没有 C 编译器，translator/gl_shaders.py es_tool 每次现编 gl_glsl_es.c 都失败，OpenGL 款离线库只剩表头、运行时现编又认不出版本行 → 黑屏。
改为发版时预编进 S2A_PREBUILT_TOOLS/codecs/glsl_es-<源码 sha1 前 12 位>[.exe]（launchers/windows/bundle_prepare_win.py），在就用。期望（手算）：
  ① 预编件名对得上源码哈希 → es_tool 直接用它，不找编译器（CC 指向不存在的程序也行）
  ② 只有旧哈希的预编件、也没有编译器 → 不用旧件；报错写明没有 C 编译器和要找的预编件名
  ③ 没有预编件、本机有 cc → 现编出同名工具，prefix 把「#version 300」补成「#version 300 es」"""
import hashlib, os, sys, tempfile
from pathlib import Path
from unittest import mock
R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / 'translator'))
import gl_shaders as gs
bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok; print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')
want_name = 'glsl_es-' + hashlib.sha1((R / 'graphics/nvn/gfx/gl/gl_glsl_es.c').read_bytes()).hexdigest()[:12] + ('.exe' if os.name == 'nt' else '')
chk('工具名 = glsl_es-<源码 sha1 前 12 位>', want_name, gs.es_name())
with tempfile.TemporaryDirectory() as t:
    t = Path(t); (t / 'codecs').mkdir(); pre = t / 'codecs' / want_name; pre.write_bytes(b'stub')
    gs._es_bin = None
    with mock.patch.dict(os.environ, {'S2A_PREBUILT_TOOLS': str(t), 'CC': str(t / 'no-such-cc')}):
        chk('① 预编件对得上 → 直接用', pre, gs.es_tool())
    pre.unlink(); (t / 'codecs' / 'glsl_es-000000000000').write_bytes(b'old')
    gs._es_bin = None
    with mock.patch.dict(os.environ, {'S2A_PREBUILT_TOOLS': str(t), 'CC': str(t / 'no-such-cc')}):
        try: gs.es_tool(); got = '没报错'
        except ValueError as e: got = str(e)
    chk('② 旧哈希不用、没编译器报清楚', (True, True), ('没有 C 编译器' in got, want_name in got))
    gs._es_bin = None
    env = {k: v for k, v in os.environ.items() if k not in ('S2A_PREBUILT_TOOLS', 'CC')}
    with mock.patch.dict(os.environ, env, clear=True):
        exe = gs.es_tool(); out = gs.es(['prefix'], b'#version 300\nvoid main(){}\n')
    chk('③ 现编同名工具', want_name, Path(exe).name)
    chk('③ prefix 补 es', b'#version 300 es\nvoid main(){}\n', out)
print(f'{"✓" if not bad else "✗"} gl_es_prebuilt：{bad} 不通'); sys.exit(1 if bad else 0)
