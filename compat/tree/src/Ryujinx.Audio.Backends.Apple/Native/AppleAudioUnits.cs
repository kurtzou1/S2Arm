using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Backends.Apple.Native
{
    // S2Arm: the small slice of AudioConverter / AudioUnit used by the optional 5.1 -> 2.0 output modes
    // (AppleOutputProcessor). The queue format bindings live in AudioToolbox.cs; these are the C APIs the
    // system downmix converter and the AUSM ('3dem') spatial mixer need.
    internal static unsafe class AppleAudioUnits
    {
        private const string Lib = "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox";

        // AudioComponentDescription
        public const uint AudioUnitTypeMixer = 0x61756D78;              // 'aumx'
        public const uint AudioUnitSubTypeSpatialMixer = 0x3364656D;    // '3dem'
        public const uint AudioUnitManufacturerApple = 0x6170706C;      // 'appl'

        // AudioUnit scopes
        public const uint ScopeGlobal = 0;
        public const uint ScopeInput = 1;
        public const uint ScopeOutput = 2;

        // AudioUnitPropertyID
        public const uint PropertyStreamFormat = 8;
        public const uint PropertyElementCount = 11;
        public const uint PropertyMaximumFramesPerSlice = 14;
        public const uint PropertyAudioChannelLayout = 19;
        public const uint PropertySetRenderCallback = 23;
        public const uint PropertySpatializationAlgorithm = 3000;
        public const uint PropertySpatialMixerSourceMode = 3005;

        public const uint SpatializationUseOutputType = 7;
        public const uint SpatialMixerSourceModeAmbienceBed = 3;

        // AudioConverterPropertyID
        public const uint PropertyPerformDownmix = 0x646D6978;          // 'dmix'
        public const uint PropertyInputChannelLayout = 0x69636C20;      // 'icl '
        public const uint PropertyOutputChannelLayout = 0x6F636C20;     // 'ocl '

        // AudioChannelLayoutTag
        public const uint ChannelLayoutTagStereo = 0x650002;            // (101 << 16) | 2
        public const uint ChannelLayoutTagMpeg51A = 0x790006;           // (121 << 16) | 6: FL FR FC LFE BL BR

        public const int AudioTimeStampSampleTimeValid = 1;

        [StructLayout(LayoutKind.Sequential)]
        public struct AudioComponentDescription
        {
            public uint ComponentType;
            public uint ComponentSubType;
            public uint ComponentManufacturer;
            public uint ComponentFlags;
            public uint ComponentFlagsMask;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct SmpteTime
        {
            public short Subframes;
            public short SubframeDivisor;
            public uint Counter;
            public uint Type;
            public uint Flags;
            public short Hours;
            public short Minutes;
            public short Seconds;
            public short Frames;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct AudioTimeStamp
        {
            public double SampleTime;
            public ulong HostTime;
            public double RateScalar;
            public ulong WordClockTime;
            public SmpteTime SmpteTime;
            public uint Flags;
            public uint Reserved;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct AudioBuffer
        {
            public uint NumberChannels;
            public uint DataByteSize;
            public void* Data;
        }

        // AudioBufferList is { UInt32 mNumberBuffers; AudioBuffer mBuffers[1]; }; on 64-bit the array starts at
        // offset 8 (the pointer in AudioBuffer aligns the struct to 8). Helpers below use that offset.
        public const int AudioBufferListBuffersOffset = 8;

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate int AURenderCallback(nint inRefCon, nint ioActionFlags, nint inTimeStamp, uint inBusNumber, uint inNumberFrames, nint ioData);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate int AudioConverterComplexInputDataProc(nint inAudioConverter, ref uint ioNumberDataPackets, nint ioData, nint outDataPacketDescription, nint inUserData);

        [DllImport(Lib)]
        public static extern nint AudioComponentFindNext(nint inComponent, ref AudioComponentDescription inDesc);

        [DllImport(Lib)]
        public static extern int AudioComponentInstanceNew(nint inComponent, out nint outInstance);

        [DllImport(Lib)]
        public static extern int AudioComponentInstanceDispose(nint inInstance);

        [DllImport(Lib)]
        public static extern int AudioUnitSetProperty(nint inUnit, uint inID, uint inScope, uint inElement, void* inData, uint inDataSize);

        [DllImport(Lib)]
        public static extern int AudioUnitInitialize(nint inUnit);

        [DllImport(Lib)]
        public static extern int AudioUnitUninitialize(nint inUnit);

        [DllImport(Lib)]
        public static extern int AudioUnitRender(nint inUnit, nint ioActionFlags, ref AudioTimeStamp inTimeStamp, uint inOutputBusNumber, uint inNumberFrames, nint ioData);

        [DllImport(Lib)]
        public static extern int AudioConverterNew(ref AudioToolbox.AudioStreamBasicDescription inSourceFormat, ref AudioToolbox.AudioStreamBasicDescription inDestinationFormat, out nint outAudioConverter);

        [DllImport(Lib)]
        public static extern int AudioConverterDispose(nint inAudioConverter);

        [DllImport(Lib)]
        public static extern int AudioConverterSetProperty(nint inAudioConverter, uint inID, uint inPropertyDataSize, void* inPropertyData);

        [DllImport(Lib)]
        public static extern int AudioConverterFillComplexBuffer(nint inAudioConverter, nint inInputDataProc, nint inInputDataProcUserData, ref uint ioOutputDataPacketSize, nint outOutputData, nint outPacketDescription);
    }
}
