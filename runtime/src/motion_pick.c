// 玩家 1 的六轴来源仲裁：纯函数，宿主（ios/controller.m）每帧调一次。
//   只在「有没有样本」这一层做决定，不碰时间 / 锁 / 设备；换源滞回与丢一帧由宿主负责。
#include "motion_pick.h"

int s2a_motion_pick(int input_source, int ns2_known, int gc_known, int phone_known) {
    int phone = phone_known ? S2A_MOTION_PHONE : S2A_MOTION_NONE;
    int gc = gc_known ? S2A_MOTION_GC : S2A_MOTION_NONE;
    int ns2 = ns2_known ? S2A_MOTION_NS2 : S2A_MOTION_NONE;
    // 11-15 维护者：「接着手柄就不用管触屏了吧？谁接着手柄还用触屏玩啊」——接了有体感的手柄就用手柄的六轴，不再看触屏有没有在操作；
    //   手柄都给不出体感（Xbox / Joy-Con 一代 / 夹手机的 Backbone、Kishi：手机和手柄一起动，手机陀螺仪正好对）才用手机。
    //   输入来源只在两只手柄之间分先后：NS2 Pro 在驱动输入就先读它，其余（系统手柄 / 触屏 / 未知）先读系统手柄
    if (input_source == 1) return ns2 ? ns2 : gc ? gc : phone;
    return gc ? gc : ns2 ? ns2 : phone;
}

int s2a_motion_fresh(int ever, uint64_t sample_us, uint64_t now_us) {
    if (!ever) return 0;
    return sample_us >= now_us || now_us - sample_us <= (uint64_t)S2A_MOTION_STALE_MS * 1000;
}

int s2a_motion_pad_silent(int capable, uint64_t last_ok_us, uint64_t now_us) {
    return capable == 1 && now_us > last_ok_us && now_us - last_ok_us > (uint64_t)S2A_MOTION_SILENT_MS * 1000;
}

int s2a_motion_blank(const float accel[3], const float gyro[3]) {
    for (int i = 0; i < 3; i++) if (accel[i] != 0.0f || gyro[i] != 0.0f) return 0;
    return 1;
}
