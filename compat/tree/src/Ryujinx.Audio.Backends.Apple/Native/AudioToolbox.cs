using System.Runtime.InteropServices;
// ReSharper disable InconsistentNaming

namespace Ryujinx.Audio.Backends.Apple.Native
{
    public static partial class AudioToolbox
    {
        [StructLayout(LayoutKind.Sequential)]
        internal struct AudioStreamBasicDescription
        {
            public double SampleRate;
            public uint FormatID;
            public uint FormatFlags;
            public uint BytesPerPacket;
            public uint FramesPerPacket;
            public uint BytesPerFrame;
            public uint ChannelsPerFrame;
            public uint BitsPerChannel;
            public uint Reserved;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct AudioChannelLayout
        {
            public uint AudioChannelLayoutTag;
            public uint AudioChannelBitmap;
            public uint NumberChannelDescriptions;
        }

        internal const uint kAudioFormatLinearPCM = 0x6C70636D;
        internal const uint kAudioQueueProperty_ChannelLayout = 0x6171636c;
        // S2Arm（#189）：正确值是 (121 << 16) | 6。旧值 0x650006 是 (101 << 16) | 6（Stereo 族带 6 声道）：
        //   AudioQueue 收下但当作布局未知，隐式 6→2 只复制 FL/FR、中置 / 环绕整段丢失（离线渲染逐声道实测）
        internal const uint kAudioChannelLayoutTag_MPEG_5_1_A = 0x790006;
        // S2Arm（#189）：队列关联设备的输出声道数（UInt32），试建 5.1 探测用；值 'aqdc'
        internal const uint kAudioQueueDeviceProperty_NumberChannels = 0x61716463;
        // S2Arm（11-14 设备缓冲）：AudioObject 系统对象（id 1）上的默认输出设备（'dOut'）。AudioQueue 不选设备时
        //   缺省绑的就是它；本机 macOS 26 实测队列侧 kAudioQueueProperty_CurrentDevice（'aqcd'）读不出
        //   （-66683 未知属性，同队列 'aqdc' 正常），设备号改从系统对象取
        internal const uint kAudioObjectSystemObject = 1;
        internal const uint kAudioHardwarePropertyDefaultOutputDevice = 0x644F7574;   // 'dOut'
        // S2Arm（11-14 设备缓冲）：CoreAudio HAL 设备属性——设备 IO 缓冲帧数（UInt32，'bsiz'）、作用域（'glob'）、元素（主元素 = 0）。
        //   仅 macOS 有 HAL（iOS 走 AVAudioSession 的 setPreferredIOBufferDuration，见 AppleHardwareDeviceDriver.S2AConfigureSession）
        internal const uint kAudioDevicePropertyBufferFrameSize = 0x6273697A;   // 'bsiz'
        internal const uint kAudioObjectPropertyScopeGlobal = 0x676C6F62;   // 'glob'
        internal const uint kAudioObjectPropertyElementMain = 0;
        // S2Arm（11-14 设备缓冲）：AudioObjectPropertyAddress = { Selector, Scope, Element }（按头文件顺序，UInt32 × 3）
        [StructLayout(LayoutKind.Sequential)]
        internal struct AudioObjectPropertyAddress
        {
            public uint Selector;
            public uint Scope;
            public uint Element;
        }

        // S2Arm（11-14 设备缓冲）：CoreAudio HAL 属性读写（AudioObjectSetPropertyData / AudioObjectGetPropertyData）。
        //   qualifier 空（设备级属性不用 qualifier）；dataSize 进出都是字节数
        [LibraryImport("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")]   // 平台例外：Apple 后端平台实现的 CoreAudio P/Invoke 声明（设备缓冲）
        internal static partial int AudioObjectSetPropertyData(
            uint objectID,
            ref AudioObjectPropertyAddress address,
            uint qualifierDataSize,
            nint qualifierData,
            uint dataSize,
            ref uint data);

        [LibraryImport("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")]   // 平台例外：Apple 后端平台实现的 CoreAudio P/Invoke 声明（设备缓冲）
        internal static partial int AudioObjectGetPropertyData(
            uint objectID,
            ref AudioObjectPropertyAddress address,
            uint qualifierDataSize,
            nint qualifierData,
            ref uint dataSize,
            ref uint data);

        internal const uint kAudioFormatFlagIsFloat = (1 << 0);
        internal const uint kAudioFormatFlagIsSignedInteger = (1 << 2);
        internal const uint kAudioFormatFlagIsPacked = (1 << 3);
        internal const uint kAudioFormatFlagIsBigEndian = (1 << 1);
        internal const uint kAudioFormatFlagIsAlignedHigh = (1 << 4);
        internal const uint kAudioFormatFlagIsNonInterleaved = (1 << 5);

        [LibraryImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")]
        internal static partial int AudioQueueNewOutput(
            ref AudioStreamBasicDescription format,
            nint callback,
            nint userData,
            nint callbackRunLoop,
            nint callbackRunLoopMode,
            uint flags,
            out nint audioQueue);

        [LibraryImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")]
        internal static partial int AudioQueueSetProperty(
            nint audioQueue,
            uint propertyID,
            ref AudioChannelLayout layout,
            uint layoutSize);

        // S2Arm（#189）：读 UInt32 队列属性（kAudioQueueDeviceProperty_NumberChannels 读队列关联设备的输出声道数）
        [LibraryImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")]   // 平台例外：Apple 后端平台实现的 AudioToolbox P/Invoke 声明
        internal static partial int AudioQueueGetProperty(
            nint audioQueue,
            uint propertyID,
            out uint value,
            ref uint dataSize);

        [LibraryImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")]
        internal static partial int AudioQueueDispose(nint audioQueue, [MarshalAs(UnmanagedType.I1)] bool immediate);

        [LibraryImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")]
        internal static partial int AudioQueueAllocateBuffer(
            nint audioQueue,
            uint bufferByteSize,
            out nint buffer);

        [LibraryImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")]
        internal static partial int AudioQueueStart(nint audioQueue, nint startTime);

        [LibraryImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")]
        internal static partial int AudioQueuePause(nint audioQueue);

        [LibraryImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")]
        internal static partial int AudioQueueStop(nint audioQueue, [MarshalAs(UnmanagedType.I1)] bool immediate);

        [LibraryImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")]
        internal static partial int AudioQueueSetParameter(
            nint audioQueue,
            uint parameterID,
            float value);

        [LibraryImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")]
        internal static partial int AudioQueueEnqueueBuffer(
            nint audioQueue,
            nint buffer,
            uint numPacketDescs,
            nint packetDescs);

        [StructLayout(LayoutKind.Sequential)]
        internal struct AudioQueueBuffer
        {
            public uint AudioDataBytesCapacity;
            public nint AudioData;
            public uint AudioDataByteSize;
            public nint UserData;
            public uint PacketDescriptionCapacity;
            public nint PacketDescriptions;
            public uint PacketDescriptionCount;
        }

        internal const uint kAudioQueueParam_Volume = 1;
    }
}
