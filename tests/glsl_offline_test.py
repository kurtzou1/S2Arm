#!/usr/bin/env python3
"""真实 GLSL / SPIRV-Cross / Metal；运行时表与组件验证分开，期望手写。"""

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "translator/gl_shaders.py"
FIX = ROOT / "tests/glsl"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(command, success=True):
    result = subprocess.run(
        [str(arg) for arg in command], capture_output=True, text=True, timeout=120
    )
    if success and result.returncode:
        raise AssertionError(f"{command}\n{result.stdout}\n{result.stderr}")
    return result


def report(path, component=False):
    return json.loads(
        (
            path / ("components_diagnostics" if component else "gl_diagnostics") / "gl_shaders.json"
        ).read_text()
    )


def same_row(a, b):
    if isinstance(a, str):
        assert a == b
    else:
        assert a[:3] == b[:3]
        assert [Path(p).read_bytes() for p in a[3]] == [Path(p).read_bytes() for p in b[3]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    for command in (
        os.environ.get("GLSLANG", "glslangValidator"),
        "spirv-cross",
        "spirv-val",
        "spirv-as",
        "xcrun",
    ):
        assert shutil.which(command), f"缺工具 {command}，不下载或跳过"
    out = args.out or Path(tempfile.mkdtemp(prefix="glsl-test-"))
    out.mkdir(parents=True, exist_ok=True)
    vk = load("vk_after", ROOT / "translator/vk_shaders.py")
    shared = load("common_backend", ROOT / "graphics/tools/spirv_msl.py")
    baseline = load("vk_before", args.baseline) if args.baseline else None
    total, parity, before_after, failures = 0, 0, 0, 0
    # 组件覆盖 UBO / SSBO / 同 binding 0 的资源；两种语言、三个阶段全部真编库。
    for profile in ("desktop", "es"):
        destination = out / profile
        inputs = [FIX / f"{profile}.{stage}" for stage in ("vert", "frag", "comp")]
        result = run(
            [
                sys.executable,
                CLI,
                "--components-only",
                *inputs,
                destination,
                "--ios",
                out / (profile + "-ios"),
            ]
        )
        assert "成功 3、失败 0、跳过 0" in result.stdout
        rows = report(destination, True)["shaders"]
        for row in rows:
            source = (FIX / f"{profile}.{row['stage']}").read_bytes()
            assert row["key"] == hashlib.sha256(source).hexdigest()[:16]
            stage = row["stage"]
            expected = (
                {"Camera": ("buffer", 0), "gl_DefaultUniformBlock": ("buffer", 1)}
                if stage == "vert"
                else {"Settings": ("buffer", 0), "Results": ("buffer", 1), "albedo": ("texture", 0)}
                if stage == "frag"
                else {
                    "Params": ("buffer", 0),
                    "gl_DefaultUniformBlock": ("buffer", 1),
                    "Data": ("buffer", 2),
                    "source": ("texture", 0),
                }
            )
            actual = {r["name"]: (r["metal_class"], r["metal_slot"]) for r in row["resources"]}
            assert actual == expected, (profile, stage, actual)
            if stage == "comp":
                assert {
                    r["name"]: r["gl_binding"]
                    for r in row["resources"]
                    if r["name"] != "gl_DefaultUniformBlock"
                } == {"Params": 0, "Data": 0, "source": 0}
            spv = destination / "components_diagnostics" / (row["function"] + ".spv")
            run(["spirv-val", "--target-env", "vulkan1.0", spv])
            after = out / f"{profile}-{stage}-after"
            after.mkdir()
            common = out / f"{profile}-{stage}-common"
            common.mkdir()
            row_vk = vk.one(str(spv), str(after), str(spv.parent))
            same_row(row_vk, shared.translate(str(spv), str(common), str(spv.parent)))
            parity += 1
            if baseline:
                before = out / f"{profile}-{stage}-before"
                before.mkdir()
                same_row(row_vk, baseline.one(str(spv), str(before), str(spv.parent)))
                before_after += 1
            total += 1
        assert not (destination / "components/gl_shaders.tsv").exists()
        assert not (destination / "gl").exists()
        assert (out / (profile + "-ios") / "components/gl_shaders.metallib").stat().st_size > 0
    # 一个顶点可配不同片元；两阶段声明顺序相反，MSL 按 user(name) 匹配。
    cap = out / "capture"
    cap.mkdir()
    vertex = b"#version 450 core\nin vec2 position;\nout vec2 uv;\nout vec3 tint;\nuniform float gain;\nvoid main(){uv=position;tint=vec3(gain);gl_Position=vec4(position,0,1);if(position.x>9)return;gl_Position.z+=0;}\n"
    frag_a = b"#version 450 core\nin vec3 tint;\nin vec2 uv;\nuniform vec4 shade;\nout vec4 color;\nvoid main(){color=vec4(uv,tint.x,1)*shade;}\n"
    frag_b = frag_a.replace(b"vec4(uv,tint.x,1)", b"vec4(uv,tint.y,1)")
    for name, src in [("one.vert", vertex), ("a.frag", frag_a), ("b.frag", frag_b)]:
        (cap / name).write_bytes(src)
    # 同源码与首 NUL 后垃圾去重，键与运行时 glShaderSource 完全相同。
    (cap / "duplicate.vert").write_bytes(vertex + b"\0ignored")
    runtime = out / "runtime"
    result = run([sys.executable, CLI, cap, runtime, "--ios", out / "runtime-ios"])
    assert "成功 3、失败 0、跳过 0" in result.stdout
    rows = report(runtime)["shaders"]
    table = (runtime / "gl/gl_shaders.tsv").read_text()
    assert table.splitlines()[0] == "# s2arm-gl-lib 3"
    by_stage = {r["stage"]: r for r in rows}
    assert set(by_stage["vert"]["fields"]) == {"a:position=0:vec2", "b:0:4", "u:gain=0:float:0:0"}
    assert set(by_stage["frag"]["fields"]) == {"o:color=0", "b:0:16", "u:shade=0:vec4:0:0"}
    for row in rows:
        msl = (runtime / "gl_diagnostics" / (row["function"] + ".metal")).read_text()
        assert "[[user(uv)]]" in msl and "[[user(tint)]]" in msl
        assert "user(locn" not in msl
        assert row["function"] == f"gl_{row['key']}_{row['stage'][0]}"
        assert (out / "runtime-ios/gl/gl_shaders.tsv").read_text() == table
        if row["stage"] == "vert":
            # SPIRV-Cross must fix every vertex exit, without Y inversion.
            assert msl.count(".z = (out.gl_Position.z + out.gl_Position.w) * 0.5") == 2, msl
            assert not re.search(r"gl_Position\.y\s*=\s*-", msl)
    solo = out / "solo"
    run([sys.executable, CLI, cap / "one.vert", solo])
    v = by_stage["vert"]["function"] + ".metal"
    assert (runtime / "gl_diagnostics" / v).read_bytes() == (
        solo / "gl_diagnostics" / v
    ).read_bytes()
    # 普通 uniform 超过旧实现的 16 槽限制，也只占一个块；偏移期望为 std140。
    many = out / "many.vert"
    declarations = "".join(f"uniform float u{i};\n" for i in range(20))
    many.write_text(
        "#version 450 core\n"
        + declarations
        + "void main(){gl_Position=vec4("
        + "+".join(f"u{i}" for i in range(20))
        + ");}\n"
    )
    run([sys.executable, CLI, many, out / "many"])
    many_fields = set(report(out / "many")["shaders"][0]["fields"])
    assert "b:0:80" in many_fields
    assert {f"u:u{i}={i * 4}:float:0:0" for i in range(20)} <= many_fields
    # main NSO 与 MVGL 均用原创文本构造；不知道阶段时尝试独立编译，不靠配对。
    raw = frag_a + b"\0"
    header = bytearray(0x100)
    header[:4] = b"NSO0"
    struct.pack_into("<III", header, 0x20, 0x100, 0, len(raw))
    struct.pack_into("<I", header, 0x64, len(raw))
    nso = out / "main"
    nso.write_bytes(header + raw)
    archives = out / "romfs"
    archives.mkdir()
    name = b"material_vp"
    start = 0x14 + 8 + 0x40 + 12
    mvgl = struct.pack("<4sHHIII", b"MDB1", 1, 1, 1, start, start + len(vertex))
    mvgl += struct.pack("<HHHH", 0, 0, 0, 0) + b"shad" + name.ljust(60, b"\0")
    mvgl += struct.pack("<III", 0, len(vertex), len(vertex)) + vertex
    (archives / "synthetic.mvgl").write_bytes(mvgl)
    run([sys.executable, CLI, nso, archives, out / "readers"])
    assert {r["key"] for r in report(out / "readers")["shaders"]} == {
        hashlib.sha256(s).hexdigest()[:16] for s in (vertex, frag_a)
    }
    # Digital Eclipse .mbundle（街霸 30 周年合集）：二进制属性表，顶层字典「文件名 → 数据」，尾部 26 字节、顶层字段是去掉 8 字节文件头的偏移；
    #   .shader 按 _v / _f 定阶段，内容是写明 #version 100 的 GLSL ES 1.00（attribute / varying / gl_FragColor）。期望：两支都收到、键 = 原文哈希、阶段对、都编得出
    es_v = b"#version 100\nuniform mat4 mvp;\nattribute vec4 pos;\nattribute vec2 uv;\nvarying vec2 vuv;\nvoid main(){vuv=uv;gl_Position=mvp*pos;}\n"
    es_f = b"#version 100\nprecision highp float;\nuniform sampler2D tex;\nvarying vec2 vuv;\nvoid main(){gl_FragColor=texture2D(tex,vuv);}\n"
    entries = [(b"Quad_v.shader", es_v), (b"Quad_f.shader", es_f), (b"Logo.png", b"\x89PNG not a shader")]
    body, offs = bytearray(b"bplist00"), []
    def obj(raw):
        offs.append(len(body)); body.extend(raw); return len(offs) - 1
    def sized(hi, n):
        return bytes([hi | n]) if n < 15 else bytes([hi | 15, 0x12]) + struct.pack(">I", n)
    keys = [obj(sized(0x50, len(nm)) + nm) for nm, _ in entries]
    vals = [obj(sized(0x40, len(dat)) + dat) for _, dat in entries]
    top = obj(bytes([0xD0 | len(entries)]) + b"".join(struct.pack(">I", i) for i in keys + vals))
    table = len(body); body.extend(b"".join(struct.pack(">I", o) for o in offs))
    body.extend(bytes([4, 4]) + struct.pack(">QQQ", len(offs), offs[top] - 8, table))
    bundles = out / "mbundle_romfs" / "Bundle"
    bundles.mkdir(parents=True)
    (bundles / "bundleMain.mbundle").write_bytes(bytes(body))
    run([sys.executable, CLI, out / "mbundle_romfs", out / "mbundle"])
    got = {(r["key"], r["stage"]) for r in report(out / "mbundle")["shaders"]}
    assert got == {(hashlib.sha256(es_v).hexdigest()[:16], "vert"), (hashlib.sha256(es_f).hexdigest()[:16], "frag")}, got
    # 主线既有 SPIR-V 覆盖 push constants、双源变体与固定大小计算 kernel。
    for name in ("t_prog_vs", "t_prog_fs", "t_prog_cs", "t_fbr_fsf", "t_fbr_fsn"):
        spv = out / (name + ".spv")
        run(
            [
                "spirv-as",
                "--target-env",
                "spv1.3",
                ROOT / "graphics/metal/tests" / (name + ".spvasm"),
                "-o",
                spv,
            ]
        )
        after = out / (name + "-after")
        after.mkdir()
        row = vk.one(str(spv), str(after), str(out))
        if baseline:
            before = out / (name + "-before")
            before.mkdir()
            same_row(row, baseline.one(str(spv), str(before), str(out)))
            before_after += 1
    # ABI 2 的一维纹理转换纳入对拍，防止共用抽取漏掉主线新增选项。
    one_d = out / "one-d.frag"
    one_d.write_text(
        "#version 450\nlayout(binding=0) uniform sampler1D tex;\nlayout(location=0) out vec4 color;\nvoid main(){color=texture(tex,0.5);}\n"
    )
    spv = out / "one-d.spv"
    run([os.environ.get("GLSLANG", "glslangValidator"), "-V", one_d, "-o", spv])
    after = out / "one-d-after"
    after.mkdir()
    row = vk.one(str(spv), str(after), str(out))
    assert "texture2d<" in Path(row[3][0]).read_text()
    if baseline:
        before = out / "one-d-before"
        before.mkdir()
        same_row(row, baseline.one(str(spv), str(before), str(out)))
        before_after += 1
    for arguments, error, count in (
        ([FIX / "broken.frag", out / "broken"], r"broken\.frag:4:", 1),
        ([FIX / "desktop.comp", out / "unsupported-comp"], "计算阶段", 1),
        ([FIX / "desktop.frag", out / "unsupported-resources"], "GL 库表口径 1", 1),
    ):
        # v0.3.1 拿不准不停：一支都没译成也退 0、只出表头（运行时首遇现编），失败原因照打、汇总行留失败数（direct_lib.sh 记降级）；原先退非 0、不出表
        bad = run([sys.executable, CLI, *arguments], success=False)
        assert bad.returncode == 0 and re.search(error, bad.stderr) and "【黄】GLSL 离线一支没译成" in bad.stderr, bad.stderr
        assert f"成功 0、失败 {count}、跳过 0" in bad.stdout
        if arguments[-1] != runtime:
            assert (arguments[-1] / "gl/gl_shaders.tsv").exists() and not (arguments[-1] / "gl/gl_shaders.metallib").exists()
        failures += 1
    # 离线一支没有（GameMaker 等运行时才拼 GLSL）：退 0、汇总「成功 0、失败 0」，只出表头（3 行注释、第一行口径）、不出库，旧库删掉
    empty_in, empty_out = out / "empty-in", out / "empty"
    empty_in.mkdir()
    (empty_out / "gl").mkdir(parents=True)
    (empty_out / "gl/gl_shaders.metallib").write_bytes(b"stale")
    empty = run([sys.executable, CLI, empty_in, empty_out, "--ios", out / "empty-ios"])
    assert "GLSL 汇总：成功 0、失败 0、跳过 0" in empty.stdout, empty.stdout
    for product in (empty_out / "gl", out / "empty-ios/gl"):
        lines = (product / "gl_shaders.tsv").read_text().splitlines()
        assert len(lines) == 3 and all(line.startswith("#") for line in lines) and lines[0].startswith("# s2arm-gl-lib "), lines
        assert not (product / "gl_shaders.metallib").exists()
    # 没有 main 的片段（#518：main 里的公共头「#version … precision …」）：两阶段都只卡在「Missing entry point」，记跳过、不计失败；
    #   只有片段时同离线一支没有（退 0、只出表头），和完整着色器同在时照常出库、退 0
    header = out / "header.glsl"
    header.write_text("#version 310 es\nprecision mediump float;\nuniform vec4 tint;\n")
    only = run([sys.executable, CLI, header, out / "header-only", "--ios", out / "header-only-ios"])
    assert "GLSL 汇总：成功 0、失败 0、跳过 1" in only.stdout, only.stdout + only.stderr
    for product in (out / "header-only/gl", out / "header-only-ios/gl"):
        assert (product / "gl_shaders.tsv").read_text().count("\n") == 3
        assert not (product / "gl_shaders.metallib").exists()
    mixed = run([sys.executable, CLI, header, FIX / "es.vert", out / "header-mixed"])
    assert "GLSL 汇总：成功 1、失败 0、跳过 1" in mixed.stdout, mixed.stdout + mixed.stderr
    assert (out / "header-mixed/gl/gl_shaders.metallib").stat().st_size > 0
    # 新主线必须保留输入附件和固定 / 特化工作组两种计算行为。
    extra_cases = {
        "subpass.frag": "#version 450\nlayout(input_attachment_index=0,set=0,binding=7) uniform subpassInput attachment;\nlayout(location=0) out vec4 color;\nvoid main(){color=subpassLoad(attachment);}\n",
        "fixed.comp": "#version 450\nlayout(local_size_x=8,local_size_y=4,local_size_z=2) in;\nlayout(std430,binding=3) buffer Data{uint value;} data;\nvoid main(){data.value=gl_GlobalInvocationID.x;}\n",
        "specialized.comp": "#version 450\nlayout(local_size_x_id=0,local_size_y=2,local_size_z=1) in;\nvoid main(){}\n",
    }
    for name, source in extra_cases.items():
        src = out / name
        src.write_text(source)
        spv = out / (name + ".spv")
        run([os.environ.get("GLSLANG", "glslangValidator"), "-V", src, "-o", spv])
        after = out / (name + "-after")
        after.mkdir()
        row = vk.one(str(spv), str(after), str(out))
        if name == "specialized.comp":
            assert row == "comp (workgroup size from specialization constants)"
        elif name == "subpass.frag":
            assert row[2] == ["t:0.7=0"], row[2]
        else:
            assert row[1] == "comp" and row[2] == ["b:0.3=0", "w:8.4=2"], row[:3]
            assert "kernel " in Path(row[3][0]).read_text()
        if not isinstance(row, str):
            run(["xcrun", "-sdk", "macosx", "metal", "-c", row[3][0], "-o", out / (name + ".air")])
        if baseline:
            before = out / (name + "-before")
            before.mkdir()
            same_row(row, baseline.one(str(spv), str(before), str(out)))
            before_after += 1
    # Owner 的混合批：6 好 + 语法错 + 自定义命名统一块；语法错算 1 个失败，其余 7 个出库，命名统一块登记成 B:<块名>=<槽>:<大小>（宿主 glUniformBlockBinding 按它绑）。
    mixed = out / "mixed-capture"
    mixed.mkdir()
    for index in range(3):
        (mixed / f"{index}.vert").write_bytes(vertex + f"// vertex {index}\n".encode())
        (mixed / f"{index}.frag").write_bytes(frag_a + f"// fragment {index}\n".encode())
    (mixed / "broken.frag").write_bytes((FIX / "broken.frag").read_bytes())
    (mixed / "custom.vert").write_text(
        "#version 450\nlayout(std140) uniform Custom {float gain;} custom;\nvoid main(){gl_Position=vec4(custom.gain);}\n"
    )
    mixed_out = out / "mixed"
    result = run([sys.executable, CLI, mixed, mixed_out, "--ios", out / "mixed-ios"], success=False)
    assert result.returncode == 0 and "成功 7、失败 1、跳过 0" in result.stdout, (   # v0.3.1：部分译不过照出库、退 0
        result.stdout + result.stderr
    )
    assert re.search(r"broken\.frag:4:", result.stderr) and "custom.vert" not in result.stderr
    lines = [
        line
        for line in (mixed_out / "gl/gl_shaders.tsv").read_text().splitlines()
        if not line.startswith("#")
    ]
    assert len(lines) == 7 and len(report(mixed_out)["shaders"]) == 7
    assert report(mixed_out)["failed"] == 1
    assert [line.split("\t")[2] for line in lines if line.endswith("/custom.vert")] == ["B:Custom=0:4"], lines
    assert (mixed_out / "gl/gl_shaders.tsv").read_bytes() == (
        out / "mixed-ios/gl/gl_shaders.tsv"
    ).read_bytes()
    for product in (mixed_out / "gl", out / "mixed-ios/gl", runtime / "gl"):
        assert {p.name for p in product.iterdir()} == {"gl_shaders.metallib", "gl_shaders.tsv"}
    assert len([p for p in (mixed_out / "gl_diagnostics").iterdir() if p.suffix == ".metal"]) == 7
    # 原目录可重跑；上一版进包的核验文件移到目录外；新表带格式和工具版本。
    (runtime / "gl" / v).write_text("legacy debug output")
    (runtime / "gl/gl_shaders.json").write_text("{}")
    result = run([sys.executable, CLI, cap / "one.vert", runtime])
    assert "成功 1、失败 0、跳过 0" in result.stdout
    rerun = (runtime / "gl/gl_shaders.tsv").read_text().splitlines()
    assert len(rerun) == 4 and all(line.startswith("#") for line in rerun[:3])
    assert (
        "default uniform" in rerun[1]
        and "glslang" in rerun[2].lower()
        and "spirv-cross" in rerun[2]
    )
    assert {p.name for p in (runtime / "gl").iterdir()} == {"gl_shaders.metallib", "gl_shaders.tsv"}
    # 全坏重跑必须移除上次的库与表行，不能拿上次成功伪装本轮成功（v0.3.1：退 0、只留表头、运行时首遇现编）。
    result = run([sys.executable, CLI, FIX / "broken.frag", runtime], success=False)
    assert result.returncode == 0 and "成功 0、失败 1、跳过 0" in result.stdout
    assert (
        all(line.startswith("#") for line in (runtime / "gl/gl_shaders.tsv").read_text().splitlines())
        and not (runtime / "gl/gl_shaders.metallib").exists()
    )
    summary = dict(
        component_shaders=total,
        component_metal_sdks=2,
        runtime_rows=3,
        shared_parity=parity,
        vulkan_before_after=before_after,
        failure_cases=failures,
        independent_linking=True,
        default_uniform_count=20,
        source_readers=3,
        mixed_good=7,
        mixed_failed=1,
        rerun_overwrite=True,
        product_files=2,
        subpass_input=True,
        fixed_workgroup=[8, 4, 2],
        specialization_skipped=True,
    )
    (out / "results.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print("GLSL 离线链通过：" + json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
