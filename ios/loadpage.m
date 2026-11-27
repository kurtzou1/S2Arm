// 首次进游戏的加载页 / 之后启动的简短启动画面（10-30 维护者 批准；进度模型 runtime/src/loadprog.c，本文件只画）。
// 首次：游戏图标模糊铺底 + 图标与标题 + 三段步骤（准备游戏数据 → 为你的设备优化画面 → 进入游戏）+ 进度条、已优化数与剩余时间
//   + 「只在首次启动时进行，之后启动只需几秒」；预热进行一会儿后淡入「先开始玩，后台继续优化」。
// 之后的启动：只有图标、标题和一个小转圈，首帧上屏就淡出。素材取本地资源包（icon.jpg、ctl/control.nacp），不外传。
// 主线程每 0.25 秒读一次模型快照；页面压在根视图最上层（虚拟手柄等后挂的视图也压不住它），首帧后 0.35 秒淡出并移除。
#import <UIKit/UIKit.h>
#import "tv_compat.h"
#import "s2a_l10n.h"
#import "bundle_icon.h"
#include "s2a_loadprog.h"
#include "native.h"   // LOG（测试开关 S2A_LOADPAGE_SKIP 的日志行）
#import "loadpage_title.h"   // 加载页游戏名的取法（#502）
uint64_t now_ns(void);

// 剩余时间小字：档位同 runtime/src/loadprog.c s2a_load_eta_text（<0 估算中 / <5 秒 / 逐秒 / 分秒 / 整分），文字按 App 语言取字符串表（#316），中文值与那份 C 原句逐字相同
static NSString *eta_text(int s) {
    if (s < 0) return S2AL(@"loadpage.eta.estimating");
    if (s < 5) return S2AL(@"loadpage.eta.under5s");
    if (s < 60) return [NSString stringWithFormat:S2AL(@"loadpage.eta.seconds"), s];
    if (s % 60) return [NSString stringWithFormat:S2AL(@"loadpage.eta.minSec"), s / 60, s % 60];
    return [NSString stringWithFormat:S2AL(@"loadpage.eta.minutes"), s / 60];
}

// ---------- 素材 ----------
static NSString *game_data_dir(void) {
    const char *gd = getenv("S2A_GAME_DATA");
    if (gd && *gd) return @(gd);
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/资源包"];
}
// 游戏名：壳交来的封面名（S2A_GAME_NAME）优先，没有按系统语言取 control.nacp（ios/loadpage_title.h），都没有用 App 显示名
static NSString *nacp_title(void) {
    const char *shown = getenv("S2A_GAME_NAME");
    NSData *d = [NSData dataWithContentsOfFile:[game_data_dir() stringByAppendingPathComponent:@"ctl/control.nacp"]];
    NSString *t = s2a_loadpage_title(shown ? @(shown) : nil, d, NSLocale.preferredLanguages);
    if (t) return t;
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"";
}
static UIImage *game_icon(void) {
    UIImage *im = [UIImage imageWithContentsOfFile:[game_data_dir() stringByAppendingPathComponent:@"icon.jpg"]];
    if (im) return im;
    // 包里的 AppIcon（pack/app_bundle.py 用同一张游戏图标缩的；Apple TV 包是品牌资源名，见 bundle_icon.h）
    NSString *name = s2a_bundle_icon_name([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleIcons"]);
    return name ? [UIImage imageNamed:name] : nil;
}

UIImage *s2a_game_icon(void) { return game_icon(); }   // 提示 / 出错页（notice.m）用同一张图

// ---------- 页面 ----------
// 层次：挂在根视图上；之后挂的虚拟手柄 / 开发浮层由 app.m 调 s2a_loadpage_front 压到它下面；资源包说明页、直连安全网提示页后加，盖在它上面
@interface S2ALoadPage : UIView
@property (nonatomic) UIImageView *backdrop, *icon;
@property (nonatomic) UILabel *title, *subtitle, *detail, *eta, *footnote;
@property (nonatomic) NSArray<UIImageView *> *stepDots; @property (nonatomic) NSArray<UILabel *> *stepLabels;
@property (nonatomic) UIProgressView *bar;
@property (nonatomic) UIButton *skip;
@property (nonatomic) UIActivityIndicatorView *spinner;
@property (nonatomic) NSTimer *timer;
@property (nonatomic) int firstRun, lastStage;
@end

static UILabel *label(CGFloat size, UIFontWeight w, UIColor *c) {
    UILabel *l = [UILabel new]; l.font = [UIFont systemFontOfSize:size weight:w]; l.textColor = c; l.adjustsFontForContentSizeCategory = NO;
    l.translatesAutoresizingMaskIntoConstraints = NO; return l;
}

@implementation S2ALoadPage
- (instancetype)initWithFrame:(CGRect)f firstRun:(int)first {
    if (!(self = [super initWithFrame:f])) return nil;
    _firstRun = first; _lastStage = -1;
    self.backgroundColor = UIColor.blackColor; self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.layer.zPosition = 2000;   // 压过虚拟手柄（1000）与直连出图层（11-02 怪猎：出图层原先压在加载页上，冷首启只见黑屏与手柄），低于开发浮层（10000）
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UIImage *ic = game_icon();
    // 图标画成圆角图片再显示（iOS 图标形状）：不靠图层裁剪，任何绘制路径下都是圆角，外加阴影不被裁掉
    UIImage *rounded = ic ? [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(256, 256)] imageWithActions:^(UIGraphicsImageRendererContext *c) { (void)c;
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 256, 256) cornerRadius:58] addClip]; [ic drawInRect:CGRectMake(0, 0, 256, 256)]; }] : nil;
    // 背景：图标放大铺满、强模糊、压暗——只给颜色氛围，不抢内容
    _backdrop = [[UIImageView alloc] initWithImage:ic]; _backdrop.contentMode = UIViewContentModeScaleAspectFill; _backdrop.clipsToBounds = YES;
    _backdrop.frame = self.bounds; _backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; _backdrop.alpha = 0.9;
    [self addSubview:_backdrop];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:S2A_BLUR_MATERIAL_DARK]];
    blur.frame = self.bounds; blur.autoresizingMask = _backdrop.autoresizingMask; [self addSubview:blur];

    _icon = [[UIImageView alloc] initWithImage:rounded]; _icon.translatesAutoresizingMaskIntoConstraints = NO; _icon.contentMode = UIViewContentModeScaleAspectFill;
    _icon.layer.shadowColor = UIColor.blackColor.CGColor; _icon.layer.shadowOpacity = 0.35; _icon.layer.shadowRadius = 12; _icon.layer.shadowOffset = CGSizeMake(0, 6);
    _title = label(first ? 22 : 20, UIFontWeightSemibold, UIColor.labelColor); _title.text = nacp_title(); _title.numberOfLines = 2;
    UILayoutGuide *g = self.safeAreaLayoutGuide;

    if (!first) {   // 之后的启动：图标 + 标题 + 小转圈，居中
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.translatesAutoresizingMaskIntoConstraints = NO; [_spinner startAnimating]; _title.textAlignment = NSTextAlignmentCenter;
        UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[_icon, _title, _spinner]]; col.axis = UILayoutConstraintAxisVertical;
        col.alignment = UIStackViewAlignmentCenter; col.spacing = 14; [col setCustomSpacing:22 afterView:_title]; col.translatesAutoresizingMaskIntoConstraints = NO;
        [blur.contentView addSubview:col];
        [NSLayoutConstraint activateConstraints:@[[_icon.widthAnchor constraintEqualToConstant:88], [_icon.heightAnchor constraintEqualToConstant:88],
            [col.centerXAnchor constraintEqualToAnchor:g.centerXAnchor], [col.centerYAnchor constraintEqualToAnchor:g.centerYAnchor],
            [col.widthAnchor constraintLessThanOrEqualToAnchor:g.widthAnchor constant:-64]]];
        return self;
    }

    _subtitle = label(15, UIFontWeightRegular, UIColor.secondaryLabelColor); _subtitle.text = S2AL(@"loadpage.subtitle");
    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[_title, _subtitle]]; head.axis = UILayoutConstraintAxisVertical; head.spacing = 4;
    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[_icon, head]]; top.axis = UILayoutConstraintAxisHorizontal; top.spacing = 18; top.alignment = UIStackViewAlignmentCenter;

    // 三段步骤
    NSArray *names = @[S2AL(@"loadpage.step.data"), S2AL(@"loadpage.step.optimize"), S2AL(@"loadpage.step.enter")];
    NSMutableArray *dots = [NSMutableArray array], *labs = [NSMutableArray array], *items = [NSMutableArray array];
    for (NSString *n in names) {
        UIImageView *dot = [UIImageView new]; dot.translatesAutoresizingMaskIntoConstraints = NO; dot.contentMode = UIViewContentModeScaleAspectFit;
        UILabel *l = label(13, UIFontWeightMedium, UIColor.tertiaryLabelColor); l.text = n;
        UIStackView *it = [[UIStackView alloc] initWithArrangedSubviews:@[dot, l]]; it.spacing = 6; it.alignment = UIStackViewAlignmentCenter;
        [NSLayoutConstraint activateConstraints:@[[dot.widthAnchor constraintEqualToConstant:15], [dot.heightAnchor constraintEqualToConstant:15]]];
        [dots addObject:dot]; [labs addObject:l]; [items addObject:it];
    }
    _stepDots = dots; _stepLabels = labs;
    UIStackView *steps = [[UIStackView alloc] initWithArrangedSubviews:items]; steps.spacing = 22; steps.alignment = UIStackViewAlignmentCenter;

    _bar = [[UIProgressView alloc] initWithProgressViewStyle:S2A_PROGRESS_BAR]; _bar.translatesAutoresizingMaskIntoConstraints = NO;
    _bar.progressTintColor = [UIColor colorWithWhite:1 alpha:0.92]; _bar.trackTintColor = [UIColor colorWithWhite:1 alpha:0.14];
    _bar.layer.cornerRadius = 2; _bar.clipsToBounds = YES;
    _detail = label(13, UIFontWeightRegular, UIColor.secondaryLabelColor);
    _eta = label(13, UIFontWeightRegular, UIColor.secondaryLabelColor); _eta.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    _eta.textAlignment = NSTextAlignmentRight; [_eta setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _detail.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    UIStackView *under = [[UIStackView alloc] initWithArrangedSubviews:@[_detail, _eta]]; under.spacing = 12;
    UIStackView *prog = [[UIStackView alloc] initWithArrangedSubviews:@[_bar, under]]; prog.axis = UILayoutConstraintAxisVertical; prog.spacing = 8;

    _footnote = label(12, UIFontWeightRegular, UIColor.tertiaryLabelColor); _footnote.text = S2AL(@"loadpage.footnote");

    UIButtonConfiguration *c = [UIButtonConfiguration filledButtonConfiguration];
    c.title = S2AL(@"loadpage.skip"); c.subtitle = S2AL(@"loadpage.skip.note");
    c.baseBackgroundColor = [UIColor colorWithWhite:1 alpha:0.14]; c.baseForegroundColor = UIColor.labelColor;
    c.cornerStyle = UIButtonConfigurationCornerStyleCapsule; c.titleAlignment = UIButtonConfigurationTitleAlignmentCenter;
    c.contentInsets = NSDirectionalEdgeInsetsMake(10, 22, 10, 22);
    c.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) { NSMutableDictionary *m = a.mutableCopy; m[NSFontAttributeName] = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]; return m; };
    c.subtitleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) { NSMutableDictionary *m = a.mutableCopy; m[NSFontAttributeName] = [UIFont systemFontOfSize:11]; m[NSForegroundColorAttributeName] = UIColor.secondaryLabelColor; return m; };
    _skip = [UIButton buttonWithConfiguration:c primaryAction:[UIAction actionWithHandler:^(UIAction *a) { (void)a; s2a_load_user_skip(); }]];
    _skip.alpha = 0; _skip.hidden = YES;

    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[top, steps, prog, _footnote, _skip]]; col.axis = UILayoutConstraintAxisVertical;
    col.alignment = UIStackViewAlignmentLeading; col.spacing = 22; [col setCustomSpacing:28 afterView:top]; [col setCustomSpacing:14 afterView:steps];
    [col setCustomSpacing:18 afterView:prog]; col.translatesAutoresizingMaskIntoConstraints = NO;
    [blur.contentView addSubview:col];
    [NSLayoutConstraint activateConstraints:@[
        [_icon.widthAnchor constraintEqualToConstant:84], [_icon.heightAnchor constraintEqualToConstant:84],
        [col.centerXAnchor constraintEqualToAnchor:g.centerXAnchor], [col.centerYAnchor constraintEqualToAnchor:g.centerYAnchor],
        [col.widthAnchor constraintEqualToConstant:520], [col.widthAnchor constraintLessThanOrEqualToAnchor:g.widthAnchor constant:-48],
        [prog.widthAnchor constraintEqualToAnchor:col.widthAnchor], [_bar.heightAnchor constraintEqualToConstant:4]]];
    [col.widthAnchor constraintEqualToConstant:520].priority = UILayoutPriorityDefaultHigh;
    return self;
}
- (void)refresh {
    s2a_load_view v; s2a_load_snapshot(now_ns(), &v);
    if (v.stage == S2A_LOAD_DONE) { [self.timer invalidate]; self.timer = nil;
        [UIView animateWithDuration:0.35 animations:^{ self.alpha = 0; } completion:^(BOOL f) { (void)f; [self removeFromSuperview]; }]; return; }
    if (!self.firstRun) return;
    [self.bar setProgress:(float)v.frac animated:YES];
    for (int i = 0; i < 3; i++) {
        int done = v.stage > i, cur = v.stage == i;
        UIImageSymbolConfiguration *sc = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
        self.stepDots[i].image = [UIImage systemImageNamed:done ? @"checkmark.circle.fill" : cur ? @"circle.inset.filled" : @"circle" withConfiguration:sc];
        self.stepDots[i].tintColor = done ? [UIColor colorWithWhite:1 alpha:0.75] : cur ? UIColor.labelColor : UIColor.tertiaryLabelColor;
        self.stepLabels[i].textColor = cur ? UIColor.labelColor : done ? UIColor.secondaryLabelColor : UIColor.tertiaryLabelColor;
    }
    NSNumberFormatter *nf = [NSNumberFormatter new]; nf.numberStyle = NSNumberFormatterDecimalStyle;
    if (v.stage == S2A_LOAD_DATA) { self.detail.text = S2AL(@"loadpage.data"); self.eta.text = @""; }
    else if (v.stage == S2A_LOAD_OPTIMIZE) {
        self.detail.text = [NSString stringWithFormat:S2AL(@"loadpage.optimized"), [nf stringFromNumber:@(v.done)], [nf stringFromNumber:@(v.total)]];
        NSString *b = eta_text(v.eta_s); self.eta.text = v.eta_s >= 0 ? [NSString stringWithFormat:S2AL(@"loadpage.remaining"), b] : b;
    } else { self.detail.text = v.go_reason == S2A_LOAD_GO_DONE ? S2AL(@"loadpage.go.done") : S2AL(@"loadpage.go.early"); self.eta.text = @""; }
    if (v.can_skip && self.skip.hidden) { self.skip.hidden = NO; [UIView animateWithDuration:0.4 animations:^{ self.skip.alpha = 1; }];
        // 测试开关 S2A_LOADPAGE_SKIP=1（发版真机冒烟按 60 秒判首帧，首装云端种子大的款首帧前要编几分钟，同 app.m S2A_LIBRARY_AUTOPLAY）：按钮淡入后 1 秒替玩家点一次
        //   「先开始玩」，走玩家点按钮的同一个动作（s2a_load_user_skip）；只点一次。不设开关行为不变
        const char *e = getenv("S2A_LOADPAGE_SKIP"); static int clicked;
        if (e && !strcmp(e, "1") && !clicked) { clicked = 1; UIButton *b = self.skip;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (b.hidden) return;   // 1 秒内已不能点（编完 / 已放行）：不点
                LOG("加载页：测试开关 S2A_LOADPAGE_SKIP，替玩家点先开始玩"); [b sendActionsForControlEvents:UIControlEventPrimaryActionTriggered]; }); } }
    else if (!v.can_skip && !self.skip.hidden) { [UIView animateWithDuration:0.2 animations:^{ self.skip.alpha = 0; } completion:^(BOOL f) { (void)f; self.skip.hidden = YES; }]; }
}
@end

static S2ALoadPage *g_page;
static void page_build(UIView *root, int first);
// 场景连上、根视图建好时调（ios/app.m）：首次与否取模型（host_main.c main 里 s2a_load_begin 定）
void s2a_loadpage_attach(UIView *root) {
    if (g_page || !root) return;
    s2a_load_view v; s2a_load_snapshot(now_ns(), &v);
    if (v.stage == S2A_LOAD_DONE) return;
    page_build(root, v.first_run);
}
// 建页面、挂上、起 0.25 秒刷新。简短启动画面期间模型把这一局升成首次（loadprog.c：之后的启动却还要编很久，11-23 #2133）时，
//   换成完整加载页（进度 + 先开始玩），同一个根视图、同一套刷新
static void page_build(UIView *root, int first) {
    g_page = [[S2ALoadPage alloc] initWithFrame:root.bounds firstRun:first];
    [root addSubview:g_page]; [g_page refresh];
    { void s2a_report_gear_attach(UIView *); s2a_report_gear_attach(g_page); }   // 左上角「故障报修」按钮（加载 / 解包时也找得到上传入口）
    __weak S2ALoadPage *w = g_page;
    g_page.timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) { (void)t;
        S2ALoadPage *pg = w; if (!pg) return;
        if (!pg.firstRun && pg.superview) { s2a_load_view v; s2a_load_snapshot(now_ns(), &v);
            if (v.first_run && v.stage != S2A_LOAD_DONE) { UIView *r = pg.superview; [pg.timer invalidate]; pg.timer = nil; [pg removeFromSuperview];
                if (g_page == pg) g_page = nil;
                page_build(r, 1); return; } }
        [pg refresh]; }];
}
// 根视图上后挂的视图（虚拟手柄、开发浮层）挂完后调：加载页压回它们上面
void s2a_loadpage_front(void) { if (g_page.superview) [g_page.superview bringSubviewToFront:g_page]; }
