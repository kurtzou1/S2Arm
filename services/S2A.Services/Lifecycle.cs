using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.SystemState;

namespace S2A.Services
{
    // 前后台 / 焦点与底座接线（缺口扫描族 1 / 2，11-01 体验线）：平台壳把焦点、掌机 / 主机写进原生层（接口 v2.15），这里每拍读一次，
    //   变了就转成游戏收得到的东西——焦点 → AppletState.SetFocus（FocusStateChanged，回前台另入队 ChangeIntoForeground）；
    //   底座 → Horizon.ChangeDockedModeState（按游戏的通知开关入队 OperationModeChanged / PerformanceModeChanged，点亮分辨率事件）。
    //   睡眠 → psc 各模块的 SleepReady / FullAwake 请求。
    //   游戏的失焦暂停开关反方向写回原生层，平台壳失焦时据此冻结客机（iOS 后台本来整体冻结）。
    //   客机冻结状态同步到声音暂停事件，沿用 Horizon.TogglePauseEmulation 的 Reset / Set 语义。
    //   原先 Ryujinx 起局时 SetFocus(true) 一次、之后焦点不再变；ChangeDockedModeState 全库没有调用方
    internal static unsafe class Lifecycle
    {
        static int _focus = 1, _mode = -1, _sleep, _frozen;

        // 起局（Host 建好 Device 后）调一次：开关回写接上，焦点 / 底座从当前值起算（之后只认变化）
        public static void Attach()
        {
            _focus = Native.HostFocused != null ? Native.HostFocused() : 1;
            _mode = Native.ConsoleMode != null ? Native.ConsoleMode() : -1;
            _sleep = Native.HostSleeping != null ? Native.HostSleeping() : 0;
            _frozen = Native.GuestFrozen != null ? Native.GuestFrozen() : 0;
            ApplyAudioPause(_frozen);
            AppletStateMgr.OutOfFocusSuspendingChanged = on => { if (Native.FocusSuspendSet != null) Native.FocusSuspendSet(on ? 1 : 0); };
        }

        // 输入泵每拍调（InputPump）：只比两个整数，变了才动 Horizon
        public static void Tick(Horizon system)
        {
            if (system == null) return;
            int focus = Native.HostFocused != null ? Native.HostFocused() : 1;
            if (focus != _focus)
            {
                _focus = focus;
                system.AppletState.SetFocus(focus != 0);
                Ryujinx.Common.Logging.Logger.Info?.Print(Ryujinx.Common.Logging.LogClass.ServiceAm, $"S2Arm 生命周期：焦点 → {(focus != 0 ? "前台" : "失焦")}，已通知游戏");
            }
            // 睡眠（iOS 后台 / Mac 系统睡眠，切窗口不算）→ psc 模块的休眠 / 唤醒请求（原先 psc 没有命令，游戏收不到）
            int sleep = Native.HostSleeping != null ? Native.HostSleeping() : 0;
            if (sleep != _sleep)
            {
                _sleep = sleep;
                Ryujinx.Horizon.Psc.Ipc.PmModule.RequestAll(sleep != 0 ? Ryujinx.Horizon.Sdk.Psc.PmState.SleepReady : Ryujinx.Horizon.Sdk.Psc.PmState.FullAwake);
                Ryujinx.Common.Logging.Logger.Info?.Print(Ryujinx.Common.Logging.LogClass.ServiceAm, $"S2Arm 生命周期：{(sleep != 0 ? "睡眠，已向 psc 模块发休眠请求" : "唤醒，已向 psc 模块发唤醒请求")}");
            }
            int frozen = Native.GuestFrozen != null ? Native.GuestFrozen() : 0;
            if (frozen != _frozen)
            {
                _frozen = frozen;
                ApplyAudioPause(frozen);
                Ryujinx.Common.Logging.Logger.Info?.Print(Ryujinx.Common.Logging.LogClass.ServiceAm, $"S2Arm 生命周期：客机{(frozen != 0 ? "冻结，声音渲染暂停" : "解冻，声音渲染恢复")}");
            }
            int mode = Native.ConsoleMode != null ? Native.ConsoleMode() : -1;
            if (mode != _mode)
            {
                _mode = mode;
                if (mode >= 0)
                {
                    system.ChangeDockedModeState(mode == 1);
                    Ryujinx.Common.Logging.Logger.Info?.Print(Ryujinx.Common.Logging.LogClass.ServiceAm, $"S2Arm 生命周期：运行中切到{(mode == 1 ? "主机" : "掌机")}模式");
                }
            }
        }

        static void ApplyAudioPause(int frozen)
        {
            Ryujinx.Audio.Integration.S2AGuestFreeze.Set(frozen != 0);   // 声音诊断按它扣掉冻结窗（11-13 失焦误报「回调 0 次」）
            var pause = Host.Device?.AudioDeviceDriver?.GetPauseEvent();
            if (pause == null) return;
            if (frozen != 0) pause.Reset(); else pause.Set();
        }
    }
}
