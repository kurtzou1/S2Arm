using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Kernel.Threading;
using System;
using System.Text;

namespace Ryujinx.HLE.HOS.Services.Nim.ShopServiceAccessServerInterface.ShopServiceAccessServer.ShopServiceAccessor
{
    // S2Arm (#790): nn::ec::IShopServiceAsync, one eShop HTTP request a game prepares, starts and reads back. There is no eShop here, so every request
    // completes at once with an empty JSON object ("{}") and error code 0, as other implementations answer it (they found games fail on an empty body).
    // Command numbers and arguments follow the protocol documented for this interface: 0 Cancel, 1 GetSize, 2 Read, 3 GetErrorCode, 4 Request, 5 Prepare.
    // Before this, every command was unknown; Civilization VII calls Prepare once at boot and got the unknown-command failure.
    // Completion is this request's own event (its handle goes out with the object, IShopServiceAccessor): Request clears it, finishes, then signals it;
    // Cancel signals it too, so a waiter never hangs.
    class IShopServiceAsync : IpcService
    {
        private static readonly byte[] EmptyBody = Encoding.ASCII.GetBytes("{}");
        private byte[] _body = Array.Empty<byte>();

        public KEvent Completion { get; }

        public IShopServiceAsync(Horizon system) { Completion = new KEvent(system.KernelContext); }

        [CommandCmif(0)]
        // Cancel()
        public ResultCode Cancel(ServiceCtx context)
        {
            _body = Array.Empty<byte>();
            Completion.ReadableEvent.Signal();
            return ResultCode.Success;
        }

        [CommandCmif(1)]
        // GetSize() -> u64
        public ResultCode GetSize(ServiceCtx context)
        {
            context.ResponseData.Write((ulong)_body.Length);
            return ResultCode.Success;
        }

        [CommandCmif(2)]
        // Read(u64 offset) -> (u64 bytes_read, buffer<bytes, 0x22>)
        public ResultCode Read(ServiceCtx context)
        {
            ulong offset = context.RequestData.ReadUInt64();
            (ulong position, ulong size) = context.Request.GetBufferType0x22();
            ulong n = offset < (ulong)_body.Length ? Math.Min(size, (ulong)_body.Length - offset) : 0;
            if (n > 0) context.Memory.Write(position, _body.AsSpan((int)offset, (int)n));
            context.ResponseData.Write(n);
            return ResultCode.Success;
        }

        [CommandCmif(3)]
        // GetErrorCode() -> u32 (0 = the request succeeded)
        public ResultCode GetErrorCode(ServiceCtx context)
        {
            context.ResponseData.Write(0u);
            return ResultCode.Success;
        }

        [CommandCmif(4)]
        // Request(): starts the prepared request; it completes at once with an empty JSON body
        public ResultCode Request(ServiceCtx context)
        {
            Completion.ReadableEvent.Clear();
            _body = EmptyBody;
            Completion.ReadableEvent.Signal();
            Logger.Stub?.PrintStub(LogClass.ServiceNim, "no eShop: request completes with an empty JSON body");
            return ResultCode.Success;
        }

        [CommandCmif(5)]
        // Prepare(buffer<path, 0x5>, buffer<post data, 0x5>): records the URL path and body of the request; nothing to keep without an eShop
        public ResultCode Prepare(ServiceCtx context)
        {
            Logger.Stub?.PrintStub(LogClass.ServiceNim);
            return ResultCode.Success;
        }
    }
}
