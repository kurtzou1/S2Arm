// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.IO;
using System.Text;
using LibHac.Common;
using LibHac.Ns;
using LibHac.Loader;
using Ryujinx.HLE.Loaders.Processes;

namespace S2A.Services.Tests
{
    // IApplicationFunctions 29 GetCacheStorageMax（0100D71004694000 在 nnMain 一开始就问，原先未知命令 2010-0221 → 游戏 Break、进不去）：
    //   生产 HIPC/CMIF 分发走 appletOE → OpenApplicationProxy → GetApplicationFunctions（20）→ 29。期望按协议手写：回游戏自己控制数据里的
    //   缓存存档上限——u32 序号上限（按 8 字节对齐占 @0，同本接口命令 27 的 u32 + u64 回包）、u64 数据加日志尺寸上限 @8
    public static unsafe partial class Program
    {
        [SoloTest("--cache-storage-max", Booted = true)]
        static void CacheStorageMax()
        {
            string npdmPath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../compat/tree/src/Ryujinx.HLE/Homebrew.npdm"));
            MetaLoader meta = new();
            meta.Load(File.ReadAllBytes(npdmPath)).ThrowIfFailure();
            meta.GetNpdm(out Npdm npdm).ThrowIfFailure();
            BlitStruct<ApplicationControlProperty> nacp = new(1);
            nacp.Value.CacheStorageIndexMax = 3;
            nacp.Value.CacheStorageDataAndJournalSizeMax = 0x12340000;
            Host.Device.Processes.S2ARegisterApplication(new ProcessResult(meta, nacp, false, false, null,
                FakeNative.GamePid, 0, npdm.Meta.MainThreadPriority, npdm.Meta.MainThreadStackSize, Host.Device.System.State.DesiredTitleLanguage));

            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            uint oe = Call(sm, Msg.Cmif(1, Name8("appletOE"))).Move[0];
            Msg cd = Msg.Cmif(0); cd.Type = 5;
            int root = *(int*)Call(oe, cd).Data;
            Reply Domain(Msg m, int obj) { m.DomainObject = obj; m.Write(_tlr); Svc(0x21, FakeNative.CookieOf(oe)); return Reply.ParseDomain(_tlr); }
            Msg opx = Msg.Cmif(0, Bytes(0UL)); opx.SendPid = true;
            int proxy = *(int*)Domain(opx, root).Data;                      // OpenApplicationProxy
            int funcs = *(int*)Domain(Msg.Cmif(20), proxy).Data;            // GetApplicationFunctions
            Reply r = Domain(Msg.Cmif(29), funcs);
            Check("GetCacheStorageMax（命令 29）：结果 / 序号上限 / 尺寸上限（控制数据 3 / 0x12340000）", "0 / 3 / 0x12340000",
                  r.Result != 0 ? $"0x{r.Result:X}" : $"{r.Result} / {*(uint*)r.Data} / 0x{*(ulong*)(r.Data + 8):X}");

            FakeNative.HandleClose(oe); FakeNative.HandleClose(sm);
        }
    }
}
