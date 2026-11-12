using Ryujinx.HLE;
using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.Services.Hid.Types;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.Npad;
using Ryujinx.Input;
using System;
using System.Collections.Generic;
using System.Numerics;
using System.Runtime.InteropServices;
using Stopwatch = System.Diagnostics.Stopwatch;

namespace S2A.Services
{
    // 复用 HID 泵；原始双侧双频震动不经过桌面普通双马达适配器。
    internal sealed unsafe class ControllerFeedback
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct MotionSample
        {
            public ulong TimestampUs;
            public float AccelerationX, AccelerationY, AccelerationZ;
            public float GyroX, GyroY, GyroZ;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MouseSample   // runtime/include/s2a_pad.h s2a_pad_mouse
        {
            public ulong TimestampUs;
            public short X, Y;
            public ushort Distance;
            public byte Side, Known;
        }

        private readonly NpadDevices _npads;
        private readonly delegate* unmanaged<MouseSample*, int> _readMousePair;   // 可选（Mac）：Joy-Con 2 光学鼠标，左右各一份
        private bool _mouseConnected, _mouseLogged;
        private readonly delegate* unmanaged<ulong, VibrationValue*, void> _setRumblePair;
        private readonly delegate* unmanaged<ulong, void> _stopRumble;
        private readonly delegate* unmanaged<ulong> _rumbleSession;
        private readonly delegate* unmanaged<MotionSample*, int> _readMotion;
        private readonly delegate* unmanaged<MotionSample*, int> _readMotionPair;   // 可选：左右两路（Mac Joy-Con HID）
        private readonly delegate* unmanaged<int, void> _setMotionEnabled;
        private readonly List<SixAxisInput> _motionStates = new(2);
        private readonly float[] _orientation = new float[9];
        private readonly float[] _orientationRight = new float[9];
        private MotionInput _motion, _motionRight;
        private PlayerIndex _rumblePlayer, _motionPlayer;
        private ulong _session;
        private ulong _motionSession, _motionTimestamp;
        private long _renewAt;
        private VibrationValue _left, _right;
        private bool _motionEnabled, _motionPublished, _rumbleLogged, _motionLogged;
        private bool _rumblePermitted;
        private volatile bool _stopped;

        public static bool MotionExport(out nint motion) =>
            NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_pad_read_motion", out motion);

        public ControllerFeedback(Switch device, PlayerIndex player)
        {
            _npads = device.Hid.Npads;
            _rumblePlayer = _motionPlayer = player;
            _rumblePermitted = _npads.VibrationPermitted;
            nint program = NativeLibrary.GetMainProgramHandle();
            if (NativeLibrary.TryGetExport(program, "s2a_pad_rumble_session", out nint rumbleSession))
            {
                // A feedback-capable host must export the atomic pair ABI; never silently split a game frame.
                _setRumblePair = (delegate* unmanaged<ulong, VibrationValue*, void>)NativeLibrary.GetExport(program, "s2a_pad_set_rumble_pair");
                _stopRumble = (delegate* unmanaged<ulong, void>)NativeLibrary.GetExport(program, "s2a_pad_stop_rumble");
                _rumbleSession = (delegate* unmanaged<ulong>)rumbleSession;
                lock (_npads.RumbleSyncRoot)
                {
                    _rumblePermitted = _npads.VibrationPermitted;
                    _session = _rumbleSession();
                    for (int i = 0; i < NpadDevices.MaxControllers; i++) _npads.ResetRumble((PlayerIndex)i);
                    _npads.RumbleBeforeAccepted = ObserveSession;
                    _npads.RumbleAccepted = AcceptRumble;
                    _npads.RumblePermissionChanged = SetRumblePermitted;
                }
            }
            if (MotionExport(out nint motion))
            {
                _readMotion = (delegate* unmanaged<MotionSample*, int>)motion;
                _setMotionEnabled = (delegate* unmanaged<int, void>)NativeLibrary.GetExport(program, "s2a_pad_set_motion_enabled");
                if (NativeLibrary.TryGetExport(program, "s2a_pad_read_motion_pair", out nint pair))   // 平台例外：Mac 宿主（macos/front_mac.m，Joy-Con HID 左右两路体感）专有的可选导出，同 s2a_pad_read_motion；iOS / 安卓宿主没有
                    _readMotionPair = (delegate* unmanaged<MotionSample*, int>)pair;
            }
            if (NativeLibrary.TryGetExport(program, "s2a_pad_read_mouse_pair", out nint mousePair))   // 平台例外：Mac 宿主（macos/front_mac.m，Joy-Con 2 光学鼠标）专有的可选导出
                _readMousePair = (delegate* unmanaged<MouseSample*, int>)mousePair;
            Console.Error.WriteLine($"[输入反馈] hooks rumble_pair={_setRumblePair != null} stop={_stopRumble != null} session={_rumbleSession != null} motion={_readMotion != null} motion_pair={_readMotionPair != null} motion_enable={_setMotionEnabled != null} mouse={_readMousePair != null} player={(int)player} session={_session} permit={_rumblePermitted}");
        }

        public void Update(PlayerIndex player)
        {
            if (_setRumblePair != null) UpdateRumble();
            TickMotion(player);
        }

        // All rumble state, game requests and lease renewals share Npads' existing lock.
        private void ObserveSession()
        {
            ulong session = _rumbleSession();
            if (session != _session)
            {
                Console.Error.WriteLine($"[输入反馈] state player={(int)_rumblePlayer} session={_session}->{session} permit={_rumblePermitted}");
                _session = session;
                _left = _right = default;
                _rumbleLogged = false;
                // A new session clears local state without truncating its connection cue.
                for (int i = 0; i < NpadDevices.MaxControllers; i++) _npads.ResetRumble((PlayerIndex)i);
            }
        }

        public void SetPlayer(PlayerIndex player)
        {
            lock (_npads.RumbleSyncRoot)
            {
                if (_stopped) return;
                if (_stopRumble != null) _stopRumble(_session);
                _rumblePlayer = player;
                _left = _right = default;
                _rumbleLogged = false;
                for (int i = 0; i < NpadDevices.MaxControllers; i++) _npads.ResetRumble((PlayerIndex)i);
                if (_rumbleSession != null) ObserveSession();
            }
        }

        private void SetRumblePermitted(bool permitted)
        {
            if (_stopped) return;
            ObserveSession();
            Console.Error.WriteLine($"[输入反馈] permit player={(int)_rumblePlayer} session={_session} permit={permitted}");
            if (!permitted && (Vibrating(_left) || Vibrating(_right))) _stopRumble(_session);
            _left = _right = default;
            _rumblePermitted = permitted;
        }

        // Called synchronously for each permitted game request, before Npads' queue deduplication.
        private void AcceptRumble(PlayerIndex player, VibrationValue left, VibrationValue right)
        {
            if (_stopped) return;
            if (!_rumbleLogged && (Vibrating(left) || Vibrating(right)))
            {
                _rumbleLogged = true;
                Console.Error.WriteLine($"[输入反馈] first game rumble slot={(int)player} player={(int)_rumblePlayer} session={_session} permit={_rumblePermitted} L={left.AmplitudeLow}@{left.FrequencyLow}/{left.AmplitudeHigh}@{left.FrequencyHigh} R={right.AmplitudeLow}@{right.FrequencyLow}/{right.AmplitudeHigh}@{right.FrequencyHigh}");
            }
            if (player != _rumblePlayer || _session == 0 || !_rumblePermitted) return;
            if ((left != _left || right != _right) &&
                (Vibrating(left) || Vibrating(right) || Vibrating(_left) || Vibrating(_right)))
            {
                SendPair(left, right);
                _left = left;
                _right = right;
                _renewAt = Stopwatch.GetTimestamp() + Stopwatch.Frequency / 4;
            }
        }

        private void UpdateRumble()
        {
            lock (_npads.RumbleSyncRoot)
            {
                if (_stopped) return;
                // SetPrimary supplies the authoritative player under this lock; an older HID snapshot cannot undo it.
                ObserveSession();
                long now = Stopwatch.GetTimestamp();
                if (_session != 0 && _rumblePermitted && now >= _renewAt && (Vibrating(_left) || Vibrating(_right)))
                {
                    SendPair(_left, _right);
                    _renewAt = now + Stopwatch.Frequency / 4;
                }
            }
        }

        private static bool Vibrating(VibrationValue value) => value.AmplitudeLow > 0 || value.AmplitudeHigh > 0;
        private void SendPair(VibrationValue left, VibrationValue right)
        {
            VibrationValue* values = stackalloc VibrationValue[2];
            values[0] = left;
            values[1] = right;
            _setRumblePair(_session, values);
        }

        // Only the HID thread calls this; event wakes and heartbeats may share a native sample.
        public void TickMotion(PlayerIndex player)
        {
            TickMouse(player);
            if (_readMotion == null || _stopped) return;
            ulong session = _rumbleSession != null ? _rumbleSession() : 0;
            if (player != _motionPlayer || session != _motionSession)
            {
                _motionPlayer = player;
                _motionSession = session;
                _motion = _motionRight = null;
                _motionTimestamp = 0;
                _motionLogged = false;
                if (_motionPublished)
                {
                    _motionStates.Clear();
                    _npads.UpdateSixAxis(_motionStates);
                    _motionPublished = false;
                }
            }
            // 六轴（StartSixAxisSensor）或 Switch 2 Npad IMU（hid 320）任一在用就读体感
            bool enabled = _npads.SixAxisActive || _npads.Imu.Active;
            if (enabled != _motionEnabled)
            {
                _setMotionEnabled(enabled ? 1 : 0);
                _motionEnabled = enabled;
            }
            _motionStates.Clear();
            MotionSample sample = default, sampleR = default;
            int known = 0, nPair = 0;
            if (enabled)
            {
                if (_readMotionPair != null)
                {
                    MotionSample* buf = stackalloc MotionSample[2];
                    nPair = _readMotionPair(buf);
                    if (nPair >= 1) { sample = buf[0]; known = 1; }
                    if (nPair >= 2) sampleR = buf[1];
                }
                else known = _readMotion(&sample);
            }
            if (!enabled || known == 0)
            {
                _motion = _motionRight = null;
                _motionTimestamp = 0;
                if (_motionPublished)
                {
                    _npads.UpdateSixAxis(_motionStates);
                    _motionPublished = false;
                }
                return;
            }
            if (sample.TimestampUs == _motionTimestamp && nPair < 2) return;
            _motionTimestamp = sample.TimestampUs;
            if (!_motionLogged)
            {
                _motionLogged = true;
                Console.Error.WriteLine($"[输入反馈] first motion known={known} pair={nPair} player={(int)player} timestamp_us={sample.TimestampUs} accel_g=({sample.AccelerationX},{sample.AccelerationY},{sample.AccelerationZ}) gyro_deg_s=({sample.GyroX},{sample.GyroY},{sample.GyroZ})");
            }
            // 左右 Joy-Con 各一路：同一 PlayerId 连续两份，UpdateSixAxis 把第二份写入右手六轴；Npad IMU 左只写传感器 0、右只写传感器 1（单路时 -1：左右同一份）
            AddMotionState(player, sample, ref _motion, _orientation, imuSensor: nPair >= 2 ? 0 : -1);
            if (nPair >= 2)
                AddMotionState(player, sampleR, ref _motionRight, _orientationRight, imuSensor: 1);
            _npads.UpdateSixAxis(_motionStates);
            _motionPublished = true;
        }

        // Joy-Con 2 光学鼠标 → 游戏的 Jcms 缓冲（hid 3110，NpadJcms）：游戏靠「已连接」位认 Joy-Con 2，靠位移玩鼠标操作的项目。
        //   连着 Joy-Con 2 就每次都写一笔（没有鼠标读数时位移 0）；Joy-Con 2 不在了写一笔未连接
        private void TickMouse(PlayerIndex player)
        {
            if (_readMousePair == null || _stopped) return;
            MouseSample* m = stackalloc MouseSample[2];
            int sides = _readMousePair(m);
            int npadId = player >= PlayerIndex.Player1 && player <= PlayerIndex.Player8 ? (int)player : 0;
            if (sides == 0)
            {
                if (_mouseConnected) _npads.Jcms.Disconnect();
                _mouseConnected = false;
                _npads.SetJoycon2(false);
                return;
            }
            _mouseConnected = true;
            _npads.SetJoycon2(true);   // 样式加 Joy-Con 2 位（NpadDevices.Joycon2Style）：只收 Joy-Con 2 的场景游戏才认
            if (!_mouseLogged && (m[0].Known != 0 || m[1].Known != 0))
            {
                _mouseLogged = true;
                Console.Error.WriteLine($"[输入反馈] first mouse npad={npadId} sides={sides} L=({(m[0].Side == 0 ? $"{m[0].X},{m[0].Y} d{m[0].Distance} k{m[0].Known}" : "-")}) R=({(m[1].Side == 1 ? $"{m[1].X},{m[1].Y} d{m[1].Distance} k{m[1].Known}" : "-")})");
            }
            NpadJcms.Side left = new() { Present = m[0].Side == 0, Known = m[0].Known != 0, X = m[0].X, Y = m[0].Y, OnSurface = m[0].Distance == 0 };
            NpadJcms.Side right = new() { Present = m[1].Side == 1, Known = m[1].Known != 0, X = m[1].X, Y = m[1].Y, OnSurface = m[1].Distance == 0 };
            bool pair = player <= PlayerIndex.Handheld && NpadDevices.Base(_npads.StyleOf(player)) == NpadStyleTag.JoyDual;   // 一对：游戏左右两侧都查
            if (_npads.Jcms.Active) _npads.Jcms.Push(npadId, left, right, m[0].Side == 0 ? m[0].TimestampUs : m[1].TimestampUs, pair);
        }

        private void AddMotionState(PlayerIndex player, MotionSample sample, ref MotionInput motion, float[] orientation, int imuSensor)
        {
            Vector3 accel = new(SixAxisSensorIc.ClampAcceleration(sample.AccelerationX), SixAxisSensorIc.ClampAcceleration(sample.AccelerationY), SixAxisSensorIc.ClampAcceleration(sample.AccelerationZ));
            Vector3 gyro = new(SixAxisSensorIc.ClampAngularRate(sample.GyroX), SixAxisSensorIc.ClampAngularRate(sample.GyroY), SixAxisSensorIc.ClampAngularRate(sample.GyroZ));
            _npads.PushImu(player, accel, gyro, sample.TimestampUs, imuSensor);
            if (motion != null && (sample.TimestampUs < motion.TimeStamp || sample.TimestampUs - motion.TimeStamp > 250_000))
                motion = null;
            motion ??= new MotionInput();
            if (sample.TimestampUs != motion.TimeStamp)
                motion.Update(accel, gyro, sample.TimestampUs, 100, 0);
            Matrix4x4 m = motion.GetOrientation();
            orientation[0] = m.M11; orientation[1] = m.M12; orientation[2] = m.M13;
            orientation[3] = m.M21; orientation[4] = m.M22; orientation[5] = m.M23;
            orientation[6] = m.M31; orientation[7] = m.M32; orientation[8] = m.M33;
            _motionStates.Add(new SixAxisInput
            {
                PlayerId = player,
                Accelerometer = motion.Accelerometer,
                Gyroscope = motion.Gyroscrope * 0.0027f,
                Rotation = motion.Rotation * 0.0027f,
                Orientation = orientation,
            });
        }

        public void Stop()
        {
            lock (_npads.RumbleSyncRoot)
            {
                if (_stopped) return;
                _stopped = true;
                if (_setRumblePair != null)
                {
                    _npads.RumbleBeforeAccepted = null;
                    _npads.RumbleAccepted = null;
                    _npads.RumblePermissionChanged = null;
                    _stopRumble(_session);
                }
                _left = _right = default;
                for (int i = 0; i < NpadDevices.MaxControllers; i++) _npads.ResetRumble((PlayerIndex)i);
            }
            // Jcms 与样式里的 Joy-Con 2 位都留着：反馈对象随焦点 / 会话重建，手柄本身没换。原先这里写「未连接」，
            //   游戏失焦片刻就以为 Joy-Con 2 拔了、拉起手柄设置（11-12 实机：之后小程序认不了 Joy-Con 2 位、游戏反复重开卡住）
            _mouseConnected = false;
            if (_setMotionEnabled != null) _setMotionEnabled(0);
            _motion = _motionRight = null;
            _motionTimestamp = 0;
            _motionEnabled = false;
            if (_motionPublished)
            {
                _motionStates.Clear();
                _npads.UpdateSixAxis(_motionStates);
                _motionPublished = false;
            }
        }
    }
}
