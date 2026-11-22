// 直连库打包容器读法（graphics/nvn/lib_pack.inc）单测：按格式手造一个两分片的小容器（期望值全由本测试写进去的字节决定，不跑被测实现），
//   验：取过的分片不留文件映射、取库并取到入口、json 逐字节相等、没有的种类返回空、链版本不符判格式错、分片大小不符报红返回空、没有 lib.idx 返回 0。
//   两个真 metallib 由 Makefile 用 xcrun metal 编（tests/t_lib_pack_a.metal / _b.metal），路径从参数传进来
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
// 本进程有几块虚拟内存映射着 <dir> 下的 .pak 文件（按区域的文件路径认）。
//   路径用 PROC_PIDREGIONPATHINFO 取这一区自己的：proc_regionfilename 对匿名区（如 Metal 建库时的 malloc 块）回的是其后第一块文件映射的路径，
//   会把紧挨在 .pak 映射前面的匿名区算进来（11-02 守望红：64 MB 的 malloc 区记到 1 MB 的分片名下）
static uint64_t g_pak_bytes;   // pak_maps 顺带记 .pak 映射的总字节
static int pak_maps(const char *dir) {
    int n = 0; mach_vm_address_t a = 0; g_pak_bytes = 0; mach_vm_size_t sz; vm_region_basic_info_data_64_t info; mach_msg_type_number_t c; mach_port_t obj; struct proc_regionwithpathinfo ri;
    for (;; a += sz) { c = VM_REGION_BASIC_INFO_COUNT_64;
        if (mach_vm_region(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &c, &obj) != KERN_SUCCESS) break;
        if (proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, a, &ri, sizeof ri) == (int)sizeof ri && ri.prp_prinfo.pri_address == a
            && strstr(ri.prp_vip.vip_path, dir) && strstr(ri.prp_vip.vip_path, ".pak")) { n++; g_pak_bytes += sz; } }
    return n;
}
// [lo, hi) 里映射着 <dir> 下 .pak 的字节（同 pak_maps 的认法）
static uint64_t pak_bytes_in(const char *dir, uint64_t lo, uint64_t hi) {
    uint64_t b = 0; mach_vm_address_t a = lo; mach_vm_size_t sz; vm_region_basic_info_data_64_t info; mach_msg_type_number_t c; mach_port_t obj; struct proc_regionwithpathinfo ri;
    for (;; a += sz) { c = VM_REGION_BASIC_INFO_COUNT_64;
        if (mach_vm_region(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &c, &obj) != KERN_SUCCESS || a >= hi) break;
        if (proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, a, &ri, sizeof ri) == (int)sizeof ri && ri.prp_prinfo.pri_address == a
            && strstr(ri.prp_vip.vip_path, dir) && strstr(ri.prp_vip.vip_path, ".pak")) b += sz; }
    return b;
}
static int g_red;
#define LP_LOG(...) do { char b_[512]; snprintf(b_, sizeof b_, __VA_ARGS__); if (strstr(b_, "【红】")) g_red++; printf("    日志：%s\n", b_); } while (0)
// 宿主高位区由测试注入（生产里是 runtime/src/vawin.c s2a_host_hi_range）：缺省 -1 = 没链原生层，照旧 mmap(NULL)，前面各项按原样跑
static int g_hr_rc = -1; static uint64_t g_hr_lo, g_hr_hi;
#define LP_HI_RANGE(lo, hi) (*(lo) = g_hr_lo, *(hi) = g_hr_hi, g_hr_rc)
#include "../lib_pack.inc"
#include <zlib.h>   // 客体输入用例：块用 zlib 库压（读端用 Foundation 解，两种实现对拍）
static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("✗ " __VA_ARGS__); printf("\n"); } else { printf("✓ " __VA_ARGS__); printf("\n"); } } while (0)
static NSData *rd(const char *p) { NSData *d = [NSData dataWithContentsOfFile:@(p)]; if (!d) { printf("读不到 %s\n", p); exit(2); } return d; }
typedef struct { uint64_t key; uint8_t kind, shard; uint32_t len; uint64_t off; } rec;
// 写容器：shard0 = segs 里 shard==0 的段依次（16 字节对齐），shard1 同理；ssize_bad >= 0 时把分片 1 在索引里的大小写错
static void write_pack(const char *dir, const char *chain, NSArray<NSData *> *segs, const uint8_t *shards, const uint64_t *keys, const uint8_t *kinds, int n, int ssize_bad) {
    NSMutableData *sh[2] = {[NSMutableData data], [NSMutableData data]}; rec r[8];
    for (int i = 0; i < n; i++) { NSMutableData *s = sh[shards[i]]; int j = 0;
        while (j < i && !(segs[j] == segs[i] && shards[j] == shards[i])) j++;   // 同一个 NSData 对象、同一分片：共用一段（批库：多个键指向同一个 metallib）
        if (j < i) { r[i] = r[j]; r[i].key = keys[i]; r[i].kind = kinds[i]; continue; }
        while (s.length % 16) [s appendBytes:"\0" length:1];
        r[i] = (rec){keys[i], kinds[i], shards[i], (uint32_t)segs[i].length, s.length}; [s appendData:segs[i]]; }
    for (int k = 0; k < 2; k++) [sh[k] writeToFile:[NSString stringWithFormat:@"%s/lib.%03d.pak", dir, k] atomically:YES];
    NSMutableData *ix = [NSMutableData data]; uint32_t ver = 1, nn = (uint32_t)n, ns = 2, z = 0; char ch[12] = {0}; memcpy(ch, chain, strlen(chain) < 12 ? strlen(chain) : 12);
    [ix appendBytes:"S2ALIB\0\0" length:8]; [ix appendBytes:&ver length:4]; [ix appendBytes:&nn length:4]; [ix appendBytes:&ns length:4]; [ix appendBytes:&z length:4]; [ix appendBytes:ch length:12]; [ix appendBytes:&z length:4]; [ix appendBytes:&z length:4]; [ix appendBytes:&z length:4];   // 头 48 字节：偏移 36–47 为 0（草案字段合计 44，另补 4 字节到 48，待着色器线确认）
    for (int k = 0; k < 2; k++) { uint64_t sz = sh[k].length + (k == 1 && ssize_bad >= 0 ? 7 : 0), zz = 0; [ix appendBytes:&sz length:8]; [ix appendBytes:&zz length:8]; }
    for (int i = 0; i < n; i++) { uint16_t z16 = 0; [ix appendBytes:&r[i].key length:8]; [ix appendBytes:&r[i].kind length:1]; [ix appendBytes:&r[i].shard length:1]; [ix appendBytes:&z16 length:2]; [ix appendBytes:&r[i].len length:4]; [ix appendBytes:&r[i].off length:8]; }
    [ix writeToFile:[NSString stringWithFormat:@"%s/lib.idx", dir] atomically:YES];
}
// 客体输入（种类 56，lp_guest_get）：块按格式手造（期望值 = 写进去的字节），用 zlib 库的 compress2 压（读端用 Foundation 解 + 自己核 Adler-32，两边不同实现）。
//   块 0（分片 0）：阶段 0，键 0x10（控制段 300 字节 + 代码 1000 字节）、0x20（40 + 7）；块 1（分片 1）：阶段 1，键 0x30（0x880 + 64）；
//   键 0x40 的记录指向块 0 的拷贝但 Adler-32 改坏；键 0x50 的记录指向块 1（块里没有 0x50）。期望：三键取回逐字节相等、阶段不符与没有的键返回 1 不报红、两处坏段返回 -1 各报一次红
static NSData *guest_seg(uint8_t st, int n, const uint64_t *keys, NSData *const *ctl, NSData *const *code, int bad_adler) {
    NSMutableData *raw = [NSMutableData data]; uint32_t nn = (uint32_t)n; uint8_t h4[4] = {st, 1, 0, 0};
    [raw appendBytes:&nn length:4]; [raw appendBytes:h4 length:4];
    uint32_t at = 8 + 24 * (uint32_t)n;
    for (int i = 0; i < n; i++) { uint32_t c = (uint32_t)ctl[i].length, d = (uint32_t)code[i].length, z = 0;
        [raw appendBytes:&keys[i] length:8]; [raw appendBytes:&at length:4]; [raw appendBytes:&c length:4]; [raw appendBytes:&d length:4]; [raw appendBytes:&z length:4]; at += c + d; }
    for (int i = 0; i < n; i++) { [raw appendData:ctl[i]]; [raw appendData:code[i]]; }
    uLongf zl = compressBound(raw.length); NSMutableData *seg = [NSMutableData dataWithLength:8 + zl];
    if (compress2((Bytef *)seg.mutableBytes + 8, &zl, raw.bytes, raw.length, 6) != Z_OK) { printf("compress2 失败\n"); exit(2); }
    seg.length = 8 + zl; uint32_t rl = (uint32_t)raw.length; memcpy(seg.mutableBytes, &rl, 4);
    if (bad_adler) ((uint8_t *)seg.mutableBytes)[seg.length - 1] ^= 0x5a;
    return seg;
}
static NSData *fill(size_t n, uint8_t seed) { NSMutableData *d = [NSMutableData dataWithLength:n]; uint8_t *b = d.mutableBytes; for (size_t i = 0; i < n; i++) b[i] = (uint8_t)(seed + i * 7); return d; }
static void guest_cases(void) {
    char dir[] = "/tmp/t_lib_guest.XXXXXX"; if (!mkdtemp(dir)) exit(2);
    NSData *c10 = fill(300, 1), *d10 = fill(1000, 2), *c20 = fill(40, 3), *d20 = fill(7, 4), *c30 = fill(0x880, 5), *d30 = fill(64, 6);
    uint64_t k0[2] = {0x10, 0x20}, k1[1] = {0x30};
    NSData *b0 = guest_seg(0, 2, k0, (NSData *[]){c10, c20}, (NSData *[]){d10, d20}, 0), *b1 = guest_seg(1, 1, k1, (NSData *[]){c30}, (NSData *[]){d30}, 0), *bb = guest_seg(0, 2, k0, (NSData *[]){c10, c20}, (NSData *[]){d10, d20}, 1);
    uint64_t keys[5] = {0x10, 0x20, 0x30, 0x40, 0x50}; uint8_t kinds[5] = {56, 56, 56, 56, 56}, shards[5] = {0, 0, 1, 0, 1};
    write_pack(dir, "abcdef012345", @[b0, b0, b1, bb, b1], shards, keys, kinds, 5, -1);   // 同一个 NSData 同分片 = 共用一段（同块的键指向同一段）
    lp_pack p; CHECK(lp_open(&p, dir, "abcdef012345") == 1 && p.n == 5, "客体输入：容器打开、5 条种类 56 记录");
    int red0 = g_red; uint8_t *buf; uint32_t nc, nk;
    int r = lp_guest_get(&p, 0x10, 0, &buf, &nc, &nk);
    CHECK(r == 0 && nc == 300 && nk == 1000 && !memcmp(buf, c10.bytes, 300) && !memcmp(buf + 300, d10.bytes, 1000), "客体输入：键 0x10（块 0 第 1 条）控制段 300 + 代码 1000 字节逐字节相等（rc %d、%u + %u）", r, nc, nk); free(buf);
    r = lp_guest_get(&p, 0x20, 0, &buf, &nc, &nk);
    CHECK(r == 0 && nc == 40 && nk == 7 && !memcmp(buf, c20.bytes, 40) && !memcmp(buf + 40, d20.bytes, 7), "客体输入：键 0x20（同块第 2 条）40 + 7 字节逐字节相等（rc %d）", r); free(buf);
    r = lp_guest_get(&p, 0x30, 1, &buf, &nc, &nk);
    CHECK(r == 0 && nc == 0x880 && nk == 64 && !memcmp(buf, c30.bytes, 0x880) && !memcmp(buf + 0x880, d30.bytes, 64), "客体输入：键 0x30（分片 1 的另一块、阶段 1）0x880 + 64 字节逐字节相等（rc %d）", r); free(buf);
    CHECK(lp_guest_get(&p, 0x10, 1, &buf, &nc, &nk) == 1 && !buf && g_red == red0, "客体输入：键 0x10 按阶段 1 要（块是阶段 0）：返回 1、不给数据、不报红");
    CHECK(lp_guest_get(&p, 0x11, 0, &buf, &nc, &nk) == 1 && !buf && g_red == red0, "客体输入：没有的键 0x11：返回 1、不报红");
    CHECK(lp_guest_get(&p, 0x40, 0, &buf, &nc, &nk) == -1 && !buf && g_red == red0 + 1, "客体输入：键 0x40 的段 Adler-32 坏：返回 -1、报红一次");
    CHECK(lp_guest_get(&p, 0x50, 1, &buf, &nc, &nk) == -1 && !buf && g_red == red0 + 2, "客体输入：键 0x50 的记录指向不含它的块：返回 -1、报红一次");
    char empty[] = "/tmp/t_lib_guest_e.XXXXXX"; if (!mkdtemp(empty)) exit(2);
    uint64_t kq[1] = {0x10}; uint8_t kdq[1] = {0}, shq[1] = {0};
    write_pack(empty, "abcdef012345", @[c10], shq, kq, kdq, 1, -1);   // 旧包：只有库段、没有种类 56
    lp_pack q; CHECK(lp_open(&q, empty, "abcdef012345") == 1 && lp_guest_get(&q, 0x10, 0, &buf, &nc, &nk) == 1 && g_red == red0 + 2, "客体输入：旧包（没有种类 56）返回 1、不报红");
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { printf("用法：t_lib_pack <a.metallib> <b.metallib>\n"); return 2; }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSData *la = rd(argv[1]), *lb = rd(argv[2]); NSData *ja = [@"{\"chain\":\"abcdef012345\",\"entry\":\"fa\"}" dataUsingEncoding:NSUTF8StringEncoding];
    char dir[] = "/tmp/t_lib_pack.XXXXXX"; if (!mkdtemp(dir)) return 2;
    // 键 A = 0x00000000000000aa（种类 0 库、1 json，分片 0），键 B = 0x0123456789abcdef（种类 0 库、3 影子输入库，分片 1）；按 (键, 种类) 升序
    // 另有两段 1 MB 填充（键 0xff…fe / 0xff…ff，各在一个分片尾，从不取）：分片远大于页，整片映射会让下面的映射字节判据红
    NSMutableData *pad = [NSMutableData dataWithLength:1 << 20];
    uint64_t keys[6] = {0xaa, 0xaa, 0x0123456789abcdefull, 0x0123456789abcdefull, 0xfffffffffffffffeull, 0xffffffffffffffffull}; uint8_t kinds[6] = {0, 1, 0, 3, 0, 0}, shards[6] = {0, 0, 1, 1, 0, 1};
    write_pack(dir, "abcdef012345", @[la, ja, lb, la, pad, pad], shards, keys, kinds, 6, -1);
    lp_pack p; CHECK(lp_open(&p, dir, "abcdef012345") == 1 && p.n == 6 && p.nshard == 2, "打开：6 条记录、2 个分片");
    dispatch_data_t a = lp_get(&p, "00000000000000aa_b", 0), j = lp_get(&p, "00000000000000aa_b", 1), b = lp_get(&p, "0123456789abcdef_b", 0), bv = lp_get(&p, "0123456789abcdef_bv", 3);
    CHECK(a && [(NSData *)a isEqualToData:la], "键 A 种类 0 = a.metallib 原字节（%zu 字节）", la.length);
    CHECK(j && [(NSData *)j isEqualToData:ja], "键 A 种类 1 = json 原字节");
    CHECK(b && [(NSData *)b isEqualToData:lb], "键 B 种类 0（分片 1）= b.metallib 原字节");
    CHECK(bv && [(NSData *)bv isEqualToData:la], "键 B 种类 3（分片 1 第二段，16 字节对齐偏移）= a.metallib 原字节");
    NSError *e = nil; id<MTLLibrary> L = a ? [dev newLibraryWithData:a error:&e] : nil, M = b ? [dev newLibraryWithData:b error:&e] : nil;
    CHECK(L && [L newFunctionWithName:@"fa"], "切片建库取到入口 fa");
    CHECK(M && [M newFunctionWithName:@"fb"], "分片 1 切片建库取到入口 fb");
    // 10-26 巫师3：分片整片映射且常驻，21 片 1343 MB 吃光低区。11-01 起一段 = 只映射这一段（无主之地3：malloc 读出的段被库持有、全算常驻 1.4 GB）。
    //   两个分片都取过、库也建着：.pak 映射总字节 ≤ 取到的 4 段各自按页取整之和（整片映射会超）
    char real[PATH_MAX]; int okp = realpath(dir, real) != NULL; uint64_t pg = (uint64_t)getpagesize(), lim = 0;
    NSData *segs4[4] = {la, ja, lb, la}; for (int i = 0; i < 4; i++) lim += (segs4[i].length + 16 + pg - 1) / pg * pg + pg;   // 段前对齐差 < 一页
    int nm = okp ? pak_maps(real) : -1;
    CHECK(okp && nm <= 4 && g_pak_bytes <= lim, "取过 4 段：.pak 映射 %d 块、%llu 字节 ≤ 各段按页取整之和 %llu（只映射取到的段，不整片映射）", nm, (unsigned long long)g_pak_bytes, (unsigned long long)lim);
    {   // 量法自检：紧贴一块 1 MB 匿名区之后映射 lib.000.pak 一页，计数只多这一页（匿名区不算进来）
        char pk[PATH_MAX]; snprintf(pk, sizeof pk, "%s/lib.000.pak", real); int fd = open(pk, O_RDONLY); uint64_t b0 = g_pak_bytes;
        char *an = mmap(NULL, (1 << 20) + pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); an[0] = 1;
        void *fm = fd >= 0 && an != MAP_FAILED ? mmap(an + (1 << 20), pg, PROT_READ, MAP_PRIVATE | MAP_FIXED, fd, 0) : MAP_FAILED; if (fd >= 0) close(fd);
        int n2 = pak_maps(real);
        CHECK(fm != MAP_FAILED && n2 == nm + 1 && g_pak_bytes == b0 + pg, "量法：.pak 映射前紧贴 1 MB 匿名区，只多算 1 块 %llu 字节（得 %d 块、多 %lld 字节）", (unsigned long long)pg, n2 - nm, (long long)(g_pak_bytes - b0));
        if (an != MAP_FAILED) munmap(an, (1 << 20) + pg); }
    CHECK(lp_get(&p, "00000000000000aa_bf", 2) == NULL && g_red == 0, "没有的种类（键 A 种类 2）返回空、不报红");
    CHECK(lp_get(&p, "00000000000000ab_b", 0) == NULL, "没有的键返回空");
    CHECK(lp_get(&p, "zz00000000000000_b", 0) == NULL, "名字前 16 位不是十六进制返回空");
    lp_pack q; CHECK(lp_open(&q, dir, "000000000000") == -1 && g_red == 1, "链版本不符：判格式错并报红");
    write_pack(dir, "abcdef012345", @[la, ja, lb, la], shards, keys, kinds, 4, 1);   // 分片 1 在索引里的大小写错
    lp_pack r2; int o = lp_open(&r2, dir, "abcdef012345"); int red0 = g_red;
    CHECK(o == 1 && lp_get(&r2, "00000000000000aa_b", 0) != NULL, "分片 0 照常取");
    CHECK(lp_get(&r2, "0123456789abcdef_b", 0) == NULL && g_red == red0 + 1, "分片 1 大小与索引不符：报红、返回空");
    char empty[] = "/tmp/t_lib_pack_e.XXXXXX"; if (!mkdtemp(empty)) return 2;
    lp_pack s; int red1 = g_red; CHECK(lp_open(&s, empty, "abcdef012345") == 0 && g_red == red1, "没有 lib.idx：返回 0、不报红（由调用方判旧格式）");
    {   // 同一段只建一个库（lp_library，11-05 时之笛：批库 1139 段被多键共用，最大一段 22 MB / 196 键；按键各建一个库，进 3D 时低区被吃掉约 800 MB）
        //   键 C1、C2 的种类 0 指向同一段 a.metallib（分片 0），键 C3 指向另一段 b.metallib（分片 1）。期望（由写进去的记录决定）：C1、C2 拿到同一个库对象、只建 1 次；
        //   C3 是另一个库；没有的键给 ENOENT。负对照：三个库都放掉后再取 C1，弱引用表里已没有它，要新建（计数 +1）——表不能把库续命
        char d3[] = "/tmp/t_lib_pack_s.XXXXXX"; if (!mkdtemp(d3)) return 2;
        uint64_t k3[3] = {0xc1, 0xc2, 0xc3}; uint8_t kd3[3] = {0, 0, 0}, sh3[3] = {0, 0, 1};
        write_pack(d3, "abcdef012345", @[la, la, lb], sh3, k3, kd3, 3, -1);
        lp_pack t; int o3 = lp_open(&t, d3, "abcdef012345");
        CHECK(o3 == 1 && t.rec[0].off == t.rec[1].off && lp_shard(&t.rec[0]) == lp_shard(&t.rec[1]) && lp_shard(&t.rec[2]) == 1, "共用段容器：C1、C2 记录同分片同偏移，C3 在分片 1");
        uint64_t b0 = atomic_load(&g_lp_lib_built), s0 = atomic_load(&g_lp_lib_shared); int ly1 = -1, ly2 = -1; NSError *e3 = nil;
        uintptr_t w1 = 0;
        @autoreleasepool {
            id<MTLLibrary> c1 = lp_library(&t, dev, "00000000000000c1_b", 0, &ly1, &e3), c2 = lp_library(&t, dev, "00000000000000c2_b", 0, &ly2, &e3), c3 = lp_library(&t, dev, "00000000000000c3_b", 0, NULL, &e3);
            CHECK(c1 && c1 == c2, "C1、C2 同段：同一个库对象（%p / %p）", (__bridge void *)c1, (__bridge void *)c2);
            CHECK(c3 && c3 != c1 && [c3 newFunctionWithName:@"fb"] && [c1 newFunctionWithName:@"fa"], "C3 另一段：另一个库，入口各自取得到（fa / fb）");
            CHECK(atomic_load(&g_lp_lib_built) - b0 == 2 && atomic_load(&g_lp_lib_shared) - s0 == 1, "建库 2 次、共用 1 次（得建 %llu、共用 %llu）",
                  (unsigned long long)(atomic_load(&g_lp_lib_built) - b0), (unsigned long long)(atomic_load(&g_lp_lib_shared) - s0));
            CHECK(ly1 == ly2, "同段的图层标志一致（%d / %d）", ly1, ly2);
            NSError *e4 = nil; CHECK(lp_library(&t, dev, "00000000000000c4_b", 0, NULL, &e4) == nil && e4.code == ENOENT, "没有的键：nil、ENOENT");
            w1 = (uintptr_t)(__bridge void *)c1;
        }
        uint64_t b1 = atomic_load(&g_lp_lib_built);
        @autoreleasepool { id<MTLLibrary> c1b = lp_library(&t, dev, "00000000000000c1_b", 0, NULL, &e3);
            CHECK(c1b && atomic_load(&g_lp_lib_built) == b1 + 1, "负对照：库全部放掉后再取 C1 要新建（建库 +%llu；表是弱引用，不给库续命）", (unsigned long long)(atomic_load(&g_lp_lib_built) - b1)); (void)w1; }
    }
    {   // 段映射放宿主高位区（11-05 赤痕 / 轩辕剑柒：开局预热 1.4 秒映射 796 MB / 251 段，mmap(NULL) 全落低区，GC 现长 32 MB 新段拿不到地址、托管 OOM）。
        //   模拟：「低区」= mmap(NULL) 落的最低空洞；「高位区」= 在 0x60_0000_0000 一带先占 64 MB 再放掉留下的空洞 [H, H + 64 MB)，注入给 LP_HI_RANGE。
        //   期望（只由造的区间与写进去的字节决定）：6 段（各 1 MB、内容各不同）全落 [H, H + 64 MB)、字节逐段相等、H 之下的 .pak 映射字节不增长；
        //   高位区里的段建库取得到入口；段全部放掉后区里 .pak 字节回 0（释放路径 munmap）。区满（区间 4 MB、整块已被占）：段照样取到（退回低区，地址在 H 之下）、
        //   报红恰好 1 次（两段只报一次）；有原生层但没有高位区（LP_HI_RANGE 回 0）：同样退回、报红恰好 1 次
        char d5[] = "/tmp/t_lib_pack_h.XXXXXX"; if (!mkdtemp(d5)) return 2; char r5[PATH_MAX]; if (!realpath(d5, r5)) return 2;
        enum { NS = 6 }; NSMutableArray<NSData *> *sg = [NSMutableArray array]; uint64_t k5[NS + 1]; uint8_t kd5[NS + 1], sh5[NS + 1];
        for (int i = 0; i < NS; i++) { NSMutableData *m = [NSMutableData dataWithLength:(1 << 20) + 4096 * i]; memset(m.mutableBytes, 0x11 * (i + 1), m.length); [sg addObject:m]; k5[i] = 0xd0 + i; kd5[i] = 0; sh5[i] = i & 1; }
        [sg addObject:la]; k5[NS] = 0xe0; kd5[NS] = 0; sh5[NS] = 0;
        write_pack(d5, "abcdef012345", sg, sh5, k5, kd5, NS + 1, -1);
        lp_pack h; CHECK(lp_open(&h, d5, "abcdef012345") == 1, "高位区容器：7 段");
        const uint64_t HN = 64ull << 20; void *hr = mmap((void *)0x6000000000ull, HN, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); uint64_t H = (uint64_t)hr;
        CHECK(hr != MAP_FAILED, "造高位区：%#llx +64 MB", (unsigned long long)H); munmap(hr, HN);
        g_hr_rc = 1; g_hr_lo = H; g_hr_hi = H + HN; int red0 = g_red; uint64_t low0 = pak_bytes_in(r5, 0, H);
        @autoreleasepool {
            dispatch_data_t seg[NS]; int inr = 0, same = 0; uint64_t sum = 0, pg = (uint64_t)getpagesize();
            for (int i = 0; i < NS; i++) { char nm[32]; snprintf(nm, sizeof nm, "%016llx_b", (unsigned long long)k5[i]); seg[i] = lp_get(&h, nm, 0);
                const void *b = NULL; size_t n = 0; dispatch_data_t f = seg[i] ? dispatch_data_create_map(seg[i], &b, &n) : nil; (void)f;
                if (b && (uint64_t)b >= H && (uint64_t)b + n <= H + HN) inr++;
                if (seg[i] && [(NSData *)seg[i] isEqualToData:sg[i]]) same++;
                sum += (sg[i].length + pg - 1) / pg * pg; }
            CHECK(inr == NS, "6 段都落在高位区 [%#llx, %#llx)（得 %d 段）", (unsigned long long)H, (unsigned long long)(H + HN), inr);
            CHECK(same == NS, "6 段字节逐段相等（得 %d 段）", same);
            uint64_t low1 = pak_bytes_in(r5, 0, H), inb = pak_bytes_in(r5, H, H + HN);
            CHECK(low1 == low0, "低区（H 之下）.pak 映射不增长：%llu → %llu 字节", (unsigned long long)low0, (unsigned long long)low1);
            CHECK(inb >= sum && inb <= sum + NS * pg, "高位区里 .pak 映射 %llu 字节 = 6 段按页取整之和 %llu（+每段至多一页对齐差）", (unsigned long long)inb, (unsigned long long)sum);
            NSError *e5 = nil; id<MTLLibrary> lh = lp_library(&h, dev, "00000000000000e0_b", 0, NULL, &e5);
            CHECK(lh && [lh newFunctionWithName:@"fa"], "高位区里的段建库取到入口 fa");
            CHECK(g_red == red0, "高位区放得下：不报红（得 %d 次）", g_red - red0);
            for (int i = 0; i < NS; i++) seg[i] = nil;
            lh = nil;
        }
        uint64_t left = 0; for (int t = 0; t < 3000 && (left = pak_bytes_in(r5, H, H + HN)); t++) usleep(10000);   // 放掉的回调在全局队列上异步跑：等到回 0，兜底 30 秒（原 2 秒，负载高时回调晚跑就假红）
        CHECK(left == 0, "段全部放掉后高位区 .pak 映射回 0（得 %llu 字节）", (unsigned long long)left);
        void *full = mmap((void *)H, 4 << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);   // 区满：区间 4 MB（比段大）、整块已被别人占着
        g_hr_lo = (uint64_t)full; g_hr_hi = (uint64_t)full + (4 << 20); int red1 = g_red;
        @autoreleasepool {
            dispatch_data_t f0 = lp_get(&h, "00000000000000d0_b", 0), f1 = lp_get(&h, "00000000000000d1_b", 0);
            const void *b0 = NULL, *b1 = NULL; size_t n0 = 0, n1 = 0; dispatch_data_t m0 = f0 ? dispatch_data_create_map(f0, &b0, &n0) : nil, m1 = f1 ? dispatch_data_create_map(f1, &b1, &n1) : nil; (void)m0; (void)m1;
            CHECK(f0 && f1 && [(NSData *)f0 isEqualToData:sg[0]] && [(NSData *)f1 isEqualToData:sg[1]], "区满：两段照样取到、字节相等（退回原路径，开局不失败）");
            CHECK(b0 && b1 && (uint64_t)b0 < H && (uint64_t)b1 < H, "区满：两段落在低区（%p / %p，H 之下）", b0, b1);
            CHECK(g_red == red1 + 1, "区满：报红恰好 1 次（两段，得 %d 次）", g_red - red1);
        }
        g_hr_rc = 0; int red2 = g_red;
        @autoreleasepool {
            dispatch_data_t f2 = lp_get(&h, "00000000000000d2_b", 0), f3 = lp_get(&h, "00000000000000d3_b", 0);
            CHECK(f2 && f3 && [(NSData *)f2 isEqualToData:sg[2]] && [(NSData *)f3 isEqualToData:sg[3]] && g_red == red2 + 1, "没有高位区：两段照样取到、报红恰好 1 次（得 %d 次）", g_red - red2);
        }
        g_hr_rc = -1; if (full != MAP_FAILED) munmap(full, 4 << 20);
    }
    {   // 覆盖层（lp_pick，S 级升级补的可读瓦片版放 <库目录>/bf/）：主容器键 A（种类 0 库、1 json「主」）、键 C（种类 1 json）；
        //   覆盖层键 A（种类 1 json「覆盖」、种类 2 _bf 库 = b.metallib）。期望（按写进去的字节手写）：A 的 json 取覆盖层那份、A 的 _bf 取覆盖层、
        //   A 的库（种类 0）覆盖层没有 → 主容器；C 只在主容器 → 主容器；覆盖层没开（idx 空）→ 一律主容器
        char dm[] = "/tmp/t_lib_pack_m.XXXXXX"; if (!mkdtemp(dm)) return 2;
        char dov[PATH_MAX]; snprintf(dov, sizeof dov, "%s/bf", dm); mkdir(dov, 0755);
        NSData *jm = [@"{\"entry\":\"main\"}" dataUsingEncoding:NSUTF8StringEncoding], *jo = [@"{\"entry\":\"main\",\"fetch\":{}}" dataUsingEncoding:NSUTF8StringEncoding], *jc = [@"{\"c\":1}" dataUsingEncoding:NSUTF8StringEncoding];
        uint64_t km[3] = {0xaa, 0xaa, 0xcc}; uint8_t kdm[3] = {0, 1, 1}, shm[3] = {0, 0, 1};
        write_pack(dm, "abcdef012345", @[la, jm, jc], shm, km, kdm, 3, -1);
        uint64_t ko[2] = {0xaa, 0xaa}; uint8_t kdo[2] = {1, 2}, sho[2] = {0, 1};
        write_pack(dov, "abcdef012345", @[jo, lb], sho, ko, kdo, 2, -1);
        lp_pack m, o, none; memset(&none, 0, sizeof none);
        CHECK(lp_open(&m, dm, "abcdef012345") == 1 && lp_open(&o, dov, "abcdef012345") == 1, "覆盖层：主容器与 bf/ 覆盖层都打开");
        CHECK(lp_pick(&m, &o, "00000000000000aa_b", 1) == &o, "键 A 的 json：取覆盖层");
        dispatch_data_t aj = lp_get(lp_pick(&m, &o, "00000000000000aa_b", 1), "00000000000000aa_b", 1);
        CHECK(aj && [(NSData *)aj isEqualToData:jo], "键 A 的 json 是覆盖层那份（带 fetch）");
        CHECK(lp_pick(&m, &o, "00000000000000aa_bf", 2) == &o, "键 A 的 _bf：取覆盖层");
        NSError *e5 = nil; id<MTLLibrary> lbf = lp_library(lp_pick(&m, &o, "00000000000000aa_bf", 2), dev, "00000000000000aa_bf", 2, NULL, &e5);
        CHECK(lbf && [lbf newFunctionWithName:@"fb"] != nil, "键 A 的 _bf 从覆盖层建库、取到入口 fb（%s）", e5.localizedDescription.UTF8String ?: "-");
        CHECK(lp_pick(&m, &o, "00000000000000aa_b", 0) == &m, "键 A 的库（种类 0）覆盖层没有：取主容器");
        CHECK(lp_pick(&m, &o, "00000000000000cc_b", 1) == &m, "键 C 只在主容器：取主容器");
        CHECK(lp_pick(&m, &none, "00000000000000aa_b", 1) == &m && lp_pick(&m, NULL, "00000000000000aa_bf", 2) == &m, "覆盖层没开：一律主容器");
        lp_pack bad; CHECK(lp_open(&bad, dov, "000000000000") == -1, "覆盖层链版本不符：判格式错（宿主不开它，只用主容器）");
    }
    guest_cases();
    {   // #1960：分片号超过 255（记录里 u8 低位 + 原保留的 u16 高位，lp_shard）。手造 300 片（各 16 字节占位，只有 3 号、299 号放真段），
        //   期望（手写）：打开、分片数 300；键 A 种类 0 在 299 号片 = a.metallib 原字节、能建库取到 fa；键 B 种类 1 在 3 号片 = json 原字节。
        //   反证：读端只取 u8 低位时 299 → 43（43 号片只有 16 字节占位），取回的字节不等、建库失败
        char d3[] = "/tmp/t_lib_pack_300.XXXXXX"; if (!mkdtemp(d3)) return 2;
        enum { NS = 300 }; NSMutableData *pk[NS];
        for (int k = 0; k < NS; k++) pk[k] = [NSMutableData dataWithLength:16];
        uint64_t off_a = pk[299].length; [pk[299] appendData:la]; uint64_t off_j = pk[3].length; [pk[3] appendData:ja];
        for (int k = 0; k < NS; k++) [pk[k] writeToFile:[NSString stringWithFormat:@"%s/lib.%03d.pak", d3, k] atomically:YES];
        NSMutableData *ix = [NSMutableData data]; uint32_t ver = 1, nn = 2, ns = NS, z = 0; char ch[12] = "abcdef012345"; uint64_t z64 = 0;
        [ix appendBytes:"S2ALIB\0\0" length:8]; [ix appendBytes:&ver length:4]; [ix appendBytes:&nn length:4]; [ix appendBytes:&ns length:4]; [ix appendBytes:&z length:4]; [ix appendBytes:ch length:12];
        [ix appendBytes:&z length:4]; [ix appendBytes:&z64 length:8];
        for (int k = 0; k < NS; k++) { uint64_t sz = pk[k].length; [ix appendBytes:&sz length:8]; [ix appendBytes:&z64 length:8]; }
        struct { uint64_t key; uint8_t kind, lo; uint16_t hi; uint32_t len; uint64_t off; } r3[2] = {
            {0xaa, 0, 299 & 0xff, 299 >> 8, (uint32_t)la.length, off_a}, {0xbb, 1, 3, 0, (uint32_t)ja.length, off_j}};
        [ix appendBytes:r3 length:sizeof r3]; [ix writeToFile:[NSString stringWithFormat:@"%s/lib.idx", d3] atomically:YES];
        lp_pack p3; CHECK(lp_open(&p3, d3, "abcdef012345") == 1 && p3.nshard == NS, "#1960 300 片：容器打开、分片数 %u（期望 300）", p3.nshard);
        dispatch_data_t a3 = lp_get(&p3, "00000000000000aa_b", 0), j3 = lp_get(&p3, "00000000000000bb_b", 1);
        CHECK(a3 && [(NSData *)a3 isEqualToData:la], "#1960 键 A 种类 0 在 299 号片：取回 = a.metallib 原字节");
        CHECK(j3 && [(NSData *)j3 isEqualToData:ja], "#1960 键 B 种类 1 在 3 号片：取回 = json 原字节");
        NSError *e3 = nil; id<MTLLibrary> L3 = lp_library(&p3, dev, "00000000000000aa_b", 0, NULL, &e3);
        CHECK(L3 && [L3 newFunctionWithName:@"fa"], "#1960 299 号片的段建库取到入口 fa（%s）", e3.localizedDescription.UTF8String ?: "-");
    }
    printf("%s t_lib_pack：%d 项，不通 %d\n", fails ? "✗" : "✓", checks, fails);
    return fails ? 1 : 0;
} }
