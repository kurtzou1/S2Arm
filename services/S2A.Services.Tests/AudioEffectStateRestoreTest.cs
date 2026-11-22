using System;
using System.Collections.Generic;
using Ryujinx.Audio.Renderer.Dsp.Command;
using Ryujinx.Audio.Renderer.Dsp.State;
using Ryujinx.Audio.Renderer.Parameter;
using Ryujinx.Audio.Renderer.Parameter.Effect;
using Ryujinx.Audio.Renderer.Server.Effect;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // 即时存档恢复 / 进程内重启后宿主侧效果器 DSP 状态是新的（数组为 null），游戏内存里的参数状态却已是 Enabled（D-WP4X：王国之泪恢复后限幅器首个采样读 null 数组崩）。
        //   期望手写：限幅器 v2，1 声道、240 个采样、输入全 0.5 × short.MaxValue、增益 1、阈值 1：空状态 + 参数「Enabled」→ Process 不抛、状态的数组建出来、输出全是有限数；
        //   同一条件下参数「New」（只更新参数、不建状态）同样不抛（原先抛空引用）
        [SoloTest("--audio-effect-state-restore")]
        private static int AudioEffectStateRestore()
        {
            var rows = new List<(string N, string E, string A)>();
            (bool threw, bool built, bool finite) Run(UsageState status)
            {
                const int Samples = 240;
                float[] mix = new float[Samples * 2];
                for (int i = 0; i < Samples; i++) mix[i] = 0.5f * short.MaxValue;
                using var list = new CommandList(null, mix.AsMemory(), Samples, 48000, 2, 0);
                LimiterParameter p = default;
                p.ChannelCount = 1; p.ChannelCountMax = 1; p.Input[0] = 0; p.Output[0] = 1; p.SampleRate = 48000;
                p.AttackCoefficient = 0.1f; p.ReleaseCoefficient = 0.1f; p.Threshold = 1f; p.InputGain = 1f; p.OutputGain = 1f;
                p.DelayBufferSampleCountMin = 1; p.DelayBufferSampleCountMax = 1; p.Status = status;
                var state = new LimiterState[1];   // 恢复后的样子：结构是默认值，数组全 null
                var result = new EffectResultState[1];
                var cmd = new LimiterCommandVersion2().Initialize(0, p, state.AsMemory(), result.AsMemory(), true, 0, 0);
                try { cmd.Process(list); }
                catch (NullReferenceException) { return (true, state[0].DetectorAverage != null, false); }
                bool fin = true; for (int i = 0; i < Samples; i++) fin &= float.IsFinite(mix[Samples + i]);
                return (false, state[0].DetectorAverage != null, fin);
            }
            var u = Run(UsageState.Enabled); var n = Run(UsageState.New);
            rows.Add(("① 空状态 + 参数「Enabled」：不抛 / 状态建出 / 输出有限", "否 / 是 / 是", $"{(u.threw ? "抛" : "否")} / {(u.built ? "是" : "否")} / {(u.finite ? "是" : "否")}"));
            rows.Add(("② 空状态 + 参数「New」：不抛 / 状态建出 / 输出有限", "否 / 是 / 是", $"{(n.threw ? "抛" : "否")} / {(n.built ? "是" : "否")} / {(n.finite ? "是" : "否")}"));
            int failures = 0;
            foreach ((string name, string ex, string a) in rows) { bool ok = ex == a; if (!ok) failures++; Console.WriteLine($"{(ok ? "✓" : "✗")} {name}：{ex} → {a}"); }
            return failures == 0 ? 0 : 1;
        }
    }
}
