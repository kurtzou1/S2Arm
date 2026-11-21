using System;
using System.Numerics;

namespace S2A.Services
{
    // 陀螺仪零偏补偿（真机由系统 HID 服务做，游戏用 SetGyroscopeZeroDriftMode 调松紧；#1935、D-BYT6）：
    //   手柄自身有固定零偏（#1935 第三方 Pro 静置 X 轴 −4.68 °/s，换位置、隔六小时都一样），不扣掉游戏里准星 / 视角一直往一边转。
    //   做法：连续一段时间「静止」——加速度模长在 1 g 附近且几乎不变、陀螺各轴读数的起伏很小——就把这段的陀螺平均值记成零偏，之后每个样本都扣掉；
    //   动起来不学，保留已学到的值。只认起伏、不认读数大小：零偏可以有好几度每秒，静止时照样学得到。
    //   平均值超过 MaxBias 的不当零偏（那是真在匀速转），一路一个实例，按样本时间戳算时长（单位：加速度 g、角速度 度/秒）
    internal sealed class GyroZeroDrift
    {
        internal const float AccelTolerance = 0.1f;   // |a| 偏离 1 g 不超过这么多
        internal const float AccelRange = 0.05f;      // 窗口内加速度各轴最大最小之差
        internal const float GyroRange = 1.5f;        // 窗口内陀螺各轴最大最小之差（度/秒）
        internal const float MaxBias = 10f;           // 零偏上限（度/秒）
        internal const ulong StillUs = 800_000;       // 静止多久学一次
        internal const ulong GapUs = 100_000;         // 两个样本隔得比这久就重新算窗口

        private Vector3 _bias;
        private Vector3 _sum, _gMin, _gMax, _aMin, _aMax;
        private int _count;
        private ulong _start, _last;

        public Vector3 Bias => _bias;
        public bool Learned { get; private set; }

        public Vector3 Apply(Vector3 accel, Vector3 gyro, ulong timestampUs)
        {
            bool still = MathF.Abs(accel.Length() - 1f) <= AccelTolerance;
            if (_count > 0 && (timestampUs <= _last || timestampUs - _last > GapUs)) _count = 0;
            if (still && _count > 0)
            {
                Vector3 gMin = Vector3.Min(_gMin, gyro), gMax = Vector3.Max(_gMax, gyro), aMin = Vector3.Min(_aMin, accel), aMax = Vector3.Max(_aMax, accel);
                Vector3 gr = gMax - gMin, ar = aMax - aMin;
                if (MathF.Max(gr.X, MathF.Max(gr.Y, gr.Z)) <= GyroRange && MathF.Max(ar.X, MathF.Max(ar.Y, ar.Z)) <= AccelRange)
                {
                    _gMin = gMin; _gMax = gMax; _aMin = aMin; _aMax = aMax; _sum += gyro; _count++;
                }
                else _count = 0;
            }
            else if (!still) _count = 0;
            if (still && _count == 0)
            {
                _gMin = _gMax = _sum = gyro; _aMin = _aMax = accel; _count = 1; _start = timestampUs;
            }
            _last = timestampUs;
            if (_count > 1 && timestampUs - _start >= StillUs)
            {
                Vector3 mean = _sum / _count;
                if (MathF.Abs(mean.X) <= MaxBias && MathF.Abs(mean.Y) <= MaxBias && MathF.Abs(mean.Z) <= MaxBias)
                {
                    _bias = mean; Learned = true;
                }
                _count = 0;   // 下一段从头算：一直静止就每 StillUs 刷新一次
            }
            return gyro - _bias;
        }
    }
}
