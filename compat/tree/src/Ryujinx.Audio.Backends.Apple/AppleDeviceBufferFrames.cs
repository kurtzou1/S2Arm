using System;

namespace Ryujinx.Audio.Backends.Apple   // 平台例外：Apple 后端平台实现的命名空间（11-14 设备缓冲）
{
    // S2Arm (11-14 设备缓冲): the device IO buffer frame size (kAudioDevicePropertyBufferFrameSize) is configurable.
    //
    // Why: the backend never requested a device buffer size, so macOS devices fall back to their default IO period
    // (built-in speakers: 512 frames ≈ 10.7 ms at 48 kHz) and that one device IO cycle is a permanent floor on output
    // latency. Measured on Mac: the device accepts 16 frames (≈ 0.33 ms) and audio stays clean, the device hand-back
    // cadence gets much finer and the audren chain drops accordingly (see AppleHardwareDeviceSession.S2AApplyDeviceBufferFrames).
    //
    // Contract (S2A_AUDIO_BUFFER_FRAMES, opt-in; unset keeps the current behaviour):
    //   valid   - a multiple of 16 in [16, 512]: requested on the queue's device at every queue creation (start and
    //             stall rebuild). Measured 11-14 on macOS: the value is per client process — another process still
    //             reads the device default (512) while ours holds 32, and nothing is left behind when our process exits.
    //   unset / invalid - request nothing (the current behaviour; invalid values get a 【红】 line and fall back).
    // Player choice: Mac per-game launch settings "Audio latency" (launchers/shared/game_settings.v1.json audioLatency:
    // Standard = unset / Low = 128 / Lowest = 32), turned into this variable at launch by pack/jobs/community.py launch_env;
    // the wider 16-step domain here is defensive for hand-edited env values.
    internal static class AppleDeviceBufferFrames
    {
        public const int Min = 16;
        public const int Max = 512;
        public const int Step = 16;

        public static bool IsValid(int frames) => frames >= Min && frames <= Max && frames % Step == 0;

        // 0 = 不请求（没设 / 不合法）；合法值 = 请求的设备缓冲帧数。建队时调用（每局 ~2 次，不在实时路径上）
        public static int FromEnvironment()
        {
            string value = Environment.GetEnvironmentVariable("S2A_AUDIO_BUFFER_FRAMES");

            if (string.IsNullOrWhiteSpace(value))
            {
                return 0;
            }

            if (int.TryParse(value.Trim(), out int frames) && IsValid(frames))
            {
                return frames;
            }

            Console.Error.WriteLine($"[声] 【红】S2A_AUDIO_BUFFER_FRAMES=「{value}」不合法（要 16 的倍数、{Min}–{Max}）：不请求，跟随系统默认（{DefaultNote}）");
            return 0;
        }

        private const string DefaultNote = "Mac 内置扬声器 512 帧 ≈ 10.7 ms";
    }
}
