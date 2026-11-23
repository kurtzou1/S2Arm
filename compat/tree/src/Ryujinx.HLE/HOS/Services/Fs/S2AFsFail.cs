using LibHac.Fs;
using System;
using System.Text;

namespace Ryujinx.HLE.HOS.Services.Fs
{
    // S2Arm: fs commands that fail are reported (upstream returns the LibHac result silently; a game that ignores it then
    // crashes far away, e.g. 10-26 census Two Point Hospital writing through a null file object after a failed open).
    // Probing results a game is expected to handle (path not found / already exists, save data not found) are a plain line;
    // every other failure is red. Called from IpcService only when a command under Services.Fs returned non-zero.
    static class S2AFsFail
    {
        private const int ModuleFs = 2, PathNotFound = 1, PathAlreadyExists = 2, TargetNotFound = 1002;

        private static readonly string[] FileSystemCommands =
        {
            "CreateFile", "DeleteFile", "CreateDirectory", "DeleteDirectory", "DeleteDirectoryRecursively", "RenameFile", "RenameDirectory",
            "GetEntryType", "OpenFile", "OpenDirectory", "Commit", "GetFreeSpaceSize", "GetTotalSpaceSize", "CleanDirectoryRecursively",
            "GetFileTimeStampRaw", "QueryEntry",
        };

        private static readonly string[] FileCommands = { "Read", "Write", "Flush", "SetSize", "GetSize", "OperateRange", "OperateRangeWithBuffer" };

        // A command that failed on a save it parsed (OpenSaveDataFileSystem and kin) leaves what it asked for here; Report appends and clears it.
        //   11-23 D-HR6A: seven failing OpenSaveDataFileSystem (2002-1002) right before a crash, with nothing saying which save it was
        [ThreadStatic] public static string Extra;

        public static string SaveAttr(SaveDataSpaceId spaceId, in SaveDataAttribute a) =>
            $"存档 类型 {a.Type}、空间 {spaceId}、程序号 {a.ProgramId.Value:X16}、用户 {a.UserId.Id.High:X16}{a.UserId.Id.Low:X16}、序号 {a.Index}、系统存档号 {a.StaticSaveDataId:X16}";

        public static bool IsProbe(uint result)
        {
            uint module = result & 0x1ff, desc = (result >> 9) & 0x1fff;

            return module == ModuleFs && desc is PathNotFound or PathAlreadyExists or TargetNotFound;
        }

        public static string CommandName(IpcService service, int commandId)
        {
            string[] names = service switch
            {
                FileSystemProxy.IFileSystem => FileSystemCommands,
                FileSystemProxy.IFile => FileCommands,
                _ => null,
            };

            string type = service.GetType().Name;

            return names != null && (uint)commandId < (uint)names.Length ? $"{type}.{names[commandId]}" : $"{type} 命令 {commandId}";
        }

        public static void Report(IpcService service, int commandId, ServiceCtx context, uint result)
        {
            string extra = Extra;
            Extra = null;

            if (S2AHooks.FsFailed == null)
            {
                return;
            }

            StringBuilder detail = new();
            detail.Append($"{2000 + (result & 0x1ff)}-{(result >> 9) & 0x1fff:D4}");

            // Paths travel in pointer buffers (type 0x19, 0x301 bytes); renames carry two
            for (int i = 0; i < context.Request.PtrBuff.Count && i < 2; i++)
            {
                var buff = context.Request.PtrBuff[i];
                int len = (int)Math.Min(buff.Size, 0x301UL);

                if (len == 0)
                {
                    continue;
                }

                byte[] raw = new byte[len];
                context.Memory.Read(buff.Position, raw);
                int end = Array.IndexOf(raw, (byte)0);
                detail.Append(i == 0 ? "，路径 " : " → ").Append(Encoding.UTF8.GetString(raw, 0, end < 0 ? len : end));
            }

            if (extra != null)
            {
                detail.Append("，").Append(extra);
            }

            S2AHooks.FsFailed(CommandName(service, commandId), detail.ToString(), !IsProbe(result));
        }
    }
}
