// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 取图线程实时声明被系统降级后怎么办（#1957 之外的另一单：D-7YPC / D-5JYW，Mac M1 一款 HashLink 游戏 DLC 场景卡成 7～12 帧）。
//   取图线程（游戏渲染线程）声明 THREAD_TIME_CONSTRAINT_POLICY 后 QoS 变成「未指定」；一帧超出申报的计算量多了，macOS 把它降成普通分时线程，
//   回落优先级按 QoS 算 = 0（日志「current priority 0 (base 0, policy 1)」），整个进程随即搬到能效核（性能核 0.05 核、能效核 1.17 核 @1.0 GHz），
//   GPU 只要 8.5 ms/帧、上屏却要 100+ ms。那局 9 次降级 8 次自己回来，1 次 1 万多帧没回来。
//   对策：每 30 帧读一次本线程调度策略；声明着却不在实时档 = 被降了：头一次当场重新声明；1 分钟内再被降，本局放弃实时声明，
//   改标准策略并用 THREAD_PRECEDENCE_POLICY 抬到优先级 47（USER_INTERACTIVE 那一档，留在性能核；设过策略的线程不能再设 QoS），不再随周期变化重报。
#pragma once
enum { RT_DEMOTE_NONE = 0, RT_DEMOTE_REDECLARE = 1, RT_DEMOTE_GIVE_UP = 2 };
// declared：本局还打算用实时声明；is_rt：内核现在把它放在实时档（policy ≠ 分时）；recent：最近 60 秒里已经处理过几次降级（不含这次）
static inline int rt_demote_action(int declared, int is_rt, int recent) {
    if (!declared || is_rt) return RT_DEMOTE_NONE;
    return recent >= 1 ? RT_DEMOTE_GIVE_UP : RT_DEMOTE_REDECLARE;
}
