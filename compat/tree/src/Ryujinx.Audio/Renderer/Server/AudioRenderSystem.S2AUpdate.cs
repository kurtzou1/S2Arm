using Ryujinx.Audio.Common;
using Ryujinx.Audio.Renderer.Common;
using Ryujinx.Audio.Renderer.Parameter;
using Ryujinx.Audio.Renderer.Parameter.Performance;
using Ryujinx.Audio.Renderer.Server.Effect;
using Ryujinx.Audio.Renderer.Server.MemoryPool;
using Ryujinx.Audio.Renderer.Server.Sink;
using Ryujinx.Audio.Renderer.Server.Voice;
using Ryujinx.Audio.Renderer.Utils;
using Ryujinx.Common.Extensions;
using Ryujinx.Common.Logging;
using Ryujinx.Common.Memory;
using System;
using System.Buffers;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using static Ryujinx.Audio.Renderer.Common.BehaviourParameter;
using WaveBuffer = Ryujinx.Audio.Renderer.Server.Voice.WaveBuffer;

namespace Ryujinx.Audio.Renderer.Server
{
    // S2Arm (#12/#13 拆分 · 维护方 #12 主方向「渲染这一拍不等游戏 Update 的锁」): Update 拆分的驱动部分。
    //   状态载体见 S2AUpdateShadow(一份影子,一次构建、每更新复用);流程:锁1 快照(shadow.SnapshotFromLive,
    //   在 AudioRenderSystem.Update 里)→ 解析段(本文件 S2AParseLocked,锁外,StateUpdater 各段跑在影子上)→
    //   锁2a 落账(本文件 S2ACommitLocked,锁内)。
    //
    //   波表槽的处方(独立复审第二轮的三条修正,逐条落实):
    //   ① 重演基底 = 锁1 快照里的该波表(含旧地址与旧 IsSendToAudioProcessor),对该基底重跑 isValid 分支与重发分支
    //      两者,产出整体替换该波表的解析段结果(VoiceInfo.S2AUpdateWaveBuffer 纯核,锁外解析与锁内重演共用);
    //   ② 该波表的 hook 槽按今天时序接序为 [Unmap(A_old) → Map×2(A_new)](强制映射路径本样双 Map,
    //      PoolMapper.AssignDspAddress),不是单条覆写——重演的 Unmap 立即执行、排在解析段记的重发 Map 重放之前,
    //      重演里的重发挂接抑制 hook(否则双倍);
    //   ③ 解析段的重发错误不直接进活队列,按 (voiceId,波表) 暂存,锁2a 复核(翻或不翻)后每槽恰一次按原序
    //      AppendError(重演与解析段同输入同基底、错误同一条,落账从暂存表入队恰一次)。
    //
    //   段失败语义(今天的「前置阶段已落账的结果必须先落、再按错误返回」):ParseStop 记落账走到第几段;池/资源/
    //   分频/混音四段失败时该段也整段落账——段内未跑到的部分影子=锁1 活值快照,而这些段除拍写字段(IsUsed/
    //   PreviousMix/目的地拍写位)外没有拍写侧,整段落账与今天的前缀语义一致;行为/声音/效果/汇段失败时该段不落账
    //   (今天的段失败都发生在段首校验、无中段改动)。收尾段的消费核算失败也只跳过事件清除,其余照落(今天同)。
    public partial class AudioRenderSystem
    {
        // S2Arm (#12/#13 拆分): 影子载体与工作件(一次建,每更新复用;错误暂存表上限与 BehaviourInfo.AppendError 一致)
        private S2AUpdateShadow _s2aUpdateShadow;
        private readonly List<ErrorInfo> _s2aWaveErrorList = new(Constants.VoiceWaveBufferCount * 2);
        private readonly List<ErrorInfo> _s2aReplayErrorList = new(Constants.VoiceWaveBufferCount * 2);
        private readonly ErrorInfo[] _s2aErrorScratch = new ErrorInfo[Constants.MaxErrorInfos];

        // S2Arm (#12/#13 拆分): 影子解析用的两个 mapper(挂接 hook 走日志、池解析在影子池表上;缓存口径同 live 侧那两个)
        private PoolMapper _s2aShadowPoolStateMapper;
        private uint _s2aShadowPoolStateMapperHandle;
        private bool _s2aShadowPoolStateMapperForce;

        private PoolMapper _s2aShadowUpdateMapper;
        private uint _s2aShadowUpdateMapperHandle;
        private bool _s2aShadowUpdateMapperForce;

        private S2AUpdateShadow S2AEnsureUpdateShadow()
        {
            if (_s2aUpdateShadow != null)
            {
                return _s2aUpdateShadow;
            }

            // hook 日志容量按段结构推上界:池段(每池至多一挂一解)+ 声音段(每声:数据源状态 1 + 四波表各(本体+ADPCM
            // 上下文)各双 Map,强制映射)+ 效果段(每效:重置两工缓 + 一挂)+ 汇段,另加余量
            int voiceCount = (int)_voiceContext.GetCount();
            int hookCapacity = (int)_memoryPoolCount * 2
                + voiceCount * (1 + Constants.VoiceWaveBufferCount * 2) * 2 + 16
                + (int)_effectContext.S2ACount * 4
                + (int)_sinkContext.GetCount() * 4 + 16;

            _s2aUpdateShadow = new S2AUpdateShadow(
                _processHandle,
                _memoryPools,
                _voiceContext,
                _effectContext,
                _sinkContext,
                _splitterContext,
                _mixContext,
                (int)_memoryPoolCount,
                voiceCount,
                (int)_effectContext.S2ACount,
                _behaviourInfo.IsEffectInfoVersion2Supported() ? (int)_effectContext.S2ACount : 0,
                (int)_sinkContext.GetCount(),
                (int)_mixContext.GetCount(),
                hookCapacity);

            return _s2aUpdateShadow;
        }

        private PoolMapper S2AGetShadowPoolStateMapper(S2AUpdateShadow shadow)
        {
            bool force = shadow.ParseBehaviour.IsMemoryPoolForceMappingEnabled();

            if (_s2aShadowPoolStateMapper == null || _s2aShadowPoolStateMapperHandle != _processHandle || _s2aShadowPoolStateMapperForce != force)
            {
                _s2aShadowPoolStateMapper = new PoolMapper(_processHandle, force);
                _s2aShadowPoolStateMapperHandle = _processHandle;
                _s2aShadowPoolStateMapperForce = force;
            }

            _s2aShadowPoolStateMapper.S2ALog = shadow.HookLog;

            return _s2aShadowPoolStateMapper;
        }

        private PoolMapper S2AGetShadowUpdateMapper(S2AUpdateShadow shadow)
        {
            bool force = shadow.ParseBehaviour.IsMemoryPoolForceMappingEnabled();

            if (_s2aShadowUpdateMapper == null || _s2aShadowUpdateMapperHandle != _processHandle || _s2aShadowUpdateMapperForce != force)
            {
                // 池表 = 影子池表(S2AUpdateShadow 的原生块,固定不动,缓存实例的池表一直有效)
                _s2aShadowUpdateMapper = new PoolMapper(_processHandle, shadow.ShadowPoolsSpan.Length != 0 ? shadow.ShadowPoolsMemory : Memory<MemoryPoolInfo>.Empty, force);
                _s2aShadowUpdateMapperHandle = _processHandle;
                _s2aShadowUpdateMapperForce = force;
            }

            _s2aShadowUpdateMapper.S2ALog = shadow.HookLog;

            return _s2aShadowUpdateMapper;
        }

        // ---------- 解析段(锁外)----------
        private ResultCode S2AParseLocked(Memory<byte> output, Memory<byte> performanceOutput, ReadOnlySequence<byte> input, S2AUpdateShadow shadow)
        {
            // S2Arm (#12/#13 相位插桩): 各段耗时进 _s2aPhaseTicks(段尾一记拍表针,相邻段共用边界针;计时本身零堆分配)。
            //   拆分后 0..7 各段计在锁外解析段上(画像含义不变:解析花在哪一段),8=落账(在 Update 里记);失败提前
            //   返回时,出错段与其后的段保持 0
            _s2aPhaseTicks.AsSpan().Clear();
            long s2aPhaseT = System.Diagnostics.Stopwatch.GetTimestamp();

            void S2AMark(int phase)
            {
                long now = System.Diagnostics.Stopwatch.GetTimestamp();
                _s2aPhaseTicks[phase] += now - s2aPhaseT;
                s2aPhaseT = now;
            }

            StateUpdater stateUpdater = new(input, output, _processHandle, shadow.ParseBehaviour);

            // 输入头的段尺寸(驱动要用;取值拷贝——GetRefOrRefToCopy 的引用会被后续读取覆盖)
            SequenceReader<byte> headerReader = new(input);
            UpdateDataHeader headerSizes = headerReader.GetRefOrRefToCopy<UpdateDataHeader>(out _);

            shadow.PoolsHookStart = shadow.HookLog.Count;

            ResultCode result = stateUpdater.UpdateBehaviourInfo();

            if (result != ResultCode.Success)
            {
                shadow.ParseResult = result;
                shadow.ParseStop = 0;
                return result;
            }

            shadow.ParseStop = 1;

            // 内存池段走驱动(与今天 UpdateMemoryPools 逐行同体):逐池记 hook 起点(落账 detach 复核要用,终审 mustFix 4)
            SequenceReader<byte> poolsReader = stateUpdater.S2AInputReader;
            Memory<byte> poolsOutCursor = stateUpdater.S2AOutput;
            ref UpdateDataHeader poolsOutHeader = ref stateUpdater.S2AOutputHeader;

            result = S2AParseMemoryPools(
                ref poolsReader,
                ref poolsOutCursor,
                shadow.ShadowPoolsSpan,
                shadow.PoolHookStart,
                S2AGetShadowPoolStateMapper(shadow),
                shadow.HookLog,
                in headerSizes,
                ref poolsOutHeader);

            stateUpdater.S2ASetInputReader(poolsReader);
            stateUpdater.S2ASetOutput(poolsOutCursor);

            if (result != ResultCode.Success)
            {
                // 池段失败:影子已跑部分=前缀,未跑部分=锁1 活值快照——池表除 IsUsed(落账保留活值)外没有拍写侧,
                // 整段落账与今天的前缀语义一致
                shadow.ParseResult = result;
                shadow.ParseStop = 2;
                return result;
            }

            shadow.ParseStop = 2;
            S2AMark(0);   // 行为+内存池

            // 声音段的 hook 日志起点(池段钩区间的终点;此前只赋了池/效果/汇三段标——声音段标漏赋会让池段
            // 钩重放变空区间、池段驻留钩全部丢失,终审 mustFix 1)
            shadow.VoicesHookStart = shadow.HookLog.Count;

            result = stateUpdater.UpdateVoiceChannelResources(shadow.VoiceContext);

            if (result != ResultCode.Success)
            {
                shadow.ParseResult = result;
                shadow.ParseStop = 3;
                return result;
            }

            shadow.ParseStop = 3;
            S2AMark(1);   // 声道资源

            result = S2AParseVoices(ref stateUpdater, shadow, in headerSizes);

            if (result != ResultCode.Success)
            {
                return result;   // ParseStop 已由 S2AParseVoices 定(=3,失败在段首校验、影子未动)
            }

            S2AMark(2);   // 声音(解析段:纯包解析+影子写入+挂接解析)

            shadow.EffectsHookStart = shadow.HookLog.Count;

            result = stateUpdater.UpdateEffects(shadow.EffectContext, shadow.IsActiveSnapshot, S2AGetShadowUpdateMapper(shadow));

            if (result != ResultCode.Success)
            {
                shadow.ParseResult = result;
                shadow.ParseStop = 4;
                return result;
            }

            // 效果段 IsNew 逐条扫输入(落账对 live 重放 InitializeResultState——它在解析段写在影子的结果态拷贝上,丢弃)
            S2AScanEffectIsNew(input, shadow, in headerSizes);

            shadow.ParseStop = 5;
            S2AMark(3);   // 效果

            if (shadow.ParseBehaviour.IsSplitterSupported())
            {
                result = stateUpdater.UpdateSplitter(shadow.SplitterContext);

                if (result != ResultCode.Success)
                {
                    // 分频段失败:同池段——未跑部分影子=活值快照,分频器结构体与目的地游戏字段没有拍写侧,整段落账同今天
                    shadow.ParseResult = result;
                    shadow.ParseStop = 6;
                    return result;
                }
            }

            shadow.ParseStop = 6;
            S2AMark(4);   // 分频

            result = stateUpdater.UpdateMixes(shadow.MixContext, GetMixBufferCount(), shadow.EffectContext, shadow.SplitterContext);

            if (result != ResultCode.Success)
            {
                // 混音段失败(含排序失败):混音结构/排序索引/邻接矩阵没有拍写侧,整段落账同今天的前缀语义
                shadow.ParseResult = result;
                shadow.ParseStop = 7;
                return result;
            }

            shadow.ParseStop = 7;
            S2AMark(5);   // 混音

            shadow.SinksHookStart = shadow.HookLog.Count;

            result = stateUpdater.UpdateSinks(shadow.SinkContext, S2AGetShadowUpdateMapper(shadow));

            if (result != ResultCode.Success)
            {
                shadow.ParseResult = result;
                shadow.ParseStop = 7;
                return result;
            }

            shadow.ParseStop = 8;
            S2AMark(6);   // 汇

            // 收尾:性能缓冲。读史(PerformanceManager 的历史渲染调度线程也在写——今天 Update 在锁内读、DSP 在锁外写,
            // 本就同型竞态,锁外解析读不引入新竞态);目标节点的 SetTargetNodeId 延后落账执行(它是拍读字段,中拍读
            // 旧值 = 「Update 在落账点串行」的今天语义)
            if (Unsafe.SizeOf<PerformanceInParameter>() != headerSizes.PerformanceBufferSize)
            {
                shadow.ParseResult = ResultCode.InvalidUpdateInfo;
                shadow.ParseStop = 8;
                return shadow.ParseResult;
            }

            SequenceReader<byte> reader = stateUpdater.S2AInputReader;
            Memory<byte> outCursor = stateUpdater.S2AOutput;

            ref readonly PerformanceInParameter perfParameter = ref reader.GetRefOrRefToCopy<PerformanceInParameter>(out _);

            ref PerformanceOutStatus perfOutStatus = ref SpanIOHelper.GetWriteRef<PerformanceOutStatus>(ref outCursor)[0];

            if (_performanceManager != null)
            {
                perfOutStatus.HistorySize = _performanceManager.CopyHistories(performanceOutput.Span);

                shadow.PerfTargetNodeId = perfParameter.TargetNodeId;
                shadow.PerfManagerPresent = true;
            }
            else
            {
                perfOutStatus.HistorySize = 0;
                shadow.PerfManagerPresent = false;
            }

            ref UpdateDataHeader outHeader = ref stateUpdater.S2AOutputHeader;

            outHeader.PerformanceBufferSize = (uint)Unsafe.SizeOf<PerformanceOutStatus>();
            outHeader.TotalSize += outHeader.PerformanceBufferSize;

            // 错误段/信息段的位置(落账写入)与消费口径记录(落账核算)
            shadow.ErrorOutOffset = output.Length - outCursor.Length;
            shadow.RendererInfoOutOffset = shadow.ErrorOutOffset + Unsafe.SizeOf<BehaviourErrorInfoOutStatus>();
            shadow.ElapsedFrameCountSupported = shadow.ParseBehaviour.IsElapsedFrameCountSupported();
            shadow.EffectOutStatusSize = shadow.ParseBehaviour.IsEffectInfoVersion2Supported() ? Unsafe.SizeOf<EffectOutStatusVersion2>() : Unsafe.SizeOf<EffectOutStatusVersion1>();
            shadow.ConsumedInput = reader.Consumed;
            shadow.OutputCursorLength = outCursor.Length;
            shadow.OutputTotalLength = output.Length;

            stateUpdater.S2ASetInputReader(reader);
            stateUpdater.S2ASetOutput(outCursor);

            shadow.ParseStop = 9;
            shadow.ParseResult = ResultCode.Success;
            S2AMark(7);   // 收尾(性能缓冲读史;错误段/信息段/消费核算在落账)

            return ResultCode.Success;
        }

        // 声音段:与今天 StateUpdater.UpdateVoices2/1 逐行同体的解析驱动,差别只有三件——跑在影子上下文上、波表段
        //   逐槽驱动(S2AUpdateWaveBuffer 纯核,处方①③的逐槽记录在这里)、错误进暂存表(处方③,不进任何活队列)
        private ResultCode S2AParseVoices(ref StateUpdater stateUpdater, S2AUpdateShadow shadow, in UpdateDataHeader headerSizes)
        {
            // 借走读取器与输出游标(ref struct 不能按引用外借,拷走、用完写回——StateUpdater 在此期间不读不写,无别名)
            SequenceReader<byte> reader = stateUpdater.S2AInputReader;
            Memory<byte> outCursor = stateUpdater.S2AOutput;

            int voiceCount = (int)shadow.VoiceContext.GetCount();

            long initialInputConsumed = reader.Consumed;
            int initialOutputSize = outCursor.Length;

            bool isVoiceV2 = shadow.ParseBehaviour.IsBiquadFilterParameterFloatSupported();

            if (isVoiceV2)
            {
                if (voiceCount * Unsafe.SizeOf<VoiceInParameter2>() != headerSizes.VoicesSize)
                {
                    shadow.ParseResult = ResultCode.InvalidUpdateInfo;
                    shadow.ParseStop = 3;
                    return shadow.ParseResult;
                }
            }
            else if (voiceCount * Unsafe.SizeOf<VoiceInParameter1>() != headerSizes.VoicesSize)
            {
                shadow.ParseResult = ResultCode.InvalidUpdateInfo;
                shadow.ParseStop = 3;
                return shadow.ParseResult;
            }

            // 先全量置不使用(影子)
            for (int i = 0; i < voiceCount; i++)
            {
                shadow.VoiceContext.GetState(i).InUse = false;
            }

            Memory<VoiceState>[] voiceStatesArray = ArrayPool<Memory<VoiceState>>.Shared.Rent(Constants.VoiceChannelCountMax);

            Span<Memory<VoiceState>> voiceStates = voiceStatesArray.AsSpan(0, Constants.VoiceChannelCountMax);

            for (int i = 0; i < voiceCount; i++)
            {
                if (isVoiceV2)
                {
                    ref readonly VoiceInParameter2 parameter = ref reader.GetRefOrRefToCopy<VoiceInParameter2>(out _);

                    voiceStates.Fill(Memory<VoiceState>.Empty);

                    ref VoiceOutStatus outStatus = ref SpanIOHelper.GetWriteRef<VoiceOutStatus>(ref outCursor)[0];

                    S2ARecordVoiceParameter(shadow, i, parameter.InUse, parameter.IsNew, parameter.PlayState,
                        parameter.FlushWaveBufferCount, parameter.ChannelCount, parameter.ChannelResourceIds);

                    // 每声(含不在用声)都在循环体顶记 hook 起点——段界不留上一更新残值:旧实现只在 in-use 分支里记,
                    // 「i 在用、i+1 本更新不在用」时末槽钩区间终点吃到陈旧下标,钩丢失或跨段乱序双放(终审 mustFix 2)
                    shadow.VoiceHookStart[i] = shadow.HookLog.Count;

                    if (parameter.InUse)
                    {
                        ref VoiceInfo currentVoiceInfo = ref shadow.VoiceContext.GetState(i);

                        Span<int> channelResourceIdsSpan = parameter.ChannelResourceIds.AsSpan();

                        for (int channelResourceIndex = 0; channelResourceIndex < parameter.ChannelCount; channelResourceIndex++)
                        {
                            int channelId = channelResourceIdsSpan[channelResourceIndex];

                            Debug.Assert(channelId >= 0 && channelId < voiceCount);

                            voiceStates[channelResourceIndex] = shadow.VoiceContext.GetUpdateStateForCpu(channelId);
                        }

                        if (parameter.IsNew)
                        {
                            currentVoiceInfo.Initialize();
                        }

                        currentVoiceInfo.UpdateParameters2(out ErrorInfo updateParameterError, in parameter, S2AGetShadowUpdateMapper(shadow), ref shadow.ParseBehaviour);

                        if (updateParameterError.ErrorCode != ResultCode.Success)
                        {
                            shadow.RecordError(updateParameterError);   // 处方③:暂存,落账恰一次原序入队
                        }

                        S2AParseVoiceWaveBuffers2(shadow, i, in parameter, voiceStates);

                        currentVoiceInfo.WriteOutStatus2(ref outStatus, in parameter, voiceStates);
                    }
                }
                else
                {
                    ref readonly VoiceInParameter1 parameter = ref reader.GetRefOrRefToCopy<VoiceInParameter1>(out _);

                    voiceStates.Fill(Memory<VoiceState>.Empty);

                    ref VoiceOutStatus outStatus = ref SpanIOHelper.GetWriteRef<VoiceOutStatus>(ref outCursor)[0];

                    S2ARecordVoiceParameter(shadow, i, parameter.InUse, parameter.IsNew, parameter.PlayState,
                        parameter.FlushWaveBufferCount, parameter.ChannelCount, parameter.ChannelResourceIds);

                    // 每声(含不在用声)都在循环体顶记 hook 起点——段界不留上一更新残值:旧实现只在 in-use 分支里记,
                    // 「i 在用、i+1 本更新不在用」时末槽钩区间终点吃到陈旧下标,钩丢失或跨段乱序双放(终审 mustFix 2)
                    shadow.VoiceHookStart[i] = shadow.HookLog.Count;

                    if (parameter.InUse)
                    {
                        ref VoiceInfo currentVoiceInfo = ref shadow.VoiceContext.GetState(i);

                        Span<int> channelResourceIdsSpan = parameter.ChannelResourceIds.AsSpan();

                        for (int channelResourceIndex = 0; channelResourceIndex < parameter.ChannelCount; channelResourceIndex++)
                        {
                            int channelId = channelResourceIdsSpan[channelResourceIndex];

                            Debug.Assert(channelId >= 0 && channelId < voiceCount);

                            voiceStates[channelResourceIndex] = shadow.VoiceContext.GetUpdateStateForCpu(channelId);
                        }

                        if (parameter.IsNew)
                        {
                            currentVoiceInfo.Initialize();
                        }

                        currentVoiceInfo.UpdateParameters1(out ErrorInfo updateParameterError, in parameter, S2AGetShadowUpdateMapper(shadow), ref shadow.ParseBehaviour);

                        if (updateParameterError.ErrorCode != ResultCode.Success)
                        {
                            shadow.RecordError(updateParameterError);   // 处方③
                        }

                        S2AParseVoiceWaveBuffers1(shadow, i, in parameter, voiceStates);

                        currentVoiceInfo.WriteOutStatus1(ref outStatus, in parameter, voiceStates);
                    }
                }
            }

            ArrayPool<Memory<VoiceState>>.Shared.Return(voiceStatesArray);

            ref UpdateDataHeader outHeader = ref stateUpdater.S2AOutputHeader;

            outHeader.VoicesSize = (uint)(Unsafe.SizeOf<VoiceOutStatus>() * voiceCount);
            outHeader.TotalSize += outHeader.VoicesSize;

            Debug.Assert((initialOutputSize - outCursor.Length) == outHeader.VoicesSize);

            reader.SetConsumed(initialInputConsumed + headerSizes.VoicesSize);

            stateUpdater.S2ASetInputReader(reader);
            stateUpdater.S2ASetOutput(outCursor);

            shadow.ParseStop = 4;

            return ResultCode.Success;
        }

        private static void S2ARecordVoiceParameter(S2AUpdateShadow shadow, int voiceId, bool inUse, bool isNew, Common.PlayState playState, byte flushWaveBufferCount, uint channelCount, Array6<int> channelResourceIds)
        {
            shadow.VoiceInUse[voiceId] = inUse;
            shadow.VoiceIsNew[voiceId] = isNew;
            shadow.VoicePlayState[voiceId] = playState;
            shadow.VoiceFlushCount[voiceId] = flushWaveBufferCount;
            shadow.VoiceChannelCount[voiceId] = (int)channelCount;
            channelResourceIds.AsSpan().CopyTo(shadow.VoiceChannelIds.AsSpan(voiceId * Constants.VoiceChannelCountMax, Constants.VoiceChannelCountMax));
        }

        // 与今天 UpdateWaveBuffers2 的段体逐行同体,差别:逐槽记录(处方①③)+ 纯核直调 + 错误暂存(处方③)
        private void S2AParseVoiceWaveBuffers2(S2AUpdateShadow shadow, int voiceId, in VoiceInParameter2 parameter, Span<Memory<VoiceState>> voiceStates)
        {
            ref VoiceInfo currentVoiceInfo = ref shadow.VoiceContext.GetState(voiceId);

            if (parameter.IsNew)
            {
                currentVoiceInfo.InitializeWaveBuffers();

                for (int i = 0; i < parameter.ChannelCount; i++)
                {
                    voiceStates[i].Span[0].IsWaveBufferValid.Clear();
                }
            }

            ref VoiceState voiceState = ref voiceStates[0].Span[0];

            Span<WaveBuffer> waveBuffersSpan = currentVoiceInfo.WaveBuffers.AsSpan();
            Span<WaveBufferInternal> pWaveBuffersSpan = parameter.WaveBuffers.AsSpan();

            _s2aWaveErrorList.Clear();

            for (int i = 0; i < Constants.VoiceWaveBufferCount; i++)
            {
                ref S2AUpdateShadow.VoiceSlotRecord slot = ref shadow.VoiceSlots[voiceId * Constants.VoiceWaveBufferCount + i];

                // 处方①③:逐槽记录 isValid 读数 / 重演输入 / hook 起点(锁2a 复核的对照基准)
                slot.IsValid = voiceState.IsWaveBufferValid[i];
                slot.BufferUnmappedIn = currentVoiceInfo.BufferInfoUnmapped;
                slot.SampleFormat = parameter.SampleFormat;
                slot.Input = pWaveBuffersSpan[i];
                slot.HookStart = shadow.HookLog.Count;

                int errorStart = _s2aWaveErrorList.Count;

                VoiceInfo.S2AUpdateWaveBuffer(
                    _s2aWaveErrorList,
                    ref waveBuffersSpan[i],
                    ref pWaveBuffersSpan[i],
                    parameter.SampleFormat,
                    slot.IsValid,
                    S2AGetShadowUpdateMapper(shadow),
                    ref shadow.ParseBehaviour,
                    ref currentVoiceInfo.BufferInfoUnmapped);

                for (int e = errorStart; e < _s2aWaveErrorList.Count; e++)
                {
                    shadow.RecordError(_s2aWaveErrorList[e]);   // 处方③:重发错误按 (voiceId,波表) 暂存
                }
            }
        }

        // 与今天 UpdateWaveBuffers1 的段体逐行同体(同上,REV8 之前的旧版参数)
        private void S2AParseVoiceWaveBuffers1(S2AUpdateShadow shadow, int voiceId, in VoiceInParameter1 parameter, Span<Memory<VoiceState>> voiceStates)
        {
            ref VoiceInfo currentVoiceInfo = ref shadow.VoiceContext.GetState(voiceId);

            if (parameter.IsNew)
            {
                currentVoiceInfo.InitializeWaveBuffers();

                for (int i = 0; i < parameter.ChannelCount; i++)
                {
                    voiceStates[i].Span[0].IsWaveBufferValid.Clear();
                }
            }

            ref VoiceState voiceState = ref voiceStates[0].Span[0];

            Span<WaveBuffer> waveBuffersSpan = currentVoiceInfo.WaveBuffers.AsSpan();
            Span<WaveBufferInternal> pWaveBuffersSpan = parameter.WaveBuffers.AsSpan();

            _s2aWaveErrorList.Clear();

            for (int i = 0; i < Constants.VoiceWaveBufferCount; i++)
            {
                ref S2AUpdateShadow.VoiceSlotRecord slot = ref shadow.VoiceSlots[voiceId * Constants.VoiceWaveBufferCount + i];

                slot.IsValid = voiceState.IsWaveBufferValid[i];
                slot.BufferUnmappedIn = currentVoiceInfo.BufferInfoUnmapped;
                slot.SampleFormat = parameter.SampleFormat;
                slot.Input = pWaveBuffersSpan[i];
                slot.HookStart = shadow.HookLog.Count;

                int errorStart = _s2aWaveErrorList.Count;

                VoiceInfo.S2AUpdateWaveBuffer(
                    _s2aWaveErrorList,
                    ref waveBuffersSpan[i],
                    ref pWaveBuffersSpan[i],
                    parameter.SampleFormat,
                    slot.IsValid,
                    S2AGetShadowUpdateMapper(shadow),
                    ref shadow.ParseBehaviour,
                    ref currentVoiceInfo.BufferInfoUnmapped);

                for (int e = errorStart; e < _s2aWaveErrorList.Count; e++)
                {
                    shadow.RecordError(_s2aWaveErrorList[e]);
                }
            }
        }

        // 效果段 IsNew 逐条扫输入(独立读取器,不干扰主读取器;位置 = 行为+内存池+声道资源+声音四段之后)
        private void S2AScanEffectIsNew(ReadOnlySequence<byte> input, S2AUpdateShadow shadow, in UpdateDataHeader headerSizes)
        {
            int effectCount = (int)shadow.EffectContext.GetCount();

            if (effectCount == 0)
            {
                return;
            }

            SequenceReader<byte> scan = new(input);

            scan.Advance(headerSizes.BehaviourSize + headerSizes.MemoryPoolsSize + headerSizes.VoiceResourcesSize + headerSizes.VoicesSize);

            if (shadow.ParseBehaviour.IsEffectInfoVersion2Supported())
            {
                for (int i = 0; i < effectCount; i++)
                {
                    ref readonly EffectInParameterVersion2 parameter = ref scan.GetRefOrRefToCopy<EffectInParameterVersion2>(out _);

                    shadow.EffectIsNew[i] = parameter.IsNew;
                }
            }
            else
            {
                for (int i = 0; i < effectCount; i++)
                {
                    ref readonly EffectInParameterVersion1 parameter = ref scan.GetRefOrRefToCopy<EffectInParameterVersion1>(out _);

                    shadow.EffectIsNew[i] = parameter.IsNew;
                }
            }
        }

        // 内存池段解析(与今天 StateUpdater.UpdateMemoryPools 逐行同体的驱动,跑在影子池表上):差别两件——
        //   逐池记 hook 起点(该池 Map/Unmap 至多一条,区间 = 本池起点到下一池起点;落账 detach 复核要用,终审
        //   mustFix 4)与挂接 hook 走日志(录制模式)。其余逐行同体,失败路径(InvalidParameter 中段返回)也与
        //   今天一致:已跑池 = 前缀(影子上),未跑池 = 锁1 快照
        internal static ResultCode S2AParseMemoryPools(
            ref SequenceReader<byte> reader,
            ref Memory<byte> outCursor,
            Span<MemoryPoolInfo> shadowPools,
            int[] poolHookStart,
            PoolMapper mapper,
            S2AHookLog hookLog,
            in UpdateDataHeader inputHeader,
            ref UpdateDataHeader outputHeader)
        {
            if (shadowPools.Length * Unsafe.SizeOf<MemoryPoolInParameter>() != inputHeader.MemoryPoolsSize)
            {
                return ResultCode.InvalidUpdateInfo;
            }

            // 先把整表填本段起点(零分配)——段中 InvalidParameter 提前返回时未达池保的是上一更新的陈旧下标,
            // 而池段失败 ParseStop=2 落账照跑,陈旧区间非空且落在本次前缀钩范围内时会把别的池的驻留钩重放
            // 第二遍(终审:更新 N 只挂池 6 → 更新 N+1 池 0..4 各挂 5 钩、池 5 参数非法段败,池 6/7 未达
            // 保陈旧 [0,1],落账重放 6 条——池 0 的 Map 被池 6 的陈旧区间重放两遍,基线恰 5 条)

            Array.Fill(poolHookStart, hookLog.Count);

            for (int i = 0; i < shadowPools.Length; i++)
            {
                poolHookStart[i] = hookLog.Count;

                ref readonly MemoryPoolInParameter parameter = ref reader.GetRefOrRefToCopy<MemoryPoolInParameter>(out _);

                ref MemoryPoolOutStatus outStatus = ref SpanIOHelper.GetWriteRef<MemoryPoolOutStatus>(ref outCursor)[0];

                PoolMapper.UpdateResult updateResult = mapper.Update(ref shadowPools[i], in parameter, ref outStatus);

                if (updateResult is not PoolMapper.UpdateResult.Success and
                    not PoolMapper.UpdateResult.MapError and
                    not PoolMapper.UpdateResult.UnmapError)
                {
                    if (updateResult != PoolMapper.UpdateResult.InvalidParameter)
                    {
                        throw new InvalidOperationException($"{updateResult}");
                    }

                    return ResultCode.InvalidUpdateInfo;
                }
            }

            outputHeader.MemoryPoolsSize = (uint)(Unsafe.SizeOf<MemoryPoolOutStatus>() * shadowPools.Length);
            outputHeader.TotalSize += outputHeader.MemoryPoolsSize;

            return ResultCode.Success;
        }

        // 内存池段落账:影子池表逐池拷回(IsUsed 保留活值)+ 逐池 hook 重放。detach 复核(与波表槽翻转复核
        //   同构的处方,终审 mustFix 4):解析段的 detach 拒绝判据(mapper.Update 的 IsUsed 检查)吃的是锁1 快照的
        //   IsUsed——中拍(渲染拍命令生成 GetReference(true) 重标记)可以把锁1 时未用的池标成在用;影子决定
        //   detach(影子清址)而此刻活池 IsUsed=true 的,保留活映射、不重放其 Unmap 钩(退驻留会拆掉在列命令
        //   正在读的区域)。基线由 live 的 IsUsed 拒绝闭合,这里在落账点补同型复核。池的响应出参状态段按解析段
        //   (锁1 快照基底)口径不变
        internal static void S2ACommitMemoryPools(
            Span<MemoryPoolInfo> livePools,
            Span<MemoryPoolInfo> shadowPools,
            S2AHookLog hookLog,
            int[] poolHookStart,
            int voicesHookStart,
            uint processHandle)
        {
            for (int i = 0; i < livePools.Length; i++)
            {
                ref MemoryPoolInfo livePool = ref livePools[i];
                ref MemoryPoolInfo shadowPool = ref shadowPools[i];

                int hookStart = poolHookStart[i];
                int hookEnd = (i + 1 < livePools.Length) ? poolHookStart[i + 1] : voicesHookStart;

                if (livePool.CpuAddress != 0 && shadowPool.CpuAddress == 0 && livePool.IsUsed)
                {
                    // 影子决定 detach 而活池此刻在用:保留活映射、不重放该池钩(解析段记的就一条 Unmap)
                    continue;
                }

                bool isUsed = livePool.IsUsed;

                livePool = shadowPool;
                livePool.IsUsed = isUsed;

                hookLog.Replay(hookStart, hookEnd, processHandle);
            }
        }

        // ---------- 落账段(锁2a,锁内)----------
        private ResultCode S2ACommitLocked(Memory<byte> output, ReadOnlySequence<byte> input, S2AUpdateShadow shadow, ResultCode parseResult)
        {
            int voiceCount = (int)_voiceContext.GetCount();

            // ① 行为:新旗标拷回 live(解析在私有拷贝上;旗标是渲染调度线程的读字段,落账原子换新)
            if (shadow.ParseStop >= 1)
            {
                _behaviourInfo.UpdateFlags(shadow.ParseBehaviour.S2AFlags);
            }

            // ② 内存池:影子池表拷回(IsUsed 保留活值——渲染拍每拍 ClearUsageState 全清、命令生成按用标记,拷基底的
            //    IsUsed 会把标记竞态盖掉;「池用量标记与 ClearUsageState 的竞态」由此闭合)+ 逐池 hook 重放,
            //    detach 复核拒绝的池保留活映射、不重放其 Unmap 钩(见 S2ACommitMemoryPools,终审 mustFix 4)
            if (shadow.ParseStop >= 2)
            {
                S2ACommitMemoryPools(
                    _memoryPools.Span,
                    shadow.ShadowPoolsSpan,
                    shadow.HookLog,
                    shadow.PoolHookStart,
                    shadow.VoicesHookStart,
                    _processHandle);
            }

            // ③ 声道资源:Id/Mix/IsUsage 拷回;PreviousMix 是拍写(ResetResources 拷 Mix→PreviousMix),保留活值
            if (shadow.ParseStop >= 3)
            {
                for (int i = 0; i < voiceCount; i++)
                {
                    ref VoiceChannelResource liveResource = ref _voiceContext.GetChannelResource(i);
                    ref VoiceChannelResource shadowResource = ref shadow.VoiceContext.GetChannelResource(i);

                    liveResource.Id = shadowResource.Id;
                    shadowResource.Mix.AsSpan().CopyTo(liveResource.Mix.AsSpan());
                    liveResource.IsUsed = shadowResource.IsUsed;
                }
            }

            // ④ 声音:字段矩阵 + 波表逐槽(处方①②③)+ 逐槽 hook(翻转重演的 Unmap 插在该槽重发 Map 之前)
            if (shadow.ParseStop >= 4)
            {
                S2ACommitVoices(shadow);

                if (_s2aVoiceDiag != null)
                {
                    string line = _s2aVoiceDiag.Observe(_voiceContext, _manager.TickSource.ElapsedSeconds, _sessionId);

                    if (line != null)
                    {
                        Console.Error.WriteLine(line);
                    }
                }
            }

            // ⑤ 效果:实例字段拷回 / 型变装新实例 + IsNew 的 InitializeResultState 对 live 重放 + 池重绑 + hook 重放
            if (shadow.ParseStop >= 5)
            {
                for (int i = 0; i < (int)_effectContext.S2ACount; i++)
                {
                    ref BaseEffect live = ref _effectContext.GetEffect(i);
                    ref BaseEffect shadowEffect = ref shadow.EffectContext.GetEffect(i);

                    if (live.TargetEffectType != shadowEffect.TargetEffectType)
                    {
                        // 解析段对影子做了型变重置(ResetEffect):影子实例即新实例,装进 live;影子槽补一个同型新实例
                        BaseEffect newLive = shadowEffect;

                        shadowEffect = BaseEffect.S2ACreate(newLive.TargetEffectType, shadow.ParseBehaviour.IsBiquadFilterParameterFloatSupported());
                        _effectContext.GetEffect(i) = newLive;
                    }
                    else
                    {
                        live.S2AShadowCopyGameFieldsFrom(shadowEffect);
                    }

                    live.S2ARebindWorkBuffers(shadow);

                    if (shadow.EffectIsNew[i])
                    {
                        // 今天的时序:InitializeResultState 在该效果更新后即跑;落账保持段序
                        live.InitializeResultState(ref _effectContext.GetDspState(i));
                        live.InitializeResultState(ref _effectContext.GetState(i));
                    }
                }

                shadow.HookLog.Replay(shadow.EffectsHookStart, shadow.SinksHookStart, _processHandle);
            }

            // ⑥ 分频:字段矩阵拷回 + 链在 live 目的地数组上原样重建(分频器结构体整拷;目的地游戏字段拷、
            //    拍写字段保留活值、增量字段按锁1 基底判增量;链头/链指针按影子链的目的地 id 序重建)
            if (shadow.ParseStop >= 6)
            {
                _splitterContext.S2ACommitFrom(shadow.SplitterContext);
            }

            // ⑦ 混音:整组拷回(混音结构/排序索引/邻接矩阵都没有拍写侧)
            if (shadow.ParseStop >= 7)
            {
                _mixContext.S2ACommitFrom(shadow.MixContext);
            }

            // ⑧ 汇:实例字段拷回 / 型变装新实例 + 池重绑 + hook 重放
            if (shadow.ParseStop >= 8)
            {
                for (int i = 0; i < (int)_sinkContext.GetCount(); i++)
                {
                    ref BaseSink live = ref _sinkContext.GetSink(i);
                    ref BaseSink shadowSink = ref shadow.SinkContext.GetSink(i);

                    if (live.TargetSinkType != shadowSink.TargetSinkType)
                    {
                        // 解析段的 ResetSink 把 CleanUp 跑在影子上,而影子的 UpsamplerInfo 按拍写字段口径不拷、
                        // 恒 null——live 的旧实例在这里补 CleanUp(释放升采样槽位,基线语义「先清后换」),
                        // 不补则旧 UpsamplerInfo 脱链、UpsamplerManager 定容槽位永久泄漏(终审 mustFix 5)
                        live.CleanUp();

                        BaseSink newLive = shadowSink;

                        shadowSink = BaseSink.S2ACreate(newLive.TargetSinkType);
                        _sinkContext.GetSink(i) = newLive;
                    }
                    else
                    {
                        live.S2AShadowCopyGameFieldsFrom(shadowSink);
                    }

                    if (live is CircularBufferSink circularBufferSink)
                    {
                        shadow.S2ARebindAddressInfo(ref circularBufferSink.CircularBufferAddressInfo);
                    }
                }

                shadow.HookLog.Replay(shadow.SinksHookStart, shadow.HookLog.Count, _processHandle);
            }

            // ⑨ 收尾:目标节点 + 错误段/信息段写入 + 消费核算 + 事件(全成才清——今天的握手时序)
            if (shadow.ParseStop >= 9)
            {
                if (shadow.PerfManagerPresent)
                {
                    _performanceManager.SetTargetNodeId(shadow.PerfTargetNodeId);
                }

                // 错误入队(今天的顺序:声音段暂存表在前、效果/汇段私有队列在后,原序进 live 队列;上限与
                // BehaviourInfo.AppendError 一致——超出的与今天一样静默丢)
                _behaviourInfo.ClearError();

                for (int i = 0; i < shadow.ErrorCount; i++)
                {
                    ErrorInfo error = shadow.Errors[i];

                    _behaviourInfo.AppendError(ref error);
                }

                shadow.ParseBehaviour.CopyErrorInfo(_s2aErrorScratch, out uint effectSinkErrorCount);

                for (int i = 0; i < effectSinkErrorCount; i++)
                {
                    ErrorInfo error = _s2aErrorScratch[i];

                    _behaviourInfo.AppendError(ref error);
                }

                // 错误段(= 今天的 UpdateErrorInfo 字节)
                ref UpdateDataHeader outHeader = ref MemoryMarshal.Cast<byte, UpdateDataHeader>(output.Span[..Unsafe.SizeOf<UpdateDataHeader>()])[0];

                ref BehaviourErrorInfoOutStatus errorOutStatus = ref MemoryMarshal.Cast<byte, BehaviourErrorInfoOutStatus>(
                    output.Span.Slice(shadow.ErrorOutOffset, Unsafe.SizeOf<BehaviourErrorInfoOutStatus>()))[0];

                _behaviourInfo.CopyErrorInfo(errorOutStatus.ErrorInfos.AsSpan(), out errorOutStatus.ErrorInfosCount);

                outHeader.BehaviourSize = (uint)Unsafe.SizeOf<BehaviourErrorInfoOutStatus>();
                outHeader.TotalSize += outHeader.BehaviourSize;

                // 信息段(= 今天的 UpdateRendererInfo:_elapsedFrameCount 是拍写字段,按落账时刻读)
                if (shadow.ElapsedFrameCountSupported)
                {
                    ref RendererInfoOutStatus rendererOutStatus = ref MemoryMarshal.Cast<byte, RendererInfoOutStatus>(
                        output.Span.Slice(shadow.RendererInfoOutOffset, Unsafe.SizeOf<RendererInfoOutStatus>()))[0];

                    rendererOutStatus.ElapsedFrameCount = _elapsedFrameCount;

                    outHeader.RenderInfoSize = (uint)Unsafe.SizeOf<RendererInfoOutStatus>();
                    outHeader.TotalSize += outHeader.RenderInfoSize;
                }

                // 消费核算(= 今天的 CheckConsumedSize,含两条错行日志)
                SequenceReader<byte> inputHeaderReader = new(input);

                UpdateDataHeader inputHeader = inputHeaderReader.GetRefOrRefToCopy<UpdateDataHeader>(out _);

                long consumedInputSize = shadow.ConsumedInput;

                // 输出消费 = 解析段游标消费 + 落账写的错误段/信息段尺寸(今天的口径:两段在核算前已把游标推过)
                int consumedOutputSize = shadow.OutputTotalLength - shadow.OutputCursorLength
                    + (int)outHeader.BehaviourSize + (int)outHeader.RenderInfoSize;

                if (consumedInputSize != inputHeader.TotalSize)
                {
                    Logger.Error?.Print(LogClass.AudioRenderer, $"Consumed input size mismatch (got {consumedInputSize} expected {inputHeader.TotalSize})");

                    return ResultCode.InvalidUpdateInfo;
                }

                if (consumedOutputSize != outHeader.TotalSize)
                {
                    Logger.Error?.Print(LogClass.AudioRenderer, $"Consumed output size mismatch (got {consumedOutputSize} expected {outHeader.TotalSize})");

                    return ResultCode.InvalidUpdateInfo;
                }

                _systemEvent.Clear();

                return ResultCode.Success;
            }

            return parseResult;
        }

        // 声音段落账:字段矩阵 + 波表逐槽(处方①②③)。今天的逐字段语义:
        //   游戏写字段从影子拷(影子 = 解析段结果);WasPlaying/PreviousVolume 只有拍写,保留活值;
        //   PlayState/IsNew/FlushWaveBufferCount 是两写字段,用纯函数对「活」值重放 = 「Update 在拍后串行」的今天语义
        //   (中拍把 Stopping 迁到 Stopped / 消费掉 IsNew / 清了 Flush 计数时,重放不复活它们、不二次 ResetResources /
        //   不二次冲洗);波表槽按处方重演。
        // 锁2a 波表单槽落账(处方①②③):生产落账与服务层单测(--audio-renderer-wave-slot-replay)共用这一份,
        //   单测不再另拼一遍流程——另拼的副本与生产走偏时(翻转槽落重演输出还是影子槽)单测照样绿,生产的翻转分支等于没测。
        //   liveValid = 落账时的活 isValid;slot = 解析段该槽的记录(读到的 isValid / 进槽 BufferUnmapped / 输入 / hook 起点);
        //   snapshotSlot = 锁1 快照里的该槽(翻转重演基底);slotHookEnd = 该槽 hook 记录终点
        internal static void S2ACommitWaveSlot(bool liveValid, ref S2AUpdateShadow.VoiceSlotRecord slot, ref WaveBuffer liveSlot, ref WaveBuffer shadowSlot,
            WaveBuffer snapshotSlot, PoolMapper commitMapper, ref BehaviourInfo parseBehaviour, List<ErrorInfo> replayErrors, S2AHookLog hookLog, int slotHookEnd, uint processHandle)
        {
            if (liveValid == slot.IsValid)
            {
                // 未翻转:解析段结果整体落账
                liveSlot = shadowSlot;
            }
            else
            {
                // 翻转:处方①——基底 = 锁1 快照里的该槽(含旧地址与旧 IsSendToAudioProcessor),对该基底重跑
                // isValid 分支(用翻转后的活 isValid)与重发分支两者。不能拿解析后的影子当基底::664 条件里的
                // IsSendToAudioProcessor 已被重发置 false,分支整跳过,A_old 的 Unmap 丢失;只对影子跑分支则
                // ForceUnmap 拿到的是 A_new,会把 DSP 下一拍正要读的新区域退驻留。重发分支不读 isValid,其
                // 输出 = 影子槽,重演只为 isValid 分支的 ForceUnmap(A_old) 与 :674 断言的今天触发条件
                WaveBuffer replayBase = snapshotSlot;
                bool bufferUnmapped = slot.BufferUnmappedIn;

                replayErrors.Clear();

                commitMapper.S2ASuppressAttachHooks = true;   // 处方②:重发挂接的 hook 已在日志里待重放,重演不再执行

                VoiceInfo.S2AUpdateWaveBuffer(
                    replayErrors,
                    ref replayBase,
                    ref slot.Input,
                    slot.SampleFormat,
                    liveValid,
                    commitMapper,
                    ref parseBehaviour,
                    ref bufferUnmapped);

                commitMapper.S2ASuppressAttachHooks = false;

                // 重演的错误与解析段暂存的同输入同基底、同一条——落账从暂存表恰一次原序入队(处方③),这里丢弃。
                // 整体替换:重发分支输出 = 影子槽,isValid 分支只多了 Unmap 钩与清址(被重发分支的重挂覆盖)
                liveSlot = shadowSlot;
            }

            // 该槽 hook 重放(处方②:翻转槽的 Unmap 已由重演先行执行,这里按原序重放解析段记的重发 Map)
            hookLog.Replay(slot.HookStart, slotHookEnd, processHandle);
        }

        private void S2ACommitVoices(S2AUpdateShadow shadow)
        {
            int voiceCount = (int)_voiceContext.GetCount();

            for (int i = 0; i < voiceCount; i++)
            {
                ref VoiceInfo live = ref _voiceContext.GetState(i);
                ref VoiceInfo shadowVoice = ref shadow.VoiceContext.GetState(i);

                // 全量 InUse=false 的语义照旧(影子已置,拷回)
                live.InUse = shadowVoice.InUse;

                if (!shadow.VoiceInUse[i])
                {
                    continue;   // 今天不在用声只置 InUse=false,其余字段不动
                }

                // ---- 游戏写字段:影子结果拷回 ----
                live.Id = shadowVoice.Id;
                live.NodeId = shadowVoice.NodeId;
                live.SampleRate = shadowVoice.SampleRate;
                live.SampleFormat = shadowVoice.SampleFormat;
                live.ChannelsCount = shadowVoice.ChannelsCount;
                live.Priority = shadowVoice.Priority;
                live.SortingOrder = shadowVoice.SortingOrder;
                live.Pitch = shadowVoice.Pitch;
                live.Volume = shadowVoice.Volume;
                live.BiquadFilters = shadowVoice.BiquadFilters;
                live.WaveBuffersCount = shadowVoice.WaveBuffersCount;
                live.WaveBuffersIndex = shadowVoice.WaveBuffersIndex;
                live.MixId = shadowVoice.MixId;
                live.SplitterId = shadowVoice.SplitterId;
                live.ChannelResourceIds = shadowVoice.ChannelResourceIds;
                live.DecodingBehaviour = shadowVoice.DecodingBehaviour;
                live.VoiceDropFlag = shadowVoice.VoiceDropFlag;
                live.DataSourceStateUnmapped = shadowVoice.DataSourceStateUnmapped;

                live.DataSourceStateAddressInfo = shadowVoice.DataSourceStateAddressInfo;
                shadow.S2ARebindAddressInfo(ref live.DataSourceStateAddressInfo);

                // 波表挂接失败标记(该字段无拍写侧,与 DataSourceStateUnmapped 同口径整拷)——漏拷会让
                // ShouldSkip 不跳过该声、按 DSP 地址 0 生成命令,且「挂接失败每更新重试」语义随影子被
                // 锁1 快照重置而丢失(终审 mustFix 3)
                live.BufferInfoUnmapped = shadowVoice.BufferInfoUnmapped;

                // ---- 两写字段:纯函数对活值重放 ----
                (live.PlayState, live.PreviousPlayState) = VoiceInfo.S2AUpdatePlayState(live.PlayState, shadow.VoicePlayState[i]);
                live.IsNew = shadow.VoiceIsNew[i] || live.IsNew;

                if (shadow.ParseBehaviour.IsFlushVoiceWaveBuffersSupported())
                {
                    live.FlushWaveBufferCount += shadow.VoiceFlushCount[i];
                }

                // WasPlaying / PreviousVolume:只有拍写,保留活值,不拷

                // ---- 波表:今天的顺序——IsNew 先清 CPU 侧 isValid,再逐槽 ----
                if (shadow.VoiceIsNew[i])
                {
                    for (int c = 0; c < shadow.VoiceChannelCount[i]; c++)
                    {
                        _voiceContext.GetUpdateStateForCpu(shadow.VoiceChannelIds[i * Constants.VoiceChannelCountMax + c]).Span[0].IsWaveBufferValid.Clear();
                    }
                }

                int voiceHookStart = shadow.VoiceHookStart[i];
                int voiceHookEnd = (i + 1 < voiceCount) ? shadow.VoiceHookStart[i + 1] : shadow.EffectsHookStart;

                // 该声数据源状态挂接的 hook(在四槽之前,今天的段内顺序)
                shadow.HookLog.Replay(voiceHookStart, shadow.VoiceSlots[i * Constants.VoiceWaveBufferCount].HookStart, _processHandle);

                ref VoiceState liveChannel0 = ref _voiceContext.GetUpdateStateForCpu(shadow.VoiceChannelIds[i * Constants.VoiceChannelCountMax]).Span[0];

                for (int k = 0; k < Constants.VoiceWaveBufferCount; k++)
                {
                    ref S2AUpdateShadow.VoiceSlotRecord slot = ref shadow.VoiceSlots[i * Constants.VoiceWaveBufferCount + k];
                    ref WaveBuffer liveSlot = ref live.WaveBuffers[k];
                    ref WaveBuffer shadowSlot = ref shadowVoice.WaveBuffers[k];

                    int slotHookEnd = (k + 1 < Constants.VoiceWaveBufferCount)
                        ? shadow.VoiceSlots[i * Constants.VoiceWaveBufferCount + k + 1].HookStart
                        : voiceHookEnd;

                    // 复核:该槽解析段读到的 isValid(处方③的暂存基准)vs 落账时的活 isValid——中拍
                    //   (Stopping 清全数组 / FlushWaveBuffers / DSP 消费回拷,UpdateParametersForCommandGeneration
                    //   在渲染拍里跑)会把它翻成 false
                    bool liveValid = liveChannel0.IsWaveBufferValid[k];

                    S2ACommitWaveSlot(liveValid, ref slot, ref liveSlot, ref shadowSlot, shadow.VoiceSnapshotSpan[i].WaveBuffers[k],
                        GetUpdatePoolMapper(), ref shadow.ParseBehaviour, _s2aReplayErrorList, shadow.HookLog, slotHookEnd, _processHandle);

                    // 池指针重绑(影子池表 → live 池表;快照拷里没被重挂的地址信息本来就指 live,原样即正确)
                    shadow.S2ARebindAddressInfo(ref liveSlot.BufferAddressInfo);
                    shadow.S2ARebindAddressInfo(ref liveSlot.ContextAddressInfo);
                }
            }
        }
    }
}
