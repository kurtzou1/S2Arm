using Ryujinx.Audio.Backends.Apple;
using Ryujinx.Audio.Backends.CompatLayer;
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // Pre-boot solo test: the 5.1 -> 2.0 modes are pure CPU work (AudioConverter / AUSM), no device session is opened.
        [SoloTest("--apple-audio-output-modes")]
        internal static int AppleAudioOutputModes()
        {
            int failures = 0;

            void Check(string name, bool ok, string detail = "")
            {
                Console.WriteLine($"{(ok ? "通过" : "【红】")} {name}{(detail.Length > 0 ? "：" + detail : "")}");

                if (!ok)
                {
                    failures++;
                }
            }

            string oldMode = Environment.GetEnvironmentVariable("S2A_AUDIO_OUT");

            try
            {
                AppleOutputMode Select(string value)
                {
                    Environment.SetEnvironmentVariable("S2A_AUDIO_OUT", value);

                    return AppleOutputModeSelector.FromEnvironment();
                }

                Environment.SetEnvironmentVariable("S2A_AUDIO_OUT", null);
                Check("缺省档 = native（上游现状）", AppleOutputModeSelector.FromEnvironment() == AppleOutputMode.Native);
                Check("matrix", Select("matrix") == AppleOutputMode.Matrix);
                Check("sys", Select("sys") == AppleOutputMode.System);
                Check("system 别名", Select("System") == AppleOutputMode.System);
                Check("spatial", Select("spatial") == AppleOutputMode.Spatial);
                Check("native", Select("native") == AppleOutputMode.Native);
                Check("不认识的档回落 native", Select("bogus") == AppleOutputMode.Native);
            }
            finally
            {
                Environment.SetEnvironmentVariable("S2A_AUDIO_OUT", oldMode);
            }

            const int rate = 48000;
            const int frames = 4800;
            const int skip = 480;
            const float amplitude = 16000.0f;
            double inputRms = amplitude / Math.Sqrt(2.0);

            byte[] Tone(int channel)
            {
                byte[] data = new byte[frames * 6 * sizeof(short)];
                Span<short> samples = MemoryMarshal.Cast<byte, short>(data.AsSpan());

                for (int frame = 0; frame < frames; frame++)
                {
                    samples[frame * 6 + channel] = (short)MathF.Round(amplitude * MathF.Sin(2.0f * MathF.PI * 1000.0f * frame / rate));
                }

                return data;
            }

            static (double Left, double Right) Rms(byte[] stereo, int frameCount, int skipFrames)
            {
                ReadOnlySpan<short> samples = MemoryMarshal.Cast<byte, short>(stereo.AsSpan());
                double left = 0, right = 0;
                int count = 0;

                for (int frame = skipFrames; frame < frameCount; frame++)
                {
                    left += (double)samples[frame * 2] * samples[frame * 2];
                    right += (double)samples[frame * 2 + 1] * samples[frame * 2 + 1];
                    count++;
                }

                return count > 0 ? (Math.Sqrt(left / count), Math.Sqrt(right / count)) : (0, 0);
            }

            // matrix: must be byte-identical to the compat layer's downmix.
            using (AppleOutputProcessor matrix = AppleOutputProcessor.Create(AppleOutputMode.Matrix, rate, 2400))
            {
                Check("matrix 器件建立", matrix.EffectiveMode == AppleOutputMode.Matrix && matrix.InitError == null);

                byte[] input = Tone(2);
                byte[] output = new byte[frames * 2 * sizeof(short)];
                byte[] expected = new byte[output.Length];
                matrix.Process(input, output);

                Downmixing.DownMixSurroundToStereo(MemoryMarshal.Cast<byte, short>(input.AsSpan()), MemoryMarshal.Cast<byte, short>(expected.AsSpan()));
                Check("matrix 与 Downmixing 逐字节一致", output.AsSpan().SequenceEqual(expected));

                (double left, double right) = Rms(output, frames, skip);
                Check("matrix 中置有量", left > 0.6 * inputRms && right > 0.6 * inputRms, $"L {left:F0} R {right:F0}（输入 {inputRms:F0}）");

                byte[] lfe = Tone(3);
                matrix.Process(lfe, output);
                (left, right) = Rms(output, frames, skip);
                Check("matrix 低音并入（0.251）", left > 0.2 * inputRms && left < 0.3 * inputRms, $"L {left:F0}");
            }

            // sys: AudioConverter PerformDownmix=1; measured on macOS: FL/FR 0.4142, C/S 0.2929, LFE 0.
            using (AppleOutputProcessor system = AppleOutputProcessor.Create(AppleOutputMode.System, rate, 2400))
            {
                Check("sys 器件建立", system.EffectiveMode == AppleOutputMode.System && system.InitError == null,
                    system.InitError ?? "");

                if (system.EffectiveMode == AppleOutputMode.System)
                {
                    byte[] output = new byte[frames * 2 * sizeof(short)];

                    system.Process(Tone(0), output);
                    (double left, double right) = Rms(output, frames, skip);
                    Check("sys 左前 ≈ 0.4142", Math.Abs(left / inputRms - 0.4142) < 0.01 && right < 1, $"L {left / inputRms:F4} R {right / inputRms:F4}");

                    system.Process(Tone(2), output);
                    (left, right) = Rms(output, frames, skip);
                    Check("sys 中置 ≈ 0.2929 两路", Math.Abs(left / inputRms - 0.2929) < 0.01 && Math.Abs(right / inputRms - 0.2929) < 0.01,
                        $"L {left / inputRms:F4} R {right / inputRms:F4}");

                    system.Process(Tone(3), output);
                    (left, right) = Rms(output, frames, skip);
                    Check("sys 低音丢弃", left < 1 && right < 1, $"L {left:F2} R {right:F2}");
                }
            }

            // spatial: AUSM; assert behaviour (direction / LFE attenuation), not an algorithm-specific gain.
            using (AppleOutputProcessor spatial = AppleOutputProcessor.Create(AppleOutputMode.Spatial, rate, 2400))
            {
                Check("spatial 器件建立", spatial.EffectiveMode == AppleOutputMode.Spatial && spatial.InitError == null,
                    spatial.InitError ?? "");

                if (spatial.EffectiveMode == AppleOutputMode.Spatial)
                {
                    byte[] output = new byte[frames * 2 * sizeof(short)];

                    spatial.Process(Tone(0), output);
                    (double frontLeft, double frontRight) = Rms(output, frames, skip);
                    Check("spatial 左前偏左", frontLeft > 2.0 * frontRight && frontLeft > 0.2 * inputRms, $"L {frontLeft:F0} R {frontRight:F0}");

                    spatial.Process(Tone(2), output);
                    (double centerLeft, double centerRight) = Rms(output, frames, skip);
                    Check("spatial 中置两路都有", centerLeft > 0.2 * inputRms && centerRight > 0.2 * inputRms, $"L {centerLeft:F0} R {centerRight:F0}");

                    spatial.Process(Tone(3), output);
                    (double lfeLeft, double lfeRight) = Rms(output, frames, skip);
                    Check("spatial 低音被重衰减", lfeLeft < 0.1 * centerLeft && lfeRight < 0.1 * centerRight, $"L {lfeLeft:F0} R {lfeRight:F0}");

                    byte[] input = Tone(2);
                    long start = Stopwatch.GetTimestamp();

                    for (int i = 0; i < 100; i++)
                    {
                        spatial.Process(input, output);
                    }

                    double microseconds = (Stopwatch.GetTimestamp() - start) * 1e6 / Stopwatch.Frequency / 100;
                    Console.WriteLine($"读数：spatial 一片 {frames} 帧 {microseconds:F1} µs（{frames / (double)rate * 1000:F0} ms 音频，单核约 {microseconds * 100 / (frames / (double)rate * 1e6):F2}%）");
                }
            }

            Console.WriteLine(failures == 0 ? "5.1 输出档：全部通过" : $"5.1 输出档：{failures} 项失败");

            return failures == 0 ? 0 : 1;
        }
    }
}
