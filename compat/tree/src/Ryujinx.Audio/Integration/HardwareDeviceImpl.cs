using Ryujinx.Audio.Common;
using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Integration
{
    public class HardwareDeviceImpl : IHardwareDevice
    {
        private readonly IHardwareDeviceSession _session;
        private readonly uint _channelCount;
        private readonly uint _sampleRate;
        private uint _currentBufferTag;

        // S2Arm (11-13 断音): renders appended so far; the processor paces by the depth of the devices this counter shows being fed
        public long S2AAppends;

        /// <summary>S2Arm: frames given to the output and not handed back by it yet; -1 when the backend cannot tell (or is not playing).</summary>
        public long S2ABufferedFrames => _session is IS2AOutputDepth d ? d.S2ABufferedFrames : -1;

        // S2Arm (#2157 评审 #15): IO 周期配速水位(旧会话不实现 IS2AIOAwareDepth → -1 → 处理器用自己的 30 ms 地板,行为不变)
        public long S2AIODepthFrames => _session is IS2AIOAwareDepth d ? d.S2AIODepthFrames : -1;

        private readonly byte[] _buffer;

        // S2Arm: one AudioBuffer per tag, reused every 4 rounds (was a new one per round); all fields are re-set before queueing
        private readonly AudioBuffer[] _audioBuffers = [new(), new(), new(), new()];

        public HardwareDeviceImpl(IHardwareDeviceDriver deviceDriver, uint channelCount, uint sampleRate)
        {
            _session = deviceDriver.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, sampleRate, channelCount);
            _channelCount = channelCount;
            _sampleRate = sampleRate;
            _currentBufferTag = 0;

            _buffer = new byte[Constants.TargetSampleCount * channelCount * sizeof(ushort)];

            _session.Start();
        }

        public void AppendBuffer(ReadOnlySpan<short> data, uint channelCount)
        {
            data.CopyTo(MemoryMarshal.Cast<byte, short>(new Span<byte>(_buffer)));

            AudioBuffer audioBuffer = _audioBuffers[_currentBufferTag];

            audioBuffer.BufferTag = 0;
            audioBuffer.DataPointer = _currentBufferTag++;
            audioBuffer.Data = _buffer;
            audioBuffer.DataSize = (ulong)_buffer.Length;
            audioBuffer.PlayedTimestamp = 0;

            _session.QueueBuffer(audioBuffer);
            S2AAppends++;

            _currentBufferTag %= 4;
        }

        public void SetVolume(float volume)
        {
            _session.SetVolume(volume);
        }

        public float GetVolume()
        {
            return _session.GetVolume();
        }

        public uint GetChannelCount()
        {
            return _channelCount;
        }

        public uint GetSampleRate()
        {
            return _sampleRate;
        }

        public void Dispose()
        {
            GC.SuppressFinalize(this);
            Dispose(true);
        }

        protected virtual void Dispose(bool disposing)
        {
            if (disposing)
            {
                _session.Dispose();
            }
        }
    }

    /// <summary>
    /// S2Arm (11-13 断音): an output session that can tell how much it holds: frames queued or submitted to the device and not
    /// handed back yet; -1 while the device is not playing (pre-roll, stopped) or the backend cannot tell.
    /// </summary>
    public interface IS2AOutputDepth
    {
        long S2ABufferedFrames { get; }
    }

    /// <summary>
    /// S2Arm (#2157 评审 #15,玩家 #1308 诊断 D-BEKN): an output session whose pacing floor follows its device's actual
    /// IO period (the frames the device pulls per callback). The render loop raises its own depth floor to this value;
    /// sessions that cannot tell (older implementations, or no device property to read) simply don't implement it.
    /// </summary>
    public interface IS2AIOAwareDepth
    {
        /// <summary>Pacing floor in frames for this output; 0 = nothing to add (the processor keeps its own floor).</summary>
        long S2AIODepthFrames { get; }
    }

    /// <summary>
    /// S2Arm (11-13 失焦误报): the host froze the guest (rendering paused through the driver's pause event). Set by the host's
    /// lifecycle; diagnostics skip windows that were frozen at any point instead of reporting a silent output.
    /// </summary>
    public static class S2AGuestFreeze
    {
        public static volatile int Frozen;
        public static long Seq;   // freezes so far (Interlocked)

        /// <summary>S2Arm (11-25 iOS 回前台 520 ms): signalled when a freeze is lifted, so the Apple backend's watchdog restarts the output at once instead of on its next 250 ms tick.</summary>
        public static readonly System.Threading.AutoResetEvent Thawed = new(false);

        public static void Set(bool frozen)
        {
            if (frozen)
            {
                System.Threading.Interlocked.Increment(ref Seq);
            }

            bool was = Frozen != 0;
            Frozen = frozen ? 1 : 0;

            if (was && !frozen)
            {
                Thawed.Set();
            }
        }
    }
}
