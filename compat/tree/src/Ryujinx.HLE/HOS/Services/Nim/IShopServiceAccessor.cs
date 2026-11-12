using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Services.Nim.ShopServiceAccessServerInterface.ShopServiceAccessServer.ShopServiceAccessor;

namespace Ryujinx.HLE.HOS.Services.Nim.ShopServiceAccessServerInterface.ShopServiceAccessServer
{
    class IShopServiceAccessor : IpcService
    {
        public IShopServiceAccessor(Horizon system) { }

        [CommandCmif(0)]
        // CreateAsyncInterface(u64) -> object<nn::ec::IShopServiceAsync>
        // Only the object, as yuzu and Skyline both answer it. With the extra copy handle this reply carried before, Minecraft (0100D71004694000) crashed in its
        // sdk right after the reply, reading address 0, on every boot.
        public ResultCode CreateAsyncInterface(ServiceCtx context)
        {
            MakeObject(context, new IShopServiceAsync());

            Logger.Stub?.PrintStub(LogClass.ServiceNim);

            return ResultCode.Success;
        }
    }
}
