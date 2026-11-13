# 安卓诊断条目前置策略（仅合成测试）

对应 #528 安卓诊断包隐私边界前置片。运行：

```sh
bash android/tests/diagnostics/run.sh
```

`DiagnosticBundlePolicy` 是纯 Java 的条目名称和字节预算检查器，不读取文件、不扫描目录、不创建 ZIP、不联网；尚未接到导出按钮。测试只传原创名称与数字，不接触真实日志。

## 与既有协议的关系

参考 `ios/diag.m` schema 1 的 `manifest.json`、`logs/host.log`、`logs/frames.tsv`、`logs/threads.txt`、`logs/unpack.log` 和 `runtime/src/os.c` 的归档名称。归档最多 9 项；不通配 `.log` 或任意子目录。固定白名单不含存档、密钥、游戏资源、着色器、截图或 MetricKit 数据。安卓只实现文本条目子集，不改变苹果代码或扩充协议。

单日志上限 8 MiB，与 iOS 初始日志上限一致；manifest 暂定更紧的 256 KiB；本前置片采用更保守的 **未压缩 payload 总量** 30 MiB。iOS 的 30 MiB 是压缩包上限，二者不可混称。未来 ZIP 写出仍需对最终 ZIP（包含头、目录等开销）另做 30 MiB 上限。每份完整提案必须有且仅有一个 manifest，最多 14 项，重复、负大小、越界、非白名单整体失败，不返回可继续导出的部分结果。

## 刻意未实现的边界

名称合法不意味着内容脱敏；manifest 内容及 schema 未由本类验证。未来调用方必须先完成脱敏并验证内容，不得把本类通过当作允许分享。未来采集器还必须基于可信根目录安全打开普通文件，拒绝符号链接/路径替换与特殊文件，核对实际读取量并控制并发变更；本类没有文件 API，不能验证这些条件。不得用本类验证一个名称后读取任意来源路径。本片不授权自动上传、不完成诊断导出 UI。

测试覆盖精确名字、路径穿越及编码变体、大小写/控制字符、禁止资源类别、重复、缺 manifest、空/无效提案、每项及合计边界、整数极值、归档数及总项数上限、失败后无共享残留预算。使用撤除白名单检查的源码变体做负对照。新能力在基线上不存在，不将基线编译缺类计作有效红；负对照是行为红。宿主 JVM 结果不代表 Android 真机导出、文件安全或内容脱敏已验证。

## 脱敏与打包（导出入口第一片）

`DiagnosticRedactor` 是 `tools/redact.py` 的 `redact_text` 的 Java 移植，另加安卓规则：
- 本应用的私有目录、安装目录、外部私有目录由调用方给出，换成 `<APP>` / `<BUNDLE>` / `<APP_EXT>`，保留后面的相对路径（同 iOS 的容器路径）。
- 别的应用数据、`/data/user_de`、`/data/app`、共享存储及其挂载点整段换成 `[PRIVATE_PATH]`；`content://` 只留提供方。
- 玩家导入的 `prod.keys` 里的值先整串换掉。
- 失败抛出，调用方整包放弃，不回退原文。

为了在桌面 Java 与安卓的 ICU 正则上一致，规则不用 `\b` `\s` `\w`，改写成显式字符类；大小写不敏感的区间写成 `A-Za-z`（Python 把 U+212A 开尔文符号算进 `[A-Z]`）；系统错误尾巴用 `\z` 不用 `$`。

`DiagnosticBundleWriter` 从 `files/user/0/saves/<程序号>/ryujinx-android/` 收本机会话日志（`runtime/src/os.c` 写的 `host-<会话>-<进程>-XXXXXX.log`）。
- 只认这个名字形状的普通文件，打开时也不跟随符号链接；同目录的存档不打开。
- 单份超 8 MB 留头 2 MB、尾约 6 MB，只在换行处切；没有换行的那段整段不要。
- 最新一局叫 `logs/host.log`，其余按修改时刻叫 `logs/host-YYYYMMDD-HHMMSS.log`。最多 10 份，总量按 `DiagnosticBundlePolicy` 的预算从新到旧装，装不下的记进 manifest 的 `omitted_logs`。
- 条目先过 `DiagnosticBundlePolicy`，最终 zip 另卡 30 MB，包目录只留最新 3 个。

测试：
- 共同契约 `tests/fixtures/redact_cases.tsv` 逐行比。
- `redact_oracle.py` 用 `tools/redact.py` 算 20000 条随机合成串的期望，与 Java 对拍。注意这把 Java 版绑在 `tools/redact.py` 的全部规则上，不止共同契约那几十条：改 Python 规则要同步改 Java。
- 安卓专有规则与打包的期望值手写（`DiagnosticRedactorTest` / `DiagnosticBundleWriterTest`）。

## 导出入口（第二片）

库页（`LibraryActivity`）的「导出诊断包」按钮在后台线程跑 `DiagnosticExport`：
- 取本应用目录的几种写法、导入的 `files/keys/prod.keys`、版本与机型。key 文件不是普通文件或过大就整次拒绝，因为那样它的值无法隐去。
- 调 `DiagnosticBundleWriter` 写到 `cache/diag`，再经系统分享面板交给玩家选的应用。

`DiagnosticShareProvider` 是不导出的只读 provider，读方只能凭分享意图上的一次性授权进来。它只认 `DiagnosticBundleWriter.shareable` 接受的包名：`cache/diag` 下、本类写出的名字形状、普通文件、不是链接。应用没有 AndroidX，所以没用 FileProvider。

## 系统退出记录（第三片）

`DiagnosticExits` 把系统给本应用各进程（库页、`:game`）记的退出记录（`ApplicationExitInfo`，API 30 起）写进 manifest 的 `exits`。最多 16 条，从新到旧，相当于 iOS 包里的 MetricKit 崩溃 / 卡死 / 退出记录。每条有：
- 时刻、进程名；
- 原因（名字和数值，取值对过 android-36 `android.jar` 的 `REASON_*`）、退出码或信号；
- 重要度、PSS / RSS（KB）、系统给的说明。

字符串照样过脱敏，说明在脱敏之后再截到 300 字，免得把一个秘密截成认不出的半截。不加新文件、不改 `DiagnosticBundlePolicy` 的白名单（manifest 的内容本来就不由它管）。
