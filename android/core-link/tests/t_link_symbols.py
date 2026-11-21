#!/usr/bin/env python3
"""Q19 / #530 link-symbol gate tests.

The production entry is android/core-link/link_symbols.py and is
wired into android/test.sh (which android/gate.sh runs).
These tests use small real project/source fixtures, not hand-maintained symbol
lists, so every case exercises the same C# closure and native definition
scanners as the gate.
"""

import importlib.util
import contextlib
import io
import json
import os
from unittest import mock
import shutil
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "android/core-link/link_symbols.py"


def load_module():
    spec = importlib.util.spec_from_file_location("s2a_link_symbols", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


LINK = load_module()
sys.path.insert(0, str(MODULE_PATH.parent))
game_spec = importlib.util.spec_from_file_location("s2a_game_core_closure", MODULE_PATH.parent / "test_game_core_closure.py")
GAME = importlib.util.module_from_spec(game_spec)
game_spec.loader.exec_module(GAME)
def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(text).lstrip(), encoding="utf-8")


def project(path, includes, references=()):
    lines = [
        '<Project Sdk="Microsoft.NET.Sdk">',
        "  <PropertyGroup>",
        "    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>",
        "  </PropertyGroup>",
        "  <ItemGroup>",
    ]
    for include in includes:
        lines.append('    <Compile Include="%s" />' % include)
    for reference in references:
        lines.append('    <ProjectReference Include="%s" />' % reference)
    lines.extend(["  </ItemGroup>", "</Project>"])
    write(path, "\n".join(lines) + "\n")


class Fixture:
    def __init__(self, temp):
        self.root = Path(temp)
        self.cs = self.root / "app"
        self.native = self.root / "native"
        self.cs.mkdir()
        self.native.mkdir()

    def shared(self, body):
        write(self.cs / "Shared.cs", body)
        return self.cs / "Shared.cs"

    def stub(self, body):
        write(self.native / "stub.c", body)
        return self.native / "stub.c"

    def add_project(self, name, includes, references=()):
        path = self.cs / name
        project(path, includes, references)
        return path

    def check(self, native_files=None):
        project_path = self.add_project("App.csproj", ["Shared.cs"])
        files = native_files if native_files is not None else [self.native / "stub.c"]
        return LINK.check_once(self.root, "diagnostic", [project_path], files, verbose=False, cmake="cmake")


class LinkSymbolTests(unittest.TestCase):
    def test_homebrew_ndk_candidates_and_redirected_home(self):
        required = {Path("/opt/homebrew/share/android-ndk"), Path("/usr/local/share/android-ndk")}
        with tempfile.TemporaryDirectory(prefix="s2a-homebrew-ndk-") as temp:
            root = Path(temp)
            fake = (root / "apple-silicon/android-ndk", root / "intel/android-ndk")
            with mock.patch.dict(os.environ, {"HOME": str(root / "empty-home")}, clear=True):
                self.assertTrue(required.issubset(set(LINK.ndk_candidates())))
            for index in range(2):
                with self.subTest(prefix=index, home="redirected" if index == 0 else "empty"):
                    ndk = fake[index]
                    ndk.mkdir(parents=True)
                    (ndk / "source.properties").write_text("Pkg.Revision = 29.0.14206865\n")
                    host = "darwin-x86_64" if sys.platform == "darwin" else "linux-x86_64"
                    tools = ndk / "toolchains/llvm/prebuilt" / host / "bin"
                    tools.mkdir(parents=True)
                    for name in ("aarch64-linux-android34-clang", "aarch64-linux-android34-clang++", "ld.lld", "llvm-nm"):
                        (tools / name).touch()
                    env = {"HOME": str(root / "empty-home") if index == 0 else ""}
                    with mock.patch.dict(os.environ, env, clear=True), \
                         mock.patch.object(LINK, "HOMEBREW_NDK_PATHS", fake, create=True), \
                         mock.patch.object(GAME.link_symbols, "HOMEBREW_NDK_PATHS", fake, create=True):
                        self.assertEqual(LINK.find_ndk(), ndk)
                        self.assertEqual(GAME.ndk_bin(), tools)
                        (ndk / "source.properties").write_text("Pkg.Revision = 28.2.13676358\n")
                        self.assertIsNone(LINK.find_ndk())
                        with self.assertRaises(RuntimeError) as caught:
                            GAME.ndk_bin()
                        message = str(caught.exception)
                        self.assertNotIn("\n", message)
                        self.assertIn(str(fake[0]), message)
                        self.assertIn(str(fake[1]), message)
                    shutil.rmtree(ndk)

    def test_q19_passes_resolved_ndk_to_offline_avc_builder(self):
        with tempfile.TemporaryDirectory(prefix="s2a-q19-ndk-") as temp:
            root = Path(temp)
            archive = root / "libs2a_avc.a"
            archive.touch()
            ndk = root / "homebrew/android-ndk"
            result = mock.Mock(returncode=0, stdout=str(archive) + "\n", stderr="")
            with mock.patch.dict(os.environ, {"HOME": str(root), "ANDROID_HOME": str(root / "stale-sdk")}, clear=True), \
                 mock.patch.object(LINK, "find_q19_cmake", return_value="/fixture/cmake"), \
                 mock.patch.object(LINK.subprocess, "run", return_value=result) as run:
                self.assertEqual(LINK.avc_probe_archive(root, ndk), str(archive.resolve()))
                self.assertEqual(run.call_args.kwargs["env"]["S2A_Q19_NDK"], str(ndk))
                self.assertEqual(run.call_args.kwargs["env"]["CMAKE"], "/fixture/cmake")
                self.assertEqual(run.call_args.kwargs["env"]["ANDROID_HOME"], str(root / "stale-sdk"))

    def test_q19_cmake_uses_path_then_sdk_and_rejects_missing(self):
        with tempfile.TemporaryDirectory(prefix="s2a-q19-cmake-") as temp:
            root = Path(temp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            path_cmake = bin_dir / "cmake"
            path_cmake.write_text('#!/bin/sh\necho "cmake version 4.4.4"\n')
            path_cmake.chmod(0o755)
            sdk_cmake = root / "sdk/cmake/3.31.6/bin/cmake"
            sdk_cmake.parent.mkdir(parents=True)
            sdk_cmake.write_text('#!/bin/sh\necho "cmake version 3.31.6-g38307f9"\n')
            sdk_cmake.chmod(0o755)
            brew = (root / "brew-missing/cmake", root / "intel-missing/cmake")
            env = {"HOME": str(root / "empty-home"), "PATH": str(bin_dir), "ANDROID_HOME": str(root / "sdk")}
            with mock.patch.dict(os.environ, env, clear=True), \
                 mock.patch.object(LINK, "HOMEBREW_CMAKE_PATHS", brew, create=True):
                self.assertEqual(LINK.find_q19_cmake(), str(path_cmake))
                self.assertEqual(LINK.find_q19_cmake(str(sdk_cmake)), str(sdk_cmake))
                path_cmake.write_text('#!/bin/sh\necho "cmake version 3.30.9"\n')
                self.assertEqual(LINK.find_q19_cmake(), str(sdk_cmake))
                sdk_cmake.unlink()
                brew[0].parent.mkdir(parents=True)
                brew[0].write_text('#!/bin/sh\necho "cmake version 3.31.7"\n')
                brew[0].chmod(0o755)
                self.assertEqual(LINK.find_q19_cmake(), str(brew[0]))
                brew[0].unlink()
                with self.assertRaises(LINK.CheckError) as caught:
                    LINK.find_q19_cmake()
                message = str(caught.exception)
                self.assertNotIn("\n", message)
                self.assertIn("3.31.6", message)
                self.assertIn(str(path_cmake), message)
                self.assertIn(str(sdk_cmake), message)
                self.assertIn(str(brew[0]), message)
                self.assertIn("brew install cmake", message)
                self.assertIn("sdkmanager 'cmake;3.31.6'", message)

    def test_game_ndk_resolution_uses_q19_candidate_order(self):
        with tempfile.TemporaryDirectory(prefix="s2a-ndk-candidates-") as temp:
            root = Path(temp)
            sdk = root / "SDK with spaces"
            good = sdk / "ndk/29.0.14206865"
            good.mkdir(parents=True)
            (good / "source.properties").write_text("Pkg.Revision = 29.0.14206865\n")
            host = "darwin-x86_64" if sys.platform == "darwin" else "linux-x86_64"
            tools = good / "toolchains/llvm/prebuilt" / host / "bin"
            tools.mkdir(parents=True)
            for name in ("aarch64-linux-android34-clang", "aarch64-linux-android34-clang++", "ld.lld", "llvm-nm"):
                (tools / name).touch()
            cases = (
                {"HOME": str(root), "ANDROID_NDK_HOME": str(root / "stale"), "ANDROID_HOME": str(sdk)},
                {"HOME": str(root), "ANDROID_HOME": str(root / "missing-sdk"), "ANDROID_SDK_ROOT": str(sdk)},
                {"HOME": "", "ANDROID_SDK_ROOT": str(sdk)},
            )
            for env in cases:
                with self.subTest(env=env), mock.patch.dict(os.environ, env, clear=True):
                    self.assertEqual(LINK.find_ndk(), good)
                    self.assertEqual(GAME.ndk_bin(), tools)

    def test_game_missing_ndk_reports_search_and_install_in_one_line(self):
        with tempfile.TemporaryDirectory(prefix="s2a-ndk-missing-") as temp:
            env = {"HOME": temp, "ANDROID_NDK_HOME": str(Path(temp) / "wrong ndk"),
                   "ANDROID_HOME": str(Path(temp) / "missing sdk")}
            with mock.patch.dict(os.environ, env, clear=True), \
                 mock.patch.object(GAME.link_symbols, "HOMEBREW_NDK_PATHS", (), create=True):
                with self.assertRaises(RuntimeError) as caught:
                    GAME.ndk_bin()
            message = str(caught.exception)
            self.assertNotIn("\n", message)
            self.assertIn("29.0.14206865", message)
            self.assertIn(env["ANDROID_NDK_HOME"], message)
            self.assertIn(str(Path(env["ANDROID_HOME"]) / "ndk/29.0.14206865"), message)
            self.assertIn("ANDROID_NDK_ROOT", message)
            self.assertIn("ANDROID_SDK_ROOT", message)
            self.assertIn("sdkmanager", message)

    def test_ndk_wrong_revision_and_missing_tools_are_not_accepted(self):
        with tempfile.TemporaryDirectory(prefix="s2a-ndk-revision-") as temp:
            root = Path(temp)
            wrong = root / "wrong"
            wrong.mkdir()
            (wrong / "source.properties").write_text("Pkg.Revision = 29.0.142068650\n")
            sdk = root / "sdk"
            correct = sdk / "ndk/29.0.14206865"
            correct.mkdir(parents=True)
            (correct / "source.properties").write_text("Pkg.Revision = 29.0.14206865\n")
            with mock.patch.dict(os.environ, {"HOME": temp, "ANDROID_NDK_HOME": str(wrong),
                                              "ANDROID_SDK_ROOT": str(sdk)}, clear=True):
                self.assertEqual(LINK.find_ndk(), correct)
                with self.assertRaisesRegex(RuntimeError, "missing .*aarch64-linux-android34-clang"):
                    GAME.ndk_bin()

    def test_production_touch_and_avc_bindings_are_wired_in_both_modes(self):
        # AndroidWindow and AvcH264Decoder (now under android/cs/video,
        # moved out of shared Nvdec for #1069) must both remain in the real
        # NativeAOT closure and in the single-library provider set.
        wanted = {
            "s2a_android_game_touch_viewport", "s2a_avc_create", "s2a_avc_decode",
            "s2a_avc_destroy", "s2a_avc_planes", "s2a_avc_provenance",
        }
        cache = {}
        project_path = ROOT / LINK.DEFAULT_CS_PROJECT
        for mode in ("diagnostic", "game"):
            with self.subTest(mode=mode):
                result = LINK.check_once(ROOT, mode, [project_path], cs_cache=cache)
                required = {item["symbol"] for item in result["required"]}
                defined = set(result["native_symbols"])
                self.assertFalse(wanted - required, "missing C# imports: " + str(sorted(wanted - required)))
                self.assertFalse(wanted - defined, "missing native definitions: " + str(sorted(wanted - defined)))
                self.assertFalse(wanted & {item["symbol"] for item in result["missing"]})

    def test_each_touch_and_avc_provider_removal_is_red(self):
        wanted = (
            "s2a_android_game_touch_viewport", "s2a_avc_create", "s2a_avc_decode",
            "s2a_avc_destroy", "s2a_avc_planes", "s2a_avc_provenance",
        )
        with tempfile.TemporaryDirectory(prefix="s2a-q19-touch-avc-") as temp:
            fixture = Fixture(temp)
            declarations = "\n".join(
                '[DllImport("s2arm_android")] static extern int %s();' % name for name in wanted
            )
            fixture.shared("using System.Runtime.InteropServices; static class Bindings {\n" + declarations + "\n}")
            touch = fixture.native / "touch.c"
            codec = fixture.root / "android/codecs/s2a_avc.c"
            write(touch, (ROOT / "android/native/game_touch.c").read_text())
            write(codec, (ROOT / "android/codecs/s2a_avc.c").read_text())
            self.assertEqual(fixture.check([touch])["missing"], [])
            for symbol in wanted:
                with self.subTest(symbol=symbol):
                    provider = touch if symbol.startswith("s2a_android_") else codec
                    original = provider.read_text()
                    mutant = original.replace(symbol + "(", "removed_" + symbol + "(", 1)
                    self.assertNotEqual(mutant, original)
                    provider.write_text(mutant)
                    self.assertIn(symbol, {item["symbol"] for item in fixture.check([touch])["missing"]})
                    provider.write_text(original)

    def test_green_when_stub_defines_entries(self):
        with tempfile.TemporaryDirectory(prefix="s2a-q19-") as temp:
            fixture = Fixture(temp)
            fixture.shared("""
                using System.Runtime.InteropServices;
                static class Bindings {
                    [DllImport("s2a_native")] static extern int s2a_handle_new();
                    [DllImport("s2a_native")] static extern int s2a_handle_close();
                }
            """)
            fixture.stub("""
                int s2a_handle_new(void) { return 0; }
                int s2a_handle_close(void) { return 0; }
            """)
            result = fixture.check()
            self.assertEqual(result["missing"], [])
            self.assertEqual(result["duplicates"], [])
            self.assertEqual({item["symbol"] for item in result["required"]},
                             {"s2a_handle_new", "s2a_handle_close"})

    def test_avc_archive_shim_is_checked_and_missing_is_red(self):
        with tempfile.TemporaryDirectory(prefix="s2a-q19-avc-") as temp:
            fixture = Fixture(temp)
            fixture.shared('using System.Runtime.InteropServices; static class Bindings { [DllImport("s2arm_android")] static extern int s2a_avc_create(); }')
            fixture.stub('int unrelated(void) { return 0; }')
            shim = fixture.root / 'android/codecs/s2a_avc.c'
            write(shim, 'int s2a_avc_create(void) { return 0; }')
            self.assertEqual(fixture.check()['missing'], [])
            shim.unlink()
            self.assertEqual([item['symbol'] for item in fixture.check()['missing']], ['s2a_avc_create'])

    def test_explicit_missing_avc_archive_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix="s2a-q19-archive-") as temp:
            with mock.patch.dict(os.environ, {"S2A_Q19_AVC_ARCHIVE": str(Path(temp) / "missing.a")}):
                with self.assertRaisesRegex(LINK.CheckError, "S2A_Q19_AVC_ARCHIVE"):
                    LINK.avc_probe_archive(Path(temp), Path(temp) / "ndk")

    def test_deleting_one_stub_definition_is_red(self):
        with tempfile.TemporaryDirectory(prefix="s2a-q19-") as temp:
            fixture = Fixture(temp)
            fixture.shared("""
                using System.Runtime.InteropServices;
                static class Bindings {
                    [DllImport("s2a_native")] static extern int s2a_handle_new();
                    [DllImport("s2a_native")] static extern int s2a_handle_close();
                }
            """)
            fixture.stub("int s2a_handle_new(void) { return 0; }\n")
            result = fixture.check()
            self.assertEqual([item["symbol"] for item in result["missing"]], ["s2a_handle_close"])
            self.assertTrue(result["missing"][0]["path"].endswith("Shared.cs"))
            self.assertGreater(result["missing"][0]["line"], 0)

    def test_new_shared_binding_without_definition_is_red(self):
        with tempfile.TemporaryDirectory(prefix="s2a-q19-") as temp:
            fixture = Fixture(temp)
            fixture.shared("""
                using System.Runtime.InteropServices;
                static class Bindings {
                    [DllImport("s2a_native")] static extern int s2a_handle_new();
                    [DllImport("s2a_native")] static extern int s2a_q19_fake();
                }
            """)
            fixture.stub("int s2a_handle_new(void) { return 0; }\n")
            result = fixture.check()
            self.assertEqual([item["symbol"] for item in result["missing"]], ["s2a_q19_fake"])

    def test_530_replay_alt_phase_and_gfx_mode(self):
        # The two bindings that broke main's Android link in #530. The stub is
        # the pre-#529 one: neither definition exists.
        with tempfile.TemporaryDirectory(prefix="s2a-q19-") as temp:
            fixture = Fixture(temp)
            fixture.shared("""
                using System.Runtime.InteropServices;
                static class Bindings {
                    [DllImport("s2a_native")] static extern int s2a_alt_phase();
                    [DllImport("s2a_native")] static extern int s2a_gfx_mode();
                    [DllImport("s2a_native")] static extern int s2a_handle_new();
                }
            """)
            fixture.stub("int s2a_handle_new(void) { return 0; }\n")
            result = fixture.check()
            self.assertEqual([item["symbol"] for item in result["missing"]],
                             ["s2a_alt_phase", "s2a_gfx_mode"])

    def test_entrypoint_rename_and_libraryimport(self):
        with tempfile.TemporaryDirectory(prefix="s2a-q19-") as temp:
            fixture = Fixture(temp)
            fixture.shared("""
                using System.Runtime.InteropServices;
                static partial class Bindings {
                    [DllImport("s2a_native", EntryPoint = "s2a_alt_phase")]
                    static extern int Phase();
                    [LibraryImport("s2arm_android", EntryPoint = "s2a_android_copy_asset")]
                    private static partial int CopyAsset(byte* name, byte* path);
                }
            """)
            fixture.stub("""
                int s2a_alt_phase(void) { return -1; }
                int s2a_android_copy_asset(void) { return 0; }
            """)
            result = fixture.check()
            self.assertEqual(result["missing"], [])
            self.assertEqual({item["symbol"] for item in result["required"]},
                             {"s2a_alt_phase", "s2a_android_copy_asset"})

    def test_missing_entrypoint_reports_native_name(self):
        with tempfile.TemporaryDirectory(prefix="s2a-q19-") as temp:
            fixture = Fixture(temp)
            fixture.shared("""
                using System.Runtime.InteropServices;
                static class Bindings {
                    [DllImport("s2a_native", EntryPoint = "s2a_alt_phase")]
                    static extern int Phase();
                }
            """)
            fixture.stub("int s2a_handle_new(void) { return 0; }\n")
            result = fixture.check()
            self.assertEqual([item["symbol"] for item in result["missing"]], ["s2a_alt_phase"])
            self.assertNotIn("Phase", {item["symbol"] for item in result["missing"]})

    def test_const_library_name(self):
        with tempfile.TemporaryDirectory(prefix="s2a-q19-") as temp:
            fixture = Fixture(temp)
            fixture.shared("""
                using System.Runtime.InteropServices;
                static class Bindings {
                    private const string Lib = "s2a_native";
                    [DllImport(Lib)] static extern int s2a_handle_new();
                }
            """)
            fixture.stub("int s2a_handle_new(void) { return 0; }\n")
            result = fixture.check()
            self.assertEqual(result["missing"], [])
            self.assertEqual({item["library"] for item in result["required"]}, {"s2a_native"})

    def test_conditional_definition_uses_android_defines(self):
        with tempfile.TemporaryDirectory(prefix="s2a-q19-") as temp:
            fixture = Fixture(temp)
            fixture.shared("""
                using System.Runtime.InteropServices;
                static class Bindings {
                    [DllImport("s2a_native")] static extern int s2a_android_only();
                }
            """)
            fixture.stub("""
                #if defined(__ANDROID__) && defined(__aarch64__)
                int s2a_android_only(void) { return 0; }
                #endif
            """)
            result = fixture.check()
            self.assertEqual(result["missing"], [])
            fixture.stub("""
                #if !defined(__ANDROID__)
                int s2a_android_only(void) { return 0; }
                #endif
            """)
            result = fixture.check()
            self.assertEqual([item["symbol"] for item in result["missing"]], ["s2a_android_only"])

    def test_directive_trailing_comment_is_not_condition(self):
        # A trailing // or /* */ comment on a directive is not part of the condition or the macro value;
        # string literals keep their "//". Expectations follow the C preprocessor under the Android defines.
        def active(src):
            return LINK.preprocess_active_lines(textwrap.dedent(src), LINK.Defines("native")).split()
        self.assertEqual(active("""
            #if !defined(__ANDROID__) /* apple only */
            A
            #endif
            #if !defined(__ANDROID__) // apple only
            B
            #endif
            #if defined(__ANDROID__) // android
            C
            #endif
            #if 1 // 0
            D
            #endif
            #define S2A_COMMENT_FLAG 0 // off
            #if S2A_COMMENT_FLAG
            E
            #endif
            #ifdef __ANDROID__ /* x */
            F
            #endif
        """), ["C", "D", "F"])
        defines = LINK.Defines("native")
        LINK.preprocess_active_lines('#define S2A_COMMENT_URL "http://x" // note\n', defines)
        self.assertEqual(defines.get("S2A_COMMENT_URL"), '"http://x"')

    def test_platform_only_types_are_still_android_requirements(self):
        # #530 option (a): no per-platform exclusion. An Apple-only type compiled into the
        # Android C#, and a type only it references, still need every import defined.
        with tempfile.TemporaryDirectory(prefix="s2a-q19-") as temp:
            fixture = Fixture(temp)
            fixture.shared("""
                using System.Runtime.InteropServices;
                static class Bindings {
                    [DllImport("s2a_native")] static extern int s2a_handle_new();
                }
            """)
            write(fixture.cs / "Apple.cs", """
                using System.Runtime.InteropServices;
                using System.Runtime.Versioning;
                [SupportedOSPlatform("ios")]
                static class AppleSession {
                    [DllImport("s2a_native")] static extern int s2a_apple_only();
                    static AppleDiag _diag;
                }
            """)
            write(fixture.cs / "AppleDiag.cs", """
                using System.Runtime.InteropServices;
                static class AppleDiag {
                    [DllImport("s2a_native")] static extern int s2a_apple_diag();
                }
            """)
            fixture.add_project("App.csproj", ["Shared.cs", "Apple.cs", "AppleDiag.cs"])
            check = lambda: LINK.check_once(
                fixture.root, "diagnostic",
                [fixture.cs / "App.csproj"], [fixture.native / "stub.c"],
                verbose=False, cmake="cmake")
            fixture.stub("int s2a_handle_new(void) { return 0; }\n")
            self.assertEqual(sorted(item["symbol"] for item in check()["missing"]),
                             ["s2a_apple_diag", "s2a_apple_only"])
            fixture.stub("int s2a_handle_new(void) { return 0; }\n"
                         "int s2a_apple_only(void) { return 0; }\n"
                         "int s2a_apple_diag(void) { return 0; }\n")
            self.assertEqual(check()["missing"], [])

    def test_duplicate_strong_definition_is_red(self):
        with tempfile.TemporaryDirectory(prefix="s2a-q19-") as temp:
            fixture = Fixture(temp)
            fixture.shared("""
                using System.Runtime.InteropServices;
                static class Bindings {
                    [DllImport("s2a_native")] static extern int s2a_dup();
                }
            """)
            fixture.stub("int s2a_dup(void) { return 0; }\n")
            other = fixture.native / "other.c"
            write(other, "int s2a_dup(void) { return 1; }\n")
            result = fixture.check([fixture.native / "stub.c", other])
            self.assertEqual(len(result["duplicates"]), 1)
            self.assertEqual(result["duplicates"][0]["symbol"], "s2a_dup")

    def test_project_reference_closure_is_scanned(self):
        with tempfile.TemporaryDirectory(prefix="s2a-q19-") as temp:
            fixture = Fixture(temp)
            fixture.root.joinpath("lib").mkdir()
            write(fixture.root / "lib/Lib.cs", """
                using System.Runtime.InteropServices;
                static class LibBindings {
                    [DllImport("s2a_native")] static extern int s2a_from_lib();
                }
            """)
            write(fixture.root / "lib/Lib.csproj", """
                <Project Sdk="Microsoft.NET.Sdk">
                  <PropertyGroup><EnableDefaultCompileItems>true</EnableDefaultCompileItems></PropertyGroup>
                </Project>
            """)
            fixture.shared("// no bindings here\n")
            fixture.add_project("App.csproj", ["Shared.cs"], ["../lib/Lib.csproj"])
            fixture.stub("")
            result = LINK.check_once(
                fixture.root, "diagnostic",
                [fixture.cs / "App.csproj"], [fixture.native / "stub.c"],
                verbose=False, cmake="cmake")
            self.assertEqual([item["symbol"] for item in result["missing"]], ["s2a_from_lib"])

    def test_one_failed_mode_is_never_reported_as_complete_link(self):
        def result(_root, mode, *_args):
            return {"mode": mode, "required": [], "cs_exports": [], "native_symbols": [],
                    "missing": [], "duplicates": []}
        def link(_root, mode, *_args):
            if mode == "game":
                raise LINK.CheckError("fixture game link failed")
            return {"attempted": True, "result": "pass"}
        with tempfile.TemporaryDirectory(prefix="s2a-q19-summary-") as temp:
            report = Path(temp) / "report.json"
            output = io.StringIO()
            with mock.patch.object(LINK, "check_once", side_effect=result), \
                 mock.patch.object(LINK, "print_findings", return_value=False), \
                 mock.patch.object(LINK, "find_ndk", return_value=Path(temp)), \
                 mock.patch.object(LINK, "link_probe", side_effect=link), \
                 contextlib.redirect_stdout(output):
                rc = LINK.main(["--root", temp, "--report", str(report)])
            self.assertEqual(rc, 1)
            self.assertIn("game", output.getvalue())
            self.assertNotIn("真实链接：libs2arm_android.so", output.getvalue())
            data = json.loads(report.read_text())
            self.assertNotEqual(data["scope"], "link-probe")
            self.assertEqual(data["link"]["game"]["result"], "fail")

    def test_missing_libavc_is_one_red_line_and_never_a_complete_link(self):
        def result(_root, mode, *_args):
            return {"mode": mode, "required": [], "cs_exports": [], "native_symbols": [],
                    "missing": [], "duplicates": []}
        with tempfile.TemporaryDirectory(prefix="s2a-q19-missing-avc-") as temp:
            report = Path(temp) / "report.json"
            output = io.StringIO()
            with mock.patch.object(LINK, "check_once", side_effect=result), \
                 mock.patch.object(LINK, "print_findings", return_value=False), \
                 mock.patch.object(LINK, "find_ndk", return_value=Path(temp)), \
                 mock.patch.object(LINK, "link_probe", side_effect=LINK.CheckError("libavc missing\nprepare sources")) as probe, \
                 contextlib.redirect_stdout(output):
                rc = LINK.main(["--root", temp, "--report", str(report)])
            self.assertEqual(rc, 1)
            red = [line for line in output.getvalue().splitlines() if "【红】" in line]
            self.assertEqual(len(red), 1)
            self.assertIn("libavc missing prepare sources", red[0])
            self.assertEqual(probe.call_count, 1)
            data = json.loads(report.read_text())
            self.assertNotEqual(data["scope"], "link-probe")
            self.assertEqual(data["link"]["diagnostic"]["result"], "fail")
            self.assertNotIn("真实链接：libs2arm_android.so", output.getvalue())

    def test_all_requested_link_modes_pass_before_success_summary(self):
        def result(_root, mode, *_args):
            return {"mode": mode, "required": [], "cs_exports": [], "native_symbols": [],
                    "missing": [], "duplicates": []}
        with tempfile.TemporaryDirectory(prefix="s2a-q19-summary-") as temp:
            report = Path(temp) / "report.json"
            output = io.StringIO()
            with mock.patch.object(LINK, "check_once", side_effect=result), \
                 mock.patch.object(LINK, "print_findings", return_value=False), \
                 mock.patch.object(LINK, "find_ndk", return_value=Path(temp)), \
                 mock.patch.object(LINK, "link_probe", return_value={"attempted": True, "result": "pass"}), \
                 contextlib.redirect_stdout(output):
                rc = LINK.main(["--root", temp, "--report", str(report)])
            self.assertEqual(rc, 0)
            self.assertIn("diagnostic/game", output.getvalue())
            self.assertEqual(json.loads(report.read_text())["scope"], "link-probe")

    def test_current_tree_is_green_in_both_modes(self):
        cmake = shutil.which("cmake")
        self.assertIsNotNone(cmake, "cmake is required by the Android gate")
        cache = {}
        for mode in ("diagnostic", "game"):
            result = LINK.check_once(
                ROOT, mode,
                [ROOT / "android/cs/aot/S2A.Android.Aot.csproj"],
                None, verbose=False, cmake=cmake, cs_cache=cache)
            self.assertEqual(result["missing"], [], "%s: %s" % (mode, result["missing"]))
            self.assertEqual(result["duplicates"], [], mode)
            self.assertGreater(len(result["required"]), 40, mode)
            symbols = {item["symbol"] for item in result["required"]}
            self.assertIn("s2a_alt_phase", symbols)
            self.assertIn("s2a_gfx_mode", symbols)
            self.assertIn("s2a_guest_frozen", symbols)
            definitions = LINK.collect_definitions(
                [ROOT / path for path in result["native_files"]], mode, ROOT)
            frozen_owners = {LINK.rel(ROOT, definition["path"]) for definition in definitions
                             if definition["symbol"] == "s2a_guest_frozen" and not definition["static"]}
            expected_owner = ("android/native/s2a_native_stub.c" if mode == "diagnostic"
                              else "runtime/src/thread.c")
            self.assertEqual(frozen_owners, {expected_owner}, mode)
            # Apple audio is absent from the Android composition; no substitute stubs.
            self.assertNotIn("s2a_hud_audio", symbols, mode)
            self.assertNotIn("s2a_dump_threads", symbols, mode)
            self.assertNotIn("android/native/apple_audio_stub.c", result["native_files"], mode)


if __name__ == "__main__":
    unittest.main(verbosity=2)
