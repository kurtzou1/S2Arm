using System;

namespace Ryujinx.Audio.Renderer.Dsp
{
    // S2Arm (10-23 塞尔达分层账：C# 前三热点全是音频 DSP)：ARM 上的音频 DSP 快路径开关。
    //   S2A_AUDIO_DSP_FAST=0 关（缺省开；翻缺省依据：0197 的重采样/双二阶快路径离线逐字节对拍一致，
    //   本补丁再把全部快路径收进 tests/audio_dsp_simd 逐位对拍单测，并补齐高质档重采样 / 降混 / 坡道 / 设备输出的向量路径）。
    //   快路径与原路径逐样本输出一致（同运算、同求和顺序、同舍入），只去掉 ARM 上的多余开销：
    //   重采样走标量（SSE 快路径只认 x86）、每次 32 KB 栈缓冲清零、双二阶滤波器状态逐样本经引用读写。
    internal static class S2ADspFast
    {
        public static readonly bool On = Environment.GetEnvironmentVariable("S2A_AUDIO_DSP_FAST") != "0";
    }
}
