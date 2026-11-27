using Ryujinx.Audio.Renderer.Common;
using Ryujinx.Audio.Renderer.Parameter;
using Ryujinx.Audio.Renderer.Server.MemoryPool;
using Ryujinx.Audio.Renderer.Utils;
using System;
using System.Diagnostics;
using static Ryujinx.Audio.Renderer.Common.BehaviourParameter;

using DspAddress = System.UInt64;

namespace Ryujinx.Audio.Renderer.Server.Effect
{
    /// <summary>
    /// Base class used as a server state for an effect.
    /// </summary>
    public class BaseEffect
    {
        // S2Arm 即时存档：恢复后让带 DSP 状态的效果在下一拍按参数重新初始化状态（托管状态不随渲染器缓冲拷回）
        public virtual void S2AForceReinit() { }

        /// <summary>
        /// The <see cref="EffectType"/> of the effect.
        /// </summary>
        public EffectType Type;

        /// <summary>
        /// Set to true if the effect must be active.
        /// </summary>
        public bool IsEnabled;

        /// <summary>
        /// Set to true if the internal effect work buffers used wasn't mapped.
        /// </summary>
        public bool BufferUnmapped;

        /// <summary>
        /// The current state of the effect.
        /// </summary>
        public UsageState UsageState;

        /// <summary>
        /// The target mix id of the effect.
        /// </summary>
        public int MixId;

        /// <summary>
        /// Position of the effect while processing effects.
        /// </summary>
        public uint ProcessingOrder;

        /// <summary>
        /// Array of all the work buffer used by the effect.
        /// </summary>
        protected AddressInfo[] WorkBuffers;

        /// <summary>
        /// Create a new <see cref="BaseEffect"/>.
        /// </summary>
        public BaseEffect()
        {
            Type = TargetEffectType;
            UsageState = UsageState.Invalid;

            IsEnabled = false;
            BufferUnmapped = false;
            MixId = Constants.UnusedMixId;
            ProcessingOrder = uint.MaxValue;

            WorkBuffers = new AddressInfo[2];

            foreach (ref AddressInfo info in WorkBuffers.AsSpan())
            {
                info = AddressInfo.Create();
            }
        }

        /// <summary>
        /// The target <see cref="EffectType"/> handled by this <see cref="BaseEffect"/>.
        /// </summary>
        public virtual EffectType TargetEffectType => EffectType.Invalid;

        /// <summary>
        /// Check if the <see cref="EffectType"/> sent by the user match the internal <see cref="EffectType"/>.
        /// </summary>
        /// <param name="parameter">The user parameter.</param>
        /// <returns>Returns true if the <see cref="EffectType"/> sent by the user matches the internal <see cref="EffectType"/>.</returns>
        public bool IsTypeValid<T>(in T parameter) where T : unmanaged, IEffectInParameter
        {
            return parameter.Type == TargetEffectType;
        }

        /// <summary>
        /// Update the usage state during command generation.
        /// </summary>
        protected void UpdateUsageStateForCommandGeneration()
        {
            UsageState = IsEnabled ? UsageState.Enabled : UsageState.Disabled;
        }

        /// <summary>
        /// Update the internal common parameters from a user parameter.
        /// </summary>
        /// <param name="parameter">The user parameter.</param>
        protected void UpdateParameterBase<T>(in T parameter) where T : unmanaged, IEffectInParameter
        {
            MixId = parameter.MixId;
            ProcessingOrder = parameter.ProcessingOrder;
        }

        /// <summary>
        /// Force unmap all the work buffers.
        /// </summary>
        /// <param name="mapper">The mapper to use.</param>
        public void ForceUnmapBuffers(PoolMapper mapper)
        {
            foreach (ref AddressInfo info in WorkBuffers.AsSpan())
            {
                if (info.GetReference(false) != 0)
                {
                    mapper.ForceUnmap(ref info);
                }
            }
        }

        /// <summary>
        /// Check if the effect needs to be skipped.
        /// </summary>
        /// <returns>Returns true if the effect needs to be skipped.</returns>
        public bool ShouldSkip()
        {
            return BufferUnmapped;
        }

        /// <summary>
        /// Update the <see cref="BaseEffect"/> state during command generation.
        /// </summary>
        public virtual void UpdateForCommandGeneration()
        {
            Debug.Assert(Type == TargetEffectType);
        }

        /// <summary>
        /// Initialize the given <paramref name="state"/> result state.
        /// </summary>
        /// <param name="state">The state to initialize</param>
        public virtual void InitializeResultState(ref EffectResultState state) { }

        /// <summary>
        /// Update the <paramref name="destState"/> result state with <paramref name="srcState"/>.
        /// </summary>
        /// <param name="destState">The destination result state</param>
        /// <param name="srcState">The source result state</param>
        public virtual void UpdateResultState(ref EffectResultState destState, ref EffectResultState srcState) { }

        /// <summary>
        /// Update the internal state from a user version 1 parameter.
        /// </summary>
        /// <param name="updateErrorInfo">The possible <see cref="ErrorInfo"/> that was generated.</param>
        /// <param name="parameter">The user parameter.</param>
        /// <param name="mapper">The mapper to use.</param>
        public virtual void Update(out ErrorInfo updateErrorInfo, in EffectInParameterVersion1 parameter, PoolMapper mapper)
        {
            Debug.Assert(IsTypeValid(in parameter));

            updateErrorInfo = new ErrorInfo();
        }

        /// <summary>
        /// Update the internal state from a user version 2 parameter.
        /// </summary>
        /// <param name="updateErrorInfo">The possible <see cref="ErrorInfo"/> that was generated.</param>
        /// <param name="parameter">The user parameter.</param>
        /// <param name="mapper">The mapper to use.</param>
        public virtual void Update(out ErrorInfo updateErrorInfo, in EffectInParameterVersion2 parameter, PoolMapper mapper)
        {
            Debug.Assert(IsTypeValid(in parameter));

            updateErrorInfo = new ErrorInfo();
        }

        /// <summary>
        /// Get the work buffer DSP address at the given index.
        /// </summary>
        /// <param name="index">The index of the work buffer</param>
        /// <returns>The work buffer DSP address at the given index.</returns>
        public virtual DspAddress GetWorkBuffer(int index)
        {
            throw new InvalidOperationException();
        }

        /// <summary>
        /// Get the first work buffer DSP address.
        /// </summary>
        /// <returns>The first work buffer DSP address.</returns>
        protected DspAddress GetSingleBuffer()
        {
            if (IsEnabled)
            {
                return WorkBuffers[0].GetReference(true);
            }

            if (UsageState != UsageState.Disabled)
            {
                DspAddress address = WorkBuffers[0].GetReference(false);
                ulong size = WorkBuffers[0].Size;

                if (address != 0 && size != 0)
                {
                    AudioProcessorMemoryManager.InvalidateDataCache(address, size);
                }
            }

            return 0;
        }

        /// <summary>
        /// Store the output status to the given user output.
        /// </summary>
        /// <param name="outStatus">The given user output.</param>
        /// <param name="isAudioRendererActive">If set to true, the <see cref="AudioRenderSystem"/> is active.</param>
        public void StoreStatus<T>(ref T outStatus, bool isAudioRendererActive) where T : unmanaged, IEffectOutStatus
        {
            if (isAudioRendererActive)
            {
                if (UsageState == UsageState.Disabled)
                {
                    outStatus.State = EffectState.Disabled;
                }
                else
                {
                    outStatus.State = EffectState.Enabled;
                }
            }
            else if (UsageState == UsageState.New)
            {
                outStatus.State = EffectState.Enabled;
            }
            else
            {
                outStatus.State = EffectState.Disabled;
            }
        }

        /// <summary>
        /// Get the <see cref="PerformanceDetailType"/> associated to the <see cref="Type"/> of this <see cref="BaseEffect"/>.
        /// </summary>
        /// <returns>The <see cref="PerformanceDetailType"/> associated to the <see cref="Type"/> of this <see cref="BaseEffect"/>.</returns>
        public PerformanceDetailType GetPerformanceDetailType()
        {
            return Type switch
            {
                EffectType.BiquadFilter => PerformanceDetailType.BiquadFilter,
                EffectType.AuxiliaryBuffer => PerformanceDetailType.Aux,
                EffectType.Delay => PerformanceDetailType.Delay,
                EffectType.Reverb => PerformanceDetailType.Reverb,
                EffectType.Reverb3d => PerformanceDetailType.Reverb3d,
                EffectType.BufferMix => PerformanceDetailType.Mix,
                EffectType.Limiter => PerformanceDetailType.Limiter,
                EffectType.CaptureBuffer => PerformanceDetailType.CaptureBuffer,
                EffectType.Compressor => PerformanceDetailType.Compressor,
                _ => throw new NotImplementedException($"{Type}"),
            };
        }

        // S2Arm (#12/#13 拆分): 按型建实例(= StateUpdater.ResetEffect 原来的 new switch,一处共用:
        //   解析段对影子实例做型变重置、影子构建时按 live 型补建影子实例)
        internal static BaseEffect S2ACreate(EffectType type, bool biquadFilterParameterFloatSupported)
        {
            return type switch
            {
                EffectType.Invalid => new BaseEffect(),
                EffectType.BufferMix => new BufferMixEffect(),
                EffectType.AuxiliaryBuffer => new AuxiliaryBufferEffect(),
                EffectType.Delay => new DelayEffect(),
                EffectType.Reverb => new ReverbEffect(),
                EffectType.Reverb3d => new Reverb3dEffect(),
                EffectType.BiquadFilter when biquadFilterParameterFloatSupported => new BiquadFilterEffect(2),
                EffectType.BiquadFilter => new BiquadFilterEffect(1),
                EffectType.Limiter => new LimiterEffect(),
                EffectType.CaptureBuffer => new CaptureBufferEffect(),
                EffectType.Compressor => new CompressorEffect(),
                _ => throw new NotImplementedException($"EffectType {type} not implemented!"),
            };
        }

        // S2Arm (#12/#13 拆分 · 渲染拍不等 Update 的锁): 效果实例的游戏侧字段影子拷贝。方向两用:锁1 把 live 拷进
        //   影子(解析段的基底),锁2a 把影子拷回 live(落账)。只发生在同型实例之间(S2AUpdateShadow 保证);
        //   型变不拷贝、走整实例替换(ResetEffect 的语义,见 S2AUpdateShadow 的效果落账)。
        //   字段矩阵:游戏写的(Type/IsEnabled/BufferUnmapped/UsageState 的 New 置位/MixId/ProcessingOrder/WorkBuffers
        //   挂接)与拍写的(UpdateForCommandGeneration 的 UsageState New→Enabled/Disabled 迁移、各型 Parameter.Status)
        //   都拷——基底取锁1 快照,与波表重演基底(处方①)同口径:这两个拍写字段落账成快照值,落在「Update 在快照点
        //   串行、拍在落账后重做同一迁移」的今天可能序上。DSP 状态(Memory<XxxState>,Get-only)不拷、引用共享:
        //   效果 Update 不写它,DSP 在锁外独写。
        //   子类 override 必须先调 base.S2AShadowCopyGameFieldsFrom。
        internal virtual void S2AShadowCopyGameFieldsFrom(BaseEffect source)
        {
            Type = source.Type;
            IsEnabled = source.IsEnabled;
            BufferUnmapped = source.BufferUnmapped;
            UsageState = source.UsageState;
            MixId = source.MixId;
            ProcessingOrder = source.ProcessingOrder;
            WorkBuffers[0] = source.WorkBuffers[0];
            WorkBuffers[1] = source.WorkBuffers[1];
        }

        // S2Arm (#12/#13 拆分): 工缓(挂接缓冲的地址信息)池指针重绑——影子槽里的指针指影子池表,落账重绑到 live
        internal void S2ARebindWorkBuffers(S2AUpdateShadow shadow)
        {
            shadow.S2ARebindAddressInfo(ref WorkBuffers[0]);
            shadow.S2ARebindAddressInfo(ref WorkBuffers[1]);
        }
    }
}
