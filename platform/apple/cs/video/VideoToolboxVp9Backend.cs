// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Common.Logging;
using Ryujinx.Graphics.Video;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Ryujinx.Graphics.Nvdec.Apple
{
    // VideoToolbox 版的 IVp9NativeBackend：与安卓 McVp9Backend（#44）同一契约（一作业一图、NotRepresentable
    // 作业交托管解码器到下个关键帧），后端是 macOS 系统 VP9 硬件解码（AppleVideoDecoder.bundle 的
    // supplemental decoder；直连线 nn::codec 的 S2A_VP9_SYSTEM 走的就是它，#348/#349）。由 AppleVideo 登记在
    // libvpx 后端之前：探针过、会话建得出就硬解，任何一级不行就回退——后端探针不过 → libvpx 原生，
    // 单个作业表示不了 / 硬件解不了 → 托管解码器（Vp9NativePath 的既有机器）。
    //
    // VideoToolbox 没有带外注入通道：tx_mode / reference_mode / 逐作业概率表全部靠重打包帧自带的真压缩头
    // 写进硬件（Vp9CompressedHeader——默认表→供给表的规范增量；写不出的段落在上游 Vp9CompressedHeader.Check
    // 已拦成托管作业）。vpcC 由常量构造：重打包的非压缩头恒写 profile 0 / 8-bit 4:2:0 / color_range 0
    // （视频范围），所以 profile / 位深 / 采样 / videoFullRangeFlag 都是定值（videoFullRangeFlag 实测改像素，
    // 坑记录 2026-11-10；level 41 与色彩「未指定 2/2/2」实测不影响）。宽高由 Vp9NativeParams 直接给出，
    // 不用解析码流——与直连线 vp9_vt_fmt 对 profile 0 视频范围码流构造出的 vpcC 逐字节相同。
    //
    // 这里剩下的判门只有运行时事实，如实回退不伪造（与 McVp9Backend 同一语义）：
    //   · ShowFrame=0（intra-only 隐藏帧）：像素只进参考槽不出图，VideoToolbox 交不出——回 NotRepresentable。
    //   · 短边 < 64：实测建会话 -12911（libvpx 官方短边向量，坑记录 2026-11-10），回 NotRepresentable。
    //   · 尺寸变化的非关键帧：会话按关键帧的编码尺寸建，重建丢参考状态，回 NeedsKeyFrame。
    //   · use_prev_frame_mvs 是推导位（重打包带不了，隐藏 inter 帧让推导与真值偏离）：本会话喂过的帧推导出的
    //     值与作业真值不符 → 回 NotRepresentable（见下面 Decode 处的注释与坑记录 2026-11-11）。
    //   · mvsOut / countsOut 是硬件产不出的量：一概不写（客体缓冲保持上游真值；路径的 _counts 维持全零，
    //     恰是重打包帧 refresh_frame_context=0 的忠实值），不写「全零」这种具体假值；ProducesGuestMetadata=false
    //     让 Vp9NativePath 拦下会读陈旧 MV 的托管作业（Vp9Decoder 的 mvBlocked）。
    //   · 解码 / 出帧出错：会话作废，粘性失败回 Error（Vp9NativePath 三次后停用本上下文的原生路径，不空转）。
    //   · 探针＝注册后实建一次 64x64 会话（VTIsHardwareDecodeSupported 建不出会话时也报 true，不能当判据，#348）。
    //
    // 稳态零托管分配：vpcC / 属性字典每次会话一次，出帧只锁 CVPixelBuffer（retain 到下一次 Decode，契约
    // 「图有效到下一次调用」）+ 解交织进本后端持有的 U/V 平面（容量按需扩后复用）；每帧只有 CoreMedia 的
    // 块 / 样本缓冲两个原生对象（用完即放），与 VideoToolboxH264Decoder 同一口径。
    // 结局记账（真机覆盖率验证，与 mc-vp9 同款）：每 300 作业与 Dispose 各打一行各结局分布。
    internal sealed unsafe partial class VideoToolboxVp9Backend : IVp9NativeBackend   // partial：嵌套互操作类的 LibraryImport 生成要重开本类
    {
        internal const int ProbsSize = 3087;    // Vp9EntropyProbs
        internal const int CountsSize = 13208;  // Vp9BackwardUpdates
        internal const int MvRefSize = 16;      // Vp9MvRef
        private const int MaxDimension = 8192;  // 与 Vp9NativeHeader.Check 同界
        private const int MinDimension = 64;    // VideoToolbox 会话下限（<64 报 -12911，坑记录 2026-11-10）

        private nint _format;    // CMVideoFormatDescriptionRef
        private nint _session;   // VTDecompressionSessionRef
        private int _width, _height;   // 会话当前配置的编码尺寸
        private bool _fed;             // 本会话喂过至少一帧（use_prev 推导要「上一帧」）
        private bool _lastFedKey;      // 上一帧是否关键帧（喂进来的只可能是关键帧或 inter——帧内隐藏帧上游已拦）
        private nint _pixelBuffer;    // 出帧 CVPixelBuffer（retain + 只读锁住，到下一次 Decode）
        private byte* _u, _v;          // 解交织后的色度平面（本后端持有）
        private nuint _uvCap;          // 每个色度平面的字节数
        private readonly OutputSlot* _slot = (OutputSlot*)NativeMemory.AllocZeroed((nuint)sizeof(OutputSlot));
        private bool _failed;

        // 结局记账（真机覆盖率验证）：每 300 作业与 Dispose 各打一行分布。hidden/shape/size/error 是本后端
        // 判出的回退；Vp9NativePath 层面拦下的作业（上游 Check 的帧形段、压缩头段、槽位等）经 NoteFallback 记进 fb: 账本。
        private int _jobs, _decoded, _nrHidden, _nrShape, _nrSize, _nrPrevMvs, _errors;

        // Vp9NativePath 交回托管的作业按原因计数，随 outcome 行同排输出，分母是总作业数。
        private readonly SortedDictionary<string, int> _fallbacks = new();

        public void NoteFallback(string reason)
        {
            _fallbacks.TryGetValue(reason, out int n);
            _fallbacks[reason] = n + 1;
        }

        private string FallbackLedger()
        {
            if (_fallbacks.Count == 0) return "";
            var b = new StringBuilder(" fb:");
            foreach (var kv in _fallbacks) b.Append($" {kv.Key}={kv.Value}/{_jobs}");
            return b.ToString();
        }

        private Vp9NativeResult Done(Vp9NativeResult r, ref int bucket)
        {
            bucket++;
            if (++_jobs % 300 == 0) Report();
            return r;
        }

        private void Report() => Logger.Info?.Print(LogClass.Nvdec,
            $"vt-vp9 outcome: jobs={_jobs} decoded={_decoded} hidden={_nrHidden} shape={_nrShape} size/key={_nrSize} prev_mvs={_nrPrevMvs} error={_errors}{FallbackLedger()}");

        // CVPixelBuffer 的样本值交不出 MV 字段 / 反向更新计数：Decoded 不写 mvsOut/countsOut，
        // 客体 MV 缓冲保持上游内容；调用方据此拦下会读陈旧 MV 的托管作业。
        public bool ProducesGuestMetadata => false;

        // 没有带外注入通道：概率增量只能走位流——真压缩头必须随帧带上（上游 Vp9CompressedHeader.Check 已拦下写不出的段）。
        public bool NeedsCompressedHeader => true;

        // 缺省关（S2A_NVDEC_VP9_VT=1 才开）：合成流里硬解只接得住 28/134 个作业，其余退到托管软件解码器（更费 CPU，宽高不是 64 倍数的流会画错），
        //   libvpx 134/134 全对——缺省保持 libvpx 原生；S2A_NVDEC_VP9=managed 关掉整条原生路径。
        public static VideoToolboxVp9Backend TryCreate()
        {
            if (Environment.GetEnvironmentVariable("S2A_NVDEC_VP9_VT") != "1") return null;
            return Available() ? new VideoToolboxVp9Backend() : null;
        }

        // 探针结果进程内缓存一次（-1 = 没测过，1 = 可用，0 = 不可用）：会话级探测不值每个解码上下文重付一遍；
        // 并发重复探测幂等（注册与建会话都可重入）。
        private static int _probe = -1;

        internal static bool Available()
        {
            int seen = Volatile.Read(ref _probe);
            if (seen >= 0)
            {
                return seen == 1;
            }

            bool ok = Probe();
            Volatile.Write(ref _probe, ok ? 1 : 0);
            return ok;
        }

        // 注册后实建一次 64x64 会话（注册 API macOS 11+；iOS 18 部署目标没有——iOS 一律 libvpx）。
        private static bool Probe()
        {
            if (!OperatingSystem.IsMacOS()) return false;

            try
            {
                Vp9VideoToolbox.VTRegisterSupplementalVideoDecoderIfAvailable(CodecVp9);

                if (CreateFormat(64, 64, out nint format) != 0)
                {
                    return false;
                }

                nint attrs = 0, session = 0;
                int st = -1;
                try
                {
                    attrs = CreateAttrs();
                    st = Vp9VideoToolbox.VTDecompressionSessionCreate(0, format, 0, attrs, null, &session);
                }
                finally
                {
                    if (attrs != 0) Vp9CoreFoundation.CFRelease(attrs);
                    if (session != 0)
                    {
                        Vp9VideoToolbox.VTDecompressionSessionInvalidate(session);
                        Vp9CoreFoundation.CFRelease(session);
                    }

                    Vp9CoreFoundation.CFRelease(format);
                }

                return st == 0;
            }
            catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException)
            {
                return false;
            }
        }

        public Vp9NativeResult Decode(
            ReadOnlySpan<byte> frame,
            ReadOnlySpan<byte> probs,
            in Vp9NativeParams p,
            ReadOnlySpan<byte> prevMvs,
            Span<byte> mvsOut,
            Span<byte> countsOut,
            out Vp9NativePicture picture,
            out string error)
        {
            picture = default;
            error = null;

            if (_failed)
            {
                error = "videotoolbox sticky failure";
                return Done(Vp9NativeResult.Error, ref _errors);
            }

            // 隐藏帧的像素 VideoToolbox 交不出——如实回退，本作业走托管。
            if (p.ShowFrame == 0)
            {
                return Done(Vp9NativeResult.NotRepresentable, ref _nrHidden);
            }

            if (p.Width < MinDimension || p.Height < MinDimension || p.Width > MaxDimension || p.Height > MaxDimension ||
                probs.Length != ProbsSize || countsOut.Length != CountsSize ||
                mvsOut.Length == 0 || mvsOut.Length % MvRefSize != 0)
            {
                return Done(Vp9NativeResult.NotRepresentable, ref _nrShape);
            }

            // 尺寸变化：会话按关键帧的编码尺寸建，重建丢参考状态，非关键帧如实回 NeedsKeyFrame。
            if (_session != 0 && (p.Width != _width || p.Height != _height))
            {
                DestroySession();
                ReleasePicture();

                if (p.IntraFrame == 0)
                {
                    return Done(Vp9NativeResult.NeedsKeyFrame, ref _nrSize);
                }
            }

            // use_prev_frame_mvs 是推导位，重打包的非压缩头 / 压缩头都带不了（libvpx read_uncompressed_header：
            // !error_resilient && 同尺寸 && 上帧已显示 && 上帧非关键帧 / 非帧内；重打包恒写 error_resilient=0、
            // show_frame=1——隐藏帧只在帧内形态被上游拦下，隐藏 inter 帧也按已显示喂进来）。本会话自己喂过的帧
            // 推导出的值与作业真值（UsePrevFrameMvs，寄存器给的真标志）不一致时，真实解码器无法表示这个作业——
            // 如实回 NotRepresentable，本作业走托管（libvpx hook 走带外注入不受此限）。典型触发：上一个是隐藏
            // inter 帧（真 show=0 → 真值 use_prev=0），硬件按「上帧已显示」推导出 1。关键帧不消费 MV，本门不拦
            // （拦了会把重激活的关键帧也回掉——关键帧之后推导恒 0、真值也恒 0）。
            if (p.IntraFrame == 0 &&
                (_fed && !_lastFedKey && p.Width == _width && p.Height == _height ? 1 : 0) != p.UsePrevFrameMvs)
            {
                return Done(Vp9NativeResult.NotRepresentable, ref _nrPrevMvs);
            }

            // 上一次的出图到此为止（契约：图有效到下一次调用）。
            ReleasePicture();

            if (_session == 0 && OpenSession(p.Width, p.Height) != 0)
            {
                return Sticky("session", out error);
            }

            int st = Submit(frame);

            if (st != 0)
            {
                return Sticky($"decode {st}", out error);
            }

            st = Emit(p.Width, p.Height, out picture);

            if (st != 0)
            {
                return Sticky($"output {st}", out error);
            }

            _fed = true;
            _lastFedKey = p.IntraFrame == 1;

            return Done(Vp9NativeResult.Decoded, ref _decoded);
        }

        private Vp9NativeResult Sticky(string what, out string error)
        {
            _failed = true;
            DestroySession();
            ReleasePicture();
            error = $"videotoolbox {what}";
            return Done(Vp9NativeResult.Error, ref _errors);
        }

        // 提交一个样本、同步等出帧：0 = 成功（像素缓冲在 _slot），否则提交 / 回调状态（没出帧记 -1）。失败时不留像素缓冲。
        private int Submit(ReadOnlySpan<byte> frame)
        {
            int st;
            fixed (byte* p = frame)
            {
                nint block = 0, sample = 0;
                st = Vp9CoreMedia.CMBlockBufferCreateWithMemoryBlock(0, p, (nuint)frame.Length, Vp9CoreFoundation.AllocatorNull, null, 0, (nuint)frame.Length, 0, &block);

                if (st == 0)
                {
                    nuint size = (nuint)frame.Length;
                    st = Vp9CoreMedia.CMSampleBufferCreateReady(0, block, _format, 1, 0, null, 1, &size, &sample);
                }

                if (st == 0)
                {
                    _slot->ImageBuffer = 0;
                    _slot->Status = -1;
                    uint info;
                    st = Vp9VideoToolbox.VTDecompressionSessionDecodeFrame(_session, sample, 0, _slot, &info);

                    if (st == 0)
                    {
                        // VP9 无重排：一进一出，等到的就是本作业的图。
                        Vp9VideoToolbox.VTDecompressionSessionWaitForAsynchronousFrames(_session);
                        st = _slot->Status != 0 ? _slot->Status : _slot->ImageBuffer == 0 ? -1 : 0;
                    }
                }

                if (sample != 0)
                {
                    Vp9CoreFoundation.CFRelease(sample);
                }

                if (block != 0)
                {
                    Vp9CoreFoundation.CFRelease(block);
                }
            }

            if (st != 0 && _slot->ImageBuffer != 0)
            {
                Vp9CoreFoundation.CFRelease(_slot->ImageBuffer);
                _slot->ImageBuffer = 0;
            }

            return st;
        }

        // vpcC 12 字节：FullBox version=1 flags=0 + VPCodecConfigurationRecord（profile 0 / level 41 / 8-bit 4:2:0 /
        // 视频范围；色彩「未指定 2/2/2」）。与直连线 vp9_vt_fmt 对 profile 0 视频范围码流构造出的逐字节相同
        // （#349：色彩字段实测不影响像素，videoFullRangeFlag 会；重打包关键帧恒写 color_range=0）。
        private static readonly byte[] VpcC = [1, 0, 0, 0, 0, 41, 0x82, 2, 2, 2, 0, 0];

        private static int CreateFormat(int width, int height, out nint format)
        {
            format = 0;
            nint data = 0, atoms = 0, ext = 0, fmt = 0;
            int st = -1;

            try
            {
                fixed (byte* v = VpcC)
                {
                    data = Vp9CoreFoundation.CFDataCreate(0, v, (nint)VpcC.Length);
                }

                if (data == 0 || Vp9CoreFoundation.VpcCAtomKey == 0) return -1;

                nint* ak = stackalloc nint[1] { Vp9CoreFoundation.VpcCAtomKey };
                nint* av = stackalloc nint[1] { data };
                atoms = Vp9CoreFoundation.CFDictionaryCreate(0, ak, av, 1, Vp9CoreFoundation.TypeDictionaryKeyCallBacks, Vp9CoreFoundation.TypeDictionaryValueCallBacks);
                if (atoms == 0) return -1;

                nint* ek = stackalloc nint[1] { Vp9CoreMedia.SampleDescriptionExtensionAtomsKey };
                nint* ev = stackalloc nint[1] { atoms };
                ext = Vp9CoreFoundation.CFDictionaryCreate(0, ek, ev, 1, Vp9CoreFoundation.TypeDictionaryKeyCallBacks, Vp9CoreFoundation.TypeDictionaryValueCallBacks);
                if (ext == 0) return -1;

                st = Vp9CoreMedia.CMVideoFormatDescriptionCreate(0, CodecVp9, (nint)width, (nint)height, ext, &fmt);
            }
            finally
            {
                if (ext != 0) Vp9CoreFoundation.CFRelease(ext);
                if (atoms != 0) Vp9CoreFoundation.CFRelease(atoms);
                if (data != 0) Vp9CoreFoundation.CFRelease(data);
            }

            format = fmt;
            return st;
        }

        // 请求 420v（视频范围）：重打包恒 color_range=0，样本值原样出（420f 是全范围的转换输出，出现了就回 Error，不做范围转换）。
        private static nint CreateAttrs()
        {
            nint attrs = Vp9CoreFoundation.CFDictionaryCreateMutable(0, 1, Vp9CoreFoundation.TypeDictionaryKeyCallBacks, Vp9CoreFoundation.TypeDictionaryValueCallBacks);
            uint fmt = PixelFormat420v;
            nint num = Vp9CoreFoundation.CFNumberCreate(0, 3 /* kCFNumberSInt32Type */, &fmt);
            Vp9CoreFoundation.CFDictionarySetValue(attrs, Vp9CoreVideo.PixelBufferPixelFormatTypeKey, num);
            Vp9CoreFoundation.CFRelease(num);
            return attrs;
        }

        private int OpenSession(int width, int height)
        {
            if (CreateFormat(width, height, out nint format) != 0)
            {
                return -1;
            }

            nint attrs = 0, session = 0;
            int st = -1;
            try
            {
                attrs = CreateAttrs();
                OutputCallbackRecord cb = new() { Callback = &OnOutput, RefCon = 0 };
                st = Vp9VideoToolbox.VTDecompressionSessionCreate(0, format, 0, attrs, &cb, &session);
            }
            finally
            {
                if (attrs != 0) Vp9CoreFoundation.CFRelease(attrs);
            }

            if (st != 0)
            {
                Vp9CoreFoundation.CFRelease(format);
                return st;
            }

            _format = format;
            _session = session;
            _width = width;
            _height = height;
            Logger.Info?.Print(LogClass.Nvdec, $"VideoToolbox VP9：{width}x{height} 会话建好（vpcC 12 字节，视频范围）");
            return 0;
        }

        [UnmanagedCallersOnly]
        private static void OnOutput(nint decoderRefCon, nint frameRefCon, int status, uint infoFlags, nint imageBuffer, CMTime pts, CMTime duration)
        {
            OutputSlot* slot = (OutputSlot*)frameRefCon;

            // VP9 无重排，一提交一出图；多出来的一张先放掉，不覆盖泄漏。
            if (slot->ImageBuffer != 0)
            {
                Vp9CoreFoundation.CFRelease(slot->ImageBuffer);
                slot->ImageBuffer = 0;
            }

            slot->Status = status;

            if (status == 0 && imageBuffer != 0)
            {
                slot->ImageBuffer = Vp9CoreFoundation.CFRetain(imageBuffer);
            }
        }

        // VT 出帧（420v 双平面）→ I420 三平面：Y 直接引用锁住的像素缓冲（行距带 VT 的对齐），
        // 交错 UV 解交织进本后端持有的 U/V 平面。0 = 成功；-1 = 输出形态与请求不符；-2 = 尺寸与作业不符；-3 = 色度平面分配不出。
        private int Emit(int width, int height, out Vp9NativePicture picture)
        {
            picture = default;
            nint buffer = _slot->ImageBuffer;
            _slot->ImageBuffer = 0;

            if (Vp9CoreVideo.CVPixelBufferGetPixelFormatType(buffer) != PixelFormat420v || Vp9CoreVideo.CVPixelBufferGetPlaneCount(buffer) != 2)
            {
                Vp9CoreFoundation.CFRelease(buffer);
                return -1;
            }

            Vp9CoreVideo.CVPixelBufferLockBaseAddress(buffer, 1 /* kCVPixelBufferLock_ReadOnly */);

            int w = (int)Vp9CoreVideo.CVPixelBufferGetWidth(buffer);
            int h = (int)Vp9CoreVideo.CVPixelBufferGetHeight(buffer);

            if (w != width || h != height)
            {
                Vp9CoreVideo.CVPixelBufferUnlockBaseAddress(buffer, 1);
                Vp9CoreFoundation.CFRelease(buffer);
                return -2;
            }

            int cw = (w + 1) >> 1, ch = (h + 1) >> 1;

            if (_uvCap < (nuint)(cw * ch))
            {
                NativeMemory.Free(_u);
                NativeMemory.Free(_v);
                _u = (byte*)NativeMemory.AllocZeroed((nuint)(cw * ch));
                _v = (byte*)NativeMemory.AllocZeroed((nuint)(cw * ch));
                _uvCap = _u != null && _v != null ? (nuint)(cw * ch) : 0;
            }

            if (_uvCap == 0)
            {
                Vp9CoreVideo.CVPixelBufferUnlockBaseAddress(buffer, 1);
                Vp9CoreFoundation.CFRelease(buffer);
                return -3;
            }

            byte* uv = (byte*)Vp9CoreVideo.CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
            nuint uvp = Vp9CoreVideo.CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);

            for (int r = 0; r < ch; r++)
            {
                byte* s = uv + (nuint)r * uvp;
                byte* u = _u + (nuint)r * (nuint)cw, v = _v + (nuint)r * (nuint)cw;
                for (int x = 0; x < cw; x++)
                {
                    u[x] = s[2 * x];
                    v[x] = s[2 * x + 1];
                }
            }

            _pixelBuffer = buffer;   // retain + 只读锁保持到下一次 Decode（契约：图有效到下一次调用）

            picture = new Vp9NativePicture(
                Vp9CoreVideo.CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                (nint)_u,
                (nint)_v,
                (int)Vp9CoreVideo.CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                cw, w, h);
            return 0;
        }

        private void ReleasePicture()
        {
            if (_pixelBuffer != 0)
            {
                Vp9CoreVideo.CVPixelBufferUnlockBaseAddress(_pixelBuffer, 1);
                Vp9CoreFoundation.CFRelease(_pixelBuffer);
                _pixelBuffer = 0;
            }
        }

        private void DestroySession()
        {
            if (_session != 0)
            {
                Vp9VideoToolbox.VTDecompressionSessionInvalidate(_session);
                Vp9CoreFoundation.CFRelease(_session);
                _session = 0;
            }

            if (_format != 0)
            {
                Vp9CoreFoundation.CFRelease(_format);
                _format = 0;
            }

            _width = _height = 0;
            _fed = false;
            _lastFedKey = false;
        }

        public void Dispose()
        {
            Report();
            DestroySession();
            ReleasePicture();
            NativeMemory.Free(_u);
            NativeMemory.Free(_v);
            _u = _v = null;
            _uvCap = 0;
            NativeMemory.Free(_slot);
        }

        private struct OutputSlot
        {
            public nint ImageBuffer;   // 回调交来的 CVPixelBuffer（已 retain）
            public int Status;
        }

        private const uint CodecVp9 = 0x76703039;        // kCMVideoCodecType_VP9（'vp09'）
        private const uint PixelFormat420v = 0x34323076;  // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange（'420v'，样本值原样）

        [StructLayout(LayoutKind.Sequential)]
        private struct CMTime
        {
            public long Value;
            public int Timescale;
            public uint Flags;
            public long Epoch;
        }

        [StructLayout(LayoutKind.Sequential)]
        private unsafe struct OutputCallbackRecord
        {
            public delegate* unmanaged<nint, nint, int, uint, nint, CMTime, CMTime, void> Callback;
            public nint RefCon;
        }

        // 互操作按 VideoToolboxH264Decoder 的自包含样式单放一份（类名带 Vp9 前缀，不与它的 partial 合并）：
        // tests/vp9_native_parity 直接编本文件，合并会让单编缺另一边的成员。
        static unsafe partial class Vp9CoreFoundation
        {
            private const string Lib = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";

            [LibraryImport(Lib)] public static partial void CFRelease(nint obj);
            [LibraryImport(Lib)] public static partial nint CFRetain(nint obj);
            [LibraryImport(Lib)] public static partial nint CFDataCreate(nint allocator, byte* bytes, nint length);
            [LibraryImport(Lib)] public static partial nint CFDictionaryCreate(nint allocator, nint* keys, nint* values, nint count, nint keyCallBacks, nint valueCallBacks);
            [LibraryImport(Lib)] public static partial nint CFDictionaryCreateMutable(nint allocator, nint capacity, nint keyCallBacks, nint valueCallBacks);
            [LibraryImport(Lib)] public static partial void CFDictionarySetValue(nint dict, nint key, nint value);
            [LibraryImport(Lib)] public static partial nint CFNumberCreate(nint allocator, int type, void* value);
            [LibraryImport(Lib)] public static partial nint CFStringCreateWithCString(nint allocator, byte* cStr, int encoding);   // encoding: 0x0600 = kCFStringEncodingASCII

            // 数据符号：回调表取地址，常量对象取变量里的值
            private static readonly nint _handle = NativeLibrary.Load(Lib);
            public static readonly nint TypeDictionaryKeyCallBacks = NativeLibrary.GetExport(_handle, "kCFTypeDictionaryKeyCallBacks");
            public static readonly nint TypeDictionaryValueCallBacks = NativeLibrary.GetExport(_handle, "kCFTypeDictionaryValueCallBacks");
            public static readonly nint AllocatorNull = *(nint*)NativeLibrary.GetExport(_handle, "kCFAllocatorNull");

            // CFSTR("vpcC") 的运行时等价物（CFSTR 字面量在 C# 里造不出；进程内一份，与字面量同样常驻）
            public static readonly nint VpcCAtomKey = CreateVpcCString();

            private static nint CreateVpcCString()
            {
                byte[] name = [(byte)'v', (byte)'p', (byte)'c', (byte)'C', 0];
                fixed (byte* p = name)
                {
                    return CFStringCreateWithCString(0, p, 0x0600 /* kCFStringEncodingASCII */);
                }
            }
        }

        static unsafe partial class Vp9CoreMedia
        {
            private const string Lib = "/System/Library/Frameworks/CoreMedia.framework/CoreMedia";

            [LibraryImport(Lib)]
            public static partial int CMVideoFormatDescriptionCreate(nint allocator, uint codecType, nint width, nint height, nint extensions, nint* format);

            [LibraryImport(Lib)]
            public static partial int CMBlockBufferCreateWithMemoryBlock(nint allocator, void* memory, nuint blockLength, nint blockAllocator, void* customSource, nuint offset, nuint dataLength, uint flags, nint* block);

            [LibraryImport(Lib)]
            public static partial int CMSampleBufferCreateReady(nint allocator, nint block, nint format, nint numSamples, nint numTimings, void* timings, nint numSizes, nuint* sizes, nint* sample);

            private static readonly nint _handle = NativeLibrary.Load(Lib);
            public static readonly nint SampleDescriptionExtensionAtomsKey = *(nint*)NativeLibrary.GetExport(_handle, "kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms");
        }

        static unsafe partial class Vp9VideoToolbox
        {
            private const string Lib = "/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox";

            [LibraryImport(Lib)]
            public static partial void VTRegisterSupplementalVideoDecoderIfAvailable(uint codecType);

            [LibraryImport(Lib)]
            public static partial int VTDecompressionSessionCreate(nint allocator, nint format, nint decoderSpec, nint imageAttrs, OutputCallbackRecord* callback, nint* session);

            [LibraryImport(Lib)]
            public static partial int VTDecompressionSessionDecodeFrame(nint session, nint sample, uint flags, void* frameRefCon, uint* infoFlags);

            [LibraryImport(Lib)]
            public static partial int VTDecompressionSessionWaitForAsynchronousFrames(nint session);

            [LibraryImport(Lib)]
            public static partial void VTDecompressionSessionInvalidate(nint session);
        }

        static unsafe partial class Vp9CoreVideo
        {
            private const string Lib = "/System/Library/Frameworks/CoreVideo.framework/CoreVideo";

            [LibraryImport(Lib)] public static partial int CVPixelBufferLockBaseAddress(nint buffer, ulong flags);
            [LibraryImport(Lib)] public static partial int CVPixelBufferUnlockBaseAddress(nint buffer, ulong flags);
            [LibraryImport(Lib)] public static partial nint CVPixelBufferGetBaseAddressOfPlane(nint buffer, nuint plane);
            [LibraryImport(Lib)] public static partial nuint CVPixelBufferGetBytesPerRowOfPlane(nint buffer, nuint plane);
            [LibraryImport(Lib)] public static partial nuint CVPixelBufferGetWidth(nint buffer);
            [LibraryImport(Lib)] public static partial nuint CVPixelBufferGetHeight(nint buffer);
            [LibraryImport(Lib)] public static partial nuint CVPixelBufferGetPlaneCount(nint buffer);
            [LibraryImport(Lib)] public static partial uint CVPixelBufferGetPixelFormatType(nint buffer);

            private static readonly nint _handle = NativeLibrary.Load(Lib);
            public static readonly nint PixelBufferPixelFormatTypeKey = *(nint*)NativeLibrary.GetExport(_handle, "kCVPixelBufferPixelFormatTypeKey");
        }
    }
}
