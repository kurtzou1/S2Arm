// 金手指面板（11-09 B 方案）：齿轮菜单进入。只管文件：导入 txt 到 <文档根>/cheats/、开关写 enabled.txt（每行「文件名/条目名」，缺省全关）、
//   读服务层写的 status.txt 显示每条状态（每秒刷新）。执行、版本校验、改代码拦截都在 services/S2A.Services/Cheats.cs，开关约 1 秒内生效，不用重启。
//   解析规则与 Cheats.cs Parse 一致：[名字] 普通条目，{名字} 主代码（不单独列开关，随同文件任一条开着执行），其余非空行是指令。
#import "vpad_cheats.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "s2a_docs.h"
#import "s2a_l10n.h"

// 弱链接[lab]：s2a_main_build_id（runtime/src/loader.c 主程序构建号；输入工作台不链原生核，取不到就不显示版本号提示）
const char *s2a_main_build_id(void) __attribute__((weak_import));

// s2a_cheats_parse 在 ios/cheats_parse.m（只依赖 Foundation，Mac 单测 runtime/tests/t_cheats_parse.m 能直接编）

// 本宿主有金手指界面：装载期向原生层登记，服务层（Cheats.cs）才起金手指线程（Mac / 安卓没有这个文件，不登记、不起）
// 弱链接[lab]：s2a_cheats_host_enable（runtime/src/loader.c；输入工作台不链原生核，取不到就不登记）
void s2a_cheats_host_enable(void) __attribute__((weak_import));
__attribute__((constructor)) static void cheats_register_host(void) { if (s2a_cheats_host_enable) s2a_cheats_host_enable(); }
static NSURL *cheats_dir(void) {   // 文档根唯一取法（s2a_docs.h），与服务层 Cheats.cs（经 s2a_cheats_dir）同一目录
    char d[1024]; s2a_docs_path(d, sizeof d, "cheats");
    return [NSURL fileURLWithPath:@(d) isDirectory:YES];
}

// 「导入金手指」的系统文件选择器：起始目录给本款的金手指文件夹（没有就建）。不给起始目录时选择器落在「最近项目」，
//   那一页要汇总机上所有开了文件共享的 App，被大容器拖住时一直「正在加载」，玩家看着像卡死（11-11 真机复现：几分钟不出内容，App 主线程空闲）
UIDocumentPickerViewController *s2a_cheats_import_picker(void) {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypePlainText, UTTypeText] asCopy:YES];
    p.allowsMultipleSelection = YES;
    NSURL *dir = cheats_dir();
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    p.directoryURL = dir;
    return p;
}

@interface S2ACheatFile : NSObject
@property (nonatomic, copy) NSString *file; @property (nonatomic, copy) NSArray<NSString *> *names; @property (nonatomic) BOOL bad;
@end
@implementation S2ACheatFile
@end

// status.txt 的状态值是与服务层 Cheats.cs 约定的串（比对照原样用中文），显示时换成当前语言；认不出的原样显示
static NSString *cheat_status_text(NSString *st) {
    NSDictionary *t = @{@"生效中": S2AL(@"cheats.status.active"), @"地址未就绪": S2AL(@"cheats.status.addressNotReady"), @"执行出错": S2AL(@"cheats.status.execError"),
        @"改代码，不支持": S2AL(@"cheats.status.modifiesCode"), @"格式不对": S2AL(@"cheats.status.badFormat"), @"版本不符": S2AL(@"cheats.status.versionMismatch"),
        @"关": S2AL(@"cheats.status.off"), @"游戏未装载": S2AL(@"cheats.status.gameNotLoaded"), @"指令有误": S2AL(@"cheats.status.badInstruction")};
    return st ? t[st] ?: st : nil;
}

@interface S2ACheatsPanel : UITableViewController <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^closed)(void);
@end
@implementation S2ACheatsPanel {
    NSArray<S2ACheatFile *> *_files; NSMutableSet<NSString *> *_on; NSDictionary<NSString *, NSString *> *_status; NSTimer *_timer;
}
- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = S2AL(@"cheats.title"); return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:S2AL(@"cheats.import") style:UIBarButtonItemStylePlain target:self action:@selector(import)];
    self.navigationItem.rightBarButtonItem.accessibilityIdentifier = @"cheats.import";
    [self reload];
}
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; __weak typeof(self) ws = self; _timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { (void)t; [ws refreshStatus]; }]; }
- (void)viewDidDisappear:(BOOL)a { [super viewDidDisappear:a]; [_timer invalidate]; _timer = nil; if (self.isBeingDismissed || self.navigationController.isBeingDismissed) { if (_closed) _closed(); _closed = nil; } }
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)reload {
    NSFileManager *fm = NSFileManager.defaultManager; NSURL *dir = cheats_dir();
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *f in [[fm contentsOfDirectoryAtPath:dir.path error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![f.pathExtension.lowercaseString isEqual:@"txt"] || [f isEqual:@"enabled.txt"] || [f isEqual:@"status.txt"]) continue;
        NSString *text = [NSString stringWithContentsOfURL:[dir URLByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:nil];
        NSArray *parsed = text ? s2a_cheats_parse(text) : nil;
        S2ACheatFile *cf = [S2ACheatFile new]; cf.file = f; cf.bad = parsed == nil;
        NSMutableArray *names = [NSMutableArray array];
        for (NSDictionary *e in parsed) if (![e[@"master"] boolValue]) [names addObject:e[@"name"]];
        cf.names = names; [files addObject:cf];
    }
    _files = files;
    NSString *en = [NSString stringWithContentsOfURL:[dir URLByAppendingPathComponent:@"enabled.txt"] encoding:NSUTF8StringEncoding error:nil];
    _on = [NSMutableSet setWithArray:[en componentsSeparatedByString:@"\n"] ?: @[]]; [_on removeObject:@""];
    [self readStatus]; [self.tableView reloadData];
}
- (void)readStatus {
    NSString *st = [NSString stringWithContentsOfURL:[cheats_dir() URLByAppendingPathComponent:@"status.txt"] encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSString *l in [st componentsSeparatedByString:@"\n"]) { NSArray *p = [l componentsSeparatedByString:@"\t"]; if (p.count == 2) m[p[0]] = p[1]; }
    _status = m;
}
- (void)refreshStatus {
    NSDictionary *old = _status; [self readStatus];
    if (![old isEqualToDictionary:_status]) [self.tableView reloadData];
}
- (BOOL)writeEnabled {
    NSURL *dir = cheats_dir(); NSError *e;
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *body = [[[_on allObjects] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@"\n"];
    if ([[body stringByAppendingString:@"\n"] writeToURL:[dir URLByAppendingPathComponent:@"enabled.txt"] atomically:YES encoding:NSUTF8StringEncoding error:&e]) return YES;
    [self alert:S2AL(@"cheats.error.toggleNotSaved") message:e.localizedDescription]; return NO;
}
- (void)alert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:S2AL(@"common.ok") style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil];
}

- (void)import {
    UIDocumentPickerViewController *p = s2a_cheats_import_picker(); p.delegate = self; [self presentViewController:p animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)c; NSFileManager *fm = NSFileManager.defaultManager; NSURL *dir = cheats_dir(); NSMutableArray *bad = [NSMutableArray array];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    // 11-13 维护者「不许堵门」：原先本地解析不出条目 / 不是 UTF-8 就不让导入；现在玩家选的文件一律原样拷进来，
    //   认不认得、哪条生效以列表里的状态为准（解析不了的标「格式不认」，服务层读到再报它自己的状态）。只有拷贝真失败才报
    for (NSURL *u in urls) {
        NSString *name = u.lastPathComponent;
        if (![name.pathExtension.lowercaseString isEqual:@"txt"]) name = [name stringByAppendingPathExtension:@"txt"];
        if ([name isEqual:@"enabled.txt"] || [name isEqual:@"status.txt"]) name = [@"cheat-" stringByAppendingString:name];   // 撞我们的两份记录文件：改个名照收
        NSError *e = nil; NSData *data = [NSData dataWithContentsOfURL:u options:0 error:&e];
        if (!data || ![data writeToURL:[dir URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:&e])
            [bad addObject:[NSString stringWithFormat:S2AL(@"cheats.import.badItem"), u.lastPathComponent, e.localizedDescription ?: @""]];
    }
    [self reload];
    if (bad.count) [self alert:S2AL(@"cheats.import.failed") message:[NSString stringWithFormat:S2AL(@"cheats.import.failed.message"), [bad componentsJoinedByString:@"\n"]]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { (void)t; return 1 + (NSInteger)_files.count; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    (void)t; if (s == 0) return 0;
    S2ACheatFile *f = _files[s - 1]; return (f.bad ? 0 : (NSInteger)f.names.count) + 1;   // 末行「删除这份文件」
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    (void)t; if (s == 0) return nil;
    S2ACheatFile *f = _files[s - 1]; NSString *st = _status[[f.file stringByAppendingString:@"/*"]];
    if (f.bad) return [NSString stringWithFormat:@"%@ · %@", f.file, S2AL(@"cheats.status.badFormat")];
    for (NSString *n in f.names) if ([_status[[NSString stringWithFormat:@"%@/%@", f.file, n]] isEqual:@"版本不符"]) st = S2AL(@"cheats.status.versionMismatch.file");
    return st ? [NSString stringWithFormat:@"%@ · %@", f.file, cheat_status_text(st)] : f.file;
}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    (void)t; if (s != 0) return nil;
    const char *b = s2a_main_build_id ? s2a_main_build_id() : NULL;
    NSString *bid = b && strlen(b) >= 16 ? [@(b) substringToIndex:16].uppercaseString : nil;
    NSMutableString *m = [NSMutableString stringWithString:S2AL(@"cheats.footer")];
    if (bid) [m appendFormat:@"\n\n%@", [NSString stringWithFormat:S2AL(@"cheats.footer.buildId"), bid]];
    if (!_files.count) [m appendFormat:@"\n\n%@", S2AL(@"cheats.footer.empty")];
    return m;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    (void)t; S2ACheatFile *f = _files[ip.section - 1];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (ip.row >= (NSInteger)(f.bad ? 0 : f.names.count)) {
        cell.textLabel.text = S2AL(@"cheats.deleteFile"); cell.textLabel.textColor = UIColor.systemRedColor; return cell;
    }
    NSString *name = f.names[ip.row], *key = [NSString stringWithFormat:@"%@/%@", f.file, name];
    cell.textLabel.text = [name isEqual:@"未命名"] ? S2AL(@"cheats.unnamed") : name; cell.selectionStyle = UITableViewCellSelectionStyleNone;   // 「未命名」是与 Cheats.cs 共用的条目名标识（开关键里照原样用），只换显示
    BOOL on = [_on containsObject:key]; NSString *st = _status[key];
    cell.detailTextLabel.text = on ? (st && ![st isEqual:@"关"] ? cheat_status_text(st) : S2AL(@"cheats.status.pending")) : nil;
    cell.detailTextLabel.textColor = [st isEqual:@"生效中"] ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
    UISwitch *sw = [UISwitch new]; sw.on = on; sw.accessibilityIdentifier = key;
    [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = sw;
    return cell;
}
- (void)toggled:(UISwitch *)sw {
    NSString *key = sw.accessibilityIdentifier;
    if (sw.on) [_on addObject:key]; else [_on removeObject:key];
    if (![self writeEnabled]) { sw.on = !sw.on; if (sw.on) [_on addObject:key]; else [_on removeObject:key]; }
    [self.tableView reloadData];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    S2ACheatFile *f = _files[ip.section - 1];
    if (ip.row < (NSInteger)(f.bad ? 0 : f.names.count)) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:S2AL(@"cheats.delete.title"), f.file] message:S2AL(@"cheats.delete.message") preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:S2AL(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:S2AL(@"common.delete") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { (void)x;
        NSError *e;
        if (![NSFileManager.defaultManager removeItemAtURL:[cheats_dir() URLByAppendingPathComponent:f.file] error:&e]) { [self alert:S2AL(@"cheats.error.deleteFailed") message:e.localizedDescription]; return; }
        NSString *prefix = [f.file stringByAppendingString:@"/"];
        for (NSString *k in [_on allObjects]) if ([k hasPrefix:prefix]) [_on removeObject:k];
        [self writeEnabled]; [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

void s2a_cheats_present(UIViewController *host, void (^closed)(void)) {
    S2ACheatsPanel *p = [S2ACheatsPanel new]; p.closed = closed;
    UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:p];
    [host presentViewController:n animated:YES completion:nil];
}
