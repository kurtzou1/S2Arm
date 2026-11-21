#!/usr/bin/env python3
"""Bounded, offline diagnostic collector. See docs/测试报告与诊断收集.md."""
import argparse
import csv
import hashlib
import html
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tempfile
import zipfile

import beta_intake
import score_cells
from redact import SECRET, load_key_values, redact_text

MAX_FILES = 1000
MAX_FILE = 16 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
FIELDS = {
    'task': ('id', 'platform'),
    'code': ('commit',),
    'package': ('id', 'version', 'commit', 'sha256', 'switches', 'signing', 'build_id', 'target_arch'),
    'game': ('name', 'id', 'version', 'updates', 'dlc'),
    'device': ('model', 'soc', 'memory', 'os', 'gpu_family'),
    'test': ('steps', 'scene', 'route', 'save_id'),
    'reproduction': ('shortest_steps', 'first_failure'),
    'untested': ('items', 'reason'),
}


def undo_double_utf8(text):
    """iOS 0.6.3 及更早的诊断包：往局日志里有一处坏字节（宿主按字节截断的长行切在汉字中间），客户端整份按 Latin-1 解再存成 UTF-8，
    中文全成二次编码乱码（「写回原值」→「å\x86\x99…」，264 份诊断中招；ios/diagcollect.m 已改成坏字节就地换 U+FFFD）。
    这里认出这种整份二次编码的文本并还原：字符全在 U+0000–U+00FF、按 Latin-1 还原成字节后基本是合法 UTF-8（坏字节不到解出的非 ASCII 字符的 1/20、
    且至少 3 个），才换；真的西文（如 café）还原不出合法 UTF-8，原样不动"""
    if not any('\x80' <= ch <= '\xff' for ch in text):
        return text
    try:
        raw = text.encode('latin-1')
    except UnicodeEncodeError:
        return text
    fixed = raw.decode('utf-8', errors='replace')
    wide = sum(1 for ch in fixed if ord(ch) > 0x7f)
    bad = fixed.count('\ufffd')
    return fixed if wide >= 3 and bad * 20 < wide else text


def sanitize(value, path=(), identity_model=False, key_values=None):
    if isinstance(value, dict):
        return {redact_text(k, key_values=key_values): '[REDACTED]' if SECRET.search(str(k)) else sanitize(v, path + (str(k),), identity_model, key_values) for k, v in value.items()}
    if isinstance(value, list):
        return [sanitize(v, path, identity_model, key_values) for v in value]
    if isinstance(value, str):
        identity = identity_model and (
            path in (('package', 'sha256'), ('app', 'sha256'), ('evidence', 'sha256')) and re.fullmatch(r'[0-9a-fA-F]{64}', value) or
            path in (('code', 'commit'), ('package', 'commit'), ('app', 'commit')) and re.fullmatch(r'[0-9a-fA-F]{7,40}', value) or
            path == ('game', 'id') and re.fullmatch(r'[0-9a-fA-F]{16}', value))
        return redact_text(value, key_values=key_values, preserve_identity=identity)
    return value


def kind(name):
    p = PurePosixPath(name)
    if p.name == 'manifest.json' and len(p.parts) == 1:
        return 'manifest'
    if p.parts[0] in ('keys', 'saves', 'games', 'resources'):
        return None
    if p.suffix.lower() in ('.png', '.jpg', '.jpeg', '.mp4', '.mov', '.webm') and p.parts[0] in ('shots', 'screenshots', 'videos', 'media', 'logs'):
        return 'media'
    if len(p.parts) == 2 and p.parts[0] == 'metrickit' and p.suffix == '.json':
        return 'metrickit'
    if p.parts[0] == 'jobs' and p.suffix == '.txt':
        return 'job'
    if (len(p.parts) == 1 or p.parts[0] == 'logs') and (p.name in ('host.log', 'run.log', 'frames.tsv', 'ap_summary.json', 'pwh.plist', 'pw1.plist', 'cold_start.txt', 'threads.txt') or re.fullmatch(r'host\.prev\d*\.log', p.name)):
        return 'diagnostic'
    if p.parts[0] == 'logs' and p.suffix == '.log':
        return 'log'
    return None


def valid_name(name):
    p = PurePosixPath(name)
    if not name or not p.parts or '\\' in name or p.is_absolute() or '..' in p.parts or re.match(r'^[A-Za-z]:', name):
        raise ValueError('unsafe input path')
    return p.as_posix()


def collect(source):
    """Read only allowlisted diagnostics; media are hashed but never copied."""
    result = {}
    total = 0

    def add(name, size, read):
        nonlocal total
        if size > MAX_FILE:
            raise ValueError('input file size limit exceeded')
        total += size
        if total > MAX_TOTAL:
            raise ValueError('input total size limit exceeded')
        k = kind(name)
        if k:
            data = read()
            if len(data) != size:
                raise ValueError('input changed during collection')
            result[name] = (k, data)

    if source.is_dir():
        if not all(hasattr(os, flag) for flag in ('O_DIRECTORY', 'O_NOFOLLOW', 'O_NONBLOCK')) or os.open not in os.supports_dir_fd or os.stat not in os.supports_dir_fd or os.listdir not in os.supports_fd:
            raise ValueError('secure directory descriptor traversal is unsupported')
        count = 0
        directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW

        def visit(directory_fd, parts=()):
            nonlocal count
            if len(parts) > 32:
                raise ValueError('input directory depth limit exceeded')
            for filename in sorted(os.listdir(directory_fd)):
                if filename.startswith('.') or filename in ('keys', 'games', 'saves', 'resources'):
                    continue
                info = os.stat(filename, dir_fd=directory_fd, follow_symlinks=False)
                if stat.S_ISLNK(info.st_mode):
                    continue
                if stat.S_ISDIR(info.st_mode):
                    if not parts and filename not in ('logs', 'jobs', 'shots', 'screenshots', 'videos', 'media', 'metrickit'):
                        continue
                    child = os.open(filename, directory_flags, dir_fd=directory_fd)
                    try:
                        opened = os.fstat(child)
                        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                            raise ValueError('input directory changed during collection')
                        visit(child, parts + (filename,))
                    finally:
                        os.close(child)
                    continue
                name = valid_name('/'.join(parts + (filename,)))
                if not stat.S_ISREG(info.st_mode) or not kind(name):
                    continue
                count += 1
                if count > MAX_FILES:
                    raise ValueError('input file count limit exceeded')
                fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
                with os.fdopen(fd, 'rb') as stream:
                    opened = os.fstat(stream.fileno())
                    if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                        raise ValueError('input file changed during collection')
                    def read():
                        data = stream.read(MAX_FILE + 1)
                        after = os.fstat(stream.fileno())
                        if (after.st_size, after.st_mtime_ns) != (opened.st_size, opened.st_mtime_ns):
                            raise ValueError('input file changed during collection')
                        return data
                    add(name, opened.st_size, read)

        root_fd = os.open(source, directory_flags)
        wrapper_fd = None
        try:
            names = [n for n in os.listdir(root_fd) if not n.startswith('.')]
            if len(names) == 1 and names[0] not in ('keys', 'games', 'saves', 'resources', 'logs', 'jobs', 'metrickit', 'shots', 'screenshots', 'videos', 'media'):
                candidate = valid_name(names[0])
                info = os.stat(candidate, dir_fd=root_fd, follow_symlinks=False)
                if stat.S_ISDIR(info.st_mode):
                    wrapper_fd = os.open(candidate, directory_flags, dir_fd=root_fd)
                    opened = os.fstat(wrapper_fd)
                    if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                        raise ValueError('input directory changed during collection')
                    try:
                        manifest_info = os.stat('manifest.json', dir_fd=wrapper_fd, follow_symlinks=False)
                    except FileNotFoundError:
                        manifest_info = None
                    if manifest_info is None or not stat.S_ISREG(manifest_info.st_mode):
                        os.close(wrapper_fd)
                        wrapper_fd = None
            visit(wrapper_fd if wrapper_fd is not None else root_fd)
        finally:
            if wrapper_fd is not None:
                os.close(wrapper_fd)
            os.close(root_fd)
    else:
        with zipfile.ZipFile(source) as z:
            infos = z.infolist()
            if len(infos) > MAX_FILES:
                raise ValueError('input file count limit exceeded')
            raw_seen, decoded_seen, entries = set(), set(), []
            # Check original and recovered names before any allowlist or member read.
            for item in infos:
                raw = valid_name(item.filename)
                decoded = item.filename
                if not item.flag_bits & 0x800:
                    try:
                        decoded = decoded.encode('cp437').decode('utf-8')
                    except (UnicodeEncodeError, UnicodeDecodeError):
                        pass
                name = valid_name(decoded)
                if raw in raw_seen or name in decoded_seen or stat.S_ISLNK(item.external_attr >> 16):
                    raise ValueError('duplicate or linked ZIP member')
                raw_seen.add(raw)
                decoded_seen.add(name)
                entries.append((name, item))
                if item.file_size > MAX_FILE:
                    raise ValueError('input file size limit exceeded')
            if sum(i.file_size for i in infos) > MAX_TOTAL:
                raise ValueError('input total size limit exceeded')
            file_names = [name for name, item in entries if not item.is_dir()]
            roots = {PurePosixPath(name).parts[0] for name in file_names}
            wrapper = next(iter(roots)) if len(roots) == 1 else None
            if wrapper and (wrapper in ('keys', 'games', 'saves', 'resources', 'logs', 'jobs', 'metrickit', 'shots', 'screenshots', 'videos', 'media') or wrapper + '/manifest.json' not in file_names):
                wrapper = None
            normalized_seen, normalized = set(), []
            for name, item in entries:
                if wrapper:
                    if name == wrapper and item.is_dir():
                        continue
                    if not name.startswith(wrapper + '/'):
                        raise ValueError('ambiguous ZIP wrapper')
                    name = valid_name(name[len(wrapper) + 1:])
                if name in normalized_seen:
                    raise ValueError('duplicate normalized ZIP member')
                normalized_seen.add(name)
                normalized.append((name, item))
            for name, item in normalized:
                if not item.is_dir():
                    add(name, item.file_size, lambda item=item: z.read(item))
    return result


def load_object(data):
    obj = json.loads(data, parse_constant=lambda value: (_ for _ in ()).throw(ValueError('non-finite JSON number')))
    if not isinstance(obj, dict):
        raise ValueError('expected JSON object')
    return obj


def metadata_model(manifest, metadata):
    model, sources, missing = {}, {}, []
    aliases = {'package': 'app'}
    for section, fields in FIELDS.items():
        model[section] = {}
        for field in fields:
            key = section + '.' + field
            value, origin = None, 'missing'
            for obj, label in ((manifest, 'manifest.json'), (metadata, 'metadata')):
                if obj is manifest and manifest.get('schema') == 1:
                    mappings = {('code', 'commit'): ('app', 'commit'), ('package', 'id'): ('app', 'bundle'), ('game', 'id'): ('game', 'title_id'), ('device', 'memory'): ('device', 'ram_mb'), ('package', 'build_id'): ('app', 'build_id'), ('package', 'target_arch'): ('app', 'pso_target')}
                    producer_key = mappings.get((section, field))
                    if producer_key:
                        parent, child = producer_key
                        producer_section = obj.get(parent, {})
                        if isinstance(producer_section, dict) and child in producer_section:
                            value, origin = producer_section[child], label + ':' + parent + '.' + child
                            if (section, field) == ('device', 'memory'):
                                value = f'{value} MiB' if type(value) in (int, float) and value >= 0 else None
                origin_section = section if section in obj else aliases.get(section, section)
                sub = obj.get(section, obj.get(aliases.get(section, ''), {}))
                if isinstance(sub, dict) and field in sub and not (section == 'package' and field == 'target_arch' and origin_section == 'app'):
                    value, origin = sub[field], label + ':' + origin_section + '.' + field
                if section == 'device' and field == 'os' and isinstance(sub, dict) and 'ios' in sub and 'os' not in sub:
                    value, origin = sub['ios'], label + ':device.ios'
            if isinstance(value, str) and not value.strip() or value in ([], {}) and (section, field) not in (('game', 'updates'), ('game', 'dlc'), ('package', 'switches'), ('untested', 'items')):
                value = None
            model[section][field] = value
            sources[key] = origin
            if value is None:
                missing.append(key)
    return model, sources, missing


def analyze_session(name, data, files, warnings, truncated=()):
    with tempfile.TemporaryDirectory(prefix='s2arm-report-score-') as tmp:
        # Two empty ancestor levels isolate infra and any future scene baseline scan.
        out = Path(tmp) / 'isolated' / 'session'
        out.mkdir(parents=True)
        (out / 'host.log').write_bytes(data)
        current = PurePosixPath(name).name == 'host.log'
        if current:
            parent = str(PurePosixPath(name).parent)
            for basename in ('frames.tsv', 'run.log', 'ap_summary.json', 'pwh.plist', 'pw1.plist', 'cold_start.txt'):
                candidate = basename if parent == '.' else parent + '/' + basename
                if candidate in files:
                    (out / basename).write_bytes(files[candidate][1])
        s = beta_intake.session(str(out / 'host.log'), strict_firstuse=True)
        heartbeat = bool(re.search(r'\[心跳\] 帧 \d+，热状态 \d+.*?进程实占 \d+ MB', data.decode(errors='replace')))
        if not heartbeat:
            for field in ('帧数', '热状态最高', '实占峰值MB'):
                s[field] = None
        try:
            frames = out / 'frames.tsv'
            if frames.exists():
                rows = list(csv.DictReader(io.StringIO(frames.read_text(errors='replace')), delimiter='\t'))
                if not rows or not {'frame', 'wall_us'}.issubset(rows[0]) or any(None in r or not str(r.get('frame', '')).isdigit() or not str(r.get('wall_us', '')).isdigit() for r in rows) or any(not str(r.get(k, '')).isdigit() for r in rows for k in r if k in ('frame', 'wall_us', 'gpu_us', 'macro_us', 'xlate_n', 'pso_n', 'shader_miss') and r[k] not in ('', None)):
                    raise ValueError('invalid frame table')
            cells, reading, reasons = score_cells.cells(str(out), '')
            bad = score_cells.infra(str(out)) or score_cells.test_unready(str(out)) or score_cells.fps_basis(str(out))
            status = 'invalid' if bad else 'unknown'
            if bad:
                cells = {k: '—' for k in cells}
            scores = {k: {'status': {'绿': 'pass', '红': 'fail', '未测': 'not_tested', '—': 'invalid'}.get(v, 'unknown'), 'legacy': v, 'reason': bad or reasons.get(k)} for k, v in cells.items()}
        except (ValueError, TypeError, KeyError, IndexError, ArithmeticError):
            status, reading, bad = 'invalid', None, 'invalid diagnostic data'
            scores = {k: {'status': 'invalid', 'legacy': '—', 'reason': bad} for k in ('能玩', '画面', '帧率', '能耗', '首局', '分配')}
            warnings.append({'source': name, 'message': bad})
        text = data.decode(errors='replace')
        if not text.strip():
            status, reading, bad = 'not_tested', None, None
            scores = {k: {'status': 'not_tested', 'legacy': '未测', 'reason': 'host log is empty; execution evidence unavailable'} for k in ('能玩', '画面', '帧率', '能耗', '首局', '分配')}
            s['首遇现编'] = None
            warnings.append({'source': name, 'message': 'host log is empty; execution evidence unavailable'})
        peaks = re.findall(r'\[声\] 稳态窗口：输出峰值 ([0-9.]+)', text)
        sound = ('pass' if float(peaks[-1]) > 0 else 'fail') if peaks else 'not_tested'
        relevant = {name}
        if current:
            relevant.update((str(PurePosixPath(name).parent / f) for f in ('frames.tsv', 'run.log', 'ap_summary.json', 'pwh.plist', 'pw1.plist', 'cold_start.txt', 'threads.txt', 'unpack.log')))
        partial = sorted(relevant.intersection(truncated))
        if partial and text.strip():
            status, reading, bad = 'invalid', None, 'producer marked diagnostic evidence truncated; complete-session scoring unavailable'
            scores = {k: {'status': 'invalid', 'legacy': '—', 'reason': bad} for k in ('能玩', '画面', '帧率', '能耗', '首局', '分配')}
            sound = 'unknown'
            warnings.append({'source': name, 'message': bad})
        if status != 'invalid':
            status = scores.get('能玩', {}).get('status', 'unknown')
        return dict(source=name, status=status, evidence_completeness='partial' if partial else 'unspecified', truncated_files=partial, observations=s, scores=scores, reading=reading, invalid_reason=bad or None,
                    operability=scores.get('能玩', {'status': 'unknown'}), picture=scores.get('画面', {'status': 'not_tested'}),
                    sound={'status': sound}, frame_time_stutter=scores.get('帧率', {'status': 'not_tested'}),
                    termination={'status': 'fail' if s['结局'] == 'crash' else 'unknown', 'kind': s['结局']},
                    heartbeat_status='observed' if heartbeat else 'unknown',
                    firstuse_status='unknown' if s['首遇现编'] is None else 'partial' if partial else 'observed',
                    frame_source='same-session' if current and (out / 'frames.tsv').exists() else None)


def markdown(report):
    # One model, rendered as escaped text; no untrusted Markdown or active links.
    lines = ['# 测试报告（schema 1）', '', '正常退出或诊断任务完成不代表游戏通过。媒体仅索引，分享前须人工审查。', '']
    def walk(value, prefix=''):
        if isinstance(value, dict):
            for key, item in value.items():
                walk(item, prefix + '.' + key if prefix else key)
        elif isinstance(value, list):
            if not value:
                lines.append(html.escape(prefix) + ': []  ')
            for index, item in enumerate(value):
                walk(item, f'{prefix}[{index}]')
        else:
            text = json.dumps(value, ensure_ascii=False)
            # Escape all Markdown metacharacters as numeric entities after HTML escaping.
            escaped = html.escape(prefix + ': ' + text)
            escaped = re.sub(r'([\\`*_{}\[\]()#+.!|>~-])', lambda m: '&#%d;' % ord(m[0]), escaped)
            lines.append(escaped.replace('\n', '<br>') + '  ')
    walk(report)
    return '\n'.join(lines) + '\n'


def generate(source, output, metadata=None, key_paths=None):
    source, output = Path(source).absolute(), Path(output).absolute()
    if source.is_symlink() or not source.exists():
        raise ValueError('input must be an existing non-linked directory or ZIP')
    source, output = source.resolve(), output.resolve()
    if output == source or source in output.parents or output in source.parents or output.exists():
        raise ValueError('output must be a new directory outside input')
    meta = {}
    if metadata is not None:
        p = Path(metadata)
        if p.is_symlink() or p.stat().st_size > MAX_FILE:
            raise ValueError('invalid metadata')
        meta = load_object(p.read_bytes())
    key_values = load_key_values(key_paths)
    files = collect(source)
    warnings = []
    manifest = {}
    if 'manifest.json' in files:
        try:
            manifest = load_object(files['manifest.json'][1])
        except (ValueError, UnicodeError):
            warnings.append({'source': 'manifest.json', 'message': 'invalid JSON object'})
    model, sources, missing = metadata_model(manifest, meta)
    report = dict(schema_version=1, **model, field_sources=sources, missing_fields=missing,
                  warnings=warnings, sessions=[], jobs=[], evidence=[], media_policy='index_only; manual review before sharing')
    truncated = set()
    truncation_flags = {}
    if manifest.get('schema') == 1:
        producer = {}
        for section, fields in (('app', ('build_id',)), ('game', ('build_id', 'pack_fp')), ('device', ('gpu_family', 'low_power'))):
            values = manifest.get(section)
            if isinstance(values, dict):
                producer[section] = {k: values[k] for k in fields if k in values}
                for k in producer[section]:
                    sources['producer.' + section + '.' + k] = 'manifest.json:' + section + '.' + k
        for field in ('settings', 'sessions', 'metrickit', 'files'):
            if field in manifest:
                producer[field] = manifest[field]
                sources['producer.' + field] = 'manifest.json:' + field
        report['producer'] = producer
        entries = manifest.get('files')
        if isinstance(entries, list):
            for entry in entries:
                if not isinstance(entry, dict) or not isinstance(entry.get('path'), str):
                    continue
                try:
                    name = valid_name(entry['path'])
                except ValueError:
                    warnings.append({'source': 'manifest.json:files', 'message': 'invalid evidence reference'})
                    continue
                flag = entry.get('truncated')
                truncation_flags[name] = flag if type(flag) is bool else None
                if flag is not False:
                    truncated.add(name)
    # Stage all outputs outside the input and publish only once complete.
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.s2arm-report-', dir=output.parent) as temporary:
        stage = Path(temporary) / 'report'
        stage.mkdir()
        (stage / 'logs').mkdir()
        for index, (name, (k, data)) in enumerate(sorted(files.items())):
            media = k == 'media'
            dest = None
            if not media:
                dest = f'logs/{index:04d}.txt'
                text = undo_double_utf8(data.decode(errors='replace'))
                try:
                    text = json.dumps(sanitize(json.loads(text), identity_model=k == 'manifest', key_values=key_values), ensure_ascii=False, indent=2)
                except (ValueError, UnicodeError):
                    text = redact_text(text, key_values=key_values)
                (stage / dest).write_text(text, encoding='utf-8')
            report['evidence'].append(dict(path=name, type=k, size=len(data), sha256=hashlib.sha256(data).hexdigest(), availability='indexed_only' if media else 'sanitized_copy', sanitized_path=dest, truncated=truncation_flags.get(name)))
            if re.fullmatch(r'host(?:\.prev\d*)?\.log', PurePosixPath(name).name):
                report['sessions'].append(analyze_session(name, data, files, warnings, truncated))
            if k == 'job':
                try:
                    job = load_object(data)
                    report['jobs'].append(dict(source=name, parse_status='available', state=job.get('state'), stage=job.get('stage'), diagnostics=job.get('diagnostics'), game_result='unknown'))
                except (ValueError, UnicodeError):
                    report['jobs'].append(dict(source=name, parse_status='unavailable', diagnostics=None, game_result='unknown'))
                    warnings.append({'source': name, 'message': 'job JSON unavailable (possibly truncated); retained as sanitized text'})
        for index, session in enumerate(report['sessions']):
            for field in ('operability', 'picture', 'sound', 'frame_time_stutter'):
                key = f'sessions[{index}].{field}'
                report['field_sources'][key] = session['source']
                if session[field]['status'] in ('unknown', 'not_tested'):
                    report['missing_fields'].append(key)
            if session['firstuse_status'] == 'unknown':
                report['missing_fields'].append(f'sessions[{index}].firstuse')
                warnings.append({'source': session['source'], 'message': 'firstuse scanner unavailable; count unknown'})
        for category, available in (('host_logs', any(data.decode(errors='replace').strip() for n, (_, data) in files.items() if re.fullmatch(r'host(?:\.prev\d*)?\.log', PurePosixPath(n).name))), ('frames', any(PurePosixPath(n).name == 'frames.tsv' for n in files)), ('media', any(k == 'media' for k, _ in files.values()))):
            if not available:
                report['missing_fields'].append('evidence.' + category)
                warnings.append({'source': 'input', 'message': 'missing evidence: ' + category})
        report = sanitize(report, identity_model=True, key_values=key_values)
        (stage / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')
        (stage / 'report.md').write_text(markdown(report), encoding='utf-8')
        # Atomic exclusive reservation; hard links publish files without replacing any target.
        output.mkdir(mode=0o700, exist_ok=False)
        created = []
        directories = []
        try:
            for directory in sorted((p for p in stage.rglob('*') if p.is_dir())):
                target = output / directory.relative_to(stage)
                target.mkdir(exist_ok=False)
                directories.append(target)
            for p in sorted(p for p in stage.rglob('*') if p.is_file()):
                target = output / p.relative_to(stage)
                os.link(p, target)
                created.append(target)
            marker = output / '.complete'
            with marker.open('x') as stream:
                stream.write('s2arm diagnostic report schema 1\n')
            created.append(marker)
        except BaseException:
            for p in reversed(created):
                p.unlink(missing_ok=True)
            for p in reversed(directories):
                try: p.rmdir()
                except OSError: pass
            try: output.rmdir()
            except OSError: pass
            raise
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description='离线生成脱敏测试报告；不修改输入，不写记分板，媒体仅索引')
    parser.add_argument('input', help='诊断目录或 ZIP')
    parser.add_argument('--output', required=True, help='输入之外的新目录；已有目录一律拒绝')
    parser.add_argument('--metadata', help='补充字段 JSON 对象，字段见使用说明')
    parser.add_argument('--keys', action='append', help='显式密钥文件路径，可重复；省略时读取 ~/.switch/prod.keys 与 title.keys')
    args = parser.parse_args(argv)
    try:
        generate(args.input, args.output, args.metadata, args.keys)
    except (OSError, ValueError, zipfile.BadZipFile, RuntimeError):
        print('诊断报告生成失败：输入、元数据或输出不符合安全契约；未发布报告。', file=sys.stderr)
        return 1
    print('诊断报告已生成；媒体分享前须人工审查。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
