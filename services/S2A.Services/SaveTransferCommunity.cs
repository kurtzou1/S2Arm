using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace S2A.Services;

// iPad / iPhone「存档管理」导入其他模拟器 / 工具的存档（#2070）：原先选择备份只收 S2Arm 的 .s2asave，选到 MeloNX 等导出的 zip / 单个存档文件
//   时把 ZIP 结构错误原样上屏（「Backup metadata is missing」「The ZIP central directory is missing」），玩家看不出原因。
//   现在选到的不是我方备份（不是带 manifest.json 的 zip）时，按存档位置的同一套识别（SaveFolder.Detect：JKSV / Checkpoint / Ryujinx / yuzu /
//   NX2Apple / 裸文件）认文件夹或 zip：认出来 → 检查给预览；确认后先把当前存档备份成 before-restore.s2asave（同我方备份的恢复），再整份放进
//   这款的存档位置（请求里的 saveFolder，同 ios/save_transfer.m save_folder），下次开始游戏时由 SaveFolder.ReadIn 读入——和玩家在「文件」App
//   里手动放进 SaveData 是同一条路。认不出 / 只选了单个散文件 → 一句说人话的原因和该怎么做
public static partial class SaveTransfer
{
    private const string CommunityStage = "community-import";

    /// <summary>是不是我方备份：zip 且带 manifest.json（.s2asave 的元数据）。读不成 zip 的、没有 manifest 的都当社区存档认</summary>
    private static bool OwnBackup(string path)
    {
        if (!File.Exists(path)) return false;
        try
        {
            using var stream = ReadFile(path);
            return ZipBounds(stream).Any(e => e.Name == "manifest.json");
        }
        catch (Failure) { return false; }
    }

    private static bool Community(Context c) => !OwnBackup(Source(c)) && c.Request["saveFolder"] is JsonValue;

    private static string CommunityNotReadable() => T("认不出这份存档。这里能导入 S2Arm 导出的 .s2asave 备份，或其他模拟器 / 工具（JKSV、Checkpoint、Ryujinx、yuzu 等）的存档文件夹或 zip。", "This save wasn’t recognized. You can import an S2Arm .s2asave backup, or a save folder or zip from another emulator or tool (JKSV, Checkpoint, Ryujinx, yuzu and so on).");

    /// <summary>来源（文件夹或 zip）解到工作目录下的暂存处，跳过 __MACOSX（访达压缩带的 ._ 附属文件）；返回暂存目录。单个散文件拒（存档通常是几个文件一起）</summary>
    private static string StageCommunity(Context c, string source)
    {
        string stage = Path.Combine(c.Work, CommunityStage, Guid.NewGuid().ToString("N"));
        CheckLinks(stage);
        Directory.CreateDirectory(stage);
        if (Directory.Exists(source))
        {
            var scan = Scan(source);   // 查链接、数量与大小上限
            foreach (string dir in scan.Directories) Directory.CreateDirectory(Path.Combine(stage, dir));
            foreach (var file in scan.Files)
            {
                if (file.Key.Split('/')[0] == "__MACOSX") continue;
                string target = Path.Combine(stage, file.Key);
                Directory.CreateDirectory(Path.GetDirectoryName(target));
                using var input = ReadFile(Path.Combine(source, file.Key));
                using var output = NewFile(target);
                input.CopyTo(output);
            }
            return stage;
        }
        bool zip;
        List<ZipEntryBounds> bounds = null;
        using (var probe = ReadFile(source))
        {
            try { bounds = ZipBounds(probe); zip = true; }
            catch (Failure) { zip = false; }
        }
        Require(zip, T("只选了一个存档文件。请选存档所在的整个文件夹，或把这些文件一起打包成 zip 再选。", "You picked a single save file. Pick the whole folder the save is in, or zip those files together and pick the zip."), "save_single_file");
        long total = 0;
        int count = 0;
        using var archive = ZipFile.OpenRead(source);
        foreach (var entry in archive.Entries)
        {
            string name = entry.FullName.Replace('\\', '/');
            if (name.Split('/')[0] == "__MACOSX" || name.EndsWith('/')) continue;
            Name(name);   // 相对路径、不越界、不含特殊段
            string target = Path.GetFullPath(Path.Combine(stage, name));
            Require(target.StartsWith(stage + "/", StringComparison.Ordinal), T("zip 里有越界路径。", "The zip contains a path outside its folder."));
            Require(++count <= MaxFiles, T("存档数据超过上限。", "Save data exceeds the limit."));
            Directory.CreateDirectory(Path.GetDirectoryName(target));
            using var input = entry.Open();
            using var output = NewFile(target);
            byte[] buffer = new byte[1 << 20];
            int size;
            while ((size = input.Read(buffer)) != 0)
            {
                total = checked(total + size);
                Require(total <= MaxBytes, T("存档数据超过上限。", "Save data exceeds the limit."));
                output.Write(buffer, 0, size);
            }
        }
        return stage;
    }

    /// <summary>暂存处里认出的存档：(种类, 目录) 列表；认不出抛 save_not_recognized（中文界面接上 Detect 的原因）</summary>
    private static List<(string kind, string dir)> DetectCommunity(Context c, string stage)
    {
        ulong program = Convert.ToUInt64(Str(c.Game, "id"), 16);
        var found = SaveFolder.Detect(stage, program, Array.Empty<string>(), out string why);
        Require(found is { Count: > 0 }, CommunityNotReadable() + (why != null && !English ? T("原因：", "Reason: ") + why : ""), "save_not_recognized");
        return found;
    }

    /// <summary>认出的存档的内容摘要（相对路径、大小、SHA-256）：检查与恢复之间来源变没变</summary>
    private static string CommunityDigest(List<(string kind, string dir)> found, out int files, out long bytes)
    {
        var value = new JsonArray();
        files = 0; bytes = 0;
        foreach (var (kind, dir) in found)
        {
            var scan = Scan(dir);
            foreach (var file in scan.Files)
            {
                value.Add((JsonNode)new JsonArray(kind, file.Key, file.Value, HashFile(Path.Combine(dir, file.Key))));
                files++; bytes += file.Value;
            }
        }
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value.ToJsonString())));
    }

    private static void DropStage(string stage)
    {
        try { if (Directory.Exists(stage)) Directory.Delete(stage, recursive: true); }
        catch (IOException ex) { Console.Error.WriteLine($"S2A 存档导入：暂存目录没删掉，下次再清（{ex.GetType().Name}）"); }
    }

    private static JsonObject InspectCommunity(Context c)
    {
        string stage = StageCommunity(c, Source(c));
        try
        {
            var found = DetectCommunity(c, stage);
            string digest = CommunityDigest(found, out int files, out long bytes);
            return new() { ["community"] = true, ["archiveSha256"] = digest, ["targetFingerprint"] = Fingerprint(c.Root),
                ["fileCount"] = files, ["totalBytes"] = bytes,
                ["notice"] = T("确认后先备份当前存档，再把这份存档放进这款的存档位置，下次开始游戏时读入。", "After you confirm, your current save is backed up first, then this save goes into the game’s save folder and is loaded the next time you start the game.") };
        }
        finally { DropStage(stage); }
    }

    private static JsonObject RestoreCommunity(Context c)
    {
        string folder = Absolute(Str(c.Request, "saveFolder"));
        Require(!Within(folder, c.Root) && !Within(folder, c.Work), T("存档位置无效。", "Invalid save folder."));
        string stage = StageCommunity(c, Source(c));
        try
        {
            var found = DetectCommunity(c, stage);
            string digest = CommunityDigest(found, out _, out long bytes);
            Require(c.Request["archiveSha256"]?.GetValue<string>() == digest, T("备份或目标已变化，请重新检查后确认。", "The backup or target has changed. Check again, then confirm."), "save_changed");
            Space(c.Work, checked(2 * bytes + (64 << 20)));
            // 恢复前副本：当前有存档就先拍一份（同我方备份的恢复，存档管理页「上一份」与回到上一份都认它）
            string prior = "";
            if (Scan(c.Root).Files.Keys.Any(n => n.StartsWith("bis/user/save/", StringComparison.Ordinal)))
            {
                string previous = Path.Combine(c.Backups, Guid.NewGuid().ToString("N"));
                DurableDirectory(previous);
                prior = Path.Combine(previous, "before-restore.s2asave");
                WriteArchive(c, c.Root, prior);
            }
            // 放进存档位置：认过的整份原样放（同玩家在「文件」App 里手动放），不按识别结果改结构——这里拿不到游戏自己存档的顶层名字（ownTop，要游戏进程），
            //   「外面一层文件夹是不是包装」要等起局时 SaveFolder.ReadIn 带着 ownTop 再认；.next / .old 与写回同名，换到一半断了由 SaveFolder.Recover 放回
            string trim = folder.TrimEnd('/'), next = trim + ".next", old = trim + ".old";
            foreach (string d in new[] { next, old }) if (Directory.Exists(d)) Directory.Delete(d, recursive: true);
            CopyTree(stage, next, skipSaves: false);
            if (Directory.Exists(folder)) Directory.Move(folder, old);
            Directory.Move(next, folder);
            if (Directory.Exists(old)) Directory.Delete(old, recursive: true);
            SyncDirectory(Path.GetDirectoryName(folder));
            Console.Error.WriteLine($"S2A 存档导入：其他工具的存档已放进存档位置（{string.Join("、", found.Select(f => f.kind))}），下次起局读入");
            return new() { ["committed"] = true, ["pending"] = true, ["hadOriginal"] = prior.Length > 0, ["previousBackup"] = prior, ["cleanupWarning"] = "" };
        }
        finally { DropStage(stage); }
    }
}
