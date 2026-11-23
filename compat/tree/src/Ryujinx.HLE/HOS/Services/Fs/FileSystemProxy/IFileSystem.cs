using LibHac;
using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using Ryujinx.Common.Logging;
using Path = LibHac.FsSrv.Sf.Path;

namespace Ryujinx.HLE.HOS.Services.Fs.FileSystemProxy
{
    class IFileSystem : DisposableIpcService
    {
        private SharedRef<LibHac.FsSrv.Sf.IFileSystem> _fileSystem;
        private readonly string _s2aSaveKey;   // S2Arm: save data mount shared through S2ASaveShare (null for other file systems)
        private readonly bool _s2aGameSave;    // S2Arm: the application's account / device save: its Commit is a save point (11-01 全量审计 P1-20)
        // S2Arm: what this file system is (the command that opened it; for a save, its attributes), appended to fs failure lines (S2AFsFail).
        //   #2107 (11-23): a game probed and failed CreateFile on /EA SPORTS FC 27/mainmenuconfig.json and the line did not say on which mount
        public string S2AMount;

        public IFileSystem(ref SharedRef<LibHac.FsSrv.Sf.IFileSystem> provider, string s2aSaveKey = null, bool s2aGameSave = false)
        {
            _fileSystem = SharedRef<LibHac.FsSrv.Sf.IFileSystem>.CreateMove(ref provider);
            _s2aSaveKey = s2aSaveKey;
            _s2aGameSave = s2aGameSave;
        }

        // S2Arm instant snapshot: while the request log is replayed, an open that is in the log succeeded back then; if the path is gone
        //   now (deleted later, before the snapshot), create an empty one so the open succeeds and the object numbering after it stays
        //   the same, and register its removal for the end of the replay (S2AHooks.SnapReplayUndo).
        private bool S2AReplayPlaceholder(in Path name, bool directory)
        {
            if (!S2AHooks.SnapReplaying)
            {
                return false;
            }

            Result made = directory ? _fileSystem.Get.CreateDirectory(in name) : _fileSystem.Get.CreateFile(in name, 0, 0);

            if (made.IsFailure())
            {
                return false;
            }

            Path path = name;
            SharedRef<LibHac.FsSrv.Sf.IFileSystem> fs = SharedRef<LibHac.FsSrv.Sf.IFileSystem>.CreateCopy(in _fileSystem);

            S2AHooks.SnapReplayUndo.Add(() =>
            {
                Result r = directory ? fs.Get.DeleteDirectory(in path) : fs.Get.DeleteFile(in path);
                fs.Destroy();

                return r.IsSuccess();
            });

            return true;
        }

        public SharedRef<LibHac.FsSrv.Sf.IFileSystem> GetBaseFileSystem()
        {
            return SharedRef<LibHac.FsSrv.Sf.IFileSystem>.CreateCopy(in _fileSystem);
        }

        [CommandCmif(0)]
        // CreateFile(u32 createOption, u64 size, buffer<bytes<0x301>, 0x19, 0x301> path)
        public ResultCode CreateFile(ServiceCtx context)
        {
            ref readonly Path name = ref FileSystemProxyHelper.GetSfPath(context);

            int createOption = context.RequestData.ReadInt32();
            context.RequestData.BaseStream.Position += 4;

            long size = context.RequestData.ReadInt64();

            return (ResultCode)_fileSystem.Get.CreateFile(in name, size, createOption).Value;
        }

        [CommandCmif(1)]
        // DeleteFile(buffer<bytes<0x301>, 0x19, 0x301> path)
        public ResultCode DeleteFile(ServiceCtx context)
        {
            ref readonly Path name = ref FileSystemProxyHelper.GetSfPath(context);

            return (ResultCode)_fileSystem.Get.DeleteFile(in name).Value;
        }

        [CommandCmif(2)]
        // CreateDirectory(buffer<bytes<0x301>, 0x19, 0x301> path)
        public ResultCode CreateDirectory(ServiceCtx context)
        {
            ref readonly Path name = ref FileSystemProxyHelper.GetSfPath(context);

            return (ResultCode)_fileSystem.Get.CreateDirectory(in name).Value;
        }

        [CommandCmif(3)]
        // DeleteDirectory(buffer<bytes<0x301>, 0x19, 0x301> path)
        public ResultCode DeleteDirectory(ServiceCtx context)
        {
            ref readonly Path name = ref FileSystemProxyHelper.GetSfPath(context);

            return (ResultCode)_fileSystem.Get.DeleteDirectory(in name).Value;
        }

        [CommandCmif(4)]
        // DeleteDirectoryRecursively(buffer<bytes<0x301>, 0x19, 0x301> path)
        public ResultCode DeleteDirectoryRecursively(ServiceCtx context)
        {
            ref readonly Path name = ref FileSystemProxyHelper.GetSfPath(context);

            return (ResultCode)_fileSystem.Get.DeleteDirectoryRecursively(in name).Value;
        }

        [CommandCmif(5)]
        // RenameFile(buffer<bytes<0x301>, 0x19, 0x301> oldPath, buffer<bytes<0x301>, 0x19, 0x301> newPath)
        public ResultCode RenameFile(ServiceCtx context)
        {
            ref readonly Path currentName = ref FileSystemProxyHelper.GetSfPath(context, index: 0);
            ref readonly Path newName = ref FileSystemProxyHelper.GetSfPath(context, index: 1);

            return (ResultCode)_fileSystem.Get.RenameFile(in currentName, in newName).Value;
        }

        [CommandCmif(6)]
        // RenameDirectory(buffer<bytes<0x301>, 0x19, 0x301> oldPath, buffer<bytes<0x301>, 0x19, 0x301> newPath)
        public ResultCode RenameDirectory(ServiceCtx context)
        {
            ref readonly Path currentName = ref FileSystemProxyHelper.GetSfPath(context, index: 0);
            ref readonly Path newName = ref FileSystemProxyHelper.GetSfPath(context, index: 1);

            return (ResultCode)_fileSystem.Get.RenameDirectory(in currentName, in newName).Value;
        }

        [CommandCmif(7)]
        // GetEntryType(buffer<bytes<0x301>, 0x19, 0x301> path) -> nn::fssrv::sf::DirectoryEntryType
        public ResultCode GetEntryType(ServiceCtx context)
        {
            ref readonly Path name = ref FileSystemProxyHelper.GetSfPath(context);

            Result result = _fileSystem.Get.GetEntryType(out uint entryType, in name);

            context.ResponseData.Write((int)entryType);

            return (ResultCode)result.Value;
        }

        [CommandCmif(8)]
        // OpenFile(u32 mode, buffer<bytes<0x301>, 0x19, 0x301> path) -> object<nn::fssrv::sf::IFile> file
        public ResultCode OpenFile(ServiceCtx context)
        {
            uint mode = context.RequestData.ReadUInt32();

            ref readonly Path name = ref FileSystemProxyHelper.GetSfPath(context);
            using SharedRef<LibHac.FsSrv.Sf.IFile> file = new();

            Result result = _fileSystem.Get.OpenFile(ref file.Ref, in name, mode);

            if (result.IsFailure() && S2AReplayPlaceholder(in name, false))
            {
                result = _fileSystem.Get.OpenFile(ref file.Ref, in name, mode);
            }

            if (result.IsSuccess())
            {
                IFile fileInterface = new(ref file.Ref, name.ToString());   // S2Arm：带上路径，读失败 / 静默短读的黄字点名文件

                MakeObject(context, fileInterface);
            }

            return (ResultCode)result.Value;
        }

        [CommandCmif(9)]
        // OpenDirectory(u32 filter_flags, buffer<bytes<0x301>, 0x19, 0x301> path) -> object<nn::fssrv::sf::IDirectory> directory
        public ResultCode OpenDirectory(ServiceCtx context)
        {
            uint mode = context.RequestData.ReadUInt32();

            ref readonly Path name = ref FileSystemProxyHelper.GetSfPath(context);
            using SharedRef<LibHac.FsSrv.Sf.IDirectory> dir = new();

            Result result = _fileSystem.Get.OpenDirectory(ref dir.Ref, in name, mode);

            if (result.IsFailure() && S2AReplayPlaceholder(in name, true))
            {
                result = _fileSystem.Get.OpenDirectory(ref dir.Ref, in name, mode);
            }

            if (result.IsSuccess())
            {
                IDirectory dirInterface = new(ref dir.Ref);

                MakeObject(context, dirInterface);
            }

            return (ResultCode)result.Value;
        }

        [CommandCmif(10)]
        // Commit()
        public ResultCode Commit(ServiceCtx context)
        {
            ResultCode resultCode = (ResultCode)_fileSystem.Get.Commit().Value;

            // S2Arm: a committed save marks the touch-pad recording (formal runs replay the player's input from the last save).
            // Only the application's account / device save counts (what the save point copies): cache / temporary storage and every other
            // file system commit with success too (11-01 全量审计 P1-20)
            unsafe
            {
                if (resultCode == ResultCode.Success && _s2aGameSave && S2AHooks.SaveCommitted != null)
                {
                    S2AHooks.SaveCommitted();
                }
            }
            if (resultCode == ResultCode.PathAlreadyInUse)
            {
                Logger.Warning?.Print(LogClass.ServiceFs, "The file system is already in use by another process.");
            }

            return resultCode;
        }

        [CommandCmif(11)]
        // GetFreeSpaceSize(buffer<bytes<0x301>, 0x19, 0x301> path) -> u64 totalFreeSpace
        public ResultCode GetFreeSpaceSize(ServiceCtx context)
        {
            ref readonly Path name = ref FileSystemProxyHelper.GetSfPath(context);

            Result result = _fileSystem.Get.GetFreeSpaceSize(out long size, in name);

            context.ResponseData.Write(size);

            return (ResultCode)result.Value;
        }

        [CommandCmif(12)]
        // GetTotalSpaceSize(buffer<bytes<0x301>, 0x19, 0x301> path) -> u64 totalSize
        public ResultCode GetTotalSpaceSize(ServiceCtx context)
        {
            ref readonly Path name = ref FileSystemProxyHelper.GetSfPath(context);

            Result result = _fileSystem.Get.GetTotalSpaceSize(out long size, in name);

            context.ResponseData.Write(size);

            return (ResultCode)result.Value;
        }

        [CommandCmif(13)]
        // CleanDirectoryRecursively(buffer<bytes<0x301>, 0x19, 0x301> path)
        public ResultCode CleanDirectoryRecursively(ServiceCtx context)
        {
            ref readonly Path name = ref FileSystemProxyHelper.GetSfPath(context);

            return (ResultCode)_fileSystem.Get.CleanDirectoryRecursively(in name).Value;
        }

        [CommandCmif(14)]
        // GetFileTimeStampRaw(buffer<bytes<0x301>, 0x19, 0x301> path) -> bytes<0x20> timestamp
        public ResultCode GetFileTimeStampRaw(ServiceCtx context)
        {
            ref readonly Path name = ref FileSystemProxyHelper.GetSfPath(context);

            Result result = _fileSystem.Get.GetFileTimeStampRaw(out FileTimeStampRaw timestamp, in name);

            context.ResponseData.Write(timestamp.Created);
            context.ResponseData.Write(timestamp.Modified);
            context.ResponseData.Write(timestamp.Accessed);
            context.ResponseData.Write(1L); // Is valid?

            return (ResultCode)result.Value;
        }

        [CommandCmif(16)]
        public ResultCode GetFileSystemAttribute(ServiceCtx context)
        {
            Result result = _fileSystem.Get.GetFileSystemAttribute(out FileSystemAttribute attribute);

            context.ResponseData.Write(SpanHelpers.AsReadOnlyByteSpan(in attribute));

            return (ResultCode)result.Value;
        }

        protected override void Dispose(bool isDisposing)
        {
            if (isDisposing)
            {
                _fileSystem.Destroy();

                if (_s2aSaveKey != null)
                {
                    S2ASaveShare.Closed(_s2aSaveKey);
                }
            }
        }
    }
}
