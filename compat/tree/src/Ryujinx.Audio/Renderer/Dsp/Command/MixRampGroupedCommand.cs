using Ryujinx.Audio.Renderer.Common;
using System;
using System.Runtime.CompilerServices;

namespace Ryujinx.Audio.Renderer.Dsp.Command
{
    public class MixRampGroupedCommand : ICommand
    {
        public bool Enabled { get; set; }

        public int NodeId { get; private set; }

        public CommandType CommandType => CommandType.MixRampGrouped;

        public uint EstimatedProcessingTime { get; set; }

        public uint MixBufferCount { get; private set; }

        public ushort[] InputBufferIndices { get; private set; }
        public ushort[] OutputBufferIndices { get; private set; }

        public float[] Volume0 { get; private set; }
        public float[] Volume1 { get; private set; }

        public Memory<VoiceState> State { get; private set; }

        public MixRampGroupedCommand()
        {
            
        }

        public MixRampGroupedCommand Initialize(
            uint mixBufferCount,
            uint inputBufferIndex,
            uint outputBufferIndex,
            ReadOnlySpan<float> volume0,
            ReadOnlySpan<float> volume1,
            Memory<VoiceState> state,
            int nodeId)
        {
            Enabled = true;
            MixBufferCount = mixBufferCount;
            NodeId = nodeId;

            InputBufferIndices ??= new ushort[Constants.MixBufferCountMax]; // S2Arm: pooled command, fixed-size arrays allocated once (was every voice, every frame)
            OutputBufferIndices ??= new ushort[Constants.MixBufferCountMax]; // S2Arm: pooled command, fixed-size arrays allocated once (was every voice, every frame)
            Volume0 ??= new float[Constants.MixBufferCountMax]; // S2Arm: pooled command, fixed-size arrays allocated once (was every voice, every frame)
            Volume1 ??= new float[Constants.MixBufferCountMax]; // S2Arm: pooled command, fixed-size arrays allocated once (was every voice, every frame)

            for (int i = 0; i < mixBufferCount; i++)
            {
                InputBufferIndices[i] = (ushort)inputBufferIndex;
                OutputBufferIndices[i] = (ushort)(outputBufferIndex + i);

                Volume0[i] = volume0[i];
                Volume1[i] = volume1[i];
            }

            State = state;
            
            return this;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static float ProcessMixRampGrouped(
            Span<float> outputBuffer,
            ReadOnlySpan<float> inputBuffer,
            float volume0,
            float volume1,
            int sampleCount)
        {
            float ramp = (volume1 - volume0) / sampleCount;

            // S2Arm: 内核抽到 S2ADspMixHelper（ARM 向量路径与标量路径逐样本一致，含音量递推序列）
            return S2ADspMixHelper.MixRamp(outputBuffer, inputBuffer, volume0, ramp, sampleCount);
        }

        public void Process(CommandList context)
        {
            ref VoiceState state = ref State.Span[0];
            
            Span<float> lastSamplesSpan = state.LastSamples.AsSpan();
            
            for (int i = 0; i < MixBufferCount; i++)
            {
                ReadOnlySpan<float> inputBuffer = context.GetBuffer(InputBufferIndices[i]);
                Span<float> outputBuffer = context.GetBuffer(OutputBufferIndices[i]);

                float volume0 = Volume0[i];
                float volume1 = Volume1[i];

                if (volume0 != 0 || volume1 != 0)
                {
                    lastSamplesSpan[i] = ProcessMixRampGrouped(outputBuffer, inputBuffer, volume0, volume1, (int)context.SampleCount);
                }
                else
                {
                    lastSamplesSpan[i] = 0;
                }
            }
        }
    }
}
