// 签名证书是手机上游戏状态的一部分（0.6.0 自签走查结论 1–5 条）：游戏库列出时就判这款要不要手机签、手机上有没有能签的证书，
//   不等点开始才发现、再静默翻成「需要在电脑上更新」。只用 Foundation，单测 runtime/tests/t_sign_state.m 在 Mac 上跑。
// 输入全是手机上的小文件：
//   App  identity/app.json（ios/prov_expiry.m 启动时写）：team = 装这个 App 的团队，cert_sha1[] = 包里描述文件 DeveloperCertificates 各张的 sha1
//   证书 identity/certs.tsv（runtime/src/selfsign.c 每导入成功一张记一行：sha1、团队、来源、时刻）＋ identity/current.json（现在用哪张；老数据只有它，也算一张）
//   程序 <根>/<号>/program/catalogue.json：signer{team, cert_sha1} = 手机签过；没有 signer 时 team = 电脑按哪个团队签的（null = 没签，起局时手机签）
// 「能用的证书」= 钥匙串里有它的签名身份、团队与 App 相同，且 sha1 在 App 描述文件的证书里（列表读不到时不看这一条）。描述文件里没有它 = 装 App 用的证书已换或吊销
//   （另一台电脑上的 AltServer 刷新过），用它签的程序系统不认
#import <Foundation/Foundation.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>

enum { S2A_SIGN_OK = 0, S2A_SIGN_NO_CERT = 1, S2A_SIGN_OTHER_TEAM = 2, S2A_SIGN_REPLACED = 3, S2A_SIGN_OLD_FORMAT = 4, S2A_SIGN_COMPUTER = 5 };

static NSString *idir(const char *home) { return [@(home) stringByAppendingPathComponent:@"Library/Application Support/S2Arm/identity"]; }
static NSDictionary *read_json(NSString *p) {
    NSData *d = [NSData dataWithContentsOfFile:p]; id o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [o isKindOfClass:NSDictionary.class] ? o : nil;
}
static NSString *str(id v) { return [v isKindOfClass:NSString.class] && [v length] ? v : nil; }

typedef struct { NSString *team; NSSet<NSString *> *certs; } app_t;   // team nil = 读不到（ad-hoc / TrollStore 包）
static app_t app_read(const char *home) {
    NSDictionary *j = read_json([idir(home) stringByAppendingPathComponent:@"app.json"]);
    NSMutableSet *c = [NSMutableSet set]; id a = j[@"cert_sha1"];
    for (id x in [a isKindOfClass:NSArray.class] ? a : @[]) if (str(x)) [c addObject:[x lowercaseString]];
    return (app_t){str(j[@"team"]), c};
}
// 手机上的证书，按导入先后排（最后一个最新）：{sha, team, source, imported}
static NSArray<NSDictionary *> *certs_read(const char *home) {
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    NSString *t = [NSString stringWithContentsOfFile:[idir(home) stringByAppendingPathComponent:@"certs.tsv"] encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [t componentsSeparatedByString:@"\n"]) {
        NSArray *f = [line componentsSeparatedByString:@"\t"]; if (f.count < 4 || ![f[0] length]) continue;
        NSString *sha = [f[0] lowercaseString]; NSIndexSet *dup = [rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *r, NSUInteger i, BOOL *s) { (void)i; (void)s; return [r[@"sha"] isEqualToString:sha]; }];
        [rows removeObjectsAtIndexes:dup];
        [rows addObject:@{@"sha": sha, @"team": f[1], @"source": f[2], @"imported": @([f[3] longLongValue])}];
    }
    NSDictionary *cur = read_json([idir(home) stringByAppendingPathComponent:@"current.json"]); NSString *cs = str(cur[@"cert_sha1"]).lowercaseString;
    if (cs && [rows indexOfObjectPassingTest:^BOOL(NSDictionary *r, NSUInteger i, BOOL *s) { (void)i; (void)s; return [r[@"sha"] isEqualToString:cs]; }] == NSNotFound)
        [rows insertObject:@{@"sha": cs, @"team": str(cur[@"team"]) ?: @"", @"source": str(cur[@"source"]) ?: @"pc", @"imported": @([cur[@"imported"] longLongValue])} atIndex:0];   // 登记表之前导入的那张（只在 current.json 里）
    [rows sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"imported"] compare:b[@"imported"]]; }];
    return rows;
}
// LiveContainer（#63639b）：S2Arm 当客体跑在 LiveContainer 进程里时，进程的签名身份是 LiveContainer 的——它用自己存的开发证书重签客体 App 包里的
//   Mach-O，系统只认这张证书签的代码。游戏程序库在 App 包外，LiveContainer 不重签，所以起局重签一律用这张（ios/program_resign.m），游戏库也按「有能用的证书」判。
//   证书与口令存在 LiveContainer 的共享偏好（LCCertificateData / LCCertificatePassword），经它自己的 +[NSUserDefaults lcSharedDefaults] 读
//   （客体按共享组名直接读会被它重定向到客体容器，读不到）。只在内存里用，不落盘、不进日志。
//   1 = 在 LiveContainer 里且有证书（p12 / pw 带回，可传 NULL）；0 = 不在 LiveContainer 里；-1 = 在 LiveContainer 里但它还没导入证书
static int lc_cert_real(NSData **p12, NSString **pw) {
    SEL s = NSSelectorFromString(@"lcSharedDefaults");
    if (!NSClassFromString(@"LCSharedUtils") || ![NSUserDefaults respondsToSelector:s]) return 0;
    NSUserDefaults *(*get)(id, SEL) = (NSUserDefaults *(*)(id, SEL))[NSUserDefaults methodForSelector:s];
    NSUserDefaults *d = get(NSUserDefaults.class, s);
    id c = [d objectForKey:@"LCCertificateData"], w = [d objectForKey:@"LCCertificatePassword"];
    if (![c isKindOfClass:NSData.class] || ![c length] || ![w isKindOfClass:NSString.class]) return -1;
    if (p12) *p12 = c;
    if (pw) *pw = w;
    return 1;
}
static int (*g_lc_cert)(NSData **, NSString **) = lc_cert_real;
#ifdef S2A_UNIT_TEST
void s2a_lc_cert_test(int (*f)(NSData **, NSString **)) { g_lc_cert = f ? f : lc_cert_real; }   // 单测换掉「读 LiveContainer 的共享偏好」
#endif
int s2a_lc_cert(NSData **p12, NSString **pw) { return g_lc_cert(p12, pw); }
// LiveContainer 存的那张起局重签用不用得上（同 ios/program_resign.m lc_identity）：1 = 在里面、解得开；0 = 不在里面；-1 = 在里面、它没导入；
//   -2 = 导入了、S2Arm 解不开（#502 / D-D8F4 的 -26275：起局改用导入进 S2Arm 的那张，游戏库就按那张判，不再当「有能用的证书」）
#include <Security/Security.h>
int s2a_selfsign_identity(const void *p12, size_t n, const char *password, SecKeyRef *key, CFArrayRef *chain);
static int lc_usable(void) {
    static NSData *seen; static int ok;   // 只在 p12 换了时重解（游戏库每款判一次，解一次几十毫秒）
    NSData *p12 = nil; NSString *pw = nil; int r = s2a_lc_cert(&p12, &pw);
    if (r <= 0) return r;
    if (![p12 isEqualToData:seen]) {
        SecKeyRef key = NULL; CFArrayRef chain = NULL;
        ok = !s2a_selfsign_identity(p12.bytes, p12.length, pw.UTF8String, &key, &chain) && chain && CFArrayGetCount(chain) > 0;
        if (key) CFRelease(key);
        if (chain) CFRelease(chain);
        seen = p12;
    }
    return ok ? 1 : -2;
}

static BOOL usable(NSDictionary *r, app_t app) { return [r[@"team"] isEqualToString:app.team] && (!app.certs.count || [app.certs containsObject:r[@"sha"]]); }

// 登记表里的这张在钥匙串里还有没有签名身份（私钥 + 证书）。没有就不算手机上的证书（11-22 D-4GCZ：current.json / certs.tsv 记着 c74b6e9c…，
//   钥匙串里却没有它的身份，起局重签必失败〔ios/program_resign.m「钥匙串里没有证书 … 的签名身份」〕；原先挑证书只比团队与描述文件，
//   判成「有能用的证书、重签了仍被拒」= 5「只能回电脑重装」，玩家照做两遍无效——缺的是手机上的证书，该判 1 让玩家重新导入）。
//   游戏库每款判一次：结果按登记表与 current.json 的修改时间缓存（导入证书必改登记表，缓存随之作废）
int s2a_identity_keychain(const char *sha, SecKeyRef *key, SecCertificateRef *cert);   // runtime/src/selfsign.c
static int kc_has_real(const char *sha) {
    SecKeyRef k = NULL; SecCertificateRef c = NULL; int ok = !s2a_identity_keychain(sha, &k, &c) && k && c;
    if (k) CFRelease(k);
    if (c) CFRelease(c);
    return ok;
}
static int (*g_kc_has)(const char *) = kc_has_real;
#ifdef S2A_UNIT_TEST
void s2a_sign_state_test_keychain(int (*f)(const char *)) { g_kc_has = f ? f : kc_has_real; }   // 单测换掉钥匙串
#endif
static double mtime(NSString *p) { struct stat st; return stat(p.fileSystemRepresentation, &st) ? 0 : st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec / 1e9; }
static BOOL in_keychain(const char *home, NSString *sha) {
    static NSMutableDictionary<NSString *, NSNumber *> *seen; static NSString *stamp;
    NSString *s = [NSString stringWithFormat:@"%s|%.6f|%.6f|%p", home, mtime([idir(home) stringByAppendingPathComponent:@"certs.tsv"]),
                   mtime([idir(home) stringByAppendingPathComponent:@"current.json"]), (void *)g_kc_has];
    @synchronized (NSDictionary.class) {
        if (![s isEqualToString:stamp]) { seen = [NSMutableDictionary dictionary]; stamp = s; }
        NSNumber *v = seen[sha]; if (!v) seen[sha] = v = @(g_kc_has(sha.UTF8String) != 0);
        return v.boolValue;
    }
}

// 挑起局签名用哪张（只看钥匙串里还有签名身份的那几张）：0 = 有能用的（sha / team 带回最新一张能用的）；1 = 手机上没有证书；2 = 只有别的团队的；3 = 有同团队的但都不在描述文件里（已换 / 吊销）。
//   App 团队读不到：最新一张就算能用（判不了不拦）
int s2a_cert_pick(const char *home, char *sha, size_t sha_n, char *team, size_t team_n) {
    @autoreleasepool {
        if (sha && sha_n) sha[0] = 0; if (team && team_n) team[0] = 0;
        if (!home) return 1;
        NSArray<NSDictionary *> *rows = [certs_read(home) filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *r, NSDictionary *b) { (void)b; return in_keychain(home, r[@"sha"]); }]];
        if (!rows.count) return 1;   // 登记过、钥匙串里却没有身份的不算（D-4GCZ）：一张都不剩 = 手机上没有证书
        app_t app = app_read(home); NSDictionary *pick = nil; BOOL same_team = NO;
        for (NSDictionary *r in rows) {
            if (!app.team || usable(r, app)) pick = r;
            if (app.team && [r[@"team"] isEqualToString:app.team]) same_team = YES;
        }
        if (!pick) return same_team ? 3 : 2;
        if (sha && sha_n) snprintf(sha, sha_n, "%s", [pick[@"sha"] UTF8String]);
        if (team && team_n) snprintf(team, team_n, "%s", [pick[@"team"] UTF8String]);
        return 0;
    }
}

// 让 current.json 指向能用的那张（导入一张别的团队的证书后，原来能用的不被顶掉）：导入成功后、App 启动后、起局重签前调。
//   没有能用的就不动（照旧是最后导入的那张：起局重签按它说清团队不符）。返回 s2a_cert_pick 的结果
int s2a_cert_settle(const char *home) {
    @autoreleasepool {
        char sha[64], team[64]; int r = s2a_cert_pick(home, sha, sizeof sha, team, sizeof team);
        if (r) return r;
        NSString *curp = [idir(home) stringByAppendingPathComponent:@"current.json"]; NSDictionary *cur = read_json(curp);
        if ([str(cur[@"cert_sha1"]).lowercaseString isEqualToString:@(sha)]) return 0;
        NSDictionary *row = nil; for (NSDictionary *x in certs_read(home)) if ([x[@"sha"] isEqualToString:@(sha)]) row = x;
        NSString *j = [NSString stringWithFormat:@"{\"schema\": 1, \"team\": \"%s\", \"cert_sha1\": \"%s\", \"imported\": %lld, \"source\": \"%@\"}\n",
                       team, sha, [row[@"imported"] longLongValue], row[@"source"] ?: @"pc"];
        NSString *tmp = [curp stringByAppendingString:@".tmp"];
        if (![j writeToFile:tmp atomically:NO encoding:NSUTF8StringEncoding error:nil] || rename(tmp.fileSystemRepresentation, curp.fileSystemRepresentation)) return 0;
        NSLog(@"[s2a] 签名证书：现用证书换回与 App 同团队的那张（团队 %s、sha1 %s）", team, sha);
        return 0;
    }
}

// 这款的签名状态（游戏库列出时判，见文件头）：catalogue = 这款程序包清单的路径；rejected = 点开始时系统拒过它的签名、之后程序包和证书都没变。
//   0 可玩；1 要手机签、手机上没有证书；2 手机上只有别的团队的证书；3 同团队证书已换 / 吊销；4 电脑签的签名本机不认（格式老）、手机上没证书重签；
//   5 手机上有能用的证书、重签了仍被拒：只能回电脑重装（原「需要在电脑上更新」）
int s2a_sign_state_at(const char *home, const char *catalogue, int rejected) {
    @autoreleasepool {
        if (!home || !catalogue) return S2A_SIGN_OK;
        app_t app = app_read(home);
        // LiveContainer 里没有 app.json（App 是 LiveContainer 装的、不经电脑），团队判不了；它存的证书又用不上时（#502 / D-92TD：-1 / -26275），
        //   起局只能用导入进 S2Arm 的那张：一张都没有就是 1「需要签名证书」（卡片上直接导入），原先这里一律判 5「去电脑更新」，玩家照做无效
        if (!app.team && lc_usable() < 0 && s2a_cert_pick(home, NULL, 0, NULL, 0) == 1) return S2A_SIGN_NO_CERT;
        if (!app.team) return rejected ? S2A_SIGN_COMPUTER : S2A_SIGN_OK;   // 判不了团队：不预判，被拒的照旧回电脑
        NSDictionary *cat = read_json(@(catalogue)); if (!cat) return rejected ? S2A_SIGN_COMPUTER : S2A_SIGN_OK;
        NSDictionary *signer = [cat[@"signer"] isKindOfClass:NSDictionary.class] ? cat[@"signer"] : nil;
        NSString *ssha = str(signer[@"cert_sha1"]).lowercaseString, *steam = str(signer[@"team"]) ?: str(cat[@"team"]);
        BOOL fine = steam && [steam isEqualToString:app.team] && (!ssha || !app.certs.count || [app.certs containsObject:ssha]);
        if (fine && !rejected) return S2A_SIGN_OK;
        int p = lc_usable() > 0 ? 0 : s2a_cert_pick(home, NULL, 0, NULL, 0);   // LiveContainer 里：起局用它的证书重签；它那张解不开就同起局改看导入进 S2Arm 的
        if (p == 0) return rejected ? S2A_SIGN_COMPUTER : S2A_SIGN_OK;   // 起局时用能用的那张重签
        if (p == 1) return rejected && fine ? S2A_SIGN_OLD_FORMAT : S2A_SIGN_NO_CERT;
        return p == 2 ? S2A_SIGN_OTHER_TEAM : S2A_SIGN_REPLACED;
    }
}

// 设置页状态行要标的：0 现用证书能用（或手机上没有证书）；2 现用的是别的团队的；3 现用的已不在描述文件里（已失效）
int s2a_cert_health(const char *home) {
    int p = s2a_cert_pick(home, NULL, 0, NULL, 0);
    return p == 2 || p == 3 ? p : 0;
}
