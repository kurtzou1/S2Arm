#!/usr/bin/env python3
"""计算取库的原因码（enum s2a_libpack_why）：正例跑 libpack_vk_test；改坏 libpack_vk.c 的原因码各一处，libpack_vk_test 必红在对应断言。
改坏的是码，不是文本——诊断（nvk_shader.c）按码分类，这里锁的就是码。"""
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
out = root / 'build/libpack-reason-code'
out.mkdir(parents=True, exist_ok=True)
native = root / 'android/native'
source = (native / 'direct/libpack_vk.c').read_text()
flags = ['-std=c11', '-D_GNU_SOURCE', '-Wall', '-Wextra', '-Werror']
includes = [native, native/'direct', native/'nvn', root/'runtime/include']


def run(name, text=None):
    lib = native / 'direct/libpack_vk.c'
    if text is not None:
        lib = out / (name + '.c')
        lib.write_text(text)
    exe = out / name
    sources = [root/'android/tests/libpack_vk_test.c', lib, native/'direct/json.c', native/'direct/jv.c', native/'nvn/nvn_vk_program_result.c']
    subprocess.run([os.environ.get('CC', 'cc'), *flags, *('-I'+str(p) for p in includes), *(str(p) for p in sources), '-o', str(exe)], check=True)
    env = os.environ.copy()
    env['TMPDIR'] = str(out)
    return subprocess.run([str(exe)], capture_output=True, text=True, env=env)


good = run('good')
if good.returncode != 0 or 'libpack_vk_test: all checks passed' not in good.stdout:
    sys.exit(f'libpack_vk_test failed on the unmodified source rc={good.returncode}\n{good.stdout}\n{good.stderr}')
print('PASS: libpack_vk_test (reason codes: hit / miss NONE, spill SHARED_LIMIT even without text, capability + descriptor-contract REFLECT, unmappable OTHER)')

mutants = (
    ('shared-limit-as-other', 'lp_fail_code(S2A_LIBPACK_WHY_SHARED_LIMIT, why, why_size, "%s %s compute shared memory',
     'lp_fail_code(S2A_LIBPACK_WHY_OTHER, why, why_size, "%s %s compute shared memory', 'FAIL: spill WG>limit → reason code SHARED_LIMIT'),
    ('capability-reject-as-other', 'lp_fail_reflect(why, why_size, "%s: uses %s, which the Vulkan device does not enable",',
     'lp_fail(why, why_size, "%s: uses %s, which the Vulkan device does not enable",', 'FAIL: SPIR-V capability refusal → reason REFLECT'),
    ('support-ownership-as-other', 'return lp_fail_reflect(why, why_size, "%s %s binding %u is owned by support_buffer",',
     'return lp_fail(why, why_size, "%s %s binding %u is owned by support_buffer",', 'FAIL: descriptor-contract refusal (support binding ownership) → reason REFLECT'),
    ('default-reject-as-reflect', '#define lp_fail(why, why_size, ...) lp_fail_code(S2A_LIBPACK_WHY_OTHER, why, why_size, __VA_ARGS__)',
     '#define lp_fail(why, why_size, ...) lp_fail_code(S2A_LIBPACK_WHY_REFLECT, why, why_size, __VA_ARGS__)', 'FAIL: unmappable binding kind → reason OTHER'),
    ('code-not-reset-per-call', '    struct s2a_libpack *lp = (struct s2a_libpack *)lp_c;\n    g_lp_why = S2A_LIBPACK_WHY_NONE;\n    if (reason) *reason = S2A_LIBPACK_WHY_NONE;',
     '    struct s2a_libpack *lp = (struct s2a_libpack *)lp_c;\n    if (reason) *reason = S2A_LIBPACK_WHY_NONE;', 'FAIL: unmappable binding kind → reason OTHER'),
    ('reason-set-on-hit', 'if (reason && rc == S2A_LIBPACK_REJECT) *reason = g_lp_why ? g_lp_why : S2A_LIBPACK_WHY_OTHER;',
     'if (reason) *reason = g_lp_why ? g_lp_why : S2A_LIBPACK_WHY_OTHER;', 'FAIL: hit carries reason NONE'),
    ('reason-not-written', 'if (reason && rc == S2A_LIBPACK_REJECT) *reason = g_lp_why ? g_lp_why : S2A_LIBPACK_WHY_OTHER;',
     '(void)g_lp_why;', 'FAIL: spill WG>limit → reason code SHARED_LIMIT'),
)
for name, old, new, expected in mutants:
    assert source.count(old) == 1, (name, 'mutation anchor', source.count(old))
    result = run(name, source.replace(old, new))
    if result.returncode == 0 or expected not in result.stdout:
        sys.exit(f'{name}: wrong negative control outcome rc={result.returncode}\n{result.stdout}\n{result.stderr}')
    print(f'{name}: expected assertion failure: {expected}', flush=True)
print(f'PASS: {len(mutants)} reason-code negative controls')
