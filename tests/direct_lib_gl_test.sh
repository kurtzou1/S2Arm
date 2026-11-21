#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：graphics/tools/direct/direct_lib.py translator/gl_shaders.py tests/direct_lib_gl_test.sh
# 真跑纯 GL 入口，混合 GL 生产分支直接调 direct_lib.Lib.gl_also（NVN 出库那段依赖平台编译器、不跑）；工具边界是合成工具和空格路径。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$H" <<'PY'
import os, pathlib, shutil, subprocess, sys, tempfile

repo = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='direct gl ') as td:
    t = pathlib.Path(td); fake = t / 'repo'; bindir = t / 'bin'; bindir.mkdir()
    for name in ('bash', 'uname', 'dirname', 'mkdir', 'rm', 'sed', 'tail', 'grep', 'tr'):
        os.symlink(shutil.which(name), bindir / name)
    for d in ('graphics/tools/direct', 'graphics/nvn/tools', 'pack', 'tools', 'translator'):
        (fake / d).mkdir(parents=True, exist_ok=True)
    shutil.copy(repo / 'graphics/tools/direct/direct_lib.py', fake / 'graphics/tools/direct/direct_lib.py')
    shutil.copy(repo / 'tools/progress.py', fake / 'tools/progress.py'); shutil.copy(repo / 'tools/pool_workers.py', fake / 'tools/pool_workers.py')
    (fake / 'graphics/nvn/tools/gfx_api.py').write_text('import sys\nprint("1\\tstub" if "--gl-also" in sys.argv else "gl\\tstub")\n')
    # 调用真 gl_shaders.translate 的预处理命令选择；后续翻译由桩终止并写合成表头。
    (fake / 'translator/gl_shaders.py').write_text('''import os, pathlib, subprocess, sys
sys.path.insert(0, str(pathlib.Path(os.environ["REAL_REPO"]) / "translator"))
import gl_shaders
class StopAfterFirstCommand(Exception): pass
gl_shaders.es = lambda args, src: src
def run(command):
    subprocess.run([str(x) for x in command], check=True)
    raise StopAfterFirstCommand
gl_shaders.run = run
out = pathlib.Path(sys.argv[sys.argv.index("--ios") + 1]) / "gl"
out.mkdir(parents=True, exist_ok=True)
try: gl_shaders.translate(b"synthetic", "vert", "key", out)
except StopAfterFirstCommand: pass
else: raise AssertionError("translator command was not invoked")
(out / "gl_shaders.tsv").write_text("# synthetic header\\n")
print("GLSL 汇总：成功 0、失败 0")
''')
    (fake / 'tools/nostall.py').write_text('import os, sys\na=sys.argv[sys.argv.index("--")+1:]; os.execv(a[0], a)\n')
    root = t / 'game'; (root / 'romfs').mkdir(parents=True); (root / 'exefs').mkdir(); (root / 'exefs/main').write_text('synthetic'); (root / 'unpack.tsv').write_text('title_id\t0100000000000000\n')
    log = t / 'invocations'
    def tool(path, label, executable=True):
        path.write_text('#!/bin/bash\necho ' + label + ' >> "$CALL_LOG"\n')
        path.chmod(0o755 if executable else 0o644)
    explicit = t / 'tool with spaces'; tool(explicit, 'explicit')
    named = bindir / 'custom-validator'; tool(named, 'named')
    fallback = bindir / 'glslangValidator'; tool(fallback, 'fallback')
    cross = bindir / 'spirv-cross'; tool(cross, 'cross')
    invalid = t / 'not executable'; tool(invalid, 'invalid', False)
    # 空值与未设置不同：Python os.environ.get 只在未设置时回退。
    cases = [('explicit space', str(explicit), False, True, 'explicit'),
             ('explicit name', 'custom-validator', False, True, 'named'),
             ('unset fallback', None, True, True, 'fallback'),
             ('missing explicit with fallback', str(t/'missing'), True, True, None),
             ('empty explicit with fallback', '', True, True, None),
             ('non-executable with fallback', str(invalid), True, True, None),
             ('shell builtin with fallback', ':', True, True, None),
             ('unset missing fallback', None, False, True, None),
             ('missing spirv-cross', str(explicit), True, False, None)]
    failures = []
    for name, value, has_fallback, has_cross, expected in cases:
        if not has_fallback: fallback.rename(bindir / 'disabled-validator')
        if not has_cross: cross.rename(bindir / 'disabled-cross')
        for mode in ('pure', 'mixed'):
            if log.exists(): log.unlink()
            env = dict(os.environ, PATH=str(bindir), S2A_PY=sys.executable, S2A_DIRECT_CACHE=str(t/'cache'), CALL_LOG=str(log), REAL_REPO=os.environ.get('REAL_GL_REPO', str(repo)), J='1')
            env.pop('GLSLANG', None)
            if value is not None: env['GLSLANG'] = value
            out = t / ('out-' + mode); work = t / 'work'; out.mkdir(exist_ok=True); work.mkdir(exist_ok=True)
            if mode == 'pure':
                cmd = [sys.executable, str(fake/'graphics/tools/direct/direct_lib.py'), str(root), str(out)]
            else:
                code = '''import sys
sys.path.insert(0, sys.argv[1])
import direct_lib
lib = direct_lib.Lib(sys.argv[2:4]); lib.C, lib.W, lib.OS = sys.argv[4], sys.argv[5], sys.argv[3]
print(lib.gl_also()[0])
'''
                cmd = [sys.executable, '-c', code, str(fake/'graphics/tools/direct'), str(root), str(out), str(t/'cache'), str(work)]
            p = subprocess.run(cmd, env=env, text=True, capture_output=True)
            calls = log.read_text().splitlines() if log.exists() else []
            good = (p.returncode == 0 and calls == [expected] and ('离线 0 支' in p.stdout)) if expected else (
                not calls and (p.returncode == 1 and 'OpenGL 款要' in p.stdout if mode == 'pure' else p.returncode == 0 and '缺 glslangValidator / spirv-cross' in p.stdout))
            if not good: failures.append(f'{mode} {name}: rc={p.returncode}, calls={calls}, stdout={p.stdout!r}, stderr={p.stderr!r}')
            print(('PASS' if good else 'FAIL') + f' {mode} {name}: rc={p.returncode}, calls={calls}')
        if not has_fallback: (bindir/'disabled-validator').rename(fallback)
        if not has_cross: (bindir/'disabled-cross').rename(cross)
    if failures:
        print('\n'.join(failures), file=sys.stderr); sys.exit(1)
    print(f'✓ direct_lib_gl: {len(cases)*2} cases')
PY
