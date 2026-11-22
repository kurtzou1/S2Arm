using Ryujinx.HLE.HOS.Applets.SoftwareKeyboard;

namespace Ryujinx.HLE.HOS.Applets
{
    public struct SoftwareKeyboardUIArgs
    {
        // S2Arm local-account dialog. Empty opens the creator directly; null is a game keyboard.
        public string[] LocalPlayerNames;
        public KeyboardMode KeyboardMode;
        public string HeaderText;
        public string SubtitleText;
        public string InitialText;
        public string GuideText;
        public string SubmitText;
        public int StringLengthMin;
        public int StringLengthMax;
    }
}
