#!/usr/bin/env python3
# 直连库全部计算着色器的计算管线归档（出包时离线编，随包放 shaders/direct/pipelines/）：
#   python3 cs_pipelines.py <shaders/direct 目录> <输出 pipelines 目录> --plat ios|macos --os <系统大版本> --arch <GPU 架构> [--arch …] [--cache <目录>] [-j <路数>]
# 为什么：设备上首次派发一个计算着色器、随包没有它的管线时，提交线程现编计算管线（nvn_mtl.m 派发处 par_compute_wait，最多等 DM_NVN_CPSO_WAIT_MS），
#   诊断里一停 5–60 秒。设备侧先查随包归档（pso_archive.h par_bundle_for：<shader_map.tsv 同级>/pipelines/<键>.metalarchive，MTLPipelineOptionFailOnBinaryArchiveMiss），
#   这里把库里每个计算着色器的管线按设备侧同一描述离线编进那个文件，首遇直接命中、不现编。
# 与 11-02 撤掉的「设备上预热全部计算着色器」（pso_seed.py 头注释：怪猎 6663 条、首帧等 64 秒）不是一回事：这里在出包机上用 metal-tt 编，
#   不进 pso_manifest.tsv 的预热行，设备上没有任何预编；没用到的计算着色器只占包里的字节，用到时是一次打开文件（单管线文件约 0.1 ms）。
# 描述 = 设备侧 par_compute_：MTLComputePipelineDescriptor 只设 computeFunction（其余缺省）；函数 = 库段（种类 0，批库多键共用一段）里的 fn_prefix + entry（nvn_mtl.m fnn），
#   与设备 lib_from_pack 读的是同一段字节（归档按描述 + 函数在库里的哈希命中，与库文件里别的函数无关，pso_gen.py 头注释 10-21 实测）。
# 只拿这一个函数的模块出归档：metal-tt 会把交给它的整个库原样装进归档（本机实测：同一个核，单独成库 7.6 KB，放进 40 个核的库 153 KB；动森一支 374 KB → 66 KB），
#   批库一段被上百个键共用时，按整段出每支都背一份整段。metallib 里每个函数各有一个位码模块，函数表 HASH = sha256(模块)；把模块原样取出、metallib 重新包成单函数库，
#   HASH 不变，设备用整段里的同名函数照样命中（本机实测：单函数库出的归档，设备拿 40 函数的库命中）。取不出 / 包出来哈希对不上的，退回按整段出（照样命中，只是大），读数里记「整段」支数。
# 文件名 = 设备侧 par_ckey(cs, 0)：「c」+ sha256(<16 位键>_b) 的前 20 字节十六进制。采样模拟变体（par_ckey fc≠0，库种类 51 _se）不出：设备照旧首遇现编。
# 目标 GPU：--arch 给几个，一个文件里就带几个架构的切片（metal-tt 多 -arch 出胖文件，设备按自己的架构取）。系统版本：--os 大版本，最低版本写 <大版本>.0
#   （本机 macOS 27.2 实测：27.0 / 27.2 都命中，26.0 不命中——同一大版本内通用、跨大版本不通用；同一架构不同大版本放不进一个文件）。
# metal-tt 与 graphics/tools/shbake/pso_chunk.sh 的 Metal 3 分支同一套：Metal 3 脚本格式（alias:<库>#<函数>）、子进程带 DIRHELPER_USER_DIR_SUFFIX（tools/tt_env.sh tt_suffix）、
#   「No available translator」只对这一句退避重试至多 5 次、单支 600 秒超时（超时连同 air-tt 子孙整组杀掉）。S2A_METAL_TT：单测换假工具。
# 缓存（--cache）：键 = 本工具格式号 + 库段 sha256 + 函数名 + 平台 + 大版本 + 架构表 + metal-tt 版本；命中按 APFS 克隆拷出。条目 <缓存>/<两位>/<64 位>.e（放在直连缓存的
#   store/cpso/ 下时由直连缓存回收认得、按最近使用淘汰）。命中刷新修改时间。
# 输出：标准输出最后一行一句读数；有支编不出 → 照出其余、退出 3（调用方打黄）；参数 / 库读不了 → 退出 1。
import argparse
import hashlib
import json
import os
import random
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from repair_compute import Library   # 直连库容器（lib.idx + lib.NNN.pak）的读法，与运行时 lib_pack.inc 同一格式
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from pool_workers import cores   # 核数 / 进程池路数唯一来源（tools/pool_workers.py，#1332）
from progress import Ticker   # 出包进度（S2A_PROGRESS）：这段原先没有计数，界面停在「刷新各阶段 n/11 · 剩 0 秒」

FORMAT = 'cs-pipelines 1'   # 改了产物形状（描述、文件名、脚本格式）就加一，旧缓存全部不中
REPO = Path(__file__).resolve().parents[3]
TT_TIMEOUT = 600   # 单次 metal-tt 上限（秒）


def ckey(key):
    """设备侧 par_ckey(cs, 0)：cs->key 是「<16 位键>_b」，sha256 取前 20 字节十六进制，前缀 c"""
    return 'c' + hashlib.sha256((key + '_b').encode()).hexdigest()[:40]


def container(direct):
    """shaders/direct 下的 Metal 库容器 b-<链>（不是安卓的 b-<链>-vk）：只认一份"""
    cs = [p for p in sorted(direct.glob('b-*')) if p.is_dir() and not p.name.endswith('-vk') and (p / 'lib.idx').is_file()]
    if len(cs) != 1:
        raise SystemExit(f'【红】{direct} 下 Metal 库容器应有 1 份，实有 {len(cs)} 份：{[p.name for p in cs]}')
    return Library(cs[0])


def compute_keys(direct, lib):
    """shader_map.tsv 第 3 列为 compute 的键，且库里有它的反射（种类 1）与库段（种类 0）；去重升序"""
    want = set()
    for line in (direct / 'shader_map.tsv').read_text(encoding='utf-8').splitlines():
        c = line.split('\t')
        if len(c) >= 4 and c[2] == 'compute' and len(c[3]) == 16:
            want.add(c[3])
    have = [k for k in sorted(want) if (int(k, 16), 0) in lib.records and (int(k, 16), 1) in lib.records]
    return have, len(want) - len(have)


def lib_functions(b):
    """metallib 函数表 → {函数名: (HASH 十六进制, 位码模块起点, 长度)}；不是 metallib / 越界 → ValueError。
    头：MTLB、版本与平台字段，偏移 24 起 4 对（u64 偏移、u64 长度）：函数表、公开元数据、私有元数据、位码；函数表 = u32 个数 + 每个函数 u32 长度 + 标签串
    （4 字节标签 + u16 长度 + 值，ENDT 结束）：NAME 名字、HASH 32 字节、OFFT 三个 u64（第三个 = 位码区内偏移）、MDSZ 模块长度"""
    if len(b) < 88 or b[:4] != b'MTLB':
        raise ValueError('不是 metallib')
    flo, _, _, _, _, _, bco, bcs = struct.unpack_from('<8Q', b, 24)
    n = struct.unpack_from('<I', b, flo)[0]; p = flo + 4; out = {}
    for _ in range(n):
        end = p + struct.unpack_from('<I', b, p)[0]; q = p + 4; f = {}
        while q + 4 <= end:
            tag = b[q:q + 4]; q += 4
            if tag == b'ENDT': break
            ln = struct.unpack_from('<H', b, q)[0]; f[tag] = b[q + 2:q + 2 + ln]; q += 2 + ln
        if b'NAME' in f and b'OFFT' in f and b'MDSZ' in f:
            o = struct.unpack_from('<3Q', f[b'OFFT'])[2]; sz = struct.unpack_from('<Q', f[b'MDSZ'])[0]
            if o + sz > bcs or bco + o + sz > len(b):
                raise ValueError('函数位码越界')
            out[f[b'NAME'].rstrip(b'\0').decode('utf-8', 'replace')] = (f.get(b'HASH', b'').hex(), bco + o, sz)
        p = end
    return out


def tt_command(plat):
    sdk = 'iphoneos' if plat == 'ios' else 'macosx'
    if os.environ.get('S2A_METAL_TT'):
        return [os.environ['S2A_METAL_TT']], os.environ['S2A_METAL_TT'], 'fake'
    path = subprocess.run(['xcrun', '-sdk', sdk, '-f', 'metal-tt'], capture_output=True, text=True).stdout.strip()
    if not path:
        raise SystemExit(f'【红】xcrun -sdk {sdk} 找不到 metal-tt（要完整的 Xcode）')
    ver = subprocess.run([path, '-version'], capture_output=True, text=True).stdout.strip().splitlines()
    return [path], path, ver[0] if ver else '?'


def tt_suffix(path):
    p = subprocess.run(['bash', '-c', '. "$1" && tt_suffix "$2"', '_', str(REPO / 'tools/tt_env.sh'), path], capture_output=True, text=True)
    if p.returncode or not p.stdout.strip():
        raise SystemExit(p.stderr.strip() or '【红】tt_env：取不到 metal-tt 查询缓存后缀')
    return p.stdout.strip()


# 子进程一律不走 fork（11-20 本机实测：18 路线程池里每对起 3 个子进程——metallib 包库、metal-tt、cp 克隆——fork 要复制整个大进程且持全局锁，
#   同一时刻只能起一个，平均每次 300 ms；一款大作冷编 1200 对 100 秒里 metal-tt 只占线程时间的 36%，同时在跑的 metal-tt 中位 5 个）。
#   posix_spawn 不复制父进程（单独起 12 ms 量级，不互相排队）：工具按绝对路径直接起（不经 xcrun 再转一手），克隆用 clonefile 进程内做。
_TOOLS, _TMU = {}, threading.Lock()


def sdk_tool(sdk, name):
    """xcrun -sdk <sdk> -f <name> 的绝对路径（每个工具只问一次）；找不到退回 ['xcrun', '-sdk', sdk, name]"""
    with _TMU:
        if (sdk, name) not in _TOOLS:
            p = subprocess.run(['xcrun', '-sdk', sdk, '-f', name], capture_output=True, text=True).stdout.strip()
            _TOOLS[(sdk, name)] = [p] if p else ['xcrun', '-sdk', sdk, name]
        return _TOOLS[(sdk, name)]


def run_tool(argv):
    """跑一个短工具、收输出：argv[0] 是绝对路径时 subprocess 走 posix_spawn（close_fds=False：本进程的描述符缺省都不继承，PEP 446）"""
    return subprocess.run(argv, capture_output=True, close_fds=False)


def run_tt(argv, env, log):
    """跑一次 metal-tt（新会话 = 新进程组，posix_spawn 起、输出直接写 log）；600 秒超时整组杀。→ (退出码, 输出)"""
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        pid = os.posix_spawnp(argv[0], argv, env, setsid=True, file_actions=[(os.POSIX_SPAWN_DUP2, fd, 1), (os.POSIX_SPAWN_DUP2, fd, 2)])
    finally:
        os.close(fd)
    late = []

    def kill():
        # 进程组信号唯一入口 tools/safe_killpg.sh（tests/killpg_lint_test.sh 守）；字样 = 本次 metal-tt 的脚本路径（组长命令行里必有，组号被复用时对不上、不杀）
        late.append(1)
        subprocess.run(['bash', '-c', 'source "$1"; safe_killpg KILL "$2" "$3"', '_', str(ROOT / 'tools/safe_killpg.sh'), str(pid), str(argv[-3])],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    tm = threading.Timer(TT_TIMEOUT, kill); tm.daemon = True; tm.start()
    try:
        st = os.waitpid(pid, 0)[1]
    finally:
        tm.cancel()
    rc = os.waitstatus_to_exitcode(st)
    text = log.read_bytes().decode('utf-8', 'replace')
    if late:
        text += f'\ncs_pipelines: metal-tt ran past {TT_TIMEOUT} s, process group killed'; rc = 124
        log.write_text(text)
    return rc, text


_LIBC = []


def _clonefile(src, dst):
    if not _LIBC:
        import ctypes
        try:
            f = ctypes.CDLL(None, use_errno=True).clonefile; f.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]; f.restype = ctypes.c_int
        except (AttributeError, OSError):
            f = None
        _LIBC.append(f)
    return bool(_LIBC[0]) and _LIBC[0](os.fsencode(src), os.fsencode(dst), 0) == 0


def clone(src, dst):
    # 临时件名带进程号 + 线程号：base_pipelines / 本工具用线程池并发出管线，两路碰上同一缓存键时同写一个目标；只带进程号时同进程两条线程共用一个临时件，
    #   先改名的一条把它挪走，后一条 os.replace 报 FileNotFoundError，整阶段软失败、包里一份管线都没有（Ori 2 出包实例）。各写各的临时件，改名原子，后到的覆盖先到的、内容相同
    tmp = dst.with_name(dst.name + f'.{os.getpid()}.{threading.get_ident()}.tmp')
    if not _clonefile(src, tmp):   # APFS 克隆（进程内 clonefile，不起 cp 子进程）；别的文件系统 / 没有这个调用退回普通拷贝
        shutil.copyfile(src, tmp)
    os.replace(tmp, dst)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('direct', type=Path); ap.add_argument('out', type=Path)
    ap.add_argument('--plat', choices=('ios', 'macos'), required=True); ap.add_argument('--os', type=int, required=True)
    ap.add_argument('--arch', action='append', required=True); ap.add_argument('--cache', type=Path)
    ap.add_argument('-j', type=int, default=cores())
    a = ap.parse_args()
    archs = sorted(set(a.arch))
    lib = container(a.direct)
    keys, nolib = compute_keys(a.direct, lib)
    argv0, ttpath, ttver = tt_command(a.plat)
    env = dict(os.environ, DIRHELPER_USER_DIR_SUFFIX=tt_suffix(ttpath)) if ttver != 'fake' else dict(os.environ)
    a.out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='cs_pipelines.', dir=a.out.parent))
    try:
        # 每支：函数名、它在段里的位码模块（能取出且 sha256 = 函数表 HASH 才算），取不出的整段按内容去重写一次
        jobs, segs, fntab = [], {}, {}
        for k in keys:
            data = lib.read(int(k, 16), 0)
            sh = hashlib.sha256(data).hexdigest()
            j = json.loads(lib.read(int(k, 16), 1)); fn = (j.get('fn_prefix') or '') + j['entry']
            if sh not in fntab:
                try: fntab[sh] = lib_functions(data)
                except (ValueError, struct.error): fntab[sh] = {}
            h, o, sz = fntab[sh].get(fn, ('', 0, 0))
            mod = data[o:o + sz] if sz else b''
            if mod and hashlib.sha256(mod).hexdigest() == h:
                jobs.append((k, 'm' + h, fn, mod))
            else:
                if sh not in segs: segs[sh] = work / f'{sh}.metallib'; segs[sh].write_bytes(data)
                jobs.append((k, 's' + sh, fn, None))
        sdk = 'iphoneos' if a.plat == 'ios' else 'macosx'
        tv = ['-arch'] * (2 * len(archs)); tv[1::2] = archs
        flag = f'-{a.plat}-version-min'
        stat, mu = {'hit': 0, 'built': 0, 'whole': 0, 'fail': []}, threading.Lock()

        def note(k, v):
            with mu:
                if k == 'fail': stat[k].append(v)
                else: stat[k] += 1

        def single(fn, h, mod):
            """单函数库：模块原样存成 .air、metallib 包一下，核包出来的函数表里同名函数 HASH 不变；不成返回 None"""
            air, ml = work / f'{h}.air', work / f'{h}.metallib'
            if ml.is_file(): return ml
            tmp = work / f'{h}.{threading.get_ident()}.metallib'
            air.write_bytes(mod)
            p = run_tool(sdk_tool(sdk, 'metallib') + [str(air), '-o', str(tmp)])
            try:
                if p.returncode or lib_functions(tmp.read_bytes()).get(fn, ('',))[0] != h: return None
            except (OSError, ValueError, struct.error):
                return None
            os.replace(tmp, ml); return ml

        def one(job):
            k, ident, fn, mod = job
            dst = a.out / f'{ckey(k)}.metalarchive'
            ck = hashlib.sha256('\n'.join([FORMAT, ident, fn, a.plat, str(a.os), ' '.join(archs), ttver]).encode()).hexdigest()
            cf = a.cache / ck[:2] / f'{ck}.e' if a.cache else None
            if cf and cf.is_file() and cf.stat().st_size:
                clone(cf, dst); os.utime(cf); note('hit', 1); return
            libf = single(fn, ident[1:], mod) if mod else None
            if not libf:   # 取不出单函数模块：按整段出（照样命中，归档背整段）
                sh = hashlib.sha256(lib.read(int(k, 16), 0)).hexdigest()
                with mu:
                    if sh not in segs: segs[sh] = work / f'{sh}.metallib'; segs[sh].write_bytes(lib.read(int(k, 16), 0))
                libf = segs[sh]; note('whole', 1)
                ck = hashlib.sha256('\n'.join([FORMAT, 's' + sh, fn, a.plat, str(a.os), ' '.join(archs), ttver]).encode()).hexdigest()
                cf = a.cache / ck[:2] / f'{ck}.e' if a.cache else None
            script = work / f'{k}.mtlp-json'
            script.write_text(json.dumps({'generator': 'MetalFramework', 'version': [0, 1, 0],
                                          'libraries': {'paths': [{'label': 'L', 'path': str(libf)}]},
                                          'pipelines': {'render_pipelines': [], 'compute_pipelines': [{'compute_function': f'alias:L#{fn}'}]}}))
            tmp = work / f'{k}.bin'
            for n in range(6):
                rc, text = run_tt(argv0 + tv + [flag, f'{a.os}.0', str(script), '-o', str(tmp)], env, work / f'{k}.log')
                if rc == 0 or n == 5 or 'No available translator' not in text: break
                time.sleep(0.2 * (n + 1) + random.random() * 0.2)
            if rc or not tmp.is_file() or not tmp.stat().st_size:
                note('fail', (k, rc, text.strip().splitlines()[-1][:160] if text.strip() else '无输出')); return
            if cf:
                cf.parent.mkdir(parents=True, exist_ok=True); clone(tmp, cf)
            os.replace(tmp, dst); note('built', 1)

        tk = Ticker('直连库·计算管线', len(jobs))
        with ThreadPoolExecutor(max(1, a.j)) as ex:
            for f in as_completed([ex.submit(one, job) for job in jobs]): f.result(); tk.step()   # 按完成先后计：一支编得久，计数不停在它前面
    finally:
        shutil.rmtree(work, ignore_errors=True)
    files = [a.out / f'{ckey(k)}.metalarchive' for k in keys]
    size = sum(p.stat().st_size for p in files if p.is_file())
    ok = len(keys) - len(stat['fail'])
    for k, rc, why in stat['fail'][:8]:
        print(f'【黄】计算管线 {k} 没编成（metal-tt 退出 {rc}）：{why}', file=sys.stderr)
    print(f'计算管线归档：计算着色器 {len(keys)} 支（表里有、库里缺 {nolib} 支不算），出 {ok} 支（缓存命中 {stat["hit"]}、现编 {stat["built"]}，其中按整段库出 {stat["whole"]}）、'
          f'失败 {len(stat["fail"])} 支；{a.plat} {a.os}.0 × {len(archs)} 个架构（{" ".join(archs)}）；共 {size} 字节，每支 {size // ok if ok else 0} 字节')
    return 3 if stat['fail'] else 0


if __name__ == '__main__':
    sys.exit(main())
