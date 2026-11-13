// S2Arm: distinguish network-account setup from local-user selection.
using Microsoft.IO;
using Ryujinx.Common;
using Ryujinx.Common.Logging;
using Ryujinx.Common.Memory;
using Ryujinx.HLE.HOS.Services.Account.Acc;
using Ryujinx.HLE.HOS.Services.Am.AppletAE;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace Ryujinx.HLE.HOS.Applets
{
    internal class PlayerSelectApplet : IApplet
    {
        private readonly Horizon _system;

        private AppletSession _normalSession;
#pragma warning disable IDE0052 // Remove unread private member
        private AppletSession _interactiveSession;
#pragma warning restore IDE0052

        public event EventHandler AppletStateChanged;

        public PlayerSelectApplet(Horizon system)
        {
            _system = system;
        }

        public ResultCode Start(AppletSession normalSession, AppletSession interactiveSession)
        {
            _normalSession = normalSession;
            _interactiveSession = interactiveSession;

            // S2Arm: the second input storage is nn::account::UiSettings, mode first; mode 1 is UserCreator (ShowUserCreator).
            // On the console this applet creates a new user and answers success; the SDK hands the first word of the reply back
            // as ShowUserCreator's result and the game then lists users again. The host has no nickname / icon UI, so create the
            // user the console would end up with: the system default icon and an unused nickname. Answering "cancelled" instead
            // left "add new user" doing nothing (11-06 Brain Training); upstream opens the user selector and reports the
            // existing user as newly created, which adds no user either.
            _normalSession.TryPop(out _);
            uint mode = _normalSession.TryPop(out byte[] uiSettings) && uiSettings.Length >= 4 ? BitConverter.ToUInt32(uiSettings, 0) : 0;
            // S2Arm (#621 Taiko no Tatsujin Rhythm Festival): the network-service modes - EnsureNetworkServiceAccountAvailable (2) and the
            // license requirements for a network service (10, 11) - link or check a Nintendo Account online. The host is offline and the
            // account service says no network service account is linked (CheckAvailability -> NetworkServiceAccountRegistrationRequired),
            // so on a console with no connection the applet ends without one: answer it cancelled. Answering "selected the current user"
            // told the game the account was now usable; it checked again, still unlinked, and opened the applet again every frame
            // (1007 times in 17 s) instead of going on offline; Diablo II: Resurrected waited on its account setup forever (#634, #28).
            // The reply is a full UiReturnArg (24 bytes: result, then a zero Uid) with the account UI's cancellation result 2124-0001
            // (0x27C), which games take as "go on offline" (#634, albionlee), not the 8-byte generic failure word.
            if (mode is UiModeEnsureNetworkServiceAccountAvailable or UiModeLicenseRequirementsForNetworkService or UiModeLicenseRequirementsForNetworkServiceWithUserContext)
            {
                if (s_offlineAnswered.TryAdd(mode, 0))
                {
                    Logger.Info?.Print(LogClass.ServiceAm, $"Player select applet mode {mode} (network service account) answered cancelled: the host is offline and no network service account is linked");
                }
                _normalSession.Push(BuildCancelledResponse());
                AppletStateChanged?.Invoke(this, null);
                _system.ReturnFocus();

                return ResultCode.Success;
            }
            if (mode == UiModeUserCreator)
            {
                UserProfile created = CreatePlayerUser();
                Logger.Info?.Print(LogClass.ServiceAm, $"User creator applet created user {created.UserId} \"{created.Name}\" (no nickname / icon UI on the host)");
                _normalSession.Push(BuildResponse(created.UserId));
                AppletStateChanged?.Invoke(this, null);
                _system.ReturnFocus();

                return ResultCode.Success;
            }

            UserProfile selected = _system.Device.UIHandler.ShowPlayerSelectDialog();
            // S2Arm (#662 local multiplayer): UiSettings carries invalid_uid_list (8 Uids from offset 8), the users already playing.
            // When player 2 joins, the game opens this applet with player 1 in that list. The host UI answers the last opened user,
            // the game rejects it and opens the applet again (20+ times in 2 s, the second pad seems dead). On the console player 2
            // picks or creates another user: answer an existing user not in the list, else create one as UserCreator does.
            if (selected != null && uiSettings != null && uiSettings.Length >= InvalidUidListOffset + InvalidUidListCount * 16)
            {
                HashSet<UserId> invalid = new();
                for (int i = 0; i < InvalidUidListCount; i++)
                {
                    int at = InvalidUidListOffset + 16 * i;
                    UserId id = new(uiSettings[at..(at + 16)]);
                    if (!id.IsNull) invalid.Add(id);
                }
                if (invalid.Contains(selected.UserId))
                {
                    UserProfile other = _system.AccountManager.GetAllUsers().FirstOrDefault(u => !invalid.Contains(u.UserId)) ?? CreatePlayerUser();
                    Logger.Info?.Print(LogClass.ServiceAm, $"Player select applet mode {mode}: user {selected.UserId} is in the game's invalid list ({invalid.Count}), answered {other.UserId} \"{other.Name}\"");
                    selected = other;
                }
            }
            if (selected == null)
            {
                _normalSession.Push(BuildResponse());
            }
            else if (selected.UserId == new UserId("00000000000000000000000000000080"))
            {
                _normalSession.Push(BuildGuestResponse());
            }
            else
            {
                _normalSession.Push(BuildResponse(selected));
            }

            AppletStateChanged?.Invoke(this, null);

            _system.ReturnFocus();

            return ResultCode.Success;
        }

        // Adds a user the way the console's user creator would, with the default icon and a free PlayerN nickname (the host has
        // no nickname / icon UI).
        private UserProfile CreatePlayerUser()
        {
            AccountManager accounts = _system.AccountManager;
            // count + 1 candidates against count existing names: one is always free
            string name = Enumerable.Range(accounts.GetUserCount() + 1, accounts.GetUserCount() + 1)
                .Select(n => $"Player{n}").First(n => accounts.GetAllUsers().All(u => u.Name != n));
            UserId created = new(Guid.NewGuid().ToString("N"));
            accounts.AddUser(name, EmbeddedResources.Read("Ryujinx.HLE/HOS/Services/Account/Acc/DefaultUserImage.jpg"), created);
            return accounts.GetAllUsers().First(u => u.UserId == created);
        }

        private static byte[] BuildResponse(UserProfile selectedUser)
        {
            using RecyclableMemoryStream stream = MemoryStreamManager.Shared.GetStream();
            using BinaryWriter writer = new(stream);

            writer.Write((ulong)PlayerSelectResult.Success);

            selectedUser.UserId.Write(writer);

            return stream.ToArray();
        }

        private static byte[] BuildResponse(UserId createdUser)
        {
            using RecyclableMemoryStream stream = MemoryStreamManager.Shared.GetStream();
            using BinaryWriter writer = new(stream);

            writer.Write((ulong)PlayerSelectResult.Success);

            createdUser.Write(writer);

            return stream.ToArray();
        }

        private static byte[] BuildGuestResponse()
        {
            using RecyclableMemoryStream stream = MemoryStreamManager.Shared.GetStream();
            using BinaryWriter writer = new(stream);

            writer.Write(new byte());

            return stream.ToArray();
        }

        // nn::account::UiMode (libnx PselUiMode)
        private const uint UiModeUserCreator = 1;
        // nn::account::UiSettings (libnx PselUiSettings): u32 mode, u32 dialog type, then AccountUid invalid_uid_list[8]
        private const int InvalidUidListOffset = 8;
        private const int InvalidUidListCount = 8;
        private const uint UiModeEnsureNetworkServiceAccountAvailable = 2;
        private const uint UiModeLicenseRequirementsForNetworkService = 10;
        private const uint UiModeLicenseRequirementsForNetworkServiceWithUserContext = 11;
        private static readonly System.Collections.Concurrent.ConcurrentDictionary<uint, byte> s_offlineAnswered = new();   // modes already logged

        private static byte[] BuildCancelledResponse()
        {
            // UiReturnArg: u64 Result, then a 16-byte Uid. The SDK returns the
            // result directly; 2124-0001 is the account UI cancellation result.
            byte[] response = new byte[0x18];
            BitConverter.GetBytes(0x27CUL).CopyTo(response, 0);
            return response;
        }

        private static byte[] BuildResponse()
        {
            using RecyclableMemoryStream stream = MemoryStreamManager.Shared.GetStream();
            using BinaryWriter writer = new(stream);

            writer.Write((ulong)PlayerSelectResult.Failure);

            return stream.ToArray();
        }
    }
}
