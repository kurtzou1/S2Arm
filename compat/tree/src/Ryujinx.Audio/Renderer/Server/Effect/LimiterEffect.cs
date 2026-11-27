using Ryujinx.Audio.Renderer.Common;
using Ryujinx.Audio.Renderer.Dsp.State;
using Ryujinx.Audio.Renderer.Parameter;
using Ryujinx.Audio.Renderer.Parameter.Effect;
using Ryujinx.Audio.Renderer.Server.MemoryPool;
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Renderer.Server.Effect
{
    /// <summary>
    /// Server state for a limiter effect.
    /// </summary>
    public class LimiterEffect : BaseEffect
    {
        public override void S2AForceReinit() => Parameter.Status = UsageState.Invalid;   // S2Arm 即时存档

        /// <summary>
        /// The limiter parameter.
        /// </summary>
        public LimiterParameter Parameter;

        /// <summary>
        /// The limiter state.
        /// </summary>
        public Memory<LimiterState> State { get; }

        /// <summary>
        /// Create a new <see cref="LimiterEffect"/>.
        /// </summary>
        public LimiterEffect()
        {
            State = new LimiterState[1];
        }

        public override EffectType TargetEffectType => EffectType.Limiter;

        // S2Arm (#12/#13 拆分): 本型的游戏侧字段影子拷贝(矩阵与基底口径见 BaseEffect.S2AShadowCopyGameFieldsFrom;
        //   各型共享的 DSP 状态数组(Get-only 的 Memory<XxxState>)不拷、引用共享)
        internal override void S2AShadowCopyGameFieldsFrom(BaseEffect source)
        {
            base.S2AShadowCopyGameFieldsFrom(source);

            Parameter = ((LimiterEffect)source).Parameter;
        }

        public override ulong GetWorkBuffer(int index)
        {
            return GetSingleBuffer();
        }

        public override void Update(out BehaviourParameter.ErrorInfo updateErrorInfo, in EffectInParameterVersion1 parameter, PoolMapper mapper)
        {
            Update(out updateErrorInfo, in parameter, mapper);
        }

        public override void Update(out BehaviourParameter.ErrorInfo updateErrorInfo, in EffectInParameterVersion2 parameter, PoolMapper mapper)
        {
            Update(out updateErrorInfo, in parameter, mapper);
        }

        public void Update<T>(out BehaviourParameter.ErrorInfo updateErrorInfo, in T parameter, PoolMapper mapper) where T : unmanaged, IEffectInParameter
        {
            Debug.Assert(IsTypeValid(in parameter));

            ref LimiterParameter limiterParameter = ref MemoryMarshal.Cast<byte, LimiterParameter>(parameter.SpecificData)[0];

            updateErrorInfo = new BehaviourParameter.ErrorInfo();

            UpdateParameterBase(in parameter);

            Parameter = limiterParameter;

            IsEnabled = parameter.IsEnabled;

            if (BufferUnmapped || parameter.IsNew)
            {
                UsageState = UsageState.New;
                Parameter.Status = UsageState.Invalid;

                BufferUnmapped = !mapper.TryAttachBuffer(out updateErrorInfo, ref WorkBuffers[0], parameter.BufferBase, parameter.BufferSize);
            }
        }

        public override void UpdateForCommandGeneration()
        {
            UpdateUsageStateForCommandGeneration();

            Parameter.Status = UsageState.Enabled;
            Parameter.StatisticsReset = false;
        }

        public override void InitializeResultState(ref EffectResultState state)
        {
            ref LimiterStatistics statistics = ref MemoryMarshal.Cast<byte, LimiterStatistics>(state.SpecificData)[0];

            statistics.Reset();
        }

        public override void UpdateResultState(ref EffectResultState destState, ref EffectResultState srcState)
        {
            destState = srcState;
        }
    }
}
