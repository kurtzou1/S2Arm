#!/usr/bin/env python3
"""macOS real-loader regression tests. Outputs stay outside the checkout."""

import argparse
import os
from pathlib import Path
import platform
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--packages", type=Path, default=Path.home() / ".nuget/packages")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("this fixture validates the macOS loader; it is not an Android run")
    root = Path(__file__).resolve().parents[3]
    output = args.out.resolve()
    if output == root or root in output.parents:
        parser.error("--out must be outside the source checkout")
    output.mkdir(parents=True, exist_ok=True)
    project = Path(__file__).with_name("ProviderOwner.Tests.csproj")
    env = dict(os.environ)
    env.update(
        DOTNET_CLI_HOME=str(output / "dotnet-home"),
        DOTNET_CLI_TELEMETRY_OPTOUT="1",
        DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1",
        DOTNET_GENERATE_ASPNET_CERTIFICATE="false",
    )
    config = output / "NuGet.Config"
    config.write_text("<configuration><packageSources><clear /></packageSources></configuration>\n")
    artifacts = output / "artifacts"
    commands = []

    def run(command, name, cwd=root):
        commands.append({"argv": [str(x) for x in command], "cwd": str(cwd)})
        result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True)
        (output / f"{name}.log").write_text(result.stdout + result.stderr)
        # 通过的场景里打出的【红】是按设计的（缺导出场景 Red.Report「原生层没有 s2a_…」）：包进负对照标记，门禁红步摘要不收（11-23）；
        #   场景失败时原样打，失败细节照进摘要
        ok = result.returncode == 0
        print("【负对照开始】" if ok else "", end="\n" if ok else "")
        print(result.stdout, end="")
        print(result.stderr, end="")
        print("【负对照结束】" if ok else "", end="\n" if ok else "")
        result.check_returncode()

    variants = {
        "full": [],
        "sentinel": ["-DPROVIDER_VALUE=987654321u"],
        "empty": ["-DNO_EXTRAS"],
        "half-mode": ["-DNO_DET_WRITE"],
        "half-write": ["-DNO_DET_MODE"],
    }
    for name, defines in variants.items():
        folder = output / name
        folder.mkdir(exist_ok=True)
        run(
            ["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-dynamiclib",
             "-I" + str(root / "runtime/include"), *defines,
             str(project.with_name("provider.c")), "-o", str(folder / "libs2arm_android.so")],
            "compile-" + name,
        )
    run(
        ["dotnet", "restore", str(project), "--configfile", str(config),
         "--artifacts-path", str(artifacts), "-p:RestorePackagesPath=" + str(args.packages),
         "-p:NuGetAudit=false"],
        "restore",
    )
    run(
        ["dotnet", "build", str(project), "-c", "Release", "--no-restore",
         "--artifacts-path", str(artifacts)],
        "build",
    )
    cases = {
        "consumer-local": ("full", None),
        "consumer-sentinel": ("full", "sentinel"),
        "consumer-empty": ("empty", "full"),
        "consumer-half-mode": ("half-mode", "full"),
        "consumer-half-write": ("half-write", "full"),
        "consumer-repeat": ("full", None),
        "consumer-other-owner": ("full", "sentinel"),
        "legacy-full": ("full", None),
        "legacy-empty": ("empty", "full"),
        "legacy-half-mode": ("half-mode", "full"),
        "legacy-half-write": ("half-write", "full"),
    }
    dll = artifacts / "bin/ProviderOwner.Tests/release/ProviderOwner.Tests.dll"
    for name, (owner, other) in cases.items():
        command = ["dotnet", str(dll), name, str(output / owner / "libs2arm_android.so")]
        if other:
            command.append(str(output / other / "libs2arm_android.so"))
        # macOS resolves the product's bare DSO name in this isolated directory.
        # The test still uses real dlopen and NativeLibrary.Load, without a hook.
        run(command, name, cwd=output / owner)
    import json
    (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    print(f"PASS {len(cases)} isolated processes; no Android/NativeAOT/game claims")


if __name__ == "__main__":
    main()
