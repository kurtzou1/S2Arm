# S2Arm 品牌图标

维护者 11-08 定稿的玻璃 S 标。

- `AppIcon-iOS.png`：iPhone / iPad 上 S2Arm 的图标（232×232，11-13 维护者定：iOS 用字标里那版更鲜艳的玻璃 S，Mac 不动）。取自维护者给的「黑底 logo 带文字」图的图标框内、去掉玻璃框线；iOS 只用 120 / 180 两档（`pack/app_bundle.py write_icons`），232 往下缩不发虚。
- `AppIcon-1024.png`：1024×1024，铺满方形、不带圆角和透明留边，供 `../make_icns.sh` 生成系统图标；圆角由系统遮罩，应用内的 `BrandMark` 按连续圆角裁切。

生成各尺寸系统图标：

```sh
bash launchers/macos/make_icns.sh build/S2Arm.icns
```

`launchers/macos/build_app.py` 将生成的 `S2Arm.icns` 放入应用资源，`CFBundleIconFile` 与应用内 `BrandMark` 均读取它。游戏出包的图标入口 `pack/app_icon.sh` 独立使用每款游戏自己的图标。
