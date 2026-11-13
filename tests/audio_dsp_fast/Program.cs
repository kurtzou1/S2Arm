// 音频 DSP 快路径对拍（#630 合入时补）：S2A_AUDIO_DSP_FAST 缺省开以后，下面两处快路径也必须与原路径逐位一致。
//   ① 双二阶滤波（BiquadFilterHelper.ProcessBiquadFilter 单级 / 多级）：状态放局部变量。
//      判据：与原循环的逐字拷贝（Ref*）逐位比，含输入输出同一块缓冲（原地滤波）。
//   ② 波形缓冲解码（DataSourceHelper.ProcessWaveBuffers）：32 KB 临时区 SkipLocalsInit，快路径只清会被读到的前段。
//      判据：同一组输入跑两遍，每遍之前先把栈上那片内存填成不同的垃圾值；只要读到了没清的区域，两遍输出就不一样。
//      填垃圾是否真落到那片内存由探针核（探针读不到垃圾值 = 判据失效，记红）。
// 跑两遍：缺省（快路径开）与 S2A_AUDIO_DSP_FAST=0（关，两项都应平凡相同）。
using Ryujinx.Audio.Renderer.Common;
using Ryujinx.Audio.Renderer.Dsp;
using Ryujinx.Audio.Renderer.Dsp.State;
using Ryujinx.Audio.Renderer.Parameter;
using Ryujinx.Memory;
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Ryujinx.Audio;
using Ryujinx.Audio.Common;
using static Ryujinx.Audio.Renderer.Parameter.VoiceInParameter1;

static class Program
{
    static int fails, cases;

    static void Fail(string what) { if (++fails <= 20) Console.WriteLine("RED " + what); }

    // 逐位比；只有一处放宽：两边都是 NaN 算一致、不比 NaN 的符号与载荷。
    //   JIT 可以交换加法两边（IEEE 加法可交换），两个操作数都是 NaN 且符号不同（.NET 的 float.NaN 是 0xFFC00000，ARM 运算生成的缺省 NaN 是 0x7FC00000）时，
    //   结果取哪一个就跟着变；NaN 往下送到设备输出饱和时一律变 0，载荷对声音没有影响。
    static bool Same(float a, float b) => BitConverter.SingleToInt32Bits(a) == BitConverter.SingleToInt32Bits(b) || (float.IsNaN(a) && float.IsNaN(b));

    static void CheckFloats(string what, ReadOnlySpan<float> want, ReadOnlySpan<float> got)
    {
        cases++;
        for (int i = 0; i < want.Length; i++)
            if (!Same(want[i], got[i])) { Fail($"{what} [{i}] want {want[i]:R} (0x{BitConverter.SingleToInt32Bits(want[i]):X8}) got {got[i]:R} (0x{BitConverter.SingleToInt32Bits(got[i]):X8})"); return; }
    }

    static void CheckState(string what, in BiquadFilterState w, in BiquadFilterState g)
    {
        cases++;
        if (!Same(w.State0, g.State0) || !Same(w.State1, g.State1) || !Same(w.State2, g.State2) || !Same(w.State3, g.State3))
            Fail($"{what} state want ({w.State0:R},{w.State1:R},{w.State2:R},{w.State3:R}) got ({g.State0:R},{g.State1:R},{g.State2:R},{g.State3:R})");
    }

    // ---- ① 双二阶：原循环逐字拷贝（BiquadFilterHelper 里 S2ADspFast 分支下方那段） ----
    static void RefSingle(float a0, float a1, float a2, float b1, float b2, ref BiquadFilterState state, Span<float> outputBuffer, ReadOnlySpan<float> inputBuffer, uint sampleCount)
    {
        for (int i = 0; i < sampleCount; i++)
        {
            float input = inputBuffer[i];
            float output = input * a0 + state.State0;
            state.State0 = input * a1 + output * b1 + state.State1;
            state.State1 = input * a2 + output * b2;
            outputBuffer[i] = output;
        }
    }

    static void RefMulti(ReadOnlySpan<BiquadFilterParameter2> parameters, Span<BiquadFilterState> states, Span<float> outputBuffer, ReadOnlySpan<float> inputBuffer, uint sampleCount)
    {
        for (int stageIndex = 0; stageIndex < parameters.Length; stageIndex++)
        {
            BiquadFilterParameter2 parameter = parameters[stageIndex];
            ref BiquadFilterState state = ref states[stageIndex];
            Span<float> n = parameter.Numerator.AsSpan(), d = parameter.Denominator.AsSpan();
            float a0 = n[0], a1 = n[1], a2 = n[2], b1 = d[0], b2 = d[1];
            for (int i = 0; i < sampleCount; i++)
            {
                float input = stageIndex != 0 ? outputBuffer[i] : inputBuffer[i];
                float output = input * a0 + state.State0 * a1 + state.State1 * a2 + state.State2 * b1 + state.State3 * b2;
                state.State1 = state.State0;
                state.State0 = input;
                state.State3 = state.State2;
                state.State2 = output;
                outputBuffer[i] = output;
            }
        }
    }

    static BiquadFilterParameter2 RandParam(Random r)
    {
        BiquadFilterParameter2 p = new() { Enable = true };
        Span<float> n = p.Numerator.AsSpan(), d = p.Denominator.AsSpan();
        // 稳定区附近的系数（极点模 < 1），外加少量大值以覆盖溢出 / 次正规数
        n[0] = (float)(r.NextDouble() * 2 - 1); n[1] = (float)(r.NextDouble() * 2 - 1); n[2] = (float)(r.NextDouble() * 2 - 1);
        d[0] = (float)(r.NextDouble() * 1.8 - 0.9); d[1] = (float)(r.NextDouble() * 1.6 - 0.8);
        if (r.Next(8) == 0) n[r.Next(3)] = (float)(r.NextDouble() * 1e30);
        if (r.Next(8) == 0) d[r.Next(2)] = 1e-40f;
        return p;
    }

    static BiquadFilterState RandState(Random r) => new()
    {
        State0 = (float)(r.NextDouble() * 2 - 1), State1 = (float)(r.NextDouble() * 2 - 1), State2 = (float)(r.NextDouble() * 2 - 1), State3 = (float)(r.NextDouble() * 2 - 1),
    };

    static float[] RandSamples(Random r, int n)
    {
        var a = new float[n];
        for (int i = 0; i < n; i++) a[i] = (float)(r.NextDouble() * 65536 - 32768);
        if (n > 4) { a[r.Next(n)] = float.NaN; a[r.Next(n)] = float.PositiveInfinity; a[r.Next(n)] = -0f; }
        return a;
    }

    static void TestBiquad(Random r)
    {
        foreach (int n in new[] { 0, 1, 7, 160, 240, 960 })
        {
            for (int rep = 0; rep < 40; rep++)
            {
                // 单级（ref 参数）：分开的输入输出 / 原地
                BiquadFilterParameter2 p = RandParam(r);
                Span<float> nn = p.Numerator.AsSpan(), dd = p.Denominator.AsSpan();
                foreach (bool inPlace in new[] { false, true })
                {
                    float[] input = RandSamples(r, n);
                    BiquadFilterState s0 = RandState(r);
                    BiquadFilterState sw = s0, sg = s0;
                    float[] wantOut = inPlace ? (float[])input.Clone() : new float[n];
                    float[] gotOut = inPlace ? (float[])input.Clone() : new float[n];
                    RefSingle(nn[0], nn[1], nn[2], dd[0], dd[1], ref sw, wantOut, inPlace ? wantOut : input, (uint)n);
                    BiquadFilterHelper.ProcessBiquadFilter(ref p, ref sg, gotOut, inPlace ? gotOut : input, (uint)n);
                    string tag = $"biquad single n={n} inPlace={inPlace} rep={rep}";
                    CheckFloats(tag, wantOut, gotOut);
                    CheckState(tag, sw, sg);
                }

                // 多级：1–3 级；第 1 级读输入、之后读输出；输入输出同一块 / 分开
                int stages = 1 + r.Next(3);
                var ps = new BiquadFilterParameter2[stages];
                var st0 = new BiquadFilterState[stages];
                for (int k = 0; k < stages; k++) { ps[k] = RandParam(r); st0[k] = RandState(r); }
                foreach (bool inPlace in new[] { false, true })
                {
                    float[] input = RandSamples(r, n);
                    var sw = (BiquadFilterState[])st0.Clone();
                    var sg = (BiquadFilterState[])st0.Clone();
                    float[] wantOut = inPlace ? (float[])input.Clone() : new float[n];
                    float[] gotOut = inPlace ? (float[])input.Clone() : new float[n];
                    RefMulti(ps, sw, wantOut, inPlace ? wantOut : input, (uint)n);
                    BiquadFilterHelper.ProcessBiquadFilter(ps, sg, gotOut, inPlace ? gotOut : input, (uint)n);
                    string tag = $"biquad multi stages={stages} n={n} inPlace={inPlace} rep={rep}";
                    CheckFloats(tag, wantOut, gotOut);
                    for (int k = 0; k < stages; k++) CheckState(tag + $" stage{k}", sw[k], sg[k]);
                }
            }
        }
    }

    // ---- ② 波形缓冲：栈上先填垃圾再解码，两种垃圾输出必须一样 ----
    const int TempShorts = 0x3F00;
    const int PoisonShorts = TempShorts * 2 + 8192;   // 盖住 ProcessWaveBuffers 的整个栈帧（临时区 32 KB + 局部量）

    [SkipLocalsInit, MethodImpl(MethodImplOptions.NoInlining)]
    static void Poison(short v)
    {
        Span<short> s = stackalloc short[PoisonShorts];
        s.Fill(v);
        GC.KeepAlive(s[PoisonShorts - 1]);
    }

    // 探针：与 ProcessWaveBuffers 同样从调用方往下开 32 KB、不清零，读到的应是刚填的垃圾值
    [SkipLocalsInit, MethodImpl(MethodImplOptions.NoInlining)]
    static int ProbeHits(short v)
    {
        Span<short> t = stackalloc short[TempShorts];
        int hits = 0;
        for (int i = 0; i < TempShorts; i++) if (t[i] == v) hits++;
        return hits;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static int Probe(short v) { Poison(v); return ProbeHits(v); }

    struct Run { public float[] Out; public VoiceState Vs; }

    const ulong Va = 0x10000;
    static AddressSpaceManager mm;
    static MemoryBlock block;

    [MethodImpl(MethodImplOptions.NoInlining)]
    static Run Decode(short poison, DataSourceHelper.WaveBufferInformation info, VoiceState vs0, WaveBuffer[] wb0, int sampleCount, int calls)
    {
        VoiceState vs = vs0;
        var wb = (WaveBuffer[])wb0.Clone();
        var outAll = new float[sampleCount * calls];
        for (int c = 0; c < calls; c++)
        {
            Span<float> o = outAll.AsSpan(c * sampleCount, sampleCount);
            Poison(poison);
            DataSourceHelper.ProcessWaveBuffers(mm, o, ref info, wb, ref vs, 48000, sampleCount);
        }
        return new Run { Out = outAll, Vs = vs };
    }

    static void CheckVoice(string what, in VoiceState a, in VoiceState b)
    {
        cases++;
        VoiceState x = a, y = b;
        bool same = BitConverter.SingleToInt32Bits(x.Fraction) == BitConverter.SingleToInt32Bits(y.Fraction) && x.Offset == y.Offset
            && x.WaveBufferIndex == y.WaveBufferIndex && x.PlayedSampleCount == y.PlayedSampleCount && x.WaveBufferConsumed == y.WaveBufferConsumed
            && x.Pitch.AsSpan().SequenceEqual(y.Pitch.AsSpan()) && x.IsWaveBufferValid.SequenceEqual(y.IsWaveBufferValid);
        if (!same) Fail($"{what} voice state differs (fraction {x.Fraction:R}/{y.Fraction:R}, offset {x.Offset}/{y.Offset}, pitch {string.Join(',', x.Pitch.AsSpan().ToArray())} / {string.Join(',', y.Pitch.AsSpan().ToArray())})");
    }

    static void TestDataSource(Random r)
    {
        const ulong Size = 4 << 20;
        block = new MemoryBlock(Size);
        mm = new AddressSpaceManager(block, 1UL << 24);
        mm.Map(Va, 0, Size, MemoryMapFlags.None);
        var fill = new byte[Size];
        r.NextBytes(fill);
        block.Write(0, fill);
        // ADPCM 系数表（8 组 × 2 + 余量），放在缓冲区末尾
        ulong coefVa = Va + Size - 4096;
        var coef = new short[32];
        for (int i = 0; i < coef.Length; i++) coef[i] = (short)r.Next(-4096, 4096);
        block.Write(Size - 4096, MemoryMarshal.AsBytes<short>(coef));

        int combos = 0, hits = 0;
        for (int pass = 0; pass < 2; pass++)   // 第 0 遍只预热（JIT 先把各条分支编好），第 1 遍才判
        {
        if (pass == 1)
        {
            // 判据自检：填的垃圾确实落在解码临时区会用的那片栈上
            Probe(0x5A5A);
            hits = Probe(0x5A5A);
            cases++;
            if (hits < TempShorts * 9 / 10) Fail($"poison probe: only {hits}/{TempShorts} stack slots carry the poison value — the garbage-sensitivity criterion is not effective");
        }
        var rp = new Random(6300);   // 两遍同一组配置
        foreach (SampleFormat fmt in new[] { SampleFormat.PcmInt16, SampleFormat.PcmFloat, SampleFormat.Adpcm })
        foreach (SampleRateConversionQuality q in new[] { SampleRateConversionQuality.Default, SampleRateConversionQuality.High, SampleRateConversionQuality.Low })
        foreach (uint rate in new uint[] { 8000, 22050, 32000, 44100, 48000, 96000 })
        foreach (float pitch in new[] { 0.5f, 1f, 1.37f, 2f })
        foreach (int sampleCount in new[] { 160, 240 })
        foreach (int scenario in new[] { 0, 1, 2 })   // 0 = 两个够长的缓冲；1 = 短缓冲接着饿（starving）；2 = 跳过变调与重采样（同采样率）
        {
            if (scenario == 2 && (rate != 48000 || pitch != 1f)) continue;
            int channels = fmt == SampleFormat.Adpcm ? 1 : 1 + rp.Next(2);
            var info = new DataSourceHelper.WaveBufferInformation
            {
                SourceSampleRate = rate, Pitch = pitch, ChannelCount = channels, ChannelIndex = rp.Next(channels), SrcQuality = q, SampleFormat = fmt,
                DecodingBehaviour = scenario == 2 ? DecodingBehaviour.SkipPitchAndSampleRateConversion : DecodingBehaviour.Default,
                ExtraParameter = fmt == SampleFormat.Adpcm ? coefVa : 0, ExtraParameterSize = fmt == SampleFormat.Adpcm ? 64UL : 0,
            };
            var wb = new WaveBuffer[Constants.VoiceWaveBufferCount];
            VoiceState vs = default;
            int nBuf = scenario == 1 ? 1 : 2;
            for (int k = 0; k < nBuf; k++)
            {
                int samples = scenario == 1 ? 50 + rp.Next(100) : 2000 + rp.Next(2000);
                int bytes = fmt switch
                {
                    SampleFormat.PcmInt16 => samples * channels * 2,
                    SampleFormat.PcmFloat => samples * channels * 4,
                    _ => (samples + 13) / 14 * 8,
                };
                ulong off = (ulong)rp.Next(0, (int)(Size / 2)) & ~3UL;
                wb[k] = new WaveBuffer { Buffer = Va + off, BufferSize = (uint)bytes, StartSampleOffset = 0, EndSampleOffset = (uint)samples };
                vs.IsWaveBufferValid[k] = true;
            }
            for (int k = 0; k < 8; k++) vs.Pitch[k] = (short)rp.Next(-32768, 32767);
            vs.Fraction = (float)rp.NextDouble();

            Run a = Decode(0x1234, info, vs, wb, sampleCount, 4);
            Run b = Decode(unchecked((short)0xA5A5), info, vs, wb, sampleCount, 4);
            string tag = $"datasource {fmt} {q} {rate}Hz pitch={pitch} n={sampleCount} scenario={scenario}";
            if (pass == 0) continue;
            CheckFloats(tag, a.Out, b.Out);
            CheckVoice(tag, a.Vs, b.Vs);
            combos++;
        }
        }
        Console.WriteLine($"datasource: {combos} voice configurations × 4 calls, poison probe {hits}/{TempShorts}");
    }

    static int Main()
    {
        bool fast = Environment.GetEnvironmentVariable("S2A_AUDIO_DSP_FAST") != "0";
        var r = new Random(630);
        TestBiquad(r);
        TestDataSource(r);
        Console.WriteLine(fails == 0 ? $"audio_dsp_fast: all green ({cases} comparisons, fast={fast})" : $"audio_dsp_fast: {fails} red of {cases} (fast={fast})");
        return fails == 0 ? 0 : 1;
    }
}
