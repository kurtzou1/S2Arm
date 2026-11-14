#!/usr/bin/env python3
# 只能 Linux（-Wl,--wrap 要 GNU ld；host_android.c 用 eventfd），需 NDK 29 的 android/log.h。
"""安卓主 guest 运行态发布（#961）：真实 HostApi / stop owner + Android runtime + 共用 guest_main /
session / direct_prompt；managed 服务、fault、SDK、存档服务出口为合成端点，不代表设备验收。

--source-root 指向另一棵树（例如修前 main）时，用它的生产源码配本树夹具，得到修前红。
不带 --source-root 时另跑负对照：逐个回退修复里的一处，指定用例必须重新变红。
"""
import argparse
import json
import pathlib
import shutil
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--out', type=pathlib.Path, required=True)
p.add_argument('--ndk-include', type=pathlib.Path, required=True)
p.add_argument('--source-root', type=pathlib.Path)
p.add_argument('--cc', default='cc')
a = p.parse_args()
here = pathlib.Path(__file__).resolve().parent
root = (a.source_root or here.parents[2]).resolve()
out = a.out.resolve()
if out.exists():
    shutil.rmtree(out)
out.mkdir(parents=True)

CASES = ['startup', 'safe', 'child-admission', 'already-running', 'stop-after-publish',
         'stop-before-publish', 'session-failed', 'attach-fail', 'track-fail']
RED_LINE = '【红】共用会话运行态没发布'
flags = [a.cc, '-D_GNU_SOURCE', '-D__ANDROID__', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
         '-pthread', '-ffunction-sections', '-fdata-sections']
for d in ['runtime/include', 'runtime/src', 'android/native', 'android/native/runtime']:
    flags += ['-I', str(root / d)]
flags += ['-idirafter', str(a.ndk_include)]
SOURCES = ['android/native/runtime/runtime.c', 'runtime/src/guest_main.c', 'runtime/src/session.c',
           'runtime/src/direct_prompt.c']
SOURCES += [f'android/native/{n}.c' for n in ['host_android', 'hostapi', 'input', 'wsi_lease', 'host_ui', 'host_ui_android']]
SOURCES += [f'android/native/direct/{n}.c' for n in ['selection', 'attempt', 'graphics', 'json', 'sha256', 's2a_direct_abi']]

# 负对照：(名字, 文件, 原文, 回退后, 必须变红的用例)
MUTANTS = [
    ('no-publish', 'runtime/src/guest_main.c',
     '    int publish_error = s2a_android_runtime_publish_running();\n',
     '    int publish_error = 0;\n', 'startup'),
    ('stop-ignored', 'android/native/host_android.c',
     '    int rc = g.stop_requested ? 1 : publish();\n',
     '    int rc = publish();\n', 'stop-before-publish'),
    ('failed-continues', 'android/native/runtime/runtime.c',
     '    if (state == S2A_SESSION_FAILED) return failed(S2A_RUNTIME_SERVICES, 0, "session failed before RUNNING publication");\n'
     '    if (s2a_session_stop_requested()) return failed(S2A_RUNTIME_STOP, 0, "session exiting before RUNNING publication");\n',
     '', 'session-failed'),
    ('mismatch-stops', 'android/native/runtime/runtime.c',
     '    if (!rc) return 0;\n',
     '    if (!rc) return 0;\n    if (rc) return failed(S2A_RUNTIME_STOP, 0, "mutant");\n', 'already-running'),
    ('publish-in-admission', 'android/native/runtime/runtime.c',
     '    if (stop_requested()) return failed(S2A_RUNTIME_STOP, 0, "stop after guest thread self-probe");\n    return 0;\n',
     '    if (stop_requested()) return failed(S2A_RUNTIME_STOP, 0, "stop after guest thread self-probe");\n'
     '    return s2a_android_runtime_publish_running();\n', 'child-admission'),
]


def build(label, replace=None):
    work = out / label
    work.mkdir()
    objects = []
    for i, rel in enumerate(SOURCES):
        source = root / rel
        if replace and replace[0] == rel:
            text = source.read_text()
            if text.count(replace[1]) != 1:
                raise SystemExit(f'mutant {label}: {rel} 原文出现 {text.count(replace[1])} 次，必须恰好 1 次')
            source = work / pathlib.Path(rel).name
            source.write_text(text.replace(replace[1], replace[2]))
        obj = work / f'{i}.o'
        # host_ui_android 的 Android 分支依赖 JNI；这里只要它的 host UI 表。
        extra = ['-U__ANDROID__'] if rel.endswith('host_ui_android.c') else []
        subprocess.run(flags + extra + ['-c', str(source), '-o', str(obj)], check=True)
        objects.append(str(obj))
    fixture = work / 'fixture.o'
    subprocess.run(flags + ['-c', str(here / 'save_running_test.c'), '-o', str(fixture)], check=True)
    exe = work / 'save-running'
    subprocess.run(flags + ['-Wl,--gc-sections', '-Wl,--wrap=pthread_create', '-Wl,--wrap=_exit',
                            *objects, str(fixture), '-ldl', '-o', str(exe)], check=True)
    return exe


def run(exe, case):
    env = {'PATH': '/usr/bin:/bin', 'S2A_CRASH_QUIET': '1'}
    r = subprocess.run([str(exe), case], text=True, capture_output=True, timeout=10, env=env)
    red = RED_LINE in r.stderr
    ok = r.returncode == 0 and red == (case == 'already-running')
    return dict(case=case, passed=ok, rc=r.returncode, red_line=red, stdout=r.stdout, stderr=r.stderr)


results = []
exe = build('candidate')
for case in CASES:
    r = run(exe, case)
    results.append(dict(label='candidate', **r))
    print('candidate', case, 'PASS' if r['passed'] else 'FAIL', r['stdout'].strip(), flush=True)
controls_ok = True
if not a.source_root:
    for name, rel, old, new, target in MUTANTS:
        r = run(build(f'mutant-{name}', (rel, old, new)), target)
        results.append(dict(label=f'mutant-{name}', **r))
        print(f'mutant-{name}', target, 'RED' if not r['passed'] else 'NOT-RED', r['stdout'].strip(), flush=True)
        controls_ok &= not r['passed']
(out / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
candidate_ok = all(r['passed'] for r in results if r['label'] == 'candidate')
controls = 'skipped (--source-root)' if a.source_root else 'all red' if controls_ok else 'NOT all red'
print(f'candidate {sum(r["passed"] for r in results if r["label"] == "candidate")}/{len(CASES)} PASS; '
      f'negative controls {controls}', flush=True)
raise SystemExit(0 if candidate_ok and controls_ok else 1)
