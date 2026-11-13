// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 多程序合集切程序时直连图形层换着色器库（nvn_be_reload_direct_library，11-06 索尼克×夏特 世代重启：ExecuteProgram(1) 切到同包第 2 支程序，
//   它的着色器在 <游戏数据>/programs/1/shaders/direct；映射表 / 库容器原先整个进程只读一次，切过去还用第 1 支的）。
// 期望按构造写死：目录 A 的映射表只有键 aaaa…（顶点），没有库容器；目录 B 的映射表只有键 bbbb…（片元），有一份 0 条记录的合法库容器（本链号）
//   ① 起局按 A：认 aaaa、不认 bbbb，库容器 = 无（一键一文件）
//   ② DM_NVN_SHMAP / DM_MSL_DIR 改到 B、调 nvn_be_reload_direct_library → 回 1；认 bbbb、不认 aaaa，库容器开在 B 的 b-<链号>
//   ③ 路径没变再调 → 回 0，什么都不动（仍认 bbbb）
//   ④ 目录里没有映射表（#786）→ 当空表：回 1、不中止，aaaa / bbbb 都不认
// 反证：不重读（直接回 0）→ ② 仍认 aaaa、不认 bbbb、库容器仍是无（红）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static void put_file(NSString *path, NSData *d) { REQUIRE([NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]); REQUIRE([d writeToFile:path atomically:NO]); }
static void put_text(NSString *path, NSString *t) { put_file(path, [t dataUsingEncoding:NSUTF8StringEncoding]); }
static void use_dir(NSString *d) { setenv("DM_MSL_DIR", d.UTF8String, 1); setenv("DM_NVN_SHMAP", [d stringByAppendingPathComponent:@"shader_map.tsv"].UTF8String, 1); }

int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_nvn_program_switch.%d", getpid()]];
        NSString *a = [root stringByAppendingPathComponent:@"a/shaders/direct"], *b = [root stringByAppendingPathComponent:@"a/programs/1/shaders/direct"];
        NSString *ka = @"aaaaaaaaaaaaaaaa", *kb = @"bbbbbbbbbbbbbbbb", *lib_b = [b stringByAppendingPathComponent:@"b-" DMSH_CHAIN];
        // shader_map.tsv：第 3 列阶段名、第 4 列键（shmap_load_once 读 c[2] / c[3]）
        put_text([a stringByAppendingPathComponent:@"shader_map.tsv"], [NSString stringWithFormat:@"x\tx\tvertex\t%@\n", ka]);
        put_text([b stringByAppendingPathComponent:@"shader_map.tsv"], [NSString stringWithFormat:@"x\tx\tfragment\t%@\n", kb]);
        REQUIRE([NSFileManager.defaultManager createDirectoryAtPath:[a stringByAppendingPathComponent:@"b-" DMSH_CHAIN] withIntermediateDirectories:YES attributes:nil error:nil]);
        // 0 条记录的库容器：头 48 字节（魔数、版本 1、n 0、nshard 0、链号 12 字节），没有分片表和记录（lib_pack.inc lp_open）
        uint8_t h[48] = {0}; memcpy(h, "S2ALIB\0\0", 8); uint32_t one = 1; memcpy(h + 8, &one, 4); memcpy(h + 24, DMSH_CHAIN, strlen(DMSH_CHAIN) < 12 ? strlen(DMSH_CHAIN) : 12);
        put_file([lib_b stringByAppendingPathComponent:@"lib.idx"], [NSData dataWithBytes:h length:sizeof h]);
        setenv("DM_PSO_MANIFEST", "off", 1);   // 预热清单不在本单测范围

        use_dir(a);
        CHECK(mtl_shmap_known(ka.UTF8String) && !mtl_shmap_known(kb.UTF8String), "① 起局按 A：认 %s、不认 %s", ka.UTF8String, kb.UTF8String);
        CHECK(lp_pack_get() == NULL && g_libpack_ok == 0, "① A 没有库容器 → 一键一文件（g_libpack_ok %d）", g_libpack_ok);

        use_dir(b);
        int r = nvn_be_reload_direct_library();
        CHECK(r == 1, "② 换到 B → 回 1（实得 %d）", r);
        CHECK(mtl_shmap_known(kb.UTF8String) && !mtl_shmap_known(ka.UTF8String), "② 换到 B 后：认 %s、不认 %s", kb.UTF8String, ka.UTF8String);
        lp_pack *lp = lp_pack_get();
        CHECK(lp && !strcmp(lp->dir, lib_b.fileSystemRepresentation), "② 库容器开在 B 的 b-<链号>（实得 %s）", lp ? lp->dir : "无");

        r = nvn_be_reload_direct_library();
        CHECK(r == 0 && mtl_shmap_known(kb.UTF8String), "③ 路径没变再调 → 回 0、仍认 B（实得 %d）", r);

        // ④ #786：换到没有映射表的目录（出包判成 OpenGL 款、没出 NVN 库的包）→ 照常回 1、进程不退，A / B 的键都不认（全部交设备上首遇现编）；改前 MDIE 中止整个进程
        NSString *c = [root stringByAppendingPathComponent:@"c/shaders/direct"];
        REQUIRE([NSFileManager.defaultManager createDirectoryAtPath:c withIntermediateDirectories:YES attributes:nil error:nil]);
        use_dir(c);
        r = nvn_be_reload_direct_library();
        CHECK(r == 1 && !mtl_shmap_known(ka.UTF8String) && !mtl_shmap_known(kb.UTF8String), "④ 换到没有映射表的目录 → 回 1、不中止，A / B 的键都不认（实得 %d）", r);
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    }
    printf("%u checks, %u failures\n", checks, failures);
    if (failures) return 1;
    puts("✓ t_nvn_program_switch");
    return 0;
}
