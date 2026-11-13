"""Original tiny producer fixtures; no private data or network."""
import os
os.environ.setdefault("S2A_UNPACK_CACHE", "off")   # 不往本机全机解包缓存写夹具（pack/stages/unpack.sh）
import base64
import json
import shutil
import struct
import sys
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class CloneTests(unittest.TestCase):
    def test_clone_links_skip_collision_and_source_isolation(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            source, dest = t / "source", t / "dest"
            (source / "directory").mkdir(parents=True)
            (source / "directory/data").write_bytes(b"original")
            (source / "directory/nested").symlink_to("data")
            (source / "top").symlink_to("directory/data")
            (source / "skip").write_bytes(b"excluded")
            (source / "directory").chmod(0o555)
            try:
                command = [sys.executable, str(ROOT / "tools/clonedir.py"), str(source), str(dest), "skip"]
                subprocess.run(command, check=True)
                self.assertEqual((dest / "top").read_bytes(), b"original")
                self.assertFalse((dest / "top").is_symlink())
                self.assertTrue((dest / "directory/nested").is_symlink())
                self.assertFalse((dest / "skip").exists())
                self.assertTrue((dest / "directory").stat().st_mode & 0o200)
                (dest / "directory/data").write_bytes(b"changed")
                self.assertEqual((source / "directory/data").read_bytes(), b"original")
                # Existing destinations must not silently merge or overwrite.
                result = subprocess.run(command, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((dest / "directory/data").read_bytes(), b"changed")
            finally:
                (source / "directory").chmod(0o755)


class RootsTests(unittest.TestCase):
    def test_private_seed_and_replay_exclusion(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = os.path.realpath(tmp)
            env = dict(os.environ, S2A_ROOTS=tmp + "/private/worker",
                       S2A_ROOTS_PRIV=tmp + "/private", S2A_ROOTS_SHARED=tmp + "/shared")
            subprocess.run(["bash", "-eu", "-c", r'''source "$1/pack/roots.sh"
mkdir -p "$S2A_ROOTS_SHARED/fixture@seed/shaders/direct"
printf original > "$S2A_ROOTS_SHARED/fixture@seed/shaders/common"
printf old > "$S2A_ROOTS_SHARED/fixture@seed/shaders/direct/keys"
ln -s fixture@seed "$S2A_ROOTS_SHARED/fixture@现行"
cur=$(root_cur fixture)
[ "$cur" = "$S2A_ROOTS/fixture@seed" ]
a=$(root_begin fixture direct)
b=$(root_begin fixture common)
printf new-direct > "$a/shaders/direct/keys"
printf new-common > "$b/shaders/common"
root_commit fixture direct
ROOT_REPLAY="shaders !shaders/direct" root_commit fixture common
cur=$(root_cur fixture)
[ "$(cat "$cur/shaders/direct/keys")" = new-direct ]
[ "$(cat "$cur/shaders/common")" = new-common ]
[ "$(cat "$S2A_ROOTS_SHARED/fixture@seed/shaders/direct/keys")" = old ]
[ "$(cat "$S2A_ROOTS_SHARED/fixture@seed/shaders/common")" = original ]
[ "$(readlink "$S2A_ROOTS_SHARED/fixture@现行")" = fixture@seed ]
''', "crosshost-private-roots", str(ROOT)], env=env, check=True)

    def test_clone_commit_replay_and_source_isolation(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = os.path.realpath(tmp)
            env = dict(os.environ, S2A_ROOTS=tmp + "/roots", S2A_ROOTS_SHARED=tmp + "/unused", S2A_ROMFS_SEAL="1")   # 下面断言 RomFS 只读：那是开发 / 门禁机语义（bd70d1f4 起玩家机缺省不封，同 roots_romfs_store_test）
            subprocess.run(["bash", "-eu", "-c", r'''source "$1/pack/roots.sh"
mkdir -p "$S2A_ROOTS/fixture@seed/romfs/sub"
printf original > "$S2A_ROOTS/fixture@seed/romfs/sub/data"
chmod 555 "$S2A_ROOTS/fixture@seed/romfs/sub"
ln -s fixture@seed "$S2A_ROOTS/fixture@现行"
a=$(root_begin fixture first)
b=$(root_begin fixture second)
printf first > "$a/first"
printf second > "$b/second"
root_commit fixture first
ROOT_REPLAY=second root_commit fixture second
cur=$(root_cur fixture)
[ "$(cat "$cur/first")" = first ]
[ "$(cat "$cur/second")" = second ]
[ "$(cat "$cur/romfs/sub/data")" = original ]
# RomFS 是共享只读存储（pack/roots.sh）：版本里写 RomFS 响亮失败，别的版本读到的仍是原样
if printf changed 2> /dev/null > "$cur/romfs/sub/data"; then exit 1; fi
[ "$(cat "$S2A_ROOTS/fixture@first/romfs/sub/data")" = original ]
[ ! -e "$cur/fixture@second" ]
# Top-level links follow clonefile semantics and become independent entities.
ln -s "$S2A_ROOTS/fixture@first/first" "$cur/link"
c=$(root_begin fixture top)
[ ! -L "$c/link" ]
[ "$(cat "$c/link")" = first ]
printf isolated > "$c/link"
[ "$(cat "$S2A_ROOTS/fixture@first/first")" = first ]
root_abort fixture top
# Nested links remain links during cloning and must be rejected by roots（romfs 只读，放在别的子目录里）.
mkdir -p "$cur/nested"; ln -s "$S2A_ROOTS/fixture@first/first" "$cur/nested/link"
if root_begin fixture unsafe; then exit 1; fi
[ ! -e "$S2A_ROOTS/fixture@unsafe.tmp" ]
chmod -R u+w "$S2A_ROOTS"
''', "crosshost-roots", str(ROOT)], env=env, check=True)


def fixture(widen=True):
    """A hand-encoded AArch64 aspect constant, SVC 1, RET, and one FDE."""
    text = bytearray(0x1000)
    struct.pack_into("<II", text, 0, 0x14000040, 0x1000)
    struct.pack_into("<IIII", text, 0x100, 0x5291C728, 0x72A7FC68, 0xD4000021, 0xD65F03C0)
    if not widen:
        struct.pack_into("<II", text, 0x100, 0xD503201F, 0xD503201F)  # NOPs: no aspect candidate
    ro = bytearray(0x1000)
    struct.pack_into("<4sIIIii", ro, 0, b"MOD0", 0, 0, 0, 0x100, 0x120)
    struct.pack_into("<BBBBiIii", ro, 0x100, 1, 0x1B, 3, 0x3B, 0xFC, 1, -0x1000, 0x118)
    ro[0x200:0x218] = struct.pack("<II", 0x14, 0) + bytes([1]) + b"zR\0" + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
    struct.pack_into("<IIii", ro, 0x218, 0x10, 0x1C, -0x1120, 16)
    header = bytearray(0x100)
    header[:4] = b"NSO0"
    header[0x40:0x50] = bytes(range(16))
    for i in range(3):
        struct.pack_into("<III", header, 0x10 + 16 * i, 0x100 + 0x1000 * i, 0x1000 * i, 0x1000)
        struct.pack_into("<I", header, 0x60 + 4 * i, 0x1000)
    npdm = bytearray(0x100)
    npdm[:4] = b"META"
    struct.pack_into("<I", npdm, 0x70, 0x80)
    npdm[0x80:0x84] = b"ACI0"
    struct.pack_into("<Q", npdm, 0x90, 0x0100AAAA00000000)
    return {"exefs/main": bytes(header + text + ro + bytearray(0x1000)),
            "exefs/main.npdm": bytes(npdm), "romfs/hello.txt": b"original hello\n",
            "romfs/sub/empty": b"", "romfs/sub/data": bytes(range(17))}


def index_entries(data):
    """Independent decoder of the documented S2ARFS01 file table."""
    if data[:8] != b"S2ARFS01":
        raise ValueError("wrong index magic")
    count = struct.unpack_from("<i", data, 16)[0]
    table = [struct.unpack_from("<qqii", data, 20 + i * 24) for i in range(count)]
    path_size = struct.unpack_from("<i", data, 20 + count * 24)[0]
    paths = data[24 + count * 24:24 + count * 24 + path_size]
    return {paths[start:start + length].decode(): size for _, size, start, length in table}


class ProducerTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux build-failure branch only")
    def test_failed_source_build_never_executes_stale_dll(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            dn = t / "dotnet"
            dn.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$CALLS"\n[ "$1" != build ] || exit 17\nexit 0\n')
            dn.chmod(0o755)
            env = dict(os.environ, DOTNET=str(dn), CALLS=str(t / "calls"))
            env.pop("S2A_PREBUILT_TOOLS", None)
            proc = subprocess.run(["bash", str(ROOT / "services/romfs_index.sh"), tmp], env=env)
            self.assertEqual(proc.returncode, 17)
            self.assertEqual(len((t / "calls").read_text().splitlines()), 1)
            self.assertTrue((t / "calls").read_text().startswith("build "))

    def test_original_extract_rewrite_and_source_built_index(self):
        self.run_original_producers(widen=True)

    def test_original_zero_candidate_rewrite_and_index(self):
        self.run_original_producers(widen=False)

    def run_original_producers(self, widen):
        dotnet = os.environ.get("DOTNET") or shutil.which("dotnet")
        if not dotnet:
            self.skipTest("source producer integration requires .NET 10 SDK; not executed")
        py = os.environ.get("S2A_PYTHON") or os.environ.get("S2A_PY")
        if not py:
            venv = os.path.expanduser("~/.s2arm/venv/bin/python3")
            py = venv if os.access(venv, os.X_OK) else shutil.which("python3")
        self.assertTrue(py, "rewrite integration: Python interpreter not found")
        if subprocess.run([py, "-c", "import capstone,lz4"], capture_output=True).returncode:
            self.fail("source rewrite integration requires pinned capstone/lz4; selected interpreter: " + py)
        # 只剩 C 改写器（ea97dc1e0）后，改写器的固定依赖按调用者真实环境定位，再显式传给下面隔离了 S2A_RUN_ROOT 的环境；
        # 不传时依赖回落点指进临时目录，只有同一检出里别的单测先编好 build/rewriter-cli 才绿（门禁并发下看先后）。
        deps = subprocess.run([py, str(ROOT / "pack/rewriter.py"), "deps-path"], capture_output=True, text=True)
        if deps.returncode:
            self.fail("source rewrite integration requires the pinned C rewriter dependencies: " + deps.stderr.strip())
        with tempfile.TemporaryDirectory(prefix="crosshost-stage-") as tmp:
            t = Path(tmp)
            # Test restore cannot contact a feed. Dependencies must already be in NuGet's cache.
            offline = t / "offline"
            offline.mkdir()
            artifacts = Path(os.environ.get("S2A_CROSSHOST_BUILD", str(ROOT / "build/crosshost-stage"))).resolve()
            env = dict(os.environ, DOTNET=dotnet, NuGetAudit="false", RestoreSources=str(offline),
                       S2A_ROOTS=str(t / "roots"), S2A_ROOTS_SHARED=str(t / "unused"),
                       S2A_ROOTS_PRIV=str(t / "private"), S2A_RUN_ROOT=str(t / "run"),
                       S2A_CPATCH="none", S2A_COMMUNITY_DIR=str(t / "community"),
                       S2A_TARGET="apple", S2A_JOBS="1",
                       S2A_WIDEN_DIR=str(t / "no-tables"), S2A_PYTHON=py, S2A_REWRITER_DEPS=deps.stdout.strip(),
                       S2A_ROMFS_ARTIFACTS=str(artifacts / "index"))
            for key in ("S2A_PREBUILT_TOOLS", "S2A_ROOT_CUR", "S2A_STAGE_KEYS", "S2A_COMMUNITY_SELECT", "S2A_CPATCH_DIRS"):
                env.pop(key, None)
            def run(*args):
                return subprocess.run(args, env=env, cwd=ROOT, check=True, timeout=300)
            sys.path.insert(0, str(ROOT))
            from pack.crosshost.prepared import seal, verify, compare, PreparedError
            source_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
            def checkpoint(root, profile):
                # Seal the actual producer root without stripping bookkeeping.
                manifest = t / (profile + ".json")
                original_files = {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()}
                seal(root, manifest, profile, source_commit)
                verify(root, manifest)
                self.assertEqual(original_files, {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()})
                clone = t / (profile + "-copy")
                shutil.copytree(root, clone)
                other = t / (profile + "-copy.json")
                seal(clone, other, profile, source_commit)
                self.assertTrue(compare(root, manifest, clone, other)["equal"])
                # Independent one-byte negative control, not a different input identity.
                changed = clone / "romfs/hello.txt"
                changed.chmod(0o644)   # RomFS 共享存储整棵只读，copytree 跟随软链拷出的副本也带只读位
                changed.write_bytes(b"Original hello\n")
                with self.assertRaises(PreparedError):
                    verify(clone, other)
                other.unlink()
                seal(clone, other, profile, source_commit)
                delta = compare(root, manifest, clone, other)
                self.assertFalse(delta["equal"])
                print("ACTUAL CHECKPOINT:", profile, "widen=" + str(widen), "seal/verify/compare positive + one-byte negative passed", flush=True)
            run(dotnet, "build", str(ROOT / "tests/crosshost_stage/Producer.csproj"),
                "-c", "Release", "--artifacts-path", str(artifacts / "extract"), "-nologo", "-v", "q", "-m:1")
            adapter = t / "synthetic-unpack"
            adapter.write_text('#!/bin/bash\nexec "$DOTNET" "' + str(artifacts / "extract/bin/Producer/release/Producer.dll") + '" "$@"\n')
            adapter.chmod(0o755)
            source = t / "source"
            source.mkdir()
            original = fixture(widen=widen)
            (source / "original.nsp").write_text(json.dumps({k: base64.b64encode(v).decode() for k, v in original.items()}, sort_keys=True))
            out = t / "roots/fixture@seed"
            run("bash", str(ROOT / "pack/stages/unpack.sh"), "extract", "--src", str(source),
                "--out", str(out), "--nx-unpack", str(adapter), "--keys", str(t / "not-used"),
                "--ids", str(t / "ids.tsv"), "--title-id", "0100AAAA00000000")
            for name, expected in original.items():
                self.assertEqual((out / name).read_bytes(), expected, name)
            self.assertTrue((out / ".stage_unpack").is_file())
            checkpoint(out, "extract")
            (t / "roots/fixture@现行").symlink_to("fixture@seed")
            run("bash", str(ROOT / "pack/stage_rewrite.sh"), "fixture")
            current = (t / "roots/fixture@现行").resolve()
            gates = [line.split("\t") for line in (current / "main.gates.tsv").read_text().splitlines()]
            self.assertEqual([row[1:] for row in gates], [["svc", "1", "0x108"]])
            if widen:
                self.assertEqual((current / "main.widen.tsv").read_text(), "0\t0x100\tasp\t0x5291c728\n")
            else:
                self.assertFalse((current / "main.widen.tsv").exists())
            patched = (current / "main.patched.bin").read_bytes()
            self.assertEqual(struct.unpack_from("<I", patched, 0x108)[0] >> 26, 5)  # B to generated SVC gate
            self.assertEqual((current / "exefs/main").read_bytes(), original["exefs/main"])
            self.assertTrue((current / ".stage_rewrite").is_file())
            checkpoint(current, "rewrite")
            run("bash", str(ROOT / "pack/stages/romfsidx.sh"), "fixture")
            current = (t / "roots/fixture@现行").resolve()
            # This is a nonempty data-interval table, not the directory table.
            # Zero-length files remain in RomFS metadata and in the extracted tree.
            self.assertEqual(index_entries((current / "romfs.s2aidx").read_bytes()),
                             {"hello.txt": 15, "sub/data": 17})
            self.assertTrue((current / ".stage_romfsidx").is_file())
            checkpoint(current, "romfs-index")
            for name, expected in original.items():
                self.assertEqual((current / name).read_bytes(), expected, name)
            before = current
            run("bash", str(ROOT / "pack/stages/romfsidx.sh"), "fixture")
            self.assertEqual((t / "roots/fixture@现行").resolve(), before)
            print("REAL PRODUCERS: synthetic RomFS extraction adapter + rewrite + source-built index; NOT encrypted NCA or Mac comparison", flush=True)


if __name__ == "__main__":
    unittest.main()
