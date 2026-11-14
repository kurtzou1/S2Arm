using Ryujinx.Audio.Renderer.Dsp.State;
using Ryujinx.Common.Logging;
using System;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.Arm;

namespace Ryujinx.Audio.Renderer.Dsp
{
    public static class AdpcmHelper
    {
        private const int FixedPointPrecision = 11;
        private const int SamplesPerFrame = 14;
        private const int NibblesPerFrame = SamplesPerFrame + 2;
        private const int BytesPerFrame = 8;
#pragma warning disable IDE0051 // Remove unused private member
        private const int BitsPerFrame = BytesPerFrame * 8;
#pragma warning restore IDE0051

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static uint GetAdpcmDataSize(int sampleCount)
        {
            Debug.Assert(sampleCount >= 0);

            int frames = sampleCount / SamplesPerFrame;
            int extraSize = 0;

            if ((sampleCount % SamplesPerFrame) != 0)
            {
                extraSize = (sampleCount % SamplesPerFrame) / 2 + 1 + (sampleCount % 2);
            }

            return (uint)(BytesPerFrame * frames + extraSize);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static int GetAdpcmOffsetFromSampleOffset(int sampleOffset)
        {
            Debug.Assert(sampleOffset >= 0);

            return GetNibblesFromSampleCount(sampleOffset) / 2;
        }

        public static int NibbleToSample(int nibble)
        {
            int frames = nibble / NibblesPerFrame;
            int extraNibbles = nibble % NibblesPerFrame;
            int samples = SamplesPerFrame * frames;

            return samples + extraNibbles - 2;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static int GetNibblesFromSampleCount(int sampleCount)
        {
            byte headerSize = 0;

            if ((sampleCount % SamplesPerFrame) != 0)
            {
                headerSize = 2;
            }

            return sampleCount % SamplesPerFrame + NibblesPerFrame * (sampleCount / SamplesPerFrame) + headerSize;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static short Saturate(int value)
        {
            if (value > short.MaxValue)
            {
                value = short.MaxValue;
            }

            if (value < short.MinValue)
            {
                value = short.MinValue;
            }

            return (short)value;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static short GetCoefficientAtIndex(ReadOnlySpan<short> coefficients, int index)
        {
            if ((uint)index >= (uint)coefficients.Length)
            {
                Logger.Error?.Print(LogClass.AudioRenderer, $"Out of bound read for coefficient at index {index}");

                return 0;
            }

            return coefficients[index];
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static int Decode(Span<short> output, ReadOnlySpan<byte> input, int startSampleOffset, int endSampleOffset, int offset, int count, ReadOnlySpan<short> coefficients, ref AdpcmLoopContext loopContext)
        {
            if (input.IsEmpty || endSampleOffset < startSampleOffset)
            {
                return 0;
            }

            byte predScale = (byte)loopContext.PredScale;
            byte scale = (byte)(predScale & 0xF);
            byte coefficientIndex = (byte)((predScale >> 4) & 0xF);
            short history0 = loopContext.History0;
            short history1 = loopContext.History1;
            short coefficient0 = GetCoefficientAtIndex(coefficients, coefficientIndex * 2 + 0);
            short coefficient1 = GetCoefficientAtIndex(coefficients, coefficientIndex * 2 + 1);

            int decodedCount = Math.Min(count, endSampleOffset - startSampleOffset - offset);
            int nibbles = GetNibblesFromSampleCount(offset + startSampleOffset);
            int remaining = decodedCount;
            int outputBufferIndex = 0;
            int inputIndex = 0;

            ReadOnlySpan<byte> targetInput;

            targetInput = input[(nibbles / 2)..];

            while (remaining > 0)
            {
                int samplesCount;

                if (((uint)nibbles % NibblesPerFrame) == 0)
                {
                    predScale = targetInput[inputIndex++];

                    scale = (byte)(predScale & 0xF);

                    coefficientIndex = (byte)((predScale >> 4) & 0xF);

                    coefficient0 = GetCoefficientAtIndex(coefficients, coefficientIndex * 2);
                    coefficient1 = GetCoefficientAtIndex(coefficients, coefficientIndex * 2 + 1);

                    nibbles += 2;

                    samplesCount = Math.Min(remaining, SamplesPerFrame);
                }
                else
                {
                    samplesCount = 1;
                }

                int scaleFixedPoint = FixedPointHelper.ToFixed(1.0f, FixedPointPrecision) << scale;

                if (samplesCount < SamplesPerFrame)
                {
                    for (int i = 0; i < samplesCount; i++)
                    {
                        int value = targetInput[inputIndex];

                        int sample;

                        if ((nibbles & 1) != 0)
                        {
                            sample = (value << 28) >> 28;

                            inputIndex++;
                        }
                        else
                        {
                            sample = (value << 24) >> 28;
                        }

                        nibbles++;

                        int prediction = coefficient0 * history0 + coefficient1 * history1;

                        sample = FixedPointHelper.RoundUpAndToInt(sample * scaleFixedPoint + prediction, FixedPointPrecision);

                        short saturatedSample = Saturate(sample);

                        history1 = history0;
                        history0 = saturatedSample;

                        output[outputBufferIndex++] = saturatedSample;

                        remaining--;
                    }
                }
                else
                {
                    // S2Arm (ADPCM 拆解)：半字节拆包向量化（S2A_AUDIO_DSP_FAST=1 开，AdvSimd）。一帧 14 样本 = 7 字节，
                    //   按 8 字节读入拆 16 条 nibble 车道（第 15、16 条是下一帧头，算完不用）：
                    //   拆包 = 拉宽到 16 位车道后 (b << 8) >> 12 / (b << 12) >> 12 符号扩展高/低半 nibble，再 ZIP 成样本序，
                    //   与标量 (value << 24) >> 28 / (value << 28) >> 28 同一比特结果；乘 scaleFixedPoint 后仍为 int32 回绕乘法，
                    //   与标量逐位一致。预测链依赖上一饱和样本（非线性），保持标量逐样本，只吃拆好的车道。
                    //   门槛：本轮起 8 字节可读（末帧差 1 字节时退回标量循环）。
                    if (S2ADspFast.On && AdvSimd.IsSupported && inputIndex + BytesPerFrame <= targetInput.Length)
                    {
                        DecodeFrameAdvSimd(targetInput, inputIndex, scaleFixedPoint, coefficient0, coefficient1, ref history0, ref history1, output.Slice(outputBufferIndex));

                        inputIndex += BytesPerFrame - 1;
                        nibbles += SamplesPerFrame;
                        remaining -= SamplesPerFrame;

                        outputBufferIndex += SamplesPerFrame;
                    }
                    else
                    {
                        for (int i = 0; i < SamplesPerFrame / 2; i++)
                        {
                            int value = targetInput[inputIndex];

                            int sample0;
                            int sample1;

                            sample0 = (value << 24) >> 28;
                            sample1 = (value << 28) >> 28;

                            inputIndex++;

                            int prediction0 = coefficient0 * history0 + coefficient1 * history1;
                            sample0 = FixedPointHelper.RoundUpAndToInt(sample0 * scaleFixedPoint + prediction0, FixedPointPrecision);
                            short saturatedSample0 = Saturate(sample0);

                            int prediction1 = coefficient0 * saturatedSample0 + coefficient1 * history0;
                            sample1 = FixedPointHelper.RoundUpAndToInt(sample1 * scaleFixedPoint + prediction1, FixedPointPrecision);
                            short saturatedSample1 = Saturate(sample1);

                            history1 = saturatedSample0;
                            history0 = saturatedSample1;

                            output[outputBufferIndex++] = saturatedSample0;
                            output[outputBufferIndex++] = saturatedSample1;
                        }

                        nibbles += SamplesPerFrame;
                        remaining -= SamplesPerFrame;
                    }
                }
            }

            loopContext.PredScale = predScale;
            loopContext.History0 = history0;
            loopContext.History1 = history1;

            return decodedCount;
        }

        // S2Arm (ADPCM 拆解)：一帧（14 样本 = 7 字节）拆包 + 乘 scaleFixedPoint 用 AdvSimd，预测链保持标量逐样本
        //   （链依赖上一饱和样本，非线性、不可跨样本并行；拆好的样本从车道顺序取出，链本身与标量同一运算序列）。
        //   拆包：8 字节读入（第 8 字节是下一帧头，只读不用）→ 拉宽 16 位 → (b << 8) >> 12 / (b << 12) >> 12
        //   符号扩展高/低半 nibble → ZIP 交织成样本序（与标量 (value << 24) >> 28 / (value << 28) >> 28 同一比特结果）
        //   → 拉宽 int32、乘 scaleFixedPoint、加舍入半值 1024（int32 回绕加法，先加半值与标量先加预测再半值逐位一致）。
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal static unsafe void DecodeFrameAdvSimd(ReadOnlySpan<byte> input, int inputIndex, int scaleFixedPoint, short coefficient0, short coefficient1, ref short history0, ref short history1, Span<short> output)
        {
            Span<int> samples = stackalloc int[SamplesPerFrame + 2];

            fixed (byte* pInput = input)
            fixed (int* pSamples = samples)
            {
                // 字节 → 16 位（无符号拉宽后按位重解释，字节值 0-255 位型不变）
                Vector128<short> bytes = Vector128.WidenLower(AdvSimd.LoadVector64(pInput + inputIndex).ToVector128()).AsInt16();

                // 高半 nibble：(b << 8) >> 12；低半：(b << 12) >> 12（算术右移带符号扩展）
                Vector128<short> high = AdvSimd.ShiftRightArithmetic(AdvSimd.ShiftLeftLogical(bytes, 8), 12);
                Vector128<short> low = AdvSimd.ShiftRightArithmetic(AdvSimd.ShiftLeftLogical(bytes, 12), 12);

                // 交织回样本序：前 4 字节 → 样本 0-7，后 4 字节 → 样本 8-15（第 15、16 条是下一帧头，算完不用）
                Vector128<short> nibbles0 = AdvSimd.Arm64.ZipLow(high, low);
                Vector128<short> nibbles1 = AdvSimd.Arm64.ZipHigh(high, low);

                Vector128<int> half = Vector128.Create(1 << (FixedPointPrecision - 1));
                Vector128<int> scale = Vector128.Create(scaleFixedPoint);

                AdvSimd.Store(pSamples, AdvSimd.Add(AdvSimd.Multiply(Vector128.WidenLower(nibbles0), scale), half));
                AdvSimd.Store(pSamples + 4, AdvSimd.Add(AdvSimd.Multiply(Vector128.WidenUpper(nibbles0), scale), half));
                AdvSimd.Store(pSamples + 8, AdvSimd.Add(AdvSimd.Multiply(Vector128.WidenLower(nibbles1), scale), half));
                AdvSimd.Store(pSamples + 12, AdvSimd.Add(AdvSimd.Multiply(Vector128.WidenUpper(nibbles1), scale), half));
            }

            for (int i = 0; i < SamplesPerFrame; i++)
            {
                int sample = samples[i] + coefficient0 * history0 + coefficient1 * history1;

                sample >>= FixedPointPrecision;

                short saturatedSample = Saturate(sample);

                history1 = history0;
                history0 = saturatedSample;

                output[i] = saturatedSample;
            }
        }
    }
}
