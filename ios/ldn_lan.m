// 本地联机·同一 Wi-Fi：每台设备都在全部网卡上托管中继（services LdnRelay），
//   用 Bonjour 发布「<程序号>-<设备号>」（_s2arm-ldn._tcp，端口由共享层传入），同时浏览同一款游戏的其他中继；
//   大家按同一规则（名字最小的那台）选出同一台中继，选举结果变了就经 S2A_LdnSetServer 改指（游戏下一次建房 / 加入生效）。
//   本机中继有了房间，发布名改成「<程序号>-!<设备号>」（'!' 排在一切字母数字前）：有房间的中继必被选中，建房早于对方进联机菜单也找得到。
//   不分先后、不需要谁先建房：每台看到的候选集合相同，选出的就是同一台。
// 何时起：游戏第一次初始化 ldn:u 时由 C#（Host.OnLdnInitializing）调已登记的 provider——只有用联机的游戏才碰网络、才弹「本地网络」授权（Info.plist 说明文字）；
//   S2A_LDN_SERVER=lan 时共享服务起局就调（开发 / 调试）。没有设置开关：不想联机就不进联机菜单、或在系统的「本地网络」权限里拒绝。
// 弱链接[host,ios]：S2A_LdnSetServer（C# 服务层 LdnRelay.cs 提供；链接行按这行放行未定义，runtime/build.mk 自动收）
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include "../runtime/src/native.h"   // 相对路径：Mac 宿主的头文件路径没有 runtime/src（ldn_lan.m 也编进 Mac 宿主）
#include "s2a_lan_discovery.h"
#include "s2a_lan_elect.h"
#include <errno.h>
#include <pthread.h>

void S2A_LdnSetServer(const char *ipv4) __attribute__((weak_import));
void s2a_lan_permission_then(int dev_mode, void (^go)(void));   // lan_permission.m：首次联机前先说明本地网络权限用途
void s2a_lan_permission_failed(const char *what, NSDictionary *err);   // lan_permission.m：发布 / 浏览失败（多半被拒）→ 引导去设置

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"   // NSNetService：iOS 上仍可用，比 Network.framework 的 nw_browser 简单够用
@interface S2ALdnLan : NSObject <NSNetServiceDelegate, NSNetServiceBrowserDelegate>
@property(strong) NSNetService *own;
@property(strong) NSNetServiceBrowser *browser;
@property(strong) NSMutableDictionary<NSString *, NSNetService *> *found;   // 名字 → 服务（同款游戏）
@property(strong) NSMutableDictionary<NSString *, NSString *> *ips;          // 名字 → 解析出的 IPv4
@property(copy) NSString *prefix, *dev, *ownName, *chosen;
@property BOOL hosting;
@property BOOL inBackground;            // App 在后台：系统会停掉本 App 的 Bonjour（发布 / 浏览回 -72000），回前台要重开
@property(strong) NSArray *lifeObservers;
@property uint16_t port;
@property uint64_t programId;
@end

// Only the callback publication gate is synchronous; Bonjour operations stay on
// the main run loop. Stop invalidates the old object before queuing its cleanup.
static pthread_mutex_t g_lan_gate = PTHREAD_MUTEX_INITIALIZER;
static S2ALdnLan *g_lan;
static int lan_is_current(S2ALdnLan *lan) {
    pthread_mutex_lock(&g_lan_gate);
    int current = g_lan == lan;
    pthread_mutex_unlock(&g_lan_gate);
    return current;
}
@implementation S2ALdnLan
// 前后台：iOS 在 App 进后台时停掉它的 Bonjour 发布与浏览（两个失败回调都回 NSNetServicesErrorCode -72000，玩家诊断里三次都在「进后台」那一刻），
//   回前台后不会自己恢复——原先此后一直找不到别的设备、别人也找不到本机，还把这次失败当成「本地网络权限被拒」弹框。
//   通知名用字符串（与 UIKit 常量同值）：本文件只依赖 Foundation，Mac 单测整份编进来
- (void)watchLife {
    if (self.lifeObservers) return;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter; __weak S2ALdnLan *w = self;
    self.lifeObservers = @[
        [nc addObserverForName:@"UIApplicationDidEnterBackgroundNotification" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; w.inBackground = YES; }],
        [nc addObserverForName:@"UIApplicationWillEnterForegroundNotification" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n;
            S2ALdnLan *me = w; if (!me || !me.inBackground) return; me.inBackground = NO;
            if (me.ownName && lan_is_current(me)) { LOG("[S2A 联机] 局域网：回前台，重新发布本机中继、重新找其他设备"); [me restartBonjour]; } }],
    ];
}
- (void)unwatchLife { for (id o in self.lifeObservers) [NSNotificationCenter.defaultCenter removeObserver:o]; self.lifeObservers = nil; }
- (void)stopBonjour {
    self.browser.delegate = nil; [self.browser stop]; self.browser = nil;
    self.own.delegate = nil; [self.own stop]; self.own = nil;
    for (NSNetService *service in self.found.allValues) { service.delegate = nil; [service stop]; }
    [self.found removeAllObjects]; [self.ips removeAllObjects];
    self.chosen = nil;
}
- (void)stop { [self unwatchLife]; [self stopBonjour]; }
- (void)browse {
    self.browser = [NSNetServiceBrowser new]; self.browser.delegate = self;
    [self.browser searchForServicesOfType:@"_s2arm-ldn._tcp." inDomain:@"local."];
}
// 回前台：系统停掉的发布 / 浏览整个重来（已找到的设备清空，重新浏览会再报一遍；选举结果按新的候选重新算）
- (void)restartBonjour {
    [self stopBonjour];
    [self publish]; [self browse];
    [self elect];
}
- (void)start:(NSString *)programId {
    self.prefix = [programId stringByAppendingString:@"-"];
    NSString *dev = [[NSUserDefaults.standardUserDefaults stringForKey:@"S2ALanDeviceId"] copy];
    if (!dev.length) { dev = [NSUUID.UUID.UUIDString substringToIndex:8].lowercaseString; [NSUserDefaults.standardUserDefaults setObject:dev forKey:@"S2ALanDeviceId"]; }
    self.dev = dev;
    self.found = [NSMutableDictionary new]; self.ips = [NSMutableDictionary new];
    [self watchLife];
    [self publish]; [self browse];
    LOG("[S2A 联机] 局域网：发布本机中继 %s，开始找同一款游戏的其他设备", self.ownName.UTF8String);
    [self elect];
}
// 发布本机：有房间时名字带「!」标记。重新发布 = 停掉旧名再发新名（NSNetService 的名字不可改）
- (void)publish {
    [self.own stop];
    self.ownName = [NSString stringWithFormat:@"%@%@%@", self.prefix, self.hosting ? @"!" : @"", self.dev];
    self.own = [[NSNetService alloc] initWithDomain:@"local." type:@"_s2arm-ldn._tcp." name:self.ownName port:self.port];
    self.own.delegate = self; [self.own publish];
}
- (void)setHostingFlag:(BOOL)on {
    if (on == self.hosting) return;
    self.hosting = on;
    [self publish];
    LOG("[S2A 联机] 局域网：本机中继%s房间，发布名改为 %s", on ? "有" : "没有", self.ownName.UTF8String);
    [self elect];
}
// 是不是本机（不管带不带「!」标记）：浏览器也会看到自己发布的服务，改名前后两个名字都要排除。
//   判定与安卓共用 runtime/src/lan_elect.c（单测 t_lan_elect），不在这里另写一份
- (BOOL)isSelf:(NSString *)name {
    return s2a_lan_is_self(self.prefix.UTF8String, self.dev.UTF8String, name.UTF8String) != 0;
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)b didFindService:(NSNetService *)s moreComing:(BOOL)more {
    (void)more;
    if (b != self.browser || !lan_is_current(self)) return;
    if (![s.name hasPrefix:self.prefix] || [self isSelf:s.name]) return;
    self.found[s.name] = s; s.delegate = self; [s resolveWithTimeout:5];
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)b didRemoveService:(NSNetService *)s moreComing:(BOOL)more {
    (void)more;
    if (b != self.browser || !lan_is_current(self)) return;
    if (![self.found objectForKey:s.name]) return;
    [self.found removeObjectForKey:s.name]; [self.ips removeObjectForKey:s.name];
    LOG("[S2A 联机] 局域网：%s 离开", s.name.UTF8String); [self elect];
}
- (void)netServiceDidResolveAddress:(NSNetService *)s {
    if (!lan_is_current(self) || self.found[s.name] != s || s.port != self.port) return;
    for (NSData *a in s.addresses) {
        const struct sockaddr *sa = a.bytes;
        if (a.length < sizeof(struct sockaddr_in) || sa->sa_family != AF_INET) continue;
        char ip[INET_ADDRSTRLEN]; inet_ntop(AF_INET, &((const struct sockaddr_in *)sa)->sin_addr, ip, sizeof ip);
        self.ips[s.name] = [NSString stringWithUTF8String:ip];
        LOG("[S2A 联机] 局域网：找到 %s（%s）", s.name.UTF8String, ip); [self elect]; return;
    }
}
// 失败：在后台时是系统停了本 App 的 Bonjour（回前台 restartBonjour 重开），只记一行；在前台才可能是本地网络权限被拒，交 lan_permission.m 引导去设置
- (void)netServiceDidPublish:(NSNetService *)s { if (s == self.own && lan_is_current(self)) LOG("[S2A 联机] 局域网：本机中继 %s 已发布", s.name.UTF8String); }
- (void)netService:(NSNetService *)s didNotPublish:(NSDictionary *)e {
    if (s != self.own || !lan_is_current(self)) return;
    if (self.inBackground) LOG("[S2A 联机] 局域网：发布本机中继停了（App 在后台，系统停掉 Bonjour：%s），回前台重开", [e[NSNetServicesErrorCode] description].UTF8String); else s2a_lan_permission_failed("发布本机中继", e);
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)b didNotSearch:(NSDictionary *)e {
    if (b != self.browser || !lan_is_current(self)) return;
    if (self.inBackground) LOG("[S2A 联机] 局域网：查找其他设备停了（App 在后台，系统停掉 Bonjour：%s），回前台重开", [e[NSNetServicesErrorCode] description].UTF8String); else s2a_lan_permission_failed("查找其他设备", e);
}
- (void)netService:(NSNetService *)s didNotResolve:(NSDictionary *)e { (void)e; LOG("[S2A 联机] 局域网：解析 %s 失败", s.name.UTF8String); }
// 选举：本机与已解析的同款设备里名字最小的那台（带「!」= 有房间的排最前）；是本机就用回环。
//   比较规则与安卓共用 s2a_lan_elect（按字节比，单测 t_lan_elect）：两边各写一份，规则一漂移，同一 Wi-Fi 的苹果机和安卓机就选出不同的中继
- (void)elect {
    NSArray<NSString *> *cands = [@[self.ownName] arrayByAddingObjectsFromArray:self.ips.allKeys];   // 本机排第一：同名时取本机
    const char *names[cands.count];
    for (NSUInteger i = 0; i < cands.count; i++) names[i] = cands[i].UTF8String;
    int at = s2a_lan_elect(self.prefix.UTF8String, names, (int)cands.count);
    if (at < 0) return;
    NSString *best = cands[at];
    if ([best isEqualToString:self.chosen]) return;
    self.chosen = best;
    NSString *ip = [best isEqualToString:self.ownName] ? @"127.0.0.1" : self.ips[best];
    LOG("[S2A 联机] 局域网：选中中继 %s（%s）", best.UTF8String, ip.UTF8String);
    pthread_mutex_lock(&g_lan_gate);
    if (g_lan == self && S2A_LdnSetServer) S2A_LdnSetServer(ip.UTF8String);
    pthread_mutex_unlock(&g_lan_gate);
}
@end
#pragma clang diagnostic pop

// Called under g_lan_gate only after a start is accepted. Capture the caller's
// initial opt-out once: our diagnostic setenv must not turn a later restart
// into a development session while the first permission explanation is pending.
static int lan_permission_dev_mode(void) {
    static int initial = -1;
    if (initial < 0) {
        const char *ev = getenv("S2A_LDN_SERVER");
        initial = ev && !strcmp(ev, "lan");
    }
    return initial;
}

// Entry points return promptly; no dispatch_sync / wait for the main thread.
static int lan_start(uint64_t program_id, uint16_t port) {
    if (!port) return -EINVAL;
    if (!S2A_LdnSetServer) return -ENOTSUP;
    pthread_mutex_lock(&g_lan_gate);
    if (g_lan) {
        int result = g_lan.programId == program_id && g_lan.port == port ? 0 : -EBUSY;
        pthread_mutex_unlock(&g_lan_gate); return result;
    }
    S2ALdnLan *lan = [S2ALdnLan new];
    lan.port = port; lan.programId = program_id;
    g_lan = lan;
    // Preserve main's first-use permission explanation and unattended-mode opt-out.
    int dev = lan_permission_dev_mode();
    setenv("S2A_LDN_SERVER", "lan", 1);
    pthread_mutex_unlock(&g_lan_gate);
    NSString *pid = [NSString stringWithFormat:@"%016llx", (unsigned long long)program_id];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!lan_is_current(lan)) return;
        s2a_lan_permission_then(dev, ^{
            // Permission UI may outlive stop/restart; never revive the old session.
            if (lan_is_current(lan)) [lan start:pid];
        });
    });
    return 0;
}
static void lan_hosting(int on) {
    pthread_mutex_lock(&g_lan_gate);
    S2ALdnLan *lan = g_lan;
    pthread_mutex_unlock(&g_lan_gate);
    if (!lan) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!lan_is_current(lan)) return;
        if (lan.ownName) [lan setHostingFlag:on != 0];
        else lan.hosting = on != 0;   // hosting raced the queued start
    });
}
static void lan_stop(void) {
    pthread_mutex_lock(&g_lan_gate);
    S2ALdnLan *lan = g_lan;
    g_lan = nil;
    pthread_mutex_unlock(&g_lan_gate);
    if (lan) dispatch_async(dispatch_get_main_queue(), ^{ [lan stop]; });
}
const s2a_lan_discovery_v1 *s2a_ldn_lan_provider(void) {
    static const s2a_lan_discovery_v1 provider = {1, lan_start, lan_hosting, lan_stop};
    return &provider;
}
