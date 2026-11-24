#!/bin/bash
# 门禁覆盖：graphics/dsx/dsx_win.py translator/spvc_inproc.py tests/win_lib_repro_test.sh
# Windows 出包机编的直连翻译库 dsx.dll 与 spirv-cross 进程内库 libspvc_cli.dll 字节可复现（整文件哈希进翻译缓存键：graphics/tools/direct/dsh/batch/Build.cs
#   ToolFingerprint → ToolLib.Fp，PE 不拆节）。修前 lld-link 写链接时刻、导出表记「dsx.dll.<进程号>.tmp.dll」、assert 的 __FILE__ 带检出路径，
#   同一份源码每编一次字节不同：Windows 出包机按提交号各一份检出，每单全部着色器翻译缓存作废（shader cache: hit 0）。
#   bash tests/win_lib_repro_test.sh（①② 不用编译器、约 1 秒；③ 只在 Windows 上真编两份比字节，约 1 分钟）
# 期望（手写，不跑被测实现推）：
#   ① dsx_win.build：每条编译命令带 -fmacro-prefix-map=<仓库根>=.；链接命令带 -Wl,/Brepro，-o 的文件名就是 dsx.dll（不带进程号）；
#      完成后输出目录里只有 dsx.dll（.lib / .exp 与临时子目录都不留）
#   ② spvc_inproc._build：Windows 分支编译带 -fmacro-prefix-map=<仓库根>=.、链接带 -shared -Wl,/Brepro；Mac 分支命令里两者都没有、仍是 -dynamiclib；
#      FLAGS 仍是 -O2 -std=c++14 -fPIC（FLAGS 进输出身份，Mac 翻译键不动）
#   ③ （只 Windows）同一份源码拷到两个不同目录各编一次：两份 dsx.dll 逐字节相同、两份 libspvc_cli.dll 逐字节相同
# 负对照（手做）：dsx_win.py / spvc_inproc.py 换回修前版本 → ① ② 不通；Windows 出包机实测修前两目录各编一次 dsx / spvc 哈希都不同（差在文件头时间戳与宽字符检出路径）
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$H" <<'PY'
import os, shutil, subprocess, sys, tempfile, hashlib
H = sys.argv[1]; bad = 0
def chk(name, ok, got=''):
    global bad; bad += not ok; print(f'{"通" if ok else "不通"} {name}{"：" + str(got) if got != "" else ""}')
sys.path.insert(0, os.path.join(H, 'graphics/dsx')); sys.path.insert(0, os.path.join(H, 'translator'))
import dsx_win, spvc_inproc as S
PMAP = '-fmacro-prefix-map=' + H + '=.'

def fake_run(log):
    def run(cmd, *a, **k):
        log.append(list(cmd))
        o = cmd[cmd.index('-o') + 1]
        open(o, 'wb').close()
        if '-shared' in cmd:   # lld-link 顺带出的导入库
            for ext in ('.lib', '.exp'): open(os.path.splitext(o)[0] + ext, 'wb').close()
        return subprocess.CompletedProcess(cmd, 0)
    return run

# ① dsx_win.build
with tempfile.TemporaryDirectory() as T:
    out = os.path.join(T, 'win', 'dsx.dll'); log = []; real = subprocess.run
    subprocess.run = fake_run(log)
    try: rc = dsx_win.build(out)
    finally: subprocess.run = real
    comp = [c for c in log if '-c' in c]; link = [c for c in log if '-shared' in c]
    chk('① 编译命令都带 -fmacro-prefix-map=<仓库根>=.', rc == 0 and comp and all(PMAP in c for c in comp), f'{sum(PMAP in c for c in comp)}/{len(comp)} 条')
    lk = link[0] if len(link) == 1 else []
    chk('① 链接带 -Wl,/Brepro', '-Wl,/Brepro' in lk)
    chk('① 链接 -o 的文件名是 dsx.dll', bool(lk) and os.path.basename(lk[lk.index('-o') + 1]) == 'dsx.dll', os.path.basename(lk[lk.index('-o') + 1]) if lk else '没有链接命令')
    chk('① 输出目录只剩 dsx.dll', sorted(os.listdir(os.path.dirname(out))) == ['dsx.dll'], sorted(os.listdir(os.path.dirname(out))))

# ② spvc_inproc._build（两个分支）
class P:
    def __init__(self, cmd, *a, **k): open(cmd[cmd.index('-o') + 1], 'wb').close(); log.append(list(cmd))
    def wait(self): return 0
for win in (True, False):
    with tempfile.TemporaryDirectory() as T:
        log = []; real_run, real_popen, real_win, real_cxx = subprocess.run, subprocess.Popen, S.WIN, S._cxx
        subprocess.run, subprocess.Popen, S.WIN, S._cxx = fake_run(log), P, win, (lambda: ['clang++'])
        try: S._build(os.path.join(T, S.LIB))
        finally: subprocess.run, subprocess.Popen, S.WIN, S._cxx = real_run, real_popen, real_win, real_cxx
        comp = [c for c in log if '-c' in c]; link = [c for c in log if '-c' not in c]
        lk = link[0] if len(link) == 1 else []
        if win:
            chk('② Windows：编译都带 -fmacro-prefix-map=<仓库根>=.', comp and all(PMAP in c for c in comp), f'{sum(PMAP in c for c in comp)}/{len(comp)} 条')
            chk('② Windows：链接带 -shared -Wl,/Brepro', '-shared' in lk and '-Wl,/Brepro' in lk)
        else:
            chk('② Mac：编译没有 -fmacro-prefix-map', comp and not any(PMAP in c for c in comp))
            chk('② Mac：链接 -dynamiclib、没有 /Brepro', '-dynamiclib' in lk and '-Wl,/Brepro' not in lk)
chk('② FLAGS 不变（输出身份 / Mac 翻译键不动）', S.FLAGS == ['-O2', '-std=c++14', '-fPIC'], S.FLAGS)

# ③ 只 Windows：两份目录真编
if sys.platform == 'win32':
    def sha(p): return hashlib.sha256(open(p, 'rb').read()).hexdigest()
    with tempfile.TemporaryDirectory() as T:
        got = {}
        for d in ('a', 'bb'):
            r = os.path.join(T, d)
            for sub in ('graphics/dsx', 'graphics/third_party/spirv_cross', 'translator/spvc_cli'):
                shutil.copytree(os.path.join(H, sub), os.path.join(r, sub), ignore=shutil.ignore_patterns('build'))
            for f in ('spvc_inproc.py', 'xlock.py'): shutil.copy2(os.path.join(H, 'translator', f), os.path.join(r, 'translator', f))
            o = os.path.join(r, 'out', 'dsx.dll')
            subprocess.run([sys.executable, os.path.join(r, 'graphics/dsx/dsx_win.py'), o], check=True)
            lp = subprocess.run([sys.executable, '-c', 'import spvc_inproc; print(spvc_inproc.lib_path())'], cwd=os.path.join(r, 'translator'),
                                capture_output=True, text=True, check=True, env=dict(os.environ, S2A_PREBUILT_TOOLS='')).stdout.strip()
            got[d] = (sha(o), sha(lp))
        chk('③ 两目录各编一次 dsx.dll 逐字节相同', got['a'][0] == got['bb'][0], (got['a'][0][:12], got['bb'][0][:12]))
        chk('③ 两目录各编一次 libspvc_cli.dll 逐字节相同', got['a'][1] == got['bb'][1], (got['a'][1][:12], got['bb'][1][:12]))
else: print('跳过 ③（只在 Windows 上真编）')
print(f'{"✓" if not bad else "✗"} win_lib_repro：{bad} 不通')
sys.exit(1 if bad else 0)
PY
