// 手机端自签（0.6.0 通用壳，可行性验证）：在 iOS 上用玩家自己的开发证书（p12）给游戏程序库（Mach-O dylib，arm64 单架构）重新签名，
//   电脑不用签。只用 iOS 也有的系统接口：CommonCrypto（SHA-256）、Security（SecPKCS12Import / SecKeyCreateSignature）。
// 签名格式照 Apple 代码签名（与 codesign / rcodesign 同构）：
//   SuperBlob 0xfade0cc0 = CodeDirectory（v0x20400，SHA-256，16 KiB 页）+ 空 Requirements 集合 +（可选）XML / DER 权限 + CMS 签名（PKCS#7 SignedData，分离式）
//   CMS 签的是 CodeDirectory 原字节：签名属性 = contentType / signingTime / messageDigest（CD 的 SHA-256）/ Apple cdhash 两条（plist + SHA-256）；
//   证书带叶证书 + p12 里的链（WWDR 中间证书）。RSA PKCS#1 v1.5 + SHA-256。
// 输入可以已有签名（ad-hoc 或别的证书）：在原 LC_CODE_SIGNATURE 处截断、按新签名大小改该命令与 __LINKEDIT 尺寸后重写，代码页本身不动。
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonHMAC.h>
#include <Security/Security.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "native.h"
#include <sys/stat.h>
#include <strings.h>
#include <unistd.h>

// Mach-O 文件格式里用到的几样（照 <mach-o/loader.h> 的布局，按文件格式自己写，不包含苹果系统头：分层规则 R-02，共用文件不直接包含苹果头）
enum { SS_MH_MAGIC_64 = 0xfeedfacf, SS_MH_EXECUTE = 0x2, SS_CPU_TYPE_ARM64 = 0x0100000c, SS_LC_SEGMENT_64 = 0x19, SS_LC_CODE_SIGNATURE = 0x1d };
struct ss_mach_header_64 { uint32_t magic; int32_t cputype, cpusubtype; uint32_t filetype, ncmds, sizeofcmds, flags, reserved; };
struct ss_load_command { uint32_t cmd, cmdsize; };
struct ss_segment_command_64 { uint32_t cmd, cmdsize; char segname[16]; uint64_t vmaddr, vmsize, fileoff, filesize; int32_t maxprot, initprot; uint32_t nsects, flags; };
struct ss_linkedit_data_command { uint32_t cmd, cmdsize, dataoff, datasize; };
_Static_assert(sizeof(struct ss_mach_header_64) == 32 && sizeof(struct ss_segment_command_64) == 72 && sizeof(struct ss_linkedit_data_command) == 16, "Mach-O 结构与文件格式不符");

#define CS_PAGE_SHIFT 14
#define CS_PAGE (1u << CS_PAGE_SHIFT)

// ---------- 小工具：大端写、可增长缓冲 ----------
typedef struct { uint8_t *p; size_t n, cap; } buf;
static int bput(buf *b, const void *d, size_t n) {
    if (b->n + n > b->cap) { size_t c = b->cap ? b->cap * 2 : 256; while (c < b->n + n) c *= 2; uint8_t *q = realloc(b->p, c); if (!q) return -1; b->p = q; b->cap = c; }
    if (d) memcpy(b->p + b->n, d, n); else memset(b->p + b->n, 0, n);
    b->n += n; return 0;
}
static void be32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void be64(uint8_t *p, uint64_t v) { be32(p, (uint32_t)(v >> 32)); be32(p + 4, (uint32_t)v); }
static uint32_t rd32be(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

// ---------- DER ----------
static int der_len(buf *b, size_t n) {
    uint8_t h[5]; int k = 0;
    if (n < 0x80) { h[0] = (uint8_t)n; k = 1; }
    else if (n < 0x100) { h[0] = 0x81; h[1] = (uint8_t)n; k = 2; }
    else if (n < 0x10000) { h[0] = 0x82; h[1] = (uint8_t)(n >> 8); h[2] = (uint8_t)n; k = 3; }
    else { h[0] = 0x83; h[1] = (uint8_t)(n >> 16); h[2] = (uint8_t)(n >> 8); h[3] = (uint8_t)n; k = 4; }
    return bput(b, h, (size_t)k);
}
static int der_tlv(buf *b, uint8_t tag, const void *v, size_t n) { return bput(b, &tag, 1) || der_len(b, n) || bput(b, v, n); }
static int der_wrap(buf *out, uint8_t tag, const buf *in) { return der_tlv(out, tag, in->p, in->n); }
static int der_oid(buf *b, const uint8_t *oid, size_t n) { return der_tlv(b, 0x06, oid, n); }
// 读一个 TLV：返回内容起点与长度，*next = 这个 TLV 之后
static const uint8_t *der_read(const uint8_t *p, const uint8_t *end, uint8_t *tag, size_t *len, const uint8_t **next) {
    if (p + 2 > end) return NULL;
    *tag = p[0]; size_t l = p[1]; const uint8_t *q = p + 2;
    if (l & 0x80) { int k = l & 0x7f; if (k < 1 || k > 3 || q + k > end) return NULL; l = 0; for (int i = 0; i < k; i++) l = l << 8 | q[i]; q += k; }
    if (q + l > end) return NULL;
    *len = l; *next = q + l; return q;
}

static const uint8_t SS_OID_DATA[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x07,0x01};
static const uint8_t SS_OID_SIGNED_DATA[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x07,0x02};
static const uint8_t SS_OID_SHA256[] = {0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x01};
static const uint8_t SS_OID_RSA[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01};
static const uint8_t SS_OID_CONTENT_TYPE[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x09,0x03};
static const uint8_t SS_OID_MESSAGE_DIGEST[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x09,0x04};
static const uint8_t SS_OID_SIGNING_TIME[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x09,0x05};
static const uint8_t SS_OID_APPLE_CDHASHES[] = {0x2a,0x86,0x48,0x86,0xf7,0x63,0x64,0x09,0x01};    // 1.2.840.113635.100.9.1：cdhash 列表（plist）
static const uint8_t SS_OID_APPLE_CDHASHES2[] = {0x2a,0x86,0x48,0x86,0xf7,0x63,0x64,0x09,0x02};   // 1.2.840.113635.100.9.2：按算法的 cdhash

static int alg_sha256(buf *b) { buf s = {0}; int r = der_oid(&s, SS_OID_SHA256, sizeof SS_OID_SHA256) || der_tlv(&s, 0x05, NULL, 0) || der_wrap(b, 0x30, &s); free(s.p); return r; }

// 叶证书里取 issuer 与 serial 原样 TLV（SignerInfo 的 issuerAndSerialNumber）
static int cert_issuer_serial(const uint8_t *der, size_t n, buf *out) {
    const uint8_t *end = der + n, *nx, *c; uint8_t t; size_t l;
    if (!(c = der_read(der, end, &t, &l, &nx)) || t != 0x30) return -1;            // Certificate
    const uint8_t *tbs = c, *tend; if (!(c = der_read(tbs, c + l, &t, &l, &tend)) || t != 0x30) return -1;   // TBSCertificate
    const uint8_t *p = c, *pend = c + l;
    if (p < pend && *p == 0xa0) { if (!der_read(p, pend, &t, &l, &nx)) return -1; p = nx; }   // [0] version
    const uint8_t *serial = p; if (!der_read(p, pend, &t, &l, &nx) || t != 0x02) return -1; size_t serial_n = (size_t)(nx - serial); p = nx;
    if (!der_read(p, pend, &t, &l, &nx) || t != 0x30) return -1; p = nx;              // signature algorithm
    const uint8_t *issuer = p; if (!der_read(p, pend, &t, &l, &nx) || t != 0x30) return -1; size_t issuer_n = (size_t)(nx - issuer);
    buf s = {0}; int r = bput(&s, issuer, issuer_n) || bput(&s, serial, serial_n) || der_wrap(out, 0x30, &s); free(s.p); return r;
}

// 叶证书 subject 里的 OU（苹果开发证书的 OU = 团队号）→ out；0 = 取到，-1 = 没有 / 读不了
static const uint8_t SS_OID_OU[] = {0x55, 0x04, 0x0b};
static int cert_team(const uint8_t *der, size_t n, char *out, size_t on) {
    const uint8_t *end = der + n, *nx, *c; uint8_t t; size_t l; out[0] = 0;
    if (!(c = der_read(der, end, &t, &l, &nx)) || t != 0x30) return -1;                                        // Certificate
    const uint8_t *tend; if (!(c = der_read(c, c + l, &t, &l, &tend)) || t != 0x30) return -1;                 // TBSCertificate
    const uint8_t *p = c, *pend = c + l;
    if (p < pend && *p == 0xa0) { if (!der_read(p, pend, &t, &l, &nx)) return -1; p = nx; }                    // [0] version
    for (int i = 0; i < 4; i++) { if (!der_read(p, pend, &t, &l, &nx)) return -1; p = nx; }                     // serial / 签名算法 / issuer / validity
    const uint8_t *sub = der_read(p, pend, &t, &l, &nx); if (!sub || t != 0x30) return -1;                     // subject
    for (const uint8_t *q = sub, *qend = sub + l; q < qend; ) {
        const uint8_t *set = der_read(q, qend, &t, &l, &nx); if (!set || t != 0x31) return -1; q = nx;          // RDN（SET）
        for (const uint8_t *r = set, *rend = set + l; r < rend; ) {
            const uint8_t *nx2, *av = der_read(r, rend, &t, &l, &nx2); if (!av || t != 0x30) return -1; r = nx2;   // AttributeTypeAndValue
            const uint8_t *nx3, *oid = der_read(av, av + l, &t, &l, &nx3); if (!oid || t != 0x06) return -1;
            if (l != sizeof SS_OID_OU || memcmp(oid, SS_OID_OU, l)) continue;
            const uint8_t *nx4, *v = der_read(nx3, nx2, &t, &l, &nx4); if (!v || l + 1 > on) return -1;
            memcpy(out, v, l); out[l] = 0; return 0;
        }
    }
    return -1;
}

// ---------- CodeDirectory ----------
// 返回 CD 字节（cd）；sig_off = 签名在文件里的偏移（= codeLimit），code = 文件前 sig_off 字节
static int build_cd(const uint8_t *code, uint32_t limit, const char *ident, const char *team, const uint8_t req_hash[32], const uint8_t *ent_hash, const uint8_t *ent_der_hash, uint64_t exec_base, uint64_t exec_limit, uint64_t exec_flags, buf *cd) {
    uint32_t nslots = (limit + CS_PAGE - 1) >> CS_PAGE_SHIFT, nspecial = ent_hash ? 7 : 2;
    size_t hdr = 88, ident_n = strlen(ident) + 1, team_n = team ? strlen(team) + 1 : 0;
    size_t ident_off = hdr, team_off = team ? ident_off + ident_n : 0, hash_off = hdr + ident_n + team_n + nspecial * 32;
    size_t total = hash_off + (size_t)nslots * 32;
    if (bput(cd, NULL, total)) return -1;
    uint8_t *h = cd->p;
    be32(h + 0, 0xfade0c02); be32(h + 4, (uint32_t)total); be32(h + 8, 0x20400); be32(h + 12, 0);   // magic / length / version / flags
    be32(h + 16, (uint32_t)hash_off); be32(h + 20, (uint32_t)ident_off); be32(h + 24, nspecial); be32(h + 28, nslots);
    be32(h + 32, limit); h[36] = 32; h[37] = 2; h[38] = 0; h[39] = CS_PAGE_SHIFT; be32(h + 40, 0);   // codeLimit / hashSize / hashType SHA-256 / platform / pageSize / spare2
    be32(h + 44, 0); be32(h + 48, (uint32_t)team_off); be32(h + 52, 0); be64(h + 56, 0);            // scatter / team / spare3 / codeLimit64
    be64(h + 64, exec_base); be64(h + 72, exec_limit); be64(h + 80, exec_flags);
    memcpy(h + ident_off, ident, ident_n);
    if (team) memcpy(h + team_off, team, team_n);
    // 特殊槽从 hash_off 往前：-1 Info.plist（没有，全零）、-2 Requirements
    memcpy(h + hash_off - 2 * 32, req_hash, 32);
    if (ent_hash) { memcpy(h + hash_off - 5 * 32, ent_hash, 32); memcpy(h + hash_off - 7 * 32, ent_der_hash, 32); }   // -5 XML 权限、-7 DER 权限（-3/-4/-6 没有，全零）
    for (uint32_t i = 0; i < nslots; i++) {
        uint32_t off = i << CS_PAGE_SHIFT, len = limit - off < CS_PAGE ? limit - off : CS_PAGE;
        CC_SHA256(code + off, len, h + hash_off + (size_t)i * 32);
    }
    return 0;
}

// ---------- CMS ----------
static int signed_attrs(const uint8_t cd_sha256[32], buf *set_der) {
    buf a = {0}, all = {0}; int r = 0;
    // contentType = id-data
    { buf v = {0}, s = {0}; r |= der_oid(&v, SS_OID_DATA, sizeof SS_OID_DATA) || der_wrap(&s, 0x31, &v); buf at = {0}; r |= der_oid(&at, SS_OID_CONTENT_TYPE, sizeof SS_OID_CONTENT_TYPE) || bput(&at, s.p, s.n) || der_wrap(&all, 0x30, &at); free(v.p); free(s.p); free(at.p); }
    // signingTime（UTCTime）
    { char ts[16]; time_t now = time(NULL); struct tm g; gmtime_r(&now, &g); strftime(ts, sizeof ts, "%y%m%d%H%M%SZ", &g);
      buf v = {0}, s = {0}, at = {0}; r |= der_tlv(&v, 0x17, ts, strlen(ts)) || der_wrap(&s, 0x31, &v) || der_oid(&at, SS_OID_SIGNING_TIME, sizeof SS_OID_SIGNING_TIME) || bput(&at, s.p, s.n) || der_wrap(&all, 0x30, &at); free(v.p); free(s.p); free(at.p); }
    // messageDigest = SHA-256(CodeDirectory)
    { buf v = {0}, s = {0}, at = {0}; r |= der_tlv(&v, 0x04, cd_sha256, 32) || der_wrap(&s, 0x31, &v) || der_oid(&at, SS_OID_MESSAGE_DIGEST, sizeof SS_OID_MESSAGE_DIGEST) || bput(&at, s.p, s.n) || der_wrap(&all, 0x30, &at); free(v.p); free(s.p); free(at.p); }
    // Apple cdhashes2：SEQUENCE { sha256 OID, OCTET STRING 整个 cdhash }
    { buf seq = {0}, v = {0}, s = {0}, at = {0}; r |= der_oid(&seq, SS_OID_SHA256, sizeof SS_OID_SHA256) || der_tlv(&seq, 0x04, cd_sha256, 32) || der_wrap(&v, 0x30, &seq) || der_wrap(&s, 0x31, &v)
        || der_oid(&at, SS_OID_APPLE_CDHASHES2, sizeof SS_OID_APPLE_CDHASHES2) || bput(&at, s.p, s.n) || der_wrap(&all, 0x30, &at); free(seq.p); free(v.p); free(s.p); free(at.p); }
    // Apple cdhashes（plist，cdhash 截前 20 字节）
    { static const char head[] = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>cdhashes</key>\n\t<array>\n\t\t<data>\n\t\t";
      static const char tail[] = "\n\t\t</data>\n\t</array>\n</dict>\n</plist>\n";
      static const char b64t[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      char b64[32]; int k = 0; for (int i = 0; i < 20; i += 3) { uint32_t v = (uint32_t)cd_sha256[i] << 16 | (i + 1 < 20 ? (uint32_t)cd_sha256[i + 1] << 8 : 0) | (i + 2 < 20 ? cd_sha256[i + 2] : 0);
        b64[k++] = b64t[v >> 18 & 63]; b64[k++] = b64t[v >> 12 & 63]; b64[k++] = i + 1 < 20 ? b64t[v >> 6 & 63] : '='; b64[k++] = i + 2 < 20 ? b64t[v & 63] : '='; } b64[k] = 0;
      buf pl = {0}; r |= bput(&pl, head, sizeof head - 1) || bput(&pl, b64, strlen(b64)) || bput(&pl, tail, sizeof tail - 1);
      buf v = {0}, s = {0}, at = {0}; r |= der_tlv(&v, 0x04, pl.p, pl.n) || der_wrap(&s, 0x31, &v) || der_oid(&at, SS_OID_APPLE_CDHASHES, sizeof SS_OID_APPLE_CDHASHES) || bput(&at, s.p, s.n) || der_wrap(&all, 0x30, &at);
      free(pl.p); free(v.p); free(s.p); free(at.p); }
    r |= der_wrap(set_der, 0x31, &all);   // DER SET OF 按编码升序：五条依次 0x30 0x18 / 0x1c / 0x2f / 0x3d / 0x82…（长度字节递增），上面的写入次序就是这个
    free(a.p); free(all.p); return r ? -1 : 0;
}

static int build_cms(const uint8_t cd_sha256[32], SecKeyRef key, CFArrayRef chain, buf *out) {
    CFIndex nc = chain ? CFArrayGetCount(chain) : 0; if (nc < 1) return -1;
    SecCertificateRef leaf = (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0);
    CFDataRef leaf_der = SecCertificateCopyData(leaf); if (!leaf_der) return -1;
    buf attrs = {0}; if (signed_attrs(cd_sha256, &attrs)) { CFRelease(leaf_der); return -1; }
    CFDataRef tbs = CFDataCreate(NULL, attrs.p, (CFIndex)attrs.n); CFErrorRef err = NULL;
    CFDataRef sig = SecKeyCreateSignature(key, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, tbs, &err); CFRelease(tbs);
    if (!sig) { if (err) CFRelease(err); CFRelease(leaf_der); free(attrs.p); return -1; }
    int r = 0;
    // SignerInfo
    buf si = {0}; uint8_t one = 1;
    r |= der_tlv(&si, 0x02, &one, 1);
    r |= cert_issuer_serial(CFDataGetBytePtr(leaf_der), (size_t)CFDataGetLength(leaf_der), &si);
    r |= alg_sha256(&si);
    attrs.p[0] = 0xa0; r |= bput(&si, attrs.p, attrs.n);   // signedAttrs 写成 [0] IMPLICIT（签名时按 SET 0x31 算）
    { buf ra = {0}; r |= der_oid(&ra, SS_OID_RSA, sizeof SS_OID_RSA) || der_tlv(&ra, 0x05, NULL, 0) || der_wrap(&si, 0x30, &ra); free(ra.p); }
    r |= der_tlv(&si, 0x04, CFDataGetBytePtr(sig), (size_t)CFDataGetLength(sig));
    // SignedData
    buf sd = {0}; r |= der_tlv(&sd, 0x02, &one, 1);
    { buf algs = {0}; r |= alg_sha256(&algs) || der_wrap(&sd, 0x31, &algs); free(algs.p); }
    { buf eci = {0}; r |= der_oid(&eci, SS_OID_DATA, sizeof SS_OID_DATA) || der_wrap(&sd, 0x30, &eci); free(eci.p); }
    { buf certs = {0}; for (CFIndex i = 0; i < nc; i++) { CFDataRef d = SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(chain, i)); if (!d) { r = -1; continue; } r |= bput(&certs, CFDataGetBytePtr(d), (size_t)CFDataGetLength(d)); CFRelease(d); }
      r |= der_wrap(&sd, 0xa0, &certs); free(certs.p); }
    { buf sis = {0}, w = {0}; r |= der_wrap(&w, 0x30, &si) || bput(&sis, w.p, w.n) || der_wrap(&sd, 0x31, &sis); free(w.p); free(sis.p); }
    // ContentInfo
    buf sdseq = {0}, ex = {0}, ci = {0};
    r |= der_wrap(&sdseq, 0x30, &sd) || der_wrap(&ex, 0xa0, &sdseq) || der_oid(&ci, SS_OID_SIGNED_DATA, sizeof SS_OID_SIGNED_DATA) || bput(&ci, ex.p, ex.n) || der_wrap(out, 0x30, &ci);
    free(si.p); free(sd.p); free(sdseq.p); free(ex.p); free(ci.p); free(attrs.p); CFRelease(sig); CFRelease(leaf_der);
    return r ? -1 : 0;
}

// ---------- 权限（免费团队必带）----------
// 免费开发团队的证书过不了系统直接信任，AMFI 改按设备上装的描述文件校验：签名里的权限要能对上描述文件
//   （真机：不带权限 → -415「best matching profile does not match the entitlements」）。
//   只放描述文件里一定有、也足够定位描述文件的两条：application-identifier（团队号.包名）与 team-identifier。
//   XML（0xfade7171）与 DER（0xfade7172）各一份，字节格式照 codesign 输出（同内容逐字节核过）
static int der_str(buf *b, const char *s) { return der_tlv(b, 0x0c, s, strlen(s)); }
static int build_ents(const char *appid, const char *team, buf *xml, buf *der) {
    static const char head[] = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n";
    char body[1024]; int bn = snprintf(body, sizeof body, "\t<key>application-identifier</key>\n\t<string>%s</string>\n\t<key>com.apple.developer.team-identifier</key>\n\t<string>%s</string>\n</dict>\n</plist>\n", appid, team);
    if (bn <= 0 || bn >= (int)sizeof body) return -1;
    uint8_t h[8]; size_t xn = 8 + sizeof head - 1 + (size_t)bn; be32(h, 0xfade7171); be32(h + 4, (uint32_t)xn);
    if (bput(xml, h, 8) || bput(xml, head, sizeof head - 1) || bput(xml, body, (size_t)bn)) return -1;
    // DER：[APPLICATION 16] { INTEGER 1, [CONTEXT 16] { SEQUENCE { key, value } … } }，键按字节序升序（这两条本来就是升序）
    buf kv = {0}, d = {0}, e1 = {0}, e2 = {0}, top = {0}; uint8_t one = 1; int r = 0;
    r |= der_str(&e1, "application-identifier") || der_str(&e1, appid) || der_wrap(&kv, 0x30, &e1);
    r |= der_str(&e2, "com.apple.developer.team-identifier") || der_str(&e2, team) || der_wrap(&kv, 0x30, &e2);
    r |= der_tlv(&top, 0x02, &one, 1) || der_wrap(&top, 0xb0, &kv) || der_wrap(&d, 0x70, &top);
    if (!r) { be32(h, 0xfade7172); be32(h + 4, (uint32_t)(8 + d.n)); r |= bput(der, h, 8) || bput(der, d.p, d.n); }
    free(kv.p); free(d.p); free(e1.p); free(e2.p); free(top.p); return r ? -1 : 0;
}

static int p12_with_mac(const uint8_t *p, size_t n, const char *password, buf *out);

// ---------- Mach-O ----------
// p12 → 私钥 + 证书链；team = 证书 OU（调用方给，或从证书里取）
int s2a_selfsign_identity(const void *p12, size_t n, const char *password, SecKeyRef *key, CFArrayRef *chain) {
    CFDataRef d = CFDataCreate(NULL, p12, (CFIndex)n);
    CFStringRef pw = CFStringCreateWithCString(NULL, password ? password : "", kCFStringEncodingUTF8);
    // 只放进程内存、不进钥匙串（iOS 本来就这样；macOS 不加会写进登录钥匙串、可能弹授权框）
    const void *k[2] = {kSecImportExportPassphrase, NULL}, *v[2] = {pw, kCFBooleanTrue}; CFIndex nk = 1;
    if (__builtin_available(iOS 18.0, macOS 15.0, *)) { k[1] = kSecImportToMemoryOnly; nk = 2; }   // 更老的 iOS 本来就只放内存
    CFDictionaryRef opt = CFDictionaryCreate(NULL, k, v, nk, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef items = NULL; OSStatus st = SecPKCS12Import(d, opt, &items);
    if (st == errSecDecode) {   // -26275：系统接口不认不带 MAC 的 p12（不论里面加没加密，iOS 26.5 模拟器 / macOS 实测），按玩家的密码补上 MAC 再交系统解（D-QSEB）
        buf m = {0};
        if (!p12_with_mac(p12, n, password, &m)) {
            CFDataRef d2 = CFDataCreate(NULL, m.p, (CFIndex)m.n);
            if (items) CFRelease(items);
            items = NULL; st = SecPKCS12Import(d2, opt, &items); CFRelease(d2);
            if (st == errSecDecode) st = errSecAuthFailed;   // MAC 是按这个密码补的、包体却解不开 = 密码不对（实测系统此时回 -26275）：让玩家再输一次
        }
        free(m.p);
    }
    CFRelease(d); CFRelease(pw); CFRelease(opt);
    if (st != errSecSuccess || !items || CFArrayGetCount(items) < 1) { if (items) CFRelease(items); return (int)(st ? st : -1); }
    CFDictionaryRef it = CFArrayGetValueAtIndex(items, 0);
    SecIdentityRef id = (SecIdentityRef)CFDictionaryGetValue(it, kSecImportItemIdentity);
    CFArrayRef ch = CFDictionaryGetValue(it, kSecImportItemCertChain);
    if (!id || SecIdentityCopyPrivateKey(id, key) != errSecSuccess) { CFRelease(items); return -2; }
    if (ch && CFArrayGetCount(ch) > 0) *chain = CFRetain(ch);
    else { SecCertificateRef c = NULL; SecIdentityCopyCertificate(id, &c); const void *cv[] = {c}; *chain = CFArrayCreate(NULL, cv, 1, &kCFTypeArrayCallBacks); if (c) CFRelease(c); }
    CFRelease(items); return 0;
}

// 给 in（整份文件，arm64 单架构 dylib / 可执行）签名，结果写 out（调用方 free）。ident = 签名标识（NULL = 沿用原签名里的），team = 团队号，
//   appid = 「团队号.包名」（非 NULL 就带上权限：免费团队必须，付费团队带上也无妨）
int s2a_selfsign_macho(const uint8_t *in, size_t n, const char *ident, const char *team, const char *appid, SecKeyRef key, CFArrayRef chain, uint8_t **out, size_t *out_n, char *why, size_t why_n) {
#define FAIL(...) do { snprintf(why, why_n, __VA_ARGS__); free(cd.p); free(cms.p); free(req.p); free(sb.p); free(o.p); free(ex.p); free(ed.p); return -1; } while (0)
    buf cd = {0}, cms = {0}, req = {0}, sb = {0}, o = {0}, ex = {0}, ed = {0};
    if (n < sizeof(struct ss_mach_header_64)) FAIL("文件太小");
    const struct ss_mach_header_64 *mh = (const void *)in;
    if (mh->magic != SS_MH_MAGIC_64 || mh->cputype != SS_CPU_TYPE_ARM64) FAIL("不是 arm64 单架构 Mach-O（magic %#x）", mh->magic);
    const uint8_t *lc = in + sizeof *mh; struct ss_linkedit_data_command *sig = NULL; struct ss_segment_command_64 *le = NULL; uint64_t text_off = 0, text_size = 0;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct ss_load_command *c = (const void *)lc;
        if (c->cmd == SS_LC_CODE_SIGNATURE) sig = (void *)c;
        if (c->cmd == SS_LC_SEGMENT_64) { struct ss_segment_command_64 *s = (void *)c; if (!strcmp(s->segname, "__LINKEDIT")) le = s; if (!strcmp(s->segname, "__TEXT")) { text_off = s->fileoff; text_size = s->filesize; } }
        lc += c->cmdsize;
    }
    if (!sig || !le) FAIL("没有 SS_LC_CODE_SIGNATURE / __LINKEDIT（要先有一份签名，ad-hoc 也行）");
    uint32_t limit = sig->dataoff;
    if (limit > n || le->fileoff > limit) FAIL("签名偏移越界");
    // 带权限时签名标识取 appid 的包名部分：免费团队按描述文件校验，libmis 拿「团队号.签名标识」对描述文件的 application-identifier
    //   （真机：标识沿用 ad-hoc 的 img_xxx-哈希 → 「Local Profile has non-matching application-identifier」→ -415）
    if (!ident && appid && *appid) { const char *dot = strchr(appid, '.'); if (dot && dot[1]) ident = dot + 1; }
    // 沿用原标识
    char ident_buf[512] = {0};
    if (!ident) {
        const uint8_t *sbp = in + sig->dataoff; uint32_t cnt = sig->datasize >= 12 ? rd32be(sbp + 8) : 0;
        for (uint32_t i = 0; i < cnt && 12 + i * 8 + 8 <= sig->datasize; i++) {
            uint32_t type = rd32be(sbp + 12 + i * 8), off = rd32be(sbp + 16 + i * 8);
            if (type == 0 && off + 24 <= sig->datasize && rd32be(sbp + off) == 0xfade0c02) { uint32_t io = rd32be(sbp + off + 20); snprintf(ident_buf, sizeof ident_buf, "%s", (const char *)sbp + off + io); break; }
        }
        if (!ident_buf[0]) FAIL("原签名里找不到标识");
        ident = ident_buf;
    }
    // 空 Requirements 集合：magic 0xfade0c01 / 长度 12 / 个数 0
    uint8_t rq[12]; be32(rq, 0xfade0c01); be32(rq + 4, 12); be32(rq + 8, 0); bput(&req, rq, 12);
    uint8_t req_hash[32]; CC_SHA256(rq, 12, req_hash);
    uint8_t ent_hash[32], ent_der_hash[32]; int ents = appid && *appid;
    if (ents) {
        if (!team || !*team) FAIL("带权限要给团队号");
        if (build_ents(appid, team, &ex, &ed)) FAIL("出权限失败");
        CC_SHA256(ex.p, (CC_LONG)ex.n, ent_hash); CC_SHA256(ed.p, (CC_LONG)ed.n, ent_der_hash);
    }
    uint32_t nblob = ents ? 5 : 3, ents_n = ents ? (uint32_t)(ex.n + ed.n) : 0;
    // 先算一次签名大小，改头再出 CD（CD 覆盖到 codeLimit，含已改过的头）
    uint8_t *code = malloc(limit); if (!code) FAIL("内存不足"); memcpy(code, in, limit);
    uint32_t est = 0;
    for (int pass = 0; pass < 2; pass++) {
        free(cd.p); cd = (buf){0}; free(cms.p); cms = (buf){0};
        if (pass == 1) {   // 按估好的大小改 SS_LC_CODE_SIGNATURE 与 __LINKEDIT
            struct ss_linkedit_data_command *s2 = (void *)(code + ((const uint8_t *)sig - in));
            struct ss_segment_command_64 *l2 = (void *)(code + ((const uint8_t *)le - in));
            s2->datasize = est; l2->filesize = (uint64_t)limit + est - l2->fileoff;
            l2->vmsize = (l2->filesize + CS_PAGE - 1) & ~(uint64_t)(CS_PAGE - 1);
        }
        if (build_cd(code, limit, ident, team, req_hash, ents ? ent_hash : NULL, ents ? ent_der_hash : NULL, text_off, text_size, mh->filetype == SS_MH_EXECUTE ? 1 : 0, &cd)) { free(code); FAIL("出 CodeDirectory 失败"); }
        uint8_t h[32]; CC_SHA256(cd.p, (CC_LONG)cd.n, h);
        if (build_cms(h, key, chain, &cms)) { free(code); FAIL("出 CMS 签名失败（私钥签不了或证书解析失败）"); }
        uint32_t need = (uint32_t)(12 + nblob * 8 + cd.n + req.n + ents_n + cms.n + 8);
        if (pass == 0) est = (need + 1024 + 15) & ~15u;   // 留 1 KiB 余量（第二遍签名时间长度不变，CMS 长度只差几个字节）
        else if (need > est) { free(code); FAIL("签名比预留大（%u > %u）", need, est); }
    }
    // SuperBlob：CodeDirectory(0) / Requirements(2) / [XML 权限(5) / DER 权限(7)] / CMS(0x10000)，索引按类型升序
    uint32_t off0 = 12 + nblob * 8, off1 = off0 + (uint32_t)cd.n, offx = off1 + (uint32_t)req.n, offd = offx + (uint32_t)ex.n, off2 = off1 + (uint32_t)req.n + ents_n;
    bput(&sb, NULL, off0); be32(sb.p, 0xfade0cc0); be32(sb.p + 8, nblob);
    { uint8_t *ix = sb.p + 12; be32(ix, 0); be32(ix + 4, off0); be32(ix + 8, 2); be32(ix + 12, off1); ix += 16;
      if (ents) { be32(ix, 5); be32(ix + 4, offx); be32(ix + 8, 7); be32(ix + 12, offd); ix += 16; }
      be32(ix, 0x10000); be32(ix + 4, off2); }
    bput(&sb, cd.p, cd.n); bput(&sb, req.p, req.n); if (ents) { bput(&sb, ex.p, ex.n); bput(&sb, ed.p, ed.n); }
    { uint8_t wh[8]; be32(wh, 0xfade0b01); be32(wh + 4, (uint32_t)cms.n + 8); bput(&sb, wh, 8); bput(&sb, cms.p, cms.n); }   // CMS 包成 BlobWrapper
    if (sb.n > est) { free(code); FAIL("SuperBlob 比预留大"); }
    be32(sb.p + 4, (uint32_t)sb.n);
    bput(&o, code, limit); bput(&o, sb.p, sb.n); bput(&o, NULL, est - sb.n);
    free(code); free(cd.p); free(cms.p); free(req.p); free(sb.p); free(ex.p); free(ed.p);
    *out = o.p; *out_n = o.n; return 0;
#undef FAIL
}

// ---------- 真机验证入口（0.6.0 可行性，开发用环境变量；玩家路径不设就不走）----------
// S2A_SELFSIGN_P12 / S2A_SELFSIGN_IN / S2A_SELFSIGN_OUT（@home/ 前缀 = App 数据容器）、S2A_SELFSIGN_PW、S2A_SELFSIGN_TEAM、
//   S2A_SELFSIGN_APPID（团队号.包名，给了就带权限；免费团队必须）：
//   起局构造期（launchctx.c 定启动上下文之前）在手机上把 IN 用 p12 重签写到 OUT，日志记耗时与大小；之后照常按启动上下文加载 OUT
static int home_path(char *out, size_t n, const char *p) {
    if (!strncmp(p, "@home/", 6)) { const char *h = getenv("HOME"); if (!h) return -1; snprintf(out, n, "%s/%s", h, p + 6); } else snprintf(out, n, "%s", p);
    return 0;
}
static uint8_t *slurp(const char *p, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long l = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = l > 0 ? malloc((size_t)l) : NULL; if (b && fread(b, 1, (size_t)l, f) != (size_t)l) { free(b); b = NULL; }
    fclose(f); *n = (size_t)l; return b;
}
// ---------- 签名身份交接（0.6.0 通用壳，电脑侧 pack/jobs/install.py deliver_identity）----------
// 电脑经 USB 把私钥（PKCS#1 RSAPrivateKey DER）与叶证书（DER）放进 App 数据容器 Library/Application Support/S2Arm/identity/incoming/{key.der, cert.der, identity.json}
//   （维护者定：私钥是玩家自己的，进他自己账号的加密备份无妨；App 一打开就导入、立刻删，躺的时间很短），
//   identity.json 最后改名 = 三份齐了。App 启动时（s2a_selfsign_probe 开头，构造期）导入钥匙串（本 App 访问组、首次解锁后、仅本机），
//   确认能配成签名身份（真机 11-17 一台测试 iPhone：分别 SecItemAdd 的私钥与证书配得上）→ 删 incoming/ 三份 → 写不含私钥的
//   Library/Application Support/S2Arm/identity/current.json（电脑推送时读它判要不要重交）；
//   证书换了不批量重签：起哪款签哪款（起局时按款重签）。任何一步失败：incoming/ 留着、写 identity/import_error.txt，起局照常
// 钥匙串按证书各存一份（0.6.0 走查：团队不符的新证书顶掉原来能用的那张，之后导入的游戏全签不了）：标签 = SS_KC_LABEL.<证书 sha1>，
//   存一张只换掉同一张的旧项，别的证书原样留着；用哪张由 identity/current.json 定（ios/sign_state.m s2a_cert_settle 按 App 团队挑），起局按它的 sha1 取（s2a_identity_keychain）。
//   0.6.0 测试包存的旧标签（不带 sha1）那一项不动，按 sha1 取时照样认得
#define SS_KC_LABEL "io.s2arm.selfsign.identity"
static int kc_store_real(SecKeyRef k, SecCertificateRef c, char *why, size_t why_n) {   // 换掉同一张证书的旧项再存；存后按身份取回核配得上
    char lab[96] = SS_KC_LABEL; CFDataRef cder = SecCertificateCopyData(c);
    if (cder) { uint8_t h[CC_SHA1_DIGEST_LENGTH]; CC_SHA1(CFDataGetBytePtr(cder), (CC_LONG)CFDataGetLength(cder), h); CFRelease(cder);
                size_t o = strlen(lab); lab[o++] = '.'; for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++, o += 2) snprintf(lab + o, 3, "%02x", h[i]); }
    CFStringRef label = CFStringCreateWithCString(NULL, lab, kCFStringEncodingUTF8);
    const void *dk[] = {kSecClass, kSecAttrLabel}, *dv1[] = {kSecClassKey, label}, *dv2[] = {kSecClassCertificate, label};
    CFDictionaryRef d1 = CFDictionaryCreate(NULL, dk, dv1, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks), d2 = CFDictionaryCreate(NULL, dk, dv2, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecItemDelete(d1); SecItemDelete(d2); CFRelease(d1); CFRelease(d2);
    const void *ak[] = {kSecClass, kSecValueRef, kSecAttrLabel, kSecAttrAccessible};
    const void *av1[] = {kSecClassKey, k, label, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly}, *av2[] = {kSecClassCertificate, c, label, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    CFDictionaryRef q1 = CFDictionaryCreate(NULL, ak, av1, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks), q2 = CFDictionaryCreate(NULL, ak, av2, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus s1 = SecItemAdd(q1, NULL), s2 = SecItemAdd(q2, NULL); CFRelease(q1); CFRelease(q2); CFRelease(label);
    if (s1 == errSecDuplicateItem) s1 = 0;   // 同一张证书的旧标签项（0.6.0 测试包）还在：钥匙串按内容去重，下面按身份取回核配得上
    if (s2 == errSecDuplicateItem) s2 = 0;
    if (s1 || s2) { snprintf(why, why_n, "存钥匙串失败（私钥 %d、证书 %d）", (int)s1, (int)s2); return -1; }
    const void *qk[] = {kSecClass, kSecReturnRef, kSecMatchLimit}, *qv[] = {kSecClassIdentity, kCFBooleanTrue, kSecMatchLimitAll};
    CFDictionaryRef q3 = CFDictionaryCreate(NULL, qk, qv, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFTypeRef got = NULL; OSStatus s3 = SecItemCopyMatching(q3, &got); CFRelease(q3);
    CFDataRef want = SecCertificateCopyData(c); int ok = 0;
    for (CFIndex i = 0; s3 == errSecSuccess && got && CFGetTypeID(got) == CFArrayGetTypeID() && i < CFArrayGetCount(got) && !ok; i++) {
        SecCertificateRef ic = NULL; if (SecIdentityCopyCertificate((SecIdentityRef)CFArrayGetValueAtIndex(got, i), &ic) || !ic) continue;
        CFDataRef dd = SecCertificateCopyData(ic); ok = dd && CFEqual(dd, want); if (dd) CFRelease(dd); CFRelease(ic);
    }
    if (got) CFRelease(got); CFRelease(want);
    if (!ok) { snprintf(why, why_n, "存进钥匙串了，但私钥和证书配不成签名身份（取回 %d）", (int)s3); return -1; }
    return 0;
}
static int (*g_kc_store)(SecKeyRef, SecCertificateRef, char *, size_t) = kc_store_real;
#ifdef S2A_UNIT_TEST
void s2a_identity_test_store(int (*f)(SecKeyRef, SecCertificateRef, char *, size_t)) { g_kc_store = f ? f : kc_store_real; }   // 单测换掉钥匙串（不碰本机钥匙串、不弹授权框）
#endif
static void json_str(const char *j, const char *key, char *out, size_t n) {   // 取 "key":"值"（只认这一种写法；电脑侧 json.dumps 写的）
    out[0] = 0; char pat[64]; snprintf(pat, sizeof pat, "\"%s\"", key); const char *p = j ? strstr(j, pat) : NULL; if (!p) return;
    p = strchr(p + strlen(pat), ':'); if (!p) return; p++; while (*p == ' ') p++; if (*p != '"') return; p++;
    size_t i = 0; while (*p && *p != '"' && i + 1 < n) out[i++] = *p++; out[i] = 0;
}
static int write_file(const char *path, const char *text) {
    char tmp[1100]; snprintf(tmp, sizeof tmp, "%s.tmp", path); FILE *f = fopen(tmp, "w"); if (!f) return -1;
    int ok = fputs(text, f) >= 0; if (fclose(f)) ok = 0; return ok && !rename(tmp, path) ? 0 : -1;
}
// 导入成功后写不含私钥的 current.json（电脑推送时读它判要不要重交；起局重签按它认现在这张证书），source = pc（电脑交来）/ p12（手机上直接导入）
// 同时登记进 identity/certs.tsv（导入成功过的每张证书一行：sha1、团队、来源、时刻；同一张只留最新一行）：current.json 只记现在用哪张，
//   这张表记手机上有哪几张，导了别的团队的证书后 ios/sign_state.m s2a_cert_settle 按它把 current.json 挑回与 App 同团队的那张
static void certs_note(const char *cur, const char *team, const char *sha, const char *source) {
    char tsv[1200]; snprintf(tsv, sizeof tsv, "%s", cur); char *slash = strrchr(tsv, '/'); if (!slash) return; snprintf(slash + 1, sizeof tsv - (size_t)(slash + 1 - tsv), "certs.tsv");
    size_t n = 0; uint8_t *old = slurp(tsv, &n); size_t cap = n + 256; char *out = malloc(cap); if (!out) { free(old); return; } size_t o = 0;
    for (char *line = old ? (char *)old : NULL, *end = old ? (char *)old + n : NULL; line && line < end; ) {   // 照抄别的证书那几行
        char *nl = memchr(line, '\n', (size_t)(end - line)); size_t ln = nl ? (size_t)(nl - line) : (size_t)(end - line);
        if (ln && !(ln > strlen(sha) && !strncasecmp(line, sha, strlen(sha)) && line[strlen(sha)] == '\t')) { memcpy(out + o, line, ln); o += ln; out[o++] = '\n'; }
        line += ln + 1;
    }
    o += (size_t)snprintf(out + o, cap - o, "%s\t%s\t%s\t%ld\n", sha, team, source, (long)time(NULL)); free(old);
    char tmp[1300]; snprintf(tmp, sizeof tmp, "%s.tmp", tsv); FILE *f = fopen(tmp, "w"); int ok = f && fwrite(out, 1, o, f) == o; if (f && fclose(f)) ok = 0; free(out);
    if (!ok || rename(tmp, tsv)) LOG("【黄】签名证书登记表 certs.tsv 写不进（这张证书照样能用；导别的团队的证书后挑不回它）");
}
static void current_write(const char *cur, const char *team, const char *sha, const char *source, const char *note) {
    certs_note(cur, team, sha, source);
    char prev[64] = {0}; { size_t pn = 0; uint8_t *pb = slurp(cur, &pn); char *ps = pb ? realloc(pb, pn + 1) : NULL; if (ps) { ps[pn] = 0; json_str(ps, "cert_sha1", prev, sizeof prev); free(ps); } else free(pb); }
    char cj[300]; snprintf(cj, sizeof cj, "{\"schema\": 1, \"team\": \"%s\", \"cert_sha1\": \"%s\", \"imported\": %ld, \"source\": \"%s\"}\n", team, sha, (long)time(NULL), source);
    if (write_file(cur, cj)) LOG("【黄】签名身份已进钥匙串，但 current.json 写不进（起局重签认不到这张证书；电脑下次推送会重交一次）");
    int changed = strcasecmp(prev, sha) != 0;
    LOG("签名身份已导入钥匙串（%s）：团队 %s、证书 sha1 %s（%s）；%s", source, team[0] ? team : "?", sha, !prev[0] ? "第一次" : changed ? "换了证书" : "同一张证书", note);
    if (changed && prev[0]) LOG("签名证书换了：各款不批量重签，玩家起哪款、起局时发现签名证书不同就当场重签那一款（维护者 0.6.0 总原则：点了才做、只做这一款）");
}
// 返回 0 = 没有要导入的；1 = 导入成功；-1 = 失败（已写 import_error.txt）
int s2a_identity_import(const char *home) {
    if (!home) return 0;
    char dir[1024], inc[1100], pj[1200], pk[1200], pc[1200], cur[1200], err[1200];
    snprintf(dir, sizeof dir, "%s/Library/Application Support/S2Arm/identity", home); snprintf(inc, sizeof inc, "%s/incoming", dir);
    snprintf(pj, sizeof pj, "%s/identity.json", inc); snprintf(pk, sizeof pk, "%s/key.der", inc); snprintf(pc, sizeof pc, "%s/cert.der", inc);
    snprintf(cur, sizeof cur, "%s/current.json", dir); snprintf(err, sizeof err, "%s/import_error.txt", dir);
    size_t jn = 0, kn = 0, cn = 0; uint8_t *jb = slurp(pj, &jn); if (!jb) return 0;   // 没有 identity.json = 没交、或还没交齐
    for (char *q = (char *)dir + 1; *q; q++) if (*q == '/') { *q = 0; mkdir(dir, 0755); *q = '/'; } mkdir(dir, 0755);   // current.json / import_error.txt 的目录
    char *js = realloc(jb, jn + 1); if (!js) { free(jb); return 0; } js[jn] = 0;
    char team[64], want_sha[64], why[256] = {0}; json_str(js, "team", team, sizeof team); json_str(js, "cert_sha1", want_sha, sizeof want_sha); free(js);
    uint8_t *kb = slurp(pk, &kn), *cb = slurp(pc, &cn); SecKeyRef k = NULL; SecCertificateRef c = NULL; int rc = -1; char sha[41] = {0};
    if (!kb || !cb) snprintf(why, sizeof why, "identity.json 在，但缺 %s", !kb ? "key.der" : "cert.der");
    else {
        CFDataRef kd = CFDataCreate(NULL, kb, (CFIndex)kn), cd = CFDataCreate(NULL, cb, (CFIndex)cn);
        const void *ak[] = {kSecAttrKeyType, kSecAttrKeyClass}, *av[] = {kSecAttrKeyTypeRSA, kSecAttrKeyClassPrivate};
        CFDictionaryRef ka = CFDictionaryCreate(NULL, ak, av, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        k = SecKeyCreateWithData(kd, ka, NULL); c = SecCertificateCreateWithData(NULL, cd); CFRelease(ka); CFRelease(kd); CFRelease(cd);
        uint8_t h[CC_SHA1_DIGEST_LENGTH]; CC_SHA1(cb, (CC_LONG)cn, h); for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) snprintf(sha + 2 * i, 3, "%02x", h[i]);
        if (!k || !c) snprintf(why, sizeof why, "%s读不了（不是 PKCS#1 RSA 私钥 / DER 证书）", !k ? "私钥" : "证书");
        else if (want_sha[0] && strcasecmp(want_sha, sha)) snprintf(why, sizeof why, "证书 sha1 对不上（identity.json %s，实际 %s）", want_sha, sha);
        else rc = g_kc_store(k, c, why, sizeof why);
    }
    if (kb) { memset(kb, 0, kn); free(kb); } free(cb); if (k) CFRelease(k); if (c) CFRelease(c);
    if (rc) { char t[400]; snprintf(t, sizeof t, "%s\n", why); write_file(err, t); LOG("【红】签名身份导入失败：%s（incoming/ 留着，电脑下次推送时说明；起局照常用电脑签好的）", why); return -1; }
    unlink(pk); unlink(pc); unlink(pj); unlink(err); rmdir(inc);   // 先删私钥，再写 current.json
    current_write(cur, team, sha, "pc", "incoming/ 已删");
    return 1;
}

// 不带 MAC、不加密的 PKCS#12（SideStore「导出证书给别的 App」给的就是这种：CodeSignKit PKCS12Builder 只拼 keyBag + certBag，密码参数不用，没有 macData）。
//   系统 SecPKCS12Import 对它的结果因系统版本而异，导不进时按结构直接取：PFX { 版本 3, ContentInfo(data) { AuthenticatedSafe { ContentInfo(data) { SafeContents { SafeBag… } } … } } }。
//   keyBag（1.2.840.113549.1.12.10.1.1）里是 PKCS#8 PrivateKeyInfo → 取里面的 RSAPrivateKey（PKCS#1）；certBag（…10.1.3）里 x509Certificate 的 OCTET STRING 是证书 DER。
//   加密的 bag（shroudedKeyBag、encryptedData）这里不解：那种 p12 系统接口认。0 = 取到私钥与证书（指向输入内部），-1 = 不是这种格式
static const uint8_t SS_OID_KEYBAG[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x0c,0x0a,0x01,0x01}, SS_OID_CERTBAG[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x0c,0x0a,0x01,0x03};
static int oid_is(const uint8_t *p, const uint8_t *end, const uint8_t *oid, size_t on, const uint8_t **next) {
    uint8_t t; size_t l; const uint8_t *v = der_read(p, end, &t, &l, next); return v && t == 0x06 && l == on && !memcmp(v, oid, on);
}
static const uint8_t *data_content(const uint8_t *ci, size_t n, size_t *out_n) {   // ContentInfo(data) → [0] OCTET STRING 的内容
    const uint8_t *end = ci + n, *nx; uint8_t t; size_t l;
    if (!oid_is(ci, end, SS_OID_DATA, sizeof SS_OID_DATA, &nx)) return NULL;
    const uint8_t *e0 = der_read(nx, end, &t, &l, &nx); if (!e0 || t != 0xa0) return NULL;
    const uint8_t *nx2, *oc = der_read(e0, e0 + l, &t, out_n, &nx2); return oc && t == 0x04 ? oc : NULL;
}
// 给不带 MAC 的 p12 补上 MAC（RFC 7292：HMAC-SHA1，密钥按附录 B 由密码、8 字节随机盐、2048 轮、ID = 3 派生），authSafe 原样不动 → out（调用方 free）。
//   有的签名工具导出的 p12 包体照常加密、只是不写 macData，系统 SecPKCS12Import 一律回 -26275；补上后加解密仍全交系统，密码不对系统照常回 -25293。
//   已带 MAC / 结构认不出 / authSafe 不是 data → -1
static int p12_with_mac(const uint8_t *p, size_t n, const char *password, buf *out) {
    const uint8_t *end = p + n, *nx, *nx2; uint8_t t; size_t l, cl;
    const uint8_t *pfx = der_read(p, end, &t, &l, &nx); if (!pfx || t != 0x30) return -1;
    const uint8_t *pend = pfx + l;
    if (!der_read(pfx, pend, &t, &cl, &nx) || t != 0x02) return -1;   // version
    const uint8_t *ci = der_read(nx, pend, &t, &cl, &nx2); if (!ci || t != 0x30 || nx2 != pend) return -1;   // authSafe 之后还有东西 = 已带 MAC
    size_t an; const uint8_t *auth = data_content(ci, cl, &an); if (!auth) return -1;
    // 密码 → BMPString（UTF-16 大端，带结尾 00 00）
    CFStringRef ps = CFStringCreateWithCString(NULL, password ? password : "", kCFStringEncodingUTF8); if (!ps) return -1;
    CFIndex ul = CFStringGetLength(ps), pl = (ul + 1) * 2; uint8_t *pw = calloc(1, (size_t)pl);
    CFIndex got = 0; CFStringGetBytes(ps, CFRangeMake(0, ul), kCFStringEncodingUTF16BE, 0, false, pw, pl - 2, &got); CFRelease(ps);
    pl = got ? got + 2 : 0;   // 空密码：系统算 MAC 时不带结尾 00 00（实测带上就回 -25293）
    // 附录 B.2，SHA-1：u = 20、v = 64，要 20 字节 = 一块 A1；I = S ‖ P（各补满 64 的整数倍）
    enum { V = 64, IT = 2048 }; uint8_t salt[8]; arc4random_buf(salt, sizeof salt);
    size_t sl = V, plen = (size_t)((pl + V - 1) / V) * V, il = sl + plen; uint8_t *di = malloc(V + il), a[CC_SHA1_DIGEST_LENGTH];
    memset(di, 3, V);
    for (size_t i = 0; i < sl; i++) di[V + i] = salt[i % sizeof salt];
    for (size_t i = 0; i < plen; i++) di[V + sl + i] = pw[i % (size_t)pl];   // pl = 0 时 plen = 0，不进循环
    CC_SHA1(di, (CC_LONG)(V + il), a);
    for (int r = 1; r < IT; r++) CC_SHA1(a, sizeof a, a);
    free(di); free(pw);
    uint8_t mac[CC_SHA1_DIGEST_LENGTH]; CCHmac(kCCHmacAlgSHA1, a, sizeof a, auth, an, mac);
    // MacData { DigestInfo { AlgorithmIdentifier { sha1, NULL }, mac }, salt, 2048 }
    static const uint8_t SS_OID_SHA1[] = {0x2b, 0x0e, 0x03, 0x02, 0x1a}; const uint8_t iters[] = {0x08, 0x00};
    buf alg = {0}, dg = {0}, md = {0}, body = {0}; int r = 0;
    r |= der_oid(&alg, SS_OID_SHA1, sizeof SS_OID_SHA1) || der_tlv(&alg, 0x05, NULL, 0) || der_wrap(&dg, 0x30, &alg) || der_tlv(&dg, 0x04, mac, sizeof mac);
    r |= der_wrap(&md, 0x30, &dg) || der_tlv(&md, 0x04, salt, sizeof salt) || der_tlv(&md, 0x02, iters, sizeof iters);
    r |= bput(&body, pfx, (size_t)(pend - pfx)) || der_wrap(&body, 0x30, &md) || der_wrap(out, 0x30, &body);
    free(alg.p); free(dg.p); free(md.p); free(body.p);
    return r ? -1 : 0;
}
static int p12_plain(const uint8_t *p, size_t n, const uint8_t **key, size_t *key_n, const uint8_t **cert, size_t *cert_n) {
    const uint8_t *end = p + n, *nx, *c; uint8_t t; size_t l; *key = *cert = NULL;
    if (!(c = der_read(p, end, &t, &l, &nx)) || t != 0x30) return -1;                                   // PFX
    const uint8_t *pend = c + l, *v = der_read(c, pend, &t, &l, &nx); if (!v || t != 0x02 || l != 1 || *v != 3) return -1;   // 版本 3
    const uint8_t *ci = der_read(nx, pend, &t, &l, &nx); if (!ci || t != 0x30) return -1;              // authSafe ContentInfo
    size_t an; const uint8_t *as = data_content(ci, l, &an); if (!as) return -1;
    const uint8_t *asq = der_read(as, as + an, &t, &l, &nx); if (!asq || t != 0x30) return -1;          // AuthenticatedSafe
    for (const uint8_t *q = asq, *qend = asq + l; q < qend; ) {
        const uint8_t *ci2 = der_read(q, qend, &t, &l, &nx); if (!ci2 || t != 0x30) return -1; q = nx;
        size_t sn; const uint8_t *sc = data_content(ci2, l, &sn); if (!sc) continue;                     // 加密的 ContentInfo：跳过
        const uint8_t *scq = der_read(sc, sc + sn, &t, &l, &nx); if (!scq || t != 0x30) continue;        // SafeContents
        for (const uint8_t *b = scq, *bend = scq + l; b < bend; ) {
            const uint8_t *bnx, *bag = der_read(b, bend, &t, &l, &bnx); if (!bag || t != 0x30) break; b = bnx;
            const uint8_t *bagend = bag + l, *vnx;
            int is_key = oid_is(bag, bagend, SS_OID_KEYBAG, sizeof SS_OID_KEYBAG, &vnx), is_cert = !is_key && oid_is(bag, bagend, SS_OID_CERTBAG, sizeof SS_OID_CERTBAG, &vnx);
            if (!is_key && !is_cert) continue;
            const uint8_t *e0 = der_read(vnx, bagend, &t, &l, &vnx); if (!e0 || t != 0xa0) continue;
            const uint8_t *inner = der_read(e0, e0 + l, &t, &l, &vnx); if (!inner || t != 0x30) continue;
            const uint8_t *iend = inner + l, *x;
            if (is_key) {   // PrivateKeyInfo { INTEGER 版本, AlgorithmIdentifier, OCTET STRING RSAPrivateKey }
                if (!der_read(inner, iend, &t, &l, &x) || t != 0x02) continue;
                if (!der_read(x, iend, &t, &l, &x) || t != 0x30) continue;
                const uint8_t *k = der_read(x, iend, &t, &l, &x); if (!k || t != 0x04) continue;
                *key = k; *key_n = l;
            } else {        // CertBag { x509Certificate OID, [0] OCTET STRING 证书 DER }
                if (!der_read(inner, iend, &t, &l, &x) || t != 0x06) continue;
                const uint8_t *ce0 = der_read(x, iend, &t, &l, &x); if (!ce0 || t != 0xa0) continue;
                const uint8_t *cd = der_read(ce0, ce0 + l, &t, &l, &x); if (!cd || t != 0x04) continue;
                if (!*cert) { *cert = cd; *cert_n = l; }   // 第一张是叶证书（后面若有中间证书不要）
            }
        }
    }
    return *key && *cert ? 0 : -1;
}

// 玩家在手机上直接导入 .p12（0.6.0：买了开发者证书的玩家不经电脑）：解 p12 → 存钥匙串（按证书各存一份，不顶掉别的证书）→ 写 current.json（source p12）、登记 certs.tsv。
//   source 写进 current.json（p12 = 玩家选的 .p12 文件，sidestore = SideStore「导出证书」回调；NULL 按 p12）。团队号取叶证书的 OU（苹果开发证书的 OU 就是团队号）。返回 0 = 导入了（team 带回团队号）；1 = 密码不对（调用方再问一次）；-1 = 失败（why 写原因）。
//   p12 文件本身由调用方在成功后删（它在「放这里导入」里）
int s2a_identity_import_p12(const char *home, const void *p12, size_t n, const char *password, const char *source, char *team, size_t team_n, char *why, size_t why_n) {
    if (team && team_n) team[0] = 0;
    if (why && why_n) why[0] = 0;
    if (!home || !p12 || !n) { snprintf(why, why_n, "没有文件内容"); return -1; }
    SecKeyRef key = NULL; CFArrayRef chain = NULL;
    int rc = s2a_selfsign_identity(p12, n, password, &key, &chain);
    if (rc || !key || !chain || CFArrayGetCount(chain) < 1) {   // 系统导不进：试不带 MAC、不加密的那种（SideStore 导出），按结构直接取
        if (key) CFRelease(key); if (chain) CFRelease(chain); key = NULL; chain = NULL;
        const uint8_t *kd, *cd; size_t kn, cn;
        if (!p12_plain(p12, n, &kd, &kn, &cd, &cn)) {
            CFDataRef kdat = CFDataCreate(NULL, kd, (CFIndex)kn), cdat = CFDataCreate(NULL, cd, (CFIndex)cn);
            const void *ak[] = {kSecAttrKeyType, kSecAttrKeyClass}, *av[] = {kSecAttrKeyTypeRSA, kSecAttrKeyClassPrivate};
            CFDictionaryRef ka = CFDictionaryCreate(NULL, ak, av, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            key = SecKeyCreateWithData(kdat, ka, NULL); SecCertificateRef c = SecCertificateCreateWithData(NULL, cdat);
            CFRelease(ka); CFRelease(kdat); CFRelease(cdat);
            if (key && c) { const void *cv[] = {c}; chain = CFArrayCreate(NULL, cv, 1, &kCFTypeArrayCallBacks); LOG(".p12 导入：系统接口导不进（%d），按不带 MAC 的明文 PKCS#12 取到私钥与证书（SideStore 导出的格式）", rc); rc = 0; }
            if (c) CFRelease(c);
            if (rc) { if (key) CFRelease(key); key = NULL; }
        }
        if (rc == errSecAuthFailed) return 1;   // -25293：密码不对（明文格式也取不到时才算）
        if (rc || !key || !chain) { if (key) CFRelease(key); if (chain) CFRelease(chain); snprintf(why, why_n, "不是能用的证书文件（.p12 读不了：%d）", rc); return -1; }
    }
    SecCertificateRef leaf = (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0);
    CFDataRef der = SecCertificateCopyData(leaf); char t[64] = "", sha[41] = "";
    if (der) { uint8_t h[CC_SHA1_DIGEST_LENGTH]; CC_SHA1(CFDataGetBytePtr(der), (CC_LONG)CFDataGetLength(der), h); for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) snprintf(sha + 2 * i, 3, "%02x", h[i]);
               cert_team(CFDataGetBytePtr(der), (size_t)CFDataGetLength(der), t, sizeof t); CFRelease(der); }
    char w[256] = ""; rc = der ? g_kc_store(key, leaf, w, sizeof w) : -1;
    CFRelease(key); CFRelease(chain);
    if (rc) { snprintf(why, why_n, "%s", w[0] ? w : "证书读不了"); LOG("【红】.p12 导入失败：%s", why); return -1; }
    char dir[1024], cur[1200]; snprintf(dir, sizeof dir, "%s/Library/Application Support/S2Arm/identity", home); snprintf(cur, sizeof cur, "%s/current.json", dir);
    for (char *q = dir + 1; *q; q++) if (*q == '/') { *q = 0; mkdir(dir, 0755); *q = '/'; } mkdir(dir, 0755);
    if (!source || !*source) source = "p12";
    current_write(cur, t, sha, source, !strcmp(source, "sidestore") ? "从 SideStore 取来的证书" : "玩家在手机上导入的 .p12");
    if (team && team_n) snprintf(team, team_n, "%s", t);
    return 0;
}

// ---------- 手机上签程序要的身份与证书链（0.6.0 通用壳：起局时按款重签，ios/program_resign.m）----------
#include "selfsign_certs.inc"
// 叶证书后接 WWDR G3 与 Apple Root。叶证书若是别一代 WWDR 签的，系统注册签名时会拒（日志「注册签名失败 errno=1」），这里不猜
CFArrayRef s2a_selfsign_chain_for(SecCertificateRef leaf) {
    if (!leaf) return NULL;
    CFMutableArrayRef a = CFArrayCreateMutable(NULL, 3, &kCFTypeArrayCallBacks); CFArrayAppendValue(a, leaf);
    const struct { const uint8_t *p; size_t n; } k[] = {{SS_WWDR_G3, sizeof SS_WWDR_G3}, {SS_APPLE_ROOT, sizeof SS_APPLE_ROOT}};
    for (size_t i = 0; i < 2; i++) {
        CFDataRef d = CFDataCreate(NULL, k[i].p, (CFIndex)k[i].n); SecCertificateRef c = d ? SecCertificateCreateWithData(NULL, d) : NULL;
        if (d) CFRelease(d);
        if (c) { CFArrayAppendValue(a, c); CFRelease(c); }
    }
    return a;
}
// 钥匙串里证书 sha1 为 sha 的那个签名身份（电脑交来的、手机上导入的都在，按证书各存一份）。0 = 取到（调用方 CFRelease 两样）；-1 = 没有
int s2a_identity_keychain(const char *sha, SecKeyRef *key, SecCertificateRef *cert) {
    if (!sha || !*sha) return -1;
    const void *k[] = {kSecClass, kSecReturnRef, kSecMatchLimit}, *v[] = {kSecClassIdentity, kCFBooleanTrue, kSecMatchLimitAll};
    CFDictionaryRef q = CFDictionaryCreate(NULL, k, v, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFTypeRef got = NULL; OSStatus st = SecItemCopyMatching(q, &got); CFRelease(q);
    int r = -1;
    for (CFIndex i = 0; r && st == errSecSuccess && got && CFGetTypeID(got) == CFArrayGetTypeID() && i < CFArrayGetCount(got); i++) {
        SecIdentityRef id = (SecIdentityRef)CFArrayGetValueAtIndex(got, i); SecCertificateRef c = NULL;
        if (SecIdentityCopyCertificate(id, &c) || !c) continue;
        CFDataRef d = SecCertificateCopyData(c); char hs[41] = ""; uint8_t h[CC_SHA1_DIGEST_LENGTH];
        if (d) { CC_SHA1(CFDataGetBytePtr(d), (CC_LONG)CFDataGetLength(d), h); CFRelease(d); for (int j = 0; j < CC_SHA1_DIGEST_LENGTH; j++) snprintf(hs + 2 * j, 3, "%02x", h[j]); }
        if (hs[0] && !strcasecmp(hs, sha) && !SecIdentityCopyPrivateKey(id, key)) { *cert = c; r = 0; } else CFRelease(c);
    }
    if (got) CFRelease(got); return r;
}

// 弱链接[host,nvntest]：s2a_prov_app_json_self（ios/prov_expiry.m，同下一行）
// 弱链接[host,nvntest]：s2a_prov_signing_ids_self（ios/prov_expiry.m 只在 iOS App 里；Mac 宿主与单测链接行按这行放行未定义）
int s2a_prov_signing_ids_self(char *team, size_t team_n, char *appid, size_t appid_n) __attribute__((weak_import));   // ios/prov_expiry.m（只在 iOS App 里）
int s2a_prov_app_json_self(const char *home) __attribute__((weak_import));   // ios/prov_expiry.m（只在 iOS App 里）
void s2a_selfsign_probe(void) {
    if (s2a_prov_app_json_self && s2a_prov_app_json_self(getenv("HOME"))) LOG("【黄】本 App 的签名身份写不进 identity/app.json（电脑推送前核团队用）");
    s2a_identity_import(getenv("HOME"));   // 电脑交来的签名身份（有才做；没有立即返回）
    const char *p12 = getenv("S2A_SELFSIGN_P12"), *in = getenv("S2A_SELFSIGN_IN"), *out = getenv("S2A_SELFSIGN_OUT");
    if (!p12 || !in || !out) return;
    char pp[1024], pi[1024], po[1024], why[256] = {0};
    if (home_path(pp, sizeof pp, p12) || home_path(pi, sizeof pi, in) || home_path(po, sizeof po, out)) { LOG("【红】手机端自签：路径展不开"); return; }
    struct timespec t0, t1, t2; clock_gettime(CLOCK_MONOTONIC, &t0);
    size_t pn = 0, n = 0; uint8_t *pb = slurp(pp, &pn), *ib = slurp(pi, &n);
    if (!pb || !ib) { LOG("【红】手机端自签：读不到 %s", !pb ? pp : pi); free(pb); free(ib); return; }
    SecKeyRef key = NULL; CFArrayRef chain = NULL;
    int rc = s2a_selfsign_identity(pb, pn, getenv("S2A_SELFSIGN_PW"), &key, &chain); free(pb);
    if (rc) { LOG("【红】手机端自签：p12 导入失败（%d）", rc); free(ib); return; }
    // iOS 的 SecPKCS12Import 只给 p12 里的证书（玩家导出的 p12 通常只有叶证书），macOS 会从系统补齐链。
    //   签名里缺 WWDR 中间证书，内核注册签名就验不过链（真机 errno=1）。S2A_SELFSIGN_CHAIN = 冒号分隔的 DER 证书（中间证书、根证书），叶证书之后接上。
    //   做成产品时这几张苹果公开证书随 App 带，按叶证书的签发者挑 WWDR 那一代
    const char *ce = getenv("S2A_SELFSIGN_CHAIN");
    if (ce && *ce && CFArrayGetCount(chain) == 1) {
        CFMutableArrayRef full = CFArrayCreateMutableCopy(NULL, 0, chain); char list[4096]; snprintf(list, sizeof list, "%s", ce);
        for (char *sv = NULL, *tok = strtok_r(list, ":", &sv); tok; tok = strtok_r(NULL, ":", &sv)) {
            char cp[1024]; size_t cn = 0; uint8_t *cb = home_path(cp, sizeof cp, tok) ? NULL : slurp(cp, &cn);
            CFDataRef cd = cb ? CFDataCreate(NULL, cb, (CFIndex)cn) : NULL; free(cb);
            SecCertificateRef c = cd ? SecCertificateCreateWithData(NULL, cd) : NULL; if (cd) CFRelease(cd);
            if (c) { CFArrayAppendValue(full, c); CFRelease(c); } else LOG("【黄】手机端自签：链证书读不了 %s", tok);
        }
        CFRelease(chain); chain = full;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    uint8_t *ob = NULL; size_t on = 0;
    // 团队号 / appid：开发用环境变量优先；没给就读包里的描述文件（ios/prov_expiry.m，产品路径；Mac 宿主与单测没有它，弱引用取不到就按没给）
    const char *team = getenv("S2A_SELFSIGN_TEAM"), *appid = getenv("S2A_SELFSIGN_APPID"); char pt[64], pa[512];
    if (!(team && *team) && s2a_prov_signing_ids_self) {
        int pr = s2a_prov_signing_ids_self(pt, sizeof pt, pa, sizeof pa);
        if (pr >= 0) { team = pt; appid = pa; LOG("手机端自签：团队号 %s、appid %s 取自包里的描述文件", pt, pa); }
        if (pr == 1) LOG("【黄】手机端自签：描述文件的 application-identifier 和本包包名拼出的 %s 不同，照常用本包包名（系统可能拒，见上一行）", pa);
        if (pr < 0) LOG("【黄】手机端自签：包里读不到描述文件的团队号（TrollStore / ad-hoc 包没有），照常不带团队号与权限签");
    }
    rc = s2a_selfsign_macho(ib, n, NULL, team, appid, key, chain, &ob, &on, why, sizeof why);
    clock_gettime(CLOCK_MONOTONIC, &t2);
    long nchain = (long)CFArrayGetCount(chain); free(ib); CFRelease(key); CFRelease(chain);
    if (rc) { LOG("【红】手机端自签：签名失败：%s", why); return; }
    for (char *q = po + 1; *q; q++) if (*q == '/') { *q = 0; mkdir(po, 0755); *q = '/'; }   // 上级目录可能还没建（program/）
    char tmp[1100]; snprintf(tmp, sizeof tmp, "%s.tmp", po);
    FILE *f = fopen(tmp, "wb"); int ok = f && fwrite(ob, 1, on, f) == on; if (f && fclose(f)) ok = 0; free(ob);
    if (!ok || rename(tmp, po)) { LOG("【红】手机端自签：写不进 %s", po); return; }
    LOG("手机端自签：在本机用 p12（证书链 %ld 张）重签 %s → %s，%zu → %zu 字节；导入证书 %.0f ms、签名 %.0f ms",
        nchain, pi, po, n, on, (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6, (t2.tv_sec - t1.tv_sec) * 1e3 + (t2.tv_nsec - t1.tv_nsec) / 1e6);
}
