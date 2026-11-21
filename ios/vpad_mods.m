// 资源替换类 mod 页（见 vpad_mods.h）。电脑端导入的 mod 装机时推到同一个目录（pack/jobs/install.py push_mods），这里一并列出、能删。
//   导入只收文件夹：iOS 没有系统的解 zip 接口，zip 请先在「文件」App 里点一下解压（说明写在页脚）。
//   认法同 pack/jobs/mods.py：选的就是 romfs → 一份；否则往下找名为 romfs 的文件夹（大小写都认、不进 romfs 里面再找），
//   路径上出现别的 16 位程序号 = 给别的游戏的，不收；找到几个就存几份（同名整份替换）
#import "vpad_mods.h"
#import "picker_present.h"   // 选文件界面弹出 + 日志（#1939）
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "s2a_docs.h"
#import "s2a_l10n.h"

static NSURL *mods_dir(void) { char d[1024]; s2a_docs_path(d, sizeof d, "mods"); return [NSURL fileURLWithPath:@(d) isDirectory:YES]; }
static const char *current_gid(void) { const char *g = getenv("S2A_LAUNCH_GAME_ID"); return g ? g : ""; }   // 同 game_options.m：起局上下文给的本款程序号；单款壳没有 = 不按程序号筛

// 关掉的 mod：文件夹改名为 .off-<名字>（同电脑端 pack/jobs/mods.py OFF）；RomFsMods.cs 跳过 . 开头的文件夹 = 起局不叠，打开改回原名
static NSString *const kOff = @".off-";
static NSString *mod_name(NSURL *u) { NSString *n = u.lastPathComponent; return [n hasPrefix:kOff] ? [n substringFromIndex:kOff.length] : n; }
static BOOL mod_on(NSURL *u) { return ![u.lastPathComponent hasPrefix:kOff]; }
static NSArray<NSURL *> *mod_folders(void) {
    NSArray<NSURL *> *all = [NSFileManager.defaultManager contentsOfDirectoryAtURL:mods_dir() includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:nil] ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSURL *u in all) {
        NSNumber *dir = nil; [u getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
        if (dir.boolValue && (![u.lastPathComponent hasPrefix:@"."] || [u.lastPathComponent hasPrefix:kOff])) [out addObject:u];   // 别的 . 开头是导入中的临时目录
    }
    return [out sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [mod_name(a) compare:mod_name(b)]; }];   // 叠加顺序 = 名字升序（RomFsMods.cs）
}
NSInteger s2a_mods_count(void) { return (NSInteger)mod_folders().count; }

static void mod_stats(NSURL *mod, long *files, long long *bytes) {
    *files = 0; *bytes = 0;
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:[mod URLByAppendingPathComponent:@"romfs"] includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey] options:0 errorHandler:nil];
    for (NSURL *f in e) { NSNumber *reg = nil, *size = nil; [f getResourceValue:&reg forKey:NSURLIsRegularFileKey error:nil];
        if (reg.boolValue) { [f getResourceValue:&size forKey:NSURLFileSizeKey error:nil]; (*files)++; *bytes += size.longLongValue; } }
}

static BOOL is_gid(NSString *s) {
    if (s.length != 16) return NO;
    for (NSUInteger i = 0; i < 16; i++) if (!isxdigit([s characterAtIndex:i])) return NO;
    return YES;
}
static NSString *safe_name(NSString *s) {
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    NSString *t = [[[s componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ."]];
    return t.length ? (t.length > 80 ? [t substringToIndex:80] : t) : @"mod";
}

// 选的文件夹里找 romfs：→ @[@[名字, romfs URL]]；notes 收「给别的游戏的」说明
static NSArray *find_romfs(NSURL *root, NSMutableArray<NSString *> *notes) {
    NSString *base = [root.lastPathComponent caseInsensitiveCompare:@"romfs"] == NSOrderedSame ? root.URLByDeletingLastPathComponent.lastPathComponent : root.lastPathComponent;
    if ([root.lastPathComponent caseInsensitiveCompare:@"romfs"] == NSOrderedSame) return @[@[safe_name(base), root]];
    NSMutableArray *found = [NSMutableArray array];
    NSString *gid = @(current_gid()).uppercaseString;
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey] options:0 errorHandler:nil];
    for (NSURL *d in e) {
        NSNumber *dir = nil, *link = nil; [d getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil]; [d getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
        if (!dir.boolValue || link.boolValue || [d.lastPathComponent caseInsensitiveCompare:@"romfs"] != NSOrderedSame) continue;
        [e skipDescendants];   // 不进 romfs 里面再找
        NSArray<NSString *> *rel = [d.path substringFromIndex:MIN(root.path.length + 1, d.path.length)].pathComponents;
        rel = [rel subarrayWithRange:NSMakeRange(0, rel.count ? rel.count - 1 : 0)];
        NSMutableArray *label = [NSMutableArray array]; NSString *other = nil; BOOL mine = NO;
        for (NSString *p in rel) {
            if (is_gid(p)) { if ([p.uppercaseString isEqualToString:gid]) mine = YES; else other = p.uppercaseString; continue; }
            NSString *low = p.lowercaseString; if (![@[@"atmosphere", @"contents", @"mods"] containsObject:low]) [label addObject:p];
        }
        if (other && !mine && gid.length) { [notes addObject:[NSString stringWithFormat:S2AL(@"mods.import.otherGame"), [rel componentsJoinedByString:@"/"], other]]; continue; }
        NSArray *tail = label.count > 2 ? [label subarrayWithRange:NSMakeRange(label.count - 2, 2)] : label;
        [found addObject:@[tail.count ? [tail componentsJoinedByString:@" - "] : @"", d]];
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *f in found) [out addObject:@[safe_name(found.count == 1 || [f[0] length] == 0 ? base : [NSString stringWithFormat:@"%@ - %@", base, f[0]]), f[1]]];
    return out;
}

@interface S2AModsPanel : UITableViewController <UIDocumentPickerDelegate>
@end

@implementation S2AModsPanel {
    NSArray<NSURL *> *_mods;
    NSString *_said;   // 刚导入的结果（页脚第一段）
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = S2AL(@"mods.title");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:S2AL(@"mods.import") style:UIBarButtonItemStylePlain target:self action:@selector(import)];
    self.navigationItem.rightBarButtonItem.accessibilityIdentifier = @"mods.import";
    [self reload];
}
- (void)reload { _mods = mod_folders(); [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return MAX((NSInteger)_mods.count, 1); }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return _said.length ? [NSString stringWithFormat:@"%@\n\n%@", _said, S2AL(@"mods.footer")] : S2AL(@"mods.footer");
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (!_mods.count) { cell.textLabel.text = S2AL(@"mods.empty"); cell.textLabel.textColor = UIColor.secondaryLabelColor; return cell; }
    NSURL *m = _mods[ip.row]; long files; long long bytes; mod_stats(m, &files, &bytes);
    cell.textLabel.text = mod_name(m);
    UISwitch *sw = [UISwitch new]; sw.on = mod_on(m); sw.accessibilityIdentifier = [@"mods.toggle." stringByAppendingString:mod_name(m)];
    sw.tag = ip.row; [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = sw;
    cell.detailTextLabel.text = [NSString stringWithFormat:S2AL(@"mods.files"), files, [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile]];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessibilityIdentifier = [@"mods.item." stringByAppendingString:mod_name(m)];
    return cell;
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (!_mods.count) return nil;
    NSURL *m = _mods[ip.row];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:S2AL(@"mods.delete") handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        (void)a; (void)v; NSError *err = nil; BOOL ok = [NSFileManager.defaultManager removeItemAtURL:m error:&err];
        if (!ok) NSLog(@"【红】mod：删 %@ 失败 %@", mod_name(m), err.localizedDescription);
        [self reload]; done(ok);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}
- (void)toggled:(UISwitch *)sw {
    if (sw.tag < 0 || sw.tag >= (NSInteger)_mods.count) return;
    NSURL *m = _mods[sw.tag], *to = [mods_dir() URLByAppendingPathComponent:sw.on ? mod_name(m) : [kOff stringByAppendingString:mod_name(m)] isDirectory:YES];
    NSError *err = nil;
    if (![NSFileManager.defaultManager moveItemAtURL:m toURL:to error:&err]) NSLog(@"【红】mod：%@ %@ 失败 %@", mod_name(m), sw.on ? @"打开" : @"关掉", err.localizedDescription);
    [self reload];
}
- (void)import {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    p.delegate = self; p.allowsMultipleSelection = YES;
    s2a_present_picker(self, p, "mods-import");
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSFileManager *fm = NSFileManager.defaultManager; NSMutableArray<NSString *> *notes = [NSMutableArray array], *done = [NSMutableArray array];
    [fm createDirectoryAtURL:mods_dir() withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSURL *src in urls) {
        BOOL scoped = [src startAccessingSecurityScopedResource];
        NSArray *found = find_romfs(src, notes);
        if (!found.count) [notes addObject:[NSString stringWithFormat:S2AL(@"mods.import.none"), src.lastPathComponent]];
        for (NSArray *f in found) {
            NSURL *dst = [mods_dir() URLByAppendingPathComponent:f[0] isDirectory:YES], *tmp = [mods_dir() URLByAppendingPathComponent:[@".importing-" stringByAppendingString:f[0]] isDirectory:YES];
            [fm removeItemAtURL:tmp error:nil]; NSError *err = nil;
            if (![fm createDirectoryAtURL:tmp withIntermediateDirectories:YES attributes:nil error:&err] || ![fm copyItemAtURL:f[1] toURL:[tmp URLByAppendingPathComponent:@"romfs"] error:&err]) {
                [notes addObject:[NSString stringWithFormat:S2AL(@"mods.import.failed"), f[0], err.localizedDescription ?: @""]]; [fm removeItemAtURL:tmp error:nil]; continue;
            }
            [fm removeItemAtURL:dst error:nil];   // 同名整份替换，不叠旧文件；关着的同名那份也换掉（新导入的是开着的）
            [fm removeItemAtURL:[mods_dir() URLByAppendingPathComponent:[kOff stringByAppendingString:f[0]] isDirectory:YES] error:nil];
            if (![fm moveItemAtURL:tmp toURL:dst error:&err]) { [notes addObject:[NSString stringWithFormat:S2AL(@"mods.import.failed"), f[0], err.localizedDescription ?: @""]]; continue; }
            [done addObject:f[0]];
        }
        if (scoped) [src stopAccessingSecurityScopedResource];
    }
    NSMutableArray *lines = [NSMutableArray array];
    if (done.count) [lines addObject:[NSString stringWithFormat:S2AL(@"mods.import.done"), [done componentsJoinedByString:@" · "]]];
    [lines addObjectsFromArray:notes];
    _said = [lines componentsJoinedByString:@"\n"];
    NSLog(@"mod 导入：%@", _said);
    [self reload];
}
@end

UIViewController *s2a_mods_controller(void) { S2AModsPanel *p = [[S2AModsPanel alloc] initWithStyle:UITableViewStyleInsetGrouped]; [p loadViewIfNeeded]; return p; }
