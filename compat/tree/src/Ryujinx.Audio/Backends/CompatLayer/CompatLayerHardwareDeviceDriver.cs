using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Backends.Dummy;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Common.Logging;
using Ryujinx.Memory;
using System;
using System.Threading;
using static Ryujinx.Audio.Integration.IHardwareDeviceDriver;

namespace Ryujinx.Audio.Backends.CompatLayer
{
    public class CompatLayerHardwareDeviceDriver : IHardwareDeviceDriver
    {
        private readonly IHardwareDeviceDriver _realDriver;

        public static bool IsSupported => true;

        public float Volume
        {
            get => _realDriver.Volume;
            set => _realDriver.Volume = value;
        }

        public CompatLayerHardwareDeviceDriver(IHardwareDeviceDriver realDevice)
        {
            _realDriver = realDevice;
        }

        public void Dispose()
        {
            GC.SuppressFinalize(this);
            _realDriver.Dispose();
        }

        public ManualResetEvent GetUpdateRequiredEvent()
        {
            return _realDriver.GetUpdateRequiredEvent();
        }

        public ManualResetEvent GetPauseEvent()
        {
            return _realDriver.GetPauseEvent();
        }

        private uint SelectHardwareChannelCount(uint targetChannelCount)
        {
            if (_realDriver.SupportsChannelCount(targetChannelCount))
            {
                return targetChannelCount;
            }

            return targetChannelCount switch
            {
                6 => SelectHardwareChannelCount(2),
                2 => SelectHardwareChannelCount(1),
                1 => throw new ArgumentException("No valid channel configuration found!"),
                _ => throw new ArgumentException($"Invalid targetChannelCount {targetChannelCount}"),
            };
        }

        private SampleFormat SelectHardwareSampleFormat(SampleFormat targetSampleFormat)
        {
            if (_realDriver.SupportsSampleFormat(targetSampleFormat))
            {
                return targetSampleFormat;
            }

            // S2Arm: the session decodes any guest format to PCM16 first (CompatLayerHardwareDeviceSession.ReadSamples), so a format
            //   the device lacks goes through PCM16: straight to it when the device takes PCM16, else on to the chain below (was:
            //   only PCM16 guests could be converted; audsmx external streams also send PcmInt8 / PcmInt32 / PcmFloat)
            if (targetSampleFormat != SampleFormat.PcmInt16)
            {
                return SelectHardwareSampleFormat(SampleFormat.PcmInt16);
            }

            // Attempt conversion from PCM16.
            if (targetSampleFormat == SampleFormat.PcmInt16)
            {
                // Prefer PCM32 if we need to convert.
                if (_realDriver.SupportsSampleFormat(SampleFormat.PcmInt32))
                {
                    return SampleFormat.PcmInt32;
                }

                // If not supported, PCM float provides the best quality with a cost lower than PCM24.
                if (_realDriver.SupportsSampleFormat(SampleFormat.PcmFloat))
                {
                    return SampleFormat.PcmFloat;
                }

                if (_realDriver.SupportsSampleFormat(SampleFormat.PcmInt24))
                {
                    return SampleFormat.PcmInt24;
                }

                // If nothing is truly supported, attempt PCM8 at the cost of losing quality.
                if (_realDriver.SupportsSampleFormat(SampleFormat.PcmInt8))
                {
                    return SampleFormat.PcmInt8;
                }
            }

            throw new ArgumentException("No valid sample format configuration found!");
        }

        public IHardwareDeviceSession OpenDeviceSession(Direction direction, IVirtualMemoryManager memoryManager, SampleFormat sampleFormat, uint sampleRate, uint channelCount)
        {
            if (channelCount == 0)
            {
                channelCount = 2;
            }

            if (sampleRate == 0)
            {
                sampleRate = Constants.TargetSampleRate;
            }

            if (!_realDriver.SupportsDirection(direction))
            {
                if (direction == Direction.Input)
                {
                    Logger.Warning?.Print(LogClass.Audio, "The selected audio backend doesn't support audio input, fallback to dummy...");

                    return new DummyHardwareDeviceSessionInput(this, memoryManager);
                }

                throw new NotImplementedException();
            }

            // S2Arm（#2151）：收音没有格式 / 声道转换（下面原先选硬件格式后对不上就整条退成 Dummy，单声道收音永远拿不到真麦克风）：
            //   支持收音的后端照游戏要的格式原样开（Apple 收音会话由 AudioQueue 按游戏格式出数、系统自己重采样）
            if (direction == Direction.Input)
            {
                return _realDriver.OpenDeviceSession(direction, memoryManager, sampleFormat, sampleRate, channelCount);
            }

            SampleFormat hardwareSampleFormat = SelectHardwareSampleFormat(sampleFormat);
            uint hardwareChannelCount = SelectHardwareChannelCount(channelCount);

            IHardwareDeviceSession realSession = _realDriver.OpenDeviceSession(direction, memoryManager, hardwareSampleFormat, sampleRate, hardwareChannelCount);

            if (hardwareChannelCount == channelCount && hardwareSampleFormat == sampleFormat)
            {
                return realSession;
            }

            if (hardwareSampleFormat != sampleFormat)
            {
                Logger.Warning?.Print(LogClass.Audio, $"{sampleFormat} isn't supported by the audio device, conversion to {hardwareSampleFormat} will happen.");

                if (hardwareSampleFormat < sampleFormat)
                {
                    Logger.Warning?.Print(LogClass.Audio, $"{hardwareSampleFormat} has lower quality than {sampleFormat}, expect some loss in audio fidelity.");
                }
            }

            // It must be a HardwareDeviceSessionOutputBase.
            if (realSession is not HardwareDeviceSessionOutputBase realSessionOutputBase)
            {
                throw new InvalidOperationException($"Real driver session class type isn't based on {typeof(HardwareDeviceSessionOutputBase).Name}.");
            }

            // If we need to do post processing before sending to the hardware device, wrap around it.
            return new CompatLayerHardwareDeviceSession(realSessionOutputBase, sampleFormat, channelCount);
        }

        public bool SupportsChannelCount(uint channelCount)
        {
            return channelCount is 1 or 2 or 6;
        }

        public bool SupportsSampleFormat(SampleFormat sampleFormat)
        {
            // TODO: More formats.
            return sampleFormat == SampleFormat.PcmInt16;
        }

        public bool SupportsSampleRate(uint sampleRate)
        {
            // TODO: More sample rates.
            return sampleRate == Constants.TargetSampleRate;
        }

        public IHardwareDeviceDriver GetRealDeviceDriver()
        {
            return _realDriver;
        }

        public bool SupportsDirection(Direction direction)
        {
            return direction is Direction.Input or Direction.Output;
        }
    }
}
