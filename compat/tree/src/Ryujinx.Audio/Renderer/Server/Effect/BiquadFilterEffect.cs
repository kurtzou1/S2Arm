using Ryujinx.Audio.Renderer.Common;
using Ryujinx.Audio.Renderer.Dsp;
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
    /// Server state for a biquad filter effect.
    /// </summary>
    public class BiquadFilterEffect : BaseEffect
    {
        public override void S2AForceReinit() => Parameter.Status = UsageState.Invalid;   // S2Arm 即时存档

        /// <summary>
        /// The biquad filter parameter.
        /// </summary>
        public BiquadFilterEffectParameter2 Parameter;

        /// <summary>
        /// The biquad filter state.
        /// </summary>
        public Memory<BiquadFilterState> State { get; }

        /// <summary>
        /// The biquad filter effect version.
        /// </summary>
        public int BiquadFilterEffectVersion;

        /// <summary>
        /// Create a new <see cref="BiquadFilterEffect"/>.
        /// </summary>
        public BiquadFilterEffect(int version)
        {
            Parameter = new BiquadFilterEffectParameter2();
            State = new BiquadFilterState[Constants.ChannelCountMax];
            BiquadFilterEffectVersion = version;
        }

        public override EffectType TargetEffectType => EffectType.BiquadFilter;

        // S2Arm (#12/#13 拆分): 本型的游戏侧字段影子拷贝(矩阵与基底口径见 BaseEffect.S2AShadowCopyGameFieldsFrom;
        //   各型共享的 DSP 状态数组(Get-only 的 Memory<XxxState>)不拷、引用共享)
        internal override void S2AShadowCopyGameFieldsFrom(BaseEffect source)
        {
            base.S2AShadowCopyGameFieldsFrom(source);

            Parameter = ((BiquadFilterEffect)source).Parameter;
            BiquadFilterEffectVersion = ((BiquadFilterEffect)source).BiquadFilterEffectVersion;
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

            UpdateParameterBase(in parameter);

            if (BiquadFilterEffectVersion == 2)
            {
                Parameter = MemoryMarshal.Cast<byte, BiquadFilterEffectParameter2>(parameter.SpecificData)[0];
            }
            else
            {
                BiquadFilterEffectParameter1 oldParameter =
                    MemoryMarshal.Cast<byte, BiquadFilterEffectParameter1>(parameter.SpecificData)[0];
                Parameter = BiquadFilterHelper.ToBiquadFilterEffectParameter2(oldParameter);
            }
            
            IsEnabled = parameter.IsEnabled;

            updateErrorInfo = new BehaviourParameter.ErrorInfo();
        }

        public override void UpdateForCommandGeneration()
        {
            UpdateUsageStateForCommandGeneration();

            Parameter.Status = UsageState.Enabled;
        }
    }
}
