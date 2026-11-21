// Direct present: crop fitting and the letterbox viewport, plain C so graphics/nvn/tests/t_present_fit.c tests the production code without Metal.
// Shared by nvn_mtl.m present_now (crop) and present_blit / present_blit_m4 (viewport).
#pragma once
#include <math.h>
#include <stdint.h>

// The game's window crop (x, y, w, h; w = h = 0 means the whole texture) against the source texture sw x sh.
//   0  = use the crop as given (out = in; no crop gives out = 0,0,0,0)
//   1  = the crop reaches past the source (S2Arm widen 10-28 Splatoon 3: the game sets a 2346-wide crop while the swap chain texture is still 1920 wide):
//        out = the part of the crop inside the source, trimmed to 16:9 from the crop origin, so the frame is shown 16:9 with black bars instead of dropped
//  -1  = invalid (negative origin, zero / negative size, or origin outside the source); out = in, the caller reports it as before
static inline int pf_crop_fit(const int in[4], uint64_t sw, uint64_t sh, int out[4]) {
    out[0] = out[1] = out[2] = out[3] = 0;
    if (!in || !(in[2] || in[3])) return 0;
    for (int i = 0; i < 4; i++) out[i] = in[i];
    if (in[0] < 0 || in[1] < 0 || in[2] <= 0 || in[3] <= 0 || (uint64_t)in[0] >= sw || (uint64_t)in[1] >= sh) return -1;
    if ((uint64_t)in[0] + (uint64_t)in[2] <= sw && (uint64_t)in[1] + (uint64_t)in[3] <= sh) return 0;
    int64_t w = (int64_t)sw - in[0], h = (int64_t)sh - in[1];
    if (w > in[2]) w = in[2];
    if (h > in[3]) h = in[3];
    if (w * 9 > h * 16) w = h * 16 / 9;        // wider than 16:9: keep the height
    else if (w * 9 < h * 16) h = w * 9 / 16;   // narrower: keep the width
    if (w <= 0 || h <= 0) return -1;
    out[2] = (int)w; out[3] = (int)h;
    return 1;
}

// The picture cw x ch fitted into the target dw x dh: same aspect, centered, black bars elsewhere; within 1% of the target's aspect it fills the target
// (the remainder of a game width rounded to a multiple of 8, e.g. 1952x900 on 2868x1320, 0.17%, leaves no few-pixel border)
typedef struct { double x, y, w, h; } pf_vp;
static inline pf_vp pf_viewport(double dw, double dh, double cw, double ch) {
    double s = fmin(dw / cw, dh / ch);
    // origin clamped at 0: when the fitted side equals the target, cw·s can land a hair above it in floating point (500 · 2.16 > 1080) and floor gave −1
    pf_vp v = {fmax(0, floor((dw - cw * s) / 2)), fmax(0, floor((dh - ch * s) / 2)), round(cw * s), round(ch * s)};
    if (fabs((dw / dh) / (cw / ch) - 1) < 0.01) v = (pf_vp){0, 0, dw, dh};
    return v;
}

// Fill modes for a target whose aspect differs from the picture's (replay presenter switch nvk_present_fill; mode 0 leaves pf_viewport's letterbox alone).
// src = the source rectangle being shown (x, y, w, h with w, h > 0), dw x dh = the target, ta / sa = target / source aspect, off = max(ta/sa, sa/ta) - 1.
//   mode 1, off <= 15%: stretch the whole source over the whole target (returns 1; crop = src)
//   mode 2, 1% <= off <= 30%: keep the aspect, enlarge until the target is covered and crop what overflows, centered: a narrower target loses the
//           left / right edges (w = floor(src h * ta)), a wider one the top / bottom (h = floor(src w / ta)) (returns 2; crop = the part of src to sample)
//   anything else: returns 0, crop = src and *vp is left as the caller set it (the letterbox)
// When it returns 1 or 2, *vp is the whole target.
static inline int pf_fill(int mode, double dw, double dh, const int src[4], int crop[4], pf_vp *vp) {
    for (int i = 0; i < 4; i++) crop[i] = src[i];
    if ((mode != 1 && mode != 2) || !(dw > 0) || !(dh > 0) || src[2] <= 0 || src[3] <= 0) return 0;
    const double cw = src[2], ch = src[3], ta = dw / dh, sa = cw / ch, off = ta > sa ? ta / sa - 1 : sa / ta - 1;
    if (mode == 1) {
        if (off > 0.15) return 0;
        *vp = (pf_vp){0, 0, dw, dh};
        return 1;
    }
    if (off < 0.01 || off > 0.30) return 0;
    double nw = cw, nh = ch;
    if (ta < sa) nw = floor(ch * ta); else nh = floor(cw / ta);
    if (nw < 1 || nh < 1) return 0;
    crop[0] = src[0] + (int)((cw - nw) / 2); crop[1] = src[1] + (int)((ch - nh) / 2); crop[2] = (int)nw; crop[3] = (int)nh;
    *vp = (pf_vp){0, 0, dw, dh};
    return 2;
}

// Output layer aspect (graphics/nvn/host_adapt.m out_aspect): a widened or heightened picture is shown at screen width / screen height (wide screens keep
// height 1080, narrow screens keep width 1920, so one formula covers both); otherwise 16:9. 11-03 Duo (1920x1350) with the game drawing a taller
// picture itself: the old width / 1080 gave 1.778 and squeezed the 1280x900 picture into a 16:9 layer with black above and below
static inline double pf_out_aspect(int widened, int sw, int sh) { return widened && sw > 0 && sh > 0 ? (double)sw / (double)sh : 16.0 / 9.0; }

// Whether a relayout of the output layer has to wait for the foreground (graphics/nvn/host_adapt.m s2a_direct_relayout). The root view is not laid out
// while the app is in the background (the multitasking snapshot resizes it). A layer on the external display's view (ext) is never held back. A layer just
// moved back to the root view (moved) is laid out at once when the root view's own scene is in the foreground (scene_fg): inside the external scene's
// disconnect callback the app state reads background while the phone's scene is still foreground active, and no foreground notification follows
static inline int pf_relayout_wait(int ext, int app_bg, int moved, int scene_fg) { return !ext && app_bg && !(moved && scene_fg); }
