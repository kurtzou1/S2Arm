// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 鸿蒙专用的游戏运行时组合：取自 2026-10-31 快照里经 Mate90 真机验证的 AndroidGameRuntime.cs。
// 上游 main 的同名安卓文件已直接依赖 AAudio / AndroidHostUi / 安卓专有原生钩子（不再走 RuntimePlatform 接缝），
// 鸿蒙暂不编它；待把这些依赖收回平台接缝后再与上游合流（见 S2Arm-Harmony 移植计划）。
using Ryujinx.Audio.Integration;
using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.SystemState;
using Ryujinx.Memory;
using S2A.Services;
using S2Arm.Backends.Vulkan.Runtime;
using System;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

namespace S2A.Android.Aot
{
    // Called by the native game composition only after its real module/memory
    // initialization. Diagnostic self-tests do not call this entry.
    public static unsafe class AndroidGameRuntime
    {
        private static readonly AndroidServiceState State = new();
        private static AndroidHostApi _host;
        private static AndroidVulkanRuntime _gpu;
        private static DirectSession _direct;   // 非空 = 本局走 native direct（不建 generic GPU）
        private static DirectOwnerLoop _directOwner; // F4.4：provider.poll 的 managed 调用者
        private static DirectRenderer _directRenderer;
        private static readonly object CleanupLock = new();
        private static bool _cleanupDone;
        private static Exception _cleanupFailure;
        private static int _stopSent;
        [ThreadStatic] private static ulong _attachedSession;
        [ThreadStatic] private static int _attachedThreadId;

        // v2: the only direct entry (shared with Android, same validation). Generic stays equal to v1
        // (empty graphics table, mode 0). Direct binds the compiler, activates the native session and
        // never degrades silently to generic; a rejected direct start returns Provider/Argument.
        [UnmanagedCallersOnly(EntryPoint = "s2a_android_services_start_v2")]
        public static int StartV2(DirectServicesRequestV2* request, AndroidServicesStatus* result)
        {
            if (!OutputValid(result)) return (int)ServiceError.Argument;
            if (request == null || request->Size < DirectAbi.ServicesRequestV2Size)
                return Write(result, ServiceError.Argument);
            if (request->Version != 2) return Write(result, ServiceError.Version);
            if (request->Flags != 0 || request->GraphicsMode > (uint)GraphicsMode.Direct)
                return Write(result, ServiceError.Argument);
            if (request->GraphicsMode == (uint)GraphicsMode.Generic && request->Graphics != 0)
                return Write(result, ServiceError.Argument);
            if (request->Session == 0 || request->NativeOwner == 0 || request->HostApi == 0 ||
                request->LeaseApi == 0 || request->ConsoleMode > 1 || request->Reserved != 0)
                return Write(result, ServiceError.Argument);
            AndroidServicesRequest v1 = V1Request(request);
            if (request->GraphicsMode != (uint)GraphicsMode.Direct) return StartCore(&v1, result, null);
            if (request->Graphics == 0) return Write(result, ServiceError.Argument);
            DirectApiV1 table = *(DirectApiV1*)request->Graphics;
            int check = DirectAbi.TableCheck(table);
            if (check != DirectAbi.Ok)
            {
                Console.Error.WriteLine($"[s2a] direct services rejected: table check {check} (size={table.Size} version={table.Version})");
                return Write(result, check == DirectAbi.VersionMismatch ? ServiceError.Version : ServiceError.Argument);
            }
            if (table.Session != request->Session)
            {
                Console.Error.WriteLine($"[s2a] direct services rejected: table session {table.Session} != request {request->Session}");
                return Write(result, ServiceError.Argument);
            }
            DirectSession session;
            try { session = new DirectSession(in table); }
            catch (ArgumentException error)
            {
                Console.Error.WriteLine($"[s2a] direct services rejected: {error.Message}");
                return Write(result, ServiceError.Argument);
            }
            nint compile = (nint)(delegate* unmanaged<ulong, ulong, DirectBytes, nint, nint, int>)&DirectCompileNative.Compile;
            int bind = session.BindCompiler(compile);
            if (bind != DirectAbi.Ok)
            {
                Console.Error.WriteLine($"[s2a] direct services rejected: compiler bind failed ({bind})");
                session.Destroy();
                return Write(result, bind == DirectAbi.Unsupported ? ServiceError.Provider : ServiceError.Argument);
            }
            int activate = session.Activate();
            if (activate != DirectAbi.Ok)
            {
                Console.Error.WriteLine($"[s2a] direct services rejected: activate failed ({activate})");
                session.RequestStop();
                session.Destroy();
                return Write(result, ServiceError.Provider);
            }
            Console.Error.WriteLine("[s2a] direct session active: compiler bound, engine activated");
            if (session.Query(out DirectStatusV1 directStatus) == DirectAbi.Ok)
                Console.Error.WriteLine($"[s2a] direct session status: state={directStatus.State} blockers={directStatus.Blockers} error={directStatus.Error}");
            return StartCore(&v1, result, session);
        }

        private static AndroidServicesRequest V1Request(DirectServicesRequestV2* request)
        {
            AndroidServicesRequest v1 = default;
            v1.Size = (uint)sizeof(AndroidServicesRequest);
            v1.Version = 1;
            v1.Session = request->Session;
            v1.NativeOwner = request->NativeOwner;
            v1.HostApi = request->HostApi;
            v1.GameDataDirectory = request->GameDataDirectory;
            v1.StateDirectory = request->StateDirectory;
            v1.LeaseApi = request->LeaseApi;
            v1.ConsoleMode = request->ConsoleMode;
            v1.Reserved = 0;
            return v1;
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_android_services_start")]
        public static int Start(AndroidServicesRequest* request, AndroidServicesStatus* result)
            => StartCore(request, result, null);

        // direct != null: graphics belong to the native NVN frontend + Vulkan backend; no managed GPU owner.
        private static int StartCore(AndroidServicesRequest* request, AndroidServicesStatus* result, DirectSession direct)
        {
            _direct = direct;
            if (!OutputValid(result)) return (int)ServiceError.Argument;
            if (request == null || request->Size < sizeof(AndroidServicesRequest))
                return Write(result, ServiceError.Argument);
            if (request->Version != 1) return Write(result, ServiceError.Version);
            if (request->Session == 0 || request->NativeOwner == 0 || request->HostApi == 0 ||
                request->LeaseApi == 0 || request->ConsoleMode > 1 || request->Reserved != 0)
                return Write(result, ServiceError.Argument);
            ServiceError begin = State.Begin(request->Session);
            if (begin != ServiceError.Ok) return Write(result, begin);
            Exports.CancelWaitsHandler = RequestServiceCancellation;

            ServiceError stage = ServiceError.Host;
            try
            {
                // Native has already bound fd 1/2 to this session's private log.
                // Console may retain handles cached before that dup2; replace
                // its writers before any HostApi/provider/GPU consumer logs.
                Console.SetOut(new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true });
                Console.SetError(new StreamWriter(Console.OpenStandardError()) { AutoFlush = true });
                _host = new AndroidHostApi(request->HostApi, request->ConsoleMode);
                string game = AndroidHostApi.ReadPath(request->GameDataDirectory);
                string state = AndroidHostApi.ReadPath(request->StateDirectory);
                // 鸿蒙应用进程没有 HOME（安卓系统会给），UserProfile 为空串时 Ryujinx 日志类静态构造
                // Directory.GetParent("") 抛异常、服务起不来。.NET 启动时就快照了环境，只能在托管侧补：设成本局状态目录（应用沙箱内）。
                if (string.IsNullOrEmpty(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)))
                    Environment.SetEnvironmentVariable("HOME", state);
                var configuration = new HostConfiguration(game, state,
                    SystemLocale.Map(_host.Language) ?? SystemLanguage.AmericanEnglish,
                    Region(_host.Region), _host.TimeZone, request->ConsoleMode == 1,
                    RuntimePlatform.CreateHostUi(error => Fatal(ServiceError.Host, error)),
                    MemoryBlock.ReserveShared);
                EnsureStarting();

                stage = ServiceError.Provider;
                Native.UseLinked(request->NativeOwner);
                // UseLinked also serves diagnostics, where all optional exports
                // may be absent. A game requires this complete owner group before
                // constructing the GPU/HLE composition.
                if (Native.GuestTick == null || Native.DetMode == null || Native.DetHostWrite == null)
                    throw new InvalidOperationException("Game provider lacks its clock or deterministic memory exports");
                // 直连不建 GPU，震动库句柄要在这里接上，否则直连游戏全部没有手机震动。
                S2A.Services.InputPump.FeedbackLibraryHandle = RuntimePlatform.LibraryHandle;
                stage = ServiceError.Gpu;
                if (direct == null)
                {
                    // 2026-11-09 起鸿蒙只走直连（与上游 11-07 删通用模式一致）：没有直连图形库就报红，不退回通用渲染器。
                    throw new NotSupportedException("鸿蒙只支持直连图形模式：这个游戏包没有直连图形库，请用新版出包工具重新出包");
                }
                else
                {
                    // direct：guest 的图形走 native 的 NVN 前端与 d2r 引擎，托管侧不许再建一套 GPU。
                    // HLE 在 Initialize 里会真的构造渲染器，所以给一个"什么都不画"的 direct 渲染器：
                    // 真正要建 GPU 资源/出图的成员一律抛 NotSupportedException（带成员名），不静默成功。
                    // F4.4：owner 控制循环从此刻起实际调用 provider.poll；起不来就按 Provider 失败收局，
                    // 不留一个“没有控制调用者”的 direct 会话。
                    _directOwner = new DirectOwnerLoop();
                    int ownerRc = _directOwner.Start(direct, OnDirectOwnerFailure);
                    if (ownerRc != DirectAbi.Ok)
                        throw new InvalidOperationException($"direct owner control loop failed to start ({ownerRc})");
                    Console.Error.WriteLine("[s2a] direct owner loop started: provider.poll is driven by the managed owner");
                    Exports.RendererFactory = () => _directRenderer ??= new DirectRenderer();
                    Exports.AfterBoot = static (_, _) => { };
                    Console.Error.WriteLine("[s2a] direct composition: managed GPU disabled, guest graphics go through the native direct table");
                }
                Exports.BeforeShutdown = StopGpu;
                Exports.ShutdownHandler = ShutdownFromNative;
                Exports.ServiceFailure = OnServiceFailure;
                Exports.AudioFactory = &CreateAudio;
                InputPump.InputHook = &ReadInput;

                stage = ServiceError.Initialize;
                EnsureStarting();
                Exports.Initialize(configuration);
                _gpu?.ThrowIfFailed();
                ServiceError complete = State.Complete();
                if (complete != ServiceError.Ok) throw new OperationCanceledException("Session stopped or failed during initialization");
                return Write(result, ServiceError.Ok);
            }
            catch (Exception error)
            {
                if (State.Snapshot().State != (uint)ServiceState.StopRequested) State.Fail(stage);
                Console.Error.WriteLine($"Android services start failed (stage={stage}, error={(int)stage}): " + error);
                NotifyHostStop(3, "Android service initialization failed");
                // No guest was released by this entry. Stop the objects actually
                // created; GPU failure retains its resources for process teardown.
                try { Cleanup(); }
                catch (Exception cleanup)
                {
                    State.Fail(ServiceError.Cleanup);
                    Console.Error.WriteLine("Android services cleanup requires process teardown: " + cleanup);
                }
                return Write(result, (ServiceError)State.Snapshot().Error);
            }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_android_services_status")]
        public static int Status(ulong session, AndroidServicesStatus* result)
        {
            if (!OutputValid(result)) return (int)ServiceError.Argument;
            AndroidServicesStatus snapshot = State.Snapshot();
            if (session == 0 || snapshot.Session != session) return Write(result, ServiceError.Argument);
            *result = snapshot;
            return 0;
        }

        // Native must call this directly on each real guest pthread, after its
        // xstack setup and before that same thread's final native fault probe.
        // Returning success proves managed attachment/service state only; the
        // native owner still arbitrates stop and the final guest admission.
        [UnmanagedCallersOnly(EntryPoint = "s2a_android_services_attach_thread")]
        public static int AttachThread(ulong session, AndroidServicesStatus* result)
        {
            if (!OutputValid(result)) return (int)ServiceError.Argument;
            ServiceError ready = ThreadReady(session, out AndroidServicesStatus snapshot);
            if (ready != ServiceError.Ok)
            {
                *result = snapshot;
                return (int)ready;
            }
            try
            {
                AttachCurrentThread(session);
                ready = ThreadReady(session, out snapshot);
                *result = snapshot;
                return (int)ready;
            }
            catch (Exception error)
            {
                Fatal(ServiceError.Initialize, error);
                return Write(result, (ServiceError)State.Snapshot().Error);
            }
        }

        private static ServiceError ThreadReady(ulong session, out AndroidServicesStatus snapshot)
        {
            snapshot = State.Snapshot();
            if (session == 0 || snapshot.Session != session) return ServiceError.Argument;
            if (snapshot.Error != 0) return (ServiceError)snapshot.Error;
            if (snapshot.State != (uint)ServiceState.Ready) return ServiceError.Initialize;
            return ServiceError.Ok;
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static void AttachCurrentThread(ulong session)
        {
            // The reverse P/Invoke prologue attaches this native thread. Force
            // actual managed thread and execution-stack access on that thread;
            // another initialization worker cannot satisfy these checks for it.
            int thread = Thread.CurrentThread.ManagedThreadId;
            RuntimeHelpers.EnsureSufficientExecutionStack();
            if (thread <= 0 || (_attachedSession != 0 &&
                (_attachedSession != session || _attachedThreadId != thread)))
                throw new InvalidOperationException("Managed guest thread belongs to a different session or thread");
            _attachedSession = session;
            _attachedThreadId = thread;
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_android_services_request_stop")]
        public static int RequestStop(ulong session, AndroidServicesStatus* result)
        {
            if (!OutputValid(result)) return (int)ServiceError.Argument;
            ServiceError error = State.RequestStop(session);
            if (error == ServiceError.Ok && State.Snapshot().State != (uint)ServiceState.Stopped)
            {
                NotifyHostStop(0, "Android session stop requested");
                RequestServiceCancellation();
            }
            return Write(result, error); // Request only. Native owns guest quiescence.
        }

        private static bool OutputValid(AndroidServicesStatus* result) =>
            result != null && result->Size >= sizeof(AndroidServicesStatus) && result->Version == 1;

        private static void EnsureStarting()
        {
            if (State.Snapshot().State != (uint)ServiceState.Starting)
                throw new OperationCanceledException("Session stopped or failed before service initialization");
        }

        private static int Write(AndroidServicesStatus* result, ServiceError error)
        {
            *result = State.Snapshot();
            return (int)error;
        }

        private static IHardwareDeviceDriver CreateAudio() => RuntimePlatform.CreateAudio(error => Fatal(ServiceError.Initialize, error));

        private static void ReadInput(ref GamepadInput input)
        {
            try
            {
                AndroidHostApi.InputState state = _host.ReadInput();
                input.Buttons = (ControllerKeys)state.Buttons;
                input.LStick.Dx = state.LeftX; input.LStick.Dy = state.LeftY;
                input.RStick.Dx = state.RightX; input.RStick.Dy = state.RightY;
            }
            catch (Exception error)
            {
                Fatal(ServiceError.Host, error);
                InputPump.Stop(); // On its own thread: prevents further invalid snapshots.
            }
        }

        private static void Fatal(ServiceError code, Exception error)
        {
            State.Fail(code);
            Console.Error.WriteLine("Android session failed: " + error);
            NotifyHostStop(3, "Android runtime dependency failed");
            RequestServiceCancellation();
        }

        private static void OnServiceFailure(Exception error) => Fatal(ServiceError.Initialize, error);

        // owner 循环的 poll 失败（Retirement/Driver/…）：按 GPU 阶段失败走同一条既有路径，
        // 只通知一次 HostApi stop 并请求取消；不在这里同步销毁 native 会话（StopGpu 统一收尾）。
        private static void OnDirectOwnerFailure(int code, string message)
        {
            Fatal(ServiceError.Gpu, new InvalidOperationException(message));
        }

        private static void NotifyHostStop(uint reason, string message)
        {
            AndroidHostApi host = Volatile.Read(ref _host);
            if (host != null && Interlocked.CompareExchange(ref _stopSent, 1, 0) == 0)
                host.RequestStop(reason, message);
        }

        private static void RequestServiceCancellation()
        {
            if (State.Snapshot().State == (uint)ServiceState.Stopped) return;
            try { Ryujinx.Common.S2AShutdown.Request(); }
            catch (Exception error)
            {
                // A service wake callback may fail. Still notify the native owner;
                // never let that managed exception cross the unmanaged stop entry.
                State.Fail(ServiceError.Cleanup);
                NotifyHostStop(3, "Android service cancellation failed");
                Console.Error.WriteLine("Android service cancellation failed: " + error);
            }
        }

        private static void StopGpu()
        {
            try { _gpu?.Stop(); }
            catch (Exception error) { Fatal(ServiceError.Cleanup, error); throw; }
            // direct：先让 HLE/guest 停下来，再按契约 request_stop → owner 控制轮询 → destroy 收掉 native 会话。
            if (_direct != null)
            {
                int stop = _direct.RequestStop();
                // F4.4：owner 循环是 provider.poll 的唯一调用者，必须带预算收尾。退出不了（例如驱动
                // 调用卡住）就不能销毁它仍可能进入的 native context：保留上下文/设备，如实报红。
                bool ownerStopped = _directOwner == null || _directOwner.Stop(DirectOwnerLoop.DefaultStopBudgetMs);
                // Stop 失败（Retirement/Driver/…）不解散 native 会话：请求 native 保留上下文/device，
                // 进程退出回收。只有 Stop 明确成功且 owner 循环确实退出，才允许 Destroy。
                int destroy = DirectAbi.Stopped;
                if (stop == DirectAbi.Ok && ownerStopped) destroy = _direct.Destroy();
                long slices = _directOwner?.Slices ?? 0;
                long pending = _directOwner?.PendingSlices ?? 0;
                Console.Error.WriteLine(
                    $"[s2a] direct session closed: stop={stop} destroy={destroy} ownerSlices={slices} ownerPending={pending}");
                if (!ownerStopped)
                    Console.Error.WriteLine(
                        "【红】direct owner loop did not stop within its budget; native session/destroy retained (process teardown)");
                if (stop != DirectAbi.Ok)
                    Console.Error.WriteLine(
                        "【红】direct stop did not prove completion; native context retained, no normal-stop claim");
                _directOwner = null;
                _direct = null;
            }
        }

        private static void ShutdownFromNative()
        {
            State.RequestStop(State.Snapshot().Session);
            try
            {
                Cleanup();
                State.CleanupComplete();
            }
            catch (Exception error) { Fatal(ServiceError.Cleanup, error); }
        }

        private static void Cleanup()
        {
            lock (CleanupLock)
            {
                if (_cleanupFailure != null)
                    throw new InvalidOperationException("Prior cleanup failed; process teardown is required", _cleanupFailure);
                if (_cleanupDone) return;
                try
                {
                    Ryujinx.Common.S2AShutdown.Request();
                    InputPump.Stop();
                    StopGpu(); // If this cannot quiesce, keep HLE memory and owner alive.
                    Host.Device?.Dispose();
                    _cleanupDone = true;
                }
                catch (Exception error)
                {
                    _cleanupFailure = error;
                    throw;
                }
            }
        }

        private static RegionCode Region(string country) => country switch
        {
            "JP" => RegionCode.Japan,
            "CN" => RegionCode.China,
            "KR" => RegionCode.Korea,
            "TW" or "HK" or "MO" => RegionCode.Taiwan,
            "AU" or "NZ" => RegionCode.Australia,
            "AT" or "BE" or "BG" or "CH" or "CY" or "CZ" or "DE" or "DK" or "EE" or "ES" or
            "FI" or "FR" or "GB" or "GR" or "HR" or "HU" or "IE" or "IS" or "IT" or "LI" or
            "LT" or "LU" or "LV" or "MT" or "NL" or "NO" or "PL" or "PT" or "RO" or "SE" or
            "SI" or "SK" => RegionCode.Europe,
            _ => RegionCode.USA, // BootSpec permits an absent region; shared default remains USA.
        };
    }
}
