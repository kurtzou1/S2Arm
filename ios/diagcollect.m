// 诊断包收成员（ios/diag.m build_zip 用）：把 Documents 下的日志 / 表 / MetricKit / 着色器现场 / 诊断局读数 / 管线记录 / 着色器补料收进工作目录 W，
//   只依赖 Foundation，Mac 上可单测（tests/diag_contract_test.sh：真打一个样样都有的包，逐个成员过诊断收件契约 tools/diag_contract/）。
//   脱敏（要读设备名，UIKit）与会话摘要（runtime/src/sesdiag.c）由调用方以 block 给进来；manifest、包名、写 zip 留在 diag.m。
#import <Foundation/Foundation.h>
#include "diagcollect.h"

// 归档的往局日志（os.c 每局一份）：Documents 下相对路径 logs/host-<起局时刻>.log，新的在前（文件名带时刻，按名排序即按时间）
static NSArray<NSString *> *archived_logs(NSString *D) {
    NSArray *a = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:[D stringByAppendingPathComponent:@"logs"] error:nil]
                  filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'host-' AND SELF ENDSWITH '.log'"]];
    NSMutableArray *r = [NSMutableArray array];
    for (NSString *n in [[a sortedArrayUsingSelector:@selector(compare:)] reverseObjectEnumerator]) [r addObject:[@"logs" stringByAppendingPathComponent:n]];
    return r;
}

// 按 UTF-8 解，坏字节就地换成 U+FFFD（按最长合法前缀算一个），其余逐字节不变。
//   原先整份解不了就整份按 Latin-1 解再存回 UTF-8：一个坏字节就让整份中文变成二次编码的乱码（如「写回原值」→「å\u0086\u0099…」），
//   诊断读不出来；坏字节来自宿主按字节截断的长行（直连层统计行截进定长缓冲、切在汉字中间），往局日志 264 份诊断中招
static NSString *utf8_lossy(NSData *d) {
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]; if (s) return s;
    const uint8_t *p = d.bytes; NSUInteger n = d.length, i = 0; NSMutableData *o = [NSMutableData dataWithCapacity:n + 64];
    static const uint8_t rep[3] = {0xEF, 0xBF, 0xBD};
    while (i < n) {
        uint8_t c = p[i]; NSUInteger len = c < 0x80 ? 1 : (c & 0xE0) == 0xC0 && c >= 0xC2 ? 2 : (c & 0xF0) == 0xE0 ? 3 : (c & 0xF8) == 0xF0 && c <= 0xF4 ? 4 : 0;
        NSUInteger k = 1;
        if (len > 1) {
            uint8_t lo = 0x80, hi = 0xBF;   // 第二字节的合法范围（排除超长编码与代理区，同 Unicode 表 3-7）
            if (c == 0xE0) lo = 0xA0; else if (c == 0xED) hi = 0x9F; else if (c == 0xF0) lo = 0x90; else if (c == 0xF4) hi = 0x8F;
            while (k < len && i + k < n && p[i + k] >= (k == 1 ? lo : 0x80) && p[i + k] <= (k == 1 ? hi : 0xBF)) k++;
        }
        if (len && k == len) [o appendBytes:p + i length:len]; else [o appendBytes:rep length:3];
        i += len && k == len ? len : k;
    }
    return [[NSString alloc] initWithData:o encoding:NSUTF8StringEncoding] ?: @"";
}

// 文本文件：超过 cap 只留头 cap/4 + 尾 cap*3/4（按行边界），中间一行「…截掉 N 字节…」；脱敏后写到 dst。返回 {bytes, truncated}
static NSDictionary *copy_text(NSString *src, NSString *dst, NSUInteger cap, NSString *(^redact)(NSString *)) {
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
    NSString *s = utf8_lossy(out);
    NSData *w = [redact(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (!w || ![w writeToFile:dst atomically:NO]) return nil;
    return @{@"bytes": @(w.length), @"truncated": @(cut)};
}

// 进文件名的款名：空白和路径 / 命令行不友好的字符换成下划线（显示名「空洞骑士 丝之歌」→「空洞骑士_丝之歌」；manifest 里仍写原名）
#include "far_top.h"
enum { FAR_TOP = 200 };   // 诊断包带远端点表的前多少个点
static NSString *far_sites_top(NSString *path, int top) { char *c = s2a_far_top(path.fileSystemRepresentation, top); if (!c) return nil; NSString *r = [NSString stringWithUTF8String:c]; free(c); return r; }
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

// ---------- 收成员 ----------
// D：Documents 根；W：工作目录（调用方已建好 W/logs）；cap：每份日志上限（字节）；slim：去掉 frames.tsv / threads.txt / 最早那次会话（超 30 MB 时退一档）
BOOL s2a_diag_collect(NSString *D, NSString *W, NSUInteger cap, BOOL slim, NSString *(^redact)(NSString *),
                      NSDictionary *(^summary)(NSString *path, NSString *name, BOOL current),
                      NSMutableArray *files, NSMutableArray *sessions, int *crash, int *hang, int *exits) {
    NSFileManager *fm = NSFileManager.defaultManager;
    __block BOOL copyFailed = NO;
    void (^add)(NSString *, NSString *, NSUInteger) = ^(NSString *src, NSString *rel, NSUInteger c) {
        NSDictionary *r = copy_text(src, [W stringByAppendingPathComponent:rel], c, redact);
        if (!r) copyFailed = YES;
        if (r) [files addObject:@{@"path": rel, @"bytes": r[@"bytes"], @"truncated": r[@"truncated"]}];
    };
    // 本局 host.log + 归档（os.c 每局一份，Documents/logs/host-<起局时刻>.log，新的在前）：精简包带上一局，完整包带全部（最多 9 份）
    NSArray *arch = archived_logs(D); NSMutableArray *logs = [NSMutableArray arrayWithObject:@"host.log"];
    [logs addObjectsFromArray:slim ? [arch subarrayWithRange:NSMakeRange(0, MIN(arch.count, (NSUInteger)1))] : arch];
    for (NSString *l in logs) {
        NSString *src = [D stringByAppendingPathComponent:l]; if (![fm fileExistsAtPath:src]) continue;
        NSMutableDictionary *s = [summary(src, l.lastPathComponent, [l isEqualToString:@"host.log"]) mutableCopy];
        if (s) [sessions addObject:s];
        add(src, [@"logs/" stringByAppendingString:l.lastPathComponent], cap);
    }
    NSArray *extra = slim ? @[@"unpack.log"] : @[@"frames.tsv", @"threads.txt", @"unpack.log"];
    for (NSString *f in extra) { NSString *src = [D stringByAppendingPathComponent:f]; if ([fm fileExistsAtPath:src]) add(src, [@"logs/" stringByAppendingString:f], cap); }
    // 远端缺页点表（runtime/src/far.c 收局 / 崩溃时写在本款文档根，多款容器 = Documents/games/<游戏号>/far_sites.tsv；原先只在 Documents/ 下找、只进完整包，
    //   诊断库里一份都没有）：精简包也带，按次数取前 FAR_TOP 个点（只有模块名、偏移、次数，不含个人信息），定「热点访存点改写成翻译跳板」值不值
    {   NSMutableArray *srcs = [NSMutableArray array]; NSString *G = [D stringByAppendingPathComponent:@"games"];
        if ([fm fileExistsAtPath:[D stringByAppendingPathComponent:@"far_sites.tsv"]]) [srcs addObject:@[@"", [D stringByAppendingPathComponent:@"far_sites.tsv"]]];
        for (NSString *gid in [[fm contentsOfDirectoryAtPath:G error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *src = [[G stringByAppendingPathComponent:gid] stringByAppendingPathComponent:@"far_sites.tsv"];
            if ([fm fileExistsAtPath:src]) [srcs addObject:@[[@"_" stringByAppendingString:file_safe(gid)], src]]; }
        for (NSArray *e in srcs) {
            NSString *txt = far_sites_top(e[1], FAR_TOP); if (!txt) continue;
            NSString *rel = [NSString stringWithFormat:@"logs/far_sites%@.tsv", e[0]];
            [fm createDirectoryAtPath:[W stringByAppendingPathComponent:@"logs"] withIntermediateDirectories:YES attributes:nil error:nil];
            if ([txt writeToFile:[W stringByAppendingPathComponent:rel] atomically:NO encoding:NSUTF8StringEncoding error:nil])
                [files addObject:@{@"path": rel, @"bytes": @([txt lengthOfBytesUsingEncoding:NSUTF8StringEncoding]), @"truncated": @NO}];
        } }
    // 多款容器：每款的解包日志在本款文档根 Documents/games/<游戏号>/unpack.log（runtime/src/pack_apply.c 的 logp），上面只收进程级那份、永远收不到
    //   （D-4VAX「装不上」：解小文件 -4 的现场 errno 只在这里，诊断包里一行都没有）。每款一份，放 logs/unpack_<游戏号>.log
    {   NSString *G = [D stringByAppendingPathComponent:@"games"];
        for (NSString *gid in [[fm contentsOfDirectoryAtPath:G error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *src = [[G stringByAppendingPathComponent:gid] stringByAppendingPathComponent:@"unpack.log"];
            if ([fm fileExistsAtPath:src]) add(src, [NSString stringWithFormat:@"logs/unpack_%@.log", gid], cap);
        } }
    NSString *mk = [D stringByAppendingPathComponent:@"metrickit"];
    for (NSString *f in [[fm contentsOfDirectoryAtPath:mk error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![f hasSuffix:@".json"]) continue;
        [fm createDirectoryAtPath:[W stringByAppendingPathComponent:@"metrickit"] withIntermediateDirectories:YES attributes:nil error:nil];
        add([mk stringByAppendingPathComponent:f], [@"metrickit/" stringByAppendingString:f], 4u << 20);
        if ([f containsString:@"crash"]) (*crash)++; if ([f containsString:@"hang"]) (*hang)++; if ([f hasSuffix:@"-exit.json"]) (*exits)++;
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
    // 编了 5 秒还没完的管线的 MSL 源（#065090，pso_archive.h par_slow_keep_src 留的 <键>.slow.metal，一局至多 4 份）：判大计算核拆分有没有覆盖到。
    //   文本，过脱敏（add）；每份至多 4 MB；多款容器 games/<游戏号>/wire/<游戏号>/shaders 与单款包 wire/<程序号>/shaders 都找，放 shaders/<程序号>_<原名>
    {   NSMutableArray *sds = [NSMutableArray array]; NSString *G = [D stringByAppendingPathComponent:@"games"], *Wd = [D stringByAppendingPathComponent:@"wire"];
        for (NSString *gid in [fm contentsOfDirectoryAtPath:G error:nil]) [sds addObject:@[gid, [[[[G stringByAppendingPathComponent:gid] stringByAppendingPathComponent:@"wire"] stringByAppendingPathComponent:gid] stringByAppendingPathComponent:@"shaders"]]];
        for (NSString *gid in [fm contentsOfDirectoryAtPath:Wd error:nil]) [sds addObject:@[gid, [[Wd stringByAppendingPathComponent:gid] stringByAppendingPathComponent:@"shaders"]]];
        int nk = 0;
        for (NSArray *sd in sds) for (NSString *f in [[fm contentsOfDirectoryAtPath:sd[1] error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
            if (nk >= 8 || ![f hasSuffix:@".slow.metal"]) continue;
            [fm createDirectoryAtPath:[W stringByAppendingPathComponent:@"shaders"] withIntermediateDirectories:YES attributes:nil error:nil];
            add([sd[1] stringByAppendingPathComponent:f], [NSString stringWithFormat:@"shaders/%@_%@", file_safe(sd[0]), f], 4u << 20); nk++;
        } }
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
    // 本机管线记录（11-13 维护者：玩家上传的诊断收进随包种子；取件 diag_pickup.py harvest_pso 收进众包 zc_crowd.tsv）：多款容器各款 games/<号>/wire/<号>/pso_user.tsv、
    //   单款包 wire/<号>/pso_user.tsv（nvn_mtl.m pso_user_path），原样放 pso/<号>.tsv——只有着色器键与管线状态的十六进制，不含个人信息、不过脱敏。
    //   单份超过 4 MB 跳过、合计至多 8 MB；同一款只放一份（多款容器那份优先）
    {   NSMutableArray *srcs = [NSMutableArray array];
        NSString *G = [D stringByAppendingPathComponent:@"games"], *Wd = [D stringByAppendingPathComponent:@"wire"];
        for (NSString *gid in [[fm contentsOfDirectoryAtPath:G error:nil] sortedArrayUsingSelector:@selector(compare:)])
            [srcs addObject:@[gid, [[[[G stringByAppendingPathComponent:gid] stringByAppendingPathComponent:@"wire"] stringByAppendingPathComponent:gid] stringByAppendingPathComponent:@"pso_user.tsv"]]];
        for (NSString *gid in [[fm contentsOfDirectoryAtPath:Wd error:nil] sortedArrayUsingSelector:@selector(compare:)])
            [srcs addObject:@[gid, [[Wd stringByAppendingPathComponent:gid] stringByAppendingPathComponent:@"pso_user.tsv"]]];
        NSCharacterSet *notHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] invertedSet];
        NSMutableSet *seen = [NSMutableSet set]; unsigned long long used = 0;
        for (NSArray *e in srcs) {
            NSString *gid = [e[0] uppercaseString];
            if (gid.length != 16 || [gid rangeOfCharacterFromSet:notHex].location != NSNotFound || [seen containsObject:gid]) continue;
            NSDictionary *at = [fm attributesOfItemAtPath:e[1] error:nil];
            if (![at.fileType isEqualToString:NSFileTypeRegular]) continue;   // 不跟链接
            unsigned long long n = at.fileSize;
            if (!n || n > (4ull << 20) || used + n > (8ull << 20)) continue;
            NSString *rel = [NSString stringWithFormat:@"pso/%@.tsv", gid];
            [fm createDirectoryAtPath:[W stringByAppendingPathComponent:@"pso"] withIntermediateDirectories:YES attributes:nil error:nil];
            if ([fm copyItemAtPath:e[1] toPath:[W stringByAppendingPathComponent:rel] error:nil]) { [files addObject:@{@"path": rel, @"bytes": @(n), @"truncated": @NO}]; used += n; [seen addObject:gid]; }
            // 同目录的局内用到的着色器（shader_seen.tsv，graphics/nvn/gfx/nvn/hle_nvn.c seen_note；只有键与阶段号）：放 pso/<号>.seen.tsv，同一份上限
            NSString *sv = [[e[1] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"shader_seen.tsv"];
            NSDictionary *sa = [fm attributesOfItemAtPath:sv error:nil]; unsigned long long sn = sa.fileSize;
            if ([sa.fileType isEqualToString:NSFileTypeRegular] && sn && sn <= (4ull << 20) && used + sn <= (8ull << 20)) {
                NSString *srel = [NSString stringWithFormat:@"pso/%@.seen.tsv", gid];
                if ([fm copyItemAtPath:sv toPath:[W stringByAppendingPathComponent:srel] error:nil]) { [files addObject:@{@"path": srel, @"bytes": @(sn), @"truncated": @NO}]; used += sn; }
            }
        } }
    // 着色器补料（graphics/nvn/host/dsh_salvage.inc，同 Mac pack/jobs/library.py 口径）：多款容器 games/<号>/wire/<号>/shader_miss/、单款包 wire/<号>/shader_miss/ 里
    //   库里没有 / 现编失败的着色器（index.tsv + 成对的 <键>.ctl / .code），每款打成一个 tar 放 shader_miss/<号>.tar（诊断包成员数有上限：
    //   tools/diagnostic_report.py MAX_FILES 1000）；取件归档进管线种子目录 rt_shaders/、出包编进那款的直连库。只有游戏着色器字节与键，不含个人信息、不过脱敏。
    //   每款至多 9 MB（运行时 8 MB + 索引余量）、合计至多 10 MB（整包压缩后 ≤ 30 MB，给日志 / 截图留地方）；索引先放，每键两份成对放（放不下整对不放）；
    //   同一款只收一处（多款容器那份优先）；不跟链接
    {   NSMutableArray *srcs = [NSMutableArray array];
        NSString *G = [D stringByAppendingPathComponent:@"games"], *Wd = [D stringByAppendingPathComponent:@"wire"];
        for (NSString *gid in [[fm contentsOfDirectoryAtPath:G error:nil] sortedArrayUsingSelector:@selector(compare:)])
            [srcs addObject:@[gid, [[[[G stringByAppendingPathComponent:gid] stringByAppendingPathComponent:@"wire"] stringByAppendingPathComponent:gid] stringByAppendingPathComponent:@"shader_miss"]]];
        for (NSString *gid in [[fm contentsOfDirectoryAtPath:Wd error:nil] sortedArrayUsingSelector:@selector(compare:)])
            [srcs addObject:@[gid, [[Wd stringByAppendingPathComponent:gid] stringByAppendingPathComponent:@"shader_miss"]]];
        NSCharacterSet *notHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] invertedSet];
        NSRegularExpression *keyCtl = [NSRegularExpression regularExpressionWithPattern:@"^[0-9a-f]{16}\\.ctl$" options:0 error:nil];
        NSMutableSet *seen = [NSMutableSet set]; unsigned long long used = 0;
        for (NSArray *e in srcs) {
            NSString *gid = [e[0] uppercaseString], *sd = e[1];
            if (gid.length != 16 || [gid rangeOfCharacterFromSet:notHex].location != NSNotFound || [seen containsObject:gid]) continue;
            if (![[fm attributesOfItemAtPath:sd error:nil].fileType isEqualToString:NSFileTypeDirectory]) continue;
            [seen addObject:gid];
            NSMutableArray *groups = [NSMutableArray arrayWithObject:@[@"index.tsv"]];
            for (NSString *f in [[fm contentsOfDirectoryAtPath:sd error:nil] sortedArrayUsingSelector:@selector(compare:)])
                if ([keyCtl firstMatchInString:f options:0 range:NSMakeRange(0, f.length)]) [groups addObject:@[f, [[f substringToIndex:16] stringByAppendingString:@".code"]]];
            NSMutableData *tar = [NSMutableData data]; unsigned long long game = 0;
            for (NSArray *names in groups) {
                NSMutableArray *datas = [NSMutableArray array]; unsigned long long n = 0; BOOL ok = YES;
                for (NSString *nm in names) { NSString *fp = [sd stringByAppendingPathComponent:nm];
                    if (![[fm attributesOfItemAtPath:fp error:nil].fileType isEqualToString:NSFileTypeRegular]) { ok = NO; break; }
                    NSData *d = [NSData dataWithContentsOfFile:fp]; if (!d) { ok = NO; break; } [datas addObject:d]; n += d.length; }
                if (!ok || !n || game + n > (9ull << 20) || used + game + n > (10ull << 20)) continue;
                for (NSUInteger i = 0; i < names.count; i++) {   // ustar：512 字节头（名、模式、大小八进制、校验和）+ 数据补齐到 512
                    NSData *d = datas[i]; char h[512]; memset(h, 0, sizeof h);
                    snprintf(h, 100, "%s", [names[i] UTF8String]); memcpy(h + 100, "0000644", 7); memcpy(h + 108, "0000000", 7); memcpy(h + 116, "0000000", 7);
                    snprintf(h + 124, 12, "%011llo", (unsigned long long)d.length); memcpy(h + 136, "00000000000", 11); h[156] = '0'; memcpy(h + 257, "ustar", 6); memcpy(h + 263, "00", 2);
                    memset(h + 148, ' ', 8); unsigned sum = 0; for (int b = 0; b < 512; b++) sum += (unsigned char)h[b]; snprintf(h + 148, 8, "%06o", sum); h[155] = ' ';
                    [tar appendBytes:h length:512]; [tar appendData:d]; static const char z[512]; if (d.length % 512) [tar appendBytes:z length:512 - d.length % 512];
                }
                game += n;
            }
            if (!game) continue;
            static const char z2[1024]; [tar appendBytes:z2 length:1024];   // tar 结尾两个空块
            NSString *rel = [NSString stringWithFormat:@"shader_miss/%@.tar", gid];
            [fm createDirectoryAtPath:[W stringByAppendingPathComponent:@"shader_miss"] withIntermediateDirectories:YES attributes:nil error:nil];
            if ([tar writeToFile:[W stringByAppendingPathComponent:rel] atomically:NO]) { [files addObject:@{@"path": rel, @"bytes": @(tar.length), @"truncated": @NO}]; used += game; }
        } }
    return !copyFailed;
}
