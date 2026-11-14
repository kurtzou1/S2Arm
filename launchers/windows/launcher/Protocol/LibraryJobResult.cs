// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;

namespace S2Arm.Launcher.Protocol;

public sealed class LibraryProtocolException(string message, Exception? inner = null) : Exception(message, inner);

public sealed record LibraryJobResult(string State, string Message, JsonElement Result, JsonElement Diagnostics)
{
    public bool Succeeded => State == "succeeded";

    // Jobs NDJSON is not the oneclick ev/t stream. A terminal event alone is not process success.
    //   整段输出也逐行交 JobEventReader：事件流规则只有那一份（剃刀 W17：原先这里另写一遍，改一处漏一处）
    public static LibraryJobResult Parse(string ndjson, int exitCode, string jobId, string operation)
    {
        var reader = new JobEventReader(jobId, operation);
        foreach (var line in ndjson.Split('\n')) reader.Accept(line);
        return reader.Finish(exitCode);
    }

    internal static string Text(JsonElement value, string key, bool allowEmpty = false)
    {
        var field = value.GetProperty(key);
        if (field.ValueKind != JsonValueKind.String || (!allowEmpty && string.IsNullOrWhiteSpace(field.GetString())))
            throw new LibraryProtocolException("Expected text: " + key);
        return field.GetString()!;
    }

    internal static void UniqueFields(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in value.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new LibraryProtocolException("Duplicate JSON field.");
                UniqueFields(property.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
            foreach (var item in value.EnumerateArray()) UniqueFields(item);
    }
}

/// <summary>One registered package in the library (base / update / dlc), mirrors GamePackage in the Mac adapter.</summary>
public sealed record GamePackage(string Type, string TitleId, int Version, string Display, long Size, string Format, string Sha256 = "", long ContentBytes = 0);

/// <param name="NeedsKeys">出包要不要 prod.keys：作业层 catalog 直接给（library.KEYLESS_FORMATS 一份判据；剃刀 W10：原先这里另抄一份格式名单）。</param>
public sealed record LibraryGame(string Id, string Name, string Version, string Cover, bool Hidden,
    IReadOnlyList<string> Missing, bool IphoneReady = false, double? IphoneInstalledAt = null,
    bool IphoneFree = false, IReadOnlyList<GamePackage>? Packages = null, bool CustomName = false, bool CustomCover = false,
    GameLocation? Location = null, bool IphoneRestorable = false, GameSizes? Sizes = null, bool NeedsKeys = false, string IphoneInstallDevice = "",
    bool OnPhone = false)
{
    /// <summary>Storage state (library layout v3): ok / offline / missing / none; older catalogues without the field read as none.</summary>
    public string LocationState => Location?.State ?? "none";

    /// <summary>可以显示的本地封面路径：只认作业层给的、就在这款自己文件夹里（catalog location.folder，按英文名或游戏号命名都行）的
    /// cover.jpg（游戏包自带图标）、玩家换的 cover.custom.&lt;8 位十六进制&gt;.jpg（作业层 _CUSTOM_COVER），或没有自带图标时的商店横图 banner.jpg；其它一律 null。
    /// 不按游戏号拼 games\&lt;号&gt;\：v0.2.0 起文件夹按英文名命名（#330）。</summary>
    public string? CoverFile()
    {
        if (Cover.Length == 0 || Location is not { State: "ok", Folder.Length: > 0 } location) return null;
        try
        {
            var path = System.IO.Path.GetFullPath(Cover);
            var folder = System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(location.Folder));
            var parent = System.IO.Path.GetDirectoryName(path);
            var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
            return parent is not null && string.Equals(parent, folder, comparison) &&
                System.Text.RegularExpressions.Regex.IsMatch(System.IO.Path.GetFileName(path), @"^(cover(\.custom\.[0-9a-f]{8})?|banner)\.jpg$") ? path : null;
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or System.IO.PathTooLongException) { return null; }
    }
    /// <summary>Offline or missing games cannot be exported, moved or cleaned (mirrors the Mac card menu).</summary>
    public bool Reachable => LocationState is not ("offline" or "missing");
    /// <summary>DLC count deduplicated by title id (mirrors GameSummary.dlcCount).</summary>
    public int DlcCount => (Packages ?? []).Where(p => p.Type == "dlc")
        .Select(p => p.TitleId).Distinct(StringComparer.Ordinal).Count();
    /// <summary>Display version of the newest base / update package; null when none.</summary>
    public string? BaseVersion => PackageDisplayVersion("base");
    public string? UpdateVersion => PackageDisplayVersion("update");
    /// <summary>Total raw size of the source files: packages that share one file (same sha256, e.g. a base + DLC bundle) count once (#141).</summary>
    public long TotalBytes => (Packages ?? []).GroupBy(p => p.Sha256.Length > 0 ? p.Sha256 : "\0" + p.TitleId + ":" + p.Type + ":" + p.Version)
        .Sum(g => g.First().Size);
    /// <summary>This package's own bytes: when one source file holds several packages, Size is the whole file, so use the reader's per-package
    /// contentBytes (mirrors pack/jobs/report.py own_bytes and the Mac Game.ownBytes); single-package files and old records keep Size.</summary>
    public long OwnBytes(GamePackage p) =>
        p.Sha256.Length > 0 && (Packages ?? []).Count(q => q.Sha256 == p.Sha256) > 1 && p.ContentBytes > 0 ? p.ContentBytes : p.Size;
    private string? PackageDisplayVersion(string type) =>
        (Packages ?? []).Where(p => p.Type == type).OrderByDescending(p => p.Version).FirstOrDefault() is { } pkg
            ? (pkg.Display.Length > 0 ? pkg.Display : "v" + pkg.Version) : null;
};

/// <summary>catalog phoneUpdates 的一项（pack/jobs/install.py phone_updates）：按本机装机记录，这台手机上的 S2Arm 壳比本版旧。
/// Games = 记录里的各款，Stale = 新壳认不得、要按新版重新出包的款（都是 {gameId, name}）。</summary>
public sealed record PhoneUpdate(string Device, string Name, string FromShell, string ToShell,
    IReadOnlyList<PhoneUpdate.Game> Games, IReadOnlyList<PhoneUpdate.Game> Stale)
{
    public sealed record Game(string Id, string Name);

    /// <summary>缺字段 / 不是数组 → 空列表（旧后端没有这个字段）；没有 device 的项跳过。</summary>
    public static IReadOnlyList<PhoneUpdate> ParseList(JsonElement result)
    {
        if (!result.TryGetProperty("phoneUpdates", out var list) || list.ValueKind != JsonValueKind.Array) return [];
        static string S(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
        static IReadOnlyList<Game> Games(JsonElement e, string key) =>
            e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Array
                ? v.EnumerateArray().Where(g => g.ValueKind == JsonValueKind.Object && S(g, "gameId").Length > 0)
                    .Select(g => new Game(S(g, "gameId"), S(g, "name").Length > 0 ? S(g, "name") : S(g, "gameId"))).ToArray()
                : [];
        return list.EnumerateArray().Where(u => u.ValueKind == JsonValueKind.Object && S(u, "device").Length > 0)
            .Select(u => new PhoneUpdate(S(u, "device"), S(u, "name"), S(u, "fromShell"), S(u, "toShell"), Games(u, "games"), Games(u, "stale"))).ToArray();
    }
}

public sealed record LibraryCatalog(IReadOnlyList<LibraryGame> Games, bool KeysReady, string KeysMessage)
{
    /// <summary>壳比本版旧的手机（游戏库顶栏「更新 iPhone 上的 S2Arm」按钮）；旧后端没有这个字段时为空。</summary>
    public IReadOnlyList<PhoneUpdate> PhoneUpdates { get; init; } = [];

    public static LibraryCatalog Parse(JsonElement result)
    {
        try
        {
            LibraryJobResult.UniqueFields(result);
            var games = new List<LibraryGame>();
            var ids = new HashSet<string>(StringComparer.Ordinal);
            foreach (var game in result.GetProperty("games").EnumerateArray())
            {
                var id = LibraryJobResult.Text(game, "id");
                if (!ids.Add(id)) throw new LibraryProtocolException("Duplicate game id.");
                var missing = game.GetProperty("missing").EnumerateArray().Select(item =>
                    item.GetString() ?? throw new LibraryProtocolException("Invalid requirement text.")).ToArray();
                // packages is optional (older catalog versions may omit it)
                var packages = new List<GamePackage>();
                if (game.TryGetProperty("packages", out var pkgsEl) && pkgsEl.ValueKind == JsonValueKind.Array)
                    foreach (var p in pkgsEl.EnumerateArray())
                    {
                        var ptype = p.TryGetProperty("type", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() ?? "" : "";
                        if (ptype.Length == 0) continue;
                        var titleId = p.TryGetProperty("titleId", out var ti) && ti.ValueKind == JsonValueKind.String ? ti.GetString() ?? "" : "";
                        var version = p.TryGetProperty("version", out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : 0;
                        var display = p.TryGetProperty("display", out var d) && d.ValueKind == JsonValueKind.String ? d.GetString() ?? "" : "";
                        var size = p.TryGetProperty("size", out var sz) && sz.ValueKind == JsonValueKind.Number ? sz.GetInt64() : 0;
                        var format = p.TryGetProperty("format", out var f) && f.ValueKind == JsonValueKind.String ? f.GetString() ?? "" : "";
                        var sha = p.TryGetProperty("sha256", out var sh) && sh.ValueKind == JsonValueKind.String ? sh.GetString() ?? "" : "";
                        var content = p.TryGetProperty("contentBytes", out var cb) && cb.ValueKind == JsonValueKind.Number ? cb.GetInt64() : 0;
                        packages.Add(new(ptype, titleId, version, display, size, format, sha, content));
                    }
                // iphoneInstall: { at, free, deviceKey } — matches the Mac adapter's LibraryProvider；deviceKey = 当初装的那台（续签装回它，不换别的）
                double? iphoneAt = null; var iphoneFree = false; var iphoneDevice = "";
                if (game.TryGetProperty("iphoneInstall", out var inst) && inst.ValueKind == JsonValueKind.Object)
                {
                    if (inst.TryGetProperty("at", out var at) && at.ValueKind == JsonValueKind.Number) iphoneAt = at.GetDouble();
                    if (inst.TryGetProperty("free", out var fr) && fr.GetBoolean()) iphoneFree = true;
                    if (inst.TryGetProperty("deviceKey", out var dk) && dk.ValueKind == JsonValueKind.String) iphoneDevice = dk.GetString() ?? "";
                }
                var iphoneReady = game.TryGetProperty("iphoneReady", out var ir) && ir.GetBoolean();
                games.Add(new(id, LibraryJobResult.Text(game, "name"),
                    LibraryJobResult.Text(game, "display", true), LibraryJobResult.Text(game, "cover", true),
                    game.GetProperty("hidden").GetBoolean(), missing, iphoneReady, iphoneAt, iphoneFree, packages.AsReadOnly(),
                    game.TryGetProperty("customName", out var customName) && customName.ValueKind == JsonValueKind.True,
                    game.TryGetProperty("customCover", out var customCover) && customCover.ValueKind == JsonValueKind.True,
                    game.TryGetProperty("location", out var location) && location.ValueKind == JsonValueKind.Object ? GameLocation.Parse(location) : null,
                    game.TryGetProperty("iphoneRestorable", out var restorable) && restorable.ValueKind == JsonValueKind.True,
                    game.TryGetProperty("sizes", out var sizes) && sizes.ValueKind == JsonValueKind.Object ? GameSizes.Parse(sizes) : null,
                    game.TryGetProperty("needsKeys", out var needsKeys) && needsKeys.ValueKind == JsonValueKind.True, iphoneDevice,
                    game.TryGetProperty("onPhone", out var onPhone) && onPhone.ValueKind == JsonValueKind.True));   // 设备记录里装在手机上：删除确认多写一句
            }
            var keys = result.GetProperty("keys");
            return new(games.AsReadOnly(), keys.GetProperty("ready").GetBoolean(),
                LibraryJobResult.Text(keys, "message", true)) { PhoneUpdates = PhoneUpdate.ParseList(result) };
        }
        catch (Exception error) when (error is InvalidOperationException or KeyNotFoundException)
        {
            throw new LibraryProtocolException("Invalid library catalogue.", error);
        }
    }
}

/// <summary>Where one game is stored (library layout v3; catalog game.location, pack/jobs/library.py catalog).
/// Path = the storage location, Folder = the game's own folder (only when State is ok).</summary>
public sealed record GameLocation(string State, string Path, string Folder, string Volume, bool IsDefault)
{
    public static GameLocation Parse(JsonElement value)
    {
        var state = LibraryJobResult.Text(value, "state");
        if (state is not ("ok" or "offline" or "missing" or "none")) throw new LibraryProtocolException("Unknown game location state.");
        return new(state, LibraryJobResult.Text(value, "path", true), LibraryJobResult.Text(value, "folder", true),
            LibraryJobResult.Text(value, "volume", true), value.TryGetProperty("default", out var d) && d.ValueKind == JsonValueKind.True);
    }
}

/// <summary>Per-part size of one game in bytes (catalog game.sizes / storageOverview games[].sizes, pack/jobs/sizes.py; mirrors GameSizes in the Mac adapter).
/// Cache = build cache + shader cache; Sources = referenced game files, a file shared by n games counts size / n for each.
/// Measured is false until a job has measured the game: the four folder parts are then 0 and shown as not counted.</summary>
public sealed record GameSizes(long ImageMac, long ImageIos, long Saves, long Cache, long Sources, bool Measured)
{
    public static GameSizes Parse(JsonElement value)
    {
        long N(string key) => value.TryGetProperty(key, out var n) && n.ValueKind == JsonValueKind.Number ? n.GetInt64() : 0;
        return new(N("imageMac"), N("imageIos"), N("saves"), N("cache"), N("sources"),
            value.TryGetProperty("measured", out var m) && m.ValueKind == JsonValueKind.True);
    }
}

/// <summary>storageOverview job (pack/jobs/sizes.py overview): every storage location's volume total / free and what S2Arm uses there,
/// shared parts (hosts / ipa / toolCache / temp / logs, backend order) and each game's sizes.</summary>
public sealed record StorageOverview(IReadOnlyList<StorageOverview.Location> Locations, IReadOnlyList<StorageOverview.Part> Shared,
    IReadOnlyList<StorageOverview.Game> Games)
{
    /// <summary>Total / Free / Used are null when the location is not connected (no fake zero).</summary>
    public sealed record Location(string Id, string Path, string Volume, bool Connected, bool IsDefault, long? TotalBytes, long? FreeBytes, long? UsedBytes);
    public sealed record Part(string Id, long Bytes);
    public sealed record Game(string Id, string Name, string State, GameSizes Sizes);

    public static StorageOverview Parse(JsonElement result)
    {
        try
        {
            LibraryJobResult.UniqueFields(result);
            long? N(JsonElement e, string key) => e.TryGetProperty(key, out var n) && n.ValueKind == JsonValueKind.Number ? n.GetInt64() : null;
            var locations = result.GetProperty("locations").EnumerateArray().Select(r => new Location(
                LibraryJobResult.Text(r, "id"), LibraryJobResult.Text(r, "path"), LibraryJobResult.Text(r, "volume", true),
                r.GetProperty("connected").GetBoolean(), r.TryGetProperty("default", out var d) && d.ValueKind == JsonValueKind.True,
                N(r, "totalBytes"), N(r, "freeBytes"), N(r, "usedBytes"))).ToArray();
            var shared = result.GetProperty("shared").EnumerateArray().Select(p => new Part(
                LibraryJobResult.Text(p, "id"), N(p, "bytes") ?? throw new LibraryProtocolException("Shared part without bytes."))).ToArray();
            var games = result.GetProperty("games").EnumerateArray().Select(g =>
            {
                var id = LibraryJobResult.Text(g, "gameId");
                var name = g.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String && n.GetString()!.Length > 0 ? n.GetString()! : id;
                return new Game(id, name, g.TryGetProperty("state", out var st) && st.ValueKind == JsonValueKind.String ? st.GetString()! : "none",
                    GameSizes.Parse(g.GetProperty("sizes")));
            }).ToArray();
            return new(locations, shared, games);
        }
        catch (Exception error) when (error is InvalidOperationException or KeyNotFoundException or FormatException)
        { throw new LibraryProtocolException("Invalid storage overview.", error); }
    }
}

/// <summary>One storage location (locations job, pack/jobs/library.py location_rows): one entry of the export page dropdown.</summary>
/// <summary>Slack：这块盘会让出包多占空间 / 可能失败的原因（#444，后端 libloc.slack_reason；只提示不拦）；null 没问题。</summary>
public sealed record StorageLocation(string Id, string Path, string Volume, bool Connected, long? FreeBytes, bool IsDefault, LocationSlack? Slack = null);

/// <summary>Reason：cluster（分配单元 ≥ 64 KB，小文件每个占满一簇）/ format（不是 NTFS、ReFS）；ClusterBytes 提示里写「每个小文件至少占 N」。</summary>
public sealed record LocationSlack(string Reason, long ClusterBytes)
{
    public static LocationSlack? Parse(JsonElement e) =>
        e.TryGetProperty("slackWarning", out var w) && w.ValueKind == JsonValueKind.True && e.TryGetProperty("slackReason", out var r) && r.ValueKind == JsonValueKind.String
            ? new(r.GetString()!, e.TryGetProperty("clusterBytes", out var c) && c.ValueKind == JsonValueKind.Number ? c.GetInt64() : 0) : null;
}

/// <summary>Result of the locations job: every storage location and the id of the one used last.</summary>
/// <summary>Probed / ProbeSlack：请求带 probe（「选择其他文件夹…」选的路径）时为 true，ProbeSlack 是这个路径的提示原因（null = 没问题）。</summary>
public sealed record StorageLocations(IReadOnlyList<StorageLocation> Rows, string Last, bool Probed = false, LocationSlack? ProbeSlack = null)
{
    public static StorageLocations Parse(JsonElement result)
    {
        try
        {
            LibraryJobResult.UniqueFields(result);
            var rows = result.GetProperty("locations").EnumerateArray().Select(r => new StorageLocation(
                LibraryJobResult.Text(r, "id"), LibraryJobResult.Text(r, "path"), LibraryJobResult.Text(r, "volume", true),
                r.GetProperty("connected").GetBoolean(),
                r.TryGetProperty("freeBytes", out var free) && free.ValueKind == JsonValueKind.Number ? free.GetInt64() : null,
                r.TryGetProperty("default", out var d) && d.ValueKind == JsonValueKind.True,
                LocationSlack.Parse(r))).ToArray();
            var probed = result.TryGetProperty("probe", out var p) && p.ValueKind == JsonValueKind.Object;
            return new(rows, result.TryGetProperty("last", out var last) && last.ValueKind == JsonValueKind.String ? last.GetString()! : "",
                probed, probed ? LocationSlack.Parse(p) : null);
        }
        catch (Exception error) when (error is InvalidOperationException or KeyNotFoundException or FormatException)
        { throw new LibraryProtocolException("Invalid storage locations.", error); }
    }

    /// <summary>Export page default (same order as the Mac ExportView): where this game is now (ok / offline) → the location used last
    /// (when connected) → the default location; "" when none is known.</summary>
    public string DefaultFor(GameLocation? game)
    {
        if (game is { State: "ok" or "offline", Path.Length: > 0 }) return game.Path;
        return Rows.FirstOrDefault(r => r.Id == Last && r.Connected)?.Path ?? Rows.FirstOrDefault(r => r.IsDefault)?.Path ?? "";
    }
}

public sealed record LibraryConnection(string Folder, string Id)
{
    public static LibraryConnection Parse(JsonElement result)
    {
        try
        {
            LibraryJobResult.UniqueFields(result);
            var folder = LibraryJobResult.Text(result, "library");
            var id = LibraryJobResult.Text(result, "libraryId");
            if (!Path.IsPathFullyQualified(folder)) throw new LibraryProtocolException("Backend library path must be absolute.");
            // setup owns identity and canonicalization; existing library ids are opaque strings, not necessarily UUIDs.
            return new(Path.GetFullPath(folder), id);
        }
        catch (Exception error) when (error is InvalidOperationException or KeyNotFoundException or ArgumentException)
        { throw new LibraryProtocolException("Invalid library connection result.", error); }
    }
}
