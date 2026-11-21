// 宿主回归：s2a_spv_workgroup_bytes 的标量词数核验（spirv_workgroup.h）。
// 反例基线：OpTypeFloat 是 3 词（OpTypeInt 才是 4 词）——合一按 len!=4 验会把
//   float 共享数组当畸形，装载闸随 #1850/#1865 覆盖面放大后对这类模块假拒。
// 覆盖：float 数组正样、int 数组对照、位宽非整字节负控、无 Workgroup 变量零计数。
#include "../native/direct/spirv_workgroup.h"
#include <stdio.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "assertion line %d: %s\n", __LINE__, #x); exit(2); } } while (0)
#define W32(op, len) ((((len) & 0xffffu) << 16) | ((op) & 0xffffu))
#define MAGIC 0x07230203u

// 排一段 Workgroup 变量模块：scalar(width) → array[len] → ptr → var。
static size_t emit_shared_fw(uint32_t *w, uint32_t scalar_op, uint32_t width, uint32_t n, uint32_t float_words) {
    w[0] = MAGIC; w[1] = 0x10000u; w[2] = 0; w[3] = 16; w[4] = 0;
    uint32_t *p = w + 5;
    if (scalar_op == SpvOpTypeInt) { p[0] = W32(SpvOpTypeInt, 4); p[1] = 1; p[2] = width; p[3] = 0; p += 4; }
    else { p[0] = W32(SpvOpTypeFloat, float_words); p[1] = 1; p[2] = width; for (uint32_t k = 3; k < float_words; k++) p[k] = 0; p += float_words; }   // 1.6 起可带浮点编码操作数（第 4 字）
    p[0] = W32(SpvOpTypeInt, 4); p[1] = 2; p[2] = 32; p[3] = 0; p += 4;
    p[0] = W32(SpvOpConstant, 4); p[1] = 2; p[2] = 3; p[3] = n; p += 4;
    p[0] = W32(SpvOpTypeArray, 4); p[1] = 4; p[2] = 1; p[3] = 3; p += 4;
    p[0] = W32(SpvOpTypePointer, 4); p[1] = 5; p[2] = SpvStorageClassWorkgroup; p[3] = 4; p += 4;
    p[0] = W32(SpvOpVariable, 4); p[1] = 5; p[2] = 6; p[3] = SpvStorageClassWorkgroup; p += 4;
    return (size_t)(p - w) * 4;
}

static size_t emit_shared(uint32_t *w, uint32_t scalar_op, uint32_t width, uint32_t n) { return emit_shared_fw(w, scalar_op, width, n, 3); }

int main(void) {
    uint32_t w[64]; uint64_t total = 0;
    // float[8] 共享数组 = 32 字节：OpTypeFloat 3 词不能被误当畸形
    size_t nb = emit_shared(w, SpvOpTypeFloat, 32, 8);
    CHECK(s2a_spv_workgroup_bytes(w, nb, &total) == NULL && total == 32);
    // int[11264] = 45056 字节（12588501 病灶形）：OpTypeInt 4 词照常
    nb = emit_shared(w, SpvOpTypeInt, 32, 11264);
    CHECK(s2a_spv_workgroup_bytes(w, nb, &total) == NULL && total == 45056);
    // SPIR-V 1.6：OpTypeFloat 带可选浮点编码操作数 = 4 字，float[8] 仍是 32 字节；5 字是畸形
    nb = emit_shared_fw(w, SpvOpTypeFloat, 32, 8, 4);
    CHECK(s2a_spv_workgroup_bytes(w, nb, &total) == NULL && total == 32);
    nb = emit_shared_fw(w, SpvOpTypeFloat, 32, 8, 5);
    CHECK(s2a_spv_workgroup_bytes(w, nb, &total) != NULL);
    // 位宽非整字节仍具名失败（12 位浮点）
    nb = emit_shared(w, SpvOpTypeFloat, 12, 4);
    CHECK(s2a_spv_workgroup_bytes(w, nb, &total) != NULL);
    // 无 Workgroup 变量 → 0 且通过
    w[0] = MAGIC; w[1] = 0x10000u; w[2] = 0; w[3] = 16; w[4] = 0;
    CHECK(s2a_spv_workgroup_bytes(w, 20, &total) == NULL && total == 0);
    printf("t_spv_workgroup_bytes: all cases pass\n");
    return 0;
}
