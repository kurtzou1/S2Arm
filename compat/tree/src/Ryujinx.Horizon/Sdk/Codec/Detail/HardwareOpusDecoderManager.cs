using System;
using Ryujinx.Common;
using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Sf;
using Ryujinx.Horizon.Sdk.Sf.Hipc;

namespace Ryujinx.Horizon.Sdk.Codec.Detail
{
    partial class HardwareOpusDecoderManager : IHardwareOpusDecoderManager
    {
        // S2Arm：四个打开入口共用（审计 P2-276：原先同一段写了四份）。同时存活的解码器有上限，到上限按真机回「资源不足」，
        //   游戏 SDK 走温和分支（HardwareOpusDecoder.MaxLive）；mapping 为空 = 单流
        private static Result CreateDecoder(out IHardwareOpusDecoder decoder, int workBufferHandle, int sampleRate, int channels,
            int streams = 0, int coupledStreams = 0, byte[] mapping = null)
        {
            decoder = null;

            if (!HardwareOpusDecoder.TryReserve())
            {
                HorizonStatic.Syscall.CloseHandle(workBufferHandle);

                return CodecResult.OutOfDecoders;
            }

            try
            {
                decoder = (mapping == null
                    ? new HardwareOpusDecoder(sampleRate, channels, workBufferHandle)
                    : new HardwareOpusDecoder(sampleRate, channels, streams, coupledStreams, mapping, workBufferHandle)).MarkReserved();
            }
            catch (Exception error)
            {
                // 构造失败：名额还回去；构造到一半的对象不会 Dispose，交进来的工作缓冲句柄在这里关（审计 P2-276）
                HardwareOpusDecoder.ReleaseReservation();
                HorizonStatic.Syscall.CloseHandle(workBufferHandle);

                // libopus 拒绝这组参数（NativeDecoder 抛 ArgumentException）：回参数错误，不让异常冲出服务分发（分发层不接它）
                if (error is ArgumentException)
                {
                    return CodecResult.OpusBadArg;
                }

                throw;
            }

            return Result.Success;
        }

        [CmifCommand(0)]
        public Result OpenHardwareOpusDecoder(
            out IHardwareOpusDecoder decoder,
            HardwareOpusDecoderParameterInternal parameter,
            [CopyHandle] int workBufferHandle,
            int workBufferSize)
        {
            decoder = null;

            if (!IsValidSampleRate(parameter.SampleRate))
            {
                HorizonStatic.Syscall.CloseHandle(workBufferHandle);

                return CodecResult.InvalidSampleRate;
            }

            if (!IsValidChannelCount(parameter.ChannelsCount))
            {
                HorizonStatic.Syscall.CloseHandle(workBufferHandle);

                return CodecResult.InvalidChannelCount;
            }

            return CreateDecoder(out decoder, workBufferHandle, parameter.SampleRate, parameter.ChannelsCount);
        }

        [CmifCommand(1)]
        public Result GetWorkBufferSize(out int size, HardwareOpusDecoderParameterInternal parameter)
        {
            size = 0;

            if (!IsValidChannelCount(parameter.ChannelsCount))
            {
                return CodecResult.InvalidChannelCount;
            }

            if (!IsValidSampleRate(parameter.SampleRate))
            {
                return CodecResult.InvalidSampleRate;
            }

            int opusDecoderSize = GetOpusDecoderSize(parameter.ChannelsCount);

            int sampleRateRatio = parameter.SampleRate != 0 ? 48000 / parameter.SampleRate : 0;
            int frameSize = BitUtils.AlignUp(sampleRateRatio != 0 ? parameter.ChannelsCount * 1920 / sampleRateRatio : 0, 64);
            size = opusDecoderSize + 1536 + frameSize;

            return Result.Success;
        }

        [CmifCommand(2)] // 3.0.0+
        public Result OpenHardwareOpusDecoderForMultiStream(
            out IHardwareOpusDecoder decoder,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.Pointer, 0x110)] in HardwareOpusMultiStreamDecoderParameterInternal parameter,
            [CopyHandle] int workBufferHandle,
            int workBufferSize)
        {
            decoder = null;

            if (!IsValidSampleRate(parameter.SampleRate))
            {
                HorizonStatic.Syscall.CloseHandle(workBufferHandle);

                return CodecResult.InvalidSampleRate;
            }

            if (!IsValidMultiChannelCount(parameter.ChannelsCount))
            {
                HorizonStatic.Syscall.CloseHandle(workBufferHandle);

                return CodecResult.InvalidChannelCount;
            }

            if (!IsValidNumberOfStreams(parameter.NumberOfStreams, parameter.NumberOfStereoStreams, parameter.ChannelsCount))
            {
                HorizonStatic.Syscall.CloseHandle(workBufferHandle);

                return CodecResult.InvalidNumberOfStreams;
            }

            return CreateDecoder(out decoder, workBufferHandle, parameter.SampleRate, parameter.ChannelsCount, parameter.NumberOfStreams, parameter.NumberOfStereoStreams, parameter.ChannelMappings.AsSpan().ToArray());
        }

        [CmifCommand(3)] // 3.0.0+
        public Result GetWorkBufferSizeForMultiStream(
            out int size,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.Pointer, 0x110)] in HardwareOpusMultiStreamDecoderParameterInternal parameter)
        {
            size = 0;

            if (!IsValidMultiChannelCount(parameter.ChannelsCount))
            {
                return CodecResult.InvalidChannelCount;
            }

            if (!IsValidSampleRate(parameter.SampleRate))
            {
                return CodecResult.InvalidSampleRate;
            }

            if (!IsValidNumberOfStreams(parameter.NumberOfStreams, parameter.NumberOfStereoStreams, parameter.ChannelsCount))
            {
                return CodecResult.InvalidSampleRate;
            }

            int opusDecoderSize = GetOpusMultistreamDecoderSize(parameter.NumberOfStreams, parameter.NumberOfStereoStreams);

            int streamSize = BitUtils.AlignUp(parameter.NumberOfStreams * 1500, 64);
            int sampleRateRatio = parameter.SampleRate != 0 ? 48000 / parameter.SampleRate : 0;
            int frameSize = BitUtils.AlignUp(sampleRateRatio != 0 ? parameter.ChannelsCount * 1920 / sampleRateRatio : 0, 64);
            size = opusDecoderSize + streamSize + frameSize;

            return Result.Success;
        }

        [CmifCommand(4)] // 12.0.0+
        public Result OpenHardwareOpusDecoderEx(
            out IHardwareOpusDecoder decoder,
            HardwareOpusDecoderParameterInternalEx parameter,
            [CopyHandle] int workBufferHandle,
            int workBufferSize)
        {
            decoder = null;

            if (!IsValidChannelCount(parameter.ChannelsCount))
            {
                HorizonStatic.Syscall.CloseHandle(workBufferHandle);

                return CodecResult.InvalidChannelCount;
            }

            if (!IsValidSampleRate(parameter.SampleRate))
            {
                HorizonStatic.Syscall.CloseHandle(workBufferHandle);

                return CodecResult.InvalidSampleRate;
            }

            return CreateDecoder(out decoder, workBufferHandle, parameter.SampleRate, parameter.ChannelsCount);
        }

        [CmifCommand(5)] // 12.0.0+
        public Result GetWorkBufferSizeEx(out int size, HardwareOpusDecoderParameterInternalEx parameter)
        {
            return GetWorkBufferSizeExImpl(out size, in parameter, fromDsp: false);
        }

        [CmifCommand(6)] // 12.0.0+
        public Result OpenHardwareOpusDecoderForMultiStreamEx(
            out IHardwareOpusDecoder decoder,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.Pointer, 0x118)] in HardwareOpusMultiStreamDecoderParameterInternalEx parameter,
            [CopyHandle] int workBufferHandle,
            int workBufferSize)
        {
            decoder = null;

            if (!IsValidSampleRate(parameter.SampleRate))
            {
                HorizonStatic.Syscall.CloseHandle(workBufferHandle);

                return CodecResult.InvalidSampleRate;
            }

            if (!IsValidMultiChannelCount(parameter.ChannelsCount))
            {
                HorizonStatic.Syscall.CloseHandle(workBufferHandle);

                return CodecResult.InvalidChannelCount;
            }

            if (!IsValidNumberOfStreams(parameter.NumberOfStreams, parameter.NumberOfStereoStreams, parameter.ChannelsCount))
            {
                HorizonStatic.Syscall.CloseHandle(workBufferHandle);

                return CodecResult.InvalidNumberOfStreams;
            }

            return CreateDecoder(out decoder, workBufferHandle, parameter.SampleRate, parameter.ChannelsCount, parameter.NumberOfStreams, parameter.NumberOfStereoStreams, parameter.ChannelMappings.AsSpan().ToArray());
        }

        [CmifCommand(7)] // 12.0.0+
        public Result GetWorkBufferSizeForMultiStreamEx(
            out int size,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.Pointer, 0x118)] in HardwareOpusMultiStreamDecoderParameterInternalEx parameter)
        {
            return GetWorkBufferSizeForMultiStreamExImpl(out size, in parameter, fromDsp: false);
        }

        [CmifCommand(8)] // 16.0.0+
        public Result GetWorkBufferSizeExEx(out int size, HardwareOpusDecoderParameterInternalEx parameter)
        {
            return GetWorkBufferSizeExImpl(out size, in parameter, fromDsp: true);
        }

        [CmifCommand(9)] // 16.0.0+
        public Result GetWorkBufferSizeForMultiStreamExEx(
            out int size,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.Pointer, 0x118)] in HardwareOpusMultiStreamDecoderParameterInternalEx parameter)
        {
            return GetWorkBufferSizeForMultiStreamExImpl(out size, in parameter, fromDsp: true);
        }

        // S2Arm：Switch 2 的硬件音频编解码客户端会话（sdk nn::codec::hwacod::shim::GetClientHipcSession 取的就是这条）
        [CmifCommand(100)]
        public Result GetHardwareAudioCodecClientSession(out IHardwareAudioCodecClientSession session)
        {
            session = new HardwareAudioCodecClientSession();

            return Result.Success;
        }

        private static Result GetWorkBufferSizeExImpl(out int size, in HardwareOpusDecoderParameterInternalEx parameter, bool fromDsp)
        {
            size = 0;

            if (!IsValidChannelCount(parameter.ChannelsCount))
            {
                return CodecResult.InvalidChannelCount;
            }

            if (!IsValidSampleRate(parameter.SampleRate))
            {
                return CodecResult.InvalidSampleRate;
            }

            int opusDecoderSize = fromDsp ? GetDspOpusDecoderSize(parameter.ChannelsCount) : GetOpusDecoderSize(parameter.ChannelsCount);

            int frameSizeMono48KHz = parameter.Flags.HasFlag(OpusDecoderFlags.LargeFrameSize) ? 5760 : 1920;
            int sampleRateRatio = parameter.SampleRate != 0 ? 48000 / parameter.SampleRate : 0;
            int frameSize = BitUtils.AlignUp(sampleRateRatio != 0 ? parameter.ChannelsCount * frameSizeMono48KHz / sampleRateRatio : 0, 64);
            size = opusDecoderSize + 1536 + frameSize;

            return Result.Success;
        }

        private static Result GetWorkBufferSizeForMultiStreamExImpl(out int size, in HardwareOpusMultiStreamDecoderParameterInternalEx parameter, bool fromDsp)
        {
            size = 0;

            if (!IsValidMultiChannelCount(parameter.ChannelsCount))
            {
                return CodecResult.InvalidChannelCount;
            }

            if (!IsValidSampleRate(parameter.SampleRate))
            {
                return CodecResult.InvalidSampleRate;
            }

            if (!IsValidNumberOfStreams(parameter.NumberOfStreams, parameter.NumberOfStereoStreams, parameter.ChannelsCount))
            {
                return CodecResult.InvalidSampleRate;
            }

            int opusDecoderSize = fromDsp
                ? GetDspOpusMultistreamDecoderSize(parameter.NumberOfStreams, parameter.NumberOfStereoStreams)
                : GetOpusMultistreamDecoderSize(parameter.NumberOfStreams, parameter.NumberOfStereoStreams);

            int frameSizeMono48KHz = parameter.Flags.HasFlag(OpusDecoderFlags.LargeFrameSize) ? 5760 : 1920;
            int streamSize = BitUtils.AlignUp(parameter.NumberOfStreams * 1500, 64);
            int sampleRateRatio = parameter.SampleRate != 0 ? 48000 / parameter.SampleRate : 0;
            int frameSize = BitUtils.AlignUp(sampleRateRatio != 0 ? parameter.ChannelsCount * frameSizeMono48KHz / sampleRateRatio : 0, 64);
            size = opusDecoderSize + streamSize + frameSize;

            return Result.Success;
        }

        private static int GetDspOpusDecoderSize(int channelsCount)
        {
            // TODO: Figure out the size returned here.
            // Not really important because we don't use the work buffer, and the size being lower is fine.

            return 0;
        }

        private static int GetDspOpusMultistreamDecoderSize(int streams, int coupledStreams)
        {
            // TODO: Figure out the size returned here.
            // Not really important because we don't use the work buffer, and the size being lower is fine.

            return 0;
        }

        private static int GetOpusDecoderSize(int channelsCount)
        {
            const int SilkDecoderSize = 0x2160;

            if (channelsCount is < 1 or > 2)
            {
                return 0;
            }

            int celtDecoderSize = GetCeltDecoderSize(channelsCount);
            int opusDecoderSize = GetOpusDecoderAllocSize(channelsCount) | 0x50;

            return opusDecoderSize + SilkDecoderSize + celtDecoderSize;
        }

        private static int GetOpusMultistreamDecoderSize(int streams, int coupledStreams)
        {
            if (streams < 1 || coupledStreams > streams || coupledStreams < 0)
            {
                return 0;
            }

            int coupledSize = GetOpusDecoderSize(2);
            int monoSize = GetOpusDecoderSize(1);

            return Align4(monoSize - GetOpusDecoderAllocSize(1)) * (streams - coupledStreams) +
                Align4(coupledSize - GetOpusDecoderAllocSize(2)) * coupledStreams + 0xb920;
        }

        private static int Align4(int value)
        {
            return BitUtils.AlignUp(value, 4);
        }

        private static int GetOpusDecoderAllocSize(int channelsCount)
        {
            return channelsCount * 0x800 + 0x4800;
        }

        private static int GetCeltDecoderSize(int channelsCount)
        {
            const int DecodeBufferSize = 0x2030;
            const int Overlap = 120;
            const int EBandsCount = 21;

            return (DecodeBufferSize + Overlap * 4) * channelsCount + EBandsCount * 16 + 0x54;
        }

        private static bool IsValidChannelCount(int channelsCount)
        {
            return channelsCount is > 0 and <= 2;
        }

        private static bool IsValidMultiChannelCount(int channelsCount)
        {
            return channelsCount is > 0 and <= 255;
        }

        private static bool IsValidSampleRate(int sampleRate)
        {
            switch (sampleRate)
            {
                case 8000:
                case 12000:
                case 16000:
                case 24000:
                case 48000:
                    return true;
            }

            return false;
        }

        private static bool IsValidNumberOfStreams(int numberOfStreams, int numberOfStereoStreams, int channelsCount)
        {
            return numberOfStreams > 0 &&
                numberOfStreams + numberOfStereoStreams <= channelsCount &&
                numberOfStereoStreams >= 0 &&
                numberOfStereoStreams <= numberOfStreams;
        }
    }
}
