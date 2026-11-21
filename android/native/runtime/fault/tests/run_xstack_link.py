#!/usr/bin/env python3
"""Real NDK shared-link/visibility regression; no Android execution or fake core."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[5]
FAULT = Path('android/native/runtime/fault')
PRIVATE = ('g_xs_fn', 'g_xs_off')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ndk_tools():
    # 与 core-link 同一固定版本解析：只认 source.properties 的
    # Pkg.Revision = 29.0.14206865，不按目录存在与否信任 ANDROID_NDK_HOME / ANDROID_NDK_ROOT。
    sys.path.insert(0, str(ROOT / 'android/core-link'))
    import link_symbols
    ndk = link_symbols.find_ndk()
    host = {'darwin': 'darwin-x86_64', 'linux': 'linux-x86_64'}.get(sys.platform.split('-')[0])
    if ndk is None or host is None:
        raise SystemExit('【红】找不到固定 NDK 29.0.14206865；设 ANDROID_NDK_HOME 或传 --cc/--readelf')
    bin_dir = ndk / 'toolchains/llvm/prebuilt' / host / 'bin'
    tools = (bin_dir / 'aarch64-linux-android34-clang', bin_dir / 'llvm-readelf')
    for tool in tools:
        if not tool.is_file():
            raise SystemExit(f'【红】缺少 {tool}；设 ANDROID_NDK_HOME 或传 --cc/--readelf')
    return tools


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--cc', type=Path)
    parser.add_argument('--readelf', type=Path)
    args = parser.parse_args()
    cc, readelf = args.cc, args.readelf
    if cc is None or readelf is None:
        default_cc, default_readelf = ndk_tools()
        cc = cc or default_cc
        readelf = readelf or default_readelf
    out = args.out.resolve()
    if out == ROOT or ROOT in out.parents:
        parser.error('output must be outside source')
    out.mkdir(parents=True, exist_ok=True)
    sources = [Path('runtime/src/xstack.c'), Path('runtime/src/entry.S'),
               FAULT / 'elf_host.c', FAULT / 'tests/xstack_link_providers.c']
    inputs = sources + [Path('runtime/src/native.h'), Path('platform/plat.h'),
                       Path('platform/plat_asm.h'), FAULT / 'tests/run_xstack_link.py']
    inputs += sorted(p.relative_to(ROOT) for p in (ROOT / 'runtime/include').glob('*.h'))
    hashes = {str(p): sha(ROOT / p) for p in inputs}
    receipt = {'kind': 'NDK29 Bionic API34 actual xstack shared link',
               'source_sha256': hashes, 'commands': [], 'checks': {},
               'android_executed': False, 'managed_executed': False,
               'providers': 'link-only abort/ENOSYS; not a runtime implementation'}

    def save():
        (out / 'results.json').write_text(json.dumps(receipt, indent=2) + '\n')

    def run(argv, name, success=True):
        process = subprocess.run([str(v) for v in argv], stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, timeout=60)
        (out / (name + '.log')).write_text(process.stdout)
        receipt['commands'].append({'argv': [str(v) for v in argv],
                                    'exit': process.returncode, 'log': name + '.log'})
        save()
        if success and process.returncode != 0:
            raise RuntimeError(name + ' failed')
        return process

    def check(name, condition):
        receipt['checks'][name] = bool(condition)
        save()
        if not condition:
            raise RuntimeError(name)

    run([cc, '--version'], 'compiler')
    common = [cc, '-fPIC', '-O2', '-Wall', '-Wextra', '-Werror',
              '-I' + str(ROOT / 'runtime/include')]
    objects = []
    for i, source in enumerate(sources):
        obj = out / (str(i) + '.o')
        run(common + ['-c', ROOT / source, '-o', obj], 'compile-' + str(i))
        objects.append(obj)
    link = [cc, '-shared', '-Wl,-z,defs,-z,max-page-size=16384,--fatal-warnings']
    library = out / 'libxstack_pic.so'
    run(link + objects + ['-ldl', '-o', library], 'link-fixed')

    # Restore only the old default visibility in a private source copy. All
    # assembler, other C objects, link flags and link-only providers stay equal.
    old_root = out / 'old-visibility-source'
    for path in inputs:
        target = old_root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / path).read_bytes())
    old = old_root / sources[0]
    content = old.read_text()
    marker = '#define XS_INTERNAL __attribute__((visibility("hidden")))'
    check('one_android_visibility_definition', content.count(marker) == 1)
    old.write_text(content.replace(marker, '#define XS_INTERNAL'))
    old_obj = out / 'old-xstack.o'
    run(common + ['-c', old, '-o', old_obj], 'compile-old')
    failed = run(link + [old_obj] + objects[1:] + ['-ldl', '-o', out / 'libold.so'],
                 'link-old', success=False)
    check('old_link_rejected', failed.returncode != 0)
    check('old_failure_is_not_undefined_provider', 'undefined symbol:' not in failed.stdout)
    for symbol in PRIVATE:
        check('old_' + symbol + '_relocation_red',
              re.search(r'relocation R_AARCH64_[A-Z0-9_]+ cannot be used against symbol [\'\"]'
                        + symbol + r'[\'\"]', failed.stdout) is not None)
    dynamic = run([readelf, '--dyn-syms', '--wide', library], 'dynamic-symbols').stdout
    symbols = run([readelf, '--symbols', '--wide', library], 'all-symbols').stdout
    relocs = run([readelf, '--relocs', '--wide', library], 'relocations').stdout
    obj_symbols = run([readelf, '--symbols', '--wide', objects[0]], 'object-symbols').stdout
    for symbol in PRIVATE:
        check(symbol + '_object_hidden',
              re.search(r'GLOBAL\s+HIDDEN\s+\S+\s+' + symbol + r'\s*$', obj_symbols, re.M) is not None)
        check(symbol + '_not_dynamic', re.search(r'\b' + symbol + r'\b', dynamic) is None)
        check(symbol + '_local_defined',
              re.search(r'LOCAL\s+HIDDEN\s+(?!UND\b)\S+\s+' + symbol + r'\s*$', symbols, re.M) is not None)
        check(symbol + '_no_dynamic_relocation', re.search(r'\b' + symbol + r'\b', relocs) is None)
    check('unrelated_key_remains_exported',
          re.search(r'GLOBAL\s+DEFAULT\s+(?!UND\b)\S+\s+g_xs_key\s*$', dynamic, re.M) is not None)
    check('source_unchanged', hashes == {str(p): sha(ROOT / p) for p in inputs})
    receipt['library_sha256'] = sha(library)
    receipt['pass'] = True
    save()
    print('PASS actual NDK shared link; old visibility fails both private symbol relocations')


if __name__ == '__main__':
    main()
