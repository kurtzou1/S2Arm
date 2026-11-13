# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Differential oracle for DiagnosticRedactor: random synthetic lines through tools/redact.py.

Writes TSV lines `input<TAB>expected` (backslash, tab, CR and LF escaped). Expected values come
from the shared stdlib implementation, not from the Java code under test. Inputs avoid the
Android-only rules (shared storage, other app data, content URIs), which tools/redact.py does
not have. Never reads key files: the key values are fixed synthetic ones, also given to Java.
"""
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'tools'))
import redact  # noqa: E402

KEYS = ('00112233445566778899aabbccddeeff', 'fedcba9876543210fedcba9876543210ffeeddcc')
FRAGMENTS = [
    'S2Arm: ', ' ', '  ', '\t', '\n', '\r\n', '\r', ',', ';', '}', ']', '[', '{', '"', "'", ':', '=', '\\', '/',
    'host.log', 'frame 12', 'version 1.2.3 build 456', '程序号 0100aabbccdd0000', '中文日志', '💠', '²', '\u00a0', '\u2028', '\x85',
    '\x01', '\x7f', '\u212a', '\u017f', 'Ｋ',
    'synth.user+diag@example.invalid', 'contact=synth@example.invalid', 'a=b@example.invalid', 'not-an-email@localhost',
    "o'brien@example.invalid", 'reply-to: a/b@example.invalid',
    'DEVELOPMENT_TEAM = ABCDE12345', 'Signing with team ABCDE12345.', 's2arm.abcde12345.0100aabbccdd0000',
    'device ', 'serial ', 'udid ',
    '0123456789abcdef0123456789abcdef01234567', '0123456789ABCDEF0123456789ABCDEF', 'commit ',
    '合成甲的iPhone', '合成乙的iPad', 'iPhone iPad',
    '{"serial":"ab\\"PrivateTail","ok":true}', "serial='ab\\'PrivateTail'", 'serial="Private Tail', '"serial":""',
    'device_id="Private Tail"', 'device_model=public', 'uuid=serial: PRIVATE', 'serial=ab]PrivateTail', 'tester=Synth',
    'prod_key = ' + KEYS[0], 'header_key=' + KEYS[1], KEYS[0], KEYS[1].upper(), 'master_key_00 = ' + 'ab' * 16,
    'title_kek=0011', 'my_keys=1', 'keyblob_00: zz', 'password: hunter2', 'api-key=xyz', 'Authorization: Bearer synth.token',
    'cookie=a=b', 'https://user:pass@example.invalid/x', 'https://example.invalid/a?token=abc&x=1', '&session=zz#f',
    '/private/var/Game Disk/S2Arm 库/a.bfttf: Operation not permitted', '/private/var/joe/x: No such file or directory',
    'cp: /private/var/joe/a: clonefile failed: Cross-device link', '/Volumes/<synth>/Games/x.nsp', '/var/mobile/Containers/x',
    # Home directories carry a <synth> placeholder: the path rule still fires, and no literal user name is committed
    # (tools/public_repo_scan.py blocks those outside its allowlist).
    '/data/user/0/org.example/files/x', '/data/data/org.example/y', '/Users/<synth>/Library/Logs/a.log', '/home/<synth>/.cache/x',
    'C:\\Users\\<synth>\\AppData\\x.log', 'D:/Documents/x', '\\\\server\\share\\dir\\f', '\\\\\\\\server\\\\share',
    '123e4567-e89b-12d3-a456-426614174000', 'ab' * 40, 'x' + 'cd' * 33, '_' + 'ef' * 32,
]


def shared_inputs():
    """The shared fixture's inputs join the fragments (its synthetic device ids are allowlisted only there)."""
    lines = (Path(__file__).resolve().parents[3] / 'tests' / 'fixtures' / 'redact_cases.tsv').read_text(encoding='utf-8').splitlines()
    return [line.split('\t')[1] for line in lines[1:] if line and not line.startswith('#')]


def esc(s):
    return s.replace('\\', '\\\\').replace('\t', '\\t').replace('\r', '\\r').replace('\n', '\\n')


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
    fragments = FRAGMENTS + shared_inputs()
    rng = random.Random(20261112)
    out = sys.stdout
    for _ in range(count):
        text = ''.join(rng.choice(fragments) for _ in range(rng.randint(1, 12)))
        out.write(esc(text) + '\t' + esc(redact.redact_text(text, key_values=KEYS)) + '\n')


if __name__ == '__main__':
    main()
