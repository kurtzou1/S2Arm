using Ryujinx.Audio.Renderer.Common;
using Ryujinx.Audio.Renderer.Parameter;
using Ryujinx.Audio.Renderer.Server.MemoryPool;
using System;
using System.Diagnostics;
using static Ryujinx.Audio.Renderer.Common.BehaviourParameter;

namespace Ryujinx.Audio.Renderer.Server.Sink
{
    /// <summary>
    /// Base class used for server information of a sink.
    /// </summary>
    public class BaseSink
    {
        /// <summary>
        /// The type of this <see cref="BaseSink"/>.
        /// </summary>
        public SinkType Type;

        /// <summary>
        /// Set to true if the sink is used.
        /// </summary>
        public bool IsUsed;

        /// <summary>
        /// Set to true if the sink need to be skipped because of invalid state.
        /// </summary>
        public bool ShouldSkip;

        /// <summary>
        /// The node id of the sink.
        /// </summary>
        public int NodeId;

        /// <summary>
        /// Create a new <see cref="BaseSink"/>.
        /// </summary>
        public BaseSink()
        {
            CleanUp();
        }

        /// <summary>
        /// Clean up the internal state of the <see cref="BaseSink"/>.
        /// </summary>
        public virtual void CleanUp()
        {
            Type = TargetSinkType;
            IsUsed = false;
            ShouldSkip = false;
        }

        /// <summary>
        /// The target <see cref="SinkType"/> handled by this <see cref="BaseSink"/>.
        /// </summary>
        public virtual SinkType TargetSinkType => SinkType.Invalid;

        /// <summary>
        /// Check if the <see cref="SinkType"/> sent by the user match the internal <see cref="SinkType"/>.
        /// </summary>
        /// <param name="parameter">The user parameter.</param>
        /// <returns>Return true, if the <see cref="SinkType"/> sent by the user match the internal <see cref="SinkType"/>.</returns>
        public bool IsTypeValid(in SinkInParameter parameter)
        {
            return parameter.Type == TargetSinkType;
        }

        /// <summary>
        /// Update the <see cref="BaseSink"/> state during command generation.
        /// </summary>
        public virtual void UpdateForCommandGeneration()
        {
            Debug.Assert(Type == TargetSinkType);
        }

        /// <summary>
        /// Update the internal common parameters from user parameter.
        /// </summary>
        /// <param name="parameter">The user parameter.</param>
        protected void UpdateStandardParameter(in SinkInParameter parameter)
        {
            if (IsUsed != parameter.IsUsed)
            {
                IsUsed = parameter.IsUsed;
                NodeId = parameter.NodeId;
            }
        }

        /// <summary>
        /// Update the internal state from user parameter.
        /// </summary>
        /// <param name="errorInfo">The possible <see cref="ErrorInfo"/> that was generated.</param>
        /// <param name="parameter">The user parameter.</param>
        /// <param name="outStatus">The user output status.</param>
        /// <param name="mapper">The mapper to use.</param>
        public virtual void Update(out ErrorInfo errorInfo, in SinkInParameter parameter, ref SinkOutStatus outStatus, PoolMapper mapper)
        {
            Debug.Assert(IsTypeValid(in parameter));

            errorInfo = new ErrorInfo();
        }

        // S2Arm (#12/#13 拆分): 按型建实例(= StateUpdater.ResetSink 原来的 new switch,一处共用)
        internal static BaseSink S2ACreate(SinkType type)
        {
            return type switch
            {
                SinkType.Invalid => new BaseSink(),
                SinkType.CircularBuffer => new CircularBufferSink(),
                SinkType.Device => new DeviceSink(),
                _ => throw new NotImplementedException($"SinkType {type} not implemented!"),
            };
        }

        // S2Arm (#12/#13 拆分 · 渲染拍不等 Update 的锁): 汇实例的游戏侧字段影子拷贝(方向两用:锁1 live→影子作解析
        //   基底、锁2a 影子→live 落账)。字段矩阵:游戏写的(Type/IsUsed/ShouldSkip/NodeId)拷;拍写的(环形汇的
        //   _lastWrittenOffset/_oldWrittenOffset/CurrentWriteOffset,UpdateForCommandGeneration 推进;器件汇的
        //   UpsamplerInfo,CommandGenerator 按需 Allocate)不拷、落账保留活值——拷基底的落账只会把拍刚推进的写
        //   偏移回卷一拍。子类 override 必须先调 base.S2AShadowCopyGameFieldsFrom。
        internal virtual void S2AShadowCopyGameFieldsFrom(BaseSink source)
        {
            Type = source.Type;
            IsUsed = source.IsUsed;
            ShouldSkip = source.ShouldSkip;
            NodeId = source.NodeId;
        }
    }
}
