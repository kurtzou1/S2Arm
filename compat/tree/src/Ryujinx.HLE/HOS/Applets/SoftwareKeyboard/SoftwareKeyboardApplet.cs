using Ryujinx.Common;
using Ryujinx.Common.Configuration.Hid;
using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Applets.SoftwareKeyboard;
using Ryujinx.HLE.HOS.Services.Am.AppletAE;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.Npad;
using Ryujinx.HLE.UI;
using Ryujinx.HLE.UI.Input;
using Ryujinx.Memory;
using System;
using System.Buffers.Binary;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Ryujinx.HLE.HOS.Applets
{
    internal class SoftwareKeyboardApplet : IApplet
    {
        private const string DefaultInputText = "Ryujinx";

        private const int StandardBufferSize = 0x7D8;
        private const int InteractiveBufferSize = 0x7D4;
        private const int MaxUserWords = 0x1388;
        private const int MaxUiTextSize = 100;

        private const Key CycleInputModesKey = Key.F6;

        private readonly Switch _device;

        private SoftwareKeyboardState _foregroundState = SoftwareKeyboardState.Uninitialized;
        private volatile InlineKeyboardState _backgroundState = InlineKeyboardState.Uninitialized;

        private bool _isBackground = false;

        private AppletSession _normalSession;
        private AppletSession _interactiveSession;

        // Configuration for foreground mode.
        private SoftwareKeyboardConfig _keyboardForegroundConfig;

        // Configuration for background (inline) mode.
#pragma warning disable IDE0052 // Remove unread private member
        private SoftwareKeyboardInitialize _keyboardBackgroundInitialize;
        private SoftwareKeyboardCustomizeDic _keyboardBackgroundDic;
        private SoftwareKeyboardDictSet _keyboardBackgroundDictSet;
#pragma warning restore IDE0052
        private SoftwareKeyboardUserWord[] _keyboardBackgroundUserWords;

        private byte[] _transferMemory;

        private string _textValue = string.Empty;
        private int _cursorBegin = 0;
        private Encoding _encoding = Encoding.Unicode;
        private KeyboardResult _lastResult = KeyboardResult.NotSet;

        private IDynamicTextInputHandler _dynamicTextInputHandler = null;
        private SoftwareKeyboardRenderer _keyboardRenderer = null;

        // S2Arm: headless host (no UI theme) — no on-screen keyboard; when the game shows the inline keyboard,
        // the text comes from the host's input dialog policy (same as the foreground keyboard), fitted to the game's Appear limits,
        // and is submitted once the appear has settled
        private bool _headless;
        private KeyboardCalcFlags _lastCalcFlags;
        private int _headlessAnswer;

        // S2Arm: how long after the keyboard is shown the host's answer is handed over (both the foreground applet and the inline keyboard)
        private const int AnswerDelayMs = 500;
        private const int DecidedAfterChangedMs = 150;

        // S2Arm: the system text input the host is showing for this keyboard (IAsyncTextInput), null when none;
        // its answer is matched by _headlessAnswer (inline) / _foregroundAnswer, a dismissed or superseded input's late answer is dropped
        private IDisposable _hostInput;
        private int _foregroundAnswer;
        private NpadReader _npads = null;
        private bool _canAcceptController = false;
        private KeyboardInputMode _inputMode = KeyboardInputMode.ControllerAndKeyboard;

        private readonly Lock _lock = new();

        public event EventHandler AppletStateChanged;

        public SoftwareKeyboardApplet(Horizon system)
        {
            _device = system.Device;
        }

        public ResultCode Start(AppletSession normalSession, AppletSession interactiveSession)
        {
            lock (_lock)
            {
                _normalSession = normalSession;
                _interactiveSession = interactiveSession;

                _interactiveSession.DataAvailable += OnInteractiveData;

                byte[] launchParams = _normalSession.Pop();
                byte[] keyboardConfig = _normalSession.Pop();

                _isBackground = keyboardConfig.Length == Unsafe.SizeOf<SoftwareKeyboardInitialize>();

                if (_isBackground)
                {
                    // Initialize the keyboard applet in background mode.

                    _keyboardBackgroundInitialize = MemoryMarshal.Read<SoftwareKeyboardInitialize>(keyboardConfig);
                    _backgroundState = InlineKeyboardState.Uninitialized;

                    _headless = _device.UIHandler != null && _device.UIHandler.HostUITheme == null;

                    if (_device.UIHandler == null)
                    {
                        Logger.Error?.Print(LogClass.ServiceAm, "GUI Handler is not set, software keyboard applet will not work properly");
                    }
                    else if (!_headless)
                    {
                        // Create a text handler that converts keyboard strokes to strings.
                        _dynamicTextInputHandler = _device.UIHandler.CreateDynamicTextInputHandler();
                        _dynamicTextInputHandler.TextChangedEvent += HandleTextChangedEvent;
                        _dynamicTextInputHandler.KeyPressedEvent += HandleKeyPressedEvent;

                        _npads = new NpadReader(_device);
                        _npads.NpadButtonDownEvent += HandleNpadButtonDownEvent;
                        _npads.NpadButtonUpEvent += HandleNpadButtonUpEvent;

                        _keyboardRenderer = new SoftwareKeyboardRenderer(_device.UIHandler.HostUITheme);
                    }

                    return ResultCode.Success;
                }
                else
                {
                    // Initialize the keyboard applet in foreground mode.

                    if (keyboardConfig.Length < Marshal.SizeOf<SoftwareKeyboardConfig>())
                    {
                        Logger.Error?.Print(LogClass.ServiceAm, $"SoftwareKeyboardConfig size mismatch. Expected {Marshal.SizeOf<SoftwareKeyboardConfig>():x}. Got {keyboardConfig.Length:x}");
                    }
                    else
                    {
                        _keyboardForegroundConfig = ReadStruct<SoftwareKeyboardConfig>(keyboardConfig);

                        // S2Arm: games on the 20.0.0+ keyboard (applet version 0x140010, all Switch 2 games) pass the native config, 0x530 bytes
                        if (keyboardConfig.Length == NativeConfigSize)
                        {
                            ApplyNativeConfig(ref _keyboardForegroundConfig, keyboardConfig);
                        }
                    }

                    Logger.Info?.Print(LogClass.ServiceAm, $"S2A 软键盘：独立键盘配置 {keyboardConfig.Length:x} 字节（{(keyboardConfig.Length == NativeConfigSize ? "20.0.0 起新布局" : "旧布局")}），" +
                        $"长度 {_keyboardForegroundConfig.StringLengthMin}–{_keyboardForegroundConfig.StringLengthMax}，UTF-8 {_keyboardForegroundConfig.UseUtf8}，游戏自己校验 {_keyboardForegroundConfig.CheckText}");

                    if (!_normalSession.TryPop(out _transferMemory))
                    {
                        Logger.Error?.Print(LogClass.ServiceAm, "SwKbd Transfer Memory is null");
                    }

                    if (_keyboardForegroundConfig.UseUtf8)
                    {
                        _encoding = Encoding.UTF8;
                    }

                    _foregroundState = SoftwareKeyboardState.Ready;

                    ExecuteForegroundKeyboard();

                    return ResultCode.Success;
                }
            }
        }

        // S2Arm: the 20.0.0+ native keyboard config (protocol facts from public emulator sources; the 0x3AA-byte text prefix keeps the old layout,
        //   the fields after it moved). Read with the old layout, a Switch 2 game's "validate the text myself" flag (0x48D) was taken from 0x3D0
        //   (almost always 0): the name went straight back as final while the game waited for its own check — the keyboard looked stuck.
        //   UTF-8 and the initial text's position were misread the same way
        internal const int NativeConfigSize = 0x530;

        internal static void ApplyNativeConfig(ref SoftwareKeyboardConfig c, byte[] b)
        {
            int I(int o) => BinaryPrimitives.ReadInt32LittleEndian(b.AsSpan(o, 4));
            c.UseNewLine = b[0x1B] != 0;
            c.UseUtf8 = b[0x3AA] != 0;
            c.UseBlurBackground = b[0x3AB] != 0;
            c.StringLengthMax = I(0x3AC);
            c.StringLengthMin = I(0x3B0);
            c.PasswordMode = (PasswordMode)I(0x3B4);
            c.InputFormMode = (InputFormMode)I(0x3B8);
            c.InitialStringOffset = I(0x3BC);
            c.InitialStringLength = I(0x3C0);
            c.CustomDictionaryOffset = I(0x3C4);
            c.CustomDictionaryCount = I(0x3C8);
            c.CheckText = b[0x48D] != 0;
        }

        private bool IsKeyboardActive()
        {
            return _backgroundState is >= InlineKeyboardState.Appearing and < InlineKeyboardState.Disappearing;
        }

        private bool InputModeControllerEnabled()
        {
            return _inputMode is KeyboardInputMode.ControllerAndKeyboard or
                   KeyboardInputMode.ControllerOnly;
        }

        private bool InputModeTypingEnabled()
        {
            return _inputMode is KeyboardInputMode.ControllerAndKeyboard or
                   KeyboardInputMode.KeyboardOnly;
        }

        private void AdvanceInputMode()
        {
            _inputMode = (KeyboardInputMode)((int)(_inputMode + 1) % (int)KeyboardInputMode.Count);
        }

        public bool DrawTo(RenderingSurfaceInfo surfaceInfo, IVirtualMemoryManager destination, ulong position)
        {
            _npads?.Update();

            _keyboardRenderer?.SetSurfaceInfo(surfaceInfo);

            return _keyboardRenderer?.DrawTo(destination, position) ?? false;
        }

        private void ExecuteForegroundKeyboard()
        {
            string initialText = null;

            // Initial Text is always encoded as a UTF-16 string in the work buffer (passed as transfer memory)
            // InitialStringOffset points to the memory offset and InitialStringLength is the number of UTF-16 characters
            if (_transferMemory != null && _keyboardForegroundConfig.InitialStringLength > 0)
            {
                initialText = Encoding.Unicode.GetString(_transferMemory, _keyboardForegroundConfig.InitialStringOffset,
                    2 * _keyboardForegroundConfig.InitialStringLength);
            }

            // If the max string length is 0, we set it to a large default
            // length.
            if (_keyboardForegroundConfig.StringLengthMax == 0)
            {
                _keyboardForegroundConfig.StringLengthMax = 100;
            }

            if (_device.UIHandler == null)
            {
                Logger.Warning?.Print(LogClass.Application, "GUI Handler is not set. Falling back to default");

                _textValue = DefaultInputText;
                _lastResult = KeyboardResult.Accept;
            }
            else
            {
                // Call the configured GUI handler to get user's input.
                SoftwareKeyboardUIArgs args = new()
                {
                    KeyboardMode = _keyboardForegroundConfig.Mode,
                    HeaderText = StripUnicodeControlCodes(_keyboardForegroundConfig.HeaderText),
                    SubtitleText = StripUnicodeControlCodes(_keyboardForegroundConfig.SubtitleText),
                    GuideText = StripUnicodeControlCodes(_keyboardForegroundConfig.GuideText),
                    SubmitText = (!string.IsNullOrWhiteSpace(_keyboardForegroundConfig.SubmitText) ?
                    _keyboardForegroundConfig.SubmitText : "OK"),
                    StringLengthMin = _keyboardForegroundConfig.StringLengthMin,
                    StringLengthMax = _keyboardForegroundConfig.StringLengthMax,
                    InitialText = initialText,
                };

                // S2Arm: a host with its own text input shows it and answers later; the game keeps running meanwhile
                if (_device.UIHandler is IAsyncTextInput input && BeginForegroundInput(input, args, initialText))
                {
                    return;
                }

                _lastResult = _device.UIHandler.DisplayInputDialog(args, out _textValue) ? KeyboardResult.Accept : KeyboardResult.Cancel;
                _textValue ??= initialText ?? DefaultInputText;
            }

            // S2Arm: same rule as the inline keyboard (FitLength). Upstream joined repeats with a space, which no numeric field accepts
            // (Let's Get Fit weight, 2–3 digits: "0" became "0 0")
            _textValue = FitLength(_textValue, _keyboardForegroundConfig.StringLengthMin, _keyboardForegroundConfig.StringLengthMax);

            // S2Arm: a player's input always comes after the keyboard has been shown, never inside the game's Start call
            _ = Task.Delay(AnswerDelayMs).ContinueWith(_ =>
            {
                lock (_lock)
                {
                    SubmitForeground();
                }
            }, TaskScheduler.Default);
        }

        // S2Arm: foreground applet answered by the host's system text input (IAsyncTextInput). Called with _lock held (Start)
        private bool BeginForegroundInput(IAsyncTextInput input, SoftwareKeyboardUIArgs args, string initialText)
        {
            int answer = ++_foregroundAnswer;
            long shown = Stopwatch.GetTimestamp();
            IDisposable handle = input.BeginTextInput(args, (ok, text) =>
            {
                Task.Delay(RemainingDelay(shown)).ContinueWith(_ =>
                {
                    lock (_lock)
                    {
                        if (answer != _foregroundAnswer || _foregroundState != SoftwareKeyboardState.Ready)
                        {
                            return;
                        }

                        _hostInput = null;
                        _lastResult = ok ? KeyboardResult.Accept : KeyboardResult.Cancel;
                        _textValue = FitLength((ok ? text : null) ?? initialText ?? DefaultInputText, _keyboardForegroundConfig.StringLengthMin, _keyboardForegroundConfig.StringLengthMax);
                        SubmitForeground();
                    }
                }, TaskScheduler.Default);
            });

            if (handle == null)
            {
                return false;
            }

            _hostInput = handle;
            return true;
        }

        // S2Arm: a player's input always comes after the keyboard has been shown (AnswerDelayMs), however fast the host answers
        private static TimeSpan RemainingDelay(long shown)
        {
            TimeSpan left = TimeSpan.FromMilliseconds(AnswerDelayMs) - Stopwatch.GetElapsedTime(shown);
            return left > TimeSpan.Zero ? left : TimeSpan.Zero;
        }

        // S2Arm: dismiss the host's system text input (game finalized / hid the keyboard); its late answer is dropped
        private void DismissHostInput()
        {
            ++_headlessAnswer;
            ++_foregroundAnswer;
            IDisposable handle = _hostInput;
            _hostInput = null;
            handle?.Dispose();
        }

        private void SubmitForeground()
        {
            // Does the application want to validate the text itself?
            if (_keyboardForegroundConfig.CheckText)
            {
                // The application needs to validate the response, so we
                // submit it to the interactive output buffer, and poll it
                // for validation. Once validated, the application will submit
                // back a validation status, which is handled in OnInteractiveDataPushIn.
                _foregroundState = SoftwareKeyboardState.ValidationPending;

                PushForegroundResponse(true);
            }
            else
            {
                // If the application doesn't need to validate the response,
                // we push the data to the non-interactive output buffer
                // and poll it for completion.
                _foregroundState = SoftwareKeyboardState.Complete;

                PushForegroundResponse(false);

                AppletStateChanged?.Invoke(this, null);
            }
        }

        private void OnInteractiveData(object sender, EventArgs e)
        {
            // Obtain the validation status response.
            byte[] data = _interactiveSession.Pop();

            if (_isBackground)
            {
                lock (_lock)
                {
                    OnBackgroundInteractiveData(data);
                }
            }
            else
            {
                OnForegroundInteractiveData(data);
            }
        }

        private void OnForegroundInteractiveData(byte[] data)
        {
            if (_foregroundState == SoftwareKeyboardState.ValidationPending)
            {
                // TODO(jduncantor):
                // If application rejects our "attempt", submit another attempt,
                // and put the applet back in PendingValidation state.

                // For now we assume success, so we push the final result
                // to the standard output buffer and carry on our merry way.
                PushForegroundResponse(false);

                AppletStateChanged?.Invoke(this, null);

                _foregroundState = SoftwareKeyboardState.Complete;
            }
            else if (_foregroundState == SoftwareKeyboardState.Complete)
            {
                // If we have already completed, we push the result text
                // back on the output buffer and poll the application.
                PushForegroundResponse(false);

                AppletStateChanged?.Invoke(this, null);
            }
            else
            {
                // We shouldn't be able to get here through standard swkbd execution.
                throw new InvalidOperationException("Software Keyboard is in an invalid state.");
            }
        }

        private void OnBackgroundInteractiveData(byte[] data)
        {
            // WARNING: Only invoke applet state changes after an explicit finalization
            // request from the game, this is because the inline keyboard is expected to
            // keep running in the background sending data by itself.

            using MemoryStream stream = new(data);
            using BinaryReader reader = new(stream);

            InlineKeyboardRequest request = (InlineKeyboardRequest)reader.ReadUInt32();

            long remaining;

            Logger.Debug?.Print(LogClass.ServiceAm, $"Keyboard received command {request} in state {_backgroundState}");

            switch (request)
            {
                case InlineKeyboardRequest.UseChangedStringV2:
                    Logger.Stub?.Print(LogClass.ServiceAm, "Inline keyboard request UseChangedStringV2");
                    break;
                case InlineKeyboardRequest.UseMovedCursorV2:
                    Logger.Stub?.Print(LogClass.ServiceAm, "Inline keyboard request UseMovedCursorV2");
                    break;
                case InlineKeyboardRequest.SetUserWordInfo:
                    // Read the user word info data.
                    remaining = stream.Length - stream.Position;
                    if (remaining < sizeof(int))
                    {
                        Logger.Warning?.Print(LogClass.ServiceAm, $"Received invalid Software Keyboard User Word Info of {remaining} bytes");
                    }
                    else
                    {
                        int wordsCount = reader.ReadInt32();
                        int wordSize = Unsafe.SizeOf<SoftwareKeyboardUserWord>();
                        remaining = stream.Length - stream.Position;

                        // 负的词数（审计 P2-255）：同超上限，打警告照常回包；否则乘积为负、过了下面的长度检查，new 负长度数组抛异常、回包前就断
                        if (wordsCount < 0 || wordsCount > MaxUserWords)
                        {
                            Logger.Warning?.Print(LogClass.ServiceAm, $"Received {wordsCount} User Words but the maximum is {MaxUserWords}");
                        }
                        // 游戏常把词表放在定长缓冲里发（怪物猎人 崛起：14 个词、4088 字节），词后面是填充：够装下 wordsCount 个词就收，只拒放不下的
                        else if (wordsCount * wordSize > remaining)
                        {
                            Logger.Warning?.Print(LogClass.ServiceAm, $"Received invalid Software Keyboard User Word Info data of {remaining} bytes for {wordsCount} words");
                        }
                        else
                        {
                            _keyboardBackgroundUserWords = new SoftwareKeyboardUserWord[wordsCount];

                            for (int word = 0; word < wordsCount; word++)
                            {
                                _keyboardBackgroundUserWords[word] = reader.ReadStruct<SoftwareKeyboardUserWord>();
                            }
                        }
                    }

                    _interactiveSession.Push(InlineResponses.ReleasedUserWordInfo(_backgroundState));
                    break;
                case InlineKeyboardRequest.SetCustomizeDic:
                    // Read the custom dic data.
                    remaining = stream.Length - stream.Position;
                    if (remaining != Unsafe.SizeOf<SoftwareKeyboardCustomizeDic>())
                    {
                        Logger.Warning?.Print(LogClass.ServiceAm, $"Received invalid Software Keyboard Customize Dic of {remaining} bytes");
                    }
                    else
                    {
                        _keyboardBackgroundDic = reader.ReadStruct<SoftwareKeyboardCustomizeDic>();
                    }

                    break;
                case InlineKeyboardRequest.SetCustomizedDictionaries:
                    // Read the custom dictionaries data.
                    remaining = stream.Length - stream.Position;
                    if (remaining != Unsafe.SizeOf<SoftwareKeyboardDictSet>())
                    {
                        Logger.Warning?.Print(LogClass.ServiceAm, $"Received invalid Software Keyboard DictSet of {remaining} bytes");
                    }
                    else
                    {
                        _keyboardBackgroundDictSet = reader.ReadStruct<SoftwareKeyboardDictSet>();
                    }

                    break;
                case InlineKeyboardRequest.UnsetCustomizedDictionaries:
                    // S2Arm: 回专门的 UnsetCustomizedDictionaries 回包（原先落到 default 回 Default：怪物猎人 崛起每次重开键盘前都发，日志报「Invalid request」）
                    _keyboardBackgroundDictSet = default;
                    _interactiveSession.Push(InlineResponses.UnsetCustomizedDictionaries(_backgroundState));
                    break;
                case InlineKeyboardRequest.Calc:
                    // The Calc request is used to communicate configuration changes and commands to the keyboard.
                    // Fields in the Calc struct and operations are masked by the Flags field.

                    // Read the Calc data.
                    SoftwareKeyboardCalcEx newCalc;
                    remaining = stream.Length - stream.Position;
                    if (remaining == Marshal.SizeOf<SoftwareKeyboardCalc>())
                    {
                        byte[] keyboardCalcData = reader.ReadBytes((int)remaining);
                        SoftwareKeyboardCalc keyboardCalc = ReadStruct<SoftwareKeyboardCalc>(keyboardCalcData);

                        newCalc = keyboardCalc.ToExtended();
                    }
                    else if (remaining == Marshal.SizeOf<SoftwareKeyboardCalcEx>() || remaining == SoftwareKeyboardCalcEx.AlternativeSize)
                    {
                        byte[] keyboardCalcData = reader.ReadBytes((int)remaining);

                        newCalc = ReadStruct<SoftwareKeyboardCalcEx>(keyboardCalcData);
                    }
                    else
                    {
                        Logger.Error?.Print(LogClass.ServiceAm, $"Received invalid Software Keyboard Calc of {remaining} bytes");

                        newCalc = new SoftwareKeyboardCalcEx();
                    }

                    // Process each individual operation specified in the flags.

                    bool updateText = false;

                    if (_headless && newCalc.Flags != _lastCalcFlags)
                    {
                        _lastCalcFlags = newCalc.Flags;
                        Logger.Info?.Print(LogClass.ServiceAm, $"Inline keyboard Calc flags 0x{(ulong)newCalc.Flags:x} in state {_backgroundState}");
                    }

                    if ((newCalc.Flags & KeyboardCalcFlags.Initialize) != 0)
                    {
                        _interactiveSession.Push(InlineResponses.FinishedInitialize(_backgroundState));

                        _backgroundState = InlineKeyboardState.Initialized;
                    }

                    if ((newCalc.Flags & KeyboardCalcFlags.SetCursorPos) != 0)
                    {
                        _cursorBegin = newCalc.CursorPos;
                        updateText = true;

                        Logger.Debug?.Print(LogClass.ServiceAm, $"Cursor position set to {_cursorBegin}");
                    }

                    if ((newCalc.Flags & KeyboardCalcFlags.SetInputText) != 0)
                    {
                        _textValue = newCalc.InputText;
                        _cursorBegin = _textValue.Length;
                        updateText = true;

                        Logger.Debug?.Print(LogClass.ServiceAm, $"Input text set to {_textValue}");
                    }

                    if ((newCalc.Flags & KeyboardCalcFlags.SetUtf8Mode) != 0)
                    {
                        _encoding = newCalc.UseUtf8 ? Encoding.UTF8 : Encoding.Default;

                        Logger.Debug?.Print(LogClass.ServiceAm, $"Encoding set to {_encoding}");
                    }

                    if (updateText)
                    {
                        _dynamicTextInputHandler?.SetText(_textValue, _cursorBegin);
                        _keyboardRenderer?.UpdateTextState(_textValue, _cursorBegin, _cursorBegin, null, null);
                    }

                    if ((newCalc.Flags & KeyboardCalcFlags.MustShow) != 0)
                    {
                        ActivateFrontend();

                        _backgroundState = InlineKeyboardState.Shown;

                        PushChangedString(_textValue, (uint)_cursorBegin, _backgroundState);
                    }

                    // Send the response to the Calc
                    _interactiveSession.Push(InlineResponses.Default(_backgroundState));

                    if (_headless && _backgroundState == InlineKeyboardState.Shown)
                    {
                        SoftwareKeyboardAppearEx a = newCalc.Appear;
                        int max = a.TextMaxLength > 0 ? Math.Min(a.TextMaxLength, MaxUiTextSize) : MaxUiTextSize;
                        SoftwareKeyboardUIArgs args = new() { KeyboardMode = a.KeyboardMode, InitialText = _textValue, StringLengthMin = a.TextMinLength, StringLengthMax = max };

                        // S2Arm: a host with its own text input shows it once per appearance (later Calcs while it is open keep it)
                        //   and the answer is handed over when the player confirms; the game keeps running and polling meanwhile
                        if (_hostInput != null)
                        {
                            break;
                        }

                        if (_device.UIHandler is IAsyncTextInput input && BeginInlineInput(input, args, a.TextMinLength, max))
                        {
                            break;
                        }
                        bool ok = _device.UIHandler.DisplayInputDialog(args, out string text);
                        text = FitLength(text ?? _textValue ?? string.Empty, a.TextMinLength, max);
                        int answer = ++_headlessAnswer;

                        // A real keyboard's input arrives frames after the game has seen it Shown, never in the same batch as the
                        // Appear reply: hand the answer over once the appear has settled, unless the game moved on meanwhile
                        _ = Task.Delay(AnswerDelayMs).ContinueWith(_ =>
                        {
                            lock (_lock)
                            {
                                if (answer != _headlessAnswer || _backgroundState != InlineKeyboardState.Shown)
                                {
                                    return;
                                }

                                PushHostAnswer(text, ok);
                            }
                        }, TaskScheduler.Default);
                    }
                    break;
                case InlineKeyboardRequest.Finalize:
                    if (_headless)
                    {
                        Logger.Info?.Print(LogClass.ServiceAm, $"Inline keyboard Finalize in state {_backgroundState}");
                    }

                    // S2Arm: the game closes the keyboard: the host's text input goes away with it
                    DismissHostInput();
                    // Destroy the frontend.
                    DestroyFrontend();
                    // The calling application wants to close the keyboard applet and will wait for a state change.
                    _backgroundState = InlineKeyboardState.Uninitialized;
                    AppletStateChanged?.Invoke(this, null);
                    break;
                default:
                    // We shouldn't be able to get here through standard swkbd execution.
                    Logger.Warning?.Print(LogClass.ServiceAm, $"Invalid Software Keyboard request {request} during state {_backgroundState}");
                    _interactiveSession.Push(InlineResponses.Default(_backgroundState));
                    break;
            }
        }

        // S2Arm: the host's answer to the inline keyboard arrives whole (system text input / unattended answer). A real keyboard reports
        //   every edit as ChangedString before the decision, and a game may keep its text from those replies and take DecidedEnter only
        //   as "done": GRID Autosport (iPhone, 11-07) left its name fields at the default / empty with DecidedEnter alone and filled them
        //   once the final text was reported first. The V1 form is sent even when the game asked for V2 (UseChangedStringV2), as the
        //   rest of this applet does (see PushChangedString). Called with _lock held
        //   The decision then follows DecidedAfterChangedMs later, never in the same batch as the ChangedString: a real keyboard's last
        //   edit and the Enter press are frames apart, and Monster Hunter Rise (Mac, #279) copies the text into its name field on the
        //   frame it sees ChangedString — with both in one batch it took DecidedEnter first, kept the field empty and reopened the keyboard
        private void PushHostAnswer(string text, bool ok)
        {
            bool changed = ok && IsKeyboardActive();
            Logger.Info?.Print(LogClass.ServiceAm, $"S2A 软键盘：交回游戏{(ok ? "确定" : "取消")}「{text}」（状态 {_backgroundState}，编码 {(_encoding == Encoding.UTF8 ? "UTF-8" : "UTF-16")}，先报改字 {(changed ? "是" : "否")}）");
            if (!changed)
            {
                PushUpdatedState(text, text.Length, ok ? KeyboardResult.Accept : KeyboardResult.Cancel);
                return;
            }

            PushChangedString(text, (uint)text.Length, _backgroundState);
            _textValue = text;
            int answer = _headlessAnswer;
            _ = Task.Delay(DecidedAfterChangedMs).ContinueWith(_ =>
            {
                lock (_lock)
                {
                    // 这期间游戏关了 / 重开了键盘：这次的确定作废（不往新的一轮里塞旧答案）
                    if (answer != _headlessAnswer || _backgroundState != InlineKeyboardState.Shown)
                    {
                        return;
                    }

                    PushUpdatedState(text, text.Length, KeyboardResult.Accept);
                }
            }, TaskScheduler.Default);
        }

        // S2Arm: inline keyboard answered by the host's system text input (IAsyncTextInput). Called with _lock held (Calc)
        private bool BeginInlineInput(IAsyncTextInput input, SoftwareKeyboardUIArgs args, int min, int max)
        {
            int answer = ++_headlessAnswer;
            long shown = Stopwatch.GetTimestamp();
            string initial = _textValue ?? string.Empty;
            IDisposable handle = input.BeginTextInput(args, (ok, text) =>
            {
                Task.Delay(RemainingDelay(shown)).ContinueWith(_ =>
                {
                    lock (_lock)
                    {
                        if (answer != _headlessAnswer || _backgroundState != InlineKeyboardState.Shown)
                        {
                            return;
                        }

                        _hostInput = null;
                        string value = FitLength((ok ? text : null) ?? initial, min, max);
                        PushHostAnswer(value, ok);
                    }
                }, TaskScheduler.Default);
            });

            if (handle == null)
            {
                return false;
            }

            _hostInput = handle;
            return true;
        }

        // S2Arm: the host's answer must fit the game's limits (foreground config / inline Appear): repeat the text up to the minimum
        // (no separator, so the result stays in the text's own character set: a numeric field stays digits), cut at the maximum
        internal static string FitLength(string text, int min, int max)
        {
            if (text.Length > 0)
            {
                while (text.Length < min)
                {
                    text += text;
                }
            }

            return max > 0 && text.Length > max ? text[..max] : text;
        }

        private void ActivateFrontend()
        {
            if (_headless)
            {
                return;
            }

            Logger.Debug?.Print(LogClass.ServiceAm, "Activating software keyboard frontend");

            _inputMode = KeyboardInputMode.ControllerAndKeyboard;

            _npads.Update(true);

            NpadButton buttons = _npads.GetCurrentButtonsOfAllNpads();

            // Block the input if the current accept key is pressed so the applet won't be instantly closed.
            _canAcceptController = (buttons & NpadButton.A) == 0;

            _dynamicTextInputHandler.TextProcessingEnabled = true;

            _keyboardRenderer.UpdateCommandState(null, null, true);
            _keyboardRenderer.UpdateTextState(null, null, null, null, true);
        }

        private void DeactivateFrontend()
        {
            if (_headless)
            {
                return;
            }

            Logger.Debug?.Print(LogClass.ServiceAm, "Deactivating software keyboard frontend");

            _inputMode = KeyboardInputMode.ControllerAndKeyboard;
            _canAcceptController = false;

            _dynamicTextInputHandler.TextProcessingEnabled = false;
            _dynamicTextInputHandler.SetText(_textValue, _cursorBegin);
        }

        private void DestroyFrontend()
        {
            Logger.Debug?.Print(LogClass.ServiceAm, "Destroying software keyboard frontend");

            _keyboardRenderer?.Dispose();
            _keyboardRenderer = null;

            if (_dynamicTextInputHandler != null)
            {
                _dynamicTextInputHandler.TextChangedEvent -= HandleTextChangedEvent;
                _dynamicTextInputHandler.KeyPressedEvent -= HandleKeyPressedEvent;
                _dynamicTextInputHandler.Dispose();
                _dynamicTextInputHandler = null;
            }

            if (_npads != null)
            {
                _npads.NpadButtonDownEvent -= HandleNpadButtonDownEvent;
                _npads.NpadButtonUpEvent -= HandleNpadButtonUpEvent;
                _npads = null;
            }
        }

        private bool HandleKeyPressedEvent(Key key)
        {
            if (key == CycleInputModesKey)
            {
                lock (_lock)
                {
                    if (IsKeyboardActive())
                    {
                        AdvanceInputMode();

                        bool typingEnabled = InputModeTypingEnabled();
                        bool controllerEnabled = InputModeControllerEnabled();

                        _dynamicTextInputHandler.TextProcessingEnabled = typingEnabled;

                        _keyboardRenderer.UpdateTextState(null, null, null, null, typingEnabled);
                        _keyboardRenderer.UpdateCommandState(null, null, controllerEnabled);
                    }
                }
            }

            return true;
        }

        private void HandleTextChangedEvent(string text, int cursorBegin, int cursorEnd, bool overwriteMode)
        {
            lock (_lock)
            {
                // Text processing should not run with typing disabled.
                Debug.Assert(InputModeTypingEnabled());

                if (text.Length > MaxUiTextSize)
                {
                    // Limit the text size and change it back.
                    text = text[..MaxUiTextSize];
                    cursorBegin = Math.Min(cursorBegin, MaxUiTextSize);
                    cursorEnd = Math.Min(cursorEnd, MaxUiTextSize);

                    _dynamicTextInputHandler.SetText(text, cursorBegin, cursorEnd);
                }

                _textValue = text;
                _cursorBegin = cursorBegin;
                _keyboardRenderer.UpdateTextState(text, cursorBegin, cursorEnd, overwriteMode, null);

                PushUpdatedState(text, cursorBegin, KeyboardResult.NotSet);
            }
        }

        private void HandleNpadButtonDownEvent(int npadIndex, NpadButton button)
        {
            lock (_lock)
            {
                if (!IsKeyboardActive())
                {
                    return;
                }

                switch (button)
                {
                    case NpadButton.A:
                        _keyboardRenderer.UpdateCommandState(_canAcceptController, null, null);
                        break;
                    case NpadButton.B:
                        _keyboardRenderer.UpdateCommandState(null, _canAcceptController, null);
                        break;
                }
            }
        }

        private void HandleNpadButtonUpEvent(int npadIndex, NpadButton button)
        {
            lock (_lock)
            {
                KeyboardResult result = KeyboardResult.NotSet;

                switch (button)
                {
                    case NpadButton.A:
                        result = KeyboardResult.Accept;
                        _keyboardRenderer.UpdateCommandState(false, null, null);
                        break;
                    case NpadButton.B:
                        result = KeyboardResult.Cancel;
                        _keyboardRenderer.UpdateCommandState(null, false, null);
                        break;
                }

                if (IsKeyboardActive())
                {
                    if (!_canAcceptController)
                    {
                        _canAcceptController = true;
                    }
                    else if (InputModeControllerEnabled())
                    {
                        PushUpdatedState(_textValue, _cursorBegin, result);
                    }
                }
            }
        }

        private void PushUpdatedState(string text, int cursorBegin, KeyboardResult result)
        {
            _lastResult = result;
            _textValue = text;

            bool cancel = result == KeyboardResult.Cancel;
            bool accept = result == KeyboardResult.Accept;

            if (!IsKeyboardActive())
            {
                // Keyboard is not active.

                return;
            }

            if (accept == false && cancel == false)
            {
                Logger.Debug?.Print(LogClass.ServiceAm, $"Updating keyboard text to {text} and cursor position to {cursorBegin}");

                PushChangedString(text, (uint)cursorBegin, _backgroundState);
            }
            else
            {
                // Disable the frontend.
                DeactivateFrontend();

                // The 'Complete' state indicates the Calc request has been fulfilled by the applet.
                _backgroundState = InlineKeyboardState.Disappearing;

                if (accept)
                {
                    Logger.Debug?.Print(LogClass.ServiceAm, $"Sending keyboard OK with text {text}");

                    DecidedEnter(text, _backgroundState);
                }
                else if (cancel)
                {
                    Logger.Debug?.Print(LogClass.ServiceAm, "Sending keyboard Cancel");

                    DecidedCancel(_backgroundState);
                }

                _interactiveSession.Push(InlineResponses.Default(_backgroundState));

                Logger.Debug?.Print(LogClass.ServiceAm, $"Resetting state of the keyboard to {_backgroundState}");

                // Set the state of the applet to 'Initialized' as it is the only known state so far
                // that does not soft-lock the keyboard after use.

                _backgroundState = InlineKeyboardState.Initialized;

                _interactiveSession.Push(InlineResponses.Default(_backgroundState));
            }
        }

        private void PushChangedString(string text, uint cursor, InlineKeyboardState state)
        {
            // TODO (Caian): The *V2 methods are not supported because the applications that request
            // them do not seem to accept them. The regular methods seem to work just fine in all cases.

            if (_encoding == Encoding.UTF8)
            {
                _interactiveSession.Push(InlineResponses.ChangedStringUtf8(text, cursor, state));
            }
            else
            {
                _interactiveSession.Push(InlineResponses.ChangedString(text, cursor, state));
            }
        }

        private void DecidedEnter(string text, InlineKeyboardState state)
        {
            if (_encoding == Encoding.UTF8)
            {
                _interactiveSession.Push(InlineResponses.DecidedEnterUtf8(text, state));
            }
            else
            {
                _interactiveSession.Push(InlineResponses.DecidedEnter(text, state));
            }
        }

        private void DecidedCancel(InlineKeyboardState state)
        {
            _interactiveSession.Push(InlineResponses.DecidedCancel(state));
        }

        private void PushForegroundResponse(bool interactive)
        {
            int bufferSize = interactive ? InteractiveBufferSize : StandardBufferSize;

            using MemoryStream stream = new(new byte[bufferSize]);
            using BinaryWriter writer = new(stream);
            byte[] output = _encoding.GetBytes(_textValue);

            if (!interactive)
            {
                // Result Code.
                writer.Write(_lastResult == KeyboardResult.Accept ? 0U : 1U);
            }
            else
            {
                // In interactive mode, we write the length of the text as a long, rather than
                // a result code. This field is inclusive of the 64-bit size.
                writer.Write((long)output.Length + 8);
            }

            writer.Write(output);

            if (!interactive)
            {
                _normalSession.Push(stream.ToArray());
            }
            else
            {
                _interactiveSession.Push(stream.ToArray());
            }
        }

        /// <summary>
        /// Removes all Unicode control code characters from the input string.
        /// This includes CR/LF, tabs, null characters, escape characters,
        /// and special control codes which are used for formatting by the real keyboard applet.
        /// </summary>
        /// <remarks>
        /// Some games send special control codes (such as 0x13 "Device Control 3") as part of the string.
        /// Future implementations of the emulated keyboard applet will need to handle these as well.
        /// </remarks>
        /// <param name="input">The input string to sanitize (may be null).</param>
        /// <returns>The sanitized string.</returns>
        internal static string StripUnicodeControlCodes(string input)
        {
            if (input is null)
            {
                return null;
            }

            if (input.Length == 0)
            {
                return string.Empty;
            }

            StringBuilder sb = new(capacity: input.Length);
            foreach (char c in input)
            {
                if (!char.IsControl(c))
                {
                    sb.Append(c);
                }
            }

            return sb.ToString();
        }

        private static T ReadStruct<[DynamicallyAccessedMembers(DynamicallyAccessedMemberTypes.PublicConstructors | DynamicallyAccessedMemberTypes.NonPublicConstructors)] T>(byte[] data)
            where T : struct
        {
            GCHandle handle = GCHandle.Alloc(data, GCHandleType.Pinned);

            try
            {
                return Marshal.PtrToStructure<T>(handle.AddrOfPinnedObject());
            }
            finally
            {
                handle.Free();
            }
        }
    }
}
