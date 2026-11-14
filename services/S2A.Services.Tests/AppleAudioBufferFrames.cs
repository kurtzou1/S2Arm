using Ryujinx.Audio.Backends.Apple;   // 平台例外：本用例只测 Apple 音频后端（11-14 设备缓冲），只在 macOS 上跑
using Ryujinx.Audio.Backends.Apple.Native;   // 平台例外：本用例只测 Apple 音频后端（11-14 设备缓冲），只在 macOS 上跑
using System;
using static Ryujinx.Audio.Backends.Apple.Native.AudioToolbox;   // 平台例外：本用例只测 Apple 音频后端（11-14 设备缓冲），只在 macOS 上跑

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // Pre-boot solo test（11-14 设备缓冲）：不出声、不改设备——只测 S2A_AUDIO_BUFFER_FRAMES 的解析口径（合法域 = 16 的倍数、16–512，
        //   没设 / 不合法 = 0 = 不请求）+ CoreAudio 四字符码常量与「读设备当前缓冲帧数」的互操作形状（只读；设设备级属性会动整机 IO 粒度，不在单测里做）。
        [SoloTest("--apple-audio-buffer-frames")]
        internal static int AppleAudioBufferFrames()
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

            if (!AppleHardwareDeviceDriver.IsSupported)   // 平台例外：本用例只测 Apple 音频后端，只在 macOS 上跑
            {
                Console.WriteLine("【红】Apple 音频后端不可用");
                return 1;
            }

            // ① 四字符码常量：'bsiz'（设备 IO 缓冲帧数）、'glob'（全局作用域）、'dOut'（系统默认输出设备）。
            //   值错了 AudioObject 调用会打到别的属性上（设坏设备状态），常量先钉死
            static uint Fcc(string s) => (uint)(s[0] << 24 | s[1] << 16 | s[2] << 8 | s[3]);
            Check("kAudioDevicePropertyBufferFrameSize = 'bsiz'", kAudioDevicePropertyBufferFrameSize == Fcc("bsiz"), $"0x{kAudioDevicePropertyBufferFrameSize:X8}");
            Check("kAudioObjectPropertyScopeGlobal = 'glob'", kAudioObjectPropertyScopeGlobal == Fcc("glob"), $"0x{kAudioObjectPropertyScopeGlobal:X8}");
            Check("kAudioHardwarePropertyDefaultOutputDevice = 'dOut'", kAudioHardwarePropertyDefaultOutputDevice == Fcc("dOut"), $"0x{kAudioHardwarePropertyDefaultOutputDevice:X8}");
            Check("kAudioObjectSystemObject = 1", kAudioObjectSystemObject == 1);

            // ② 合法域：16 的倍数、16–512（启动设置「声音延迟」只用 128 / 32 两档，见 game_settings.v1.json audioLatency）
            Check("下限 / 上限合法（16、512）", AppleDeviceBufferFrames.IsValid(16) && AppleDeviceBufferFrames.IsValid(512));
            Check("中间倍数合法（48、256、496）", AppleDeviceBufferFrames.IsValid(48) && AppleDeviceBufferFrames.IsValid(256) && AppleDeviceBufferFrames.IsValid(496));
            Check("越界不合法（0、15、513）", !AppleDeviceBufferFrames.IsValid(0) && !AppleDeviceBufferFrames.IsValid(15) && !AppleDeviceBufferFrames.IsValid(513));
            Check("非 16 倍数 / 负数不合法（17、100、-16）", !AppleDeviceBufferFrames.IsValid(17) && !AppleDeviceBufferFrames.IsValid(100) && !AppleDeviceBufferFrames.IsValid(-16));
            bool allValid = true;
            for (int f = AppleDeviceBufferFrames.Min; f <= AppleDeviceBufferFrames.Max; f += AppleDeviceBufferFrames.Step) allValid &= AppleDeviceBufferFrames.IsValid(f);
            Check("合法域内 16 步进全合法（防御手改环境值；启动设置只给标准 / 128 / 32）", allValid);

            // ③ 解析：没设 = 0（不请求，现状）；合法值原样；不合法回落 0 并打【红】
            string old = Environment.GetEnvironmentVariable("S2A_AUDIO_BUFFER_FRAMES");
            try
            {
                Environment.SetEnvironmentVariable("S2A_AUDIO_BUFFER_FRAMES", null);
                Check("没设 = 0（跟随系统，现状不变）", AppleDeviceBufferFrames.FromEnvironment() == 0);

                Environment.SetEnvironmentVariable("S2A_AUDIO_BUFFER_FRAMES", "");
                Check("空串 = 0", AppleDeviceBufferFrames.FromEnvironment() == 0);

                Environment.SetEnvironmentVariable("S2A_AUDIO_BUFFER_FRAMES", "  ");
                Check("纯空白 = 0", AppleDeviceBufferFrames.FromEnvironment() == 0);

                foreach (int f in new[] { 16, 32, 512 })
                {
                    Environment.SetEnvironmentVariable("S2A_AUDIO_BUFFER_FRAMES", f.ToString());
                    Check($"S2A_AUDIO_BUFFER_FRAMES={f} 原样通过", AppleDeviceBufferFrames.FromEnvironment() == f);
                }

                Environment.SetEnvironmentVariable("S2A_AUDIO_BUFFER_FRAMES", " 48 ");
                Check("带空白取整后通过（48）", AppleDeviceBufferFrames.FromEnvironment() == 48);

                foreach (string bad in new[] { "17", "100", "544", "0", "-16", "abc", "" })
                {
                    Environment.SetEnvironmentVariable("S2A_AUDIO_BUFFER_FRAMES", bad);
                    Check($"不合法「{bad}」= 0（打【红】，不请求）", AppleDeviceBufferFrames.FromEnvironment() == 0);
                }
            }
            finally
            {
                Environment.SetEnvironmentVariable("S2A_AUDIO_BUFFER_FRAMES", old);
            }

            // ④ 互操作形状（只读）：从 AudioObject 系统对象读默认输出设备号，再读设备当前缓冲帧数
            //   （>0 即结构布局 / 调用约定正确；设备给多少算多少，不改它）
            if (OperatingSystem.IsMacOS())   // 平台例外：只读探针读 Mac 默认输出设备的 HAL 属性，iOS 没有 HAL 设备属性
            {
                AudioObjectPropertyAddress defaultOut = new()
                {
                    Selector = kAudioHardwarePropertyDefaultOutputDevice,
                    Scope = kAudioObjectPropertyScopeGlobal,
                    Element = kAudioObjectPropertyElementMain
                };
                uint device = 0;
                uint deviceSize = sizeof(uint);
                int devResult = AudioObjectGetPropertyData(kAudioObjectSystemObject, ref defaultOut, 0, nint.Zero, ref deviceSize, ref device);
                Check("读默认输出设备号（'dOut'）", devResult == 0 && device != 0, $"rc={devResult}，device={device}");

                if (devResult == 0 && device != 0)
                {
                    AudioObjectPropertyAddress address = new()
                    {
                        Selector = kAudioDevicePropertyBufferFrameSize,
                        Scope = kAudioObjectPropertyScopeGlobal,
                        Element = kAudioObjectPropertyElementMain
                    };
                    uint frames = 0;
                    uint readSize = sizeof(uint);
                    int getResult = AudioObjectGetPropertyData(device, ref address, 0, nint.Zero, ref readSize, ref frames);
                    Check("读设备当前缓冲帧数（'bsiz'，只读）", getResult == 0 && frames > 0, $"rc={getResult}，当前 {frames} 帧");
                }
            }

            if (failures > 0)
            {
                Console.Error.WriteLine($"【红】--apple-audio-buffer-frames：{failures} 项不符");
                return 1;
            }

            Console.WriteLine("PASS：S2A_AUDIO_BUFFER_FRAMES 解析口径（16 倍数 16–512，没设 / 不合法 = 不请求）+ 'bsiz'/'glob'/'dOut' 常量与设备缓冲只读互操作");
            return 0;
        }
    }
}
