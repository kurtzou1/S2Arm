using Ryujinx.Audio.Integration;
using Ryujinx.Audio.Renderer.Common;
using Ryujinx.Audio.Renderer.Dsp.Command;
using Ryujinx.Audio.Renderer.Dsp.State;
using Ryujinx.Audio.Renderer.Parameter;
using Ryujinx.Audio.Renderer.Server.Effect;
using Ryujinx.Audio.Renderer.Server.MemoryPool;
using Ryujinx.Audio.Renderer.Server.Mix;
using Ryujinx.Audio.Renderer.Server.Performance;
using Ryujinx.Audio.Renderer.Server.Sink;
using Ryujinx.Audio.Renderer.Server.Splitter;
using Ryujinx.Audio.Renderer.Server.Types;
using Ryujinx.Audio.Renderer.Server.Upsampler;
using Ryujinx.Audio.Renderer.Server.Voice;
using Ryujinx.Audio.Renderer.Utils;
using Ryujinx.Common;
using Ryujinx.Common.Logging;
using Ryujinx.Memory;
using System;
using System.Buffers;
using System.Diagnostics;
using System.Threading;
using CpuAddress = System.UInt64;

namespace Ryujinx.Audio.Renderer.Server
{
    public class AudioRenderSystem : IDisposable
    {
        private readonly Lock _lock = new();

        private AudioRendererRenderingDevice _renderingDevice;
        private AudioRendererExecutionMode _executionMode;
        private readonly IWritableEvent _systemEvent;
        private MemoryPoolInfo _dspMemoryPoolInfo;
        private readonly VoiceContext _voiceContext;
        private readonly MixContext _mixContext;
        private readonly SinkContext _sinkContext;
        private readonly SplitterContext _splitterContext;
        private readonly EffectContext _effectContext;
        private PerformanceManager _performanceManager;
        private UpsamplerManager _upsamplerManager;
        private bool _isActive;
        private BehaviourInfo _behaviourInfo;
#pragma warning disable IDE0052 // Remove unread private member
        private ulong _totalElapsedTicksUpdating;
        private ulong _totalElapsedTicks;
#pragma warning restore IDE0052
        private int _sessionId;
        private Memory<MemoryPoolInfo> _memoryPools;

        private uint _sampleRate;
        private uint _sampleCount;
        private uint _mixBufferCount;
        private uint _voiceChannelCountMax;
        private uint _upsamplerCount;
        private uint _memoryPoolCount;
        private uint _processHandle;
        private ulong _appletResourceId;

        private MemoryHandle _workBufferMemoryPin;

        // S2Arm: work buffer in native memory owned by this renderer (see AudioRendererManager.OpenAudioRenderer)
        private unsafe byte* _ownedWorkBuffer;

        // S2Arm: voice slot diagnostics (S2A_AUDIO_VOICE_DIAG=1), read-only; null when off
        private S2AVoiceSlotDiag _s2aVoiceDiag;

        public unsafe Memory<byte> AllocateOwnedWorkBuffer(int size)
        {
            _ownedWorkBuffer = (byte*)System.Runtime.InteropServices.NativeMemory.AllocZeroed((nuint)Math.Max(size, 1));

            return new Ryujinx.Memory.NativeMemoryManager<byte>(_ownedWorkBuffer, size).Memory;
        }

        public unsafe void FreeOwnedWorkBuffer()
        {
            if (_ownedWorkBuffer != null)
            {
                System.Runtime.InteropServices.NativeMemory.Free(_ownedWorkBuffer);
                _ownedWorkBuffer = null;
            }
        }

        private Memory<float> _mixBuffer;
        private Memory<float> _depopBuffer;

        private uint _renderingTimeLimitPercent;
        private bool _voiceDropEnabled;
        private uint _voiceDropCount;
        private float _voiceDropParameter;
        private bool _isDspRunningBehind;

        private ICommandProcessingTimeEstimator _commandProcessingTimeEstimator;

        private Memory<byte> _performanceBuffer;

        public IVirtualMemoryManager MemoryManager { get; private set; }

        private ulong _elapsedFrameCount;
        private ulong _renderingStartTick;

        private readonly AudioRendererManager _manager;

        private int _disposeState;

        public AudioRenderSystem(AudioRendererManager manager, IWritableEvent systemEvent)
        {
            _manager = manager;
            _dspMemoryPoolInfo = MemoryPoolInfo.Create(MemoryPoolInfo.LocationType.Dsp);
            _voiceContext = new VoiceContext();
            _mixContext = new MixContext();
            _sinkContext = new SinkContext();
            _splitterContext = new SplitterContext();
            _effectContext = new EffectContext();

            _commandProcessingTimeEstimator = null;
            _systemEvent = systemEvent;
            _behaviourInfo = new BehaviourInfo();

            _totalElapsedTicksUpdating = 0;
            _sessionId = 0;
            _voiceDropParameter = 1.0f;
        }

        public ResultCode Initialize(
            ref AudioRendererConfiguration parameter,
            uint processHandle,
            Memory<byte> workBufferMemory,
            CpuAddress workBuffer,
            ulong workBufferSize,
            int sessionId,
            ulong appletResourceId,
            IVirtualMemoryManager memoryManager)
        {
            if (!BehaviourInfo.CheckValidRevision(parameter.Revision))
            {
                return ResultCode.OperationFailed;
            }

            if (GetWorkBufferSize(ref parameter) > workBufferSize)
            {
                return ResultCode.WorkBufferTooSmall;
            }

            Debug.Assert(parameter.RenderingDevice == AudioRendererRenderingDevice.Dsp && parameter.ExecutionMode == AudioRendererExecutionMode.Auto);

            Logger.Info?.Print(LogClass.AudioRenderer, $"Initializing with REV{BehaviourInfo.GetRevisionNumber(parameter.Revision)}");

            _behaviourInfo.SetUserRevision(parameter.Revision);

            _sampleRate = parameter.SampleRate;
            _sampleCount = parameter.SampleCount;
            _mixBufferCount = parameter.MixBufferCount;
            _voiceChannelCountMax = Constants.VoiceChannelCountMax;
            _upsamplerCount = parameter.SinkCount + parameter.SubMixBufferCount;
            _appletResourceId = appletResourceId;
            _memoryPoolCount = parameter.EffectCount + parameter.VoiceCount * Constants.VoiceWaveBufferCount;
            _renderingDevice = parameter.RenderingDevice;
            _executionMode = parameter.ExecutionMode;
            _sessionId = sessionId;
            MemoryManager = memoryManager;

            if (memoryManager is IRefCounted rc)
            {
                rc.IncrementReferenceCount();
            }

            WorkBufferAllocator workBufferAllocator;

            workBufferMemory.Span.Clear();
            _workBufferMemoryPin = workBufferMemory.Pin();

            workBufferAllocator = new WorkBufferAllocator(workBufferMemory);

            PoolMapper poolMapper = new(processHandle, false);
            poolMapper.InitializeSystemPool(ref _dspMemoryPoolInfo, workBuffer, workBufferSize);

            _mixBuffer = workBufferAllocator.Allocate<float>(_sampleCount * (_voiceChannelCountMax + _mixBufferCount), 0x10);

            if (_mixBuffer.IsEmpty)
            {
                return ResultCode.WorkBufferTooSmall;
            }

            Memory<float> upSamplerWorkBuffer = workBufferAllocator.Allocate<float>(Constants.TargetSampleCount * (_voiceChannelCountMax + _mixBufferCount) * _upsamplerCount, 0x10);

            if (upSamplerWorkBuffer.IsEmpty)
            {
                return ResultCode.WorkBufferTooSmall;
            }

            _depopBuffer = workBufferAllocator.Allocate<float>(BitUtils.AlignUp<ulong>(parameter.MixBufferCount, Constants.BufferAlignment), Constants.BufferAlignment);

            if (_depopBuffer.IsEmpty)
            {
                return ResultCode.WorkBufferTooSmall;
            }

            Memory<BiquadFilterState> splitterBqfStates = Memory<BiquadFilterState>.Empty;

            if (_behaviourInfo.IsBiquadFilterParameterForSplitterEnabled() &&
                parameter.SplitterCount > 0 &&
                parameter.SplitterDestinationCount > 0)
            {
                splitterBqfStates = workBufferAllocator.Allocate<BiquadFilterState>(parameter.SplitterDestinationCount * SplitterContext.BqfStatesPerDestination, 0x10);

                if (splitterBqfStates.IsEmpty)
                {
                    return ResultCode.WorkBufferTooSmall;
                }

                splitterBqfStates.Span.Clear();
            }

            // Invalidate DSP cache on what was currently allocated with workBuffer.
            AudioProcessorMemoryManager.InvalidateDspCache(_dspMemoryPoolInfo.Translate(workBuffer, workBufferAllocator.Offset), workBufferAllocator.Offset);

            Debug.Assert((workBufferAllocator.Offset % Constants.BufferAlignment) == 0);

            Memory<VoiceInfo> voices = workBufferAllocator.Allocate<VoiceInfo>(parameter.VoiceCount, VoiceInfo.Alignment);

            if (voices.IsEmpty)
            {
                return ResultCode.WorkBufferTooSmall;
            }

            foreach (ref VoiceInfo voice in voices.Span)
            {
                voice.Initialize();
            }

            // A pain to handle as we can't have VoiceInfo*, use indices to be a bit more safe
            Memory<int> sortedVoices = workBufferAllocator.Allocate<int>(parameter.VoiceCount, 0x10);

            if (sortedVoices.IsEmpty)
            {
                return ResultCode.WorkBufferTooSmall;
            }

            // Clear memory (use -1 as it's an invalid index)
            sortedVoices.Span.Fill(-1);

            Memory<VoiceChannelResource> voiceChannelResources = workBufferAllocator.Allocate<VoiceChannelResource>(parameter.VoiceCount, VoiceChannelResource.Alignment);

            if (voiceChannelResources.IsEmpty)
            {
                return ResultCode.WorkBufferTooSmall;
            }

            for (uint id = 0; id < voiceChannelResources.Length; id++)
            {
                ref VoiceChannelResource voiceChannelResource = ref voiceChannelResources.Span[(int)id];

                voiceChannelResource.Id = id;
                voiceChannelResource.IsUsed = false;
            }

            Memory<VoiceState> voiceStates = workBufferAllocator.Allocate<VoiceState>(parameter.VoiceCount, VoiceState.Align);

            if (voiceStates.IsEmpty)
            {
                return ResultCode.WorkBufferTooSmall;
            }

            uint mixesCount = parameter.SubMixBufferCount + 1;

            Memory<MixInfo> mixes = workBufferAllocator.Allocate<MixInfo>(mixesCount, MixInfo.Alignment);

            if (mixes.IsEmpty)
            {
                return ResultCode.WorkBufferTooSmall;
            }

            if (parameter.EffectCount == 0)
            {
                foreach (ref MixInfo mix in mixes.Span)
                {
                    mix = new MixInfo(Memory<int>.Empty, ref _behaviourInfo);
                }
            }
            else
            {
                Memory<int> effectProcessingOrderArray = workBufferAllocator.Allocate<int>(parameter.EffectCount * mixesCount, 0x10);

                foreach (ref MixInfo mix in mixes.Span)
                {
                    mix = new MixInfo(effectProcessingOrderArray[..(int)parameter.EffectCount], ref _behaviourInfo);

                    effectProcessingOrderArray = effectProcessingOrderArray[(int)parameter.EffectCount..];
                }
            }

            // Initialize the final mix id
            mixes.Span[0].MixId = Constants.FinalMixId;

            Memory<int> sortedMixesInfo = workBufferAllocator.Allocate<int>(mixesCount, 0x10);

            if (sortedMixesInfo.IsEmpty)
            {
                return ResultCode.WorkBufferTooSmall;
            }

            // Clear memory (use -1 as it's an invalid index)
            sortedMixesInfo.Span.Fill(-1);

            Memory<byte> nodeStatesWorkBuffer = Memory<byte>.Empty;
            Memory<byte> edgeMatrixWorkBuffer = Memory<byte>.Empty;

            if (_behaviourInfo.IsSplitterSupported())
            {
                nodeStatesWorkBuffer = workBufferAllocator.Allocate((uint)NodeStates.GetWorkBufferSize((int)mixesCount), 1);
                edgeMatrixWorkBuffer = workBufferAllocator.Allocate((uint)EdgeMatrix.GetWorkBufferSize((int)mixesCount), 1);

                if (nodeStatesWorkBuffer.IsEmpty || edgeMatrixWorkBuffer.IsEmpty)
                {
                    return ResultCode.WorkBufferTooSmall;
                }
            }

            _mixContext.Initialize(sortedMixesInfo, mixes, nodeStatesWorkBuffer, edgeMatrixWorkBuffer);

            _memoryPools = workBufferAllocator.Allocate<MemoryPoolInfo>(_memoryPoolCount, MemoryPoolInfo.Alignment);

            if (_memoryPools.IsEmpty)
            {
                return ResultCode.WorkBufferTooSmall;
            }

            foreach (ref MemoryPoolInfo info in _memoryPools.Span)
            {
                info = MemoryPoolInfo.Create(MemoryPoolInfo.LocationType.Cpu);
            }

            if (!_splitterContext.Initialize(ref _behaviourInfo, ref parameter, workBufferAllocator, splitterBqfStates))
            {
                return ResultCode.WorkBufferTooSmall;
            }

            _processHandle = processHandle;

            _upsamplerManager = new UpsamplerManager(upSamplerWorkBuffer, _upsamplerCount);

            _effectContext.Initialize(parameter.EffectCount, _behaviourInfo.IsEffectInfoVersion2Supported() ? parameter.EffectCount : 0);
            _sinkContext.Initialize(parameter.SinkCount);

            Memory<VoiceState> voiceStatesDsp = workBufferAllocator.Allocate<VoiceState>(parameter.VoiceCount, VoiceState.Align);

            if (voiceStatesDsp.IsEmpty)
            {
                return ResultCode.WorkBufferTooSmall;
            }

            _voiceContext.Initialize(sortedVoices, voices, voiceChannelResources, voiceStates, voiceStatesDsp, parameter.VoiceCount);

            _s2aVoiceDiag = S2AVoiceSlotDiag.On ? new S2AVoiceSlotDiag(parameter.VoiceCount) : null;

            if (parameter.PerformanceMetricFramesCount > 0)
            {
                ulong performanceBufferSize = PerformanceManager.GetRequiredBufferSizeForPerformanceMetricsPerFrame(ref parameter, ref _behaviourInfo) * (parameter.PerformanceMetricFramesCount + 1) + 0xC;

                _performanceBuffer = workBufferAllocator.Allocate(performanceBufferSize, Constants.BufferAlignment);

                if (_performanceBuffer.IsEmpty)
                {
                    return ResultCode.WorkBufferTooSmall;
                }

                _performanceManager = PerformanceManager.Create(_performanceBuffer, ref parameter, _behaviourInfo);
            }
            else
            {
                _performanceManager = null;
            }

            _totalElapsedTicksUpdating = 0;
            _totalElapsedTicks = 0;
            _renderingTimeLimitPercent = 100;
            _voiceDropEnabled = parameter.VoiceDropEnabled && _executionMode == AudioRendererExecutionMode.Auto;

            AudioProcessorMemoryManager.InvalidateDataCache(workBuffer, workBufferSize);

            _processHandle = processHandle;
            _elapsedFrameCount = 0;
            _voiceDropParameter = 1.0f;

            _commandProcessingTimeEstimator = _behaviourInfo.GetCommandProcessingTimeEstimatorVersion() switch
            {
                1 => new CommandProcessingTimeEstimatorVersion1(_sampleCount, _mixBufferCount),
                2 => new CommandProcessingTimeEstimatorVersion2(_sampleCount, _mixBufferCount),
                3 => new CommandProcessingTimeEstimatorVersion3(_sampleCount, _mixBufferCount),
                4 => new CommandProcessingTimeEstimatorVersion4(_sampleCount, _mixBufferCount),
                5 => new CommandProcessingTimeEstimatorVersion5(_sampleCount, _mixBufferCount),
                _ => throw new NotImplementedException($"Unsupported processing time estimator version {_behaviourInfo.GetCommandProcessingTimeEstimatorVersion()}."),
            };

            return ResultCode.Success;
        }

        public void Start()
        {
            Logger.Info?.Print(LogClass.AudioRenderer, $"Starting renderer id {_sessionId}");

            lock (_lock)
            {
                _elapsedFrameCount = 0;
                _isActive = true;
            }
        }

        public void Stop()
        {
            Logger.Info?.Print(LogClass.AudioRenderer, $"Stopping renderer id {_sessionId}");

            lock (_lock)
            {
                _isActive = false;
            }

            Logger.Info?.Print(LogClass.AudioRenderer, $"Stopped renderer id {_sessionId}");
        }

        public void Disable()
        {
            lock (_lock)
            {
                _isActive = false;
            }
        }

        // S2Arm (11-13 断音): the render loop and the game's RequestUpdate share _lock. Longest hold by Update since the render loop last
        //   read it, and how long the render loop waited for the lock (AudioRendererManager logs both when a period runs long)
        public static long S2AUpdateHoldMaxTicks;
        public static long S2ARenderLockWaitTicks;

        public ResultCode Update(Memory<byte> output, Memory<byte> performanceOutput, ReadOnlySequence<byte> input)
        {
            lock (_lock)
            {
                long s2aHeld = System.Diagnostics.Stopwatch.GetTimestamp();

                try
                {
                    return S2AUpdateLocked(output, performanceOutput, input);
                }
                finally
                {
                    s2aHeld = System.Diagnostics.Stopwatch.GetTimestamp() - s2aHeld;

                    if (s2aHeld > Volatile.Read(ref S2AUpdateHoldMaxTicks))
                    {
                        Volatile.Write(ref S2AUpdateHoldMaxTicks, s2aHeld);
                    }
                }
            }
        }

        private ResultCode S2AUpdateLocked(Memory<byte> output, Memory<byte> performanceOutput, ReadOnlySequence<byte> input)
        {
            {
                ulong updateStartTicks = GetSystemTicks();

                output.Span.Clear();

                StateUpdater stateUpdater = new(input, output, _processHandle, _behaviourInfo);

                ResultCode result;

                result = stateUpdater.UpdateBehaviourInfo();

                if (result != ResultCode.Success)
                {
                    return result;
                }

                result = stateUpdater.UpdateMemoryPools(_memoryPools.Span, GetMemoryPoolStateMapper());

                if (result != ResultCode.Success)
                {
                    return result;
                }

                result = stateUpdater.UpdateVoiceChannelResources(_voiceContext);

                if (result != ResultCode.Success)
                {
                    return result;
                }

                PoolMapper poolMapper = GetUpdatePoolMapper();

                if (_behaviourInfo.IsBiquadFilterParameterFloatSupported())
                {
                    result = stateUpdater.UpdateVoices2(_voiceContext, poolMapper);
                }
                else
                {
                    result = stateUpdater.UpdateVoices1(_voiceContext, poolMapper);
                }

                if (result != ResultCode.Success)
                {
                    return result;
                }

                if (_s2aVoiceDiag != null)
                {
                    string line = _s2aVoiceDiag.Observe(_voiceContext, _manager.TickSource.ElapsedSeconds, _sessionId);

                    if (line != null)
                    {
                        Console.Error.WriteLine(line);
                    }
                }

                result = stateUpdater.UpdateEffects(_effectContext, _isActive, poolMapper);

                if (result != ResultCode.Success)
                {
                    return result;
                }

                if (_behaviourInfo.IsSplitterSupported())
                {
                    result = stateUpdater.UpdateSplitter(_splitterContext);

                    if (result != ResultCode.Success)
                    {
                        return result;
                    }
                }

                result = stateUpdater.UpdateMixes(_mixContext, GetMixBufferCount(), _effectContext, _splitterContext);

                if (result != ResultCode.Success)
                {
                    return result;
                }

                result = stateUpdater.UpdateSinks(_sinkContext, poolMapper);

                if (result != ResultCode.Success)
                {
                    return result;
                }

                result = stateUpdater.UpdatePerformanceBuffer(_performanceManager, performanceOutput.Span);

                if (result != ResultCode.Success)
                {
                    return result;
                }

                result = stateUpdater.UpdateErrorInfo();

                if (result != ResultCode.Success)
                {
                    return result;
                }

                if (_behaviourInfo.IsElapsedFrameCountSupported())
                {
                    result = stateUpdater.UpdateRendererInfo(_elapsedFrameCount);

                    if (result != ResultCode.Success)
                    {
                        return result;
                    }
                }

                result = stateUpdater.CheckConsumedSize();

                if (result != ResultCode.Success)
                {
                    return result;
                }

                _systemEvent.Clear();

                ulong updateEndTicks = GetSystemTicks();

                _totalElapsedTicksUpdating += (updateEndTicks - updateStartTicks);

                return result;
            }
        }

        private ulong GetSystemTicks()
        {
            return (ulong)(_manager.TickSource.ElapsedSeconds * Constants.TargetTimerFrequency);
        }

        private uint ComputeVoiceDrop(CommandBuffer commandBuffer, uint voicesEstimatedTime, long deltaTimeDsp)
        {
            int i;

            for (i = 0; i < commandBuffer.CommandList.Commands.Count; i++)
            {
                ICommand command = commandBuffer.CommandList.Commands[i];

                CommandType commandType = command.CommandType;

                if (commandType is CommandType.AdpcmDataSourceVersion1 or
                    CommandType.AdpcmDataSourceVersion2 or
                    CommandType.PcmInt16DataSourceVersion1 or
                    CommandType.PcmInt16DataSourceVersion2 or
                    CommandType.PcmFloatDataSourceVersion1 or
                    CommandType.PcmFloatDataSourceVersion2 or
                    CommandType.Performance)
                {
                    break;
                }
            }

            uint voiceDropped = 0;

            for (; i < commandBuffer.CommandList.Commands.Count; i++)
            {
                ICommand targetCommand = commandBuffer.CommandList.Commands[i];

                int targetNodeId = targetCommand.NodeId;

                if (voicesEstimatedTime <= deltaTimeDsp || NodeIdHelper.GetType(targetNodeId) != NodeIdType.Voice)
                {
                    break;
                }

                ref VoiceInfo voice = ref _voiceContext.GetState(NodeIdHelper.GetBase(targetNodeId));

                if (voice.Priority == Constants.VoiceHighestPriority)
                {
                    break;
                }

                // We can safely drop this voice, disable all associated commands while activating depop preparation commands.
                voiceDropped++;
                voice.VoiceDropFlag = true;

                Logger.Warning?.Print(LogClass.AudioRenderer, $"Dropping voice {voice.NodeId}");

                for (; i < commandBuffer.CommandList.Commands.Count; i++)
                {
                    ICommand command = commandBuffer.CommandList.Commands[i];

                    if (command.NodeId != targetNodeId)
                    {
                        break;
                    }

                    if (command.CommandType == CommandType.DepopPrepare)
                    {
                        command.Enabled = true;
                    }
                    else if (command.CommandType == CommandType.Performance || !command.Enabled)
                    {
                        continue;
                    }
                    else
                    {
                        command.Enabled = false;

                        voicesEstimatedTime -= (uint)(_voiceDropParameter * command.EstimatedProcessingTime);
                    }
                }
            }

            return voiceDropped;
        }

        private void GenerateCommandList(out CommandList commandList)
        {
            Debug.Assert(_executionMode == AudioRendererExecutionMode.Auto);

            PoolMapper.ClearUsageState(_memoryPools);

            ulong startTicks = GetSystemTicks();

            // S2Arm: command list / buffer / generator / context reused per render system (zero steady-state allocation)
            commandList = CommandList.S2ARent(this, _s2aCommandLists);

            if (_performanceManager != null)
            {
                _performanceManager.TapFrame(_isDspRunningBehind, _voiceDropCount, _renderingStartTick);

                _isDspRunningBehind = false;
                _voiceDropCount = 0;
                _renderingStartTick = 0;
            }

            CommandBuffer commandBuffer = _s2aCommandBuffer ??= new CommandBuffer(commandList, _commandProcessingTimeEstimator);
            commandBuffer.S2AReset(commandList);

            CommandGenerator commandGenerator;

            if (_s2aCommandGenerator == null)
            {
                commandGenerator = _s2aCommandGenerator = new CommandGenerator(commandBuffer, GetContext(), _voiceContext, _mixContext, _effectContext, _sinkContext, _splitterContext, _performanceManager);
            }
            else
            {
                commandGenerator = _s2aCommandGenerator;
                commandGenerator.S2AReset(commandBuffer, GetContext());
            }

            _voiceContext.Sort();
            commandGenerator.GenerateVoices();

            uint voicesEstimatedTime = (uint)(_voiceDropParameter * commandBuffer.EstimatedProcessingTime);

            commandGenerator.GenerateSubMixes();
            commandGenerator.GenerateFinalMixes();
            commandGenerator.GenerateSinks();

            uint totalEstimatedTime = (uint)(_voiceDropParameter * commandBuffer.EstimatedProcessingTime);

            if (_voiceDropEnabled)
            {
                long maxDspTime = GetMaxAllocatedTimeForDsp();

                long restEstimateTime = totalEstimatedTime - voicesEstimatedTime;

                long deltaTimeDsp = Math.Max(maxDspTime - restEstimateTime, 0);

                _voiceDropCount = ComputeVoiceDrop(commandBuffer, voicesEstimatedTime, deltaTimeDsp);
            }

            _voiceContext.UpdateForCommandGeneration();

            if (_behaviourInfo.IsEffectInfoVersion2Supported())
            {
                _effectContext.UpdateResultStateForCommandGeneration();
            }

            ulong endTicks = GetSystemTicks();

            _totalElapsedTicks = endTicks - startTicks;

            _renderingStartTick = GetSystemTicks();
            _elapsedFrameCount++;
        }

        private int GetMaxAllocatedTimeForDsp()
        {
            return (int)(Constants.AudioProcessorMaxUpdateTimePerSessions * _behaviourInfo.GetAudioRendererProcessingTimeLimit() * (GetRenderingTimeLimit() / 100.0f));
        }

        public void SendCommands()
        {
            long s2aWait = System.Diagnostics.Stopwatch.GetTimestamp();

            lock (_lock)
            {
                S2ARenderLockWaitTicks += System.Diagnostics.Stopwatch.GetTimestamp() - s2aWait;   // render loop thread only

                if (_isActive)
                {
                    if (!_manager.Processor.HasRemainingCommands(_sessionId))
                    {
                        GenerateCommandList(out CommandList commands);

                        _manager.Processor.Send(_sessionId,
                                                commands,
                                                GetMaxAllocatedTimeForDsp(),
                                                _appletResourceId);

                        _systemEvent.Signal();
                    }
                    else
                    {
                        _isDspRunningBehind = true;
                    }
                }
            }
        }

        public uint GetMixBufferCount()
        {
            return _mixBufferCount;
        }

        public void SetRenderingTimeLimitPercent(uint percent)
        {
            Debug.Assert(percent <= 100);

            _renderingTimeLimitPercent = percent;
        }

        public uint GetRenderingTimeLimit()
        {
            return _renderingTimeLimitPercent;
        }

        public Memory<float> GetMixBuffer()
        {
            return _mixBuffer;
        }

        public uint GetSampleCount()
        {
            return _sampleCount;
        }

        public uint GetSampleRate()
        {
            return _sampleRate;
        }

        public uint GetVoiceChannelCountMax()
        {
            return _voiceChannelCountMax;
        }

        public bool IsActive()
        {
            return _isActive;
        }

        private RendererSystemContext GetContext()
        {
            // S2Arm: one context per render system, refreshed every frame (the channel count follows the output device)
            RendererSystemContext context = _s2aContext ??= new RendererSystemContext();

            context.ChannelCount = _manager.Processor.OutputDevices[_sessionId].GetChannelCount();
            context.BehaviourInfo = _behaviourInfo;
            context.DepopBuffer = _depopBuffer;
            context.MixBufferCount = GetMixBufferCount();
            context.SessionId = _sessionId;
            context.UpsamplerManager = _upsamplerManager;

            return context;
        }

        private readonly System.Collections.Generic.Stack<CommandList> _s2aCommandLists = new();
        private CommandBuffer _s2aCommandBuffer;

        // S2Arm: PoolMapper is immutable; reuse it while its inputs are unchanged (was a new one per RequestUpdate, several per frame)
        private PoolMapper _s2aUpdateMapper;
        private uint _s2aUpdateMapperHandle;
        private Memory<MemoryPoolInfo> _s2aUpdateMapperPools;
        private bool _s2aUpdateMapperForce;

        private PoolMapper _s2aPoolStateMapper;
        private uint _s2aPoolStateMapperHandle;
        private bool _s2aPoolStateMapperForce;

        // Same as StateUpdater's former new PoolMapper(processHandle, force) (no memory pool list)
        private PoolMapper GetMemoryPoolStateMapper()
        {
            bool force = _behaviourInfo.IsMemoryPoolForceMappingEnabled();

            if (_s2aPoolStateMapper == null || _s2aPoolStateMapperHandle != _processHandle || _s2aPoolStateMapperForce != force)
            {
                _s2aPoolStateMapper = new PoolMapper(_processHandle, force);
                _s2aPoolStateMapperHandle = _processHandle;
                _s2aPoolStateMapperForce = force;
            }

            return _s2aPoolStateMapper;
        }

        private PoolMapper GetUpdatePoolMapper()
        {
            bool force = _behaviourInfo.IsMemoryPoolForceMappingEnabled();

            if (_s2aUpdateMapper == null || _s2aUpdateMapperHandle != _processHandle || !_s2aUpdateMapperPools.Equals(_memoryPools) || _s2aUpdateMapperForce != force)
            {
                _s2aUpdateMapper = new PoolMapper(_processHandle, _memoryPools, force);
                _s2aUpdateMapperHandle = _processHandle;
                _s2aUpdateMapperPools = _memoryPools;
                _s2aUpdateMapperForce = force;
            }

            return _s2aUpdateMapper;
        }
        private CommandGenerator _s2aCommandGenerator;
        private RendererSystemContext _s2aContext;

        public int GetSessionId()
        {
            return _sessionId;
        }

        public static ulong GetWorkBufferSize(ref AudioRendererConfiguration parameter)
        {
            BehaviourInfo behaviourInfo = new();

            behaviourInfo.SetUserRevision(parameter.Revision);

            uint mixesCount = parameter.SubMixBufferCount + 1;

            uint memoryPoolCount = parameter.EffectCount + parameter.VoiceCount * Constants.VoiceWaveBufferCount;

            ulong size = 0;

            // Mix Buffers
            size = WorkBufferAllocator.GetTargetSize<float>(size, parameter.SampleCount * (Constants.VoiceChannelCountMax + parameter.MixBufferCount), 0x10);

            // Upsampler workbuffer
            size = WorkBufferAllocator.GetTargetSize<float>(size, Constants.TargetSampleCount * (Constants.VoiceChannelCountMax + parameter.MixBufferCount) * (parameter.SinkCount + parameter.SubMixBufferCount), 0x10);

            // Depop buffer
            size = WorkBufferAllocator.GetTargetSize<float>(size, BitUtils.AlignUp<ulong>(parameter.MixBufferCount, Constants.BufferAlignment), Constants.BufferAlignment);

            // Voice
            size = WorkBufferAllocator.GetTargetSize<VoiceInfo>(size, parameter.VoiceCount, VoiceInfo.Alignment);
            size = WorkBufferAllocator.GetTargetSize<int>(size, parameter.VoiceCount, 0x10);
            size = WorkBufferAllocator.GetTargetSize<VoiceChannelResource>(size, parameter.VoiceCount, VoiceChannelResource.Alignment);
            size = WorkBufferAllocator.GetTargetSize<VoiceState>(size, parameter.VoiceCount, VoiceState.Align);

            // Mix
            size = WorkBufferAllocator.GetTargetSize<MixInfo>(size, mixesCount, MixInfo.Alignment);
            size = WorkBufferAllocator.GetTargetSize<int>(size, parameter.EffectCount * mixesCount, 0x10);
            size = WorkBufferAllocator.GetTargetSize<int>(size, mixesCount, 0x10);

            if (behaviourInfo.IsSplitterSupported())
            {
                size += (ulong)BitUtils.AlignUp(NodeStates.GetWorkBufferSize((int)mixesCount) + EdgeMatrix.GetWorkBufferSize((int)mixesCount), 0x10);
            }

            // Memory Pool
            size = WorkBufferAllocator.GetTargetSize<MemoryPoolInfo>(size, memoryPoolCount, MemoryPoolInfo.Alignment);

            // Splitter
            size = SplitterContext.GetWorkBufferSize(size, ref behaviourInfo, ref parameter);

            if (behaviourInfo.IsBiquadFilterParameterForSplitterEnabled() &&
                parameter.SplitterCount > 0 &&
                parameter.SplitterDestinationCount > 0)
            {
                size = WorkBufferAllocator.GetTargetSize<BiquadFilterState>(size, parameter.SplitterDestinationCount * SplitterContext.BqfStatesPerDestination, 0x10);
            }

            // DSP Voice
            size = WorkBufferAllocator.GetTargetSize<VoiceState>(size, parameter.VoiceCount, VoiceState.Align);

            // Performance
            if (parameter.PerformanceMetricFramesCount > 0)
            {
                ulong performanceMetricsPerFramesSize = PerformanceManager.GetRequiredBufferSizeForPerformanceMetricsPerFrame(ref parameter, ref behaviourInfo) * (parameter.PerformanceMetricFramesCount + 1) + 0xC;

                size += BitUtils.AlignUp<ulong>(performanceMetricsPerFramesSize, Constants.PerformanceMetricsPerFramesSizeAlignment);
            }

            return BitUtils.AlignUp<ulong>(size, Constants.WorkBufferAlignment);
        }

        public ResultCode QuerySystemEvent(out IWritableEvent systemEvent)
        {
            systemEvent = default;

            if (_executionMode == AudioRendererExecutionMode.Manual)
            {
                return ResultCode.UnsupportedOperation;
            }

            systemEvent = _systemEvent;

            return ResultCode.Success;
        }

        public void Dispose()
        {
            GC.SuppressFinalize(this);

            if (Interlocked.CompareExchange(ref _disposeState, 1, 0) == 0)
            {
                Dispose(true);
            }
        }

        protected virtual void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (_isActive)
                {
                    Stop();
                }

                PoolMapper mapper = new(_processHandle, false);
                mapper.Unmap(ref _dspMemoryPoolInfo);

                PoolMapper.ClearUsageState(_memoryPools);

                for (int i = 0; i < _memoryPoolCount; i++)
                {
                    ref MemoryPoolInfo memoryPool = ref _memoryPools.Span[i];

                    if (memoryPool.IsMapped())
                    {
                        mapper.Unmap(ref memoryPool);
                    }
                }

                _manager.Unregister(this);
                _workBufferMemoryPin.Dispose();
                FreeOwnedWorkBuffer();

                if (MemoryManager is IRefCounted rc)
                {
                    rc.DecrementReferenceCount();

                    MemoryManager = null;
                }
            }
        }

        public void SetVoiceDropParameter(float voiceDropParameter)
        {
            _voiceDropParameter = Math.Clamp(voiceDropParameter, 0.0f, 4.0f);
        }

        public float GetVoiceDropParameter()
        {
            return _voiceDropParameter;
        }

        public ResultCode ExecuteAudioRendererRendering()
        {
            if (_executionMode == AudioRendererExecutionMode.Manual && _renderingDevice == AudioRendererRenderingDevice.Cpu)
            {
                // NOTE: Here Nintendo aborts with this error code, we don't want that.
                return ResultCode.InvalidExecutionContextOperation;
            }

            return ResultCode.UnsupportedOperation;
        }
    }
}
