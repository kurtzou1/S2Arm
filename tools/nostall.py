#!/usr/bin/env python3
# 无进展看门狗（10-30 维护者 / 维护者「出包管线深修」①：固定墙钟超时把满载下的正常慢当挂死杀掉——今天实验单 20 张 0 绿，
#   抽取 timeout 900 杀 5 单、直连库 timeout 7200 杀 2 单；一款第一方动作冒险游戏同一步平时 443 秒，只有 2 倍余量）：
#   nostall.py [--watch <目录或文件>]… <无进展秒> -- <命令…>
#   每 S2A_NOSTALL_POLL（缺省 30）秒看一次「有没有进展」，下面任一成立都算；连续 <无进展秒> 一条都不成立才判挂死：
#     ① 被盯的路径有新写入：--watch 给的目录（目录自身与前几项子目录的修改时间——新建 / 改名 / 删除都会动它；不列全目录）
#        和文件，以及本命令的标准输出 / 标准错误（调用方重定向到日志文件时，日志在长就是在干活）
#     ② 命令及其全部子孙进程的 CPU 时间合计在涨
#     ③ 进程树里有编译子进程活着（xcrun / metal / metallib / clang / air-* / spirv-* / glslc …）
#     ④ 树里任一进程的磁盘读 / 写字节数在涨（macOS：libproc proc_pid_rusage 的 ri_diskio_bytesread / byteswritten；Linux：/proc/<pid>/io 的 read_bytes / write_bytes；
#        Windows：GetProcessIoCounters 的读 / 写 / 其他传输字节 + GetProcessMemoryInfo 的缺页次数（#680：原先 Windows 取不到、只看 ①②③，
#        11 GB 内存的笔记本上直连库「两张表收尾」等换页 615 秒、CPU 几乎不涨也不出声，被当挂死停掉，10 小时出包白跑）；取不到就只看 ①②③）
#   ④ 的来由（11-04 巫师3 c1104_w3astc 抽取被误杀：本机负载 100–200、多个出包同读工作盘，两个工作进程整 600 秒停在 mmap 切片的缺页读上，
#     缺页等盘几乎不涨 CPU、也还没写输出，旧版判挂死）。实测 mmap 缺页读计入 ri_diskio_bytesread（一款第一方游戏网球 xci 随机页读 5 秒：+452 MB，ri_pageins +26766）
#   ③ 的来由（10-31 mhrise-formal-f285 02:03 被误杀、01007EF00011E000 rc=124 同类）：Metal 编译真正在算的是系统的 MTLCompilerService，
#     它由 launchd 起、不在本进程树里；树里的 xcrun / metal 只在等它，树内 CPU 不涨，旧版只看 ②，把正在编库的出库判成挂死。
#   判挂死：打一行「【红】无进展看门狗：…」到标准错误、TERM 整棵树、10 秒后 KILL，退出 124（同 timeout，调用方按超时归类）。
#   停之前先给树里每个进程抓 1 秒原生调用栈（/usr/bin/sample，各进程同时抓），写进第一个被盯目录下的 nostall_stacks.<命令进程号>.log，红行写明路径
#   （11-02 无主之地3 S2Arm 抽取 600 秒无进展被停、CPU 停在 17.2 秒，只剩一行红：看不出是哪个进程停在管道读、信号量还是锁上；
#    抽取失败现场按 *.log 留进 .failed，这份栈跟着留下）。没有被盯目录就不抓
#   命令自己退出就原样交它的退出码。收到 TERM / INT 转给整棵树。不另开进程组（外层按进程组 / 进程树停出包时连同命令一起停，不留孤儿）
#   <无进展秒> 由调用方给（缺省口径：S2A_NOSTALL_S，出包链各处统一 600）
import ctypes, os, re, signal, stat, subprocess, sys, time

COMPILER = re.compile(r'^(xcrun|metal[-\w.]*|metallib|air[-\w.]*|clang(\+\+)?(-\d+)?|spirv-[-\w.]+|glslc|glslangValidator|dxc)$')
PEEK, DEPTH = 64, 3   # 被盯目录只看自身与前 PEEK 项里的子目录（至多 DEPTH 层），不列全目录（10-31 符文工房5：一层平铺 26.9 万个文件，全量列一次 36 秒以上、卡在 IO 等待）

WIN = sys.platform == 'win32'

def win_procs():   # Windows（#1100 W6）：没有 ps；Toolhelp 快照取 进程号 / 父进程号 / 映像名，GetProcessTimes 取 CPU（内核 + 用户）→ [(pid, ppid, 秒, 名)]
    import ctypes
    from ctypes import wintypes as w
    class PE(ctypes.Structure):
        _fields_ = [('dwSize', w.DWORD), ('cntUsage', w.DWORD), ('th32ProcessID', w.DWORD), ('th32DefaultHeapID', ctypes.c_size_t), ('th32ModuleID', w.DWORD),
                    ('cntThreads', w.DWORD), ('th32ParentProcessID', w.DWORD), ('pcPriClassBase', ctypes.c_long), ('dwFlags', w.DWORD), ('szExeFile', ctypes.c_wchar * 260)]
    k = ctypes.windll.kernel32; k.CreateToolhelp32Snapshot.restype = w.HANDLE; k.OpenProcess.restype = w.HANDLE
    snap = k.CreateToolhelp32Snapshot(2, 0); out = []; e = PE(); e.dwSize = ctypes.sizeof(PE)
    ok = k.Process32FirstW(snap, ctypes.byref(e))
    while ok:
        s = 0.0; h = k.OpenProcess(0x1000, False, e.th32ProcessID)   # PROCESS_QUERY_LIMITED_INFORMATION
        if h:
            ft = [w.FILETIME() for _ in range(4)]
            if k.GetProcessTimes(h, *[ctypes.byref(x) for x in ft]): s = sum((x.dwHighDateTime << 32 | x.dwLowDateTime) for x in ft[2:]) / 1e7
            k.CloseHandle(h)
        n = e.szExeFile; out.append((e.th32ProcessID, e.th32ParentProcessID, s, n[:-4] if n.lower().endswith('.exe') else n))
        ok = k.Process32NextW(snap, ctypes.byref(e))
    k.CloseHandle(snap)
    return out

def win_fd_path(fd):
    """Windows：文件描述符 → 它打开的文件路径（GetFinalPathNameByHandleW）；取不到 → None"""
    import msvcrt
    from ctypes import wintypes as w
    buf = ctypes.create_unicode_buffer(32768)
    n = ctypes.windll.kernel32.GetFinalPathNameByHandleW(w.HANDLE(msvcrt.get_osfhandle(fd)), buf, len(buf), 0)
    if not n or n >= len(buf): return None
    p = buf.value
    return p[4:] if p.startswith('\\\\?\\') else p

def tree(root):   # → {pid: (CPU 秒, 命令名)}，root 和它的全部子孙（ps 的 TIME 列：[[dd-]hh:]mm:ss.ss）
    if WIN:
        kids, info = {}, {}
        for pid, pp, s, n in win_procs():
            if pid != pp: kids.setdefault(pp, []).append(pid)
            info[pid] = (s, n)
        out, todo = {}, [root]
        while todo:
            x = todo.pop()
            if x in out: continue
            out[x] = info.get(x, (0.0, '')); todo += kids.get(x, [])
        return out
    r = subprocess.run(['ps', '-A', '-o', 'pid=,ppid=,time=,comm='], capture_output=True, text=True)
    kids, info = {}, {}
    for ln in r.stdout.splitlines():
        f = ln.split(None, 3)
        if len(f) < 3: continue
        pid, pp = int(f[0]), int(f[1]); kids.setdefault(pp, []).append(pid)
        d, _, t = f[2].rpartition('-'); s = 0.0
        for x in t.split(':'): s = s * 60 + float(x)
        info[pid] = (s + (int(d) * 86400 if d else 0), os.path.basename(f[3]) if len(f) > 3 else '')
    out, todo = {}, [root]
    while todo:
        x = todo.pop(); out[x] = info.get(x, (0.0, '')); todo += kids.get(x, [])
    return out

class _RI(ctypes.Structure):   # struct rusage_info_v2（<sys/resource.h>，RUSAGE_INFO_V2 = 2）
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        'user_time', 'system_time', 'pkg_idle_wkups', 'interrupt_wkups', 'pageins', 'wired_size', 'resident_size', 'phys_footprint',
        'proc_start_abstime', 'proc_exit_abstime', 'child_user_time', 'child_system_time', 'child_pkg_idle_wkups', 'child_interrupt_wkups',
        'child_pageins', 'child_elapsed_abstime', 'diskio_bytesread', 'diskio_byteswritten')]
try: _libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
except OSError: _libproc = None

def _win_io(pid):
    """Windows 一个进程的「在干活」读数：IO_COUNTERS 的读 / 写 / 其他传输字节 + 缺页次数 × 4096（等换页的进程 CPU 不涨、也不一定走 ReadFile，
    但缺页次数一定涨）；打不开（已退出 / 无权限）→ None"""
    from ctypes import wintypes as w
    class IO(ctypes.Structure):
        _fields_ = [(n, ctypes.c_ulonglong) for n in ('ReadOps', 'WriteOps', 'OtherOps', 'ReadBytes', 'WriteBytes', 'OtherBytes')]
    class MEM(ctypes.Structure):
        _fields_ = [('cb', w.DWORD), ('PageFaultCount', w.DWORD)] + [(n, ctypes.c_size_t) for n in (
            'PeakWorkingSetSize', 'WorkingSetSize', 'QuotaPeakPagedPoolUsage', 'QuotaPagedPoolUsage', 'QuotaPeakNonPagedPoolUsage',
            'QuotaNonPagedPoolUsage', 'PagefileUsage', 'PeakPagefileUsage')]
    k = ctypes.windll.kernel32; k.OpenProcess.restype = w.HANDLE
    h = k.OpenProcess(0x1000, False, pid)   # PROCESS_QUERY_LIMITED_INFORMATION：两个读数都够用
    if not h: return None
    try:
        io, mem = IO(), MEM(); mem.cb = ctypes.sizeof(MEM)
        got = 0
        if k.GetProcessIoCounters(h, ctypes.byref(io)): got += io.ReadBytes + io.WriteBytes + io.OtherBytes
        if k.K32GetProcessMemoryInfo(h, ctypes.byref(mem), mem.cb): got += mem.PageFaultCount * 4096
        return got
    finally:
        k.CloseHandle(h)

def diskio(pids):   # → {pid: 磁盘读 + 写字节数}；取不到的进程（已退出、无权限、平台不支持）不出现
    out = {}
    for pid in pids:
        if WIN:
            v = _win_io(pid)
            if v is not None: out[pid] = v
            continue
        if _libproc:
            r = _RI()
            if _libproc.proc_pid_rusage(pid, 2, ctypes.byref(r)) == 0: out[pid] = r.diskio_bytesread + r.diskio_byteswritten
        else:
            try:
                with open(f'/proc/{pid}/io') as f: kv = dict(ln.split(':', 1) for ln in f if ':' in ln)
                out[pid] = int(kv['read_bytes']) + int(kv['write_bytes'])
            except (OSError, KeyError, ValueError): pass
    return out

def footprint(paths):   # 被盯路径的「写入指纹」：文件看大小与修改时间；目录看自身的修改时间与链接数（在其中新建 / 改名 / 删除都会改它们），
    #   再往下只看前 PEEK 项里的子目录（出库写进 <输出>/b-<链>/：输出目录本身项很少，b-<链> 是其中一项）。从不全量列目录、不逐个 stat 文件
    sig = []
    def walk(d, depth):
        try: st = os.stat(d)
        except OSError: sig.append((d, None)); return
        sig.append((d, st.st_mtime_ns, st.st_nlink))
        if depth >= DEPTH: return
        try:
            with os.scandir(d) as it:
                for k, e in enumerate(it):
                    if k >= PEEK: break
                    if e.is_dir(follow_symlinks=False): walk(e.path, depth + 1)
        except OSError: pass
    for p in paths:
        try: st = os.stat(p)
        except OSError: sig.append((p, None)); continue
        if stat.S_ISDIR(st.st_mode): walk(p, 0)
        else: sig.append((p, st.st_size, st.st_mtime_ns))
    return hash(tuple(sig))

def stacks(t, dest):
    """树里每个进程的原生调用栈（sample 报告里「Call graph」一段）→ dest；各进程同时抓 1 秒。→ 写成的路径，没写成 → None"""
    if WIN: return None   # Windows 没有 /usr/bin/sample
    ps = {}
    for pid, (cpu, name) in t.items():
        try: ps[pid] = (cpu, name, subprocess.Popen(['/usr/bin/sample', str(pid), '1', '-mayDie'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True))
        except OSError: pass
    out = []
    for pid, (cpu, name, q) in sorted(ps.items()):
        try: rep = q.communicate(timeout=30)[0]
        except subprocess.TimeoutExpired: q.kill(); rep = q.communicate()[0]
        a = rep.find('Call graph:'); b = rep.find('Total number in stack', a)
        out.append(f'== 进程 {pid}（{name}，CPU {cpu:.1f} 秒）\n' + (rep[a:b if b > 0 else None].rstrip() if a >= 0 else '（没抓到：进程已退出或 sample 失败）') + '\n')
    try:
        with open(dest, 'w') as f: f.write('\n'.join(out))
        return dest
    except OSError: return None

def main():
    a, watch = sys.argv[1:], []
    while len(a) >= 2 and a[0] == '--watch': watch.append(a[1]); a = a[2:]
    if len(a) < 3 or a[1] != '--': sys.exit('用法：nostall.py [--watch <目录或文件>]… <无进展秒> -- <命令…>')
    limit, cmd = float(a[0]), a[2:]
    poll = float(os.environ.get('S2A_NOSTALL_POLL', '30'))
    for fd in (1, 2):   # 标准输出 / 错误是日志文件就一并盯
        try:
            if stat.S_ISREG(os.fstat(fd).st_mode):
                if not WIN: watch.append(f'/dev/fd/{fd}')
                elif (path := win_fd_path(fd)): watch.append(path)   # Windows 没有 /dev/fd：按句柄取日志文件的真实路径（#680）
        except OSError: pass
    p = subprocess.Popen(cmd)
    def fwd(sig, _):
        for x in tree(p.pid):
            try: os.kill(x, sig)
            except ProcessLookupError: pass
            except OSError:   # Windows：进程已退出时 os.kill 报 WinError 87 等，不是 ProcessLookupError
                if not WIN: raise
    signal.signal(signal.SIGTERM, fwd); signal.signal(signal.SIGINT, fwd)
    last_cpu, last_fp, last_io, since = -1.0, footprint(watch), {}, time.time()
    while True:
        try: rc = p.wait(timeout=poll); return rc if rc >= 0 else 128 - rc
        except subprocess.TimeoutExpired: pass
        t = tree(p.pid); c = sum(v[0] for v in t.values()); fp = footprint(watch)
        comp = sorted({v[1] for v in t.values() if COMPILER.match(v[1])})
        io = diskio(t)   # 按进程比（进程退出不让合计倒退）；新出现的进程和 0 比
        moved = c > last_cpu or fp != last_fp or comp or any(v > last_io.get(x, 0) for x, v in io.items())
        last_cpu, last_fp, last_io = max(c, last_cpu), fp, io
        if moved: since = time.time(); continue
        if time.time() - since >= limit:
            print(f'【红】无进展看门狗：{" ".join(cmd)[:160]} {limit:.0f} 秒没有任何进展——进程树 CPU 时间没涨（停在 {c:.1f} 秒）、磁盘读写字节没涨、'
                  f'被盯的输出 / 日志没有新写入（{len(watch)} 处）、树里没有编译子进程，判挂死、停掉', file=sys.stderr, flush=True)
            d = next((w for w in watch if os.path.isdir(w)), None)
            got = d and stacks(t, os.path.join(d, f'nostall_stacks.{p.pid}.log'))
            if got: print(f'  停之前各进程的调用栈（{len(t)} 个进程）：{got}', file=sys.stderr, flush=True)
            fwd(signal.SIGTERM, None)
            try: p.wait(timeout=10)
            except subprocess.TimeoutExpired: fwd(getattr(signal, 'SIGKILL', signal.SIGTERM), None); p.wait()   # Windows 的 os.kill 本就是 TerminateProcess
            return 124

if __name__ == '__main__': sys.exit(main())
