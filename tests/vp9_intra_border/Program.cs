// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using Ryujinx.Graphics.Nvdec.Vp9;
using Ryujinx.Graphics.Nvdec.Vp9.Types;

static unsafe class Program
{
    static int Case(int plane, bool bottom, bool cropped)
    {
        using Surface surface = new(cropped ? 350 : 352, cropped ? 198 : 200);
        var pixels = plane == 0 ? surface.YBuffer : plane == 1 ? surface.UBuffer : surface.VBuffer;
        pixels.AsSpan().Fill(100);
        int ss = plane == 0 ? 0 : 1;
        int stride = plane == 0 ? surface.Stride : surface.UvStride;
        int visible = bottom
            ? plane == 0 ? surface.Height : surface.UvHeight
            : plane == 0 ? surface.Width : surface.UvWidth;
        int aligned = bottom
            ? plane == 0 ? surface.AlignedHeight : surface.UvAlignedHeight
            : plane == 0 ? surface.AlignedWidth : surface.UvAlignedWidth;
        int x = 320 >> ss, y = 192 >> ss, bs = 32 >> ss;
        for (int i = 0; i < bs; i++)
        {
            int position = (bottom ? y : x) + i;
            byte sample = position < visible ? (byte)100 : position < aligned ? (byte)200 : (byte)17;
            int index = bottom ? (y + i) * stride + x - 1 : (y - 1) * stride + x + i;
            pixels[index] = sample;
        }

        // A 64x64 superblock at (320,192), with a 32x32 luma / 16x16 chroma transform.
        MacroBlockD xd = new()
        {
            CurBuf = surface,
            MbToLeftEdge = -40 * 64,
            MbToTopEdge = -24 * 64,
            MbToRightEdge = (((surface.Width + 7) >> 3) - 40 - 8) * 64,
            MbToBottomEdge = (((surface.Height + 7) >> 3) - 24 - 8) * 64,
        };
        xd.Plane[plane].SubsamplingX = ss;
        xd.Plane[plane].SubsamplingY = ss;
        Span<byte> predicted = stackalloc byte[bs * bs];
        fixed (byte* dst = predicted)
        {
            ReconIntra.BuildIntraPredictors(ref xd, pixels.Slice(y * stride + x).ToPointer(), stride,
                dst, bs, PredictionMode.DcPred, ss == 0 ? TxSize.Tx32X32 : TxSize.Tx16X16,
                1, 1, 1, 0, 0, plane);
        }

        // VP9 DC prediction is (sum(top) + sum(left) + bs) / (2 * bs).
        // Bottom: Y (32*100 + 6*100 + 26*200 + 32)/64 = 141;
        // U/V (16*100 + 3*100 + 13*200 + 16)/32 = 141.
        // Right: Y (32*100 + 30*100 + 2*200 + 32)/64 = 103;
        // U/V (16*100 + 15*100 + 1*200 + 16)/32 = 103.
        // A crop already aligned to 8 has only 100-valued coded reference samples.
        int expected = cropped ? bottom ? 141 : 103 : 100;
        int bad = 0;
        foreach (byte value in predicted) if (value != expected) bad++;
        Console.WriteLine($"{(bad == 0 ? "PASS" : "FAIL")} plane={plane} {(bottom ? "bottom" : "right")} {(cropped ? "cropped" : "aligned")}: expected {expected}, actual first {predicted[0]}, wrong {bad}/{predicted.Length}");
        return bad == 0 ? 0 : 1;
    }

    static int Main()
    {
        int failures = 0;
        foreach (bool cropped in new[] { false, true })
            for (int plane = 0; plane < 3; plane++)
                foreach (bool bottom in new[] { false, true })
                    failures += Case(plane, bottom, cropped);
        Console.WriteLine($"vp9_intra_border: 12 cases, {failures} failures");
        return failures == 0 ? 0 : 1;
    }
}
