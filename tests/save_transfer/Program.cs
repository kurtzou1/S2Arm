using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using S2A.Services;

Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = new S2A.Apple.SaveCommit.AppleHostDirectoryTransaction();

if (args.Length == 2 && args[0] == "--request")
{
    Console.WriteLine(SaveTransfer.Execute(File.ReadAllText(args[1])));
    return;
}
if (args.Length == 1 && args[0] == "--linked-root")
{
    // 诊断 D-R52E：数据根所在路径上有链接（游戏库挪到外置盘再链回来、/tmp 系统链接）照常做；只拦解开后跑出存档目录的（事务目录下的备份目录链到外面）。期望手写
    string tmp = Directory.CreateDirectory(Path.Combine("/private/tmp", "s2a-linked-root-" + Guid.NewGuid().ToString("N"))).FullName;
    string real = Path.Combine(tmp, "外置盘", "游戏库"), linkParent = Path.Combine(tmp, "链回来");
    Directory.CreateDirectory(Path.Combine(real, "data")); Directory.CreateDirectory(Path.Combine(tmp, "work"));
    Directory.CreateSymbolicLink(linkParent, Path.Combine(tmp, "外置盘"));
    string id = "0100000000010000";
    JsonObject Req(string op, string root, string work) => new() { ["operation"] = op, ["dataRoot"] = root, ["workRoot"] = work, ["path"] = Path.Combine(tmp, "x.s2asave"),
        ["game"] = new JsonObject { ["id"] = id, ["version"] = 0, ["contentIdentity"] = new string('a', 64), ["name"] = "t" } };
    string Code(JsonObject r) { var n = JsonNode.Parse(SaveTransfer.Execute(r.ToJsonString())); return n["ok"].GetValue<bool>() ? "ok" : n["error"]["code"].GetValue<string>(); }
    var fails = new List<string>();
    void Expect(bool ok, string what) { Console.WriteLine((ok ? "PASS " : "FAIL ") + what); if (!ok) fails.Add(what); }
    string viaLink = Path.Combine(linkParent, "游戏库", "data");
    Expect(Code(Req("status", viaLink, Path.Combine(tmp, "work"))) == "ok", "data root reached through a linked parent folder: status ok");
    string viaTmp = "/tmp" + Path.Combine(real, "data").Substring("/private/tmp".Length);
    Expect(Code(Req("status", viaTmp, Path.Combine(tmp, "work"))) == "ok", "data root under the /tmp system link: status ok");
    string outside = Directory.CreateDirectory(Path.Combine(tmp, "elsewhere")).FullName;
    Directory.CreateDirectory(Path.Combine(tmp, "work", "save-backups"));
    Directory.CreateSymbolicLink(Path.Combine(tmp, "work", "save-backups", id), outside);
    Expect(Code(Req("status", viaLink, Path.Combine(tmp, "work"))) == "save_unsafe_path", "backup folder linked outside the save folders: still save_unsafe_path");
    Directory.Delete(tmp, true);
    if (fails.Count > 0) { Console.WriteLine($"✗ linked root: {fails.Count} failed"); Environment.Exit(1); }
    Console.WriteLine("✓ linked root: 3 checks");
    return;
}
if (args.Length == 1 && args[0] == "--running-gate")
{
    // 诊断#a87296：游戏在跑（hostRunning）时只放只读的 status / export / inspect；restore / recover、留着没收尾的事务一律 save_running；不需要私有存档
    string tmp = Directory.CreateDirectory(Path.Combine(OperatingSystem.IsWindows() ? Path.GetTempPath() : "/private/tmp", "s2a-running-gate-" + Guid.NewGuid().ToString("N"))).FullName,   // 不走 /var/folders：/var 是软链，存档路径核对拒链接
    root = Path.Combine(tmp, "data"), work = Path.Combine(tmp, "work");
    Directory.CreateDirectory(root);
    string id = "0100000000010000";
    JsonObject Req(string op) => new() { ["operation"] = op, ["dataRoot"] = root, ["workRoot"] = work, ["path"] = Path.Combine(tmp, "x.s2asave"),
        ["game"] = new JsonObject { ["id"] = id, ["version"] = 0, ["contentIdentity"] = new string('a', 64), ["name"] = "t" } };
    string Code(JsonObject r, bool running) { var n = JsonNode.Parse(SaveTransfer.Execute(r.ToJsonString(), running)); return n["ok"].GetValue<bool>() ? "ok" : n["error"]["code"].GetValue<string>(); }
    var fails = new List<string>();
    void Expect(bool ok, string what) { Console.WriteLine((ok ? "PASS " : "FAIL ") + what); if (!ok) fails.Add(what); }
    Expect(Code(Req("status"), false) == "ok", "not running: status ok (fixture is valid)");
    Expect(Code(Req("status"), true) == "ok", "running: status allowed (empty save)");
    Expect(Code(Req("restore"), true) == "save_running", "running: restore refused");
    Expect(Code(Req("recover"), true) == "save_running", "running: recover refused");
    Directory.CreateDirectory(Path.Combine(work, "save-transactions"));
    File.WriteAllText(Path.Combine(work, "save-transactions", id + ".json"), "{}");
    Expect(Code(Req("status"), true) == "save_running", "running: pending transaction journal refuses even status (no Recover while the game writes)");
    Expect(Code(Req("status"), false) != "save_running", "not running: status goes through (Recover handles the journal)");
    Directory.Delete(tmp, true);
    if (fails.Count > 0) { Console.WriteLine($"✗ running gate: {fails.Count} failed"); Environment.Exit(1); }
    Console.WriteLine("✓ running gate: 6 checks");
    return;
}
if (args.Length == 1 && args[0] == "--export-unstarted")
{
    // 存档从电脑推进来、这款在这台设备上还没起过局：有 bis/user/save，没有用户档案与存档索引（第一次起局时模拟器才建）。
    //   导出要报 save_user 并说清「先进一次游戏」，不再是读档案时找不到文件归成的笼统 save_invalid。期望手写
    string tmp = Directory.CreateDirectory(Path.Combine(OperatingSystem.IsWindows() ? Path.GetTempPath() : "/private/tmp", "s2a-export-unstarted-" + Guid.NewGuid().ToString("N"))).FullName,
    root = Path.Combine(tmp, "data"), work = Path.Combine(tmp, "work");
    string save = Path.Combine(root, "bis", "user", "save", "0000000000000001", "0");
    Directory.CreateDirectory(save); File.WriteAllText(Path.Combine(save, "slot.bin"), "progress");
    JsonObject Req(string op, string name) => new() { ["operation"] = op, ["dataRoot"] = root, ["workRoot"] = work, ["path"] = Path.Combine(tmp, name),
        ["game"] = new JsonObject { ["id"] = "0100000000010000", ["version"] = 0, ["contentIdentity"] = new string('a', 64), ["name"] = "t" } };
    var fails = new List<string>();
    void Expect(bool ok, string what) { Console.WriteLine((ok ? "PASS " : "FAIL ") + what); if (!ok) fails.Add(what); }
    var r = JsonNode.Parse(SaveTransfer.Execute(Req("export", "a.s2asave").ToJsonString()));
    string code = r["ok"].GetValue<bool>() ? "ok" : r["error"]["code"].GetValue<string>();
    string msg = r["ok"].GetValue<bool>() ? "" : r["error"]["message"].GetValue<string>();
    Expect(code == "save_user", $"save files without profile / index: export refused as save_user (got {code})");
    Expect(msg.Contains("还没进过游戏") || msg.Contains("hasn't been started"), "message says the game hasn't been started on this device");
    Expect(!File.Exists(Path.Combine(tmp, "a.s2asave")), "no archive left behind");
    Expect(File.ReadAllText(Path.Combine(save, "slot.bin")) == "progress", "save files untouched");
    Directory.Delete(tmp, true);
    if (fails.Count > 0) { Console.WriteLine($"✗ export unstarted: {fails.Count} failed"); Environment.Exit(1); }
    Console.WriteLine("✓ export unstarted: 4 checks");
    return;
}
if (args.Length == 1 && args[0] == "--previous")
{
    // 回到上一份存档：previous 只读、游戏在跑也给；restorePrevious 把已提交版本 0/ 与 .s2a_prev 原子交换，再调一次换回；在跑拒、没有上一份拒
    string tmp = Directory.CreateDirectory(Path.Combine(OperatingSystem.IsWindows() ? Path.GetTempPath() : "/private/tmp", "s2a-previous-" + Guid.NewGuid().ToString("N"))).FullName,
    root = Path.Combine(tmp, "data"), work = Path.Combine(tmp, "work");
    string id = "0100000000010000", save = Path.Combine(root, "bis", "user", "save", "0000000000000001");
    JsonObject Req(string op) => new() { ["operation"] = op, ["dataRoot"] = root, ["workRoot"] = work, ["path"] = Path.Combine(tmp, "x.s2asave"),
        ["game"] = new JsonObject { ["id"] = id, ["version"] = 0, ["contentIdentity"] = new string('a', 64), ["name"] = "t" } };
    JsonNode Call(JsonObject r, bool running = false) => JsonNode.Parse(SaveTransfer.Execute(r.ToJsonString(), running));
    string Code(JsonNode n) => n["ok"].GetValue<bool>() ? "ok" : n["error"]["code"].GetValue<string>();
    string Read(string sub) => File.ReadAllText(Path.Combine(save, sub, "slot.bin"));
    var fails = new List<string>();
    void Expect(bool ok, string what) { Console.WriteLine((ok ? "PASS " : "FAIL ") + what); if (!ok) fails.Add(what); }
    Directory.CreateDirectory(root);
    Expect(Code(Call(Req("previous"))) == "ok" && !Call(Req("previous"))["result"]["hasPrevious"].GetValue<bool>(), "no save: previous ok, hasPrevious false");
    Expect(Code(Call(Req("restorePrevious"))) == "save_no_previous", "no previous: restorePrevious refused (save_no_previous)");
    Directory.CreateDirectory(Path.Combine(save, "0")); File.WriteAllText(Path.Combine(save, "0", "slot.bin"), "newer");
    Directory.CreateDirectory(Path.Combine(save, ".s2a_prev")); File.WriteAllText(Path.Combine(save, ".s2a_prev", "slot.bin"), "older");
    var p = Call(Req("previous"));
    Expect(Code(p) == "ok" && p["result"]["hasPrevious"].GetValue<bool>() && p["result"]["saveIds"][0].GetValue<string>() == "0000000000000001", "previous lists the save that has .s2a_prev");
    Expect(Code(Call(Req("previous"), true)) == "ok", "running: previous allowed (read only)");
    Expect(!p["result"]["guardRed"].GetValue<bool>(), "no guard mark: guardRed false");
    File.WriteAllText(Path.Combine(save, ".s2a_guard"), "commit 3 refused");
    Expect(Call(Req("previous"))["result"]["guardRed"].GetValue<bool>(), "guard mark next to the save: guardRed true");
    Expect(Code(Call(Req("restorePrevious"), true)) == "save_running" && Read("0") == "newer", "running: restorePrevious refused, save untouched");
    var r1 = Call(Req("restorePrevious"));
    Expect(Code(r1) == "ok" && r1["result"]["restored"].GetValue<int>() == 1 && Read("0") == "older" && Read(".s2a_prev") == "newer", "restorePrevious: committed is now the previous version, the newer one kept as previous");
    Expect(!File.Exists(Path.Combine(save, ".s2a_guard")), "restorePrevious clears the guard mark");
    var r2 = Call(Req("restorePrevious"));
    Expect(Code(r2) == "ok" && Read("0") == "newer" && Read(".s2a_prev") == "older", "restorePrevious again: switched back exactly");
    Directory.Delete(tmp, true);
    if (fails.Count > 0) { Console.WriteLine($"✗ previous: {fails.Count} failed"); Environment.Exit(1); }
    Console.WriteLine("✓ previous: 10 checks");
    return;
}
if (args.Length == 4 && args[0] == "--crash-child")
{
    Environment.SetEnvironmentVariable("SAVE_TRANSFER_CHECKPOINT", args[2]);
    Environment.SetEnvironmentVariable("SAVE_TRANSFER_SIGNAL", args[3]);
    Console.WriteLine(SaveTransfer.Execute(File.ReadAllText(args[1])));
    return;
}
if (args.Length != 6 || args[0] != "--source" || args[2] != "--game" || args[4] != "--g05")
    throw new ArgumentException("Use --request request.json, or --source /private/real-root --game identity.json --g05 real-g05.s2asave. Source is read only; tests use private temporary copies.");
RealTests.Run(args[1], args[3], args[5]);

internal static class RealTests
{
    private static JsonObject game;
    private static string source;
    private static string progress;
    private static int passed;
    private static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
    private static JsonObject Request(string root, string work, string operation, string path = null) => new()
    {
        ["operation"] = operation, ["dataRoot"] = root, ["workRoot"] = work, ["game"] = game.DeepClone(), ["path"] = path
    };
    private static JsonObject Call(JsonObject request)
    {
        var response = JsonNode.Parse(SaveTransfer.Execute(request.ToJsonString()));
        Assert(response["ok"].GetValue<bool>(), response.ToJsonString());
        return response["result"].AsObject();
    }
    private static void Reject(JsonObject request, string code = null)
    {
        var response = JsonNode.Parse(SaveTransfer.Execute(request.ToJsonString()));
        Assert(!response["ok"].GetValue<bool>(), "Expected rejection");
        if (code != null) Assert(response["error"]["code"].GetValue<string>() == code, response.ToJsonString());
    }
    private static void Pass(string name) { passed++; Console.WriteLine("PASS " + name); }
    private static SortedDictionary<string, string> Hashes(string root) => new(Directory.GetFiles(root, "*", SearchOption.AllDirectories)
        .ToDictionary(p => Path.GetRelativePath(root, p), p => Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(p)))), StringComparer.Ordinal);
    private static bool Equal(SortedDictionary<string, string> a, SortedDictionary<string, string> b) => a.Count == b.Count && a.All(p => b.TryGetValue(p.Key, out var hash) && hash == p.Value);
    private static void Copy(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (string dir in Directory.GetDirectories(from, "*", SearchOption.AllDirectories)) Directory.CreateDirectory(Path.Combine(to, Path.GetRelativePath(from, dir)));
        foreach (string file in Directory.GetFiles(from, "*", SearchOption.AllDirectories)) File.Copy(file, Path.Combine(to, Path.GetRelativePath(from, file)));
    }
    private static JsonObject Confirm(string root, string work, string archive)
    {
        var preview = Call(Request(root, work, "inspect", archive));
        var request = Request(root, work, "restore", archive);
        request["archiveSha256"] = preview["archiveSha256"].DeepClone();
        request["targetFingerprint"] = preview["targetFingerprint"].DeepClone();
        return request;
    }
    private static void MutateProgress(string root)
    {
        string path = Path.Combine(root, progress);
        byte[] bytes = File.ReadAllBytes(path);
        Assert(bytes.Length > 0, "Need a nonempty real savedata file");
        bytes[0] ^= 0x40;
        File.WriteAllBytes(path, bytes);
    }
    private static void Rewrite(string input, string output, Action<JsonObject> change = null, string extra = null)
    {
        using var original = ZipFile.OpenRead(input);
        using var zip = ZipFile.Open(output, ZipArchiveMode.Create);
        foreach (var entry in original.Entries)
        {
            using var src = entry.Open();
            using var dst = zip.CreateEntry(entry.FullName).Open();
            if (entry.FullName == "manifest.json" && change != null)
            {
                var manifest = JsonNode.Parse(src).AsObject(); change(manifest);
                dst.Write(Encoding.UTF8.GetBytes(manifest.ToJsonString()));
            }
            else src.CopyTo(dst);
        }
        if (extra != null) using (var target = zip.CreateEntry(extra).Open()) target.WriteByte(1);
    }
    internal static void Run(string sourcePath, string gamePath, string macArchive)
    {
        source = Path.GetFullPath(sourcePath);
        macArchive = Path.GetFullPath(macArchive);
        game = JsonNode.Parse(File.ReadAllText(gamePath)).AsObject();
        var original = Hashes(source);
        progress = original.Keys.First(p => p.StartsWith("bis/user/save/", StringComparison.Ordinal) && p.Contains("/0/") && new FileInfo(Path.Combine(source, p)).Length > 0);
        string scratch = Path.Combine(Path.GetTempPath(), "s2arm-transfer-" + Guid.NewGuid().ToString("N"));
        if (scratch.StartsWith("/var/")) scratch = "/private" + scratch;
        Directory.CreateDirectory(scratch);
        string root = Path.Combine(scratch, "source"), work = Path.Combine(scratch, "work"), archive = Path.Combine(scratch, "save.s2asave");
        try
        {
            Copy(source, root);
            var g05 = Call(Request(root, work, "inspect", macArchive));
            Assert(g05["fileCount"].GetValue<int>() > 0, "Real G05 archive"); Pass("inspect real G05 archive with exact game identity");
            Call(Request(root, work, "export", archive));
            var preview = Call(Request(root, work, "inspect", archive));
            Assert(preview["manifest"]["files"].AsArray().All(f => !f["path"].GetValue<string>().Contains("saveMeta")), "Whitelist");
            Pass("export real private save copy and validate CRC/hash/index");
            Reject(Request(root, work, "export", archive), "save_exists"); Pass("exclusive export");
            var stale = Confirm(root, work, archive);
            // 维护者 11-17（按新规矩改：原先检查后目标又变就拒绝）：iCloud 自动同步（sync）照旧拒绝；手动恢复照常恢复，恢复前副本在执行时现拍
            MutateProgress(root);
            var staleSync = stale.DeepClone().AsObject(); staleSync["sync"] = true; Reject(staleSync, "save_changed");
            var staleDone = Call(stale); Assert(staleDone["committed"].GetValue<bool>() && File.Exists(staleDone["previousBackup"].GetValue<string>()), "stale manual restore proceeds with a fresh previous backup");
            Call(Request(root, work, "recover"));
            Pass("changed target after preview: sync rejects, manual restore proceeds");
            var restored = Call(Confirm(root, work, archive));
            Assert(restored["committed"].GetValue<bool>() && Equal(original, Hashes(root)), "byte-for-byte restore including nonwhitelisted original data");
            Assert(File.Exists(restored["previousBackup"].GetValue<string>()), "Previous archive");
            Call(Request(root, work, "inspect", restored["previousBackup"].GetValue<string>()));
            Call(Request(root, work, "recover"));
            Pass("real save restore, preserved saveMeta and selectable previous backup");
            string emptyRoot = Path.Combine(scratch, "empty");
            Call(Confirm(emptyRoot, work + "-empty", macArchive));
            foreach (var file in g05["manifest"]["files"].AsArray())
                Assert(Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(Path.Combine(emptyRoot, file["path"].GetValue<string>())))) == file["sha256"].GetValue<string>(), "G05 imported bytes");
            Pass("restore actual G05 archive into empty target");
            var wrong = Request(root, work, "inspect", archive); wrong["game"]["id"] = "0000000000000000"; Reject(wrong, "save_wrong_game");
            // 版本 / DLC 组合、账号归属对不上：手动检查照常通过并带一句提示；sync（iCloud 自动同步）照旧拒绝
            foreach (var change in new Action<JsonObject>[] { r => r["game"]["version"] = game["version"].GetValue<long>() + 1, r => r["game"]["contentIdentity"] = new string('0', 64) })
            {
                wrong = Request(root, work, "inspect", archive); change(wrong);
                var warned = Call(wrong); Assert(warned["warnings"].AsArray().Count == 1, "version mismatch warns once");
                wrong = Request(root, work, "inspect", archive); change(wrong); wrong["sync"] = true; Reject(wrong, "save_version");
            }
            Assert(Call(Request(root, work, "inspect", archive))["warnings"].AsArray().Count == 0, "matching backup has no warnings");
            Pass("reject other game; version/contentIdentity mismatch warns (sync still rejects)");
            string other = Path.Combine(scratch, "other-owner"); Copy(source, other); OwnershipVariant.Change(other);
            Assert(Call(Request(other, work + "-other", "inspect", archive))["warnings"].AsArray().Count == 1, "owner mismatch warns once");
            var syncOther = Request(other, work + "-other", "inspect", archive); syncOther["sync"] = true; Reject(syncOther, "save_wrong_user");
            Pass("changed actual LibHac account owner warns (sync still rejects)");
            string duplicate = Path.Combine(scratch, "duplicate-index"); Copy(source, duplicate);
            string indexPath = Path.Combine(duplicate, "bis/system/save/8000000000000000/0/imkvdb.arc");
            byte[] indexBytes = File.ReadAllBytes(indexPath);
            Assert(indexBytes.Length >= 292, "Need actual multi-entry index for malformed ownership check");
            indexBytes.AsSpan(24, 64).CopyTo(indexBytes.AsSpan(164, 64));
            File.WriteAllBytes(indexPath, indexBytes);
            RejectInChild(Request(duplicate, work + "-duplicate", "status"), scratch);
            Pass("malformed duplicate actual index fails without terminating process");
            string bad = Path.Combine(scratch, "bad.s2asave");
            Rewrite(archive, bad, m => m["schema"] = 2); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Rewrite(archive, bad, extra: "payload/../escape"); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Rewrite(archive, bad, extra: "MANIFEST.json"); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Rewrite(archive, bad, m => m["files"][0]["sha256"] = new string('0', 64)); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Rewrite(archive, bad, m => m["saveEntries"][0]["userId"] = new string('0', 32)); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Rewrite(archive, bad, m => m["saveEntries"] = null); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Rewrite(archive, bad, m => m["deviceSettings"] = null); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Pass("reject altered real archive: unknown schema, traversal, collisions, hash and forged ownership");
            Rewrite(archive, bad, m => { m.Remove("saveEntries"); m.Remove("deviceSettings"); m["users"] = new JsonObject(); });
            Call(Request(root, work, "inspect", bad)); File.Delete(bad); Pass("old schema1 derives owner from actual committed index");
            byte[] archiveBytes = File.ReadAllBytes(archive);
            File.WriteAllBytes(bad, archiveBytes.Concat(new byte[] { 1, 2, 3 }).ToArray()); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            File.WriteAllBytes(bad, new byte[] { 1, 2, 3 }.Concat(archiveBytes).ToArray()); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Pass("reject trailing and prepended data");
            File.WriteAllBytes(bad, SaveTransfer.Zip64Variant(archiveBytes, false, false)); Call(Request(root, work, "inspect", bad)); File.Delete(bad);
            File.WriteAllBytes(bad, SaveTransfer.Zip64Variant(archiveBytes, false, false, true)); Call(Request(root, work, "inspect", bad)); File.Delete(bad);
            File.WriteAllBytes(bad, SaveTransfer.Zip64Variant(archiveBytes, true, false)); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            File.WriteAllBytes(bad, SaveTransfer.Zip64Variant(archiveBytes, false, true)); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Pass("standard ZIP64 accepts actual archive; excessive count and extensible record reject before entries");
            File.CreateSymbolicLink(Path.Combine(root, "link"), archive); Reject(Request(root, work, "export", bad)); File.Delete(Path.Combine(root, "link")); Pass("reject source symlink");
            foreach (string phase in new[] { "prepared", "oldMoved", "newMoved", "committed" }) Crash(scratch, phase, archive);
            Assert(Equal(original, Hashes(source)), "Source savedata was modified"); Pass("source savedata hashes unchanged");
            Console.WriteLine($"Save transfer actual-data verification: {passed} groups passed; no game was launched.");
        }
        finally { Directory.Delete(scratch, recursive: true); }
    }
    private static ProcessStartInfo Driver()
    {
        string executable = Environment.ProcessPath;
        var start = new ProcessStartInfo(executable) { RedirectStandardOutput = true, RedirectStandardError = true };
        if (Path.GetFileNameWithoutExtension(executable) == "dotnet") start.ArgumentList.Add(typeof(RealTests).Assembly.Location);
        return start;
    }
    private static void RejectInChild(JsonObject request, string scratch)
    {
        string path = Path.Combine(scratch, "bad-index-request.json");
        File.WriteAllText(path, request.ToJsonString());
        var start = Driver(); start.ArgumentList.Add("--request"); start.ArgumentList.Add(path);
        using var process = Process.Start(start);
        string output = process.StandardOutput.ReadToEnd();
        string error = process.StandardError.ReadToEnd();
        Assert(process.WaitForExit(20000) && process.ExitCode == 0, "Malformed index terminated process: " + error);
        Assert(!JsonNode.Parse(output)["ok"].GetValue<bool>(), "Malformed index accepted");
    }
    private static void Crash(string scratch, string phase, string archive)
    {
        string root = Path.Combine(scratch, "crash-" + phase), work = root + "-work";
        Copy(source, root); MutateProgress(root);
        var before = Hashes(root);
        string request = root + ".json", signal = root + ".checkpoint";
        File.WriteAllText(request, Confirm(root, work, archive).ToJsonString());
        var start = Driver();
        foreach (string arg in new[] { "--crash-child", request, phase, signal }) start.ArgumentList.Add(arg);
        using var child = Process.Start(start);
        var timer = Stopwatch.StartNew();
        while (!File.Exists(signal) && !child.HasExited && timer.Elapsed < TimeSpan.FromSeconds(20)) Thread.Sleep(10);
        Assert(File.Exists(signal), "Checkpoint failed: " + phase + (child.HasExited ? child.StandardError.ReadToEnd() + child.StandardOutput.ReadToEnd() : " timeout"));
        child.Kill(); child.WaitForExit();
        Call(Request(root, work, "recover"));
        Assert(Equal(phase == "committed" ? Hashes(source) : before, Hashes(root)), "Crash recovery bytes: " + phase);
        Pass("real child kill and actual-data recovery at " + phase);
    }
}

namespace S2A.Services
{
    public static partial class SaveTransfer
    {
        static partial void Checkpoint(string phase)
        {
            if (Environment.GetEnvironmentVariable("SAVE_TRANSFER_CHECKPOINT") != phase) return;
            File.WriteAllText(Environment.GetEnvironmentVariable("SAVE_TRANSFER_SIGNAL"), phase);
            Thread.Sleep(Timeout.Infinite);
        }
    }
}
