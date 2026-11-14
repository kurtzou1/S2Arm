namespace Ryujinx.HLE
{
    // Called only after guest/service threads have exited and Switch.Dispose returned.
    // These upstream singletons otherwise retain the old kernel, file system or guest addresses.
    internal static unsafe class S2ASessionState
    {
        internal static void End()
        {
            HOS.Services.Fs.S2ASaveShare.CloseAll();
            Ryujinx.HLE.FileSystem.S2ASaveSpace.Reset();
            HOS.Services.Sockets.Bsd.BsdContext.S2AReset();
            HOS.Services.Sockets.Bsd.Proxy.SocketHelpers.UnregisterProxy();
            HOS.Services.Nv.NvDrvServices.NvMap.NvMapDeviceFile.S2AReset();
            HOS.Services.SurfaceFlinger.HOSBinderDriverServer.S2AReset();
            HOS.Services.Time.TimeManager.S2AReset();
            HOS.Services.Mii.DatabaseImpl.S2AReset();
            HOS.Services.Ssl.BuiltInCertificateManager.S2AReset();
            HOS.Services.Bluetooth.BluetoothDriver.BluetoothEventManager.S2AReset();
            S2AHooks.MakeSession = null;
            S2AHooks.StartHorizonService = null;
            S2AHooks.EventSignal = null;
            S2AHooks.EventClear = null;
            S2AHooks.SaveCommitted = null;
            S2AHooks.TickSource = null;
            S2AHooks.GuestView = null;
            S2AHooks.OpenSystemDataStorage = null;
            S2AHooks.SystemDataFallback = null;
            S2AHooks.OpenAocDataStorage = null;
            S2AHooks.TimeZoneDataDir = null;
            S2AHooks.SharedFontDir = null;
            S2AHooks.SystemDataRoot = null;
            S2AHooks.SystemDataAsked = null;
            S2AHooks.FsFailed = null;
            S2AHooks.LdnInitializing = null;
            S2AHooks.Red = null;
        }
    }
}
