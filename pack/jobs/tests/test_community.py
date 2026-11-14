"""社区资源（pack/jobs/community.py，10-27 维护者 01:4x 口径）：宽屏 / 60 帧是宿主开关（缺省开、可关），版本不符走跨版本定位不判死，
画面同互斥组单选；Mac 启动按选择设 S2A_WIDESCREEN=0 / S2A_FPS60=0。期望按规则手写"""
import json, os, shutil, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import community
import layout
from core import Failure

GID = "0100C2500FC20000"


REPO = Path(__file__).resolve().parents[3]


class Ctx:
    def __init__(self, root):
        self.library, self.engine, self.private, self.r = root / "lib", root / "engine", root / "priv", {"gameId": GID}
        table = self.engine / community.SETTINGS_TABLE   # 定义表用仓库里的真表
        table.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(REPO / community.SETTINGS_TABLE, table)
    def begin(self, *a): pass


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text, encoding="utf-8")


class CommunityTests(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.c = Ctx(self.t)
        write(self.c.library / "catalog.json", json.dumps({"games": [{"id": GID, "packages": [
            {"type": "base", "version": 0, "display": "1.0.0", "builds": {"main": "AAAA"}},
            {"type": "update", "version": 1 << 16, "display": "4.1.0", "builds": {}}]}]}))
        write(self.c.engine / "graphics/widen/tables/verified.tsv", "# 注释\n程序号\t构建号\t款\t登记日期\t依据\n" + GID + "\taaaa\tspl3\t2026-10-27\t实测\n")
        # 这款 Mac 包里编进去的补丁（产物 cpatch.tsv，11-12 出包时自动查库）：宽屏 / 画面各一份、帧率一份（跟 60 帧开关，不列）、金手指一条（金手指一栏，不列）
        write(layout.image_mac(self.c, GID) / "cpatch.tsv", "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\n"
              "widescreen:aa\tmain\t0\twidescreen\t21:9\tMIT\tx.pchtxt\t\t0\ngfx:bb\tmain\t1\tgfx\t关动态模糊\t\ty.pchtxt\t\t0\n"
              "fps:cc\tmain\t2\tfps\t60 FPS\t\tz.pchtxt\t\t0\ncheat:dd:1\tmain\t-\tcheat\t无限血\t\tc.txt\t\t0\n")
        cd = self.t / "cp"; os.environ["S2A_COMMUNITY_DIR"] = str(cd)
        write(cd / "fps/full/x/INDEX.tsv", "game\ttitle_id\tversion\tbuild_id\ttype\ttarget_fps\tsource\tin_pack\tsha256\n"
              f"Spl\t{GID}\t1.1.1\t\tpchtxt\t60\tfpsrepo\tyes\tabc\nSpl\t{GID}\t4.1.0\t\tpchtxt\t30\tother30\tyes\tdef\n")
        write(cd / "uw/full/y/INDEX.tsv", "game\ttitle_id\tversion\tbuild_id\taspect\tkind\tui_fix\tsource\tin_pack\tsha256\n"
              f"Spl\t{GID}\t4.1.0\t\t21:9\tpchtxt\tyes\tuwrepo\tyes\t111\n")

    def test_defaults_and_sources(self):
        r = community.listing(self.c)
        ws, fps = r["widescreen"], r["fps60"]
        self.assertEqual((ws["available"], ws["verified"], ws["enabled"], ws["sources"], ws["relocate"]), (True, True, True, ["uwrepo"], False))
        self.assertEqual((fps["available"], fps["verified"], fps["enabled"], fps["sources"], fps["relocate"]), (True, False, True, ["fpsrepo"], True))   # 1.1.1≠4.1.0：跨版本定位、不判死；30 帧那条不算
        self.assertEqual([(it["id"], it["enabled"], it["license"]) for it in r["graphics"]], [("widescreen:aa", True, "MIT"), ("gfx:bb", True, "")])   # 11-13 起没选过 = 默认开（Mac 画面类也开）；帧率 / 金手指不在这里

    def test_save_and_launch_env(self):
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_CPATCH_ON": "gfx:bb,widescreen:aa", "S2A_WIDESCREEN": "0"})   # 没选过：包里的补丁全开（11-13），开着宽屏补丁 S2Arm 满屏让开；60 帧由宿主定
        self.c.r.update(settings={"widescreen": False, "fps60": False}, graphics={"gfx:bb": True})
        community.save(self.c)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_WIDESCREEN": "0", "S2A_FPS60": "0", "S2A_CPATCH_ON": "gfx:bb,widescreen:aa"})   # 玩家明确关：写 0；没关过的补丁照开
        self.c.r = {"gameId": GID, "graphics": {"widescreen:aa": True}}
        r = community.save(self.c); g = {it["id"]: it for it in r["graphics"]}
        self.assertEqual((g["widescreen:aa"]["enabled"], g["gfx:bb"]["enabled"]), (True, True))
        self.assertEqual({k: v for k, v in community.launch_env(self.c, GID).items() if k in ("S2A_CPATCH_ON", "S2A_WIDESCREEN")},
                         {"S2A_CPATCH_ON": "gfx:bb,widescreen:aa", "S2A_WIDESCREEN": "0"})   # 开着宽屏补丁：S2Arm 满屏让开
        self.assertEqual((r["widescreen"]["enabled"], r["fps60"]["enabled"]), (False, False))       # 没带的项不变
        self.c.r = {"gameId": GID, "graphics": {"nope": True}}
        with self.assertRaises(Failure): community.save(self.c)

    def test_game_language(self):
        # 游戏语言（启动设置页）：跟随系统不设变量（宿主读系统首选语言）；选了哪种就把宿主枚举名交给 S2A_SYSTEM_LANGUAGE；不在表里的值拒收
        self.c.r.update(settings={"language": "system"}); community.save(self.c)
        self.assertNotIn("S2A_SYSTEM_LANGUAGE", community.launch_env(self.c, GID))
        self.c.r = {"gameId": GID, "settings": {"language": "Japanese"}}; community.save(self.c)
        self.assertEqual(community.launch_env(self.c, GID)["S2A_SYSTEM_LANGUAGE"], "Japanese")
        self.c.r = {"gameId": GID, "settings": {"language": "Klingon"}}
        with self.assertRaises(Failure): community.save(self.c)

    def test_audio_latency(self):
        # 声音延迟（11-14 维护者收 PR #1066 进启动设置）：标准不设变量（设备默认）；低 / 最低 = 请求设备 IO 缓冲 128 / 32 帧；不在表里的值拒收
        self.assertNotIn("S2A_AUDIO_BUFFER_FRAMES", community.launch_env(self.c, GID))
        for v, frames in (("low", "128"), ("lowest", "32")):
            self.c.r = {"gameId": GID, "settings": {"audioLatency": v}}; community.save(self.c)
            self.assertEqual(community.launch_env(self.c, GID)["S2A_AUDIO_BUFFER_FRAMES"], frames)
        self.c.r = {"gameId": GID, "settings": {"audioLatency": "standard"}}; community.save(self.c)
        self.assertNotIn("S2A_AUDIO_BUFFER_FRAMES", community.launch_env(self.c, GID))
        self.c.r = {"gameId": GID, "settings": {"audioLatency": "16"}}
        with self.assertRaises(Failure): community.save(self.c)
    def test_game_language_only_supported(self):
        # 11-14 维护者「按你的建议加上」：只列这款 control.nacp 支持的语言；系统语言不支持时在设置里写明起局用哪种（不弹窗）。期望按 NACP 位序手算
        def nacp(*bits):
            raw = bytearray(0x4000); raw[0x302C:0x3030] = sum(1 << b for b in bits).to_bytes(4, "little"); return bytes(raw)
        self.assertEqual(community.nacp_languages(nacp(0, 2, 13, 14)), ["AmericanEnglish", "Japanese", "TraditionalChinese", "SimplifiedChinese"])
        self.assertEqual(community.nacp_languages(nacp()), [])            # 合成的 nacp 不声明：不知道
        self.assertEqual(community.nacp_languages(b"short"), [])
        ctl = layout.image_mac(self.c, GID) / "ctl" / "control.nacp"
        self.assertNotIn("choices", community.mac_settings(self.c, GID)["language"])   # 还没出包（没有 nacp）：照旧列全部
        write(ctl, ""); ctl.write_bytes(nacp(0, 2, 14))                      # 美英、日、简中
        os.environ["S2A_TEST_PREFERRED_LANGUAGES"] = "zh-Hans-CN,en-US"
        try:
            lang = community.mac_settings(self.c, GID)["language"]
            self.assertEqual(lang["choices"], ["system", "AmericanEnglish", "Japanese", "SimplifiedChinese"])
            self.assertNotIn("note", lang)                                    # 系统简中、这款有：不标
            os.environ["S2A_TEST_PREFERRED_LANGUAGES"] = "ko-KR"
            self.assertEqual(community.mac_settings(self.c, GID)["language"]["note"],
                             {"zh-Hans": "这款不支持한국어，起局用English (US)。", "en": "This game doesn't have 한국어; it starts in English (US)."})
            ctl.write_bytes(nacp(2, 13))                                       # 没有英语：落支持表第一项（日语）
            self.assertEqual(community.mac_settings(self.c, GID)["language"]["note"]["zh-Hans"], "这款不支持한국어，起局用日本語。")
            self.c.r = {"gameId": GID, "settings": {"language": "German"}}; community.save(self.c)
            self.assertEqual(community.mac_settings(self.c, GID)["language"]["note"]["zh-Hans"], "这款不支持Deutsch，起局用日本語。")   # 选过的语言这款没有也标
        finally:
            del os.environ["S2A_TEST_PREFERRED_LANGUAGES"]
        # 系统语言映射照宿主 SystemLocale.Map；实际语言照 TitleFallback：想要的 → 美式 / 英式英语 → 支持表第一项
        for tags, want in ((["zh-Hant-HK"], "TraditionalChinese"), (["zh-HK"], "TraditionalChinese"), (["zh-CN"], "SimplifiedChinese"), (["en-GB"], "BritishEnglish"),
                           (["es-MX"], "LatinAmericanSpanish"), (["es"], "Spanish"), (["pt-BR"], "BrazilianPortuguese"), (["fr-CA"], "CanadianFrench"), (["xx", "ja-JP"], "Japanese"), ([], "AmericanEnglish")):
            self.assertEqual(community.system_title_language(tags), want, tags)
        self.assertEqual(community.effective_language("Korean", ["BritishEnglish", "Japanese"]), "BritishEnglish")
        self.assertEqual(community.effective_language("Korean", []), "Korean")

    def test_game_language_ios_same_as_table(self):
        # 游戏语言 iOS 下拉（ios/settings.m s2a_ios_game_languages、ios/app_settings.m 的标签）与定义表 language 的 options 同值同序、条数相同；
        #   每个值都是宿主 SystemLanguage 枚举名（compat/tree/.../SystemLanguage.cs）、iOS 平台在表里声明了
        import re
        item = next(i for i in json.loads((REPO / community.SETTINGS_TABLE).read_text(encoding="utf-8"))["items"] if i["id"] == "language")
        values = [o["value"] for o in item["options"]]
        ios = re.search(r"s2a_ios_game_languages\(void\) \{\s*return @\[(.*?)\];", (REPO / "ios/settings.m").read_text(encoding="utf-8"), re.S).group(1)
        self.assertEqual(re.findall(r'@"(\w+)"', ios), values)
        menu = (REPO / "ios/app_settings.m").read_text(encoding="utf-8")
        labels = re.search(r"labels = @\[S2AL\(@\"settings.gameLanguage.system\"\),(.*?)\];", menu, re.S).group(1)
        self.assertEqual(len(re.findall(r'@"[^"]+"\)?', labels)) + 1, len(values))   # 字面量与 S2AL(@"键") 各算一项
        enum = (REPO / "compat/tree/src/Ryujinx.HLE/HOS/SystemState/SystemLanguage.cs").read_text(encoding="utf-8")
        self.assertEqual([v for v in values[1:] if not re.search(r"\b%s,?\s" % v, enum)], [])
        self.assertIn("ios", item["platforms"])

    def test_diag_run_is_one_session_only(self):
        # #438 诊断局：打开后下一次起局设定好的四个探针（帧号 3600 / 7200，图写这款文件夹 diagrun/），起局时就把这项从 launch.json 去掉，
        #   第二次起局不再开；上一次诊断局的图清掉。期望值按规格手写
        (layout.image_mac(self.c, GID) / "cpatch.tsv").unlink()   # 只看诊断局变量：这款包里没补丁
        self.c.r.update(settings={"diagRun": True})
        community.save(self.c)
        old = layout.path(self.c, GID, "diagrun") / "shot_1.png"; old.parent.mkdir(parents=True, exist_ok=True); old.write_bytes(b"old")
        env = community.launch_env(self.c, GID)
        out = layout.path(self.c, GID, "diagrun")
        self.assertEqual(env, {"DM_NVN_PASSDUMP": "3600-3601", "DM_NVN_TEXDUMP": f"3600,7200:{out}/td_%d.png",
                               "DM_NVN_TEXSNAP": "0,4,8,12,16,20,24,28", "DM_NVN_SHOT": f"3600,7200:{out}/shot_%d.png"})
        self.assertTrue(out.is_dir()); self.assertFalse(old.exists())
        self.assertNotIn("diagRun", community.load_launch(self.c, GID)["settings"])
        self.assertEqual(community.launch_env(self.c, GID), {})

    def test_pack_without_patches(self):
        # 包里没编进补丁（没查到 / 还没出 Mac 版）→ 不列、不能存、不设 S2A_CPATCH_ON；宽屏 / 60 帧（我方能力）照常
        (layout.image_mac(self.c, GID) / "cpatch.tsv").unlink()
        r = community.listing(self.c)
        self.assertEqual((r["graphics"], r["widescreen"]["available"], r["fps60"]["available"]), ([], True, True))
        self.assertNotIn("S2A_CPATCH_ON", community.launch_env(self.c, GID))
        self.c.r = {"gameId": GID, "graphics": {"gfx:bb": True}}
        with self.assertRaises(Failure): community.save(self.c)

    def test_no_data(self):
        os.environ["S2A_COMMUNITY_DIR"] = str(self.t / "none")
        (self.c.engine / "graphics/widen/tables/verified.tsv").unlink(); (layout.image_mac(self.c, GID) / "cpatch.tsv").unlink()
        r = community.listing(self.c)
        self.assertEqual((r["widescreen"]["available"], r["fps60"]["available"], r["widescreen"]["enabled"], r["graphics"]), (False, False, False, []))



class MacDisplayTests(unittest.TestCase):
    """Mac 设置页：可用与否和缺省跟这款的能力清单走，只存玩家明确选过的。期望按规则手写"""
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.c = Ctx(self.t)
        write(self.c.library / "catalog.json", json.dumps({"games": [{"id": GID, "packages": []}]}))

    def caps(self, text="widen\t0\t# 缺省关\nfps60\t1\t# 开\ndirect\t1\t# 直连\n"):
        write(layout.image_mac(self.c, GID) / "s2a_caps.tsv", "# 注释\n" + text)

    def save(self, **change):
        self.c.r = {"gameId": GID, "settings": change}
        community.save(self.c)
        self.c.r = {"gameId": GID}

    def mac(self):
        return community.mac_settings(self.c, GID)

    def launch_file(self):
        return json.loads(community.launch_path(self.c, GID, create=False).read_text())

    def test_defaults_follow_the_caps(self):
        self.caps()
        m = self.mac()
        self.assertEqual((m["fps60"]["available"], m["fps60"]["value"]), (True, False))   # 清单 1 但原因不是已验证来源：缺省原帧率（同宿主）
        self.assertEqual((m["widescreen"]["available"], m["widescreen"]["value"]), (True, False))   # 清单 widen 0「缺省关」：没选过显示关、可以开
        self.assertEqual((m["enhance"]["available"], m["enhance"]["value"]), (True, False))
        self.assertEqual((m["docked"]["value"], m["rumble"]["value"], m["rumbleLevel"]["value"], m["motion"]["value"], m["hud"]["value"]),
                         ("docked", True, "2", True, False))   # 定义表缺省：Mac 主机模式、震动开标准档、体感开、浮层关
        self.assertEqual(community.launch_env(self.c, GID), {})

    def test_fps60_default_follows_the_verified_reason_like_the_host(self):
        # 同宿主 runtime/src/caps.c：清单 fps60 1 且原因含「fps.tsv」「逻辑速度同局 A/B 绿」「游戏原生 60 帧」「社区帧率补丁」之一才缺省开；值 0 / 别的原因都是原帧率
        for line, want in (("fps60\t1\t# fps.tsv 登记 60 帧\n", True), ("fps60\t1\t# 逻辑速度同局 A/B 绿\n", True),
                           ("fps60\t1\t# 游戏原生 60 帧\n", True), ("fps60\t1\t# 默认开：来源 社区帧率补丁\n", True), ("fps60\t1\t# 全引擎档\n", False), ("fps60\t0\t# fps.tsv 判红\n", False)):
            with self.subTest(line=line):
                self.caps(line + "direct\t1\n")
                self.assertEqual(self.mac()["fps60"]["value"], want)
                self.assertEqual(community.launch_env(self.c, GID), {})   # 没选过：不写，宿主自己按同一条规则开 / 不开

    def test_without_patches_fps60_and_widescreen_are_hidden(self):
        # 只用社区补丁（11-13 维护者撤掉我方 60 帧与通用满屏）：清单读得到时，没有帧率补丁 → 「60 帧」hidden；包里 cpatch.tsv 没有宽屏 / 自适应满屏补丁 → 「满屏」hidden
        self.caps("fps60\t1\t# fps.tsv 登记 60 帧\nwiden\t0\ndirect\t1\n")
        m = self.mac()
        self.assertEqual((m["fps60"].get("hidden"), m["widescreen"].get("hidden"), m["docked"].get("hidden")), (True, True, None))
        self.caps("fps60\t1\t# 默认开：来源 社区帧率补丁\nwiden\t0\ndirect\t1\n")
        write(layout.image_mac(self.c, GID) / "cpatch.tsv", "编号\t缺省开\nwidescreen:abc\t1\n")
        m = self.mac()
        self.assertEqual((m["fps60"].get("hidden"), m["widescreen"].get("hidden")), (None, None))
        (layout.image_mac(self.c, GID) / "s2a_caps.tsv").unlink()   # 还没出 Mac 版（读不到清单）：照旧都列、先存偏好
        self.assertEqual((self.mac()["fps60"].get("hidden"), self.mac()["widescreen"].get("hidden")), (None, None))

    def test_every_mac_item_of_the_table_is_on_the_page(self):
        # 定义表里 platforms 含 mac 的 bool / choice 项 = enhance fps60 widescreen docked rumble rumbleLevel motion hud（11-13 widenForce 并进 widescreen）
        self.caps()
        self.assertEqual(sorted(self.mac()), sorted(["enhance", "fps60", "fpsPick", "widescreen", "docked", "language", "rumble", "rumbleLevel", "motion", "padFace", "hud", "pauseUnfocused", "audioLatency", "diagRun"]))

    def test_fps_pick_level(self):
        # 帧率档位（11-13）：包里帧率补丁（编号 fps:）目标帧率两档以上才出；选具体档 → S2A_FPS_PICK=档，选自动（"0"）不写；表外取值拒收
        self.caps("fps60\t1\t# 默认开：来源 社区帧率补丁\nwiden\t0\ndirect\t1\n")
        tsv = layout.image_mac(self.c, GID) / "cpatch.tsv"
        write(tsv, "编号\t缺省开\t目标帧率\nfps:a\t1\t60\nfps:b\t1\t\nwidescreen:x\t1\t\n")   # 60 与没写（当 60）= 一档
        self.assertEqual((community.fps_levels(self.c, GID), self.mac()["fpsPick"].get("hidden")), ([60], True))
        write(tsv, "编号\t缺省开\t目标帧率\nfps:a\t1\t60\nfps:c\t1\t120\ngfx:d\t1\t30\n")       # gfx: 的目标帧率不算档
        self.assertEqual((community.fps_levels(self.c, GID), self.mac()["fpsPick"].get("hidden"), self.mac()["fpsPick"]["value"]), ([60, 120], None, "0"))
        self.assertNotIn("S2A_FPS_PICK", community.launch_env(self.c, GID))
        self.c.r.update(settings={"fpsPick": "60"}); community.save(self.c)
        self.assertEqual(community.launch_env(self.c, GID)["S2A_FPS_PICK"], "60")
        self.c.r = {"gameId": GID, "settings": {"fpsPick": "0"}}; community.save(self.c)
        self.assertNotIn("S2A_FPS_PICK", community.launch_env(self.c, GID))
        self.c.r = {"gameId": GID, "settings": {"fpsPick": "90"}}
        with self.assertRaises(Failure): community.save(self.c)

    def test_game_without_a_mac_build_can_still_pick(self):
        # v0.3.1：还没出 Mac 版也能先选、存成偏好（出好后生效）——原先整页置灰写「还没有做好 Mac 版」，玩家只能先去出包
        m = self.mac()
        for key in ("fps60", "widescreen", "enhance", "docked", "hud"):
            self.assertTrue(m[key]["available"]); self.assertEqual(m[key]["reason"], "")

    def test_missing_capabilities_give_their_own_reason(self):
        self.caps("widen\t0\ndirect\t0\n")
        m = self.mac()
        self.assertEqual(m["fps60"]["reason"], community.NO_FPS60)
        self.assertEqual(m["enhance"]["reason"], community.NO_DIRECT)
        self.assertTrue(m["widescreen"]["available"])   # 「缺省关」不是强信号：照样能开
        self.caps("widen\t0\t# 强信号：宽屏画面坏\ndirect\t1\n")
        self.assertEqual((self.mac()["widescreen"]["available"], self.mac()["widescreen"]["reason"]), (False, community.NO_WIDEN))

    def test_enhance_reaches_launch_and_turns_back_off(self):
        self.caps()
        self.save(enhance=True)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_SCALING_FILTER": "MetalFX"})
        self.assertTrue(self.mac()["enhance"]["value"])
        self.save(enhance=None)   # 回缺省：文件里不留这一项
        self.assertEqual((community.launch_env(self.c, GID), self.launch_file()["settings"]), ({}, {}))
        self.save(enhance=True)
        self.caps("fps60\t1\ndirect\t0\n")
        self.assertEqual(community.launch_env(self.c, GID), {})

    def test_full_screen_matches_iphone(self):
        # 满屏明确开 = 没验证过也铺满（同 iPhone settings.m）；明确关 = 16:9；强信号判坏的款明确开也不开
        self.caps()
        self.save(widescreen=True)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_WIDEN_VERIFIED": "1", "S2A_WIDESCREEN": "1"})
        self.save(widescreen=False)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_WIDESCREEN": "0"})
        self.caps("widen\t1\t# 默认开：widen_verified.tsv\ndirect\t1\n")
        self.save(widescreen=None)
        self.assertTrue(self.mac()["widescreen"]["value"])                           # 验过的款没选过：显示开
        self.assertEqual(community.launch_env(self.c, GID), {})
        self.caps("widen\t0\t# 强信号：崩溃归因\ndirect\t1\n")
        write(community.launch_path(self.c, GID), json.dumps({"schema": 1, "settings": {"widescreen": True}, "patches": {}}))
        self.assertEqual(community.launch_env(self.c, GID), {})

    def test_full_screen_drives_the_adaptive_patch(self):
        # 包里有自适应满屏补丁（wsauto:<族>:w / :n）：满屏开关一并开关它、不单列；开着时 S2Arm 满屏让开、不强开（同 iPhone）
        tsv = "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\n"
        for default in ("1", "0"):
            with self.subTest(default=default):
                self.caps()
                write(layout.image_mac(self.c, GID) / "cpatch.tsv", tsv + "".join(f"wsauto:fam:{x}\tmain\t0\tultrawide\tAuto\t\tsrc\t\t{default}\n" for x in "wn")
                      + "gfx:dof\tmain\t1\tother-gfx\tDisable DOF\t\tsrc\t\t0\n")
                self.assertEqual([it["id"] for it in community.packed_patches(self.c, GID)], ["gfx:dof"])
                self.save(widescreen=None)
                self.assertTrue(self.mac()["widescreen"]["value"])                          # 11-13：有自适应满屏补丁就默认开（不看我方验过标签）
                self.assertEqual(community.launch_env(self.c, GID), {"S2A_CPATCH_ON": "gfx:dof,wsauto:fam", "S2A_WIDESCREEN": "0"})   # 画面补丁没选过也开
                self.save(widescreen=True)
                self.assertEqual(community.launch_env(self.c, GID), {"S2A_CPATCH_ON": "gfx:dof,wsauto:fam", "S2A_WIDESCREEN": "0"})
                self.save(widescreen=False)
                self.assertEqual(community.launch_env(self.c, GID), {"S2A_CPATCH_ON": "gfx:dof", "S2A_WIDESCREEN": "0"})

    def test_fixed_ratio_variants_are_one_item(self):
        # 定画幅宽屏变体（表「画幅」列，11-13）：几份并成一项 widescreen:auto（宿主按窗口比例开最近一份）；开着时 S2Arm 满屏让开；没画幅的单列
        self.caps()
        tsv = "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅\n" + \
            "".join(f"widescreen:v{i}\tmain\t{i}\tultrawide\tHUD\t\tsrc\t\t0\t\t{a}\n" for i, a in enumerate(("1.6000", "2.3333")))
        write(layout.image_mac(self.c, GID) / "cpatch.tsv", tsv + "gfx:dof\tmain\t5\tother-gfx\tDisable DOF\t\tsrc\t\t0\t\t\n")
        got = community.packed_patches(self.c, GID)
        self.assertEqual([(it["id"], it["label"], it.get("ratios")) for it in got],
                         [("widescreen:auto", "满屏补丁（按屏幕比例自动选）", ["16:10", "21:9"]), ("gfx:dof", "Disable DOF", None)])
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_CPATCH_ON": "gfx:dof,widescreen:auto", "S2A_WIDESCREEN": "0"})

    def test_packed_patch_shows_last_session_result(self):
        # 上一局实际结果（runtime/src/cpatch.c 写 游戏库/temp/<程序号>/cpatch_status.tsv）：没生效写原因、开着量到效果写实测、其余空
        self.caps()
        tsv = "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\n" + "".join(f"gfx:{x}\tmain\t{i}\tother-gfx\t{x}\t\tsrc\t\t0\n" for i, x in enumerate("abcdef"))
        write(layout.image_mac(self.c, GID) / "cpatch.tsv", tsv)
        write(Path(self.c.library) / "temp" / GID / "cpatch_status.tsv", "gfx:a\t不配套\t\ngfx:b\t开\tfps=60\ngfx:c\t开\taspect=19.5:9\ngfx:d\t开\t\ngfx:e\t开\tfps=31\ngfx:f\t开\tunfilled\n")
        got = {it["id"]: it["result"] for it in community.packed_patches(self.c, GID)}
        self.assertEqual(got, {"gfx:a": "没生效：补丁与这个版本的游戏不配套", "gfx:b": "已生效：上一局实测 60 帧", "gfx:c": "已生效：上一局画面比例 19.5:9", "gfx:d": "",
                               "gfx:e": "开着，但上一局实测只有 31 帧", "gfx:f": "开着，但上一局画面没铺满"})

    def test_old_force_widescreen_choice_becomes_full_screen_on(self):
        # 旧 launch.json 的 widenForce=真（「宽屏强制启用」）= 满屏明确开
        self.caps()
        write(community.launch_path(self.c, GID), json.dumps({"schema": 1, "settings": {"widenForce": True}, "patches": {}}))
        self.assertTrue(self.mac()["widescreen"]["value"])
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_WIDEN_VERIFIED": "1", "S2A_WIDESCREEN": "1"})

    def test_fps60_off_and_manual_on_over_a_red_game(self):
        self.caps()
        self.save(fps60=False)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_FPS60": "0"})             # 玩家明确关：写 0
        self.assertFalse(self.mac()["fps60"]["value"])
        self.save(fps60=True)                                                               # 清单开的款玩家开：也要明确传 1（宿主不再看清单）
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_FPS60": "1"})
        self.caps("fps60\t0\t# 判红\ndirect\t1\n")
        self.save(fps60=True)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_FPS60": "1"})
        self.assertTrue(self.mac()["fps60"]["value"])

    def test_changing_one_switch_does_not_decide_the_others(self):
        # 判红的款：改画面增强不能顺手把 60 帧存成开；文件里只有这一项
        self.caps("fps60\t0\t# 判红\ndirect\t1\n")
        self.save(enhance=True)
        self.assertFalse(self.mac()["fps60"]["value"])
        self.assertEqual(self.launch_file()["settings"], {"enhance": True})
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_SCALING_FILTER": "MetalFX"})

    def test_controls_and_mode_reach_the_host(self):
        # 掌机 → S2A_DOCKED=0；浮层开 → S2A_HUD=1；震动关 → S2A_RUMBLE=0；强度「强」(4) → 倍率 1.8；体感关 → S2A_MOTION=0
        self.caps()
        self.save(docked="handheld", hud=True, rumble=False, rumbleLevel="4", motion=False)
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_DOCKED": "0", "S2A_HUD": "1", "S2A_RUMBLE": "0", "S2A_RUMBLE_SCALE": "1.8", "S2A_MOTION": "0"})

    def test_max_blast_rumble_level(self):
        # 「震爆我」(5) → 倍率 5.0；iOS ios/controller.m 的六档倍率表与定义表一致
        self.caps()
        self.save(rumbleLevel="5")
        self.assertEqual(community.launch_env(self.c, GID)["S2A_RUMBLE_SCALE"], "5.0")
        import re
        table = json.loads((REPO / community.SETTINGS_TABLE).read_text(encoding="utf-8"))
        scale = next(i for i in table["items"] if i["id"] == "rumbleLevel")["scale"]
        ios = re.search(r"gains\[6\] = \{([^}]*)\}", (REPO / "ios" / "controller.m").read_text(encoding="utf-8")).group(1)
        self.assertEqual([float(x.strip().rstrip("f")) for x in ios.split(",")], [scale[str(i)] for i in range(6)])

    def test_pad_face_is_shared_by_every_game(self):
        # 全游戏共用：存数据目录 game-settings.json、不进这款 launch.json；另一款（没有 Mac 版）也读到「Switch 布局」；起局转 S2A_PAD_FACE=switch
        self.caps()
        self.save(padFace="switch")
        self.assertEqual(json.loads((self.c.private / "game-settings.json").read_text())["settings"], {"padFace": "switch"})
        self.assertEqual(self.launch_file()["settings"], {})
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_PAD_FACE": "switch"})
        other = "0100000000000001"
        write(self.c.library / "catalog.json", json.dumps({"games": [{"id": GID, "packages": []}, {"id": other, "packages": []}]}))
        m = community.mac_settings(self.c, other)
        self.assertEqual((m["padFace"]["available"], m["padFace"]["value"]), (True, "switch"))
        self.assertEqual(community.launch_env(self.c, other), {"S2A_PAD_FACE": "switch"})
        self.save(padFace="xbox")
        self.assertEqual(community.launch_env(self.c, GID), {"S2A_PAD_FACE": "xbox"})
        self.save(padFace=None)   # 回缺省「自动」：不设环境变量
        self.assertEqual(community.launch_env(self.c, GID), {})
        self.assertEqual(community.mac_settings(self.c, GID)["padFace"]["value"], "auto")

    def test_pad_face_old_values_still_count(self):
        # 11-11 前存下的旧值：按位置 = Switch 布局（照旧转 switch），按字母 = 自动（不设环境变量）
        self.caps()
        for old, value, env in (("position", "switch", {"S2A_PAD_FACE": "switch"}), ("letter", "auto", {})):
            write(self.c.private / "game-settings.json", json.dumps({"schema": 1, "settings": {"padFace": old}}))
            self.assertEqual(community.mac_settings(self.c, GID)["padFace"]["value"], value)
            self.assertEqual(community.launch_env(self.c, GID), env)

    def test_bad_key_or_value_is_refused_and_file_unchanged(self):
        self.caps()
        self.save(hud=True)
        for bad in ({"nosuch": True}, {"docked": "tabletop"}, {"hud": "yes"}, {"input": True}):
            self.c.r = {"gameId": GID, "settings": bad}
            with self.assertRaises(Failure): community.save(self.c)
        self.assertEqual(self.launch_file()["settings"], {"hud": True})

    def test_old_community_file_is_moved_once(self):
        # schema 3：widenForce / metalfx / fps60 都是玩家选的 → widescreen（满屏明确开，11-13 并入）/ enhance / fps60；补丁带过去；旧文件删掉
        self.caps()
        old = layout.path(self.c, GID, "community.json")
        write(old, json.dumps({"schema": 3, "widescreen": False, "fps60": True, "widenForce": True, "metalfx": True, "enabled": {"gfx:a": True}}))
        self.assertTrue(self.mac()["enhance"]["value"])
        self.assertEqual(self.launch_file(), {"schema": 1, "settings": {"widescreen": True, "enhance": True, "fps60": True}, "patches": {"gfx:a": True}})
        self.assertFalse(old.exists())

    def test_old_file_written_by_the_previous_panel_is_not_a_manual_choice(self):
        # schema 2 存盘总带 fps60=真：不算玩家选的，判红的款 60 帧仍关
        self.caps("fps60\t0\t# 判红\ndirect\t1\n")
        write(layout.path(self.c, GID, "community.json"), json.dumps({"schema": 2, "widescreen": True, "fps60": True, "enabled": {}}))
        self.assertFalse(self.mac()["fps60"]["value"])
        self.assertEqual(community.launch_env(self.c, GID), {})

if __name__ == "__main__":
    unittest.main()
