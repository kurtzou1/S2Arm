// 单处绘制兜底（10-26 维护者：不再整局切通用）：直接包含生产 nvn_mtl.m。期望按规则手写，不由被测实现推出：
//   ① GPU 报错隔离：提交前新建的程序对是嫌疑；非无辜受害的报错 → 嫌疑全部隔离、quar_has 命中、写进 gpu_quarantine.tsv；新进程读文件同样命中（以后的局也跳过）
//      嫌疑超过 QUAR_MAX（16）对 → 一个也不隔离；隔离之后新建的不受影响
//   ② 编译服务失败（XPC 连接中断 / 超时）判为暂时性，管线本身的错（线程组内存超限）不算
//   ③ GPU 内存用满（错误码 8 / 描述 OutOfMemory）不隔离；④ 旧版（没有版本头）的隔离文件读时作废重学
//   ⑤ GPU 挂死 / 超时且出事前约 10 秒本进程大量写盘（≥ 1 GB）或缺页读入（≥ 10000 次）→ 不隔离（D-9R4S：3 GB / 10 s 写回下挂死，5 对无辜绘制被记住）；
//      挂死但没在写回、或不是挂死的错误、或没有 ≥ 1 秒前的基准 → 照旧隔离。⑥ v2 文件（写回挂死也记过）读时作废重学
//   反证：改前的 nvn_mtl.m 没有 quar_* / pso_err_transient，本单测编不过；去掉 quar_blameless 那行 → ③ 红；去掉版本头判断 → ④ 红；去掉挂死写回豁免 → ⑤a/⑤d/⑤f 红
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/wait.h>

static unsigned failures, checks;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static NvShader *sh(const char *key) { NvShader *s = [NvShader new]; strlcpy(s->key, key, sizeof s->key); return s; }
// ⑤ 写盘 / 缺页读入的替身（生产是 runtime/src/energy.c，这里按用例给累计值）
static uint64_t t_w, t_p;
static int fake_disk_io(uint64_t *rd, uint64_t *wr, uint64_t *pageins) { *rd = 0; *wr = t_w; *pageins = t_p; return 0; }
// 一个用例：基准样本 ago 秒前（写 w0 / 缺页 p0），出事时累计到 w1 / p1；新建一对、按 err 报错，回「那一对被隔离没有」
static int case5(const char *k, double ago, uint64_t w0, uint64_t p0, uint64_t w1, uint64_t p1, NSError *err) {
    g_quar_disk_io = fake_disk_io;
    char vk[24], fk[24]; snprintf(vk, sizeof vk, "%.15s5_b", k); snprintf(fk, sizeof fk, "%.15s6_b", k);
    NvShader *v = sh(vk), *f = sh(fk); quar_built(v, f); NSArray *s = quar_take();
    g_qio_n = 0; if (ago > 0) quar_io_note(now_ns() - (uint64_t)(ago * 1e9), w0, p0);
    t_w = w1; t_p = p1; quar_fault(s, err); return quar_has(v, f);
}

int main(void) {
    @autoreleasepool {
        char dir[] = "/tmp/t_drawfb_XXXXXX"; if (!mkdtemp(dir)) return 2;
        char user[300]; snprintf(user, sizeof user, "%s/pso_user.tsv", dir); setenv("DM_PSO_USER", user, 1);
        NvShader *va = sh("aaaaaaaaaaaaaaaa_b"), *fa = sh("bbbbbbbbbbbbbbbb_b"), *vb = sh("cccccccccccccccc_b"), *fb = sh("dddddddddddddddd_b");
        quar_built(va, fa); NSArray *sus = quar_take();
        VERIFY(sus.count == 1 && !quar_has(va, fa), "① 提交前新建 1 对，报错前不隔离");
        quar_fault(sus, [NSError errorWithDomain:@"t" code:1 userInfo:nil]);
        VERIFY(quar_has(va, fa) && !quar_has(vb, fb), "① 报错后那一对隔离、别的不受影响");
        quar_built(vb, fb); VERIFY(quar_take().count == 1 && !quar_has(vb, fb), "① 隔离之后新建的不受影响，下一个提交照常收嫌疑");
        NSMutableArray *many = [NSMutableArray array]; for (int i = 0; i < 17; i++) [many addObject:[NSString stringWithFormat:@"%016x_b\t%016x_b", i, i]];
        quar_fault(many, nil);
        VERIFY(![g_quar containsObject:many[0]], "① 嫌疑 17 对（> 16）：一个也不隔离");
        NSString *f = [NSString stringWithContentsOfFile:[@(dir) stringByAppendingPathComponent:@"gpu_quarantine.tsv"] encoding:NSUTF8StringEncoding error:nil];
        VERIFY([f isEqualToString:@QUAR_HEAD "\naaaaaaaaaaaaaaaa\tbbbbbbbbbbbbbbbb\n"], "① 写进 gpu_quarantine.tsv（版本头 + 那一对，实得「%s」）", f.UTF8String);
        pid_t c = fork();
        if (c == 0) { g_quar = nil; g_quar_n = 0; _exit(quar_has(va, fa) && !quar_has(vb, fb) ? 0 : 1); }
        int st = 0; waitpid(c, &st, 0);
        VERIFY(WIFEXITED(st) && !WEXITSTATUS(st), "① 新进程读文件：那一对一开局就跳过");
        // ③ GPU 内存用满不怪程序（#327 空之轨迹：显存满那次提交新建的程序对被隔离、以后每局开局就跳过 → 一进游戏就黑、开头 logo 残缺）：
        //   Metal 3 错误码 8 / Metal 4 描述里的 OutOfMemory → 不隔离；④ 旧版文件（没有版本头）→ 读的时候整份作废、隔离表空、文件删掉
        { NvShader *vc = sh("eeeeeeeeeeeeeeee_b"), *fc = sh("ffffffffffffffff_b"); quar_built(vc, fc); NSArray *s3 = quar_take();
          quar_fault(s3, [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorOutOfMemory userInfo:nil]);
          VERIFY(!quar_has(vc, fc), "③ Metal 3 显存不足（错误码 8）：不隔离");
          quar_fault(s3, [NSError errorWithDomain:@"MTL4CommandQueueErrorDomain" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)"}]);
          VERIFY(!quar_has(vc, fc), "③ Metal 4 显存不足（描述里 OutOfMemory）：不隔离"); }
        { NSString *qp = [@(dir) stringByAppendingPathComponent:@"gpu_quarantine.tsv"];
          [@"1111111111111111\t2222222222222222\n" writeToFile:qp atomically:YES encoding:NSUTF8StringEncoding error:nil];
          pid_t c4 = fork();
          if (c4 == 0) { g_quar = nil; g_quar_n = 0; NvShader *v1 = sh("1111111111111111_b"), *f1 = sh("2222222222222222_b");
              int hit = quar_has(v1, f1); _exit(!hit && g_quar_n == 0 && ![NSFileManager.defaultManager fileExistsAtPath:qp] ? 0 : 1); }
          int s4 = 0; waitpid(c4, &s4, 0);
          VERIFY(WIFEXITED(s4) && !WEXITSTATUS(s4), "④ 旧版隔离文件（没有版本头）：作废重学、开局不跳过、文件删掉"); }
        {   // ⑤ 挂死 + 写回 / 分页：期望按 D-9R4S 读数与门槛手写（1 GB = 1024 MB / 10 s；缺页 10000 次 / 10 s；窗口比 10 秒长按 10 秒折算）
            NSError *hang = [NSError errorWithDomain:@"MTL4CommandQueueErrorDomain" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Caused GPU Hang Error (00000003:kIOGPUCommandBufferCallbackErrorHang)"}];
            NSError *other = [NSError errorWithDomain:@"MTL4CommandQueueErrorDomain" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid Resource (00000009:kIOGPUCommandBufferCallbackErrorInvalidResource)"}];
            NSError *to3 = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorTimeout userInfo:nil];
            uint64_t MB = 1u << 20;
            VERIFY(!case5("aaaa", 11, 100 * MB, 0, 3100 * MB, 0, hang), "⑤a 挂死、前 11 秒写 3000 MB（折 10 秒约 2727 MB ≥ 1024）：不隔离");
            VERIFY(case5("bbbb", 11, 100 * MB, 0, 110 * MB, 0, hang), "⑤b 挂死、前 11 秒只写 10 MB、无缺页：照旧隔离（程序自己挂的）");
            VERIFY(case5("cccc", 11, 100 * MB, 0, 3100 * MB, 0, other), "⑤c 不是挂死（无效资源）、写回再大：照旧隔离");
            VERIFY(!case5("dddd", 11, 0, 1000, 0, 31000, hang), "⑤d 挂死、前 11 秒缺页读入 30000 次（折约 27273 ≥ 10000）：不隔离");
            VERIFY(case5("eeee", 0.5, 100 * MB, 0, 3100 * MB, 0, hang), "⑤e 挂死、基准不到 1 秒：判不了，照旧隔离");
            VERIFY(!case5("ffff", 11, 100 * MB, 0, 3100 * MB, 0, to3), "⑤f Metal 3 超时（MTLCommandBufferErrorTimeout）+ 写 3000 MB：不隔离");
            VERIFY(case5("gggg", 30, 0, 0, 2000 * MB, 0, hang), "⑤g 挂死、基准 30 秒前、写 2000 MB（折 10 秒约 667 MB < 1024）：照旧隔离（旧样本不夸大）");
            t_w = t_p = 0;
        }
        {   // ⑥ v2 文件（写回挂死也记过，分不清）：读时作废重学
            NSString *qp = [@(dir) stringByAppendingPathComponent:@"gpu_quarantine.tsv"];
            [@"# gpu_quarantine v2: program pairs whose first commit faulted (not GPU memory exhaustion)\n3333333333333333\t4444444444444444\n" writeToFile:qp atomically:YES encoding:NSUTF8StringEncoding error:nil];
            pid_t c6 = fork();
            if (c6 == 0) { g_quar = nil; g_quar_n = 0; int hit = quar_has(sh("3333333333333333_b"), sh("4444444444444444_b"));
                _exit(!hit && g_quar_n == 0 && ![NSFileManager.defaultManager fileExistsAtPath:qp] ? 0 : 1); }
            int s6 = 0; waitpid(c6, &s6, 0);
            VERIFY(WIFEXITED(s6) && !WEXITSTATUS(s6), "⑥ v2 隔离文件：作废重学、开局不跳过、文件删掉");
        }
        NSError *(^E)(NSString *) = ^(NSString *d) { return [NSError errorWithDomain:@"t" code:1 userInfo:@{NSLocalizedDescriptionKey: d}]; };
        VERIFY(pso_err_transient(E(@"Compilation failed due to an interrupted connection: XPC_ERROR_CONNECTION_INTERRUPTED. This error occurred after multiple retries.")), "② 巫师3 那条（XPC 连接中断）判暂时性");
        VERIFY(!pso_err_transient(E(@"Threadgroup memory size (36880) exceeds the maximum threadgroup memory allowed (32768)")) && !pso_err_transient(nil), "② 管线本身的错 / 无错误不算暂时性");
        char cmd[400]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir); system(cmd);
    }
    if (failures) { printf("✗ t_nvn_draw_fallback：%u / %u 项不过\n", failures, checks); return 1; }
    printf("✓ t_nvn_draw_fallback：%u 项全过（GPU 报错隔离与记住、编译服务失败判暂时性）\n", checks);
    return 0;
}
