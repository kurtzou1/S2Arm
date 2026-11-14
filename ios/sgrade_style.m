// S 级优化的金色样式，见 sgrade_style.h
#import "sgrade_style.h"
#import "s2a_l10n.h"

static UIColor *rgb(CGFloat r, CGFloat g, CGFloat b) { return [UIColor colorWithRed:r green:g blue:b alpha:1]; }
UIColor *s2a_sgrade_gold(void) {   // 主金：深色界面亮金，浅色界面深一档（跟系统外观即时切）
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) { return t.userInterfaceStyle == UIUserInterfaceStyleDark ? rgb(0.93, 0.77, 0.42) : rgb(0.70, 0.49, 0.14); }];
}

UIImage *s2a_sgrade_image(void) {
    static UIImage *img; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *b = [NSBundle.mainBundle pathForResource:@"S2ArmShellUI_ShellUI" ofType:@"bundle"];
        NSString *p = b ? [[NSBundle bundleWithPath:b] pathForResource:@"s-gold" ofType:@"png"] : nil;
        img = p ? [UIImage imageWithContentsOfFile:p] : nil;
        if (!img) img = [[UIImage systemImageNamed:@"sparkles"] imageWithTintColor:s2a_sgrade_gold() renderingMode:UIImageRenderingModeAlwaysOriginal];
    });
    return img;
}

// 横向渐变的字（香槟金 → 主金 → 玫瑰金）：画成图案色给 UILabel
static UIColor *gradient_text_color(CGSize size) {
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *g = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        // 浅色界面（设置页跟系统外观）用深一档的金：原来的香槟金在浅底上发白看不清（11-13 ç»´æ¤è 截图）
        BOOL light = UITraitCollection.currentTraitCollection.userInterfaceStyle != UIUserInterfaceStyleDark;
        NSArray *cs = light ? @[(id)rgb(0.62, 0.42, 0.10).CGColor, (id)rgb(0.72, 0.50, 0.16).CGColor, (id)rgb(0.72, 0.36, 0.26).CGColor]
                            : @[(id)rgb(1, 0.92, 0.70).CGColor, (id)rgb(0.93, 0.77, 0.42).CGColor, (id)rgb(0.93, 0.62, 0.52).CGColor];
        CGGradientRef gr = CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)cs, NULL);
        CGContextDrawLinearGradient(ctx.CGContext, gr, CGPointZero, CGPointMake(size.width, 0), 0); CGGradientRelease(gr);
    }];
    return [UIColor colorWithPatternImage:g];
}

UIView *s2a_sgrade_header(CGFloat width) {
    UIView *v = [UIView new];
    UIImageView *s = [[UIImageView alloc] initWithImage:s2a_sgrade_image()]; s.contentMode = UIViewContentModeScaleAspectFit;
    s.layer.shadowColor = s2a_sgrade_gold().CGColor; s.layer.shadowRadius = 9; s.layer.shadowOpacity = 0.55; s.layer.shadowOffset = CGSizeZero;
    UILabel *title = [UILabel new]; title.text = S2AL(@"sgrade.title");
    title.font = [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:19 weight:UIFontWeightBold]]; title.adjustsFontForContentSizeCategory = YES;
    [title sizeToFit]; title.textColor = gradient_text_color(CGSizeMake(MAX(title.bounds.size.width, 1), MAX(title.bounds.size.height, 1)));
    title.accessibilityTraits = UIAccessibilityTraitHeader;
    UILabel *beta = [UILabel new]; beta.text = @" BETA "; beta.font = [UIFont systemFontOfSize:9.5 weight:UIFontWeightBold]; beta.textColor = s2a_sgrade_gold();
    beta.layer.borderColor = [s2a_sgrade_gold() colorWithAlphaComponent:0.55].CGColor; beta.layer.borderWidth = 1; beta.layer.cornerRadius = 8; beta.textAlignment = NSTextAlignmentCenter;
    UILabel *note = [UILabel new]; note.text = S2AL(@"sgrade.note"); note.numberOfLines = 0;
    note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; note.adjustsFontForContentSizeCategory = YES; note.textColor = UIColor.secondaryLabelColor;
    for (UIView *x in @[s, title, beta, note]) { x.translatesAutoresizingMaskIntoConstraints = NO; [v addSubview:x]; }
    UILayoutGuide *m = v.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [s.leadingAnchor constraintEqualToAnchor:m.leadingAnchor], [s.topAnchor constraintEqualToAnchor:v.topAnchor constant:14],
        [s.widthAnchor constraintEqualToConstant:40], [s.heightAnchor constraintEqualToConstant:40],
        [title.leadingAnchor constraintEqualToAnchor:s.trailingAnchor constant:12], [title.topAnchor constraintEqualToAnchor:s.topAnchor constant:-1],
        [beta.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:8], [beta.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [beta.heightAnchor constraintEqualToConstant:16],
        [note.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [note.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [note.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:3], [note.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-8],
        [note.bottomAnchor constraintGreaterThanOrEqualToAnchor:s.bottomAnchor constant:0],
    ]];
    (void)width; return v;
}
