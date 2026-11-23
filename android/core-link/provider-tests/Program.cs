using S2A.Android.Aot;
using S2A.Services;
using System;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;

internal static unsafe class Program
{
    private const ulong ExpectedTick = 123456789;
    private const ulong SentinelTick = 987654321;
    private static int _checks;

    [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint = "dlopen")]
    private static extern nint Dlopen(string path, int flags);

    [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint = "dlclose")]
    private static extern int Dlclose(nint handle);

    private static void Check(bool value, string message)
    {
        _checks++;
        if (!value)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static nint Load(string path, bool global = false)
    {
        nint owner = Dlopen(path, 2 | (global ? 8 : 4)); // macOS NOW | GLOBAL/LOCAL.
        Check(owner != 0, "The real loader could not open " + path);
        return owner;
    }

    private static ulong Tick(nint owner)
    {
        var tick = (delegate* unmanaged<ulong>)NativeLibrary.GetExport(owner, "s2a_guest_tick");
        return tick();
    }

    private static nint[] Slots() =>
    [
        (nint)Native.HandleNew, (nint)Native.HandleGet, (nint)Native.HandleClose,
        (nint)Native.EventCreate, (nint)Native.EventSignal, (nint)Native.EventClear,
        (nint)Native.EventRelease, (nint)Native.EventDupRead, (nint)Native.EventRetain,
        (nint)Native.ShmemWrap, (nint)Native.TmemGet, (nint)Native.MemQuery,
        (nint)Native.MemMapped, (nint)Native.ProcessId, (nint)Native.ProgramId,
        (nint)Native.RegisterCs, (nint)Native.ScreenW, (nint)Native.ScreenH, (nint)Native.WidenGame,
        (nint)Native.WidenLayout, (nint)Native.WidenFull, (nint)Native.GfxMode, (nint)Native.BootMark,
        (nint)Native.GuestTick, (nint)Native.GuestTickHz, (nint)Native.DetMode, (nint)Native.DetHostWrite,
        (nint)Native.ClockUnseen, (nint)Native.ClockRegisterCatchup,   // 10-29 #863 补时两槽
        (nint)Native.HostFocused, (nint)Native.FocusSuspendSet, (nint)Native.ConsoleMode, (nint)Native.HostSleeping,   // 接口 v2.15 焦点 / 掌机主机 / 睡眠四槽（ad04aa664、31dc875e5）
        (nint)Native.GuestFrozen,   // 接口 v2.17 客机冻结槽（49db64562 #1489）
        (nint)Native.AppletOpenAdd,   // 接口 v2.18 系统小程序开着的个数（6032e66d9）
    ];

    private static uint OldHandleNew(uint kind, ulong cookie) => 88;
    private static int OldScreenW() => 99;
    private static int OldScreenH() => 98;

    // Existing injected pointers are allowed before startup. A failed candidate
    // must leave both nonzero and zero slots exactly as they were.
    private static void Seed(nint owner)
    {
        Native.HandleNew = &OldHandleNew;
        Native.ScreenW = &OldScreenW;
        Native.ScreenH = &OldScreenH;
        Native.GuestTick = (delegate* unmanaged<ulong>)NativeLibrary.GetExport(owner, "s2a_guest_tick");
        Native.DetMode = (delegate* unmanaged<int>)NativeLibrary.GetExport(owner, "s2a_det_mode");
        Native.DetHostWrite = (delegate* unmanaged<ulong, void*, ulong, void>)NativeLibrary.GetExport(owner, "s2a_det_host_write");
    }

    private static (int Failures, string Report) SelfTest()
    {
        byte* output = stackalloc byte[2048];
        delegate* unmanaged<byte*, int, int> run = &AndroidSelfTest.Run;
        int failures = run(output, 2048);
        string report = Marshal.PtrToStringUTF8((nint)output);
        Console.WriteLine(report);
        return (failures, report);
    }

    private static void AssertConsumer(nint owner, bool extras)
    {
        var result = SelfTest();
        Check(result.Failures == 0, "Production AndroidSelfTest failed.");
        Check(result.Report.Contains("s2a_screen_w=2400"), "Static import did not reach the provider.");
        Check(Native.ScreenH != null && Native.ScreenH() == 1440, "ScreenH did not reach the provider.");
        Check(result.Report.Contains("game_ready=false"), "Diagnostic selftest must not assert game readiness.");
        Check(result.Report.Contains(extras ? "clock=present; det=present; clock-catchup=present" : "clock=absent; det=absent; clock-catchup=absent"),
            "Diagnostic availability does not match the actual exports.");
        Check(extras ? Native.ClockUnseen != null && Native.ClockRegisterCatchup != null : Native.ClockUnseen == null && Native.ClockRegisterCatchup == null,
            "Clock catch-up exports must bind from the explicit owner exactly like the other optional exports.");
        var mark = (delegate* unmanaged<nint>)NativeLibrary.GetExport(owner, "fixture_last_mark");
        Check(Marshal.PtrToStringUTF8(mark()) == "cs-selftest", "The actual BootMark consumer did not run.");
        Check(Red.Total == 0, "Explicit diagnostic binding must not report absent optional exports as a core failure.");
        if (extras)
        {
            Check(NativeTickSource.Available && new NativeTickSource().Counter == ExpectedTick,
                "The actual NativeTickSource did not read the selected owner's clock.");
            Check(Native.DetMode != null && Native.DetHostWrite != null, "Full deterministic pair was not published.");
            int source = 41;
            int target = 0;
            Native.DetHostWrite((ulong)&target, &source, sizeof(int));
            Check(target == source && Native.DetMode() == 0, "Selected deterministic exports were not callable.");
        }
        else
        {
            Check(!NativeTickSource.Available && Native.GuestTick == null && Native.DetMode == null && Native.DetHostWrite == null,
                "Absent exports retained another owner's injected pointers.");
        }
    }

    private static void Reject(Action action, nint[] before)
    {
        bool rejected = false;
        try
        {
            action();
        }
        catch (ArgumentException)
        {
            rejected = true;
        }
        catch (InvalidOperationException)
        {
            rejected = true;
        }
        Check(rejected, "Invalid candidate was accepted.");
        Check(Slots().SequenceEqual(before), "Rejected candidate partially published the native table.");
    }

    private static void Main(string[] args)
    {
        Red.Strict = false;
        Check(typeof(Native).GetFields(BindingFlags.Public | BindingFlags.Static).Count(f => f.FieldType.IsFunctionPointer) == Slots().Length,
            "Slot preservation test must cover every public function pointer.");
        string scenario = args[0];
        nint other = args.Length > 2 ? Load(args[2], scenario == "consumer-sentinel") : 0;
        bool legacy = scenario.StartsWith("legacy-", StringComparison.Ordinal);
        nint owner = Load(args[1], legacy);
        nint main = NativeLibrary.GetMainProgramHandle();
        if (scenario == "consumer-sentinel")
        {
            Check(Tick(main) == SentinelTick, "Main-program negative control did not expose the wrong sentinel.");
            Check(Tick(owner) == ExpectedTick, "Explicit owner must expose a different real symbol.");
        }
        else if (!legacy)
        {
            Check(!NativeLibrary.TryGetExport(main, "s2a_guest_tick", out _),
                "Negative control requires the owner to be invisible to the main handle.");
        }

        // JIT substitute only for NativeAOT's static s2a_native DirectPInvoke
        // imports; GetExport/NativeLibrary.Load still use the real OS loader.
        NativeLibrary.SetDllImportResolver(Assembly.GetExecutingAssembly(),
            (name, assembly, searchPath) => name == "s2a_native" ? owner : 0);

        if (scenario.Contains("empty") || scenario.Contains("half"))
        {
            Seed(other);
        }

        if (legacy)
        {
            Native.UseLinked();
            Check(Native.ScreenW() == 2400 && Native.ScreenH() == 1440, "Legacy static imports failed.");
            bool empty = scenario == "legacy-empty";
            bool half = scenario.Contains("half");
            Check(NativeTickSource.Available == !empty, "Legacy clock availability changed.");
            Check(Red.Total == (empty ? 2 : 0), "Legacy missing-clock diagnostic changed.");   // 全缺：guest tick（v2.8）与补时（v2.14）两条独立报红
            if (!empty)
            {
                Check(new NativeTickSource().Counter == ExpectedTick, "Legacy clock did not come from main.");
            }
            Check((Native.DetMode != null && Native.DetHostWrite != null) == !(empty || half),
                "Legacy partial deterministic pair must stay wholly absent.");
            Check(!(empty || half) || (Native.DetMode == null && Native.DetHostWrite == null),
                "Legacy partial pair retained an injected pointer.");
            var before = Slots();
            Native.UseLinked();
            Check(Slots().SequenceEqual(before), "Legacy repeat changed the bound table.");
        }
        else if (scenario.Contains("half"))
        {
            var before = Slots();
            var result = SelfTest();
            Check(result.Failures == 1 && result.Report.StartsWith("FAILED InvalidOperationException", StringComparison.Ordinal)
                && result.Report.Contains("s2a_det_mode / s2a_det_host_write"),
                "Production consumer did not reject the partial deterministic pair at its admission check.");
            Check(Slots().SequenceEqual(before), "Failed selftest partially published the native slots.");
            Native.UseLinked(other); // A failed candidate must not latch its owner.
            Check(NativeTickSource.Available && new NativeTickSource().Counter == ExpectedTick,
                "A rejected candidate prevented a later valid startup binding.");
        }
        else
        {
            AssertConsumer(owner, scenario != "consumer-empty");
            var before = Slots();
            Native.UseLinked(owner);
            Check(Slots().SequenceEqual(before), "Same-owner binding must be idempotent.");
            if (scenario == "consumer-repeat")
            {
                // Release only the fixture's own reference. Production retains
                // its separately acquired Lazy owner; it never unloads that DSO.
                Check(Dlclose(owner) == 0, "Could not drop the fixture's extra reference.");
                AssertConsumer(owner, true);
                Check(Slots().SequenceEqual(before), "Repeated actual selftest changed pointers.");
            }
            Reject(() => Native.UseLinked(0), before);
            Reject(() => Native.UseLinked(), before);
            if (other != 0)
            {
                Reject(() => Native.UseLinked(other), before);
            }
        }
        Console.WriteLine($"PASS {scenario}: {_checks} assertions (host loader/managed consumers only)");
    }
}
