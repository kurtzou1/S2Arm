#!/usr/bin/env python3
# 直连抽取按文件降级（v0.3.1 拿不准不停 ⑦）：translator/shader_split.py scan_counted。约 0.1 秒，退出 0 = 全过。
# 原先任一文件的读取器 red()（sys.exit('[RED] …')）或解析异常就让整份抽取退出，本款离线直连库 0 支。期望手写：
#   ① 读取器 [RED] 退出 → 不抛、返回空结果 + (FILE_RED, '<相对路径>: <原因>')
#   ② struct.error 等解析异常 → 同 ①，原因带异常类名
#   ③ MemoryError → 照旧抛（环境问题）
#   ④ 正常文件 → 原样返回 scan_file 的结果 + SKIPPED 增量
import os, struct, sys, tempfile
from pathlib import Path
H = Path(__file__).resolve().parents[4]
bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')
with tempfile.TemporaryDirectory(prefix='splitskip-') as t:
    (Path(t) / 'game.tsv').write_text('shader_groups\tsynthetic=synthetic\nshader_note\tsynthetic\n')
    os.environ['DM_GAME'] = t
    sys.path.insert(0, str(H / 'translator'))
    import shader_split as S
    def fake(job):
        if job[1] == 'red.bin': S.red('reader does not know this container')
        if job[1] == 'parse.bin': struct.unpack_from('<I', b'', 0)
        if job[1] == 'oom.bin': raise MemoryError()
        return (job[1], {'k': 1}, {('a', 'b')}, {})
    S.scan_file = fake
    def run(rel):
        try: return S.scan_counted(('/x/' + rel, rel))
        except BaseException as e: return type(e).__name__
    r = run('red.bin')
    chk('① [RED] 退出：只跳过这个文件', ('red.bin', {}, set(), {}, [(getattr(S, 'FILE_RED', None), 'red.bin: reader does not know this container')]), r)
    r = run('parse.bin')
    chk('② 解析异常：只跳过这个文件、原因带 struct.error', (True, True), (isinstance(r, tuple) and r[1] == {}, isinstance(r, tuple) and r[4][0][1].startswith('parse.bin: error:')))
    chk('③ MemoryError 照旧抛', 'MemoryError', run('oom.bin'))
    chk('④ 正常文件原样返回', ('ok.bin', {'k': 1}, {('a', 'b')}, {}, []), run('ok.bin'))
print(f'{"✓" if not bad else "✗"} t_split_file_skip：{bad} 处不符')
sys.exit(1 if bad else 0)
