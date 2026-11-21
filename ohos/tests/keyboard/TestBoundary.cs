// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Only unrelated IHostUIHandler types are bounded here. The actual keyboard
// implementation, host adapter, request arguments and interface are compiled.
namespace Ryujinx.HLE { public class Switch { } }
// Red.cs (compiled for real) only names the Ryujinx logger in StubSummary, which this test never calls.
namespace Ryujinx.Common.Logging
{
    public static class Logger
    {
        public static System.Collections.Generic.List<(string Name, long Count)> S2AStubHits() => new();
    }
}
// The shared HostUi (services/S2A.Services/Host.cs) is not compiled here: OhosHostUi only
// registers its SoftwareKeyboard hook, which is all this boundary exposes.
namespace S2A.Services
{
    public sealed class HostUi
    {
        public System.Func<Ryujinx.HLE.HOS.Applets.SoftwareKeyboardUIArgs, string> SoftwareKeyboard { get; set; }
    }
}
namespace Ryujinx.HLE.HOS.Applets { public struct ControllerAppletUIArgs { } }
namespace Ryujinx.HLE.HOS.Services.Account.Acc { public class UserProfile { } }
namespace Ryujinx.HLE.HOS.Services.Am.AppletOE.ApplicationProxyService.ApplicationProxy.Types
{ public enum ProgramSpecifyKind { } }
namespace Ryujinx.HLE.UI
{
    public interface IHostUITheme { }
    public interface IDynamicTextInputHandler { }
}
