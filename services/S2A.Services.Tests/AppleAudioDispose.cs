using Ryujinx.Audio.Backends.Apple;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Memory;
using System;
using System.Collections.Generic;
using System.Diagnostics.CodeAnalysis;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        [DynamicDependency(DynamicallyAccessedMemberTypes.NonPublicFields,
            "Ryujinx.Audio.Backends.Apple.ApplePullHardwareDeviceSession", "Ryujinx.Audio.Backends.Apple")]   // 平台例外：测试点名 Apple 后端类型（#2157）
        internal static int AppleAudioDispose()
        {
            try
            {
                // 判「有没有方法是现编的」：PublishAot 工程用 dotnet run 走 JIT 时，IsDynamicCodeSupported / IsDynamicCodeCompiled 都被功能开关置成 false，拦不住；
                //   JIT 下事件句柄不是 GCHandle 槽，下面的复用永远对不上，只会报「没有覆盖句柄槽复用」误导人。要 dotnet publish -r osx-arm64 后跑产物
                if (System.Runtime.JitInfo.GetCompiledMethodCount() > 0)
                    throw new InvalidOperationException("本回归必须运行NativeAOT产物（dotnet publish -r osx-arm64 后执行），才能覆盖Unix WaitSubsystem的GCHandle复用");
                if (!AppleHardwareDeviceDriver.IsSupported)
                    throw new InvalidOperationException("真实Apple音频后端不可用");
                for (int round = 1; round <= 10; round++)
                {
                    using MemoryBlock backing = new(0x1000);
                    var memory = new Ryujinx.Cpu.Jit.MemoryManager(backing, 0x1000);
                    memory.IncrementReferenceCount();
                    try
                    {
                        AppleHardwareDeviceDriver driver = new();
                        IHardwareDeviceSession session = driver.OpenDeviceSession(
                            IHardwareDeviceDriver.Direction.Output, memory, SampleFormat.PcmInt16, 48000, 2);
                        FieldInfo handleField = session.GetType().GetField("_gcHandle", BindingFlags.NonPublic | BindingFlags.Instance)
                            ?? throw new InvalidOperationException("找不到实际音频回调GCHandle");
                        nint original = GCHandle.ToIntPtr((GCHandle)handleField.GetValue(session));
                        if (original == 0) throw new InvalidOperationException("真实音频会话未持有回调句柄");
                        session.Dispose();

                        // Only ordinary event construction reuses the released slot.
                        // No GCHandle is manually freed, forged or reassigned here.
                        List<AutoResetEvent> events = [];
                        AutoResetEvent reused = null;
                        for (int i = 0; i < 8192; i++)
                        {
                            AutoResetEvent candidate = new(true);
                            events.Add(candidate);
                            if (candidate.SafeWaitHandle.DangerousGetHandle() == original)
                            {
                                reused = candidate;
                                break;
                            }
                        }
                        if (reused == null)
                            throw new InvalidOperationException($"第{round}轮没有覆盖实际句柄槽复用，不能记通过");

                        session.Dispose();
                        driver.Dispose();
                        session.Dispose();
                        driver.Dispose();
                        if (!reused.WaitOne(0) || reused.WaitOne(0))
                            throw new InvalidOperationException($"第{round}轮复用槽的AutoResetEvent初始信号被旧会话破坏");
                        reused.Set();
                        if (!reused.WaitOne(0) || reused.WaitOne(0))
                            throw new InvalidOperationException($"第{round}轮AutoResetEvent已失去自动复位语义");
                        if (((GCHandle)handleField.GetValue(session)).IsAllocated)
                            throw new InvalidOperationException($"第{round}轮音频会话仍持已释放句柄");
                        GC.Collect();
                        GC.WaitForPendingFinalizers();
                        reused.Set();
                        if (!reused.WaitOne(0) || reused.WaitOne(0))
                            throw new InvalidOperationException($"第{round}轮GC后事件语义被旧句柄释放破坏");
                        foreach (AutoResetEvent evnt in events) evnt.Dispose();
                        Console.WriteLine($"真实Apple音频Dispose {round}/10：拉取会话建/关，旧槽由AutoResetEvent复用，重复session/driver Dispose及GC后信号均正确；事件数{events.Count}");
                    }
                    finally { memory.DecrementReferenceCount(); }
                }
                Console.WriteLine("PASS：NativeAOT真实Apple音频会话重复Dispose与事件句柄复用10轮；未加载游戏或用户数据");
                return 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(error);
                // A failed baseline may already have invalidated another object's
                // handle. Do not dispose that corrupted handle a second time.
                return 1;
            }
        }
    }
}
