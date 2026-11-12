<p align="center"><a href="https://s2arm.com"><img src="docs/images/s2arm-wordmark.png" width="420" alt="S2Arm"></a><br><a href="https://s2arm.com">s2arm.com</a></p>

> [!NOTE]
> **好消息：[s2arm.com](https://s2arm.com) 已正式成为 S2Arm 官方网站。** S2Arm 免费开源，从不接受任何捐赠；请只从 [s2arm.com](https://s2arm.com) 或本 GitHub 仓库获取 S2Arm。

**把你自己的 Switch 游戏，原生带到 iPhone、iPad 和 Mac。** 游戏代码改写成原生 ARM64，直接在设备的处理器上执行；图形直连 Metal。整座游戏库装进一个 App，在 Mac 或 Windows 的图形启动器里点几下就能出包、装机、开玩。

平台：iPhone / iPad（iOS / iPadOS 18 起）· Mac（Apple 芯片，macOS 15 起）· 在 Mac 或 Windows 上出包 · Android / 鸿蒙即将支持 · 许可：Apache-2.0 · **游戏原件自备**

[English](README.md) · [下载启动器](https://jhaizhou-ops.github.io/S2Arm/) · [全部版本](https://github.com/jhaizhou-ops/S2Arm/releases) · [证据页](docs/validation/证据.md)

<p align="center"><img src="docs/images/launcher-welcome.png" width="760" alt="S2Arm 启动器欢迎页"></p>

## 原生移植，不是模拟

游戏自己的 ARM64 代码在出包时改写，然后直接在 iPhone、iPad 和 Mac 的处理器上运行，没有 CPU 模拟器夹在中间。图形调用直接翻译成 Metal，系统服务由原生宿主提供。快、凉、省电，都从这里来。[证据](docs/validation/证据.md#原生移植)

## 一个 App，装下整个游戏库

所有游戏导入同一个 S2Arm App，打开后在游戏库里挑一款就玩。整座游戏库只占开发者账号的一个 App 名额：多加一款游戏，不多装一个 App，也不多占一个签名名额。[证据](docs/validation/证据.md#单壳游戏库)

## 图形启动器，几乎零配置

Mac 和 Windows 各有一个图形启动器。第一次打开，欢迎页把事情收成三步：准备这台电脑、放入密钥、添加游戏，任何时候只有一个主按钮。运行所需的组件要么已经内置，要么一键获取，全程不用打开命令行。

点「一键出包」之后，每个阶段的进度、用时、剩余时间和磁盘占用都看得见；多款游戏可以排队连续出包。[证据](docs/validation/证据.md#零配置启动器)

<p align="center">
  <img src="docs/images/launcher-oneclick.png" width="400" alt="一键出包">
  <img src="docs/images/launcher-export.png" width="400" alt="出包进度">
</p>

<p align="center">
  <img src="docs/images/launcher-success.png" width="400" alt="出包完成">
  <img src="docs/images/launcher-library.png" width="400" alt="游戏库">
</p>

## AI 可以直接驾驶

Mac 和 Windows 启动器都开放了控制接口 `s2armctl`：AI 助手可以导入游戏、出包、装机、查进度、读错误，每一步都在启动器窗口里看得见。配套的自查、自修与反馈工具包让 AI 自己定位问题、按处方修复，修不好就整理出诊断包交给你提交。看 AI 诊断并修好一个真实问题的完整实录：[证据](docs/validation/证据.md#ai-驾驶)

### 让 AI 帮你操作

把这句话发给你的 AI 助手（需要它能在你的电脑上执行命令）：

> 请阅读 https://github.com/jhaizhou-ops/S2Arm/blob/main/launchers/macos/skill/s2arm-operator/SKILL.md ，然后帮我把我的 Switch 游戏装到 iPhone 上。

它会用这几条命令一步步推进，你在启动器窗口里看得到每一步：

```bash
/Applications/S2Arm.app/Contents/Resources/s2armctl start        # 打开并连上启动器
/Applications/S2Arm.app/Contents/Resources/s2armctl next         # 现在该做什么、谁来做、为什么
/Applications/S2Arm.app/Contents/Resources/s2armctl diag export ~/Desktop/S2Arm-诊断.zip   # 修不好时导出诊断包
```

需要你本人做的事（系统授权、登录 Apple ID、在手机上点「信任」），AI 会停下来告诉你。Windows 上用启动器文件夹里的 `s2armctl.cmd`，命令相同。Windows 只出 iPhone / iPad 包，游戏里的问题请在手机上导诊断包：游戏画面上四指同时长按 1.5 秒，选「导出诊断包」。

**游戏里出了问题**（画面、帧率、卡顿、闪退）？把这句话发给 AI：

> 请阅读 https://github.com/jhaizhou-ops/S2Arm/blob/main/skills/player-game-triage/SKILL.md 。我在 S2Arm 里玩的游戏出了这个问题：<描述现象>。先帮我查设置、收诊断；你能改代码就按里面的方法根修并提 PR，修不了就帮我整理成 Issue。

## 经过大规模真机检验

**211** 款游戏完成普查，一次出包成功率 **95%**。**4700+** 局 iOS 真机测试，**1000+** 局 macOS 测试。[证据](docs/validation/证据.md#大规模真机检验)

## 快、顺、省电

在一台 16 GB 内存的 MacBook Air（M3）上，从导入游戏到出好 iPhone 包，全程冷启动：

| 游戏 | 原件 | 着色器 | 出包用时 |
|---|---|---|---|
| 一款 23.5 GB 的动作角色扮演游戏 | 23.5 GB | 1,222 | **6.4 分钟** |
| 一款 12.0 GB 的生活模拟游戏 | 12.0 GB | 9,315 | **8.6 分钟** |
| 一款 17.5 GB 的开放世界游戏 | 17.5 GB | 26,999 | **34 分钟** |

一款 Switch 2 游戏在 iPhone 17 Pro Max 上真机实测，手机未发热时**满 60 帧**，持续高负载发热后 **37～43 帧**，每帧耗电约 **0.15 焦耳**。[证据](docs/validation/证据.md#速度与能效)

## 覆盖面

| 平台 | 支持 |
|---|---|
| iPhone / iPad | iOS / iPadOS 18 起，所有游戏在同一个 App 里选 |
| Mac | Apple 芯片，macOS 15 起；本机出包，也能直接在 Mac 上玩 |
| Windows | 图形启动器，为 iPhone / iPad 出包并装机 |
| Android / 鸿蒙 | 即将支持 |

[证据](docs/validation/证据.md#平台与系统)

## 下游深度方案

有的游戏有社区专门做的深度移植。S2Arm 认得出这些游戏：导出时弹一页说明，你可以改用下游项目的方案（导入、出包、装机仍在 S2Arm 里点按钮完成，底层换成下游项目的实现），也可以照常用原版方案。登记表在 [`pack/downstream/schemes.json`](pack/downstream/schemes.json)，两边的约定以下游项目的说明为准。

| 方案 | 项目 | 终端 | 约定 |
|---|---|---|---|
| D2R-Mobile | [jhaizhou-ops/d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile) | iPhone / iPad（iOS 26 起；安卓、鸿蒙接入中） | [docs/S2ARM.zh-CN.md](https://github.com/jhaizhou-ops/d2r-mobile/blob/main/docs/S2ARM.zh-CN.md) |

## 开始使用

1. 从[下载页](https://jhaizhou-ops.github.io/S2Arm/)下载 Mac 或 Windows 启动器，打开即用。在 Mac 上出 iPhone 包需要 App Store 免费的 Xcode，并在里面登录你的 Apple ID，启动器会一步步带你完成。
2. 导入你自己的密钥和游戏；本体、更新和 DLC 放在同一个文件夹里一次导入。
3. 选 iPhone / iPad 或这台 Mac，点「出包」。
4. 按启动器提示用你自己的 Apple ID 签名装机（Windows 版已附带签名工具 Impactor），打开 S2Arm，在游戏库里选游戏开玩。

更新 App 前先备份存档。正式版的 App 标识改为 `io.s2arm.*`，系统会把它当成一个新 App：测试版（beta）里的存档不会自动带过来。

## 诚实的边界

S2Arm 运行 64 位（AArch64）游戏。Apple 芯片不能执行 32 位 ARM 代码，所以 32 位游戏不在支持范围内；需要 36 位地址空间的游戏同样不在支持范围内。

## 参与开发

[贡献指南](CONTRIBUTING.md) · [AI 协作规范](LLM_POLICY.md) · [给 AI 的诊断与根修 skills](skills/) · [问题回报](https://github.com/jhaizhou-ops/S2Arm/issues) · [第三方许可](THIRD_PARTY_LICENSES.md)

## 致谢

S2Arm 站在社区的肩膀上。

- **联合开发者**：感谢每一位在本项目提交过 PR 或 Issue 的人，你们的代码、真机测试和问题报告塑造了今天的 S2Arm（按首次贡献时间）：[@biglawine](https://github.com/biglawine), [@yyan160](https://github.com/yyan160), [@DanielZhangyc](https://github.com/DanielZhangyc), [@vickwv](https://github.com/vickwv), [@Xc1Ym](https://github.com/Xc1Ym), [@fjack](https://github.com/fjack), [@ha7rock](https://github.com/ha7rock), [@yourmoonlight](https://github.com/yourmoonlight), [@qidian99](https://github.com/qidian99), [@n06ody](https://github.com/n06ody), [@YTwsy](https://github.com/YTwsy), [@wdjwxh](https://github.com/wdjwxh), [@realskyrin](https://github.com/realskyrin), [@wwmogu](https://github.com/wwmogu), [@quancunlau](https://github.com/quancunlau), [@moongrant](https://github.com/moongrant), [@imyinyx](https://github.com/imyinyx), [@s-leeq](https://github.com/s-leeq), [@Zhangbu](https://github.com/Zhangbu), [@retX0](https://github.com/retX0), [@zh0ngtian](https://github.com/zh0ngtian), [@fengbird](https://github.com/fengbird), [@zsakvo](https://github.com/zsakvo), [@1500256797](https://github.com/1500256797), [@BossaMelon](https://github.com/BossaMelon), [@GayoZhao](https://github.com/GayoZhao), [@sovaly](https://github.com/sovaly), [@ruterfu](https://github.com/ruterfu), [@fyn1320068837-source](https://github.com/fyn1320068837-source), [@InTheManXG](https://github.com/InTheManXG), [@neexuan](https://github.com/neexuan), [@Catnip202X](https://github.com/Catnip202X), [@kmmao](https://github.com/kmmao), [@Darcelsan](https://github.com/Darcelsan), [@lson-lee](https://github.com/lson-lee), [@cszwdy](https://github.com/cszwdy), [@Aoldbald](https://github.com/Aoldbald), [@potpot3](https://github.com/potpot3), [@yangxiaofei819](https://github.com/yangxiaofei819), [@nevenhsu](https://github.com/nevenhsu), [@shuangwei-Ye](https://github.com/shuangwei-Ye), [@IUMonster](https://github.com/IUMonster), [@zhanggh126](https://github.com/zhanggh126), [@xiaoweili126](https://github.com/xiaoweili126), [@shenxianmq](https://github.com/shenxianmq), [@rugal7699](https://github.com/rugal7699), [@painkiller2049](https://github.com/painkiller2049), [@tommy762](https://github.com/tommy762), [@tiannip](https://github.com/tiannip), [@Tiaoge-tou](https://github.com/Tiaoge-tou), [@skyezhangF](https://github.com/skyezhangF), [@DDDDEEP](https://github.com/DDDDEEP), [@CJohnSnow](https://github.com/CJohnSnow), [@shanaiardor](https://github.com/shanaiardor), [@wehnes](https://github.com/wehnes), [@SantaJiang](https://github.com/SantaJiang), [@orzdesu](https://github.com/orzdesu), [@shengyifan](https://github.com/shengyifan), [@QBYLHQ](https://github.com/QBYLHQ), [@kurtzou1](https://github.com/kurtzou1), [@TravelC](https://github.com/TravelC), [@f\*\*\*\*\*\*\*](https://github.com/fucknima), [@mizukico](https://github.com/mizukico), [@turtle4512](https://github.com/turtle4512), [@CrazyBunQnQ](https://github.com/CrazyBunQnQ), [@lwjailjq-spec](https://github.com/lwjailjq-spec), [@hkk818](https://github.com/hkk818), [@AirEcho825](https://github.com/AirEcho825), [@asdaffeqqr](https://github.com/asdaffeqqr), [@jazz-zzzz](https://github.com/jazz-zzzz), [@Canon329](https://github.com/Canon329), [@llpgf](https://github.com/llpgf), [@wyx813562408](https://github.com/wyx813562408), [@GirlNet](https://github.com/GirlNet), [@yangliguo7](https://github.com/yangliguo7), [@vuongtqchip](https://github.com/vuongtqchip), [@danielmx98](https://github.com/danielmx98), [@vpromise](https://github.com/vpromise), [@starlighteryuan-rgb](https://github.com/starlighteryuan-rgb), [@Jean-Zhang999](https://github.com/Jean-Zhang999), [@devinhurry](https://github.com/devinhurry), [@zhaobenshan-cmd](https://github.com/zhaobenshan-cmd), [@ethan-unplugged](https://github.com/ethan-unplugged), [@huanhuxilu](https://github.com/huanhuxilu), [@Y2JING](https://github.com/Y2JING), [@lin465](https://github.com/lin465), [@ZEERDEER](https://github.com/ZEERDEER), [@Haseenesss](https://github.com/Haseenesss), [@xavierskip](https://github.com/xavierskip), [@Levier007](https://github.com/Levier007), [@XuanLIN0224](https://github.com/XuanLIN0224), [@kaiying1994](https://github.com/kaiying1994), [@zhaozhen197](https://github.com/zhaozhen197), [@igobypc](https://github.com/igobypc), [@nimohe](https://github.com/nimohe), [@Glaucus-Kwok](https://github.com/Glaucus-Kwok), [@1614912120](https://github.com/1614912120), [@sofaseakk](https://github.com/sofaseakk), [@Eylock](https://github.com/Eylock), [@tututuhehehe](https://github.com/tututuhehehe), [@dovelflab](https://github.com/dovelflab), [@daiadong](https://github.com/daiadong), [@l1uvu](https://github.com/l1uvu), [@torg20](https://github.com/torg20), [@2k002](https://github.com/2k002), [@rzhang-tech](https://github.com/rzhang-tech), [@edwardzgy](https://github.com/edwardzgy), [@sevenspan](https://github.com/sevenspan), [@unionpacificy](https://github.com/unionpacificy), [@wendaocode](https://github.com/wendaocode), [@zhegemimahaolihai666](https://github.com/zhegemimahaolihai666), [@rhotov](https://github.com/rhotov), [@Arvinnma](https://github.com/Arvinnma), [@abissa](https://github.com/abissa), [@ckuffff](https://github.com/ckuffff), [@xiaopebaka](https://github.com/xiaopebaka), [@xiaoxiaocos](https://github.com/xiaoxiaocos), [@BTFKM](https://github.com/BTFKM), [@UKhhh](https://github.com/UKhhh), [@bagasromadon](https://github.com/bagasromadon), [@wangkoukouX](https://github.com/wangkoukouX), [@Klien-m](https://github.com/Klien-m), [@hycailxy](https://github.com/hycailxy), [@CCCGoat](https://github.com/CCCGoat), [@NJimmi](https://github.com/NJimmi), [@qooxxp](https://github.com/qooxxp), [@lhailiang20-hue](https://github.com/lhailiang20-hue), [@lucaAce1024](https://github.com/lucaAce1024), [@dejavuwl](https://github.com/dejavuwl), [@KANATA23333](https://github.com/KANATA23333), [@wowkiseki](https://github.com/wowkiseki), [@wcashew](https://github.com/wcashew), [@Chidober](https://github.com/Chidober), [@Orreroem](https://github.com/Orreroem), [@XIAMI2016](https://github.com/XIAMI2016), [@StrayDogA8](https://github.com/StrayDogA8), [@HFYKratos](https://github.com/HFYKratos), [@iriotssos](https://github.com/iriotssos), [@oneincase](https://github.com/oneincase), [@hx23840](https://github.com/hx23840)。
- **虚拟手柄与齿轮菜单**：iOS 游戏内齿轮菜单和虚拟手柄原地编辑的交互，参考了 [@neexuan](https://github.com/neexuan) 在 [#134](https://github.com/jhaizhou-ops/S2Arm/pull/134) 带来的 MeloNX 风格设计，S2Arm 重新实现。感谢 MeloNX 在 iOS 上探索的这套交互。
- **Ryujinx**（Ryujinx Team and Contributors，MIT）：系统服务与着色器翻译的上游，S2Arm 的兼容层建立在它之上。
- **[NX2Apple](https://github.com/LNPANDY/NX2Apple)**（LNPANDY，MIT）：启动器界面的上游。
- **[nxnative](https://github.com/seedds/nxnative)**（seedds，MIT，Copyright (c) 2026 seedds）：直连图形层的原作，S2Arm 把游戏图形直接接到 Metal 的这一层源自这份工作。没有这份慷慨的开源，就没有今天的直连路线。
- **[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)**（MIT）：开拓了这条技术路线，第一次把自己的 Switch 游戏原生带到 iPhone、iPad、Mac、安卓和鸿蒙。
- **Impactor**（Samara M，MIT）与 **apple-codesign**（MPL-2.0）：Windows 端的签名装机。
- **LNPANDY** 及 iOS 游戏库外壳的原作者与贡献者：外壳与 RomFS 归档子系统。
- **ns2pro-bridge**（DanielZhangyc，MIT）、**MacNativeGames**（MIT）、**LumaDock**（MIT）、**deko3d**（fincs，zlib）、**nvn.h**（h1k421，MIT）、**bcdec**（Sergii Kudlai，MIT / Unlicense）、**SPIRV-Cross** 与 **Vulkan-Headers**（Khronos Group）、**SMAA**（Jorge Jimenez 等，MIT）、**Mesa** 的细分器（Microsoft，MIT）、**Capstone**、**LZ4**、**.NET**、**libvpx**、**libopus**、**dav1d** 和 **Noto** 字体。

每个组件的版本、许可全文和用途见 [NOTICE](NOTICE) 与 [第三方许可清单](THIRD_PARTY_LICENSES.md)。

## Star 走势

<a href="https://star-history.com/#jhaizhou-ops/S2Arm&Date"><picture><source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=jhaizhou-ops/S2Arm&type=Date&theme=dark" /><img alt="Star History" src="https://api.star-history.com/svg?repos=jhaizhou-ops/S2Arm&type=Date" /></picture></a>

## 许可与声明

S2Arm 以 [Apache License 2.0](LICENSE) 开源。本项目不提供任何游戏，也不提供密钥；游戏原件请自行合法取得。S2Arm 与 Nintendo 没有隶属或授权关系，游戏名称与商标归各自权利人所有。
