// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Renderer.Common;
using Ryujinx.Audio.Renderer.Parameter;
using Ryujinx.Audio.Renderer.Server;
using Ryujinx.Audio.Renderer.Server.MemoryPool;
using Ryujinx.Audio.Renderer.Server.Voice;
using Ryujinx.Memory;
using System;
using System.Buffers;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using static Ryujinx.Audio.Renderer.Common.BehaviourParameter;
using ResultCode = Ryujinx.Audio.ResultCode;
using WaveBuffer = Ryujinx.Audio.Renderer.Server.Voice.WaveBuffer;

namespace S2A.Services.Tests
{
    // D-ARWS（#12/#13 拆分 · 独立复审第二轮的三条处方）: 中拍翻转 + 同拍重发的波表槽重演。
    //   口径:纯函数/日志重演——VoiceInfo.S2AUpdateWaveBuffer 纯核逐槽直调,oracle = 今天的串行序
    //   (拍先翻转 isValid、Update 再跑成);拆分 = 解析段(锁1 快照基底、isValid=快照读数)+ 锁2a 复核翻转重演
    //   (同一快照基底、isValid=翻转后的活值、重发挂接抑制 hook)+ 解析段 hook 日志重放。
    //   九槽 = 一个声的 1 数据源状态 + 4 波表本体 + 4 波表上下文。三件断言:
    //   ① 九槽终值(地址/尺寸/强制映射地址/送 DSP 标志/样偏移/bufferUnmapped);
    //   ② hook 日志时序(处方②:翻转槽 = [Unmap(A_old) → Map×2(A_new)],强制映射路径本样双 Map,
    //      PoolMapper.AssignDspAddress;重演的 Unmap 立即执行、排在解析段记的重发 Map 重放之前);
    //   ③ 错误段(处方③:响应错误字节口径——按 (voiceId,波表) 暂存、恰一次原序入队,重演错误与解析段同一条,
    //      丢弃不二次入队)。
    //   另测无交错(不翻转):拆分终值 = 今天 isValid=快照读数一次跑成的终值。
    static class AudioRendererWaveSlotReplayTest
    {
        private const int SlotsPerVoice = 4;

        private const ulong Pool0Address = 0x1000_0000;    // 池 0:全部旧区(A_old、数据源旧、上下文旧)
        private const ulong Pool0Size = 0x1_0000;
        private const ulong Pool1Address = 0x3000_0000;    // 池 1:槽 1 的新区(池内挂接路径,不产 hook)
        private const ulong Pool1Size = 0x1_0000;

        private static readonly ulong DsOld = Pool0Address + 0x1000;
        private static readonly ulong A0Old = Pool0Address + 0x3000;
        private static readonly ulong A1Old = Pool0Address + 0x4000;
        private static readonly ulong A2Old = Pool0Address + 0x5000;
        private static readonly ulong A3Old = Pool0Address + 0x6000;
        private static readonly ulong DsNew = 0x2000_0000;             // 池外(强制映射)
        private static readonly ulong A0New = 0x2000_1000;            // 池外(强制映射)
        private static readonly ulong CtxNew = 0x2000_2000;           // 池外(强制映射,ADPCM 上下文)
        private static readonly ulong A1New = Pool1Address + 0x8000;  // 池 1 内(池内挂接)

        private const ulong RegionSize = 0x1000;

        // 锁1 读到的 CPU 侧 IsWaveBufferValid:槽 2 早已失效(如 DSP 消费完),其余有效
        private static readonly bool[] SnapshotIsValid = { true, true, false, true };

        // hook 捕获(静态函数指针不能捕捕获,走静态表;单线程测试无竞态)
        private static readonly List<string> _hooks = new();

        private static unsafe void Capture(ulong address, ulong size, bool map)
        {
            _hooks.Add($"{(map ? "Map" : "Unmap")} 0x{address:x}/0x{size:x}");
        }

        private sealed class Run
        {
            internal VoiceInfo Voice;
            internal List<ErrorInfo> Errors = new();
            internal List<string> Hooks = new();
        }

        // 原生池表(地址信息要绑池指针,池表原生、指针稳定;测试结束释放)
        private static readonly List<IntPtr> _poolBlocks = new();

        private static unsafe Memory<MemoryPoolInfo> MakePools()
        {
            byte* block = (byte*)NativeMemory.AlignedAlloc((nuint)(sizeof(MemoryPoolInfo) * 2), 0x10);
            NativeMemory.Clear(block, (nuint)(sizeof(MemoryPoolInfo) * 2));

            _poolBlocks.Add((IntPtr)block);

            Span<MemoryPoolInfo> pools = new(block, 2);

            pools[0] = MemoryPoolInfo.Create(MemoryPoolInfo.LocationType.Cpu);
            pools[1] = MemoryPoolInfo.Create(MemoryPoolInfo.LocationType.Cpu);
            pools[0].SetCpuAddress(Pool0Address, Pool0Size);
            pools[1].SetCpuAddress(Pool1Address, Pool1Size);

            return new NativeMemoryManager<MemoryPoolInfo>((MemoryPoolInfo*)block, 2).Memory;
        }

        private static unsafe void FreePools()
        {
            foreach (IntPtr block in _poolBlocks)
            {
                NativeMemory.AlignedFree((void*)block);
            }

            _poolBlocks.Clear();
        }

        // 锁1 快照态:四槽挂旧址(IsSendToAudioProcessor=true)、数据源状态挂旧址
        private static VoiceInfo MakeVoice()
        {
            VoiceInfo voice = new();
            voice.Initialize();

            Span<WaveBuffer> waveBuffers = voice.WaveBuffers.AsSpan();

            for (int k = 0; k < SlotsPerVoice; k++)
            {
                waveBuffers[k].BufferAddressInfo.Setup(A0Old + (ulong)k * 0x1000, RegionSize);
                waveBuffers[k].IsSendToAudioProcessor = true;
                waveBuffers[k].ContextAddressInfo.Setup(0, 0);
            }

            voice.DataSourceStateAddressInfo.Setup(DsOld, RegionSize);

            return voice;
        }

        // 本拍的输入包:槽 0 重发池外新址+上下文新址;槽 1 重发池 1 内新址;槽 2 不重发;槽 3 重发但尾样偏移越界(错误段)
        private static WaveBufferInternal[] MakeInputs()
        {
            WaveBufferInternal[] inputs = new WaveBufferInternal[SlotsPerVoice];

            inputs[0] = new WaveBufferInternal
            {
                Address = A0New,
                Size = RegionSize,
                StartSampleOffset = 0,
                EndSampleOffset = 0x40,
                SentToServer = false,
                ContextAddress = CtxNew,
                ContextSize = RegionSize,
            };

            inputs[1] = new WaveBufferInternal
            {
                Address = A1New,
                Size = RegionSize,
                StartSampleOffset = 0,
                EndSampleOffset = 0x40,
                SentToServer = false,
                ContextAddress = 0,
                ContextSize = 0,
            };

            inputs[2] = new WaveBufferInternal
            {
                Address = A2Old,
                Size = RegionSize,
                StartSampleOffset = 0,
                EndSampleOffset = 0x40,
                SentToServer = true,
                ContextAddress = 0,
                ContextSize = 0,
            };

            inputs[3] = new WaveBufferInternal
            {
                Address = A0New,
                Size = RegionSize,
                StartSampleOffset = 0,
                EndSampleOffset = 0x100000,   // ADPCM 数据量越界 → InvalidAddressInfo(错误段)
                SentToServer = false,
                ContextAddress = 0,
                ContextSize = 0,
            };

            return inputs;
        }

        private static BehaviourInfo MakeBehaviour()
        {
            BehaviourInfo behaviour = new();

            behaviour.SetUserRevision(BehaviourInfo.BaseRevisionMagic + BehaviourInfo.Revision5);
            behaviour.UpdateFlags(1);   // 强制映射开启(池内挂接、池外双 Map 都走得到)

            return behaviour;
        }

        private static string ErrorText(List<ErrorInfo> errors)
        {
            List<string> parts = new();

            foreach (ErrorInfo error in errors)
            {
                parts.Add($"{error.ErrorCode}:0x{error.ExtraErrorInfo:x}");
            }

            return string.Join("、", parts);
        }

        // oracle:今天的串行序——拍先翻转,Update 一次跑成(isValid=翻转后的值,全程一把、无重演)
        private static unsafe Run RunSerial(bool slot0Valid)
        {
            Run run = new();

            _hooks.Clear();
            S2AAudioPoolResident.Hook = &Capture;

            try
            {
                Memory<MemoryPoolInfo> pools = MakePools();

                PoolMapper mapper = new(0, pools, true);

                BehaviourInfo behaviour = MakeBehaviour();

                VoiceInfo voice = MakeVoice();
                WaveBufferInternal[] inputs = MakeInputs();

                bool[] isValid = { slot0Valid, true, false, true };

                // 数据源状态改址重挂(UpdateParameters2 的挂接步)
                voice.DataSourceStateUnmapped = !mapper.TryAttachBuffer(out ErrorInfo dsError, ref voice.DataSourceStateAddressInfo, DsNew, RegionSize);

                if (dsError.ErrorCode != ResultCode.Success)
                {
                    run.Errors.Add(dsError);
                }

                for (int k = 0; k < SlotsPerVoice; k++)
                {
                    WaveBufferInternal input = inputs[k];

                    VoiceInfo.S2AUpdateWaveBuffer(
                        run.Errors,
                        ref voice.WaveBuffers[k],
                        ref input,
                        SampleFormat.Adpcm,
                        isValid[k],
                        mapper,
                        ref behaviour,
                        ref voice.BufferInfoUnmapped);
                }

                run.Voice = voice;
                run.Hooks.AddRange(_hooks);
            }
            finally
            {
                S2AAudioPoolResident.Hook = null;
            }

            return run;
        }

        // 拆分:解析段(锁1 快照基底、isValid=快照读数、录制 hook)+ 锁2a 复核翻转重演 + 日志重放 + 错误暂存恰一次入队
        private static unsafe Run RunSplit(bool slot0Flipped)
        {
            Run run = new();

            VoiceInfo snapshot = MakeVoice();   // 锁1 快照(重演基底,处方①)
            WaveBufferInternal[] inputs = MakeInputs();

            // ---- 解析段(锁外):录制 mapper ----
            S2AHookLog log = new(64);

            Memory<MemoryPoolInfo> pools = MakePools();

            PoolMapper parseMapper = new(0, pools, true);
            parseMapper.S2ALog = log;

            BehaviourInfo behaviour = MakeBehaviour();

            VoiceInfo shadow = snapshot;   // 影子 = 快照拷(解析段的工作拷;基底语义同快照)

            List<ErrorInfo> stash = new();   // 处方③:错误暂存(数据源 + 四槽,按序)
            bool[] bufferUnmappedIn = new bool[SlotsPerVoice];
            int[] slotHookStart = new int[SlotsPerVoice];
            int[] slotHookEnd = new int[SlotsPerVoice];

            int dsHookStart = log.Count;

            shadow.DataSourceStateUnmapped = !parseMapper.TryAttachBuffer(out ErrorInfo dsError, ref shadow.DataSourceStateAddressInfo, DsNew, RegionSize);

            if (dsError.ErrorCode != ResultCode.Success)
            {
                stash.Add(dsError);
            }

            for (int k = 0; k < SlotsPerVoice; k++)
            {
                slotHookStart[k] = log.Count;
                bufferUnmappedIn[k] = shadow.BufferInfoUnmapped;

                WaveBufferInternal input = inputs[k];

                VoiceInfo.S2AUpdateWaveBuffer(
                    stash,
                    ref shadow.WaveBuffers[k],
                    ref input,
                    SampleFormat.Adpcm,
                    SnapshotIsValid[k],
                    parseMapper,
                    ref behaviour,
                    ref shadow.BufferInfoUnmapped);

                slotHookEnd[k] = log.Count;
            }

            // ---- 锁2a:落账 ----
            _hooks.Clear();
            S2AAudioPoolResident.Hook = &Capture;

            try
            {
                PoolMapper commitMapper = new(0, pools, true);   // 落账段立即执行(复核重演的 ForceUnmap)

                VoiceInfo live = snapshot;   // live = 锁1 基底(本场景中拍只翻 isValid,不改 VoiceInfo)

                // 数据源状态槽落账(解析段挂接结果拷回 + hook 在四槽之前重放,今天的段内顺序)
                live.DataSourceStateAddressInfo = shadow.DataSourceStateAddressInfo;
                live.DataSourceStateUnmapped = shadow.DataSourceStateUnmapped;

                log.Replay(dsHookStart, slotHookStart[0], 0);

                List<ErrorInfo> replayErrors = new();   // 重演错误:与解析段暂存的同一条,丢弃(处方③)

                for (int k = 0; k < SlotsPerVoice; k++)
                {
                    bool liveValid = (k == 0) ? !slot0Flipped : SnapshotIsValid[k];

                    // 生产落账同一份(AudioRenderSystem.S2ACommitWaveSlot):本测试只造输入与 oracle,不另拼落账流程
                    S2AUpdateShadow.VoiceSlotRecord slot = new()
                    {
                        IsValid = SnapshotIsValid[k],
                        BufferUnmappedIn = bufferUnmappedIn[k],
                        SampleFormat = SampleFormat.Adpcm,
                        Input = inputs[k],
                        HookStart = slotHookStart[k],
                    };

                    AudioRenderSystem.S2ACommitWaveSlot(liveValid, ref slot, ref live.WaveBuffers[k], ref shadow.WaveBuffers[k], snapshot.WaveBuffers[k],
                        commitMapper, ref behaviour, replayErrors, log, slotHookEnd[k], 0);
                }

                // 错误段(处方③:暂存表恰一次原序入队——不是双份)
                run.Errors.AddRange(stash);

                run.Voice = live;
                run.Hooks.AddRange(_hooks);
            }
            finally
            {
                S2AAudioPoolResident.Hook = null;
            }

            return run;
        }

        // 槽终值文本(地址/尺寸/强制映射地址/池表内址/送 DSP 标志/样偏移)
        private static unsafe string SlotText(ref WaveBuffer slot)
        {
            string pool = "0";

            if (slot.BufferAddressInfo.S2AMemoryPoolPointer != 0)
            {
                pool = $"pool@0x{(*(MemoryPoolInfo*)slot.BufferAddressInfo.S2AMemoryPoolPointer).CpuAddress:x}";
            }

            return $"[{slot.BufferAddressInfo.CpuAddress:x}/{slot.BufferAddressInfo.Size:x} dsp={slot.BufferAddressInfo.ForceMappedDspAddress:x} {pool} sent={slot.IsSendToAudioProcessor} {slot.StartSampleOffset}..{slot.EndSampleOffset}]";
        }

        private static string CtxText(ref WaveBuffer slot)
        {
            return $"[{slot.ContextAddressInfo.CpuAddress:x}/{slot.ContextAddressInfo.Size:x} dsp={slot.ContextAddressInfo.ForceMappedDspAddress:x}]";
        }

        // D-ARWS-P(#12/#13 拆分 · 终审 mustFix 1/4): 池段驻留钩的录放——带 Hook 捕获。
        //   解析段(AudioRenderSystem.S2AParseMemoryPools,与今天 UpdateMemoryPools 逐行同体)在影子池表上逐池
        //   记 hook 起点、attach/detach 钩进日志;落账(S2ACommitMemoryPools)逐池重放。
        //   场景一:三池——p0 重挂新址(Map 钩)、p1 退驻留(Unmap 钩)、p2 退驻留但中拍已把活池标在用 → 复核拒绝
        //   (保留活映射、不重放其 Unmap 钩,mustFix 4;解析段 detach 判据吃锁1 快照的 IsUsed,活值复核在落账补)。
        //   场景二:三池全不在用 → 三条钩全部重放(池段驻留钩确实被重放,mustFix 1 的回归:段标漏赋会让池段
        //   钩重放变空区间、钩全部丢失,真宿主挂 Hook 时池区永不驻留锁页 / detach 永不退驻留)。
        [SoloTest("--audio-renderer-pool-hook-replay")]
        private static unsafe int CheckPoolHookReplay()
        {
            int bad = 0;

            void Row(string name, string expect, string actual, bool ok)
            {
                bad += ok ? 0 : 1;

                Console.WriteLine($"{(ok ? "✓" : "✗")} 池段钩重放 {name}:{expect} → {actual}");
            }

            string PoolText(ref MemoryPoolInfo pool) => $"[{pool.CpuAddress:x}/{pool.Size:x} dsp={pool.DspAddress:x} used={pool.IsUsed}]";

            // 输入包:三池各一条参数(p0 重挂、p1 退、p2 退)
            byte[] MakeInput(ulong a0, ulong a1, ulong a2, ulong size)
            {
                byte[] data = new byte[3 * Unsafe.SizeOf<MemoryPoolInParameter>()];

                (ulong address, MemoryPoolUserState state)[] rows =
                {
                    (a0, MemoryPoolUserState.RequestAttach),
                    (a1, MemoryPoolUserState.RequestDetach),
                    (a2, MemoryPoolUserState.RequestDetach),
                };

                for (int i = 0; i < 3; i++)
                {
                    MemoryPoolInParameter parameter = new()
                    {
                        CpuAddress = rows[i].address,
                        Size = size,
                        State = rows[i].state,
                    };

                    MemoryMarshal.Write(data.AsSpan(i * Unsafe.SizeOf<MemoryPoolInParameter>()), in parameter);
                }

                return data;
            }

            void Run(bool pool2UsedAtCommit, out string poolsText, out string hooksText, out string outText)
            {
                ulong x0 = 0x1000_0000, x1 = 0x1000_2000, x2 = 0x1000_4000, attach = 0x2000_0000;
                const ulong size = 0x1000;

                // 锁1 快照:影子池表 = 活池表(三池都挂址、都不在用;IsUsed 按锁1 口径拷)
                MemoryPoolInfo[] shadowPools = new MemoryPoolInfo[3];
                MemoryPoolInfo[] livePools = new MemoryPoolInfo[3];

                for (int i = 0; i < 3; i++)
                {
                    shadowPools[i] = MemoryPoolInfo.Create(MemoryPoolInfo.LocationType.Cpu);
                    shadowPools[i].SetCpuAddress(x0 + (ulong)i * 0x2000, size);
                    livePools[i] = shadowPools[i];
                }

                S2AHookLog log = new(16);
                int[] poolHookStart = new int[3];

                PoolMapper mapper = new(0, true);
                mapper.S2ALog = log;

                SequenceReader<byte> reader = new(new ReadOnlySequence<byte>(MakeInput(attach, x1, x2, size)));
                Memory<byte> outCursor = new byte[3 * Unsafe.SizeOf<MemoryPoolOutStatus>()];
                UpdateDataHeader inputHeader = new() { MemoryPoolsSize = (uint)(3 * Unsafe.SizeOf<MemoryPoolInParameter>()) };
                UpdateDataHeader outputHeader = new();

                // 解析段(锁外):录制 + 逐池 hook 起点
                ResultCode rc = AudioRenderSystem.S2AParseMemoryPools(
                    ref reader, ref outCursor, shadowPools, poolHookStart, mapper, log, in inputHeader, ref outputHeader);

                // 落账段(锁2a):Hook 捕获 + 逐池重放 + detach 复核(p2 中拍标在用)
                if (pool2UsedAtCommit)
                {
                    livePools[2].IsUsed = true;   // 中拍(渲染拍命令生成 GetReference(true) 重标记)
                }

                _hooks.Clear();
                S2AAudioPoolResident.Hook = &Capture;

                try
                {
                    AudioRenderSystem.S2ACommitMemoryPools(livePools, shadowPools, log, poolHookStart, log.Count, 0);
                }
                finally
                {
                    S2AAudioPoolResident.Hook = null;
                }

                poolsText = $"{PoolText(ref livePools[0])} {PoolText(ref livePools[1])} {PoolText(ref livePools[2])}";
                hooksText = string.Join(" → ", _hooks);
                outText = $"rc={rc}";
            }

            // 场景一:p2 复核拒绝(保留活映射、跳过其 Unmap 钩)
            Run(pool2UsedAtCommit: true, out string pools1, out string hooks1, out string rc1);

            // p2 复核拒绝:活池原样保留(CpuAddress/Size/DspAddress(夹具未映射=0)/IsUsed 全不动,拒绝即 continue)
            Row("复核拒绝的三池终值", "[20000000/1000 dsp=20000000 used=False] [0/0 dsp=0 used=False] [10004000/1000 dsp=0 used=True]", pools1,
                pools1 == "[20000000/1000 dsp=20000000 used=False] [0/0 dsp=0 used=False] [10004000/1000 dsp=0 used=True]");

            Row("复核拒绝的钩序列", "Map 0x20000000/0x1000 → Unmap 0x10002000/0x1000", hooks1,
                hooks1 == "Map 0x20000000/0x1000 → Unmap 0x10002000/0x1000");

            // 场景二:全不在用 → 三条钩全部重放(池段钩确实被重放,mustFix 1 回归)
            Run(pool2UsedAtCommit: false, out string pools2, out string hooks2, out string rc2);

            Row("全放行的三池终值", "[20000000/1000 dsp=20000000 used=False] [0/0 dsp=0 used=False] [0/0 dsp=0 used=False]", pools2,
                pools2 == "[20000000/1000 dsp=20000000 used=False] [0/0 dsp=0 used=False] [0/0 dsp=0 used=False]");

            Row("全放行的钩序列", "Map 0x20000000/0x1000 → Unmap 0x10002000/0x1000 → Unmap 0x10004000/0x1000", hooks2,
                hooks2 == "Map 0x20000000/0x1000 → Unmap 0x10002000/0x1000 → Unmap 0x10004000/0x1000");

            Row("解析返回", "rc=Success", rc1 + " " + rc2, rc1 == "rc=Success" && rc2 == "rc=Success");

            return bad;
        }

        // D-ARWS-PP(#12/#13 拆分 · 终审:池段失败路径的陈旧 PoolHookStart 尾巴): 更新 N 只挂迟位池(池 6),
        //   更新 N+1 早位池 0..4 各挂、池 5 参数非法段中失败——池 6/7 未达保留上一更新的陈旧下标 [0,1],
        //   池段失败 ParseStop=2 落账照跑,未达池的陈旧区间非空时把前缀里别的池的驻留钩重放第二遍
        //   (探针实测:重放 6 条、池 0 的 Map 被池 6 的陈旧区间重放两遍,基线恰 5 条)。
        //   修复 = 解析循环入口先把整表填本段起点(Array.Fill,零分配),未达池区间恒空 → 恰 5 条各一次。
        [SoloTest("--audio-renderer-pool-hook-failprefix")]
        private static unsafe int CheckPoolHookFailurePrefix()
        {
            int bad = 0;

            void Row(string name, string expect, string actual, bool ok)
            {
                bad += ok ? 0 : 1;

                Console.WriteLine($"{(ok ? "✓" : "✗")} 池段失败前缀 {name}:{expect} → {actual}");
            }

            const int PoolCount = 8;
            const ulong Size = 0x1000;
            const ulong AttachBase = 0x2000_0000;

            // 锁1 快照口径:八池全挂址、不在用
            MemoryPoolInfo[] shadowPools = new MemoryPoolInfo[PoolCount];
            MemoryPoolInfo[] livePools = new MemoryPoolInfo[PoolCount];

            for (int i = 0; i < PoolCount; i++)
            {
                shadowPools[i] = MemoryPoolInfo.Create(MemoryPoolInfo.LocationType.Cpu);
                shadowPools[i].SetCpuAddress(0x1000_0000 + (ulong)i * 0x2000, Size);
                livePools[i] = shadowPools[i];
            }

            int[] poolHookStart = new int[PoolCount];

            // 输入包:每池一行;非法行 = RequestAttach + 不页对齐地址(段中 InvalidParameter);无操作行 = Invalid
            byte[] MakeInput((ulong address, MemoryPoolUserState state)[] rows)
            {
                byte[] data = new byte[PoolCount * Unsafe.SizeOf<MemoryPoolInParameter>()];

                for (int i = 0; i < PoolCount; i++)
                {
                    MemoryPoolInParameter parameter = new()
                    {
                        CpuAddress = rows[i].address,
                        Size = Size,
                        State = rows[i].state,
                    };

                    MemoryMarshal.Write(data.AsSpan(i * Unsafe.SizeOf<MemoryPoolInParameter>()), in parameter);
                }

                return data;
            }

            (ulong, MemoryPoolUserState) Noop() => (0, MemoryPoolUserState.Invalid);

            // ---- 更新 N:只有池 6 重挂新址(此后 poolHookStart=[0,0,0,0,0,0,0,1],陈旧值的源头) ----
            (ulong, MemoryPoolUserState)[] rowsN =
            {
                Noop(), Noop(), Noop(), Noop(), Noop(), Noop(),
                (AttachBase + 6 * 0x1000, MemoryPoolUserState.RequestAttach),
                Noop(),
            };

            S2AHookLog logN = new(16);

            PoolMapper mapperN = new(0, true);
            mapperN.S2ALog = logN;

            {
                SequenceReader<byte> reader = new(new ReadOnlySequence<byte>(MakeInput(rowsN)));
                Memory<byte> outCursor = new byte[PoolCount * Unsafe.SizeOf<MemoryPoolOutStatus>()];
                UpdateDataHeader inputHeader = new() { MemoryPoolsSize = (uint)(PoolCount * Unsafe.SizeOf<MemoryPoolInParameter>()) };
                UpdateDataHeader outputHeader = new();

                ResultCode rc = AudioRenderSystem.S2AParseMemoryPools(
                    ref reader, ref outCursor, shadowPools, poolHookStart, mapperN, logN, in inputHeader, ref outputHeader);

                Row("更新N解析", "rc=Success", $"rc={rc}", rc == ResultCode.Success);
            }

            _hooks.Clear();
            S2AAudioPoolResident.Hook = &Capture;

            try
            {
                AudioRenderSystem.S2ACommitMemoryPools(livePools, shadowPools, logN, poolHookStart, voicesHookStart: logN.Count, 0);
            }
            finally
            {
                S2AAudioPoolResident.Hook = null;
            }

            Row("更新N钩", "Map 0x20006000/0x1000", string.Join(" → ", _hooks),
                string.Join(" → ", _hooks) == "Map 0x20006000/0x1000");

            // ---- 更新 N+1:池 0..4 各挂新址(5 钩)、池 5 参数非法段中失败(池 6/7 未达) ----
            for (int i = 0; i < PoolCount; i++)
            {
                shadowPools[i] = livePools[i];   // 下一拍的锁1 快照(拷自更新 N 落账后的活池)
            }

            (ulong, MemoryPoolUserState)[] rowsM =
            {
                (AttachBase + 0x10000, MemoryPoolUserState.RequestAttach),
                (AttachBase + 0x11000, MemoryPoolUserState.RequestAttach),
                (AttachBase + 0x12000, MemoryPoolUserState.RequestAttach),
                (AttachBase + 0x13000, MemoryPoolUserState.RequestAttach),
                (AttachBase + 0x14000, MemoryPoolUserState.RequestAttach),
                (0x1001, MemoryPoolUserState.RequestAttach),   // 不页对齐 → InvalidParameter,段中失败
                Noop(),
                Noop(),
            };

            S2AHookLog logM = new(16);

            PoolMapper mapperM = new(0, true);
            mapperM.S2ALog = logM;

            ResultCode rcM;

            {
                SequenceReader<byte> reader = new(new ReadOnlySequence<byte>(MakeInput(rowsM)));
                Memory<byte> outCursor = new byte[PoolCount * Unsafe.SizeOf<MemoryPoolOutStatus>()];
                UpdateDataHeader inputHeader = new() { MemoryPoolsSize = (uint)(PoolCount * Unsafe.SizeOf<MemoryPoolInParameter>()) };
                UpdateDataHeader outputHeader = new();

                rcM = AudioRenderSystem.S2AParseMemoryPools(
                    ref reader, ref outCursor, shadowPools, poolHookStart, mapperM, logM, in inputHeader, ref outputHeader);
            }

            Row("更新N+1解析", "rc=InvalidUpdateInfo", $"rc={rcM}", rcM == ResultCode.InvalidUpdateInfo);

            // 落账(ParseStop=2 前缀照落;voicesHookStart 按失败路径的 0 口径——段标只在段成后才赋)
            _hooks.Clear();
            S2AAudioPoolResident.Hook = &Capture;

            try
            {
                AudioRenderSystem.S2ACommitMemoryPools(livePools, shadowPools, logM, poolHookStart, voicesHookStart: 0, 0);
            }
            finally
            {
                S2AAudioPoolResident.Hook = null;
            }

            // 基线 = 恰 5 条各一次;陈旧尾巴会把池 0 的 Map 重放第二遍(6 条)
            string expect =
                "Map 0x20010000/0x1000 → Map 0x20011000/0x1000 → Map 0x20012000/0x1000 → Map 0x20013000/0x1000 → Map 0x20014000/0x1000";

            Row("失败前缀钩恰 5 条", expect, string.Join(" → ", _hooks), string.Join(" → ", _hooks) == expect);

            return bad;
        }

        [SoloTest("--audio-renderer-wave-slot-replay")]
        private static int Check()
        {
            int bad = 0;

            void Row(string name, string expect, string actual, bool ok)
            {
                bad += ok ? 0 : 1;

                Console.WriteLine($"{(ok ? "✓" : "✗")} 波表重演 {name}:{expect} → {actual}");
            }

            try
            {
                // ---- 场景一:中拍翻转 + 同拍重发(流式声音常见拍)----
                Run oracle = RunSerial(slot0Valid: false);
                Run split = RunSplit(slot0Flipped: true);

                // ① 九槽终值
                Row("数据源状态槽", oracle.Voice.DataSourceStateAddressInfo.CpuAddress.ToString("x"),
                    split.Voice.DataSourceStateAddressInfo.CpuAddress.ToString("x"),
                    oracle.Voice.DataSourceStateAddressInfo.CpuAddress == split.Voice.DataSourceStateAddressInfo.CpuAddress
                    && oracle.Voice.DataSourceStateAddressInfo.ForceMappedDspAddress == split.Voice.DataSourceStateAddressInfo.ForceMappedDspAddress
                    && oracle.Voice.DataSourceStateUnmapped == split.Voice.DataSourceStateUnmapped);

                for (int k = 0; k < SlotsPerVoice; k++)
                {
                    string o = SlotText(ref oracle.Voice.WaveBuffers[k]);
                    string s = SlotText(ref split.Voice.WaveBuffers[k]);

                    Row($"波表 {k} 本体槽", o, s, o == s);

                    string oc = CtxText(ref oracle.Voice.WaveBuffers[k]);
                    string sc = CtxText(ref split.Voice.WaveBuffers[k]);

                    Row($"波表 {k} 上下文槽", oc, sc, oc == sc);
                }

                Row("bufferUnmapped", oracle.Voice.BufferInfoUnmapped.ToString(), split.Voice.BufferInfoUnmapped.ToString(),
                    oracle.Voice.BufferInfoUnmapped == split.Voice.BufferInfoUnmapped);

                // ② hook 日志时序(处方②:翻转槽 [Unmap(A_old 池) → Map×2(A_new) → Map×2(上下文)])
                string oh = string.Join(" → ", oracle.Hooks);
                string sh = string.Join(" → ", split.Hooks);

                Row("hook 日志", oh, sh, oh == sh);

                // ③ 错误段(处方③:恰一次、原序——槽 3 的尾样偏移越界错恰一条,重演不重复入队)
                string oe = ErrorText(oracle.Errors);
                string se = ErrorText(split.Errors);

                Row("错误段", oe, se, oe == se);

                // ---- 场景二:无交错(不翻转)——拆分终值 = 今天 isValid=快照读数一次跑成的终值 ----
                Run oracle2 = RunSerial(slot0Valid: true);
                Run split2 = RunSplit(slot0Flipped: false);

                bool same = true;

                for (int k = 0; k < SlotsPerVoice; k++)
                {
                    same &= SlotText(ref oracle2.Voice.WaveBuffers[k]) == SlotText(ref split2.Voice.WaveBuffers[k]);
                    same &= CtxText(ref oracle2.Voice.WaveBuffers[k]) == CtxText(ref split2.Voice.WaveBuffers[k]);
                }

                same &= oracle2.Voice.DataSourceStateAddressInfo.CpuAddress == split2.Voice.DataSourceStateAddressInfo.CpuAddress;
                same &= oracle2.Voice.BufferInfoUnmapped == split2.Voice.BufferInfoUnmapped;
                same &= string.Join(" → ", oracle2.Hooks) == string.Join(" → ", split2.Hooks);
                same &= ErrorText(oracle2.Errors) == ErrorText(split2.Errors);

                Row("无交错全程", "与今天串行一致", same ? "一致" : "不一致", same);
            }
            finally
            {
                FreePools();
            }

            return bad;
        }
    }
}
