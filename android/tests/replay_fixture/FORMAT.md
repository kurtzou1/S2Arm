# S2RF 回放夹具格式（FORMAT v1）

`*.in.rfx` 与 `*.exp.rfx` 的字节级规范。实现：`rfx.c`（写 / 读 / 比对）；权威 ID 表：`rfx.h`。
本文件是「两份实现各自按规范解析必须得到同一比特」的契约，不是某一方的内部表示。

## 1. 容器

- 全文件小端；无对齐填充（记录可起于任意字节偏移）。
- 文件头 16 字节：

  | 偏移 | 类型 | 值 |
  |---|---|---|
  | 0 | u32 | `RFX_MAGIC` = `0x31465852`（`"RFX1"`） |
  | 4 | u32 | `RFX_VERSION` = 1 |
  | 8 | u32 | kind：`1` = 输入（IN），`2` = 期望（EXP） |
  | 12 | u32 | 保留，恒 0 |

- 文件体 = 记录序列，逐条为 `{u32 tag, u32 len, u8 payload[len]}`，以 `tag = 3`（END）结束。
- 解析器必须拒绝：坏 magic / 版本 / kind、len 越过文件尾、缺 END、END 后有字节、记录号与文件 kind 不相容（见 §2 表）。

## 2. 记录族

| tag | 名 | 出现于 | payload |
|---|---|---|---|
| 1 | REGION | IN | `{u64 addr, u64 len, u64 prot}` —— guest 内存段声明；语义与 `nvn_frame_rec.inc` 的 FR_REC_REGION 相同，`prot` 位同 mprotect（样例用 3 = R\|W） |
| 2 | DATA | IN | `{u64 addr, u64 len, u8 bytes[len]}` —— 段内初始内容；同 FR_REC_DATA |
| 3 | END | IN/EXP | 空 |
| 4 | RES | IN | `{u32 rkind, u16 name_len, u8 name[..], 负载按 rkind}` —— 命名资源，见 §3 |
| 5 | CALL | IN | `{u32 func, u64 ret, 负载按 func}` —— 上沿 `nvn_be_*` 调用，func 表见 `rfx.h` `RFX_BE_*` |
| 6 | EXP | EXP | `{u32 func, 负载按 func}` —— 期望的下沿 `nvn_gpu_*` 调用，func 表见 `rfx.h` `RFX_GPU_*` |
| 7 | CHK | EXP | `{u32 ckind, 负载按 ckind}` —— 检查点，见 §8 |
| 8 | ASSUME | EXP | 能力档，见 §6.1；必须是期望文件的第一条记录 |

IN 文件允许的记录：REGION、DATA、RES、CALL、END。
EXP 文件允许的记录：ASSUME、EXP、CHK、END。

文件内次序（生成器约定，解析器不强制）：IN 为 REGION* → DATA* → RES* → CALL* → END；
EXP 为 ASSUME → （EXP/CHK 按流序交错）→ END。

## 3. RES（rkind）

| rkind | 名 | payload |
|---|---|---|
| 1 | PROG | `{u64 serial, u8 keys[6][8], u8 kok, u8 stage_of[6]}` —— 程序快照：serial 是前端 `nvn_new_serial()` 的单调号（样例按 tex_init 序 1,2,3…）；keys 按 prog_t.sd 槽位给着色器产物键；`stage_of[i]` 把槽位映到阶段（0=VS 1=FS 5=CS，0xff=空），`kok` 为阶段掩码 |
| 2 | SHADER | `{u8 stage, u8 key[8], u8 blob_kind, u16 entry_len, u8 entry[..], u32 nent, u32 push_off, u32 push_bytes, u32 support_bytes, u8 id[16], u16 idsrc_len, u8 idsrc[..], ent[nent], u64 blob_len, u8 blob[..]}` —— 着色器产物；`ent` 每项 16B：`{u8 set, cls, access, src_kind; u16 binding, src_reg, count, aid; u32 stages}`；blob 是编译产物本体（样例用确定占位字节，见 §7） |
| 3 | SURFACE | `{u32 w, u32 h, u32 nvn_format, u32 nimg}` —— 假窗口面 |

RES 是「调用开始之前世界已经有的东西」：程序快照、着色器产物、窗口。回放器先按 RES
重建这些对象，再按序回放 CALL。

## 4. 规范化编码（核心：让「两次实现各自的合法选择」可比）

下沿调用里凡是实现可以自由选值的量，一律换成规范化形式再进 EXP：

| 原始量 | 规范化 |
|---|---|
| 后端返回的句柄（buf/tex/view/samp/shader/pipe/cpipe/cmd/surface） | `hid`：u32，从 1 起、按**首次出现序**编号；0 保留 = 无 |
| guest 指针 / 地址 | 输入侧保留原值（DATA 覆盖范围内）；期望侧一律不出现 guest 地址，改为 `hid + 偏移` |
| 块数据内容（缓冲写、贴图上传、着色器 blob） | `len + CRC32(IEEE)`，不逐字节嵌进 EXP（CHK_BUF 例外，见 §8） |
| 返回值 | `i32 rc`：`0` = OK；负数用 `nvn_gpu_rc` 原值（错误域 [-1099,-1000]） |
| 时刻 / 时间戳 | `at = 0`、`time_kind = 0`（TIME_NONE）；presented 用 `status` 枚举 |
| 枚举 / 位掩码 | 用 `nvn_backend.h` / `nvn_refl.h` 原值，不做后端私有重映射 |
| 可选字段 | 1B `has_` 标志 + 定长体（缺省全 0） |

以下各小节给出 EXP 复合载荷的字段序（与 `rfx.h` 注释一一对应）。

### 4.1 句柄钉法

`hid` 单一序号空间：surface、cmd、buf、tex、view、samp、shader、pipe、cpipe 全部从同一个
计数器按首次出现分配（有窗口的样例 `surface=1` 先占、`cmd=2`；无窗口的 `cmd=1`）。
期望流里句柄间的相等 / 不等关系就是全部信息：两处引用同一个 hid ⇔ 期望同一对象。

### 4.2 view16（`reg_tex` / `view_create` 的视图块）

16B：`view_t` 前 14B 原样 + 末 2B 恒 0（`_rsv` 归一）。`has_view = 0` 时整段 16B 恒 0。

### 4.3 nvn_gpu_tex_desc（`tex_create`）

`nvn_gpu_tex_desc` 原样（`nvn_backend.h`）＝`nvn_texdesc d`（40B）+ `{u32 usage,
u32 host_w, u32 host_h, u16 swz, u8 rsv[2]}`，再跟 `{i32 rc, u32 hid}`。
usage 取 `NVN_GPU_TEX_*` 位（RENDER / SAMPLED / CPU_UPLOAD …）；swz 恒等写 0；
host_w/host_h = 0 表示同 d；`rsv[2]` 恒 0（归一，与 §4.2 的 `_rsv` 同一做法；这两字节原先是
`u8 stencil_view, u8 rsv`，模板模式改为只由视图记录表达后 `stencil_view` 不再有写入方，字节位置保留以免动已提交的金样）。

### 4.4 layout（`shader_load` / RES SHADER）

`{u32 nent, u32 push_off, u32 push_bytes, u32 support_bytes, u8 id[16], u16 idsrc_len,
u8 idsrc[..], ent[nent]}`；`ent` 编码同 §3 rkind=2。src_reg 用 `NVN_RB_*` 原值。

### 4.5 pipe_desc / stage_desc（`pipe_get` / `cpipe_get`）

`pipe_desc`：5 个阶段槽按 `st[5]`（VS FS GS TCS TES）序各写 `{u32 sh, u32 nspec,
nvn_gpu_spec spec[nspec]}`（spec 每项 8B：`{u16 id, u8 type, u8 rsv, u32 bits}`；
样例全部 nspec=0，故每槽 8B）→
`u32 cfmt[8]` → `{u32 dfmt, u32 sfmt}` → `u32 samples` → `u8 layer_map[8]` →
`{u32 prim, u32 patch_size, u8 prim_restart, u8 rsv[3]}` → `blend_st×8` → `color_st` →
`chmask_st` → `ms_st(10B)+rsv16` → `u32 vattr[16]` → `vs_st×16` → `ds_st` → `poly_st` →
`{u8 rast_discard, u8 clip_neg1, u8 rsv[2]}` → `u8 mode`（0=SYNC）→ `{i32 rc, u32 hid}`。
`*_st` 均为 `nvn_obj.h` 的原始定长结构，原样嵌入（这些已是契约可见值）。

`stage_desc`（cpipe）：`{u32 sh, u32 nspec, nvn_gpu_spec spec[nspec]}` → `u8 mode` → `{i32 rc, u32 hid}`。

### 4.6 pass_desc（`pass_begin`）

`{u32 cmd, u32 ncolor}` → 8 个颜色附件槽 × `{u32 view, u32 resolve, u8 load, u8 store,
u8 rsv[2], f32 clear[4]}` → 深度附件槽（同构）→ 模板附件槽（同构）→
`{f32 clear_depth, u32 clear_stencil}` → `{u32 w, u32 h, u32 layers}` →
`{u8 occlusion, u8 fb_fetch, u8 rsv[2]}`。不用的槽整段 0；load/store 用 `NVN_GPU_LOAD_*` 原值。

### 4.7 dyn（`set_dyn`）

`{u32 nvp, f32 vp[16][6], u8 vp_sw[64], i32 scissor[4], u8 has_sc, u8 origin_ll,
u8 depth_clamp, u8 rsv, f32 poly_offset[3], u32 st_vmask[2], u32 st_wmask[2],
u32 st_ref[2], f32 blend_color[4], ds_st, poly_st}`。

### 4.8 bind ent（`bind`）

`{u32 cmd, u8 stage, u32 n, ent[n]}`；每项头 `{u16 ent, u8 res, u8 rsv, u32 elem}` +
按 `res`（`NVN_GPU_RES_*`，与 `nvn_gpu_binding.u` 的成员对应）的定长体：

| res | u 成员 | 序列化 |
|---|---|---|
| UBO / SSBO / TBUF / IMAGE_TBUF | `u.b` | `{u32 buf, u64 off, u64 len}` |
| TEX / IMAGE | `u.view` | `{u32 view}` |
| SAMP | `u.samp` | `{u32 samp}` |
| TEX_SAMP | `u.ts` | `{u32 view, u32 samp}` |
| VA | `u.va` | `{u64 va}` |

### 4.9 draw_args（`draw`）

`{u32 cmd, u32 prim, u32 count, u32 first, u32 inst, u32 base_instance, u32 ibuf,
u64 ioff, u32 itype, i32 base_vertex, u32 ind, u64 ind_off, u32 cnt, u64 cnt_off,
u32 max_draws, u32 stride}`；不用的间接 / 索引 / base_instance 字段全 0。

## 5. EXP 函数表

`RFX_GPU_*` 枚举（`rfx.h`）即函数 ID 与载荷签名表。覆盖契约 `nvn_gpu_*` 全集里会进
记录流的函数：设备 open/close、缓冲 wrap/create/release/use/write/arena_alloc、贴图
create/release/upload、视图 / 采样器、shader_load/release、pipe_get/cpipe_get、
cmd_begin/abort/commit、pass_begin/end、set_pipe/set_dyn/set_vbuf、bind/push、
draw/dispatch、copy_*、blit、clear_view、barrier、occlusion、label、fence_wait、
surface_attach/rebuild/detach、drawable_acquire/release、present。

不入流的纯查询（`caps_get`、`format_caps`、`buf_va`、`buf_cpu`、`tex_info_get`、
`surface_gen`、`fence_done`、`fence_failed`、`stats`）不写 EXP：它们的可观测效果由
CHK（栅栏读数 / 缓冲内容 / 回调）或 §6 钉法覆盖。

## 6. 钉法（样例期望所依赖的确定性约定）

期望流要独立于被测实现，就必须把契约里「允许多种合法实现」的点钉死。生成器统一用：

### 6.1 ASSUME（能力档）

样例全用 REF 档：`{api=10, api_version=0x00401000, family=0, vendor=0, device=0,
caps=NVN_GPU_CAP_HOST_IMPORT(1), color_att=8, vstreams=16, tex_dim=16384, samples=4,
viewports=16, max_push_bytes=4096, min_ubo=16, ssbo_align=16, max_ubo=65536,
ssbo_range=1<<27, max_buf_bytes=1<<30, max_stage_res[10]=32, max_sets=4,
storage_stages=0x3f, atomic_stages=0, display_max_hz=60}`。期望是在「该档能力下契约
要求的行为」；只置 HOST_IMPORT（Metal 抽离线的主靶——池页零拷贝包装），其余位全
0：无 GPL 链接管线、无动态 ds / 光栅状态、无上屏时刻、无 GPU 解排布、无间接计数
（对应 §8 C19/C20/C14 的保守侧与 §7 的 Metal 现行口径）。

### 6.2 资源钉法

- `nvn_be_pool_add` → `buf_wrap(addr, bytes)` → `rc=OK, hid`：**在 pool_add 的流位置
  同步包装**（CAP_HOST_IMPORT 的零拷贝路，Metal `newBufferWithBytesNoCopy` 的对应）；
  之后池内一切引用 = `hid + 池内偏移`（顶点流、SSBO、上传源的 guest 地址一律换成它）。
  无 HOST_IMPORT 档的 fallback（wrap→E_UNSUPPORTED→create+脏页 buf_write）属另一能力
  档的差分期望，样例不占。
- `tex_create` / `view_create` / `samp_create` 在**首次被流引用**时入流（tex_init 只
  把 serial 记 live，usage 此时尚不可知——Metal 现行即懒建）。
- 通道外序：tex/view/samp/shader/pipe/upload 全部排在 `pass_begin` 之前（§8 C23 的
  「通道内禁止」侧不踩）。
- `sub_commit` 的 `signal` = 提交序号（1,2,3… 单调），`fence_wait` 与 CHK 栅栏值随之。

## 7. 样例统一取值

- 窗口 / 帧缓冲：W=H=256，`FMT_RGBA8=0x25`，深度 `FMT_D32=0x34`，交换链 3 图。
- 顶点数据：单三角形 `{0,0.5} {-0.5,-0.5} {0.5,-0.5}`（s03 用覆盖屏的退化三点），
  stream0 顶点态 `{size=12, stride=0}`，vattr 掩码 `0x2E`。
- `states`：`blend{target0, src1/dst0, eq ADD}`、`color{blend_en0, alpha_func7}`、
  `chmask 0xffffffff`、`ms{samples1}`、`poly{cull0,front0,mode0,offset0}`、
  `ds`：关 `{dt0,dw1,df7(ALWAYS)}` / 开 `{dt1,dw1,df3(LEQUAL)}`。
- 采样器：SAMP_LINEAR `{minf=magf=LINEAR, ws=wt=wr=REPEAT, lod 0..12}`。
- 着色器 blob：16B 占位 `"S2RF-SPV-vs1"` / `"-fs1"` / `"-fs2"` / `"-cs1"`，
  键 `"RFX_VS01"`/`"RFX_FS01"`/`"RFX_FS02"`/`"RFX_CS01"`。blob 内容对契约无意义，
  只要求确定、可辨识、与任何真实游戏无关。

## 8. CHK（检查点；比对器不消费，由回放执行器核）

| ckind | 名 | payload | 语义 |
|---|---|---|---|
| 1 | FENCE_DONE | `{u64 v}` | 此时 `fence_done()` 应报 v |
| 2 | FENCE_FAILED | `{u64 v}` | `fence_failed()` 应报 v |
| 3 | DONE | `{u64 signal, u8 status, i32 rc, u8 time_kind}` | 该段 done 回调恰一次：status / rc / 时间域 |
| 4 | BUF | `{u32 hid, u64 off, u64 len, u8 bytes[len]}` | 执行后该缓冲段内容逐字节等于 bytes |
| 5 | PRESENTED | `{u64 ticket, u32 status, f64 at}` | presented 回调：status（SHOWN_UNKNOWN=2…）、at 归一 |
| 6 | RETIRED | `{u32 hid}` | retired 回调（次序敏感：在对应 done 之后） |
| 7 | ERROR | `{i32 code, u16 entry_len, u8 entry[..], u32 count}` | 粘滞错误面：code / 入口名 / 计数 |

CHK 不进 `rfx_cmp` 的比对序列（§9）：它是「执行器必须兑现的断言」，不是记录器输出。

## 9. 比对（rfx_cmp）

- 取期望文件的 ASSUME + EXP 记录序列与实际文件同序列逐字节比（ASSUME 也入比对——
  实际文件的记录器也应写出自己声明的能力档，第一处就是能力差异）。
- `funcs` 过滤非空时只配对 func 在表内的 EXP（各自保序），用于按函数族切片回归。
- 第一处差异即返回：`rfx_diff{index, tag, id, file_off, act_off, exp_b, act_b, msg}`，
  msg 带记录序号、函数名、两侧文件偏移与字节值；一侧先完报 `exp_b/act_b = -1`。
- 0 容差：规范化做对的两份实现必须逐字节一致；差一字节即红。
