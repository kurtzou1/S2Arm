// 维度不符时绑的是游戏开局占位贴图，不标红（tex_mis_placeholder）。一款第一方游戏：texture ID 258 = 序号 6、4x4 RGBA8 2D，游戏开局绑进各阶段 0 号槽，
//   模型着色器变体把槽 3 / 8 声明成 3D 时也塞它；读 0 同 Ryujinx，原先每局标红、分诊里总被当线索（271 份日志）。
// 期望按规则手写（序号 < 64 且 ≤ 4x4x1、单层单级 = 占位；与被测实现无关）：
//   正例 ① 序号 6、4x4x1、1 层 1 级 → 占位
//   另：3D 贴图在 2D / 2D 数组槽 → 普通行（⑦⑧）；2D 在 3D 槽、缓冲贴图在 2D 槽、3D 在立方槽 → 照旧标红（⑨⑩⑪）
//   反例 ② 序号 6、8x8 → 不是；③ 序号 500、4x4 → 不是（局中建的小贴图照旧标红）；④ 序号 6、4x4x2（3D 两层深）→ 不是；⑤ 序号 6、4x4、3 级 → 不是；⑥ 序号 0（没登记）→ 不是
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, fails;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

int main(void) {
    VERIFY(tex_mis_placeholder(6, 4, 4, 1, 1, 1), "① 序号 6、4x4x1 单层单级：开局占位，不标红");
    VERIFY(!tex_mis_placeholder(6, 8, 8, 1, 1, 1), "② 序号 6、8x8：不是占位，照旧标红");
    VERIFY(!tex_mis_placeholder(500, 4, 4, 1, 1, 1), "③ 序号 500、4x4：局中建的，照旧标红");
    VERIFY(!tex_mis_placeholder(6, 4, 4, 2, 1, 1), "④ 序号 6、4x4x2：不是占位");
    VERIFY(!tex_mis_placeholder(6, 4, 4, 1, 1, 3), "⑤ 序号 6、4x4 三级：不是占位");
    VERIFY(!tex_mis_placeholder(0, 4, 4, 1, 1, 1), "⑥ 序号 0（没登记）：不是占位");
    // 3D 贴图在声明 2D / 2D 数组的槽：游戏绑了不同维度的贴图，Ryujinx 同样不绑、读 0 → 普通行（tex_mis_3d_in_2d）；期望按规则手写，MTLTextureType 原值 2D=2、2D 数组=3、立方=5、3D=7、缓冲=9
    VERIFY(tex_mis_3d_in_2d(2, 7), "⑦ 3D 在 2D 槽：普通行");
    VERIFY(tex_mis_3d_in_2d(3, 7), "⑧ 3D 在 2D 数组槽：普通行");
    VERIFY(!tex_mis_3d_in_2d(7, 2), "⑨ 2D 在 3D 槽（#674 桥没接上）：照旧标红");
    VERIFY(!tex_mis_3d_in_2d(2, 9), "⑩ 缓冲贴图在 2D 槽：照旧标红");
    VERIFY(!tex_mis_3d_in_2d(5, 7), "⑪ 3D 在立方槽：照旧标红");
    printf("%s t_nvn_tex_mis_placeholder：%u 项，失败 %u\n", fails ? "✗" : "✓", checks, fails);
    return fails ? 1 : 0;
}
