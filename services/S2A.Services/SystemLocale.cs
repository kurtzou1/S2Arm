using Ryujinx.HLE.HOS.SystemState;
using System;
using System.Runtime.InteropServices;

namespace S2A.Services
{
    // 系统语言缺省跟设备（维护者 10-20：「都要装上以后默认是中文版哈（系统本身也是中文版的）」）：
    //   没给 S2A_SYSTEM_LANGUAGE 时按 iPhone / Mac 的系统首选语言（CFLocaleCopyPreferredLanguages，BCP 47 标签如 zh-Hans-CN）映射 Switch SystemLanguage；
    //   测试资产 / 对真值局显式给的 S2A_SYSTEM_LANGUAGE 照旧优先。游戏不支持该语言时按 TitleFallback 的四步选。
    //   不跟 App / 启动器界面语言（11-13 撤回同日的「跟界面」）：界面只有简 / 繁 / 英三种，日 / 韩语设备会被落成英语，游戏按语言换整套字体，
    //   Switch 上用日 / 韩 / 中文起的名字导入后成乱码。iOS 里玩家在 App 设置选过界面语言时本 App 的 AppleLanguages 就是它，首选列表第一项随之是它，
    //   所以「选过界面语言 → 游戏跟它」不另走一条路
    //   服务层是 InvariantGlobalization，CultureInfo 拿不到系统语言，所以直接调 CoreFoundation（iOS / macOS 同一个 C 接口）
    public static class SystemLocale
    {
        // BCP 47 标签 → Switch 系统语言；认不出返回 null（换首选列表里的下一个）
        public static SystemLanguage? Map(string tag)
        {
            if (string.IsNullOrEmpty(tag))
            {
                return null;
            }

            string[] p = tag.Replace('_', '-').ToLowerInvariant().Split('-');
            string lang = p[0];
            bool Has(string s) => Array.IndexOf(p, s, 1) >= 0;

            switch (lang)
            {
                case "zh":
                    // 有文字子标签按文字定；只有地区时：台 / 港 / 澳 = 繁体，其余简体
                    if (Has("hant")) return SystemLanguage.TraditionalChinese;
                    if (Has("hans")) return SystemLanguage.SimplifiedChinese;
                    return Has("tw") || Has("hk") || Has("mo") ? SystemLanguage.TraditionalChinese : SystemLanguage.SimplifiedChinese;
                case "ja": return SystemLanguage.Japanese;
                case "ko": return SystemLanguage.Korean;
                case "en": return Has("gb") || Has("au") || Has("nz") || Has("ie") || Has("in") || Has("za") ? SystemLanguage.BritishEnglish : SystemLanguage.AmericanEnglish;
                case "fr": return Has("ca") ? SystemLanguage.CanadianFrench : SystemLanguage.French;
                case "es": return p.Length == 1 || Has("es") ? SystemLanguage.Spanish : SystemLanguage.LatinAmericanSpanish;
                case "pt": return Has("br") ? SystemLanguage.BrazilianPortuguese : SystemLanguage.Portuguese;
                case "de": return SystemLanguage.German;
                case "it": return SystemLanguage.Italian;
                case "nl": return SystemLanguage.Dutch;
                case "ru": return SystemLanguage.Russian;
                case "pl": return SystemLanguage.Polish;
                case "th": return SystemLanguage.Thai;
                default: return null;
            }
        }

        // 首选语言列表里第一个认得的；都不认得（或取不到）回美式英语。来源写进 why 供日志
        public static SystemLanguage FromPreferred(string[] tags, out string why)
        {
            foreach (string t in tags)
            {
                SystemLanguage? l = Map(t);

                if (l.HasValue)
                {
                    why = $"系统首选语言 {t}";
                    return l.Value;
                }
            }

            why = tags.Length == 0 ? "取不到系统首选语言" : $"系统首选语言 {string.Join(",", tags)} 都没有对应的 Switch 语言";
            return SystemLanguage.AmericanEnglish;
        }

        // 游戏不支持主语言时依次试的语言（交 Ryujinx GetDesiredLanguage，S2AHooks.TitleLanguageFallback）。只看宿主主语言 primary（Host.Language）：
        //   维护者 11-13：「这款游戏不支持该语言就落到英文；英文也没有才用游戏自己的默认」「繁体对繁体、简体对简体，不要互相落」。
        //   ① 主语言 → ② 英语：美式、英式（主语言是英式时 ① 已试过） → ③ 都没有：游戏支持表第一项（上游，PickFallbackLanguage）。
        //   取代 11-03 / #445 的「同族变体（简 ↔ 繁）→ 英语 → 简中 / 繁中」：简中玩家遇到只有繁中的游戏不再落繁中，落英语
        public static TitleLanguage[] TitleFallback(SystemLanguage primary)
        {
            var r = new System.Collections.Generic.List<TitleLanguage>();
            void Add(TitleLanguage t) { if (!r.Contains(t)) r.Add(t); }
            if (Enum.TryParse(primary.ToString(), out TitleLanguage p)) Add(p);
            Add(TitleLanguage.AmericanEnglish); Add(TitleLanguage.BritishEnglish);
            return r.ToArray();
        }

        public static string[] Preferred()
        {
            IntPtr arr = CFLocaleCopyPreferredLanguages();

            if (arr == IntPtr.Zero)
            {
                return Array.Empty<string>();
            }

            try
            {
                long n = CFArrayGetCount(arr);
                string[] r = new string[n];
                byte[] buf = new byte[128];

                for (long i = 0; i < n; i++)
                {
                    IntPtr s = CFArrayGetValueAtIndex(arr, i);
                    r[i] = s != IntPtr.Zero && CFStringGetCString(s, buf, buf.Length, 0x08000100) ? System.Text.Encoding.UTF8.GetString(buf, 0, Array.IndexOf(buf, (byte)0)) : "";
                }

                return r;
            }
            finally
            {
                CFRelease(arr);
            }
        }

        private const string CF = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";

        [DllImport(CF)] private static extern IntPtr CFLocaleCopyPreferredLanguages();
        [DllImport(CF)] private static extern long CFArrayGetCount(IntPtr array);
        [DllImport(CF)] private static extern IntPtr CFArrayGetValueAtIndex(IntPtr array, long index);
        [DllImport(CF)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool CFStringGetCString(IntPtr s, byte[] buffer, long size, uint encoding);
        [DllImport(CF)] private static extern void CFRelease(IntPtr cf);
    }
}
