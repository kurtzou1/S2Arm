// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using S2Arm.Launcher.Protocol;

// 启动器界面语言：第一次跟随系统（简中 / 繁中 / 英 / 日四种系统语言）；选过重启仍记住；选「跟随系统」回到跟随。
// 期望按规则手写：中文系统（简繁都算）→ zh-Hans，其余 → en。
public static class LauncherLanguageCases
{
    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "s2a-lang 中文 " + Guid.NewGuid().ToString("N"));
        try
        {
            check(LauncherLanguage.Resolve(root, "zh-CN") == "zh-Hans", "language: first launch, Simplified Chinese system");
            check(LauncherLanguage.Resolve(root, "zh-TW") == "zh-Hans", "language: first launch, Traditional Chinese system falls back to Simplified for now");
            check(LauncherLanguage.Resolve(root, "en-US") == "en", "language: first launch, English system");
            check(LauncherLanguage.Resolve(root, "ja-JP") == "en", "language: first launch, Japanese system falls back to English");
            LauncherLanguage.Save(root, "en");
            check(LauncherLanguage.Resolve(root, "zh-CN") == "en", "language: chosen English survives a restart on a Chinese system");
            LauncherLanguage.Save(root, "zh-Hans");
            check(LauncherLanguage.Resolve(root, "en-US") == "zh-Hans", "language: chosen Chinese survives a restart on an English system");
            LauncherLanguage.Save(root, null);
            check(LauncherLanguage.Saved(root) is null && LauncherLanguage.Resolve(root, "ja-JP") == "en", "language: follow system again after choosing it");
            File.WriteAllText(Path.Combine(root, LauncherLanguage.FileName), "klingon");
            check(LauncherLanguage.Resolve(root, "zh-CN") == "zh-Hans", "language: an unknown stored value is ignored");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
