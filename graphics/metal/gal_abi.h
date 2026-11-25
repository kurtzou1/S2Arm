// Ryujinx GAL → Metal 渲染器的 C ABI（10-18 起，渲染线）。
// 分层：C# 薄适配（sw/gfx/gal/cs，实现 Ryujinx.Graphics.GAL 的 IRenderer / IPipeline / ITexture …）+ 本目录的 C/ObjC 后端（复用 nvn_mtl 的驻留 / 零拷贝 / Metal 4 经验）。
// 调用方式：一律导出函数直调（C# [DllImport("nxgal")] + 解析到主程序 / libnxgal.dylib；NativeAOT 上 DirectPInvoke 静态链）。
//   参数全部 blittable（整数 / 浮点 / 指针 / 本头里的定长结构），C# 端零封送；不用命令环（直调几纳秒，环要两端各维护一份记录布局）。
// 线程：Ryujinx 的 GPU 线程就是调用线程（Gpu 层串行）；后端不另起编码线程。除 nxgal_current_sync 外所有入口同一线程调用。
// 句柄：缓冲 / 贴图 / 采样器 / 程序 / 计数事件一律 uint32 编号（0 = 空）；GAL BufferHandle 的值就是缓冲编号。
// 枚举：参数里的 format / target / compare_op 等一律是 Ryujinx.Graphics.GAL 枚举的整数值，原样传，翻译在 C 端。
// ABI 指纹：不手写版本号。构建时 tools/abi_hash.py 对本文件（去注释、合并空白）取 SHA-256 前 8 字节，C 端编成 NXGAL_ABI_HASH、C# 端编成 NxGal.Abi.Hash，
// 初始化时比对 nxgal_abi_hash()，不一致当场报错（10-18/19 两次改签名没升号，旧库配新核心库越界卡死）。改注释不变指纹，改签名 / 结构 / 常量必变。
// 分块：各块在自己的 .m 里实现自己那段函数，声明都加在本头对应小节（只加不改别人的）。
#pragma once
#include <stdint.h>
#include <stddef.h>
#include "../dsx/dsx_abi.h"   // NXGAL_API 与直连翻译库 libdsx（graphics/dsx，11-08 拆出）的导出原型


#ifdef __cplusplus
extern "C" {
#endif

// ---------- 结构（与 C# 端 [StructLayout(Sequential)] 逐字段对应）----------
// 贴图描述 = GAL TextureCreateInfo 原样搬运
typedef struct {
    int32_t width, height, depth, levels, samples, block_w, block_h, bpp;
    int32_t format;          // Ryujinx.Graphics.GAL.Format
    int32_t ds_mode;         // DepthStencilMode：0 Depth 1 Stencil
    int32_t target;          // Target：0 1D 1 2D 2 3D 3 1DArray 4 2DArray 5 2DMS 6 2DMSArray 7 Cube 8 CubeArray 9 Buffer
    int32_t swz[4];          // SwizzleComponent：0 Zero 1 One 2 R 3 G 4 B 5 A
} nxgal_tex_info;

typedef struct { int32_t x, y, w, h; } nxgal_rect;
// BufferRange：buf = 缓冲编号；write = 着色器会写
typedef struct { uint32_t buf; int32_t offset, size, write; } nxgal_buf_range;
typedef struct { int32_t binding; nxgal_buf_range r; } nxgal_buf_assign;          // BufferAssignment
typedef struct { int32_t enable; float constant[4]; int32_t color_op, color_src, color_dst, alpha_op, alpha_src, alpha_dst; } nxgal_blend;   // BlendDescriptor
typedef struct { int32_t test, write, func; } nxgal_depth_test;                    // DepthTestDescriptor
typedef struct {                                                                   // StencilTestDescriptor
    int32_t enable;
    int32_t front_func, front_sfail, front_dppass, front_dpfail, front_ref, front_func_mask, front_mask;
    int32_t back_func, back_sfail, back_dppass, back_dpfail, back_ref, back_func_mask, back_mask;
} nxgal_stencil;
typedef struct { float x, y, w, h; int32_t swz[4]; float znear, zfar; } nxgal_viewport;   // Viewport（swz = ViewportSwizzle）
typedef struct { int32_t buffer, offset, is_zero, format; } nxgal_vattr;          // VertexAttribDescriptor
typedef struct { nxgal_buf_range r; int32_t stride, divisor; } nxgal_vbuf;        // VertexBufferDescriptor
typedef struct {                                                                   // SamplerCreateInfo
    int32_t min_filter, mag_filter, seamless_cube, addr_u, addr_v, addr_p, compare_mode, compare_op;
    float border[4]; float min_lod, max_lod, lod_bias, max_aniso;
} nxgal_sampler_info;
typedef struct { int32_t left, right, top, bottom, flip_x, flip_y, stretched; float aspect_x, aspect_y; } nxgal_crop;   // ImageCrop
// 着色器：Ryujinx 交来的 SPIR-V（TargetApi.Vulkan）。stage = ShaderStage：0 计算 1 顶点 2 曲面控制 3 曲面求值 4 几何 5 片元
typedef struct { const uint8_t *code; uint32_t len; int32_t stage; } nxgal_shader;
// 资源布局（ShaderInfo.ResourceLayout.Sets 拍平）：set = 描述符集号（见 Capabilities 的 *SetIndex），type = ResourceType
//   0 UniformBuffer 1 StorageBuffer 2 Texture 3 Sampler 4 TextureAndSampler 5 Image 6 BufferTexture 7 BufferImage；stages = ResourceStages 位
typedef struct { int32_t set, binding, count, type, stages; } nxgal_res_desc;

// ---------- 第 1 块：核心与同步（gal_core.m）----------
NXGAL_API uint64_t nxgal_abi_hash(void);   // = 构建时的 NXGAL_ABI_HASH（见文件头）
NXGAL_API int  nxgal_init(int debug_level);              // 0 = 成功
// 设备能力（nxgal_init 之后调，MTLDevice 当场查询；能力表据此报，不按平台写死）：out[0] 位见下，out[1] 计算共享内存上限字节，out[2] 建议工作集字节，out[3] 保留 0
enum { NXGAL_CAP_BC = 1, NXGAL_CAP_ASTC = 2, NXGAL_CAP_ETC2 = 4, NXGAL_CAP_PACKED16 = 8, NXGAL_CAP_ASTC_HDR = 16 };   // PACKED16 = ABGR4 / B5G6R5 / A1BGR5 / BGR5A1（Apple 族格式）
NXGAL_API void nxgal_device_caps(uint64_t out[4]);
// 管线归档统计（环境变量 NXGAL_PSO_ARCHIVE / NXGAL_PSO_SCRIPT / NXGAL_PSO_ARCHIVE_OUT 见 gal_core.m）：[0] 归档命中 [1] 现建 [2] 现建累计纳秒 [3] 归档已载入
NXGAL_API void nxgal_pso_cache_stats(uint64_t out[4]);
NXGAL_API int nxgal_pso_inflight(void);   // 异步现建在编条数（单测按事件等编完用，不靠墙钟）
// 着色器包管线归档目录：只登记本机架构 × 系统大版本的各片 gal_pso.<…>.<片号>.bin 与索引 gal_pso.idx（管线描述 → 片号），不打开；建管线时按索引只开那一片，
//   开前向原生层低区统一账申请（s2a_lowva，取不到不设限），账本不给就这片不开、首遇现建；开了不关（iPhone 上关片不还地址，gal_core.m pa_get）。0 = 已登记；1 = 包里没有本机的归档；-1 = 索引缺或坏（归档不用、首遇现建）
NXGAL_API int32_t nxgal_pso_archive_open_dir(const char *dir);
NXGAL_API void nxgal_warm_internal(void);   // 内部管线预建（定格 / 上屏 / 顶点重排 / 索引转换），第一帧之前调一次   // 着色器包管线归档 <dir>/gal_pso.<本机 GPU 架构名>.bin：0 载入 / 1 包里没有本机架构 / -1 失败（nxgal_init 之后、建管线之前调）
NXGAL_API void nxgal_shutdown(void);
NXGAL_API void nxgal_request_stop(void);
NXGAL_API int nxgal_shutdown_session(void);
NXGAL_API void nxgal_barrier(int kind);                  // 0 Barrier 1 CommandBufferBarrier 2 TextureBarrier 3 TextureBarrierTiled
NXGAL_API void nxgal_flush(void);                        // 提交已录命令（不等）；PreFrame / 出图前用
// 同步（GAL CreateSync / WaitSync / GetCurrentSync）：id 由 Gpu 层给，单调递增
NXGAL_API void nxgal_create_sync(uint64_t id, int strict);
NXGAL_API void nxgal_wait_sync(uint64_t id);
NXGAL_API uint64_t nxgal_current_sync(void);             // 已完成的最大同步号（可在任意线程调）

// ---------- 第 3 块：贴图（gal_tex.m；第 1 块先给渲染目标所需最小集）----------
NXGAL_API uint32_t nxgal_tex_create(const nxgal_tex_info *info);
NXGAL_API uint32_t nxgal_tex_view(uint32_t parent, const nxgal_tex_info *info, int32_t first_layer, int32_t first_level);
NXGAL_API void nxgal_tex_release(uint32_t tex);
// 读回：layer / level = -1 表示整张（各级各层紧排，顺序同 GAL GetData()：级在外、层在内）；否则单层单级。
// 返回字节数；out 为空时只算大小。调用隐含提交并等 GPU 完成（GPU 写回按需可见的入口之一）。
NXGAL_API uint64_t nxgal_tex_get_data(uint32_t tex, int32_t layer, int32_t level, void *out, uint64_t out_len);
// 写入：layer / level = -1 表示整张；region 非空时只写该矩形（单层单级）
NXGAL_API void nxgal_tex_set_data(uint32_t tex, int32_t layer, int32_t level, const nxgal_rect *region, const void *data, uint64_t len);
// 上传租约（gal_tex.m）：GPU 模拟线程上租共享缓冲、直接写入，再交给贴图 / 缓冲写入（渲染器拿它当暂存），省托管数组与一次拷贝。rent 不拿 API 锁；0 = 租不到（退回旧路）
NXGAL_API uint32_t nxgal_upload_rent(uint64_t len, void **cpu);
NXGAL_API void nxgal_upload_drop(uint32_t lease);
NXGAL_API void nxgal_tex_set_data_lease(uint32_t tex, int32_t layer, int32_t level, const nxgal_rect *region, uint32_t lease, uint64_t len);
NXGAL_API void nxgal_buf_set_data_lease(uint32_t buf, int32_t offset, uint32_t lease, int32_t size);
// BC → ASTC 预转包（gal_tex.m「BC → ASTC」；设备不支持 BC 且设了 NXGAL_ASTC_PACK）：bce_active = 本进程 BC 贴图走包没有（能力表这时照报支持 BC）；
//   set_bc = 经包的 BC 贴图上传原始 BC：1 包里全命中、已传 ASTC；0 没命中，贴图已是解压格式，调用方解压后再 nxgal_tex_set_data；-1 不是经包的 BC 贴图
NXGAL_API int32_t nxgal_bce_active(void);
NXGAL_API int32_t nxgal_tex_set_bc(uint32_t tex, int32_t layer, int32_t level, const nxgal_rect *region, const void *data, uint64_t len);

// ---------- 第 5 块：渲染目标与清屏（gal_pass.m）----------
// colors[i] = 贴图编号（0 = 不挂），n ≤ 8；depth = 深度模板贴图（0 = 无）
NXGAL_API void nxgal_set_render_targets(const uint32_t *colors, int32_t n, uint32_t depth);
NXGAL_API void nxgal_set_scissors(const nxgal_rect *rects, int32_t n);   // 第 0 个也是清屏剪裁（同 Vulkan 后端 ClearScissor）
NXGAL_API void nxgal_clear_color(int32_t index, int32_t layer, int32_t layer_count, uint32_t mask, const float rgba[4]);
NXGAL_API void nxgal_clear_ds(int32_t layer, int32_t layer_count, float depth, int32_t depth_mask, int32_t stencil, int32_t stencil_mask);

// 采样器（第 3 块，gal_tex.m）
NXGAL_API uint32_t nxgal_sampler_create(const nxgal_sampler_info *info);
NXGAL_API void nxgal_sampler_release(uint32_t smp);
// 贴图其余（第 3 块）：拷贝（GAL ITexture.CopyTo 四种）、贴图缓冲（SetStorage）
NXGAL_API void nxgal_tex_copy(uint32_t src, uint32_t dst, int32_t first_layer, int32_t first_level);                   // CopyTo(dst, firstLayer, firstLevel)：src 全部层级拷到 dst 的偏移处
NXGAL_API void nxgal_tex_copy_slice(uint32_t src, uint32_t dst, int32_t src_layer, int32_t dst_layer, int32_t src_level, int32_t dst_level);
NXGAL_API void nxgal_tex_copy_region(uint32_t src, uint32_t dst, const nxgal_rect *src_rect, const nxgal_rect *dst_rect, int32_t linear);   // 可缩放（blit）
NXGAL_API void nxgal_tex_copy_to_buffer(uint32_t src, const nxgal_buf_range *dst, int32_t layer, int32_t level, int32_t stride);
NXGAL_API void nxgal_tex_set_storage(uint32_t tex, const nxgal_buf_range *buf);   // Target.TextureBuffer：贴图视图挂到缓冲上
// 贴图 / 图像数组（CreateTextureArray / CreateImageArray；第 3 块）：数组编号与贴图编号不同空间
NXGAL_API uint32_t nxgal_tarr_create(int32_t size, int32_t is_buffer, int32_t is_image);
NXGAL_API void nxgal_tarr_set_textures(uint32_t arr, int32_t index, const uint32_t *tex, int32_t n);
NXGAL_API void nxgal_tarr_set_samplers(uint32_t arr, int32_t index, const uint32_t *smp, int32_t n);
NXGAL_API void nxgal_tarr_release(uint32_t arr);

// ---------- 第 2 块：缓冲（gal_buf.m）----------
NXGAL_API uint32_t nxgal_buf_create(int32_t size, int32_t access);                 // access = BufferAccess
NXGAL_API uint32_t nxgal_buf_create_host(void *ptr, int32_t size);
NXGAL_API void nxgal_host_remapped(uint64_t addr, uint64_t size);              // [addr, addr+size) 背后物理页被换掉：重叠的宿主映射作废别名 / 窗口、对新页重建                // CreateBuffer(nint, int)：零拷贝映射宿主内存（客体内存）
NXGAL_API uint32_t nxgal_buf_create_sparse(const nxgal_buf_range *ranges, int32_t n);
NXGAL_API void nxgal_buf_delete(uint32_t buf);
NXGAL_API int32_t nxgal_buf_get_data(uint32_t buf, int32_t offset, int32_t size, void *out);   // 隐含提交并等 GPU 完成；返回 0 = 成功
NXGAL_API void nxgal_buf_set_data(uint32_t buf, int32_t offset, const void *data, int32_t size);   // 按命令顺序生效
NXGAL_API void nxgal_buf_clear(uint32_t buf, int32_t offset, int32_t size, uint32_t value);
NXGAL_API void nxgal_buf_copy(uint32_t src, uint32_t dst, int32_t src_offset, int32_t dst_offset, int32_t size);
NXGAL_API int32_t nxgal_prepare_host_mapping(void *addr, uint64_t size);
NXGAL_API int32_t nxgal_hostmap_probe(void);   // 零拷贝宿主映射 iOS 可行性探针（NXGAL_HOSTMAP_PROBE=1 时初始化后跑一次，gal_probe.m）：0 跑完 / 1 wired 回不去已停 / 2 建缓冲或核对失败

// ---------- 第 4 块：程序（gal_prog.m）----------
// 建程序：着色器 SPIR-V + 资源布局 → Metal 函数与参数缓冲布局。运行时按 SPIR-V 内容哈希查离线库，未命中：Mac 现编（SPIRV-Cross），iOS 报红计数
NXGAL_API uint32_t nxgal_prog_create(const nxgal_shader *shaders, int32_t n, const nxgal_res_desc *descs, int32_t ndesc, int32_t frag_output_map);
NXGAL_API int32_t nxgal_prog_status(uint32_t prog, int32_t blocking);   // ProgramLinkStatus：0 Success 1 Failure 2 Incomplete
NXGAL_API void nxgal_prog_release(uint32_t prog);
// 程序二进制（GetBinary / LoadProgramBinary）：内容 = 后端自定义的可重载描述（例如各阶段库哈希 + 资源布局）；out 为空时只返回长度
NXGAL_API int32_t nxgal_prog_binary(uint32_t prog, void *out, int32_t cap);
NXGAL_API uint32_t nxgal_prog_load_binary(const void *data, int32_t len, int32_t has_fragment);
// （第 4 块追加，不改既有签名）
// 翻译口径版本：SPIRV-Cross 选项 / [[id]] 分配规则 / 着色器记录格式任何一项变了就 +1；离线索引与程序二进制都带它，不符即作废
// 13（10-21 画面·着色器线，顶点属性原始位）：顶点输入原始位（Ryujinx 补丁 vattr-raw，成员 s2a_raw<位置> → gal_vpull.m s2a_vr，必须自取）+ 缩放格式描述位 9 + 自取解码拆成按已读原始值解码
// 15（10-22 画面·着色器线 gfxsh/linkxc）：链接版顶上——顶点（自取、不写层号）/ 片元译文末尾追加通用签名函数体 s<键>_lb（原 MSL 一字不改，函数体副本 s<键>_lbi；可见函数里丢弃不生效、隐式细节层固定 0 级：副本里丢弃改置 dc 由片元桩丢弃、采样补显式梯度），
//   记录位 15 GAL_REC_LINKB；片元记录在参数表之后另带 43 字节片元桩种类 gal_lkind（gal_linkstub.m、gal_prog.m rec_write）
// 17：无混合 half 颜色附件在完整版 / 链接桩出口显式 RTZ 量化；片元 buffer(27) 为逐绘制附件位图
// 18（10-24 画面·着色器线 graphics/logicop-emu）：有整数颜色输出的片元末尾追加逻辑运算入口 s<键>_lo（GAL_MSL_LOP 标记之后；帧缓冲读取 [[color(i)]] + 片元 buffer(29) 运算参数），记录位 17 GAL_REC_LOGICOP
// 19（10-24 画幅线 gal/cov-batch3）：顶点自取取数表每项 16 → 24 字节、带从地址起可读字节数，越界属性读 0（图形接口盘点 11，gal_vpull.m）
// 20（10-24 画面·着色器线 graphics/vpull-fast）：顶点自取取数表放 constant 地址空间、4 字节对齐时整字读（Mac 对比测量取数开销省约 26%，帧率能耗线塞尔达顶点占比高）
// 21（10-28 画面线 #807）：翻译后着色器改按 relaxed 数学模式 + preserveInvariance 编译（运行时 gal_msl_opts 与离线 gal_offline.py 同口径），isnan 选择不再被折叠
// 22（10-29 画面线 wire-c/samp-emu2，#800）：边框表项 pad → lb（着色器加的 LOD 偏置），s2a_bsample / s2a_lbsample 带 LOD 偏置模拟（本机 GPU 原生采样器偏置不生效时用）
// 23（10-30 wire-c/rm-gal-linked）：删通用链接版，记录位 15 不再置、片元记录不再带 43 字节桩种类尾
// 24（11-01 #1204 T1，维护者定）：加固的常量 / 存储缓冲越界读不再「读回 0」（值 & 界内掩码），只钳下标（读到钳到的末元素）；越界写 / 原子不落、循环上限不变
// 25（11-23 D-WZCF）：加固后越界的原子返回钳到元素的当前值（原先回 0，读改写重试循环越界时空转不退）
#define NXGAL_XC_VERSION 25u
// 离线索引文件 gal.idx（小端）：u32 魔数 "GALI"(0x494c4147)、u32 版本 1、u32 NXGAL_XC_VERSION、u32 平台（0 iOS 1 macOS）、u32 条数 n、u32 0；
//   n × { u64 键, u32 记录偏移（从文件头起）, u32 记录长 }（按键升序）；之后是着色器记录（格式见 gal_prog.m rec_write）。
// 离线库目录（graphics/metal/tools/gal_offline.py 产出）：gal.idx + gal.shards（每行「首键 16 位十六进制<TAB>文件名」，键升序）+ 各片 gal.<片号>.metallib（每片 ≤64 MB，一段连续键区间）。
// metallib：每支着色器一个函数，名 = "s" + 16 位十六进制键。iOS 启动时开，Mac 可选。0 = 成功
NXGAL_API int32_t nxgal_prog_lib_open(const char *dir);
NXGAL_API void nxgal_prog_xc_stats(uint64_t out[8]);   // 首遇现编：0 异步作业 1 持久缓存命中 2 失败 3 首用时未编完的程序 4 等待总 ms 5 等待最大 ms 6 建程序后 100 ms 内首用 7 异步程序数
NXGAL_API void nxgal_prog_set_xc(int32_t enable);
// 同进程 A/B（GalPlay S2A_GALPLAY_LIBB）：之后新建的程序哈希混入 v（管线缓存按它分开），并清着色器缓存；配合 nxgal_prog_lib_open 换离线库。缺省 0 不变
NXGAL_API void nxgal_prog_set_variant(uint64_t v);       // Mac 运行时现编开关（缺省开；iOS 恒关）。测试用它证明离线 / 二进制路径不靠 SPIRV-Cross
NXGAL_API void nxgal_prog_cache_clear(void);            // 清内存着色器缓存（测试用）
NXGAL_API void nxgal_prog_stats(uint32_t out[6]);       // 0 建成 1 失败 2 离线库命中 3 离线库未命中（iOS 上即红计数）4 运行时现编 5 内存缓存命中
NXGAL_API const char *nxgal_prog_last_error(void);      // 最近一次失败的原因
// 离线工具用（仅 Mac 有实现）：一支 SPIR-V → MSL 源码 + 着色器记录（不需要 nxgal_init）。platform：0 iOS 1 macOS。返回 1 成功；*msl / *rec 由调用方 free
NXGAL_API int32_t nxgal_prog_xc(const void *spv, uint32_t len, int32_t platform, char **msl, void **rec, uint32_t *rec_len, uint64_t *hash);
// platform 参数可或上 NXGAL_XC_VT：把顶点着色器按「曲面细分前的顶点」翻成计算核（键 = SPIR-V 键 ^ NXGAL_VT_SALT，函数名同规则；gal_xc 对 *.vt.spv 文件给这一位）
#define NXGAL_XC_VT 0x100
#define NXGAL_VT_SALT 0x7465737356543031ull
// platform 参数可或上 NXGAL_XC_FBF：片元帧缓冲读取变体（gal_fbr.m 改写过的 SPIR-V，SubpassData 输入附件译成 [[color(n)]]；键 = 改写后 SPIR-V 的键；gal_xc 对 *.fbf.spv 文件给这一位）
#define NXGAL_XC_FBF 0x200
NXGAL_API int32_t nxgal_prog_xc_mt(const void *spv, uint32_t len, int32_t platform, char **msl, void **rec, uint32_t *rec_len, uint64_t *hash, char *err);   // 同上，不取 API 锁（离线并行）
// 读帧缓冲证明出包（10-22，gal_fbr.m；gal_xc --fbr 用，不需要 nxgal_init、不取 API 锁，各句柄可在不同线程上用）：
//   prove_spv：（顶点, 片元）SPIR-V 证明，NULL = 证不出；rewrite_spv：按映射（n 个 绑定 → 颜色槽，ydown）改写片元，malloc 的新 SPIR-V（*len 字节），NULL = 映射不在证明里 / 改写失败；
//   add_variant：变体表记一条（映射 → 变体片元键）；trailer：程序二进制尾段字节（out 为空只算长度，格式见 gal_fbr.m）；release：释放句柄
NXGAL_API void *nxgal_fbr_prove_spv(const void *vs, uint32_t vlen, const void *fs, uint32_t flen);
NXGAL_API void *nxgal_fbr_rewrite_spv(void *fbr, int32_t n, int32_t ydown, const uint8_t *bind, const uint8_t *slot, uint32_t *len);
NXGAL_API int32_t nxgal_fbr_add_variant(void *fbr, int32_t n, int32_t ydown, const uint8_t *bind, const uint8_t *slot, uint64_t fs_key);
NXGAL_API int32_t nxgal_fbr_trailer(const void *fbr, void *out);
NXGAL_API void nxgal_fbr_release(void *fbr);

// ---------- 第 5 块：管线状态（gal_state.m）----------
NXGAL_API void nxgal_set_program(uint32_t prog);
NXGAL_API void nxgal_set_blend(int32_t index, const nxgal_blend *b);
NXGAL_API void nxgal_set_blend_advanced(int32_t op, int32_t overlap, int32_t src_premul);   // 第 8 块（先报红）
NXGAL_API void nxgal_set_color_masks(const uint32_t *masks, int32_t n);
NXGAL_API void nxgal_set_depth_bias(int32_t enables, float factor, float units, float clamp);
NXGAL_API void nxgal_set_depth_clamp(int32_t clamp);
NXGAL_API void nxgal_set_depth_mode(int32_t mode);
NXGAL_API void nxgal_set_depth_test(const nxgal_depth_test *d);
NXGAL_API void nxgal_set_stencil_test(const nxgal_stencil *s);
NXGAL_API void nxgal_set_face_culling(int32_t enable, int32_t face);
NXGAL_API void nxgal_set_front_face(int32_t front_face);
NXGAL_API void nxgal_set_line_params(float width, int32_t smooth);
NXGAL_API void nxgal_set_point_params(float size, int32_t program_size, int32_t sprite, int32_t origin);
NXGAL_API void nxgal_set_logic_op(int32_t enable, int32_t op);
NXGAL_API void nxgal_set_multisample(int32_t alpha_to_coverage, int32_t a2c_dither, int32_t alpha_to_one);
// 曲面细分计数（gal_tess.m）：0 曲面绘制数 1 曲面片数 2 为此结束渲染通道的次数 3 跳过的曲面绘制 4 超容量丢弃的曲面片（GPU 计）5 展开出的索引数累计（GPU 计）
NXGAL_API void nxgal_tess_stats(uint64_t out[6]);
NXGAL_API void nxgal_set_patch_params(int32_t vertices, const float outer[4], const float inner[2]);
NXGAL_API void nxgal_set_polygon_mode(int32_t front, int32_t back);
NXGAL_API void nxgal_set_primitive_restart(int32_t enable, int32_t index);
NXGAL_API void nxgal_set_topology(int32_t topology);
NXGAL_API void nxgal_set_rasterizer_discard(int32_t discard);
NXGAL_API void nxgal_set_user_clip(int32_t index, int32_t enable);
NXGAL_API void nxgal_set_viewports(const nxgal_viewport *v, int32_t n);
NXGAL_API void nxgal_set_vertex_attribs(const nxgal_vattr *a, int32_t n);
NXGAL_API void nxgal_set_vertex_buffers(const nxgal_vbuf *b, int32_t n);
NXGAL_API void nxgal_set_index_buffer(const nxgal_buf_range *r, int32_t type);
NXGAL_API void nxgal_set_alpha_test(int32_t enable, float ref, int32_t op);
// 资源绑定（stage = ShaderStage）
NXGAL_API void nxgal_set_uniform_buffers(const nxgal_buf_assign *a, int32_t n);
NXGAL_API void nxgal_set_storage_buffers(const nxgal_buf_assign *a, int32_t n);
NXGAL_API void nxgal_set_texture_sampler(int32_t stage, int32_t binding, uint32_t tex, uint32_t smp);
NXGAL_API void nxgal_set_image(int32_t stage, int32_t binding, uint32_t tex);
NXGAL_API void nxgal_set_texture_array(int32_t stage, int32_t binding, uint32_t arr);       // 也用于图像数组
NXGAL_API void nxgal_set_texture_array_separate(int32_t stage, int32_t set, uint32_t arr);
NXGAL_API void nxgal_set_transform_feedback_buffers(const nxgal_buf_range *r, int32_t n);   // 第 8 块（先报红）

// ---------- 第 6 块：绘制与派发（gal_draw.m）----------
NXGAL_API void nxgal_draw(int32_t vertex_count, int32_t instance_count, int32_t first_vertex, int32_t first_instance);
NXGAL_API void nxgal_draw_indexed(int32_t index_count, int32_t instance_count, int32_t first_index, int32_t first_vertex, int32_t first_instance);
NXGAL_API void nxgal_draw_indirect(const nxgal_buf_range *ind, int32_t indexed);
NXGAL_API void nxgal_draw_indirect_count(const nxgal_buf_range *ind, const nxgal_buf_range *param, int32_t max_draws, int32_t stride, int32_t indexed);
NXGAL_API void nxgal_draw_texture(uint32_t tex, uint32_t smp, const float src[4], const float dst[4]);   // Extents2DF x1 y1 x2 y2
NXGAL_API void nxgal_dispatch(int32_t x, int32_t y, int32_t z);
NXGAL_API void nxgal_begin_transform_feedback(int32_t topology);   // 第 8 块（先报红）
NXGAL_API void nxgal_end_transform_feedback(void);

// ---------- 计数与条件渲染（gal_cnt.m）----------
// ReportCounter：返回事件编号；结果由 nxgal_counter_poll 取（C# 端在 UpdateCounters / Flush 时调用并回调 resultHandler）
NXGAL_API uint32_t nxgal_counter_report(int32_t type, float divisor, int32_t host_reserved);
NXGAL_API void nxgal_counter_reset(int32_t type);
NXGAL_API void nxgal_counter_flush(uint32_t ev);               // 让该事件尽快出结果（提交）并等它完成
NXGAL_API void nxgal_counter_release(uint32_t ev);
// 取已出结果的事件：写 ids / values，返回条数（≤ max）
NXGAL_API int32_t nxgal_counter_poll(uint32_t *ids, uint64_t *values, int32_t max);
// 计数线程用：叫醒等待者；等到可能有新结果（队头 GPU 做完 / 提交 / 叫醒；等 GPU 最多 timeout_ms）。返回 0 = 原先没有在途
NXGAL_API void nxgal_counter_kick(void);
NXGAL_API int32_t nxgal_counter_wait(int32_t timeout_ms);
NXGAL_API void nxgal_pre_frame(void);
// 条件渲染：Metal 无硬件谓词——返回 0 让 Gpu 层走 CPU 侧判定（同 Vulkan 不支持时的路径）；实现可在结果已出时返回 1 并按结果跳过
NXGAL_API int32_t nxgal_cond_begin(uint32_t ev, uint64_t compare, uint32_t ev2, int32_t is_equal);
NXGAL_API void nxgal_cond_end(void);

// ---------- 第 7 块：出图（gal_present.m）----------
NXGAL_API void nxgal_window_set_layer(void *ca_metal_layer);   // 宿主给 CAMetalLayer（Mac 窗口 / iOS 视图）；为空 = 无窗口（只计数，测试用）
NXGAL_API int32_t nxgal_window_attach_ios(void);   // iOS：建 CAMetalLayer 挂到 App 壳根视图（s2a_ios_root_view）并设为出图层；Mac 返回 -1
NXGAL_API void nxgal_window_attach_failed_ios(void);   // 挂接失败：通知 iOS 壳暂停游戏、显示错误并保留诊断；Mac 无操作
NXGAL_API void nxgal_present(uint32_t tex, const nxgal_crop *crop);
// 本线程自动释放池轮换（帧率能耗线 10-24）：弹出本线程上次推入的池、再推一个。C# 线程没有释放池，GAL 入口里自动释放的对象原先永不放掉；
//   Metal 编码线程在 nxgal_present 开头轮换（每帧一次），GPU 模拟线程由渲染循环每轮调。只能在任何 @autoreleasepool 之外调；主线程上不做事
NXGAL_API void nxgal_pool_cycle(void);
NXGAL_API void nxgal_window_set_size(int32_t w, int32_t h);
NXGAL_API void nxgal_window_set_vsync(int32_t mode);           // VSyncMode
NXGAL_API void nxgal_window_set_scaling(int32_t filter, float level);
NXGAL_API void nxgal_window_set_antialiasing(int32_t mode);   // GAL AntiAliasing：None 0 / SMAA Low..Ultra 2..5；1（Ryujinx 的 Fxaa）按 SMAA Medium（不带 FXAA）；初始化前可设
NXGAL_API int32_t nxgal_screenshot(void *out, int32_t cap, int32_t *w, int32_t *h);   // 最近一次出图的 BGRA8 像素
NXGAL_API int32_t nxgal_screenshot_processed(void *out, int32_t cap, int32_t *w, int32_t *h);   // 同原始截图口径，额外包含本帧 AA；缩放前
NXGAL_API void nxgal_present_pillar(int32_t on);   // 宽屏包装层（画幅线）每次上屏前告知：本帧是「16:9 原比例页」（纯 CPU 供图的整画布 16:9 图片，没有更宽内容可补，按原比例居中留黑边）= 1；两侧本帧被放宽内容画过（黑是游戏画的）= 2；0 = 照常判；满屏内容判据见 gal_present.m
// 第 7 块追加（只增函数，已有签名不变）：
//   截图口径 = 裁切 + 翻转后、窗口缩放前（同 Ryujinx Window.CaptureFrame 的区域，翻转已做好），行紧排，alpha = 255；任意线程可调
NXGAL_API void nxgal_window_set_min_interval(float seconds);   // 每张至少显示多久（iOS 30 帧档 = 1/30）；0 = 不限
NXGAL_API void nxgal_window_stats(uint64_t out[4]);            // [0] 出图次数 [1] 上屏次数 [2] 信箱里被新帧顶掉 [3] 取不到 drawable
NXGAL_API int32_t nxgal_window_render_to(uint32_t dst_tex);    // 最近一帧按当前窗口设置画进 GAL 贴图（= 上屏同一段编码）；诊断 / 单测用，Gpu 线程调

// 性能计数：out[2k] = 第 k 段 CPU 纳秒（只在 NXGAL_PERF_TIME=1 时计，缺省 0：计时本身占渲染线程约一成），out[2k+1] = 次数（k：0 绘制总 1 取管线 2 建管线 3 绑资源 4 动态状态 5 上传 6 清屏 7 提交 8 等 GPU 9 等首遇现编 10 出图 11 拷贝 12 开渲染编码器 13 开计算 / 拷贝编码器 14 缓冲写走预载 15 缓冲写走在录命令流（切通道）16 参数缓冲按集复用 17 缓冲写走镜像 18 绑定用到镜像 19 索引地址未对齐改用对齐的 32 位索引，12–19 只计次数）；
// 返回段数 N（以后加段只往后加）；out[2N] = GPU 纳秒（已完成的提交 GPUEnd-GPUStart 之和），out[2N+1] = 已完成提交数——调用方按返回值取，别写死下标。reset 非 0 读后清零。n 为 out 长度（≥ 2N+2 才回填 GPU 两项）
NXGAL_API int32_t nxgal_perf_read(uint64_t *out, int32_t n, int32_t reset);
NXGAL_API void nxgal_frame_totals(uint64_t out[6]);
NXGAL_API uint64_t nxgal_display_interval_us(void);   // 最近两次画面真正上屏的间隔（微秒，presentedTime 差；0 = 还没有 / 无显示层）
NXGAL_API int32_t nxgal_thread_start(void (*fn)(void *), void *arg, int32_t qos, const char *name);   // 按 QoS（qos_class_t 原值）起原生线程跑 fn(arg)（托管 UnmanagedCallersOnly 入口）；0 成功
NXGAL_API int32_t nxgal_thread_start_joinable(void (*fn)(void *), void *arg, int32_t qos, const char *name, uintptr_t *thread);
NXGAL_API int32_t nxgal_thread_join(uintptr_t thread);   // 0 = pthread_join / TLS 析构完成；失败保留句柄与资源
NXGAL_API int32_t nxgal_bounds_report(void);   // 越界 / 循环到上限计数收尾报数（计数缺省关，NXGAL_BOUNDS_COUNT=1 开；开着的局画面不代表 iPhone，只读计数）：有计数的着色器逐个报【红】，返回有计数的着色器数；没开返回 0   // 逐帧累计（常开、不清零）：0 绘制 1 渲染遍 2 上传 3 附件读写字节 4 CPU 等 GPU 纳秒
// 最近一个 GPU 已做完的帧（以出图为帧界）的 GPU 耗时（毫秒）：该帧全部命令缓冲 GPUEnd-GPUStart 之和；*frame 回填其帧号（第几次出图，从 1 起），尚无则返回 0、帧号 0
NXGAL_API double nxgal_last_gpu_ms(uint64_t *frame);
NXGAL_API int32_t nxgal_perf_hook_mtl3(void);
NXGAL_API int32_t nxgal_perf_passes(uint64_t *out, int32_t max, int32_t reset);   // 诊断 NXGAL_PERF_PASSCOMMIT=1：每遍（命令缓冲）一条 8 个 u64：宽 高 GAL 格式 绘制数 类别（1 渲染 2 拷贝计算）GPU 纳秒 附件读入字节 附件存回字节   // 测量用：本进程 Metal 3 命令缓冲（如 MoltenVK）的 GPU 时间也累计进 nxgal_perf_read 的 GPU 计数

// 诊断 NXGAL_PSTAT=1（缺省关，关时立即返回）：游戏提交的一个 GPFIFO 命令段在 CPU 侧的 n 对（地址, 长度）连续片，total = 段字节；n < 0 = 段没法统计（只计数）。
// 任意线程可调（自带锁）；统计口径与汇总行见 gal_pstat.m
NXGAL_API void nxgal_pstat_seg(const uint64_t *ranges, int32_t n, uint64_t total);
#ifdef __cplusplus
}
#endif
