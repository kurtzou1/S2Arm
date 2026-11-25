// 云端管线种子（11-25）：手机直导 .s2arm 的款不经电脑出包，包里的预热种子表是导出那一刻的（常为只有表头的空表），首局场景里的管线全在提交线程现编、卡顿。
//   电脑出包时会把云端统一包里这款的管线种子并进随包种子表（pack/jobs/patches.py seed_sources → pack/stage_direct_seed.sh）；手机直导没有这一步，这里补上：
//   导入这一款 / 开局时，按程序号取下载站 g/<程序号>.json.gz（同 pack/jobs/patches.py 的统一包），收其中 kind = pso 的条目（每条核 sha256），
//   原样拼成 <各款文档>/wire/<程序号>/pso_cloud.tsv（与本机清单 pso_user.tsv 同目录、同行格式），宿主预热时作第二张清单读
//   （graphics/nvn/gfx/nvn/nvn_mtl.m warm_paths；别的版本的键、旧结构的行由 warm_parse 按本包库滤掉，第 1 代键经 key_alias.tsv 换代）。
//   云端这款没有种子（包不存在 / 没有 pso 条目）：写一张只有表头的表记下「问过了」，开局不再每次去问；导入时总是重取（新导入的包可能换了版本）。
//   联网失败 / 内容核不过：什么都不写（已有的表留着），只记日志，开局照常。不在后台批量取：只取导入的、点开的这一款。
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <zlib.h>
#include "cloud_seed.h"

#ifndef S2A_UNIT_TEST
#include "../runtime/src/native.h"
#else
#define LOG(...) do { fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)
#endif

static NSString *const kBase = @"https://dl.s2arm.com/patches/v2";   // 同 pack/jobs/patches.py BASE
static const NSUInteger kMaxBytes = 4u << 20;                           // 同 pack/jobs/patches.py MAX_BYTES（压缩后）

static NSString *hex_sha256(NSData *d) {
    unsigned char h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *s = [NSMutableString stringWithCapacity:sizeof h * 2];
    for (size_t i = 0; i < sizeof h; i++) [s appendFormat:@"%02x", h[i]];
    return s;
}

static NSData *gunzip(NSData *gz) {
    if (gz.length < 18) return nil;
    z_stream z; memset(&z, 0, sizeof z);
    if (inflateInit2(&z, 16 + MAX_WBITS) != Z_OK) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:gz.length * 4];
    z.next_in = (Bytef *)gz.bytes; z.avail_in = (uInt)gz.length;
    int r = Z_OK;
    while (r == Z_OK) {
        if (z.total_out >= out.length) { if (out.length >= 64u << 20) break; out.length *= 2; }   // 解开后至多 64 MB：种子条目是文本，远小于这个
        z.next_out = (Bytef *)out.mutableBytes + z.total_out; z.avail_out = (uInt)(out.length - z.total_out);
        r = inflate(&z, Z_NO_FLUSH);
    }
    uLong n = z.total_out; inflateEnd(&z);
    if (r != Z_STREAM_END) return nil;
    out.length = n; return out;
}

int s2a_cloud_seed_build(NSData *gz, const char *gid, NSData **out, int *items) {
    *out = nil; *items = 0;
    NSData *raw = gunzip(gz); if (!raw) return -1;
    id doc = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
    if (![doc isKindOfClass:NSDictionary.class] || ![doc[@"items"] isKindOfClass:NSArray.class]) return -1;
    NSMutableData *tsv = [NSMutableData data];
    [tsv appendData:[[NSString stringWithFormat:@"# Cloud pipeline seed for %s (download site g/%s.json.gz, pso items; rows as in pso_user.tsv)\n", gid, gid] dataUsingEncoding:NSUTF8StringEncoding]];
    for (NSDictionary *it in doc[@"items"]) {
        if (![it isKindOfClass:NSDictionary.class] || ![it[@"kind"] isEqual:@"pso"] || ![it[@"data"] isKindOfClass:NSString.class]) continue;
        NSData *d = [[NSData alloc] initWithBase64EncodedString:it[@"data"] options:0];
        if (!d || ![hex_sha256(d) isEqual:it[@"sha256"]]) { LOG("【黄】云端管线种子：%s 的一条（%s）内容核不过 sha256，不收", gid, [it[@"id"] description].UTF8String); continue; }
        [tsv appendData:d];
        if (d.length && ((const char *)d.bytes)[d.length - 1] != '\n') [tsv appendBytes:"\n" length:1];
        (*items)++;
    }
    *out = tsv; return 0;
}

// 各款文档 = <容器 Documents>/games/<程序号>（pack_apply.c 同拼法），宿主 wire/<程序号> 按 %016llX 大写（graphics/nvn/host_adapt.m）
static NSString *seed_path(const char *docs, NSString *g) {
    return [NSString stringWithFormat:@"%s/games/%@/wire/%@/pso_cloud.tsv", docs, g, g];
}

static BOOL write_atomic(NSString *path, NSData *d) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    return [d writeToFile:path options:NSDataWritingAtomic error:nil];   // 先写临时文件再改名：宿主读到的要么是整张旧表、要么是整张新表
}

void s2a_cloud_seed_fetch(const char *docs, const char *gid, int force) {
    if (!docs || !*docs || !gid || strlen(gid) != 16) return;
    NSString *g = @(gid).uppercaseString, *path = seed_path(docs, g);
    BOOL dir = NO;   // 只给多款容器里的款（<Documents>/games/<程序号> 在）：单款 App 由电脑出包，种子已随包，宿主也不读这个位置
    if (![NSFileManager.defaultManager fileExistsAtPath:[NSString stringWithFormat:@"%s/games/%@", docs, g] isDirectory:&dir] || !dir) return;
    if (!force && [NSFileManager.defaultManager fileExistsAtPath:path]) return;
    const char *b = getenv("S2A_PATCH_BASE");   // 同 pack/jobs/patches.py：换来源（单测指本地目录 file://）
    NSString *base = b && *b ? @(b) : kBase;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/g/%@.json.gz", base, g]];
    if (!url) return;
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.timeoutIntervalForRequest = 10; cfg.timeoutIntervalForResource = 30;
    NSURLSession *s = [NSURLSession sessionWithConfiguration:cfg];
    NSString *gs = g;
    [[s dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *e) {
        NSInteger st = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : (data ? 200 : 0);
        if (st == 404) {   // 下载站没有这款的包 = 云端没有种子
            NSData *none = [[NSString stringWithFormat:@"# Cloud pipeline seed for %@: the download site has none\n", gs] dataUsingEncoding:NSUTF8StringEncoding];
            BOOL ok = write_atomic(path, none);
            LOG("云端管线种子：%s 下载站没有（HTTP %ld）%s", gs.UTF8String, (long)st, ok ? "，记下不再每局去问" : "；【红】记录写不进");
            return;
        }
        if (e || st != 200 || !data) { LOG("云端管线种子：%s 没取到（%s），开局照常，首遇的管线现编", gs.UTF8String, e ? e.localizedDescription.UTF8String : [NSString stringWithFormat:@"HTTP %ld", (long)st].UTF8String); return; }
        if (data.length > kMaxBytes) { LOG("【黄】云端管线种子：%s 的包 %lu 字节超过上限，不收", gs.UTF8String, (unsigned long)data.length); return; }
        NSData *tsv = nil; int n = 0;
        if (s2a_cloud_seed_build(data, gs.UTF8String, &tsv, &n)) { LOG("【黄】云端管线种子：%s 的包解不开，不收", gs.UTF8String); return; }
        BOOL ok = write_atomic(path, tsv);
        LOG("云端管线种子：%s 收 %d 条（%lu 字节）%s %s", gs.UTF8String, n, (unsigned long)tsv.length, ok ? "→" : "【红】写不进", path.UTF8String);
    }] resume];
    [s finishTasksAndInvalidate];
}
