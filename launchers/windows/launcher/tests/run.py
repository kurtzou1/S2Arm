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
        # 出包页打开哪一款（玩家反馈：A 在出包时点 B 的出包进的是 A 的页面；UI.Snapshots/BuildRouteProbe.cs）
        with tempfile.TemporaryDirectory(prefix="s2arm-build-route-probe-") as temporary:
            out = run([dotnet, "run", "--project", str(probe), "--no-build", "--configuration", "Release", "--",
                       "--build-route-probe", str(Path(temporary) / "out"), "--data-root=" + str(Path(temporary) / "data")], env)
            if "✓ 出包页打开哪一款" not in out.stdout:
                raise RuntimeError("build route probe did not report success")
        # 控制口 /dismiss（s2armctl dismiss）关得掉新功能大窗 / 更新弹窗（UI.Snapshots/DismissProbe.cs）
        with tempfile.TemporaryDirectory(prefix="s2arm-dismiss-probe-") as temporary:
            out = run([dotnet, "run", "--project", str(probe), "--no-build", "--configuration", "Release", "--",
                       "--dismiss-probe", str(Path(temporary) / "out"), "--data-root=" + str(Path(temporary) / "data")], env)
            if "✓ 控制口 dismiss 关弹窗" not in out.stdout:
                raise RuntimeError("dismiss probe did not report success")
        # 装机前清单按钮落点（11-19 落点契约，同 Mac：action 唯一来源、POST /install-action、state.presented；UI.Snapshots/InstallActionProbe.cs）
        with tempfile.TemporaryDirectory(prefix="s2arm-install-action-probe-") as temporary:
            out = run([dotnet, "run", "--project", str(probe), "--no-build", "--configuration", "Release", "--",
                       "--install-action-probe", str(Path(temporary) / "out"), "--data-root=" + str(Path(temporary) / "data")], env)
            if "✓ 装机前清单按钮落点" not in out.stdout:
                raise RuntimeError("install action probe did not report success")
        # 装机卡片「详细过程」点开后不被进度事件刷新收起（D-237B；UI.Snapshots/DetailsProbe.cs）
        with tempfile.TemporaryDirectory(prefix="s2arm-details-probe-") as temporary:
            out = run([dotnet, "run", "--project", str(probe), "--no-build", "--configuration", "Release", "--",
                       "--details-probe", str(Path(temporary) / "out"), "--data-root=" + str(Path(temporary) / "data")], env)
            if "✓ 装机卡片详细过程点开后不被进度刷新收起" not in out.stdout:
                raise RuntimeError("details probe did not report success")
        # 首位 S2Arm 总控台窄窗 / 英文不被裁、页顶不写长编号（0.6.2 前端走查；UI.Snapshots/ConsoleProbe.cs）
        with tempfile.TemporaryDirectory(prefix="s2arm-console-probe-") as temporary:
            out = run([dotnet, "run", "--project", str(probe), "--no-build", "--configuration", "Release", "--",
                       "--console-probe", str(Path(temporary) / "out"), "--data-root=" + str(Path(temporary) / "data")], env)
            if "✓ 总控台窄窗 / 英文不裁、页顶不写长编号、出法没读回不先画错" not in out.stdout:
                raise RuntimeError("console probe did not report success")
        # 游戏库「更新 / 导出」两件事（0.6.4 改版：大卡三态、导出确认页设备行与默认不勾、开始后起的单、逐台结果；UI.Snapshots/UpdateExportProbe.cs）
        with tempfile.TemporaryDirectory(prefix="s2arm-update-export-probe-") as temporary:
            out = run([dotnet, "run", "--project", str(probe), "--no-build", "--configuration", "Release", "--",
                       "--update-export-probe", str(Path(temporary) / "out"), "--data-root=" + str(Path(temporary) / "data")], env)
            if "✓ 更新 / 导出两件事" not in out.stdout:
                raise RuntimeError("update/export probe did not report success")
        # D-97FT：坏封面只让那一格用占位图；设置框没画出来时环境检查路径不变空（UI.Snapshots/CoverProbe.cs）
        with tempfile.TemporaryDirectory(prefix="s2arm-cover-probe-") as temporary:
            out = run([dotnet, "run", "--project", str(probe), "--no-build", "--configuration", "Release", "--",
                       "--cover-probe", str(Path(temporary) / "out"), "--data-root=" + str(Path(temporary) / "data")], env)
            if "✓ 坏封面与没画出的设置框" not in out.stdout:
                raise RuntimeError("cover probe did not report success")
        # #2191：出包客户端抛 catch 列表之外的异常，收尾照样先撤作业登记、按钮不永远灰（UI.Snapshots/EndJobProbe.cs）
        with tempfile.TemporaryDirectory(prefix="s2arm-endjob-probe-") as temporary:
            out = run([dotnet, "run", "--project", str(probe), "--no-build", "--configuration", "Release", "--",
                       "--endjob-probe", str(Path(temporary) / "out"), "--data-root=" + str(Path(temporary) / "data")], env)
            if "✓ 出包异常收尾撤登记" not in out.stdout:
                raise RuntimeError("endjob probe did not report success")
        # 推游戏遇到手机上旧 App（#1842）：phone_app_outdated 走通用确认「仍然继续」、不兼容的不是确认码（UI.Snapshots/ConfirmProbe.cs）
        with tempfile.TemporaryDirectory(prefix="s2arm-confirm-probe-") as temporary:
            out = run([dotnet, "run", "--project", str(probe), "--no-build", "--configuration", "Release", "--",
                       "--confirm-probe", str(Path(temporary) / "out"), "--data-root=" + str(Path(temporary) / "data")], env)
            if "✓ 推游戏遇到旧 App 的确认页" not in out.stdout:
                raise RuntimeError("confirm probe did not report success")
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
