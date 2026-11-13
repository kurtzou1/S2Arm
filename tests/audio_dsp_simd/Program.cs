// Audio DSP kernels (compat/tree/src/Ryujinx.Audio/Renderer/Dsp): the S2Arm AdvSimd fast paths (S2A_AUDIO_DSP_FAST,
// default on) must be bit-identical to the upstream scalar loops for every kernel they gate:
//   resample default quality (4 taps) and high quality (8 taps), 5.1 -> stereo downmix, mix ramp, volume ramp,
//   and the device-sink float -> int16 saturate + stereo interleave.
// Expected values come from the scalar reference transcribed here from the upstream loops (independent of the
// kernels under test) and, for the mix kernels, also from the tree's own scalar path (S2ADspMixHelper.*Scalar).
// Adversarial inputs: rounding midpoints everywhere (Math.Round default = round-half-to-even: x.5 must round to
// even, not away from zero), 0, +-short.MaxValue/MinValue, NaN and +-Inf (saturate must give 0 / +-32767/-32768),
// ratios on all three LUT boundaries (1.0, 1.333313) and random, fractions spanning the 128 phase slots, sample
// counts with scalar tails (n % 4 == 1..3 for 4-lane kernels, n % 8 == 1..7 for the interleave), ramps 0 / negative
// / tiny / huge, volume 0.
// The wiring check compares the public dispatchers (ResamplerHelper.Resample, S2ADspMixHelper.*) against the direct
// kernel calls; it runs green under the default env (fast path on) and under S2A_AUDIO_DSP_FAST=0 (the test script
// runs the binary twice). On non-ARM64 there is no AdvSimd: prints off and returns 0.
using System;
using System.Diagnostics;
using System.Runtime.Intrinsics.Arm;
using Ryujinx.Audio.Renderer.Dsp;
using Ryujinx.Audio.Renderer.Parameter;

static class P
{
    static int fails, cases;

    static void Fail(string what, long i, string want, string got)
    {
        if (fails++ < 10) Console.WriteLine($"FAIL {what} at {i}: want {want}, got {got}");
    }

    static void CheckFloats(string what, ReadOnlySpan<float> want, ReadOnlySpan<float> got)
    {
        cases++;
        for (int i = 0; i < want.Length; i++)
        {
            if (BitConverter.SingleToInt32Bits(want[i]) != BitConverter.SingleToInt32Bits(got[i]))
            {
                Fail(what, i, $"{want[i]:R} (0x{BitConverter.SingleToInt32Bits(want[i]):X8})", $"{got[i]:R} (0x{BitConverter.SingleToInt32Bits(got[i]):X8})");
                return;
            }
        }
    }

    static void CheckShorts(string what, ReadOnlySpan<short> want, ReadOnlySpan<short> got)
    {
        cases++;
        for (int i = 0; i < want.Length; i++)
        {
            if ((ushort)want[i] != (ushort)got[i])
            {
                Fail(what, i, $"{want[i]} (0x{(ushort)want[i]:X4})", $"{got[i]} (0x{(ushort)got[i]:X4})");
                return;
            }
        }
    }

    static void CheckFloat(string what, float want, float got)
    {
        cases++;
        if (BitConverter.SingleToInt32Bits(want) != BitConverter.SingleToInt32Bits(got))
        {
            Fail(what, 0, $"{want:R} (0x{BitConverter.SingleToInt32Bits(want):X8})", $"{got:R} (0x{BitConverter.SingleToInt32Bits(got):X8})");
        }
    }

    // ---- upstream scalar loops, transcribed (do not call the kernels under test) -------------------

    static void RefResampleDefault(ReadOnlySpan<short> input, ReadOnlySpan<float> par, float ratio, float fraction, int sampleCount, Span<float> output, out float outFraction)
    {
        int inputBufferIndex = 0;

        for (int i = 0; i < sampleCount; i++)
        {
            int baseIndex = (int)(fraction * 128) * 4;
            ReadOnlySpan<float> parameter = par.Slice(baseIndex, 4);
            ReadOnlySpan<short> currentInput = input.Slice(inputBufferIndex, 4);

            output[i] = (float)Math.Round(currentInput[0] * parameter[0] +
                                          currentInput[1] * parameter[1] +
                                          currentInput[2] * parameter[2] +
                                          currentInput[3] * parameter[3]);

            fraction += ratio;
            inputBufferIndex += (int)fraction;

            // Only keep lower part (safe as fraction isn't supposed to be negative)
            fraction -= (int)fraction;
        }

        outFraction = fraction;
    }

    static void RefResampleHigh(ReadOnlySpan<short> input, ReadOnlySpan<float> par, float ratio, float fraction, int sampleCount, Span<float> output, out float outFraction)
    {
        int inputBufferIndex = 0;

        for (int i = 0; i < sampleCount; i++)
        {
            int baseIndex = (int)(fraction * 128) * 8;
            ReadOnlySpan<float> parameter = par.Slice(baseIndex, 8);
            ReadOnlySpan<short> currentInput = input.Slice(inputBufferIndex, 8);

            output[i] = (float)Math.Round(currentInput[0] * parameter[0] +
                                          currentInput[1] * parameter[1] +
                                          currentInput[2] * parameter[2] +
                                          currentInput[3] * parameter[3] +
                                          currentInput[4] * parameter[4] +
                                          currentInput[5] * parameter[5] +
                                          currentInput[6] * parameter[6] +
                                          currentInput[7] * parameter[7]);

            fraction += ratio;
            inputBufferIndex += (int)MathF.Truncate(fraction);

            fraction -= (int)fraction;
        }

        outFraction = fraction;
    }

    static void RefDownMix(Span<float> stereoLeft, Span<float> stereoRight, ReadOnlySpan<float> frontLeft, ReadOnlySpan<float> frontRight, ReadOnlySpan<float> frontCenter, ReadOnlySpan<float> lowFrequency, ReadOnlySpan<float> backLeft, ReadOnlySpan<float> backRight, ReadOnlySpan<float> c, int sampleCount)
    {
        for (int i = 0; i < sampleCount; i++)
        {
            stereoLeft[i] = MathF.Round(c[3] * backLeft[i] + c[2] * lowFrequency[i] + c[1] * frontCenter[i] + c[0] * frontLeft[i]);
            stereoRight[i] = MathF.Round(c[3] * backRight[i] + c[2] * lowFrequency[i] + c[1] * frontCenter[i] + c[0] * frontRight[i]);
        }
    }

    static float RefMixRamp(Span<float> outputBuffer, ReadOnlySpan<float> inputBuffer, float volume, float ramp, int sampleCount)
    {
        float state = 0;

        for (int i = 0; i < sampleCount; i++)
        {
            state = MathF.Round(inputBuffer[i] * volume);

            outputBuffer[i] += state;
            volume += ramp;
        }

        return state;
    }

    static void RefVolumeRamp(Span<float> outputBuffer, ReadOnlySpan<float> inputBuffer, float volume, float ramp, int sampleCount)
    {
        for (int i = 0; i < sampleCount; i++)
        {
            outputBuffer[i] = MathF.Round(inputBuffer[i] * volume);
            volume += ramp;
        }
    }

    static short RefSaturate(float value)
    {
        if (value > short.MaxValue)
        {
            return short.MaxValue;
        }

        if (value < short.MinValue)
        {
            return short.MinValue;
        }

        return (short)value;
    }

    static void RefSaturateInterleave(Span<short> outputBuffer, ReadOnlySpan<float> left, ReadOnlySpan<float> right, int sampleCount)
    {
        for (int j = 0; j < sampleCount; j++)
        {
            outputBuffer[j * 2] = RefSaturate(left[j]);
            outputBuffer[j * 2 + 1] = RefSaturate(right[j]);
        }
    }

    // ---- helpers ------------------------------------------------------------------------------------

    static short[] FillShorts(Random rnd, int length, int pattern)
    {
        short[] input = new short[length];

        switch (pattern)
        {
            case 1:
                for (int i = 0; i < length; i++) input[i] = (short)rnd.Next(short.MinValue, short.MaxValue);
                break;
            case 2:
                Array.Fill(input, short.MaxValue);
                break;
            case 3:
                Array.Fill(input, short.MinValue);
                break;
            case 4:
                for (int i = 0; i < length; i++) input[i] = (i & 1) == 0 ? short.MaxValue : short.MinValue;
                break;
            default:
                Array.Fill(input, (short)0);
                break;
        }

        return input;
    }

    static float[] Midpoints(int length, int offset)
    {
        // x.x5 values: with volume / coefficient 1.0 every product lands on a rounding midpoint
        float[] a = new float[length];
        for (int i = 0; i < length; i++) a[i] = (i + offset) - 10.5f;
        return a;
    }

    // ---- kernel tests --------------------------------------------------------------------------------

    static void TestResample(Random rnd, bool high)
    {
        string what = high ? "resample high" : "resample default";
        int[] counts = [1, 2, 3, 4, 5, 7, 8, 9, 12, 15, 31, 239, 240, 241, 242, 243, 247];
        float[] ratios = [0.5f, 0.75f, 0.9f, 1.0f, 1.1f, 1.333313f, 1.333314f, 1.5f, 2.0f, 3.7f];

        foreach (float ratio in ratios)
        {
            ReadOnlySpan<float> par = high ? ResamplerHelper.GetHighParameter(ratio) : ResamplerHelper.GetDefaultParameter(ratio);

            foreach (int n in counts)
            {
                for (int pattern = 0; pattern < 5; pattern++)
                {
                    short[] input = FillShorts(rnd, ((int)ratio + 2) * n + 32, pattern);
                    float[] want = new float[n], got = new float[n];
                    float fraction = rnd.NextSingle();

                    float fracOut;
                    if (high)
                    {
                        RefResampleHigh(input, par, ratio, fraction, n, want, out fracOut);
                    }
                    else
                    {
                        RefResampleDefault(input, par, ratio, fraction, n, want, out fracOut);
                    }

                    float fracVec = fraction;
                    if (high)
                    {
                        ResamplerHelper.ResampleHighQualityAdvSimd(got, input, ratio, ref fracVec, n, par);
                    }
                    else
                    {
                        ResamplerHelper.ResampleDefaultQualityAdvSimd(got, input, ratio, ref fracVec, n, par);
                    }

                    CheckFloats($"{what} n={n} ratio={ratio} pattern={pattern} vs ref", want, got);
                    CheckFloat($"{what} n={n} ratio={ratio} pattern={pattern} fraction", fracOut, fracVec);
                }
            }
        }

        for (int round = 0; round < 400; round++)
        {
            float ratio = MathF.Round(0.25f + rnd.NextSingle() * 3.75f, 3);
            ReadOnlySpan<float> par = high ? ResamplerHelper.GetHighParameter(ratio) : ResamplerHelper.GetDefaultParameter(ratio);
            int n = rnd.Next(1, 248);
            short[] input = FillShorts(rnd, ((int)ratio + 2) * n + 32, 1);
            float[] want = new float[n], got = new float[n];
            float fraction = round == 0 ? 0f : rnd.NextSingle();

            float fracOut;
            if (high)
            {
                RefResampleHigh(input, par, ratio, fraction, n, want, out fracOut);
            }
            else
            {
                RefResampleDefault(input, par, ratio, fraction, n, want, out fracOut);
            }

            float fracVec = fraction;
            if (high)
            {
                ResamplerHelper.ResampleHighQualityAdvSimd(got, input, ratio, ref fracVec, n, par);
            }
            else
            {
                ResamplerHelper.ResampleDefaultQualityAdvSimd(got, input, ratio, ref fracVec, n, par);
            }

            CheckFloats($"{what} n={n} ratio={ratio} random", want, got);
            CheckFloat($"{what} n={n} ratio={ratio} fraction random", fracOut, fracVec);
        }
    }

    static void TestDownMix(Random rnd)
    {
        float[][] coeffSets =
        [
            [1.0f, 1.0f, 1.0f, 1.0f],
            [0.70710677f, 0.70710677f, 0.70710677f, 0.70710677f],
            [1.0f, 0.5f, 0.25f, 0.75f],
            [0.0f, 0.0f, 0.0f, 0.0f],
            [-1.0f, 2.0f, -0.5f, 1.5f],
        ];
        int[] counts = [0, 1, 2, 3, 4, 5, 7, 239, 240, 241, 242, 243, 247];

        for (int round = 0; round < 260; round++)
        {
            int n = counts[round % counts.Length];
            float[] c = coeffSets[round % coeffSets.Length];
            if (round % 3 == 2)
            {
                c = [rnd.NextSingle() * 3f - 1.5f, rnd.NextSingle() * 3f - 1.5f, rnd.NextSingle() * 3f - 1.5f, rnd.NextSingle() * 3f - 1.5f];
            }

            float[][] ch = new float[6][];
            for (int k = 0; k < 6; k++)
            {
                ch[k] = new float[n];
            }

            if (round % 4 == 1)
            {
                // midpoints: coefficient 1.0 set turns every sample into a x.5 rounding case
                for (int k = 0; k < 6; k++) ch[k] = Midpoints(n, k);
            }
            else if (round % 4 == 2)
            {
                for (int k = 0; k < 6; k++)
                    for (int i = 0; i < n; i++)
                        ch[k][i] = (i & 1) == 0 ? 3e38f : -3e38f;
            }
            else if (round % 4 == 3)
            {
                for (int k = 0; k < 6; k++) Array.Fill(ch[k], 0f);
            }
            else
            {
                for (int k = 0; k < 6; k++)
                    for (int i = 0; i < n; i++)
                        ch[k][i] = rnd.NextSingle() * 4f - 2f;
            }

            float[] wantL = new float[n], wantR = new float[n];
            RefDownMix(wantL, wantR, ch[0], ch[1], ch[2], ch[3], ch[4], ch[5], c, n);

            float[] gotL = new float[n], gotR = new float[n];
            S2ADspMixHelper.DownMixSurroundToStereoAdvSimd(gotL, gotR, ch[0], ch[1], ch[2], ch[3], ch[4], ch[5], c, n);
            CheckFloats($"downmix n={n} left vs ref", wantL, gotL);
            CheckFloats($"downmix n={n} right vs ref", wantR, gotR);

            float[] slowL = new float[n], slowR = new float[n];
            S2ADspMixHelper.DownMixSurroundToStereoScalar(slowL, slowR, ch[0], ch[1], ch[2], ch[3], ch[4], ch[5], c, 0, n);
            CheckFloats($"downmix n={n} left vs scalar", slowL, gotL);
            CheckFloats($"downmix n={n} right vs scalar", slowR, gotR);
        }
    }

    static void TestRamp(Random rnd)
    {
        (float Volume, float Ramp)[] ramps =
        [
            (1.0f, 0.0f),
            (0.5f, 0.5f),
            (0.0f, 0.1f),
            (-2.5f, 0.25f),
            (0.9f, -0.0133333337f),
            (0.75f, 1e-07f),
            (100.5f, -0.25f),
            (1.0f, float.MinValue),
        ];
        int[] counts = [0, 1, 2, 3, 4, 5, 7, 239, 240, 241, 242, 243, 247];

        for (int round = 0; round < 240; round++)
        {
            int n = counts[round % counts.Length];
            (float volume, float ramp) = ramps[(round / counts.Length) % ramps.Length];

            float[] input = new float[n];
            float[] output = new float[n];

            switch (round % 5)
            {
                case 1:
                    input = Midpoints(n, 0);
                    break;
                case 2:
                    Array.Fill(input, 0f);
                    break;
                case 3:
                    for (int i = 0; i < n; i++) input[i] = (i & 1) == 0 ? 3e38f : -3e38f;
                    break;
                default:
                    for (int i = 0; i < n; i++) input[i] = rnd.NextSingle() * 4f - 2f;
                    break;
            }

            for (int i = 0; i < n; i++) output[i] = rnd.NextSingle() * 2f - 1f; // accumulation: pre-fill, not zero

            float[] mixWant = (float[])output.Clone();
            float mixWantState = RefMixRamp(mixWant, input, volume, ramp, n);

            float[] mixGot = (float[])output.Clone();
            float mixGotState = S2ADspMixHelper.MixRampAdvSimd(mixGot, input, volume, ramp, n);
            CheckFloats($"mixramp n={n} v={volume:R} r={ramp:R} vs ref", mixWant, mixGot);
            CheckFloat($"mixramp n={n} v={volume:R} r={ramp:R} state vs ref", mixWantState, mixGotState);

            float[] mixSlow = (float[])output.Clone();
            float mixSlowState = S2ADspMixHelper.MixRampScalar(mixSlow, input, volume, ramp, 0, n);
            CheckFloats($"mixramp n={n} v={volume:R} r={ramp:R} vs scalar", mixSlow, mixGot);
            CheckFloat($"mixramp n={n} v={volume:R} r={ramp:R} state vs scalar", mixSlowState, mixGotState);

            float[] volWant = new float[n];
            RefVolumeRamp(volWant, input, volume, ramp, n);

            float[] volGot = new float[n];
            S2ADspMixHelper.VolumeRampAdvSimd(volGot, input, volume, ramp, n);
            CheckFloats($"volumeramp n={n} v={volume:R} r={ramp:R} vs ref", volWant, volGot);

            float[] volSlow = new float[n];
            S2ADspMixHelper.VolumeRampScalar(volSlow, input, volume, ramp, 0, n);
            CheckFloats($"volumeramp n={n} v={volume:R} r={ramp:R} vs scalar", volSlow, volGot);
        }
    }

    static void TestSaturateInterleave(Random rnd)
    {
        float[] specials =
        [
            0f, float.Epsilon, -float.Epsilon, 0.5f, 1.5f, 2.5f, 3.5f, -0.5f, -1.5f, -2.5f, -3.5f,
            2.4999f, 32766.5f, 32766.9f, 32767f, 32767.4f, 32767.5f, 32767.9f, 32768f, 40000.9f, 3e38f, float.MaxValue,
            -32767.5f, -32768f, -32768.5f, -40000.9f, -3e38f, float.MinValue, -0.4f,
            float.NaN, float.PositiveInfinity, float.NegativeInfinity,
        ];
        int[] counts = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 240, 241, 242, 243, 244, 245, 246, 247];

        for (int round = 0; round < 160; round++)
        {
            int n = counts[round % counts.Length];

            float[] left = new float[n], right = new float[n];
            if (round % 3 == 0)
            {
                for (int j = 0; j < n; j++)
                {
                    left[j] = specials[(j * 7 + round) % specials.Length];
                    right[j] = specials[(j * 5 + round * 3) % specials.Length];
                }
            }
            else if (round % 3 == 1)
            {
                for (int j = 0; j < n; j++)
                {
                    left[j] = rnd.Next(-33000, 33000);
                    right[j] = rnd.Next(-33000, 33000);
                }
            }
            else
            {
                for (int j = 0; j < n; j++)
                {
                    left[j] = rnd.NextSingle() * 80000f - 40000f;
                    right[j] = rnd.NextSingle() * 80000f - 40000f;
                }
            }

            short[] want = new short[n * 2];
            RefSaturateInterleave(want, left, right, n);

            short[] got = new short[n * 2];
            S2ADspMixHelper.SaturateInterleaveStereoAdvSimd(got, left, right, n);
            CheckShorts($"saturate-interleave n={n} round={round}", want, got);

            short[] slow = new short[n * 2];
            S2ADspMixHelper.SaturateInterleaveStereoScalar(slow, left, right, 0, n);
            CheckShorts($"saturate-interleave n={n} round={round} vs scalar", want, slow);
        }
    }

    static void TestWiring(Random rnd)
    {
        string mode = S2ADspFast.On ? "fast" : "slow";

        // Resample dispatchers (both qualities) against the direct kernel / transcribed reference
        foreach (float ratio in new float[] { 0.9f, 1.0f, 1.4f })
        {
            foreach (int n in new int[] { 239, 240, 241 })
            {
                foreach (bool high in new bool[] { false, true })
                {
                    ReadOnlySpan<float> par = high ? ResamplerHelper.GetHighParameter(ratio) : ResamplerHelper.GetDefaultParameter(ratio);
                    short[] srcInput = FillShorts(rnd, ((int)ratio + 2) * n + 32, 1);

                    float startFraction = rnd.NextSingle();

                    float[] disp = new float[n];
                    float dispFraction = startFraction;
                    ResamplerHelper.Resample(
                        disp, srcInput, ratio, ref dispFraction, n,
                        high ? SampleRateConversionQuality.High : SampleRateConversionQuality.Default,
                        needPitch: false);

                    float[] want = new float[n];
                    float wantFraction = startFraction;
                    if (S2ADspFast.On)
                    {
                        if (high)
                        {
                            ResamplerHelper.ResampleHighQualityAdvSimd(want, srcInput, ratio, ref wantFraction, n, par);
                        }
                        else
                        {
                            ResamplerHelper.ResampleDefaultQualityAdvSimd(want, srcInput, ratio, ref wantFraction, n, par);
                        }
                    }
                    else
                    {
                        if (high)
                        {
                            RefResampleHigh(srcInput, par, ratio, startFraction, n, want, out wantFraction);
                        }
                        else
                        {
                            RefResampleDefault(srcInput, par, ratio, startFraction, n, want, out wantFraction);
                        }
                    }

                    CheckFloats($"wiring resample {mode} n={n} ratio={ratio} high={high}", want, disp);
                    CheckFloat($"wiring resample {mode} n={n} ratio={ratio} high={high} fraction", wantFraction, dispFraction);
                }
            }
        }

        // Mix kernel dispatchers
        const int n2 = 241;
        float[] input = new float[n2], prefill = new float[n2];
        for (int i = 0; i < n2; i++)
        {
            input[i] = rnd.NextSingle() * 4f - 2f;
            prefill[i] = rnd.NextSingle() * 2f - 1f;
        }

        float[] dispMix = (float[])prefill.Clone();
        float dispState = S2ADspMixHelper.MixRamp(dispMix, input, 0.25f, 0.001f, n2);

        float[] wantMix = (float[])prefill.Clone();
        float wantState = S2ADspFast.On ? S2ADspMixHelper.MixRampAdvSimd(wantMix, input, 0.25f, 0.001f, n2) : S2ADspMixHelper.MixRampScalar(wantMix, input, 0.25f, 0.001f, 0, n2);
        CheckFloats($"wiring mixramp {mode}", wantMix, dispMix);
        CheckFloat($"wiring mixramp state {mode}", wantState, dispState);

        float[] dispVol = new float[n2];
        S2ADspMixHelper.VolumeRamp(dispVol, input, 0.75f, -0.001f, n2);
        float[] wantVol = new float[n2];
        if (S2ADspFast.On) S2ADspMixHelper.VolumeRampAdvSimd(wantVol, input, 0.75f, -0.001f, n2);
        else S2ADspMixHelper.VolumeRampScalar(wantVol, input, 0.75f, -0.001f, 0, n2);
        CheckFloats($"wiring volumeramp {mode}", wantVol, dispVol);

        float[] downIn = new float[n2];
        for (int i = 0; i < n2; i++) downIn[i] = rnd.NextSingle() - 0.5f;
        float[] dispL = new float[n2], dispR = new float[n2];
        float[] stereoL = new float[n2], stereoR = new float[n2];
        float[] coeffs = [0.70710677f, 0.5f, 0.25f, 0.70710677f];
        ReadOnlySpan<float> coefficients = coeffs;
        S2ADspMixHelper.DownMixSurroundToStereo(dispL, dispR, downIn, downIn, downIn, downIn, downIn, downIn, coefficients, n2);
        if (S2ADspFast.On) S2ADspMixHelper.DownMixSurroundToStereoAdvSimd(stereoL, stereoR, downIn, downIn, downIn, downIn, downIn, downIn, coefficients, n2);
        else S2ADspMixHelper.DownMixSurroundToStereoScalar(stereoL, stereoR, downIn, downIn, downIn, downIn, downIn, downIn, coefficients, 0, n2);
        CheckFloats($"wiring downmix {mode} left", stereoL, dispL);
        CheckFloats($"wiring downmix {mode} right", stereoR, dispR);

        short[] dispOut = new short[n2 * 2];
        S2ADspMixHelper.SaturateInterleaveStereo(dispOut, downIn, input, n2);
        short[] wantOut = new short[n2 * 2];
        if (S2ADspFast.On) S2ADspMixHelper.SaturateInterleaveStereoAdvSimd(wantOut, downIn, input, n2);
        else S2ADspMixHelper.SaturateInterleaveStereoScalar(wantOut, downIn, input, 0, n2);
        CheckShorts($"wiring saturate-interleave {mode}", wantOut, dispOut);
    }

    // ---- optional kernel timing (not part of the green/red verdict) --------------------------------

    static float _benchFraction; // lambda 传 ref 需要字段

    static long TimeIterations(Action action, int iterations)
    {
        var sw = Stopwatch.StartNew();
        for (int i = 0; i < iterations; i++) action();
        return sw.ElapsedTicks * 1000 / iterations;
    }

    static void Bench()
    {
        const int N = 240; // TargetSampleCount per 5 ms render cycle
        var rnd = new Random(20261111);

        float ratio = 1.3777778f; // 48000 -> 384000/277.71-ish upscale shape, exercises the fast path
        float[] parD = ResamplerHelper.GetDefaultParameter(ratio).ToArray();
        float[] parH = ResamplerHelper.GetHighParameter(ratio).ToArray();
        short[] input = FillShorts(rnd, ((int)ratio + 2) * N + 64, 1);
        float[] outA = new float[N], outB = new float[N];
        float[] chA = new float[N], chB = new float[N], chC = new float[N];
        for (int i = 0; i < N; i++)
        {
            chA[i] = rnd.NextSingle() - 0.5f;
            chB[i] = rnd.NextSingle() - 0.5f;
            chC[i] = rnd.NextSingle() - 0.5f;
        }

        float[] coefficients = [0.70710677f, 0.70710677f, 0.70710677f, 0.70710677f];
        short[] shorts = new short[N * 2];

        Console.WriteLine($"bench (JIT, N={N}): ns/call median of 7 x 5000");

        void Row(string name, Action fast, Action slow)
        {
            fast(); slow();
            long[] a = new long[7], b = new long[7];
            for (int i = 0; i < 7; i++)
            {
                a[i] = TimeIterations(fast, 5000);
                b[i] = TimeIterations(slow, 5000);
            }

            Array.Sort(a); Array.Sort(b);
            Console.WriteLine($"  {name}: vector {a[3]} ns vs scalar {b[3]} ns -> {b[3] / (double)a[3]:F2}x");
        }

        Row("resample default (4 tap)", () => { _benchFraction = 0.5f; ResamplerHelper.ResampleDefaultQualityAdvSimd(outA, input, ratio, ref _benchFraction, N, parD); },
            () => RefResampleDefault(input, parD, ratio, 0.5f, N, outB, out _));
        Row("resample high (8 tap)", () => { _benchFraction = 0.5f; ResamplerHelper.ResampleHighQualityAdvSimd(outA, input, ratio, ref _benchFraction, N, parH); },
            () => RefResampleHigh(input, parH, ratio, 0.5f, N, outB, out _));
        Row("downmix 5.1->stereo", () => S2ADspMixHelper.DownMixSurroundToStereoAdvSimd(outA, outB, chA, chB, chC, chC, chA, chB, coefficients, N),
            () => S2ADspMixHelper.DownMixSurroundToStereoScalar(outA, outB, chA, chB, chC, chC, chA, chB, coefficients, 0, N));
        Row("mix ramp", () => S2ADspMixHelper.MixRampAdvSimd(outA, chA, 0.25f, 0.001f, N),
            () => S2ADspMixHelper.MixRampScalar(outA, chA, 0.25f, 0.001f, 0, N));
        Row("volume ramp", () => S2ADspMixHelper.VolumeRampAdvSimd(outA, chA, 0.75f, -0.001f, N),
            () => S2ADspMixHelper.VolumeRampScalar(outA, chA, 0.75f, -0.001f, 0, N));
        Row("device sink saturate+interleave", () => S2ADspMixHelper.SaturateInterleaveStereoAdvSimd(shorts, chA, chB, N),
            () => S2ADspMixHelper.SaturateInterleaveStereoScalar(shorts, chA, chB, 0, N));
    }

    static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--bench")
        {
            Bench();
            return 0;
        }

        Console.WriteLine($"vector path: {(AdvSimd.IsSupported ? "on" : "off (no AdvSimd: nothing to compare)")}");
        if (!AdvSimd.IsSupported) return 0;

        var rnd = new Random(20261111);

        TestResample(rnd, high: false);
        TestResample(rnd, high: true);
        TestDownMix(rnd);
        TestRamp(rnd);
        TestSaturateInterleave(rnd);
        TestWiring(rnd);

        Console.WriteLine(fails == 0 ? $"audio_dsp_simd: all green ({cases} comparisons, S2ADspFast.On={S2ADspFast.On})" : $"audio_dsp_simd: {fails} red of {cases} (S2ADspFast.On={S2ADspFast.On})");
        return fails == 0 ? 0 : 1;
    }
}
