// 签名证书进游戏状态（ios/sign_state.m）单测，Mac 上跑。期望照 cmdr 走查「第 2 支期望」表手写，不跑被测实现算：
//   每款签名状态 s2a_sign_state_at（情形 1–15；14 / 15 = LiveContainer 里，15 = 它那张 S2Arm 解不开）、挑现用证书 s2a_cert_settle（导入别的团队的证书不顶掉能用的）、
//   证书登记表 certs.tsv（runtime/src/selfsign.c 导入成功时记：同一张不重复；钥匙串换成桩，不碰本机钥匙串）
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "s2a_t_result.h"

int s2a_sign_state_at(const char *home, const char *catalogue, int rejected);
int s2a_cert_settle(const char *home);
int s2a_cert_health(const char *home);
int s2a_identity_import_p12(const char *home, const void *p12, size_t n, const char *password, const char *source, char *team, size_t team_n, char *why, size_t why_n);
void s2a_identity_test_store(int (*f)(SecKeyRef, SecCertificateRef, char *, size_t));
void s2a_lc_cert_test(int (*f)(NSData **, NSString **));
static NSData *g_lc_p12;   // LiveContainer 共享偏好里那张（桩）：解得开的真 p12，或解不开的一段字节
static int lc_ok(NSData **p, NSString **w) { if (p) *p = g_lc_p12; if (w) *w = @"t"; return 1; }

static int bad;
static void ck(int ok, NSString *what) { printf("%s %s\n", ok ? "  通" : "  【红】", what.UTF8String); if (!ok) bad++; }
static int store_ok(SecKeyRef k, SecCertificateRef c, char *w, size_t n) { (void)k; (void)c; (void)w; (void)n; return 0; }
static NSString *H, *ID, *CAT;
static void put(NSString *p, NSString *s) { [s writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
static void reset(void) { NSFileManager *fm = NSFileManager.defaultManager; [fm removeItemAtPath:ID error:nil]; [fm createDirectoryAtPath:ID withIntermediateDirectories:YES attributes:nil error:nil]; }
static void app(NSString *team, NSArray *certs) {
    put([ID stringByAppendingPathComponent:@"app.json"], [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@{@"team": team, @"cert_sha1": certs, @"schema": @1} options:NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding]);
}
static void certs(NSString *tsv) { put([ID stringByAppendingPathComponent:@"certs.tsv"], tsv); }
static void cat(NSString *json) { put(CAT, json); }
static int st(int rejected) { return s2a_sign_state_at(H.fileSystemRepresentation, CAT.fileSystemRepresentation, rejected); }
static NSString *cur_sha(void) {
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[ID stringByAppendingPathComponent:@"current.json"]] ?: NSData.data options:0 error:nil];
    return [j isKindOfClass:NSDictionary.class] ? j[@"cert_sha1"] : nil;
}
static NSString *sh(NSString *cmd) { NSTask *t = [NSTask new]; t.launchPath = @"/bin/sh"; t.arguments = @[@"-c", cmd]; NSPipe *p = [NSPipe pipe]; t.standardOutput = p; t.standardError = p;
    [t launch]; [t waitUntilExit]; return [[NSString alloc] initWithData:[p.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding]; }

int main(void) { @autoreleasepool {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_sign_state.%d", getpid()]];
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    H = [dir stringByAppendingPathComponent:@"home"]; ID = [H stringByAppendingPathComponent:@"Library/Application Support/S2Arm/identity"];
    NSString *prog = [H stringByAppendingPathComponent:@"Library/Application Support/S2Arm/games/0100ABCDE0000000/program"];
    [NSFileManager.defaultManager createDirectoryAtPath:prog withIntermediateDirectories:YES attributes:nil error:nil];
    CAT = [prog stringByAppendingPathComponent:@"catalogue.json"];
    NSString *A1 = @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1", *A2 = @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2", *B1 = @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1";
    NSString *unsigned_ = @"{\"schema\":1,\"title_id\":\"0100ABCDE0000000\",\"team\":null}", *pc_team = @"{\"schema\":1,\"title_id\":\"0100ABCDE0000000\",\"team\":\"TEAMAAAAAA\"}";
    NSString *phone_a1 = @"{\"schema\":1,\"title_id\":\"0100ABCDE0000000\",\"team\":null,\"signer\":{\"by\":\"phone\",\"team\":\"TEAMAAAAAA\",\"cert_sha1\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1\"}}";
    NSString *rowA1 = [NSString stringWithFormat:@"%@\tTEAMAAAAAA\tp12\t100\n", A1], *rowA2 = [NSString stringWithFormat:@"%@\tTEAMAAAAAA\tsidestore\t300\n", A2],
             *rowB1 = [NSString stringWithFormat:@"%@\tTEAMBBBBBB\tp12\t200\n", B1];

    printf("每款签名状态\n");
    reset(); cat(unsigned_); ck(st(0) == 0, @"1 app.json 没有（ad-hoc 包）→ 0 可玩");
    reset(); app(@"TEAMAAAAAA", @[A1]); cat(pc_team); ck(st(0) == 0, @"2 电脑按 App 团队签好、手机 0 张 → 0");
    cat(unsigned_); ck(st(0) == 1, @"3 程序没签、手机 0 张 → 1 没证书");
    certs(rowB1); ck(st(0) == 2, @"4 程序没签、只有别的团队证书 → 2 团队不符");
    reset(); app(@"TEAMAAAAAA", @[A2]); certs(rowA1); cat(unsigned_); ck(st(0) == 3, @"5 同团队证书不在描述文件 → 3 已换 / 吊销");
    reset(); app(@"TEAMAAAAAA", @[A1]); certs(rowA1); cat(unsigned_); ck(st(0) == 0, @"6 有能用的证书 → 0（起局重签）");
    cat(phone_a1); ck(st(0) == 0, @"7 手机签过、签名证书在描述文件 → 0");
    reset(); app(@"TEAMAAAAAA", @[A2]); certs(rowA1); cat(phone_a1); ck(st(0) == 3, @"8 手机签的证书被换掉、手机上只有那张旧的 → 3");
    certs([rowA1 stringByAppendingString:rowA2]); ck(st(0) == 0, @"9 又导入描述文件里的新证书 → 0");
    reset(); app(@"TEAMAAAAAA", @[A1]); cat(pc_team); ck(st(1) == 4, @"10 电脑签的被系统拒、手机 0 张 → 4 签名格式老");
    certs(rowA1); ck(st(1) == 5, @"11 被拒、手机有能用的证书（重签过仍拒）→ 5 只能回电脑");
    certs(rowB1); ck(st(1) == 2, @"12 被拒、手机只有别的团队证书 → 2");
    reset(); app(@"TEAMAAAAAA", @[A1]); certs([rowA1 stringByAppendingString:rowB1]); cat(unsigned_);
    ck(st(0) == 0, @"13 能用的 A + 后导入的别团队 B → 0");
    put([ID stringByAppendingPathComponent:@"current.json"], [NSString stringWithFormat:@"{\"schema\": 1, \"team\": \"TEAMBBBBBB\", \"cert_sha1\": \"%@\", \"imported\": 200, \"source\": \"p12\"}\n", B1]);
    ck(s2a_cert_settle(H.fileSystemRepresentation) == 0 && [cur_sha() isEqualToString:A1], @"13 现用证书被 B 写成别的团队后，settle 挑回 A");
    ck(s2a_cert_health(H.fileSystemRepresentation) == 0, @"13 状态行不标");
    reset(); app(@"TEAMAAAAAA", @[A1]); put([ID stringByAppendingPathComponent:@"current.json"], [NSString stringWithFormat:@"{\"schema\": 1, \"team\": \"TEAMAAAAAA\", \"cert_sha1\": \"%@\", \"imported\": 50, \"source\": \"pc\"}\n", A1]);
    cat(unsigned_); ck(st(0) == 0, @"老数据：只有 current.json（登记表之前导入的）也算一张 → 0");
    reset(); app(@"TEAMAAAAAA", @[A1]); certs(rowB1); ck(s2a_cert_health(H.fileSystemRepresentation) == 2, @"状态行：只有别的团队 → 2");
    reset(); app(@"TEAMAAAAAA", @[A2]); certs(rowA1); ck(s2a_cert_health(H.fileSystemRepresentation) == 3, @"状态行：同团队但已失效 → 3");

    printf("导入 .p12：登记表与现用证书（钥匙串用桩）\n");
    { NSString *cnf = [dir stringByAppendingPathComponent:@"openssl.cnf"]; put(cnf, @"[req]\ndistinguished_name = dn\n[dn]\n"); setenv("OPENSSL_CONF", cnf.fileSystemRepresentation, 1); }
    NSString *mk = [NSString stringWithFormat:@"cd '%@' && for x in a1:TEAMAAAAAA a2:TEAMAAAAAA b1:TEAMBBBBBB; do n=${x%%%%:*}; t=${x#*:}; "
        "openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj \"/CN=t_sign_state/OU=$t\" -keyout $n.k -out $n.pem 2>/dev/null && "
        "openssl pkcs12 -export -inkey $n.k -in $n.pem -out $n.p12 -passout pass:t -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null && "
        "openssl x509 -in $n.pem -outform DER | shasum | cut -c1-40 > $n.sha || exit 1; done && echo OK", dir];
    ck([sh(mk) containsString:@"OK"], @"备好三张测试证书（团队 A ×2、B ×1）");
    NSString *(^sha)(NSString *) = ^NSString *(NSString *n) { return [[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:[n stringByAppendingString:@".sha"]] encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; };
    int (^imp)(NSString *) = ^int(NSString *n) {
        NSData *d = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:[n stringByAppendingString:@".p12"]]]; char t[64], w[256];
        int r = s2a_identity_import_p12(H.fileSystemRepresentation, d.bytes, d.length, "t", "p12", t, sizeof t, w, sizeof w);
        s2a_cert_settle(H.fileSystemRepresentation); return r;
    };
    NSString *(^tsv)(void) = ^NSString *(void) { return [NSString stringWithContentsOfFile:[ID stringByAppendingPathComponent:@"certs.tsv"] encoding:NSUTF8StringEncoding error:nil] ?: @""; };
    NSUInteger (^lines)(void) = ^NSUInteger(void) { return [[tsv() componentsSeparatedByString:@"\n"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]].count; };
    s2a_identity_test_store(store_ok); reset(); app(@"TEAMAAAAAA", @[sha(@"a1"), sha(@"a2")]);
    ck(imp(@"a1") == 0 && lines() == 1 && [cur_sha() isEqualToString:sha(@"a1")], @"S1 导入 A1 → 登记 1 行、现用 A1");
    ck(imp(@"b1") == 0 && lines() == 2 && [cur_sha() isEqualToString:sha(@"a1")], @"S2 再导入别团队 B1 → 登记 2 行、现用仍是 A1");
    ck(imp(@"a2") == 0 && lines() == 3 && [cur_sha() isEqualToString:sha(@"a2")] && [tsv() containsString:sha(@"a1")], @"S3 再导入 A2 → 现用 A2、A1 仍在登记表");
    ck(imp(@"a2") == 0 && lines() == 3, @"S4 同一张再导一次 → 登记表不重复");
    // LiveContainer 里（#63639b）：起局用它的证书重签，游戏库不因手机上没有 / 只有别的团队的证书标「没证书 / 团队不符」
    s2a_lc_cert_test(lc_ok); g_lc_p12 = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"a1.p12"]];
    reset(); app(@"TEAMAAAAAA", @[A1]); cat(unsigned_); ck(st(0) == 0, @"14 LiveContainer 里、程序没签、手机 0 张 → 0（起局用它的证书重签）");
    certs(rowB1); ck(st(0) == 0, @"14 LiveContainer 里、只有别的团队证书 → 0");
    ck(st(1) == 5, @"14 LiveContainer 里重签过仍被拒 → 5");
    // 15 LiveContainer 存的那张 S2Arm 解不开（#502 / D-D8F4 -26275）：起局改用导入进 S2Arm 的那张，游戏库同样按它判；
    //   一张都没导 → 1「需要签名证书」（卡片上直接导入），不再是 5「回电脑推到 iPhone」（LiveContainer 里的玩家走不通那条）
    g_lc_p12 = [NSData dataWithBytes:"not a p12" length:9];
    reset(); app(@"TEAMAAAAAA", @[A1]); cat(unsigned_); ck(st(0) == 1, @"15 LiveContainer 的证书解不开、S2Arm 没导证书 → 1 需要签名证书");
    ck(st(1) == 1, @"15 同上、点开始被拒过 → 仍是 1（不是 5）");
    certs(rowA1); ck(st(0) == 0, @"15 解不开、但 S2Arm 导入了同团队能用的 → 0");
    certs(rowB1); ck(st(0) == 2, @"15 解不开、S2Arm 只导入了别的团队的 → 2");
    s2a_lc_cert_test(NULL);
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    return S2A_T_RESULT("t_sign_state", bad);
} }
