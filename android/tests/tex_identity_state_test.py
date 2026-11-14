#!/usr/bin/env python3
"""A3：附件对象身份复核（三态）+ 可查墓碑（serial/描述/退休代际）的宿主合同（不建 Vulkan 设备）。

被测判据/表直接取自生产源码，用同一份测试编译（同 tex_zero_descriptor_test.py 的口径）：
  - `nvn_vk_texcache_tex_identity`（texcache.c）：记录里的 tex_t 快照三态
    未绑定(NULL) / 已绑定但描述无效 / 描述有效。只看快照本身是否自洽，不猜 guest 意图。
  - 墓碑环 `tex_tombstones_add` / `tex_tombstones_find`（texcache.c）+ 状态判据
    `tex_serial_state_from`：活着 / 已退休（返回退休时描述与退休代际）/ 从未创建 /
    未知（墓碑表满或淘汰过条目后，“查不到”不再等于“从未创建”）。活条目优先于墓碑。
  - `find_texture`（vk_record.c）：同 serial 活条目优先（沿 7a74818b8 语义），先整体扫 serial
    再退回 key/动态解析；同一批表里旧 key 命中不得抢在新 serial 之前。
  - `tex_attachment_failure`（vk_record.c）：解析不到时的类型化失败
    “已绑定但描述无效”（S2A_RECORD_INVALID）/ “已退休(Finalize)”（S2A_RECORD_INVALID）/
    完全不确定时保留原有“解析不到”（返回 0，由调用方报 S2A_RECORD_MEMORY）。

--source-ref <git rev> 用同一份测试编译旧版本源码，用于“先红后绿/撤回”对照。
--withdraw 行为撤回对照：把关键实现改回旧行为（墓碑不记/状态忽略墓碑/serial 不优先/接受 0 尺寸/
退休不分类），每条变异都必须让合同转红；变异体存活 = 本测试没有鉴别力 = 失败。
"""
from pathlib import Path
import argparse
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-ref", help="git revision for source withdrawal control")
parser.add_argument("--keep", help="keep the generated C file at this path (debugging)")
parser.add_argument("--withdraw", action="store_true", help="run behaviour-withdrawal mutations (each must turn red)")
args = parser.parse_args()


def source(path):
    if args.source_ref:
        return subprocess.check_output(["git", "show", f"{args.source_ref}:{path}"], cwd=ROOT, text=True)
    return (ROOT / path).read_text()


def function(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth, i = 1, brace + 1
    while depth:
        depth += (text[i] == "{") - (text[i] == "}")
        i += 1
    return text[start:i]


def block(text, start_marker, end_marker):
    i = text.index(start_marker)
    j = text.index(end_marker, i) + len(end_marker)
    return text[i:j]


def define(text, name):
    m = re.search(rf"^#define {name} (0x[0-9a-fA-F]+|\d+)$", text, re.M)
    if not m:
        raise SystemExit(f"红：源码里找不到 #define {name}（当前源码应含 A3 合同；--source-ref 旧版本在此红）")
    return f"#define {name} {m.group(1)}"


def enum_block(text, first_value):
    pos = text.index(first_value)
    start = text.rindex("enum {", 0, pos)
    end = text.index("};", pos) + 2
    return text[start:end]


tex_c = source("android/native/nvn/nvn_vk_texcache.c")
tex_h = source("android/native/nvn/nvn_vk_texcache.h")
rec_c = source("android/native/direct/vk_record.c")

# 合同锁：判据/墓碑/状态查询的类型与常量必须仍在生产源码里，任何漂移都让测试编译失败。
try:
    tomb_max = define(tex_h, "NVK_TEX_TOMB_MAX")
    tomb_struct = block(tex_h, "struct nvn_tex_tombstone {", "};")
    tombs_struct = block(tex_h, "struct nvn_tex_tombstones {", "};")
    id_enum = enum_block(tex_h, "NVN_TEX_ID_UNBOUND")
    state_enum = enum_block(tex_h, "NVN_TEX_SERIAL_NEVER")
except (ValueError, IndexError):
    raise SystemExit("红：A3 的判据/墓碑合同不在源码里（三态枚举、nvn_tex_tombstone(s)、NVK_TEX_TOMB_MAX；--source-ref 旧版本在此红）")

try:
    identity = function(tex_c, "int nvn_vk_texcache_tex_identity(const tex_t *t, char *why, size_t why_size) {")
    state_from = function(tex_c, "static int tex_serial_state_from(int live_hit, int tomb_hit, int tomb_evicted) {")
    tomb_add = function(tex_c, "static void tex_tombstones_add(struct nvn_tex_tombstones *tt, struct nvn_tex_tombstone e) {")
    tomb_find = function(tex_c, "static const struct nvn_tex_tombstone *tex_tombstones_find(const struct nvn_tex_tombstones *tt, uint64_t serial) {")
except (ValueError, IndexError):
    raise SystemExit("红：源码里找不到 A3 判据/墓碑函数（tex_identity / tex_serial_state_from / tombstones_add/find；--source-ref 旧版本在此红）")

try:
    find_texture = function(rec_c, "static const struct s2a_replay_texture *find_texture(const struct s2a_replay_texture *textures,")
    attachment_failure = function(rec_c, "static int tex_attachment_failure(int identity, const char *detail, int serial_state,")
except (ValueError, IndexError):
    raise SystemExit("红：vk_record.c 里找不到 serial 优先的 find_texture / tex_attachment_failure（A3 接线缺失；--source-ref 旧版本在此红）")

preamble = r'''
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* 共享记录布局的最小替身：只放被测函数读到的字段，字段名与 nvn_obj.h 同形（改名会让本测试编译失败）。 */
typedef struct { int target, format, flags, samples; uint32_t width, height, depth, levels, stride; int pkg_layout; } nvn_texdesc;
typedef struct { uint64_t size, layer_size; uint32_t align, layers, bpb; unsigned tileH, tileD; } nvn_texlayout;
typedef struct { uint32_t magic, flags; uint8_t *mem; uint64_t size; int32_t nvmap; uint64_t gva; } pool_t;
typedef struct {
    uint32_t magic; nvn_texdesc d; uint8_t has_layout, set_swz : 1, stencil : 1; uint16_t swz;
    nvn_texlayout L; uint8_t *mem; pool_t *pool; int64_t off; uint8_t layout[8]; uint64_t serial;
} tex_t;
#define MAGIC(a, b, c, d) ((uint32_t)(a) | (uint32_t)(b) << 8 | (uint32_t)(c) << 16 | (uint32_t)(d) << 24)
#define NVN_TEXTURE_TARGET_1D 0x0
#define NVN_TEXTURE_TARGET_2D 0x1
#define NVN_TEXTURE_TARGET_3D 0x2
#define NVN_TEXTURE_TARGET_1D_ARRAY 0x3
#define NVN_TEXTURE_TARGET_2D_ARRAY 0x4
#define NVN_TEXTURE_TARGET_2D_MULTISAMPLE 0x5
#define NVN_TEXTURE_TARGET_2D_MULTISAMPLE_ARRAY 0x6
#define NVN_TEXTURE_TARGET_RECTANGLE 0x7
#define NVN_TEXTURE_TARGET_CUBEMAP 0x8
#define NVN_TEXTURE_TARGET_CUBEMAP_ARRAY 0x9
#define NVN_TEXTURE_TARGET_BUFFER 0xA

/* 回放纹理表替身（vk_record.h）。Vulkan 句柄在失败判据里只作不透明身份。 */
typedef uintptr_t VkImage;
typedef uint32_t VkFormat;
struct s2a_replay_texture {
    const void *key; VkImage image; VkFormat format;
    uint32_t width, height, depth; uint64_t serial; uint32_t levels, layers;
};
typedef int (*s2a_record_tex_resolve)(void *opaque, const void *key, struct s2a_replay_texture *out);
static s2a_record_tex_resolve g_tex_resolve;
static void *g_tex_resolve_opaque;
static struct s2a_replay_texture g_tex_scratch;

/* 生产记录码（vk_record.h）：失败分类只沿用现有 ABI，本测试锁住“不新增码”。 */
enum { S2A_RECORD_OK = 0, S2A_RECORD_ARGUMENT = -1, S2A_RECORD_INVALID = -2,
       S2A_RECORD_UNSUPPORTED = -3, S2A_RECORD_GPU = -4, S2A_RECORD_MEMORY = -5,
       S2A_RECORD_DEPTH = -6, S2A_RECORD_LIMIT = -7 };
'''

main = r'''
static int g_checks, g_failed;
static void check(int cond, const char *what) {
    g_checks++;
    if (!cond) { g_failed++; printf("FAIL: %s\n", what); }
}

static tex_t make_tex(uint64_t serial, uint32_t w, uint32_t h) {
    tex_t t;
    memset(&t, 0, sizeof t);
    t.magic = MAGIC('T', 'E', 'X', 0);
    t.serial = serial;
    t.mem = (uint8_t *)(uintptr_t)0x1000;
    t.pool = (pool_t *)(uintptr_t)0x2000;
    t.d.target = NVN_TEXTURE_TARGET_2D;
    t.d.format = 0x0A;
    t.d.width = w; t.d.height = h;
    t.d.levels = 1;
    t.L.layers = 1;
    return t;
}

/* ---- 1) 三态判据：未绑定 / 已绑定但描述无效 / 描述有效 ---- */
static void test_identity(void) {
    char why[160];
    tex_t v = make_tex(7, 1280, 720);
    check(nvn_vk_texcache_tex_identity(NULL, why, sizeof why) == NVN_TEX_ID_UNBOUND, "identity: NULL is unbound");
    check(nvn_vk_texcache_tex_identity(&v, why, sizeof why) == NVN_TEX_ID_DESC_VALID, "identity: full 2D snapshot is valid");

    struct { tex_t t; const char *name; } bad[16];
    int nb = 0;
#define BAD(name_, stmt) do { bad[nb].t = make_tex(7, 640, 360); bad[nb].name = name_; stmt; nb++; } while (0)
    BAD("serial-0", bad[nb].t.serial = 0);
    BAD("magic-wrong", bad[nb].t.magic = 0);
    BAD("no-storage", bad[nb].t.mem = NULL);
    BAD("no-pool", bad[nb].t.pool = NULL);
    BAD("width-0", bad[nb].t.d.width = 0);
    BAD("height-0", bad[nb].t.d.height = 0);
    BAD("format-none", bad[nb].t.d.format = 0);
    BAD("target-outside", bad[nb].t.d.target = 0x42);
    BAD("levels-cannot-fit", bad[nb].t.d.levels = 11);
    BAD("layers-0", bad[nb].t.L.layers = 0);
    BAD("3d-depth-0", (bad[nb].t.d.target = NVN_TEXTURE_TARGET_3D, bad[nb].t.d.depth = 0));
    BAD("cubemap-5-faces", (bad[nb].t.d.target = NVN_TEXTURE_TARGET_CUBEMAP, bad[nb].t.L.layers = 5));
    BAD("cube-array-not-multiple-6", (bad[nb].t.d.target = NVN_TEXTURE_TARGET_CUBEMAP_ARRAY, bad[nb].t.L.layers = 8));
    BAD("ms-count-on-2d", bad[nb].t.d.samples = 4);
    BAD("ms-target-single-sample", (bad[nb].t.d.target = NVN_TEXTURE_TARGET_2D_MULTISAMPLE, bad[nb].t.d.samples = 1));
#undef BAD
    for (int i = 0; i < nb; i++) {
        char label[96];
        snprintf(label, sizeof label, "identity: invalid snapshot rejected (%s)", bad[i].name);
        int got = nvn_vk_texcache_tex_identity(&bad[i].t, why, sizeof why);
        check(got == NVN_TEX_ID_DESC_INVALID && why[0] != 0, label);
    }

    /* 合法但本后端未接的 NVN 组合仍是“描述有效”（能力缺口由解析层报，不在判据里判死）。 */
    tex_t ms = make_tex(8, 640, 360);
    ms.d.target = NVN_TEXTURE_TARGET_2D_MULTISAMPLE;
    ms.d.samples = 4;
    check(nvn_vk_texcache_tex_identity(&ms, why, sizeof why) == NVN_TEX_ID_DESC_VALID, "identity: self-consistent MS snapshot is valid");
    tex_t cube = make_tex(9, 256, 256);
    cube.d.target = NVN_TEXTURE_TARGET_CUBEMAP;
    cube.L.layers = 6;
    check(nvn_vk_texcache_tex_identity(&cube, why, sizeof why) == NVN_TEX_ID_DESC_VALID, "identity: 6-face cubemap snapshot is valid");
    tex_t t3 = make_tex(10, 64, 64);
    t3.d.target = NVN_TEXTURE_TARGET_3D; t3.d.depth = 16; t3.L.layers = 1;
    check(nvn_vk_texcache_tex_identity(&t3, why, sizeof why) == NVN_TEX_ID_DESC_VALID, "identity: 3D depth slice snapshot is valid");
    tex_t buf = make_tex(11, 64, 1);
    buf.d.target = NVN_TEXTURE_TARGET_BUFFER;
    check(nvn_vk_texcache_tex_identity(&buf, why, sizeof why) == NVN_TEX_ID_DESC_VALID, "identity: buffer target is in the NVN domain");
    /* 数组目标的 depth 是层数（shape() 语义），不是“非 3D 就非法”；1D_ARRAY 的 height 是层数。 */
    tex_t arr = make_tex(12, 128, 64);
    arr.d.target = NVN_TEXTURE_TARGET_2D_ARRAY; arr.d.depth = 4; arr.L.layers = 4;
    check(nvn_vk_texcache_tex_identity(&arr, why, sizeof why) == NVN_TEX_ID_DESC_VALID, "identity: 2D array depth-as-layers is valid");
    tex_t arr1 = make_tex(13, 64, 3);
    arr1.d.target = NVN_TEXTURE_TARGET_1D_ARRAY; arr1.d.height = 3; arr1.L.layers = 3;
    check(nvn_vk_texcache_tex_identity(&arr1, why, sizeof why) == NVN_TEX_ID_DESC_VALID, "identity: 1D array height-as-layers is valid");
}

/* ---- 2) 墓碑环 + 状态判据 ---- */
static void test_tombstones(void) {
    struct nvn_tex_tombstones tt;
    memset(&tt, 0, sizeof tt);

    /* 活条目优先于任何墓碑：serial 复用后的新对象不能被旧墓碑拦下。 */
    check(tex_serial_state_from(1, 1, 1) == NVN_TEX_SERIAL_LIVE, "state: live beats tombstone");
    check(tex_serial_state_from(1, 0, 1) == NVN_TEX_SERIAL_LIVE, "state: live beats unknown");
    check(tex_serial_state_from(0, 1, 0) == NVN_TEX_SERIAL_RETIRED, "state: tombstone hit is retired");
    check(tex_serial_state_from(0, 0, 0) == NVN_TEX_SERIAL_NEVER, "state: absence before any eviction is never-created");
    check(tex_serial_state_from(0, 0, 1) == NVN_TEX_SERIAL_UNKNOWN, "state: absence after eviction is unknown, not never-created");

    for (uint64_t s = 11; s <= 33; s += 11) {
        struct nvn_tex_tombstone e;
        memset(&e, 0, sizeof e);
        e.serial = s; e.width = 100 + (uint32_t)s; e.height = 200; e.nvn_format = 0x32;
        tex_tombstones_add(&tt, e);
    }
    const struct nvn_tex_tombstone *hit = tex_tombstones_find(&tt, 22);
    check(hit && hit->width == 122 && hit->height == 200 && hit->nvn_format == 0x32, "tomb: descriptor snapshot retained");
    check(hit && hit->generation == 2, "tomb: retirement generation is monotonic per retirement");
    check(tex_tombstones_find(&tt, 44) == NULL, "tomb: unknown serial is absent");
    check(tt.evicted == 0 && tt.n == 3, "tomb: ring not evicted while below capacity");

    /* 同一 serial 再次退休（同 serial 重建后再 Finalize）：更新原条目，不新增重复项，代际继续单调。 */
    {
        struct nvn_tex_tombstone again;
        memset(&again, 0, sizeof again);
        again.serial = 22; again.width = 640; again.height = 480; again.nvn_format = 0x33;
        tex_tombstones_add(&tt, again);
        const struct nvn_tex_tombstone *re = tex_tombstones_find(&tt, 22);
        check(re && re->width == 640 && re->nvn_format == 0x33 && tt.n == 3 && re->generation == 4,
              "tomb: same-serial retirement updates the entry and keeps generation monotonic");
    }
    /* serial 0 没有可锚定身份，不能写进墓碑。 */
    {
        struct nvn_tex_tombstone anon;
        memset(&anon, 0, sizeof anon);
        tex_tombstones_add(&tt, anon);
        check(tt.n == 3 && tt.generation == 4, "tomb: serial 0 is not recorded");
    }

    /* 表满后覆盖最旧：evicted > 0；最旧查不到、最新查得到 → 之后“缺席”只能报未知。 */
    for (uint32_t i = 0; i < NVK_TEX_TOMB_MAX; i++) {
        struct nvn_tex_tombstone e;
        memset(&e, 0, sizeof e);
        e.serial = 1000 + i;
        tex_tombstones_add(&tt, e);
    }
    check(tt.n == NVK_TEX_TOMB_MAX, "tomb: bounded table stays at capacity");
    check(tt.evicted > 0, "tomb: overflow is counted");
    check(tex_tombstones_find(&tt, 11) == NULL, "tomb: oldest entry evicted");
    check(tex_tombstones_find(&tt, 1000 + NVK_TEX_TOMB_MAX - 1) != NULL, "tomb: newest entry retained");
    check(tex_serial_state_from(0, tex_tombstones_find(&tt, 11) != NULL, tt.evicted != 0) == NVN_TEX_SERIAL_UNKNOWN,
          "state: evicted tombstone lookup answers unknown");
}

/* ---- 3) find_texture：同 serial 活条目优先，然后 key，最后动态解析 ---- */
static int mock_resolve_calls;
static int mock_resolve(void *opaque, const void *key, struct s2a_replay_texture *out) {
    (void)opaque;
    mock_resolve_calls++;
    memset(out, 0, sizeof *out);
    out->image = (VkImage)0xD00D;
    out->serial = ((const tex_t *)key)->serial;
    return 1;
}

static void test_find_texture(void) {
    tex_t snap_a = make_tex(42, 0, 0);      /* 快照不带尺寸（guest 重建中间态的形状） */
    tex_t snap_b = make_tex(42, 640, 360);  /* 同 serial 的活条目有真实尺寸 */
    tex_t probe = make_tex(42, 0, 0);       /* 记录里的副本 */
    struct s2a_replay_texture tbl[2];
    memset(tbl, 0, sizeof tbl);
    tbl[0].key = &snap_a; tbl[0].serial = 0; tbl[0].width = 1;      /* 旧 key 恰好命中，但 serial 不是身份 */
    tbl[1].key = &snap_b; tbl[1].serial = 42; tbl[1].width = 640; tbl[1].height = 360;
    check(find_texture(tbl, 2, &probe) == &tbl[1], "find: same-serial live entry beats stale key hit");
    check(find_texture(tbl, 2, &snap_b) == &tbl[1], "find: same pointer + serial still resolves the entry");

    /* key 退回：serial 为 0（无身份调用）时按 key 匹配。 */
    tex_t solo = make_tex(0, 64, 64);
    struct s2a_replay_texture one;
    memset(&one, 0, sizeof one);
    one.key = &solo; one.image = (VkImage)0xAA;
    check(find_texture(&one, 1, &solo) == &one, "find: key match still works for identity-less calls");
    check(find_texture(&one, 1, NULL) == NULL, "find: NULL key does not read through a snapshot");

    /* 动态解析：静态表未命中才回调；解析器必须回填调用方的 key。 */
    g_tex_resolve = mock_resolve; g_tex_resolve_opaque = NULL;
    mock_resolve_calls = 0;
    tex_t only = make_tex(99, 32, 32);
    const struct s2a_replay_texture *r = find_texture(tbl, 2, &only);
    check(r == &g_tex_scratch && r->key == &only && mock_resolve_calls == 1, "find: resolver fallback + key backfilled");
    g_tex_resolve = NULL;
    check(find_texture(tbl, 2, &only) == NULL, "find: unknown key with no resolver is a miss");
}

/* ---- 4) 解析失败的分类/报错文本（沿用现有 S2A_RECORD_*，不新增 ABI） ---- */
static void test_attachment_failure(void) {
    char why[256];
    int code = 0;

    memset(why, 0, sizeof why); code = 0;
    int got = tex_attachment_failure(NVN_TEX_ID_DESC_INVALID, "extent is 0", NVN_TEX_SERIAL_NEVER, NULL, &code, why, sizeof why);
    check(got == 1 && code == S2A_RECORD_INVALID, "fail: invalid descriptor + miss -> typed failure");
    check(strstr(why, "invalid") && strstr(why, "extent is 0"), "fail: invalid descriptor reason preserved");

    code = 0;
    got = tex_attachment_failure(NVN_TEX_ID_DESC_INVALID, "extent is 0", NVN_TEX_SERIAL_UNKNOWN, NULL, &code, why, sizeof why);
    check(got == 1 && code == S2A_RECORD_INVALID, "fail: invalid descriptor + unknown state -> typed failure");

    code = 0;
    got = tex_attachment_failure(NVN_TEX_ID_DESC_INVALID, "extent is 0", NVN_TEX_SERIAL_LIVE, NULL, &code, why, sizeof why);
    check(got == 0, "fail: live entry present -> keep the resolver's own failure (no misreport)");

    struct nvn_tex_tombstone tomb;
    memset(&tomb, 0, sizeof tomb);
    tomb.serial = 14468; tomb.generation = 37; tomb.width = 0; tomb.height = 0; tomb.nvn_format = 0x32;
    memset(why, 0, sizeof why); code = 0;
    got = tex_attachment_failure(NVN_TEX_ID_DESC_VALID, "", NVN_TEX_SERIAL_RETIRED, &tomb, &code, why, sizeof why);
    check(got == 1 && code == S2A_RECORD_INVALID, "fail: tombstone hit -> typed failure");
    check(strstr(why, "retired") && strstr(why, "Finalize") && strstr(why, "14468") && strstr(why, "37"),
          "fail: retired message carries identity + retirement generation");

    code = 0;
    got = tex_attachment_failure(NVN_TEX_ID_DESC_INVALID, "extent is 0", NVN_TEX_SERIAL_RETIRED, &tomb, &code, why, sizeof why);
    check(got == 1 && strstr(why, "retired"), "fail: tombstone wins over an inconsistent snapshot copy");

    code = 0;
    got = tex_attachment_failure(NVN_TEX_ID_DESC_VALID, "", NVN_TEX_SERIAL_NEVER, NULL, &code, why, sizeof why);
    check(got == 0, "fail: valid descriptor + never-created -> keep the existing not-resolvable failure");
    got = tex_attachment_failure(NVN_TEX_ID_DESC_VALID, "", NVN_TEX_SERIAL_UNKNOWN, NULL, &code, why, sizeof why);
    check(got == 0, "fail: valid descriptor + unknown -> keep the existing not-resolvable failure");
    got = tex_attachment_failure(NVN_TEX_ID_UNBOUND, "", NVN_TEX_SERIAL_NEVER, NULL, &code, why, sizeof why);
    check(got == 0, "fail: unbound target keeps the existing no-target semantics");
}

int main(void) {
    test_identity();
    test_tombstones();
    test_find_texture();
    test_attachment_failure();
    printf("tex-identity-state: %d checks, %d failed (host mock, no Vulkan device)\n", g_checks, g_failed);
    printf("%s\n", g_failed == 0 ? "ALL PASSED" : "FAILED");
    return g_failed == 0 ? 0 : 1;
}
'''

full_source = (preamble + "\n" + tomb_max + "\n" + tomb_struct + "\n" + tombs_struct + "\n" +
               id_enum + "\n" + state_enum + "\n" +
               identity + "\n" + state_from + "\n" + tomb_add + "\n" + tomb_find + "\n" +
               find_texture + "\n" + attachment_failure + "\n" + main)


def build_and_run(text, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    exe = Path(str(path) + ".bin")
    subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra", "-Werror",
                    str(path), "-o", str(exe)], check=True)
    return subprocess.run([str(exe)], text=True, capture_output=True)


# 行为撤回对照：每条变异把关键机制改回旧行为，合同必须转红。
MUTATIONS = [
    ("ignore-tombstone-state",
     "    if (tomb_hit) return NVN_TEX_SERIAL_RETIRED;",
     "    (void)tomb_hit;   /* mutation: retired looks like never-created */"),
    ("stop-recording-tombstones",
     "    tt->e[slot] = e;",
     "    (void)e;   /* mutation: tombstones not recorded */"),
    ("drop-serial-first-lookup",
     "                if (textures[i].serial == serial) return &textures[i];",
     "                if (0) return &textures[i];   /* mutation: serial-first lookup dropped */"),
    ("accept-zero-extent",
     '    if (!t->d.width || (t->d.target != NVN_TEXTURE_TARGET_1D && !t->d.height)) TEX_ID_INVALID("extent is 0");',
     "    /* mutation: zero extent accepted as a valid snapshot */"),
    ("ignore-retired-failure",
     "    if (serial_state == NVN_TEX_SERIAL_RETIRED && tomb) {",
     "    if (0) {   /* mutation: retired target not classified */"),
]

if args.withdraw:
    failures = 0
    with tempfile.TemporaryDirectory(prefix="s2a-texidentity-withdraw-") as tmp:
        for i, (name, old, new) in enumerate(MUTATIONS):
            if old not in full_source:
                print(f"MISSING ANCHOR for mutation {name}")
                failures += 1
                continue
            try:
                result = build_and_run(full_source.replace(old, new, 1), Path(tmp) / f"m{i}.c")
            except subprocess.CalledProcessError:
                print(f"withdraw {name}: MUTANT DID NOT COMPILE (not evidence of coverage)")
                failures += 1
                continue
            if result.returncode == 0:
                print(f"MUTANT SURVIVED: {name}（合同没有鉴别力）")
                print(result.stdout)
                failures += 1
            else:
                print(f"withdraw {name}: expected red ok (rc={result.returncode})")
    if failures:
        print(f"红：撤回对照有 {failures} 项未按预期转红")
    else:
        print(f"PASS: {len(MUTATIONS)} behaviour-withdrawal mutations all turned the contract red")
    raise SystemExit(1 if failures else 0)

with tempfile.TemporaryDirectory(prefix="s2a-texidentity-") as tmp:
    path = Path(args.keep) if args.keep else Path(tmp) / "test.c"
    result = build_and_run(full_source, path)
    print(result.stdout.strip())
    if result.stderr.strip():
        print(result.stderr.strip(), file=__import__("sys").stderr)
    raise SystemExit(result.returncode)
