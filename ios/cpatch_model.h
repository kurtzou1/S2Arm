// 社区补丁设置的数据层（纯 Foundation，Mac 单测 t_cpatch_settings）：读包根 cpatch.tsv（pack/cpatch.py plan 出的装载器表），
//   按编号前缀分组（widescreen: 宽屏 / fps: 60 帧 / 其余 画面；编号 gfx: 的画面类 iOS 不打不列，11-13），同一编号跨模块的多行并成一项；开关写回 S2ACommunityPatches。
// 写回口径与装载器一致（ios/settings.m → S2A_CPATCH_ON → runtime/src/cpatch.c）：没设过 = 全开（11-13；表「缺省开」只作我方已验标签）；字符串数组 = 只开数组里的；
//   空数组 = 全关。帧率类（fps:）不看这个列表，跟 60 帧开关 S2AFps60 走，所以不进写回。下次启动生效
#import <Foundation/Foundation.h>

extern NSString *const S2ACPatchDefaultsKey;   // @"S2ACommunityPatches"

@interface S2ACPatchItem : NSObject
@property (nonatomic, copy) NSString *ident;     // 编号，如 widescreen:0123456789abcdef
@property (nonatomic, copy) NSString *name;      // 段名（补丁作者写的英文原文）
@property (nonatomic, copy) NSString *title;     // 中文显示名（S2ACPatchTitle 按常见词对照表生成；对不上的用「<组名>补丁」）
@property (nonatomic, copy) NSString *group;     // 显示分组：widescreen / fps / gfx（S2ACPatchClassify，按名字关键词，其次「类别」列）
@property (nonatomic, copy) NSString *license;   // 许可（空 = 未声明）
@property (nonatomic) BOOL defaultOn;            // 表里「缺省开」（同一编号多行时任一行为 1 即为 1）
@property (nonatomic) NSInteger targetFps;      // 帧率类的目标帧率（表第 10 列，pack/cpatch.py；0 = 没写 / 旧表）。补丁优先：设置页「帧率」行按它写「最高 n 帧」
@property (nonatomic, readonly) BOOL followsFps60;   // 帧率类：跟 60 帧开关
@property (nonatomic, readonly) BOOL followsFullscreen;   // 自适应满屏一族（编号 wsauto:）：跟满屏开关（settings.m s2a_ios_set_fullscreen 一并开关），不单列
@end

@interface S2ACPatchGroup : NSObject
@property (nonatomic, copy) NSString *kind;    // widescreen / fps / gfx
@property (nonatomic, copy) NSString *title;   // 宽屏 / 60 帧 / 画面
@property (nonatomic, copy) NSArray<S2ACPatchItem *> *items;
@end

// 显示分组：先看补丁名关键词（60 帧 → 宽屏 → 画面），都没有再看「类别」列（出包按补丁目录填：ultrawide / 60fps / other-gfx），再没有看编号前缀。
//   「类别」是目录不是内容（0100152000022000 的 ultrawide 目录里有「Force 60FPS split screen」「Removed depth of field」），所以名字优先。
//   分组只管显示；运行时跟 60 帧开关的是编号前缀 fps: 那一类（followsFps60），与显示在哪组无关
NSString *S2ACPatchClassify(NSString *name, NSString *category, NSString *ident);
// 中文显示名：常见写法对照表（分辨率 / 帧率 / 景深 / 动态分辨率 / LOD / 模糊 / 描边 / 阴影 …），按顺序第一条命中的为准
NSString *S2ACPatchTitle(NSString *name, NSString *group);
// 画幅数 → 显示写法（16:10 / 21:9 …）
NSString *S2ACPatchRatioText(double a);
// 解析 cpatch.tsv 全文（第一行表头）；按显示分组 宽屏 → 60 帧 → 画面 排，没有项的组不出。读不懂的行跳过
NSArray<S2ACPatchGroup *> *S2ACPatchGroupsFromTSV(NSString *text);
// 当前开着的编号（不含帧率类）
NSSet<NSString *> *S2ACPatchEnabled(NSArray<S2ACPatchGroup *> *groups, NSUserDefaults *defaults);
// 改一项（帧率类忽略）：在当前开着的集合上加 / 减，按页面顺序写回字符串数组
void S2ACPatchSetEnabled(NSArray<S2ACPatchGroup *> *groups, NSUserDefaults *defaults, NSString *ident, BOOL on);
