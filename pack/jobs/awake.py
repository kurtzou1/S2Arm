# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""出包 / 推送期间不让电脑自己睡过去（v0.3.1 玩家反馈：推十几 GB 的包走 Wi-Fi 要二三十分钟，电脑按节能设置空闲休眠，推送停在半截，
手机游戏库显示「传输中断」）。只防系统空闲休眠：不拦合盖、不拦锁屏、不点亮屏幕。

Mac：起 /usr/bin/caffeinate -i -w <本作业进程号>，作业结束时停掉；作业进程被直接杀掉时 caffeinate 跟着退（-w），不会留下一直不睡的电脑。
Windows：在跑作业的线程上 SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)，结束时改回 ES_CONTINUOUS；线程 / 进程没了系统自动收回。
其它系统、或拿不到（caffeinate 不在、调用失败）：照常跑作业，标准错误记一行（只是可能会睡，不拦作业）。"""
from __future__ import annotations

import contextlib
import os
import subprocess
import sys

ES_CONTINUOUS = 0x80000000
ES_SYSTEM_REQUIRED = 0x00000001
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


def _hold_windows():
    import ctypes
    kernel = ctypes.windll.kernel32
    if not kernel.SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED):
        _say("保持电脑不休眠没开成（SetThreadExecutionState 返回 0），作业照常跑；电脑空闲休眠时推送 / 出包会停在半截")
        return lambda: None
    return lambda: kernel.SetThreadExecutionState(ES_CONTINUOUS)


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
