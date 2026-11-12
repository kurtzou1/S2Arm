// 游戏原始输入解包（底本旧库 tools/nx_unpack @497552d；出包第一步，零配置新游戏从这里进）：
//   nx_unpack <prod.keys> <输出目录> [--nacp-only | --aoc-only] <xci / nsp 文件…>
// 直接读卡带 / 安装包（不先把 NCA 拷出来），按内容清单（cnmt）认基础程序、最新更新、追加内容（DLC），一遍解密写出：
//   <输出目录>/exefs/（main、sdk、subsdk*、main.npdm、rtld）、romfs/（更新叠加后的资源分区）、aoc/<序号>/（每个 DLC 的数据分区）、
//   ctl/control.nacp（取最新更新的控制分区；服务层 am / ns / acc 读）、icon.jpg、unpack.tsv（程序号、名称、显示版本、构建号、DLC 序号）。
// 源文件按内容认格式（不看扩展名）：0x100 处魔数 HEAD = 卡带镜像（xci，及其压缩版 xcz），否则按安装包（nsp / nsz 的 PFS0）开；
//   里面的 .ncz（nsz / xcz 的压缩 NCA）由 Ncz.cs 还原成原 NCA 再交 LibHac。
// --nacp-only：只写 ctl/control.nacp、icon.jpg、unpack.tsv（给已有产物根补元数据，不重解资源）。
// --exefs-only：只写 exefs/ 与 unpack.tsv 就返回（普查判图形接口 / 位宽用，不解资源）。
// --program-index=<n>：多程序合集（一个应用里多支程序，程序号末位 = 序号）解第 n 支：本体 / 更新清单里的 Program、Control 按内容自己的序号挑（ProgramPick.cs），
//   unpack.tsv 的 title_id 写这支程序的程序号（应用号 + n），多程序合集另写 programs（支数）/ program_index 两行；DLC 仍按应用号认。缺省 0。
// --aoc-only：只解追加内容到 aoc/<序号>/ 并写 aoc.tsv（序号、标题号、版本、文件数、字节），给已有产物根补 DLC；版本核对同 --nacp-only。
//   清单里有、数据不在给的文件里或解不开的 DLC 也记一行，文件数 -1（仅授权：服务层只报已拥有、不挂数据——暗黑2 卡带里的 DLC 是 100 KB 的密钥代号 0 占位包，哈希校验过不了）。
// 追加内容按内容认：清单类型 AddOnContent 且标题号去掉低 12 位 = 程序号 + 0x1000（序号 = 低 12 位），别的游戏的 DLC / 更新文件一起给也只取本游戏的。
// 资源包不在这里出（pack/pack.py 按文件 clonefile 出资源包 v2；旧库的第 1 版分卷输出已删）。
// 完整性：先开 LibHac ErrorOnInvalid；仅更新叠加的 RomFS 遇 2002-4604 可在结构合法时重读一次 None、打黄并记 bypassed；可执行分区始终严格，密钥值不打印。
// 为什么不用 nstool：nstool 先把 NCA 整个拷出再软件 AES 解密写出，暗黑三 16 GB 用 234 秒；SDK 20 起的分区压缩它也不认（丝之歌）。
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using LibHac.Common;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Ncm;
using LibHac.Spl;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.NcaUtils;
using LibHac.Tools.FsSystem.RomFs;
using LibHac.Tools.Ncm;
using ContentType = LibHac.Ncm.ContentType;
using Path = System.IO.Path;

static partial class P {
    static KeySet Ks;
    // 内容号（32 位十六进制）→ 打开它的办法（每次调用都从源文件新开一份读视图，给并行线程各用各的）
    static readonly Dictionary<string, Func<IStorage>> Where = new();
    // 建索引时同一内容号的每一份（来源文件, 打开办法）；全部建完由 Resolve 按 CopyPick 选定一份进 Where
    static readonly Dictionary<string, List<(string From, Func<IStorage> Open)>> Copies = new();
    const long PartSize = 1024L << 20;

    // 源文件本身的问题（空、截断、缺密钥）：报一行能照做的红，不抛调用栈
    sealed class SourceError : Exception { public SourceError(string m) : base(m) { } }
    // 本次跳过的坏源文件（整文件或其中被截断的内容）：报红 / DLC 跳过行里点名原因
    static readonly List<string> Broken = new();
    static string BrokenNote() => Broken.Count == 0 ? "" : $"；跳过的坏源文件：{string.Join("；", Broken)}";
    // 我们自己的用法 / 参数错（如 --title-keys 指的路径不在）：不是「这个包解不开」，不占 --inspect 的退出码 3
    //   （10-28 #633：调用方按 3 认「容器读不出」，把自己的用法错误混成 3 会被说成玩家的密钥问题）
    sealed class UsageError : Exception { public UsageError(string m) : base(m) { } }
    static int Main(string[] a) {
        // 输出固定 UTF-8（无 BOM）：Windows 上 .NET 控制台缺省按系统代码页（中文 Windows 为 GBK）编码，调用方按 UTF-8 读会解不开
        //   （11-04 Windows 出包机01007EF00011E000：追加内容阶段读 --nacp-only 的中文提示报 UnicodeDecodeError）；Mac / Linux 缺省本就是 UTF-8，字节不变
        Console.OutputEncoding = new System.Text.UTF8Encoding(false);
        try { return Run(a); }
        catch (SourceError e) { Console.Error.WriteLine("🔴 " + e.Message); return 1; }
        catch (UsageError e) { Console.Error.WriteLine("🔴 " + e.Message); return 2; }
        catch (Exception e) when (HashFail(e) is HorizonResultException h) {   // 数据块哈希不对（10-26 生死格斗沙滩排球3 整合版：资源被改过、哈希没更新）
            Console.Error.WriteLine($"🔴 源文件数据哈希校验不过（{h.Message.Split('\n')[0]}）：文件被改过（如合进改版资源的整合版）或损坏，换一份原版完整的文件");
            HashWhere(e); return 1; }
        catch (LibHac.Common.Keys.MissingKeyException e) {
            Console.Error.WriteLine("🔴 " + ExplainOne(e).Message); return 1; }
        catch (Exception e) {   // 兜底（10-28 #633）：上面三类之外的任何异常都不许再让 CLR 打印调用栈 + abort（rc=134）
            var (code, message) = Explain(e);
            Report(code, message, e); if (code == "hash_mismatch") HashWhere(e); return 1;
        }
        finally { NczCore.CleanupAll(); }
    }
    // 一行红字 + 分类码（--inspect 的 stderr、完整解包的兜底共用同一份口径，两份入口说同一件事）
    static void Report(string code, string message, Exception e) {
        Console.Error.WriteLine("🔴 " + message);
        Console.Error.WriteLine($"【原因 {code}】");   // 与 --inspect 同形，日志聚合按「【原因 」分类
        if (Trace()) Console.Error.WriteLine(e.ToString());
    }
    // 带 S2A_NXUNPACK_TRACE=1 重跑时把调用栈打到 stderr（默认不打印：普查日志里没用的噪音）
    static bool Trace() => Environment.GetEnvironmentVariable("S2A_NXUNPACK_TRACE") == "1";
    // 任何没被专门接住的异常翻译成「能照做的红字 + 分类码」。分类码是给普查 / 日志聚合看的，不参与成功判定。
    //   异常链里每一个（含并行读包 AggregateException 的全部 inner）各分一次类，按 Prio 取最具体的那个（#772 F-nxunpack-leaf-first：
    //   原先只顺着第一条 inner 走到底，缺密钥 / 容器坏排在第二条时记成 internal，普查和「内部错误」混在一起）
    static readonly string[] Prio = { "disk_full", "access_denied", "ticket_missing", "keys_missing", "hash_mismatch", "container_invalid", "out_of_range", "io", "oom", "hresult", "source", "usage", "internal" };
    static (string Code, string Message) Explain(Exception e) {
        (string Code, string Message) best = ExplainOne(e); int bi = Array.IndexOf(Prio, best.Code);
        foreach (Exception x in Chain(e)) { var r = ExplainOne(x); int i = Array.IndexOf(Prio, r.Code); if (i < bi) { best = r; bi = i; } }
        return best;
    }
    // #792：访问被拒（Windows 上目录改名 / 建文件被拦时是 IOException 带 E_ACCESSDENIED，不一定是 UnauthorizedAccessException）。
    //   原先落进 io「读源文件失败、文件被截断」，玩家去换源文件；被拒的其实多是我们自己的解包工作目录（受控文件夹访问 / 杀毒软件拦写入）
    static bool AccessDenied(Exception x) => x is UnauthorizedAccessException ||
        x is IOException && (x.HResult == unchecked((int)0x80070005) || x.HResult == 13 || (x.Message ?? "").StartsWith("Access to the path", StringComparison.Ordinal));
    internal static string OutDir;   // 本次输出目录（Run 里赋值）：被拒路径在它下面 = 我们自己的工作目录
    internal static string DeniedMessage(Exception x, string first) {
        var m = System.Text.RegularExpressions.Regex.Match(x.Message ?? "", "'([^']+)'");
        string path = m.Success ? m.Groups[1].Value : null;
        bool ours = path != null && OutDir != null && Path.GetFullPath(path).StartsWith(Path.GetFullPath(OutDir).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
        string what = path == null ? "这个路径" : ours ? "S2Arm 自己的解包工作目录（不是游戏源文件）" : "源文件";
        string fix = OperatingSystem.IsWindows()
            ? "常见原因是 Windows 安全中心的「受控文件夹访问」或杀毒软件拦了写入（游戏库放在「文档」「桌面」「图片」这类受保护文件夹里最常见）：把游戏库换到这些文件夹以外，或在安全中心的拦截记录里允许 S2Arm，再重试"
            : "检查这个文件夹的读写权限（访达「显示简介」→ 共享与权限），或把游戏库换到别的文件夹再重试";
        return $"访问被拒绝（{first}）：被拒的是{what}。{fix}";
    }
    // .NET preserves Unix errno and wraps Windows filesystem errors in HRESULTs.
    static bool DiskFull(IOException error) => OperatingSystem.IsWindows()
        ? error.HResult is unchecked((int)0x80070070) or unchecked((int)0x80070027)
        : error.HResult == 28 || error.HResult == (OperatingSystem.IsMacOS() ? 69 : 122);

    static (string Code, string Message) ExplainOne(Exception x) {
        string first = (x.Message ?? "").Split('\n')[0];
        switch (x) {
            case SourceError s: return ("source", s.Message);
            case UsageError u: return ("usage", u.Message);
            case MissingKeyException m when m.Type == LibHac.Common.Keys.KeyType.Title:
                return ("ticket_missing", "缺少内容对应的票据或标题密钥，请检查源文件是否完整");
            case LibHac.Common.Keys.MissingKeyException m:
                return ("keys_missing", $"prod.keys 里没有 {m.Name}：这款游戏用了更新的密钥版本，要用系统版本更新的 Switch 重新导出 prod.keys（{first}）");
            case HorizonResultException h when h.Message.Contains("VerificationFailed"):
                return ("hash_mismatch", $"源文件数据哈希校验不过（{first}）：文件被改过（如合进改版资源的整合版）或损坏，换一份原版完整的文件");
            case HorizonResultException h:
                return ("hresult", $"读内容失败（{first}）：分区表 / 内容头对不上（文件被截断或被改过），或这类内容本工具还不支持");
            case InvalidDataException d:
                return ("container_invalid", $"容器格式不对（{first}）：不是 xci / nsp，或包里的 .ncz 头损坏，换一份原始包");
            case ArgumentOutOfRangeException or IndexOutOfRangeException:
                return ("out_of_range", $"读越界（{first}）：源文件被截断（NCZ 声明的长度比实际数据长），或内容号对不上；文件不完整就换一份完整的");
            case IOException io when DiskFull(io):
                return ("disk_full", "写入内容所需的磁盘空间不足");
            case UnauthorizedAccessException or IOException when AccessDenied(x):
                return ("access_denied", DeniedMessage(x, first));
            case IOException io:   // 含 EndOfStreamException（NCZ 临时文件 / zstd 流提前结束）
                return ("io", $"读源文件失败（{first}）：文件被截断或读不动（外置盘掉线？），换一份完整的");
            case OutOfMemoryException:
                return ("oom", "内存不够（解大资源时分配失败）：关掉别的程序再试，或先只解 exefs（--exefs-only）");
            default:
                return ("internal", $"内部错误 {x.GetType().Name}：{first}（带 S2A_NXUNPACK_TRACE=1 重跑可看调用栈）");
        }
    }
    // 异常链里所有异常（含并行任务 AggregateException 的全部 inner），按先序展开
    static IEnumerable<Exception> Chain(Exception e) {
        var queue = new Queue<Exception>(); queue.Enqueue(e);
        while (queue.Count > 0) {
            Exception x = queue.Dequeue(); yield return x;
            if (x is AggregateException g) { foreach (Exception i in g.InnerExceptions) queue.Enqueue(i); }
            else if (x.InnerException != null) queue.Enqueue(x.InnerException);
        }
    }
    // 哈希错可能被并行读包在 AggregateException 里（10-26 普查：RomFS 分卷并行读时崩成 rc=134 调用栈，上面的红没接住）；
    //   10-28 #633：原先只看 InnerExceptions[0]，并行里多条任务同时失败时哈希错可能排在后面 → 仍然漏成 134，改成看全部
    static HorizonResultException HashFail(Exception e) {
        foreach (Exception x in Chain(e)) if (x is HorizonResultException h && h.Message.Contains("VerificationFailed")) return h;
        return null;
    }
    // #787：哈希校验不过只有一行原因，玩家分不出坏的是本体、更新还是 DLC，也分不出是整合包改过还是解包器的问题。
    //   报红后补两行：读到坏块时在读什么（阶段 + 文件 + 文件内偏移，ReadPlace 包在异常链里），再把本次用到的内容逐个整份核对一遍、
    //   逐段写通过 / 不过（只在失败时做，读一遍全部内容，大游戏要几分钟）
    static volatile string Stage = "建索引";
    static readonly List<(string Role, string Id)> Involved = new();
    static readonly Dictionary<string, string> FromOf = new();   // 内容号 → 选定那份来自哪个源文件（文件名）
    static void HashWhere(Exception e) {
        string at = Chain(e).OfType<ReadPlace>().Select(r => r.Message).FirstOrDefault();
        Console.Error.WriteLine($"   读到坏块时在：{Stage}{(at == null ? "" : "，" + at)}");
        if (Involved.Count == 0) return;
        Console.Error.WriteLine("   逐个核对本次用到的内容（整份读一遍）：");
        foreach (var (role, id) in Involved) Console.Error.WriteLine($"   - {role} {id}（{(FromOf.TryGetValue(id, out var f) ? f : "?")}）：{VerifyReport(id)}");
    }
    static string VerifyReport(string id) {
        if (!Where.TryGetValue(id, out var open)) return "不在给的文件里";
        Nca nca;
        try { nca = new Nca(Ks, open()); } catch (Exception x) { return $"头部读不出（{x.GetType().Name}）"; }
        var parts = new List<string>();
        for (int s = 0; s < 4; s++) {
            if (!nca.SectionExists(s)) continue;
            string kind = nca.Header.ContentType == NcaContentType.Program ? s switch { 0 => "可执行", 1 => "资源", 2 => "标志", _ => "?" } : "数据";
            string v;
            try { v = nca.VerifySection(s) == Validity.Valid ? "通过" : "不过"; }
            catch (Exception x) { v = HashFail(x) != null ? "不过" : $"没法单独核对（{x.GetType().Name}：{(x.Message ?? "").Split('\n')[0]}）"; }   // 更新的资源段要叠在本体上才能读
            parts.Add($"第 {s} 段{kind} {v}");
        }
        return parts.Count == 0 ? "没有分段" : string.Join("，", parts);
    }
    // 整份内容逐段校验哈希（只在有多份可选时调用；读完整份内容）
    static bool VerifyNca(Func<IStorage> open) {
        var nca = new Nca(Ks, open());
        for (int s = 0; s < 4; s++) if (nca.SectionExists(s) && nca.VerifySection(s) != Validity.Valid) return false;
        return true;
    }
    // 每个内容号选定一份：一份直接用；多份时逐份完整校验，取第一份通过的，校验不过的点名（CopyPick）
    static void Resolve() {
        foreach (var (id, list) in Copies) {
            var (pick, bad) = CopyPick.Pick(list.Count, i => VerifyNca(list[i].Open));
            if (bad.Count > 0) Console.WriteLine($"🟡 内容 {id[..8]} 在 {list.Count} 个文件里各有一份；{string.Join("、", bad.Select(i => Path.GetFileName(list[i].From)))} 那份数据校验不过，"
                + (bad.Count < list.Count ? $"用 {Path.GetFileName(list[pick].From)} 那份" : "都不过，照旧用最后一份（读到坏块会报红）"));
            Where[id] = list[pick].Open; FromOf[id] = Path.GetFileName(list[pick].From);
        }
        Copies.Clear();
    }
    static int Run(string[] a) {
        // 单测注入（tests/nx_unpack_fail_test.sh）：造并行读包那种 AggregateException——第一条普通异常、第二条缺密钥，走真实的兜底路径
        if (Environment.GetEnvironmentVariable("S2A_NXUNPACK_TEST_THROW") == "agg-key")
            throw new AggregateException(new Exception("并行任务一：普通异常"), new LibHac.Common.Keys.MissingKeyException("单测：缺密钥", "titlekek_10", LibHac.Common.Keys.KeyType.Common));
        if (Environment.GetEnvironmentVariable("S2A_NXUNPACK_TEST_THROW") == "agg-hash") {   // #787：并行里第二条是带位置的真 2002-4604
            Exception hash = null; try { ResultFs.NonRealDataVerificationFailed.Value.ThrowIfFailure(); } catch (Exception x) { hash = x; }
            throw new AggregateException(new Exception("并行任务一：普通异常"), new ReadPlace("文件 romfs/x.bin，文件内偏移 7（读 16 字节）", hash));
        }
        if (a.Length == 2 && a[0] == "--npdm-isa") return NpdmIsaCli(a[1]);   // 不要密钥：只读一份已解出的 main.npdm
        if (a.Length == 3 && a[0] == "--nso-normalize") {   // 不要密钥：一份 NSO 解成段不压缩（ZBIC 才动，别的原样拷），给 Switch 2 导出目录 / NUP 路径（pack/ns2_dump.py）用
            try { File.WriteAllBytes(a[2], NsoZbic.Normalize(File.ReadAllBytes(a[1]), Path.GetFileName(a[1]))); return 0; }
            catch (InvalidDataException e) { Console.Error.WriteLine($"🔴 {e.Message}"); return 1; }
        }
        if (a.Length >= 3 && a[1] == "--inspect") return Inspect(a);
        if (a.Length < 3) { Console.Error.WriteLine("用法：nx_unpack <prod.keys> <输出目录> [--nacp-only | --aoc-only | --exefs-only] [--aoc-index] [--title-id=<16 hex>] [--program-index=<0..15>] [--title-keys=<title.keys>] <xci/nsp…>"); return 2; }
        var t0 = DateTime.UtcNow;
        Ks = ExternalKeyReader.ReadKeyFile(a[0]); string D = a[1]; OutDir = D; bool nacpOnly = false, aocOnly = false, aocIndex = false, exefsOnly = false;
        // 单测注入（tests/nx_unpack_fail_test.sh，#792）：Windows 目录改名被拦的原样异常（IOException + E_ACCESSDENIED），被拒路径在输出目录里 / 外
        if (Environment.GetEnvironmentVariable("S2A_NXUNPACK_TEST_THROW") is "denied-out" or "denied-src")
            throw new IOException($"Access to the path '{(Environment.GetEnvironmentVariable("S2A_NXUNPACK_TEST_THROW") == "denied-out" ? Path.Combine(D, "build", "extract", ".romfs-extract-40b3") : Path.Combine(Path.GetTempPath(), "src.xci"))}' is denied.", unchecked((int)0x80070005));
        var srcs = new List<string>(); ulong? selectedTitle = null; string titleKeys = null; int programIndex = 0;
        for (int i = 2; i < a.Length; i++) {
            if (a[i] == "--nacp-only") nacpOnly = true;
            else if (a[i] == "--aoc-index") aocIndex = true;
            else if (a[i] == "--exefs-only") exefsOnly = true;
            else if (a[i] == "--aoc-only") aocOnly = true;
            else if (a[i].StartsWith("--title-keys=", StringComparison.Ordinal)) titleKeys = a[i].Substring(13);
            // 多程序合集（ProgramPick.cs）：解同一应用里第几支程序（Program / Control 按内容自己的序号挑），缺省 0
            else if (a[i].StartsWith("--program-index=", StringComparison.Ordinal)) {
                if (!int.TryParse(a[i].Substring(16), out programIndex) || programIndex < 0 || programIndex > 15) { Console.Error.WriteLine("Invalid --program-index (expected 0..15)"); return 2; }
            }
            else if (a[i].StartsWith("--title-id=", StringComparison.Ordinal)) {
                string value = a[i].Substring(11);
                if (value.Length != 16 || !ulong.TryParse(value, System.Globalization.NumberStyles.HexNumber, null, out ulong title)) {
                    Console.Error.WriteLine("Invalid --title-id (expected 16 hex digits)"); return 2;
                }
                selectedTitle = title;
            } else srcs.Add(a[i]);
        }
        if (!nacpOnly && !aocOnly && File.Exists(Path.Combine(D, "exefs", "main"))) { Console.Error.WriteLine($"🔴 {D}/exefs 已有内容；要重解先自己挪走（不覆盖）"); return 1; }
        NczCore.TempDir = Path.GetDirectoryName(Path.GetFullPath(D.TrimEnd('/')));
        LoadTitleKeys(a[0], titleKeys);
        // 源文件坏（0 字节 / 分区表打不开）：只跳过这一个文件并点名，其余照常；本体 / 更新缺了，下面「不在给的文件里」照样报红并附上这些坏文件
        //   （11-01 出包线：七龙珠 电光炸裂 ZERO 一个 21 KB 的截断 DLC 让本体 + 更新整款解不了）
        foreach (string s in srcs) {
            try { Index(s); }
            catch (SourceError e) { Broken.Add(e.Message); Console.WriteLine($"🟡 源文件损坏，已跳过：{e.Message}"); }
        }
        Resolve();

        // ---- 内容清单：基础程序 1 个；更新取版本最高；DLC 按序号（标题号 − 基础 − 0x1000）每个取版本最高 ----
        Stage = "读内容清单（cnmt）"; var metas = new List<Cnmt>();
        // 头部校验不过的内容（10-26 生死格斗沙滩排球3 整合版：120 个里 30 个 DLC 内容头哈希不对）只跳过它自己并点名；
        //   基础程序 / 更新 / 控制若在其中，下面「不在给的文件里」照样报红
        foreach (var (id, open) in Where.ToList()) {
            Nca nca;
            try { nca = new Nca(Ks, open()); }
            catch (Exception e) when (e is not LibHac.Common.Keys.MissingKeyException) { Console.WriteLine($"🟡 内容 {id[..8]} 头部读不出 / 校验不过（{e.GetType().Name}：{e.Message.Split('\n')[0]}），跳过"); Where.Remove(id); continue; }
            if (nca.Header.ContentType != NcaContentType.Meta) continue;
            var fs = nca.OpenFileSystem(0, IntegrityCheckLevel.ErrorOnInvalid);
            foreach (DirectoryEntryEx e in fs.EnumerateEntries("*.cnmt", SearchOptions.Default)) {
                using var f = new UniqueRef<IFile>(); fs.OpenFile(ref f.Ref, e.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                metas.Add(new Cnmt(f.Release().AsStream()));
            }
        }
        var apps = metas.Where(m => m.Type == ContentMetaType.Application && (!selectedTitle.HasValue || m.TitleId == selectedTitle.Value)).GroupBy(m => m.TitleId).ToList();   // 同一游戏的卡带 + 安装包一起给时清单重复，按程序号算
        if (apps.Count != 1) { Console.Error.WriteLine($"🔴 基础程序应恰好 1 个（按程序号），实际 {apps.Count}{BrokenNote()}"); return 1; }
        string Cid(Cnmt m, ContentType t) { var c = m.ContentEntries.FirstOrDefault(c => c.Type == t); return c == null ? null : Convert.ToHexString(c.NcaId).ToLowerInvariant(); }
        // 内容的序号（程序号末位）：读 NCA 头；不在给的文件里 / 读不出回 -1
        int IndexOf(string id) => id != null && Where.TryGetValue(id, out var o) ? new Nca(Ks, o()).ProgramIndex : -1;
        string Hex(CnmtContentEntry c) => Convert.ToHexString(c.NcaId).ToLowerInvariant();
        // Program / Control 按序号挑（多程序合集；Ryujinx ContentMetaData.GetNcaByType），别的类型照旧取第一份
        string CidAt(Cnmt m, ContentType t) {
            var cs = m.ContentEntries.Where(c => c.Type == t).ToList();
            int k = ProgramPick.Pick(cs.Count, i => IndexOf(Hex(cs[i])), programIndex);
            return k < 0 ? null : Hex(cs[k]);
        }
        // 取版本最高的那份清单；同一最高版本有多份、程序内容各不相同时（10-26 泡泡龙4 / 街霸30 周年：卡带本体 + 另一份 NSP 本体，内容号不同、NSP 那份坏），
        //   按 CopyPick 选程序内容校验通过的那份（原先取最后一份 = 坏的 NSP），都不过照旧取最后一份
        Cnmt Newest(IEnumerable<Cnmt> ms, string what) {
            var top = ms.GroupBy(m => m.TitleVersion.Version).OrderBy(g => g.Key).LastOrDefault()?.ToList();
            if (top == null) return null;
            var ids = top.Select(m => CidAt(m, ContentType.Program)).ToList();
            if (ids.Distinct().Count() <= 1) return top.Last();
            var (pick, bad) = CopyPick.Pick(top.Count, i => ids[i] != null && Where.TryGetValue(ids[i], out var o) && VerifyNca(o));
            if (bad.Count > 0) Console.WriteLine($"🟡 {what}同一版本 v{top[0].TitleVersion.Version} 有 {top.Count} 份；程序内容 {string.Join("、", bad.Select(i => ids[i]?[..8] ?? "缺"))} 校验不过，"
                + (bad.Count < top.Count ? $"用 {ids[pick][..8]}" : "都不过，照旧用最后一份（读到坏块会报红）"));
            return top[pick];
        }
        Cnmt app = Newest(apps[0], "本体"); ulong tid = app.TitleId;
        Cnmt pat = Newest(metas.Where(m => m.Type == ContentMetaType.Patch && m.ApplicationTitleId == tid), "更新");
        var dlc = metas.Where(m => m.Type == ContentMetaType.AddOnContent && (m.TitleId & ~0xFFFUL) == tid + 0x1000).GroupBy(m => m.TitleId).Select(g => g.OrderBy(m => m.TitleVersion.Version).Last())
                     .OrderBy(m => (m.TitleId - tid - 0x1000).ToString(), StringComparer.Ordinal).ToList();   // 按序号的字符串序（= pack.py 遍历 data/<游戏>/aoc 时子目录的排序）
        string baseId = CidAt(app, ContentType.Program), patId = pat == null ? null : CidAt(pat, ContentType.Program);
        string ctrlId = (pat == null ? null : CidAt(pat, ContentType.Control)) ?? CidAt(app, ContentType.Control);
        // 包里几支程序（本体清单里 Program 的序号从 0 起连续）；单程序款只有一份 Program，不读头
        var progs = app.ContentEntries.Where(c => c.Type == ContentType.Program).ToList();
        int programs = progs.Count <= 1 ? progs.Count : ProgramPick.Count(progs.Select(c => { try { return IndexOf(Hex(c)); } catch (Exception) { return -1; } }));
        if (baseId == null) { Console.Error.WriteLine($"🔴 本体清单里没有序号 {programIndex} 的程序（共 {programs} 支，序号 0..{programs - 1}）{BrokenNote()}"); return 1; }
        ulong pid = tid + (ulong)programIndex;   // 这支程序自己的程序号（本体清单的程序号 = 序号 0；DLC 仍按应用号 tid 认）
        // 多程序合集才多写两行（单程序款 unpack.tsv 逐字节不变）：programs = 支数、program_index = 本次解的序号
        string multi = programs > 1 || programIndex > 0 ? $"programs\t{programs}\nprogram_index\t{programIndex}\n" : "";
        foreach (string need in new[] { baseId, patId }) if (need != null && !Where.ContainsKey(need)) { Console.Error.WriteLine($"🔴 清单里的内容 {need} 不在给的文件里（更新 / 基础分在别的文件？一起给）{BrokenNote()}"); return 1; }
        Involved.Add(("本体程序", baseId)); if (patId != null) Involved.Add(("更新程序", patId));
        if (ctrlId != null && Where.ContainsKey(ctrlId)) Involved.Add(("控制数据", ctrlId));
        Console.WriteLine($"程序号 {pid:x16}{(programs > 1 ? $"（多程序合集 {programs} 支，本次序号 {programIndex}）" : "")}；基础 {baseId[..8]}；更新 {(patId == null ? "无" : patId[..8] + " v" + pat.TitleVersion.Version)}；DLC {dlc.Count} 个");
        Func<IntegrityCheckLevel, IStorage> RomfsOpener = level => {   // 叠加更新后的资源分区（每次新开，线程各用各的）
            var b = new Nca(Ks, Where[baseId]());
            return patId == null ? b.OpenStorage(NcaSectionType.Data, level)
                                 : b.OpenStorageWithPatch(new Nca(Ks, Where[patId]()), NcaSectionType.Data, level);
        };

        // ---- 控制数据：名称、显示版本、图标 ----
        Directory.CreateDirectory(D); string name = "", nameZh = "", dver = "";
        if (!aocOnly && ctrlId != null && Where.ContainsKey(ctrlId)) {
            Stage = $"控制数据（内容 {ctrlId[..8]}）";
            var cfs = new Nca(Ks, Where[ctrlId]()).OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
            byte[] nacp = ReadAll(cfs, "/control.nacp"); Directory.CreateDirectory(Path.Combine(D, "ctl")); File.WriteAllBytes(Path.Combine(D, "ctl", "control.nacp"), nacp);
            name = TitleName(nacp, 0); nameZh = TitleName(nacp, 14) ?? TitleName(nacp, 13) ?? name; name ??= nameZh ?? ""; dver = Encoding.ASCII.GetString(nacp, 0x3060, 0x10).TrimEnd('\0');
            foreach (string lang in IconLangs) { byte[] ic = ReadAll(cfs, $"/icon_{lang}.dat"); if (ic != null) { File.WriteAllBytes(Path.Combine(D, "icon.jpg"), ic); break; } }
        }

        if (nacpOnly || aocOnly) {
            if (nacpOnly && !File.Exists(Path.Combine(D, "ctl", "control.nacp"))) { Console.Error.WriteLine("🔴 清单里没有控制分区（或不在给的文件里）"); return 1; }
            // 版本核对：元数据必须和输出目录里已有的 exefs 同一版本——比 main 模块的构建号（NSO 头 0x40 起 16 字节）
            var bn0 = new Nca(Ks, Where[baseId]());
            IFileSystem ex0 = patId == null ? bn0.OpenFileSystem(NcaSectionType.Code, IntegrityCheckLevel.ErrorOnInvalid)
                                            : bn0.OpenFileSystemWithPatch(new Nca(Ks, Where[patId]()), NcaSectionType.Code, IntegrityCheckLevel.ErrorOnInvalid);
            byte[] m0 = ReadAll(ex0, "/main"); string have = Path.Combine(D, "exefs", "main");
            if (File.Exists(have)) {
                byte[] m1 = File.ReadAllBytes(have);
                if (m0 == null || m0.Length < 0x50 || m1.Length < 0x50 || !m0.AsSpan(0x40, 16).SequenceEqual(m1.AsSpan(0x40, 16))) {
                    if (nacpOnly) File.Delete(Path.Combine(D, "ctl", "control.nacp"));
                    Console.Error.WriteLine($"🔴 版本不符：包里 main 构建号 {(m0 == null ? "无" : Convert.ToHexString(m0, 0x40, 16))}，{have} 是 {Convert.ToHexString(m1, 0x40, 16)}（{(aocOnly ? "追加内容" : "元数据 " + dver)}与已有 exefs 不是同一版本，没写）"); return 1;
                }
            } else if (aocOnly) { Console.Error.WriteLine($"🔴 {have} 不在：--aoc-only 只给已有产物根补追加内容"); return 1; }
        }
        // base = 本体 CNMT 版本。没有更新的款（update 空）出包要内容版本时取它；显示版本不能替代（10-25；11-03 御天之剑HD）
        string vers = $"update\t{(pat == null ? "" : pat.TitleVersion.Version.ToString())}\nbase\t{app.TitleVersion.Version}\n";
        if (nacpOnly) {
            File.WriteAllText(Path.Combine(D, "unpack.tsv"), $"title_id\t{pid:x16}\nname\t{name}\nname_zh\t{nameZh}\ndisplay_version\t{dver}\n{vers}{multi}");
            Console.WriteLine($"🟢 控制数据：{name}（{nameZh}，{dver}）→ {D}/ctl/control.nacp"); return 0;
        }

        var builds = new List<string>();
        if (!aocOnly) {   // ---- 可执行分区 ----
        Stage = $"可执行分区（本体 {baseId[..8]}{(patId == null ? "" : " + 更新 " + patId[..8])}）";
        var bn = new Nca(Ks, Where[baseId]());
        IFileSystem exefs = patId == null ? bn.OpenFileSystem(NcaSectionType.Code, IntegrityCheckLevel.ErrorOnInvalid)
                                          : bn.OpenFileSystemWithPatch(new Nca(Ks, Where[patId]()), NcaSectionType.Code, IntegrityCheckLevel.ErrorOnInvalid);
        string ex = Path.Combine(D, "exefs"); Directory.CreateDirectory(ex);
        foreach (DirectoryEntryEx e in exefs.EnumerateEntries("*", SearchOptions.Default)) {
            if (e.Type != DirectoryEntryType.File) continue; byte[] raw;
            try { raw = ReadAll(exefs, e.FullPath); } catch (Exception x) when (x is not ReadPlace) { throw new ReadPlace($"文件 exefs/{e.Name}", x); }
            byte[] v = NsoZbic.Normalize(raw, e.Name); File.WriteAllBytes(Path.Combine(ex, e.Name), v);   // ZBIC 段的 NSO 解成不压缩段（#769）
            if (v.Length >= 0x50 && v[0] == 'N' && v[1] == 'S' && v[2] == 'O' && v[3] == '0') builds.Add($"{e.Name}:{Convert.ToHexString(v, 0x40, 16).ToLowerInvariant()}");
        }
        }
        if (exefsOnly) {
            File.WriteAllText(Path.Combine(D, "unpack.tsv"), $"title_id\t{pid:x16}\nname\t{name}\nname_zh\t{nameZh}\ndisplay_version\t{dver}\n{vers}{multi}builds\t{string.Join(' ', builds)}\n");
            Console.WriteLine($"🟢 只解 exefs：{name}（{dver}）；{string.Join(' ', builds.Select(b => b.Split(':')[0]))}；{(DateTime.UtcNow - t0).TotalSeconds:F0} 秒"); return 0;
        }

        // ---- 资源：清单（顺序 = pack.py 的 os.walk：每个目录先本层文件（按名排序）再按名排序进子目录）----
        var items = new List<Item>();
        void AddFs(string root, Func<IStorage> opener, string dst) {
            var fs = new RomFsFileSystem(opener()); Walk(fs, "/", root, dst, opener, items);
        }
        RomfsExtraction.Result patchedRomfs = null;
        // 程序 NCA 没有资源段（第 1 段）的款（#620，数据全在 exefs 里的小游戏）：没有 RomFS，产出空 romfs 目录（空 RomFS 的下游同 #578），
        //   原先照开第 1 段，抛「NCA section 1 does not exist」整次解包失败。只看本体：更新的资源段要叠在本体那段上，本体没有就无从叠
        bool hasRomfs = new Nca(Ks, Where[baseId]()).SectionExists(NcaSectionType.Data);
        if (!aocOnly && !hasRomfs) { Directory.CreateDirectory(Path.Combine(D, "romfs")); Console.WriteLine("程序没有资源分区（RomFS）：按空资源出包"); }
        if (!aocOnly && hasRomfs) {
            Stage = $"资源分区 RomFS（本体 {baseId[..8]}{(patId == null ? "" : " + 更新 " + patId[..8])}）";
            if (patId == null) AddFs("romfs", () => RomfsOpener(IntegrityCheckLevel.ErrorOnInvalid), Path.Combine(D, "romfs"));
            else {
                try { patchedRomfs = RomfsExtraction.Extract(RomfsOpener, Path.Combine(D, "romfs"), patched: true); }
                catch (InvalidDataException e) { throw new SourceError(e.Message); }
            }
        }
        var aocIdx = new List<int>(); var aocRows = new List<string>();
        foreach (Cnmt m in dlc) {
            int idx = (int)(m.TitleId - tid - 0x1000); string did = Cid(m, ContentType.Data);
            if (did == null || !Where.ContainsKey(did)) { Console.WriteLine($"🟡 DLC 序号 {idx}：数据内容不在给的文件里（{(Broken.Count > 0 ? "源文件损坏，已跳过" + BrokenNote() : "只有授权？")}），跳过"); aocRows.Add($"{idx}\t{m.TitleId:x16}\t{m.TitleVersion.Version}\t-1\t0"); continue; }
            Involved.Add(($"DLC 序号 {idx} 数据", did)); Stage = $"DLC 序号 {idx} 数据分区（内容 {did[..8]}）";
            string id2 = did; Func<IStorage> op = () => new Nca(Ks, Where[id2]()).OpenStorage(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
            var part = new List<Item>();   // 先在临时清单里列全：DLC 解不开（缺标题密钥 / 票据时解密结果过不了哈希校验）只丢这一个 DLC、明确报出来，基础游戏照常解
            try { Walk(new RomFsFileSystem(op()), "/", $"aoc/{idx}", Path.Combine(D, "aoc", idx.ToString()), op, part); }
            catch (Exception e) { Console.WriteLine($"🟡 DLC 序号 {idx}：数据分区解不开（{e.GetType().Name}：{e.Message.Split('\n')[0]}），不打包数据，aoc.tsv 记仅授权"); aocRows.Add($"{idx}\t{m.TitleId:x16}\t{m.TitleVersion.Version}\t-1\t0"); continue; }
            aocIdx.Add(idx); items.AddRange(part); aocRows.Add($"{idx}\t{m.TitleId:x16}\t{m.TitleVersion.Version}\t{part.Count}\t{part.Sum(i => i.Size)}");
        }
        // 只差大小写的两个路径：宿主 / iOS 都按客体原名找文件，但 Mac 与 iPhone 的文件系统不分大小写，松散文件会互相覆盖——宁可报红停下也不悄悄丢一个
        var ci = items.GroupBy(i => i.Rel.ToLowerInvariant()).FirstOrDefault(g => g.Count() > 1);
        if (ci != null) { Console.Error.WriteLine($"🔴 资源里有只差大小写的路径：{string.Join(" / ", ci.Select(i => i.Rel))}（文件系统不分大小写，解出来会互相覆盖）"); return 1; }
        long total = 0; foreach (Item it in items) { it.Off = total; total += it.Size; }
        foreach (Item it in items) if (it.Dst != null) Directory.CreateDirectory(Path.GetDirectoryName(it.Dst));
        foreach (Item it in items) if (it.Dst != null && it.Size == 0) File.Create(it.Dst).Dispose();

        // ---- 并行：每卷一个任务，按偏移把重叠的文件片段读出来写进松散文件和分卷 ----
        int nparts = (int)Math.Max(1, (total + PartSize - 1) / PartSize); long chunk = PartSize;   // 不出资源包时也按卷大小分任务
        Stage = "逐文件读出资源（RomFS / DLC）"; var offs = items.Select(i => i.Off).ToArray();
        var opts = new ParallelOptions { MaxDegreeOfParallelism = Math.Min(nparts, Environment.ProcessorCount) };
        var tl = new ThreadLocal<Dictionary<Func<IStorage>, IFileSystem>>(() => new());   // 每线程每个来源一份读视图
        Parallel.For(0, nparts, opts, k => {
            long lo = k * chunk, hi = Math.Min(total, lo + chunk); byte[] buf = new byte[4 << 20];
            int i = Array.BinarySearch(offs, lo); if (i < 0) i = ~i - 1; if (i < 0) i = 0;
            for (; i < items.Count && items[i].Off < hi; i++) {
                Item it = items[i]; if (it.Size == 0) continue;
                long a0 = Math.Max(lo, it.Off), a1 = Math.Min(hi, it.Off + it.Size); if (a1 <= a0) continue;
                using FileStream lf = it.Dst == null ? null : new FileStream(it.Dst, FileMode.OpenOrCreate, FileAccess.Write, FileShare.ReadWrite, 1);
                var map = tl.Value; if (!map.TryGetValue(it.Opener, out var fs)) map[it.Opener] = fs = new RomFsFileSystem(it.Opener());
                var fref = new UniqueRef<IFile>(); fs.OpenFile(ref fref.Ref, it.Path.ToU8Span(), OpenMode.Read).ThrowIfFailure(); IFile src = fref.Get;
                if (lf != null) lf.Position = a0 - it.Off;
                for (long p = a0; p < a1;) {
                    int want = (int)Math.Min(buf.Length, a1 - p); long got;
                    try { src.Read(out got, p - it.Off, buf.AsSpan(0, want), ReadOption.None).ThrowIfFailure(); }
                    catch (Exception x) when (x is not ReadPlace) { throw new ReadPlace($"文件 {it.Rel}，文件内偏移 {p - it.Off}（读 {want} 字节）", x); }
                    if (got <= 0) throw new IOException($"读不出 {it.Rel} @{p - it.Off}");
                    lf?.Write(buf, 0, (int)got); p += got;
                }
                fref.Destroy();
            }
        });
        if (aocOnly) {
            File.WriteAllText(Path.Combine(D, "aoc.tsv"), "idx\ttitle_id\tversion\tfiles\tbytes\n" + string.Concat(aocRows.Select(r => r + "\n")));
            Console.WriteLine($"🟢 追加内容：程序号 {tid:x16}；清单里 {dlc.Count} 个，解出 {aocIdx.Count} 个（{items.Sum(i => i.Size) >> 20} MB）{string.Concat(aocRows.Select(r => "；" + r.Split('\t')[1]))}；{(DateTime.UtcNow - t0).TotalSeconds:F0} 秒");
            return 0;
        }
        if (aocIndex) File.WriteAllText(Path.Combine(D, "aoc.tsv"), "idx\ttitle_id\tversion\tfiles\tbytes\n" + string.Concat(aocRows.Select(r => r + "\n")));
        WriteResourceManifest(Path.Combine(D, "unpack.tsv"), $"title_id\t{pid:x16}\nname\t{name}\nname_zh\t{nameZh}\ndisplay_version\t{dver}\n{vers}{multi}builds\t{string.Join(' ', builds)}\naoc\t{string.Join(',', aocIdx)}\n", patchedRomfs);
        int nromfs = patchedRomfs?.Files ?? items.Count(i => i.Rel.StartsWith("romfs/"));
        long romfsBytes = patchedRomfs?.Bytes ?? items.Where(i => i.Rel.StartsWith("romfs/")).Sum(i => i.Size);
        Console.WriteLine($"🟢 解包：{name}（{dver}）；exefs {string.Join(' ', builds.Select(b => b.Split(':')[0]))}；romfs {nromfs} 个文件 {romfsBytes >> 20} MB；DLC 解出 {aocIdx.Count} 个"
            + $"；{(DateTime.UtcNow - t0).TotalSeconds:F0} 秒，{Math.Max(opts.MaxDegreeOfParallelism, patchedRomfs?.Parallelism ?? 1)} 路并行");
        return 0;
    }

    internal static void WriteResourceManifest(string path, string contents, RomfsExtraction.Result romfs) {
        File.WriteAllText(path, contents + (romfs?.Manifest ?? ""));
        if (romfs?.Warning is string warning) Console.WriteLine(warning);
    }

    class Item { public string Rel, Path, Dst; public long Size, Off; public Func<IStorage> Opener; }
    static void Walk(IFileSystem fs, string dir, string root, string dst, Func<IStorage> opener, List<Item> items) {
        var files = new List<DirectoryEntryEx>(); var dirs = new List<string>();
        foreach (DirectoryEntryEx e in fs.EnumerateEntries(dir, "*", SearchOptions.Default)) { if (e.Type == DirectoryEntryType.Directory) dirs.Add(e.Name); else files.Add(e); }
        foreach (var e in files.OrderBy(e => e.Name, StringComparer.Ordinal)) {
            string rel = (dir + e.Name).TrimStart('/');
            items.Add(new Item { Rel = root + "/" + rel, Path = dir + e.Name, Dst = Path.Combine(dst, rel), Size = e.Size, Opener = opener });
        }
        foreach (string d in dirs.OrderBy(d => d, StringComparer.Ordinal)) Walk(fs, dir + d + "/", root, dst, opener, items);
    }
    // 源文件建索引：卡带镜像（xci / xcz）取安全分区（HFS0），安装包（nsp / nsz）是 PFS0——按内容认，不看扩展名；
    //   .nca 直接用，.ncz 还原成原 NCA（同一内容一个共享实例）；通用票据里的标题密钥导入密钥集
    static readonly Dictionary<string, NczCore> NczCores = new();
    static void Add(string id, string src, Func<IStorage> open) {
        if (!Copies.TryGetValue(id, out var list)) Copies[id] = list = new();
        list.Add((src, open));
    }
    static void Index(string src, bool inspect = false) {
        // 长度取打开后的流（跟随符号链接）：FileInfo(src).Length 在 Unix 上是链接自身的长度（10-26 Downloads 里指向移动硬盘的链接全当成非卡带镜像）
        string fn = Path.GetFileName(src); bool xci = false; long len;
        using (var fh = File.OpenRead(src)) {
            len = fh.Length;
            if (len == 0) throw new SourceError($"{fn} 是 0 字节：源文件是空的（拷贝 / 下载没完成），换一份完整的");
            byte[] m = new byte[4]; if (len >= 0x104) { fh.Position = 0x100; fh.ReadExactly(m); xci = m.AsSpan().SequenceEqual("HEAD"u8); } }
        // 内容表：卡带镜像自己解安全分区的 HFS0（Hfs0.cs：不经 LibHac 的前段哈希核对，对不上的下面改核 NCA 头签名），安装包走 LibHac PFS0
        var ents = new List<(string Name, long Size, Func<IStorage> Open, bool HashOk)>();
        try {
            if (xci) {
                foreach (var h in SecureEntries(src)) { long o = h.Offset, sz = h.Size; ents.Add((h.Name, sz, () => new SubStorage(new LocalStorage(src, FileAccess.Read), o, sz), h.HashOk)); }
            } else {
                Func<IFileSystem> openFs = () => { var pfs = new PartitionFileSystem(); pfs.Initialize(new LocalStorage(src, FileAccess.Read)).ThrowIfFailure(); return pfs; };
                IFileSystem fs0 = openFs();
                foreach (DirectoryEntryEx e in fs0.EnumerateEntries("*", SearchOptions.Default)) {
                    string path = e.FullPath;
                    ents.Add((e.Name, e.Size, () => { IFileSystem fs = openFs(); using var f = new UniqueRef<IFile>(); fs.OpenFile(ref f.Ref, path.ToU8Span(), OpenMode.Read).ThrowIfFailure(); return f.Release().AsStorage(); }, true));
                }
            }
        }
        catch (Exception e) when (e is InvalidDataException || e is HorizonResultException || e is EndOfStreamException) {
            throw new SourceError(xci ? $"{fn} 是卡带镜像（0x100 处有 HEAD），但分区表打不开（文件坏了或密钥不对）：{e.Message.Split('\n')[0]}"
                                      : $"{fn} 既不是卡带镜像（0x100 处没有 HEAD）也不是安装包（PFS0），或分区表坏了：{e.Message.Split('\n')[0]}"); }
        bool confirmedTruncation = false;
        var truncated = new List<string>(); var strange = new List<string>(); var signed = new List<string>(); var badsig = new List<string>();
        foreach (var e in ents) {
            if (e.Name.EndsWith(".tik", StringComparison.OrdinalIgnoreCase)) {
                byte[] t = e.Size is > 0 and < (1 << 20) ? new byte[e.Size] : null;
                if (t == null || e.Open().Read(0, t).IsFailure() || t.Length < 0x2c0 || t[0x281] != 0) { Console.Error.WriteLine($"【红】{e.Name} 不是通用票据，跳过"); continue; }
                // 同一张票据可能在卡带 + 安装包里各有一份：重复导入不算错，跳过即可
                try { Ks.ExternalKeySet.Add(new RightsId(t.AsSpan(0x2a0, 0x10)), new AccessKey(t.AsSpan(0x180, 0x10))).ThrowIfFailure(); } catch (Exception) { }
            } else if (e.Name.EndsWith(".nca", StringComparison.OrdinalIgnoreCase) || e.Name.EndsWith(".ncz", StringComparison.OrdinalIgnoreCase)) {
                // 内容文件必须叫「32 位内容号 + .nca/.ncz」。名字不合规的（手工改名、转换工具加了前缀、只给裸 nca 的小包）跳过并点名，
                //   不抛异常：10-28 #633 实测这里原是 e.Name[..32]，名字短于 32 字符 → ArgumentOutOfRange → 整进程 SIGABRT（rc=134）
                if (!IsContentName(e.Name)) { strange.Add(e.Name); continue; }
                string id = e.Name[..32].ToLowerInvariant(); Func<IStorage> raw = e.Open;
                // 截断核对：内容的最后一个字节要读得到（10-26 一款第一方 RPG 1.47 GB 的卡带镜像声明 6.27 GB，原先在解清单时抛 OutOfRange 调用栈）
                byte[] last = new byte[1];
                if (e.Size > 0) {
                    var read = raw().Read(e.Size - 1, last);
                    if (read.IsFailure()) {
                        confirmedTruncation |= ResultFs.OutOfRange.Includes(read);
                        truncated.Add(e.Name);
                        continue;
                    }
                }
                Func<IStorage> content = raw;
                if (e.Name.EndsWith(".ncz", StringComparison.OrdinalIgnoreCase)) {
                    string key = src + "\0" + e.Name;
                    content = () => { NczCore c; lock (NczCores) { if (!NczCores.TryGetValue(key, out c)) NczCores[key] = c = new NczCore(raw(), e.Name); } return new NczStorage(c); };
                }
                // HFS0 前段哈希对不上（整合版塞进来的内容）：改核 NCA——头签名有效，或各段内容哈希全部核过（整合工具改成标准加密时会改 NCA 头、签名随之失效，
                //   内容仍完整，沙排3 那 30 个即此），照用；都不过才当坏文件跳过并点名
                if (!e.HashOk) {
                    bool ok;
                    try {
                        var nca = new Nca(Ks, content());
                        ok = nca.VerifyHeaderSignature() == Validity.Valid;
                        if (!ok) { ok = true; for (int sct = 0; sct < 4; sct++) if (nca.SectionExists(sct) && nca.VerifySection(sct) != Validity.Valid) { ok = false; break; } }
                    } catch (Exception error) when (!inspect || error is not IOException io || !DiskFull(io)) { ok = false; }
                    if (!ok) { badsig.Add(e.Name); continue; }
                    signed.Add(e.Name);
                }
                Add(id, src, content);
            }
        }
        if (signed.Count > 0)
            Console.WriteLine($"🟡 {fn} 安全分区 {signed.Count} 个内容的 HFS0 前段哈希与分区表不符（整合版常见：塞进来的内容没重算），已按 NCA 头签名或各段内容哈希核过照用（如 {string.Join(", ", signed.Take(3))}）");
        if (badsig.Count > 0) {
            string m = $"{fn} 安全分区 {badsig.Count} 个内容 HFS0 前段哈希不符、NCA 头签名与内容哈希也核不过（如 {string.Join(", ", badsig.Take(3))}；缺标题密钥或内容被改过）";
            Broken.Add(m); Console.WriteLine($"🟡 源文件损坏，已跳过：{m}");
        }
        if (strange.Count > 0)
            Console.WriteLine($"🟡 {fn} 里 {strange.Count} 个内容文件名字不是「32 位内容号 + .nca/.ncz」（如 {strange[0]}），跳过（认不出内容号就对不上清单）");
        if (truncated.Count > 0) {   // 只跳过被截断的那几个内容（同文件里完整的内容照用，如 DLC 的清单）；被跳过的若是本体 / 更新要的，下面照样报红
            string m = $"{fn} 被截断：{truncated.Count} 个内容超出文件末尾（文件 {len / (double)(1L << 30):F2} GB；如 {string.Join(", ", truncated.Take(3))}），源文件不完整，换一份完整的";
            if (inspect && confirmedTruncation) Console.WriteLine("【内容截断】");
            Broken.Add(m); Console.WriteLine($"🟡 源文件损坏，已跳过被截断的内容：{m}");
        }
    }
    // 内容文件名：前 32 个字符必须是十六进制内容号（.nca / .ncz 都按这个命名，nsz 也一样）
    static bool IsContentName(string name) {
        if (name.Length < 33) return false;
        for (int i = 0; i < 32; i++) if (!Uri.IsHexDigit(name[i])) return false;
        return true;
    }
    // 标题密钥（title key）：prod.keys 里没有这类条目（实测 0 条），只能从包里的 .tik 或 title.keys 拿。
    //   10-26 普查 6 款「Container metadata could not be decrypted」就是这一路：包里缺 .tik（xci 转 nsp、只给裸 nca、
    //   或个人化票据被跳过），而 title.keys 从来没被读过。规则：prod.keys 同目录有 title.keys 就自动读，也接受 --title-keys=<路径>。
    //   title.keys 每行「<rights id 32 hex>=<title key 32 hex>」，与票据里的 rights id / title key 同一口径（导入同一个 ExternalKeySet）。
    static void LoadTitleKeys(string prodKeysPath, string explicitPath) {
        string p = explicitPath ?? Path.Combine(Path.GetDirectoryName(Path.GetFullPath(prodKeysPath)) ?? ".", "title.keys");
        if (!File.Exists(p)) {
            if (explicitPath != null) throw new UsageError($"--title-keys 指的文件不在：{p}");
            return;
        }
        int ok = 0, bad = 0;
        foreach (string raw in File.ReadLines(p)) {
            string line = raw.Trim();
            if (line.Length == 0 || line[0] == '#') continue;
            int eq = line.IndexOf('=');
            if (eq <= 0 || !TryHex(line[..eq], 16, out byte[] rid) || !TryHex(line[(eq + 1)..], 16, out byte[] tk)) { bad++; continue; }
            try { Ks.ExternalKeySet.Add(new RightsId(rid), new AccessKey(tk)).ThrowIfFailure(); ok++; } catch (Exception) { }
        }
        // 条数与文件名可以打印，密钥值一律不打印
        if (ok > 0 || bad > 0) Console.WriteLine($"🟡 标题密钥：{Path.GetFileName(p)} 里 {ok} 条已载入" + (bad > 0 ? $"，{bad} 行格式不对跳过" : ""));
    }
    static bool TryHex(string s, int bytes, out byte[] value) {
        value = null; s = s.Trim();
        if (s.Length != bytes * 2) return false;
        var v = new byte[bytes];
        for (int i = 0; i < bytes; i++) {
            int hi = HexVal(s[i * 2]), lo = HexVal(s[i * 2 + 1]);
            if (hi < 0 || lo < 0) return false;
            v[i] = (byte)(hi << 4 | lo);
        }
        value = v; return true;
    }
    static int HexVal(char c) => c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
    static byte[] ReadAll(IFileSystem fs, string path) {
        using var f = new UniqueRef<IFile>(); if (fs.OpenFile(ref f.Ref, path.ToU8Span(), OpenMode.Read).IsFailure()) return null;
        f.Get.GetSize(out long n).ThrowIfFailure(); byte[] v = new byte[n]; f.Get.Read(out _, 0, v, ReadOption.None).ThrowIfFailure(); return v;
    }
    // 图标语言：简体中文 → 美式英文 → 其余（10-20 维护者：App 图标用游戏自己的，中文优先）
    static readonly string[] IconLangs = { "SimplifiedChinese", "AmericanEnglish", "BritishEnglish", "Japanese", "French", "German", "LatinAmericanSpanish", "Spanish", "Italian",
                                           "Dutch", "CanadianFrench", "Portuguese", "Russian", "Korean", "TraditionalChinese", "BrazilianPortuguese" };
    // 游戏名：NACP 开头 16 个语言条目各 0x300 字节（名 0x200 + 发行商 0x100），取第一个非空；新 SDK 把这 0x3000 字节压成「u16 长度 + raw deflate」、解开是 32 × 0x300（上游 nx_extract 同法）
    // lang：0 美式英语 … 13 繁体中文、14 简体中文；该语言没填返回 null，lang<0 = 第一个非空
    static string TitleName(byte[] nacp, int lang) {
        byte[] t = nacp; int n = nacp[0] | nacp[1] << 8;
        if (n > 0 && n <= 0x2ffe) try {
            using var z = new System.IO.Compression.DeflateStream(new MemoryStream(nacp, 2, n), System.IO.Compression.CompressionMode.Decompress);
            var m = new MemoryStream(); z.CopyTo(m); if (m.Length == 0x6000) t = m.ToArray();
        } catch (InvalidDataException) { }
        for (int i = 0; i < (t == nacp ? 16 : 32); i++) {
            if (lang >= 0 && i != lang) continue;
            int z = Array.IndexOf(t, (byte)0, i * 0x300, 0x200), len = (z < 0 ? i * 0x300 + 0x200 : z) - i * 0x300;
            if (len > 0) return Encoding.UTF8.GetString(t, i * 0x300, len);
        }
        return lang >= 0 ? null : "";
    }
}
