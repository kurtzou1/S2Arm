using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Backends.Apple.Native   // 平台例外：Apple 后端平台实现的 Native 命名空间（#189 后续，虚拟环绕）
{
    // S2Arm（#189 后续，5.1 虚拟环绕）：AUSpatialMixer（'3dem'）的 AudioUnit C API 切片——AppleOutputProcessor 的
    //   虚拟环绕档用。AudioQueue / AudioConverter 绑定在 AudioToolbox.cs / AudioConverterInterop.cs，这里只有
    //   空间化混音器：找器件（AudioComponentFindNext）、建实例、设属性（StreamFormat / 布局 / 空间化三属性）、
    //   喂输入（输入元件 0 的 RenderCallback）、手动拉取输出（AudioUnitRender）。
    //   布局 / 采样格式常量复用 AudioToolbox.cs（kAudioChannelLayoutTag_MPEG_5_1_A 等）与 AudioConverterInterop.cs
    //   （kAudioChannelLayoutTag_Stereo、AudioBuffer、AudioBufferListBuffersOffset）。
    internal static unsafe class AudioUnitInterop
    {
        private const string Lib = "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox";

        // AudioComponentDescription（AudioComponent.h，四字符代号）
        public const uint kAudioUnitType_Mixer = 0x61756D78;             // 'aumx'
        public const uint kAudioUnitSubType_SpatialMixer = 0x3364656D;    // '3dem'
        public const uint kAudioUnitManufacturer_Apple = 0x6170706C;     // 'appl'

        // S2Arm（#2157 只留一种传输，AudioUnit 拉取取代 AudioQueue）：输出器件——macOS 用 DefaultOutput（AUHAL 特化、
        //   跟随用户默认输出设备，与 AudioQueue 的缺省绑定语义一致），iOS/tvOS 直接走 RemoteIO
        public const uint kAudioUnitType_Output = 0x61756F75;            // 'auou'
        public const uint kAudioUnitSubType_DefaultOutput = 0x64656620; // 'def '
        public const uint kAudioUnitSubType_RemoteIO = 0x72696F63;       // 'rioc'

        [StructLayout(LayoutKind.Sequential)]
        public struct AudioComponentDescription
        {
            public uint ComponentType;
            public uint ComponentSubType;
            public uint ComponentManufacturer;
            public uint ComponentFlags;
            public uint ComponentFlagsMask;
        }

        // AudioUnitPropertyID（AudioUnitProperties.h；AUSM 空间化属性 3000 / 3005 / 3100）
        public const uint kAudioUnitProperty_StreamFormat = 8;
        public const uint kAudioUnitProperty_ElementCount = 11;
        public const uint kAudioUnitProperty_MaximumFramesPerSlice = 14;
        public const uint kAudioUnitProperty_AudioChannelLayout = 19;
        public const uint kAudioUnitProperty_SetRenderCallback = 23;
        public const uint kAudioUnitProperty_SpatializationAlgorithm = 3000;
        public const uint kAudioUnitProperty_SpatialMixerSourceMode = 3005;
        public const uint kAudioUnitProperty_SpatialMixerOutputType = 3100;

        // kAudioUnitScope
        public const uint kAudioUnitScope_Global = 0;
        public const uint kAudioUnitScope_Input = 1;
        public const uint kAudioUnitScope_Output = 2;

        // S2Arm（#2157 只留一种传输）：输出器件属性（AudioUnitProperties.h:2522-2529；RemoteIO 输出总线缺省即开——
        //   输出单元缺省 output-only，不用 EnableIO；CurrentDevice / StartTimestampsAtZero 留作显式选设备用）
        public const uint kAudioOutputUnitProperty_CurrentDevice = 2000;
        public const uint kAudioOutputUnitProperty_EnableIO = 2003;
        public const uint kAudioOutputUnitProperty_StartTimestampsAtZero = 2007;

        // AUSpatializationAlgorithm：UseOutputType——按 SpatialMixerOutputType 定渲染路径
        public const uint kSpatializationAlgorithm_UseOutputType = 7;
        // AUSpatialMixerSourceMode：AmbienceBed——整张 5.1 声床按环境声渲染（点源模式不做逐声道摆放）
        public const uint kSpatialMixerSourceMode_AmbienceBed = 3;
        // AUSpatialMixerOutputType：显式设备类型。不用 .auto（0）：5.1 路径上 .auto 全部退化为 ExternalSpeakers
        //   普通平移（内置 / USB / DisplayPort 三路由实测一致，见 docs/坑记录.md），显式类型才虚拟化
        public const uint kSpatialMixerOutputType_Headphones = 1;
        public const uint kSpatialMixerOutputType_BuiltInSpeakers = 2;

        // AudioTimeStamp：手动拉取只填 mSampleTime + SampleTimeValid 位，且必须单调递增
        //   （否则 AUSM 重复上一片或输出零，#189 已记录的坑）
        public const uint kAudioTimeStampSampleTimeValid = 1 << 0;

        [StructLayout(LayoutKind.Sequential)]
        public struct AudioTimeStamp
        {
            public double SampleTime;
            public ulong HostTime;
            public double RateScalar;
            public ulong WordClockTime;
            public uint SMPTETimeFlags;
            public uint Flags;
            public uint Reserved;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct AURenderCallbackStruct
        {
            public nint InputProc;
            public nint InputProcRefCon;
        }

        // AURenderCallback：喂输入（inRefCon / ioActionFlags / inTimeStamp / 总线号 / 帧数 / AudioBufferList*）
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate int AURenderCallback(nint inRefCon, nint ioActionFlags, nint inTimeStamp, uint inBusNumber, uint inNumberFrames, nint ioData);

        [DllImport(Lib)]
        public static extern nint AudioComponentFindNext(nint inComponent, ref AudioComponentDescription inDesc);

        [DllImport(Lib)]
        public static extern int AudioComponentInstanceNew(nint inComponent, out nint outInstance);

        [DllImport(Lib)]
        public static extern int AudioComponentInstanceDispose(nint inInstance);

        [DllImport(Lib)]
        public static extern int AudioUnitInitialize(nint inUnit);

        [DllImport(Lib)]
        public static extern int AudioUnitUninitialize(nint inUnit);

        [DllImport(Lib)]
        public static extern int AudioUnitSetProperty(nint inUnit, uint inID, uint inScope, uint inElement, void* inData, uint inDataSize);

        [DllImport(Lib)]
        public static extern int AudioUnitRender(nint inUnit, ref uint ioActionFlags, ref AudioTimeStamp inTimeStamp, uint inOutputBusNumber, uint inNumberFrames, nint ioData);

        // S2Arm（#2157 只留一种传输）：开播 / 停播输出器件（AudioOutputUnit.h:24/27；
        //   停播后回调停、环内样本保留，Start 自然续播——播放信用地板直接是已渲染量，不需要重学交还相位）
        [DllImport(Lib)]
        public static extern int AudioOutputUnitStart(nint inUnit);

        [DllImport(Lib)]
        public static extern int AudioOutputUnitStop(nint inUnit);
    }
}
