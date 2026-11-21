# T05 独立 JNI 改写准备库

`NativeRewriter` 从受信 App 私有工作区复制 NSO 与可选表，生成本次独占的改写产物并返回身份校验结果。它复用 `runtime/rewriter` 的 C ABI，目标固定 `android`，每次显式传入 spin、SDK cut、widen、fps。默认参数口径为 spin=false、SDK cut=true。调用由 App 的后台 worker 承担，Job/Event 映射沿用 J10，后续模块组装与激活由已有 GameInstall/BootContract 接口承接。

## 调用与所有权

调用方传入 `Context.getFilesDir()` 下独立创建、仅 owner 有权限的工作区，输入文件先由导入/解包流程写入该工作区。工作区与 active revisions 分开管理。

```java
NativeRewriter.Result result = NativeRewriter.rewrite(
    workspace, workspace.resolve("main.nso"), "main",
    false, true, null, null);
if (!result.succeeded()) {
    // 向既有任务执行器报告 nativeStatus、validationError 和私有诊断。
    return;
}
// 由既有产物组装/安装器验证后消费 result.output。
```

- 每次创建新的 `0700` attempt/output，NSO 和表复制到本次 `0400` 快照，并记录复制字节的大小与 SHA-256；原始输入之后变化不影响本次快照。
- 拒绝工作区内软链接、越界输入、公开权限的根目录、NUL/非法 Unicode 和不合法模块名。路径使用严格 UTF-8 byte[]，JNI 复制成调用拥有的缓冲；不使用 Modified UTF-8 路径。
- 路径检查基于受信 App 私有目录假设。它不提供 `openat` 级别的同 UID 恶意线程隔离，也不替调用方判定目录是否来自正确 Context。
- 必需产物为 patched.bin / fixups.tsv / gates.tsv / sites.tsv / gaps.tsv，widen.tsv 可选；校验完整文件集、TARGET、ABI、零 LOAD_BIAS、源 NSO BUILD_ID、无 GAP、非空映像，并为每文件返回大小与 SHA-256。
- C 的 0/3/1 保存在 `nativeStatus`。C 返回 0 后若产物校验失败，`succeeded()` 仍为 false，`validationError` 解释原因。失败产物不激活，已有目录不覆盖。
- 本库的所有 JNI 调用由同一加载 DSO 内的静态 mutex 串行化。其他 DSO 副本或直接 C API 调用不在这个锁的覆盖范围内。
- 返回的诊断摘要最多读取 64KiB 原始日志字节，截断有标记；私有原始日志及失败 staging 的保留由调用方管理。共享核心源码另有写进程 stderr 的 FPS 警告分支，本库不重定向全局 stdio，摘要不承诺收齐该分支。
- native 调用是阻塞的，模块之间的取消由调用方处理。该片不提供进程内中断、任务 journal 或 revision 激活协议。

## 可选构建

准备库实验开关缺省为 0；普通 App 构建不读取改写器依赖或增加准备库目标。开发时显式开启：

```sh
S2ARM_ANDROID_REWRITER=1 S2A_REWRITER_DEPS=/path/to/pinned-deps ./gradlew :app:assembleDebug
# 等价属性：-Ps2arm.rewriter=1 -Ps2arm.rewriterDeps=/path/to/pinned-deps
```

依赖必须预先按 `runtime/rewriter/prepare_deps.py` 准备，构建不下载它们。`gate.sh` 和直接执行的
`tests/native_rewriter_test.py` 都复用 `pack/rewriter.py` 的 `dependency_dir()`，
按共享解析器现有顺序查找，`S2A_REWRITER_DEPS` 不是必填变量。平台门禁在 JDK/测试前
解析成功后导出该绝对路径，供 JNI 与 C/Python 矩阵统一使用；真缺 Capstone/LZ4 源码
时输出一行【红】并退出，直接 JNI 测试也在 JDK/构建前独立报红。不会因外部 CLI 覆盖
跳过 mandatory 同源测试，也不安装或从 Python 模块目录猜测 C 源码。

`libs2arm_rewriter.so` 静态包含固定 Capstone/LZ4、隐藏 C 核心符号，只导出 JNI 入口，Android arm64/API34，16KiB ELF LOAD 对齐。Gradle 通过 Variant generated-assets API 生成 Capstone BSD/LLVM 与 LZ4 C BSD2 许可；APK 检查器在包含准备库时强制这两份非空许可。

电脑产品出包入口仍按统一 refresh 流程；这里的独立 CMake 和测试命令用于开发验证。设备内准备不运行 bash。

## 开发验证

```sh
JAVA_HOME=/path/to/jdk17 S2A_REWRITER_DEPS=/path/to/pinned-deps \
  python3 android/tests/native_rewriter_test.py
```

该测试用同一构建的 host JNI 与 CLI 实际对拍合成输入，覆盖压缩输入、模块名、可选表、有效 spin/SDK-cut 变化、错误恢复、私有路径、并发调用者及完整产物字节/SHA。`S2A_JNI_EVIDENCE=<新目录>` 可保留日志。JNI raw 控制进程不使用 Path/Files，单独要求 `-Xcheck:jni` 无 warning；Java facade 的 warning 单独记录。macOS JDK17 的 Unicode Path 正控出现过相同 Critical warning，不能把 facade 功能通过记成 CheckJNI 干净。

NDK 入口独立于游戏运行时：

```sh
cmake -S android/rewriter -B build/android-rewriter \
  -DCMAKE_TOOLCHAIN_FILE=/path/to/ndk/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-34 \
  -DS2A_REWRITER_DEPS=/path/to/pinned-deps
cmake --build build/android-rewriter --parallel 2
```

使用真实构建的 Android host/准备库和真实许可测试 native ZIP 规则：

```sh
python3 android/tests/native_rewriter_packaging_test.py \
  --host /path/to/libs2arm_android.so --rewriter /path/to/libs2arm_rewriter.so \
  --licenses /path/to/generated/rewriter-assets/licenses
```

这里验证 ELF、ZIP 对齐及许可/库名单的正反例，不是可安装 APK、App UID 或设备运行证据。宿主 JVM JNI、NDK、AGP 资产合并、完整 APK、App UID 与游戏起局分别记录。本片没有完成 App UID 验收；main 的普通共享页 producer 修复继续依赖 #499。

平台门禁经 `test.sh` 实际执行 host JNI 矩阵及 `--format-fixture` 的 ZIP 准入单测，`S2A_TEST_NO_NATIVE` 只跳过 Linux runtime 的 mremap/CTest 部分。格式单测的 ELF/许可占位只验证格式与准入规则，不代表真实代码或许可验证；上面的显式真实库模式用于另行核验实际 NDK/许可字节。

测试宿主需要系统实际安装的 C.UTF-8 或 en_US.UTF-8 locale。harness 只为 Java/CLI 子进程选择 UTF-8，不更改外层门禁的 C locale；避免 JDK17 ProcessBuilder 在 ASCII/无效 locale 下把中文 argv 编成问号。选择值记录在私有测试证据中，没有可用 locale 会明确失败。

平台门禁选择 JDK17 的 javac 后，向该编译器的 VM 查询真实 `java.home`，再设置 `JAVA_HOME/PATH`。Homebrew keg 的 `bin/javac` 软链父目录可能不是完整 JDK Home；JNI 检查仍要求完整 JDK，不跳过检查，也不依赖系统 `java_home` 对版本的宽松匹配。
