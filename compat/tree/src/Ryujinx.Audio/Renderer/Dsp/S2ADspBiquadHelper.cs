using Ryujinx.Audio.Renderer.Dsp.State;
using Ryujinx.Audio.Renderer.Parameter;
using System;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.Arm;

namespace Ryujinx.Audio.Renderer.Dsp
{
    // S2Arm (双二阶跨声道打包)：多档双二阶滤波（MultiTapBiquadFilterCommand）的两声道打包内核（S2A_AUDIO_DSP_FAST=1 开）。
    //   IIR 的递归依赖只在声道内：两声道入 Vector64<float> 两条车道，同一时间步并行递推即可向量化；命令层把两声道
    //   交给同一条命令（GenerateMultiTapBiquadFilterStereo）。每车道运算与求和顺序同上游逐级循环（直接形式 1、
    //   局部状态），两级融合（第二级直接吃第一级本步刚算出的车道结果，第 i 样本第二级的输入就是第一级的第 i 样本
    //   输出，与逐级循环等价），输出与标量路径逐位一致。本体独立成方法（不依赖运行时开关），tests/audio_dsp_simd
    //   直调两条路径逐位对拍。
    internal static class S2ADspBiquadHelper
    {
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static void ProcessBiquadFilterStereo(
            ReadOnlySpan<BiquadFilterParameter2> parameters,
            Span<BiquadFilterState> states0,
            Span<BiquadFilterState> states1,
            Span<float> outputBuffer0,
            Span<float> outputBuffer1,
            ReadOnlySpan<float> inputBuffer0,
            ReadOnlySpan<float> inputBuffer1,
            uint sampleCount)
        {
            if (S2ADspFast.On && AdvSimd.IsSupported)
            {
                ProcessBiquadFilterStereoAdvSimd(parameters, states0, states1, outputBuffer0, outputBuffer1, inputBuffer0, inputBuffer1, sampleCount);

                return;
            }

            ProcessBiquadFilterStereoScalar(parameters, states0, states1, outputBuffer0, outputBuffer1, inputBuffer0, inputBuffer1, sampleCount);
        }

        // 标量路径 = 上游多级循环（直接形式 1、状态放局部变量逐样本推进、末尾写回）逐声道跑两遍的融合体：
        //   级外层（两级）、声道按车道并排，每样本两级连续算完；运算与求和顺序同上游循环。
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal static void ProcessBiquadFilterStereoScalar(
            ReadOnlySpan<BiquadFilterParameter2> parameters,
            Span<BiquadFilterState> states0,
            Span<BiquadFilterState> states1,
            Span<float> outputBuffer0,
            Span<float> outputBuffer1,
            ReadOnlySpan<float> inputBuffer0,
            ReadOnlySpan<float> inputBuffer1,
            uint sampleCount)
        {
            Debug.Assert(parameters.Length == 2);

            for (int stageIndex = 0; stageIndex < parameters.Length; stageIndex++)
            {
                Span<float> numeratorSpan = parameters[stageIndex].Numerator.AsSpan();
                Span<float> denominatorSpan = parameters[stageIndex].Denominator.AsSpan();

                float a0 = numeratorSpan[0];
                float a1 = numeratorSpan[1];
                float a2 = numeratorSpan[2];

                float b1 = denominatorSpan[0];
                float b2 = denominatorSpan[1];

                ref BiquadFilterState state0 = ref states0[stageIndex];
                ref BiquadFilterState state1 = ref states1[stageIndex];

                float s00 = state0.State0, s01 = state0.State1, s02 = state0.State2, s03 = state0.State3;
                float s10 = state1.State0, s11 = state1.State1, s12 = state1.State2, s13 = state1.State3;

                ReadOnlySpan<float> src0 = stageIndex != 0 ? outputBuffer0 : inputBuffer0;
                ReadOnlySpan<float> src1 = stageIndex != 0 ? outputBuffer1 : inputBuffer1;

                for (int i = 0; i < sampleCount; i++)
                {
                    float x0 = src0[i];
                    float y0 = x0 * a0 + s00 * a1 + s01 * a2 + s02 * b1 + s03 * b2;

                    s01 = s00;
                    s00 = x0;
                    s03 = s02;
                    s02 = y0;

                    float x1 = src1[i];
                    float y1 = x1 * a0 + s10 * a1 + s11 * a2 + s12 * b1 + s13 * b2;

                    s11 = s10;
                    s10 = x1;
                    s13 = s12;
                    s12 = y1;

                    outputBuffer0[i] = y0;
                    outputBuffer1[i] = y1;
                }

                state0.State0 = s00; state0.State1 = s01; state0.State2 = s02; state0.State3 = s03;
                state1.State0 = s10; state1.State1 = s11; state1.State2 = s12; state1.State3 = s13;
            }
        }

        // 两条车道 = 声道 0 / 声道 1；每步两级直接形式 1 递推，求和顺序与标量一致：((x*a0 + s0*a1) + s1*a2) + s2*b1) + s3*b2
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal static void ProcessBiquadFilterStereoAdvSimd(
            ReadOnlySpan<BiquadFilterParameter2> parameters,
            Span<BiquadFilterState> states0,
            Span<BiquadFilterState> states1,
            Span<float> outputBuffer0,
            Span<float> outputBuffer1,
            ReadOnlySpan<float> inputBuffer0,
            ReadOnlySpan<float> inputBuffer1,
            uint sampleCount)
        {
            Debug.Assert(parameters.Length == 2);

            // 参数先整体拷到局部再取字段 span：Array2/Array3.AsSpan() 是对结构体字段取引用，
            //   对「parameters[i] 这个临时副本」的字段取 span，Release 下 JIT 会把多个临时复用同一栈槽，
            //   四个 span 全部别名到后取的那份参数（实测 stage 0 用了 stage 1 的系数）。局部拷贝活到方法尾，span 才有效。
            BiquadFilterParameter2 parameter0 = parameters[0];
            BiquadFilterParameter2 parameter1 = parameters[1];

            Span<float> numerator0Span = parameter0.Numerator.AsSpan();
            Span<float> denominator0Span = parameter0.Denominator.AsSpan();
            Span<float> numerator1Span = parameter1.Numerator.AsSpan();
            Span<float> denominator1Span = parameter1.Denominator.AsSpan();

            Vector64<float> a00 = Vector64.Create(numerator0Span[0]);
            Vector64<float> a10 = Vector64.Create(numerator0Span[1]);
            Vector64<float> a20 = Vector64.Create(numerator0Span[2]);
            Vector64<float> b10 = Vector64.Create(denominator0Span[0]);
            Vector64<float> b20 = Vector64.Create(denominator0Span[1]);

            Vector64<float> a01 = Vector64.Create(numerator1Span[0]);
            Vector64<float> a11 = Vector64.Create(numerator1Span[1]);
            Vector64<float> a21 = Vector64.Create(numerator1Span[2]);
            Vector64<float> b11 = Vector64.Create(denominator1Span[0]);
            Vector64<float> b21 = Vector64.Create(denominator1Span[1]);

            Vector64<float> s00 = Vector64.Create(states0[0].State0, states1[0].State0);
            Vector64<float> s01 = Vector64.Create(states0[0].State1, states1[0].State1);
            Vector64<float> s02 = Vector64.Create(states0[0].State2, states1[0].State2);
            Vector64<float> s03 = Vector64.Create(states0[0].State3, states1[0].State3);

            Vector64<float> s10 = Vector64.Create(states0[1].State0, states1[1].State0);
            Vector64<float> s11 = Vector64.Create(states0[1].State1, states1[1].State1);
            Vector64<float> s12 = Vector64.Create(states0[1].State2, states1[1].State2);
            Vector64<float> s13 = Vector64.Create(states0[1].State3, states1[1].State3);

            for (int i = 0; i < sampleCount; i++)
            {
                Vector64<float> x = Vector64.Create(inputBuffer0[i], inputBuffer1[i]);

                Vector64<float> y0 = AdvSimd.Add(AdvSimd.Add(AdvSimd.Add(
                    AdvSimd.Multiply(x, a00),
                    AdvSimd.Multiply(s00, a10)),
                    AdvSimd.Multiply(s01, a20)),
                    AdvSimd.Multiply(s02, b10));
                y0 = AdvSimd.Add(y0, AdvSimd.Multiply(s03, b20));

                s01 = s00;
                s00 = x;
                s03 = s02;
                s02 = y0;

                Vector64<float> y1 = AdvSimd.Add(AdvSimd.Add(AdvSimd.Add(
                    AdvSimd.Multiply(y0, a01),
                    AdvSimd.Multiply(s10, a11)),
                    AdvSimd.Multiply(s11, a21)),
                    AdvSimd.Multiply(s12, b11));
                y1 = AdvSimd.Add(y1, AdvSimd.Multiply(s13, b21));

                s11 = s10;
                s10 = y0;
                s13 = s12;
                s12 = y1;

                outputBuffer0[i] = y1.GetElement(0);
                outputBuffer1[i] = y1.GetElement(1);
            }

            states0[0].State0 = s00.GetElement(0); states1[0].State0 = s00.GetElement(1);
            states0[0].State1 = s01.GetElement(0); states1[0].State1 = s01.GetElement(1);
            states0[0].State2 = s02.GetElement(0); states1[0].State2 = s02.GetElement(1);
            states0[0].State3 = s03.GetElement(0); states1[0].State3 = s03.GetElement(1);

            states0[1].State0 = s10.GetElement(0); states1[1].State0 = s10.GetElement(1);
            states0[1].State1 = s11.GetElement(0); states1[1].State1 = s11.GetElement(1);
            states0[1].State2 = s12.GetElement(0); states1[1].State2 = s12.GetElement(1);
            states0[1].State3 = s13.GetElement(0); states1[1].State3 = s13.GetElement(1);
        }
    }
}
