using LibHac;
using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Shim;
using Ryujinx.Common;
using Ryujinx.Common.Logging;
using Ryujinx.Horizon.Sdk.Account;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;

namespace Ryujinx.HLE.HOS.Services.Account.Acc
{
    public class AccountManager : IEmulatorAccountManager
    {
        public static readonly UserId DefaultUserId = new("00000000000000010000000000000000");

        private readonly AccountSaveDataManager _accountSaveDataManager;

        // Todo: The account service doesn't have the permissions to delete save data. Qlaunch takes care of deleting
        // save data, so we're currently passing a client with full permissions. Consider moving save data deletion
        // outside of the AccountManager.
        private readonly HorizonClient _horizonClient;

        private readonly ConcurrentDictionary<string, UserProfile> _profiles;
        private string[] _userOrder = [];
        private UserProfile[] _storedOpenedUsers;

        public UserProfile LastOpenedUser { get; private set; }

        public AccountManager(HorizonClient horizonClient, string initialProfileName = null)
        {
            _horizonClient = horizonClient;

            _profiles = new ConcurrentDictionary<string, UserProfile>();
            _storedOpenedUsers = [];

            _accountSaveDataManager = new AccountSaveDataManager(_profiles);

            if (!_profiles.TryGetValue(DefaultUserId.ToString(), out _))
            {
                byte[] defaultUserImage = EmbeddedResources.Read("Ryujinx.HLE/HOS/Services/Account/Acc/DefaultUserImage.jpg");

                AddUser("RyuPlayer", defaultUserImage, DefaultUserId);

                OpenUser(DefaultUserId);
            }
            else
            {
                UserId commandLineUserProfileOverride = default;
                if (!string.IsNullOrEmpty(initialProfileName))
                {
                    commandLineUserProfileOverride = _profiles.Values.FirstOrDefault(x => x.Name == initialProfileName)?.UserId ?? default;
                    if (commandLineUserProfileOverride.IsNull)
                    {
                        Logger.Warning?.Print(LogClass.Application, $"The command line specified profile named '{initialProfileName}' was not found");
                    }
                }

                OpenUser(commandLineUserProfileOverride.IsNull ? _accountSaveDataManager.LastOpened : commandLineUserProfileOverride);
            }
        }

        public void AddUser(string name, byte[] image, UserId userId = new())
        {
            if (userId.IsNull)
            {
                userId = new UserId(Guid.NewGuid().ToString().Replace("-", string.Empty));
            }

            UserProfile profile = new(userId, name, image);

            _profiles.AddOrUpdate(userId.ToString(), profile, (key, old) => profile);

            _accountSaveDataManager.Save(_profiles);
        }

        public void OpenUser(UserId userId)
        {
            if (_profiles.TryGetValue(userId.ToString(), out UserProfile profile))
            {
                // TODO: Support multiple open users ?
                foreach (UserProfile userProfile in GetAllUsers())
                {
                    if (userProfile == LastOpenedUser)
                    {
                        userProfile.AccountState = AccountState.Closed;

                        break;
                    }
                }

                (LastOpenedUser = profile).AccountState = AccountState.Open;

                _accountSaveDataManager.LastOpened = userId;
            }

            _accountSaveDataManager.Save(_profiles);
        }

        public void CloseUser(UserId userId)
        {
            if (_profiles.TryGetValue(userId.ToString(), out UserProfile profile))
            {
                profile.AccountState = AccountState.Closed;
            }

            _accountSaveDataManager.Save(_profiles);
        }

        public void OpenUserOnlinePlay(Uid userId)
        {
            OpenUserOnlinePlay(new UserId((long)userId.Low, (long)userId.High));
        }

        public void OpenUserOnlinePlay(UserId userId)
        {
            if (_profiles.TryGetValue(userId.ToString(), out UserProfile profile))
            {
                // TODO: Support multiple open online users ?
                foreach (UserProfile userProfile in GetAllUsers())
                {
                    if (userProfile == LastOpenedUser)
                    {
                        userProfile.OnlinePlayState = AccountState.Closed;

                        break;
                    }
                }

                profile.OnlinePlayState = AccountState.Open;
            }

            _accountSaveDataManager.Save(_profiles);
        }

        public void CloseUserOnlinePlay(Uid userId)
        {
            CloseUserOnlinePlay(new UserId((long)userId.Low, (long)userId.High));
        }

        public void CloseUserOnlinePlay(UserId userId)
        {
            if (_profiles.TryGetValue(userId.ToString(), out UserProfile profile))
            {
                profile.OnlinePlayState = AccountState.Closed;
            }

            _accountSaveDataManager.Save(_profiles);
        }

        public void SetUserImage(UserId userId, byte[] image)
        {
            foreach (UserProfile userProfile in GetAllUsers())
            {
                if (userProfile.UserId == userId)
                {
                    userProfile.Image = image;

                    break;
                }
            }

            _accountSaveDataManager.Save(_profiles);
        }

        public void SetUserName(UserId userId, string name)
        {
            foreach (UserProfile userProfile in GetAllUsers())
            {
                if (userProfile.UserId == userId)
                {
                    userProfile.Name = name;

                    break;
                }
            }

            _accountSaveDataManager.Save(_profiles);
        }

        public void DeleteUser(UserId userId)
        {
            DeleteSaveData(userId);

            _profiles.Remove(userId.ToString(), out _);

            OpenUser(DefaultUserId);

            _accountSaveDataManager.Save(_profiles);
        }

        private void DeleteSaveData(UserId userId)
        {
            SaveDataFilter saveDataFilter = SaveDataFilter.Make(programId: default, saveType: default,
                new LibHac.Fs.UserId((ulong)userId.High, (ulong)userId.Low), saveDataId: default, index: default);

            using UniqueRef<SaveDataIterator> saveDataIterator = new();

            _horizonClient.Fs.OpenSaveDataIterator(ref saveDataIterator.Ref, SaveDataSpaceId.User, in saveDataFilter).ThrowIfFailure();

            Span<SaveDataInfo> saveDataInfo = stackalloc SaveDataInfo[10];

            while (true)
            {
                saveDataIterator.Get.ReadSaveDataInfo(out long readCount, saveDataInfo).ThrowIfFailure();

                if (readCount == 0)
                {
                    break;
                }

                for (int i = 0; i < readCount; i++)
                {
                    _horizonClient.Fs.DeleteSaveData(SaveDataSpaceId.User, saveDataInfo[i].SaveDataId).ThrowIfFailure();
                }
            }
        }

        internal int GetUserCount()
        {
            return _profiles.Count;
        }

        internal bool TryGetUser(UserId userId, out UserProfile profile)
        {
            return _profiles.TryGetValue(userId.ToString(), out profile);
        }

        public IEnumerable<UserProfile> GetAllUsers()
        {
            // S2Arm local players: the listed players first, in the host's order, then every other user on this device. Ordering only, never
            // hiding: users created before the list existed (PlayerN from the user creator) and their saves stay visible to the game.
            if (_userOrder.Length == 0) return _profiles.Values;
            return _userOrder.Select(key => _profiles.TryGetValue(key, out var user) ? user : null)
                .Where(user => user != null)
                .Concat(_profiles.Where(p => !_userOrder.Contains(p.Key)).OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => p.Value));   // fixed order: the dictionary has none
        }

        public void SetUserOrder(IEnumerable<UserId> orderedUsers)
        {
            _userOrder = orderedUsers.Select(id => id.ToString()).Distinct().ToArray();
        }

        internal IEnumerable<UserProfile> GetOpenedUsers()
        {
            return _profiles.Values.Where(x => x.AccountState == AccountState.Open);
        }

        // S2Arm: users the application itself has open. On the console nn::account::OpenUser is only
        // GetBaasAccountManagerForApplication and CloseUser only releases that IManagerForApplication, so "open"
        // as the application sees it lasts from creating the manager to releasing it. Upstream reports the
        // emulator's always-open default user instead: 10-26 census Let's Get Fit lists open users after its user
        // selector, finds the selected user already open, and closes a handle it never opened (CloseUser on null)
        private readonly ConcurrentDictionary<string, int> _applicationOpened = new();

        internal void ApplicationOpened(UserId userId)
        {
            _applicationOpened.AddOrUpdate(userId.ToString(), 1, (_, n) => n + 1);
        }

        internal void ApplicationClosed(UserId userId)
        {
            _applicationOpened.AddOrUpdate(userId.ToString(), 0, (_, n) => Math.Max(n - 1, 0));
        }

        internal IEnumerable<UserProfile> GetApplicationOpenedUsers()
        {
            return _profiles.Values.Where(x => _applicationOpened.TryGetValue(x.UserId.ToString(), out int n) && n > 0);
        }

        internal IEnumerable<UserProfile> GetStoredOpenedUsers()
        {
            return _storedOpenedUsers;
        }

        internal void StoreOpenedUsers()
        {
            _storedOpenedUsers = _profiles.Values.Where(x => x.AccountState == AccountState.Open).ToArray();
        }

        internal UserProfile GetFirst()
        {
            return _profiles.First().Value;
        }
    }
}
