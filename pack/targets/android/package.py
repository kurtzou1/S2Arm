#!/usr/bin/env python3
"""Android per-game delivery using the existing pack, Gradle and resource tools."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import platform
import re
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import struct
import zipfile
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from pack.contracts.validate import validate


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 << 20), b''):
            h.update(block)
    return h.hexdigest()


def manifest(root, apk, resources, environment=None, interpreter=None):
    artifact = json.loads((resources / 'game-build-artifact.json').read_text())
    if artifact['target'] != 'android' or artifact['apk']['sha256'] != sha256(apk):
        raise ValueError('资源包与 APK 身份不一致。')
    files = []
    for path in [apk, *sorted(resources.rglob('*'))]:
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError('产物目录含软链或越界路径。')
        if path.is_file():
            files.append(dict(path=path.relative_to(root).as_posix(), size=path.stat().st_size,
                              sha256=sha256(path)))
    doc = dict(schema='s2a.artifact.v2', target='android', files=files,
               details=dict(schema='s2a.artifact.android.v1', apk=apk.name,
                            resourcePack=resources.name, titleId=artifact['titleId'],
                            apkSha256=artifact['apk']['sha256'],
                            signingCertSha256=artifact['apk']['signingCertSha256'],
                            contentRoot=artifact['contentRoot'], inputFrozen=False,
                            inputStatus='输入未冻结：T04（#559）未入 main'))
    if environment is not None:
        doc['details']['buildEnvironment'] = {'python': interpreter or sys.executable,
                                               'variables': dict(sorted(environment.items()))}
    return validate('artifact', doc)


def elf_build_id(data):
    """Read one SHA-1 GNU build-id from a little-endian AArch64 ELF PT_NOTE."""
    if len(data) < 64 or data[:6] != b'\x7fELF\x02\x01' or data[16:20] != b'\x03\x00\xb7\x00':
        raise ValueError('运行时库不是 Android AArch64 ELF。')
    phoff = struct.unpack_from('<Q', data, 32)[0]
    entsize, count = struct.unpack_from('<HH', data, 54)
    if entsize < 56 or count == 0 or phoff + entsize * count > len(data):
        raise ValueError('运行时库 ELF program header 无效。')
    ids = []
    for i in range(count):
        typ, _, offset, _, _, size, _, _ = struct.unpack_from('<IIQQQQQQ', data, phoff + i * entsize)
        if typ != 4:
            continue
        if offset + size > len(data):
            raise ValueError('运行时库 ELF note 越界。')
        pos, end = offset, offset + size
        while pos + 12 <= end:
            namesz, descsz, kind = struct.unpack_from('<III', data, pos); pos += 12
            name_end = pos + namesz; desc_pos = (name_end + 3) & ~3
            desc_end = desc_pos + descsz; next_pos = (desc_end + 3) & ~3
            if next_pos > end:
                raise ValueError('运行时库 ELF note 无效。')
            if kind == 3 and data[pos:name_end] == b'GNU\0':
                ids.append(data[desc_pos:desc_end].hex())
            pos = next_pos
    if len(ids) != 1 or not re.fullmatch(r'[0-9a-f]{40}', ids[0]):
        raise ValueError('运行时库缺少唯一 GNU build-id。')
    return ids[0]


def apk_provider_build_id(apk):
    name = 'lib/arm64-v8a/libs2arm_android.so'
    try:
        with zipfile.ZipFile(apk) as archive:
            entries = [item for item in archive.infolist() if item.filename == name]
            if len(entries) != 1:
                raise ValueError('APK 缺少唯一游戏运行时库。')
            return elf_build_id(archive.read(entries[0]))
    except (OSError, zipfile.BadZipFile, EOFError) as error:
        raise ValueError('APK 运行时库无法读取。') from error


def verify_game_provider(build_source, start_ns, apk, containerized=True):
    reports = []
    for path in (build_source / 'android').rglob('core-link-*.json'):
        if path.stat().st_mtime_ns < start_ns:
            continue
        report = json.loads(path.read_text())
        if report.get('provider_role') != 'game' or report.get('provider_link_complete') is not True:
            continue
        native = Path(report['artifacts']['native_library']['path'])
        if containerized:
            try:
                relative = native.relative_to('/src')
            except ValueError as error:
                raise ValueError('运行时链接报告路径无效。') from error
            library = (build_source / relative).resolve()
        else:
            if not native.is_absolute():
                raise ValueError('运行时链接报告路径无效。')
            library = native.resolve()
        if not library.is_relative_to(build_source.resolve()) or not library.is_file() or sha256(library) != report['artifacts']['native_library']['sha256']:
            raise ValueError('运行时链接报告与本次产物不一致。')
        build_id = report['artifacts']['native_library'].get('build_id')
        if not build_id or elf_build_id(library.read_bytes()) != build_id or apk_provider_build_id(apk) != build_id:
            raise ValueError('APK 游戏运行时库与链接报告 build-id 不一致。')
        reports.append(path)
    if len(reports) != 1:
        raise ValueError('缺少本次游戏运行时链接通过的报告。')


def build_backend(env):
    """出包后端自动选（#1131，owner 定）：Docker 只留给 Linux 主机——Linux 走 docker，
    缺 docker 或 daemon 起不来直接报红；Darwin 走 host 原生，不碰 docker；其它系统报红。
    Darwin x86_64 宿主路径未实机验证：按 owner 复审口径明确报红「未验证」，
    不放行半通状态（维护方复审 6546409619 第 6 条）。两个方向都不自动退，也没有手工开关。"""
    system = platform.system()
    if system == 'Darwin':
        machine = platform.machine()
        if machine != 'arm64':
            raise ValueError(f'安卓出包宿主原生路径未在 Darwin {machine}（Intel Mac）上实机验证：'
                             '请在 Apple Silicon Mac 或带 Docker 的 Linux 主机上构建；'
                             '该路径未验证前不提供宿主出包，也不回退 Docker。')
        return 'host'
    if system == 'Linux':
        docker = shutil.which('docker', path=env.get('PATH', os.defpath))
        if not docker:
            raise ValueError('Linux 安卓出包需要 Docker：找不到 docker 命令，请先安装并启动 Docker。')
        try:
            healthy = subprocess.run([docker, 'info'], env=env, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, timeout=10).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            healthy = False
        if not healthy:
            raise ValueError('Linux 安卓出包需要 Docker：docker info 失败，请启动 Docker daemon。')
        return 'docker'
    raise ValueError(f'安卓构建不支持该宿主：{system}-{platform.machine()}')


def java_runtime_ok(env):
    """本机有能用的 Java 运行时（apksigner 是 Java 程序）。Mac 的 /usr/bin/java 是没装 JDK 也存在的空壳，所以要真跑一次。"""
    home = env.get('JAVA_HOME')
    java = str(Path(home) / 'bin/java') if home and (Path(home) / 'bin/java').is_file() else shutil.which('java', path=env.get('PATH', os.defpath))
    if not java:
        return False
    try:
        return subprocess.run([java, '-version'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


ANDROID_MAX_VERSION_CODE = 2100000000


def android_version_code(now=None):
    """同款连续出包，后出的 versionCode 一定更大，能直接覆盖装、存档保留。"""
    code = int(time.time() if now is None else now)
    if not 1 <= code <= ANDROID_MAX_VERSION_CODE:
        raise ValueError('出包时刻换算的 versionCode 超出安卓允许范围。')
    return code


def build_variant(environ=None):
    """玩家包一律正式构建（10-31 维护者）；只有我们自己的验证包设 S2A_ANDROID_DEBUG_BUILD=1 出调试构建
    （调试入口另要设备上 adb shell setprop debug.s2a.debug_env 1 才开，见 android/native/debug_gate.h）。"""
    return 'debug' if (os.environ if environ is None else environ).get('S2A_ANDROID_DEBUG_BUILD') == '1' else 'release'


def build_parent(out, home=None, system=None):
    """源码临时树放哪：Mac 上 docker（colima / Docker Desktop）缺省只挂载家目录，输出目录在外接盘等家目录以外时，
    临时树放 ~/.cache/s2arm-android-build（10-31 合入线：--out 指到外接盘时容器挂不进源码，出包退出码 125）。
    体积大的产物（解包、资源包、APK）仍落在 --out。"""
    home = Path.home() if home is None else Path(home)
    if (platform.system() if system is None else system) != 'Darwin' or out.resolve().is_relative_to(home.resolve()):
        return out
    parent = home / '.cache/s2arm-android-build'
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    return parent


def apk_output(variant):
    return f'android/app/build/outputs/apk/{variant}/app-{variant}.apk'


def verify_native_optimized(build_source, variant, start_ns=0):
    """游戏原生库按优化编译：本次 CMake 生成的编译命令里 s2arm_android 的源文件都带 -O2 / -O3，正式构建还要带 -DNDEBUG。
    读构建目录里的 compile_commands.json（AGP 每个配置一份），不按配置名猜编译参数；只认本次游戏构建开始后写的
    （同 verify_game_provider：出游戏包前那次诊断用的默认调试构建也留了 .cxx/Debug，10-31 合入线误扫到它的 memory.c）。"""
    found = 0
    for commands in (build_source / 'android/app/.cxx').rglob('compile_commands.json'):
        if commands.stat().st_mtime_ns < start_ns:
            continue
        for entry in json.loads(commands.read_text()):
            command = entry.get('command') or ' '.join(entry.get('arguments', []))
            source = entry.get('file', '')
            if '/android/' not in source or 's2arm_android' not in command:
                continue
            if not source.endswith(('.c', '.cc', '.cpp', '.cxx')):
                continue   # 汇编（.S）不吃 -O，游戏模式的 -O2 只加在 C / C++ 上（10-31 调试构建误拦 selftest_gate.S）
            found += 1
            flags = command.split()
            if not any(flag in ('-O2', '-O3') for flag in flags):
                raise ValueError(f'游戏原生库未按优化编译：{entry["file"]}')
            if variant == 'release' and '-DNDEBUG' not in flags:
                raise ValueError(f'正式构建的游戏原生库没带 -DNDEBUG：{entry["file"]}')
    if not found:
        raise ValueError('找不到本次游戏原生库的编译命令（compile_commands.json），无法核实优化参数。')


def sdk_pins():
    # 固定 Android 组件版本的唯一来源：docker/Dockerfile 的 ARG SDK_PACKAGES（复审第 1 条）。
    # 与 tools/versions.sh 解析同一行；shell 侧与这里都不许第二份字面量。
    dockerfile = Path(__file__).resolve().parents[3] / 'android/docker/Dockerfile'
    m = re.search(r'^ARG SDK_PACKAGES="([^"]+)"$', dockerfile.read_text(), re.M)
    if not m:
        raise ValueError('无法解析 android/docker/Dockerfile 的 ARG SDK_PACKAGES')
    return dict(pkg.split(';', 1) for pkg in m[1].split())


def sdk_dir_from_properties(path):
    """local.properties 的 sdk.dir：多行时末行生效，值取 `=` 后整行（允许含空格，
    去掉行尾空白）；没有文件或没有 sdk.dir 行返回 None。"""
    sdk_dir = None
    if not path.is_file():
        return None
    for line in path.read_text(errors='replace').splitlines():
        m = re.match(r'\s*sdk\.dir\s*=\s*(.*)', line)
        if m:
            sdk_dir = m[1].rstrip()
    return sdk_dir


def android_sdk_home(env):
    """SDK 目录解析唯一实现（#1207 复审三条：host/hostenv.sh 也调这里，不再各自解析）：
    ANDROID_HOME → ANDROID_SDK_ROOT → android/local.properties 的 sdk.dir
    → Darwin 默认 ~/Library/Android/sdk → 其它宿主 ~/Android/Sdk。"""
    sdk = env.get('ANDROID_HOME') or env.get('ANDROID_SDK_ROOT')
    if sdk:
        return sdk
    props = Path(__file__).resolve().parents[3] / 'android/local.properties'
    sdk_dir = sdk_dir_from_properties(props)
    if sdk_dir:
        return sdk_dir
    home = Path(env.get('HOME') or str(Path.home()))
    return str(home / ('Library/Android/sdk' if platform.system() == 'Darwin' else 'Android/Sdk'))


def host_signer_env(build_source, env):
    """host 后端验签用的环境：构建由 host/hostenv.sh 经 tools/jdk17.sh 找 JDK 17（Homebrew 装的不进 PATH、
    也不登记 java_home），apksigner 是 Java 程序，要用同一个 JDK，否则落到 Mac 的 /usr/bin/java 空壳。"""
    if java_runtime_ok(env):
        return env
    try:
        found = subprocess.run(['bash', str(Path(build_source) / 'android/tools/jdk17.sh')], env=env, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return env
    javac = found.stdout.strip() if found.returncode == 0 else ''
    if not javac:
        return env
    home = str(Path(javac).parent.parent)
    return {**env, 'JAVA_HOME': home, 'PATH': str(Path(home) / 'bin') + os.pathsep + env.get('PATH', os.defpath)}


def verify_signature(build_source, apk, env, backend, variant='release'):
    sdk = android_sdk_home(env)
    pinned = Path(sdk) / 'build-tools' / sdk_pins()['build-tools'] / 'apksigner'
    local = str(pinned) if pinned.is_file() and os.access(pinned, os.X_OK) else shutil.which('apksigner', path=env.get('PATH', os.defpath))
    # Docker 后端（Mac）：本机装了 SDK 却没装 Java 很常见，本机 apksigner 起不来；事先选容器里的 apksigner，
    #   不是本机验签失败后再换 Docker 重试（签名失败不能冒充通过）。host 后端本来就要求 JDK 17，不变。
    if local and backend == 'docker' and not java_runtime_ok(env):
        local = None
    if local:
        subprocess.run([local, 'verify', str(apk)], env=host_signer_env(build_source, env) if backend == 'host' else env, check=True)
    elif backend == 'docker':
        image = env.get('S2ARM_ANDROID_IMAGE', 's2arm-android-build:1')
        subprocess.run(['docker', 'run', '--rm', '--network', 'none',
                        '--mount', f'type=bind,source={build_source},target=/src,readonly',
                        '--entrypoint', 'bash', image, '-c',
                        '"$ANDROID_HOME/build-tools/' + sdk_pins()['build-tools'] + '/apksigner" verify /src/' + apk_output(variant)],
                       env=env, check=True)
    else:
        raise ValueError(f'找不到 apksigner：安装 Android SDK build-tools;{sdk_pins()["build-tools"]} 并设置 ANDROID_HOME，或将 apksigner 加入 PATH。')


# Host tool and cache locations are the only caller-supplied settings that the
# packaging children need. Rewrite selection, community patches, interpreter
# injection, and ambient compiler flags are deliberately not inherited.
BUILD_ENV_ALLOWED = frozenset({
    'PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'JAVA_HOME', 'DOTNET_ROOT',
    'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'ANDROID_NDK_HOME', 'ANDROID_NDK_ROOT',
    'ANDROID_USER_HOME', 'GRADLE_USER_HOME', 'NUGET_PACKAGES',
    'S2A_ANDROID_DOTNET', 'S2A_JAVAC', 'S2A_REWRITER_DEPS', 'S2A_RUN_ROOT',
    'S2A_BUILD_CACHE', 'S2ARM_ANDROID_IMAGE', 'S2ARM_ANDROID_CACHE',
    'S2A_MAX_INDEX_BYTES',   # 只抬高 direct_library 的 index.tsv 读取上限（超大型 RomFS 显式放开，见 direct_library.py）
    'S2A_VULKAN_PROFILE', 'S2A_VULKAN_REFS',
})


def build_environment(environ):
    env = {key: environ[key] for key in BUILD_ENV_ALLOWED if key in environ}
    env.setdefault('PATH', os.defpath)
    env.update(S2A_REWRITE_SPIN='0', S2ARM_ANDROID_CS_SERVICES='static',
               S2A_ANDROID_SKIP_APPLE_ARTIFACTS='1', S2A_TARGET='android',
               S2ARM_ANDROID_VK_ENGINE='1', S2ARM_ANDROID_VK_BACKEND='nvn_vk',
               S2ARM_ANDROID_GAME_DIR='build/android-game/input',
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    # #1207 复审二轮：local.properties 被 gitignore、不进导出树——把解析出的
    #   SDK 路径显式写进构建环境，导出树里的构建与验签用同一条结论。
    env['ANDROID_HOME'] = android_sdk_home(env)
    return env


def verify_manifest(root, apk, resources, ledger):
    """Recompute file identities and validate the recorded child environment."""
    if not isinstance(ledger, dict):
        raise ValueError('安卓产物账本无效。')
    details = ledger.get('details')
    record = details.get('buildEnvironment') if isinstance(details, dict) else None
    if not isinstance(record, dict) or set(record) != {'python', 'variables'}:
        raise ValueError('安卓产物账本缺少构建环境。')
    interpreter, variables = record['python'], record['variables']
    if (not isinstance(interpreter, str) or not os.path.isabs(interpreter)
            or not isinstance(variables, dict)
            or any(not isinstance(k, str) or not isinstance(v, str) or '\0' in k or '\0' in v
                   for k, v in variables.items())
            or build_environment(variables) != variables):
        raise ValueError('安卓产物账本构建环境无效。')
    computed = manifest(root, apk, resources, variables, interpreter)
    if computed != ledger:
        raise ValueError('安卓产物账本不匹配。')
    return computed


def export_sources(destination, env):
    """Build from a committed source export outside the repository checkout."""
    if subprocess.run(['git', '-C', str(ROOT), 'diff', '--quiet', 'HEAD', '--'], env=env).returncode:
        raise ValueError('引擎源码有未提交的修改，无法固定安卓构建输入。')
    destination.mkdir(mode=0o700)
    archive = destination.parent / 'source.tar'
    try:
        with archive.open('wb') as stream:
            subprocess.run(['git', '-C', str(ROOT), 'archive', '--format=tar', 'HEAD'],
                           env=env, stdout=stream, check=True)
        subprocess.run(['tar', '-xf', str(archive), '-C', str(destination)], env=env, check=True)
    finally:
        archive.unlink(missing_ok=True)


def direct_vulkan_candidate(root, tools):
    """#48 P5：Vulkan 类游戏（main 导入 vk*、不导入 NVN / EGL，加载器 / 驱动模块能干净替换）出包要带 direct-vulkan.txt，
    安卓侧 s2a_vk_lib_ready / AUTO 才有判定依据；别的游戏照旧不带。判定用导出源码树里同一份 vulkan_modules.replaced_modules
    （make_pack --direct-vulkan 写描述符时也是它），返回 (是否带, 不带的原因)。读不了模块表这类意外也按「不带」处理并给出原因：
    这一步只决定加不加一个可选描述符，不能让本来出得了的包因此失败。"""
    exefs = Path(root) / 'exefs'
    if not exefs.is_dir():
        return False, ''
    spec = importlib.util.spec_from_file_location('s2a_vulkan_modules', Path(tools) / 'vulkan_modules.py')
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
        module.replaced_modules(exefs)
    except Exception as error:   # noqa: BLE001 — 原因原样交给调用方打印
        return False, f'{type(error).__name__}: {error}'
    return True, ''


def latest_release(releases):
    """The newest published release whose resource package is complete, or None.

    The next release's read-only files are hard-linked to it (game_apk.py --resources --reuse-from) instead of
    being written again: ext4 has no reflink, so every release used to keep a full copy of the RomFS.
    A release is published only by the final rename (ledger written first), so '.'-named staging directories,
    symlinks and directories missing the ledger or the package manifest are not candidates. What game_apk.py
    actually links is decided by hash against the new package's own index, so a stale or foreign candidate
    only costs the links, never correctness."""
    newest = None
    try:
        candidates = list(releases.iterdir())
    except OSError:
        return None
    for path in candidates:
        if path.name.startswith('.') or path.is_symlink() or not path.is_dir():
            continue
        ledger = path / 'artifact.json'
        if not ledger.is_file() or not (path / 'resources' / 'manifest.json').is_file():
            continue
        stamp = ledger.stat().st_mtime_ns
        if newest is None or stamp > newest[0]:
            newest = (stamp, path)
    return newest[1] if newest else None


def package(root, out):
    root, out = Path(root).resolve(), Path(out).resolve()
    releases = out / 'android-releases'
    if out == ROOT.resolve() or out.is_relative_to(ROOT.resolve()) or root == ROOT.resolve() or root.is_relative_to(ROOT.resolve()):
        raise ValueError('游戏输入和输出必须在源码仓库之外。')
    if not root.is_dir() or root == releases or root in releases.parents or releases in root.parents:
        raise ValueError('刷新产物根与交付目录不可重叠。')
    # A source bundle may provide only the diagnostic shell. Never label it playable.
    gradle = (ROOT / 'android/app/build.gradle').read_text()
    if 's2arm.nativeMode' not in gradle or not (ROOT / 'android/app/src/main/java/org/s2arm/android/LibraryActivity.java').is_file():
        raise ValueError('Android 游戏运行时尚未接入：请使用包含游戏运行时的完整引擎源码。')
    out.mkdir(mode=0o700, parents=True, exist_ok=True)
    releases.mkdir(mode=0o700, exist_ok=True)
    env = build_environment(os.environ)
    py = sys.executable
    with (out / '.android-oneclick.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with tempfile.TemporaryDirectory(prefix='.android-build-', dir=build_parent(out)) as build_tmp, \
             tempfile.TemporaryDirectory(prefix='.android-release-', dir=releases) as output_tmp:
            build_source = Path(build_tmp) / 'src'
            export_sources(build_source, env)
            tool = build_source / 'android/tools'
            game_dir = build_source / 'build/android-game/input'
            game_dir.parent.mkdir(parents=True)
            stage = Path(output_tmp)
            original_pack = stage / 'source-pack'
            resources = stage / 'resources'
            apk = stage / 'game.apk'
            # 两次 make_pack 必须一致：describe 记下的 gameContentRoot 覆盖 direct-vulkan.txt 这一行，只在第二次带会对不上
            vulkan, why_not = direct_vulkan_candidate(root, tool)
            vulkan_flag = ['--direct-vulkan'] if vulkan else []
            if vulkan:
                print('Vulkan 类游戏：包里带 direct-vulkan.txt（AUTO 据此判直连）。')
            elif why_not and not why_not.startswith('ValueError: direct Vulkan requires Vulkan main imports'):
                print('🟡 不带 direct-vulkan.txt（' + why_not + '）：本包照旧走通用路径。')
            subprocess.run([py, str(tool / 'make_pack.py'), str(original_pack), '--root', str(root), *vulkan_flag],
                           env=env, check=True)
            backend = build_backend(env)
            builder = build_source / ('android/docker/build.sh' if backend == 'docker' else 'android/host/build.sh')
            # 描述符的翻译闭包取本源码树编译器的构建身份（与 APK 里的编译器同源同配置）。
            subprocess.run(['bash', str(builder), '--direct-identity'], env=env, check=True)
            identity = build_source / 'build/android-direct/identity.json'
            descriptor = stage / 'graphics.v1.json'
            subprocess.run([py, str(tool / 'direct_library.py'), 'describe', '--pack', str(original_pack),
                            '--identity', str(identity), '--descriptor', str(descriptor)], env=env, check=True)
            direct_pack = stage / 'direct-pack'
            subprocess.run([py, str(tool / 'make_pack.py'), str(direct_pack), '--root', str(root),
                            '--direct-graphics', str(descriptor), *vulkan_flag], env=env, check=True)
            shutil.rmtree(original_pack)
            original_pack = direct_pack
            # 离线 Vulkan 着色器包（target.json「shaders」，#1574）：包 manifest 绑定安装 revision 的
            #   内容根（index 去 shaders/ 行），要等 make_pack 写出 index 才存在，只能放在出包期；
            #   抽取 / 程序表 / S2A.ShBake / attach_shaders 全是共享流水线现成的。没有真机导出的
            #   S2A_VULKAN_PROFILE 就不出包——host 不能猜设备能力，设备端按现行口径首遇现编兜底。
            shader_pack = None
            shader_profile = os.environ.get('S2A_VULKAN_PROFILE')
            if shader_profile:
                bake_out = stage / 'shader-pack'
                bake_args = [py, str(tool / 'bake_shaders.py'), str(original_pack),
                             '--root', str(root), '--profile', shader_profile,
                             '--out', str(bake_out)]
                for ref in os.environ.get('S2A_VULKAN_REFS', '').split():
                    bake_args += ['--ref', ref]
                spirv_val = shutil.which('spirv-val', path=env.get('PATH', os.defpath))
                if spirv_val:
                    bake_args += ['--spirv-val', spirv_val]
                subprocess.run(bake_args, env=env, check=True)
                bake_summary = json.loads((bake_out / 'bake.json').read_text(encoding='utf-8'))
                shader_pack = bake_summary.get('pack')
                if not shader_pack and bake_summary.get('reason'):
                    print('🟡 ' + str(bake_summary['reason']) + '：本包不含离线着色器。')
            else:
                print('🟡 未提供 S2A_VULKAN_PROFILE（真机导出的 Vulkan 翻译 profile）：'
                      '本包不含离线着色器，设备首遇按现行口径现编。')
            # versionCode 按出包时刻（秒）单调递增：固定 1 时，机上装过更高版本的同款包就覆盖不了（INSTALL_FAILED_VERSION_DOWNGRADE），
            #   玩家只能卸载重装、存档跟着丢（10-30 #693 本机复验）。秒数在 2036 年前都低于安卓上限 2100000000。
            version_code = android_version_code()
            subprocess.run([py, str(tool / 'game_apk.py'), str(original_pack), str(game_dir),
                            '--version-code', str(version_code),
                            *(('--shader-pack', shader_pack) if shader_pack else ())],
                           env=env, check=True)
            app_build = build_source / 'android/app/build'
            if app_build.is_symlink():
                raise ValueError('安卓构建目录不能是软链。')
            if app_build.exists():
                if not app_build.is_dir():
                    raise ValueError('安卓构建目录无效。')
                shutil.rmtree(app_build)
            # Existing default entry builds NativeAOT and OpenSSL; explicit second
            # invocation selects the game provider and cleans stale app output.
            subprocess.run(['bash', str(builder)], env=env, check=True)
            start_ns = time.time_ns()
            variant = build_variant()
            task = variant.capitalize()
            subprocess.run(['bash', str(builder), '-Ps2arm.nativeMode=game', ':app:clean',
                            f':app:assemble{task}', f':app:lint{task}'], env=env, check=True)
            built = build_source / apk_output(variant)
            if built.is_symlink() or not built.is_file():
                raise ValueError('构建未产生本次 APK。')
            shutil.copyfile(built, apk)
            verify_game_provider(build_source, start_ns, apk, containerized=backend == 'docker')
            subprocess.run([py, str(build_source / 'android/verify-apk.py'), str(apk)], env=env, check=True)
            verify_native_optimized(build_source, variant, start_ns)
            verify_signature(build_source, apk, env, backend, variant)
            if sha256(apk) != sha256(built):
                raise ValueError('构建输出在签名验证期间变化。')
            previous = latest_release(releases)   # 持着出包锁：不会有别的出包在这时发布新的
            subprocess.run([py, str(tool / 'game_apk.py'), '--resources',
                            *(('--reuse-from', str(previous / 'resources')) if previous else ()),
                            str(original_pack), str(apk), str(resources)], env=env, check=True)
            if shader_pack:
                # 把离线包挂进安装资源包：行追加进 index、manifest 绑定的是挂前的内容根
                #   （attach_shaders.py 自己核 contentRoot，与烘焙时 --content-root 一致）。
                subprocess.run([py, str(tool / 'attach_shaders.py'), str(resources),
                                str(shader_pack)], env=env, check=True)
            shutil.rmtree(original_pack)
            descriptor.unlink()
            ledger = manifest(stage, apk, resources, env)
            (stage / 'artifact.json').write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n')
            destination = releases / uuid.uuid4().hex
            os.replace(stage, destination)
    return dict(apk=str(destination / 'game.apk'), resources=str(destination / 'resources'),
                artifact=str(destination / 'artifact.json'))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    def interrupt(_signum, _frame):
        raise InterruptedError('安卓出包已取消。')
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    try:
        result = package(args.root, args.out)
    except subprocess.CalledProcessError as error:
        print('【红】Android 构建步骤失败，退出码 ' + str(error.returncode), file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError) as error:
        print('【红】Android 出包失败：' + str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
