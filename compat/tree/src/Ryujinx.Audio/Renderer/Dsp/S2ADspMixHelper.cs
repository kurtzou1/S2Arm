using System;
using System.Runtime.CompilerServices;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.Arm;

namespace Ryujinx.Audio.Renderer.Dsp
{
    // S2Arm (10-23 塞尔达分层账：C# 前三热点全是音频 DSP)：降混 / 坡道混音 / 设备输出命令的每缓冲区内核（S2A_AUDIO_DSP_FAST=1 开）。
    //   原先这些循环逐样本写在各命令里，ARM 上没有向量路径（上游只给 Mix/Volume/float 转换写了 SSE/AVX）。
    //   向量路径与标量路径逐样本输出一致：同运算、同求和顺序、同舍入（Math.Round 缺省 = 就近取偶；饱和窄化 = 夹取后截断，
    //   FCVTZS + SQXTN 对 NaN / ±∞ / 越界值与 PcmHelper.Saturate 逐值等价）。坡道的音量序列用同样的逐样本浮点递推构造，
    //   逐位保持与标量一致。本体独立成方法（不依赖运行时开关），tests/audio_dsp_simd 直调两条路径逐位对拍。
    internal static class S2ADspMixHelper
    {
        // 5.1 → 立体声降混。求和顺序照原循环：coefficients[3]*back + coefficients[2]*lfe + coefficients[1]*center + coefficients[0]*front，就近取偶舍入。
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static void DownMixSurroundToStereo(
            Span<float> stereoLeft,
            Span<float> stereoRight,
            ReadOnlySpan<float> frontLeft,
            ReadOnlySpan<float> frontRight,
            ReadOnlySpan<float> frontCenter,
            ReadOnlySpan<float> lowFrequency,
            ReadOnlySpan<float> backLeft,
            ReadOnlySpan<float> backRight,
            ReadOnlySpan<float> coefficients,
            int sampleCount)
        {
            if (S2ADspFast.On && AdvSimd.IsSupported)
            {
                DownMixSurroundToStereoAdvSimd(stereoLeft, stereoRight, frontLeft, frontRight, frontCenter, lowFrequency, backLeft, backRight, coefficients, sampleCount);

                return;
            }

            DownMixSurroundToStereoScalar(stereoLeft, stereoRight, frontLeft, frontRight, frontCenter, lowFrequency, backLeft, backRight, coefficients, 0, sampleCount);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal static void DownMixSurroundToStereoScalar(
            Span<float> stereoLeft,
            Span<float> stereoRight,
            ReadOnlySpan<float> frontLeft,
            ReadOnlySpan<float> frontRight,
            ReadOnlySpan<float> frontCenter,
            ReadOnlySpan<float> lowFrequency,
            ReadOnlySpan<float> backLeft,
            ReadOnlySpan<float> backRight,
            ReadOnlySpan<float> coefficients,
            int start,
            int sampleCount)
        {
            for (int i = start; i < sampleCount; i++)
            {
                stereoLeft[i] = FloatingPointHelper.RoundUp(coefficients[3] * backLeft[i] + coefficients[2] * lowFrequency[i] + coefficients[1] * frontCenter[i] + coefficients[0] * frontLeft[i]);
                stereoRight[i] = FloatingPointHelper.RoundUp(coefficients[3] * backRight[i] + coefficients[2] * lowFrequency[i] + coefficients[1] * frontCenter[i] + coefficients[0] * frontRight[i]);
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal static unsafe void DownMixSurroundToStereoAdvSimd(
            Span<float> stereoLeft,
            Span<float> stereoRight,
            ReadOnlySpan<float> frontLeft,
            ReadOnlySpan<float> frontRight,
            ReadOnlySpan<float> frontCenter,
            ReadOnlySpan<float> lowFrequency,
            ReadOnlySpan<float> backLeft,
            ReadOnlySpan<float> backRight,
            ReadOnlySpan<float> coefficients,
            int sampleCount)
        {
            Vector128<float> c3 = Vector128.Create(coefficients[3]);
            Vector128<float> c2 = Vector128.Create(coefficients[2]);
            Vector128<float> c1 = Vector128.Create(coefficients[1]);
            Vector128<float> c0 = Vector128.Create(coefficients[0]);

            int i = 0;

            fixed (float* pLeft = stereoLeft, pRight = stereoRight, pFrontLeft = frontLeft, pFrontRight = frontRight, pCenter = frontCenter, pLfe = lowFrequency, pBackLeft = backLeft, pBackRight = backRight)
            {
                for (; i < (sampleCount & ~3); i += 4)
                {
                    // 每车道与标量同一求和顺序 ((c3*back + c2*lfe) + c1*center) + c0*front，一次 SIMD 舍入（就近取偶）
                    Vector128<float> left = AdvSimd.Add(AdvSimd.Add(AdvSimd.Add(
                        AdvSimd.Multiply(AdvSimd.LoadVector128(pBackLeft + i), c3),
                        AdvSimd.Multiply(AdvSimd.LoadVector128(pLfe + i), c2)),
                        AdvSimd.Multiply(AdvSimd.LoadVector128(pCenter + i), c1)),
                        AdvSimd.Multiply(AdvSimd.LoadVector128(pFrontLeft + i), c0));
                    Vector128<float> right = AdvSimd.Add(AdvSimd.Add(AdvSimd.Add(
                        AdvSimd.Multiply(AdvSimd.LoadVector128(pBackRight + i), c3),
                        AdvSimd.Multiply(AdvSimd.LoadVector128(pLfe + i), c2)),
                        AdvSimd.Multiply(AdvSimd.LoadVector128(pCenter + i), c1)),
                        AdvSimd.Multiply(AdvSimd.LoadVector128(pFrontRight + i), c0));

                    AdvSimd.Store(pLeft + i, AdvSimd.RoundToNearest(left));
                    AdvSimd.Store(pRight + i, AdvSimd.RoundToNearest(right));
                }
            }

            DownMixSurroundToStereoScalar(stereoLeft, stereoRight, frontLeft, frontRight, frontCenter, lowFrequency, backLeft, backRight, coefficients, i, sampleCount);
        }

        // 坡道混音（output[i] += round(input[i] * volume)）。返回最后一个样本的混音结果（命令要存进 LastSamples）。
        //   音量序列 volume_{k+1} = volume_k + ramp（浮点逐样本递推），向量路径用同样的递推逐车道构造，逐位一致。
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static float MixRamp(Span<float> outputBuffer, ReadOnlySpan<float> inputBuffer, float volume, float ramp, int sampleCount)
        {
            if (S2ADspFast.On && AdvSimd.IsSupported)
            {
                return MixRampAdvSimd(outputBuffer, inputBuffer, volume, ramp, sampleCount);
            }

            return MixRampScalar(outputBuffer, inputBuffer, volume, ramp, 0, sampleCount);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal static float MixRampScalar(Span<float> outputBuffer, ReadOnlySpan<float> inputBuffer, float volume, float ramp, int start, int sampleCount)
        {
            float state = 0;

            for (int i = start; i < sampleCount; i++)
            {
                state = FloatingPointHelper.MultiplyRoundUp(inputBuffer[i], volume);

                outputBuffer[i] += state;
                volume += ramp;
            }

            return state;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal static unsafe float MixRampAdvSimd(Span<float> outputBuffer, ReadOnlySpan<float> inputBuffer, float volume, float ramp, int sampleCount)
        {
            float state = 0;
            int i = 0;

            fixed (float* pOutput = outputBuffer, pInput = inputBuffer)
            {
                for (; i < (sampleCount & ~3); i += 4)
                {
                    // 逐车道音量 = 与标量完全相同的逐样本浮点递推 v, v+r, (v+r)+r, …
                    float v0 = volume;
                    float v1 = v0 + ramp;
                    float v2 = v1 + ramp;
                    float v3 = v2 + ramp;

                    Vector128<float> rounded = AdvSimd.RoundToNearest(AdvSimd.Multiply(AdvSimd.LoadVector128(pInput + i), Vector128.Create(v0, v1, v2, v3)));

                    AdvSimd.Store(pOutput + i, AdvSimd.Add(AdvSimd.LoadVector128(pOutput + i), rounded));

                    state = rounded.GetElement(3);
                    volume = v3 + ramp;
                }
            }

            // 剩余样本（不满 4）落回标量尾部并带回其 state；全部向量处理完时 state 取最后一组的末车道
            if (i < sampleCount)
            {
                return MixRampScalar(outputBuffer, inputBuffer, volume, ramp, i, sampleCount);
            }

            return state;
        }

        // 设备输出 5.1（6 声道）交织（output[6*j + c] = saturate(channel_c[j])）。
        //   窄化同立体声内核（FCVTZS+SQXTN ≡ 夹取后截断）。交织用 TBL 字节表 gather：每 8 帧 6 个声道各窄化成
        //   一个 8×int16 向量（96 字节表），每个 16 字节输出向量按静态字节下标查 3 次接力——TBL 覆盖字节 0-31，
        //   TBLX 两次接力 32-63、64-95；接力下标减 32 / 64 按字节回绕，回绕后 ≥ 224 超表长 → TBLX 保默认车道
        //   （即前一次查到的字节），三次查表互不串扰。TBL 是纯字节搬运，输出与标量循环逐位一致。
        //   缓冲区数不足 6 的（上混）静音声道传空 span：查表用零向量，与原循环先整块清零再只写前面的声道一致。
        //   约定：非空声道长度 ≥ sampleCount。
        public static void SaturateInterleave6(
            Span<short> outputBuffer,
            ReadOnlySpan<float> channel0,
            ReadOnlySpan<float> channel1,
            ReadOnlySpan<float> channel2,
            ReadOnlySpan<float> channel3,
            ReadOnlySpan<float> channel4,
            ReadOnlySpan<float> channel5,
            int sampleCount)
        {
            if (S2ADspFast.On && AdvSimd.Arm64.IsSupported)
            {
                SaturateInterleave6AdvSimd(outputBuffer, channel0, channel1, channel2, channel3, channel4, channel5, sampleCount);

                return;
            }

            SaturateInterleave6Scalar(outputBuffer, channel0, channel1, channel2, channel3, channel4, channel5, 0, sampleCount);
        }

        internal static void SaturateInterleave6Scalar(
            Span<short> outputBuffer,
            ReadOnlySpan<float> channel0,
            ReadOnlySpan<float> channel1,
            ReadOnlySpan<float> channel2,
            ReadOnlySpan<float> channel3,
            ReadOnlySpan<float> channel4,
            ReadOnlySpan<float> channel5,
            int start,
            int sampleCount)
        {
            for (int j = start; j < sampleCount; j++)
            {
                outputBuffer[j * 6 + 0] = PcmHelper.Saturate(channel0.Length > j ? channel0[j] : 0f);
                outputBuffer[j * 6 + 1] = PcmHelper.Saturate(channel1.Length > j ? channel1[j] : 0f);
                outputBuffer[j * 6 + 2] = PcmHelper.Saturate(channel2.Length > j ? channel2[j] : 0f);
                outputBuffer[j * 6 + 3] = PcmHelper.Saturate(channel3.Length > j ? channel3[j] : 0f);
                outputBuffer[j * 6 + 4] = PcmHelper.Saturate(channel4.Length > j ? channel4[j] : 0f);
                outputBuffer[j * 6 + 5] = PcmHelper.Saturate(channel5.Length > j ? channel5[j] : 0f);
            }
        }

        // 静态查表下标：输出第 k 块（每块 16 字节 = 8 个短）第 t 字节属于输出短位置 p = 8k + (t >> 1)——
        //   帧号 f = p / 6、声道 c = p % 6 → 源声道向量的第 f 样本（int16 小端）占表内字节 c * 16 + 2 * f 与 +1；
        //   t 为偶数取低字节（+0）、奇数取高字节（+1）。最大下标 95（声道 5 第 7 样本高字节）< 表长 96。
        //   shift 用于 TBLX 接力（减 32 / 减 64，按字节回绕）。
        private static readonly Vector128<byte>[] Interleave6Indices = BuildInterleave6Indices(0);
        private static readonly Vector128<byte>[] Interleave6IndicesMinus32 = BuildInterleave6Indices(32);
        private static readonly Vector128<byte>[] Interleave6IndicesMinus64 = BuildInterleave6Indices(64);

        private static Vector128<byte>[] BuildInterleave6Indices(int shift)
        {
            var result = new Vector128<byte>[6];
            Span<byte> indices = stackalloc byte[16];

            for (int k = 0; k < 6; k++)
            {
                for (int t = 0; t < 16; t++)
                {
                    int position = 8 * k + (t >> 1);

                    indices[t] = (byte)((position % 6) * 16 + 2 * (position / 6) + (t & 1) - shift);
                }

                result[k] = Vector128.Create(indices);
            }

            return result;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static unsafe Vector128<short> NarrowSaturate8(ReadOnlySpan<float> channel, int j)
        {
            if (channel.IsEmpty)
            {
                return Vector128<short>.Zero;
            }

            fixed (float* pChannel = channel)
            {
                Vector128<float> f0 = AdvSimd.LoadVector128(pChannel + j);
                Vector128<float> f1 = AdvSimd.LoadVector128(pChannel + j + 4);

                return AdvSimd.ExtractNarrowingSaturateUpper(AdvSimd.ExtractNarrowingSaturateLower(AdvSimd.ConvertToInt32RoundToZero(f0)), AdvSimd.ConvertToInt32RoundToZero(f1));
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal static unsafe void SaturateInterleave6AdvSimd(
            Span<short> outputBuffer,
            ReadOnlySpan<float> channel0,
            ReadOnlySpan<float> channel1,
            ReadOnlySpan<float> channel2,
            ReadOnlySpan<float> channel3,
            ReadOnlySpan<float> channel4,
            ReadOnlySpan<float> channel5,
            int sampleCount)
        {
            fixed (short* pOutput = outputBuffer)
            {
                for (int j = 0; j < (sampleCount & ~7); j += 8)
                {
                    Vector128<short> n0 = NarrowSaturate8(channel0, j);
                    Vector128<short> n1 = NarrowSaturate8(channel1, j);
                    Vector128<short> n2 = NarrowSaturate8(channel2, j);
                    Vector128<short> n3 = NarrowSaturate8(channel3, j);
                    Vector128<short> n4 = NarrowSaturate8(channel4, j);
                    Vector128<short> n5 = NarrowSaturate8(channel5, j);

                    byte* p = (byte*)(pOutput + j * 6);

                    for (int k = 0; k < 6; k++)
                    {
                        Vector128<byte> gathered = AdvSimd.Arm64.VectorTableLookup((n0.AsByte(), n1.AsByte()), Interleave6Indices[k]);
                        gathered = AdvSimd.Arm64.VectorTableLookupExtension(gathered, (n2.AsByte(), n3.AsByte()), Interleave6IndicesMinus32[k]);
                        gathered = AdvSimd.Arm64.VectorTableLookupExtension(gathered, (n4.AsByte(), n5.AsByte()), Interleave6IndicesMinus64[k]);

                        AdvSimd.Store(p + 16 * k, gathered);
                    }
                }
            }

            SaturateInterleave6Scalar(outputBuffer, channel0, channel1, channel2, channel3, channel4, channel5, sampleCount & ~7, sampleCount);
        }

        // 坡道音量（output[i] = round(input[i] * volume)，覆盖写；与 VolumeRampCommand 原循环一致）。
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static void VolumeRamp(Span<float> outputBuffer, ReadOnlySpan<float> inputBuffer, float volume, float ramp, int sampleCount)
        {
            if (S2ADspFast.On && AdvSimd.IsSupported)
            {
                VolumeRampAdvSimd(outputBuffer, inputBuffer, volume, ramp, sampleCount);

                return;
            }

            VolumeRampScalar(outputBuffer, inputBuffer, volume, ramp, 0, sampleCount);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal static void VolumeRampScalar(Span<float> outputBuffer, ReadOnlySpan<float> inputBuffer, float volume, float ramp, int start, int sampleCount)
        {
            for (int i = start; i < sampleCount; i++)
            {
                outputBuffer[i] = FloatingPointHelper.MultiplyRoundUp(inputBuffer[i], volume);
                volume += ramp;
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal static unsafe void VolumeRampAdvSimd(Span<float> outputBuffer, ReadOnlySpan<float> inputBuffer, float volume, float ramp, int sampleCount)
        {
            int i = 0;

            fixed (float* pOutput = outputBuffer, pInput = inputBuffer)
            {
                for (; i < (sampleCount & ~3); i += 4)
                {
                    float v0 = volume;
                    float v1 = v0 + ramp;
                    float v2 = v1 + ramp;
                    float v3 = v2 + ramp;

                    AdvSimd.Store(pOutput + i, AdvSimd.RoundToNearest(AdvSimd.Multiply(AdvSimd.LoadVector128(pInput + i), Vector128.Create(v0, v1, v2, v3))));

                    volume = v3 + ramp;
                }
            }

            VolumeRampScalar(outputBuffer, inputBuffer, volume, ramp, i, sampleCount);
        }

        // 设备输出立体声交织（output[2*j] = saturate(left[j])，output[2*j+1] = saturate(right[j])）。
        //   饱和窄化 = FCVTZS（向零截断 + 饱和到 int32）后 SQXTN（饱和窄化到 int16），与 PcmHelper.Saturate 的夹取后截断逐值等价。
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static void SaturateInterleaveStereo(Span<short> outputBuffer, ReadOnlySpan<float> left, ReadOnlySpan<float> right, int sampleCount)
        {
            if (S2ADspFast.On && AdvSimd.Arm64.IsSupported)
            {
                SaturateInterleaveStereoAdvSimd(outputBuffer, left, right, sampleCount);

                return;
            }

            SaturateInterleaveStereoScalar(outputBuffer, left, right, 0, sampleCount);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal static void SaturateInterleaveStereoScalar(Span<short> outputBuffer, ReadOnlySpan<float> left, ReadOnlySpan<float> right, int start, int sampleCount)
        {
            for (int j = start; j < sampleCount; j++)
            {
                outputBuffer[j * 2] = PcmHelper.Saturate(left[j]);
                outputBuffer[j * 2 + 1] = PcmHelper.Saturate(right[j]);
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal static unsafe void SaturateInterleaveStereoAdvSimd(Span<short> outputBuffer, ReadOnlySpan<float> left, ReadOnlySpan<float> right, int sampleCount)
        {
            int j = 0;

            fixed (short* pOutput = outputBuffer)
            fixed (float* pLeft = left, pRight = right)
            {
                for (; j < (sampleCount & ~7); j += 8)
                {
                    Vector128<float> fl0 = AdvSimd.LoadVector128(pLeft + j);
                    Vector128<float> fl1 = AdvSimd.LoadVector128(pLeft + j + 4);
                    Vector128<float> fr0 = AdvSimd.LoadVector128(pRight + j);
                    Vector128<float> fr1 = AdvSimd.LoadVector128(pRight + j + 4);

                    Vector128<short> l = AdvSimd.ExtractNarrowingSaturateUpper(AdvSimd.ExtractNarrowingSaturateLower(AdvSimd.ConvertToInt32RoundToZero(fl0)), AdvSimd.ConvertToInt32RoundToZero(fl1));
                    Vector128<short> r = AdvSimd.ExtractNarrowingSaturateUpper(AdvSimd.ExtractNarrowingSaturateLower(AdvSimd.ConvertToInt32RoundToZero(fr0)), AdvSimd.ConvertToInt32RoundToZero(fr1));

                    // 交织 8 帧：zip 后正好是设备输出的 (L, R, L, R, …) 布局
                    AdvSimd.Store(pOutput + j * 2, AdvSimd.Arm64.ZipLow(l, r));
                    AdvSimd.Store(pOutput + j * 2 + 8, AdvSimd.Arm64.ZipHigh(l, r));
                }
            }

            SaturateInterleaveStereoScalar(outputBuffer, left, right, j, sampleCount);
        }
    }
}
