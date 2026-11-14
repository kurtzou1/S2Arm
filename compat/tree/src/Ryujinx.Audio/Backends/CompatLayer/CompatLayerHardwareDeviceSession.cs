using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Renderer.Dsp;
using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Backends.CompatLayer
{
    class CompatLayerHardwareDeviceSession : HardwareDeviceSessionOutputBase, Ryujinx.Audio.Integration.IS2AOutputDepth
    {
        // S2Arm (11-13 断音): the renderer's output always comes through this wrapper; pass the real session's depth through (frames:
        //   downmixing keeps the frame count, the rate is the real session's)
        public long S2ABufferedFrames => _realSession is Ryujinx.Audio.Integration.IS2AOutputDepth d ? d.S2ABufferedFrames : -1;

        private readonly HardwareDeviceSessionOutputBase _realSession;
        private readonly SampleFormat _userSampleFormat;
        private readonly uint _userChannelCount;

        // S2Arm: guest buffers are converted (downmix, then sample format) in chunks of this many units as the device reads them
        // (ReadSamples), instead of copying, downmixing and converting each whole buffer into new arrays sized by the game.
        // A unit is a frame when downmixing (output frame i only depends on input frame i), else one sample.
        private const int UnitsPerChunk = 256;
        private readonly bool _downmix;
        private readonly int _unitInSize;
        private readonly int _unitOutSize;
        // Renderer output (samples in Data, PCM16) converted to the real format: reused while the size stays the same
        private byte[] _convertedData;

        public CompatLayerHardwareDeviceSession(HardwareDeviceSessionOutputBase realSession, SampleFormat userSampleFormat, uint userChannelCount) : base(realSession.MemoryManager, realSession.RequestedSampleFormat, realSession.RequestedSampleRate, userChannelCount)
        {
            _realSession = realSession;
            _userSampleFormat = userSampleFormat;
            _userChannelCount = userChannelCount;

            _downmix = userChannelCount != realSession.RequestedChannelCount;
            _unitInSize = BackendHelper.GetSampleSize(userSampleFormat) * (_downmix ? (int)userChannelCount : 1);
            _unitOutSize = BackendHelper.GetSampleSize(realSession.RequestedSampleFormat) * (_downmix ? (int)realSession.RequestedChannelCount : 1);
        }

        public override void Dispose()
        {
            _realSession.Dispose();
        }

        public override ulong GetPlayedSampleCount()
        {
            return _realSession.GetPlayedSampleCount();
        }

        public override float GetVolume()
        {
            return _realSession.GetVolume();
        }

        public override void PrepareToClose()
        {
            _realSession.PrepareToClose();
        }

        public override void QueueBuffer(AudioBuffer buffer)
        {
            SampleFormat realSampleFormat = _realSession.RequestedSampleFormat;

            if (_userSampleFormat != realSampleFormat)
            {
                if (_userSampleFormat != SampleFormat.PcmInt16)
                {
                    throw new NotImplementedException("Converting formats other than PCM16 is not supported.");
                }

                if (realSampleFormat is not (SampleFormat.PcmInt8 or SampleFormat.PcmInt24 or SampleFormat.PcmInt32 or SampleFormat.PcmFloat))
                {
                    throw new NotImplementedException($"Sample format conversion from {_userSampleFormat} to {realSampleFormat} not implemented.");
                }

                // Guest buffers are converted as the device reads them (ReadSamples); only samples already in Data are converted here
                if (buffer.Data != null)
                {
                    ReadOnlySpan<short> samples = MemoryMarshal.Cast<byte, short>(buffer.Data);
                    int convertedSize = BackendHelper.GetSampleSize(realSampleFormat) * samples.Length;

                    if (_convertedData == null || _convertedData.Length != convertedSize)
                    {
                        _convertedData = new byte[convertedSize];
                    }

                    ConvertSamples(samples, _convertedData);

                    buffer.Data = _convertedData;
                }
            }

            _realSession.QueueBuffer(buffer);
        }

        public override bool RegisterBuffer(AudioBuffer buffer)
        {
            if (buffer.DataPointer == 0)
            {
                return false;
            }

            if (_downmix)
            {
                if (_userSampleFormat != SampleFormat.PcmInt16)
                {
                    throw new NotImplementedException("Downmixing formats other than PCM16 is not supported.");
                }

                if (_userChannelCount != 6 && !(_userChannelCount == 2 && _realSession.RequestedChannelCount == 1))
                {
                    throw new NotImplementedException($"Downmixing from {_userChannelCount} to {_realSession.RequestedChannelCount} not implemented.");
                }
            }

            // Size of the samples as the device will read them (whole units only, as the old whole-buffer downmix / conversion did).
            // The format conversion is included: it used to be applied to Data at QueueBuffer without updating DataSize, so the device
            // counted the converted buffer's samples at the user sample size.
            buffer.DataSize = buffer.DataSize / (ulong)_unitInSize * (ulong)_unitOutSize;
            buffer.SampleReader = this;

            return _realSession.RegisterBuffer(buffer);
        }

        public override void ReadSamples(AudioBuffer buffer, ulong offset, Span<byte> destination)
        {
            Span<byte> input = stackalloc byte[UnitsPerChunk * 6 * sizeof(short)];
            Span<short> stereo = stackalloc short[UnitsPerChunk * 2];
            Span<short> mono = stackalloc short[UnitsPerChunk];
            Span<byte> output = stackalloc byte[UnitsPerChunk * 2 * sizeof(float)];

            ulong unit = offset / (ulong)_unitOutSize;
            int skip = (int)(offset % (ulong)_unitOutSize);

            while (!destination.IsEmpty)
            {
                int units = Math.Min(UnitsPerChunk, (skip + destination.Length + _unitOutSize - 1) / _unitOutSize);
                Span<byte> inBytes = input[..(units * _unitInSize)];

                MemoryManager.Read(buffer.DataPointer + unit * (ulong)_unitInSize, inBytes);

                ReadOnlySpan<short> samples = MemoryMarshal.Cast<byte, short>(inBytes);

                if (_downmix)
                {
                    if (_userChannelCount == 6)
                    {
                        samples = Downmixing.DownMixSurroundToStereo(samples, stereo);

                        if (_realSession.RequestedChannelCount == 1)
                        {
                            samples = Downmixing.DownMixStereoToMono(samples, mono);
                        }
                    }
                    else
                    {
                        samples = Downmixing.DownMixStereoToMono(samples, mono);
                    }
                }

                Span<byte> outBytes = output[..(units * _unitOutSize)];

                if (_userSampleFormat != _realSession.RequestedSampleFormat)
                {
                    ConvertSamples(samples, outBytes);
                }
                else
                {
                    MemoryMarshal.AsBytes(samples).CopyTo(outBytes);
                }

                int n = Math.Min(outBytes.Length - skip, destination.Length);

                outBytes.Slice(skip, n).CopyTo(destination);

                destination = destination[n..];
                skip = 0;
                unit += (ulong)units;
            }
        }

        private void ConvertSamples(ReadOnlySpan<short> samples, Span<byte> convertedSamples)
        {
            switch (_realSession.RequestedSampleFormat)
            {
                case SampleFormat.PcmInt8:
                    PcmHelper.ConvertSampleToPcm8(MemoryMarshal.Cast<byte, sbyte>(convertedSamples), samples);
                    break;
                case SampleFormat.PcmInt24:
                    PcmHelper.ConvertSampleToPcm24(convertedSamples, samples);
                    break;
                case SampleFormat.PcmInt32:
                    PcmHelper.ConvertSampleToPcm32(MemoryMarshal.Cast<byte, int>(convertedSamples), samples);
                    break;
                case SampleFormat.PcmFloat:
                    PcmHelper.ConvertSampleToPcmFloat(MemoryMarshal.Cast<byte, float>(convertedSamples), samples);
                    break;
                default:
                    throw new NotImplementedException($"Sample format conversion from {_userSampleFormat} to {_realSession.RequestedSampleFormat} not implemented.");
            }
        }

        public override void SetVolume(float volume)
        {
            _realSession.SetVolume(volume);
        }

        public override void Start()
        {
            _realSession.Start();
        }

        public override void Stop()
        {
            _realSession.Stop();
        }

        public override void UnregisterBuffer(AudioBuffer buffer)
        {
            _realSession.UnregisterBuffer(buffer);
        }

        public override bool WasBufferFullyConsumed(AudioBuffer buffer)
        {
            return _realSession.WasBufferFullyConsumed(buffer);
        }
    }
}
