using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.Horizon.Common;
using System;

namespace Ryujinx.HLE.HOS.Services.Nifm.StaticService
{
    class IRequest : IpcService
    {
        private enum RequestState
        {
            Error = 1,
            OnHold = 2,
            Available = 3,
        }

        private readonly KEvent _event0;
        private readonly KEvent _event1;

        private int _event0Handle;
        private int _event1Handle;

        // S2Arm: without internet access a real console answers a submitted request OnHold first, signals the request event,
        // then settles on Error (the request failed). Answering Error straight away made games that resubmit until the
        // request leaves OnHold (Hades: nn::nifm::SubmitNetworkRequest in a loop) spin on IPC without ever yielding,
        // starving the threads sharing the core (#1823, about 80 s in). Same timing as nxnative's offline fix.
        private bool _pendingOnHold;

#pragma warning disable IDE0052 // Remove unread private member
        private readonly uint _version;
#pragma warning restore IDE0052

        public IRequest(Horizon system, uint version)
        {
            _event0 = new KEvent(system.KernelContext);
            _event1 = new KEvent(system.KernelContext);

            _version = version;
        }

        [CommandCmif(0)]
        // GetRequestState() -> u32
        public ResultCode GetRequestState(ServiceCtx context)
        {
            RequestState requestState = context.Device.Configuration.EnableInternetAccess
                ? RequestState.Available
                : _pendingOnHold ? RequestState.OnHold : RequestState.Error;

            if (_pendingOnHold)
            {
                // First query after Submit saw OnHold; the request has now resolved: signal the state change, later queries see Error
                _pendingOnHold = false;
                _event0.ReadableEvent.Signal();
            }

            context.ResponseData.Write((int)requestState);

            Logger.Stub?.PrintStub(LogClass.ServiceNifm);

            return ResultCode.Success;
        }

        [CommandCmif(1)]
        // GetResult()
        public ResultCode GetResult(ServiceCtx context)
        {
            Logger.Stub?.PrintStub(LogClass.ServiceNifm);

            return GetResultImpl(context);
        }

        // S2Arm: consistent with GetRequestState — without internet access the request failed, so GetResult reports the
        // documented IRequest::GetResult error (Unknown112) instead of Success (a real console offline does the same)
        private static ResultCode GetResultImpl(ServiceCtx context)
        {
            return context.Device.Configuration.EnableInternetAccess ? ResultCode.Success : ResultCode.Unknown112;
        }

        [CommandCmif(2)]
        // GetSystemEventReadableHandles() -> (handle<copy>, handle<copy>)
        public ResultCode GetSystemEventReadableHandles(ServiceCtx context)
        {
            if (_event0Handle == 0)
            {
                if (context.Process.HandleTable.GenerateHandle(_event0.ReadableEvent, out _event0Handle) != Result.Success)
                {
                    throw new InvalidOperationException("Out of handles!");
                }
            }

            if (_event1Handle == 0)
            {
                if (context.Process.HandleTable.GenerateHandle(_event1.ReadableEvent, out _event1Handle) != Result.Success)
                {
                    throw new InvalidOperationException("Out of handles!");
                }
            }

            context.Response.HandleDesc = IpcHandleDesc.MakeCopy(_event0Handle, _event1Handle);

            return ResultCode.Success;
        }

        [CommandCmif(3)]
        // Cancel()
        public ResultCode Cancel(ServiceCtx context)
        {
            Logger.Stub?.PrintStub(LogClass.ServiceNifm);

            return ResultCode.Success;
        }

        [CommandCmif(4)]
        // Submit()
        public ResultCode Submit(ServiceCtx context)
        {
            Logger.Stub?.PrintStub(LogClass.ServiceNifm);

            // Offline: the first state query after this submit answers OnHold (see _pendingOnHold)
            _pendingOnHold = !context.Device.Configuration.EnableInternetAccess;

            return ResultCode.Success;
        }

        [CommandCmif(11)]
        // SetConnectionConfirmationOption(i8)
        public ResultCode SetConnectionConfirmationOption(ServiceCtx context)
        {
            Logger.Stub?.PrintStub(LogClass.ServiceNifm);

            return ResultCode.Success;
        }

        [CommandCmif(21)]
        // GetAppletInfo(u32) -> (u32, u32, u32, buffer<bytes, 6>)
        public ResultCode GetAppletInfo(ServiceCtx context)
        {
#pragma warning disable IDE0059 // Remove unnecessary value assignment
            uint themeColor = context.RequestData.ReadUInt32();
#pragma warning restore IDE0059

            Logger.Stub?.PrintStub(LogClass.ServiceNifm);

            ResultCode result = GetResultImpl(context);

            if (result == ResultCode.Success || (ResultCode)((int)result & 0x3fffff) == ResultCode.Unknown112)
            {
                return ResultCode.Unknown180;
            }

            // Returns appletId, libraryAppletMode, outSize and a buffer.
            // Returned applet ids- (0x19, 0xf, 0xe)
            // libraryAppletMode seems to be 0 for all applets supported.

            // TODO: check order
            context.ResponseData.Write(0xe); // Use error applet as default for now
            context.ResponseData.Write(0); // libraryAppletMode
            context.ResponseData.Write(0); // outSize

            return ResultCode.Success;
        }
    }
}
