#!/usr/bin/env python3
# 门禁本机：平台无关 Python+Git，本机秒级
"""Location-only release inventory and changed-file gate over committed Git blobs.

No worktree payloads, symlink targets, credentials, pictures or game macros are
opened. Rules, scoped exceptions and content-read boundaries live in the adjacent
reviewable JSON table. A finding is a candidate, never a claim of ownership.
Exit 0: no blocking candidates/boundaries; 1: candidates or unapproved full-scan
boundaries; 2: invalid/incomplete changed scan. Full scan never treats unread
content as scanned: only the existing reasoned allowlist can acknowledge an
ordinary boundary. A separate exact-path, pinned-SHA rule may verify reviewed
third-party ZIP bytes without scanning their contents; credentials, game paths
and non-regular Git entries remain protected.
--base gates content findings on added
lines and metadata findings on new/renamed files; old findings do not block.
"""
import argparse
import codecs
from collections import Counter
import fnmatch
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

RULES_PATH = Path(__file__).with_name('public_repo_scan_rules.json')
MAX_BYTES = 16 * 1024 * 1024
# 可执行 / 库文件头（Mach-O、Mach-O fat、ELF、PE、ar）：白名单外的一律记 build_artifact（构建产物不入仓）
ARTIFACT_MAGIC = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\x7fELF', b'MZ', b'!<arch>')


class ScanError(Exception):
    pass


def git(repo, *args):
    try:
        return subprocess.run(['git', '-c', 'core.quotepath=off', '-C', str(repo), *args],
                              check=True, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL).stdout
    except (OSError, subprocess.CalledProcessError):
        raise ScanError('git_read_failed') from None


def load_rules():
    try:
        rules = json.loads(RULES_PATH.read_text(encoding='utf-8'))
        if rules['version'] != 1:
            raise ValueError
        for row in rules['content_rules']:
            row['compiled'] = re.compile(row['regex'])
            if 'context' in row:
                row['context_compiled'] = re.compile(row['context'])
        for row in rules['path_redaction_rules']:
            row['compiled'] = re.compile(row['regex'])
        for row in rules['allowlist']:
            if not row['reason']:
                raise ValueError
            if 'regex' in row:
                row['compiled'] = re.compile(row['regex'])
            if 'line_regex' in row:
                row['line_compiled'] = re.compile(row['line_regex'])
        archive_paths = set()
        for row in rules.get('reviewed_archives', []):
            if not isinstance(row, dict) or any(
                    not isinstance(row.get(key), str) or not row[key]
                    for key in ('id', 'path', 'sha256', 'reason')):
                raise ValueError
            path = row['path']
            if (not row['id'] or not row['reason'] or not path or path.startswith('/') or
                    '..' in PurePosixPath(path).parts or str(PurePosixPath(path)) != path or
                    any(c in path for c in '*?[]') or path in archive_paths or
                    not re.fullmatch(r'[0-9a-f]{64}', row['sha256'])):
                raise ValueError
            archive_paths.add(path)
        return rules
    except (OSError, ValueError, KeyError, TypeError, re.error):
        raise ScanError('invalid_rules_table') from None


def matches(path, globs):
    return any(fnmatch.fnmatchcase(path, p) for p in globs)


def allowed(category, value, line, path, rules):
    for row in rules['allowlist']:
        if category not in row['categories'] or not matches(path, row['paths']):
            continue
        if 'compiled' in row and not row['compiled'].fullmatch(value):
            continue
        if 'line_compiled' in row and not row['line_compiled'].search(line):
            continue
        return True
    return False


def content_hits(line, path, rules):
    for row in rules['content_rules']:
        if 'context_compiled' in row and not row['context_compiled'].search(line):
            continue
        if row.get('messages_only'):   # 只扫提交信息的规则（内部线名：文件存量待 v0.2.0 后一次清完再打开）
            continue
        if 'paths' in row and not matches(path, row['paths']):   # 只管指定文件的规则（如 README 不写 LibHac / hactool；上游代码里照常有）
            continue
        for match in row['compiled'].finditer(line):
            value = match[row.get('group', 0)]
            if not allowed(row['category'], value, line, path, rules):
                yield row['category'], match.start(row.get('group', 0))


def categories(line, path=''):
    """Small pure helper used by synthetic contracts; values never leave it."""
    return sorted({c for c, _ in content_hits(line, path, load_rules())})


def safe_path(path, rules):
    # Redact identifiers even when a content exception would allow their value.
    # JSON escapes control characters and invalid UTF-8 Git names on emission.
    for row in rules['content_rules'] + rules['path_redaction_rules']:
        path = row['compiled'].sub(lambda m: '<' + row['category'] + '>', path)
    path = re.sub(r'(?<![A-Za-z0-9])(?=[A-Za-z0-9]{10}(?![A-Za-z0-9]))'
                  r'(?=[A-Za-z0-9]*[A-Za-z])(?=[A-Za-z0-9]*[0-9])[A-Za-z0-9]{10}',
                  '<team_id>', path)
    return path


WIN_BAD_CHARS = re.compile(r'[<>:"|?*\\\x00-\x1f]')
WIN_RESERVED = re.compile(r'(?i)^(?:con|prn|aux|nul|com[1-9\u00b9\u00b2\u00b3]|lpt[1-9\u00b9\u00b2\u00b3])$')


def windows_path_illegal(path):
    """True when Windows (NTFS / Win32 checkout) cannot hold this Git path.

    Tianyan, the Windows packing host, checks out the whole tree; one such path
    makes `git checkout` fail with `invalid path` and stops every Windows job
    (11-05: a stray 'R:\\s2a\\work\\lane/me.need'). Per component: no < > : " | ? * \\
    or control characters, no reserved device name (with or without extension),
    no trailing space or dot. Path only; never an allowlist exception."""
    for part in path.split('/'):
        if (WIN_BAD_CHARS.search(part) or part.endswith((' ', '.')) or
                WIN_RESERVED.match(part.split('.', 1)[0].rstrip(' '))):
            return True
    return False


def classify(path, mode, kind, size, rules, read_blob=None):
    boundary = rules['boundaries']
    # Credentials take priority over all metadata/source exceptions.
    parts = PurePosixPath(path).parts
    if (matches(path.lower(), boundary['credential_globs']) or
            any(p.lower() in boundary['credential_directories'] for p in parts)):
        return 'excluded_credentials', []
    if mode not in ('100644', '100755') or kind != 'blob':
        return 'non_regular', []
    metadata = [r['category'] for r in rules['metadata_rules']
                if matches(path.lower(), r['globs'])]
    if metadata:
        return 'metadata_only', [c for c in metadata if not allowed(c, '', '', path, rules)]
    if matches(path, boundary['binary_ascii_globs']):
        return ('binary_ascii' if size <= MAX_BYTES else 'oversized'), []
    p = PurePosixPath(path)
    if matches(path, boundary['reviewed_text_globs']):
        return ('text' if size <= MAX_BYTES else 'oversized'), []
    source_text = (any(path.startswith(d + '/') for d in boundary['source_text_directories']) and
                   (p.suffix.lower() in boundary['text_suffixes'] or p.name in boundary['text_names']))
    if (any(x.lower() in boundary['protected_directories'] for x in parts) or
            matches(path.lower(), boundary['payload_globs']) or
            any(x.lower() in boundary['payload_directories'] for x in parts) and not source_text and
            p.suffix.lower() not in boundary['code_suffixes']):
        return 'excluded_payload', []
    if p.suffix.lower() in boundary['text_suffixes'] or p.name in boundary['text_names']:
        return ('text' if size <= MAX_BYTES else 'oversized'), []
    if not p.suffix:
        if size > MAX_BYTES:
            return 'oversized', []
        if read_blob is not None:
            # Only regular, non-sensitive, size-bounded extensionless blobs reach
            # this probe. List-only supplies no reader and remains metadata-only.
            # Inspect the first 8 KiB: no NUL and valid UTF-8, allowing a character
            # split at the sample boundary. The normal text path still validates
            # the entire blob before scanning any content or emitting findings.
            sample = read_blob()[:8192]
            try:
                if b'\0' in sample:
                    raise UnicodeError
                codecs.getincrementaldecoder('utf-8')().decode(sample, final=size <= 8192)
            except UnicodeError:
                return 'unreviewed_type', []
            return 'text', []
    return 'unreviewed_type', []


def reviewed_archive(path, mode, kind, rules):
    """Exact metadata eligibility only. Never probe protected data for its hash."""
    boundary = rules['boundaries']
    protected = (boundary['credential_directories'] + boundary['protected_directories'] +
                 boundary['payload_directories'])
    if (mode not in ('100644', '100755') or kind != 'blob' or
            PurePosixPath(path).suffix.lower() != '.zip' or
            matches(path.lower(), boundary['credential_globs']) or
            any(p.lower() in protected for p in PurePosixPath(path).parts)):
        return None
    return next((row for row in rules.get('reviewed_archives', []) if row['path'] == path), None)


class Blobs:
    """One lazy Git reader; only already-classified, size-bounded blobs enter it."""
    def __init__(self, repo):
        self.repo, self.proc = repo, None

    def read(self, oid, size):
        try:
            if self.proc is None:
                self.proc = subprocess.Popen(
                    ['git', '-c', 'core.quotepath=off', '-C', str(self.repo),
                     'cat-file', '--batch'], stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            self.proc.stdin.write(oid.encode('ascii') + b'\n')
            self.proc.stdin.flush()
            header = self.proc.stdout.readline().split()
            if header != [oid.encode('ascii'), b'blob', str(size).encode('ascii')]:
                raise ScanError('git_blob_read_failed')
            data = self.proc.stdout.read(size)
            if len(data) != size or self.proc.stdout.read(1) != b'\n':
                raise ScanError('git_blob_read_failed')
            return data
        except (OSError, ValueError):
            raise ScanError('git_blob_read_failed') from None

    def close(self):
        if self.proc is not None:
            self.proc.stdin.close()
            self.proc.stdout.close()
            self.proc.wait()


def resolve(repo, ref):
    try:
        return git(repo, 'rev-parse', '--verify', '--end-of-options',
                   ref + '^{commit}').decode('ascii').strip()
    except (ScanError, UnicodeError):
        raise ScanError('cannot_resolve_revision') from None


def tree_entries(repo, commit):
    entries = {}
    for entry in git(repo, 'ls-tree', '-rlz', commit).split(b'\0'):
        if not entry:
            continue
        try:
            meta, raw_path = entry.split(b'\t', 1)
            mode, kind, oid, size = meta.decode('ascii').split()
            entries[raw_path.decode('utf-8', 'surrogateescape')] = (
                mode, kind, oid, int(size) if size != '-' else 0)
        except (ValueError, UnicodeError):
            raise ScanError('invalid_git_tree') from None
    return entries


def changed_paths(repo, base, commit):
    # Exact renames use object identity only: never ask Git to inspect payloads
    # for similarity. NUL framing also handles tabs/newlines in Git paths.
    fields = git(repo, 'diff', '--name-status', '-z', '--find-renames=100%',
                 '--diff-filter=ACMRTUXB', base, commit).split(b'\0')
    changes, renames = set(), {}
    i = 0
    while i < len(fields) and fields[i]:
        status = fields[i].decode('ascii')
        old = fields[i + 1].decode('utf-8', 'surrogateescape')
        i += 2
        if status.startswith(('R', 'C')):
            path = fields[i].decode('utf-8', 'surrogateescape')
            i += 1
            renames[path] = old
        else:
            path = old
        changes.add(path)
    return changes, renames


def added_line_ranges(repo, old_oid, new_oid):
    # Both object IDs must already be classified as bounded readable content.
    # Disable user diff drivers/textconv and parse hunk headers only; no raw
    # lines or values enter reports. Blob diff avoids pathspec ambiguity.
    diff = git(repo, 'diff', '--no-ext-diff', '--no-textconv', '--text',
               '--unified=0', '--inter-hunk-context=0', '--no-color', old_oid, new_oid)
    return [(int(m[1]), int(m[2] or b'1')) for m in
            re.finditer(rb'^@@ -[0-9]+(?:,[0-9]+)? \+([0-9]+)(?:,([0-9]+))? @@',
                        diff, re.MULTILINE)]


def scan(repo, ref, paths, list_only=False, base=None):
    if not paths or any(not p or p.startswith('/') or
                        '..' in PurePosixPath(p).parts for p in paths):
        raise ScanError('explicit_relative_paths_required')
    paths = sorted(set(str(PurePosixPath(p)) for p in paths))
    repo = Path(repo).resolve()
    try:
        top = git(repo, 'rev-parse', '--show-toplevel').decode().rstrip('\n')
        if Path(top).resolve() != repo:
            raise ScanError('repo_must_be_root')
    except (ScanError, UnicodeError):
        raise ScanError('repo_must_be_root') from None
    rules = load_rules()
    commit = resolve(repo, ref)
    base_commit, changed, renames, baseline = None, set(), {}, {}
    if base is not None:
        base_commit = resolve(repo, base)
        try:
            base_commit = git(repo, 'merge-base', base_commit, commit).decode().strip()
            changed, renames = changed_paths(repo, base_commit, commit)
            baseline = tree_entries(repo, base_commit)
        except ScanError:
            raise ScanError('cannot_resolve_baseline') from None
    matched_paths = {p for p in paths if p == '.'}
    findings, manifest, uncovered = [], [], []
    uncovered_blocking, uncovered_allowed = [], []
    counts = Counter()
    reader = Blobs(repo)
    try:
        for path, (mode, kind, oid, size) in tree_entries(repo, commit).items():
            matching = {p for p in paths if p == '.' or p == path or path.startswith(p + '/')}
            matched_paths.update(matching)
            if not matching:
                counts['outside_selection'] += 1
                continue
            decision, meta_categories = classify(
                path, mode, kind, size, rules,
                read_blob=None if list_only else lambda: reader.read(oid, size))
            display = safe_path(path, rules)
            state = 'changed' if path in changed else 'existing'
            location = {'path': display, 'status': state}
            if list_only:
                manifest.append({**location, 'decision': decision, 'size': size})
                counts[decision] += 1
                continue
            if decision in ('binary_ascii', 'unreviewed_type') and size >= 4 and \
                    '.' not in path.rsplit('/', 1)[-1] and \
                    not matches(path, rules['boundaries'].get('build_artifact_allow_globs', [])) and \
                    reader.read(oid, size)[:8].startswith(ARTIFACT_MAGIC):
                meta_categories = meta_categories + ['build_artifact']
            for category in meta_categories + (['windows_path'] if windows_path_illegal(path) else []):
                findings.append({**location, 'status': 'changed' if path in changed and
                                 (path not in baseline or path in renames) else 'existing',
                                 'category': category, 'location': 'git_metadata'})
            if decision in ('text', 'binary_ascii'):
                ranges = None
                old = baseline.get(renames.get(path, path))
                if path in changed and old is not None:
                    old_mode, old_kind, old_oid, old_size = old
                    old_decision, _ = classify(renames.get(path, path), old_mode,
                                               old_kind, old_size, rules,
                                               read_blob=lambda: reader.read(old_oid, old_size))
                    if old_decision == decision:
                        ranges = added_line_ranges(repo, old_oid, oid)
                data = reader.read(oid, size)
                if decision == 'text':
                    try:
                        if b'\0' in data:
                            raise UnicodeError
                        text = data.decode('utf-8')
                    except UnicodeError:
                        decision = 'unreviewed_binary_or_encoding'
                    else:
                        for number, line in enumerate(text.split('\n'), 1):
                            for category in sorted({c for c, _ in content_hits(line, path, rules)}):
                                findings.append({**location, 'status': 'changed' if path in changed and
                                                 (ranges is None or any(start <= number < start + count
                                                                        for start, count in ranges))
                                                 else 'existing',
                                                 'line': number, 'category': category})
                else:
                    # strings -a semantics, without executing or decoding the binary.
                    seen = set()
                    for run in re.finditer(rb'[\x20-\x7e]{4,}', data):
                        for category, start in content_hits(run[0].decode('ascii'), path, rules):
                            item = (run.start() + start, category)
                            if item not in seen:
                                number = data.count(b'\n', 0, item[0]) + 1
                                findings.append({**location, 'status': 'changed' if path in changed and
                                                 (ranges is None or any(start <= number < start + count
                                                                        for start, count in ranges))
                                                 else 'existing',
                                                 'offset': item[0], 'category': category})
                                seen.add(item)
            counts[decision] += 1
            if decision not in ('text', 'binary_ascii', 'metadata_only'):
                item = {**location, 'reason': decision}
                archive = reviewed_archive(path, mode, kind, rules) if decision == 'excluded_payload' else None
                verified = archive is not None and size <= MAX_BYTES and \
                    hashlib.sha256(reader.read(oid, size)).hexdigest() == archive['sha256']
                if verified:
                    item['reviewed_archive'] = archive['id']
                uncovered.append(item)
                if archive is not None:
                    # Hash verification is not content coverage. A changed pinned
                    # archive must fail too, rather than becoming a delta warning.
                    (uncovered_allowed if verified else uncovered_blocking).append(item)
                elif base is None:
                    # Reuse the one reviewed policy table, without opening the
                    # blob or changing its coverage classification. Protected
                    # material cannot be waived by even a matching rule.
                    protected = decision in ('excluded_credentials', 'excluded_payload', 'non_regular')
                    if not protected and allowed('uncovered_' + decision, '', '', path, rules):
                        uncovered_allowed.append(item)
                    else:
                        uncovered_blocking.append(item)
    finally:
        reader.close()
    if matched_paths != set(paths):
        raise ScanError('requested_path_not_found')
    findings.sort(key=lambda f: (f['path'], f.get('line', -1), f.get('offset', -1), f['category']))
    blocking = [f for f in findings if base is None or f['status'] == 'changed']
    incomplete = [f for f in uncovered if f['status'] == 'changed' and
                  f['reason'] == 'excluded_credentials']
    warnings = [f for f in uncovered if f['status'] == 'changed' and
                f['reason'] != 'excluded_credentials']
    return {'commit': commit, 'base': base_commit, 'scope': 'committed_git_inventory',
            'requested_paths': [safe_path(p, rules) for p in paths], 'list_only': list_only,
            'coverage': dict(sorted(counts.items())), 'findings': findings,
            'blocking_count': len(blocking), 'incomplete_changed': incomplete,
            'warnings_changed': warnings, 'uncovered': uncovered, 'manifest': manifest,
            'uncovered_blocking': uncovered_blocking, 'uncovered_allowed': uncovered_allowed}


MESSAGE_CATEGORIES = ('internal_name',)   # 提交信息查内部称呼（维护者账号 / 内部线名 / 设备代号 / 私有主机），外加规则里写了 "messages": true 的（第一方游戏名，11-09 晚：#371 提交标题漏过）；其余路径限定的规则不适用于提交信息


def scan_messages(repo, ref, base):
    """提交信息扫描（11-09 维护方：公开仓扫描只查文件，main 提交信息里漏进内部线名 / 设备代号这类内部称呼）：
    base..ref 每条提交信息逐行用同一份 content_rules 里 internal_name 类判；返回 [(短提交号, 行号, 规则 id)]，命中的词本身不外泄"""
    rules = load_rules()
    rows = [r for r in rules['content_rules'] if r['category'] in MESSAGE_CATEGORIES or r.get('messages')]
    revs = git(repo, 'rev-list', f'{base}..{ref}').decode().split()
    hits = []
    for rev in revs:
        msg = git(repo, 'log', '-1', '--format=%B', rev).decode('utf-8', 'replace')
        for n, line in enumerate(msg.splitlines(), 1):
            for row in rows:
                if 'context_compiled' in row and not row['context_compiled'].search(line):
                    continue
                for match in row['compiled'].finditer(line):
                    if not allowed(row['category'], match[row.get('group', 0)], line, '', rules):
                        hits.append((rev[:9], n, row['id'])); break
    return hits, len(revs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--ref', default='HEAD')
    parser.add_argument('--path', action='append', required=True,
                        help='explicit relative file/directory; . selects the whole tree')
    parser.add_argument('--base', help='gate against merge-base; omit for inventory')
    parser.add_argument('--list-only', action='store_true', help='metadata only; never reads blobs')
    parser.add_argument('--format', choices=('json', 'gate'), default='json')
    parser.add_argument('--report', help='write location-only JSON (e.g. build/public_repo_scan.json)')
    parser.add_argument('--messages', metavar='BASE', help='只扫 BASE..REF 的提交信息（内部称呼），命中退 1；列车入队预检用')
    args = parser.parse_args()
    if args.messages:
        try:
            hits, n = scan_messages(args.repo, args.ref, args.messages)
        except (ScanError, OSError, subprocess.CalledProcessError) as exc:
            print(f'【红】提交信息扫描没跑成：{exc}'); return 2
        for rev, line, rid in hits:
            print(f'🔴 提交 {rev} 信息第 {line} 行：' + ('任天堂第一方游戏名' if rid == 'compliance_first_party_titles' else '内部称呼') + f'（规则 {rid}）')
        if hits:
            print('提交信息里不许出现内部称呼与任天堂第一方游戏名：内部称呼改成「维护者 / Windows 实机 / Mac 实机」等通用说法，'
                  '游戏名改成泛指（「一款大型开放世界游戏」）或只写程序号；用 git rebase -i <基线> 把对应提交标成 reword 改信息后重新入队')
        print(f'提交信息扫描：{n} 条提交，命中 {len(hits)} 处')
        return 1 if hits else 0
    try:
        report = scan(args.repo, args.ref, args.path, args.list_only, args.base)
        encoded = json.dumps(report, ensure_ascii=True, indent=2) + '\n'
        if args.report:
            dest = Path(args.report)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(encoded, encoding='utf-8')
    except (ScanError, OSError) as exc:
        print(json.dumps({'error': str(exc) if isinstance(exc, ScanError) else 'report_write_failed'}))
        return 2
    if args.format == 'json':
        print(encoded, end='')
    else:
        for f in report['findings']:
            if args.base and f['status'] != 'changed':
                continue
            # JSON-quoted paths cannot inject log lines or terminal controls.
            print('{}:{}: {}'.format(json.dumps(f['path'], ensure_ascii=True),
                  f.get('line', 'offset=' + str(f['offset']) if 'offset' in f else 'metadata'), f['category']))
        for f in report['incomplete_changed']:
            print('{}:uncovered: {}'.format(json.dumps(f['path'], ensure_ascii=True), f['reason']))
        for f in report['warnings_changed']:
            print('【黄】{}:uncovered: {}'.format(json.dumps(f['path'], ensure_ascii=True), f['reason']))
        for f in report['uncovered_blocking']:
            print('{}:uncovered: {}'.format(json.dumps(f['path'], ensure_ascii=True), f['reason']))
        for f in report['uncovered_allowed']:
            if 'reviewed_archive' in f:
                print('{}:reviewed_archive: SHA-256 已核对（仍未扫描正文）'.format(
                    json.dumps(f['path'], ensure_ascii=True)))
        if args.base is None:
            print('全量公开仓扫描：候选 {}，未读阻挡 {}，有理由保留未读 {}（仍未扫描正文）'.format(
                report['blocking_count'], len(report['uncovered_blocking']), len(report['uncovered_allowed'])))
        else:
            print('公开仓扫描：增量命中 {}，存量命中 {}，增量未覆盖 {}，增量未审类型 {}；全量清单含未覆盖边界'.format(
                report['blocking_count'], sum(f['status'] == 'existing' for f in report['findings']),
                len(report['incomplete_changed']),
                sum(f['reason'] == 'unreviewed_type' for f in report['warnings_changed'])))
    if report['blocking_count'] or report['uncovered_blocking']:
        return 1
    return 2 if report['incomplete_changed'] else 0


if __name__ == '__main__':
    sys.exit(main())
