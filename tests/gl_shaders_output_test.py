#!/usr/bin/env python3
"""gl_shaders.py 外部工具的输出按 UTF-8 宽松解（D-TCA9）：python3 tests/gl_shaders_output_test.py
Windows 上 text=True 按系统代码页（中文 Windows 为 GBK）解子进程输出，解不开时读输出线程出错、stdout / stderr 成 None，失败时拼原因先抛 TypeError，真原因丢掉。
子进程用替身，不调真工具。期望（手写）：
  失败、stderr 是 Shift-JIS 日文 + 非法字节 → 抛 ValueError（不是 TypeError），原因里带 stderr 的 ASCII 部分「ERROR: 0:3」
  失败、stdout 为 None（Windows 读线程解码出错后的样子）、stderr 有字 → ValueError，原因 = stderr
  成功、stdout 是 UTF-8 中文 → 原样返回 str
  run / metal / tool_version 三处同样"""
import subprocess, sys
from pathlib import Path
from unittest import mock
R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / 'translator'))
import gl_shaders as gs
bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok; print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')
def outcome(fn, out, err, rc):
    done = subprocess.CompletedProcess(['x'], rc, stdout=out, stderr=err)
    with mock.patch.object(gs.subprocess, 'run', lambda *a, **k: done), mock.patch.object(gs, 'metal_run', lambda *a, **k: done):
        try:
            return 'ok', fn()
        except ValueError as e:
            return 'ValueError', str(e)
        except TypeError as e:
            return 'TypeError', str(e)
sjis = 'ERROR: 0:3 未定義の識別子'.encode('shift_jis') + b'\xff\xfe'
for name, fn in (('run', lambda: gs.run(['glslangValidator'])), ('metal', lambda: gs.metal(['metal'], '.')), ('tool_version', lambda: gs.tool_version(['spirv-cross']))):
    k, msg = outcome(fn, b'', sjis, 1)
    chk(f'{name} 失败、stderr 带 Shift-JIS 与非法字节：异常类型', 'ValueError', k)
    chk(f'{name} 失败：原因带 ASCII 部分', True, 'ERROR: 0:3' in msg)
    chk(f'{name} 失败、stdout 为 None', ('ValueError', 'boom'), outcome(fn, None, b'boom', 1))
k, msg = outcome(lambda: gs.run(['spirv-cross']), '着色器 ok'.encode('utf-8'), b'', 0)
chk('run 成功、UTF-8 中文输出', ('ok', '着色器 ok'), (k, msg))
k, msg = outcome(lambda: gs.tool_version(['glslangValidator']), b'Glslang Version: 11\n', b'', 0)
chk('tool_version 成功', ('ok', 'Glslang Version: 11'), (k, msg))
print(f'{"✓" if not bad else "✗"} gl_shaders_output_test：{bad} 项不通')
sys.exit(1 if bad else 0)
