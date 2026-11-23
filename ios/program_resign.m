// 起局时按款重签（0.6.0 通用壳，手机侧）：玩家起哪款就核哪款，程序库的签名身份和手机上现在的签名身份（电脑交来、已导入钥匙串，
//   identity/current.json）不是同一张证书 / 同一个团队，或程序包本来没签（.s2arm 导入、证书模式电脑不签），就在这里当场用手机上的身份签好再起。
//   维护者 0.6.0 总原则：不在后台批量重做全部游戏；玩家点了才做、只做这一款。100 MB 程序库签一次 0.1–0.2 秒（真机 11-17）。
// 写入规则（cmdr 通用壳方案）：每个写入方写自己的版本目录。手机签的放 program/v-<签后 sha256 前 16 位>-phone/：从清单指着的那一版用
//   APFS 克隆整份拷过来（瞬间、不占空间），只换掉程序库；最后改名换上 catalogue.json（dir / image_sha256 / signer / source_sha256）。
//   旧版本目录不删（这局可能还开着），由 s2a_program_gc 一小时后清。
// 做不了（钥匙串里没有身份、签不成、写不进）不拦：记一行原因，照旧用原来的程序库起局，系统真不认时由选游戏那一步标「需要在电脑上更新」。
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <string.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <unistd.h>

#include "native.h"   // s2a_log_line（static inline，不能另写外部声明：iOS 链接找不到定义）
int s2a_identity_keychain(const char *sha, SecKeyRef *key, SecCertificateRef *cert);   // runtime/src/selfsign.c（按证书 sha1 取）
int s2a_cert_settle(const char *home);   // ios/sign_state.m：current.json 指向与 App 同团队、还在描述文件里的那张
CFArrayRef s2a_selfsign_chain_for(SecCertificateRef leaf);
int s2a_selfsign_macho(const uint8_t *in, size_t n, const char *ident, const char *team, const char *appid, SecKeyRef key, CFArrayRef chain, uint8_t **out, size_t *out_n, char *why, size_t why_n);
int s2a_prov_signing_ids_self(char *team, size_t team_n, char *appid, size_t appid_n);   // ios/prov_expiry.m
int s2a_selfsign_identity(const void *p12, size_t n, const char *password, SecKeyRef *key, CFArrayRef *chain);   // runtime/src/selfsign.c（只放进程内存）
int s2a_lc_cert(NSData **p12, NSString **pw);   // ios/sign_state.m：在 LiveContainer 里时取它存的证书
#define RLOG(...) s2a_log_line("[s2a] " __VA_ARGS__)

static int (*g_get_identity)(const char *, SecKeyRef *, SecCertificateRef *) = s2a_identity_keychain;
static int (*g_prov_ids)(char *, size_t, char *, size_t) = s2a_prov_signing_ids_self;
#ifdef S2A_UNIT_TEST
void s2a_program_resign_test_identity(int (*f)(const char *, SecKeyRef *, SecCertificateRef *)) { g_get_identity = f ? f : s2a_identity_keychain; }   // 单测换掉钥匙串
void s2a_program_resign_test_prov(int (*f)(char *, size_t, char *, size_t)) { g_prov_ids = f ? f : s2a_prov_signing_ids_self; }   // 单测换掉「读包里的描述文件」
#endif

static NSString *hex(const uint8_t *d, size_t n) { NSMutableString *s = [NSMutableString stringWithCapacity:n * 2]; for (size_t i = 0; i < n; i++) [s appendFormat:@"%02x", d[i]]; return s; }
static NSDictionary *read_json(NSString *p) {
    NSData *d = [NSData dataWithContentsOfFile:p]; if (!d) return nil;
    id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil]; return [o isKindOfClass:NSDictionary.class] ? o : nil;
}
static int write_json(NSString *p, NSDictionary *o) {   // 临时名再改名（catalogue.json.<pid>.tmp：s2a_program_gc 认这个名字清残留）
    NSData *d = [NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil]; if (!d) return -1;
    NSString *t = [NSString stringWithFormat:@"%@.%d.tmp", p, (int)getpid()];
    if (![d writeToFile:t atomically:NO]) return -1;
    return rename(t.fileSystemRepresentation, p.fileSystemRepresentation) ? -1 : 0;
}
// 证书 DER 里最后一个 OU（主体在签发者之后；苹果开发证书主体的 OU = 团队号，签发者 WWDR 的 OU 是「G3」这类）
static NSString *cert_ou(SecCertificateRef c) {
    CFDataRef d = SecCertificateCopyData(c); if (!d) return nil;
    const uint8_t *p = CFDataGetBytePtr(d); CFIndex l = CFDataGetLength(d); NSString *ou = nil;
    for (CFIndex i = 0; i + 7 <= l; i++)
        if (p[i] == 0x06 && p[i + 1] == 0x03 && p[i + 2] == 0x55 && p[i + 3] == 0x04 && p[i + 4] == 0x0b && (p[i + 5] == 0x0c || p[i + 5] == 0x13) && p[i + 6] < 0x80 && i + 7 + p[i + 6] <= l)
            ou = [[NSString alloc] initWithBytes:p + i + 7 length:p[i + 6] encoding:NSUTF8StringEncoding];
    CFRelease(d); return ou.length ? ou : nil;
}
// LiveContainer 的签名身份（见 ios/sign_state.m s2a_lc_cert）：1 = 取到（key / leaf 调用方 CFRelease，sha / team 带回）；0 = 不在 LiveContainer 里；-1 = 在里面但它没导入证书；
//   -2 = 它导入了证书、S2Arm 解不开（why 写原因；LiveContainer 自己用 OpenSSL 读，有的 p12 它认、系统的 SecPKCS12Import 不认，如 #502 / D-D8F4 的 -26275）
static int lc_identity(SecKeyRef *key, SecCertificateRef *leaf, NSString **sha, NSString **team, NSString **why) {
    NSData *p12 = nil; NSString *pw = nil; int r = s2a_lc_cert(&p12, &pw);
    if (r <= 0) { if (r < 0) *why = @"在 LiveContainer 里运行，但 LiveContainer 还没导入签名证书：在 LiveContainer 的设置里导入证书（用 SideStore 装的会自动带上）后再开"; return r; }
    CFArrayRef chain = NULL; int st = s2a_selfsign_identity(p12.bytes, p12.length, pw.UTF8String, key, &chain);
    if (st || !chain || CFArrayGetCount(chain) < 1) { if (chain) CFRelease(chain); if (*key) CFRelease(*key); *key = NULL; *why = [NSString stringWithFormat:@"LiveContainer 存的签名证书读不出来（%d）", st]; return -2; }
    *leaf = (SecCertificateRef)CFRetain(CFArrayGetValueAtIndex(chain, 0)); CFRelease(chain);
    CFDataRef der = SecCertificateCopyData(*leaf); uint8_t h[CC_SHA1_DIGEST_LENGTH]; CC_SHA1(CFDataGetBytePtr(der), (CC_LONG)CFDataGetLength(der), h); CFRelease(der);
    *sha = hex(h, sizeof h); *team = cert_ou(*leaf);
    return 1;
}
static NSString *str(id v) { return [v isKindOfClass:NSString.class] && [v length] ? v : nil; }
// LiveContainer 用宿主包名签 Mach-O；客体 mainBundle 已被替换，要取它保留的 lcMainBundle。取不到 → nil（沿用程序库原标识）
static NSString *lc_host_id(void) {
    NSString *id_ = nil; SEL selector = NSSelectorFromString(@"lcMainBundle");
    if ([NSUserDefaults respondsToSelector:selector]) {
        NSBundle *(*get_host_bundle)(id, SEL) = (NSBundle *(*)(id, SEL))[NSUserDefaults methodForSelector:selector];
        id_ = get_host_bundle(NSUserDefaults.class, selector).bundleIdentifier;
    }
    if (id_.length) RLOG("LiveContainer 重签标识：用宿主包名 %s（不添加程序库权限）", id_.UTF8String);
    else RLOG("【黄】LiveContainer 重签标识：取不到宿主包名，沿用程序库原标识");
    return id_.length ? id_ : nil;
}

// 1 = 重签了（module_dir / images 改指新版本目录，各 n 字节）；0 = 不用签（没有手机身份、签名身份已是现在这张、电脑按同团队签好的）；
// -1 = 要签但没签成（why 写原因，调用方照旧用原程序库）
// force：不看「签名身份是不是已是现在这张 / 同团队」，只要手机上有身份就重签（注册签名失败时用：证书相同、但签名格式老，
//   如 Windows plumesign 签的小 IPA 程序库，系统照样不认；11-17 Windows 付费团队真机 errno=1）
static int program_resign(const char *home, const char *game_data, const char *gid, char *module_dir, char *images, size_t n, char *why, size_t why_n, int force);
int s2a_program_resign_if_needed(const char *home, const char *game_data, const char *gid, char *module_dir, char *images, size_t n, char *why, size_t why_n) {
    return program_resign(home, game_data, gid, module_dir, images, n, why, why_n, 0);
}
int s2a_program_resign_force(const char *home, const char *game_data, const char *gid, char *module_dir, char *images, size_t n, char *why, size_t why_n) {
    return program_resign(home, game_data, gid, module_dir, images, n, why, why_n, 1);
}
static int program_resign(const char *home, const char *game_data, const char *gid, char *module_dir, char *images, size_t n, char *why, size_t why_n, int force) {
    @autoreleasepool {
        if (why && why_n) why[0] = 0;
        if (!home || !game_data || !gid || !module_dir || !images) return 0;
        // LiveContainer 里（#63639b）：进程的签名身份是 LiveContainer 的，程序库一律用它存的证书签；电脑交来的身份（current.json）在这里不算数
        SecKeyRef key = NULL; SecCertificateRef leaf = NULL; NSString *cur_sha = nil, *cur_team = nil, *lc_why = nil;
        int in_lc = lc_identity(&key, &leaf, &cur_sha, &cur_team, &lc_why), lc_fb = 0;
#define RELEASE_ID() do { if (key) CFRelease(key); if (leaf) CFRelease(leaf); key = NULL; leaf = NULL; } while (0)
        if (in_lc == -2) {
            // LiveContainer 的证书解不开：改用玩家导入进 S2Arm 的那张（齿轮 →「签名证书」→「导入 .p12…」，同一张或同团队的都行——库校验看团队），
            //   没有就照实说怎么导（11-21 #502：原先直接拒，玩家在 LiveContainer 里每款都起不来、也不知道能怎么办）
            s2a_cert_settle(home);
            NSDictionary *cur = read_json([@(home) stringByAppendingPathComponent:@"Library/Application Support/S2Arm/identity/current.json"]);
            if (str(cur[@"cert_sha1"])) { in_lc = 0; lc_fb = 1; }
            else { in_lc = -1; lc_why = [lc_why stringByAppendingString:@"：在 S2Arm 齿轮 →「签名证书」→「导入 .p12…」导入同一张证书（SideStore / AltStore 的设置里能导出），S2Arm 会改用它签"]; }
        }
        if (!in_lc) {
            s2a_cert_settle(home);   // 手机上有几张证书时用与 App 同团队、还能用的那张（导入别的团队的证书不顶掉它）
            NSString *idp = [@(home) stringByAppendingPathComponent:@"Library/Application Support/S2Arm/identity/current.json"];
            NSDictionary *cur = read_json(idp); cur_sha = str(cur[@"cert_sha1"]).lowercaseString; cur_team = str(cur[@"team"]);
            if (!cur_sha) { RLOG("起局重签：游戏 %s 不重签：手机上没有签名身份（电脑签好推上来的）", gid); return 0; }   // 不碰
        }
        NSString *prog = [[@(game_data) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"program"];
        NSString *catp = [prog stringByAppendingPathComponent:@"catalogue.json"];
        NSDictionary *cat = read_json(catp); if (!cat) { RELEASE_ID(); RLOG("起局重签：游戏 %s 不重签：程序包清单读不到（%s）", gid, catp.UTF8String); return 0; }
        NSDictionary *signer = [cat[@"signer"] isKindOfClass:NSDictionary.class] ? cat[@"signer"] : nil;
        NSString *was_sha = str(signer[@"cert_sha1"]).lowercaseString, *team = str(cat[@"team"]);
        if (in_lc >= 0 && !force && (was_sha ? [was_sha isEqualToString:cur_sha] : (!in_lc && team && cur_team && [team isEqualToString:cur_team]))) {
            // 判「不用签」也记一行（D-RG9V：LiveContainer 里外置镜像被拒、日志里一行重签都没有，分不清是证书没取到还是程序库本来就是这张签的）
            RLOG("起局重签：游戏 %s 不用重签：程序库签名 %s 团队 %s，当前%s %s 团队 %s", gid, was_sha.UTF8String ?: "无", team.UTF8String ?: "无",
                 in_lc ? "LiveContainer 的证书" : lc_fb ? "导入进 S2Arm 的证书" : "手机上的签名身份", cur_sha.UTF8String ?: "无", cur_team.UTF8String ?: "无");
            RELEASE_ID(); return 0;
        }
        NSString *why_sign = force ? @"程序库签名本机注册不了" : in_lc ? @"在 LiveContainer 里、程序库不是它的证书签的" : was_sha ? @"程序库是另一张证书签的" : team ? @"程序库是别的团队签的" : @"程序库还没签名";
        const char *src = in_lc ? "LiveContainer 的证书" : lc_fb ? "导入进 S2Arm 的证书（LiveContainer 存的那张解不开）" : "手机上的签名身份";
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#define FAIL(...) do { RELEASE_ID(); if (why && why_n) snprintf(why, why_n, __VA_ARGS__); RLOG("【黄】起局重签：游戏 %s %s，要用%s重签，没签成：%s；照旧用原来的程序库", gid, why_sign.UTF8String, src, why); return -1; } while (0)
        if (in_lc < 0) FAIL("%s", lc_why.UTF8String);
        // 证书的团队（电脑交身份时写进 current.json）和装这个 App 的团队（包里描述文件）不同：签出来的程序库团队号与 App 对不上，系统一定不认（库校验要同团队），
        //   签了也白签。AltStore / SideStore 装的 App 是玩家在那边登录的 Apple ID 的团队，启动器里登录了另一个 Apple ID 就是这种情况：把原因说清楚，不签
        //   LiveContainer 里不看本包的描述文件（客体 App 包里那份不是这个进程的身份），团队号取 LiveContainer 证书的、不带权限
        char pteam[64] = "", pappid[512] = ""; int pr = in_lc || lc_fb ? -1 : g_prov_ids(pteam, sizeof pteam, pappid, sizeof pappid);
        if (pr >= 0 && cur_team && ![cur_team isEqualToString:@(pteam)])
            FAIL("手机上的签名证书是团队 %s 的，这个 App 是团队 %s 签的（启动器里登录的 Apple ID 和装 App 用的不是同一个）：在启动器里登录装 App 用的那个 Apple ID 后再连一次电脑",
                 cur_team.UTF8String, pteam);
        if (!in_lc && (g_get_identity(cur_sha.UTF8String, &key, &leaf) || !key || !leaf)) FAIL("钥匙串里没有证书 %s 的签名身份", cur_sha.UTF8String);
        CFArrayRef chain = s2a_selfsign_chain_for(leaf);
        const char *steam = pr >= 0 ? pteam : cur_team.UTF8String, *sappid = pr >= 0 ? pappid : NULL;
        NSData *in = [NSData dataWithContentsOfFile:@(images)];
        uint8_t *out = NULL; size_t on = 0; char w[256] = "";
        NSString *lc_sign_id = in_lc || lc_fb ? lc_host_id() : nil;
        int rc = in ? s2a_selfsign_macho(in.bytes, in.length, lc_sign_id.length ? lc_sign_id.UTF8String : NULL, steam, sappid, key, chain, &out, &on, w, sizeof w) : -1;
        RELEASE_ID(); if (chain) CFRelease(chain);
        if (!in) FAIL("程序库 %s 读不了", images);
        if (rc) FAIL("签名失败：%s", w);
        uint8_t h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(out, (CC_LONG)on, h); NSString *sha = hex(h, sizeof h);
        NSString *dir = [NSString stringWithFormat:@"v-%@-phone", [sha substringToIndex:16]], *dst = [prog stringByAppendingPathComponent:dir];
        NSString *img = @(images).lastPathComponent, *mrel = [NSString stringWithFormat:@"Games/%s", gid];
        NSFileManager *fm = NSFileManager.defaultManager;
        if ([dst isEqualToString:@(images).stringByDeletingLastPathComponent]) { free(out); FAIL("新签出的和现在这一版是同一份（%s）", dir.UTF8String); }   // 不能删掉正在用的这版再从它拷
        [fm removeItemAtPath:dst error:nil];   // 同一份签名结果的残留（上次写了一半）
        if (![fm createDirectoryAtPath:[dst stringByAppendingPathComponent:@"Games"] withIntermediateDirectories:YES attributes:nil error:nil]) { free(out); FAIL("建不了版本目录 %s", dst.UTF8String); }
        NSString *mdst = [dst stringByAppendingPathComponent:mrel];
        if (clonefile(module_dir, mdst.fileSystemRepresentation, 0) && ![fm copyItemAtPath:@(module_dir) toPath:mdst error:nil]) { free(out); FAIL("随行目录拷不过去（errno %d）", errno); }
        NSString *idst = [dst stringByAppendingPathComponent:img], *itmp = [idst stringByAppendingString:@".tmp"];
        FILE *f = fopen(itmp.fileSystemRepresentation, "wb"); int ok = f && fwrite(out, 1, on, f) == on; if (f && fclose(f)) ok = 0; free(out);
        if (!ok || rename(itmp.fileSystemRepresentation, idst.fileSystemRepresentation)) FAIL("签好的程序库写不进 %s", idst.UTF8String);
        NSMutableDictionary *nc = [cat mutableCopy];
        if (!str(nc[@"source_sha256"]) && str(cat[@"image_sha256"])) nc[@"source_sha256"] = cat[@"image_sha256"];   // 未签名的那份（电脑判重按它）
        nc[@"dir"] = dir; nc[@"image_sha256"] = sha;
        nc[@"signer"] = in_lc ? @{@"by": @"phone", @"via": @"livecontainer", @"team": @(steam ? steam : ""), @"cert_sha1": cur_sha}
                              : @{@"by": @"phone", @"team": @(steam ? steam : ""), @"cert_sha1": cur_sha};
        if (write_json(catp, nc)) FAIL("程序包清单写不进 %s", catp.UTF8String);
        if (snprintf(module_dir, n, "%s", mdst.fileSystemRepresentation) >= (int)n || snprintf(images, n, "%s", idst.fileSystemRepresentation) >= (int)n) FAIL("路径太长");
        RLOG("起局重签：游戏 %s %s，已用%s（团队 %s）签好 → %s，%.0f ms", gid, why_sign.UTF8String, src, steam ? steam : "?", dir.UTF8String, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
        return 1;
#undef FAIL
#undef RELEASE_ID
    }
}

// 程序在 App 包里的款（独立 App：导出包 / 装到 iPhone 的独立 App，镜像包在 <App>/Frameworks/S2AImages-<游戏号>.dylib）在 LiveContainer 里起局（D-HF6H / D-RG9V）：
//   进程的签名身份是 LiveContainer 的，系统只许映射同团队签的代码页；LiveContainer 装 App 时只重签「签名无效」的 Mach-O，导出包里 ad-hoc 签的镜像包它照原样留着，
//   映射代码段就被拒（EPERM，image_exec_lc）。程序包款早由 program_resign 用 LiveContainer 的证书重签（#63639b，真机已验），包内款原先不走这一步。
//   做法同程序包款：用 LiveContainer 的证书（解不开就用导入进 S2Arm 的那张）签一份副本，放 <资源包上一级>/program-lc/v-<签后 sha256 前 16 位>-lc/，images 改指它；
//   App 包里那份不动（LiveContainer 管的目录）。副本按「包里那份的路径 + 大小 + 修改时间 + 证书」记在 program-lc/lc.json，没变就直接用、不重签；变了重签并清掉旧副本。
//   不在 LiveContainer 里 → 0（App 包是装它的工具整包签的，照原样用）。1 = images 改指副本；-1 = 要签没签成（why 写原因，照旧用包里那份，系统真不认时由装载器报 image_exec_lc）
int s2a_bundle_image_resign_lc(const char *home, const char *game_data, const char *gid, char *images, size_t n, char *why, size_t why_n) {
    @autoreleasepool {
        if (why && why_n) why[0] = 0;
        if (!home || !game_data || !gid || !images || !images[0]) return 0;
        SecKeyRef key = NULL; SecCertificateRef leaf = NULL; NSString *cur_sha = nil, *cur_team = nil, *lc_why = nil;
        int in_lc = lc_identity(&key, &leaf, &cur_sha, &cur_team, &lc_why), lc_fb = 0;
        if (!in_lc) { RLOG("起局重签：游戏 %s 的程序在 App 包里、不在 LiveContainer 里：用装 App 时的签名，不重签", gid); return 0; }
#define RELEASE_ID() do { if (key) CFRelease(key); if (leaf) CFRelease(leaf); key = NULL; leaf = NULL; } while (0)
#define FAIL(...) do { RELEASE_ID(); if (why && why_n) snprintf(why, why_n, __VA_ARGS__); RLOG("【黄】起局重签：游戏 %s 的程序在 App 包里、在 LiveContainer 里，要用%s签一份副本，没签成：%s；照旧用包里那份", gid, src, why); return -1; } while (0)
        const char *src = "LiveContainer 的证书";
        if (in_lc == -2) {   // 同程序包款：LiveContainer 的证书解不开 → 用导入进 S2Arm 的那张（同团队就行）
            s2a_cert_settle(home);
            NSDictionary *cur = read_json([@(home) stringByAppendingPathComponent:@"Library/Application Support/S2Arm/identity/current.json"]);
            cur_sha = str(cur[@"cert_sha1"]).lowercaseString; cur_team = str(cur[@"team"]);
            if (cur_sha) { lc_fb = 1; src = "导入进 S2Arm 的证书（LiveContainer 存的那张解不开）"; }
            else lc_why = [lc_why stringByAppendingString:@"：在 S2Arm 齿轮 →「签名证书」→「导入 .p12…」导入同一张证书（SideStore / AltStore 的设置里能导出），S2Arm 会改用它签"];
        }
        if (in_lc < 0 && !lc_fb) FAIL("%s", lc_why.UTF8String);
        if (lc_fb && (g_get_identity(cur_sha.UTF8String, &key, &leaf) || !key || !leaf)) FAIL("钥匙串里没有证书 %s 的签名身份", cur_sha.UTF8String);
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *img = @(images).lastPathComponent, *plc = [[@(game_data) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"program-lc"];
        NSString *markp = [plc stringByAppendingPathComponent:@"lc.json"];
        struct stat st; if (stat(images, &st)) FAIL("包里的程序库 %s 不在（errno %d）", images, errno);
        NSNumber *size = @((long long)st.st_size), *mtime = @((long long)st.st_mtimespec.tv_sec * 1000000000LL + st.st_mtimespec.tv_nsec);
        NSDictionary *mark = read_json(markp);
        NSString *have = str(mark[@"dir"]) ? [[plc stringByAppendingPathComponent:mark[@"dir"]] stringByAppendingPathComponent:img] : nil;
        if (have && [mark[@"src"] isEqual:@(images)] && [mark[@"size"] isEqual:size] && [mark[@"mtime_ns"] isEqual:mtime] && [str(mark[@"cert_sha1"]) isEqualToString:cur_sha]
            && [fm fileExistsAtPath:have]) {
            RELEASE_ID();
            if (snprintf(images, n, "%s", have.fileSystemRepresentation) >= (int)n) FAIL("路径太长");
            RLOG("起局重签：游戏 %s 的程序在 App 包里、在 LiveContainer 里：沿用已用%s签好的副本 %s", gid, src, str(mark[@"dir"]).UTF8String);
            return 1;
        }
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        NSString *sign_id = lc_host_id();
        CFArrayRef chain = s2a_selfsign_chain_for(leaf);
        NSData *in = [NSData dataWithContentsOfFile:@(images)];
        uint8_t *out = NULL; size_t on = 0; char w[256] = "";
        int rc = in ? s2a_selfsign_macho(in.bytes, in.length, sign_id.UTF8String, cur_team.UTF8String, NULL, key, chain, &out, &on, w, sizeof w) : -1;
        if (chain) CFRelease(chain);
        if (!in) FAIL("包里的程序库 %s 读不了", images);
        if (rc) FAIL("签名失败：%s", w);
        uint8_t h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(out, (CC_LONG)on, h); NSString *sha = hex(h, sizeof h);
        NSString *dir = [NSString stringWithFormat:@"v-%@-lc", [sha substringToIndex:16]], *dst = [plc stringByAppendingPathComponent:dir];
        for (NSString *e in [fm contentsOfDirectoryAtPath:plc error:nil]) if ([e hasPrefix:@"v-"]) [fm removeItemAtPath:[plc stringByAppendingPathComponent:e] error:nil];   // 旧副本（包里那份换过 / 证书换过）：本进程这时还没映射任何一份
        if (![fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:nil]) { free(out); FAIL("建不了副本目录 %s", dst.UTF8String); }
        NSString *idst = [dst stringByAppendingPathComponent:img], *itmp = [idst stringByAppendingString:@".tmp"];
        FILE *f = fopen(itmp.fileSystemRepresentation, "wb"); int ok = f && fwrite(out, 1, on, f) == on; if (f && fclose(f)) ok = 0; free(out);
        if (!ok || rename(itmp.fileSystemRepresentation, idst.fileSystemRepresentation)) FAIL("签好的副本写不进 %s", idst.UTF8String);
        if (write_json(markp, @{@"src": @(images), @"size": size, @"mtime_ns": mtime, @"cert_sha1": cur_sha ?: @"", @"team": cur_team ?: @"", @"dir": dir}))
            RLOG("【黄】起局重签：副本记录 %s 写不进，下次起局再签一次", markp.UTF8String);
        RELEASE_ID();
        if (snprintf(images, n, "%s", idst.fileSystemRepresentation) >= (int)n) FAIL("路径太长");
        RLOG("起局重签：游戏 %s 的程序在 App 包里、在 LiveContainer 里，已用%s（团队 %s）签好副本 → program-lc/%s，%.0f ms", gid, src, cur_team.UTF8String ?: "?", dir.UTF8String,
             (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
        return 1;
#undef FAIL
#undef RELEASE_ID
    }
}
