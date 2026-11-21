// 直连出图 PSO 多槽缓存（PR3c，评审稿 v3 §2.2 PSO 缓存接缝 / §3 B3·B4·B5 / §4 PR3c）：按目标像素格式多槽，纯 C，
//   graphics/nvn/tests/t_present_pso.c 直测本头（nvn_present_fit.h 同族：生产代码 include 的同一份纯逻辑，不要 GPU）。
//   修的两个缺口：B3/B5 单槽「格式交替即重建」——层持 PQ（PR4 起的 RGB10A2Unorm 层）后，抗锯齿 / 放大器的中间图（BGRA8Unorm）与
//   PQ 层 drawable 在一帧内交替、截图的 BGRA8 目标与 HDR 层帧间交替，每交替一次重编一遍管线；且 Metal 4 不保留编码器取过的
//   PSO，重建即释放旧管线、在飞命令缓冲期悬垂（对齐 gal_present.m g_pr_pso[4] 四槽先例——两格式并存、互不逐出）。
//   B4 失败语义：基线槽（单槽时代所服务的一切非 PQ 层目标格式）维持现状 MDIE；只有 HDR 槽（PQ 层目标 RGB10A2Unorm）建不出时
//   回退基线 + 红日志（不 MDIE——不放宽 SDR 现状；回退的执行在平台侧 nvn_mtl.m：层切回 SDR 基线，本层只管表与负缓存）。
//   纯 C，不引平台头：MTLPixelFormat 的枚举值由平台侧原样传入当不透明槽键（只比相等），void* 由平台侧桥接真 PSO。
#pragma once
#include <stdint.h>

enum { PF_PSO_SLOTS = 4 };   // gal_present.m g_pr_pso[4] 同数：S0/S1 层两格式 + 截图 / 中间格式余量
enum { PF_PSO_MISS = 0, PF_PSO_HIT = 1, PF_PSO_DEAD = 2 };   // 查槽三态：未见过（要建）/ 命中（缓存直用）/ 死槽（HDR 槽建不出的负缓存）
typedef struct { uint32_t fmt; void *pso; int dead; } pf_pso_slot;   // fmt 0 = 空槽；dead：HDR 槽建不出，负缓存直到重建成翻身
typedef struct { pf_pso_slot s[PF_PSO_SLOTS]; int n; } pf_pso_tab;

// 查槽：live 槽命中（*out = PSO）；死槽返回 PF_PSO_DEAD（调用方回退基线，不再建——每帧重试会把一次性失败变成逐帧卡顿）；
//   没见过返回 PF_PSO_MISS（调用方建）。格式交替时两格式并存，互不逐出（单槽的重建 / 悬垂险就在这修掉）
static inline int pf_pso_lookup(const pf_pso_tab *t, uint32_t fmt, void **out) {
    if (out) *out = 0;
    for (int i = 0; i < t->n; i++) {
        if (t->s[i].fmt != fmt) continue;
        if (t->s[i].dead) return PF_PSO_DEAD;
        if (out) *out = t->s[i].pso;
        return PF_PSO_HIT;
    }
    return PF_PSO_MISS;
}

// 入槽：空位按到达序填（gal_present.m pr_pso_get 同款）。已在表的格式更新原槽（死槽翻身——HDR 槽重建成即恢复）。
//   表满返回 0：gal_present.m 四槽同款处置——调用方红一次、本格式不出图（四槽盖不住的第五种格式本不该出现）
static inline int pf_pso_add(pf_pso_tab *t, uint32_t fmt, void *pso) {
    for (int i = 0; i < t->n; i++) if (t->s[i].fmt == fmt) { t->s[i].pso = pso; t->s[i].dead = 0; return 1; }
    if (t->n >= PF_PSO_SLOTS) return 0;
    t->s[t->n].fmt = fmt; t->s[t->n].pso = pso; t->s[t->n].dead = 0; t->n++;
    return 1;
}

// 死槽登记（HDR 槽建不出，B4 的负缓存）：此后 lookup 恒 DEAD，不逐帧重试。首建即败（还没进过表）的格式也登记；
//   表满时不登记（第五种格式的失败已由 pf_pso_add 的表满红先行报告，重试无缓存代价可接受）。基线槽不走这里（照旧 MDIE）
static inline void pf_pso_dead(pf_pso_tab *t, uint32_t fmt) {
    for (int i = 0; i < t->n; i++) if (t->s[i].fmt == fmt) { t->s[i].dead = 1; return; }
    if (t->n >= PF_PSO_SLOTS) return;
    t->s[t->n].fmt = fmt; t->s[t->n].pso = 0; t->s[t->n].dead = 1; t->n++;
}

// 预热（启动预热候选组合，T11 首帧 / 首切换无 >100ms 编译卡顿）：候选逐个过 build——未见过才建（命中 / 死槽都跳过，
//   幂等：重复预热零新建）。build 返回空 = 该候选建不出，交调用方处置（基线 MDIE / HDR 负缓存——本层不管失败语义），不入槽。
//   返回本次新入槽数
static inline int pf_pso_warm(pf_pso_tab *t, const uint32_t *fmts, int n, void *(*build)(uint32_t fmt, void *ctx), void *ctx) {
    int added = 0;
    for (int i = 0; i < n; i++) {
        void *old;
        if (pf_pso_lookup(t, fmts[i], &old) != PF_PSO_MISS) continue;
        void *pso = build ? build(fmts[i], ctx) : 0;
        if (pso) added += pf_pso_add(t, fmts[i], pso);
    }
    return added;
}
