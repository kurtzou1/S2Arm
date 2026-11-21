# OHOS OpenSSL 依赖

NativeAOT linux-musl-arm64 的 .NET 加密模块需要 `libssl.so.3` / `libcrypto.so.3`。
缺库会 abort，不能用空符号或 Dummy 加密替代。版本及 SHA256 直接读取
`android/openssl/build.sh`，不在鸿蒙维护第二份版本号。

从该脚本注明的官方 OpenSSL Release 下载对应 tar.gz，然后使用已有工具：

```sh
python ohos/openssl/build.py --archive <openssl.tar.gz> --native-sdk <OHOS-native-SDK> --perl <perl> --make <GNU-make> --shell <bash> --out <新的仓库外目录>
```

输出 `package/libssl.so.3`、`package/libcrypto.so.3`、`openssl-LICENSE.txt` 与摘要清单；构建检查 AArch64 与 SONAME。原始归档先核对共享 SHA256，下载、源码和产物不进 Git。

集成 HAP 时把两个版本化库放到与 `libS2AEngine.so` 相同的 arm64 库目录，许可证进入应用资源。不要只复制 `.so` 的符号链接、不要用 Android/bionic 版本替代。外壳的默认构建仍是无引擎开发壳，本脚本不签名、不安装、不替换它。

此入口是供集成者复现的独立依赖构建配方。端到端 HAP 打包、NativeAOT 加密实际调用和真机验证须另记，编译通过不代表这些验收完成。

本轮 Windows 实测：官方 3.5.9 归档摘要与安卓固定值一致；调用 Configure 时，已有 Git Perl 缺 `Locale::Maketext::Simple`（IPC::Cmd 的依赖）而退出，未产出两库。脚本现会在解包前检查这个已有依赖；没有安装或修改环境。请用具备完整 Perl 的既有 Mac/Linux 构建机复验，不能把此配方标记为跨平台构建全绿。
