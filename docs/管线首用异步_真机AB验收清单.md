# 真机 A/B 验收清单：首用管线异步（debug.s2a.nvk_pipe_async）

目标：验证「后台建管线 + 有界等待 + 可恢复的首次缺画」在真机上**降低首次使用长帧、且不引入持续缺画/黑块**。
现已缺省开（与 iOS 一致）：稳态 A/B 见第 6 节（开 ≈ 关、无红行无缺段）；冷进场首用收益用新装包首局在代表游戏上验（新装包没有跨局预热清单，就是冷进场，绕开第 7 节清缓存的阻塞）。

## 0. 前置约束（很关键）

- 开关 `debug.s2a.nvk_pipe_async` 走 `nvn_plat_flag` → 需要 `s2a_debug_entries_open()`：**CMake Debug 配置**且 `adb shell setprop debug.s2a.debug_env 1`。
- 正式包（Release）编译期就把调试门关掉，**Release 包无法运行时切换本开关**。因此：
  - 想用运行时属性做 A/B：只能出 **Debug** 包（CMake Debug 通常是 -O0，性能不代表正式）。
  - 想用**正式性能**做 A/B：出新旧两版 Release 包，**测量版**把 `nvn_vk_pipe_demand_on()` 临时改为 `return 1`（或加一个只在测量构建里生效的强制开），**仅此一处差异**；两包同一 route 各跑 3 局。测完把该临时改动撤掉、不开进正式包。

## 1. 出包（两条路任选其一）

A. 运行时属性路（Debug，验证语义/画面，不用于性能数值）：
```
S2ARM_ANDROID_CS_SERVICES=static S2ARM_ANDROID_GAME_DIR=build/android-game/input \
S2ARM_ANDROID_VK_ENGINE=1 S2ARM_ANDROID_VK_BACKEND=nvk \
  bash android/docker/build.sh -Ps2arm.nativeMode=game :app:assembleDebug
```
装包后：`adb shell setprop debug.s2a.debug_env 1`；A 组 `adb shell setprop debug.s2a.nvk_pipe_async 0`；B 组 `... 1`。

B. 正式性能路（Release，测量版强制开）：
- OFF 包：`bash build/measure/build.sh`（现状，默认关）。
- ON 包：临时把 `android/native/nvn/nvn_vk_pipe_demand.c:nvn_vk_pipe_demand_on()` 首行改 `return 1;`，再 `bash build/measure/build.sh`；装另一台/另一轮。
- 每组前 `adb shell am force-stop org.s2arm.game.t0100f2c0115b6000`。

## 2. 跑分（同机、同存档、同路线；一次只差一个变量）

```
bash build/measure/bench.sh 40 build/measure/ab-<组>-<轮>   # 每组 3 局取中位
```
记录热状态 / 是否充电（AGENTS 要求）。

## 3. 记录指标（期望 → 真结果 对位）

- 首窗「取程序」「开通道与取管线」ms/帧（对照 PR #996 冷进场 255→9.9 / 173.6→~11 的基线）
- 该窗 fps；稳态 fps / p99 / >33ms 帧 / 窗口 max
- 跳过分账：日志「首用跳过累计 …（budget/late/stuck）」与「首用后台建管线：提交/合并/建成/失败/超时」
- 红行数、未接数、`c1_segment_not_captured`（必须 0，否则火把/粒子光照会被跳）
- 画面：该作这类**时域历史 / 曝光 / 阴影 / 遮挡查询**是否出现持续缺画、闪烁超出「首帧」、黑块

## 4. 通过判据

- 无新增红行、无 `c1_segment_not_captured`；跳过只影响首次使用期间短暂少画，恢复后逐像素正确。
- 首窗长帧显著下降；稳态 fps/p99 无回归（在噪声内）。
- 若「不可跳」项持续超上限导致长时间缺画 → 属降级，必须记录并评估是否收紧 skip_safe 或关闭默认。

## 5. 回滚

`adb shell setprop debug.s2a.nvk_pipe_async 0`（Debug 包）或装回 OFF 包即回到现状；代码默认关，无需其他动作。
## 6. 首轮真机 A/B（2026-11-14，稳态窗口，非冷进场）

设备 192.168.31.233:5555；游戏 0100F2C0115B6000；release 包；同路线同一段重场景 40 s 采集。
测量版把 `nvn_vk_pipe_demand_on()` 临时改 `return 1`（绕过调试门、保留 release 性能），测完已还原默认关并重新部署。

| 指标 | OFF（默认关） | ON（强制开） |
|---|---|---|
| fps（各 5 s 窗） | 26.8/24.6/27.5/28.2/21.4/19.9/20.0/19.8 | 27.1/28.5/25.5/25.4/21.3/21.9/21.9/21.9 |
| GPU 忙 ms | 27.4–35.9 | 27.0–33.6 |
| 开通道 / 取管线（其中后端取设）ms | 3.47 / 2.25（1.96） | 3.49 / 2.27（2.01） |
| 红行 / 未接 | 0 / 0 | 0 / 0 |
| 通关截图 | 画面正常、火把亮 | 画面正常、火把亮（与 OFF 逐像素同景） |

结论：
- **稳态 ON≈OFF，无回归、无红行、无 c1 缺段（火把/粒子光正常），demand 线程 + 跳过逻辑开启不崩不黑。**
- 该窗口是**热态**（程序/管线清单已命中），日志中无 `首用跳过` / `首用后台建管线` 记录 → 首次缺画/跳过的收益**未被触发**；要量「冷进场首用」收益必须清掉跨会话预热清单（需保存档的冷起，或维护方基准台），本机 release 包不可 run-as 清内部缓存，未做。
- 因此本清单的**完整 A/B（冷进场首用收益 + 3 局中位）仍是验收前置**；本轮只完成了「稳态无回归 + 画面安全」这一半。
## 7. 冷进场 A/B 的实测阻塞（2026-11-14，本机）

目的：制造**冷进场**（清掉跨会话预热清单 `<files>/user/0/direct-cache/nvn-vk/{programs-v1.bin,pipes-*.bin}`）来触发首用跳过/后台建管线，量其收益与画面。
- 缓存是**应用私有内部目录**（`state_dir = getFilesDir()/user/0`，见 provider_nvk.c:517 与 s2a_program_cache_dir），非 adb 可直接读写。
- 本机设备（Xiaomi/HyperOS，targetSdk 36）**`run-as` 被 SELinux 拒**：`seapp_context_lookup_internal: No match ... fromRunAs ... Permission denied`；即便 APK 已 `DEBUGGABLE`（`dumpsys package` 的 flags 有 DEBUGGABLE）也进不去。
- 无 root / 无 su；`pm clear` 会连存档一起清（不可接受）。
- 结论：**清缓存式冷进场在本机不可行**。可行的替代：
  1. 维护方基准台（可 run-as 的 debuggable 设备 / 工程机）按本清单跑；
  2. 或加一个**仅测量构建**的调试开关，让 warm/prefetch 与跨局程序缓存跳过读取（`debug.s2a.nvk_warm=0` 只停预热线程，程序缓存读取仍在，不足以制造冷首用；需专门「清单当作不存在」的测量开关）；
  3. 或走到预热清单未覆盖的新区域（新内容首用）——需连续输入自动化，本机未做。
