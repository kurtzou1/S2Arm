# iOS App 组装（Windows / Mac / Linux）

`app_bundle.py` 只做编完以后的组装：图标、plist 字符串元数据、从只读模板复制新 App、归档 IPA。没有 Mac 工具调用、联网、自动安装或游戏专用分支。安装依赖由用户明确执行，Pillow 在 `launchers/macos/requirements-runtime.txt` 钉为 12.3.0；运行时只要求可以导入，不用图标编码差异判版本失败。

## 输入和所有权

模板是未签名 `.app` 的内容根（将来壳缓存的 `root/`），包括 `Info.plist`、`CFBundleExecutable` 指定的主程序、扁平的 `Frameworks/*.framework` 和资源。当前 `make ios` 仍在 Mac 上编译游戏相关的 App；原生层完成游戏无关壳以前，不把合成模板测试当成真实壳验收。

调用者先用 `pack.shell.cache.ensure` 取得已核验、对号的模板，组装层不重定义清单或壳编号。缓存模板不能就地修改；`assemble` 总是复制到输出同父目录的私有临时目录，完成检查后改名发布。已有目标（包括空目录）报红、不覆盖。调用者独占输出路径及其父目录的发布操作，输入文件在整个调用期间保持不变；不提供跨用户共享目录的锁或对恶意并发修改的隔离。父目录可以是路径别名，模板/内容本身不允许链接或 Windows 重解析点。`assemble` 返回解析父目录别名后的规范 `Path`，不保留调用方路径的词法拼写。

`_CodeSignature`、`embedded.mobileprovision` 残留在模板中报红；`write_icons`、`update_metadata` 只供调用者拥有的未签名新构建目录使用。原地函数单个文件原子替换，I/O 中途失败须弃用这份新构建，不宣称多个文件可以一起事务回滚。`assemble` 的临时副本失败不会发布成品，原模板不变。

两种模式共用一个 API，组装层没有 `mode` 参数。调用者决定三项输入：

| 模式 | 显示名 | 包名 | 图标 |
| --- | --- | --- | --- |
| 单款 | 游戏名称 | 调用者显式提供 | 游戏自己的图标 |
| S2Arm | `S2Arm` | 调用者显式提供，不能拿模板占位包名代替 | `launchers/macos/Branding/AppIcon-iOS.png` |

两种模式输出目录名都为 `S2Arm.app`。此处不放游戏 dylib、不定义多游戏目录、不推设备、不签名；这些分别由游戏镜像、安装、签名接口接续。

## Python / CLI

```python
from pack.app_bundle import assemble, update_metadata, write_icons, write_ipa

app = assemble(template, output_app, bundle_id="org.example.game",
               display_name="游戏名称", icon=icon_path,
               metadata={"S2ABuildID": build_id, "S2APsoTarget": pso_target})
# app-only 到此结束。签名层签 app，核 IML 后才需要归档：
write_ipa(app, output_ipa)
```

```sh
python3 pack/app_bundle.py assemble <模板根> <输出>/S2Arm.app --bundle-id org.example.game --display-name 游戏名称 --icon <图标>
python3 pack/app_bundle.py write_icons <图标> <未签名App>
python3 pack/app_bundle.py update_metadata <未签名App> --set S2ABuildID=本包号 --set S2APsoTarget=
python3 pack/app_bundle.py write_ipa <已签名App> <输出.ipa>
```

CLI 的 stdout/stderr 明确 UTF-8，导入库不更改调用者输出流。成功退出 0，输入/文件操作失败退出 1，用法错误退出 2。缺 Pillow 只给手动安装提示，普通 plist/归档操作不需要 Pillow 导入。

`update_metadata` 只接受字符串或 `None`，空字符串/`None` 删除对应键；未知的原有 plist 键和类型原样保留，XML 写回。`assemble` 始终以显式包名、显示名为准，不允许可选 metadata 反过来覆盖身份。

图标只出 `AppIcon60x60@2x.png`（120×120）、`AppIcon60x60@3x.png`（180×180），RGB PNG、Lanczos 缩放；`CFBundleIcons` 固定为 `CFBundlePrimaryIcon.CFBundleIconFiles=["AppIcon60x60"]`。图标缺失或空文件打黄、返回 False/退出 0，不改 App；非空但损坏/超大/不可读则报红。未增 iPad 图标或 icns，不承诺 Pillow 与 sips 缩放/PNG 编码逐字节一致。

## IPA 字节与权限

`write_ipa` 允许签后材料，只读取 App，不改任何文件内容或源文件权限。流式归档为 `Payload/S2Arm.app/`，含目录条目，文件 deflate、非 ASCII 名称用 UTF-8 ZIP 标志，`create_system=3`。临时 IPA 写完才以不覆盖的硬链接发布；文件系统不支持该操作时明确失败，不退回覆盖写入。

Windows 与 Mac 共用权限规则，完全不依赖 Windows stat 的执行位：

- 主程序（App 的 `CFBundleExecutable`）、`Frameworks/*.framework` 各自 plist 指定的程序、全部 `.dylib` 为 0755。
- 目录为 0755，其余文件为 0644，带普通文件/目录类型位。
- 相应可执行文件缺失或路径逃逸报红。所有链接、重解析点、特殊文件、Windows 名称/大小写碰撞均拒绝。

与旧包的明确差异：旧 `main.npdm` 保留源权限 0640，新规则统一为 0644。XML 排版、PNG 编码、ZIP 时间/额外字段/压缩容器也可能不同；比较 plist 键值/类型、图标尺寸、成员集合、逐文件内容和明确的执行位，不要求 IPA 整包哈希相等。这些检查不验证密码学签名/信任链、安装成功、IML 扩容或游戏运行。

## 验证和接线

```sh
python3 -I -B tests/test_app_bundle.py
S2A_PY=<已装Pillow的Python> bash tests/app_bundle_test.sh
S2A_PY=<已装Pillow的Python> bash tests/app_icon_test.sh
```

`pack/ipa.sh` 保留编译、身份来源、签名、签后 IML、资源包及阶段根逻辑；只将原图标/plutil 更新/zip 调用委托本模块。`runtime/build.mk` 不改，Mac 预编基础 plist 的阶段无需在 Windows 重跑。`pack/app_icon.sh` 已删除，无兼容实现。oneclick 开工检查增加 PIL；新增 Runtime 依赖将使 Mac 内置 Runtime 的缓存键改变、整套重建一次，这是预期成本。

测试全部为原创 PNG/plist/普通字节夹具，覆盖两种调用者身份、内容/类型、失败发布、真实链接/junction、UTF-8 CLI 和归档；Linux/Windows 专项 skip 单列。出包线负责同提交 Mac 新旧真实产物对照及两平台结构对照；正式壳未发版时，Windows 真实壳组装留到发版后验。没有用模拟夹具宣称正式下载、签名、安装或游戏可玩。
