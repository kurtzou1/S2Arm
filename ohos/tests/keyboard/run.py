#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Run actual managed OHOS keyboard sources with a fake transport, offline."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dotnet", default="dotnet")
    parser.add_argument("--output", type=Path, required=True,
                        help="New evidence/build directory outside the source tree")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    repo = here.parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sources = [here / p for p in ("Program.cs", "TestBoundary.cs", "Keyboard.Tests.csproj", "NuGet.Config", "run.py")]
    sources += [repo / p for p in (
        "ohos/cs/OhosKeyboard.cs", "ohos/cs/OhosHostUi.cs", "services/S2A.Services/Red.cs",
        "compat/tree/src/Ryujinx.HLE/HOS/Applets/SoftwareKeyboard/SoftwareKeyboardUIArgs.cs",
        "compat/tree/src/Ryujinx.HLE/HOS/Applets/SoftwareKeyboard/KeyboardMode.cs",
        "compat/tree/src/Ryujinx.HLE/UI/IHostUIHandler.cs")]
    def hashes(paths):
        return [{"path": str(p), "bytes": p.stat().st_size,
                 "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in paths]
    manifest = {"invocation": sys.argv, "scope": "Windows managed CPU only; fake transport; no OHOS ABI/UI/device validation",
                "inputs_before": hashes(sources), "commands": []}
    env = dict(os.environ, DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_NOLOGO="1",
               DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1")
    def run(name, command):
        start = time.time()
        result = subprocess.run(command, cwd=here, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        (output / (name + ".stdout.txt")).write_bytes(result.stdout)
        (output / (name + ".stderr.txt")).write_bytes(result.stderr)
        manifest["commands"].append({"name": name, "argv": command, "cwd": str(here),
                                     "exit_code": result.returncode, "seconds": round(time.time() - start, 3)})
        print(name, "rc=", result.returncode, flush=True)
        print(result.stdout.decode("utf-8", errors="replace"), end="", flush=True)
        print(result.stderr.decode("utf-8", errors="replace"), end="", file=sys.stderr, flush=True)
        return result.returncode
    code = run("dotnet-version", [args.dotnet, "--version"])
    if code == 0:
        code = run("build", [args.dotnet, "build", str(here / "Keyboard.Tests.csproj"),
            "--configuration", "Release", "--output", str(output / "bin"),
            "--configfile", str(here / "NuGet.Config"), "--disable-build-servers",
            "-p:BaseIntermediateOutputPath=" + str(output / "obj") + os.sep,
            "-p:ImportDirectoryBuildProps=false", "-p:ImportDirectoryBuildTargets=false"])
    if code == 0:
        code = run("test", [args.dotnet, str(output / "bin" / "Keyboard.Tests.dll")])
    manifest["inputs_after"] = hashes(sources)
    manifest["inputs_unchanged"] = manifest["inputs_before"] == manifest["inputs_after"]
    manifest["exit_code"] = code
    artifacts = sorted(p for p in output.rglob("*") if p.is_file())
    manifest["artifacts"] = hashes(artifacts)
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
