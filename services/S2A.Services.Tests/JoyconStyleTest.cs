using System;
using Ryujinx.HLE.HOS.Services.Hid;

namespace S2A.Services.Tests
{
    // #520 A：连着单只 Joy-Con 2 时照真机报单只样式（InputPump.JoyconPick）。期望按「游戏收它那一侧的单只样式、只有一个手柄才改；
    //   Joy-Con 不在了 / 游戏不收了换回改之前的」手写，不跑被测实现推期望。
    public static partial class Program
    {
        [SoloTest("--joycon-style")]
        private static int JoyconStyle()
        {
            int bad = 0;
            void Row(string what, string expect, (PlayerIndex, ControllerType) got)
            {
                string actual = $"{got.Item1} {got.Item2}";
                bool ok = expect == actual; if (!ok) bad++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 单只 Joy-Con 样式 {what}：{expect} → {actual}");
            }
            const ControllerType None = ControllerType.None, Pro = ControllerType.ProController, HH = ControllerType.Handheld;
            const ControllerType L = ControllerType.JoyconLeft, R = ControllerType.JoyconRight, Pair = ControllerType.JoyconPair;
            ControllerType all = Pro | HH | Pair | L | R;
            // ① 右只、游戏都收、主机档 Pro → Player1 的 JoyconRight
            Row("右只、游戏全收、现在 Pro", "Player1 JoyconRight", InputPump.JoyconPick(all, R, 1, Pro, None, PlayerIndex.Unknown));
            // ② 左只、掌机格 → Player1 的 JoyconLeft（同真机：拆下的单只当 Player1）
            Row("左只、现在掌机格", "Player1 JoyconLeft", InputPump.JoyconPick(all, L, 1, HH, None, PlayerIndex.Unknown));
            // ③ 已经是 JoyconRight：不动
            Row("已是右只样式", "Unknown None", InputPump.JoyconPick(all, R, 1, R, Pro, PlayerIndex.Player1));
            // ④ 游戏不收单只（只收 Pro / 双 Joy-Con）：不改，交给原来的跟随样式（宿主转横握扮 Pro）
            Row("游戏不收单只", "Unknown None", InputPump.JoyconPick(Pro | Pair, R, 1, Pro, None, PlayerIndex.Unknown));
            // ⑤ 游戏只收左只、手里是右只：不改成左只（宿主照旧转横握）
            Row("游戏只收左只、手里右只", "Unknown None", InputPump.JoyconPick(Pro | L, R, 1, Pro, None, PlayerIndex.Unknown));
            // ⑥ 两个手柄（第二格镜像）：不改
            Row("两个手柄", "Unknown None", InputPump.JoyconPick(all, R, 2, Pro, None, PlayerIndex.Unknown));
            // ⑦ Joy-Con 断开（宿主报 None）、之前从 Pro 改来：换回 Player1 的 Pro
            Row("断开后换回", "Player1 ProController", InputPump.JoyconPick(all, None, 1, R, Pro, PlayerIndex.Player1));
            // ⑧ 换成 Pro 手柄（宿主报 None）、之前从掌机格改来：换回掌机格
            Row("换成 Pro 手柄后换回掌机格", "Handheld Handheld", InputPump.JoyconPick(all, None, 1, L, HH, PlayerIndex.Handheld));
            // ⑨ 右只换成左只：改成左只
            Row("右只换左只", "Player1 JoyconLeft", InputPump.JoyconPick(all, L, 1, R, Pro, PlayerIndex.Player1));
            // ⑩ 游戏不收了：换回
            Row("游戏不收单只了", "Player1 ProController", InputPump.JoyconPick(Pro | Pair, R, 1, R, Pro, PlayerIndex.Player1));
            // ⑪ 没改过（游戏自己只收右只，原来的跟随样式改的）、没有 Joy-Con：不动
            Row("没改过", "Unknown None", InputPump.JoyconPick(R, None, 1, R, None, PlayerIndex.Unknown));
            // 告诉宿主的样式（ReportedStyle）：期望按「Pro / 双 Joy-Con 这一对看游戏收不收 Pro」手写
            void Rep(string what, string expect, ControllerType got)
            {
                bool ok = expect == got.ToString(); if (!ok) bad++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 报给宿主的样式 {what}：{expect} → {got}");
            }
            // ⑫ 游戏收 Pro 和双 Joy-Con、现在双 Joy-Con（小程序配的）：报 Pro（宿主转横握，一只手柄全键可用）
            Rep("收 Pro、现在双 Joy-Con", "ProController", InputPump.ReportedStyle(Pro | Pair, Pair));
            // ⑬ 只收 掌机 / 双 Joy-Con（一款体育游戏的球类项目）、现在 Pro（Remap 成双 Joy-Con）：报 JoyconPair（宿主照原始方向）
            Rep("只收双 Joy-Con、现在 Pro", "JoyconPair", InputPump.ReportedStyle(HH | Pair, Pro));
            // ⑭ 单只样式、掌机、游戏还没声明：原样
            Rep("单只右", "JoyconRight", InputPump.ReportedStyle(all, R));
            Rep("游戏没声明", "ProController", InputPump.ReportedStyle(None, Pro));
            Console.WriteLine($"{(bad == 0 ? "🟢" : "🔴")} 单只 Joy-Con 样式单测：15 项，不符 {bad}");
            return bad == 0 ? 0 : 1;
        }
    }
}
