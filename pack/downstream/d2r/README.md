# iPad 同容器 D2R-Mobile 开发构建

此构建从 S2Arm 游戏库启动 D2R-Mobile 后端，并接入暗黑 2 的本地存档管理。需要 Apple 芯片 Mac、Xcode 27、iPadOS 26 或以上，以及支持 Metal 4 和 BC 纹理的设备。游戏输入为自己导出的 1.0.34.0 更新。S2Arm 的一键出包仍提供现有的独立 App 方案。

## 本地构建

1. 按 [S2Arm 贡献指南](../../../CONTRIBUTING.md) 准备工具链。从本分支运行 `make ios S2A_CS=1 S2A_SHELLUI=1`，生成 `build/ios/S2Arm.app`。
2. 检出 [D2R-Mobile v2.3.5](https://github.com/jhaizhou-ops/d2r-mobile/tree/66635dac08a68b074779dc59d3825ee8c262afd8)，按该版本说明使用自己的 ExeFS 与 RomFS 生成 iOS IPA。构建时沿用这次做包的 RomFS、着色器链和所用 Python 环境。
3. 在 S2Arm 仓库根目录运行：

   ```sh
   python3 pack/downstream/d2r/package.py \
     --app build/ios/S2Arm.app \
     --d2r-source /path/to/d2r-mobile \
     --d2r-ipa /path/to/D2RMobile-unsigned.ipa \
     --romfs /path/to/RomFS \
     --output build/S2Arm-D2R.ipa
   ```

4. 用自己的签名安装输出的 IPA。更新已有 S2Arm 时沿用原签名团队和 App 标识。把做包时同一份 RomFS 的 `data` 目录放入「文件 → 我的 iPad → S2Arm → D2R Mobile」，再从 S2Arm 游戏库启动。

## 本地存档

长按游戏卡片的「管理存档」可导出整份存档或添加单个角色文件夹。同名角色保留原文件。存档实际写入 `Documents/games/0100726014352000/S2A/ryujinx/bis/user/save`。此前同容器试用版的本地存档会在首次打开时复制，旧目录保留。自动云同步留待后续。

## 源码来源

S2Arm 新接入代码使用 Apache-2.0。运行后端在本机构建自 D2R-Mobile v2.3.5（提交 `66635dac08a68b074779dc59d3825ee8c262afd8`，MIT，版权所有 © 2026 jhaizhou）。`embedded.patch` 在临时源码副本中调整 Mach-O 注册段、启动目录、着色器版本及独立版的云存档初始化。出包保留 D2R-Mobile 的 MIT 许可全文，生成的游戏程序、着色器、游戏资源和 IPA 只在本地使用。

## 存档回归检查

```sh
make native-test-d2r_saves
```
