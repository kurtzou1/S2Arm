#import "sgrade_style.h"
#import "vpad_cheats.h"
void s2a_ios_sgrade_counts(NSString *gid, NSInteger *cheatOn, NSInteger *cheatAll, NSInteger *patchOn, NSInteger *patchAll);   // ios/game_options.m
#import "app_settings.h"
#import "s2a_l10n.h"
#import "settings.h"
#import "play_layout.h"
// 弱链接[lab]：s2a_fps_cap_reason（runtime/src/fps.c：60 帧降档原因 0 无 / 1 热 / 2 低电量 / 3 A/B 测原帧率段；输入工作台不链原生核，取不到就不写降档副标题）
int s2a_fps_cap_reason(void) __attribute__((weak_import));
#import "vpad.h"
#import "vpad_settings.h"
#import "cpatch_settings.h"
#include "native.h"   // LOG
#include "s2a_pad.h"   // 手柄按键排布（自动 / Switch / Xbox）的取值解析，同齿轮菜单
// 弱链接[lab]：s2a_cpatch_fps_pick（runtime/src/cpatch.c：局中切帧率档，下一帧生效；输入工作台不链原生核，取不到就只记、下次进游戏生效）
void s2a_cpatch_fps_pick(int target) __attribute__((weak_import));
// 弱链接[lab]：s2a_pad_layout_parse（runtime/src/pad.c；输入工作台不链原生核，取不到就按存的字面值认）
int s2a_pad_layout_parse(const char *value) __attribute__((weak_import));
// 弱链接[lab]：s2a_hud_brief_show（ios/hud.m 简版性能浮层；输入工作台不链 hud.m，取不到就只记开关、下次进游戏生效）
void s2a_hud_brief_show(UIView *root, BOOL on) __attribute__((weak_import));
// 弱链接[lab]：s2a_ios_root_view（ios/app.m 游戏画面根视图，性能浮层挂在它上面；输入工作台没有 app.m，取不到就只记开关）
UIView *s2a_ios_root_view(void) __attribute__((weak_import));
#include "s2a_direct_prompt.h"   // 「切换游戏」文案（与 launchers/shared/experience.v1.json prompts 逐字一致；按 App 语言只显示一种，S2APICK）
#include <math.h>

void s2a_diag_report(void);
// 弱链接[lab]：s2a_console_mode_set（runtime/src/os.c 接口 v2.15 提供；输入工作台不链原生核，取不到就不切）
void s2a_console_mode_set(int docked) __attribute__((weak_import));
BOOL s2a_diag_is_exporting(void);
BOOL s2a_diag_is_uploading(void);   // diag.m：正在传（这一行改成「正在上传…点按取消」）
void s2a_diag_cancel_upload(void);
@implementation S2ASettingsRuntime
@end
static S2ASettingsRuntime *g_runtime;
void s2a_settings_set_runtime(S2ASettingsRuntime *runtime) { g_runtime = runtime; }
S2ASettingsRuntime *s2a_settings_runtime(void) { return g_runtime; }

@interface S2ASteppedSlider : UISlider
@end
@implementation S2ASteppedSlider
- (void)accessibilityIncrement { self.value = MIN(self.maximumValue, roundf(self.value) + 1); [self sendActionsForControlEvents:UIControlEventValueChanged]; }
- (void)accessibilityDecrement { self.value = MAX(self.minimumValue, roundf(self.value) - 1); [self sendActionsForControlEvents:UIControlEventValueChanged]; }
@end

@class S2ASettingsController;
@interface S2ASettingsPane : UITableViewController
@property(nonatomic, weak) S2ASettingsController *owner;
@property(nonatomic, copy) NSArray<NSNumber *> *groups;
@end
@interface S2ASettingsController : UIViewController
- (UITableViewCell *)cellForGroup:(NSInteger)group row:(NSInteger)row;
- (void)selectGroup:(NSInteger)group row:(NSInteger)row;
- (void)refresh;
- (NSInteger)rowsForGroup:(NSInteger)group;
@end

static NSArray *toggleKeys(void) {
    return @[@"S2ANS2ProAdapterEnabled", @"S2APhoneGyro", @"S2APhoneHaptics", @"S2ADiagExportOnOpen", @"S2ADevHUD", @"MetalHUDForceEnabled", @"S2AWidescreen", @"S2AFps60", @"S2A.touchHud", @"S2ADockedMode", @"S2ADiagRunNext", @"S2APerfHUD"];
}
static NSArray *toggleTitles(void) {
    return @[S2AL(@"vpad.menu.ns2pro"), S2AL(@"vpad.menu.gyro"), S2AL(@"settings.toggle.phoneHaptics"), S2AL(@"settings.toggle.diagOnOpen"), S2AL(@"settings.toggle.devHud"), S2AL(@"settings.toggle.metalHud"), S2AL(@"settings.toggle.fullscreen"), S2AL(@"cpatch.group.fps"), S2AL(@"settings.toggle.touchHud"), S2AL(@"settings.toggle.docked"), S2AL(@"settings.toggle.diagRun"), S2AL(@"vpad.menu.hud")];
}
static UILabel *textLabel(UIFontTextStyle style) {
    UILabel *label = [UILabel new]; label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES; label.numberOfLines = 0; return label;
}

@implementation S2ASettingsPane
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 60;
    self.tableView.sectionHeaderHeight = UITableViewAutomaticDimension;
    self.tableView.sectionFooterHeight = UITableViewAutomaticDimension;
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.groups.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.owner rowsForGroup:self.groups[section].integerValue];
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSInteger g = self.groups[section].integerValue;
    if (g == 8) return nil;   // S 级优化：金色头（viewForHeaderInSection）
    if (g == 6) return S2AL(@"play.group");
    if (g == 7) return S2AL(@"settings.group.language");
    return g == 2 ? nil : S2AL(@"cpatch.group.gfx");   // 2：开发者页，标题在导航栏
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (self.groups[section].integerValue) {
        case 8: return nil;   // S 级优化
        case 6: return S2AL(@"play.footer");
        case 7: {   // 选的（跟随系统 = 系统语言）这款不支持：说明里写明起局实际用哪种（11-14 维护者：标出来、不弹窗；规则同宿主 SystemLocale.TitleFallback）
            NSString *note = s2a_ios_game_language_note();
            return note ? [NSString stringWithFormat:@"%@\n%@", note, S2AL(@"settings.footer.language")] : S2AL(@"settings.footer.language");
        }
        case 0: return S2AL(@"settings.footer.graphics");
        default: return S2AL(@"settings.footer.dev");   // 2：开发者页
    }
}
// S 级优化（社区补丁 + 金手指，11-13 统一入口）：金色分组头，同启动器与游戏库设置一套样式（sgrade_style.m）
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return self.groups[section].integerValue == 8 ? s2a_sgrade_header(tableView.bounds.size.width) : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    return [self.owner cellForGroup:self.groups[path.section].integerValue row:path.row];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; [self.owner selectGroup:self.groups[path.section].integerValue row:path.row];
}
@end

@implementation S2ASettingsController {
    NSDictionary *_entryGraphics;
    NSArray<S2ACPatchGroup *> *_patchGroups;
    NSSet<NSString *> *_entryPatches;
    S2ASettingsRuntime *_runtime;
    UIVisualEffectView *_material;
    UIStackView *_columns;
    S2ASettingsPane *_left, *_right;
    BOOL _restarting;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _runtime = g_runtime;
    _entryGraphics = s2a_ios_graphics_snapshot(s2a_ios_settings_defaults());
    _patchGroups = s2a_cpatch_bundled_groups();
    _entryPatches = S2ACPatchEnabled(_patchGroups, s2a_ios_settings_defaults());
    self.title = S2AL(@"common.settings"); return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    _material = [[UIVisualEffectView alloc] initWithEffect:nil]; _material.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_material];
    [NSLayoutConstraint activateConstraints:@[
        [_material.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [_material.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_material.topAnchor constraintEqualToAnchor:self.view.topAnchor], [_material.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
    _left = [S2ASettingsPane new]; _right = [S2ASettingsPane new]; _left.owner = _right.owner = self;
    for (S2ASettingsPane *pane in @[_left, _right]) { [self addChildViewController:pane]; [pane didMoveToParentViewController:self]; }
    _columns = [[UIStackView alloc] initWithArrangedSubviews:@[_left.view, _right.view]];
    _columns.axis = UILayoutConstraintAxisHorizontal; _columns.distribution = UIStackViewDistributionFillEqually;
    _columns.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:_columns];
    // 11-14 重做（维护者「太丑、好多功能冗余」）：单栏，最宽 620 居中，横屏也不拆两栏；右栏只当「开发者」页用（见 openDeveloper）
    _right.view.hidden = YES;
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *fill = [_columns.widthAnchor constraintEqualToAnchor:safe.widthAnchor]; fill.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [_columns.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor], [_columns.widthAnchor constraintLessThanOrEqualToConstant:620], fill,
        [_columns.topAnchor constraintEqualToAnchor:safe.topAnchor], [_columns.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]]];
    // 标题长按 1.5 秒进「开发者」页（诊断局、触屏诊断、打开时导出、两个开发浮层：玩家用不到，不放在主页面）
    UILabel *titleLabel = [UILabel new]; titleLabel.text = self.title; titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    titleLabel.userInteractionEnabled = YES; titleLabel.accessibilityIdentifier = @"settings.title";
    UILongPressGestureRecognizer *dev = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(developerPress:)]; dev.minimumPressDuration = 1.5;
    [titleLabel addGestureRecognizer:dev]; self.navigationItem.titleView = titleLabel;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:S2AL(@"common.done") style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.rightBarButtonItem.accessibilityIdentifier = @"settings.done";
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:NSUserDefaultsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:@"S2ADiagExportChanged" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateMaterial) name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateColumns) name:UIContentSizeCategoryDidChangeNotification object:nil];
    [self updateMaterial]; [self updateColumns];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refresh]; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [self updateColumns]; }
- (void)updateMaterial {
    BOOL solid = UIAccessibilityIsReduceTransparencyEnabled();
    _material.effect = solid ? nil : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    _material.backgroundColor = solid ? UIColor.systemGroupedBackgroundColor : UIColor.clearColor;
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    if (solid) { [appearance configureWithOpaqueBackground]; appearance.backgroundColor = UIColor.systemGroupedBackgroundColor; }
    else { [appearance configureWithTransparentBackground]; appearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]; }
    self.navigationController.navigationBar.standardAppearance = appearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
    self.navigationController.navigationBar.compactAppearance = appearance;
    [self refresh];
}
- (void)updateColumns {
    // 11-14 重做：设置页只放低频、改了要重启的——屏幕（6）/ 画面（0）/ S 级优化（8）/ 语言（7）。
    //   局内随手调、当场生效的（布局、摇杆、震动、手柄与体感、性能浮层、存档、切换游戏、故障报修）都在齿轮菜单（vpad.m），这里不再重复一份；
    //   开发项（组 2）在标题长按进的「开发者」页
    NSArray *groups = @[@6, @0, @8, @7];
    if (![_left.groups isEqual:groups]) {
        _left.groups = groups; _right.groups = @[@2];
        // 转屏切换分组后必须直接失效旧行；refresh 先取 visibleCells 会让 UITableView 用旧 section 查询新数组，越界退出。
        [_left.tableView reloadData]; [_right.tableView reloadData];
    }
}
- (void)developerPress:(UILongPressGestureRecognizer *)press { if (press.state == UIGestureRecognizerStateBegan) [self openDeveloper]; }
- (void)openDeveloper {
    if (self.navigationController.topViewController != self) { LOG("设置页：开发者页没开（最上层不是设置页）"); return; }
    LOG("设置页：打开开发者页");
    // 和主页面同一种底：系统材质铺满，表格最宽 620 居中、放在安全区里（不铺到导航栏下面）
    S2ASettingsPane *pane = [S2ASettingsPane new]; pane.owner = self; pane.groups = @[@2];
    UIViewController *page = [UIViewController new]; page.title = S2AL(@"settings.group.dev");
    UIVisualEffectView *material = [[UIVisualEffectView alloc] initWithEffect:UIAccessibilityIsReduceTransparencyEnabled() ? nil : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    material.backgroundColor = UIAccessibilityIsReduceTransparencyEnabled() ? UIColor.systemGroupedBackgroundColor : UIColor.clearColor;
    material.frame = page.view.bounds; material.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [page.view addSubview:material];
    [page addChildViewController:pane]; pane.view.translatesAutoresizingMaskIntoConstraints = NO; [page.view addSubview:pane.view]; [pane didMoveToParentViewController:page];
    UILayoutGuide *safe = page.view.safeAreaLayoutGuide;
    NSLayoutConstraint *fill = [pane.view.widthAnchor constraintEqualToAnchor:safe.widthAnchor]; fill.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[[pane.view.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor], [pane.view.widthAnchor constraintLessThanOrEqualToConstant:620], fill,
        [pane.view.topAnchor constraintEqualToAnchor:safe.topAnchor], [pane.view.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]]];
    // 「完成」另建一个（同一个按钮对象挂在两页的导航条上，返回键会被挤到右边）
    page.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:S2AL(@"common.done") style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    [self.navigationController pushViewController:page animated:YES];
}
// 测试开关（真机自动化长按不了标题；同 diag.m S2A_OPEN_SETTINGS，环境变量只有 devicectl / Xcode 起 App 能给，玩家碰不到）：S2A_SETTINGS_DEV=1 一打开就进「开发者」页
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    static BOOL once; const char *e = getenv("S2A_SETTINGS_DEV");
    if (e) LOG("设置页：测试开关 S2A_SETTINGS_DEV=%s（once=%d）", e, once);
    if (!once && e && !strcmp(e, "1")) { once = YES; [self openDeveloper]; }
    // 同理 S2A_SETTINGS_SCROLL=language：一打开就把「语言」组滚到顶（截图核游戏语言那一行和说明）
    const char *sc = getenv("S2A_SETTINGS_SCROLL"); NSUInteger sec = [_left.groups indexOfObject:@7];
    if (sc && !strcmp(sc, "language") && sec != NSNotFound) {
        LOG("设置页：测试开关 S2A_SETTINGS_SCROLL=language");
        [_left.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:sec] atScrollPosition:UITableViewScrollPositionTop animated:NO];
    }
}
- (void)refresh {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; }); return; }
    self.navigationItem.rightBarButtonItem.enabled = !_restarting && !s2a_diag_is_exporting();
    // Do not replace a UISlider while it is tracking a finger.
    for (UITableViewCell *cell in _left.tableView.visibleCells) {
        if ([cell.contentView viewWithTag:100] && [(UISlider *)[cell.contentView viewWithTag:100] isTracking]) return;
    }
    [_left.tableView reloadData]; [_right.tableView reloadData];
    for (UIViewController *child in self.navigationController.topViewController.childViewControllers)   // 开发者页开着时一起刷
        if (child != _left && child != _right && [child isKindOfClass:S2ASettingsPane.class]) [((S2ASettingsPane *)child).tableView reloadData];
}
- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:S2AL(@"settings.error.title") message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"settings.error.back") style:UIAlertActionStyleCancel handler:nil]];
    [self.navigationController.topViewController presentViewController:alert animated:YES completion:nil];
}
- (UITableViewCell *)baseCell:(NSString *)title {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = title; cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.numberOfLines = 0;
    cell.backgroundColor = [UIColor.secondarySystemGroupedBackgroundColor colorWithAlphaComponent:UIAccessibilityIsReduceTransparencyEnabled() ? 1 : 0.75];
    return cell;
}
- (UITableViewCell *)dropdown:(NSString *)title labels:(NSArray *)labels selected:(NSInteger)selected enabled:(BOOL (^)(NSInteger))enabled choose:(void (^)(NSInteger))choose identifier:(NSString *)identifier {
    UITableViewCell *cell = [self baseCell:title]; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIButtonConfiguration *config = UIButtonConfiguration.plainButtonConfiguration;
    config.title = selected >= 0 ? labels[selected] : S2AL(@"settings.notStarted");
    config.image = [UIImage systemImageNamed:@"chevron.down"]; config.imagePlacement = NSDirectionalRectEdgeTrailing; config.imagePadding = 6;
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    button.accessibilityLabel = title; button.accessibilityValue = config.title; button.accessibilityIdentifier = identifier;
    NSMutableArray *actions = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)labels.count; i++) {
        UIAction *action = [UIAction actionWithTitle:labels[i] image:nil identifier:nil handler:^(UIAction *action) { choose(i); }];
        action.state = i == selected ? UIMenuElementStateOn : UIMenuElementStateOff;
        if (!enabled(i)) action.attributes = UIMenuElementAttributesDisabled;
        [actions addObject:action];
    }
    button.menu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:actions];
    button.showsMenuAsPrimaryAction = YES; button.enabled = selected >= 0;
    [button sizeToFit]; CGRect frame = button.frame; frame.size.height = MAX(44, frame.size.height); button.frame = frame;
    cell.accessoryView = button; return cell;
}
- (UITableViewCell *)sliderCell:(NSDictionary *)option {
    UITableViewCell *cell = [self baseCell:@""]; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSArray *values = option[@"values"], *labels = option[@"labels"];
    NSInteger selected = [values indexOfObject:s2a_ios_graphics_snapshot(s2a_ios_settings_defaults())[option[@"key"]]];
    UILabel *title = textLabel(UIFontTextStyleBody); title.text = option[@"title"];
    UILabel *value = textLabel(UIFontTextStyleBody); value.text = labels[selected]; value.textColor = self.view.tintColor;
    [value setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *heading = [[UIStackView alloc] initWithArrangedSubviews:@[title, value]]; heading.spacing = 12;
    S2ASteppedSlider *slider = [S2ASteppedSlider new]; slider.tag = 100;
    slider.minimumValue = 0; slider.maximumValue = values.count - 1; slider.value = selected;
    slider.accessibilityLabel = option[@"title"]; slider.accessibilityValue = labels[selected];
    slider.accessibilityIdentifier = [@"settings." stringByAppendingString:option[@"key"]];
    [slider addAction:[UIAction actionWithHandler:^(UIAction *action) {
        UISlider *control = (UISlider *)action.sender; NSInteger index = lroundf(control.value); control.value = index;
        value.text = labels[index]; control.accessibilityValue = labels[index];
        [s2a_ios_settings_defaults() setObject:values[index] forKey:option[@"key"]];
    }] forControlEvents:UIControlEventValueChanged];
    [slider.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    UIStackView *ticks = [UIStackView new]; ticks.distribution = UIStackViewDistributionEqualSpacing;
    for (NSString *label in labels) { UILabel *tick = textLabel(UIFontTextStyleCaption2); tick.text = label; tick.textColor = UIColor.secondaryLabelColor; tick.isAccessibilityElement = NO; [ticks addArrangedSubview:tick]; }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[heading, slider, ticks]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 2; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:stack]; UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor], [stack.trailingAnchor constraintEqualToAnchor:m.trailingAnchor], [stack.topAnchor constraintEqualToAnchor:m.topAnchor], [stack.bottomAnchor constraintEqualToAnchor:m.bottomAnchor]]];
    return cell;
}
- (UITableViewCell *)toggleCell:(NSInteger)index {
    NSString *key = toggleKeys()[index]; UITableViewCell *cell = [self baseCell:toggleTitles()[index]];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *control = [UISwitch new]; id saved = [s2a_ios_settings_defaults() objectForKey:key];
    control.on = [key isEqualToString:@"S2AFps60"] ? s2a_ios_fps60_on() : saved ? [saved boolValue] : (index == 1 || index == 2 || index == 6);   // 60 帧显示实际生效的（没选过的缺省按清单，不一律显示开）
    control.accessibilityLabel = toggleTitles()[index]; control.accessibilityIdentifier = [@"settings." stringByAppendingString:key];
    // 主机模式（#352，维护者 11-09：手机缺省掌机，玩家可自己开）：标题下一行写明代价——更耗电换画质，手机上不建议开
    // 诊断局（#438）同样在标题下写一行：怎么用、只管下一局、会变慢
    if ([key isEqualToString:@"S2ADockedMode"] || [key isEqualToString:@"S2ADiagRunNext"]) {
        UITableViewCell *sub = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        sub.textLabel.text = cell.textLabel.text; sub.textLabel.font = cell.textLabel.font; sub.textLabel.adjustsFontForContentSizeCategory = YES; sub.textLabel.numberOfLines = 0;
        sub.detailTextLabel.text = [key isEqualToString:@"S2ADiagRunNext"] ? S2AL(@"settings.diagRun.note") : S2AL(@"settings.docked.note"); sub.detailTextLabel.numberOfLines = 0; sub.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        sub.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; sub.detailTextLabel.adjustsFontForContentSizeCategory = YES;
        sub.selectionStyle = UITableViewCellSelectionStyleNone; cell = sub;
    }
    // 补丁优先（11-13 维护者：有 120 帧补丁就盖过我们的 60 帧、有 60 帧补丁就盖过我们自己的 60 帧，满屏同理）：这款带了帧率 / 满屏补丁，
    //   这一行改由补丁接管——帧率行改名「帧率」、写补丁目标「最高 n 帧」，满屏行写「社区满屏补丁接管」，开关照旧（开 = 用补丁）
    {
        NSString *pTitle = nil, *pNote = nil; NSInteger target = 0; BOOL fpsP = NO, wsP = NO;
        for (S2ACPatchGroup *g in _patchGroups) for (S2ACPatchItem *it in g.items) {
            if (it.followsFps60) { fpsP = YES; target = MAX(target, it.targetFps); }
            if ([g.kind isEqual:@"widescreen"]) wsP = YES;
        }
        if ([key isEqualToString:@"S2AFps60"] && fpsP) {
            pTitle = S2AL(@"settings.fps.patchTitle");
            pNote = target > 0 ? [NSString stringWithFormat:S2AL(@"settings.fps.patchNote"), (long)target] : S2AL(@"settings.patchNote");
        } else if ([key isEqualToString:@"S2AWidescreen"] && wsP) pNote = S2AL(@"settings.fullscreen.patchNote");
        if (pNote) {
            UITableViewCell *sub = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
            sub.textLabel.text = pTitle ?: cell.textLabel.text; sub.textLabel.font = cell.textLabel.font; sub.textLabel.adjustsFontForContentSizeCategory = YES;
            sub.detailTextLabel.text = pNote; sub.detailTextLabel.textColor = s2a_sgrade_gold(); sub.detailTextLabel.numberOfLines = 0;
            sub.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; sub.detailTextLabel.adjustsFontForContentSizeCategory = YES;
            sub.selectionStyle = UITableViewCellSelectionStyleNone; control.accessibilityLabel = sub.textLabel.text; cell = sub;
        }
    }
    // 本款原生 60 帧（运行时判定后记在 S2AFpsNative60，app.m s2a_ios_fps_native60）：开关改不动帧率，显示原因、置灰（11-02 维护者 丝之歌关了照样 60 帧、以为没生效）
    if ([key isEqualToString:@"S2AFps60"] && [s2a_ios_settings_defaults() boolForKey:@"S2AFpsNative60"]) {
        control.on = YES; control.enabled = NO; cell.detailTextLabel.text = S2AL(@"settings.fps.native"); control.accessibilityValue = S2AL(@"settings.fps.native");
        cell.accessoryView = control; return cell; }
    // 包里 60 帧是关的（强信号：逻辑速度红 / 崩溃 / 卡死 / 帧率达不到；11-02 起全引擎默认开，只有强信号才关）：开关显示玩家手动开没开（S2AFps60Manual，缺省关、不跟 S2AFps60 的缺省开），打开时先提示（11-02 维护者 / 维护者 定的文案）；下次启动生效（settings.m）
    // 包里满屏是关的（强信号：满屏画面坏 / 崩溃归因，tools/caps_policy.py）：设置开关改不动，如实显示关、置灰、写原因（不再缺省显示开、按了没用）
    // 满屏（自适应，settings.m s2a_ios_fullscreen_state：与游戏库长按设置同一口径、同一份存储）：显示此刻实际生效的；包内清单判满屏坏 = 置灰写原因
    if ([key isEqualToString:@"S2AWidescreen"]) {
        BOOL fs = NO;
        if (s2a_ios_fullscreen_state(nil, &fs)) {
            control.on = NO; control.enabled = NO; cell.detailTextLabel.text = S2AL(@"settings.widen.blocked"); control.accessibilityValue = cell.detailTextLabel.text;
            cell.accessoryView = control; return cell; }
        control.on = fs;
    }
    if ([key isEqualToString:@"S2AFps60"] && s2a_ios_caps_value("fps60") == 0) {
        NSUserDefaults *d = s2a_ios_settings_defaults();
        control.on = [d boolForKey:@"S2AFps60Manual"]; cell.detailTextLabel.text = S2AL(@"settings.fps.knownIssue");
        __weak S2ASettingsController *weakSelf = self;
        [control addAction:[UIAction actionWithHandler:^(UIAction *action) {
            BOOL on = ((UISwitch *)action.sender).on;
            [d setBool:on forKey:@"S2AFps60Manual"];
            if (!on) return;
            [d setBool:YES forKey:@"S2AFps60"];   // 先前关过 60 帧（存着 NO）会压过手动开（settings.m 关的分支在前）
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:S2AL(@"cpatch.group.fps") message:S2AL(@"settings.fps.knownIssue.message") preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"common.gotIt") style:UIAlertActionStyleCancel handler:nil]];
            [weakSelf.navigationController.topViewController presentViewController:alert animated:YES completion:nil];
        }] forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = control; return cell; }
    // 60 帧开着、此刻因发热 / 低电量降档（runtime/src/fps.c）：开关仍是玩家选的开，副标题写清楚画面暂时是原生帧率（审计 P1-80）
    if ([key isEqualToString:@"S2AFps60"] && control.on) { int cap = s2a_fps_cap_reason ? s2a_fps_cap_reason() : 0; if (cap == 1 || cap == 2) cell.detailTextLabel.text = cap == 1 ? S2AL(@"settings.fps.capThermal") : S2AL(@"settings.fps.capLowPower"); }
    [control addAction:[UIAction actionWithHandler:^(UIAction *action) {
        BOOL enabled = ((UISwitch *)action.sender).on;
        if ([key isEqualToString:@"S2A.touchHud"]) s2a_vpad_set_touch_hud(enabled);
        // 性能浮层：与齿轮菜单同一个键（App 级 NSUserDefaults），改完当场显示 / 收起
        else if ([key isEqualToString:@"S2APerfHUD"]) {
            [NSUserDefaults.standardUserDefaults setBool:enabled forKey:key];
            if (s2a_hud_brief_show && s2a_ios_root_view && s2a_ios_root_view()) s2a_hud_brief_show(s2a_ios_root_view(), enabled);
        }
        // 60 帧：开关这一下是玩家明确的选择，连同 S2AFps60Manual 一起记（settings.m 只认它算「开」；老版本缺省存着的 S2AFps60=YES 不算）；同一层存储（按款 / 所有游戏）
        else if ([key isEqualToString:@"S2AFps60"]) s2a_ios_set_fps60(enabled);
        else if ([key isEqualToString:@"S2AWidescreen"]) s2a_ios_set_fullscreen(nil, enabled);
        else [s2a_ios_settings_defaults() setBool:enabled forKey:key];
    }] forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = control; return cell;
}
- (NSInteger)rowsForGroup:(NSInteger)group {
    if (group == 6) return 2;
    if (group == 7) return 2;   // 界面语言、游戏语言
    if (group == 8) return 1 + (_patchGroups.count > 0);   // S 级优化：社区补丁（这款有才列）+ 金手指
    if (group == 2) return 5;   // 开发者页：打开时导出 / 诊断局 / 触屏诊断 / S2Arm 浮层 / Metal 浮层
    return group == 0 ? (NSInteger)[self graphicsRows].count : 0;
}
// 画面组的行（11-13 维护者撤掉我方 60 帧与通用满屏，只用社区补丁）：画质四项 → 满屏（这款有宽屏补丁才列）→ 帧率（有帧率补丁才列）→ 运行模式；
//   值 0–3 = 画质选项序号，6 / 7 / 9 = toggleKeys 序号（满屏 / 帧率 / 运行模式）
// 这款帧率补丁的档位（目标帧率去重升序，取不到目标的当 60；11-13 维护者：60 / 120 都带进去，玩家自己切）
- (NSArray<NSNumber *> *)fpsLevels {
    NSMutableOrderedSet *s = [NSMutableOrderedSet orderedSet];
    for (S2ACPatchGroup *g in _patchGroups) for (S2ACPatchItem *it in g.items) if (it.followsFps60) [s addObject:@(it.targetFps > 0 ? it.targetFps : 60)];
    return [s.array sortedArrayUsingSelector:@selector(compare:)];
}
- (NSArray<NSNumber *> *)graphicsRows {
    BOOL fpsP = NO, wsP = NO;
    for (S2ACPatchGroup *g in _patchGroups) for (S2ACPatchItem *it in g.items) { if (it.followsFps60) fpsP = YES; if ([g.kind isEqual:@"widescreen"] || it.followsFullscreen) wsP = YES; }
    NSMutableArray *rows = [@[@0, @1, @2, @3] mutableCopy];
    if (wsP) [rows addObject:@6];
    if (fpsP) [rows addObject:@7];
    if (fpsP && [self fpsLevels].count > 1) [rows addObject:@20];   // 帧率档位（两档以上才列）
    [rows addObject:@9];
    return rows;
}
- (UITableViewCell *)cellForGroup:(NSInteger)group row:(NSInteger)row {
    __weak S2ASettingsController *weakSelf = self;
    if (group == 6) {
        BOOL split=row==0;
        NSString *key=split?S2APlaySplitKey:S2APlayOrientationKey;
        NSArray *values=split?@[@"auto",@"on",@"off"]:@[@"auto",@"landscape",@"portrait"];
        NSInteger selected=split?(NSInteger)S2APlayReadSplit(NSUserDefaults.standardUserDefaults):(NSInteger)S2APlayReadOrientation(NSUserDefaults.standardUserDefaults);
        return [self dropdown:split?S2AL(@"play.split"):S2AL(@"play.orientation") labels:split?@[S2AL(@"play.auto"),S2AL(@"play.on"),S2AL(@"play.off")]:@[S2AL(@"play.auto"),S2AL(@"play.landscape"),S2AL(@"play.portrait")] selected:selected enabled:^BOOL(NSInteger i){ return YES; } choose:^(NSInteger i){
            [NSUserDefaults.standardUserDefaults setObject:values[i] forKey:key]; [weakSelf refresh];
        } identifier:[@"settings." stringByAppendingString:key]];
    }
    if (group == 7 && row == 1) {   // 游戏语言（按款，11-13；定义表 game_settings.v1.json language）：跟随系统 + Switch 全部语言，存这款的 S2AGameLanguage，下次开游戏生效
        NSArray<NSString *> *values = s2a_ios_game_languages();
        NSArray<NSString *> *labels = @[S2AL(@"settings.gameLanguage.system"), S2AL(@"settings.language.zhHans"), S2AL(@"settings.language.zhHant"), @"English (US)", @"English (UK)", S2AL(@"settings.gameLanguage.ja"), @"한국어", @"Français", @"Français (Canada)", @"Deutsch",
                                        @"Español", @"Español (Latinoamérica)", @"Italiano", @"Nederlands", @"Português", @"Português (Brasil)", @"Русский", @"Polski", @"ไทย"];
        NSUserDefaults *d = s2a_ios_settings_defaults();
        NSString *cur = [d stringForKey:S2AGameLanguageKey];
        // 只列这款支持的（11-14 维护者：读资源包 ctl/control.nacp 的支持语言标志，settings.m）；读不到 = 不知道，照旧列全部；已选的这款没有也留着
        NSArray<NSString *> *supported = s2a_ios_game_supported_languages();
        NSMutableArray<NSString *> *keep = [NSMutableArray array], *shown = [NSMutableArray array];
        for (NSUInteger i = 0; i < values.count; i++)
            if (i == 0 || supported.count == 0 || [supported containsObject:values[i]] || [values[i] isEqualToString:cur]) { [keep addObject:values[i]]; [shown addObject:labels[i]]; }
        values = keep;
        NSInteger selected = cur ? (NSInteger)[values indexOfObject:cur] : 0; if (selected == NSNotFound) selected = 0;
        return [self dropdown:S2AL(@"settings.gameLanguage") labels:shown selected:selected enabled:^BOOL(NSInteger i) { (void)i; return YES; } choose:^(NSInteger i) {
            if (i == selected) return;
            if (i == 0) [d removeObjectForKey:S2AGameLanguageKey]; else [d setObject:values[i] forKey:S2AGameLanguageKey];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:S2AL(@"settings.gameLanguage") message:S2AL(@"settings.gameLanguage.restart") preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"common.gotIt") style:UIAlertActionStyleCancel handler:nil]];
            [weakSelf.navigationController.topViewController presentViewController:alert animated:YES completion:nil]; [weakSelf refresh];
        } identifier:@"settings.gameLanguage"];
    }
    if (group == 7) {   // 界面语言（11-13 维护者）：跟随系统 / 简 / 繁 / 英，存 S2AUILanguageKey；重开 App 生效（ios/app.m 起进程时设本 App 的 AppleLanguages）
        NSArray *values = @[@"system", @"zh-Hans", @"zh-Hant", @"en"];
        NSString *cur = [NSUserDefaults.standardUserDefaults stringForKey:S2AUILanguageKey]; NSInteger selected = cur ? (NSInteger)[values indexOfObject:cur] : 0; if (selected == NSNotFound) selected = 0;
        return [self dropdown:S2AL(@"settings.language") labels:@[S2AL(@"settings.language.system"), S2AL(@"settings.language.zhHans"), S2AL(@"settings.language.zhHant"), S2AL(@"settings.language.en")]
                     selected:selected enabled:^BOOL(NSInteger i) { (void)i; return YES; } choose:^(NSInteger i) {
            if (i == selected) return;
            if (i == 0) [NSUserDefaults.standardUserDefaults removeObjectForKey:S2AUILanguageKey]; else [NSUserDefaults.standardUserDefaults setObject:values[i] forKey:S2AUILanguageKey];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:S2AL(@"settings.language") message:S2AL(@"settings.language.restart") preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"common.gotIt") style:UIAlertActionStyleCancel handler:nil]];
            [weakSelf.navigationController.topViewController presentViewController:alert animated:YES completion:nil]; [weakSelf refresh];
        } identifier:@"settings.uiLanguage"];
    }
    if (group == 8) {   // S 级优化：社区补丁 → 补丁页；金手指 → 金手指页（都推进本设置的导航里）
        BOOL patches = _patchGroups.count > 0 && row == 0;
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.textLabel.text = patches ? S2AL(@"cpatch.title") : S2AL(@"cheats.title"); cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        NSInteger con = 0, call = 0, pon = 0, pall = 0; s2a_ios_sgrade_counts(nil, &con, &call, &pon, &pall);   // 右边写「已开 n · 共 m」（ios/game_options.m）
        cell.detailTextLabel.text = [NSString stringWithFormat:S2AL(@"sgrade.counts"), (long)(patches ? pon : con), (long)(patches ? pall : call)];
        cell.imageView.image = [UIImage systemImageNamed:patches ? @"square.stack.3d.up.fill" : @"wand.and.stars"]; cell.imageView.tintColor = s2a_sgrade_gold();
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessibilityIdentifier = patches ? @"settings.communityPatches" : @"settings.cheats";
        return cell;
    }
    if (group == 0) {
        NSInteger kind = [self graphicsRows][row].integerValue;
        if (kind == 20) {   // 帧率档位：自动（不超过屏幕刷新率的最高一档）/ 各档；选了存 S2AFpsPick，游戏里当场切（s2a_cpatch_fps_pick），否则下次进游戏生效
            NSArray<NSNumber *> *lv = [self fpsLevels]; NSMutableArray *labels = [NSMutableArray arrayWithObject:S2AL(@"settings.fps.pick.auto")];
            for (NSNumber *n in lv) [labels addObject:[NSString stringWithFormat:S2AL(@"settings.fps.pick.level"), n.longValue]];
            NSInteger cur = [s2a_ios_settings_defaults() integerForKey:@"S2AFpsPick"], sel = cur > 0 ? (NSInteger)[lv indexOfObject:@(cur)] + 1 : 0;
            if (sel < 0 || sel > (NSInteger)lv.count) sel = 0;
            return [self dropdown:S2AL(@"settings.fps.pick") labels:labels selected:sel enabled:^BOOL(NSInteger index) { (void)index; return YES; } choose:^(NSInteger index) {
                NSInteger v = index > 0 ? lv[index - 1].integerValue : 0;
                [s2a_ios_settings_defaults() setInteger:v forKey:@"S2AFpsPick"];
                if (s2a_cpatch_fps_pick) s2a_cpatch_fps_pick((int)v);
                [weakSelf refresh];
            } identifier:@"settings.fpsPick"];
        }
        if (kind >= 6) return [self toggleCell:kind];
        row = kind;
        NSDictionary *option = s2a_ios_graphics_options()[row];
        if (row != 2) return [self sliderCell:option];
        NSArray *values = option[@"values"];
        NSInteger selected = [values indexOfObject:s2a_ios_graphics_snapshot(s2a_ios_settings_defaults())[option[@"key"]]];
        return [self dropdown:option[@"title"] labels:option[@"labels"] selected:selected enabled:^BOOL(NSInteger index) { return YES; } choose:^(NSInteger index) {
            [s2a_ios_settings_defaults() setObject:values[index] forKey:option[@"key"]]; [weakSelf refresh];
        } identifier:@"settings.filter"];
    }
    static const NSInteger dev[] = {3, 10, 8, 4, 5};   // toggleKeys 下标
    return [self toggleCell:dev[MIN(MAX(row, 0), 4)]];
}
- (void)selectGroup:(NSInteger)group row:(NSInteger)row {
    if (group == 8 && !(_patchGroups.count > 0 && row == 0)) {
        UIViewController *cheats = s2a_cheats_controller(YES);
        NSMutableArray *bar = [NSMutableArray array];   // 右上：设置页自己的关闭键 + 金手指的「导入」
        if (self.navigationItem.rightBarButtonItem) [bar addObject:self.navigationItem.rightBarButtonItem];
        if (cheats.navigationItem.rightBarButtonItem) [bar addObject:cheats.navigationItem.rightBarButtonItem];
        cheats.navigationItem.rightBarButtonItems = bar;
        [self.navigationController pushViewController:cheats animated:YES];
    } else if (group == 8) {
        UIViewController *patches = s2a_cpatch_settings_controller(_patchGroups);
        if (patches) {
            patches.navigationItem.rightBarButtonItem = self.navigationItem.rightBarButtonItem;
            [self.navigationController pushViewController:patches animated:YES];
        }
    }
}
- (void)close {
    [self.navigationController dismissViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled() completion:^{ s2a_vpad_set_settings_open(NO); }];
}
- (void)done {
    if (_restarting || s2a_diag_is_exporting() || self.navigationController.topViewController.presentedViewController) return;
    // 掌机 / 主机改成运行中直接切（缺口扫描族 2，接口 v2.15）：服务层调 ChangeDockedModeState，按游戏的通知开关发模式消息、点亮分辨率事件；
    //   不再算进「要重启才生效」的画面设置
    BOOL graphicsRestart = NO;
    NSInteger docked = s2a_ios_settings_docked_change(_entryGraphics, s2a_ios_graphics_snapshot(s2a_ios_settings_defaults()), &graphicsRestart);
    if (docked >= 0) {
        if (s2a_console_mode_set) s2a_console_mode_set((int)docked);
        _entryGraphics = [s2a_ios_graphics_snapshot(s2a_ios_settings_defaults()) copy];
    }
    BOOL changed = graphicsRestart ||
        ![_entryPatches isEqual:S2ACPatchEnabled(_patchGroups, s2a_ios_settings_defaults())];
    if (!changed) { [self close]; return; }
    BOOL canRestart = _runtime.restart && _runtime.canRestart && _runtime.canRestart();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:S2AL(@"settings.restart.title")
        message:canRestart ? S2AL(@"settings.restart.message") : S2AL(@"settings.restart.messageLater")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:canRestart ? S2AL(@"common.restartLater") : S2AL(@"common.done") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { [self close]; }]];
    if (canRestart) {
        __weak UIAlertController *weakAlert = alert;
        UIAlertAction *restart = [UIAlertAction actionWithTitle:S2AL(@"common.restartNow") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            // An immediate provider rejection must not try to present an error
            // over a confirmation that is still dismissing.
            UIAlertController *confirmation = weakAlert;
            if (confirmation.presentingViewController)
                [confirmation dismissViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled() completion:^{ [self restart]; }];
            else dispatch_async(dispatch_get_main_queue(), ^{ [self restart]; });
        }];
        [alert addAction:restart]; alert.preferredAction = restart;
    }
    [self.navigationController.topViewController presentViewController:alert animated:!UIAccessibilityIsReduceMotionEnabled() completion:nil];
}
- (void)restart {
    _restarting = YES; self.navigationItem.rightBarButtonItem.enabled = NO;
    _columns.userInteractionEnabled = NO;
    UIViewController *top = self.navigationController.topViewController;
    NSString *title = top.title; BOOL hiddenBack = top.navigationItem.hidesBackButton;
    UIGestureRecognizer *back = self.navigationController.interactivePopGestureRecognizer;
    BOOL backEnabled = back.enabled; back.enabled = NO;
    top.view.userInteractionEnabled = NO; top.navigationItem.hidesBackButton = YES;
    self.title = top.title = S2AL(@"settings.restarting");
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, self.title);
    _runtime.restart(^(NSString *error) {
        self->_restarting = NO; self->_columns.userInteractionEnabled = YES;
        top.view.userInteractionEnabled = YES; top.navigationItem.hidesBackButton = hiddenBack;
        back.enabled = backEnabled;
        top.title = title;
        self.title = S2AL(@"common.settings"); [self refresh];
        if (error) [self showError:error]; else [self close];
    });
}
@end

@interface S2ASettingsNavigation : UINavigationController
@end
@implementation S2ASettingsNavigation
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return s2a_ios_play_orientations(); }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
@end

void s2a_settings_present(UIViewController *presenter) {
    if (!presenter) return;
    presenter = s2a_top_presenter(presenter);
    s2a_vpad_set_settings_open(YES);
    S2ASettingsNavigation *navigation = [[S2ASettingsNavigation alloc] initWithRootViewController:[S2ASettingsController new]];
    navigation.modalPresentationStyle = UIModalPresentationOverFullScreen; navigation.modalInPresentation = YES;
    navigation.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;   // 11-14 重做：和游戏画面同一种深色，不再是灰毛玻璃上压白卡片
    [presenter presentViewController:navigation animated:!UIAccessibilityIsReduceMotionEnabled() completion:nil];
}
