// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Reflection;
using Ryujinx.Audio.Backends.Dummy;
using Ryujinx.Audio.Integration;

namespace S2A.Services.Tests
{
    static unsafe class AudioCompositionTest
    {
        private static int _calls;
        private static IHardwareDeviceDriver Create() { _calls++; return new DummyHardwareDeviceDriver(); }

        [SoloTest("--audio-composition")]
        static int Run()
        {
            var method = typeof(Exports).GetMethod("CreateAudioDriver", BindingFlags.Static | BindingFlags.NonPublic);
            if (method == null) { Console.Error.WriteLine("音频装配：缺少生产音频选择入口"); return 1; }
            bool strict = Red.Strict;
            var log = Red.Log;
            var factory = Exports.AudioFactory;
            string line = null;
            string audioOff = Environment.GetEnvironmentVariable("S2A_AUDIO_OFF");
            try
            {
                Red.Strict = true;
                Red.Log = text => line = text;
                Exports.AudioFactory = null;
                using var fallback = (IHardwareDeviceDriver)method.Invoke(null, null);
                if (fallback is not DummyHardwareDeviceDriver || line == null || !line.Contains("【红】")) return 1;
                line = null;
                Exports.AudioFactory = &Create;
                using var registered = (IHardwareDeviceDriver)method.Invoke(null, null);
                if (registered is not AudioFallbackDriver { Real: DummyHardwareDeviceDriver } || _calls != 1 || line != null) return 1;   // 登记的工厂包一层无声回退（AudioFallback.cs）
                Environment.SetEnvironmentVariable("S2A_AUDIO_OFF", "1");
                using var appleOff = S2A.Apple.Audio.AppleAudio.Create();
                if (appleOff is not DummyHardwareDeviceDriver || line != null) return 1;
                Console.WriteLine("音频装配：未登记报红并用 Dummy；登记后调用指定工厂并包无声回退；Apple 关闭开关保留");
                return 0;
            }
            finally { Exports.AudioFactory = factory; Red.Log = log; Red.Strict = strict; Environment.SetEnvironmentVariable("S2A_AUDIO_OFF", audioOff); }
        }
    }
}
