using Gommon;
using Ryujinx.Common.Logging;
using Ryujinx.HLE.Exceptions;
using Ryujinx.HLE.HOS.Ipc;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;

namespace Ryujinx.HLE.HOS.Services
{
    abstract class IpcService
    {
        public IReadOnlyDictionary<int, MethodInfo> CmifCommands { get; }
        public IReadOnlyDictionary<int, MethodInfo> TipcCommands { get; }

        public ServerBase Server { get; private set; }

        private IpcService _parent;
        // S2Arm: 延迟创建。域对象的表只有「转成域 / 加了域对象」的服务才用得到，而取子会话类命令
        //   （time:u 的各个时钟、hid 各句柄）每次请求都 new 一个服务、进构造就走不到这里，
        //   原来每建一个实例就 new IdDictionary + new ConcurrentDictionary，是 H05 普查里时钟命令剩下的那 1–2 KB。
        //   _selfId 也是 -1 表示「还没转域」，所以这里保持 null 与它一致。
        private IdDictionary _domainObjects;
        private int _selfId;
        private bool _isDomain;

        // cache array so we don't recreate it all the time
        private object[] _parameters = [null];

        // S2Arm: generated switch dispatch (S2AIpcDispatchGenerator) instead of MethodInfo.Invoke, zero allocation per request
        private readonly nint _s2aCmif;
        private readonly nint _s2aTipc;

        // S2Arm: 命令表按「服务类型」缓存一份。原来每个 IpcService 实例都在构造里重新解析一遍反射特性
        //   （GetMethods + GetCustomAttributes + SelectMany + ToDictionary），而「取子会话」类命令每次请求都 new 一个服务实例，
        //   于是游戏每帧读一次时钟就付 5–16 KB 的反射分配（H05 普查实测 time:u 三个时钟命令：16089 / 6995 / 5351 B）。
        //   同一类型的命令表恒定（特性是编译期常量，方法集合不随实例变），所以按类型缓存后这些命令降到 0 字节。
        //   ConcurrentDictionary：服务实例会在线程上并发创建（游戏线程 + 音频线程 + 各服务线程）。
        private static readonly ConcurrentDictionary<Type, IReadOnlyDictionary<int, MethodInfo>> _cmifCache = new();
        private static readonly ConcurrentDictionary<Type, IReadOnlyDictionary<int, MethodInfo>> _tipcCache = new();

        private static IReadOnlyDictionary<int, MethodInfo> BuildCmifCommands(Type type)
        {
            return type
                .GetMethods(BindingFlags.Instance | BindingFlags.Static | BindingFlags.Public)
                .SelectMany(methodInfo => methodInfo.GetCustomAttributes<CommandCmifAttribute>()
                .Select(command => (command.Id, methodInfo)))
                .ToDictionary(command => command.Id, command => command.methodInfo);
        }

        private static IReadOnlyDictionary<int, MethodInfo> BuildTipcCommands(Type type)
        {
            return type
                .GetMethods(BindingFlags.Instance | BindingFlags.Static | BindingFlags.Public)
                .SelectMany(methodInfo => methodInfo.GetCustomAttributes<CommandTipcAttribute>()
                    .Select(command => (command.Id, methodInfo)))
                .ToDictionary(command => command.Id, command => command.methodInfo);
        }

        public IpcService(ServerBase server = null, bool registerTipc = false)
        {
            Stopwatch sw = Stopwatch.StartNew();

            // S2Arm: 按类型缓存（见 _cmifCache 的注释）：同一服务类型的第二个实例起不再走反射解析
            CmifCommands = _cmifCache.GetOrAdd(GetType(), static t => BuildCmifCommands(t));

            sw.Stop();

            Logger.Debug?.Print(
                LogClass.Emulation,
                $"{CmifCommands.Count} Cmif commands loaded in {sw.ElapsedTicks} ticks ({Stopwatch.Frequency} tps).",
                GetType().AsPrettyString()
            );

            if (registerTipc)
            {
                sw.Start();

                TipcCommands = _tipcCache.GetOrAdd(GetType(), static t => BuildTipcCommands(t));

                sw.Stop();

                Logger.Debug?.Print(
                    LogClass.Emulation,
                    $"{TipcCommands.Count} Tipc commands loaded in {sw.ElapsedTicks} ticks ({Stopwatch.Frequency} tps).",
                    GetType().AsPrettyString()
                );
            }

            Server = server;

            (_s2aCmif, _s2aTipc) = S2AIpcDispatch.Lookup(GetType());

            _parent = this;
            _selfId = -1;
        }

        private IdDictionary DomainObjects => _domainObjects ??= new IdDictionary();

        public int ConvertToDomain()
        {
            if (_selfId == -1)
            {
                _selfId = DomainObjects.Add(this);
            }

            _isDomain = true;

            return _selfId;
        }

        public void ConvertToSession()
        {
            _isDomain = false;
        }

        public unsafe void CallCmifMethod(ServiceCtx context)
        {
            IpcService service = this;

            if (_isDomain)
            {
                int domainWord0 = context.RequestData.ReadInt32();
                int domainObjId = context.RequestData.ReadInt32();

                int domainCmd = (domainWord0 >> 0) & 0xff;
                int inputObjCount = (domainWord0 >> 8) & 0xff;
                int dataPayloadSize = (domainWord0 >> 16) & 0xffff;

                context.RequestData.BaseStream.Seek(0x10 + dataPayloadSize, SeekOrigin.Begin);

                context.Request.ObjectIds.EnsureCapacity(inputObjCount);

                for (int index = 0; index < inputObjCount; index++)
                {
                    context.Request.ObjectIds.Add(context.RequestData.ReadInt32());
                }

                context.RequestData.BaseStream.Seek(0x10, SeekOrigin.Begin);

                if (domainCmd == 1)
                {
                    service = GetObject(domainObjId);

                    context.ResponseData.Write(0L);
                    context.ResponseData.Write(0L);
                }
                else if (domainCmd == 2)
                {
                    Delete(domainObjId);

                    context.ResponseData.Write(0L);

                    return;
                }
                else
                {
                    throw new NotImplementedException($"Domain command: {domainCmd}");
                }
            }

#pragma warning disable IDE0059 // Remove unnecessary value assignment
            long sfciMagic = context.RequestData.ReadInt64();
#pragma warning restore IDE0059
            int commandId = (int)context.RequestData.ReadInt64();

            bool serviceExists = service.CmifCommands.TryGetValue(commandId, out MethodInfo processRequest);

            if (context.Device.Configuration.IgnoreMissingServices || serviceExists)
            {
                ResultCode result = ResultCode.Success;

                context.ResponseData.BaseStream.Seek(_isDomain ? 0x20 : 0x10, SeekOrigin.Begin);

                if (serviceExists)
                {
                    Logger.Trace?.Print(LogClass.KernelIpc, $"{service.GetType().Name}: {processRequest.Name}");

                    long direct = service._s2aCmif != 0
                        ? ((delegate*<IpcService, int, ServiceCtx, long>)service._s2aCmif)(service, commandId, context)
                        : S2AIpcDispatch.NotHandled;

                    if (direct != S2AIpcDispatch.NotHandled)
                    {
                        result = (ResultCode)direct;
                    }
                    else
                    {
                        _parameters[0] = context;

                        result = (ResultCode)processRequest.Invoke(service, _parameters);
                    }
                }
                else
                {
                    string serviceName = (service is not DummyService dummyService) ? service.GetType().FullName : dummyService.ServiceName;

                    Logger.Warning?.Print(LogClass.KernelIpc, $"Missing service {serviceName}: {commandId} ignored");
                }

                if (_isDomain)
                {
                    foreach (int id in context.Response.ObjectIds)
                    {
                        context.ResponseData.Write(id);
                    }

                    context.ResponseData.BaseStream.Seek(0, SeekOrigin.Begin);

                    context.ResponseData.Write(context.Response.ObjectIds.Count);
                }

                context.ResponseData.BaseStream.Seek(_isDomain ? 0x10 : 0, SeekOrigin.Begin);

                context.ResponseData.Write(IpcMagic.Sfco);
                context.ResponseData.Write((long)result);

                S2AIpcRecord.Command(service, commandId, context, (long)result, tipc: false);

                // S2Arm: a failing fs command is reported (S2AFsFail; upstream returns it silently)
                if (result != ResultCode.Success && service.GetType().Namespace?.StartsWith("Ryujinx.HLE.HOS.Services.Fs", StringComparison.Ordinal) == true)
                {
                    Fs.S2AFsFail.Report(service, commandId, context, (uint)result);
                }
            }
            else
            {
                string dbgMessage = $"{service.GetType().FullName}: {commandId}";

                throw new ServiceNotImplementedException(service, context, dbgMessage);
            }
        }

        public unsafe void CallTipcMethod(ServiceCtx context)
        {
            int commandId = (int)context.Request.Type - 0x10;

            bool serviceExists = TipcCommands.TryGetValue(commandId, out MethodInfo processRequest);

            if (context.Device.Configuration.IgnoreMissingServices || serviceExists)
            {
                ResultCode result = ResultCode.Success;

                context.ResponseData.BaseStream.Seek(0x4, SeekOrigin.Begin);

                if (serviceExists)
                {
                    Logger.Debug?.Print(LogClass.KernelIpc, $"{GetType().Name}: {processRequest.Name}");

                    long direct = _s2aTipc != 0
                        ? ((delegate*<IpcService, int, ServiceCtx, long>)_s2aTipc)(this, commandId, context)
                        : S2AIpcDispatch.NotHandled;

                    if (direct != S2AIpcDispatch.NotHandled)
                    {
                        result = (ResultCode)direct;
                    }
                    else
                    {
                        _parameters[0] = context;

                        result = (ResultCode)processRequest.Invoke(this, _parameters);
                    }
                }
                else
                {
                    string serviceName;

                    serviceName = (this is not DummyService dummyService) ? GetType().FullName : dummyService.ServiceName;

                    Logger.Warning?.Print(LogClass.KernelIpc, $"Missing service {serviceName}: {commandId} ignored");
                }

                context.ResponseData.BaseStream.Seek(0, SeekOrigin.Begin);

                context.ResponseData.Write((uint)result);

                S2AIpcRecord.Command(this, commandId, context, (long)result, tipc: true);
            }
            else
            {
                string dbgMessage = $"{GetType().FullName}: {commandId}";

                throw new ServiceNotImplementedException(this, context, dbgMessage);
            }
        }

        protected unsafe void MakeObject(ServiceCtx context, IpcService obj)
        {
            obj.TrySetServer(_parent.Server);

            if (_parent._isDomain)
            {
                obj._parent = _parent;

                context.Response.ObjectIds.Add(_parent.Add(obj));
            }
            else if (S2AHooks.MakeSession != null)
            {
                // S2Arm: direct dispatch, the sub-session is served on the caller's thread (see S2AHooks)
                context.Response.HandleDesc = IpcHandleDesc.MakeMove(S2AHooks.MakeSession(obj));
            }
            else
            {
                context.Device.System.KernelContext.Syscall.CreateSession(out int serverSessionHandle, out int clientSessionHandle, false, 0);

                obj.Server.AddSessionObj(serverSessionHandle, obj);

                context.Response.HandleDesc = IpcHandleDesc.MakeMove(clientSessionHandle);
            }
        }

        protected T GetObject<T>(ServiceCtx context, int index) where T : IpcService
        {
            int objId = context.Request.ObjectIds[index];

            IpcService obj = _parent.GetObject(objId);

            return obj is T t ? t : null;
        }

        public bool TrySetServer(ServerBase newServer)
        {
            if (Server == null)
            {
                Server = newServer;

                return true;
            }

            return false;
        }

        private int Add(IpcService obj)
        {
            // S2Arm instant snapshot replay: take the id this object had when the request was logged (S2AHooks.SnapForceDomainIds)
            var forced = S2AHooks.SnapForceDomainIds;

            if (forced != null && forced.Count > 0)
            {
                int id = forced.Dequeue();

                if (DomainObjects.Add(id, obj))
                {
                    return id;
                }

                S2AHooks.SnapForceDomainIdMiss++;
                // 原号被占：点名谁占着、本该是谁、改分到几号（2002-6457 恢复局两份诊断都有「原号被占」，只有计数看不出错位到哪个对象）
                int got = DomainObjects.Add(obj);
                Console.Error.WriteLine($"[s2a] 【黄】即时存档恢复：域对象原号 {id} 已被 {DomainObjects.GetData(id)?.GetType().Name ?? "?"} 占着，{obj.GetType().Name} 改分到 {got}（游戏按原号发给它的请求会落到占着的那个对象上）");
                return got;
            }

            return DomainObjects.Add(obj);
        }

        private bool Delete(int id)
        {
            object obj = _domainObjects?.Delete(id);

            if (obj is IDisposable disposableObj)
            {
                disposableObj.Dispose();
            }

            return obj != null;
        }

        private IpcService GetObject(int id)
        {
            return _domainObjects?.GetData<IpcService>(id);
        }

        // S2Arm: the direct dispatcher (services/S2A.Services HleTarget) needs these to write a well-formed error reply for a domain request
        // (domain out-header before SFCO) and to name the domain object a failing command was addressed to (the session root is not it)
        internal bool S2AIsDomain => _isDomain;

        internal string S2ADomainObjectName(int id) => GetObject(id)?.GetType().Name;
        internal string S2ADomainObjectFullName(int id) => GetObject(id)?.GetType().FullName;   // S2Arm 即时存档：同名接口（AM / FS 都有 IStorage）按命名空间分

        public void SetParent(IpcService parent)
        {
            _parent = parent._parent;
        }

        public virtual void DestroyAtExit()
        {
            if (_domainObjects == null)
            {
                return;
            }

            foreach (object domainObject in _domainObjects.Values)
            {
                if (domainObject != this && domainObject is IDisposable disposableObj)
                {
                    disposableObj.Dispose();
                }
            }

            _domainObjects.Clear();
        }
    }
}
