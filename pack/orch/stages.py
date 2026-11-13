# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Direct Python/core-tool counterparts of the first three bash stages.

Base stage keys retain the bash byte protocol. Actual-read manifests retain
the bash mechanism rows and add the orchestration sources (issue1100 contract).
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import hashlib
import errno
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time

from .bash import find_bash
from .roots import REPO, Roots, copy_file, git, is_link, plain_entries, read, remove_owned, text

ENTRY = {'rewrite': 'pack/stage_rewrite.sh', 'romfsidx': 'pack/stages/romfsidx.sh',
         'direct_profile': 'pack/stage_direct_profile.sh'}
LIGHT_ENTRY = {'sysdata': 'pack/stages/sysdata.sh', 'uilayout': 'pack/stage_uilayout.sh',
               'aoc': 'pack/stages/aoc.sh', 'caps': 'pack/stage_caps.sh',
               'nacp': 'pack/stages/nacp.sh'}
ENTRY.update(LIGHT_ENTRY)
# Layout writes RomFS, so indexing follows it; caps consumes rewrite outputs.
# Existing W1 stages retain their relative order. No compiler stages are added.
LIGHT_ORDER = ('rewrite', 'sysdata', 'uilayout', 'aoc', 'caps', 'romfsidx',
               'nacp', 'direct_profile')
MECHANISM = ('pack/stage_keyfiles.sh', 'tools/stage_deps.py',
             'tools/stage_deps_hook/sitecustomize.py')
ROOT_HELPERS = ('pack/resource_input_key.py', 'tools/direct_shards.py', 'tools/clonedir.py')
ORCH = ('pack/orch/__init__.py', 'pack/orch/roots.py', 'pack/orch/stages.py', 'pack/orch/refresh.py')
REWRITE_OUTPUTS = tuple(('*.code_patch.tsv *.patched.bin *.fixups.tsv *.gates.tsv '
    'degrade.rewrite.tsv *.sites.tsv *.gaps.tsv *.npdm *.widen.tsv widen_sites.tsv cpatch.tsv cpatch_rows.tsv '
    'cpatch_plan.log cpatch_excluded.tsv widen_enable*.tsv widen_verified.tsv fps.tsv '
    'nro_modules.tsv nro_to_nso.log widen_full*.tsv addr_need.tsv addr_need.log nro_exports.tsv '
    'nro_exports.log gpu_drivers.tsv widen_scan.log fps_generic.log *.rewrite.log '
    '.stage_rewrite .stage_rewrite.deps').split())


LAYOUT_ZSTD = '1.5.7'   # 布局阶段要的 zstd 命令行钉版（Mac Homebrew 同版）；pack/orch/oneclick_win.py --check 起单前按它核

def _title_id(directory):
    """目录里 unpack.tsv 记的程序号（大写）；读不出 → ''"""
    return next((line.split('\t', 1)[1].strip().upper() for line in read(Path(directory) / 'unpack.tsv').splitlines() if line.startswith('title_id\t')), '')


class StageError(RuntimeError):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def digest(data, size=16):
    return hashlib.sha256(data.encode('utf-8') if isinstance(data, str) else data).hexdigest()[:size]


def canonical_text(paths):
    """Generated UTF-8 text only; leave original inputs and binary bytes alone."""
    for p in paths:
        if p.is_file() and p.suffix in ('.tsv', '.json', '.md'):
            raw = p.read_bytes()
            raw.decode('utf-8')  # refuse a mislabeled binary, do not corrupt it
            if b'\r\n' in raw:
                p.write_bytes(raw.replace(b'\r\n', b'\n'))


def module(relative, name):
    spec = importlib.util.spec_from_file_location(name, REPO / relative)
    loaded = importlib.util.module_from_spec(spec)
    sys.modules[name] = loaded
    spec.loader.exec_module(loaded)
    return loaded


def run(args, *, env=None, log=None, allowed=(0,), timeout=600):
    """Captured UTF-8 output; Windows child trees belong to a private Job.

    On Windows `timeout` is a no-progress limit (job CPU time and I/O bytes both
    flat that long), not a wall clock: 11-05 Tianyan census Trine 5 direct_profile
    was killed at 600 s while still scanning a large original."""
    command = [str(a) for a in args]
    try:
        if os.name == 'nt':
            from pack.jobs import winproc
            p = winproc.popen(command, cwd=str(REPO), env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE)
            try:
                out, err = winproc.communicate_nostall(p, timeout)
            except subprocess.TimeoutExpired:
                winproc.reap_session(p.pid)
                p.communicate(timeout=10)
                raise StageError(f'工具超时：{Path(command[0]).name}')
            finally:
                winproc.reap_session(p.pid)
            rc = p.returncode
        else:
            p = subprocess.run(command, cwd=REPO, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=timeout)
            out, err, rc = p.stdout, p.stderr, p.returncode
    except FileNotFoundError as error:
        raise StageError(f'环境未就绪：{command[0]}', 75) from error
    except subprocess.TimeoutExpired as error:
        raise StageError(f'工具超时：{Path(command[0]).name}') from error
    if log:
        Path(log).write_bytes(out + err)
    elif err:
        sys.stderr.write(err.decode('utf-8', errors='replace'))
    if rc not in allowed:
        # 日志写在本阶段事务目录里，阶段失败事务整个丢弃（roots.py abort），「详见 <日志>」事后找不到（11-06 Windows 出包机0100C9C00E25C000只剩一句「详见 nro_to_nso.log」）：
        #   把工具输出最后几行带进报红，light.log / 红日志包里就有原因
        tail = [ln.strip() for ln in (out + err).decode('utf-8', errors='replace').splitlines() if ln.strip()][-4:]
        raise StageError(f'{Path(command[0]).name} 退出 {rc}；{Path(log).name if log else "stderr"} 末尾：' + (' / '.join(tail)[-600:] or '（无输出）'),
                         3 if rc == 3 else 1)
    # Protocol stdout is text (JSON/TSV/keys); preserve the raw log above,
    # but do not let Windows stdout CRLF leak into persistent byte manifests.
    return out.decode('utf-8').replace('\r\n', '\n'), rc


class Dependencies:
    def __init__(self, stage, root):
        self.stage, self.root = stage, Path(root)
        # collect consumes every entry as a record file. Keep tool scratch
        # outside that inbox, on the output-root volume (including ReFS).
        self.temp = tempfile.TemporaryDirectory(prefix='s2a-orch-deps-', dir=self.root.parent)
        self.work = Path(self.temp.name)
        self.raw = self.work / 'records'
        self.raw.mkdir()
        self.env = dict(os.environ)
        self.env['PYTHONIOENCODING'] = 'utf-8'
        self.env['S2A_DEPS_OUT'] = str(self.raw)
        self.env['PYTHONPATH'] = str(REPO / 'tools/stage_deps_hook') + (os.pathsep + self.env['PYTHONPATH'] if self.env.get('PYTHONPATH') else '')
        self.env.setdefault('S2A_DEPS_EXTERNAL', machine_cfg(self.env, 'S2A_COMMUNITY_DIR'))
        self.py = self.env.get('S2A_PYTHON') or self.env.get('S2A_PY') or sys.executable
        self.inputs = set()
        # Retain the existing root-clone algorithm identity even on Windows,
        # where roots.py supplies the native copy implementation.
        self.record(ENTRY[stage], *MECHANISM, *ROOT_HELPERS, *ORCH)

    def record(self, *paths):
        for p in paths:
            self.inputs.add(str((REPO / p).resolve()))

    def python(self, relative, *args, **kwargs):
        return run([self.py, '-X', 'utf8', REPO / relative, *args], env=kwargs.pop('env', self.env), **kwargs)

    def key(self, base):
        manifest = self.root / f'.stage_{self.stage}.deps'
        if not manifest.is_file():
            return base + '~d'
        stored = manifest.read_bytes()
        required = [ENTRY[self.stage], *MECHANISM, *ROOT_HELPERS, *ORCH]
        if any(('f\tR:' + p + '\t').encode() not in stored for p in required):
            return base + '~d'
        clean = dict(self.env)
        clean.pop('S2A_DEPS_OUT', None)
        result, _ = self.python('tools/stage_deps.py', 'rehash', manifest, REPO, env=clean)
        return base if result.encode('utf-8') == stored else base + '~d'

    def save(self, output, base):
        text(self.raw / 'scripts.tsv', ''.join(f'f\t{p}\n' for p in sorted(self.inputs)))
        clean = dict(self.env)
        clean.pop('S2A_DEPS_OUT', None)
        excludes = [self.root.parent, output, os.environ.get('S2A_ROOTS_SHARED', ''),
                    os.environ.get('S2A_ROOTS_PRIV', '')]
        manifest, _ = self.python('tools/stage_deps.py', 'collect', self.raw, REPO,
                                  *[str(p) for p in excludes if p], env=clean)
        text(output / f'.stage_{self.stage}.deps', manifest)
        text(output / f'.stage_{self.stage}', base + '\n')

    def close(self):
        self.temp.cleanup()


def romfs_walk(path):
    # Same repository traversal as every bash/core consumer; no replacement scan.
    return module('graphics/nvn/tools/romfs_list.py', '_orch_romfs_list').walk(path)


def layout_source_identity(original):
    """布局覆盖包的原版身份（审计 #1534 P1-54，同 pack/stage_uilayout.sh）：原版 Layout / UI / Pack 的盘点身份（romfs_list：相对路径 + 大小 + 修改时间纳秒，只 lstat）
    合成 12 位，进覆盖包目录名；原版变了构建号没变也重新生成。取本文件所在仓库的 romfs_list（不随单测换掉的 REPO）"""
    walker = sys.modules.get('_orch_layout_romfs_list')
    if walker is None:
        spec = importlib.util.spec_from_file_location('_orch_layout_romfs_list', Path(__file__).resolve().parents[2] / 'graphics/nvn/tools/romfs_list.py')
        walker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(walker)
        sys.modules['_orch_layout_romfs_list'] = walker
    h = hashlib.sha256()
    for name in ('Layout', 'UI', 'Pack'):
        if (Path(original) / name).is_dir():
            identity = walker.scan(Path(original) / name).identity
            if identity is None:
                raise StageError('布局盘点不了原版romfs的' + name)
            h.update(f'{name} {identity}\n'.encode())
    return h.hexdigest()[:12]


def rewrite_inputs(root):
    root = Path(root)
    paths = [p for p in (root / 'exefs').iterdir() if p.is_file()]
    if (root / 'romfs').is_dir():
        def fail(error):
            raise error
        walker = module('graphics/nvn/tools/romfs_list.py', '_orch_romfs_list')
        for directory, _, names in walker.walk(root / 'romfs', onerror=fail):
            paths.extend(Path(directory) / n for n in names if n.lower().endswith(('.nro', '.nrr')))
    h = hashlib.sha256(b'rewrite-inputs-v1\0')
    for path in sorted(paths, key=lambda p: os.fsencode(p.relative_to(root).as_posix())):
        rel = os.fsencode(path.relative_to(root).as_posix())
        content = hashlib.sha256()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                content.update(block)
        h.update(len(rel).to_bytes(8, 'little') + rel + content.digest())
    return h.hexdigest()


def selected_tables(game, bid, env):
    """选表规则只在 pack/pkg_srcs.py widen_list 一处（仓库表按构建号找，11-05 旷野之息）；这里按本次环境调它"""
    keys = ('S2A_WIDEN_DIR', 'S2A_WIDEN_AUTO', 'S2A_RUN_ROOT'); saved = {k: os.environ.get(k) for k in keys}
    try:
        os.environ['S2A_WIDEN_DIR'] = str(env.get('S2A_WIDEN_DIR', REPO / 'graphics/widen/tables'))
        os.environ['S2A_WIDEN_AUTO'] = str(env.get('S2A_WIDEN_AUTO', Path(env.get('S2A_RUN_ROOT', Path.home() / '.s2arm/run')) / 's2arm/widen/auto'))
        return [Path(p) for p in module('pack/pkg_srcs.py', 's2a_pkg_srcs').widen_list(game, bid)]
    finally:
        for k, v in saved.items():
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v


def machine_cfg(env, name):
    """本机配置一项：env 里非空用它，否则 tools/machine.local 的值（tools/machine.sh get，S2A_MACHINE_NO_LOCAL=1 不读；玩家作业恒设），都没有 = ''。
    不在代码里写死开发机路径（11-07 启动器零配置）：开发机的数据目录在 machine.local 声明"""
    if env.get(name):
        return env[name]
    bash = find_bash(env)
    if not bash:
        return ''
    try:
        r = subprocess.run([bash, str(REPO / 'tools/machine.sh'), 'get', name], env=env, capture_output=True,
                           text=True, timeout=30)
    except (OSError, subprocess.SubprocessError, ValueError):
        return ''
    out = r.stdout.strip()
    return out if r.returncode == 0 and '\0' not in out else ''


def community(env):
    root = machine_cfg(env, 'S2A_COMMUNITY_DIR')
    paths = env.get('S2A_CPATCH_DIRS', '')
    dirs = [Path(p) for p in paths.split(os.pathsep) if p] if paths else [] if not root else [
        p.parent for pattern in ('*/full/*/INDEX.tsv', '*/*/INDEX.tsv')
        for p in sorted(Path(root).glob(pattern)) if not any(x.endswith('-lite') for x in p.parts)]
    env['S2A_CPATCH_DIRS'] = os.pathsep.join(map(str, dirs))
    selection = env.get('S2A_CPATCH', '')
    cv = REPO / 'graphics/cpatch/verified.tsv'
    return dirs, selection, cv


def community_selection(env, pid, bid):
    """社区补丁这一款打不打、打哪些（苹果改写阶段 rewrite_plan 与安卓 android/tools/make_pack.py 共用这一份，#48 D2）：
    (索引目录, 缺省开的编号, 打不打)。缺省开 = graphics/cpatch/verified.tsv 本款「程序号 + main 构建号」的行 + S2A_CPATCH + 启动器玩家选择（同 stage_rewrite.sh CSEL）；
    打 = S2A_COMMUNITY_PATCHES=1（10-30 维护者：玩家包缺省不带上游补丁字节）且有索引目录且 S2A_CPATCH 不是 none"""
    dirs, selection, cv = community(env)
    verified_selection = ','.join(line.split('\t')[2] for line in read(cv).splitlines()
                                  if not line.startswith('#') and len(line.split('\t')) >= 3
                                  and line.split('\t')[0].upper() == pid and line.split('\t')[1].lower() == bid)
    if not selection:
        selection = verified_selection
    elif verified_selection and selection not in ('all', 'none'):
        # Same CSEL rule as stage_rewrite.sh: an explicit list augments the
        # verified defaults; all/none remain complete selections.
        selection = verified_selection + ',' + selection
    if env.get('S2A_COMMUNITY_SELECT'):
        selection_json = json.loads(Path(env['S2A_COMMUNITY_SELECT']).read_text(encoding='utf-8'))
        extra = ','.join(sorted(k for k, v in (selection_json.get('enabled') or {}).items() if v is True and k != 'ws:verified'))
        if extra:
            selection = selection + ',' + extra if selection and selection != 'none' else extra
    on = env.get('S2A_COMMUNITY_PATCHES', '0') == '1' and bool(dirs) and env.get('S2A_CPATCH') != 'none'
    return dirs, selection, on


def rewrite_plan(game, current, deps):
    env = deps.env
    main, npdm = current / 'exefs/main', current / 'exefs/main.npdm'
    with main.open('rb') as stream:
        stream.seek(0x40); bid = stream.read(16).hex()
    raw = npdm.read_bytes()
    aci = struct.unpack_from('<I', raw, 0x70)[0]
    if raw[aci:aci + 4] != b'ACI0':
        raise StageError('main.npdm ACI0 无效')
    pid = f'{struct.unpack_from("<Q", raw, aci + 0x10)[0]:016X}'
    tables = selected_tables(game, bid, env)
    vt = Path(env.get('S2A_WIDEN_DIR', REPO / 'graphics/widen/tables')) / 'verified.tsv'
    verified = next((line for line in read(vt).splitlines() if not line.startswith('#')
                     and len(line.split('\t')) >= 4 and line.split('\t')[0].upper() == pid
                     and line.split('\t')[1].lower() == bid and line.split('\t')[3].lower() == 'apple'), '')   # F7 #1574：苹果路线只取 apple 行
    fps = REPO / f'runtime/fps/{bid[:16]}.tsv'
    dirs, selection, on = community_selection(env, pid, bid)
    if env.get('S2A_COMMUNITY_SELECT'):
        deps.record(env['S2A_COMMUNITY_SELECT'])
    ck = ''
    if on:
        b = (selection + '\n').encode() + (REPO / 'pack/cpatch.py').read_bytes()
        b += b''.join((d / 'INDEX.tsv').read_bytes() for d in dirs if (d / 'INDEX.tsv').is_file())
        ck = ' cpatch=' + digest(b)
    ad = deps.work / 'addr'
    ad.mkdir()
    addr = ad / 'addr_need.tsv'
    ak, _ = deps.python('tools/addr_need.py', bid, addr, '--npdm', npdm, '--key', '--main', main, log=ad / 'log')
    sd, _ = deps.python('pack/rewriter.py', 'source')
    kr = digest(sd.strip() + '\n' + (REPO / 'runtime/rewriter/nro_to_nso.py').read_text(encoding='utf-8'), 40)
    ks = git('rev-parse', 'HEAD:graphics/widen/scan')
    rk, _ = deps.python('pack/rewriter.py', 'key')
    target = env.get('S2A_TARGET', 'apple')
    env.setdefault('S2A_REWRITE_SPIN', '1')
    spin = env['S2A_REWRITE_SPIN'] == '1'
    en = digest(''.join(f'{p.name} {digest(p.read_bytes(), 64)}\n' for p in tables)) if tables else '无启用表'
    suffix = (f' target={target}' if target != 'apple' else '') + (' spin=1' if spin else '')
    key = digest(f'{kr} {ks} {en}{suffix} addr={ak.strip()}', 10)
    patch = Path(env['S2A_PATCH_DIR']) / pid / 'patch.tsv' if env.get('S2A_PATCH_DIR') else None
    code = ''
    if patch and patch.is_file():
        section, lines = '', []
        for line in patch.read_text(encoding='utf-8').splitlines():
            if line.startswith('['):
                section = line
            elif section == '[code]' or (not section and line.split() and line.split()[0] == 'build'):
                lines.append(line + '\n')
        code = ' code=' + digest(''.join(lines))
    else:
        patch = None
    key = digest(f'{key} backend={rk.strip()}{ck}{code}' +
                 (f' fps={digest(fps.read_bytes())}' if fps.is_file() else '') +
                 (f' verified={digest(verified)}' if verified else ''), 10)
    key = digest(f'{key} inputs={rewrite_inputs(current)}', 10)
    tag = f'rw-{key}' + (f'-{target}' if target != 'apple' else '') + ('-spin' if spin else '')
    deps.record('graphics/nvn/tools/romfs_list.py')
    return dict(key=key, tag=tag, bid=bid, tables=tables, verified=verified,
                fps=fps if fps.is_file() else None, patch=patch, addr=addr,
                addr_log=ad / 'log', community=bool(ck), dirs=dirs, selection=selection)


def romfsidx_key(current):
    oids = git('rev-parse', 'HEAD:services/S2A.Services/RomFsIndex.cs',
               'HEAD:services/romfs_index', 'HEAD:services/romfs_index.sh',
               'HEAD:compat/tree/Directory.Packages.props').splitlines()
    if len(oids) != 4:
        raise StageError('RomFS 索引源码对象不完整')
    kt = digest('\n'.join(oids) + '\n')
    h = hashlib.sha256()
    base = current / 'romfs'
    for directory, dirs, files in romfs_walk(base):
        dirs.sort()
        for name in sorted(files):
            p = Path(directory) / name
            h.update(f'{p.relative_to(base).as_posix()}\t{p.stat().st_size}\n'.encode())
    over = overlay_sizes(current)
    if over:   # 界面布局覆盖层（_uilayout）：覆盖文件的大小也进键（没有覆盖层的版本键与原先相同）
        h.update(''.join(f'ui_overlay\t{n}\t{over[n]}\n' for n in sorted(over)).encode())
    return digest(f'{h.hexdigest()[:16]} {kt}')


def overlay_sizes(version):
    """界面布局覆盖层 <版本>/ui_overlay/romfs/<路径> → {RomFS 相对路径: 字节数}（读方按「覆盖层优先」叠在 romfs/ 上；没有覆盖层 → 空）"""
    layer = Path(version) / 'ui_overlay' / 'romfs'
    if is_link(layer) or not layer.is_dir():
        return {}
    return {p.relative_to(layer).as_posix(): p.stat().st_size for p in plain_entries(layer) if p.is_file()}


class Stages:
    def __init__(self, roots):
        self.roots = roots

    def _romfsidx(self, tx, deps):
        w = tx.path
        target = w / 'romfs.s2aidx'
        target.unlink(missing_ok=True)
        listing = deps.work / 'romfs-list.tsv'
        deps.python('graphics/nvn/tools/romfs_list.py', 'sizes', w / 'romfs', listing, log=w / 'romfs_index.log')
        over = overlay_sizes(w)
        if over:   # 覆盖层优先：索引只认路径与大小（RomFsIndex --list 用 SizeOnlyFile），覆盖文件换成覆盖层那份的大小
            rows = listing.read_text(encoding='utf-8').splitlines()
            seen = {r.split('\t', 1)[1] for r in rows if '\t' in r}
            extra = sorted(set(over) - seen)
            if extra:
                raise StageError(f'界面布局覆盖层有底下 RomFS 没有的文件（{extra[:3]}）：覆盖层只许替换')
            listing.write_text(''.join(f'{over.get(r.split(chr(9), 1)[1], r.split(chr(9), 1)[0])}\t{r.split(chr(9), 1)[1]}\n'
                                       for r in rows if '\t' in r), encoding='utf-8', newline='\n')
        dotnet = os.environ.get('DOTNET') or shutil.which('dotnet')
        if not dotnet:
            raise StageError('winenv：缺 .NET 命令；不下载', 75)
        prebuilt = os.environ.get('S2A_PREBUILT_TOOLS')
        if prebuilt:
            dll = Path(prebuilt) / 'romfs/romfs_index.dll'
        else:
            # --no-restore avoids implicit NuGet/network downloads; missing
            # restored inputs are an explicit environment failure.
            dll = REPO / 'services/romfs_index/bin/Release/net10.0/romfs_index.dll'
            try:
                run([dotnet, 'build', REPO / 'services/romfs_index', '-c', 'Release',
                     '-nologo', '-v', 'q', '--no-restore', '-m:2', '-nr:false',
                     '-p:UseSharedCompilation=false'], env=deps.env, log=w / 'romfs_index_build.log', timeout=300)
            except StageError as error:
                raise StageError('winenv：RomFS 索引构建/已还原依赖未就绪；未运行旧 DLL', 75) from error
        if not dll.is_file():
            raise StageError('winenv：缺本次指定的 romfs_index.dll', 75)
        run([dotnet, dll, w, '--list', listing], env=deps.env, log=w / 'romfs_index_core.log')
        if not target.is_file() or target.stat().st_size == 0:
            raise StageError('RomFS 索引为空，拒绝提交')

    def _direct_profile(self, tx, deps, plan):
        w = tx.path
        result, _ = deps.python('pack/direct_profile_stage.py', w, '--out', w / 'direct-profile' / plan['key'])
        data = json.loads(result)
        if not data.get('reused'):
            canonical_text((w / 'direct-profile' / plan['key']).rglob('*'))
        data['profile'] = Path(data['profile']).resolve().relative_to(w.resolve()).as_posix()
        data['DM_GAMES_DIR'] = Path(data['profile']).parent.as_posix()
        text(w / 'direct_profile.json', json.dumps(data, ensure_ascii=False, sort_keys=True) + '\n')
        deps.python('pack/direct_profile_stage.py', w, '--selected')

    def _rewrite(self, tx, deps, plan, executable, game):
        w, env = tx.path, dict(deps.env)
        for pattern in REWRITE_OUTPUTS:
            for path in w.glob(pattern):
                remove_owned(path)
        remove_owned(w / 'nroexe')
        deps.python('runtime/rewriter/nro_to_nso.py', w / 'romfs', w / 'nroexe', log=w / 'nro_to_nso.log')
        if (w / 'nroexe/nro_modules.tsv').is_file():
            (w / 'nroexe/nro_modules.tsv').rename(w / 'nro_modules.tsv')
        deps.python('graphics/widen/scan/wide_scan.py', w / 'exefs', '--tsv', w / 'widen_sites.tsv', log=w / 'widen_scan.log')
        for p in plan['tables']:
            copy_file(p, w / p.name)
        if plan['verified']:
            text(w / 'widen_verified.tsv', plan['verified'] + '\n')
        if plan['fps']:
            copy_file(plan['fps'], w / 'fps.tsv')
            env['S2A_FPS_TSV'] = str(w / 'fps.tsv')
        else:
            env.pop('S2A_FPS_TSV', None)
        if plan['patch']:
            env.update(S2A_CODE_PATCH=str(plan['patch']), S2A_CODE_BUILD=plan['bid'])
        else:
            env.pop('S2A_CODE_PATCH', None); env.pop('S2A_CODE_BUILD', None)
        env.pop('S2A_DEPS_OUT', None)
        modules = sorted(p for p in (w / 'exefs').iterdir() if p.is_file() and
                         (p.name in ('main', 'sdk') or len(p.name) == 7 and p.name.startswith('subsdk') and p.name[-1].isdigit()))
        modules += sorted(p for p in (w / 'nroexe').glob('nro*') if p.is_file())
        jobs = int(env.get('S2A_JOBS') or os.cpu_count() or 0)
        if jobs < 1:
            raise StageError('无法确定正数并发度')

        # 退出码 3 = 有缺口、产物照出：降级继续（缺口点保持原指令，汇总进 degrade.rewrite.tsv），与 pack/stage_rewrite.sh 同口径（#893：原先这里只认 0，
        #   Windows 上有缺口的款整包失败，Mac 同一款照出）。退出码 3 却没出产物 = 改写空间超过上限，物理上做不了，照旧停
        def rewrite_all():
            def one(p):
                _, code = run([executable, p, w, p.name, w / 'widen_sites.tsv'],
                              env=env, log=w / f'{p.name}.rewrite.log', allowed=(0, 3))
                if code == 3 and not (w / f'{p.name}.patched.bin').is_file():
                    raise StageError(f'改写 {p.name}：这款有程序代码需要的改写空间超过了能放下的上限，出不了包（{p.name}.rewrite.log）', 3)
                return p.name if code == 3 else ''
            with ThreadPoolExecutor(max_workers=jobs) as pool:
                return [name for name in pool.map(one, modules) if name]

        rewrite_all()
        if plan['community']:
            text(w / 'cpatch_excluded.tsv', '')
            for _ in range(6):
                deps.python('pack/cpatch.py', 'plan', w, plan['selection'].removeprefix('none'), *plan['dirs'], log=w / 'cpatch_plan.log')
                if not (w / 'cpatch_rows.tsv').is_file() or not (w / 'cpatch_rows.tsv').stat().st_size:
                    break
                env['S2A_CPATCH_TSV'] = str(w / 'cpatch_rows.tsv')
                rewrite_all()
                _, rc = deps.python('pack/cpatch.py', 'prune', w, log=w / 'cpatch_prune.log', allowed=(0, 10))
                if rc != 10:
                    break   # 剩下的是补丁以外的缺口：降级继续（同 stage_rewrite.sh）
        said, _ = deps.python('pack/rewrite_degrade.py', w, game)
        if said.strip():
            print(said.strip(), file=sys.stderr)
        copy_file(w / 'exefs/main.npdm', w / 'main.npdm')
        copy_file(plan['addr'], w / 'addr_need.tsv')
        copy_file(plan['addr_log'], w / 'addr_need.log')
        deps.python('tools/nro_exports.py', w / 'romfs', w / 'nro_exports.tsv', log=w / 'nro_exports.log')
        gpu, _ = deps.python('graphics/nvn/games/profile_guess.py', '--gpu-drivers', w / 'exefs', log=w / 'gpu_drivers.log')
        text(w / 'gpu_drivers.tsv', gpu)
        if not plan['fps']:
            _, rc = deps.python('tools/fps_warehouse.py', w, plan['bid'], log=w / 'fps_warehouse.log', allowed=(0, 1, 2))
            if rc:
                deps.python('tools/fps_generic.py', w, plan['bid'], log=w / 'fps_generic.log', allowed=(0, 1, 2))
        remove_owned(w / 'nroexe')
        canonical_text(p for pattern in REWRITE_OUTPUTS for p in w.glob(pattern))

    def execute(self, game, stage):
        if stage in LIGHT_ENTRY:
            return self._execute_light(game, stage)
        if stage not in ENTRY:
            raise ValueError('仅支持 rewrite,romfsidx,direct_profile')
        current = self.roots.cur(game)
        if not current or not (current / 'exefs').is_dir() or not (current / 'romfs').is_dir():
            raise StageError('缺现行 exefs/romfs；先 --from-extract 播种')
        self.roots._validate(current, game)
        deps = Dependencies(stage, current)
        start = time.perf_counter()
        try:
            if stage == 'rewrite':
                plan = rewrite_plan(game, current, deps)
                key, tag, replay = plan['key'], plan['tag'], REWRITE_OUTPUTS
            elif stage == 'romfsidx':
                deps.record('graphics/nvn/tools/romfs_list.py')
                key = romfsidx_key(current)
                tag, replay = 'rx-' + key[:8], ()
                plan = None
            else:
                api, _ = deps.python('graphics/nvn/tools/gfx_api.py', current / 'exefs')
                if api.split('\t')[0].strip() in ('vulkan', 'gl'):
                    return self._result(stage, start, current, None, skipped=True)
                meta, _ = deps.python('pack/direct_profile_stage.py', current, '--key')
                plan = json.loads(meta)
                if plan['source'] != 'generated':
                    deps.python('pack/direct_profile_stage.py', current, '--selected')
                    return self._result(stage, start, current, plan['key'], skipped=True)
                key, tag = plan['key'], 'dp-' + plan['key']
                replay = ('direct-profile', 'direct_profile.json', '.stage_direct_profile', '.stage_direct_profile.deps')
            checked = deps.key(key)
            if read(current / f'.stage_{stage}') == checked and (stage != 'direct_profile' or (current / 'direct_profile.json').is_file()):
                return self._result(stage, start, current, key, skipped=True)
            executable = None
            if stage == 'rewrite':
                build_log = deps.work / 'rewriter-build.log'
                try:
                    executable, _ = deps.python('pack/rewriter.py', 'c-path', log=build_log)
                except StageError as error:
                    message = read(build_log)
                    if '缺 C 改写器固定依赖' in message or '需要 CMake' in message:
                        raise StageError('winenv：自动源码改写器固定依赖/CMake 未就绪；不下载', 75) from error
                    raise StageError('自动源码改写器构建失败；未运行旧二进制：' + message[-1200:]) from error
                executable = executable.strip()
            tx = self.roots.begin(game, self.roots.tag(game, tag), env=deps.env)
            try:
                if stage == 'rewrite':
                    self._rewrite(tx, deps, plan, executable, game)
                elif stage == 'romfsidx':
                    self._romfsidx(tx, deps)
                else:
                    self._direct_profile(tx, deps, plan)
                deps.save(tx.path, key)
                result = self._result(stage, start, tx.path, key)
                # Write the final immutable version name, never a .tmp path.
                result['version'] = tx.path.name.removesuffix('.tmp')
                text(tx.path / '.orch_last.json', json.dumps(result, ensure_ascii=False, sort_keys=True) + '\n')
                final = tx.commit(replay=replay)
                result['version'] = final.name
                if stage == 'direct_profile':
                    deps.python('pack/direct_profile_stage.py', final, '--selected')
                return result
            except BaseException:
                tx.abort()
                raise
        finally:
            deps.close()

    @staticmethod
    def _result(stage, start, current, key, *, skipped=False):
        return dict(stage=stage, seconds=round(time.perf_counter() - start, 6),
                    version=current.name, key=key, skipped=skipped,
                    timing_scope='key+core+deps_before_commit')

    def _execute_light(self, game, stage):
        if stage in ('sysdata', 'uilayout', 'nacp', 'aoc'):
            return getattr(self, '_' + stage)(game)
        current = self.roots.cur(game)
        if not current or not (current / 'exefs/main').is_file():
            raise StageError('缺现行 exefs/main；先 --from-extract 播种')
        self.roots._validate(current, game)
        start = time.perf_counter()
        deps = Dependencies(stage, current)
        try:
            base, plan = self._caps_plan(current, deps)
            replay = ('s2a_caps.tsv', 's2a_caps.all.tsv', 'caps.log', '.stage_caps', '.stage_caps.deps')
            key = base
            if read(current / f'.stage_{stage}') == deps.key(base):
                return self._result(stage, start, current, key, skipped=True)
            tx = self.roots.begin(game, self.roots.tag(game, stage + '-' + digest(key, 8)), env=deps.env)
            try:
                self._caps(tx.path, deps)
                deps.save(tx.path, base)
                text(tx.path / f'.stage_{stage}', key + '\n')
                result = self._result(stage, start, tx.path, key)
                result['version'] = tx.path.name.removesuffix('.tmp')
                text(tx.path / '.orch_last.json', json.dumps(result, ensure_ascii=False, sort_keys=True) + '\n')
                result['version'] = tx.commit(replay=replay).name
                return result
            except BaseException:
                tx.abort()
                raise
        finally:
            deps.close()

    @staticmethod
    def _caps_plan(current, deps):
        rewrite = read(current / '.stage_rewrite')
        if not rewrite:
            raise StageError('能力清单需要已完成的改写阶段')
        pid = '-'
        try:
            npdm = (current / 'exefs/main.npdm').read_bytes()
            aci = struct.unpack_from('<I', npdm, 0x70)[0]
            if npdm[aci:aci + 4] == b'ACI0':
                pid = f'{struct.unpack_from("<Q", npdm, aci + 0x10)[0]:016X}'
        except (OSError, ValueError, struct.error):
            pass  # The bash key also uses '-' when metadata cannot identify a PID.
        signals, _ = deps.python('tools/caps_policy.py', 'signal-files', '--target', 'apple')
        signals = signals.strip()
        if not signals:
            raise StageError('取不到能力实现文件清单')
        deps.env['S2A_DEPS_KEYED'] = os.pathsep.join(['docs/名单_验证账.tsv', *signals.split(':')])
        signal_hash, _ = deps.python('tools/caps_policy.py', 'signal-hash', '--target', 'apple')
        # Like grep -i '^<PID>\t': keep exact matching row bytes and order.
        rows = ''.join(line + '\n' for line in read(REPO / 'docs/名单_验证账.tsv').splitlines()
                       if line.split('\t', 1)[0].upper() == pid.upper())
        deps.record('pack/gen_caps.sh')
        return digest(rows + 'rewrite=' + rewrite + '\n' + signal_hash), None

    @staticmethod
    def _caps(output, deps):
        lines, _ = deps.python('tools/caps_policy.py', 'decide',
                               deps.env.get('S2A_CAPS_REPO') or REPO, output, '--both', '--target', 'apple',
                               log=output / 'caps.log')
        Stages._light_log(output / 'caps.log')
        rows = [line.split('\t') for line in lines.splitlines()]
        if len(rows) != 2 or any(len(row) != 5 or row[0] not in ('0', '1')
                                 or row[2] not in ('0', '1') or row[4] not in ('0', '1') for row in rows):
            raise StageError('能力判定应有发布/测试两行，每行5列，不使用旧清单')
        dual, direct = '1', '直连可用'   # 只有直连（11-07 拆通用模式）
        heads = ('发布包：60 帧默认开、强信号才关；满屏默认关、真机验过或有补丁才开（tools/caps_policy.py）',
                 '--all-caps 出包：有来源即开、不看强信号')
        for filename, head, row in zip(('s2a_caps.tsv', 's2a_caps.all.tsv'), heads, rows):
            fps, fps_reason, widen, widen_reason, display = row
            content = ('plat\tapple\n'   # F7 #1574：清单首行标平台，安卓打包只收 plat android 头
                       f'# 包内能力清单（{head}）\n'
                       '# 格式：<能力>\\t<值>\\t# <原因>（1 = 开，0 = 显式关）；优先级：启动环境 > Settings.bundle（用户改过的设置）> 本文件\n'
                       f'widen\t{widen}\t# {widen_reason}\nfps60\t{fps}\t# {fps_reason}\n'
                       f'direct\t{dual}\t# {direct}\ngyro\t1\t# 宿主通用能力\nhaptics\t1\t# 宿主通用能力\n')
            if display == '1':
                content += 'fps60_display\t1\t# 引擎通用：放开出图间隔（全引擎，同局 A/B 判红才关）\n'
            text(output / filename, content)

    def _light_current(self, game):
        current = self.roots.cur(game)
        if not current or not (current / 'exefs/main').is_file():
            raise StageError('缺现行 exefs/main；先 --from-extract 播种')
        self.roots._validate(current, game)
        return current

    @staticmethod
    def _light_log(path):
        if is_link(path):
            raise StageError('阶段日志不能是链接')
        if path.is_file():
            raw = path.read_bytes()
            raw.decode('utf-8')
            if b'\r\n' in raw:
                path.write_bytes(raw.replace(b'\r\n', b'\n'))

    def _light_commit(self, tx, stage, start, key, replay=()):
        result = self._result(stage, start, tx.path, key)
        result['version'] = tx.path.name.removesuffix('.tmp')
        text(tx.path / '.orch_last.json', json.dumps(result, ensure_ascii=False, sort_keys=True) + '\n')
        result['version'] = tx.commit(replay=replay).name
        return result

    @staticmethod
    def _layout_paths(folder):
        if is_link(folder):
            raise StageError('布局覆盖目录不能是链接')
        if not folder.is_dir():
            return []
        return sorted((Stages._layout_name(p.relative_to(folder).as_posix()) for p in plain_entries(folder)
                       if p.is_file() and p.name != '.DS_Store'), key=lambda p: p.encode('utf-8'))

    @staticmethod
    def _layout_name(name):
        # ui_overlay.tsv is persisted input. Never let it escape either tree.
        if (not name or '\\' in name or ':' in name or '\t' in name or '\r' in name
                or name.startswith('/') or any(p in ('', '.', '..') for p in name.split('/'))):
            raise StageError('布局清单含非法相对路径')
        return name

    @staticmethod
    def _layout_tools(generator, work):
        zstd = shutil.which('zstd')
        if not zstd or (os.name == 'nt' and ('cygwin' in str(zstd).lower() or Path(zstd).suffix.lower() != '.exe')):
            raise StageError(f'布局需要已准备的原生zstd {LAYOUT_ZSTD}；不下载', 75)
        version, _ = run([zstd, '--version'])
        if not re.search(rf'\bv{re.escape(LAYOUT_ZSTD)}\b', version):
            raise StageError(f'布局需要钉版zstd {LAYOUT_ZSTD}', 75)
        # 启动器随发版预编的 Yaz0 编码器（S2A_PREBUILT_TOOLS/codecs，按源码哈希同名；名字由布局核心 yaz0enc_name 给）在 → 不要编译器，下面照样实跑一次
        spec = importlib.util.spec_from_file_location('ui_encoder_name', generator)
        core = importlib.util.module_from_spec(spec); spec.loader.exec_module(core)
        cc = None
        if not core.yaz0enc_prebuilt():
            cc = os.environ.get('CC') or shutil.which('clang')
            if not cc:
                raise StageError('布局Yaz0源码编译器未就绪；配置CC', 75)
            version, _ = run([cc, '--version'])
            if 'clang' not in version.lower():
                raise StageError('布局需要已核的Clang编译器', 75)
            source = generator.read_text(encoding='utf-8')
            if os.name == 'nt' and ('os.environ' not in source or "['cc', '-O2'" in source):
                raise StageError('布局核心的CC继承/Windows exe共用适配尚未进当前源码', 75)
        # Exercise the unchanged encoder in this child before workers start.
        # A failed C build must not silently turn into literal-only compression.
        script = ("import importlib.util,sys\n"
                  "s=importlib.util.spec_from_file_location('ui_encoder_check',sys.argv[1])\n"
                  "m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n"
                  "m.yaz0_pack(b'original encoder preflight'*8,b'Yaz0'+bytes(12))\n"
                  "assert m._ENC, 'Yaz0 C encoder fell back to literals'\n")
        env = dict(os.environ, **({'CC': str(cc)} if cc else {}), PYTHONIOENCODING='utf-8')
        run([sys.executable, '-X', 'utf8', '-c', script, generator], env=env,
            log=work / 'encoder-check.log')
        return env

    def _uilayout(self, game):
        start = time.perf_counter()
        current = self._light_current(game)
        if not (current / 'romfs').is_dir():
            return self._result('uilayout', start, current, None, skipped=True)
        # 原版：seed.txt 记的解包目录 romfs——它在、而且是这一款的（unpack.tsv 程序号对得上）才用（旧格式版本就地改过 RomFS 时靠它还原，见下面 restore）；
        #   否则用现行产物根的 romfs：本阶段只写覆盖层，Windows 别的阶段也不改 romfs，它一直联到播种时那份不可变的身份。
        #   解包目录不可靠：从原件解时 romfs 被挪进共享存储、原处链接在播种那一版修剪后悬空；玩家实报还指到过别的款的解包目录，
        #   原先照用，拿别的款的布局文件生成覆盖叠到这一款上（v0.3.0 Windows）
        source = next((line[4:] for line in read(current / 'seed.txt').splitlines() if line.startswith('src=')), '')
        original = Path(source) / 'romfs' if source else None
        theirs, ours = _title_id(Path(source)) if source else '', _title_id(current)
        if original is None or not original.is_dir() or (theirs and ours and theirs != ours):
            print(f'【黄】布局原版改用现行产物根的 RomFS（seed.txt 记的解包目录{"是另一款 " + theirs + " 的" if theirs and ours and theirs != ours else "不在或已失效"}）', file=sys.stderr)
            original = current / 'romfs'
        plain_entries(original)
        generator = REPO / 'graphics/widen/scan/ui_lyt.py'
        # Current repository import closure, including both on-demand C codecs.
        # Decoder fixes must invalidate overlays as well as the stage stamp.
        tool_sources = (generator, generator.with_name('yaz0enc.c'),
                        REPO / 'graphics/nvn/tools/romfs_list.py',
                        REPO / 'graphics/tools/nxfmt.py', REPO / 'graphics/tools/yaz0dec.c')
        tv = hashlib.sha256(b''.join(p.read_bytes() for p in tool_sources)).hexdigest()[:12]
        bid = (current / 'exefs/main').read_bytes()[0x40:0x50].hex()
        width = 2346
        overlay = Path(os.environ.get('S2A_WIDEN_DIR', self._run_root() / 's2arm/widen')) / (game + '_' + bid) / f'ui_w{width}_{tv}_{layout_source_identity(original)}'
        if is_link(overlay) or is_link(overlay.parent):
            raise StageError('布局覆盖缓存不能是链接')
        if not overlay.is_dir() and any((original / p).is_dir() for p in ('Layout', 'UI', 'Pack')):
            overlay.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix=overlay.name + '.tmp.', dir=overlay.parent) as temporary:
                work = Path(temporary)
                env = self._layout_tools(generator, work)
                _, code = run([sys.executable, '-X', 'utf8', generator, original, work / 'romfs', width],
                              env=env, log=work / 'gen.log', allowed=(0, 1))
                diagnostics = read(work / 'gen.log')
                # _one catches Python exceptions and prints their class instead
                # of a traceback. Those are tool failures even with good files.
                python_failure = re.search(
                    r'(?m)^\s*Traceback\b|(?:^|[：:]\s*)[A-Za-z_][A-Za-z_0-9.]*(?:Error|Exception)\b',
                    diagnostics)
                errors = [line.strip() for line in diagnostics.splitlines() if '【红】' in line]
                content_partial = (errors and all(re.match(r'^【红】.+：内容缺口：.+', line) for line in errors)
                                   and re.search(r'报错\s+[1-9][0-9]*（', diagnostics))
                if python_failure or ((code or errors) and not content_partial):
                    print(diagnostics, file=sys.stderr)
                    raise StageError('布局生成器异常或未明确分类的失败；不发布缓存、下次重试', 75)
                files = self._layout_paths(work / 'romfs')
                if code and not files:
                    print('【黄】布局生成失败且无覆盖，不发布缓存、下次重试', file=sys.stderr)
                else:
                    if code:
                        print('【黄】布局部分生成失败；只采用成功的覆盖', file=sys.stderr)
                    try:
                        work.rename(overlay)
                    except OSError as error:
                        if error.errno not in (errno.EEXIST, errno.ENOTEMPTY) or is_link(overlay) or not overlay.is_dir():
                            raise
        files = self._layout_paths(overlay / 'romfs')
        previous = [self._layout_name(p) for p in read(current / 'ui_overlay.tsv').splitlines() if p]
        if not files and not previous:
            return self._result('uilayout', start, current, None, skipped=True)
        hash_rows = ''.join(hashlib.sha256((overlay / 'romfs' / name).read_bytes()).hexdigest() + '  ' + name + '\n' for name in files)
        overlay_hash = digest(hash_rows) if files else ''
        key = digest(f'w{width} {tv} {overlay_hash}')
        if read(current / '.stage_uilayout') == key:
            return self._result('uilayout', start, current, key, skipped=True)
        # 覆盖层（11-06 出包速度线，维护者批）：现行 RomFS 不动（仍联到存储里那份不可变的身份），改动的布局文件只写进
        #   <版本>/ui_overlay/romfs/<路径>，读方（RomFS 索引、资源包 pack/pkg_srcs.py）按「覆盖层优先」叠上去。
        #   原先为改几十个文件独占克隆整份 RomFS、提交时整份封存、修剪时再整份解封删除（0100F2C0115B6000 30.5 万个文件，Windows 出包机 uilayout 1283 秒）。
        tx = self.roots.begin(game, self.roots.tag(game, 'ui-w' + str(width) + '-' + key[:8]))
        try:
            base = tx.path / 'romfs'
            previous = [self._layout_name(p) for p in read(tx.path / 'ui_overlay.tsv').splitlines() if p]
            missing = {p for p in set(files + previous) if not (original / p).is_file() or not (base / p).is_file()}
            if missing:
                print(f'【黄】布局原版/现行没有{len(missing)}项，只许替换、跳过', file=sys.stderr)
            files = [p for p in files if p not in missing]
            # 上一版覆盖过、这一版不覆盖的：底下 RomFS 若不是原版（旧格式版本就地改过 RomFS）就把原版放进覆盖层；清单记覆盖层里的全部文件，下一版照样核
            restore = [p for p in sorted(set(previous) - set(files) - missing) if (base / p).read_bytes() != (original / p).read_bytes()]
            layer = tx.path / 'ui_overlay'
            remove_owned(layer)
            for name, source in [(p, overlay / 'romfs' / p) for p in files] + [(p, original / p) for p in restore]:
                target = layer / 'romfs' / name
                target.parent.mkdir(parents=True, exist_ok=True)
                copy_file(source, target)
            text(tx.path / 'ui_overlay.tsv', ''.join(p + '\n' for p in sorted(set(files) | set(restore), key=lambda p: p.encode('utf-8'))))
            text(tx.path / '.stage_uilayout', key + '\n')
            (tx.path / '.stage_romfsidx').unlink(missing_ok=True)
            (tx.path / 'romfs.s2aidx').unlink(missing_ok=True)
            return self._light_commit(tx, 'uilayout', start, key,
                ('ui_overlay', 'ui_overlay.tsv', '.stage_uilayout', '.stage_romfsidx', 'romfs.s2aidx'))
        except BaseException:
            tx.abort()
            raise

    @staticmethod
    def _fonts():
        """Configured fonts or the unchanged generator, with downloads denied."""
        if os.environ.get('S2A_FONTS'):
            selected = Path(os.environ['S2A_FONTS'])
        else:
            selected = next((Path(p) for p in os.environ.get('S2A_APP_FONTS_DIRS', '').split(os.pathsep)
                             if p and list(Path(p).glob('*.bfttf'))), None)
        if selected is not None:
            if is_link(selected) or not selected.is_dir() or not list(selected.glob('*.bfttf')):
                raise StageError('共享字体目录缺失/非法；配置S2A_FONTS', 75)
            return selected   # v0.2.3 清理：玩家选的字体目录只认 *.bfttf，里面别的条目（软链、.DS_Store）不管、不拒
        run_root = Path(os.environ.get('S2A_RUN_ROOT', Path.home() / '.s2arm/run'))
        dest = Path(os.environ.get('S2A_OPENFONTS_DIR', run_root / 's2arm/openfonts'))
        generator = REPO / 'pack/fonts/make_open_fonts.py'
        stamp = hashlib.sha256(generator.read_bytes()).hexdigest()
        def ready():
            return (dest.is_dir() and not is_link(dest)
                    and read(dest / '.generator.sha256') == stamp and len(list(dest.glob('*.bfttf'))) == 7)
        if ready():
            return dest   # 自家生成的缓存：ready() 已核生成器指纹与 7 份字体，不再递归扫链接（v0.2.3 清理）
        if is_link(dest) or is_link(dest.parent):
            raise StageError('开源字体缓存路径不能是链接')
        dest.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=dest.name + '.tmp.', dir=dest.parent) as scratch:
            temp = Path(scratch) / 'fonts'
            # The stock generator fetches missing pinned data. Deny that exact
            # entry point in this child, without modifying the shared generator.
            script = ("import runpy,sys,urllib.request\n"
                      "def offline(*a,**k): raise RuntimeError('S2A_FONT_OFFLINE_INPUT_MISSING')\n"
                      "urllib.request.urlopen=offline\n"
                      "sys.argv=sys.argv[1:]\nrunpy.run_path(sys.argv[0],run_name='__main__')\n")
            env = dict(os.environ, PYTHONIOENCODING='utf-8')
            log = Path(scratch) / 'fonts.log'
            try:
                run([sys.executable, '-X', 'utf8', '-c', script, generator, temp], env=env, log=log)
            except StageError as error:
                message = read(log)
                if ('S2A_FONT_OFFLINE_INPUT_MISSING' in message or 'ModuleNotFoundError' in message
                        or ('版本' in message and 'requirements.txt' in message)):
                    raise StageError('开源字体固定依赖/离线数据未就绪；不下载，或配置S2A_FONTS', 75) from error
                raise
            if len(list(temp.glob('*.bfttf'))) != 7:
                raise StageError('开源字体生成器没有产出7份字体')
            text(temp / '.generator.sha256', stamp + '\n')
            # The shared file lock protects replacement of this exact cache;
            # another game's successful generation is kept rather than removed.
            from pack.jobs import filelock
            with (dest.parent / (dest.name + '.lock')).open('a+b') as lock:
                if lock.seek(0, 2) == 0:
                    lock.write(b'\0'); lock.flush()
                deadline = time.monotonic() + 600
                while True:
                    try:
                        filelock.try_lock(lock)
                        break
                    except BlockingIOError:
                        if time.monotonic() >= deadline:
                            raise StageError('共享字体发布锁超时')
                        time.sleep(0.05)
                try:
                    if not ready():
                        remove_owned(dest)
                        temp.rename(dest)
                finally:
                    filelock.unlock(lock)
        return dest

    @staticmethod
    def _timezone(root):
        system = root / 'systemdata'
        return next((p for p in system.iterdir() if p.name.upper() == '010000000000080E' and p.is_dir()), None) if system.is_dir() else None

    @staticmethod
    def _tz_pins():
        pins = dict(re.findall(r'^(TZ_[A-Z0-9_]+)=(\S+)$',
                               read(REPO / 'services/systemdata/tzdata-pins.sh'), re.M))
        names = ('TZ_VERSION', 'TZ_CODE_SHA512', 'TZ_DATA_SHA512', 'TZ_OUTPUT_SHA256')
        if any(n not in pins for n in names):
            raise StageError('钉版时区身份不完整')
        return pins, ' '.join(pins[n] for n in names)

    @staticmethod
    def _tz_bundle(pins):
        bundle = REPO / 'Binaries/Prepare/Tzdata/output'
        # S2A_TZDATA_CACHE is the existing make_tzdata.sh offline cache root.
        if not bundle.is_dir() and os.environ.get('S2A_TZDATA_CACHE'):
            bundle = Path(os.environ['S2A_TZDATA_CACHE']) / 'output'
        if not bundle.is_dir() or is_link(bundle):
            raise StageError('缺钉版时区离线产物；不下载IANA、不在Windows现编zic', 75)
        rows = []
        for p in plain_entries(bundle):
            if p.is_file():
                rows.append(dict(path=p.relative_to(bundle).as_posix(), size=p.stat().st_size,
                                 sha256=hashlib.sha256(p.read_bytes()).hexdigest()))
        rows.sort(key=lambda item: item['path'])
        actual = hashlib.sha256(json.dumps(rows, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        if actual != pins['TZ_OUTPUT_SHA256']:
            raise StageError('钉版时区离线产物内容哈希不符')
        return bundle

    def _sysdata(self, game):
        start = time.perf_counter()
        current = self._light_current(game)
        zone = self._timezone(current)
        generated = any(line.startswith('时区数据：') for line in read(current / 'tz.log').splitlines()) if zone else False
        pins, identity = self._tz_pins() if not zone or generated else (None, '')
        tz_hash = hashlib.sha256((identity + '\n').encode()).hexdigest() if not zone or generated else 'real'
        key = 'real' if tz_hash == 'real' else 'tz-' + tz_hash
        stale = generated and ('s2a-tzdata-source ' + identity) not in read(current / 'tz.log').splitlines()
        bundle = self._tz_bundle(pins) if not zone or stale else None
        fonts = self._fonts()
        need, _ = run([sys.executable, '-X', 'utf8', REPO / 'pack/sysdata_need.py', current,
                       os.environ.get('S2A_SYSDATA', '')])
        copies, synth = [], []
        for line in need.splitlines():
            fields = line.split('\t')
            if fields[0] == 'COPY' and len(fields) == 3:
                copies.append((fields[1], Path(fields[2])))
            elif fields[0] == 'SYNTH' and len(fields) >= 2:
                synth.append(fields[1])
        def font_rows(folder, algorithm):
            return [(p.name, hashlib.new(algorithm, p.read_bytes()).hexdigest())
                    for p in sorted(folder.glob('*.bfttf'), key=lambda p: os.fsencode(p.name))]
        already = (font_rows(fonts, 'sha1') == font_rows(current / 'systemdata/fonts', 'sha1')
                   and zone is not None and zone.name == '010000000000080E' and not stale
                   and not copies and not synth and (read(current / '.stage_sysdata') == key
                       or (not generated and not read(current / '.stage_sysdata'))))
        if already:
            return self._result('sysdata', start, current, key, skipped=True)
        font_identity = ''.join(f'{sha}  {name}\n' for name, sha in font_rows(fonts, 'sha256'))
        tag = 'sys-' + digest(font_identity, 8) + '-tz' + tz_hash + ('-sd' if copies else '') + ('-syn' if synth else '')
        tx = self.roots.begin(game, self.roots.tag(game, tag))
        try:
            target = tx.path / 'systemdata'
            target.mkdir(exist_ok=True)
            remove_owned(target / 'fonts')
            (target / 'fonts').mkdir()
            for source in fonts.glob('*.bfttf'):
                copy_file(source, target / 'fonts' / source.name)
            zone = self._timezone(tx.path)
            if stale and zone:
                remove_owned(zone)
                zone = None
            if zone is None:
                self.roots._copy_tree(bundle, target / '010000000000080E')
                text(tx.path / 'tz.log', '时区数据：App 钉版 ' + pins['TZ_VERSION'] + '\n'
                     + 's2a-tzdata-source ' + identity + '\n')
            elif zone.name != '010000000000080E':
                interim = target / (zone.name + '.up-' + str(time.time_ns()))
                zone.rename(interim)
                interim.rename(target / '010000000000080E')
            for sid, source in copies:
                if not re.fullmatch('[0-9A-F]{16}', sid):
                    raise StageError('系统数据生成器返回非法号')
                remove_owned(target / sid)
                (target / (sid + '.synth')).unlink(missing_ok=True)
                self.roots._copy_tree(source, target / sid)
            for sid in synth:
                if not re.fullmatch('[0-9A-F]{16}', sid):
                    raise StageError('系统数据生成器返回非法号')
                remove_owned(target / sid)
                run([sys.executable, '-X', 'utf8', REPO / 'pack/sysdata_synth.py', sid, target / sid])
                text(target / (sid + '.synth'), '合成：pack/sysdata_synth.py ' + sid + '\n')
            text(tx.path / '.stage_sysdata', key + '\n')
            return self._light_commit(tx, 'sysdata', start, key, ('systemdata', 'tz.log', '.stage_sysdata'))
        except BaseException:
            tx.abort()
            raise

    @staticmethod
    def _run_root():
        return Path(os.environ.get('S2A_RUN_ROOT', Path.home() / '.s2arm/run'))

    @staticmethod
    def _program_id(current):
        for line in read(current / 'unpack.tsv').splitlines():
            fields = line.split('\t')
            if len(fields) == 2 and fields[0] == 'title_id' and re.fullmatch('[0-9a-fA-F]{16}', fields[1]):
                return fields[1].upper()
        raw = (current / 'exefs/main.npdm').read_bytes()
        aci = struct.unpack_from('<I', raw, 0x70)[0]
        if raw[aci:aci + 4] != b'ACI0':
            raise StageError('取不到现行程序号')
        return f'{struct.unpack_from("<Q", raw, aci + 0x10)[0]:016X}'

    def _nxu(self, work):
        explicit = os.environ.get('S2A_NX_UNPACK')
        if explicit:
            tool = Path(explicit)
            if not tool.is_file():
                raise StageError('S2A_NX_UNPACK未就绪', 75)
            return tool
        source = REPO / 'pack/nx_unpack'
        inputs = [*sorted(source.glob('*.cs')), *sorted(source.glob('*.csproj'))]
        if not inputs:
            raise StageError('缺nx_unpack源码')
        identity = hashlib.sha256(b''.join(p.read_bytes() for p in inputs)).hexdigest()[:12]
        dest = self._run_root() / 's2arm/bin' / ('nx_unpack_' + identity)
        name = 'nx_unpack.exe' if os.name == 'nt' else 'nx_unpack'
        pre = os.environ.get('S2A_PREBUILT_TOOLS')   # 启动器随发版预编（同 oneclick_win.nx_unpack，身份相同才用）：玩家机只带 .NET 运行时、现编不了
        if pre:
            tool = Path(pre, 'nx_unpack', name)
            try:
                if tool.is_file() and (tool.parent / '.src_digest').read_text(encoding='utf-8').strip() == identity:
                    return tool
            except OSError:
                pass
        if (dest / name).is_file() and not is_link(dest):
            return dest / name
        dotnet = os.environ.get('DOTNET') or shutil.which('dotnet')
        if not dotnet or not (source / 'obj/project.assets.json').is_file():
            raise StageError('nx_unpack的既有.NET/离线还原资产未就绪；不下载、不跑旧工具', 75)
        dest.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=dest.name + '.tmp.', dir=dest.parent) as temporary:
            output = Path(temporary) / 'build'
            log = work / 'nx_unpack-build.log'
            run([dotnet, 'build', source, '--no-restore', '-c', 'Release', '-o', output,
                 '-m:2', '-nr:false', '-p:UseSharedCompilation=false'], log=log)
            if not (output / name).is_file():
                raise StageError('nx_unpack构建退出成功但缺当前宿主可执行文件')
            try:
                output.rename(dest)
            except OSError as error:
                if error.errno not in (errno.EEXIST, errno.ENOTEMPTY) or is_link(dest) or not (dest / name).is_file():
                    raise
        return dest / name

    @staticmethod
    def _source_files():
        # 只认调用方给的原件目录（Mac 出包与一键出包都设 S2A_GAME_SRC）。v0.2.3 清理：去掉没设时退回扫 ~/Downloads 的兜底——
        #   10-26 扫 Downloads 弹出访问授权框（build.py 注释），玩家流程用不上它
        if not os.environ.get('S2A_GAME_SRC'):
            return []
        directory = Path(os.environ['S2A_GAME_SRC'])
        if not directory.is_dir():
            return []
        found = []
        # Same maximum depth and excluded directory names as src_ids. Follow
        # source links for identity, but never delete or write source files.
        for parent, dirs, names in os.walk(directory, followlinks=True):
            depth = len(Path(parent).relative_to(directory).parts)
            dirs[:] = sorted(d for d in dirs if not d.startswith('.') and d not in ('$RECYCLE.BIN', 'System Volume Information')) if depth < 3 else []
            for name in names:
                p = Path(parent) / name
                if p.suffix.lower() in ('.xci', '.nsp', '.nsz', '.xcz') and not name.startswith('._') and p.is_file():   # ._ = exFAT 上的访达附属文件
                    if '\n' in str(p) or '\t' in str(p):
                        raise StageError('原件路径不能含TAB/换行', 3)
                    found.append(p.absolute())
        return sorted(found, key=lambda p: os.fsencode(str(p)))

    @staticmethod
    def _source_identity(paths):
        rows = []
        for p in paths:
            st = p.stat()
            rows.append(f'{st.st_size} {st.st_mtime_ns} {st.st_ctime_ns} {st.st_ino}')
        return '\n'.join(rows)

    def _source_rows(self, tool, work, env):
        cache = Path(env.get('S2A_SRC_IDS', Path(env.get('S2A_ICONS', self._run_root() / 's2arm/icons')) / '.ids.tsv'))
        old = [line.split('\t') for line in read(cache).splitlines()]
        rows = []
        keys = env.get('S2A_KEYS', str(Path.home() / '.switch/prod.keys'))
        for number, path in enumerate(self._source_files()):
            st = path.stat()
            identity = [str(path), str(st.st_size), f'{st.st_mtime_ns // 10**9}.{st.st_mtime_ns % 10**9:09d}']   # 纳秒，同 pack/srcs.sh（审计 P1-54）
            # Same contract as pack/srcs.sh src_ids: one container may hold several
            # base programs (a game plus a bundled art-book app); each program id
            # gets its own row, and a cached multi-base file has several rows.
            pids = list(dict.fromkeys(row[3] for row in old if len(row) == 4 and row[:3] == identity))
            if not pids:
                probe = work / ('identify-' + str(number))
                probe.mkdir()
                log = work / ('identify-' + str(number) + '.log')
                _, rc = run([tool, keys, probe, '--nacp-only', path], env=env, log=log, allowed=(0, 1, 3))
                metadata = dict(line.split('\t', 1) for line in read(probe / 'unpack.tsv').splitlines() if '\t' in line)
                pids = [metadata.get('title_id', '-').upper()]
                if rc == 1 and re.search('基础程序应恰好 1 个.*实际 ([2-9]|[1-9][0-9]+)', read(log)):
                    out, code = run([tool, keys, '--inspect', path], env=env, allowed=(0, 3))
                    try:
                        bases = sorted({p['titleId'].upper() for p in json.loads(out)['packages'] if p.get('type') == 'base'}) if code == 0 else []
                    except (ValueError, KeyError, TypeError, AttributeError):
                        bases = []
                    if len(bases) >= 2:
                        pids, rc = bases, 0
                if any(pid != '-' and not re.fullmatch('[0-9A-F]{16}', pid) for pid in pids):
                    raise StageError('nx_unpack返回非法程序号')
                if rc == 0:
                    cache.parent.mkdir(parents=True, exist_ok=True)
                    with cache.open('a', encoding='utf-8', newline='\n') as stream:
                        stream.write(''.join('\t'.join([*identity, pid]) + '\n' for pid in pids))
            rows.extend([*identity, pid.upper()] for pid in pids)
        return rows

    def _nacp(self, game):
        start = time.perf_counter()
        current = self._light_current(game)
        if (current / 'ctl/control.nacp').is_file():
            return self._result('nacp', start, current, None, skipped=True)
        with tempfile.TemporaryDirectory(prefix='s2a-nacp-', dir=current.parent) as scratch:
            work = Path(scratch)
            tool = self._nxu(work)
            env = dict(os.environ, PYTHONIOENCODING='utf-8')
            pid = self._program_id(current)
            rows = [row for row in self._source_rows(tool, work, env) if row[3] in (pid, '-')]
            if not any(row[3] == pid for row in rows):
                raise StageError('缺本款原始包，无法补ctl/control.nacp', 3)
            tag = 'nacp-' + (current / 'exefs/main').read_bytes()[0x40:0x44].hex()
            tx = self.roots.begin(game, self.roots.tag(game, tag))
            try:
                run([tool, env.get('S2A_KEYS', str(Path.home() / '.switch/prod.keys')), tx.path,
                     '--nacp-only', '--title-id=' + pid, *[row[0] for row in rows]], env=env, log=tx.path / 'nacp.log')
                if not (tx.path / 'ctl/control.nacp').is_file():
                    raise StageError('nx_unpack成功却未产出ctl/control.nacp')
                self._light_log(tx.path / 'nacp.log')
                # The original stage has no stamp/manifest or restricted replay.
                return self._light_commit(tx, 'nacp', start, None)
            except BaseException:
                tx.abort()
                raise

    @staticmethod
    def _aoc_base(current, rows, tool):
        paths = [Path(row[0]) for row in rows]
        raw = '\n'.join('\t'.join(row) for row in rows) + '\n'
        raw += Stages._source_identity(paths) + '\n'
        dll = Path(str(tool) + '.dll') if tool.suffix.lower() != '.exe' else tool.with_suffix('.dll')
        for binary in (dll, tool):
            if binary.is_file():
                raw += hashlib.sha256(binary.read_bytes()).hexdigest() + '  -\n'
        with (current / 'exefs/main').open('rb') as stream:
            stream.seek(0x40)
            raw += stream.read(16).hex() + '\n'
        return digest(raw)

    def _aoc_extract(self, tool, current, rows, output, deps):
        env = dict(deps.env)
        env.pop('S2A_HDD_READ', None)
        keys = env.get('S2A_KEYS', str(Path.home() / '.switch/prod.keys'))
        (output / 'exefs').mkdir()
        copy_file(current / 'exefs/main', output / 'exefs/main')
        log = output / 'aoc.log'
        # rows are pre-filtered to this game's program id plus unidentified '-'
        # files; a multi-base container needs the id so nx_unpack takes this game.
        title = '--title-id=' + next(row[3] for row in rows if row[3] != '-')
        _, rc = run([tool, keys, output, '--aoc-only', title, *[row[0] for row in rows]],
                    env=env, log=log, allowed=(0, 1, 3))
        if rc == 0 and not (output / 'aoc.tsv').is_file():
            raise StageError('nx_unpack成功却未产出aoc.tsv')
        missing = []
        if rc:
            why = read(log).splitlines()[-1:] or ['追加内容解包失败']
            remove_owned(output / 'aoc')
            (output / 'aoc.tsv').unlink(missing_ok=True)
            context, dlc = [], []
            for row in rows:
                if row[3] != '-':
                    context.append(row[0]); continue
                inspected, code = run([tool, keys, '--inspect', row[0]], env=env, allowed=(0, 1, 3))
                try:
                    kinds = {p['type'] for p in json.loads(inspected)['packages']} if code == 0 else None
                except (ValueError, KeyError, TypeError):
                    kinds = None
                if kinds is None:
                    missing.append((Path(row[0]).name, '读不出内容清单（nx_unpack --inspect）'))
                elif kinds == {'dlc'}:
                    dlc.append(row[0])
                else:
                    context.append(row[0])
            successful = []
            for number, path in enumerate(dlc):
                part = output / ('part' + str(number))
                (part / 'exefs').mkdir(parents=True)
                copy_file(output / 'exefs/main', part / 'exefs/main')
                _, code = run([tool, keys, part, '--aoc-only', title, *context, path], env=env,
                              log=part / 'aoc.log', allowed=(0, 1, 3))
                if code == 0 and (part / 'aoc.tsv').is_file():
                    successful.append(part)
                else:
                    message = read(part / 'aoc.log').splitlines()[-1:] or ['追加内容解包失败']
                    missing.append((Path(path).name, message[0]))
            if not dlc:
                missing.extend((Path(path).name, why[0]) for path in context)
            if successful:
                self._aoc_merge_parts(output, successful)
            for part in output.glob('part*'):
                if part.is_dir():
                    remove_owned(part)
        remove_owned(output / 'exefs')
        plain_entries(output)
        with log.open('a', encoding='utf-8', newline='\n') as stream:
            for name, message in missing:
                message = message.replace('\t', ' ').replace('\n', ' ')[:160]
                stream.write(f'追加内容缺\t{name}\t{message}\n')
        canonical_text([log, output / 'aoc.tsv'])
        self._light_log(log)
        return missing, not (output / 'aoc.tsv').is_file()

    @staticmethod
    def _aoc_merge_parts(output, parts):
        rows, header = {}, 'idx\ttitle_id\tversion\tfiles\tbytes'
        (output / 'aoc').mkdir(exist_ok=True)
        with (output / 'aoc.log').open('a', encoding='utf-8', newline='\n') as log:
            for part in parts:
                plain_entries(part)
                lines = read(part / 'aoc.tsv').splitlines()
                if lines:
                    header = lines[0]
                for line in lines[1:]:
                    index = line.split('\t', 1)[0]
                    if not line.strip() or index in rows:
                        continue
                    if not index.isdecimal():
                        raise StageError('追加内容序号非法')
                    rows[index] = line
                    source = part / 'aoc' / index
                    if source.is_dir():
                        source.rename(output / 'aoc' / index)
                log.write((part / 'aoc.log').read_text(encoding='utf-8'))
        text(output / 'aoc.tsv', header + '\n' + ''.join(rows[k] + '\n' for k in sorted(rows)))

    def _aoc(self, game):
        start = time.perf_counter()
        current = self._light_current(game)
        deps = Dependencies('aoc', current)
        deps.record('pack/srcs.sh')
        try:
            tool = self._nxu(deps.work)
            pid = self._program_id(current)
            rows = [row for row in self._source_rows(tool, deps.work, deps.env) if row[3] in (pid, '-')]
            if not any(row[3] == pid for row in rows):
                print('【黄】本机没有本款原始包，追加内容跳过、现行不动', file=sys.stderr)
                return self._result('aoc', start, current, None, skipped=True)
            base = self._aoc_base(current, rows, tool)
            key = deps.key(base)
            if read(current / '.stage_aoc') == key:
                return self._result('aoc', start, current, base, skipped=True)
            cache = Path(os.environ.get('S2A_AOC_CACHE', self._run_root() / 's2arm/cache/aoc')) / (game + '-' + key)
            if is_link(cache) or is_link(cache.parent):
                raise StageError('追加内容缓存不能是链接')
            cache.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix=cache.name + '.tmp.', dir=cache.parent) as scratch:
                output = Path(scratch) / 'output'
                missing, keep = [], False
                if (cache / 'aoc.tsv').is_file():
                    plain_entries(cache)
                    source = cache
                else:
                    output.mkdir()
                    missing, keep = self._aoc_extract(tool, current, rows, output, deps)
                    source = output
                    if not missing and not keep:
                        try:
                            output.rename(cache)
                        except OSError as error:
                            if error.errno not in (errno.EEXIST, errno.ENOTEMPTY) or is_link(cache) or not (cache / 'aoc.tsv').is_file():
                                raise
                        plain_entries(cache)
                        source = cache
                if keep:
                    wanted = [line for line in read(source / 'aoc.log').splitlines() if line.startswith('追加内容缺\t')]
                    previous = [line for line in read(current / 'aoc.log').splitlines() if line.startswith('追加内容缺\t')]
                    if wanted == previous:
                        return self._result('aoc', start, current, None, skipped=True)
                tx = self.roots.begin(game, self.roots.tag(game, 'aoc-' + key[:8]), env=deps.env)
                try:
                    (tx.path / 'aoc.log').unlink(missing_ok=True)
                    copy_file(source / 'aoc.log', tx.path / 'aoc.log')
                    if keep:
                        return self._light_commit(tx, 'aoc', start, None, ('aoc.log',))
                    remove_owned(tx.path / 'aoc')
                    if (source / 'aoc').is_dir():
                        self.roots._copy_tree(source / 'aoc', tx.path / 'aoc')
                    (tx.path / 'aoc.tsv').unlink(missing_ok=True)
                    copy_file(source / 'aoc.tsv', tx.path / 'aoc.tsv')
                    deps.save(tx.path, base)
                    return self._light_commit(tx, 'aoc', start, base,
                        ('aoc', 'aoc.tsv', 'aoc.log', '.stage_aoc', '.stage_aoc.deps'))
                except BaseException:
                    tx.abort()
                    raise
        finally:
            deps.close()
