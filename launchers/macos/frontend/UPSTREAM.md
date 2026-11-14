# NX2Apple 前端快照：来源、取用与改动

- 上游：https://github.com/LNPANDY/NX2Apple （MIT，`LICENSE` / `NOTICE` 从上游仓库根原样拷来，同目录）
- 固定提交：`908e4e848fd232304381fc19d4d847fcc10fc4c2`（main，Merge pull request #888）
- 取自：上游 `frontend/`（Mac 启动器 SwiftPM 包）
- 用途：S2Arm × NX2Apple 的 Mac 正式前端（第一刀：库 → Play → 运行事件 / 停止 → 回库；
  第二刀：环境检查、导入游戏、准备运行、打 iPhone 包、装到 iPhone，后端收成设计稿 2.13 的 EngineProvider 形状 `S2ArmEngineProvider`）。
  后端一律走 S2Arm 作业层（`pack/jobs/main.py`），经 `launchers/macos/adapter`（`S2ArmAppleAdapter`）接入；
  装配入口是 `launchers/macos` 的可执行 target `S2ArmApple`。旧 `launchers/macos/Sources/S2ArmLauncher` 本阶段并存不动。

## 取用清单

原样（与上游该提交逐字节相同，同步上游时直接覆盖）：

| 本目录 | 上游 `frontend/` |
|---|---|
| `Sources/NXCore/Localization.swift`、`LocalizationFiles.swift`、`BundledTools.swift`、`LauncherWork.swift`、`BuildProgress.swift` | 同名 |
| `Sources/NXModel/Localizer.swift` | 同名 |
| `Sources/NXLauncher/LauncherPalette.swift`、`Typography.swift`、`EmbeddedFonts.swift`、`LauncherStyles.swift`、`LauncherDropdown.swift`、`PadFocus.swift`、`LauncherCard.swift`、`RowScroller.swift` | 同名 |
| `fonts/Manrope-OFL.txt` | 同名（`EmbeddedFonts.swift` 内嵌的 Manrope 字体的 SIL OFL 1.1 许可） |

带 S2Arm 改动（文件头注明 Derived from 与改动）：

| 本目录 | 上游 `frontend/` | 改动 |
|---|---|---|
| `Sources/NX2Apple/LauncherView.swift` | 同名 | 只保留库页；状态换成 `S2ArmLauncherModel`（不用 `LauncherStores`）；作业进行中（一局 / 准备 / 装机 / 导入）换成 `JobSessionView`，出包换成 `ExportSessionView`；点某款的「出包」库页换成出包页 `ExportView`；顶栏加「添加游戏」（选文件 / 拖进窗口 → import 作业）与「环境检查」；加装机页、释放空间两个 sheet；去掉 Builds / Settings 页、启动选项 sheet、引擎同步横幅、封面编辑、管理菜单、主机模式与手柄驱动；顶栏显示品牌名（一行大号，与窗口三个按钮同一中线：空的 unified 工具栏把标题栏撑到顶栏高、系统把按钮居中）；顶栏加 Switch 2 Pro 手柄按钮与弹窗（`Switch2ProConnectionPopover`）；顶栏最前加本地玩家按钮与弹窗（`PlayerToolbarButton`，S2Arm 自有 `LocalPlayersView.swift`，#623） |
| `Sources/NX2Apple/LauncherView+Library.swift` | 同名 | 游戏换成适配层 `GameSummary`（catalog 作业），封面用游戏库 `cover.jpg`（`CoverFill` / `CoverCache`，不取上游 Artwork 体系）；主按钮是「出包」（打开出包页），Mac 版已做好的款旁边加次按钮「开始游戏」（launch 作业），再是「释放空间」圆钮；「开始游戏」旁有启动设置圆钮（齿轮，11-09；游戏语言等逐款选项，11-14 维护者确认玩家可选）；卡片与主按钮带自己的辅助功能标签（原先被读成图片）；空库页加「添加游戏」；去掉重建、iPhone 重签、管理菜单、Switch 2 徽标、筛选 |
| `l10n/en.json`、`l10n/zh.json` | 同名 | 按键序插入我方键 `s2arm.*`；上游已有的键一个没改 |
| `Package.swift` | 同名 | 我方重写：只含取用的文件；上游 app target `NX2Apple` 改成库 target `NX2AppleUI`（路径仍是 `Sources/NX2Apple`），依赖 `S2ArmAppleAdapter`；下限同上游 macOS 13、Swift 5 语言模式 |

S2Arm 新增（不是上游文件）：`Sources/NX2Apple/S2ArmLauncherModel.swift`（界面状态，接适配层 `S2ArmEngineProvider`；出包的平台队列 `ExportRun`）、`ExportView.swift`（出包页：游戏信息、平台多选卡、能不能出包；没有游戏选项）、`ExportSessionView.swift`（出包进行中 / 做完：平台队列、总用时与预计还需（适配层 `MilestoneEstimate`）、步骤清单、按平台的结果动作）、`JobSessionView.swift`（作业页：事件 / 停止或取消 / 结局 / 回库，第一刀叫 PlaySessionView）、
`EnvironmentView.swift`（环境检查清单与一键处理，卡片用 NXLauncher 的 CardGroup / CardRow；游戏库在云盘 / 非 APFS 给「换游戏库」）、`InstallView.swift`（装机前清单，每 5 秒重查）、`FreeSpaceView.swift`（释放空间：spaceSurvey / spaceFree 作业，勾选删除、二次确认）、`JobProgress.swift`（作业页的第几步 / 本阶段计数 / 按实测速率算的剩余时间，显示借 NXCore `BuildProgress` 的 `Stage.clock` 与 `progressDetail`）、`BackendText+Localizer.swift`（作业层中文原句按界面语言显示，翻译走适配层 `BackendText`）、`S2ArmAppleRoot.swift`（本包唯一 public 入口：`package` 访问级别不跨 SwiftPM 包）。

不取游戏选项（11-07 维护者）：上游 `LaunchOptionsView.swift`（每款启动选项 sheet）不取用——游戏语言跟设备系统语言，Mac 主机模式 / 手机掌机模式，60 帧缺省开、起不来自动降级，满屏缺省通用 + 补丁包，都由 S2Arm 作业层 / 宿主定，界面不给开关；适配层 `settingsSchema` 回空表。

## 剔除清单

整块不要（S2Arm 有自己的引擎、出包、签名、装机与发版，不引入第二套）：
`EngineLayout` / `EngineManifest` / `EngineUpdater` / `EngineSyncStore` / `RepoStore` / `GitCheckout` / `BuildStore*` / `ExperimentalBuilder` / `ShellInstall` / `ShellRoot*` / `OneGameIPA` / `AppUpdate*` / `ReleaseSource`，
以及 `frontend/bundled-python`、`nxbuild.pin`、`frontend/tools/`、`engine-signing.pub`。

本刀未取用（闭环用不到，按需再取，取时照上表登记）：上游 `Sources/` 其余文件——NXCore 的设备 / 签名 / 工具链 / 存档同步 / 构建失败分类等，
NXModel 的其余 store，NXLauncher 的构建页卡片（`TargetCard`、`InstallCard`、`ToolsCard` 等依赖 `BuildStore` / `EngineSyncStore`），
app target 的封面编辑、Console（手柄大屏模式）、金手指、存档传输、引导等；`Tests/`、`screenshots/`、`AppIcon.icon`、`README.md` / `ARCHITECTURE.md` 等文档；
`fonts/Manrope.ttf` 与 `embed_fonts.py`（字体已内嵌在 `EmbeddedFonts.swift`）；`l10n/` 里除 en / zh 外的语言（S2Arm 目前只出中英）。

## 同步上游

1. 在只读克隆里换到新提交，逐个比对「原样」表里的文件，相同的直接覆盖；上游删改的要看调用方。
2. 「带 S2Arm 改动」的文件按上游 diff 手工合，改动说明同步更新本文件与文件头。
3. l10n：上游新键直接收，我方键（`s2arm.*`、上表 `launch.*`）保留。
4. 改完更新本文件的固定提交。
