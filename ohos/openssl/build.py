#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Build OHOS OpenSSL from the archive pinned by android/openssl/build.sh.

Requires an installed OHOS SDK, Perl, GNU make and a POSIX shell. Never installs
tools or publishes binaries. Pass an already downloaded official archive.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def shared_pin():
    source = (ROOT/'android/openssl/build.sh').read_text(encoding='utf8')
    version = re.search(r'^version=([0-9.]+)\s', source, re.M)
    sha = re.search(r'^sha256=([a-f0-9]{64})$', source, re.M)
    if not version or not sha:
        raise RuntimeError('Cannot read the shared Android OpenSSL pin')
    return version[1], sha[1]

def tool_path(path):
    # Configure emits shell command strings. Use installed Windows short paths,
    # as in ohos/codecs/build.py, rather than losing SDK paths at spaces.
    if os.name != 'nt':
        return str(path)
    buf = ctypes.create_unicode_buffer(32768)
    if not ctypes.windll.kernel32.GetShortPathNameW(str(path), buf, len(buf)):
        raise OSError('Cannot resolve installed tool path: ' + str(path))
    return buf.value.replace('\\', '/')

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--native-sdk', required=True, type=Path)
    p.add_argument('--archive', required=True, type=Path)
    p.add_argument('--out', required=True, type=Path, help='New empty build directory outside the repository')
    p.add_argument('--perl', required=True, type=Path)
    p.add_argument('--make', required=True, type=Path)
    p.add_argument('--shell', required=True, type=Path)
    p.add_argument('--jobs', type=int, default=2)
    args = p.parse_args()
    if args.jobs < 1 or args.jobs > 16:
        p.error('--jobs must be between 1 and 16')
    sdk, out, archive = args.native_sdk.resolve(), args.out.resolve(), args.archive.resolve()
    if out == ROOT or ROOT in out.parents:
        p.error('Build output must remain outside the Git worktree')
    if out.exists() and any(out.iterdir()):
        p.error('Use a new empty output directory; existing builds are retained')
    version, expected = shared_pin()
    if digest(archive) != expected:
        p.error('Archive SHA256 does not match android/openssl/build.sh')
    suffix = '.exe' if os.name == 'nt' else ''
    llvm = sdk/'llvm/bin'
    tools = {n: llvm/(n+suffix) for n in ('clang','llvm-ar','llvm-ranlib','llvm-strip','llvm-readelf')}
    for t in [*tools.values(), args.perl, args.make, args.shell]:
        if not t.is_file():
            p.error('Missing installed tool: ' + str(t))
    # Check the installed Perl before extracting a large source tree.
    check = subprocess.run([str(args.perl.resolve()), '-MIPC::Cmd', '-e', '1'], capture_output=True)
    if check.returncode:
        raise RuntimeError('Installed Perl lacks OpenSSL Configure modules (IPC::Cmd): ' + check.stderr.decode(errors='replace'))
    out.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, 'r:gz') as tar:
        roots = {Path(m.name).parts[0] for m in tar.getmembers() if m.name}
        if roots != {'openssl-'+version}:
            raise RuntimeError('Unexpected OpenSSL archive root')
        tar.extractall(out, filter='data')
    source = out/('openssl-'+version)
    env = dict(os.environ, SOURCE_DATE_EPOCH='1761868800')
    env['CC'] = shlex.quote(tool_path(tools['clang']))+' --target=aarch64-linux-ohos --sysroot='+shlex.quote(tool_path(sdk/'sysroot'))
    env['AR'], env['RANLIB'] = tool_path(tools['llvm-ar']), tool_path(tools['llvm-ranlib'])
    env['PATH'] = os.pathsep.join([str(args.shell.resolve().parent), str(args.make.resolve().parent), str(llvm), env.get('PATH','')])
    env['MSYS2_ARG_CONV_EXCL'] = '*'
    commands = []
    def run(name, argv):
        result = subprocess.run([str(args.shell.resolve()), '-c', 'exec "$@"', 's2a-openssl', *map(str,argv)], cwd=source, env=env, capture_output=True)
        (out/(name+'.log')).write_bytes(result.stdout+result.stderr)
        commands.append({'step':name,'exit_code':result.returncode})
        (out/'steps.json').write_text(json.dumps(commands,indent=2))
        if result.returncode:
            raise RuntimeError(name+' failed; see '+str(out/(name+'.log')))
    run('configure',[args.perl.resolve(), 'Configure', 'linux-aarch64', 'shared', 'no-module', 'no-apps', 'no-tests', 'no-docs', '-Wl,-z,max-page-size=16384'])
    run('build',[args.make.resolve(), '-j'+str(args.jobs), 'build_libs'])
    dest = out/'package'
    dest.mkdir()
    records = []
    for name in ('libssl.so.3','libcrypto.so.3'):
        lib = source/name
        info = subprocess.check_output([str(tools['llvm-readelf']), '-h', '-d', str(lib)], text=True)
        if 'AArch64' not in info or not re.search(r'\(SONAME\).*\['+re.escape(name)+r'\]',info):
            raise RuntimeError('Unexpected architecture or SONAME: '+name)
        (out/(name+'.readelf.txt')).write_text(info)
        subprocess.run([str(tools['llvm-strip']), '--strip-unneeded', '-o', str(dest/name), str(lib)],check=True)
        records.append({'file':name,'sha256':digest(dest/name)})
    shutil.copyfile(source/'LICENSE.txt',dest/'openssl-LICENSE.txt')
    (dest/'manifest.json').write_text(json.dumps({'version':version,'source_sha256':expected,'recipe_sha256':digest(Path(__file__)),
        'clang_sha256':digest(tools['clang']),'libraries':records,'license_sha256':digest(dest/'openssl-LICENSE.txt')},indent=2))
    print(str(dest))

if __name__ == '__main__':
    main()
