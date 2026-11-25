// 云端管线种子（ios/cloud_seed.m）单测：统一包 g/<号>.json.gz → pso_cloud.tsv。下载站换成本地目录（S2A_PATCH_BASE=file://…），不联网。
//   ① 只收 kind = pso 且 sha256 对得上的条目，原样拼接（缺行尾补换行），金手指等别类不收 ② 取到写进 <docs>/games/<号>/wire/<号>/pso_cloud.tsv
//   ③ 表已在、开局（force 0）不重取；导入（force 1）重取 ④ 不是多款容器里的款（games/<号> 不在）不取 ⑤ 解不开的包不写
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <zlib.h>
#include <unistd.h>
#include "cloud_seed.h"

#define CHECK(...) do { if (!(__VA_ARGS__)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #__VA_ARGS__); exit(1); } } while (0)

static NSString *sha(NSData *d) {
    unsigned char h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *s = [NSMutableString string]; for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", h[i]]; return s;
}
static NSData *gz(NSData *raw) {
    z_stream z; memset(&z, 0, sizeof z); CHECK(deflateInit2(&z, 6, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY) == Z_OK);
    NSMutableData *o = [NSMutableData dataWithLength:raw.length + 1024];
    z.next_in = (Bytef *)raw.bytes; z.avail_in = (uInt)raw.length; z.next_out = o.mutableBytes; z.avail_out = (uInt)o.length;
    CHECK(deflate(&z, Z_FINISH) == Z_STREAM_END); o.length = z.total_out; deflateEnd(&z); return o;
}
static NSDictionary *item(NSString *kind, NSString *text, BOOL good) {
    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
    return @{@"kind": kind, @"id": [sha(d) substringToIndex:16], @"data": [d base64EncodedStringWithOptions:0], @"sha256": good ? sha(d) : [@"0" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0]};
}
static NSString *wait_file(NSString *p, NSString *unlike) {   // 后台取：等文件出现（或内容变了），至多 10 秒
    for (int i = 0; i < 200; i++) {
        NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (s && ![s isEqual:unlike]) return s;
        usleep(50000);
    }
    return nil;
}

int main(void) { @autoreleasepool {
    NSString *G = @"0100A3501946E000";
    NSString *a = @"C\td50c4ec744149865_b\nR\t3138\n", *b = @"S\tab12cd34ef567890_b\t1";   // b 没有行尾换行
    NSString *head = [NSString stringWithFormat:@"# Cloud pipeline seed for %@ (download site g/%@.json.gz, pso items; rows as in pso_user.tsv)\n", G, G];
    NSString *want = [NSString stringWithFormat:@"%@%@%@\n", head, a, b];   // 好的两条原样拼接，b 补换行；坏 sha 与金手指不收
    NSDictionary *doc = @{@"schema": @2, @"key": [@"g/" stringByAppendingString:G], @"items": @[item(@"pso", a, YES), item(@"cheat", @"[x]\n04000000 0 0\n", YES), item(@"pso", @"R\tdeadbeef\n", NO), item(@"pso", b, YES)]};
    NSData *pack = gz([NSJSONSerialization dataWithJSONObject:doc options:0 error:nil]);

    // ① 纯函数
    NSData *out = nil; int n = -1;
    CHECK(s2a_cloud_seed_build(pack, G.UTF8String, &out, &n) == 0);
    CHECK(n == 2);
    CHECK([[[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] isEqual:want]);
    CHECK(s2a_cloud_seed_build([@"not gzip at all, not gzip" dataUsingEncoding:NSUTF8StringEncoding], G.UTF8String, &out, &n) == -1 && !out);

    // 本地下载站 + 容器
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_cloud_seed_%d", getpid()]];
    NSFileManager *fm = NSFileManager.defaultManager; [fm removeItemAtPath:root error:nil];
    NSString *site = [root stringByAppendingPathComponent:@"site"], *docs = [root stringByAppendingPathComponent:@"Documents"];
    CHECK([fm createDirectoryAtPath:[site stringByAppendingPathComponent:@"g"] withIntermediateDirectories:YES attributes:nil error:nil]);
    CHECK([pack writeToFile:[NSString stringWithFormat:@"%@/g/%@.json.gz", site, G] atomically:YES]);
    setenv("S2A_PATCH_BASE", [NSURL fileURLWithPath:site].absoluteString.UTF8String, 1);
    NSString *seed = [NSString stringWithFormat:@"%@/games/%@/wire/%@/pso_cloud.tsv", docs, G, G];

    // ④ games/<号> 不在：不取
    s2a_cloud_seed_fetch(docs.UTF8String, G.UTF8String, 1); usleep(500000);
    CHECK(![fm fileExistsAtPath:seed]);

    // ② 多款容器里的款：取到写进 wire/<号>/pso_cloud.tsv（程序号小写传入也落到大写目录）
    CHECK([fm createDirectoryAtPath:[NSString stringWithFormat:@"%@/games/%@", docs, G] withIntermediateDirectories:YES attributes:nil error:nil]);
    s2a_cloud_seed_fetch(docs.UTF8String, G.lowercaseString.UTF8String, 0);
    CHECK([wait_file(seed, nil) isEqual:want]);

    // ③ 表已在：开局不重取；导入重取
    CHECK([@"# local\n" writeToFile:seed atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    s2a_cloud_seed_fetch(docs.UTF8String, G.UTF8String, 0); usleep(500000);
    CHECK([[NSString stringWithContentsOfFile:seed encoding:NSUTF8StringEncoding error:nil] isEqual:@"# local\n"]);
    s2a_cloud_seed_fetch(docs.UTF8String, G.UTF8String, 1);
    CHECK([wait_file(seed, @"# local\n") isEqual:want]);

    // ⑤ 包坏了：已有的表留着
    CHECK([[@"broken" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[NSString stringWithFormat:@"%@/g/%@.json.gz", site, G] atomically:YES]);
    s2a_cloud_seed_fetch(docs.UTF8String, G.UTF8String, 1); usleep(800000);
    CHECK([[NSString stringWithContentsOfFile:seed encoding:NSUTF8StringEncoding error:nil] isEqual:want]);

    [fm removeItemAtPath:root error:nil];
    printf("✓ t_cloud_seed：只收核过 sha256 的管线种子条目、写进各款 wire 目录、开局不重取 / 导入重取、单款不取、坏包不覆盖（联网与 404「没有」由真机局核）\n");
    return 0;
} }
