#!/usr/bin/env python3
"""vk_shaders.py 合库走响应文件（11-06 Windows 出包机银河 2 第二包：3795 个 .air 拼在 metallib 命令行上超 Windows 32767 字符，WinError 206）：python3 tests/vk_shaders_rsp_test.py
期望（手写）：5000 个 .air（每个路径约 80 字符，直拼约 40 万字符）→ metallib 命令行只带「@<响应文件>」、总长 < 2000 字符；响应文件 5000 行、
  每行一个带引号的路径、顺序同输入；调用后响应文件删掉；Windows 口径（os.name 置 nt）下清单写相对临时目录的路径、工作目录设成临时目录（11-09 中文用户名）。外部命令一律替身，不调 metal / metallib"""
import os, sys, tempfile
from pathlib import Path
from unittest import mock
R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / 'translator'))
import vk_shaders as vs
bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok; print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')
for nt in (False, True):
    with tempfile.TemporaryDirectory() as t:
        msls = [os.path.join(t, f'shader_{i:05d}_' + 'x' * 50 + '.metal') for i in range(5000)]
        seen = {}
        def run(cmd, **kw):
            cwd = kw.get('cwd') or ''
            if 'metallib' in os.path.basename(str(cmd[0])) or 'metallib' in cmd:
                at = [os.path.join(cwd, str(c)[1:]) for c in cmd if str(c).startswith('@')]
                seen['len'] = len(' '.join(map(str, cmd))); seen['rsp'] = open(at[0], encoding='utf-8').read().splitlines() if at else None; seen['path'] = at[0] if at else None
                seen['cwd'] = cwd
                open(os.path.join(cwd, str(cmd[cmd.index('-o') + 1])), 'wb').write(b'lib')   # 替身产出库文件（之后挪进 out）
            class P: returncode = 0; stderr = ''
            return P()
        sep = '\\' if nt else os.sep
        with mock.patch.object(vs.subprocess, 'run', run), mock.patch.object(vs.os, 'name', 'nt' if nt else os.name), mock.patch.object(vs.os, 'sep', sep):
            lib, failed = vs.metallib(msls, os.path.join(t, 'out'), 'iphoneos', [], t)   # v0.3.1：返回（库路径, 编不过的支）
            chk('没有编不过的支', {}, failed)
        # Windows 口径：清单里写相对工作目录（= 临时目录 t）的路径（编译器按 ANSI 开文件、会拆空格，见 spirv_msl.metal_run）
        want = ['"' + (os.path.basename(m[:-6]) + '.iphoneos.air' if nt else m[:-6] + '.iphoneos.air') + '"' for m in msls]
        tag = 'Windows 口径' if nt else '本机口径'
        chk(f'{tag}：metallib 命令行只带响应文件、长度 < 2000', (True, True), (seen.get('rsp') is not None, seen.get('len', 10**9) < 2000))
        chk(f'{tag}：响应文件 5000 行、带引号、顺序同输入', want, seen.get('rsp'))
        chk(f'{tag}：调用后响应文件已删', False, bool(seen.get('path')) and os.path.exists(seen['path']))
        chk(f'{tag}：库挪进输出目录', (os.path.join(t, 'out', 'vk_shaders.metallib'), True), (lib, os.path.isfile(lib)))
        if nt: chk(f'{tag}：metallib 的工作目录 = 临时目录', t, seen.get('cwd'))
# v0.3.1 拿不准不停：一支 Metal 编不过只剔这一支、其余照链（原先 red 退出、整份没有库）。替身编译器对第 2 支（下标 1）回 rc 1
with tempfile.TemporaryDirectory() as t:
    msls = [os.path.join(t, f's{i}.metal') for i in range(3)]; rsp = {}
    def run2(cmd, **kw):
        class P: returncode = 0; stderr = ''
        if 'metallib' in os.path.basename(str(cmd[0])) or 'metallib' in cmd:
            at = [str(c)[1:] for c in cmd if str(c).startswith('@')]; rsp['airs'] = open(at[0], encoding='utf-8').read().splitlines()
            open(str(cmd[cmd.index('-o') + 1]), 'wb').write(b'lib')
        elif any(str(c).endswith('s1.metal') for c in cmd): P.returncode = 1; P.stderr = 'synthetic error'
        return P()
    with mock.patch.object(vs.subprocess, 'run', run2):
        lib, failed = vs.metallib(msls, os.path.join(t, 'out'), 'iphoneos', [], t)
    chk('一支编不过：失败表只有它', [msls[1]], sorted(failed))
    chk('一支编不过：其余两支照链（响应文件 2 行）', 2, len(rsp.get('airs') or []))
    chk('一支编不过：库照出', True, bool(lib) and os.path.isfile(lib))
# 审计 P1-176：两个目标各剔各的。翻译 / 逐目标编库都用替身：三支 A B C，Mac 目标编不过的支按场景给，iPhone 全编得过
#   期望（手写）：Mac 只 A 编不过 → Mac 表 B C、iPhone 表 A B C（原先 iPhone 也只剩 B C）、汇总「成功 3、失败 1」
#               Mac 三支全编不过 → Mac 只有表头且没有库、iPhone 表 A B C 且库在（原先 iPhone 库被删成表头）、汇总「成功 3、失败 3」
import contextlib, io
def main_run(mac_bad):
    with tempfile.TemporaryDirectory() as t:
        src = os.path.join(t, 'spv'); os.makedirs(src); mac, ios = os.path.join(t, 'mac'), os.path.join(t, 'ios')
        keys = ['a', 'b', 'c']
        def one(p, tmp, root): k = os.path.basename(p); return (k, 'vert', ['u:0.0=0'], [os.path.join(tmp, k + '.metal')], 'src/' + k)
        def metallib(msls, d, sdk, extra, tmp):
            bad = {m: 'synthetic error' for m in msls if sdk == 'macosx' and os.path.basename(m)[0] in mac_bad}
            if len(bad) == len(msls): return None, bad
            os.makedirs(d, exist_ok=True); lib = os.path.join(d, 'vk_shaders.metallib'); open(lib, 'wb').write(b'lib'); return lib, bad
        class R: stdout = 'r'; stderr = ''; returncode = 0
        out = io.StringIO()
        with mock.patch.object(vs, 'spirv_files', lambda r: [os.path.join(r, k) for k in keys]), mock.patch.object(vs, 'one', one), \
             mock.patch.object(vs, 'metallib', metallib), mock.patch.object(vs.subprocess, 'run', lambda *a, **k: R()), \
             mock.patch.object(sys, 'argv', ['vk_shaders.py', src, mac, '--ios', ios]), contextlib.redirect_stdout(out):
            vs.main()
        rows = lambda d: [l.split('\t')[0] for l in open(os.path.join(d, 'vk', 'vk_shaders.tsv'), encoding='utf-8').read().splitlines() if not l.startswith('#')]
        libs = lambda d: os.path.exists(os.path.join(d, 'vk', 'vk_shaders.metallib'))
        summ = [l for l in out.getvalue().splitlines() if l.startswith('Vulkan 汇总')]
        return rows(mac), libs(mac), rows(ios), libs(ios), summ
m, ml, i, il, summ = main_run('a')
chk('P1-176 Mac 只 A 编不过：Mac 表', ['b', 'c'], m)
chk('P1-176 Mac 只 A 编不过：iPhone 表仍有 A', ['a', 'b', 'c'], i)
chk('P1-176 Mac 只 A 编不过：汇总行', ['Vulkan 汇总：成功 3、失败 1'], summ)
m, ml, i, il, summ = main_run('abc')
chk('P1-176 Mac 全编不过：Mac 只有表头、没有库', ([], False), (m, ml))
chk('P1-176 Mac 全编不过：iPhone 表与库都在', (['a', 'b', 'c'], True), (i, il))
chk('P1-176 Mac 全编不过：汇总行', ['Vulkan 汇总：成功 3、失败 3'], summ)
print(f'{"✓" if not bad else "✗"} vk_shaders_rsp：{bad} 不通')
sys.exit(1 if bad else 0)
