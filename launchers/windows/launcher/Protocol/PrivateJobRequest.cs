// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace S2Arm.Launcher.Protocol;

// Requests carry player paths. The parent is private before a request file is created.
public sealed class PrivateJobRequest : IDisposable
{
    public string FilePath { get; }
    private PrivateJobRequest(string path) => FilePath = path;

    /// <summary>私有目录用不了时给玩家看的话：(原因代码, 目录) → 一句话。协议层没有本地化，启动器起来时换成体验规格里的中 / 英文案
    /// （private_root.&lt;代码&gt;）；缺省英文。原先直接抛英文短句、不点名目录（#672：「Private job root is not owned by this user.」）</summary>
    public static Func<string, string, string> Describe { get; set; } = (code, path) => code switch
    {
        "reparse" => $"S2Arm's private data folder {path} is a link to a place this Windows account does not own (or the link is broken), so another account could change what is in it; for safety it is not used. Delete the link (or point it at a folder of your own) and reopen S2Arm; it is recreated, your game library and saves are not in it, but imported keys must be imported again.",
        "owner" => $"S2Arm's private data folder {path} belongs to another Windows account and this account cannot take it over. S2Arm works as usual, but that account can see the files in it; to lock it down, delete the folder and reopen S2Arm (it is recreated; your game library and saves are not in it, but imported keys must be imported again), or open S2Arm once with that account.",
        _ => $"S2Arm's private data folder {path} still gives another account access and this account cannot remove it. S2Arm works as usual, but that account can see the files in it; to lock it down, delete the folder and reopen S2Arm (it is recreated; your game library and saves are not in it, but imported keys must be imported again).",
    };

    /// <summary>私有目录收不紧（属主拿不回 / 别的账户的权限去不掉）时给玩家看的一句话；null = 没问题。#754：原先这里抛错，控制口和出包都起不来。
    /// 这个检查防的是同机别的账户读到 / 改动请求文件里的玩家路径；请求文件本身建时就是只给本人的受保护权限（CreateWindowsFile），
    /// 目录收不紧只少一层防护，玩家照常用、设置页给一行说明、日志记一笔，不拦</summary>
    public static string? Warning { get; private set; }
    /// <summary>自愈 / 收不紧时记日志（启动器起来时接到自己的日志；缺省不记）</summary>
    public static Action<string> Note { get; set; } = _ => { };

    // 必须先于私有目录下的任何子目录调用：Directory.CreateDirectory 顺带建出的父目录带继承权限，之后的作业会被权限校验拒绝。
    public static void EnsurePrivateRoot(string privateRoot)
    {
        if (OperatingSystem.IsWindows()) PrepareWindowsRoot(privateRoot);
    }

    public static PrivateJobRequest Create(string privateRoot, string json)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows request ACL required.");
        var directory = PrepareWindowsRoot(privateRoot);
        var path = Path.Combine(directory, "request-" + Guid.NewGuid().ToString("N") + ".json");
        var created = false;
        try
        {
            using var file = CreateWindowsFile(path);
            created = true;
            var bytes = Encoding.UTF8.GetBytes(json);
            file.Write(bytes);
            file.Flush(flushToDisk: true);
            return new(path);
        }
        catch { if (created) File.Delete(path); throw; }
    }

    [SupportedOSPlatform("windows")]
    private static FileStream CreateWindowsFile(string path)
    {
        using var identity = WindowsIdentity.GetCurrent();
        var current = identity.User ?? throw new IOException("Current user SID is missing.");
        var security = new FileSecurity();
        security.SetOwner(current);
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new FileSystemAccessRule(current, FileSystemRights.FullControl, AccessControlType.Allow));
        return new FileInfo(path).Create(FileMode.CreateNew, FileSystemRights.Write, FileShare.None, 4096, FileOptions.None, security);
    }

    [SupportedOSPlatform("windows")]
    private static string PrepareWindowsRoot(string path)
    {
        path = Path.GetFullPath(path);
        using var identity = WindowsIdentity.GetCurrent();
        var current = identity.User ?? throw new IOException("Current user SID is missing.");
        var directory = new DirectoryInfo(path);
        if (directory.LinkTarget is not null)   // 先于 Exists：断链 Exists 为假，会被当成没有、去新建
        {
            // 玩家常用目录联接把数据目录挪到别的盘：指向的目录归本人（属主是本人，或本人 / 本人所在的组有完全控制）就照常用、记一笔；
            //   指向的位置不归本人（别人能换掉里面的东西）或链接断了才拒，Describe 说清下一步
            DirectoryInfo? target;
            bool owned;
            try
            {
                target = directory.ResolveLinkTarget(returnFinalTarget: true) as DirectoryInfo;
                owned = target is { Exists: true } && OwnedBy(target.GetAccessControl(), identity);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)   // 断链：解析时 Windows 报「参数错误」
            { throw new IOException(Describe("reparse", path), error); }
            if (!owned || target is null) throw new IOException(Describe("reparse", path));
            Note($"private root is a link to {target.FullName}, owned by this account; used as is");
        }
        if (!directory.Exists)
        {
            var security = new DirectorySecurity();
            security.SetOwner(current);
            security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
            security.AddAccessRule(new FileSystemAccessRule(current, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            directory.Create(security);
        }
        directory.Refresh();
        var readers = FileSystemRights.ReadData | FileSystemRights.ReadAttributes | FileSystemRights.ReadExtendedAttributes |
            FileSystemRights.ReadPermissions | FileSystemRights.Write | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
        var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        var administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        bool Trusted(IdentityReference who) => who.Equals(current) || who.Equals(system) || who.Equals(administrators);
        bool Others(DirectorySecurity a) => a.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>()
            .Any(rule => rule.AccessControlType == AccessControlType.Allow && (rule.FileSystemRights & readers) != 0 && !Trusted(rule.IdentityReference));
        var acl = directory.GetAccessControl();
        string Warn(string code, Exception? error)
        {
            Warning = Describe(code, path);
            Note($"private root {code}, left as is: {path} {error?.Message}");
            return path;
        }
        // 自愈（#672 / #669）：属主是别的账户（以前用别的账户或「以管理员身份运行」建的）、或还给别的账户开着权限（从上级继承了另一个本地账户的完全控制）。
        //   当前账户对这个目录有接管属主 / 改权限的权利时（通常有：完全控制里就含这两项），先把属主拿回本人——之后别人就没法再把权限改回去——
        //   再改成不继承、只留本人 / SYSTEM / Administrators。只收紧、不放宽；改不动（没有这两项权利）照常用，Warning 点名目录、说怎么恢复（#754）
        if (!current.Equals(acl.GetOwner(typeof(SecurityIdentifier))))
        {
            try
            {
                var owner = new DirectorySecurity();
                owner.SetOwner(current);
                directory.SetAccessControl(owner);   // 只写属主一节
            }
            catch (Exception error) when (error is UnauthorizedAccessException or InvalidOperationException or PrivilegeNotHeldException)
            {
                return Warn("owner", error);
            }
            directory.Refresh(); acl = directory.GetAccessControl();
            if (!current.Equals(acl.GetOwner(typeof(SecurityIdentifier)))) return Warn("owner", null);
            Note($"private root owner taken over: {path}");
        }
        if (Others(acl))
        {
            try
            {
                acl.SetAccessRuleProtection(isProtected: true, preserveInheritance: true);   // 先把继承来的转成显式规则，下面才删得掉
                directory.SetAccessControl(acl);
                directory.Refresh(); acl = directory.GetAccessControl();
                foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, false, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToList())
                    if (!Trusted(rule.IdentityReference)) acl.RemoveAccessRuleSpecific(rule);
                directory.SetAccessControl(acl);
            }
            catch (Exception error) when (error is UnauthorizedAccessException or InvalidOperationException)
            {
                return Warn("others", error);
            }
            directory.Refresh(); acl = directory.GetAccessControl();
            if (Others(acl)) return Warn("others", null);
            Note($"private root access for other accounts removed: {path}");
        }
        Warning = null;
        if (!acl.AreAccessRulesProtected)
        {
            // 自愈（#580）：目录已存在、属主是本人、不是重解析点、上面也没有给其他身份的权限（都已核过），只是还继承上级——
            //   常见于先用 Directory.CreateDirectory 建了子目录、顺带建出的父目录（见 EnsurePrivateRoot 的说明）。原先这里直接报错，
            //   玩家每次添加游戏都卡在「Private job root inherits permissions」，换游戏库位置也没用（这个目录不在游戏库里）。
            //   就地改成不继承、把现有规则原样转成显式规则：有效权限不变，只是以后上级目录的变动不再传进来
            acl.SetAccessRuleProtection(isProtected: true, preserveInheritance: true);
            directory.SetAccessControl(acl);
            directory.Refresh();
            if (!directory.GetAccessControl().AreAccessRulesProtected) throw new IOException("Private job root inherits permissions.");
        }
        return path;
    }

    [SupportedOSPlatform("windows")]
    private static bool OwnedBy(DirectorySecurity acl, WindowsIdentity identity)
    {
        if (identity.User is { } user && user.Equals(acl.GetOwner(typeof(SecurityIdentifier)))) return true;
        var mine = new HashSet<IdentityReference>(identity.Groups ?? new IdentityReferenceCollection()) { identity.User! };
        var rules = acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().Where(r => mine.Contains(r.IdentityReference)).ToList();
        return !rules.Any(r => r.AccessControlType == AccessControlType.Deny) &&
            rules.Any(r => r.AccessControlType == AccessControlType.Allow && (r.FileSystemRights & FileSystemRights.FullControl) == FileSystemRights.FullControl);
    }

    public void Dispose() => File.Delete(FilePath);
}
