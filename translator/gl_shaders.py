#!/usr/bin/env python3
# OpenGL games' GLSL shaders → one Metal library + a table for the host's GL layer (dm/gfx/gl/hle_gl.m). Digimon Story Cyber Sleuth: Complete Edition renders with
# NVIDIA's desktop GL through EGL and compiles GLSL ES 3.20 source at run time (glShaderSource / glCompileShader); the host finds each shader again by the hash of its source.
# Sources, all searched in every input path:
#   · MVGL archives (*.mvgl, dm/gfx/tools/mvgl.py): every .shad file, named <material>_vp / <material>_fp (1,682 files, 615 distinct sources in Digimon);
#   · Digital Eclipse bundles (*.mbundle, mbundle.py): every .shader file, named <name>_v / <name>_f (Street Fighter 30th Anniversary Collection: 13 in bundleMain, GLSL ES 1.00);
#   · an NSO (a file that starts with NSO0, the game's main): every NUL-terminated string that starts with '#version' (its built-in post effects, movie and shadow shaders);
#   · capture folders (the Mac host's DM_GL_CAPTURE): <key>.vert / <key>.frag, what the game really compiled, for sources it puts together at run time;
#   · loose shader files in the RomFS: .vert / .frag / .comp, and .vs / .fs (libGDX naming: Slay the Spire's shaders/*.vs, *.fs, GLSL ES 1.00 without #version);
#     .glsl, whose name does not say the stage (FINAL FANTASY VII: ff7/shaders/*_vv.glsl / *_p.glsl, GLSL 3.20): translated as each stage that compiles, as a string from main.
# GLSL ES 1.00 (no #version after preprocessing, or #version 100): raised to ES 3.10 for glslang -V; GLSL ES 3.00 (#version 300 es) gets its version line raised to 310 es; the key is still the hash of the original text.
#   The rewriting (version lines, ES 1.00 attribute / varying / gl_FragColor, the old texture functions, fix-ups NVIDIA's compiler accepts) is graphics/nvn/gfx/gl/gl_glsl_es.c, one implementation
#   shared with the host's run-time fallback (gl_xlate.c, called from gl_prog.m); this script builds its command-line entry once per process and runs it per shader.
# Per shader:
#   · key = sha256(the source text up to its first NUL)[:16] (hex), as the host hashes the strings glShaderSource gets; the Metal function is gl_<key>_v or gl_<key>_f;
#   · the stage: a capture's extension, an archive file's _vp / _fp; a string in main says nothing of its stage, so it is translated as each stage that compiles (one of
#     Digimon's built-in fragment shaders names gl_Position in a #define);
#   · GLSL → SPIR-V with glslang (-V -R: relaxed Vulkan rules, which gather the loose uniforms into one block, gl_DefaultUniformBlock; --aml / --amb number the inputs,
#     outputs and bindings), SPIR-V → MSL with spirv-cross (--msl-decoration-binding: Metal slots = those bindings; vertex shaders --fixup-clipspace: GL's z from −w to w → 0 to w);
#   · varyings are matched by name, as GL links them: --aml numbers each stage's outputs in its own declaration order, so [[user(locnN)]] becomes [[user(<variable name>)]];
#   · the host renders in GL's orientation (row 0 at the bottom, the NVN layer's lower-left origin), so nothing is flipped here.
# Output: <out>/gl/gl_shaders.metallib and <out>/gl/gl_shaders.tsv; --ios <dir> also writes <dir>/gl/ with an iPhone library (same table)
#   no source at all (GameMaker puts its GLSL together at run time): only the table header, no library; the host translates what it meets at run time (gl_prog.m)
# Table rows: key <TAB> stage (vert / frag) <TAB> fields, space-separated (a key can have a row per stage):
#   a:<name>=<slot>:<type>                       a vertex input, [[attribute(slot)]]
#   u:<name>=<offset>:<type>:<count>:<stride>    a member of the default uniform block (count 0 = not an array); a struct member (not an array of structs) is
#                                                spread into its members as GL names them, <name>.<member>, offset from the block's start
#   b:<slot>:<size>                              the default uniform block: its buffer slot and size in bytes
#   t:<name>=<slot>:<type>[:<count>]             a combined sampler: texture and sampler slot; an array of count (> 1) takes slots slot … slot + count − 1 (ABI 2)
#   o:<name>=<location>                          a fragment output, [[color(location)]]
#   D                                            the fragment shader writes gl_FragDepth (Metal needs a depth attachment for it; the GL layer attaches a scratch one when the target has none)
# <TAB> where it came from
# Usage: gl_shaders.py <input path>... <out dir> [--ios <dir>]   (input paths: the RomFS, the main NSO, capture folders)
import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import atexit
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mvgl
# 仓库里唯一的 RomFS 遍历（graphics/nvn/tools/romfs_list.py：walk 同 os.walk，listdir 同 os.listdir）
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'graphics', 'nvn', 'tools')); import romfs_list
import mbundle

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "graphics/tools"))
from glsl.normalize import resources as normalize_resources
from spirv_msl import SLOT_CLASS, metal_cmd, metal_run
from spirv_msl import translate as spirv_to_msl

GL_LIB_ABI = 3   # = graphics/nvn/gfx/gl/gl_lib.h S2A_GL_LIB_ABI（3：MSL 3.1，审计 #1534 P1-66）：表格式 / 槽位 / 翻译选项改了两边一起加 1（2：采样器数组 t:<名>=<槽>:<类型>:<个数>，11-03 火影羁绊 Scaleform）
VEC_TYPES = {'float', 'vec2', 'vec3', 'vec4', 'int', 'ivec2', 'ivec3', 'ivec4', 'uint', 'uvec2', 'uvec3', 'uvec4', 'bool', 'mat2', 'mat3', 'mat4'}

def red(msg): sys.exit('[RED] ' + msg)

def text_of(b):
    b = bytes(b); z = b.find(b'\0')
    return b[:z] if z >= 0 else b

def nso_strings(path):
    """'#version' strings of an NSO's read-only segment (lz4 segments, as dm/tools/nso.py decompresses them)"""
    import lz4.block, struct
    d = open(path, 'rb').read()
    flags = struct.unpack_from('<I', d, 0xc)[0]; fo, mo, sz = struct.unpack_from('<III', d, 0x20); csz = struct.unpack_from('<I', d, 0x64)[0]
    img = d[fo:fo + csz]
    if flags >> 1 & 1: img = lz4.block.decompress(img, uncompressed_size=sz)
    out, i = [], 0
    while True:
        i = img.find(b'#version', i)
        if i < 0: break
        if i == 0 or img[i - 1] == 0:
            out.append(text_of(img[i:i + 0x10000]))
        i += 8
    return out

STAGE_EXT = {'vert': 'vert', 'frag': 'frag', 'comp': 'comp', 'vs': 'vert', 'fs': 'frag'}
def stage_of(name):   # a loose shader file's stage from its extension, or None
    return STAGE_EXT.get(name.rsplit('.', 1)[1]) if '.' in os.path.basename(name) else None
def any_stage(name):   # a loose shader file whose extension does not give the stage (.glsl): translated as each stage that compiles
    return os.path.basename(name).lower().endswith('.glsl')


def rel(p, r):   # 表里来源列一律 / 分隔（Windows 出包机上 relpath 给 \，11-05 Windows 出包机 FF7 实测）
    return os.path.relpath(p, r).replace(os.sep, '/')


def sources(roots):
    """(source bytes, stage or None, where) for every shader in the input paths"""
    for r in roots:
        if os.path.isfile(r):
            with open(r, 'rb') as f: head = f.read(4)
            if head == b'NSO0':
                for k, s in enumerate(nso_strings(r)): yield s, None, f'{os.path.basename(r)}#{k}'
            elif stage_of(r) or any_stage(r):
                yield text_of(open(r, 'rb').read()), stage_of(r), os.path.basename(r)
            continue
        if not os.path.isdir(r):
            raise ValueError(f'输入路径不存在：{r}')
        for d, _, fs in romfs_list.walk(r):
            for fn in sorted(fs):
                p = os.path.join(d, fn)
                if fn.endswith('.mvgl'):
                    try: a = mvgl.Archive(p)
                    except ValueError:
                        with open(p, 'rb') as probe:
                            if probe.read(4) == b'AFS2': continue
                        raise
                    for nm in sorted(a.files):
                        if not nm.endswith('.shad'): continue
                        st = 'vert' if nm.endswith('_vp.shad') else 'frag' if nm.endswith('_fp.shad') else None
                        yield text_of(a.read(nm)), st, f'/{rel(p, r)}:{nm}'
                elif fn.endswith('.mbundle'):
                    b = mbundle.Bundle(p)
                    for nm in sorted(b.files):
                        if not nm.endswith('.shader'): continue
                        st = 'vert' if nm.endswith('_v.shader') else 'frag' if nm.endswith('_f.shader') else None
                        yield text_of(b.read(nm)), st, f'/{rel(p, r)}:{nm}'
                elif stage_of(fn) or any_stage(fn):
                    yield text_of(open(p, 'rb').read()), stage_of(fn), '/' + rel(p, r)

# GLSL 改写层（graphics/nvn/gfx/gl/gl_glsl_es.c）：离线链与宿主运行时兜底共用一份 C 实现；这里每个进程编一次它的命令行入口（S2A_GLSL_ES_MAIN），逐支调用
ES_SRC = Path(__file__).resolve().parents[1] / "graphics/nvn/gfx/gl" / "gl_glsl_es.c"
_es_lock, _es_bin = threading.Lock(), None


def es_tool():
    global _es_bin
    with _es_lock:
        if _es_bin is None:
            d = tempfile.mkdtemp(prefix="glsl-es-")
            atexit.register(shutil.rmtree, d, True)
            exe = Path(d) / ("glsl_es.exe" if os.name == "nt" else "glsl_es")   # Windows：不带 .exe 起不来
            run([os.environ.get("CC", "cc"), "-O2", "-DS2A_GLSL_ES_MAIN", ES_SRC, "-o", exe])
            _es_bin = exe
    return _es_bin


def es(args, data):
    """gl_glsl_es.c：prefix（原文补 es）/ rewrite <阶段>（预处理后 → ES 3.10），字节进字节出；失败抛 ValueError（原因同 C 侧，如 unbalanced parentheses）"""
    result = subprocess.run([str(es_tool()), *args], input=data, capture_output=True, timeout=120)
    if result.returncode:
        raise ValueError(result.stderr.decode(errors="replace").strip())
    return result.stdout


def glsl_type(t, refl):
    return refl['types'][t]['name'] if t in refl.get('types', {}) else t

def run(command):
    result = subprocess.run([str(arg) for arg in command], capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise ValueError((result.stdout + result.stderr).strip())
    return result.stdout


def translate(src, stage, key, tmp):
    """每支独立翻译；源码键与 GL 运行时一致，资源分槽只调用共用后端。"""
    src = text_of(src)
    stem = f"{key}_{stage[0]}"
    original = Path(tmp) / f"{stem}.in.{stage}"
    glsl = Path(tmp) / f"{stem}.{stage}"
    spv = Path(tmp) / f"{stem}.gl.spv"
    # NVIDIA 的 GLSL 编译器收「#version 300 / 310 / 320」不带 profile（按 ES 读）；glslang 照规范要求写 es（FINAL FANTASY VII 的 ff7/shaders/*.glsl 全是「#version 320」）。
    #   只改交给 glslang 的副本：键仍是原文的哈希（宿主按 glShaderSource 收到的原文算）
    original.write_bytes(es(["prefix"], src))
    pre = run([os.environ.get("GLSLANG", "glslangValidator"), "-E", "-S", stage, original])
    # 预处理后改写（gl_glsl_es.c s2a_glsl_es_rewrite）：没有 #version / #version 100（街霸 30 周年合集的 .shader、GameMaker）= GLSL ES 1.00 升到 ES 3.10；
    #   #version 300 es（火影忍者 终极风暴羁绊的 Scaleform）升到 310 es；旧纹理函数、gl_Position 重声明、非常量纹理偏移改写
    glsl.write_bytes(es(["rewrite", stage], pre.encode()))
    # 按现行 GL 接口用宽松 Vulkan 发射器收拢普通 uniform；不让 Vulkan 的 Y 翻转流入 GL。
    run(
        [
            os.environ.get("GLSLANG", "glslangValidator"),
            "-V",
            "-R",
            "--aml",
            "--amb",
            "-S",
            stage,
            glsl,
            "-o",
            spv,
        ]
    )
    reflection = json.loads(run(["spirv-cross", spv, "--reflect"]))
    varyings = reflection.get("outputs" if stage == "vert" else "inputs", [])
    if stage in ("vert", "frag"):
        for item in varyings:
            if item.get("array") or item["type"].startswith(("_", "mat")):
                raise ValueError(f"varying {item['name']}：数组 / 接口块 / 矩阵尚未接入按名链接")
    mapping = normalize_resources(spv, reflection)
    function = f"gl_{key}_{stage[0]}"
    row = spirv_to_msl(
        str(spv),
        tmp,
        tmp,
        stages=("vert", "frag", "comp"),
        key=key,
        entry_name=function,
        flip_vert_y=False,
        fixup_clipspace=True,
        varying_names=True,
        dual_source=False,
        texture_1d_as_2d=False,
    )
    if isinstance(row, str):
        raise ValueError(row)
    slots = {}
    for field in row[2]:
        if field.startswith("w:"):
            continue
        left, right = field.split("=")
        kind, pair = left.split(":")
        namespace, binding = map(int, pair.split("."))
        slot, _, count = right.partition("*")
        slots[kind, namespace, binding] = int(slot), int(count or 1)
    fields, used, unsupported = [], [], []
    if stage == "vert":
        fields += [
            f"a:{v['name']}={v['location']}:{v['type']}" for v in reflection.get("inputs", [])
        ]
    elif stage == "frag":
        fields += [f"o:{v['name']}={v['location']}" for v in reflection.get("outputs", [])]
        if re.search(r"\bgl_FragDepth\b", Path(glsl).read_text(errors="replace")):   # 写深度：Metal 要求管线挂深度附件，目标没有深度时运行时挂假深度（gl_draw.m）
            fields.append("D")
    else:
        unsupported.append("当前 GL 运行时没有计算阶段")
    for resource in mapping:
        match = slots.get(
            (resource["resource_kind"], resource["normalized_set"], resource["normalized_binding"])
        )
        if match is None:
            continue
        slot, count = match
        resource.update(
            metal_slot=slot, metal_class=SLOT_CLASS[resource["resource_kind"]], count=count
        )
        used.append(resource)
        category = resource["kind"]
        if (
            category == "ubos"
            and reflection["types"][resource["type"]]["name"] == "gl_DefaultUniformBlock"
        ):
            fields.append(f"b:{slot}:{resource['block_size']}")
            members = [(member, "", 0) for member in reflection["types"][resource["type"]]["members"]]
            while members:
                member, prefix, base = members.pop(0)
                name, dimensions = prefix + member["name"], member.get("array", [])
                # 结构体成员（不是数组的）按 GL 命名展开成「名字.成员」，偏移加上结构体自己的偏移（GameMaker 内置着色器的 uniform LightEnv u_LightEnv）；
                #   展开的成员排在原位、按声明序（graphics/nvn/gfx/gl/gl_xlate.c 同口径）
                if member["type"] in reflection.get("types", {}) and not dimensions:
                    members[0:0] = [(sub, name + ".", base + member["offset"]) for sub in reflection["types"][member["type"]]["members"]]
                    continue
                ty = glsl_type(member["type"], reflection)
                if ty not in VEC_TYPES or len(dimensions) > 1 or any(not n for n in dimensions):
                    unsupported.append(f"普通 uniform {name}：类型 / 数组尚未接入运行时")
                    continue
                fields.append(
                    f"u:{name}={base + member['offset']}:{ty}:{dimensions[0] if dimensions else 0}:{member.get('array_stride', 0)}"
                )
        elif category == "ubos" and count == 1:   # 命名统一块（GLSL uniform Block { … }）：数据在游戏的缓冲里，绘制时按 glUniformBlockBinding 的绑定点取（FINAL FANTASY VII 的 BlockVertex / BlockFragment）
            fields.append(f"B:{reflection['types'][resource['type']]['name']}={slot}:{resource['block_size']}")
        elif category == "textures":   # 采样器数组（Scaleform 的 uniform sampler2D tex[2]）：Metal 占连续 count 个纹理 / 采样器槽
            fields.append(f"t:{resource['name']}={slot}:{resource['type']}" + (f":{count}" if count > 1 else ""))
        else:
            unsupported.append(f"{category} {resource['name']}：GL 库表口径 1 没有此接线")
    return dict(
        key=key,
        stage=stage,
        function=function,
        fields=fields,
        resources=used,
        reflection=reflection,
        msl=row[3][0],
        spv=str(spv),
        unsupported=unsupported,
    )


def one(task, temp, components):
    index, (src, stage, where) = task
    work = Path(temp) / f"source-{index}"
    work.mkdir()
    key, rows, errors = hashlib.sha256(src).hexdigest()[:16], [], []
    for st in [stage] if stage else ["vert", "frag"]:
        try:
            row = translate(src, st, key, str(work))
            row["source"] = where
            if row["unsupported"] and not components:
                raise ValueError("; ".join(row["unsupported"]))
            rows.append(row)
        except (ValueError, OSError, ImportError, subprocess.SubprocessError, SystemExit) as exc:
            diagnostic = str(exc).replace(str(work / f"{key}_{st[0]}.{st}"), where)
            diagnostic = diagnostic.replace(str(work / f"{key}_{st[0]}.in.{st}"), where)
            errors.append(f"{where} [{st}]: {diagnostic}")
    # NSO strings do not identify their stage; a successful stage is sufficient.
    # 两个阶段都失败时只报真实阶段的原因：glslang 编过、卡在后面（接线 / 翻译）的那个阶段才是它的阶段；另一阶段的编译错是试错的必然结果，不打红。
    #   都编过（同一个原因）只报一条；都编不过（真编译错）两条都报
    if not rows and len(errors) == 2:
        compiled = [e for e in errors if "SPIR-V is not generated" not in e and "ERROR:" not in e]
        if compiled: errors = compiled[:1]
    # 每个试过的阶段都只卡在 glslang 链接「Missing entry point」：源码里没有 main，不是一支完整着色器，而是引擎运行时拼接用的片段
    #   （main 里的公共头「#version … precision …」、包含文件；#518 0100BB400B276000 main#0）。离线翻不出也不该翻，记跳过；
    #   游戏运行时拼成的完整源码由宿主首遇现编（gl_prog.m）。只认这一种原因，别的编译错照旧计失败
    if not rows and errors and all("Missing entry point" in e for e in errors):
        return [], [], 1
    return rows, [] if rows else errors, 0


def metal(command, temp):
    """Metal 编译器：Windows 上按相对 temp 的路径交给编译器（spirv_msl.metal_run：空格会被再拆开、非 ASCII 打不开）"""
    result = metal_run([str(arg) for arg in command], temp, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise ValueError((result.stdout + result.stderr).strip())
    return result.stdout


def compile_msl(task, temp):
    identity, row, sdk, extra = task
    air = Path(temp) / f"{row['function']}.{sdk}.air"
    try:
        metal(metal_cmd(sdk, "metal", "-c", "-fpreserve-invariance", *extra, row["msl"], "-o", air), temp)
        return identity, sdk, str(air), None
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        return identity, sdk, None, f"{row['source']} [{sdk}]: {exc}"


def library(airs, destination, sdk):
    path = Path(destination) / f"gl_shaders.{sdk}.metallib"
    metal(metal_cmd(sdk, "metallib", *airs, "-o", path), destination)
    return path


def tool_version(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise ValueError((result.stdout + result.stderr).strip())
    return " ".join((result.stdout + result.stderr).split())


def table_header():
    return [
        f"# s2arm-gl-lib {GL_LIB_ABI}",
        "# GL shaders: key = sha256(GLSL source before NUL)[:16]; functions gl_<key>_v / gl_<key>_f; "
        "a: vertex inputs, u: default uniform members (offset:type:count:stride), b: block (slot:size), "
        "t: combined samplers (slot:type[:count]), o: fragment outputs",
        "# "
        + tool_version([os.environ.get("GLSLANG", "glslangValidator"), "--version"])
        + "; spirv-cross "
        + tool_version(["spirv-cross", "--revision"]),
    ]


def write_empty(destinations):
    """离线一支没有（GameMaker 等运行时拼 GLSL 的引擎）：只出表头、不出库（metallib 不收空输入）；宿主照读表头，库里没有的源码首遇时现场翻译（gl_prog.m）"""
    table = "\n".join(table_header()) + "\n"
    for destination, _sdk, _extra in destinations:
        destination.mkdir(parents=True, exist_ok=True)
        (destination / "gl_shaders.metallib").unlink(missing_ok=True)
        staged = destination / ".gl_shaders.tsv.tmp"
        staged.write_text(table, encoding="utf-8", newline="\n")
        staged.replace(destination / "gl_shaders.tsv")


def write_product(compiled, destination, table, diagnostics):
    """Only runtime library/table belong in gl/. Move legacy generated debug files out."""
    destination.mkdir(parents=True, exist_ok=True)
    for entry in tuple(destination.iterdir()):
        generated = re.fullmatch(r"(?:gl_)?[0-9a-f]{16}(?:_[vfc])?\.(?:metal|spv|air)", entry.name)
        if entry.is_file() and (generated or entry.name == "gl_shaders.json"):
            legacy = diagnostics / "legacy"
            legacy.mkdir(exist_ok=True)
            entry.replace(legacy / entry.name)
    lib = destination / "gl_shaders.metallib"
    staged = destination / ".gl_shaders.metallib.tmp"
    shutil.copyfile(compiled, staged)
    staged.replace(lib)
    if table is not None:
        staged_table = destination / ".gl_shaders.tsv.tmp"
        staged_table.write_text(table, encoding="utf-8", newline="\n")
        staged_table.replace(destination / "gl_shaders.tsv")


def clear_products(destinations):
    # The caller owns exactly these generated outputs; never retain a previous success after total failure.
    for destination, _sdk, _extra in destinations:
        if not destination.is_dir() or destination.is_symlink():
            continue
        for name in ("gl_shaders.metallib", "gl_shaders.tsv"):
            (destination / name).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description="独立 GLSL → 共用 SPIR-V 后端 → GL 离线库")
    parser.add_argument(
        "paths", nargs="+", help="RomFS / main NSO / 采集目录或 GLSL，最后一项为输出根"
    )
    parser.add_argument("--ios", type=Path)
    parser.add_argument(
        "--components-only",
        action="store_true",
        help="只验证阶段组件，不出运行时 GL 表；允许计算 / UBO / SSBO",
    )
    parser.add_argument(
        "-j", "--jobs", type=int, default=os.cpu_count() or 1, help="并行翻译与 Metal 编译数量"
    )
    args = parser.parse_args()
    if len(args.paths) < 2 or args.jobs < 1:
        parser.error("需要输入路径、输出目录和正数并行度")
    roots, out = args.paths[:-1], Path(args.paths[-1])
    count, failed, destinations, can_clear = 0, [], [], False
    try:
        items, seen = [], set()
        for src, stage, where in sources(roots):
            src = text_of(src)
            identity = (src, stage)
            if identity not in seen:
                items.append((src, stage, where))
                seen.add(identity)
        count = len(items)
        subdir = "components" if args.components_only else "gl"
        # Mac 目标写明最低版本号（同 NVN 支 graphics/tools/direct/dsh/batch/Build.cs、tools/toolchain.env 的 15.0）：不写时 Mac 跟着装的 SDK 走（26.5 → macOS 26），
        #   Windows 的 metal.exe 缺省 macOS 10.15（11-05 Windows 出包机实测），两边都不定
        destinations = [(out / subdir, "macosx", ["-mmacosx-version-min=15.0"])]
        if args.ios:
            destinations.append(
                (
                    args.ios / subdir,
                    "iphoneos",
                    ["-mios-version-min=18.0", "-fmetal-math-mode=relaxed"],
                )
            )
        if len({path.resolve() for path, _, _ in destinations}) != len(destinations):
            raise ValueError("macOS 与 iOS 输出目录不能相同")
        if any(
            path.is_symlink() or (path.exists() and not path.is_dir())
            for path, _, _ in destinations
        ):
            raise ValueError("目标子目录必须是普通目录，不能是文件或符号链接")
        if not items:
            if args.components_only:
                raise ValueError("没有 GLSL 着色器")
            write_empty(destinations)
            print("GLSL 汇总：成功 0、失败 0、跳过 0")
            return 0
        can_clear = True
        diagnostics = out / (subdir + "_diagnostics")
        diagnostics.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="glsl-") as temp:
            with cf.ThreadPoolExecutor(args.jobs) as pool:
                translated = list(
                    pool.map(lambda task: one(task, temp, args.components_only), enumerate(items))
                )
            rows = {}
            skipped = sum(skip for _, _, skip in translated)
            for candidates, errors, _ in translated:
                if errors:
                    failed.append("\n".join(errors))
                for row in candidates:
                    rows.setdefault((row["key"], row["stage"]), row)
            tasks = [
                (identity, row, sdk, extra)
                for identity, row in rows.items()
                for _, sdk, extra in destinations
            ]
            with cf.ThreadPoolExecutor(args.jobs) as pool:
                compiled = list(pool.map(lambda task: compile_msl(task, temp), tasks))
            # 每个目标各记各的编不过（审计 P1-176：原先按着色器身份共用一份，Mac 编不过的支 iOS 编得过也不收）；
            #   汇总行「失败」= 至少一个目标编不过的支（每支只记一次原话），「成功」= 至少一个目标编成的支
            bad = {sdk: set() for _, sdk, _ in destinations}
            airs, reported = {}, set()
            for identity, sdk, air, error in compiled:
                if error:
                    if identity not in reported:
                        failed.append(error)
                    reported.add(identity)
                    bad[sdk].add(identity)
                else:
                    airs[identity, sdk] = air
            mine = {sdk: {identity: row for identity, row in rows.items() if identity not in bad[sdk]} for _, sdk, _ in destinations}
            rows = {identity: row for identity, row in rows.items() if any(identity in m for m in mine.values())}
            for error in failed:
                print("[RED] " + error, file=sys.stderr)
            report = {
                "schema_version": 1,
                "runtime_table": not args.components_only,
                "failed": len(failed),
                "skipped": skipped,
                "errors": failed,
                "shaders": [],
            }
            for row in rows.values():
                report["shaders"].append({k: v for k, v in row.items() if k not in ("msl", "spv")})
                for field, extension in (("msl", ".metal"), ("spv", ".spv")):
                    (diagnostics / (row["function"] + extension)).write_bytes(
                        Path(row[field]).read_bytes()
                    )
            (diagnostics / "gl_shaders.json").write_text(
                json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n"
            )
            if not rows and not failed and not args.components_only:
                # 只有跳过的片段：同离线一支没有，只出表头、全部运行时首遇现编
                write_empty(destinations)
                print(f"GLSL 汇总：成功 0、失败 0、跳过 {skipped}")
                return 0
            if not rows:
                if args.components_only:
                    clear_products(destinations)
                    print(f"GLSL 汇总：成功 0、失败 {len(failed)}、跳过 {skipped}")
                    return 1
                # 一支都没译成（v0.3.1 拿不准不停；#702 原先整款停）：同离线一支没有，只出表头、全部运行时首遇现编；失败数留在汇总行，direct_lib.sh 记降级
                write_empty(destinations)
                print(f"【黄】GLSL 离线一支没译成（{len(failed)} 支失败，见上方 [RED]），只出表头、运行时首遇现编", file=sys.stderr)
                print(f"GLSL 汇总：成功 0、失败 {len(failed)}、跳过 {skipped}")
                return 0
            for destination, sdk, extra in destinations:
                own = mine[sdk]
                if not own:   # 这个目标一支不剩：只这个目标出表头（另一个目标已编成的库照出）
                    if args.components_only:
                        clear_products([(destination, sdk, extra)])
                    else:
                        write_empty([(destination, sdk, extra)])
                    print(f"{sdk}: 0 shaders after dropping the ones this target cannot compile ({len(bad[sdk])}), table header only → {destination}/gl_shaders.tsv")
                    continue
                table = table_header()
                table += [
                    f"{key}\t{stage}\t{' '.join(row['fields'])}\t{row['source']}"
                    for (key, stage), row in sorted(own.items())
                ]
                write_product(
                    library([airs[identity, sdk] for identity in own], temp, sdk),
                    destination,
                    None if args.components_only else "\n".join(table) + "\n",
                    diagnostics,
                )
                print(f"{sdk}: {len(own)} shaders（这个目标编不过 {len(bad[sdk])}）→ {destination}")
        print(f"GLSL 汇总：成功 {len(rows)}、失败 {len(failed)}、跳过 {skipped}")
        # 部分译不过：译成的照出库、退 0（v0.3.1 拿不准不停），失败数在汇总行；只校验阶段组件（--components-only）时照旧退 1
        return 1 if failed and args.components_only else 0
    except (ValueError, OSError, ImportError, subprocess.SubprocessError, SystemExit) as exc:
        if can_clear:
            clear_products(destinations)
        print(f"[RED] {exc}", file=sys.stderr)
        print(f"GLSL 汇总：成功 0、失败 {count}、跳过 0")
        return 1


if __name__ == "__main__":
    sys.exit(main())
