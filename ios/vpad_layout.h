// F01 layout format and per-app storage. Foundation-only; all callers use the main thread.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
// 内置选项：都不对应磁盘上的 JSON。"default" 按当前安全区现算；"touch" 不画任何虚拟按键，
// 所有手指直接写进 Hid.Touchscreen（游戏自带的触屏 UI），两者在列表里并列。
extern NSString *const S2AVPadLayoutDefaultIdentifier;
extern NSString *const S2AVPadLayoutTouchIdentifier;
// "2d"（#268，11-09 维护者定稿 cmdr/assets/268_vpad_2d_对比_1109.png）：横版 / 像素游戏用。十字键放大到左拇指落点、可按斜角，ABXY 放大，
//   没有摇杆和 L3 / R3（左半屏不再抢触点）；同 default 按安全区现算，不对应磁盘文件
extern NSString *const S2AVPadLayout2DIdentifier;
// Rendering targets shared by UIKit and host tests; idle must be in [0, 1].
CGFloat S2AVPadKeyOpacity(CGFloat idle, BOOL active);

@interface S2AVPadLayout : NSObject
@property(nonatomic, readonly, copy) NSDictionary *document;
@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly, copy) NSString *name;
// 显示用名字（#316）：默认布局与「我的布局」的 name 是建档时按当时语言写进文件的，显示按当前语言取；其余是玩家自己起的名字，原样
@property(nonatomic, readonly, copy) NSString *displayName;
@property(nonatomic, readonly, copy) NSArray<NSDictionary *> *buttons;
@property(nonatomic, readonly, copy) NSArray<NSDictionary *> *sticks;
// 布局文件里可选的按键外观（keyStyles：theme / globalScale / globalOpacity / keys，#2303）；没有为 nil
@property(nonatomic, readonly, copy, nullable) NSDictionary *keyStyles;
+ (nullable instancetype)readData:(NSData *)data error:(NSError **)error;
// The built-in layout keeps the historical point geometry at each viewport size.
+ (instancetype)defaultForSafeRect:(CGRect)rect;
+ (instancetype)defaultForSafeRect:(CGRect)rect split:(BOOL)split;
+ (instancetype)twoDForSafeRect:(CGRect)rect;
// 八方向十字键（没有摇杆的布局，即 2D 和从它改出来的）：触点落在十字键圆区内 → 方向位（上 1 / 下 2 / 左 4 / 右 8，斜角两位），
//   圆区外或有摇杆的布局 → -1。圆心 = 四个方向键中心的平均，半径 = 最远方向键中心 + 半个键宽；正中心一小圈（半径 0.2）不算方向
- (int)dpadDirectionsAt:(CGPoint)p safeRect:(CGRect)rect;
+ (BOOL)isBuiltinIdentifier:(NSString *)identifier;
- (CGRect)frameForButton:(NSDictionary *)button safeRect:(CGRect)rect;
- (CGRect)frameForButton:(NSDictionary *)button safeRect:(CGRect)rect avoiding:(CGRect)division;
- (CGRect)frameForButton:(NSDictionary *)button safeRect:(CGRect)rect avoiding:(CGRect)division scale:(CGFloat)scale;
// 触点落在哪个按键上（各键框外扩 slop 点，重叠处按 buttons 顺序取第一个）；没有返回 nil。vpad.m keyAt 用它，单测 t_vpad_stick_press 直接调
- (nullable NSString *)buttonAt:(CGPoint)p safeRect:(CGRect)rect slop:(CGFloat)slop;
// 同上，按每键缩放算框（绕键中心）；scales 里值为 0 的键不参与（隐藏），没列出的键取 scales[@"*"]，再没有按 1
- (nullable NSString *)buttonAt:(CGPoint)p safeRect:(CGRect)rect slop:(CGFloat)slop scales:(nullable NSDictionary<NSString *, NSNumber *> *)scales;
- (nullable NSString *)buttonAt:(CGPoint)p safeRect:(CGRect)rect slop:(CGFloat)slop avoiding:(CGRect)division nearest:(BOOL)nearest;
- (nullable NSString *)buttonAt:(CGPoint)p safeRect:(CGRect)rect slop:(CGFloat)slop avoiding:(CGRect)division nearest:(BOOL)nearest scales:(nullable NSDictionary<NSString *, NSNumber *> *)scales;
- (CGRect)activationForStick:(NSDictionary *)stick safeRect:(CGRect)rect;
- (CGFloat)radiusForStick:(NSDictionary *)stick safeRect:(CGRect)rect;
- (nullable NSData *)JSONData:(NSError **)error;
// 拖动编辑（按游戏自定义位置）：按键中心换成 centers（与 safeRect 同一坐标系的点 @[x, y]，键为按键 id），其余字段照旧；
//   新 id / 名称，越出安全区的中心钳到 [0,1]。生成后按生产校验重读，不合法返回 nil
- (nullable instancetype)layoutWithButtonCenters:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)centers safeRect:(CGRect)rect
                                       identifier:(NSString *)identifier name:(NSString *)name error:(NSError **)error;
@end
// 拖动编辑存下的方案 id（每款游戏一份，覆盖保存）
extern NSString *const S2AVPadLayoutMineIdentifier;

// 浮动摇杆「点按 = 按下摇杆」（LS / RS）：按住不超过 kS2AVPadStickTapSeconds、全程离按下点不超过 kS2AVPadStickTapMove 点，抬手时发一次按下
//   （pad.c 短按锁存保证 HID 下一拍读得到）。推摇杆总会离开中心或按得更久，不会误判
static const double kS2AVPadStickTapSeconds = 0.25;
static const double kS2AVPadStickTapMove = 10;
static inline BOOL S2AVPadStickTapIsPress(double held, double maxMove) {
    return held >= 0 && held <= kS2AVPadStickTapSeconds && maxMove <= kS2AVPadStickTapMove;
}

// 主线程触屏快照：按键上升沿 + 每根摇杆本次触点首次到边；一次快照最多请求一次轻反馈。
// activeSticks / edgeSticks 的位 0 / 1 分别是左 / 右杆。清触点时整份状态归零。
typedef struct { uint32_t buttons; uint8_t reachedEdges; } S2AVPadHapticState;
BOOL S2AVPadHapticStep(S2AVPadHapticState *state, uint32_t buttons, uint8_t activeSticks, uint8_t edgeSticks, BOOL enabled);

// ZL / ZR 按住锁定：held 是手指此刻按着的位，发给游戏的是 held | locked。按住满 2 秒切成锁定，锁定后再点一下、抬手时解锁，
//   手指按着期间已发按键不变。now 单调秒数；返回本拍切换的位（调用方据此反馈）；enabled = NO 立即清空且不算切换。
static const double kS2AVPadHoldLockSeconds = 2;
typedef struct { uint32_t held, locked, unlocking; double downAt[16]; } S2AVPadHoldLockState;
uint32_t S2AVPadHoldLockStep(S2AVPadHoldLockState *state, uint32_t held, uint32_t lockable, double now, BOOL enabled);
// 下一次要检查的时刻（最早的「按着、没锁」键满 2 秒）；没有返回 0。手指不动时没有触屏事件，靠它定时。
double S2AVPadHoldLockDeadline(const S2AVPadHoldLockState *state);

// 输入为相对落点 / 摇杆半径的 UIKit 坐标；返回单位圆内的同向值，Y 翻转由调用方处理。
// t = clamp((length - deadzone) / (saturation - deadzone), 0, 1)，输出长度 t^exponent。
CGPoint S2AVPadStickResponse(CGPoint input, CGFloat deadzone, CGFloat saturation, CGFloat exponent);
// 灵敏度：先把手指相对半径的位移乘 sensitivity，再钳到单位圆内。sensitivity = 1 与不调用相同
CGPoint S2AVPadStickSensitivity(CGPoint input, CGFloat sensitivity);

// 大小倍率范围（每键与整体同一范围）：上限原 1.6，#372 连打类游戏要更大的键，放到 4（文件格式不变，旧存档照读）
#define S2A_VPAD_SCALE_MIN 0.6
#define S2A_VPAD_SCALE_MAX 4.0
// 每键外观：大小倍率 S2A_VPAD_SCALE_MIN–MAX、不透明度 0.2–1、是否隐藏；与布局几何分开存（.key_style.json）；导出的布局文件另带一份可选 keyStyles，导入时照着恢复（#2303）
typedef struct { CGFloat scale, opacity; BOOL hidden; } S2AVPadKeyStyle;
static const NSInteger kS2AVPadKeyThemeCount = 5;   // 0 = 默认描线，1–4 = 配色

@interface S2AVPadLayoutStore : NSObject
@property(nonatomic, readonly, copy) NSURL *directory;
@property(nonatomic, readonly) BOOL split;
@property(nonatomic, readonly, copy) NSString *selectedIdentifier;
// Invalid files remain on disk and are returned as visible diagnostics.
@property(nonatomic, readonly, copy) NSArray<NSString *> *diagnostics;
// 独立于布局几何，按 App 保存；旧布局无需新增字段。默认 0.08 / 1 / 1。
@property(nonatomic, readonly) CGFloat stickDeadzone, stickSaturation, stickExponent;
// deadzone 0–0.4，saturation 0.5–1，exponent 0.5–3；失败时保留原内存与磁盘值。
- (BOOL)setStickDeadzone:(CGFloat)deadzone saturation:(CGFloat)saturation exponent:(CGFloat)exponent error:(NSError **)error;
// 摇杆模式（按游戏存）：浮动 = 手指落点当中心（缺省）；固定 = 摇杆常驻屏幕固定位置，位置可在按键编辑里拖。灵敏度 0.5–2。
//   center 是相对安全区的 0–1 坐标，side 0 左 1 右；缺省左 (0.12, 0.66)、右 (0.63, 0.66)，避开默认布局的键
@property(nonatomic, readonly) BOOL stickFixed;
@property(nonatomic, readonly) CGFloat stickSensitivity;
- (CGPoint)stickCenter:(int)side;
- (BOOL)setStickFixed:(BOOL)fixed sensitivity:(CGFloat)sensitivity error:(NSError **)error;
- (BOOL)setStickCenter:(CGPoint)center side:(int)side error:(NSError **)error;
// App-local appearance preference, separate from schema 1 layout geometry.
@property(nonatomic, readonly) CGFloat idleKeyOpacity;
- (BOOL)setIdleKeyOpacity:(CGFloat)opacity error:(NSError **)error;
// App-local UI feedback; independent of game rumble and layout selection. Default YES.
@property(nonatomic, readonly) BOOL hapticFeedbackEnabled;
- (BOOL)setHapticFeedbackEnabled:(BOOL)enabled error:(NSError **)error;
// ZL / ZR 按住锁定：按游戏存在 directory，默认 YES。
@property(nonatomic, readonly) BOOL holdLockEnabled;
- (BOOL)setHoldLockEnabled:(BOOL)enabled error:(NSError **)error;
// 按键外观：按游戏存在 directory。没设过的键是 1 / 1 / 不隐藏。persist = NO 只改内存（拖滑杆时预览），松手再 persist
- (S2AVPadKeyStyle)keyStyle:(NSString *)identifier;
- (BOOL)setKeyStyle:(S2AVPadKeyStyle)style forKey:(NSString *)identifier persist:(BOOL)persist error:(NSError **)error;
@property(nonatomic, readonly) NSInteger keyTheme;
// 整体大小 S2A_VPAD_SCALE_MIN–MAX、整体不透明度 0.2–1：乘在每键值之上，也作用于摇杆；persist 同上
@property(nonatomic, readonly) CGFloat globalScale, globalOpacity;
- (BOOL)setGlobalScale:(CGFloat)scale opacity:(CGFloat)opacity persist:(BOOL)persist error:(NSError **)error;
- (BOOL)setKeyTheme:(NSInteger)theme error:(NSError **)error;
- (BOOL)resetKeyStyles:(NSError **)error;
// 取键用：键 id → 倍率（已乘整体大小），隐藏的键为 0（includeHidden 时按其倍率）；"*" = 没单独设过的键
- (NSDictionary<NSString *, NSNumber *> *)keyScalesIncludingHidden:(BOOL)includeHidden;
// 编辑取消时整体还原
- (NSDictionary *)keyStyleSnapshot;
- (BOOL)restoreKeyStyleSnapshot:(NSDictionary *)snapshot error:(NSError **)error;
- (BOOL)applyKeyStyles:(NSDictionary *)styles error:(NSError **)error;   // 导入布局带的外观：校验后换掉现有外观并存盘
- (instancetype)initWithDirectory:(NSURL *)directory;
// 布局与选择记录存 directory（多款容器壳 = 该游戏自己的目录），闲置透明度 / 触感 / 摇杆手感存 settingsDirectory（App 级，全部游戏共用）
- (instancetype)initWithDirectory:(NSURL *)directory settingsDirectory:(NSURL *)settingsDirectory;
// 分屏几何与选择存 directory/split；键/触模式、长按锁定和手动选择标记仍与普通布局共用。
- (instancetype)initWithDirectory:(NSURL *)directory settingsDirectory:(NSURL *)settingsDirectory split:(BOOL)split;
@property(nonatomic, readonly, copy) NSURL *settingsDirectory;
// 拖动编辑的结果：同 id 原子覆盖（导入仍拒绝同 id，见 saveLayout:）；内置 id 拒绝
- (BOOL)replaceLayout:(S2AVPadLayout *)layout error:(NSError **)error;
- (NSArray<S2AVPadLayout *> *)layouts;
- (nullable S2AVPadLayout *)selectedLayout:(NSError **)error;
- (BOOL)saveLayout:(S2AVPadLayout *)layout error:(NSError **)error;
- (BOOL)selectIdentifier:(NSString *)identifier error:(NSError **)error;
// 「键 / 触」一键切换（屏角切换钮、触屏提示的「切到触屏」、游戏声明触屏时自动切共用）：
//   on = 切到内置 touch，并把切走前的按键方案记进 .last_keys.json；off = 切回记下的按键方案（缺失 / 失效就回 default）。
//   返回 1 = 真切了，0 = 本来就是这个方案（不写盘），-1 = 写盘失败（error 带原因）
- (int)setTouchOnly:(BOOL)on error:(NSError **)error;
// 玩家手动选过方案（切换钮 / 提示条「切到触屏」/ 设置里的触屏布局）：.manual 标记，持久化；自动切（游戏声明触屏配置）见到它就不切
@property(nonatomic, readonly) BOOL manualChosen;
- (BOOL)markManual:(NSError **)error;
// 切「仅触屏 / 按键」的来源（vpad.m 切方案入口与 s2a_vpad_set_touch_only 的 manual 参数同值）：
//   Auto 0 = 自动（游戏声明触屏配置）：玩家手动选过方案就不切；否则只改本局覆盖，不写盘、不记手动
//   Saved 1 = 玩家手动、保存（齿轮「显示 / 隐藏按键」、设置页）：写持久化选择 + 记手动，清掉本局覆盖
//   Session 2 = 玩家手动、只这一局（提示条「切到触屏」）：手动选过也照切；只改本局覆盖，不写盘、不记手动
typedef NS_ENUM(int, S2AVPadTouchSwitch) { S2AVPadTouchAuto = 0, S2AVPadTouchSaved = 1, S2AVPadTouchSession = 2 };
// 按来源切方案。*sessionTouch 是调用方持有的本局覆盖（1 = 本局按仅触屏跑，0 = 没有），这里按来源改写；本局是否仅触屏 = *sessionTouch || 选中 touch。
//   覆盖只往「仅触屏」方向盖：Auto / Session 切回按键只清覆盖，存下的就是 touch 时仍是仅触屏。
//   返回 1 = 本局仅触屏与否变了，0 = 没变（含 Auto 遇手动选过），-1 = 写盘失败（覆盖和持久化都不动）。单测 t_vpad_touch_switch
- (int)switchTouchOnly:(BOOL)on source:(S2AVPadTouchSwitch)source session:(int *)sessionTouch error:(NSError **)error;
/// 旧版 App 级「我的布局」接进这款（11-15 维护者「每款游戏记住自己的触屏布局」）：11-07 以前布局存在 App 级 VPadLayouts，按游戏存以后没人读。
///   打开一款时把 App 级目录里玩家自己的布局（*.json，内置名除外、读得通的）复制进这款的布局目录，只复制不替玩家选上（每款从默认布局开始，
///   默认布局所有游戏都能用；旧布局可能没有摇杆，不能当所有游戏的缺省）。这款已有同名文件不覆盖；每款只做一次（.legacy_adopted），玩家删了不再冒出来。
///   两个目录相同（单款壳）时什么都不做。返回复制了几份
+ (NSUInteger)adoptLegacyLayoutsFrom:(NSURL *)appDirectory into:(NSURL *)gameDirectory;
@end
NS_ASSUME_NONNULL_END
