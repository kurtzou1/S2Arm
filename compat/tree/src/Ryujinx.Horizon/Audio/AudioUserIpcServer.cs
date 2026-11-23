using Ryujinx.Horizon.Sdk.Audio.Detail;
using Ryujinx.Horizon.Sdk.Sf.Hipc;
using Ryujinx.Horizon.Sdk.Sm;

namespace Ryujinx.Horizon.Audio
{
    class AudioUserIpcServer
    {
        private const int MaxSessionsCount = 30;

        private const int PointerBufferSize = 0xB40;
        // S2Arm：audsmx:u 的客户端（Switch 2 SDK 的 CmifDomainProxyKind）连上就转域，域对象 = 会话管理 + 会话 + 每条外部流。
        //   开域只影响请求转域的客户端；本服务器其余服务的客户端不转域，行为不变
        private const int MaxDomains = 8;
        private const int MaxDomainObjects = 256;
        private const int MaxPortsCount = 1;

        private static readonly ManagerOptions _options = new(PointerBufferSize, MaxDomains, MaxDomainObjects, false);

        private SmApi _sm;
        private ServerManager _serverManager;
        private AudioManagers _managers;

        public void Initialize()
        {
            HeapAllocator allocator = new();

            _sm = new SmApi();
            _sm.Initialize().AbortOnFailure();

            _serverManager = new ServerManager(allocator, _sm, MaxPortsCount, _options, MaxSessionsCount);
            _managers = new AudioManagers(HorizonStatic.Options.AudioDeviceDriver, HorizonStatic.Options.TickSource);

            AudioRendererManager audioRendererManager = new(_managers.AudioRendererManager, _managers.AudioDeviceSessionRegistry);
            AudioOutManager audioOutManager = new(_managers.AudioOutputManager);
            AudioInManager audioInManager = new(_managers.AudioInputManager);
            FinalOutputRecorderManager finalOutputRecorderManager = new();
            AudioSnoopManager audioSnoopManager = new();

            _serverManager.RegisterObjectForServer(audioRendererManager, ServiceName.Encode("audren:u"), MaxSessionsCount);
            _serverManager.RegisterObjectForServer(audioOutManager, ServiceName.Encode("audout:u"), MaxSessionsCount);
            _serverManager.RegisterObjectForServer(audioInManager, ServiceName.Encode("audin:u"), MaxSessionsCount);
            _serverManager.RegisterObjectForServer(finalOutputRecorderManager, ServiceName.Encode("audrec:u"), MaxSessionsCount);
            _serverManager.RegisterObjectForServer(audioSnoopManager, ServiceName.Encode("auddev"), MaxSessionsCount);
            // S2Arm：Switch 2 SDK 的统一入口 aud:u，转给上面三个管理对象（Sdk/Audio/Detail/NativeAudioManager.cs）
            _serverManager.RegisterObjectForServer(new NativeAudioManager(audioInManager, audioOutManager, audioRendererManager), ServiceName.Encode("aud:u"), MaxSessionsCount);
            // S2Arm：Switch 2 的虚拟音频设备管理 auddmg:u（Sdk/Audio/Detail/AudioDeviceManager.cs）与系统混音器外部流 audsmx:u
            //   （Sdk/Audio/Detail/AudioSystemMixer.cs），两边按流号共用一份登记；外部流的声音交宿主声音输出（同 audout:u 的输出管理）
            //   输入流（麦克风，#2151）向宿主声音驱动直接要收音会话（同一个驱动，经兼容层：不支持收音的后端给静音）
            ExternalStreamRegistry externalStreams = new(_managers.AudioOutputManager, HorizonStatic.Options.AudioDeviceDriver);
            _serverManager.RegisterObjectForServer(new AudioDeviceManagerUserSessionManager(externalStreams), ServiceName.Encode("auddmg:u"), MaxSessionsCount);
            _serverManager.RegisterObjectForServer(new AudioSystemMixerUserSessionManager(externalStreams), ServiceName.Encode("audsmx:u"), MaxSessionsCount);
        }

        public void ServiceRequests()
        {
            _serverManager.ServiceRequests();
        }

        public void Shutdown()
        {
            _serverManager.Dispose();
            _managers.Dispose();
            _sm.Dispose();
        }
    }
}
