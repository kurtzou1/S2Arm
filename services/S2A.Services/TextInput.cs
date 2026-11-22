using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Applets.SoftwareKeyboard;
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;

namespace S2A.Services
{
    // 系统键盘桥接（11-06 出包速度线，质量线定因 GRID 输入车手名不弹键盘）：游戏的软键盘（前台小程序 / 内嵌键盘）→ 苹果宿主自己的输入框
    //   （iOS ios/textinput.m：UIAlertController + 系统键盘，可用中文输入法；Mac macos/textinput_mac.m：NSAlert 挂游戏窗口）。
    //   异步：小程序只发起、不等（Ryujinx IAsyncTextInput），游戏 / 服务线程任何时候都不等玩家；原生在主线程画框，回调转线程池再交回小程序。
    //   原生 C 接口（runtime/include/s2a_text_input.h）：
    //     int s2a_host_text_input(int64 id, const char *json, cb)：1 = 已弹出（之后 cb 恰好一次）；0 = 不交互（无人值守局 S2A_AUTOPLAY / 没有界面）→ 退回自动应答
    //     void s2a_host_text_input_cancel(int64 id)：收起（游戏关键盘 / 会话停）；已答过的忽略
    //     cb(int64 id, int status, const char *utf8)：status 1 = 确定（utf8 = 玩家输入），0 = 取消（utf8 = NULL）；在原生主线程调
    //   原生导出在公用核心 runtime/src/text_input.c（Native.cs Imports 直连），平台没登记输入框（安卓 / 开发宿主）回 0 → 退回自动应答（HostUi.DisplayInputDialog）。开着期间输入泵把实体手柄 / 触屏手柄输入清零（InputPump，防误触）
    internal static unsafe class TextInput
    {
        // 单测替身：设了就代替原生（返回同 s2a_host_text_input）
        internal static Func<long, string, int> BeginHook;
        internal static Action<long> CancelHook;

        private static readonly ConcurrentDictionary<long, Action<bool, string>> Pending = new();
        private static long _nextId;

        // 正有输入框开着（输入泵据此清零手柄输入）
        internal static bool Open => !Pending.IsEmpty;

        internal static IDisposable Begin(SoftwareKeyboardUIArgs args, Action<bool, string> done)
        {
            long id = Interlocked.Increment(ref _nextId);
            string json = Json(args);
            Pending[id] = done;   // 先登记再发起：原生回调可能在发起返回前就到
            int rc;
            try { rc = BeginHook != null ? BeginHook(id, json) : NativeBegin(id, json); }
            catch { Pending.TryRemove(id, out _); throw; }   // 发起失败不留登记（否则开框标记一直立着，输入泵一直静音手柄）
            if (rc != 1)
            {
                Pending.TryRemove(id, out _);
                return null;
            }

            Console.Error.WriteLine($"S2A 系统键盘：弹出（#{id}，模式 {args.KeyboardMode}，长度 {args.StringLengthMin}–{args.StringLengthMax}，标题「{args.HeaderText}」）");
            return new Handle(id);
        }

        // 原生回调入口（主线程）：拷出文本、转线程池交回，主线程不碰小程序的锁
        internal static void Answer(long id, bool ok, string text)
        {
            if (!Pending.TryRemove(id, out Action<bool, string> done)) return;   // 已收起 / 已答过
            Console.Error.WriteLine($"S2A 系统键盘：{(ok ? "确定" : "取消")}（#{id}，{text?.Length ?? 0} 字）");
            ThreadPool.QueueUserWorkItem(_ => done(ok, ok ? text ?? string.Empty : null));
        }

        // 会话停 / 重启：还开着的一律按取消交回（原生同时收框）
        internal static void CancelAll()
        {
            foreach (long id in Pending.Keys) Cancel(id);
        }

        private static void Cancel(long id)
        {
            if (!Pending.ContainsKey(id)) return;
            if (CancelHook != null) CancelHook(id); else NativeCancel(id);
            Answer(id, false, null);
        }

        private sealed class Handle(long id) : IDisposable
        {
            public void Dispose() => Cancel(id);
        }

        internal static string Json(SoftwareKeyboardUIArgs a)
        {
            using MemoryStream m = new();
            using (Utf8JsonWriter w = new(m))
            {
                w.WriteStartObject();
                if (a.LocalPlayerNames != null)
                {
                    w.WriteStartArray("localPlayers");
                    foreach (string name in a.LocalPlayerNames) w.WriteStringValue(name);
                    w.WriteEndArray();
                }
                w.WriteString("header", a.HeaderText ?? "");
                w.WriteString("subtitle", a.SubtitleText ?? "");
                w.WriteString("guide", a.GuideText ?? "");
                w.WriteString("initial", a.InitialText ?? "");
                w.WriteString("submit", a.SubmitText ?? "");
                // 键盘种类（Switch KeyboardMode）：numeric = 数字键盘；ascii = 只收半角；full = 系统键盘（含中文等输入法）
                w.WriteString("mode", a.KeyboardMode switch { KeyboardMode.Numeric => "numeric", KeyboardMode.ASCII => "ascii", _ => "full" });
                w.WriteNumber("min", Math.Max(0, a.StringLengthMin));
                w.WriteNumber("max", Math.Max(0, a.StringLengthMax));
                w.WriteEndObject();
            }
            return Encoding.UTF8.GetString(m.ToArray());
        }

        private static int NativeBegin(long id, string json)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(json + "\0");
            fixed (byte* p = bytes) return Native.Imports.s2a_host_text_input(id, p, &Callback);
        }

        private static void NativeCancel(long id) => Native.Imports.s2a_host_text_input_cancel(id);

        [UnmanagedCallersOnly]
        private static void Callback(long id, int status, byte* utf8)
        {
            try { Answer(id, status == 1, utf8 == null ? null : Marshal.PtrToStringUTF8((nint)utf8)); }
            catch (Exception e) { Console.Error.WriteLine($"S2A 系统键盘回调异常：{e}"); }
        }
    }
}
