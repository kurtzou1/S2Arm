#!/usr/bin/env python3
# 直连抽取找游戏解码器的缺省（11-07 勇者斗恶龙 XI S：私有根出包时 extract.py 不设 DM_OODLE_HOST / DM_OODLE_MODULES，shader_split 遇 LZ5 包直接红，
#   而 pack/ue_pak.py、nxsh_extract 用 uepak.oodle_host_find 的缺省照样找得到）。translator/shader_split.py oodle_defaults。期望按约定手写：
#   ① 两个变量都没设、产物根布局（<根>/romfs 与 <根>/main.fixups.tsv 并排）、宿主存在 → DM_OODLE_HOST = 宿主、DM_OODLE_MODULES = <根>（写进环境，派生的工人进程看得见）
#   ② 调用方已设 → 原样不动
#   ③ 找不到（RomFS 父目录里没有 main.fixups.tsv）→ 两个变量都不设，S2A_OODLE_WHY 写原因（红行带上）
#   负对照：把 oodle_defaults 换成空函数 → ① 两个变量还是空（旧行为）
import os, sys, tempfile, unittest
from pathlib import Path
from unittest import mock
TOOLS = Path(__file__).resolve().parents[4] / 'translator'
_PROF = tempfile.TemporaryDirectory(prefix='split-oodle-')   # 被测模块载入只读这份合成档案（不碰任何真游戏）
(Path(_PROF.name) / 'game.tsv').write_text('shader_groups\tsynthetic=synthetic\nshader_note\tsynthetic\n')
os.environ['DM_GAME'] = _PROF.name
sys.path.insert(0, str(TOOLS)); import shader_split as ss   # noqa: E402

class T(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); r = Path(self.d.name)
        (r / 'root/romfs').mkdir(parents=True); (r / 'root/main.fixups.tsv').write_text('x')
        (r / 'bare/romfs').mkdir(parents=True)
        self.host = r / 'host'; self.host.write_text('#!/bin/sh\n'); self.r = r
        self.env = mock.patch.dict(os.environ, {k: v for k, v in os.environ.items() if k not in ('DM_OODLE_HOST', 'DM_OODLE_MODULES', 'S2A_OODLE_WHY')}, clear=True); self.env.start()
    def tearDown(self): self.env.stop(); self.d.cleanup()
    def test_1_default_found(self):
        os.environ['DM_OODLE_HOST'] = str(self.host)   # 宿主由测试给（仓库 build/s2arm-host 是否存在与本测试无关）；模块目录走缺省
        os.environ.pop('DM_OODLE_MODULES', None)
        ss.oodle_defaults(str(self.r / 'root/romfs'))
        self.assertEqual(os.environ.get('DM_OODLE_MODULES'), os.path.abspath(str(self.r / 'root')))
        self.assertEqual(os.environ.get('DM_OODLE_HOST'), str(self.host))
    def test_2_caller_set_kept(self):
        os.environ['DM_OODLE_HOST'] = 'h'; os.environ['DM_OODLE_MODULES'] = 'm'
        ss.oodle_defaults(str(self.r / 'root/romfs'))
        self.assertEqual((os.environ['DM_OODLE_HOST'], os.environ['DM_OODLE_MODULES']), ('h', 'm'))
    def test_3_not_found(self):
        os.environ['DM_OODLE_HOST'] = str(self.host)
        ss.oodle_defaults(str(self.r / 'bare/romfs'))
        self.assertNotIn('DM_OODLE_MODULES', os.environ)
        self.assertIn('main.fixups.tsv', os.environ.get('S2A_OODLE_WHY', ''))

if __name__ == '__main__':
    r = unittest.main(exit=False, verbosity=1).result
    print(f"直连抽取解码器缺省：{r.testsRun} 项、不符 {len(r.failures) + len(r.errors)}"); sys.exit(0 if r.wasSuccessful() else 1)
