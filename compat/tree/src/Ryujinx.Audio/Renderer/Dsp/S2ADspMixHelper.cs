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
