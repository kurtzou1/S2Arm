#!/bin/bash
# 门禁覆盖：translator/dmsh_chain.py graphics/tools/direct/direct_lib.py tests/dmsh_chain_own_compilers_test.sh
# 直连整份出库前核工具（dmsh_chain.py --build-env → own_compilers）：Xcode 与锁不同的机器照常出包（11-02 合入线对照 #1：C# 迁移删了 own_compilers.py 后每款出库前退出）。约 1 秒：bash tests/dmsh_chain_own_compilers_test.sh
#   期望（手写）：只有 metal_macosx / metal_iphoneos 版本不同 → 全放行、照停为空；编译器缺失（actual missing）→ 照停；spirv-cross / 翻译器 dll / 翻译器源码不符 → 照停；混合时各归各
#   不同编译器编的库不会被复用由 graphics/tools/direct/tests/t_unity.py ⑦ 实测（假 xcrun 报另一版本 → 新编、换回 → 命中）
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
cd "$H/translator" && exec python3 - <<'PY'
import dmsh_chain
import os, subprocess, sys, tempfile
from pathlib import Path
M = 'metal_macosx: lock Apple metal version 32023.921 (metalfe-32023.921.6) / actual Apple metal version 32023.883 (metalfe-32023.883)'
I = 'metal_iphoneos: lock Apple metal version 32023.921 (metalfe-32023.921.6) / actual Apple metal version 32100.1 (metalfe-32100.1)'
MISS = 'metal_iphoneos: lock Apple metal version 32023.921 (metalfe-32023.921.6) / actual missing'
SC = 'spirv-cross: lock 1.4.363.0 / actual 1.4.400.0'; DLL = 'dmsh_xlate.dll: lock 047a08dc50dca83f / actual 0000000000000000'
SRC = 'the translator was not built from the in-repo source: embedded source a / in repo b (rebuild dmsh_xlate_bin)'
bad = checks = 0
def ck(name, got, want):
    global bad, checks
    checks += 1
    ok = got == want; bad += not ok; print(('✓ ' if ok else '✗ ') + name + ('' if ok else f'：期望 {want}，实际 {got}'))
ck('两个 Metal 编译器版本都不同 → 全放行', dmsh_chain.own_compilers([M, I]), ([M, I], []))
ck('Metal 编译器缺失 → 照停', dmsh_chain.own_compilers([MISS]), ([], [MISS]))
# D-TYCN：读不到版本的原因写在括号里，同样是缺失、照停（不能被当成「版本不同」放行）
MB = 'metal_macosx: lock Apple metal version 32023.921 (metalfe-32023.921.6) / actual missing (start blocked: [WinError 5] Access is denied)'
MN = 'metal_iphoneos: lock Apple metal version 32023.921 (metalfe-32023.921.6) / actual missing (no version output: exit code 0xc0000135)'
ck('Metal 编译器起不来 / 没打版本 → 照停', dmsh_chain.own_compilers([MB, MN]), ([], [MB, MN]))
ck('spirv-cross 不符 → 照停', dmsh_chain.own_compilers([SC]), ([], [SC]))
ck('翻译器 dll / 源码不符 → 照停', dmsh_chain.own_compilers([DLL, SRC]), ([], [DLL, SRC]))
ck('混合：Metal 放行、其余照停', dmsh_chain.own_compilers([M, SC, MISS]), ([M], [SC, MISS]))
ck('全符 → 都空', dmsh_chain.own_compilers([]), ([], []))
# 真跑 direct_lib.py 的生产取值 / 校验函数 build_env；工具边界只提供合成 stdout、stderr 与退出码。
root = Path(dmsh_chain.HERE).parent
expected = 'c7a4970bffe5\t0100ABCD00000000\tsynthetic-inputs'
note = "note: built with this Mac's compilers\ncompiler versions differ"
fatal = '[RED] translation chain tools do not match the lock file: synthetic translator'
sys.path.insert(0, str(root / 'graphics/tools/direct'))
import contextlib, io, direct_lib
with tempfile.TemporaryDirectory(prefix='s2a-chain-env-') as tmp:
    base = Path(tmp); repo = base / 'repo with spaces'; tools = repo / 'translator'
    tools.mkdir(parents=True)
    (tools / 'dmsh_chain.py').write_text(
        "import os, sys\n"
        "mode = os.environ['CHAIN_TEST_MODE']\n"
        "if mode in ('note', 'mismatch'): print(os.environ['CHAIN_TEST_NOTE'], file=sys.stderr)\n"
        "row = os.environ['CHAIN_TEST_ROW']\n"
        "if mode == 'mismatch': row = '000000000000' + row[12:]\n"
        "print(row, end='\\r\\n' if mode == 'crlf' else '\\n')\n"
        "if mode == 'error': print(os.environ['CHAIN_TEST_ERROR'], file=sys.stderr); sys.exit(7)\n")
    for mode in ('normal', 'note', 'error', 'mismatch', 'crlf'):   # crlf：Windows 原生程序按 CRLF 写标准输出，取值不能带 CR
        work = base / mode; work.mkdir()
        os.environ.update(CHAIN_TEST_MODE=mode, CHAIN_TEST_NOTE=note, CHAIN_TEST_ROW=expected, CHAIN_TEST_ERROR=fatal)
        out, err = io.StringIO(), io.StringIO(); rc = 0; got = None
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try: got = direct_lib.build_env(sys.executable, str(tools), str(work), 'c7a4970bffe5')
            except direct_lib.Exit as e: rc = e.code
        out, err = out.getvalue(), err.getvalue()
        if got: out += 'accepted\t' + '\t'.join(got) + '\n'
        ck(f'生产接线 {mode}：退出码', rc, 0 if mode in ('normal', 'note', 'crlf') else 1)
        if mode in ('normal', 'note', 'crlf'):
            ck(f'生产接线 {mode}：三个字段保持原样', out.strip(), 'accepted\t' + expected)
        if mode in ('note', 'mismatch'):
            ck(f'生产接线 {mode}：提示保留在诊断输出', note in err, True)
        if mode == 'error':
            ck('工具退出非零：保留错误、拒绝其 stdout 中看似有效的结果', fatal in out + err and 'accepted\t' not in out, True)
        if mode == 'mismatch':
            ck('真实链号不符仍拒绝', '链号前后不一（c7a4970bffe5 / 000000000000）' in out, True)
# 取子进程标准输出（同 $(…)）：Windows 原生程序写 CRLF，取到的路径不能带 CR（11-20 Windows 实跑：game.py dir 的路径带 CR，报「配置档缺 game.tsv」）
ck('取值去掉 CRLF 的 CR', direct_lib.run([sys.executable, '-c', "import sys; sys.stdout.buffer.write(b'D:/p/0100\\r\\n')"], capture=True), (0, 'D:/p/0100'))
print(f'dmsh_chain_own_compilers：{checks} 项，失败 {bad}'); raise SystemExit(1 if bad else 0)
PY
