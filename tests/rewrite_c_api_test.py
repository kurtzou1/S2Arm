#!/usr/bin/env python3
"""Generate public fixtures, then verify C ABI isolation and malformed input handling.

C 接口线程输出对金样（tests/fixtures/rewrite_golden/rewrite_c_api.tsv，见 tests/rewrite_golden.py；原为对 Python 改写器真值）。
"""
import importlib.util
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tests/rewrite_corpus'))
spec = importlib.util.spec_from_file_location('corpus', ROOT / 'tests/rewrite_corpus/run.py')
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)
sys.path.insert(0, str(ROOT / 'tests'))
from rewrite_golden import Golden

def main():
    binary = Path(os.environ['REW']).resolve()
    harness = binary.with_name('s2a-rewrite-api-test')
    try:
        with tempfile.TemporaryDirectory(prefix='rewrite-api-') as tmp:
            t = Path(tmp); source = t / 'main'
            words = [0xb9400008, 0x34ffffe8, 0xd53bd040, 0x91002243, 0xd4000021, 0xd65f03c0]
            corpus.nso(words, {}, len(words)*4, str(source))
            proc = subprocess.run([str(harness), str(source), str(t/'apple'), str(t/'android')], capture_output=True, text=True, timeout=60)
            assert proc.returncode == 0, (proc.returncode, proc.stdout, proc.stderr)
            assert not proc.stderr, proc.stderr
            print(proc.stdout.strip())
            # 线程输出 = 对应目标（安卓开自旋）的 CLI 产物；金样 10-31 由 Python 改写器与 C 同产物时生成
            golden = Golden('rewrite_c_api')
            problems = [e for e in (golden.check('api-' + target, 0, source, t/target) for target in ('apple', 'android')) if e]
            problems += golden.finish()
            assert not problems, problems
            print('C API：线程输出逐文件与金样相同（2 组）')
            gap_source = t/'gap.nso'
            corpus.nso([0xd503207f, 0xd65f03c0], {}, 8, str(gap_source))  # wfi, ret
            stale = t/'stale'; stale.mkdir(); (stale/'main.patched.bin').write_bytes(b'stale')
            result = subprocess.run([str(binary), str(gap_source), str(stale), 'main'], capture_output=True, text=True, timeout=10)
            assert result.returncode == 3 and (stale/'main.patched.bin').read_bytes() != b'stale', (result.returncode, result.stderr)   # v0.3.1：有缺口照出新产物、覆盖旧映像
            assert not result.stderr and 'sys' in (stale/'main.gaps.tsv').read_text(), result.stderr
            print('缺口：退出码 3、记录原因、产物照出并覆盖旧映像（v0.3.1）')
            valid = source.read_bytes()
            malformed = [b'', b'NSO0', bytes(256), valid[:270]]
            for index in (0x10, 0x14, 0x18, 0x60):
                data = bytearray(valid); struct.pack_into('<I', data, index, 0xffffffff)
                malformed.append(bytes(data))
            data = bytearray(valid); struct.pack_into('<I', data, 0x100+4, 0xfffffff0)
            malformed.append(bytes(data))
            for i, data in enumerate(malformed):
                path = t / f'invalid-{i}'; path.write_bytes(data)
                out = t / f'bad-{i}'
                result = subprocess.run([str(binary), str(path), str(out), 'main'], capture_output=True, text=True, timeout=10)
                assert result.returncode == 1, (i, result.returncode, result.stdout, result.stderr)
                assert not result.stderr and not (out/'main.patched.bin').exists(), (i, result.stderr)
            print(f'畸形 NSO：{len(malformed)} 例明确失败、不出映像、无 sanitizer 诊断')
    finally:
        shutil.rmtree(corpus.T)

if __name__ == '__main__':
    main()
