// dav1d AV1 解码的极小 C 接口（与 services/vpx/s2a_vp9.c 同形：调用方不用对 Dav1dPicture 的结构布局）：
// 打开 / 送一个时间单元并交出（至多）一帧的三个平面指针、步长、宽高与色彩信息（指针在下次解码 / 关闭前有效）/ 关闭。
// 用方：Switch 2 直连档接管的 nn::codec AV1 解码器在 VideoToolbox 不支持 AV1 时（graphics/nvn/gfx/nvn/nvn2_codec.c）。
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "dav1d/dav1d.h"

typedef struct
{
    Dav1dContext *c;
    Dav1dPicture pic;
    int has_pic;
} s2a_av1;

void *s2a_av1_open_mt(int threads, int frame_delay);

// threads：dav1d 线程数（0 = 按核数）；最大帧延迟 1：送一个时间单元就出它的帧（游戏按包取帧，不能攒）
void *s2a_av1_open(int threads)
{
    return s2a_av1_open_mt(threads, 1);
}

// 一帧的三个平面指针、步长、宽高与色彩信息（info 布局见 s2a_av1_decode）
static void av1_pic_info(const Dav1dPicture *p, uint8_t **planes, int32_t *strides, int32_t *info)
{
    for (int i = 0; i < 3; i++)
    {
        planes[i] = p->data[i];
        strides[i] = (int32_t)p->stride[i ? 1 : 0];
    }

    info[0] = p->p.w;
    info[1] = p->p.h;
    info[2] = p->p.bpc;
    info[3] = (int32_t)p->p.layout;
    info[4] = p->seq_hdr == NULL || p->seq_hdr->mtrx == DAV1D_MC_UNKNOWN ? -1 : p->seq_hdr->mtrx == DAV1D_MC_BT709 ? 1 : 0;
    info[5] = p->seq_hdr != NULL && p->seq_hdr->color_range;
}

// 返回 0 = 出了一帧；1 = 送进去了但没有可显示的帧；-1 = 解码失败
// info：[0] 宽 [1] 高 [2] 每分量位数（8 / 10 / 12）[3] 色度布局（0 单色 1 4:2:0 2 4:2:2 3 4:4:4）[4] 色彩矩阵（1 = BT.709，0 = 其它已声明，-1 = 未声明）[5] 全范围（1）/ 视频范围（0）
int s2a_av1_decode(void *hv, const uint8_t *data, uint32_t len, uint8_t **planes, int32_t *strides, int32_t *info)
{
    s2a_av1 *h = hv;
    Dav1dData d = { 0 };
    int got = 0;

    if (h->has_pic)
    {
        dav1d_picture_unref(&h->pic);
        h->has_pic = 0;
    }

    uint8_t *buf = dav1d_data_create(&d, len);

    if (buf == NULL)
    {
        return -1;
    }

    memcpy(buf, data, len);
    while (d.sz > 0)
    {
        int r = dav1d_send_data(h->c, &d);

        if (r < 0 && r != DAV1D_ERR(EAGAIN))
        {
            dav1d_data_unref(&d);
            return -1;
        }

        // 送不进（EAGAIN）先取帧；取到的第一帧留给调用方，其余（最大帧延迟 1 时不会有）丢掉
        Dav1dPicture p = { 0 };
        int g = dav1d_get_picture(h->c, &p);

        if (g == 0)
        {
            if (!got)
            {
                h->pic = p;
                h->has_pic = got = 1;
            }
            else
            {
                dav1d_picture_unref(&p);
            }
        }
        else if (g < 0 && g != DAV1D_ERR(EAGAIN))
        {
            dav1d_data_unref(&d);
            return -1;
        }
        else if (r == DAV1D_ERR(EAGAIN))
        {
            // 送不进又没帧可取：解码器卡住，按失败报
            dav1d_data_unref(&d);
            return -1;
        }
    }

    if (!got)
    {
        Dav1dPicture p = { 0 };
        int g = dav1d_get_picture(h->c, &p);

        if (g == 0)
        {
            h->pic = p;
            h->has_pic = got = 1;
        }
        else if (g < 0 && g != DAV1D_ERR(EAGAIN))
        {
            return -1;
        }
    }

    if (!got)
    {
        return 1;
    }

    av1_pic_info(&h->pic, planes, strides, info);
    return 0;
}

// —— 帧并行接口（直连档的影片解码用）——
// 上面的 s2a_av1_decode 把最大帧延迟定成 1：dav1d 只能一帧接一帧解（帧内分块 / 行线程），1080p 片子在 M1 上每包平均约 10 ms、
//   关键帧 100+ ms，解码线程常常跟不上 60 帧，游戏只能重复上一帧，画面越放越慢，声音照真实时间放、跑到前面。
//   这组接口让 dav1d 自己定帧延迟（0 = 按线程数，6 线程时 3 帧同时解），每包送进去后至多取一帧；帧带着送进时的时间戳出来。
//   调用方要能接受「出帧比送包晚几包」：流结束时调 s2a_av1_flush 把还在解的帧全部取出。
typedef int (*s2a_av1_out_fn)(void *ctx, uint8_t **planes, int32_t *strides, int32_t *info, int64_t ts);

// frame_delay：dav1d 的 max_frame_delay（0 = 按线程数自动，1 = 不并行，即 s2a_av1_open）
void *s2a_av1_open_mt(int threads, int frame_delay)
{
    s2a_av1 *h = calloc(1, sizeof *h);
    Dav1dSettings s;

    if (h == NULL)
    {
        return NULL;
    }

    dav1d_default_settings(&s);
    s.n_threads = threads > 0 ? threads : 0;
    s.max_frame_delay = frame_delay > 0 && frame_delay <= DAV1D_MAX_FRAME_DELAY ? frame_delay : 0;
    if (dav1d_open(&h->c, &s) < 0)
    {
        free(h);
        return NULL;
    }

    return h;
}

// 交一帧给调用方；返回调用方的结果（0 = 调用方要停，后面的帧不再交）
static int av1_give(Dav1dPicture *p, s2a_av1_out_fn out, void *ctx)
{
    uint8_t *planes[3];
    int32_t strides[3], info[6];

    av1_pic_info(p, planes, strides, info);
    int r = out(ctx, planes, strides, info, p->m.timestamp);
    dav1d_picture_unref(p);
    return r;
}

// 送一个时间单元（带时间戳 ts），出了的帧逐个交给 out（指针只在 out 里有效）。
// 返回 0 = 送进去了；-1 = 解码失败；-2 = 调用方要停（out 返回 0）
// 每次送进之后只取一次帧：dav1d 在两次取帧之间没有新数据时会进「排空」，等还在解的帧解完（把帧并行又变回一帧一帧）
int s2a_av1_send(void *hv, const uint8_t *data, uint32_t len, int64_t ts, s2a_av1_out_fn out, void *ctx)
{
    s2a_av1 *h = hv;
    Dav1dData d = { 0 };
    uint8_t *buf = dav1d_data_create(&d, len);

    if (buf == NULL)
    {
        return -1;
    }

    memcpy(buf, data, len);
    d.m.timestamp = ts;
    int stuck = 0;
    while (d.sz > 0)
    {
        int r = dav1d_send_data(h->c, &d);

        if (r < 0 && r != DAV1D_ERR(EAGAIN))
        {
            dav1d_data_unref(&d);
            return -1;
        }

        if (r == 0 && d.sz == 0)
        {
            break;
        }

        // 送不进（EAGAIN，有帧等着被取）：先取走一帧再送
        Dav1dPicture p = { 0 };
        int g = dav1d_get_picture(h->c, &p);

        if (g == 0)
        {
            if (!av1_give(&p, out, ctx))
            {
                dav1d_data_unref(&d);
                return -2;
            }
        }
        else if (g != DAV1D_ERR(EAGAIN))
        {
            dav1d_data_unref(&d);
            return -1;
        }
        else if (r == DAV1D_ERR(EAGAIN) && ++stuck > 8)
        {
            dav1d_data_unref(&d);
            return -1;   // 反复送不进又没帧可取：解码器卡住
        }
        // 送不进、取帧也没出：上一包没解析完的尾巴（dav1d 送成功后留在内部，比如只有「显示已有帧」的小包）刚被取帧这一下解析掉，
        //   重送就进得去。原先这里直接判失败、丢掉这一包：帧并行时这种包每次都丢，影片少帧、画面跑到声音前面
    }

    Dav1dPicture p = { 0 };
    int g = dav1d_get_picture(h->c, &p);

    if (g == 0)
    {
        return av1_give(&p, out, ctx) ? 0 : -2;
    }

    return g == DAV1D_ERR(EAGAIN) ? 0 : -1;
}

// 跳转 / 换代（游戏 Flush）：丢掉还在解、还没取走的帧与已送进的数据（dav1d_flush），下一包从关键帧接着解。
//   帧并行时 dav1d 里压着前几包的帧，不清的话换代后头几次送包会把旧片段的帧交出去
void s2a_av1_reset(void *hv)
{
    s2a_av1 *h = hv;

    if (h->has_pic)
    {
        dav1d_picture_unref(&h->pic);
        h->has_pic = 0;
    }
    dav1d_flush(h->c);
}

// 流结束：把还在解的帧全部取出交给 out。返回同 s2a_av1_send
int s2a_av1_flush(void *hv, s2a_av1_out_fn out, void *ctx)
{
    s2a_av1 *h = hv;

    for (;;)
    {
        Dav1dPicture p = { 0 };
        int g = dav1d_get_picture(h->c, &p);

        if (g == DAV1D_ERR(EAGAIN))
        {
            return 0;
        }

        if (g < 0)
        {
            return -1;
        }

        if (!av1_give(&p, out, ctx))
        {
            return -2;
        }
    }
}

void s2a_av1_close(void *hv)
{
    s2a_av1 *h = hv;

    if (h == NULL)
    {
        return;
    }

    if (h->has_pic)
    {
        dav1d_picture_unref(&h->pic);
    }

    dav1d_close(&h->c);
    free(h);
}
