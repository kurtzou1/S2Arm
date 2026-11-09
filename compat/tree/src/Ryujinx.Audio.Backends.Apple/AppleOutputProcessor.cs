using Ryujinx.Audio.Backends.Apple.Native;
using Ryujinx.Audio.Backends.CompatLayer;
using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Backends.Apple
{
    // S2Arm: 5.1 (6-channel PCM16) -> stereo output modes for the Apple backend.
    //
    // Why: the Apple backend reports 6-channel support, so the renderer produces a 5.1 mix, and the AudioQueue is
    // created with a 6-channel format. AudioQueue's implicit 6 -> 2 conversion only copies front left/right when no
    // channel layout is known (measured on macOS 26.7.1 with AudioQueueSetOfflineRenderFormat: FC, LFE, BL and BR
    // all came out zero), so dialogue and surround were lost. Even with the layout declared, the implicit mix is
    // L = FL + 0.704*C + 0.704*BL (and the right mirror) with LFE dropped, i.e. no headroom.
    //
    // Modes (S2A_AUDIO_OUT, opt-in; the default is native and keeps the upstream path):
    //   sys     - AudioConverter with kAudioConverterPropertyPerformDownmix + channel layouts: the system's explicit
    //             downmix. Measured gains: front 0.4142, centre/surround 0.2929, LFE dropped.
    //   spatial - AUSM ('3dem'), kSpatializationAlgorithm_UseOutputType + AmbienceBed, 6-channel bed -> stereo.
    //   matrix  - host Q15 downmix with the same coefficients as Downmixing.DownMixSurroundToStereo. This is the
    //             fallback when a sys/spatial device cannot be built or a slice fails; it can also be selected
    //             explicitly for A/B against the compat layer.
    //   native  - 6-channel PCM straight into the AudioQueue (the upstream behaviour, default).
    internal enum AppleOutputMode
    {
        Native = 0,
        Matrix = 1,
        System = 2,
        Spatial = 3,
    }

    internal static class AppleOutputModeSelector
    {
        private const AppleOutputMode DefaultMode = AppleOutputMode.Native;

        public static AppleOutputMode FromEnvironment()
        {
            string value = Environment.GetEnvironmentVariable("S2A_AUDIO_OUT");

            if (string.IsNullOrWhiteSpace(value))
            {
                return DefaultMode;
            }

            switch (value.Trim().ToLowerInvariant())
            {
                case "matrix":
                case "q15":
                    return AppleOutputMode.Matrix;
                case "sys":
                case "system":
                case "converter":
                    return AppleOutputMode.System;
                case "spatial":
                case "ausm":
                    return AppleOutputMode.Spatial;
                case "native":
                case "off":
                    return AppleOutputMode.Native;
                default:
                    Console.Error.WriteLine($"[声] 【红】S2A_AUDIO_OUT=「{value}」不认识（可用 matrix / sys / spatial / native）：按 {ModeName(DefaultMode)}");
                    return DefaultMode;
            }
        }

        public static string ModeName(AppleOutputMode mode)
        {
            return mode switch
            {
                AppleOutputMode.Matrix => "矩阵（Q15）",
                AppleOutputMode.System => "系统显式下混（AudioConverter）",
                AppleOutputMode.Spatial => "空间化（AUSM '3dem'）",
                _ => "native（上游现状：6 声道直交 AudioQueue）",
            };
        }
    }

    // One instance per 6-channel output session. Process() is called from the device pump (guest buffers) and from
    // the renderer thread (Data buffers), so it serialises internally. Input is interleaved PCM16 6-channel
    // (FL FR FC LFE BL BR, the renderer's channel order), output is interleaved PCM16 stereo; the frame count is
    // preserved, so the session's byte accounting and release cadence stay unchanged.
    internal sealed unsafe class AppleOutputProcessor : IDisposable
    {
        private const int InputChannels = 6;
        private const int OutputChannels = 2;
        private const int InputBytesPerFrame = InputChannels * sizeof(short);
        private const int OutputBytesPerFrame = OutputChannels * sizeof(short);

        private readonly object _lock = new();
        private readonly AppleOutputMode _requestedMode;
        private readonly int _sampleRate;
        private readonly int _maxFrames;
        private AppleOutputMode _mode;
        private int _failures;
        private bool _disposed;

        // AudioConverter ('sys')
        private nint _converter;
        private nint _convInputProcPtr;
        private nint _convOutputAbl;
        private AppleAudioUnits.AudioConverterComplexInputDataProc _convInputProc;
        private int _convFrames;
        private nint _convInput;
        private int _convDone;

        // AUSM ('spatial')
        private nint _unit;
        private nint _renderProcPtr;
        private AppleAudioUnits.AURenderCallback _renderProc;
        private nint _outAbl;
        private readonly nint[] _inPlanes = new nint[InputChannels];
        private nint _outLeft;
        private nint _outRight;
        private double _sequence;

        private GCHandle _self;

        public string InitError { get; private set; }
        public AppleOutputMode EffectiveMode => _mode;

        private AppleOutputProcessor(AppleOutputMode mode, int sampleRate, int maxFrames)
        {
            _requestedMode = mode;
            _sampleRate = sampleRate;
            _maxFrames = Math.Max(16, maxFrames);
            _mode = mode;
        }

        // Never returns null and never leaves a mode that cannot produce audio: a converter / AUSM that cannot be
        // built falls back to matrix (InitError says why; the caller logs it once).
        public static AppleOutputProcessor Create(AppleOutputMode mode, int sampleRate, int maxFrames)
        {
            AppleOutputProcessor processor = new(mode, sampleRate, maxFrames);

            if (mode == AppleOutputMode.System && !processor.InitSystem())
            {
                processor._mode = AppleOutputMode.Matrix;
            }
            else if (mode == AppleOutputMode.Spatial && !processor.InitSpatial())
            {
                processor._mode = AppleOutputMode.Matrix;
            }

            return processor;
        }

        private static AudioToolbox.AudioStreamBasicDescription MakeFormat(int rate, int channels)
        {
            return new AudioToolbox.AudioStreamBasicDescription
            {
                SampleRate = rate,
                FormatID = AudioToolbox.kAudioFormatLinearPCM,
                FormatFlags = AudioToolbox.kAudioFormatFlagIsSignedInteger | AudioToolbox.kAudioFormatFlagIsPacked,
                BytesPerPacket = (uint)(channels * sizeof(short)),
                FramesPerPacket = 1,
                BytesPerFrame = (uint)(channels * sizeof(short)),
                ChannelsPerFrame = (uint)channels,
                BitsPerChannel = 16,
                Reserved = 0,
            };
        }

        private static AudioToolbox.AudioChannelLayout Layout(uint tag)
        {
            return new AudioToolbox.AudioChannelLayout
            {
                AudioChannelLayoutTag = tag,
                AudioChannelBitmap = 0,
                NumberChannelDescriptions = 0,
            };
        }

        private bool InitSystem()
        {
            AudioToolbox.AudioStreamBasicDescription input = MakeFormat(_sampleRate, InputChannels);
            AudioToolbox.AudioStreamBasicDescription output = MakeFormat(_sampleRate, OutputChannels);

            int rc = AppleAudioUnits.AudioConverterNew(ref input, ref output, out _converter);

            if (rc != 0 || _converter == 0)
            {
                InitError = $"AudioConverterNew rc={rc}";

                return false;
            }

            AudioToolbox.AudioChannelLayout inputLayout = Layout(AppleAudioUnits.ChannelLayoutTagMpeg51A);
            AudioToolbox.AudioChannelLayout outputLayout = Layout(AppleAudioUnits.ChannelLayoutTagStereo);

            rc = AppleAudioUnits.AudioConverterSetProperty(_converter, AppleAudioUnits.PropertyInputChannelLayout,
                (uint)sizeof(AudioToolbox.AudioChannelLayout), &inputLayout);

            if (rc == 0)
            {
                rc = AppleAudioUnits.AudioConverterSetProperty(_converter, AppleAudioUnits.PropertyOutputChannelLayout,
                    (uint)sizeof(AudioToolbox.AudioChannelLayout), &outputLayout);
            }

            uint downmix = 1;

            if (rc == 0)
            {
                rc = AppleAudioUnits.AudioConverterSetProperty(_converter, AppleAudioUnits.PropertyPerformDownmix,
                    sizeof(uint), &downmix);
            }

            if (rc != 0)
            {
                InitError = $"AudioConverter 布局 / PerformDownmix rc={rc}";
                AppleAudioUnits.AudioConverterDispose(_converter);
                _converter = 0;

                return false;
            }

            _self = GCHandle.Alloc(this);
            _convInputProc = ConverterInput;
            _convInputProcPtr = Marshal.GetFunctionPointerForDelegate(_convInputProc);
            _convOutputAbl = Marshal.AllocHGlobal(AppleAudioUnits.AudioBufferListBuffersOffset + sizeof(AppleAudioUnits.AudioBuffer));

            return true;
        }

        private bool InitSpatial()
        {
            AppleAudioUnits.AudioComponentDescription desc = new()
            {
                ComponentType = AppleAudioUnits.AudioUnitTypeMixer,
                ComponentSubType = AppleAudioUnits.AudioUnitSubTypeSpatialMixer,
                ComponentManufacturer = AppleAudioUnits.AudioUnitManufacturerApple,
            };

            nint component = AppleAudioUnits.AudioComponentFindNext(0, ref desc);

            if (component == 0)
            {
                InitError = "AUSM '3dem' 组件不存在";

                return false;
            }

            int rc = AppleAudioUnits.AudioComponentInstanceNew(component, out _unit);

            if (rc != 0 || _unit == 0)
            {
                InitError = $"AUSM 实例 rc={rc}";

                return false;
            }

            AudioToolbox.AudioStreamBasicDescription format = new()
            {
                SampleRate = _sampleRate,
                FormatID = AudioToolbox.kAudioFormatLinearPCM,
                FormatFlags = AudioToolbox.kAudioFormatFlagIsFloat | AudioToolbox.kAudioFormatFlagsNativeEndian | AudioToolbox.kAudioFormatFlagIsNonInterleaved,
                BytesPerPacket = sizeof(float),
                FramesPerPacket = 1,
                BytesPerFrame = sizeof(float),
                ChannelsPerFrame = OutputChannels,
                BitsPerChannel = 32,
                Reserved = 0,
            };

            AudioToolbox.AudioChannelLayout outputLayout = Layout(AppleAudioUnits.ChannelLayoutTagStereo);
            rc = AppleAudioUnits.AudioUnitSetProperty(_unit, AppleAudioUnits.PropertyStreamFormat,
                AppleAudioUnits.ScopeOutput, 0, &format, (uint)sizeof(AudioToolbox.AudioStreamBasicDescription));

            if (rc == 0)
            {
                rc = AppleAudioUnits.AudioUnitSetProperty(_unit, AppleAudioUnits.PropertyAudioChannelLayout,
                    AppleAudioUnits.ScopeOutput, 0, &outputLayout, (uint)sizeof(AudioToolbox.AudioChannelLayout));
            }

            format.ChannelsPerFrame = InputChannels;

            if (rc == 0)
            {
                rc = AppleAudioUnits.AudioUnitSetProperty(_unit, AppleAudioUnits.PropertyStreamFormat,
                    AppleAudioUnits.ScopeInput, 0, &format, (uint)sizeof(AudioToolbox.AudioStreamBasicDescription));
            }

            AudioToolbox.AudioChannelLayout inputLayout = Layout(AppleAudioUnits.ChannelLayoutTagMpeg51A);

            if (rc == 0)
            {
                rc = AppleAudioUnits.AudioUnitSetProperty(_unit, AppleAudioUnits.PropertyAudioChannelLayout,
                    AppleAudioUnits.ScopeInput, 0, &inputLayout, (uint)sizeof(AudioToolbox.AudioChannelLayout));
            }

            uint one = 1;

            if (rc == 0)
            {
                rc = AppleAudioUnits.AudioUnitSetProperty(_unit, AppleAudioUnits.PropertyElementCount,
                    AppleAudioUnits.ScopeInput, 0, &one, sizeof(uint));
            }

            uint maxFrames = (uint)_maxFrames;

            if (rc == 0)
            {
                rc = AppleAudioUnits.AudioUnitSetProperty(_unit, AppleAudioUnits.PropertyMaximumFramesPerSlice,
                    AppleAudioUnits.ScopeGlobal, 0, &maxFrames, sizeof(uint));
            }

            uint algorithm = AppleAudioUnits.SpatializationUseOutputType;
            uint sourceMode = AppleAudioUnits.SpatialMixerSourceModeAmbienceBed;

            if (rc == 0)
            {
                rc = AppleAudioUnits.AudioUnitSetProperty(_unit, AppleAudioUnits.PropertySpatializationAlgorithm,
                    AppleAudioUnits.ScopeInput, 0, &algorithm, sizeof(uint));
            }

            if (rc == 0)
            {
                rc = AppleAudioUnits.AudioUnitSetProperty(_unit, AppleAudioUnits.PropertySpatialMixerSourceMode,
                    AppleAudioUnits.ScopeInput, 0, &sourceMode, sizeof(uint));
            }

            if (rc != 0)
            {
                InitError = $"AUSM 属性 rc={rc}";
                DisposeUnit();

                return false;
            }

            _self = GCHandle.Alloc(this);
            _renderProc = RenderInput;
            _renderProcPtr = Marshal.GetFunctionPointerForDelegate(_renderProc);
            nint callback = Marshal.AllocHGlobal(sizeof(nint) * 2);

            *(nint*)callback = _renderProcPtr;
            *(nint*)(callback + sizeof(nint)) = GCHandle.ToIntPtr(_self);

            if (rc == 0)
            {
                rc = AppleAudioUnits.AudioUnitSetProperty(_unit, AppleAudioUnits.PropertySetRenderCallback,
                    AppleAudioUnits.ScopeInput, 0, (void*)callback, (uint)(sizeof(nint) * 2));
            }

            Marshal.FreeHGlobal(callback);

            if (rc != 0)
            {
                InitError = $"AUSM 渲染回调 rc={rc}";
                DisposeUnit();

                return false;
            }

            for (int i = 0; i < InputChannels; i++)
            {
                _inPlanes[i] = Marshal.AllocHGlobal(_maxFrames * sizeof(float));
            }

            _outLeft = Marshal.AllocHGlobal(_maxFrames * sizeof(float));
            _outRight = Marshal.AllocHGlobal(_maxFrames * sizeof(float));
            _outAbl = Marshal.AllocHGlobal(AppleAudioUnits.AudioBufferListBuffersOffset + 2 * sizeof(AppleAudioUnits.AudioBuffer));

            rc = AppleAudioUnits.AudioUnitInitialize(_unit);

            if (rc != 0)
            {
                InitError = $"AUSM 初始化 rc={rc}";
                DisposeUnit();

                return false;
            }

            return true;
        }

        public bool Process(ReadOnlySpan<byte> input, Span<byte> output)
        {
            int frames = Math.Min(input.Length / InputBytesPerFrame, output.Length / OutputBytesPerFrame);

            if (frames <= 0)
            {
                return true;
            }

            lock (_lock)
            {
                if (_disposed)
                {
                    return false;
                }

                if (_mode == AppleOutputMode.Matrix)
                {
                    MatrixDownmix(input, output, frames);

                    return true;
                }

                if (_mode == AppleOutputMode.System && ConvertSystem(input, output, frames))
                {
                    return true;
                }

                if (_mode == AppleOutputMode.Spatial && RenderSpatial(input, output, frames))
                {
                    return true;
                }

                MatrixDownmix(input, output, frames);
                CountFailure();

                return false;
            }
        }

        private void CountFailure()
        {
            _failures++;

            if (_failures == 1)
            {
                Console.Error.WriteLine($"[声] 【红】5.1→2.0 档「{AppleOutputModeSelector.ModeName(_requestedMode)}」这一次没出数：这一片按矩阵下混");
            }
        }

        private static void MatrixDownmix(ReadOnlySpan<byte> input, Span<byte> output, int frames)
        {
            ReadOnlySpan<short> source = MemoryMarshal.Cast<byte, short>(input)[..(frames * InputChannels)];
            Span<short> destination = MemoryMarshal.Cast<byte, short>(output)[..(frames * OutputChannels)];

            Downmixing.DownMixSurroundToStereo(source, destination);
        }

        private bool ConvertSystem(ReadOnlySpan<byte> input, Span<byte> output, int frames)
        {
            int remaining = frames;
            int frameOffset = 0;

            while (remaining > 0)
            {
                int chunk = Math.Min(remaining, _maxFrames);
                int inputBytes = chunk * InputBytesPerFrame;
                int outputBytes = chunk * OutputBytesPerFrame;
                bool ok;

                fixed (byte* inputPtr = input.Slice(frameOffset * InputBytesPerFrame, inputBytes))
                fixed (byte* outputPtr = output.Slice(frameOffset * OutputBytesPerFrame, outputBytes))
                {
                    _convInput = (nint)inputPtr;
                    _convFrames = chunk;
                    _convDone = 0;

                    AppleAudioUnits.AudioBuffer* buffer = (AppleAudioUnits.AudioBuffer*)(_convOutputAbl + AppleAudioUnits.AudioBufferListBuffersOffset);

                    *(uint*)_convOutputAbl = 1;
                    buffer->NumberChannels = OutputChannels;
                    buffer->DataByteSize = (uint)outputBytes;
                    buffer->Data = outputPtr;

                    uint outputFrames = (uint)chunk;
                    int rc = AppleAudioUnits.AudioConverterFillComplexBuffer(_converter, _convInputProcPtr,
                        GCHandle.ToIntPtr(_self), ref outputFrames, _convOutputAbl, 0);

                    ok = rc == 0 && outputFrames == (uint)chunk;
                }

                if (!ok)
                {
                    return false;
                }

                frameOffset += chunk;
                remaining -= chunk;
            }

            return true;
        }

        private static int ConverterInput(nint converter, ref uint ioPackets, nint ioData, nint packetDescription, nint userData)
        {
            AppleOutputProcessor processor = (AppleOutputProcessor)GCHandle.FromIntPtr(userData).Target;

            if (processor._convDone != 0)
            {
                ioPackets = 0;

                return 0;
            }

            AppleAudioUnits.AudioBuffer* buffer = (AppleAudioUnits.AudioBuffer*)(ioData + AppleAudioUnits.AudioBufferListBuffersOffset);

            *(uint*)ioData = 1;
            buffer->NumberChannels = InputChannels;
            buffer->DataByteSize = (uint)(processor._convFrames * InputBytesPerFrame);
            buffer->Data = (void*)processor._convInput;
            processor._convDone = 1;
            ioPackets = (uint)processor._convFrames;

            return 0;
        }

        private bool RenderSpatial(ReadOnlySpan<byte> input, Span<byte> output, int frames)
        {
            int remaining = frames;
            int frameOffset = 0;

            while (remaining > 0)
            {
                int chunk = Math.Min(remaining, _maxFrames);

                ReadOnlySpan<short> source = MemoryMarshal.Cast<byte, short>(input.Slice(frameOffset * InputBytesPerFrame, chunk * InputBytesPerFrame));

                for (int channel = 0; channel < InputChannels; channel++)
                {
                    float* plane = (float*)_inPlanes[channel];
                    int index = channel;

                    for (int frame = 0; frame < chunk; frame++, index += InputChannels)
                    {
                        plane[frame] = source[index] * (1.0f / 32768.0f);
                    }
                }

                AppleAudioUnits.AudioBuffer* outputLeft = (AppleAudioUnits.AudioBuffer*)(_outAbl + AppleAudioUnits.AudioBufferListBuffersOffset);
                AppleAudioUnits.AudioBuffer* outputRight = outputLeft + 1;
                uint bytes = (uint)(chunk * sizeof(float));

                *(uint*)_outAbl = 2;
                outputLeft->NumberChannels = 1;
                outputLeft->DataByteSize = bytes;
                outputLeft->Data = (void*)_outLeft;
                outputRight->NumberChannels = 1;
                outputRight->DataByteSize = bytes;
                outputRight->Data = (void*)_outRight;

                AppleAudioUnits.AudioTimeStamp timestamp = default;
                timestamp.SampleTime = _sequence;
                timestamp.Flags = AppleAudioUnits.AudioTimeStampSampleTimeValid;

                uint renderFlags = 0;
                int rc = AppleAudioUnits.AudioUnitRender(_unit, (nint)(&renderFlags), ref timestamp, 0, (uint)chunk, _outAbl);

                if (rc != 0)
                {
                    return false;
                }

                _sequence += chunk;

                Span<short> destination = MemoryMarshal.Cast<byte, short>(output.Slice(frameOffset * OutputBytesPerFrame, chunk * OutputBytesPerFrame));
                float* left = (float*)_outLeft;
                float* right = (float*)_outRight;

                for (int frame = 0; frame < chunk; frame++)
                {
                    destination[frame * 2] = ToPcm16(left[frame]);
                    destination[frame * 2 + 1] = ToPcm16(right[frame]);
                }

                frameOffset += chunk;
                remaining -= chunk;
            }

            return true;
        }

        private static short ToPcm16(float value)
        {
            long sample = (long)MathF.Round(value * 32768.0f);

            return (short)Math.Clamp(sample, short.MinValue, short.MaxValue);
        }

        private static int RenderInput(nint refCon, nint actionFlags, nint timeStamp, uint busNumber, uint frames, nint ioData)
        {
            AppleOutputProcessor processor = (AppleOutputProcessor)GCHandle.FromIntPtr(refCon).Target;
            uint buffers = *(uint*)ioData;
            AppleAudioUnits.AudioBuffer* first = (AppleAudioUnits.AudioBuffer*)(ioData + AppleAudioUnits.AudioBufferListBuffersOffset);
            uint bytes = frames * sizeof(float);

            for (uint i = 0; i < buffers && i < InputChannels; i++)
            {
                first[i].NumberChannels = 1;
                first[i].DataByteSize = bytes;
                first[i].Data = (void*)processor._inPlanes[i];
            }

            return 0;
        }

        private void DisposeUnit()
        {
            if (_unit != 0)
            {
                AppleAudioUnits.AudioUnitSetProperty(_unit, AppleAudioUnits.PropertySetRenderCallback,
                    AppleAudioUnits.ScopeInput, 0, null, 0);
                AppleAudioUnits.AudioUnitUninitialize(_unit);
                AppleAudioUnits.AudioComponentInstanceDispose(_unit);
                _unit = 0;
            }

            for (int i = 0; i < InputChannels; i++)
            {
                if (_inPlanes[i] != 0)
                {
                    Marshal.FreeHGlobal(_inPlanes[i]);
                    _inPlanes[i] = 0;
                }
            }

            if (_outLeft != 0)
            {
                Marshal.FreeHGlobal(_outLeft);
                _outLeft = 0;
            }

            if (_outRight != 0)
            {
                Marshal.FreeHGlobal(_outRight);
                _outRight = 0;
            }

            if (_outAbl != 0)
            {
                Marshal.FreeHGlobal(_outAbl);
                _outAbl = 0;
            }

            if (_self.IsAllocated)
            {
                _self.Free();
            }
        }

        public void Dispose()
        {
            lock (_lock)
            {
                if (_disposed)
                {
                    return;
                }

                _disposed = true;

                if (_converter != 0)
                {
                    AppleAudioUnits.AudioConverterDispose(_converter);
                    _converter = 0;
                }

                if (_convOutputAbl != 0)
                {
                    Marshal.FreeHGlobal(_convOutputAbl);
                    _convOutputAbl = 0;
                }

                DisposeUnit();
            }
        }
    }
}
