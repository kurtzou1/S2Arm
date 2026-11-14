using Ryujinx.Audio.Integration;
using Ryujinx.Audio.Renderer.Dsp.Command;
using Ryujinx.Audio.Renderer.Utils;
using Ryujinx.Common;
using Ryujinx.Common.Logging;
using System;
using System.Threading;

namespace Ryujinx.Audio.Renderer.Dsp
{
    public class AudioProcessor : IDisposable
    {
        private const int MaxBufferedFrames = 5;
        private const int TargetBufferedFrames = 3;

        private enum MailboxMessage : uint
        {
            Start,
            Stop,
            RenderStart,
            RenderEnd,
        }

        private class RendererSession
        {
            public CommandList CommandList;
            public int RenderingLimit;
            public ulong AppletResourceId;
        }

        private Mailbox<MailboxMessage> _mailbox;
        private RendererSession[] _sessionCommandList;
        private Thread _workerThread;

        public IHardwareDevice[] OutputDevices { get; private set; }

        private long _lastTime;
        private long _playbackEnds;

        private ManualResetEvent _pauseEvent;

        // S2Arm（能耗，帧率能耗线 10-20）：S2A_AUDIO_INLINE=1 时 DSP 在调用方（AudioRendererManager 线程）上同步做，不起 AudioProcessor.Worker、不走信箱。
        // 原两线程是严格同步交接（管理线程 Signal 后即 Wait 到 RenderEnd，无并行），同步执行顺序不变；
        // 测试设备1 线程表：两条线程合计约 1.9 万运行段/秒（每段 2.5–7.6 µs），设计每 5 ms 一次交接
        // 10-22 起缺省开（杂音：两线程每周期一次交接，负载下交接等调度 27–34 ms，渲染器整批丢周期）；S2A_AUDIO_INLINE=0 退回上游两线程
        private static readonly bool S2AInline = Environment.GetEnvironmentVariable("S2A_AUDIO_INLINE") != "0";

        // S2Arm: diagnostics read (and reset) by the output backend's reporter: periods dropped by the catch-up skip below, and the
        // worst lateness of a period start (how long after its due time the loop got to it)
        public static long S2ASkippedPeriods;
        public static long S2AMaxLateNs;

        public AudioProcessor()
        {
        }

        private static uint GetHardwareChannelCount(IHardwareDeviceDriver deviceDriver)
        {
            // Get the real device driver (In case the compat layer is on top of it).
            deviceDriver = deviceDriver.GetRealDeviceDriver();

            if (deviceDriver.SupportsChannelCount(6))
            {
                return 6;
            }

            // NOTE: We default to stereo as this will get downmixed to mono by the compat layer if it's not compatible.
            return 2;
        }

        public void Start(IHardwareDeviceDriver deviceDriver)
        {
            OutputDevices = new IHardwareDevice[Constants.AudioRendererSessionCountMax];

            uint channelCount = GetHardwareChannelCount(deviceDriver);

            for (int i = 0; i < OutputDevices.Length; i++)
            {
                // TODO: Don't hardcode sample rate.
                OutputDevices[i] = new HardwareDeviceImpl(deviceDriver, channelCount, Constants.TargetSampleRate);
            }

            _mailbox = new Mailbox<MailboxMessage>();
            _sessionCommandList = new RendererSession[Constants.AudioRendererSessionCountMax];
            _lastTime = PerformanceCounter.ElapsedNanoseconds;
            _pauseEvent = deviceDriver.GetPauseEvent();

            if (S2AInline)
            {
                Console.Error.WriteLine("[S2A 声音] DSP 在管理线程同步执行（不起 AudioProcessor.Worker；S2A_AUDIO_INLINE=0 退回两线程）");
                return;
            }

            StartThread();

            _mailbox.SendMessage(MailboxMessage.Start);

            if (_mailbox.ReceiveResponse() != MailboxMessage.Start)
            {
                throw new InvalidOperationException("Audio Processor Start response was invalid!");
            }
        }

        public void Stop()
        {
            if (S2AInline)
            {
                foreach (IHardwareDevice d in OutputDevices)
                {
                    d.Dispose();
                }

                return;
            }

            _mailbox.SendMessage(MailboxMessage.Stop);

            if (_mailbox.ReceiveResponse() != MailboxMessage.Stop)
            {
                throw new InvalidOperationException("Audio Processor Stop response was invalid!");
            }

            foreach (IHardwareDevice device in OutputDevices)
            {
                device.Dispose();
            }
        }

        // S2Arm: one session record per slot, reused: Send only happens after the processor cleared the slot
        // (HasRemainingCommands), so a record is never shared between two frames (was allocated every 5 ms)
        private readonly RendererSession[] _s2aSessionRecords = new RendererSession[Constants.AudioRendererSessionCountMax];

        public void Send(int sessionId, CommandList commands, int renderingLimit, ulong appletResourceId)
        {
            RendererSession session = _s2aSessionRecords[sessionId] ??= new RendererSession();

            session.CommandList = commands;
            session.RenderingLimit = renderingLimit;
            session.AppletResourceId = appletResourceId;

            Volatile.Write(ref _sessionCommandList[sessionId], session);
        }

        public bool HasRemainingCommands(int sessionId)
        {
            return _sessionCommandList[sessionId] != null;
        }

        public void Signal()
        {
            if (S2AInline)
            {
                _pauseEvent?.WaitOne();
                Render();
                return;
            }

            _mailbox.SendMessage(MailboxMessage.RenderStart);
        }

        public void Wait()
        {
            if (!S2AInline && _mailbox.ReceiveResponse() != MailboxMessage.RenderEnd)
            {
                throw new InvalidOperationException("Audio Processor Wait response was invalid!");
            }

            long increment = Constants.AudioProcessorMaxUpdateTimeTarget;

            long timeNow = PerformanceCounter.ElapsedNanoseconds;

            if (timeNow > _playbackEnds)
            {
                // Playback has restarted.
                _playbackEnds = timeNow;
            }

            _playbackEnds += increment;

            // The number of frames we are behind where the timer says we should be.
            long framesBehind = (timeNow - _lastTime) / increment;

            // The number of frames yet to play on the backend.
            long bufferedFrames = (_playbackEnds - timeNow) / increment + framesBehind;

            // If we've entered a situation where a lot of buffers will be queued on the backend,
            // Skip some audio frames so that playback can catch up.
            if (bufferedFrames > MaxBufferedFrames)
            {
                // Skip a few frames so that we're not too far behind. (the target number of frames)
                _lastTime += increment * (bufferedFrames - TargetBufferedFrames);
                Interlocked.Add(ref S2ASkippedPeriods, bufferedFrames - TargetBufferedFrames);
            }

            long s2aLate = timeNow - (_lastTime + increment);

            if (s2aLate > Volatile.Read(ref S2AMaxLateNs))
            {
                Volatile.Write(ref S2AMaxLateNs, s2aLate);
            }

            // S2Arm (11-14 卡顿诊断探针): 本周期比节拍晚到的纳秒累计给宿主 TSV 的 @aud_wait_ms 列（hle_nvn.c 每帧取走清零）。
            // 游戏线程等的声音更新事件由本线程 Signal（AudioRendererManager.SendCommands）——这里晚到，等事件的游戏线程就同量晚醒
            if (s2aLate > 0)
            {
                S2AAudLate.Note(s2aLate);
            }

            // S2Arm: one sleep to the end of the period instead of polling WaitOne(1) (3.4 wakeups per 5 ms period → 1)
            if (timeNow < _lastTime + increment)
            {
                Ryujinx.Common.PreciseSleep.PreciseSleepHelper.SleepUntilTimePointSingleWake(
                    PerformanceCounter.ElapsedTicks + (_lastTime + increment - timeNow) * PerformanceCounter.TicksPerMillisecond / 1_000_000);
            }

            _lastTime += increment;
        }

        private void StartThread()
        {
            _workerThread = new Thread(Work)
            {
                Name = "AudioProcessor.Worker",
            };

            _workerThread.Start();
        }

        private void Work()
        {
            if (_mailbox.ReceiveMessage() != MailboxMessage.Start)
            {
                throw new InvalidOperationException("Audio Processor Start message was invalid!");
            }

            _mailbox.SendResponse(MailboxMessage.Start);
            _mailbox.SendResponse(MailboxMessage.RenderEnd);

            Logger.Info?.Print(LogClass.AudioRenderer, "Starting audio processor");

            // S2Arm: real-time like the manager thread (see Ryujinx.Common.S2ARealtime); only used with S2A_AUDIO_INLINE=0
            S2ARealtime.Promote("声音 DSP 线程", Constants.AudioProcessorMaxUpdateTimeTarget, Constants.AudioProcessorMaxUpdateTimeTarget / 2, Constants.AudioProcessorMaxUpdateTimeTarget);

            while (true)
            {
                Ryujinx.Common.S2AThreadAlloc.Tick("声音 DSP"); // S2Arm: per-thread allocation accounting

                _pauseEvent?.WaitOne();

                MailboxMessage message = _mailbox.ReceiveMessage();

                if (message == MailboxMessage.Stop)
                {
                    break;
                }

                if (message == MailboxMessage.RenderStart)
                {
                    Render();

                    _mailbox.SendResponse(MailboxMessage.RenderEnd);
                }
            }

            Logger.Info?.Print(LogClass.AudioRenderer, "Stopping audio processor");
            _mailbox.SendResponse(MailboxMessage.Stop);
        }

        private void Render()
        {
            long startTicks = PerformanceCounter.ElapsedNanoseconds;

            for (int i = 0; i < _sessionCommandList.Length; i++)
            {
                if (_sessionCommandList[i] != null)
                {
                    _sessionCommandList[i].CommandList.Process(OutputDevices[i]);
                    _sessionCommandList[i].CommandList.Dispose();
                    _sessionCommandList[i] = null;
                }
            }

            long endTicks = PerformanceCounter.ElapsedNanoseconds;

            long elapsedTime = endTicks - startTicks;

            if (Constants.AudioProcessorMaxUpdateTime < elapsedTime)
            {
                Logger.Debug?.Print(LogClass.AudioRenderer, $"DSP too slow (exceeded by {elapsedTime - Constants.AudioProcessorMaxUpdateTime}ns)");
            }
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
                _mailbox?.Dispose();
            }
        }
    }
}
