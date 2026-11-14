using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Renderer.Dsp
{
    /// <summary>
    /// S2Arm (11-14 卡顿诊断探针): 把声音渲染线程每个 5 ms 周期的唤醒迟到纳秒累计交给宿主（hle_nvn.c 的 s2a_aud_late_note），
    /// DM_NVN_TSV 每帧取走清零成 @aud_wait_ms 列。慢帧归因「在等事件」时用它看音频占比。
    /// </summary>
    /// <remarks>
    /// 没有 s2a_native 这个符号的构建（安卓 / 单测 / 别的宿主）就不记：守门一次失败后不再调（同 S2AOutputDiag.HudAudio）。
    /// </remarks>
    internal static class S2AAudLate
    {
        [DllImport("s2a_native")] private static extern void s2a_aud_late_note(long ns);

        private static bool _gone;

        internal static void Note(long lateNs)
        {
            if (_gone)
            {
                return;
            }

            try
            {
                s2a_aud_late_note(lateNs);
            }
            catch (Exception e) when (e is DllNotFoundException || e is EntryPointNotFoundException || e is BadImageFormatException)
            {
                _gone = true;
            }
        }
    }
}
