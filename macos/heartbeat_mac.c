// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Mac 心跳（#1050）：只编进 Mac 宿主（launchers/macos/build.mk HOST_SRCS），由 front_mac.m 的 10 秒定时器调。
//   不放 runtime/src/energy.c：它按名配单测 t_energy.c 只链 energy.c，心跳要的上屏帧数（ap_host.c）、客体内存文件后备（vawin.c）那里没有
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include "../runtime/src/native.h"
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <CoreFoundation/CoreFoundation.h>

int s2a_disk_io(uint64_t *rd, uint64_t *wr, uint64_t *pageins);   // runtime/src/energy.c
// Mac 心跳（iOS 的在 ios/app.m，节拍相同）：每 10 秒一行，前端定时器调。#1050：Mac 原先没有周期行，长局后段丢帧、慢动作、实占只涨不降都只能靠玩家自己量。
//   出帧 = 近 10 秒上屏帧数按实际间隔折成每秒（锁 30 掉到二十几就是游戏时间变慢）；读盘 / 缺页读入随丢帧一起涨 = 在等后备文件换页
uint64_t s2a_ap_frames(void);
void s2a_heartbeat_mac(void) {
    static uint64_t lf, lr, lw, lp, lt; static int have; static double tb; if (!tb) { mach_timebase_info_data_t i; mach_timebase_info(&i); tb = (double)i.numer / i.denom; }
    uint64_t f = s2a_ap_frames(), t = mach_absolute_time(), rd = 0, wr = 0, pi = 0; int io = s2a_disk_io(&rd, &wr, &pi) == 0;
    task_vm_info_data_t v; mach_msg_type_number_t c = TASK_VM_INFO_COUNT; unsigned long long fp = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&v, &c) == KERN_SUCCESS ? v.phys_footprint >> 20 : 0;
    double sec = have ? (double)(t - lt) * tb / 1e9 : 0;
    char iob[200] = "读写盘取不到";
    if (io) snprintf(iob, sizeof iob, "读盘 %llu MB、写盘 %llu MB、缺页读入 %llu 次", (unsigned long long)(have && rd >= lr ? (rd - lr) >> 20 : 0),
                     (unsigned long long)(have && wr >= lw ? (wr - lw) >> 20 : 0), (unsigned long long)(have && pi >= lp ? pi - lp : 0));
    LOG("[心跳] 帧 %llu，进程实占 %llu MB，近 %.0f 秒出帧 %llu（%.1f 帧/秒）、%s（客体内存文件后备 %s）", (unsigned long long)f, fp, sec,
        (unsigned long long)(have && f >= lf ? f - lf : 0), sec > 0 && f >= lf ? (double)(f - lf) / sec : 0.0, iob, s2a_guest_fd() >= 0 ? "开" : "关");
    lf = f; lt = t; if (io) { lr = rd; lw = wr; lp = pi; } have = 1;
    {   // 供电 / 窗口 / 游戏主线程调度（D-JSGK 11-22）：慢局性能核几乎没用、游戏在等，先分清是不是系统在节流本进程。
        //   电源 = 交流 / 电池；低电量模式与热状态取 NSProcessInfo（host_main.c）；窗口可见 = 没被挡 / 没最小化；主线程优先级 = 内核眼里的当前 / 基础优先级
        //   （USER_INTERACTIVE 约 47，App Nap / 后台节流压低；cur 远低于 base 就是被系统降了）
        int dm_low_power_now(void), dm_thermal_now(void), s2a_mac_window_visible(int *), s2a_guest_main_sched(int *, int *);
        char ps[32] = "取不到"; CFTypeRef blob = IOPSCopyPowerSourcesInfo();
        if (blob) { CFStringRef t = IOPSGetProvidingPowerSourceType(blob);
                    if (t) snprintf(ps, sizeof ps, "%s", CFEqual(t, CFSTR(kIOPMACPowerKey)) ? "交流电" : CFEqual(t, CFSTR(kIOPMBatteryPowerKey)) ? "电池" : "其它"); CFRelease(blob); }
        int hid = 0, vis = s2a_mac_window_visible(&hid), cur = -1, base = -1; char pr[96] = "取不到";
        if (!s2a_guest_main_sched(&cur, &base)) snprintf(pr, sizeof pr, "当前 %d / 基础 %d%s", cur, base, cur + 8 < base ? "（被系统压低：节流 / App Nap）" : "");
        LOG("[心跳] 供电 %s、低电量模式 %s、热状态 %d（0 正常 1 一般 2 严重 3 危急）；游戏窗口 %s（变成不可见累计 %d 次）；游戏主线程优先级 %s",
            ps, dm_low_power_now() ? "开" : "关", dm_thermal_now(), vis < 0 ? "还没建" : vis ? "可见" : "不可见（被挡 / 最小化）", hid, pr); }
    { void s2a_guest_backing_log(void); s2a_guest_backing_log(); }   // vawin.c：文件后备开着时报匿名块 / 文件块各多少（溢出模式，没开不打）
    s2a_energy_log();
}
