# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""出包 / 推送期间不让电脑自己睡过去（v0.3.1 玩家反馈：推十几 GB 的包走 Wi-Fi 要二三十分钟，电脑按节能设置空闲休眠，推送停在半截，
手机游戏库显示「传输中断」）。只防系统空闲休眠：不拦合盖、不拦锁屏、不点亮屏幕。

Mac：起 /usr/bin/caffeinate -i -w <本作业进程号>，作业结束时停掉；作业进程被直接杀掉时 caffeinate 跟着退（-w），不会留下一直不睡的电脑。
Windows：电源请求（PowerCreateRequest + PowerSetRequest：PowerRequestSystemRequired 与 PowerRequestExecutionRequired），结束时 PowerClearRequest、关句柄；
  进程没了系统自动收回，`powercfg /requests` 里看得到这一条。原先用 SetThreadExecutionState(ES_SYSTEM_REQUIRED) 只挡空闲计时器，
  「现代待机」的笔记本熄屏后照样进待机、挂起桌面程序（11-21：一位 4 核玩家出包夜里整整 517 分钟没有一条事件，早上才接着编）；
  ExecutionRequired 是现代待机下让桌面程序继续跑的那一种。
其它系统、或拿不到（caffeinate 不在、调用失败）：照常跑作业，标准错误记一行（只是可能会睡，不拦作业）。"""
from __future__ import annotations

import contextlib
import os
import subprocess
import sys

POWER_REQUEST_SYSTEM_REQUIRED, POWER_REQUEST_EXECUTION_REQUIRED = 1, 3   # POWER_REQUEST_TYPE
POWER_REQUEST_CONTEXT_VERSION, POWER_REQUEST_CONTEXT_SIMPLE_STRING = 0, 0x1
REASON = "S2Arm is building or sending a game"   # powercfg /requests 里显示的理由（系统界面，不是玩家句）
CAFFEINATE = "/usr/bin/caffeinate"


def _say(text):
    print(f"[s2a] {text}", file=sys.stderr, flush=True)


def _spawn(argv):
    return subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _hold_mac():
    try:
        p = _spawn([CAFFEINATE, "-i", "-w", str(os.getpid())])
    except OSError as error:
        _say(f"保持电脑不休眠没开成（{error}），作业照常跑；电脑空闲休眠时推送 / 出包会停在半截")
        return lambda: None

    def release():
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
    return release


def _win_power():
    """Windows 电源请求的四个调用（单测替换这一层）→ (create, set, clear, close)"""
    import ctypes
    from ctypes import wintypes

    class REASON_CONTEXT(ctypes.Structure):
        _fields_ = [("Version", wintypes.ULONG), ("Flags", wintypes.DWORD), ("SimpleReasonString", wintypes.LPWSTR)]

    kernel = ctypes.windll.kernel32
    kernel.PowerCreateRequest.restype = wintypes.HANDLE
    kernel.PowerCreateRequest.argtypes = [ctypes.POINTER(REASON_CONTEXT)]
    kernel.PowerSetRequest.argtypes = kernel.PowerClearRequest.argtypes = [wintypes.HANDLE, ctypes.c_int]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    invalid = wintypes.HANDLE(-1).value

    def create():
        h = kernel.PowerCreateRequest(ctypes.byref(REASON_CONTEXT(POWER_REQUEST_CONTEXT_VERSION, POWER_REQUEST_CONTEXT_SIMPLE_STRING, REASON)))
        return None if not h or h == invalid else h
    return create, kernel.PowerSetRequest, kernel.PowerClearRequest, kernel.CloseHandle


def _hold_windows():
    create, set_request, clear_request, close = _win_power()
    handle = create()
    if handle is None:
        _say("保持电脑不休眠没开成（PowerCreateRequest 失败），作业照常跑；电脑空闲休眠时推送 / 出包会停在半截")
        return lambda: None
    held = [t for t in (POWER_REQUEST_SYSTEM_REQUIRED, POWER_REQUEST_EXECUTION_REQUIRED) if set_request(handle, t)]
    if POWER_REQUEST_SYSTEM_REQUIRED not in held:
        _say("保持电脑不休眠没开成（PowerSetRequest 失败），作业照常跑；电脑空闲休眠时推送 / 出包会停在半截")

    def release():
        for t in held:
            clear_request(handle, t)
        close(handle)
    return release


@contextlib.contextmanager
def keep_awake():
    """with 块里电脑不空闲休眠；块结束（完成 / 失败 / 取消）就放开"""
    if sys.platform == "darwin":
        release = _hold_mac()
    elif os.name == "nt":
        release = _hold_windows()
    else:
        release = lambda: None   # noqa: E731
    try:
        yield
    finally:
        release()
