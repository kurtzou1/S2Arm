#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Compile and exercise the production GetPresentCount routing offline."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
RUNTIME = HERE.parent / "AndroidGameRuntime.cs"
METHOD_START = "        public static long GetPresentCount()"
METHOD_END = '\n        [UnmanagedCallersOnly(EntryPoint = "s2a_android_services_request_applet_exit")]'
NVN_BRANCH = "            if (_directSession != null) return unchecked((long)s2a_android_nvn_present_count());\n"
EXPECTED_NVN_FAILURE = "FAIL NVN session reads NVN source: expected 11, got 33"

HARNESS = r'''using System;

internal sealed class PresentCounterStub
{
    public long Count;
}

internal static class Program
{
    private static object _directSession;
    private static bool _direct;
    private static readonly PresentCounterStub PresentCounter = new();
    private static ulong _nvnValue;
    private static ulong _vulkanValue;

    private static ulong s2a_android_nvn_present_count() => _nvnValue;
    private static ulong s2a_android_vk_present_count() => _vulkanValue;

METHOD

    private static bool Expect(string label, long expected)
    {
        long actual = GetPresentCount();
        if (actual != expected)
        {
            Console.Error.WriteLine($"FAIL {label}: expected {expected}, got {actual}");
            return false;
        }
        Console.WriteLine("PASS " + label);
        return true;
    }

    public static int Main()
    {
        _directSession = new object();
        _direct = false;
        _nvnValue = 11;
        _vulkanValue = 22;
        PresentCounter.Count = 33;
        if (!Expect("NVN session reads NVN source", 11)) return 1;
        _nvnValue = 12;
        if (!Expect("NVN value follows source changes", 12)) return 1;
        _direct = true;
        _nvnValue = 13;
        if (!Expect("NVN session outranks Vulkan-direct", 13)) return 1;

        _directSession = null;
        _direct = true;
        if (!Expect("Vulkan-direct reads Vulkan source", 22)) return 1;
        _vulkanValue = 23;
        if (!Expect("Vulkan value follows source changes", 23)) return 1;

        _direct = false;
        if (!Expect("legacy path reads PresentCounter", 33)) return 1;
        PresentCounter.Count = 34;
        if (!Expect("legacy value follows source changes", 34)) return 1;
        return 0;
    }
}
'''

PROJECT = '''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>disable</ImplicitUsings>
    <Nullable>disable</Nullable>
    <InvariantGlobalization>true</InvariantGlobalization>
    <JsonSerializerIsReflectionEnabledByDefault>false</JsonSerializerIsReflectionEnabledByDefault>
  </PropertyGroup>
</Project>
'''
NUGET_CONFIG = '<configuration><packageSources><clear /></packageSources></configuration>\n'


def extract_method(source, source_name):
    if source.count(METHOD_START) != 1:
        raise ValueError(f"{source_name}: GetPresentCount declaration boundary must occur exactly once")
    if source.count(METHOD_END) != 1:
        raise ValueError(f"{source_name}: next-method boundary must occur exactly once")
    start = source.index(METHOD_START)
    end = source.index(METHOD_END)
    if end <= start:
        raise ValueError(f"{source_name}: GetPresentCount boundary order changed")
    method = source[start:end].rstrip()
    if method.count("{") != method.count("}"):
        raise ValueError(f"{source_name}: GetPresentCount braces are unbalanced")
    return method


def compile_and_run(dotnet, directory, method):
    directory.mkdir(parents=True, exist_ok=False)
    (directory / "Program.cs").write_text(HARNESS.replace("METHOD", method), encoding="utf-8")
    project = directory / "Proof.csproj"
    config = directory / "NuGet.Config"
    project.write_text(PROJECT, encoding="utf-8")
    config.write_text(NUGET_CONFIG, encoding="utf-8")
    env = os.environ.copy()
    env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
    env["DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE"] = "1"
    restore = [str(dotnet), "restore", str(project), "--configfile", str(config), "--verbosity", "quiet", "-p:NuGetAudit=false"]
    restored = subprocess.run(restore, capture_output=True, text=True, timeout=90, env=env)
    if restored.returncode:
        return restore, restored.stdout + restored.stderr, restored.returncode, None
    build = [str(dotnet), "build", str(project), "--no-restore", "--disable-build-servers", "--verbosity", "quiet"]
    built = subprocess.run(build, capture_output=True, text=True, timeout=90, env=env)
    if built.returncode:
        return build, built.stdout + built.stderr, built.returncode, None
    command = [str(dotnet), str(directory / "bin/Debug/net10.0/Proof.dll")]
    run = subprocess.run(command, capture_output=True, text=True, timeout=30, env=env)
    return command, run.stdout + run.stderr, run.returncode, built.stdout + built.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dotnet", default=shutil.which("dotnet") or "dotnet", help="dotnet executable (default: PATH)")
    parser.add_argument("--output", type=Path, help="new directory for isolated builds and results; defaults to a temporary directory")
    parser.add_argument("--source-ref", "--source", dest="source_ref", type=Path, help="baseline AndroidGameRuntime.cs source file for an expected red proof (no Git required)")
    args = parser.parse_args()
    production = extract_method(RUNTIME.read_text(encoding="utf-8"), str(RUNTIME))
    if production.count(NVN_BRANCH) != 1:
        raise SystemExit("production GetPresentCount must contain exactly one NVN routing branch for the negative control")
    mutated = production.replace(NVN_BRANCH, "", 1)
    source_ref = None
    if args.source_ref is not None:
        source_ref = args.source_ref.resolve()
        if not source_ref.is_file():
            raise SystemExit(f"--source/--source-ref must name an existing AndroidGameRuntime.cs source file: {source_ref}")
        source_ref_method = extract_method(source_ref.read_text(encoding="utf-8"), str(source_ref))

    temporary = tempfile.TemporaryDirectory(prefix="s2a-present-source-") if args.output is None else None
    out = args.output.resolve() if args.output is not None else Path(temporary.name) / "out"
    out.mkdir(parents=True, exist_ok=False)
    cases = [("production", production, None), ("remove-nvn-branch", mutated, EXPECTED_NVN_FAILURE)]
    if source_ref is not None:
        cases.append(("source-ref-red", source_ref_method, EXPECTED_NVN_FAILURE))
    results = []
    hashes = {str(RUNTIME.relative_to(ROOT)): hashlib.sha256(RUNTIME.read_bytes()).hexdigest()}
    if source_ref is not None:
        hashes[str(source_ref)] = hashlib.sha256(source_ref.read_bytes()).hexdigest()
    (out / "sources.json").write_text(json.dumps(hashes, indent=2) + "\n", encoding="utf-8")
    for name, method, expected_failure in cases:
        command, output, exit_code, build_output = compile_and_run(args.dotnet, out / name, method)
        if build_output is None:
            passed = False
            reason = "compile/restore failed; this is not an accepted negative-control result"
        elif expected_failure is None:
            passed = exit_code == 0 and "PASS legacy value follows source changes" in output
            reason = None if passed else "production routing must pass all source-selection assertions"
        else:
            passed = exit_code != 0 and expected_failure in output
            reason = None if passed else f"expected runtime assertion failure, not a compile failure: {expected_failure}"
        results.append({"name": name, "command": command, "exit": exit_code, "expectedFailure": expected_failure, "passed": passed, "output": output})
        (out / "results.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
        print(name, "PASS" if passed else "FAIL")
        if not passed:
            if build_output is None:
                print(output, end="")
            else:
                print(reason)
                print(output, end="")
            raise SystemExit(1)
    if temporary is not None:
        temporary.cleanup()


if __name__ == "__main__":
    main()
