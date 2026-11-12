#ifndef S2A_PHONE_AXES_H
#define S2A_PHONE_AXES_H
// 手机机身传感器 → NS2 原始坐标（见 runtime/src/phone_axes.c）
//   right / up：屏幕「右」「上」两个方向在机身坐标（CoreMotion x、y）里的单位向量，各分量取 −1 / 0 / 1（ios/phone_motion.m 由屏幕坐标空间实算）
void s2a_phone_axes_basis(const int right[2], const int up[2], const double acc_dev[3], const double gyr_dev[3], float acc_raw[3], float gyr_raw[3]);
// 竖屏为原生面板的手机横屏两种（横屏右 = 顶端朝左：右 = 机身 −y、上 = 机身 x；横屏左相反）
void s2a_phone_axes(int landscape_right, const double acc_dev[3], const double gyr_dev[3], float acc_raw[3], float gyr_raw[3]);

// 手柄 GCMotion → NS2 原始坐标（Mac，macos/front_mac.m）：手柄坐标轴与 NS2 相同（x 右、y 上沿、z 正面法线），
//   重力方向取反成支撑反力，角速度 rad/s 换成度/秒。纯函数，单测 t_phone_axes
static inline void s2a_gc_motion_axes(const double gravity[3], const double user[3], const double rotation[3], float acc_raw[3], float gyr_raw[3]) {
    for (int i = 0; i < 3; i++) {
        acc_raw[i] = (float)-(gravity[i] + user[i]);
        gyr_raw[i] = (float)(rotation[i] * 57.29577951308232);
    }
}
#endif
