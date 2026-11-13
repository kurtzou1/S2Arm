using System;
using System.Runtime.CompilerServices;

namespace Ryujinx.Audio.Renderer.Dsp.Command
{
    public class VolumeRampCommand : ICommand
    {
        public bool Enabled { get; set; }

        public int NodeId { get; private set; }

        public CommandType CommandType => CommandType.VolumeRamp;

        public uint EstimatedProcessingTime { get; set; }

        public ushort InputBufferIndex { get; private set; }
        public ushort OutputBufferIndex { get; private set; }

        public float Volume0 { get; private set; }
        public float Volume1 { get; private set; }

        public VolumeRampCommand()
        {
            
        }
        
        public VolumeRampCommand Initialize(float volume0, float volume1, uint bufferIndex, int nodeId)
        {
            Enabled = true;
            NodeId = nodeId;

            InputBufferIndex = (ushort)bufferIndex;
            OutputBufferIndex = (ushort)bufferIndex;

            Volume0 = volume0;
            Volume1 = volume1;

            return this;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private void ProcessVolumeRamp(Span<float> outputBuffer, ReadOnlySpan<float> inputBuffer, int sampleCount)
        {
            float ramp = (Volume1 - Volume0) / sampleCount;

            // S2Arm: 内核抽到 S2ADspMixHelper（ARM 向量路径与标量路径逐样本一致，含音量递推序列）
            S2ADspMixHelper.VolumeRamp(outputBuffer, inputBuffer, Volume0, ramp, sampleCount);
        }

        public void Process(CommandList context)
        {
            ReadOnlySpan<float> inputBuffer = context.GetBuffer(InputBufferIndex);
            Span<float> outputBuffer = context.GetBuffer(OutputBufferIndex);

            ProcessVolumeRamp(outputBuffer, inputBuffer, (int)context.SampleCount);
        }
    }
}
