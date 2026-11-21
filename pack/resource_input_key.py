#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""资源内容键及根外派生摘要缓存；大文件仍只采首尾各64KiB。

已提交输入在一次阶段操作内保持不变。--clone-result只接root_begin的
成功输出；生产由roots.sh在暴露新根/写owner之前统一迁移，不接受任意目录作克隆证明。
"""
import os as _pw_os, sys as _pw_sys; _pw_sys.path.append(_pw_os.path.join(_pw_os.path.dirname(_pw_os.path.abspath(__file__)), '..', 'tools')); from pool_workers import env_jobs  # noqa: E402  核数 / 进程池路数唯一来源（tools/pool_workers.py，#1332）
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

# 仓库里唯一的 RomFS 遍历（graphics/nvn/tools/romfs_list.py）
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'graphics' / 'nvn' / 'tools'))
import romfs_list
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from progress import Ticker   # 出包进度（tools/progress.py，不进阶段键）

BLOCK = 64 * 1024
SCHEMA = 2
HELPER_SHA = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def signature(info):
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
            info.st_ctime_ns, stat.S_IFMT(info.st_mode)]


def inventory(root):
    if not stat.S_ISDIR((root / 'exefs').lstat().st_mode):
        raise ValueError('exefs is not a directory')
    main = (root / 'exefs/main').lstat()
    if not stat.S_ISREG(main.st_mode):
        raise ValueError('main is not a regular file')
    entries = {'exefs/main': signature(main)}
    pending = []
    for top in ('romfs', 'aoc'):
        base = root / top
        try:
            info = base.lstat()
        except FileNotFoundError:
            # RomFS 不落散文件（11-16）：目录不在、旁边有 <目录>.std 标准镜像 → 成员从镜像盘点（romfs_list），名字 / 大小 / 抽样字节与目录形态相同，键不变
            if romfs_list.image_of(base) is not None:
                pending.append((str(base), top))
                continue
            if top == 'romfs':
                raise
            continue
        # 产物根的 romfs 可以是指向本款 RomFS 共享存储的相对软链（pack/roots.sh _root_romfs_link 同一判法）：
        # 只认 ../.romfs_store/<本款>/<身份>、身份目录是真目录；其余软链照旧拒绝
        if stat.S_ISLNK(info.st_mode) and top == 'romfs':
            link = os.readlink(base)
            store = f'../.romfs_store/{root.name.split("@")[0]}/'
            ident = link[len(store):] if link.startswith(store) else ''
            target = root.parent / '.romfs_store' / root.name.split('@')[0] / ident
            if not ident or '/' in ident or ident.startswith('.') or target.is_symlink() or not target.is_dir():
                raise ValueError('romfs link is not this title\'s RomFS store')
        elif not stat.S_ISDIR(info.st_mode):
            raise ValueError('resource root is not a directory')
        pending.append((str(base), top))
    for folder, relative in pending:
        # 盘点经 graphics/nvn/tools/romfs_list.py（仓库里唯一的 RomFS 遍历：scandir + lstat，每次调用都现盘点）；
        # 目录打不开 / lstat 失败照原先抛出，链接与特殊文件照原先拒绝
        tree = romfs_list.scan(folder)
        for error in tree.errors.values():
            raise error
        image = tree.image.path if tree.image is not None else None
        for child in tree.entries:
            if child.lstat_error is not None:
                raise child.lstat_error
            info = child.lstat
            name = relative + '/' + child.rel
            if stat.S_ISDIR(info.st_mode):
                continue
            elif stat.S_ISREG(info.st_mode):
                entries[name] = signature(info) if image is None else image_signature(image, info.st_size)
            else:
                raise ValueError('resource is not a regular file or directory')
    return dict(sorted(entries.items(), key=lambda row: os.fsencode(row[0])))


def inventories(*roots):
    """几个根同时盘点（各自一棵 scandir + lstat，线程里等盘、不占解释器）：克隆交接要同时看源与新根"""
    with ThreadPoolExecutor(max_workers=len(roots)) as pool:
        return list(pool.map(inventory, roots))


def memo_path(root):
    root = Path(root).resolve(strict=True)
    info = root.stat()
    return root.parent / '.resource-input-cache' / f'{info.st_dev}-{info.st_ino}.json'


def encoded(payload):
    return json.dumps(payload, sort_keys=True, ensure_ascii=True, separators=(',', ':')).encode()


def load_memo(root, raw=None):
    try:
        wrapper = json.loads(memo_path(root).read_text() if raw is None else raw)
        payload = wrapper['payload']
        if wrapper['checksum'] != hashlib.sha256(encoded(payload)).hexdigest():
            return None
        if payload.get('kind') != 's2arm-resource-input-key' or payload['schema'] != SCHEMA or payload['block'] != BLOCK or payload.get('helper_sha') != HELPER_SHA:
            return None
        key = payload['key']
        if len(key) != 16 or len(bytes.fromhex(key)) != 8:
            return None
        for name, entry in payload['entries'].items():
            if len(entry['signature']) != 6 or not all(isinstance(x, int) for x in entry['signature']):
                return None
            if len(entry['digest']) != 64 or len(bytes.fromhex(entry['digest'])) != 32:
                return None
        return payload
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def save_memo(root, entries, key):
    path = memo_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {'kind': 's2arm-resource-input-key', 'schema': SCHEMA, 'block': BLOCK, 'helper_sha': HELPER_SHA, 'entries': entries, 'key': key}
    wrapper = {'payload': payload, 'checksum': hashlib.sha256(encoded(payload)).hexdigest()}
    fd, temp = tempfile.mkstemp(prefix='.resource-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(json.dumps(wrapper, ensure_ascii=True, separators=(',', ':')))
        os.replace(temp, path)
        # 根轮转只留少数版本；仅回收本协议生成且对应目录inode已不在的派生memo。
        live = {f'{info.st_dev}-{info.st_ino}.json' for directory in root.parent.iterdir()
                if directory.is_dir() for info in [directory.stat()]}
        for previous in path.parent.glob('*.json'):
            if previous.name in live:
                continue
            try:
                wrapper_old = json.loads(previous.read_text())
                payload_old = wrapper_old['payload']
                if (payload_old.get('kind') == 's2arm-resource-input-key' and
                    wrapper_old['checksum'] == hashlib.sha256(encoded(payload_old)).hexdigest()):
                    previous.unlink(missing_ok=True)
            except (OSError, ValueError, KeyError, TypeError, AttributeError):
                pass  # 不清理不认识/无法核证的文件。
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def title_memo_path(root):
    """同款跨根的摘要缓存（11-05 根修）：产物根重新克隆后目录 inode 变了、按根取的 memo 取不到，18.6 万文件全部重采约 8 分钟。
    按款（根名 @ 前）存一份「路径 → 字节数 + mtime + 设备号 + inode + 摘要」，新根按 字节数 + mtime 相同、且设备号 + inode 与记录的不同
    （确是别的根里的另一份文件：克隆保留字节数与 mtime，inode / ctime 必变）复用摘要。同一份文件（inode 相同）不借：按根缓存坏了 / 换了工具版本时
    它可能已被原地改过，只能重采。"""
    root = Path(root).resolve(strict=True)
    return root.parent / '.resource-input-cache' / f'title-{root.name.split("@")[0]}.json'


def load_title_memo(root):
    try:
        wrapper = json.loads(title_memo_path(root).read_text())
        payload = wrapper['payload']
        if wrapper['checksum'] != hashlib.sha256(encoded(payload)).hexdigest():
            return {}
        if payload.get('kind') != 's2arm-resource-title-digests' or payload['schema'] != SCHEMA or payload['block'] != BLOCK or payload.get('helper_sha') != HELPER_SHA:
            return {}
        return {n: e for n, e in payload['entries'].items()
                if isinstance(e, list) and len(e) == 5 and all(isinstance(x, int) for x in e[:4]) and len(bytes.fromhex(e[4])) == 32}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return {}


def save_title_memo(root, entries):
    """kind 与按根 memo 不同，save_memo 的过期回收不会删它；每次算完整份覆盖（只留本根现有成员）"""
    path = title_memo_path(root)
    payload = {'kind': 's2arm-resource-title-digests', 'schema': SCHEMA, 'block': BLOCK, 'helper_sha': HELPER_SHA,
               'entries': {n: [e['signature'][2], e['signature'][3], e['signature'][0], e['signature'][1], e['digest']] for n, e in entries.items()}}
    wrapper = {'payload': payload, 'checksum': hashlib.sha256(encoded(payload)).hexdigest()}
    fd, temp = tempfile.mkstemp(prefix='.resource-title-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(json.dumps(wrapper, ensure_ascii=True, separators=(',', ':')))
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def image_signature(image, size):
    """镜像里的成员（没有自己的 inode / 时间）：设备、inode、修改 / 变更时间取镜像文件本身，大小取成员的；镜像换了或被改 → 签名变 → 重采"""
    info = os.stat(image)
    return [info.st_dev, info.st_ino, size, info.st_mtime_ns, info.st_ctime_ns, stat.S_IFREG]


def read_digest(path, expected, full, image=None):
    """image：成员在 RomFS 镜像里时给镜像路径（内容经 romfs_list.open_file 从镜像读，前后核镜像文件的签名）"""
    h = hashlib.sha256()
    if image is None:
        opened, now = path.open('rb'), lambda stream: signature(os.fstat(stream.fileno()))
        settled = lambda: signature(path.lstat())
    else:
        opened, now = romfs_list.open_file(path), lambda stream: image_signature(image, romfs_list.file_size(path))
        settled = lambda: image_signature(image, romfs_list.file_size(path))
    with opened as stream:
        if now(stream) != expected:
            raise OSError('resource changed before hashing')
        if full:
            for data in iter(lambda: stream.read(1024 * 1024), b''):
                h.update(data)
        elif expected[2] <= 2 * BLOCK:
            data = stream.read(2 * BLOCK + 1)
            if len(data) != expected[2]:
                raise OSError('resource changed while hashing')
            h.update(data)
        else:
            head = stream.read(BLOCK)
            if len(head) != BLOCK:
                raise OSError('short resource sample read')
            h.update(head)
            stream.seek(-BLOCK, 2)
            tail = stream.read(BLOCK)
            if len(tail) != BLOCK or stream.tell() != expected[2]:
                raise OSError('resource changed while hashing')
            h.update(tail)
        if now(stream) != expected or settled() != expected:
            raise OSError('resource changed while hashing')
    return h.hexdigest()


def resource_key(root):
    root = Path(root).resolve(strict=True)
    current = inventory(root)
    memo = load_memo(root)
    old = memo['entries'] if memo else {}
    if memo and set(old) == set(current) and all(old[n]['signature'] == sig for n, sig in current.items()):
        return memo['key']  # 已验证全部成员/身份，不再读输入字节或重算汇总键。
    changed = [(name, sig) for name, sig in current.items()
               if name not in old or old[name]['signature'] != sig]
    images = {top: romfs_list.image_of(root / top) for top in ('romfs', 'aoc')}
    def sample(row):
        name, sig = row
        image = images.get(name.split('/')[0])
        args = (root / name, sig, name == 'exefs/main') + ((image,) if image else ())
        return name, {'signature': sig, 'digest': read_digest(*args)}
    entries = {name: old[name] for name, sig in current.items() if name in old and old[name]['signature'] == sig}
    # 本根 memo 里从没出现过的路径（新克隆的根、memo 按根目录 inode 取不到），再按同款摘要缓存：字节数 + mtime 都相同就复用
    #   （exefs/main 整份哈希、很小，始终重算）。本根 memo 里有、身份变了的（原地改字节再把 mtime 改回 / 替换）一律重采：
    #   同款缓存只证「别的根里有过这份内容」，证不了本根这份没被原地改过（审计 P1-54：大小 + 修改时间不变也得认出内容变，tests/pkg_key_inputs_test.sh）
    if changed:
        same = load_title_memo(root)
        hit = {name: {'signature': sig, 'digest': same[name][4]} for name, sig in changed
               if name != 'exefs/main' and name not in old and name in same and same[name][:2] == [sig[2], sig[3]] and same[name][2:4] != [sig[0], sig[1]]}
        entries.update(hit)
        changed = [row for row in changed if row[0] not in hit]
    workers = min(env_jobs('S2A_JOBS'), max(1, len(changed)))
    # 进度（S2A_PROGRESS）：新解包 / 新克隆的根要逐个文件读首尾抽样（一款大作 4.8 万个文件约 6 GB、二十多秒），原先没有计数，界面在抽取开工前停半分钟
    tk = Ticker('游戏输入键', len(changed))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for name, entry in pool.map(sample, changed):
            entries[name] = entry; tk.step()
    if inventory(root) != current:
        raise OSError('resource membership changed while hashing')
    h = hashlib.sha256(b's2arm-resource-inputs-v1\0')
    h.update(bytes.fromhex(entries['exefs/main']['digest']))
    for name in current:
        if name == 'exefs/main':
            continue
        relative = os.fsencode(name)
        h.update(len(relative).to_bytes(8, 'little') + relative +
                 current[name][2].to_bytes(8, 'little') + bytes.fromhex(entries[name]['digest']))
    key = h.hexdigest()[:16]
    save_memo(root, entries, key)
    save_title_memo(root, entries)
    return key


def inherit_cache(source, target, expected_key=None, before_owner=False):
    """内部克隆交接：source固定为已算KR的不可变根，target尚未交给阶段写入。

    普通外部目录不得调用此协议；生产只在roots.sh内部刚完成真实克隆时调用。
    缺快照/发生并发输入变化均报错，不把元数据近似当成内容证明。
    """
    source, target = Path(source).resolve(strict=True), Path(target).resolve(strict=True)
    memo = load_memo(source)
    if not memo or (expected_key is not None and memo['key'] != expected_key):
        raise ValueError('fixed source input snapshot is unavailable')
    if target.parent != source.parent:
        raise ValueError('not a same-parent clone handoff')
    before, after = inventories(source, target)
    if before_owner:
        # roots.sh紧接clonedir，在.root_pid和调用方可见之前调用；源为不可变现行。
        # replay也在重放路径写入前交接，随后输入写入仍由逐文件ctime使摘要失效。
        if not target.name.endswith(('.tmp', '.tmp.rb')) or (target / '.root_pid').exists():
            raise ValueError('not an unpublished root clone')
    else:
        # 保留旧内部接口的标记/写入守卫，不能把已交给调用方的目录当刚克隆。
        if not target.name.endswith('.tmp') or (target / '.root_base').read_text().strip() != source.name:
            raise ValueError('not a root_begin clone handoff')
        handoff_ns = (target / '.root_pid').stat().st_mtime_ns
        if any(sig[4] > handoff_ns for sig in after.values()):
            raise ValueError('clone target was written after root_begin')
    if set(before) != set(memo['entries']) or set(after) != set(before):
        raise ValueError('clone input membership differs')
    for name, sig in before.items():
        if sig != memo['entries'][name]['signature'] or (after[name][2], after[name][3]) != (sig[2], sig[3]):
            raise ValueError('clone source snapshot changed')
    # 交接前复核两边没被并发改动。root_begin 刚克隆（before_owner）不复核：源是现行（阶段只写克隆、提交只换现行指向，不改旧版本），
    # 新根还没有持有者（上面已核 .tmp 名、没有 .root_pid），这段时间没有任何写者；复核两遍盘点在 Spare-host 上火纹约 11 秒、每个阶段一次（11-03 实测）
    if not before_owner and inventories(source, target) != [before, after]:
        raise OSError('source changed during clone handoff')
    entries = {name: {'signature': sig, 'digest': memo['entries'][name]['digest']} for name, sig in after.items()}
    save_memo(target, entries, memo['key'])


def publish_once(root, key):
    path = os.environ.get('S2A_RESOURCE_KEY_ONCE_FILE')
    if not path:
        return
    root = Path(root).resolve(strict=True)
    raw = memo_path(root).read_bytes()
    memo = load_memo(root, raw)
    if not memo or memo['key'] != key:
        raise ValueError('input snapshot changed before handoff')
    info = root.stat()
    line = f's2a-resource-once-v2\t{info.st_dev}:{info.st_ino}\t{key}\t{hashlib.sha256(raw).hexdigest()}\t{HELPER_SHA}\n'
    path = Path(path)
    fd, temp = tempfile.mkstemp(prefix='.resource-once-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(line)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--root-clone':
        # 缓存只是加速；所有异常由roots.sh降级为空摘要，不影响真实克隆/阶段。
        source, target = sys.argv[2:]
        memo = load_memo(source)
        if memo:
            inherit_cache(source, target, memo['key'], before_owner=True)
    elif len(sys.argv) == 3 and sys.argv[1] == '--root-publish':
        # clone后调用方仍可能改main/romfs；只有提交完成且输入签名全同才能发快路径。
        root = Path(sys.argv[2]).resolve(strict=True)
        memo = load_memo(root)
        if memo and not (root / '.root_pid').exists():
            current = inventory(root)
            if set(current) == set(memo['entries']) and all(memo['entries'][n]['signature'] == sig for n, sig in current.items()):
                publish_once(root, memo['key'])
    elif len(sys.argv) == 4 and sys.argv[1] == '--clone-result':
        # 此时root_begin还未把W暴露给调用脚本；该脚本是唯一新根写者。
        target = sys.stdin.read().strip()
        inherit_cache(sys.argv[2], target, sys.argv[3])
        publish_once(target, sys.argv[3])
        print(target)
    elif len(sys.argv) == 2:
        key = resource_key(sys.argv[1])
        publish_once(sys.argv[1], key)
        print(key)
    else:
        raise SystemExit('usage: resource_input_key.py ROOT | --clone-result SOURCE KEY < root_begin-output')
