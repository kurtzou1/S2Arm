using System.IO;
// graphics/widen 单元测试：期望值全部手算（宽高比、矩阵元素），不跑被测实现推期望。用法：dotnet run -c Release；退出码 = 失败项数。
using S2Arm.Gfx.Widen;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

static class T
{
    static int fails, total;
    static void Check(string name, object want, object got)
    {
        total++;
        bool ok = want is float fw && got is float fg ? MathF.Abs(fw - fg) <= 1e-4f * MathF.Max(1, MathF.Abs(fw)) : Equals(want, got);
        if (!ok) fails++;
        Console.WriteLine($"{(ok ? "过" : "【红】")}  {name}：期望 {want} → 真结果 {got}");
    }

    const float A0 = 2868f / 1320f;              // 屏幕 2.172727
    const float K = 2346f / 1920f;               // 吸附：1920 多 426 列（偶数）→ 1.221875
    const float A = K * 16f / 9f;                // 2346/1080 = 2.172222
    static byte[] B(params float[] f) => MemoryMarshal.AsBytes(f.AsSpan()).ToArray();
    static float[] Fl(byte[] b) => MemoryMarshal.Cast<byte, float>(b).ToArray();
    // fovy 45°：P11 = 1/tan(22.5°) = 2.4142136，P00 = P11 ÷ (16/9) = 1.3579951
    const float P11 = 2.4142136f, P00 = 1.3579951f;
    static float[] Proj() => new[] { P00, 0, 0, 0, 0, P11, 0, 0, 0, 0, -1.0002f, -0.20002f, 0, 0, -1, 0 };

    /// <summary>模拟 GPU 上的缓冲字节：包装层转发的上传（OnBufferData 返回 true 时发 scratch）、缓冲间拷贝、IBufferPatcher 写，都落到这里。</summary>
    /// <summary>越界外推语义用例：属性 0 = (X, 0, 0, 1)；support_buffer（绑定 0）第 10 成员 s2a_widen（偏移 64）= (外推量 D, 门限² E2, 收缩量 Z, 0)。</summary>
    sealed class EdgeEnv : IPosEnv
    {
        public float X, D, E2, Z;
        public bool Attr(int location, int lane, out uint bits) { bits = BitConverter.SingleToUInt32Bits(location == 0 ? lane switch { 0 => X, 3 => 1f, _ => 0f } : 0f); return location == 0; }
        public uint Builtin(uint builtIn) => 0;
        public bool Ubo(int binding, int byteOffset, out uint bits)
        {
            bits = 0; if (binding != 0) return false;
            float v = byteOffset switch { 64 => D, 68 => E2, 72 => Z, _ => 0f };
            bits = BitConverter.SingleToUInt32Bits(v); return true;
        }
    }

    sealed class GpuSim : IBufferPatcher
    {
        readonly Dictionary<ulong, byte[]> _b = new(); public int Writes;
        public byte[] Buf(ulong k) { if (!_b.TryGetValue(k, out var a)) _b[k] = a = new byte[4096]; return a; }
        public void Write(ulong b, int o, ReadOnlySpan<byte> d) { Writes++; d.CopyTo(Buf(b).AsSpan(o)); }
        public void Up(WidenFrame f, ulong b, int o, byte[] d) { var s = new byte[d.Length]; (f.OnBufferData(b, o, d, s) ? s : d).CopyTo(Buf(b), o); }
        public void Copy(WidenFrame f, ulong s, ulong d, int so, int dof, int n) { f.OnCopyBuffer(s, d, so, dof, n); Array.Copy(Buf(s), so, Buf(d), dof, n); }
    }
    sealed class NullPatcher : IBufferPatcher { public void Write(ulong b, int o, ReadOnlySpan<byte> d) { } }
    sealed class Rec : IBufferPatcher { public List<(ulong, int, float[])> W = new(); public void Write(ulong b, int o, ReadOnlySpan<byte> d) => W.Add((b, o, MemoryMarshal.Cast<byte, float>(d).ToArray())); }

    // ---------- 直连会话（WidenSession，export/s2a_widen.h 的实现）：常量就在游戏内存里，绑定时比影子、出数时按命中状态拼 ----------
    /// <summary>钉住的游戏内存（地址按 256 对齐，同 NVN 常量缓冲对齐要求）：返回地址与对齐处在数组里的下标。</summary>
    static nint Pinned(int len, out byte[] arr, out int at)
    {
        arr = GC.AllocateArray<byte>(len + 256, pinned: true);
        nint p0 = Marshal.UnsafeAddrOfPinnedArrayElement(arr, 0);
        at = (int)((256 - ((long)p0 & 255)) & 255);
        return p0 + at;
    }

    static void DirectSession()
    {
        // 模式判定（同 10-21 Compose.cs 的两行，手算四种）
        // 存储放不宽的颜色目标（11-02 饥荒：交换链 1920 当颜色、放宽过的深度当深度，按深度判成放宽目标 → 视口画出存储被裁、整幅偏右）。手算期望：
        //   深度 5（1920×1080，UseRt）放宽到 2346；颜色 1 不带 UseRt（存储放不宽）→ 目标 (1, 5) 不放宽；颜色 9 没登记过 → (9, 5) 照旧按深度放宽；
        //   颜色 1 后来带 UseRt 重登记 → (1, 5) 放宽；先设目标 (2, 5)、再把 2 登记成放不宽 → 当场重判为不放宽
        {
            var s = new WidenSession(2346, 1080, false, true, false);
            int dw = s.Texture(5, 1920, 1080, 1, WidenSession.UseRt); int cw = s.Texture(1, 1920, 1080, 1, 0);
            s.Targets(1, 5); bool fixedWide = s.Frame.TargetWide;
            s.Targets(9, 5); bool unregWide = s.Frame.TargetWide;
            s.Texture(1, 1920, 1080, 1, WidenSession.UseRt); s.Targets(1, 5); bool reWide = s.Frame.TargetWide;
            s.Targets(2, 5); bool before = s.Frame.TargetWide; s.Texture(2, 1920, 1080, 1, 0); bool after = s.Frame.TargetWide;
            Check("放不宽的颜色目标：不从深度继承放宽（深度宽 / 颜色宽 / 定宽颜色 / 没登记颜色 / 重登记 / 当场重判前后）", "2346 1920 False True True True False",
                  $"{dw} {cw} {fixedWide} {unregWide} {reWide} {before} {after}");
        }
        // 认不出镜头、只采样没放宽的渲染目标（11-02 你裁我剪登场光晕：离屏 1024×512 合成回放宽上屏目标）：原尺寸居中，不按 k 整幅拉开（拉开会与 Hor 世界错位成副本）。手算期望：
        //   上屏目标 1（1920×1080）放宽、离屏 486（1024×512，不属 16:9 一族）登记不放宽；目标 1 上不读常量的一笔：只采 486 → CenterNative；
        //   采 CPU 图集 7（不是渲染目标）→ ScaleK（同改前）；采 486 + 放宽的 1 → ScaleK（采样了放宽贴图，同改前）；
        //   16:9 一族的没放宽渲染目标是整幅画面 → 照旧按 k 铺满（见下「当过渲染目标、没放宽的 16:9 贴图」）
        {
            var s = new WidenSession(2346, 1080, false, true, false);
            s.Texture(1, 1920, 1080, 1, WidenSession.UseRt); s.Texture(486, 1024, 512, 1, WidenSession.UseRt);
            int h = s.Shader("", false); int[] sh = { h, 0, 0, 0, 0, 0 }; Span<float> push = stackalloc float[4];
            s.Frame.OnRenderTargets(1, 0);
            var mn = s.Draw(0, 1564, 720, 1, sh, WidenSession.DrawColor, new[] { new WidenSession.Tex { Id = 486, W = 1024, H = 512, Scale = 1 } }, push, out _);
            var mc = s.Draw(0, 1564, 720, 1, sh, WidenSession.DrawColor, new[] { new WidenSession.Tex { Id = 7, W = 1024, H = 1024, Scale = 1 } }, push, out _);
            var mw = s.Draw(0, 1564, 720, 1, sh, WidenSession.DrawColor, new[] { new WidenSession.Tex { Id = 486, W = 1024, H = 512, Scale = 1 }, new WidenSession.Tex { Id = 1, W = 1920, H = 1080, Scale = 1 } }, push, out _);
            Check("认不出镜头的合成笔：只采没放宽离屏层 → 原尺寸居中；采 CPU 图集 / 采到放宽贴图 → 照旧按 k 铺满", "CenterNative ScaleK ScaleK", $"{mn} {mc} {mw}");
            // 11-06 马车8 比赛看台：材质笔采资源贴图 + 一张没放宽的小渲染目标（前几帧画好的 32×32 探针）→ 是 3D 表面不是离屏层合成，照旧按 k 铺满；
            //   离屏层 + ≤8×8 占位小图仍算纯合成 → 原尺寸居中。手算期望：ScaleK CenterNative
            s.Texture(9, 32, 32, 1, WidenSession.UseRt);
            var mm = s.Draw(0, 1564, 720, 1, sh, WidenSession.DrawColor, new[] { new WidenSession.Tex { Id = 7, W = 1024, H = 1024, Scale = 1 }, new WidenSession.Tex { Id = 9, W = 32, H = 32, Scale = 1 } }, push, out _);
            var mp = s.Draw(0, 1564, 720, 1, sh, WidenSession.DrawColor, new[] { new WidenSession.Tex { Id = 486, W = 1024, H = 512, Scale = 1 }, new WidenSession.Tex { Id = 8, W = 4, H = 4, Scale = 1 } }, push, out _);
            Check("采资源贴图 + 没放宽小渲染目标的材质笔 → 照旧按 k 铺满；离屏层 + 占位小图 → 原尺寸居中", "ScaleK CenterNative", $"{mm} {mp}");
        }
        // 游戏自己出宽图（第二层，Ui 模式）：宿主不放宽渲染目标，游戏的场景层按宽尺寸画（11-02 维护者 测试设备1 塞尔达：场景 1564×720 不属 16:9 一族、登记过渲染目标）。
        //   上屏目标 1 按屏幕比视口 1564×720 画（原生宽区域）、只采样场景层 50 的一笔 → 不收进原尺寸居中（期望 ScaleK，同 968a20ebe 之前）；改前是 CenterNative，整幅场景缩成中间 1/k
        {
            var s = new WidenSession(2346, 1080, true, false, false);
            s.Texture(1, 1920, 1080, 1, WidenSession.UseRt); s.Texture(50, 1564, 720, 1, WidenSession.UseRt);
            int h = s.Shader("", false); int[] sh = { h, 0, 0, 0, 0, 0 }; Span<float> push = stackalloc float[4];
            s.Frame.OnRenderTargets(1, 0);
            var mg = s.Draw(0, 1564, 720, 1, sh, WidenSession.DrawColor, new[] { new WidenSession.Tex { Id = 50, W = 1564, H = 720, Scale = 1 } }, push, out _);
            Check("游戏自己出宽图：采样游戏宽场景层的铺满笔不收进原尺寸居中", "ScaleK", $"{mg}");
        }
        Check("模式：屏宽 1920 → 只观察、16:9", "Off 1.777778", $"{WidenSession.Decide(1920, 1080, true, true, out float a0)} {a0:F6}");
        Check("模式：第二层生效 → 只管界面层、2346/1080", "Ui 2.172222", $"{WidenSession.Decide(2346, 1080, true, false, out float a1)} {a1:F6}");
        Check("模式：第三层表验过 → 整套放宽", "All 2.172222", $"{WidenSession.Decide(2346, 1080, false, true, out float a2)} {a2:F6}");
        Check("模式：都没有 → 16:9 居中留黑边", "Pillar 1.777778", $"{WidenSession.Decide(2346, 1080, false, false, out float a3)} {a3:F6}");

        // 10-26 任意宽高比：屏幕比 16:9 窄（iPhone Duo 内屏 2670×1878 = 1.4217）→ 宽守 1920、高 1920 / 1.4217 = 1350.5 取偶 1350，上下多画。期望手算：
        //   Ky：1080 高多出 2·round(540·(16/9 ÷ 1.4217 − 1)) = 2·round(135.2) = 270 行 → Ky = 1350 / 1080 = 1.25；投影 y 行 × 0.8、x 行不动；1080 → 1350、720 → 900
        Check("窄屏模式：屏高 1350 → 整套放宽、宽高比 1920/1350", "All 1.422222", $"{WidenSession.Decide(1920, 1350, false, true, out float an)} {an:F6}");
        Check("窄屏模式：没验过 → 16:9 居中留黑边", "Pillar 1.777778", $"{WidenSession.Decide(1920, 1350, false, false, out float ap)} {ap:F6}");
        {
            var rn = new WidenRewriter(2670f / 1878f);
            Check("窄屏重写器：K = 1、Ky = 1.25、开", "1.000000 1.250000 True True", $"{rn.K:F6} {rn.Ky:F6} {rn.On} {rn.Tall}");
            Check("窄屏放高：1920×1080 → 1350、1280×720 → 900、宽不动", "1350 900 1920 1280", $"{rn.WidenHeight(1920, 1080)} {rn.WidenHeight(1280, 720)} {rn.WidenWidth(1920, 1080)} {rn.WidenWidth(1280, 720)}");
            Check("窄屏放高：不属 16:9 一族不改（512×512）", 512, rn.WidenHeight(512, 512));
            {   // 通用层高屏上屏比例（审计 #1565 P1-117，11-05 Mac 1920×1350 通用层异度神剑3 读数：出图 1920×1080 取 1280×720，上屏宽高比 12.8:9 → 整屏竖向拉 1.25 倍）
                //   期望手算：Ky = 1.25 → 屏幕比 16/9 ÷ 1.25 = 1.422222，ay = 9 时 ax = 12.8；16:9 贴图 ax = 16
                var gf = new WidenFrame(rn);
                Check("通用层高屏上屏：16:9 贴图（1920×1080，MapCrop 给了 12.8）→ 回到 16:9（ax 16）", "16.0000", gf.GenericPresentAspectX(12.8f, 9f, 1920, 1080).ToString("F4"));
                Check("通用层高屏上屏：16:9 贴图、没放宽登记（ax 16）→ 仍 16", "16.0000", gf.GenericPresentAspectX(16f, 9f, 1280, 720).ToString("F4"));
                Check("通用层高屏上屏：游戏按加长分辨率出 1280×900 → 按屏幕比（ax 12.8）", "12.8000", gf.GenericPresentAspectX(16f, 9f, 1280, 900).ToString("F4"));
                Check("通用层上屏：宽屏（Ky = 1）原样", "21.7222", new WidenFrame(new WidenRewriter(2346f / 1080f)).GenericPresentAspectX(21.7222f, 9f, 1564, 720).ToString("F4"));
                Check("通用层高屏上屏：宽高比缺失（0）原样", "0.0000", gf.GenericPresentAspectX(0f, 9f, 1280, 900).ToString("F4"));
            }
            TallPresentCheck.Run(Check);   // 同一组期望经生产 WidenWindow.Present 再核一遍（审计 #1592 P1-118）
            byte[] src = B(Proj()), dst = new byte[src.Length];
            bool hit = rn.Rewrite(src, 0, dst);
            float[] o = Fl(dst);
            Check("窄屏投影：P00 不动、P11 × 0.8", $"True {P00:F6} {P11 * 0.8f:F6}", $"{hit} {o[0]:F6} {o[5]:F6}");
            byte[] ss = B(1920, 1080, 1 / 1920f, 1 / 1080f), sd = new byte[16];
            rn.Rewrite(ss, 0, sd);
            Check("窄屏屏幕尺寸常量 (W, H, 1/W, 1/H)：宽不动、高 → 1350", $"1920 1350 {1 / 1920f:G9} {1 / 1350f:G9}", string.Join(" ", Array.ConvertAll(Fl(sd), v => v.ToString("G9"))));
            var rw = new WidenRewriter(2346f / 1080f);
            byte[] sd2 = new byte[16];
            rw.Rewrite(ss, 0, sd2);
            Check("宽屏屏幕尺寸常量：高的两位逐位不变（窄屏改动不碰宽屏）", true, Fl(sd2)[1] == 1080f && BitConverter.SingleToInt32Bits(Fl(sd2)[3]) == BitConverter.SingleToInt32Bits(1 / 1080f) && rw.Ky == 1f);
        }
        // 拉伸风险（11-06 满屏泛化）①：游戏自己已按屏幕比算的镜头只登记、不改写。屏 2346×1080：K = 2346 / 1920，屏幕比 = 2346 / 1080 ≈ 2.1722。
        //   手算期望：行存透视投影 P00 = f / 比、P11 = f（f = 1.7321，近 0.1 远 1000）；比 = 16:9 → 认作投影并改写（P00 × 1/K）；比 = 屏幕比 → WideProjection，原样不动、计数 +1
        {
            float f = 1.7321f, n0 = 0.1f, f0 = 1000f;
            byte[] Proj(float aspect) { var m = new float[16]; m[0] = f / aspect; m[5] = f; m[10] = -(f0 + n0) / (f0 - n0); m[11] = -2 * f0 * n0 / (f0 - n0); m[14] = -1; var b = new byte[64]; Buffer.BlockCopy(m, 0, b, 0, 64); return b; }
            var rw = new WidenRewriter(2346f / 1080f);
            byte[] p16 = Proj(16f / 9f), d16 = new byte[64]; bool h16 = rw.Rewrite(p16, 0, d16);
            float p00 = BitConverter.ToSingle(d16, 0);
            Check("拉伸风险①：16:9 镜头照旧改写（改写后 P00 × K ÷ 原 P00 = 1）", "True 1.0000", $"{h16} {(p00 / (f / (16f / 9f)) * (2346f / 1920f)):F4}");
            long w0 = rw.Stats.WideProjection;
            byte[] pw = Proj(2346f / 1080f), dw = new byte[64]; rw.Rewrite(pw, 0, dw);
            Check("拉伸风险①：屏幕比镜头认作游戏自己的宽镜头、原样不改、计数 +1", "True 1", $"{dw.AsSpan().SequenceEqual(pw)} {rw.Stats.WideProjection - w0}");
            var r169 = new WidenRewriter(16f / 9f); long z0 = r169.Stats.WideProjection; r169.Rewrite(Proj(16f / 9f), 0, new byte[64]);
            Check("拉伸风险①：屏幕本身就是 16:9 时不判宽镜头（分不开）", 0L, r169.Stats.WideProjection - z0);
        }
        // 拉伸风险②：放宽目标（1920×1080 → 2346）上挂深度、写颜色的场景笔。手算期望：
        //   不读任何常量、不采样 → 按 k 拉宽（ScaleK）= 拉伸 1；采样了放宽的目标 1 = 整屏合成 → 对 1；不挂深度的笔不计
        {
            var s = new WidenSession(2346, 1080, false, true, false);
            s.Texture(1, 1920, 1080, 1, WidenSession.UseRt); s.Texture(2, 1920, 1080, 1, WidenSession.UseRt); s.Texture(3, 1920, 1080, 1, WidenSession.UseRt);
            int h = s.Shader("", false); int[] sh = { h, 0, 0, 0, 0, 0 }; Span<float> push = stackalloc float[4];
            s.Targets(2, 3);
            var m1 = s.Draw(0, 1564, 720, 1, sh, WidenSession.DrawColor, Array.Empty<WidenSession.Tex>(), push, out _);
            var m2 = s.Draw(0, 1564, 720, 1, sh, WidenSession.DrawColor, new[] { new WidenSession.Tex { Id = 1, W = 1920, H = 1080, Scale = 1 } }, push, out _);
            s.Targets(2, 0); s.Draw(0, 1564, 720, 1, sh, WidenSession.DrawColor, Array.Empty<WidenSession.Tex>(), push, out _);
            Check("拉伸风险②：深度场景笔没读镜头按 k 拉宽 → 拉伸 1；采样放宽目标 → 对 1；无深度不计", "ScaleK 1 1 0", $"{m1} {s.StretchRisk} {s.StretchOk} {s.SqueezeRisk}");
        }
        // 窄屏帧层（第 2 段）：屏 1920×1350（Ky 1.25，pad = 135）。期望手算：1920×1080 目标宽不动、高 1350；1 级视图 960×540 → 675；
        //   视口 y：Hor 全高 (0, 1080) → 中心 540 + 135 = 675、高 1350 → (0, 1350)；界面层同 Hor 居中 y + 135（11-02 起，原贴底 + 270）；原比例页居中 y + 135；全屏遍 (100, 200) × 1.25 → (125, 250)
        //   剪刀 y：Hor 盖全高 → 铺满 (0, 1350)；Hor 局部 (100, 50) → (235, 50)；全屏遍 (100, 201) → floor 125、ceil 376.25 = 377 → (125, 252)
        //   上屏竖裁 (0, 1080) → (0, 1350)；片元 y 倍率：全屏遍读片元坐标 1.25、不读 1
        {
            var s = new WidenSession(1920, 1350, false, true, false);
            int tw = s.Texture(10, 1920, 1080, 1, WidenSession.UseRt);
            bool t10 = s.Frame.TryTall(10, out int h0, out int h1);
            Check("窄屏帧层：1920×1080 目标宽不动、登记加高 1080 → 1350、也算放宽一族（宽不变）", "1920 True 1080 1350 True", $"{tw} {t10} {h0} {h1} {s.Frame.IsWide(10)}");
            int vw = s.View(11, 10, 1, 960); s.Frame.TryTall(11, out int vh0, out int vh1);
            Check("窄屏帧层：1 级视图宽不动、高 540 → 675", "960 540 675", $"{vw} {vh0} {vh1}");
            s.Texture(12, 512, 512, 1, WidenSession.UseRt);
            Check("窄屏帧层：512×512 不属 16:9 一族、不加高", false, s.Frame.TryTall(12, out _, out _));
            s.Frame.OnRenderTargets(10, 0);
            float y = 0, h = 1080; s.Frame.MapViewportY(ViewportMode.Hor, ref y, ref h);
            float yc = 0, hc = 1080; s.Frame.MapViewportY(ViewportMode.CenterNative, ref yc, ref hc);
            float yp = 0, hp = 1080; s.Frame.MapViewportY(ViewportMode.Page, ref yp, ref hp);
            float yk = 100, hk = 200; s.Frame.MapViewportY(ViewportMode.ScaleK, ref yk, ref hk);
            Check("窄屏视口 y：Hor / 界面层居中 / 原比例页居中 / 全屏遍", "0 1350 135 1080 135 1080 125 250", $"{y} {h} {yc} {hc} {yp} {hp} {yk} {hk}");
            int sy = 0, sh = 1080; s.Frame.MapScissorY(ViewportMode.Hor, ref sy, ref sh);
            int sy2 = 100, sh2 = 50; s.Frame.MapScissorY(ViewportMode.Hor, ref sy2, ref sh2);
            int sy3 = 100, sh3 = 201; s.Frame.MapScissorY(ViewportMode.ScaleK, ref sy3, ref sh3);
            Check("窄屏剪刀 y：Hor 盖全高铺满 / Hor 局部下移 / 全屏遍外扩取整", "0 1350 235 50 125 252", $"{sy} {sh} {sy2} {sh2} {sy3} {sh3}");
            int ct = 0, cb = 1080; s.Frame.MapCropY(10, ref ct, ref cb);
            int ut = 0, ub = 512; s.Frame.MapCropY(12, ref ut, ref ub);
            Check("窄屏上屏竖裁：加高图 (0, 1080) → (0, 1350)、没加高的原样", "0 1350 0 512", $"{ct} {cb} {ut} {ub}");
            Check("窄屏片元 y 倍率：全屏遍读片元坐标 1.25、不读 1、Keep 1", "1.25 1 1", $"{s.Frame.FragScaleY(ViewportMode.ScaleK, true)} {s.Frame.FragScaleY(ViewportMode.ScaleK, false)} {s.Frame.FragScaleY(ViewportMode.Keep, true)}");
            // 10-26 Duo 真机（屏 2034×1398 → 高 1318、Ky 1.2204）：720 放到 878，比值除不尽。手算：额外行 2·round(540·(16/9 ÷ 1920/1318 − 1)) = 238；
            //   720 × 238 / 1080 = 158.67 不整除 → 720 + 2·round(79.33) = 878。上屏竖裁 (0, 720) → (0, 878)：浮点 720 × (878/720) 向上取整得 879（多一行，上屏整帧被拒、全黑）；
            //   剪刀全屏遍 (0, 720) → (0, 878)、(100, 201) → floor(121.94) = 121、ceil(367.06) = 368 → (121, 247)
            {
                var d = new WidenSession(1920, 1318, false, true, false);
                d.Texture(30, 1280, 720, 1, WidenSession.UseRt); d.Frame.TryTall(30, out _, out int dh1);
                int t0 = 0, b0 = 720; d.Frame.MapCropY(30, ref t0, ref b0);
                d.Frame.OnRenderTargets(30, 0);
                int q0 = 0, r0 = 720; d.Frame.MapScissorY(ViewportMode.ScaleK, ref q0, ref r0);
                int q1 = 100, r1 = 201; d.Frame.MapScissorY(ViewportMode.ScaleK, ref q1, ref r1);
                Check("Duo 比例（屏高 1318）：720 放高 878、上屏竖裁不越出贴图、剪刀整数换算", "878 0 878 0 878 121 247", $"{dh1} {t0} {b0} {q0} {r0} {q1} {r1}");
            }
            // 竖向外推层（11-02 维护者 Duo 外屏丝之歌：开局压暗遮罩只盖原 16:9、上下各一条亮带；11-05 改竖向外推，原整笔拉满把文字 / 页签底板一起拉走）。
            //   和横向推满同一份「无细节铺满层」判定 → 画法照旧 Hor（视口 720·Ky、投影 y 乘 1/Ky，几何原尺寸），出竖向外推参数：push = (0, 门限², 0, 外推量)。
            //   手算（屏 1920×1318）：加高 2·round(540·(16/9 ÷ 1920/1318 − 1)) = 238，Ky = 1318/1080；外推量 1 − 1/Ky = 238/1318 = 0.180577；门限² = (0.997·1080/1318)² = 0.667432
            {
                var d = new WidenSession(1920, 1318, false, true, false);
                d.Texture(40, 1280, 720, 1, WidenSession.UseRt);
                float[] push = new float[4];
                int[] shP = { d.Shader("0:0,1,2,3", true), 0, 0, 0, 0, 0 };
                nint pp = Pinned(64, out byte[] gp, out int gpt); B(Proj()).CopyTo(gp, gpt);
                WidenSession.Tex T(uint id, int w, int h) => new WidenSession.Tex { Id = id, W = w, H = h, Scale = 1 };
                string D(WidenSession.Tex[] tex, float w = 1280, float h = 720, uint fl = WidenSession.DrawColor)
                {
                    d.Targets(40, 0); d.CbufBind(0, 0, pp, 64);
                    ViewportMode m = d.Draw(0, w, h, 1, shP, fl, tex, push, out _);
                    float y = 0, vh = h; d.Frame.MapViewportY(m, ref y, ref vh);
                    return $"{m} {Math.Round(y) + 0} {Math.Round(vh)} [{push[0]:F6} {push[1]:F6} {push[2]:F6} {push[3]:F6}]";
                }
                long f0 = d.DrawsTallPushed;
                Check("竖向：无深度目标、读改写投影、只采 24×24 的铺满层 → 照旧 Hor、出竖向外推 (0, 门限², 0, 外推量)", "Hor 0 879 [0.000000 0.667432 0.000000 0.180577]", D(new[] { T(41, 24, 24) }));
                Check("竖向：同一层采 1024×1024 不透明整图（有细节）→ Hor、不外推", "Hor 0 879 [0.000000 0.000000 0.000000 0.000000]", D(new[] { T(42, 1024, 1024) }, fl: WidenSession.DrawColor | WidenSession.DrawOpaque));
                Check("竖向：同一层写深度 → 不外推", "Hor 0 879 [0.000000 0.000000 0.000000 0.000000]", D(new[] { T(41, 24, 24) }, fl: WidenSession.DrawColor | WidenSession.DrawDepthWrite));
                Check("竖向：同一层一笔多四边形（文字 / 一批贴片）→ 不外推", "Hor 0 879 [0.000000 0.000000 0.000000 0.000000]", D(new[] { T(41, 24, 24) }, fl: WidenSession.DrawColor | WidenSession.DrawPatches));
                Check("竖向：同一层子视口 640×360 → 不外推", "0.000000", D(new[] { T(41, 24, 24) }, 640, 360).Split('[')[1].Split(' ')[3].TrimEnd(']'));
                Check("计数：竖向外推层 1", "1", $"{d.DrawsTallPushed - f0}");
            }
            // 11-05 原生高：第一层给高屏报加长分辨率（掌机 1280×900），游戏照着建的 1280×900 是它自己画的高图——宽高比 1280/900 = 1.4222 = 屏比 1920/1350，
            //   认作原生（不再二次加高到 1125、Hor 视口不动）；16:9 的 1280×720 照旧加高到 900。屏比外的 1280×1000 两样都不是
            {
                var t = new WidenSession(1920, 1350, false, true, false);
                int rn = t.Texture(70, 1280, 900, 1, WidenSession.UseRt), r16 = t.Texture(71, 1280, 720, 1, WidenSession.UseRt), rx = t.Texture(72, 1280, 1000, 1, WidenSession.UseRt);
                t.Frame.OnRenderTargets(70, 0);
                float ny = 0, nh = 900; t.Frame.MapViewportY(ViewportMode.Hor, ref ny, ref nh);
                Check("原生高：1280×900 认原生、不加高、Hor 视口原样；1280×720 照旧加高 900；1280×1000 两样都不是",
                    "1280 True False 0 900 | True 900 | False False",
                    $"{rn} {t.Frame.IsNative(70)} {t.Frame.TryTall(70, out _, out _)} {ny} {nh} | {t.Frame.TryTall(71, out _, out int h71)} {h71} | {t.Frame.IsNative(72)} {t.Frame.TryTall(72, out _, out _)}");
            }
            var w = new WidenSession(2346, 1080, false, true, false);
            w.Texture(10, 1920, 1080, 1, WidenSession.UseRt); w.Frame.OnRenderTargets(10, 0);
            float wy = 7, wh = 1080; w.Frame.MapViewportY(ViewportMode.ScaleK, ref wy, ref wh);
            Check("宽屏不受纵向改动影响：不登记加高、视口 y 原样", "False 7 1080", $"{w.Frame.TryTall(10, out _, out _)} {wy} {wh}");
        }

        // 奇数加高量（10-28 审计 P3 / B06）：加高量本身恒偶（WidenRewriter 的 2·round），但 mip 视图按级缩会截出奇数差——
        //   1080 → 1350 的一级视图是 540 → 675，差 135。手算 pad = 135 / 2 = 67（向下取整）。
        //   页内容 [67, 607)、上条带 [0, 67)、下条带 [607, 675)：三处逐行相接，无空档无重叠。
        //   改前：视口 y 用浮点 pad = 67.5、剪刀页各行用 67 → 第 67 行上半被清黑留在画面、下半被内容覆盖（半行对不齐）；
        //   界面层贴底用 2·pad = 134 → 底部留 1 行未清。
        {
            var t = new WidenSession(1920, 1350, false, true, false);
            t.Texture(10, 1920, 1080, 1, WidenSession.UseRt);   // 1080 → 1350
            t.View(11, 10, 1, 960);                             // 一级视图 540 → 675
            t.Frame.TryTall(11, out int th0, out int th1);
            Check("奇数加高：一级视图 1080 → 540、1350 → 675（差 135 奇数）", "540 675", $"{th0} {th1}");
            float[] push = new float[4]; int[] sh = new int[6];
            var pic = new[] { new WidenSession.Tex { Id = 12, W = 1920, H = 1080, Scale = 1 } };
            t.Targets(11, 0);
            ViewportMode m = t.Draw(0, 1920, 1080, 1, sh, WidenSession.DrawColor, pic, push, out _);
            bool rows = t.PageRows(out int r0, out int rc0, out int rc1, out int r1);
            Check("奇数加高起页：上下条带按整数 pad 交出", "Page True [0,67) [607,675)", $"{m} {rows} [{r0},{rc0}) [{rc1},{r1})");
            Check("奇数加高：上条带止 = 内容起 67、内容止 = 下条带起 607、底 675", "67 607 675", $"{rc0} {rc1} {r1}");
            float yp = 0, hp = 540; t.Frame.MapViewportY(ViewportMode.Page, ref yp, ref hp);
            int sp = 0, shp = 540; t.Frame.MapScissorY(ViewportMode.Page, ref sp, ref shp);
            Check("奇数加高：视口 y 与剪刀 y 同为整数 pad 67（改前视口 67.5）", "67 67", $"{yp} {sp}");
            float yc = 0, hc = 540; t.Frame.MapViewportY(ViewportMode.CenterNative, ref yc, ref hc);
            int sc = 0, shc = 540; t.Frame.MapScissorY(ViewportMode.CenterNative, ref sc, ref shc);
            Check("奇数加高：界面层居中用整数 pad 67，视口与剪刀同口径（11-02 起；原贴底 135）", "67 67", $"{yc} {sc}");
        }

        // 读法文本：绑定 3 读 vec4 0、2，绑定 5 动态；映射 3→槽 1、5→槽 4、其余不映射
        {
            var u3 = new CbufUse { Binding = 3 }; u3.Add(2); u3.Add(0);
            var u5 = new CbufUse { Binding = 5, Dynamic = true };
            var u9 = new CbufUse { Binding = 9 }; u9.Add(1);
            int[] map = { -1, -1, -1, 1, -1, 4 };
            Check("读法文本：按槽号升序、映射不到的跳过", "1:0,2;4:*", SpirvCbufUseText.Format(new[] { u9, u5, u3 }, map));
            var p = SpirvCbufUseText.Parse("0:0,1;2:*;bad;30:1", 18);
            Check("读法文本解析：槽 0 读 0、1，槽 1 不读，槽 2 动态，越界项跳过", "True True False True", $"{p[0].Contains(0) && p[0].Contains(1) && !p[0].Contains(2)} {p[1] == null} {p[0].Dynamic} {p[2].Dynamic}");
        }

        // 动森形状（只管界面层）：界面投影（16:9 透视，手算 P00/K）在游戏内存里；画到 600×300 离屏界面贴图要原值，画到 1568×720 原生宽目标要改写值
        {
            var s = new WidenSession(2346, 1080, true, false, false);
            Check("直连：只管界面层模式下渲染目标不放宽", "1920 1568 600", $"{s.Texture(1, 1920, 1080, 1, WidenSession.UseRt)} {s.Texture(2, 1568, 720, 1, WidenSession.UseRt)} {s.Texture(3, 600, 300, 1, WidenSession.UseRt)}");
            nint ptr = Pinned(768, out byte[] ga, out int gat);
            B(Proj()).CopyTo(ga, gat);
            int h = s.Shader("0:0,1,2,3", false);
            int[] sh = { h, 0, 0, 0, 0, 0 };
            byte[] scratch = new byte[768];
            Span<float> push = stackalloc float[4];
            s.Frame.OnRenderTargets(3, 0);
            s.CbufBind(0, 0, ptr, 768);
            var m3 = s.Draw(0, 600, 300, 1, sh, WidenSession.DrawColor, default, push, out _);
            Check("直连：没放宽的离屏界面贴图 → 原样、常量零拷贝（原值）", "Keep 0", $"{m3} {s.CbufEmit(0, 0, scratch)}");
            // 界面层 / 读改写投影的层都采图集（大贴图）；不采贴图 / 只采小图的层在直连里按原样铺满（见下「纯色全画布层」）
            var atlas = new[] { new WidenSession.Tex { Id = 7, W = 1024, H = 1024, Scale = 1 } };
            s.Frame.OnRenderTargets(2, 0);
            s.CbufBind(0, 0, ptr, 768);
            var m2 = s.Draw(0, 1568, 720, 1, sh, WidenSession.DrawColor, atlas, push, out _);
            int n2 = s.CbufEmit(0, 0, scratch);
            Check("直连：原生宽目标、读到改写投影 → Hor，出数 1 处、[0] = P00/K（1.3579951 / 1.221875）", $"Hor 1 {P00 / K:F6}", $"{m2} {n2} {Fl(scratch)[0]:F6}");
            Check("直连：游戏内存没被写", P00, Fl(ga[gat..])[0]);
            s.Frame.OnRenderTargets(3, 0); s.CbufBind(0, 0, ptr, 768);
            s.Draw(0, 600, 300, 1, sh, WidenSession.DrawColor, default, push, out _);
            Check("直连：再画回离屏界面贴图 → 又是原值（零拷贝）", 0, s.CbufEmit(0, 0, scratch));
            s.Frame.OnRenderTargets(2, 0); s.CbufBind(0, 0, ptr, 768); s.Draw(0, 1568, 720, 1, sh, WidenSession.DrawColor, atlas, push, out _);
            int nShort = s.CbufEmit(0, 0, new byte[64]);
            Check("直连：暂存区不够 → 返回 0、记红", "0 1", $"{nShort} {s.ScratchShort}");
            // 规则 A（同上面 GameWide 规则 A 用例，经直连入口）：上屏 1 前最后一笔采样 2 → T_out = 2；第二次画 2、没读改写矩阵 → 原宽居中 x 142.5、宽 1283
            int ho = s.Shader("1:20", false);
            int[] so = { ho, 0, 0, 0, 0, 0 };
            s.Frame.OnRenderTargets(1, 0); s.CbufBind(0, 1, ptr, 768);
            var t2 = new[] { new WidenSession.Tex { Id = 2, W = 1568, H = 720, Scale = 1 } };
            s.Draw(0, 1564, 720, 1, so, WidenSession.DrawColor, t2, push, out _);
            int l = 0, r = 0; float ax = 0; s.Present(1, ref l, ref r, ref ax, 0);
            Check("直连规则 A：T_out = 上屏前最后一笔采样的原生宽目标 2", 2u, s.Frame.OutTexture);
            s.Frame.OnRenderTargets(2, 0);
            s.Draw(0, 1568, 720, 1, so, WidenSession.DrawColor, atlas, push, out _);
            var mh = s.Draw(0, 1568, 720, 1, so, WidenSession.DrawColor, atlas, push, out _);
            float x = 0, w = 1568; s.Frame.MapViewport(mh, ref x, ref w);
            Check("直连规则 A：界面层没读改写矩阵 → 原宽居中（x 142.5、宽 1283）", "CenterNative 142.5 1283", $"{mh} {Math.Round(x, 2)} {Math.Round(w, 2)}");
            // 宽排版界面正交（10-26 暗黑2 直连菜单）：游戏按第一层报的宽分辨率自己排界面，正交画布 1568×720（宽高比 = 放宽后的屏宽比 16:9 × K）→ 原样画（视口不动）、
            //   不收回中间；同一处换成 1280×720 的 16:9 正交 → 照旧原宽居中。两块各用一段新游戏内存（常量影子按内存登记命中）
            {
                int hw = s.Shader("1:20,21,22,23", false); int[] sw = { hw, 0, 0, 0, 0, 0 };
                float[] OrthoAt(float wpx) => new float[] { 2f / wpx, 0, 0, -1, 0, -2f / 720, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1 };
                nint pw = Pinned(768, out byte[] gw, out int gwt); B(OrthoAt(1568)).CopyTo(gw, gwt + 320);
                long uw0 = s.Frame.DrawsUiWide;
                s.Frame.OnRenderTargets(2, 0); s.CbufBind(0, 1, pw, 768);
                var mw = s.Draw(0, 1568, 720, 1, sw, WidenSession.DrawColor, atlas, push, out _);
                float wx = 0, ww = 1568; s.Frame.MapViewport(mw, ref wx, ref ww);
                Check("宽排版界面正交（1568×720）→ 原样：画法 ScaleK、视口 0 / 1568、宽排版计数 +1", "ScaleK 0 1568 1", $"{mw} {wx} {ww} {s.Frame.DrawsUiWide - uw0}");
                nint pn = Pinned(768, out byte[] gn, out int gnt); B(OrthoAt(1280)).CopyTo(gn, gnt + 320);
                s.CbufBind(0, 1, pn, 768);
                var mn = s.Draw(0, 1568, 720, 1, sw, WidenSession.DrawColor, atlas, push, out _);
                float nx = 0, nw = 1568; s.Frame.MapViewport(mn, ref nx, ref nw);
                Check("16:9 界面正交（1280×720）→ 照旧原宽居中（x 142.5、宽 1283）", "CenterNative 142.5 1283", $"{mn} {Math.Round(nx, 2)} {Math.Round(nw, 2)}");
                Check("宽排版界面正交只登记不改：游戏内存与影子出数都是原值", true, B(OrthoAt(1568)).AsSpan().SequenceEqual(gw.AsSpan(gwt + 320, 64)));
            }
            // 纯色全画布层（10-24 动森加载页黑遮罩）：顶点不能外推（直连 v1 着色器没改过）、片元不采贴图 → 不收进中间，按原样铺满（视口不动、出数 0 = 原值）
            var mf = s.Draw(0, 1568, 720, 1, so, WidenSession.DrawColor, default, push, out _);
            float fx = 0, fw = 1568; s.Frame.MapViewport(mf, ref fx, ref fw);
            Check("直连纯色全画布层（不能外推）→ 原样铺满：画法 Keep、视口 0 / 1568、出数 0", "Keep 0 1568 0", $"{mf} {fx} {fw} {s.CbufEmit(0, 1, scratch)}");
            // 收缩外推：顶点能外推、片元只采 8×8 小图 → 改成 Hor + 参数（手算：e = (1 − 0.003)/K、门限² = e²、外推量 = 1 − 1/K，收缩量同外推量）
            int hp = s.Shader("1:20", true);
            var small = new[] { new WidenSession.Tex { Id = 9, W = 8, H = 8, Scale = 1 } };
            var mp = s.Draw(0, 1568, 720, 1, new[] { hp, 0, 0, 0, 0, 0 }, WidenSession.DrawColor, small, push, out _);
            float e = 0.997f / K;
            Check("直连收缩外推：原宽居中层 → Hor + (外推量, 门限², 收缩量)", $"Hor {1 - 1 / K:F5} {e * e:F5} {1 - 1 / K:F5}", $"{mp} {push[0]:F5} {push[1]:F5} {push[2]:F5}");
            // 稳态零分配（JIT 下量；NativeAOT 下另量，见 tests/visual/widen_capi）
            long a = 0;
            for (int i = 0; i < 4000; i++)
            {
                if (i == 2000) a = GC.GetAllocatedBytesForCurrentThread();   // 前 2000 笔预热（各表第一次见到的键）
                s.Frame.OnRenderTargets((uint)(2 + (i & 1)), 0); s.CbufBind(0, 0, ptr, 768); s.CbufBind(0, 1, ptr, 768);
                s.Draw(0, (i & 1) == 0 ? 1568 : 600, (i & 1) == 0 ? 720 : 300, 1, sh, WidenSession.DrawColor, t2, push, out _);
                s.CbufEmit(0, 0, scratch); s.CbufEmit(0, 1, scratch);
                if (i % 50 == 49) s.Present(1, ref l, ref r, ref ax, 0);
            }
            long da = GC.GetAllocatedBytesForCurrentThread() - a;   // 先取数：Check 的期望参数装箱也算分配
            Check("直连：稳态 2000 笔绘制托管分配字节（JIT）", 0L, da);
        }

        // 两种模式等效（差分）：同一串上传 / 绘制，直连每笔出数 = 通用模式此刻 GPU 缓冲里的内容（GpuSim 收上传与写回）。整套放宽，放宽目标 1、没放宽目标 2
        {
            var g = new WidenFrame(new WidenRewriter(A0)); var sim = new GpuSim();
            var s = new WidenSession(2346, 1080, false, true, false);
            foreach (var f in new[] { g }) { f.OnCreateTexture(1, 1280, 720); f.OnCreateTexture(2, 600, 300); }
            s.Texture(1, 1280, 720, 1, WidenSession.UseRt); s.Texture(2, 600, 300, 1, WidenSession.UseRt);
            nint ptr = Pinned(256, out byte[] garr, out int gat2);
            var guest = new ArraySegment<byte>(garr, gat2, 256);
            var useAll = new CbufUse { Binding = 0 }; for (int i = 0; i < 16; i++) useAll.Add(i);
            var usePart = new CbufUse { Binding = 0 }; usePart.Add(1);   // 只读投影的第 2 个 vec4（一截）
            int hAll = s.Shader("0:" + string.Join(",", System.Linq.Enumerable.Range(0, 16)), false), hPart = s.Shader("0:1", false);
            byte[] scratch = new byte[256]; Span<float> push = stackalloc float[4];
            int same = 0, steps = 0; string first = null;
            var rnd = new Random(1024);
            for (int step = 0; step < 400; step++)
            {
                if (step % 7 == 0)   // 游戏改写常量：投影的视角 / 位置在两份数据间换，偶尔换成不认的数据
                {
                    float[] p = Proj(); if (rnd.Next(3) == 0) p[0] *= 1.5f;
                    float[] all = new float[64]; p.CopyTo(all, 4 * rnd.Next(3)); all[60] = step;
                    B(all).CopyTo(garr, gat2);
                    sim.Up(g, 7, 0, B(all));
                }
                uint rt = (uint)(1 + rnd.Next(2)); bool part = rnd.Next(4) == 0;
                CbufRead[] rd = { new(7, 0, 256, part ? usePart : useAll) };
                g.OnRenderTargets(rt, 0); g.OnDraw(rd, sim, out _);
                s.Frame.OnRenderTargets(rt, 0); s.CbufBind(0, 0, ptr, 256);
                s.Draw(0, 1280, 720, 1, new[] { part ? hPart : hAll, 0, 0, 0, 0, 0 }, WidenSession.DrawColor, default, push, out _);
                ReadOnlySpan<byte> seen = s.CbufEmit(0, 0, scratch) > 0 ? scratch : guest.AsSpan();
                steps++;
                if (seen[..256].SequenceEqual(sim.Buf(7).AsSpan(0, 256))) same++; else first ??= $"第 {step} 步（目标 {rt}{(part ? "、只读一截" : "")}）";
            }
            Check("两种模式等效：400 笔绘制直连出数 = 通用模式 GPU 缓冲内容", $"{steps}/{steps}", $"{same}/{steps}{(first != null ? "，首个不同 " + first : "")}");
            Check("差分有效：改写真发生过（直连有出数的笔数 > 0）", true, s.Frame.Rewriter.Stats.Projection > 0 && s.Frame.Restores > 0);
        }

        // 关闭（16:9 屏）：全部原样
        {
            var s = new WidenSession(1920, 1080, true, true, true);
            nint p1 = Pinned(64, out byte[] g1, out int g1at); B(Proj()).CopyTo(g1, g1at);
            s.CbufBind(0, 0, p1, 64);
            Check("关闭：贴图不放宽、常量零拷贝", "1920 0", $"{s.Texture(1, 1920, 1080, 1, 1)} {s.CbufEmit(0, 0, new byte[64])}");
        }

        // 左上画布（10-31 丝之歌暂停页，帧回放定因）：掌机档在 1920×1080 窗口贴图里只画左上 1280×720。放宽 1920 → 2346 的目标上，
        //   原宽居中 / Hor 的 pad 要按画布 (1564 − 1280)/2 = 142 算，不是整张贴图 (2346 − 1920)/2 = 213；铺满整张的视口清掉画布
        {
            var s = new WidenSession(2346, 1080, false, true, false);
            s.Texture(1, 1920, 1080, 1, WidenSession.UseRt);
            float[] push = new float[4]; int[] sh = new int[6];
            s.Targets(1, 0);
            s.Draw(0, 1280, 720, 1, sh, WidenSession.DrawColor, Array.Empty<WidenSession.Tex>(), push, out _);
            float cx = 0, cw = 1280; s.Frame.MapViewport(ViewportMode.CenterNative, ref cx, ref cw);
            float hx = 0, hw = 1280; s.Frame.MapViewport(ViewportMode.Hor, ref hx, ref hw);
            Check("左上画布 1280×720：原宽居中 x 142、Hor 铺满 [0, 1564)", "142 1280 0 1564", $"{cx} {cw} {Math.Round(hx)} {Math.Round(hw)}");
            s.Draw(0, 640, 360, 1, sh, WidenSession.DrawColor, Array.Empty<WidenSession.Tex>(), push, out _);
            float sx = 0, sw = 1280; s.Frame.MapViewport(ViewportMode.CenterNative, ref sx, ref sw);
            Check("之后的子视口（640×360，< 60%）不改画布：原宽居中仍 x 142", "142", $"{sx}");
            s.Draw(0, 1920, 1080, 1, sh, WidenSession.DrawColor, Array.Empty<WidenSession.Tex>(), push, out _);
            float fx = 0, fw = 1920; s.Frame.MapViewport(ViewportMode.CenterNative, ref fx, ref fw);
            Check("铺满整张的视口清掉画布：原宽居中回到 x 213", "213", $"{fx}");
        }

        // 直连 16:9 原比例页（10-25：直连三个前端的全屏 2D 背景 / 标题图原先按 k 横向拉宽；同包装层 TryBeginPage）。整套放宽，1280×720 放宽到 round(1280·k) = 1564，
        // 页面平移 (1564 − 1280)/2 = 142：内容区 [142, 1422)、两侧条带 [0, 142) [1422, 1564)。贴图号 0 = GL / Vulkan 胶水报的没放宽贴图
        {
            var s = new WidenSession(2346, 1080, false, true, false);
            foreach (uint id in new uint[] { 1, 3, 4, 5, 6, 7 }) s.Texture(id, 1280, 720, 1, WidenSession.UseRt);
            s.Texture(8, 128, 72, 1, WidenSession.UseRt);
            float[] push = new float[4]; int[] sh = new int[6];
            var pic = new[] { new WidenSession.Tex { Id = 0, W = 1280, H = 720, Scale = 1 } };
            string D(uint rt, WidenSession.Tex[] tex, float w = 1280, float h = 720)
            {
                s.Targets(rt, 0);
                ViewportMode m = s.Draw(0, w, h, 1, sh, WidenSession.DrawColor, tex, push, out _);
                return s.PageSides(out int m0, out int c0, out int c1, out int m1) ? $"{m} [{m0},{c0}) [{c1},{m1})" : $"{m}";
            }
            Check("页：放宽目标上采样整画布 16:9 图片 → 起页、交出两侧条带", "Page [0,142) [1422,1564)", D(1, pic));
            Check("页：同帧同目标之后的绘制（不采样）仍按页画、不再交条带", "Page", D(1, Array.Empty<WidenSession.Tex>()));
            float x = 0, w = 1280; s.Frame.MapViewport(ViewportMode.Page, ref x, ref w);
            Check("页：视口原宽平移 142", "142 1280", $"{x} {w}");
            // 页生效期间同一目标上采样放宽贴图的绘制（10-26 马车8 直连主菜单：磨砂底板采样放宽的模糊图）→ 照旧按页画，回放层把采样换到放宽贴图中间 16:9 区（uvx_fill）
            var w3 = new[] { new WidenSession.Tex { Id = 3, W = 1280, H = 720, Scale = 1 } };
            Check("页生效时采样放宽贴图 → 照旧按页画（采样由回放层换到中间 16:9 区）", "Page", D(1, w3));
            Check("页仍生效：之后不采样的绘制照旧按页画", "Page", D(1, Array.Empty<WidenSession.Tex>()));
            var p1 = new[] { new WidenSession.Tex { Id = 1, W = 1280, H = 720, Scale = 1 } };
            // 直连不沿采样链传页（包装层按贴图放宽比改采样坐标，直连改不了）：全屏采样页目标按 k 铺满 = 一比一拷，居中内容 + 黑边原样带过去；再起页会把内容再平移 142
            Check("直连：只采样页目标（放宽贴图）→ 不起页、按 k 一比一拷", "ScaleK", D(3, p1));
            Check("同时采样放宽贴图与 16:9 图片 → 不是页（按 k 铺满）", "ScaleK", D(4, new[] { p1[0], pic[0] }));
            Check("方形贴图 1024×1024 不是整画布图片 → 按 k", "ScaleK", D(6, new[] { new WidenSession.Tex { Id = 0, W = 1024, H = 1024, Scale = 1 } }));
            Check("横向平铺的 16:9 贴图不是页 → 按 k", "ScaleK", D(7, new[] { new WidenSession.Tex { Id = 0, W = 1280, H = 720, Scale = 1, Flags = WidenSession.TexTileU } }));
            Check("画布高 72 < 360 的小缓冲不新起页 → 按 k", "ScaleK", D(8, new[] { new WidenSession.Tex { Id = 0, W = 128, H = 72, Scale = 1 } }, 128, 72));
            int l = 0, r = 1280; float ax = 16;
            s.Present(4, ref l, ref r, ref ax, 9);
            Check("下一帧：目标 1 不采样图片 → 不再是页", "ScaleK", D(1, Array.Empty<WidenSession.Tex>()));
            // 当过渲染目标、没放宽的 16:9 贴图（GPU 画出来的，10-25 马车8 标题页合成笔）不是图片来源 → 不起页：登记成渲染目标再从放宽表摘掉 = 「登记过、没放宽」
            s.Texture(12, 1280, 720, 1, WidenSession.UseRt); s.Frame.OnReleaseTexture(12);
            var gpu = new[] { new WidenSession.Tex { Id = 12, W = 1280, H = 720, Scale = 1 } };
            Check("当过渲染目标、没放宽的 16:9 贴图 → 不起页（按 k）", "ScaleK", D(5, gpu));
            s.Texture(13, 1280, 720, 1, 0);   // 同尺寸 CPU 供图（存储在游戏内存池、没登记成目标）
            Check("同尺寸 CPU 供图 → 起页", "Page [0,142) [1422,1564)", D(5, new[] { new WidenSession.Tex { Id = 13, W = 1280, H = 720, Scale = 1 } }));
            Check("起页计数", 2L, s.PageDraws);
            // GPU 写出的 16:9 图（计算派发写的图像 / 拷贝目标，存储放不宽、没登记成渲染目标；10-26 八方2 场景图 896×504 被认成 CPU 供图起了页）→ GpuWrote 后不当图片来源
            s.Present(4, ref l, ref r, ref ax, 9);
            Check("计算写的 16:9 图记 GPU 写过 → 返回 1", 1, s.GpuWrote(14, 0));
            Check("GPU 写过的 16:9 图 → 不起页（按 k）", "ScaleK", D(7, new[] { new WidenSession.Tex { Id = 14, W = 1280, H = 720, Scale = 1 } }));
            Check("CPU 供图拷出来的（src 13 不是 GPU 写的）→ 不记、返回 0", 0, s.GpuWrote(15, 13));
            Check("CPU 供图的拷贝仍是图片 → 起页", "Page [0,142) [1422,1564)", D(7, new[] { new WidenSession.Tex { Id = 15, W = 1280, H = 720, Scale = 1 } }));
            Check("GPU 写的图拷出来的（src 14）→ 记、返回 1", 1, s.GpuWrote(16, 14));
            Check("起页计数（再多 1 页：CPU 供图的拷贝）", 3L, s.PageDraws);
        }

        // 10-29 铺满画布的界面层两侧要有确定内容（喷3 房间列表暗化层、马车8 选轮胎页两侧留旧帧）。整套放宽 K = 1.221875：1280×720 → 1564，居中偏移 (1564 − 1280)/2 = 142。
        //   外推参数手算同上「直连收缩外推」：外推量 1 − 1/K、门限² ((1 − 0.003)/K)²；收缩量：原尺寸居中层 1 − 1/K、Hor 层 NoBandZ（不收缩）；不推全 0
        {
            var s = new WidenSession(2346, 1080, false, true, false);
            foreach (uint id in new uint[] { 1, 2, 3, 4, 5, 6 }) s.Texture(id, 1280, 720, 1, WidenSession.UseRt);
            float e = 0.997f / K; string shrunk = $"Hor {1 - 1 / K:F5} {e * e:F5} {1 - 1 / K:F5}";
            float[] push = new float[4];
            int hp = s.Shader("0:0,1,2,3", true), hn = s.Shader("0:0,1,2,3", false);
            int[] shP = { hp, 0, 0, 0, 0, 0 }, shN = { hn, 0, 0, 0, 0, 0 };
            WidenSession.Tex T(uint id, int w, int h, uint f = 0) => new WidenSession.Tex { Id = id, W = w, H = h, Scale = 1, Flags = f };
            string D(int[] sh, WidenSession.Tex[] tex, float w = 1280, float h = 720, uint fl = WidenSession.DrawColor)
            {
                ViewportMode m = s.Draw(0, w, h, 1, sh, fl, tex, push, out _);
                return $"{m} {push[0]:F5} {push[1]:F5} {push[2]:F5}";
            }
            // 原尺寸居中层：规则 A（上屏 1 前最后一笔采样放宽的 2 → 出图目标 2；目标 2 第一笔是全屏合成，之后没读改写矩阵的笔 = 原尺寸居中）
            s.Targets(1, 0); s.Draw(0, 1280, 720, 1, shP, WidenSession.DrawColor, new[] { T(2, 1280, 720) }, push, out _);
            int l = 0, r = 1280; float ax = 16; s.Present(1, ref l, ref r, ref ax, 9);
            s.Targets(2, 0); s.Draw(0, 1280, 720, 1, shP, WidenSession.DrawColor, new[] { T(2, 1280, 720) }, push, out _);
            // 11-06 八方2 小地图：叠加层（本帧已合成的出图目标上）的非平铺贴图不再按尺寸猜无细节——Unreal / Slate 界面每个小部件都按整画布视口画，贴图 1:1 画在一小块里；只认按内容量的结论
            Check("喷3 型：铺满画布的叠加层只采 128×72、还没量过内容 → 照旧原尺寸居中、不推（先点名量）", "CenterNative 0.00000 0.00000 0.00000 20", D(shP, new[] { T(20, 128, 72) }) + $" {s.WantFlat}");
            Check("喷3 型：同一层量过内容横向无细节、每行横向不变 → 收缩外推推满宽屏", shrunk, D(shP, new[] { T(20, 128, 72, WidenSession.TexFlatKnown | WidenSession.TexFlatContent | WidenSession.TexRowConst) }));
            // 11-06 八方2 iPhone 实局：底盘圆盘量得「平滑」（曲率处处小）但行内变化大（没有 TexRowConst）→ 不收缩
            Check("八方2 底盘型（真机量值）：量过平滑、行内有变化 → 原尺寸居中、不收缩不推", "CenterNative 0.00000 0.00000 0.00000", D(shP, new[] { T(24, 256, 256, WidenSession.TexFlatKnown | WidenSession.TexFlatContent) }));
            // 11-06 B 几何判据：收缩只给两侧贴画布边的整画布层（宿主按位置切片在 CPU 求 NDC x，WidenCApi.Geom）
            uint FC = WidenSession.TexFlatKnown | WidenSession.TexFlatContent | WidenSession.TexRowConst;
            s.GeomCovers = () => 1; Check("几何铺满（NDC 两侧到 ±1）+ 内容行内不变 → 收缩外推", shrunk, D(shP, new[] { T(25, 128, 72, FC) }));
            s.GeomCovers = () => 0; Check("几何只盖一部分（八方2 小地图程序画的细环：贴图均匀、部件不铺满画布）→ 不收缩", "CenterNative 0.00000 0.00000 0.00000", D(shP, new[] { T(25, 128, 72, FC) }));
            s.GeomCovers = () => -1; Check("几何判不出 → 不收缩（保守）", "CenterNative 0.00000 0.00000 0.00000", D(shP, new[] { T(25, 128, 72, FC) }));
            s.GeomCovers = () => -2; Check("没有位置切片（11-06 前的库）→ 照旧收缩", shrunk, D(shP, new[] { T(25, 128, 72, FC) }));
            s.GeomCovers = null;
            Check("八方2 小地图底盘型：叠加层整画布视口、采 256×256 圆盘、量过有细节 → 原尺寸居中、不收缩不推", "CenterNative 0.00000 0.00000 0.00000", D(shP, new[] { T(23, 256, 256, WidenSession.TexFlatKnown) }));
            Check("同一层子视口 640×360（不铺满画布）→ 照旧原尺寸居中、不推", "CenterNative 0.00000 0.00000 0.00000", D(shP, new[] { T(20, 128, 72) }, 640, 360));
            Check("铺满画布但采 512×256（放大 2.5 倍，有细节）→ 照旧原尺寸居中", "CenterNative 0.00000 0.00000 0.00000", D(shP, new[] { T(21, 512, 256) }));
            Check("纯色 ≤8×8 型（能外推）→ 收缩外推（原有规则）", shrunk, D(shP, new[] { T(22, 8, 8) }));
            string mo = D(shN, new[] { T(22, 8, 8) });
            Check("纯色 ≤8×8 型（不能外推）→ 放宽目标上按 k 铺满（ScaleK、出数 0），不是只铺客体宽的 Keep", "ScaleK 0.00000 0.00000 0.00000 True", $"{mo} {s.EmitsNone}");
            // 马车8 蓝底型（10-29 Mac 局常量转储：界面是透视投影 P00 1.358 / P11 2.4142 下的平面，蓝底 1280×720 像素 = 画布大小，采 8×1048 夹边渐变）：
            //   放宽目标、没有深度目标、读改写过的投影（几何原尺寸、只占中间）、只采横向无细节贴图 → 画布边推到屏幕边（外推量 1 − 1/K、门限²、收缩量 NoBandZ）
            string horPush = $"Hor {1 - 1 / K:F5} {e * e:F5} {WidenFrame.NoBandZ:F5}";
            nint pp = Pinned(64, out byte[] gp, out int gpt); B(Proj()).CopyTo(gp, gpt);
            s.Texture(9, 1280, 720, 1, WidenSession.UseRt); s.Texture(10, 1280, 720, 1, WidenSession.UseRt);
            s.Targets(9, 0); s.CbufBind(0, 0, pp, 64);
            Check("马车8 蓝底型：无深度目标、读改写投影、只采 8×1048 夹边渐变 → Hor 且画布边推到屏幕边", horPush, D(shP, new[] { T(30, 8, 1048) }));
            Check("同一层采横向平铺的 128×128（斜铺的标志面）→ Hor、不推", "Hor 0.00000 0.00000 0.00000", D(shP, new[] { T(32, 128, 128, WidenSession.TexTileU) }));
            Check("同一层采 1024×1024（有细节）→ Hor、不推", "Hor 0.00000 0.00000 0.00000", D(shP, new[] { T(31, 1024, 1024) }));
            Check("同一层顶点不能外推 → Hor、不推（不按 k 拉伸）", "Hor 0.00000 0.00000 0.00000", D(shN, new[] { T(30, 8, 1048) }));
            Check("同一层子视口 640×360 → Hor、不推", "Hor 0.00000 0.00000 0.00000", D(shP, new[] { T(30, 8, 1048) }, 640, 360));
            s.Targets(10, 11); s.CbufBind(0, 0, pp, 64);
            Check("带深度目标的 3D 场景（画布外是新视野）只采 8×1048 → Hor、不推", "Hor 0.00000 0.00000 0.00000", D(shP, new[] { T(30, 8, 1048) }));
            // 丝之歌暂停页型（10-31）：出图目标 2 本帧已全屏合成过（规则 A：之后的笔是界面层），界面遍挂着深度，压暗遮罩读改写投影、只采 24×24 → 照推
            s.Targets(2, 11); s.CbufBind(0, 0, pp, 64);
            Check("丝之歌暂停页型：出图目标全屏合成之后的界面层挂着深度、读改写投影、只采 24×24 → Hor 且画布边推到屏幕边", horPush, D(shP, new[] { T(34, 24, 24) }));
            // 族 2（11-01）：叠加在已合成画面上的半透明层带纹理也推（泡泡龙 4 房间光束、马力欧惊奇选用户页浅蓝底）；不透明的整幅图片照旧不推（推了被拉伸）
            Check("同一界面层半透明、采 1024×1024 还没量过 → Hor、不推（先点名量边缘）", "Hor 0.00000 0.00000 0.00000", D(shP, new[] { T(31, 1024, 1024) }));
            uint EK = WidenSession.TexFlatKnown;
            Check("族 2：半透明叠加、量过有细节但左右边缘带平滑（光束 / 模糊 / 渐晕）→ Hor 且推", horPush, D(shP, new[] { T(36, 1024, 1024, EK | WidenSession.TexEdgeSmooth) }));
            Check("族 2：半透明叠加、量过边缘也有细节（马力欧惊奇标题主视觉）→ Hor、不推（外扩会绕回 / 拉丝）", "Hor 0.00000 0.00000 0.00000", D(shP, new[] { T(37, 1024, 1024, EK) }));
            Check("族 2：半透明叠加、横向重复寻址且首尾无缝（平铺设计）→ Hor 且推", horPush, D(shP, new[] { T(38, 1024, 1024, EK | WidenSession.TexTileU | WidenSession.TexSeamlessU) }));
            Check("族 2：半透明叠加、横向重复寻址但首尾不无缝（只是采样器缺省重复）→ Hor、不推", "Hor 0.00000 0.00000 0.00000", D(shP, new[] { T(39, 1024, 1024, EK | WidenSession.TexTileU) }));
            D(shP, new[] { T(36, 1024, 1024, EK | WidenSession.TexEdgeSmooth) }); bool ueDetail = s.UvExtend;
            D(shP, new[] { T(34, 24, 24, EK | WidenSession.TexFlatContent) }); bool ueFlat = s.UvExtend;   // 叠加层的小图按内容量过横向无细节（11-06 起叠加层不按尺寸猜）
            Check("族 2 采样坐标外扩：半透明有细节叠加层推满 → UvExtend 真；横向无细节层推满 → 假（照旧拉宽，看不出）", "True False", $"{ueDetail} {ueFlat}");
            // 11-02 泡泡龙4 说明页：整页字形网格一笔（非实例化、270 顶点 → 胶水标 DrawPatches），采 4096×4096 SDF 字体图集（边缘平滑）→ 同多实例：Hor、不推、不外扩
            string pt = D(shP, new[] { T(36, 1024, 1024, EK | WidenSession.TexEdgeSmooth) }, fl: WidenSession.DrawColor | WidenSession.DrawPatches); bool uePatch = s.UvExtend;
            Check("族 2：一笔多四边形的贴片批（字形网格）→ Hor、不推、不外扩采样坐标", "Hor 0.00000 0.00000 0.00000 False", $"{pt} {uePatch}");
            Check("同一界面层不透明、采 1024×1024（有细节）→ Hor、不推（整幅图片推了被拉伸）", "Hor 0.00000 0.00000 0.00000", D(shP, new[] { T(31, 1024, 1024) }, 1280, 720, WidenSession.DrawColor | WidenSession.DrawOpaque));
            Check("按内容判：尺寸不过、还没量过 → 点名想量这张（31）", 31u, s.WantFlat);
            // 异度3 选难度页横带型（11-01）：400 宽拼块铺满画布只放大 3.2 倍，尺寸规则判有细节；量过是平滑渐变 → 推满
            Check("按内容判：量过且横向平滑 → Hor 且推", horPush, D(shP, new[] { T(31, 1024, 1024, WidenSession.TexFlatKnown | WidenSession.TexFlatContent) }));
            Check("按内容判：量过且有细节（边缘也有细节）、半透明叠加 → Hor、不推（族 2 只推边缘可延续的）", "Hor 0.00000 0.00000 0.00000", D(shP, new[] { T(31, 1024, 1024, WidenSession.TexFlatKnown) }));
            Check("按内容判：量过且有细节、不透明 → Hor、不推", "Hor 0.00000 0.00000 0.00000", D(shP, new[] { T(31, 1024, 1024, WidenSession.TexFlatKnown) }, 1280, 720, WidenSession.DrawColor | WidenSession.DrawOpaque));
            Check("按内容判：量过的不再点名", 0u, s.WantFlat);
            // 马车8 选赛道「OK」页型（10-31）：出图目标上的界面层铺满画布、采横向平铺的 64×64 底纹 → 也推（平铺不推只对场景层，见下面目标 9 的标志面用例）
            Check("马车8 OK 页型：出图目标界面层采横向平铺 64×64 → Hor 且画布边推到屏幕边", horPush, D(shP, new[] { T(36, 64, 64, WidenSession.TexTileU) }));
            // 马车8 选车页光点型（11-01）：同样的界面层条件、采 128×128 平铺图，但一笔多实例（一批贴片）→ 不推，否则跨画布边的贴片被拉成横线
            Check("马车8 光点型：一笔多实例的平铺贴片 → Hor、不推", "Hor 0.00000 0.00000 0.00000", D(shP, new[] { T(37, 128, 128, WidenSession.TexTileU) }, fl: WidenSession.DrawColor | WidenSession.DrawInstanced));
            // 丝之歌实局型（10-31）：交换链三张轮换，规则 A 认不出出图目标；目标 15 挂深度，本帧先一笔铺满画布、只采放宽目标 1 的全屏合成（ScaleK），之后的遮罩照推
            s.Texture(15, 1280, 720, 1, WidenSession.UseRt); s.Texture(16, 1280, 720, 1, WidenSession.UseRt);
            s.Targets(16, 11); s.CbufBind(0, 0, pp, 64);
            Check("对照：挂深度、本帧没有全屏合成的目标上同一遮罩 → Hor、不推", "Hor 0.00000 0.00000 0.00000", D(shP, new[] { T(34, 24, 24) }));
            s.Targets(15, 11); s.CbufBind(0, 0, 0, 0);
            Check("丝之歌实局型：挂深度目标上第一笔铺满画布、只采放宽目标 → 全屏合成 ScaleK", "ScaleK", $"{s.Draw(0, 1280, 720, 1, shP, WidenSession.DrawColor, new[] { T(1, 1280, 720) }, push, out _)}");
            s.CbufBind(0, 0, pp, 64);
            Check("丝之歌实局型：全屏合成之后读改写投影、只采 24×24 的遮罩 → Hor 且画布边推到屏幕边", horPush, D(shP, new[] { T(34, 24, 24) }));
            // 马车8 选车页型（10-31）：同样已全屏合成的目标上，3D 模型先画深度（写深度、不采贴图）再按深度相等着色——写深度的笔不外推，否则相等比较失败、模型透出背景
            Check("马车8 选车页型：全屏合成之后读改写投影、写深度、不采贴图的笔 → Hor、不推", "Hor 0.00000 0.00000 0.00000", D(shP, new WidenSession.Tex[0], fl: WidenSession.DrawColor | WidenSession.DrawDepthWrite));
            Check("对照：同一笔不写深度 → Hor 且推（界面遮罩照推）", horPush, D(shP, new WidenSession.Tex[0]));
            s.Present(1, ref l, ref r, ref ax, 9); s.Targets(15, 11); s.CbufBind(0, 0, pp, 64);
            Check("丝之歌实局型：上屏后（新一帧还没合成）同一遮罩 → Hor、不推", "Hor 0.00000 0.00000 0.00000", D(shP, new[] { T(34, 24, 24) }));
            s.Targets(9, 0); s.CbufBind(0, 0, 0, 0);
            Check("没读改写过的镜头量的全屏层（几何本来就按全屏画、ScaleK）只采 8×1048 → 不推（推了画布边的元素会被推出屏幕）", "ScaleK 0.00000 0.00000 0.00000", D(shP, new[] { T(30, 8, 1048) }));
            s.Targets(3, 0);
            Check("原比例页型：铺满画布采 CPU 供图 1280×720 → 照旧起页、两侧清黑", "Page True [0,142) [1422,1564)",
                  $"{s.Draw(0, 1280, 720, 1, shP, WidenSession.DrawColor, new[] { T(33, 1280, 720) }, push, out _)} {s.PageSides(out int q0, out int q1, out int q2, out int q3)} [{q0},{q1}) [{q2},{q3})");
            // 两侧带兜底（调用方报清屏 / 拷贝 / 计算写：DrawWrites）：放宽目标本帧第一次被画、两侧还没有确定内容 → 这笔之前交出两侧条带 [0,142) [1422,1564) 清黑
            uint W = WidenSession.DrawColor | WidenSession.DrawWrites;
            string Sides(uint rt, uint fl = 0)
            {
                s.Targets(rt, 0); s.Draw(0, 1280, 720, 1, shP, fl == 0 ? W : fl, new[] { T(40, 1024, 1024) }, push, out _);
                return s.PageSides(out int m0, out int c0, out int c1, out int m1) ? $"[{m0},{c0}) [{c1},{m1})" : "不清";
            }
            // 马车8 型（10-29 选轮胎页诊断：背景目标 2706 每帧不清屏，第一笔是半透明的全屏渐变 ScaleK，之后的底纹层都按 Hor 原尺寸居中，两侧一直叠着上一帧）
            Check("马车8 型：目标 4 本帧没清屏、第一笔是不带 DrawOpaque 的铺满全宽 ScaleK → 这笔之前交出两侧条带清黑", "[0,142) [1422,1564)", Sides(4));
            Check("兜底：同帧第二笔 → 不再清", "不清", Sides(4));
            s.Frame.OnTargetCleared(5);
            Check("兜底：目标 5 本帧清过屏 → 不清", "不清", Sides(5));
            Check("兜底：调用方不报清屏 / 拷贝（没带 DrawWrites，GL / Vulkan 胶水）→ 不清", "不清", Sides(6, WidenSession.DrawColor));
            s.Present(4, ref l, ref r, ref ax, 9);
            Check("兜底：下一帧目标 4 又是第一次被画、没清屏 → 再清", "[0,142) [1422,1564)", Sides(4));
            s.GpuWrote(5, 0);
            Check("兜底：目标 5 本帧被计算整张写过 → 不清", "不清", Sides(5));
            s.Texture(7, 1280, 720, 1, WidenSession.UseRt); s.Texture(8, 1280, 720, 1, WidenSession.UseRt);
            Check("兜底：目标 7 第一笔就是不透明铺满全宽（ScaleK、DrawOpaque）→ 不清（它自己盖住两侧）", "不清", Sides(7, W | WidenSession.DrawOpaque));
            s.Targets(8, 0); s.Draw(0, 640, 360, 1, shP, W | WidenSession.DrawOpaque, new[] { T(40, 1024, 1024) }, push, out _);
            Check("兜底：目标 8 第一笔不透明但只画子视口 640×360 → 清", "[0,142) [1422,1564)", s.PageSides(out int z0, out int z1, out int z2, out int z3) ? $"[{z0},{z1}) [{z2},{z3})" : "不清");
            s.GpuWrote(6, 20);
            Check("兜底：目标 6 本帧只被 CPU 供图拷进客体那块 → 照清", "[0,142) [1422,1564)", Sides(6));
            // 马车8 比赛型（10-31）：每帧新建的临时累积目标，第一笔是带混合的铺满 ScaleK、只采放宽过的目标（全屏处理）→ 不清（这笔自己写满两侧，要和上一帧累加）
            s.Texture(13, 1280, 720, 1, WidenSession.UseRt); s.Texture(14, 1280, 720, 1, WidenSession.UseRt);
            s.Targets(13, 0); s.Draw(0, 1280, 720, 1, shP, W, new[] { T(14, 1280, 720) }, push, out _);
            Check("兜底：第一笔是铺满的 ScaleK、只采放宽目标（带混合）→ 不清", "不清", s.PageSides(out int y0, out int y1, out int y2, out int y3) ? $"[{y0},{y1}) [{y2},{y3})" : "不清");
            Check("计数：横向无细节推满 原尺寸居中层 3（128×72 + 几何铺满 / 没有切片两例；8×8 走原有规则不算）、原尺寸界面层 10（马车8 蓝底型、丝之歌暂停页型、马车8 OK 页型、丝之歌实局型、马车8 选车页型的对照笔；写深度那笔不算、异度3 横带型（量过平滑）、族 2 半透明有细节叠加层 2 笔 + 采样坐标外扩用例 2 笔；不透明的 2 笔不算），两侧兜底清黑 4", "3 10 4", $"{s.DrawsFlatShrunk} {s.DrawsFlatPushed} {s.SideClears}");
        }
    }

    static int Main()
    {
        var rw = new WidenRewriter(A0);
        Check("K 吸附 = 2346/1920（1920 多出偶数列）", 1.221875f, rw.K);
        Check("吸附后宽高比 = 2346/1080", 2.1722222f, rw.Aspect);
        Check("16:9 一族 1920×1080", true, WidenRewriter.Family(1920, 1080));
        Check("16:9 一族 30×17（取整尺寸）", true, WidenRewriter.Family(30, 17));
        Check("非一族 1024×1024", false, WidenRewriter.Family(1024, 1024));
        Check("非一族 2346×1080（已是屏幕比例）", false, WidenRewriter.Family(2346, 1080));
        Check("放宽宽度 1920×1080 → 2346", 2346, rw.WidenWidth(1920, 1080));
        Check("放宽宽度 1280×720 → 1564（1280×1.221875 整）", 1564, rw.WidenWidth(1280, 720));
        // 宽度规则（10-21）：宽 × K 是整数（K = 391/320，宽是 320 的倍数）就取它，否则多出偶数列。手算：960·391/320 = 1173、1600·391/320 = 1955、320·391/320 = 391；
        // 1024·391/320 = 1251.2 不是整数 → 1024 + 2·round(113.6) = 1252。旧规则（一律偶数列）给 1174 / 1956 / 392 / 1252
        Check("放宽宽度 960×540 → 960·K = 1173（整数，取它）", 1173, rw.WidenWidth(960, 540));
        Check("放宽宽度 1600×900 → 1600·K = 1955（暗黑2 交换链；旧规则 1956）", 1955, rw.WidenWidth(1600, 900));
        Check("放宽宽度 320×180 → 391（= 1564 / 4）", 391, rw.WidenWidth(320, 180));
        Check("放宽宽度 1024×576 → 1252（1024·K 非整数 → 多出偶数列，丝之歌）", 1252, rw.WidenWidth(1024, 576));
        // 整宽按级缩下来的宽：期望 = 整宽放宽后按级缩 ⌊宽1 / 2^L⌋（Metal mip 级宽），与独立建的同尺寸贴图互拷尺寸一致（10-21 暗黑2 160×90 旧取 196）
        Check("放宽宽度 160×90 → 195（= 1564 >> 3）", 1564 >> 3, rw.WidenWidth(160, 90));
        Check("放宽宽度 80×45 → 97（= 1564 >> 4）", 1564 >> 4, rw.WidenWidth(80, 45));
        Check("放宽宽度 240×135 → 293（= 2346 >> 3；旧 294）", 2346 >> 3, rw.WidenWidth(240, 135));
        Check("放宽宽度 200×112 → 244（= 1955 >> 3）", 1955 >> 3, rw.WidenWidth(200, 112));
        Check("放宽宽度 512×288 → 626（512 << L 都不是整宽 → 仍多出偶数列）", 626, rw.WidenWidth(512, 288));
        {
            var fw = new WidenFrame(new WidenRewriter(A0)); fw.OnCreateTexture(5, 1600, 900);
            Check("1600 宽贴图里的子画布 1280 → MapX = 1564（整数、与 1280×720 目标的 1564 相同；旧规则 1565 奇数）", 1564, fw.MapX(5, 1280));
        }
        Check("非一族不放宽 1024×1024", 1024, rw.WidenWidth(1024, 1024));
        Check("目标 ≤16:9 时关闭", false, new WidenRewriter(16f / 9f).On);

        // 银河2（Vulkan）推送常量里的真实投影（10-25 常量转储，第一关 6299 笔绘制读它）：204 字节推送块、偏移 48 一个行存 4×4，GX 式深度（p4 ≈ 0、p5 = 100）、
        // y 缩放取负（Vulkan y 朝下）、中心偏 1/3840 / 1/2160，y/x = 1.7807（16:9 的 1% 容差内）。期望按定义：命中 1 个投影，x 缩放写成 4.2656/K，其余不动
        {
            var r = new WidenRewriter(A0); float[] pc = new float[51];
            new[] { 4.2656f, 0, 0.000260417f, 0, 0, -7.59575f, 0.000462963f, 0, 0, 0, 0.000125016f, 100.013f, 0, 0, -1, 0 }.CopyTo(pc, 12);
            byte[] src = B(pc), dst = new byte[src.Length];
            Check("银河2 推送常量投影命中", true, r.Rewrite(src, 0, dst) && r.Stats.Projection == 1);
            float[] m = Fl(dst);
            Check("银河2 投影 x 缩放 = 4.2656/K、y 缩放不动（5 位小数）", $"{4.2656f / K:F5} -7.59575", $"{m[12]:F5} {m[17]:F5}");
        }
        // 行存投影：x 行乘 1/K，改写后 |P11|/P00 = 目标宽高比
        {
            var r = new WidenRewriter(A0); byte[] src = B(Proj()); byte[] dst = new byte[64];
            Check("行存投影命中", true, r.Rewrite(src, 0, dst));
            float[] m = Fl(dst);
            Check("行存投影 P00 = 1.3579951/K", P00 / K, m[0]);
            Check("改写后 P11/P00 = 2346/1080", A, m[5] / m[0]);
            Check("行存投影 y 行不动", P11, m[5]);
            Check("计数 投影", 1L, r.Stats.Projection);
            byte[] dst2 = new byte[64]; long pj = r.Stats.Projection + r.Stats.ViewProjection + r.Stats.InverseProjection;
            // 幂等 = 不二次缩放：改写过的投影宽高比已是屏幕比，11-06 起会被认作「游戏自己的宽镜头」（WideProjection，只登记不改值），所以按数据不变、改写计数不涨判
            bool again = r.Rewrite(dst, 0, dst2);
            Check("改写过的数据再过一遍不再改写（幂等：数据不变、改写计数不涨）", "True 0", $"{(!again || dst2.AsSpan().SequenceEqual(dst))} {r.Stats.Projection + r.Stats.ViewProjection + r.Stats.InverseProjection - pj}");
        }
        // 列存投影（转置）：每列第 0 个元素乘 1/K
        {
            var r = new WidenRewriter(A0); float[] p = Proj(); float[] t = new float[16];
            for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) t[j * 4 + i] = p[i * 4 + j];
            byte[] dst = new byte[64];
            Check("列存投影命中", true, r.Rewrite(B(t), 0, dst));
            float[] m = Fl(dst);
            Check("列存投影 P00 位置 [0]", P00 / K, m[0]);
            Check("列存投影 [8]（原 P(2,0)=0）仍 0", 0f, m[8]);
            Check("计数 列存", 1L, r.Stats.ColumnMajor);
        }
        // 判当零的元素原样不动（10-22 暗黑2 人物界面闪烁，回放取的真实 64 字节）：3 行投影（列存读）后紧跟光照分块参数整数 (32, 20, 1, 1)，
        // 按浮点读 ≈ 0 凑成第 4 列、整窗认成投影。期望按定义：[0] = P00/K；[12..15] 的位原样（旧代码 [12] 乘 1/K：整数 32 → 26，光照剔除只铺 26 格）
        {
            byte[] src = new byte[64];
            MemoryMarshal.Cast<byte, float>(src.AsSpan(0, 48))[0] = 1.46536f; MemoryMarshal.Cast<byte, float>(src.AsSpan(0, 48))[5] = 2.60509f; MemoryMarshal.Cast<byte, float>(src.AsSpan(0, 48))[11] = -1f;
            uint[] tail = { 32, 20, 1, 1 }; MemoryMarshal.AsBytes(tail.AsSpan()).CopyTo(src.AsSpan(48));
            var r = new WidenRewriter(A0); byte[] dst = new byte[64];
            Check("投影后紧跟整数：整窗命中投影", true, r.Rewrite(src, 0, dst) && r.Stats.Projection == 1);
            Check("投影后紧跟整数：[0] = P00 / K", 1.46536f / K, Fl(dst)[0]);
            Check("投影后紧跟整数：末 16 字节整数原样 32,20,1,1", "32,20,1,1", string.Join(",", MemoryMarshal.Cast<byte, uint>(dst.AsSpan(48)).ToArray()));
            float[] wd = new float[16];
            Check("逐窗口路径同样命中、整数原样", "32,20,1,1", new WidenRewriter(A0).RewriteWindow(Fl(src), wd, out _, out _) ? string.Join(",", MemoryMarshal.Cast<float, uint>(wd.AsSpan(12)).ToArray()) : "没命中");
        }
        // 不该命中：正交、单位阵、骨骼仿射、非 16:9 投影
        {
            var r = new WidenRewriter(A0); byte[] dst = new byte[64];
            byte[] uo = B(2f / 1920, 0, 0, -1, 0, 2f / 1080, 0, -1, 0, 0, 1, 0, 0, 0, 0, 1);
            // 纯 2D 款（10-31 植物大战僵尸 / Slay the Spire 两侧 213 黑带）：整局还没出现过场景镜头 → 像素正交按场景镜头改写（x 行 ÷ K）、记纯 2D 一次
            Check("纯 2D：没见过场景镜头时像素正交改写 [0] = (2/1920)/K", (2f / 1920) / K, r.Rewrite(uo, 0, dst) ? Fl(dst)[0] : float.NaN);
            Check("纯 2D：记为纯 2D 款的像素正交 1 次、不记界面正交", "1 0", $"{r.Stats.Ortho2D} {r.Stats.UiOrtho}");
            r.Rewrite(B(Proj()), 0, dst);   // 出现场景透视镜头之后：恢复界面正交只登记（3D 款）
            r.Rewrite(uo, 0, dst);
            Check("界面正交投影 (2/1920, 2/1080, 偏移 −1) 只登记不改：值不变", true, ((ReadOnlySpan<byte>)dst).SequenceEqual(uo));
            Check("界面正交投影：登记为界面正交 1 次", 1L, r.Stats.UiOrtho);
            for (int i = 0; i < WidenRewriter.Scene2DFrames; i++) r.EndFrame();
            Check("纯 2D：镜头 60 次上屏前出现过（时间窗内）→ 仍只登记", true, !r.Rewrite(uo, 0, dst) || ((ReadOnlySpan<byte>)dst).SequenceEqual(uo));
            r.EndFrame();
            Check("纯 2D：61 次上屏没再出现镜头（植物大战僵尸开机只有几次镜头命中）→ 又按场景改写", (2f / 1920) / K, r.Rewrite(uo, 0, dst) ? Fl(dst)[0] : float.NaN);
            Check("单位阵不改", false, r.Rewrite(B(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1), 0, dst));
            Check("骨骼仿射（缩放 0.5625:1）不改", false, r.Rewrite(B(0.5625f, 0, 0, 3, 0, 1, 0, 4, 0, 0, 1, 5, 0, 0, 0, 1), 0, dst));
            Check("4:3 投影 (P11/P00=4/3) 不改", false, r.Rewrite(B(1.81066f, 0, 0, 0, 0, 2.41421f, 0, 0, 0, 0, -1, -0.2f, 0, 0, -1, 0), 0, dst));
            // 原比例回退（11-01，根因族 1：忍者龟标题页 Hor+ 露出左侧游戏没画的区域）：回退开着时纯 2D 帧的像素正交只登记不改、仍记「最近是纯 2D 帧」
            r.Pure2DOff = true;
            Check("原比例回退：回退中纯 2D 像素正交不改（值不变）", true, !r.Rewrite(uo, 0, dst) || ((ReadOnlySpan<byte>)dst).SequenceEqual(uo));
            Check("原比例回退：回退中仍记最近是纯 2D 帧", true, r.Pure2DRecent);
            r.Pure2DOff = false;
            Check("签名：8 格完全相同 → 没换场景", false, WidenSession.SceneChanged(0x11111111u, 0x11111111u));
            Check("签名：8 格各差 1 档（亮度小抖）→ 没换场景", false, WidenSession.SceneChanged(0x11111111u, 0x22222222u));
            Check("签名：2 格差 ≥3 档 → 没换场景", false, WidenSession.SceneChanged(0x11111111u, 0x11111155u));
            Check("签名：3 格差 ≥3 档 → 换场景", true, WidenSession.SceneChanged(0x11111111u, 0x11111555u));
            var fb = new WidenSession(2346, 1080, false, true, false); int fl = 0, fr2 = 0, ft = 0, fbm = 0; float fax = 0;
            fb.Rewriter.Rewrite(uo, 0, dst);   // 本帧纯 2D（没见过场景镜头）
            fb.SideCoverage(false, false, 0x00000000u); fb.SideCoverage(false, false, 0x00010100u); fb.SideCoverage(false, false, 0u);
            Check("原比例回退：中间也没内容（开机黑屏，8 格最高 ≤ 1 档）连续 3 个样本两侧没内容 → 不计、不回退（植物大战僵尸）", false, fb.Rewriter.Pure2DOff);
            Check("原比例回退：中间没内容的样本记数 3", 3L, fb.BlankSamples);
            fb.SideCoverage(false, false, 0x00000300u); fb.SideCoverage(false, false, 0u); fb.SideCoverage(false, false, 0x00000300u);
            Check("原比例回退：两侧没内容的样本之间夹一个中间没内容的 → 不清零，连满 2 个就回退", true, fb.Rewriter.Pure2DOff);
            fb = new WidenSession(2346, 1080, false, true, false); fb.Rewriter.Rewrite(uo, 0, dst);
            fb.SideCoverage(false, true, 0x33333333u); fb.SideCoverage(false, true, 0x33333333u); fb.SideCoverage(true, false, 0x33333333u);
            Check("原比例回退：只有一侧没画到（DOUBLE DRAGON4 镜头到关卡左端、左侧露清屏色、右侧有场景）连续 3 个样本 → 不回退", false, fb.Rewriter.Pure2DOff);
            fb.SideCoverage(false, false, 0x33333333u);
            Check("原比例回退：纯 2D 帧两侧都没画到 1 个样本 → 还不回退（迟滞）", false, fb.Rewriter.Pure2DOff);
            fb.SideCoverage(true, true, 0x33333333u);
            fb.SideCoverage(false, false, 0x33333333u);
            Check("原比例回退：中间夹一个两侧都画到的样本 → 计数清零、不回退", false, fb.Rewriter.Pure2DOff);
            fb.SideCoverage(false, true, 0x33333333u);
            Check("原比例回退：中间夹一个只一侧没画到的样本 → 计数清零、不回退", false, fb.Rewriter.Pure2DOff);
            fb.SideCoverage(false, false, 0x33333333u); fb.SideCoverage(false, false, 0x33333333u);
            Check("原比例回退：连续 2 个样本两侧都没画到 → 回退", true, fb.Rewriter.Pure2DOff);
            fb.Rewriter.Rewrite(uo, 0, dst);
            Check("原比例回退：回退中纯 2D 帧上屏返回 5", 5, fb.Present(1, ref fl, ref fr2, ref ft, ref fbm, ref fax, 1f));
            fb.SideCoverage(false, false, 0x33333344u);
            Check("原比例回退：中间画面小变 → 不解除", true, fb.Rewriter.Pure2DOff);
            fb.SideCoverage(false, false, 0x33333777u); fb.SideCoverage(false, false, 0x33333777u);
            Check("原比例回退滞回：连续 2 个样本换了场景、但回退才 1 次上屏（< 60）→ 不解除（防淡入淡出左右闪）", true, fb.Rewriter.Pure2DOff);
            for (int i = 0; i < 60; i++) { fb.Rewriter.Rewrite(uo, 0, dst); fb.Present(1, ref fl, ref fr2, ref ft, ref fbm, ref fax, 1f); }
            fb.SideCoverage(false, false, 0x33333333u);
            Check("原比例回退滞回：满 60 次上屏后来一个没换场景的样本 → 换场景计数清零、不解除", true, fb.Rewriter.Pure2DOff);
            fb.SideCoverage(false, false, 0x33333777u);
            Check("原比例回退滞回：之后只 1 个样本换了场景 → 不解除", true, fb.Rewriter.Pure2DOff);
            fb.SideCoverage(false, false, 0x33333777u);
            Check("原比例回退：满 60 次上屏、连续 2 个样本中间画面换了（3 格大变）→ 解除、重试放宽", false, fb.Rewriter.Pure2DOff);
            Check("原比例回退：记下最短一次回退持续 61 次上屏", 61L, fb.FallbackShortest);
            var f3 = new WidenSession(2346, 1080, false, true, false);
            f3.Rewriter.Rewrite(B(Proj()), 0, dst);   // 3D 帧：见过场景镜头
            f3.SideCoverage(false, false, 0); f3.SideCoverage(false, false, 0);
            Check("原比例回退：3D 帧两侧没内容（只给有没有内容的旧接口）→ 纯 2D 回退不开", false, f3.Rewriter.Pure2DOff);
            // 族 1 ③ 3D 镜头帧回退（11-01）：两侧游戏都没画到（哨兵还在）连续 2 个样本 → 上屏裁剪框收进存储中间 16:9。手算：原宽 1280、k = 2346/1920 →
            //   存储 1564（同上文画布），中间 16:9 = [142, 1422)；两侧画成纯色（没内容但画到了）不算——真 3D 场景两侧的夜空 / 暗色不能误回退
            var c3 = new WidenSession(2346, 1080, false, true, false); int cl = 0, cr = 0, ctp = 0, cbt = 0; float cax = 0;
            c3.Texture(70, 1280, 720, 1, WidenSession.UseRt);
            c3.Rewriter.Rewrite(B(Proj()), 0, dst);
            c3.SideCoverage(false, false, false, false, 0x55555555u); c3.SideCoverage(false, false, false, false, 0x55555555u);
            Check("3D 镜头帧：两侧没内容但画到了（纯色 / 暗）连续 2 个样本 → 不回退", false, c3.Crop3D);
            c3.SideCoverage(false, false, true, false, 0x55555555u); c3.SideCoverage(false, false, false, true, 0x55555555u);
            Check("3D 镜头帧：只一侧没画到 → 不回退", false, c3.Crop3D);
            c3.SideCoverage(false, false, true, true, 0x55555555u); c3.SideCoverage(false, false, true, true, 0x55555555u);
            Check("3D 镜头帧：两侧都没画到连续 2 个样本 → 3D 回退", true, c3.Crop3D);
            c3.Rewriter.Rewrite(B(Proj()), 0, dst);
            int pr3 = c3.Present(70, ref cl, ref cr, ref ctp, ref cbt, ref cax, 1f);
            Check("3D 镜头帧回退：上屏返回 5、裁剪框收进中间 [142, 1422)", "5 142 1422", $"{pr3} {cl} {cr}");
            for (int i = 0; i < 60; i++) { c3.Rewriter.Rewrite(B(Proj()), 0, dst); c3.Present(70, ref cl, ref cr, ref ctp, ref cbt, ref cax, 1f); }
            c3.SideCoverage(false, false, true, true, 0x99999999u); c3.SideCoverage(false, false, true, true, 0x99999999u);
            Check("3D 镜头帧回退：中间画面大变但两侧仍没画到 → 不解除（解除只看两侧有没有被画到）", true, c3.Crop3D);
            // Ui 模式回退（11-02 怪猎健康提醒页两侧白、塞尔达菜单黑：游戏靠第二层补丁自己出宽图，界面页只画中间 16:9，两侧露游戏清屏色）：
            //   宿主关不掉游戏的宽布局，回退在上屏收：裁剪框收进中间 16:9。手算：屏 2346×1080、k = 2346 / 1920，裁剪 [0, 2346) → [(2346 − 1920) / 2, 2346 − 213) = [213, 2133)
            {
                var u = new WidenSession(2346, 1080, true, true, false); int ul = 0, ur = 2346, ut = 0, ub = 1080; float uax = 0;
                u.Rewriter.Rewrite(uo, 0, dst);   // 纯 2D 帧（健康提醒页）
                u.SideCoverage(false, false, 0x33333333u); u.SideCoverage(false, false, 0x33333333u);
                Check("Ui 模式：纯 2D 帧两侧没内容连续 2 个样本 → 上屏收进中间（CropUi），不动纯 2D 改写", "Ui True False", $"{u.Mode} {u.CropUi} {u.Rewriter.Pure2DOff}");
                int pu = u.Present(1, ref ul, ref ur, ref ut, ref ub, ref uax, 1f);
                Check("Ui 模式回退：上屏返回 5、裁剪框 [0, 2346) 收进 [213, 2133)", "5 213 2133", $"{pu} {ul} {ur}");
                for (int i = 0; i < 60; i++) { ul = 0; ur = 2346; u.Rewriter.Rewrite(uo, 0, dst); u.Present(1, ref ul, ref ur, ref ut, ref ub, ref uax, 1f); }
                u.SideCoverage(false, false, 0x99999999u); u.SideCoverage(false, false, 0x99999999u);
                Check("Ui 模式回退：中间换了但两侧仍没内容 → 不解除（解除只看两侧有没有内容）", true, u.CropUi);
                u.SideCoverage(true, false, 0x99999999u); u.SideCoverage(false, true, 0x99999999u);
                Check("Ui 模式回退：满 60 次上屏后连续 2 个样本有一侧有内容 → 解除", false, u.CropUi);
                ul = 0; ur = 2346; int pn = u.Present(1, ref ul, ref ur, ref ut, ref ub, ref uax, 1f);
                Check("Ui 模式回退解除后：上屏照常（不返回 5、裁剪不动）", "False 0 2346", $"{pn == 5} {ul} {ur}");
                var u3 = new WidenSession(2346, 1080, true, true, false); u3.Rewriter.Rewrite(B(Proj()), 0, dst);   // 3D 帧（塞尔达菜单：林克模型）
                u3.SideCoverage(false, false, false, false, 0x55555555u); u3.SideCoverage(false, false, false, false, 0x55555555u);
                Check("Ui 模式 3D 帧：两侧画成纯色 / 暗（画到了）→ 不回退", false, u3.CropUi);
                u3.SideCoverage(false, false, true, true, 0x55555555u); u3.SideCoverage(false, false, true, true, 0x55555555u);
                Check("Ui 模式 3D 帧：两侧都没画到连续 2 个样本 → 上屏收进中间（CropUi），不走放宽贴图的 3D 回退", "True False", $"{u3.CropUi} {u3.Crop3D}");
            }
            // 直连整屏副本登记（11-02 塞尔达直连菜单底图只铺中间 16:9：10-21 规则的登记那半只在包装层，直连从没登记过）。Ui 模式（屏 2346×1080，屏幕比 1564 / 720）：
            //   目标 80 / 82 是 1564×720 渲染目标；铺满整张、只采 1564×720 整屏画面（79）→ 80 是整屏副本；之后采 80 的一笔「采样了宽内容」= 真。反例按包装层：子视口不算、多采一张 256×256 界面图不算
            {
                var sc = new WidenSession(2346, 1080, true, true, false); float[] sp = new float[4]; int[] ssh = new int[6];
                foreach (uint id in new uint[] { 80, 81, 82 }) sc.Texture(id, 1564, 720, 1, WidenSession.UseRt);
                WidenSession.Tex P(uint id, int w, int h) => new WidenSession.Tex { Id = id, W = w, H = h, Scale = 1 };
                sc.Targets(81, 0); sc.Draw(0, 1564, 720, 1, ssh, WidenSession.DrawColor, new[] { P(79, 1564, 720), P(90, 256, 256) }, sp, out _);
                sc.Targets(82, 0); sc.Draw(0, 782, 360, 1, ssh, WidenSession.DrawColor, new[] { P(79, 1564, 720) }, sp, out _);
                Check("整屏副本反例：多采一张 256×256 界面图 / 子视口 782×360 → 不登记", "False False", $"{sc.Frame.IsScreenCopy(81)} {sc.Frame.IsScreenCopy(82)}");
                sc.Targets(80, 0); sc.Draw(0, 1564, 720, 1, ssh, WidenSession.DrawColor, new[] { P(79, 1564, 720), P(91, 4, 4) }, sp, out _);
                Check("整屏副本：铺满整张、只采 1564×720 整屏画面（加一张 4×4 查找表）→ 80 登记为整屏副本", true, sc.Frame.IsScreenCopy(80));
                sc.Targets(81, 0); sc.Draw(0, 1564, 720, 1, ssh, WidenSession.DrawColor, new[] { P(80, 1564, 720) }, sp, out _);
                Check("采样整屏副本 80 的一笔：采样了宽内容（铺满，不当界面层收进中间）", true, sc.Frame.DrawSamplesWide);
                // 跳过核心的 16:9 目标（Ui 模式 16:9 视口不进核心）：调用方只交采样表登记（NoteFill）。塞尔达菜单缩图链 782×360 → 320×180
                sc.NoteFill(84, 320, 180, new[] { P(80, 1564, 720), P(90, 256, 256) });
                sc.NoteFill(83, 320, 180, new[] { P(80, 1564, 720), P(91, 8, 8) });
                Check("NoteFill：跳过核心的 320×180 只采整屏副本 80（加 8×8 查找表）→ 登记为副本；多采 256×256 界面图的 84 → 不登记", "True False", $"{sc.Frame.IsScreenCopy(83)} {sc.Frame.IsScreenCopy(84)}");
                sc.Targets(81, 0); sc.Draw(0, 1564, 720, 1, ssh, WidenSession.DrawColor, new[] { P(83, 320, 180) }, sp, out _);
                Check("菜单底图采样 320×180 副本 83：采样了宽内容", true, sc.Frame.DrawSamplesWide);
            }
            c3.SideCoverage(true, false, false, true, 0x99999999u); c3.SideCoverage(true, true, false, false, 0x99999999u);
            Check("3D 镜头帧回退：满 60 次上屏、连续 2 个样本有一侧被画到 → 解除、恢复放宽上屏", false, c3.Crop3D);
        }
        // 正交：暗黑2 等距视角（10-21 回放取的真实数值，行存展开）。对称正交投影 P = diag(0.025454, 0.045251, 0.0001001)、z 平移 1.001；
        // 世界用 P × 视图旋转（列存上传）。期望按构造：P 的 x 行 ÷K；先认过 P（记正交相机签名）才认 正交 × 视图，x 行 ÷K、其余不动；骨骼仿射 / 没认过镜头 / 改写过的都不改
        {
            float[] Po = { 0.025454f, 0, 0, 0, 0, 0.045251f, 0, 0, 0, 0, 0.0001001f, 1.001f, 0, 0, 0, 1 };
            float c45 = MathF.Sqrt(0.5f), sa = 0.5f, ca = MathF.Sqrt(3) / 2;
            float[] Vr = { c45, 0, -c45, 120, -c45 * sa, ca, -c45 * sa, -40, c45 * ca, sa, c45 * ca, 900, 0, 0, 0, 1 };   // 绕 y 45°、俯 30° + 平移
            float[] MulO(float[] x, float[] y) { var o = new float[16]; for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) { float acc = 0; for (int k = 0; k < 4; k++) acc += x[i * 4 + k] * y[k * 4 + j]; o[i * 4 + j] = acc; } return o; }
            float[] OV = MulO(Po, Vr), OVc = new float[16]; for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) OVc[j * 4 + i] = OV[i * 4 + j];
            byte[] d0 = new byte[64], d1 = new byte[64], d2 = new byte[64], d3 = new byte[64];
            Check("没认过正交镜头：正交 × 视图不改", false, new WidenRewriter(A0).Rewrite(B(OVc), 0, d0));
            var r = new WidenRewriter(A0);
            // 暗黑2 这个投影 z 平移 1.001：按列存读时 w 行 xyz = (0,0,1.001)，main 原有的透视视图投影判据就认（改的位置等价于正交改写），维持原行为
            r.Rewrite(B(Po), 0, d1);
            Check("暗黑2 对称正交投影（z 平移 ≈ 1）维持原行为：被改写、x 行 = 0.025454 / K", 0.025454f / K, Fl(d1)[0]);
            // z 平移不是 1 的对称正交投影（丝之歌界面一类）：只记正交签名、本身不改
            var r2 = new WidenRewriter(A0); byte[] d4 = new byte[64];
            Check("对称正交投影（z 平移 0.5）只记签名、本身不改（10-21 丝之歌界面用它，改了界面移位）", false, r2.Rewrite(B(0.025454f, 0, 0, 0, 0, 0.045251f, 0, 0, 0, 0, 0.0001001f, 0.5f, 0, 0, 0, 1), 0, d4));
            Check("它记下的正交签名照样能认 正交 × 视图", true, r2.Rewrite(B(OVc), 0, d4));
            float[] Vt = { 1, 0, 0, 30, 0, 1, 0, -8, 0, 0, 1, 2, 0, 0, 0, 1 };   // 只平移、不旋转：2D 层
            Check("轴对齐的 正交 × 平移（2D 层 / 界面，丝之歌血量条一类）不改", false, r2.Rewrite(B(MulO(Po, Vt)), 0, d4));
            Check("认过正交投影后：正交 × 视图（列存）命中", true, r.Rewrite(B(OVc), 0, d2));
            bool xs = true, rest = true; float[] dd = Fl(d2);
            for (int j = 0; j < 4; j++) xs &= MathF.Abs(dd[j * 4] - OVc[j * 4] / K) <= 1e-6f * MathF.Max(1, MathF.Abs(OVc[j * 4]));
            for (int i = 0; i < 16; i++) if (i % 4 != 0) rest &= dd[i] == OVc[i];
            Check("正交 × 视图：x 行（列存每列第 0 个）= 原值 / K、其余不动", true, xs && rest);
            Check("计数 正交 1", 1L, r.Stats.Ortho);
            Check("改写过的正交 × 视图再过一遍不再命中（幂等）", false, r.Rewrite(d2, 0, d3));
            Check("认过正交镜头后：骨骼仿射（缩放 0.5625:1、两两正交）仍不改", false, r.Rewrite(B(0.5625f, 0, 0, 3, 0, 1, 0, 4, 0, 0, 1, 5, 0, 0, 0, 1), 0, d3));
            float[] wv = new float[16];
            Check("逐窗口路径同样认 正交 × 视图", true, r.QuickWindow(OVc) && r.RewriteWindow(OVc, wv, out var ko, out _) && ko == WidenKind.ViewProjection);
        }
        // 16:9 正交 × 绕 x 轴俯仰（10-25 哈迪斯等距视角，Vulkan 层转储 w_dump/cb.bin 偏移 264 / 280 浮点的原值，列存）：游戏不单独上传正交投影、俯仰轴是 x 轴（x 行轴对齐）。
        // 期望按构造：|y 行| / |x 行| = 0.0014087 / 0.0007925 = 1.7776（16:9）→ 认成视图投影，x 行（列存每列第 0 个）÷K、其余不动；没有俯仰的轴对齐正交（2D 层）、
        // z 行与 x 行同量级（骨骼）、比例不是 16:9 的都不认；改写过的不再认
        {
            float[] Hw = { 0.0007924874f, 0, 0, 0, 0, -0.0007044332f, -4.330127e-06f, 0, 0, -0.001220114f, 2.5e-06f, 0, -1.591483f, 7.184695f, 0.5441641f, 1 };
            float[] Hs = { 0.001041667f, 0, 0, 0, 0, -0.0009259259f, -4.330127e-06f, 0, 0, -0.001603751f, 2.5e-06f, 0, -1, 1, 0.5031177f, 1 };
            var r = new WidenRewriter(A0); byte[] d = new byte[128], d2 = new byte[128];
            float[] HH = new float[32]; Hw.CopyTo(HH, 0); Hs.CopyTo(HH, 16); byte[] both = B(HH);
            Check("哈迪斯世界相机 + 屏幕层（正交 × 俯仰）没认过任何镜头也命中", true, r.Rewrite(both, 0, d));
            float[] o = Fl(d); bool xs = true, rest = true;
            for (int mi = 0; mi < 2; mi++) { float[] src = mi == 0 ? Hw : Hs;
                for (int i = 0; i < 16; i++) { float g = o[mi * 16 + i], w = i % 4 == 0 ? src[i] / K : src[i]; if (i % 4 == 0) xs &= MathF.Abs(g - w) <= 1e-6f * MathF.Max(1, MathF.Abs(w)); else rest &= g == w; } }
            Check("两个矩阵 x 行（含 x 平移）= 原值 / K、其余 12 个元素不动", true, xs && rest);
            Check("计数 正交 2、视图投影 2", "2 2", $"{r.Stats.Ortho} {r.Stats.ViewProjection}");
            Check("改写过的再过一遍不再命中（幂等）", false, r.Rewrite(d, 0, d2));
            float[] wv = new float[16];
            Check("逐窗口路径同样认（新改写器）", true, new WidenRewriter(A0) is var rw2 && rw2.QuickWindow(Hw) && rw2.RewriteWindow(Hw, wv, out var kh, out _) && kh == WidenKind.ViewProjection);
            byte[] dn = new byte[64];
            Check("没有俯仰的轴对齐正交（2D 层，y 行无 z 分量）不认", false, new WidenRewriter(A0).Rewrite(B(0.0007924874f, 0, 0, 0, 0, -0.0014087f, 0, 0, 0, 0, 5e-06f, 0, -1.591483f, 7.184695f, 0.5441641f, 1), 0, dn));
            Check("z 行与 x 行同量级（骨骼 / 世界矩阵）不认", false, new WidenRewriter(A0).Rewrite(B(0.0007924874f, 0, 0, 0, 0, -0.0007044332f, -0.0006f, 0, 0, -0.001220114f, 0.000346f, 0, -1.591483f, 7.184695f, 0.5441641f, 1), 0, dn));
            Check("俯仰但比例不是 16:9（4:3）不认", false, new WidenRewriter(A0).Rewrite(B(0.0010566f, 0, 0, 0, 0, -0.0007044332f, -4.330127e-06f, 0, 0, -0.001220114f, 2.5e-06f, 0, -1.591483f, 7.184695f, 0.5441641f, 1), 0, dn));
            // 界面画布「缩放 + 偏移」（同一局 HUD 文字，按笔转储原值）：(2/1280, −2/720, 0, 0)、(2/1280, −2/720, −640, −360) → 登记界面正交、值不改；
            //   宽高不是 16:9 一族 / 偏移不是画布中心的负值 / 两个 vec4 缩放不同 都不认
            float[] cv = new float[16]; float[] cv0 = { 0.0015625f, -0.00277778f, 0, 0, 0.0015625f, -0.00277778f, -640, -360 }; cv0.CopyTo(cv, 0);
            var rc = new WidenRewriter(A0); byte[] dc = new byte[64], ocv = B(cv);
            rc.Rewrite(ocv, 0, dc);
            Check("界面画布（2/1280、−2/720、−640、−360）登记界面正交 1 次、值不改", "1 True", $"{rc.Stats.UiOrtho} {((ReadOnlySpan<byte>)dc).SequenceEqual(ocv)}");
            float[] cvBad = (float[])cv.Clone(); cvBad[6] = -600;
            var rb = new WidenRewriter(A0); rb.Rewrite(B(cvBad), 0, new byte[64]);
            float[] cv43 = (float[])cv.Clone(); cv43[1] = cv43[5] = -2f / 960; cv43[7] = -480;
            var r43 = new WidenRewriter(A0); r43.Rewrite(B(cv43), 0, new byte[64]);
            Check("界面画布：偏移不是画布中心 / 1280×960（非 16:9）不认", "0 0", $"{rb.Stats.UiOrtho} {r43.Stats.UiOrtho}");
            float[] wv2 = new float[16];
            Check("界面画布：逐窗口路径同样认", true, new WidenRewriter(A0) is var rw3 && rw3.QuickWindow(cv) && rw3.RewriteWindow(cv, wv2, out var kc, out _) && kc == WidenKind.UiOrtho);
        }
        // 正交投影的逆（10-22 暗黑2 营地，回放取的真实数值：逆投影 c[17..20] 按行存放 = diag(1/P00, 1/P11, 9990) + z 平移 −10000，列存读 w 行 = 0001）：
        // 光照遮罩用 c[17].x 把屏幕 x 换回视空间，没改 → 光斑横向拉宽 k 倍。期望按构造：先认过正交投影 P（签名 P00 = 0.0254535、P11 = 0.0452507）后，逆投影 [0] = 39.2873·K、其余不动；
        // 没认过镜头不改；对角 16:9 但对不上签名的贴图变换 diag(0.025, 0.125, 0.05) 不改；改写过的再过一遍不再命中（幂等）
        {
            float[] Po = { 0.0254535f, 0, 0, 0, 0, 0.0452507f, 0, 0, 0, 0, 0.0001001f, 1.001f, 0, 0, 0, 1 };
            float[] Ip = { 39.2873f, 0, 0, 0, 0, 22.0991f, 0, 0, 0, 0, 9990, 0, 0, 0, -10000, 1 };
            byte[] dp = new byte[64], di = new byte[64];
            Check("没认过正交镜头：逆投影不改", false, new WidenRewriter(A0).Rewrite(B(Ip), 0, di));
            var r = new WidenRewriter(A0); r.Rewrite(B(Po), 0, dp);
            Check("认过正交镜头后逆投影命中", true, r.Rewrite(B(Ip), 0, di) && r.Stats.InverseProjection == 1);
            float[] o = Fl(di); bool rest = true; for (int i = 1; i < 16; i++) rest &= o[i] == Ip[i];
            Check("正交逆投影 [0] = 39.2873·K", 39.2873f * K, o[0]);
            Check("正交逆投影其余 15 个元素不动", true, rest);
            Check("对角 16:9 贴图变换 diag(0.025, 0.125, 0.05) 不改", false, r.Rewrite(B(0.025f, 0, 0, 0, 0, 0.125f, 0, 0, 0, 0, 0.05f, 0, 0, 0, 0, 1), 0, dp));
            Check("改写过的正交逆投影再过一遍不再命中（幂等）", false, r.Rewrite(di, 0, dp));
            var r2 = new WidenRewriter(A0); float[] wp = new float[16], wi = new float[16]; r2.RewriteWindow(Po, wp, out _, out _);
            Check("逐窗口路径同样命中", true, r2.RewriteWindow(Ip, wi, out var ki, out _) && ki == WidenKind.InverseProjection && MathF.Abs(wi[0] - 39.2873f * K) < 1e-3f);
        }
        // 跨两个矩阵的窗口（前一矩阵末行 0001 + 投影前三行）不许被当成视图投影；真投影仍按 16 字节对齐命中
        {
            var r = new WidenRewriter(A0); var f = new List<float> { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }; f.AddRange(Proj());
            byte[] src = B(f.ToArray()); byte[] dst = new byte[src.Length];
            r.Rewrite(src, 0, dst);
            Check("跨矩阵窗口：视图投影命中 0", 0L, r.Stats.ViewProjection);
            Check("跨矩阵窗口：真投影命中 1", 1L, r.Stats.Projection);
            Check("跨矩阵窗口：第一个矩阵不动", 1f, Fl(dst)[0]);
        }
        // 视图投影：VP = P · V，V = 绕 y 轴转 30° + 平移 (1,2,3)
        {
            float c = MathF.Cos(MathF.PI / 6), s = MathF.Sin(MathF.PI / 6);
            float[] V = { c, 0, -s, 1, 0, 1, 0, 2, s, 0, c, 3, 0, 0, 0, 1 }, P = Proj(), VP = new float[16];
            for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) { float acc = 0; for (int k = 0; k < 4; k++) acc += P[i * 4 + k] * V[k * 4 + j]; VP[i * 4 + j] = acc; }
            var r = new WidenRewriter(A0); byte[] dst = new byte[64];
            Check("视图投影命中", true, r.Rewrite(B(VP), 0, dst));
            Check("计数 视图投影", 1L, r.Stats.ViewProjection);
            Check("视图投影 x 行第 0 个 = P00·cos30°/K", P00 * c / K, Fl(dst)[0]);
            Check("视图投影 x 行平移 = P00·1/K", P00 * 1 / K, Fl(dst)[3]);
        }
        // 带均匀缩放的世界·视图·投影 WVP = P·V·W，W = 平移 (5,0,-2) · 绕 y 轴转 50° · 均匀缩放 1.35（10-21 暗黑3 角色：|w 行| = 1.35，旧判据认不出、角色按 16:9 拉宽、偏离阴影）。
        // 期望按构造算：x 行 4 个元素都乘 1/K、其余行不动；与同一镜头的纯视图投影是同一个相机签名。
        // 带缩放的（|w| ≠ 1）靠已认出镜头的深度快筛放进来：先过一遍同镜头的纯视图投影（游戏里不缩放的静态物体先认出镜头）；没认过镜头时不改
        {
            float c = MathF.Cos(MathF.PI / 6), s = MathF.Sin(MathF.PI / 6), c5 = MathF.Cos(50 * MathF.PI / 180), s5 = MathF.Sin(50 * MathF.PI / 180), sc = 1.35f;
            float[] V = { c, 0, -s, 1, 0, 1, 0, 2, s, 0, c, 3, 0, 0, 0, 1 }, P = Proj();
            float[] W = { sc * c5, 0, -sc * s5, 5, 0, sc, 0, 0, sc * s5, 0, sc * c5, -2, 0, 0, 0, 1 };
            float[] Mul(float[] x, float[] y) { var o = new float[16]; for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) { float acc = 0; for (int k = 0; k < 4; k++) acc += x[i * 4 + k] * y[k * 4 + j]; o[i * 4 + j] = acc; } return o; }
            float[] VP = Mul(P, V), WVP = Mul(VP, W), T = new float[16];
            for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) T[j * 4 + i] = WVP[i * 4 + j];
            byte[] dst = new byte[64], dv0 = new byte[64];
            Check("没认过镜头：带缩放 1.35 的 WVP 不改", false, new WidenRewriter(A0).Rewrite(B(WVP), 0, dst));
            var r = new WidenRewriter(A0); r.Rewrite(B(VP), 0, dv0);
            Check("带缩放 1.35 的 WVP（行存）命中视图投影", true, r.Rewrite(B(WVP), 0, dst));
            bool xs = true, rest = true; float[] d = Fl(dst);
            for (int j = 0; j < 4; j++) xs &= MathF.Abs(d[j] - WVP[j] / K) <= 1e-6f * MathF.Max(1, MathF.Abs(WVP[j]));
            for (int j = 4; j < 16; j++) rest &= d[j] == WVP[j];
            Check("带缩放 WVP：x 行 4 个元素 = 原值 / K", true, xs);
            Check("带缩放 WVP：y / z / w 行不动", true, rest);
            byte[] dt = new byte[64];
            Check("带缩放 1.35 的 WVP（列存）命中", true, r.Rewrite(B(T), 0, dt));
            Check("带缩放 WVP 列存：[0] = 原值 / K", WVP[0] / K, Fl(dt)[0]);
            Check("纯 VP 与带缩放 WVP 同一相机签名（签名数 1）", 1, r.Cameras);
            var rw2 = new WidenRewriter(A0); float[] wd = new float[16], wv = new float[16]; rw2.RewriteWindow(VP, wv, out _, out _);
            Check("逐窗口路径（上传只扫变了的）同样命中", true, rw2.QuickWindow(WVP) && rw2.RewriteWindow(WVP, wd, out var kd, out _) && kd == WidenKind.ViewProjection);
            byte[] dn = new byte[64];
            Check("带缩放 1.35 的正交投影（w 行 0）不改", false, r.Rewrite(B(Mul(new float[] { 2f / 1920, 0, 0, -1, 0, 2f / 1080, 0, -1, 0, 0, 1, 0, 0, 0, 0, 1 }, W)), 0, dn));
            Check("带缩放 1.35 的 4:3 透视（深度参数同镜头）不改", false, r.Rewrite(B(Mul(Mul(new float[] { 1.81066f, 0, 0, 0, 0, 2.41421f, 0, 0, 0, 0, P[10], P[11], 0, 0, -1, 0 }, V), W)), 0, dn));
            Check("改写过的带缩放 WVP 再过一遍不再命中（幂等）", false, r.Rewrite(dst, 0, dn));
        }
        // 非均匀缩放的世界·视图·投影（10-21 暗黑3 点光源光照体：W 线性部分 = 转 50° · diag(36, 30, 41)，形状看不出 16:9）：同一镜头的视图投影先认过
        //（记下深度映射 z 行 = a·w 行 + b·e₄），之后按深度映射认出并改 x 行；换一个近 / 远平面不同的镜头（深度参数不同）不认；没认过镜头之前不认
        {
            float c = MathF.Cos(MathF.PI / 6), s = MathF.Sin(MathF.PI / 6), c5 = MathF.Cos(50 * MathF.PI / 180), s5 = MathF.Sin(50 * MathF.PI / 180);
            float[] V = { c, 0, -s, 1, 0, 1, 0, 2, s, 0, c, 3, 0, 0, 0, 1 }, P = Proj();
            float[] W = { 36 * c5, 0, -41 * s5, 120, 0, 30, 0, 4, 36 * s5, 0, 41 * c5, -250, 0, 0, 0, 1 };
            float[] Mul(float[] x, float[] y) { var o = new float[16]; for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) { float acc = 0; for (int k = 0; k < 4; k++) acc += x[i * 4 + k] * y[k * 4 + j]; o[i * 4 + j] = acc; } return o; }
            float[] VP = Mul(P, V), M = Mul(VP, W);
            float[] P2 = (float[])P.Clone(); P2[10] = -1.5f; P2[11] = -0.9f;   // 另一镜头：同视角、深度参数不同
            float[] M2 = Mul(Mul(P2, V), W);
            byte[] d0 = new byte[64];
            Check("没认过镜头：非均匀缩放 WVP 不改", false, new WidenRewriter(A0).Rewrite(B(M), 0, d0));
            var r = new WidenRewriter(A0); byte[] dv = new byte[64], dm = new byte[64], d2 = new byte[64];
            r.Rewrite(B(VP), 0, dv);
            Check("认过视图投影后：非均匀缩放 WVP 按深度映射命中", true, r.Rewrite(B(M), 0, dm));
            bool xs = true, rest = true; float[] d = Fl(dm);
            for (int j = 0; j < 4; j++) xs &= MathF.Abs(d[j] - M[j] / K) <= 1e-6f * MathF.Max(1, MathF.Abs(M[j]));
            for (int j = 4; j < 16; j++) rest &= d[j] == M[j];
            Check("按深度映射：x 行 = 原值 / K、其余行不动", true, xs && rest);
            Check("计数 按深度映射 1", 1L, r.Stats.ByDepth);
            Check("另一镜头（深度参数不同）的非均匀缩放 WVP 不改", false, r.Rewrite(B(M2), 0, d2));
            // 另一台镜头：近 / 远平面相同（深度映射相同）、视角不同（10-21 马车8 选车界面卡丁车预览）：带缩放的矩阵不改（C⁻¹·M 不是仿射）
            float[] P3 = (float[])P.Clone(); P3[0] *= 1.6f; P3[5] *= 1.6f;
            float[] V3 = { 1, 0, 0, -3, 0, c, -s, 1, 0, s, c, 7, 0, 0, 0, 1 };
            float[] Wu = { 1.35f * c5, 0, -1.35f * s5, 2, 0, 1.35f, 0, 0, 1.35f * s5, 0, 1.35f * c5, -5, 0, 0, 0, 1 };
            byte[] d3 = new byte[64];
            Check("另一台视角不同的镜头：非均匀缩放 WVP 不改", false, r.Rewrite(B(Mul(Mul(P3, V3), W)), 0, d3));
            Check("另一台视角不同的镜头：均匀缩放 1.35 的 WVP 不改", false, r.Rewrite(B(Mul(Mul(P3, V3), Wu)), 0, d3));
            Check("同一镜头换了位置 / 朝向（V3）后：非均匀缩放 WVP 仍认", true, r.Rewrite(B(Mul(Mul(P, V3), W)), 0, d3));
            // 稳态零分配：每轮先认视图投影（相机 C 更新、逆矩阵作废），再按深度映射认非均匀缩放矩阵（原地重求逆）
            byte[] bv = B(VP), bm = B(M), ov = new byte[64], om = new byte[64];
            for (int i = 0; i < 50; i++) { r.Rewrite(bv, 0, ov); r.Rewrite(bm, 0, om); }
            long g0 = GC.GetAllocatedBytesForCurrentThread();
            for (int i = 0; i < 1000; i++) { r.Rewrite(bv, 0, ov); r.Rewrite(bm, 0, om); }
            long g1 = GC.GetAllocatedBytesForCurrentThread();
            for (int i = 0; i < 3000; i++) { r.Rewrite(bv, 0, ov); r.Rewrite(bm, 0, om); }
            long g2 = GC.GetAllocatedBytesForCurrentThread();
            Check("深度映射路径稳态零分配（每轮认视图投影 + 认非均匀缩放矩阵；3000 轮窗口减 1000 轮窗口再 ÷2000）", 0L, ((g2 - g1) - (g1 - g0)) / 2000);
            float[] T = new float[16]; for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) T[j * 4 + i] = M[i * 4 + j];
            byte[] dt = new byte[64];
            Check("按深度映射：列存同样命中，[0] = 原值 / K", M[0] / K, r.Rewrite(B(T), 0, dt) ? Fl(dt)[0] : float.NaN);
            float[] wd = new float[16];
            Check("逐窗口路径（上传只扫变了的）同样按深度映射命中", true, r.QuickWindow(M) && r.RewriteWindow(M, wd, out var kd, out _) && kd == WidenKind.ViewProjection && MathF.Abs(wd[0] - M[0] / K) <= 1e-6f * MathF.Abs(M[0]));
        }
        // 无限远反向 Z 的镜头（10-22 暗黑2 人物界面，回放取的投影）：z 行 = (0, 0, 0, 0.1)，深度映射 a = 0、b = 0.1。场景绘制读的视图投影 M = P·V（列存上传）z 行 xyz 也是 0，
        // 形状判据（要 z 行 xyz 非零）和旧深度快筛（只收 a² > 0 的相机）都放不进来，整场景按 k 拉伸。期望按构造：先认出投影后，M 命中视图投影、x 行（列存每列第 0 个）= 原值 / K；没认过镜头不改
        {
            float c = MathF.Cos(MathF.PI / 6), sn = MathF.Sin(MathF.PI / 6);
            float[] Mul(float[] x, float[] y) { var o = new float[16]; for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) { float acc = 0; for (int k = 0; k < 4; k++) acc += x[i * 4 + k] * y[k * 4 + j]; o[i * 4 + j] = acc; } return o; }
            float[] Tr(float[] x) { var o = new float[16]; for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) o[j * 4 + i] = x[i * 4 + j]; return o; }
            float[] P = { 1.46536f, 0, 0, 0, 0, 2.60509f, 0, 0, 0, 0, 0, 0.1f, 0, 0, -1, 0 }, V = { c, 0, -sn, 1, 0, 1, 0, 2, sn, 0, c, 3, 0, 0, 0, 1 }, M = Mul(P, V);
            byte[] d0 = new byte[64], d1 = new byte[64];
            Check("没认过镜头：反向 Z 视图投影不改", false, new WidenRewriter(A0).Rewrite(B(Tr(M)), 0, d1));
            var r = new WidenRewriter(A0);
            Check("反向 Z 投影（列存）命中投影", true, r.Rewrite(B(Tr(P)), 0, d0) && r.Stats.Projection == 1);
            Check("同镜头反向 Z 视图投影（列存）命中", true, r.Rewrite(B(Tr(M)), 0, d1) && r.Stats.ViewProjection == 1);
            float[] o = Fl(d1); bool xs = true, rest = true; float[] t = Tr(M);
            for (int j = 0; j < 4; j++) xs &= MathF.Abs(o[j * 4] - M[j] / K) <= 1e-5f * MathF.Max(1, MathF.Abs(M[j]));
            for (int i = 0; i < 16; i++) if (i % 4 != 0) rest &= o[i] == t[i];
            Check("反向 Z 视图投影：x 行 = 原值 / K", true, xs);
            Check("反向 Z 视图投影：y / z / w 行不动", true, rest);
            var r2 = new WidenRewriter(A0); float[] wp = new float[16], wm = new float[16]; r2.RewriteWindow(Tr(P), wp, out _, out _);
            Check("逐窗口路径同样命中", true, r2.QuickWindow(Tr(M)) && r2.RewriteWindow(Tr(M), wm, out var kw, out _) && kw == WidenKind.ViewProjection && MathF.Abs(wm[0] - M[0] / K) <= 1e-5f);
        }
        // 逆投影：x 行乘 K
        {
            float[] inv = { 1 / P00, 0, 0, 0, 0, 1 / P11, 0, 0, 0, 0, 0, -1, 0, 0, -4.999f, 5.0f };
            var r = new WidenRewriter(A0); byte[] dst = new byte[64];
            Check("逆投影命中", true, r.Rewrite(B(inv), 0, dst));
            Check("逆投影 [0] = (1/P00)·K", K / P00, Fl(dst)[0]);
        }
        // 宽高比常量对、屏幕尺寸 vec4（两种顺序）
        {
            var r = new WidenRewriter(A0); byte[] dst = new byte[48];
            r.Rewrite(B(16f / 9f, 9f / 16f, 7, 7, 1920, 1080, 1f / 1920, 1f / 1080, 1f / 1280, 1f / 720, 1280, 720), 0, dst);
            float[] m = Fl(dst);
            Check("宽高比对 → 2346/1080", A, m[0]);
            Check("宽高比对 → 1080/2346", 1 / A, m[1]);
            Check("屏幕尺寸 (W,H,1/W,1/H) W → 2346", 2346f, m[4]);
            Check("屏幕尺寸 1/W → 1/2346", 1f / 2346, m[6]);
            Check("屏幕尺寸 H 不动", 1080f, m[5]);
            Check("屏幕尺寸 (1/W,1/H,W,H) 1280 → 1564", 1564f, m[10]);
            Check("屏幕尺寸 (1/W,1/H,W,H) 1/W → 1/1564", 1f / 1564, m[8]);
        }
        // 屏幕尺寸矩形写法 (0, 0, W, H)：计算着色器按它判线程越界（10-22 八方2 镇上 640×360 → 782×360，右 142 列没人写）；起点非 0 / 不是 16:9 一族不认
        {
            var r = new WidenRewriter(A0); byte[] dst = new byte[64];
            Check("矩形 (0,0,640,360) 命中", true, r.Rewrite(B(0, 0, 640, 360, 5, 0, 640, 360, 0, 0, 640, 480, 0, 0, 1280, 720), 0, dst));
            float[] m = Fl(dst);
            Check("矩形 (0,0,640,360)：宽 → 782、其余不动", "0 0 782 360", $"{m[0]} {m[1]} {m[2]} {m[3]}");
            Check("起点 (5,0) 的矩形不认", 640f, m[6]);
            Check("640×480（4:3）不是 16:9 一族不认", 640f, m[10]);
            Check("矩形 (0,0,1280,720) → 1564", 1564f, m[14]);
            float[] fw = new float[4];
            int len = r.RewriteFloats(new float[] { 0, 0, 640, 360 }, true, fw, out WidenKind kind);
            Check("逐单元判（只扫变了的）同样认矩形：16 字节、屏幕尺寸、宽 782", "16 ScreenSize 782", $"{len} {kind} {fw[2]}");
        }
        // 整数最大像素坐标矩形 (W−1, H−1, 0, 0)（10-23 八方2 时域抗锯齿按它夹紧整数取图 x，448 放宽成 548 后右侧 100 列都取第 447 列 → 拉丝）：
        // 期望手算：448×252 放宽宽 548（回放实测贴图 191 = 548×252）→ 547；后两格非 0 / 宽 − 1 < 127 / 不是 16:9 一族都不认。旧代码不认整数，四项命中类全红
        {
            float I(int v) => BitConverter.Int32BitsToSingle(v);
            var r = new WidenRewriter(A0); byte[] dst = new byte[64];
            Check("整数矩形 (447,251,0,0) 命中", true, r.Rewrite(B(I(447), I(251), I(0), I(0), I(447), I(251), I(1), I(0), I(99), I(55), I(0), I(0), I(447), I(447), I(0), I(0)), 0, dst));
            int[] iv = MemoryMarshal.Cast<byte, int>(dst.AsSpan()).ToArray();
            Check("整数矩形 (447,251,0,0)：x → 547、其余不动", "547 251 0 0", $"{iv[0]} {iv[1]} {iv[2]} {iv[3]}");
            Check("后两格非 0 的 (447,251,1,0) 不认", 447, iv[4]);
            Check("宽 − 1 < 127 的 (99,55,0,0) 不认", 99, iv[8]);
            Check("(447,447,0,0)（1:1）不是 16:9 一族不认", 447, iv[12]);
            float[] fw = new float[4];
            int len = r.RewriteFloats(new float[] { I(447), I(251), I(0), I(0) }, true, fw, out WidenKind kind);
            Check("逐单元判（只扫变了的）同样认整数矩形：16 字节、屏幕尺寸、x 547", "16 ScreenSize 547", $"{len} {kind} {BitConverter.SingleToInt32Bits(fw[0])}");
        }
        // 相机系数对：先认出投影（签名 P00=1.3579951、P11=2.4142136），再在别处认 (1/P00, 1/P11) 与 (P00, P11)
        {
            var r = new WidenRewriter(A0); byte[] d0 = new byte[64];
            byte[] pair = B(1 / P00, 1 / P11, 0, 0, P00, -P11, 0, 0, 0.946f * (1 / P00) / 0.94527f * 0.94527f + 0.0008f, 1 / P11, 0, 0);
            byte[] dst = new byte[pair.Length];
            Check("没见过相机时系数对不改", false, r.Rewrite(pair, 0, dst));
            r.Rewrite(B(Proj()), 0, d0);
            Check("认出投影后记 1 个相机签名", 1, r.Cameras);
            Check("认出投影后系数对命中", true, r.Rewrite(pair, 0, dst));
            float[] m = Fl(dst);
            Check("(1/P00) → K/P00", K / P00, m[0]);
            Check("(1/P11) 不动", 1 / P11, m[1]);
            Check("(P00, −P11) → P00/K（P11 符号不计）", P00 / K, m[4]);
            Check("差 0.08% 的近似对不改（容差 2e-4）", 0.946f * (1 / P00) / 0.94527f * 0.94527f + 0.0008f, m[8]);
            Check("计数 相机系数对", 2L, r.Stats.CameraPair);
        }
        // 屏幕尺寸先于相机系数对（10-23 暗黑2 火光漂移）：错位窗口把界面正交（2/1280、2/720）认成列存视图投影，登记出像素尺度的「镜头」(1/640, 1/360)；
        // 之后半分辨率屏幕尺寸 (640, 360, 1/640, 1/360) 要认成屏幕尺寸（读片元坐标的程序才写回原值），不是两个相机系数对
        {
            var r = new WidenRewriter(A0); byte[] d0 = new byte[64];
            r.Rewrite(B(6.8159e-42f, 0, 8638.6f, 1, -0.0015625f, 0, 0, 0, 0, 0.0027778f, 0, 0, 0, 0, 0.0001f, 0), 0, d0);
            Check("错位窗口登记出像素尺度镜头（本例前提）", 1, r.Cameras);
            byte[] dst = new byte[16]; var sink = new HitList1023();
            Check("半分辨率屏幕尺寸命中", true, r.Rewrite(B(640, 360, 1f / 640, 1f / 360), 0, dst, sink));
            Check("认成屏幕尺寸一条 16 字节，不是相机系数对", "ScreenSize 16", string.Join(";", sink.Hits));
            Check("计数：屏幕尺寸 1、相机系数对 0", "1 0", $"{r.Stats.ScreenSize} {r.Stats.CameraPair}");
            Check("宽 → 782、1/宽 → 1/782、高不动", $"782 360 {1f / 782} {1f / 360}", string.Join(" ", Fl(dst)));
            float[] fw = new float[4];
            int len = r.RewriteFloats(new float[] { 640, 360, 1f / 640, 1f / 360 }, true, fw, out WidenKind kind);
            Check("逐单元判（只扫变了的）同样认屏幕尺寸", "16 ScreenSize 782", $"{len} {kind} {fw[0]}");
        }
        // 签名表满时淘汰最久没见到的（10-23 暗黑2 营地：一批新签名按先进先出挤掉每帧都在用的世界镜头，那一帧火光按拉伸画）
        {
            var r = new WidenRewriter(A0); byte[] d0 = new byte[64];
            float[] ProjF(float p11) => new[] { p11 * 9f / 16f, 0, 0, 0, 0, p11, 0, 0, 0, 0, -1.0002f, -0.20002f, 0, 0, -1, 0 };
            r.Rewrite(B(Proj()), 0, d0);                                                   // 主镜头 A
            for (int i = 0; i < 7; i++) r.Rewrite(B(ProjF(1.5f + 0.1f * i)), 0, d0);         // 7 台别的镜头，表满
            Check("签名表满 8 格", 8, r.Cameras);
            r.Rewrite(B(Proj()), 0, d0);                                                   // A 又出现（刷新）
            r.Rewrite(B(ProjF(2.3f)), 0, d0);                                              // 第 8 台新镜头：按先进先出会挤掉 A
            byte[] pair = B(1 / P00, 1 / P11, 0, 0), dst = new byte[pair.Length];
            Check("刚见过的主镜头没被挤掉：它的相机系数对照样认出", true, r.Rewrite(pair, 0, dst));
            byte[] pair1 = B(1 / (1.5f * 9f / 16f), 1 / 1.5f, 0, 0), dst1 = new byte[pair1.Length];
            Check("最久没见到的（第一台别的镜头）被挤掉：系数对不再认", false, r.Rewrite(pair1, 0, dst1));
        }
        // 缓冲内偏移：数据从缓冲偏移 8 开始，矩阵在缓冲偏移 16（数据内偏移 8）
        {
            var f = new List<float> { 9, 9 }; f.AddRange(Proj());
            var r = new WidenRewriter(A0); byte[] src = B(f.ToArray()); byte[] dst = new byte[src.Length];
            Check("按缓冲内 16 字节对齐找矩阵（数据偏移 8）", true, r.Rewrite(src, 8, dst));
            Check("对齐后 P00 在数据第 2 个 float", P00 / K, Fl(dst)[2]);
            Check("按数据起点对齐会错位（缓冲偏移 0 时不命中）", false, new WidenRewriter(A0).Rewrite(src, 0, dst));
        }

        // ---------- 界面正交投影（像素空间画布）：认 / 不认 ----------
        {
            Check("暗黑2 界面层投影（列存，x −2/1280、y 2/720、y 平移 −2）认", true, WidenRewriter.IsUiOrtho(new float[] { -0.0015625f, 0, 0, 0, 0, 0.0027778f, 0, 0, 0, 0, 0.0001f, 0, 0, -2, -1e-5f, 1 }, out _));
            Check("1024×1024 画布（非 16:9）不认", false, WidenRewriter.IsUiOrtho(new float[] { 2f / 1024, 0, 0, -1, 0, 2f / 1024, 0, -1, 0, 0, 1, 0, 0, 0, 0, 1 }, out _));
            Check("世界正交投影（2/P00 = 78.6 世界单位，不是整数像素）不认", false, WidenRewriter.IsUiOrtho(new float[] { 0.025454f, 0, 0, 0, 0, 0.045251f, 0, 0, 0, 0, 0.0001001f, 1.001f, 0, 0, 0, 1 }, out _));
            Check("带旋转的不认", false, WidenRewriter.IsUiOrtho(new float[] { 0.001f, 0.001f, 0, -1, 0, 2f / 720, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1 }, out _));
        }
        // 界面层目标（不是 T_out，单独一张、最后合成：10-21 暗黑2）：读界面正交、没读改写矩阵、没绑放宽贴图 → 原尺寸居中；绑了放宽贴图（整屏后处理）→ 照旧按 k
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            fr.OnCreateTexture(4, 1280, 720); fr.OnCreateTexture(9, 1280, 720);
            byte[] dst = new byte[64];
            fr.OnBufferData(7, 0, B(Proj()), dst);   // 3D 款：已出现场景镜头（纯 2D 款的像素正交另按场景改写，见改写器用例）
            fr.OnBufferData(8, 0, B(2f / 1280, 0, 0, -1, 0, -2f / 720, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1), dst);
            var use = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) use.Add(i);
            CbufRead[] ru = { new(8, 0, 256, use) };
            fr.OnRenderTargets(4, 0); fr.OnFragmentTexture(128, 0);
            Check("界面层目标读界面正交 → 原尺寸居中", ViewportMode.CenterNative, fr.OnDraw(ru, pat, out var cu));
            Check("界面层目标读界面正交 → 记为界面层", DrawClass.Hud, cu);
            float x = 0, w = 1280; fr.MapViewport(ViewportMode.CenterNative, ref x, ref w);
            Check("居中视口 x = (1564−1280)/2 = 142、宽不变", "142/1280", $"{x}/{w}");
            fr.OnFragmentTexture(128, 9);
            Check("采样放宽贴图（整屏后处理）→ 照旧按 k", ViewportMode.ScaleK, fr.OnDraw(ru, pat, out _));
        }
        // 片元槽位表只扫用到的上界（11-02 _fragHi，满屏线审）：高槽位 200 先采样放宽贴图、下一笔清零、再换低槽位采样——判定与整扫 256 格一致，
        // 上界不回落也不漏判。期望按定义：采样了放宽贴图 → ScaleK；没采样 → 界面层原尺寸居中
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            fr.OnCreateTexture(4, 1280, 720); fr.OnCreateTexture(9, 1280, 720);
            byte[] dst = new byte[64];
            fr.OnBufferData(7, 0, B(Proj()), dst);
            fr.OnBufferData(8, 0, B(2f / 1280, 0, 0, -1, 0, -2f / 720, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1), dst);
            var use = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) use.Add(i);
            CbufRead[] ru = { new(8, 0, 256, use) };
            fr.OnRenderTargets(4, 0);
            fr.OnFragmentTexture(200, 9);
            Check("槽位上界：槽 200 采样放宽贴图 → 照旧按 k", ViewportMode.ScaleK, fr.OnDraw(ru, pat, out _));
            fr.OnFragmentTexture(200, 0);
            Check("槽位上界：槽 200 清零后没采样放宽贴图 → 原尺寸居中（不残留）", ViewportMode.CenterNative, fr.OnDraw(ru, pat, out _));
            fr.OnFragmentTexture(3, 9);
            Check("槽位上界：换低槽 3 采样放宽贴图 → 照旧按 k（上界不回落、不漏判）", ViewportMode.ScaleK, fr.OnDraw(ru, pat, out _));
            fr.OnFragmentTexture(3, 0); fr.OnFragmentTexture(255, 9);
            Check("槽位上界：最高槽 255 采样放宽贴图 → 照旧按 k", ViewportMode.ScaleK, fr.OnDraw(ru, pat, out _));
        }
        // 同上，经会话：页来源在第 201 张（槽 200）也沿合成链传播；下一笔只采 1 张放宽的非页目标（槽 200 被会话清零）时不当页来源（残留会误标）
        {
            var s = new WidenSession(2346, 1080, false, true, false);
            s.Texture(100, 1280, 720, 1, 0);
            s.Texture(1655, 1280, 720, 1, WidenSession.UseRt);
            s.Texture(1657, 1280, 720, 1, WidenSession.UseRt);
            s.Texture(1659, 1280, 720, 1, WidenSession.UseRt);
            s.Texture(1661, 1280, 720, 1, WidenSession.UseRt);   // 放宽了、但从没当过页的渲染目标
            nint ptr = Pinned(768, out byte[] ga, out int gat);
            B(Proj()).CopyTo(ga, gat);
            int hp = s.Shader("0:0,1,2,3", false);
            int[] sp = { hp, 0, 0, 0, 0, 0 };
            Span<float> push = stackalloc float[4];
            s.Targets(1655, 0); s.CbufBind(0, 0, ptr, 768);
            Check("槽位上界·会话：页笔画法 Page", ViewportMode.Page, s.Draw(0, 1280, 720, 1, sp, WidenSession.DrawColor, new[] { new WidenSession.Tex { Id = 100, W = 1280, H = 720, Scale = 1 } }, push, out _));
            s.CbufBind(0, 0, 0, 0); s.Targets(1657, 0);
            var hi = new WidenSession.Tex[201]; hi[200] = new WidenSession.Tex { Id = 1655, W = 1280, H = 720, Scale = 1 };
            Check("槽位上界·会话：槽 200 采页目标的合成画法 ScaleK", ViewportMode.ScaleK, s.Draw(0, 1564, 720, 1, sp, WidenSession.DrawColor, hi, push, out _));
            Check("槽位上界·会话：槽 200 采页目标 → 中间目标 1657 标为页来源", true, s.Frame.IsPageSource(1657));
            s.Targets(1659, 0);
            Check("槽位上界·会话：只采 1 张放宽的非页目标的合成画法 ScaleK", ViewportMode.ScaleK, s.Draw(0, 1564, 720, 1, sp, WidenSession.DrawColor, new[] { new WidenSession.Tex { Id = 1661, W = 1280, H = 720, Scale = 1 } }, push, out _));
            Check("槽位上界·会话：槽 200 已被会话清零 → 1659 不标页来源", false, s.Frame.IsPageSource(1659));
        }
        // 绑定区间之外伸进来的矩阵不算这次绘制读到的（10-21 暗黑2 HUD 帧级跳：流式常量缓冲里场景透视投影紧挨在界面那块之前、尾 16 字节伸进界面绑定，
        // 界面着色器按动态下标整段读 → 旧判据算「读到放宽矩阵」→ Hor 拉宽）。期望按定义：投影 [208,272) 不整个在绑定 [256,512) 里 → 不算；界面正交 [272,336) 整个在 → 原尺寸居中
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            fr.OnCreateTexture(4, 1280, 720);
            var lay = new byte[512]; B(Proj()).CopyTo(lay, 208); B(2f / 1280, 0, 0, -1, 0, -2f / 720, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1).CopyTo(lay, 272);
            fr.OnBufferData(8, 0, lay, new byte[512]);
            var dyn = new CbufUse { Binding = 4, Dynamic = true };
            CbufRead[] rd = { new(8, 256, 256, dyn) };
            fr.OnRenderTargets(4, 0); fr.OnFragmentTexture(128, 0);
            Check("前一块的投影尾巴伸进界面绑定（动态整段读）：不算读到放宽矩阵", false, fr.ReadsRewritten(8, 256, 256, dyn));
            Check("同上：界面层仍原尺寸居中（不按 Hor 拉宽）", ViewportMode.CenterNative, fr.OnDraw(rd, pat, out _));
            Check("投影整个在绑定里时照算读到（正对照，经一次真实绘制：先改回改写值再判）", ViewportMode.Hor, fr.OnDraw(new CbufRead[] { new(8, 192, 320, dyn) }, pat, out _));
        }

        // 命中跨在绑定边界上、只读到一截（10-22 暗黑2 场景闪烁：残留相机列 + 新材质块凑成「正交 × 视图」，材质块绑定只盖住末 16 字节）：放宽目标上也写回原值；
        // 之后有绑定整块读它的绘制再改回改写值。期望按定义：投影 [0,64) 改写后 [0] = P00/K，原值 P00
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            fr.OnCreateTexture(2, 1920, 1080);
            byte[] dst = new byte[64];
            Check("投影上传即改：[0] = P00/K", P00 / K, fr.OnBufferData(7, 0, B(Proj()), dst) ? Fl(dst)[0] : float.NaN);
            var u0 = new CbufUse { Binding = 4 }; u0.Add(0);
            var u4 = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) u4.Add(i);
            fr.OnRenderTargets(2, 0);
            pat.W.Clear(); fr.OnDraw(new CbufRead[] { new(7, 48, 256, u0) }, pat, out _);
            Check("绑定从 48 起、只读到投影末 16 字节：写回原值（偏移 0、[0] = P00）", $"0 {P00}", pat.W.Count == 1 ? $"{pat.W[0].Item2} {pat.W[0].Item3[0]}" : $"写了 {pat.W.Count} 次");
            pat.W.Clear(); fr.OnDraw(new CbufRead[] { new(7, 0, 256, u4) }, pat, out _);
            Check("之后整块读投影的绘制：改回改写值（[0] = P00/K）", P00 / K, pat.W.Count == 1 ? pat.W[0].Item3[0] : float.NaN);
            pat.W.Clear(); fr.OnDraw(new CbufRead[] { new(7, 0, 256, u4), new(7, 48, 256, u0) }, pat, out _);
            Check("同一次绘制另有绑定整块读它：不写回（0 次写）", 0, pat.W.Count);
        }
        // 缓冲间拷贝搬命中（10-22 暗黑2 云层 / 火焰 / 叹号隔帧横抖：Ryujinx 用拷贝搬常量的那几帧，搬过去的改写值没了命中记录，读它的绘制按 ScaleK 画、也不补回）。
        // 期望按定义：缓冲 7 的投影 [0,64) 拷到缓冲 9 的 [256,320) → 读缓冲 9 整块算读到改写矩阵；源上暂时写回原值的拷过去也记着，之后整块读它的绘制把缓冲 9 补回改写值（[0] = P00/K）
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            byte[] dst = new byte[64]; fr.OnBufferData(7, 0, B(Proj()), dst);
            var u4 = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) u4.Add(i);
            fr.OnCopyBuffer(7, 9, 0, 256, 64);
            Check("拷贝后目标缓冲整块读算读到改写矩阵", true, fr.ReadsRewritten(9, 256, 64, u4));
            var f2 = new WidenFrame(new WidenRewriter(A0)); f2.OnBufferData(7, 0, B(Proj()), dst);
            f2.OnDispatch(new CbufRead[] { new(7, 0, 256, u4) }, pat, true);
            f2.OnCopyBuffer(7, 9, 0, 256, 64);
            pat.W.Clear(); f2.OnDispatch(new CbufRead[] { new(9, 256, 64, u4) }, pat, false);
            var w9 = pat.W.FindAll(x => x.Item1 == 9);   // 源缓冲 7 上的那份同样补回（待补回表里两份都在），这里只看目标
            Check("源上写回原值后拷过去：之后整块读目标的派发把缓冲 9 [256] 补回改写值 P00/K", $"256 {P00 / K}", w9.Count == 1 ? $"{w9[0].Item2} {w9[0].Item3[0]}" : $"缓冲 9 写了 {w9.Count} 次");
            fr.OnCopyBuffer(7, 9, 32, 256, 64);
            Check("只拷了一截（跨拷贝边界）的命中不搬", false, fr.ReadsRewritten(9, 256, 64, u4));
        }
        // 影子跟着拷（10-22 暗黑2 第 10 帧：缓冲迁移后从矩阵中间起部分上传，跨上传起点的投影命中丢了、前几粒影子未知重判不了）。
        // 期望按定义：两段都绑过（有影子页），拷贝后对目标只重传投影末行（内容没变）→ 命中还在、整块读仍算读到改写矩阵
        {
            var fr = new WidenFrame(new WidenRewriter(A0));
            fr.OnUniformBound(7, 0, 256); fr.OnUniformBound(9, 256, 256);
            byte[] dst = new byte[256]; float[] p = Proj(); fr.OnBufferData(7, 0, B(p), dst);
            fr.OnBufferData(7, 0, B(p), dst);   // 第一次上传认出新相机签名 → 影子全部作废（设计如此）；再传一次影子才是已知的（真机签名早就稳定）
            fr.OnCopyBuffer(7, 9, 0, 256, 128);
            var u4 = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) u4.Add(i);
            fr.OnBufferData(9, 304, B(p[12], p[13], p[14], p[15]), dst);
            Check("拷贝后只重传投影末行（没变）：命中还在、整块读算读到改写矩阵", true, fr.ReadsRewritten(9, 256, 64, u4));
        }
        // 缓冲迁移整页搬影子（10-23 M4 暗黑2 大帧分配）：源绑过两页 [0, 8192)、目标没绑过，0 → 8192 整段拷 8192 字节（页内同余、整页覆盖）
        // 期望按定义：影子总字节不变（页从源挂到目标、不建新页）、搬了 2 页；目标只重传投影末行（没变）→ 命中还在。
        // 反例：源 / 目标页内不同余（偏移差 16）照旧逐粒拷、目标建新页——影子总字节多 1 页以上
        {
            var fr = new WidenFrame(new WidenRewriter(A0));
            fr.OnUniformBound(7, 0, 8192);
            byte[] dst = new byte[64]; float[] p = Proj(); fr.OnBufferData(7, 4096, B(p), dst); fr.OnBufferData(7, 4096, B(p), dst);
            long b0 = fr.Shadow.Bytes;
            fr.OnCopyBuffer(7, 9, 0, 8192, 8192);
            Check("页内同余整页拷：影子总字节不变（页搬过去、不建新页）、搬 2 页", $"{b0} 2", $"{fr.Shadow.Bytes} {fr.Shadow.PagesMoved}");
            var u4 = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) u4.Add(i);
            fr.OnBufferData(9, 8192 + 4096 + 48, B(p[12], p[13], p[14], p[15]), dst);
            Check("整页搬后只重传投影末行（没变）：命中还在、整块读算读到改写矩阵", true, fr.ReadsRewritten(9, 8192 + 4096, 64, u4));
            var f2 = new WidenFrame(new WidenRewriter(A0));
            f2.OnUniformBound(7, 0, 8192); f2.OnBufferData(7, 4096, B(p), dst); f2.OnBufferData(7, 4096, B(p), dst);
            long c0 = f2.Shadow.Bytes;
            f2.OnCopyBuffer(7, 9, 0, 8192 + 16, 8192 - 16);
            Check("反例：页内不同余（差 16）逐粒拷、目标建新页（影子总字节多 ≥ 1 页）、不搬", true, f2.Shadow.Bytes >= c0 + 4096 && f2.Shadow.PagesMoved == 0);
        }
        // 缓冲迁移整张交命中表（10-23 M4 暗黑2：迁移时 602–1600 个命中逐个插进新缓冲空表、表按倍数长）：0 → 0 整段拷、目标没命中 → 表整张交给目标。
        // 期望按定义：目标整块读算读到改写矩阵、交表 1 次；偏移不为 0（拷到 256）走逐个插入、不交表
        {
            var fr = new WidenFrame(new WidenRewriter(A0));
            byte[] dst = new byte[64]; fr.OnBufferData(7, 0, B(Proj()), dst);
            var u4 = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) u4.Add(i);
            fr.OnCopyBuffer(7, 9, 0, 0, 4096);
            Check("迁移 0 → 0：目标整块读算读到改写矩阵、命中表整张交 1 次", "True 1", $"{fr.ReadsRewritten(9, 0, 64, u4)} {fr.Shadow.HitListsMoved}");
            var f2 = new WidenFrame(new WidenRewriter(A0)); f2.OnBufferData(7, 0, B(Proj()), dst);
            f2.OnCopyBuffer(7, 9, 0, 256, 4096);
            Check("拷到偏移 256：逐个插入（不交表）、目标 [256] 整块读算读到改写矩阵", "True 0", $"{f2.ReadsRewritten(9, 256, 64, u4)} {f2.Shadow.HitListsMoved}");
        }
        // 跨两次上传的矩阵（10-22 暗黑2 第 10 帧：投影前三行传进缓冲 895、迁到 1796、末行从 c[16] 起再传）：期望按定义——认出、登记成暂时写回原值（这次发出去的是原值），
        // 之后整块读它的放宽绘制补回改写值 64 字节（[0] = P00/K）、按读到改写矩阵画（Hor）；不迁移、同一缓冲分两次传同样认
        // 倒序分块（10-22 暗黑2 第 9 帧：4 KB 一块，先传后一块 [1331200, …) 再传前一块，投影 c[13..16] 跨 1331200）：先传末行、再传前三行，期望同上
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            fr.OnCreateTexture(2, 1920, 1080); fr.OnRenderTargets(2, 0);
            float[] p = Proj(); byte[] pb = B(p), dst = new byte[64];
            fr.OnBufferData(5, 0, pb, dst); fr.OnBufferData(5, 0, pb, dst);
            fr.OnBufferData(9, 304, pb.AsSpan(48, 16), dst);
            bool sent = fr.OnBufferData(9, 256, pb.AsSpan(0, 48), dst);
            var u4 = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) u4.Add(i);
            pat.W.Clear(); var m = fr.OnDraw(new CbufRead[] { new(9, 256, 64, u4) }, pat, out _);
            var w9 = pat.W.FindAll(x => x.Item1 == 9 && x.Item2 == 256 && x.Item3.Length == 16);
            Check("倒序分块上传的投影：前三行上传发原值、之后整块读的放宽绘制补回改写值 [0] = P00/K、按 Hor 画", $"False {P00 / K} Hor", $"{sent} {(w9.Count == 1 ? w9[0].Item3[0] : float.NaN)} {m}");
        }
        foreach (bool mig in new[] { false, true })
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            fr.OnCreateTexture(2, 1920, 1080); fr.OnRenderTargets(2, 0);
            float[] p = Proj(); byte[] pb = B(p), dst = new byte[64];
            fr.OnBufferData(5, 0, pb, dst); fr.OnBufferData(5, 0, pb, dst);   // 先认出镜头签名（第一次认出会作废影子）
            ulong a1 = mig ? 7UL : 9UL;
            fr.OnBufferData(a1, 256, pb.AsSpan(0, 48), dst);
            if (mig) fr.OnCopyBuffer(7, 9, 0, 0, 1024);
            bool sent = fr.OnBufferData(9, 304, pb.AsSpan(48, 16), dst);
            var u4 = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) u4.Add(i);
            pat.W.Clear(); var m = fr.OnDraw(new CbufRead[] { new(9, 256, 64, u4) }, pat, out _);
            var w9 = pat.W.FindAll(x => x.Item1 == 9 && x.Item2 == 256 && x.Item3.Length == 16);
            Check($"跨两次上传的投影{(mig ? "（中间缓冲迁移）" : "")}：末行上传发原值、之后整块读的放宽绘制补回改写值 [0] = P00/K、按 Hor 画", $"False {P00 / K} Hor", $"{sent} {(w9.Count == 1 ? w9[0].Item3[0] : float.NaN)} {m}");
        }
        // 计算派发（10-22 暗黑2 调色 LUT）：只写没放宽的图像 = 同画到没放宽的目标，整块读的命中也写回原值；写放宽图像的整块读用改写值、只读一截的写回原值
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            byte[] dst = new byte[64]; fr.OnBufferData(7, 0, B(Proj()), dst);
            var u4 = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) u4.Add(i);
            var u0 = new CbufUse { Binding = 4 }; u0.Add(0);
            pat.W.Clear(); fr.OnDispatch(new CbufRead[] { new(7, 0, 256, u4) }, pat, true);
            Check("只写没放宽图像的派发整块读投影：写回原值（[0] = P00）", P00, pat.W.Count == 1 ? pat.W[0].Item3[0] : float.NaN);
            pat.W.Clear(); fr.OnDispatch(new CbufRead[] { new(7, 0, 256, u4) }, pat, false);
            Check("写放宽图像的派发整块读投影：改回改写值（[0] = P00/K）", P00 / K, pat.W.Count == 1 ? pat.W[0].Item3[0] : float.NaN);
            pat.W.Clear(); fr.OnDispatch(new CbufRead[] { new(7, 48, 256, u0) }, pat, false);
            Check("写放宽图像的派发只读到投影末 16 字节：写回原值（[0] = P00）", P00, pat.W.Count == 1 ? pat.W[0].Item3[0] : float.NaN);
        }
        // 只读改写动过的那个 vec4（10-22 暗黑2 人物界面光照剔除只读逆投影 c[17].x）：命中整个在绑定里、改动过的 vec4 都读到 → 用改写值。
        // 行存投影改写只动 x 行（vec4 0）。期望按定义：只读 vec4 0 的派发不写回（0 次写，GPU 上留 P00/K）；只读 vec4 1（没改动的）照旧写回原值
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            byte[] dst = new byte[64]; fr.OnBufferData(7, 0, B(Proj()), dst);
            var u0 = new CbufUse { Binding = 4 }; u0.Add(0);
            var u1 = new CbufUse { Binding = 4 }; u1.Add(1);
            pat.W.Clear(); fr.OnDispatch(new CbufRead[] { new(7, 0, 256, u0) }, pat, false);
            Check("派发只读投影 vec4 0（改动过的 x 行）：用改写值、不写回（0 次写）", 0, pat.W.Count);
            pat.W.Clear(); fr.OnDispatch(new CbufRead[] { new(7, 0, 256, u1) }, pat, false);
            Check("派发只读投影 vec4 1（没改动）：写回原值（[0] = P00）", P00, pat.W.Count == 1 ? pat.W[0].Item3[0] : float.NaN);
            pat.W.Clear(); fr.OnDispatch(new CbufRead[] { new(7, 0, 256, u0) }, pat, false);
            Check("之后只读 vec4 0 的派发：改回改写值（[0] = P00/K）", P00 / K, pat.W.Count == 1 ? pat.W[0].Item3[0] : float.NaN);
        }

        // ---------- WidenFrame：界面层规则 A、写回原值、视口换算 ----------
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            Check("建 1920×1080 输出贴图 2 → 2346", 2346, fr.OnCreateTexture(2, 1920, 1080));
            fr.OnCreateTexture(13, 1920, 1080); fr.OnCreateTexture(50, 600, 300);
            // 缓冲 7：偏移 0 放界面投影
            byte[] dst = new byte[64];
            fr.OnBufferData(7, 0, B(Proj()), dst);
            var proj = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) proj.Add(i);
            var other = new CbufUse { Binding = 4 }; other.Add(20);
            CbufRead[] rp = { new(7, 0, 768, proj) }, ro = { new(7, 0, 768, other) };
            // 第 1 帧：最后一次画到上屏贴图 13、采样 2 → 下帧 T_out = 2
            fr.OnRenderTargets(13, 0); fr.OnFragmentTexture(128, 2); fr.OnDraw(ro, pat, out _); fr.OnPresent(13);
            Check("T_out = 上屏前最后绘制采样的放宽贴图", 2u, fr.OutTexture);
            fr.OnRenderTargets(2, 0);
            var m1 = fr.OnDraw(ro, pat, out var c1);
            Check("本帧第一次画 T_out = 全屏合成", DrawClass.FirstToOut, c1);
            Check("全屏合成视口按 k", ViewportMode.ScaleK, m1);
            fr.DrawSamplesWide = false;   // 界面层采样的是界面图集（包装层按本笔实际采样填）
            var m2 = fr.OnDraw(ro, pat, out var c2);
            Check("第二次画 T_out = 界面层", DrawClass.Hud, c2);
            Check("界面层没读改写矩阵 → 原宽居中", ViewportMode.CenterNative, m2);
            Check("界面层读了改写投影 → Hor（中心平移 + 宽度乘 k，与投影 1/K 抵消）", ViewportMode.Hor, fr.OnDraw(rp, pat, out _));
            // 10-25 数码宝贝：第一次合成之后又一道全屏后处理（采样放宽贴图 = 读的是场景画面）→ 按 k 铺满，不当界面层居中
            fr.DrawSamplesWide = true;
            var mPost = fr.OnDraw(ro, pat, out var cPost);
            Check("T_out 上第二道全屏后处理（采样放宽贴图）→ 场景、按 k 铺满", "Scene ScaleK", $"{cPost} {mPost}");
            fr.DrawSamplesWide = null;
            float x = 0, w = 1920; fr.MapViewport(ViewportMode.CenterNative, ref x, ref w);
            Check("居中视口 x = (2346−1920)/2 整数", 213f, x);
            Check("居中视口宽不变", 1920f, w);
            x = 0; w = 1920; fr.MapViewport(ViewportMode.ScaleK, ref x, ref w);
            Check("按 k 视口宽 = 2346", 2346f, w);
            x = 0; w = 1920; fr.MapViewport(ViewportMode.Hor, ref x, ref w);
            Check("Hor 全屏视口 x = 0", 0f, x);
            Check("Hor 全屏视口宽 = 2346", 2346f, w);
            x = 1600; w = 200; fr.MapViewport(ViewportMode.Hor, ref x, ref w);
            Check("Hor 子视口宽 = 200·2346/1920", 244.375f, w);
            Check("Hor 子视口中心 = 1700 + 213 → x = 1913 − 122.1875", 1790.8125f, x);
            int hx = 0, hw = 1920; fr.MapScissor(ViewportMode.Hor, ref hx, ref hw);
            Check("Hor 全宽裁剪铺满 2346", 2346, hw);
            hx = 1600; hw = 200; fr.MapScissor(ViewportMode.Hor, ref hx, ref hw);
            Check("Hor 子裁剪平移 1600 + 213", 1813, hx);
            Check("Hor 子裁剪宽不变", 200, hw);
            int sx = 100, sw = 200; fr.MapScissor(ViewportMode.ScaleK, ref sx, ref sw);
            Check("裁剪 x = floor(100·2346/1920)", 122, sx);
            Check("裁剪宽 = ceil(300·2346/1920) − 122", 367 - 122, sw);
            // 非放宽目标（600×300 离屏界面）读到改写投影 → 写回原值；同通道第二次不重复；回到放宽目标再写改写值
            fr.OnRenderTargets(50, 0);
            fr.OnDraw(rp, pat, out var c3); fr.OnDraw(rp, pat, out _);
            Check("非放宽目标类别", DrawClass.NotWide, c3);
            Check("写回原值 1 次（同通道不重复）", 1, pat.W.Count);
            Check("写回的是原 P00", P00, pat.W[0].Item3[0]);
            fr.OnDraw(ro, pat, out _);
            Check("读不到改写区间的绘制不写回", 1, pat.W.Count);
            fr.OnRenderTargets(2, 0); fr.OnDraw(ro, pat, out _);
            Check("回到放宽目标写回改写值", 2, pat.W.Count);
            Check("写回的是改写后 P00", P00 / K, pat.W[1].Item3[0]);
            Check("缓冲同区间新写入后旧改写作废（不再算读到）", false, ((Func<bool>)(() => { fr.OnBufferData(7, 0, new byte[64], new byte[64]); return fr.ReadsRewritten(7, 0, 768, proj); }))());
        }

        // ---------- Hor 视口宽乘投影的 K，不乘目标实际放宽比（10-22 八方2 动态分辨率 896 → 1094：比 1.22098 ≠ K 1.221875，中间区边缘错 0.33 像素）----------
        {
            var fr = new WidenFrame(new WidenRewriter(A0));
            Check("896×504 放宽宽 1094（整数宽，比 ≠ K）", 1094, fr.OnCreateTexture(2, 896, 504));
            fr.OnRenderTargets(2, 0);
            float x = 0, w = 896; fr.MapViewport(ViewportMode.Hor, ref x, ref w);
            Check("Hor 视口 = 中心 448+99、宽 896·K：x −0.4、宽 1094.8", "-0.4 1094.8", $"{x:F1} {w:F1}");
            // 客体 ndc → 放宽像素：中心 + ndc/K·(宽/2) 应等于 99 + (ndc+1)·448（与 k=1 逐点平移 pad）
            float err = 0; foreach (float ndc in new[] { -1f, -0.5f, 0.5f, 1f }) err = MathF.Max(err, MathF.Abs(x + w * 0.5f + ndc / K * w * 0.5f - (99 + (ndc + 1) * 448)));
            Check("中间区与 k=1 逐点对齐（误差 < 0.01 像素；旧做法边缘 0.33）", true, err < 0.01f);
            x = 0; w = 896; fr.MapViewport(ViewportMode.ScaleK, ref x, ref w);
            Check("ScaleK 仍按目标铺满 0..1094", "0.0 1094.0", $"{x:F1} {w:F1}");
        }
        // ---------- SPIR-V 读取分析（手拼最小模块） ----------
        {
            // 编号：%1 int 类型、%2 常量 0、%3 常量 33、%4 Uniform 变量（绑定 4）、%5 指针类型、%6 动态下标、%7/%8 访问链结果
            var w = new List<uint> { 0x07230203, 0x00010000, 0, 20, 0 };
            void I(int op, params uint[] a) { w.Add((uint)((a.Length + 1) << 16 | op)); w.AddRange(a); }
            I(71, 4, 33, 4);            // OpDecorate %4 Binding 4
            I(43, 1, 2, 0);             // OpConstant %int %2 = 0
            I(43, 1, 3, 33);            // OpConstant %int %3 = 33
            I(59, 5, 4, 2);             // OpVariable %ptr %4 Uniform
            I(65, 9, 7, 4, 2, 3);       // OpAccessChain %7 = %4[0][33]
            var u = SpirvCbufUse.Analyze(MemoryMarshal.AsBytes(w.ToArray().AsSpan()));
            Check("SPIR-V：一个常量绑定", 1, u.Count);
            Check("SPIR-V：绑定号 4", 4, u[0].Binding);
            Check("SPIR-V：读下标 33", "33", string.Join(",", u[0].Indices.ToArray()));
            Check("SPIR-V：非动态", false, u[0].Dynamic);
            Check("读法：下标 33 落在 [528,544)", true, u[0].Reads(0, 768, 528, 544));
            Check("读法：下标 33 不落在 [0,64)", false, u[0].Reads(0, 768, 0, 64));

            // 原创读取分析夹具（不是可执行着色器）：OpExtInst 的 word 4 是指令字面量，其余仍按 ID 检查。
            // %4 只经上面的访问链读 vec4[33]；扩展指令编号恰好为 4，不能凭数字相同扩大到整块。
            var staticRead = w.ToArray();
            List<CbufUse> WithInstruction(int op, params uint[] operands)
            {
                var module = new List<uint>(staticRead);
                module.Add((uint)((operands.Length + 1) << 16 | op)); module.AddRange(operands);
                return SpirvCbufUse.Analyze(MemoryMarshal.AsBytes(module.ToArray().AsSpan()));
            }
            var ext = WithInstruction(12, 1, 10, 11, 4, 12, 13);
            Check("SPIR-V：ExtInst literal 碰撞不变为动态", false, ext[0].Dynamic);
            Check("SPIR-V：ExtInst literal 碰撞保留绑定", 4, ext[0].Binding);
            Check("SPIR-V：ExtInst literal 碰撞保留精确下标", "33", string.Join(",", ext[0].Indices.ToArray()));
            Check("SPIR-V：ExtInst literal 碰撞不扩大读取范围", false, ext[0].Reads(0, 768, 0, 64));
            Check("SPIR-V：ExtInst 最短五字指令不把 literal 当 ID", false, WithInstruction(12, 1, 10, 11, 4)[0].Dynamic);
            foreach (int word in new[] { 1, 2, 3, 5, 6 })
            {
                uint[] operands = { 1, 10, 11, 4, 12, 13 }; operands[word - 1] = 4;
                Check($"SPIR-V：ExtInst word {word} 真 ID 碰撞仍动态", true, WithInstruction(12, operands)[0].Dynamic);
            }
            for (int words = 1; words < 5; words++)
                Check($"SPIR-V：ExtInst 短指令 {words} 字拒绝", true, WithInstruction(12, new uint[words - 1]) == null);
            Check("SPIR-V：未知指令 word 4 的 Uniform 逃逸仍动态", true, WithInstruction(65535, 1, 10, 11, 4, 12)[0].Dynamic);

            I(65, 9, 8, 4, 2, 6);       // OpAccessChain %8 = %4[0][%6 动态]
            u = SpirvCbufUse.Analyze(MemoryMarshal.AsBytes(w.ToArray().AsSpan()));
            Check("SPIR-V：动态下标判为动态", true, u[0].Dynamic);

            // gl_Position.w 恒 1：%10 float 类型、%11 常量 1.0、%12 结构体（成员 0 = Position）、%13 输出指针类型、%14 输出变量、%15 访问链、%16 int、%17=0、%18=3
            var v = new List<uint> { 0x07230203, 0x00010000, 0, 30, 0 };
            void J(int op, params uint[] a) { v.Add((uint)((a.Length + 1) << 16 | op)); v.AddRange(a); }
            J(72, 12, 0, 11, 0);        // OpMemberDecorate %12 0 BuiltIn Position
            J(22, 10, 32);              // OpTypeFloat %10 32
            J(43, 10, 11, 0x3f800000);  // OpConstant %float %11 = 1.0
            J(43, 16, 17, 0); J(43, 16, 18, 3);
            J(32, 13, 3, 12);           // OpTypePointer %13 Output %12
            J(59, 13, 14, 3);           // OpVariable %13 %14 Output
            J(65, 19, 15, 14, 17, 18);  // OpAccessChain %15 = %14[0][3]
            J(62, 15, 11);              // OpStore %15 1.0
            Check("gl_Position.w 只写 1.0 → 2D 通道", true, SpirvCbufUse.PositionWIsOne(MemoryMarshal.AsBytes(v.ToArray().AsSpan())));
            J(62, 15, 17);              // 再写一次非 1.0 的值
            Check("gl_Position.w 写了别的值 → 透视", false, SpirvCbufUse.PositionWIsOne(MemoryMarshal.AsBytes(v.ToArray().AsSpan())));
        }

        // ---------- 原生宽目标（游戏自己按屏幕比出 2346×1080） ----------
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            Check("原生宽 2346×1080 不放宽（宽不变）", 2346, fr.OnCreateTexture(2, 2346, 1080));
            Check("原生宽登记", true, fr.IsNative(2));
            Check("原生宽不算放宽贴图（上传 / 读回 / 拷贝照常）", false, fr.IsWide(2));
            fr.OnCreateTexture(13, 2346, 1080);
            byte[] dst = new byte[64]; fr.OnBufferData(7, 0, B(Proj()), dst);
            var proj = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) proj.Add(i);
            var other = new CbufUse { Binding = 4 }; other.Add(20);
            CbufRead[] rp = { new(7, 0, 768, proj) }, ro = { new(7, 0, 768, other) };
            fr.OnRenderTargets(13, 0); fr.OnFragmentTexture(128, 2); fr.OnDraw(ro, pat, out _); fr.OnPresent(13);
            Check("原生宽：T_out 认得出", 2u, fr.OutTexture);
            fr.OnRenderTargets(2, 0);
            Check("原生宽：片元坐标不缩放", 1f, fr.TargetScaleX ?? -1f);
            fr.DrawSamplesWide = false;   // 界面层采样的是界面图集（包装层按本笔实际采样填；不填时按槽位判，槽位里还留着上一帧的 2）
            fr.OnDraw(ro, pat, out _);
            var mh = fr.OnDraw(rp, pat, out var ch);
            Check("原生宽：读改写投影的界面层", DrawClass.Hud, ch);
            float x = 0, w = 2346; fr.MapViewport(mh, ref x, ref w);
            Check("原生宽：界面层读改写投影 → 视口不动（投影 1/k 让它居中原尺寸）", 2346f, w);
            var mc = fr.OnDraw(ro, pat, out _);
            x = 0; w = 2346; fr.MapViewport(mc, ref x, ref w);
            Check("原生宽：界面层没读改写矩阵 → 视口收进中间 16:9，宽 2346/k = 1920", 1920f, w);
            Check("原生宽：收进后 x = 213", 213f, x);
            Check("原生宽目标不写回原值", 0, pat.W.Count);
            fr.DrawSamplesWide = null;
        }

        // ---------- 16:9 原比例页（BeginPage / Page 模式）：期望按 s = (宽1 − 宽0)·(画布中心)/宽0 手算 ----------
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            fr.OnCreateTexture(5, 1600, 900);   // 暗黑2 交换链：掌机档只画左上 1280×720
            fr.OnCreateTexture(6, 1920, 1080);  // 整张画布
            byte[] dst = new byte[64]; fr.OnBufferData(7, 0, B(Proj()), dst);
            var proj = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) proj.Add(i);
            CbufRead[] rp = { new(7, 0, 768, proj) };
            fr.OnRenderTargets(5, 0);
            Check("登记前不是页", false, fr.PageActive);
            Check("旧行为（反证）：读改写投影的绘制按 Hor —— 视口 1280 放大到 1280·1955/1600 = 1564（图片被放大）", ViewportMode.Hor, fr.OnDraw(rp, pat, out _));
            float x = 0, w = 1280; fr.MapViewport(ViewportMode.Hor, ref x, ref w);
            Check("旧行为（反证）：Hor 视口宽 1564", 1564f, w);
            bool ok = fr.BeginPage(5, 0, 1280, out int c0, out int c1, out int m0, out int m1);
            Check("1600 宽贴图、画布 [0,1280)：s = 355·640/1600 = 142，内容 [142,1422)、页面放宽区 [0,1564)", "True 142 1422 0 1564", $"{ok} {c0} {c1} {m0} {m1}");
            Check("登记后本帧是页", true, fr.PageActive);
            int n0 = pat.W.Count;
            Check("页内绘制返回 Page", ViewportMode.Page, fr.OnDraw(rp, pat, out _, true));
            Check("页内绘制把读到的改写投影写回原值（按 16:9 原样画）", "1 " + P00, $"{pat.W.Count - n0} {(pat.W.Count > n0 ? pat.W[^1].Item3[0] : 0)}");
            x = 0; w = 1280; fr.MapViewport(ViewportMode.Page, ref x, ref w);
            Check("页内视口原尺寸、平移 142", "142 1280", $"{x} {w}");
            int sx = 0, sw = 1280; fr.MapScissor(ViewportMode.Page, ref sx, ref sw);
            Check("页内剪裁原尺寸、平移 142", "142 1280", $"{sx} {sw}");
            Check("页内容区（之后的绘制剪到这里）", "True 142 1422", $"{fr.PageClip(out int k0, out int k1)} {k0} {k1}");
            fr.OnDraw(rp, pat, out _);
            Check("离开页（普通放宽绘制）把改写值写回", P00 / K, pat.W[^1].Item3[0]);
            fr.OnPresent(5);
            fr.OnRenderTargets(5, 0);
            Check("下一帧不再是页（每帧重新判）", false, fr.PageActive);
            fr.OnRenderTargets(6, 0);
            fr.BeginPage(6, 0, 1920, out c0, out c1, out m0, out m1);
            Check("整张 1920 画布：s = 213 = 界面层居中偏移，内容 [213,2133)、放宽区 [0,2346)", "213 2133 0 2346", $"{c0} {c1} {m0} {m1}");
            Check("首次上屏的 CPU 内容按页放：1920 宽贴图、裁剪 [0,1280) → s = 426·640/1920 = 142（丝之歌）", 142.0, Math.Round(fr.PageShift(6, 0, 1280), 6));
            Check("没放宽的贴图不能登记页", false, fr.BeginPage(99, 0, 1280, out _, out _, out _, out _));
            fr.OnCreateTexture(8, 320, 180);   // 320·K = 391，多出 71 列（奇数）：中心偏移 35.5 取整 36（页内容按整像素平移，被采样的原宽副本对得齐）
            Check("320×180 页：平移取整 36（不是 35.5）", 36.0, fr.PageShift(8, 0, 320));
        }

        // ---------- 稳态零分配：预热后 1000 帧（每帧改写 + 非放宽目标写回 + 放宽目标写回 + 上屏），托管分配应为 0 ----------
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new NullPatcher();
            fr.OnCreateTexture(2, 1920, 1080); fr.OnCreateTexture(13, 1920, 1080); fr.OnCreateTexture(50, 600, 300);
            byte[] src = B(Proj()), dst = new byte[64];
            var proj = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) proj.Add(i);
            CbufRead[] rp = { new(7, 0, 768, proj) };
            void Frame()
            {
                fr.OnBufferData(7, 0, src, dst);
                fr.OnRenderTargets(50, 0); fr.OnDraw(rp, pat, out _);
                fr.OnRenderTargets(2, 0); fr.OnDraw(rp, pat, out _); fr.OnDraw(rp, pat, out _);
                fr.OnRenderTargets(13, 0); fr.OnFragmentTexture(128, 2); fr.OnDraw(rp, pat, out _); fr.OnPresent(13);
            }
            for (int i = 0; i < 100; i++) Frame();
            // 两段窗口相减，去掉与帧数无关的一次性开销（分层编译换代码等），只看「随帧数增长」的分配
            long a0 = GC.GetAllocatedBytesForCurrentThread();
            for (int i = 0; i < 1000; i++) Frame();
            long a1 = GC.GetAllocatedBytesForCurrentThread();
            for (int i = 0; i < 10000; i++) Frame();
            long a2 = GC.GetAllocatedBytesForCurrentThread();
            Console.WriteLine($"     （1000 帧 {a1 - a0} 字节、10000 帧 {a2 - a1} 字节）");
            Check("稳态每帧托管分配（字节，10000 帧窗口减 1000 帧窗口再 ÷9000）", 0L, ((a2 - a1) - (a1 - a0)) / 9000);
            Check("稳态期间确实走了写回路径（写回 ≥1000 次）", true, fr.Restores >= 1000);
        }

        // ---------- 计算派发写放宽图像（10-22 巫师3 第三层）：按像素铺的派发 X 组数补到放宽宽度，不按像素铺的不动 ----------
        Check("40×23 组铺 640×360（16 像素一组）放宽到 782：⌈782/16⌉ = 49", 49, WidenFrame.WidenGroupsX(40, 23, 640, 782, 360));
        Check("80×45 组铺 640×360（8 像素一组）放宽到 782：⌈782/8⌉ = 98", 98, WidenFrame.WidenGroupsX(80, 45, 640, 782, 360));
        Check("180×1 组（一维规约，⌈640/L⌉ 无一等于 180）不补", -1, WidenFrame.WidenGroupsX(180, 1, 640, 782, 360));
        Check("4×1 组（⌈640/128⌉ = 5、⌈640/256⌉ = 3）不补", -1, WidenFrame.WidenGroupsX(4, 1, 640, 782, 360));
        Check("40×24 组（⌈360/16⌉ = 23 ≠ 24，y 不按像素铺）不补", -1, WidenFrame.WidenGroupsX(40, 24, 640, 782, 360));

        // ---------- 读片元坐标的程序按客体 x 坐标画（render_scale[0] = k）：读到的屏幕尺寸写回原值（10-22 巫师3：叠了改写的 1564 → 取图只覆盖 0..0.82、整幅放大 + 重影）；
        // 不读片元坐标的程序（看到真实宽像素）照用改写值 ----------
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            fr.OnCreateTexture(2, 1920, 1080);
            byte[] dst = new byte[16];
            bool sent = fr.OnBufferData(7, 0, B(1920, 1080, 1f / 1920, 1f / 1080), dst);
            Check("屏幕尺寸 1920 → 2346（上传即改）", 2346f, sent ? Fl(dst)[0] : float.NaN);
            var u = new CbufUse { Binding = 4 }; u.Add(0);
            CbufRead[] r = { new(7, 0, 256, u) };
            fr.OnRenderTargets(2, 0);
            string Ws() => string.Join(",", pat.W.ConvertAll(w => w.Item3[0].ToString()));
            pat.W.Clear(); var m1 = fr.OnDraw(r, pat, out _, false, true);
            Check("读片元坐标的程序画放宽目标：ScaleK、屏幕尺寸写回原值 1920", "ScaleK 1920", $"{m1} {Ws()}");
            pat.W.Clear(); fr.OnDraw(r, pat, out _, false, true);
            Check("连续两次读片元坐标的绘制：不来回写", 0, pat.W.Count);
            pat.W.Clear(); fr.OnDraw(r, pat, out _, false, false);
            Check("不读片元坐标的程序：改回改写值 2346", "2346", Ws());
        }

        // ---------- 像素射线基（10-22 巫师3 光照累积：射线 = C + x·A + y·B，读整数取图的程序片元 x 是真实宽像素，左上射线 C 要左移 pad 个 A）----------
        {
            // 镜头 fovy 45°（tanX = 1/P00、tanY = 1/P11），1920×1080 画布：|A| = 2·tanX/1920 = 2·tanY/1080；右 R、下 D、前 F 两两正交
            float th = 0.6f, tx = 1 / P00, ty = 1 / P11, s = 2 * tx / 1920;
            float[] R = { MathF.Cos(th), -MathF.Sin(th), 0 }, D = { 0, 0, -1 }, Fw = { MathF.Sin(th), MathF.Cos(th), 0 };
            float[] Rows(float sa, float cu, float cv)   // 行：A、B、相机位置、C（巫师3 的排法），C = F + cu·A + cv·B
            {
                var f = new float[16];
                for (int j = 0; j < 3; j++) { f[j] = sa * s * R[j]; f[4 + j] = s * D[j]; f[12 + j] = Fw[j] + cu * sa * s * R[j] + cv * s * D[j]; }
                f[8] = 270; f[9] = -32.5f; f[10] = 990; f[11] = 5; f[15] = 0.0002f;
                return f;
            }
            float[] rows = Rows(1, -959.5f, -539.5f);
            WidenFrame Fr() { var f = new WidenFrame(new WidenRewriter(A0)); f.OnCreateTexture(2, 1920, 1080); f.OnBufferData(9, 0, B(Proj()), new byte[64]); return f; }
            var fr = Fr(); byte[] dst = new byte[64];
            bool sent = fr.OnBufferData(7, 0, B(rows), dst);
            float[] o = Fl(dst);
            float pad = (2346 - 1920) / 2f, err = 0;
            for (int j = 0; j < 3; j++) err = MathF.Max(err, MathF.Abs(o[12 + j] - (rows[12 + j] - pad * rows[j])));
            Check("像素射线基：上传即改左上射线 C' = C − 213·A（误差 < 1e-5）", "True True", $"{sent} {err < 1e-5f}");
            float errA = 0; for (int j = 0; j < 3; j++) errA = MathF.Max(errA, MathF.Abs(o[j] - K * rows[j]));
            Check("步长 A' = k·A（误差 < 1e-7）、A 的 w 不改", true, sent && errA < 1e-7f && o[3] == rows[3]);
            Check("B、相机位置、C 的 w 不改", true, sent && o.AsSpan(4, 8).SequenceEqual(rows.AsSpan(4, 8)) && o[15] == rows[15]);
            Check("计数 像素射线起点 1、步长 1", "1 1", $"{fr.Rewriter.Stats.PixelRay} {fr.Rewriter.Stats.PixelStep}");
            Check("步长 ×1.1（反解画布宽 1745.5 不是整数）不认", false, Fr().OnBufferData(7, 0, B(Rows(1.1f, -959.5f / 1.1f, -539.5f)), dst));
            Check("C 是中心射线（不在左上）不认", false, Fr().OnBufferData(7, 0, B(Rows(1, 0, 0)), dst));
            var u = new CbufUse { Binding = 16 }; for (int i = 0; i < 4; i++) u.Add(i);
            CbufRead[] r = { new(7, 0, 64, u) };
            var pat = new Rec(); fr.OnRenderTargets(2, 0);
            fr.OnDraw(r, pat, out _, false, false);
            Check("按真实像素画的程序（片元坐标即放宽像素）：A 写回原值、C' 照用", true, pat.W.Count == 1 && pat.W[0].Item2 == 0 && pat.W[0].Item3.AsSpan().SequenceEqual(rows.AsSpan(0, 4)));
            pat.W.Clear(); fr.OnDraw(r, pat, out _, false, true);
            Check("按客体坐标画的程序（片元 x 已 ÷ k）：改回 A' = k·A", true, pat.W.Count == 1 && pat.W[0].Item2 == 0 && pat.W[0].Item3.AsSpan().SequenceEqual(o.AsSpan(0, 4)));
            th = 1.1f; R[0] = MathF.Cos(th); R[1] = -MathF.Sin(th); Fw[0] = MathF.Sin(th); Fw[1] = MathF.Cos(th);
            float[] rows2 = Rows(1, -959.5f, -539.5f);
            fr.OnBufferData(7, 0, B(rows2), dst); o = Fl(dst); err = 0;
            for (int j = 0; j < 3; j++) err = MathF.Max(err, MathF.Abs(o[12 + j] - (rows2[12 + j] - pad * rows2[j])));
            for (int j = 0; j < 3; j++) err = MathF.Max(err, MathF.Abs(o[j] - K * rows2[j]));
            Check("镜头转动后整段重传：按新 A 重算 C'、A'", true, err < 1e-5f);
        }

        // ---------- 大上传（10-22 巫师3 换场景：按上传大小长的临时缓冲一帧分配约 44 MB）：整段扫描按 64 KB 分块、跨块矩阵照认；dst 装不下时命中逐段补写 ----------
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            int n = 200 * 1024; var f = new float[n / 4];
            int[] at = { 64 * 1024 - 32, 128 * 1024 - 16, 3000 * 16, 150 * 1024 };   // 跨第 1 / 2 块边界、块内两个
            foreach (int o in at) Proj().CopyTo(f, o / 4);
            fr.OnBufferData(5, 0, B(f), Array.Empty<byte>(), pat);
            var ws = new List<(ulong, int, float[])>(pat.W); ws.Sort((x, y) => x.Item2.CompareTo(y.Item2)); Array.Sort(at);
            Check("200 KB 上传、补写方式：4 个投影各补写一次、位置对", string.Join(",", at), string.Join(",", ws.ConvertAll(w => w.Item2)));
            Check("补写的是改写值（P00 × 1/k）", true, ws.Count == 4 && ws.TrueForAll(w => MathF.Abs(w.Item3[0] - P00 / K) < 1e-5f));
            // 先扫后写（上传租约：数据交出去后不能再读）：只扫描登记、不写，之后 WriteHits 补写同样的 4 段
            var frL = new WidenFrame(new WidenRewriter(A0)); var patL = new Rec();
            bool hitL = frL.OnBufferData(5, 0, B(f), Array.Empty<byte>(), null);
            frL.WriteHits(5, 0, n, patL);
            var wl = new List<(ulong, int, float[])>(patL.W); wl.Sort((x, y) => x.Item2.CompareTo(y.Item2));
            Check("先扫后写：扫描不写、WriteHits 补写同样 4 段与改写值", "True " + string.Join(",", at), $"{hitL} {string.Join(",", wl.ConvertAll(w => w.Item2))}");
            Check("WriteHits 写的值与补写方式逐段相同", true, wl.Count == ws.Count && wl.TrueForAll(x => ws.Exists(y => y.Item2 == x.Item2 && y.Item3.AsSpan().SequenceEqual(x.Item3))));
            var fr2 = new WidenFrame(new WidenRewriter(A0)); byte[] small = B(Proj()), dd = new byte[64];
            fr2.OnBufferData(6, 0, small, dd);
            var big = new byte[4 << 20]; new Random(3).NextBytes(big);
            long a0 = GC.GetAllocatedBytesForCurrentThread();
            fr2.OnBufferData(7, 0, big, Array.Empty<byte>(), new NullPatcher());
            long al = GC.GetAllocatedBytesForCurrentThread() - a0;
            Console.WriteLine($"     （4 MB 上传本线程分配 {al} B）");
            Check("4 MB 大上传（没影子、整段扫）本线程分配 < 64 KB（旧做法 ≈ 7 MB）", true, al < 64 * 1024);
        }

        // ---------- 常量缓冲影子回收（10-22 暗黑2：绑定位置在大缓冲里一路往后挪 + 缓冲不停新建 / 删除，旧做法页只建不收、每个新缓冲新建一份影子）----------
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new NullPatcher();
            fr.OnCreateTexture(2, 1920, 1080);
            byte[] src = B(Proj()), dst = new byte[64];
            var proj = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) proj.Add(i);
            var rp = new CbufRead[1];
            int n = 0;
            // 每帧：流式常量缓冲 1 往后挪 4 页（1024 页一圈 = 256 帧）各绑一次、传投影、画一次；新建缓冲 100000+n 传一段、绑一次，删掉 3 帧前那个
            void Frame()
            {
                for (int k = 0; k < 4; k++)
                {
                    int off = (n * 4 + k) % 1024 * 4096;
                    fr.OnUniformBound(1, off, 256); fr.OnBufferData(1, off, src, dst);
                    rp[0] = new CbufRead(1, off, 256, proj); fr.OnRenderTargets(2, 0); fr.OnDraw(rp, pat, out _);
                }
                ulong t = 100000 + (ulong)n;
                fr.OnBufferData(t, 0, src, dst); fr.OnUniformBound(t, 0, 256);
                if (n >= 3) fr.OnDeleteBuffer(t - 3);
                fr.OnPresent(2); n++;
            }
            for (int i = 0; i < 600; i++) Frame();
            long a0 = GC.GetAllocatedBytesForCurrentThread();
            for (int i = 0; i < 1000; i++) Frame();
            long a1 = GC.GetAllocatedBytesForCurrentThread();
            for (int i = 0; i < 10000; i++) Frame();
            long a2 = GC.GetAllocatedBytesForCurrentThread();
            Console.WriteLine($"     （1000 帧 {a1 - a0} 字节、10000 帧 {a2 - a1} 字节）");
            Check("挪绑定 + 缓冲新建删除：稳态每帧托管分配（字节，10000 帧窗口减 1000 帧窗口再 ÷9000）", 0L, ((a2 - a1) - (a1 - a0)) / 9000);
            // 存活页上限手算：流式缓冲最近 KeepFrames+1 帧各 4 页 + 还没删的 3 个新缓冲各 1 页（旧做法一圈 1024 页全留 = 4 MB）
            Check("影子不超过最近 KeepFrames+1 帧绑过的页（字节）", true, fr.Shadow.Bytes <= ((CbufShadow.KeepFrames + 1) * 4 + 4) * 4096L);
        }
        // 页回收后的正确性：命中表不动（照算读到改写），再绑、同内容再传（影子没了 → 整段重扫）照样发改写值
        {
            var fr = new WidenFrame(new WidenRewriter(A0));
            fr.OnCreateTexture(2, 1920, 1080);
            var proj = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) proj.Add(i);
            byte[] src = B(Proj()), dst = new byte[64];
            fr.OnUniformBound(7, 0, 256); fr.OnBufferData(7, 0, src, dst);
            Check("绑过的页传投影：读到改写", true, fr.ReadsRewritten(7, 0, 256, proj));
            long b0 = fr.Shadow.Bytes;
            for (int i = 0; i < CbufShadow.KeepFrames; i++) fr.OnPresent(2);
            Check("KeepFrames 帧没再绑：页还在", b0, fr.Shadow.Bytes);
            fr.OnPresent(2);
            Check("第 KeepFrames+1 帧：页回收（影子少 4096 字节）", b0 - 4096, fr.Shadow.Bytes);
            Check("页回收后命中表不动：仍算读到改写", true, fr.ReadsRewritten(7, 0, 256, proj));
            fr.OnUniformBound(7, 0, 256); Array.Clear(dst);
            bool sent = fr.OnBufferData(7, 0, src, dst);
            Check("页回收后再绑、同内容再传：照样发改写值（[0] = P00/K）", P00 / K, sent ? Fl(dst)[0] : float.NaN);
            fr.OnBufferData(7, 512, src, dst);
            Check("7 号 512 起再传一份投影：读到改写", true, fr.ReadsRewritten(7, 512, 256, proj));
            fr.OnDeleteBuffer(7);
            Check("删缓冲：影子页全回收", 0L, fr.Shadow.Bytes);
            fr.OnUniformBound(8, 0, 256); fr.OnBufferData(8, 0, src, dst);
            Check("删后新缓冲复用回收的影子：旧缓冲 512 起的命中没带过来", false, fr.ReadsRewritten(8, 512, 256, proj));
            Check("新缓冲自己的命中照算", true, fr.ReadsRewritten(8, 0, 256, proj));
        }

        // ---------- 片元坐标 y 去缩放（手拼 Ryujinx 形态：取 FragCoord[1] 与 support_buffer[5][0]，经局部变量中转后 FDiv） ----------
        {
            // %1 float 类型、%2 int 类型、%3..%6 int 常量 0/1/5/0、%7 float 1.0、%8 FragCoord 变量、%9 support_buffer（绑定 0、Uniform）、
            // %10 局部变量甲、%11 局部变量乙、%20.. 结果
            var v = new List<uint> { 0x07230203, 0x00010000, 0, 40, 0 };
            void J(int op, params uint[] a) { v.Add((uint)((a.Length + 1) << 16 | op)); v.AddRange(a); }
            J(71, 8, 11, 15);            // OpDecorate %8 BuiltIn FragCoord
            J(71, 9, 33, 0);             // OpDecorate %9 Binding 0
            J(22, 1, 32);                // OpTypeFloat %1 32
            J(43, 2, 3, 0); J(43, 2, 4, 1); J(43, 2, 5, 5);
            J(43, 1, 7, 0x3f800000);     // %7 = 1.0f
            J(59, 30, 9, 2);             // OpVariable %ptr %9 Uniform
            J(65, 31, 20, 8, 4);         // %20 = &FragCoord[1]
            J(61, 1, 21, 20);            // %21 = load
            J(62, 10, 21);               // store 甲 ← y
            J(65, 32, 22, 9, 5, 3);      // %22 = &support_buffer[5][0]
            J(61, 1, 23, 22);            // %23 = load
            J(62, 11, 23);               // store 乙 ← 缩放
            J(61, 1, 24, 10); J(61, 1, 25, 11);
            int divAt = v.Count;
            J(136, 1, 26, 24, 25);       // %26 = y / 缩放
            J(65, 31, 27, 8, 3);         // %27 = &FragCoord[0]
            J(61, 1, 28, 27);
            J(136, 1, 29, 28, 23);       // %29 = x / 缩放
            byte[] spv = MemoryMarshal.AsBytes(v.ToArray().AsSpan()).ToArray();
            byte[] o = SpirvFragCoord.PatchY(spv, 5, out int yp, out int xu);
            Check("片元 y ÷ 缩放：改 1 处", 1, yp);
            Check("片元 x ÷ 缩放：认出 1 处、不改", 1, xu);
            Check("y 那处除数换成常量 1.0（%7）", 7u, MemoryMarshal.Cast<byte, uint>(o)[divAt + 4]);
            Check("x 那处除数不动（%23）", 23u, MemoryMarshal.Cast<byte, uint>(o)[^1]);
            Check("原数组不被改", 25u, MemoryMarshal.Cast<byte, uint>(spv)[divAt + 4]);
        }
        // 同一形态、模块里没有常量 1.0（审计 P2-39）：原先 y 修正静默不做；现在补一个常量 1.0（编号 = 原 bound 40）、bound 加 1、y 除数指向它
        {
            var v = new List<uint> { 0x07230203, 0x00010000, 0, 40, 0 };
            void J(int op, params uint[] a) { v.Add((uint)((a.Length + 1) << 16 | op)); v.AddRange(a); }
            J(71, 8, 11, 15); J(71, 9, 33, 0); J(22, 1, 32);
            J(43, 2, 3, 0); J(43, 2, 4, 1); J(43, 2, 5, 5);
            J(59, 30, 9, 2);
            J(54, 1, 50, 0, 60);         // OpFunction：常量补在它前面
            J(65, 31, 20, 8, 4); J(61, 1, 21, 20);
            J(65, 32, 22, 9, 5, 3); J(61, 1, 23, 22);
            J(136, 1, 26, 21, 23);       // %26 = y / 缩放
            J(56);
            byte[] spv = MemoryMarshal.AsBytes(v.ToArray().AsSpan()).ToArray();
            byte[] o = SpirvFragCoord.PatchY(spv, 5, out int yp, out _);
            var ow = MemoryMarshal.Cast<byte, uint>(o).ToArray();
            Check("没有常量 1.0：y ÷ 缩放仍改 1 处", 1, yp);
            Check("没有常量 1.0：bound 加 1", 41u, ow[3]);
            int fn = Array.FindIndex(ow, x => x == (5u << 16 | 54)), div = Array.FindLastIndex(ow, x => x == (5u << 16 | 136));
            Check("没有常量 1.0：函数定义前补了 OpConstant %1 %40 1.0", "262187 1 40 1065353216", fn >= 4 ? $"{ow[fn - 4]} {ow[fn - 3]} {ow[fn - 2]} {ow[fn - 1]}" : "无");
            Check("没有常量 1.0：y 除数指向新常量 %40", 40u, div >= 0 ? ow[div + 4] : 0u);
        }

        // ---------- 取图缩放只剩横向（手拼 Ryujinx 形态：TexelFetchScale(坐标, 缩放下标, 分量号) / TextureSizeUnscale(尺寸分量, 缩放下标)，参数是局部变量指针、常量先存进局部变量） ----------
        {
            // %1 float、%2 int、%3/%4/%5/%6 int 常量 0/1/5/2、%9 support_buffer（绑定 0、Uniform）、%40 2D 图像类型、%41 采样图像类型、%42 贴图变量（绑定 130）、
            // %43 缓冲图像类型（Dim Buffer）、%44 缓冲贴图变量（绑定 131）、%50 取图缩放（3 参）、%70 尺寸反缩放（2 参）、%81.. 局部变量、%100.. 值
            List<uint> Build(bool scaleFetch, bool bufferFetch, bool addOffset = false, bool imageWrite = false)
            {
                var v = new List<uint> { 0x07230203, 0x00010000, 0, 200, 0 };
                void J(int op, params uint[] a) { v.Add((uint)((a.Length + 1) << 16 | op)); v.AddRange(a); }
                J(71, 9, 33, 0); J(71, 42, 33, 130); J(71, 44, 33, 131);
                if (imageWrite) { J(71, 46, 33, 132); J(25, 45, 1, 1, 0, 0, 0, 2, 1); J(59, 31, 46, 0); }   // 二维存储图像 %45（Rgba32f）、变量 %46（绑定 132）
                J(22, 1, 32); J(21, 2, 32, 1);
                J(43, 2, 3, 0); J(43, 2, 4, 1); J(43, 2, 5, 5); J(43, 2, 6, 2);
                J(25, 40, 1, 1, 0, 0, 0, 1, 0); J(27, 41, 40); J(25, 43, 1, 5, 0, 0, 0, 1, 0);
                J(59, 30, 9, 2); J(59, 31, 42, 0); J(59, 31, 44, 0);
                foreach (var (f, np) in new[] { (50u, 3), (70u, 2) })
                {
                    J(54, 2, f, 0, 60);
                    for (uint k = 0; k < np; k++) J(55, 61, f + 1 + k);
                    J(61, 2, f + 5, f + 2);                 // 载缩放下标
                    J(65, 62, f + 6, 9, 5, f + 5);          // &support_buffer.render_scale[动态下标]
                    J(56);
                }
                J(54, 2, 99, 0, 60);
                uint co = 110;
                if (scaleFetch)
                {
                    J(62, 81, 100); J(62, 82, 6); J(62, 83, 3); J(57, 2, 110, 50, 81, 82, 83);   // x 分量
                    J(62, 84, 101); J(62, 85, 6); J(62, 86, 4); J(57, 2, 111, 50, 84, 85, 86);   // y 分量
                    J(62, 87, 110); J(62, 88, 111); J(61, 2, 112, 87); J(61, 2, 113, 88);
                    if (addOffset) { J(128, 2, 130, 112, 102); J(128, 2, 131, 113, 102); J(80, 90, 114, 130, 131); }   // 缩放后再加运行时偏移
                    else J(80, 90, 114, 112, 113);
                    co = 114;
                }
                else J(80, 90, co, 100, 101);
                J(61, 41, 115, 42); J(100, 40, 116, 115); J(95, 91, 117, 116, co);   // texelFetch(贴图 130, 坐标)
                J(103, 90, 118, 116, 3); J(81, 2, 119, 118, 0); J(81, 2, 120, 118, 1);  // textureSize → x、y
                J(62, 89, 119); J(62, 92, 6); J(57, 2, 121, 70, 89, 92);
                J(62, 93, 120); J(57, 2, 122, 70, 93, 92);
                if (bufferFetch) { J(61, 43, 123, 44); J(95, 91, 124, 123, 100); }   // 缓冲贴图整数取图（Ryujinx 不缩放、与屏幕无关）
                if (imageWrite) { J(61, 45, 125, 46); J(99, 125, 100, 117); }   // imageStore(图像 132, 游戏坐标 %100, 取到的值)
                J(56);
                return v;
            }
            byte[] B2(List<uint> l) => MemoryMarshal.AsBytes(l.ToArray().AsSpan()).ToArray();
            var src = Build(true, true);
            byte[] o = SpirvFetchScale.PatchY(B2(src), 5, out var sc, out int yp, out bool exact);
            var ow = MemoryMarshal.Cast<byte, uint>(o).ToArray();
            Check("取图缩放：y 分量两处调用换掉（取图 + 尺寸）、exact", "2 True", $"{yp} {exact}");
            Check("取图缩放项：render_scale[3] ↔ 贴图绑定 130（取图与尺寸同一项去重）", "3:130:False", string.Join(",", Array.ConvertAll(sc, x => $"{x.Index}:{x.Binding}:{x.Image}")));
            int Find(uint[] w, uint op, uint res) { for (int i = 5; i < w.Length; i += (int)(w[i] >> 16)) if ((w[i] & 0xffff) == op && w[i + 2] == res) return i; return -1; }
            int yi = Find(ow, 61, 111), si = Find(ow, 61, 122);
            Check("y 取图调用 → OpLoad %111 ← 参数0 指针 %84；y 尺寸调用 → OpLoad %122 ← %93", "84 93", yi > 0 && si > 0 ? $"{ow[yi + 3]} {ow[si + 3]}" : "没找到");
            Check("x 分量调用不动（%110 仍是函数调用、尺寸 x %121 也是）", "True True", $"{Find(ow, 57, 110) > 0} {Find(ow, 57, 121) > 0}");
            Check("换掉后总字数少 5（7→4、6→4）、原数组不改", "5 True", $"{src.Count - ow.Length} {Find(src.ToArray(), 57, 111) > 0}");
            SpirvFetchScale.PatchY(B2(Build(false, false)), 5, out var sc2, out _, out bool ex2);
            Check("2D 整数取图没经过缩放：不 exact（这个程序仍按真实像素画）", false, ex2);
            SpirvFetchScale.PatchY(B2(Build(true, false)), 5, out _, out _, out bool ex3);
            Check("缓冲贴图整数取图不影响 exact", true, ex3);
            SpirvFetchScale.PatchY(B2(Build(true, false, true)), 5, out var sc4, out _, out bool ex4);
            Check("缩放后再加运行时偏移（OpIAdd）仍 exact、缩放项照记", "True 1", $"{ex4} {sc4.Length}");
            // 尺寸表证明（内部分辨率 ABI2）：缓冲贴图（Dim Buffer）宿主从不缩放，取图单独记 never_scaled（内部分辨率放行）；类型认不出的（%44 改指一个没声明的类型）照旧是原因
            SpirvFetchScale.AnalyzeSizeTable(B2(Build(true, true)), 5, out _, out var rsBuf);
            var unk = Build(true, true); { int k = unk.LastIndexOf(43u); unk[k] = 199; }   // 缓冲贴图那次 OpLoad 的结果类型 %43 → 没声明的 %199
            SpirvFetchScale.AnalyzeSizeTable(B2(unk), 5, out _, out var rsUnk);
            Check("尺寸表证明：缓冲贴图取图记 never_scaled、不记 non_2d / 类型认不出的照记 non_2d", "True False True",
                  $"{Array.IndexOf(rsBuf, "never_scaled_image_type") >= 0} {Array.IndexOf(rsBuf, "non_2d_or_unknown_image_type") >= 0} {Array.IndexOf(rsUnk, "non_2d_or_unknown_image_type") >= 0}");
            // 写二维图像（11-22 D-ZR6V 计算着色器）：宽屏旧约定照旧不 exact（Ryujinx 不缩放写图像）；尺寸表证明不因写图像多记原因（宿主图像槽一律原尺寸）——
            //   同一程序加一次 imageStore 前后，尺寸表的原因集合逐项相同、没有 image_write（这个夹具用旧式缩放辅助函数，本身另有原因；修前多一条 image_write）
            SpirvFetchScale.PatchY(B2(Build(true, false)), 5, out _, out _, out bool exW0);
            SpirvFetchScale.PatchY(B2(Build(true, false, imageWrite: true)), 5, out _, out _, out bool exW);
            SpirvFetchScale.AnalyzeSizeTable(B2(Build(true, false)), 5, out _, out var rsW0);
            SpirvFetchScale.AnalyzeSizeTable(B2(Build(true, false, imageWrite: true)), 5, out _, out var rsWr);
            Check("写二维图像：旧约定由 exact 变不 exact；尺寸表原因不变、无 image_write", "True False True False",
                  $"{exW0} {exW} {string.Join(",", rsW0) == string.Join(",", rsWr)} {Array.IndexOf(rsWr, "image_write") >= 0}");
        }

        // ---------- 游戏自己出宽图（GameWide）：不放宽贴图、按视口判原生宽、界面原尺寸居中在视口区域 ----------
        {
            var g = new WidenFrame(new WidenRewriter(2346f / 1080f)) { GameWide = true };
            Check("GameWide：16:9 贴图 1920×1080 不放宽", 1920, g.OnCreateTexture(1, 1920, 1080));
            g.OnRenderTargets(1, 0);
            Check("GameWide：视口 1564×720（屏幕比）→ 原生宽", true, g.OnViewport(0, 1564, 720) && g.TargetNative && g.TargetWide);
            float x = 0, w = 1564; g.MapViewport(ViewportMode.CenterNative, ref x, ref w);
            Check("GameWide：未读改写矩阵的界面层收进视口中间 16:9（x 142、宽 1280）", "142,1280", $"{Math.Round(x)},{Math.Round(w)}");
            x = 0; w = 1564; g.MapViewport(ViewportMode.Hor, ref x, ref w);
            Check("GameWide：读改写矩阵的绘制视口不动", "0,1564", $"{x},{w}");
            // 剪裁跟着界面内容收进中间（手算：k = 1564/1280 = 1.221875、pad 142；左 142 + ⌊1100/k⌋ = 1042，右 142 + ⌈1400/k⌉ = 1288）
            int sx = 1100, sw = 300; g.MapScissor(ViewportMode.Hor, ref sx, ref sw);
            Check("GameWide：读改写矩阵的界面层局部剪裁收进中间（动森小地图）", "1042,246", $"{sx},{sw}");
            sx = 0; sw = 1564; g.MapScissor(ViewportMode.Hor, ref sx, ref sw);
            Check("GameWide：覆盖全宽的剪裁不收（外推元素要画到屏幕边）", "0,1564", $"{sx},{sw}");
            // 界面布局也是宽的（LayoutWide，10-23 塞尔达雷达：游戏剪裁 1187+210 已按宽屏像素算、包住改写后内容 1213..1371）：Hor 局部剪裁原样；
            // 旧规则照收：142 + ⌊1187/k⌋ = 142 + 971 = 1113，右 142 + ⌈1397/k⌉ = 142 + 1144 = 1286 → 1113+173（雷达右半被切，回放实测切在 1286）
            g.LayoutWide = true;
            sx = 1187; sw = 210; g.MapScissor(ViewportMode.Hor, ref sx, ref sw);
            Check("GameWide + 界面布局宽：读改写矩阵的界面层局部剪裁不收（塞尔达雷达）", "1187,210", $"{sx},{sw}");
            sx = 1187; sw = 210; g.MapScissor(ViewportMode.CenterNative, ref sx, ref sw);
            Check("GameWide + 界面布局宽：没读改写矩阵的界面层（内容由视口收进中间）剪裁照收", "1113,173", $"{sx},{sw}");
            g.LayoutWide = false;
            sx = 1187; sw = 210; g.MapScissor(ViewportMode.Hor, ref sx, ref sw);
            Check("GameWide、界面布局 16:9：同一剪裁照收（旧规则，动森）", "1113,173", $"{sx},{sw}");
            Check("GameWide：视口 1280×720（16:9）→ 不是原生宽、视口照旧", true, g.OnViewport(0, 1280, 720) && !g.TargetWide);
            Check("GameWide：放宽表为空（上屏裁剪不换算）", 700, g.MapX(1, 700));
        }

        // ---------- 出图目标集合（10-23 巫师3 露台站立时整帧光影周期性跳）：交换链 26 / 32 交替上屏，上屏晚于下一帧绘制 ----------
        // 时序照巫师3 回放的上屏日志：「上屏 32、最后一笔在 26」→ 选出 32；「上屏 26、最后一笔在 32」→ 选出 26；偶尔「上屏 32、最后一笔就在 32、采样合成图 559」→ 选出 559。
        // 两张交替要连着三次上屏（A、B、A）才认：第 3、4 次上屏分别把 32、26 收进集合。
        // 期望手算：选出过的上屏图 26 / 32 常驻出图目标、559 只当这一次的 T_out；之后画 26：第一笔 = 色调映射合成（FirstToOut / ScaleK），第二笔没读改写矩阵 = 界面层原宽居中（Hud / CenterNative）。
        // 再上屏 32（最后一笔就在 32、没采样别的）→ 选出 32；此后画 559 不再是出图目标（暗黑2 物品栏：误选过一次的合成源常驻集合，全画布遮罩被收进中间）。
        // 旧代码只记最近一张（559）：26 上的第二笔判成场景（Scene / ScaleK），界面被拉伸，与其他帧的居中交替 → 整帧跳
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            foreach (uint t in new uint[] { 26, 32, 559 }) fr.OnCreateTexture(t, 1280, 720);
            var u = new CbufUse { Binding = 4 }; u.Add(20); CbufRead[] rd = { new(7, 0, 768, u) };
            fr.OnRenderTargets(26, 0); fr.OnDraw(rd, pat, out _); fr.OnPresent(32);
            fr.OnRenderTargets(32, 0); fr.OnDraw(rd, pat, out _); fr.OnPresent(26);
            fr.OnRenderTargets(26, 0); fr.OnDraw(rd, pat, out _); fr.OnPresent(32);
            fr.OnRenderTargets(32, 0); fr.OnDraw(rd, pat, out _); fr.OnPresent(26);
            fr.OnRenderTargets(559, 0); fr.OnDraw(rd, pat, out _);
            fr.OnRenderTargets(32, 0); fr.OnFragmentTexture(128, 559); fr.OnDraw(rd, pat, out _); fr.OnPresent(32);
            Check("出图目标集合：最近一次选出的 T_out = 合成图 559", 559u, fr.OutTexture);
            fr.OnFragmentTexture(128, 0);
            fr.OnRenderTargets(26, 0);
            var m1 = fr.OnDraw(rd, pat, out var c1); var m2 = fr.OnDraw(rd, pat, out var c2);
            Check("出图目标集合：画之前选出过的交换链图 26——第一笔合成、第二笔界面层原宽居中", "FirstToOut,ScaleK,Hud,CenterNative", $"{c1},{m1},{c2},{m2}");
            fr.OnRenderTargets(32, 0); fr.OnDraw(rd, pat, out _); fr.OnPresent(26);
            fr.OnRenderTargets(32, 0); fr.OnDraw(rd, pat, out _); fr.OnPresent(32);
            Check("出图目标集合：上屏 32 且最后一笔在 32 → 选出 32", 32u, fr.OutTexture);
            fr.OnRenderTargets(559, 0); fr.OnDraw(rd, pat, out var c3); fr.OnDraw(rd, pat, out var c4);
            Check("出图目标集合：只按采样选出过一次的合成源 559 不常驻（两笔都不是出图目标）", "Scene,Scene", $"{c3},{c4}");
        }

        // ---------- 出图目标集合只在两张交替时启用（10-23 丝之歌三张 10 / 11 / 7 轮换：界面画在轮换的下一张上，改前认不出、按登记的 HUD 左锚定画）----------
        // 期望手算：上屏 10 / 11 / 7 / 10 / 11（每次最后一笔在上屏图上、没采样别的 → 选出上屏图本身），不是 A、B、A → 集合一直空；之后画 7（三次前选出的）不是出图目标 = Scene
        {
            var fr = new WidenFrame(new WidenRewriter(A0)); var pat = new Rec();
            foreach (uint t in new uint[] { 10, 11, 7 }) fr.OnCreateTexture(t, 1280, 720);
            var u = new CbufUse { Binding = 4 }; u.Add(20); CbufRead[] rd = { new(7, 0, 768, u) };
            foreach (uint t in new uint[] { 10, 11, 7, 10, 11 }) { fr.OnRenderTargets(t, 0); fr.OnDraw(rd, pat, out _); fr.OnPresent(t); }
            fr.OnRenderTargets(7, 0); fr.OnDraw(rd, pat, out var c1); fr.OnDraw(rd, pat, out var c2);
            Check("出图目标集合：三张轮换不启用（画三次前选出的 7 两笔都不是出图目标）", "Scene,Scene", $"{c1},{c2}");
        }

        // ---------- GameWide 规则 A：界面画进原生宽合成目标、再合成到上屏贴图（10-21 怪猎掌机档 1568×720，RE 引擎界面按 1280 画布拉满视口）----------
        // 期望手算：T_out = 上屏前最后一次画上屏贴图 1 所采样的贴图 2（画过 1568×720 原生宽视口）；第 2 帧首次画 2 = 合成，再画 = 界面层；
        // 没读改写矩阵 → 收进中间：w0 = round(1568 / 1.221875) = 1283、pad = (1568 − 1283) / 2 = 142.5 → x 142.5、宽 1283。
        // 旧代码 GameWide 下 T_out 恒 0：界面层判成场景、视口按全宽（拉宽 1.22 倍）。
        {
            var g = new WidenFrame(new WidenRewriter(2346f / 1080f)) { GameWide = true }; var pat = new Rec();
            g.OnCreateTexture(1, 1920, 1080); g.OnCreateTexture(2, 1568, 720);
            var other = new CbufUse { Binding = 4 }; other.Add(20); CbufRead[] ro = { new(7, 0, 768, other) };
            g.OnRenderTargets(2, 0); g.OnViewport(0, 1568, 720); g.OnDraw(ro, pat, out _);
            g.OnRenderTargets(1, 0); g.OnViewport(0, 1564, 720); g.OnFragmentTexture(128, 2); g.OnDraw(ro, pat, out _); g.OnPresent(1);
            Check("GameWide 规则 A：T_out = 上屏前最后绘制采样的原生宽合成目标 2", 2u, g.OutTexture);
            g.OnRenderTargets(2, 0); g.OnViewport(0, 1568, 720);
            g.OnDraw(ro, pat, out var gc1);
            Check("GameWide 规则 A：本帧第一次画 T_out = 合成", DrawClass.FirstToOut, gc1);
            var gm2 = g.OnDraw(ro, pat, out var gc2);
            Check("GameWide 规则 A：第二次画 T_out = 界面层、没读改写矩阵 → 原宽居中", "Hud,CenterNative", $"{gc2},{gm2}");
            float x = 0, w = 1568; g.MapViewport(gm2, ref x, ref w);
            Check("GameWide 规则 A：界面视口收进中间（x 142.5、宽 1283）", "142.5,1283", $"{Math.Round(x, 2)},{Math.Round(w, 2)}");
            g.OnRenderTargets(1, 0); g.OnViewport(0, 1564, 720);
            Check("GameWide 规则 A：上屏贴图上的最终合成不是界面层", DrawClass.Scene, ((Func<DrawClass>)(() => { g.OnDraw(ro, pat, out var c); return c; }))());
            g.OnReleaseTexture(2); g.OnPresent(1);
            Check("GameWide 规则 A：合成目标释放后不再当 T_out（回落上屏贴图本身）", 1u, g.OutTexture);
        }

        // ---------- GameWide 子视口（10-23 维护者 实机暗黑3：怒气液体 83×83、血条填充 231×21 各用小视口画，框按原尺寸居中平移了、它们留在游戏坐标）----------
        // 期望手算：区域 1568 宽、w0 = 1283、pad = 142.5、k = 1568/1283；子视口 (58, 83) → x = 142.5 + 58 × 1283/1568 = 189.96、宽 83 × 1283/1568 = 67.91
        {
            var g = new WidenFrame(new WidenRewriter(2346f / 1080f)) { GameWide = true }; var pat = new Rec();
            g.OnCreateTexture(1, 1920, 1080); g.OnCreateTexture(2, 1568, 720);
            var other = new CbufUse { Binding = 4 }; other.Add(20); CbufRead[] ro = { new(7, 0, 768, other) };
            g.OnRenderTargets(2, 0); g.OnViewport(0, 1568, 720); g.OnDraw(ro, pat, out _);
            g.OnRenderTargets(1, 0); g.OnViewport(0, 1564, 720); g.OnFragmentTexture(128, 2); g.OnDraw(ro, pat, out _); g.OnPresent(1);
            g.OnRenderTargets(2, 0); g.OnViewport(0, 1568, 720); g.OnDraw(ro, pat, out _);
            var fm = g.OnDraw(ro, pat, out _);   // 框 / 底：界面层、原尺寸居中
            g.OnViewport(58, 83, 83);
            var sm = g.OnDraw(ro, pat, out var sc);
            float x = 58, w = 83; g.MapViewport(sm, ref x, ref w);
            Check("GameWide 子视口：框原尺寸居中时，区域里的小视口同样居中（x 189.96、宽 67.91）", $"CenterNative,CenterNative,Hud,{189.96},{67.91}", $"{fm},{sm},{sc},{Math.Round(x, 2)},{Math.Round(w, 2)}");
            g.OnViewport(1500, 200, 40);
            Check("GameWide 子视口：越出区域的小视口不算（不是原生宽、原样）", "Keep", g.OnDraw(ro, pat, out _).ToString());
            g.OnRenderTargets(1, 0); g.OnViewport(0, 1564, 720); var lm = g.OnDraw(ro, pat, out _);
            g.OnViewport(100, 200, 40);
            Check("GameWide 子视口：框没居中（场景 / 按游戏坐标画）时子视口也不动", $"{lm},Keep", $"{lm},{g.OnDraw(ro, pat, out _)}");
        }

        // ---------- 整屏副本（原生宽目标上的界面层外推判据，10-21 塞尔达菜单底图缺两侧）----------
        // 期望按定义手算：屏幕比 2346/1080 = 2.1722；1564/720 = 2.1722 是整屏画面；1280/720 = 1.778（差 18%）不是，除非是整屏画面的缩拷副本。
        // 旧代码反证：旧规则外推只放行 ≤8×8 小图 → 320×180 底图面板不推、只占 [142, 1422)（回放读数见 graphics/widen/README.md「整屏副本」）。
        {
            var g = new WidenFrame(new WidenRewriter(2346f / 1080f)) { GameWide = true };
            Check("整屏画面：1564×720（屏幕比）", true, g.IsScreenAspect(1564, 720));
            Check("整屏画面：782×360（屏幕比缩半）", true, g.IsScreenAspect(782, 360));
            Check("整屏画面：1280×720（16:9）不是", false, g.IsScreenAspect(1280, 720));
            Check("整屏画面：391×180（屏幕比缩到 1/4，720×2.1722 ÷ 4 = 391.0）", true, g.IsScreenAspect(391, 180));
            Check("整屏画面：界面图 483×224 不是（224 × 2.1722 = 486.6，差 3.6 像素；比例差 0.75% 但不是整屏）", false, g.IsScreenAspect(483, 224));
            Check("整屏副本：320×180 没来历时不是", false, g.IsScreenCopy(4));
            g.OnTargetFilled(3, 1280, 720, g.IsScreenAspect(1564, 720));   // 1564×720 → 1280×720 缩拷
            g.OnTargetFilled(4, 320, 180, g.IsScreenCopy(3));   // 1280×720 → 320×180 再缩
            Check("整屏副本：采样整屏画面铺满的 1280×720", true, g.IsScreenCopy(3));
            Check("整屏副本：链式传下去（320×180）", true, g.IsScreenCopy(4));
            g.OnTargetFilled(4, 320, 180, false);   // 同一张目标上铺满视口叠画小图标：来历不变
            Check("整屏副本：叠画没采样整屏画面的绘制不改来历", true, g.IsScreenCopy(4));
            g.OnTargetFilled(5, 61, 540, true);   // 整屏的一条裁拷（冒険手帳页毛玻璃面板）：比例既不是 16:9 也不是屏幕比
            Check("整屏副本：61×540 局部裁拷不算（16:9 应 960 宽、屏幕比应 1173 宽）", false, g.IsScreenCopy(5));
            g.OnTargetCleared(4);
            Check("整屏副本：游戏清掉目标后不再是", false, g.IsScreenCopy(4));
            g.OnReleaseTexture(3);
            Check("整屏副本：释放后不再是", false, g.IsScreenCopy(3));
            var off = new WidenFrame(new WidenRewriter(16f / 9f)) { GameWide = true };
            Check("16:9 屏幕（宽屏关）：没有整屏画面这回事", false, off.IsScreenAspect(1280, 720));

        }

        // ---------- 原画框外推写侧：顶点位置求值（SpirvPosSlice，10-23 八方2 存档菜单模糊链图集子块）----------
        {
            // 手拼：x = 2·fma(attr0.x, cb4[0].x, cb4[0].z) − 1；cb4[0].x ≤ 0 时走另一支 x = −5（分支 + OpPhi）；写 gl_PerVertex.Position = (x, 0, 0, 1)
            var v = new List<uint> { 0x07230203, 0x00010000, 0, 60, 0 };
            void J(int op, params uint[] a) { v.Add((uint)((a.Length + 1) << 16 | op)); v.AddRange(a); }
            J(11, 21, 0x4c534c47, 0x6474732e, 0x3035342e, 0);   // OpExtInstImport %21 "GLSL.std.450"
            J(15, 0, 8, 0x6e69616d, 0, 7, 12);                  // OpEntryPoint Vertex %8 "main" %7 %12
            J(71, 12, 30, 0); J(71, 17, 33, 4); J(71, 13, 6, 16); J(72, 15, 0, 35, 0); J(72, 5, 0, 11, 0);
            J(19, 1); J(33, 2, 1); J(22, 3, 32); J(23, 4, 3, 4); J(30, 5, 4); J(32, 6, 3, 5); J(21, 10, 32, 1);
            J(43, 10, 14, 16); J(43, 10, 19, 0); J(43, 10, 20, 2); J(28, 13, 4, 14); J(30, 15, 13); J(32, 16, 2, 15); J(32, 18, 2, 3); J(32, 11, 1, 4); J(32, 22, 3, 4); J(20, 27);
            J(43, 3, 23, 0x40000000); J(43, 3, 24, 0x3f800000); J(43, 3, 25, 0); J(43, 3, 26, 0xc0a00000);
            J(59, 6, 7, 3); J(59, 11, 12, 1); J(59, 16, 17, 2);
            J(54, 1, 8, 0, 2); J(248, 9);
            J(61, 4, 30, 12); J(81, 3, 31, 30, 0); J(65, 18, 32, 17, 19, 19, 19); J(61, 3, 33, 32); J(65, 18, 34, 17, 19, 19, 20); J(61, 3, 35, 34);
            J(12, 3, 36, 21, 50, 31, 33, 35); J(186, 27, 37, 33, 25); J(247, 42, 0); J(250, 37, 40, 41);
            J(248, 40); J(133, 3, 43, 36, 23); J(131, 3, 44, 43, 24); J(249, 42);
            J(248, 41); J(249, 42);
            J(248, 42); J(245, 3, 45, 44, 40, 26, 41); J(80, 4, 46, 45, 25, 25, 24); J(65, 22, 47, 7, 19); J(62, 47, 46); J(253); J(56);
            byte[] vs = MemoryMarshal.AsBytes(v.ToArray().AsSpan()).ToArray();
            var ps = SpirvPosSlice.Extract(vs, out string why);
            Check("位置求值：手拼顶点着色器认得出", "认得出", ps != null ? "认得出" : why);
            var env = new PosEnv1023(); float X(float ax, float sc, float of) { env.Ax = ax; env.Cb[0] = sc; env.Cb[2] = of; return ps != null && ps.Eval(env, out float x, out float w) ? x / w : float.NaN; }
            Check("子块：单位四边形 × (0.5, 0) → x 从 −1 到 0（只盖左半画布）", "-1 0", $"{X(0, 0.5f, 0)} {X(1, 0.5f, 0)}");
            Check("铺满：× (1, 0) → x 从 −1 到 1", "-1 1", $"{X(0, 1, 0)} {X(1, 1, 0)}");
            Check("分支：常量 ≤ 0 走另一支（OpPhi 取 −5）", "-5", $"{X(0, -1, 0)}");
            // 求值复用存储（10-23 巫师3 新几何帧分配）：热身一次后再求 200 次，期望本线程分配 0 字节、结果不变
            {
                X(1, 0.5f, 0); long a0 = GC.GetAllocatedBytesForCurrentThread(); float last = 0;
                for (int k = 0; k < 200; k++) last = X(1, 0.5f, 0);
                Check("求值复用存储：热身后 200 次求值分配 0 字节、结果仍 0", "0 0", $"{GC.GetAllocatedBytesForCurrentThread() - a0} {last}");
            }
            env.UboOk = false;
            Check("读不到常量（分支条件未知）→ 判不出", "分支条件未知", ps != null && !ps.Eval(env, out _, out _) ? ps.LastFail : "算出来了");
            env.UboOk = true;
            { uint[] fw = v.ToArray(); int ep = 5 + 6; fw[ep + 1] = 4; Check("入口不是顶点（改成片元）：抽不出", true, SpirvPosSlice.Extract(MemoryMarshal.AsBytes(fw.AsSpan()).ToArray(), out _) == null); }
            string pf = Path.Combine(Path.GetTempPath(), $"wpos_{Environment.ProcessId}.bin");
            if (ps != null) PosFile.Write(pf, new[] { new KeyValuePair<ulong, byte[]>(42, ps.Packed), new KeyValuePair<ulong, byte[]>(43, ps.Packed) });
            PosFile pfo = PosFile.Open(pf); var back = pfo?.Get(42);
            {   // 10-23 马车8 首帧：载程序时不解析、按键缓存——同键再取是同一对象且 0 字节；没有的键 null；另一个键另解析一份
                long a0 = GC.GetAllocatedBytesForCurrentThread(); var again = pfo?.Get(42); long a1 = GC.GetAllocatedBytesForCurrentThread();
                Check("widen_pos.bin 同键再取：同一对象、分配 0 字节", "True 0", $"{again != null && ReferenceEquals(again, back)} {a1 - a0}");
                Check("widen_pos.bin：有没有键（不解析）/ 没有的键取出 null / 另一个键是另一份", "True False True True", $"{pfo?.Has(43)} {pfo?.Has(44)} {pfo?.Get(44) == null} {pfo?.Get(43) is { } o43 && !ReferenceEquals(o43, back)}");
            }
            File.Delete(pf);
            Check("widen_pos.bin 往返后同样算（子块 x = 0）", "0", back != null && back.Eval(new PosEnv1023 { Ax = 1, Cb = { [0] = 0.5f, [2] = 0 } }, out float bx, out float bw) ? $"{bx / bw}" : "读不回");
        }

        // ---------- P2-35：OpSDiv 有符号除法、向零截断与未知传播（期望手算）----------
        {
            SpirvPosSlice BuildSDiv(int a, int b, bool vector = false, int a1 = 0, int b1 = 1, uint lane = 0)
            {
                var words = new List<uint> { 0x07230203, 0x00010000, 0, 32, 0 };
                void J(int op, params uint[] args) { words.Add((uint)((args.Length + 1) << 16 | op)); words.AddRange(args); }
                J(17, 1); J(14, 0, 1);             // Shader；Logical / GLSL450
                J(15, 0, 9, 0x6e69616d, 0, 8);    // Vertex %9 "main" %8
                J(71, 8, 11, 0);                  // %8 BuiltIn Position
                J(19, 1); J(33, 2, 1);             // void；void()
                J(22, 3, 32); J(23, 4, 3, 4);      // float32；vec4
                J(21, 5, 32, 1); J(23, 6, 5, 2);   // signed int32；ivec2
                J(32, 7, 3, 4);                    // Output vec4*
                J(43, 3, 11, 0); J(43, 3, 12, 0x3f800000); // float 0 / 1
                J(43, 5, 13, unchecked((uint)a)); J(43, 5, 14, unchecked((uint)b));
                J(43, 5, 15, unchecked((uint)a1)); J(43, 5, 16, unchecked((uint)b1));
                if (vector) { J(44, 6, 17, 13, 15); J(44, 6, 18, 14, 16); }
                J(59, 7, 8, 3); J(54, 1, 9, 0, 2); J(248, 10);
                if (vector) { J(135, 6, 19, 17, 18); J(81, 5, 20, 19, lane); } // SDiv ivec2 → 取分量
                else J(135, 5, 20, 13, 14);         // SDiv int
                J(111, 3, 21, 20);                 // ConvertSToF，不能用 Bitcast 冒充数值转换
                J(80, 4, 22, 21, 11, 11, 12);      // Position=(result,0,0,1)
                J(62, 8, 22); J(253); J(56);
                var ps = SpirvPosSlice.Extract(MemoryMarshal.AsBytes(words.ToArray().AsSpan()).ToArray(), out string why);
                Check("SDiv 手拼模块能提取", "成功", ps != null ? "成功" : why);
                return ps;
            }
            void AssertSDiv(string name, SpirvPosSlice ps, float? expected)
            {
                if (ps == null) return; // 提取失败已计红，不当作成功的未知值。
                bool known = ps.Eval(new PosEnv1023(), out float x, out float w);
                Check(name + "：是否已知", expected.HasValue, known);
                if (expected.HasValue)
                {
                    Check(name + "：x", expected.Value, x);
                    Check(name + "：w", 1f, w);
                }
                else Check(name + "：未知原因", "位置依赖未知值", ps.LastFail);
            }
            AssertSDiv("SDiv 7/-1=-7", BuildSDiv(7, -1), -7f);
            AssertSDiv("SDiv -7/2=-3（向零截断）", BuildSDiv(-7, 2), -3f);
            AssertSDiv("SDiv -7/-1=7", BuildSDiv(-7, -1), 7f);
            AssertSDiv("SDiv 7/-2=-3", BuildSDiv(7, -2), -3f);
            AssertSDiv("SDiv 7/2=3", BuildSDiv(7, 2), 3f);
            AssertSDiv("SDiv 0/-1=0", BuildSDiv(0, -1), 0f);
            AssertSDiv("SDiv MinValue/1=MinValue", BuildSDiv(int.MinValue, 1), (float)int.MinValue);
            AssertSDiv("SDiv 除0为未知", BuildSDiv(7, 0), null);
            AssertSDiv("SDiv MinValue/-1为未知", BuildSDiv(int.MinValue, -1), null);
            AssertSDiv("SDiv vector lane0 signed", BuildSDiv(7, -1, true, -7, 2, 0), -7f);
            AssertSDiv("SDiv vector lane1 signed", BuildSDiv(7, -1, true, -7, 2, 1), -3f);
            // 整值 Unknown：非法分量不能使另一个分量成为伪造的已知位置。
            AssertSDiv("SDiv 后lane除0，提取前lane仍未知", BuildSDiv(7, -1, true, 7, 0, 0), null);
            AssertSDiv("SDiv 后lane溢出，提取前lane仍未知", BuildSDiv(7, -1, true, int.MinValue, -1, 0), null);
            AssertSDiv("SDiv 前lane除0，提取后lane仍未知", BuildSDiv(7, 0, true, -7, 2, 1), null);
        }

        // ---------- 界面层越界顶点外推（手拼 Ryujinx 形态：gl_PerVertex 块成员 0 = Position、support_buffer 第 8 / 9 / 10 成员 ivec4（s2a_flags / s2a_point / s2a_widen）、main 一个 OpReturn）----------
        {
            // %1 void、%2 fn、%3 float、%4 vec4、%5 gl_PerVertex、%6 Output 块指针、%7 块变量、%8 main、%9 label、
            // %10 int、%11 ivec4、%12 support_buffer 结构（8 个 int + s2a_flags ivec4 + s2a_point ivec4 [+ s2a_widen ivec4]）、%13 Uniform 结构指针、%14 support_buffer 变量
            // layout：0 = 0066 之前（8 + s2a_flags，9 个成员，没有 s2a_widen）、1 = 0066（+ s2a_widen，10 个）、2 = 0093 起（s2a_widen 前插 s2a_point，11 个）
            List<uint> Build(int layout)
            {
                var v = new List<uint> { 0x07230203, 0x00010000, 0, 20, 0 };
                void J(int op, params uint[] a) { v.Add((uint)((a.Length + 1) << 16 | op)); v.AddRange(a); }
                J(15, 0, 8, 0x6e69616d, 0, 7);   // OpEntryPoint Vertex %8 "main" %7
                J(72, 5, 0, 11, 0);              // OpMemberDecorate %5 0 BuiltIn Position
                J(71, 14, 33, 0);                // OpDecorate %14 Binding 0
                J(19, 1); J(33, 2, 1); J(22, 3, 32); J(23, 4, 3, 4); J(30, 5, 4); J(32, 6, 3, 5); J(59, 6, 7, 3);
                J(21, 10, 32, 1); J(23, 11, 10, 4);
                if (layout == 2) J(30, 12, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11); else if (layout == 1) J(30, 12, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11); else J(30, 12, 10, 10, 10, 10, 10, 10, 10, 10, 11);
                J(32, 13, 2, 12); J(59, 13, 14, 2);
                J(54, 1, 8, 0, 2); J(248, 9); J(253); J(56);
                return v;
            }
            byte[] spv = MemoryMarshal.AsBytes(Build(2).ToArray().AsSpan()).ToArray();
            byte[] o = SpirvEdgePush.Patch(spv, out int ret);
            Check("越界外推：顶点着色器改了", true, o != null);
            Check("越界外推：插在 1 个返回点前", 1, ret);
            uint[] w = o == null ? Array.Empty<uint>() : MemoryMarshal.Cast<byte, uint>(o).ToArray();
            var fc = new List<float>(); var ops = new List<int>();
            for (int i = 5; i < w.Length;) { int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff); ops.Add(op); if (op == 43 && n == 4 && w[i + 1] == 3) fc.Add(BitConverter.UInt32BitsToSingle(w[i + 3])); i += n; }
            Check("参数从 support_buffer.s2a_widen 读（三次 OpBitcast：外推量 / 门限² / 收缩量，一次 OpFNegate，一次 OpFSub = 1 − 收缩量）", "3,1,1", $"{ops.FindAll(x => x == 124).Count},{ops.FindAll(x => x == 127).Count},{ops.FindAll(x => x == 131).Count}");
            int iX = ops.IndexOf(81), iMul = ops.IndexOf(133), iDiv = ops.IndexOf(136);
            Check("先横向收缩再判画布边：取 x（OpCompositeExtract）→ 乘（OpFMul）→ 除以 w（OpFDiv）", true, iX >= 0 && iX < iMul && iMul < iDiv);
            var ic = new List<uint>(); for (int i = 5; i < w.Length;) { int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff); if (op == 43 && n == 4 && w[i + 1] != 3) ic.Add(w[i + 3]); i += n; }
            Check("取的是第 10 成员（s2a_widen，0093 起 s2a_point 插在它前面）的 x / y / z 分量：整数常量含 10、0、1、2", true, ic.Contains(10) && ic.Contains(0) && ic.Contains(1) && ic.Contains(2));
            Check("着色器里没有与屏幕有关的浮点常量（只剩 0、收缩用的 1、屏幕边 (1−3‰)²、窄带比 ((1+3‰)/(1−3‰))²）", $"0,1,{SpirvEdgePush.Screen2},{SpirvEdgePush.BandRatio2}", string.Join(",", fc));
            int at = ops.IndexOf(253);
            Check("返回前最后一条 = 写回 Position（OpStore）", 62, at > 0 ? ops[at - 1] : -1);
            Check("id 上界只增不减", true, w.Length > 3 && w[3] > 20);
            Check("支持缓冲没有 s2a_widen（0066 之前，9 个成员）→ 不改", true, SpirvEdgePush.Patch(MemoryMarshal.AsBytes(Build(0).ToArray().AsSpan()).ToArray(), out _) == null);
            byte[] o1 = SpirvEdgePush.Patch(MemoryMarshal.AsBytes(Build(1).ToArray().AsSpan()).ToArray(), out _);
            var ic1 = new List<uint>(); if (o1 != null) { uint[] w1 = MemoryMarshal.Cast<byte, uint>(o1).ToArray(); for (int i = 5; i < w1.Length;) { int n = (int)(w1[i] >> 16), op = (int)(w1[i] & 0xffff); if (op == 43 && n == 4 && w1[i + 1] != 3) ic1.Add(w1[i + 3]); i += n; } }
            Check("0066 布局（10 个成员，旧录像）→ 照改、取第 9 成员", true, o1 != null && ic1.Contains(9) && !ic1.Contains(10));
            {   // 推哪些顶点（按改后着色器解释执行，期望手算）：着色器把属性 0 原样写进 Position；k = 2346/1920，1/k = 0.81841，外推量 d = 1 − 1/k
                var q = new List<uint> { 0x07230203, 0x00010000, 0, 21, 0 };
                void J(int op, params uint[] a) { q.Add((uint)((a.Length + 1) << 16 | op)); q.AddRange(a); }
                J(15, 0, 8, 0x6e69616d, 0, 7, 15);
                J(72, 5, 0, 11, 0); J(71, 14, 33, 0); J(71, 14, 34, 0); J(71, 12, 2); J(71, 15, 30, 0);
                for (uint m = 0; m < 11; m++) J(72, 12, m, 35, m < 8 ? m * 4 : 32 + (m - 8) * 16);
                J(19, 1); J(33, 2, 1); J(22, 3, 32); J(23, 4, 3, 4); J(30, 5, 4); J(32, 6, 3, 5); J(59, 6, 7, 3);
                J(21, 10, 32, 1); J(23, 11, 10, 4); J(30, 12, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11); J(32, 13, 2, 12); J(59, 13, 14, 2);
                J(32, 16, 1, 4); J(59, 16, 15, 1); J(32, 17, 3, 4); J(43, 10, 18, 0);
                J(54, 1, 8, 0, 2); J(248, 9); J(61, 4, 19, 15); J(65, 17, 20, 7, 18); J(62, 20, 19); J(253); J(56);
                byte[] pq = SpirvEdgePush.Patch(MemoryMarshal.AsBytes(q.ToArray().AsSpan()).ToArray(), out _);
                SpirvPosSlice sl = pq == null ? null : SpirvPosSlice.Extract(pq, out _);
                float kk = 2346f / 1920f, inv = 1f / kk, dd = 1f - inv;
                var (te2, td) = SpirvEdgePush.Params(kk);
                string X(float x, float z) { var env = new EdgeEnv { X = x, D = td, E2 = te2, Z = z }; return sl != null && sl.Eval(env, out float px, out float pw) ? (px / pw).ToString("F4") : "算不出"; }
                Check("越界外推（不收缩）：贴着 16:9 边界的顶点 x = −1/k 推到屏幕边 −1", (-1f).ToString("F4"), X(-inv, 0));
                Check("越界外推（不收缩）：边界窄带里 x = 1/k × 1.002 推出 d", (inv * 1.002f + dd).ToString("F4"), X(inv * 1.002f, 0));
                Check("越界外推（不收缩）：游戏自己排在边界外侧的 x = −0.95 不动（10-23 暗黑3 HUD）", (-0.95f).ToString("F4"), X(-0.95f, 0));
                Check("越界外推（不收缩）：画布里的 x = −0.5 不动", (-0.5f).ToString("F4"), X(-0.5f, 0));
                // 撤窄带（10-24）：不收缩的外推核心给极小收缩量 NoBandZ → 着色器走「一律推」：动森转场黑板 x = −1.15/k 推出 d，画布里几乎不动
                float nb = WidenFrame.NoBandZ;
                Check("越界外推（z = NoBandZ）：转场黑板 x = −1.15/k 推出 d", (-1.15f * inv * (1 - nb) - dd).ToString("F4"), X(-1.15f * inv, nb));
                Check("越界外推（z = NoBandZ）：画布里的 x = −0.5 不推", (-0.5f * (1 - nb)).ToString("F4"), X(-0.5f, nb));
                // 已在屏幕边上及外的顶点不推（11-05）：裁剪空间写死的全屏三角形 (−1, 3) 推成 (−1 − d, 3 + d) 后插值的采样坐标整体左移 pad/2
                //   （旷野之息宽屏整套放宽光照合成：一深一浅两个林克）；旧逻辑这两例给 −1 − d、3 + d（负对照见提交说明）
                Check("越界外推（z = NoBandZ）：全屏三角形顶点 x = −1（屏幕边）不推", (-1f * (1 - nb)).ToString("F4"), X(-1f, nb));
                Check("越界外推（z = NoBandZ）：全屏三角形顶点 x = 3（屏幕外）不推", (3f * (1 - nb)).ToString("F4"), X(3f, nb));
                Check("越界外推（z = NoBandZ）：画布外、屏幕内 x = 0.99 照推出 d", (0.99f * (1 - nb) + dd).ToString("F4"), X(0.99f, nb));
                {   var fr = new WidenFrame(new WidenRewriter(2346f / 1080f));
                    fr.PushParams(true, false, out _, out _, out float zn); fr.PushParams(false, false, out _, out _, out float zo);
                    Check("外推参数：不收缩 z = NoBandZ（撤窄带）、不外推 z = 0", $"{nb} 0", $"{zn} {zo}"); }
                Check("越界外推（收缩 z = 1 − 1/k）：画布边 x = −1 收到 −1/k 再推到 −1", (-1f).ToString("F4"), X(-1f, dd));
                Check("越界外推（收缩）：画布外的 x = −1.1 收到 −1.1/k 照旧推出 d（原尺寸居中层画布外的元素不进两侧）", (-1.1f * inv - dd).ToString("F4"), X(-1.1f, dd));
                Check("越界外推（收缩）：x = 3 收到 3/k 已在屏幕外，不再推", (3f * inv).ToString("F4"), X(3f, dd));
            }
            var vv = Build(2); vv[5 + 1] = 4;   // 执行模型改成片元
            Check("片元着色器不改", true, SpirvEdgePush.Patch(MemoryMarshal.AsBytes(vv.ToArray().AsSpan()).ToArray(), out _) == null);
            float k = 2346f / 1920f; var (e2, d) = SpirvEdgePush.Params(k);
            Check("包装层写的参数：门限² = ((1−3‰)/k)²、外推量 = 1 − 1/k", true, e2 == (1f - 3e-3f) / k * ((1f - 3e-3f) / k) && d == 1f - 1f / k);
            Check("运行时与出包同一入口：WidenShaders.Vertex 与 SpirvEdgePush.Patch 逐字节相同", true, o != null && WidenShaders.Vertex(spv, out bool pv).AsSpan().SequenceEqual(o) && pv);

            // 采样绑定：%1 float、%2 image、%3 sampled image、%4 指针 UniformConstant、%5 变量 Binding 128
            var t = new List<uint> { 0x07230203, 0x00010000, 0, 8, 0 };
            void T(int op, params uint[] a) { t.Add((uint)((a.Length + 1) << 16 | op)); t.AddRange(a); }
            T(71, 5, 33, 128); T(22, 1, 32); T(25, 2, 1, 1, 0, 0, 0, 1, 0); T(27, 3, 2); T(32, 4, 0, 3); T(59, 4, 5, 0);
            int[] bs = SpirvEdgePush.SampledBindings(MemoryMarshal.AsBytes(t.ToArray().AsSpan()).ToArray());
            Check("片元采样绑定号认出 128", "128", string.Join(",", bs));
        }

        // ---------- 原画框外推（10-22 八方2 暗角）：手拼 Ryujinx 形态片元——uv 插值（location 0，noperspective）、FragCoord.x ÷ render_scale[0]、
        //            采样绑定 128 的 2D 组合采样器，坐标 = (uv.x, x ÷ 缩放)；support_buffer 10 个成员，第 5 个 float[73]、最后一个 ivec4（s2a_widen） ----------
        {
            List<uint> Fs(uint texBinding, uint uvLoc)
            {
                var v = new List<uint> { 0x07230203, 0x00010300, 0, 39, 0 };
                void J(int op, params uint[] a) { v.Add((uint)((a.Length + 1) << 16 | op)); v.AddRange(a); }
                J(17, 1); J(14, 0, 1); J(15, 4, 27, 0x6e69616d, 0, 14, 15, 17); J(16, 27, 7);
                J(71, 14, 11, 15); J(71, 15, 30, uvLoc); J(71, 15, 13); J(71, 17, 30, 0); J(71, 21, 34, 2); J(71, 21, 33, texBinding); J(71, 12, 34, 0); J(71, 12, 33, 0); J(71, 10, 2); J(71, 9, 6, 16);
                uint[] off = { 0, 4, 8, 12, 16, 32, 1200, 1204, 1208, 1216 }; for (uint m = 0; m < 10; m++) J(72, 10, m, 35, off[m]);
                J(19, 1); J(33, 2, 1); J(22, 3, 32); J(23, 4, 3, 4); J(21, 5, 32, 1); J(21, 6, 32, 0); J(23, 7, 5, 4); J(43, 6, 8, 73); J(28, 9, 3, 8);
                J(30, 10, 3, 3, 3, 3, 3, 9, 3, 3, 3, 7); J(32, 11, 2, 10); J(59, 11, 12, 2); J(32, 13, 1, 4); J(59, 13, 14, 1); J(59, 13, 15, 1); J(32, 16, 3, 4); J(59, 16, 17, 3);
                J(25, 18, 3, 1, 0, 0, 0, 1, 0); J(27, 19, 18); J(32, 20, 0, 19); J(59, 20, 21, 0); J(32, 22, 1, 3); J(32, 23, 2, 3); J(43, 5, 24, 0); J(43, 5, 25, 5); J(23, 26, 3, 2);
                J(54, 1, 27, 0, 2); J(248, 28);
                J(65, 22, 29, 14, 24); J(61, 3, 30, 29); J(65, 23, 31, 12, 25, 24); J(61, 3, 32, 31); J(136, 3, 33, 30, 32);
                J(65, 22, 34, 15, 24); J(61, 3, 35, 34); J(61, 19, 36, 21); J(80, 26, 37, 35, 33); J(87, 4, 38, 36, 37); J(62, 17, 38); J(253); J(56);
                return v;
            }
            byte[] Bs(List<uint> v) => MemoryMarshal.AsBytes(v.ToArray().AsSpan()).ToArray();
            static List<(int Op, uint[] W)> Ins(byte[] b)
            {
                var r = new List<(int, uint[])>(); uint[] w = MemoryMarshal.Cast<byte, uint>(b).ToArray();
                for (int i = 5; i < w.Length;) { int n = (int)(w[i] >> 16); r.Add(((int)(w[i] & 0xffff), w.AsSpan(i, n).ToArray())); i += n; }
                return r;
            }
            byte[] src = Bs(Fs(128, 0));
            byte[] o = SpirvExtrap.PatchFragment(src, 5, Array.Empty<(int, int, bool)>(), out var smp, out string why);
            Check("原画框外推：片元改了", "改了", o != null ? "改了" : why);
            var ins = o != null ? Ins(o) : new List<(int Op, uint[] W)>();
            // 10-23 起不动顶点：不新增输入（已有 gl_FragCoord，入口接口仍 3 个），插值按 v + dFdx(v)·((x − pad)·k − x) 换算——只对 uv 插值取一次 dFdx
            var ep = ins.Find(x => x.Op == 15).W;
            Check("不新增输入：入口接口仍 3 个、没有 location 31 装饰", "3,False", $"{(ep == null ? -1 : ep.Length - 5)},{ins.Exists(x => x.Op == 71 && x.W[2] == 30 && x.W[3] == 31)}");
            Check("一次 dFdx：uv 插值", 1, ins.FindAll(x => x.Op == 207).Count);
            // 片元坐标：FDiv 的被除数换成 FSub(原 x %30, pad)
            var div = ins.Find(x => x.Op == 136 && x.W[2] == 33).W; uint dvd = div?[3] ?? 0;
            var sub = ins.Find(x => x.Op == 131 && x.W[2] == dvd).W;
            Check("片元坐标 x ÷ render_scale[0] 前先减 pad：FDiv 的被除数 = FSub(%30, …)", "30", sub != null ? $"{sub[3]}" : "没有");
            // 采样坐标换了（CompositeInsert 出的新坐标），采样项 = (1 + 128 − 128, 128)
            var sm = ins.Find(x => x.Op == 87).W; uint nc = sm?[4] ?? 0;
            Check("采样坐标换成 x·a + c 插回的新向量（不再是 %37）", "82", ins.Find(x => x.W.Length > 2 && x.W[2] == nc && x.Op != 87).Op.ToString());
            Check("外推采样项（render_scale 下标, 绑定号）= (1, 128)", "1:128", string.Join(",", Array.ConvertAll(smp, x => $"{x.Index}:{x.Binding}")));
            Check("补能力 ImageQuery（50）", true, ins.Exists(x => x.Op == 17 && x.W[1] == 50));
            // 读 uv.x 的 OpLoad %35 换成从修正值取分量（OpCompositeExtract … 0）
            var l35 = ins.Find(x => x.W.Length > 2 && x.W[2] == 35).W;
            Check("读插值 uv.x（%35）改成从修正值取第 0 分量", "81,0", l35 != null ? $"{l35[0] & 0xffff},{l35[^1]}" : "没有");
            // pad 从 s2a_widen.w 读：AccessChain(support_buffer, 9, 3)
            bool padRead = false; uint c9 = 0, c3 = 0; foreach (var (op, w) in ins) if (op == 43 && w[1] == 5) { if (w[3] == 9) c9 = w[2]; if (w[3] == 3) c3 = w[2]; }
            foreach (var (op, w) in ins) if (op == 65 && w.Length == 6 && w[3] == 12 && w[4] == c9 && w[5] == c3) padRead = true;
            Check("pad 从 support_buffer 最后成员（s2a_widen）的 w 分量读", true, padRead);
            bool kRead = false; uint c1k = 0; foreach (var (op, w) in ins) if (op == 43 && w[1] == 5 && w[3] == 1) c1k = w[2];
            foreach (var (op, w) in ins) if (op == 65 && w.Length == 6 && w[3] == 12 && w[4] == c9 && w[5] == c1k) kRead = true;
            Check("放宽比 k 从 s2a_widen 的 y 分量读", true, kRead);
            Check("运行时与出包同一入口：WidenShaders.Fragment（exact）结果与 PatchFragment 逐字节相同", true,
                o != null && WidenShaders.Fragment(src, true, out _, out _, out bool ex1, out bool fx1, out _).AsSpan().SequenceEqual(o) && ex1 && fx1);
            // 本款不外推（游戏自己出宽 / 16:9 款）：不注入外推代码，结果同只做片元 y / 取图缩放（10-23 塞尔达：分支里不执行的导数也改了苹果 GPU 输出）
            byte[] noEx = WidenShaders.Fragment(src, false, out _, out _, out _, out bool fx0, out var es0);
            byte[] onlyFs = SpirvFetchScale.PatchY(SpirvFragCoord.PatchY(src, 5, out _, out _), 5, out _, out _, out _);
            Check("不外推的款：不注入外推、采样表空、结果同只改片元 y / 取图缩放", "False 0 True", $"{fx0} {es0.Length} {noEx.AsSpan().SequenceEqual(onlyFs)}");
            Check("贴图绑定只从 162 起（顶点按计算着色器跑的程序）：不改", "顶点按计算着色器跑的程序（片元贴图绑定从 162 起）", SpirvExtrap.PatchFragment(Bs(Fs(162, 0)), 5, null, out _, out string w4) == null ? w4 : "改了");
            Check("取图缩放项的下标与绑定号对不上口径（下标 2、绑定 128）：不改", "缩放下标 2 与绑定号 128 对不上口径", SpirvExtrap.PatchFragment(src, 5, new[] { (2, 128, false) }, out _, out string w5) == null ? w5 : "改了");
            if (o != null && File.Exists("/opt/homebrew/bin/spirv-val"))
            {
                string fv = Path.Combine(Path.GetTempPath(), $"widen_unit_ex_{Environment.ProcessId}.spv"); File.WriteAllBytes(fv, o);
                var pv = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("/opt/homebrew/bin/spirv-val", $"--target-env vulkan1.1 {fv}") { RedirectStandardError = true, RedirectStandardOutput = true });
                string er = pv.StandardError.ReadToEnd() + pv.StandardOutput.ReadToEnd(); pv.WaitForExit(); File.Delete(fv);
                Check("改后片元 spirv-val（Vulkan 1.1）", "过", pv.ExitCode == 0 ? "过" : er.Trim());
            }
        }

        // ---------- 画面分层图集按需放宽（WidenFrame.LayerWiden，10-23 八方2 景深近 / 远两层 448×252 竖拼成 448×544）----------
        // 期望手算：896×504 放宽后同族；448 = 896 ÷ 2、544 在 252 的 2–2.5 倍（504..630）→ 按 448×252 放宽 = 548；方形 / 太高 / 宽不是按级缩的 / GameWide 都不放宽
        {
            var fr = new WidenFrame(new WidenRewriter(A0));
            Check("没有放宽过的 16:9 画面：448×544 不放宽", 448, fr.LayerWiden(3, 448, 544));
            fr.OnCreateTexture(2, 896, 504);
            Check("896×504 放宽后：448×544（两层竖拼）放宽到 548", 548, fr.LayerWiden(4, 448, 544));
            Check("登记进放宽一族（IsWide）", true, fr.IsWide(4));
            Check("448×448（方形，高 < 2×252）不放宽（暗黑2 阴影图 / 查表图那类）", 448, fr.LayerWiden(5, 448, 448));
            Check("448×640（高 > 2.5×252 = 630）不放宽", 448, fr.LayerWiden(6, 448, 640));
            Check("450×544（宽不是按级缩的宽）不放宽", 450, fr.LayerWiden(7, 450, 544));
            var gw = new WidenFrame(new WidenRewriter(A0)) { GameWide = true }; gw.OnCreateTexture(2, 896, 504);
            Check("GameWide 不放宽", 448, gw.LayerWiden(8, 448, 544));
        }
        // ---------- 降采样链 / 可分离模糊中间目标跟着放宽（WidenFrame.LayerWiden 第二种形状，11-07 小小梦魇3 中间暗两侧亮）----------
        // 期望手算：屏幕 2868×1320 → 放宽多出 2·round(960·(2.172727/1.777778 − 1)) = 426 列 / 1920；1280×720 放宽后同族。
        //   20 = 1280 >> 6，23 = ⌈720 / 32⌉（级差 1）→ 放宽到 20 + ⌊20·426/1920⌋ = 24；20×12：12 = ⌈720 / 64⌉（同级）→ 24；
        //   20×64（64 不是 720 按级缩的高）、21×23（21 不是 1280 按级缩的宽）、20×90（90 = 720 >> 3，与宽级差 3）、没有放宽过的画面 → 都不放宽
        {
            var fr = new WidenFrame(new WidenRewriter(A0));
            Check("没有放宽过的 16:9 画面：20×23 不放宽", 20, fr.LayerWiden(10, 20, 23));
            fr.OnCreateTexture(2, 1280, 720);
            Check("1280×720 放宽后：20×23（横向减半一级）放宽到 24", 24, fr.LayerWiden(11, 20, 23));
            Check("登记进放宽一族（IsWide）", true, fr.IsWide(11));
            Check("20×12（两向同级）放宽到 24", 24, fr.LayerWiden(12, 20, 12));
            Check("20×64（高不是按级缩的高）不放宽", 20, fr.LayerWiden(13, 20, 64));
            Check("21×23（宽不是按级缩的宽）不放宽", 21, fr.LayerWiden(14, 21, 23));
            Check("20×90（两向级差 3）不放宽", 20, fr.LayerWiden(15, 20, 90));
            Check("计数：降采样链放宽 2 张", 2L, fr.ChainWidened);
            // 直连顺序（11-07 小小梦魇3 真机）：开遍前按需放宽（LayerWiden），开遍时才第一次登记同一张（OnCreateTexture，同宽）→ 仍按放宽（24）、仍是放宽目标；
            //   释放后同序号重新建同尺寸 → 回到不放宽（20）。旧代码第一次登记就把放宽删了（返回 20、IsWide 假）
            Check("按需放宽后同宽登记：保留放宽 24", 24, fr.OnCreateTexture(11, 20, 23));
            Check("按需放宽后同宽登记：仍是放宽目标", true, fr.IsWide(11));
            fr.OnReleaseTexture(11);
            Check("释放后同序号重建 20×23：不放宽", 20, fr.OnCreateTexture(11, 20, 23));
        }
        // 窄屏（Duo 2670×1878）：同一条降采样链按竖向加高。期望手算：每 1080 行多 2·round(540·(1.777778/1.421725 − 1)) = 270 行；
        //   23 行：92 = 23·4 时 92·270 能被 1080 整除 → 23 + ⌊23·270/1080⌋ = 28；12 行：12·270 = 3240 整除 → 12 + 3 = 15；宽都不变（20）
        {
            var fr = new WidenFrame(new WidenRewriter(2670f / 1878f));
            fr.OnCreateTexture(2, 1280, 720);
            Check("窄屏 20×23：宽不变 20", 20, fr.LayerWiden(11, 20, 23));
            Check("窄屏 20×23：加高到 28", 28, fr.TryTall(11, out _, out int th1) ? th1 : -1);
            fr.LayerWiden(12, 20, 12);
            Check("窄屏 20×12：加高到 15", 15, fr.TryTall(12, out _, out int th2) ? th2 : -1);
            fr.OnCreateTexture(11, 20, 23);
            Check("窄屏按需加高后同尺寸登记：仍加高 28", 28, fr.TryTall(11, out _, out int th3) ? th3 : -1);
        }
        // ---------- 只扫变了的（10-21）：常量缓冲按绑定的区间留影子，上传逐 16 字节比影子，只扫变了的区间（各外扩 48 字节）；GpuSim 模拟 GPU 上的缓冲字节 ----------
        // 期望按定义手算（投影 P00 → P00/K、宽高比对 → 2346/1080、扫的字节 = 变了的粒外扩 48 字节截在上传内），不跑被测实现；「旧代码反证」= 同一份上传按旧做法（WidenRewriter.Rewrite 整段）扫的字节数
        {
            float pK = P00 / K;
            byte[] Layout(float p00A = 1.3579951f)
            {
                var b = new byte[768];
                var pa = Proj(); pa[0] = p00A; pa[5] = p00A * 16f / 9f;
                B(pa).CopyTo(b, 0); B(Proj()).CopyTo(b, 256);
                B(16f / 9f, 9f / 16f).CopyTo(b, 512);
                return b;
            }
            float At(GpuSim g, ulong buf, int off) => BitConverter.ToSingle(g.Buf(buf), off);
            WidenFrame NewFrame() { var f = new WidenFrame(new WidenRewriter(A0)); f.OnCreateTexture(2, 1920, 1080); f.OnCreateTexture(50, 600, 300); return f; }
            byte[] old = new byte[768]; var oldRw = new WidenRewriter(A0);
            oldRw.Rewrite(Layout(), 0, old);
            long oldScan = oldRw.Stats.ScannedBytes;

            {   // 影子只给绑过常量的区间；没绑过的照旧整段扫
                var fr = NewFrame(); var g = new GpuSim();
                g.Up(fr, 9, 0, Layout());
                Check("没绑过常量的缓冲：不留影子（0 字节）、上传整段扫、A / B / 宽高比对都改", $"0 768 {pK} {pK} {A}", $"{fr.Shadow.Bytes} {fr.ScanBytes} {At(g, 9, 0)} {At(g, 9, 256)} {At(g, 9, 512)}");
                fr.OnUniformBound(7, 0, 768);
                Check("绑成常量 [0, 768)：建一页影子（4096 字节）", 4096L, fr.Shadow.Bytes);
            }
            {   // 原样重传 / 变一处 / 矩阵变了
                var fr = NewFrame(); var g = new GpuSim(); fr.OnUniformBound(7, 0, 768);
                g.Up(fr, 7, 0, Layout());
                Check("首次上传（影子未知）：整段扫 768 字节、全改", $"768 {pK} {pK} {A}", $"{fr.ScanBytes} {At(g, 7, 0)} {At(g, 7, 256)} {At(g, 7, 512)}");
                long s0 = fr.ScanBytes; g.Up(fr, 7, 0, Layout());
                Check("首次认出投影 = 相机签名表变了 → 影子全部作废，第二次原样重传整段重扫 768 字节", 768L, fr.ScanBytes - s0);
                s0 = fr.ScanBytes; int w0 = g.Writes;
                g.Up(fr, 7, 0, Layout());
                Check("原样重传：一个字节都不扫、命中原样保留、发出去的仍是改写值、没有另外的写", $"0 {pK} {pK} {A} 0", $"{fr.ScanBytes - s0} {At(g, 7, 0)} {At(g, 7, 256)} {At(g, 7, 512)} {g.Writes - w0}");
                Check("旧代码反证：同一份原样重传旧做法整段扫 768 字节", 768L, oldScan);
                var one = Layout(); B(16f / 9f + 0.5f, 9f / 16f).CopyTo(one, 512);   // 只改宽高比对那 8 字节（粒 32）
                s0 = fr.ScanBytes; g.Up(fr, 7, 0, one);
                Check("只变一粒（[512, 528)）：只判碰到它的单元——矩阵窗口起点 464..512（4 个 × 16）+ 浮点位置 508（4；粒 512 整粒快筛跳过）= 68，A / B 原样保留仍改写、新值不是宽高比对不改", $"68 {pK} {pK} {16f / 9f + 0.5f}", $"{fr.ScanBytes - s0} {At(g, 7, 0)} {At(g, 7, 256)} {At(g, 7, 512)}");
                g.Up(fr, 7, 0, Layout(P00 * 0.5f));   // 镜头变焦：A 换成另一个 16:9 投影
                Check("矩阵变了：当场重扫、发出去的是新 P00/K", P00 * 0.5f / K, At(g, 7, 0));
            }
            {   // 整数最大像素坐标矩形走「只扫变了的」路径（10-23 八方2 第 45 帧：整段扫认得、逐单元判前的两道快筛把整数当成极小浮点筛掉，c4 后来变的那次上传没改写 → 又拉丝）
                // 第一次上传这块是 0，第二次只这一粒变成 (447,251,0,0)：逐单元判要认出、发出去 547（手算同整段扫：448 放宽 548）；旧快筛下发出去 447
                var fr = NewFrame(); var g = new GpuSim(); fr.OnUniformBound(11, 0, 256);
                var z = new byte[256]; g.Up(fr, 11, 0, z); g.Up(fr, 11, 0, z);
                var r2 = new byte[256]; BitConverter.GetBytes(447).CopyTo(r2, 32); BitConverter.GetBytes(251).CopyTo(r2, 36);
                g.Up(fr, 11, 0, r2);
                Check("只变一粒成整数矩形 (447,251,0,0)：逐单元判认出、发出去 x = 547", "547 251", $"{BitConverter.ToInt32(g.Buf(11), 32)} {BitConverter.ToInt32(g.Buf(11), 36)}");
            }
            {   // 非放宽目标读到命中：写回原值；回到放宽目标写改写值（机制同旧）
                var fr = NewFrame(); var g = new GpuSim(); fr.OnUniformBound(7, 0, 768);
                var uA = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) uA.Add(i);
                g.Up(fr, 7, 0, Layout());
                fr.OnRenderTargets(50, 0); fr.OnDraw(new[] { new CbufRead(7, 0, 768, uA) }, g, out _);
                Check("非放宽目标读到 A：写回原值", P00, At(g, 7, 0));
                fr.OnRenderTargets(2, 0); fr.OnDraw(new[] { new CbufRead(7, 0, 768, uA) }, g, out _);
                Check("回到放宽目标：A 重新改写", pK, At(g, 7, 0));
                fr.OnRenderTargets(50, 0); fr.OnDraw(new[] { new CbufRead(7, 0, 768, uA) }, g, out _);
                g.Up(fr, 7, 0, Layout());
                Check("写回原值之后原样重传：发出去的是改写值（同旧：上传即改写），之后读到再写回", pK, At(g, 7, 0));
            }
            {   // 缓冲间拷贝：GPU 上拷过去的是源上已改写的内容（同旧）；命中与影子跟着搬（10-22 起：以前目标那段命中丢掉、影子作废、下次上传整段扫）
                var fr = NewFrame(); var g = new GpuSim(); fr.OnUniformBound(7, 0, 768); fr.OnUniformBound(9, 0, 1024);
                g.Up(fr, 9, 256, Layout());
                g.Copy(fr, 7, 9, 0, 256, 768);   // 源 7 还没上传过：拷过去原值也行，下面看目标重传
                g.Up(fr, 7, 0, Layout());
                g.Copy(fr, 7, 9, 0, 256, 768);
                Check("拷贝：目标拿到源上已改写的 A", pK, At(g, 9, 256));
                long s0 = fr.ScanBytes; g.Up(fr, 9, 256, Layout());
                Check("拷贝后目标原样重传：影子跟着搬过来、内容没变 → 不重扫（0 字节）、照样是改写值", $"0 {pK}", $"{fr.ScanBytes - s0} {At(g, 9, 256)}");
            }
            {   // 相机签名后学到：系数对先上传（签名未知不改），之后别处认出投影 → 影子全部作废 → 系数对原样重传也重扫、改上
                var fr = NewFrame(); var g = new GpuSim(); fr.OnUniformBound(7, 0, 768);
                var pair = new byte[768]; B(1 / P00, 1 / P11).CopyTo(pair, 512);
                g.Up(fr, 7, 0, pair);
                Check("系数对先到：签名未知不改", 1 / P00, At(g, 7, 512));
                g.Up(fr, 9, 0, B(Proj()));
                long s0 = fr.ScanBytes; g.Up(fr, 7, 0, pair);
                Check("学到签名后原样重传：影子已作废、整段重扫 768 字节，1/P00 → K/P00", $"768 {K / P00}", $"{fr.ScanBytes - s0} {At(g, 7, 512)}");
            }
            {   // 矩阵跨两次上传（10-21 暗黑2 按 4 KB 一块传常量）：两次各判不了；之后整段原样上传要重判、改上（同旧整段扫描）
                var fr = NewFrame(); var g = new GpuSim(); fr.OnUniformBound(7, 0, 768);
                g.Up(fr, 9, 0, B(Proj()));   // 先认出镜头（之后不再变签名、不整体作废影子）
                var lay = new byte[768]; B(Proj()).CopyTo(lay, 352);
                g.Up(fr, 7, 0, lay[..384]); g.Up(fr, 7, 384, lay[384..]);
                Check("投影 [352, 416) 跨 [0, 384) / [384, 768) 两次上传：两次都不整个含它，不改（同旧）", P00, At(g, 7, 352));
                long s0 = fr.ScanBytes; g.Up(fr, 7, 0, lay);
                Check("之后整段原样上传：内容没变，但跨界那几粒带边缘位要重判 → 改上", pK, At(g, 7, 352));
                Check("只重判边缘那几粒附近（不是整段 768）", true, fr.ScanBytes - s0 < 768);
                s0 = fr.ScanBytes; g.Up(fr, 7, 0, lay);
                Check("再原样重传：边缘位已清、一个字节都不扫、仍是改写值", $"0 {pK}", $"{fr.ScanBytes - s0} {At(g, 7, 352)}");
            }
            {   // 变了的区间与边缘区间交错（10-22：两者归并成升序，不用 List.Sort——值元组排序在 NativeAOT 下每次分配 48 B）：
                // 跨界投影 [352, 416) 只靠边缘位重判；同一次整段上传里 [64, 80) 与 [512, 576)（新放一个投影）是变了的区间，排在边缘区间两侧
                var fr = NewFrame(); var g = new GpuSim(); fr.OnUniformBound(7, 0, 768);
                g.Up(fr, 9, 0, B(Proj()));
                var lay = new byte[768]; B(Proj()).CopyTo(lay, 352);
                g.Up(fr, 7, 0, lay[..384]); g.Up(fr, 7, 384, lay[384..]);
                var lay2 = (byte[])lay.Clone(); B(7f).CopyTo(lay2, 64); B(Proj()).CopyTo(lay2, 512);
                g.Up(fr, 7, 0, lay2);
                Check("变了的 [64,80) / [512,576) 夹着边缘区间：跨界投影改上", pK, At(g, 7, 352));
                Check("同上：变了的区间里新放的投影改上", pK, At(g, 7, 512));
                Check("同上：[64] 原样（不是矩阵）", 7f, At(g, 7, 64));
            }
            {   // 稳态零分配：每帧分两块传（置边缘位）再整段传、改一个字节（变了的区间 + 边缘区间归并）
                var fr = NewFrame(); fr.OnUniformBound(7, 0, 768);
                byte[] cam = B(Proj()), d64 = new byte[64], lay = new byte[768], dst = new byte[768];
                fr.OnBufferData(9, 0, cam, d64);
                B(Proj()).CopyTo(lay, 352);
                int n = 0;
                void Frame()
                {
                    fr.OnBufferData(7, 0, lay.AsSpan(0, 384), dst); fr.OnBufferData(7, 384, lay.AsSpan(384), dst);
                    lay[64] = (byte)n++; fr.OnBufferData(7, 0, lay, dst);
                }
                for (int i = 0; i < 100; i++) Frame();
                long a0 = GC.GetAllocatedBytesForCurrentThread();
                for (int i = 0; i < 1000; i++) Frame();
                long a1 = GC.GetAllocatedBytesForCurrentThread();
                for (int i = 0; i < 10000; i++) Frame();
                long a2 = GC.GetAllocatedBytesForCurrentThread();
                Console.WriteLine($"     （1000 帧 {a1 - a0} 字节、10000 帧 {a2 - a1} 字节）");
                Check("变了的区间 + 边缘区间归并：稳态每帧托管分配（字节，10000 帧窗口减 1000 帧窗口再 ÷9000；NativeAOT 发布同样要 0）", 0L, ((a2 - a1) - (a1 - a0)) / 9000);
            }
            {   // 删缓冲、号复用：不带旧命中、旧影子
                var fr = NewFrame(); var g = new GpuSim(); fr.OnUniformBound(7, 0, 768);
                var uA = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) uA.Add(i);
                g.Up(fr, 7, 0, Layout()); fr.OnDeleteBuffer(7);
                Check("删缓冲：影子回收", 0L, fr.Shadow.Bytes);
                g.Up(fr, 7, 0, new byte[768]);
                Check("号复用：新缓冲不带旧命中", false, fr.ReadsRewritten(7, 0, 768, uA));
            }
            {   // 稳态零分配：绑定 + 每帧原样重传 + 读
                var fr = NewFrame(); byte[] lay = Layout(), scr = new byte[768];
                var uA = new CbufUse { Binding = 4 }; for (int i = 0; i < 4; i++) uA.Add(i);
                CbufRead[] rd = { new(7, 0, 768, uA) };
                void Frame() { fr.OnUniformBound(7, 0, 768); fr.OnBufferData(7, 0, lay, scr); fr.OnRenderTargets(2, 0); fr.OnDraw(rd, null, out _); fr.OnRenderTargets(50, 0); fr.OnDraw(rd, null, out _); fr.OnPresent(2); }
                for (int i = 0; i < 100; i++) Frame();
                long a0 = GC.GetAllocatedBytesForCurrentThread(); for (int i = 0; i < 1000; i++) Frame();
                long a1 = GC.GetAllocatedBytesForCurrentThread(); for (int i = 0; i < 10000; i++) Frame();
                long a2 = GC.GetAllocatedBytesForCurrentThread();
                Check("只扫变了的：稳态每帧零分配（10000 帧窗口减 1000 帧窗口再 ÷9000）", 0L, ((a2 - a1) - (a1 - a0)) / 9000);
            }
        }

        // ---------- 每帧镜头位姿（CameraTrack）：已知镜头造 VP = P·V，期望值按构造直接算 ----------
        {
            double yaw = 30 * Math.PI / 180, pitch = -10 * Math.PI / 180; double[] C = { 10, 2, -5 };
            double[] f = { Math.Sin(yaw) * Math.Cos(pitch), Math.Sin(pitch), Math.Cos(yaw) * Math.Cos(pitch) };
            double[] up0 = { 0, 1, 0 };
            double[] Cross(double[] a, double[] b) => new[] { a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
            double[] Norm(double[] a) { double n = Math.Sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]); return new[] { a[0] / n, a[1] / n, a[2] / n }; }
            double Dot(double[] a, double[] b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
            double[] sv = Norm(Cross(f, up0)), uv = Cross(sv, f);
            double[,] V = { { sv[0], sv[1], sv[2], -Dot(sv, C) }, { uv[0], uv[1], uv[2], -Dot(uv, C) }, { -f[0], -f[1], -f[2], Dot(f, C) }, { 0, 0, 0, 1 } };
            double fovy = 50 * Math.PI / 180, asp = 2346.0 / 1080, n0 = 0.1, f0 = 1000, ct = 1 / Math.Tan(fovy / 2);
            double[,] P = { { ct / asp, 0, 0, 0 }, { 0, ct, 0, 0 }, { 0, 0, -(f0 + n0) / (f0 - n0), -2 * f0 * n0 / (f0 - n0) }, { 0, 0, -1, 0 } };
            float[] VP = new float[16], PP = new float[16];
            for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) { double a = 0; for (int k2 = 0; k2 < 4; k2++) a += P[i, k2] * V[k2, j]; VP[i * 4 + j] = (float)a; PP[i * 4 + j] = (float)P[i, j]; }
            float[] VPc = new float[16]; for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) VPc[j * 4 + i] = VP[i * 4 + j];
            var use = new CbufUse { Binding = 1 }; for (int i = 0; i < 16; i++) use.Add(i);
            foreach (bool colMajor in new[] { false, true })
            {
                var csh = new CbufShadow(); csh.Cover(7, 0, 256); var cam = new CameraTrack(csh); var chg = new List<(int, int)>();
                byte[] buf = new byte[256];   // 0：纯投影 P（不算）；64：主镜头 VP；128：另一个 VP（只在阴影深度目标上被读）
                MemoryMarshal.AsBytes(PP.AsSpan()).CopyTo(buf.AsSpan(0));
                MemoryMarshal.AsBytes((colMajor ? VPc : VP).AsSpan()).CopyTo(buf.AsSpan(64));
                float[] sh = (float[])VP.Clone(); sh[3] += 50; sh[7] += 20; sh[15] += 3;   // 平移不同的另一个镜头
                MemoryMarshal.AsBytes(sh.AsSpan()).CopyTo(buf.AsSpan(128));
                csh.Write(7, 0, buf, chg, out _);
                var main = new[] { new CbufRead(7, 64, 64, use) }; var shadow = new[] { new CbufRead(7, 128, 64, use) }; var pr = new[] { new CbufRead(7, 0, 64, use) };
                for (int i = 0; i < 320; i++) cam.OnDraw(2, main);   // 场景深度目标 2：320 次读主镜头（每 32 次抽 1 → 计 10）
                for (int i = 0; i < 960; i++) cam.OnDraw(2, pr);    // 读纯投影（不是候选）
                for (int i = 0; i < 160; i++) cam.OnDraw(9, shadow);  // 阴影深度目标 9：40 次
                cam.OnPresent();
                string tag = colMajor ? "列存" : "行存";
                Check($"镜头位姿（{tag}）：认出主镜头", true, cam.Valid && cam.Draws == 10);
                Check($"镜头位姿（{tag}）：位置 = (10, 2, −5)", "10.000,2.000,-5.000", $"{cam.X:F3},{cam.Y:F3},{cam.Z:F3}");
                Check($"镜头位姿（{tag}）：偏航 30°、俯仰 −10°", "30.00,-10.00", $"{cam.Yaw:F2},{cam.Pitch:F2}");
            }
            {
                var csh = new CbufShadow(); csh.Cover(7, 0, 256); var cam = new CameraTrack(csh); var chg = new List<(int, int)>(); byte[] buf = new byte[64]; MemoryMarshal.AsBytes(VP.AsSpan()).CopyTo(buf);
                var main = new[] { new CbufRead(7, 0, 64, use) };
                for (int i = 0; i < 100; i++) { csh.Write(7, 0, buf, chg, out _); cam.OnDraw(2, main); cam.OnPresent(); }
                long a0 = GC.GetAllocatedBytesForCurrentThread();
                for (int i = 0; i < 1000; i++) { csh.Write(7, 0, buf, chg, out _); for (int d = 0; d < 20; d++) cam.OnDraw(2, main); cam.OnPresent(); }
                long a1 = GC.GetAllocatedBytesForCurrentThread();
                for (int i = 0; i < 10000; i++) { csh.Write(7, 0, buf, chg, out _); for (int d = 0; d < 20; d++) cam.OnDraw(2, main); cam.OnPresent(); }
                long a2 = GC.GetAllocatedBytesForCurrentThread();
                Check("镜头位姿：稳态每帧零分配（10000 帧窗口减 1000 帧窗口再 ÷9000）", 0L, ((a2 - a1) - (a1 - a0)) / 9000);
                cam.OnPresent();
                Check("镜头位姿：本帧深度目标上没有绘制（30 帧游戏重复上屏）→ 沿用上一帧", true, cam.Valid);
                csh.Write(7, 0, new byte[64], chg, out _); for (int i = 0; i < 32; i++) cam.OnDraw(2, main); cam.OnPresent();
                Check("镜头位姿：候选被覆盖成非矩阵 → 本帧无镜头（2D / 菜单标空）", false, cam.Valid);
            }
            {   // 主深度目标只在有透视候选的深度里选（10-25 动森直连）：阴影深度 3 读正交矩阵、绘制更多（64 笔 / 帧），场景深度 2 读 VP（48 笔 / 帧）→ 主镜头 = 场景的 (10, 2, −5)
                var csh = new CbufShadow(); csh.Cover(7, 0, 256); csh.Cover(8, 0, 256); var cam = new CameraTrack(csh); var chg = new List<(int, int)>();
                byte[] vb = new byte[64]; MemoryMarshal.AsBytes(VP.AsSpan()).CopyTo(vb);
                byte[] ob = B(0.01f, 0, 0, 0, 0, 0.0177f, 0, 0, 0, 0, 0.001f, 0.5f, 0, 0, 0, 1);   // 阴影：轴对齐正交（w 行 0001，不是透视 VP）
                var scene = new[] { new CbufRead(7, 0, 64, use) }; var shadow = new[] { new CbufRead(8, 0, 64, use) };
                for (int fr = 0; fr < 4; fr++) { csh.Write(7, 0, vb, chg, out _); csh.Write(8, 0, ob, chg, out _);
                    for (int i = 0; i < 64 * 32; i++) cam.OnDraw(3, shadow); for (int i = 0; i < 48 * 32; i++) cam.OnDraw(2, scene); cam.OnPresent(); }
                Check("镜头位姿：阴影深度绘制更多但没有透视候选 → 主镜头取场景深度 (10, 2, −5)", "True 10.000,2.000,-5.000", $"{cam.Valid} {cam.X:F3},{cam.Y:F3},{cam.Z:F3}");
            }
            {   // 自动玩家在线读（s2a_ap_cam 背后的发布 / 读取）：有镜头读到位置与帧号；无镜头返回 false、pos 不动；读写零分配
                var csh = new CbufShadow(); csh.Cover(7, 0, 256); var cam = new CameraTrack(csh); var chg = new List<(int, int)>(); byte[] buf = new byte[64]; MemoryMarshal.AsBytes(VP.AsSpan()).CopyTo(buf);
                var main = new[] { new CbufRead(7, 0, 64, use) };
                for (int i = 0; i < 40; i++) { csh.Write(7, 0, buf, chg, out _); cam.OnDraw(2, main); cam.OnPresent(); }
                Span<float> pos = stackalloc float[3];
                CameraTrack.Publish(cam, 77);
                bool got = CameraTrack.ReadCam(pos, out ulong fr);
                Check("在线读镜头：有主镜头 → 位置 (10, 2, −5)、帧号 77", "True 10.000,2.000,-5.000 77", $"{got} {pos[0]:F3},{pos[1]:F3},{pos[2]:F3} {fr}");
                long a0 = GC.GetAllocatedBytesForCurrentThread();
                for (int i = 0; i < 10000; i++) { CameraTrack.Publish(cam, (ulong)i); CameraTrack.ReadCam(pos, out fr); }
                long a1 = GC.GetAllocatedBytesForCurrentThread();
                for (int i = 0; i < 100000; i++) { CameraTrack.Publish(cam, (ulong)i); CameraTrack.ReadCam(pos, out fr); }
                long a2 = GC.GetAllocatedBytesForCurrentThread();
                Check("在线读镜头：发布 + 读稳态零分配（10 万次窗口减 1 万次窗口）", 0L, (a2 - a1) - (a1 - a0));
                csh.Write(7, 0, new byte[64], chg, out _); for (int i = 0; i < 32; i++) cam.OnDraw(2, main); cam.OnPresent();
                pos[0] = 123; CameraTrack.Publish(cam, 78);
                got = CameraTrack.ReadCam(pos, out fr);
                Check("在线读镜头：无主镜头 → false、帧号 78、pos 不动", "False 78 123", $"{got} {fr} {pos[0]:F0}");
            }
            {   // 直连只观察会话（S2A_WIDEN_OBSERVE，10-25 马车8 直连没有镜头位姿）：同一个 VP 经直连入口（CbufBind / Draw / Present）→ s2a_ap_cam 读到同一位置；
                //   画法恒 Keep、常量出数恒 0（不改画面），渲染目标不放宽
                var s = new WidenSession(2346, 1080, false, true, false, observe: true);
                nint ptr = Pinned(64, out byte[] ga, out int gat);
                MemoryMarshal.AsBytes(VP.AsSpan()).CopyTo(ga.AsSpan(gat));
                int h = s.Shader("0:0,1,2,3", false); int[] sh = { h, 0, 0, 0, 0, 0 };
                Span<float> push = stackalloc float[4]; byte[] scratch = new byte[64];
                string modes = ""; int emitted = 0;
                for (int fi = 0; fi < 3; fi++)
                {
                    s.Targets(1, 2);
                    for (int i = 0; i < 64; i++) { s.CbufBind(0, 0, ptr, 64); var m = s.Draw(0, 1280, 720, 1, sh, WidenSession.DrawColor, default, push, out _); if (!modes.Contains(m.ToString())) modes += m; emitted += s.CbufEmit(0, 0, scratch); }
                    int l = 0, r = 1280; float ax = 16; s.Present(1, ref l, ref r, ref ax, 9);
                }
                Span<float> pos = stackalloc float[3];
                bool got = CameraTrack.ReadCam(pos, out ulong fr);
                Check("直连只观察：模式 Observe、渲染目标不放宽、画法恒 Keep、出数恒 0", "Observe 1920 Keep 0", $"{s.Mode} {s.Texture(9, 1920, 1080, 1, WidenSession.UseRt)} {modes} {emitted}");
                Check("直连只观察：s2a_ap_cam 读到镜头 (10, 2, −5)", "True 10.000,2.000,-5.000", $"{got} {pos[0]:F3},{pos[1]:F3},{pos[2]:F3}");
            }
        }

        // ---------- 着色器包宽屏元数据 widen.idx：写 → 读往返、程序二进制取键 ----------
        {
            var u1 = new CbufUse { Binding = 3 }; u1.Add(4); u1.Add(5); u1.Add(6); u1.Add(7);
            var u2 = new CbufUse { Binding = 0, Dynamic = true };
            var m1 = new WidenStageMeta { Stage = 0, Push = true, Uses = new[] { u1 } };
            var m2 = new WidenStageMeta { Stage = 4, FragY = 2, RealPx = true, Scales = new[] { (3, 130, false), (5, 2, true) }, Images = new[] { 0, 1 }, Sampled = new[] { 128, 130 }, Uses = new[] { u2 },
                Extrap = true, ExtrapSamples = new[] { (1, 128), (3, 130) } };
            string f = Path.Combine(Path.GetTempPath(), $"widen_unit_{Environment.ProcessId}.idx");
            WidenIndex.Write(f, new Dictionary<ulong, WidenStageMeta> { [0x1122334455667788UL] = m1, [0x99UL] = m2 });
            var rd = WidenIndex.Read(f); File.Delete(f);
            Check("widen.idx 往返：条数", 2, rd?.Count ?? -1);
            var a = rd[0x1122334455667788UL]; var bb = rd[0x99UL];
            Check("widen.idx 往返：顶点条（阶段、外推、读法下标）", "0,True,3,4-5-6-7", $"{a.Stage},{a.Push},{a.Uses[0].Binding},{string.Join("-", a.Uses[0].Indices.ToArray())}");
            Check("widen.idx 往返：片元条（片元 y 处数、采样绑定、动态读法）", "2,128-130,True", $"{bb.FragY},{string.Join("-", bb.Sampled)},{bb.Uses[0].Dynamic}");
            Check("widen.idx 往返（版本 3）：片元按真实像素 / 顶点条不", "True,False", $"{bb.RealPx},{a.RealPx}");
            Check("widen.idx 往返（版本 3）：取图缩放项", "3:130:False,5:2:True", string.Join(",", Array.ConvertAll(bb.Scales, x => $"{x.Index}:{x.Binding}:{x.Image}")));
            Check("widen.idx 往返（版本 3）：存储图像绑定（片元条 0、1；顶点条没给 = 空表）", "0-1|", $"{string.Join("-", bb.Images)}|{string.Join("-", a.Images)}");
            Check("widen.idx 往返（版本 4）：片元能外推、外推采样项；顶点条不能外推", "True,1:128-3:130,False", $"{bb.Extrap},{string.Join("-", Array.ConvertAll(bb.ExtrapSamples, x => $"{x.Index}:{x.Binding}"))},{a.Extrap}");
            // 手拼版本 2（有「整数读取」字节、没有取图缩放项）：照读，整数读取 → 按真实像素（那时包里的取图缩放不分轴）
            {
                var v2 = new MemoryStream(); var q = new BinaryWriter(v2);
                q.Write(0x58444957u); q.Write(2u); q.Write(1); q.Write(0x78UL); q.Write(4); q.Write(1); q.Write((byte)0); q.Write((byte)1); q.Write(1); q.Write(129); q.Write(0);
                string f2 = Path.Combine(Path.GetTempPath(), $"widen_unit_v2_{Environment.ProcessId}.idx"); File.WriteAllBytes(f2, v2.ToArray());
                var r2 = WidenIndex.Read(f2); File.Delete(f2);
                Check("widen.idx 版本 2 照读：按真实像素、没有取图缩放项、采样 129、存储图像不知道（null）", "True,0,129,True", r2 != null && r2.TryGetValue(0x78UL, out var e2) ? $"{e2.RealPx},{e2.Scales.Length},{string.Join("-", e2.Sampled)},{e2.Images == null}" : "读不出");
            }
            // 手拼版本 1（没有整数读取字节）：照读、该项 false（旧着色器包重新出包前仍可用）
            {
                var v1 = new MemoryStream(); var q = new BinaryWriter(v1);
                q.Write(0x58444957u); q.Write(1u); q.Write(1); q.Write(0x77UL); q.Write(4); q.Write(1); q.Write((byte)0); q.Write(1); q.Write(129); q.Write(0);
                string f1 = Path.Combine(Path.GetTempPath(), $"widen_unit_v1_{Environment.ProcessId}.idx"); File.WriteAllBytes(f1, v1.ToArray());
                var r1 = WidenIndex.Read(f1); File.Delete(f1);
                Check("widen.idx 版本 1 照读：片元 y 1、采样 129、按真实像素 false", "1,129,False", r1 != null && r1.TryGetValue(0x77UL, out var e1) ? $"{e1.FragY},{string.Join("-", e1.Sampled)},{e1.RealPx}" : "读不出");
            }
            // 存储图像绑定：%10 存储图像类型（Sampled 2）、%11 采样图像类型（Sampled 1）、%12 存储图像数组；指针 %20/%21/%22；变量 %30（绑定 3）、%31（绑定 128）、%32（绑定 5）
            {
                var v = new List<uint> { 0x07230203, 0x00010000, 0, 40, 0 };
                void J(int op, params uint[] x) { v.Add((uint)((x.Length + 1) << 16 | op)); v.AddRange(x); }
                J(71, 30, 33, 3); J(71, 31, 33, 128); J(71, 32, 33, 5);
                J(22, 1, 32); J(25, 10, 1, 1, 0, 0, 0, 2, 4); J(25, 11, 1, 1, 0, 0, 0, 1, 0); J(43, 1, 13, 4); J(28, 12, 10, 13);
                J(32, 20, 0, 10); J(32, 21, 0, 11); J(32, 22, 0, 12);
                J(59, 20, 30, 0); J(59, 21, 31, 0); J(59, 22, 32, 0);
                Check("存储图像绑定：存储图像 3、存储图像数组 5；采样贴图 128 不算", "3,5", string.Join(",", WidenIndex.StorageImageBindings(MemoryMarshal.AsBytes(v.ToArray().AsSpan()).ToArray())));
            }
            // 手拼 GALP 程序二进制：头 20 字节 + 两条记录（记录开头 u64 键）
            var ms = new MemoryStream(); var w = new BinaryWriter(ms);
            w.Write(0x504c4147u); w.Write(1u); w.Write(7u); w.Write(2u); w.Write(0);
            foreach (ulong k in new[] { 0xAAAABBBBCCCCDDDDUL, 0x0123456789ABCDEFUL }) { w.Write(24u); w.Write(k); w.Write(1u); w.Write(new byte[12]); }
            var keys = new List<ulong>();
            Check("程序二进制取各阶段键", "aaaabbbbccccdddd,0123456789abcdef", WidenIndex.BinaryKeys(ms.ToArray(), keys) ? string.Join(",", keys.ConvertAll(x => x.ToString("x16"))) : "失败");
            byte[] bad = ms.ToArray(); bad[0] ^= 1;
            Check("魔数不对 → 认不出", false, WidenIndex.BinaryKeys(bad, keys));
            Check("截断 → 认不出", false, WidenIndex.BinaryKeys(ms.ToArray().AsSpan(0, 40), keys));
        }

        {   // 常量影子按段写（10-23：变了 / 未知的一段整段拷、按位段置已知）：变了区间期望按「粒 = 16 字节；没页 / 未知 / 半粒 / 内容不同都算变」手算
            var csh = new CbufShadow(); var chg = new List<(int Lo, int Hi)>();
            csh.Cover(5, 0, 8192);   // 两页 [0, 8192)，第三页没影子
            byte[] a = new byte[8400]; for (int i = 0; i < a.Length; i++) a[i] = (byte)(i * 7);
            string L() => string.Join(" ", chg.ConvertAll(c => $"{c.Lo}-{c.Hi}"));
            csh.Write(5, 0, a.AsSpan(0, 8192), chg, out _); Check("按段写：整两页初次上传（全未知）→ 一段", "0-8192", L());
            csh.Write(5, 0, a.AsSpan(0, 8192), chg, out _); Check("按段写：同内容再传 → 无变化", "", L());
            byte[] m = (byte[])a.Clone(); m[16]++; m[17]++; m[48]++; m[4095]++; m[4096]++;
            csh.Write(5, 0, m.AsSpan(0, 8192), chg, out _); Check("按段写：零散改字节（粒 1、3、页尾 255 与下页首粒 256 相邻）", "16-32 48-64 4080-4112", L());
            csh.Write(5, 100, m.AsSpan(100, 40), chg, out _); Check("按段写：不对齐同内容 [100,140)：头尾半粒算变、中间整粒没变", "100-112 128-140", L());
            csh.Write(5, 8000, m.AsSpan(8000, 400), chg, out _); Check("按段写：跨进没影子的页：有影子部分没变、没影子部分整段算变", "8192-8400", L());
            byte[] r = (byte[])m.Clone(); for (int i = 0; i < 128; i++) r[i]++;
            csh.Write(5, 0, r.AsSpan(0, 256), chg, out _); Check("按段写：连续 8 粒内容都变、后 8 粒没变 → 一段", "0-128", L());
            Span<byte> got = stackalloc byte[256];
            Check("按段写：影子内容 = 最后上传的内容", true, csh.TryGet(5).ReadKnown(0, got) && got.SequenceEqual(r.AsSpan(0, 256)));
            csh.Cover(6, 0, 4096);
            byte[] z = new byte[64]; for (int i = 0; i < 64; i++) z[i] = (byte)(i + 1);
            csh.Write(6, 8, z.AsSpan(8, 40), chg, out _); Check("按段写：未知区不对齐 [8,48) → 一段", "8-48", L());
            Span<byte> g16 = stackalloc byte[16]; Span<byte> g32 = stackalloc byte[32];
            Check("按段写：头半粒原来未知 → 仍未知；中间两整粒 → 已知且内容对", "False True",
                $"{csh.TryGet(6).ReadKnown(0, g16)} {csh.TryGet(6).ReadKnown(16, g32) && g32.SequenceEqual(z.AsSpan(16, 32))}");
            csh.Write(6, 0, z, chg, out _); Check("按段写：[0,64) 里粒 0 / 3 未知、1–2 已知没变", "0-16 48-64", L());
        }
        // ---------- 10-28 页来源随合成传递：16:9 原比例页经中间目标合成后上屏免判 ----------
        // 八方2 标题 / 读档菜单：页先画进中间目标 1655 → 1657（两段合成）→ 交换链；上屏贴图不是页目标本身，
        // 核心把「页来源」沿 ScaleK 合成链传播，上屏时 s2a_widen_present 返回 1（免判）。
        // 同一交换链下一帧画 3D 场景（Hor）→ 清页来源标记 → 上屏返回 0。
        {
            var s = new WidenSession(2346, 1080, false, true, false);   // All 模式（第三层验过）
            s.Texture(100, 1280, 720, 1, 0);   // CPU 供图（页来源图片），不登记 RT
            s.Texture(1655, 1280, 720, 1, WidenSession.UseRt);   // 中间目标 → 放宽 1564
            s.Texture(1657, 1280, 720, 1, WidenSession.UseRt);   // 中间目标 → 放宽 1564
            s.Texture(200, 1280, 720, 1, WidenSession.UseRt);    // 交换链 → 放宽 1564

            nint ptr = Pinned(768, out byte[] ga, out int gat);
            B(Proj()).CopyTo(ga, gat);
            int hp = s.Shader("0:0,1,2,3", false);   // 顶点读投影
            int[] sp = { hp, 0, 0, 0, 0, 0 };
            Span<float> push = stackalloc float[4];

            // 第 1 帧：页 → 1655（起页，标 1655 为页来源）
            s.Targets(1655, 0);
            s.CbufBind(0, 0, ptr, 768);
            var pageTex = new[] { new WidenSession.Tex { Id = 100, W = 1280, H = 720, Scale = 1 } };
            Check("页来源传播：页笔画法 Page", ViewportMode.Page, s.Draw(0, 1280, 720, 1, sp, WidenSession.DrawColor, pageTex, push, out _));
            Check("页来源传播：页目标 1655 标为页来源", true, s.Frame.IsPageSource(1655));

            // 1655 → 1657（第一段合成；解绑投影使 reads 空 → ScaleK，采样页来源 → 标 1657）
            s.CbufBind(0, 0, 0, 0);
            s.Targets(1657, 0);
            var tex1655 = new[] { new WidenSession.Tex { Id = 1655, W = 1280, H = 720, Scale = 1 } };
            Check("页来源传播：第一段合成画法 ScaleK", ViewportMode.ScaleK, s.Draw(0, 1564, 720, 1, sp, WidenSession.DrawColor, tex1655, push, out _));
            Check("页来源传播：中间目标 1657 标为页来源", true, s.Frame.IsPageSource(1657));

            // 1657 → 200（第二段合成 → 标 200）
            s.Targets(200, 0);
            var tex1657 = new[] { new WidenSession.Tex { Id = 1657, W = 1280, H = 720, Scale = 1 } };
            Check("页来源传播：第二段合成画法 ScaleK", ViewportMode.ScaleK, s.Draw(0, 1564, 720, 1, sp, WidenSession.DrawColor, tex1657, push, out _));
            Check("页来源传播：交换链 200 标为页来源", true, s.Frame.IsPageSource(200));

            // 上屏 200 → 返回 1（免判）
            int l = 0, r = 0; float ax = 16;
            Check("页来源传播：上屏交换链（页来源）→ 返回 1", 1, s.Present(200, ref l, ref r, ref ax, 9));

            // 第 2 帧：3D 场景（读改写投影 → Hor）→ 清页来源标记 → 上屏返回 0
            s.Targets(200, 0);
            s.CbufBind(0, 0, ptr, 768);
            Check("页来源传播：3D 场景画法 Hor", ViewportMode.Hor, s.Draw(0, 1564, 720, 1, sp, WidenSession.DrawColor, default, push, out _));
            Check("页来源传播：3D 场景清掉页来源标记", false, s.Frame.IsPageSource(200));
            Check("页来源传播：上屏交换链（3D 场景）→ 返回 0", 0, s.Present(200, ref l, ref r, ref ax, 9));
        }
        // ---------- 11-02 页来源随贴图拷贝：马里奥和索尼克东京2020 原比例页起在画布、拷进交换链上屏 ----------
        //   页起在 1655（同上）；GpuWrote(300 ← 1655)（贴图拷贝）→ 300 是页来源、上屏返回 1；之后 GpuWrote(300 ← 1657 非页) → 清掉、上屏返回 0
        {
            var s = new WidenSession(2346, 1080, false, true, false);
            s.Texture(100, 1280, 720, 1, 0); s.Texture(1655, 1280, 720, 1, WidenSession.UseRt); s.Texture(1657, 1280, 720, 1, WidenSession.UseRt); s.Texture(300, 1280, 720, 1, WidenSession.UseRt);
            nint ptr = Pinned(768, out byte[] ga, out int gat); B(Proj()).CopyTo(ga, gat);
            int hp = s.Shader("0:0,1,2,3", false); int[] sp = { hp, 0, 0, 0, 0, 0 }; Span<float> push = stackalloc float[4];
            s.Targets(1655, 0); s.CbufBind(0, 0, ptr, 768);
            s.Draw(0, 1280, 720, 1, sp, WidenSession.DrawColor, new[] { new WidenSession.Tex { Id = 100, W = 1280, H = 720, Scale = 1 } }, push, out _);
            s.GpuWrote(300, 1655); int l = 0, r = 0; float ax = 16; int p1 = s.Present(300, ref l, ref r, ref ax, 9);
            s.GpuWrote(300, 1657); l = 0; r = 0; ax = 16; int p2 = s.Present(300, ref l, ref r, ref ax, 9);
            Check("页来源随贴图拷贝：从页目标拷来 → 上屏 1；再从非页目标拷来 → 上屏 0", "1 0", $"{p1} {p2}");
        }
        // ---------- 10-28 第二轮：页来源按内容记、不按帧号 ----------
        // o2red3 跟踪：八方2 标题视频页 20715 约隔一帧才重画（mode 4 只在第 1400 / 1430 / 1475 / 1505… 帧出现，1415 / 1445 / 1460 / 1490… 没有），
        // 交换链 1659 每帧照样 ScaleK 合成 20715。旧规则按帧号认页来源，不重画的帧 1659 认不出 → 上屏返回 0 → 判据「离开原比例页」再报红。
        {
            var s = new WidenSession(2346, 1080, false, true, false);
            s.Texture(100, 1280, 720, 1, 0);                      // CPU 供图（视频帧）
            s.Texture(1655, 1280, 720, 1, WidenSession.UseRt);   // 页目标
            s.Texture(200, 1280, 720, 1, WidenSession.UseRt);    // 交换链
            nint ptr = Pinned(768, out byte[] ga, out int gat);
            B(Proj()).CopyTo(ga, gat);
            int hp = s.Shader("0:0,1,2,3", false);
            int[] sp = { hp, 0, 0, 0, 0, 0 };
            Span<float> push = stackalloc float[4];
            var pageTex = new[] { new WidenSession.Tex { Id = 100, W = 1280, H = 720, Scale = 1 } };
            var tex1655 = new[] { new WidenSession.Tex { Id = 1655, W = 1280, H = 720, Scale = 1 } };
            int l = 0, r = 0; float ax = 16;

            // 第 1 帧：起页 + 合成上屏
            s.Targets(1655, 0); s.CbufBind(0, 0, ptr, 768);
            Check("页按内容：起页那笔画法 Page", ViewportMode.Page, s.Draw(0, 1280, 720, 1, sp, WidenSession.DrawColor, pageTex, push, out _));
            s.CbufBind(0, 0, 0, 0); s.Targets(200, 0);
            Check("页按内容：起页帧合成画法 ScaleK", ViewportMode.ScaleK, s.Draw(0, 1280, 720, 1, sp, WidenSession.DrawColor, tex1655, push, out _));
            Check("页按内容：起页帧上屏 → 1", 1, s.Present(200, ref l, ref r, ref ax, 9));
            // 第 2–4 帧：不起页（页内容没变、游戏不重画），只把同一张页目标合成上屏
            for (int pf = 2; pf <= 4; pf++)
            {
                s.Targets(200, 0);
                Check($"页按内容：第 {pf} 帧（不起页）合成画法 ScaleK", ViewportMode.ScaleK, s.Draw(0, 1280, 720, 1, sp, WidenSession.DrawColor, tex1655, push, out _));
                Check($"页按内容：第 {pf} 帧（不起页）上屏 → 1", 1, s.Present(200, ref l, ref r, ref ax, 9));
            }
            // 第 5 帧：交换链被 3D 场景（读改写投影、铺满画布 = Hor）覆盖 → 不再是页；两侧是放宽内容画的 → 返回 2
            s.Targets(200, 0); s.CbufBind(0, 0, ptr, 768);
            Check("页按内容：3D 帧画法 Hor", ViewportMode.Hor, s.Draw(0, 1280, 720, 1, sp, WidenSession.DrawColor, default, push, out _));
            Check("页按内容：3D 帧清掉页标记", false, s.Frame.IsPageSource(200));
            Check("页按内容：3D 帧上屏 → 2（两侧放宽内容）", 2, s.Present(200, ref l, ref r, ref ax, 9));
            // 页目标本身没被别的内容覆盖，标记仍在；清屏后作废
            Check("页按内容：页目标 1655 标记仍在", true, s.Frame.IsPageSource(1655));
            s.Frame.OnTargetCleared(1655);
            Check("页按内容：页目标清屏后作废", false, s.Frame.IsPageSource(1655));
            // 交换链清屏后两侧来历作废 → 0
            s.Frame.OnTargetCleared(200);
            Check("页按内容：交换链清屏后上屏 → 0", 0, s.Present(200, ref l, ref r, ref ax, 9));
            // 合成同时采样页与内容不是页的放宽贴图（真宽的场景）→ 不算页
            s.Texture(1843, 1280, 720, 1, WidenSession.UseRt);   // 放宽的场景目标
            s.Targets(1843, 0); s.CbufBind(0, 0, 0, 0);
            s.Draw(0, 1280, 720, 1, sp, WidenSession.DrawColor, default, push, out _);
            Check("页按内容：场景目标 1843 已放宽", true, s.Frame.IsWide(1843));
            s.Frame.OnTargetCleared(1655); s.Targets(1655, 0); s.CbufBind(0, 0, ptr, 768);
            Check("页按内容：重新起页", ViewportMode.Page, s.Draw(0, 1280, 720, 1, sp, WidenSession.DrawColor, pageTex, push, out _));
            s.CbufBind(0, 0, 0, 0); s.Targets(200, 0);
            var mix = new[] { new WidenSession.Tex { Id = 1655, W = 1280, H = 720, Scale = 1 }, new WidenSession.Tex { Id = 1843, W = 1280, H = 720, Scale = 1 } };
            s.Draw(0, 1280, 720, 1, sp, WidenSession.DrawColor, mix, push, out _);
            Check("页按内容：页 + 真宽场景同笔合成 → 不算页", false, s.Frame.IsPageSource(200));
        }
        // ---------- 10-28 两侧来历（同包装层 Bands）：八方2 直连读档页 ----------
        // o2red3 第 1880 帧：交换链 1659 上没有页（20715 不再被合成），1×1 纯色底被收缩后推满宽屏（核心 mode 2、x 0 w 1564）、界面原尺寸居中、整屏模糊链 1659 → 34502 → 34503 → 34502 → 1659。
        // 两侧纯黑是放宽内容画的，同包装层返回 2；模糊链 ScaleK 把标记带回交换链。
        {
            var s = new WidenSession(2346, 1080, false, true, false);
            s.Texture(300, 1280, 720, 1, WidenSession.UseRt);   // 交换链
            s.Texture(301, 1280, 720, 1, WidenSession.UseRt);   // 模糊中间目标
            s.Texture(400, 1280, 720, 1, WidenSession.UseRt);
            nint ptr = Pinned(768, out byte[] ga, out int gat);
            B(Proj()).CopyTo(ga, gat);
            int hp = s.Shader("0:0,1,2,3", false);
            int[] sp = { hp, 0, 0, 0, 0, 0 };
            Span<float> push = stackalloc float[4];
            int l = 0, r = 0; float ax = 16;
            s.Targets(300, 0); s.CbufBind(0, 0, ptr, 768);
            Check("两侧来历：铺满画布的底画法 Hor", ViewportMode.Hor, s.Draw(0, 1280, 720, 1, sp, WidenSession.DrawColor, default, push, out _));
            s.CbufBind(0, 0, 0, 0); s.Targets(301, 0);
            var t300 = new[] { new WidenSession.Tex { Id = 300, W = 1280, H = 720, Scale = 1 } };
            var t301 = new[] { new WidenSession.Tex { Id = 301, W = 1280, H = 720, Scale = 1 } };
            s.Draw(0, 1280, 720, 1, sp, WidenSession.DrawColor, t300, push, out _);
            Check("两侧来历：模糊链 ScaleK 带过去", true, s.Frame.IsBands(301));
            s.Frame.OnTargetCleared(300); s.Targets(300, 0);
            s.Draw(0, 1280, 720, 1, sp, WidenSession.DrawColor, t301, push, out _);
            Check("两侧来历：交换链清屏后由模糊链合成回来 → 上屏 2", 2, s.Present(300, ref l, ref r, ref ax, 9));
            // 反例：Hor 只画了局部视口（不铺满画布）→ 不标 → 0
            s.Targets(400, 0); s.CbufBind(0, 0, ptr, 768);
            s.Draw(100, 640, 360, 1, sp, WidenSession.DrawColor, default, push, out _);
            Check("两侧来历：局部视口的 Hor 不标 → 上屏 0", 0, s.Present(400, ref l, ref r, ref ax, 9));
        }
        // 10-30 按内容判画布（银河2：16:9 场景按变形画法画进 1920×1584 的 Wii EFB，尺寸不属一族、从不放宽）。整套放宽 K = 1.221875，期望手算：
        //   能重建（UseRebuild）的 1920×1584 附件先记「未定」、建出原宽 1920；只画 2D（不读投影）不晋升；铺满视口（1920×1584）读到 16:9 透视投影 → 晋升，放宽 1920·391/320 = 2346；
        //   之后同尺寸新建直接 2346；不能重建的同尺寸贴图从不未定；只画半个视口（640×528 / 1280×1056 < 90%）不晋升；晋升后同一笔按 Hor、出数 P00/K
        {
            var s = new WidenSession(2346, 1080, false, true, false);
            nint ptr = Pinned(768, out byte[] ga, out int gat); B(Proj()).CopyTo(ga, gat);
            int h = s.Shader("0:0,1,2,3", false), h2d = s.Shader("", false);
            int[] sh = { h, 0, 0, 0, 0, 0 }, s2d = { h2d, 0, 0, 0, 0, 0 };
            Span<float> push = stackalloc float[4]; byte[] scratch = new byte[768]; uint[] ids = new uint[4];
            const int RB = WidenSession.UseRt | WidenSession.UseRebuild;
            Check("画布：能重建的 1920×1584 / 不能重建的同尺寸 / 1280×1056 先都按原宽建", "1920 1920 1280", $"{s.Texture(500, 1920, 1584, 1, RB)} {s.Texture(501, 1920, 1584, 1, WidenSession.UseRt)} {s.Texture(502, 1280, 1056, 1, RB)}");
            Check("画布：未定 = 能重建且不属一族的那两张", "True False True", $"{s.Frame.IsUndecided(500)} {s.Frame.IsUndecided(501)} {s.Frame.IsUndecided(502)}");
            s.Targets(500, 0);
            var m0 = s.Draw(0, 1920, 1584, 1, s2d, WidenSession.DrawColor, default, push, out _);
            Check("画布：未定目标上只画 2D（不读投影）→ Keep、不晋升", "Keep 0", $"{m0} {s.Frame.Promoted}");
            s.CbufBind(0, 0, ptr, 768);
            var m1 = s.Draw(0, 1920, 1584, 1, sh, WidenSession.DrawColor, default, push, out _);
            int n = s.Frame.TakePromoted(ids);
            Check("画布：铺满视口读到 16:9 透视投影 → 这一笔仍 Keep、晋升 1 张（500）", "Keep 1 500", $"{m1} {n} {ids[0]}");
            Check("画布：放宽 1920 → 2346（1920·391/320）、取走后队列空", "True 1920 2346 0", $"{s.Frame.TryWide(500, out int w0, out int w1)} {w0} {w1} {s.Frame.TakePromoted(ids)}");
            Check("画布：之后同尺寸新建直接按 2346 建", 2346, s.Texture(503, 1920, 1584, 1, RB));
            // Vulkan 层按视图号登记渲染目标：未定贴图 504（960×792，另一尺寸）的整级视图 505 上读到投影 → 晋升的是贴图 504；重调 View 后视图按父放宽 960·391/320 = 1173
            s.Texture(504, 960, 792, 1, RB); s.View(505, 504, 0, 960);
            s.Targets(505, 0); s.CbufBind(0, 0, ptr, 768); s.Draw(0, 960, 792, 1, sh, WidenSession.DrawColor, default, push, out _);
            int nv = s.Frame.TakePromoted(ids);
            Check("画布：视图上读到投影 → 晋升根贴图 504、视图重调后 1173", "1 504 1173", $"{nv} {ids[0]} {s.View(505, 504, 0, 960)}");
            s.Targets(501, 0); s.CbufBind(0, 0, ptr, 768); s.Draw(0, 1920, 1584, 1, sh, WidenSession.DrawColor, default, push, out _);
            Check("画布：不能重建的同尺寸贴图画同一投影 → 不晋升", 0, s.Frame.TakePromoted(ids));
            s.Targets(502, 0); s.CbufBind(0, 0, ptr, 768); s.Draw(0, 640, 528, 1, sh, WidenSession.DrawColor, default, push, out _);
            Check("画布：只画半个视口（640×528）→ 不晋升、仍未定", "0 True", $"{s.Frame.TakePromoted(ids)} {s.Frame.IsUndecided(502)}");
            // 10-30 银河2 实局：未定目标上的绘制按原样画（命中被标成「写回原值」），之后不重绑、同一段投影再画一笔铺满视口 → 照样晋升（认的是「被认出的镜头矩阵」，不看当前是原值还是改写值）
            s.Draw(0, 1280, 1056, 1, sh, WidenSession.DrawColor, default, push, out _);
            Check("画布：之前的绘制已写回原值、不重绑再铺满视口 → 晋升 502", "1 502", $"{s.Frame.TakePromoted(ids)} {ids[0]}");
            // 同尺寸类一起晋升（银河2 两张颜色 EFB + 一张深度同为 1920×1584）：960×720 三张未定，画其中一张 → 三张都晋升（960·391/320 = 1173），另一尺寸 1000×1320（507）不动
            s.Texture(510, 960, 720 * 2, 1, RB); s.Texture(511, 960, 1440, 1, RB); s.Texture(512, 960, 1440, 1, RB); s.Texture(507, 1000, 1320, 1, RB);
            s.Targets(511, 0); s.CbufBind(0, 0, ptr, 768); s.Draw(0, 960, 1440, 1, sh, WidenSession.DrawColor, default, push, out _);
            int ng = s.Frame.TakePromoted(ids);
            Check("画布：同尺寸 960×1440 三张一起晋升、另一尺寸不动", "3 1173 1173 1173 True", $"{ng} {(s.Frame.TryWide(510, out _, out int a1) ? a1 : 0)} {(s.Frame.TryWide(511, out _, out int a2) ? a2 : 0)} {(s.Frame.TryWide(512, out _, out int a3) ? a3 : 0)} {s.Frame.IsUndecided(507)}");
            // 左上一块 16:9（银河2：EFB 1920×1584 上视口 0,0 1280×720，宽 67% ≥ 60%）→ 晋升；同目标左上 640×528（不是 16:9）不晋升
            s.Texture(506, 1600, 1320, 1, RB); s.Targets(506, 0); s.CbufBind(0, 0, ptr, 768);
            s.Draw(0, 640, 528, 1, sh, WidenSession.DrawColor, default, push, out _);
            int nc0 = s.Frame.TakePromoted(ids);
            s.Draw(0, 1280, 720, 1, sh, WidenSession.DrawColor, default, push, out _);
            int nc1 = s.Frame.TakePromoted(ids);
            Check("画布：1600×1320 上左上 640×528 不晋升、左上 1280×720（16:9、宽 80%）晋升 506，放宽 1600·391/320 = 1955", "0 1 506 1955", $"{nc0} {nc1} {ids[0]} {(s.Frame.TryWide(506, out _, out int w506) ? w506 : 0)}");
            // 左上画布的换算按画布宽 1280（不按贴图宽 1600）：pad = 1280·(K−1)/2 = 142，画布放宽 1280·K = 1564
            s.Targets(506, 0);
            float hx = 0, hw = 1280; s.Frame.MapViewport(ViewportMode.Hor, ref hx, ref hw);
            float cx = 0, cw2 = 1280; s.Frame.MapViewport(ViewportMode.CenterNative, ref cx, ref cw2);
            int sx = 0, sw = 1280; s.Frame.MapScissor(ViewportMode.Hor, ref sx, ref sw);
            Check("画布：左上画布 Hor 视口 0/1280 → 0/1564、居中 x → 142、Hor 剪刀 0..1280 → 0/1564（按画布宽，不按贴图宽 1600）", "0 1564 142 0 1564", $"{hx:F0} {hw:F0} {cx:F0} {sx} {sw}");
            s.Targets(500, 0); s.CbufBind(0, 0, ptr, 768);
            var m2 = s.Draw(0, 1920, 1584, 1, sh, WidenSession.DrawColor, default, push, out _);
            int e2 = s.CbufEmit(0, 0, scratch);
            Check("画布：晋升后的目标上同一笔 → Hor，出数 1 处、[0] = P00/K", $"Hor 1 {P00 / K:F6}", $"{m2} {e2} {Fl(scratch)[0]:F6}");
        }
        // 11-02 按内容判画布的竖向（银河2 Duo 外屏：EFB 1920×1584 左上 1280×720，竖向会话原先不进「未定」、EFB 不加高，局内 3D 上下各差约 49 行）。
        //   屏 1920×1318（1080 高多 238 行，Ky 1.2204）。期望手算：1584·238 = 376992 不被 1080 整除（翻倍 3168 也不），→ 1584 + 2·round(376992 / 2160) = 1584 + 350 = 1934；
        //   左上画布高 1280·9/16 = 720 → 878（同 Duo 比例用例）。Hor 视口 (0, 720)：中心 360 + pad (878 − 720)/2 = 79、高 720·1.2204 = 878.7 → 约 (0, 879)；
        //   ScaleK 按画布比 878/720 → (0, 878)；Hor 剪刀覆盖客体全高 (0, 720) → (0, 878)。按存储算 pad 会是 (1934 − 1584)/2 = 175
        {
            var s = new WidenSession(1920, 1318, false, true, false);
            nint ptr = Pinned(768, out byte[] ga, out int gat); B(Proj()).CopyTo(ga, gat);
            int[] sh = { s.Shader("0:0,1,2,3", false), 0, 0, 0, 0, 0 };
            Span<float> push = stackalloc float[4]; uint[] ids = new uint[4];
            const int RB = WidenSession.UseRt | WidenSession.UseRebuild;
            s.Texture(600, 1920, 1584, 1, RB);
            Check("竖向画布：能重建的 EFB 1920×1584 → 未定", true, s.Frame.IsUndecided(600));
            s.Targets(600, 0); s.CbufBind(0, 0, ptr, 768); s.Draw(0, 1280, 720, 1, sh, WidenSession.DrawColor, default, push, out _);
            int n = s.Frame.TakePromoted(ids);
            Check("竖向画布：左上 1280×720 读到 16:9 投影 → 晋升 600、宽不变、加高 1584 → 1934", "1 600 1920 1920 1584 1934",
                $"{n} {ids[0]} {(s.Frame.TryWide(600, out int w0, out int w1) ? $"{w0} {w1}" : "- -")} {(s.Frame.TryTall(600, out int h0, out int h1) ? $"{h0} {h1}" : "- -")}");
            s.Targets(600, 0); s.CbufBind(0, 0, ptr, 768); s.Draw(0, 1280, 720, 1, sh, WidenSession.DrawColor, default, push, out _);
            float hy = 0, hh = 720; s.Frame.MapViewportY(ViewportMode.Hor, ref hy, ref hh);
            float ky = 0, kh = 720; s.Frame.MapViewportY(ViewportMode.ScaleK, ref ky, ref kh);
            int sy = 0, shh = 720; s.Frame.MapScissorY(ViewportMode.Hor, ref sy, ref shh);
            Check("竖向画布：左上画布按画布高换算 Hor 视口 (0, 720) → (0, 879)、ScaleK → (0, 878)、Hor 全高剪刀 → (0, 878)", "0 879 0 878 0 878", $"{Math.Round(hy) + 0} {Math.Round(hh)} {Math.Round(ky) + 0} {Math.Round(kh)} {sy} {shh}");
            Check("竖向画布：之后同尺寸新建直接加高（宽不变）", "1920 True 1934", $"{s.Texture(601, 1920, 1584, 1, RB)} {s.Frame.TryTall(601, out _, out int t1)} {t1}");
            // 11-05 旷野之息 Duo：左上画布上起 16:9 原比例页，上下条带按画布高——画布 720 → 878、pad 79 → 内容 [79, 799)、条带 [0, 79) [799, 878)（手算同上）。
            //   改前按整张存储 1584 → 1934 算：[0, 79) [1663, 1934)，底条带落在画布外
            s.Targets(600, 0); s.CbufBind(0, 0, ptr, 768);
            ViewportMode pm = s.Draw(0, 1280, 720, 1, sh, WidenSession.DrawColor, new[] { new WidenSession.Tex { Id = 650, W = 1280, H = 720, Scale = 1 } }, push, out _);
            bool prow = s.PageRows(out int pr0, out int prc0, out int prc1, out int pr1);
            Check("竖向画布：左上画布起原比例页，上下条带按画布高", "Page True [0,79) [799,878)", $"{pm} {prow} [{pr0},{prc0}) [{prc1},{pr1})");
        }
        // 11-05 旷野之息 Duo：当过绘制目标的贴图重登记成放不宽（Texture 不带 UseRt）后，合成上屏采样它不能被认成 16:9 图片起页
        //   （场景目标 2820 起页时已不在 _rt，交换链每帧起原比例页、场景只占画布 [89,632) 行）。正例：从没当过目标的 CPU 图片照起页
        {
            var s = new WidenSession(1920, 1350, false, true, false);
            int[] sh = new int[6]; Span<float> push = stackalloc float[4];
            s.Texture(10, 1280, 720, 1, WidenSession.UseRt); s.Texture(20, 1920, 1080, 1, WidenSession.UseRt);
            s.Targets(10, 0); s.Draw(0, 1280, 720, 1, sh, WidenSession.DrawColor, default, push, out _);
            s.Texture(10, 1280, 720, 1, 0);   // 重登记成放不宽
            WidenSession.Tex[] T(uint id) => new[] { new WidenSession.Tex { Id = id, W = 1280, H = 720, Scale = 1 } };
            s.Targets(20, 0);
            ViewportMode m1 = s.Draw(0, 1280, 720, 1, sh, WidenSession.DrawColor, T(10), push, out _);
            Check("页来源：采样当过绘制目标、后重登记成放不宽的 1280×720 → 不起页", "False", $"{m1 == ViewportMode.Page}");
            ViewportMode m2 = s.Draw(0, 1280, 720, 1, sh, WidenSession.DrawColor, T(30), push, out _);
            Check("页来源：采样从没当过目标的 1280×720 CPU 图片 → 起页", "True", $"{m2 == ViewportMode.Page}");
        }
        DirectSession();
        Console.WriteLine($"\n共 {total} 项，失败 {fails} 项");
        // 只比更新段（CbufShadow.WriteRanges，11-02 怪猎直连宽屏胶水按影子续拼的更新段喂核心）：与整段比（Write）逐项相同；前提不满足退回 false
        {
            const ulong KA = 7; const int N = 4096;
            var a = new CbufShadow(); var b2 = new CbufShadow(); a.Cover(KA, 0, N); b2.Cover(KA, 0, N);
            var ca = new List<(int Lo, int Hi)>(); var cb = new List<(int Lo, int Hi)>();
            byte[] d = new byte[N]; var rnd = new Random(1102); rnd.NextBytes(d);
            Check("只比更新段：影子全未知时不能只比更新段（前提不满足 → false）", false, b2.WriteRanges(KA, 0, d, new[] { (0, 16) }, cb, out _));
            a.Write(KA, 0, d, ca, out _); b2.Write(KA, 0, d, cb, out _);
            Check("只比更新段：起点不按 16 字节对齐 → false", false, b2.WriteRanges(KA, 8, d.AsSpan(8, 64), new[] { (0, 4) }, cb, out _));
            // 手算：改 [100, 116) 的 16 个字节 → 变了的粒是 96–112 与 112–128，合成 [96, 128)
            for (int i = 100; i < 116; i++) d[i] ^= 0x5A;
            bool ok1 = b2.WriteRanges(KA, 0, d, new[] { (100, 116) }, cb, out _);
            Check("只比更新段：改 [100, 116) → 变了的区间 [96, 128)、只比了 32 字节", "True (96, 128) 32", $"{ok1} {string.Join(" ", cb)} {b2.RangeBytes}");
            a.Write(KA, 0, d, ca, out _);
            int mism = 0, fb = 0, rounds = 3000;
            for (int it = 0; it < rounds; it++)
            {
                int k = rnd.Next(1, 6); var spans = new List<(int Lo, int Hi)>();
                for (int j = 0; j < k; j++)
                {
                    int lo = rnd.Next(0, N - 1), hi = Math.Min(N, lo + rnd.Next(1, 400)); spans.Add((lo, hi));
                    int mode = rnd.Next(3);   // 0 = 写同样的字节（更新了但没变）、1 = 全新随机、2 = 只翻其中一个字节
                    if (mode == 1) rnd.NextBytes(d.AsSpan(lo, hi - lo)); else if (mode == 2) d[rnd.Next(lo, hi)] ^= 0xFF;
                }
                spans.Sort();
                a.Write(KA, 0, d, ca, out _);
                if (!b2.WriteRanges(KA, 0, d, spans.ToArray(), cb, out _)) { fb++; continue; }
                if (ca.Count != cb.Count) { mism++; continue; }
                for (int i = 0; i < ca.Count; i++) if (ca[i] != cb[i]) { mism++; break; }
            }
            Check($"只比更新段：随机 {rounds} 轮（每轮 1–5 段、含写同样字节 / 单字节变），与整段比的变了区间逐项相同（不符 / 退回）", "0 0", $"{mism} {fb}");
            Check("只比更新段：随机轮之后影子与内容逐字节相同（整段再比一处不变）", false, b2.Write(KA, 0, d, cb, out _));
        }
        // 经会话入口：同一份投影常量两个会话，一个整段绑、一个按更新段绑（CbufBindRanges），改写出数逐字节相同
        {
            var s1 = new WidenSession(2346, 1080, true, false, false); var s2 = new WidenSession(2346, 1080, true, false, false);
            nint p1 = Pinned(768, out byte[] g1, out int o1), p2 = Pinned(768, out byte[] g2, out int o2);
            B(Proj()).CopyTo(g1, o1); B(Proj()).CopyTo(g2, o2);
            int hs1 = s1.Shader("0:0,1,2,3", false), hs2 = s2.Shader("0:0,1,2,3", false);
            int[] sh1 = { hs1, 0, 0, 0, 0, 0 }, sh2 = { hs2, 0, 0, 0, 0, 0 };
            var atl = new[] { new WidenSession.Tex { Id = 7, W = 1024, H = 1024, Scale = 1 } };
            Span<float> pu = stackalloc float[4]; byte[] e1 = new byte[768], e2 = new byte[768];
            s1.Texture(2, 1568, 720, 1, WidenSession.UseRt); s2.Texture(2, 1568, 720, 1, WidenSession.UseRt);
            s1.Frame.OnRenderTargets(2, 0); s2.Frame.OnRenderTargets(2, 0);
            s1.CbufBind(0, 0, p1, 768); s2.CbufBind(0, 0, p2, 768);
            s1.Draw(0, 1568, 720, 1, sh1, WidenSession.DrawColor, atl, pu, out _); s2.Draw(0, 1568, 720, 1, sh2, WidenSession.DrawColor, atl, pu, out _);
            int n1 = s1.CbufEmit(0, 0, e1), n2 = s2.CbufEmit(0, 0, e2);
            // 头一笔认出投影会换镜头签名版本、影子作废（WidenFrame.ScanUpload）：同内容再绑画一笔，影子稳定下来
            s1.CbufBind(0, 0, p1, 768); s2.CbufBind(0, 0, p2, 768);
            s1.Draw(0, 1568, 720, 1, sh1, WidenSession.DrawColor, atl, pu, out _); s2.Draw(0, 1568, 720, 1, sh2, WidenSession.DrawColor, atl, pu, out _);
            // 改投影的深度项 P[10]（字节 [40, 44)，仍是 16:9 透视）：会话 1 整段绑，会话 2 只给更新段 [40, 44)
            float nz = -1.0004f; B(nz).CopyTo(g1, o1 + 40); B(nz).CopyTo(g2, o2 + 40);
            s1.CbufBind(0, 0, p1, 768); s2.CbufBindRanges(0, 0, p2, 768, new[] { (40, 44) });
            s1.Draw(0, 1568, 720, 1, sh1, WidenSession.DrawColor, atl, pu, out _); s2.Draw(0, 1568, 720, 1, sh2, WidenSession.DrawColor, atl, pu, out _);
            Array.Clear(e1); Array.Clear(e2);
            int m1 = s1.CbufEmit(0, 0, e1), m2 = s2.CbufEmit(0, 0, e2);
            Check("按更新段绑：改深度项后两会话出数处数与字节相同、按更新段比了 1 次、没退回", $"{m1} True 1 0", $"{m2} {e1.AsSpan().SequenceEqual(e2)} {s2.Frame.RangeBinds} {s2.Frame.RangeFallbacks}");
            Check("按更新段绑：改深度项后仍改写 P00 = P00 / K（手算 1.3579951 / 1.221875）、[10] 是新值 −1.0004", $"{P00 / K:F5} -1.00040", $"{Fl(e2)[0]:F5} {Fl(e2)[10]:F5}");
            Check("按更新段绑：改前两会话出数相同且有改写", true, n1 == n2 && n1 > 0);
        }
        return fails;
    }
}

/// <summary>收命中（种类 + 字节数），给「屏幕尺寸先于相机系数对」用例</summary>
sealed class HitList1023 : IWidenHitSink
{
    public readonly List<string> Hits = new();
    public void Hit(int bufferOffset, int length, WidenKind kind, bool columnMajor) => Hits.Add($"{kind} {length}");
}

/// <summary>位置求值用例的输入：属性 0 的 x、常量缓冲 4 的 c[0]（下标 0..3 = x..w）</summary>
sealed class PosEnv1023 : IPosEnv
{
    public float Ax; public float[] Cb = new float[4]; public bool UboOk = true;
    public bool Attr(int loc, int lane, out uint bits) { bits = BitConverter.SingleToUInt32Bits(loc == 0 && lane == 0 ? Ax : lane == 3 ? 1f : 0f); return loc == 0; }
    public uint Builtin(uint bi) => 0;
    public bool Ubo(int binding, int off, out uint bits) { bits = 0; if (!UboOk || binding != 4 || off >= 16) return false; bits = BitConverter.SingleToUInt32Bits(Cb[off / 4]); return true; }
}
