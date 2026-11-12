// 管线归档批量写回（pso_archive.h par_write_batch，11-06 马车8 卡预热：一条一个文件写回 ~95 ms/条，一局写不完、退出即丢、每次启动从零编）。
//   直接包含生产 nvn_mtl.m，在真 Metal 设备上编 70 条不同的计算管线（先编一遍 = 预热），一次放进待写队列再同步跑写回。期望（按 PAR_BATCH=32 手算）：
//   ① 写出 3 个批文件（32 + 32 + 6）、batches.tsv 70 行、每行指向在的文件；② 70 个键都能经 par_archive_for 取到归档，只准命中归档地建管线（FailOnBinaryArchiveMiss）70/70 成；
//   ③ 写成计数 +70、写失败 0。反证（构建规则另编 -DPAR_BATCH=1）：批文件 70 个，① 不符
#include "../gfx/nvn/nvn_mtl.m"
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
int main(void) { @autoreleasepool {
    g_dev = MTLCreateSystemDefaultDevice(); REQUIRE(g_dev);
    char tmpl[] = "/tmp/t_pso_batch.XXXXXX"; REQUIRE(mkdtemp(tmpl));
    g_par_dir = @(tmpl); g_par_have = [NSMutableSet set]; g_par_open = [NSMutableDictionary dictionary]; g_par_bmap = [NSMutableDictionary dictionary]; g_par_on = 1;
    enum { N = 70 }; NSMutableArray *descs = [NSMutableArray array], *keys = [NSMutableArray array];
    for (int i = 0; i < N; i++) {
        NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void k(device float *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] = b[i] * %d.0 + %d.0; }", i + 2, i];
        NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:src options:nil error:&e]; REQUIRE(lib);
        MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new]; d.computeFunction = [lib newFunctionWithName:@"k"];
        REQUIRE([g_dev newComputePipelineStateWithDescriptor:d options:0 reflection:nil error:&e]);   // 预热先编一遍
        [descs addObject:d]; [keys addObject:[NSString stringWithFormat:@"t-batch-%02d", i]];
    }
    uint64_t w0 = atomic_load(&g_par_written), f0 = atomic_load(&g_par_write_failed);
    pthread_mutex_lock(&g_par_mu); g_par_todo = [NSMutableArray array]; for (int i = 0; i < N; i++) [g_par_todo addObject:@[keys[i], descs[i]]]; g_par_writer = 1; pthread_mutex_unlock(&g_par_mu);
    par_writer();
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:g_par_dir error:nil];
    NSUInteger files = [names filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'batch-' AND SELF ENDSWITH '.metalarchive'"]].count;
    NSString *idx = [NSString stringWithContentsOfFile:[g_par_dir stringByAppendingPathComponent:@"batches.tsv"] encoding:NSUTF8StringEncoding error:nil];
    NSUInteger lines = 0, dangling = 0;
    for (NSString *ln in [idx componentsSeparatedByString:@"\n"]) { NSArray *c = [ln componentsSeparatedByString:@"\t"]; if (c.count != 2) continue; lines++;
        if (![NSFileManager.defaultManager fileExistsAtPath:[g_par_dir stringByAppendingPathComponent:c[1]]]) dangling++; }
    VERIFY(files == 3 && lines == N && dangling == 0, "① 批文件 %lu 个（期望 3）、索引 %lu 行（期望 70）、指向不存在文件 %lu 行（期望 0）", (unsigned long)files, (unsigned long)lines, (unsigned long)dangling);
    int got = 0;
    for (int i = 0; i < N; i++) { id<MTLBinaryArchive> a = par_archive_for(keys[i]); if (!a) continue;
        MTLComputePipelineDescriptor *d = [descs[i] copy]; d.binaryArchives = @[a]; NSError *e = nil;
        if ([g_dev newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&e]) got++; }
    VERIFY(got == N, "② 只准命中归档地建管线 %d/%d", got, N);
    VERIFY(atomic_load(&g_par_written) - w0 == N && atomic_load(&g_par_write_failed) == f0, "③ 写成 +%llu（期望 70）、写失败 +%llu（期望 0）",
           (unsigned long long)(atomic_load(&g_par_written) - w0), (unsigned long long)(atomic_load(&g_par_write_failed) - f0));
    // #756：写归档前留 .writing、写完删掉；进程死在写里则留下，下次起局判「不再写」
    NSString *wflag = [g_par_dir stringByAppendingPathComponent:PAR_WRITING];
    VERIFY(![NSFileManager.defaultManager fileExistsAtPath:wflag], "④ 写完不留 .writing 标记");
    REQUIRE([@"batch-x" writeToFile:wflag atomically:NO encoding:NSUTF8StringEncoding error:nil]);   // 模拟上次死在写里
    par_check_dead_write();
    VERIFY(g_par_nowrite == 1, "⑤ 起局见到 .writing → 这个系统版本不再写");
    pthread_mutex_lock(&g_par_mu); NSUInteger before = g_par_todo.count; pthread_mutex_unlock(&g_par_mu);
    par_note(@"t-after-dead-write", descs[0]);
    pthread_mutex_lock(&g_par_mu); NSUInteger after = g_par_todo.count; pthread_mutex_unlock(&g_par_mu);
    VERIFY(after == before, "⑥ 不再写时 par_note 不进待写队列（%lu → %lu）", (unsigned long)before, (unsigned long)after);
    [NSFileManager.defaultManager removeItemAtPath:g_par_dir error:nil];
    if (failures) { printf("✗ t_nvn_pso_batch：%u 项里 %u 项不符\n", checks, failures); return 1; }
    printf("✓ t_nvn_pso_batch：%u 项全过（70 条管线写成 3 个批文件，按键全部取回；死在写里的标记生效）\n", checks); return 0;
} }
