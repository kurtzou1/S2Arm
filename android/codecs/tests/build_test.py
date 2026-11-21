#!/usr/bin/env python3
"""Offline build rejection and APK license checks; never downloads a codec."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import struct
import zipfile
import contextlib
import shutil
import hashlib
import gzip
import io
import re
import tarfile
import unittest

HERE = Path(__file__).resolve().parent
ANDROID = HERE.parents[1]


def _copy_toolchain(repo):
    # codecs/build.sh 顶部就 source tools/ndk_toolchain.sh（其内再 source tools/versions.sh，
    # 后者解析 docker/Dockerfile 的 ARG SDK_PACKAGES）与 tools/fetch_source.sh——fixture 必须带齐这一链。
    tools = repo / 'android/tools'
    tools.mkdir(parents=True, exist_ok=True)
    for name in ('ndk_toolchain.sh', 'versions.sh', 'fetch_source.sh'):
        shutil.copyfile(ANDROID / 'tools' / name, tools / name)
    docker = repo / 'android/docker'
    docker.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ANDROID / 'docker/Dockerfile', docker / 'Dockerfile')


def _fake_ndk_clang(ndk):
    # s2a_ndk_prebuilt_tag 按实际存在的 prebuilt 目录选宿主工具链——只有
    # source.properties 的假 NDK 会在「没有本宿主可用的 llvm prebuilt 目录」处
    # 提前报红，够不到用例想验证的源码钉/CMake 检查。
    tag = 'darwin-x86_64' if os.uname().sysname == 'Darwin' else 'linux-x86_64'
    bindir = ndk / 'toolchains/llvm/prebuilt' / tag / 'bin'
    bindir.mkdir(parents=True, exist_ok=True)
    clang = bindir / 'aarch64-linux-android34-clang'
    clang.write_text('#!/bin/sh\nif [ "$1" = --version ]; then echo fixture-clang; exit 0; fi\n'
                     'prev=; for a in "$@"; do [ "$prev" = -o ] && : > "$a"; prev=$a; done\nexit 0\n')
    clang.chmod(0o755)


SOURCE_SPEC = importlib.util.spec_from_file_location('avc_source', ANDROID / 'codecs/avc_source.py')
AVC_SOURCE = importlib.util.module_from_spec(SOURCE_SPEC)
SOURCE_SPEC.loader.exec_module(AVC_SOURCE)

class BuildTest(unittest.TestCase):
    def test_shared_cache_default_override_and_missing_home(self):
        # Run the real dispatcher, source checks, AVC recipe and Q19 delegate in
        # an isolated copy; only the source pins/toolchain are synthetic.
        with tempfile.TemporaryDirectory(prefix='s2a-cache-route-') as temporary:
            root = Path(temporary)
            repo = root / 'checkout'
            codecs = repo / 'android/codecs'
            shutil.copytree(ANDROID / 'codecs', codecs, ignore=shutil.ignore_patterns('tests', '__pycache__'))
            _copy_toolchain(repo)
            local = root / 'local'; local.mkdir()
            for name in ('opus', 'vpx'):
                data = (name + ' fixture').encode()
                sha = hashlib.sha256(data).hexdigest()
                filename = 'opus-1.2.tar.gz' if name == 'opus' else 'libvpx-1.2.tar.gz'
                (local / filename).write_bytes(data)
                service = repo / 'services' / name; service.mkdir(parents=True)
                (service / 'build.sh').write_text('VER=1.2; SHA=' + sha + '\n')
            avc = local / 'libavc-fixture.tar.gz'
            with tarfile.open(avc, 'w:gz') as tar:
                for name in ('LICENSE', 'NOTICE', 'common/fixture.h', 'decoder/fixture.c'):
                    data = b'fixture'; item = tarfile.TarInfo(name); item.size = len(data)
                    tar.addfile(item, io.BytesIO(data))
            content = AVC_SOURCE.content_digest(avc)
            build = codecs / 'build.sh'
            text = build.read_text().replace('avc_commit=d380d04a78c6c08702e36aca86d0fd4baee390f9', 'avc_commit=fixture')
            text = text.replace('8901129497b2ba38ec2c52c2667d478626d9b554dd87603ffc5fd5be0a84651a', content)
            build.write_text(text)
            ndk = root / 'ndk'; ndk.mkdir()
            (ndk / 'source.properties').write_text('Pkg.Revision = 29.0.14206865\n')
            bindir = ndk / ('toolchains/llvm/prebuilt/' + ('darwin-x86_64' if os.uname().sysname == 'Darwin' else 'linux-x86_64') + '/bin')
            bindir.mkdir(parents=True)
            tools = {
                'aarch64-linux-android34-clang': '#!/bin/sh\nif [ "$1" = --version ]; then echo fixture-clang; exit; fi\nwhile [ $# -gt 0 ]; do if [ "$1" = -o ]; then shift; : > "$1"; exit; fi; shift; done\n',
                'llvm-ar': '#!/bin/sh\n: > "$2"\n',
                'llvm-ranlib': '#!/bin/sh\nexit 0\n',
            }
            for name, body in tools.items():
                path = bindir / name; path.write_text(body); path.chmod(0o755)
            cmake = root / 'cmake'
            cmake.write_text('#!/bin/sh\ncase "$1" in --version) echo "cmake version 3.31.6";; --build) : > "$2/libavcdec.a";; -S) mkdir -p "$4";; esac\n')
            cmake.chmod(0o755)
            spec = importlib.util.spec_from_file_location('cache_link_symbols', ANDROID / 'core-link/link_symbols.py')
            link = importlib.util.module_from_spec(spec); spec.loader.exec_module(link)
            from unittest import mock
            home = root / 'home'; home.mkdir()
            base = dict(os.environ, HOME=str(home), S2A_Q19_NDK=str(ndk), CMAKE=str(cmake))
            for key in ('S2A_BUILD_CACHE', 'S2A_AVC_ARCHIVE', 'S2A_Q19_AVC_ARCHIVE'):
                base.pop(key, None)
            for override in (None, root / 'custom-cache'):
                with self.subTest(override=override):
                    env = dict(base)
                    if override is not None: env['S2A_BUILD_CACHE'] = str(override)
                    expected = override or home / '.cache/s2arm-build'
                    self.assertFalse(expected.resolve().is_relative_to(repo.resolve()))
                    for args in (['--prepare-sources', str(local)], ['--check-sources']):
                        result = subprocess.run(['bash', str(build), *args], env=env, capture_output=True, text=True)
                        self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(len(list((expected / 'codecs/sources').glob('*.tar.gz'))), 3)
                    result = subprocess.run(['bash', str(build), '--avc-only'], env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    built = Path(result.stdout.strip())
                    self.assertTrue(built.is_file())
                    self.assertTrue(built.is_relative_to(expected))
                    with mock.patch.dict(os.environ, env, clear=True):
                        self.assertEqual(Path(link.avc_probe_archive(repo, ndk, str(cmake))), built.resolve())
            env = dict(base); env.pop('HOME')
            for args in (['--prepare-sources', str(local)], ['--check-sources'], ['--avc-only']):
                result = subprocess.run(['bash', str(build), *args], env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('【红】codec 缓存需要 HOME 或显式设置 S2A_BUILD_CACHE', result.stderr)
            with mock.patch.dict(os.environ, env, clear=True):
                with self.assertRaisesRegex(link.CheckError, 'codec 缓存需要 HOME'):
                    link.avc_probe_archive(repo, ndk, str(cmake))
            env['S2A_BUILD_CACHE'] = str(root / 'no-home-override')
            result = subprocess.run(['bash', str(build), '--prepare-sources', str(local)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((repo / 'build/android-q19-cache').exists())

    def test_q19_allows_supported_newer_cmake_with_standalone_ndk(self):
        with tempfile.TemporaryDirectory(prefix='s2a-avc-newer-cmake-') as temp:
            root = Path(temp)
            ndk = root / 'homebrew/android-ndk'
            ndk.mkdir(parents=True)
            (ndk / 'source.properties').write_text('Pkg.Revision = 29.0.14206865\n')
            _fake_ndk_clang(ndk)
            cmake = root / 'cmake'
            cmake.write_text('#!/bin/sh\necho "cmake version 4.4.4"\n')
            cmake.chmod(0o755)
            bad = root / 'bad.tar.gz'
            bad.write_bytes(b'wrong archive')
            env = dict(os.environ, ANDROID_HOME=str(root / 'stale-sdk'), S2A_Q19_NDK=str(ndk),
                       CMAKE=str(cmake), S2A_BUILD_CACHE=str(root / 'cache'), S2A_AVC_ARCHIVE=str(bad))
            result = subprocess.run(['bash', str(ANDROID / 'codecs/build.sh'), '--avc-only'],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('FAILED', result.stderr)  # supported CMake reaches the source pin check
            self.assertNotIn('requires CMake', result.stderr)

    def test_q19_uses_resolved_standalone_ndk_for_offline_avc(self):
        with tempfile.TemporaryDirectory(prefix='s2a-avc-standalone-ndk-') as temp:
            root = Path(temp)
            ndk = root / 'homebrew/android-ndk'
            ndk.mkdir(parents=True)
            (ndk / 'source.properties').write_text('Pkg.Revision = 29.0.14206865\n')
            _fake_ndk_clang(ndk)
            cmake = root / 'cmake'
            cmake.write_text('#!/bin/sh\necho "cmake version 3.31.6"\n')
            cmake.chmod(0o755)
            bad = root / 'bad.tar.gz'
            bad.write_bytes(b'wrong archive')
            env = dict(os.environ, ANDROID_HOME=str(root / 'stale-sdk'), S2A_Q19_NDK=str(ndk),
                       CMAKE=str(cmake), S2A_BUILD_CACHE=str(root / 'cache'), S2A_AVC_ARCHIVE=str(bad))
            result = subprocess.run(['bash', str(ANDROID / 'codecs/build.sh'), '--avc-only'],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('FAILED', result.stderr)  # real source verifier, not wrong NDK path
            self.assertNotIn('libavc requires NDK', result.stderr)

    def test_avc_content_pin_ignores_archive_time_but_rejects_changes(self):
        def make(path, mtime, payload=b'original', mode=0o644, member='src/a.c', kind='file'):
            with path.open('wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', mtime=mtime) as gz:
                with tarfile.open(fileobj=gz, mode='w') as tar:
                    item = tarfile.TarInfo(member)
                    item.mode = mode
                    item.mtime = mtime
                    if kind == 'link':
                        item.type = tarfile.SYMTYPE
                        item.linkname = 'other'
                        tar.addfile(item)
                    else:
                        item.size = len(payload)
                        tar.addfile(item, io.BytesIO(payload))

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            old, same = root/'old.tar.gz', root/'same.tar.gz'
            make(old, 1); make(same, 200)
            old_sha = hashlib.sha256(old.read_bytes()).hexdigest()
            self.assertNotEqual(old_sha, hashlib.sha256(same.read_bytes()).hexdigest())
            # The old byte pin rejects an equally authentic, different-time tar.
            old_check = subprocess.run(['sha256sum', '-c', '--quiet', '-'],
                                       input=old_sha+'  '+str(same)+'\n', text=True, capture_output=True)
            self.assertNotEqual(old_check.returncode, 0)
            content = AVC_SOURCE.content_digest(old)
            self.assertEqual(AVC_SOURCE.verify(same, content), content)
            for label, kwargs in (
                    ('bytes', {'payload': b'tampered'}), ('mode', {'mode': 0o755}),
                    ('path', {'member': 'src/other.c'}), ('link', {'kind': 'link'}),
                    ('traversal', {'member': '../escape'}), ('setuid', {'mode': 0o4644})):
                with self.subTest(label=label):
                    bad = root/(label+'.tar.gz'); make(bad, 1, **kwargs)
                    with self.assertRaises(ValueError): AVC_SOURCE.verify(bad, content)
            duplicate = root/'duplicate.tar.gz'
            with tarfile.open(duplicate, 'w:gz') as tar:
                for _ in range(2):
                    item = tarfile.TarInfo('src/a.c'); item.size = 1
                    tar.addfile(item, io.BytesIO(b'x'))
            with self.assertRaisesRegex(ValueError, 'duplicate'): AVC_SOURCE.verify(duplicate, content)

            # Exercise the production prepare and offline source selection with
            # the alternate-time archive, not just the Python helper.
            local, cache = root/'local', root/'cache'
            local.mkdir(); shutil.copyfile(same, local/'libavc-fixture.tar.gz')
            command = ['bash', '-c', 'set -euo pipefail; repo_dir=$1; cache_root=$2; '
                       'avc_commit=fixture; avc_sha=$3; avc_content_sha=$4; '
                       'source "$repo_dir/android/codecs/cache.sh"; '
                       'source "$repo_dir/android/codecs/avc-build.sh"; '
                       'avc_prepare "$5"; avc_source',
                       'fixture', str(ANDROID.parents[0]), str(cache), old_sha, content, str(local)]
            result = subprocess.run(command, capture_output=True, text=True, check=True)
            cached = Path(result.stdout.strip())
            self.assertEqual(cached.read_bytes(), same.read_bytes())
            cached.write_bytes(b'corrupt')
            rejected = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('FAILED', rejected.stderr)

    def test_bad_archive_is_rejected_before_configuration(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ndk = root / 'sdk/ndk/29.0.14206865'
            ndk.mkdir(parents=True)
            (ndk / 'source.properties').write_text('Pkg.Revision = 29.0.14206865\n')
            _fake_ndk_clang(ndk)
            cmake = root / 'cmake'
            cmake.write_text('#!/bin/sh\nprintf "cmake version 3.31.6\\n"\n')
            cmake.chmod(0o755)
            bad = root / 'bad.tar.gz'
            bad.write_bytes(b'not the pinned source')
            env = dict(os.environ, ANDROID_HOME=str(root / 'sdk'), S2A_BUILD_CACHE=str(root / 'cache'),
                       S2A_AVC_ARCHIVE=str(bad), CMAKE=str(cmake))
            for version in ('3.31.6','3.31.6-g38307f9','3.31.7'):
                with self.subTest(version=version):
                    cmake.write_text('#!/bin/sh\nprintf "cmake version '+version+'\\n"\n')
                    result = subprocess.run(['bash', str(ANDROID / 'codecs/build.sh'), '--avc-only'], env=env,
                                            capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('requires CMake 3.31.6' if version=='3.31.7' else 'FAILED', result.stderr)
                    self.assertEqual(result.stdout, '')
                    self.assertFalse(list((root / 'cache').rglob('libs2a_avc.a')))

    def test_independent_recipe_keys(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); repo=root/'repo';codecs=repo/'android/codecs'
            shutil.copytree(ANDROID/'codecs',codecs,ignore=shutil.ignore_patterns('tests','__pycache__'))
            _copy_toolchain(repo)
            for name in ('opus','vpx'):
                dest=repo/'services'/name;dest.mkdir(parents=True)
                shutil.copy2(ANDROID.parents[0]/'services'/name/'build.sh',dest/'build.sh')
            sdk=root/'sdk';ndk=sdk/'ndk/29.0.14206865';ndk.mkdir(parents=True)
            (ndk/'source.properties').write_text('Pkg.Revision = 29.0.14206865\n')
            tag='darwin-x86_64' if os.uname().sysname=='Darwin' else 'linux-x86_64'
            compiler=ndk/'toolchains/llvm/prebuilt'/tag/'bin/aarch64-linux-android34-clang';compiler.parent.mkdir(parents=True)
            compiler.write_text('#!/bin/sh\necho clang-fixture-version\n');compiler.chmod(0o755)
            cmake=root/'cmake';cmake.write_text('#!/bin/sh\necho cmake-version-fixture\n');cmake.chmod(0o755)
            env=dict(os.environ,ANDROID_HOME=str(sdk),S2A_BUILD_CACHE=str(root/'cache'),CMAKE=str(cmake))
            def keys():
                result=subprocess.run(['bash',str(codecs/'build.sh'),'--cache-keys'],env=env,capture_output=True,text=True,check=True)
                return dict(line.split() for line in result.stdout.splitlines())
            before=keys();self.assertEqual(set(before),{'opus','vpx','avc'})
            # libavc's recipe includes the shared helper layer (cache.sh/build.sh):
            # helper semantics can change flags/toolchain handling, so AVC must be
            # invalidated while Opus/VPX keep their own independent keys.
            with (codecs/'build.sh').open('a') as f:f.write('\n# dispatcher/helper change\n')
            helper=keys();self.assertEqual(helper['opus'],before['opus']);self.assertEqual(helper['vpx'],before['vpx']);self.assertNotEqual(helper['avc'],before['avc'])
            with (codecs/'cache.sh').open('a') as f:f.write('\n# shared cache helper change\n')
            shared=keys();self.assertEqual(shared['opus'],before['opus']);self.assertEqual(shared['vpx'],before['vpx']);self.assertNotEqual(shared['avc'],helper['avc'])
            with (codecs/'avc-build.sh').open('a') as f:f.write('\n# avc recipe change\n')
            after=keys();self.assertEqual(after['opus'],before['opus']);self.assertEqual(after['vpx'],before['vpx']);self.assertNotEqual(after['avc'],shared['avc'])
            with (codecs/'opus-build.sh').open('a') as f:f.write('\n# opus recipe change\n')
            last=keys();self.assertNotEqual(last['opus'],after['opus']);self.assertEqual(last['vpx'],after['vpx']);self.assertEqual(last['avc'],after['avc'])

    def test_opus_recipe_maps_build_directory_out_of_embedded_paths(self):
        # __FILE__ 会把随机 mktemp 目录写进 .a，两路/重跑因此字节不同；CFLAGS 必须把它映射成定值。
        with tempfile.TemporaryDirectory(prefix='s2a-opus-map-') as temporary:
            root = Path(temporary)
            log = root / 'configure.log'
            command = r'''
set -euo pipefail
codec_recipe_key() { echo fixture-key; }
codec_cached() { return 1; }
codec_unpack() { mkdir -p "$2/src/include"; printf h > "$2/src/include/opus.h"; printf lic > "$2/src/COPYING"; cp "$CONFIGURE_EXTRA" "$2/src/configure"; chmod +x "$2/src/configure"; }
codec_publish() { mkdir -p "$2"; cp "$1/COPYING" "$2/"; }
codec_shim() { printf '%s\n' "$1"; }
make() { mkdir -p .libs; printf a > .libs/libopus.a; }
codec_jobs=1; cc=clang; cache_root=$1; licenses=$2; repo_dir=$3; opus_sha=fixture; opus_ver=1.2
mkdir -p "$cache_root/codecs" "$licenses"
. "$4"
build_opus
'''
            configure = root / 'Configure.extra'
            configure.write_text('#!/bin/sh\nprintf "%s\\n" "$CFLAGS" > "$CONFIGURE_LOG"\nexit 0\n')
            env = dict(os.environ, CONFIGURE_LOG=str(log), CONFIGURE_EXTRA=str(configure))
            result = subprocess.run(['bash', '-c', command, 'fixture', str(root / 'cache'),
                                     str(root / 'licenses'), str(root / 'repo'),
                                     str(ANDROID / 'codecs/opus-build.sh')],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            cflags = log.read_text().strip()
            self.assertRegex(cflags, r'-ffile-prefix-map=/\S+=opus\b')
            self.assertRegex(cflags, r'-fmacro-prefix-map=/\S+=opus\b')
            mapped = re.findall(r'-f(?:file|macro)-prefix-map=(/\S+?)=opus\b', cflags)
            self.assertEqual(len(set(mapped)), 1, cflags)

    def test_preparation_local_source_and_build_are_offline(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);cache=root/'cache';local=root/'local';local.mkdir()
            data=b'original source fixture';sha=hashlib.sha256(data).hexdigest()
            (local/'fixture.tgz').write_bytes(data)
            fakebin=root/'bin';fakebin.mkdir();marker=root/'network-called'
            curl=fakebin/'curl';curl.write_text('#!/bin/sh\ntouch "'+str(marker)+'"\nexit 99\n');curl.chmod(0o755)
            env=dict(os.environ,PATH=str(fakebin)+os.pathsep+os.environ['PATH'])
            common=['bash','-c','source "$1";source "$2";cache_root="$3";'+
                    'codec_prepare fixture.tgz https://invalid.example/source "$4" "$5"; codec_source "$4"',
                    'fixture',str(ANDROID/'tools/ndk_toolchain.sh'),str(ANDROID/'codecs/cache.sh'),str(cache),sha,str(local)]
            prepared=subprocess.run(common,env=env,capture_output=True,text=True,check=True)
            archive=cache/'codecs/sources'/(sha+'.tar.gz')
            self.assertEqual(archive.read_bytes(),data);self.assertIn(str(archive),prepared.stdout)
            archive.write_bytes(b'corrupt')
            bad=subprocess.run(common,env=env,capture_output=True,text=True)
            self.assertNotEqual(bad.returncode,0);self.assertIn('FAILED',bad.stderr)
            missing=subprocess.run(['bash',str(ANDROID/'codecs/build.sh'),'--check-sources'],
                                   env=dict(env,S2A_BUILD_CACHE=str(root/'empty')),capture_output=True,text=True)
            self.assertNotEqual(missing.returncode,0);self.assertIn('Missing pinned codec source',missing.stderr)
            self.assertFalse(marker.exists(),'build or local preparation attempted network')

    def test_missing_shim_fails_instead_of_publishing_bare_libavc(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);repo=root/'repo';codecs=repo/'android/codecs'
            shutil.copytree(ANDROID/'codecs',codecs,ignore=shutil.ignore_patterns('tests','__pycache__'))
            _copy_toolchain(repo)
            src=root/'src';(src/'common').mkdir(parents=True);(src/'decoder').mkdir()
            (src/'common'/'fixture.h').write_text('/* fixture */\n')
            (src/'decoder'/'fixture.c').write_text('/* fixture */\n')
            (src/'LICENSE').write_text('fixture license\n');(src/'NOTICE').write_text('fixture notice\n')
            archive=root/'libavc.tar.gz'
            with tarfile.open(archive,'w:gz') as tar:
                for child in sorted(src.iterdir()): tar.add(child,arcname=child.name)
            sha=hashlib.sha256(archive.read_bytes()).hexdigest()
            content_sha=AVC_SOURCE.content_digest(archive)
            ndk=root/'sdk/ndk/29.0.14206865';ndk.mkdir(parents=True)
            (ndk/'source.properties').write_text('Pkg.Revision = 29.0.14206865\n')
            _fake_ndk_clang(ndk)
            bin=root/'bin';bin.mkdir()
            cc=bin/'cc';cc.write_text('#!/bin/sh\nprev=;for a in "$@";do [ "$prev" = -o ] && : > "$a";prev=$a;done\nexit 0\n');cc.chmod(0o755)
            cmake=bin/'cmake';cmake.write_text('#!/bin/sh\ncase "$1" in --version) echo "cmake version 3.31.6";; --build) mkdir -p "$2"; : > "$2/libavcdec.a";; -S) mkdir -p "$4";; esac\nexit 0\n');cmake.chmod(0o755)
            ar=bin/'llvm-ar';ar.write_text('#!/bin/sh\n: > "$2"\nexit 0\n');ar.chmod(0o755)
            ranlib=bin/'llvm-ranlib';ranlib.write_text('#!/bin/sh\nexit 0\n');ranlib.chmod(0o755)
            env=dict(os.environ,ANDROID_HOME=str(root/'sdk'),S2A_BUILD_CACHE=str(root/'cache'),
                     S2A_AVC_ARCHIVE=str(archive),CMAKE=str(cmake),PATH=str(bin)+os.pathsep+os.environ['PATH'])
            command=['bash','-c','set -euo pipefail;repo_dir=$1;cache_root=$2;licenses=$3;ndk=$4;cc=$5;avc_sha=$6;'+
                     'avc_tag=android-16.0.0_r4;avc_commit=d380d04a78c6c08702e36aca86d0fd4baee390f9;avc_content_sha=$7;'+
                     'source "$repo_dir/android/tools/ndk_toolchain.sh";'+
                     'source "$repo_dir/android/codecs/cache.sh";source "$repo_dir/android/codecs/avc-build.sh";build_avc',
                     'fixture',str(repo),str(root/'cache'),str(root/'licenses'),str(ndk),str(cc),sha,content_sha]
            shim=codecs/'s2a_avc.c';shim.unlink()
            missing=subprocess.run(command,env=env,capture_output=True,text=True)
            self.assertNotEqual(missing.returncode,0)
            self.assertIn('missing libavc shim source s2a_avc.c',missing.stderr)
            self.assertFalse(list((root/'cache').rglob('libs2a_avc.a')))
            shutil.copy2(ANDROID/'codecs/s2a_avc.c',shim)
            built=subprocess.run(command,env=env,capture_output=True,text=True)
            self.assertEqual(built.returncode,0,built.stderr)
            output=Path(built.stdout.strip().splitlines()[-1])
            self.assertTrue(output.is_file() and output.name=='libs2a_avc.a',built.stdout)

    def test_artifact_cache_integrity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);entry=root/'entry';entry.mkdir()
            payload=b'archive fixture';(entry/'lib.a').write_bytes(payload)
            (entry/'manifest.sha256').write_text(hashlib.sha256(payload).hexdigest()+'  lib.a\n')
            cmd=['bash','-c','source "$1";source "$2"; codec_cached "$3"','fixture',
                 str(ANDROID/'tools/ndk_toolchain.sh'),str(ANDROID/'codecs/cache.sh'),str(entry)]
            self.assertEqual(subprocess.run(cmd,capture_output=True).returncode,0)
            (entry/'lib.a').write_bytes(b'corrupt')
            corrupt=subprocess.run(cmd,capture_output=True,text=True)
            self.assertNotEqual(corrupt.returncode,0);self.assertIn('Corrupt/incomplete codec artifact cache',corrupt.stderr)
            (entry/'manifest.sha256').unlink()
            incomplete=subprocess.run(cmd,capture_output=True,text=True)
            self.assertNotEqual(incomplete.returncode,0);self.assertIn('Corrupt/incomplete codec artifact cache',incomplete.stderr)

    def test_parallel_publish_reuses_the_published_entry(self):
        """同 key 的产物已被并行门禁发布：后到的重建复用，不判红（10-29 #919）。"""
        with tempfile.TemporaryDirectory(prefix='s2a-publish-race-') as temporary:
            root = Path(temporary)
            target = root / 'cache' / 'avc-fixed'
            (root / 'cache').mkdir()
            first = root / 'first'; first.mkdir()
            (first / 'libs2a_avc.a').write_bytes(b'first build')
            second = root / 'second'; second.mkdir()
            (second / 'libs2a_avc.a').write_bytes(b'second build')
            command = ['bash', '-c', 'source "$1"; source "$2"; codec_publish "$3" "$4"',
                       'fixture', str(ANDROID / 'tools/ndk_toolchain.sh'), str(ANDROID / 'codecs/cache.sh')]
            published = subprocess.run([*command, str(first), str(target)],
                                       capture_output=True, text=True)
            self.assertEqual(published.returncode, 0, published.stderr)
            # 修复前这里红：Codec cache appeared during build（2 路并发实测 1 红）。
            reused = subprocess.run([*command, str(second), str(target)],
                                    capture_output=True, text=True)
            self.assertEqual(reused.returncode, 0, reused.stderr)
            self.assertEqual((target / 'libs2a_avc.a').read_bytes(), b'first build')
            self.assertFalse(second.exists(), '后到的重建目录应被丢弃')
            # 已发布条目坏掉时照旧报红：复用不是「谁先到谁赢」的兜底。
            (target / 'libs2a_avc.a').write_bytes(b'corrupt')
            third = root / 'third'; third.mkdir()
            (third / 'libs2a_avc.a').write_bytes(b'third build')
            corrupt = subprocess.run([*command, str(third), str(target)],
                                     capture_output=True, text=True)
            self.assertNotEqual(corrupt.returncode, 0)
            self.assertIn('Corrupt/incomplete codec artifact cache', corrupt.stderr)

    def verifier(self):
        spec = importlib.util.spec_from_file_location('verify_apk', ANDROID / 'verify-apk.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_actual_apk_license_and_alignment_rejection(self):
        module=self.verifier()
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            marker,names=next(row for row in module.LICENSE_MARKERS if b'LIBAVC' in row[0])
            def apk(name,missing=None,align=16384):
                data=bytearray(256)
                data[:6]=b'\x7fELF\x02\x01'
                struct.pack_into('<H',data,18,183)
                struct.pack_into('<Q',data,32,64)
                struct.pack_into('<HH',data,54,56,1)
                struct.pack_into('<IIQQQQQQ',data,64,1,4,0,0,0,len(data),len(data),align)
                data+=marker+module.jni_abi().encode()
                path=root/name
                with zipfile.ZipFile(path,'w') as archive:
                    info=zipfile.ZipInfo('lib/arm64-v8a/libs2arm_android.so')
                    pad=(-30-len(info.filename.encode()))%16384
                    info.extra=struct.pack('<HH',0xcafe,pad-4)+bytes(pad-4)
                    archive.writestr(info,data)
                    # verify-apk 要求打包的 capprobe 助手也在 lib/：夹具给
                    # 同一 ELF 头与 STORED+16 KB 载荷对齐（无许可标记）。
                    probe=zipfile.ZipInfo('lib/arm64-v8a/libs2a_capprobe.so')
                    pad=-(archive.fp.tell()+30+len(probe.filename.encode()))%16384
                    if pad:
                        if pad<4: pad+=16384
                        probe.extra=struct.pack('<HH',0xcafe,pad-4)+bytes(pad-4)
                    archive.writestr(probe,data[:256])
                    for entry in names:
                        if entry!=missing: archive.writestr(entry,'fixture license')
                return path
            with contextlib.redirect_stdout(io.StringIO()): module.verify(apk('valid.apk'))
            for entry in names:
                with self.assertRaisesRegex(ValueError,'license'):
                    module.verify(apk('missing.apk',entry))
            with self.assertRaisesRegex(ValueError,'16 KB'):
                module.verify(apk('bad-align.apk',align=4096))

    def test_sanitizer_reports_cannot_pass_on_exit_zero(self):
        from sanitizer_report import inspect
        with self.assertRaisesRegex(AssertionError,'strict sanitizer'):
            inspect('/tmp/shim.c:1:1: runtime error: left shift of negative value -1',HERE)
        with self.assertRaisesRegex(AssertionError,'new upstream'):
            inspect(str(HERE/'unlisted.c')+':1:1: runtime error: unexpected UB',HERE,True)
        with self.assertRaisesRegex(AssertionError,'never allowed'):
            inspect('ERROR: AddressSanitizer: heap-buffer-overflow',HERE,True)

    def test_libavc_license_marker_requires_all_three_notices(self):
        spec = importlib.util.spec_from_file_location('verify_apk', ANDROID / 'verify-apk.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        marker, names = next(row for row in module.LICENSE_MARKERS if b'LIBAVC' in row[0])
        self.assertIn(b'd380d04a78c6c08702e36aca86d0fd4baee390f9', marker)
        self.assertEqual({Path(n).name for n in names},
                         {'libavc-LICENSE.txt', 'libavc-NOTICE.txt', 'libavc-SOURCE.txt'})

if __name__ == '__main__':
    unittest.main()
