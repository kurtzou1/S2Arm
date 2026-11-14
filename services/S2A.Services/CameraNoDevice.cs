using Microsoft.IO;
using Ryujinx.Common.Memory;
using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Kernel.Threading;
using System;
using System.Buffers;
using System.Runtime.InteropServices;

namespace S2A.Services
{
    // Switch 2 摄像头会话（GameChat 视频用的 USB 摄像头）：nn::camera::sdk::CreateCameraContext 本来向图形系统的用户会话（gsv）要一个到摄像头服务的会话、
    //   当 UniqueNativeHandle（32 位句柄）交给游戏，游戏再用 SDK 的 HIPC 客户端经这个会话跟摄像头说话。宿主没有 gsv 会话，原先输出参数写 0：
    //   游戏对句柄 0 发 SendSyncRequest，会话不在会话表 → sdk 中止（诊断 #0148a6：一款 Switch 2 游戏 0400C3F00006E000 在 iPad 上 5 局都在这里 Break）。
    // 这里给一个真会话，按「接口有、没插摄像头的主机」答（做法与依据照 nxnative dm/host/hle_sf.c camera_answer，MIT）：
    //   命令 3（打开设备，名字 "Default"）、4（关闭）成功；21（摄像头事件）复制一个永不触发的事件的读端；其余（含 29 QueryDeviceConnection）回 0x7c4 =「没检测到摄像头设备」。
    sealed class CameraNoDevice : SessionTarget
    {
        private const uint NoDevice = 0x7c4;
        private KEvent _event;
        private static int s_said;

        public override string Name => "camera(gsv)";

        public override unsafe uint Process(Dispatcher d, byte* msg, int size)
        {
            IpcMessage request = new(new ReadOnlySpan<byte>(msg, Math.Min(size, 0x100)), (long)msg);
            IpcMessage response = new();
            Dispatcher.Streams s = Dispatcher.ThreadStreams;

            if (request.Type is IpcMessageType.CmifCloseSession or IpcMessageType.TipcCloseSession) return 0;

            if (request.Type is IpcMessageType.CmifControl or IpcMessageType.CmifControlWithContext)
            {
                s.Resp.SetLength(0);
                Control(d, BitConverter.ToUInt32(request.RawData, 8), response, s);
                response.RawData = s.Resp.ToArray();
                Write(msg, response);
                return 0;
            }

            if (request.Type is not (IpcMessageType.CmifRequest or IpcMessageType.CmifRequestWithContext))
            {
                Red.Report($"摄像头会话：消息类型未支持 {request.Type}");
                return 0xF601;
            }

            uint cmd = BitConverter.ToUInt32(request.RawData, 8);
            uint result = cmd switch { 3 or 4 or 21 => 0, _ => NoDevice };
            int eventHandle = 0;

            if (cmd == 21)
            {
                _event ??= new KEvent(d.Kernel);
                var rc = d.ServerProcess.HandleTable.GenerateHandle(_event.ReadableEvent, out eventHandle);
                if (rc != Ryujinx.Horizon.Common.Result.Success) { Red.Report($"摄像头会话：事件句柄分配失败 {rc.ErrorCode}"); result = NoDevice; eventHandle = 0; }
            }

            if (System.Threading.Interlocked.Exchange(ref s_said, 1) == 0)
                Console.Error.WriteLine($"[s2a] 摄像头会话：宿主没有摄像头，按「没插摄像头」答（首个命令 {cmd} → 0x{result:x}；3 / 4 成功、21 给永不触发的事件、其余 0x7c4）");

            s.Resp.SetLength(0);
            s.Writer.Write(IpcMagic.Sfco);
            s.Writer.Write((long)result);
            response.Type = IpcMessageType.CmifResponse;
            response.RawData = s.Resp.ToArray();

            if (eventHandle != 0)
            {
                response.HandleDesc = IpcHandleDesc.MakeCopy(eventHandle);
                uint kr = d.TranslateResponseHandles(response.HandleDesc);
                if (kr != 0) return kr;
            }

            Write(msg, response);
            return 0;
        }

        private static unsafe void Write(byte* msg, IpcMessage response)
        {
            RecyclableMemoryStream rs = response.GetStream((long)msg, 0);
            try { rs.GetReadOnlySequence().CopyTo(new Span<byte>(msg, (int)rs.Length)); }
            finally { MemoryStreamManager.Shared.ReleaseStream(rs); }
        }

        // 原生层 nn::camera::sdk::CreateCameraContext（graphics/nvn/gfx/nvn/nvn2.c）调：建一个摄像头会话，回游戏句柄（0 = 服务层没起）
        [UnmanagedCallersOnly(EntryPoint = "S2A_CameraSessionOpen")]
        private static uint Open()
        {
            Dispatcher d = Dispatcher.Instance;
            return d == null ? 0 : d.NewSessionHandle(new CameraNoDevice());
        }
    }
}
