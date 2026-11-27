using Ryujinx.Audio.Renderer.Common;
using Ryujinx.Audio.Renderer.Parameter;
using Ryujinx.Audio.Renderer.Utils;
using Ryujinx.Common.Logging;
using System;
using System.Diagnostics;
using static Ryujinx.Audio.Renderer.Common.BehaviourParameter;

using CpuAddress = System.UInt64;
using DspAddress = System.UInt64;

namespace Ryujinx.Audio.Renderer.Server.MemoryPool
{
    // S2Arm (#12/#13 拆分 · 渲染拍不等 Update 的锁): guest 驻留 hook 的录制日志。影子解析段(锁外)里本类换到
    //   录制模式:本该在这里发生的 Map/Unmap(AudioProcessorMemoryManager → S2AAudioPoolResident.Hook)不立即执行,
    //   按发生原序记进日志,锁2a 落账段(锁内)重放——unmap 在锁外执行会把 DSP 正在读的区域退驻留
    //   (S2AWiredBuffer.cs:61-66 防的正是这个);Map 也就序成今天时序。容量一次配足、每更新复用(零稳态分配),
    //   Record 的越界丢记只会发生在容量算错时(按池数/声音数/效果数/汇数公式推的上界),Debug.Assert 兜底报红。
    public sealed class S2AHookLog
    {
        public struct Entry
        {
            public bool Map;        // true = Map(驻留),false = Unmap(退驻留)
            public CpuAddress Address;
            public ulong Size;
        }

        private readonly Entry[] _entries;

        public int Count { get; private set; }

        public S2AHookLog(int capacity)
        {
            _entries = new Entry[capacity];
        }

        public void Clear()
        {
            Count = 0;
        }

        public void Record(bool map, CpuAddress address, ulong size)
        {
            Debug.Assert(Count < _entries.Length, "S2AHookLog 容量不足(上界公式漏了哪种挂接?)");

            if (Count < _entries.Length)
            {
                _entries[Count++] = new Entry { Map = map, Address = address, Size = size };
            }
        }

        // 落账段重放 [start, end) 原序执行;handle 与录制时同源(调用方 = 渲染器,hook 只看地址/尺寸/方向)
        public void Replay(int start, int end, uint processHandle)
        {
            if (end > Count)
            {
                end = Count;
            }

            for (int i = start; i < end; i++)
            {
                ref Entry entry = ref _entries[i];

                if (entry.Map)
                {
                    AudioProcessorMemoryManager.Map(processHandle, entry.Address, entry.Size);
                }
                else
                {
                    AudioProcessorMemoryManager.Unmap(processHandle, entry.Address, entry.Size);
                }
            }
        }
    }

    /// <summary>
    /// Memory pool mapping helper.
    /// </summary>
    public class PoolMapper
    {
        const uint CurrentProcessPseudoHandle = 0xFFFF8001;

        // S2Arm (#12/#13 拆分): 影子解析段(锁外)的录制日志;null = 不录制,Map/Unmap 当场执行(与上游一致)。
        //   池表解析(FindMemoryPool)在影子池表(锁1 快照拷贝)上做:池表字段只有游戏线程写,锁外解析无撕裂。
        internal S2AHookLog S2ALog;

        // S2Arm (#12/#13 拆分 · 处方②): 波表翻转重演(锁2a)时抑制重发挂接的 hook——那两次 Map 已在解析段记进
        //   日志、紧接着按原序重放,重演里再执行就是双倍;重演的 ForceUnmap(Unmap(A_old))不抑制,它必须立即执行、
        //   排在该槽重发 Map 之前(今天的时序)。落账后复位
        internal bool S2ASuppressAttachHooks;

        /// <summary>
        /// The result of <see cref="Update(ref MemoryPoolInfo, ref MemoryPoolInParameter, ref MemoryPoolOutStatus)"/>.
        /// </summary>
        public enum UpdateResult : uint
        {
            /// <summary>
            /// No error reported.
            /// </summary>
            Success = 0,

            /// <summary>
            /// The user parameters were invalid.
            /// </summary>
            InvalidParameter = 1,

            /// <summary>
            /// <see cref="Dsp.AudioProcessor"/> mapping failed.
            /// </summary>
            MapError = 2,

            /// <summary>
            /// <see cref="Dsp.AudioProcessor"/> unmapping failed.
            /// </summary>
            UnmapError = 3,
        }

        /// <summary>
        /// The handle of the process owning the CPU memory manipulated.
        /// </summary>
        private readonly uint _processHandle;

        /// <summary>
        /// The <see cref="Memory{MemoryPoolInfo}"/> that will be manipulated.
        /// </summary>
        private readonly Memory<MemoryPoolInfo> _memoryPools;

        /// <summary>
        /// If set to true, this will try to force map memory pool even if their state are considered invalid.
        /// </summary>
        private readonly bool _isForceMapEnabled;

        /// <summary>
        /// Create a new <see cref="PoolMapper"/> used for system mapping.
        /// </summary>
        /// <param name="processHandle">The handle of the process owning the CPU memory manipulated.</param>
        /// <param name="isForceMapEnabled">If set to true, this will try to force map memory pool even if their state are considered invalid.</param>
        public PoolMapper(uint processHandle, bool isForceMapEnabled)
        {
            _processHandle = processHandle;
            _isForceMapEnabled = isForceMapEnabled;
            _memoryPools = Memory<MemoryPoolInfo>.Empty;
        }

        /// <summary>
        /// Create a new <see cref="PoolMapper"/> used for user mapping.
        /// </summary>
        /// <param name="processHandle">The handle of the process owning the CPU memory manipulated.</param>
        /// <param name="memoryPool">The user memory pools.</param>
        /// <param name="isForceMapEnabled">If set to true, this will try to force map memory pool even if their state are considered invalid.</param>
        public PoolMapper(uint processHandle, Memory<MemoryPoolInfo> memoryPool, bool isForceMapEnabled)
        {
            _processHandle = processHandle;
            _memoryPools = memoryPool;
            _isForceMapEnabled = isForceMapEnabled;
        }

        /// <summary>
        /// Initialize the <see cref="MemoryPoolInfo"/> for system use.
        /// </summary>
        /// <param name="memoryPool">The <see cref="MemoryPoolInfo"/> for system use.</param>
        /// <param name="cpuAddress">The <see cref="CpuAddress"/> to assign.</param>
        /// <param name="size">The size to assign.</param>
        /// <returns>Returns true if mapping on the <see cref="Dsp.AudioProcessor"/> succeeded.</returns>
        public bool InitializeSystemPool(ref MemoryPoolInfo memoryPool, CpuAddress cpuAddress, ulong size)
        {
            if (memoryPool.Location != MemoryPoolInfo.LocationType.Dsp)
            {
                return false;
            }

            return InitializePool(ref memoryPool, cpuAddress, size);
        }

        /// <summary>
        /// Initialize the <see cref="MemoryPoolInfo"/>.
        /// </summary>
        /// <param name="memoryPool">The <see cref="MemoryPoolInfo"/>.</param>
        /// <param name="cpuAddress">The <see cref="CpuAddress"/> to assign.</param>
        /// <param name="size">The size to assign.</param>
        /// <returns>Returns true if mapping on the <see cref="Dsp.AudioProcessor"/> succeeded.</returns>
        public bool InitializePool(ref MemoryPoolInfo memoryPool, CpuAddress cpuAddress, ulong size)
        {
            memoryPool.SetCpuAddress(cpuAddress, size);

            return Map(ref memoryPool) != 0;
        }

        /// <summary>
        /// Get the process handle associated to the <see cref="MemoryPoolInfo"/>.
        /// </summary>
        /// <param name="memoryPool">The <see cref="MemoryPoolInfo"/>.</param>
        /// <returns>Returns the process handle associated to the <see cref="MemoryPoolInfo"/>.</returns>
        public uint GetProcessHandle(ref MemoryPoolInfo memoryPool)
        {
            if (memoryPool.Location == MemoryPoolInfo.LocationType.Cpu)
            {
                return CurrentProcessPseudoHandle;
            }

            if (memoryPool.Location == MemoryPoolInfo.LocationType.Dsp)
            {
                return _processHandle;
            }

            return 0;
        }

        /// <summary>
        /// Map the <see cref="MemoryPoolInfo"/> on the <see cref="Dsp.AudioProcessor"/>.
        /// </summary>
        /// <param name="memoryPool">The <see cref="MemoryPoolInfo"/> to map.</param>
        /// <returns>Returns the DSP address mapped.</returns>
        public DspAddress Map(ref MemoryPoolInfo memoryPool)
        {
            CpuAddress cpuAddress = memoryPool.CpuAddress;
            ulong size = memoryPool.Size;

            // S2Arm (#12/#13 拆分): 录制模式只记 hook、不执行;返回值与 DspAddress 置位走 Map 的确定结果(地址原样),
            //   影子池表落账时一并拷回
            if (S2ALog != null)
            {
                S2ALog.Record(map: true, cpuAddress, size);

                memoryPool.DspAddress = cpuAddress;

                return cpuAddress;
            }

            DspAddress result = AudioProcessorMemoryManager.Map(GetProcessHandle(ref memoryPool), cpuAddress, size);

            if (result != 0)
            {
                memoryPool.DspAddress = result;
            }

            return result;
        }

        /// <summary>
        /// Unmap the <see cref="MemoryPoolInfo"/> from the <see cref="Dsp.AudioProcessor"/>.
        /// </summary>
        /// <param name="memoryPool">The <see cref="MemoryPoolInfo"/> to unmap.</param>
        /// <returns>Returns true if unmapped.</returns>
        public bool Unmap(ref MemoryPoolInfo memoryPool)
        {
            if (memoryPool.IsUsed)
            {
                return false;
            }

            if (S2ALog != null)
            {
                // S2Arm (#12/#13 拆分): 记 hook 不执行,落账段重放;池表状态照写在影子上,落账拷回
                S2ALog.Record(map: false, memoryPool.CpuAddress, memoryPool.Size);
            }
            else
            {
                AudioProcessorMemoryManager.Unmap(GetProcessHandle(ref memoryPool), memoryPool.CpuAddress, memoryPool.Size);
            }

            memoryPool.SetCpuAddress(0, 0);
            memoryPool.DspAddress = 0;

            return true;
        }

        /// <summary>
        /// Find a <see cref="MemoryPoolInfo"/> associated to the region given.
        /// </summary>
        /// <param name="cpuAddress">The region <see cref="CpuAddress"/>.</param>
        /// <param name="size">The region size.</param>
        /// <returns>Returns the <see cref="MemoryPoolInfo"/> found or <see cref="Memory{MemoryPoolInfo}.Empty"/> if not found.</returns>
        private Span<MemoryPoolInfo> FindMemoryPool(CpuAddress cpuAddress, ulong size)
        {
            if (!_memoryPools.IsEmpty && _memoryPools.Length > 0)
            {
                for (int i = 0; i < _memoryPools.Length; i++)
                {
                    if (_memoryPools.Span[i].Contains(cpuAddress, size))
                    {
                        return _memoryPools.Span.Slice(i, 1);
                    }
                }
            }

            return Span<MemoryPoolInfo>.Empty;
        }

        /// <summary>
        /// Force unmap the given <see cref="AddressInfo"/>.
        /// </summary>
        /// <param name="addressInfo">The <see cref="AddressInfo"/> to force unmap</param>
        public void ForceUnmap(ref AddressInfo addressInfo)
        {
            if (_isForceMapEnabled)
            {
                Span<MemoryPoolInfo> memoryPool = FindMemoryPool(addressInfo.CpuAddress, addressInfo.Size);

                if (!memoryPool.IsEmpty)
                {
                    if (S2ALog != null)
                    {
                        // S2Arm (#12/#13 拆分): 记 hook 不执行(解析段在锁外,unmap 落账段才执行);解析用的是影子池表
                        S2ALog.Record(map: false, memoryPool[0].CpuAddress, memoryPool[0].Size);
                    }
                    else
                    {
                        AudioProcessorMemoryManager.Unmap(_processHandle, memoryPool[0].CpuAddress, memoryPool[0].Size);
                    }

                    return;
                }

                if (S2ALog != null)
                {
                    S2ALog.Record(map: false, addressInfo.CpuAddress, 0);
                }
                else
                {
                    AudioProcessorMemoryManager.Unmap(_processHandle, addressInfo.CpuAddress, 0);
                }
            }
        }

        /// <summary>
        /// Try to attach the given region to the <see cref="AddressInfo"/>.
        /// </summary>
        /// <param name="errorInfo">The error information if an error was generated.</param>
        /// <param name="addressInfo">The <see cref="AddressInfo"/> to attach the region to.</param>
        /// <param name="cpuAddress">The region <see cref="CpuAddress"/>.</param>
        /// <param name="size">The region size.</param>
        /// <returns>Returns true if mapping was performed.</returns>
        public bool TryAttachBuffer(out ErrorInfo errorInfo, ref AddressInfo addressInfo, CpuAddress cpuAddress, ulong size)
        {
            errorInfo = new ErrorInfo();

            addressInfo.Setup(cpuAddress, size);

            if (AssignDspAddress(ref addressInfo))
            {
                errorInfo.ErrorCode = 0x0;
                errorInfo.ExtraErrorInfo = 0x0;

                return true;
            }

            errorInfo.ErrorCode = ResultCode.InvalidAddressInfo;
            errorInfo.ExtraErrorInfo = addressInfo.CpuAddress;

            return _isForceMapEnabled;
        }

        /// <summary>
        /// Update a <see cref="MemoryPoolInfo"/> using user parameters.
        /// </summary>
        /// <param name="memoryPool">The <see cref="MemoryPoolInfo"/> to update.</param>
        /// <param name="inParameter">Input user parameter.</param>
        /// <param name="outStatus">Output user parameter.</param>
        /// <returns>Returns the <see cref="UpdateResult"/> of the operations performed.</returns>
        public UpdateResult Update(ref MemoryPoolInfo memoryPool, in MemoryPoolInParameter inParameter, ref MemoryPoolOutStatus outStatus)
        {
            MemoryPoolUserState inputState = inParameter.State;

            MemoryPoolUserState outputState;

            const uint PageSize = 0x1000;

            if (inputState is not MemoryPoolUserState.RequestAttach and not MemoryPoolUserState.RequestDetach)
            {
                return UpdateResult.Success;
            }

            if (inParameter.CpuAddress == 0 || (inParameter.CpuAddress % PageSize) != 0)
            {
                return UpdateResult.InvalidParameter;
            }

            if (inParameter.Size == 0 || (inParameter.Size % PageSize) != 0)
            {
                return UpdateResult.InvalidParameter;
            }

            if (inputState == MemoryPoolUserState.RequestAttach)
            {
                bool initializeSuccess = InitializePool(ref memoryPool, inParameter.CpuAddress, inParameter.Size);

                if (!initializeSuccess)
                {
                    memoryPool.SetCpuAddress(0, 0);

                    Logger.Error?.Print(LogClass.AudioRenderer, $"Map of memory pool (address: 0x{inParameter.CpuAddress:x}, size 0x{inParameter.Size:x}) failed!");
                    return UpdateResult.MapError;
                }

                outputState = MemoryPoolUserState.Attached;
            }
            else
            {
                if (memoryPool.CpuAddress != inParameter.CpuAddress || memoryPool.Size != inParameter.Size)
                {
                    return UpdateResult.InvalidParameter;
                }

                if (!Unmap(ref memoryPool))
                {
                    Logger.Error?.Print(LogClass.AudioRenderer, $"Unmap of memory pool (address: 0x{memoryPool.CpuAddress:x}, size 0x{memoryPool.Size:x}) failed!");
                    return UpdateResult.UnmapError;
                }

                outputState = MemoryPoolUserState.Detached;
            }

            outStatus.State = outputState;

            return UpdateResult.Success;
        }

        /// <summary>
        /// Map the <see cref="AddressInfo"/> to the <see cref="Dsp.AudioProcessor"/>.
        /// </summary>
        /// <param name="addressInfo">The <see cref="AddressInfo"/> to map.</param>
        /// <returns>Returns true if mapping was performed.</returns>
        private bool AssignDspAddress(ref AddressInfo addressInfo)
        {
            if (addressInfo.CpuAddress == 0)
            {
                return false;
            }

            if (_memoryPools.Length > 0)
            {
                Span<MemoryPoolInfo> memoryPool = FindMemoryPool(addressInfo.CpuAddress, addressInfo.Size);

                if (!memoryPool.IsEmpty)
                {
                    addressInfo.SetupMemoryPool(memoryPool);

                    return true;
                }
            }

            if (_isForceMapEnabled)
            {
                if (S2ASuppressAttachHooks)
                {
                    // S2Arm (#12/#13 拆分 · 处方②): 波表翻转重演——重发挂接的 hook 已在日志里待重放,这里只做状态
                    addressInfo.ForceMappedDspAddress = addressInfo.CpuAddress;
                }
                // S2Arm (#12/#13 拆分): 录制模式记双 Map(今天本样:AssignDspAddress 强制映射路径对同一区域 Map 两次,
                //   落账段按原序重放两次),ForceMappedDspAddress 走 Map 的确定结果(地址原样)
                else if (S2ALog != null)
                {
                    S2ALog.Record(map: true, addressInfo.CpuAddress, addressInfo.Size);
                    S2ALog.Record(map: true, addressInfo.CpuAddress, addressInfo.Size);

                    addressInfo.ForceMappedDspAddress = addressInfo.CpuAddress;
                }
                else
                {
                    DspAddress dspAddress = AudioProcessorMemoryManager.Map(_processHandle, addressInfo.CpuAddress, addressInfo.Size);

                    addressInfo.ForceMappedDspAddress = dspAddress;

                    AudioProcessorMemoryManager.Map(_processHandle, addressInfo.CpuAddress, addressInfo.Size);
                }
            }
            else
            {
                unsafe
                {
                    addressInfo.SetupMemoryPool(MemoryPoolInfo.Null);
                }
            }

            return false;
        }

        /// <summary>
        /// Remove the usage flag from all the <see cref="MemoryPoolInfo"/>.
        /// </summary>
        /// <param name="memoryPool">The <see cref="Memory{MemoryPoolInfo}"/> to reset.</param>
        public static void ClearUsageState(Memory<MemoryPoolInfo> memoryPool)
        {
            foreach (ref MemoryPoolInfo info in memoryPool.Span)
            {
                info.IsUsed = false;
            }
        }
    }
}
