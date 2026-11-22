// Shader reflection json (B: produced by translating the original Switch shaders, output of tools/dmsh_build.py) → fixed-length C arrays (nvn_refl.h)
#import "nvn_refl.h"
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>

// Dummy texture type: same prefix rules as the original dummy_tex (an unbound texture slot reads 0 per D3D semantics)
static void dummy_kind(NSString *t, uint8_t *tt, uint8_t *pf) {
    MTLTextureType y = MTLTextureType2D;
    // Multisample first (texture2d_ms_array also starts with texture2d_): without them a multisample declaration read as 2D, and since bound as is was removed (10-26) a real
    //   multisample texture in its own slot was taken for a mismatch and read 0 (Octopath Traveler II: 24 shaders declare texture2d_ms; PR #490 found the gap)
    if ([t hasPrefix:@"texture2d_ms_array"] || [t hasPrefix:@"depth2d_ms_array"]) y = MTLTextureType2DMultisampleArray;
    else if ([t hasPrefix:@"texture2d_ms"] || [t hasPrefix:@"depth2d_ms"]) y = MTLTextureType2DMultisample;
    else if ([t hasPrefix:@"texture_buffer"]) y = MTLTextureTypeTextureBuffer;
    else if ([t hasPrefix:@"texture2d_array"] || [t hasPrefix:@"depth2d_array"]) y = MTLTextureType2DArray;
    else if ([t hasPrefix:@"texturecube_array"] || [t hasPrefix:@"depthcube_array"]) y = MTLTextureTypeCubeArray;
    else if ([t hasPrefix:@"texturecube"] || [t hasPrefix:@"depthcube"]) y = MTLTextureTypeCube;
    else if ([t hasPrefix:@"texture3d"]) y = MTLTextureType3D;
    else if ([t hasPrefix:@"texture1d_array"]) y = MTLTextureType1DArray;
    else if ([t hasPrefix:@"texture1d"]) y = MTLTextureType1D;
    *tt = (uint8_t)y;
    *pf = [t hasPrefix:@"depth"] ? NVN_DPF_DEPTH : [t containsString:@"<uint"] ? NVN_DPF_UINT : [t containsString:@"<int"] ? NVN_DPF_SINT : NVN_DPF_FLOAT;
}

// array<element, n> → n and the element type (0 and the type itself for anything else)
static int arr_len(NSString *ty, NSString **el) {
    *el = ty;
    if (![ty isKindOfClass:[NSString class]] || ![ty hasPrefix:@"array<"] || ![ty hasSuffix:@">"]) return 0;
    NSRange c = [ty rangeOfString:@", " options:NSBackwardsSearch];
    if (c.location == NSNotFound) return 0;
    *el = [ty substringWithRange:NSMakeRange(6, c.location - 6)];
    return [[ty substringWithRange:NSMakeRange(NSMaxRange(c), ty.length - 1 - NSMaxRange(c))] intValue];
}

// Whether a storage buffer binding may be written: "rw" says so, or SPIRV-Cross typed it without const (it types a buffer the shader never writes const device). Route B's
//   "rw" was false for every storage buffer until 10-27 (dmsh_build.py tested BufferUsageFlags bit 1, Write is bit 0): Xenoblade 3's skinning vertex shaders, which write theirs,
//   read as writing nothing, and their discarded draws were dropped (sx_draw); a package built before still carries that "rw", so a non-const type counts on its own
static int sbuf_rw(NSDictionary *b) { id rw = b[@"rw"], ty = b[@"msl_type"]; return (rw && [rw boolValue]) || ([ty isKindOfClass:[NSString class]] && ![ty hasPrefix:@"const "]) || (!rw && ![ty isKindOfClass:[NSString class]]); }
// The other half of a single handle read from uniform buffers (nvn_refl.h pair), from the binding's name as Ryujinx's TextureHandle packs it (the translator's Dsh.cs DecodeUboTex reads
//   the same name): <stage>_<t|i>…_cb<slots>_<HEX>, slots = texture buffer | (sampler buffer + 1) << 16, HEX = texture word | sampler word << 14 | type << 28 (word offsets; buffers
//   c3..c16 = uniform slots 0..13). Types 1 (SeparateSamplerHandle) and 2 (SeparateSamplerId, the sampler word shifted by 20) read a second word, which Ryujinx ReadPackedId ORs in
//   whatever the binding is. The binding's own half (reg / off from the build) must match the name's, or nothing is paired (read as before)
static void pair_from_name(NSString *nm, nvn_rbind *r) {
    if (![nm isKindOfClass:[NSString class]] || r->n) return;
    if ([nm hasSuffix:@"Smplr"]) nm = [nm substringToIndex:nm.length - 5];
    static NSRegularExpression *re; static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"^[a-z]+_[ti]\\w*?_cb(\\d+)_([0-9A-F]+)" options:0 error:NULL]; });
    NSTextCheckingResult *m = [re firstMatchInString:nm options:0 range:NSMakeRange(0, nm.length)];
    if (!m) return;
    long long slots = [[nm substringWithRange:[m rangeAtIndex:1]] longLongValue]; unsigned long long h = strtoull([nm substringWithRange:[m rangeAtIndex:2]].UTF8String, NULL, 16);
    long tb = (long)(slots & 0xffff), sb = (slots >> 16) ? (long)(slots >> 16) - 1 : tb, o0 = (long)(h & 0x3fff) * 4, o1 = (long)((h >> 14) & 0x3fff) * 4, ty = (long)(h >> 28);
    if ((ty != 1 && ty != 2) || tb < 3 || tb > 16 || sb < 3 || sb > 16) return;
    if (r->kind == NVN_RB_SAMPU) { if (r->reg != sb - 3 || r->off != o1) return; r->pair_reg = (uint16_t)(tb - 3); r->pair_off = (uint16_t)o0; r->pair_sid = 0; }
    else { if (r->reg != tb - 3 || r->off != o0) return; r->pair_reg = (uint16_t)(sb - 3); r->pair_off = (uint16_t)o1; r->pair_sid = ty == 2; }
    r->pair = 1;
}
int nvn_refl_from_json(NSDictionary *j, nvn_refl *o, char *err, int errlen) {
    memset(o, 0, sizeof *o); if (errlen > 0) err[0] = 0;   // success leaves err empty, or a note (drv_unfilled)
    #define FAIL(...) do { free(o->c1); o->c1 = NULL; free(o->b); o->b = NULL; snprintf(err, errlen, __VA_ARGS__); return 1; } while (0)
    if (![j[@"route"] isEqual:@"B"]) FAIL("not a B reflection (route ≠ B; route A / PC-chain reflection is retired)");
    {   // Translated original Switch shaders: kind and NVN slot number are already parsed from the MSL member names by dmsh_build.py
        NSArray *bs = j[@"bindings"];
        if (![bs isKindOfClass:[NSArray class]]) FAIL("missing bindings");
        if (bs.count > NVN_REFL_MAXARG) FAIL("%lu bindings, over the argument buffer limit %d", (unsigned long)bs.count, NVN_REFL_MAXARG);   // each binding takes at least one entry
        if (!(o->b = calloc(bs.count ? bs.count : 1, sizeof *o->b))) FAIL("allocation of %lu bindings failed", (unsigned long)bs.count);
        o->route_b = 1; o->abi = 0;   // spirv-cross set 0 → [[buffer(0)]]
        NSMutableDictionary<NSString *, NSNumber *> *by_name = [NSMutableDictionary dictionary]; NSMutableDictionary<NSNumber *, NSString *> *lead_for = [NSMutableDictionary dictionary];   // #798 TBLEAD：成员名 → 下标；前导项下标 → 它所属的成员名
        for (NSDictionary *b in bs) {
            NSString *k = b[@"kind"]; nvn_rbind *r = &o->b[o->nb];
            id rg = b[@"reg"]; int reg = [rg isKindOfClass:[NSNumber class]] ? [rg intValue] : -1, aid = [b[@"arg_id"] intValue];
            r->aid = (uint16_t)aid; r->reg = reg < 0 ? 0 : (uint16_t)reg;
            NSString *nm = b[@"msl_name"], *ty = b[@"msl_type"];
            if ([nm isKindOfClass:[NSString class]]) by_name[nm] = @(o->nb);
            // Ryujinx's fallback for a handle it cannot trace to one slot (handle type 4: <stage>_<t|tb|s>_cb0_40000000, declared array<element, n>); the build leaves it without a slot
            // ('tbuf' / 'tex' with no reg, '?' for the samplers). Octopath Traveler 0's vertex shaders pick one of several c2 table slots at run time (61 shaders, slots 0-10)
            NSString *el; int n = arr_len(ty, &el);
            if ([nm isKindOfClass:[NSString class]] && [nm hasSuffix:@"_cb0_40000000"] && [ty isKindOfClass:[NSString class]] && [ty hasPrefix:@"array<"] && [ty hasSuffix:@">"]) {
                if (n < 1 || n > 32) FAIL("B binding %s: array of %d", nm.UTF8String, n);
                if ([el hasPrefix:@"sampler"]) r->kind = NVN_RB_SAMPD;
                else if ([el hasPrefix:@"texture_buffer"]) { r->kind = NVN_RB_TEXD; r->dtt = (uint8_t)MTLTextureTypeTextureBuffer; uint8_t tt; dummy_kind(el, &tt, &r->dpf); }
                else if ([el hasPrefix:@"texture"] || [el hasPrefix:@"depth"]) { r->kind = NVN_RB_TEXD; dummy_kind(el, &r->dtt, &r->dpf); }
                else FAIL("B binding %s: dynamic handle array of %s", nm.UTF8String, el.UTF8String);
                r->n = (uint8_t)n; o->dyn = 1; o->nb++; continue;
            }
            // SPIRV-Cross's MSL 2.3 image atomics: the image (texture_buffer / texture2d… <uint> or <int>) and, for the atomics, a device pointer to the same memory, <image name>_atomic, which the build
            // reads as a second image of the same slot. Octopath Traveler 0: 2,084 shaders (Unreal's buffer images: cp_i_cb2_4C_r32ui_atomic)
            if ([k isEqualToString:@"img"] && reg >= 0 && [nm isKindOfClass:[NSString class]] && [nm hasSuffix:@"_atomic"] && [ty isKindOfClass:[NSString class]] && [ty hasPrefix:@"device atomic_"]) {
                r->kind = NVN_RB_IMGA; r->rw = 1; o->nb++; continue;
            }
            if ([k isEqualToString:@"cbuf"]) r->kind = NVN_RB_CBUF;
            else if ([k isEqualToString:@"samp"]) { r->kind = NVN_RB_SAMP;   // declared as an array (the sampler half of a separate handle pair whose texture half is a run-time c2 array, Dsh.cs C2Array): every element is this one sampler
                if (n > 1) { if (n > 32) FAIL("B binding %s: array of %d", nm.UTF8String, n); r->n = (uint8_t)n; } }
            else if ([k isEqualToString:@"samp_tex"]) r->kind = NVN_RB_SAMPT;
            else if ([k isEqualToString:@"tex"]) { r->kind = NVN_RB_TEX; dummy_kind(b[@"msl_type"], &r->dtt, &r->dpf); r->f1d = [b[@"fetch1d"] boolValue] ? ([b[@"fetch1d_exact"] boolValue] ? 2 : 1) : 0;
                // #968: the s2a_flags.yzw bit the translator reads for this binding's coordinate normalization (Dsh.cs Reflect); absent in an older library = no bit, as before
                id ub = b[@"unnorm_bit"];
                if (ub && ![ub isKindOfClass:[NSNumber class]]) FAIL("B binding %s: unnorm_bit is not a number", [nm description].UTF8String);
                if (ub) { int v = [ub intValue]; if (v < -1 || v >= 96) FAIL("B binding %s: unnorm_bit %d outside -1..95", [nm description].UTF8String, v);
                    if (v < 0) o->unb_uncov++; else { r->unb = (uint8_t)(v + 1); o->has_unb = 1; } } }
            // An array of them (array<element, n>): the handles of a uniform buffer the shader indexes at run time (Ryujinx's texture array from a buffer, handle 0: the index is the handle's
            // byte offset ÷ 8, an NVN handle being 64-bit). Paper Mario: The Thousand-Year Door's reflection shaders: array<texture2d<float>, 32> fp_t2d_cb14_0, the handles of uniform slot 11
            else if ([k isEqualToString:@"tex_ubo"]) { r->kind = NVN_RB_TEXU; dummy_kind(el, &r->dtt, &r->dpf); r->off = (uint16_t)[b[@"off"] intValue]; o->bindless = 1;
                if (n) { if (n > 32) FAIL("B binding %s: array of %d", nm.UTF8String, n); r->n = (uint8_t)n; } }
            else if ([k isEqualToString:@"samp_ubo"]) { r->kind = NVN_RB_SAMPU; r->off = (uint16_t)[b[@"off"] intValue]; r->sid = [b[@"sid"] boolValue]; o->bindless = 1;
                if (n) { if (n > 32) FAIL("B binding %s: array of %d", nm.UTF8String, n); r->n = (uint8_t)n; } }
            else if ([k isEqualToString:@"samp_id"]) r->kind = NVN_RB_SAMPI;
            // The pools, indexed by the handle's IDs (nvn_refl.h TEXP / SAMPP): which texture is read is known only when the GPU runs the draw
            else if ([k isEqualToString:@"tex_pool"]) { if (![b[@"elem"] isKindOfClass:[NSString class]]) FAIL("B binding %s: texture pool without its element type", [nm description].UTF8String); r->kind = NVN_RB_TEXP; dummy_kind(b[@"elem"], &r->dtt, &r->dpf); o->bindless = o->pool = 1;
                r->rw = [b[@"elem"] containsString:@"access::write"] || [b[@"elem"] containsString:@"access::read_write"]; }   // an image pool (the shader writes through it): nvn_mtl.m pool_fit / pool_mark_writes
            else if ([k isEqualToString:@"samp_pool"]) { r->kind = NVN_RB_SAMPP; o->bindless = o->pool = 1; }
            else if ([k isEqualToString:@"tex_c2a"] || [k isEqualToString:@"samp_c2a"]) {   // an array of the driver table's handles (nvn_refl.h TEXA / SAMPA)
                if (n < 1 || n > 32) FAIL("B binding %s: array of %d", nm.UTF8String, n);
                r->kind = [k isEqualToString:@"tex_c2a"] ? NVN_RB_TEXA : NVN_RB_SAMPA; r->n = (uint8_t)n; r->off = (uint16_t)[b[@"off"] intValue];
                if (r->kind == NVN_RB_TEXA) dummy_kind(el, &r->dtt, &r->dpf);
            }
            else if ([k isEqualToString:@"img"]) { r->kind = NVN_RB_IMG; dummy_kind(b[@"msl_type"], &r->dtt, &r->dpf);   // rw: the shader writes it (access::write / read_write; a load-only view of the slot is not)
                r->rw = [ty isKindOfClass:[NSString class]] && ([ty containsString:@"access::write"] || [ty containsString:@"access::read_write"]);
                r->atomic_image = [b[@"atomic"] boolValue];
                o->has_atomic_image |= r->atomic_image;
                if (r->atomic_image && (!r->rw || (r->dpf != NVN_DPF_UINT && r->dpf != NVN_DPF_SINT) ||
                    !([ty hasPrefix:@"texture2d<"] || [ty hasPrefix:@"texture2d_array<"] || [ty hasPrefix:@"texture3d<"] || [ty hasPrefix:@"texture_buffer<"])))
                    FAIL("B binding %s: unsupported native image atomic type %s", nm.UTF8String, ty.UTF8String); }
            else if ([k isEqualToString:@"img_ubo"]) { r->kind = NVN_RB_IMGU; dummy_kind(b[@"msl_type"], &r->dtt, &r->dpf); r->off = (uint16_t)[b[@"off"] intValue]; o->bindless = 1;   // its handle in a uniform buffer (No Man's Sky, 11-05)
                r->rw = [ty isKindOfClass:[NSString class]] && ([ty containsString:@"access::write"] || [ty containsString:@"access::read_write"]);
                // Native image atomics as IMG (11-07 No Man's Sky: spot light lists and depth reprojection, handles in c3): nvn_mtl.m img_atomic_prepare takes the texture ID through img_tid
                r->atomic_image = [b[@"atomic"] boolValue];
                o->has_atomic_image |= r->atomic_image;
                if (r->atomic_image && (!r->rw || (r->dpf != NVN_DPF_UINT && r->dpf != NVN_DPF_SINT) ||
                    !([ty hasPrefix:@"texture2d<"] || [ty hasPrefix:@"texture2d_array<"] || [ty hasPrefix:@"texture3d<"] || [ty hasPrefix:@"texture_buffer<"])))
                    FAIL("B binding %s: unsupported native image atomic type %s", nm.UTF8String, ty.UTF8String); }
            else if ([k isEqualToString:@"tbuf"]) { r->kind = NVN_RB_TBUF; uint8_t tt; dummy_kind(b[@"msl_type"], &tt, &r->dpf); }
            else if ([k isEqualToString:@"tbuf_ubo"]) { r->kind = NVN_RB_TBUFU; uint8_t tt; dummy_kind(b[@"msl_type"], &tt, &r->dpf); r->off = (uint16_t)[b[@"off"] intValue]; o->bindless = 1; }   // its handle in a uniform buffer (Civilization VI, 11-05)
            else if ([k isEqualToString:@"sbuf"]) { r->kind = NVN_RB_SBUFP; r->rw = sbuf_rw(b); }
            else if ([k isEqualToString:@"ubo_ptr"]) r->kind = NVN_RB_UBOP;
            else if ([k isEqualToString:@"gmem_map"]) { r->kind = NVN_RB_GMEM; r->rw = [b[@"rw"] boolValue]; }   // raw memory pool table (nvn_refl.h GMEM)
            else if ([k isEqualToString:@"gmem_log"]) { r->kind = NVN_RB_GMEML; r->rw = 1; }
            else if ([k isEqualToString:@"sbuf_ubo"]) { r->kind = NVN_RB_SBUFU; r->rw = sbuf_rw(b); r->off = (uint16_t)[b[@"off"] intValue]; }
            else if ([k isEqualToString:@"sbuf_push"]) { int off = [b[@"off"] intValue];   // its address pushed into NVN2 push slot reg (Dsh.cs sbuf_push; nvn_refl.h SBUFQ)
                if (reg < 0 || reg >= NVN_REFL_PUSH_SLOTS || off < 0 || off + 8 > NVN_REFL_PUSH_BYTES) FAIL("B binding %s: push slot %d + %d outside the %d slots of %d bytes", [nm description].UTF8String, reg, off, NVN_REFL_PUSH_SLOTS, NVN_REFL_PUSH_BYTES);
                r->kind = NVN_RB_SBUFQ; r->rw = sbuf_rw(b); r->off = (uint16_t)off; }
            else if ([k isEqualToString:@"geometry"]) { if (reg < 0 || reg > 4) FAIL("invalid geometry helper slot"); r->kind = NVN_RB_GEOMETRY; }
            else if ([k isEqualToString:@"support"]) r->kind = NVN_RB_SUPPORT;
            else if ([k isEqualToString:@"uvx"]) r->kind = NVN_RB_UVX;
            else if ([k isEqualToString:@"lb"]) r->kind = NVN_RB_LB;   // S2Arm #800 sampler LOD bias table (dmsh_red.py fs_lb)
            else if ([k isEqualToString:@"ubolen"]) r->kind = NVN_RB_UBOLEN;   // #1204 T1 uniform buffer length table (gal_spvx.m direct form)
            else if ([k isEqualToString:@"sbsize"]) r->kind = NVN_RB_SBSZ;     // SPIRV-Cross storage buffer byte sizes (by argument id)
            else if ([k isEqualToString:@"tblead"]) { if (![b[@"for"] isKindOfClass:[NSString class]]) FAIL("B binding %s: texel buffer lead without its buffer", [nm description].UTF8String);
                r->kind = NVN_RB_TBLEAD; lead_for[@(o->nb)] = b[@"for"]; }   // #798（nvn_refl.h TBLEAD）
            else if ([k isEqualToString:@"c1"]) r->kind = NVN_RB_C1;
            // 常量库 c[24 + k]：NVN2（Ampere）的推常量槽 k（nvn2_cmd.h；PushGraphics / ComputeConstants 推进来的那 256 字节），不是驱动段
            else if ([k isEqualToString:@"drvcb"] && [b[@"bank"] intValue] >= 24 && [b[@"bank"] intValue] < 32) { r->kind = NVN_RB_PUSH; r->reg = (uint16_t)([b[@"bank"] intValue] - 24); }
            else if ([k isEqualToString:@"drvcb"]) r->kind = [b[@"bank"] intValue] == 2 ? NVN_RB_DRV2 : NVN_RB_DRV0;
            else FAIL("B binding kind %s not implemented (%s)", k.UTF8String, [b[@"msl_name"] UTF8String]);
            if ((r->kind == NVN_RB_CBUF || r->kind == NVN_RB_SAMP || r->kind == NVN_RB_SAMPT || r->kind == NVN_RB_TEX || r->kind == NVN_RB_IMG || r->kind == NVN_RB_TBUF || r->kind == NVN_RB_SBUFP || r->kind == NVN_RB_UBOP || r->kind == NVN_RB_SBUFU || r->kind == NVN_RB_TEXU || r->kind == NVN_RB_IMGU || r->kind == NVN_RB_TBUFU || r->kind == NVN_RB_SAMPU || r->kind == NVN_RB_SAMPI) && reg < 0)
                FAIL("B binding %s has no resolved slot number", [b[@"msl_name"] UTF8String]);
            if (r->kind == NVN_RB_TEXU || r->kind == NVN_RB_SAMPU || r->kind == NVN_RB_TBUFU || r->kind == NVN_RB_IMGU) pair_from_name(nm, r);   // the second word of a separate handle
            o->nb++;
        }
        for (NSNumber *li in lead_for) {   // #798：前导项配给它的纹素缓冲（名字对上、且是纹素缓冲那几种）
            NSNumber *ti = by_name[lead_for[li]]; int L = li.intValue, T = ti ? ti.intValue : -1;
            // 几何拓扑缓冲 trb_data：翻译器先把它声明成纹素缓冲，spv_tbias（gal_spvx.c）照例给它加了前导项；几何变体再把它改写成宿主填的 uint 指针
            //   （Dsh.cs TopologyPointer），反射里成了几何辅助缓冲。宿主自己写的缓冲没有不对齐偏移，前导数恒为 0——不配对正是 0（tbl_lead_of 无配对返回 0），
            //   和 #798 之前一样。原先整支判失败：几何核编不出、整批几何绘制被跳过（11-16 一款 Switch 2 游玩帧 121 笔）。
            // 图像纹素缓冲（可写，img / img_ubo 声明成 texture_buffer）：spv_tbias 同样给它加前导项，宿主的前导视图（tbl_view）只做只读纹素缓冲，
            //   不配对 = 前导数 0 = #798 之前的行为（那时这些着色器照常编、照常画）。原先整支判失败（11-16 一款 Unreal 游戏一局 188 处）。别的种类照旧报错
            if (T >= 0 && T < o->nb && (o->b[T].kind == NVN_RB_GEOMETRY ||
                ((o->b[T].kind == NVN_RB_IMG || o->b[T].kind == NVN_RB_IMGU) && o->b[T].dtt == (uint8_t)MTLTextureTypeTextureBuffer))) continue;
            if (T < 0 || T >= o->nb || !(o->b[T].kind == NVN_RB_TBUF || o->b[T].kind == NVN_RB_TBUFU || (o->b[T].kind == NVN_RB_TEX && o->b[T].dtt == (uint8_t)MTLTextureTypeTextureBuffer)))
                FAIL("B binding gal_tbl_%s: no texel buffer of that name", [lead_for[li] description].UTF8String);
            o->b[T].tbl = (uint16_t)(L + 1); o->b[L].tbl = (uint16_t)(T + 1); o->has_tbl = 1;
        }
        NSDictionary *dr = j[@"drv_reads"];
        if ([dr isKindOfClass:[NSDictionary class]]) { o->drv_read[0] = dr[@"0"] != nil; o->drv_read[2] = dr[@"2"] != nil; }
        // A declared driver-segment binding means the shader reads it: the build's drv_reads scan (dmsh_build.py) matches only fragment-shader names (fp_c0 / fp_c2), so vertex and compute
        // shaders reading c0 got an all-zero segment (Link's Awakening's light culling multiplied the tile row by a zero workgroup count: every row's lights landed in row 0)
        for (int i = 0; i < o->nb; i++) { if (o->b[i].kind == NVN_RB_DRV0) o->drv_read[0] = 1; else if (o->b[i].kind == NVN_RB_DRV2) o->drv_read[2] = 1; }
        NSArray *uf = j[@"drv_unfillable"];
        // Locations the replay layer does not fill (a dynamic index, a word outside its tables) read 0, as every location of a vertex / compute shader the build does not scan does:
        //   the shader is used, with a note (S2Arm, no refusal on a check that only says "not filled": 0100853015E86000's pixel shaders read c0 by a dynamic index and c0+0x630,
        //   and the whole program was refused, so every draw with it was skipped, #bbd549). The dynamic index lands in the tables the layer fills when it indexes them
        if ([uf isKindOfClass:[NSArray class]] && uf.count) { o->drv_unfilled = 1; if (errlen > 0) snprintf(err, errlen, "reads driver-bank locations the replay layer does not fill (they read 0): %s", [[uf componentsJoinedByString:@" "] UTF8String]); }
        NSString *c1 = j[@"c1"];
        if (c1.length % 2 || c1.length / 2 > 0xffff) FAIL("c1 is %lu bytes: over the limit or an odd hex length", (unsigned long)c1.length / 2);
        if (c1.length && !(o->c1 = malloc(c1.length / 2))) FAIL("c1 allocation of %lu bytes failed", (unsigned long)c1.length / 2);
        if (c1.length) { o->has_c1 = 1; o->c1_len = (uint16_t)(c1.length / 2); for (unsigned i = 0; i < o->c1_len; i++) o->c1[i] = (uint8_t)strtoul([[c1 substringWithRange:NSMakeRange(2 * i, 2)] UTF8String], NULL, 16); }
        for (NSDictionary *v in j[@"vertex_inputs"]) {   // [[attribute(n)]]: n is the NVN vertex attribute number
            int loc = [v[@"location"] intValue]; NSString *t = v[@"msl_type"];
            if (loc < 0 || loc >= NVN_REFL_MAXV || o->nv >= NVN_REFL_MAXV) FAIL("B vertex input %d out of range", loc);
            o->v[o->nv].loc = o->v[o->nv].nvn = (uint8_t)loc;
            o->v[o->nv].ct = [t hasPrefix:@"uint"] ? NVN_CT_UINT : [t hasPrefix:@"int"] ? NVN_CT_INT : NVN_CT_FLOAT;
            memset(o->v[o->nv].sh, 0xff, sizeof o->v[o->nv].sh);
            o->nv++;
        }
        NSDictionary *vin = j[@"vin"];   // shadow inputs of the <key>_bv library (dmsh_vin.py): per input, the Metal attribute index of its float / other-sign declaration
        if ([vin isKindOfClass:[NSDictionary class]]) {
            uint32_t used = 0;
            for (NSDictionary *e in vin[@"shadow"]) {
                int loc = [e[@"location"] intValue], v = 0;
                while (v < o->nv && o->v[v].loc != loc) v++;
                if (v == o->nv || o->v[v].ct == NVN_CT_FLOAT) FAIL("shadow input for location %d, which is not an integer input", loc);
                const struct { NSString *k; int ct; } T[3] = { { @"float", NVN_CT_FLOAT }, { @"sint", NVN_CT_INT }, { @"uint", NVN_CT_UINT } };
                for (int q = 0; q < 3; q++) { id x = e[T[q].k]; if (!x) continue; int idx = [x intValue];
                    if (idx < 16 || idx > 30 || used >> idx & 1 || T[q].ct == o->v[v].ct) FAIL("shadow input %s of location %d at attribute %d: out of 16-30, used twice or of the input's own type", T[q].k.UTF8String, loc, idx);
                    used |= 1u << idx; o->v[v].sh[T[q].ct] = (uint8_t)idx; }
            }
            o->has_vin = used != 0;
        }
        for (int w = 0; w < 2; w++) { NSArray *ul = j[w ? @"user_in" : @"user_out"]; if (![ul isKindOfClass:[NSArray class]]) continue;   // dmsh_build.py user_locs
            uint32_t bits = 0; for (NSNumber *l in ul) { int v = [l isKindOfClass:[NSNumber class]] ? l.intValue : -1; if (v < 0 || v > 31) FAIL("user(locn) %d out of range", v); bits |= 1u << v; }
            if (w) o->user_in = bits; else o->user_out = bits; o->has_user |= (uint8_t)(1u << w); }
        NSDictionary *ra = j[@"raster"];
        o->pos_attr = -1; o->may_discard = 1; o->writes_smask = 1;
        if ([ra isKindOfClass:[NSDictionary class]]) {
            if (ra[@"pos_attr"]) { int pa = [ra[@"pos_attr"] intValue]; o->pos_attr = (int8_t)(pa >= 0 && pa < 16 ? pa : -1); o->pos_w1 = [ra[@"pos_w"] isEqual:@"one"]; }
            if (ra[@"discard"]) o->may_discard = [ra[@"discard"] intValue] != 0;
            if (ra[@"sample_mask"]) o->writes_smask = [ra[@"sample_mask"] intValue] != 0;
            for (NSNumber *c in ra[@"colors"]) if (c.intValue >= 0 && c.intValue < 8) o->color_mask |= (uint8_t)(1u << c.intValue);
            o->color_known = [ra[@"colors"] isKindOfClass:[NSArray class]];
        }
        memset(o->uv_attr, -1, sizeof o->uv_attr); memset(o->uv_aff_attr, -1, sizeof o->uv_aff_attr);
        NSDictionary *ua = [ra isKindOfClass:[NSDictionary class]] ? ra[@"uv_affine"] : nil;
        if ([ua isKindOfClass:[NSDictionary class]]) for (NSString *k in ua) { int l = k.intValue; NSDictionary *e = ua[k]; int a = [e[@"attr"] intValue];
            if (l < 0 || l >= 32 || a < 0 || a >= 16) continue;
            NSArray *refs[4] = {e[@"sx"], e[@"ox"], e[@"sy"], e[@"oy"]}; int ok = 1;
            for (int q = 0; q < 4; q++) { NSArray *r = refs[q]; if (![r isKindOfClass:[NSArray class]] || r.count != 3) { ok = 0; break; }
                int sl = [r[0] intValue], vec = [r[1] intValue], cmp = [r[2] intValue]; if (sl < 0 || sl > 15 || vec < 0 || vec > 4095 || cmp < 0 || cmp > 3) { ok = 0; break; }   // a vec4 anywhere in the 64 KB buffer (upstream reference implementation, MIT)
                o->uv_aff[l][q] = (uint32_t)(sl << 16 | vec << 2 | cmp); }
            if (ok) o->uv_aff_attr[l] = (int8_t)a; }
        NSArray *su = [ra isKindOfClass:[NSDictionary class]] ? ra[@"scr_uv"] : nil;   // 10-30：屏幕坐标插值量（见 nvn_refl.h scr_uv）
        if ([su isKindOfClass:[NSArray class]]) for (NSNumber *l in su) if ([l isKindOfClass:[NSNumber class]] && l.intValue >= 0 && l.intValue < 32) o->scr_uv |= 1u << l.intValue;
        NSArray *sp = [ra isKindOfClass:[NSDictionary class]] ? ra[@"scr_pos"] : nil;   // #1152：等于 gl_Position 的插值量（见 nvn_refl.h scr_pos）
        if ([sp isKindOfClass:[NSArray class]]) for (NSNumber *l in sp) if ([l isKindOfClass:[NSNumber class]] && l.intValue >= 0 && l.intValue < 32) o->scr_pos |= 1u << l.intValue;
        NSDictionary *uv = [ra isKindOfClass:[NSDictionary class]] ? ra[@"uv_from_attr"] : nil;
        if ([uv isKindOfClass:[NSDictionary class]]) for (NSString *k in uv) { int l = k.intValue, a = [uv[k] intValue]; if (l >= 0 && l < 32 && a >= 0 && a < 16) o->uv_attr[l] = (int8_t)a; }
        NSDictionary *fe = j[@"fetch"];
        if ([fe isKindOfClass:[NSDictionary class]]) {
            for (NSDictionary *c in fe[@"calls"]) { int i = [c[@"fc"] intValue], r = [c[@"tex_reg"] intValue], l = [c[@"varying_locn"] intValue];
                if (i != o->nfc || i >= 32 || r < 0 || r >= 256 || l < 0 || l >= 32) FAIL("fetch call table not contiguous or out of range (entry %d)", i);
                if ([c[@"proj"] intValue]) o->fc_proj |= 1u << o->nfc;
                if ([c[@"ndc"] intValue]) o->fc_ndc |= 1u << o->nfc;
                o->fc_reg[o->nfc] = (uint8_t)r; o->fc_locn[o->nfc] = (uint8_t)l; o->nfc++; }
            for (NSNumber *r in fe[@"mixed_regs"]) if (r.intValue >= 0 && r.intValue < 256) o->fc_mixed[r.intValue >> 6] |= 1ull << (r.intValue & 63);
            for (NSDictionary *u in fe[@"outputs"]) { if (o->nfo >= 8) FAIL("more than 8 fetch outputs"); o->fo_color[o->nfo++] = (uint8_t)[u[@"color"] intValue]; }
        }
        for (NSDictionary *u in j[@"first_store"]) { if (![u isKindOfClass:[NSDictionary class]]) FAIL("first_store entry is not an object"); if (o->nfirst >= 4) FAIL("more than 4 first-invocation stores");
            int reg = [u[@"reg"] intValue], word = [u[@"word"] intValue];
            // 反射里的 reg 是着色器内存储缓冲的序号（绑定项的 index，graphics/tools/direct/dsh/Dsh.cs first_store），宿主派发时按 NVN 存储槽取缓冲（S.ssbo[5][reg]）：
            //   同一份绑定表里 kind = sbuf、index = 它的那一项，把它换成该项的 reg（NVN 槽）。11-09 质量线 Raiders 卡顿：剔除着色器 029d9c3ec1fcb39f 的 5 个存储缓冲
            //   index 0..4 对应槽 4 / 2 / 0 / 1 / 3，首写「index 0 第 1 字清零」落到了槽 0 的别的缓冲上，槽 4 里间接绘制的实例数从不归零、每帧 +40，GPU 一帧从 90 ms 涨到 600 ms 以上。
            //   绑定表里找不到这个序号（旧反射 / index 与槽本来相同）就照原值
            for (NSDictionary *b in [j[@"bindings"] isKindOfClass:[NSArray class]] ? j[@"bindings"] : @[]) {
                if (![b isKindOfClass:[NSDictionary class]] || ![b[@"kind"] isEqual:@"sbuf"] || ![b[@"index"] isKindOfClass:[NSNumber class]] || [b[@"index"] intValue] != reg) continue;
                if ([b[@"reg"] isKindOfClass:[NSNumber class]]) reg = [b[@"reg"] intValue];
                break;
            }
            if (reg < 0 || reg >= 16) FAIL("first-invocation store to storage slot %d", reg);
            if (word < 0 || word > 0xffff) FAIL("first-invocation store to word %d", word);
            o->first[o->nfirst].reg = (uint8_t)reg; o->first[o->nfirst].word = (uint16_t)word; o->first[o->nfirst++].value = (uint32_t)[u[@"value"] unsignedIntValue]; }
        NSArray *tg = j[@"threadgroup_size"];
        if ([tg isKindOfClass:[NSArray class]] && tg.count == 3) for (int i = 0; i < 3; i++) o->tg[i] = (uint16_t)[tg[i] intValue];
        return 0;
    }
    #undef FAIL
}
