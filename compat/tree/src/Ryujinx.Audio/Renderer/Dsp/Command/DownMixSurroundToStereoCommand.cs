using System;
using System.Runtime.CompilerServices;

namespace Ryujinx.Audio.Renderer.Dsp.Command
{
    public class DownMixSurroundToStereoCommand : ICommand
    {
        public bool Enabled { get; set; }

        public int NodeId { get; private set; }

        public CommandType CommandType => CommandType.DownMixSurroundToStereo;

        public uint EstimatedProcessingTime { get; set; }

        public ushort[] InputBufferIndices { get; }
        public ushort[] OutputBufferIndices { get; }

        public float[] Coefficients { get; private set; }

        public DownMixSurroundToStereoCommand()
        {
            InputBufferIndices = new ushort[Constants.VoiceChannelCountMax];
            OutputBufferIndices = new ushort[Constants.VoiceChannelCountMax];
        }

        public DownMixSurroundToStereoCommand Initialize(uint bufferOffset, Span<byte> inputBufferOffset, Span<byte> outputBufferOffset, float[] downMixParameter, int nodeId)
        {
            Enabled = true;
            NodeId = nodeId;

            for (int i = 0; i < Constants.VoiceChannelCountMax; i++)
            {
                InputBufferIndices[i] = (ushort)(bufferOffset + inputBufferOffset[i]);
                OutputBufferIndices[i] = (ushort)(bufferOffset + outputBufferOffset[i]);
            }

            Coefficients = downMixParameter;
            
            return this;
        }

        public void Process(CommandList context)
        {
            ReadOnlySpan<float> frontLeft = context.GetBuffer(InputBufferIndices[0]);
            ReadOnlySpan<float> frontRight = context.GetBuffer(InputBufferIndices[1]);
            ReadOnlySpan<float> frontCenter = context.GetBuffer(InputBufferIndices[2]);
            ReadOnlySpan<float> lowFrequency = context.GetBuffer(InputBufferIndices[3]);
            ReadOnlySpan<float> backLeft = context.GetBuffer(InputBufferIndices[4]);
            ReadOnlySpan<float> backRight = context.GetBuffer(InputBufferIndices[5]);

            Span<float> stereoLeft = context.GetBuffer(OutputBufferIndices[0]);
            Span<float> stereoRight = context.GetBuffer(OutputBufferIndices[1]);

            // S2Arm: 内核抽到 S2ADspMixHelper（ARM 向量路径 + 标量路径逐样本一致）
            S2ADspMixHelper.DownMixSurroundToStereo(
                stereoLeft,
                stereoRight,
                frontLeft,
                frontRight,
                frontCenter,
                lowFrequency,
                backLeft,
                backRight,
                Coefficients,
                (int)context.SampleCount);

            context.ClearBuffer(OutputBufferIndices[2]);
            context.ClearBuffer(OutputBufferIndices[3]);
            context.ClearBuffer(OutputBufferIndices[4]);
            context.ClearBuffer(OutputBufferIndices[5]);
        }
    }
}
