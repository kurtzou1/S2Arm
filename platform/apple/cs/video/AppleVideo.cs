using Ryujinx.Graphics.Nvdec;
using Ryujinx.Graphics.Video;

namespace S2A.Apple.Video
{
    // 苹果装配登记视频解码器（平台 adapter P1，#1069）：Host.Boot 之前调一次
    public static class AppleVideo
    {
        public static void Register()
        {
            S2AVideoDecoders.H264 = static () => new Ryujinx.Graphics.Nvdec.Apple.VideoToolboxH264Decoder();
            S2AVideoDecoders.Vp8 = static () => new Ryujinx.Graphics.Nvdec.Vpx.VpxVp8Decoder();   // 共用 libvpx 封装（安卓的 AndroidVp8Decoder 也包它）；VideoToolbox 不解 VP8
            // VP9：macOS 上 VideoToolbox 硬解优先（探针＝实建一次 64x64 会话，#348 的判据；注册 API 要 macOS 11 / iOS 26.2，
            // iOS 18 部署目标没有——iOS 与探针不过的 Mac 一律 libvpx），与安卓 MediaCodec 后端（#232）同一回退链：
            //   后端探针过 → 会话 / 单作业表示不了时按 Vp9NativePath 的既有机器逐级回退（libvpx 原生段 → 托管解码器）。
            //   硬解缺省关、S2A_NVDEC_VP9_VT=1 才开（缺省 libvpx 原生）；S2A_NVDEC_VP9=managed 关掉整条原生路径。
            S2AVideoDecoders.Vp9 = static () =>
                (IVp9NativeBackend)Ryujinx.Graphics.Nvdec.Apple.VideoToolboxVp9Backend.TryCreate() ??
                new Ryujinx.Graphics.Nvdec.Vpx.VpxVp9Backend();
            S2AVideoDecoders.Vp9DefaultMode = "native";   // 与安卓同一缺省（#247）：不登记时恒走托管解码器，P4G 类 VP9 过场吃满整核
        }
    }
}
