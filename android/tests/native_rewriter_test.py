#!/usr/bin/env python3
"""Real JDK17 host JNI checks using pinned offline C dependencies, no game data/network.

This is host JVM evidence. Android APK/App UID and device checks are separate.
S2A_JNI_EVIDENCE retains the command logs, fixtures and comparison fingerprints.
"""
import importlib.util
import json
import os
from pathlib import Path
import hashlib
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('android_gate_rewriter', ROOT / 'pack/rewriter.py')
rewriter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rewriter)


def run(base):
    # Direct callers also use the production resolver, without requiring an env
    # override. Resolve before JDK/build work and keep only this boundary terse.
    try:
        deps = rewriter.dependency_dir()
    except (ValueError, OSError) as error:
        # The shared CLI's optional Python fallback does not apply to JNI.
        diagnostic = ' '.join(str(error).split('显式改用 Python：', 1)[0].splitlines()).strip()
        print('【红】JNI 门禁 C 固定源码（Capstone/LZ4）：' + diagnostic, file=sys.stderr)
        raise SystemExit(1)
    commands = []

    def command(argv, env=None, expected=0):
        result = subprocess.run([str(x) for x in argv], env=env, capture_output=True, text=True, timeout=180)
        index = len(commands)
        (base / f'{index:02}.stdout.log').write_text(result.stdout)
        (base / f'{index:02}.stderr.log').write_text(result.stderr)
        commands.append(dict(argv=[str(x) for x in argv], returncode=result.returncode))
        (base / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        if result.returncode != expected:
            raise RuntimeError(f'command {index} failed: {result.stdout}\n{result.stderr}')
        return result

    jdk = Path(os.environ['JAVA_HOME'])
    version = command([jdk / 'bin/javac', '-version'])
    if '17.' not in version.stdout + version.stderr:
        raise RuntimeError('JDK17 is required')
    build = base / 'build'
    command(['cmake', '-S', ROOT / 'android/rewriter', '-B', build,
             '-DS2A_REWRITER_DEPS=' + str(deps), '-DCMAKE_BUILD_TYPE=Release'])
    command(['cmake', '--build', build, '--target', 's2arm_rewriter', 's2a-rewrite', '--parallel', '2'])
    fixture = base / '私有输入😀'; fixture.mkdir(mode=0o700)
    command([sys.executable, ROOT / 'android/tools/selftest_nso.py', fixture / 'main.nso'])
    data = bytearray((fixture / 'main.nso').read_bytes())
    struct.pack_into('<I', data, 0x34, 0x4000)  # legitimate non-shared-page fixture, no producer substitution
    struct.pack_into('<4I', data, 0x230, 0x5280a003, 0xd65f03c0, 0x52800028, 0xd65f03c0)
    struct.pack_into('<I', data, 0x1324, 0x40)
    (fixture / 'main.nso').write_bytes(data)
    import lz4.block
    header, payload = bytearray(data[:0x100]), bytearray()
    struct.pack_into('<I', header, 12, 7)
    for index in range(3):
        offset, _, size = struct.unpack_from('<III', data, 0x10 + 16 * index)
        block = lz4.block.compress(bytes(data[offset:offset + size]), store_size=False)
        struct.pack_into('<I', header, 0x10 + 16 * index, 0x100 + len(payload))
        struct.pack_into('<I', header, 0x60 + 4 * index, len(block))
        payload += block
    (fixture / 'compressed.nso').write_bytes(header + payload)
    (fixture / 'widen.tsv').write_text('main\t0x130\tmovz\r\n')
    (fixture / 'fps.tsv').write_text('c main 0x138 word 52800028 52800048\n')
    (fixture / 'bad.nso').write_bytes(b'not NSO')
    gap = bytearray(data); struct.pack_into('<I', gap, 0x200, 0xd4000022)   # hvc #1：异常类缺口（hlt 已同 brk 放行，不能再当缺口样本）
    (fixture / 'gap.nso').write_bytes(gap)
    def code_fixture(name, words):
        raw = bytearray(data)
        raw[0x100:0x1100] = bytes(0x1000)
        struct.pack_into('<II', raw, 0x100, 0x14000040, 0x1000)
        struct.pack_into('<' + 'I' * len(words), raw, 0x200, *words)
        struct.pack_into('<I', raw, 0x1324, 4 * len(words))
        (fixture / name).write_bytes(raw)
    # AArch64 SDK constructor shape: movz w8,#0x3fe0,lsl16;
    # add x9,x1,x8; str x9,[x0,#0x28]; mov w2,#0x30;
    # movz w10,#0x3fe0,lsl16; ret. No platform assembler is required.
    code_fixture('sdk.nso', [0x52a7fc08, 0x8b080029, 0xf9001409,
                             0x52800602, 0x52a7fc0a, 0xd65f03c0])
    code_fixture('spin.nso', [0xb9400008, 0x34ffffe8, 0xd65f03c0])

    def window_fixture(name, sp_word):
        """2 段 / 9 条的 LL/SC 自旋窗口（与塞尔达 main 0x65c2dc 同构），第二段里一条触 SP 的指令。

        0x100 ldxr w8,[x22] / 0x104 cmp w8,#1 / 0x108 b.ne 0x114 / 0x10c stxr w9,w8,[x22] /
        0x110 cbz w9,0x120 / 0x114 ldxr w8,[x22] / 0x118 <sp 指令> / 0x11c b.ne 0x10c / 0x120 ret
        """
        code_fixture(name, [0x885f7ec8, 0x7100051f, 0x54000061, 0x88097ec8, 0x34000089,
                            0x885f7ec8, sp_word, 0x54ffff81, 0xd65f03c0])
    window_fixture('window-sp.nso', 0xf9407bf2)         # ldr x18,[sp,#0xf0]：unsigned offset、dlt=0，应抬帧放行
    window_fixture('window-sp-reject.nso', 0xf84087f2)  # ldr x18,[sp],#8：写回、SP 动了，应准确记缺口
    classes = base / 'classes'; headers = base / 'headers'
    command([jdk / 'bin/javac', '-encoding', 'UTF-8', '-h', headers, '-d', classes,
             ROOT / 'android/app/src/main/java/org/s2arm/android/NativeRewriter.java',
             ROOT / 'android/tests/NativeRewriterTest.java',
             ROOT / 'android/tests/NativeRewriterRawTest.java'])
    # The surrounding gate may need LC_ALL=C for its sort-based tests. JDK17
    # ProcessBuilder uses the VM's default/native encoding for Unicode argv;
    # select an actually installed UTF-8 locale only for these child processes.
    available = command(['locale', '-a']).stdout.splitlines()
    utf8_locale = next((actual for preferred in ('c.utf8', 'en_us.utf8')
                        for actual in available if actual.lower().replace('-', '') == preferred), None)
    if utf8_locale is None:
        raise RuntimeError('JNI Unicode-path tests require an installed C.UTF-8 or en_US.UTF-8 locale')
    (base / 'java-runtime.json').write_text(json.dumps(dict(
        inherited_locale=os.environ.get('LC_ALL'), child_locale=utf8_locale), indent=2) + '\n')
    env = dict(os.environ, LC_ALL=utf8_locale, LANG=utf8_locale, S2A_TARGET='apple',
               S2A_REWRITE_SPIN='1', S2A_SDK_ADDR_CUT='0', S2A_FPS_TSV='/absent-ambient-fps-table')
    cases = {
        'normal-first': ('main', False, True, False, False, 0),
        'bad': ('bad', False, True, False, False, 1),
        'normal-after-bad': ('main', False, True, False, False, 0),
        'gap': ('gap', False, True, False, False, 3),
        'normal-after-gap': ('main', False, True, False, False, 0),
        'tables': ('main', True, True, True, True, 0),
        'no-cut': ('main', False, False, True, True, 0),
        'widen-only': ('main', False, True, True, False, 0),
        'fps-only': ('main', False, True, False, True, 0),
        'spin-off': ('spin', False, True, False, False, 0),
        'spin-on': ('spin', True, True, False, False, 0),
        'cut-on': ('sdk', False, True, False, False, 0),
        'cut-off': ('sdk', False, False, False, False, 0),
        'normal-after-invalid': ('main', False, True, False, False, 0),
        'concurrent-tables': ('main', True, True, True, True, 0),
        'concurrent-plain': ('main', False, True, False, False, 0),
    }
    raw_root = base / 'raw-cases'; raw_root.mkdir(mode=0o700)
    for case in list(cases) + ['bad-log']:
        directory = raw_root / case; directory.mkdir(mode=0o700)
        (directory / 'out').mkdir(mode=0o700)
        if case == 'bad-log':
            (directory / 'log').mkdir(mode=0o700)
        else:
            (directory / 'log').touch(mode=0o600)
    raw = command([jdk / 'bin/java', '-Xcheck:jni', '-Djava.library.path=' + str(build), '-cp', classes,
                   'org.s2arm.android.NativeRewriterRawTest', fixture, raw_root], env)
    if 'Warning:' in raw.stdout + raw.stderr or 'WARNING' in raw.stdout + raw.stderr:
        raise RuntimeError('raw JNI CheckJNI control emitted warnings; see retained logs')
    statuses = {fields[1]: int(fields[2]) for line in raw.stdout.splitlines()
                if len(fields := line.split('\t')) == 3 and fields[0] == 'CASE'}
    if statuses != {**{name: values[-1] for name, values in cases.items()}, 'bad-log': 1}:
        raise RuntimeError('raw JNI statuses differ: ' + str(statuses))
    comparisons = {}
    for name, (source, spin, cut, wide, fps, status) in cases.items():
        actual = {p.name: p.read_bytes() for p in (raw_root / name / 'out').iterdir()}
        if status == 1:
            if 'main.patched.bin' in actual:
                raise RuntimeError('failed raw call emitted an image: ' + name)
            continue
        expected = base / ('raw-expected-' + name); expected.mkdir(mode=0o700)
        cli_env = dict(env, S2A_TARGET='android', S2A_REWRITE_SPIN=str(int(spin)), S2A_SDK_ADDR_CUT=str(int(cut)))
        cli_env.pop('S2A_FPS_TSV', None)
        if fps: cli_env['S2A_FPS_TSV'] = str(fixture / 'fps.tsv')
        argv = [build / 'core/s2a-rewrite', fixture / (source + '.nso'), expected, 'main']
        if wide: argv.append(fixture / 'widen.tsv')
        command(argv, cli_env, expected=status)
        truth = {p.name: p.read_bytes() for p in expected.iterdir()}
        if actual != truth:
            raise RuntimeError('raw JNI/CLI complete output bytes differ: ' + name)
        if status == 3:
            rows = [line.split('\t') for line in actual['main.gaps.tsv'].decode().splitlines()
                    if line and not line.startswith('#')]
            if len(rows) != 1 or rows[0][:2] != ['0x100', 'sys'] or 'd4000022' not in rows[0][2]:
                raise RuntimeError('gap: 缺口地址、类别或指令不符')
            if struct.unpack_from('<I', actual['main.patched.bin'], 0x100)[0] != 0xd4000022:
                raise RuntimeError('gap: 缺口处原指令被改写')
        comparisons[name] = {n: dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
                             for n, data in actual.items()}
    if list((raw_root / 'bad-log/out').iterdir()):
        raise RuntimeError('log-open failure reached C outputs')
    (base / 'raw-comparisons.json').write_text(json.dumps(comparisons, indent=2) + '\n')
    # 窗口内触 SP 的指令：合流后由共享前端的 win_frame/sp_shift 统一抬帧（取代本分支原来的窄门控）。
    # 正例：能平移 → sp-safe，补丁岛里是抬帧后的偏置；反例：平移不了的形态（写回）→ 准确记缺口、不出包，
    # 不许退回 below-sp 包。反例是防止以后有人放宽成静默近似的唯一保险。
    directory = base / 'window-sp'; directory.mkdir(mode=0o700)
    cli_env = dict(env, S2A_TARGET='android'); cli_env.pop('S2A_FPS_TSV', None)
    rewritten = command([build / 'core/s2a-rewrite', fixture / 'window-sp.nso', directory, 'main'], cli_env)
    header = (directory / 'main.fixups.tsv').read_text()
    if '# REWRITE_ABI\tandroid-sp-safe-v1' not in header:
        raise RuntimeError('window-sp: 期望 android-sp-safe-v1，实得 fixups 头：' + header.replace('\t', ' '))
    if "'window': 1" not in rewritten.stdout:
        raise RuntimeError('window-sp: fixture 没有形成窗口，统计行为 ' + repr(rewritten.stdout))
    if "'below_sp'" in rewritten.stdout:
        raise RuntimeError('window-sp: 窗口内 sp 指令可平移，不该再有 below_sp：' + repr(rewritten.stdout))
    # 偏置错一位就是静默错值：补丁岛里必须是 ldr xR,[sp,#0x100]（+16），不许留 subst 后的 [sp,#0xf0]。
    image = (directory / 'main.patched.bin').read_bytes()
    island = image[int(next(l.split('\t')[1] for l in header.splitlines()
                            if l.startswith('# PATCH_OFF\t')), 16):]
    unbiased = [struct.pack('<I', 0xf9407bf2 - 18 + r) for r in range(16)]
    biased = [struct.pack('<I', 0xf94083f2 - 18 + r) for r in range(16)]
    if any(word in island for word in unbiased):
        raise RuntimeError('window-sp: 补丁岛里还有未补 +16 的 ldr xR,[sp,#0xf0]')
    if not any(word in island for word in biased):
        raise RuntimeError('window-sp: 补丁岛里没有 ldr xR,[sp,#0x100]（窗口抬帧后的偏置）')
    # 反例：ldr x18,[sp],#8 写回、SP 动了 → 平移不了。准确记缺口（rc=3），
    # 降级产物保留缺口处原指令，不许退回 below-sp 包或静默按旧偏移改写。
    reject = base / 'window-sp-reject'; reject.mkdir(mode=0o700)
    rejected = command([build / 'core/s2a-rewrite', fixture / 'window-sp-reject.nso', reject, 'main'],
                       cli_env, expected=3)
    if '窗口内 sp 形态不可平移' not in rejected.stdout + rejected.stderr:
        raise RuntimeError('window-sp-reject: 缺口没指明 sp 形态不可平移：' + repr(rejected.stdout))
    for produced in ('main.patched.bin', 'main.fixups.tsv', 'main.gates.tsv', 'main.sites.tsv', 'main.gaps.tsv'):
        if not (reject / produced).is_file():
            raise RuntimeError('window-sp-reject: 缺口路径缺少 ' + produced)
    gaps = (reject / 'main.gaps.tsv').read_text()
    if '窗口内 sp 形态不可平移' not in gaps:
        raise RuntimeError('window-sp-reject: 缺口表未记录不可平移原因')
    if '# REWRITE_ABI\tandroid-sp-safe-v1' not in (reject / 'main.fixups.tsv').read_text():
        raise RuntimeError('window-sp-reject: 降级产物 ABI 不符')
    rejected_image = (reject / 'main.patched.bin').read_bytes()
    if struct.unpack_from('<I', rejected_image, 0x118)[0] != 0xf84087f2:
        raise RuntimeError('window-sp-reject: 缺口处写回指令未保留原字')
    print('窗口 sp 门控：正例 android-sp-safe-v1（below_sp 0、补丁岛抬帧偏置已核）；'
          '反例（写回形态）准确记缺口 rc=3、保留原指令')
    result = command([jdk / 'bin/java', '-Xcheck:jni', '-Djava.library.path=' + str(build), '-cp', classes,
                      'org.s2arm.android.NativeRewriterTest', fixture, build / 'core/s2a-rewrite'], env)
    warning = 'Warning: Calling other JNI functions in the scope of Get/ReleasePrimitiveArrayCritical or Get/ReleaseStringCritical'
    facade_warnings = result.stdout.count(warning) + result.stderr.count(warning)
    other = (result.stdout + result.stderr).replace(warning, '')
    if 'Warning:' in other or 'WARNING in native method' in other or 'FATAL ERROR' in other:
        raise RuntimeError('unexpected facade JNI diagnostics; see retained logs')
    print(result.stdout.strip().splitlines()[-1])
    success_comparisons = sum(case[-1] == 0 for case in cases.values())
    gap_comparisons = sum(case[-1] == 3 for case in cases.values())
    print(f'raw JNI: 17 statuses, 110 invalid-argument cases, {success_comparisons} success + {gap_comparisons} gap full CLI comparisons, zero CheckJNI warnings')
    if facade_warnings:
        print(f'Java facade: {facade_warnings} Critical warnings retained; not a clean CheckJNI claim (see independent JDK Unicode Path control)')
    else:
        print('Java facade: zero CheckJNI warnings (host JVM only)')
    (base / 'result.json').write_text(json.dumps(dict(functional_passed=True, evidence='host JVM JNI only',
        raw_checkjni_clean=True, raw_success_comparisons=success_comparisons, raw_gap_comparisons=gap_comparisons,
        facade_checkjni_clean=not facade_warnings,
        facade_critical_warnings=facade_warnings, actual_jni=True, app_uid=False, device=False), indent=2) + '\n')


if __name__ == '__main__':
    retained = os.environ.get('S2A_JNI_EVIDENCE')
    if retained:
        evidence = Path(retained); evidence.mkdir(parents=True, exist_ok=False)
        run(evidence)
    else:
        with tempfile.TemporaryDirectory(prefix='s2arm-jni-') as temporary:
            run(Path(temporary))
