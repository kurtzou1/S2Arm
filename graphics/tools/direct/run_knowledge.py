#!/usr/bin/env python3
"""跑局知识快照（审计 #1534 P1-54 B1）：run_knowledge.py <输出目录> <程序号 | 产物根> [来源…]
出包要用的「跑局学到的东西」只从这里取：把真跑来源整理成四张归一化表，直连库阶段（pack/stage_direct.sh）按其中三张进键、
管线种子阶段（pack/stage_direct_seed.sh）按 seen.tsv 进键；出库只读快照，不再边出库边读活文件（出库途中又有一局追加也不影响这一次）。
  来源：给了就用参数（pso_user.tsv 文件，或放 .tsv 的目录）；没给 = S2A_PSO_SOURCES（系统分隔符：Windows「;」、别处「:」，盘符路径里的冒号不拆），再没有 = <运行根>/s2arm/pso_seed/<程序号>/；
    没给参数时再在后面接 S2A_PSO_SOURCES_EXTRA（系统分隔符；出包时 pack/jobs/patches.py 交来的补丁包管线种子）
    （测试设备局 tools/dev_run.sh、卸前 tools/dev_uninstall.sh、Mac 局 runtime/run_mac.sh 收局都拷进这一个目录；出包不读 ~/Documents/wire，
    所以同一提交、同一份 pso_seed/ 在 Mac 和Windows 出包机算出同一个键）。不存在的来源跳过。
  第二个参数给产物根目录时按 pack/srcs.sh prog_id 同一规则取程序号（unpack.tsv 的 title_id，没有就读 exefs/main.npdm）。
  pairs.tsv     P 行「P<TAB>顶点键<TAB>片元键」，去重、排序 → direct_lib.py 交 run_pairs.py 并进配对表（vs_pad 补顶点输出）        进直连库阶段键
  fout_want.tsv 片元输出类型变体请求，fout_want.py 同一推导、同一格式（R 行 + rt_fout.tsv 行）→ 直接作配置档副本的 fout_want.tsv   进直连库阶段键
  se_want.tsv   采样模拟变体要的键，se_want.py wants 同一推导，去重、排序，不按并集滤（出库时 se_want.py --keys 再按并集滤）     进直连库阶段键
  seen.tsv      S / R / C 行：只核格式（同 pso_seed.py：S 三列、C 两列、R 长度 = 2 × pso_skey 字节数的小写十六进制），不按库键滤；
                按来源先后、各自行序去重（= 首用序，种子表要这个序）→ pso_seed.py 唯一来源                                         进种子阶段键
  vk_spv/       Vulkan 款设备首遇现编时存下的游戏 SPIR-V（各来源目录下的 vk_spv/<键>.spv；来源是文件时取它所在目录下的 vk_spv/）：
                按魔数认 SPIR-V、按内容重算键（sha256 前 16 位 = hle_vk / vk_shaders.py 的键）去重，文件名不对的照内容改名；
                direct_lib.py 的 Vulkan 分支把它和 RomFS 一起交 vk_shaders.py 离线翻（11-05：出包不起局抓着色器，运行时生成 SPIR-V 的款靠真跑学到）      进直连库阶段键
键只看这四张表的内容：重复行、同内容的重复文件、修改时间、来源路径与来源机器都不影响；格式坏的行丢掉。最后一行是汇总。
"""
import contextlib
import hashlib
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fout_want  # noqa: E402
import pso_layout  # noqa: E402
from run_pairs import KEY, sources  # noqa: E402
from se_want import wants as se_wants  # noqa: E402

HEX = set('0123456789abcdef')


def program_id(a):   # = pack/srcs.sh prog_id
    if not os.path.isdir(a): return a.upper()
    try:
        with open(os.path.join(a, 'unpack.tsv'), encoding='utf-8') as f:
            for l in f:
                c = l.rstrip('\n').split('\t')
                if c[0] == 'title_id' and len(c) > 1 and c[1]: return c[1].upper()
    except OSError: pass
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'tools'))
    import addr_need
    return addr_need.npdm_program(os.path.join(a, 'exefs', 'main.npdm')).upper()


def default_sources(tid):
    # 补丁包带的管线种子（pack/jobs/patches.py 落到私有缓存后交 S2A_PSO_SOURCES_EXTRA，按系统分隔符）排在本机来源之后：本机真跑的首用序在前
    extra = [p for p in os.environ.get('S2A_PSO_SOURCES_EXTRA', '').split(os.pathsep) if p]
    env = os.environ.get('S2A_PSO_SOURCES')
    if env: return [p for p in env.split(os.pathsep) if p] + extra
    run = os.environ.get('S2A_RUN_ROOT') or os.path.join(os.path.expanduser('~'), '.s2arm', 'run')
    return [os.path.join(run, 's2arm', 'pso_seed', tid)] + extra


def write(path, text):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8', newline='\n') as f: f.write(text)
    os.replace(tmp, path)


def vk_spv(srcs, out):   # 各来源的 vk_spv/*.spv → out/<键>.spv（按内容重算键、去重；不是 SPIR-V 的跳过）→ 支数
    import shutil
    shutil.rmtree(out, ignore_errors=True); n = 0
    dirs = []
    for p in srcs:
        d = os.path.join(p if os.path.isdir(p) else os.path.dirname(p), 'vk_spv')
        if os.path.isdir(d) and d not in dirs: dirs.append(d)
    for d in dirs:
        for f in sorted(os.listdir(d)):
            b = open(os.path.join(d, f), 'rb').read()
            if len(b) < 20 or len(b) % 4 or b[:4] != b'\x03\x02\x23\x07': continue
            dst = os.path.join(out, hashlib.sha256(b).hexdigest()[:16] + '.spv')
            if os.path.exists(dst): continue
            os.makedirs(out, exist_ok=True); open(dst, 'wb').write(b); n += 1
    return n


def main(out, tid, srcs):
    tid = program_id(tid); srcs = srcs or default_sources(tid)
    files = list(sources(srcs)); skey = pso_layout.load()['skey_size']
    os.makedirs(out, exist_ok=True)
    pairs, se, seen, rows = set(), set(), set(), []
    for f in files:
        with open(f, encoding='utf-8', errors='replace') as fh: lines = fh.read().split('\n')
        se |= se_wants(lines)
        for l in lines:
            c = l.split('\t')
            if not l or l.startswith('#'): continue
            if c[0] == 'P':   # = run_pairs.py 的格式规则
                if len(c) >= 3 and KEY.fullmatch(c[1]) and KEY.fullmatch(c[2]): pairs.add((c[1], c[2]))
                continue
            if c[0] == 'S': good = len(c) >= 3   # = pso_seed.py 的格式规则（库键过滤留给 pso_seed.py）
            elif c[0] == 'C': good = len(c) >= 2
            elif c[0] == 'R': good = len(c) >= 2 and len(c[1]) == 2 * skey and set(c[1]) <= HEX
            else: good = False
            if good and l not in seen: seen.add(l); rows.append(l)
    write(os.path.join(out, 'pairs.tsv'), '# 跑局配对：P<TAB>顶点键<TAB>片元键（graphics/tools/direct/run_knowledge.py，去重排序）\n'
          + ''.join(f'P\t{v}\t{p}\n' for v, p in sorted(pairs)))
    with contextlib.redirect_stdout(io.StringIO()) as o:   # fout_want.py 原样出表（推导、排序、表头都是它的），汇总行收进本工具的汇总
        rc = fout_want.main([os.path.join(out, 'fout_want.tsv')] + srcs)
    if rc: print(f'【红】输出类型变体请求表出不来（fout_want.py 退 {rc}）', file=sys.stderr); return 1
    nf = sum(1 for l in open(os.path.join(out, 'fout_want.tsv'), encoding='utf-8') if not l.startswith('#'))
    write(os.path.join(out, 'se_want.tsv'), '# 采样模拟变体：跑局见过 fc & 2 的键（graphics/tools/direct/run_knowledge.py，去重排序，未按并集滤）\n'
          + ''.join(k + '\n' for k in sorted(se)))
    write(os.path.join(out, 'seen.tsv'), '# 跑局见过的管线：S / R / C 行，首用序去重（graphics/tools/direct/run_knowledge.py）\n'
          + ''.join(r + '\n' for r in rows))
    nv = vk_spv(srcs, os.path.join(out, 'vk_spv'))
    print(f'跑局知识快照：来源 {len(files)} 份；配对 {len(pairs)}、输出类型变体 {nf}、采样模拟 {len(se)}、管线种子行 {len(rows)}、Vulkan 现编 SPIR-V {nv}'
          f'（{o.getvalue().strip().removeprefix("[直连库] ")}）')
    return 0


if __name__ == '__main__':
    if len(sys.argv) < 3: sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3:]))
