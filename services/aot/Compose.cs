using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace S2A.Aot
{
    // 把显卡线的渲染器接到服务层：S2A_Init 建 Ryujinx 显卡上下文时用 NxGal 的 Metal 渲染器
    static unsafe class Compose
    {
        [DllImport("s2a_native")] private static extern S2A.Services.LanDiscoveryV1* s2a_ldn_lan_provider();

        private static S2Arm.Gfx.Widen.Gal.WidenRenderer s_widen;
        private static RyuJudge.GalRec.GalRecorder s_rec;
        private static NxGal.NxRenderer s_renderer;
        private static System.Threading.CancellationTokenSource s_frameCapStop;
        private static System.Threading.Thread s_frameCapThread;
        private enum SessionState { Empty, Active, Retiring, ResourcesRetired, ProcessExit }
        private static readonly object s_sessionLock = new();
        private static SessionState s_sessionState;

        [DllImport("s2a_native")] private static extern int s2a_graphics_native_restart_check();
        [DllImport("s2a_native")] private static extern int s2a_graphics_native_request_stop();
        [DllImport("s2a_native")] private static extern int s2a_graphics_native_shutdown_session();
        [DllImport("s2a_native")] private static extern int s2a_graphics_native_begin_session();
        [DllImport("s2a_native")] private static extern void s2a_graphics_native_seal_process_exit();
        [DllImport("s2a_native")] private static extern void s2a_video_frame();   // graphics/nvn hle_nvn.c：视频解一帧（按片源帧率出图，nvn_vpace.h）

        [UnmanagedCallersOnly(EntryPoint = "s2a_graphics_restart_check")]
        public static int RestartCheck() => s2a_graphics_native_restart_check();

        [UnmanagedCallersOnly(EntryPoint = "s2a_graphics_request_stop")]
        public static int RequestStop()
        {
            try
            {
                int error = s2a_graphics_native_request_stop();
                S2A.Gfx.RenderLoop.RequestStop();
                s_renderer?.RequestStop();
                return error;
            }
            catch (System.Exception e) { System.Console.Error.WriteLine($"【红】停止图形队列：{e}"); return -1; }
        }

        // The session coordinator must have joined every guest thread and
        // completed service/GPU disposal before retiring guest-address tables.
        // Ordinary process exit does not satisfy that contract and never calls this stage.
        [UnmanagedCallersOnly(EntryPoint = "s2a_graphics_shutdown_session")]
        public static int ShutdownSession()
        {
            try
            {
                lock (s_sessionLock)
                {
                    if (s_sessionState != SessionState.ResourcesRetired)
                        throw new System.InvalidOperationException($"图形资源尚未安全退休，不能清理 native 地址表（{s_sessionState}）");
                    int error = s2a_graphics_native_shutdown_session();
                    if (error != 0) return error;
                    S2A.Gfx.RenderLoop.ResetSession();
                    S2Arm.Gfx.Widen.WidenCApi.ResetSession();
                    S2A.Services.GuestMemory.ReprotectHook = null;
                    S2A.Services.GuestMemory.WriteUntrackedHook = null;
                    S2A.Services.GuestMemory.WriteHook = null;
                    S2A.Services.GuestMemory.WriteQuietHook = null;
                    S2A.Services.GuestMemory.GpuModifiedHook = null;
                    s_sessionState = SessionState.Empty;
                    return 0;
                }
            }
            catch (System.Exception e) { System.Console.Error.WriteLine($"【红】退休已停止客体的图形会话：{e}"); return -1; }
        }

        private static int CamHook(float* o) => s_widen != null && s_widen.TryCamera(new System.Span<float>(o, 8)) ? 1 : 0;
        private static void BindTrackingHooks()
        {
            S2A.Services.GuestMemory.ReprotectHook = &NxGal.NxTrack.Reprotect;
            S2A.Services.GuestMemory.WriteUntrackedHook = &NxGal.NxTrack.WriteUntracked;
            S2A.Services.GuestMemory.WriteHook = &NxGal.NxTrack.Write;
            S2A.Services.GuestMemory.WriteQuietHook = &NxGal.NxTrack.WriteQuiet;
            S2A.Services.GuestMemory.GpuModifiedHook = &NxGal.NxTrack.GpuModified;
        }

        [ModuleInitializer]
        internal static void Init()
        {
            S2A.Services.Exports.AudioFactory = &S2A.Apple.Audio.AppleAudio.Create;
            // 视频解码（平台 adapter P1，#1069）：Nvdec 只认登记的工厂，苹果实现在 platform/apple/cs/video
            S2A.Apple.Video.AppleVideo.Register();
            // 相册截图 JPEG（游戏 caps:su SaveScreenShotEx*）：ImageIO 编码，苹果宿主不带 Skia
            S2A.Apple.Capture.AppleScreenshotEncoder.Register();
            var lan = s2a_ldn_lan_provider();
            if (lan != null) S2A.Services.Native.RegisterLanDiscovery(lan);
            // 存档原子提交的宿主目录原语（平台 adapter P6，#1072）：苹果实现在 platform/apple/cs/savecommit
            Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = new S2A.Apple.SaveCommit.AppleHostDirectoryTransaction();
            // 视频按片源帧率出图：Ryujinx Nvdec 每解一帧报给直连出图节拍（通用模式不读，记下无副作用）
            Ryujinx.Graphics.Nvdec.NvdecDevice.S2AFrameDecoded = static () => s2a_video_frame();
            // 分配拆账（S2A_ALLOC_TRACE=1）：宽屏导出入口按名记的分配接到按线程拆账的细分项（宽屏核心不引用 Ryujinx，由这里接）
            if (Ryujinx.Common.S2AThreadAlloc.On) S2Arm.Gfx.Widen.WidenCApi.AllocPart = Ryujinx.Common.S2AThreadAlloc.Part;
            // 宽屏（画幅线 graphics/widen/gal）：渲染器一律套 GAL 包装层。屏幕比 16:9 宽时放宽——游戏自己出宽图（第二层）时界面层仍用 16:9 相机，
            // 包装层按原尺寸居中、越界遮罩推到屏幕边；游戏没出宽图时整套第三层改写。16:9 时只观察（不改常量与着色器，离线着色器库照常命中），
            // 供每帧镜头位姿识别（frames.tsv，自动玩家判据）。屏幕宽只认原生层 s2a_screen_w（1080 高对应的宽；Mac 读 S2A_SCREEN_W，iOS 由 App 壳按屏幕算）
            S2A.Services.Exports.RendererFactory = static () =>
            {
                lock (s_sessionLock)
                {
                    if (s_sessionState != SessionState.Empty)
                        throw new System.InvalidOperationException($"旧图形会话未完成可重建关闭（{s_sessionState}）");
                    s_sessionState = SessionState.Active;
                }
                BindTrackingHooks();
                Ryujinx.Graphics.GAL.IRenderer nx = new NxGal.NxRenderer();
                s_renderer = (NxGal.NxRenderer)nx;
                S2A.Services.GraphicsSettings.Apply(nx);
                int w = S2A.Services.Native.ScreenW != null ? S2A.Services.Native.ScreenW() : 1920;
                int h = S2A.Services.Native.ScreenH != null ? S2A.Services.Native.ScreenH() : 1080;   // 10-26 任意宽高比：窄屏 > 1080
                // 原生层 s2a_widen_game：启用了第二层宽屏点 = 游戏自己出宽图，包装层只管界面层、不放宽贴图
                bool game = S2A.Services.Native.WidenGame != null && S2A.Services.Native.WidenGame() == 1;
                // 第三层（整套放宽）也只用闭环验过的表：没验过 = 不放宽，16:9 原比例居中、两侧黑边，出图层不报未满屏（10-21 维护者 实机暗黑2 / 巫师3 拉伸错位）
                bool full = S2A.Services.Native.WidenFull != null && S2A.Services.Native.WidenFull() == 1;
                // 模式判定在宽屏核心（直连模式经 s2a_widen_init 用同一份）
                bool pillar = S2Arm.Gfx.Widen.WidenSession.Decide(w, h, game, full, out float aspect) == S2Arm.Gfx.Widen.WidenMode.Pillar;
                // 原生层 s2a_widen_layout：游戏界面布局也是宽的（启用了 lytsz）→ 界面剪裁已是真实宽屏像素，包装层不再收进中间
                bool layout = game && S2A.Services.Native.WidenLayout != null && S2A.Services.Native.WidenLayout() == 1;
                s_widen = new S2Arm.Gfx.Widen.Gal.WidenRenderer(nx, aspect, game) { PillarAll = pillar, LayoutWide = layout, CpuPeek = ((NxGal.NxRenderer)nx).S2APeekBufferCpu };   // 几何判定只读 CPU 侧、不等 GPU
                System.Console.Error.WriteLine($"[宽屏] 包装层已套：屏幕宽 {w}，k {s_widen.State.Rewriter.K:F4}，{(w <= 1920 ? "16:9 只观察" : game ? "游戏自己出宽图：只管界面层" : full ? "整套放宽（第三层表验过）" : "不放宽：第三层没验过，16:9 原比例居中留黑边")}");
                Ryujinx.Graphics.GAL.IRenderer outer = Record(nx, s_widen);
                FrameCapAtMark();
                // 双线程渲染（缺省开，S2A_THREADED=0 关）：最外层套 Ryujinx 原版 ThreadedRenderer = Threaded(录像(宽屏(NxGal)))——录像 / 宽屏 / NxGal 都在渲染线程上被调，
                // 宽屏状态与 NxFrames 镜头钩子（出图时读）同在渲染线程；非 GPU 线程直调下层的少数分支持渲染线程锁（补丁 0106）；GPU 模拟另起线程（graphics/loop/RenderLoop.cs）
                if (S2A.Gfx.RenderLoop.Threaded)
                {
                    System.Console.Error.WriteLine("[gal] 双线程渲染：渲染器套 ThreadedRenderer（GPU 模拟与 Metal 编码分两条线程）");
                    return new Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer(outer);
                }
                return outer;
            };

            // 每帧镜头位姿（frames.tsv cam_* 列，自动玩家判据）：渲染线程上由包装层的镜头识别给出
            NxGal.NxFrames.Camera = &CamHook;

            // 按 GC 间隔拆账（10-23 测试出包线，② 加载期 gen1 中寿命分配找根）：每次 GC 紧接 [gc] 行打游戏线程服务请求 + 渲染线程分派的增量
            if (System.Environment.GetEnvironmentVariable("S2A_ALLOC_TRACE") == "1")
                NxGal.NxFrames.OnGcAlloc = static () => S2A.Services.Dispatcher.AllocSinceLastGc() + "\n" + Ryujinx.Graphics.Gpu.S2AAllocTrace.SinceLastGc();

            // 写跟踪（帧率能耗线 16 KB 精确跟踪）
            BindTrackingHooks();

            // 渲染循环（帧率能耗线 S2A.GPU 线程）：服务层与游戏登记完成后起，关停前停
            // 直连模式（runtime/include/s2a_gfx_mode.h，起局判定）：游戏的 NVN 调用由直连图形层（graphics/nvn）直接出图，Ryujinx 显卡模拟与通用渲染循环都不起，
            //   NxGal 不建 Metal 设备与出图层（出图层归直连独占）；渲染器工厂照旧登记，但服务层只构造不初始化
            S2A.Services.Exports.AfterBoot = static (device, tracking) =>
            {
                lock (s_sessionLock)
                {
                    if (s_sessionState != SessionState.Active) throw new System.InvalidOperationException("图形会话不可启动");
                    int error = s2a_graphics_native_begin_session();
                    if (error != 0) throw new System.InvalidOperationException($"native 图形会话不可启动 ({error})");
                }
                if (S2A.Services.Native.GfxMode != null && S2A.Services.Native.GfxMode() == 1) { System.Console.Error.WriteLine("[gal] 直连模式：通用渲染循环不起（出图层归直连图形层 graphics/nvn）"); NxGal.NxFrames.StartDirect(); return; }
                // 起局判定成「不能直连」（设备既无 Metal 4 也无 Metal 3 路径，runtime/src/gfxmode.c）：宿主随后停在初启失败页（host_main.c direct_lib_missing）。
                //   通用渲染循环在这里起的话，它在自己线程上建 Metal 4 队列失败、抛未处理异常，把已经显示提示页的进程整个带崩
                //   （#620 / 诊断 #3e75dc：A12X iPad 上提示页出来后 nxgal 初始化失败 → FailFast）。只有直连一种模式，不能直连就不起通用循环
                if (S2A.Services.Native.GfxMode != null) { System.Console.Error.WriteLine("[gal] 不能直连：通用渲染循环不起（宿主停在初启失败页）"); return; }
                S2A.Gfx.RenderLoop.Start(device, tracking);
            };
            S2A.Services.Exports.BeforeShutdown = static () =>
            {
                int error = s2a_graphics_native_request_stop();
                if (error != 0) throw new System.InvalidOperationException($"直连图形队列未停止 ({error})");
                s_frameCapStop?.Cancel();
                if (s_frameCapThread != null && !s_frameCapThread.Join(3000))
                    throw new System.TimeoutException("存帧等待线程未停止");
                s_frameCapThread = null; s_frameCapStop?.Dispose(); s_frameCapStop = null;
                S2A.Gfx.RenderLoop.RequestStop();
                s_renderer?.RequestStop();
                S2A.Gfx.RenderLoop.StopProducer();
                s_renderer?.StopCallbacks();
            };
            S2A.Services.Exports.AfterShutdown = static device =>
            {
                // Apple process exit parks SVC calls but does not join every
                // guest writer. Keep GPU/tracking/resource owners until process exit.
                lock (s_sessionLock)
                {
                    if (s_sessionState != SessionState.Active)
                        throw new System.InvalidOperationException($"图形关闭路径已选定（{s_sessionState}）");
                    s_sessionState = SessionState.ProcessExit;
                    s2a_graphics_native_seal_process_exit();
                    S2A.Gfx.RenderLoop.StopBackend();
                    s_rec?.Dispose(); s_rec = null;
                }
            };
            S2A.Services.Exports.AfterGuestJoinedShutdown = static device =>
            {
                // GPU destruction still queues commands: consume them before
                // joining the encoder and disposing the underlying renderer.
                lock (s_sessionLock)
                {
                    if (s_sessionState != SessionState.Active || device == null || !System.Object.ReferenceEquals(device, S2A.Services.Host.Device))
                        throw new System.InvalidOperationException($"图形会话不能进入客体已 join 的退休路径（{s_sessionState}）");
                    S2A.Gfx.RenderLoop.EnsureRetirementBackend();
                    s_sessionState = SessionState.Retiring;
                    device.Gpu.S2ABeforeRendererDispose = S2A.Gfx.RenderLoop.StopBackend;
                    device.DisposeGpu();
                    s_rec?.Dispose(); s_rec = null; s_widen = null; s_renderer = null;
                    s_sessionState = SessionState.ResourcesRetired;
                }
                // Native tables and frame callbacks remain owned until the
                // coordinator's guest-joined retirement stage above succeeds.
            };
        }

        // 逐帧存图（诊断，出图层 graphics/metal/gal_present.m）：NXGAL_FRAME_CAP=mark+K:N 时 MARK 一到通知出图层开窗（同录像层按 AudioPeakDriver.Marked 判 MARK）；
        // 后台线程每 100 ms 看一次，不进每帧路径
        [System.Runtime.InteropServices.DllImport("nxgal")] private static extern void nxgal_frame_cap_arm();
        private static void FrameCapAtMark()
        {
            string fc = System.Environment.GetEnvironmentVariable("NXGAL_FRAME_CAP");
            if (string.IsNullOrEmpty(fc) || !fc.StartsWith("mark", System.StringComparison.Ordinal)) return;
            s_frameCapStop = new System.Threading.CancellationTokenSource();
            var stop = s_frameCapStop.Token;
            s_frameCapThread = new System.Threading.Thread(() =>
            {
                while (!S2A.Services.AudioPeakDriver.Marked)
                    if (stop.WaitHandle.WaitOne(100)) return;
                if (!stop.IsCancellationRequested) nxgal_frame_cap_arm();
            }) { IsBackground = true, Name = "s2a-framecap" };
            s_frameCapThread.Start();
        }

        // GAL 调用流录像（画幅线 tests/visual/galrec，S2AGAL01 格式，tests/visual/galplay 回放 / 逐绘制探针）：S2A_GALREC=<目录> 时录到 <目录>/gal.rec，
        // 录的是游戏发出的原始调用（套在宽屏包装层外面；回放时 galplay --widen 再套）。S2A_GALREC_MAX_MB（缺省 2048）到顶停录；
        // S2A_GALREC_FRAMES=a-b 只录第 a..b 次上屏（之前的对象 / 状态照样记成开场）。不设 = 不套这层，零开销。
        // S2A_GALREC_FRAMES=mark[+K]:N：自动玩家打 MARK 之后，跳过 K 次上屏（缺省 0）再录 N 次（双后端逐绘制对拍录 MARK 后的游戏场景，事先不知道 MARK 在第几帧）；
        //   S2A_GALREC_MARK_FALLBACK_S=<秒>：录像层建好后这么多秒还没 MARK 就照样开窗、不跳（到不了 MARK 的款也录一段，报告里注明「没到 MARK」）。
        // 能力表要初始化后的设备才查得到：先初始化 NxRenderer（nxgal_init / NxColdStart 幂等，服务层随后的 Initialize 落空）。
        private static Ryujinx.Graphics.GAL.IRenderer Record(Ryujinx.Graphics.GAL.IRenderer nx, Ryujinx.Graphics.GAL.IRenderer outer)
        {
            if (S2A.Services.Native.GfxMode != null && S2A.Services.Native.GfxMode() == 1) return outer;
            string dir = System.Environment.GetEnvironmentVariable("S2A_GALREC");
            if (string.IsNullOrEmpty(dir)) return outer;
            // 相对路径按 App 的 Documents / Mac 的家目录解析（同 S2A_SAVE_DIR，执行器 --pull 也按 Documents 拉）。
            // 原先按进程当前目录：iOS 上是「/」，S2A_GALREC=galrec 建 /galrec 无权限，S2A_Init 整个失败、0x1F 全未实现（10-22 暗黑2 真机录像局）
            if (!System.IO.Path.IsPathRooted(dir)) dir = System.IO.Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.Personal), dir);
            System.IO.Directory.CreateDirectory(dir);
            nx.Initialize(Ryujinx.Common.Configuration.GraphicsDebugLevel.None);
            long max = (long.TryParse(System.Environment.GetEnvironmentVariable("S2A_GALREC_MAX_MB"), out long mb) && mb > 0 ? mb : 2048) << 20;
            long lo = 1, hi = long.MaxValue;
            string fr = System.Environment.GetEnvironmentVariable("S2A_GALREC_FRAMES");
            long markSkip = -1, markN = 0;
            double fbS = double.TryParse(System.Environment.GetEnvironmentVariable("S2A_GALREC_MARK_FALLBACK_S"), out double fb) && fb > 0 ? fb : double.MaxValue;
            long t0 = System.Diagnostics.Stopwatch.GetTimestamp();
            if (!string.IsNullOrEmpty(fr) && fr.StartsWith("mark", System.StringComparison.Ordinal))
            {
                string[] kn = fr[4..].Split(':');
                markSkip = kn[0].Length > 1 && kn[0][0] == '+' ? long.Parse(kn[0][1..]) : 0;
                markN = kn.Length > 1 ? long.Parse(kn[1]) : 60;
                lo = long.MaxValue; hi = long.MaxValue;
            }
            else if (!string.IsNullOrEmpty(fr)) { string[] ab = fr.Split('-'); lo = long.Parse(ab[0]); hi = ab.Length > 1 && ab[1].Length > 0 ? long.Parse(ab[1]) : lo; }
            var widen = s_widen;
            string path = System.IO.Path.Combine(dir, "gal.rec");
            s_rec = new RyuJudge.GalRec.GalRecorder(path, max, () =>
            {
                long f = widen.State.Frames + 1;
                if (markSkip >= 0 && lo == long.MaxValue)
                {
                    bool mk = S2A.Services.AudioPeakDriver.Marked;
                    if (mk || System.Diagnostics.Stopwatch.GetElapsedTime(t0).TotalSeconds > fbS)
                    {
                        lo = f + (mk ? markSkip : 0); hi = lo + markN - 1;   // 没到 MARK 的退路不再跳：画面可能就要停（10-21 暗黑2 在跳的 30 帧里停帧，一帧没录到）
                        System.Console.Error.WriteLine($"[录像] {(mk ? "MARK 后开窗" : $"{fbS:F0} 秒没到 MARK，照样开窗")}：上屏 {lo}..{hi}");
                    }
                }
                return f >= lo && f <= hi;
            }, RyuJudge.GalRec.GalOps.Names, nx.GetCapabilities());
            System.Console.Error.WriteLine($"[录像] GAL 调用流录到 {path}（上限 {max >> 20} MB，上屏 {(markSkip >= 0 ? $"MARK 后 +{markSkip} 起 {markN} 次" : $"{lo}..{(hi == long.MaxValue ? "末" : hi.ToString())}")}）");
            return new RyuJudge.GalRec.RecordingRenderer(outer, null, s_rec);
        }
    }
}
