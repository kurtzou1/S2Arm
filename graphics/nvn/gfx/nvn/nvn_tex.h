// NVN texture storage layout (Tegra X1 block-linear), see nvn_tex.c.
#pragma once
#include <stdint.h>

typedef struct {
    int target, format, flags, samples;   // NVNtextureTarget / NVNformat / NVNtextureFlags / sample count (0 or 1 = single-sampled)
    uint32_t width, height, depth, levels, stride;
    int pkg_layout;                       // Packaged layout byte 0 (low nibble log2 block height, high nibble log2 block depth) | byte 1's low nibble (log2 width alignment in GOBs) << 8, + 1; 0 = automatic
} nvn_texdesc;

typedef struct {
    uint64_t size, layer_size;            // Total storage bytes, bytes per layer
    uint32_t align, layers, bpb;          // Alignment, layer count, bytes per block
    unsigned tileH, tileD;                // Block height / block depth (log2 of the GOB count)
} nvn_texlayout;

void nvn_tex_layout(const nvn_texdesc *d, nvn_texlayout *o);
uint64_t nvn_tex_level_offset(const nvn_texdesc *d, unsigned level);
uint32_t nvn_tex_level_gobs(const nvn_texdesc *d, unsigned level);   // GOB columns level `level` is laid out with (its width in GOBs; padded to whole 64 KB tiles in a sparse texture's tiled levels)
int nvn_fmt_bpb(int format, int *bw, int *bh);   // Bytes per block (0 = unknown format), block width and height
// Block height / block depth actually used by level `level` (log2 of the GOB count): the per-level block height shrinks with that level's row count (block rows), and deswizzling uses it level by level
void nvn_tex_level_tiles(const nvn_texdesc *d, unsigned level, unsigned *tileH, unsigned *tileD);
// Public sparse query: number of tiled levels, then tile width / height / depth in texels.
// The rest of the mip chain is a packed tail. Unsupported sparse targets return four zeros.
void nvn_tex_sparse_layout(const nvn_texdesc *d, uint32_t tile[4]);
// A texture buffer of n elements of bpb bytes read as 2D rows of NVN_TBUF_ROW texels (the translator's wrapped 1D fetch, x & 0x3FFF / x >> 14): width, height and bytes per row of the
// linear 2D texture over the same memory. One row is n texels, its byte length rounded up to align (the linear-texture row alignment); more rows are full 16384-texel rows. 0 when n or bpb is 0
#define NVN_TBUF_ROW 16384u
int nvn_tbuf_rows(uint64_t n, uint32_t bpb, uint32_t align, uint32_t *w, uint32_t *h, uint32_t *row);
// The exact form for Ampere's wrapped fetch (fetch1d_exact; InstEmitAmpereMem.cs takes W and H from the bound form and reads 0 past W * H): W * H = n exactly, so a fetch past the
// buffer reads 0 as the hardware's. n <= NVN_TBUF_ROW: one row of n; else W = the largest power of two dividing n (at most NVN_TBUF_ROW) and H = n / W. 0 when none fits
// (H > NVN_TBUF_ROW, or W * bpb not a multiple of align)
int nvn_tbuf_rows_exact(uint64_t n, uint32_t bpb, uint32_t align, uint32_t *w, uint32_t *h, uint32_t *row);
