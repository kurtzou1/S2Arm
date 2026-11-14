// 社区补丁设置子页（统一设置的画面组进入；数据层 cpatch_model.m）：读包根 cpatch.tsv，按 宽屏 / 60 帧 / 画面 分组列开关。
//   「宽屏」「60 帧」两个总开关只在设置页画面组（app_settings.m：原生 60 帧置灰、已知问题提示、降档副标题都在那边），这里不再重复列（11-13 统一）；
//   帧率类社区项（编号 fps:）跟 60 帧开关走（runtime/src/cpatch.c s2a_cpatch_fps_follow），这里只显示、不单独开关。主标题中文名（cpatch_model.m 对照表），
//   副标题英文原名 + 「社区 · 我方已验 / 未经验证」。下次启动生效
#import "cpatch_settings.h"
#import "settings.h"   // s2a_ios_settings_defaults：社区补丁按游戏存（11-11）
#import "s2a_l10n.h"
NSDictionary<NSString *, NSArray<NSString *> *> *s2a_ios_cpatch_status_for(NSString *gid);   // ios/game_options.m
NSString *s2a_ios_cpatch_result(NSArray<NSString *> *st);
BOOL s2a_ios_cpatch_result_ok(NSArray<NSString *> *st);   // ios/game_options.m


@interface S2ACPatchSettings : UITableViewController
@end
@implementation S2ACPatchSettings {
    NSArray<S2ACPatchGroup *> *_groups;
}
- (instancetype)initWithGroups:(NSArray<S2ACPatchGroup *> *)groups {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _groups = groups; self.title = S2AL(@"cpatch.title");
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateMaterial) name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
    [self updateMaterial];
    UILabel *notice = [UILabel new];
    notice.text = S2AL(@"cpatch.notice"); notice.numberOfLines = 0; notice.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; notice.adjustsFontForContentSizeCategory = YES;
    notice.textColor = UIColor.secondaryLabelColor; notice.accessibilityIdentifier = @"cpatch.notice";
    UIView *header = [UIView new]; [header addSubview:notice];
    notice.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [notice.leadingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.leadingAnchor],
        [notice.trailingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.trailingAnchor],
        [notice.topAnchor constraintEqualToAnchor:header.topAnchor constant:12],
        [notice.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-4]]];
    self.tableView.tableHeaderView = header;
}
- (void)viewDidLayoutSubviews {   // 表头按文字高度定高
    [super viewDidLayoutSubviews];
    UIView *h = self.tableView.tableHeaderView;
    CGFloat height = [h systemLayoutSizeFittingSize:CGSizeMake(self.tableView.bounds.size.width, 0) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    if (fabs(h.frame.size.height - height) > 0.5) { h.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, height); self.tableView.tableHeaderView = h; }
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)updateMaterial {
    BOOL solid = UIAccessibilityIsReduceTransparencyEnabled();
    self.tableView.backgroundColor = solid ? UIColor.systemGroupedBackgroundColor : UIColor.clearColor;
    self.tableView.backgroundView = solid ? nil : [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { (void)t; return (NSInteger)_groups.count; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { (void)t; return (NSInteger)_groups[s].items.count; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { (void)t; return _groups[s].title; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    (void)t;
    if ([_groups[s].kind isEqual:@"fps"]) return S2AL(@"cpatch.footer.fps");
    return S2AL(@"cpatch.footer");
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    (void)t;
    S2ACPatchGroup *g = _groups[ip.section];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    UISwitch *sw = [UISwitch new]; cell.accessoryView = sw;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0; cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    S2ACPatchItem *it = g.items[ip.row];
    cell.textLabel.text = it.title;
    NSString *lic = it.license.length && ![it.license hasPrefix:@"none"] ? it.license : S2AL(@"cpatch.license.none");   // 出包表里「没声明」写作空或 none(未声明)
    // 缺省开 = 出包时在 graphics/cpatch/verified.tsv 里（我方验过本款这一份，pack/stage_rewrite.sh）；其余是社区未经验证、缺省关
    NSString *tag = it.defaultOn ? S2AL(@"cpatch.tag.verified") : S2AL(@"cpatch.tag.unverified");
    cell.detailTextLabel.text = [NSString stringWithFormat:S2AL(@"cpatch.item.detail"), it.name, tag, lic, it.followsFps60 ? S2AL(@"cpatch.item.followsFps") : it.followsFullscreen ? S2AL(@"cpatch.item.followsFullscreen") : @""];
    NSArray<NSString *> *st = s2a_ios_cpatch_status_for(nil)[it.ident];
    NSString *res = s2a_ios_cpatch_result(st);   // 这一局装载时的实际结果（runtime/src/cpatch.c）：没生效写原因、量到效果写实测；生效了写绿色（11-13 ç»´æ¤è）
    if (res) {
        NSMutableAttributedString *d = [[NSMutableAttributedString alloc] initWithString:[cell.detailTextLabel.text stringByAppendingString:@"\n"]
                                                                               attributes:@{NSForegroundColorAttributeName: UIColor.secondaryLabelColor}];
        [d appendAttributedString:[[NSAttributedString alloc] initWithString:res attributes:@{NSForegroundColorAttributeName: s2a_ios_cpatch_result_ok(st) ? UIColor.systemGreenColor : UIColor.secondaryLabelColor}]];
        cell.detailTextLabel.attributedText = d;
    }
    sw.accessibilityLabel = it.title; sw.accessibilityIdentifier = [@"cpatch.item." stringByAppendingString:it.ident];
    // 跟随设置页「60 帧」/「满屏」开关的项（11-13 ç»´æ¤è「排版乱」：原来画成按不动的灰开关）：右边不放开关，写现在是开还是关
    if (it.followsFps60 || it.followsFullscreen) {
        BOOL on = it.followsFps60; if (on) on = s2a_ios_fps60_on(); else s2a_ios_fullscreen_state(nil, &on);
        UILabel *state = [UILabel new]; state.text = on ? S2AL(@"cpatch.state.on") : S2AL(@"cpatch.state.off");
        state.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; state.adjustsFontForContentSizeCategory = YES;
        state.textColor = on ? UIColor.systemGreenColor : UIColor.secondaryLabelColor; [state sizeToFit];
        state.accessibilityIdentifier = [@"cpatch.item." stringByAppendingString:it.ident];
        cell.accessoryView = state;
    }
    else {
        sw.on = [S2ACPatchEnabled(_groups, s2a_ios_settings_defaults()) containsObject:it.ident];
        [sw addTarget:self action:@selector(itemChanged:) forControlEvents:UIControlEventValueChanged];
    }
    return cell;
}
- (void)itemChanged:(UISwitch *)sw {
    NSString *ident = [sw.accessibilityIdentifier substringFromIndex:@"cpatch.item.".length];
    S2ACPatchSetEnabled(_groups, s2a_ios_settings_defaults(), ident, sw.on);
}
@end

// 包根没有 cpatch.tsv 或表里没有项时，统一设置不显示此入口。
NSArray<S2ACPatchGroup *> *s2a_cpatch_bundled_groups(void) {
    NSString *path = [NSBundle.mainBundle pathForResource:@"cpatch" ofType:@"tsv"];
    NSString *text = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    return text ? S2ACPatchGroupsFromTSV(text) : @[];
}
UIViewController *s2a_cpatch_settings_controller(NSArray<S2ACPatchGroup *> *groups) {
    return groups.count ? [[S2ACPatchSettings alloc] initWithGroups:groups] : nil;
}
