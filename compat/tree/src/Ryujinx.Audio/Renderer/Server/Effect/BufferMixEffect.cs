using Ryujinx.Audio.Renderer.Common;
using Ryujinx.Audio.Renderer.Parameter;
using Ryujinx.Audio.Renderer.Parameter.Effect;
using Ryujinx.Audio.Renderer.Server.MemoryPool;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Renderer.Server.Effect
{
    /// <summary>
    /// Server state for a buffer mix effect.
    /// </summary>
    public class BufferMixEffect : BaseEffect
    {
        /// <summary>
        /// The buffer mix parameter.
        /// </summary>
        public BufferMixParameter Parameter;

        public override EffectType TargetEffectType => EffectType.BufferMix;

        // S2Arm (#12/#13 拆分): 本型的游戏侧字段影子拷贝(矩阵与基底口径见 BaseEffect.S2AShadowCopyGameFieldsFrom;
        //   各型共享的 DSP 状态数组(Get-only 的 Memory<XxxState>)不拷、引用共享)
        internal override void S2AShadowCopyGameFieldsFrom(BaseEffect source)
        {
            base.S2AShadowCopyGameFieldsFrom(source);

            Parameter = ((BufferMixEffect)source).Parameter;
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

            Parameter = MemoryMarshal.Cast<byte, BufferMixParameter>(parameter.SpecificData)[0];
            IsEnabled = parameter.IsEnabled;

            updateErrorInfo = new BehaviourParameter.ErrorInfo();
        }

        public override void UpdateForCommandGeneration()
        {
            UpdateUsageStateForCommandGeneration();
        }
    }
}
