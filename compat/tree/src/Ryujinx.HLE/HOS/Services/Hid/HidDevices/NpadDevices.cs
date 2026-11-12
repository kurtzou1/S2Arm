using Ryujinx.Common;
using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.HLE.HOS.Services.Hid.Types;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.Common;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.Npad;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.CompilerServices;

namespace Ryujinx.HLE.HOS.Services.Hid
{
    public class NpadDevices : BaseDevice
    {
        private const int NoMatchNotifyFrequencyMs = 2000;
        private int _activeCount;
        private long _lastNotifyTimestamp;

        public const int MaxControllers = 9; // Players 1-8 and Handheld
        private ControllerType[] _configuredTypes;
        private readonly KEvent[] _styleSetUpdateEvents;
        private readonly bool[] _supportedPlayers;
        private VibrationValue _neutralVibrationValue = new()
        {
            AmplitudeLow = 0f,
            FrequencyLow = 160f,
            AmplitudeHigh = 0f,
            FrequencyHigh = 320f,
        };

        internal NpadJoyHoldType JoyHold { get; set; }
        private readonly HashSet<(long UserId, int Handle)> _sixAxisSensors = new();
        public bool SixAxisActive { get { lock (_sixAxisSensors) return _sixAxisSensors.Count != 0; } }

        // S2Arm：Switch 2 Npad IMU 缓冲（hid 320 / 321，见 NpadImu.cs）；读数与六轴同源，由宿主的体感读取一并写入
        public readonly NpadImu Imu = new();

        // S2Arm：Joy-Con 2 光学鼠标传感器缓冲（hid 3110–3113，见 NpadJcms.cs）；由宿主的 Joy-Con 2 鼠标读取写入
        public readonly NpadJcms Jcms = new();

        // sensor：双 Joy-Con 左右各有读数时 0 = 左只、1 = 右只；-1 = 单一体感源（NpadImu.Push）
        public void PushImu(PlayerIndex player, System.Numerics.Vector3 accelerationG, System.Numerics.Vector3 angularVelocityDegrees, ulong timestampUs, int sensor = -1)
        {
            bool joyDual = player <= PlayerIndex.Handheld && Base(_device.Hid.SharedMemory.Npads[(int)player].InternalState.StyleSet) == NpadStyleTag.JoyDual;

            Imu.Push(player, joyDual, accelerationG, angularVelocityDegrees, timestampUs, sensor);
        }

        public void SetSixAxisActive(long userId, int handle, bool active)
        {
            lock (_sixAxisSensors)
            {
                if (active) _sixAxisSensors.Add((userId, handle));
                else _sixAxisSensors.Remove((userId, handle));
            }
        }
        // 游戏声明收哪些样式（SetSupportedNpadStyleSet）。S2Arm：连着 Joy-Con 2 时，声明里 Joy-Con 2 位的有无一变就重配一遍，
        //   让刚声明只收 Joy-Con 2 的游戏拿到 Joy-Con 2 位（样式值只在游戏声明了这几位时才带，见 Joycon2StyleFor）
        internal ControllerType SupportedStyleSets
        {
            get => _supportedStyleSets;
            set
            {
                bool before = ((uint)_supportedStyleSets & (uint)Joycon2Bits) != 0, after = ((uint)value & (uint)Joycon2Bits) != 0;
                _supportedStyleSets = value;
                if (Joycon2 && before != after) Remap();
            }
        }
        private ControllerType _supportedStyleSets;

        // S2Arm：Joy-Con 2 的样式位。随游戏 SDK 的手柄分派（读 GetNpadStyleSet）把 bit 12 / 13 / 14 当成 JoyDual / JoyLeft / JoyRight 一样读，
        //   即 Joy-Con 2 的一对 / 左只 / 右只；只收 Joy-Con 2 的场景游戏只声明这几位（例：掌机 | bit 12），一代样式的手柄就被提示「请重新连接 Joy-Con 2」。
        //   连着的实体手柄是 Joy-Con 2 时（宿主报的型号，见 SetJoycon2），样式在一代位之外再加对应的 Joy-Con 2 位；内部按一代位走（Base）
        internal const NpadStyleTag JoyDual2 = (NpadStyleTag)(1 << 12), JoyLeft2 = (NpadStyleTag)(1 << 13), JoyRight2 = (NpadStyleTag)(1 << 14);
        private const NpadStyleTag Joycon2Bits = JoyDual2 | JoyLeft2 | JoyRight2;
        public bool Joycon2 { get; private set; }

        // 这一格现在的样式（共享内存里的值，含 Joy-Con 2 位）
        internal NpadStyleTag StyleOf(PlayerIndex player) => _device.Hid.SharedMemory.Npads[(int)player].InternalState.StyleSet;

        // 去掉 Joy-Con 2 位（只剩一代样式），供内部按样式分派
        internal static NpadStyleTag Base(NpadStyleTag style) => style & ~Joycon2Bits;

        // 一代样式对应的 Joy-Con 2 位（不是 Joy-Con 2 / 不是 Joy-Con 样式时 None）
        internal NpadStyleTag Joycon2Style(ControllerType type) => !Joycon2 ? NpadStyleTag.None : type switch
        {
            ControllerType.JoyconPair => JoyDual2,
            ControllerType.JoyconLeft => JoyLeft2,
            ControllerType.JoyconRight => JoyRight2,
            _ => NpadStyleTag.None,
        };

        // 共享内存里样式值要带的 Joy-Con 2 位：只给声明了 Joy-Con 2 位的游戏。没声明的（Switch 1 游戏）样式值保持一代原样——
        //   按整值比较样式的老游戏不会把 JoyDual 加一个它不认识的位当成别的手柄（合入时补，同真机：应用只看到自己声明过的样式）
        internal NpadStyleTag Joycon2StyleFor(ControllerType type) =>
            ((uint)SupportedStyleSets & (uint)Joycon2Bits) != 0 ? Joycon2Style(type) : NpadStyleTag.None;

        // 游戏声明收不收这一样式：一代位，或（连着 Joy-Con 2 时）对应的 Joy-Con 2 位
        public bool StyleSupported(ControllerType type, ControllerType supported) =>
            (type & supported) != 0 || ((uint)Joycon2Style(type) & (uint)supported) != 0;

        // 宿主报连着的实体手柄是不是 Joy-Con 2；变了就重新配一遍（样式位跟着变，游戏收到样式更新事件）
        public void SetJoycon2(bool joycon2)
        {
            if (Joycon2 == joycon2)
            {
                return;
            }

            Joycon2 = joycon2;
            Logger.Info?.Print(LogClass.Hid, $"Joy-Con 2 style bits {(joycon2 ? "on" : "off")}");
            Remap();
        }

        public Dictionary<PlayerIndex, ConcurrentQueue<(VibrationValue, VibrationValue)>> RumbleQueues = new();
        public Dictionary<PlayerIndex, (VibrationValue, VibrationValue)> LastVibrationValues = new();
        private readonly object _rumbleLock = new();
        // Output hooks run under this same lock. They must not call back from native code or wait for transport IO.
        public object RumbleSyncRoot => _rumbleLock;
        public Action RumbleBeforeAccepted;
        public Action<PlayerIndex, VibrationValue, VibrationValue> RumbleAccepted;
        public Action<bool> RumblePermissionChanged;
        private bool _vibrationPermitted = true;
        public bool VibrationPermitted { get { lock (_rumbleLock) return _vibrationPermitted; } }

        public void SetVibrationPermitted(bool permitted)
        {
            lock (_rumbleLock)
            {
                if (_vibrationPermitted == permitted) return;
                _vibrationPermitted = permitted;
                LastVibrationValues.Clear();
                RumblePermissionChanged?.Invoke(permitted);
                if (!permitted) foreach (var queue in RumbleQueues.Values)
                {
                    while (queue.TryDequeue(out _)) { }
                    queue.Enqueue((_neutralVibrationValue, _neutralVibrationValue));
                }
            }
        }

        public NpadDevices(Switch device, bool active = true) : base(device, active)
        {
            _configuredTypes = new ControllerType[MaxControllers];

            SupportedStyleSets = ControllerType.Handheld | ControllerType.JoyconPair |
                                 ControllerType.JoyconLeft | ControllerType.JoyconRight |
                                 ControllerType.ProController;

            _supportedPlayers = new bool[MaxControllers];
            _supportedPlayers.AsSpan().Fill(true);

            _styleSetUpdateEvents = new KEvent[MaxControllers];
            for (int i = 0; i < _styleSetUpdateEvents.Length; ++i)
            {
                _styleSetUpdateEvents[i] = new KEvent(_device.System.KernelContext);
            }

            _activeCount = 0;

            JoyHold = NpadJoyHoldType.Vertical;
        }

        internal ref KEvent GetStyleSetUpdateEvent(PlayerIndex player)
        {
            // S2Arm: 手柄号越界（Unknown = 9 / Auto = 10 / 乱值）钳到掌机号，不再越界抛 IndexOutOfRangeException 带走整局
            int i = (int)player;

            if ((uint)i >= (uint)_styleSetUpdateEvents.Length)
            {
                i = (int)PlayerIndex.Handheld;
            }

            return ref _styleSetUpdateEvents[i];
        }

        internal void ClearSupportedPlayers()
        {
            _supportedPlayers.AsSpan().Clear();
        }

        internal void SetSupportedPlayer(PlayerIndex player, bool supported = true)
        {
            if ((uint)player >= _supportedPlayers.Length)
            {
                return;
            }

            _supportedPlayers[(int)player] = supported;
        }

        // S2A：输入泵每 250 ms 查游戏收不收掌机格 / Player1（不分配，GetSupportedPlayers 是迭代器）
        internal bool IsSupportedPlayer(PlayerIndex player) => (uint)player < (uint)_supportedPlayers.Length && _supportedPlayers[(int)player];

        internal IEnumerable<PlayerIndex> GetSupportedPlayers()
        {
            for (int i = 0; i < _supportedPlayers.Length; ++i)
            {
                if (_supportedPlayers[i])
                {
                    yield return (PlayerIndex)i;
                }
            }
        }

        public bool Validate(int playerMin, int playerMax, ControllerType acceptedTypes, out int configuredCount, out PlayerIndex primaryIndex)
        {
            primaryIndex = PlayerIndex.Unknown;
            configuredCount = 0;

            Span<NpadState> nPadsSpan = _device.Hid.SharedMemory.Npads.AsSpan();

            for (int i = 0; i < MaxControllers; ++i)
            {
                ControllerType npad = _configuredTypes[i];

                if (npad == ControllerType.Handheld && _device.System.State.DockedMode)
                {
                    continue;
                }

                ControllerType currentType = (ControllerType)Base(nPadsSpan[i].InternalState.StyleSet);

                if (currentType != ControllerType.None && StyleSupported(npad, acceptedTypes) && _supportedPlayers[i])   // S2Arm：连着 Joy-Con 2 时只收 Joy-Con 2 位也算（手柄设置小程序原先判不收、游戏反复重开）
                {
                    configuredCount++;
                    if (primaryIndex == PlayerIndex.Unknown)
                    {
                        primaryIndex = (PlayerIndex)i;
                    }
                }
            }

            if (configuredCount < playerMin || configuredCount > playerMax || primaryIndex == PlayerIndex.Unknown)
            {
                return false;
            }

            return true;
        }

        public void Configure(params ReadOnlySpan<ControllerConfig> configs)
        {
            _configuredTypes = new ControllerType[MaxControllers];

            for (int i = 0; i < configs.Length; ++i)
            {
                PlayerIndex player = configs[i].Player;
                ControllerType controllerType = configs[i].Type;

                if (player > PlayerIndex.Handheld)
                {
                    throw new InvalidOperationException("Player must be Player1-8 or Handheld");
                }

                if (controllerType == ControllerType.Handheld)
                {
                    player = PlayerIndex.Handheld;
                }

                _configuredTypes[(int)player] = controllerType;

                Logger.Info?.Print(LogClass.Hid, $"Configured Controller {controllerType} to {player}");
            }
        }

        public void Update(IList<GamepadInput> states)
        {
            Remap();

            Span<bool> updated = stackalloc bool[10];

            // Update configured inputs
            for (int i = 0; i < states.Count; ++i)
            {
                GamepadInput state = states[i];

                updated[(int)state.PlayerId] = true;

                UpdateInput(state);
            }

            for (int i = 0; i < updated.Length; i++)
            {
                if (!updated[i])
                {
                    UpdateDisconnectedInput((PlayerIndex)i);
                }
            }
        }

        private void Remap()
        {
            // Remap/Init if necessary
            for (int i = 0; i < MaxControllers; ++i)
            {
                ControllerType config = _configuredTypes[i];

                // Remove Handheld config when Docked
                if (config == ControllerType.Handheld && _device.System.State.DockedMode)
                {
                    config = ControllerType.None;
                }

                // Auto-remap ProController and JoyconPair
                if (config == ControllerType.JoyconPair && (SupportedStyleSets & ControllerType.JoyconPair) == 0 && (SupportedStyleSets & ControllerType.ProController) != 0)
                {
                    config = ControllerType.ProController;
                }
                else if (config == ControllerType.ProController && (SupportedStyleSets & ControllerType.ProController) == 0 && (SupportedStyleSets & ControllerType.JoyconPair) != 0)
                {
                    config = ControllerType.JoyconPair;
                }

                // Check StyleSet and PlayerSet（S2Arm：连着 Joy-Con 2 时，游戏只声明 Joy-Con 2 位也算收）
                if (!StyleSupported(config, SupportedStyleSets) || !_supportedPlayers[i])
                {
                    config = ControllerType.None;
                }

                SetupNpad((PlayerIndex)i, config);
            }

            if (_activeCount == 0 && PerformanceCounter.ElapsedMilliseconds > _lastNotifyTimestamp + NoMatchNotifyFrequencyMs)
            {
                Logger.Warning?.Print(LogClass.Hid, $"No matching controllers found. Application requests '{SupportedStyleSets}' on '{string.Join(", ", GetSupportedPlayers())}'");
                _lastNotifyTimestamp = PerformanceCounter.ElapsedMilliseconds;
            }
        }

        private void SetupNpad(PlayerIndex player, ControllerType type)
        {
            ref NpadInternalState controller = ref _device.Hid.SharedMemory.Npads[(int)player].InternalState;

            ControllerType oldType = (ControllerType)Base(controller.StyleSet);

            if (oldType == type && (controller.StyleSet & Joycon2Bits) == Joycon2StyleFor(type))
            {
                return; // Already configured
            }

            controller = NpadInternalState.Create(); // Reset it

            if (type == ControllerType.None)
            {
                _styleSetUpdateEvents[(int)player].ReadableEvent.Signal(); // Signal disconnect
                _activeCount--;

                Logger.Info?.Print(LogClass.Hid, $"Disconnected Controller {oldType} from {player}");

                return;
            }

            // TODO: Allow customizing colors at config
            controller.JoyAssignmentMode = NpadJoyAssignmentMode.Dual;
            controller.FullKeyColor.FullKeyBody = (uint)NpadColor.BodyGray;
            controller.FullKeyColor.FullKeyButtons = (uint)NpadColor.ButtonGray;
            controller.JoyColor.LeftBody = (uint)NpadColor.BodyNeonBlue;
            controller.JoyColor.LeftButtons = (uint)NpadColor.ButtonGray;
            controller.JoyColor.RightBody = (uint)NpadColor.BodyNeonRed;
            controller.JoyColor.RightButtons = (uint)NpadColor.ButtonGray;

            controller.SystemProperties = NpadSystemProperties.IsPoweredJoyDual |
                                          NpadSystemProperties.IsPoweredJoyLeft |
                                          NpadSystemProperties.IsPoweredJoyRight;

            controller.BatteryLevelJoyDual = NpadBatteryLevel.Percent100;
            controller.BatteryLevelJoyLeft = NpadBatteryLevel.Percent100;
            controller.BatteryLevelJoyRight = NpadBatteryLevel.Percent100;

            switch (type)
            {
#pragma warning disable IDE0055 // Disable formatting
                case ControllerType.ProController:
                    controller.StyleSet           = NpadStyleTag.FullKey;
                    controller.DeviceType         = DeviceType.FullKey;
                    controller.SystemProperties  |= NpadSystemProperties.IsAbxyButtonOriented |
                                                    NpadSystemProperties.IsPlusAvailable      |
                                                    NpadSystemProperties.IsMinusAvailable;
                    controller.AppletFooterUiType = AppletFooterUiType.SwitchProController;
                    break;
                case ControllerType.Handheld:
                    controller.StyleSet           = NpadStyleTag.Handheld;
                    controller.DeviceType         = DeviceType.HandheldLeft |
                                                    DeviceType.HandheldRight;
                    controller.SystemProperties  |= NpadSystemProperties.IsAbxyButtonOriented |
                                                    NpadSystemProperties.IsPlusAvailable      |
                                                    NpadSystemProperties.IsMinusAvailable;
                    controller.AppletFooterUiType = AppletFooterUiType.HandheldJoyConLeftJoyConRight;
                    break;
                case ControllerType.JoyconPair:
                    controller.StyleSet           = NpadStyleTag.JoyDual;
                    controller.DeviceType         = DeviceType.JoyLeft |
                                                    DeviceType.JoyRight;
                    controller.SystemProperties  |= NpadSystemProperties.IsAbxyButtonOriented |
                                                    NpadSystemProperties.IsPlusAvailable      |
                                                    NpadSystemProperties.IsMinusAvailable;
                    controller.AppletFooterUiType = _device.System.State.DockedMode ? AppletFooterUiType.JoyDual : AppletFooterUiType.HandheldJoyConLeftJoyConRight;
                    break;
                case ControllerType.JoyconLeft:
                    controller.StyleSet           = NpadStyleTag.JoyLeft;
                    controller.JoyAssignmentMode  = NpadJoyAssignmentMode.Single;
                    controller.DeviceType         = DeviceType.JoyLeft;
                    controller.SystemProperties  |= NpadSystemProperties.IsSlSrButtonOriented |
                                                    NpadSystemProperties.IsMinusAvailable;
                    controller.AppletFooterUiType = _device.System.State.DockedMode ? AppletFooterUiType.JoyDualLeftOnly : AppletFooterUiType.HandheldJoyConLeftOnly;
                    break;
                case ControllerType.JoyconRight:
                    controller.StyleSet           = NpadStyleTag.JoyRight;
                    controller.JoyAssignmentMode  = NpadJoyAssignmentMode.Single;
                    controller.DeviceType         = DeviceType.JoyRight;
                    controller.SystemProperties  |= NpadSystemProperties.IsSlSrButtonOriented |
                                                    NpadSystemProperties.IsPlusAvailable;
                    controller.AppletFooterUiType = _device.System.State.DockedMode ? AppletFooterUiType.JoyDualRightOnly : AppletFooterUiType.HandheldJoyConRightOnly;
                    break;
                case ControllerType.Pokeball:
                    controller.StyleSet           = NpadStyleTag.Palma;
                    controller.DeviceType         = DeviceType.Palma;
                    controller.AppletFooterUiType = AppletFooterUiType.None;
                    break;
#pragma warning restore IDE0055
            }

            controller.StyleSet |= Joycon2StyleFor(type);   // S2Arm：连着 Joy-Con 2、且游戏声明了 Joy-Con 2 位时加上对应的位

            _styleSetUpdateEvents[(int)player].ReadableEvent.Signal();
            _activeCount++;

            Logger.Info?.Print(LogClass.Hid, $"Connected Controller {type}{(Joycon2StyleFor(type) != NpadStyleTag.None ? " (Joy-Con 2)" : "")} to {player}");
        }

        private ref RingLifo<NpadCommonState> GetCommonStateLifo(ref NpadInternalState npad)
        {
            switch (Base(npad.StyleSet))
            {
                case NpadStyleTag.FullKey:
                    return ref npad.FullKey;
                case NpadStyleTag.Handheld:
                    return ref npad.Handheld;
                case NpadStyleTag.JoyDual:
                    return ref npad.JoyDual;
                case NpadStyleTag.JoyLeft:
                    return ref npad.JoyLeft;
                case NpadStyleTag.JoyRight:
                    return ref npad.JoyRight;
                case NpadStyleTag.Palma:
                    return ref npad.Palma;
                default:
                    return ref npad.SystemExt;
            }
        }

        private void UpdateUnusedInputIfNotEqual(ref RingLifo<NpadCommonState> currentlyUsed, ref RingLifo<NpadCommonState> possiblyUnused)
        {
            if (!Unsafe.AreSame(ref currentlyUsed, ref possiblyUnused))
            {
                NpadCommonState newState = new();

                WriteNewInputEntry(ref possiblyUnused, ref newState);
            }
        }

        private void WriteNewInputEntry(ref RingLifo<NpadCommonState> lifo, ref NpadCommonState state)
        {
            ref NpadCommonState previousEntry = ref lifo.GetCurrentEntryRef();

            state.SamplingNumber = previousEntry.SamplingNumber + 1;

            lifo.Write(ref state);
        }

        private void UpdateUnusedSixInputIfNotEqual(ref RingLifo<SixAxisSensorState> currentlyUsed, ref RingLifo<SixAxisSensorState> possiblyUnused, ref SixAxisSensorState used)
        {
            if (!Unsafe.AreSame(ref currentlyUsed, ref possiblyUnused))
            {
                SixAxisSensorState newState = used;   // S2Arm：单一体感源时其余样式的记录写同一份读数，不写全零（上游写全零）

                WriteNewSixInputEntry(ref possiblyUnused, ref newState);
            }
        }

        private void WriteNewSixInputEntry(ref RingLifo<SixAxisSensorState> lifo, ref SixAxisSensorState state)
        {
            ref SixAxisSensorState previousEntry = ref lifo.GetCurrentEntryRef();

            state.SamplingNumber = previousEntry.SamplingNumber + 1;

            lifo.Write(ref state);
        }

        private void UpdateInput(GamepadInput state)
        {
            if (state.PlayerId == PlayerIndex.Unknown)
            {
                return;
            }

            ref NpadInternalState currentNpad = ref _device.Hid.SharedMemory.Npads[(int)state.PlayerId].InternalState;

            if (currentNpad.StyleSet == NpadStyleTag.None)
            {
                return;
            }

            ref RingLifo<NpadCommonState> lifo = ref GetCommonStateLifo(ref currentNpad);

            NpadCommonState newState = new()
            {
                Buttons = (NpadButton)state.Buttons,
                AnalogStickL = new AnalogStickState
                {
                    X = state.LStick.Dx,
                    Y = state.LStick.Dy,
                },
                AnalogStickR = new AnalogStickState
                {
                    X = state.RStick.Dx,
                    Y = state.RStick.Dy,
                },
                Attributes = NpadAttribute.IsConnected,
            };

            switch (Base(currentNpad.StyleSet))
            {
                case NpadStyleTag.Handheld:
                    // S2Arm：掌机 = 左右两只 Joy-Con 都插在机身滑轨上，真机属性里左右各自「已连 + 有线」都置位。原先只给已连 + 有线，
                    //   网球 Aces 认掌机要求已连 + 左已连 + 右已连（main+0x252378），判手柄没就绪、每帧重拉手柄小程序，约 100 秒后游戏堆耗尽断言
                    newState.Attributes |= NpadAttribute.IsWired |
                                           NpadAttribute.IsLeftConnected | NpadAttribute.IsLeftWired |
                                           NpadAttribute.IsRightConnected | NpadAttribute.IsRightWired;
                    break;
                case NpadStyleTag.FullKey:
                    newState.Attributes |= NpadAttribute.IsWired;
                    break;
                case NpadStyleTag.JoyDual:
                    newState.Attributes |= NpadAttribute.IsLeftConnected |
                                           NpadAttribute.IsRightConnected;
                    break;
                case NpadStyleTag.JoyLeft:
                    newState.Attributes |= NpadAttribute.IsLeftConnected;
                    break;
                case NpadStyleTag.JoyRight:
                    newState.Attributes |= NpadAttribute.IsRightConnected;
                    break;
            }

            WriteNewInputEntry(ref lifo, ref newState);

            // Mirror data to Default layout just in case
            if (!currentNpad.StyleSet.HasFlag(NpadStyleTag.SystemExt))
            {
                WriteNewInputEntry(ref currentNpad.SystemExt, ref newState);
            }

            UpdateUnusedInputIfNotEqual(ref lifo, ref currentNpad.FullKey);
            UpdateUnusedInputIfNotEqual(ref lifo, ref currentNpad.Handheld);
            UpdateUnusedInputIfNotEqual(ref lifo, ref currentNpad.JoyDual);
            UpdateUnusedInputIfNotEqual(ref lifo, ref currentNpad.JoyLeft);
            UpdateUnusedInputIfNotEqual(ref lifo, ref currentNpad.JoyRight);
            UpdateUnusedInputIfNotEqual(ref lifo, ref currentNpad.Palma);
        }

        private void UpdateDisconnectedInput(PlayerIndex index)
        {
            ref NpadInternalState currentNpad = ref _device.Hid.SharedMemory.Npads[(int)index].InternalState;

            NpadCommonState newState = new();

            WriteNewInputEntry(ref currentNpad.FullKey, ref newState);
            WriteNewInputEntry(ref currentNpad.Handheld, ref newState);
            WriteNewInputEntry(ref currentNpad.JoyDual, ref newState);
            WriteNewInputEntry(ref currentNpad.JoyLeft, ref newState);
            WriteNewInputEntry(ref currentNpad.JoyRight, ref newState);
            WriteNewInputEntry(ref currentNpad.Palma, ref newState);
        }

        public void UpdateSixAxis(IList<SixAxisInput> states)
        {
            Span<bool> updated = stackalloc bool[10];

            for (int i = 0; i < states.Count; ++i)
            {
                updated[(int)states[i].PlayerId] = true;

                if (SetSixAxisState(states[i]))
                {
                    // S2Arm 11-05（#55 Switch Sports Joy-Con 校准「无法调整」）：双 Joy-Con 样式要一左一右两份读数；只有一个体感源（手机）时只来一份，
                    //   上游直接 return，右手那条记录从来不更新（全零），游戏校准两只 Joy-Con、右手那只永远失败。单一体感源 = 左右同一份读数
                    if (i + 1 >= states.Count || states[i + 1].PlayerId != states[i].PlayerId)
                    {
                        SetSixAxisState(states[i], true);
                        continue;
                    }

                    i++;
                    SetSixAxisState(states[i], true);
                }
            }

            for (int i = 0; i < updated.Length; i++)
            {
                if (!updated[i])
                {
                    UpdateDisconnectedInputSixAxis((PlayerIndex)i);
                }
            }
        }

        private ref RingLifo<SixAxisSensorState> GetSixAxisSensorLifo(ref NpadInternalState npad, bool isRightPair)
        {
            switch (Base(npad.StyleSet))
            {
                case NpadStyleTag.FullKey:
                    return ref npad.FullKeySixAxisSensor;
                case NpadStyleTag.Handheld:
                    return ref npad.HandheldSixAxisSensor;
                case NpadStyleTag.JoyDual:
                    if (isRightPair)
                    {
                        return ref npad.JoyDualRightSixAxisSensor;
                    }
                    else
                    {
                        return ref npad.JoyDualSixAxisSensor;
                    }
                case NpadStyleTag.JoyLeft:
                    return ref npad.JoyLeftSixAxisSensor;
                case NpadStyleTag.JoyRight:
                    return ref npad.JoyRightSixAxisSensor;
                default:
                    throw new NotImplementedException($"{npad.StyleSet}");
            }
        }

        private bool SetSixAxisState(SixAxisInput state, bool isRightPair = false)
        {
            if (state.PlayerId == PlayerIndex.Unknown)
            {
                return false;
            }

            ref NpadInternalState currentNpad = ref _device.Hid.SharedMemory.Npads[(int)state.PlayerId].InternalState;

            if (currentNpad.StyleSet == NpadStyleTag.None)
            {
                return false;
            }

            HidVector accel = new()
            {
                X = state.Accelerometer.X,
                Y = state.Accelerometer.Y,
                Z = state.Accelerometer.Z,
            };

            HidVector gyro = new()
            {
                X = state.Gyroscope.X,
                Y = state.Gyroscope.Y,
                Z = state.Gyroscope.Z,
            };

            HidVector rotation = new()
            {
                X = state.Rotation.X,
                Y = state.Rotation.Y,
                Z = state.Rotation.Z,
            };

            SixAxisSensorState newState = new()
            {
                Acceleration = accel,
                AngularVelocity = gyro,
                Angle = rotation,
                Attributes = SixAxisSensorAttribute.IsConnected,
            };

            state.Orientation.AsSpan().CopyTo(newState.Direction.AsSpan());

            ref RingLifo<SixAxisSensorState> lifo = ref GetSixAxisSensorLifo(ref currentNpad, isRightPair);

            WriteNewSixInputEntry(ref lifo, ref newState);

            bool needUpdateRight = Base(currentNpad.StyleSet) == NpadStyleTag.JoyDual && !isRightPair;

            if (!isRightPair)
            {
                UpdateUnusedSixInputIfNotEqual(ref lifo, ref currentNpad.FullKeySixAxisSensor, ref newState);
                UpdateUnusedSixInputIfNotEqual(ref lifo, ref currentNpad.HandheldSixAxisSensor, ref newState);
                UpdateUnusedSixInputIfNotEqual(ref lifo, ref currentNpad.JoyDualSixAxisSensor, ref newState);
                UpdateUnusedSixInputIfNotEqual(ref lifo, ref currentNpad.JoyLeftSixAxisSensor, ref newState);
                UpdateUnusedSixInputIfNotEqual(ref lifo, ref currentNpad.JoyRightSixAxisSensor, ref newState);
            }

            if (!needUpdateRight && !isRightPair)
            {
                SixAxisSensorState emptyState = newState;   // S2Arm：同上，双 Joy-Con 右手的记录也写同一份读数

                WriteNewSixInputEntry(ref currentNpad.JoyDualRightSixAxisSensor, ref emptyState);
            }

            return needUpdateRight;
        }
        
        public bool isAtRest(int playerNumber)
        {
            ref NpadInternalState currentNpad = ref _device.Hid.SharedMemory.Npads[playerNumber].InternalState;

            if (currentNpad.StyleSet == NpadStyleTag.None)
            {
                return true; // it will always be at rest because it cannot move.
            }
            
            ref SixAxisSensorState storage = ref GetSixAxisSensorLifo(ref currentNpad, false).GetCurrentEntryRef();
                
            float acceleration = Math.Abs(storage.Acceleration.X)
                                 + Math.Abs(storage.Acceleration.Y)
                                 + Math.Abs(storage.Acceleration.Z);

            float angularVelocity = Math.Abs(storage.AngularVelocity.X)
                                    + Math.Abs(storage.AngularVelocity.Y)
                                    + Math.Abs(storage.AngularVelocity.Z);

            // S2Arm 11-05：静止 = 只受重力（加速度模长 0.9–1.1 g）且几乎不转（三轴角速度绝对值和 ≤ 0.02 转/秒）。上游按「三轴加速度绝对值和 ≤ 1」判，
            //   平放静止时光重力就约 1 g（手机实测和 1.04），几乎永远判没静止
            float ax = storage.Acceleration.X, ay = storage.Acceleration.Y, az = storage.Acceleration.Z;
            float norm = MathF.Sqrt(ax * ax + ay * ay + az * az);
            _ = acceleration;
            return norm >= 0.9F && norm <= 1.1F && angularVelocity <= 0.02F;
        }

        private void UpdateDisconnectedInputSixAxis(PlayerIndex index)
        {
            ref NpadInternalState currentNpad = ref _device.Hid.SharedMemory.Npads[(int)index].InternalState;

            SixAxisSensorState newState = new()
            {
                Attributes = SixAxisSensorAttribute.IsConnected,
            };

            WriteNewSixInputEntry(ref currentNpad.FullKeySixAxisSensor, ref newState);
            WriteNewSixInputEntry(ref currentNpad.HandheldSixAxisSensor, ref newState);
            WriteNewSixInputEntry(ref currentNpad.JoyDualSixAxisSensor, ref newState);
            WriteNewSixInputEntry(ref currentNpad.JoyDualRightSixAxisSensor, ref newState);
            WriteNewSixInputEntry(ref currentNpad.JoyLeftSixAxisSensor, ref newState);
            WriteNewSixInputEntry(ref currentNpad.JoyRightSixAxisSensor, ref newState);
        }

        public void UpdateRumbleQueue(PlayerIndex index, Dictionary<byte, VibrationValue> dualVibrationValues)
        {
            lock (_rumbleLock)
            {
                if (RumbleAccepted == null && !RumbleQueues.ContainsKey(index)) return;
                if (!_vibrationPermitted) return;
                RumbleBeforeAccepted?.Invoke();
                if (!dualVibrationValues.TryGetValue(0, out VibrationValue leftVibrationValue))
                {
                    leftVibrationValue = GetLastVibrationValueLocked(index, 0);
                }

                if (!dualVibrationValues.TryGetValue(1, out VibrationValue rightVibrationValue))
                {
                    rightVibrationValue = GetLastVibrationValueLocked(index, 1);
                }

                UpdateRumbleQueue(index, leftVibrationValue, rightVibrationValue, prepared: true);
            }
        }

        // S2Arm: one vibration value at one position (IHidServer.SendVibrationValue), without the per-call dictionary
        // (10-21 d2r: ~70 calls per second, 232 B each, half of the game threads' remaining service allocations)
        public void UpdateRumbleQueue(PlayerIndex index, byte position, VibrationValue vibrationValue)
        {
            lock (_rumbleLock)
            {
                if (!_vibrationPermitted) return;
                // Check the output session before filling the unmodified side from the previous accepted pair.
                RumbleBeforeAccepted?.Invoke();
                UpdateRumbleQueue(index, position == 0 ? vibrationValue : GetLastVibrationValueLocked(index, 0),
                    position == 1 ? vibrationValue : GetLastVibrationValueLocked(index, 1), prepared: true);
            }
        }

        // A batch updates only its specified handles; retain an absent side from the same output session.
        public void UpdateRumbleQueue(PlayerIndex index, bool hasLeft, VibrationValue left, bool hasRight, VibrationValue right)
        {
            lock (_rumbleLock)
            {
                if (RumbleAccepted == null && !RumbleQueues.ContainsKey(index)) return;
                if (!_vibrationPermitted) return;
                RumbleBeforeAccepted?.Invoke();
                UpdateRumbleQueue(index, hasLeft ? left : GetLastVibrationValueLocked(index, 0),
                    hasRight ? right : GetLastVibrationValueLocked(index, 1), prepared: true);
            }
        }

        private void UpdateRumbleQueue(PlayerIndex index, VibrationValue leftVibrationValue, VibrationValue rightVibrationValue, bool prepared = false)
        {
            lock (_rumbleLock)
            {
                if (!_vibrationPermitted) return;
                if (!prepared) RumbleBeforeAccepted?.Invoke();
                if (RumbleAccepted != null)
                {
                    RumbleAccepted(index, leftVibrationValue, rightVibrationValue);
                    LastVibrationValues[index] = (leftVibrationValue, rightVibrationValue);
                    return;
                }
                if (RumbleQueues.TryGetValue(index, out ConcurrentQueue<(VibrationValue, VibrationValue)> currentQueue))
                {
                    if (!LastVibrationValues.TryGetValue(index, out (VibrationValue, VibrationValue) dualVibrationValue) || !leftVibrationValue.Equals(dualVibrationValue.Item1) || !rightVibrationValue.Equals(dualVibrationValue.Item2))
                    {
                        currentQueue.Enqueue((leftVibrationValue, rightVibrationValue));

                        LastVibrationValues[index] = (leftVibrationValue, rightVibrationValue);
                    }
                }
            }
        }

        public VibrationValue GetLastVibrationValue(PlayerIndex index, byte position)
        {
            lock (_rumbleLock)
            {
                RumbleBeforeAccepted?.Invoke();
                return GetLastVibrationValueLocked(index, position);
            }
        }

        private VibrationValue GetLastVibrationValueLocked(PlayerIndex index, byte position)
        {
            if (!LastVibrationValues.TryGetValue(index, out var values)) return _neutralVibrationValue;
            return position == 0 ? values.Item1 : values.Item2;
        }

        public void ResetRumble(PlayerIndex index)
        {
            lock (_rumbleLock)
            {
                LastVibrationValues.Remove(index);
                if (RumbleQueues.TryGetValue(index, out var queue)) while (queue.TryDequeue(out _)) { }
            }
        }

        public ConcurrentQueue<(VibrationValue, VibrationValue)> GetRumbleQueue(PlayerIndex index)
        {
            if (!RumbleQueues.TryGetValue(index, out ConcurrentQueue<(VibrationValue, VibrationValue)> rumbleQueue))
            {
                rumbleQueue = new ConcurrentQueue<(VibrationValue, VibrationValue)>();
                _device.Hid.Npads.RumbleQueues[index] = rumbleQueue;
            }

            return rumbleQueue;
        }
    }
}
