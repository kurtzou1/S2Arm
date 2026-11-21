// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Applets.SoftwareKeyboard;
using S2A.Android.Aot;
using S2A.Services;
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;

internal static class Program
{
    private static int _assertions;
    private static int _cases;
    private static void Check(bool condition, string message)
    {
        _assertions++;
        if (!condition) throw new Exception(message);
    }

    private static T Throws<T>(Action action) where T : Exception
    {
        _assertions++;
        try { action(); }
        catch (T error) { return error; }
        throw new Exception("Expected " + typeof(T).Name);
    }

    private static SoftwareKeyboardUIArgs Args(KeyboardMode mode = KeyboardMode.Default, int min = 0, int max = 1000) =>
        new() { KeyboardMode = mode, StringLengthMin = min, StringLengthMax = max };

    private static byte[] Reply(bool accepted, string text) => JsonSerializer.SerializeToUtf8Bytes(new { version = 1, type = "keyboard", accepted, text });

    private sealed class FakeTransport : IOhosKeyboardTransport
    {
        internal long Now;
        internal byte[] Request;
        internal byte[] Answer = Reply(true, "测试");
        internal int BeginError, WaitError, CancelError, PendingCount, BeginCount, CancelCount;
        internal ulong Id = 42;
        internal long AdvanceOnReply;
        internal bool ThrowWait, OmitNul;
        internal nuint? SuccessfulLength;
        internal readonly Queue<nuint> ForcedRanges = new();
        internal readonly List<int> Timeouts = new();
        internal readonly List<int> Capacities = new();
        internal OhosKeyboard Keyboard(int timeout = 120000) => new(this, () => Now, timeout);
        public int Begin(ReadOnlySpan<byte> request, out ulong id)
        {
            BeginCount++;
            Request = request.ToArray();
            id = Id;
            return BeginError;
        }
        public int Wait(ulong id, int timeoutMilliseconds, Span<byte> reply, out nuint length)
        {
            Check(id == Id, "request id must be retained");
            Check(timeoutMilliseconds > 0 && timeoutMilliseconds <= 250, "bounded native wait");
            Timeouts.Add(timeoutMilliseconds);
            Capacities.Add(reply.Length);
            length = 0;
            if (ThrowWait) throw new IOException("Synthetic transport failure");
            if (PendingCount-- > 0) { Now += timeoutMilliseconds; return -6; }
            if (WaitError != 0) return WaitError;
            if (ForcedRanges.Count > 0) { length = ForcedRanges.Dequeue(); return -3; }
            if (Answer.Length + 1 > reply.Length) { length = (nuint)Answer.Length + 1; return -3; }
            Answer.CopyTo(reply);
            if (!OmitNul) reply[Answer.Length] = 0;
            length = SuccessfulLength ?? (nuint)Answer.Length;
            Now += AdvanceOnReply;
            return 0;
        }
        public int Cancel(ulong id)
        {
            Check(id == Id && id != 0, "cleanup id");
            CancelCount++;
            return CancelError;
        }
    }

    private static void Case(string name, Action test)
    {
        test();
        _cases++;
        Console.WriteLine("PASS " + name);
    }

    private static void RejectReply(string wire, SoftwareKeyboardUIArgs? args = null)
    {
        var transport = new FakeTransport { Answer = Encoding.UTF8.GetBytes(wire) };
        Throws<InvalidDataException>(() => transport.Keyboard().Display(args ?? Args(), out _));
        Check(transport.CancelCount == 1, "invalid reply must release request");
    }

    public static int Main()
    {
        // 真 Red.cs：严格模式（S2A_STRICT=1）首次报红会 FailFast，本单测要数报红次数，关掉；日志行收进来核对不带输入内容
        Red.Strict = false;
        var redLines = new List<string>();
        Red.Log = line => redLines.Add(line);
        try
        {
            Case("host-ui-real-cancel-and-no-content-in-error", () =>
            {
                // 放在最前：这里是本进程第一次报红，Red 一定打日志行（之后按 2^n 次才打），才能核日志不带输入内容
                long before = Red.Total;
                var transport = new FakeTransport { Answer = Reply(false, "") };
                var ui = OhosHostUi.Create(transport.Keyboard());
                Check(ui.SoftwareKeyboard(Args(min: 3)) == null && Red.Total == before, "real cancel is null and not red");
                transport = new FakeTransport { Answer = Encoding.UTF8.GetBytes("{\"private-input-marker\": true}") };
                ui = OhosHostUi.Create(transport.Keyboard());
                Check(ui.SoftwareKeyboard(Args()) == null && Red.Total == before + 1, "bad reply answers null and reports red once");
                Check(redLines.Count == 1 && redLines[0].Contains("鸿蒙软键盘应答失败"), "first red prints one line");
                Check(!redLines[0].Contains("private-input-marker"), "red line does not print input");
            });
            Case("unicode-roundtrip-and-frozen-schema", () =>
            {
                var args = Args(KeyboardMode.Default, 2, 5);
                args.HeaderText = "角色名称"; args.SubtitleText = "中文"; args.GuideText = "真实输入";
                args.InitialText = "勇者😀"; args.SubmitText = "确认";
                var transport = new FakeTransport { Answer = Reply(true, "小菠萝😀") };
                Check(transport.Keyboard().Display(args, out string value) && value == "小菠萝😀" && value.Length == 5, "UTF16 roundtrip");
                using var request = JsonDocument.Parse(transport.Request);
                var root = request.RootElement;
                Check(root.EnumerateObject().Count() == 10, "frozen request field count");
                Check(root.GetProperty("version").GetInt32() == 1 && root.GetProperty("type").GetString() == "keyboard", "typed request");
                Check(root.GetProperty("header").GetString() == args.HeaderText && root.GetProperty("initialText").GetString() == args.InitialText, "request Unicode");
                Check(root.GetProperty("minLength").GetInt32() == 2 && root.GetProperty("maxLength").GetInt32() == 5, "lengths unchanged");
                Check(transport.CancelCount == 1, "accepted cleanup");
            });
            Case("cancel-is-false-null-even-below-minimum", () =>
            {
                var transport = new FakeTransport { Answer = Reply(false, "") };
                Check(!transport.Keyboard().Display(Args(min: 3), out string value) && value == null, "cancel output must be null");
                Check(transport.CancelCount == 1, "cancel cleanup");
                transport = new FakeTransport { Answer = Reply(false, "尚未完成") };
                Check(!transport.Keyboard().Display(Args(KeyboardMode.Numeric, 1), out value) && value == null, "cancel need not satisfy accepted text restrictions");
            });
            Case("mode-constraints", () =>
            {
                foreach (var item in new[] { (KeyboardMode.FullLatin, "中文😀"), (KeyboardMode.Numeric, "12..09"), (KeyboardMode.ASCII, " A~9") })
                {
                    var transport = new FakeTransport { Answer = Reply(true, item.Item2) };
                    Check(transport.Keyboard().Display(Args(item.Item1), out string value) && value == item.Item2, "supported mode");
                }
                RejectReply(Encoding.UTF8.GetString(Reply(true, "-1")), Args(KeyboardMode.Numeric));
                RejectReply(Encoding.UTF8.GetString(Reply(true, "１２")), Args(KeyboardMode.Numeric));
                RejectReply(Encoding.UTF8.GetString(Reply(true, "a\n")), Args(KeyboardMode.ASCII));
                RejectReply(Encoding.UTF8.GetString(Reply(true, "中文")), Args(KeyboardMode.ASCII));
                foreach (uint mode in new uint[] { 4, 5, 6, 7, 8, 9, 99, uint.MaxValue })
                {
                    var transport = new FakeTransport();
                    Throws<NotSupportedException>(() => transport.Keyboard().Display(Args((KeyboardMode)mode), out _));
                    Check(transport.BeginCount == 0, "unsupported mode must fail before admission");
                }
            });
            Case("utf16-length-and-request-validation", () =>
            {
                var transport = new FakeTransport { Answer = Reply(true, "😀") };
                Check(transport.Keyboard().Display(Args(min: 2, max: 2), out _), "emoji occupies two UTF16 units");
                RejectReply(Encoding.UTF8.GetString(Reply(true, "😀")), Args(max: 1));
                RejectReply(Encoding.UTF8.GetString(Reply(true, "a")), Args(min: 2));
                RejectReply(Encoding.UTF8.GetString(Reply(false, new string('a', 1001))));
                foreach (var args in new[] { Args(min: -1), Args(min: 3, max: 2), Args(max: 1001) })
                    Throws<ArgumentException>(() => OhosKeyboard.EncodeRequest(args));
                var bad = Args(max: 1); bad.InitialText = "ab";
                Throws<ArgumentException>(() => OhosKeyboard.EncodeRequest(bad));
                bad = Args(KeyboardMode.Numeric); bad.InitialText = "a";
                Throws<ArgumentException>(() => OhosKeyboard.EncodeRequest(bad));
                bad = Args(); bad.InitialText = "\ud800";
                Throws<ArgumentException>(() => OhosKeyboard.EncodeRequest(bad));
                bad = Args(); bad.HeaderText = new string('x', 4097);
                Throws<ArgumentException>(() => OhosKeyboard.EncodeRequest(bad));
                bad = Args(); bad.HeaderText = new string('x', 2100); bad.SubtitleText = new string('y', 2100);
                Throws<ArgumentException>(() => OhosKeyboard.EncodeRequest(bad));
                using var empty = JsonDocument.Parse(OhosKeyboard.EncodeRequest(Args(max: 0)));
                Check(empty.RootElement.GetProperty("initialText").GetString() == "", "null initial text encoded empty");
            });
            Case("strict-json-duplicates-types-and-unicode", () =>
            {
                foreach (string wire in new[] {
                    "[]", "null", "{}", "{\"version\":2,\"type\":\"keyboard\",\"accepted\":true,\"text\":\"a\"}",
                    "{\"version\":1.0,\"type\":\"keyboard\",\"accepted\":true,\"text\":\"a\"}",
                    "{\"version\":1,\"type\":\"other\",\"accepted\":true,\"text\":\"a\"}",
                    "{\"version\":1,\"type\":\"keyboard\",\"accepted\":1,\"text\":\"a\"}",
                    "{\"version\":1,\"type\":\"keyboard\",\"accepted\":true,\"text\":null}",
                    "{\"version\":1,\"type\":\"keyboard\",\"accepted\":true,\"text\":\"a\",\"text\":\"b\"}",
                    "{\"version\":1,\"type\":\"keyboard\",\"accepted\":true,\"text\":\"a\",\"te\\u0078t\":\"b\"}",
                    "{\"version\":1,\"type\":\"keyboard\",\"accepted\":true,\"text\":\"a\",\"extra\":0}",
                    "{\"version\":1,\"type\":\"keyboard\",\"accepted\":true,\"text\":\"\\uD800\"}",
                    "{\"version\":1,\"type\":\"keyboard\",\"accepted\":true,\"text\":\"a\",}",
                    "{\"version\":1,\"type\":\"keyboard\",\"accepted\":true,\"text\":\"a\"}{}" }) RejectReply(wire);
                var invalid = new FakeTransport { Answer = new byte[] { (byte)'{', 0xc0, 0xaf, (byte)'}' } };
                Throws<InvalidDataException>(() => invalid.Keyboard().Display(Args(), out _));
                Check(invalid.CancelCount == 1, "invalid UTF8 cleanup");
            });
            Case("bounded-range-retry-and-terminator", () =>
            {
                var transport = new FakeTransport { Answer = Reply(true, new string('a', 1000)) };
                Check(transport.Keyboard().Display(Args(), out string value) && value.Length == 1000, "range growth preserves answer");
                Check(transport.Capacities.Count == 2 && transport.Capacities[0] == 1024 && transport.Capacities[1] == transport.Answer.Length + 1, "RANGE includes NUL");
                foreach (nuint length in new nuint[] { 0, 1024, 8194, nuint.MaxValue })
                {
                    var bad = new FakeTransport(); bad.ForcedRanges.Enqueue(length);
                    Throws<InvalidDataException>(() => bad.Keyboard().Display(Args(), out _));
                    Check(bad.CancelCount == 1, "bad RANGE cleanup");
                }
                transport = new FakeTransport(); transport.ForcedRanges.Enqueue(2048); transport.ForcedRanges.Enqueue(4096);
                Throws<InvalidDataException>(() => transport.Keyboard().Display(Args(), out _));
                foreach (nuint length in new nuint[] { 0, 1024, 8193, nuint.MaxValue })
                {
                    var bad = new FakeTransport { SuccessfulLength = length };
                    Throws<InvalidDataException>(() => bad.Keyboard().Display(Args(), out _));
                }
                transport = new FakeTransport { OmitNul = true };
                Throws<InvalidDataException>(() => transport.Keyboard().Display(Args(), out _));
            });
            Case("pending-timeout-and-deadline-cleanup", () =>
            {
                var transport = new FakeTransport { PendingCount = 2 };
                Check(transport.Keyboard().Display(Args(), out _), "pending can become a real answer");
                Check(transport.Timeouts.Count == 3 && transport.CancelCount == 1, "pending count");
                transport = new FakeTransport { PendingCount = 100 };
                Throws<TimeoutException>(() => transport.Keyboard(800).Display(Args(), out _));
                Check(transport.Timeouts.Count == 4 && transport.Timeouts[3] == 50 && transport.Now == 800 && transport.CancelCount == 1, "total deadline and final short poll");
                transport = new FakeTransport { AdvanceOnReply = 1000 };
                Throws<TimeoutException>(() => transport.Keyboard(1000).Display(Args(), out _));
                Check(transport.CancelCount == 1, "late answer cleanup");
            });
            Case("transport-errors-red-and-finally", () =>
            {
                // 生产口径（OhosHostUi 登记共用 HostUi 的软键盘挂点）：传输出错 → 报红一次、回 null（= 不确认），不抛、不停局；请求照样释放
                foreach (int error in new[] { -1, -2, -4, -5, -99 })
                {
                    var transport = new FakeTransport { WaitError = error };
                    long before = Red.Total;
                    var ui = OhosHostUi.Create(transport.Keyboard());
                    Check(ui.SoftwareKeyboard(Args()) == null, "wait error answers null (not confirmed)");
                    Check(Red.Total == before + 1 && transport.CancelCount == 1, "wait error must report red once and release");
                }
                var begin = new FakeTransport { BeginError = -4, Id = 0 };
                Throws<InvalidOperationException>(() => begin.Keyboard().Display(Args(), out _));
                Check(begin.CancelCount == 0 && begin.Timeouts.Count == 0, "failed begin admitted no request");
                begin = new FakeTransport { BeginError = -5 };
                Throws<InvalidOperationException>(() => begin.Keyboard().Display(Args(), out _));
                Check(begin.CancelCount == 1, "unexpected allocated ID still cleaned");
                begin = new FakeTransport { Id = 0 };
                Throws<InvalidDataException>(() => begin.Keyboard().Display(Args(), out _));
                var failed = new FakeTransport { ThrowWait = true };
                Throws<IOException>(() => failed.Keyboard().Display(Args(), out _));
                Check(failed.CancelCount == 1, "exception still cleans");
                failed = new FakeTransport { CancelError = -5 };
                string userText = "sentinel";
                Throws<InvalidOperationException>(() => failed.Keyboard().Display(Args(), out userText));
                Check(userText == null, "cleanup failure cannot publish success");
                failed = new FakeTransport { WaitError = -4, CancelError = -5 };
                var both = Throws<AggregateException>(() => failed.Keyboard().Display(Args(), out _));
                Check(both.InnerExceptions.Count == 2, "preserve request and cleanup errors");
            });
            Console.WriteLine($"PASS keyboard: {_cases} groups, {_assertions} assertions; actual managed codec/loop/host adapter, fake transport only.");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"FAIL keyboard after {_cases} groups: {error}");
            return 1;
        }
    }
}

internal static class JsonPropertyCount
{
    internal static int Count(this JsonElement.ObjectEnumerator values)
    {
        int count = 0;
        foreach (var _ in values) count++;
        return count;
    }
}
