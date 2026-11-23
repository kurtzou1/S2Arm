// 起局按款重签（ios/program_resign.m s2a_program_resign_if_needed）单测，Mac 上跑：钥匙串换成桩（openssl 现生成的自签名证书，不碰本机钥匙串）。
//   期望值不靠被测实现：新版本目录名按单测自己对新程序库算的 SHA-256；签名身份用系统 codesign -dvvv 读「Authority=」。
//   ① 没签名的程序包 → 1：清单 dir 指新目录 v-<sha16>-phone、signer.by=phone / cert_sha1=当前、source_sha256=原 image_sha256；随行目录拷过去；旧版本目录原样
//   ② 再起一次 → 0（签名身份已是这张）③ 没有 identity/current.json → 0 ④ 清单 team 与当前团队相同、没写 signer（电脑按同团队签好）→ 0
//   ⑤ 钥匙串里没有身份 → -1，清单不动
//   ⑦ 在 LiveContainer 里（#63639b，s2a_lc_cert 换成桩交测试 p12）：不要 current.json、不看本包描述文件（给的是别的团队），用 LiveContainer 的证书重签：
//     signer.cert_sha1 = 测试证书 DER 的 SHA-1、team = 证书主体 OU、via = livecontainer、codesign 读到测试身份；⑦b 再起 → 0；⑦c LiveContainer 没导入证书 → -1、清单不动、原因提 LiveContainer
//   签名标识：LiveContainer 直接证书与备用证书都取宿主包名；普通安装或宿主对象缺失时沿用原程序库标识。
//   ⑥ App 描述文件的团队（侧载工具装的、别的 Apple ID）≠ 手机身份的团队 → -1，不签（清单不动），原因写出两个团队号；⑥b 团队相同 → 照常签（1）
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "s2a_t_result.h"

int s2a_selfsign_identity(const void *p12, size_t n, const char *password, SecKeyRef *key, CFArrayRef *chain);
int s2a_program_resign_if_needed(const char *home, const char *game_data, const char *gid, char *module_dir, char *images, size_t n, char *why, size_t why_n);
void s2a_program_resign_test_identity(int (*f)(const char *, SecKeyRef *, SecCertificateRef *));
void s2a_program_resign_test_prov(int (*f)(char *, size_t, char *, size_t));
void s2a_lc_cert_test(int (*f)(NSData **, NSString **));
int s2a_program_resign_force(const char *home, const char *game_data, const char *gid, char *module_dir, char *images, size_t n, char *why, size_t why_n);
int s2a_bundle_image_resign_lc(const char *home, const char *game_data, const char *gid, char *images, size_t n, char *why, size_t why_n);

static int bad;
static void ck(int ok, NSString *what) { printf("%s %s\n", ok ? "  通" : "  【红】", what.UTF8String); if (!ok) bad++; }
static SecKeyRef g_key; static SecCertificateRef g_cert;
static int id_ok(const char *sha, SecKeyRef *k, SecCertificateRef *c) { (void)sha; *k = (SecKeyRef)CFRetain(g_key); *c = (SecCertificateRef)CFRetain(g_cert); return 0; }
static int id_none(const char *sha, SecKeyRef *k, SecCertificateRef *c) { (void)sha; (void)k; (void)c; return -1; }
static int prov_other(char *t, size_t tn, char *a, size_t an) { snprintf(t, tn, "FGHIJ67890"); snprintf(a, an, "FGHIJ67890.io.s2arm.games.FGHIJ67890"); return 0; }   // AltStore 装的 App：别的团队
static int prov_same(char *t, size_t tn, char *a, size_t an) { snprintf(t, tn, "ABCDE12345"); snprintf(a, an, "ABCDE12345.io.s2arm.games.ABCDE12345"); return 0; }
static NSData *g_p12;
static NSBundle *g_host_bundle;
@interface NSUserDefaults (S2ALCHostFixture)
+ (NSBundle *)lcMainBundle;
@end
@implementation NSUserDefaults (S2ALCHostFixture)
+ (NSBundle *)lcMainBundle { return g_host_bundle; }
@end
static int lc_ok(NSData **p, NSString **w) { if (p) *p = g_p12; if (w) *w = @"t"; return 1; }
static int lc_nocert(NSData **p, NSString **w) { (void)p; (void)w; return -1; }
static int lc_none(NSData **p, NSString **w) { (void)p; (void)w; return 0; }   // 不在 LiveContainer 里
static int lc_garbled(NSData **p, NSString **w) { if (p) *p = [@"not a p12" dataUsingEncoding:NSUTF8StringEncoding]; if (w) *w = @"t"; return 1; }   // LiveContainer 存了证书、系统解不开（#502 的 -26275）
static NSString *sha_file(NSString *p) { NSData *d = [NSData dataWithContentsOfFile:p]; uint8_t h[32]; CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *s = [NSMutableString string]; for (int i = 0; i < 32; i++) [s appendFormat:@"%02x", h[i]]; return s; }
static NSString *sha1_file(NSString *p) { NSData *d = [NSData dataWithContentsOfFile:p]; uint8_t h[20]; CC_SHA1(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *s = [NSMutableString string]; for (int i = 0; i < 20; i++) [s appendFormat:@"%02x", h[i]]; return s; }
static NSDictionary *json(NSString *p) { return [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:p] options:0 error:nil]; }
static void put_json(NSString *p, NSDictionary *o) { [[NSJSONSerialization dataWithJSONObject:o options:0 error:nil] writeToFile:p atomically:YES]; }
static NSString *sh(NSString *cmd) { NSTask *t = [NSTask new]; t.launchPath = @"/bin/sh"; t.arguments = @[@"-c", cmd]; NSPipe *p = [NSPipe pipe]; t.standardOutput = p; t.standardError = p;
    [t launch]; [t waitUntilExit]; return [[NSString alloc] initWithData:[p.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding]; }

int main(void) { @autoreleasepool {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_program_resign.%d", getpid()]];
    NSFileManager *fm = NSFileManager.defaultManager; [fm removeItemAtPath:dir error:nil]; [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    // openssl 用测试自带的最小配置：不依赖本机 openssl.cnf（一台门禁机的 Homebrew openssl 缺配置文件，req 直接失败、整组红）
    { NSString *cnf = [dir stringByAppendingPathComponent:@"openssl.cnf"]; [@"[req]\ndistinguished_name = dn\n[dn]\n" writeToFile:cnf atomically:YES encoding:NSUTF8StringEncoding error:nil]; setenv("OPENSSL_CONF", cnf.fileSystemRepresentation, 1); }
    NSString *G = @"0100ABCDE0000000", *home = [dir stringByAppendingPathComponent:@"home"];
    NSString *gd = [home stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Application Support/S2Arm/games/%@/资源包", G]];
    NSString *prog = [[gd stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"program"], *v0 = [prog stringByAppendingPathComponent:@"v-0000000000000000-pc"];
    NSString *img = [NSString stringWithFormat:@"S2AImages-%@.dylib", G], *idir = [home stringByAppendingPathComponent:@"Library/Application Support/S2Arm/identity"];
    [fm createDirectoryAtPath:gd withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[v0 stringByAppendingPathComponent:[@"Games" stringByAppendingPathComponent:G]] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:idir withIntermediateDirectories:YES attributes:nil error:nil];
    [@"companion" writeToFile:[v0 stringByAppendingPathComponent:[NSString stringWithFormat:@"Games/%@/x.txt", G]] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *prep = [NSString stringWithFormat:@"cd '%@' && printf 'int f(void){return 1;}' > a.c && cc -arch arm64 -dynamiclib -o '%@/%@' a.c && codesign -f -s - '%@/%@' 2>/dev/null"
        " && openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=t_program_resign/OU=ABCDE12345' -addext 'keyUsage=critical,digitalSignature' -addext 'extendedKeyUsage=critical,codeSigning'"
        " -keyout k.pem -out c.pem 2>/dev/null && openssl pkcs12 -export -inkey k.pem -in c.pem -out id.p12 -passout pass:t -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null"
        " && openssl x509 -in c.pem -outform DER -out c.der && echo OK", dir, v0, img, v0, img];
    ck([sh(prep) containsString:@"OK"], @"备好 ad-hoc 程序库、测试证书");
    NSString *original_description = sh([NSString stringWithFormat:@"codesign -dvvv '%@/%@' 2>&1", v0, img]);
    NSString *original_identifier = nil;
    for (NSString *line in [original_description componentsSeparatedByString:@"\n"])
        if ([line hasPrefix:@"Identifier="]) original_identifier = [line stringByAppendingString:@"\n"];
    NSData *p12 = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"id.p12"]]; CFArrayRef chain = NULL;
    ck(p12 && !s2a_selfsign_identity(p12.bytes, p12.length, "t", &g_key, &chain) && chain, @"导入测试身份");
    g_cert = (SecCertificateRef)CFRetain(CFArrayGetValueAtIndex(chain, 0)); CFRelease(chain);
    NSString *cur_sha = sha1_file([dir stringByAppendingPathComponent:@"c.der"]), *src_sha = sha_file([v0 stringByAppendingPathComponent:img]);
    NSString *catp = [prog stringByAppendingPathComponent:@"catalogue.json"];
    NSDictionary *cat0 = @{@"schema": @1, @"title_id": G, @"image": img, @"image_sha256": src_sha, @"team": NSNull.null, @"dir": @"v-0000000000000000-pc"};
    put_json(catp, cat0); put_json([idir stringByAppendingPathComponent:@"current.json"], @{@"schema": @1, @"team": @"ABCDE12345", @"cert_sha1": cur_sha});
    s2a_program_resign_test_identity(id_ok);
    char md[1024], im[1024], why[300];
#define ARGS() snprintf(md, sizeof md, "%s/Games/%s", v0.fileSystemRepresentation, G.UTF8String), snprintf(im, sizeof im, "%s/%s", v0.fileSystemRepresentation, img.UTF8String)
    ARGS(); int rc = s2a_program_resign_if_needed(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, md, im, sizeof md, why, sizeof why);
    NSDictionary *c1 = json(catp); NSString *newdir = c1[@"dir"], *v1 = [prog stringByAppendingPathComponent:newdir ?: @"?"], *nsha = sha_file([v1 stringByAppendingPathComponent:img]);
    NSString *auth = sh([NSString stringWithFormat:@"codesign -dvvv '%@/%@' 2>&1", v1, img]);
    ck(original_identifier.length && [auth containsString:original_identifier], @"普通安装：签名标识沿用原程序库（codesign 原件作参照）");
    ck(rc == 1 && [newdir isEqualToString:[NSString stringWithFormat:@"v-%@-phone", [nsha substringToIndex:16]]] && [c1[@"image_sha256"] isEqualToString:nsha],
       [NSString stringWithFormat:@"① 没签名 → 重签：返回 %d，清单 dir %@（期望 v-<新程序库 sha 前 16 位>-phone）", rc, newdir]);
    ck([c1[@"signer"][@"by"] isEqual:@"phone"] && [c1[@"signer"][@"cert_sha1"] isEqual:cur_sha] && [c1[@"source_sha256"] isEqual:src_sha], @"① signer.by=phone、cert_sha1=当前证书、source_sha256=原 image_sha256");
    ck([auth containsString:@"Authority=t_program_resign"], @"① 新程序库是测试身份签的（codesign 读 Authority）");
    ck(!strcmp(im, [v1 stringByAppendingPathComponent:img].fileSystemRepresentation) && [fm fileExistsAtPath:[v1 stringByAppendingPathComponent:[NSString stringWithFormat:@"Games/%@/x.txt", G]]],
       @"① 返回的程序库路径指新目录、随行目录拷过去了");
    ck([sha_file([v0 stringByAppendingPathComponent:img]) isEqualToString:src_sha], @"① 旧版本目录原样（这局可能还开着）");
    rc = s2a_program_resign_if_needed(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, md, im, sizeof md, why, sizeof why);
    ck(rc == 0 && [json(catp)[@"dir"] isEqualToString:newdir], [NSString stringWithFormat:@"② 再起一次：返回 %d（期望 0），清单不变", rc]);
    // ②b 注册签名失败时强制重签（证书与手机身份相同、签名格式老）：不看「已是这张」照样重签，出新版本目录（签名时间不同 → 内容不同），随行目录跟过去
    sleep(1); rc = s2a_program_resign_force(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, md, im, sizeof md, why, sizeof why);
    { NSString *d2 = json(catp)[@"dir"];
      ck(rc == 1 && d2 && ![d2 isEqualToString:newdir] && [fm fileExistsAtPath:[[prog stringByAppendingPathComponent:d2] stringByAppendingPathComponent:[NSString stringWithFormat:@"Games/%@/x.txt", G]]],
         [NSString stringWithFormat:@"②b 强制重签：返回 %d（期望 1）、新目录 %@（不同于 %@）、随行目录在", rc, d2, newdir]); }
    put_json(catp, cat0); [fm removeItemAtPath:[idir stringByAppendingPathComponent:@"current.json"] error:nil];
    ARGS(); rc = s2a_program_resign_if_needed(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, md, im, sizeof md, why, sizeof why);
    ck(rc == 0 && [json(catp)[@"dir"] isEqualToString:@"v-0000000000000000-pc"], [NSString stringWithFormat:@"③ 没有 current.json：返回 %d（期望 0），清单不动", rc]);
    put_json([idir stringByAppendingPathComponent:@"current.json"], @{@"schema": @1, @"team": @"ABCDE12345", @"cert_sha1": cur_sha});
    NSMutableDictionary *cat2 = [cat0 mutableCopy]; cat2[@"team"] = @"ABCDE12345"; put_json(catp, cat2);
    ARGS(); rc = s2a_program_resign_if_needed(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, md, im, sizeof md, why, sizeof why);
    ck(rc == 0, [NSString stringWithFormat:@"④ 电脑按同团队签好（team 相同、没写 signer）：返回 %d（期望 0）", rc]);
    put_json(catp, cat0); s2a_program_resign_test_identity(id_none);
    ARGS(); rc = s2a_program_resign_if_needed(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, md, im, sizeof md, why, sizeof why);
    ck(rc == -1 && [json(catp)[@"dir"] isEqualToString:@"v-0000000000000000-pc"] && strstr(why, "钥匙串"), [NSString stringWithFormat:@"⑤ 钥匙串里没有身份：返回 %d（期望 -1）、清单不动、原因「%@」", rc, @(why)]);
    s2a_program_resign_test_identity(id_ok); s2a_program_resign_test_prov(prov_other); put_json(catp, cat0);
    ARGS(); rc = s2a_program_resign_if_needed(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, md, im, sizeof md, why, sizeof why);
    ck(rc == -1 && [json(catp)[@"dir"] isEqualToString:@"v-0000000000000000-pc"] && strstr(why, "ABCDE12345") && strstr(why, "FGHIJ67890"),
       [NSString stringWithFormat:@"⑥ App 团队 FGHIJ67890 ≠ 身份团队 ABCDE12345：返回 %d（期望 -1）、清单不动、原因「%@」写出两个团队号", rc, @(why)]);
    s2a_program_resign_test_prov(prov_same); put_json(catp, cat0);
    ARGS(); rc = s2a_program_resign_if_needed(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, md, im, sizeof md, why, sizeof why);
    ck(rc == 1 && [json(catp)[@"signer"][@"team"] isEqual:@"ABCDE12345"], [NSString stringWithFormat:@"⑥b 团队相同：照常重签，返回 %d（期望 1）、signer.team ABCDE12345", rc]);
    NSString *host = [dir stringByAppendingPathComponent:@"LiveContainer.app"];
    [fm createDirectoryAtPath:host withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSPropertyListSerialization dataWithPropertyList:@{@"CFBundleIdentifier": @"com.example.livecontainer.host"} format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]
        writeToFile:[host stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
    g_host_bundle = [NSBundle bundleWithPath:host];
    // ⑦ LiveContainer 里
    g_p12 = p12; s2a_lc_cert_test(lc_ok); s2a_program_resign_test_identity(id_none); s2a_program_resign_test_prov(prov_other);
    [fm removeItemAtPath:[idir stringByAppendingPathComponent:@"current.json"] error:nil]; put_json(catp, cat0);
    ARGS(); rc = s2a_program_resign_if_needed(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, md, im, sizeof md, why, sizeof why);
    { NSDictionary *c7 = json(catp); NSString *v7 = [prog stringByAppendingPathComponent:c7[@"dir"] ?: @"?"];
      NSString *a7 = sh([NSString stringWithFormat:@"codesign -dvvv '%@/%@' 2>&1", v7, img]);
      ck(rc == 1 && [c7[@"signer"][@"cert_sha1"] isEqual:cur_sha] && [c7[@"signer"][@"team"] isEqual:@"ABCDE12345"] && [c7[@"signer"][@"via"] isEqual:@"livecontainer"],
         [NSString stringWithFormat:@"⑦ LiveContainer 里：返回 %d（期望 1）、signer %@（期望 cert_sha1 %@、team ABCDE12345、via livecontainer）", rc, c7[@"signer"], cur_sha]);
      ck([a7 containsString:@"Authority=t_program_resign"] && [a7 containsString:@"TeamIdentifier=ABCDE12345"], @"⑦ 新程序库是 LiveContainer 交的证书签的、团队号 ABCDE12345（codesign 读）");
      ck([a7 containsString:@"Identifier=com.example.livecontainer.host\n"], @"LC 标识：直接使用 LiveContainer 证书时取宿主包名"); }
    rc = s2a_program_resign_if_needed(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, md, im, sizeof md, why, sizeof why);
    ck(rc == 0, [NSString stringWithFormat:@"⑦b 再起一次：返回 %d（期望 0）", rc]);
    s2a_lc_cert_test(lc_nocert); put_json(catp, cat0);
    ARGS(); rc = s2a_program_resign_if_needed(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, md, im, sizeof md, why, sizeof why);
    ck(rc == -1 && [json(catp)[@"dir"] isEqualToString:@"v-0000000000000000-pc"] && strstr(why, "LiveContainer"),
       [NSString stringWithFormat:@"⑦c LiveContainer 没导入证书：返回 %d（期望 -1）、清单不动、原因「%@」", rc, @(why)]);
    // ⑦d LiveContainer 的证书解不开、玩家往 S2Arm 里导入过证书（current.json + 钥匙串身份）：改用导入的那张签，不看本包描述文件（给的是别的团队）
    s2a_lc_cert_test(lc_garbled); s2a_program_resign_test_identity(id_ok); s2a_program_resign_test_prov(prov_other);
    put_json([idir stringByAppendingPathComponent:@"current.json"], @{@"cert_sha1": cur_sha, @"team": @"ABCDE12345"}); put_json(catp, cat0);
    ARGS(); rc = s2a_program_resign_if_needed(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, md, im, sizeof md, why, sizeof why);
    ck(rc == 1 && [json(catp)[@"signer"][@"cert_sha1"] isEqual:cur_sha],
       [NSString stringWithFormat:@"⑦d LiveContainer 证书解不开、S2Arm 里导入过证书：返回 %d（期望 1，改用导入的那张）、signer %@", rc, json(catp)[@"signer"]]);
    { NSString *signed_path = [[prog stringByAppendingPathComponent:json(catp)[@"dir"]] stringByAppendingPathComponent:img];
      NSString *description = sh([NSString stringWithFormat:@"codesign -dvvv '%@' 2>&1", signed_path]);
      ck([description containsString:@"Identifier=com.example.livecontainer.host\n"], @"LC 标识：使用已导入的备用证书时取宿主包名"); }
    g_host_bundle = nil; put_json(catp, cat0);
    ARGS(); rc = s2a_program_resign_if_needed(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, md, im, sizeof md, why, sizeof why);
    { NSString *description = sh([NSString stringWithFormat:@"codesign -dvvv '%s' 2>&1", im]);
      ck(rc == 1 && original_identifier.length && [description containsString:original_identifier],
         @"LiveContainer 宿主包名读不到：继续重签，沿用原程序库标识"); }
    // ⑦e 解不开、也没导入过：不签、原因写清怎么导（齿轮 →「签名证书」→「导入 .p12…」）
    [fm removeItemAtPath:[idir stringByAppendingPathComponent:@"current.json"] error:nil]; put_json(catp, cat0);
    ARGS(); rc = s2a_program_resign_if_needed(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, md, im, sizeof md, why, sizeof why);
    ck(rc == -1 && [json(catp)[@"dir"] isEqualToString:@"v-0000000000000000-pc"] && strstr(why, "读不出来") && strstr(why, "导入 .p12"),
       [NSString stringWithFormat:@"⑦e 解不开、也没导入过：返回 %d（期望 -1）、清单不动、原因「%@」写出怎么导", rc, @(why)]);
    // ⑨ 程序在 App 包里的款（独立 App 导出、LiveContainer 装；D-HF6H / D-RG9V）：原先只有程序包款起局重签，包内款在 LiveContainer 里用的是
    //   原样的程序库（不是 LiveContainer 的证书签的），映射代码段被系统拒（EPERM）。期望：
    //   ⑨a 在 LiveContainer 里 → 1：images 改指 <资源包上一级>/program-lc/v-<签后 sha256 前 16 位>-lc/<程序库名>（单测自己算 sha），codesign 读到测试身份、团队 ABCDE12345，
    //       包里那份原样（sha 不变）；⑨b 再起（包里那份没变）→ 1、同一路径、不重签（文件修改时间不变）；⑨c 包里那份换了 → 重签出新目录、旧目录清掉；
    //   ⑨d 不在 LiveContainer 里 → 0、images 不动；⑨e LiveContainer 没导入证书 → -1、images 不动、原因提 LiveContainer
    {   NSString *bdir = [home stringByAppendingPathComponent:@"Bundle/S2Arm.app/Frameworks"], *bimg = [bdir stringByAppendingPathComponent:img];
        [fm createDirectoryAtPath:bdir withIntermediateDirectories:YES attributes:nil error:nil];
        ck([sh([NSString stringWithFormat:@"cd '%@' && cc -arch arm64 -dynamiclib -o '%@' a.c && codesign -f -s - '%@' 2>/dev/null && echo OK", dir, bimg, bimg]) containsString:@"OK"],
           @"⑨ 备好 App 包里的 ad-hoc 程序库");
        NSString *bsha = sha_file(bimg), *plc = [[gd stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"program-lc"];
        char bi[2048];
        s2a_lc_cert_test(lc_ok); s2a_program_resign_test_identity(id_none); s2a_program_resign_test_prov(prov_other);
        snprintf(bi, sizeof bi, "%s", bimg.fileSystemRepresentation);
        rc = s2a_bundle_image_resign_lc(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, bi, sizeof bi, why, sizeof why);
        NSString *got = @(bi), *want_dir = [NSString stringWithFormat:@"v-%@-lc", [sha_file(got) substringToIndex:16]];
        NSString *a9 = sh([NSString stringWithFormat:@"codesign -dvvv '%@' 2>&1", got]);
        ck(rc == 1 && [got isEqualToString:[[plc stringByAppendingPathComponent:want_dir] stringByAppendingPathComponent:img]] && [sha_file(bimg) isEqualToString:bsha],
           [NSString stringWithFormat:@"⑨a LiveContainer 里包内款：返回 %d（期望 1）、改指 %@（期望 program-lc/%@/%@）、包里那份原样", rc, got, want_dir, img]);
        ck([a9 containsString:@"Authority=t_program_resign"] && [a9 containsString:@"TeamIdentifier=ABCDE12345"], @"⑨a 副本是 LiveContainer 交的证书签的、团队号 ABCDE12345（codesign 读）");
        NSDate *m0 = [fm attributesOfItemAtPath:got error:nil].fileModificationDate;
        snprintf(bi, sizeof bi, "%s", bimg.fileSystemRepresentation);
        rc = s2a_bundle_image_resign_lc(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, bi, sizeof bi, why, sizeof why);
        ck(rc == 1 && [@(bi) isEqualToString:got] && [[fm attributesOfItemAtPath:got error:nil].fileModificationDate isEqual:m0],
           [NSString stringWithFormat:@"⑨b 再起：返回 %d（期望 1）、同一路径、不重签", rc]);
        sh([NSString stringWithFormat:@"cd '%@' && printf 'int f(void){return 2;}' > b.c && cc -arch arm64 -dynamiclib -o '%@' b.c && codesign -f -s - '%@' 2>/dev/null", dir, bimg, bimg]);
        snprintf(bi, sizeof bi, "%s", bimg.fileSystemRepresentation);
        rc = s2a_bundle_image_resign_lc(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, bi, sizeof bi, why, sizeof why);
        NSArray *left = [fm contentsOfDirectoryAtPath:plc error:nil];
        ck(rc == 1 && ![@(bi) isEqualToString:got] && ![left containsObject:want_dir] && [@(bi) hasPrefix:plc],
           [NSString stringWithFormat:@"⑨c 包里那份换了：返回 %d（期望 1）、新路径 %s、旧目录清掉（剩 %@）", rc, bi, left]);
        s2a_lc_cert_test(lc_none);
        snprintf(bi, sizeof bi, "%s", bimg.fileSystemRepresentation);
        rc = s2a_bundle_image_resign_lc(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, bi, sizeof bi, why, sizeof why);
        ck(rc == 0 && [@(bi) isEqualToString:bimg], [NSString stringWithFormat:@"⑨d 不在 LiveContainer 里：返回 %d（期望 0）、images 不动", rc]);
        s2a_lc_cert_test(lc_nocert);
        rc = s2a_bundle_image_resign_lc(home.fileSystemRepresentation, gd.fileSystemRepresentation, G.UTF8String, bi, sizeof bi, why, sizeof why);
        ck(rc == -1 && [@(bi) isEqualToString:bimg] && strstr(why, "LiveContainer"), [NSString stringWithFormat:@"⑨e LiveContainer 没导入证书：返回 %d（期望 -1）、images 不动、原因「%@」", rc, @(why)]);
    }
    s2a_lc_cert_test(NULL); s2a_program_resign_test_identity(id_ok);
    s2a_program_resign_test_prov(NULL);
    [fm removeItemAtPath:dir error:nil];
    return S2A_T_RESULT("t_program_resign", bad);
} }
