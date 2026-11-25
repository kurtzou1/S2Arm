// galplay：录像 → [通用宽屏包装层] → NxRenderer（Metal），指定上屏帧读回存 PNG（RGBA8）。
// 用法：galplay <gal.rec> <输出目录> [--widen <宽高比> [--game-wide]] [--frames 10,20,30] [--skip-compat] [--probe <帧>:<贴图号>:<x>,<y>]
//   --ref：双后端对拍——同一录像同步回放进参照渲染器（Ryujinx Vulkan 后端 @ MoltenVK，tests/visual/refvk），指定帧两边上屏图逐像素比，写 ref_<帧>.png、diff_<帧>.png，报每帧差异像素占比与 PSNR（不能和 --widen 同用）；
//     同时比两边报告的计数器值（ReportCounter 结果按录像事件号配对），报「计数器对拍」一行，不等的前几个写进报告
//   --depth <帧>：该帧上屏时，把画面形状（宽高比 ≥ 1.7）的深度附件里本帧绘制次数最多的那张（场景深度；没有画面形状的才在全部里挑）连同它最近一次清屏值导出 depth_<帧>.f32 + depth_<帧>.json（宽屏露空量化用，tests/visual/widen_holes.py 读）
//   --probe：该帧里每次绘制后，若颜色目标 0 是该贴图（贴图号 0 = 任意目标，坐标按目标客体尺寸等比换算），读回客体坐标 (x,y) 处像素（放宽时按居中偏移换算）写 probe.tsv，基线与加宽各跑一遍对齐找第一处分歧
//   --time <宽>x<高>[@a-b]（0x0 = 任意尺寸目标）（只计第 a..b 帧；每次命中读回两次，整份录像会很慢）：每次画到该尺寸颜色目标 0 的绘制，前后各读回一次目标（把 GPU 排空 / 等这一条画完），量单次绘制墙钟（含一次小读回，约 0.1 ms 级），写 time.tsv（记录号、帧、程序号、目标号、毫秒）
//   --spv-sub <目录>：程序 SPIR-V 按原字节键换成 <目录>/<键>.spv（同一录像对拍两种翻译结果；报告记替换了几个阶段）
//   --diff [a-b]（要配 --ref）：逐绘制对拍——第 a..b 帧（缺省全部）每个渲染通道结束（换目标 / 上屏前）两边读回全部颜色目标与深度逐像素比，
//     分歧写 diff.tsv、前 8 处存 diff_first_<k>_{ours,ref,mask}.png，报第一处分歧（记录、帧、程序、目标、差异像素、最大差）；有分歧退出码 4。
//     --diff-draw a-b：第 a..b 条记录里每次绘制之后都比（定位通道内第一处分歧的绘制）；--diff-tol <级>（颜色，缺省 1）/ --diff-dtol <16 位级>（深度，缺省 1）；
//     --diff-nosync：不把参照结果写回我方（缺省写回，每处分歧只算在引入它的通道上）；--diff-all：每次比对都写一行带两边哈希（同后端两次回放自比噪声用）。见 DrawDiff.cs
//   --cbuf <程序,…>:<绑定>（配 --trace）：该帧这些程序每次绘制的该常量绑定内容（前 4096 字节，按 vec4）与采样贴图写 cbuf.tsv
//   --capcheck <帧>：拷屏贴回一致性（CapCheck.cs）：该帧每次「拷屏贴图画回屏幕目标」的改动像素与拷屏时原位比，不符 > 1% 红（退出码 6）；--capcheck-selftest 只跑合成画面正对照
//   --layout-wide：同产品 s2a_widen_layout()（配 --game-wide；第二层启用了界面布局尺寸点 lytsz）：读改写矩阵的界面层局部剪裁不收进中间
//   --trace <帧>：该帧每次绘制的换算方式、视口 / 裁剪换算前后、外推判定、采样贴图尺寸写 trace.tsv（要配 --widen）
//   --drawbox <贴图号>：配 --trace，该帧每次画到这张目标的绘制改动的像素包围盒写 drawbox.tsv（每次绘制前读回目标、与上一次比：两次之间的改动记在上一次绘制名下）；
//     同一录像 k=1 / 放宽各放一遍，tests/visual/drawbox_cmp.py 逐绘制比屏幕位置（放宽 = k=1 平移居中量）——特效 / 粒子 / 小目标错位整帧差分抓不到
//   --until <帧>：放到第 N 次上屏即停（配 NXGAL_TRACE_ENC=1 等进程级统计：放到 N−1 与 N 两次相减 = 第 N 帧单帧）
// 输出：present_<帧>.png、report.txt（回放条数 / 错误 / 宽屏统计与红计数）。退出码：0 = 回放无错误且宽屏红计数（序章补内容除外）0；1 = 有；2 = 用法 / 录像错。
using NxGal;
using RyuJudge.GalRec;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using S2Arm.Gfx.Widen;
using S2Arm.Gfx.Widen.Gal;
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;

static class P
{
    static int Main(string[] a)
    {
        Console.OutputEncoding = Encoding.UTF8;
        // --selftest-vraw <目录>：参照端吃原始位顶点输入的单测（RefRawVertexTest.cs；目录里是 graphics/metal 编出的 t_vraw/vs.spv、fs.spv）
        if (a.Length >= 1 && a[0] == "--selftest-ref-d24") return RefD24Test.Run();   // 参照端 D24 深度上传 / 读回往返（RefD24Test.cs）
        if (a.Length >= 2 && a[0] == "--selftest-vraw") return RefRawVertexTest.Run(a[1], a.Contains("--anti-all"));
        if (a.Length == 3 && a[0] == "--selftest-vraw-anti") return RefRawVertexTest.Anti(a[1], int.Parse(a[2]));
        if (a.Contains("--capcheck-selftest")) { var sl = new StringBuilder(); int sr = CapCheck.SelfTest(sl); Console.Write(sl); return sr; }
        if (a.Length < 2) { Console.Error.WriteLine("用法：galplay <gal.rec> <输出目录> [--widen 宽高比] [--frames a,b] [--skip-compat]"); return 2; }
        string rec = a[0], outDir = a[1]; Directory.CreateDirectory(outDir);
        float widen = Opt(a, "--widen") is string ws ? float.Parse(ws) : 0;
        var frames = new HashSet<long>((Opt(a, "--frames") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries).Select(long.Parse));
        var sw = Stopwatch.StartNew();
        // --spv-sub <目录>：程序的 SPIR-V 按原字节键（SHA-256 前 8 字节小端，同 gal_spv_hash）换成 <目录>/<键>.spv——同一录像对拍两种翻译结果（翻译器改动的逐像素验收）
        long subN = 0;
        if (Opt(a, "--spv-sub") is string subDir)
        {
            R.ShaderSubstitute = b =>
            {
                string p = Path.Combine(subDir, System.Buffers.Binary.BinaryPrimitives.ReadUInt64LittleEndian(System.Security.Cryptography.SHA256.HashData(b)).ToString("x16") + ".spv");
                if (!File.Exists(p)) return b;
                subN++;
                return File.ReadAllBytes(p);
            };
        }
        using GalRecFile f = GalRecFile.Load(rec);
        var nx = new NxRenderer(); nx.Initialize(GraphicsDebugLevel.None);
        int psoOpen = -2;   // -2 = 没登记管线归档
        // 包内着色器局的录像：程序走 LoadProgramBinary，不开离线库时我方建不出程序、绘制全不执行（10-20 画幅线）。S2A_SHADER_PACK=<着色器包目录>（含 gal.idx / gal.shards / 各片 metallib）同运行时 graphics/loop/ShaderPack.cs 开库
        if (Environment.GetEnvironmentVariable("S2A_SHADER_PACK") is string spk && File.Exists(Path.Combine(spk, "gal.idx")))
        {
            string le = NxProgram.OpenLibrary(spk);
            Console.WriteLine(le == null ? $"着色器包离线库已开：{spk}" : $"【红】着色器包开离线库失败：{le}");
            // 包里有管线归档（gal_pso.idx）就同运行时一样登记（graphics/loop/ShaderPack.cs）：管线先按描述查归档、查不到现建；收尾报命中 / 现建（归档 A/B 对拍：管线确实来自归档）
            if (File.Exists(Path.Combine(spk, "gal_pso.idx"))) { psoOpen = NxProgram.OpenPsoArchive(spk); Console.WriteLine($"着色器包管线归档登记：{psoOpen}（0 已登记 / 1 没有本机架构 × 系统版本的归档 / -1 索引坏）"); }
        }
        // --ui-noscissor：不开深度测的绘制（界面 / 二维）裁剪放成整张（闭环 ⑩：与正常回放的出图差 = 界面裁剪切掉的像素）
        if (a.Contains("--ui-noscissor")) WidenRenderer.IgnoreOutScissor = true;
        bool cam = a.Contains("--cam") || a.Contains("--cam-off");   // 镜头位姿：不放宽的观察包装层（16:9），每帧打一行位姿；--cam-off 关掉识别对拍开销
        if (a.Contains("--cam-off")) CameraTrack.Enabled = false; else if (cam) CameraTrack.Profile = true;
        // --game-wide：同产品路径 services/aot/Compose.cs「游戏自己出宽图（第二层启用）」—— 包装层只管界面层、不放宽贴图
        WidenRenderer wr = widen > 0 ? new WidenRenderer(nx, widen, a.Contains("--game-wide")) : cam ? new WidenRenderer(nx, 16f / 9f) : null;
        if (wr != null && a.Contains("--layout-wide")) wr.LayoutWide = true;   // 同产品 s2a_widen_layout()：第二层启用了界面布局尺寸点（lytsz）
        if (wr != null) wr.CpuPeek = nx.S2APeekBufferCpu;   // 同产品：几何判定只读 CPU 侧、不等 GPU
        // --widen-check：影子对照（tests/visual/widen_scanbench/WidenOldModel.cs）——旧「上传即整段改写」模型逐绘制比这次读到的字节，报漏改 / 多改（宽屏门禁判漏改 0）
        WidenOldModel chk = wr != null && a.Contains("--widen-check") ? new WidenOldModel(widen) : null;
        if (chk != null) wr.State.Check = chk;
        IRenderer target = (IRenderer)wr ?? nx;
        var pn = new GalRecReplayer(target);
        // --typed-vertex：我方也按当次顶点格式把原始位顶点输入改回类型声明（同参照端 RefRawVertexHook），配 NXGAL_VPULL=0 走顶点描述符——
        //   同一份原始位录像上量「旧口径（按类型 + 顶点描述符）」的出图与 GPU 时间，与原样回放（原始位 + 自取）只差顶点取数这一个变量
        RefRawVertexHook typedHook = a.Contains("--typed-vertex") ? new RefRawVertexHook(null) : null;
        if (typedHook != null) pn.Hook = typedHook;
        bool useRef = a.Contains("--ref");
        bool negVp = a.Contains("--neg-vp169"); long negVpN = 0;
        // 计数开着不许比像素（10-21 起计数缺省关、与出货一致）：片元含计数原子写就改苹果 GPU 上丢弃后隐式导数绘制的结果（docs/坑记录.md）
        if (Environment.GetEnvironmentVariable("NXGAL_BOUNDS_COUNT") == "1" && (useRef || a.Contains("--diff"))) { Console.WriteLine("【红】计数开着（NXGAL_BOUNDS_COUNT=1）不许比像素（--ref / --diff）：计数局只读越界计数"); return 3; }
        if (useRef && wr != null) { Console.Error.WriteLine("--ref 不能和 --widen 同用（参照是 16:9 原样）"); return 2; }
        // 参照端的着色器同样加循环上限（RefLoopGuard）：10-21 参照端跑八方2 坏常量循环没有上限，两次整卡重置（gpuEvent-galplay 08:02 / 08:20）
        GalRecReplayer pref = useRef ? new GalRecReplayer(RefVk.RefVkRenderer.Create()) { ShaderFilter = RefLoopGuard.Guard } : null;
        // 参照端吃原始位顶点输入（Ryujinx 补丁 vattr-raw 之后录的录像）：按当次顶点格式把 s2a_raw<位置> 改回类型声明（RefRawVertex.cs）
        RefRawVertexHook rawHook = pref != null ? new RefRawVertexHook(RefLoopGuard.Guard) : null;
        if (pref != null) pref.Hook = rawHook;
        if (pref != null && !f.Capabilities.SupportsDepthClipControl) pref.Target.Pipeline.SetDepthMode(DepthMode.ZeroToOne);
        long errR = 0; var cmp = new StringBuilder(); var errRSamples = new List<string>();
        DrawDiff dd = null; string ddPre = ""; bool ddSplit = a.Contains("--diff-split");
        if (a.Contains("--diff"))
        {
            if (pref == null) { Console.Error.WriteLine("--diff 要配 --ref"); return 2; }
            dd = new DrawDiff(outDir, pn, pref) { Resync = !a.Contains("--diff-nosync"), All = a.Contains("--diff-all") };
            if (Opt(a, "--diff") is string dfr && dfr.Length > 0 && char.IsDigit(dfr[0])) { string[] q = dfr.Split('-'); dd.FrameLo = long.Parse(q[0]); dd.FrameHi = q.Length > 1 && q[1].Length > 0 ? long.Parse(q[1]) : dd.FrameLo; }
            if (Opt(a, "--diff-draw") is string ddr) { string[] q = ddr.Split('-'); dd.DrawLo = long.Parse(q[0]); dd.DrawHi = long.Parse(q[1]); }
            if (Opt(a, "--diff-buf") is string dbf && dbf.Length > 0) dd.BufRec = long.Parse(dbf);   // --diff-buf <记录>：该记录之前当前绑着的常量 / 存储缓冲两边逐字节比（diff_buf.txt）
            if (Opt(a, "--diff-tex") is string dtx) { string[] q = dtx.Split(':'); dd.TexRec = long.Parse(q[0]); dd.TexIds = q[1].Split(',').Select(uint.Parse).ToArray(); }   // --diff-tex <记录>:<贴图号,…>：该记录前两边逐层逐级比贴图内容（diff_tex.txt）
            if (Opt(a, "--diff-tol") is string dt) dd.Tol = double.Parse(dt, System.Globalization.CultureInfo.InvariantCulture);
            if (Opt(a, "--diff-dtol") is string ddt) dd.DTol = double.Parse(ddt, System.Globalization.CultureInfo.InvariantCulture);
            // 录像里按二进制建的程序（包内着色器局录的）参照建不出、绘制不执行，上屏图两边却可能逐位相同——假通过（10-20 画幅线），先点名
            long nSpv = 0, nBin = 0; foreach (GalRecRecord r0 in f.Records()) { if (r0.Op == 0x106) nSpv++; else if (r0.Op == 0x111) nBin++; }
            ddPre = $"录像程序：SPIR-V 建 {nSpv} 支、二进制载入 {nBin} 支" + (nBin > 0 ? "【红】（二进制程序参照建不出，对拍无效：要用空着色器包 S2A_SHADER_PACK=<空目录> 录）" : "") + "\n";
        }
        try { pn.CheckCompatible(f); }
        catch (GalRecIncompatibleException e) { if (!a.Contains("--skip-compat")) { Console.WriteLine($"录像与 NxRenderer 不兼容：{e.Message}"); return 2; } Console.WriteLine($"[注意] 能力表不符仍放：{e.Message}"); }
        string[] pr = Opt(a, "--probe")?.Split(':'); long prFrame = pr != null ? long.Parse(pr[0]) : -1; uint prTex = pr != null ? uint.Parse(pr[1]) : 0;
        int prX = pr != null ? int.Parse(pr[2].Split(',')[0]) : 0, prY = pr != null ? int.Parse(pr[2].Split(',')[1]) : 0; uint rt0 = 0, prog = 0; var probe = new StringBuilder();
        long depthFrame = Opt(a, "--depth") is string dfs ? long.Parse(dfs) : -1; uint ds0 = 0;
        CapCheck cap = Opt(a, "--capcheck") is string ccs ? new CapCheck(long.Parse(ccs), id => (pn.Obj<ITexture>(id) is WidenTexture cw ? cw.Inner : pn.Obj<ITexture>(id)) as NxTexture) : null;
        string[] dmo = Opt(a, "--dump")?.Split(':'); long dumpFrame = dmo != null ? long.Parse(dmo[0]) : -1; uint[] dumpTex = dmo?[1].Split(',').Select(uint.Parse).ToArray();
        // --stop-rec N：回放完第 N 条记录（两后端都放完）就按 --dump 的贴图号存图并收工——同一遍里逐次绘制二分两后端第一处分歧（10-20 丝之歌）
        long stopRec = Opt(a, "--stop-rec") is string srs ? long.Parse(srs) : -1;
        var dsDraws = new Dictionary<uint, int>(); var dsClear = new Dictionary<uint, float>(); var dsSnap = new Dictionary<uint, (byte[] data, int draws)>();
        long presents = 0, recs = 0, errs = 0, nReport = 0, nReset = 0; WidenRed redProlog = default; var errSamples = new List<string>(); var log = new StringBuilder(); var bands = new StringBuilder();
        var perFrame = new StringBuilder("帧\t绘制\t换目标\n"); long fDraws = 0, fRts = 0;
        // 录像原始出图参数（宽屏门禁期望用，只读录像、不经包装层）：上屏贴图的客体尺寸 + 裁剪（与 gal_present.m 同口径：左右都 0 = 整宽）+ 拉伸 + 宽高比，变化次数与首几次所在出图号
        (int, int, int, int, int, int, bool, float, float) rawLast = default; long rawChg = 0; var rawChgAt = new List<long>();
        long until = Opt(a, "--until") is string us ? long.Parse(us) : -1;
        string? progress = Environment.GetEnvironmentVariable("GALPLAY_PROGRESS") is string gp && gp.Length > 0 ? gp : null;   // 每次上屏把序号写这里（进展心跳）
        // --trace <帧>：该帧每次绘制记一行（记录号、程序、颜色目标 0 与尺寸、包装层换算方式、视口 0 / 裁剪 0 换算前 → 后）写 trace.tsv（要配 --widen）
        long traceFrame = Opt(a, "--trace") is string tfs ? long.Parse(tfs) : -1; var trace = new StringBuilder("记录\t程序\t目标\t方式\t\t目标状态\t视口\t裁剪\t外推\t采样\n");
        // --cbuf <程序,…>:<绑定>（-1 = 全部已绑的）：配 --trace，该帧这些程序的每次绘制把该常量绑定的内容（前 4096 字节）按 vec4 写进 cbuf.tsv，并记采样贴图（号:宽x高）
        string[] cbo = Opt(a, "--cbuf")?.Split(':'); var cbProgs = cbo != null ? new HashSet<uint>(cbo[0].Split(',').Select(uint.Parse)) : null; int cbBind = cbo != null ? int.Parse(cbo[1]) : 0; var cbuf = new StringBuilder();
        if (wr != null && traceFrame > 0) wr.TraceTexName = t => pn.IdOf(t).ToString();
        uint dbT = Opt(a, "--drawbox") is string dbs ? uint.Parse(dbs) : 0; byte[] dbPrev = null; long dbRec = -1; uint dbProg = 0; var dbox = new StringBuilder("记录\t程序\tx0\tx1\ty0\ty1\t改动像素\t宽\t高\n");
        byte[] DbSnap(out int w, out int h)
        {
            w = h = 0; ITexture q = pn.Obj<ITexture>(dbT); if (q is WidenTexture qw) q = qw.Inner;
            if (q is not NxTexture qn) return null;
            w = qn.Info.Width; h = qn.Info.Height; using (var g = qn.GetData(0, 0)) return g.Get().ToArray();
        }
        void DbStep()
        {
            byte[] cur = DbSnap(out int w, out int h);
            if (cur != null && dbPrev != null && dbRec >= 0 && cur.Length == dbPrev.Length && w * h > 0)
            {
                int bpp = cur.Length / (w * h), x0 = int.MaxValue, x1 = -1, y0 = int.MaxValue, y1 = -1; long n = 0;
                for (int y = 0; y < h; y++)
                    for (int x = 0; x < w; x++)
                    {
                        int o = (y * w + x) * bpp;
                        if (cur.AsSpan(o, bpp).SequenceEqual(dbPrev.AsSpan(o, bpp))) continue;
                        n++; if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
                    }
                dbox.Append($"{dbRec}\t{dbProg}\t{(n > 0 ? x0 : -1)}\t{x1 + 1}\t{(n > 0 ? y0 : -1)}\t{y1 + 1}\t{n}\t{w}\t{h}\n");
                // 改动像素位图（drawmask/<记录>.bin，按行 1 位 / 像素）：一次绘制画很多小东西（粒子 / 火苗合批）时包围盒看不出里面谁挪了，比位图重合度
                if (n > 0)
                {
                    var bits = new byte[(w * h + 7) / 8];
                    for (int i = 0; i < w * h; i++) if (!cur.AsSpan(i * bpp, bpp).SequenceEqual(dbPrev.AsSpan(i * bpp, bpp))) bits[i >> 3] |= (byte)(1 << (i & 7));
                    Directory.CreateDirectory(Path.Combine(outDir, "drawmask")); File.WriteAllBytes(Path.Combine(outDir, "drawmask", $"{dbRec}.bin"), bits);
                }
            }
            dbPrev = cur;
        }
        if (wr != null && traceFrame > 0) wr.DrawTrace = line =>
        {
            if (presents + 1 != traceFrame) return;
            if (cbProgs != null && cbProgs.Contains(prog))
            for (int bi = cbBind < 0 ? 0 : cbBind; bi <= (cbBind < 0 ? 63 : cbBind); bi++)
            if (wr.TryUniform(bi, out ulong cb, out int co, out int cs))
            {
                int n = Math.Min(cs, 4096);
                byte[] d; using (var g = nx.GetBufferData(System.Runtime.CompilerServices.Unsafe.As<ulong, BufferHandle>(ref cb), co, n)) d = g.Get().ToArray();
                cbuf.Append($"# 记录 {recs} 程序 {prog} 目标 {rt0} 绑定 {bi} 缓冲 {cb} 偏移 {co} 长 {cs} 采样 {wr.FragmentTextures()}\n");
                for (int i = 0; i + 16 <= d.Length; i += 16)
                {
                    var f = System.Runtime.InteropServices.MemoryMarshal.Cast<byte, float>(d.AsSpan(i, 16));
                    var u = System.Runtime.InteropServices.MemoryMarshal.Cast<byte, uint>(d.AsSpan(i, 16));
                    cbuf.Append($"{recs}\t{prog}\t{bi}\tc[{i / 16}]\t{f[0]:G6}\t{f[1]:G6}\t{f[2]:G6}\t{f[3]:G6}\t{u[0]:x8} {u[1]:x8} {u[2]:x8} {u[3]:x8}\n");
                }
            }
            if (dbT != 0 && rt0 == dbT) { DbStep(); dbRec = recs; dbProg = prog; }
            ITexture q = pn.Obj<ITexture>(rt0); if (q is WidenTexture qw) q = qw.Inner;
            trace.Append(recs).Append('\t').Append(prog).Append('\t').Append(rt0).Append(q is NxTexture qn ? $":{qn.Info.Width}x{qn.Info.Height}" : "").Append('\t').Append(line).Append('\n');
        };
        void DumpTex(string tag)
        {
            foreach (uint di in dumpTex)
                foreach ((string side, ITexture dt0) in new[] { ("ours", pn.Obj<ITexture>(di)), ("ref", pref?.Obj<ITexture>(di)) })
                {
                    ITexture dt = dt0 is WidenTexture dw2 ? dw2.Inner : dt0;
                    if (dt == null) continue;
                    TextureCreateInfo di2 = ((NxTexture)(pn.Obj<ITexture>(di) is WidenTexture dw3 ? dw3.Inner : pn.Obj<ITexture>(di))).Info;   // 参照同一建法，尺寸格式取我方
                    byte[] db; using (var g = dt.GetData(0, 0)) db = g.Get().ToArray();
                    File.WriteAllBytes(Path.Combine(outDir, $"dump_{tag}_{di}_{side}.bin"), db);
                    File.WriteAllText(Path.Combine(outDir, $"dump_{tag}_{di}_{side}.json"), $"{{\"w\":{di2.Width},\"h\":{di2.Height},\"stride\":{di2.GetMipStride(0)},\"format\":\"{di2.Format}\",\"bytes\":{db.Length}}}");
                    log.AppendLine($"{tag}：存贴图 {di}（{side}，{di2.Format} {di2.Width}×{di2.Height}）");
                }
        }
        // 正对照（--break-shader [程序号]，自 visual/golden 8b2cd81）：只改我方——对拍段里画得最多的程序，其着色器全部 OpFMul 改成 OpFAdd；参照照原样建。对拍必须报出分歧，否则尺子是瞎的
        uint breakProg = 0;
        if (a.Contains("--break-shader"))
        {
            // 选「对拍帧段里绘制次数最多」的程序（有 --diff 时按其帧段，否则全录像）：整份录像里绑得最多的程序可能根本不在对拍段里画（10-21 暗黑3 程序 101，门禁正对照落空）
            var cnt = new Dictionary<uint, long>(); long bf = 1; uint bcur = 0; bool bcol = false;
            long blo = dd?.FrameLo ?? 1, bhi = dd?.FrameHi ?? long.MaxValue;
            foreach (GalRecRecord r0 in f.Records())
            {
                if (r0.Op == 0x201) { bf++; continue; }
                if (r0.Op == 0x026) { ReadOnlySpan<byte> p0 = f.Payload(r0); if (p0.Length >= 4) bcur = BinaryPrimitives.ReadUInt32LittleEndian(p0); continue; }
                if (r0.Op == 0x029) { ReadOnlySpan<byte> p0 = f.Payload(r0); bcol = p0.Length >= 8 && BinaryPrimitives.ReadUInt32LittleEndian(p0) > 0 && BinaryPrimitives.ReadUInt32LittleEndian(p0[4..]) != 0; continue; }
                // 只数画到颜色目标的绘制：只写深度的程序（阴影图）改坏了，对拍在 D24 深度上看不到（参照 D24 读回不准、不比；10-21 暗黑3 程序 233 改 211 处 0 分歧）
                if (bcur != 0 && bcol && bf >= blo && bf <= bhi && r0.Op is 0x009 or 0x00A or 0x00B or 0x00C or 0x00D or 0x00E) cnt[bcur] = cnt.GetValueOrDefault(bcur) + 1;
            }
            breakProg = Opt(a, "--break-shader") is string bps && bps.Length > 0 && char.IsDigit(bps[0]) ? uint.Parse(bps) : cnt.Count > 0 ? cnt.MaxBy(kv => kv.Value).Key : 0;
            log.AppendLine($"正对照：改坏程序 {breakProg}（帧 {blo}..{(bhi == long.MaxValue ? "末" : bhi.ToString())} 里画 {cnt.GetValueOrDefault(breakProg)} 次）");
        }
        string[] tmo = Opt(a, "--time")?.Split('@'); int[] tm = tmo?[0].Split('x').Select(int.Parse).ToArray();
        long[] tmf = tmo != null && tmo.Length > 1 ? tmo[1].Split('-').Select(long.Parse).ToArray() : new long[] { 1, long.MaxValue }; var times = new StringBuilder(); var progKeys = new Dictionary<uint, string>(); PrimitiveTopology topo = default; var keyTmp = new List<ulong>();
        foreach (GalRecRecord r in f.Records())
        {
            recs++;
            ReadOnlySpan<byte> pl = f.Payload(r);
            uint tid = r.Op == 0x201 && pl.Length >= 4 ? BinaryPrimitives.ReadUInt32LittleEndian(pl) : 0;
            NxTexture tt = null;
            if (tm != null && rt0 != 0 && presents + 1 >= tmf[0] && presents + 1 <= tmf[^1] && r.Op is 0x009 or 0x00A or 0x00B or 0x00C or 0x00D or 0x00E)
            {
                ITexture q = pn.Obj<ITexture>(rt0); if (q is WidenTexture qw) q = qw.Inner;
                if (q is NxTexture qn && (tm[0] == 0 || qn.Info.Width == tm[0] && qn.Info.Height == tm[1])) { tt = qn; using (qn.GetData(0, 0)) { } }   // 排空：之前的命令都画完
            }
            // --depth：深度附件画过之后又被清（ClearRenderTargetDepthStencil）时，清之前存一份——暗黑3 每帧末尾、换走目标前把深度清回 1.0，上屏时读到的全是清屏值（帧率能耗线 10-20 查实：第 3417 条清、写深度绘制在 197–2818 条）
            if (r.Op == 0x005 && presents + 1 == depthFrame && ds0 != 0 && dsDraws.GetValueOrDefault(ds0) > dsSnap.GetValueOrDefault(ds0).draws
                && (pn.Obj<ITexture>(ds0) is WidenTexture sw0 ? sw0.Inner : pn.Obj<ITexture>(ds0)) is NxTexture snx)
                using (var g = snx.GetData(0, 0)) dsSnap[ds0] = (g.Get().ToArray(), dsDraws[ds0]);
            dd?.Before(r.Op, pl, recs, presents + 1, tid);
            cap?.Before(r.Op, pl, presents + 1, rt0, recs, prog);
            if (breakProg != 0 && r.Op == 0x106 && pl.Length >= 4 && BinaryPrimitives.ReadUInt32LittleEndian(pl[^4..]) == breakProg)
            {
                byte[] bp = pl.ToArray(); int nm = 0;
                // OpFMul = 字数 5、操作码 133（0x85）：首字小端 85 00 05 00。全部改成 OpFAdd（只改第一处时可能落在不影响输出的地方：10-21 暗黑3 程序 233 改了一处 0 分歧）
                for (int i = 0; i + 4 <= bp.Length; i++) if (bp[i] == 0x85 && bp[i + 1] == 0 && bp[i + 2] == 5 && bp[i + 3] == 0) { bp[i] = 0x81; nm++; }
                if (nm > 0) log.AppendLine($"正对照：程序 {breakProg} 着色器里 {nm} 处 OpFMul 改成 OpFAdd"); else log.AppendLine($"【红】正对照：程序 {breakProg} 里找不到 OpFMul（没有 SPIR-V？）");
                pl = bp;
            }
            // 反例（--neg-vp169，10-23 怪猎「两侧是游戏画的」判据）：比 16:9 明显宽的视口改成同高 16:9、水平居中——模拟游戏自己出宽图的补丁没生效、
            //   场景按 16:9 画在宽出图区中间；上屏两侧种类必须回到 0（照常判，真机会报未满屏），否则判据放行过度
            if (negVp && r.Op == 0x035 && pl.Length >= 4)
            {
                byte[] vb = pl.ToArray(); int vn = (int)BinaryPrimitives.ReadUInt32LittleEndian(vb), vs = System.Runtime.CompilerServices.Unsafe.SizeOf<Viewport>();
                for (int i = 0; i < vn && 4 + (i + 1) * vs <= vb.Length; i++)
                {
                    Span<byte> e = vb.AsSpan(4 + i * vs);
                    float vx = BinaryPrimitives.ReadSingleLittleEndian(e), vw0 = BinaryPrimitives.ReadSingleLittleEndian(e[8..]), vh0 = Math.Abs(BinaryPrimitives.ReadSingleLittleEndian(e[12..]));
                    if (vh0 > 0 && Math.Abs(vw0) / vh0 > 16f / 9f * 1.05f)
                    {
                        float nw = MathF.CopySign(vh0 * 16f / 9f, vw0);
                        BinaryPrimitives.WriteSingleLittleEndian(e, vx + (vw0 - nw) / 2); BinaryPrimitives.WriteSingleLittleEndian(e[8..], nw); negVpN++;
                    }
                }
                pl = vb;
            }
            long tt0 = Stopwatch.GetTimestamp();
            try { var rr = new R(pl); pn.ReplayOne(r.Op, ref rr); }
            catch (Exception e) { errs++; if (errSamples.Count < 10) errSamples.Add($"#{recs} {f.Name(r.Op)}：{e.GetType().Name} {e.Message}"); }
            if (tt != null)
            {
                using (tt.GetData(0, 0)) { }
                double ms = (Stopwatch.GetTimestamp() - tt0) * 1000.0 / Stopwatch.Frequency;
                if (!progKeys.TryGetValue(prog, out string ks))   // 程序各阶段的键（= 渲染器 stage_hash，GPU 卡死现场按它报）：取程序二进制按记录开头解
                {
                    IProgram po = pn.Obj<IProgram>(prog); ks = "?";
                    if (po is NxProgram np && np.GetBinary() is byte[] bin && WidenIndex.BinaryKeys(bin, keyTmp)) ks = string.Join(",", keyTmp.Select(k => k.ToString("x16")));
                    progKeys[prog] = ks;
                }
                string args = pl.Length >= 8 ? $"{BinaryPrimitives.ReadInt32LittleEndian(pl)},{BinaryPrimitives.ReadInt32LittleEndian(pl[4..])}" : "";   // 绘制前两个参数：顶点 / 索引数、实例数
                times.AppendLine($"{recs}\t{presents + 1}\t{prog}\t{ks}\t{rt0}:{tt.Info.Width}x{tt.Info.Height}\t{f.Name(r.Op)}\t{args}\t{topo}\t{ms:F3}");
            }
            if (pref != null)
            {
                // 录像按我方能力表录（不支持深度裁剪控制，-1..1 深度已编进着色器）；参照若执行 SetDepthMode 会把深度换算做两遍，所以丢掉、保持 ZeroToOne（旧库 10-18 动森阴影贴图坑）
                if (f.Name(r.Op).StartsWith("IPipeline.SetDepthMode") && !f.Capabilities.SupportsDepthClipControl) pref.Target.Pipeline.SetDepthMode(DepthMode.ZeroToOne);
                else try { var rr2 = new R(f.Payload(r)); pref.ReplayOne(r.Op, ref rr2); } catch (Exception e) { errR++; if (errRSamples.Count < 10) errRSamples.Add($"#{recs} {f.Name(r.Op)}：{e.GetType().Name} {e.Message}"); }
            }
            if (recs == stopRec) { DumpTex($"r{recs}"); log.AppendLine($"放到第 {recs} 条记录（{f.Name(r.Op)}）停（--stop-rec）"); break; }
            if (r.Op == 0x029 && pl.Length >= 8)
            {
                uint nc = BinaryPrimitives.ReadUInt32LittleEndian(pl);
                rt0 = nc > 0 ? BinaryPrimitives.ReadUInt32LittleEndian(pl[4..]) : 0;
                ds0 = pl.Length >= 8 + 4 * (int)nc ? BinaryPrimitives.ReadUInt32LittleEndian(pl[(4 + 4 * (int)nc)..]) : 0;
            }
            if (r.Op == 0x005 && ds0 != 0 && pl.Length >= 12) dsClear[ds0] = BinaryPrimitives.ReadSingleLittleEndian(pl[8..]);
            if (ds0 != 0 && r.Op is 0x009 or 0x00A or 0x00B or 0x00C or 0x00D or 0x00E) dsDraws[ds0] = dsDraws.GetValueOrDefault(ds0) + 1;
            if (r.Op == 0x026 && pl.Length >= 4) prog = BinaryPrimitives.ReadUInt32LittleEndian(pl);
            if (r.Op == 0x025 && pl.Length >= 4) topo = (PrimitiveTopology)BinaryPrimitives.ReadInt32LittleEndian(pl);
            // --diff-split：我方每次绘制后结束渲染通道（不提交、不等；靠 Barrier 拆，要配环境变量 NXGAL_BARRIER_SPLIT=1——10-21 起无存储写的屏障缺省不拆遍）——长通道里的回放不确定（10-20 画幅线：暗黑3 第 603 帧，每次绘制拆通道则 12/12 确定）对照用
            if (dd != null && ddSplit && r.Op is 0x008 or 0x009 or 0x00A or 0x00B or 0x00C or 0x00D or 0x00E or 0x00F) pn.Target.Pipeline.Barrier();
            dd?.After(r.Op, f.Payload(r), recs, presents + 1, prog);
            cap?.After(r.Op, presents + 1);
            if (pr != null && presents + 1 == prFrame && rt0 != 0 && (prTex == 0 || rt0 == prTex) && r.Op is 0x009 or 0x00A or 0x00B or 0x00C or 0x00D or 0x00E or 0x00F)
            {
                ITexture pt = pn.Obj<ITexture>(rt0); int pad = 0, gw = 0;
                if (pt is WidenTexture pw) { if (wr.State.TryWide(pw.Id, out int w0, out int w1)) pad = (w1 - w0) / 2; gw = pw.Width; pt = pw.Inner; }
                if (pt is NxTexture pnx && pnx.Info.Format is Format.R8G8B8A8Unorm or Format.R8G8B8A8Srgb or Format.B8G8R8A8Unorm or Format.R10G10B10A2Unorm or Format.R11G11B10Float or Format.R16G16B16A16Float or Format.R8Unorm or Format.D32Float or Format.R32Float)
                {
                    if (gw == 0) gw = pnx.Info.Width;
                    int bpp = pnx.Info.Format == Format.R16G16B16A16Float ? 8 : pnx.Info.Format == Format.R8Unorm ? 1 : 4;
                    int qx = prX * gw / 1920 + pad, qy = prY * pnx.Info.Height / 1080;   // 客体坐标按 1920×1080 给，按目标客体尺寸等比换算
                    byte[] d; using (var g = pnx.GetData(0, 0)) d = g.Get().ToArray();
                    int o = qy * pnx.Info.GetMipStride(0) + qx * bpp;
                    if (o + bpp <= d.Length) probe.AppendLine($"{recs}\t{prog}\t{rt0}\t{pnx.Info.Width}x{pnx.Info.Height}:{pnx.Info.Format}\t{Convert.ToHexString(d, o, bpp)}");
                }
            }
            if (r.Op == 0xFF02 && wr != null) { redProlog = wr.RedCounts; wr.Cam.TicksScan = wr.Cam.TicksDraw = wr.Cam.TicksInval = wr.Cam.ScanBytes = wr.Cam.QuickPass = 0; }   // 序章（录像补活对象与内容）不计镜头位姿开销   // 序章（录像补活对象与内容）结束：之前的红是录像补内容，不是游戏行为
            if (r.Op is 0x009 or 0x00A or 0x00B or 0x00C or 0x00D or 0x00E or 0x00F) fDraws++;
            if (r.Op == GalOps.IRenderer_ReportCounter) nReport++; else if (r.Op == GalOps.IRenderer_ResetCounter) nReset++;
            if (r.Op == 0x029) fRts++;
            if (r.Op != 0x201) continue;
            presents++;
            if (progress != null) File.WriteAllText(progress, presents.ToString());   // 进展心跳：门禁按「多久没新上屏」收卡死，不按固定墙钟（见 tests/visual/widen_gate.sh）
            if (dbT != 0 && presents == traceFrame && dbRec >= 0) { DbStep(); dbRec = -1; }
            if (wr != null) bands.Append(bands.Length > 0 ? " " : "").Append(wr.LastPillar);
            ImageCrop rc0 = pl.Length >= 4 + System.Runtime.CompilerServices.Unsafe.SizeOf<ImageCrop>() ? System.Runtime.InteropServices.MemoryMarshal.Read<ImageCrop>(pl[4..]) : default;
            (int pgw, int pgh) = pn.Obj<ITexture>(tid) switch { WidenTexture gwt => (gwt.Width, gwt.Height), NxTexture gnt => (gnt.Info.Width, gnt.Info.Height), _ => (0, 0) };
            (int x0, int x1, int y0, int y1) rcr = Crop(rc0.Left, rc0.Right, rc0.Top, rc0.Bottom, pgw, pgh);
            var rawNow = (pgw, pgh, rcr.x0, rcr.x1, rcr.y0, rcr.y1, rc0.IsStretched, rc0.AspectRatioX, rc0.AspectRatioY);
            if (rawChg == 0 || !rawNow.Equals(rawLast)) { rawChg++; if (rawChgAt.Count < 8) rawChgAt.Add(presents); rawLast = rawNow; }
            perFrame.Append(presents).Append('\t').Append(fDraws).Append('\t').Append(fRts).Append('\n'); fDraws = fRts = 0;
            if (presents == until) { log.AppendLine($"放到第 {until} 次上屏停（--until）"); break; }
            if (cam && wr != null)
            {
                Span<float> po = stackalloc float[8];
                log.AppendLine(wr.TryCamera(po) ? $"镜头 帧 {presents}：位置 {po[0]:F3} {po[1]:F3} {po[2]:F3}，前向 {po[3]:F4} {po[4]:F4} {po[5]:F4}，偏航 {po[6]:F2}° 俯仰 {po[7]:F2}°（读它的绘制 {wr.Cam.Draws} / 深度目标上 {wr.Cam.FrameDepthDraws}，存活候选 {wr.Cam.FrameLive}；前三 {wr.Cam.TopCnt[0]}@z{wr.Cam.TopZ[0]:F1} {wr.Cam.TopCnt[1]}@z{wr.Cam.TopZ[1]:F1} {wr.Cam.TopCnt[2]}@z{wr.Cam.TopZ[2]:F1}）" : $"镜头 帧 {presents}：无透视主镜头（深度目标上绘制 {wr.Cam.FrameDepthDraws}、存活候选 {wr.Cam.FrameLive}、累计认出 {wr.Cam.Found}）");
            }
            if (presents == depthFrame && dsDraws.Count > 0)
            {
                // 场景深度 = 画面形状（宽高比 ≥ 1.7：16:9 或放宽后的屏幕比）的深度附件里绘制最多的那张；一张都没有才退回全部里绘制最多的。
                //   只按绘制次数挑会挑到阴影图（10-26 动森闭环：386×386 的阴影级联本帧 1503 笔、比场景深度多，⑤ 露空判不出、退到截图口径误判）
                static float Aspect(ITexture t) { if (t is WidenTexture w) t = w.Inner; return t is NxTexture n && n.Info.Height > 0 ? (float)n.Info.Width / n.Info.Height : 0f; }
                var wide = dsDraws.Where(kv => Aspect(pn.Obj<ITexture>(kv.Key)) >= 1.7f).ToList();
                uint did = (wide.Count > 0 ? wide : dsDraws.ToList()).OrderByDescending(kv => kv.Value).First().Key;
                ITexture dt = pn.Obj<ITexture>(did); int w0 = 0;
                if (dt is WidenTexture dw) { w0 = dw.Width; dt = dw.Inner; }
                if (dt is NxTexture dnx)
                {
                    byte[] d; bool snap = dsSnap.TryGetValue(did, out var sn); if (snap) d = sn.data; else using (var g = dnx.GetData(0, 0)) d = g.Get().ToArray();   // 本帧被清过：用清之前那份
                    var dinf = dnx.Info; int stride = dinf.GetMipStride(0), bpp = dinf.Format == Format.D32FloatS8Uint ? 8 : 4;
                    var f32 = new float[dinf.Width * dinf.Height];
                    for (int y = 0; y < dinf.Height; y++)
                        for (int x = 0; x < dinf.Width; x++)
                        {
                            int o = y * stride + x * bpp;
                            f32[y * dinf.Width + x] = dinf.Format is Format.D32Float or Format.D32FloatS8Uint ? BitConverter.ToSingle(d, o)
                                : dinf.Format == Format.D24UnormS8Uint ? (BitConverter.ToUInt32(d, o) >> 8) / 16777215f   // 我方 GAL 布局（graphics/metal/gal_tex.m）：D24UnormS8Uint = d24 << 8 | s
                                : (BitConverter.ToUInt32(d, o) & 0xFFFFFF) / 16777215f;   // S8UintD24Unorm = s << 24 | d24；X8UintD24Unorm 同取低 24 位（10-20 前 D24UnormS8Uint 也取低 24 位，暗黑3 深度读成常数 0.9999848、露空恒 0，是假通过）
                        }
                    File.WriteAllBytes(Path.Combine(outDir, $"depth_{presents}.f32"), System.Runtime.InteropServices.MemoryMarshal.AsBytes(f32.AsSpan()).ToArray());
                    File.WriteAllText(Path.Combine(outDir, $"depth_{presents}.json"),
                        $"{{\"w\":{dinf.Width},\"h\":{dinf.Height},\"w0\":{(w0 == 0 ? dinf.Width : w0)},\"clear\":{(dsClear.TryGetValue(did, out float cv) ? cv.ToString(System.Globalization.CultureInfo.InvariantCulture) : "null")},\"format\":\"{dinf.Format}\",\"tex\":{did},\"draws\":{dsDraws[did]}}}");
                    log.AppendLine($"帧 {presents}：深度 {did}（{dinf.Format} {dinf.Width}×{dinf.Height}，本帧绘制 {dsDraws[did]} 次{(snap ? $"，取被清之前第 {sn.draws} 次绘制后的那份" : "")}）→ depth_{presents}.f32");
                }
            }
            dsDraws.Clear(); dsSnap.Clear();
            if (presents == dumpFrame) DumpTex(presents.ToString());   // --dump：该帧上屏时把指定贴图原样存（我方 + 有 --ref 时参照），裸字节 + json，供逐遍对拍中间目标
            if (!frames.Contains(presents)) continue;
            ITexture t = pn.Obj<ITexture>(tid);
            if (t is WidenTexture w) t = w.Inner;
            if (t is not NxTexture nt) { log.AppendLine($"帧 {presents}：上屏贴图 {tid} 取不到"); continue; }
            byte[] px; using (var d = nt.GetData(0, 0)) px = d.Get().ToArray();
            var inf = nt.Info;
            string png = Path.Combine(outDir, $"present_{presents}.png");
            if (Png.Write(png, px, inf.Width, inf.Height, inf.GetMipStride(0), inf.Format)) log.AppendLine($"帧 {presents}：{inf.Format} {inf.Width}×{inf.Height} → {png}");
            else log.AppendLine($"帧 {presents}：格式 {inf.Format} 不支持存图");
            // 出图区（宽屏门禁判中间区用）：raw = 录像原始裁剪（客体贴图尺寸），out = 实际交给出图层的裁剪（放宽贴图按包装层 MapX 换算，同 WidenWindow.Present）
            {
                int ol = rc0.Left, orr = rc0.Right;
                if (wr != null && pn.Obj<ITexture>(tid) is WidenTexture owt && wr.State.TryWide(owt.Id, out _, out _)) { ol = wr.State.MapX(owt.Id, rc0.Left); orr = rc0.Right == 0 ? 0 : wr.State.MapX(owt.Id, rc0.Right); }
                var oc = Crop(ol, orr, rc0.Top, rc0.Bottom, inf.Width, inf.Height);
                File.WriteAllText(Path.Combine(outDir, $"present_{presents}.json"), $"{{\"raw\":[{pgw},{pgh},{rcr.x0},{rcr.x1},{rcr.y0},{rcr.y1}],\"out\":[{inf.Width},{inf.Height},{oc.x0},{oc.x1},{oc.y0},{oc.y1}]}}");
            }
            if (pref != null && pref.Obj<ITexture>(tid) is ITexture rt)
            {
                byte[] rp; using (var d = rt.GetData(0, 0)) rp = d.Get().ToArray();
                Png.Write(Path.Combine(outDir, $"ref_{presents}.png"), rp, inf.Width, inf.Height, inf.GetMipStride(0), inf.Format);
                cmp.AppendLine(Compare(px, rp, inf.Width, inf.Height, inf.GetMipStride(0), presents, outDir));
            }
        }
        if (cam && wr != null && CameraTrack.Profile) log.AppendLine($"镜头位姿开销：识别 {wr.Cam.TicksScan * 1000.0 / System.Diagnostics.Stopwatch.Frequency:F2} ms（其中覆盖失效 {wr.Cam.TicksInval * 1000.0 / System.Diagnostics.Stopwatch.Frequency:F2} ms）；扫 {wr.Cam.ScanBytes >> 10} KB、快筛通过 {wr.Cam.QuickPass} 处、累计认出 {wr.Cam.Found}；计数 {wr.Cam.TicksDraw * 1000.0 / System.Diagnostics.Stopwatch.Frequency:F2} ms，共 {presents} 帧 → 每帧 {(wr.Cam.TicksScan + wr.Cam.TicksDraw) * 1000.0 / System.Diagnostics.Stopwatch.Frequency / Math.Max(1, presents):F3} ms");
        if (negVp) log.AppendLine($"反例 --neg-vp169：比 16:9 宽的视口改成 16:9 居中 {negVpN} 个");
        string rep = $"录像 {rec}：{recs} 条、上屏 {presents} 次、回放错误 {errs}，用时 {sw.Elapsed.TotalSeconds:F1} 秒\n" + $"录像出图参数变化 {rawChg} 次（录像原始贴图客体尺寸 + 裁剪；首几次在第 {string.Join(",", rawChgAt)} 次出图）\n" + string.Join("\n", errSamples) + (errSamples.Count > 0 ? "\n" : "") + log + (wr != null ? $"上屏两侧种类（逐帧，第 1 帧起；0 照常判 / 1 原比例页 / 2 两侧是放宽内容画的）：{bands}\n" + wr.Report() + $"\n其中序章补内容造成：{redProlog}；游戏行为红计数 {wr.RedCounts.Total - redProlog.Total}\n" : "") + (chk != null ? chk.Summary() + "\n" + string.Join("\n", chk.Samples) + "\n" : "");
        if (R.ShaderSubstitute != null) rep += $"SPIR-V 替换（--spv-sub）：{subN} 个阶段\n";
        if (typedHook != null) rep += $"我方按类型声明顶点输入（--typed-vertex）：程序 {typedHook.RawPrograms} 个、按格式建变体 {typedHook.Variants} 个、改写失败 {typedHook.Failed} 个\n";
        if (rawHook != null) rep += $"参照端原始位顶点输入：程序 {rawHook.RawPrograms} 个、按格式建变体 {rawHook.Variants} 个、改写失败 {rawHook.Failed} 个" + (rawHook.FailSamples.Count > 0 ? "（" + string.Join("；", rawHook.FailSamples) + "）" : "") + "\n";
        if (pref != null) rep += $"双后端对拍（参照 Vulkan@MoltenVK，参照回放异常 {errR} 条，参照端加循环上限的着色器 {RefLoopGuard.Guarded} 支）：\n" + string.Join("\n", errRSamples) + (errRSamples.Count > 0 ? "\n" : "") + cmp;
        if (pref != null) rep += $"录像计数器操作：ReportCounter {nReport} 次、ResetCounter {nReset} 次；" + CounterCompare(pn, pref);
        if (dd != null) rep += ddPre + dd.Report();
        if (cap != null) rep += cap.Summary();
        if (psoOpen != -2) unsafe { ulong* ps = stackalloc ulong[4]; nxgal_pso_cache_stats(ps); rep += $"管线归档：登记 {psoOpen}，归档命中 {ps[0]}、现建 {ps[1]}（现建累计 {ps[2] / 1e6:F1} ms）\n"; }
        File.WriteAllText(Path.Combine(outDir, "report.txt"), rep);
        if (pr != null) File.WriteAllText(Path.Combine(outDir, "probe.tsv"), probe.ToString());
        if (traceFrame > 0) File.WriteAllText(Path.Combine(outDir, "trace.tsv"), trace.ToString());
        if (dbT != 0) File.WriteAllText(Path.Combine(outDir, "drawbox.tsv"), dbox.ToString());
        if (cbProgs != null) File.WriteAllText(Path.Combine(outDir, "cbuf.tsv"), cbuf.ToString());
        File.WriteAllText(Path.Combine(outDir, "frames.tsv"), perFrame.ToString());   // 每次上屏之间的绘制数与换目标次数（对 frames.tsv 帧号 / 找重帧用）
        if (tm != null) File.WriteAllText(Path.Combine(outDir, "time.tsv"), "记录\t帧\t程序\t各阶段键\t目标\t调用\t数,实例\t拓扑\t毫秒\n" + times);
        Console.Write(rep); Console.Out.Flush();
        if (Environment.GetEnvironmentVariable("NXGAL_BOUNDS_COUNT") == "1") Console.Error.WriteLine($"越界 / 循环到上限的着色器 {nxgal_bounds_report()} 支（明细见上方【红】行；计数开着，本次只读计数）");   // 回放到不了 600 次出图、也不走渲染器关停，收尾主动报
        int rc = errs == 0 && (wr == null || wr.RedCounts.Total - redProlog.Total == 0) ? (dd?.First != null ? 4 : cap != null && cap.Red > 0 ? 6 : 0) : 1;
        Environment.Exit(rc);   // 渲染器留有前台线程
        return rc;
    }

    [System.Runtime.InteropServices.DllImport("nxgal")] static extern int nxgal_bounds_report();
    [System.Runtime.InteropServices.DllImport("nxgal")] static extern unsafe void nxgal_pso_cache_stats(ulong* o);

    /// <summary>计数器对拍：两边先把在途结果收进来（UpdateCounters；一边已出、另一边还在途的逐个 Flush 等出来，免得放完时 GPU 进度不同造成假「没出」），
    /// 按录像事件号配对比值；只比两边都出了结果的。</summary>
    static string CounterCompare(GalRecReplayer ours, GalRecReplayer refr)
    {
        Dictionary<uint, ulong> a = null, b = null;
        for (int pass = 0; pass < 2; pass++)
        {
            ours.Target.UpdateCounters(); refr.Target.UpdateCounters();
            lock (ours.CounterResults) a = new(ours.CounterResults);
            lock (refr.CounterResults) b = new(refr.CounterResults);
            if (pass == 1) break;
            foreach (uint id in b.Keys) if (!a.ContainsKey(id)) ours.Obj<ICounterEvent>(id)?.Flush();
            foreach (uint id in a.Keys) if (!b.ContainsKey(id)) refr.Obj<ICounterEvent>(id)?.Flush();
        }
        long both = 0, eq = 0; ulong maxd = 0; var bad = new List<string>();
        foreach (var kv in a.OrderBy(k => k.Key))
        {
            if (!b.TryGetValue(kv.Key, out ulong rv)) continue;
            both++;
            if (rv == kv.Value) { eq++; continue; }
            ulong d = rv > kv.Value ? rv - kv.Value : kv.Value - rv; if (d > maxd) maxd = d;
            if (bad.Count < 8) bad.Add($"  事件 {kv.Key}：我方 {kv.Value}、参照 {rv}");
        }
        return $"计数器对拍：我方出结果 {a.Count}、参照出结果 {b.Count}、两边都出 {both}、相等 {eq}、不等 {both - eq}（最大差 {maxd}）\n"
            + string.Join("\n", bad) + (bad.Count > 0 ? "\n" : "");
    }

    /// <summary>参照端循环上限：回放 CreateProgram 时每支 SPIR-V 经 nxgal_spv_loop_guard 加上限（与我方同口径，不加越界钳位、不改正常语义）。
    /// 不用 DispatchProxy 包整个渲染器：带 ReadOnlySpan 参数的方法（SetBufferData）转发不了。</summary>
    public static class RefLoopGuard
    {
        public static long Guarded;
        public static unsafe ShaderSource[] Guard(ShaderSource[] ss)
        {
            var o = (ShaderSource[])ss.Clone();
            for (int i = 0; i < o.Length; i++)
            {
                byte[] b = o[i].BinaryCode;
                if (o[i].Language != Ryujinx.Graphics.Shader.Translation.TargetLanguage.Spirv || b == null || b.Length < 20 || b.Length % 4 != 0) continue;
                uint n; uint* r;
                fixed (byte* p = b) r = nxgal_spv_loop_guard((uint*)p, (uint)(b.Length / 4), &n);
                if (r == null) continue;
                var nb = new byte[n * 4]; new ReadOnlySpan<byte>(r, (int)n * 4).CopyTo(nb); nxgal_spv_free(r);
                o[i] = new ShaderSource(o[i].Code, nb, o[i].Stage, o[i].Language); Guarded++;
            }
            return o;
        }
        [System.Runtime.InteropServices.DllImport("dsx")] static extern unsafe uint* nxgal_spv_loop_guard(uint* inp, uint nw, uint* onw);
        [System.Runtime.InteropServices.DllImport("dsx")] static extern unsafe void nxgal_spv_free(void* p);
    }

    /// <summary>两边上屏图（RGBA8 / BGRA8，同尺寸同步长）逐像素比：差异像素 = 任一通道差 > 2；PSNR 按 RGB；差异图红 = 差异像素、其余灰度淡显。</summary>
    static string Compare(byte[] a, byte[] b, int w, int h, int stride, long frame, string outDir)
    {
        if (b.Length < h * stride) return $"帧 {frame}：参照数据长度 {b.Length} < {h * stride}，不比";
        long diff = 0; double se = 0; byte[] o = new byte[w * h * 4];
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
        {
            int s = y * stride + x * 4, q = (y * w + x) * 4; int m = 0;
            for (int c = 0; c < 3; c++) { int d = a[s + c] - b[s + c]; se += d * d; m = Math.Max(m, Math.Abs(d)); }
            bool bad = m > 2; if (bad) diff++;
            byte g = (byte)(a[s + 1] * 160 / 255); o[q] = bad ? (byte)255 : g; o[q + 1] = bad ? (byte)0 : g; o[q + 2] = bad ? (byte)0 : g; o[q + 3] = 255;
        }
        Png.Write(Path.Combine(outDir, $"diff_{frame}.png"), o, w, h, w * 4, Format.R8G8B8A8Unorm);
        double mse = se / (3.0 * w * h), psnr = mse == 0 ? 99 : 10 * Math.Log10(255.0 * 255 / mse);
        return $"帧 {frame}：差异像素 {diff * 100.0 / (w * h):F2}%（通道差 > 2），PSNR {psnr:F2} dB";
    }
    /// <summary>出图源矩形，同 graphics/metal/gal_present.m（左右都为 0 = 整宽；上下同理）。</summary>
    static (int x0, int x1, int y0, int y1) Crop(int l, int r, int t, int b, int w, int h) => (l != 0 || r != 0 ? l : 0, l != 0 || r != 0 ? r : w, t != 0 || b != 0 ? t : 0, t != 0 || b != 0 ? b : h);
    static string Opt(string[] a, string k) { int i = Array.IndexOf(a, k); return i >= 0 && i + 1 < a.Length ? a[i + 1] : null; }
}

static class Png
{
    public static bool Write(string path, byte[] px, int w, int h, int stride, Format f)
    {
        bool bgra = f is Format.B8G8R8A8Unorm or Format.B8G8R8A8Srgb;
        bool rgb10 = f is Format.R10G10B10A2Unorm;
        if (!(bgra || rgb10 || f is Format.R8G8B8A8Unorm or Format.R8G8B8A8Srgb)) return false;
        var raw = new MemoryStream();
        for (int y = 0; y < h; y++)
        {
            raw.WriteByte(0);
            for (int x = 0; x < w; x++)
            {
                int o = y * stride + x * 4;
                if (rgb10) { uint v = BitConverter.ToUInt32(px, o); raw.WriteByte((byte)((v & 1023) >> 2)); raw.WriteByte((byte)(((v >> 10) & 1023) >> 2)); raw.WriteByte((byte)(((v >> 20) & 1023) >> 2)); raw.WriteByte(255); continue; }
                raw.WriteByte(px[o + (bgra ? 2 : 0)]); raw.WriteByte(px[o + 1]); raw.WriteByte(px[o + (bgra ? 0 : 2)]); raw.WriteByte(255);
            }
        }
        var z = new MemoryStream(); using (var zs = new ZLibStream(z, CompressionLevel.Fastest, true)) raw.WriteTo(zs);
        using var fs = File.Create(path);
        fs.Write(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });
        var ihdr = new byte[13]; Be(ihdr, 0, w); Be(ihdr, 4, h); ihdr[8] = 8; ihdr[9] = 6;
        Chunk(fs, "IHDR", ihdr); Chunk(fs, "IDAT", z.ToArray()); Chunk(fs, "IEND", Array.Empty<byte>());
        return true;
    }
    static void Be(byte[] b, int o, int v) { b[o] = (byte)(v >> 24); b[o + 1] = (byte)(v >> 16); b[o + 2] = (byte)(v >> 8); b[o + 3] = (byte)v; }
    static void Chunk(Stream s, string type, byte[] data)
    {
        var len = new byte[4]; Be(len, 0, data.Length); s.Write(len);
        byte[] t = Encoding.ASCII.GetBytes(type); s.Write(t); s.Write(data);
        uint c = Crc(t, 0xFFFFFFFF); c = Crc(data, c) ^ 0xFFFFFFFF; var cb = new byte[4]; Be(cb, 0, (int)c); s.Write(cb);
    }
    static uint[] _t;
    static uint Crc(byte[] d, uint c)
    {
        if (_t == null) { _t = new uint[256]; for (uint n = 0; n < 256; n++) { uint k = n; for (int i = 0; i < 8; i++) k = (k & 1) != 0 ? 0xEDB88320 ^ (k >> 1) : k >> 1; _t[n] = k; } }
        foreach (byte b in d) c = _t[(c ^ b) & 0xFF] ^ (c >> 8);
        return c;
    }
}
