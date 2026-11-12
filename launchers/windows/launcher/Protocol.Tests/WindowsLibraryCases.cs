// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using S2Arm.Launcher.Protocol;

internal static class WindowsLibraryCases
{
    public static async Task Run(Action<bool, string> check)
    {
        if (OperatingSystem.IsWindows()) await RunWindows(check);
    }

    // 平台守卫放在单独的方法上：lambda 里的 ACL 调用分析器认不出外层的 IsWindows 守卫
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static async Task RunWindows(Action<bool, string> check)
    {
        var temp = Path.GetFullPath(Path.GetTempPath());
        var root = Path.Combine(temp, "s2arm-private-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var privateRoot = Path.Combine(root, "Private");
            string file;
            using (var request = PrivateJobRequest.Create(privateRoot, "{\"schema\":1}"))
            {
                file = request.FilePath;
                check(File.ReadAllText(file) == "{\"schema\":1}", "private request content round trips");
                check(new FileInfo(file).GetAccessControl().AreAccessRulesProtected, "request owns protected DACL from creation");
            }
            check(!File.Exists(file), "private request deleted after use");
            var weak = Path.Combine(root, "Weak");
            var acl = new DirectorySecurity();
            var sid = WindowsIdentity.GetCurrent().User!;
            acl.SetOwner(sid); acl.SetAccessRuleProtection(true, false);
            acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.ReadData,
                InheritanceFlags.ObjectInherit, PropagationFlags.InheritOnly, AccessControlType.Allow));
            new DirectoryInfo(weak).Create(acl);
            // #672：别的身份的权限就地去掉（当前账户是属主、有改权限的权利），不再拒绝；Everyone 那条规则必须没了才算修好
            var everyone = new SecurityIdentifier(WellKnownSidType.WorldSid, null);
            using (var healedWeak = PrivateJobRequest.Create(weak, "{}"))
                check(File.Exists(healedWeak.FilePath), "private root granting Everyone is healed and accepts a request");
            check(!new DirectoryInfo(weak).GetAccessControl().GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>()
                .Any(r => r.IdentityReference.Equals(everyone)), "healed private root no longer grants Everyone");
            // #672：属主是别的身份（玩家曾以管理员身份运行 → 属主 Administrators 组）。夹具要能把属主设成 Administrators：只有管理员会话做得到，普通会话跳过并写明
            var foreign = Path.Combine(root, "Foreign");
            Directory.CreateDirectory(foreign);
            var admins = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            var fixtureOk = true;
            try { var o = new DirectorySecurity(); o.SetOwner(admins); new DirectoryInfo(foreign).SetAccessControl(o); }
            catch (Exception e) when (e is UnauthorizedAccessException or InvalidOperationException) { fixtureOk = false; Console.WriteLine("skip foreign-owner case: this session cannot set owner to Administrators"); }
            if (fixtureOk)
            {
                check(admins.Equals(new DirectoryInfo(foreign).GetAccessControl().GetOwner(typeof(SecurityIdentifier))), "fixture: private root owned by Administrators");
                using (var taken = PrivateJobRequest.Create(foreign, "{}"))
                    check(File.Exists(taken.FilePath), "private root owned by Administrators is taken over and accepts a request");
                check(sid.Equals(new DirectoryInfo(foreign).GetAccessControl().GetOwner(typeof(SecurityIdentifier))), "taken-over private root is owned by the current user");
            }
            // 修不了时的话点名目录（玩家要知道删哪个）
            check(PrivateJobRequest.Describe("owner", @"C:\X\private").Contains(@"C:\X\private"), "unrecoverable private root message names the folder");
            check(PrivateJobRequest.Warning is null, "healthy private roots leave no warning");
            // #754：收不紧（当前账户没有改权限的权利）不再抛、照常建请求，只留一句 Warning。夹具：属主是本人，但 OWNER RIGHTS 一条只给「修改」（读写建删，
            //   不含改权限 / 取得所有权）——属主就不再隐含改权限的权利；再给 Everyone 读。管理员远程会话带着已启用的还原 / 取得所有权特权，
            //   会绕过权限检查把它收紧（实测如此），所以这一项在关掉全部特权的模拟令牌里跑，等同玩家的普通会话
            var stuck = Path.Combine(root, "Stuck");
            {
                var stuckAcl = new DirectorySecurity();
                stuckAcl.SetOwner(sid); stuckAcl.SetAccessRuleProtection(true, false);
                stuckAcl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-3-4"),
                    FileSystemRights.Modify | FileSystemRights.DeleteSubdirectoriesAndFiles,
                    InheritanceFlags.None, PropagationFlags.None, AccessControlType.Allow));
                stuckAcl.AddAccessRule(new FileSystemAccessRule(everyone, FileSystemRights.ReadData,
                    InheritanceFlags.None, PropagationFlags.None, AccessControlType.Allow));
                new DirectoryInfo(stuck).Create(stuckAcl);
            }
            WithoutPrivileges(() =>
            {
                using var stuckRequest = PrivateJobRequest.Create(stuck, "{}");
                check(File.Exists(stuckRequest.FilePath), "private root that cannot be tightened still accepts a request");
            });
            check(PrivateJobRequest.Warning is { } stuckWarning && stuckWarning.Contains(stuck), $"untightenable private root leaves a warning naming the folder: {PrivateJobRequest.Warning}");
            check(new DirectoryInfo(stuck).GetAccessControl().GetAccessRules(true, false, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>()
                .Any(r => r.IdentityReference.Equals(everyone)), "fixture: Everyone could not be removed");
            // 重解析点：玩家用目录联接把数据目录挪到别的盘——指向本人自己的目录照常用；链接断了 / 指向不归本人的位置才拒，话里点名目录
            var movedTarget = Path.Combine(root, "MovedTarget");
            Directory.CreateDirectory(movedTarget);   // 临时目录下新建：属主本人或本人有完全控制
            var junction = Path.Combine(root, "Junction");
            Junction(junction, movedTarget);
            check((new DirectoryInfo(junction).Attributes & FileAttributes.ReparsePoint) != 0, "fixture: junction is a reparse point");
            using (var viaJunction = PrivateJobRequest.Create(junction, "{}"))
                check(File.Exists(Path.Combine(movedTarget, Path.GetFileName(viaJunction.FilePath))), "private root junctioned to the user's own folder is used and writes into the target");
            var dangling = Path.Combine(root, "Dangling");
            var gone = Path.Combine(root, "Gone");
            Directory.CreateDirectory(gone);
            Junction(dangling, gone);
            Directory.Delete(gone);
            string? refused = null;
            try { using var _ = PrivateJobRequest.Create(dangling, "{}"); } catch (IOException e) { refused = e.Message; }
            check(refused is not null && refused.Contains(dangling), $"broken junction private root is refused naming the folder: {refused}");
            // #580：私有目录被 Directory.CreateDirectory 先建出来（继承临时目录的权限：本人 / SYSTEM / Administrators），原先永远报 inherits permissions
            var inherited = Path.Combine(root, "Inherited");
            Directory.CreateDirectory(Path.Combine(inherited, "jobs"));
            {   // 玩家机上普通用户建的目录属主就是本人；管理员会话里缺省属主是 Administrators 组，夹具改回本人，只留「继承」这一个问题。
                //   只写属主这一节（新建的描述符只设了 Owner）：取回整套再写回会顺带把权限改成不继承，夹具就不像玩家的目录了
                var own = new DirectorySecurity();
                own.SetOwner(sid);
                new DirectoryInfo(inherited).SetAccessControl(own);
            }
            check(!new DirectoryInfo(inherited).GetAccessControl().AreAccessRulesProtected, "fixture: directory starts with inherited DACL");
            check(sid.Equals(new DirectoryInfo(inherited).GetAccessControl().GetOwner(typeof(SecurityIdentifier))), "fixture: directory owned by the current user");
            using (var healed = PrivateJobRequest.Create(inherited, "{}"))
                check(File.Exists(healed.FilePath), "inherited-only private root is healed and accepts a request");
            var after = new DirectoryInfo(inherited).GetAccessControl();
            check(after.AreAccessRulesProtected, "healed private root no longer inherits");
            check(after.GetAccessRules(true, false, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>()
                .Any(r => r.IdentityReference.Equals(sid) && r.AccessControlType == AccessControlType.Allow && (r.FileSystemRights & FileSystemRights.FullControl) == FileSystemRights.FullControl),
                "healed private root keeps the current user's full control as an explicit rule");
            var engine = Path.Combine(root, "中文 & %S2A_MARKER% !", "Engine");
            var runtime = Path.Combine(root, "Runtime");
            Directory.CreateDirectory(Path.Combine(engine, "pack", "jobs"));
            Directory.CreateDirectory(runtime);
            var python = Environment.GetEnvironmentVariable("S2A_TEST_PYTHON")!;
            await File.WriteAllTextAsync(Path.Combine(runtime, "s2arm_env.cmd"),
                "@echo off\r\nset \"PATH=" + Path.GetDirectoryName(python) + ";%PATH%\"\r\n");
            await File.WriteAllTextAsync(Path.Combine(engine, "pack", "jobs", "main.py"), """
import argparse,json,os,sys
p=argparse.ArgumentParser(); p.add_argument('command'); p.add_argument('--request'); p.add_argument('--private-root'); p.add_argument('--task'); a=p.parse_args()
if a.command=='cancel':
    from pathlib import Path
    Path(a.private_root,'cancel-called').write_text(a.task)
    sys.exit(0)
assert a.command=='run'
with open(a.request,encoding='utf-8') as f: r=json.load(f)
assert r['schema']==1 and os.path.normcase(r['engineDir'])==os.path.normcase(os.getcwd()), 'job selected engine reaches backend'
assert r['operation'] in ['setup','catalog','keys','import']
assert r['library'].endswith('Output') and r.get('libraryId')=='opaque-id'
if r.get('paths')==['wait']:
    import time
    from pathlib import Path
    while not Path(r['privateRoot'],'cancel-called').exists(): time.sleep(.02)
    assert Path(r['privateRoot'],'cancel-called').read_text()==r['jobId']
    print(json.dumps(dict(schema=1,jobId=r['jobId'],seq=1,type='result',operation=r['operation'],state='cancelled',message='cancelled',result={})))
    sys.exit(130)
assert r.get('paths')==['C:/Synthetic/中文 & %NAME% !.nsp'], 'original paths reach job request'
print(json.dumps(dict(schema=1,jobId=r['jobId'],taskId=r['jobId'],seq=1,type='result',operation=r['operation'],state='succeeded',message='合成操作完成',result={'accepted':r['operation']}),ensure_ascii=False))
print('request-file='+a.request,file=sys.stderr)
""");
            var paths = new LauncherPaths(engine, runtime, Path.Combine(root, "Shell"));
            foreach (var operation in new[] { "setup", "catalog", "keys", "import" })
            {
                var job = await LibraryJobClient.RunAsync(paths, privateRoot, Path.Combine(root, "Output"), "opaque-id",
                    operation, new[] { "C:/Synthetic/中文 & %NAME% !.nsp" }, CancellationToken.None);
                check(job.Report.Succeeded && job.Report.Result.GetProperty("accepted").GetString() == operation,
                    "literal request paths and selected Engine reach job " + operation);
                var requestPath = job.Output.StandardError.Split('\n').Single(x => x.StartsWith("request-file="))[13..].Trim();
                check(!File.Exists(requestPath), "job temporary request cleaned for " + operation);
            }
            using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
            var timer = Stopwatch.StartNew();
            try
            {
                await LibraryJobClient.RunAsync(paths, privateRoot, Path.Combine(root, "Output"), "opaque-id", "import", ["wait"], cancel.Token);
                throw new Exception("accepted library cancellation");
            }
            catch (OperationCanceledException)
            { check(File.Exists(Path.Combine(privateRoot, "cancel-called")) && timer.Elapsed < TimeSpan.FromSeconds(7),
                "library cancellation uses main.py cancel before owned process fallback"); }
            check(!Directory.GetFiles(privateRoot, "request-*.json").Any(), "cancelled job request removed after process exits");
            Console.WriteLine("Windows library cases: 23 assertions passed (13 ACL + 8 invocation + 2 cancellation; no device/game/key probe)");
        }
        finally
        {
            var resolved = Path.GetFullPath(root);
            if (!resolved.StartsWith(temp.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Private request test cleanup escaped temporary root.");
            foreach (var link in new[] { "Junction", "Dangling" }.Select(n => new DirectoryInfo(Path.Combine(resolved, n))).Where(d => d.LinkTarget is not null))
                link.Delete();   // 先删链接本身：断链留在里面，递归删除会报「参数错误」
            if (Directory.Exists(resolved)) Directory.Delete(resolved, true);
        }
    }

    private static void Junction(string link, string target)
    {
        using var p = Process.Start(new ProcessStartInfo("cmd.exe", ["/c", "mklink", "/J", link, target]) { UseShellExecute = false, RedirectStandardOutput = true })!;
        p.StandardOutput.ReadToEnd(); p.WaitForExit();
        if (p.ExitCode != 0) throw new InvalidOperationException("mklink /J failed: " + link);
    }

    // 当前令牌复制一份、关掉全部特权，在它下面跑 action（只影响这个线程这一段）
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static void WithoutPrivileges(Action action)
    {
        if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, 0x0002 | 0x0008 | 0x0020, out var process))   // DUPLICATE | QUERY | ADJUST_PRIVILEGES
            throw new System.ComponentModel.Win32Exception();
        try
        {
            if (!DuplicateTokenEx(process, 0x02000000, IntPtr.Zero, 2, 2, out var plain))   // MAXIMUM_ALLOWED，SecurityImpersonation，TokenImpersonation
                throw new System.ComponentModel.Win32Exception();
            using var handle = new Microsoft.Win32.SafeHandles.SafeAccessTokenHandle(plain);
            if (!AdjustTokenPrivileges(plain, true, IntPtr.Zero, 0, IntPtr.Zero, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception();
            WindowsIdentity.RunImpersonated(handle, action);
        }
        finally { CloseHandle(process); }
    }
    [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool DuplicateTokenEx(IntPtr token, uint access, IntPtr attributes, int level, int type, out IntPtr duplicate);
    [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, IntPtr state, uint length, IntPtr previous, IntPtr returned);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
}
