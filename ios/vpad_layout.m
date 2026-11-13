#import "vpad_layout.h"
#import "s2a_l10n.h"
#include <math.h>

NSString *const S2AVPadLayoutDefaultIdentifier = @"default";
NSString *const S2AVPadLayoutMineIdentifier = @"mine";
// 纯触屏：没有虚拟按键，也就没有可编辑的几何，因此不落文件、只记在选择记录里。
NSString *const S2AVPadLayoutTouchIdentifier = @"touch";
NSString *const S2AVPadLayout2DIdentifier = @"2d";

CGFloat S2AVPadKeyOpacity(CGFloat idle, BOOL active) {
    return active ? MAX(0.75, idle) : idle;
}

// Foundation's JSON reader can round two related decimal fields in opposite
// directions (observed for the iPad default's 54/687 and 27/687). This is far
// below a screen pixel; do not reject a valid round trip on a cross-field edge.
static const double geometryTolerance = 1e-12;

static NSError *layout_error(NSString *code, NSString *message) {
    return [NSError errorWithDomain:@"S2Arm.VPadLayout" code:1
                          userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:S2AL(@"vpad.layout.error"), code, message]}];
}
static BOOL fail(NSError **error, NSString *code, NSString *message) {
    if (error) *error = layout_error(code, message);
    return NO;
}
static BOOL fields(id value, NSArray *keys) {
    return [value isKindOfClass:NSDictionary.class] &&
        [[NSSet setWithArray:[value allKeys]] isEqualToSet:[NSSet setWithArray:keys]];
}
static BOOL number(id value, double low, double high) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue] >= low && [value doubleValue] <= high;
}
static BOOL identifier_ok(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 64) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789._-"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
        [[NSCharacterSet alphanumericCharacterSet] characterIsMember:[value characterAtIndex:0]];
}
static BOOL rect_ok(id value) {
    if (!fields(value, @[@"x", @"y", @"width", @"height"])) return NO;
    for (NSString *key in @[@"x", @"y"]) if (!number(value[key], 0, 1)) return NO;
    for (NSString *key in @[@"width", @"height"]) if (!number(value[key], 0.01, 1)) return NO;
    return [value[@"x"] doubleValue] + [value[@"width"] doubleValue] <= 1 + geometryTolerance &&
           [value[@"y"] doubleValue] + [value[@"height"] doubleValue] <= 1 + geometryTolerance;
}
static CGRect normalized_rect(NSDictionary *value) {
    return CGRectMake([value[@"x"] doubleValue], [value[@"y"] doubleValue],
                      [value[@"width"] doubleValue], [value[@"height"] doubleValue]);
}

@implementation S2AVPadLayout
+ (instancetype)readData:(NSData *)data error:(NSError **)error {
    if (data.length > 65536) { fail(error, @"F01.size", S2AL(@"vpad.layout.err.size")); return nil; }
    id doc = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!doc) return nil;
    if (!fields(doc, @[@"schemaVersion", @"id", @"name", @"buttons", @"sticks"]) ||
        !number(doc[@"schemaVersion"], 1, 1) || !identifier_ok(doc[@"id"]) ||
        ![doc[@"name"] isKindOfClass:NSString.class] || ![doc[@"name"] length] || [doc[@"name"] length] > 64 ||
        [doc[@"name"] rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        ![doc[@"buttons"] isKindOfClass:NSArray.class] || ![doc[@"sticks"] isKindOfClass:NSArray.class]) {
        fail(error, @"F01.schema", S2AL(@"vpad.layout.err.schema")); return nil;
    }
    NSArray *required = @[@"A", @"B", @"X", @"Y", @"L", @"R", @"ZL", @"ZR", @"PLUS", @"MINUS", @"LEFT", @"UP", @"RIGHT", @"DOWN"];
    NSSet *allowed = [NSSet setWithArray:[required arrayByAddingObjectsFromArray:@[@"LS", @"RS"]]];
    NSMutableSet *seen = [NSMutableSet set];
    NSArray *buttons = doc[@"buttons"];
    if (buttons.count < 14 || buttons.count > 16) { fail(error, @"F01.buttons", S2AL(@"vpad.layout.err.buttonCount")); return nil; }
    for (id b in buttons) {
        if (!fields(b, @[@"id", @"x", @"y", @"width", @"height", @"cornerRadius"]) ||
            ![b[@"id"] isKindOfClass:NSString.class] || ![allowed containsObject:b[@"id"]] || [seen containsObject:b[@"id"]] ||
            !number(b[@"x"], 0, 1) || !number(b[@"y"], 0, 1) ||
            // 宽高按安全区短边折算（frameForButton）：默认布局按点设计，小键 30 点在 iPad 大屏（短边约 1000 点）只有 0.03；
            //   下限原为 0.04（按 iPhone 定），iPad 上拖完一保存就过不了（#372），改成与摇杆激活区同一个下限 0.01
            !number(b[@"width"], 0.01, 0.4) || !number(b[@"height"], 0.01, 0.4) ||
            !number(b[@"cornerRadius"], 0, 0.2) ||
            [b[@"cornerRadius"] doubleValue] > MIN([b[@"width"] doubleValue], [b[@"height"] doubleValue]) / 2 + geometryTolerance) {
            fail(error, @"F01.buttons", S2AL(@"vpad.layout.err.buttonFields")); return nil;
        }
        [seen addObject:b[@"id"]];
    }
    if (![[NSSet setWithArray:required] isSubsetOfSet:seen]) { fail(error, @"F01.buttons", S2AL(@"vpad.layout.err.buttonMissing")); return nil; }
    NSArray *sticks = doc[@"sticks"];
    // 0 根（2D 布局和从它改出来的「我的布局」，#268）或 2 根
    if (sticks.count != 2 && sticks.count != 0) { fail(error, @"F01.sticks", S2AL(@"vpad.layout.err.stickCount")); return nil; }
    [seen removeAllObjects];
    for (id s in sticks) {
        if (!fields(s, @[@"id", @"activation", @"radius"]) ||
            ![s[@"id"] isKindOfClass:NSString.class] || ![@[@"left", @"right"] containsObject:s[@"id"]] ||
            [seen containsObject:s[@"id"]] || !rect_ok(s[@"activation"]) || !number(s[@"radius"], 0.04, 0.3)) {
            fail(error, @"F01.sticks", S2AL(@"vpad.layout.err.stickFields")); return nil;
        }
        [seen addObject:s[@"id"]];
    }
    CGRect overlap = sticks.count == 2 ? CGRectIntersection(normalized_rect(sticks[0][@"activation"]), normalized_rect(sticks[1][@"activation"])) : CGRectNull;
    if (!CGRectIsNull(overlap) && overlap.size.width > geometryTolerance && overlap.size.height > geometryTolerance) {
        fail(error, @"F01.sticks", S2AL(@"vpad.layout.err.stickOverlap")); return nil;
    }
    S2AVPadLayout *layout = [self new];
    layout->_document = [doc copy]; layout->_identifier = [doc[@"id"] copy]; layout->_name = [doc[@"name"] copy];
    layout->_buttons = [buttons copy]; layout->_sticks = [sticks copy];
    return layout;
}
+ (BOOL)isBuiltinIdentifier:(NSString *)identifier {
    return [identifier isEqualToString:S2AVPadLayoutDefaultIdentifier] || [identifier isEqualToString:S2AVPadLayoutTouchIdentifier] || [identifier isEqualToString:S2AVPadLayout2DIdentifier];
}
- (NSString *)displayName {
    if ([_identifier isEqualToString:S2AVPadLayoutDefaultIdentifier]) return S2AL(@"vpad.layout.default");
    if ([_identifier isEqualToString:S2AVPadLayout2DIdentifier]) return S2AL(@"vpad.layout.2d");
    if ([_identifier isEqualToString:S2AVPadLayoutMineIdentifier]) return S2AL(@"vpad.layout.mine");
    return _name;
}
+ (instancetype)defaultForSafeRect:(CGRect)rect {
    return [self defaultForSafeRect:rect split:NO];
}
+ (instancetype)defaultForSafeRect:(CGRect)rect split:(BOOL)split {
    CGFloat w = MAX(rect.size.width, 1), h = MAX(rect.size.height, 1), unit = MIN(w, h);
    CGFloat scale = split ? MIN(1, MIN(w / 400, h / 350)) : 1;
    // 11-07 维护者 定（参考图 + 方案三「描线」）：肩键下移到约 1/3 高、拇指够得到；左摇杆左侧中部、十字键在它右下；右摇杆右下偏中；ABXY 右侧中下；
    //   L3 / R3 小键挨着两根摇杆；− / + 留顶上正中。位置按安全区比例（横按宽、纵按高），尺寸照旧按点（iPhone 17 Pro Max 横屏 832×419 安全区设计）
    CGFloat ax = 0.905 * w, ay = 0.625 * h, ad = 47, px = 0.235 * w, py = 0.80 * h, pd = 32;
    NSArray *spec = @[@[@"A", @(ax + ad), @(ay)], @[@"B", @(ax), @(ay + ad)], @[@"X", @(ax), @(ay - ad)], @[@"Y", @(ax - ad), @(ay)],
        @[@"ZL", @(0.035 * w), @(0.358 * h)], @[@"L", @(0.135 * w), @(0.358 * h)],
        @[@"R", @(0.865 * w), @(0.358 * h)], @[@"ZR", @(0.965 * w), @(0.358 * h)],
        @[@"MINUS", @(w / 2 - 52), @(22 - rect.origin.y)], @[@"PLUS", @(w / 2 + 52), @(22 - rect.origin.y)],
        @[@"UP", @(px), @(py - pd)], @[@"DOWN", @(px), @(py + pd)], @[@"LEFT", @(px - pd), @(py)], @[@"RIGHT", @(px + pd), @(py)],
        // 摇杆按下（11-06 维护者：七龙珠Z 协议确认页要按）：L3 / R3 挨着各自摇杆的上方；放在其它键之后，热区重叠处仍归旧键（keyAt 按顺序取第一个）
        @[@"LS", @(0.205 * w), @(0.489 * h)], @[@"RS", @(0.795 * w), @(0.489 * h)]];
    if (split) {
        ax=.84*w; ay=.68*h; ad=47*scale; px=.35*w; py=.72*h; pd=32*scale;
        // 外肩键会被安全区边界钳住；内肩键至少隔开一个键宽和 8 点（均随布局缩放）。
        CGFloat outer=MAX(.06*w,29*scale), inner=MAX(.20*w,outer+66*scale);
        spec=@[@[@"A",@(ax+ad),@(ay)],@[@"B",@(ax),@(ay+ad)],@[@"X",@(ax),@(ay-ad)],@[@"Y",@(ax-ad),@(ay)],
            @[@"ZL",@(outer),@(.13*h)],@[@"L",@(inner),@(.13*h)],@[@"R",@(w-inner),@(.13*h)],@[@"ZR",@(w-outer),@(.13*h)],
            @[@"MINUS",@(w/2-52*scale),@(.13*h)],@[@"PLUS",@(w/2+52*scale),@(.13*h)],
            @[@"UP",@(px),@(py-pd)],@[@"DOWN",@(px),@(py+pd)],@[@"LEFT",@(px-pd),@(py)],@[@"RIGHT",@(px+pd),@(py)],
            @[@"LS",@(.13*w),@(.36*h)],@[@"RS",@(.65*w),@(.43*h)]];
    }
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSUInteger i = 0; i < spec.count; i++) {
        NSArray *s = spec[i]; CGFloat bw = i < 4 ? 50 : i < 8 ? 58 : i < 10 ? 30 : i < 14 ? 30 : 30;
        CGFloat bh = i < 4 ? 50 : i < 8 ? 32 : i < 10 ? 30 : i < 14 ? 30 : 30, cr = i < 4 ? 25 : i < 8 ? 16 : i < 10 ? 15 : i < 14 ? 8 : 15;
        [buttons addObject:@{@"id": s[0], @"x": @(MAX(0, MIN(1, [s[1] doubleValue] / w))), @"y": @(MAX(0, MIN(1, [s[2] doubleValue] / h))),
            @"width": @(bw * scale / unit), @"height": @(bh * scale / unit), @"cornerRadius": @(cr * scale / unit)}];
    }
    NSDictionary *doc = @{@"schemaVersion": @1, @"id": S2AVPadLayoutDefaultIdentifier, @"name": S2AL(@"vpad.layout.default"), @"buttons": buttons,
        @"sticks": @[@{@"id": @"left", @"activation": @{@"x": @0, @"y": @0, @"width": @0.5, @"height": @1}, @"radius": @(60 * scale / unit)},
                     @{@"id": @"right", @"activation": @{@"x": @0.5, @"y": @0, @"width": @0.5, @"height": @1}, @"radius": @(60 * scale / unit)}]};
    // Do not parse our own trusted defaults on every resize.
    S2AVPadLayout *layout = [self new]; layout->_document = doc; layout->_identifier = S2AVPadLayoutDefaultIdentifier; layout->_name = doc[@"name"];
    layout->_buttons = buttons; layout->_sticks = doc[@"sticks"]; return layout;
}
+ (instancetype)twoDForSafeRect:(CGRect)rect {
    CGFloat w = MAX(rect.size.width, 1), h = MAX(rect.size.height, 1), unit = MIN(w, h);
    // 定稿（iPhone 横屏 832×419 安全区设计，位置按比例、尺寸按点）：十字键 56 点、中心 (0.17, 0.66)、间距 52；ABXY 64 点、中心 (0.855, 0.64)、间距 58；
    //   肩键、− / + 与默认布局同位置；没有 L3 / R3、没有摇杆
    CGFloat px = 0.17 * w, py = 0.66 * h, pd = 52, ax = 0.855 * w, ay = 0.64 * h, ad = 58;
    NSArray *spec = @[@[@"A", @(ax + ad), @(ay), @64, @32], @[@"B", @(ax), @(ay + ad), @64, @32], @[@"X", @(ax), @(ay - ad), @64, @32], @[@"Y", @(ax - ad), @(ay), @64, @32],
        @[@"ZL", @(0.035 * w), @(0.358 * h), @58, @16], @[@"L", @(0.135 * w), @(0.358 * h), @58, @16],
        @[@"R", @(0.865 * w), @(0.358 * h), @58, @16], @[@"ZR", @(0.965 * w), @(0.358 * h), @58, @16],
        @[@"MINUS", @(w / 2 - 52), @(22 - rect.origin.y), @30, @15], @[@"PLUS", @(w / 2 + 52), @(22 - rect.origin.y), @30, @15],
        @[@"UP", @(px), @(py - pd), @56, @10], @[@"DOWN", @(px), @(py + pd), @56, @10], @[@"LEFT", @(px - pd), @(py), @56, @10], @[@"RIGHT", @(px + pd), @(py), @56, @10]];
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSArray *s in spec) {
        CGFloat side = [s[3] doubleValue], height = [s[0] hasPrefix:@"Z"] || [s[0] isEqual:@"L"] || [s[0] isEqual:@"R"] ? 32 : side;
        [buttons addObject:@{@"id": s[0], @"x": @(MAX(0, MIN(1, [s[1] doubleValue] / w))), @"y": @(MAX(0, MIN(1, [s[2] doubleValue] / h))),
            @"width": @(side / unit), @"height": @(height / unit), @"cornerRadius": @([s[4] doubleValue] / unit)}];
    }
    NSDictionary *doc = @{@"schemaVersion": @1, @"id": S2AVPadLayout2DIdentifier, @"name": S2AL(@"vpad.layout.2d"), @"buttons": buttons, @"sticks": @[]};
    S2AVPadLayout *layout = [self new]; layout->_document = doc; layout->_identifier = S2AVPadLayout2DIdentifier; layout->_name = doc[@"name"];
    layout->_buttons = buttons; layout->_sticks = @[]; return layout;
}
- (int)dpadDirectionsAt:(CGPoint)p safeRect:(CGRect)rect {
    if (_sticks.count) return -1;
    CGFloat sx = 0, sy = 0, reach = 0, half = 0; int n = 0; CGRect frames[4];
    for (NSDictionary *b in _buttons) {
        NSUInteger i = [@[@"UP", @"DOWN", @"LEFT", @"RIGHT"] indexOfObject:b[@"id"]]; if (i == NSNotFound) continue;
        frames[n] = [self frameForButton:b safeRect:rect]; sx += CGRectGetMidX(frames[n]); sy += CGRectGetMidY(frames[n]); n++;
    }
    if (n != 4) return -1;
    CGPoint c = CGPointMake(sx / 4, sy / 4);
    for (int i = 0; i < 4; i++) { reach = MAX(reach, hypot(CGRectGetMidX(frames[i]) - c.x, CGRectGetMidY(frames[i]) - c.y)); half = MAX(half, MAX(frames[i].size.width, frames[i].size.height) / 2); }
    CGFloat r = reach + half, dx = p.x - c.x, dy = p.y - c.y, d = hypot(dx, dy);
    if (d > r) return -1;
    if (d < 0.2 * r) return 0;
    // 八个 45° 扇区：右 0°、下 90°（UIKit 纵轴朝下）；扇区边界在 22.5° 处
    int sector = (int)floor(fmod(atan2(dy, dx) * 180 / M_PI + 360 + 22.5, 360) / 45);
    static const int bits[8] = {8, 8 | 2, 2, 2 | 4, 4, 4 | 1, 1, 1 | 8};
    return bits[sector];
}
- (instancetype)layoutWithButtonCenters:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)centers safeRect:(CGRect)rect
                             identifier:(NSString *)identifier name:(NSString *)name error:(NSError **)error {
    CGFloat w = MAX(rect.size.width, 1), h = MAX(rect.size.height, 1);
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSDictionary *button in self.buttons) {
        NSMutableDictionary *b = [button mutableCopy]; NSArray<NSNumber *> *c = centers[button[@"id"]];
        if (c.count == 2) { CGPoint p = CGPointMake(c[0].doubleValue, c[1].doubleValue);
            b[@"x"] = @(MAX(0, MIN(1, (p.x - CGRectGetMinX(rect)) / w))); b[@"y"] = @(MAX(0, MIN(1, (p.y - CGRectGetMinY(rect)) / h))); }
        [buttons addObject:b];
    }
    NSDictionary *doc = @{@"schemaVersion": @1, @"id": identifier, @"name": name, @"buttons": buttons, @"sticks": self.sticks};
    NSData *data = [NSJSONSerialization dataWithJSONObject:doc options:0 error:error];
    return data ? [S2AVPadLayout readData:data error:error] : nil;
}
- (CGRect)frameForButton:(NSDictionary *)button safeRect:(CGRect)rect {
    return [self frameForButton:button safeRect:rect avoiding:CGRectNull];
}
- (CGRect)frameForButton:(NSDictionary *)button safeRect:(CGRect)rect avoiding:(CGRect)division {
    return [self frameForButton:button safeRect:rect avoiding:division scale:1];
}
- (CGRect)frameForButton:(NSDictionary *)button safeRect:(CGRect)rect avoiding:(CGRect)division scale:(CGFloat)scale {
    CGFloat unit = MIN(rect.size.width, rect.size.height);
    CGFloat w = MIN(rect.size.width, [button[@"width"] doubleValue] * unit);
    CGFloat h = MIN(rect.size.height, [button[@"height"] doubleValue] * unit);
    CGFloat x = CGRectGetMinX(rect) + [button[@"x"] doubleValue] * rect.size.width - w / 2;
    CGFloat y = CGRectGetMinY(rect) + [button[@"y"] doubleValue] * rect.size.height - h / 2;
    CGRect frame=CGRectMake(MAX(CGRectGetMinX(rect), MIN(x, CGRectGetMaxX(rect) - w)),
                            MAX(CGRectGetMinY(rect), MIN(y, CGRectGetMaxY(rect) - h)), w, h);
    frame=CGRectInset(frame,frame.size.width*(1-scale)/2,frame.size.height*(1-scale)/2);
    if (!CGRectIsNull(division) && !CGRectIsEmpty(CGRectIntersection(frame,division)) && division.size.height>division.size.width) {
        BOOL left=CGRectGetMidX(frame)<CGRectGetMidX(division);
        CGRect side=left ? CGRectMake(rect.origin.x,rect.origin.y,MAX(0,CGRectGetMinX(division)-rect.origin.x),rect.size.height) :
                         CGRectMake(CGRectGetMaxX(division),rect.origin.y,MAX(0,CGRectGetMaxX(rect)-CGRectGetMaxX(division)),rect.size.height);
        frame.size.width=MIN(frame.size.width,side.size.width);
        frame.origin.x=MAX(CGRectGetMinX(side),MIN(frame.origin.x,CGRectGetMaxX(side)-frame.size.width));
    }
    return frame;
}
- (nullable NSString *)buttonAt:(CGPoint)p safeRect:(CGRect)rect slop:(CGFloat)slop {
    return [self buttonAt:p safeRect:rect slop:slop scales:nil];
}
- (nullable NSString *)buttonAt:(CGPoint)p safeRect:(CGRect)rect slop:(CGFloat)slop scales:(NSDictionary<NSString *, NSNumber *> *)scales {
    return [self buttonAt:p safeRect:rect slop:slop avoiding:CGRectNull nearest:NO scales:scales];
}
- (nullable NSString *)buttonAt:(CGPoint)p safeRect:(CGRect)rect slop:(CGFloat)slop avoiding:(CGRect)division nearest:(BOOL)nearest {
    return [self buttonAt:p safeRect:rect slop:slop avoiding:division nearest:nearest scales:nil];
}
- (nullable NSString *)buttonAt:(CGPoint)p safeRect:(CGRect)rect slop:(CGFloat)slop avoiding:(CGRect)division nearest:(BOOL)nearest scales:(NSDictionary<NSString *, NSNumber *> *)scales {
    if (nearest && (!CGRectContainsPoint(rect,p) || CGRectContainsPoint(division,p))) return nil;
    NSString *best=nil; CGFloat distance=CGFLOAT_MAX;
    for (NSDictionary *button in _buttons) {
        NSNumber *value=scales[button[@"id"]] ?: scales[@"*"]; CGFloat scale=value ? value.doubleValue : 1;
        if (scale<=0) continue;
        CGRect frame=[self frameForButton:button safeRect:rect avoiding:division scale:scale], hit=CGRectInset(frame,-slop,-slop);
        if (nearest) hit=CGRectInset(frame,-MAX(slop,(44-frame.size.width)/2),-MAX(slop,(44-frame.size.height)/2));
        if (!CGRectContainsPoint(hit,p) || CGRectIsEmpty(frame)) continue;
        if (!nearest) return button[@"id"];
        CGFloat dx=(p.x-CGRectGetMidX(frame))/MAX(1,hit.size.width), dy=(p.y-CGRectGetMidY(frame))/MAX(1,hit.size.height), d=dx*dx+dy*dy;
        if (d<distance) { distance=d; best=button[@"id"]; }
    }
    return best;
}
- (CGRect)activationForStick:(NSDictionary *)stick safeRect:(CGRect)rect {
    CGRect n = normalized_rect(stick[@"activation"]);
    return CGRectMake(rect.origin.x + n.origin.x * rect.size.width, rect.origin.y + n.origin.y * rect.size.height,
                      n.size.width * rect.size.width, n.size.height * rect.size.height);
}
- (CGFloat)radiusForStick:(NSDictionary *)stick safeRect:(CGRect)rect {
    return [stick[@"radius"] doubleValue] * MIN(rect.size.width, rect.size.height);
}
- (NSData *)JSONData:(NSError **)error {
    return [NSJSONSerialization dataWithJSONObject:_document options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error];
}
@end

BOOL S2AVPadHapticStep(S2AVPadHapticState *state, uint32_t buttons, uint8_t activeSticks, uint8_t edgeSticks, BOOL enabled) {
    activeSticks &= 3; edgeSticks &= activeSticks;
    state->reachedEdges &= activeSticks;
    BOOL pulse = (buttons & ~state->buttons) || (edgeSticks & ~state->reachedEdges);
    state->buttons = buttons; state->reachedEdges |= edgeSticks;
    return enabled && pulse;
}

uint32_t S2AVPadHoldLockStep(S2AVPadHoldLockState *state, uint32_t held, uint32_t lockable, double now, BOOL enabled) {
    if (!enabled) { *state = (S2AVPadHoldLockState){0}; return 0; }
    held &= lockable & 0xFFFF;
    uint32_t before = state->locked, down = held & ~state->held, up = state->held & ~held;
    // 先结算满 2 秒：主线程卡顿时定时器可能排在抬手之后，手指按够了就算数
    for (int i = 0; i < 16; i++) if ((state->held & ~state->locked) >> i & 1 && now - state->downAt[i] >= kS2AVPadHoldLockSeconds) state->locked |= 1u << i;
    for (int i = 0; i < 16; i++) if (down >> i & 1) { if (state->locked >> i & 1) state->unlocking |= 1u << i; else state->downAt[i] = now; }
    state->locked &= ~(up & state->unlocking); state->unlocking &= ~up; state->held = held;
    return before ^ state->locked;
}
double S2AVPadHoldLockDeadline(const S2AVPadHoldLockState *state) {
    double due = 0;
    for (int i = 0; i < 16; i++) if ((state->held & ~state->locked) >> i & 1) {
        double t = state->downAt[i] + kS2AVPadHoldLockSeconds; if (due == 0 || t < due) due = t;
    }
    return due;
}

static BOOL stick_values(CGFloat deadzone, CGFloat saturation, CGFloat exponent) {
    return isfinite(deadzone) && deadzone >= 0 && deadzone <= .4 &&
        isfinite(saturation) && saturation >= .5 && saturation <= 1 &&
        isfinite(exponent) && exponent >= .5 && exponent <= 3;
}
CGPoint S2AVPadStickSensitivity(CGPoint input, CGFloat sensitivity) {
    CGFloat x = input.x * sensitivity, y = input.y * sensitivity, m = hypot(x, y);
    return m > 1 ? CGPointMake(x / m, y / m) : CGPointMake(x, y);
}
CGPoint S2AVPadStickResponse(CGPoint input, CGFloat deadzone, CGFloat saturation, CGFloat exponent) {
    CGFloat radius = hypot(input.x, input.y);
    if (!isfinite(radius) || radius <= deadzone || !stick_values(deadzone, saturation, exponent)) return CGPointZero;
    CGFloat length = pow(MIN(1, (radius - deadzone) / (saturation - deadzone)), exponent);
    return CGPointMake(input.x / radius * length, input.y / radius * length);
}

// {schemaVersion:1, enabled:布尔} 的小文件。1 = 读到，0 = 没有文件，-1 = 损坏
static int read_enabled(NSURL *file, BOOL *enabled) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:file.path]) return 0;
    NSDictionary *attributes = [fm attributesOfItemAtPath:file.path error:nil];
    NSData *data = nil;
    if ([attributes[NSFileType] isEqualToString:NSFileTypeRegular] && [attributes[NSFileSize] unsignedLongLongValue] <= 4096)
        data = [NSData dataWithContentsOfURL:file options:0 error:nil];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (!fields(value, @[@"schemaVersion", @"enabled"]) || !number(value[@"schemaVersion"], 1, 1) ||
        ![value[@"enabled"] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value[@"enabled"]) != CFBooleanGetTypeID()) return -1;
    *enabled = [value[@"enabled"] boolValue]; return 1;
}

@implementation S2AVPadLayoutStore {
    S2AVPadLayoutStore *_commonStore;
    NSString *_splitKeys;
    NSString *_selectionProblem;
    NSString *_hapticProblem;
    NSString *_holdLockProblem;
    NSString *_keyStyleProblem;
    NSString *_stickModeProblem;
    CGPoint _stickCenters[2];
    NSMutableDictionary<NSString *, NSDictionary *> *_keyStyles;

    NSString *_stickProblem;
    NSString *_visibilityProblem;
}
- (instancetype)initWithDirectory:(NSURL *)directory { return [self initWithDirectory:directory settingsDirectory:directory]; }
- (BOOL)split { return _commonStore!=nil; }
- (instancetype)initWithDirectory:(NSURL *)directory settingsDirectory:(NSURL *)settingsDirectory split:(BOOL)split {
    self=[self initWithDirectory:split ? [directory URLByAppendingPathComponent:@"split" isDirectory:YES] : directory settingsDirectory:settingsDirectory];
    if (self && split) {
        _commonStore=[[S2AVPadLayoutStore alloc] initWithDirectory:directory settingsDirectory:settingsDirectory];
        _splitKeys=_selectedIdentifier;
        if ([_commonStore.selectedIdentifier isEqualToString:S2AVPadLayoutTouchIdentifier]) _selectedIdentifier=S2AVPadLayoutTouchIdentifier;
        _manualChosen=_commonStore.manualChosen; _holdLockEnabled=_commonStore.holdLockEnabled; _holdLockProblem=_commonStore->_holdLockProblem;
    }
    return self;
}
- (instancetype)initWithDirectory:(NSURL *)directory settingsDirectory:(NSURL *)settingsDirectory {
    if (!(self = [super init])) return nil;
    _directory = [directory copy]; _settingsDirectory = [settingsDirectory copy]; _selectedIdentifier = S2AVPadLayoutDefaultIdentifier; _diagnostics = @[];
    _hapticFeedbackEnabled = YES;
    if (read_enabled([_settingsDirectory URLByAppendingPathComponent:@".haptics.json"], &_hapticFeedbackEnabled) < 0)
        _hapticProblem = [NSString stringWithFormat:S2AL(@"vpad.layout.error"), @"F01.haptics", S2AL(@"vpad.layout.problem.haptics")];
    _holdLockEnabled = YES;
    if (read_enabled([_directory URLByAppendingPathComponent:@".hold_lock.json"], &_holdLockEnabled) < 0)
        _holdLockProblem = [NSString stringWithFormat:S2AL(@"vpad.layout.error"), @"F01.holdLock", S2AL(@"vpad.layout.problem.holdLock")];
    [self loadKeyStyles]; [self loadStickMode];
    _idleKeyOpacity = 0.25;
    NSURL *visibility = [_settingsDirectory URLByAppendingPathComponent:@".visibility.json"];
    if ([NSFileManager.defaultManager fileExistsAtPath:visibility.path]) {
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:visibility.path error:nil];
        NSData *data = nil;
        if ([attributes[NSFileType] isEqualToString:NSFileTypeRegular] && [attributes[NSFileSize] unsignedLongLongValue] <= 4096)
            data = [NSData dataWithContentsOfURL:visibility];
        id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (fields(value, @[@"schemaVersion", @"idleKeyOpacity"]) && number(value[@"schemaVersion"], 1, 1) && number(value[@"idleKeyOpacity"], 0, 1))
            _idleKeyOpacity = [value[@"idleKeyOpacity"] doubleValue];
        else _visibilityProblem = [NSString stringWithFormat:S2AL(@"vpad.layout.error"), @"F01.visibility", S2AL(@"vpad.layout.problem.visibility")];
    }
    NSURL *url = [_directory URLByAppendingPathComponent:@".selection.json"];
    if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) {
        NSError *error;
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:&error];
        NSData *data = nil;
        if ([attributes[NSFileType] isEqualToString:NSFileTypeRegular] && [attributes[NSFileSize] unsignedLongLongValue] <= 4096)
            data = [NSData dataWithContentsOfURL:url options:0 error:&error];
        id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        if (fields(value, @[@"schemaVersion", @"id"]) && number(value[@"schemaVersion"], 1, 1) && identifier_ok(value[@"id"]))
            _selectedIdentifier = [value[@"id"] copy];
        else _selectionProblem = [NSString stringWithFormat:S2AL(@"vpad.layout.error"), @"F01.selection", S2AL(@"vpad.layout.problem.selection")];
    }
    _stickDeadzone = .08; _stickSaturation = _stickExponent = 1;
    NSURL *stickURL = [_settingsDirectory URLByAppendingPathComponent:@".stick.json"];
    if ([NSFileManager.defaultManager fileExistsAtPath:stickURL.path]) {
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:stickURL.path error:nil];
        NSData *data = nil;
        if ([attributes[NSFileType] isEqualToString:NSFileTypeRegular] && [attributes[NSFileSize] unsignedLongLongValue] <= 4096)
            data = [NSData dataWithContentsOfURL:stickURL options:0 error:nil];
        id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (fields(value, @[@"schemaVersion", @"deadzone", @"saturation", @"exponent"]) &&
            number(value[@"schemaVersion"], 1, 1) && number(value[@"deadzone"], 0, .4) &&
            number(value[@"saturation"], .5, 1) && number(value[@"exponent"], .5, 3)) {
            _stickDeadzone = [value[@"deadzone"] doubleValue]; _stickSaturation = [value[@"saturation"] doubleValue]; _stickExponent = [value[@"exponent"] doubleValue];
        } else _stickProblem = [NSString stringWithFormat:S2AL(@"vpad.layout.error"), @"F01.stick", S2AL(@"vpad.layout.problem.stick")];
    }
    _manualChosen = [NSFileManager.defaultManager fileExistsAtPath:[_directory URLByAppendingPathComponent:@".manual"].path];
    return self;
}
- (NSURL *)urlForIdentifier:(NSString *)identifier {
    return [_directory URLByAppendingPathComponent:[identifier stringByAppendingString:@".json"]];
}
- (S2AVPadLayout *)readIdentifier:(NSString *)identifier error:(NSError **)error {
    NSURL *url = [self urlForIdentifier:identifier];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:error];
    if (!attributes) return nil;
    if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] > 65536) {
        fail(error, @"F01.file", S2AL(@"vpad.layout.err.file")); return nil;
    }
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    S2AVPadLayout *layout = data ? [S2AVPadLayout readData:data error:error] : nil;
    if (layout && ![layout.identifier isEqualToString:identifier]) {
        fail(error, @"F01.identity", S2AL(@"vpad.layout.err.fileName")); return nil;
    }
    return layout;
}
- (NSArray<S2AVPadLayout *> *)layouts {
    NSMutableArray *result = [NSMutableArray array], *problems = [NSMutableArray array];
    if (_selectionProblem) [problems addObject:_selectionProblem];
    if (_hapticProblem) [problems addObject:_hapticProblem];
    if (_holdLockProblem) [problems addObject:_holdLockProblem];
    if (_keyStyleProblem) [problems addObject:_keyStyleProblem];
    if (_stickModeProblem) [problems addObject:_stickModeProblem];
    if (_stickProblem) [problems addObject:_stickProblem];
    if (_visibilityProblem) [problems addObject:_visibilityProblem];
    NSError *error; NSArray *urls = [NSFileManager.defaultManager contentsOfDirectoryAtURL:_directory includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:&error];
    if (!urls && error.code != NSFileReadNoSuchFileError) [problems addObject:error.localizedDescription];
    for (NSURL *url in [urls sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.lastPathComponent compare:b.lastPathComponent]; }]) {
        if (![url.pathExtension.lowercaseString isEqualToString:@"json"]) continue;
        NSString *identifier = url.lastPathComponent.stringByDeletingPathExtension;
        if (!identifier_ok(identifier) || [S2AVPadLayout isBuiltinIdentifier:identifier]) { [problems addObject:[NSString stringWithFormat:S2AL(@"vpad.layout.error"), @"F01.identity", S2AL(@"vpad.layout.problem.reservedName")]]; continue; }
        error = nil; S2AVPadLayout *layout = [self readIdentifier:identifier error:&error];
        if (layout) [result addObject:layout]; else [problems addObject:[NSString stringWithFormat:S2AL(@"vpad.layout.error"), url.lastPathComponent, error.localizedDescription]];
    }
    if (![S2AVPadLayout isBuiltinIdentifier:_selectedIdentifier] &&
        ![[result valueForKey:@"identifier"] containsObject:_selectedIdentifier])
        [problems addObject:[NSString stringWithFormat:S2AL(@"vpad.layout.error"), @"F01.selection", S2AL(@"vpad.layout.problem.selectionMissing")]];
    _diagnostics = [problems copy]; return result;
}
- (S2AVPadLayout *)selectedLayout:(NSError **)error {
    if (_selectionProblem) { fail(error, @"F01.selection", _selectionProblem); return nil; }
    if ([S2AVPadLayout isBuiltinIdentifier:_selectedIdentifier]) return nil;
    return [self readIdentifier:_selectedIdentifier error:error];
}
- (BOOL)prepareDirectory:(NSError **)error {
    return [NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES attributes:nil error:error];
}
- (BOOL)prepareSettingsDirectory:(NSError **)error {
    return [NSFileManager.defaultManager createDirectoryAtURL:_settingsDirectory withIntermediateDirectories:YES attributes:nil error:error];
}
- (BOOL)replaceLayout:(S2AVPadLayout *)layout error:(NSError **)error {
    if ([S2AVPadLayout isBuiltinIdentifier:layout.identifier]) return fail(error, @"F01.identity", S2AL(@"vpad.layout.err.builtin"));
    NSData *data = [layout JSONData:error];
    if (!data || ![S2AVPadLayout readData:data error:error] || ![self prepareDirectory:error]) return NO;
    return [data writeToURL:[self urlForIdentifier:layout.identifier] options:NSDataWritingAtomic error:error];   // 原子替换：看得见的文件总是完整的
}
- (BOOL)setHapticFeedbackEnabled:(BOOL)enabled error:(NSError **)error {
    if (![self prepareSettingsDirectory:error]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion": @1, @"enabled": (enabled ? @YES : @NO)} options:0 error:error];
    if (!data || ![data writeToURL:[_settingsDirectory URLByAppendingPathComponent:@".haptics.json"] options:NSDataWritingAtomic error:error]) return NO;
    _hapticFeedbackEnabled = enabled; _hapticProblem = nil; return YES;
}
- (BOOL)setHoldLockEnabled:(BOOL)enabled error:(NSError **)error {
    if (_commonStore) {
        if (![_commonStore setHoldLockEnabled:enabled error:error]) return NO;
        _holdLockEnabled=enabled; _holdLockProblem=nil; return YES;
    }
    if (![self prepareDirectory:error]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion": @1, @"enabled": (enabled ? @YES : @NO)} options:0 error:error];
    if (!data || ![data writeToURL:[_directory URLByAppendingPathComponent:@".hold_lock.json"] options:NSDataWritingAtomic error:error]) return NO;
    _holdLockEnabled = enabled; _holdLockProblem = nil; return YES;
}
- (NSURL *)stickModeFile { return [_directory URLByAppendingPathComponent:@".stick_mode.json"]; }
- (void)loadStickMode {
    _stickFixed = NO; _stickSensitivity = 1; _stickCenters[0] = CGPointMake(0.12, 0.66); _stickCenters[1] = CGPointMake(0.63, 0.66);
    NSData *data = [NSData dataWithContentsOfURL:self.stickModeFile];
    if (!data) return;
    id doc = data.length <= 4096 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (!fields(doc, @[@"schemaVersion", @"fixed", @"sensitivity", @"left", @"right"]) || !number(doc[@"schemaVersion"], 1, 1) || !number(doc[@"sensitivity"], 0.5, 2) || ![doc[@"fixed"] isKindOfClass:NSNumber.class]) {
        _stickModeProblem = [NSString stringWithFormat:S2AL(@"vpad.layout.error"), @"F01.stickMode", S2AL(@"vpad.layout.problem.stickMode")]; return; }
    NSArray *names = @[@"left", @"right"];
    for (int i = 0; i < 2; i++) { NSArray *p = doc[names[i]];
        if (![p isKindOfClass:NSArray.class] || p.count != 2 || !number(p[0], 0, 1) || !number(p[1], 0, 1)) { _stickModeProblem = [NSString stringWithFormat:S2AL(@"vpad.layout.error"), @"F01.stickMode", S2AL(@"vpad.layout.problem.stickMode")]; return; } }
    _stickFixed = [doc[@"fixed"] boolValue]; _stickSensitivity = [doc[@"sensitivity"] doubleValue];
    for (int i = 0; i < 2; i++) { NSArray *p = doc[names[i]]; _stickCenters[i] = CGPointMake([p[0] doubleValue], [p[1] doubleValue]); }
}
- (BOOL)saveStickMode:(NSError **)error {
    if (![self prepareDirectory:error]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion": @1, @"fixed": @(_stickFixed), @"sensitivity": @(_stickSensitivity),
        @"left": @[@(_stickCenters[0].x), @(_stickCenters[0].y)], @"right": @[@(_stickCenters[1].x), @(_stickCenters[1].y)]} options:0 error:error];
    if (!data || ![data writeToURL:self.stickModeFile options:NSDataWritingAtomic error:error]) return NO;
    _stickModeProblem = nil; return YES;
}
- (CGPoint)stickCenter:(int)side { return _stickCenters[side ? 1 : 0]; }
- (BOOL)setStickFixed:(BOOL)fixed sensitivity:(CGFloat)sensitivity error:(NSError **)error {
    if (!isfinite(sensitivity) || sensitivity < 0.5 || sensitivity > 2) return fail(error, @"F01.stickMode", S2AL(@"vpad.layout.err.sensitivity"));
    _stickFixed = fixed; _stickSensitivity = sensitivity; return [self saveStickMode:error];
}
- (BOOL)setStickCenter:(CGPoint)center side:(int)side error:(NSError **)error {
    if (!isfinite(center.x) || !isfinite(center.y) || center.x < 0 || center.x > 1 || center.y < 0 || center.y > 1) return fail(error, @"F01.stickMode", S2AL(@"vpad.layout.err.stickOffscreen"));
    _stickCenters[side ? 1 : 0] = center; return [self saveStickMode:error];
}
// 界面滑杆是单精度：拉到头的 1.6f 换成双精度是 1.6000000238，越过上限一点点就被拒（#372 iPad 上按键调到最大存不上）。
//   存之前按界面精度 0.001 取整，再按原范围校验；文件格式与范围都不变
static S2AVPadKeyStyle key_style_snapped(S2AVPadKeyStyle s) {
    if (isfinite(s.scale)) s.scale = round(s.scale * 1000) / 1000;
    if (isfinite(s.opacity)) s.opacity = round(s.opacity * 1000) / 1000;
    return s;
}
static BOOL key_style_valid(S2AVPadKeyStyle s) {
    return isfinite(s.scale) && isfinite(s.opacity) && s.scale >= 0.6 && s.scale <= 1.6 && s.opacity >= 0.2 && s.opacity <= 1;
}
- (NSURL *)keyStyleFile { return [_directory URLByAppendingPathComponent:@".key_style.json"]; }
- (void)loadKeyStyles {
    _keyStyles = [NSMutableDictionary dictionary]; _keyTheme = 0; _globalScale = _globalOpacity = 1;
    NSData *data = [NSData dataWithContentsOfURL:self.keyStyleFile];
    id doc = data.length && data.length <= 65536 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (!doc) return;
    if (!fields(doc, @[@"schemaVersion", @"theme", @"keys", @"globalScale", @"globalOpacity"]) || !number(doc[@"schemaVersion"], 1, 1) || !number(doc[@"theme"], 0, kS2AVPadKeyThemeCount - 1) || !number(doc[@"globalScale"], 0.6, 1.6) || !number(doc[@"globalOpacity"], 0.2, 1) || ![doc[@"keys"] isKindOfClass:NSDictionary.class]) {
        _keyStyleProblem = [NSString stringWithFormat:S2AL(@"vpad.layout.error"), @"F01.keyStyle", S2AL(@"vpad.layout.problem.keyStyle")]; return; }
    for (NSString *key in doc[@"keys"]) {
        NSDictionary *v = doc[@"keys"][key];
        if (!fields(v, @[@"scale", @"opacity", @"hidden"]) || !number(v[@"scale"], 0.6, 1.6) || !number(v[@"opacity"], 0.2, 1) || ![v[@"hidden"] isKindOfClass:NSNumber.class]) {
            _keyStyles = [NSMutableDictionary dictionary]; _keyStyleProblem = [NSString stringWithFormat:S2AL(@"vpad.layout.error"), @"F01.keyStyle", S2AL(@"vpad.layout.problem.keyStyle")]; return; }
        _keyStyles[key] = v;
    }
    _keyTheme = [doc[@"theme"] integerValue]; _globalScale = [doc[@"globalScale"] doubleValue]; _globalOpacity = [doc[@"globalOpacity"] doubleValue];
}
- (BOOL)saveKeyStyles:(NSError **)error {
    if (![self prepareDirectory:error]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion": @1, @"theme": @(_keyTheme), @"keys": _keyStyles, @"globalScale": @(_globalScale), @"globalOpacity": @(_globalOpacity)} options:0 error:error];
    if (!data || ![data writeToURL:self.keyStyleFile options:NSDataWritingAtomic error:error]) return NO;
    _keyStyleProblem = nil; return YES;
}
- (S2AVPadKeyStyle)keyStyle:(NSString *)identifier {
    NSDictionary *v = _keyStyles[identifier];
    return v ? (S2AVPadKeyStyle){[v[@"scale"] doubleValue], [v[@"opacity"] doubleValue], [v[@"hidden"] boolValue]} : (S2AVPadKeyStyle){1, 1, NO};
}
- (BOOL)setKeyStyle:(S2AVPadKeyStyle)style forKey:(NSString *)identifier persist:(BOOL)persist error:(NSError **)error {
    style = key_style_snapped(style);
    if (!key_style_valid(style)) return fail(error, @"F01.keyStyle", S2AL(@"vpad.layout.err.keyStyle"));
    _keyStyles[identifier] = @{@"scale": @(style.scale), @"opacity": @(style.opacity), @"hidden": @(style.hidden)};
    return persist ? [self saveKeyStyles:error] : YES;
}
- (BOOL)setKeyTheme:(NSInteger)theme error:(NSError **)error {
    if (theme < 0 || theme >= kS2AVPadKeyThemeCount) return fail(error, @"F01.keyStyle", S2AL(@"vpad.layout.err.theme"));
    _keyTheme = theme; return [self saveKeyStyles:error];
}
- (BOOL)setGlobalScale:(CGFloat)scale opacity:(CGFloat)opacity persist:(BOOL)persist error:(NSError **)error {
    S2AVPadKeyStyle check = key_style_snapped((S2AVPadKeyStyle){scale, opacity, NO});
    if (!key_style_valid(check)) return fail(error, @"F01.keyStyle", S2AL(@"vpad.layout.err.keyStyle"));
    _globalScale = check.scale; _globalOpacity = check.opacity; return persist ? [self saveKeyStyles:error] : YES;
}
- (BOOL)resetKeyStyles:(NSError **)error { _keyStyles = [NSMutableDictionary dictionary]; _keyTheme = 0; _globalScale = _globalOpacity = 1; return [self saveKeyStyles:error]; }
- (NSDictionary<NSString *, NSNumber *> *)keyScalesIncludingHidden:(BOOL)includeHidden {
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithObject:@(_globalScale) forKey:@"*"];
    for (NSString *key in _keyStyles) { S2AVPadKeyStyle s = [self keyStyle:key]; out[key] = @(s.hidden && !includeHidden ? 0 : s.scale * _globalScale); }
    return out;
}
- (NSDictionary *)keyStyleSnapshot { return @{@"theme": @(_keyTheme), @"globalScale": @(_globalScale), @"globalOpacity": @(_globalOpacity), @"keys": [[NSDictionary alloc] initWithDictionary:_keyStyles copyItems:YES]}; }
- (BOOL)restoreKeyStyleSnapshot:(NSDictionary *)snapshot error:(NSError **)error {
    _keyTheme = [snapshot[@"theme"] integerValue]; _globalScale = [snapshot[@"globalScale"] doubleValue]; _globalOpacity = [snapshot[@"globalOpacity"] doubleValue]; _keyStyles = [snapshot[@"keys"] mutableCopy]; return [self saveKeyStyles:error];
}
- (BOOL)setStickDeadzone:(CGFloat)deadzone saturation:(CGFloat)saturation exponent:(CGFloat)exponent error:(NSError **)error {
    if (!stick_values(deadzone, saturation, exponent)) return fail(error, @"F01.stick", S2AL(@"vpad.layout.err.stickValues"));
    if (![self prepareSettingsDirectory:error]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion": @1, @"deadzone": @(deadzone), @"saturation": @(saturation), @"exponent": @(exponent)} options:0 error:error];
    if (!data || ![data writeToURL:[_settingsDirectory URLByAppendingPathComponent:@".stick.json"] options:NSDataWritingAtomic error:error]) return NO;
    _stickDeadzone = deadzone; _stickSaturation = saturation; _stickExponent = exponent; _stickProblem = nil;
    return YES;
}
- (BOOL)setIdleKeyOpacity:(CGFloat)opacity error:(NSError **)error {
    if (!number(@(opacity), 0, 1)) return fail(error, @"F01.visibility", S2AL(@"vpad.layout.err.idleOpacity"));
    if (![self prepareSettingsDirectory:error]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion": @1, @"idleKeyOpacity": @(opacity)} options:0 error:error];
    if (!data || ![data writeToURL:[_settingsDirectory URLByAppendingPathComponent:@".visibility.json"] options:NSDataWritingAtomic error:error]) return NO;
    _idleKeyOpacity = opacity; _visibilityProblem = nil; return YES;
}
- (BOOL)saveLayout:(S2AVPadLayout *)layout error:(NSError **)error {
    if ([S2AVPadLayout isBuiltinIdentifier:layout.identifier]) return fail(error, @"F01.identity", S2AL(@"vpad.layout.err.builtin"));
    NSData *data = [layout JSONData:error];
    if (!data || ![S2AVPadLayout readData:data error:error] || ![self prepareDirectory:error]) return NO;
    NSURL *url = [self urlForIdentifier:layout.identifier];
    if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) return fail(error, @"F01.exists", S2AL(@"vpad.layout.err.exists"));
    NSURL *temporary = [_directory URLByAppendingPathComponent:[@".import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![data writeToURL:temporary options:NSDataWritingAtomic error:error]) return NO;
    // moveItem refuses an existing destination; the visible file is always complete.
    BOOL ok = [NSFileManager.defaultManager moveItemAtURL:temporary toURL:url error:error];
    if (!ok) [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
    return ok;
}
- (BOOL)selectIdentifier:(NSString *)identifier error:(NSError **)error {
    if (_commonStore) _commonStore=[[S2AVPadLayoutStore alloc] initWithDirectory:_commonStore.directory settingsDirectory:_settingsDirectory];
    if (_commonStore && [identifier isEqualToString:S2AVPadLayoutTouchIdentifier]) return [self setTouchOnly:YES error:error]>=0;
    if (!identifier_ok(identifier)) return fail(error, @"F01.identity", S2AL(@"vpad.layout.err.id"));
    if (![S2AVPadLayout isBuiltinIdentifier:identifier] && ![self readIdentifier:identifier error:error]) return NO;
    if (![self prepareDirectory:error]) return NO;
    NSURL *selection=[_directory URLByAppendingPathComponent:@".selection.json"];
    NSData *before=_commonStore ? [NSData dataWithContentsOfURL:selection] : nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion": @1, @"id": identifier} options:0 error:error];
    if (![data writeToURL:[_directory URLByAppendingPathComponent:@".selection.json"] options:NSDataWritingAtomic error:error]) return NO;
    if (_commonStore && [_commonStore setTouchOnly:NO error:error]<0) {
        if (before) [before writeToURL:selection options:NSDataWritingAtomic error:nil]; else [NSFileManager.defaultManager removeItemAtURL:selection error:nil];
        return NO;
    }
    if (_commonStore) _splitKeys=[identifier copy];
    _selectedIdentifier = [identifier copy]; _selectionProblem = nil; return YES;
}
- (BOOL)markManual:(NSError **)error {
    if (_commonStore) { BOOL ok=[_commonStore markManual:error]; if (ok) _manualChosen=YES; return ok; }
    if (_manualChosen) return YES;
    if (![self prepareDirectory:error]) return NO;
    if (![[NSData data] writeToURL:[_directory URLByAppendingPathComponent:@".manual"] options:NSDataWritingAtomic error:error]) return NO;
    _manualChosen = YES; return YES;
}
- (NSURL *)lastKeysURL { return [_directory URLByAppendingPathComponent:@".last_keys.json"]; }
- (NSString *)lastKeysIdentifier {   // 记下的按键方案；读不到 / 坏了 / 已失效 → default
    NSData *data = [NSData dataWithContentsOfURL:[self lastKeysURL] options:0 error:nil];
    id value = data.length <= 4096 && data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *identifier = fields(value, @[@"schemaVersion", @"id"]) && number(value[@"schemaVersion"], 1, 1) && identifier_ok(value[@"id"]) ? value[@"id"] : nil;
    if (!identifier || [identifier isEqualToString:S2AVPadLayoutTouchIdentifier]) return S2AVPadLayoutDefaultIdentifier;
    if (![S2AVPadLayout isBuiltinIdentifier:identifier] && ![self readIdentifier:identifier error:nil]) return S2AVPadLayoutDefaultIdentifier;
    return identifier;
}
- (int)setTouchOnly:(BOOL)on error:(NSError **)error {
    if (_commonStore) {
        // 编辑器和游戏内各有 store；切模式前现读共用选择，不能把另一份刚保存的布局覆盖成旧缓存。
        _commonStore=[[S2AVPadLayoutStore alloc] initWithDirectory:_commonStore.directory settingsDirectory:_settingsDirectory];
        int r=[_commonStore setTouchOnly:on error:error];
        if (r>=0) _selectedIdentifier=on ? S2AVPadLayoutTouchIdentifier : _splitKeys;
        return r;
    }
    BOOL now = !_selectionProblem && [_selectedIdentifier isEqualToString:S2AVPadLayoutTouchIdentifier];
    if (now == on) return 0;
    if (on) {
        // 切走前的按键方案（选择记录坏了时 _selectedIdentifier 仍是 default，照记 default）
        if (![self prepareDirectory:error]) return -1;
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion": @1, @"id": _selectedIdentifier} options:0 error:error];
        if (!data || ![data writeToURL:[self lastKeysURL] options:NSDataWritingAtomic error:error]) return -1;
        return [self selectIdentifier:S2AVPadLayoutTouchIdentifier error:error] ? 1 : -1;
    }
    return [self selectIdentifier:[self lastKeysIdentifier] error:error] ? 1 : -1;
}
@end
