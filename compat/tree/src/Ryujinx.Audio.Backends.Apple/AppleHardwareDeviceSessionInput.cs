using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Memory;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using static Ryujinx.Audio.Backends.Apple.Native.AudioToolbox;   // 平台例外：Apple 后端平台实现（收音会话，#2151）

namespace Ryujinx.Audio.Backends.Apple   // 平台例外：Apple 后端平台实现（收音会话，#2151）
{
    // S2Arm（#2151）：Apple 收音会话，Mac 与 iOS 同一份。AudioQueue 输入按游戏要的格式出数（系统自己从设备采样率重采样到 48000 Hz），
    //   回调里把样本按交来的顺序抄进游戏缓冲，一块写满就算「已消费」（调用方 ExternalInputStream / AudioInputSystem 据此推写指针）。
    //   麦克风权限、iOS 音频会话类别、给玩家的横幅交给本机壳（s2a_mic_*：macos/front_mac.m、ios/app.m；runtime/src/game_volume.c 弱定义 = 视为已授权）：
    //     没授权（拒绝 / 还在问）或建队失败时按静音跑：交来的块立即算写满（内容是调用方交出前清的零），授权到了再起队列；
    //     拒绝由壳自己提示，建队 / 起队失败本会话请壳提示，玩家都看得到「麦克风不可用」，不是悄悄没声
    sealed class AppleHardwareDeviceSessionInput : IHardwareDeviceSession   // 平台例外：Apple 后端平台实现（收音会话，#2151）
    {
        private const int NumBuffers = 4;
        private const int BufferMilliseconds = 10;

        // s2a_mic_begin / s2a_mic_state 的取值
        private const int MicGranted = 0;
        private const int MicDenied = 1;

        // s2a_mic_notice 的原因
        private const int NoticeOpenFailed = 2;

        [DllImport("s2a_native")]
        private static extern int s2a_mic_begin();   // 开始用麦克风：iOS 切到可收音的会话类别；没问过权限就发起询问。回 0 已授权 / 1 拒绝 / 2 正在问

        [DllImport("s2a_native")]
        private static extern int s2a_mic_state();   // 同上取值，只读不发起

        [DllImport("s2a_native")]
        private static extern void s2a_mic_end();    // 不再用麦克风：iOS 切回原会话类别

        [DllImport("s2a_native")]
        private static extern void s2a_mic_notice(int reason);   // 请壳给玩家一条「麦克风不可用」横幅

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void AudioQueueInputCallback(nint userData, nint audioQueue, nint buffer, nint startTime, uint numPackets, nint packetDescs);

        private readonly Lock _lock = new();
        private readonly AppleHardwareDeviceDriver _driver;   // 平台例外：Apple 后端平台实现（收音会话，#2151）
        private readonly IVirtualMemoryManager _memory;
        private readonly SampleFormat _sampleFormat;
        private readonly uint _sampleRate;
        private readonly uint _channelCount;
        private readonly int _bytesPerFrame;
        private readonly Queue<AudioBuffer> _pending = new();
        private readonly HashSet<AudioBuffer> _consumed = new();
        private readonly AudioQueueInputCallback _callback;
        private GCHandle _handle;

        private ulong _filledBytes;     // _pending 队首已写入的字节数
        private ulong _capturedFrames;
        private nint _queue;
        private bool _started;
        private bool _failed;
        private float _volume = 1f;

        public AppleHardwareDeviceSessionInput(AppleHardwareDeviceDriver driver, IVirtualMemoryManager memory, SampleFormat sampleFormat, uint sampleRate, uint channelCount)   // 平台例外：Apple 后端平台实现（收音会话，#2151）
        {
            if (!IsSupported(sampleFormat, channelCount))
            {
                throw new NotSupportedException($"Apple 收音会话：{sampleFormat}、{channelCount} 声道（只收 PcmInt16 / PcmInt32 / PcmFloat、1 或 2 声道）");
            }

            _driver = driver;
            _memory = memory;
            _sampleFormat = sampleFormat;
            _sampleRate = sampleRate;
            _channelCount = channelCount;
            _bytesPerFrame = (sampleFormat == SampleFormat.PcmInt16 ? 2 : 4) * (int)channelCount;
            _callback = InputCallback;
            _handle = GCHandle.Alloc(this);
        }

        public static bool IsSupported(SampleFormat sampleFormat, uint channelCount)
        {
            return channelCount is 1 or 2 && sampleFormat is SampleFormat.PcmInt16 or SampleFormat.PcmInt32 or SampleFormat.PcmFloat;
        }

        public bool RegisterBuffer(AudioBuffer buffer)
        {
            return buffer.DataPointer != 0;
        }

        public void QueueBuffer(AudioBuffer buffer)
        {
            bool startQueue = false;

            lock (_lock)
            {
                // 还没起队列：权限刚给到就起；否则（拒绝 / 正在问 / 建队失败）这一块按静音算写满
                if (_queue == 0 && _started && !_failed && s2a_mic_state() == MicGranted)
                {
                    startQueue = true;
                }
                else if (_queue == 0)
                {
                    _consumed.Add(buffer);
                    _driver.GetUpdateRequiredEvent().Set();

                    return;
                }

                _pending.Enqueue(buffer);
            }

            if (startQueue)
            {
                StartQueue();
            }
        }

        public bool WasBufferFullyConsumed(AudioBuffer buffer)
        {
            lock (_lock)
            {
                return _consumed.Contains(buffer);
            }
        }

        public void UnregisterBuffer(AudioBuffer buffer)
        {
            lock (_lock)
            {
                if (_consumed.Remove(buffer))
                {
                    return;
                }

                // 没写满就撤回（调用方摘流）：从待写队列里去掉，队首换人时已写字节清零
                if (_pending.Count > 0 && _pending.Peek() == buffer)
                {
                    _filledBytes = 0;
                }

                int count = _pending.Count;

                for (int i = 0; i < count; i++)
                {
                    AudioBuffer b = _pending.Dequeue();

                    if (b != buffer)
                    {
                        _pending.Enqueue(b);
                    }
                }
            }
        }

        public void Start()
        {
            int state = s2a_mic_begin();

            lock (_lock)
            {
                _started = true;
            }

            Console.Error.WriteLine($"[声] 收音：开始（{_sampleFormat}、{_channelCount} 声道、{_sampleRate} Hz），麦克风权限 {(state == MicGranted ? "已授权" : state == MicDenied ? "被拒绝，按静音给游戏" : "正在询问，授权前按静音给游戏")}");

            if (state == MicGranted)
            {
                StartQueue();
            }
        }

        private void StartQueue()
        {
            AudioStreamBasicDescription format = AppleHardwareDeviceDriver.GetAudioFormat(_sampleFormat, _sampleRate, _channelCount);   // 平台例外：Apple 后端平台实现（收音会话，#2151）
            nint queue = nint.Zero;
            int rc = AudioQueueNewInput(ref format, Marshal.GetFunctionPointerForDelegate(_callback), GCHandle.ToIntPtr(_handle), nint.Zero, nint.Zero, 0, out queue);
            string step = "AudioQueueNewInput";
            uint bytes = (uint)(_sampleRate * BufferMilliseconds / 1000 * _bytesPerFrame);

            for (int i = 0; rc == 0 && i < NumBuffers; i++)
            {
                step = "AudioQueueAllocateBuffer";
                rc = AudioQueueAllocateBuffer(queue, bytes, out nint buffer);

                if (rc == 0)
                {
                    step = "AudioQueueEnqueueBuffer";
                    rc = AudioQueueEnqueueBuffer(queue, buffer, 0, nint.Zero);
                }
            }

            lock (_lock)
            {
                if (rc == 0 && _started)
                {
                    _queue = queue;
                }
            }

            if (rc == 0 && _queue == queue)
            {
                step = "AudioQueueStart";
                rc = AudioQueueStart(queue, nint.Zero);
            }

            if (rc == 0 && _queue == queue)
            {
                Console.Error.WriteLine("[声] 收音：麦克风队列已起");

                return;
            }

            lock (_lock)
            {
                if (_queue == queue)
                {
                    _queue = nint.Zero;
                }

                _failed = rc != 0;

                // 已交来的块按静音算写满，调用方照常推进
                while (_pending.TryDequeue(out AudioBuffer b))
                {
                    _consumed.Add(b);
                }

                _filledBytes = 0;
            }

            if (queue != nint.Zero)
            {
                AudioQueueDispose(queue, true);
            }

            if (rc != 0)
            {
                Console.Error.WriteLine($"[声] 【红】收音：{step} 失败 rc={rc}（没有可用的收音设备或被系统拒绝），按静音给游戏");
                s2a_mic_notice(NoticeOpenFailed);
            }
        }

        private static void InputCallback(nint userData, nint audioQueue, nint buffer, nint startTime, uint numPackets, nint packetDescs)
        {
            if (GCHandle.FromIntPtr(userData).Target is AppleHardwareDeviceSessionInput session)   // 平台例外：Apple 后端平台实现（收音会话，#2151）
            {
                session.OnInput(audioQueue, buffer);
            }
        }

        private unsafe void OnInput(nint audioQueue, nint buffer)
        {
            AudioQueueBuffer* aq = (AudioQueueBuffer*)buffer;
            ReadOnlySpan<byte> data = new((void*)aq->AudioData, (int)aq->AudioDataByteSize);
            bool filledAny = false;

            lock (_lock)
            {
                if (audioQueue != _queue)
                {
                    return;   // 队列已停（Stop 里正在拆），不再写也不再交回
                }

                // 按交来的顺序抄进游戏缓冲；没有待写的块（游戏不读、环满）时多出来的样本丢掉
                while (!data.IsEmpty && _pending.TryPeek(out AudioBuffer target))
                {
                    int n = (int)Math.Min((ulong)data.Length, target.DataSize - _filledBytes);
                    _memory.Write(target.DataPointer + _filledBytes, data[..n]);
                    data = data[n..];
                    _filledBytes += (ulong)n;

                    if (_filledBytes == target.DataSize)
                    {
                        _pending.Dequeue();
                        _consumed.Add(target);
                        _capturedFrames += target.DataSize / (ulong)_bytesPerFrame;
                        _filledBytes = 0;
                        filledAny = true;
                    }
                }

                AudioQueueEnqueueBuffer(audioQueue, buffer, 0, nint.Zero);
            }

            if (filledAny)
            {
                _driver.GetUpdateRequiredEvent().Set();
            }
        }

        public void Stop()
        {
            nint queue;
            bool started;

            lock (_lock)
            {
                queue = _queue;
                started = _started;
                _queue = nint.Zero;
                _started = false;
            }

            // 锁外拆队列：AudioQueueStop(立即) 要等回调线程退出，回调要拿同一把锁
            if (queue != nint.Zero)
            {
                AudioQueueStop(queue, true);
                AudioQueueDispose(queue, true);
            }

            if (started)
            {
                s2a_mic_end();
                Console.Error.WriteLine($"[声] 收音：停止（本会话共收 {_capturedFrames} 帧）");
            }
        }

        public void SetVolume(float volume)
        {
            _volume = volume;
        }

        public float GetVolume()
        {
            return _volume;
        }

        public ulong GetPlayedSampleCount()
        {
            lock (_lock)
            {
                return _capturedFrames;
            }
        }

        public void PrepareToClose() { }

        public void Dispose()
        {
            Stop();

            if (_handle.IsAllocated)
            {
                _handle.Free();
            }
        }
    }
}
