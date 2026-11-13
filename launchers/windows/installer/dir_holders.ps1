# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
#
# 哪些进程占着一个目录（安装程序开装前用：S2Arm.iss PrepareToInstall 解到临时目录调它）。
# 本文件存成带 BOM 的 UTF-8：PowerShell 5 读无 BOM 的脚本按系统代码页（中文 Windows 是 GBK），中文会把字符串读断。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File dir_holders.ps1 -Dir <目录> [-Kill <pid,pid>] [-Out <文件>]
#   不带 -Kill：列出占着 <目录> 的进程。
#   带 -Kill：对这些进程号做 taskkill /F /T，再查一遍，列出仍占着的进程；退出码 0 = 都关掉了，1 = 还有关不掉的。
#   输出：默认往标准输出写一行 JSON 数组 [{"pid":123,"exe":"C:\\...\\x.exe","name":"显示名"}]，没有就是 []。
#         给了 -Out 就把同样内容按行写进文件（带 BOM 的 UTF-8，每行 pid<TAB>name<TAB>exe），给安装程序的 Pascal 脚本读。
#
# 怎么算「占着」（两路取并集）：
#   1. 进程的 exe 本身在 <目录> 下（Win32_Process.ExecutablePath，不分大小写）：S2Arm、Impactor、签名工具都在这一路。
#   2. 重启管理器（Restart Manager，RmGetList）报出开着 <目录> 下 exe / dll 的进程：exe 在别处、但加载了这里的库的进程。
#   查不到的两类，调用方遇到「没查到但还是换不动」要照实说（例如「还有程序占着这个文件夹，可能是开着它的窗口」）：
#     工作目录在 <目录> 里的进程（cd 进去的命令行窗口）、开着这个文件夹的资源管理器窗口。
# 永不列出、永不结束调用方自己和它的父进程（调起本脚本的安装程序）。
param(
    [Parameter(Mandatory = $true)][string]$Dir,
    [string]$Kill = "",
    [string]$Out = ""
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8   # PowerShell 5 缺省走系统代码页，exe 路径里有中文会乱

$root = [System.IO.Path]::GetFullPath($Dir).TrimEnd('\') + '\'
$self = $PID
$parent = 0
try { $parent = [int](Get-CimInstance Win32_Process -Filter "ProcessId = $self").ParentProcessId } catch { }
$skip = @($self, $parent)

function Under([string]$path) {
    return $path -and $path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
}

$rmSource = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class S2ArmRm {
    [StructLayout(LayoutKind.Sequential)] struct FILETIME { public uint Low, High; }
    [StructLayout(LayoutKind.Sequential)] struct RM_UNIQUE_PROCESS { public int dwProcessId; public FILETIME ProcessStartTime; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
        public int ApplicationType; public uint AppStatus; public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmStartSession(out uint h, int flags, string key);
    [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint h);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmRegisterResources(uint h, uint nFiles, string[] files, uint nApps, IntPtr apps, uint nSvc, string[] svcs);
    [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint h, out uint needed, ref uint count, [In, Out] RM_PROCESS_INFO[] info, ref uint reasons);
    public static int[] Holders(string[] files) {
        var pids = new List<int>();
        uint h; if (RmStartSession(out h, 0, Guid.NewGuid().ToString()) != 0) return pids.ToArray();
        try {
            if (RmRegisterResources(h, (uint)files.Length, files, 0, IntPtr.Zero, 0, null) != 0) return pids.ToArray();
            uint needed = 0, count = 0, reasons = 0;
            int rc = RmGetList(h, out needed, ref count, null, ref reasons);
            if (rc == 234 && needed > 0) {   // ERROR_MORE_DATA
                var info = new RM_PROCESS_INFO[needed]; count = needed;
                if (RmGetList(h, out needed, ref count, info, ref reasons) == 0)
                    for (int i = 0; i < count; i++) pids.Add(info[i].Process.dwProcessId);
            }
        } finally { RmEndSession(h); }
        return pids.ToArray();
    }
}
"@

function Holders {
    $found = @{}
    foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, Name, ExecutablePath) {
        if ($skip -contains [int]$p.ProcessId) { continue }
        if (Under $p.ExecutablePath) { $found[[int]$p.ProcessId] = $p }
    }
    # 第二路：重启管理器。查不了（目录不存在、类型编译失败）就只用第一路，不当错误
    try {
        if (Test-Path -LiteralPath $root) {
            $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include *.exe, *.dll -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            if ($files.Count -gt 0) {
                if (-not ("S2ArmRm" -as [type])) { Add-Type -TypeDefinition $rmSource -Language CSharp }
                foreach ($id in [S2ArmRm]::Holders($files)) {
                    if ($skip -contains $id -or $found.ContainsKey($id)) { continue }
                    $p = Get-CimInstance Win32_Process -Filter "ProcessId = $id" -Property ProcessId, Name, ExecutablePath
                    if ($p) { $found[$id] = $p }
                }
            }
        }
    } catch { }
    return @($found.Values | Sort-Object ProcessId | ForEach-Object {
        $name = $_.Name
        try { $d = (Get-Item -LiteralPath $_.ExecutablePath).VersionInfo.FileDescription; if ($d) { $name = $d } } catch { }
        [ordered]@{ pid = [int]$_.ProcessId; exe = [string]$_.ExecutablePath; name = [string]$name }
    })
}

if ($Kill) {
    $killed = @()
    foreach ($id in ($Kill -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })) {
        if ($skip -contains $id) { continue }
        & "$env:SystemRoot\System32\taskkill.exe" /F /T /PID $id *> $null
        $killed += $id
    }
    # 等被结束的进程真正退出再复查（最多 15 秒）：taskkill 返回时进程常还没退干净，原先固定等 1.5 秒，Windows 实机实测复查仍列出刚结束的 S2Arm、报「没能关掉」
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and @($killed | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count -gt 0) { Start-Sleep -Milliseconds 250 }
}

$list = Holders
if ($Out) {
    $lines = @($list | ForEach-Object { "{0}`t{1}`t{2}" -f $_.pid, $_.name, $_.exe })
    [System.IO.File]::WriteAllLines($Out, [string[]]$lines, (New-Object System.Text.UTF8Encoding $true))
} else {
    if ($list.Count -eq 0) { [Console]::Out.WriteLine("[]") }
    else { [Console]::Out.WriteLine((ConvertTo-Json -InputObject @($list) -Compress -Depth 3)) }
}
if ($Kill -and $list.Count -gt 0) { exit 1 }
exit 0
