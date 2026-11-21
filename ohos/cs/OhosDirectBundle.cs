// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// OHOS copy of the Android s2a_direct_bundle_v1 export (android/cs/aot/AndroidDirectBundle.cs)
// without the unused S2A.Dsh alias. The legacy per-stage bundle path stays unimplemented: the shader
// survey reports it red and the draw-time compile_fn path is the only producer.
using System;
using System.Runtime.InteropServices;

namespace S2A.Android.Aot
{
    public static unsafe class OhosDirectBundle
    {
        [UnmanagedCallersOnly(EntryPoint = "s2a_direct_bundle_v1")]
        public static int Compile(byte* code, nuint codeLen, byte* ctl, nuint ctlLen, int stage, byte* outDir, int flags)
        {
            _ = code; _ = codeLen; _ = ctl; _ = ctlLen; _ = stage; _ = outDir; _ = flags;
            Console.Error.WriteLine("【红】直连补编：统一生产链待接（compile_fn 请求构造未实现，未写任何产物）");
            return 2;
        }
    }
}
