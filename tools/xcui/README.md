# 真机交互运行器（XCUITest）

真机上需要「点屏幕」的验收（设置页开关、已知坐标点按看触点）用它做，不靠人手、不靠来历不明的预装运行器。只点不判：判据看宿主日志（host.log）与 `devicectl device capture screenshot`。

## 用法

```bash
S2A_DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
  bash tools/xcui/run.sh <设备 UDID> <计划.json> [输出目录]
```

- 先拿设备锁（tools/devlock.sh），被点的 App 先起好（dev_run 起局，或带 `S2A_OPEN_SETTINGS=<秒>` 直接开设置页）；运行器只附着、不重启它。
- 签名：`S2A_XCUI_TEAM`，没给就取 Xcode 里第一个付费团队；工程由 xcodegen 生成在 build/xcui（不入库）。
- 输出：`xcodebuild.log`、`steps.log`（每步一行「[xcui] …」）。

## 计划格式（tools/xcui/Runner/Plan.swift，单测 tests/xcui_plan_test.sh）

```json
{"bundle": "io.s2arm.0100152000022000", "steps": [
  {"tap": "settings.S2ADockedMode"}, {"tap": "settings.done", "timeout": 5},
  {"slider": "settings.S2AResolutionScale", "to": 1}, {"tap": "立刻重启"},
  {"tapxy": [480, 220]}, {"press": [480, 220, 1.5]}, {"wait": 2}]}
```

`tap` 按无障碍标识或标签找控件（系统弹框按钮用标题，如「立刻重启」）；整段找不到时退一步找标签以它开头的第一个（带副标题的菜单项，写标题即可，如「手柄按键：Xbox 布局」）；`slider` 把滑条拖到 0~1 的归一位置（渲染分辨率 0.5 / 0.75 / 1 / 1.5 / 2 五档，1 = 最右 = 2 倍）。

设置页控件的无障碍标识：`settings.<键>`（如 S2ADockedMode / S2AResolutionScale）、`settings.done`、触屏布局行 `vpad.layout.*`（ios/app_settings.m、vpad_settings.m）。

## 首次使用：设备上要人输一次密码

iOS 第一次给 XCTest 开 UI 自动化时弹「为 “XCTest” 输入 iPhone 密码 — Enable UI Automation」，不输就报 `Timed out while enabling automation mode`（11-01 测试设备1 实测）。自动化不能代输密码，要人在设备上输一次。

## 做不到的

- 四指长按、手柄按键：XCUITest 只有单指按压 / 双指点按。打开 S2Arm 设置页请用 `S2A_OPEN_SETTINGS=<秒>`（ios/diag.m 测试开关）。
