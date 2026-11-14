using Ryujinx.Common.Logging;
using Ryujinx.HLE.Exceptions;
using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Kernel;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.Horizon.Common;
using System;

namespace Ryujinx.HLE.HOS.Services.Am.AppletAE.AllSystemAppletProxiesService.LibraryAppletCreator
{
    class ILibraryAppletAccessor : DisposableIpcService
    {
        private readonly KernelContext _kernelContext;

        private readonly IApplet _applet;

        private readonly AppletSession _normalSession;
        private readonly AppletSession _interactiveSession;

        private readonly KEvent _stateChangedEvent;
        private readonly KEvent _normalOutDataEvent;
        private readonly KEvent _interactiveOutDataEvent;

        private int _stateChangedEventHandle;
        private int _normalOutDataEventHandle;
        private int _interactiveOutDataEventHandle;

        private int _indirectLayerHandle;

        private readonly KEvent _cmd170Event;
        private int _cmd170EventHandle;

        public ILibraryAppletAccessor(AppletId appletId, Horizon system)
        {
            _kernelContext = system.KernelContext;

            _stateChangedEvent = new KEvent(system.KernelContext);
            _normalOutDataEvent = new KEvent(system.KernelContext);
            _interactiveOutDataEvent = new KEvent(system.KernelContext);
            _cmd170Event = new KEvent(system.KernelContext);

            _applet = AppletManager.Create(appletId, system);

            _normalSession = new AppletSession();
            _interactiveSession = new AppletSession();

            _applet.AppletStateChanged += OnAppletStateChanged;
            _normalSession.DataAvailable += OnNormalOutData;
            _interactiveSession.DataAvailable += OnInteractiveOutData;

            Logger.Info?.Print(LogClass.ServiceAm, $"Applet '{appletId}' created.");
        }

        private void OnAppletStateChanged(object sender, EventArgs e)
        {
            _stateChangedEvent.WritableEvent.Signal();
        }

        private void OnNormalOutData(object sender, EventArgs e)
        {
            _normalOutDataEvent.WritableEvent.Signal();
        }

        private void OnInteractiveOutData(object sender, EventArgs e)
        {
            _interactiveOutDataEvent.WritableEvent.Signal();
        }

        [CommandCmif(0)]
        // GetAppletStateChangedEvent() -> handle<copy>
        public ResultCode GetAppletStateChangedEvent(ServiceCtx context)
        {
            if (_stateChangedEventHandle == 0)
            {
                if (context.Process.HandleTable.GenerateHandle(_stateChangedEvent.ReadableEvent, out _stateChangedEventHandle) != Result.Success)
                {
                    throw new InvalidOperationException("Out of handles!");
                }
            }

            context.Response.HandleDesc = IpcHandleDesc.MakeCopy(_stateChangedEventHandle);

            return ResultCode.Success;
        }

        [CommandCmif(10)]
        // Start()
        public ResultCode Start(ServiceCtx context)
        {
            return (ResultCode)_applet.Start(_normalSession.GetConsumer(), _interactiveSession.GetConsumer());
        }

        [CommandCmif(20)]
        // RequestExit()
        public ResultCode RequestExit(ServiceCtx context)
        {
            // TODO: Since we don't support software Applet for now, we can just signals the changed state of the applet.
            _stateChangedEvent.ReadableEvent.Signal();

            Logger.Stub?.PrintStub(LogClass.ServiceAm);

            return ResultCode.Success;
        }

        [CommandCmif(30)]
        // GetResult()
        public ResultCode GetResult(ServiceCtx context)
        {
            return (ResultCode)_applet.GetResult();
        }

        [CommandCmif(60)]
        // PresetLibraryAppletGpuTimeSliceZero()
        public ResultCode PresetLibraryAppletGpuTimeSliceZero(ServiceCtx context)
        {
            // NOTE: This call reset two internal fields to 0 and one internal field to "true".
            //       It seems to be used only with software keyboard inline.
            //       Since we don't support applets for now, it's fine to stub it.

            Logger.Stub?.PrintStub(LogClass.ServiceAm);

            return ResultCode.Success;
        }
        
        [CommandCmif(90)]
        // Unknown90(ulong[4])
        public ResultCode Unknown90(ServiceCtx context)
        {
            // NOTE: This call is performed on SDK 20+ when applet is called.
            //       Since we don't support most applets for now, it's fine to stub it.
            //       Throw if values are not 0 to learn more about what this function does.

            if (context.RequestData.ReadUInt64() != 0 || context.RequestData.ReadUInt64() != 0 ||
                context.RequestData.ReadUInt64() != 0 || context.RequestData.ReadUInt64() != 0)
            {
                throw new ServiceNotImplementedException(this, context, $"{GetType().FullName}: 90");
            }

            Logger.Stub?.PrintStub(LogClass.ServiceAm);
            return ResultCode.Success;
        }

        [CommandCmif(100)]
        // PushInData(object<nn::am::service::IStorage>)
        public ResultCode PushInData(ServiceCtx context)
        {
            IStorage data = GetObject<IStorage>(context, 0);

            _normalSession.Push(data.Data.ToArray());

            return ResultCode.Success;
        }

        [CommandCmif(101)]
        // PopOutData() -> object<nn::am::service::IStorage>
        public ResultCode PopOutData(ServiceCtx context)
        {
            if (_normalSession.TryPop(out byte[] data))
            {
                MakeObject(context, new IStorage(data));

                _normalOutDataEvent.WritableEvent.Clear();

                return ResultCode.Success;
            }

            return ResultCode.NotAvailable;
        }

        [CommandCmif(103)]
        // PushInteractiveInData(object<nn::am::service::IStorage>)
        public ResultCode PushInteractiveInData(ServiceCtx context)
        {
            IStorage data = GetObject<IStorage>(context, 0);

            _interactiveSession.Push(data.Data.ToArray());

            return ResultCode.Success;
        }

        [CommandCmif(104)]
        // PopInteractiveOutData() -> object<nn::am::service::IStorage>
        public ResultCode PopInteractiveOutData(ServiceCtx context)
        {
            if (_interactiveSession.TryPop(out byte[] data))
            {
                MakeObject(context, new IStorage(data));

                _interactiveOutDataEvent.WritableEvent.Clear();

                return ResultCode.Success;
            }

            return ResultCode.NotAvailable;
        }

        [CommandCmif(105)]
        // GetPopOutDataEvent() -> handle<copy>
        public ResultCode GetPopOutDataEvent(ServiceCtx context)
        {
            if (_normalOutDataEventHandle == 0)
            {
                if (context.Process.HandleTable.GenerateHandle(_normalOutDataEvent.ReadableEvent, out _normalOutDataEventHandle) != Result.Success)
                {
                    throw new InvalidOperationException("Out of handles!");
                }
            }

            context.Response.HandleDesc = IpcHandleDesc.MakeCopy(_normalOutDataEventHandle);

            return ResultCode.Success;
        }

        [CommandCmif(106)]
        // GetPopInteractiveOutDataEvent() -> handle<copy>
        public ResultCode GetPopInteractiveOutDataEvent(ServiceCtx context)
        {
            if (_interactiveOutDataEventHandle == 0)
            {
                if (context.Process.HandleTable.GenerateHandle(_interactiveOutDataEvent.ReadableEvent, out _interactiveOutDataEventHandle) != Result.Success)
                {
                    throw new InvalidOperationException("Out of handles!");
                }
            }

            context.Response.HandleDesc = IpcHandleDesc.MakeCopy(_interactiveOutDataEventHandle);

            return ResultCode.Success;
        }

        [CommandCmif(110)]
        // NeedsToExitProcess()
        public ResultCode NeedsToExitProcess(ServiceCtx context)
        {
            return ResultCode.Stubbed;
        }

        [CommandCmif(150)]
        // RequestForAppletToGetForeground()
        public ResultCode RequestForAppletToGetForeground(ServiceCtx context)
        {
            return ResultCode.Stubbed;
        }

        [CommandCmif(160)] // 2.0.0+
        // GetIndirectLayerConsumerHandle() -> u64 indirect_layer_consumer_handle
        public ResultCode GetIndirectLayerConsumerHandle(ServiceCtx context)
        {
            Horizon horizon = _kernelContext.Device.System;

            _indirectLayerHandle = horizon.AppletState.IndirectLayerHandles.Add(_applet);

            context.ResponseData.Write((ulong)_indirectLayerHandle);

            return ResultCode.Success;
        }

        [CommandCmif(170)] // 22.0.0+
        // Cmd170() -> handle<copy>：无入参、回一个复制句柄（23.0.1 系统接口转储：inbytes 0、outhandles [copy]；另一实现同样回本小程序的一个可读事件）。
        //   事件语义没有公开资料；本机没有能让它触发的状态，事件从不 signal（与 GetAppletStateChangedEvent 同法建句柄、同一句柄重复回）。
        //   原先只回成功、不带句柄：客户端按协议取句柄会拿到 0
        public ResultCode Cmd170(ServiceCtx context)
        {
            if (_cmd170EventHandle == 0)
            {
                if (context.Process.HandleTable.GenerateHandle(_cmd170Event.ReadableEvent, out _cmd170EventHandle) != Result.Success)
                {
                    throw new InvalidOperationException("Out of handles!");
                }
            }

            context.Response.HandleDesc = IpcHandleDesc.MakeCopy(_cmd170EventHandle);

            Logger.Stub?.PrintStub(LogClass.ServiceAm);

            return ResultCode.Success;
        }

        protected override void Dispose(bool isDisposing)
        {
            if (isDisposing)
            {
                if (_stateChangedEventHandle != 0)
                {
                    _kernelContext.Syscall.CloseHandle(_stateChangedEventHandle);
                }

                if (_normalOutDataEventHandle != 0)
                {
                    _kernelContext.Syscall.CloseHandle(_normalOutDataEventHandle);
                }

                if (_interactiveOutDataEventHandle != 0)
                {
                    _kernelContext.Syscall.CloseHandle(_interactiveOutDataEventHandle);
                }

                if (_cmd170EventHandle != 0)
                {
                    _kernelContext.Syscall.CloseHandle(_cmd170EventHandle);
                }
            }

            Horizon horizon = _kernelContext.Device.System;

            horizon.AppletState.IndirectLayerHandles.Delete(_indirectLayerHandle);
        }
    }
}
