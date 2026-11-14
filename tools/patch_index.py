#!/usr/bin/env python3
"""社区补丁索引（11-12 维护者：出包时自动对接公开库；「库里的帧率、画幅都是经过验证的，玩家想用就给他打开」）。
我方这边跑：读各上游仓库的本地浅克隆，出一份只含元数据的索引（不含补丁字节）挂到下载站；玩家出包时 pack/jobs/patches.py 取索引，
按「仓库 + 提交号 + 路径」从 raw.githubusercontent 下载对得上这款的文件（不走 GitHub API：未登录每小时 60 次，玩家连出几款就撞上限）。

用法：patch_index.py <上游镜像目录> <输出 .json.gz>
  镜像目录里每个上游一个子目录 <owner>__<repo>：带 .git 的取 HEAD 提交号；删过 .git 的按镜像目录 SOURCES.tsv（来源 / 提交号两列）取。
每行：repo / commit / path / size / sha256 / kind（pchtxt | ips）/ cat（fps | widescreen | gfx）/ target_fps / aspect /
  gids（路径里出现的程序号）/ bids（pchtxt 的 @nsobid、ips 的文件名构建号）/ license（仓库 LICENSE 首行，没有写空）。
romfs 下的文件（游戏数据）、大于 2 MB 的文件不收。
压缩包（.zip / .rar，11-13：超宽屏 / 老牌补丁库把每款打成一个包）：包里的 exefs 补丁与 cheats/<构建号>.txt 金手指逐个成行，path 是包本身，
  另记 member（包内路径）、archive_sha256 / archive_size（整包，下载时先核它）；sha256 / size 是包内这一份。rar 用系统 bsdtar（libarchive）读。
金手指（kind=cheat，cat=cheat）：cheats/<构建号>.txt（散文件或包内）；出包时由 pack/jobs/cheats.py 收进金手指一栏，不进画面补丁。
  已由金手指专门通道取的库（CHEAT_LIBS，pack/jobs/cheats.py LIBRARIES）不在这里重复收。"""
import gzip
import hashlib
import json
import os
import re
import subprocess
import sys
import zipfile

MAX = 2 << 20
GID = re.compile(r'01[0-9A-Fa-f]{14}')


def classify(path, text=''):
    """类别按路径 / 文件头关键词（同本机补丁库覆盖表口径）：帧率 / 画幅 / 其余画面"""
    # 先去网址（11-13）：作者署名里的仓库网址（github.com/StevensND/ue4-emuswitch-60fps）落在前 400 字内，「60fps」把同一作者的关景深 / 关抗锯齿 / 分辨率补丁全判成帧率 60
    s = re.sub(r'https?://\S+', ' ', (path + '\n' + text[:400]).lower())
    fps = re.search(r'(\d{2,3})\s*fps', s)
    if re.search(r'ultra\s*wide|widescreen|21[:x_.]9|32[:x_.]9|aspect', s):
        m = re.search(r'(\d{1,2}(?:\.\d)?)\s*[:x_\-](9|10)\b', s)
        return 'widescreen', '', f'{m.group(1)}:{m.group(2)}' if m else ''
    if fps or 'fpslock' in s or 'speedfix' in s or re.search(r'(unlock|uncap|unlimit)\w*[\s_-]*fps|fps[\s_-]*(unlock|uncap|unlimit)', s):
        return 'fps', fps.group(1) if fps else '', ''
    return 'gfx', '', ''


def bids_of(path, data):
    name = os.path.splitext(os.path.basename(path))[0]
    if path.lower().endswith('.ips'):
        return [name.upper()] if re.fullmatch(r'[0-9A-Fa-f]{16,64}', name) else []
    return sorted({m.upper() for m in re.findall(r'@nsobid-([0-9A-Fa-f]{16,64})', data.decode('utf-8', 'replace'))})


CHEAT_LIBS = {'bad1dea/NXCheats', 'HamletDuFromage/switch-cheats-db', 'ChanseyIsTheBest/NX-60FPS-RES-GFX-Cheats'}
CHEAT = re.compile(r'(?:^|/)cheats/([0-9A-Fa-f]{16})\.txt$', re.I)


def members(full):
    """压缩包 → [(包内路径, 字节)]，只取补丁（.pchtxt / .ips，不在 romfs 下）与 cheats/<构建号>.txt；读不了 = []"""
    want = lambda n: not n.endswith('/') and '/romfs/' not in '/' + n.lower() and (n.lower().endswith(('.pchtxt', '.ips')) or CHEAT.search(n))
    out = []
    try:
        if full.lower().endswith('.zip'):
            with zipfile.ZipFile(full) as z:
                for i in z.infolist():
                    if want(i.filename) and i.file_size <= MAX:
                        out.append((i.filename, z.read(i)))
        else:
            names = subprocess.run(['bsdtar', '-tf', full], capture_output=True, text=True, timeout=60).stdout.splitlines()
            for n in names:
                if want(n):
                    data = subprocess.run(['bsdtar', '-xOf', full, n], capture_output=True, timeout=60).stdout
                    if len(data) <= MAX:
                        out.append((n, data))
    except (OSError, zipfile.BadZipFile, subprocess.SubprocessError) as e:
        print(f'跳过压缩包 {full}：{type(e).__name__}', file=sys.stderr)
    return out


def true_paths(repo, commit):
    """上游这次提交的真实文件树：git 内容号 → [路径]（大小写以上游为准）。镜像放在不分大小写的盘上时，上游只差大小写的两个目录会被合成一个
    （11-13 实测 ShinySick：同一款的全大写与首字母大写两个目录），按本地路径拼下载地址 404。经 gh（我方生成索引的机器已登录）取；取不到回 None、按本地路径"""
    try:
        out = subprocess.run(['gh', 'api', f'repos/{repo}/git/trees/{commit}?recursive=1', '--jq', '.tree[] | select(.type=="blob") | .sha + "\t" + .path'],
                             capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode:
        return None
    m = {}
    for line in out.stdout.splitlines():
        sha, _, path = line.partition('\t')
        m.setdefault(sha, []).append(path)
    return m


def fix_case(rel, data, tree):
    """本地路径 → 上游真实路径：同内容（git 内容号）且只差大小写的那条；对不上照本地"""
    if not tree:
        return rel
    sha = hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest()
    return next((p for p in tree.get(sha, []) if p.lower() == rel.lower()), rel)


def keep_dir(name):
    """上游镜像里不进的子目录：.git、游戏数据目录（补丁库里附带的资源替换，不是补丁）"""
    return name != '.git' and name.lower() != 'romfs'


HAMLET = re.compile(r'^cheats/(01[0-9A-Fa-f]{14})\.json$')   # 金手指汇总库：每款一份 JSON，键 = 构建号前 16 位，值 = {条目名: 整段代码}


def scan(mirror, keep_local=False, cheat_libs=False):
    """keep_local：每行另记 _local（镜像里的本地相对路径，tools/patch_pack.py 取字节用；不进索引）；汇总库 JSON 拆出的金手指另记 _data（内容是拼出来的，按路径取不回）。
    cheat_libs：金手指专门库（CHEAT_LIBS）的金手指也收（统一包用：11-13 起金手指也由我们的下载站分发，不再由出包端逐库去 GitHub 取）"""
    rows, pinned = [], {}
    src = os.path.join(mirror, 'SOURCES.tsv')
    if os.path.isfile(src):
        for line in open(src, encoding='utf-8'):
            c = line.rstrip('\n').split('\t')
            if len(c) >= 3 and re.fullmatch(r'[0-9a-f]{40}', c[2]):
                pinned[c[0]] = c[2]
    for d in sorted(os.listdir(mirror)):
        root = os.path.join(mirror, d)
        if '__' not in d or not os.path.isdir(root):
            continue
        repo = d.replace('__', '/', 1)
        commit = subprocess.run(['git', '-C', root, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip() \
            if os.path.isdir(os.path.join(root, '.git')) else pinned.get(d, '')
        if not re.fullmatch(r'[0-9a-f]{40}', commit):
            print(f'跳过 {d}：取不到提交号', file=sys.stderr); continue
        lic = ''
        for n in ('LICENSE', 'LICENSE.md', 'LICENSE.txt'):
            p = os.path.join(root, n)
            if os.path.isfile(p):
                lic = next((l.strip() for l in open(p, encoding='utf-8', errors='replace') if l.strip()), '')[:80]
                break
        def row(rel, name, data, extra=None):
            m = CHEAT.search(name)
            if m:
                if repo in CHEAT_LIBS and not cheat_libs:
                    return
                kind, cat, tfps, aspect, bids = 'cheat', 'cheat', '', '', [m.group(1).upper()]
            else:
                kind = 'ips' if name.lower().endswith('.ips') else 'pchtxt'
                cat, tfps, aspect = classify(rel + '/' + name if extra else rel, data.decode('utf-8', 'replace') if kind == 'pchtxt' else '')
                bids = bids_of(name, data)
            rows.append(dict(repo=repo, commit=commit, path=rel, size=len(data), sha256=hashlib.sha256(data).hexdigest(), kind=kind, cat=cat,
                             target_fps=tfps, aspect=aspect, gids=sorted({g.upper() for g in GID.findall(rel + '/' + name)}), bids=bids, license=lic, **(extra or {})))
            if keep_local:
                rows[-1]['_local'] = local
        tree = true_paths(repo, commit) if os.environ.get('S2A_PATCH_INDEX_NO_GH') != '1' else None
        if tree is None:
            print(f'{d}：取不到上游文件树，路径按本地（只差大小写的目录会 404）', file=sys.stderr)
        for dirpath, dirs, files in os.walk(root):
            dirs[:] = [x for x in dirs if keep_dir(x)]
            for f in files:
                full = os.path.join(dirpath, f); rel = os.path.relpath(full, root).replace(os.sep, '/'); local = rel
                if tree and os.path.getsize(full) <= MAX:
                    rel = fix_case(rel, open(full, 'rb').read(), tree)
                fpsl = f.lower().endswith('.yaml') and '/FPSLocker/patches/' in full.replace(os.sep, '/')
                hm = HAMLET.match(rel) if cheat_libs and repo == 'HamletDuFromage/switch-cheats-db' else None
                if hm:
                    try:
                        dj = json.load(open(full, encoding='utf-8'))
                    except (OSError, ValueError):
                        continue
                    author = '、'.join(sorted({str(v).splitlines()[0] for v in (dj.get('attribution') or {}).values() if str(v).strip()}))[:200]
                    for k, v in sorted(dj.items()):
                        if not (isinstance(v, dict) and re.fullmatch(r'[0-9A-Fa-f]{16}', k)):
                            continue
                        data = ''.join(x for x in v.values() if isinstance(x, str)).encode()
                        if not data.strip():
                            continue
                        rows.append(dict(repo=repo, commit=commit, path=rel, size=len(data), sha256=hashlib.sha256(data).hexdigest(), kind='cheat', cat='cheat',
                                         target_fps='', aspect='', gids=[hm.group(1).upper()], bids=[k.upper()], license=lic, author=author, member=k.upper()))
                        if keep_local:
                            rows[-1]['_data'] = data
                    continue
                if os.path.getsize(full) > MAX:
                    continue
                if f.lower().endswith(('.zip', '.rar')):
                    whole = open(full, 'rb').read()
                    for name, data in members(full):
                        row(rel, name, data, dict(member=name, archive_sha256=hashlib.sha256(whole).hexdigest(), archive_size=len(whole)))
                    continue
                if not f.lower().endswith(('.pchtxt', '.ips')) and not fpsl and not CHEAT.search(rel):
                    continue
                data = open(full, 'rb').read()
                if fpsl:
                    rows.append(dict(repo=repo, commit=commit, path=rel, size=len(data), sha256=hashlib.sha256(data).hexdigest(), kind='fpsl', cat='fps',
                                     target_fps='60', aspect='', gids=sorted({g.upper() for g in GID.findall(rel)}), bids=[os.path.splitext(f)[0].upper()], license=lic))
                    if keep_local:
                        rows[-1]['_local'] = local
                else:
                    row(rel, rel, data)
    return rows


# 转存合集 / 分叉（收别人的补丁再打包）：同一份内容（sha256 一样）在原作者库里也有时记原作者库，这几个排最后
AGGREGATORS = ('ADEMOLA200/', 'citron-neo/', 'pacoa-kdbg/', 'Copox/', 'Uncloak2/')


def dedupe(rows):
    """同一份内容只留一行：原作者库优先（合集排后），同级按库名；同一提交被镜像成两个名字（仓库改过名）只算一次"""
    rows = sorted(rows, key=lambda r: (r['repo'].startswith(AGGREGATORS), r['repo'], r['path'], r.get('member', '')))
    seen, out = set(), []
    for r in rows:
        k = (r['sha256'], r['kind'], tuple(r['gids']))   # 同内容不同款（通用补丁两款各放一份）各留一行
        if k not in seen:
            seen.add(k); out.append(r)
    return out


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr); return 2
    rows = dedupe(scan(argv[0]))
    with gzip.open(argv[1], 'wt', encoding='utf-8') as f:
        json.dump(dict(schema=1, rows=rows), f, ensure_ascii=False, separators=(',', ':'))
    print(f'补丁索引：{len(rows)} 份文件、{len({r["repo"] for r in rows})} 个上游 → {argv[1]}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
