// Texture 组（#270 N12）三条语义，走生产 bootstrap、不初始化 GPU：
//   · GL 互操作名字：Set 之后 Get 原样返回（Metal 路径不消费，只保查询）；
//   · 稀疏贴图布局（#962）：贴图的 GetSparseTileLayout 与构造器的同一口径（按贴图建时的描述 tex_t.d）——稀疏描述给出页的 4 个字段（期望照 t_nvn_a 手算那一行），
//     非稀疏描述 / 全零对象给 0；原先一律填零，一款游戏按 0 字节的页算 MapVirtual 请求、全被拒后崩；
//   · 调试 ID：NVN 没有 SetDebugID，本层用对象初始化序号 → 非零、且同一对象多次查询稳定。
#include "nvn_protos.h"
#include "nvn_obj.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
static int bad;
static void *api(const char *n) { void *p = h_nvnBootstrapLoader(n); if (!p) { fprintf(stderr, "找不到公开 API：%s\n", n); bad++; } return p; }
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)
#define API(type, var, name) type var = (type)api(#name)

int main(void) {
    API(NVNT_nvnTextureBuilderSetGLTextureName, setName, nvnTextureBuilderSetGLTextureName);
    API(NVNT_nvnTextureBuilderGetGLTextureName, getName, nvnTextureBuilderGetGLTextureName);
    API(NVNT_nvnTextureGetSparseTileLayout, sparse, nvnTextureGetSparseTileLayout);
    API(NVNT_nvnTextureGetDebugID, dbg, nvnTextureGetDebugID);
    API(NVNT_nvnTextureBuilderSetDefaults, bdef, nvnTextureBuilderSetDefaults);
    API(NVNT_nvnTextureBuilderSetTarget, btgt, nvnTextureBuilderSetTarget);
    API(NVNT_nvnTextureBuilderSetFormat, bfmt, nvnTextureBuilderSetFormat);
    API(NVNT_nvnTextureBuilderSetSize2D, bsz, nvnTextureBuilderSetSize2D);
    API(NVNT_nvnTextureBuilderSetFlags, bflg, nvnTextureBuilderSetFlags);
    API(NVNT_nvnTextureBuilderSetStride, bstr, nvnTextureBuilderSetStride);
    API(NVNT_nvnTextureBuilderSetLevels, blev, nvnTextureBuilderSetLevels);
    API(NVNT_nvnTextureBuilderGetStorageSize, bsize, nvnTextureBuilderGetStorageSize);
    if (bad) return 1;

    union { NVNtextureBuilder b; char raw[0x80]; } builder;
    memset(&builder, 0, sizeof builder);

    // ① GL 名字往返（含 0 与一个非零值）
    CHECK(getName(&builder.b) == 0, "未设置时 GetGLTextureName=%u（应 0）", getName(&builder.b));
    setName(&builder.b, 0x1234u);
    CHECK(getName(&builder.b) == 0x1234u, "Set 0x1234 后 Get=%u", getName(&builder.b));
    setName(&builder.b, 0);
    CHECK(getName(&builder.b) == 0, "Set 0 后 Get=%u（应 0）", getName(&builder.b));

    // ② 稀疏布局：全零对象（非稀疏）→ 4 个字段都写 0（先填满垃圾再查）；
    //    稀疏描述 RGBA8 256×256、1 级、标志 0x20 → 1 级平铺、页 128×128×1（同 t_nvn_a 手算那一行：64 KiB 页 / 4 字节 = 128×128）；同描述去掉稀疏标志 → 0
    NVNtextureSparseTileLayout lay;
    memset(&lay, 0xAB, sizeof lay);
    NVNtexture tex;
    memset(&tex, 0, sizeof tex);
    sparse(&tex, &lay);
    CHECK(lay.numTiledLevels == 0 && lay.tileWidth == 0 && lay.tileHeight == 0 && lay.tileDepth == 0, "全零对象：GetSparseTileLayout = %d / %d×%d×%d（应全 0）", lay.numTiledLevels, lay.tileWidth, lay.tileHeight, lay.tileDepth);
    {
        union { NVNtextureBuilder b; char raw[0x80]; } sb; memset(&sb, 0, sizeof sb);
        bdef(&sb.b); btgt(&sb.b, (NVNtextureTarget)1); bfmt(&sb.b, NVN_FORMAT_RGBA8); bsz(&sb.b, 256, 256); blev(&sb.b, 1); bflg(&sb.b, 0x20);
        ((tex_t *)&tex)->d = ((const tex_builder_t *)&sb.b)->d;   // 贴图按这个构造器建时记下的描述
        memset(&lay, 0xAB, sizeof lay); sparse(&tex, &lay);
        CHECK(lay.numTiledLevels == 1 && lay.tileWidth == 128 && lay.tileHeight == 128 && lay.tileDepth == 1,
              "稀疏 RGBA8 256×256：GetSparseTileLayout = %d / %d×%d×%d（应 1 / 128×128×1）", lay.numTiledLevels, lay.tileWidth, lay.tileHeight, lay.tileDepth);
        bflg(&sb.b, 0); ((tex_t *)&tex)->d = ((const tex_builder_t *)&sb.b)->d;
        memset(&lay, 0xAB, sizeof lay); sparse(&tex, &lay);
        CHECK(lay.numTiledLevels == 0 && lay.tileWidth == 0, "非稀疏 RGBA8 256×256：GetSparseTileLayout = %d / %d（应 0 / 0）", lay.numTiledLevels, lay.tileWidth);
        memset(&tex, 0, sizeof tex);
    }

    // ③ 调试 ID：同一对象稳定（本层用初始化序号；这里对象未初始化，要求两次查询一致即可）
    uint64_t a = dbg(&tex), b = dbg(&tex);
    CHECK(a == b, "GetDebugID 同一对象两次不一致：%llu vs %llu", (unsigned long long)a, (unsigned long long)b);

    // ④ LINEAR_RENDER_TARGET（0x40）+ 行距：线性排布，存储 = 行距 × 高（10-29 1-2-Switch 影片帧：游戏按 w×h 行 memcpy 上传、90 MiB 定长堆按线性算 30 帧；
    //   按块线性算每张大 ~11%，第 28 帧起堆不够、块的 pool 留 0，游戏拿空 pool 调 MemoryPoolMap 崩）。期望值按公式算：1920×1080×1 字节
    union { NVNtextureBuilder b; char raw[0x80]; } lb; memset(&lb, 0, sizeof lb);
    bdef(&lb.b); btgt(&lb.b, (NVNtextureTarget)1); bfmt(&lb.b, (NVNformat)1); bsz(&lb.b, 1920, 1080); bflg(&lb.b, 0x40); bstr(&lb.b, 1920);
    size_t got = bsize(&lb.b);
    CHECK(got == (size_t)1920 * 1080, "LINEAR_RENDER_TARGET 1920×1080 R8 行距 1920：存储 %zu（应 %d = 行距 × 高）", got, 1920 * 1080);
    bflg(&lb.b, 0); size_t blk = bsize(&lb.b);   // 负对照：不带线性标志仍按块线性，比线性大
    CHECK(blk > (size_t)1920 * 1080, "块线性 1920×1080 R8：存储 %zu（应大于线性的 %d）", blk, 1920 * 1080);

    printf("%s t_nvn_tex：GL 名字往返、稀疏布局同构造器口径、调试 ID 稳定、线性渲染目标存储 → %s\n", bad ? "✗" : "✓", bad ? "有不符合项" : "通过");
    return bad != 0;
}
