using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Services.Nim.ShopServiceAccessServerInterface.ShopServiceAccessServer.ShopServiceAccessor;
using Ryujinx.Horizon.Common;
using System;

namespace Ryujinx.HLE.HOS.Services.Nim.ShopServiceAccessServerInterface.ShopServiceAccessServer
{
    class IShopServiceAccessor : IpcService
    {
        private readonly Horizon _system;

        public IShopServiceAccessor(Horizon system) { _system = system; }

        [CommandCmif(0)]
        // CreateAsyncInterface(u64) -> (handle<copy>, object<nn::ec::IShopServiceAsync>)
        // The copy handle is this request's own completion event, as the documented interface and Eden answer it: the game waits on it after Request.
        // Answered with the object alone (9404c53e), one game (0100C3601518C000) waited on it forever right after Request and never drew a frame.
        // The handle carried before 9404c53e was one event shared by every request and never signalled.
        public ResultCode CreateAsyncInterface(ServiceCtx context)
        {
            IShopServiceAsync async = new(_system);

            MakeObject(context, async);

            if (context.Process.HandleTable.GenerateHandle(async.Completion.ReadableEvent, out int handle) != Result.Success)
            {
                throw new InvalidOperationException("Out of handles!");
            }

            // Keep the object's move handle (a non-domain session hands the object out as a move handle in this same descriptor) and add the copy handle.
            // The handle carried before 9404c53e replaced the whole descriptor with the copy handle, so the object never reached the game: that was
            // the read of address 0 one game (0100D71004694000) hit right after this reply.
            context.Response.HandleDesc = new IpcHandleDesc(new[] { handle }, context.Response.HandleDesc?.ToMove ?? Array.Empty<int>());

            Logger.Stub?.PrintStub(LogClass.ServiceNim);

            return ResultCode.Success;
        }
    }
}
