// OpenGL 前端最小绘制路径单测（WP7，docs/研究/GL前端接口.md）：只经 EGL / GL 接口画一帧，从窗口表面贴图读回像素，按 GL 规范手算的期望逐点核对。
// 着色器：同目录 tri.vert / tri.frag / depth.vert（合成 GLSL ES 3.20），由 t_gl_min.sh 在测试时用出包工具 gl_shaders.py 出库（DM_MSL_DIR 指过来）。
// ① 方向：存储按 GL 行序（第 0 行在底）。三角形 (−1,−1)(1,−1)(−1,1) 盖住 NDC 里 x + y ≤ 0 的一半；视口 1280×720（表面 1920×1080 的左下），
//    GL 坐标 (300, 600) → NDC (−0.531, 0.667)，和 0.135 > 0 → 清屏蓝；(300, 120) → (−0.531, −0.667)，和 −1.198 → 三角形。存储第 600 行第 300 列必须是蓝。
// ② uniform：uTint = (0.5, 1, 1, 1)，顶点色红 (1, 0, 0) → 片元 (0.5, 0, 0, 1)，RGBA8 红通道 round(0.5 × 255) = 128（允许 ±1）。
// ③ 剔除：开背面剔除。上面那个三角形在 GL 里逆时针（正面）照画；第二个三角形 (1,1)(1,0)(0,1) 顺时针（背面）用绿色，必须被剔掉：
//    GL 坐标 (1200, 600) → NDC (0.875, 0.667)，在第二个三角形里（x ≥ 0、y ≥ 0、x + y ≥ 1），期望仍是清屏蓝。
// ④ 命令顺序：更新只影响后面的绘制，之前编码的绘制仍读旧存储；库里没有的源码编译状态 0。
// ⑤ ubyte 索引：奇数偏移、128 / 255 普通索引，以及 SubData 前后同遍绘制的独立快照。
#include "../../gfx/gl/gl_int.h"
#include <unistd.h>

#include "t_gl_stubs.inc"   // 公共后端 / 宽屏核心替身（与 t_gl_api 共用）

typedef void *(*gpa_t)(const char *);
#define F(name, ret, ...) ret (*name)(__VA_ARGS__) = (ret (*)(__VA_ARGS__))gpa(#name); if (!name) { printf("✗ 取不到 %s\n", #name); return 1; }
static int fails, checks;
#define CHECK(c, ...) do { checks++; if (c) printf("  过 " __VA_ARGS__); else { printf("  败 " __VA_ARGS__); fails++; } printf("\n"); } while (0)

#include "t_gl_alloc.inc"

static void readpx(id<MTLTexture> t, uint32_t x, uint32_t y, uint8_t px[4]) {   // 存储第 y 行第 x 列
    id<MTLDevice> d = (__bridge id<MTLDevice>)mtl_device(); id<MTLBuffer> b = [d newBufferWithLength:4 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [d newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x, y, 0) sourceSize:MTLSizeMake(1, 1, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:4 destinationBytesPerImage:4];
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted]; memcpy(px, b.contents, 4);
}
static int near(int a, int b) { return a - b <= 1 && b - a <= 1; }
static void depth_pixel(id<MTLTexture> t, int cell, const uint8_t expected[4], const char *label) {
    uint8_t p[4]; readpx(t, (uint32_t)(cell*32+16), 16, p);
    CHECK(near(p[0], expected[0]) && near(p[1], expected[1]) && near(p[2], expected[2]) && near(p[3], expected[3]),
          "%s[%d]：期望 %u %u %u %u，实测 %u %u %u %u", label, cell, expected[0], expected[1], expected[2], expected[3], p[0], p[1], p[2], p[3]);
}
static void blend_pixel(id<MTLTexture> t, int cell, const uint8_t expected[4], const char *label) {
    uint8_t p[4]; readpx(t, (uint32_t)(cell * 32 + 16), 16, p);
    CHECK(near(p[0], expected[0]) && near(p[1], expected[1]) && near(p[2], expected[2]) && near(p[3], expected[3]),
          "%s[%d]：期望 %u %u %u %u，实测 %u %u %u %u", label, cell, expected[0], expected[1], expected[2], expected[3], p[0], p[1], p[2], p[3]);
}

// 四个三角形依次朝下、右、上、左，按 GL 的最后顶点 flat 颜色应为绿、黄、青、品红。
// 顶点着色器同时核对原始 gl_VertexID；丢 first、截断索引或重编号会输出黑色。
static void fan_pixels(id<MTLTexture> col, const char *label, int culled) {
    const unsigned xy[][2] = {{640, 144}, {1024, 360}, {640, 576}, {256, 360}};
    const uint8_t colors[][3] = {{0,255,0}, {255,255,0}, {0,255,255}, {255,0,255}};
    for (unsigned i = 0; i < 4; i++) {
        uint8_t px[4]; readpx(col, xy[i][0], xy[i][1], px);
        int ok = culled ? px[0] == 0 && px[1] == 0 && px[2] == 255 : memcmp(px, colors[i], 3) == 0;
        CHECK(ok && px[3] == 255, "⑥ %s，扇面 %u：%u %u %u %u", label, i, px[0], px[1], px[2], px[3]);
    }
}
static int triangle_fans(gpa_t gpa, id<MTLTexture> col) {
    F(glGenBuffers, void, GLsizei, GLuint *) F(glDeleteBuffers, void, GLsizei, const GLuint *) F(glBindBuffer, void, GLenum, GLuint)
    F(glBufferData, void, GLenum, GLsizeiptr, const void *, GLenum) F(glBufferSubData, void, GLenum, GLintptr, GLsizeiptr, const void *)
    F(glGenVertexArrays, void, GLsizei, GLuint *) F(glBindVertexArray, void, GLuint) F(glVertexAttribPointer, void, GLuint, GLint, GLenum, GLuint, GLsizei, const void *)
    F(glEnableVertexAttribArray, void, GLuint) F(glCreateShader, GLuint, GLenum) F(glShaderSource, void, GLuint, GLsizei, const GLchar *const *, const GLint *)
    F(glCompileShader, void, GLuint) F(glGetShaderiv, void, GLuint, GLenum, GLint *) F(glCreateProgram, GLuint, void) F(glAttachShader, void, GLuint, GLuint)
    F(glLinkProgram, void, GLuint) F(glGetProgramiv, void, GLuint, GLenum, GLint *) F(glUseProgram, void, GLuint) F(glGetAttribLocation, GLint, GLuint, const GLchar *)
    F(glClear, void, GLbitfield) F(glDrawArrays, void, GLenum, GLint, GLsizei) F(glDrawElements, void, GLenum, GLsizei, GLenum, const void *)
    F(glFinish, void, void) F(glGetError, GLenum, void)
    GLuint prog = glCreateProgram(); GLint ok;
    for (unsigned i = 0; i < 2; i++) {
        char path[1024]; snprintf(path, sizeof path, "%s/fan.%s", getenv("T_GL_DIR"), i ? "frag" : "vert");
        FILE *file = fopen(path, "rb"); if (!file) return 1;
        fseek(file, 0, SEEK_END); long length = ftell(file); rewind(file);
        char *source = calloc(1, (size_t)length + 1); if (!source) { fclose(file); return 1; }
        if (fread(source, 1, (size_t)length, file) != (size_t)length) { free(source); fclose(file); return 1; } fclose(file);
        GLuint shader = glCreateShader(i ? 0x8B30 : 0x8B31); const GLchar *text = source;
        glShaderSource(shader, 1, &text, NULL); free(source); glCompileShader(shader); glGetShaderiv(shader, 0x8B81, &ok);
        CHECK(ok == 1, "⑥ fan %s 从真实 GLSL 离线库加载", i ? "frag" : "vert"); glAttachShader(prog, shader);
    }
    glLinkProgram(prog); glGetProgramiv(prog, 0x8B82, &ok); CHECK(ok == 1, "⑥ flat / gl_VertexID 程序链接"); glUseProgram(prog);
    GLuint vao, vbo, ebo; glGenVertexArrays(1, &vao); glBindVertexArray(vao);
    glGenBuffers(1, &vbo); glBindBuffer(0x8892, vbo); glGenBuffers(1, &ebo); glBindBuffer(0x8893, ebo);
    const char *names[] = {"aPos", "aCol", "aID"}; const int sizes[] = {2,3,1}, offsets[] = {0,8,20};
    for (unsigned i = 0; i < 3; i++) {
        GLint slot = glGetAttribLocation(prog, names[i]); CHECK(slot >= 0, "⑥ 属性 %s 存在", names[i]);
        glVertexAttribPointer((GLuint)slot, sizes[i], 0x1406, 0, 24, (void *)(uintptr_t)offsets[i]); glEnableVertexAttribArray((GLuint)slot);
    }
    const float vertices[][6] = {{0,0,0,0,0,0}, {-.8f,-.8f,1,0,0,0}, {.8f,-.8f,0,1,0,0},
                                {.8f,.8f,1,1,0,0}, {-.8f,.8f,0,1,1,0}, {-.8f,-.8f,1,0,1,0}};
    float array[10][6] = {0};
    for (unsigned i = 0; i < 6; i++) { memcpy(array[i + 3], vertices[i], sizeof vertices[i]); array[i + 3][5] = i + 3; }
    memcpy(array[9], array[8], sizeof array[9]); array[9][5] = 9;   // 多出的扇面退化，用于触发公共索引缓存扩容。
    glBufferData(0x8892, sizeof array, array, 0x88E4);
    uint64_t fr, dr, pa, bf, be, dr0, pa0, bf0, be0;
    dm_gl_stats(&fr, &dr0, &pa0); dm_gl_bad_draws(&bf0, &be0);
    glClear(0x4000); glDrawArrays(6, 3, 6); glFinish(); fan_pixels(col, "DrawArrays first=3 / last provoking", 0);
    dm_gl_stats(&fr, &dr, &pa); dm_gl_bad_draws(&bf, &be);
    CHECK(dr == dr0 + 1 && pa == pa0 + 1 && bf == bf0 && be == be0 && glGetError() == 0, "⑥ 四片扇面只计一次 draw / pass，无坏绘制");
    uint8_t probe[4];
    glClear(0x4000); glDrawArrays(6, 3, 3); glFinish(); readpx(col, 640, 576, probe);
    CHECK(probe[0] == 0 && probe[1] == 0 && probe[2] == 255, "⑥ DrawArrays 改 count 后仅画下方一片，上方蓝");
    glClear(0x4000); glDrawArrays(6, 4, 3); glFinish(); readpx(col, 640, 144, probe);
    CHECK(probe[0] == 255 && probe[1] == 255 && probe[2] == 0, "⑥ DrawArrays 改 first 后下方为黄，缓存不串区间");
    glClear(0x4000); glDrawArrays(6, 3, 7); glFinish(); fan_pixels(col, "DrawArrays 公共索引扩容后 first / flat 保持", 0);
    glClear(0x4000); glDrawArrays(6, 3, 6); glFinish(); fan_pixels(col, "DrawArrays 扩容后复用较短前缀", 0);

    const unsigned ids[][6] = {{128,255,0,129,1,254}, {32768,65535,0,32769,1,65534}, {65536,65535,0,32769,1,65534}};
    const GLenum types[] = {0x1401,0x1403,0x1405}; const size_t widths[] = {1,2,4};
    for (unsigned kind = 0; kind < 3; kind++) {
        float (*data)[6] = calloc(65537, sizeof *data); if (!data) return 1;
        for (unsigned i = 0; i < 6; i++) { memcpy(data[ids[kind][i]], vertices[i], sizeof vertices[i]); data[ids[kind][i]][5] = ids[kind][i]; }
        glBufferData(0x8892, 65537 * sizeof *data, data, 0x88E4); free(data);
        uint8_t indices[36] = {0}, reversed[24] = {0}; size_t width = widths[kind];
        for (unsigned i = 0; i < 6; i++) { // 三个前缀是有效但退化的索引，后续才是扇面；反序列表为顺时针。
            uint32_t value = ids[kind][i], reverse = ids[kind][i ? 6 - i : 0];
            memcpy(indices + (i + 3) * width, &value, width); memcpy(reversed + i * width, &reverse, width);
        }
        glBufferData(0x8893, 9 * width, indices, 0x88E4);
        glClear(0x4000); glDrawElements(6, 6, types[kind], (void *)(3 * width)); glFinish();
        fan_pixels(col, kind == 0 ? "ubyte offset 3" : kind == 1 ? "ushort offset 6 / 65535" : "uint offset 12 / 65536", 0);
        glClear(0x4000); glDrawElements(6, 3, types[kind], (void *)(3 * width)); glFinish(); readpx(col, 640, 576, probe);
        CHECK(probe[0] == 0 && probe[1] == 0 && probe[2] == 255, "⑥ indexed fan 改 count 后上方蓝，宽 %zu", width);
        glClear(0x4000); glDrawElements(6, 3, types[kind], (void *)(4 * width)); glFinish(); readpx(col, 640, 144, probe);
        CHECK(probe[0] == 255 && probe[1] == 255 && probe[2] == 0, "⑥ indexed fan 改 offset 后下方黄，宽 %zu", width);
        // 第一笔必须保留旧 EBO；第二笔反序扇面必须被剔除，不能覆盖第一笔颜色。
        dm_gl_stats(&fr, &dr0, &pa0);
        glClear(0x4000); glDrawElements(6, 6, types[kind], (void *)(3 * width));
        glBufferSubData(0x8893, 3 * width, 6 * width, reversed); glDrawElements(6, 6, types[kind], (void *)(3 * width)); glFinish();
        fan_pixels(col, "同遍 SubData 保留旧扇面且剔除新顺时针扇面", 0);
        dm_gl_stats(&fr, &dr, &pa); CHECK(dr == dr0 + 2 && pa == pa0 + 1 && glGetError() == 0, "⑥ 两次 fan 绘制 / 一遍，索引宽 %zu", width);
        glClear(0x4000); glDrawElements(6, 6, types[kind], (void *)(3 * width)); glFinish(); fan_pixels(col, "独立顺时针扇面被剔除", 1);
        // 原存储孤立和删除都不能改变已经编码的索引。
        glBufferData(0x8893, 9 * width, indices, 0x88E4); glClear(0x4000); glDrawElements(6, 6, types[kind], (void *)(3 * width));
        glBufferData(0x8893, 6 * width, reversed, 0x88E4); glDeleteBuffers(1, &ebo); glFinish(); fan_pixels(col, "orphan / delete 后已编码扇面保持", 0);
        glGenBuffers(1, &ebo); glBindBuffer(0x8893, ebo); glBufferData(0x8893, 9 * width, indices, 0x88E4);
        dm_gl_bad_draws(&bf0, &be0); dm_gl_stats(&fr, &dr0, &pa0);
        glDrawElements(6, 6, types[kind], (void *)(3 * width + 1)); GLenum error = glGetError(); dm_gl_bad_draws(&bf, &be);
        CHECK(error == 0x0502 && bf == bf0 && be == be0 + 1, "⑥ fan 索引少一字节明确拒绝，宽 %zu", width);
        glDrawElements(6, 6, types[kind], (void *)UINTPTR_MAX); error = glGetError(); dm_gl_stats(&fr, &dr, &pa);
        CHECK(error == 0x0502 && dr == dr0 && pa == pa0, "⑥ fan 极大偏移拒绝且不编码，宽 %zu", width);
    }
    glBindBuffer(0x8893, 0); dm_gl_stats(&fr, &dr0, &pa0); dm_gl_bad_draws(&bf0, &be0);
    for (int n = 0; n < 3; n++) { glDrawArrays(6, 3, n); glDrawElements(6, n, 0x1405, (void *)UINTPTR_MAX); }
    dm_gl_stats(&fr, &dr, &pa); dm_gl_bad_draws(&bf, &be);
    CHECK(dr == dr0 && pa == pa0 && bf == bf0 && be == be0 && glGetError() == 0, "⑥ 少于三个顶点不生成三角形、不读取 EBO / 分配 / 编码");
    glDrawArrays(6, -1, 6); CHECK(glGetError() == 0x0501, "⑥ fan 负 first → INVALID_VALUE");
    glDrawArrays(6, 0, -1); CHECK(glGetError() == 0x0501, "⑥ fan 负 count → INVALID_VALUE");
    glDrawElements(6, -1, 0x1405, NULL); CHECK(glGetError() == 0x0501, "⑥ indexed fan 负 count → INVALID_VALUE");
    glDrawElements(6, 0, 0x1406, NULL); CHECK(glGetError() == 0x0500, "⑥ fan 空绘制也拒绝非法索引类型");
    // 客户端内存顶点 / 索引数组（Slay the Spire：不绑缓冲，指针直接给游戏内存）：同一组扇面，判据同上
    F(glGetActiveAttrib, void, GLuint, GLuint, GLsizei, GLsizei *, GLint *, GLenum *, GLchar *) F(glGetActiveUniform, void, GLuint, GLuint, GLsizei, GLsizei *, GLint *, GLenum *, GLchar *)
    glGetProgramiv(prog, 0x8B89, &ok); CHECK(ok == 3, "⑧ GL_ACTIVE_ATTRIBUTES = 3（实测 %d）", ok);
    GLint maxlen = 0; glGetProgramiv(prog, 0x8B8A, &maxlen); CHECK(maxlen == 5, "⑧ GL_ACTIVE_ATTRIBUTE_MAX_LENGTH = 5（aPos / aCol + 结尾 0；实测 %d）", maxlen);
    int seen = 0; for (GLuint i = 0; i < 3; i++) { char nm[16] = {0}; GLsizei len = -1; GLint size = 0; GLenum ty = 0; glGetActiveAttrib(prog, i, sizeof nm, &len, &size, &ty, nm);
        for (unsigned k = 0; k < 3; k++) if (!strcmp(nm, names[k]) && len == (GLsizei)strlen(names[k]) && size == 1 && ty == (k == 0 ? 0x8B50u : k == 1 ? 0x8B51u : 0x1406u)) seen |= 1 << k; }
    CHECK(seen == 7 && glGetError() == 0, "⑧ glGetActiveAttrib 三个属性名字 / 类型（vec2 vec3 float）都对（掩码 %d）", seen);
    GLint nu = -1; glGetProgramiv(prog, 0x8B86, &nu); { char nm[8]; GLsizei len; GLint size; GLenum ty; glGetActiveUniform(prog, (GLuint)nu, sizeof nm, &len, &size, &ty, nm); }
    CHECK(nu == 0 && glGetError() == 0x0501, "⑧ GL_ACTIVE_UNIFORMS = 0（实测 %d），越界下标 → INVALID_VALUE", nu);
    glBindVertexArray(0); glBindBuffer(0x8892, 0);   // GLES 缺省顶点数组 0（游戏的用法；它不在名字表里）
    for (unsigned i = 0; i < 3; i++) { GLuint at = (GLuint)glGetAttribLocation(prog, names[i]); glVertexAttribPointer(at, sizes[i], 0x1406, 0, 24, (const uint8_t *)array + offsets[i]); glEnableVertexAttribArray(at); }
    CHECK(glGetError() == 0, "⑧ 没绑数组缓冲时 glVertexAttribPointer 收客户端指针");
    dm_gl_bad_draws(&bf0, &be0);
    glClear(0x4000); glDrawArrays(6, 3, 6); glFinish(); fan_pixels(col, "客户端内存顶点 DrawArrays first=3（≤ 4 KB）", 0);
    float (*big)[6] = calloc(65537, sizeof *big); if (!big) return 1;
    const uint16_t cix[] = {32768, 65535, 0, 32769, 1, 65534};
    for (unsigned i = 0; i < 6; i++) { memcpy(big[cix[i]], vertices[i], sizeof vertices[i]); big[cix[i]][5] = cix[i]; }
    for (unsigned i = 0; i < 3; i++) glVertexAttribPointer((GLuint)glGetAttribLocation(prog, names[i]), sizes[i], 0x1406, 0, 24, (const uint8_t *)big + offsets[i]);
    glClear(0x4000); glDrawElements(6, 6, 0x1403, cix); glFinish(); fan_pixels(col, "客户端内存索引 + 顶点（顶点 1.5 MB）", 0);
    const uint8_t cix8[] = {128, 255, 0, 129, 1, 254}; memset(big, 0, 65537 * sizeof *big);
    for (unsigned i = 0; i < 6; i++) { memcpy(big[cix8[i]], vertices[i], sizeof vertices[i]); big[cix8[i]][5] = cix8[i]; }
    glClear(0x4000); glDrawElements(6, 6, 0x1401, cix8); glFinish(); fan_pixels(col, "客户端内存 ubyte 索引", 0);
    free(big); dm_gl_bad_draws(&bf, &be);
    CHECK(bf == bf0 && be == be0 && glGetError() == 0, "⑧ 客户端内存数组绘制无坏绘制（缺功能 +%llu、出错 +%llu）", (unsigned long long)(bf - bf0), (unsigned long long)(be - be0));
    // glBindAttribLocation（街霸 30 周年合集，GLSL ES 1.00 的程序链接前按名字定属性号）：aPos → 7、aCol → 2 下一次链接生效；
    //   没绑的 aID 取自己的翻译槽，和绑过的撞号就取最小空号。期望按链接前读到的槽算，再用新属性号喂同一组扇面，判据同上（读错数组则颜色 / 位置错）
    F(glBindAttribLocation, void, GLuint, GLuint, const GLchar *) F(glLineWidth, void, GLfloat) F(glGetFloatv, void, GLenum, GLfloat *) F(glDisableVertexAttribArray, void, GLuint)
    GLint sid = glGetAttribLocation(prog, "aID"), want_id = sid == 7 || sid == 2 ? 0 : sid;
    glBindAttribLocation(prog, 7, "aPos"); glBindAttribLocation(prog, 2, "aCol");
    CHECK(glGetAttribLocation(prog, "aPos") != 7 && glGetError() == 0, "⑧′ glBindAttribLocation 链接前不生效");
    glBindAttribLocation(prog, 16, "aPos"); CHECK(glGetError() == 0x0501, "⑧′ 属性号 16 → INVALID_VALUE");
    glBindAttribLocation(prog, 3, "gl_Vertex"); CHECK(glGetError() == 0x0502, "⑧′ gl_ 前缀 → INVALID_OPERATION");
    glLinkProgram(prog); glGetProgramiv(prog, 0x8B82, &ok); glUseProgram(prog);
    GLint lp = glGetAttribLocation(prog, "aPos"), lc = glGetAttribLocation(prog, "aCol"), li = glGetAttribLocation(prog, "aID");
    CHECK(ok == 1 && lp == 7 && lc == 2 && li == want_id, "⑧′ 重链接后 aPos 7 / aCol 2 / aID %d（实测 %d / %d / %d，aID 原槽 %d）", want_id, lp, lc, li, sid);
    for (GLuint i = 0; i < 16; i++) glDisableVertexAttribArray(i);
    for (unsigned i = 0; i < 3; i++) { GLuint at = (GLuint)glGetAttribLocation(prog, names[i]); glVertexAttribPointer(at, sizes[i], 0x1406, 0, 24, (const uint8_t *)array + offsets[i]); glEnableVertexAttribArray(at); }
    dm_gl_bad_draws(&bf0, &be0);
    glClear(0x4000); glDrawArrays(6, 3, 6); glFinish(); fan_pixels(col, "绑过属性号后 DrawArrays first=3", 0);
    dm_gl_bad_draws(&bf, &be); CHECK(bf == bf0 && be == be0 && glGetError() == 0, "⑧′ 绑过属性号的绘制无坏绘制");
    GLfloat lw = 0; glLineWidth(2.5f); glGetFloatv(0x0B21, &lw); CHECK(lw == 2.5f && glGetError() == 0, "⑧′ glLineWidth 记下宽度（GL_LINE_WIDTH 读回 %g）", lw);
    glLineWidth(0); CHECK(glGetError() == 0x0501, "⑧′ 线宽 0 → INVALID_VALUE");
    return 0;
}

static void cull_pixel(id<MTLTexture> col, unsigned x, unsigned y, const uint8_t expected[4], const char *label) {
    uint8_t px[4]; readpx(col, x, y, px);
    CHECK(memcmp(px, expected, 4) == 0, "⑦ %s (%u,%u)：期望 %u %u %u %u，实测 %u %u %u %u", label, x, y,
          expected[0], expected[1], expected[2], expected[3], px[0], px[1], px[2], px[3]);
}
static int cull_states(gpa_t gpa, id<MTLTexture> col) {
    F(glCreateShader, GLuint, GLenum) F(glShaderSource, void, GLuint, GLsizei, const GLchar *const *, const GLint *)
    F(glCompileShader, void, GLuint) F(glGetShaderiv, void, GLuint, GLenum, GLint *) F(glCreateProgram, GLuint, void)
    F(glAttachShader, void, GLuint, GLuint) F(glLinkProgram, void, GLuint) F(glGetProgramiv, void, GLuint, GLenum, GLint *) F(glUseProgram, void, GLuint)
    F(glGetAttribLocation, GLint, GLuint, const GLchar *) F(glGetUniformLocation, GLint, GLuint, const GLchar *)
    F(glUniform1f, void, GLint, GLfloat) F(glUniform4f, void, GLint, GLfloat, GLfloat, GLfloat, GLfloat)
    F(glGenVertexArrays, void, GLsizei, GLuint *) F(glBindVertexArray, void, GLuint) F(glGenBuffers, void, GLsizei, GLuint *)
    F(glBindBuffer, void, GLenum, GLuint) F(glBufferData, void, GLenum, GLsizeiptr, const void *, GLenum)
    F(glVertexAttribPointer, void, GLuint, GLint, GLenum, GLuint, GLsizei, const void *) F(glEnableVertexAttribArray, void, GLuint)
    F(glFrontFace, void, GLenum) F(glCullFace, void, GLenum) F(glEnable, void, GLenum) F(glDisable, void, GLenum)
    F(glViewport, void, GLint, GLint, GLsizei, GLsizei) F(glScissor, void, GLint, GLint, GLsizei, GLsizei)
    F(glClearColor, void, GLfloat, GLfloat, GLfloat, GLfloat) F(glClearDepthf, void, GLfloat) F(glClear, void, GLbitfield)
    F(glDrawArrays, void, GLenum, GLint, GLsizei) F(glDrawElements, void, GLenum, GLsizei, GLenum, const void *)
    F(glFinish, void, void) F(glGetError, GLenum, void)
    GLuint prog = glCreateProgram(); GLint ok;
    for (unsigned i = 0; i < 2; i++) {
        char path[1024]; snprintf(path, sizeof path, "%s/%s", getenv("T_GL_DIR"), i ? "tri.frag" : "cull.vert");
        FILE *file = fopen(path, "rb"); if (!file) return 1;
        fseek(file, 0, SEEK_END); long length = ftell(file); rewind(file);
        char *source = calloc(1, (size_t)length+1); if (!source) { fclose(file); return 1; }
        if (fread(source, 1, (size_t)length, file) != (size_t)length) { free(source); fclose(file); return 1; } fclose(file);
        GLuint shader = glCreateShader(i ? 0x8B30 : 0x8B31); const GLchar *text = source;
        glShaderSource(shader, 1, &text, NULL); free(source); glCompileShader(shader); glGetShaderiv(shader, 0x8B81, &ok);
        CHECK(ok == 1, "⑦ cull %s 离线着色器加载", i ? "frag" : "vert"); glAttachShader(prog, shader);
    }
    glLinkProgram(prog); glGetProgramiv(prog, 0x8B82, &ok); CHECK(ok == 1, "⑦ cull 程序链接"); glUseProgram(prog);
    GLint pos = glGetAttribLocation(prog, "aPos"), color = glGetAttribLocation(prog, "aCol");
    GLint z = glGetUniformLocation(prog, "uZ"), tint = glGetUniformLocation(prog, "uTint");
    CHECK(pos >= 0 && color >= 0 && pos != color && z >= 0 && tint >= 0, "⑦ cull 属性 / uniform 有效");
    // 前六点：左三角 CCW 红、右三角 CW 绿。32×32 视口内 (3,8)/(18,8) 严格位于各自内部。
    // 其后依次是覆盖全格的 CCW 三角、CCW strip、CCW fan、点、水平线；点径由着色器显式设为 8。
    const float vertices[][5] = {
        {-.9f,-.8f,1,0,0}, {-.1f,-.8f,1,0,0}, {-.9f,.8f,1,0,0},
        {.1f,-.8f,0,1,0}, {.1f,.8f,0,1,0}, {.9f,-.8f,0,1,0},
        {-1,-1,1,1,1}, {3,-1,1,1,1}, {-1,3,1,1,1},
        {-.8f,-.8f,1,1,1}, {.8f,-.8f,1,1,1}, {-.8f,.8f,1,1,1}, {.8f,.8f,1,1,1},
        {0,0,1,1,1}, {-.8f,-.8f,1,1,1}, {.8f,-.8f,1,1,1}, {.8f,.8f,1,1,1}, {-.8f,.8f,1,1,1}, {-.8f,-.8f,1,1,1},
        {.03125f,.03125f,1,1,1}, {-.75f,.03125f,1,1,1}, {.75f,.03125f,1,1,1},
    };
    const uint16_t indices[] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21};
    GLuint vao, vbo, ebo; glGenVertexArrays(1, &vao); glBindVertexArray(vao);
    glGenBuffers(1, &vbo); glBindBuffer(0x8892, vbo); glBufferData(0x8892, sizeof vertices, vertices, 0x88E4);
    glGenBuffers(1, &ebo); glBindBuffer(0x8893, ebo); glBufferData(0x8893, sizeof indices, indices, 0x88E4);
    glVertexAttribPointer((GLuint)pos, 2, 0x1406, 0, 20, (void *)0); glEnableVertexAttribArray((GLuint)pos);
    glVertexAttribPointer((GLuint)color, 3, 0x1406, 0, 20, (void *)8); glEnableVertexAttribArray((GLuint)color);
    enum { CULL = 0x0B44, DEPTH = 0x0B71, SCISSOR = 0x0C11, CW = 0x0900, CCW = 0x0901, FRONT = 0x0404, BACK = 0x0405, BOTH = 0x0408 };
    const uint8_t red[] = {255,0,0,255}, green[] = {0,255,0,255}, blue[] = {0,0,255,255};
    glDisable(DEPTH); glDisable(SCISSOR); glDisable(0x0BE2); glClearColor(0,0,1,1); glUniform1f(z, 0); glUniform4f(tint, 1,1,1,1);
    uint64_t fr, dr, pa, dr0, pa0, bf, be, bf0, be0; dm_gl_bad_draws(&bf0, &be0);
#define CVIEW(cell) glViewport((cell)*32, 0, 32, 32)
#define CPAIR(cell) do { CVIEW(cell); glDrawArrays(4, 0, 6); } while (0)
#define CPIX(cell, expected, label) cull_pixel(col, (cell)*32+16, 16, expected, label)
    static const struct { GLenum front, cull; int left, right; } states[] = {
        {CCW,FRONT,0,1}, {CCW,BACK,1,0}, {CCW,BOTH,0,0}, {CW,FRONT,1,0}, {CW,BACK,0,1}, {CW,BOTH,0,0},
    };
    glClear(0x4000); glEnable(CULL); dm_gl_stats(&fr, &dr0, &pa0);
    for (int i = 0; i < 6; i++) { glFrontFace(states[i].front); glCullFace(states[i].cull); CPAIR(i); }
    glDisable(CULL); CPAIR(6); glEnable(CULL); CPAIR(7);
    glCullFace(BACK); CPAIR(8); glFrontFace(CCW); CPAIR(9); glFinish();
    for (int i = 0; i < 6; i++) {
        cull_pixel(col, i*32+3, 8, states[i].left ? red : blue, "CW/CCW × FRONT/BACK/BOTH 左侧");
        cull_pixel(col, i*32+18, 8, states[i].right ? green : blue, "CW/CCW × FRONT/BACK/BOTH 右侧");
    }
    cull_pixel(col, 6*32+3, 8, red, "disable BOTH 左红"); cull_pixel(col, 6*32+18, 8, green, "disable BOTH 右绿");
    cull_pixel(col, 7*32+3, 8, blue, "重新 enable BOTH 左蓝"); cull_pixel(col, 7*32+18, 8, blue, "重新 enable BOTH 右蓝");
    cull_pixel(col, 8*32+3, 8, blue, "CW/BACK 左蓝"); cull_pixel(col, 8*32+18, 8, green, "CW/BACK 右绿");
    cull_pixel(col, 9*32+3, 8, red, "切回 CCW/BACK 左红"); cull_pixel(col, 9*32+18, 8, blue, "切回 CCW/BACK 右蓝");
    dm_gl_stats(&fr, &dr, &pa); CHECK(dr == dr0+10 && pa == pa0+1, "⑦ winding / cull / enable 的 10 笔状态切换只开一遍");
    CPAIR(10); glFinish(); cull_pixel(col, 10*32+3, 8, red, "新编码器恢复 CCW/BACK 左红");
    cull_pixel(col, 10*32+18, 8, blue, "新编码器恢复 CCW/BACK 右蓝");

    // 六种三角形调用各画 BOTH→BACK 一对，随后 BOTH 下的点 / 线仍要有片元；再画三角形检验恢复。
    const GLenum modes[] = {4,5,6}; const GLint first[] = {6,9,13}; const GLsizei count[] = {3,4,6};
    glClear(0x4000); glUniform4f(tint, 0,1,0,1); dm_gl_stats(&fr, &dr0, &pa0);
    for (int i = 0; i < 6; i++) {
        int kind = i%3;
        for (int pass = 0; pass < 2; pass++) {
            glCullFace(pass ? BACK : BOTH); CVIEW(i*2+pass);
            if (i < 3) glDrawArrays(modes[kind], first[kind], count[kind]);
            else glDrawElements(modes[kind], count[kind], 0x1403, (void *)(uintptr_t)(first[kind]*2));
        }
    }
    glCullFace(BOTH); CVIEW(12); glDrawArrays(0, 19, 1); CVIEW(13); glDrawElements(1, 2, 0x1403, (void *)(20*2));
    glCullFace(BACK); CVIEW(14); glDrawArrays(4, 6, 3); glFinish();
    for (int i = 0; i < 6; i++) { CPIX(i*2, blue, "BOTH 抑制三角 / strip / fan"); CPIX(i*2+1, green, "BACK 恢复三角 / strip / fan"); }
    CPIX(12, green, "BOTH 仍绘制显式 8 像素点"); CPIX(13, green, "BOTH 仍绘制线段"); CPIX(14, green, "点线后恢复三角形");
    dm_gl_stats(&fr, &dr, &pa); CHECK(dr == dr0+15 && pa == pa0+1, "⑦ BOTH 保留 15 笔 draw 录制，图元 / 管线切换不切遍");

    glClear(0x4000); glUniform4f(tint, 1,1,1,1); glFrontFace(CW); glCullFace(BACK);
    glFrontFace(0xDEAD); CHECK(glGetError() == 0x0500, "⑦ 非法 FrontFace 返回 INVALID_ENUM"); CPAIR(0);
    glCullFace(BOTH); glCullFace(0xDEAD); CHECK(glGetError() == 0x0500, "⑦ 非法 CullFace 返回 INVALID_ENUM"); CPAIR(1);
    glCullFace(BACK); CPAIR(2); glFinish();
    cull_pixel(col, 3, 8, blue, "非法 FrontFace 保持 CW/BACK 左蓝"); cull_pixel(col, 18, 8, green, "非法 FrontFace 保持 CW/BACK 右绿");
    cull_pixel(col, 32+3, 8, blue, "非法 CullFace 保持 BOTH 左蓝"); cull_pixel(col, 32+18, 8, blue, "非法 CullFace 保持 BOTH 右蓝");
    cull_pixel(col, 64+3, 8, blue, "恢复 BACK 后 winding 仍 CW 左蓝"); cull_pixel(col, 64+18, 8, green, "恢复 BACK 后 winding 仍 CW 右绿");

    // 默认深度 LESS / mask=true：BOTH 的 .25 不得污染深度，随后 .5 仍应通过。
    glFrontFace(CCW); glEnable(DEPTH); glClearDepthf(1); glClear(0x4100); glUniform4f(tint, 0,1,0,1);
    dm_gl_stats(&fr, &dr0, &pa0); glCullFace(BOTH); CVIEW(0); glUniform1f(z, -.5f); glDrawArrays(4, 6, 3);
    glCullFace(BACK); glUniform1f(z, 0); glDrawArrays(4, 6, 3); glFinish(); CPIX(0, green, "BOTH 不写 .25 深度，后续 .5 通过");
    dm_gl_stats(&fr, &dr, &pa); CHECK(dr == dr0+2 && pa == pa0+1, "⑦ 深度检查两笔只开一遍");

    // 空 scissor 是 BOTH 的临时编码状态，恢复时既要遵守启用的 GL scissor，也要恢复禁用后的全视口。
    glClear(0x4100); glEnable(SCISSOR); glScissor(0,0,16,32); dm_gl_stats(&fr, &dr0, &pa0);
    for (int i = 0; i < 2; i++) {
        if (i) glDisable(SCISSOR);
        CVIEW(i); glCullFace(BOTH); glUniform1f(z, -.5f); glDrawArrays(4, 6, 3);
        glCullFace(BACK); glUniform1f(z, 0); glDrawArrays(4, 6, 3);
    }
    glFinish(); cull_pixel(col, 8,16,green,"BOTH 后恢复 GL scissor 内部"); cull_pixel(col,24,16,blue,"BOTH 后保持 GL scissor 外部");
    cull_pixel(col,40,16,green,"禁用 GL scissor 后左侧恢复"); cull_pixel(col,56,16,green,"禁用 GL scissor 后右侧恢复");
    dm_gl_stats(&fr, &dr, &pa); CHECK(dr == dr0+4 && pa == pa0+1, "⑦ BOTH / scissor / 深度状态切换的四笔只开一遍");
    dm_gl_bad_draws(&bf, &be); CHECK(bf == bf0 && be == be0 && glGetError() == 0, "⑦ 合法剔除不记坏绘制，错误已完整取走");
    glDisable(DEPTH);
#undef CPIX
#undef CPAIR
#undef CVIEW
    return 0;
}

static void clear_pixel(id<MTLTexture> col, unsigned x, unsigned y, const uint8_t expected[4], const char *label) {
    uint8_t p[4]; readpx(col, x, y, p);
    CHECK(near(p[0], expected[0]) && near(p[1], expected[1]) && near(p[2], expected[2]) && near(p[3], expected[3]),
          "⑦ %s (%u,%u)：期望 %u %u %u %u，实测 %u %u %u %u", label, x, y,
          expected[0], expected[1], expected[2], expected[3], p[0], p[1], p[2], p[3]);
}
// 只依赖基线已实现的入口；即使 glColorMask 缺失，也先实际画出并读回裁剪清除反例。
static int scissored_clears(gpa_t gpa, id<MTLTexture> col) {
    F(glClearColor, void, GLfloat, GLfloat, GLfloat, GLfloat) F(glClear, void, GLbitfield)
    F(glEnable, void, GLenum) F(glDisable, void, GLenum) F(glScissor, void, GLint, GLint, GLsizei, GLsizei)
    F(glViewport, void, GLint, GLint, GLsizei, GLsizei) F(glFinish, void, void) F(glGetError, GLenum, void)
    const uint8_t red[] = {255,0,0,255}, green[] = {0,255,0,255}, blue[] = {0,0,255,255};
    glDisable(0x0C11); glClearColor(0,0,1,1); glClear(0x4000);
    glViewport(64,64,1,1); glEnable(0x0C11); glScissor(8,8,16,16); glClearColor(1,0,0,1); glClear(0x4000); glFinish();
    clear_pixel(col,12,12,red,"裁剪内清红且忽略 viewport"); clear_pixel(col,4,4,blue,"裁剪外保留蓝");
    clear_pixel(col,24,12,blue,"scissor 右端点排除");
    glDisable(0x0C11); glClearColor(0,0,1,1); glClear(0x4000); glEnable(0x0C11);
    uint64_t fr, dr, pa, pa0; dm_gl_stats(&fr, &dr, &pa0);
    glScissor(0,0,16,16); glClearColor(1,0,0,1); glClear(0x4000);
    glScissor(16,0,16,16); glClearColor(0,1,0,1); glClear(0x4000); glFinish();
    dm_gl_stats(&fr, &dr, &pa); CHECK(pa == pa0+1, "⑦ 整屏清后两次局部清除同在一遍（%llu 遍）", (unsigned long long)(pa-pa0));
    clear_pixel(col,8,8,red,"无 draw / 提交的前次清除保留红值和范围");
    clear_pixel(col,24,8,green,"后次清除独立为绿"); clear_pixel(col,40,8,blue,"两次清除外仍蓝");
    glDisable(0x0C11); glViewport(0,0,(GLsizei)col.width,(GLsizei)col.height);
    CHECK(glGetError() == 0,"⑦ 基线裁剪清除的公开入口无 GL 错误");
    return 0;
}

static void clear_depth_stencil(id<MTLTexture> depth, unsigned x, unsigned y, float expected_depth, uint8_t expected_stencil, const char *label) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)mtl_device(); id<MTLBuffer> data = [dev newBufferWithLength:8 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [queue commandBuffer]; id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x,y,0) sourceSize:MTLSizeMake(1,1,1) toBuffer:data
      destinationOffset:0 destinationBytesPerRow:4 destinationBytesPerImage:4 options:MTLBlitOptionDepthFromDepthStencil];
    [blit copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x,y,0) sourceSize:MTLSizeMake(1,1,1) toBuffer:data
      destinationOffset:4 destinationBytesPerRow:1 destinationBytesPerImage:1 options:MTLBlitOptionStencilFromDepthStencil];
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted || cb.error) { fprintf(stderr,"深度 / 模板读回失败：%s\n",cb.error.description.UTF8String); exit(1); }
    float d; memcpy(&d,data.contents,4); uint8_t s = ((uint8_t *)data.contents)[4];
    CHECK(d == expected_depth && s == expected_stencil, "⑦ %s (%u,%u)：深度 %.3f / 模板 %#x，实测 %.3f / %#x", label,x,y,expected_depth,expected_stencil,d,s);
}
static int masked_clears(gpa_t gpa, id<MTLTexture> col) {
    F(glColorMask, void, GLuint, GLuint, GLuint, GLuint) F(glClearColor, void, GLfloat, GLfloat, GLfloat, GLfloat)
    F(glClearDepthf, void, GLfloat) F(glClearStencil, void, GLint) F(glClear, void, GLbitfield)
    F(glEnable, void, GLenum) F(glDisable, void, GLenum) F(glScissor, void, GLint, GLint, GLsizei, GLsizei)
    F(glViewport, void, GLint, GLint, GLsizei, GLsizei) F(glFinish, void, void) F(glGetError, GLenum, void)
    F(glCreateShader, GLuint, GLenum) F(glShaderSource, void, GLuint, GLsizei, const GLchar *const *, const GLint *)
    F(glCompileShader, void, GLuint) F(glGetShaderiv, void, GLuint, GLenum, GLint *) F(glCreateProgram, GLuint, void)
    F(glAttachShader, void, GLuint, GLuint) F(glLinkProgram, void, GLuint) F(glGetProgramiv, void, GLuint, GLenum, GLint *) F(glUseProgram, void, GLuint)
    F(glGetAttribLocation, GLint, GLuint, const GLchar *) F(glGetUniformLocation, GLint, GLuint, const GLchar *)
    F(glUniform2f, void, GLint, GLfloat, GLfloat) F(glUniform4f, void, GLint, GLfloat, GLfloat, GLfloat, GLfloat)
    F(glGenVertexArrays, void, GLsizei, GLuint *) F(glBindVertexArray, void, GLuint) F(glGenBuffers, void, GLsizei, GLuint *)
    F(glBindBuffer, void, GLenum, GLuint) F(glBufferData, void, GLenum, GLsizeiptr, const void *, GLenum)
    F(glVertexAttribPointer, void, GLuint, GLint, GLenum, GLuint, GLsizei, const void *) F(glEnableVertexAttribArray, void, GLuint)
    F(glDrawArrays, void, GLenum, GLint, GLsizei)
    enum { SCISSOR=0x0C11, DEPTH=0x0B71, CULL=0x0B44, BLEND=0x0BE2, COLOR_BIT=0x4000, DEPTH_BIT=0x100, STENCIL_BIT=0x400 };
    const uint8_t dest[] = {17,34,51,68}, red[] = {255,0,0,255}, green[] = {0,255,0,255};
    // 位顺序 RGBA。每个允许写的通道取 S=(221,187,153,119)，其余保留 D=(17,34,51,68)，不依赖 Metal 掩码位序。
    static const uint8_t masked[16][4] = {
        {17,34,51,68}, {221,34,51,68}, {17,187,51,68}, {221,187,51,68},
        {17,34,153,68}, {221,34,153,68}, {17,187,153,68}, {221,187,153,68},
        {17,34,51,119}, {221,34,51,119}, {17,187,51,119}, {221,187,51,119},
        {17,34,153,119}, {221,34,153,119}, {17,187,153,119}, {221,187,153,119},
    };
#define FULL_MASK() glColorMask(1,1,1,1)
#define INIT_DEST() do { glDisable(SCISSOR); FULL_MASK(); glClearColor(17.f/255,34.f/255,51.f/255,68.f/255); glClear(COLOR_BIT); } while (0)
    // 空框、完全越界和 x+width/y+height 超过 INT32_MAX 都不能影响表面；范围运算需先提升再相加。
    INIT_DEST(); glEnable(SCISSOR); glClearColor(1,0,0,1);
    const GLint empty[][4] = {{0,0,0,32}, {0,0,32,0}, {2000,0,32,32}, {0,2000,32,32},
        {-32,-32,16,16}, {INT32_MAX-2,0,8,16}, {0,INT32_MAX-2,16,8}, {INT32_MIN,0,INT32_MAX,16}};
    for (unsigned i=0; i<sizeof empty/sizeof empty[0]; i++) { glScissor(empty[i][0],empty[i][1],empty[i][2],empty[i][3]); glClear(COLOR_BIT); }
    glFinish(); clear_pixel(col,8,8,dest,"空 / 完全越界 / 大整数 scissor 不清除");
    glScissor(-8,-8,24,24); glClear(COLOR_BIT); glFinish();
    clear_pixel(col,8,8,red,"负 origin 取与表面交集"); clear_pixel(col,16,8,dest,"负 origin 的右边界排除"); clear_pixel(col,8,16,dest,"负 origin 的上边界排除");
    INIT_DEST(); glEnable(SCISSOR); glScissor((GLint)col.width-8,0,INT32_MAX,16); glClearColor(1,0,0,1); glClear(COLOR_BIT); glFinish();
    clear_pixel(col,(unsigned)col.width-4,8,red,"正 origin 加大宽度溢出 32 位时仍清右条"); clear_pixel(col,(unsigned)col.width-12,8,dest,"大宽度不越过左边界");
    glScissor(-8,-8,INT32_MAX,INT32_MAX); glClearColor(0,1,0,1); glClear(COLOR_BIT); glFinish();
    clear_pixel(col,(unsigned)col.width-1,(unsigned)col.height-1,green,"巨大裁剪范围截到真实表面");

    GLuint prog=glCreateProgram(); GLint ok;
    for (unsigned i=0; i<2; i++) {
        char path[1024]; snprintf(path,sizeof path,"%s/tri.%s",getenv("T_GL_DIR"),i?"frag":"vert");
        FILE *file=fopen(path,"rb"); if (!file) return 1; fseek(file,0,SEEK_END); long length=ftell(file); rewind(file);
        char *source=calloc(1,(size_t)length+1); if (!source) { fclose(file); return 1; }
        if (fread(source,1,(size_t)length,file)!=(size_t)length) { free(source); fclose(file); return 1; } fclose(file);
        GLuint shader=glCreateShader(i?0x8B30:0x8B31); const GLchar *text=source; glShaderSource(shader,1,&text,NULL); free(source);
        glCompileShader(shader); glGetShaderiv(shader,0x8B81,&ok); CHECK(ok==1,"⑦ 掩码回归 tri.%s 离线加载",i?"frag":"vert"); glAttachShader(prog,shader);
    }
    glLinkProgram(prog); glGetProgramiv(prog,0x8B82,&ok); CHECK(ok==1,"⑦ 掩码回归程序链接"); glUseProgram(prog);
    GLint pos=glGetAttribLocation(prog,"aPos"), color=glGetAttribLocation(prog,"aCol");
    GLint offset=glGetUniformLocation(prog,"uOff"), tint=glGetUniformLocation(prog,"uTint");
    CHECK(pos>=0 && color>=0 && pos!=color && offset>=0 && tint>=0,"⑦ 掩码回归属性 / uniform 有效");
    const float white[]={-1,-1,1,1,1, 3,-1,1,1,1, -1,3,1,1,1}; GLuint vao,vbo;
    glGenVertexArrays(1,&vao); glBindVertexArray(vao); glGenBuffers(1,&vbo); glBindBuffer(0x8892,vbo); glBufferData(0x8892,sizeof white,white,0x88E4);
    glVertexAttribPointer((GLuint)pos,2,0x1406,0,20,(void *)0); glEnableVertexAttribArray((GLuint)pos);
    glVertexAttribPointer((GLuint)color,3,0x1406,0,20,(void *)8); glEnableVertexAttribArray((GLuint)color);
    glUniform2f(offset,0,0); glUniform4f(tint,221.f/255,187.f/255,153.f/255,119.f/255);
    glDisable(DEPTH); glDisable(CULL); glDisable(BLEND); INIT_DEST();
    glViewport(0,0,32,32); glEnable(SCISSOR);
    glScissor(-32,-32,16,16); glDrawArrays(4,0,3); glScissor(2000,0,32,32); glDrawArrays(4,0,3);
    glScissor(0,2000,32,32); glDrawArrays(4,0,3); glFinish(); clear_pixel(col,8,8,dest,"普通绘制完全越界 scissor 不改像素");
    glDisable(SCISSOR);
    uint64_t frames,draws,passes,dr0,pa0; dm_gl_stats(&frames,&dr0,&pa0);
    for (int i=0; i<16; i++) { glColorMask(i&1,i&2,i&4,i&8); glViewport(i*32,0,32,32); glDrawArrays(4,0,3); }
    glColorMask(1,0,1,0); glViewport(17*32,0,32,32); glDrawArrays(4,0,3);
    dm_gl_stats(&frames,&draws,&passes); CHECK(draws==dr0+17 && passes==pa0+1,"⑦ 16 颜色掩码及切回已有 PSO：17 笔只开一遍");
    glClearColor(221.f/255,187.f/255,153.f/255,119.f/255); glEnable(SCISSOR);
    for (int i=0; i<16; i++) { glColorMask(i&1,i&2,i&4,i&8); glScissor(i*32,32,32,32); glClear(COLOR_BIT); }
    // GLboolean 仅低字节有效；验证两个入口都把 0x100 当 false，0x102/0x101 当 true。
    glColorMask(0x100,0x102,0x100,0x101); glScissor(16*32,32,32,32); glClear(COLOR_BIT);
    glDisable(SCISSOR); glViewport(16*32,0,32,32); glDrawArrays(4,0,3);
    FULL_MASK(); glViewport(18*32,0,32,32); glUniform4f(tint,0,1,0,1); glDrawArrays(4,0,3); glFinish();
    for (int i=0; i<16; i++) { clear_pixel(col,i*32+16,16,masked[i],"普通绘制 RGBA 掩码"); clear_pixel(col,i*32+16,48,masked[i],"裁剪清除 RGBA 掩码"); }
    clear_pixel(col,17*32+16,16,masked[5],"切回旧颜色掩码 PSO"); clear_pixel(col,16*32+16,16,masked[10],"ColorMask GLboolean ABI 普通绘制");
    clear_pixel(col,16*32+16,48,masked[10],"ColorMask GLboolean ABI 清除"); clear_pixel(col,18*32+16,16,green,"清除后恢复用户程序 / 顶点 / uniform / 视口 / 颜色写掩码");

    INIT_DEST(); glClearDepthf(0); glClear(DEPTH_BIT); glEnable(DEPTH); glEnable(CULL); glEnable(BLEND);
    glViewport(100,100,0,0); glEnable(SCISSOR); glScissor(0,0,16,16); glClearColor(1,0,0,1); glClear(COLOR_BIT); glFinish();
    clear_pixel(col,8,8,red,"clear 忽略零 viewport / depth test / blend / cull"); clear_pixel(col,24,8,dest,"clear 仍服从 scissor");
    glDisable(DEPTH); glDisable(CULL); glDisable(BLEND);

    // 全关颜色掩码不能挡住深度 / 模板；深度再通过真正 GL LESS 绘制验证，模板读真实 EGL 附件。
    INIT_DEST(); glClearDepthf(.25f); glClearStencil(0x135); glClear(DEPTH_BIT|STENCIL_BIT);   // 整屏快路同样只取低 8 位。
    glColorMask(0,0,0,0); glEnable(SCISSOR); glScissor(0,0,16,16); glClearDepthf(.75f); glClearStencil(0x1A6);
    glClearColor(1,0,0,1); glClear(COLOR_BIT|DEPTH_BIT|STENCIL_BIT); glFinish();
    clear_pixel(col,8,8,dest,"颜色掩码全关仍保留颜色"); clear_pixel(col,24,8,dest,"附件清除外的颜色保留");
    id<MTLTexture> dep=gl_surface_depth();
    clear_depth_stencil(dep,8,8,.75f,0xA6,"全关颜色掩码仍清 depth/stencil，模板取低 8 位");
    clear_depth_stencil(dep,24,8,.25f,0x35,"scissor 外 depth/stencil 保留");
    FULL_MASK(); glDisable(SCISSOR); glEnable(DEPTH); glViewport(0,0,32,32); glUniform4f(tint,0,1,0,1); glDrawArrays(4,0,3); glFinish();
    clear_pixel(col,8,8,green,"深度裁剪清除内 .5 < .75，通过默认 LESS"); clear_pixel(col,24,8,dest,"深度裁剪清除外 .5 > .25，被挡住"); glDisable(DEPTH);

    INIT_DEST(); glClearDepthf(.25f); glClearStencil(-203); glClear(DEPTH_BIT|STENCIL_BIT); glEnable(SCISSOR);   // -203 的低 8 位仍为 0x35。
    glScissor(0,0,16,16); glClearColor(1,0,0,1); glClear(COLOR_BIT);
    glClearColor(0,0,1,1); glScissor(16,0,16,16); glClearDepthf(.75f); glClear(DEPTH_BIT);
    glScissor(0,16,16,16); glClearStencil(0xA6); glClear(STENCIL_BIT);
    glClearColor(0,1,0,1); glClearDepthf(1); glClearStencil(0); glScissor(0,0,128,128); glClear(0); glFinish();
    clear_pixel(col,8,8,red,"跨附件连续 clear 保留先前颜色值和范围"); clear_pixel(col,24,8,dest,"只清深度不改颜色"); clear_pixel(col,8,24,dest,"只清模板不改颜色");
    clear_depth_stencil(dep,8,8,.25f,0x35,"只清颜色不改深度 / 模板");
    clear_depth_stencil(dep,24,8,.75f,0x35,"深度独立快照不被后续模板 / Clear(0) 覆盖");
    clear_depth_stencil(dep,8,24,.25f,0xA6,"模板独立快照不被改值 / Clear(0) 覆盖");

    INIT_DEST(); glEnable(SCISSOR); glScissor(8,8,16,16);
    glScissor(0,0,-1,16); CHECK(glGetError()==0x0501,"⑦ scissor 负宽返回 INVALID_VALUE");
    glScissor(0,0,16,-1); CHECK(glGetError()==0x0501,"⑦ scissor 负高返回 INVALID_VALUE");
    glClearColor(1,0,0,1); glClear(COLOR_BIT); glClearColor(0,1,0,1); glClear(0x80000000u);
    CHECK(glGetError()==0x0501,"⑦ 非法 clear mask 返回 INVALID_VALUE"); glFinish();
    clear_pixel(col,12,12,red,"非法 scissor 保持旧范围，非法 clear 保持先前清除"); clear_pixel(col,4,4,dest,"非法 scissor / clear 不影响范围外");
    glDisable(SCISSOR); FULL_MASK(); glViewport(0,0,(GLsizei)col.width,(GLsizei)col.height);
    CHECK(glGetError()==0,"⑦ 掩码 / 裁剪清除回归完成，GL 错误已取走");
#undef INIT_DEST
#undef FULL_MASK
    return 0;
}

// #272 纹理：GL4.5 §8.4/8.14–8.17；ES3.2 §8。底行红绿、顶行蓝白，线性中心四格平均 (128,128,128,255)±1。
// 只用实际前端与 Metal 像素读回，公共上屏后端仍是上面的替身；不代表完整宿主或游戏。
static void tex_pixel(id<MTLTexture> col, unsigned x, unsigned y, const uint8_t expected[4], const char *label) {
    uint8_t px[4]; readpx(col, x, y, px);
    CHECK(near(px[0],expected[0]) && near(px[1],expected[1]) && near(px[2],expected[2]) && near(px[3],expected[3]),
          "⑦ %s：(%u,%u) %u %u %u %u，期望 %u %u %u %u", label,x,y,px[0],px[1],px[2],px[3],expected[0],expected[1],expected[2],expected[3]);
}
// ⑦b GLSL ES 1.00（杀戮尖塔 / libGDX 形态：没有 #version、attribute / varying、texture2D、gl_FragColor，精度只在 #ifdef GL_ES 里）：
//    texture100.vs / .fs 由 t_gl_min.sh 放进类 RomFS 目录、gl_shaders.py 按扩展名收、升到 ES 3.10 出库；运行时按原文哈希命中。
//    全屏 2×2 NEAREST 纹理（左下红、右下绿、左上蓝、右上白，GL 行序第 0 行在底），四个象限中心各取一点。
static int es100_sampling(gpa_t gpa, id<MTLTexture> col) {
    F(glCreateShader,GLuint,GLenum) F(glShaderSource,void,GLuint,GLsizei,const GLchar *const *,const GLint *) F(glCompileShader,void,GLuint)
    F(glGetShaderiv,void,GLuint,GLenum,GLint *) F(glCreateProgram,GLuint,void) F(glAttachShader,void,GLuint,GLuint) F(glLinkProgram,void,GLuint)
    F(glGetProgramiv,void,GLuint,GLenum,GLint *) F(glUseProgram,void,GLuint) F(glGetUniformLocation,GLint,GLuint,const GLchar *) F(glUniform1i,void,GLint,GLint)
    F(glGenVertexArrays,void,GLsizei,GLuint *) F(glBindVertexArray,void,GLuint) F(glGenBuffers,void,GLsizei,GLuint *) F(glBindBuffer,void,GLenum,GLuint)
    F(glBufferData,void,GLenum,GLsizeiptr,const void *,GLenum) F(glGetAttribLocation,GLint,GLuint,const GLchar *)
    F(glVertexAttribPointer,void,GLuint,GLint,GLenum,GLuint,GLsizei,const void *) F(glEnableVertexAttribArray,void,GLuint)
    F(glActiveTexture,void,GLenum) F(glGenTextures,void,GLsizei,GLuint *) F(glBindTexture,void,GLenum,GLuint) F(glTexParameteri,void,GLenum,GLenum,GLint)
    F(glTexImage2D,void,GLenum,GLint,GLint,GLsizei,GLsizei,GLint,GLenum,GLenum,const void *) F(glBindSampler,void,GLuint,GLuint)
    F(glClear,void,GLbitfield) F(glDrawArrays,void,GLenum,GLint,GLsizei) F(glFinish,void,void)
    GLuint prog = glCreateProgram(); GLint ok;
    for (int i = 0; i < 2; i++) {
        char path[1024]; snprintf(path, sizeof path, "%s/texture100.%s", getenv("T_GL_DIR"), i ? "fs" : "vs");
        FILE *f = fopen(path, "rb"); if (!f) return 1; fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
        char *src = calloc(1, (size_t)n + 1); if (!src) { fclose(f); return 1; }
        if (fread(src, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(src); return 1; } fclose(f);
        GLuint shader = glCreateShader(i ? 0x8B30 : 0x8B31); const char *text = src; glShaderSource(shader, 1, &text, NULL); free(src);
        glCompileShader(shader); glGetShaderiv(shader, 0x8B81, &ok); CHECK(ok == 1, "⑦b ES 1.00 texture100.%s 离线编译（按原文哈希命中）", i ? "fs" : "vs"); glAttachShader(prog, shader);
    }
    glLinkProgram(prog); glGetProgramiv(prog, 0x8B82, &ok); CHECK(ok == 1, "⑦b ES 1.00 程序链接（varying 按名配对）"); if (!ok) return 1; glUseProgram(prog);
    GLint loc = glGetUniformLocation(prog, "uTex"), pos = glGetAttribLocation(prog, "aPos");
    CHECK(loc >= 0 && pos >= 0, "⑦b ES 1.00 attribute / sampler 各有位置");
    GLuint vao, vbo, tex; glGenVertexArrays(1, &vao); glBindVertexArray(vao); glGenBuffers(1, &vbo); glBindBuffer(0x8892, vbo);
    const float quad[] = {-1,-1, 1,-1, -1,1, -1,1, 1,-1, 1,1}; glBufferData(0x8892, sizeof quad, quad, 0x88E4);
    glVertexAttribPointer(pos, 2, 0x1406, 0, 8, NULL); glEnableVertexAttribArray(pos); glUniform1i(loc, 0);
    glActiveTexture(0x84C0); glBindSampler(0, 0); glGenTextures(1, &tex); glBindTexture(0x0DE1, tex);
    glTexParameteri(0x0DE1, 0x2801, 0x2600); glTexParameteri(0x0DE1, 0x2800, 0x2600);
    const uint8_t colors[][4] = {{255,0,0,255}, {0,255,0,255}, {0,0,255,255}, {255,255,255,255}};
    glTexImage2D(0x0DE1, 0, 0x8058, 2, 2, 0, 0x1908, 0x1401, colors);
    glClear(0x4000); glDrawArrays(4, 0, 6); glFinish();
    tex_pixel(col, 320, 180, colors[0], "⑦b ES 1.00 左下红"); tex_pixel(col, 960, 180, colors[1], "⑦b ES 1.00 右下绿");
    tex_pixel(col, 320, 540, colors[2], "⑦b ES 1.00 左上蓝"); tex_pixel(col, 960, 540, colors[3], "⑦b ES 1.00 右上白（gl_FragColor 写到颜色 0）");
    return 0;
}

static int texture_sampling(gpa_t gpa, id<MTLTexture> col, EGLDisplay display, EGLSurface surface, EGLContext original) {
    F(glDisable,void,GLenum) F(glViewport,void,GLint,GLint,GLsizei,GLsizei)
    F(glGenTextures,void,GLsizei,GLuint *) F(glDeleteTextures,void,GLsizei,const GLuint *) F(glActiveTexture,void,GLenum)
    F(glBindTexture,void,GLenum,GLuint) F(glTexImage2D,void,GLenum,GLint,GLint,GLsizei,GLsizei,GLint,GLenum,GLenum,const void *)
    F(glTexSubImage2D,void,GLenum,GLint,GLint,GLint,GLsizei,GLsizei,GLenum,GLenum,const void *) F(glTexStorage2D,void,GLenum,GLsizei,GLenum,GLsizei,GLsizei)
    F(glTexParameteri,void,GLenum,GLenum,GLint) F(glTexParameterf,void,GLenum,GLenum,GLfloat) F(glPixelStorei,void,GLenum,GLint)
    F(glGenerateMipmap,void,GLenum) F(glGenSamplers,void,GLsizei,GLuint *) F(glDeleteSamplers,void,GLsizei,const GLuint *)
    F(glBindSampler,void,GLuint,GLuint) F(glSamplerParameteri,void,GLuint,GLenum,GLint)
    F(glCreateShader,GLuint,GLenum) F(glShaderSource,void,GLuint,GLsizei,const GLchar *const *,const GLint *) F(glCompileShader,void,GLuint)
    F(glGetShaderiv,void,GLuint,GLenum,GLint *) F(glCreateProgram,GLuint,void) F(glAttachShader,void,GLuint,GLuint) F(glLinkProgram,void,GLuint)
    F(glGetProgramiv,void,GLuint,GLenum,GLint *) F(glUseProgram,void,GLuint) F(glGetUniformLocation,GLint,GLuint,const GLchar *)
    F(glUniform1i,void,GLint,GLint) F(glUniform1iv,void,GLint,GLsizei,const GLint *) F(glUniform2f,void,GLint,GLfloat,GLfloat)
    F(glGenVertexArrays,void,GLsizei,GLuint *) F(glBindVertexArray,void,GLuint) F(glGenBuffers,void,GLsizei,GLuint *) F(glBindBuffer,void,GLenum,GLuint)
    F(glBufferData,void,GLenum,GLsizeiptr,const void *,GLenum) F(glGetAttribLocation,GLint,GLuint,const GLchar *)
    F(glVertexAttribPointer,void,GLuint,GLint,GLenum,GLuint,GLsizei,const void *) F(glEnableVertexAttribArray,void,GLuint)
    F(glClear,void,GLbitfield) F(glDrawArrays,void,GLenum,GLint,GLsizei) F(glFinish,void,void) F(glGetError,GLenum,void)
    glDisable(0x0BE2); glDisable(0x0B71); glDisable(0x0B44); glDisable(0x0C11); glViewport(0,0,1280,720); // 本组独立于前面的混合 / 小视口回归。
    GLuint prog = glCreateProgram(); GLint ok;
    for (int i = 0; i < 2; i++) {
        char path[1024]; snprintf(path,sizeof path,"%s/texture.%s",getenv("T_GL_DIR"),i ? "frag" : "vert");
        FILE *f = fopen(path,"rb"); if (!f) return 1; fseek(f,0,SEEK_END); long n = ftell(f); rewind(f);
        char *src = calloc(1,(size_t)n+1); if (!src) { fclose(f); return 1; }
        if (fread(src,1,(size_t)n,f)!=(size_t)n) { fclose(f); free(src); return 1; } fclose(f);
        GLuint shader=glCreateShader(i?0x8B30:0x8B31); const char *text=src; glShaderSource(shader,1,&text,NULL); free(src);
        glCompileShader(shader); glGetShaderiv(shader,0x8B81,&ok); CHECK(ok==1,"⑦ texture %s 离线编译",i?"frag":"vert"); glAttachShader(prog,shader);
    }
    glLinkProgram(prog); glGetProgramiv(prog,0x8B82,&ok); CHECK(ok==1,"⑦ 采样反射程序链接"); if (!ok) return 1; glUseProgram(prog);
    GLint off=glGetUniformLocation(prog,"uOff"), scale=glGetUniformLocation(prog,"uScale"), uvscale=glGetUniformLocation(prog,"uUVScale"), uvoff=glGetUniformLocation(prog,"uUVOff"), loc=glGetUniformLocation(prog,"uTex");
    CHECK(loc>=0 && off>=0 && scale>=0 && uvscale>=0 && uvoff>=0,"⑦ 普通 / sampler uniform 各有位置");
    GLuint vao,vbo,tex,sampler; glGenVertexArrays(1,&vao); glBindVertexArray(vao); glGenBuffers(1,&vbo); glBindBuffer(0x8892,vbo);
    const float quad[]={-1,-1, 1,-1, -1,1, -1,1, 1,-1, 1,1}; glBufferData(0x8892,sizeof quad,quad,0x88E4);
    GLint pos=glGetAttribLocation(prog,"aPos"); glVertexAttribPointer(pos,2,0x1406,0,8,NULL); glEnableVertexAttribArray(pos);
    glUniform2f(off,0,0); glUniform2f(scale,1,1); glUniform2f(uvscale,1,1); glUniform2f(uvoff,0,0); glUniform1i(loc,0);
    glActiveTexture(0x84C0); glGenTextures(1,&tex); glBindTexture(0x0DE1,tex);
    glTexParameteri(0x0DE1,0x2801,0x2600); glTexParameteri(0x0DE1,0x2800,0x2600);
    glTexParameterf(0x0DE1,0x2802,0x812F); glTexParameteri(0x0DE1,0x2803,0x812F);
    const uint8_t colors[][4]={{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,255,255}};
    glTexImage2D(0x0DE1,0,0x8058,2,2,0,0x1908,0x1401,colors);
    glClear(0x4000); glDrawArrays(4,0,6); glFinish();
    tex_pixel(col,320,180,colors[0],"NEAREST 左下"); tex_pixel(col,960,180,colors[1],"NEAREST 右下");
    tex_pixel(col,320,540,colors[2],"NEAREST 左上"); tex_pixel(col,960,540,colors[3],"NEAREST 右上");
    // 固定 UV=.5，消除窗口偶数尺寸的像素中心偏移；线性中心正好四格等权。
    const uint8_t gray[]={128,128,128,255}, red[]={255,0,0,255}, green[]={0,255,0,255}, black[]={0,0,0,255}, blue[]={0,0,255,255};
    glUniform2f(uvscale,0,0); glUniform2f(uvoff,.5f,.5f);
    glTexParameteri(0x0DE1,0x2801,0x2601); glTexParameteri(0x0DE1,0x2800,0x2601);
    glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,640,360,gray,"LINEAR 四格平均");
    glGenSamplers(1,&sampler); glSamplerParameteri(sampler,0x2801,0x2600); glSamplerParameteri(sampler,0x2800,0x2600); glBindSampler(0,sampler);
    glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,640,360,colors[3],"采样器 NEAREST 覆盖纹理 LINEAR");
    glBindSampler(0,0); glDeleteSamplers(1,&sampler);
    // 未提交引用：第一笔旧红、第二笔新绿，左右分离，只有一个 render pass。
    glTexImage2D(0x0DE1,0,0x8058,1,1,0,0x1908,0x1401,red); glUniform2f(scale,.45f,.8f); glUniform2f(off,-.5f,0);
    uint64_t fr,dr,pa,dr0,pa0; dm_gl_stats(&fr,&dr0,&pa0);
    glClear(0x4000); glDrawArrays(4,0,6); glTexSubImage2D(0x0DE1,0,0,0,1,1,0x1908,0x1401,green);
    glUniform2f(off,.5f,0); glDrawArrays(4,0,6); glFinish();
    tex_pixel(col,320,360,red,"在途 SubImage 保留第一笔旧红"); tex_pixel(col,960,360,green,"SubImage 后第二笔新绿");
    dm_gl_stats(&fr,&dr,&pa); CHECK(dr==dr0+2 && pa==pa0+1,"⑦ 上传顺序：两笔 / 一遍（draw+%llu pass+%llu）",(unsigned long long)(dr-dr0),(unsigned long long)(pa-pa0));
    // 局部上传还必须复制未修改的整级内容，而不只是新区域。
    glTexImage2D(0x0DE1,0,0x8058,2,2,0,0x1908,0x1401,colors); glUniform2f(uvscale,1,1); glUniform2f(uvoff,0,0);
    glUniform2f(off,-.5f,0); glClear(0x4000); glDrawArrays(4,0,6);
    glTexSubImage2D(0x0DE1,0,0,0,1,1,0x1908,0x1401,green); glUniform2f(off,.5f,0); glDrawArrays(4,0,6); glFinish();
    tex_pixel(col,176,216,red,"局部上传前保留旧左下"); tex_pixel(col,816,216,green,"局部上传后新左下"); tex_pixel(col,816,504,blue,"局部上传保留未修改的顶行");
    glTexImage2D(0x0DE1,0,0x8058,1,1,0,0x1908,0x1401,green); glUniform2f(uvscale,0,0); glUniform2f(uvoff,.5f,.5f);
    // 整级重定义也必须保留已编码存储。
    glUniform2f(off,-.5f,0); glClear(0x4000); glDrawArrays(4,0,6);
    glTexImage2D(0x0DE1,0,0x8058,1,1,0,0x1908,0x1401,blue); glUniform2f(off,.5f,0); glDrawArrays(4,0,6); glFinish();
    tex_pixel(col,320,360,green,"TexImage 前旧绿"); tex_pixel(col,960,360,blue,"TexImage 后新蓝");
    glUniform2f(off,0,0); glUniform2f(scale,1,1); glBindTexture(0x0DE1,0);
    glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,640,360,black,"未绑定黑色 alpha1");
    glBindTexture(0x0DE1,tex); glTexImage2D(0x0DE1,0,0x8058,2,2,0,0x1908,0x1401,colors);
    glTexParameteri(0x0DE1,0x2801,0x2703); glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,640,360,black,"缺 mip 链不完整为黑");
    glTexParameteri(0x0DE1,0x813D,0); glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,640,360,gray,"max level 截成完整单级");
    glTexParameteri(0x0DE1,0x813D,1000); glGenerateMipmap(0x0DE1);
    uint8_t mip[4]; id<MTLTexture> level1=gl_tex_mtl(tex,1); CHECK(level1 && level1.width==1 && level1.height==1,"⑦ GenerateMipmap 生成 1x1");
    if (level1) { [level1 getBytes:mip bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0]; CHECK(near(mip[0],128)&&near(mip[1],128)&&near(mip[2],128)&&mip[3]==255,"⑦ 生成 mip 四格平均：%u %u %u %u",mip[0],mip[1],mip[2],mip[3]); }
    glTexParameteri(0x0DE1,0x2801,0x2700); glTexParameteri(0x0DE1,0x2800,0x2600); glUniform2f(uvscale,1280,1280); glUniform2f(uvoff,0,0);
    glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,640,360,gray,"缩小采样实际命中生成 mip1");
    glUniform2f(uvscale,0,0); glUniform2f(uvoff,1.25f,.25f);
    glTexParameteri(0x0DE1,0x2801,0x2600); glTexParameteri(0x0DE1,0x2802,0x2901);
    glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,640,360,red,"REPEAT 1.25→.25");
    glTexParameteri(0x0DE1,0x2802,0x812F); glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,640,360,green,"CLAMP_TO_EDGE 1.25→右边");
    glTexParameteri(0x0DE1,0x2802,0x8370); glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,640,360,green,"MIRRORED_REPEAT 1.25→.75");
    glTexParameteri(0x0DE1,0x2801,0x2600); glTexParameteri(0x0DE1,0x2800,0x2600);
    glUniform2f(uvscale,1,1); glUniform2f(uvoff,0,0);
    // 默认对齐4：RGB 每行3字节，第二行从偏移4读；不能把填充的0当绿色通道。
    const uint8_t rgb[]={255,0,0,0, 0,255,0}; glTexImage2D(0x0DE1,0,0x8051,1,2,0,0x1907,0x1401,rgb);
    glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,640,180,red,"RGB8 默认行对齐4 / alpha1 底行"); tex_pixel(col,640,540,green,"RGB8 默认行对齐4 顶行");
    const uint8_t rows[][4]={{255,0,0,255},{0,255,0,255},{19,23,29,0},{0,0,255,255},{255,255,255,255}};
    glPixelStorei(0x0CF2,3); glTexImage2D(0x0DE1,0,0x8058,2,2,0,0x1908,0x1401,rows); glPixelStorei(0x0CF2,0);
    glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,320,540,blue,"UNPACK_ROW_LENGTH=3 跳过填充像素");
    glPixelStorei(0x0CF5,1); uint8_t r=128,rg[]={64,192};
    glTexImage2D(0x0DE1,0,0x8229,1,1,0,0x1903,0x1401,&r); glClear(0x4000); glDrawArrays(4,0,6); glFinish(); const uint8_t r_expected[]={128,0,0,255}; tex_pixel(col,640,360,r_expected,"R8 默认缺失通道");
    glTexImage2D(0x0DE1,0,0x822B,1,1,0,0x8227,0x1401,rg); glClear(0x4000); glDrawArrays(4,0,6); glFinish(); const uint8_t rg_expected[]={64,192,0,255}; tex_pixel(col,640,360,rg_expected,"RG8 默认缺失通道");
    const uint16_t half[]={0x3800,0,0x3C00,0x3C00}; const uint8_t half_expected[]={128,0,255,255};
    glTexImage2D(0x0DE1,0,0x881A,1,1,0,0x1908,0x140B,half); glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,640,360,half_expected,"RGBA16F 半精度 .5/0/1/1");
    // sampler uniform 与 active unit 都必须接线，Uniform1iv 不可写进普通 UBO。
    GLuint other; glGenTextures(1,&other); glActiveTexture(0x84C1); glBindTexture(0x0DE1,other); glTexParameteri(0x0DE1,0x2801,0x2600); glTexParameteri(0x0DE1,0x2800,0x2600);
    glTexStorage2D(0x0DE1,1,0x8058,1,1); glTexSubImage2D(0x0DE1,0,0,0,1,1,0x1908,0x1401,blue);
    GLint one=1; glUniform1iv(loc,1,&one); glActiveTexture(0x84C0); glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,640,360,blue,"Uniform1iv / 纹理单元1 / immutable storage");
    glTexImage2D(0x0DE1,0,0x8058,1,1,0,0x1908,0x1401,green); CHECK(glGetError()==0,"⑦ 未发生有效调用错误"); // 当前活动单元0，允许 mutable 重定义。
    glActiveTexture(0x84C1); glTexImage2D(0x0DE1,0,0x8058,1,1,0,0x1908,0x1401,red); CHECK(glGetError()==0x0502,"⑦ immutable 禁止重定义");
    glTexSubImage2D(0x0DE1,0,1,0,1,1,0x1908,0x1401,red); CHECK(glGetError()==0x0501,"⑦ 越界 SubImage 拒绝");
    glPixelStorei(0x0CF5,3); CHECK(glGetError()==0x0501,"⑦ 非法对齐3拒绝");
    glActiveTexture(0x84C0+32); CHECK(glGetError()==0x0500,"⑦ 越界 active unit 拒绝");
    glTexImage2D(0x0DE1,0,0xDEAD,1,1,0,0x1908,0x1401,red); CHECK(glGetError()==0x0502,"⑦ immutable 错误优先，不改原图");
    glActiveTexture(0x84C0); uint64_t bf0,be0,bf,be; dm_gl_bad_draws(&bf0,&be0);
    glTexImage2D(0x0DE1,0,0xDEAD,1,1,0,0x1908,0x1401,red); dm_gl_bad_draws(&bf,&be); CHECK(glGetError()==0x0500 && bf==bf0+1,"⑦ 未支持格式明确红 / INVALID_ENUM / 缺特性+1");
    glUniform1i(loc,-1); CHECK(glGetError()==0x0501,"⑦ sampler uniform 负单元拒绝");
    glUniform1i(loc,32); CHECK(glGetError()==0x0501,"⑦ sampler uniform 越界值在设置处拒绝");
    glDeleteTextures(1,&other); glUniform1i(loc,1); glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,640,360,black,"删除解绑，旧名字不留下采样状态");
    // RGB 内部格式不保存 RGBA 输入的 alpha。
    glBindTexture(0x0DE1,tex); const uint8_t transparent_red[]={255,0,0,0}; glUniform1i(loc,0);
    glTexImage2D(0x0DE1,0,0x8051,1,1,0,0x1908,0x1401,transparent_red); glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,640,360,red,"RGB 内部格式丢弃输入 alpha");
    // PixelStore 属于上下文：新建上下文初始4/0；切回旧上下文仍保留1/3。
    F(eglCreateContext,EGLContext,EGLDisplay,EGLConfig,EGLContext,const EGLint *) F(eglChooseConfig,EGLBoolean,EGLDisplay,const EGLint *,EGLConfig *,EGLint,EGLint *)
    F(eglMakeCurrent,EGLBoolean,EGLDisplay,EGLSurface,EGLSurface,EGLContext) F(eglDestroyContext,EGLBoolean,EGLDisplay,EGLContext)
    EGLConfig config; EGLint count; const EGLint cfg[]={0x3040,0x0040,0x3038}, attrs[]={0x3098,3,0x30FB,2,0x3038};
    eglChooseConfig(display,cfg,&config,1,&count); glPixelStorei(0x0CF5,1); glPixelStorei(0x0CF2,3);
    EGLContext fresh=eglCreateContext(display,config,NULL,attrs); CHECK(fresh && eglMakeCurrent(display,surface,surface,fresh),"⑦ 新上下文建立");
    GLuint freshtex; glGenTextures(1,&freshtex); glBindTexture(0x0DE1,freshtex); glTexImage2D(0x0DE1,0,0x8051,1,2,0,0x1907,0x1401,rgb);
    uint8_t freshbytes[8]; id<MTLTexture> freshimage=gl_tex_mtl(freshtex,0);
    if (freshimage) [freshimage getBytes:freshbytes bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,2) mipmapLevel:0];
    CHECK(freshimage && !memcmp(freshbytes,red,4) && !memcmp(freshbytes+4,green,4),"⑦ 新上下文 UNPACK 默认4/0，不继承旧值");
    glDeleteTextures(1,&freshtex); CHECK(eglMakeCurrent(display,surface,surface,original),"⑦ 切回原上下文"); eglDestroyContext(display,fresh);
    glTexImage2D(0x0DE1,0,0x8058,2,2,0,0x1908,0x1401,rows); id<MTLTexture> oldimage=gl_tex_mtl(tex,0); uint8_t oldbytes[4];
    if (oldimage) [oldimage getBytes:oldbytes bytesPerRow:4 fromRegion:MTLRegionMake2D(0,1,1,1) mipmapLevel:0];
    CHECK(oldimage && !memcmp(oldbytes,blue,4),"⑦ 切回上下文保留原 UNPACK_ROW_LENGTH=3"); glPixelStorei(0x0CF2,0);
    glDeleteTextures(1,&tex); glPixelStorei(0x0CF5,4); glUniform1i(-1,99); CHECK(glGetError()==0,"⑦ 位置-1忽略，删除和有效状态无错误");
    // MAX_LEVEL=INT32_MAX 合法（wwmogu #386）：跨度按 64 位算——1×1 单级仍完整采到红；2×2 GenerateMipmap 只生成到 1×1、不报错
    GLuint big; glGenTextures(1,&big); glActiveTexture(0x84C0); glBindTexture(0x0DE1,big); glUniform1i(loc,0);
    glUniform2f(off,0,0); glUniform2f(scale,1,1); glUniform2f(uvscale,0,0); glUniform2f(uvoff,.5f,.5f);
    glTexParameteri(0x0DE1,0x2801,0x2600); glTexParameteri(0x0DE1,0x2800,0x2600); glTexParameteri(0x0DE1,0x813D,0x7FFFFFFF);
    glTexImage2D(0x0DE1,0,0x8058,1,1,0,0x1908,0x1401,red); glClear(0x4000); glDrawArrays(4,0,6); glFinish(); tex_pixel(col,640,360,red,"MAX_LEVEL=INT32_MAX 单级仍完整");
    glTexImage2D(0x0DE1,0,0x8058,2,2,0,0x1908,0x1401,colors); glGenerateMipmap(0x0DE1); CHECK(glGetError()==0,"⑦ MAX_LEVEL=INT32_MAX GenerateMipmap 无错");
    id<MTLTexture> big1=gl_tex_mtl(big,1); CHECK(big1 && big1.width==1 && big1.height==1,"⑦ MAX_LEVEL=INT32_MAX 生成到 1×1");
    // 自选大名字（wwmogu #360 复审）：UINT32_MAX 不回绕成 0、2^31 不让扩容倍增回绕，都不开整张表，报 OUT_OF_MEMORY
    glBindTexture(0x0DE1,0xFFFFFFFFu); CHECK(glGetError()==0x0505,"⑦ 绑定纹理名 UINT32_MAX 报 OUT_OF_MEMORY");
    glBindBuffer(0x8892,0x80000000u); CHECK(glGetError()==0x0505,"⑦ 绑定缓冲名 2^31 报 OUT_OF_MEMORY");
    glBindBuffer(0x8892,vbo); glBindTexture(0x0DE1,0); glDeleteTextures(1,&big);
    return 0;
}

#define SF(name, ret, ...) ret (*name)(__VA_ARGS__) = (ret (*)(__VA_ARGS__))gpa(#name); if (!name) { printf("  败 %s：取不到 %s\n", label, #name); return 0; }
static GLuint shadow_program(gpa_t gpa, const char *fragment, const char *label) {
    SF(glCreateShader, GLuint, GLenum) SF(glShaderSource, void, GLuint, GLsizei, const GLchar *const *, const GLint *)
    SF(glCompileShader, void, GLuint) SF(glGetShaderiv, void, GLuint, GLenum, GLint *)
    SF(glCreateProgram, GLuint, void) SF(glAttachShader, void, GLuint, GLuint) SF(glLinkProgram, void, GLuint)
    SF(glGetProgramiv, void, GLuint, GLenum, GLint *)
    GLuint program = glCreateProgram(); GLint ok = 0;
    const char *files[] = {"shadow.vert", fragment};
    for (int i = 0; i < 2; i++) {
        char path[1024]; snprintf(path, sizeof path, "%s/%s", getenv("T_GL_DIR"), files[i]);
        FILE *f = fopen(path, "rb"); if (!f) { printf("  败 %s：读不到 %s\n", label, path); return 0; }
        fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f); char *source = calloc(1, (size_t)n + 1);
        if (!source || fread(source, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(source); printf("  败 %s：读取 %s\n", label, path); return 0; }
        fclose(f); GLuint shader = glCreateShader(i ? 0x8B30 : 0x8B31); const GLchar *text = source;
        glShaderSource(shader, 1, &text, NULL); free(source); glCompileShader(shader); glGetShaderiv(shader, 0x8B81, &ok);
        CHECK(ok == 1, "⑨ %s %s 反射库着色器加载", label, i ? "fragment" : "vertex"); if (!ok) return 0;
        glAttachShader(program, shader);
    }
    glLinkProgram(program); glGetProgramiv(program, 0x8B82, &ok); CHECK(ok == 1, "⑨ %s 程序链接", label);
    return ok ? program : 0;
}
#undef SF

// #272 shadow sampling：深度值只由真实 GL FBO clear 写入私有 Metal 深度纹理；采样后读取窗口 Metal 颜色像素。
// 2D 比较矩阵使用 texel=.5、reference={.25,.5,.75}，逐一核对 GL reference FUNC texel 的完整真值表；
// cube 六面深度递增，以五个 reference 形成唯一的六位通过图样，确认每个主轴方向都取到对应面。
static int shadow_sampling(gpa_t gpa, id<MTLTexture> col) {
    F(glDisable, void, GLenum) F(glEnable, void, GLenum) F(glViewport, void, GLint, GLint, GLsizei, GLsizei)
    F(glGenTextures, void, GLsizei, GLuint *) F(glActiveTexture, void, GLenum) F(glBindTexture, void, GLenum, GLuint)
    F(glTexStorage2D, void, GLenum, GLsizei, GLenum, GLsizei, GLsizei) F(glTexParameteri, void, GLenum, GLenum, GLint)
    F(glGenFramebuffers, void, GLsizei, GLuint *) F(glBindFramebuffer, void, GLenum, GLuint)
    F(glFramebufferTexture2D, void, GLenum, GLenum, GLenum, GLuint, GLint) F(glCheckFramebufferStatus, GLenum, GLenum)
    F(glClearDepthf, void, GLfloat) F(glDepthMask, void, GLuint) F(glClear, void, GLbitfield)
    F(glGenSamplers, void, GLsizei, GLuint *) F(glBindSampler, void, GLuint, GLuint) F(glSamplerParameteri, void, GLuint, GLenum, GLint) F(glDeleteSamplers, void, GLsizei, const GLuint *)
    F(glCreateProgram, GLuint, void) F(glUseProgram, void, GLuint) F(glGetUniformLocation, GLint, GLuint, const GLchar *)
    F(glUniform1i, void, GLint, GLint) F(glUniform1f, void, GLint, GLfloat) F(glUniform3f, void, GLint, GLfloat, GLfloat, GLfloat)
    F(glGenVertexArrays, void, GLsizei, GLuint *) F(glBindVertexArray, void, GLuint) F(glGenBuffers, void, GLsizei, GLuint *) F(glBindBuffer, void, GLenum, GLuint)
    F(glBufferData, void, GLenum, GLsizeiptr, const void *, GLenum) F(glGetAttribLocation, GLint, GLuint, const GLchar *)
    F(glVertexAttribPointer, void, GLuint, GLint, GLenum, GLuint, GLsizei, const void *) F(glEnableVertexAttribArray, void, GLuint)
    F(glDrawArrays, void, GLenum, GLint, GLsizei) F(glFinish, void, void) F(glGetError, GLenum, void)
    enum { TEX2D = 0x0DE1, CUBE = 0x8513, CUBE_POS_X = 0x8515, RGBA8 = 0x8058, DEPTH32F = 0x8CAC,
           FB = 0x8D40, COLOR_ATTACHMENT0 = 0x8CE0, DEPTH_ATTACHMENT = 0x8D00, FRAMEBUFFER_COMPLETE = 0x8CD5,
           COLOR_BIT = 0x4000, DEPTH_BIT = 0x0100, MIN_FILTER = 0x2801, MAG_FILTER = 0x2800, NEAREST = 0x2600,
           COMPARE_MODE = 0x884C, COMPARE_FUNC = 0x884D, NONE = 0, COMPARE_REF = 0x884E,
           NEVER = 0x0200, LESS = 0x0201, EQUAL = 0x0202, LEQUAL = 0x0203, GREATER = 0x0204, NOTEQUAL = 0x0205, GEQUAL = 0x0206, ALWAYS = 0x0207,
           INVALID_ENUM = 0x0500 };
    const GLenum funcs[8] = {NEVER, LESS, EQUAL, LEQUAL, GREATER, NOTEQUAL, GEQUAL, ALWAYS};
    const char *const fnames[8] = {"NEVER", "LESS", "EQUAL", "LEQUAL", "GREATER", "NOTEQUAL", "GEQUAL", "ALWAYS"};
    const float refs[3] = {.25f, .5f, .75f}; const uint8_t yes[] = {255,255,255,255}, no[] = {0,0,0,255};
    const uint8_t truth[8][3] = {{0,0,0},{1,0,0},{0,1,0},{1,1,0},{0,0,1},{1,0,1},{0,1,1},{1,1,1}};

    glDisable(0x0BE2); glDisable(0x0B71); glDisable(0x0B44); glDisable(0x0C11); glBindSampler(0, 0); glActiveTexture(0x84C0);
    GLuint raw = shadow_program(gpa, "shadow_raw.frag", "depth raw sampler2D");
    GLuint sh2 = shadow_program(gpa, "shadow.frag", "sampler2DShadow");
    GLuint shcube = shadow_program(gpa, "shadow_cube.frag", "samplerCubeShadow");
    if (!raw || !sh2 || !shcube) return 1;
    GLuint vao, vbo; glGenVertexArrays(1, &vao); glBindVertexArray(vao); glGenBuffers(1, &vbo); glBindBuffer(0x8892, vbo);
    const float quad[] = {-1,-1, 1,-1, -1,1, -1,1, 1,-1, 1,1}; glBufferData(0x8892, sizeof quad, quad, 0x88E4);
    GLint pos = glGetAttribLocation(sh2, "aPos"); glVertexAttribPointer((GLuint)pos, 2, 0x1406, 0, 8, NULL); glEnableVertexAttribArray((GLuint)pos);

    GLuint color, depth2d, fb; glGenTextures(1, &color); glActiveTexture(0x84C1); glBindTexture(TEX2D, color);
    glTexStorage2D(TEX2D, 1, RGBA8, 8, 8);
    glActiveTexture(0x84C0); glGenTextures(1, &depth2d); glBindTexture(TEX2D, depth2d);
    glTexParameteri(TEX2D, MIN_FILTER, NEAREST); glTexParameteri(TEX2D, MAG_FILTER, NEAREST);
    glTexStorage2D(TEX2D, 1, DEPTH32F, 8, 8);
    glGenFramebuffers(1, &fb); glBindFramebuffer(FB, fb); glFramebufferTexture2D(FB, COLOR_ATTACHMENT0, TEX2D, color, 0);
    glFramebufferTexture2D(FB, DEPTH_ATTACHMENT, TEX2D, depth2d, 0);
    CHECK(glCheckFramebufferStatus(FB) == FRAMEBUFFER_COMPLETE, "⑨ 8×8 RGBA8 + DEPTH_COMPONENT32F FBO 完整");
    glDepthMask(1); glClearDepthf(.5f); glClear(DEPTH_BIT); glBindFramebuffer(FB, 0);
    CHECK(glGetError() == 0, "⑨ 私有 2D 深度纹理经 FBO 清到 .5");

    glUseProgram(raw); GLint raw_tex = glGetUniformLocation(raw, "uTex"); glUniform1i(raw_tex, 0); glViewport(0, 0, 16, 16); glDrawArrays(4, 0, 6); glFinish();
    const uint8_t raw_half[] = {128,0,0,255}; tex_pixel(col, 8, 8, raw_half, "⑨ 默认 COMPARE_MODE=NONE：普通 sampler 读原始深度 .5");

    glUseProgram(sh2); GLint tex = glGetUniformLocation(sh2, "uShadow"), ref = glGetUniformLocation(sh2, "uRef");
    CHECK(tex >= 0 && ref >= 0, "⑨ sampler2DShadow 反射位置"); glUniform1i(tex, 0);
    glTexParameteri(TEX2D, COMPARE_MODE, COMPARE_REF);   // 新对象缺省 compare func 必须是 LEQUAL。
    glTexParameteri(TEX2D, COMPARE_MODE, 0xDEAD); CHECK(glGetError() == INVALID_ENUM, "⑨ 非法 texture compare mode 返回 INVALID_ENUM");
    for (int i = 0; i < 3; i++) { glViewport(i*16, 32, 16, 16); glUniform1f(ref, refs[i]); glDrawArrays(4, 0, 6); }
    glFinish(); tex_pixel(col, 8, 40, yes, "⑨ 默认 compare func LEQUAL：.25 ≤ .5"); tex_pixel(col, 24, 40, yes, "⑨ 默认 compare func LEQUAL：.5 ≤ .5"); tex_pixel(col, 40, 40, no, "⑨ 默认 compare func LEQUAL：.75 不≤ .5");
    glTexParameteri(TEX2D, COMPARE_FUNC, LESS); glTexParameteri(TEX2D, COMPARE_FUNC, 0xDEAD);
    CHECK(glGetError() == INVALID_ENUM, "⑨ 非法 texture compare func 返回 INVALID_ENUM");
    glViewport(0, 64, 16, 16); glUniform1f(ref, .25f); glDrawArrays(4, 0, 6);
    glViewport(16, 64, 16, 16); glUniform1f(ref, .75f); glDrawArrays(4, 0, 6); glFinish();
    tex_pixel(col, 8, 72, yes, "⑨ 非法 func 后保留 LESS：.25 < .5"); tex_pixel(col, 24, 72, no, "⑨ 非法 func 后保留 LESS：.75 不< .5");
    for (int f = 0; f < 8; f++) {
        glTexParameteri(TEX2D, COMPARE_FUNC, (GLint)funcs[f]);
        for (int r = 0; r < 3; r++) { glViewport(f*16, 96+r*16, 16, 16); glUniform1f(ref, refs[r]); glDrawArrays(4, 0, 6); }
    }
    glFinish();
    for (int f = 0; f < 8; f++) for (int r = 0; r < 3; r++) {
        char label[96]; snprintf(label, sizeof label, "⑨ texture compare %s ref=%.2f texel=.50", fnames[f], refs[r]);
        tex_pixel(col, f*16+8, 96+r*16+8, truth[f][r] ? yes : no, label);
    }

    glTexParameteri(TEX2D, COMPARE_MODE, NONE); glUseProgram(raw); glViewport(0, 192, 16, 16); glDrawArrays(4, 0, 6); glFinish();
    tex_pixel(col, 8, 200, raw_half, "⑨ COMPARE_REF_TO_TEXTURE → NONE：切回普通采样得到原始 .5");

    GLuint sampler; glGenSamplers(1, &sampler); glSamplerParameteri(sampler, COMPARE_MODE, COMPARE_REF); glSamplerParameteri(sampler, COMPARE_FUNC, ALWAYS);
    glTexParameteri(TEX2D, COMPARE_FUNC, NEVER); glBindSampler(0, sampler); glUseProgram(sh2); glUniform1i(tex, 0);
    glSamplerParameteri(sampler, COMPARE_MODE, 0xDEAD); CHECK(glGetError() == INVALID_ENUM, "⑨ 非法 sampler compare mode 返回 INVALID_ENUM");
    glSamplerParameteri(sampler, COMPARE_FUNC, 0xDEAD); CHECK(glGetError() == INVALID_ENUM, "⑨ 非法 sampler compare func 返回 INVALID_ENUM");
    for (int i = 0; i < 3; i++) { glViewport(i*16, 160, 16, 16); glUniform1f(ref, refs[i]); glDrawArrays(4, 0, 6); }
    glFinish(); for (int i = 0; i < 3; i++) tex_pixel(col, i*16+8, 168, yes, "⑨ sampler object COMPARE/ALWAYS 覆盖 texture NONE/NEVER，非法值不改状态");
    glBindSampler(0, 0); glDeleteSamplers(1, &sampler);

    GLuint cube; glGenTextures(1, &cube); glBindTexture(CUBE, cube); glTexParameteri(CUBE, MIN_FILTER, NEAREST); glTexParameteri(CUBE, MAG_FILTER, NEAREST);
    glTexStorage2D(CUBE, 1, DEPTH32F, 8, 8); glTexParameteri(CUBE, COMPARE_MODE, COMPARE_REF); glTexParameteri(CUBE, COMPARE_FUNC, LESS);
    const float face_depth[6] = {.125f,.25f,.375f,.625f,.75f,.875f};
    glBindFramebuffer(FB, fb);
    for (int f = 0; f < 6; f++) {
        glFramebufferTexture2D(FB, DEPTH_ATTACHMENT, CUBE_POS_X+f, cube, 0);
        CHECK(glCheckFramebufferStatus(FB) == FRAMEBUFFER_COMPLETE, "⑨ cube face %d FBO 完整", f);
        glClearDepthf(face_depth[f]); glClear(DEPTH_BIT);
    }
    glBindFramebuffer(FB, 0); glUseProgram(shcube); GLint cube_tex = glGetUniformLocation(shcube, "uShadow"), dir = glGetUniformLocation(shcube, "uDir"), cube_ref = glGetUniformLocation(shcube, "uRef");
    CHECK(cube_tex >= 0 && dir >= 0 && cube_ref >= 0, "⑨ samplerCubeShadow 反射位置"); glUniform1i(cube_tex, 0);
    const float dirs[6][3] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
    const float cube_refs[5] = {.1875f,.3125f,.5f,.6875f,.8125f};
    for (int f = 0; f < 6; f++) for (int r = 0; r < 5; r++) {
        glUniform3f(dir, dirs[f][0], dirs[f][1], dirs[f][2]); glUniform1f(cube_ref, cube_refs[r]);
        glViewport(f*16, 224+r*16, 16, 16); glDrawArrays(4, 0, 6);
    }
    glFinish();
    for (int f = 0; f < 6; f++) for (int r = 0; r < 5; r++) {
        char label[96]; snprintf(label, sizeof label, "⑨ cube face %d ref=%.4f < depth=%.3f", f, cube_refs[r], face_depth[f]);
        tex_pixel(col, f*16+8, 224+r*16+8, cube_refs[r] < face_depth[f] ? yes : no, label);
    }
    CHECK(glGetError() == 0, "⑨ 2D/cube compare 采样与所有深度面完成无 GL 错误");
    return 0;
}

// ⑧ 第二批（数码宝贝 79 函数的差集）。cube.vert / cube.frag：颜色 = 采样 + aAdd − (0,0,0,1) + uBias[2]；aAdd 数组关着时读 GL 缺省 (0,0,0,1)，
//    抵消后颜色 = 采样 + uBias[2]（关掉的数组若读成 0，alpha 掉成 0，下面所有像素的 alpha 255 就会失败）。
//    格子 i = 视口 (8i, 0, 8, 8)，读中心 (8i+4, 4)；期望全由 GL 规范与输入手算，不读前端状态。
static void cell_px(id<MTLTexture> win, int i, const uint8_t e[4], const char *label) { tex_pixel(win, (unsigned)(i * 8 + 4), 4, e, label); }
static int second_batch(gpa_t gpa, EGLDisplay dpy, EGLSurface sf) {
    F(glGetString, const GLchar *, GLenum) F(glGetStringi, const GLchar *, GLenum, GLuint) F(glGetIntegerv, void, GLenum, GLint *) F(glGetError, GLenum, void)
    F(glDisable, void, GLenum) F(glEnable, void, GLenum) F(glViewport, void, GLint, GLint, GLsizei, GLsizei) F(glClear, void, GLbitfield) F(glClearColor, void, GLfloat, GLfloat, GLfloat, GLfloat)
    F(glClearStencil, void, GLint) F(glColorMask, void, GLuint, GLuint, GLuint, GLuint) F(glStencilFunc, void, GLenum, GLint, GLuint) F(glStencilOp, void, GLenum, GLenum, GLenum)
    F(glGenTextures, void, GLsizei, GLuint *) F(glActiveTexture, void, GLenum) F(glBindTexture, void, GLenum, GLuint) F(glPixelStorei, void, GLenum, GLint)
    F(glTexImage2D, void, GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *) F(glCompressedTexImage2D, void, GLenum, GLint, GLenum, GLsizei, GLsizei, GLint, GLsizei, const void *)
    F(glTexSubImage2D, void, GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void *) F(glCompressedTexSubImage2D, void, GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLsizei, const void *)
    F(glTexParameteri, void, GLenum, GLenum, GLint)
    F(glGenFramebuffers, void, GLsizei, GLuint *) F(glBindFramebuffer, void, GLenum, GLuint) F(glFramebufferTexture2D, void, GLenum, GLenum, GLenum, GLuint, GLint)
    F(glGenRenderbuffers, void, GLsizei, GLuint *) F(glBindRenderbuffer, void, GLenum, GLuint) F(glRenderbufferStorage, void, GLenum, GLenum, GLsizei, GLsizei)
    F(glFramebufferRenderbuffer, void, GLenum, GLenum, GLenum, GLuint) F(glCheckFramebufferStatus, GLenum, GLenum)
    F(glCreateShader, GLuint, GLenum) F(glShaderSource, void, GLuint, GLsizei, const GLchar *const *, const GLint *) F(glCompileShader, void, GLuint)
    F(glCreateProgram, GLuint, void) F(glAttachShader, void, GLuint, GLuint) F(glLinkProgram, void, GLuint) F(glGetProgramiv, void, GLuint, GLenum, GLint *) F(glUseProgram, void, GLuint)
    F(glGetUniformLocation, GLint, GLuint, const GLchar *) F(glGetAttribLocation, GLint, GLuint, const GLchar *) F(glUniform1i, void, GLint, GLint) F(glUniform1f, void, GLint, GLfloat)
    F(glUniform2f, void, GLint, GLfloat, GLfloat) F(glUniform3f, void, GLint, GLfloat, GLfloat, GLfloat) F(glUniform4fv, void, GLint, GLsizei, const GLfloat *)
    F(glGenVertexArrays, void, GLsizei, GLuint *) F(glBindVertexArray, void, GLuint) F(glGenBuffers, void, GLsizei, GLuint *) F(glBindBuffer, void, GLenum, GLuint)
    F(glBufferData, void, GLenum, GLsizeiptr, const void *, GLenum) F(glVertexAttribPointer, void, GLuint, GLint, GLenum, GLuint, GLsizei, const void *)
    F(glEnableVertexArrayAttrib, void, GLuint, GLuint) F(glDisableVertexAttribArray, void, GLuint) F(glDrawArrays, void, GLenum, GLint, GLsizei) F(glFinish, void, void)
    F(eglSwapBuffers, EGLBoolean, EGLDisplay, EGLSurface)
    enum { CUBE = 0x8513, PX = 0x8515, TEX2D = 0x0DE1, RGBA = 0x1908, UB = 0x1401, FB = 0x8D40, RB = 0x8D41, STENCIL = 0x0B90, COLOR_BIT = 0x4000, STENCIL_BIT = 0x400 };
    const GLchar *ver = glGetString(0x1F02); GLint maxtex = 0; glGetIntegerv(0x0D33, &maxtex);
    CHECK(ver && !strncmp(ver, "OpenGL ES 3.2", 13) && maxtex == 16384 && glGetStringi(0x1F03, 0) && glGetError() == 0, "⑧ glGetString / glGetStringi / glGetIntegerv：ES 上下文版本 %s、最大纹理 %d", ver ? ver : "(空)", maxtex);
    glGetIntegerv(0xDEAD, &maxtex); CHECK(glGetError() == 0x0500 && maxtex == 16384, "⑧ 没实现的查询：INVALID_ENUM、不动输出（GLES §2.3.1；D-5MW2 前写 0，空指针上崩）：%d", maxtex);
    GLuint prog = glCreateProgram(); GLint ok;
    for (int i = 0; i < 2; i++) {
        char path[1024]; snprintf(path, sizeof path, "%s/cube.%s", getenv("T_GL_DIR"), i ? "frag" : "vert");
        FILE *f = fopen(path, "rb"); if (!f) return 1; fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
        char *src = calloc(1, (size_t)n + 1); if (!src || fread(src, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(src); return 1; } fclose(f);
        GLuint sh = glCreateShader(i ? 0x8B30 : 0x8B31); const char *text = src; glShaderSource(sh, 1, &text, NULL); free(src); glCompileShader(sh); glAttachShader(prog, sh);
    }
    glLinkProgram(prog); glGetProgramiv(prog, 0x8B82, &ok); CHECK(ok == 1, "⑧ samplerCube + uniform 数组程序链接"); if (!ok) return 1; glUseProgram(prog);
    GLint uCube = glGetUniformLocation(prog, "uCube"), uTex = glGetUniformLocation(prog, "uTex"), uDir = glGetUniformLocation(prog, "uDir"), uUse = glGetUniformLocation(prog, "uUse2D");
    GLint uBias = glGetUniformLocation(prog, "uBias"), uBias2 = glGetUniformLocation(prog, "uBias[2]"), uOff = glGetUniformLocation(prog, "uOff"), uScale = glGetUniformLocation(prog, "uScale");
    CHECK(uCube >= 0 && uTex >= 0 && uDir >= 0 && uUse >= 0 && uBias >= 0 && uBias2 >= 0 && uBias2 != uBias && glGetUniformLocation(prog, "uBias[3]") == -1, "⑧ 数组元素位置：uBias / uBias[2] 不同，uBias[3] 越界回 −1");
    GLuint vao, vbo; glGenVertexArrays(1, &vao); glBindVertexArray(vao); glGenBuffers(1, &vbo); glBindBuffer(0x8892, vbo);
    const float quad[] = {-1,-1, 1,-1, -1,1, -1,1, 1,-1, 1,1}; glBufferData(0x8892, sizeof quad, quad, 0x88E4);
    GLint aPos = glGetAttribLocation(prog, "aPos"), aAdd = glGetAttribLocation(prog, "aAdd");
    glVertexAttribPointer((GLuint)aPos, 2, 0x1406, 0, 8, NULL); glEnableVertexArrayAttrib(vao, (GLuint)aPos); glDisableVertexAttribArray((GLuint)aAdd);
    glUniform2f(uOff, 0, 0); glUniform2f(uScale, 1, 1); glUniform1i(uCube, 1); glUniform1i(uTex, 0); glUniform1f(uUse, 0);
    glDisable(0x0BE2); glDisable(0x0B71); glDisable(0x0B44); glDisable(0x0C11); glDisable(STENCIL);
    // 立方体：+X 红、−X 绿、+Y 蓝、−Y 白、+Z 黄、−Z 青（各 1×1），六个主轴方向各取一面
    const uint8_t faces[6][4] = {{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,255,255},{255,255,0,255},{0,255,255,255}};
    const float dirs[6][3] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
    GLuint cube; glGenTextures(1, &cube); glActiveTexture(0x84C1); glBindTexture(CUBE, cube);
    glTexParameteri(CUBE, 0x2801, 0x2600); glTexParameteri(CUBE, 0x2800, 0x2600);
    for (int f = 0; f < 6; f++) glTexImage2D(PX + f, 0, 0x8058, 1, 1, 0, RGBA, UB, faces[f]);
    glActiveTexture(0x84C0); glClearColor(0, 0, 0, 0); glClear(COLOR_BIT);
    for (int f = 0; f < 6; f++) { glViewport(f * 8, 0, 8, 8); glUniform3f(uDir, dirs[f][0], dirs[f][1], dirs[f][2]); glDrawArrays(4, 0, 6); }
    glFinish(); id<MTLTexture> win = gl_surface_color();
    static const char *const fname[] = {"+X 红", "−X 绿", "+Y 蓝", "−Y 白", "+Z 黄", "−Z 青"};
    for (int f = 0; f < 6; f++) cell_px(win, f, faces[f], fname[f]);
    CHECK(glGetError() == 0, "⑧ 立方体六面上传 / 采样无 GL 错误（关掉的 aAdd 读 (0,0,0,1)：alpha 255 才过）");
    // uniform 数组：一次写 3 个元素，第 3 个 (0,.5,0,0) 叠到 +X 红 → (255,128,0,255)；再按「uBias[2]」单写清零 → 回到红
    const float bias[12] = {0,0,0,0, 0,0,0,0, 0,.5f,0,0}, zero[4] = {0};
    glUniform3f(uDir, 1, 0, 0); glUniform4fv(uBias, 3, bias); glViewport(0, 0, 8, 8); glDrawArrays(4, 0, 6);
    glUniform4fv(uBias2, 1, zero); glViewport(8, 0, 8, 8); glDrawArrays(4, 0, 6); glFinish();
    const uint8_t orange[] = {255,128,0,255}; cell_px(win, 0, orange, "glUniform4fv 数组 count=3 写到第 3 个元素"); cell_px(win, 1, faces[0], "uBias[2] 位置单写清零");
    // 2D 格式（单元 0，uUse2D = 1）：亮度 / alpha / 亮度 alpha 存单双通道、采样换位；565 打包；BC1 压缩块（c0 = 红 0xF800 > c1 = 0，索引全 0 → 红）
    glUniform1f(uUse, 1); GLuint t2; glGenTextures(1, &t2); glBindTexture(TEX2D, t2); glTexParameteri(TEX2D, 0x2801, 0x2600); glTexParameteri(TEX2D, 0x2800, 0x2600);
    glPixelStorei(0x0CF5, 1);
    const uint8_t lum = 77, alpha = 200, la[2] = {10, 20}; const uint16_t r565 = 0xF800; const uint8_t bc1[8] = {0x00, 0xF8, 0, 0, 0, 0, 0, 0};
    const uint8_t e_lum[] = {77,77,77,255}, e_alpha[] = {0,0,0,200}, e_la[] = {10,10,10,20}, e_red[] = {255,0,0,255};
    struct { GLint internal; GLenum format, type; const void *data; const uint8_t *e; const char *label; } cases[] = {
        {0x1909, 0x1909, UB, &lum, e_lum, "GL_LUMINANCE → (L,L,L,1)"}, {0x1906, 0x1906, UB, &alpha, e_alpha, "GL_ALPHA → (0,0,0,A)"},
        {0x190A, 0x190A, UB, la, e_la, "GL_LUMINANCE_ALPHA → (L,L,L,A)"}, {0x1907, 0x1907, 0x8363, &r565, e_red, "RGB + UNSIGNED_SHORT_5_6_5 0xF800 → 红"},
    };
    for (int i = 0; i < 4; i++) { glTexImage2D(TEX2D, 0, cases[i].internal, 1, 1, 0, cases[i].format, cases[i].type, cases[i].data); glViewport(i * 8, 0, 8, 8); glDrawArrays(4, 0, 6); }
    glCompressedTexImage2D(TEX2D, 0, 0x83F1, 4, 4, 0, 8, bc1); glViewport(32, 0, 8, 8); glDrawArrays(4, 0, 6); glFinish();
    for (int i = 0; i < 4; i++) cell_px(win, i, cases[i].e, cases[i].label);
    cell_px(win, 4, e_red, "BC1（DXT1 RGBA）4×4 压缩块 → 红");
    glCompressedTexImage2D(TEX2D, 0, 0x83F1, 4, 4, 0, 7, bc1); CHECK(glGetError() == 0x0501, "⑧ 压缩数据字节数不符：INVALID_VALUE");
    // 压缩纹理子图（#272 第 6 项）：8×8 BC1（2×2 块，每块 8 字节）先全红；块序按块行优先——(0,0)=0..7、(1,0)=8..15、(0,1)=16..23、(1,1)=24..31。
    //   按块逐次子图换右列两块为绿 → 字节上只有 (1,0) / (1,1) 变；再把左列两块也换成绿 → 整张绿，采样中心（vec2(0.5)）读到绿。
    const uint8_t redblock[8] = {0x00,0xF8,0,0,0,0,0,0}, greenblock[8] = {0xE0,0x07,0,0,0,0,0,0};
    uint8_t bc1_8[32]; for (int i = 0; i < 4; i++) memcpy(bc1_8 + 8 * i, redblock, 8);
    GLuint ct; glGenTextures(1, &ct); glBindTexture(TEX2D, ct); glTexParameteri(TEX2D, 0x2801, 0x2600); glTexParameteri(TEX2D, 0x2800, 0x2600);
    glCompressedTexImage2D(TEX2D, 0, 0x83F1, 8, 8, 0, 32, bc1_8);
    glCompressedTexSubImage2D(TEX2D, 0, 4, 0, 4, 4, 0x83F1, 8, greenblock);
    glCompressedTexSubImage2D(TEX2D, 0, 4, 4, 4, 4, 0x83F1, 8, greenblock);
    CHECK(glGetError() == 0, "⑧ 压缩子图两次单块上传（(4,0) / (4,4)）无 GL 错误");
    id<MTLTexture> cimg = gl_tex_mtl(ct, 0); uint8_t blocks[32] = {0};
    if (cimg) [cimg getBytes:blocks bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
    CHECK(cimg && !memcmp(blocks, redblock, 8) && !memcmp(blocks + 8, greenblock, 8) && !memcmp(blocks + 16, redblock, 8) && !memcmp(blocks + 24, greenblock, 8),
          "⑧ 压缩子图只改指定块：(1,0) / (1,1) 变绿，左列两块字节不变");
    glCompressedTexSubImage2D(TEX2D, 0, 0, 0, 4, 4, 0x83F1, 8, greenblock);
    glCompressedTexSubImage2D(TEX2D, 0, 0, 4, 4, 4, 0x83F1, 8, greenblock);
    glViewport(40, 0, 8, 8); glUniform1f(uUse, 1); glDrawArrays(4, 0, 6); glFinish();
    cell_px(win, 5, faces[1], "⑧ 四块都经子图写绿后采样中心为绿");
    uint64_t bad0 = gl_bad_feat;
    glCompressedTexSubImage2D(TEX2D, 0, 2, 0, 4, 4, 0x83F1, 8, greenblock); CHECK(glGetError() == 0x0501, "⑧ 子图 x 未按块对齐（2）：INVALID_VALUE");
    glCompressedTexSubImage2D(TEX2D, 0, 4, 0, 2, 4, 0x83F1, 8, greenblock); CHECK(glGetError() == 0x0501, "⑧ 子图 width 未按块对齐且不贴边界（2）：INVALID_VALUE");
    glCompressedTexSubImage2D(TEX2D, 0, 4, 0, 4, 4, 0x83F1, 7, greenblock); CHECK(glGetError() == 0x0501, "⑧ 子图长度不符（7）：INVALID_VALUE");
    glCompressedTexSubImage2D(TEX2D, 0, 6, 0, 4, 4, 0x83F1, 8, greenblock); CHECK(glGetError() == 0x0501, "⑧ 子图越界：INVALID_VALUE");
    glCompressedTexSubImage2D(TEX2D, 0, 4, 0, 4, 4, 0x83F3, 16, greenblock); CHECK(glGetError() == 0x0502, "⑧ 子图格式与存储不符（BC3 对 BC1）：INVALID_OPERATION");
    glCompressedTexSubImage2D(TEX2D, 0, 4, 0, 4, 4, 0x1908, 8, greenblock); CHECK(glGetError() == 0x0500, "⑧ 子图来源不是压缩格式（RGBA8）：INVALID_ENUM");
    glTexSubImage2D(TEX2D, 0, 0, 0, 4, 4, RGBA, UB, blocks); CHECK(glGetError() == 0x0502 && gl_bad_feat == bad0, "⑧ 压缩存储上走 glTexSubImage2D：INVALID_OPERATION 且不计未实现");
    glBindTexture(TEX2D, t2); glTexImage2D(TEX2D, 0, 0x8058, 4, 4, 0, RGBA, UB, NULL);
    glCompressedTexSubImage2D(TEX2D, 0, 0, 0, 4, 4, 0x83F1, 8, greenblock); CHECK(glGetError() == 0x0502, "⑧ 非压缩纹理上的压缩子图：INVALID_OPERATION");
    // 在途路径（#447 审阅建议补测）：先编码一笔绘制读旧存储、不 glFinish，再做压缩子图 → 子图必须换存储并复制整级全部块，
    //   已编码的那笔仍读旧红，子图后的那笔读新内容；未修改的块字节不能丢。copy_level / replaceRegion 都在 CPU 侧同步完成，可直接读字节。
    glBindTexture(TEX2D, ct); glUniform1f(uUse, 1); glUniform2f(uScale, 1, 1); glUniform2f(uOff, 0, 0);
    glCompressedTexImage2D(TEX2D, 0, 0x83F1, 8, 8, 0, 32, bc1_8);          // 重新定义成全红（四块都是 0xF800 红块）
    id<MTLTexture> before_img = gl_tex_mtl(ct, 0);
    glViewport(64, 0, 8, 8); glDrawArrays(4, 0, 6);                          // 这笔读旧存储；不等完成，序列保持「在途」
    glCompressedTexSubImage2D(TEX2D, 0, 4, 4, 4, 4, 0x83F1, 8, greenblock);  // 在途：只换 (1,1)——采样中心 uv(.5) 落在这一块
    id<MTLTexture> after_img = gl_tex_mtl(ct, 0);
    uint8_t blocks2[32]; memset(blocks2, 0xAA, sizeof blocks2);
    if (after_img) [after_img getBytes:blocks2 bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
    CHECK(after_img && after_img != before_img, "⑧ 在途压缩子图换存储（旧对象留给已编码的命令）");
    CHECK(after_img && !memcmp(blocks2, redblock, 8) && !memcmp(blocks2 + 8, redblock, 8) &&
          !memcmp(blocks2 + 16, redblock, 8) && !memcmp(blocks2 + 24, greenblock, 8),
          "⑧ 在途压缩子图复制整级：(1,1) 变绿，另三块仍是原红块字节");
    glViewport(72, 0, 8, 8); glDrawArrays(4, 0, 6); glFinish();
    cell_px(win, 8, e_red, "⑧ 在途：子图前那笔仍读旧红");
    cell_px(win, 9, faces[1], "⑧ 在途：子图后那笔读新绿");
    CHECK(glGetError() == 0, "⑧ 在途压缩子图无 GL 错误");
    glUniform2f(uScale, 1, 1); glUniform2f(uOff, 0, 0);
    glPixelStorei(0x0CF5, 4);
    // 帧缓冲对象：8×8 RGBA8 纹理 + DEPTH24_STENCIL8 渲染缓冲。先整屏清绿（挂起），再把 +X 红画进右半 → 纹理第 4 列起红；
    //   绑回 0 号，以 NEAREST 在 uv .5（第 4 列）采这张纹理 → 红。画到窗口而不是附件时纹理仍是清除前的内容（不是红）
    GLuint rt, rb, fb; glGenTextures(1, &rt); glBindTexture(TEX2D, rt); glTexParameteri(TEX2D, 0x2801, 0x2600); glTexParameteri(TEX2D, 0x2800, 0x2600);
    glTexImage2D(TEX2D, 0, 0x8058, 8, 8, 0, RGBA, UB, NULL); glBindTexture(TEX2D, 0);
    glGenRenderbuffers(1, &rb); glBindRenderbuffer(RB, rb); glRenderbufferStorage(RB, 0x88F0, 8, 8);
    glGenFramebuffers(1, &fb); glBindFramebuffer(FB, fb); glFramebufferTexture2D(FB, 0x8CE0, TEX2D, rt, 0); glFramebufferRenderbuffer(FB, 0x821A, RB, rb);
    CHECK(glCheckFramebufferStatus(FB) == 0x8CD5 && glGetError() == 0, "⑧ 颜色纹理 + 深度模板渲染缓冲：帧缓冲完整");
    glViewport(0, 0, 8, 8); glClearColor(0, 1, 0, 1); glClear(COLOR_BIT | STENCIL_BIT);
    glUniform1f(uUse, 0); glUniform3f(uDir, 1, 0, 0); glUniform2f(uScale, .5f, 1); glUniform2f(uOff, .5f, 0); glDrawArrays(4, 0, 6);
    glBindFramebuffer(FB, 0); glUniform2f(uScale, 1, 1); glUniform2f(uOff, 0, 0); glBindTexture(TEX2D, rt); glUniform1f(uUse, 1);
    glClearColor(0, 0, 1, 1); glClear(COLOR_BIT); glViewport(0, 0, 8, 8); glDrawArrays(4, 0, 6); glFinish();
    cell_px(win, 0, e_red, "画进帧缓冲附件纹理、绑回 0 号后采样");
    // 模板（窗口表面的深度模板）：清模板 0；ALWAYS/REPLACE 1、关颜色写画左半；再 EQUAL 1 画整格红 → 左红、右仍是清屏蓝
    glUniform1f(uUse, 0); glClearStencil(0); glClear(COLOR_BIT | STENCIL_BIT); glEnable(STENCIL); glViewport(48, 0, 16, 8);
    glStencilFunc(0x0207, 1, 0xff); glStencilOp(0x1E00, 0x1E00, 0x1E01); glColorMask(0, 0, 0, 0);
    glUniform2f(uScale, .5f, 1); glUniform2f(uOff, -.5f, 0); glDrawArrays(4, 0, 6);
    glColorMask(1, 1, 1, 1); glStencilFunc(0x0202, 1, 0xff); glStencilOp(0x1E00, 0x1E00, 0x1E00); glUniform2f(uScale, 1, 1); glUniform2f(uOff, 0, 0); glDrawArrays(4, 0, 6);
    glFinish(); glDisable(STENCIL);
    const uint8_t blue[] = {0,0,255,255}; tex_pixel(win, 52, 4, e_red, "模板 EQUAL 1：写过的左半通过"); tex_pixel(win, 60, 4, blue, "模板 EQUAL 1：右半不通过、保留清屏蓝");
    // 上屏裁切：本帧 0 号帧缓冲视口到 1280×720 → 上屏取左下 1280×720；下一帧画满 1920×1080 → 不裁
    glViewport(0, 0, 1280, 720); glDrawArrays(4, 0, 6); eglSwapBuffers(dpy, sf);
    CHECK(g_cropped && g_crop[0] == 0 && g_crop[1] == 0 && g_crop[2] == 1280 && g_crop[3] == 720, "⑧ 只画到 1280×720：上屏裁左下 1280×720（实测 %d：%d %d %d %d）", g_cropped, g_crop[0], g_crop[1], g_crop[2], g_crop[3]);
    glViewport(0, 0, 1920, 1080); glDrawArrays(4, 0, 6); eglSwapBuffers(dpy, sf); CHECK(!g_cropped, "⑧ 画满表面：上屏不裁");
    // 交换锁垂直同步：间隔 1（缺省）连交换 7 次 ≥ 6 拍（6/60 秒，留 10% 余量）；间隔 0 不等（7 次 < 1 拍）
    { F(eglSwapInterval, EGLBoolean, EGLDisplay, EGLint) struct timespec a0, a1; double dt;
      eglSwapInterval(dpy, 1); eglSwapBuffers(dpy, sf); clock_gettime(CLOCK_MONOTONIC, &a0); for (int i = 0; i < 7; i++) eglSwapBuffers(dpy, sf); clock_gettime(CLOCK_MONOTONIC, &a1);
      dt = (a1.tv_sec - a0.tv_sec) + (a1.tv_nsec - a0.tv_nsec) * 1e-9; CHECK(dt >= 6 / 60.0 * 0.9, "⑧ 交换间隔 1：7 次交换 %.1f ms（≥ 6 拍 = 100 ms）", dt * 1e3);
      eglSwapInterval(dpy, 0); clock_gettime(CLOCK_MONOTONIC, &a0); for (int i = 0; i < 7; i++) eglSwapBuffers(dpy, sf); clock_gettime(CLOCK_MONOTONIC, &a1);
      dt = (a1.tv_sec - a0.tv_sec) + (a1.tv_nsec - a0.tv_nsec) * 1e-9; CHECK(dt < 1 / 60.0, "⑧ 交换间隔 0：7 次交换 %.1f ms（不等，< 1 拍）", dt * 1e3);
      // 有显示链接：跟链接的拍（nvn_be_link_wait_tick 按交换间隔的拍数），自己的时钟不再睡——两套节拍叠加时真机每帧多错过 1–3 拍
      g_link = 1; g_ticks = 0; eglSwapInterval(dpy, 2); clock_gettime(CLOCK_MONOTONIC, &a0); for (int i = 0; i < 7; i++) eglSwapBuffers(dpy, sf); clock_gettime(CLOCK_MONOTONIC, &a1);
      dt = (a1.tv_sec - a0.tv_sec) + (a1.tv_nsec - a0.tv_nsec) * 1e-9;
      CHECK(g_ticks == 7 && g_tick_vs == 2 && dt < 1 / 60.0, "⑧ 有显示链接、间隔 2：跟链接等 %d 次、每次 %d 拍，自己不睡（7 次交换 %.1f ms < 1 拍）", g_ticks, g_tick_vs, dt * 1e3);
      g_link = 0; eglSwapInterval(dpy, 1); }
    CHECK(glGetError() == 0, "⑧ 第二批全程无意外 GL 错误");
    return 0;
}

// ⑪ 宽屏第三层（S2A_WIDEN_DIRECT=1 那一遍，t_gl_min.sh 第二次起；替身核心按整套放宽 2346 / 1920 回答）。期望手算：
//   表面颜色贴图宽 = round(1920 × 2346 / 1920) = 2346、eglQuerySurface 仍回 1920；全屏视口画一张红色全屏四边形（采样 1×1 红纹理），
//   存储第 10 行第 2300 列（> 1920，只有视口换算了才画得到）是红；帧缓冲纹理 64×64 当附件清绿后再采样它画到表面，读到绿（清除画进了放宽的影子，
//   采样不换影子就读到没画过的原纹理）；裁剪 [1800, 1920) 换到 [2199, 2346)；上屏裁切 = 整宽 2346 × 1080；之后反证 ① 重新定义后采到新内容、④ 上传过内容的附件影子先拷原图、② 删后同名新建的影子不被误删，删纹理后下一遍开遍释放旧影子（替身记 1 次）
#include "t_default_textures.inc"

static int widen_case(gpa_t gpa) {
    F(eglGetDisplay, EGLDisplay, void *) F(eglInitialize, EGLBoolean, EGLDisplay, EGLint *, EGLint *) F(eglBindAPI, EGLBoolean, EGLenum) F(eglChooseConfig, EGLBoolean, EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *)
    F(eglCreateWindowSurface, EGLSurface, EGLDisplay, EGLConfig, void *, const EGLint *) F(eglCreateContext, EGLContext, EGLDisplay, EGLConfig, EGLContext, const EGLint *)
    F(eglMakeCurrent, EGLBoolean, EGLDisplay, EGLSurface, EGLSurface, EGLContext) F(eglSwapBuffers, EGLBoolean, EGLDisplay, EGLSurface) F(eglQuerySurface, EGLBoolean, EGLDisplay, EGLSurface, EGLint, EGLint *)
    F(glCreateShader, GLuint, GLenum) F(glShaderSource, void, GLuint, GLsizei, const GLchar *const *, const GLint *) F(glCompileShader, void, GLuint)
    F(glCreateProgram, GLuint, void) F(glAttachShader, void, GLuint, GLuint) F(glLinkProgram, void, GLuint) F(glUseProgram, void, GLuint)
    F(glGetUniformLocation, GLint, GLuint, const GLchar *) F(glGetAttribLocation, GLint, GLuint, const GLchar *) F(glUniform1i, void, GLint, GLint) F(glUniform2f, void, GLint, GLfloat, GLfloat)
    F(glGenVertexArrays, void, GLsizei, GLuint *) F(glBindVertexArray, void, GLuint) F(glGenBuffers, void, GLsizei, GLuint *) F(glBindBuffer, void, GLenum, GLuint)
    F(glBufferData, void, GLenum, GLsizeiptr, const void *, GLenum) F(glVertexAttribPointer, void, GLuint, GLint, GLenum, GLuint, GLsizei, const void *) F(glEnableVertexAttribArray, void, GLuint)
    F(glActiveTexture, void, GLenum) F(glGenTextures, void, GLsizei, GLuint *) F(glBindTexture, void, GLenum, GLuint) F(glDeleteTextures, void, GLsizei, const GLuint *)
    F(glTexImage2D, void, GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *) F(glTexParameteri, void, GLenum, GLenum, GLint)
    F(glGenFramebuffers, void, GLsizei, GLuint *) F(glBindFramebuffer, void, GLenum, GLuint) F(glFramebufferTexture2D, void, GLenum, GLenum, GLenum, GLuint, GLint)
    F(glViewport, void, GLint, GLint, GLsizei, GLsizei) F(glClearColor, void, GLfloat, GLfloat, GLfloat, GLfloat) F(glClear, void, GLbitfield) F(glDrawArrays, void, GLenum, GLint, GLsizei) F(glFinish, void, void)
    F(glEnable, void, GLenum) F(glDisable, void, GLenum) F(glScissor, void, GLint, GLint, GLsizei, GLsizei)
    eglBindAPI(0x30A0); EGLDisplay dpy = eglGetDisplay(NULL); EGLint ma, mi; eglInitialize(dpy, &ma, &mi); EGLConfig cfg; EGLint n;
    const EGLint ctx_attr[] = {0x3098, 3, 0x30FB, 2, 0x3038}; eglChooseConfig(dpy, NULL, &cfg, 1, &n);
    EGLSurface sf = eglCreateWindowSurface(dpy, cfg, NULL, NULL); EGLContext ctx = eglCreateContext(dpy, cfg, NULL, ctx_attr); eglMakeCurrent(dpy, sf, sf, ctx);
    id<MTLTexture> col = gl_surface_color(); EGLint qw = 0; eglQuerySurface(dpy, sf, 0x3057, &qw);
    CHECK(col && col.width == 2346 && col.height == 1080 && qw == 1920, "⑪ 宽屏：表面贴图放宽到 2346×1080（实测 %lu×%lu），游戏查到的仍是 %d", (unsigned long)col.width, (unsigned long)col.height, qw);
    GLuint prog = glCreateProgram();
    for (int i = 0; i < 2; i++) { char path[1024]; snprintf(path, sizeof path, "%s/texture.%s", getenv("T_GL_DIR"), i ? "frag" : "vert");
        FILE *f = fopen(path, "rb"); if (!f) return 1; fseek(f, 0, SEEK_END); long len = ftell(f); rewind(f); char *src = calloc(1, (size_t)len + 1); fread(src, 1, (size_t)len, f); fclose(f);
        GLuint sh = glCreateShader(i ? 0x8B30 : 0x8B31); const char *t = src; glShaderSource(sh, 1, &t, NULL); free(src); glCompileShader(sh); glAttachShader(prog, sh); }
    glLinkProgram(prog); glUseProgram(prog);
    glUniform2f(glGetUniformLocation(prog, "uOff"), 0, 0); glUniform2f(glGetUniformLocation(prog, "uScale"), 1, 1);
    glUniform2f(glGetUniformLocation(prog, "uUVScale"), 0, 0); glUniform2f(glGetUniformLocation(prog, "uUVOff"), .5f, .5f); glUniform1i(glGetUniformLocation(prog, "uTex"), 0);
    GLuint vao, vbo; glGenVertexArrays(1, &vao); glBindVertexArray(vao); glGenBuffers(1, &vbo); glBindBuffer(0x8892, vbo);
    const float quad[] = {-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1}; glBufferData(0x8892, sizeof quad, quad, 0x88E4);
    GLint pos = glGetAttribLocation(prog, "aPos"); glVertexAttribPointer(pos, 2, 0x1406, 0, 8, NULL); glEnableVertexAttribArray(pos);
    GLuint red_tex, rt; const uint8_t red[] = {255, 0, 0, 255}, green[] = {0, 255, 0, 255}, blue[] = {0, 0, 255, 255};
    glActiveTexture(0x84C0); glGenTextures(1, &red_tex); glBindTexture(0x0DE1, red_tex); glTexParameteri(0x0DE1, 0x2801, 0x2600); glTexParameteri(0x0DE1, 0x2800, 0x2600);
    glTexImage2D(0x0DE1, 0, 0x8058, 1, 1, 0, 0x1908, 0x1401, red);
    glViewport(0, 0, 1920, 1080); glClearColor(0, 0, 1, 1); glClear(0x4000); glDrawArrays(4, 0, 6); glFinish();
    tex_pixel(col, 2300, 10, red, "⑪ 宽屏：全屏视口换算后画到第 2300 列（> 1920）");
    // 帧缓冲纹理当附件：清绿画进影子，采样换影子
    glGenTextures(1, &rt); glBindTexture(0x0DE1, rt); glTexParameteri(0x0DE1, 0x2801, 0x2600); glTexParameteri(0x0DE1, 0x2800, 0x2600);
    glTexImage2D(0x0DE1, 0, 0x8058, 64, 64, 0, 0x1908, 0x1401, NULL);
    GLuint fb; glGenFramebuffers(1, &fb); glBindFramebuffer(0x8D40, fb); glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, rt, 0);
    glViewport(0, 0, 64, 64); glClearColor(0, 1, 0, 1); glClear(0x4000);
    glBindFramebuffer(0x8D40, 0); glViewport(0, 0, 1920, 1080); glClearColor(0, 0, 1, 1); glClear(0x4000); glDrawArrays(4, 0, 6); glFinish();
    tex_pixel(col, 1000, 500, green, "⑪ 宽屏：附件清进放宽影子、采样换影子读到绿");
    uint32_t tc = g_wd_tc; CHECK(tc != 0, "⑪ 宽屏：开遍把表面贴图号交给核心（%u）", tc);
    // 裁剪按放宽换算：游戏裁 [1800, 1920) 清红 → 存储 [round(1800k), round(1920k)) = [2199, 2346)，第 2300 列红、第 2190 列仍是上一遍的绿
    glEnable(0x0C11); glScissor(1800, 0, 120, 1080); glClearColor(1, 0, 0, 1); glClear(0x4000); glDisable(0x0C11); glFinish();
    tex_pixel(col, 2300, 500, red, "⑪ 宽屏：裁剪换算后清到第 2300 列"); tex_pixel(col, 2190, 500, green, "⑪ 宽屏：裁剪左边界换到 2199、第 2190 列不清");
    eglSwapBuffers(dpy, sf);
    CHECK(g_cropped && g_crop[0] == 0 && g_crop[2] == 2346 && g_crop[3] == 1080, "⑪ 宽屏：上屏裁切整宽 2346×1080（实测 %d %d %d %d，裁 %d）", g_crop[0], g_crop[1], g_crop[2], g_crop[3], g_cropped);
    // 替身核心 s2a_widen_present 回 1（= 核心说这帧是 16:9 原比例页）：上屏前把免判种类 1 交给满屏判据（11-01 街霸合集原比例黑边被判未满屏）
    CHECK(g_fit_k == 1, "⑪ 宽屏：上屏前交满屏判据免判种类 = 核心返回 1（实测 %d）", g_fit_k);
    col = gl_surface_color();   // 交换后表面换到下一张颜色贴图
    // 反证 ①：当过附件的纹理重新 TexImage2D（新内容蓝）→ 采样拿到新内容，不是影子里的旧绿（按名字存影子、不核原图的旧接法读到绿）
    static uint8_t px[64 * 64 * 4]; for (int i = 0; i < 64 * 64; i++) memcpy(px + 4 * i, blue, 4);
    GLint uvo = glGetUniformLocation(prog, "uUVOff");
    glBindTexture(0x0DE1, rt); glTexImage2D(0x0DE1, 0, 0x8058, 64, 64, 0, 0x1908, 0x1401, px);
    glClearColor(0, 0, 0, 1); glClear(0x4000); glDrawArrays(4, 0, 6); glFinish();
    tex_pixel(col, 1000, 500, blue, "⑪ 宽屏反证①：附件纹理重新定义后采样拿到新内容");
    // ④：上传过内容（蓝）再当附件、不清除只裁剪清右半 [32, 64) 红 → 影子先拷进原图内容：采左边 u = .25 是蓝、右边 u = .75 是红
    glBindFramebuffer(0x8D40, fb); glViewport(0, 0, 64, 64); glEnable(0x0C11); glScissor(32, 0, 32, 64); glClearColor(1, 0, 0, 1); glClear(0x4000); glDisable(0x0C11);
    glBindFramebuffer(0x8D40, 0); glViewport(0, 0, 1920, 1080);
    glUniform2f(uvo, .25f, .5f); glDrawArrays(4, 0, 6); glFinish(); tex_pixel(col, 1000, 500, blue, "⑪ 宽屏④：影子先拷进原图上传的内容（左半蓝）");
    glUniform2f(uvo, .75f, .5f); glDrawArrays(4, 0, 6); glFinish(); tex_pixel(col, 1000, 500, red, "⑪ 宽屏④：裁剪清的右半红");
    glUniform2f(uvo, .5f, .5f);
    // 反证 ②：删掉 rt、马上新建拿到同一个名字并挂附件清黄 → 采样读到黄（旧接法：开遍时按名字释放，把新影子也删了，读到没画过的原图）
    const uint8_t yellow[] = {255, 255, 0, 255}; GLuint old = rt; int rel0 = g_wd_rel;
    glDeleteTextures(1, &rt); glGenTextures(1, &rt); CHECK(rt == old, "⑪ 宽屏反证②：删后新建复用同一个名字 %u（实测 %u）", old, rt);
    glBindTexture(0x0DE1, rt); glTexParameteri(0x0DE1, 0x2801, 0x2600); glTexParameteri(0x0DE1, 0x2800, 0x2600); glTexImage2D(0x0DE1, 0, 0x8058, 64, 64, 0, 0x1908, 0x1401, NULL);
    glBindFramebuffer(0x8D40, fb); glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, rt, 0); glViewport(0, 0, 64, 64); glClearColor(1, 1, 0, 1); glClear(0x4000);
    glBindFramebuffer(0x8D40, 0); glViewport(0, 0, 1920, 1080); glDrawArrays(4, 0, 6); glFinish();
    tex_pixel(col, 1000, 500, yellow, "⑪ 宽屏反证②：名字复用后新纹理的影子内容在");
    CHECK(g_wd_rel == rel0 + 1, "⑪ 宽屏：删纹理后下一遍开遍时释放旧影子 1 次（实测 %d 次）", g_wd_rel - rel0);
    // ⑪b 原比例回退的两侧覆盖采样（widen_fallback.inc，与 NVN 直连共用；GL 原先没接）：表面放宽 2346、客体 1920，两侧放宽带各 (2346 − 1920) / 2 = 213 列。
    //   每帧整幅清蓝（世界目标的清屏 alpha 挪成哨兵）再画一笔：视口 [200, 1720) 换算到 [244, 2102) → 两侧带 [0, 213) 与 [2133, 2346) 都没画到 → 样本报左右「没画到」；
    //   视口整宽 [0, 1920) → [0, 2346) 两侧都画到 → 样本报「画到」。样本每 30 次上屏一个、下次上屏交核心，按帧轮到为止（上限 40 / 80 帧）
    { glBindFramebuffer(0x8D40, 0); int n0 = g_cov_n;
      for (int f = 0; f < 40 && g_cov_n == n0; f++) { glViewport(200, 0, 1520, 1080); glClearColor(0, 0, 1, 1); glClear(0x4000); glDrawArrays(4, 0, 6); eglSwapBuffers(dpy, sf); usleep(20000); }
      CHECK(g_cov_n > n0 && g_cov[2] && g_cov[3] && !g_cov[0] && !g_cov[1], "⑪b 宽屏原比例回退：两侧放宽带都没画到 → GL 层交核心「左右都没画到」（样本 %d 个；画到 %d/%d、没画到 %d/%d）", g_cov_n - n0, g_cov[0], g_cov[1], g_cov[2], g_cov[3]);
      // 换成整宽画面前已经起了的样本还是窄画面：第一段最后那个样本判两侧空，产品当场在同一次上屏对窄画面补采一次（widen_fallback.inc，回退在 2–3 次上屏内生效），
      //   它在整宽第一帧上屏时才交核心。先画两帧整宽、交上去，丢掉换内容之前起的样本，之后起的样本才判整宽内容
      for (int f = 0; f < 2; f++) { glViewport(0, 0, 1920, 1080); glClearColor(0, 0, 1, 1); glClear(0x4000); glDrawArrays(4, 0, 6); eglSwapBuffers(dpy, sf); usleep(20000); }
      int n1 = g_cov_n;
      for (int f = 0; f < 80 && g_cov_n == n1; f++) { glViewport(0, 0, 1920, 1080); glClearColor(0, 0, 1, 1); glClear(0x4000); glDrawArrays(4, 0, 6); eglSwapBuffers(dpy, sf); usleep(20000); }
      CHECK(g_cov_n > n1 && !g_cov[2] && !g_cov[3], "⑪b 宽屏原比例回退：整宽画满 → 交核心「两侧都画到」（样本 %d 个；没画到 %d/%d）", g_cov_n - n1, g_cov[2], g_cov[3]); }
    return default_textures(gpa, dpy, sf, ctx);
}
int main(void) { alarm(60); @autoreleasepool {
    if (!getenv("T_GL_WIDEN")) {
        int r = allocation_case();
        if (r || getenv("T_GL_ALLOC_ONLY")) { printf("%s t_gl_alloc：%d 项，失败 %d\n", r || fails ? "✗" : "✓", checks, fails); return r || fails; }
    }
    if (getenv("T_GL_WIDEN")) {   // ⑪ 宽屏那一遍（S2A_WIDEN_DIRECT=1）：只跑宽屏用例
        void *(*egp0)(const char *) = (void *(*)(const char *))gl_lookup("eglGetProcAddress");
        int r = widen_case((gpa_t)egp0); printf("%s t_gl_min（宽屏）：%d 项，失败 %d\n", r || fails ? "✗" : "✓", checks, fails); return r || fails;
    }
    void *(*egp)(const char *) = (void *(*)(const char *))gl_lookup("eglGetProcAddress");
    if (!egp) { printf("✗ 函数表里没有 eglGetProcAddress\n"); return 1; }
    gpa_t gpa = egp;
    F(eglGetDisplay, EGLDisplay, void *) F(eglInitialize, EGLBoolean, EGLDisplay, EGLint *, EGLint *) F(eglBindAPI, EGLBoolean, EGLenum) F(eglChooseConfig, EGLBoolean, EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *)
    F(eglCreateWindowSurface, EGLSurface, EGLDisplay, EGLConfig, void *, const EGLint *) F(eglCreateContext, EGLContext, EGLDisplay, EGLConfig, EGLContext, const EGLint *)
    F(eglMakeCurrent, EGLBoolean, EGLDisplay, EGLSurface, EGLSurface, EGLContext) F(eglGetCurrentContext, EGLContext, void) F(eglSwapBuffers, EGLBoolean, EGLDisplay, EGLSurface)
    F(glGenBuffers, void, GLsizei, GLuint *) F(glDeleteBuffers, void, GLsizei, const GLuint *) F(glBindBuffer, void, GLenum, GLuint) F(glBufferData, void, GLenum, GLsizeiptr, const void *, GLenum) F(glBufferSubData, void, GLenum, GLintptr, GLsizeiptr, const void *)
    F(glGenVertexArrays, void, GLsizei, GLuint *) F(glBindVertexArray, void, GLuint) F(glVertexAttribPointer, void, GLuint, GLint, GLenum, GLuint, GLsizei, const void *)
    F(glEnableVertexAttribArray, void, GLuint) F(glCreateShader, GLuint, GLenum) F(glShaderSource, void, GLuint, GLsizei, const GLchar *const *, const GLint *)
    F(glCompileShader, void, GLuint) F(glGetShaderiv, void, GLuint, GLenum, GLint *) F(glCreateProgram, GLuint, void) F(glAttachShader, void, GLuint, GLuint)
    F(glLinkProgram, void, GLuint) F(glGetProgramiv, void, GLuint, GLenum, GLint *) F(glUseProgram, void, GLuint) F(glGetAttribLocation, GLint, GLuint, const GLchar *)
    F(glGetUniformLocation, GLint, GLuint, const GLchar *) F(glUniform2f, void, GLint, GLfloat, GLfloat) F(glUniform4f, void, GLint, GLfloat, GLfloat, GLfloat, GLfloat)
    F(glClearColor, void, GLfloat, GLfloat, GLfloat, GLfloat) F(glClear, void, GLbitfield) F(glEnable, void, GLenum) F(glDrawArrays, void, GLenum, GLint, GLsizei) F(glDrawElements, void, GLenum, GLsizei, GLenum, const void *)
    F(glDisable, void, GLenum) F(glViewport, void, GLint, GLint, GLsizei, GLsizei)
    F(glBlendFunc, void, GLenum, GLenum) F(glBlendFuncSeparate, void, GLenum, GLenum, GLenum, GLenum)
    F(glBlendEquation, void, GLenum) F(glBlendEquationSeparate, void, GLenum, GLenum) F(glBlendColor, void, GLfloat, GLfloat, GLfloat, GLfloat)
    F(glUniform1f, void, GLint, GLfloat) F(glDepthFunc, void, GLenum) F(glDepthMask, void, GLuint) F(glDepthRangef, void, GLfloat, GLfloat) F(glDepthRange, void, double, double) F(glClearDepthf, void, GLfloat) F(glClearDepth, void, double)
    F(glGetIntegerv, void, GLenum, GLint *)
    F(glFinish, void, void) F(glGetError, GLenum, void)
    // 没实现的核心名交安全空实现（游戏按报的 GL 版本直接调，回空就跳到地址 0 被系统杀，见 gl_core.m）；带厂商后缀的扩展名照旧回空
    void *miss = gpa("glNotAFunction");
    CHECK(miss != NULL && miss == gpa("glNotAFunction"), "没实现的核心名拿到安全空实现（非空、同名再查同一个）");
    CHECK(gpa("glNotAFunctionARB") == NULL, "没实现的扩展名（厂商后缀）照旧回空");
    if (miss) {   // 首次调用回 0、记一行红：临时把 1 / 2 号描述符接到文件里截这一行
        char tmpl[] = "/tmp/t_gl_min_miss.XXXXXX"; int fd = mkstemp(tmpl), o1 = dup(1), o2 = dup(2); uint64_t r = 1; char got[4096] = {0};
        if (fd >= 0) { fflush(stdout); fflush(stderr); dup2(fd, 1); dup2(fd, 2); r = ((uint64_t (*)(void))miss)(); fflush(stdout); fflush(stderr);
            dup2(o1, 1); dup2(o2, 2); lseek(fd, 0, SEEK_SET); ssize_t n = read(fd, got, sizeof got - 1); if (n > 0) got[n] = 0; close(fd); unlink(tmpl); }
        close(o1); close(o2);
        CHECK(r == 0 && strstr(got, "没实现的 GL 核心函数 glNotAFunction"), "调用空实现回 0、首次调用记一行红（回 %llu）", (unsigned long long)r);
    }

    // tri.vert / tri.frag 是 GLSL ES 3.20，显式申请 ES 3 配置与 ES 3.2 上下文。
    EGLBoolean es = eglBindAPI(0x30A0);   // EGL_OPENGL_ES_API
    const EGLint cfg_attr[] = {0x3040, 0x0040, 0x3033, 0x0004, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3038};
    const EGLint ctx_attr[] = {0x3098, 3, 0x30FB, 2, 0x3038};
    EGLDisplay dpy = eglGetDisplay(NULL); EGLint ma, mi; EGLBoolean initialized = eglInitialize(dpy, &ma, &mi); EGLConfig cfg; EGLint ncfg;
    EGLBoolean configured = eglChooseConfig(dpy, cfg_attr, &cfg, 1, &ncfg);
    EGLSurface sf = eglCreateWindowSurface(dpy, cfg, NULL, NULL); EGLContext ctx = eglCreateContext(dpy, cfg, NULL, ctx_attr);
    CHECK(es && initialized && configured && ncfg == 1 && sf && ctx && eglMakeCurrent(dpy, sf, sf, ctx) && eglGetCurrentContext() == ctx && g_ll == 1, "ES 3 配置 / ES 3.2 上下文、当前上下文一致，上屏原点设为左下（%d）", g_ll);
    // 表面按 vi 层缺省 1920×1080 建（游戏按自己的层尺寸画、不查询表面）；第一次绑表面时视口 = 整个表面。以下几何按 1280×720 视口算
    { GLint vp[4] = {-1, -1, -1, -1}; glGetIntegerv(0x0BA2, vp); CHECK(vp[0] == 0 && vp[1] == 0 && vp[2] == 1920 && vp[3] == 1080, "缺省视口 = 表面 1920×1080（实测 %d %d %d %d）", vp[0], vp[1], vp[2], vp[3]); }
    glViewport(0, 0, 1280, 720);

    const char *dir = getenv("T_GL_DIR"); char path[1024]; char *src[3];
    for (int i = 0; i < 3; i++) { snprintf(path, sizeof path, "%s/%s", dir, i == 0 ? "tri.vert" : i == 1 ? "tri.frag" : "depth.vert"); FILE *f = fopen(path, "rb"); if (!f) { printf("✗ 读不到 %s\n", path); return 1; }
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET); src[i] = calloc(1, (size_t)n + 1); fread(src[i], 1, (size_t)n, f); fclose(f); }
    GLuint vs = glCreateShader(0x8B31), fs = glCreateShader(0x8B30); GLint ok;
    glShaderSource(vs, 1, (const GLchar *const *)&src[0], NULL); glCompileShader(vs); glGetShaderiv(vs, 0x8B81, &ok); CHECK(ok == 1, "顶点着色器按源码哈希在库里找到");
    glShaderSource(fs, 1, (const GLchar *const *)&src[1], NULL); glCompileShader(fs); glGetShaderiv(fs, 0x8B81, &ok); CHECK(ok == 1, "片元着色器按源码哈希在库里找到");
    { GLuint x = glCreateShader(0x8B30); const char *s = "#version 320 es\nvoid main(){}\n"; glShaderSource(x, 1, &s, NULL); glCompileShader(x); glGetShaderiv(x, 0x8B81, &ok); CHECK(ok == 0, "库里没有的源码编译状态 0"); }
    GLuint prog = glCreateProgram(); glAttachShader(prog, vs); glAttachShader(prog, fs); glLinkProgram(prog); glGetProgramiv(prog, 0x8B82, &ok); CHECK(ok == 1, "链接成功");
    GLint aPos = glGetAttribLocation(prog, "aPos"), aCol = glGetAttribLocation(prog, "aCol"), uOff = glGetUniformLocation(prog, "uOff"), uTint = glGetUniformLocation(prog, "uTint");
    CHECK(aPos >= 0 && aCol >= 0 && aPos != aCol && uOff >= 0 && uTint >= 0 && uOff != uTint, "属性 / uniform 位置：aPos %d aCol %d uOff %d uTint %d", aPos, aCol, uOff, uTint);

    // 两个三角形：第一个逆时针、红；第二个顺时针、绿（要被背面剔除）。每顶点 x, y, r, g, b
    float v[] = {-1, -1, 1, 0, 0,   1, -1, 1, 0, 0,   -1, 1, 1, 0, 0,
                  1, 1, 0, 1, 0,    1, 0, 0, 1, 0,     0, 1, 0, 1, 0};
    GLuint vao, vbo; glGenVertexArrays(1, &vao); glBindVertexArray(vao); glGenBuffers(1, &vbo); glBindBuffer(0x8892, vbo); glBufferData(0x8892, sizeof v, v, 0x88E4);
    glVertexAttribPointer((GLuint)aPos, 2, 0x1406, 0, 20, (void *)0); glEnableVertexAttribArray((GLuint)aPos);
    glVertexAttribPointer((GLuint)aCol, 3, 0x1406, 0, 20, (void *)8); glEnableVertexAttribArray((GLuint)aCol);
    glClearColor(0, 0, 1, 1); glClear(0x4000);
    glUseProgram(prog); glUniform2f(uOff, 0, 0); glUniform4f(uTint, 0.5f, 1, 1, 1);
    glEnable(0x0B44);   // GL_CULL_FACE（缺省剔背面、逆时针为正面）
    glDrawArrays(4, 0, 6);
    id<MTLTexture> col = gl_surface_color(); glFinish();
    uint8_t a[4], b[4], c[4];
    readpx(col, 300, 120, a); readpx(col, 300, 600, b); readpx(col, 1200, 600, c);
    CHECK(near(a[0], 128) && a[1] == 0 && a[2] == 0 && a[3] == 255, "① ② GL (300, 120) 在三角形里：红 128（实测 %u %u %u %u）", a[0], a[1], a[2], a[3]);
    CHECK(b[0] == 0 && b[1] == 0 && b[2] == 255, "① GL (300, 600) 在三角形外：清屏蓝（实测 %u %u %u）——存储第 600 行 = GL 的 y 600", b[0], b[1], b[2]);
    CHECK(c[0] == 0 && c[1] == 0 && c[2] == 255, "③ 顺时针三角形被背面剔除：GL (1200, 600) 仍是蓝（实测 %u %u %u）", c[0], c[1], c[2]);
    uint64_t presents = mtl_present_count();
    EGLBoolean swapped = eglSwapBuffers(dpy, sf); mtl_present_flush();
    CHECK(swapped && mtl_present_count() == presents + 1, "交换：交给上屏路径 1 次");
    uint64_t fr, dr, pa; dm_gl_stats(&fr, &dr, &pa);
    CHECK(fr == 1 && dr == 1, "计数：帧 %llu、绘制 %llu", (unsigned long long)fr, (unsigned long long)dr);
    GLenum e = glGetError(); CHECK(e == 0, "glGetError = %#x", e);

    // ④ 命令顺序（#326）：画红三角 → glBufferSubData 把同一缓冲里的颜色改绿 → 平移后再画 → 才提交。
    //   GL 要求更新只影响它之后的绘制：第一笔仍红、第二笔绿。直接改 CPU 可见存储的实现第一笔也会变绿
    float green[] = {-1, -1, 0, 1, 0,   1, -1, 0, 1, 0,   -1, 1, 0, 1, 0};
    glClear(0x4000);
    glUniform2f(uOff, 0, 0); glDrawArrays(4, 0, 3);
    glBufferSubData(0x8892, 0, sizeof green, green);
    glUniform2f(uOff, 1, 1); glDrawArrays(4, 0, 3);
    col = gl_surface_color(); glFinish();   // 交换后表面换了张图，重取
    uint8_t f[4], g[4];
    readpx(col, 300, 120, f); readpx(col, 800, 450, g);
    CHECK(near(f[0], 128) && f[1] == 0 && f[2] == 0, "④ SubData 之前编码的那笔仍读旧数据：GL (300, 120) 红 128（实测 %u %u %u）", f[0], f[1], f[2]);
    CHECK(g[0] == 0 && g[1] == 255 && g[2] == 0, "④ SubData 之后的那笔读新数据：GL (800, 450) 绿 255（实测 %u %u %u）", g[0], g[1], g[2]);
    {
    // ⑤ 深度：GL z∈[-1,1] 经 --fixup-clipspace，再由 depth range 映射为 n+(f−n)×(z+1)/2。
    // 白色大三角覆盖每个 32×32 视口，颜色只用红/绿/蓝；所有深度参考值为可精确表示的二进制分数。
    GLuint dvs = glCreateShader(0x8B31); glShaderSource(dvs, 1, (const GLchar *const *)&src[2], NULL);
    glCompileShader(dvs); glGetShaderiv(dvs, 0x8B81, &ok); CHECK(ok == 1, "⑤ 深度顶点着色器按哈希查库成功");
    GLuint dp = glCreateProgram(); glAttachShader(dp, dvs); glAttachShader(dp, fs); glLinkProgram(dp);
    glGetProgramiv(dp, 0x8B82, &ok); CHECK(ok == 1, "⑤ 深度程序链接成功");
    GLint daPos = glGetAttribLocation(dp, "aPos"), daCol = glGetAttribLocation(dp, "aCol");
    GLint uZ = glGetUniformLocation(dp, "uZ"), dtint = glGetUniformLocation(dp, "uTint");
    CHECK(daPos >= 0 && daCol >= 0 && daPos != daCol && uZ >= 0 && dtint >= 0, "⑤ 深度程序属性 / uniform 有效");
    float white[] = {-1,-1,1,1,1, 3,-1,1,1,1, -1,3,1,1,1};
    GLuint dvao, dvbo; glGenVertexArrays(1, &dvao); glBindVertexArray(dvao);
    glGenBuffers(1, &dvbo); glBindBuffer(0x8892, dvbo); glBufferData(0x8892, sizeof white, white, 0x88E4);
    glVertexAttribPointer((GLuint)daPos, 2, 0x1406, 0, 20, (void *)0); glEnableVertexAttribArray((GLuint)daPos);
    glVertexAttribPointer((GLuint)daCol, 3, 0x1406, 0, 20, (void *)8); glEnableVertexAttribArray((GLuint)daCol);
    glUseProgram(dp); glDisable(0x0B44);
    enum { DEPTH_TEST = 0x0B71, COLOR_BIT = 0x4000, DEPTH_BIT = 0x0100, LESS = 0x0201, EQUAL = 0x0202, ALWAYS = 0x0207 };
    const uint8_t red[] = {255,0,0,255}, green_px[] = {0,255,0,255}, blue[] = {0,0,255,255};
#define DDRAW(i, z, r, g, b) do { glViewport((i)*32, 0, 32, 32); glUniform1f(uZ, z); glUniform4f(dtint, r, g, b, 1); glDrawArrays(4, 0, 3); } while (0)
#define DPIX(i, p, label) depth_pixel(col, i, p, label)
#define DCLEAR() do { glClearColor(0,0,1,1); glClear(COLOR_BIT | DEPTH_BIT); } while (0)
    // 此前未调用任何深度状态 setter：默认 clear=1、range=(0,1)、func=LESS、mask=true、test=false。
    DCLEAR(); DDRAW(0, -.5f, 1,0,0); glEnable(DEPTH_TEST); DDRAW(0, 0, 0,1,0);
    DDRAW(1, 0, 1,0,0); DDRAW(1, .5f, 0,1,0); DDRAW(1, 0, 0,1,0); glFinish();
    DPIX(0, green_px, "⑤ 默认 test 关闭不写深度，随后 .5 仍通过");
    DPIX(1, red, "⑤ 默认 LESS 且写入：.5 写后 .75 / 等于 .5 均失败");

    // 同一个清除深度 .5，near/equal/far 分别为 .25/.5/.75；mask=false 防止各笔改变参考深度。
    static const struct { const char *name; uint8_t pass[3]; } compares[] = {
        {"NEVER", {0,0,0}}, {"LESS", {1,0,0}}, {"EQUAL", {0,1,0}}, {"LEQUAL", {1,1,0}},
        {"GREATER", {0,0,1}}, {"NOTEQUAL", {1,0,1}}, {"GEQUAL", {0,1,1}}, {"ALWAYS", {1,1,1}},
    };
    glClearDepthf(.5f); DCLEAR(); glDepthMask(0); dm_gl_stats(&fr, &dr, &pa);
    uint64_t passes_before = pa, draws_before = dr;
    for (int i = 0; i < 8; i++) { glDepthFunc((GLenum)(0x0200+i)); for (int j = 0; j < 3; j++) DDRAW(i*3+j, (j-1)*.5f, 0,1,0); }
    glFinish(); dm_gl_stats(&fr, &dr, &pa);
    CHECK(pa == passes_before+1 && dr == draws_before+24, "⑤ 8 种深度比较 × 3 深度：24 笔只开 1 遍");
    for (int i = 0; i < 8; i++) for (int j = 0; j < 3; j++) DPIX(i*3+j, compares[i].pass[j] ? green_px : blue, compares[i].name);

    // mask=false 仍比较、但不写；GLuint 签名保留调用寄存器高位，GLboolean 只取低 8 bit。
    glDepthMask(1); glClearDepthf(.5f); DCLEAR(); glDepthFunc(LESS); dm_gl_stats(&fr, &dr, &pa); passes_before = pa;
    glDepthMask(0); DDRAW(0, -.5f, 1,0,0); DDRAW(0, -.25f, 0,1,0); DDRAW(0, .5f, 1,0,0);
    glDepthMask(0x100); DDRAW(1, -.5f, 1,0,0); glDepthMask(1); DDRAW(1, -.25f, 0,1,0);
    glDepthMask(0x102); DDRAW(2, -.5f, 1,0,0); glDepthMask(0x100); DDRAW(2, -.25f, 0,1,0);
    glClear(0); DDRAW(3, -.5f, 0,1,0);
    glFinish(); DPIX(0, green_px, "⑤ mask=false 仍遮挡远处、不会写入近处");
    DPIX(1, green_px, "⑤ GLboolean 0x100 的低字节为 false"); DPIX(2, red, "⑤ GLboolean 0x102 的低字节非零为 true");
    DPIX(3, green_px, "⑤ Clear(0) 不影响当前深度比较");
    dm_gl_stats(&fr, &dr, &pa); CHECK(pa == passes_before+1, "⑤ mask / GLboolean ABI / Clear(0) 不切遍");
    glDepthMask(1); glClearDepthf(.25f); DCLEAR(); glDepthMask(0); glClearDepthf(1); glClear(DEPTH_BIT);
    DDRAW(0, 0, 0,1,0); glFinish(); DPIX(0, blue, "⑤ mask=false 禁止清深度：.5 仍不能通过 .25");

    // 先用 range=(0,1)、ALWAYS 写入每格手算的参考深度，再用 EQUAL 对照目标 range 的结果。
    // n/f 先各自 clamp[0,1]；允许反向和 n=f，默认 / 非对称 / 反向 / 两端钳位都须得到表中同一深度。
    static const struct { GLfloat reference_z, z, n, f; int wide; } ranges[] = {
        {0, 0, 0,1, 0}, {-.25f, 0, .25f,.5f, 0}, {.25f, -.5f, .75f,.25f, 1},
        {-.5f, 0, -1,.5f, 0}, {.5f, 0, .5f,2, 1}, {.5f, -.5f, 2,-1, 0}, {-.25f, 1, .375f,.375f, 1},
    };
    glDepthMask(1); glDepthRangef(0,1); glClearDepthf(1); DCLEAR(); glDepthFunc(ALWAYS);
    dm_gl_stats(&fr, &dr, &pa); passes_before = pa;
    for (int i = 0; i < 7; i++) DDRAW(i, ranges[i].reference_z, 0,0,1);
    glDepthMask(0); glDepthFunc(EQUAL);
    for (int i = 0; i < 7; i++) {
        if (ranges[i].wide) glDepthRange(ranges[i].n, ranges[i].f); else glDepthRangef(ranges[i].n, ranges[i].f);
        DDRAW(i, ranges[i].z, 0,1,0);
    }
    glFinish(); for (int i = 0; i < 7; i++) DPIX(i, green_px, "⑤ range 精确映射参考 .5/.375/.625/.25/.75/.75/.375");
    dm_gl_stats(&fr, &dr, &pa); CHECK(pa == passes_before+1, "⑤ range 变动与参考绘制在同一遍");

    glDepthMask(1); glDepthRange(0,1); glDepthFunc(LESS);
    for (int i = 0; i < 4; i++) {
        if (i < 2) glClearDepthf(i ? 2 : -1); else glClearDepth(i == 3 ? 2 : -1);
        DCLEAR(); DDRAW(0, 0, 0,1,0); glFinish();
        DPIX(0, i%2 ? green_px : blue, i < 2 ? "⑤ ClearDepthf 上下钳位" : "⑤ ClearDepth 上下钳位");
    }
    // 清除值在 glClear 时取快照；只清颜色不能重写待执行的深度值，反过来也一样。
    glClearDepth(.25); glClear(DEPTH_BIT); glClearDepth(1); glClearColor(0,0,1,1); glClear(COLOR_BIT);
    DDRAW(0, 0, 0,1,0); glFinish(); DPIX(0, blue, "⑤ pending depth=.25 不受改值 / 只清颜色覆盖");
    glClearColor(1,0,0,1); glClear(COLOR_BIT); glClearColor(0,0,1,1); glClearDepthf(.75f); glClear(DEPTH_BIT);
    glFinish(); DPIX(0, red, "⑤ pending color=红不受改值 / 只清深度覆盖");
    // mask=0 既不清附件，也不能覆盖前次 pending 快照；后续 .5 对 .25 仍应被挡住。
    glClearColor(1,0,0,1); glClearDepthf(.25f); glClear(COLOR_BIT | DEPTH_BIT);
    glClearColor(0,0,1,1); glClearDepthf(1); glClear(0); glFinish(); DPIX(0, red, "⑤ Clear(0) 不改 pending 颜色快照");
    DDRAW(0, 0, 0,1,0); glFinish(); DPIX(0, red, "⑤ Clear(0) 不改 pending 深度快照");

    glClearDepth(.5); DCLEAR(); glDepthFunc(EQUAL); glDepthMask(0);
    glDepthFunc(0xDEAD); CHECK(glGetError() == 0x0500, "⑤ 非法 DepthFunc 返回 INVALID_ENUM");
    DDRAW(0, -.5f, 0,1,0); DDRAW(1, 0, 0,1,0); DDRAW(2, .5f, 0,1,0); glFinish();
    DPIX(0, blue, "⑤ 非法 DepthFunc 保持 EQUAL：near 失败"); DPIX(1, green_px, "⑤ 非法 DepthFunc 保持 EQUAL：equal 通过");
    DPIX(2, blue, "⑤ 非法 DepthFunc 保持 EQUAL：far 失败");
    e = glGetError(); CHECK(e == 0, "⑤ 深度回归完成，glGetError = %#x", e);
#undef DCLEAR
#undef DPIX
#undef DDRAW
    // 后续索引回归继续使用原三角形程序与布局，深度回归不把状态带入下一组。
    glDisable(DEPTH_TEST); glDepthMask(1); glDepthFunc(LESS); glDepthRange(0,1); glClearDepth(1);
    glUseProgram(prog); glBindVertexArray(vao); glBindBuffer(0x8892, vbo);
    glViewport(0,0,1280,720); glEnable(0x0B44);

    }
    // ⑤ 左三角：0 / 128 / 255，红；右三角：1 / 129 / 254，绿。其余顶点均在裁剪区外。
    // 左右三角的 NDC 顶点分别是 (−.9,−.8)(−.1,−.8)(−.9,.8) 与 (.1,−.8)(.9,−.8)(.1,.8)。
    // 像素中心 (128,180)、(768,180) 约为 (−.799,−.499)、(.201,−.499)，各在对应三角内部。
    float indexed[256][5] = {0};
    for (int i = 0; i < 256; i++) indexed[i][0] = indexed[i][1] = 2;
    const unsigned slots[] = {0, 128, 255, 1, 129, 254};
    const float corners[][2] = {{-.9f, -.8f}, {-.1f, -.8f}, {-.9f, .8f}, {.1f, -.8f}, {.9f, -.8f}, {.1f, .8f}};
    for (int i = 0; i < 6; i++) { indexed[slots[i]][0] = corners[i][0]; indexed[slots[i]][1] = corners[i][1]; indexed[slots[i]][i < 3 ? 2 : 3] = 1; }
    glBufferData(0x8892, sizeof indexed, indexed, 0x88E4);
    glUniform2f(uOff, 0, 0); glUniform4f(uTint, 1, 1, 1, 1);
    GLuint ebo; glGenBuffers(1, &ebo); glBindBuffer(0x8893, ebo);
    const uint8_t bytes[] = {1, 129, 254, 0, 128, 255};   // 前缀会画右边；offset 3 才是左边
    const uint8_t right[] = {1, 129, 254};
    glBufferData(0x8893, sizeof bytes, bytes, 0x88E4);
    uint64_t before_dr, before_pa, before_feat, before_err, feat, err;
    dm_gl_stats(&fr, &before_dr, &before_pa); dm_gl_bad_draws(&before_feat, &before_err);
    glClear(0x4000); glDrawElements(4, 3, 0x1401, (void *)3); glFinish();
    readpx(col, 128, 180, f); readpx(col, 768, 180, g);
    CHECK(f[0] == 255 && f[1] == 0 && f[2] == 0, "⑤ ubyte 奇数 offset 3，128 / 255 是普通索引：左红（实测 %u %u %u）", f[0], f[1], f[2]);
    CHECK(g[0] == 0 && g[1] == 0 && g[2] == 255, "⑤ 不读取 offset 之前的索引：右蓝（实测 %u %u %u）", g[0], g[1], g[2]);
    dm_gl_stats(&fr, &dr, &pa); dm_gl_bad_draws(&feat, &err);
    CHECK(dr == before_dr + 1 && pa == before_pa + 1 && feat == before_feat && err == before_err && glGetError() == 0, "⑤ ubyte 正常绘制：draw +1、pass +1、无错误");

    // 同一 render pass、同一次提交：先左红，再改同一 EBO 为右绿；转换不得延后读取更新后的索引。
    dm_gl_stats(&fr, &before_dr, &before_pa);
    glClear(0x4000); glDrawElements(4, 3, 0x1401, (void *)3);
    glBufferSubData(0x8893, 3, sizeof right, right); glDrawElements(4, 3, 0x1401, (void *)3); glFinish();
    readpx(col, 128, 180, f); readpx(col, 768, 180, g);
    CHECK(f[0] == 255 && f[1] == 0 && f[2] == 0, "⑤ EBO SubData 前的绘制保留左红（实测 %u %u %u）", f[0], f[1], f[2]);
    CHECK(g[0] == 0 && g[1] == 255 && g[2] == 0, "⑤ EBO SubData 后的绘制得到右绿（实测 %u %u %u）", g[0], g[1], g[2]);
    dm_gl_stats(&fr, &dr, &pa);
    CHECK(dr == before_dr + 2 && pa == before_pa + 1 && glGetError() == 0, "⑤ draw → SubData → draw：两次绘制只开一遍");

    if (triangle_fans(gpa, col)) return 1;
    glUseProgram(prog);   // fan 回归使用独立程序，混合回归仍使用 tri.vert / tri.frag。

    // ⑤ 单源混合：GL 4.5 core §17.3.6、表 17.1/17.2。白色大三角覆盖各个 32×32 视口；每格只画一次，
    //    S=(51,102,153,85)/255，D=(153,51,102,204)/255。RGBA8 允许 ±1 量化误差；期望不读取前端状态。
    enum { BLEND = 0x0BE2, ADD = 0x8006, SUB = 0x800A, REV = 0x800B, MIN = 0x8007, MAX = 0x8008,
           SA = 0x0302, OMSA = 0x0303, CC = 0x8001, OMCC = 0x8002, INVALID_ENUM = 0x0500 };
    const uint8_t source[] = {51,102,153,85}, dest[] = {153,51,102,204};
    float white[] = {-1,-1,1,1,1, 3,-1,1,1,1, -1,3,1,1,1};
    GLuint blend_vao, blend_vbo; glGenVertexArrays(1, &blend_vao); glBindVertexArray(blend_vao);
    glGenBuffers(1, &blend_vbo); glBindBuffer(0x8892, blend_vbo); glBufferData(0x8892, sizeof white, white, 0x88E4);
    glVertexAttribPointer((GLuint)aPos, 2, 0x1406, 0, 20, (void *)0); glEnableVertexAttribArray((GLuint)aPos);
    glVertexAttribPointer((GLuint)aCol, 3, 0x1406, 0, 20, (void *)8); glEnableVertexAttribArray((GLuint)aCol);
    glDisable(0x0B44); glUniform2f(uOff, 0, 0); glUniform4f(uTint, .2f, .4f, .6f, 1.f/3);
#define BDRAW(i) do { glViewport((i)*32, 0, 32, 32); glDrawArrays(4, 0, 3); } while (0)
#define BPIX(i, p, label) blend_pixel(col, i, p, label)
#define BCLEAR() do { glClearColor(.6f, .2f, .4f, .8f); glClear(0x4000); } while (0)
    BCLEAR(); glEnable(BLEND); BDRAW(0); glFinish();
    BPIX(0, source, "⑤ 默认 ONE/ZERO、ADD 覆盖源 RGBA");
    // 在任何 glBlendColor 之前检查默认常量色 (0,0,0,0)。
    BCLEAR(); glBlendFunc(CC, OMCC); BDRAW(0); glFinish();
    BPIX(0, dest, "⑤ 默认常量色为零");

    // 每行两笔：F/0 得 S×F，0/F 得 D×F；同时检验 RGB 与 alpha 的源/目标四槽。
    // 例如 SRC_COLOR：S×S=(10.2,40.8,91.8,28⅓)，D×S=(30.6,20.4,61.2,68)。
    // SATURATE 的 RGB 因子 min(1/3,1−.8)=.2，alpha 因子为 1；常量 C=(.25,.5,.75,.6)。
    static const struct { GLenum factor; const char *name; uint8_t s[4], d[4]; } factors[] = {
        {0, "ZERO", {0,0,0,0}, {0,0,0,0}},
        {1, "ONE", {51,102,153,85}, {153,51,102,204}},
        {0x0300, "SRC_COLOR", {10,41,92,28}, {31,20,61,68}},
        {0x0301, "ONE_MINUS_SRC_COLOR", {41,61,61,57}, {122,31,41,136}},
        {SA, "SRC_ALPHA", {17,34,51,28}, {51,17,34,68}},
        {OMSA, "ONE_MINUS_SRC_ALPHA", {34,68,102,57}, {102,34,68,136}},
        {0x0304, "DST_ALPHA", {41,82,122,68}, {122,41,82,163}},
        {0x0305, "ONE_MINUS_DST_ALPHA", {10,20,31,17}, {31,10,20,41}},
        {0x0306, "DST_COLOR", {31,20,61,68}, {92,10,41,163}},
        {0x0307, "ONE_MINUS_DST_COLOR", {20,82,92,17}, {61,41,61,41}},
        {0x0308, "SRC_ALPHA_SATURATE", {10,20,31,85}, {31,10,20,204}},
        {CC, "CONSTANT_COLOR", {13,51,115,51}, {38,26,77,122}},
        {OMCC, "ONE_MINUS_CONSTANT_COLOR", {38,51,38,34}, {115,26,26,82}},
        {0x8003, "CONSTANT_ALPHA", {31,61,92,51}, {92,31,61,122}},
        {0x8004, "ONE_MINUS_CONSTANT_ALPHA", {20,41,61,34}, {61,20,41,82}},
    };
    BCLEAR(); glBlendColor(.25f, .5f, .75f, .6f); dm_gl_stats(&fr, &dr, &pa);
    uint64_t passes_before = pa, draws_before = dr;
    for (int i = 0; i < 15; i++) {
        GLenum fct = factors[i].factor;
        glBlendFuncSeparate(fct, 0, fct, 0); BDRAW(i*2);
        glBlendFuncSeparate(0, fct, 0, fct); BDRAW(i*2+1);
    }
    glFinish(); dm_gl_stats(&fr, &dr, &pa);
    CHECK(pa == passes_before + 1 && dr == draws_before + 30, "⑤ 15 因子四槽：30 笔绘制只开 1 遍");
    for (int i = 0; i < 15; i++) { BPIX(i*2, factors[i].s, factors[i].name); BPIX(i*2+1, factors[i].d, factors[i].name); }

    // 透明叠加 RGB=S/3+D×2/3=(119,68,119)；同因子 alpha=85/3+204×2/3=164⅓。
    // 独立 alpha 改为 ONE / ONE_MINUS_SRC_ALPHA，结果 85+136=221；切回原状态必须命中正确 PSO。
    const uint8_t over[] = {119,68,119,164}, separate[] = {119,68,119,221};
    BCLEAR(); dm_gl_stats(&fr, &dr, &pa); passes_before = pa;
    glBlendFunc(SA, OMSA); BDRAW(0);
    glBlendFuncSeparate(SA, OMSA, 1, OMSA); BDRAW(1);
    glBlendFunc(SA, OMSA); BDRAW(2); glFinish(); dm_gl_stats(&fr, &dr, &pa);
    BPIX(0, over, "⑤ 透明叠加"); BPIX(1, separate, "⑤ 独立 alpha"); BPIX(2, over, "⑤ 切回原因子 PSO");
    CHECK(pa == passes_before + 1, "⑤ 透明 / 独立 alpha / 切回在同一遍");

    // 各方程都分别用于 RGB 与 alpha；MIN/MAX 故意给 ZERO/ZERO，必须仍比较未乘因子的 S/D。
    static const struct { GLenum rgb, alpha; uint8_t p[4]; } equations[] = {
        {ADD, SUB, {204,153,255,0}}, {SUB, REV, {0,51,51,119}}, {REV, MIN, {102,0,0,85}},
        {MIN, MAX, {51,51,102,204}}, {MAX, ADD, {153,102,153,255}},
    };
    BCLEAR(); dm_gl_stats(&fr, &dr, &pa); passes_before = pa;
    for (int i = 0; i < 5; i++) {
        glBlendFuncSeparate(i >= 3 ? 0 : 1, i >= 3 ? 0 : 1, i == 2 || i == 3 ? 0 : 1, i == 2 || i == 3 ? 0 : 1);
        glBlendEquationSeparate(equations[i].rgb, equations[i].alpha); BDRAW(i);
    }
    glFinish(); dm_gl_stats(&fr, &dr, &pa);
    for (int i = 0; i < 5; i++) BPIX(i, equations[i].p, "⑤ RGB / alpha 独立方程");
    CHECK(pa == passes_before + 1, "⑤ 五种方程在同一遍切换");

    // 同一编码器上改变动态常量色、方程、因子再切回；越界常量 (-.5,1.5,.25,2) 钳位成 (0,1,.25,1)。
    const uint8_t constant_a[] = {13,51,115,51}, constant_b[] = {0,102,38,85};
    BCLEAR(); dm_gl_stats(&fr, &dr, &pa); passes_before = pa;
    glBlendEquation(ADD); glBlendFunc(CC, 0); glBlendColor(.25f, .5f, .75f, .6f); BDRAW(0);
    glBlendColor(-.5f, 1.5f, .25f, 2); BDRAW(1);
    glBlendEquation(REV); glBlendFunc(0, 1); BDRAW(2);
    glBlendEquation(ADD); glBlendFunc(CC, 0); glBlendColor(.25f, .5f, .75f, .6f); BDRAW(3);
    glDisable(BLEND); BDRAW(4); glEnable(BLEND); BDRAW(5); glFinish();
    BPIX(0, constant_a, "⑤ 常量 A"); BPIX(1, constant_b, "⑤ 常量 clamp"); BPIX(2, dest, "⑤ 同遍改方程及因子");
    BPIX(3, constant_a, "⑤ 切回常量 A / 原 PSO"); BPIX(4, source, "⑤ disable 后源色覆盖"); BPIX(5, constant_a, "⑤ 同遍重新 enable");
    dm_gl_stats(&fr, &dr, &pa); CHECK(pa == passes_before + 1, "⑤ 常量 / 方程 / 因子 / 开关变化不切遍");
    BDRAW(6); glFinish(); BPIX(6, constant_a, "⑤ 新编码器恢复混合与常量色");
    dm_gl_stats(&fr, &dr, &pa); CHECK(pa == passes_before + 2, "⑤ glFinish 后新编码器恰好多一遍");

    // 非法调用每次都绘制：不能只检查错误码而漏掉部分更新。基准 RGB=D×2/3−S/3=(85,0,17)，alpha=Sα=85。
    const uint8_t unchanged[] = {85,0,17,85};
    BCLEAR(); glBlendFuncSeparate(SA, OMSA, 1, 0); glBlendEquationSeparate(REV, ADD); dm_gl_stats(&fr, &dr, &pa); draws_before = dr;
    const GLenum invalid_factors[][4] = {{0xDEAD,0,0,0}, {0,0xDEAD,0,0}, {0,0,0xDEAD,0}, {0,0,0,0xDEAD}};
    for (int i = 0; i < 4; i++) {
        glBlendFuncSeparate(invalid_factors[i][0], invalid_factors[i][1], invalid_factors[i][2], invalid_factors[i][3]);
        CHECK(glGetError() == INVALID_ENUM, "⑤ 非法因子槽 %d 返回 INVALID_ENUM", i); BDRAW(i);
    }
    glBlendFunc(0, 0xDEAD); CHECK(glGetError() == INVALID_ENUM, "⑤ glBlendFunc 非法目标返回 INVALID_ENUM"); BDRAW(4);
    glBlendEquationSeparate(ADD, 0xDEAD); CHECK(glGetError() == INVALID_ENUM, "⑤ 非法 alpha 方程返回 INVALID_ENUM"); BDRAW(5);
    glBlendEquationSeparate(0xDEAD, SUB); CHECK(glGetError() == INVALID_ENUM, "⑤ 非法 RGB 方程返回 INVALID_ENUM"); BDRAW(6);
    glBlendEquation(0xDEAD); CHECK(glGetError() == INVALID_ENUM, "⑤ glBlendEquation 非法枚举返回 INVALID_ENUM"); BDRAW(7);
    // 当前 ES 3.2 无双源扩展，四种 SRC1 枚举分别放在四槽：报红 + INVALID_ENUM，仍须原子保持。
    const GLenum dual[][4] = {{0x88F9,0,0,0}, {0,0x88FA,0,0}, {0,0,0x8589,0}, {0,0,0,0x88FB}};
    uint64_t feat_before, err_before, feat_after, err_after; dm_gl_bad_draws(&feat_before, &err_before);
    for (int i = 0; i < 4; i++) {
        glBlendFuncSeparate(dual[i][0], dual[i][1], dual[i][2], dual[i][3]);
        CHECK(glGetError() == INVALID_ENUM, "⑤ ES 3.2 双源因子槽 %d 返回 INVALID_ENUM", i); BDRAW(i+8);
    }
    glBlendFunc(0, 0x88F9); CHECK(glGetError() == INVALID_ENUM, "⑤ ES 3.2 glBlendFunc 双源目标返回 INVALID_ENUM"); BDRAW(12);
    glFinish(); dm_gl_bad_draws(&feat_after, &err_after); dm_gl_stats(&fr, &dr, &pa);
    CHECK(feat_after == feat_before && err_after == err_before && dr == draws_before + 13, "⑤ 拒绝调用不丢后续 13 笔有效绘制");
    for (int i = 0; i < 13; i++) BPIX(i, unchanged, "⑤ 拒绝非法 / 双源调用后状态保持");

    // GL 4.5 §17.3.6：RGBA8 的源分量和因子在混合前 clamp；不是等方程求完才钳位。
    // S=(2,-1,.5,2) -> (1,0,.5,1)，SRC_ALPHA/ONE_MINUS_SRC_ALPHA -> ONE/ZERO。
    const uint8_t clamped_source[] = {255,0,128,255};
    BCLEAR(); glBlendEquation(ADD); glBlendFunc(SA, OMSA); glUniform4f(uTint, 2, -1, .5f, 2); BDRAW(0); glFinish();
    BPIX(0, clamped_source, "⑤ RGBA8 混合前钳位越界源色与 alpha");
    e = glGetError(); CHECK(e == 0, "⑤ 所有混合回归完成，glGetError = %#x", e);
#undef BCLEAR
#undef BPIX
#undef BDRAW
    if (cull_states(gpa, col)) return 1;
    if (scissored_clears(gpa, col)) return 1;
    if (masked_clears(gpa, col)) return 1;
    if (texture_sampling(gpa, col, dpy, sf, ctx)) return 1;
    if (es100_sampling(gpa, col)) return 1;
    if (shadow_sampling(gpa, col)) return 1;
    if (second_batch(gpa, dpy, sf)) return 1;
    if (default_textures(gpa, dpy, sf, ctx)) return 1;
    if (fails) { printf("✗ t_gl_min：%d 项失败\n", fails); return 1; }
    printf("✓ t_gl_min：%d 项全过\n", checks); return 0;
}}
