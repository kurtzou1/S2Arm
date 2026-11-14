#!/usr/bin/env python3
"""Read-only Android build inventory. No Gradle/build scripts or package managers run."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import struct
import subprocess
import sys
import zipfile

ANDROID = Path(__file__).resolve().parents[1]
REPO = ANDROID.parents[0]
# 判据拆在相邻的小模块里：cs/archive_check.py 与本文件共用，共享准备标记只登记它。
sys.path.insert(0, str(Path(__file__).resolve().parent))
from archive_valid import archive_valid, elf_header   # noqa: E402


def host_sdk_rid():
    """本宿主对应的固定 SDK RID；不在引导表里的宿主返回 None（可 S2A_ANDROID_DOTNET 或 Docker）。"""
    return {('Linux', 'x86_64'): 'linux-x64', ('Linux', 'AMD64'): 'linux-x64',
            ('Darwin', 'arm64'): 'osx-arm64', ('Darwin', 'aarch64'): 'osx-arm64'}.get(
                (platform.system(), platform.machine()))


def one(text, pattern):
    matches = re.findall(pattern, text, re.M)
    if len(matches) != 1:
        raise ValueError('version source missing or ambiguous: ' + pattern)
    return matches[0]


def assignment(text, variable):
    """Read one supported shell assignment, including export/indentation, without eval."""
    if len(re.findall(rf'(?<![\w]){variable}\s*=', text)) != 1:
        raise ValueError(variable + ' assignment missing or ambiguous')
    # The old SDK line also exported NUGET_PACKAGES; other commands are unsupported.
    suffix = r'(?:\s+NUGET_PACKAGES=[^\s;]+)?' if variable == 'DOTNET_ROOT' else ''
    value = one(text, rf'^\s*(?:export\s+)?{variable}=("[^"\n]*"|[^\s;"\n]+){suffix}\s*(?:#.*)?$')
    return value[1:-1] if value.startswith('"') else value


def cache_path(text, variable, values):
    """Resolve only /cache or the published S2A_BUILD_CACHE default, then known pins."""
    value = assignment(text, variable)
    root = re.match(r'^\$(?:\{(cache|cache_root)\}|(cache|cache_root))/', value)
    if root:
        name = root[1] or root[2]
        if assignment(text, name) not in ('${S2A_BUILD_CACHE:-/cache}',
                                          '${S2A_BUILD_CACHE:-$HOME/.cache/s2arm-build}'):
            raise ValueError('unsupported cache root: ' + name)
        value = '/cache/' + value[root.end():]

    def replace(match):
        name = match[1] or match[2]
        if name not in values:
            raise ValueError('unknown cache variable: ' + name)
        return values[name]

    value = re.sub(r'\$\{([A-Za-z_][A-Za-z_0-9]*)\}|\$([A-Za-z_][A-Za-z_0-9]*)', replace, value)
    if (not re.fullmatch(r'/cache/[A-Za-z0-9_./-]+', value)
            or any(part in ('', '.', '..') for part in value.removeprefix('/cache/').split('/'))):
        raise ValueError('unsupported cache expression: ' + variable)
    return value.removeprefix('/cache/')


def requirements(repo):
    """Parse literals, never source/eval build scripts. Unknown layouts fail closed."""
    files = {}

    def read(name):
        p = repo / name
        s = p.read_text(encoding='utf-8')
        files[name] = hashlib.sha256(p.read_bytes()).hexdigest()
        return '\n'.join(line for line in s.splitlines() if not line.lstrip().startswith('#'))

    docker = read('android/docker/Dockerfile')
    app = read('android/app/build.gradle')
    settings = read('android/settings.gradle')
    cs = read('android/cs/build.sh')
    ssl = read('android/openssl/build.sh')
    codecs = read('android/codecs/build.sh')
    build = read('android/docker/build.sh')
    toolchain = read('android/tools/ndk_toolchain.sh')
    hostbuild = read('android/host/build.sh')
    hostenv = read('android/host/hostenv.sh')
    sdk = json.loads(read('compat/tree/global.json'))['sdk']
    packages = one(docker, r'^ARG SDK_PACKAGES="([^"]+)"$').split()
    pins = dict(p.split(';', 1) for p in packages)
    want = {
        'jdk': one(docker, r'openjdk-(\d+)-jdk-headless'),
        'sdk': pins['platforms'].removeprefix('android-'),
        'build_tools': pins['build-tools'], 'ndk': pins['ndk'], 'cmake': pins['cmake'],
        'gradle': one(docker, r'^ARG GRADLE=([\d.]+)$'),
        'agp': one(settings, r"id 'com.android.application' version '([\d.]+)'"),
        'dotnet': sdk, 'cs_sdk': assignment(cs, 'sdk_version'),
        'openssl': assignment(ssl, 'version'),
        'api': one(app, r'^\s*minSdk (\d+)\s*$'),
        'image': one(build, r'^image=\$\{S2ARM_ANDROID_IMAGE:-([^}]+)\}$'),
        'target': one(cs, r'publish "\$cs_dir/probe/[^\"]+" -c Release -r ([\w-]+)'),
        'base_image': one(docker, r'^FROM (\S+)$'),
    }
    # cs/build.sh 按宿主 RID 引导固定 SDK：每个宿主 case 分支必须给出 sdk_rid + 对应 sha512。
    # 正则通捕全部分支标签：表里外的第 3 个分支（如未验证宿主）会进 sdk_hosts 撞不等式报红，
    # 而不是被模式漏过（维护方复审 6546409619 第 6 条）。
    sdk_arms = re.findall(r'^\s*(\w[\w-]*)\)\s+sdk_rid=([\w-]+)\s*\n\s*sdk_sha512=([0-9a-f]{128})',
                          cs, re.M)
    want['sdk_hosts'] = {host: rid for host, rid, _sha in sdk_arms}
    want['sdk_sha512'] = {rid: sha for _host, rid, sha in sdk_arms}
    if want['sdk_hosts'] != {'Linux-x86_64': 'linux-x64', 'Darwin-arm64': 'osx-arm64'} \
            or len(want['sdk_sha512']) != 2 or len(set(want['sdk_sha512'].values())) != 2 \
            or 'dotnet-sdk-$sdk_version-$sdk_rid.tar.gz' not in cs:
        raise ValueError('unsupported SDK bootstrap layout')
    # NDK prebuilt/<host> 目录选择顺序由 ndk_toolchain.sh 的 tag 循环唯一给出；
    # docker 要 linux-x86_64、macOS 原生要 darwin-*，两个方向都得在偏好表里。
    want['ndk_hosts'] = one(toolchain, r'for tag in ([\w -]+); do').split()
    if 'linux-x86_64' not in want['ndk_hosts'] or not any(t.startswith('darwin-') for t in want['ndk_hosts']):
        raise ValueError('unsupported NDK prebuilt tag list')
    for name in ('cs_sdk', 'openssl'):
        if not re.fullmatch(r'\d+(?:\.\d+)+', want[name]):
            raise ValueError('unsupported version literal: ' + name)
    # Cross-check the consuming scripts; a new literal must never silently drift.
    pairs = [(want['sdk'], one(app, r'^\s*compileSdk (\d+)\s*$')),
             (want['ndk'], one(app, r"^\s*ndkVersion '([^']+)'")),
             (want['cmake'], one(app, r"^\s*version '([\d.]+)'")),
             (want['jdk'], one(app, r'^\s*sourceCompatibility JavaVersion.VERSION_(\d+)\s*$'))]
    pairs += [(want['jdk'], one(app, r'^\s*targetCompatibility JavaVersion.VERSION_(\d+)\s*$')),
              (want['api'], one(ssl, r'^api=(\d+)\s*(?:#.*)?$')),
              (want['api'], one(codecs, r'^api=(\d+)\s*(?:#.*)?$')),
              (want['cs_sdk'], sdk['version'])]
    for actual, expected in pairs:
        if actual != expected:
            raise ValueError('Android version sources disagree')
    for script, variable, extra in ((ssl, 'ndk', ()), (codecs, 'ndk', ('$S2A_Q19_NDK',))):
        # Accept only the current literal assignment layouts, never evaluate shell.
        # Count all assignments too: a second export/inline assignment must not hide
        # behind the original version still occurring elsewhere in the script; the
        # codecs Q19 分支的 ndk=$S2A_Q19_NDK 是唯一核准的条件赋值。
        def unquote(expr):
            expr = expr.split('#', 1)[0].strip()
            return expr[1:-1] if expr.startswith('"') and expr.endswith('"') else expr
        if len(re.findall(r'(?<![\w])(?:ndk|ndk_bin)\s*=', script)) != 1 + len(extra):
            raise ValueError('NDK consumer assignment missing or ambiguous')
        expressions = [unquote(e) for e in re.findall(rf'^\s*{variable}=([^\n]+)$', script, re.M)]
        expressions = [e for e in expressions if e not in extra]
        if len(expressions) != 1:
            raise ValueError('NDK consumer assignment missing or ambiguous')
        # 核准两种写法：$ANDROID_HOME/ndk/<固定字面量> 或 $ANDROID_HOME/ndk/$S2A_ANDROID_NDK
        # ——后者由 tools/versions.sh 从同一份 Dockerfile 导出，定义上即 pin（复审第 1 条）。
        match = re.fullmatch(r'\$(?:ANDROID_HOME|\{ANDROID_HOME(?::\?[^}]*)?\})/ndk/([\d.]+|\$S2A_ANDROID_NDK)', expressions[0])
        if not match or (match[1] != '$S2A_ANDROID_NDK' and match[1] != want['ndk']):
            raise ValueError('NDK consumer differs from Dockerfile')
    # cs/build.sh：NDK 由 ndk_toolchain.sh 解析（显式变量 → SDK 固定路径 → 宿主常见路径），
    # prebuilt/<host> 由 s2a_ndk_host_bin 实选；固定修订版在 source.properties 上核对。
    # 三个形状都写死，防静默改回写死 linux-x86_64 或绕开版本核对。
    cs_ndk_shapes = ['ndk=$(s2a_ndk_resolve)', 'ndk_bin=$(s2a_ndk_host_bin "$ndk")',
                     'tools/ndk_toolchain.sh', 'Pkg.Revision = \'$S2A_ANDROID_NDK\'']
    if not all(shape in cs for shape in cs_ndk_shapes) \
            or re.findall(r'(?<![\w])ndk_bin\s*=', cs) != ['ndk_bin='] \
            or 'prebuilt/linux-x86_64' in cs or 'prebuilt/darwin' in cs:
        raise ValueError('unsupported cs NDK resolution layout')
    # macOS 归档坑护栏：静态库必须走 NDK llvm-ar，且产物必须过 archive_check。
    if '-p:CppLibCreator=' not in cs or 'archive_check.py' not in cs:
        raise ValueError('missing static-archive tool/validation pins')
    # 固定组件版本的唯一来源是 Dockerfile ARG SDK_PACKAGES（复审第 1 条）：
    # tools/versions.sh 解析那一行导出变量，消费脚本一律 source 它、不再写字面量。
    versions_sh = read('android/tools/versions.sh')
    if 'ARG SDK_PACKAGES' not in versions_sh or 'S2A_ANDROID_NDK' not in versions_sh \
            or 's2a_sdkmanager_hint' not in versions_sh:
        raise ValueError('versions.sh must parse Dockerfile SDK_PACKAGES and export the pins')
    # host/hostenv.sh 四项固定包检查与 PATH 必须吃版本变量；build.sh 必须 source 同一份
    # hostenv.sh，不准另起第二套检查。
    for var in ('S2A_ANDROID_PLATFORM', 'S2A_ANDROID_BUILD_TOOLS', 'S2A_ANDROID_NDK', 'S2A_ANDROID_CMAKE'):
        if f'${var}' not in hostenv:
            raise ValueError('hostenv package pin must come from versions.sh: ' + var)
    if 'tools/versions.sh' not in hostenv:
        raise ValueError('hostenv must source tools/versions.sh')
    if 'host/hostenv.sh' not in hostbuild:
        raise ValueError('host build must source hostenv.sh')
    # sdk.dir 写回只在显式 prepare/build 命令里；hostenv 与 gate-apk（门禁路径）
    # 必须只读（#1207 复审二条）。SDK 解析只有 package.py:android_sdk_home 一处。
    for text, name in ((hostenv, 'hostenv.sh'),
                       (read('android/host/gate-apk.sh'), 'gate-apk.sh')):
        if re.search(r'>>\s*[^\n]*local\.properties', text):
            raise ValueError(f'gate path must not write local.properties: {name}')
    for text, name in ((read('android/host/prepare.sh'), 'prepare.sh'),
                       (hostbuild, 'build.sh')):
        if not re.search(r'>>\s*[^\n]*local\.properties', text):
            raise ValueError(f'sdk.dir write belongs in explicit command: {name}')
    if 'android_sdk_home' not in hostenv:
        raise ValueError('hostenv must resolve SDK via package.py android_sdk_home')
    # host/prepare.sh + host/gate-apk.sh：在线准备与离线门禁分离，和 docker 同一契约——
    # 回执走同一份 cache-identity（--backend host）、os.replace 原子落盘、门禁先验回执
    # 再 sandbox-exec 断网构建。形状只认下面这份写法，改了就当不支持直接报红。
    prepare = read('android/host/prepare.sh')
    gateapk = read('android/host/gate-apk.sh')
    # 版本字面量只允许出现在 Dockerfile 与 versions.sh（复审第 1 条）；
    # 消费方一律吃变量，漂移一份就报红。
    for consumer in (read('android/tools/ndk_toolchain.sh'),
                     read('android/cs/build.sh'), read('android/codecs/build.sh'),
                     read('android/codecs/cache.sh'), read('android/codecs/avc-build.sh'),
                     read('android/openssl/build.sh'), gateapk, hostbuild, prepare, hostenv):
        for literal in (want['ndk'], want['build_tools'], want['cmake']):
            if literal in consumer:
                raise ValueError('pinned version literal must not be duplicated outside versions.sh: ' + literal)
    if ('--backend host' not in prepare or '--slot' not in prepare or '--prune' not in prepare
            or 'os.replace' not in prepare or 'host/build.sh' not in prepare
            or 'rm -f "$receipt_path"' not in prepare):
        raise ValueError('unsupported host prepare layout')
    if ('--backend host' not in gateapk or 'sandbox-exec' not in gateapk
            or 'deny network*' not in gateapk or 's2a_ndk_host_bin "$ndk"' not in gateapk
            or 'host/prepare.sh' not in gateapk or '--slot' not in gateapk
            or 'touch "$receipt_path"' not in gateapk):
        raise ValueError('unsupported host gate layout')
    # 同提交两路比对（复审第 4 条 + 三轮 .so 口径）：两路 gate 凭 S2A_APK_OUT 各交出
    # 一个 APK，tools/compare_backends.sh 依序驱动，compare_apks.py 按「路径+大小」
    # 比条目、.so 按加载态字节比（去 .comment/.note.*/符号表后相同判绿、不同判红
    # 并列段级差异）、llvm-nm -D 去地址后排序逐行比（保留 U 与重复）。
    compare = read('android/tools/compare_apks.py')
    if ('sorted(lines)' not in compare or '_ADDR_RE' not in compare
            or '.so 体积差' not in compare):
        raise ValueError('unsupported compare_apks layout')
    driver = read('android/tools/compare_backends.sh')
    docker_gate = read('android/docker/gate-apk.sh')
    for text, needle in ((gateapk, 'S2A_APK_OUT'), (docker_gate, 'S2A_APK_OUT'),
                         (driver, 'docker/gate-apk.sh'), (driver, 'host/gate-apk.sh'),
                         (driver, 'compare_apks.py'), (driver, 's2a_ndk_host_bin')):
        if needle not in text:
            raise ValueError('unsupported backend-compare layout: missing ' + needle)
    # 出包后端自动选（package.py，owner 定）：Docker 只留给 Linux 主机。Darwin arm64
    # 一律 host、Darwin 非 arm64 明确报红「未验证」（复审第 6 条，不放行半通状态）、
    # Linux 必须 docker 健康——形状变了这里要跟着改。
    pkg = read('pack/targets/android/package.py')
    if (not re.search(r"if system == 'Darwin':.*?machine != 'arm64'.*?未验证.*?return 'host'", pkg, re.S)
            or not re.search(r"if system == 'Linux':.*?return 'docker'", pkg, re.S)
            or "'info'" not in pkg or 'raise ValueError' not in pkg):
        raise ValueError('unsupported package backend selection')
    if ('$out' not in cs
            or cache_path(cs, 'DOTNET_ROOT', {'sdk_version': want['cs_sdk']})
            != 'dotnet/' + want['cs_sdk']):
        raise ValueError('unsupported NativeAOT cache layout')
    # NuGet SHA-512 钉表（复审第 5 条）：cs/nuget-pins.tsv 每行「id 版本 sha512」
    # 三列非空且不少于 ILCompiler/runtime 两类的覆盖面；cs/build.sh 每次 publish
    # 后必须调 nuget_verify.py，verifier 必须核 contentHash。
    pins_tsv = read('android/cs/nuget-pins.tsv')
    verify = read('android/cs/nuget_verify.py')
    pin_rows = [line.split('#', 1)[0].split() for line in pins_tsv.splitlines()
                if line.split('#', 1)[0].strip()]
    pin_ids = {row[0].lower() for row in pin_rows if len(row) == 3}
    if (not pin_rows or any(len(row) != 3 for row in pin_rows)
            or 'microsoft.dotnet.ilcompiler' not in pin_ids
            or not any('ilcompiler' in i and i.startswith('runtime.') for i in pin_ids)
            or not any('netcore.app.runtime' in i for i in pin_ids)):
        raise ValueError('unsupported NuGet pin table')
    if 'nuget_verify.py' not in cs or 'contentHash' not in verify:
        raise ValueError('unsupported NuGet verify wiring')
    # Host build, prepare and APK gate use this shared environment and helper.
    if (len(re.findall(r'(?<![\w])JAVAC\s*=', hostenv)) != 1
            or not re.fullmatch(r'\$\(bash "\$hostenv_android_dir/tools/jdk17\.sh" \|\| true\)',
                                one(hostenv, r'^JAVAC=([^\n]+)$'))):
        raise ValueError('unsupported hostenv JDK helper invocation')
    if re.search(r'case\s+"\$jv"', hostenv):
        raise ValueError('ambiguous hostenv JDK version sources')
    jdk = read('android/tools/jdk17.sh')
    host_jdk = one(jdk, r"grep -q ' (\d+)\\\.'")
    if host_jdk != want['jdk']:
        raise ValueError('host JDK differs from Dockerfile')
    for name in ('opus', 'vpx'):
        pin = read(f'services/{name}/build.sh')
        ver, sha = one(pin, r'^VER=([\d.]+); SHA=([0-9a-f]{64})$')
        want[name] = {'version': ver, 'sha256': sha}
    # openssl/build.sh 的键 = 版本 + 固定 NDK + 配方摘要（build.sh 与工具链解析的字节拼接）。
    # 摘要算法与 build.sh 的 cat|sha256 保持一致：配方变了就必须换缓存目录。
    recipe = hashlib.sha256((repo / 'android/openssl/build.sh').read_bytes()
                            + (repo / 'android/tools/ndk_toolchain.sh').read_bytes()).hexdigest()
    want['openssl_cache'] = cache_path(ssl, 'cache', {
        'version': want['openssl'], 'api': want['api'],
        'S2A_ANDROID_NDK': want['ndk'], 'recipe_sha': recipe})
    # codecs/<name>-<ver>-<recipe_key>：recipe_key 折进了 NDK toolchain 指纹（编译器 --version
    # 输出），doctor 不跑编译器算不出它，只固定目录名形状和配方脚本里唯一的 target/key 表达式；
    # 具体目录由 inspect 用 manifest.sha256 + 归档校验确认。cache_root 必须是唯一固定字面量。
    if (len(re.findall(r'(?<![\w])cache_root\s*=', codecs)) != 1
            or 'cache_root=${S2A_BUILD_CACHE:-$HOME/.cache/s2arm-build}' not in codecs):
        raise ValueError('unsupported codecs cache root')
    # vpx 的配方键另带 S2Arm 的 libvpx 补丁（services/vpx/patches，Nvdec VP9 作业接口）。
    extra = {'vpx': ' "$repo_dir/services/vpx/patches/0001-s2a-vp9-nvdec-hook.patch"'}
    for name in ('opus', 'vpx'):
        recipe = read(f'android/codecs/{name}-build.sh')
        if (len(re.findall(r'(?<![\w-])(?:target|key)\s*=', recipe)) != 2
                or one(recipe, r'^\s*target=\$cache_root/codecs/(\S+)$') != f'{name}-${name}_ver-$key'
                or one(recipe, r'^\s*key=\$\(([^\n]+)\)$')
                != f'codec_recipe_key {name} "${name}_sha" "$repo_dir/android/codecs/{name}-build.sh"{extra.get(name, "")}'):
            raise ValueError('unsupported codec cache layout: ' + name)
        want[name + '_cache'] = f'codecs/{name}-{want[name]["version"]}-'
    want['sources'] = files
    return want


def pinned_version(dep):
    # downloadDependencies 一项的精确版本 [v, v]；裸版本（下界）、区间或坏值都不算钉版本
    try:
        return exact_version(dep.get('version'))
    except ValueError:
        return None


def gradle_on_path():
    # --gradle-home / GRADLE_HOME 都没给时，像找 javac 一样从 PATH 找（#1568 定）：官方构建镜像只放
    #   /usr/local/bin/gradle 软链、不设 GRADLE_HOME。解软链到 <home>/bin/gradle 取 home；只看路径，不运行 Gradle
    found = shutil.which('gradle')
    if not found:
        return None
    real = Path(found).resolve()
    return real.parent.parent if real.parent.name == 'bin' else None


def exact_version(value):
    # A bare NuGet version is a lower bound, not an exact constraint.
    if not isinstance(value, str):
        raise ValueError('runtime range is not exact')
    match = re.fullmatch(r'\[\s*([^,\[\]()]+?)\s*(?:,\s*([^,\[\]()]+?)\s*)?\]', value.strip())
    if match:
        first, second = match[1].strip(), match[2].strip() if match[2] else None
        if re.fullmatch(r'\d+\.\d+\.\d+(?:-[\w.-]+)?', first) and (second is None or first == second):
            return first
    raise ValueError('runtime range is not exact')


def sdk_matches(version, spec):
    have = tuple(map(int, version.split('.')))
    want = tuple(map(int, spec['version'].split('.')))
    policy = spec.get('rollForward', 'patch')
    if policy == 'disable':
        return have == want
    if policy in ('patch', 'latestPatch'):
        return have[:2] == want[:2] and have[2] // 100 == want[2] // 100 and have >= want
    if policy in ('feature', 'latestFeature'):
        return have[:2] == want[:2] and have >= want
    if policy in ('minor', 'latestMinor'):
        return have[0] == want[0] and have >= want
    if policy in ('major', 'latestMajor'):
        return have >= want
    return False


def run(argv):
    """Only bounded version/introspection commands; never emit stderr or environment."""
    env = dict(os.environ, DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',
               DOTNET_NOLOGO='1', DOCKER_CLI_HINTS='false')
    try:
        p = subprocess.run([str(x) for x in argv], capture_output=True, text=True,
                           timeout=8, env=env, check=False)
        return p.returncode, (p.stdout + p.stderr)[:262144]
    except (OSError, subprocess.TimeoutExpired):
        return -1, ''


def nonempty(p):
    return p.is_file() and p.stat().st_size > 0


def manifest_entries(root):
    """codec_publish 写的 '<sha256>  ./<relpath>' 清单；读不了或格式不合就 None。"""
    try:
        entries = {}
        for line in (root / 'manifest.sha256').read_text().splitlines():
            match = re.fullmatch(r'([0-9a-f]{64})  (\./[^\n]+)', line)
            if not match:
                return None
            rel = match[2][2:]
            if rel.startswith('/') or '..' in rel.split('/'):
                return None
            entries[rel] = match[1]
        return entries or None
    except OSError:
        return None


def codec_valid(root, archive, header, notices, shim, machine=183):
    """一个 codec 缓存目录：清单内文件哈希全对 + 目标归档/许可齐 + 至少一个有效 s2a 垫片。"""
    entries = manifest_entries(root)
    if not entries:
        return False
    for rel, sha in entries.items():
        p = root / rel
        if not p.is_file() or p.is_symlink() or hashlib.sha256(p.read_bytes()).hexdigest() != sha:
            return False
    if not archive_valid(root / archive, machine):
        return False
    if not all(nonempty(root / rel) for rel in [header, *notices]):
        return False
    return any(manifest_entries(d) and archive_valid(d / ('lib' + shim + '.a'), machine)
               for d in root.glob('s2a-*') if d.is_dir())


def jar_valid(p):
    try:
        with zipfile.ZipFile(p) as z:
            # Read central directory and member headers, no extraction/decompression.
            return bool(z.infolist()) and any(x.filename.endswith('.class') for x in z.infolist())
    except (OSError, ValueError, zipfile.BadZipFile):
        return False


def pom_valid(p, version):
    try:
        from xml.etree import ElementTree as ET
        root = ET.parse(p).getroot()
        values = {e.tag.split('}')[-1]: e.text for e in root}
        return values.get('artifactId') == 'gradle' and values.get('version') == version
    except (OSError, ET.ParseError):
        return False


def binary(p, kind, machine=183):
    if not nonempty(p):
        return False
    if kind == 'archive':
        return archive_valid(p, machine)
    with p.open('rb') as f:
        return elf_header(f.read(64), machine, (2, 3))


def executable_status(p, system=None, arch=None, scripts=False):
    """Static format/ISA/permission evidence; does not execute the payload."""
    if not nonempty(p):
        return 'missing', 'missing or empty executable'
    if not (p.stat().st_mode & 0o111) or not os.access(p, os.X_OK):
        return 'missing', 'execute permission unavailable'
    system, arch = system or platform.system(), arch or platform.machine()
    machine = {'x86_64': 62, 'AMD64': 62, 'arm64': 183, 'aarch64': 183}.get(arch)
    with p.open('rb') as f:
        h = f.read(256)
        if h.startswith(b'#!'):
            if not scripts:
                return 'mismatch', 'expected native host executable, found script'
            try:
                words = shlex.split(h.split(b'\n', 1)[0][2:].decode('utf-8').strip())
            except (ValueError, UnicodeError):
                return 'unverified', 'unrecognized script interpreter'
            # Current SDK/Gradle/NDK launchers use sh/bash. Other layouts need review.
            if words and words[0] == '/usr/bin/env':
                words = words[1:]
                interpreter = shutil.which(words[0]) if len(words) == 1 else None
            else:
                interpreter = words[0] if len(words) == 1 and words[0].startswith('/') else None
            if not interpreter or Path(interpreter).name not in ('sh', 'bash'):
                return 'unverified', 'unsupported script interpreter'
            if not Path(interpreter).is_file() or not os.access(interpreter, os.X_OK):
                return 'missing', 'script interpreter unavailable'
            return 'ok', 'shell launcher header and interpreter available; not executed'
        if h.startswith(b'\x7fELF'):
            if system != 'Linux' or machine is None or not elf_header(h, machine, (2, 3)):
                return 'mismatch', 'ELF OS/class/type/ISA differs from required host'
            return 'ok', 'ELF64 host ISA and execute permission'
        cpu = {'x86_64': 0x01000007, 'AMD64': 0x01000007,
               'arm64': 0x0100000c, 'aarch64': 0x0100000c}.get(arch)
        def thin(header):
            return (len(header) >= 32 and header[:4] == b'\xcf\xfa\xed\xfe'
                    and struct.unpack('<I', header[4:8])[0] == cpu
                    and struct.unpack('<I', header[12:16])[0] == 2)
        if h[:4] == b'\xcf\xfa\xed\xfe':
            return ('ok', 'Mach-O host ISA and execute permission') if system == 'Darwin' and thin(h) else (
                'mismatch', 'Mach-O OS/type/ISA differs from required host')
        if h[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
            if system != 'Darwin' or len(h) < 8:
                return 'mismatch', 'universal Mach-O requires Darwin host'
            count = struct.unpack('>I', h[4:8])[0]
            wide = h[:4] == b'\xca\xfe\xba\xbf'
            size = 32 if wide else 20
            total = p.stat().st_size
            if count == 0 or count > 64 or 8 + count * size > total:
                return 'mismatch', 'invalid universal Mach-O table'
            f.seek(8)
            table = f.read(count * size)
            for n in range(count):
                entry = table[n * size:(n + 1) * size]
                kind = struct.unpack('>I', entry[:4])[0]
                offset, length = struct.unpack('>QQ' if wide else '>II', entry[8:24] if wide else entry[8:16])
                if offset < 8 + count * size or length < 32 or offset + length > total:
                    return 'mismatch', 'invalid universal Mach-O slice'
                if kind == cpu:
                    f.seek(offset)
                    if thin(f.read(32)):
                        return 'ok', 'universal Mach-O matching executable slice'
            return 'mismatch', 'no matching Mach-O executable slice'
    return 'unverified', 'unrecognized executable format; metadata is insufficient'


class Inventory:
    def __init__(self):
        self.checks = []

    def add(self, name, status, expected, actual=None, path=None, action=None):
        self.checks.append(dict(id=name, status=status, expected=expected, actual=actual,
                                path=str(path) if path is not None else None, action=action))

    def version(self, name, path, args, pattern, expected, major=False):
        path = Path(path) if path else None
        if path is None or not path.is_file() or not os.access(path, os.X_OK):
            self.add(name, 'missing', expected, path=path, action='指定已有可执行文件或经批准准备对应版本')
            return
        code, output = run([path, *args])
        match = re.search(pattern, output)
        actual = match[1] if match else None
        status = 'ok' if code == 0 and actual and (actual.split('.')[0] if major else actual) == expected else 'mismatch'
        self.add(name, status, expected, actual, path.resolve())

    def files(self, name, root, entries):
        absent, diagnostics = [], {}
        for relative, kind in entries:
            p = root / relative
            if kind in ('host', 'launcher', 'linux_x64', 'linux_launcher'):
                status, reason = executable_status(
                    p, 'Linux' if kind.startswith('linux_') else None,
                    'x86_64' if kind.startswith('linux_') else None,
                    scripts=kind in ('launcher', 'linux_launcher'))
            else:
                valid = (binary(p, kind) if kind in ('elf', 'archive') else
                         jar_valid(p) if kind == 'jar' else nonempty(p))
                status, reason = ('ok', 'data payload present') if valid else ('missing', 'missing or invalid data')
            diagnostics[relative] = {'status': status, 'reason': reason}
            if status != 'ok':
                absent.append(relative)
        status = next((v for v in ('missing', 'mismatch', 'unverified')
                       if any(x['status'] == v for x in diagnostics.values())), 'ok')
        self.add(name, status, [p for p, _ in entries],
                 {'missing_or_invalid': absent, 'files': diagnostics}, root)


def inspect(args, repo=REPO):
    pins = requirements(repo)
    i = Inventory()
    sdk = Path(args.sdk) if args.sdk else Path('/opt/android-sdk')
    cache = Path(args.cache_root)
    gradle_cache = Path(args.gradle_cache) if args.gradle_cache else cache / 'gradle'
    nuget = Path(args.nuget_cache) if args.nuget_cache else cache / 'nuget'
    java = Path(args.jdk) / 'bin/javac' if args.jdk else shutil.which('javac')
    i.version('jdk', java, ['-version'], r'javac (\d+(?:\.\d+)+)', pins['jdk'], major=True)
    runtime_java = Path(java).parent / 'java' if java else None
    i.version('jdk_runtime', runtime_java, ['-version'], r'version \"(\d+(?:\.\d+)+)', pins['jdk'], major=True)
    # Read package metadata and payload, not just versioned directory names.
    packages = [('sdk', f'platforms/android-{pins["sdk"]}', [('android.jar', 'jar')], f'platforms;android-{pins["sdk"]}'),
                ('build_tools', f'build-tools/{pins["build_tools"]}', [('aapt2', 'host'), ('apksigner', 'launcher'), ('zipalign', 'host')], f'build-tools;{pins["build_tools"]}'),
                ('ndk', f'ndk/{pins["ndk"]}', [('build/cmake/android.toolchain.cmake', 'file')], f'ndk;{pins["ndk"]}'),
                ('cmake', f'cmake/{pins["cmake"]}', [('bin/cmake', 'host'), ('bin/ninja', 'host')], f'cmake;{pins["cmake"]}')]
    import xml.etree.ElementTree as ET
    for name, relative, entries, package_id in packages:
        root = sdk / relative
        i.files(name + '_files', root, entries)
        parent = root.parent
        available = sorted(p.name for p in parent.iterdir() if p.is_dir()) if parent.is_dir() else []
        i.checks[-1]['actual']['available_versions'] = available
        try:
            node = ET.parse(root / 'package.xml').getroot()
            local = next(e for e in node.iter() if e.tag.split('}')[-1] == 'localPackage')
            actual = local.attrib.get('path')
            revision = None
            if name != 'sdk':
                rev = next((e for e in local if e.tag.split('}')[-1] == 'revision'), None)
                if rev is not None:
                    nums = {e.tag.split('}')[-1]: e.text for e in rev}
                    revision = '.'.join(nums.get(k, '0') for k in ('major', 'minor', 'micro'))
                valid = actual == package_id and revision == pins[name]
            else:
                valid = actual == package_id
            i.add(name + '_package', 'ok' if valid else 'mismatch', package_id,
                  {'package': actual, 'revision': revision}, root)
        except (OSError, ET.ParseError, StopIteration):
            i.add(name + '_package', 'missing', package_id, path=root)
    ndk = sdk / 'ndk' / pins['ndk']
    ndk_tag = next((t for t in pins['ndk_hosts'] if (ndk / 'toolchains/llvm/prebuilt' / t).is_dir()), None)
    if ndk_tag is None:
        i.files('ndk_compiler', ndk / 'toolchains/llvm/prebuilt', [])
    else:
        i.files('ndk_compiler', ndk / 'toolchains/llvm/prebuilt' / ndk_tag,
                [('bin/clang', 'host'),
                 ('bin/aarch64-linux-android' + pins['api'] + '-clang', 'launcher')])
    gradle = Path(args.gradle_home) if args.gradle_home else gradle_on_path()
    launchers = list((gradle / 'lib').glob('gradle-launcher-*.jar')) if gradle else []
    actual = [p.name.removeprefix('gradle-launcher-').removesuffix('.jar') for p in launchers if jar_valid(p)]
    launcher_status, _ = executable_status(gradle / 'bin/gradle', scripts=True) if gradle else ('missing', 'Gradle home not configured')
    i.add('gradle', launcher_status if actual == [pins['gradle']] else 'mismatch' if actual else 'missing',
          pins['gradle'], actual, gradle, '用 --gradle-home 指定已解压目录，或把 <home>/bin/gradle 放进 PATH；不运行可能初始化缓存的 Gradle')
    agp = gradle_cache / 'caches/modules-2/files-2.1/com.android.tools.build/gradle' / pins['agp']
    for suffix in ('pom', 'jar'):
        found = [str(p.relative_to(agp)) for p in agp.glob('*/*.' + suffix) if (jar_valid(p) if suffix == 'jar' else pom_valid(p, pins['agp']))]
        i.add('agp_' + suffix, 'ok' if found else 'missing', pins['agp'], found, agp)
    dotnet = args.dotnet or shutil.which('dotnet')
    if dotnet:
        code, out = run([dotnet, '--list-sdks'])
        versions = re.findall(r'^(\d+\.\d+\.\d+) \[', out, re.M) if code == 0 else []
    else:
        versions = []
    # APK build.sh deliberately uses its own exact Linux-x64 SDK, unlike global.json rollForward.
    compatible = [v for v in versions if sdk_matches(v, pins['dotnet'])]
    i.add('dotnet_inventory', 'ok' if compatible else 'mismatch' if versions else 'missing', pins['dotnet'], versions, dotnet)
    cs_sdk = cache / 'dotnet' / pins['cs_sdk']
    i.files('nativeaot_sdk', cs_sdk, [('dotnet', 'host'), ('sdk/' + pins['cs_sdk'] + '/dotnet.dll', 'file')])
    sdk_status, sdk_reason = executable_status(cs_sdk / 'dotnet')
    i.add('nativeaot_sdk_host', sdk_status, 'host executable SDK', sdk_reason, cs_sdk / 'dotnet')
    # Exact runtime version comes from restore, not a guessed SDK -> runtime mapping.
    assets = Path(args.assets) if args.assets else repo / 'build/android-cs/probe/obj/project.assets.json'
    runtime = None
    try:
        doc = json.loads(assets.read_text())
        if not isinstance(doc, dict) or not isinstance(doc.get('project'), dict):
            raise ValueError('invalid assets document')
        frameworks = doc['project'].get('frameworks')
        if not isinstance(frameworks, dict) or not all(isinstance(fw, dict) for fw in frameworks.values()):
            raise ValueError('invalid frameworks')
        if not isinstance(doc.get('libraries', {}), dict):
            raise ValueError('invalid libraries')
        versions = {exact_version(d['version']) for fw in doc['project']['frameworks'].values()
                    for d in fw.get('downloadDependencies', [])
                    if d['name'].lower() == 'microsoft.netcore.app.runtime.nativeaot.' + pins['target']}
        if len(versions) == 1 and re.fullmatch(r'\d+\.\d+\.\d+(?:-[\w.-]+)?', next(iter(versions))):
            runtime = next(iter(versions))
        else:
            raise ValueError('runtime version missing/ambiguous')
        i.add('nativeaot_restore', 'ok', pins['target'], runtime, assets)
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        i.add('nativeaot_restore', 'missing', pins['target'], path=assets, action='在获准的 Linux x64 构建环境先完成现有 cs/build.sh 的还原；本工具不还原')
    if runtime:
        i.files('nativeaot_runtime', nuget / ('microsoft.netcore.app.runtime.nativeaot.' + pins['target']) / runtime,
                [('runtimes/' + pins['target'] + '/native/libRuntime.WorkstationGC.a', 'archive'),
                 ('LICENSE.TXT', 'file'), ('THIRD-PARTY-NOTICES.TXT', 'file')])
        sdk_rid = host_sdk_rid()
        compiler_id = 'runtime.' + (sdk_rid or '<unsupported-host>') + '.microsoft.dotnet.ilcompiler'
        compiler_versions = [name.split('/', 1)[1] for name in doc.get('libraries', {})
                             if '/' in name and name.split('/', 1)[0].lower() == compiler_id]
        # PublishAotUsingRuntimePack 的真实还原只把宿主编译器记成 PackageDownload：在 downloadDependencies 里、
        #   不在 libraries（#107 情形 E，#1568 定口径）。libraries 没有时，只认精确钉版本 [v, v]，
        #   且本地 NuGet 缓存里按包名 + 版本找得到（.nupkg 或解开的 tools/）；只有其一仍 unverified
        pinned = sorted({v for fw in doc['project']['frameworks'].values() for v in
                         [pinned_version(dep) for dep in fw.get('downloadDependencies', [])
                          if isinstance(dep, dict) and str(dep.get('name', '')).lower() == compiler_id] if v})
        package = nuget / compiler_id / pinned[0] if len(pinned) == 1 else None
        if len(compiler_versions) == 1 and re.fullmatch(r'[0-9A-Za-z.-]+', compiler_versions[0]):
            compiler = nuget / compiler_id / compiler_versions[0] / 'tools/ilc'
            status, reason = executable_status(compiler)
            i.add('nativeaot_compiler', status, compiler_versions[0] + ' host executable', reason, compiler)
        elif not compiler_versions and package and ((package / (compiler_id + '.' + pinned[0] + '.nupkg')).is_file()
                                                     or (package / 'tools').is_dir()):
            compiler = package / 'tools/ilc'
            status, reason = executable_status(compiler)
            i.add('nativeaot_compiler', status, pinned[0] + ' host executable (downloadDependencies)', reason, compiler)
        else:
            i.add('nativeaot_compiler', 'unverified', 'exact restored host compiler', path=assets)
    else:
        i.add('nativeaot_runtime', 'unverified', 'exact restored runtime and compiler', path=nuget)
    i.files('openssl', cache / pins['openssl_cache'], [('libssl.so', 'elf'), ('libcrypto.so', 'elf'), ('LICENSE.txt', 'file')])
    for name, archive, shim, notices, header in [
        ('opus', 'libopus.a', 's2a_opus', ['COPYING'], 'include/opus.h'),
        ('vpx', 'libvpx.a', 's2a_vpx', ['LICENSE', 'PATENTS'], 'include/vpx/vpx_decoder.h')]:
        prefix = pins[name + '_cache'].split('/', 1)[1]  # '<name>-<ver>-'，目录实名为 <prefix><64 位 recipe key>
        parent = cache / 'codecs'
        found = sorted(p for p in parent.glob(prefix + '*')
                       if p.is_dir() and re.fullmatch(r'[0-9a-f]{64}', p.name[len(prefix):]))
        valid = [p.name for p in found if codec_valid(p, archive, header, notices, shim)]
        i.add(name, 'ok' if valid else 'missing', pins[name + '_cache'] + '<recipe_key>',
              {'candidates': [p.name for p in found], 'valid': valid}, parent,
              None if valid else 'codec 缓存缺失或损坏；显式运行 codecs/build.sh 重建（离线、不自动下载）')
    system, arch = platform.system(), platform.machine()
    native = host_sdk_rid() is not None
    i.add('nativeaot_host', 'ok' if native else 'unsupported',
          ' / '.join(pins['sdk_hosts'].values()) + ' / ' + ' '.join(pins['ndk_hosts']),
          {'os': system, 'arch': arch}, action='宿主不在固定 SDK RID 表内；可用 S2A_ANDROID_DOTNET 指定固定版本 SDK，或走 Docker/Linux x64')
    docker = args.docker or shutil.which('docker')
    image = args.image or pins['image']
    if docker and args.offline:
        i.add('docker', 'unverified', 'running server', path=docker, action='离线模式不连接 Docker daemon')
        i.add('docker_image', 'unverified', 'linux/amd64', path=image)
    elif docker:
        code, output = run([docker, 'version', '--format', '{{json .}}'])
        try:
            version = json.loads(output) if code == 0 else {}
            if not isinstance(version, dict):
                raise ValueError('invalid docker version')
            server = version.get('Server') or {}
            if not isinstance(server, dict):
                raise ValueError('invalid docker server')
            i.add('docker', 'ok' if server else 'missing', 'running server (no startup)',
                  {k: server.get(k) for k in ('Version', 'Os', 'Arch')}, docker)
        except ValueError:
            i.add('docker', 'error', 'valid version response', path=docker)
        code, output = run([docker, 'image', 'inspect', image, '--format', '{{json .}}'])
        try:
            info = json.loads(output) if code == 0 else {}
            if not isinstance(info, dict):
                raise ValueError('invalid image')
            architecture = info.get('Architecture')
            good = architecture == 'amd64' and info.get('Os') == 'linux'
            i.add('docker_image', 'ok' if good else 'unsupported' if info else 'missing', 'linux/amd64',
                  {k: info.get(k) for k in ('Id', 'Os', 'Architecture')}, image)
        except ValueError:
            i.add('docker_image', 'error', 'valid inspect response', path=image)
    else:
        i.add('docker', 'missing', 'Docker CLI and already running daemon', action='获准后配置 Docker，或转交 Linux x64；本工具不启动服务')
        i.add('docker_image', 'unverified', 'linux/amd64', path=image)
    i.add('offline_resolution', 'unverified', 'full Gradle/NuGet dependency closure',
          action='发现 AGP/JAR 与 AOT 缓存不等于依赖闭包；在已授权构建中显式 --offline 验证。doctor 不执行还原、Gradle 或 docker run')
    space = Path(args.space_path or args.cache_root)
    while not space.exists() and space != space.parent:
        space = space.parent
    free = shutil.disk_usage(space).free
    i.add('disk_space', 'ok' if args.min_free_bytes is not None and free >= args.min_free_bytes else 'missing' if args.min_free_bytes is not None else 'unverified',
          {'user_min_free_bytes': args.min_free_bytes}, {'free_bytes': free}, space,
          '没有项目统一磁盘阈值；用 --min-free-bytes 传入本次预算，不猜测常数')
    checks = i.checks
    return {'version': 1, 'scope': 'android-apk', 'read_only': True, 'offline': args.offline, 'configuration': args.config, 'network': ('no network probes' if args.offline else 'no downloads; configured Docker daemon introspection only'),
            'requirements': pins, 'checks': checks,
            'status': 'incomplete' if any(c['status'] != 'ok' for c in checks) else 'ok',
            'stages': {'environment': 'incomplete' if any(c['status'] != 'ok' for c in checks) else 'ok',
                       'compile': 'not_tested', 'apk_validation': 'not_tested', 'signature': 'not_tested',
                       'installation': 'not_tested', 'device_game': 'not_tested', 'performance': 'not_tested'}}


def load_config(path, allowed):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('duplicate configuration key: ' + key)
            result[key] = value
        return result
    doc = json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=pairs)
    if not isinstance(doc, dict) or type(doc.get('version')) is not int or doc['version'] != 1:
        raise ValueError('configuration requires version=1')
    if set(doc) - allowed - {'version'}:
        raise ValueError('unknown configuration key')
    for key, value in doc.items():
        if key == 'version':
            continue
        if key == 'offline':
            valid = type(value) is bool
        elif key == 'min_free_bytes':
            valid = type(value) is int and value >= 0
        else:
            valid = isinstance(value, str) and bool(value.strip()) and '\0' not in value
        if not valid:
            raise ValueError('invalid configuration value: ' + key)
    for key in allowed - {'image', 'offline', 'min_free_bytes'}:
        if key in doc:
            value = Path(doc[key]).expanduser()
            doc[key] = str(value if value.is_absolute() else path.resolve().parent / value)
    return doc


def main():
    p = argparse.ArgumentParser(description=__doc__)
    paths = {'jdk': 'JAVA_HOME', 'sdk': 'ANDROID_HOME', 'gradle_home': 'GRADLE_HOME',
             'dotnet': None, 'docker': None, 'cache_root': None, 'gradle_cache': None,
             'nuget_cache': None, 'assets': None, 'image': 'S2ARM_ANDROID_IMAGE', 'space_path': None}
    for name in paths:
        p.add_argument('--' + name.replace('_', '-'))
    p.add_argument('--config', help='version=1 JSON with paths only; CLI overrides config overrides environment')
    p.add_argument('--min-free-bytes', type=int)
    p.add_argument('--offline', action='store_true', default=None, help='do not contact even an existing Docker daemon')
    p.add_argument('--format', choices=['json', 'text'], default='text')
    p.add_argument('--plan', action='store_true', help='print preparation guidance only; never execute it')
    args = p.parse_args()
    try:
        defaults = {name: os.environ.get(env) if env else None for name, env in paths.items()}
        defaults['sdk'] = defaults['sdk'] or os.environ.get('ANDROID_SDK_ROOT')
        defaults['cache_root'] = '/cache'
        defaults['offline'] = False
        config = load_config(Path(args.config), set(paths) | {'offline', 'min_free_bytes'}) if args.config else {}
        for name in [*paths, 'offline', 'min_free_bytes']:
            if getattr(args, name) is None:
                setattr(args, name, config.get(name, defaults.get(name)))
        if args.min_free_bytes is not None and args.min_free_bytes < 0:
            raise ValueError('--min-free-bytes must be nonnegative')
        report = inspect(args)
    except (OSError, ValueError, KeyError) as exc:
        report = {'version': 1, 'status': 'error', 'error': type(exc).__name__,
                  'message': '读取配置/源码版本正本失败；未执行准备', 'detail': str(exc)}
    if args.plan and 'checks' in report:
        image = args.image or report['requirements']['image']
        repo = REPO
        commands = [
            ['docker', 'build', '--platform', 'linux/amd64', '-t', image, str(repo / 'android/docker')],
            ['env', 'DOCKER_DEFAULT_PLATFORM=linux/amd64', 'S2ARM_ANDROID_IMAGE=' + image,
             'bash', str(repo / 'android/docker/build.sh')],
        ]
        report['plan'] = {'executed': False,
            'steps': ['先复用 --jdk / --sdk / --gradle-home / --dotnet / --cache-root 指定目录并重新检查',
                      '经用户授权后按 docker/Dockerfile 准备 linux/amd64 镜像；Apple Silicon 必须单独验证仿真，当前 build.sh 未强制平台',
                      '经用户授权运行原有 docker/build.sh（涉及下载/安装）；首次 NativeAOT/编解码和 Gradle 缓存需要联网',
                      '准备完成后在构建环境跑 test.sh、verify-apk.py 和 apksigner verify；另存实际命令、commit 与状态',
                      '离线闭包须在受控环境另行运行离线构建验证；构建成功不代表安装或游戏可玩'],
            'commands_require_approval': [shlex.join(c) for c in commands],
            'cache_note': '--cache-root 等参数只选择检查目录；构建脚本用 S2A_BUILD_CACHE（缺省 /cache），Docker volume 另由 S2ARM_ANDROID_CACHE 选择。doctor 不设置这些构建变量。',
            'activation': {k: v for k, v in {'JAVA_HOME': args.jdk, 'ANDROID_HOME': args.sdk,
                          'GRADLE_HOME': args.gradle_home, 'GRADLE_USER_HOME': args.gradle_cache,
                          'NUGET_PACKAGES': args.nuget_cache}.items() if v}}
    if args.format == 'json':
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print('Android APK 环境：' + report['status'] + '（只读，未构建/签名/安装）')
        for c in report.get('checks', []):
            print(f'{c["status"]}: {c["id"]} | 要求 {c["expected"]} | 实际 {c["actual"]} | 路径 {c["path"]}')
            if c['action']:
                print('  → ' + c['action'])
        if 'plan' in report:
            print('准备计划（未执行）：')
            print('\n'.join(report['plan']['steps']))
            print(report['plan']['cache_note'])
            print('获准后手动执行（本次未执行）：')
            print('\n'.join(report['plan']['commands_require_approval']))
            print('当前进程激活（仅打印）：')
            for key, value in report['plan']['activation'].items():
                print('export ' + key + '=' + shlex.quote(value))
        if 'message' in report:
            print(report['message'])
            print(report.get('detail', ''))
    return 1 if report['status'] == 'error' else 0 if report['status'] == 'ok' else 2


if __name__ == '__main__':
    sys.exit(main())
