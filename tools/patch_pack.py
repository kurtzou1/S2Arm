#!/usr/bin/env python3
"""社区补丁统一包（不是 tools/patch_bundle.py：那个是启动器随发版带的我方真机验过补丁）（11-13 维护者：补丁由我们的下载站分发、长期跟踪上游，上线后 README 显眼处致谢与来源说明）。
我方这边跑：读上游镜像（同 tools/patch_index.py：本地浅克隆，路径按上游真实大小写），压缩包在这里解开，按游戏整理成统一包，写到输出目录，
由 private-tools 的发布脚本传 dl.s2arm.com/patches/v2/。玩家出包时 pack/jobs/patches.py 只向下载站要这一款的包（不再逐个上游下载、不再在玩家机器上解 rar）。

用法：patch_pack.py <上游镜像目录> <输出目录> [<管线种子目录>]
  管线种子目录（可选，我方真跑产出）：<目录>/<程序号>/*.tsv，每份是真跑记下的 pso_user.tsv（S / R / C 行，R 行 = pso_skey 十六进制，布局 graphics/tools/direct/pso_layout.json）。
    进这款的 g/<程序号> 包，条目 kind = cat = pso；玩家出包时 pack/jobs/patches.py 交管线种子阶段当来源，首局加载页后台预建这些管线（多等一下换游戏内不卡）。
    不按构建号分：别的版本的行出包时按本包直连库的键滤掉（graphics/tools/direct/pso_seed.py），不会编错。
输出（同输入同输出：gzip 不带时间、行按固定顺序，内容没变的包字节不变，发布脚本只传变了的）：
  g/<程序号>.json.gz   这款的全部条目（路径或包内路径写了程序号的）
  b/<构建号前16位>.json.gz   没写程序号、只能按主程序构建号认的条目（pchtxt 的 @nsobid / ips 文件名 / 金手指文件名）
  index.json            {schema, generated, upstreams: {库: 提交号}, bundles: {"g/<程序号>" | "b/<构建号>": {sha256, size, items}}}
  snapshot.tar          以上全部（随启动器安装的本地补丁库，stage_snapshot 放进启动器资源 CommunityPatches/patches-v2.tar）
包：{schema: 2, key, items: [条目]}；条目：
  id（内容 sha256 前 16 位，同 pack/cpatch.py 编号口径）、kind（pchtxt | ips | fpsl | cheat | pso）、cat（fps | widescreen | gfx | cheat | pso）、
  name（文件名：ips / FPSLocker / 金手指靠文件名认构建号，原样保留；pchtxt 取原文件名）、bids、gids、target_fps、aspect、
  source {repo, commit, path, member}（上游原处，致谢与追溯用；金手指汇总库的 member 是构建号）、license、author、sha256（内容）、data（内容 base64，字节与上游原文件一致，不转格式：
  编号按内容算，转了格式编号就变，玩家已开的选择与验证记录会对不上）。"""
import base64
import gzip
import hashlib
import io
import json
import os
import subprocess
import sys
import time
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import patch_index   # noqa: E402  扫描、分类、去重、路径大小写同一份


def content(mirror, row):
    """条目的字节：散文件读镜像（路径按本地：镜像在不分大小写的盘上，上游大小写只用于来源记录），包内的再解一次"""
    if '_data' in row:
        return row['_data']
    local = os.path.join(mirror, row['repo'].replace('/', '__', 1), row['_local'])
    if not row.get('member'):
        return open(local, 'rb').read()
    if local.lower().endswith('.zip'):
        with zipfile.ZipFile(local) as z:
            return z.read(row['member'])
    return subprocess.run(['bsdtar', '-xOf', local, row['member']], capture_output=True, check=True, timeout=60).stdout


def item(row, data):
    return dict(id=row['sha256'][:16], kind=row['kind'], cat=row['cat'], name=os.path.basename(row.get('member') or row['path']),
                bids=row['bids'], gids=row['gids'], target_fps=row['target_fps'], aspect=row['aspect'],
                source=dict(repo=row['repo'], commit=row['commit'], path=row['path'], member=row.get('member', '')),
                license=row['license'], author=row.get('author', ''), sha256=row['sha256'], data=base64.b64encode(data).decode())


def gz(obj):
    raw = json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode='wb', mtime=0, compresslevel=9) as f:
        f.write(raw)
    return buf.getvalue()


def seed_rows(seeds):
    """管线种子（<目录>/<程序号>/*.tsv）→ 与上游条目同形的行（_data 带内容）；程序号按 16 位十六进制认，别的目录 / 非 .tsv 不收"""
    rows = []
    for g in sorted(os.listdir(seeds)) if seeds else []:
        d = os.path.join(seeds, g)
        if not (os.path.isdir(d) and len(g) == 16 and all(ch in '0123456789abcdefABCDEF' for ch in g)):
            continue
        for f in sorted(os.listdir(d)):
            if f.endswith('.tsv') and os.path.isfile(os.path.join(d, f)):
                data = open(os.path.join(d, f), 'rb').read()
                rows.append(dict(_data=data, sha256=hashlib.sha256(data).hexdigest(), kind='pso', cat='pso', path=f'{g.upper()}/{f}', bids=[], gids=[g.upper()],
                                 target_fps='', aspect='', repo='S2Arm/pso-seeds', commit='', license='', author='S2Arm'))
    return rows


def build(mirror, out, seeds=None):
    rows = patch_index.dedupe(patch_index.scan(mirror, keep_local=True, cheat_libs=True)) + seed_rows(seeds)
    groups, upstreams, bad = {}, {}, 0
    for r in rows:
        if r['kind'] != 'pso':   # 我方种子不算上游
            upstreams[r['repo']] = r['commit']
        try:
            data = content(mirror, r)
        except (OSError, KeyError, zipfile.BadZipFile, subprocess.SubprocessError):
            bad += 1; continue
        if hashlib.sha256(data).hexdigest() != r['sha256']:
            bad += 1; continue
        keys = [f'g/{g}' for g in r['gids']] or sorted({f'b/{b[:16].upper()}' for b in r['bids'] if len(b) >= 16})
        for k in keys:
            groups.setdefault(k, []).append(item(r, data))
    os.makedirs(os.path.join(out, 'g'), exist_ok=True); os.makedirs(os.path.join(out, 'b'), exist_ok=True)
    bundles = {}
    for k, items in sorted(groups.items()):
        items.sort(key=lambda i: (i['cat'], i['source']['repo'], i['source']['path'], i['source']['member'], i['id']))
        blob = gz(dict(schema=2, key=k, items=items))
        p = os.path.join(out, k + '.json.gz')
        if not (os.path.isfile(p) and open(p, 'rb').read() == blob):
            with open(p + '.tmp', 'wb') as f:
                f.write(blob)
            os.replace(p + '.tmp', p)
        bundles[k] = dict(sha256=hashlib.sha256(blob).hexdigest(), size=len(blob), items=len(items))
    for sub in ('g', 'b'):   # 上游删掉的款：本地也删（发布脚本按 index.json 只认在册的）
        for f in os.listdir(os.path.join(out, sub)):
            if f.endswith('.json.gz') and f'{sub}/{f[:-8]}' not in bundles:
                os.remove(os.path.join(out, sub, f))
    index = dict(schema=2, generated=int(time.time()), upstreams=dict(sorted(upstreams.items())), bundles=bundles)
    try:   # 内容没变（包与上游提交都一样）沿用上次的生成时间：清单与快照字节不变，发布脚本不重传
        old = json.load(open(os.path.join(out, 'index.json'), encoding='utf-8'))
        if old.get('bundles') == bundles and old.get('upstreams') == index['upstreams']:
            index['generated'] = old.get('generated', index['generated'])
    except (OSError, ValueError):
        pass
    with open(os.path.join(out, 'index.json.tmp'), 'w', encoding='utf-8') as f:
        json.dump(index, f, ensure_ascii=False, sort_keys=True, indent=0)
    os.replace(os.path.join(out, 'index.json.tmp'), os.path.join(out, 'index.json'))
    print(f'补丁统一包：{len(bundles)} 个包（按游戏 {sum(k.startswith("g/") for k in bundles)}、按构建号 {sum(k.startswith("b/") for k in bundles)}）、'
          f'{sum(b["items"] for b in bundles.values())} 条、{sum(b["size"] for b in bundles.values()) / 1e6:.1f} MB、{len(upstreams)} 个上游；取不出 / 内容不符 {bad} 条 → {out}', file=sys.stderr)
    return index


SNAPSHOT = 'snapshot.tar'   # 随启动器安装的完整快照（11-13 维护者：补丁库随启动器装在本地、云端兜底）：index.json + g/ + b/，不压缩的 tar（里面的包本身是 gz）


def snapshot(out):
    """<输出目录>/snapshot.tar：在册的全部包 + index.json，成员按名字排序、时间 / 属主清零，同输入同字节（发布脚本据此判要不要重传）"""
    import tarfile
    index = json.load(open(os.path.join(out, 'index.json'), encoding='utf-8'))
    names = ['index.json'] + [k + '.json.gz' for k in sorted(index['bundles'])]
    tmp = os.path.join(out, SNAPSHOT + '.tmp')
    with tarfile.open(tmp, 'w', format=tarfile.USTAR_FORMAT) as t:
        for n in names:
            data = open(os.path.join(out, n), 'rb').read()
            ti = tarfile.TarInfo(n); ti.size = len(data); ti.mtime = 0; ti.mode = 0o644; ti.uid = ti.gid = 0; ti.uname = ti.gname = ''
            t.addfile(ti, io.BytesIO(data))
    os.replace(tmp, os.path.join(out, SNAPSHOT))
    return os.path.join(out, SNAPSHOT)


def check_snapshot(path):
    """快照自洽：每个在册包的 sha256 与快照里 index.json 记的一致 → (index, None)；不一致 / 读不了 → (None, 原因)"""
    import tarfile
    try:
        with tarfile.open(path) as t:
            index = json.load(t.extractfile('index.json'))
            for k, v in index.get('bundles', {}).items():
                if hashlib.sha256(t.extractfile(k + '.json.gz').read()).hexdigest() != v['sha256']:
                    return None, f'{k} 与清单不符'
        return index, None
    except (OSError, KeyError, ValueError, tarfile.TarError) as e:
        return None, f'{type(e).__name__}: {e}'


def stage_snapshot(dest_dir, url='https://dl.s2arm.com/patches/v2/' + SNAPSHOT):
    """启动器打包（launchers/macos/build_app.py、launchers/windows/bundle_win.py）：快照放进 <资源>/CommunityPatches/。
    来源 S2A_PATCH_SNAPSHOT（本机文件）> 下载站；核过自洽才放。取不到 / 不自洽 → 不放、回原因（出包时照样向下载站要，只是离线没有本地库）"""
    import urllib.request
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, 'patches-v2.tar')
    src = os.environ.get('S2A_PATCH_SNAPSHOT')
    try:
        if src:
            data = open(src, 'rb').read()
        else:
            with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'S2Arm-build'}), timeout=60) as r:
                data = r.read()
    except OSError as e:
        return f'取不到快照（{type(e).__name__}）'
    with open(dest + '.tmp', 'wb') as f:
        f.write(data)
    index, why = check_snapshot(dest + '.tmp')
    if index is None:
        os.remove(dest + '.tmp'); return f'快照不自洽：{why}'
    os.replace(dest + '.tmp', dest)
    return None


if __name__ == '__main__':
    if len(sys.argv) not in (3, 4):
        print(__doc__, file=sys.stderr); sys.exit(2)
    build(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None)
    print(f'快照：{snapshot(sys.argv[2])}', file=sys.stderr)
