#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Compile the production Ticker; verify phase records preserve legacy MB progress."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[4]
source = (ROOT / 'graphics/tools/direct/dsh/batch/Build.cs').read_text(encoding='utf-8')
start = source.index('sealed class Ticker')
brace = source.index('{', start)
depth = 0
for pos in range(brace, len(source)):
    depth += (source[pos] == '{') - (source[pos] == '}')
    if depth == 0:
        ticker = source[start:pos + 1]
        break
else:
    raise AssertionError('unbalanced production Ticker')
# Ticker 写活动行用的具名 record + 源码生成上下文在 DshActivity.cs（dsh_batch 是 NativeAOT 单文件，不能反射序列化）：一并编进来，
#   去掉它自己的 using（下面 PROGRAM 头上统一给），类型声明原样
activity = ''.join(l for l in (ROOT / 'graphics/tools/direct/dsh/batch/DshActivity.cs').read_text(encoding='utf-8').splitlines(True)
                   if not l.startswith('using '))

PROGRAM = r'''
using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Text.Json;
using System.Text.Json.Serialization;
static class Build { internal static int Jobs = 5; }
__TICKER__
__ACTIVITY__
static class Program {
    static int failures;
    static string path;
    static void Check(bool ok, string label) {
        Console.WriteLine((ok ? "PASS " : "FAIL ") + label); if (!ok) failures++;
    }
    static JsonElement? Last() {
        var line = File.ReadAllLines(path).LastOrDefault(x => x.StartsWith("#dsh_activity\t"));
        return line == null ? null : JsonDocument.Parse(line.Split('\t', 2)[1]).RootElement.Clone();
    }
    static void Dispose(object ticker) => (ticker as IDisposable)?.Dispose();
    public static int Main(string[] args) {
        path = Path.Combine(args[0], "progress.tsv"); Environment.SetEnvironmentVariable("S2A_PROGRESS", path);
        var ticker = new Ticker("直连库·编批库（MB）", 100);
        var data = Last();
        Check(data is { } d && d.GetProperty("schema").GetInt32() == 1 && d.GetProperty("pid").GetInt32() == Environment.ProcessId
            && d.GetProperty("target").GetInt32() == 5 && d.GetProperty("pool").GetInt32() == 10 && d.GetProperty("state").GetString() == "active",
            "producer reports phase owner, target 5 and preparation pool 10");
        Check(data is { } a && !a.TryGetProperty("inFlight", out _), "configured pool is not reported as measured compiler count");
        var rows = File.ReadAllLines(path);
        Check(rows.Where(x => !x.StartsWith("#")).Single().Split('\t').SequenceEqual(new[] {rows[0].Split('\t')[0], "直连库·编批库（MB）", "0", "100"}),
            "legacy four-column source MB row is unchanged");
        Check(rows.Where(x => x.StartsWith("#")).Any() && rows.Where(x => x.StartsWith("#")).All(x => x.Split('\t').Length == 2),
            "optional metadata has two columns for old reader compatibility");
        long idle = new FileInfo(path).Length; Thread.Sleep(1100);
        Check(new FileInfo(path).Length == idle, "idle build writes no periodic heartbeat to watchdog input");
        ticker.Step(100);
        Check(File.ReadAllLines(path).Where(x => !x.StartsWith("#")).Last().Split('\t')[2] == "100", "completed work still advances source MB");
        Dispose(ticker); long ended = new FileInfo(path).Length;
        Check(Last() is { } end && end.GetProperty("state").GetString() == "ended", "dispose publishes phase end");
        ticker.Step(); Dispose(ticker);
        Check(new FileInfo(path).Length == ended, "disposed phase emits no more progress or duplicate end");
        foreach (bool cancel in new[] {false, true}) {
            var current = new Ticker("直连库·翻译与收尾", 100);
            try { if (cancel) throw new OperationCanceledException(); throw new IOException("synthetic phase failure"); }
            catch (Exception error) when (error is IOException || error is OperationCanceledException) { }
            finally { Dispose(current); }
            Check(Last() is { } e && e.GetProperty("state").GetString() == "ended", (cancel ? "cancellation" : "exception") + " ends phase lifetime");
        }
        File.WriteAllText(path, "");
        var cached = new Ticker("直连库·编批库（MB）", 0);
        Check(Last() is { } c && c.GetProperty("state").GetString() == "active" && File.ReadAllLines(path).All(x => x.StartsWith("#")),
            "cache-only phase has activity without invented MB denominator");
        Dispose(cached);
        Check(__OWNED_SCOPES__, "all four production phases (translate, unity, _se, _vp) use disposable Ticker scopes");
        Environment.SetEnvironmentVariable("S2A_PROGRESS", args[0]);
        var unwritable = new Ticker("直连库·编批库（MB）", 0); Dispose(unwritable);
        Check(true, "optional metadata failure does not turn a cache-only compile into failure");
        return failures == 0 ? 0 : 1;
    }
}
'''

dotnet = os.environ.get('DOTNET') or shutil.which('dotnet')
if not dotnet:
    sys.exit('需要预先安装 .NET 10 SDK（DOTNET）；本测试不下载工具。')
with tempfile.TemporaryDirectory(prefix='dsh-activity-test-') as directory:
    root = Path(directory)
    program = PROGRAM.replace('__TICKER__', ticker).replace('__ACTIVITY__', activity).replace('__OWNED_SCOPES__', str(source.count('using var tk = new Ticker(') == 4).lower())
    (root / 'Program.cs').write_text(program, encoding='utf-8')
    (root / 'test.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType>'
        '<TargetFramework>net10.0</TargetFramework><Nullable>disable</Nullable></PropertyGroup></Project>')
    config = root / 'NuGet.Config'
    config.write_text('<configuration><packageSources><clear /></packageSources></configuration>')
    env = dict(os.environ, DOTNET_CLI_HOME=str(root / 'dotnet-home'), DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1')
    for command in [[dotnet, 'restore', str(root / 'test.csproj'), '--configfile', str(config), '-v', 'q'],
                    [dotnet, 'build', str(root / 'test.csproj'), '--no-restore', '-v', 'q', '-p:UseSharedCompilation=false', '-nodeReuse:false']]:
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        if result.returncode:
            print(result.stdout + result.stderr); sys.exit(result.returncode)
    sys.exit(subprocess.run([dotnet, str(root / 'bin/Debug/net10.0/test.dll'), str(root)], env=env).returncode)
