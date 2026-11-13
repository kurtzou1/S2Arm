#!/usr/bin/env python3
"""阶段真实输入清单（10-30 出包线根修）：缓存键按「这次实际读过的文件」算，不靠手工列名单。
  起因：改写阶段键手工列了 fps_generic / ue_cvar_loc，新生成器 fps_warehouse、profile_guess（出 gpu_drivers.tsv）等没进键，
  已缓存的根热出包直接跳过改写，新逻辑只在冷出包生效（按内容缓存最怕的「漏算真实输入、用错旧产物」）。
  做法同编译器的依赖文件：采集端 tools/stage_deps_hook/sitecustomize.py 记下阶段里每个 Python 进程读过的文件 / 列过的目录，
  阶段结束 collect 成清单存进产物根；下次判跳过时 rehash 按清单重算当前内容并进键——清单里任一文件变了键就变。
  新依赖只能经由已记录的文件（或阶段脚本本身，它直接进键）的改动引入，所以不会漏。

用法：
  stage_deps.py collect <原始记录目录> <仓库根> [<排除前缀>…]   → stdout：种类<TAB>路径<TAB>哈希，已排序去重
  stage_deps.py rehash  <清单> <仓库根>                            → 按清单里的路径重算当前哈希，同格式输出（没变 = 逐字相同）
清单格式：f = 文件内容 sha256 前 16 位，d = 目录项名单（排序；仓库内只算 git 跟踪 / 未忽略的子项，编译中间目录不算）sha256 前 16 位，读不到记「缺」（之后出现也算变）。
  仓库内路径写 R:<相对路径>（换检出目录键不变），仓库外写绝对路径。
记什么：仓库里 git 跟踪 / 未忽略的文件与目录（构建产物、缓存被 .gitignore 挡掉，不然缓存一长键就变）；仓库外只认 S2A_DEPS_EXTERNAL（os.pathsep 分隔：Mac / Linux 冒号、Windows 分号）下的
  （缺省由 pack/stage_keyfiles.sh 给社区补丁目录）；不记：给定前缀（产物根等）、S2A_DEPS_KEYED 里阶段已更细进键的文件、本阶段自己写过的、字节码、
  解释器自身（标准库 / site-packages / 钩子，采集端按各进程自己的解释器排）。
已知边界：只看 Python 进程；os.path.exists 这类只查存在不读的判断看不到（读到的索引表变了照样会变）。"""
import hashlib
import os
import subprocess
import sys

def _digest(kind, p, keep=None):
    """keep：目录项只算这些名字（仓库内目录 = git 跟踪 / 未忽略的子项；None = 全算）。
    11-05 根修：编译中间目录（bin / obj，被 .gitignore 挡）原先算进目录名单，编过的树和新检出的树键不同 → 直连库被迫重编。"""
    try:
        if kind == 'd':
            names = os.listdir(p) if keep is None else [n for n in os.listdir(p) if n in keep]
            return hashlib.sha256('\n'.join(sorted(names)).encode('utf-8', 'surrogateescape')).hexdigest()[:16]
        with open(p, 'rb') as f: return hashlib.sha256(f.read()).hexdigest()[:16]
    except OSError:
        return '缺'


# 产物等价表（pack/stage_inputs/equiv.tsv；登记命令 tools/stage_equiv.py add）。读表写在本文件里、不 import 旁边的模块：
#   本工具会被单独拷进各种隔离引擎目录（阶段单测、门禁机的假引擎都只拷 stage_deps.py），多一个同目录依赖就整条算键失败、缓存永不命中（11-11 列车红）
EQUIV_TABLE = os.path.join('pack', 'stage_inputs', 'equiv.tsv')


def equiv_load(repo):
    """→ {(路径, 新 sha16): (旧对象号, 旧 sha16)}；没有表 → {}"""
    out = {}
    try:
        for ln in open(os.path.join(repo, EQUIV_TABLE), encoding='utf-8'):
            if ln.startswith('#') or not ln.strip(): continue
            c = ln.rstrip('\n').split('\t')
            if len(c) >= 4: out[(c[0], c[1])] = (c[2], c[3])
    except FileNotFoundError:
        pass
    return out


_equiv = {}
def equiv_canon(repo, rel, h):
    """登记过等价的「路径 + 新内容」→ 旧版本的 sha16，否则原样"""
    t = _equiv.get(repo)
    if t is None: t = _equiv[repo] = equiv_load(repo)
    return t.get((rel, h), (None, h))[1]


# 算键 / 记清单的基础设施本身（阶段表里归「外」：只读输入算键、不改产物）：照记进实际读入清单（编排层 pack/orch/stages.py 要求清单里有这几行，
#   缺了就判清单无效、永不跳过——11-11 第一版把它们从清单里去掉，列车上各阶段缓存测试全红）；重算时这几行原样沿用记录值，
#   改了它们（如加产物等价）不让老游戏重跑（11-11 实测：同根换代码再出，抽取曾因清单里 stage_keyfiles.sh / stage_deps.py 对不上被判重跑）
INFRA = {'R:pack/stage_keyfiles.sh', 'R:tools/stage_deps.py', 'R:tools/stage_equiv.py', 'R:pack/stage_inputs/equiv.tsv'}


def _eq(repo, k, n, h):
    """仓库内文件登记过产物等价：记成旧版本的内容哈希（只提速、不改产物的改动不让老游戏重跑，11-11）"""
    return equiv_canon(repo, n[2:], h) if k == 'f' and n.startswith('R:') else h


def _real(repo, name):
    return (repo if name == 'R:.' else os.path.join(repo, name[2:])) if name.startswith('R:') else name


def _git(args, **kw):
    """账本 git 调用不吃工具链 env：坏 / 假 DEVELOPER_DIR 会让 /usr/bin/git 垫片 xcrun 报红。"""
    env = os.environ.copy(); env.pop('DEVELOPER_DIR', None)
    return subprocess.run(['git', *args], env=env, **kw)


def _listed(repo):
    """仓库里算输入的文件：git 跟踪的 + 未跟踪但没被忽略的（构建产物 / 缓存被 .gitignore 挡掉）；不是 git 仓库 → None（全收）"""
    try:
        out = _git(['-C', repo, 'ls-files', '-co', '--exclude-standard', '-z'], capture_output=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None, None
    files = {f for f in out.decode('utf-8', 'surrogateescape').split('\0') if f}
    dirs = {''}
    for f in files:
        d = os.path.dirname(f)
        while d not in dirs: dirs.add(d); d = os.path.dirname(d)
    return files, dirs


def _children(files, dirs):
    """仓库内每个目录（相对路径，根为 ''）下算输入的子项名：git 跟踪 / 未忽略的文件与含这类文件的子目录"""
    kids = {}
    for x in files | (dirs - {''}):
        kids.setdefault(os.path.dirname(x), set()).add(os.path.basename(x))
    return kids


def _keep(kids, name):
    """清单名字 → 目录项过滤集合（仓库外 / 不是 git 仓库 = None 全算）"""
    if kids is None or not name.startswith('R:'): return None
    return kids.get('' if name == 'R:.' else name[2:], set())


def _ignored(repo, rel):
    return _git(['-C', repo, 'check-ignore', '-q', '--', rel], capture_output=True).returncode == 0


def collect(raw, repo, excl):
    repo = os.path.realpath(repo)
    # 路径列表按 os.pathsep 拆（Windows 是 ;，D:\ 自带冒号）；前缀比较按 os.sep，仓库内名字一律记成 / 分隔（git ls-files 与各平台清单同一写法）
    skip = [os.path.realpath(e).rstrip(os.sep) + os.sep for e in excl if e]   # 给定前缀（产物根、新版本根）：一律不记
    ext = [os.path.realpath(e).rstrip(os.sep) + os.sep for e in os.environ.get('S2A_DEPS_EXTERNAL', '').split(os.pathsep) if e]   # 仓库外只认这些数据根
    keyed = {k.strip('/') for k in os.environ.get('S2A_DEPS_KEYED', '').split(os.pathsep) if k}   # 阶段已更细地进键的仓库文件
    files, dirs = _listed(repo)
    rows, wrote = set(), set()
    for fn in sorted(os.listdir(raw)):
        # 只读本机制写的记录（钩子的 <pid>-<纳秒>.tsv、stage_deps_save / orch 的 scripts.tsv）：记录目录在游戏库卷上，
        #   exFAT / FAT 上 macOS 把扩展属性存成旁边的 ._<名>（AppleDouble 二进制，含 NUL），还有 .DS_Store（#812 exFAT 出包报 embedded null character）
        if fn.startswith('.') or not fn.endswith('.tsv'): continue
        with open(os.path.join(raw, fn), encoding='utf-8', errors='surrogateescape') as f:
            for ln in f:
                k, _, p = ln.rstrip('\n').partition('\t')
                if not p: continue
                rp = os.path.realpath(p)
                if k == 'w': wrote.add(rp); continue
                rows.add((k, rp))
    out = set()
    for k, rp in rows:
        if rp in wrote or (os.sep + '__pycache__' + os.sep) in rp or rp.endswith('.pyc'): continue   # 字节码（含 PYTHONPYCACHEPREFIX 写到别处的）：源文件另由 sys.modules 记
        if any((rp + os.sep).startswith(s) for s in skip): continue
        if k == 'f' and os.path.isdir(rp): continue
        if rp == repo or rp.startswith(repo + os.sep):
            rel = os.path.relpath(rp, repo).replace(os.sep, '/') if rp != repo else ''
            if rel in keyed: continue
            if files is not None and not (rel in files if k == 'f' else rel in dirs):
                if os.path.exists(rp) or _ignored(repo, rel): continue   # 读不到的文件（之后出现也算变）：位置没被忽略就记
            out.add((k, 'R:' + (rel or '.')))
        elif any((rp + os.sep).startswith(e) for e in ext):
            out.add((k, rp))
    kids = _children(files, dirs) if files is not None else None
    return [(k, n, _eq(repo, k, n, _digest(k, _real(repo, n), _keep(kids, n)))) for k, n in sorted(out)]   # 算键基础设施照记（pack/orch/stages.py 要求清单里有这几行才认）


def rehash(manifest, repo):
    repo = os.path.realpath(repo); res = []; kids = False
    with open(manifest, encoding='utf-8', errors='surrogateescape') as f:
        for ln in f:
            c = ln.rstrip('\n').split('\t')
            if len(c) != 3: continue
            if c[1] in INFRA: res.append((c[0], c[1], c[2])); continue   # 老清单里记了基础设施：原样沿用，不让它改键
            if c[0] == 'd' and kids is False:   # 有目录项才列一次仓库（git ls-files）
                files, dirs = _listed(repo); kids = _children(files, dirs) if files is not None else None
            res.append((c[0], c[1], _eq(repo, c[0], c[1], _digest(c[0], _real(repo, c[1]), _keep(kids, c[1]) if c[0] == 'd' else None))))
    return res


def main(a):
    if len(a) >= 3 and a[0] == 'collect': rows = collect(a[1], a[2], a[3:])
    elif len(a) == 3 and a[0] == 'rehash': rows = rehash(a[1], a[2])
    else: print(__doc__.strip(), file=sys.stderr); return 2
    sys.stdout.write(''.join(f'{k}\t{n}\t{h}\n' for k, n, h in rows)); return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
