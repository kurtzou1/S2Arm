#!/usr/bin/env python3
# 资源目录列表走 @<列表文件>（11-05 Windows 出包机怪猎崛起 273 个追加内容：extract.py 把目录拼进命令行，超过 Windows 32767 字符上限，起 Python 报「Argument list too long」）。
#   期望手写：① shader_split.list_arg：逗号串照旧拆；@文件按行读，去掉行尾 \r\n、跳过空行
#   ② nxsh_extract.py <输出> @<列表>：300 个长名资源目录各放 1 个文件（路径合计超过 32767 字符），退 0、统计「顶层文件」= 300（列表里的目录都被读到）
import os, subprocess, sys, tempfile
from pathlib import Path

H = Path(__file__).resolve().parents[4]
bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')

with tempfile.TemporaryDirectory(prefix='listarg-') as t:
    t = Path(t)
    (t / 'game.tsv').write_text('shader_groups\tsynthetic=synthetic\nshader_note\tsynthetic\n')
    os.environ['DM_GAME'] = str(t)
    sys.path.insert(0, str(H / 'translator'))
    import shader_split
    chk('① 逗号串照旧拆', ['a/romfs', 'b/aoc/1'], shader_split.list_arg('a/romfs,b/aoc/1'))
    (t / 'r.lst').write_bytes(b'a/romfs\r\nb/aoc/1\n\nc,d/aoc/2\n')
    chk('① @文件按行读（去 \\r\\n、跳空行、行内逗号不拆）', ['a/romfs', 'b/aoc/1', 'c,d/aoc/2'], shader_split.list_arg('@' + str(t / 'r.lst')))
    dirs = [t / 'res' / (f'{i:03d}_' + 'x' * 100) for i in range(300)]
    for d in dirs: d.mkdir(parents=True); (d / 'a.bin').write_bytes(b'\0' * 64)
    (t / 'roots.lst').write_text(''.join(f'{d}\n' for d in dirs), encoding='utf-8')
    chk('② 列表里的目录路径合计超过 32767 字符（测的确是超长那种）', True, sum(len(str(d)) + 1 for d in dirs) > 32767)
    p = subprocess.run([sys.executable, str(H / 'graphics/tools/shbake/nxsh_extract.py'), str(t / 'out'), '@' + str(t / 'roots.lst')], capture_output=True, text=True, env=dict(os.environ, J='2'))
    chk('② nxsh_extract @列表：退 0、300 个目录里的文件都读到（统计「顶层文件」300）', (0, True), (p.returncode, "'顶层文件': 300" in p.stdout + p.stderr))
    if p.returncode: print(p.stderr[-800:])
print(f'资源目录列表文件：失败 {bad}')
sys.exit(1 if bad else 0)
