// 顶点着色器真正取数的顶点流（#618 诊断包：顶点缓冲槽 5 不在任何池、整局约 420 万次「读零」）。
// 管线的顶点描述（nvn_mtl.m pso_desc / pso_key_norm）只为着色器声明的输入建属性，属性只引用它所在的流；
//   游戏绑着、但当前着色器的输入都不引用的流，GPU 一个字节也不取（真机的顶点取数同样经属性走：流地址只在有属性引用它时才被读）。
//   bind_vbufs 原先对 16 个槽「有地址就解析」：没被读的流指向已释放 / 从未登记的内存时，每次绘制都查一遍池表（查不到时整表线性扫）并报「读零」红，
//   把无害的残留绑定和真读零混在一起。这里给出要解析的流：着色器读的属性号 → 属性所在的流，格式 0 的属性不取数（pso_desc 走零缓冲）。
// 纯函数、不依赖 Metal / NVN 头，单测 tests/t_vbuf_read.c。
#pragma once
#include <stdint.h>

// attr_nvn[0..nv)：着色器读的 NVN 属性号（nvn_refl.v[].nvn）；attr_stream / attr_fmt[0..nattr)：当前绑的顶点属性状态（va_st.stream / .fmt）。
// 返回位 s = 流 s 会被取数；属性号越界（≥ nattr 或 ≥ 16）、格式 0、流号 ≥ 16 的都不算
static inline uint32_t nvn_vbuf_read_streams(const uint8_t *attr_nvn, int nv, const uint8_t *attr_stream, const uint8_t *attr_fmt, int nattr) {
    uint32_t m = 0;
    for (int v = 0; v < nv; v++) {
        int a = attr_nvn[v];
        if (a >= 16 || a >= nattr || !attr_fmt[a] || attr_stream[a] >= 16) continue;
        m |= 1u << attr_stream[a];
    }
    return m;
}
