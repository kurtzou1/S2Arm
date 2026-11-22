/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 S2Arm contributors */

// 管线缓存及其着色器在 worker / commit 退出后才销毁。只在实际录下 draw / dispatch 后记库程序。
static void loss_note_program(struct nvn_gpu_cmd_s *c, const struct nvn_gpu_pipe_s *p) {
    if (!p->lib_stages || p == c->loss_last_pipe || c->loss_programs_truncated) return;
    c->loss_last_pipe = p;
    for (unsigned i = 0; i < c->loss_nprograms; i++) {
        const struct nvn_gpu_pipe_s *other = c->loss_programs[i];
        if (p->lib_stages != other->lib_stages) continue;
        if (p->cshader) {
            if (p->cshader == other->cshader) return;
            continue;
        }
        // 同一组着色器可以配不同的光栅状态、附件和管线对象。
        unsigned st = 0;
        while (st < NVN_GPU_SH_CS && p->key.st[st].sh == other->key.st[st].sh) st++;
        if (st == NVN_GPU_SH_CS) return;
    }
    if (c->loss_nprograms == LOSS_PROGRAMS_PER_SEGMENT) {
        c->loss_programs_truncated = 1;
        return;
    }
    c->loss_programs[c->loss_nprograms++] = p;
}

enum loss_role { LOSS_OBSERVED, LOSS_INFLIGHT, LOSS_SUBMIT_UNCERTAIN };
enum { LOSS_SNAPSHOT_STAGES = 64 };

struct loss_candidate {
    uint64_t signal;
    unsigned program, stage;
    enum loss_role role;
    uint8_t key[8], digest[32];
};

struct loss_snapshot {
    struct loss_candidate items[LOSS_SNAPSHOT_STAGES];
    unsigned nitems, accepted, uncertain, wsi, library_segments, truncated_segments;
    int truncated_log;
};

static void loss_capture(struct loss_snapshot *dst, const struct vk_segment *s, enum loss_role role) {
    if (role == LOSS_SUBMIT_UNCERTAIN) dst->uncertain++;
    else dst->accepted++;
    if (s->internal) dst->wsi++;
    const struct nvn_gpu_cmd_s *c = s->cmd;
    if (!c || !c->loss_nprograms) return;
    dst->library_segments++;
    dst->truncated_segments += c->loss_programs_truncated;
    for (unsigned i = 0; i < c->loss_nprograms; i++) {
        const struct nvn_gpu_pipe_s *p = c->loss_programs[i];
        for (unsigned st = 0; st <= NVN_GPU_SH_CS; st++) {
            if (!(p->lib_stages & (1u << st))) continue;
            if (dst->nitems == LOSS_SNAPSHOT_STAGES) {
                dst->truncated_log = 1;
                return;
            }
            const struct nvn_gpu_shader_s *sh = st == NVN_GPU_SH_CS ? p->cshader : p->key.st[st].sh;
            struct loss_candidate *row = &dst->items[dst->nitems++];
            row->signal = s->signal;
            row->program = i;
            row->stage = st;
            row->role = role;
            memcpy(row->key, sh->stage_key, sizeof row->key);
            memcpy(row->digest, sh->spirv_digest, sizeof row->digest);
        }
    }
}

// 提交线程在调用 Vulkan 之前发布 submitting，与入队在 g_mu 下交接。读到该指针时，
// 提交可能还没返回，也可能未入队：票据状态报未定。等待栅栏的线程不需要等待队列调用返回。
// 栅栏等待失败时把该段标出。提交回 LOST 时该次尝试可能已在途，单独列出。
// 其它候选是已获 VK_SUCCESS、主机尚未见完成的段。驱动不提供这些候选的执行位置。
static void device_loss_report(struct nvn_gpu_vk *vk, const struct vk_segment *trigger, enum loss_role role) {
    struct loss_snapshot snap;
    pthread_mutex_lock(&g_mu);
    if (vk->loss_reported) {
        pthread_mutex_unlock(&g_mu);
        return;
    }
    vk->loss_reported = 1;
    snap.nitems = snap.accepted = snap.uncertain = snap.wsi = snap.library_segments = snap.truncated_segments = 0;
    snap.truncated_log = 0;
    loss_capture(&snap, trigger, role);
    const struct vk_segment *submitting = atomic_load(&vk->submitting);
    if (submitting && submitting != trigger) loss_capture(&snap, submitting, LOSS_SUBMIT_UNCERTAIN);
    if (vk->active_segment && vk->active_segment != trigger)
        loss_capture(&snap, vk->active_segment, LOSS_INFLIGHT);
    for (const struct vk_segment *s = vk->qhead; s; s = s->next)
        if (s->submitted) loss_capture(&snap, s, LOSS_INFLIGHT);
    pthread_mutex_unlock(&g_mu);

    const int ext = vk->dev->device_fault_ext_state;
    const char *fault = ext > 0 ? "advertised" : ext == 0 ? "absent" : "unknown";
    char line[360];
    snprintf(line, sizeof line,
             "device-lost first site=%s signal=%llu wsi_seq=%llu VK_EXT_device_fault=%s accepted_unretired=%u submit_uncertain=%u wsi=%u library_segments=%u truncated_segments=%u truncated_rows=%d stage_rows=%u",
             role == LOSS_OBSERVED ? "wait-fence" : "queue-submit", (unsigned long long)trigger->signal,
             (unsigned long long)trigger->wsi_seq, fault, snap.accepted, snap.uncertain, snap.wsi, snap.library_segments,
             snap.truncated_segments, snap.truncated_log, snap.nitems);
    nvn_plat_log(NVN_PLAT_LOG_RED, "gpu", line);

    static const char *const roles[] = {"observed", "inflight", "submit-uncertain"};
    static const char *const stages[] = {"vs", "fs", "gs", "tcs", "tes", "cs"};
    static const char hex[] = "0123456789abcdef";
    for (unsigned i = 0; i < snap.nitems; i++) {
        const struct loss_candidate *row = &snap.items[i];
        char key[17], digest[65];
        for (unsigned b = 0; b < sizeof row->key; b++) {
            key[2 * b] = hex[row->key[b] >> 4];
            key[2 * b + 1] = hex[row->key[b] & 15];
        }
        key[16] = '\0';
        s2a_sha256_hex(row->digest, digest);
        snprintf(line, sizeof line,
                 "device-lost candidate role=%s signal=%llu program=%u stage=%s key=%s spirv_sha256=%s",
                 roles[row->role], (unsigned long long)row->signal, row->program, stages[row->stage], key, digest);
        nvn_plat_log(NVN_PLAT_LOG_RED, "gpu", line);
    }
}
