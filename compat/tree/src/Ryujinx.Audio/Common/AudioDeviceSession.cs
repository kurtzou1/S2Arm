using Ryujinx.Audio.Integration;
using Ryujinx.Common;
using System;
using System.Diagnostics;

namespace Ryujinx.Audio.Common
{
    /// <summary>
    /// An audio device session.
    /// </summary>
    class AudioDeviceSession : IDisposable
    {
        /// <summary>
        /// The volume of the <see cref="AudioDeviceSession"/>.
        /// </summary>
        private float _volume;

        /// <summary>
        /// The state of the <see cref="AudioDeviceSession"/>.
        /// </summary>
        private AudioDeviceState _state;

        /// <summary>
        /// Array of all buffers currently used or released.
        /// </summary>
        private readonly AudioBuffer[] _buffers;

        /// <summary>
        /// S2Arm: one <see cref="AudioBuffer"/> per ring slot, reused by every append landing on that slot (was a new one per append).
        /// A slot is only reused after its previous buffer left the ring (total count &lt; max).
        /// </summary>
        private readonly AudioBuffer[] _slots;

        /// <summary>
        /// The server index inside <see cref="_buffers"/> (appended but not queued to device driver).
        /// </summary>
        private uint _serverBufferIndex;

        /// <summary>
        /// The hardware index inside <see cref="_buffers"/> (queued to device driver).
        /// </summary>
        private uint _hardwareBufferIndex;

        /// <summary>
        /// The released index inside <see cref="_buffers"/> (released by the device driver).
        /// </summary>
        private uint _releasedBufferIndex;

        /// <summary>
        /// The count of buffer appended (server side).
        /// </summary>
        private uint _bufferAppendedCount;

        /// <summary>
        /// The count of buffer registered (driver side).
        /// </summary>
        private uint _bufferRegisteredCount;

        /// <summary>
        /// The count of buffer released (released by the driver side).
        /// </summary>
        private uint _bufferReleasedCount;

        /// <summary>
        /// The released buffer event.
        /// </summary>
        private readonly IWritableEvent _bufferEvent;

        /// <summary>
        /// The session on the device driver.
        /// </summary>
        private readonly IHardwareDeviceSession _hardwareDeviceSession;

        /// <summary>
        /// Max number of buffers that can be registered to the device driver at a time.
        /// </summary>
        private readonly uint _bufferRegisteredLimit;

        /// <summary>
        /// Create a new <see cref="AudioDeviceSession"/>.
        /// </summary>
        /// <param name="deviceSession">The device driver session associated</param>
        /// <param name="bufferEvent">The release buffer event</param>
        /// <param name="bufferRegisteredLimit">The max number of buffers that can be registered to the device driver at a time</param>
        public AudioDeviceSession(IHardwareDeviceSession deviceSession, IWritableEvent bufferEvent, uint bufferRegisteredLimit = 4)
        {
            _bufferEvent = bufferEvent;
            _hardwareDeviceSession = deviceSession;
            _bufferRegisteredLimit = bufferRegisteredLimit;

            _buffers = new AudioBuffer[Constants.AudioDeviceBufferCountMax];
            _slots = new AudioBuffer[Constants.AudioDeviceBufferCountMax];

            for (int i = 0; i < _slots.Length; i++)
            {
                _slots[i] = new AudioBuffer();
            }

            _serverBufferIndex = 0;
            _hardwareBufferIndex = 0;
            _releasedBufferIndex = 0;

            _bufferAppendedCount = 0;
            _bufferRegisteredCount = 0;
            _bufferReleasedCount = 0;
            _volume = deviceSession.GetVolume();
            _state = AudioDeviceState.Stopped;
        }

        /// <summary>
        /// Get the released buffer event.
        /// </summary>
        /// <returns>The released buffer event</returns>
        public IWritableEvent GetBufferEvent()
        {
            return _bufferEvent;
        }

        /// <summary>
        /// Get the state of the session.
        /// </summary>
        /// <returns>The state of the session</returns>
        public AudioDeviceState GetState()
        {
            Debug.Assert(_state is AudioDeviceState.Started or AudioDeviceState.Stopped);

            return _state;
        }

        /// <summary>
        /// Get the total buffer count (server + driver + released).
        /// </summary>
        /// <returns>Return the total buffer count</returns>
        private uint GetTotalBufferCount()
        {
            uint bufferCount = _bufferAppendedCount + _bufferRegisteredCount + _bufferReleasedCount;

            Debug.Assert(bufferCount <= Constants.AudioDeviceBufferCountMax);

            return bufferCount;
        }

        /// <summary>
        /// Register a new <see cref="AudioBuffer"/> on the server side.
        /// </summary>
        /// <param name="buffer">The <see cref="AudioBuffer"/> to register</param>
        /// <returns>True if the operation succeeded</returns>
        private bool RegisterBuffer(AudioBuffer buffer)
        {
            if (GetTotalBufferCount() == Constants.AudioDeviceBufferCountMax)
            {
                return false;
            }

            _buffers[_serverBufferIndex] = buffer;
            _serverBufferIndex = (_serverBufferIndex + 1) % Constants.AudioDeviceBufferCountMax;
            _bufferAppendedCount++;

            return true;
        }

        /// <summary>
        /// Flush server buffers to hardware.
        /// </summary>
        private void FlushToHardware()
        {
            uint bufferToFlushCount = Math.Min(Math.Min(_bufferAppendedCount, 4), _bufferRegisteredLimit - _bufferRegisteredCount);

            // S2Arm: the buffers to flush are the ring slots [first, first + count) — queue them straight from the ring
            // after the bookkeeping, same order as before (was a temporary AudioBuffer[] per flush)
            uint firstBufferIndex = _hardwareBufferIndex;

            _bufferAppendedCount -= bufferToFlushCount;
            _bufferRegisteredCount += bufferToFlushCount;
            _hardwareBufferIndex = (firstBufferIndex + bufferToFlushCount) % Constants.AudioDeviceBufferCountMax;

            for (uint i = 0; i < bufferToFlushCount; i++)
            {
                _hardwareDeviceSession.QueueBuffer(_buffers[(firstBufferIndex + i) % Constants.AudioDeviceBufferCountMax]);
            }
        }

        /// <summary>
        /// Get the current index of the <see cref="AudioBuffer"/> playing on the driver side.
        /// </summary>
        /// <param name="playingIndex">The output index of the <see cref="AudioBuffer"/> playing on the driver side</param>
        /// <returns>True if any buffer is playing</returns>
        private bool TryGetPlayingBufferIndex(out uint playingIndex)
        {
            if (_bufferRegisteredCount > 0)
            {
                playingIndex = (_hardwareBufferIndex - _bufferRegisteredCount) % Constants.AudioDeviceBufferCountMax;

                return true;
            }

            playingIndex = 0;

            return false;
        }

        /// <summary>
        /// Try to pop the <see cref="AudioBuffer"/> playing on the driver side.
        /// </summary>
        /// <param name="buffer">The output <see cref="AudioBuffer"/> playing on the driver side</param>
        /// <returns>True if any buffer is playing</returns>
        private bool TryPopPlayingBuffer(out AudioBuffer buffer)
        {
            if (_bufferRegisteredCount > 0)
            {
                uint bufferIndex = (_hardwareBufferIndex - _bufferRegisteredCount) % Constants.AudioDeviceBufferCountMax;

                buffer = _buffers[bufferIndex];

                _buffers[bufferIndex] = null;

                _bufferRegisteredCount--;

                return true;
            }

            buffer = null;

            return false;
        }

        /// <summary>
        /// Try to pop a <see cref="AudioBuffer"/> released by the driver side.
        /// </summary>
        /// <param name="buffer">The output <see cref="AudioBuffer"/> released by the driver side</param>
        /// <returns>True if any buffer has been released</returns>
        public bool TryPopReleasedBuffer(out AudioBuffer buffer)
        {
            if (_bufferReleasedCount > 0)
            {
                uint bufferIndex = (_releasedBufferIndex - _bufferReleasedCount) % Constants.AudioDeviceBufferCountMax;

                buffer = _buffers[bufferIndex];

                _buffers[bufferIndex] = null;

                _bufferReleasedCount--;

                return true;
            }

            buffer = null;

            return false;
        }

        /// <summary>
        /// Release a <see cref="AudioBuffer"/>.
        /// </summary>
        /// <param name="buffer">The <see cref="AudioBuffer"/> to release</param>
        private void ReleaseBuffer(AudioBuffer buffer)
        {
            buffer.PlayedTimestamp = (ulong)PerformanceCounter.ElapsedNanoseconds;

            _bufferRegisteredCount--;
            _bufferReleasedCount++;

            _releasedBufferIndex = (_releasedBufferIndex + 1) % Constants.AudioDeviceBufferCountMax;
        }

        /// <summary>
        /// Update the released buffers.
        /// </summary>
        /// <param name="updateForStop">True if the session is currently stopping</param>
        private void UpdateReleaseBuffers(bool updateForStop = false)
        {
            bool wasAnyBuffersReleased = false;

            while (TryGetPlayingBufferIndex(out uint playingIndex))
            {
                if (!updateForStop && !_hardwareDeviceSession.WasBufferFullyConsumed(_buffers[playingIndex]))
                {
                    break;
                }

                if (updateForStop)
                {
                    _hardwareDeviceSession.UnregisterBuffer(_buffers[playingIndex]);
                }

                ReleaseBuffer(_buffers[playingIndex]);

                wasAnyBuffersReleased = true;
            }

            if (wasAnyBuffersReleased)
            {
                _bufferEvent.Signal();
            }
        }

        /// <summary>
        /// Append a new audio buffer.
        /// </summary>
        /// <param name="bufferTag">The unique tag of this buffer</param>
        /// <param name="dataPointer">Pointer to the user samples</param>
        /// <param name="dataSize">Size of the user samples region</param>
        /// <returns>True if the buffer was appended</returns>
        public bool AppendBuffer(ulong bufferTag, ulong dataPointer, ulong dataSize)
        {
            // S2Arm: the buffer object is the ring slot's own, reset here to a fresh buffer's state (was a new AudioBuffer from the
            // caller per append). Safe to reuse: every way out of the ring (release after playback, or the unregister done by
            // Stop / FlushBuffers / Dispose) leaves the driver with no reference to it (AudioSampleQueue copies unread samples in).
            // Ring full: the slot at the server index still holds a buffer in flight — refuse before touching it
            // (same result as before: driver registration undone, false)
            if (GetTotalBufferCount() == Constants.AudioDeviceBufferCountMax)
            {
                return false;
            }

            AudioBuffer buffer = _slots[_serverBufferIndex];

            buffer.BufferTag = bufferTag;
            buffer.DataPointer = dataPointer;
            buffer.DataSize = dataSize;
            buffer.PlayedTimestamp = 0;
            buffer.Data = null;
            buffer.SampleReader = null;

            if (_hardwareDeviceSession.RegisterBuffer(buffer))
            {
                if (RegisterBuffer(buffer))
                {
                    FlushToHardware();

                    return true;
                }

                _hardwareDeviceSession.UnregisterBuffer(buffer);
            }

            return false;
        }

        public static bool AppendUacBuffer(AudioBuffer buffer, uint handle)
        {
            // NOTE: On hardware, there is another RegisterBuffer method taking a handle.
            // This variant of the call always return false (stubbed?) as a result this logic will never succeed.

            return false;
        }

        /// <summary>
        /// Start the audio session.
        /// </summary>
        /// <returns>A <see cref="ResultCode"/> reporting an error or a success</returns>
        public ResultCode Start()
        {
            if (_state == AudioDeviceState.Started)
            {
                return ResultCode.OperationFailed;
            }

            _hardwareDeviceSession.Start();

            _state = AudioDeviceState.Started;

            FlushToHardware();

            _hardwareDeviceSession.SetVolume(_volume);

            return ResultCode.Success;
        }

        /// <summary>
        /// Stop the audio session.
        /// </summary>
        /// <returns>A <see cref="ResultCode"/> reporting an error or a success</returns>
        public ResultCode Stop()
        {
            if (_state == AudioDeviceState.Started)
            {
                _hardwareDeviceSession.Stop();

                UpdateReleaseBuffers(true);

                _state = AudioDeviceState.Stopped;
            }

            return ResultCode.Success;
        }

        /// <summary>
        /// Get the volume of the session.
        /// </summary>
        /// <returns>The volume of the session</returns>
        public float GetVolume()
        {
            return _hardwareDeviceSession.GetVolume();
        }

        /// <summary>
        /// Set the volume of the session.
        /// </summary>
        /// <param name="volume">The new volume to set</param>
        public void SetVolume(float volume)
        {
            _volume = volume;

            if (_state == AudioDeviceState.Started)
            {
                _hardwareDeviceSession.SetVolume(volume);
            }
        }

        /// <summary>
        /// Get the count of buffer currently in use (server + driver side).
        /// </summary>
        /// <returns>The count of buffer currently in use</returns>
        public uint GetBufferCount()
        {
            return _bufferAppendedCount + _bufferRegisteredCount;
        }

        /// <summary>
        /// Check if a buffer is present.
        /// </summary>
        /// <param name="bufferTag">The unique tag of the buffer</param>
        /// <returns>Return true if a buffer is present</returns>
        public bool ContainsBuffer(ulong bufferTag)
        {
            uint bufferIndex = (_releasedBufferIndex - _bufferReleasedCount) % Constants.AudioDeviceBufferCountMax;

            uint totalBufferCount = GetTotalBufferCount();

            for (int i = 0; i < totalBufferCount; i++)
            {
                if (_buffers[bufferIndex].BufferTag == bufferTag)
                {
                    return true;
                }

                bufferIndex = (bufferIndex + 1) % Constants.AudioDeviceBufferCountMax;
            }

            return false;
        }

        // S2Arm 即时存档：缓冲队列与已播采样数。存：还没交还的（正在放 + 排着，按放的顺序）与已交还、游戏还没取走的（按交还顺序），各存 tag / 地址 / 大小；
        //   恢复（新会话、重放已 Start）：已交还的直接放回「已交还」并发事件，没交还的按顺序重新追加给硬件（样本在已恢复的游戏内存里），
        //   已播采样数按偏移接上（游戏拿它做音画同步，不能从 0 重来）。原先这个队列不存：恢复后游戏一直等它以为还排着的缓冲交还，音频线程卡住、跟音频走的动画定格
        private ulong _s2aPlayedOffset;
        public ulong S2APlayedSampleCount => GetPlayedSampleCount();
        public (ulong Tag, ulong Ptr, ulong Size)[] S2APending()
        {
            uint n = _bufferRegisteredCount + _bufferAppendedCount;
            var r = new (ulong, ulong, ulong)[n];
            uint first = (_hardwareBufferIndex - _bufferRegisteredCount) % Constants.AudioDeviceBufferCountMax;
            for (uint i = 0; i < n; i++) { AudioBuffer b = _buffers[(first + i) % Constants.AudioDeviceBufferCountMax]; r[i] = (b.BufferTag, b.DataPointer, b.DataSize); }
            return r;
        }
        public (ulong Tag, ulong Ptr, ulong Size)[] S2AReleased()
        {
            var r = new (ulong, ulong, ulong)[_bufferReleasedCount];
            uint first = (_releasedBufferIndex - _bufferReleasedCount) % Constants.AudioDeviceBufferCountMax;
            for (uint i = 0; i < _bufferReleasedCount; i++) { AudioBuffer b = _buffers[(first + i) % Constants.AudioDeviceBufferCountMax]; r[i] = (b.BufferTag, b.DataPointer, b.DataSize); }
            return r;
        }
        /// <returns>重新追加成功的在途缓冲个数（放不进的不算）</returns>
        public int S2ARestore((ulong Tag, ulong Ptr, ulong Size)[] released, (ulong Tag, ulong Ptr, ulong Size)[] pending, ulong played)
        {
            if (GetTotalBufferCount() != 0 || released.Length + pending.Length > Constants.AudioDeviceBufferCountMax) return -1;   // 只给刚重建的空会话用
            // 已交还的：占环最前面几格，计数直接记成已交还（不经硬件）；_hardwareBufferIndex / _serverBufferIndex 跟着前移，之后追加的接在后面
            for (int i = 0; i < released.Length; i++)
            {
                AudioBuffer b = _slots[_serverBufferIndex];
                b.BufferTag = released[i].Tag; b.DataPointer = released[i].Ptr; b.DataSize = released[i].Size; b.PlayedTimestamp = (ulong)PerformanceCounter.ElapsedNanoseconds; b.Data = null; b.SampleReader = null;
                _buffers[_serverBufferIndex] = b;
                _serverBufferIndex = (_serverBufferIndex + 1) % Constants.AudioDeviceBufferCountMax;
            }
            _hardwareBufferIndex = _serverBufferIndex; _releasedBufferIndex = _serverBufferIndex; _bufferReleasedCount = (uint)released.Length;
            int ok = 0;
            foreach (var p in pending) if (AppendBuffer(p.Tag, p.Ptr, p.Size)) ok++;
            ulong now = _state == AudioDeviceState.Stopped ? 0 : _hardwareDeviceSession.GetPlayedSampleCount();
            _s2aPlayedOffset = played > now ? played - now : 0;
            if (released.Length > 0) _bufferEvent.Signal();
            return ok;
        }

        /// <summary>
        /// Get the count of sample played in this session.
        /// </summary>
        /// <returns>The count of sample played in this session</returns>
        public ulong GetPlayedSampleCount()
        {
            if (_state == AudioDeviceState.Stopped)
            {
                return 0;
            }

            return _hardwareDeviceSession.GetPlayedSampleCount() + _s2aPlayedOffset;
        }

        /// <summary>
        /// Flush all buffers to the initial state.
        /// </summary>
        /// <returns>True if any buffer was flushed (a playing or an appended one)</returns>
        public bool FlushBuffers()
        {
            if (_state == AudioDeviceState.Stopped)
            {
                return false;
            }

            // S2Arm (#2157 作者推演、维护者核实)：已放回、游戏还没取走的缓冲留在放回环里照常可取，只从硬件注销。
            //   原先 TryPopReleasedBuffer 把它们弹掉、清空槽位：交 1、2、3，1 已放回未取、2 / 3 在播 → Flush 后游戏只取回 [2, 3]，1 永远回不来
            for (uint i = 0; i < _bufferReleasedCount; i++)
            {
                uint index = (_releasedBufferIndex - _bufferReleasedCount + i + Constants.AudioDeviceBufferCountMax) % Constants.AudioDeviceBufferCountMax;
                _hardwareDeviceSession.UnregisterBuffer(_buffers[index]);
            }

            // S2Arm: 在播缓冲按 Stop 路径的账目交还（ReleaseBuffer 推进 _releasedBufferIndex），并发放回事件。
            //   原 TryPopPlayingBuffer 只减 _bufferRegisteredCount、不推进 _releasedBufferIndex：放回环的取数区间
            //   [_releasedBufferIndex − _bufferReleasedCount, _releasedBufferIndex) 落后于在播区，之后再放回一个缓冲，
            //   GetReleasedBuffer / ContainsBuffer 就读到被清空的槽位（NullReferenceException，音频服务线程未捕获 → 宿主闪退）；
            //   被 Flush 的缓冲游戏也取不回
            bool flushed = false;

            while (TryGetPlayingBufferIndex(out uint playingIndex))
            {
                _hardwareDeviceSession.UnregisterBuffer(_buffers[playingIndex]);
                ReleaseBuffer(_buffers[playingIndex]);
                flushed = true;
            }

            // S2Arm (#2157)：已追加、还没交给硬件的缓冲（appended）也一并作废放回。原先这段要求「registered == 0 时 return false」在前，
            //   而上面的循环总把 registered 耗到 0，这段永远走不到：刚追加的缓冲躲过 Flush、下一次 Update 照常交给硬件播出来，返回值也恒为 false。
            //   返回值（游戏 FlushAudioOutBuffers 读到的 bool）= 这次有没有作废掉缓冲（在播的或已追加的），已放回的不算
            if (_bufferAppendedCount > 0 && _bufferReleasedCount + _bufferAppendedCount <= Constants.AudioDeviceBufferCountMax)
            {
                _bufferReleasedCount += _bufferAppendedCount;
                _releasedBufferIndex = (_releasedBufferIndex + _bufferAppendedCount) % Constants.AudioDeviceBufferCountMax;
                _bufferAppendedCount = 0;
                _hardwareBufferIndex = _serverBufferIndex;
                flushed = true;
            }

            if (flushed)
            {
                _bufferEvent.Signal();
            }

            return flushed;
        }

        /// <summary>
        /// Update the session.
        /// </summary>
        public void Update()
        {
            if (_state == AudioDeviceState.Started)
            {
                UpdateReleaseBuffers();
                FlushToHardware();
            }
        }

        public void Dispose()
        {
            Dispose(true);
        }

        protected virtual void Dispose(bool disposing)
        {
            if (disposing)
            {
                // Tell the hardware session that we are ending.
                _hardwareDeviceSession.PrepareToClose();

                // Unregister all buffers

                while (TryPopReleasedBuffer(out AudioBuffer buffer))
                {
                    _hardwareDeviceSession.UnregisterBuffer(buffer);
                }

                while (TryPopPlayingBuffer(out AudioBuffer buffer))
                {
                    _hardwareDeviceSession.UnregisterBuffer(buffer);
                }

                // Finally dispose hardware session.
                _hardwareDeviceSession.Dispose();

                _bufferEvent.Signal();
            }
        }
    }
}
