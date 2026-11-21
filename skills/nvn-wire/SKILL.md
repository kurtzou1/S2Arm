---
name: nvn-wire
description: S2Arm 的 NVN 语义与教训参照：实现或修零配置直连 NVN 前端（graphics/nvn）里任何一个 NVN 函数、对象或命令之前先查本 skill 的 references/。附带从小菠萝（三周 NVN→Metal 实战）、S2Arm 通用方案、丝之歌试点三处提炼的全部参照和教训。「施工流程」一节是 10-24 停用的单款接线（C 档）的历史流程，只作对照，不再新做。
---

# NVN 语义与教训参照（附：单款接线历史流程）

**现行做法**：main 上的 NVN 前端是零配置直连（`graphics/nvn/gfx/nvn/hle_nvn.c` 接 NVN 函数、`graphics/nvn/gfx/nvn/nvn_mtl.m` 翻成 Metal），对所有 NVN 游戏通用，不按款配置（见 docs/方案_快速通用模式.md 与 docs/方案.md §2 铁律）。缺函数、语义不对，就在这两个文件里按 references/nvn_semantics.md 的语义补齐，并按 [skills/gfx-triage](../gfx-triage/SKILL.md) 写先红后绿的单测（graphics/nvn/tests/）。

**历史**：下文「施工流程」描述的是 10-24 前的单款接线（C 档）：NVN 调用译成 Ryujinx IRenderer，代码在 origin 分支 `wire/silksong-c`（graphics/wire + runtime/src/wire.c）。那条路已被零配置直连取代，按款启用与「通用层零专用配置」铁律冲突，**不进 main、不再新做**。流程里的侦察、真值对拍、逐函数补齐的方法对修直连前端仍有参考价值，命令只在该历史分支上能跑。

说明：文中「小菠萝」是 S2Arm 的内部前身实现，代码未公开。references 里带 `H:` / `M:` 行号的出处只供内部对照；外部贡献者看语义描述就够了。

## 参照（按需查，不要整篇读）
| 文件 | 内容 | 什么时候查 |
|---|---|---|
| references/nvn_semantics.md | 逐对象、逐命令的 NVN 语义，小菠萝实现位置，S2Arm 现状与差异，⚠ 易错点 | 实现或修任何一个 NVN 函数之前 |
| references/xbl_lessons.md | 小菠萝三周 152 条教训（着色器缓存、驻留、上屏节拍、iOS 真机、功耗、调试方法） | 遇到对应阶段的问题；开工前先读最后的「最值钱 10 条」 |
| references/s2arm_lessons.md | S2Arm 通用方案 167 条（Metal 后端约束、首遇、GC、Mac 局 / 真机 / 门禁 / 列车用法） | 同上；开工前先读最后的「必须知道的 10 条」 |
| references/pilot_silksong.md | 丝之歌试点 22 个实测坑（构建缓存键、方向坐标、控制段、按阶段绑程序……）和停点 | 开工前通读，只有 40 行 |

**开工前必读**：上面三份文件里的「10 条」各一遍，加 pilot_silksong.md 全文，约 15 分钟。这一步省掉的是几个小时的踩坑。

画面出错（花屏、不满屏、直连异常）时的分诊另见 [skills/gfx-triage](../gfx-triage/SKILL.md)。

## 施工流程（历史：单款接线，只在 wire/silksong-c 分支上能跑）

### 1. 起手（约 10 分钟）
1. 工作树：`git -C <S2Arm 仓库> fetch origin && git -C <S2Arm 仓库> worktree add <工作树目录>/<名> origin/wire/silksong-c -b wire/<款>`。分支落后 main 时**按列车的方向**合：`git checkout --detach origin/main && git merge <本支>`；冲突如果出在 Ryujinx 补丁 series / 改动清单上，跑 `python3 tools/train_renumber.py "$PWD"` 续号（它会自己提交），再 `git branch -f <本支> HEAD && git checkout <本支>`。⚠ 别在本支上 `git merge origin/main` 再续号：工具默认「当前 = main」，会把 main 上已有补丁的号改掉（10-24 实测）。其他冲突照常手解。
2. 私有产物根（公共现行根会被别人换掉）：`python3 tools/clonedir.py "<产物根目录>/$(cat <产物根目录>/<款>@现行)" <私有产物根目录>/<名>/<款>`（`<款>@现行` 是指针文件，内容 = 现行版本目录名）
3. 侦察：`python3 graphics/wire/tools/nvn_recon.py <私有根>`，得到程序号、这款按名字取的 NVN 函数全集、还没实现的（按对象分组）、包里有没有着色器缓存。没有缓存就先让通用路径给这款出包。
4. 编译：`S2A_CS=1 make -s host`。
5. 真值局与第一个接线局同根、同参数、关输入，排队一起跑：
   - `bash graphics/wire/tools/wirerun.sh <款> <私有根> <出>/truth 90 1-1800 off`
   - `bash graphics/wire/tools/wirerun.sh <款> <私有根> <出>/w1 60 1-1500`

### 2. 补函数：侦察结果 → 实现，在第一局之前完成
- 侦察列出的「没实现」里，凡是 nvn_semantics.md 标为小菠萝已实现的，照它的语义一次补齐。getter、调试标签一类直接补，不用等跑局报红。
- nvn_semantics.md 最后一节列着两类缺口，这款用到的先补：
  - 小菠萝有而 S2Arm 没有的 27 个函数（事件整组、ClearTexture、ReadTexels 等）；
  - 表里有、但回放没做或会报红的 7 处（CopyTextureToBuffer、Downsample、ResetCounter、多重采样回放、深度偏移回放、整数清色、驱动段 c0/c2）。

  同节的 25 条「S2Arm 差异」逐条判断对本款有没有影响。
- 写法：`[UnmanagedCallersOnly] static <返回> <去掉 nvn 前缀的名字>(…)`，签名写在一行里，放进 WireApi.cs / WireCmd.cs；回放放进 WireReplay.cs。补完跑 `python3 graphics/wire/gen_table.py`。
- 枚举值、缺省值逐个查仓库里的 `graphics/nvn/gfx/nvn/include/nvn.h`；GAL 方法签名逐个查 `compat/tree/src/Ryujinx.Graphics.GAL`。
- 补完派一个审查子 Agent，把这批新增和改动对照 nvn_semantics.md 逐函数审，「确定」的问题全部改完再跑局。提示词模板见文末。

### 3. 调试循环（每局 45–60 秒，一局合并多项修正）
wirerun 会输出：「近况」行（出图、绘制、跳过原因、着色器命中）、上屏参数、崩溃栈、红行分类汇总。按下面的顺序处理：
1. **崩溃** → 看栈。Metal 断言要在调 GAL 之前就拦住并报红，不能让进程崩。
2. **「NVN 未实现被调用」** → 按 nvn_semantics.md 补。
3. **跳过绘制 > 0** → 按括号里的分类逐类清（没程序 / 图元 / 索引 / 复合 / 着色器未命中）。
4. **全黑、颠倒、偏移** → 拿接线局与真值局 host.log 的「出图参数」行逐字段比（贴图尺寸、源矩形、翻转），再对照 pilot_silksong.md 的方向坐标三条。
   - ⚠ 现在的视口 (x, y+h, w, −h) 加正面绕序对调，是丝之歌（窗口原点左上）实测出来的口径。
   - 新游戏先看接线局日志里的「窗口原点」行。如果是左下（GL），要按 Ryujinx StateUpdater.UpdateViewportTransform / UpdateFrontFace 重新推一遍，再拿真值的「出图参数」核对，不能直接沿用。
5. **局部缺失** → 先用 `S2A_WIRE_RTLOG=<帧>` 画出离屏链路：每次换目标、每次绘制采样了哪张贴图、贴图在哪一帧建、小目标（查找表）在哪一帧被写。再用 `S2A_WIRE_SHOWTEX=<贴图号,…>` 按帧轮换上屏这些中间贴图，找到最后一张对、第一张错的那一环，只修那一环。
6. 同一类错误出现两次 → 再派一次审查子 Agent，覆盖这一整类，不要逐个撞。

### 4. 验收与合入
- 逐帧：`python3 tests/visual/wire_cmp.py <truth>/framecap.bin <wN>/framecap.bin --logs <truth host.log> <wN host.log>`。用块指标加单调对齐比较，要求新增红行为 0。两局本来就不会逐像素相同，真值局的存帧窗口要比接线局长。
- 进局：用通用自动玩家（AI 看屏驾驶）走到 MARK；同一款第二局起回放学过的路线，两边进局路径一致，再比一次。
- 缺省关一致：`make native-test-wire`，加上通用层原有门禁全绿。
- 合入：外部贡献者按 docs/协作循环.md 提 PR，并贴 `bash tools/contrib_check.sh` 摘要；维护者在列车里合。
- iPhone：同一个包，A/B 只差 `S2A_WIRE`，读数只认 iPhone；交出「期望 → 真结果」表。

### 5. 汇报节奏
每个里程碑报一次：起手完成 / 首帧有图 / 标题与真值一致 / 进局到 MARK 一致 / iPhone A/B。每次附墙钟和用量。卡住超过 1 小时就报「做到哪 / 卡在哪 / 还要什么」。

## 诊断开关（历史：接线分支的 graphics/wire/WireReplay.cs）
- `S2A_WIRE_RTLOG=<帧>`：该帧的换目标、每次绘制采样的贴图、建贴图；小目标（高 ≤ 32）在任何帧都记。
- `S2A_WIRE_SHOWTEX=<号,…>`：上屏按帧轮换显示中间贴图。接线局与真值局的帧号不对应，接线局启动更快。
- `S2A_WIRE_REUPLOAD=1`（每帧重传池内容）、`S2A_WIRE_NODEPTH=1`（关深度测试）：快速二分用。
- 「近况」行里有跳过原因分类、对象号解析不出、无标记视图等计数，「不许静默成功」靠这些计数和报红桩。

## 审查子 Agent 提示词模板
> 全程中文思考与报告。只读审查，不改文件、不跑局。
>
> 审查对象：S2Arm 接线层 graphics/wire（NVN → Ryujinx IRenderer）。
> - 语义参照 skills/nvn-wire/references/nvn_semantics.md。
> - NVN 枚举以仓库 graphics/nvn/gfx/nvn/include/nvn.h 为准，不看任天堂官方 SDK 文档。
> - GAL 接口在 compat/tree/src/Ryujinx.Graphics.GAL。
>
> 本款侦察结果与本轮改动：<贴 nvn_recon 输出与 git diff --stat>。
>
> 逐函数找会导致画面错 / 黑 / 崩的语义差异，重点看：
> - 渲染目标与清屏；贴图拷贝与上传；
> - 混合与颜色掩码；深度模板；剔除与正面朝向；视口方向；
> - 顶点与索引；常量缓冲与 support buffer；
> - 贴图 / 采样器句柄与池；窗口与上屏。
>
> 每条给出「文件:行号、我的写法 → 参照语义 → 后果 → 改法」，按最可能致黑排序，区分确定 / 可疑，1500 字以内。
