// nn::ro 懒绑定交接（#858：游戏的 nn::ro 卸角色 NRO 时 RevertReference 把主程序指向它的函数槽改回模块对象 +0xc8 记的懒绑定入口；
//   宿主替 rtld 装模块时没填这个入口与 GOT[1] / GOT[2]，槽被改成 0，重装后一调就 pc 0）。
// 夹具 runtime/tests/ro_lazy/prepare.py：合成模块按 SDK 的 nn::ro 布局，期望全由夹具布局算出（layout.tsv），不读实现：
//   ① 模块对象 +0xc8 = 基址 + PLT 表头（JUMP_SLOT 槽的链接时原值 + 基址，同 SDK RoModule::Relocation）
//   ② GOT[1] = 模块对象、GOT[2] = 基址 + nn::ro::BindEntry（同 SDK RoModule::Relocation 末尾）
//   ③ 急绑定照旧：JUMP_SLOT 槽 = 基址 + target；模块对象进了自动装载表（g_pAutoLoadList 的环里）
// 旧实现：①② 都是 0（Initialize 把 +0xc8 清零后没人填，GOT 不动）。
#include "../src/native.h"
#include <string.h>

static int bad;
#define CHECK(c, ...) do { if (!(c)) { bad++; printf("✗ "); printf(__VA_ARGS__); putchar('\n'); } } while (0)
static uint64_t layout(const char *dir, const char *key) {
    char p[1100], k[32]; unsigned long long v; snprintf(p, sizeof p, "%s/layout.tsv", dir); FILE *f = fopen(p, "r");
    if (!f) { printf("✗ 读不到 %s\n", p); exit(2); }
    while (fscanf(f, "%31s %llx", k, &v) == 2) if (!strcmp(k, key)) { fclose(f); return v; }
    printf("✗ layout.tsv 没有 %s\n", key); exit(2);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    unsetenv("S2A_FPS60"); unsetenv("S2A_CPATCH_ON");
    const char *names[] = {"main"}; load_modules(argv[1], names, 1);
    CHECK(g_nmod == 1, "装 main 后模块数 %d，期望 1", g_nmod);
    uint8_t *base = g_mod[0].base;
    uint64_t *obj = (uint64_t *)(base + layout(argv[1], "obj")), *got = (uint64_t *)(base + layout(argv[1], "got"));
    uint64_t plt0 = (uint64_t)base + layout(argv[1], "plt0"), bind = (uint64_t)base + layout(argv[1], "bind");
    uint64_t slot = *(uint64_t *)(base + layout(argv[1], "slot")), target = (uint64_t)base + layout(argv[1], "target");
    uint64_t stub = layout(argv[1], "stub");   // 懒绑定入口字段：新 SDK +0xc8（RestoreFunctions）、老 SDK +0xb0（RestoreFunction，夹具 old 形态）
    CHECK(obj[stub / 8] == plt0, "① 模块对象 +%#llx = %#llx，期望基址 + PLT 表头 %#llx", (unsigned long long)stub, (unsigned long long)obj[stub / 8], (unsigned long long)plt0);
    CHECK(got[1] == (uint64_t)obj, "② GOT[1] = %#llx，期望模块对象 %p", (unsigned long long)got[1], (void *)obj);
    CHECK(got[2] == bind, "② GOT[2] = %#llx，期望基址 + BindEntry %#llx", (unsigned long long)got[2], (unsigned long long)bind);
    CHECK(slot == target, "③ JUMP_SLOT 槽 = %#llx，期望急绑定到 target %#llx", (unsigned long long)slot, (unsigned long long)target);
    uint64_t *head = (uint64_t *)*(uint64_t *)module_sym(&g_mod[0], "_ZN2nn2ro6detail15g_pAutoLoadListE");
    CHECK(head && head[1] == (uint64_t)obj, "③ 自动装载表头的后继 = %#llx，期望模块对象 %p", head ? (unsigned long long)head[1] : 0ULL, (void *)obj);
    if (bad) { printf("✗ t_ro_lazy：%d 处不符\n", bad); return 1; }
    printf("✓ t_ro_lazy：模块对象 +懒绑定入口字段 = PLT 表头、GOT[1] / GOT[2] = 模块对象 / BindEntry、急绑定与自动装载表不变\n");
    return 0;
}
