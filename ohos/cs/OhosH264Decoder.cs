// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Graphics.Nvdec.FFmpeg.H264;
using Ryujinx.Graphics.Video;
using System;
using System.Runtime.InteropServices;

namespace S2A.Android.Aot;

// Selected only by the OHOS composition root. Other hosts keep their decoder.
internal sealed unsafe class OhosH264Decoder : IH264Decoder
{
    [DllImport("s2a_native")] private static extern nint s2a_ohos_h264_open(int width, int height, out int hardware);
    [DllImport("s2a_native")] private static extern int s2a_ohos_h264_decode(nint handle, byte* data, int length, byte* i420, int capacity);
    [DllImport("s2a_native")] private static extern void s2a_ohos_h264_close(nint handle);
    private nint _handle;
    private int _width, _height;
    private readonly byte[] _params = new byte[0x200];
    private byte[] _packet = new byte[0x10000];
    private bool _hardware;
    public bool IsHardwareAccelerated => _hardware;
    public ISurface CreateSurface(int width, int height) => new OhosVideoSurface(width, height);

    public bool Decode(ref H264PictureInfo picture, ISurface output, ReadOnlySpan<byte> bitstream)
    {
        if (picture.FieldPicFlag || picture.MbAdaptiveFrameFieldFlag || picture.ChromaFormatIdc != 1)
            throw new NotSupportedException("OHOS H264: interlaced/field or non-4:2:0 NVDEC picture is not implemented.");
        var surface = (OhosVideoSurface)output;
        if (_handle == 0 || surface.Width != _width || surface.Height != _height)
        {
            Dispose();
            _handle = s2a_ohos_h264_open(surface.Width, surface.Height, out int hardware);
            if (_handle == 0) throw new NotSupportedException("OHOS H264: no system decoder with decoding-order output.");
            _hardware = hardware != 0; _width = surface.Width; _height = surface.Height;
        }
        ReadOnlySpan<byte> headers = SpsAndPpsReconstruction.Reconstruct(ref picture, _params);
        int length = checked(headers.Length + bitstream.Length);
        if (length > 64 * 1024 * 1024) throw new InvalidOperationException("OHOS H264 packet exceeds 64 MiB limit.");
        if (_packet.Length < length) Array.Resize(ref _packet, length);
        headers.CopyTo(_packet);
        bitstream.CopyTo(_packet.AsSpan(headers.Length));
        int rc;
        fixed (byte* data = _packet)
            rc = s2a_ohos_h264_decode(_handle, data, length, surface.Data, surface.Length);
        if (rc != 0) throw new InvalidOperationException($"OHOS H264 decode failed ({rc}); no frame was written to guest memory.");
        return true;
    }
    public void Dispose()
    {
        if (_handle != 0) s2a_ohos_h264_close(_handle);
        _handle = 0;
    }
}

internal sealed unsafe class OhosVideoSurface : ISurface
{
    internal byte* Data;
    internal int Length { get; }
    public int Width { get; }
    public int Height { get; }
    public int Stride => Width;
    public int UvStride => Width / 2;
    public int UvWidth => Width / 2;
    public int UvHeight => Height / 2;
    public FrameField Field => FrameField.Progressive;
    public Plane YPlane => new((nint)Data, Width * Height);
    public Plane UPlane => new((nint)(Data + Width * Height), Width * Height / 4);
    public Plane VPlane => new((nint)(Data + Width * Height * 5 / 4), Width * Height / 4);
    internal OhosVideoSurface(int width, int height)
    {
        if (width <= 0 || height <= 0 || width > 8192 || height > 8192 || ((width | height) & 1) != 0)
            throw new ArgumentOutOfRangeException(nameof(width), "OHOS video requires bounded even dimensions.");
        Width = width; Height = height; Length = checked(width * height * 3 / 2);
        Data = (byte*)NativeMemory.Alloc((nuint)Length);
        if (Data == null) throw new OutOfMemoryException();
    }
    public void Dispose() { NativeMemory.Free(Data); Data = null; }
}
