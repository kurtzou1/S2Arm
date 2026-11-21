#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
if [ "$(uname -s)" = Darwin ]; then
    export S2A_VULKAN_CACHE="$repo/build/vulkan-cache"
    exec bash "$repo/android/tests/vk/run.sh" "--pool-table${1:-}"
fi
# 找 lavapipe / validation 与 run.sh 的 find_icd / find_layer 同口径：Mesa 25 起 ICD 文件名不带架构（lvp_icd.json），
# 只认 lvp_icd.x86_64.json 会在新系统上整套报「missing lavapipe or validation」（11-17 GitHub android-vk 全片 rc=2）。
icd=${S2A_LAVAPIPE_ICD:-}
if [ -z "$icd" ]; then
    for f in "$HOME/.local/share/vulkan/icd.d/lvp_icd.json" "$HOME/.local/share/vulkan/icd.d/lvp_icd."*.json \
             /usr/share/vulkan/icd.d/lvp_icd.json /usr/share/vulkan/icd.d/lvp_icd.*.json; do
        [ -f "$f" ] && { icd=$f; break; }
    done
fi
layer=${S2A_VK_LAYER_DIR:-}
if [ -z "$layer" ]; then
    for d in "$HOME/.local/share/vulkan/explicit_layer.d" /usr/share/vulkan/explicit_layer.d; do
        [ -f "$d/VkLayer_khronos_validation.json" ] && { layer=$d; break; }
    done
fi
[ -f "$icd" ] && [ -f "$layer/VkLayer_khronos_validation.json" ] || { echo 'missing lavapipe or validation' >&2; exit 2; }
[ -f "$repo/build/c883-ndk/vulkan/vulkan_core.h" ] || { echo 'NDK 29 headers not staged' >&2; exit 2; }
out="$repo/build/vk-pool-table"; mkdir -p "$out"
mode=${1:-}
# 竞态用例不建 VkDevice：只链后端与依赖，不跑 lavapipe/VVL（那里 ASan 会撞 LLVM JIT）。
if [ "$mode" = -race ] || [[ "$mode" == -race-neg-* ]]; then
    inc=(); for d in android/tests/vkhost build/c883-ndk graphics/nvn graphics/nvn/replay graphics/nvn/gfx/nvn graphics/nvn/gfx/nvn/include android/native android/native/nvn android/native/direct runtime/include; do inc+=(-I "$repo/$d"); done
    src=(android/tests/vk/t_pool_race.c android/native/nvn/backend_vulkan.c android/native/nvn/nvn_pipe_flight.c android/native/nvn/nvn_vk_pipe_once.c android/native/direct/vk_device.c android/native/direct/gs_path.c android/native/capprobe/capprobe_host.c android/native/nvn/nvn_vk_format.c graphics/nvn/gfx/nvn/nvn_fmt_expand.c graphics/nvn/replay/nvn_unimpl.c android/native/nvn/nvn_vk_bcdec.c android/native/nvn/nvn_vk_driver_cache.c android/native/direct/sha256.c)
    for i in "${!src[@]}"; do src[$i]="$repo/${src[$i]}"; done
    if [ "$mode" != -race ]; then
        cp "$repo/android/native/nvn/backend_vulkan.c" "$out/race_mutant.c"
        python3 - "$repo/android/native/nvn/backend_vulkan_pool.inc" "$out/backend_vulkan_pool.inc" "$mode" <<'PYRACE'
import pathlib, sys
src, dst, mode = sys.argv[1:]
s = pathlib.Path(src).read_text()
mutations = {
 '-race-neg-atomic': (
   "    if (!p || p->released) { pthread_mutex_unlock(&g_mu); return 0; }\n    p->refs++;\n    pthread_mutex_unlock(&g_mu);\n",
   "    if (!p || p->released) { pthread_mutex_unlock(&g_mu); return 0; }\n    pthread_mutex_unlock(&g_mu);\n#ifdef S2A_NVK_POOL_HOST_TEST\n    if (g_pool_test_hook) { void (*hook)(nvn_gpu_pool_table) = g_pool_test_hook; g_pool_test_hook = NULL; hook(t); }\n#endif\n    pthread_mutex_lock(&g_mu);\n    p->refs++;\n    pthread_mutex_unlock(&g_mu);\n"),
 '-race-neg-released': (
   'if (!p || p->released) { pthread_mutex_unlock(&g_mu); return 0; }',
   'if (!p) { pthread_mutex_unlock(&g_mu); return 0; }'),
 '-race-neg-unref': (
   "static void pool_cmd_unref(struct nvn_gpu_cmd_s *c, nvn_gpu_pool_table t) {\n    if (c->nrefs && c->refs[c->nrefs - 1].obj == t && c->refs[c->nrefs - 1].type == REF_POOL) c->nrefs--;\n    pthread_mutex_lock(&g_mu);\n    unref_locked(&g, t, REF_POOL);\n    pthread_mutex_unlock(&g_mu);\n}",
   "static void pool_cmd_unref(struct nvn_gpu_cmd_s *c, nvn_gpu_pool_table t) { (void)c; (void)t; }"),
}
if mode not in mutations: raise SystemExit('unknown pool race mutation: ' + mode)
a, b = mutations[mode]
if s.count(a) != 1: raise SystemExit('pool race mutation anchor changed: ' + mode)
pathlib.Path(dst).write_text(s.replace(a, b))
PYRACE
        src[1]="$out/race_mutant.c"
    fi
    cc -fsanitize=address -fno-omit-frame-pointer -D_POSIX_C_SOURCE=200809L -std=c11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -ffunction-sections -fdata-sections -DS2A_ANDROID_VK_BACKEND_NVN_VK=1 -DS2A_NVK_POOL_HOST_TEST=1 "${inc[@]}" "${src[@]}" -Wl,--gc-sections -lvulkan -lpthread -lm -o "$out/race"
    set +e
    ASAN_OPTIONS=detect_leaks=0 timeout 120 "$out/race" 2>&1 | tee "$out/race.log"
    rc=${PIPESTATUS[0]}
    set -e
    if [ "$mode" = -race ]; then
        [ "$rc" -eq 0 ] || exit 1
        ! grep -q "AddressSanitizer" "$out/race.log" || exit 1
        exit 0
    fi
    [ "$rc" -ne 0 ] || { echo "mutation $mode unexpectedly passed" >&2; exit 1; }
    case "$mode" in
        -race-neg-atomic) expected='AddressSanitizer|FAIL race bind' ;;
        -race-neg-released) expected='FAIL released table resurrected' ;;
        -race-neg-unref) expected='FAIL layout failure leaked ref' ;;
        *) exit 2 ;;
    esac
    grep -qE "$expected" "$out/race.log" || { echo "mutation $mode failed somewhere else" >&2; exit 1; }
    echo "negative control $mode: expected failure observed"
    exit 0
fi
"${GLSLC:-glslc}" --target-env=vulkan1.1 "$repo/android/tests/vk/shaders/pool_table.comp" -o "$out/pool_table.comp.spv"
"${GLSLC:-glslc}" --target-env=vulkan1.1 -DPOOL_ARRAY_LEN=64 "$repo/android/tests/vk/shaders/pool_table.comp" -o "$out/pool_table_small.comp.spv"
inc=(); for d in android/tests/vkhost build/c883-ndk graphics/nvn graphics/nvn/replay graphics/nvn/gfx/nvn graphics/nvn/gfx/nvn/include android/native android/native/nvn android/native/direct runtime/include; do inc+=(-I "$repo/$d"); done
src=(android/tests/vk/t_pool_table.c android/native/nvn/backend_vulkan.c android/native/nvn/nvn_pipe_flight.c android/native/nvn/nvn_vk_pipe_once.c android/native/direct/vk_device.c android/native/direct/gs_path.c android/native/capprobe/capprobe_host.c android/native/nvn/nvn_vk_format.c graphics/nvn/gfx/nvn/nvn_fmt_expand.c graphics/nvn/replay/nvn_unimpl.c android/native/nvn/nvn_vk_bcdec.c android/native/nvn/nvn_vk_driver_cache.c android/native/direct/sha256.c)
for i in "${!src[@]}"; do src[$i]="$repo/${src[$i]}"; done
if [ -n "$mode" ]; then
    cp "$repo/android/native/nvn/backend_vulkan.c" "$out/mutant.c"
    python3 - "$repo/android/native/nvn/backend_vulkan_pool.inc" "$out/backend_vulkan_pool.inc" "$mode" "$out/mutant.c" <<'PYMUT'
import pathlib, sys
src, dst, mode, cpath = sys.argv[1:]
s = pathlib.Path(src).read_text()
mutations = {
 '-neg-image': ('t->images[i].imageView = v->view;', 't->images[i].imageView = (i == 64 ? dv : v)->view;'),
 '-neg-sampler': ('t->images[i].sampler = d->sampler_integer ? s->int_sampler : s->sampler;', 't->images[i].sampler = (i == 64 ? ds : s)->sampler;'),
 '-neg-empty': ('t->objects[i] = v; ref_bump(v, REF_VIEW);', 'if (state == NVN_GPU_POOL_EMPTY && i < d->count) { v = t->objects[0]; } t->objects[i] = v; ref_bump(v, REF_VIEW);'),
 '-neg-type': ('v->tex->samples != dv->tex->samples) v = dv;', 'v->tex->samples != dv->tex->samples) v = t->objects[0];'),
 '-neg-numeric': ('else if (got != cls || v->type != dv->type', 'else if (got != cls) v = t->objects[0]; else if (v->type != dv->type'),
 '-neg-bounds': ('t->objects[i] = v; ref_bump(v, REF_VIEW);', 'if (i == d->count) { v = t->objects[0]; } t->objects[i] = v; ref_bump(v, REF_VIEW);'),
 '-neg-cap': ('if (!g.dev->descriptor_indexing_enabled)', 'if (0 && !g.dev->descriptor_indexing_enabled)'),
 '-neg-limit': ('(uint64_t)d->count + 1 > lim1', '(uint64_t)d->count + 1 > (lim1 | UINT32_MAX)'),
 '-neg-unavailable': ('if (state == NVN_GPU_POOL_UNAVAILABLE) {', 'if (state == NVN_GPU_POOL_UNAVAILABLE) { state = NVN_GPU_POOL_EMPTY; } if (state == NVN_GPU_POOL_UNAVAILABLE) {'),
 '-neg-rebind': ('c->pool_binds[st][ent] = t; c->pool_active = 1; c->desc_dirty', 'if (!c->pool_binds[st][ent]) { c->pool_binds[st][ent] = t; } c->pool_active = 1; c->desc_dirty'),
 '-neg-fence': ('    p->refs++;\n    pthread_mutex_unlock(&g_mu);\n    return cmd_ref_append(c, t, REF_POOL);', '    /* mutation: 不取引用 */\n    pthread_mutex_unlock(&g_mu);\n    return cmd_ref_append(c, t, REF_POOL);'),
 '-neg-aggregate': ('if (limit) { pool_cmd_unref(c, t); return pool_bind_error(c, err, NVN_GPU_E_UNSUPPORTED, limit); }', 'if (0 && limit) { pool_cmd_unref(c, t); return pool_bind_error(c, err, NVN_GPU_E_UNSUPPORTED, limit); }'),
 '-neg-sampler-resource': ('d->kind == NVN_GPU_POOL_IMAGE && (uint64_t)d->count + 1 > l->maxPerStageResources', '(uint64_t)d->count + 1 > l->maxPerStageResources'),
 '-neg-preflight': ('if (pool_shader_source(compute)) return pool_pipeline_limit(p, graphics);', 'if (0 && pool_shader_source(compute)) return pool_pipeline_limit(p, graphics);'),
 # 整池组备忘（nvk_pool_memo）：键里不放池快照序号 → 换了快照却命中旧组
 '-neg-memo-key': ('info[e->set].k1 += pool_key_mix1(e->binding, t->uid); info[e->set].k2 += pool_key_mix2(e->binding, t->uid);',
                   'info[e->set].k1 += pool_key_mix1(e->binding, 0); info[e->set].k2 += pool_key_mix2(e->binding, 0);'),
 # 整池组回收（nvk_pool_rec）：取组时不核键（任何空闲组都当「键相同」）→ 换了采样器 / 贴图池快照却不重写，读到旧内容
 '-neg-rec-key': ('if (b->free[i]->k1 == si->k1 && b->free[i]->k2 == si->k2) { at = i; hit = 1; break; }', 'if (1) { at = i; hit = 1; break; }'),
 # 整表写完不记键 → 空闲串里的组永远对不上，第二段还是整表重写
 '-neg-rec-mark': ('c->prs_use[uidx].rs->k1 = si->k1; c->prs_use[uidx].rs->k2 = si->k2;', '(void)c; (void)uidx; (void)si;'),
 # 键不同的空闲组也当「内容就绪」不写整表 → 里面还是上一张表的内容，读到旧的采样 / 贴图
 '-neg-rec-valid': ('*uidx = c->prs_n++; *out = rs->set; *valid = hit;', '*uidx = c->prs_n++; *out = rs->set; *valid = hit || !reserve;'),
 # 总量不按字节封顶（放得下放不下都新建）
 '-neg-rec-cap': ('if (g_prs_bytes + nb > g_prs_cap) { why = 2; b = NULL; }', 'if (0) { why = 2; b = NULL; }'),
 # 空闲不封顶
 '-neg-rec-keep': ('if (!g_prs_closed && rs->bytes <= g_prs_idle_cap) {', 'if (!g_prs_closed) {'),
 # 字节估算不乘每项字节数（只数了描述符项数）→ 账上的字节和估算公式对不上，封顶也就失准
 '-neg-rec-bytes': ('return bytes < PRS_GROUP_MIN_BYTES ? PRS_GROUP_MIN_BYTES : bytes;', '(void)bytes; return n < PRS_GROUP_MIN_BYTES ? PRS_GROUP_MIN_BYTES : n;'),
 # 淘汰挑了空闲串里最新放回的、不是最久没用的 → 留下的是老组
 '-neg-rec-lru': ('    struct pool_rs *rs = ob->free[0];\n    memmove(ob->free, ob->free + 1, (size_t)(ob->nfree - 1) * sizeof *ob->free);\n    ob->nfree--;',
                  '    struct pool_rs *rs = ob->free[ob->nfree - 1];\n    ob->nfree--;'),
 # 跨布局淘汰不比 seq（只拿第一个有空闲组的布局的头）→ 刚放回的小组被淘汰、更老的大组留着
 '-neg-rec-global': ('if (b->nfree && (!ob || b->free[0]->seq < ob->free[0]->seq)) ob = b;', 'if (b->nfree && !ob) ob = b;'),
 # 向驱动新建放不下时不淘汰空闲组（别的布局占着空闲组也直接退回老路径）
 '-neg-rec-evict-take': ('for (struct pool_rs *ev; g_prs_bytes + nb > g_prs_cap && (ev = prs_evict_oldest_locked()); ) { ev->next = dead; dead = ev; }', ';'),
 # 放回空闲串时空闲超封顶不淘汰（空闲越攒越多）
 '-neg-rec-evict-rel': ('for (struct pool_rs *ev; g_prs_idle_bytes + rs->bytes > g_prs_idle_cap && (ev = prs_evict_oldest_locked()); ) { ev->next = dead; dead = ev; }', ';'),
 # 缺省空闲封顶又设回总量的一半 → 一帧用到的组一起放回空闲串，比一帧的用量还小（真机重场景每帧淘汰 14–30 组又新建）；缺省封顶读数对不上
 '-neg-rec-default-half': ('g_prs_cap = (uint64_t)mb << 20; g_prs_idle_cap = g_prs_cap;', 'g_prs_cap = (uint64_t)mb << 20; g_prs_idle_cap = g_prs_cap / 2;'),
 # 放回时按空闲封顶的一半淘汰 → 一帧用到的组数等于封顶能放的组数时，每帧都淘汰又新建
 '-neg-rec-keep-half': ('g_prs_idle_bytes + rs->bytes > g_prs_idle_cap && (ev = prs_evict_oldest_locked())', 'g_prs_idle_bytes + rs->bytes > g_prs_idle_cap / 2 && (ev = prs_evict_oldest_locked())'),
}
# 下面几条改的是 backend_vulkan.c（已拷成 mutant.c），.inc 原样放过去
cmutations = {
 # 整池组永不命中 = 修前的行为：同键第二笔还是新建 + 整池重写
 '-neg-memo-miss': ('if (m->h1 == h1[set] && m->h2 == h2[set] && m->dsl == p->dsl[set])', 'if (!(pool_dirty >> set & 1) && m->h1 == h1[set] && m->h2 == h2[set] && m->dsl == p->dsl[set])'),
 # 开关 nvk_pool_memo=0 不起作用
 '-neg-memo-flag': ('(g_pmemo_cur && !pool_fb)', '(1 && !pool_fb)'),
 # 整池组的键里不放这一笔的普通绑定 → 换了输出缓冲却命中旧组，第二块输出缓冲没人写
 '-neg-memo-binding': ('for (int k = 0; k < 5; k++) { h1[set] = (h1[set] ^ v[k])', 'for (int k = 0; k < 5 && !(pool_dirty >> set & 1); k++) { h1[set] = (h1[set] ^ v[k])'),
 # 开关 nvk_pool_rec=0 不起作用
 '-neg-rec-flag': ('const int rec = g_prs_cur && pool_dirty &&', 'const int rec = 1 && pool_dirty &&'),
}
if mode not in mutations and mode not in cmutations: raise SystemExit('unknown pool mutation: ' + mode)
if mode in mutations:
    a, b = mutations[mode]
    if s.count(a) != 1: raise SystemExit('pool mutation anchor changed: ' + mode)
    pathlib.Path(dst).write_text(s.replace(a, b))
else:
    a, b = cmutations[mode]
    cs = pathlib.Path(cpath).read_text()
    if cs.count(a) != 1: raise SystemExit('pool mutation anchor changed: ' + mode)
    pathlib.Path(cpath).write_text(cs.replace(a, b))
    pathlib.Path(dst).write_text(s)
PYMUT
    src[1]="$out/mutant.c"
fi
cc -D_POSIX_C_SOURCE=200809L -std=c11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -ffunction-sections -fdata-sections -DS2A_ANDROID_VK_BACKEND_NVN_VK=1 -DS2A_NVK_POOL_HOST_TEST=1 "${inc[@]}" "${src[@]}" -Wl,--wrap=vkBeginCommandBuffer -Wl,--wrap=vkQueueSubmit -Wl,--wrap=vkAllocateDescriptorSets -Wl,--wrap=vkGetPhysicalDeviceFormatProperties -Wl,--wrap=vkCreatePipelineCache -Wl,--wrap=vkGetPipelineCacheData -Wl,--wrap=vkCreateGraphicsPipelines -Wl,--wrap=vkCreateComputePipelines -Wl,--gc-sections -lvulkan -lpthread -lm -o "$out/test"
set +e
ASAN_OPTIONS=detect_leaks=0 VK_DRIVER_FILES="$icd" VK_LAYER_PATH="$layer" VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation timeout 120 "$out/test" "$out" 2>&1 | tee "$out/run.log"
rc=${PIPESTATUS[0]}
set -e
if [ -n "$mode" ]; then
    [ "$rc" -ne 0 ] || { echo "mutation $mode unexpectedly passed" >&2; exit 1; }
    case "$mode" in
        -neg-image) expected='pool dispatch output\[10\]' ;;
        -neg-sampler) expected='pool dispatch output\[4\]' ;;
        -neg-empty) expected='pool dispatch output\[13\]' ;;
        -neg-type) expected='pool dispatch output\[17\]' ;;
        -neg-numeric) expected='pool dispatch output\[25\]' ;;
        -neg-bounds) expected='pool dispatch output\[21\]' ;;
        -neg-cap) expected='pool missing feature' ;;
        -neg-limit) expected='exceeds reduced stage sampler limit' ;;
        -neg-unavailable) expected='registered unavailable resource must reject' ;;
        -neg-rebind) expected='replacement output\[9\]' ;;
        -neg-fence) expected='pool command must hold snapshot reference' ;;
        -neg-aggregate) expected='aggregate stage resources 66 images' ;;
        -neg-sampler-resource) expected='samplers must not count against maxPerStageResources' ;;
        -neg-preflight) expected='small pool pipeline aggregate 64 images'  ;;
        -neg-memo-key) expected='pool memo table change output\[10\]' ;;
        -neg-memo-miss) expected='pool memo same key: need/hit/made/elems expected 2/1/1/132' ;;
        -neg-memo-flag) expected='pool memo off: need/hit/made/elems expected 2/0/2/264' ;;
        -neg-memo-binding) expected='pool memo binding change second output\[0\]' ;;
        -neg-rec-key) expected='pool rec stale sampler: need/memohit/oldnew/elems/rec-hit/miss/new/fallback expected 2/1/0/132/0/1/0/0' ;;
        -neg-rec-mark) expected='pool rec warm: need/memohit/oldnew/elems/rec-hit/miss/new/fallback expected 2/1/0/0/1/0/0/0' ;;
        -neg-rec-valid) expected='pool rec stale sampler: need/memohit/oldnew/elems/rec-hit/miss/new/fallback expected 2/1/0/132/0/1/0/0' ;;
        -neg-rec-cap) expected='pool rec cap: need/memohit/oldnew/elems/rec-hit/miss/new/fallback expected 2/0/1/264/0/0/1/1' ;;
        -neg-rec-keep) expected='pool rec keep: total/idle expected 0/0' ;;
        -neg-rec-bytes) expected='pool rec bytes: total/idle bytes expected' ;;
        -neg-rec-lru) expected='pool rec lru keeps second' ;;
        -neg-rec-global) expected='pool rec global lru evict: total/idle/bytes/evicted expected' ;;
        -neg-rec-evict-take) expected='pool rec cross evict small: need/memohit/oldnew/elems/rec-hit/miss/new/fallback expected 1/0/0/128/0/0/1/0' ;;
        -neg-rec-evict-rel) expected='pool rec lru: total/idle/bytes/evicted expected 2/2/' ;;
        -neg-rec-default-half) expected='pool rec default caps: total/idle caps expected 384 MB/equal' ;;
        -neg-rec-keep-half) expected='pool rec steady frame 2+: need/memohit/oldnew/elems/rec-hit/miss/new/fallback expected 3/0/0/0/3/0/0/0' ;;
        -neg-rec-flag) expected='pool rec off: need/memohit/oldnew/elems/rec-hit/miss/new/fallback expected 2/1/1/132/0/0/0/0' ;;
        *) exit 2 ;;
    esac
    grep -q "FAIL .*${expected}" "$out/run.log" || { echo "mutation $mode failed somewhere else" >&2; exit 1; }
    echo "negative control $mode: expected behavior assertion failed"
    exit 0
fi
if [ "$rc" -ne 0 ] || grep -qE 'Validation Error|VUID-' "$out/run.log"; then exit 1; fi
