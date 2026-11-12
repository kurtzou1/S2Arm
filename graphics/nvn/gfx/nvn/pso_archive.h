// S2Arm: the pipeline archive (after MacNativeGames totk_pipeline_archive.h, MIT). A pipeline's GPU code, once compiled on this device, is kept in a Metal binary archive beside
// pso_user.tsv (pipelines/<key>.metalarchive, or batch-*.metalarchive files indexed by batches.tsv, see par_write_batch) and later builds take it from there instead of compiling: the system's own shader cache is cleared by reboots and OS updates, and
// the prepare step (warm_prepare) rebuilt every listed pipeline from scratch after one. Measured there (M4, 2026-10-21): one file per pipeline, because a file holding many costs
// memory about quadratic in their number and Metal searches every archive handed to a pipeline; a one-pipeline file opens in 0.08 ms (about 35 KB) and gives its pipeline in
// 0.04 ms. iPhone 14: prewarm 95-122 s → 5.9 s, pipeline time in long frames 1,452 → 102 ms.
// A build first asks only its own file (MTLPipelineOptionFailOnBinaryArchiveMiss); a miss compiles as before. Writing compiles the pipeline once more, and writes go one at a time
// (g_par_wmu: the build folder a write leaves is told apart from others' by appearing during it): written in place they held the prepare step's 18 workers behind one lock
// (mhrise on the Mac 10-26: 2.0 s → 48.9 s). So the prewarm's misses are only noted (par_write_in_place) and written beside it, one by one by a utility writer (par_note);
// a pipeline first compiled in play is in pso_user.tsv, and the next start's prewarm notes it.
// The key only finds the file: Metal checks the functions and state, so a wrong file is a miss, never a wrong pipeline. A file that misses (another package's libraries under the
// same key) is removed and written again. Valid for one OS version, GPU and translation chain (pipelines/identity.json; otherwise the folder is removed).
// Every archive written leaves a build folder (com.apple.gpuarchiver/gpuarchiver-*, about 380 KB) that Metal never removes: par_write removes the one its own write made, and the
// app's own leftovers are removed at start. DM_PSO_ARCHIVE=0 turns it off. Included by nvn_mtl.m after MLOG, g_dev and pso_user_path.
#pragma once
#import <Metal/Metal.h>
#include <CommonCrypto/CommonDigest.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
#include "dmsh_chain.h"

static pthread_mutex_t g_par_mu = PTHREAD_MUTEX_INITIALIZER;
static NSMutableSet<NSString *> *g_par_have;                              // keys with a file
static NSMutableDictionary<NSString *, NSString *> *g_par_bmap;          // key → batch file name (pipelines/batches.tsv; 11-06, see par_write_batch)
static NSMutableDictionary<NSString *, id<MTLBinaryArchive>> *g_par_open; // opened (kept: Metal keeps their memory anyway)
static NSString *g_par_dir, *g_par_bdir;                                // g_par_bdir: the package's read-only archives (shaders/direct/pipelines, made at pack time)
static NSMutableSet<NSString *> *g_par_bhave;                             // keys with a package file
static int g_par_on;
// #756（iPad Pro M1、iOS 18.3.1：每次起局预热后，后台写管线归档时在 Metal 里 objc_retain 崩，之后每次打开都闪退）：写归档只是「下次起得快」的优化，
//   写不成不影响玩。每批写之前在归档目录留 .writing、写完删掉；起局发现它还在 = 上次进程死在写归档里 → 这台设备这个系统版本不再写（照常读已有的、照常编），
//   记一行黄字。标记留着不删，之后每次起局都不写；系统 / GPU / 翻译链一变，identity.json 对不上，整个目录连标记一起删掉、重新开写
static int g_par_nowrite;
#define PAR_WRITING @".writing"
static void par_check_dead_write(void) {   // 起局（打开归档目录时）调：上次进程死在写归档里 → 这个系统版本不再写
    if (![NSFileManager.defaultManager fileExistsAtPath:[g_par_dir stringByAppendingPathComponent:PAR_WRITING]]) return;
    g_par_nowrite = 1;
    MLOG("【黄】 pipeline archive: the last run died while writing it (#756: Metal crashed inside the archive writer on iOS 18): reading it as usual, writing nothing more on this OS version");
}
static const char *g_par_harvest;                                        // S2A_PSO_HARVEST: the folder the harvest writes into (nvn_pso_harvest); writes at once instead of noting
static _Atomic uint64_t g_par_hits, g_par_misses, g_par_written, g_par_write_failed, g_par_stale, g_par_ga_removed;
static __thread int par_write_in_place;                                  // the prewarm's threads: what they compile is noted for writing (par_flush_bg)
static NSMutableArray *g_par_todo;                                       // @[key, descriptor] noted by the prewarm, written beside it (par_writer)

static NSDictionary *par_identity(id<MTLDevice> dev) {
    return @{@"schema": @1, @"chain": @DMSH_CHAIN, @"gpu": dev.name ?: @"?", @"os": NSProcessInfo.processInfo.operatingSystemVersionString ?: @"?"};
}
static NSString *par_hash(const void *bytes, size_t n) {
    uint8_t d[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes, (CC_LONG)n, d);
    NSMutableString *s = [NSMutableString stringWithCapacity:40];
    for (int i = 0; i < 20; i++) [s appendFormat:@"%02x", d[i]];   // 160 bits name a file
    return s;
}
static NSString *par_file(NSString *key) { return [g_par_dir stringByAppendingFormat:@"/%@.metalarchive", key]; }
// Metal's archive build folders: com.apple.gpuarchiver under confstr's user cache folder and the Caches folder, each with and without the bundle id (iPhone: Library/Caches/<bundle
// id>/com.apple.gpuarchiver; confstr gives no path there). Folders under the bundle id are this app's own; the others are shared, and par_write removes only folders that appeared
// while it wrote (one write at a time, g_par_wmu)
static pthread_mutex_t g_par_wmu = PTHREAD_MUTEX_INITIALIZER;
static NSArray<NSDictionary *> *par_ga_dirs(void) {   // @{path, own}
    static NSArray *dirs; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *bases = [NSMutableArray array];
        char b[PATH_MAX]; if (confstr(_CS_DARWIN_USER_CACHE_DIR, b, sizeof b)) [bases addObject:@(b)];
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        if (caches) [bases addObject:caches];
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        NSMutableArray *out = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
        for (NSString *base in bases) for (int own = bundle.length ? 1 : 0; own >= 0; own--) {
            NSString *dir = [(own ? [base stringByAppendingPathComponent:bundle] : base) stringByAppendingPathComponent:@"com.apple.gpuarchiver"];
            dir = dir.stringByResolvingSymlinksInPath.stringByStandardizingPath;
            if (![seen containsObject:dir]) { [seen addObject:dir]; [out addObject:@{@"path": dir, @"own": @(own)}]; }
        }
        dirs = out;
    });
    return dirs;
}
// readdir, not NSFileManager: a bare Mac binary shares one folder with every other program (10-26 this Mac: 20,929 entries, 13 GB), and listing it twice per write through
//   NSFileManager made each write about a second (mhrise: 53 of 415 written in a minute)
#include <dirent.h>
static NSSet<NSString *> *par_ga_list(int own_only) {
    NSMutableSet *s = [NSMutableSet set];
    for (NSDictionary *d in par_ga_dirs()) {
        if (own_only && ![d[@"own"] boolValue]) continue;
        DIR *dp = opendir([d[@"path"] fileSystemRepresentation]); if (!dp) continue;
        struct dirent *e; NSString *base = d[@"path"];
        while ((e = readdir(dp))) if (!strncmp(e->d_name, "gpuarchiver-", 12)) [s addObject:[base stringByAppendingFormat:@"/%s", e->d_name]];
        closedir(dp);
    }
    return s;
}
// 跨进程锁：同一用户的裸二进制宿主共用一个 com.apple.gpuarchiver 目录（见上）。同时开几局（普查本机并行）时，A 写存档的「前后两次列目录」之间 B 正在建的
//   gpuarchiver-* 也算成 A 新建的被删掉，B 的序列化找不到自己的临时目录（11-01 普查 93 款里 12 款报 cannot remove、6 款报 cannot write …
//   Failed to generate machO: cannot pack / cannot read …/C//…），存档没写成、下一局重编。写存档整段（列目录、建、序列化、再列、删）在这把锁里串行，
//   前后两次列目录之间多出的只会是本进程的。锁文件放在第一个 gpuarchiver 目录的上一级（同一用户的宿主看到同一路径）；打不开锁照旧只用进程内锁
#include <sys/file.h>
static int par_ga_lock(void) {
    static int fd = -2; static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    if (fd == -2) { NSArray *d = par_ga_dirs(); fd = -1;
        if (d.count) { NSString *lp = [[d[0][@"path"] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"s2a-gpuarchiver.lock"]; fd = open(lp.fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC, 0644); }
        if (fd < 0) MLOG("pipeline archive: no cross-process lock for Metal's build folder (open failed): concurrent hosts may remove each other's folders"); }
    pthread_mutex_unlock(&mu);
    if (fd >= 0) while (flock(fd, LOCK_EX) != 0 && errno == EINTR) {}
    return fd;
}
static void par_ga_unlock(int fd) { if (fd >= 0) flock(fd, LOCK_UN); }
static void par_ga_remove_new(NSSet<NSString *> *before) {
    NSMutableSet<NSString *> *made = [par_ga_list(0) mutableCopy]; [made minusSet:before];
    for (NSString *path in made) {
        NSError *e = nil;
        if ([NSFileManager.defaultManager removeItemAtPath:path error:&e]) atomic_fetch_add(&g_par_ga_removed, 1);
        else { static _Atomic int said; if (atomic_fetch_add(&said, 1) < 4) MLOG("【红】 pipeline archive: cannot remove Metal's build folder %s: %s", path.UTF8String, e.localizedDescription.UTF8String); }
    }
}
// Once: the folder of this OS version, GPU and chain, and the keys it has files for
static void par_open_dir(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *ev = getenv("DM_PSO_ARCHIVE"); if (ev && !strcmp(ev, "0")) { MLOG("DM_PSO_ARCHIVE=0: no pipeline archive, every pipeline compiles"); return; }
        // The package's archives (pack time, shader line 10-26: one file per pipeline under the same key, made for the target GPU): looked up first, never removed or rewritten
        g_par_bhave = [NSMutableSet set];
        if (g_shmap_path && !g_par_harvest) {
            g_par_bdir = [g_shmap_path.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"pipelines"];
            for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:g_par_bdir error:nil] ?: @[]) if ([name hasSuffix:@".metalarchive"]) [g_par_bhave addObject:name.stringByDeletingPathExtension];
            if (g_par_bhave.count) MLOG("pipeline archive in the package %s: %lu pipelines", g_par_bdir.UTF8String, (unsigned long)g_par_bhave.count);
        }
        NSString *user = g_par_harvest ? nil : pso_user_path(); if (!user && !g_par_harvest) return;   // no save directory (unit tests): nowhere to keep it
        g_par_dir = g_par_harvest ? @(g_par_harvest) : [user.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"pipelines"];
        NSFileManager *fm = NSFileManager.defaultManager;
        dispatch_async(s2a_qos_global(S2A_QOS_IO_BG), ^{   // the app's own build folders left by earlier runs (a crash in a write)
            pthread_mutex_lock(&g_par_wmu); NSUInteger n = 0;
            for (NSString *path in par_ga_list(1)) if ([NSFileManager.defaultManager removeItemAtPath:path error:nil]) n++;
            pthread_mutex_unlock(&g_par_wmu);
            if (n) MLOG("pipeline archive: removed %lu build folders Metal left behind in earlier runs", (unsigned long)n);
        });
        NSString *stamp_path = [g_par_dir stringByAppendingPathComponent:@"identity.json"];
        NSData *sd = [NSData dataWithContentsOfFile:stamp_path];
        NSDictionary *stamp = sd ? [NSJSONSerialization JSONObjectWithData:sd options:0 error:nil] : nil;
        if (![stamp isEqual:par_identity(g_dev)] && [fm fileExistsAtPath:g_par_dir]) {
            if (stamp) MLOG("pipeline archive: the OS version, GPU or translation chain changed: removed, built again");
            [fm removeItemAtPath:g_par_dir error:nil];
        }
        [fm createDirectoryAtPath:g_par_dir withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSJSONSerialization dataWithJSONObject:par_identity(g_dev) options:NSJSONWritingSortedKeys error:nil] writeToFile:stamp_path atomically:YES];
        g_par_have = [NSMutableSet set]; g_par_open = [NSMutableDictionary dictionary]; uint64_t bytes = 0;
        for (NSString *name in [fm contentsOfDirectoryAtPath:g_par_dir error:nil] ?: @[]) if ([name hasSuffix:@".metalarchive"] && ![name hasPrefix:@"batch-"]) {
            [g_par_have addObject:name.stringByDeletingPathExtension];
            bytes += [[fm attributesOfItemAtPath:[g_par_dir stringByAppendingPathComponent:name] error:nil] fileSize];
        }
        // Batch files (par_write_batch): batches.tsv holds key → file, later lines win (a key written again after a miss); a line whose file is gone is skipped
        g_par_bmap = [NSMutableDictionary dictionary]; NSUInteger nb = 0;
        NSString *idx = [NSString stringWithContentsOfFile:[g_par_dir stringByAppendingPathComponent:@"batches.tsv"] encoding:NSUTF8StringEncoding error:nil];
        NSMutableSet *bfiles = [NSMutableSet set];
        for (NSString *ln in [idx componentsSeparatedByString:@"\n"]) {
            NSArray *c = [ln componentsSeparatedByString:@"\t"]; if (c.count != 2 || ![c[1] hasPrefix:@"batch-"]) continue;
            if (![bfiles containsObject:c[1]]) { if (![fm fileExistsAtPath:[g_par_dir stringByAppendingPathComponent:c[1]]]) continue; [bfiles addObject:c[1]]; }
            g_par_bmap[c[0]] = c[1]; [g_par_have addObject:c[0]];
        }
        for (NSString *f in bfiles) { bytes += [[fm attributesOfItemAtPath:[g_par_dir stringByAppendingPathComponent:f] error:nil] fileSize]; nb++; }
        par_check_dead_write();
        g_par_on = 1;
        MLOG("pipeline archive %s: %lu pipelines (%lu in %lu batch files, the rest one file each; %.1f MB), opened when used", g_par_dir.UTF8String, (unsigned long)g_par_have.count,
             (unsigned long)g_par_bmap.count, (unsigned long)nb, bytes / 1048576.0);
    });
}
static id<MTLBinaryArchive> par_bundle_for(NSString *key) {   // the package's file for this key, or nil (kept open like the device's)
    par_open_dir();
    if (!key || ![g_par_bhave containsObject:key]) return nil;
    NSString *k = [@"b/" stringByAppendingString:key];
    pthread_mutex_lock(&g_par_mu);
    id<MTLBinaryArchive> a = g_par_open[k];
    if (!a) {
        MTLBinaryArchiveDescriptor *d = [MTLBinaryArchiveDescriptor new]; d.url = [NSURL fileURLWithPath:[g_par_bdir stringByAppendingFormat:@"/%@.metalarchive", key]];
        a = [g_dev newBinaryArchiveWithDescriptor:d error:nil];
        if (a) g_par_open[k] = a; else [g_par_bhave removeObject:key];
    }
    pthread_mutex_unlock(&g_par_mu);
    return a;
}
static id<MTLBinaryArchive> par_archive_for(NSString *key) {
    par_open_dir();
    if (!g_par_on || !key) return nil;
    pthread_mutex_lock(&g_par_mu);
    id<MTLBinaryArchive> a = g_par_open[key];
    NSString *bf = a ? nil : g_par_bmap[key];
    if (bf) {   // in a batch file: one open archive per file, shared by its keys
        NSString *fk = [@"f/" stringByAppendingString:bf]; a = g_par_open[fk];
        if (!a) { MTLBinaryArchiveDescriptor *d = [MTLBinaryArchiveDescriptor new]; d.url = [NSURL fileURLWithPath:[g_par_dir stringByAppendingPathComponent:bf]];
                  a = [g_dev newBinaryArchiveWithDescriptor:d error:nil]; if (a) g_par_open[fk] = a; }
        if (a) g_par_open[key] = a; else { [g_par_bmap removeObjectForKey:key]; [g_par_have removeObject:key]; }
    } else if (!a && [g_par_have containsObject:key]) {
        MTLBinaryArchiveDescriptor *d = [MTLBinaryArchiveDescriptor new]; d.url = [NSURL fileURLWithPath:par_file(key)];
        NSError *e = nil; a = [g_dev newBinaryArchiveWithDescriptor:d error:&e];
        if (a) g_par_open[key] = a;
        else { [g_par_have removeObject:key]; [NSFileManager.defaultManager removeItemAtPath:par_file(key) error:nil]; }
    }
    pthread_mutex_unlock(&g_par_mu);
    return a;
}
static void par_drop(NSString *key) {   // its file did not give the pipeline (another package's libraries under the same key): written again by the next write
    pthread_mutex_lock(&g_par_mu); [g_par_open removeObjectForKey:key]; [g_par_have removeObject:key];
    BOOL batched = g_par_bmap[key] != nil; [g_par_bmap removeObjectForKey:key]; pthread_mutex_unlock(&g_par_mu);
    if (!batched) [NSFileManager.defaultManager removeItemAtPath:par_file(key) error:nil];   // a batch file holds others' pipelines: kept, the key is written again into a new one
    atomic_fetch_add(&g_par_stale, 1);
}
// One pipeline as its own file (a temporary name, then renamed)
static void par_write(NSString *key, id desc) {
    pthread_mutex_lock(&g_par_mu); BOOL have = [g_par_have containsObject:key]; pthread_mutex_unlock(&g_par_mu);
    if (have) return;
    NSError *e = nil; BOOL ok;
    NSString *path = par_file(key), *temp = [path stringByAppendingString:@".tmp"];
    pthread_mutex_lock(&g_par_wmu); int lk = par_ga_lock();   // 跨进程串行（见 par_ga_lock）
    NSSet<NSString *> *before = par_ga_list(0);
    @autoreleasepool {
        id<MTLBinaryArchive> a = [g_dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:&e];
        ok = a && ([desc isKindOfClass:MTLRenderPipelineDescriptor.class] ? [a addRenderPipelineFunctionsWithDescriptor:desc error:&e]
                                                                          : [a addComputePipelineFunctionsWithDescriptor:desc error:&e]);
        if (ok) ok = [a serializeToURL:[NSURL fileURLWithPath:temp] error:&e] && rename(temp.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
    }
    par_ga_remove_new(before);
    par_ga_unlock(lk); pthread_mutex_unlock(&g_par_wmu);
    if (!ok) { unlink(temp.fileSystemRepresentation);
               if (atomic_fetch_add(&g_par_write_failed, 1) < 4) MLOG("【红】 pipeline archive: cannot write %s: %s", path.UTF8String, e ? e.localizedDescription.UTF8String : "rename failed"); return; }
    pthread_mutex_lock(&g_par_mu); [g_par_have addObject:key]; pthread_mutex_unlock(&g_par_mu);
    atomic_fetch_add(&g_par_written, 1);
}
// The prewarm's misses go to one writer at utility QoS, started at the first one and running beside the prewarm, off the game's way (the next start takes them from the
//   archive). Not after the prewarm: 11-02 mhrise on an iPhone 17 Pro (thermal state serious) had the first frame wait 64 s for 12,741 of 17,630 lines and the rest 52 s more in
//   play; the writes after it (each compiles its pipeline once more) never finished before the app went to the background, and the runs before it ended before the prewarm did,
//   so every start found 0 in the archive and compiled all 17,630 again. Written as they come, whatever a run compiled is kept, however it ends
// Up to PAR_BATCH noted pipelines into one file (11-06 Mario Kart 8 Deluxe on an iPhone, prewarm list 19,077 lines: one file per pipeline wrote about 95 ms each — the
//   lock, two listings of Metal's build folders, a serialization and a 380 KB build folder per pipeline — so a run wrote 446 of 5,830 in 42.6 s, the rest were lost at exit and every
//   start compiled almost everything again behind the 15 s first-frame cap). Measured on this Mac (fresh pipelines): one per file 9.9–10.9 ms each, 32 per file 2.6–4.1 ms each;
//   opening a 32-pipeline file 1.24 ms (0.04 ms a pipeline, a one-pipeline file 0.22 ms), 64 already 4.3 ms and 200 34 ms (the cost that grows with the count, see the top)
#ifndef PAR_BATCH
#define PAR_BATCH 32   // 单测反证编 -DPAR_BATCH=1
#endif
static void par_write_batch(NSArray<NSArray *> *items) {
    NSMutableArray<NSArray *> *todo = [NSMutableArray array];
    pthread_mutex_lock(&g_par_mu); for (NSArray *it in items) if (![g_par_have containsObject:it[0]]) [todo addObject:it]; pthread_mutex_unlock(&g_par_mu);
    if (!todo.count) return;
    NSString *name = [NSString stringWithFormat:@"batch-%llx-%d.metalarchive", (unsigned long long)clock_gettime_nsec_np(CLOCK_REALTIME), getpid()];
    NSString *path = [g_par_dir stringByAppendingPathComponent:name], *temp = [path stringByAppendingString:@".tmp"];
    NSMutableArray<NSString *> *keys = [NSMutableArray array]; NSError *e = nil; BOOL ok = NO;
    pthread_mutex_lock(&g_par_wmu); int lk = par_ga_lock();
    NSSet<NSString *> *before = par_ga_list(0);
    // #756：写之前留标记、写完（成不成都算）删掉；进程死在这一段里，标记留下，下次起局就不再写
    const char *writing = [g_par_dir stringByAppendingPathComponent:PAR_WRITING].fileSystemRepresentation;
    { int fd = open(writing, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd >= 0) { (void)!write(fd, name.UTF8String, strlen(name.UTF8String)); fsync(fd); close(fd); } }
    @autoreleasepool {
        id<MTLBinaryArchive> a = [g_dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:&e];
        for (NSArray *it in todo) { NSError *e1 = nil; id desc = it[1];
            BOOL one = a && ([desc isKindOfClass:MTLRenderPipelineDescriptor.class] ? [a addRenderPipelineFunctionsWithDescriptor:desc error:&e1] : [a addComputePipelineFunctionsWithDescriptor:desc error:&e1]);
            if (one) [keys addObject:it[0]]; else { e = e1; atomic_fetch_add(&g_par_write_failed, 1); } }
        if (keys.count) ok = [a serializeToURL:[NSURL fileURLWithPath:temp] error:&e] && rename(temp.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
    }
    unlink(writing);
    par_ga_remove_new(before);
    if (ok) {   // the index after the file: a line always names a file that is there
        NSMutableString *lines = [NSMutableString string]; for (NSString *k in keys) [lines appendFormat:@"%@\t%@\n", k, name];
        FILE *f = fopen([g_par_dir stringByAppendingPathComponent:@"batches.tsv"].fileSystemRepresentation, "a");
        ok = f && fputs(lines.UTF8String, f) >= 0; if (f) ok = (fclose(f) == 0) && ok;
    }
    par_ga_unlock(lk); pthread_mutex_unlock(&g_par_wmu);
    if (!ok) { unlink(temp.fileSystemRepresentation);
               if (atomic_fetch_add(&g_par_write_failed, 1) < 4) MLOG("【红】 pipeline archive: cannot write the batch %s (%lu pipelines): %s", name.UTF8String, (unsigned long)keys.count, e ? e.localizedDescription.UTF8String : "rename or index failed"); return; }
    pthread_mutex_lock(&g_par_mu); for (NSString *k in keys) { g_par_bmap[k] = name; [g_par_have addObject:k]; } pthread_mutex_unlock(&g_par_mu);
    atomic_fetch_add(&g_par_written, keys.count);
}
static int g_par_writer;                                                 // the writer is running (g_par_mu)
static uint64_t g_par_w_t0, g_par_w_n0;
static void par_writer(void) { @autoreleasepool {
    for (;;) @autoreleasepool {
        pthread_mutex_lock(&g_par_mu);
        NSUInteger n = MIN(g_par_todo.count, (NSUInteger)PAR_BATCH); NSArray *batch = n ? [g_par_todo subarrayWithRange:NSMakeRange(0, n)] : nil;
        if (n) [g_par_todo removeObjectsInRange:NSMakeRange(0, n)]; else g_par_writer = 0;
        pthread_mutex_unlock(&g_par_mu);
        if (!batch) break;
        par_write_batch(batch);   // whatever is noted when the writer comes round, up to PAR_BATCH a file
    }
} }
static void par_note(NSString *key, id desc) {
    if (g_par_nowrite) return;   // #756：上次死在写归档里，这个系统版本不再写
    pthread_mutex_lock(&g_par_mu);
    if (!g_par_todo) g_par_todo = [NSMutableArray array];
    [g_par_todo addObject:@[key, desc]];
    int start = !g_par_writer; g_par_writer = 1;
    if (start && !g_par_w_t0) { g_par_w_t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); g_par_w_n0 = atomic_load(&g_par_written); }
    pthread_mutex_unlock(&g_par_mu);
    if (start) dispatch_async(s2a_qos_global(S2A_QOS_IO_BG), ^{ par_writer(); });
}
// After the prewarm: how far the writer is (it goes on until what the prewarm noted is written)
static void par_flush_bg(void) {
    pthread_mutex_lock(&g_par_mu); unsigned long left = (unsigned long)g_par_todo.count; uint64_t t0 = g_par_w_t0, n0 = g_par_w_n0; pthread_mutex_unlock(&g_par_mu);
    if (!t0) return;
    MLOG("pipeline archive: %llu pipelines the prewarm compiled written so far in %.1f s beside it, %lu still to write (Metal build folders removed so far %llu)",
         (unsigned long long)(atomic_load(&g_par_written) - n0), (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e9, left, (unsigned long long)atomic_load(&g_par_ga_removed));
}
static _Atomic uint64_t g_par_dedup, g_par_dedup_ns;   // 等了别人在编的同一条：次数、总等待
static void par_count(int hit) {
    uint64_t h = hit ? atomic_fetch_add(&g_par_hits, 1) + 1 : atomic_load(&g_par_hits), m = hit ? atomic_load(&g_par_misses) : atomic_fetch_add(&g_par_misses, 1) + 1;
    if (!((h + m) & (h + m - 1)) && h + m >= 256) MLOG("pipeline archive: %llu builds, %llu from the archive, %llu compiled; %llu written this run, %llu stale files rewritten; %llu waited for the same key another thread was building (%.1f ms in all)",
                                                      (unsigned long long)(h + m), (unsigned long long)h, (unsigned long long)m, (unsigned long long)atomic_load(&g_par_written), (unsigned long long)atomic_load(&g_par_stale),
                                                      (unsigned long long)atomic_load(&g_par_dedup), atomic_load(&g_par_dedup_ns) / 1e6);
}
// 在途去重（11-05 能耗线）：同一归档键同时只编一次。预热工人（warm_task，utility QoS）、提交线程（pso_get_ 首遇）、并行预编都经 par_render / par_compute；
//   原先各编各的：提交线程急用的那条若正被预热工人编着，它自己再编一遍，两份一起排编译服务（Switch2 线时之笛读数：与提交线程重复建同一条；
//   斯普拉遁3 c1104_r2 第 232 帧单条首用等待 36.7 s）。现在后到的等先到的那份、把自己的 QoS 借给它（同 flight_wait_locked），拿同一个管线对象（Metal 管线对象线程安全）；
//   先到的失败（nil）时后到的自己再编一次，取它自己的错误信息
@interface ParFlight : NSObject { @public dispatch_group_t done; id result; pthread_t builder; } @end
@implementation ParFlight @end
static NSMutableDictionary<NSString *, ParFlight *> *g_par_flights;
static os_unfair_lock g_par_fl_lock = OS_UNFAIR_LOCK_INIT;
// 进：有人在编同一键 → 等它编完返回 1、*out = 它的结果；否则登记本线程为编者、*mine = 本次的在途记录，返回 0
static int par_fl_enter(NSString *key, id *out, ParFlight **mine) {
    *mine = nil; *out = nil;
    if (!key) return 0;
    os_unfair_lock_lock(&g_par_fl_lock);
    ParFlight *f = g_par_flights[key];
    if (f) {
        pthread_override_t ov = f->builder && !pthread_equal(f->builder, pthread_self()) ? pthread_override_qos_class_start_np(f->builder, qos_class_self(), 0) : NULL;
        os_unfair_lock_unlock(&g_par_fl_lock);
        struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
        dispatch_group_wait(f->done, DISPATCH_TIME_FOREVER);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        if (ov) pthread_override_qos_class_end_np(ov);
        atomic_fetch_add(&g_par_dedup, 1); atomic_fetch_add(&g_par_dedup_ns, (uint64_t)((t1.tv_sec - t0.tv_sec) * 1000000000ll + (t1.tv_nsec - t0.tv_nsec)));
        *out = f->result; return 1;
    }
    f = [ParFlight new]; f->done = dispatch_group_create(); dispatch_group_enter(f->done); f->builder = pthread_self();
    if (!g_par_flights) g_par_flights = [NSMutableDictionary dictionary];
    g_par_flights[key] = f; *mine = f;
    os_unfair_lock_unlock(&g_par_fl_lock);
    return 0;
}
static void par_fl_leave(NSString *key, ParFlight *mine, id result) {   // 编者编完：登记结果、摘掉在途、放行等它的
    if (!mine) return;
    os_unfair_lock_lock(&g_par_fl_lock); mine->result = result; [g_par_flights removeObjectForKey:key]; os_unfair_lock_unlock(&g_par_fl_lock);
    dispatch_group_leave(mine->done);
}
static id<MTLRenderPipelineState> par_render_(MTLRenderPipelineDescriptor *d, NSString *key, NSError **e);
static id<MTLComputePipelineState> par_compute_(id<MTLFunction> fn, NSString *key, NSError **e);
// A pipeline build that is still running after PAR_SLOW_MS says so, with its archive key, its functions (s<MSL digest>_<entry>: the package maps the digest to the shader key) and the building thread (11-05 Switch 2 Ocarina of Time, test device 2: the submit
//   thread stood inside a compute pipeline build for over 30 s on the first gameplay frame, and nothing in the log named the shader, because a build is logged only when it
//   returns). The note fires from a timer while the build still runs; a build that took longer than PAR_SLOW_MS also logs its time when it returns, and whether it built or failed (11-05: a compile the system killed at its 150 MB limit returned nil after 8.4 s and read as built). Nothing else changes.
enum { PAR_SLOW_MS = 5000 };
typedef struct { _Atomic int done; char key[96]; char kind[8]; char thread[32]; char fns[160]; uint64_t t0; } ParSlow;
static ParSlow *par_slow_begin(NSString *key, const char *kind, NSString *fns) {
    ParSlow *w = calloc(1, sizeof *w); if (!w) return NULL;
    snprintf(w->key, sizeof w->key, "%s", key ? key.UTF8String : "-"); snprintf(w->kind, sizeof w->kind, "%s", kind); snprintf(w->fns, sizeof w->fns, "%s", fns ? fns.UTF8String : "-");
    pthread_getname_np(pthread_self(), w->thread, sizeof w->thread); w->t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    atomic_store(&w->done, 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)PAR_SLOW_MS * 1000000), s2a_qos_global(S2A_QOS_IO_BG), ^{
        if (atomic_exchange(&w->done, 2) == 1) { free(w); return; }   // the build returned first: its end freed nothing and left the memory to this block
        MLOG("【红】 %s pipeline %s (functions %s) still compiling after %d ms on thread %s", w->kind, w->key, w->fns, PAR_SLOW_MS, w->thread[0] ? w->thread : "?");
    });
    return w;
}
static void par_slow_end(ParSlow *w, int ok) {
    if (!w) return;
    double ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - w->t0) / 1e6;
    if (ms >= PAR_SLOW_MS) MLOG("%s%s pipeline %s (functions %s) %s after %.0f ms on thread %s", ok ? "" : "【红】 ", w->kind, w->key, w->fns, ok ? "built" : "FAILED", ms, w->thread[0] ? w->thread : "?");
    if (atomic_exchange(&w->done, 1) == 2) free(w);   // the timer already ran: the memory is the end's to free
}
// Build a render pipeline through the archive. key = par_rkey(...), nil = not archived (built as before)
static id<MTLRenderPipelineState> par_render(MTLRenderPipelineDescriptor *d, NSString *key, NSError **e) {
    id got; ParFlight *mine;
    if (par_fl_enter(key, &got, &mine) && got) return got;
    ParSlow *sw = par_slow_begin(key, "render", [NSString stringWithFormat:@"%@ %@", d.vertexFunction.name ?: @"-", d.fragmentFunction.name ?: @"-"]);
    id<MTLRenderPipelineState> ps = par_render_(d, key, e);
    par_slow_end(sw, ps != nil);
    par_fl_leave(key, mine, ps);
    return ps;
}
static id<MTLComputePipelineState> par_compute(id<MTLFunction> fn, NSString *key, NSError **e) {
    if (!fn) return nil;
    id got; ParFlight *mine;
    if (par_fl_enter(key, &got, &mine) && got) return got;
    ParSlow *sw = par_slow_begin(key ? key : fn.name, "compute", fn.name);
    id<MTLComputePipelineState> ps = par_compute_(fn, key, e);
    par_slow_end(sw, ps != nil);
    par_fl_leave(key, mine, ps);
    return ps;
}
static id<MTLRenderPipelineState> par_render_(MTLRenderPipelineDescriptor *d, NSString *key, NSError **e) {
    id<MTLBinaryArchive> b = par_bundle_for(key);
    if (b) {   // a miss (another OS / GPU than the package was made for) is no error: the device's archive and the compiler follow
        d.binaryArchives = @[b];
        id<MTLRenderPipelineState> ps = [g_dev newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:nil];
        d.binaryArchives = nil;
        if (ps) { par_count(1); return ps; }
    }
    id<MTLBinaryArchive> a = par_archive_for(key);
    if (a) {
        d.binaryArchives = @[a];
        id<MTLRenderPipelineState> ps = [g_dev newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:nil];
        d.binaryArchives = nil;
        if (ps) { par_count(1); return ps; }
        par_drop(key);
    }
    if (key && g_par_on) par_count(0);
    id<MTLRenderPipelineState> ps = [g_dev newRenderPipelineStateWithDescriptor:d error:e];
    if (ps && key && g_par_on && par_write_in_place) { if (g_par_harvest) par_write(key, d); else par_note(key, d); }
    return ps;
}
static id<MTLComputePipelineState> par_compute_(id<MTLFunction> fn, NSString *key, NSError **e) {
    MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new]; d.computeFunction = fn;
    id<MTLBinaryArchive> b = par_bundle_for(key);
    if (b) {
        d.binaryArchives = @[b];
        id<MTLComputePipelineState> ps = [g_dev newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:nil];
        d.binaryArchives = nil;
        if (ps) { par_count(1); return ps; }
    }
    id<MTLBinaryArchive> a = par_archive_for(key);
    if (a) {
        d.binaryArchives = @[a];
        id<MTLComputePipelineState> ps = [g_dev newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:nil];
        d.binaryArchives = nil;
        if (ps) { par_count(1); return ps; }
        par_drop(key);
    }
    if (key && g_par_on) par_count(0);
    id<MTLComputePipelineState> ps = [g_dev newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionNone reflection:nil error:e];
    if (ps && key && g_par_on && par_write_in_place) { if (g_par_harvest) par_write(key, d); else par_note(key, d); }
    return ps;
}
