using Ryujinx.Audio.Common;
using Ryujinx.Audio.Renderer.Common;
using Ryujinx.Audio.Renderer.Dsp;
using Ryujinx.Audio.Renderer.Dsp.State;
using Ryujinx.Audio.Renderer.Parameter;
using Ryujinx.Audio.Renderer.Server.MemoryPool;
using Ryujinx.Common;
using Ryujinx.Common.Memory;
using Ryujinx.Common.Utilities;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using static Ryujinx.Audio.Renderer.Common.BehaviourParameter;
using PlayState = Ryujinx.Audio.Renderer.Server.Types.PlayState;

namespace Ryujinx.Audio.Renderer.Server.Voice
{
    [StructLayout(LayoutKind.Sequential, Pack = Alignment)]
    public struct VoiceInfo
    {
        public const int Alignment = 0x10;

        private static readonly ObjectPool<Memory<VoiceState>[]> voiceStatesPool = new(() => new Memory<VoiceState>[Constants.VoiceChannelCountMax]);

        /// <summary>
        /// Set to true if the voice is used.
        /// </summary>
        [MarshalAs(UnmanagedType.I1)]
        public bool InUse;

        /// <summary>
        /// Set to true if the voice is new.
        /// </summary>
        [MarshalAs(UnmanagedType.I1)]
        public bool IsNew;

        [MarshalAs(UnmanagedType.I1)]
        public bool WasPlaying;

        /// <summary>
        /// The <see cref="SampleFormat"/> of the voice.
        /// </summary>
        public SampleFormat SampleFormat;

        /// <summary>
        /// The sample rate of the voice.
        /// </summary>
        public uint SampleRate;

        /// <summary>
        /// The total channel count used.
        /// </summary>
        public uint ChannelsCount;

        /// <summary>
        /// Id of the voice.
        /// </summary>
        public int Id;

        /// <summary>
        /// Node id of the voice.
        /// </summary>
        public int NodeId;

        /// <summary>
        /// The target mix id of the voice.
        /// </summary>
        public int MixId;

        /// <summary>
        /// The current voice <see cref="Types.PlayState"/>.
        /// </summary>
        public PlayState PlayState;

        /// <summary>
        /// The previous voice <see cref="Types.PlayState"/>.
        /// </summary>
        public PlayState PreviousPlayState;

        /// <summary>
        /// The priority of the voice.
        /// </summary>
        public uint Priority;

        /// <summary>
        /// Target sorting position of the voice. (used to sort voice with the same <see cref="Priority"/>)
        /// </summary>
        public uint SortingOrder;

        /// <summary>
        /// The pitch used on the voice.
        /// </summary>
        public float Pitch;

        /// <summary>
        /// The output volume of the voice.
        /// </summary>
        public float Volume;

        /// <summary>
        /// The previous output volume of the voice.
        /// </summary>
        public float PreviousVolume;

        /// <summary>
        /// Biquad filters to apply to the output of the voice.
        /// </summary>
        public Array2<BiquadFilterParameter2> BiquadFilters;

        /// <summary>
        /// Total count of <see cref="WaveBufferInternal"/> of the voice.
        /// </summary>
        public uint WaveBuffersCount;

        /// <summary>
        /// Current playing <see cref="WaveBufferInternal"/> of the voice.
        /// </summary>
        public uint WaveBuffersIndex;

        /// <summary>
        /// Change the behaviour of the voice.
        /// </summary>
        /// <remarks>This was added on REV5.</remarks>
        public DecodingBehaviour DecodingBehaviour;

        /// <summary>
        /// User state <see cref="AddressInfo"/> required by the data source.
        /// </summary>
        /// <remarks>Only used for <see cref="SampleFormat.Adpcm"/> as the GC-ADPCM coefficients.</remarks>
        public AddressInfo DataSourceStateAddressInfo;

        /// <summary>
        /// The wavebuffers of this voice.
        /// </summary>
        public Array4<WaveBuffer> WaveBuffers;

        /// <summary>
        /// The channel resource ids associated to the voice.
        /// </summary>
        public Array6<int> ChannelResourceIds;

        /// <summary>
        /// The target splitter id of the voice.
        /// </summary>
        public uint SplitterId;

        /// <summary>
        /// Change the Sample Rate Conversion (SRC) quality of the voice.
        /// </summary>
        /// <remarks>This was added on REV8.</remarks>
        public SampleRateConversionQuality SrcQuality;

        /// <summary>
        /// If set to true, the voice was dropped.
        /// </summary>
        [MarshalAs(UnmanagedType.I1)]
        public bool VoiceDropFlag;

        /// <summary>
        /// Set to true if the data source state work buffer wasn't mapped.
        /// </summary>
        [MarshalAs(UnmanagedType.I1)]
        public bool DataSourceStateUnmapped;

        /// <summary>
        /// Set to true if any of the <see cref="WaveBuffer.BufferAddressInfo"/> work buffer wasn't mapped.
        /// </summary>
        [MarshalAs(UnmanagedType.I1)]
        public bool BufferInfoUnmapped;

        /// <summary>
        /// The biquad filter initialization state storage.
        /// </summary>
        private BiquadFilterNeedInitializationArrayStruct _biquadFilterNeedInitialization;

        /// <summary>
        /// Flush the amount of wavebuffer specified. This will result in the wavebuffer being skipped and marked played.
        /// </summary>
        /// <remarks>This was added on REV5.</remarks>
        public byte FlushWaveBufferCount;

        [StructLayout(LayoutKind.Sequential, Size = Constants.VoiceBiquadFilterCount)]
        private struct BiquadFilterNeedInitializationArrayStruct { }

        /// <summary>
        /// The biquad filter initialization state array.
        /// </summary>
        public Span<bool> BiquadFilterNeedInitialization => SpanHelpers.AsSpan<BiquadFilterNeedInitializationArrayStruct, bool>(ref _biquadFilterNeedInitialization);

        private static List<ErrorInfo> _waveBufferUpdaterErrorInfosList;

        /// <summary>
        /// Initialize the <see cref="VoiceInfo"/>.
        /// </summary>
        public void Initialize()
        {
            IsNew = false;
            VoiceDropFlag = false;
            DataSourceStateUnmapped = false;
            BufferInfoUnmapped = false;
            FlushWaveBufferCount = 0;
            PlayState = PlayState.Stopped;
            Priority = Constants.VoiceLowestPriority;
            Id = 0;
            NodeId = 0;
            SampleRate = 0;
            SampleFormat = SampleFormat.Invalid;
            ChannelsCount = 0;
            Pitch = 0.0f;
            Volume = 0.0f;
            PreviousVolume = 0.0f;
            BiquadFilters.AsSpan().Clear();
            WaveBuffersCount = 0;
            WaveBuffersIndex = 0;
            MixId = Constants.UnusedMixId;
            SplitterId = Constants.UnusedSplitterId;
            DataSourceStateAddressInfo.Setup(0, 0);

            InitializeWaveBuffers();

            _waveBufferUpdaterErrorInfosList ??= [];
        }

        /// <summary>
        /// Initialize the <see cref="WaveBuffer"/> in this <see cref="VoiceInfo"/>.
        /// </summary>
        internal void InitializeWaveBuffers()   // S2Arm (#12/#13 拆分): 影子驱动的波表段要走今天同一条初始化
        {
            Span<WaveBuffer> waveBuffersSpan = WaveBuffers.AsSpan();
            
            for (int i = 0; i < waveBuffersSpan.Length; i++)
            {
                waveBuffersSpan[i].StartSampleOffset = 0;
                waveBuffersSpan[i].EndSampleOffset = 0;
                waveBuffersSpan[i].ShouldLoop = false;
                waveBuffersSpan[i].IsEndOfStream = false;
                waveBuffersSpan[i].BufferAddressInfo.Setup(0, 0);
                waveBuffersSpan[i].ContextAddressInfo.Setup(0, 0);
                waveBuffersSpan[i].IsSendToAudioProcessor = true;
            }
        }

        /// <summary>
        /// Check if the voice needs to be skipped.
        /// </summary>
        /// <returns>Returns true if the voice needs to be skipped.</returns>
        public readonly bool ShouldSkip()
        {
            return !InUse || WaveBuffersCount == 0 || DataSourceStateUnmapped || BufferInfoUnmapped || VoiceDropFlag;
        }

        /// <summary>
        /// Return true if the mix has any destinations.
        /// </summary>
        /// <returns>True if the mix has any destinations.</returns>
        public readonly bool HasAnyDestination()
        {
            return MixId != Constants.UnusedMixId || SplitterId != Constants.UnusedSplitterId;
        }
        
        /// <summary>
        /// Indicate if the server voice information needs to be updated.
        /// </summary>
        /// <param name="parameter">The user parameter.</param>
        /// <returns>Return true, if the server voice information needs to be updated.</returns>
        private readonly bool ShouldUpdateParameters2(in VoiceInParameter2 parameter)
        {
            if (DataSourceStateAddressInfo.CpuAddress == parameter.DataSourceStateAddress)
            {
                return DataSourceStateAddressInfo.Size != parameter.DataSourceStateSize;
            }

            return DataSourceStateAddressInfo.CpuAddress != parameter.DataSourceStateAddress ||
                   DataSourceStateAddressInfo.Size != parameter.DataSourceStateSize ||
                   DataSourceStateUnmapped;
        }

        /// <summary>
        /// Indicate if the server voice information needs to be updated.
        /// </summary>
        /// <param name="parameter">The user parameter.</param>
        /// <returns>Return true, if the server voice information needs to be updated.</returns>
        private readonly bool ShouldUpdateParameters1(in VoiceInParameter1 parameter)
        {
            if (DataSourceStateAddressInfo.CpuAddress == parameter.DataSourceStateAddress)
            {
                return DataSourceStateAddressInfo.Size != parameter.DataSourceStateSize;
            }

            return DataSourceStateAddressInfo.CpuAddress != parameter.DataSourceStateAddress ||
                   DataSourceStateAddressInfo.Size != parameter.DataSourceStateSize ||
                   DataSourceStateUnmapped;
        }
        
        /// <summary>
        /// Update the internal state from a user parameter.
        /// </summary>
        /// <param name="outErrorInfo">The possible <see cref="ErrorInfo"/> that was generated.</param>
        /// <param name="parameter">The user parameter.</param>
        /// <param name="poolMapper">The mapper to use.</param>
        /// <param name="behaviourInfo">The behaviour context.</param>
        public void UpdateParameters2(out ErrorInfo outErrorInfo, in VoiceInParameter2 parameter, PoolMapper poolMapper, ref BehaviourInfo behaviourInfo)
        {
            InUse = parameter.InUse;
            Id = parameter.Id;
            NodeId = parameter.NodeId;

            UpdatePlayState(parameter.PlayState);

            SrcQuality = parameter.SrcQuality;

            Priority = parameter.Priority;
            SortingOrder = parameter.SortingOrder;
            SampleRate = parameter.SampleRate;
            SampleFormat = parameter.SampleFormat;
            ChannelsCount = parameter.ChannelCount;
            Pitch = parameter.Pitch;
            Volume = parameter.Volume;
            parameter.BiquadFilters.AsSpan().CopyTo(BiquadFilters.AsSpan());
            WaveBuffersCount = parameter.WaveBuffersCount;
            WaveBuffersIndex = parameter.WaveBuffersIndex;

            if (behaviourInfo.IsFlushVoiceWaveBuffersSupported())
            {
                FlushWaveBufferCount += parameter.FlushWaveBufferCount;
            }

            MixId = parameter.MixId;

            if (behaviourInfo.IsSplitterSupported())
            {
                SplitterId = parameter.SplitterId;
            }
            else
            {
                SplitterId = Constants.UnusedSplitterId;
            }

            parameter.ChannelResourceIds.AsSpan().CopyTo(ChannelResourceIds.AsSpan());

            DecodingBehaviour behaviour = DecodingBehaviour.Default;

            if (behaviourInfo.IsDecodingBehaviourFlagSupported())
            {
                behaviour = parameter.DecodingBehaviourFlags;
            }

            DecodingBehaviour = behaviour;

            if (parameter.ResetVoiceDropFlag)
            {
                VoiceDropFlag = false;
            }

            if (ShouldUpdateParameters2(in parameter))
            {
                DataSourceStateUnmapped = !poolMapper.TryAttachBuffer(out outErrorInfo, ref DataSourceStateAddressInfo, parameter.DataSourceStateAddress, parameter.DataSourceStateSize);
            }
            else
            {
                outErrorInfo = new ErrorInfo();
            }
        }

        /// <summary>
        /// Update the internal state from a user parameter.
        /// </summary>
        /// <param name="outErrorInfo">The possible <see cref="ErrorInfo"/> that was generated.</param>
        /// <param name="parameter">The user paramter2.</param>
        /// <param name="poolMapper">The mapper to use.</param>
        /// <param name="behaviourInfo">The behaviour context.</param>
        public void UpdateParameters1(out ErrorInfo outErrorInfo, in VoiceInParameter1 parameter, PoolMapper poolMapper, ref BehaviourInfo behaviourInfo)
        {
            InUse = parameter.InUse;
            Id = parameter.Id;
            NodeId = parameter.NodeId;

            UpdatePlayState(parameter.PlayState);

            SrcQuality = parameter.SrcQuality;

            Priority = parameter.Priority;
            SortingOrder = parameter.SortingOrder;
            SampleRate = parameter.SampleRate;
            SampleFormat = parameter.SampleFormat;
            ChannelsCount = parameter.ChannelCount;
            Pitch = parameter.Pitch;
            Volume = parameter.Volume;
            BiquadFilters[0] = BiquadFilterHelper.ToBiquadFilterParameter2(parameter.BiquadFilters[0]);
            BiquadFilters[1] = BiquadFilterHelper.ToBiquadFilterParameter2(parameter.BiquadFilters[1]);
            WaveBuffersCount = parameter.WaveBuffersCount;
            WaveBuffersIndex = parameter.WaveBuffersIndex;

            if (behaviourInfo.IsFlushVoiceWaveBuffersSupported())
            {
                FlushWaveBufferCount += parameter.FlushWaveBufferCount;
            }

            MixId = parameter.MixId;

            if (behaviourInfo.IsSplitterSupported())
            {
                SplitterId = parameter.SplitterId;
            }
            else
            {
                SplitterId = Constants.UnusedSplitterId;
            }

            parameter.ChannelResourceIds.AsSpan().CopyTo(ChannelResourceIds.AsSpan());

            DecodingBehaviour behaviour = DecodingBehaviour.Default;

            if (behaviourInfo.IsDecodingBehaviourFlagSupported())
            {
                behaviour = parameter.DecodingBehaviourFlags;
            }

            DecodingBehaviour = behaviour;

            if (parameter.ResetVoiceDropFlag)
            {
                VoiceDropFlag = false;
            }

            if (ShouldUpdateParameters1(in parameter))
            {
                DataSourceStateUnmapped = !poolMapper.TryAttachBuffer(out outErrorInfo, ref DataSourceStateAddressInfo, parameter.DataSourceStateAddress, parameter.DataSourceStateSize);
            }
            else
            {
                outErrorInfo = new ErrorInfo();
            }
        }

        /// <summary>
        /// Update the internal play state from user play state.
        /// </summary>
        /// <param name="userPlayState">The target user play state.</param>
        public void UpdatePlayState(Common.PlayState userPlayState)
        {
            (PlayState, PreviousPlayState) = S2AUpdatePlayState(PlayState, userPlayState);
        }

        // S2Arm (#12/#13 拆分): 播放态迁移的纯函数。锁2a 落账对「活」PlayState 重放——中拍(解析段进行时的渲染拍)把
        //   Stopping 迁到 Stopped 时,按活值重算 = 「Update 在拍后串行」的今天语义;快照基底重算会复活 Stopping,
        //   下一拍再清一遍把已消费的波表再消费一次。语义与原内联体逐行一致:PreviousPlayState 恒写老值
        //   (Stop 打在 Stopped 上的早退也在写完之后),Stop+Stopped 时 PlayState 保持不动
        internal static (PlayState NewState, PlayState PreviousState) S2AUpdatePlayState(PlayState oldServerPlayState, Common.PlayState userPlayState)
        {
            PlayState newServerPlayState;

            switch (userPlayState)
            {
                case Common.PlayState.Start:
                    newServerPlayState = PlayState.Started;
                    break;

                case Common.PlayState.Stop:
                    if (oldServerPlayState == PlayState.Stopped)
                    {
                        return (oldServerPlayState, oldServerPlayState);
                    }

                    newServerPlayState = PlayState.Stopping;
                    break;

                case Common.PlayState.Pause:
                    newServerPlayState = PlayState.Paused;
                    break;

                default:
                    throw new NotImplementedException($"Unhandled PlayState.{userPlayState}");
            }

            return (newServerPlayState, oldServerPlayState);
        }
        
        /// <summary>
        /// Write the status of the voice to the given user output.
        /// </summary>
        /// <param name="outStatus">The given user output.</param>
        /// <param name="parameter">The user parameter.</param>
        /// <param name="voiceStates">The voice states associated to the <see cref="VoiceInfo"/>.</param>
        public void WriteOutStatus2(ref VoiceOutStatus outStatus, in VoiceInParameter2 parameter, ReadOnlySpan<Memory<VoiceState>> voiceStates)
        {
#if DEBUG
            // Sanity check in debug mode of the internal state
            if (!parameter.IsNew && !IsNew)
            {
                for (int i = 1; i < ChannelsCount; i++)
                {
                    ref VoiceState stateA = ref voiceStates[i - 1].Span[0];
                    ref VoiceState stateB = ref voiceStates[i].Span[0];

                    Debug.Assert(stateA.WaveBufferConsumed == stateB.WaveBufferConsumed);
                    Debug.Assert(stateA.PlayedSampleCount == stateB.PlayedSampleCount);
                    Debug.Assert(stateA.Offset == stateB.Offset);
                    Debug.Assert(stateA.WaveBufferIndex == stateB.WaveBufferIndex);
                    Debug.Assert(stateA.Fraction == stateB.Fraction);
                    Debug.Assert(stateA.IsWaveBufferValid.SequenceEqual(stateB.IsWaveBufferValid));
                }
            }
#endif
            if (parameter.IsNew || IsNew)
            {
                IsNew = true;

                outStatus.VoiceDropFlag = false;
                outStatus.PlayedWaveBuffersCount = 0;
                outStatus.PlayedSampleCount = 0;
            }
            else
            {
                ref VoiceState state = ref voiceStates[0].Span[0];

                outStatus.VoiceDropFlag = VoiceDropFlag;
                outStatus.PlayedWaveBuffersCount = state.WaveBufferConsumed;
                outStatus.PlayedSampleCount = state.PlayedSampleCount;
            }
        }

        /// <summary>
        /// Write the status of the voice to the given user output.
        /// </summary>
        /// <param name="outStatus">The given user output.</param>
        /// <param name="parameter">The user parameter.</param>
        /// <param name="voiceStates">The voice states associated to the <see cref="VoiceInfo"/>.</param>
        public void WriteOutStatus1(ref VoiceOutStatus outStatus, in VoiceInParameter1 parameter, ReadOnlySpan<Memory<VoiceState>> voiceStates)
        {
#if DEBUG
            // Sanity check in debug mode of the internal state
            if (!parameter.IsNew && !IsNew)
            {
                for (int i = 1; i < ChannelsCount; i++)
                {
                    ref VoiceState stateA = ref voiceStates[i - 1].Span[0];
                    ref VoiceState stateB = ref voiceStates[i].Span[0];

                    Debug.Assert(stateA.WaveBufferConsumed == stateB.WaveBufferConsumed);
                    Debug.Assert(stateA.PlayedSampleCount == stateB.PlayedSampleCount);
                    Debug.Assert(stateA.Offset == stateB.Offset);
                    Debug.Assert(stateA.WaveBufferIndex == stateB.WaveBufferIndex);
                    Debug.Assert(stateA.Fraction == stateB.Fraction);
                    Debug.Assert(stateA.IsWaveBufferValid.SequenceEqual(stateB.IsWaveBufferValid));
                }
            }
#endif
            if (parameter.IsNew || IsNew)
            {
                IsNew = true;

                outStatus.VoiceDropFlag = false;
                outStatus.PlayedWaveBuffersCount = 0;
                outStatus.PlayedSampleCount = 0;
            }
            else
            {
                ref VoiceState state = ref voiceStates[0].Span[0];

                outStatus.VoiceDropFlag = VoiceDropFlag;
                outStatus.PlayedWaveBuffersCount = state.WaveBufferConsumed;
                outStatus.PlayedSampleCount = state.PlayedSampleCount;
            }
        }
        
        /// <summary>
        /// Update the internal state of all the <see cref="WaveBuffer"/> of the <see cref="VoiceInfo"/>.
        /// </summary>
        /// <param name="errorInfos">An array of <see cref="ErrorInfo"/> used to report errors when mapping any of the <see cref="WaveBuffer"/>.</param>
        /// <param name="parameter">The user parameter.</param>
        /// <param name="voiceStates">The voice states associated to the <see cref="VoiceInfo"/>.</param>
        /// <param name="mapper">The mapper to use.</param>
        /// <param name="behaviourInfo">The behaviour context.</param>
        public void UpdateWaveBuffers2(
            out ErrorInfo[] errorInfos,
            in VoiceInParameter2 parameter,
            ReadOnlySpan<Memory<VoiceState>> voiceStates,
            PoolMapper mapper,
            ref BehaviourInfo behaviourInfo)
        {
            

            if (parameter.IsNew)
            {
                InitializeWaveBuffers();

                for (int i = 0; i < parameter.ChannelCount; i++)
                {
                    voiceStates[i].Span[0].IsWaveBufferValid.Clear();
                }
            }

            ref VoiceState voiceState = ref voiceStates[0].Span[0];
            
            Span<WaveBuffer> waveBuffersSpan = WaveBuffers.AsSpan();
            Span<WaveBufferInternal> pWaveBuffersSpan = parameter.WaveBuffers.AsSpan();
            _waveBufferUpdaterErrorInfosList.Clear();

            for (int i = 0; i < Constants.VoiceWaveBufferCount; i++)
            {
                UpdateWaveBuffer(_waveBufferUpdaterErrorInfosList, ref waveBuffersSpan[i], ref pWaveBuffersSpan[i], parameter.SampleFormat, voiceState.IsWaveBufferValid[i], mapper, ref behaviourInfo);
            }
            
            errorInfos = _waveBufferUpdaterErrorInfosList.ToArray();
        }

        /// <summary>
        /// Update the internal state of all the <see cref="WaveBuffer"/> of the <see cref="VoiceInfo"/>.
        /// </summary>
        /// <param name="errorInfos">An array of <see cref="ErrorInfo"/> used to report errors when mapping any of the <see cref="WaveBuffer"/>.</param>
        /// <param name="parameter">The user parameter.</param>
        /// <param name="voiceStates">The voice states associated to the <see cref="VoiceInfo"/>.</param>
        /// <param name="mapper">The mapper to use.</param>
        /// <param name="behaviourInfo">The behaviour context.</param>
        public void UpdateWaveBuffers1(
            out ErrorInfo[] errorInfos,
            in VoiceInParameter1 parameter,
            ReadOnlySpan<Memory<VoiceState>> voiceStates,
            PoolMapper mapper,
            ref BehaviourInfo behaviourInfo)
        {
            

            if (parameter.IsNew)
            {
                InitializeWaveBuffers();

                for (int i = 0; i < parameter.ChannelCount; i++)
                {
                    voiceStates[i].Span[0].IsWaveBufferValid.Clear();
                }
            }

            ref VoiceState voiceState = ref voiceStates[0].Span[0];
            
            Span<WaveBuffer> waveBuffersSpan = WaveBuffers.AsSpan();
            Span<WaveBufferInternal> pWaveBuffersSpan = parameter.WaveBuffers.AsSpan();
            _waveBufferUpdaterErrorInfosList.Clear();

            for (int i = 0; i < Constants.VoiceWaveBufferCount; i++)
            {
                UpdateWaveBuffer(_waveBufferUpdaterErrorInfosList, ref waveBuffersSpan[i], ref pWaveBuffersSpan[i], parameter.SampleFormat, voiceState.IsWaveBufferValid[i], mapper, ref behaviourInfo);
            }
            
            errorInfos = _waveBufferUpdaterErrorInfosList.ToArray();
        }

        /// <summary>
        /// Update the internal state of one of the <see cref="WaveBuffer"/> of the <see cref="VoiceInfo"/>.
        /// </summary>
        /// <param name="errorInfos">A <see cref="Span{ErrorInfo}"/> used to report errors when mapping the <see cref="WaveBuffer"/>.</param>
        /// <param name="waveBuffer">The <see cref="WaveBuffer"/> to update.</param>
        /// <param name="inputWaveBuffer">The <see cref="WaveBufferInternal"/> from the user input.</param>
        /// <param name="sampleFormat">The <see cref="SampleFormat"/> from the user input.</param>
        /// <param name="isValid">If set to true, the server side wavebuffer is considered valid.</param>
        /// <param name="mapper">The mapper to use.</param>
        /// <param name="behaviourInfo">The behaviour context.</param>
        private void UpdateWaveBuffer(
            List<ErrorInfo> errorInfos,
            ref WaveBuffer waveBuffer,
            ref WaveBufferInternal inputWaveBuffer,
            SampleFormat sampleFormat,
            bool isValid,
            PoolMapper mapper,
            ref BehaviourInfo behaviourInfo)
        {
            S2AUpdateWaveBuffer(errorInfos, ref waveBuffer, ref inputWaveBuffer, sampleFormat, isValid, mapper, ref behaviourInfo, ref BufferInfoUnmapped);
        }

        // S2Arm (#12/#13 拆分 · 处方①②③的载体): 单个波表槽更新的纯核,与原内联体逐行同体;BufferInfoUnmapped
        //   (voice 级,四槽按原序演化)按引用进出。三处调用、一个语义:
        //   ① 解析段(锁外):基底 = 锁1 快照槽,isValid = 解析段读到的(CPU 侧 IsWaveBufferValid),产出影子槽;
        //   ② 锁2a 翻转重演:同一基底 = 锁1 快照槽(含旧地址与旧 IsSendToAudioProcessor),isValid = 落账时活的
        //     (中拍被 Stopping 清全数组 / FlushWaveBuffers / DSP 消费回拷翻成 false)——重跑 isValid 分支与重发分支
        //     两者,产出整体替换该槽的解析段结果。不能拿解析后的影子当基底::664 条件里的 IsSendToAudioProcessor
        //     已被重发置 false,分支整跳过,A_old 的 Unmap 丢失;重发分支重跑一遍还会把错误二次入队、:674 的
        //     Debug.Assert 直接触发——基底必须是快照槽(断言与今天的触发条件完全一致)。
        //   ③ 单测直调(纯函数/日志重演口径):同基底换 isValid 输入比对今天串行序的终值与错误段。
        //   hook 槽的今天时序:isValid 分支的 Unmap(A_old) 在前、重发挂接的双 Map(A_new) 在后(AssignDspAddress
        //   强制映射路径本样双 Map,见 PoolMapper.S2AHookLog)。
        internal static void S2AUpdateWaveBuffer(
            List<ErrorInfo> errorInfos,
            ref WaveBuffer waveBuffer,
            ref WaveBufferInternal inputWaveBuffer,
            SampleFormat sampleFormat,
            bool isValid,
            PoolMapper mapper,
            ref BehaviourInfo behaviourInfo,
            ref bool bufferInfoUnmapped)
        {
            if (!isValid && waveBuffer.IsSendToAudioProcessor && waveBuffer.BufferAddressInfo.CpuAddress != 0)
            {
                mapper.ForceUnmap(ref waveBuffer.BufferAddressInfo);
                waveBuffer.BufferAddressInfo.Setup(0, 0);
            }

            if (!inputWaveBuffer.SentToServer || bufferInfoUnmapped)
            {
                if (inputWaveBuffer.IsSampleOffsetValid(sampleFormat))
                {
                    Debug.Assert(waveBuffer.IsSendToAudioProcessor);

                    waveBuffer.IsSendToAudioProcessor = false;
                    waveBuffer.StartSampleOffset = inputWaveBuffer.StartSampleOffset;
                    waveBuffer.EndSampleOffset = inputWaveBuffer.EndSampleOffset;
                    waveBuffer.ShouldLoop = inputWaveBuffer.ShouldLoop;
                    waveBuffer.IsEndOfStream = inputWaveBuffer.IsEndOfStream;
                    waveBuffer.LoopStartSampleOffset = inputWaveBuffer.LoopFirstSampleOffset;
                    waveBuffer.LoopEndSampleOffset = inputWaveBuffer.LoopLastSampleOffset;
                    waveBuffer.LoopCount = inputWaveBuffer.LoopCount;

                    bufferInfoUnmapped = !mapper.TryAttachBuffer(out ErrorInfo bufferInfoError, ref waveBuffer.BufferAddressInfo, inputWaveBuffer.Address, inputWaveBuffer.Size);

                    if (bufferInfoError.ErrorCode != ResultCode.Success)
                    {
                        errorInfos.Add(bufferInfoError);
                    }

                    if (sampleFormat == SampleFormat.Adpcm && behaviourInfo.IsAdpcmLoopContextBugFixed() && inputWaveBuffer.ContextAddress != 0)
                    {
                        bool adpcmLoopContextMapped = mapper.TryAttachBuffer(out ErrorInfo adpcmLoopContextInfoError,
                                                                             ref waveBuffer.ContextAddressInfo,
                                                                             inputWaveBuffer.ContextAddress,
                                                                             inputWaveBuffer.ContextSize);

                        if (adpcmLoopContextInfoError.ErrorCode != ResultCode.Success)
                        {
                            errorInfos.Add(adpcmLoopContextInfoError);
                        }

                        if (!adpcmLoopContextMapped || bufferInfoUnmapped)
                        {
                            bufferInfoUnmapped = true;
                        }
                        else
                        {
                            bufferInfoUnmapped = false;
                        }
                    }
                    else
                    {
                        waveBuffer.ContextAddressInfo.Setup(0, 0);
                    }
                }
                else
                {
                    errorInfos.Add(new ErrorInfo
                    {
                        ErrorCode = ResultCode.InvalidAddressInfo,
                        ExtraErrorInfo = inputWaveBuffer.Address
                    });
                }
            }
        }

        /// <summary>
        /// Reset the resources associated to this <see cref="VoiceInfo"/>.
        /// </summary>
        /// <param name="context">The voice context.</param>
        private void ResetResources(VoiceContext context)
        {
            Span<int> channelResourceIdsSpan = ChannelResourceIds.AsSpan();
            
            for (int i = 0; i < ChannelsCount; i++)
            {
                int channelResourceId = channelResourceIdsSpan[i];

                ref VoiceChannelResource voiceChannelResource = ref context.GetChannelResource(channelResourceId);

                Debug.Assert(voiceChannelResource.IsUsed);

                Memory<VoiceState> dspSharedState = context.GetUpdateStateForDsp(channelResourceId);

                MemoryMarshal.Cast<VoiceState, byte>(dspSharedState.Span).Clear();

                voiceChannelResource.UpdateState();
            }
        }

        /// <summary>
        /// Flush a certain amount of <see cref="WaveBuffer"/>.
        /// </summary>
        /// <param name="waveBufferCount">The amount of wavebuffer to flush.</param>
        /// <param name="voiceStates">The voice states associated to the <see cref="VoiceInfo"/>.</param>
        /// <param name="channelCount">The channel count from user input.</param>
        private void FlushWaveBuffers(uint waveBufferCount, Memory<VoiceState>[] voiceStates, uint channelCount)
        {
            uint waveBufferIndex = WaveBuffersIndex;
            
            Span<WaveBuffer> waveBuffersSpan = WaveBuffers.AsSpan();

            for (int i = 0; i < waveBufferCount; i++)
            {
                waveBuffersSpan[(int)waveBufferIndex].IsSendToAudioProcessor = true;

                uint nextWaveBufferIndex = (waveBufferIndex + 1) % Constants.VoiceWaveBufferCount;

                for (int j = 0; j < channelCount; j++)
                {
                    ref VoiceState voiceState = ref voiceStates[j].Span[0];

                    // S2Arm: same as nn::audio::server::VoiceInfo::FlushWaveBuffers in the SDK: a flushed buffer counts as consumed
                    // when the DSP is still at its slot, whether or not it was ever sent to the DSP. The previous check
                    // (!IsSendToAudioProcessor || IsWaveBufferValid) read IsSendToAudioProcessor after setting it, so a buffer
                    // appended to a stopped or paused voice was never counted and the guest never got it back.
                    if (voiceState.WaveBufferIndex == waveBufferIndex)
                    {
                        voiceState.WaveBufferIndex = nextWaveBufferIndex;
                        voiceState.WaveBufferConsumed++;
                    }

                    voiceState.IsWaveBufferValid[(int)waveBufferIndex] = false;
                }

                waveBufferIndex = nextWaveBufferIndex;
            }
        }

        /// <summary>
        /// Update the internal parameters for command generation.
        /// </summary>
        /// <param name="voiceStates">The voice states associated to the <see cref="VoiceInfo"/>.</param>
        /// <returns>Return true if this voice should be played.</returns>
        public bool UpdateParametersForCommandGeneration(Memory<VoiceState>[] voiceStates)
        {
            if (FlushWaveBufferCount != 0)
            {
                FlushWaveBuffers(FlushWaveBufferCount, voiceStates, ChannelsCount);

                FlushWaveBufferCount = 0;
            }

            Span<WaveBuffer> waveBuffersSpan;

            switch (PlayState)
            {
                case PlayState.Started:
                    waveBuffersSpan = WaveBuffers.AsSpan();
                    
                    for (int i = 0; i < waveBuffersSpan.Length; i++)
                    {
                        ref WaveBuffer waveBuffer = ref waveBuffersSpan[i];

                        if (!waveBuffer.IsSendToAudioProcessor)
                        {
                            for (int y = 0; y < ChannelsCount; y++)
                            {
                                Debug.Assert(!voiceStates[y].Span[0].IsWaveBufferValid[i]);

                                voiceStates[y].Span[0].IsWaveBufferValid[i] = true;
                            }

                            waveBuffer.IsSendToAudioProcessor = true;
                        }
                    }

                    WasPlaying = false;

                    ref VoiceState primaryVoiceState = ref voiceStates[0].Span[0];

                    for (int i = 0; i < primaryVoiceState.IsWaveBufferValid.Length; i++)
                    {
                        if (primaryVoiceState.IsWaveBufferValid[i])
                        {
                            return true;
                        }
                    }

                    return false;

                case PlayState.Stopping:
                    waveBuffersSpan = WaveBuffers.AsSpan();
                    
                    for (int i = 0; i < waveBuffersSpan.Length; i++)
                    {
                        ref WaveBuffer waveBuffer = ref waveBuffersSpan[i];

                        waveBuffer.IsSendToAudioProcessor = true;

                        for (int j = 0; j < ChannelsCount; j++)
                        {
                            ref VoiceState voiceState = ref voiceStates[j].Span[0];

                            if (voiceState.IsWaveBufferValid[i])
                            {
                                voiceState.WaveBufferIndex = (voiceState.WaveBufferIndex + 1) % Constants.VoiceWaveBufferCount;
                                voiceState.WaveBufferConsumed++;
                            }

                            voiceState.IsWaveBufferValid[i] = false;
                        }
                    }

                    for (int i = 0; i < ChannelsCount; i++)
                    {
                        ref VoiceState voiceState = ref voiceStates[i].Span[0];

                        voiceState.Offset = 0;
                        voiceState.PlayedSampleCount = 0;
                        voiceState.Pitch.AsSpan().Clear();
                        voiceState.Fraction = 0;
                        voiceState.LoopContext = new AdpcmLoopContext();
                    }

                    PlayState = PlayState.Stopped;
                    WasPlaying = PreviousPlayState == PlayState.Started;

                    return WasPlaying;

                case PlayState.Stopped:
                case PlayState.Paused:
                    foreach (ref WaveBuffer wavebuffer in WaveBuffers.AsSpan())
                    {
                        wavebuffer.BufferAddressInfo.GetReference(true);
                        wavebuffer.ContextAddressInfo.GetReference(true);
                    }

                    if (SampleFormat == SampleFormat.Adpcm)
                    {
                        if (DataSourceStateAddressInfo.CpuAddress != 0)
                        {
                            DataSourceStateAddressInfo.GetReference(true);
                        }
                    }

                    WasPlaying = PreviousPlayState == PlayState.Started;

                    return WasPlaying;
                default:
                    throw new NotImplementedException($"{PlayState}");
            }
        }

        /// <summary>
        /// Update the internal state for command generation.
        /// </summary>
        /// <param name="context">The voice context.</param>
        /// <returns>Return true if this voice should be played.</returns>
        public bool UpdateForCommandGeneration(VoiceContext context)
        {
            if (IsNew)
            {
                ResetResources(context);
                PreviousVolume = Volume;
                IsNew = false;
            }

            Memory<VoiceState>[] voiceStates = voiceStatesPool.Allocate();

            Span<int> channelResourceIdsSpan = ChannelResourceIds.AsSpan();
            
            for (int i = 0; i < ChannelsCount; i++)
            {
                voiceStates[i] = context.GetUpdateStateForDsp(channelResourceIdsSpan[i]);
            }

            bool result = UpdateParametersForCommandGeneration(voiceStates);
            
            voiceStatesPool.Release(voiceStates); 
            //might contain garbage data, but said data will never be accessed
            
            return result;
        }
    }
}
