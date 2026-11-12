// 导出诊断包（用户体验线 10-23，明天内测用；包格式由测试出包线定，schema 1）：
//   入口：① 系统「设置 → 本 App」里的开关「打开 App 时导出诊断包」（App 打开 / 回前台时看到开着就导出，并把开关关回去）；
//         ② 游戏画面上四指长按 1.5 秒 → 菜单「导出诊断包」；③ 没进游戏的提示页（缺资源 / 导入失败）上的按钮；
//         ④ 上次会话在前台没正常收尾（崩溃 / 卡死被杀 / 内存超限被杀）或 MetricKit 报了崩溃 / 卡顿 → 这次启动问一句「把上次的诊断发给我们？」。
//   包：S2Arm-诊断-<月日>-<时分>.zip（英文界面 S2Arm-diag-…；同一分钟再导出加 -2），压缩后 ≤ 30 MB：
//       manifest.json、logs/host.log + logs/host-<起局时刻>.log（本局 + 机上归档的最近 9 局；单份超 8 MB 只留头 2 MB + 尾 6 MB）、
//       logs/frames.tsv、logs/threads.txt、logs/unpack.log（有就放）、metrickit/*.json（MetricKit 崩溃 / 卡顿诊断原样 JSON）、
//       shaders/*（现编着色器的输入：编到一半进程没了留下的 .inflight.*、翻译器报错留下的 .fail.*，有就放）、
//       diagrun/*.png（诊断局的出图与颜色目标，总量 ≤ 20 MB）。
//   脱敏：App 数据目录 / 安装目录换成 <APP> / <BUNDLE>，设备名、UDID 去掉；存档（bis/user/save）、资源包、密钥都不放。
//   交出：系统分享面板（AirDrop / 存到文件 / 微信）；包同时留在 Documents/diag/（只留最近 3 个，Mac 前端「拉回诊断」能拉到）。
#import <UIKit/UIKit.h>
#import "s2a_l10n.h"
#import <MetricKit/MetricKit.h>
#import <Metal/Metal.h>
#import "vpad.h"
#import "app_settings.h"
#include <sys/sysctl.h>
#include "native.h"
#include "diagredact.h"
#include "s2a_unattended.h"
#include "s2a_pad.h"   // s2a_pad_plus_press：手柄长按「+」开菜单
#include "s2a_launch_ctx.h"
#include "s2a_sesdiag.h"

static NSString *docs(void) { return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject; }
// 资源包根：启动上下文给了本款资源包就读它（上下文文件 / 多款容器选了游戏：v0.3.0 起在 Library 下，s2a_docs.h s2a_pack_root）；
//   单款兼容照旧 Documents/资源包（不随 S2A_GAME_DATA，同改造前）
//   多款容器还没选游戏（游戏库里导出：多半是上一局崩了 App 重开）：按上次在库里选的款（app.m library_play 记的 S2ALastGameId）解析本款资源包，
//   诊断包对得上那一局的游戏（#795：原先落到不存在的 Documents/资源包，程序号 / 主程序构建号 / 包指纹全空）
static NSString *last_container_game_root(void) {
    if (!s2a_launch_ctx_container()) return nil;
    NSString *gid = [NSUserDefaults.standardUserDefaults stringForKey:@"S2ALastGameId"]; if (!gid.length) return nil;
    const char *home = getenv("HOME"); s2a_launch_ctx c; char why[256];
    if (s2a_launch_ctx_resolve_game(&c, s2a_launch_ctx_bundle_dir(), home && *home ? home : ".", gid.UTF8String, why, sizeof why)) { LOG("诊断包：上次的游戏 %s 解析不了（%s），游戏信息留空", gid.UTF8String, why); return nil; }
    return @(c.game_data);
}
static NSString *pack_root(void) {
    const s2a_launch_ctx *lc = s2a_launch_ctx_get();
    if (lc && (lc->source == S2A_LCTX_FILE || lc->source == S2A_LCTX_CONTAINER)) return @(lc->game_data);
    return last_container_game_root() ?: [docs() stringByAppendingPathComponent:@"资源包"];
}
// 归档的往局日志（os.c 每局一份）：Documents 下相对路径 logs/host-<起局时刻>.log，新的在前（文件名带时刻，按名排序即按时间）
static NSArray<NSString *> *archived_logs(void) {
    NSArray *a = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:[docs() stringByAppendingPathComponent:@"logs"] error:nil]
                  filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'host-' AND SELF ENDSWITH '.log'"]];
    NSMutableArray *r = [NSMutableArray array];
    for (NSString *n in [[a sortedArrayUsingSelector:@selector(compare:)] reverseObjectEnumerator]) [r addObject:[@"logs" stringByAppendingPathComponent:n]];
    return r;
}
static NSString *const kOpenToggle = @"S2ADiagExportOnOpen";   // Settings.bundle 里的开关
static UIViewController *g_vc;
static BOOL g_prompted, g_exporting;
static __weak UIAlertController *g_promptAlert;   // 「把上次的诊断发给我们？」正显示着时指向它：导出要先把它关掉再弹分享面板，不叠在一起

// ---------- 单次会话日志的摘要（manifest.sessions 一项；只在导出诊断包的后台线程算）----------
// 11-07 起只读头 1 MB + 尾 3 MB、按字节找（runtime/src/sesdiag.c s2a_log_summary）：原先整份读成 NSString 逐行折叠查找，挂死后刷满红行的上一局日志在主线程上卡几秒（测试设备2 看门狗复位）
static NSDictionary *session_summary(NSString *path, NSString *name, BOOL current) {
    NSDictionary *at = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil]; if (!at) return nil;
    s2a_log_sum m; if (s2a_log_summary(path.fileSystemRepresentation, S2A_SUM_HEAD, S2A_SUM_TAIL, &m)) return nil;
    // 收尾判法（测试出包线 schema 1）：「优雅退出完成」= exit；有 CRASH 行 = crash；本次正在跑 = running；都没有 = unknown（入库脚本再按 MetricKit 细分 killed / hang）
    NSString *end = current ? @"running" : m.end == S2A_SUM_END_EXIT ? @"exit" : m.end == S2A_SUM_END_CRASH ? @"crash" : @"unknown";
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new]; iso.timeZone = NSTimeZone.localTimeZone;
    NSMutableDictionary *d = [@{@"log": [@"logs/" stringByAppendingString:name], @"end": end, @"mark": @(m.mark != 0),
                                @"started": at[NSFileCreationDate] ? [iso stringFromDate:at[NSFileCreationDate]] : NSNull.null} mutableCopy];
    d[@"frames"] = m.frames >= 0 ? @(m.frames) : NSNull.null; d[@"thermal_max"] = m.thermal >= 0 ? @(m.thermal) : NSNull.null; d[@"footprint_peak_mb"] = m.peak_mb >= 0 ? @(m.peak_mb) : NSNull.null;
    if (m.truncated) d[@"summary_scope"] = @"head+tail";   // 超过 4 MB 的日志只摘头尾（中间的心跳 / 热状态不计）
    return d;
}

// ---------- 脱敏：App 数据目录 / 安装目录、设备名、UDID ----------
static NSString *redact(NSString *s) {
    NSMutableString *m = [s mutableCopy];
    NSString *dev = UIDevice.currentDevice.name;
    if (dev.length > 0 && ![dev isEqualToString:UIDevice.currentDevice.model])
        [m replaceOccurrencesOfString:dev withString:@"<设备名>" options:0 range:NSMakeRange(0, m.length)];
    char *clean = s2a_diag_redact(m.UTF8String);
    if (!clean) { LOG("【红】诊断脱敏失败，拒绝写出原文"); return nil; }
    NSString *result = [[NSString alloc] initWithUTF8String:clean]; free(clean);
    return result;
}

// 文本文件：超过 cap 只留头 cap/4 + 尾 cap*3/4（按行边界），中间一行「…截掉 N 字节…」；脱敏后写到 dst。返回 {bytes, truncated}
static NSDictionary *copy_text(NSString *src, NSString *dst, NSUInteger cap) {
    NSData *d = [NSData dataWithContentsOfFile:src options:NSDataReadingMappedIfSafe error:nil]; if (!d) return nil;
    BOOL cut = d.length > cap; NSData *out = d;
    if (cut) {
        NSUInteger head = cap / 4, tail = cap - head;
        NSRange nl = [d rangeOfData:[NSData dataWithBytes:"\n" length:1] options:NSDataSearchBackwards range:NSMakeRange(0, head)]; if (nl.location != NSNotFound) head = nl.location + 1;
        NSUInteger ts = d.length - tail; NSRange nl2 = [d rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(ts, d.length - ts)]; if (nl2.location != NSNotFound) ts = nl2.location + 1;
        NSMutableData *m = [[d subdataWithRange:NSMakeRange(0, head)] mutableCopy];
        [m appendData:[[NSString stringWithFormat:@"\n…截掉 %lu 字节…\n", (unsigned long)(ts - head)] dataUsingEncoding:NSUTF8StringEncoding]];
        [m appendData:[d subdataWithRange:NSMakeRange(ts, d.length - ts)]]; out = m;
    }
    NSString *s = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:out encoding:NSISOLatin1StringEncoding];
    NSData *w = [redact(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (!w || ![w writeToFile:dst atomically:NO]) return nil;
    return @{@"bytes": @(w.length), @"truncated": @(cut)};
}

// ---------- 设备与游戏信息 ----------
static NSString *hw_model(void) { char b[64] = {0}; size_t n = sizeof b; sysctlbyname("hw.machine", b, &n, NULL, 0); return @(b); }
static NSString *gpu_family(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    for (int f = 10; f >= 1; f--) if ([dev supportsFamily:(MTLGPUFamily)(MTLGPUFamilyApple1 + f - 1)]) return [NSString stringWithFormat:@"apple%d", f];
    return @"";
}
// 程序号：资源包 exefs/main.npdm 的 ACI0 段（npdm 0x70 处 u32 = ACI0 偏移，ACI0 +0x10 处 u64 = 程序号）
static NSString *title_id(void) {
    NSData *d = [NSData dataWithContentsOfFile:[pack_root() stringByAppendingPathComponent:@"exefs/main.npdm"]]; if (d.length < 0x80) return @"";
    const uint8_t *p = d.bytes; uint32_t aci = *(const uint32_t *)(p + 0x70);
    if (aci + 0x18 > d.length || memcmp(p + aci, "ACI0", 4)) return @"";
    return [NSString stringWithFormat:@"%016llX", *(const unsigned long long *)(p + aci + 0x10)];
}
// 主程序构建号：起局后取装载器读到的（loader.c）；还没起局（启动即导出 / 上次崩了这次刚开）就从资源包 exefs/main 的 NSO 头 0x40 起 16 字节读
static NSString *main_build_id(void) {
    const char *b = s2a_main_build_id(); if (b && *b) return @(b);
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:[pack_root() stringByAppendingPathComponent:@"exefs/main"]]; if (!h) return @"";
    [h seekToFileOffset:0x40]; NSData *d = [h readDataOfLength:16]; [h closeFile];
    if (d.length < 16) return @"";
    NSMutableString *s = [NSMutableString string]; const uint8_t *p = d.bytes; for (int i = 0; i < 16; i++) [s appendFormat:@"%02X", p[i]];
    return s;
}
static NSString *pack_fp(void) {
    NSData *d = [NSData dataWithContentsOfFile:[pack_root() stringByAppendingPathComponent:@"manifest.json"]]; if (!d) return @"";
    NSString *h = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil][@"index_sha256"];
    return [h isKindOfClass:NSString.class] ? [h substringToIndex:MIN(16u, h.length)] : @"";
}
// 着色器归档目标：单款包 Info.plist 有（ipa_tail.py 写）；多款容器的壳里没有按款的值，按本款资源包 shaders/gal_pso.<架构>.<系统>.<片>.bin 算（同 ipa_tail.py pso_target）
static NSString *pso_target(void) {
    NSString *t = [NSBundle.mainBundle objectForInfoDictionaryKey:@"S2APsoTarget"]; if (t.length) return t;
    NSMutableSet *ts = [NSMutableSet set];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:[pack_root() stringByAppendingPathComponent:@"shaders"] error:nil] ?: @[]) {
        if (![f hasPrefix:@"gal_pso."] || ![f hasSuffix:@".bin"]) continue;
        NSString *m = [f substringWithRange:NSMakeRange(8, f.length - 8 - 4)]; NSRange dot = [m rangeOfString:@"." options:NSBackwardsSearch];
        [ts addObject:dot.location == NSNotFound ? m : [m substringToIndex:dot.location]];
    }
    return [[ts.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
}
static NSString *game_name(void) {   // 款名：包名 io.s2arm.<款> 的最后一段；别的包名用显示名
    NSString *b = NSBundle.mainBundle.bundleIdentifier ?: @"";
    if ([b hasPrefix:@"io.s2arm."]) return [b substringFromIndex:@"io.s2arm.".length];
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"s2arm";
}
// 进文件名的款名：空白和路径 / 命令行不友好的字符换成下划线（显示名「空洞骑士 丝之歌」→「空洞骑士_丝之歌」；manifest 里仍写原名）
static NSString *file_safe(NSString *s) {
    NSMutableString *o = [NSMutableString string];
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *c, NSRange r, NSRange er, BOOL *stop) {
        (void)r; (void)er; (void)stop;
        BOOL bad = [c rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound
                || [c rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|'`$&;()"]].location != NSNotFound;
        if (!bad) [o appendString:c]; else if (![o hasSuffix:@"_"]) [o appendString:@"_"];
    }];
    return o.length ? o : @"s2arm";
}

#include "diagzip.h"   // write_zip：诊断包 zip（只用 Foundation + zlib，Mac 上有单测 tests/diagzip_test.sh）
static NSString *tester_id(void) {   // 随机短号：同一台机器每次一样，不含任何个人信息
    NSString *t = [NSUserDefaults.standardUserDefaults stringForKey:@"S2ATesterId"];
    if (!t.length) { t = [[NSUUID UUID].UUIDString substringToIndex:6]; [NSUserDefaults.standardUserDefaults setObject:t forKey:@"S2ATesterId"]; }
    return t;
}

// 宿主自身的构建提交号（runtime/build.mk 写进 Info.plist 的 S2ACommit）：直连安全网的包身份之一（dguard.c）。取不到 = ""
const char *s2a_ios_host_commit(void) {
    static char c[48]; static dispatch_once_t once;
    dispatch_once(&once, ^{ NSString *s = [NSBundle.mainBundle objectForInfoDictionaryKey:@"S2ACommit"];
        snprintf(c, sizeof c, "%s", [s isKindOfClass:NSString.class] && ![s containsString:@" "] ? s.UTF8String : ""); });
    return c;
}

// ---------- 打包 ----------
// cap：每份日志上限（字节）；slim：去掉 frames.tsv / threads.txt / 最早那次会话（超 30 MB 时退一档）
static NSURL *build_zip(NSUInteger cap, BOOL slim, NSString **err) {
    NSFileManager *fm = NSFileManager.defaultManager; NSString *D = docs();
    NSString *commit = [NSBundle.mainBundle objectForInfoDictionaryKey:@"S2ACommit"] ?: @"";
    // 文件名只写「S2Arm-诊断-月日-时分」（英文界面 S2Arm-diag-…）：机型、系统、提交号、包名、游戏都在包里的 manifest.json，
    //   不往文件名里塞（11-11 维护者：长名不专业）；同一分钟再导出加 -2、-3
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"MMdd-HHmm"; df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSString *outDir = [D stringByAppendingPathComponent:@"diag"]; [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *base = [NSString stringWithFormat:@"S2Arm-%@-%@", S2AL(@"diag.fileWord"), [df stringFromDate:NSDate.date]], *name = base;
    for (int k = 2; [fm fileExistsAtPath:[[outDir stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"zip"]]; k++) name = [NSString stringWithFormat:@"%@-%d", base, k];
    NSString *W = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    [fm removeItemAtPath:W error:nil];
    [fm createDirectoryAtPath:[W stringByAppendingPathComponent:@"logs"] withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray *files = [NSMutableArray array], *sessions = [NSMutableArray array];
    __block BOOL copyFailed = NO;
    void (^add)(NSString *, NSString *, NSUInteger) = ^(NSString *src, NSString *rel, NSUInteger c) {
        NSDictionary *r = copy_text(src, [W stringByAppendingPathComponent:rel], c);
        if (!r) copyFailed = YES;
        if (r) [files addObject:@{@"path": rel, @"bytes": r[@"bytes"], @"truncated": r[@"truncated"]}];
    };
    // 本局 host.log + 归档（os.c 每局一份，Documents/logs/host-<起局时刻>.log，新的在前）：精简包带上一局，完整包带全部（最多 9 份）
    NSArray *arch = archived_logs(); NSMutableArray *logs = [NSMutableArray arrayWithObject:@"host.log"];
    [logs addObjectsFromArray:slim ? [arch subarrayWithRange:NSMakeRange(0, MIN(arch.count, (NSUInteger)1))] : arch];
    for (NSString *l in logs) {
        NSString *src = [D stringByAppendingPathComponent:l]; if (![fm fileExistsAtPath:src]) continue;
        NSMutableDictionary *s = [session_summary(src, l.lastPathComponent, [l isEqualToString:@"host.log"]) mutableCopy];
        if (s) [sessions addObject:s];
        add(src, [@"logs/" stringByAppendingString:l.lastPathComponent], cap);
    }
    NSArray *extra = slim ? @[@"unpack.log"] : @[@"frames.tsv", @"threads.txt", @"unpack.log", @"far_sites.tsv"];   // far_sites.tsv：远端缺页点表（far.c，地址根修的读数）
    for (NSString *f in extra) { NSString *src = [D stringByAppendingPathComponent:f]; if ([fm fileExistsAtPath:src]) add(src, [@"logs/" stringByAppendingString:f], cap); }
    int crash = 0, hang = 0, exits = 0;
    NSString *mk = [D stringByAppendingPathComponent:@"metrickit"];
    for (NSString *f in [[fm contentsOfDirectoryAtPath:mk error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![f hasSuffix:@".json"]) continue;
        [fm createDirectoryAtPath:[W stringByAppendingPathComponent:@"metrickit"] withIntermediateDirectories:YES attributes:nil error:nil];
        add([mk stringByAppendingPathComponent:f], [@"metrickit/" stringByAppendingString:f], 4u << 20);
        if ([f containsString:@"crash"]) crash++; if ([f containsString:@"hang"]) hang++; if ([f hasSuffix:@"-exit.json"]) exits++;
    }
    // 现编着色器的输入（graphics/nvn/host/dsh_miss.inc）：<键>.inflight.*（编到一半进程没了才剩下，#467）与 <键>.fail.*（翻译器报错，#442）。
    //   只有着色器字节、不含个人信息，原样带走（不过脱敏，二进制也过不了）；每份至多 1 MB、整包至多 16 份，放 shaders/<程序号>_<原名>
    {   NSString *G = [D stringByAppendingPathComponent:@"games"]; int ns = 0;
        for (NSString *gid in [fm contentsOfDirectoryAtPath:G error:nil]) {
            NSString *sd = [[[[G stringByAppendingPathComponent:gid] stringByAppendingPathComponent:@"wire"] stringByAppendingPathComponent:gid] stringByAppendingPathComponent:@"shaders"];
            for (NSString *f in [[fm contentsOfDirectoryAtPath:sd error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
                if (ns >= 16) break;
                if (![f hasSuffix:@".inflight.ctl"] && ![f hasSuffix:@".inflight.code"] && ![f hasSuffix:@".fail.ctl"] && ![f hasSuffix:@".fail.code"]) continue;
                NSData *d = [NSData dataWithContentsOfFile:[sd stringByAppendingPathComponent:f]]; if (!d || d.length > (1u << 20)) continue;
                NSString *rel = [NSString stringWithFormat:@"shaders/%@_%@", file_safe(gid), f];
                [fm createDirectoryAtPath:[W stringByAppendingPathComponent:@"shaders"] withIntermediateDirectories:YES attributes:nil error:nil];
                if ([d writeToFile:[W stringByAppendingPathComponent:rel] atomically:NO]) { [files addObject:@{@"path": rel, @"bytes": @(d.length), @"truncated": @NO}]; ns++; }
            } } }
    // 诊断局（#438，settings.m s2a_ios_apply_diag_run）的读数：单款包 Documents/diagrun/、多款容器各款 games/<游戏号>/diagrun/ 里的 PNG
    //   （出图画面与颜色目标，渲染出来的图、不含游戏数据和个人信息，原样带走）。单张超过 4 MB 跳过、总量至多 20 MB（整包 ≤ 30 MB，给日志留地方），放 diagrun/<游戏号>_<原名>
    {   NSMutableArray *dirs = [NSMutableArray arrayWithObject:@[@"app", [D stringByAppendingPathComponent:@"diagrun"]]];
        NSString *G = [D stringByAppendingPathComponent:@"games"];
        for (NSString *gid in [[fm contentsOfDirectoryAtPath:G error:nil] sortedArrayUsingSelector:@selector(compare:)])
            [dirs addObject:@[gid, [[G stringByAppendingPathComponent:gid] stringByAppendingPathComponent:@"diagrun"]]];
        unsigned long long used = 0;
        for (NSArray *e in dirs) for (NSString *f in [[fm contentsOfDirectoryAtPath:e[1] error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
            if (![f.lowercaseString hasSuffix:@".png"]) continue;
            NSString *src = [e[1] stringByAppendingPathComponent:f];
            unsigned long long n = [[fm attributesOfItemAtPath:src error:nil] fileSize];
            if (!n || n > (4ull << 20) || used + n > (20ull << 20)) continue;
            NSString *rel = [NSString stringWithFormat:@"diagrun/%@_%@", file_safe(e[0]), f];
            [fm createDirectoryAtPath:[W stringByAppendingPathComponent:@"diagrun"] withIntermediateDirectories:YES attributes:nil error:nil];
            if ([fm copyItemAtPath:src toPath:[W stringByAppendingPathComponent:rel] error:nil]) { [files addObject:@{@"path": rel, @"bytes": @(n), @"truncated": @NO}]; used += n; }
        } }
    if (copyFailed) {
        [fm removeItemAtPath:W error:nil];
        if (err) *err = S2AL(@"diag.error.redact");
        return nil;
    }
    NSString *bundle = redact(NSBundle.mainBundle.bundleIdentifier ?: @"");
    if (!bundle) {
        [fm removeItemAtPath:W error:nil];
        if (err) *err = S2AL(@"diag.error.bundleName");
        return nil;
    }
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new]; iso.timeZone = NSTimeZone.localTimeZone;
    NSDictionary *manifest = @{
        @"schema": @1, @"exported_at": [iso stringFromDate:NSDate.date],
        @"tester": @{@"id": tester_id(), @"group": @"", @"note": @""},
        @"app": @{@"bundle": bundle, @"version": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"", @"commit": commit,
                  // 包号：单款包 S2ABuildID；多款容器的壳没有按款包号，记壳号 S2AShellId（同 s2a_catalogue.json shell_id）
                  @"build_id": [NSBundle.mainBundle objectForInfoDictionaryKey:@"S2ABuildID"] ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"S2AShellId"] ?: @"",
                  // 界面版本字（设置页 / 游戏库顶部显示的 v0.3.0 / v0.2.6-dev+ba0ef07，电脑组装时写 Info.plist 的 S2ADisplayVersion）：玩家截图与诊断包对得上
                  @"display_version": [NSBundle.mainBundle objectForInfoDictionaryKey:@"S2ADisplayVersion"] ?: @"",
                  // 包里着色器归档的目标「架构.系统」（ipa.sh 写 Info.plist 的 S2APsoTarget，如 applegpu_g18p.ios27，多份逗号连）：和 device.gpu_family / ios 对照，一眼看出整份不命中
                  @"pso_target": pso_target()},
        @"game": @{@"name": game_name(), @"title_id": title_id(), @"build_id": main_build_id(), @"pack_fp": pack_fp()},
        @"device": @{@"model": hw_model(), @"ios": UIDevice.currentDevice.systemVersion, @"ram_mb": @(NSProcessInfo.processInfo.physicalMemory >> 20),
                     @"gpu_family": gpu_family(), @"low_power": @(NSProcessInfo.processInfo.lowPowerModeEnabled)},
        @"settings": @{@"language": NSLocale.preferredLanguages.firstObject ?: @""},
        @"sessions": sessions, @"metrickit": @{@"crash": @(crash), @"hang": @(hang), @"exit": @(exits)}, @"files": files };
    [[NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil]
        writeToFile:[W stringByAppendingPathComponent:@"manifest.json"] atomically:NO];
    // 自己写 zip（write_zip）：manifest.json、logs/ 在根上（schema 1），文件名带 UTF-8 标记
    NSString *destPath = [[outDir stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"zip"];
    NSURL *zip = write_zip(W, destPath) ? [NSURL fileURLWithPath:destPath] : nil;
    [fm removeItemAtPath:W error:nil];
    if (!zip && err) *err = S2AL(@"diag.error.zip");
    // Documents/diag 只留最近 3 个：按修改时间排（短名按字面排不准：同一分钟的 -2 排在前面、换了界面语言前缀不同、跨年 01 排在 12 前面）
    NSArray *old = [[[fm contentsOfDirectoryAtPath:outDir error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF ENDSWITH '.zip'"]] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *ta = [fm attributesOfItemAtPath:[outDir stringByAppendingPathComponent:a] error:nil].fileModificationDate ?: NSDate.distantPast;
        NSDate *tb = [fm attributesOfItemAtPath:[outDir stringByAppendingPathComponent:b] error:nil].fileModificationDate ?: NSDate.distantPast;
        return [ta compare:tb]; }];
    for (NSUInteger i = 0; old.count > 3 && i < old.count - 3; i++) [fm removeItemAtPath:[outDir stringByAppendingPathComponent:old[i]] error:nil];
    return zip;
}

// 导出并弹系统分享面板（主线程调）。打包在后台线程做，不卡画面
BOOL s2a_diag_is_exporting(void) { return g_exporting; }
// 弹分享面板的地方：游戏里用游戏界面（g_vc）；多款容器还停在游戏库时 g_vc 为空——原先直接返回，快捷菜单「导出诊断包」
//   在库里点了什么也不发生（11-11 宿主梳理）。这时取前台窗口的根控制器（游戏库）
static UIViewController *diag_host(void) {
    if (g_vc) return g_vc;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState == UISceneActivationStateBackground) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow && w.rootViewController) return w.rootViewController;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.rootViewController) return w.rootViewController;
    }
    return nil;
}
void s2a_diag_export(void) {
    UIViewController *host = diag_host();
    if (g_exporting || !host) return; g_exporting = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:@"S2ADiagExportChanged" object:nil];
    LOG("诊断包：开始导出");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil; NSURL *zip = nil; unsigned long long sz = 0;
        // ≤ 30 MB：先按每份 8 MB；超了退到 4 MB + 精简，再超退到 1 MB
        struct { NSUInteger cap; BOOL slim; } tiers[] = {{8u << 20, NO}, {4u << 20, YES}, {1u << 20, YES}};
        for (int i = 0; i < 3; i++) {
            zip = build_zip(tiers[i].cap, tiers[i].slim, &err); if (!zip) break;
            sz = [[NSFileManager.defaultManager attributesOfItemAtPath:zip.path error:nil] fileSize];
            if (sz <= (30ull << 20)) break;
        }
        LOG("诊断包：%s %s（%.1f MB）", zip ? "已生成" : "失败", zip ? zip.lastPathComponent.UTF8String : (err ?: @"").UTF8String, sz / 1048576.0);
        dispatch_async(dispatch_get_main_queue(), ^{
            g_exporting = NO;
            [NSNotificationCenter.defaultCenter postNotificationName:@"S2ADiagExportChanged" object:nil];
            UIViewController *presenter = host;
            while (presenter.presentedViewController) presenter = presenter.presentedViewController;
            if ([presenter isKindOfClass:UINavigationController.class]) presenter = ((UINavigationController *)presenter).topViewController;
            if (!zip) { UIAlertController *a = [UIAlertController alertControllerWithTitle:S2AL(@"diag.error.title") message:err preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:S2AL(@"common.gotIt") style:UIAlertActionStyleCancel handler:nil]]; [presenter presentViewController:a animated:YES completion:nil]; return; }
            UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[zip] applicationActivities:nil];
            av.popoverPresentationController.sourceView = host.view;   // iPad 要锚点
            av.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(host.view.bounds), CGRectGetMidY(host.view.bounds), 1, 1);
            void (^show)(void) = ^{ UIViewController *top = host; while (top.presentedViewController) top = top.presentedViewController;
                [top presentViewController:av animated:YES completion:nil]; };
            // 导出就是对「要不要发」的回答：询问弹窗还开着（比如自动导出和异常退出后的询问同时触发）就先关掉它，关完再弹分享面板
            UIAlertController *q = g_promptAlert;
            if (q.presentingViewController) [q dismissViewControllerAnimated:YES completion:show]; else show();
        });
    });
}

// ---------- MetricKit：崩溃 / 卡顿诊断与退出原因计数（系统在下次启动或之后交来）原样存 Documents/metrickit/ ----------
// 每类各留最近 20 份（按文件名后缀分：-exit.json 一类，崩溃 / 卡顿 / 其它诊断一类），退出计数不挤掉崩溃现场
static void mk_trim(NSString *dir, BOOL exits) {
    NSMutableArray *mine = [NSMutableArray array];
    for (NSString *f in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)])
        if ([f hasSuffix:@".json"] && [f hasSuffix:@"-exit.json"] == exits) [mine addObject:f];
    for (NSUInteger i = 0; mine.count > 20 && i < mine.count - 20; i++) [NSFileManager.defaultManager removeItemAtPath:[dir stringByAppendingPathComponent:mine[i]] error:nil];
}
static NSString *mk_dir(void) {
    NSString *dir = [docs() stringByAppendingPathComponent:@"metrickit"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}
@interface S2ADiagMK : NSObject <MXMetricManagerSubscriber>
@end
@implementation S2ADiagMK
- (void)didReceiveDiagnosticPayloads:(NSArray<MXDiagnosticPayload *> *)payloads {
    NSString *dir = mk_dir();
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyyMMdd-HHmmss";
    int bad = 0;
    for (MXDiagnosticPayload *p in payloads) {
        NSString *kind = p.crashDiagnostics.count ? @"crash" : p.hangDiagnostics.count ? @"hang" : @"other";
        // 文件名按载荷自己的起止时刻：启动时补读的历史载荷（pastDiagnosticPayloads）与当时交来的是同一份，覆盖不重复；
        //   只有这次新落下的才算「上次崩了」去问玩家（补读的旧载荷每次启动都会再交一遍，不能每次都问）
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@-%@.json",
            [df stringFromDate:p.timeStampBegin ?: NSDate.date], [df stringFromDate:p.timeStampEnd ?: NSDate.date], kind]];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) bad += (int)(p.crashDiagnostics.count + p.hangDiagnostics.count);
        [p.JSONRepresentation writeToFile:path atomically:YES];
    }
    mk_trim(dir, NO);
    LOG("诊断包：MetricKit 交来 %lu 份诊断（新的崩溃 / 卡顿 %d）", (unsigned long)payloads.count, bad);
    if (bad) dispatch_async(dispatch_get_main_queue(), ^{ void s2a_diag_prompt(NSString *why); s2a_diag_prompt(S2AL(@"diag.prompt.crash")); });
}
// 退出原因计数（系统约每天交一次：前台 / 后台各类退出的累计次数）：被看门狗杀、超内存上限被杀不产生崩溃诊断，只在这里看得见——0 崩率要它
- (void)didReceiveMetricPayloads:(NSArray<MXMetricPayload *> *)payloads {
    NSString *dir = mk_dir();
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyyMMdd-HHmmss";
    for (MXMetricPayload *p in payloads) {
        MXAppExitMetric *x = p.applicationExitMetrics; if (!x) continue;
        [p.JSONRepresentation writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@-exit.json",
            [df stringFromDate:p.timeStampBegin ?: NSDate.date], [df stringFromDate:p.timeStampEnd ?: NSDate.date]]] atomically:YES];
        MXForegroundExitData *f = x.foregroundExitData; MXBackgroundExitData *b = x.backgroundExitData;
        NSUInteger fbad = f.cumulativeAbnormalExitCount + f.cumulativeMemoryResourceLimitExitCount + f.cumulativeBadAccessExitCount + f.cumulativeIllegalInstructionExitCount + f.cumulativeAppWatchdogExitCount;
        LOG("%s诊断包：MetricKit 退出计数（%s 起）：前台 正常 %lu / 异常 %lu / 超内存上限 %lu / 坏访问 %lu / 非法指令 %lu / 看门狗 %lu；后台 正常 %lu / 超内存上限 %lu / 内存压力 %lu / 看门狗 %lu / 坏访问 %lu",
            fbad ? "【红】" : "", [df stringFromDate:p.timeStampBegin ?: NSDate.date].UTF8String,
            (unsigned long)f.cumulativeNormalAppExitCount, (unsigned long)f.cumulativeAbnormalExitCount, (unsigned long)f.cumulativeMemoryResourceLimitExitCount,
            (unsigned long)f.cumulativeBadAccessExitCount, (unsigned long)f.cumulativeIllegalInstructionExitCount, (unsigned long)f.cumulativeAppWatchdogExitCount,
            (unsigned long)b.cumulativeNormalAppExitCount, (unsigned long)b.cumulativeMemoryResourceLimitExitCount, (unsigned long)b.cumulativeMemoryPressureExitCount,
            (unsigned long)b.cumulativeAppWatchdogExitCount, (unsigned long)b.cumulativeBadAccessExitCount);
    }
    mk_trim(dir, YES);
}
@end
static S2ADiagMK *g_mk;

// 问一句「把上次的诊断发给我们？」（每次启动最多问一次）
void s2a_diag_prompt(NSString *why) {
    // 已经在导出（或分享面板开着）就不问了：玩家正在发，问了只会和分享面板叠在一起
    if (g_prompted || !g_vc) return; g_prompted = YES;
    // 自动化 / 开发工具起的局（s2a_unattended.h）不问：日志由工具拉回，弹窗只会挡住整局
    if (s2a_unattended()) { LOG("诊断：%s；自动化局不问「把上次的诊断发给我们？」", why.UTF8String); return; }
    if (g_exporting || [g_vc.presentedViewController isKindOfClass:UIActivityViewController.class]) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:S2AL(@"diag.prompt.title")
        message:[NSString stringWithFormat:S2AL(@"diag.prompt.message"), why] preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:S2AL(@"diag.prompt.no") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:S2AL(@"diag.prompt.send") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { (void)x; s2a_diag_export(); }]];
    UIViewController *top = g_vc; while (top.presentedViewController) top = top.presentedViewController;
    g_promptAlert = a; [top presentViewController:a animated:YES completion:nil];
}

// 设置页开关开着 → 导出并把开关关回去
static void check_toggle(void) {
    NSUserDefaults *u = NSUserDefaults.standardUserDefaults;
    static BOOL env_done;   // 真机验证用：devicectl 起局带 S2A_DIAG_EXPORT_NOW=1 → 启动就导出一次（包落 Documents/diag/，执行器拉回核对），不用人点
    if (!env_done) { env_done = YES; const char *e = getenv("S2A_DIAG_EXPORT_NOW"); if (e && *e == '1') { s2a_diag_export(); return; } }
    if (![u boolForKey:kOpenToggle]) return;
    [u setBool:NO forKey:kOpenToggle]; s2a_diag_export();
}

// App 启动时调（didFinishLaunching）：订阅 MetricKit
void s2a_diag_boot(void) {
    g_mk = [S2ADiagMK new]; [MXMetricManager.sharedManager addSubscriber:g_mk];
    // 订阅之前交过、App 没接住的（上次在订阅前就崩了 / 被杀了）：启动时补读一次，文件名按载荷时刻，重复的覆盖
    { NSArray *pd = MXMetricManager.sharedManager.pastDiagnosticPayloads, *pm = MXMetricManager.sharedManager.pastPayloads;
      if (pd.count) [g_mk didReceiveDiagnosticPayloads:pd]; if (pm.count) [g_mk didReceiveMetricPayloads:pm]; }
    // 设置页显示包号（Settings.bundle 的只读项读 UserDefaults 的 S2ABuildID；值来自 Info.plist，ipa.sh 写）
    NSString *bid = [NSBundle.mainBundle objectForInfoDictionaryKey:@"S2ABuildID"];
    [NSUserDefaults.standardUserDefaults setObject:bid.length ? bid : S2AL(@"about.unknown") forKey:@"S2ABuildID"];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n;
        [NSUserDefaults.standardUserDefaults synchronize]; check_toggle(); }];
}

// 窗口建好后调：挂四指长按、看设置开关、判上次会话要不要问
@interface S2ADiagGesture : NSObject
@end
@implementation S2ADiagGesture
+ (void)fire:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    void s2a_diag_open_menu(void); s2a_diag_open_menu();
}
@end
// 快捷菜单唯一入口：四指长按与手柄长按「+」/ Home（ios/controller.m menu_hold_check）都走这里；主线程调
void s2a_diag_open_menu(void) {
    // Reuse this one hidden entry, including on iPad. Never stack a second menu
    // on a layout sheet, file picker, diagnostic prompt or sharing panel.
    if (!g_vc || g_vc.presentedViewController || g_exporting) return;
    s2a_settings_present(g_vc);
}
// 手柄长按「+」：1.5 秒后仍按着同一下（s2a_pad_plus_press 序号没变）才开菜单，同四指长按时长；
//   「+」照常送给游戏（多数游戏是暂停），菜单打开时游戏输入停住
void s2a_diag_menu_hold(uint64_t press) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (s2a_pad_plus_press() == press) s2a_diag_open_menu();
    });
}
void s2a_diag_attach(UIViewController *vc) {
    g_vc = vc;
    // 四指长按 1.5 秒（原生层线 10-23：三指会误触——两拇指压摇杆 + 再按住一个键正好三指；四指玩游戏时不会出现）。
    //   不吃游戏 / 虚拟手柄的触摸：cancelsTouchesInView / delaysTouchesBegan / delaysTouchesEnded 都关（delaysTouchesEnded 缺省 YES，会压住虚拟键「松开」）
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:S2ADiagGesture.class action:@selector(fire:)];
    lp.numberOfTouchesRequired = 4; lp.minimumPressDuration = 1.5; lp.cancelsTouchesInView = NO; lp.delaysTouchesBegan = NO; lp.delaysTouchesEnded = NO;
    [vc.view addGestureRecognizer:lp];
    // 测试开关（真机自动化打不出四指长按 / 手柄长按 +，集中回归 E6）：S2A_OPEN_SETTINGS=<秒> 起局后这么久直接开设置页（同菜单入口，已开着别的界面就不开）。
    //   两处来源：执行器起局时给的环境变量；主屏长按「设置」快捷操作冷启动时 app.m home_shortcut 进程内设的 2 秒
    { const char *e = getenv("S2A_OPEN_SETTINGS"); double sec = e ? atof(e) : 0;
      if (sec > 0) { LOG("设置页：测试开关 S2A_OPEN_SETTINGS=%s，%.0f 秒后直接打开", e, sec);
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ LOG("设置页：测试开关到点，打开"); s2a_diag_open_menu(); }); } }
    // 上次会话是不是死在前台：只读会话标记（runtime/src/sesdiag.c，几字节），不读日志（11-07：主线程整份读上一局日志卡几秒，见 session_summary）。
    //   标记在这里先读后写：读到的是上一局留下的，然后标成本局「前台」；进后台 / 回前台由 app.m 改写，优雅退出（lifecycle.c）删掉
    { uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); int prev = s2a_sesmark_prev(docs().fileSystemRepresentation); s2a_sesmark_set(docs().fileSystemRepresentation, S2A_SESMARK_FG);
      LOG("诊断包：上次会话标记 %s（主线程 %.2f ms，不读日志）→ %s", prev == S2A_SESMARK_FG ? "前台未收尾" : prev == S2A_SESMARK_BG ? "后台" : "无（正常收尾）", (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6, prev == S2A_SESMARK_FG ? "提示导出" : "不提示");
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        check_toggle();
        if (prev == S2A_SESMARK_FG) s2a_diag_prompt(S2AL(@"diag.prompt.abnormalExit"));
      }); }
}
// 进后台 / 回前台（app.m 生命周期通知，主线程）：改写会话标记，在后台被划掉 / 被系统回收不算异常
void s2a_diag_session_fg(int fg) { s2a_sesmark_set(docs().fileSystemRepresentation, fg ? S2A_SESMARK_FG : S2A_SESMARK_BG); }
