// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Applets.SoftwareKeyboard;
using System;
using System.Buffers;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace S2A.Android.Aot
{
    // Synchronous only on the applet/service caller. UI and GPU threads never wait here.
    // The native broker owns requests; JSON and copied reply bytes never borrow UI memory.
    internal interface IOhosKeyboardTransport
    {
        int Begin(ReadOnlySpan<byte> request, out ulong id);
        int Wait(ulong id, int timeoutMilliseconds, Span<byte> reply, out nuint length);
        int Cancel(ulong id);
    }

    internal sealed class OhosKeyboard
    {
        internal const int RequestLimit = 4096;
        internal const int ReplyLimit = 8192;
        internal const int TextLimit = 1000;
        internal const int Range = -3;
        internal const int Pending = -6;
        private static readonly UTF8Encoding StrictUtf8 = new(false, true);
        private readonly IOhosKeyboardTransport _transport;
        private readonly Func<long> _milliseconds;
        private readonly int _timeoutMilliseconds;
        private readonly int _pollMilliseconds;

        internal OhosKeyboard() : this(new NativeTransport(), () => Environment.TickCount64) { }

        internal OhosKeyboard(IOhosKeyboardTransport transport, Func<long> milliseconds,
            int timeoutMilliseconds = 120000, int pollMilliseconds = 250)
        {
            _transport = transport ?? throw new ArgumentNullException(nameof(transport));
            _milliseconds = milliseconds ?? throw new ArgumentNullException(nameof(milliseconds));
            if (timeoutMilliseconds <= 0 || pollMilliseconds <= 0 || pollMilliseconds > 250)
                throw new ArgumentOutOfRangeException(nameof(timeoutMilliseconds));
            _timeoutMilliseconds = timeoutMilliseconds;
            _pollMilliseconds = pollMilliseconds;
        }

        internal bool Display(SoftwareKeyboardUIArgs args, out string userText)
        {
            userText = null;
            byte[] request = EncodeRequest(args);
            byte[] buffer = new byte[1024];
            ulong id = 0;
            Exception failure = null;
            try
            {
                long start = _milliseconds();
                int error = _transport.Begin(request, out id);
                if (error != 0) throw TransportFailure("begin", error);
                if (id == 0) throw new InvalidDataException("OHOS keyboard begin returned an invalid request ID.");
                bool resized = false;
                while (true)
                {
                    long elapsed = _milliseconds() - start;
                    if (elapsed < 0 || elapsed >= _timeoutMilliseconds)
                        throw new TimeoutException("OHOS keyboard request exceeded its wait deadline.");
                    int wait = (int)Math.Min(_pollMilliseconds, _timeoutMilliseconds - elapsed);
                    buffer.AsSpan().Fill(0xff);
                    error = _transport.Wait(id, wait, buffer, out nuint length);
                    if (error == Pending) continue;
                    if (error == Range)
                    {
                        // An answered broker request is immutable until consumed. One
                        // capacity retry is sufficient; RANGE must include its final NUL.
                        if (resized || length <= (nuint)buffer.Length || length > ReplyLimit + 1)
                            throw new InvalidDataException("OHOS keyboard reply capacity is invalid.");
                        Array.Clear(buffer);
                        buffer = new byte[(int)length];
                        resized = true;
                        continue;
                    }
                    if (error != 0) throw TransportFailure("wait", error);
                    long completedAfter = _milliseconds() - start;
                    if (completedAfter < 0 || completedAfter >= _timeoutMilliseconds)
                        throw new TimeoutException("OHOS keyboard reply arrived after its wait deadline.");
                    if (length == 0 || length > ReplyLimit || length >= (nuint)buffer.Length || buffer[(int)length] != 0)
                        throw new InvalidDataException("OHOS keyboard reply length or terminator is invalid.");
                    (bool accepted, string text) = DecodeReply(buffer.AsMemory(0, (int)length), args);
                    // A real cancel is distinct from transport failure. Null lets the
                    // unchanged applet handle its own cancellation result/cleanup text.
                    userText = accepted ? text : null;
                    return accepted;
                }
            }
            catch (Exception error)
            {
                failure = error;
                throw;
            }
            finally
            {
                Exception cleanupFailure = null;
                try
                {
                    if (id != 0)
                    {
                        int error = _transport.Cancel(id);
                        if (error != 0) cleanupFailure = TransportFailure("cancel", error);
                    }
                }
                catch (Exception error) { cleanupFailure = error; }
                Array.Clear(request);
                Array.Clear(buffer);
                if (cleanupFailure != null)
                {
                    userText = null;
                    if (failure != null)
                        throw new AggregateException("OHOS keyboard request and cleanup failed.", failure, cleanupFailure);
                    throw cleanupFailure;
                }
            }
        }

        private static Exception TransportFailure(string operation, int error) =>
            new InvalidOperationException($"OHOS keyboard transport {operation} failed, rc={error}.");

        internal static byte[] EncodeRequest(SoftwareKeyboardUIArgs args)
        {
            ValidateLimits(args);
            ValidateMode(args.KeyboardMode);
            string initial = args.InitialText ?? string.Empty;
            if (initial.Length > args.StringLengthMax)
                throw new ArgumentException("OHOS keyboard initial text exceeds the requested maximum.");
            ValidateCharacters(initial, args.KeyboardMode);
            string[] strings = { args.HeaderText ?? string.Empty, args.SubtitleText ?? string.Empty,
                args.GuideText ?? string.Empty, initial, args.SubmitText ?? string.Empty };
            foreach (string value in strings)
            {
                ValidateUnicode(value);
                if (value.Length > RequestLimit || StrictUtf8.GetByteCount(value) > RequestLimit)
                    throw new ArgumentException("OHOS keyboard request text exceeds the wire limit.");
            }
            var bytes = new ArrayBufferWriter<byte>();
            using (var writer = new Utf8JsonWriter(bytes, new JsonWriterOptions { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
            {
                writer.WriteStartObject();
                writer.WriteNumber("version", 1);
                writer.WriteString("type", "keyboard");
                writer.WriteString("header", strings[0]);
                writer.WriteString("subtitle", strings[1]);
                writer.WriteString("guide", strings[2]);
                writer.WriteString("initialText", strings[3]);
                writer.WriteString("submitText", strings[4]);
                writer.WriteNumber("minLength", args.StringLengthMin);
                writer.WriteNumber("maxLength", args.StringLengthMax);
                writer.WriteNumber("keyboardMode", (int)args.KeyboardMode);
                writer.WriteEndObject();
            }
            if (bytes.WrittenCount > RequestLimit)
                throw new ArgumentException("OHOS keyboard request exceeds the wire limit.");
            return bytes.WrittenSpan.ToArray();
        }

        internal static (bool Accepted, string Text) DecodeReply(ReadOnlyMemory<byte> bytes, SoftwareKeyboardUIArgs args)
        {
            if (bytes.Length == 0 || bytes.Length > ReplyLimit)
                throw new InvalidDataException("OHOS keyboard reply exceeds the wire limit.");
            try
            {
                _ = StrictUtf8.GetCharCount(bytes.Span);
                using JsonDocument document = JsonDocument.Parse(bytes, new JsonDocumentOptions
                { AllowTrailingCommas = false, CommentHandling = JsonCommentHandling.Disallow, MaxDepth = 4 });
                if (document.RootElement.ValueKind != JsonValueKind.Object) throw BadReply();
                int fields = 0;
                bool accepted = false;
                string text = null;
                foreach (JsonProperty property in document.RootElement.EnumerateObject())
                {
                    int bit;
                    switch (property.Name)
                    {
                        case "version":
                            bit = 1;
                            if (property.Value.ValueKind != JsonValueKind.Number || !property.Value.TryGetInt32(out int version) || version != 1)
                                throw BadReply();
                            break;
                        case "type":
                            bit = 2;
                            if (property.Value.ValueKind != JsonValueKind.String || property.Value.GetString() != "keyboard") throw BadReply();
                            break;
                        case "accepted":
                            bit = 4;
                            if (property.Value.ValueKind != JsonValueKind.True && property.Value.ValueKind != JsonValueKind.False) throw BadReply();
                            accepted = property.Value.GetBoolean();
                            break;
                        case "text":
                            bit = 8;
                            if (property.Value.ValueKind != JsonValueKind.String) throw BadReply();
                            text = property.Value.GetString();
                            break;
                        default: throw BadReply();
                    }
                    if ((fields & bit) != 0) throw BadReply();
                    fields |= bit;
                }
                if (fields != 15 || text.Length > TextLimit) throw BadReply();
                ValidateUnicode(text);
                if (accepted)
                {
                    if (text.Length < args.StringLengthMin || text.Length > args.StringLengthMax) throw BadReply();
                    ValidateCharacters(text, args.KeyboardMode);
                }
                return (accepted, text);
            }
            catch (Exception error) when (error is JsonException || error is DecoderFallbackException ||
                                          error is EncoderFallbackException || error is ArgumentException || error is InvalidOperationException)
            {
                // Parser details can quote input; never attach or log their contents.
                throw BadReply();
            }
        }

        private static InvalidDataException BadReply() => new("OHOS keyboard reply violates the typed protocol or text constraints.");

        private static void ValidateLimits(SoftwareKeyboardUIArgs args)
        {
            if (args.StringLengthMin < 0 || args.StringLengthMax < args.StringLengthMin || args.StringLengthMax > TextLimit)
                throw new ArgumentException("OHOS keyboard length constraints are unsupported.");
        }

        private static void ValidateMode(KeyboardMode mode)
        {
            if (mode != KeyboardMode.Default && mode != KeyboardMode.FullLatin && mode != KeyboardMode.Numeric && mode != KeyboardMode.ASCII)
                throw new NotSupportedException($"OHOS keyboard mode {(uint)mode} is not implemented.");
        }

        private static void ValidateUnicode(string text)
        {
            try { _ = StrictUtf8.GetByteCount(text); }
            catch (EncoderFallbackException) { throw new ArgumentException("OHOS keyboard text contains invalid Unicode."); }
        }

        private static void ValidateCharacters(string text, KeyboardMode mode)
        {
            foreach (char value in text)
            {
                if (mode == KeyboardMode.Numeric && value != '.' && (value < '0' || value > '9'))
                    throw new ArgumentException("OHOS numeric keyboard text contains an unsupported character.");
                if (mode == KeyboardMode.ASCII && (value < 0x20 || value > 0x7e))
                    throw new ArgumentException("OHOS ASCII keyboard text contains an unsupported character.");
            }
        }

        private sealed unsafe class NativeTransport : IOhosKeyboardTransport
        {
            [DllImport("s2a_native")] private static extern int s2a_ohos_ui_begin(byte* json, ulong* id);
            [DllImport("s2a_native")] private static extern int s2a_ohos_ui_wait(ulong id, int timeoutMilliseconds, byte* reply, nuint capacity, nuint* length);
            [DllImport("s2a_native")] private static extern int s2a_ohos_ui_cancel(ulong id);

            public int Begin(ReadOnlySpan<byte> request, out ulong id)
            {
                byte[] terminated = new byte[request.Length + 1];
                request.CopyTo(terminated);
                ulong value = 0;
                try
                {
                    fixed (byte* json = terminated)
                    {
                        int result = s2a_ohos_ui_begin(json, &value);
                        id = value;
                        return result;
                    }
                }
                finally { Array.Clear(terminated); }
            }

            public int Wait(ulong id, int timeoutMilliseconds, Span<byte> reply, out nuint length)
            {
                nuint value = 0;
                fixed (byte* output = reply)
                {
                    int result = s2a_ohos_ui_wait(id, timeoutMilliseconds, output, (nuint)reply.Length, &value);
                    length = value;
                    return result;
                }
            }

            public int Cancel(ulong id) => s2a_ohos_ui_cancel(id);
        }
    }
}
