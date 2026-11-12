#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Compile the production Metal.Compile method unchanged with fake cache/compiler boundaries.

Only the surrounding dependencies are replaced. The hash wrapper still uses BCL
SHA-256 and counts completed hash computations. No game, Metal compiler or network is required.
Set DOTNET to a preinstalled .NET 10 SDK; this test never installs dependencies.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[4]
source = (ROOT / 'graphics/tools/direct/dsh/batch/Build.cs').read_text(encoding='utf-8')
signature = '    public static byte[] Compile(string target, string msl, string name, out string key)'
assert source.count(signature) == 1, 'Metal.Compile signature must be unique'
start = source.index(signature)
brace = source.index('{', start)
# 此方法的插值文本花括号均成对；截取后还由 C# 编译器验证完整语法。
depth = 0
for pos in range(brace, len(source)):
    depth += (source[pos] == '{') - (source[pos] == '}')
    if depth == 0:
        end = pos + 1
        break
else:
    raise AssertionError('Metal.Compile has no balanced closing brace')
assert source[end:].lstrip().startswith('// 编不过的一句'), 'unexpected method boundary'
method = source[start:end]
dotnet = os.environ.get('DOTNET') or shutil.which('dotnet')
if not dotnet:
    sys.exit('需要预先安装 .NET 10 SDK（DOTNET）；本测试不下载工具。')

HARNESS = r'''
using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using IncrementalHash = CountedHash;

sealed class CountedHash : IDisposable {
    public static int Count;
    readonly System.Security.Cryptography.IncrementalHash hash;
    CountedHash(HashAlgorithmName name) { hash = System.Security.Cryptography.IncrementalHash.CreateHash(name); }
    public static CountedHash CreateHash(HashAlgorithmName name) => new(name);
    public void AppendData(byte[] b) => hash.AppendData(b);
    public byte[] GetHashAndReset() { Count++; return hash.GetHashAndReset(); }
    public void Dispose() => hash.Dispose();
}
static class Store {
    public static Dictionary<string, Dictionary<string, byte[]>> Entries = new();
    public static List<string> Reads = new();
    public static Dictionary<string, byte[]> Get(string key) { Reads.Add(key); return Entries.GetValueOrDefault(key); }
    public static void Put(string key, Dictionary<string, byte[]> value) => Entries[key] = value;
}
sealed class CompileError : Exception { public CompileError(string m) : base(m) {} }
static class Metal {
    public static readonly Dictionary<string, (string[] Cmd, string Sdk, byte[] Ident)> T = new() {
        ["mac"] = (new[] {"metal"}, "fake-sdk", Encoding.UTF8.GetBytes("synthetic-compiler")) };
    public static string Work;
    static SemaphoreSlim Gate = new(1);
    public static readonly ConcurrentDictionary<string, long> St = new();
    static readonly ConcurrentBag<(double S, string Target, int Bytes)> Times = new();
    static readonly ConcurrentDictionary<string, string[]> Pch = new();
    const int PchTrip = 8;
    public static byte[] Output = new byte[] {1, 2, 3};
    public static int CompilerCalls;
    static IEnumerable<string> Native(string[] cmd) => cmd;
    static string[] Tool(string sdk, params string[] cmd) => cmd;
    static (int, string) Exec(string[] args) {
        CompilerCalls++;
        string file = args[Array.IndexOf(args, "-o") + 1];
        File.WriteAllBytes(file, file.EndsWith(".metallib") ? Output : new byte[] {0});
        return (0, "");
    }
    static string EnvProblem() => null;
    static string DiskFull(string s) => null;
    static string OpenFail(string s) => null;
    static string CompilerWhy(string s) => s;
    static string Trunc(string s, int n) => s;
    static void Note(string s) {}
__METHOD__
}
static class TestProgram {
    static int failures;
    static void Check(bool ok, string label) {
        Console.WriteLine((ok ? "PASS " : "FAIL ") + label);
        if (!ok) failures++;
    }
    static string Expected(string name = null) {
        var mid = name == null ? new byte[] {0} : Encoding.UTF8.GetBytes("\0" + name + "\0");
        return "mtl/mac/" + Convert.ToHexString(SHA256.HashData(
            Encoding.UTF8.GetBytes("synthetic-compiler").Concat(mid).Concat(Encoding.UTF8.GetBytes("synthetic MSL")).ToArray())).ToLowerInvariant();
    }
    static byte[] Compile(string name, out string key) {
        CountedHash.Count = 0; Store.Reads.Clear();
        return Metal.Compile("mac", "synthetic MSL", name, out key);
    }
    public static int Main(string[] args) {
        Metal.Work = args[0];
        byte[] cold = Compile("plain", out var sourceKey);
        Check(sourceKey == Expected() && Metal.CompilerCalls == 2 && CountedHash.Count == 2, "cold source-independent library key/compiler/hash count");
        Store.Entries.Clear();
        Store.Put(Expected(), new() { ["lib"] = new byte[] {1, 2, 3} });
        byte[] hot = Compile("different-name", out var hotKey);
        Check(CountedHash.Count == 1, "source hit uses one full-source hash");
        Check(Store.Reads.SequenceEqual(new[] {sourceKey}), "source hit reads only source key");
        Check(hot.SequenceEqual(cold) && hotKey == sourceKey && Metal.CompilerCalls == 2, "source hit preserves bytes/key and avoids compiler");
        Check(Metal.St["mac reused"] == 1 && Metal.St["mac compiled"] == 1, "cache statistics preserved");
        Store.Entries.Clear();
        Metal.Output = Encoding.UTF8.GetBytes("synthetic global constructor: ctor.metal");
        byte[] named = Compile("ctor", out var namedKey);
        Check(namedKey == Expected("ctor") && CountedHash.Count == 2, "filename-sensitive cold library stored under named key");
        Store.Entries.Clear();
        Store.Put(Expected("ctor"), new() { ["lib"] = Encoding.UTF8.GetBytes("synthetic global constructor: ctor.metal") });
        int before = Metal.CompilerCalls;
        byte[] namedHot = Compile("ctor", out var namedHotKey);
        Check(CountedHash.Count == 2 && Store.Reads.SequenceEqual(new[] {Expected(), Expected("ctor")}), "named hit keeps source-then-name lookup order");
        Check(namedHot.SequenceEqual(named) && namedHotKey == namedKey && Metal.CompilerCalls == before, "named hit preserves bytes/key and avoids compiler");
        Metal.Output = Encoding.UTF8.GetBytes("synthetic global constructor: 另一名称.metal");
        byte[] other = Compile("另一名称", out var otherKey);
        Check(Metal.CompilerCalls == before + 2 && otherKey == Expected("另一名称") && !other.SequenceEqual(named), "other filename cannot reuse named library");
        return failures == 0 ? 0 : 1;
    }
}
'''

with tempfile.TemporaryDirectory(prefix='metal-cache-test-') as d:
    root = Path(d)
    (root / 'Program.cs').write_text(HARNESS.replace('__METHOD__', method), encoding='utf-8')
    (root / 'test.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>'
        '<OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework>'
        '<Nullable>disable</Nullable></PropertyGroup></Project>')
    config = root / 'NuGet.Config'
    config.write_text('<configuration><packageSources><clear /></packageSources></configuration>')
    env = dict(os.environ, DOTNET_CLI_HOME=str(root / 'dotnet-home'), DOTNET_CLI_TELEMETRY_OPTOUT='1',
               DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1')
    for command in [[dotnet, 'restore', str(root / 'test.csproj'), '--configfile', str(config), '-v', 'q'],
                    [dotnet, 'build', str(root / 'test.csproj'), '--no-restore', '-v', 'q',
                     '-p:UseSharedCompilation=false', '-nodeReuse:false']]:
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        if result.returncode:
            print(result.stdout + result.stderr)
            sys.exit(result.returncode)
    work = root / 'work'
    work.mkdir()
    sys.exit(subprocess.run([dotnet, str(root / 'bin/Debug/net10.0/test.dll'), str(work)], env=env).returncode)
