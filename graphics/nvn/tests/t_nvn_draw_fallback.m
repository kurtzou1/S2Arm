// 单处绘制兜底（10-26 维护者：不再整局切通用）：直接包含生产 nvn_mtl.m。期望按规则手写，不由被测实现推出：
//   ① GPU 报错隔离：提交前新建的程序对是嫌疑；非无辜受害的报错 → 嫌疑全部隔离、quar_has 命中、写进 gpu_quarantine.tsv；新进程读文件同样命中（以后的局也跳过）
//      嫌疑超过 QUAR_MAX（16）对 → 一个也不隔离；隔离之后新建的不受影响
//   ② 编译服务失败（XPC 连接中断 / 超时）判为暂时性，管线本身的错（线程组内存超限）不算
//   ③ GPU 内存用满（错误码 8 / 描述 OutOfMemory）不隔离；④ 旧版（没有版本头）的隔离文件读时作废重学
//   反证：改前的 nvn_mtl.m 没有 quar_* / pso_err_transient，本单测编不过；去掉 quar_blameless 那行 → ③ 红；去掉版本头判断 → ④ 红
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/wait.h>

static unsigned failures, checks;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static NvShader *sh(const char *key) { NvShader *s = [NvShader new]; strlcpy(s->key, key, sizeof s->key); return s; }

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
        NSError *(^E)(NSString *) = ^(NSString *d) { return [NSError errorWithDomain:@"t" code:1 userInfo:@{NSLocalizedDescriptionKey: d}]; };
        VERIFY(pso_err_transient(E(@"Compilation failed due to an interrupted connection: XPC_ERROR_CONNECTION_INTERRUPTED. This error occurred after multiple retries.")), "② 巫师3 那条（XPC 连接中断）判暂时性");
        VERIFY(!pso_err_transient(E(@"Threadgroup memory size (36880) exceeds the maximum threadgroup memory allowed (32768)")) && !pso_err_transient(nil), "② 管线本身的错 / 无错误不算暂时性");
        char cmd[400]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir); system(cmd);
    }
    if (failures) { printf("✗ t_nvn_draw_fallback：%u / %u 项不过\n", failures, checks); return 1; }
    printf("✓ t_nvn_draw_fallback：%u 项全过（GPU 报错隔离与记住、编译服务失败判暂时性）\n", checks);
    return 0;
}
