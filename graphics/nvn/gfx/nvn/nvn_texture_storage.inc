// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// NVN textures and buffers name the same pool bytes. Keep buffer-to-texture
// uploads in that storage too: a later byte copy may relocate the texture.
// Addressing follows nvn_bl_offset / Ryujinx BlockLinearLayout, in both GOB orders.
typedef struct {
    uint64_t src, dst, base, pitch, image;
    uint32_t bytes, rows, slices, x, y, z, full_rows, th, td, gx, gob2, unpack;
} storage_move_params;
static id<MTLComputePipelineState> g_storage_move;
static int storage_move_init(void) {
    if (g_storage_move) return 1;
    static const char *msl =
        "#include <metal_stdlib>\nusing namespace metal;\n"
        "struct P { ulong src,dst,base,pitch,image; uint bytes,rows,slices,x,y,z,full_rows,th,td,gx,gob2,unpack; };\n"
        "inline ulong at(uint x,uint y,uint z,constant P& p) {\n"
        " uint bh=1u<<p.th,bd=1u<<p.td,by=(p.full_rows+8u*bh-1u)/(8u*bh);\n"
        " ulong block=512ul*bh*bd; uint inner=p.gob2 ? (x%64/32)*256+(y%8/4)*128+(x%32/16)*64+(y%4/2)*32+(y%2)*16+x%16 : (x%64/32)*256+(y%8/2)*64+(x%32/16)*32+(y%2)*16+x%16;\n"
        " return p.base+((ulong)(z/bd)*p.gx*by+(ulong)(y/(8*bh))*p.gx+x/64)*block+((ulong)(z%bd)*bh+y%(8*bh)/8)*512+inner; }\n"
        "kernel void move_bytes(device const uchar* s [[buffer(0)]],device uchar* d [[buffer(1)]],constant P& p [[buffer(2)]],uint3 q [[thread_position_in_grid]]) {\n"
        " uint x=q.x*16; if(x>=p.bytes||q.y>=p.rows||q.z>=p.slices)return;\n"
        " ulong lin=(ulong)q.z*p.image+(ulong)q.y*p.pitch+x,bl=at(p.x+x,p.y+q.y,p.z+q.z,p); uint n=min(16u,p.bytes-x);\n"
        " ulong so=p.src+(p.unpack?bl:lin),dd=p.dst+(p.unpack?lin:bl);\n"
        " if(n==16 && ((p.x+x)&15u)==0 && ((so|dd)&15ul)==0) *(device uint4*)(d+dd)=*(device const uint4*)(s+so);\n"
        " else for(uint i=0;i<n;i++){bl=at(p.x+x+i,p.y+q.y,p.z+q.z,p);d[p.dst+(p.unpack?lin+i:bl)]=s[p.src+(p.unpack?bl:lin+i)];}\n} \n";
    NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(msl) options:nil error:&error];
    if (lib) g_storage_move = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"move_bytes"] error:&error];
    if (!g_storage_move) MLOG("【红】 texture storage copy kernel: %s", error.localizedDescription.UTF8String);
    return g_storage_move != nil;
}
static int storage_move(const tex_t *t, unsigned lv, unsigned layer, const NVNcopyRegion *r,
                        id<MTLBuffer> src, uint64_t so, id<MTLBuffer> dst, uint64_t doff,
                        size_t row, size_t image, int unpack) {
    uint32_t rb, rows, slices, bpb; uint64_t base; unsigned th, td; int bw, bh;
    if (nvn_deswizzle_geom(&t->d, lv, layer, &rb, &rows, &slices, &base, &th, &td, &bpb) || !storage_move_init()) return 0;
    nvn_fmt_bpb(t->d.format, &bw, &bh);
    storage_move_params p = {so, doff, base, row, image,
        (uint32_t)((r->width + bw - 1) / bw * bpb), (uint32_t)((r->height + bh - 1) / bh), (uint32_t)MAX(r->depth, 1),
        (uint32_t)(r->xoffset / bw * bpb), (uint32_t)(r->yoffset / bh), (uint32_t)r->zoffset,
        rows, th, td, MAX(nvn_tex_level_gobs(&t->d, lv), (rb + 63) / 64), (uint32_t)nvn_gob_switch2, (uint32_t)unpack};
    if (r->xoffset < 0 || r->yoffset < 0 || r->zoffset < 0 || !p.bytes || !p.rows || p.x + p.bytes > rb || p.y + p.rows > rows || p.z + p.slices > slices || row < p.bytes || image < row * p.rows) return 0;
    id<MTLBuffer> params; size_t off = arena_alloc(sizeof p, &params);
    memcpy((uint8_t *)params.contents + off, &p, sizeof p);
    rp_end(); id e = enc_c_begin(NULL);
    enc_c_pso(e, g_storage_move);
    enc_c_args(e, src.gpuAddress, 0); enc_c_args(e, dst.gpuAddress, 1); enc_c_args(e, params.gpuAddress + off, 2);
    enc_c_dispatch(e, MTLSizeMake((p.bytes + 255) / 256, p.rows, p.slices), MTLSizeMake(16, 1, 1));
    enc_c_end(e); args_dirty_all();
    return 1;
}
// Returns NULL when the pool storage now holds the upload (or needs nothing), else why it could not be updated (the caller's red line names it).
// A SPARSE texture in a physical pool is laid out like any other one here (tex_init_fill reads its initial content from the same bytes,
// nvn_mtl.m "treated as full-size Metal texture"): only a virtual pool's page-table storage is out of reach.
static const char *texture_storage_upload(const p_copy_b2t *c, id<MTLBuffer> source, uint64_t so, size_t row, size_t image) {
    id<MTLBuffer> src = source;
    const tex_t *t = c->tex;
    if (t->d.target == NVN_TEXTURE_TARGET_BUFFER || (t->d.flags & (NVN_TEXTURE_FLAGS_LINEAR | NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET))) return NULL;
    // An NvPkg tracks CPU writes by comparing per-page hashes (pk->ph) against t->mem; mutating t->mem from the GPU breaks those hashes and turns neighbor CPU writes in the same host page into false partial re-uploads.
    if ([tex_get(t->serial) isKindOfClass:[NvPkg class]]) return NULL;
    if (t->has_layout) return "packaged layout";
    if (t->d.samples > 1) return "multisampled";
    if (!t->pool) return "no pool";
    if (t->pool->flags & NVN_MEMORY_POOL_FLAGS_VIRTUAL) return "virtual pool";
    void *db; uint64_t doff;
    if (!t->mem || !nvn_be_addr((uint64_t)t->mem, t->L.size, &db, &doff)) return "storage has no backing buffer";
    int is3d = t->d.target == 2, nz = MAX(c->r.depth, 1);
    unsigned lv = c->has_view && c->view.set_levels ? c->view.base_level : 0;
    unsigned layer = c->has_view && c->view.set_layers ? c->view.min_layer : 0;
    // Preserve the upload source when the linear input aliases its tiled destination.
    if (c->src < (uint64_t)t->mem + t->L.size && (uint64_t)t->mem < c->src + image * nz) {
        id<MTLBuffer> copy = [g_dev newBufferWithLength:image * nz options:MTLResourceStorageModePrivate];
        if (!copy) return "aliasing source copy allocation failed";
        res_add(copy); defer_obj_release(copy);
        enc_b_copy_buffer(blit(), src, so, copy, 0, image * nz); src = copy; so = 0;
    }
    NVNcopyRegion r = c->r;
    for (int z = 0; z < (is3d ? 1 : nz); z++) {
        if (!is3d) { r.zoffset = 0; r.depth = 1; }
        if (!storage_move(t, lv, is3d ? 0 : layer + c->r.zoffset + z, &r, src, so + z * image, (__bridge id<MTLBuffer>)db, doff, row, image, 0)) return "region outside the level's block-linear layout";
    }
    // Conservatively track dependencies over the storage, without declaring
    // untouched GOBs current in the GPU-texture write ledger.
    g_wr_epoch++; g_mdx_epoch++;
    vc_gpu_write((uint64_t)t->mem, t->L.size);
    sbw_note((uint64_t)t->mem, t->L.size, SBW_GPU);
    return NULL;
}
// A new descriptor can consume a just-copied buffer before the CPU sees its bytes.
// Read that storage on the same GPU timeline, rather than uploading a CPU snapshot.
static int texture_storage_load(const tex_t *t, id<MTLTexture> mt) {
    uint32_t pf; int expanded;
    if (fmt_unpack(t->d.format, &pf, &expanded) || t->d.samples > 1 || (t->d.flags & (NVN_TEXTURE_FLAGS_LINEAR | NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET))) return 0;
    if ((t->d.flags & NVN_TEXTURE_FLAGS_SPARSE) && (!t->pool || (t->pool->flags & NVN_MEMORY_POOL_FLAGS_VIRTUAL))) return 0;   // SPARSE in a physical pool: laid out like any other (texture_storage_upload)
    void *sb; uint64_t so;
    if (!nvn_be_addr((uint64_t)t->mem, t->L.size, &sb, &so)) return 0;
    id<MTLBuffer> tiled = (__bridge id<MTLBuffer>)sb;
    // Keep the existing initial-content rule for untouched stale GOBs. A pool
    // buffer write can overlap only part of an earlier private render target.
    uint64_t *runs = NULL, stale = 0;
    int nr = gpw_stale(t->mem, t->L.size, &runs, &stale);
    if (nr) {
        id<MTLBuffer> copy = [g_dev newBufferWithLength:t->L.size options:MTLResourceStorageModePrivate];
        if (!copy) { free(runs); return 0; }
        res_add(copy); defer_obj_release(copy);
        enc_b_copy_buffer(blit(), tiled, so, copy, 0, t->L.size);
        for (int i = 0; i < nr; i++) [blit() fillBuffer:copy range:NSMakeRange(runs[2 * i], runs[2 * i + 1] - runs[2 * i]) value:0];
        tiled = copy; so = 0;
    }
    free(runs);
    int bw, bh, bpb = nvn_fmt_bpb(t->d.format, &bw, &bh);
    for (unsigned lv = 0; lv < MAX(t->d.levels, 1); lv++) {
        unsigned w = MAX(t->d.width >> lv, 1), h = MAX(t->d.height >> lv, 1), dz = t->d.target == 2 ? MAX(t->d.depth >> lv, 1) : 1;
        size_t row = (w + bw - 1) / bw * bpb, image = row * ((h + bh - 1) / bh);
        id<MTLBuffer> linear = [g_dev newBufferWithLength:image * dz options:MTLResourceStorageModePrivate];
        if (!linear) return 0;
        res_add(linear); defer_obj_release(linear);
        NVNcopyRegion r = {0, 0, 0, (int)w, (int)h, (int)dz};
        for (unsigned layer = 0; layer < t->L.layers; layer++) {
            if (!storage_move(t, lv, layer, &r, tiled, so, linear, 0, row, image, 1)) return 0;
            enc_b_copy_buffer_texture(blit(), linear, 0, row, image, MTLSizeMake(w, h, dz), mt, layer, lv, MTLOriginMake(0, 0, 0));
        }
    }
    return 1;
}
