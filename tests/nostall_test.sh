#!/bin/bash
# 无进展看门狗单测（tools/nostall.py，约 15 秒）：bash tests/nostall_test.sh
# 期望（按规则手写）：① 子进程不吃 CPU 地卡住 → 无进展窗口后停掉整棵树、退 124、打【红】、子进程不留；② 子进程一直在算、总时长超过窗口 → 跑完退 0；
#   ③ 命令自己的退出码原样透传；④ 被信号杀 → 128 + 信号号
#   以下是 10-31 mhrise / botw 误杀的根修（编译在树外的 MTLCompilerService 里算，树内 CPU 不涨）。窗口 2 秒：
#   ⑤ 树外往 --watch 目录里不停新建文件 → 不杀、跑完退 0；⑥ 树外往命令的日志（标准输出重定向的文件）追加 → 不杀、退 0；
#   ⑦ 树里有个叫 metal 的子进程活着（编译子进程）→ 不杀、退 0；
#   ⑧ 反证：盯着目录和日志、但都没人写，树里只有 sleep（不是编译器）→ 照样停、退 124
#   ⑧b 卡住的 sh → sleep 两层：停之前给树里两个进程都抓了调用栈，写进被盯目录 nostall_stacks.<进程号>.log、红行写明路径；sleep 那段停在 nanosleep（11-02 无主之地3 抽取卡死只剩一行红）
#   ⑩ 11-04 巫师3 c1104_w3astc 现场（抽取工作进程整 600 秒停在 mmap 缺页读、CPU 不涨、没写输出，被误杀）：树内 CPU 不涨、没人写、无编译器，
#     只有磁盘读字节在涨 → 不杀、退 0；⑩反：读写字节停在一个非零值不动（不是「有过读」就算）→ 照样停，发停时刻 = 最后一次涨（0.5）+ 2 = 2.5
#     ⑩ 读数来源（真进程）：子进程用 F_NOCACHE（绕过页缓存，次次真读盘）读回 8 MB，读数之间磁盘读写字节涨 ≥ 8 MB
#   ⑪ #1560：编译子进程一直活着、CPU 一直涨，但产出（被盯路径 / 日志 / S2A_PROGRESS 出包进度）连续 窗口 × 6 秒不动 → 照样停（在动不等于在前进）
#   ⑨ 10-31 符文工房5 现场：盯外层目录，写入落在其下一层平铺 2 万个文件的 b-x/ 里 → 不杀、退 0；算一次目录指纹 stat < 100 次（只看目录自身与前 64 项，不随文件数涨；旧版逐个 stat 2 万个文件）
# 怎么测（11-02 合入线：main 无缓存全套 361 步并发、gate-host 负载 20+ 时 ②⑤⑧ 反复红——② 忙循环 2 秒窗口里没拿到 CPU 被判挂死、⑤ 喂文件进程 2 秒没被调度、
#   ⑧ 停树 + 抓栈用了 11–17 秒超「< 10 秒」）：判挂死本来就按墙钟窗口，真进程 + 2 秒窗口 = 赌调度。拆成两半：
#   · 判定逻辑（②⑤⑥⑦⑧⑨ 的「杀 / 不杀、何时杀」）：假时钟驱动 nostall.main()——Popen 换成假进程，每次 wait(timeout=轮询) 把假时钟推一格并做这一格的「活」
#     （写被盯目录 / 追加日志 / 涨 CPU / 什么都不做）；被盯路径的指纹用真文件系统，只有时钟与进程是假的。结果与机器负载无关
#   · 真进程只核与时间无关的部分：①③④⑧⑧b 杀树 / 透传 / 抓栈（只核结果，不核用了几秒）；ps 读进程树 CPU 随计算涨、认出 metal 子进程、读磁盘字节随读盘涨，按事件同步（子进程报做完才读）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); bad=0; export S2A_NOSTALL_POLL=0.5
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
M=nostall_t_$$; o=$(python3 "$H/tools/nostall.py" 2 -- sh -c "exec -a $M sleep 30" 2>&1); r1=$?; sleep 1
ck "① 卡住 → rc=${r1}、打【红】、子进程不留" '[ $r1 = 124 ] && grep -q "【红】无进展看门狗" <<< "$o" && [ -z "$(pgrep -f "^$M")" ]'
python3 "$H/tools/nostall.py" 2 -- sh -c 'exit 7'; r3=$?; ck "③ 退出码透传 rc=${r3}" '[ $r3 = 7 ]'
python3 "$H/tools/nostall.py" 2 -- sh -c 'kill -TERM $$'; r4=$?; ck "④ 被 TERM 杀 rc=${r4}（143）" '[ $r4 = 143 ]'
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir "$T/out"; : > "$T/log"
# ⑧ 真进程：命令睡 120 秒，看门狗不停它就睡满退 0 → 红；不核停了几秒（停树 + 抓栈的耗时随负载变，与要证的「没人写就判挂死」无关）
o=$(python3 "$H/tools/nostall.py" --watch "$T/out" 2 -- sh -c "sleep 120" 2>&1 >> "$T/log"); r8=$?
ck "⑧ 反证（真进程）：盯着目录和日志但没人写、无编译器 → rc=${r8}（124）、打【红】" '[ $r8 = 124 ] && grep -q "【红】无进展看门狗" <<< "$o"'
# ⑫ 0400A3A01EE4C000：调用方没设 S2A_PROGRESS，子进程照出包进度协议往 $S2A_PROGRESS 每秒写一行、别的什么都不动（不吃 CPU、不写被盯目录 / 日志、无编译器），
#   总时长 14 秒 > 窗口 2 × 6 → 看门狗自己建的进度文件在涨 = 在前进 → 不杀、退 0；反证（旧实现：变量没设、写不出去）2 秒就停、退 124
o=$(env -u S2A_PROGRESS python3 "$H/tools/nostall.py" --watch "$T/out" 2 -- sh -c 'i=0; while [ $i -lt 14 ]; do echo "$(date +%s)	x	$i	14" >> "$S2A_PROGRESS"; sleep 1; i=$((i+1)); done' 2>&1 >> "$T/log"); r12=$?
ck "⑫ 没设 S2A_PROGRESS、子进程只写出包进度 14 秒 → rc=${r12}（0）" '[ $r12 = 0 ]'
rm -f "$T/out"/nostall_stacks.*.log; mkdir "$T/st"
o=$(python3 "$H/tools/nostall.py" --watch "$T/st" 2 -- sh -c "sleep 30; true" 2>&1); r8b=$?   # 「; true」让 sh 不直接 exec 成 sleep：树里两个进程
SF=$(ls "$T/st"/nostall_stacks.*.log 2> /dev/null | head -1)
ck "⑧b 停前抓栈：rc=${r8b}、${SF:-没写}，进程段 $(grep -c '^== 进程' "${SF:-/dev/null}") 个" '[ $r8b = 124 ] && [ -n "$SF" ] && grep -qF "$SF" <<< "$o" && [ "$(grep -c "^== 进程" "$SF")" = 2 ] && grep -q "（sh，" "$SF" && grep -q "（sleep，" "$SF" && grep -q "nanosleep" "$SF"'
printf '#include <unistd.h>\nint main(int c,char**v){sleep(c>1?atoi(v[1]):6);return 0;}\n' | cc -include stdlib.h -x c - -o "$T/metal"   # 拷系统 sleep 会因签名被杀，现编一个叫 metal 的
mkdir -p "$T/ms/b-x"; python3 -c "import os,sys; [open(os.path.join(sys.argv[1], f'k{i}_b.json'), 'w').close() for i in range(20000)]" "$T/ms/b-x"
python3 - "$H/tools" "$T" <<'PY'
import os, signal, subprocess, sys, time
tools, T = sys.argv[1:3]
sys.path.insert(0, tools)
import nostall as N
bad = 0
def ck(name, ok):
    global bad
    print(('通 ' if ok else '不通 ') + name, flush=True)
    bad |= not ok
def wait_for(cond, dl=300):   # 按事件等；dl 只防挂死（前提一直不成立就让后面的判据红），不是判据
    end = time.monotonic() + dl
    while not cond() and time.monotonic() < end: time.sleep(0.02)
    return cond()

# ── 真进程：ps 读进程树 CPU 随计算涨（② 的读数来源）。子进程按自己的 CPU 时间报「算满了」再停下等，测试见报才读：读数之间子进程确定多算了 0.3 秒 CPU
CHILD = '''
import os, sys, time
d = sys.argv[1]
def burn(t):
    while time.process_time() < t: pass
burn(0.2); open(d + '/m1', 'w').close()
while not os.path.exists(d + '/go1'): time.sleep(0.02)
burn(0.5); open(d + '/m2', 'w').close()
while not os.path.exists(d + '/go2'): time.sleep(0.02)
'''
d = os.path.join(T, 'cpu'); os.mkdir(d)
c = subprocess.Popen([sys.executable, '-c', CHILD, d])
cpu = lambda: sum(v[0] for v in N.tree(c.pid).values())
c1 = cpu() if wait_for(lambda: os.path.exists(d + '/m1')) else -1.0
open(d + '/go1', 'w').close()
c2 = cpu() if wait_for(lambda: os.path.exists(d + '/m2')) else -1.0
open(d + '/go2', 'w').close(); c.wait()
ck(f'② 真进程树 CPU 读数随计算涨：算满 0.2 秒 CPU 时读 {c1:.2f}、再算 0.3 秒后读 {c2:.2f}（≥ 0.18、涨 ≥ 0.25）', c1 >= 0.18 and c2 - c1 >= 0.25)

# ── 真进程：树里的编译子进程按名认出（⑦ 的读数来源）。sh 下挂一个现编的 metal，等它出现在树里再判
s = subprocess.Popen(['sh', '-c', f'"{T}/metal" 600; true'])
names = lambda: {v[1] for v in N.tree(s.pid).values()}
seen = wait_for(lambda: 'metal' in names())
ck(f'⑦ 真进程树认出编译子进程：树里有 metal（{seen}）、编译器名规则认它（{bool(N.COMPILER.match("metal"))}）、不认 sleep / sh（{not N.COMPILER.match("sleep") and not N.COMPILER.match("sh")}）',
   seen and bool(N.COMPILER.match('metal')) and not N.COMPILER.match('sleep') and not N.COMPILER.match('sh'))
for x in N.tree(s.pid):
    try: os.kill(x, signal.SIGKILL)
    except ProcessLookupError: pass
s.wait()

# ── 真进程：进程磁盘读写字节随读盘涨（⑩ 的读数来源）。子进程先用 F_NOCACHE 写好 8 MB（不进页缓存）报 m1，测试读数后放行，它再 F_NOCACHE 读回 8 MB 报 m2
IOCHILD = '''
import fcntl, os, sys, time
d = sys.argv[1]; fd = os.open(d + '/blob', os.O_RDWR | os.O_CREAT); fcntl.fcntl(fd, 48, 1)   # 48 = F_NOCACHE
for i in range(8): os.pwrite(fd, b'x' * (1 << 20), i << 20)
os.fsync(fd); open(d + '/m1', 'w').close()
while not os.path.exists(d + '/go1'): time.sleep(0.02)
for i in range(8): os.pread(fd, 1 << 20, i << 20)
open(d + '/m2', 'w').close()
while not os.path.exists(d + '/go2'): time.sleep(0.02)
'''
if sys.platform == 'darwin':
    d = os.path.join(T, 'io'); os.mkdir(d)
    c = subprocess.Popen([sys.executable, '-c', IOCHILD, d])
    io = lambda: N.diskio([c.pid]).get(c.pid, -1)
    d1 = io() if wait_for(lambda: os.path.exists(d + '/m1')) else -1
    open(d + '/go1', 'w').close()
    d2 = io() if wait_for(lambda: os.path.exists(d + '/m2')) else -1
    open(d + '/go2', 'w').close(); c.wait()
    ck(f'⑩ 真进程磁盘读写字节随读盘涨：F_NOCACHE 读回 8 MB 前 {d1}、后 {d2}（读得到、涨 ≥ {8 << 20}）', d1 >= 0 and d2 - d1 >= 8 << 20)
else: print('跳过 ⑩ 真进程读数（F_NOCACHE 只在 macOS）', flush=True)

# ── 判定逻辑：假时钟 + 假进程驱动 nostall.main()；被盯路径的指纹走真文件系统
class Clock: t = 0.0
class FakeProc:
    pid = 424242
    def __init__(self, exit_at, work):
        self.exit_at, self.work, self.polls, self.term_at = exit_at, work, 0, None
    def wait(self, timeout=None):
        if self.term_at is not None: return -signal.SIGTERM
        if timeout is None: return 0
        nt = Clock.t + timeout
        if nt >= self.exit_at: Clock.t = self.exit_at; return 0
        Clock.t = nt; self.polls += 1; self.work(self.polls)
        raise subprocess.TimeoutExpired('fake', timeout)

def run(args, exit_at, work=lambda k: None, cpu=lambda t: 0.0, names=('sleep',), stdout_log=None, io=lambda t: 0):
    """→ (退出码, 假进程, 标准错误)。cpu(t)：假时刻 t 时整棵树的 CPU 秒；io(t)：假时刻 t 时根进程的磁盘读写字节；names：树里各进程名；stdout_log：把标准输出临时接到这个文件（看门狗会盯它）"""
    Clock.t = 0.0
    p = FakeProc(exit_at, work)
    def tree(pid): return {pid + k: (cpu(Clock.t) if k == 0 else 0.0, n) for k, n in enumerate(names)}
    def diskio(pids): return {x: (io(Clock.t) if x == p.pid else 0) for x in pids}
    def kill(pid, sig):
        if sig == signal.SIGTERM and p.term_at is None: p.term_at = Clock.t
    saved = (N.tree, N.diskio, N.stacks, subprocess.Popen, time.time, os.kill, sys.argv, sys.stderr)
    sigs = {x: signal.getsignal(x) for x in (signal.SIGTERM, signal.SIGINT)}   # main() 装的转发处理器指着假进程，跑完还原
    errf = open(os.path.join(T, 'err.txt'), 'w+')
    fd1 = os.dup(1) if stdout_log else None
    try:
        if stdout_log:
            sys.stdout.flush(); lf = os.open(stdout_log, os.O_WRONLY | os.O_APPEND); os.dup2(lf, 1); os.close(lf)
        N.tree, N.diskio, N.stacks = tree, diskio, (lambda t, dest: None)   # 抓栈由真进程 ⑧b 证
        subprocess.Popen, time.time, os.kill = (lambda cmd: p), (lambda: Clock.t), kill
        sys.argv, sys.stderr = ['nostall.py', *args, '--', 'fake'], errf
        rc = N.main()
    finally:
        N.tree, N.diskio, N.stacks, subprocess.Popen, time.time, os.kill, sys.argv, sys.stderr = saved
        if fd1 is not None: os.dup2(fd1, 1); os.close(fd1)
        for x, h in sigs.items(): signal.signal(x, h)
    errf.seek(0); err = errf.read(); errf.close()
    return rc, p, err

def newfile(dirpath):
    def w(k):
        tmp = os.path.join(dirpath, f'n{k}.tmp'); open(tmp, 'w').close(); os.rename(tmp, os.path.join(dirpath, f'n{k}_b.json'))
    return w
def append(path):
    def w(k):
        with open(path, 'a') as f: f.write(f'{k}\n')
    return w

# 期望（按规则：每 0.5 秒看一次、连续 2 秒一条进展都没有才判挂死）：跑 4 秒的命令要被看 7 次（0.5 … 3.5），跨过 2 秒窗口；
#   停的时刻 ∈ [2, 2.5]：窗口满 2 秒之后的第一次轮询
rc, p, _ = run(['2'], 4.0, cpu=lambda t: t * 0.8)
ck(f'② 一直在算 4 秒（窗口 2 秒，假时钟）→ rc={rc}（0）、被看 {p.polls} 次（7）、发停时刻 {p.term_at}（None）', rc == 0 and p.polls == 7 and p.term_at is None)
rc, p, _ = run(['--watch', os.path.join(T, 'out'), '2'], 4.0, work=newfile(os.path.join(T, 'out')))
ck(f'⑤ 树外写被盯目录（每格新建一个文件，假时钟）→ rc={rc}（0）、被看 {p.polls} 次（7）、发停时刻 {p.term_at}（None）', rc == 0 and p.polls == 7 and p.term_at is None)
log6 = os.path.join(T, 'log6'); open(log6, 'w').close()
rc, p, _ = run(['2'], 4.0, work=append(log6), stdout_log=log6)
ck(f'⑥ 树外追加命令日志（标准输出接到日志，每格追加一行，假时钟）→ rc={rc}（0）、被看 {p.polls} 次（7）、发停时刻 {p.term_at}（None）', rc == 0 and p.polls == 7 and p.term_at is None)
rc, p, _ = run(['2'], 4.0, names=('sh', 'metal'))
ck(f'⑦ 树里编译子进程活着、CPU 不涨（假时钟）→ rc={rc}（0）、被看 {p.polls} 次（7）、发停时刻 {p.term_at}（None）', rc == 0 and p.polls == 7 and p.term_at is None)
rc, p, err = run(['--watch', os.path.join(T, 'out'), '2'], 30.0, stdout_log=log6)
ck(f'⑧ 反证：盯着目录和日志但没人写、无编译器、CPU 不涨（假时钟）→ rc={rc}（124）、假时刻 {p.term_at} 发 TERM（∈ [2, 2.5]）、打【红】',
   rc == 124 and p.term_at is not None and 2.0 <= p.term_at <= 2.5 and '【红】无进展看门狗' in err)
rc, p, _ = run(['--watch', os.path.join(T, 'out'), '2'], 4.0, io=lambda t: int(t * 100e6), stdout_log=log6)
ck(f'⑩ 只在读盘（CPU 不涨、没人写、无编译器，磁盘读字节每秒涨 100 MB，假时钟）→ rc={rc}（0）、被看 {p.polls} 次（7）、发停时刻 {p.term_at}（None）', rc == 0 and p.polls == 7 and p.term_at is None)
rc, p, err = run(['--watch', os.path.join(T, 'out'), '2'], 30.0, io=lambda t: 5 << 30, stdout_log=log6)
ck(f'⑩反 读写字节停在 5 GiB 不动（假时钟）→ rc={rc}（124）、假时刻 {p.term_at} 发 TERM（2.5）、打【红】',
   rc == 124 and p.term_at == 2.5 and '【红】无进展看门狗' in err)
# ⑪ #1560（玩家出包最后一批两个 metal 进程卡了三个半小时，看门狗一直当它在干活）：在动不等于在前进。窗口 2 秒 → 产出上限 2 × 6 = 12 秒：
#   编译子进程一直活着、CPU 一直涨，被盯路径 / 日志 / 出包进度一次都没写 → 发停时刻 ∈ [12, 12.5]、红行写「产出没有前进」；
#   ⑪b 同样忙、出包进度文件（S2A_PROGRESS，不在 --watch 里）每格写一行 → 不杀；⑪c 产出每 10 秒才前进一次（< 12）→ 不杀
rc, p, err = run(['--watch', os.path.join(T, 'out'), '2'], 30.0, cpu=lambda t: t * 0.8, names=('sh', 'metal'), stdout_log=log6)
ck(f'⑪ 编译器一直活着、CPU 一直涨、产出 30 秒不动（假时钟）→ rc={rc}（124）、假时刻 {p.term_at} 发 TERM（∈ [12, 12.5]）、红行写产出没有前进',
   rc == 124 and p.term_at is not None and 12.0 <= p.term_at <= 12.5 and '产出没有前进' in err)
prog = os.path.join(T, 'progress.tsv'); open(prog, 'w').close(); os.environ['S2A_PROGRESS'] = prog
try:
    rc, p, _ = run(['--watch', os.path.join(T, 'out'), '2'], 30.0, work=append(prog), cpu=lambda t: t * 0.8, names=('sh', 'metal'), stdout_log=log6)
    ck(f'⑪b 同样忙、出包进度文件每格写一行（假时钟）→ rc={rc}（0）、发停时刻 {p.term_at}（None）', rc == 0 and p.term_at is None)
    rc, p, _ = run(['--watch', os.path.join(T, 'out'), '2'], 30.0, work=lambda k: k % 20 == 0 and append(prog)(k), cpu=lambda t: t * 0.8, names=('sh', 'metal'), stdout_log=log6)
    ck(f'⑪c 产出每 10 秒前进一次（假时钟）→ rc={rc}（0）、发停时刻 {p.term_at}（None）', rc == 0 and p.term_at is None)
finally: del os.environ['S2A_PROGRESS']
rc, p, _ = run(['--watch', os.path.join(T, 'ms'), '2'], 4.0, work=newfile(os.path.join(T, 'ms', 'b-x')))
n = [0]; st = os.stat
def counting(*a, **k): n[0] += 1; return st(*a, **k)
os.stat = counting
try: N.footprint([os.path.join(T, 'ms')])
finally: os.stat = st
ck(f'⑨ 写入在平铺 2 万文件的子目录（假时钟）→ rc={rc}（0）、被看 {p.polls} 次（7）、发停时刻 {p.term_at}（None）；算一次目录指纹 stat {n[0]} 次（< 100）', rc == 0 and p.polls == 7 and p.term_at is None and n[0] < 100)
sys.exit(bad)
PY
[ $? = 0 ] || bad=1
[ $bad = 0 ] && echo "nostall 单测全过" || { echo "nostall 单测有不通"; exit 1; }
