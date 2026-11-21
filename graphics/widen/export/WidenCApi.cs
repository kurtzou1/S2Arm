// 宽屏核心的 C 导出（export/s2a_widen.h）：NativeAOT 库模式按 [UnmanagedCallersOnly] 导出（S2A.Aot.csproj 登记本程序集）。
// 每个入口都吞掉异常（不能跨 C 边界抛）、计数后按「不改」返回。渲染路径入口零分配。
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace S2Arm.Gfx.Widen
{
    public static unsafe class WidenCApi
    {
        static WidenSession s_s;
        static long s_errors;   // 还没有会话时的异常
        // Called after native frontend resource releases, which still use the
        // old texture ids. The session owns every shader/texture/uniform map.
        public static void ResetSession()
        {
            s_s = null;
            s_errors = 0;
            CameraTrack.ResetPublished();
        }
        // 分配拆账（S2A_ALLOC_TRACE=1，定位用）：每笔绘制走的几个入口按名记本线程分配，交给 AllocPart（组装处 services/aot/Compose.cs 接到
        //   Ryujinx.Common.S2AThreadAlloc.Part；是游戏线程「两次系统调用之间」那一项的细分；10-26 巫师3 R39 核对差额 65.6% 归不到线程）。没接 = 只多一次判空
        public static Action<string, long> AllocPart;
        static long T0() => AllocPart != null ? GC.GetAllocatedBytesForCurrentThread() : 0;
        static void T1(string part, long a0) { Action<string, long> f = AllocPart; if (f != null) f(part, GC.GetAllocatedBytesForCurrentThread() - a0); }

        static void Err(Exception e)
        {
            if (s_s != null) s_s.Errors++; else s_errors++;
            if ((s_s?.Errors ?? s_errors) <= 8) Console.Error.WriteLine($"[宽屏·核心] 导出入口异常：{e.GetType().Name} {e.Message}");
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_init")]
        public static int Init(int screenW, int screenH, uint flags)
        {
            try
            {
                s_s = new WidenSession(screenW, screenH, (flags & 1) != 0, (flags & 4) != 0, (flags & 2) != 0, (flags & 8) != 0);
                s_s.GeomCovers = GeomNow;
                Console.Error.WriteLine($"[宽屏·核心] 直连会话：屏幕宽 {screenW}、高 {screenH}，模式 {s_s.Mode}，k {s_s.Rewriter.K:F4}、ky {s_s.Rewriter.Ky:F4}");
                return (int)s_s.Mode;
            }
            catch (Exception e) { Err(e); s_s = null; return 0; }
        }

        /// <summary>运行中换屏：按新屏幕宽 / 高重定模式（见 WidenSession.Reaspect）。返回新模式（同 s2a_widen_init）；没有会话返回 0。</summary>
        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_reaspect")]
        public static int Reaspect(int screenW, int screenH)
        {
            try
            {
                if (s_s == null) return 0;
                WidenMode m = s_s.Reaspect(screenW, screenH);
                Console.Error.WriteLine($"[宽屏·核心] 换屏：屏幕宽 {screenW}、高 {screenH}，模式 {m}，k {s_s.Rewriter.K:F4}、ky {s_s.Rewriter.Ky:F4}（第 {s_s.Reaspects} 次）");
                return (int)m;
            }
            catch (Exception e) { Err(e); return 0; }
        }

        /// <summary>导出入口异常累计（11-05：宿主「撑不住就问玩家」每秒读，涨了 = 这一秒满屏画面不可靠，见 runtime/src/qprompt.c s2a_qp_unfit_sample）。</summary>
        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_errors")]
        public static long ErrorCount() => s_s?.Errors ?? s_errors;

        /// <summary>拉伸风险累计（11-06 满屏泛化，WidenSession.Draw）：which 0 = 对、1 = 拉伸、2 = 收窄；宿主 runtime/src/qprompt_host.c 按局内窗口取差判。没有会话 -1。</summary>
        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_stretch")]
        public static long Stretch(int which) => s_s == null ? -1 : which == 0 ? s_s.StretchOk : which == 1 ? s_s.StretchRisk : s_s.SqueezeRisk;

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_k")]
        public static float K() => s_s?.Rewriter.K ?? 1f;

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_texture")]
        public static int Texture(uint id, int w, int h, float scale, uint usage)
        {
            try { return s_s?.Texture(id, w, h, scale, usage) ?? w; } catch (Exception e) { Err(e); return w; }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_promoted")]
        public static int Promoted(uint* ids, int cap)
        {
            try { return s_s == null || ids == null || cap <= 0 ? 0 : s_s.Frame.TakePromoted(new Span<uint>(ids, cap)); } catch (Exception e) { Err(e); return 0; }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_view")]
        public static int View(uint id, uint parent, int level, int w0)
        {
            try { return s_s?.View(id, parent, level, w0) ?? w0; } catch (Exception e) { Err(e); return w0; }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_release")]
        public static void Release(uint id) { try { s_s?.Release(id); } catch (Exception e) { Err(e); } }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_gpu_wrote")]
        public static int GpuWrote(uint id, uint src) { try { return s_s?.GpuWrote(id, src) ?? 0; } catch (Exception e) { Err(e); return 0; } }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_layer_widen")]
        public static int LayerWiden(uint id, int w, int h) { try { return s_s?.Frame.LayerWiden(id, w, h) ?? w; } catch (Exception e) { Err(e); return w; } }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_map_x")]
        public static int MapX(uint tex, int x) { try { return s_s?.Frame.MapX(tex, x) ?? x; } catch (Exception e) { Err(e); return x; } }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_targets")]
        public static void Targets(uint color0, uint depth) { try { s_s?.Targets(color0, depth); } catch (Exception e) { Err(e); } }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_viewport")]
        public static int Viewport(float x, float w, float h, float scale)
        {
            try { if (s_s == null) return 0; s_s.Frame.OnViewport(x, w, MathF.Abs(h), scale > 0 ? scale : 1f); return s_s.Frame.TargetWide || s_s.Frame.TargetUndecided || s_s.Mode == WidenMode.Observe ? 1 : 0; }   // 未定目标：常量要交给核心按内容判画布   // 只观察：每笔都进核心（镜头抽样要看到绘制），画法恒 Keep
            catch (Exception e) { Err(e); return 1; }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_cbuf_bind")]
        public static void CbufBind(int stage, int slot, void* cpu, uint len)
        {
            long a0 = T0();
            try { s_s?.CbufBind(stage, slot, (nint)cpu, (int)Math.Min(len, int.MaxValue)); } catch (Exception e) { Err(e); }
            T1("宽屏导出·cbuf_bind", a0);
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_cbuf_bind_ranges")]
        public static void CbufBindRanges(int stage, int slot, void* cpu, uint len, uint* ranges, int n)
        {
            long a0 = T0();
            try
            {
                if (s_s == null) return;
                if (n <= 0 || ranges == null || n > 256) { s_s.CbufBind(stage, slot, (nint)cpu, (int)Math.Min(len, int.MaxValue)); return; }
                Span<(int Lo, int Hi)> r = stackalloc (int, int)[n];
                for (int i = 0; i < n; i++) r[i] = ((int)ranges[2 * i], (int)ranges[2 * i + 1]);
                s_s.CbufBindRanges(stage, slot, (nint)cpu, (int)Math.Min(len, int.MaxValue), r);
            }
            catch (Exception e) { Err(e); }
            T1("宽屏导出·cbuf_bind", a0);
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DrawIn
        {
            public float VpX, VpY, VpW, VpH, TargetScale;
            public fixed int Shader[6];
            public uint Flags;
            public WidenSession.Tex* Tex; public int NTex;
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct DrawOut { public int Mode; public fixed float Push[4]; public float FragScaleX; public uint Flags; public uint WantFlat; }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_note_fill")]
        public static void NoteFill(uint id, int w, int h, WidenSession.Tex* tex, int n)
        {
            try { if (s_s != null && tex != null && n > 0) s_s.NoteFill(id, w, h, new ReadOnlySpan<WidenSession.Tex>(tex, n)); } catch (Exception e) { Err(e); }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_draw")]
        public static int Draw(DrawIn* i, DrawOut* o)
        {
            long a0 = T0();
            try
            {
                if (o != null) { o->Mode = 0; o->Push[0] = o->Push[1] = o->Push[2] = o->Push[3] = 0; o->FragScaleX = 1; o->Flags = 0; o->WantFlat = 0; }
                if (s_s == null || i == null) return 0;
                var tex = i->Tex != null && i->NTex > 0 ? new ReadOnlySpan<WidenSession.Tex>(i->Tex, i->NTex) : default;
                Span<float> push = stackalloc float[4];
                ViewportMode m = s_s.Draw(i->VpX, i->VpW, i->VpH, i->TargetScale, new ReadOnlySpan<int>(i->Shader, 6), i->Flags, tex, push, out float fs);
                if (o != null) { o->Mode = (int)m; for (int k = 0; k < 4; k++) o->Push[k] = push[k]; o->FragScaleX = fs; o->Flags = (s_s.EmitsNone ? 1u : 0u) | (s_s.PageSides(out _, out _, out _, out _) ? 2u : 0u) | (s_s.UvExtend ? 4u : 0u); o->WantFlat = s_s.WantFlat; }
                return (int)m;
            }
            catch (Exception e) { Err(e); return 0; }
            finally { T1("宽屏导出·draw", a0); }
        }

        /// <summary>写深度 3D 笔旁路（WidenSession.DrawLight）：1 = 已按 ScaleK、出数 0 处理（out 同 s2a_widen_draw），0 = 照走 s2a_widen_draw。</summary>
        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_draw_light")]
        public static int DrawLight(DrawIn* i, DrawOut* o)
        {
            try
            {
                if (s_s == null || i == null) return 0;
                var tex = i->Tex != null && i->NTex > 0 ? new ReadOnlySpan<WidenSession.Tex>(i->Tex, i->NTex) : default;
                Span<float> push = stackalloc float[4];
                if (!s_s.DrawLight(i->VpX, i->VpW, i->VpH, i->TargetScale, i->Flags, tex, push, out float fs)) return 0;
                if (o != null) { o->Mode = (int)ViewportMode.ScaleK; for (int k = 0; k < 4; k++) o->Push[k] = 0; o->FragScaleX = fs; o->Flags = 0; o->WantFlat = 0; }
                return 1;
            }
            catch (Exception e) { Err(e); return 0; }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_page_sides")]
        public static int PageSides(int* cols)
        {
            try
            {
                if (s_s == null || cols == null || !s_s.PageSides(out int m0, out int c0, out int c1, out int m1)) return 0;
                cols[0] = m0; cols[1] = c0; cols[2] = c1; cols[3] = m1; return 1;
            }
            catch (Exception e) { Err(e); return 0; }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_page_rows")]
        public static int PageRows(int* rows)
        {
            try
            {
                if (s_s == null || rows == null || !s_s.PageRows(out int r0, out int c0, out int c1, out int r1)) return 0;
                rows[0] = r0; rows[1] = c0; rows[2] = c1; rows[3] = r1; return 1;
            }
            catch (Exception e) { Err(e); return 0; }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_state_gen")]
        public static long StateGen() { try { return s_s?.StateGen ?? 0; } catch (Exception e) { Err(e); return 0; } }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_map_viewport")]
        public static void MapViewport(int mode, float* x, float* w)
        {
            try { if (s_s != null && x != null && w != null) s_s.Frame.MapViewport((ViewportMode)mode, ref *x, ref *w); } catch (Exception e) { Err(e); }
        }

        // ---------- 窄屏上下多画（10-26 任意宽高比）：纵向的对应件 ----------
        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_ky")]
        public static float Ky() => s_s?.Rewriter.Ky ?? 1f;

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_tex_guest_w")]
        public static int TexGuestW(uint id, int w)
        {
            try { return s_s != null && s_s.Frame.TryWide(id, out int w0, out _) ? w0 : w; } catch (Exception e) { Err(e); return w; }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_tex_h")]
        public static int TexH(uint id, int h)
        {
            try { return s_s != null && s_s.Frame.TryTall(id, out _, out int h1) ? h1 : h; } catch (Exception e) { Err(e); return h; }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_map_viewport_y")]
        public static void MapViewportY(int mode, float* y, float* h)
        {
            try { if (s_s != null && y != null && h != null) s_s.Frame.MapViewportY((ViewportMode)mode, ref *y, ref *h); } catch (Exception e) { Err(e); }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_map_scissor_y")]
        public static void MapScissorY(int mode, int* y, int* h)
        {
            try { if (s_s != null && y != null && h != null) s_s.Frame.MapScissorY((ViewportMode)mode, ref *y, ref *h); } catch (Exception e) { Err(e); }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_frag_scale_y")]
        public static float FragScaleY() => s_s?.FragScaleY ?? 1f;

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_map_scissor")]
        public static void MapScissor(int mode, int* x, int* w)
        {
            try { if (s_s != null && x != null && w != null) s_s.Frame.MapScissor((ViewportMode)mode, ref *x, ref *w); } catch (Exception e) { Err(e); }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_cbuf_emit")]
        public static uint CbufEmit(int stage, int slot, void* scratch, uint cap)
        {
            long a0 = T0();
            try { return s_s == null ? 0u : (uint)s_s.CbufEmit(stage, slot, scratch == null ? default : new Span<byte>(scratch, (int)Math.Min(cap, int.MaxValue))); }
            catch (Exception e) { Err(e); return 0; }
            finally { T1("宽屏导出·cbuf_emit", a0); }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_dispatch")]
        public static void Dispatch(int* shader, int narrowOnly)
        {
            long a0 = T0();
            try { if (s_s != null && shader != null) s_s.Dispatch(new ReadOnlySpan<int>(shader, 6), narrowOnly != 0); } catch (Exception e) { Err(e); }
            T1("宽屏导出·dispatch", a0);
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_groups_x")]
        public static int GroupsX(int gx, int gy, int w0, int w1, int h) => WidenFrame.WidenGroupsX(gx, gy, w0, w1, h);

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_target_cleared")]
        public static void TargetCleared(uint tex) { try { s_s?.Frame.OnTargetCleared(tex); } catch (Exception e) { Err(e); } }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_pure2d")]
        public static int Pure2D() { try { return s_s != null && s_s.Rewriter.Pure2DRecent ? 1 : 0; } catch (Exception e) { Err(e); return 0; } }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_side_coverage")]
        public static void SideCoverage(int leftDrawn, int rightDrawn, int leftUndrawn, int rightUndrawn, uint sig) { try { s_s?.SideCoverage(leftDrawn != 0, rightDrawn != 0, leftUndrawn != 0, rightUndrawn != 0, sig); } catch (Exception e) { Err(e); } }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_shader")]
        public static int Shader(int stage, byte* useText, uint flags)
        {
            try { return s_s?.Shader(useText == null ? null : Marshal.PtrToStringUTF8((nint)useText), (flags & 1) != 0) ?? 0; }
            catch (Exception e) { Err(e); return 0; }
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Crop { public int Left, Right, Top, Bottom; public float AspectX, AspectY; }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_present")]
        public static int Present(uint tex, Crop* c)
        {
            try
            {
                if (s_s == null) return 0;
                Crop z = default; Crop* p = c != null ? c : &z;
                return s_s.Present(tex, ref p->Left, ref p->Right, ref p->Top, ref p->Bottom, ref p->AspectX, p->AspectY);
            }
            catch (Exception e) { Err(e); return 0; }
        }

        // ---------- 离线 ----------
        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_spirv_vertex")]
        public static nuint SpirvVertex(byte* spv, nuint len, byte* outp, nuint cap)
        {
            try
            {
                if (spv == null || len == 0) return 0;
                byte[] o = WidenShaders.Vertex(new ReadOnlySpan<byte>(spv, (int)len).ToArray(), out bool patched);
                if (!patched) return 0;
                if ((nuint)o.Length <= cap && outp != null) o.CopyTo(new Span<byte>(outp, o.Length));
                return (nuint)o.Length;
            }
            catch (Exception e) { Err(e); return 0; }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_spirv_cbuf_use")]
        public static nuint SpirvCbufUse(byte* spv, nuint len, int* slotOfBinding, int nmap, byte* outp, nuint cap)
        {
            try
            {
                if (spv == null || len == 0) return 0;
                var uses = Widen.SpirvCbufUse.Analyze(new ReadOnlySpan<byte>(spv, (int)len));
                string t = SpirvCbufUseText.Format(uses, slotOfBinding != null && nmap > 0 ? new ReadOnlySpan<int>(slotOfBinding, nmap) : default);
                return Put(t, outp, cap);
            }
            catch (Exception e) { Err(e); return 0; }
        }

        // ---------- 诊断 ----------
        // ---------- 几何判据（11-06，移植通用模式 WidenRenderer.GeomCoversNow）：「原尺寸居中层收缩 + 推满」只给两侧都贴画布边的整画布层 ----------
        // 宿主把顶点着色器的位置切片（直连库 json pos_slice，SpirvPosSlice.Packed）、本笔要算的顶点号表和两个读数回调交进来，核心逐个顶点解释执行求 gl_Position.x / w。
        //   返回 1 铺满（各顶点 NDC x/w 最小 ≤ −1、最大 ≥ 1，容差 1e-3）、0 只盖一部分、−1 判不出（切片坏、读不到输入、w ≤ 0）；mnmx（可空）写 NDC 最小 / 最大
        [StructLayout(LayoutKind.Sequential)]
        public struct GeomEnvC
        {
            public delegate* unmanaged<void*, int, int, uint, uint, uint*, int> Attr;   // (u, location, 分量, 顶点号, 实例号, 出值位) → 1 读到 / 0 读不到
            public delegate* unmanaged<void*, int, int, uint*, int> Ubo;                 // (u, SPIR-V 绑定号, 字节偏移, 出值位) → 1 / 0
            public void* U;
        }
        sealed class GeomEnvAdapter : IPosEnv
        {
            public GeomEnvC* E; public uint Vid, Iid; public bool Failed;
            public bool Stop => Failed;
            public string What;
            public bool Attr(int location, int lane, out uint bits) { uint b = lane == 3 ? 0x3f800000u : 0; int ok = E->Attr(E->U, location, lane, Vid, Iid, &b); bits = b; if (ok == 0 && !Failed) { Failed = true; What = $"属性 {location}.{lane}"; } return ok != 0; }
            public uint Builtin(uint bi) => bi switch { 42 or 5 => Vid, 43 or 6 => Iid, _ => 0 };
            public bool Ubo(int binding, int byteOffset, out uint bits) { uint b = 0; int ok = E->Ubo(E->U, binding, byteOffset, &b); bits = b; if (ok == 0 && !Failed) { Failed = true; What = $"常量 绑定 {binding} 偏移 {byteOffset}"; } return ok != 0; }
        }
        static readonly System.Collections.Generic.Dictionary<ulong, SpirvPosSlice> s_slices = new();
        static readonly GeomEnvAdapter s_genv = new();
        public static long GeomEvals, GeomFails;
        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_geom")]
        public static int Geom(ulong key, byte* slice, int len, uint* vids, int n, uint inst, GeomEnvC* env, float* mnmx)
        {
            try
            {
                if (slice == null || len <= 0 || vids == null || n <= 0 || n > 64 || env == null) return -1;
                if (!s_slices.TryGetValue(key, out SpirvPosSlice ps)) { ps = SpirvPosSlice.FromPacked(new ReadOnlySpan<byte>(slice, len).ToArray()); if (s_slices.Count > 4096) s_slices.Clear(); s_slices[key] = ps; }
                if (ps == null) { SetWhy("切片解不开"); return -1; }
                GeomEvals++; s_genv.E = env; s_genv.Failed = false; s_genv.Iid = inst; float mn = float.MaxValue, mx = float.MinValue;
                for (int i = 0; i < n; i++)
                {
                    s_genv.Vid = vids[i];
                    if (!ps.Eval(s_genv, out float x, out float w) || !(w > 1e-6f)) { GeomFails++; SetWhy(s_genv.Failed ? $"读不到{s_genv.What}（顶点 {vids[i]}）" : ps.LastFail ?? $"w = {w}"); return -1; }
                    float t = x / w; if (t < mn) mn = t; if (t > mx) mx = t;
                }
                if (mnmx != null) { mnmx[0] = mn; mnmx[1] = mx; }
                return mn <= -1f + 1e-3f && mx >= 1f - 1e-3f ? 1 : 0;
            }
            catch (Exception e) { Err(e); return -1; }
        }
        static byte* s_why;
        static void SetWhy(string w) { if (s_why == null) s_why = (byte*)NativeMemory.Alloc(512); int n = Encoding.UTF8.GetBytes((w ?? "").AsSpan(0, Math.Min((w ?? "").Length, 160)), new Span<byte>(s_why, 511)); s_why[n] = 0; }
        /// <summary>上一次 s2a_widen_geom 返回 −1 的原因（UTF-8，宿主打日志用）。</summary>
        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_geom_why")]
        public static byte* GeomWhy() { if (s_why == null) SetWhy(""); return s_why; }
        // 核心在收缩候选笔上回调宿主要这笔的几何结论（1 / 0 / −1 同 s2a_widen_geom；−2 = 这支顶点着色器没有位置切片，照旧收缩）；没设 = −2
        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_set_geom_cb")]
        public static void SetGeomCb(delegate* unmanaged<int> cb) { s_geomCb = cb; }
        static delegate* unmanaged<int> s_geomCb;
        internal static int GeomNow() => s_geomCb != null ? s_geomCb() : -2;   // 宿主没接回调 = 没有位置切片（照旧）

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_alloc_bytes")]
        public static ulong AllocBytes() => (ulong)GC.GetAllocatedBytesForCurrentThread();

        [UnmanagedCallersOnly(EntryPoint = "s2a_widen_report")]
        public static int Report(byte* buf, int cap)
        {
            try
            {
                string t = s_s?.Report() ?? $"[宽屏·核心] 没有会话（异常 {s_errors}）";
                nuint n = Put(t, buf, cap <= 0 ? 0 : (nuint)cap);
                return (int)Math.Min((long)n - 1, Math.Max(0, cap - 1));
            }
            catch (Exception e) { Err(e); return 0; }
        }

        /// <summary>UTF-8 写进 buf（含结尾 0；装不下就截断并保证以 0 结尾）。返回完整需要的字节数（含结尾 0）。</summary>
        static nuint Put(string t, byte* buf, nuint cap)
        {
            int need = Encoding.UTF8.GetByteCount(t) + 1;
            if (buf != null && cap > 0)
            {
                byte[] b = Encoding.UTF8.GetBytes(t);
                int n = (int)Math.Min((nuint)b.Length, cap - 1);
                // 截断落在多字节字符中间（下一个字节是 UTF-8 后续字节 10xxxxxx）就退到这个字符开头：宿主把它原样写进 host.log，
                //   半个汉字（「写回原\xe5\x80」）让 iOS 诊断包把整份日志按 Latin-1 解成乱码（已收诊断里 264 份、467 个日志文件中招）
                while (n > 0 && n < b.Length && (b[n] & 0xC0) == 0x80) n--;
                new ReadOnlySpan<byte>(b, 0, n).CopyTo(new Span<byte>(buf, n));
                buf[n] = 0;
            }
            return (nuint)need;
        }
    }
}
