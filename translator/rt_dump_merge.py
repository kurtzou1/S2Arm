#!/usr/bin/env python3
# 运行时转储的着色器并进直连抽取（Switch2 线 11-05）：rt_dump_merge.py <转储目录> <包目录 pkg> <shader_map.tsv> <shader_facts.tsv>
#
# 为什么要：有的着色器游戏文件里抽不到（时之笛 Switch 2 版开局 11 支计算着色器：解压后的 romfs、三个程序模块、抽取产物 4.1 万支里都搜不到原码），
#   真机只能在首遇时现翻译 + 现编 Metal：单支 MSL 0.17–1.7 MB，编库约 9 秒、建管线约 10 秒，提交线程同步等、GPU 空闲，开局停帧 30 秒以上。
#   宿主 DM_NVN_SHDUMP 把这类着色器的控制段与代码区按真机键存成 <键>.ctl / <键>.code（graphics/nvn/host/dsh_miss.inc）；放进解包目录 rt_shaders/ 后，
#   直连出库（graphics/tools/direct/direct_lib.sh 合并两边抽取之后）调本工具，按 shader_split.py 的同一记录格式追加进 <阶段>_rt.bin、同一键算法核键、补着色器表与答案表，
#   出库（Build.cs 按 shader_map.tsv 的键列取记录）就把它们编进直连库，真机按原键命中、不再现编。
#
# 规矩：文件名的键必须等于按 shader_split.skey 重算的键（不等 = 转储坏了或键算法变了，报红退 1，不进库）；控制段 / 代码区要过 shader_split.check；
#   表里已有的键不重复追加（抽取已覆盖时只计数）；计算着色器答案表取控制段线程组 / 共享内存（同 shader_split：Switch 2 走 ns2_shaders.compute_facts）。
#   着色器代码属游戏内容：转储只在本机用、不分发（同 graphics/tools/shbake/shcollect.sh 头注）。
# 输出一行：转储 <n> 支，新进库 <a> 支（各阶段），已在表里 <s> 支
import collections, hashlib, json, os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ns2_shaders as ns2
# 不 import shader_split：它导入时就要选游戏配置档（DM_GAME），零配置款没有仓库档。下面三样与 shader_split.py 的 ctl_len / skey / check 同一公式；
#   文件名的键必须等于重算的键，公式一旦与 shader_split 漂移会当场报红，不会静默进错库
CTL_MAGIC, GFX_MAGIC, CS_MAGIC = bytes.fromhex('34127698'), bytes.fromhex('78563412'), bytes.fromhex('79563412')
STAGE_NAME = {'vs': 'vertex', 'hs': 'hull', 'ds': 'domain', 'gs': 'geometry', 'ps': 'pixel', 'cs': 'compute', 'ts': 'task', 'ms': 'mesh'}   # = shader_split.py STAGE_NAME


def ctl_len(ctl):
    if ns2.is_nvn2(ctl): return ns2.KEY_CTL
    n = struct.unpack_from('<I', ctl, 0x20)[0]
    return n if 0x760 <= n < 0x880 else 0x880


def skey(ctl, code):
    return hashlib.sha256((ns2.key_ctl(ctl) if ns2.is_nvn2(ctl) else ctl[:ctl_len(ctl)]) + code).hexdigest()[:16]


def check(where, st, ctl, code):
    if ns2.is_nvn2(ctl): return ns2.check(st, ctl, code)
    if ctl[:4] != CTL_MAGIC or len(ctl) < ctl_len(ctl): return 'bad control section'
    if st != 'cs' or code[:4] != CS_MAGIC: return 'only compute shaders are taken from a Switch 1 dump'
    if struct.unpack_from('<I', ctl, 0x704)[0] != len(code): return 'control +0x704 does not match the code area length'
    return None


def stage_of(ctl, code):
    if ns2.is_nvn2(ctl): return ns2.stage(ctl)
    return 'cs' if code[:4] == CS_MAGIC else None   # Switch 1 图形阶段要看代码头里的阶段字段：本工具只收计算着色器与 Switch 2 各阶段，其余报红不进库


def main():
    if len(sys.argv) != 5: sys.exit('用法：rt_dump_merge.py <转储目录> <包目录 pkg> <shader_map.tsv> <shader_facts.tsv>')
    dump, pkg, mapf, factf = sys.argv[1:]
    have = set()
    for ln in open(mapf, encoding='utf-8'):
        c = ln.rstrip('\n').split('\t')
        if len(c) > 4 and not ln.startswith('#'): have.add(c[3])
    keys = sorted(f[:-5] for f in os.listdir(dump) if f.endswith('.code') and os.path.isfile(os.path.join(dump, f[:-5] + '.ctl')))
    recs, rows, facts, stat, skipped = collections.defaultdict(list), [], [], collections.Counter(), 0
    bad = []   # 单支转储坏了：跳过这一支、记一笔，其余照并（v0.3.1 拿不准不停 ⑭；原先任一支坏整个合并退出）
    def skip(k, why): bad.append(f'{k}：{why}'); print(f'[WARN] 转储 {k}：{why}，跳过这一支', flush=True)
    for k in keys:
        code = open(os.path.join(dump, k + '.code'), 'rb').read(); ctl = open(os.path.join(dump, k + '.ctl'), 'rb').read()
        kk = skey(ctl, code)
        if kk != k: skip(k, f'按 shader_split 键算法重算是 {kk}，与文件名不符（转储坏了或键算法变了）'); continue
        st = stage_of(ctl, code)
        if st not in STAGE_NAME: skip(k, '认不出阶段（Switch 1 图形阶段本工具不收）'); continue
        why = check(k, st, ctl, code)
        if why: skip(k, why); continue
        if k in have: skipped += 1; continue
        name = f'{st}_rt.bin'
        rec = bytearray(b'BTCDBTCD' + bytes(0x30)); struct.pack_into('<2I', rec, 0x28, len(ctl), len(code)); rec += code + ctl
        if rec.count(b'BTCDBTCD') != 1: skip(k, '记录分隔符出现在记录里，出库会切错'); continue
        if not ns2.is_nvn2(ctl) and rec.find(CTL_MAGIC) != 0x38 + len(code): skip(k, '控制段魔数出现在代码区'); continue
        if os.path.exists(os.path.join(pkg, name)) and not recs[name]: sys.exit(f'【红】包目录里已有 {name}（重复并入？先用抽取阶段重出的包目录）')
        rows.append((name, len(recs[name]), STAGE_NAME[st], k, f'rt-dump:{k}')); recs[name].append(bytes(rec)); stat[st] += 1
        if st == 'cs':
            (x, y, z), sh = ns2.compute_facts(ctl) if ns2.is_nvn2(ctl) else (struct.unpack_from('<3I', ctl, 0x748), struct.unpack_from('<I', ctl, 0x754)[0])
            if not x * y * z: skip(k, '控制段线程组为 0'); rows.pop(); recs[name].pop(); stat[st] -= 1; continue
            facts.append(f'{k}\t' + json.dumps({'local': [x, y, z], 'shared': (sh + 15) // 16 * 16}, separators=(',', ':')) + '\n')
    for name, rr in recs.items():
        with open(os.path.join(pkg, name), 'wb') as f: f.write(b''.join(rr))
    with open(mapf, 'a', encoding='utf-8') as f: f.writelines('\t'.join(map(str, r)) + '\n' for r in rows)
    with open(factf, 'a', encoding='utf-8') as f: f.writelines(facts)
    print(f'运行时转储：{len(keys)} 支，新进库 {len(rows)} 支（{" ".join(f"{s} {n}" for s, n in sorted(stat.items()) if n) or "—"}），已在表里 {skipped} 支'
          + (f'，坏了跳过 {len(bad)} 支（逐条见上方 [WARN]）' if bad else ''))


if __name__ == '__main__':
    main()
