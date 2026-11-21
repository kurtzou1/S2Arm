#!/usr/bin/env python3
# 整份直连出库（C# dsh_batch build，graphics/tools/direct/dsh/batch/Build.cs，11-01 出库链整条挪进 C#）的缓存复用与出库形态单测：python3 t_dmsh_reuse.py，约 1 分钟（首次要编 dsh_batch）
#   真跑：S2A.Dsh 翻译 + spirv-cross + xcrun metal。链号 / 程序号 / 配置档输入摘要 / 改翻译的配置档行由 dmsh_chain.py --build-env 给（与 direct_lib.py 同一口径）。
#   夹具现造、不含游戏数据：3 个计算着色器（EXIT + NOP… + BRA 自身），答案表线程组 16 / 32 / 64 各不同。线程组只进反射 json，三支 MSL 相同（计算核的线程组是派发时给的）。
#   期望按缓存规格写，不跑被测实现推：翻译缓存键 = 记录 + 本键的映射 / 答案行 + 工具指纹（含 --profile-rows）；Metal 缓存键 = 编译约定（分侧）+ 编译器身份 + MSL；
#   同 MSL 的键共用一份批库；收尾只留本次用到的条目。三支同 MSL → 每侧只编 1 份库；仓里条目 = 3 份翻译 + 每侧 1 份库 + 每侧 1 条批成员索引（Unity.ReuseIndex：三支同 MSL 只有一个代表键，每侧一条「ubu/<侧>/…」）。
#   ① 两份冷出（不发布：两侧按键导出）：Mac 每键 .metal / .metallib / .json、iOS 每键 .metallib / .json；命中 / 重编 (0, 3)；Metal 每侧 (复用 0, 新编 1)；
#      _b_build.json 3 键全 ok；两侧 inputs.tsv 印章 = 给的程序号与摘要 + 本树翻译器指纹 / 锁摘要；①′ --check-stamp 本树库过、篡改 / 旧印章红，--lock 不存在出库红；①″ 没 SDK 的玩家机按内置件 .xfp 记录核过 / 核红；仓 7 条留 0 条删；进度「直连库·翻译与收尾 / 编批库」从 0 到完成（7965ddea7 起翻译与逐键收尾同线程流水、合成一段）；
#      _se 每个键都试（0.6.0 出包着色器全覆盖，83a632e4e 起；se_want.tsv 只报覆盖）：se_want.tsv 列 K1 与一个不在本次出库里的键 → 试 3 个、请求 2 个其中出了 0 个，
#      三支都是计算核、没有要模拟的采样「nothing to emulate 3」、不出 _se
#   ② 原地再出、什么都没变：(3, 0)、Metal 每侧 (1, 0)、两侧每个按键文件逐字节不变、仓 7 条留 0 删、仓里条目修改时间不变（含批成员索引：整批拿来时不重记）（命中不改写条目，出包机缓存裁剪按目录时间算款的新旧）
#   ③ 改 K2 线程组 32 → 128、K3 移出着色器表：(1, 1)（只 K2 重翻）；K1 文件逐字节不变；K2 json 线程组 [128, 1, 1]；MSL 没变 → Metal 每侧 (1, 0)；
#      K3 两侧文件全删；仓留 4（K1 / 新 K2 翻译 + 两份库；另两条批成员索引照留）、删 2（旧 K2 翻译、K3 翻译）
#   ④ 改工具指纹（--profile-rows 多一行）：3 键全重翻 (0, 3)，MSL 没变 → Metal 每侧 (1, 0)（Metal 只按 MSL 内容复用）
#   ⑤ 只出 iOS（--no-mac）冷出：Mac 没有一个 .metallib、每键 .metal / .json 照写，iOS 每键齐；Metal 汇总只有 ios (0, 1)
#   ⑥ 两份出拿 ⑤ 只有 iOS 库的仓：翻译不分侧 → (3, 0)；Metal mac (0, 1)、ios (1, 0)；Mac 库齐
#   ⑦ 只出 iOS 拿两份齐的仓：(3, 0)、Metal 只有 ios (1, 0)、Mac 没有库
#   ⑧ 换模式：⑥ 两份齐的目录上原地只出 iOS → 旧 Mac 库（按键与批库）删光
#   ⑨ 出包形态（--publish ios + --export-mac）：iOS 目录只有 lib.idx + lib.NNN.pak + inputs.tsv、两侧输出目录没有按键文件；iOS 那份库字节（⑦ 导出的）原样在分片里；
#      iOS 输出根 keys.tsv = 三键、ps_inputs.tsv 在；--export-mac 目录有三键 Mac 三样（考卷 / 全量对拍用）
#   ⑨′ 客体输入（种类 56）：三键同块、块内每条 = 包记录切出的控制段 + 代码区
#   ⑩ 只出 Mac（--no-ios --publish mac）：退出 0；输出打出 lib.idx 与分片、没有按键文件；「只出 Mac：Mac 三样都齐」「发布 mac 库：反射全部 -sdk macosx」；Metal 汇总只有 mac
#   ⑪ 两张表（c1_full.tsv / cb_extent.tsv，C1Cb 接入中）：配置档目录里两张表都在、首行「# chain b-<链号> inputs <摘要>」（内容逐字节由别的对拍保证）
#   ⑫ 出包形态不导出（发布前放掉 Mac 侧源码、两张表后台遍每支一批）：容器 / keys / ps_inputs / 两张表与 ⑨ 逐字节相同
#   未覆盖：片元 / 顶点才有的附加入口回退、_bf / _bv / _se 真出变体（夹具造不出能编过的片元 / 顶点码），只在真实样本上看
import glob, json, os, re, shutil, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); R = os.path.abspath(os.path.join(HERE, '../../../..')); TOOLS = os.path.join(R, 'translator')
TID = '0100000000fa0000'; K1, K2, K3 = 'aaaa000000000001', 'aaaa000000000002', 'aaaa000000000003'; ALL = {K1, K2, K3}
fails = []
DSX = os.environ.get('DSX_LIB') or os.path.join(R, 'build/dsx/libdsx.dylib')   # 计算着色器共享内存改写（S2A.Dsh SpillFix）与进程内 SPIRV-Cross 要它
if not os.path.exists(DSX): print(f'✗ t_dmsh_reuse：缺 {DSX}（先 make -C graphics/dsx；DSX_LIB 可改）'); sys.exit(1)
sys.path.insert(0, TOOLS)
import dsh_batch, spvc_inproc
CMD, _ = dsh_batch.get(); SPVC = spvc_inproc.lib_path()
def check(cond, msg):
    print(('  ✓ ' if cond else '  ✗ ') + msg)
    if not cond: fails.append(msg)

def record(nops):   # 包记录：BTCDBTCD + 0x30 头（+0x28 控制段长、+0x2c 代码区长）+ 代码区（调度字 + 三条指令一组）+ 控制段魔数 34127698（+0x700 c1 起止 = 代码区长度，即没有 c1）
    SCHED, EXIT, BRA, NOP = 0x001F8000FFE007E0, 0xE30000000007000F, 0xE2400FFFFF87000F, 0x50B0000000070F00
    ins = [EXIT] + [NOP] * nops + [BRA]
    ins += [NOP] * (-len(ins) % 3)
    code = b''.join(struct.pack('<4Q', SCHED, *ins[i:i + 3]) for i in range(0, len(ins), 3))
    ctl = bytearray(bytes.fromhex('34127698') + bytes(0x800)); struct.pack_into('<2I', ctl, 4 + 0x700, len(code), len(code))
    hdr = bytearray(0x30); struct.pack_into('<2I', hdr, 0x28 - 8, len(ctl), len(code))
    return b'BTCDBTCD' + bytes(hdr) + code + bytes(ctl)

t = tempfile.mkdtemp(prefix='t_dmsh_reuse_'); P = os.path.join(t, 'prof', TID); os.makedirs(P); PKG = os.path.join(t, 'pkg'); os.makedirs(PKG)
open(os.path.join(PKG, 'cs_t.bin'), 'wb').write(record(0) + record(3) + record(6))
def tables(local):   # {键: 线程组 x}：着色器表只列这些键
    idx = {K1: 0, K2: 1, K3: 2}
    open(os.path.join(P, 'shader_map.tsv'), 'w').writelines(f'cs_t.bin\t{idx[k]}\tcompute\t{k}\tt#{idx[k]}\n' for k in sorted(local))
    open(os.path.join(P, 'shader_facts.tsv'), 'w').writelines(f'{k}\t{{"local":[{x},1,1],"shared":0}}\n' for k, x in sorted(local.items()))
for n, body in (('game.tsv', f'title_id\t{TID}\nprogram_id\t{TID}\nname\tt_dmsh_reuse\n'), ('shader_pairs.tsv', '# none\n'), ('bf_want.tsv', '# none\n'),
                ('se_want.tsv', f'# 采样模拟变体请求\n{K1}\nffff000000000009\n'),
                ('shader_map.tsv.conflicts.tsv', '# none\ndm_ctl_sha16\tchosen_pc\tclass\tcandidates\trecords\n')):
    open(os.path.join(P, n), 'w').write(body)

def build_env():   # → (链号, 程序号, 摘要, profile-rows 文件)：direct_lib.py 同一口径
    rows = os.path.join(t, 'rows.tsv')
    r = subprocess.run([sys.executable, os.path.join(TOOLS, 'dmsh_chain.py'), '--build-env', rows], capture_output=True, text=True,
                       env=dict(os.environ, DM_GAMES_DIR=os.path.join(t, 'prof'), DM_GAMES_FIRST='1', DM_GAME=TID))
    c = r.stdout.strip().split('\t')
    if r.returncode or len(c) != 3: print(r.stdout + r.stderr); print('✗ t_dmsh_reuse：dmsh_chain.py --build-env 没给出「链号\\t程序号\\t摘要」'); sys.exit(1)
    return c[0], c[1], c[2], rows

def build(name, cas, *flags, rows=None, progress=None, env_add=None):   # → (退出码, 输出, Mac 库目录, iOS 库目录, 链号, 摘要)
    chain, game, inp, rows0 = build_env()
    a = [*CMD, 'build', '--pkg', PKG, '--profile', P, '--game', game, '--chain', chain, '--inputs', inp, '--profile-rows', rows or rows0,
         '--out', os.path.join(t, name, 'mac'), '--iosout', os.path.join(t, name, 'ios'), '--cas', os.path.join(t, cas), '--dsx', DSX, '--spvc', SPVC,
         '-j', '2', '--lock', os.path.join(TOOLS, 'dmsh_chain.lock'), *flags]
    env = dict(os.environ); env.pop('S2A_PROGRESS', None)
    if progress: env['S2A_PROGRESS'] = progress
    env.update(env_add or {})
    r = subprocess.run(a, capture_output=True, text=True, env=env)
    if r.returncode: print(r.stdout[-1500:] + r.stderr[-1500:])
    return r.returncode, r.stdout + r.stderr, os.path.join(t, name, 'mac', 'b-' + chain), os.path.join(t, name, 'ios', 'b-' + chain), chain, inp

def hits(o): m = re.search(r'^shader cache: hit (\d+), rebuilt (\d+)$', o, re.M); return (int(m.group(1)), int(m.group(2))) if m else None
def metal(o, side): m = re.search(rf'^Metal cache: .*\b{side} (\d+) reused, (\d+) compiled', o, re.M); return (int(m.group(1)), int(m.group(2))) if m else None
# #1429 验收汇总行：(kept, 命中键, 计到的键, 没计到的键)；夹具三支计算核只有 EXIT / NOP / BRA，没有可写内存读 → kept 0，三键都计到（冷翻与命中缓存两条路）
def astmem(o): m = re.search(r'^ast mem order kept: (\d+) in (\d+) keys \(counted (\d+) keys, uncounted (\d+)\)$', o, re.M); return tuple(map(int, m.groups())) if m else None
def store(o): m = re.search(r'^store: (\d+) entries kept, (\d+) dropped$', o, re.M); return (int(m.group(1)), int(m.group(2))) if m else None
def ls(d): return os.listdir(d) if os.path.isdir(d) else []
def names(d, ext): return {n[:16] for n in ls(d) if n.endswith('_b.' + ext)}
def perkey(d): return [n for n in ls(d) if re.match(r'[0-9a-f]{16}_|u[0-9a-f]{16}\.metallib$', n)]
def snap(*ds): return {(d, n): open(os.path.join(d, n), 'rb').read() for d in ds for n in perkey(d)}
def maclibs(d): return [n for n in ls(d) if n.endswith('.metallib')]
def stamp(d): return dict(l.rstrip('\n').split('\t', 1) for l in open(os.path.join(d, 'inputs.tsv')) if not l.startswith('#')) if os.path.exists(os.path.join(d, 'inputs.tsv')) else {}
def entries(cas): return {p: os.stat(p).st_mtime_ns for p in glob.glob(os.path.join(t, cas, 'dshb', '*', '*.e'))}

# ① 两份冷出
tables({K1: 16, K2: 32, K3: 64})
progress = os.path.join(t, 'progress.tsv')
rc, o, mac, ios, chain, inp = build('a', 'cas_a', progress=progress)
bj = json.load(open(os.path.join(mac, '_b_build.json'))) if os.path.exists(os.path.join(mac, '_b_build.json')) else []
check(rc == 0 and all(names(mac, e) == ALL for e in ('metal', 'metallib', 'json')) and all(names(ios, e) == ALL for e in ('metallib', 'json')),
      f'① 两份冷出：退出 {rc}，Mac 三样 / iOS 两样各 3 键')
check(hits(o) == (0, 3) and metal(o, 'mac') == (0, 1) and metal(o, 'ios') == (0, 1) and store(o) == (7, 0) and astmem(o) == (0, 0, 3, 0),
      f'① 命中 / 重编 {hits(o)}（期望 (0, 3)），#1429 计数行 {astmem(o)}（期望 (0, 0, 3, 0)），Metal mac {metal(o, "mac")} / ios {metal(o, "ios")}（期望各 (0, 1)：三支同 MSL 共用一份），仓 {store(o)}（期望 (7, 0)：含每侧 1 条批成员索引）')
def zform(p):   # 11-08 仓条目整条压缩：文件 = b'DSZ1' + zlib(原 DSE1 整串)
    import zlib; d = open(p, 'rb').read()
    try: return d[:4] == b'DSZ1' and zlib.decompress(d[4:])[:4] == b'DSE1'
    except zlib.error: return False
ez = list(entries('cas_a'))
check(len(ez) == 7 and all(zform(p) for p in ez), f'① 仓条目 {len(ez)} 条（期望 7）全是 DSZ1 + zlib(DSE1)：{sum(zform(p) for p in ez)} 条')
import dmsh_chain   # 期望值由本树源码另算（xlate_fp 与 C# 编译期 Xfp 同清单同算法，tests/xfp_single_source_test.sh 守二者相等），不读被测程序
XFP, LOCKFP = dmsh_chain.xlate_fp(), dmsh_chain.lock_fp()
check(sorted((x['key'], x['st']) for x in bj) == [(k, 'ok') for k in sorted(ALL)] and stamp(mac) == stamp(ios) == {'game': TID, 'inputs': inp, 'xfp': XFP, 'lock': LOCKFP},
      f'① _b_build.json {[(x["key"][-1], x["st"]) for x in bj]}、两侧印章 {stamp(mac)}（期望程序号 {TID}、摘要 {inp}、翻译器指纹 {XFP}、锁摘要 {LOCKFP}）')
# ①′ 出库后核产物出自本树翻译器（direct_lib.py 调 dmsh_chain.py --check-stamp；11-06 时之笛第 49 版旧程序出库没被发现）：本树出的库通过；
#     印章翻译器指纹换一位 / 锁摘要换一位 / 没有这两行（旧程序出的库）→ 各报红；给了不存在的 --lock → 出库退出非 0、报 [RED] --lock
def chk_stamp(d): return subprocess.run([sys.executable, os.path.join(TOOLS, 'dmsh_chain.py'), '--check-stamp', d], capture_output=True, text=True)
r0 = chk_stamp(ios)
fake = os.path.join(t, 'fake_stamp'); os.makedirs(fake)
bad = []
for tag, body in (('翻译器指纹不同', f'game\t{TID}\ninputs\t{inp}\nxfp\t{"0" * 16}\nlock\t{LOCKFP}\n'), ('锁摘要不同', f'game\t{TID}\ninputs\t{inp}\nxfp\t{XFP}\nlock\t{"0" * 16}\n'),
                  ('旧程序没记', f'game\t{TID}\ninputs\t{inp}\n')):
    open(os.path.join(fake, 'inputs.tsv'), 'w').write(body); r = chk_stamp(fake)
    if r.returncode == 0 or '[RED]' not in r.stderr: bad.append(tag)
check(r0.returncode == 0 and not bad, f'①′ --check-stamp：本树出的库退出 {r0.returncode}（期望 0）{r0.stderr.strip()[-200:]}；该红没红的 {bad}（期望无）')
# ①″ 玩家机（App 只带 .NET 运行时、没有 SDK：dotnet msbuild 展不开 DshXfpInput，xlate_fp 现算不了）：内置 dsh_batch 在用（S2A_PREBUILT_TOOLS/dsh_batch/.src_digest
#     = 本树源码摘要）时取发版记下的 .xfp 当本树值——记录 = 本树指纹 → 过；记录换一位 → 红；源码摘要不同（内置件不在用）→ 退回现算，没 SDK → 红；不给 S2A_PREBUILT_TOOLS 没 SDK → 红
import dsh_batch
nosdk = os.path.join(t, 'nosdk_dotnet'); open(nosdk, 'w').write('#!/bin/sh\necho "No .NET SDKs were found." >&2\nexit 1\n'); os.chmod(nosdk, 0o755)
pre = os.path.join(t, 'prebuilt'); os.makedirs(os.path.join(pre, 'dsh_batch')); open(os.path.join(pre, 'dsh_batch', 'dsh_batch'), 'w').close()   # 发版件是 NativeAOT 单文件（dsh_batch.prebuilt 只认 dsh_batch / dsh_batch.exe）
DG = dsh_batch.src_digest(os.path.join(dsh_batch.DSH, 'batch', 'dsh_batch.csproj'))
def chk_player(digest, xfp, prebuilt=True):
    open(os.path.join(pre, 'dsh_batch', '.src_digest'), 'w').write(digest + '\n'); open(os.path.join(pre, 'dsh_batch', '.xfp'), 'w').write(xfp + '\n')
    env = {k: v for k, v in os.environ.items() if k not in ('S2A_PREBUILT_TOOLS', 'DOTNET')}; env['DOTNET'] = nosdk
    if prebuilt: env['S2A_PREBUILT_TOOLS'] = pre
    r = subprocess.run([sys.executable, os.path.join(TOOLS, 'dmsh_chain.py'), '--check-stamp', ios], capture_output=True, text=True, env=env)
    return 'green' if r.returncode == 0 else 'red' if '[RED]' in r.stderr else f'rc {r.returncode}'
pl = [chk_player(DG, XFP), chk_player(DG, '0' * 16), chk_player('0' * 64, XFP), chk_player(DG, XFP, prebuilt=False)]
check(pl == ['green', 'red', 'red', 'red'], f'①″ 没 SDK 的玩家机 --check-stamp（记录对 / 记录错 / 内置件摘要不同 / 无内置件）：{pl}（期望 green / red / red / red）')
rl = subprocess.run([*CMD, 'build', '--pkg', PKG, '--profile', P, '--game', TID, '--chain', chain, '--inputs', inp, '--out', os.path.join(t, 'nolock', 'mac'),
                     '--iosout', os.path.join(t, 'nolock', 'ios'), '--cas', os.path.join(t, 'cas_nolock'), '--dsx', DSX, '--spvc', SPVC, '-j', '2',
                     '--lock', os.path.join(t, 'no_such.lock')], capture_output=True, text=True)
check(rl.returncode != 0 and '[RED] --lock' in rl.stdout + rl.stderr, f'①′ --lock 指向不存在的文件：退出 {rl.returncode}（期望非 0）、报 [RED] --lock')
rows = [l.rstrip('\n').split('\t') for l in open(progress)] if os.path.exists(progress) else []
for stg, total in (('直连库·翻译与收尾', 3), ('直连库·编批库（MB）', None), ('直连库·采样模拟变体', 3)):   # 采样模拟变体在编批库满了之后逐键编：要有自己的计数，界面才不停在 100%
    v = [(int(x[2]), int(x[3])) for x in rows if len(x) == 4 and x[1] == stg]
    check(bool(v) and v[0][0] == 0 and v[-1][0] == v[-1][1] and all(a <= b for (a, _), (b, _) in zip(v, v[1:])) and (total is None or v[-1][1] == total),
          f'① 进度 {stg} 从 0 到完成：{v}')
check(re.search(r'every key tried 3\): built 0 \(0 of them in 0 batches, 0 built key by key after their batch failed; of se_want\.tsv\'s 2 keys 0\), nothing to emulate 3, failed 0', o) is not None and not [n for n in ls(mac) + ls(ios) if '_se.' in n],
      '① _se 每个键都试：试 3 个、se_want.tsv 请求 2 个出了 0 个，三支计算核都没有采样 → nothing to emulate 3、不出 _se')
before = snap(mac, ios); e0 = entries('cas_a')
# ② 原地再出
rc, o, _, _, _, _ = build('a', 'cas_a')
check(rc == 0 and hits(o) == (3, 0) and metal(o, 'mac') == (1, 0) and metal(o, 'ios') == (1, 0) and snap(mac, ios) == before and store(o) == (7, 0) and astmem(o) == (0, 0, 3, 0),
      f'② 原地再出没变：命中 / 重编 {hits(o)}（期望 (3, 0)），#1429 计数行 {astmem(o)}（期望 (0, 0, 3, 0)：命中缓存的键照样计到），Metal mac {metal(o, "mac")} / ios {metal(o, "ios")}（期望各 (1, 0)），{len(before)} 个按键文件逐字节不变，仓 {store(o)}（期望 (7, 0)：含每侧 1 条批成员索引）')
check(len(e0) == 7 and entries('cas_a') == e0, f'② 全命中不改写条目：仓 {len(e0)} 条（期望 7，含两条批成员索引）修改时间全不变')
# ③ 改 K2、去 K3
tables({K1: 16, K2: 128})
rc, o, _, _, _, inp3 = build('a', 'cas_a')
after = snap(mac, ios)
same1 = all(after.get(k) == v for k, v in before.items() if k[1].startswith(K1))
tg2 = json.load(open(os.path.join(mac, K2 + '_b.json'))).get('threadgroup_size') if os.path.exists(os.path.join(mac, K2 + '_b.json')) else None
gone3 = not any(n.startswith(K3) for n in ls(mac) + ls(ios))
check(rc == 0 and hits(o) == (1, 1) and same1 and tg2 == [128, 1, 1] and metal(o, 'mac') == (1, 0) and metal(o, 'ios') == (1, 0),
      f'③ 改 K2：命中 / 重编 {hits(o)}（期望 (1, 1)），K1 文件不变 {same1}，K2 线程组 {tg2}（期望 [128, 1, 1]），Metal mac {metal(o, "mac")} / ios {metal(o, "ios")}（期望各 (1, 0)）')
check(gone3 and names(mac, 'metallib') == {K1, K2} == names(ios, 'metallib') and store(o) == (8, 0) and stamp(mac).get('inputs') == inp3 != inp,
      f'③ K3 移出：两侧 K3 文件全删 {gone3}，仓 {store(o)}（期望 (8, 0)：含两条批成员索引；出库不删仓条目，旧 K2 / K3 翻译留着——11-02 起淘汰按容量预算 LRU 另做（tools/direct_cache_lru.py），'
      f'原先「本次没用到的全删」让交替出包的两边互删），印章摘要换成新的 {stamp(mac).get("inputs") == inp3 != inp}')
# ④ 工具指纹变了
tables({K1: 16, K2: 32, K3: 64})
rows4 = os.path.join(t, 'rows4.tsv'); shutil.copy(os.path.join(t, 'rows.tsv'), rows4); open(rows4, 'a').write('shader_t_dmsh_reuse\t1\n')
rc, o, _, _, _, _ = build('a', 'cas_a', rows=rows4)
check(rc == 0 and hits(o) == (0, 3) and metal(o, 'mac') == (1, 0) and metal(o, 'ios') == (1, 0),
      f'④ --profile-rows 多一行：命中 / 重编 {hits(o)}（期望 (0, 3)），Metal mac {metal(o, "mac")} / ios {metal(o, "ios")}（期望各 (1, 0)：MSL 没变）')
# ⑤–⑧ 只出 iOS / 两份互换
rc, o, mac5, ios5, _, _ = build('b', 'cas_b', '--no-mac')
check(rc == 0 and maclibs(mac5) == [] and names(mac5, 'metal') == ALL == names(mac5, 'json') and names(ios5, 'metallib') == ALL == names(ios5, 'json')
      and metal(o, 'ios') == (0, 1) and metal(o, 'mac') is None,
      f'⑤ 只出 iOS 冷出：退出 {rc}，Mac .metallib {len(maclibs(mac5))} 个（期望 0），Mac .metal / .json 与 iOS 两样各 3 键，Metal ios {metal(o, "ios")} / mac {metal(o, "mac")}（期望 (0, 1) / 无）')
rc, o, mac6, ios6, _, _ = build('c', 'cas_b')
check(rc == 0 and hits(o) == (3, 0) and metal(o, 'mac') == (0, 1) and metal(o, 'ios') == (1, 0) and names(mac6, 'metallib') == ALL,
      f'⑥ 两份出拿只有 iOS 库的仓：命中 / 重编 {hits(o)}（期望 (3, 0)），Metal mac {metal(o, "mac")}（期望 (0, 1)）/ ios {metal(o, "ios")}（期望 (1, 0)），Mac 库 {len(names(mac6, "metallib"))} 键')
rc, o, mac7, ios7, _, _ = build('d', 'cas_b', '--no-mac')
check(rc == 0 and hits(o) == (3, 0) and metal(o, 'ios') == (1, 0) and metal(o, 'mac') is None and maclibs(mac7) == [],
      f'⑦ 只出 iOS 拿两份齐的仓：命中 / 重编 {hits(o)}（期望 (3, 0)），Metal ios {metal(o, "ios")}（期望 (1, 0)），Mac .metallib {len(maclibs(mac7))} 个（期望 0）')
rc, o, _, _, _, _ = build('c', 'cas_b', '--no-mac')
check(rc == 0 and maclibs(mac6) == [], f'⑧ 两份齐的目录上原地只出 iOS：Mac .metallib 剩 {len(maclibs(mac6))} 个（期望 0）')
# ⑨ 出包形态：发布 iOS + 导出 Mac
iosbytes = {open(os.path.join(ios7, n), 'rb').read() for n in maclibs(ios7)}
exp = os.path.join(t, 'export-mac')
rc, o, macp, iosp, _, _ = build('p', 'cas_b', '--publish', 'ios', '--export-mac', exp)
packs = sorted(n for n in ls(iosp) if n.startswith('lib.'))
blob = b''.join(open(os.path.join(iosp, n), 'rb').read() for n in packs)
top = os.path.dirname(iosp)
keys = set(open(os.path.join(top, 'keys.tsv')).read().split()) if os.path.exists(os.path.join(top, 'keys.tsv')) else set()
check(rc == 0 and 'lib.idx' in packs and len(packs) >= 2 and not perkey(macp) + perkey(iosp) and len(iosbytes) == 1 and all(b in blob for b in iosbytes),
      f'⑨ 发布 iOS：退出 {rc}，容器 {packs}，按键文件 {len(perkey(macp) + perkey(iosp))} 个（期望 0），iOS 库 {len(iosbytes)} 份字节原样在分片里')
check(keys == ALL and os.path.exists(os.path.join(top, 'ps_inputs.tsv')) and all(names(exp, e) == ALL for e in ('metal', 'metallib', 'json')),
      f'⑨ keys.tsv 三键 {keys == ALL}、ps_inputs.tsv 在、--export-mac 目录 Mac 三样各 3 键')
# ⑨′ 客体输入（种类 56，Build.GuestBuild → LibPack.GuestBlocks）：三支计算着色器（阶段 2）同在一块、三条记录指向同一段；解出的块头 3 条 / 阶段 2 / 版本 1，
#   每条控制段 + 代码区 = 包记录按格式切出的那份（+0x28 控制段长、+0x2c 代码区长、代码从 +0x38 起、控制段随后；不调被测实现）；日志报「3 keys in 1 blocks」
import zlib
gi = {}
if 'lib.idx' in packs:
    ix = open(os.path.join(iosp, 'lib.idx'), 'rb').read(); n_, ns_ = struct.unpack_from('<II', ix, 12)
    for i in range(n_):
        k, kd, sh, _, ln, off = struct.unpack_from('<QBBHIQ', ix, 48 + 16 * ns_ + 24 * i)
        if kd == 56: gi[f'{k:016x}'] = (sh, off, ln)
ok_gi = set(gi) == ALL and len(set(gi.values())) == 1
if ok_gi:
    sh, off, ln = next(iter(gi.values())); sg = open(os.path.join(iosp, f'lib.{sh:03d}.pak'), 'rb').read()[off:off + ln]; raw = zlib.decompress(sg[8:])
    cnt, bst, ver = struct.unpack_from('<IBB', raw, 0); ents = {f'{e[0]:016x}': e[1:4] for e in (struct.unpack_from('<QIII', raw, 8 + 24 * i) for i in range(cnt))}
    recs = open(os.path.join(PKG, 'cs_t.bin'), 'rb').read().split(b'BTCDBTCD')[1:]
    def parts(r): r = b'BTCDBTCD' + r; nc, nd = struct.unpack_from('<II', r, 0x28); return r[0x38 + nd:0x38 + nd + nc], r[0x38:0x38 + nd]
    want = {K1: parts(recs[0]), K2: parts(recs[1]), K3: parts(recs[2])}
    ok_gi = struct.unpack_from('<I', sg, 0)[0] == len(raw) and (cnt, bst, ver) == (3, 2, 1) and set(ents) == ALL and all(
        raw[a:a + c] == want[k][0] and raw[a + c:a + c + d] == want[k][1] for k, (a, c, d) in ents.items())
check(ok_gi and 'guest inputs (kind 56' in o and '3 keys in 1 blocks' in o, f'⑨′ 客体输入：三键种类 56 同指一段、块头 3 条 / 阶段 2 / 版本 1、每条 = 包记录切出的控制段 + 代码区（记录 {len(gi)} 条）')
# ⑫ 出包形态不导出（v0.2.4 出包空间：两张表收尾挪到发布前、ps_inputs 写完即放掉 Mac 侧源码那份；两张表后台遍按字节切批，S2A_C1CB_CHUNK_MB=0 每支一批）：
#   产物与 ⑨（导出、源码留到最后、缺省切批）逐字节相同——容器分片 + lib.idx、keys.tsv、ps_inputs.tsv、两张表（首行带印章时间，比第二行起）；日志有「临时数据：」用量行
def body(d, n): b = open(os.path.join(d, n), 'rb').read(); return b.split(b'\n', 1)[1] if d == P else b
def outs(lib, top_): return {n: body(d, n) for d, ns in ((lib, [n for n in ls(lib) if n.startswith('lib.')]), (top_, ['keys.tsv', 'ps_inputs.tsv']), (P, ['c1_full.tsv', 'cb_extent.tsv'])) for n in ns if os.path.exists(os.path.join(d, n))}
ref = outs(iosp, top)
rc, o, _, iosq, _, _ = build('q', 'cas_b', '--publish', 'ios', env_add={'S2A_C1CB_CHUNK_MB': '0'})
got = outs(iosq, os.path.dirname(iosq))
check(rc == 0 and len(ref) >= 6 and got == ref and '临时数据：' in o,
      f'⑫ 发布 iOS 不导出、两张表每支一批：退出 {rc}，产物 {sorted(got)} 与 ⑨ 逐字节相同 {got == ref}（不同：{sorted(n for n in set(got) | set(ref) if got.get(n) != ref.get(n))}），用量行 {"临时数据：" in o}')
# ⑩ 只出 Mac
rc, o, macm, iosm, _, _ = build('m', 'cas_m', '--no-ios', '--publish', 'mac')
mlibs = sorted(n for n in ls(iosm) if n.startswith('lib.'))
check(rc == 0 and 'lib.idx' in mlibs and not perkey(iosm) and '只出 Mac：Mac 三样都齐' in o and '[直连库] 发布 mac 库：反射全部 -sdk macosx' in o
      and metal(o, 'mac') == (0, 1) and metal(o, 'ios') is None,
      f'⑩ 只出 Mac：退出 {rc}，输出 {mlibs}，按键文件 {len(perkey(iosm))}，Metal mac {metal(o, "mac")} / ios {metal(o, "ios")}（期望 (0, 1) / 无），发布 mac / macosx')
# ⑪ 两张表
for tb in ('c1_full.tsv', 'cb_extent.tsv'):
    p = os.path.join(P, tb); head = open(p).readline().rstrip('\n') if os.path.exists(p) else None
    check(head is not None and head.startswith(f'# chain b-{chain} inputs '), f'⑪ {tb} 在、首行 {head!r}（期望以「# chain b-{chain} inputs 」开头）')

# ⑬ 编 Metal 的几段（编批库 / _se / _vp）按此刻空闲内存重算编译路数（Build.cs LiveLanes）：-j 2，空闲 6000 MB / 本单 8 核 → 1 + (3000 − 1065) ÷ 420 = 5 路；
#    空闲 1000 MB 算出来不到 -j → 照旧 2 路（只放宽、不收窄）；本单 3 核 → 封顶 3 路
for avail, jobs, want in (('6000', '8', 5), ('1000', '8', 2), ('6000', '3', 3)):
    lp = os.path.join(t, f'lanes{avail}_{jobs}.progress.tsv')
    rc, o, _, _, _, _ = build(f'lanes{avail}_{jobs}', 'cas_lanes', progress=lp, env_add={'S2A_MEM_AVAIL_MB': avail, 'S2A_JOBS': jobs})
    acts = [json.loads(l.split('\t', 1)[1]) for l in open(lp, encoding='utf-8') if l.startswith('#dsh_activity\t')] if os.path.exists(lp) else []
    se = [(x['target'], x['pool']) for x in acts if x['stage'] == '直连库·采样模拟变体' and x['state'] == 'active']
    check(se == [(want, want * 2)], f'⑬ 空闲 {avail} MB、本单 {jobs} 核：采样模拟变体的活动记录报放宽后的路数 目标 / 任务池 {se}（期望 [({want}, {want * 2})]）')
    m = re.search(r'采样模拟变体：(\d+) 路编', o)
    check(rc == 0 and m is not None and int(m.group(1)) == want, f'⑬ 空闲 {avail} MB、本单 {jobs} 核：采样模拟变体 {m.group(1) if m else "没打"} 路（期望 {want}），退出 {rc}')
    u = re.search(r'编批库：(\d+) 路编', o)   # 只有第一次冷编有批要编；后两次批全拿缓存，这段不读内存、不打行
    check((u is not None and int(u.group(1)) == want) if (avail, jobs) == ('6000', '8') else u is None,
          f'⑬ 空闲 {avail} MB、本单 {jobs} 核：编批库 {u.group(1) + " 路" if u else "没打（批全拿缓存）"}（期望 {str(want) + " 路" if (avail, jobs) == ("6000", "8") else "没打"}）')

shutil.rmtree(t, ignore_errors=True)
print(f't_dmsh_reuse：{"全符" if not fails else f"{len(fails)} 例不符"}')
sys.exit(1 if fails else 0)
