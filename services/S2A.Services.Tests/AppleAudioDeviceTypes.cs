using Ryujinx.Audio;
using Ryujinx.Audio.Backends.Apple;   // 平台例外：本用例只测 Apple 音频后端（#189 后续，设备类型 + 虚拟环绕），只在 macOS 上跑
using Ryujinx.Audio.Backends.Apple.Native;   // 平台例外：本用例只测 Apple 音频后端（#189 后续），只在 macOS 上跑
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Renderer.Device;   // 平台例外：本用例只测 Apple 音频后端（#189 后续，active device 名字映射），只在 macOS 上跑
using Ryujinx.Audio.Integration;
using Ryujinx.Memory;
using System;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.Reflection;
using System.Runtime.InteropServices;
using static Ryujinx.Audio.Backends.Apple.Native.AudioToolbox;   // 平台例外：本用例只测 Apple 音频后端（#189 后续），只在 macOS 上跑
using DriverProbe = Ryujinx.Audio.Backends.Apple.AppleHardwareDeviceDriver;   // 平台例外：本用例只测 Apple 音频后端探测，只在 macOS 上跑

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // Pre-boot solo test（#189 后续）：设备类型选择器、驱动上报矩阵、active device 名字/声道映射（第二片，§4.5）、
        //   会话路径接线（不出声：会话只建不播）、AUSM 5.1 判据（处理器级手动拉取，纯 CPU 不出声）。读数基准 = 评估的裸 AUSM 手动渲染表
        //   （48 kHz / 997 Hz / 4800 帧跳过前 1200 帧）：显式 BuiltInSpeakers——FL +7.1 dB、C 等幅、LFE 0.000（移除）、
        //   BL 近等幅（-0.5 dB）；显式 Headphones——FL +8.0 dB、延迟约 0.4–1.4 ms（19–67 样本）、C 等幅、
        //   LFE 受衰减（约 7% 输入）；ExternalSpeakers / .auto——FL 仅左、BL +12.8 dB、0 延迟（普通平移，负对照见坑记录）。
        //   试建队列的 callback 必须非空（macOS 27 起 NULL 直接 -50，#189）
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void DeviceTypesProbeCallback(nint userData, nint audioQueue, nint buffer);

        private static readonly DeviceTypesProbeCallback _deviceTypesProbeCallback = static (_, _, _) => { };

        [DynamicDependency(DynamicallyAccessedMemberTypes.NonPublicFields,
            "Ryujinx.Audio.Backends.Apple.ApplePullHardwareDeviceSession", "Ryujinx.Audio.Backends.Apple")]   // 平台例外：本用例只测 Apple 音频后端的会话接线（#189 后续），只在 macOS 上跑
        // 本线程 CPU 时间（纳秒）：CLOCK_THREAD_CPUTIME_ID = 16（<time.h>），按线程计，被抢占的时间不算
        [DllImport("/usr/lib/libSystem.dylib")]   // 平台例外：苹果音频后端单测，只在 macOS 跑
        private static extern ulong clock_gettime_nsec_np(int clock);
        private static ulong ThreadCpuNs() => clock_gettime_nsec_np(16);

        // 读回我方设给 AUSM 的属性（只读；判据只核我方输入，见 ⑥）
        [DllImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", EntryPoint = "AudioUnitGetProperty")]   // 平台例外：本用例只测 Apple 音频后端（读回我方设给 AUSM 的属性），只在 macOS 上跑
        private static extern int AudioUnitGetPropertyRaw(nint unit, uint id, uint scope, uint element, nint data, ref uint size);

        [SoloTest("--apple-audio-device-types")]
        internal static int AppleAudioDeviceTypes()
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

            if (!AppleHardwareDeviceDriver.IsSupported)   // 平台例外：本用例只测 Apple 音频后端（#189 后续），只在 macOS 上跑
            {
                Console.WriteLine("【红】Apple 音频后端不可用");
                return 1;
            }

            string oldDevice = Environment.GetEnvironmentVariable("S2A_AUDIO_DEVICE");
            string oldVsSpeakers = Environment.GetEnvironmentVariable("S2A_AUDIO_VS_SPEAKERS");
            string oldVsHeadphones = Environment.GetEnvironmentVariable("S2A_AUDIO_VS_HEADPHONES");
            string oldCh2 = Environment.GetEnvironmentVariable("S2A_AUDIO_CH2");
            string oldStereo = Environment.GetEnvironmentVariable("S2A_AUDIO_STEREO");
            string oldOut = Environment.GetEnvironmentVariable("S2A_AUDIO_OUT");

            void Set(string device, string vsSpeakers, string vsHeadphones)
            {
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", device);
                Environment.SetEnvironmentVariable("S2A_AUDIO_VS_SPEAKERS", vsSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_VS_HEADPHONES", vsHeadphones);
            }

            bool Reports6()
            {
                using AppleHardwareDeviceDriver driver = new();   // 平台例外：本用例只测 Apple 音频后端（#189 后续），只在 macOS 上跑

                return driver.SupportsChannelCount(6);
            }

            try
            {
                Environment.SetEnvironmentVariable("S2A_AUDIO_CH2", null);
                Environment.SetEnvironmentVariable("S2A_AUDIO_STEREO", null);
                Environment.SetEnvironmentVariable("S2A_AUDIO_OUT", null);

                // ① 设备类型选择器：缺省 Auto（未显式选择 = 按设备自动判，评审 11-16）；显式解析三种类型；非法值回落 Auto
                Set(null, null, null);
                Check("缺省设备类型 = Auto（未显式选择 = 按设备自动）", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.Auto);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "auto");
                Check("auto 解析", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.Auto);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "builtin");
                Check("builtin 解析", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.BuiltInSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "BuiltInSpeakers");
                Check("BuiltInSpeakers 别名（不分大小写）", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.BuiltInSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "speakers");
                Check("speakers 别名", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.BuiltInSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "headphones");
                Check("headphones 解析", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.Headphones);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "Headphone");
                Check("Headphone 别名", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.Headphones);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "external");
                Check("external 解析", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.ExternalSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "ExternalSpeakers");
                Check("ExternalSpeakers 别名", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.ExternalSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "tv");
                Check("tv 别名", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.ExternalSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "bogus");
                Check("不认识的设备类型回落 Auto（按设备自动判）", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.Auto);

                // 两个 VS 开关按类型分别读、external 永远关
                Set("builtin", "1", null);
                Check("builtin 的 VS 开（S2A_AUDIO_VS_SPEAKERS=1）", AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.BuiltInSpeakers));
                Set("builtin", "0", null);
                Check("builtin 的 VS 关（0）", !AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.BuiltInSpeakers));
                Set("builtin", null, null);
                Check("builtin 的 VS 缺省关", !AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.BuiltInSpeakers));
                Set("builtin", null, "1");
                Check("builtin 不看耳机的 VS 开关", !AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.BuiltInSpeakers));
                Set("headphones", null, "1");
                Check("headphones 的 VS 开（S2A_AUDIO_VS_HEADPHONES=1）", AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.Headphones));
                Set("headphones", "1", null);
                Check("headphones 不看扬声器的 VS 开关", !AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.Headphones));
                Set("external", "1", "1");
                Check("external 的 VS 永远关", !AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.ExternalSpeakers));
                Check("Auto 的 VS 永远关（未显式选择不套 VS）", !AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.Auto));

                // ② 驱动上报矩阵：缺省（未显式选择）按设备真实声道判——期望按 main 的 #577 判据写死（评审 11-16），
                //   用注入的探测读数模拟设备（产品路径不走注入）；显式 builtin / headphones 才看各自 VS 开关
                Check("NeedsSurroundProbe 共用判据：队列成功 + 声道读取成功 + ≥6 才建布局队列",
                    DriverProbe.NeedsSurroundProbe(0, 0, 6) && DriverProbe.NeedsSurroundProbe(0, 0, 8) &&
                    !DriverProbe.NeedsSurroundProbe(-50, 0, 6) && !DriverProbe.NeedsSurroundProbe(0, 5, 6) &&
                    !DriverProbe.NeedsSurroundProbe(0, 0, 2));
                Set(null, null, null);
                AppleHardwareDeviceDriver.S2ATestProbe = (0, 6, 0, 0);   // 平台例外：注入试建读数，模拟 6 声道设备
                Check("未显式选择 + 设备 6 声道 → 上报 5.1（main 的 #577 判据）", Reports6());
                Check("6 声道探测：先用 2 声道队列读数，再试 6 声道布局", DriverProbe.S2ATestProbeFirstQueueChannels == 2 &&
                    DriverProbe.S2ATestProbeSurroundQueueChannels == 6 && DriverProbe.S2ATestProbeLayoutCalls == 1,
                    $"首队列 {DriverProbe.S2ATestProbeFirstQueueChannels}、布局队列 {DriverProbe.S2ATestProbeSurroundQueueChannels}、布局调用 {DriverProbe.S2ATestProbeLayoutCalls}");
                AppleHardwareDeviceDriver.S2ATestProbe = (0, 2, 0, 0);   // 平台例外：模拟 2 声道设备
                Check("未显式选择 + 设备 2 声道 → 上报 2", !Reports6());
                Check("2 声道设备不建 6 声道队列、不设置 5.1 布局", DriverProbe.S2ATestProbeFirstQueueChannels == 2 &&
                    DriverProbe.S2ATestProbeSurroundQueueChannels == 0 && DriverProbe.S2ATestProbeLayoutCalls == 0,
                    $"首队列 {DriverProbe.S2ATestProbeFirstQueueChannels}、布局队列 {DriverProbe.S2ATestProbeSurroundQueueChannels}、布局调用 {DriverProbe.S2ATestProbeLayoutCalls}");
                AppleHardwareDeviceDriver.S2ATestProbe = (0, 6, 5, 0);   // 平台例外：模拟声道数读失败
                Check("未显式选择 + 读声道失败 → 上报 2（【红】后保守）", !Reports6());
                AppleHardwareDeviceDriver.S2ATestProbe = (-50, 0, -1, -1);   // 平台例外：模拟试建队列失败（macOS 27 的 NULL callback 坑）
                Check("未显式选择 + 试建队列失败 → 上报 2", !Reports6());
                AppleHardwareDeviceDriver.S2ATestProbe = (0, 6, 0, 5);   // 平台例外：模拟 5.1 布局设置失败
                Check("未显式选择 + 5.1 布局设置失败 → 上报 2（保守回退）", !Reports6());
                AppleHardwareDeviceDriver.S2ATestProbe = (0, 6, 0, 0);   // 平台例外：6 声道设备
                Environment.SetEnvironmentVariable("S2A_AUDIO_VS_SPEAKERS", "1");
                Check("未显式选择 + 只设 VS 开关 → 仍按设备判报 5.1（VS 只在显式类型生效）", Reports6());
                Environment.SetEnvironmentVariable("S2A_AUDIO_VS_SPEAKERS", null);
                AppleHardwareDeviceDriver.S2ATestProbe = null;   // 平台例外：清注入，后面的用例走真探测
                Set("builtin", "1", null);
                Check("builtin + VS 开上报 6", Reports6());
                Set("builtin", null, null);
                Check("builtin + VS 关不上报 6", !Reports6());
                Set("builtin", null, "1");
                Check("builtin 只看自己的 VS 开关", !Reports6());
                Set("headphones", null, "1");
                Check("headphones + VS 开上报 6", Reports6());
                Set("headphones", null, null);
                Check("headphones + VS 关不上报 6", !Reports6());
                Set("headphones", "1", null);
                Check("headphones 只看自己的 VS 开关", !Reports6());

                // external：上报 6 ⇔ 默认输出设备真实声道数 ≥ 6；两个 VS 开关都不改变它
                AudioStreamBasicDescription format =
                    AppleHardwareDeviceDriver.GetAudioFormat(SampleFormat.PcmFloat, Constants.TargetSampleRate, 2);   // 平台例外：本用例只测 Apple 音频后端（#189 后续），只在 macOS 上跑

                int newResult = AudioQueueNewOutput(
                    ref format,
                    Marshal.GetFunctionPointerForDelegate(_deviceTypesProbeCallback),
                    nint.Zero, nint.Zero, nint.Zero, 0, out nint queue);

                uint deviceChannels = 0;
                bool readOk = false;

                if (newResult == 0)
                {
                    uint size = sizeof(uint);
                    int getResult = AudioQueueGetProperty(
                        queue, kAudioQueueDeviceProperty_NumberChannels, out deviceChannels, ref size);
                    AudioQueueDispose(queue, true);
                    readOk = getResult == 0;
                    Check("独立读默认输出设备声道数", readOk, $"rc={getResult}");
                }
                else
                {
                    Check("独立读默认输出设备声道数（试建队列）", false, $"AudioQueueNewOutput rc={newResult}");
                }

                if (readOk)
                {
                    Set("external", null, null);
                    Check("external：上报 6 ⇔ 设备 ≥ 6 声道", Reports6() == (deviceChannels >= 6),
                        $"设备 {deviceChannels} 声道（builtin/VS 缺省也不因设备 ≥6 上报 6，VS 开才报）");
                    Set("external", "1", "1");
                    Check("external：两个 VS 开关不改变上报", Reports6() == (deviceChannels >= 6),
                        $"设备 {deviceChannels} 声道（external 不虚拟环绕）");
                }

                // ③ active device（第二片，计划 §4.5；游戏经 HLE AudioDevice 看到的名字 / 声道数，直接构造 VirtualDeviceSessionRegistry）：
                //   名字按玩家显式选择的设备类型定（builtin → AudioBuiltInSpeakerOutput、headphones → AudioStereoJackOutput，
                //   USB 等真实接口名不另报——设备类型语义的简化），声道数照旧只看 SupportsChannelCount(6)；
                //   未显式选择（Auto）与 external 不给名字 → 缺省 AudioTvOutput，缺省路径逐字节不变
                (uint Channels, string Name) ActiveDevice()
                {
                    using AppleHardwareDeviceDriver driver = new();   // 平台例外：本用例只测 Apple 音频后端（#189 后续），只在 macOS 上跑
                    VirtualDevice device = new VirtualDeviceSessionRegistry(driver).ActiveDevice;   // 平台例外：同上
                    return (device.ChannelCount, device.Name);
                }

                Set(null, null, null);
                AppleHardwareDeviceDriver.S2ATestProbe = (0, 6, 0, 0);   // 平台例外：注入试建读数，模拟 6 声道设备
                (uint ch, string name) = ActiveDevice();
                Check("未显式选择 + 6 声道 → active device 照旧 AudioTvOutput 6 声道（缺省不变）", ch == 6 && name == "AudioTvOutput", $"{name} {ch}");
                AppleHardwareDeviceDriver.S2ATestProbe = (0, 2, 0, 0);   // 平台例外：模拟 2 声道设备
                (ch, name) = ActiveDevice();
                Check("未显式选择 + 2 声道 → AudioTvOutput 2 声道（缺省不变）", ch == 2 && name == "AudioTvOutput", $"{name} {ch}");
                Set("builtin", "1", null);
                (ch, name) = ActiveDevice();
                Check("builtin + VS 开 → AudioBuiltInSpeakerOutput 6 声道", ch == 6 && name == "AudioBuiltInSpeakerOutput", $"{name} {ch}");
                Set("builtin", null, null);
                (ch, name) = ActiveDevice();
                Check("builtin + VS 关 → AudioBuiltInSpeakerOutput 2 声道", ch == 2 && name == "AudioBuiltInSpeakerOutput", $"{name} {ch}");
                Set("headphones", null, "1");
                (ch, name) = ActiveDevice();
                Check("headphones + VS 开 → AudioStereoJackOutput 6 声道", ch == 6 && name == "AudioStereoJackOutput", $"{name} {ch}");
                Set("headphones", null, null);
                (ch, name) = ActiveDevice();
                Check("headphones + VS 关 → AudioStereoJackOutput 2 声道", ch == 2 && name == "AudioStereoJackOutput", $"{name} {ch}");
                Set("external", "1", "1");
                AppleHardwareDeviceDriver.S2ATestProbe = (0, 6, 0, 0);   // 平台例外：模拟 6 声道设备
                (ch, name) = ActiveDevice();
                Check("external + 6 声道 → AudioTvOutput 6 声道（直通，VS 开关不改变名字）", ch == 6 && name == "AudioTvOutput", $"{name} {ch}");
                AppleHardwareDeviceDriver.S2ATestProbe = (0, 2, 0, 0);   // 平台例外：模拟 2 声道设备
                (ch, name) = ActiveDevice();
                Check("external + 2 声道 → AudioTvOutput 2 声道（下混）", ch == 2 && name == "AudioTvOutput", $"{name} {ch}");
                AppleHardwareDeviceDriver.S2ATestProbe = null;   // 平台例外：清注入，后面的用例走真探测

                // ④ S2A_AUDIO_CH2 仍最高优先级；S2A_AUDIO_OUT=sys 显式下混优先于设备类型
                Set("builtin", "1", null);
                Environment.SetEnvironmentVariable("S2A_AUDIO_CH2", "1");
                Check("builtin + VS 开 + S2A_AUDIO_CH2=1 仍强制立体声", !Reports6());
                Environment.SetEnvironmentVariable("S2A_AUDIO_CH2", null);
                Environment.SetEnvironmentVariable("S2A_AUDIO_OUT", "sys");
                Check("builtin + VS 关 + S2A_AUDIO_OUT=sys 照报 5.1（显式下混优先）", Reports6());
                Environment.SetEnvironmentVariable("S2A_AUDIO_OUT", null);

                // ⑤ 会话路径接线（反射 _processor / _deviceChannelCount；会话只建不播，不出声）
                FieldInfo processorField = typeof(ApplePullHardwareDeviceSession).GetField("_processor", BindingFlags.NonPublic | BindingFlags.Instance)   // 平台例外：本用例只测 Apple 音频后端的会话接线（#189 后续），只在 macOS 上跑
                    ?? throw new InvalidOperationException("找不到 ApplePullHardwareDeviceSession._processor");   // 平台例外：同上，只在 macOS 上跑
                FieldInfo deviceChannelsField = typeof(ApplePullHardwareDeviceSession).GetField("_deviceChannelCount", BindingFlags.NonPublic | BindingFlags.Instance)   // 平台例外：同上，只在 macOS 上跑
                    ?? throw new InvalidOperationException("找不到 ApplePullHardwareDeviceSession._deviceChannelCount");   // 平台例外：同上，只在 macOS 上跑

                (AppleOutputMode? Mode, int DeviceChannels) Session(AppleAudioDeviceType? type, string vs, SampleFormat sampleFormat)
                {
                    Set(type == AppleAudioDeviceType.BuiltInSpeakers ? "builtin"
                      : type == AppleAudioDeviceType.Headphones ? "headphones"
                      : type == AppleAudioDeviceType.ExternalSpeakers ? "external" : null, vs, vs);

                    using MemoryBlock backing = new(0x1000);
                    var memory = new Ryujinx.Cpu.Jit.MemoryManager(backing, 0x1000);
                    memory.IncrementReferenceCount();

                    try
                    {
                        using AppleHardwareDeviceDriver driver = new();   // 平台例外：本用例只测 Apple 音频后端（#189 后续），只在 macOS 上跑
                        using IHardwareDeviceSession session = driver.OpenDeviceSession(   // 平台例外：同上
                            IHardwareDeviceDriver.Direction.Output, memory, sampleFormat, 48000, 6);
                        AppleOutputProcessor processor = (AppleOutputProcessor)processorField.GetValue(session);

                        return (processor?.EffectiveMode ?? null, (int)deviceChannelsField.GetValue(session));
                    }
                    finally
                    {
                        memory.DecrementReferenceCount();
                    }
                }

                (AppleOutputMode? mode, int sessionChannels) = Session(AppleAudioDeviceType.BuiltInSpeakers, "1", SampleFormat.PcmInt16);
                Check("builtin + VS 开 + 6ch PCM16 → AUSM 内置扬声器档（会话折到 2 声道）",
                    mode == AppleOutputMode.SpatialSpeakers && sessionChannels == 2,
                    $"档 {mode?.ToString() ?? "无"}、设备声道 {sessionChannels}");
                (mode, sessionChannels) = Session(AppleAudioDeviceType.Headphones, "1", SampleFormat.PcmInt16);
                Check("headphones + VS 开 + 6ch PCM16 → AUSM 耳机档（会话折到 2 声道）",
                    mode == AppleOutputMode.SpatialHeadphones && sessionChannels == 2,
                    $"档 {mode?.ToString() ?? "无"}、设备声道 {sessionChannels}");
                (mode, sessionChannels) = Session(AppleAudioDeviceType.BuiltInSpeakers, null, SampleFormat.PcmInt16);
                Check("builtin + VS 关 → 无处理器、6 声道直交（不套 AUSM）",
                    mode == null && sessionChannels == 6, $"档 {mode?.ToString() ?? "无"}、设备声道 {sessionChannels}");
                (mode, sessionChannels) = Session(AppleAudioDeviceType.Headphones, null, SampleFormat.PcmInt16);
                Check("headphones + VS 关 → 无处理器、6 声道直交",
                    mode == null && sessionChannels == 6, $"档 {mode?.ToString() ?? "无"}、设备声道 {sessionChannels}");
                (mode, sessionChannels) = Session(AppleAudioDeviceType.ExternalSpeakers, "1", SampleFormat.PcmInt16);
                Check("external + 6ch → 无处理器、6 声道直通队列（VS 无效）",
                    mode == null && sessionChannels == 6, $"档 {mode?.ToString() ?? "无"}、设备声道 {sessionChannels}");
                (mode, sessionChannels) = Session(AppleAudioDeviceType.BuiltInSpeakers, "1", SampleFormat.PcmFloat);
                Check("builtin + VS 开 + 6ch 非 PCM16 → 无处理器（只支持 PCM16 的 5.1）",
                    mode == null && sessionChannels == 6, $"档 {mode?.ToString() ?? "无"}、设备声道 {sessionChannels}");
                (mode, sessionChannels) = Session(null, "1", SampleFormat.PcmInt16);
                Check("未显式选择 + 只设 VS 开 + 6ch → 无处理器（VS 只在显式类型生效，走原 6ch 路径）",
                    mode == null && sessionChannels == 6, $"档 {mode?.ToString() ?? "无"}、设备声道 {sessionChannels}");

                // ⑥ AUSM 5.1 判据（处理器级，无声）：裸 AUSM 手动拉取，读数基准见方法头注释
                const int rate = 48000;
                const int frames = 4800;
                const float amplitude = 16000.0f;
                double inputRms = amplitude / Math.Sqrt(2.0);

                byte[] Tone(int channel)
                {
                    byte[] data = new byte[frames * 6 * sizeof(short)];
                    Span<short> samples = MemoryMarshal.Cast<byte, short>(data.AsSpan());

                    for (int frame = 0; frame < frames; frame++)
                    {
                        samples[frame * 6 + channel] = (short)MathF.Round(amplitude * MathF.Sin(2.0f * MathF.PI * 997.0f * frame / rate));
                    }

                    return data;
                }

                // 判据只问我方送给 AUSM 的东西（11-19 维护者规矩「判据只问我方输出」）：AUSM 渲染出的声音形状（左右比、等幅、LFE 去除、双耳延迟）
                //   是苹果混音器的行为，随 macOS 版本漂移——同一树 27.0.1 上 BL 两路差 12.8 dB、27.2.1 近等幅，原判据在门禁机红、本机绿。
                //   改核三件我方负责的：① 我方设给 AUSM 的属性读回（输出类型 / 算法 / 源模式 / 输入 MPEG_5_1_A、输出 Stereo / 输入 6 声道）；
                //   ② 每路测试音落在我方填给 AUSM 的对应输入平面（Switch 5.1 与 MPEG_5_1_A 同为 L R C LFE Ls Rs，恒等映射），别的平面静音；
                //   ③ AudioUnitRender 成功（处理器失败计数不涨），即确实出了数。期望值都由我方配置与测试音手算，不读混音器输出
                FieldInfo unitField = typeof(AppleOutputProcessor).GetField("_unit", BindingFlags.NonPublic | BindingFlags.Instance);
                FieldInfo planesField = typeof(AppleOutputProcessor).GetField("_spatialInPlanes", BindingFlags.NonPublic | BindingFlags.Instance);
                Check("测试观测口：处理器字段 _unit / _spatialInPlanes 在", unitField != null && planesField != null, "");

                uint ReadU32(AppleOutputProcessor p, uint id, uint scope, int offset, int bytes)
                {
                    nint unit = (nint)unitField.GetValue(p);
                    nint buf = Marshal.AllocHGlobal(bytes);

                    try
                    {
                        uint size = (uint)bytes;
                        int rc = AudioUnitGetPropertyRaw(unit, id, scope, 0, buf, ref size);

                        return rc == 0 ? (uint)Marshal.ReadInt32(buf, offset) : uint.MaxValue;
                    }
                    finally
                    {
                        Marshal.FreeHGlobal(buf);
                    }
                }

                void CheckOwnInput(string tag, AppleOutputProcessor p, uint wantOutputType)
                {
                    Check($"{tag}：AUSM 输出类型 = {wantOutputType}（我方设的）", ReadU32(p, AudioUnitInterop.kAudioUnitProperty_SpatialMixerOutputType, AudioUnitInterop.kAudioUnitScope_Global, 0, 4) == wantOutputType, "");
                    Check($"{tag}：算法 = UseOutputType", ReadU32(p, AudioUnitInterop.kAudioUnitProperty_SpatializationAlgorithm, AudioUnitInterop.kAudioUnitScope_Input, 0, 4) == AudioUnitInterop.kSpatializationAlgorithm_UseOutputType, "");
                    Check($"{tag}：源模式 = AmbienceBed", ReadU32(p, AudioUnitInterop.kAudioUnitProperty_SpatialMixerSourceMode, AudioUnitInterop.kAudioUnitScope_Input, 0, 4) == AudioUnitInterop.kSpatialMixerSourceMode_AmbienceBed, "");
                    Check($"{tag}：输入布局 = MPEG_5_1_A", ReadU32(p, AudioUnitInterop.kAudioUnitProperty_AudioChannelLayout, AudioUnitInterop.kAudioUnitScope_Input, 0, 64) == kAudioChannelLayoutTag_MPEG_5_1_A, "");
                    Check($"{tag}：输入 6 声道", ReadU32(p, AudioUnitInterop.kAudioUnitProperty_StreamFormat, AudioUnitInterop.kAudioUnitScope_Input, 28, 40) == 6, "");
                    Check($"{tag}：输出 2 声道", ReadU32(p, AudioUnitInterop.kAudioUnitProperty_StreamFormat, AudioUnitInterop.kAudioUnitScope_Output, 28, 40) == 2, "");

                    float[][] planes = (float[][])planesField.GetValue(p);
                    double want = amplitude / 32768.0 / Math.Sqrt(2.0);

                    for (int channel = 0; channel < 6; channel++)
                    {
                        byte[] output = new byte[frames * 2 * sizeof(short)];
                        int failures = p.FailureCount;
                        bool rendered = p.Process(Tone(channel), output) && p.FailureCount == failures;
                        double[] rms = new double[6];

                        for (int plane = 0; plane < 6; plane++)
                        {
                            float[] data = planes[plane];
                            double sum = 0;

                            for (int i = 0; i < data.Length; i++)
                            {
                                sum += (double)data[i] * data[i];
                            }

                            rms[plane] = Math.Sqrt(sum / Math.Max(1, data.Length));
                        }

                        bool onlyThis = Math.Abs(rms[channel] - want) < 0.02 * want;

                        for (int plane = 0; plane < 6; plane++)
                        {
                            onlyThis &= plane == channel || rms[plane] == 0;
                        }

                        Check($"{tag}：第 {channel} 路测试音只进我方第 {channel} 个输入平面、AudioUnitRender 成功", rendered && onlyThis,
                            $"平面 RMS {string.Join(" / ", Array.ConvertAll(rms, v => v.ToString("F3")))}（期望第 {channel} 个 {want:F3}、其余 0）、出数 {rendered}");
                    }
                }

                // 内置扬声器档（显式 BuiltInSpeakers 输出类型）
                using (AppleOutputProcessor speakers = AppleOutputProcessor.Create(AppleOutputMode.SpatialSpeakers, rate, 2400))
                {
                    Check("AUSM BuiltInSpeakers 器件建立", speakers.EffectiveMode == AppleOutputMode.SpatialSpeakers && speakers.InitError == null,
                        speakers.InitError ?? "");

                    if (speakers.EffectiveMode == AppleOutputMode.SpatialSpeakers)
                    {
                        CheckOwnInput("内置扬声器档", speakers, AudioUnitInterop.kSpatialMixerOutputType_BuiltInSpeakers);
                    }
                }

                // 耳机档（显式 Headphones 输出类型）
                using (AppleOutputProcessor headphones = AppleOutputProcessor.Create(AppleOutputMode.SpatialHeadphones, rate, 2400))
                {
                    Check("AUSM Headphones 器件建立", headphones.EffectiveMode == AppleOutputMode.SpatialHeadphones && headphones.InitError == null,
                        headphones.InitError ?? "");

                    if (headphones.EffectiveMode == AppleOutputMode.SpatialHeadphones)
                    {
                        byte[] output = new byte[frames * 2 * sizeof(short)];
                        CheckOwnInput("耳机档", headphones, AudioUnitInterop.kSpatialMixerOutputType_Headphones);

                        // ⑦ 性能读数：ConvertSpatial 在交缓冲的生产方线程上同步跑（评审 11-16），典型片长给
                        //   中位 / 最大；4800 帧一片（50 ms 设备缓冲，两片 2400）有门限 150 µs。
                        //   按本线程 CPU 时间判（AUSM 渲染在调用线程上同步跑）：要守的是混音本身够快、真机上不欠载；
                        //   原先按墙钟，门禁满载时线程被抢占也算进去（11-26 main 实测 493.8 µs，近 40 次钩子红占 6 次），判的是机器忙不忙。墙钟照打不判
                        byte[] bigSlice = new byte[frames * 6 * sizeof(short)];
                        long start = Stopwatch.GetTimestamp();
                        ulong cpu0 = ThreadCpuNs();

                        for (int i = 0; i < 100; i++)
                        {
                            headphones.Process(bigSlice, output);
                        }

                        double cpuMicroseconds = (ThreadCpuNs() - cpu0) / 1e3 / 100;
                        double microseconds = (Stopwatch.GetTimestamp() - start) * 1e6 / Stopwatch.Frequency / 100;
                        Check("AUSM 一片 4800 帧 < 150 µs（线程 CPU）", cpuMicroseconds < 150, $"CPU {cpuMicroseconds:F1} µs、墙钟 {microseconds:F1} µs（100 ms 音频）");

                        foreach (int sliceFrames in new[] { 240, 480, 1024, 2400 })
                        {
                            byte[] slice = new byte[sliceFrames * 6 * sizeof(short)];
                            byte[] sliceOutput = new byte[sliceFrames * 2 * sizeof(short)];
                            double[] samples = new double[200];

                            for (int i = 0; i < 50; i++)
                            {
                                headphones.Process(slice, sliceOutput);
                            }

                            for (int i = 0; i < samples.Length; i++)
                            {
                                long t0 = Stopwatch.GetTimestamp();
                                headphones.Process(slice, sliceOutput);
                                samples[i] = (Stopwatch.GetTimestamp() - t0) * 1e6 / Stopwatch.Frequency;
                            }

                            Array.Sort(samples);
                            Console.WriteLine($"读数：AUSM 一片 {sliceFrames} 帧（{sliceFrames * 1000.0 / rate:F1} ms 音频）中位 {samples[samples.Length / 2]:F1} µs、最大 {samples[^1]:F1} µs");
                        }
                    }
                }
            }
            finally
            {
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", oldDevice);
                Environment.SetEnvironmentVariable("S2A_AUDIO_VS_SPEAKERS", oldVsSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_VS_HEADPHONES", oldVsHeadphones);
                Environment.SetEnvironmentVariable("S2A_AUDIO_CH2", oldCh2);
                Environment.SetEnvironmentVariable("S2A_AUDIO_STEREO", oldStereo);
                Environment.SetEnvironmentVariable("S2A_AUDIO_OUT", oldOut);
            }

            Console.WriteLine(failures == 0 ? "设备类型 + 虚拟环绕：全部通过" : $"设备类型 + 虚拟环绕：{failures} 项失败");

            return failures == 0 ? 0 : 1;
        }
    }
}
