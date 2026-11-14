#!/bin/bash
# 门禁只看：pack/stages/aoc.sh
# 原创目录夹具直接调用生产发布函数；两个后台进程在同一屏障后争用同一键。
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
python3 - "${1:-$R/pack/stages/aoc.sh}" <<'PY'
from pathlib import Path
import subprocess
import sys
import tempfile
import time

source = str(Path(sys.argv[1]).resolve())
failures = []
checks = 0
worker = r'''source "$1"
: > "$4"
for ((i=0; i<1000; i++)); do
  if [ -f "$5" ]; then aoc_cache_publish "$2" "$3"; exit $?; fi
  sleep 0.01
done
echo 'barrier timeout' >&2
exit 2
'''


def check(ok, message):
    global checks
    checks += 1
    if not ok:
        failures.append(message)


def make_stage(path, label):
    (path / 'aoc' / '1').mkdir(parents=True)
    (path / 'aoc.tsv').write_text(label + '\n')
    (path / 'aoc.log').write_text('completed ' + label + '\n')
    (path / 'aoc' / '1' / 'data').write_bytes(label.encode() + bytes(range(256)))
    return snapshot(path)


def snapshot(path):
    return {str(p.relative_to(path)): p.read_bytes() for p in path.rglob('*') if p.is_file()}


def publish(stage, cache):
    return subprocess.run(['/bin/bash', '-c', 'source "$1"; aoc_cache_publish "$2" "$3"',
                           'publish', source, str(stage), str(cache)],
                          capture_output=True, text=True, timeout=10)


def clean_result(cache, stages, expected, message):
    check(cache.is_dir() and snapshot(cache) in expected, message + ': winner bytes unchanged')
    nested = list(cache.rglob('*.tmp.*')) if cache.is_dir() else []
    check(not nested, message + ': no nested staging directory')
    check(len(list(cache.rglob('aoc.tsv'))) == 1, message + ': one aoc.tsv')
    check(all(not p.exists() for p in stages), message + ': own staging paths gone')
    return bool(nested)


with tempfile.TemporaryDirectory(prefix='s2arm-aoc-publish-') as tmp:
    root = Path(tmp)
    cache = root / 'single'
    stage = root / 'single.tmp.only'
    expected = make_stage(stage, 'single')
    check(publish(stage, cache).returncode == 0, 'single publication rc0')
    clean_result(cache, [stage], [expected], 'single')

    # 后到者不能改变先到者的任何字节，即使两份内容不同。
    stage = root / 'single.tmp.late'
    make_stage(stage, 'late')
    check(publish(stage, cache).returncode == 0, 'sequential loser rc0')
    clean_result(cache, [stage], [expected], 'sequential')

    nested_rounds = 0
    for n in range(20):
        base = root / ('race-%02d' % n)
        base.mkdir()
        cache = base / 'cache'
        stages = [base / ('cache.tmp.' + who) for who in ('left', 'right')]
        expected = [make_stage(p, who) for p, who in zip(stages, ('left', 'right'))]
        ready = [base / ('ready-' + str(i)) for i in range(2)]
        start = base / 'start'
        procs = []
        try:
            for stage, mark in zip(stages, ready):
                procs.append(subprocess.Popen(['/bin/bash', '-c', worker, 'publish', source,
                                              str(stage), str(cache), str(mark), str(start)],
                                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
            deadline = time.monotonic() + 10
            while not all(p.exists() for p in ready) and time.monotonic() < deadline:
                time.sleep(0.005)
            check(all(p.exists() for p in ready), 'race %d: both background workers ready' % n)
            start.touch()
            for i, proc in enumerate(procs):
                out, err = proc.communicate(timeout=10)
                check(proc.returncode == 0, 'race %d worker %d rc0: %s%s' % (n, i, out, err))
        finally:
            # Only these fixture processes belong to the test; no process-group signals.
            for proc in procs:
                if proc.poll() is None:
                    proc.terminate()
                    proc.communicate(timeout=5)
        nested_rounds += clean_result(cache, stages, expected, 'race %d' % n)
    print('RACE: 20 background pairs, nested rounds=%d' % nested_rounds)

    # 真正的发布错误不能被当作「别人已经发布成功」吞掉，也不能删除自己的输入。
    for kind in ('file', 'incomplete', 'missing-parent'):
        base = root / kind
        base.mkdir()
        cache = base / 'cache'
        stage = base / 'cache.tmp.own'
        expected = make_stage(stage, kind)
        if kind == 'file':
            cache.write_bytes(b'existing file')
        elif kind == 'incomplete':
            cache.mkdir()
            (cache / 'unrelated').write_bytes(b'not a completed cache')
        else:
            cache = base / 'absent' / 'cache'
        proc = publish(stage, cache)
        check(proc.returncode != 0 and '【红】' in proc.stderr, kind + ': failure is visible')
        check(stage.exists() and snapshot(stage) == expected, kind + ': own input preserved')
        if kind == 'file':
            check(cache.read_bytes() == b'existing file', 'existing file preserved')
        elif kind == 'incomplete':
            check(snapshot(cache) == {'unrelated': b'not a completed cache'}, 'invalid destination preserved')

    # 错传路径或临时目录软链不能授予删除其他目录的权限。
    base = root / 'ownership with spaces'
    base.mkdir()
    cache = base / 'cache'
    make_stage(cache, 'winner')
    winner = snapshot(cache)
    for name in ('other', 'cache.tmp.'):
        stage = base / name
        expected = make_stage(stage, name)
        proc = publish(stage, cache)
        check(proc.returncode != 0 and '【红】' in proc.stderr, name + ': reject unrelated input')
        check(snapshot(stage) == expected and snapshot(cache) == winner, name + ': no cleanup outside own stage')
    link = base / 'cache.tmp.link'
    link.symlink_to(base / 'other', target_is_directory=True)
    proc = publish(link, cache)
    check(proc.returncode != 0 and link.is_symlink(), 'symlink input rejected and retained')
    check(snapshot(base / 'other').get('aoc.tsv') == b'other\n', 'symlink target unchanged')

    # 同款旧键回收：发布新键后同款别的完整缓存只留最新 1 份，6 小时内动过的不碰；别的款、临时目录、不完整目录不碰。
    import os
    base = root / 'prune'
    base.mkdir()
    now = time.time()
    def aged(name, hours, complete=True):
        p = base / name
        if complete:
            make_stage(p, name)
        else:
            (p / 'aoc').mkdir(parents=True)
        for q in [p, *p.rglob('*')]:
            os.utime(q, (now - hours * 3600, now - hours * 3600))
        return p
    olds = {n: aged(n, h) for n, h in (('t01-aaaa~d', 10), ('t01-bbbb~d', 8), ('t01-cccc~d', 1), ('t02-aaaa~d', 10),
                                       ('t03-aaaa~d', 10), ('t03-bbbb~d', 9))}
    tmp = aged('t01-dddd~d.tmp.9', 10)
    partial = aged('t01-eeee~d', 10, complete=False)
    stage = base / 't01-ffff~d.tmp.own'
    make_stage(stage, 'new')
    proc = publish(stage, base / 't01-ffff~d')
    check(proc.returncode == 0, 'prune publish rc0: ' + proc.stderr)
    check((base / 't01-ffff~d' / 'aoc.tsv').is_file(), 'prune: new key published')
    check(olds['t01-cccc~d'].is_dir(), 'prune: newest other key (1 h) kept')
    check(not olds['t01-aaaa~d'].exists() and not olds['t01-bbbb~d'].exists(), 'prune: older keys (>6 h) removed')
    check(olds['t02-aaaa~d'].is_dir(), 'prune: other game untouched')
    check(tmp.is_dir() and partial.is_dir(), 'prune: tmp / incomplete dirs untouched')
    stage = base / 't03-cccc~d.tmp.own'
    make_stage(stage, 'new3')
    proc = publish(stage, base / 't03-cccc~d')
    check(proc.returncode == 0, 'prune all-old publish rc0: ' + proc.stderr)
    check(olds['t03-bbbb~d'].is_dir() and not olds['t03-aaaa~d'].exists(), 'prune: all old → keep newest 1 other, drop rest')

print('aoc_cache_publish: %d checks, %d failures' % (checks, len(failures)))
for failure in failures:
    print('FAIL:', failure)
sys.exit(bool(failures))
PY
