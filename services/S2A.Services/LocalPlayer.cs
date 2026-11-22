using Ryujinx.HLE;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using AccUserId = Ryujinx.HLE.HOS.Services.Account.Acc.UserId;
using AccountManager = Ryujinx.HLE.HOS.Services.Account.Acc.AccountManager;
using Switch = Ryujinx.HLE.Switch;
using UserProfile = Ryujinx.HLE.HOS.Services.Account.Acc.UserProfile;

namespace S2A.Services
{
    // 本地玩家（#623，维护者 11-11）：同一台设备几个人轮流玩，游戏库里选「谁在玩」，同一款游戏的存档跟着玩家走（同 Switch 选用户）。
    //   存档本来就按用户号隔离（账号存档 = 程序号 + 用户号，Saves / SaveFolder / 选用户小程序都按当前用户），这里只决定这一局用哪个用户号。平台在起局环境里给：
    //   S2A_PLAYER_USER = first           第一个玩家（升级前那份进度的主人）：存档位置 SaveData 里记了用户号就用它（旧规则，SaveFolder.SelectUser），
    //                                     没记 = Ryujinx 缺省用户 00000000000000010000000000000000——不沿用数据根里「上次打开的用户」，那可能是上一局别的玩家
    //                   = <32 位十六进制>  另一个玩家：没有这个用户就建（Ryujinx 写进数据根 system/Profiles.json，下次起局还在）、切成当前用户；
    //                                     不认存档位置里记的用户号（玩家选的是谁就是谁，别人的存档拷进这个玩家的文件夹也读进这个玩家名下）
    //                   不给 / 空          旧行为原样（Mac 启动器、开发起局、单款包没建过玩家）
    //   S2A_PLAYER_NAME = 名字（可空）：写进当前用户的资料（游戏里显示的昵称），截到 32 字节 UTF-8 以内
    //   S2A_LOCAL_PLAYERS = JSON 数组 [{"user":"first","name":"...","folder":"SaveData"}, ...]：同屏多手柄 2P–4P 加入时，
    //                       选用户小程序按本机玩家列表顺序绑定对应的独立用户与存档目录，不再凭空生成临时 Player2
    //   存档位置「上次读写摘要」与「没读进来的原因」两个文件按玩家分（SaveFolder.StatePath / ProblemPath，第一个玩家仍是原文件名）；
    //   各玩家的 SaveData 文件夹路径由平台给 S2A_SAVE_FOLDER（共享层不判平台）
    public static class LocalPlayer
    {
        public const string First = "first";
        static readonly Regex Hex32 = new("^[0-9a-f]{32}$");

        public sealed record PlayerEntry(string RequestedUser, AccUserId UserId, string Name, string FolderPath, string FileSuffix);

        private static List<PlayerEntry> _allPlayers = [];
        private static readonly HashSet<AccUserId> _usedInSession = [];
        private static readonly object _syncLock = new();
        public static IReadOnlyList<PlayerEntry> AllPlayers { get { lock (_syncLock) return _allPlayers.ToArray(); } }

        internal static void ResetSession()
        {
            lock (_syncLock)
            {
                Ryujinx.HLE.S2AHooks.CreateLocalPlayer = null;
                Ryujinx.HLE.S2AHooks.UserSelected = null;
                _allPlayers = [];
                _usedInSession.Clear();
            }
        }

        internal static bool WasPlayerUsedInSession(AccUserId userId)
        {
            lock (_syncLock)
            {
                return _usedInSession.Contains(userId);
            }
        }

        internal static void MarkPlayerUsed(AccUserId userId)
        {
            lock (_syncLock)
            {
                _usedInSession.Add(userId);
            }
        }

        /// <summary>这一局的玩家：First、32 位小写十六进制用户号，或 null（没给 = 旧行为）。给了认不出的值报红、按旧行为</summary>
        public static string Requested()
        {
            string v = Environment.GetEnvironmentVariable("S2A_PLAYER_USER")?.Trim().ToLowerInvariant();
            if (string.IsNullOrEmpty(v)) return null;
            if (v == First) return First;
            if (Hex32.IsMatch(v) && v.Any(c => c != '0')) return v;
            Red.Report("S2A_PLAYER_USER 不是 first 也不是 32 位十六进制用户号，按没给处理", v);
            return null;
        }

        /// <summary>按玩家分开的文件名后缀：另一个玩家 = "-&lt;用户号&gt;"；第一个玩家与旧行为 = ""（原文件名不变，升级后接着用）</summary>
        public static string FileSuffix() => Requested() is string u && u != First ? "-" + u : "";

        /// <summary>建存档之前调（Application.Register，EnsureSaveData 之前）：按 S2A_PLAYER_USER 定当前用户，并同步 S2A_LOCAL_PLAYERS 里的全部玩家到 AccountManager。
        ///   返回 true = 已按玩家定好（调用方不再套存档位置里的用户号）；false = 没给玩家，调用方走旧规则</summary>
        public static bool Select(Switch device, ulong programId)
        {
            ResetSession();
            string want = Requested();
            bool roster = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("S2A_LOCAL_PLAYERS"));
            var accounts = device.System.AccountManager;
            accounts.SetUserOrder(Array.Empty<AccUserId>());
            if (want == null && !roster) return false;
            string name = Name();
            if (want == null)
            {
                SaveFolder.SelectUser(device, programId);
                want = First;
            }
            else if (want == First)
            {
                // 旧规则先走：存档位置里记的用户号（P1-162，游戏按建档用户号认人）；没记就回缺省用户
                if (!SaveFolder.SelectUser(device, programId)) Open(accounts, AccountManager.DefaultUserId, name);
            }
            else Open(accounts, new AccUserId(want), name);
            var current = accounts.LastOpenedUser;
            if (name != null && current.Name != name) accounts.SetUserName(current.UserId, name);
            MarkPlayerUsed(current.UserId);
            if (roster)
            {
                SyncConfiguredPlayers(accounts, programId, want, current.UserId);
                Ryujinx.HLE.S2AHooks.CreateLocalPlayer = CreateFromGame;
                Ryujinx.HLE.S2AHooks.UserSelected = MarkPlayerUsed;
            }
            Console.Error.WriteLine($"S2A 本地玩家：{(want == First ? "第一个玩家" : "玩家 " + want)}，当前用户 {current.UserId}（{current.Name}）");
            return true;
        }

        private static void SyncConfiguredPlayers(AccountManager accounts, ulong programId, string activeWant, AccUserId activeUserId)
        {
            string raw = Environment.GetEnvironmentVariable("S2A_LOCAL_PLAYERS");
            string activeSaveFolder = SaveFolder.Folder();
            string baseDir = !string.IsNullOrEmpty(activeSaveFolder) ? Path.GetDirectoryName(activeSaveFolder.TrimEnd(Path.DirectorySeparatorChar)) : null;

            JsonArray arr = null;
            if (!string.IsNullOrWhiteSpace(raw))
            {
                try
                {
                    arr = JsonNode.Parse(raw) as JsonArray;
                }
                catch (Exception e)
                {
                    Red.Report("S2A_LOCAL_PLAYERS JSON 解析失败，忽略多玩家列表", e.Message);
                }
            }
            if (arr == null || arr.Count == 0)
            {
                arr = new JsonArray(new JsonObject
                {
                    ["user"] = activeWant,
                    ["name"] = Name() ?? "",
                    ["folder"] = activeWant == First ? "SaveData" : ("SaveData-" + activeWant)
                });
            }

            var entries = new List<PlayerEntry>();
            var orderedIds = new List<AccUserId>();
            var configuredSet = new HashSet<AccUserId>();

            var folders = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (JsonNode item in arr)
            {
                if (item is not JsonObject obj) continue;
                if (obj["user"] is not JsonValue user || !user.TryGetValue(out string userText)) continue;
                string u = userText.Trim().ToLowerInvariant();
                string rawName = obj["name"] is JsonValue n && n.TryGetValue(out string nick) ? nick : null;
                string folderName = obj["folder"] is JsonValue f && f.TryGetValue(out string dir) ? dir : null;
                if (string.IsNullOrEmpty(u)) continue;
                if (u != First && (!Hex32.IsMatch(u) || !u.Any(c => c != '0'))) continue;

                string folderPath = null;
                if (!string.IsNullOrEmpty(baseDir) && !string.IsNullOrEmpty(folderName) &&
                    (u == First ? folderName == "SaveData" : folderName.StartsWith("SaveData-", StringComparison.Ordinal)) &&
                    folders.Add(folderName) && !folderName.Contains('/') && !folderName.Contains('\\') && !folderName.Contains(':'))
                {
                    folderPath = Path.Combine(baseDir, folderName);
                }

                AccUserId uid;
                if (u == activeWant)
                {
                    uid = activeUserId;
                }
                else if (u == First)
                {
                    string firstHex = folderPath != null ? SaveFolder.FolderUser(folderPath, programId) : null;
                    uid = firstHex != null ? new AccUserId(firstHex) : AccountManager.DefaultUserId;
                }
                else
                {
                    uid = new AccUserId(u);
                }

                string trimmedName = TrimName(rawName);
                EnsureProfile(accounts, uid, trimmedName);
                if (configuredSet.Add(uid))
                {
                    orderedIds.Add(uid);
                    string suffix = u == First ? "" : "-" + u;
                    entries.Add(new PlayerEntry(u, uid, trimmedName, folderPath, suffix));
                }
            }

            if (!configuredSet.Contains(activeUserId))
            {
                orderedIds.Insert(0, activeUserId);
                entries.Insert(0, new PlayerEntry(activeWant, activeUserId, Name(), activeSaveFolder, FileSuffix()));
            }
            accounts.SetUserOrder(orderedIds);
            lock (_syncLock) _allPlayers = entries;
        }

        public static UserProfile CreateFromGame(string rawName)
        {
            Switch device = Host.Device;
            if (device == null) return null;
            AccountManager accounts = device.System.AccountManager;

            string candidate = (rawName ?? "").Trim().Normalize(NormalizationForm.FormC);
            if (string.IsNullOrEmpty(candidate))
            {
                candidate = $"Player{accounts.GetUserCount() + 1}";   // 与选人面板的缺省名、小程序的 CreatePlayerUser 同一种写法
            }

            PlayerEntry entry;
            lock (_syncLock)
            {
                var existingNames = new HashSet<string>(
                    _allPlayers.Select(p => string.IsNullOrEmpty(p.Name) ? "玩家 1" : p.Name),
                    StringComparer.OrdinalIgnoreCase);
                foreach (var u in accounts.GetAllUsers())
                {
                    if (!string.IsNullOrEmpty(u.Name)) existingNames.Add(u.Name);
                }
                existingNames.Add("Player 1");
                existingNames.Add("玩家 1");

                string baseName = candidate;
                int suffixNum = 2;
                while (existingNames.Contains(candidate) || _allPlayers.Any(p => p.UserId == new AccUserId(ComputePlayerUid(candidate))))
                {
                    candidate = $"{baseName}_{suffixNum++}";
                }

                string uidHex = ComputePlayerUid(candidate);
                var existingFolders = new HashSet<string>(
                    _allPlayers.Where(p => !string.IsNullOrEmpty(p.FolderPath)).Select(p => Path.GetFileName(p.FolderPath)),
                    StringComparer.OrdinalIgnoreCase);
                existingFolders.Add("SaveData");

                string folderName = ComputePlayerFolder(candidate, uidHex);
                if (existingFolders.Contains(folderName))
                {
                    folderName += "-" + uidHex[..6];
                }

                string activeSaveFolder = SaveFolder.Folder();
                string baseDir = !string.IsNullOrEmpty(activeSaveFolder) ? Path.GetDirectoryName(activeSaveFolder.TrimEnd(Path.DirectorySeparatorChar)) : null;
                string folderPath = !string.IsNullOrEmpty(baseDir) ? Path.Combine(baseDir, folderName) : null;

                AccUserId uid = new(uidHex);
                string trimmedName = TrimName(candidate) ?? candidate;
                // 记进本机玩家列表；记不上（宿主没有写回接口、偏好写失败）这一局照样建、照样玩，只是下次不在列表里
                try { StorePlayer(uidHex, candidate, folderName); }
                catch (Exception e) { Console.Error.WriteLine($"【红】S2A 本地玩家：{trimmedName} 没记进本机玩家列表（这一局照常用，下次不在列表里）：{e.Message}"); }
                EnsureProfile(accounts, uid, trimmedName);

                entry = new PlayerEntry(uidHex, uid, trimmedName, folderPath, "-" + uidHex);
                if (_allPlayers.All(p => p.UserId != uid))
                {
                    _allPlayers.Add(entry);
                }
                _usedInSession.Add(uid);
                accounts.SetUserOrder(_allPlayers.Select(p => p.UserId));
            }

            // 挂存档在锁外：读写盘可能慢，别让同时进来的选人等着
            Application.EnsureCurrentSaveData(device);
            SaveFolder.ReadSecondary(device, entry);

            Console.Error.WriteLine($"S2A 本地玩家：游戏内新建 S2Arm 玩家 {entry.UserId}（{entry.Name}），存档位置 {entry.FolderPath ?? "（无）"}");
            return accounts.GetAllUsers().FirstOrDefault(u => u.UserId == entry.UserId);
        }

        private static string ComputePlayerUid(string name)
        {
            string key = name.Trim().Normalize(NormalizationForm.FormC).ToLowerInvariant();
            string salt = "";
            while (true)
            {
                byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes("S2Arm local player\n" + key + salt));
                string hex = Convert.ToHexString(hash.AsSpan(0, 16)).ToLowerInvariant();
                if (hex != "00000000000000000000000000000000" && hex != "00000000000000010000000000000000")
                {
                    return hex;
                }
                salt += "\n";
            }
        }

        private static string ComputePlayerFolder(string name, string uidHex)
        {
            var sb = new StringBuilder(name.Length);
            foreach (char ch in name)
            {
                sb.Append((ch == '/' || ch == '\\' || ch == ':') ? '-' : ch);
            }
            string cleaned = sb.ToString().TrimStart('.').Trim();
            var outSb = new StringBuilder();
            int bytes = 0;
            foreach (var rune in cleaned.EnumerateRunes())
            {
                bytes += rune.Utf8SequenceLength;
                if (bytes > 200) break;
                outSb.Append(rune.ToString());
            }
            string finalClean = outSb.ToString();
            return string.IsNullOrEmpty(finalClean) ? "SaveData-" + uidHex[..8] : "SaveData-" + finalClean;
        }

        internal static Action<string, string, string> StorePlayer = PersistPlayerToPreferences;

        private static unsafe void PersistPlayerToPreferences(string uidHex, string name, string folderName)
        {
            if (!NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_local_player_persist", out nint fn))   // 平台例外：苹果启动器与宿主通过本机偏好共享玩家列表，只有发布该列表的宿主提供此写回接口。
                throw new InvalidOperationException("宿主没有本地玩家持久化接口");
            fixed (byte* u = Encoding.UTF8.GetBytes(uidHex + "\0"), n = Encoding.UTF8.GetBytes(name + "\0"), f = Encoding.UTF8.GetBytes(folderName + "\0"))
            {
                if (((delegate* unmanaged<byte*, byte*, byte*, int>)fn)(u, n, f) == 0)
                    throw new IOException("本地玩家列表写入失败");
            }
        }

        static void EnsureProfile(AccountManager accounts, AccUserId id, string name)
        {
            var existing = accounts.TryGetUser(id, out var profile) ? profile : null;
            if (existing == null)
            {
                accounts.AddUser(name ?? "Player", Ryujinx.Common.EmbeddedResources.Read("Ryujinx.HLE/HOS/Services/Account/Acc/DefaultUserImage.jpg"), id);
                Console.Error.WriteLine($"S2A 本地玩家：新建用户 {id}（{name ?? "Player"}）");
            }
            else if (name != null && existing.Name != name)
            {
                accounts.SetUserName(id, name);
            }
        }

        // 没有这个用户就建（缺省头像；名字没给用 Player），再切成当前用户。AccountManager.OpenUser 对不存在的用户号什么都不做，所以先建
        static void Open(AccountManager accounts, AccUserId id, string name)
        {
            EnsureProfile(accounts, id, name);
            if (accounts.LastOpenedUser.UserId != id) accounts.OpenUser(id);
        }

        internal static string Name() => TrimName(Environment.GetEnvironmentVariable("S2A_PLAYER_NAME"));

        // 名字：去掉首尾空白，截到 32 字节 UTF-8 以内（Switch 用户资料的昵称上限），不截半个字；空 = 不改
        internal static string TrimName(string v)
        {
            v = v?.Trim();
            if (string.IsNullOrEmpty(v)) return null;
            var sb = new StringBuilder();
            int bytes = 0;
            foreach (var rune in v.EnumerateRunes())
            {
                bytes += rune.Utf8SequenceLength;
                if (bytes > 32) break;
                sb.Append(rune.ToString());
            }
            return sb.ToString();
        }
    }
}
