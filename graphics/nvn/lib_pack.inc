// S2Arm 直连库打包容器的 Apple 段读法（10-25 合库，格式见 lib_pack_core.inc 与共享笔记「画面着色器线_直连库合库草案_1025.md」§1，出库 graphics/tools/direct/lib_pack.py）。
//   容器头/记录结构、lib.idx 打开核头、按键二分在 lib_pack_core.inc（#1434 拆出共用，安卓侧 POSIX 段在 android/native/direct/libpack_vk.c 复用同一份）。
// 运行时：lib.idx 整份 mmap、二分查；一段 = 分片文件里这一段的只读文件映射（按页对齐只映射这一段，dispatch_data 放掉时 munmap），
//   给 newLibraryWithData（库）或 NSJSONSerialization（json；dispatch_data 与 NSData 免费桥接）。
//   分片不整片映射：10-26 巫师3 测试设备2 两局，整片映射且常驻，21 片 1343 MB 全落在低区（4 GB 到游戏窗口底，占满窗口的款只剩 1.1–1.4 GB），
//   低区吃光后宿主 C++ 分配抛异常 abort；而用到的只是各片里少数几段。现在只占活着的库那几段
//   一段原先是 malloc + pread 的堆内存：Metal 库对象持有它，库活多久它就常驻多久、全算脏页。11-01 无主之地3 第 60 秒宿主 malloc 1694 MB 里 1376 MB 是这些段
//   （659 段、均 2.1 MB，预热线程载入的 943 MB），常驻 5.29 GB 超 iPhone 5 GB 上限；Mac 上大块 malloc 的地址房间也被吃光，再取 2.8 / 4.9 MB 的段 malloc 返回空、库读不出。
//   改成文件映射：页是文件后备的干净页，系统可回收、不计入常驻（iOS 判杀看的足迹），地址占用与原先相同（只映射这一段）
// 段放高位区（11-05 赤痕 / 轩辕剑柒托管 OOM）：mmap(NULL) 取最低的空洞，段落进 4 GB 起那段低区——GC 段模式的新段只能落那里（坑记录 10-24 异度神剑3）。
//   开局阻塞预热（31efce0d5）1.4 秒建完 444 个着色器、段映射 796 MB / 251 块全在低区，GC 现长新段拿不到地址抛 OutOfMemoryException；同一时刻窗口下方留给宿主的 1 GB 还空着 982 MB。
//   现在每段带地址提示映射进宿主高位区（runtime/src/vawin.c s2a_host_hi_range：窗口下方的宿主保留段，或窗口之上），核落点；放不下 / 没有高位区报红一次、退回 mmap(NULL)
// 由 nvn_mtl.m 与单测各自 #include；包含方先定义 LP_LOG(fmt, ...)（一行日志，红行自带 【红】）与 LP_HI_RANGE(&lo, &hi)
//   （1 = 宿主高位区 [lo, hi)；0 = 有原生层但没有高位区，报红一次、退回低区；-1 = 没链原生层（图形单测），照旧 mmap(NULL)、不报红）。线程：库在提交线程、预热线程、预载线程上都会取，每次取各开各读（无共享可变状态）
#include "lib_pack_core.inc"
#include <errno.h>
#include <stdatomic.h>
#include "../../runtime/include/s2a_qos.h"   // 线程调度档一张表（IO_BG）；要在第一次用 s2a_qos_global 之前（11-06 原放在第 112 行，t_lib_pack 编不过、gfx 钩子红）

// 16 位十六进制键（库文件名的前 16 字符，比如 "0123456789abcdef_b"）→ 数值；不是就返回 0 并置 *ok = 0。
//   Apple 段按文件名取段用；安卓段键是 8 字节控制键原件，不走文件名（libpack_vk.c lp_key8）。
static uint64_t lp_key(const char *s, int *ok) {
    uint64_t k = 0; *ok = 1;
    for (int i = 0; i < 16; i++) { char c = s[i]; int v = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
        if (v < 0) { *ok = 0; return 0; } k = k << 4 | (uint64_t)v; }
    return k;
}

// 映射一段（只读文件页）：先带提示放宿主高位区，落点不在区里（区满：内核往上找到了区外）就放掉、报红一次、退回 mmap(NULL)。*hi = 1 放进了高位区。
//   释放照旧 munmap（普通文件映射，不是自己占的保留）。读数：高位区段数 / 在用字节、退回低区的段数 / 字节（nvn_mtl.m shader_load_stats 打）
static _Atomic uint64_t g_lp_hi_n, g_lp_hi_live, g_lp_low_n, g_lp_low_bytes;
static _Atomic int g_lp_hi_full_red, g_lp_hi_none_red;
static void *lp_map(size_t len, int fd, off_t at, int *hi) {
    uint64_t lo = 0, top = 0; int rc = LP_HI_RANGE(&lo, &top); *hi = 0;
    if (rc < 0) return mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, at);
    if (rc > 0) {
        void *m = top > lo && len <= top - lo ? mmap((void *)(uintptr_t)lo, len, PROT_READ, MAP_PRIVATE, fd, at) : MAP_FAILED; uint64_t a = (uint64_t)(uintptr_t)m;
        if (m != MAP_FAILED && a >= lo && a + len <= top) { *hi = 1; atomic_fetch_add(&g_lp_hi_n, 1); atomic_fetch_add(&g_lp_hi_live, len); return m; }
        if (m != MAP_FAILED) munmap(m, len);
        if (!atomic_exchange(&g_lp_hi_full_red, 1))
            LP_LOG("【红】 direct library container: the host high range %#llx-%#llx has no room for a %zu-byte segment (it landed at %#llx); this and later segments that do not fit map into the low range the GC grows its segments in (first case)",
                   (unsigned long long)lo, (unsigned long long)top, len, m == MAP_FAILED ? 0ull : (unsigned long long)a);
    } else if (!atomic_exchange(&g_lp_hi_none_red, 1))
        LP_LOG("【红】 direct library container: no host high range (no address window); library segments map into the low range the GC grows its segments in (first case)");
    void *m = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, at);
    if (m != MAP_FAILED) { atomic_fetch_add(&g_lp_low_n, 1); atomic_fetch_add(&g_lp_low_bytes, len); }
    return m;
}
// 取一段：键 + 种类 → 分片映射的子区间（不拷贝）；没有这一段返回 NULL（不报红：很多键本来就没有 _bf / _bv）；分片缺失 / 大小不符 / 越界报红返回 NULL
static dispatch_data_t lp_get(lp_pack *p, const char *name, unsigned kind) {
    int ok; uint64_t key = lp_key(name, &ok); if (!ok || !p->idx) return NULL;
    const lp_rec *r = lp_find(p, key, kind); if (!r) return NULL;
    if (lp_shard(r) >= p->nshard) { LP_LOG("【红】 direct library container: %.16s kind %u points at shard %u of %u", name, kind, lp_shard(r), p->nshard); return NULL; }
    if (r->off + r->len > p->ssize[2 * lp_shard(r)]) { LP_LOG("【红】 direct library container: %.16s kind %u runs past the end of shard %u", name, kind, lp_shard(r)); return NULL; }
    char path[1100]; snprintf(path, sizeof path, "%s/lib.%03u.pak", p->dir, lp_shard(r));
    int fd = open(path, O_RDONLY); struct stat st;
    if (fd < 0 || fstat(fd, &st) || (uint64_t)st.st_size != p->ssize[2 * lp_shard(r)]) {
        LP_LOG("【红】 direct library container: shard %s is %s (index says %llu bytes)", path, fd < 0 ? "missing" : "the wrong size", (unsigned long long)p->ssize[2 * lp_shard(r)]);
        if (fd >= 0) close(fd); return NULL; }
    const uint64_t pg = (uint64_t)getpagesize(), at = r->off & ~(pg - 1), delta = r->off - at; const size_t mlen = (size_t)(delta + (r->len ? r->len : 1));
    int hi; void *m = lp_map(mlen, fd, (off_t)at, &hi); int e = errno;
    close(fd);
    if (m == MAP_FAILED) { LP_LOG("【红】 direct library container: cannot map %.16s kind %u from %s (%u bytes at %#llx, errno %d)", name, kind, path, r->len, (unsigned long long)r->off, e); return NULL; }
    return dispatch_data_create((const uint8_t *)m + delta, r->len, s2a_qos_global(S2A_QOS_IO_BG), ^{ munmap(m, mlen); if (hi) atomic_fetch_sub(&g_lp_hi_live, mlen); });
}

#ifdef __OBJC__
// 同一段只建一个 Metal 库（11-05 时之笛）：批库（dsh_batch 编批）把上百个键的入口编进同一个 metallib，这些键的种类 0 记录指向同一段（分片 + 偏移）。
//   时之笛 41481 键只有 3234 段，1139 段被多键共用，最大一段 22 MB 被 196 个键共用。按键各自 lp_get + newLibraryWithData，同一段被映射、建库多次：
//   第十一版测试设备1 进 3D 那几秒低区被拦不到的分配吃掉约 800 MB，随后库段映射 ENOMEM（21 次，8–18 MB 的段）、着色器装不上、建 c1 缓冲失败崩溃。
//   这里按段记活着的库（弱引用：库放掉就不再记，库的生命周期照旧由持有它的着色器决定），同段的键拿同一个库；段里有没有 render_target_array_index 随段记，
//   不必每个键扫一遍整段。layer 可为 NULL。取不到返回 nil 并给 err（没有这一段：ENOENT「not in the library container」；映射失败 lp_get 已报红）
#import <Metal/Metal.h>
// 客体输入（种类 56；段与块的格式见 graphics/tools/direct/dsh/batch/LibPack.cs GuestBlocks）：按键取出这支着色器出包时交给翻译器的控制段 + 代码区。
//   用处：库里的着色器在本机没翻过，游戏又已回收控制段时，设备侧现做补齐 / 采样模拟变体、宿主自跑任务阶段要先翻一份基础源码（graphics/nvn/host/dsh_miss.inc）。
//   读法：这一段 pread 进来（压缩后几十 KB）、整块解压（Foundation 的 NSDataCompressionAlgorithmZlib 是裸 deflate：跳过 2 字节 zlib 头，尾部 Adler-32 自己核）、取一条、块放掉；
//   用 Foundation 而不用 Compression 框架 / zlib 库：直连层静态库（libnvn.a）的各个链接方（宿主、App、十来个单测）都已链 Foundation，不给它们加链接库；
//   一个键一局至多取一两次（变体做好就落兜底目录），不缓存块。st：要的阶段（dsh_stage 编号：0 顶点 1 片元 2 计算 4 任务 5 网格）。
//   → 0 取到：*buf 是 malloc 的一块（控制段 *nctl 字节在前、代码区 *ncode 字节紧随），调用方 free；
//     1 没有（容器里没有这个键的种类 56：旧包、翻译失败的键、不带的阶段；或块里记的阶段不是 st）：不报红，由调用方报；-1 段坏了（报红）
__attribute__((unused)) static uint32_t lp_adler32(const uint8_t *p, size_t n) {
    uint32_t a = 1, b = 0;
    while (n) { size_t m = n < 5552 ? n : 5552; n -= m; while (m--) { a += *p++; b += a; } a %= 65521; b %= 65521; }
    return b << 16 | a;
}
__attribute__((unused)) static int lp_guest_get(const lp_pack *p, uint64_t key, int st, uint8_t **buf, uint32_t *nctl, uint32_t *ncode) {
    *buf = NULL; *nctl = *ncode = 0;
    const lp_rec *r = p && p->idx ? lp_find(p, key, LP_K_GUEST) : NULL; if (!r) return 1;
    enum { HEAD = 8, ZHEAD = 2, ZTAIL = 4, RAW_MAX = 64u << 20 };
    const char *why = NULL; uint8_t *seg = NULL, *raw = NULL; uint32_t rawlen = 0; int rc = -1;
    char path[1100]; snprintf(path, sizeof path, "%s/lib.%03u.pak", p->dir, lp_shard(r));
    int fd = -1;
    if (lp_shard(r) >= p->nshard || r->off + r->len > p->ssize[2 * lp_shard(r)]) why = "points past the end of its shard";
    else if (r->len < HEAD + ZHEAD + ZTAIL) why = "is shorter than its header";
    else if (!(seg = malloc(r->len))) why = "cannot be read (out of memory)";
    else if ((fd = open(path, O_RDONLY)) < 0 || pread(fd, seg, r->len, (off_t)r->off) != (ssize_t)r->len) why = "cannot be read from its shard";
    if (fd >= 0) close(fd);
    if (!why) {
        memcpy(&rawlen, seg, 4); uint8_t cmf = seg[HEAD], flg = seg[HEAD + 1];
        if (rawlen < 8 || rawlen > RAW_MAX) why = "states an implausible inflated length";
        else if ((cmf & 0x0f) != 8 || ((unsigned)cmf << 8 | flg) % 31 || (flg & 0x20)) why = "is not a zlib stream";
        else @autoreleasepool {
            NSData *z = [NSData dataWithBytesNoCopy:seg + HEAD + ZHEAD length:r->len - HEAD - ZHEAD - ZTAIL freeWhenDone:NO];
            NSData *u = [z decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil];
            if (!u || u.length != rawlen) why = "does not inflate to its stated length";
            else if (!(raw = malloc(rawlen))) why = "cannot be inflated (out of memory)";
            else memcpy(raw, u.bytes, rawlen);
        }
        if (!why) { const uint8_t *t = seg + r->len - ZTAIL; uint32_t want = (uint32_t)t[0] << 24 | (uint32_t)t[1] << 16 | (uint32_t)t[2] << 8 | t[3];
               if (lp_adler32(raw, rawlen) != want) why = "fails its Adler-32 check"; }
    }
    if (!why) {
        uint32_t n; memcpy(&n, raw, 4);
        if (!n || n > 16 || raw[5] != 1 || HEAD + 24ull * n > rawlen) why = "has a malformed block header";
        else {
            const uint8_t *e = NULL;
            for (uint32_t i = 0; i < n; i++) { uint64_t k; memcpy(&k, raw + HEAD + 24 * i, 8); if (k == key) { e = raw + HEAD + 24 * i; break; } }
            uint32_t at = 0, c = 0, d = 0; if (e) { memcpy(&at, e + 8, 4); memcpy(&c, e + 12, 4); memcpy(&d, e + 16, 4); }
            if (!e) why = "points at a block that does not hold this key";
            else if (at < HEAD + 24 * n || (uint64_t)at + c + d > rawlen) why = "has an entry running past its block";
            else if (raw[4] != st) rc = 1;   // 块里是别的阶段：按没有（调用方报红）
            else if (!(*buf = malloc((size_t)c + d + 1))) why = "cannot be copied out (out of memory)";
            else { memcpy(*buf, raw + at, (size_t)c + d); *nctl = c; *ncode = d; rc = 0; }
        }
    }
    if (why) LP_LOG("【红】 direct library container: the guest input (kind %u) of %016llx in %s at %#llx (%u bytes) %s", (unsigned)LP_K_GUEST, (unsigned long long)key, path, (unsigned long long)r->off, r->len, why);
    free(seg); free(raw);
    return rc;
}

#include <os/lock.h>
static os_unfair_lock g_lp_lib_mu = OS_UNFAIR_LOCK_INIT;
static NSMapTable<NSString *, id<MTLLibrary>> *g_lp_libs;    // "<容器>/<分片>/<偏移>" → 活着的库
static NSMutableDictionary<NSString *, NSNumber *> *g_lp_layer;   // 同键 → 这一段用不用 render_target_array_index
static _Atomic uint64_t g_lp_lib_built, g_lp_lib_shared;    // 建了几个库 / 几次取库直接拿到同段已建好的
// 覆盖层（S 级升级补的可读瓦片版：<库目录>/bf/，同格式同链版本的小容器，只含补上的 <键>_bf 与带 fetch 的 <键>_b.json）：
//   同键同种类覆盖层里有就取覆盖层，否则取主容器。主容器整份不动（玩家机上 1 GB 量级，只推这一小份）。over 没开（idx 空）= 只用主容器
static lp_pack *lp_pick(lp_pack *main, lp_pack *over, const char *name, unsigned kind) {
    if (over && over->idx) { int ok; uint64_t k = lp_key(name, &ok); if (ok && lp_find(over, k, kind)) return over; }
    return main;
}
static id<MTLLibrary> lp_library(lp_pack *p, id<MTLDevice> dev, const char *name, unsigned kind, int *layer, NSError **err) {
    int ok; uint64_t key = lp_key(name, &ok); const lp_rec *r = ok && p->idx ? lp_find(p, key, kind) : NULL;
    if (!r) { if (err) *err = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%s is not in the library container", name]}];
              return nil; }
    NSString *bk = [NSString stringWithFormat:@"%p/%u/%llx", (void *)p->idx, lp_shard(r), (unsigned long long)r->off];
    os_unfair_lock_lock(&g_lp_lib_mu);
    if (!g_lp_libs) { g_lp_libs = [NSMapTable strongToWeakObjectsMapTable]; g_lp_layer = [NSMutableDictionary dictionary]; }
    id<MTLLibrary> lib = [g_lp_libs objectForKey:bk]; int ly = g_lp_layer[bk].intValue;
    os_unfair_lock_unlock(&g_lp_lib_mu);
    if (lib) { atomic_fetch_add(&g_lp_lib_shared, 1); if (layer) *layer = ly; return lib; }
    if (!dev) { if (err) *err = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENODEV userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%s: no Metal device yet (the library is built before the device exists)", name]}];
                return nil; }   // [nil newLibraryWithData:] returns nil and leaves the error unset: say so, or the caller can only report "no reflection json"
    dispatch_data_t d = lp_get(p, name, kind);
    if (!d) { if (err) *err = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%s: its library segment could not be mapped", name]}];
              return nil; }
    const void *b = NULL; size_t n = 0; dispatch_data_t flat = dispatch_data_create_map(d, &b, &n); (void)flat;   // one slice of one mapping: contiguous, no copy
    ly = b && memmem(b, n, "render_target_array_index", 25) != NULL;
    lib = [dev newLibraryWithData:d error:err];
    if (!lib) return nil;
    os_unfair_lock_lock(&g_lp_lib_mu);   // two threads may build the same segment at once: the first one in is kept, the other's library goes with this call
    id<MTLLibrary> cur = [g_lp_libs objectForKey:bk];
    if (cur) { lib = cur; ly = g_lp_layer[bk].intValue; } else { [g_lp_libs setObject:lib forKey:bk]; g_lp_layer[bk] = @(ly); }
    os_unfair_lock_unlock(&g_lp_lib_mu);
    atomic_fetch_add(cur ? &g_lp_lib_shared : &g_lp_lib_built, 1);
    if (layer) *layer = ly;
    return lib;
}
#endif
