"""进程池路数的唯一取法（#1332 / D-VV4J）：凡按核数（或按阶段分到的路数）开进程池的，都经 process_pool_size。
Windows 上进程池最多 61 个工作进程：multiprocessing.Pool 的结果线程、ProcessPoolExecutor 的管理线程都用 WaitForMultipleObjects 等全部子进程，
系统上限 64 个句柄、扣掉池自己占的几个。超了 multiprocessing.Pool 卡死（88 核玩家出 iPhone 包停在「资源包 N/N」几个小时；
Windows 实测 Pool(61) 0.6 秒、Pool(62) 不动），ProcessPoolExecutor 直接抛 ValueError。这是 Windows 的固定上限，跟机器无关；
少于 61 路的照给，别的系统不封顶。线程池没有这个上限，不经 process_pool_size。
本机核数与此刻可用内存也只在这里读（cores / available_mb）：全仓按核数定并行度的地方都经 cores / env_jobs，不另读 os.cpu_count（tests/pool_size_lint_test.py 判红）。"""
import os
import subprocess
import sys

WINDOWS_MAX = 61


def _windows():   # 单测在 Mac 上模拟 Windows 时只换这一处，不碰全局 os.name（别处的 Windows 专用代码不受牵连）
    return os.name == "nt"


def process_pool_size(n):
    """要开 n 路的进程池 → 实际给几路：至少 1；Windows 上至多 61"""
    n = max(1, int(n or 1))
    return min(n, WINDOWS_MAX) if _windows() else n


def cores():
    """本机可用核数的唯一取法：S2A_NCPU 给了就用它（同 tools/cores.sh，单测 / 门禁模拟别的机器），否则 os.cpu_count；至少 1"""
    try:
        n = int(os.environ.get("S2A_NCPU") or 0)
    except ValueError:
        n = 0
    return max(1, n or os.cpu_count() or 1)


def env_jobs(*keys):
    """并行路数：按 keys 依次取环境变量里的正整数（如 J、S2A_JOBS，调用方 / tools/cores.sh 按核数与内存预算给的），都没有 → cores()"""
    for k in keys:
        try:
            n = int(os.environ.get(k) or 0)
        except ValueError:
            n = 0
        if n > 0:
            return n
    return cores()


def available_mb():
    """此刻可用内存（MB）。S2A_MEM_AVAIL_MB 覆盖（单测 / 模拟小内存机器，同 tools/cores.sh）；
    macOS vm_stat 空闲 + 非活跃 + 预读 + 可清除页；Windows GlobalMemoryStatusEx；Linux MemAvailable；都读不到 → None"""
    o = os.environ.get("S2A_MEM_AVAIL_MB")
    if o:
        try:
            return max(0, int(o))
        except ValueError:
            pass
    if sys.platform == "darwin":
        try:
            out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=5).stdout
            page, pages = 0, 0
            for line in out.splitlines():
                if "page size of" in line:
                    page = int(line.split("page size of")[1].split()[0])
                elif line.startswith(("Pages free:", "Pages inactive:", "Pages speculative:", "Pages purgeable:")):
                    pages += int(line.rsplit(None, 1)[1].rstrip("."))
            if page and pages:
                return pages * page >> 20
        except (OSError, ValueError, IndexError, subprocess.SubprocessError):
            pass
        return None
    if sys.platform == "win32":
        import ctypes
        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong), ("ullTotalPhys", ctypes.c_ulonglong),
                        ("ullAvailPhys", ctypes.c_ulonglong), ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                        ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong), ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
        st = MEMORYSTATUSEX(); st.dwLength = ctypes.sizeof(st)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
            return st.ullAvailPhys >> 20
        return None
    try:
        with open("/proc/meminfo", encoding="ascii") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) >> 10
    except (OSError, ValueError):
        pass
    return None
