#!/usr/bin/env python3
# 门禁手动：要现存私有 Maxwell 作业及原机器码、已构建 translator 和显式路径参数；手动执行真实语料回归，不造输入。
"""Translate existing Maxwell jobs without inventing resource facts or code.

The input jobs and their original code must already exist. A code directory may
relocate an expired job path by basename. This verifies CPU translation and
capability metadata; it does not run a game or establish GPU correctness.
"""
import argparse
import collections
import hashlib
import json
import pathlib
import struct
import subprocess
import tempfile


def instructions(data):
    if len(data) < 20 or len(data) % 4:
        raise AssertionError('invalid SPIR-V size')
    words = struct.unpack('<%dI' % (len(data) // 4), data)
    if words[0] != 0x07230203:
        raise AssertionError('translation output is not SPIR-V')
    offset = 5
    while offset < len(words):
        count, opcode = words[offset] >> 16, words[offset] & 0xffff
        if count == 0 or offset + count > len(words):
            raise AssertionError('malformed SPIR-V instruction')
        yield opcode, words[offset + 1:offset + count]
        offset += count


def verify(root, jobs, xlate):
    manifest = root / 'jobs.json'
    manifest.write_text(json.dumps(jobs))
    subprocess.run(['dotnet', str(xlate.resolve()), str(manifest), str(root)], check=True)
    counts = collections.Counter()
    reasons = collections.Counter()
    for job in jobs:
        res = json.loads((root / (job['key'] + '.res.json')).read_text())
        if res['resolution_scale_abi'] != 2 or res['stage'] != job['stage']:
            raise AssertionError('missing stage/ABI metadata')
        exact = res['resolution_scale_exact']
        why = res['resolution_scale_reasons']
        if not isinstance(exact, bool) or not isinstance(why, list):
            raise AssertionError('invalid capability metadata')
        if res['resolution_scale_status'] != ('exact' if exact else 'legacy_1x'):
            raise AssertionError('status disagrees with exactness')
        if exact == bool(why):
            raise AssertionError('exact needs no refusal reasons; legacy_1x needs reasons')
        for reason in why:
            if not isinstance(reason, str) or not reason.startswith(('unknown_missing_fact:', 'unsupported_scaled_access:')):
                raise AssertionError('unclassified capability reason')
            reasons[reason.split(':', 1)[0]] += 1
        for index, binding, image in res['tex_scales']:
            if not 0 < index < 73 or not any(t['binding'] == binding for t in res['images' if image else 'textures']):
                raise AssertionError('scale table index or binding is unproven')
        # Image writes may be exact (11-22): the host keeps every storage-image slot at its own size (rs_pre_images / rs_pre_draw).
        if exact and any(t['array'] > 1 for t in res['textures'] + res['images']):
            raise AssertionError('unsupported descriptor array is exact')
        path = root / (job['key'] + '.spv')
        if not any(op == 72 and operands[1:] == (12, 35, 2608) for op, operands in instructions(path.read_bytes())):
            raise AssertionError('SPIR-V member 12 is not at ABI2 offset 2608')
        if exact:
            subprocess.run(['spirv-val', '--target-env', 'vulkan1.1', str(path)], check=True)
            counts['exact_validated'] += 1
            if res['tex_scales']:
                counts['exact_with_table'] += 1
        else:
            counts['legacy_1x'] += 1
    if not counts['exact_with_table']:
        raise AssertionError('no original exact shader exercised the input-size contract')
    print('Original shader stages:', dict(collections.Counter(job['stage'] for job in jobs)))
    print('Production CPU translation:', dict(counts))
    print('Capability reasons:', dict(reasons))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xlate', type=pathlib.Path, required=True)
    parser.add_argument('--code-dir', type=pathlib.Path, action='append', default=[])
    parser.add_argument('--require-stages', nargs='+', choices=['vs', 'ps', 'cs'], default=['vs', 'ps', 'cs'])
    parser.add_argument('jobs', nargs='+', type=pathlib.Path)
    args = parser.parse_args()
    jobs = []
    digest = hashlib.sha256()
    for source in args.jobs:
        original = source.read_bytes()
        digest.update(original)
        for job in json.loads(original):
            code = pathlib.Path(job['code'])
            candidates = [code, source.parent / code.name] + [root / code.name for root in args.code_dir]
            hit = next((candidate for candidate in candidates if candidate.is_file()), None)
            if hit is None:
                raise FileNotFoundError('original shader code referenced by job is unavailable')
            digest.update(hit.read_bytes())
            jobs.append({**job, 'code': str(hit.resolve())})
    if not jobs or len({job['key'] for job in jobs}) != len(jobs):
        raise AssertionError('empty corpus or duplicate input shader keys')
    if not set(args.require_stages) <= {job['stage'] for job in jobs}:
        raise AssertionError('required original shader stages are absent')
    print('Original jobs and code SHA256:', digest.hexdigest(), flush=True)
    with tempfile.TemporaryDirectory(prefix='s2a-resolution-cpu-') as directory:
        verify(pathlib.Path(directory), jobs, args.xlate)


if __name__ == '__main__':
    main()
