// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// OHOS composition reuses the shared services state machine and its existing C ABI.
using Ryujinx.Audio.Integration;
using Ryujinx.HLE.UI;
using S2A.Audio.OHAudio;
using System;
using System.Runtime.InteropServices;

namespace S2A.Android.Aot;
internal static unsafe class RuntimePlatform
{
    [DllImport("s2a_native")] private static extern nint s2a_ohos_state_directory();
    [DllImport("s2a_native")] private static extern nint s2a_ohos_library_handle();
    [DllImport("s2a_native")] private static extern void s2a_ohos_perf_begin();
    [DllImport("s2a_native")] private static extern void s2a_ohos_perf_present();
    [DllImport("s2a_native")] private static extern nint s2a_ohos_game_directory();
    [DllImport("s2a_native")] private static extern nint s2a_ohos_module_directory();
    [DllImport("s2a_native")] private static extern uint s2a_ohos_fps_present_hook();
    internal static nint LibraryHandle => s2a_ohos_library_handle();
    // 喂数线程报错（设备被拔 / 被抢占）交给共用回退改无声（S2A.Services.AudioFallbackDriver）；没有在用的回退驱动才按致命处理
    internal static IHardwareDeviceDriver CreateAudio(Action<Exception> fatal) =>
        new OHAudioHardwareDeviceDriver(error => { if (!S2A.Services.AudioFallbackDriver.ReportOutputFailure(error)) fatal(error); });
    internal static IHostUIHandler CreateHostUi(Action<Exception> fatal) => OhosHostUi.Create();
}
