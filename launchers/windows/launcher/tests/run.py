#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Offline host gate. Dependencies must already exist in the caller's NuGet cache."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent


def run(args, env, *, ok=True):
    result = subprocess.run(args, env=env, cwd=ROOT, text=True, encoding="utf-8",
                            errors="replace", stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=180)
    print(result.stdout, end="", flush=True)
    if ok and result.returncode:
        raise RuntimeError(f"host command exited {result.returncode}")
    return result


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser()
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    dotnet = os.environ.get("S2A_DOTNET") or shutil.which("dotnet")
    if not dotnet:
        print("missing .NET 10 SDK; prepare dependencies before the offline gate", file=sys.stderr)
        return 75
    env = dict(os.environ, DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_NOLOGO="1")
    if os.name == "nt":
        env["S2A_TEST_PYTHON"] = sys.executable
        env["S2A_TEST_ENGINE"] = str(ROOT.parents[2])
    cache = Path(env.get("NUGET_PACKAGES", str(Path.home() / ".nuget/packages")))
    cache.mkdir(parents=True, exist_ok=True)
    projects = [HERE / "../Protocol.Tests/Protocol.Tests.csproj", HERE / "../App/S2Arm.csproj"]
    try:
        for project in projects:
            # A local-only source plus disabled network audit makes gate restoration offline.
            restore = run([dotnet, "restore", str(project), "--source", str(cache),
                           "-p:NuGetAudit=false", "--disable-parallel"], env, ok=False)
            if restore.returncode:
                print("OFFLINE DEPENDENCIES NOT READY: run a normal restore before the gate", file=sys.stderr)
                return 75
            run([dotnet, "build", str(project), "--no-restore", "--disable-build-servers",
                 "-p:UseSharedCompilation=false", "--configuration", "Release", "--verbosity", "minimal"], env)
        run([dotnet, "run", "--project", str(projects[0]), "--no-build", "--configuration", "Release"], env)
        # 引导页点设置键（玩家反馈闪退：没连库时读证书 → 渲染 → 再读的无限递归、栈溢出）：无头窗口按真实点击路径点一次，
        #   栈溢出抓不住、进程直接退出，所以核退出码 0 + 末行「✓」（UI.Snapshots/SettingsProbe.cs）
        probe = HERE / "../UI.Snapshots/UI.Snapshots.csproj"
        if run([dotnet, "restore", str(probe), "--source", str(cache), "-p:NuGetAudit=false", "--disable-parallel"], env, ok=False).returncode:
            print("OFFLINE DEPENDENCIES NOT READY: run a normal restore before the gate", file=sys.stderr)
            return 75
        run([dotnet, "build", str(probe), "--no-restore", "--disable-build-servers",
             "-p:UseSharedCompilation=false", "--configuration", "Release", "--verbosity", "minimal"], env)
        with tempfile.TemporaryDirectory(prefix="s2arm-settings-probe-") as temporary:
            out = run([dotnet, "run", "--project", str(probe), "--no-build", "--configuration", "Release", "--",
                       "--settings-probe", str(Path(temporary) / "out"), "--data-root=" + str(Path(temporary) / "data")], env)
            if "✓ 引导状态下点设置键" not in out.stdout:
                raise RuntimeError("settings probe did not report success")
        # 顶栏「故障报修」（11-13）：各页 / 各引导状态下顶栏最右都有这个键（UI.Snapshots/ReportProbe.cs）
        with tempfile.TemporaryDirectory(prefix="s2arm-report-probe-") as temporary:
            out = run([dotnet, "run", "--project", str(probe), "--no-build", "--configuration", "Release", "--",
                       "--report-probe", str(Path(temporary) / "out"), "--data-root=" + str(Path(temporary) / "data")], env)
            if "✓ 各页顶栏故障报修键" not in out.stdout:
                raise RuntimeError("report probe did not report success")
        if args.negative_controls:
            with tempfile.TemporaryDirectory(prefix="s2arm-ui-negative-") as temporary:
                target = Path(temporary).resolve()
                for folder in ("Protocol", "Protocol.Tests"):
                    shutil.copytree(ROOT / folder, target / folder,
                                    ignore=shutil.ignore_patterns("bin", "obj"))
                source = target / "Protocol/EnvironmentReport.cs"
                text = source.read_text(encoding="utf-8")
                needle = "public bool HasAction => !string.IsNullOrWhiteSpace(Action);"
                if text.count(needle) != 1:
                    raise RuntimeError("negative-control target not found exactly once")
                source.write_text(text.replace(needle, "public bool HasAction => true;"), encoding="utf-8")
                project = target / "Protocol.Tests/Protocol.Tests.csproj"
                run([dotnet, "restore", str(project), "--source", str(cache), "-p:NuGetAudit=false"], env)
                negative = run([dotnet, "run", "--project", str(project), "--no-restore",
                                "--disable-build-servers", "-p:UseSharedCompilation=false"], env, ok=False)
                if negative.returncode == 0 or "ok has no action" not in negative.stdout:
                    raise RuntimeError("negative control did not fail at its expected assertion")
                print("negative HasAction always visible: RED (ok has no action)")
                needle = "var url = OfficialUrl(item);"
                if text.count(needle) != 1:
                    raise RuntimeError("official URL negative-control target not found exactly once")
                source.write_text(text.replace(needle, "Uri? url = null;"), encoding="utf-8")
                negative = run([dotnet, "run", "--project", str(project), "--no-restore",
                                "--disable-build-servers", "-p:UseSharedCompilation=false"], env, ok=False)
                if negative.returncode == 0 or "backend official URL retained separately" not in negative.stdout:
                    raise RuntimeError("official URL negative control did not fail at its expected assertion")
                print("negative official URL discarded: RED (backend official URL retained separately)")
                if os.name == "nt":
                    source.write_text(text, encoding="utf-8")
                    probe = target / "Protocol/EnvironmentProbe.cs"
                    probe_text = probe.read_text(encoding="utf-8")
                    needle = "shell = Path.GetFullPath(paths.Shell)"
                    if probe_text.count(needle) != 1:
                        raise RuntimeError("shell request negative-control target not found exactly once")
                    probe.write_text(probe_text.replace(needle, 'shell = ""'), encoding="utf-8")
                    negative = run([dotnet, "run", "--project", str(project), "--no-restore",
                                    "--disable-build-servers", "-p:UseSharedCompilation=false"], env, ok=False)
                    if negative.returncode == 0 or "configured shell reaches backend" not in negative.stdout:
                        raise RuntimeError("shell request negative control did not fail at its expected assertion")
                    print("negative configured shell discarded: RED (configured shell reaches backend)")
                    needle = 'Path.Combine(paths.Engine, "Binaries", "Prepare")'
                    if probe_text.count(needle) != 1:
                        raise RuntimeError("engine layout negative-control target not found exactly once")
                    probe.write_text(probe_text.replace(needle, 'Path.Combine(AppContext.BaseDirectory, "Binaries", "Prepare")'), encoding="utf-8")
                    negative = run([dotnet, "run", "--project", str(project), "--no-restore",
                                    "--disable-build-servers", "-p:UseSharedCompilation=false"], env, ok=False)
                    if negative.returncode == 0 or "selected Engine snapshot owns prepared tools" not in negative.stdout:
                        raise RuntimeError("engine layout negative control did not fail at its expected assertion")
                    print("negative tools outside Engine: RED (selected Engine snapshot owns prepared tools)")
                    probe.write_text(probe_text, encoding="utf-8")
                source.write_text(text, encoding="utf-8")
                shared = target / "Protocol/SharedText.cs"
                shared_text = shared.read_text(encoding="utf-8")
                needle = "ReadLauncher(launcher);"
                if shared_text.count(needle) != 1:
                    raise RuntimeError("launcher items negative-control target not found exactly once")
                shared.write_text(shared_text.replace(needle, 'Flatten(launcher, "");'), encoding="utf-8")
                negative = run([dotnet, "run", "--project", str(project), "--no-restore",
                                "--disable-build-servers", "-p:UseSharedCompilation=false"], env, ok=False)
                if negative.returncode == 0 or "shared Chinese text" not in negative.stdout:
                    raise RuntimeError("launcher items negative control did not fail at its expected assertion")
                print("negative launcher items treated as nested text: RED (shared Chinese text)")
                shared.write_text(shared_text, encoding="utf-8")
                for relative, before, after, expected in (
                    ("Protocol/LibraryJobResult.cs", 'if (exitCode != (result.State', 'if (exitCode == int.MinValue && exitCode != (result.State', "successful result cannot hide failed process exit"),
                    ("Protocol/PrivateJobRequest.cs", '(rule.FileSystemRights & readers) != 0', '(rule.FileSystemRights & readers) == 0', "accepted public inherited request access"),
                    ("Protocol/PrivateJobRequest.cs", 'using var file = CreateWindowsFile(path);', 'using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);', "request owns protected DACL from creation"),
                    ("Protocol/LibraryJobClient.cs", 'payload["paths"] = selectedPaths;', 'payload["paths"] = Array.Empty<string>();', "original paths reach job request"),
                    ("Protocol/LibraryJobResult.cs", 'return new(Path.GetFullPath(folder), id);', 'if (!Guid.TryParse(id, out _)) throw new LibraryProtocolException("UUID-only id"); return new(Path.GetFullPath(folder), id);', "backend library id is opaque"),
                ):
                    if ("PrivateJobRequest" in relative or "LibraryJobClient" in relative) and os.name != "nt":
                        print("Windows library negative control: NOT RUN (requires Windows)")
                        continue
                    source = target / relative
                    original = source.read_text(encoding="utf-8")
                    if original.count(before) != 1:
                        raise RuntimeError("library negative-control target not found exactly once: " + relative)
                    source.write_text(original.replace(before, after), encoding="utf-8")
                    negative = run([dotnet, "run", "--project", str(project), "--no-restore",
                                    "--disable-build-servers", "-p:UseSharedCompilation=false"], env, ok=False)
                    if negative.returncode == 0 or expected not in negative.stdout:
                        raise RuntimeError("library negative control missed expected assertion: " + relative)
                    print("negative " + relative + ": RED (" + expected + ")")
                    source.write_text(original, encoding="utf-8")

        print("launcher host gate: PASS; actual Windows UI/publish and device acceptance are separate")
        return 0
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
