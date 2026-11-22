// 手机端自签（runtime/src/selfsign.c）的权限输出：与系统 codesign 逐字节对照（只 Mac）。
//   期望值不靠被测实现：同一份权限（application-identifier / team-identifier）交给 codesign --entitlements，取它写出的
//   XML 权限槽（类型 5，magic 0xfade7171）与 DER 权限槽（类型 7，magic 0xfade7172）当真值。
//   ① 带 appid：两槽与 codesign 逐字节一致；CodeDirectory 特殊槽 -5 / -7 = 两槽的 SHA-256；签名标识 = appid 去掉团队号前缀；codesign -v 通过
//   ② 不带 appid：与 codesign 不带 --entitlements 一样没有 5 / 7 两槽，特殊槽只有 2 个；签名标识沿用原签名；codesign -v 通过
//   证书：测试时用 openssl 现生成一张自签名证书打成 p12（不用任何真证书；要带代码签名用途，否则 codesign -v 报 Invalid Key Usage）；输入：现编的 arm64 小可执行文件（ad-hoc 签名）
#include <CommonCrypto/CommonDigest.h>
#include <Security/Security.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "s2a_t_result.h"

int s2a_selfsign_identity(const void *p12, size_t n, const char *password, SecKeyRef *key, CFArrayRef *chain);
int s2a_selfsign_macho(const uint8_t *in, size_t n, const char *ident, const char *team, const char *appid, SecKeyRef key, CFArrayRef chain, uint8_t **out, size_t *out_n, char *why, size_t why_n);
void s2a_log_line(const char *fmt, ...) { (void)fmt; }

static int fails;
#define CHECK(c, ...) do { if (c) printf("通 " __VA_ARGS__); else { printf("【红】 " __VA_ARGS__); fails++; } printf("\n"); } while (0)

static uint32_t be(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint8_t *slurp(const char *p, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long l = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = l > 0 ? malloc((size_t)l) : NULL; if (b && fread(b, 1, (size_t)l, f) != (size_t)l) { free(b); b = NULL; }
    fclose(f); *n = (size_t)l; return b;
}
static int sh(const char *fmt, const char *dir) { char c[2048]; snprintf(c, sizeof c, fmt, dir, dir, dir, dir, dir, dir); return system(c); }

// 取签名 SuperBlob 里某类型的 blob（含 8 字节头）；没有返回 NULL
static const uint8_t *blob(const uint8_t *f, size_t n, uint32_t type, uint32_t *len) {
    const uint8_t *sb = NULL;
    for (size_t i = n >= 12 ? n - 12 : 0; i > 0; i--) if (be(f + i) == 0xfade0cc0 && i + be(f + i + 4) <= n) { sb = f + i; break; }   // 签名在文件尾，从后往前找
    if (!sb) return NULL;
    for (uint32_t k = 0, c = be(sb + 8); k < c; k++) if (be(sb + 12 + k * 8) == type) { const uint8_t *b = sb + be(sb + 16 + k * 8); *len = be(b + 4); return b; }
    return NULL;
}

static void one_case(const char *dir, SecKeyRef key, CFArrayRef chain, const uint8_t *in, size_t n, const char *appid) {
    const char *tag = appid ? "带 appid" : "不带 appid";
    // 真值：codesign
    char ref[512]; snprintf(ref, sizeof ref, "%s/ref_%s", dir, appid ? "ent" : "plain");
    char cmd[2048];
    if (appid) snprintf(cmd, sizeof cmd, "cp %s/in %s && codesign -f -s - --entitlements %s/e.plist %s 2>/dev/null", dir, ref, dir, ref);
    else snprintf(cmd, sizeof cmd, "cp %s/in %s && codesign -f -s - %s 2>/dev/null", dir, ref, ref);
    CHECK(system(cmd) == 0, "%s：codesign 出真值", tag);
    size_t rn = 0; uint8_t *rf = slurp(ref, &rn);
    // 被测
    uint8_t *out = NULL; size_t on = 0; char why[256] = {0};
    int rc = s2a_selfsign_macho(in, n, NULL, "ABCDE12345", appid, key, chain, &out, &on, why, sizeof why);
    CHECK(rc == 0, "%s：签名成功 %s", tag, why);
    if (rc || !rf) { free(rf); free(out); return; }
    char ours[512]; snprintf(ours, sizeof ours, "%s/ours_%s", dir, appid ? "ent" : "plain");
    FILE *f = fopen(ours, "wb"); fwrite(out, 1, on, f); fclose(f);
    for (uint32_t t = 5; t <= 7; t += 2) {
        uint32_t la = 0, lb = 0; const uint8_t *a = blob(rf, rn, t, &la), *b = blob(out, on, t, &lb);
        if (appid) CHECK(a && b && la == lb && !memcmp(a, b, la), "%s：类型 %u 权限槽与 codesign 逐字节一致（%u / %u 字节）", tag, t, la, lb);
        else CHECK(!a && !b, "%s：类型 %u 权限槽两边都没有", tag, t);
    }
    uint32_t cl = 0; const uint8_t *cd = blob(out, on, 0, &cl);
    CHECK(cd && be(cd) == 0xfade0c02, "%s：有 CodeDirectory", tag);
    if (cd) {
        uint32_t hash_off = be(cd + 16), nspecial = be(cd + 24);
        CHECK(nspecial == (appid ? 7u : 2u), "%s：特殊槽 %u 个", tag, nspecial);
        if (appid && nspecial == 7) {
            for (uint32_t t = 5; t <= 7; t += 2) {
                uint32_t lb = 0; const uint8_t *b = blob(out, on, t, &lb); uint8_t h[32]; CC_SHA256(b, lb, h);
                CHECK(!memcmp(cd + hash_off - t * 32, h, 32), "%s：特殊槽 -%u = 权限槽的 SHA-256", tag, t);
            }
        }
        const char *id = (const char *)cd + be(cd + 20);
        if (appid) CHECK(!strcmp(id, strchr(appid, '.') + 1), "%s：签名标识 = 包名（%s）", tag, id);
        else CHECK(!strcmp(id, "t_selfsign_in"), "%s：签名标识沿用原签名（%s）", tag, id);
    }
    snprintf(cmd, sizeof cmd, "codesign -v %s 2>/dev/null", ours);
    CHECK(system(cmd) == 0, "%s：codesign -v 验过", tag);
    free(rf); free(out);
}

// ③ 签名身份交接（s2a_identity_import）：钥匙串换成桩（不碰本机钥匙串）。期望按文件与 openssl 算的 sha1：
//   齐了 → 返回 1、桩被调 1 次、current.json 里是证书 sha1、incoming/ 三份删掉；sha1 对不上 / 私钥坏 → -1、写 import_error.txt、incoming/ 留着、桩不调；没交 → 0
// ④ 手机上直接导入 .p12：密码错 → 1 / 非 p12 → -1（都不存）；对 → 0、团队号 = 证书 OU、current.json 带 openssl 算的 sha1 与 source p12
// ⑤ SideStore 导出的不带 MAC 明文 p12（照 PKCS12Builder 拼 / openssl -nomac）：传错密码也导入成功、团队号与 sha1 对；截断 → -1
int s2a_identity_import(const char *home);
int s2a_identity_import_p12(const char *home, const void *p12, size_t n, const char *password, const char *source, char *team, size_t team_n, char *why, size_t why_n);
void s2a_identity_test_store(int (*f)(SecKeyRef, SecCertificateRef, char *, size_t));
static int g_store_n;
static int store_stub(SecKeyRef k, SecCertificateRef c, char *why, size_t n) { (void)why; (void)n; g_store_n += k && c; return 0; }
static int exists(const char *d, const char *f) { char p[700]; snprintf(p, sizeof p, "%s/%s", d, f); return access(p, F_OK) == 0; }
static void id_case(const char *dir, const char *tag, const char *sha_in_json, int corrupt_key, int want_rc, const char *real_sha) {
    char home[600], inc[700], c[2400]; snprintf(home, sizeof home, "%s/home_%s", dir, tag);
    snprintf(inc, sizeof inc, "%s/Library/Application Support/S2Arm/identity/incoming", home);
    snprintf(c, sizeof c, "mkdir -p '%s' && cp %s/key.der '%s/key.der' && cp %s/cert.der '%s/cert.der' && printf '{\"schema\": 1, \"team\": \"ABCDE12345\", \"cert_sha1\": \"%s\"}' > '%s/identity.json'",
             inc, dir, inc, dir, inc, sha_in_json, inc);
    system(c);
    if (corrupt_key) { char k2[700]; snprintf(k2, sizeof k2, "%s/key.der", inc); FILE *f = fopen(k2, "r+b"); if (f) { fseek(f, 4, SEEK_SET); fputs("\x05\x05\x05\x05", f); fclose(f); } }
    g_store_n = 0; int rc = s2a_identity_import(home);
    char idd[700]; snprintf(idd, sizeof idd, "%s/Library/Application Support/S2Arm/identity", home);
    if (want_rc == 1) {
        char cur[800]; snprintf(cur, sizeof cur, "%s/current.json", idd); size_t n = 0; FILE *f = fopen(cur, "rb"); char buf[400] = {0}; if (f) { n = fread(buf, 1, sizeof buf - 1, f); fclose(f); }
        CHECK(rc == 1 && g_store_n == 1 && n && strstr(buf, real_sha) && !strstr(buf, "BEGIN") && !exists(inc, "key.der") && !exists(inc, "identity.json"),
              "身份交接 %s：返回 %d（期望 1）、存钥匙串 %d 次、current.json 带 sha1 %s、incoming/ 删掉", tag, rc, g_store_n, real_sha);
    } else {
        CHECK(rc == want_rc && g_store_n == 0 && exists(idd, "import_error.txt") && exists(inc, "key.der") && exists(inc, "identity.json"),
              "身份交接 %s：返回 %d（期望 %d）、不存钥匙串、写了 import_error.txt、incoming/ 留着", tag, rc, want_rc);
    }
}

// ⑤ 的样本：照 SideStore 依赖的 CodeSignKit PKCS12Builder.build 逐字段拼（PFX 版本 3、authSafe = [keyBag 的 data ContentInfo, certBag 的 data ContentInfo]、
//   私钥 = PKCS#8 PrivateKeyInfo 包 PKCS#1、没有 macData、不加密）。DER 长度一律用长格式 0x82 两字节（PKCS12Builder 的 ASN1Helper 同样按需取，解析不该依赖短格式）
typedef struct { uint8_t *p; size_t n; } db;
static db tlv(uint8_t tag, db v) { db o; o.n = 4 + v.n; o.p = malloc(o.n); o.p[0] = tag; o.p[1] = 0x82; o.p[2] = (uint8_t)(v.n >> 8); o.p[3] = (uint8_t)v.n; memcpy(o.p + 4, v.p, v.n); free(v.p); return o; }
static db raw(const void *d, size_t n) { db o = {malloc(n ? n : 1), n}; memcpy(o.p, d, n); return o; }
static db cat2(db a, db b) { db o = {malloc(a.n + b.n), a.n + b.n}; memcpy(o.p, a.p, a.n); memcpy(o.p + a.n, b.p, b.n); free(a.p); free(b.p); return o; }
static db oidv(const uint8_t *o, size_t n) { db r = {malloc(n + 2), n + 2}; r.p[0] = 0x06; r.p[1] = (uint8_t)n; memcpy(r.p + 2, o, n); return r; }
static const uint8_t O_DATA[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x07,0x01}, O_KEYBAG[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x0c,0x0a,0x01,0x01},
    O_CERTBAG[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x0c,0x0a,0x01,0x03}, O_X509[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x09,0x16,0x01}, O_RSA[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01};
static db data_ci(db octets) { return tlv(0x30, cat2(oidv(O_DATA, sizeof O_DATA), tlv(0xa0, tlv(0x04, octets)))); }
static db sidestore_p12(const uint8_t *key1, size_t kn, const uint8_t *cert, size_t cn) {
    const uint8_t v0[] = {0x02, 0x01, 0x00}, v3[] = {0x02, 0x01, 0x03}, nul[] = {0x05, 0x00};
    db alg = tlv(0x30, cat2(oidv(O_RSA, sizeof O_RSA), raw(nul, 2)));
    db pkcs8 = tlv(0x30, cat2(cat2(raw(v0, 3), alg), tlv(0x04, raw(key1, kn))));
    db keybag = tlv(0x30, cat2(oidv(O_KEYBAG, sizeof O_KEYBAG), tlv(0xa0, pkcs8)));
    db certval = tlv(0x30, cat2(oidv(O_X509, sizeof O_X509), tlv(0xa0, tlv(0x04, raw(cert, cn)))));
    db certbag = tlv(0x30, cat2(oidv(O_CERTBAG, sizeof O_CERTBAG), tlv(0xa0, certval)));
    db authsafe = tlv(0x30, cat2(data_ci(tlv(0x30, keybag)), data_ci(tlv(0x30, certbag))));
    return tlv(0x30, cat2(raw(v3, 3), data_ci(authsafe)));
}
int main(void) {
    char dir[] = "/tmp/t_selfsign.XXXXXX"; if (!mkdtemp(dir)) { puts("【红】建不了临时目录"); return 1; }
    // openssl 用测试自带的最小配置：不依赖本机 openssl.cnf（一台门禁机的 Homebrew openssl 缺配置文件，req 直接失败、整组红）
    { char cnf[600]; snprintf(cnf, sizeof cnf, "%s/openssl.cnf", dir); FILE *f = fopen(cnf, "w"); if (f) { fputs("[req]\ndistinguished_name = dn\n[dn]\n", f); fclose(f); setenv("OPENSSL_CONF", cnf, 1); } }
    // 输入：arm64 小可执行文件，签名标识 t_selfsign_in；证书：自签名 RSA 2048，OU = 团队号
    int r = sh("printf 'int main(void){return 0;}' > %s/m.c && cc -arch arm64 -o %s/in %s/m.c && codesign -f -s - -i t_selfsign_in %s/in 2>/dev/null", dir)
         || sh("openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=t_selfsign/OU=ABCDE12345'"
               " -addext 'keyUsage=critical,digitalSignature' -addext 'extendedKeyUsage=critical,codeSigning' -keyout %s/k.pem -out %s/c.pem 2>/dev/null"
               " && openssl pkcs12 -export -inkey %s/k.pem -in %s/c.pem -out %s/id.p12 -passout pass:t -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null", dir);
    CHECK(r == 0, "备好输入与测试证书");
    FILE *e = NULL; { char p[512]; snprintf(p, sizeof p, "%s/e.plist", dir); e = fopen(p, "w"); }
    if (e) { fputs("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n"
                   "\t<key>application-identifier</key>\n\t<string>ABCDE12345.io.example.selfsign.test</string>\n"
                   "\t<key>com.apple.developer.team-identifier</key>\n\t<string>ABCDE12345</string>\n</dict>\n</plist>\n", e); fclose(e); }
    char p[512]; size_t pn = 0, n = 0;
    snprintf(p, sizeof p, "%s/id.p12", dir); uint8_t *pb = slurp(p, &pn);
    snprintf(p, sizeof p, "%s/in", dir); uint8_t *in = slurp(p, &n);
    SecKeyRef key = NULL; CFArrayRef chain = NULL;
    int ir = pb ? s2a_selfsign_identity(pb, pn, "t", &key, &chain) : -1;
    CHECK(ir == 0, "导入测试 p12（%d）", ir);
    if (!ir && in) {
        one_case(dir, key, chain, in, n, "ABCDE12345.io.example.selfsign.test");
        one_case(dir, key, chain, in, n, NULL);
    }
    {   printf("③ 签名身份交接\n");
        s2a_identity_test_store(store_stub);
        char cmd[1600]; snprintf(cmd, sizeof cmd, "cd %s && openssl rsa -in k.pem -traditional -outform DER -out key.der 2>/dev/null && openssl x509 -in c.pem -outform DER -out cert.der && openssl dgst -sha1 -r cert.der | cut -c1-40 > sha.txt", dir);
        int pr = system(cmd); char sha[64] = {0}; { char p[600]; snprintf(p, sizeof p, "%s/sha.txt", dir); FILE *f = fopen(p, "r"); if (f) { if (fgets(sha, sizeof sha, f)) sha[strcspn(sha, "\n")] = 0; fclose(f); } }
        CHECK(pr == 0 && strlen(sha) == 40, "备好 PKCS#1 私钥 DER、证书 DER、openssl 算的证书 sha1 %s", sha);
        id_case(dir, "ok", sha, 0, 1, sha);
        id_case(dir, "badsha", "0000000000000000000000000000000000000000", 0, -1, sha);
        id_case(dir, "badkey", sha, 1, -1, sha);
        char home[600]; snprintf(home, sizeof home, "%s/home_none", dir); g_store_n = 0;
        CHECK(s2a_identity_import(home) == 0 && g_store_n == 0, "没交（没有 identity.json）：返回 0、不碰钥匙串");
        // ④ 手机上直接导入 .p12（s2a_identity_import_p12）：期望团队号 = 生成证书时写的 OU、sha1 = openssl 对证书 DER 算的；密码错 → 1、不存；非 p12 → -1、不存
        printf("④ 手机上直接导入 .p12\n");
        char h4[600], cur[800], buf[400] = {0}, team[64], why[256]; snprintf(h4, sizeof h4, "%s/home_p12", dir);
        snprintf(cur, sizeof cur, "%s/Library/Application Support/S2Arm/identity/current.json", h4);
        g_store_n = 0; int r1 = pb ? s2a_identity_import_p12(h4, pb, pn, "错的", NULL, team, sizeof team, why, sizeof why) : -9;
        CHECK(r1 == 1 && g_store_n == 0 && access(cur, F_OK) != 0, ".p12 密码不对：返回 %d（期望 1）、不存钥匙串、不写 current.json", r1);
        const char junk[] = "not a p12 file"; g_store_n = 0; int r2 = s2a_identity_import_p12(h4, junk, sizeof junk, "t", NULL, team, sizeof team, why, sizeof why);
        CHECK(r2 == -1 && g_store_n == 0 && why[0], "不是 p12：返回 %d（期望 -1）、不存、原因「%s」", r2, why);
        g_store_n = 0; int r3 = pb ? s2a_identity_import_p12(h4, pb, pn, "t", NULL, team, sizeof team, why, sizeof why) : -9;
        { FILE *f = fopen(cur, "rb"); if (f) { size_t k = fread(buf, 1, sizeof buf - 1, f); buf[k] = 0; fclose(f); } }
        CHECK(r3 == 0 && g_store_n == 1 && !strcmp(team, "ABCDE12345") && strstr(buf, sha) && strstr(buf, "\"team\": \"ABCDE12345\"") && strstr(buf, "\"source\": \"p12\"") && !strstr(buf, "BEGIN"),
              ".p12 密码对：返回 %d（期望 0）、存钥匙串 %d 次、团队号 %s（期望证书 OU ABCDE12345）、current.json 带 sha1 %s 与 source p12", r3, g_store_n, team, sha);
        // ⑤ SideStore 导出的明文 p12（没有 MAC、不加密、密码不起作用）：照 PKCS12Builder 拼的样本、openssl -nomac 不加密的样本，各传错密码导入
        printf("⑤ 不带 MAC 的明文 .p12（SideStore 导出格式）\n");
        size_t k1n = 0, cdn = 0; char kp[600], cp[600]; snprintf(kp, sizeof kp, "%s/key.der", dir); snprintf(cp, sizeof cp, "%s/cert.der", dir);
        uint8_t *k1 = slurp(kp, &k1n), *cd = slurp(cp, &cdn);
        db ss = k1 && cd ? sidestore_p12(k1, k1n, cd, cdn) : (db){NULL, 0};
        char h5[600], cur5[800]; snprintf(h5, sizeof h5, "%s/home_ss", dir); snprintf(cur5, sizeof cur5, "%s/Library/Application Support/S2Arm/identity/current.json", h5);
        g_store_n = 0; int r5 = ss.p ? s2a_identity_import_p12(h5, ss.p, ss.n, "对话框里的密码会被忽略", "sidestore", team, sizeof team, why, sizeof why) : -9;
        memset(buf, 0, sizeof buf); { FILE *f = fopen(cur5, "rb"); if (f) { size_t k = fread(buf, 1, sizeof buf - 1, f); buf[k] = 0; fclose(f); } }
        CHECK(r5 == 0 && g_store_n == 1 && !strcmp(team, "ABCDE12345") && strstr(buf, sha) && strstr(buf, "\"source\": \"sidestore\""), "PKCS12Builder 格式样本（%zu 字节）：返回 %d（期望 0）、存钥匙串 %d 次、团队号 %s、current.json 带 sha1 %s（%s）", ss.n, r5, g_store_n, team, sha, why);
        char cmd5[1200]; snprintf(cmd5, sizeof cmd5, "cd %s && openssl pkcs12 -export -inkey k.pem -in c.pem -out nomac.p12 -nomac -keypbe NONE -certpbe NONE -passout pass: 2>/dev/null", dir);
        size_t nmn = 0; char nmp[600]; snprintf(nmp, sizeof nmp, "%s/nomac.p12", dir); uint8_t *nm = system(cmd5) == 0 ? slurp(nmp, &nmn) : NULL;
        g_store_n = 0; int r6 = nm ? s2a_identity_import_p12(h5, nm, nmn, "随便填", "sidestore", team, sizeof team, why, sizeof why) : -9;
        CHECK(r6 == 0 && g_store_n == 1 && !strcmp(team, "ABCDE12345"), "openssl -nomac 不加密样本（%zu 字节）：返回 %d（期望 0）、存钥匙串 %d 次、团队号 %s（%s）", nmn, r6, g_store_n, team, why);
        uint8_t bad5[64]; memcpy(bad5, ss.p ? ss.p : (uint8_t *)"x", ss.n < 64 ? ss.n : 64); g_store_n = 0;
        int r7 = ss.n >= 64 ? s2a_identity_import_p12(h5, bad5, 64, "x", "sidestore", team, sizeof team, why, sizeof why) : -9;
        CHECK(r7 == -1 && g_store_n == 0, "明文格式截断成 64 字节：返回 %d（期望 -1）、不存", r7);
        // ⑥ 加密但不带 MAC 的 p12（D-QSEB：有的签名工具这样导出，系统 SecPKCS12Import 一律回 -26275）。期望手写：密码对 → 导入、团队号 = 证书 OU；
        //   密码错 → 1（让玩家再输一次，不是「文件不能用」）；空密码导出 + 空密码 → 导入。样本：openssl -nomac 默认 AES-256、-legacy 3DES
        printf("⑥ 加密但不带 MAC 的 .p12\n");
        const char *kinds[][2] = {{"aes", "-passout pass:t"}, {"3des", "-legacy -passout pass:t"}, {"aes_empty", "-passout pass:"}};
        for (int i = 0; i < 3; i++) {
            char c6[1200], f6[600], h6[600]; snprintf(f6, sizeof f6, "%s/enc_nomac_%s.p12", dir, kinds[i][0]); snprintf(h6, sizeof h6, "%s/home_enc_%s", dir, kinds[i][0]);
            snprintf(c6, sizeof c6, "cd %s && openssl pkcs12 -export -inkey k.pem -in c.pem -out %s -nomac %s 2>/dev/null", dir, f6, kinds[i][1]);
            size_t en = 0; uint8_t *eb = system(c6) == 0 ? slurp(f6, &en) : NULL; const char *pw = i == 2 ? "" : "t";
            SecKeyRef k6 = NULL; CFArrayRef ch6 = NULL; int sr = eb ? s2a_selfsign_identity(eb, en, pw, &k6, &ch6) : -9;
            CHECK(sr == 0 && k6 && ch6 && CFArrayGetCount(ch6) >= 1, "%s（%zu 字节）：s2a_selfsign_identity 返回 %d（期望 0，补 MAC 前系统回 -26275）", kinds[i][0], en, sr);
            if (k6) CFRelease(k6);
            if (ch6) CFRelease(ch6);
            if (i < 2) { g_store_n = 0; int rw = eb ? s2a_identity_import_p12(h6, eb, en, "错的", NULL, team, sizeof team, why, sizeof why) : -9;
                         CHECK(rw == 1 && g_store_n == 0, "%s 密码错：返回 %d（期望 1 = 再问密码）、不存", kinds[i][0], rw); }
            g_store_n = 0; int ro = eb ? s2a_identity_import_p12(h6, eb, en, pw, NULL, team, sizeof team, why, sizeof why) : -9;
            CHECK(ro == 0 && g_store_n == 1 && !strcmp(team, "ABCDE12345"), "%s 密码对：返回 %d（期望 0）、存钥匙串 %d 次、团队号 %s（%s）", kinds[i][0], ro, g_store_n, team, why);
            free(eb);
        }
        free(k1); free(cd); free(ss.p); free(nm);
        s2a_identity_test_store(NULL);
    }
    char c[600]; snprintf(c, sizeof c, "rm -rf %s", dir); system(c);
    return S2A_T_RESULT("t_selfsign", fails);
}
