#!/usr/bin/env python3
"""#1574 宿主回归：安卓一键出包的离线 Vulkan 着色器阶段（target.json「shaders」）。

package.py 出包期那段接线的合成输入验证——不建 Vulkan 设备、不跑真机烘焙器、不装 APK：
  * game_apk.py --shader-pack：把烘焙产物根打成字节可复现的 assets/game/shaders.zip
    （排序、固定时间戳——Gradle 打进 APK 的就是这份资产）；
  * attach_shaders.py：把同一产物挂进资源包，index 追加 shaders/vulkan/generic/ 行，
    安装 revision 的 GameContentRoot（index 去 shaders/ 行）保持不变；
  * 可复现：同一包 + 同一烘焙产物两次跑，资源包 index/artifact 身份与 zip 字节逐位相同；
  * 输入敏感：烘焙产物内容一变，资源包 index/artifact 与 zip 都跟着变；
  * 负对照：跳过该阶段（不给 --shader-pack、不 attach），同一套「包里有着色器」的断言必须失败；
  * 声明绑定：target.json 配方声明的 shaders 阶段指向 bake_shaders.py / attach_shaders.py /
    game_apk.py --shader-pack，不能声明与实际接点脱节；
  * bake_shaders.py 的 host 侧单元行为：内容根绑定、0 支抽取早退、extract/s2x 复用。

真机的「首遇编译数下降 / >100ms 帧下降」验收属设备线（autonomous-game-run.md §4 P2），本文件不宣布其完成。
"""
import hashlib
import importlib.util
import io
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
TOOLS = HERE.parent / 'tools'
REPO = HERE.parents[1]
sys.path.insert(0, str(TOOLS))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


direct_library = load('direct_library', TOOLS / 'direct_library.py')
make_pack = load('android_make_pack', TOOLS / 'make_pack.py')
game_apk = load('android_game_apk', TOOLS / 'game_apk.py')
bake_shaders = load('android_bake_shaders', TOOLS / 'bake_shaders.py')

TITLE = '0100000000ABCDEF'
PROFILE_KEY = 'a1b2c3d4e5f6'


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class ShaderPackStageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.pack = self.write_pack(self.base / 'pack')

    # -- fixtures --------------------------------------------------------------------
    def nacp(self):
        nacp = bytearray(0x4000)
        nacp[0:15] = b'S2Arm synthetic'                 # 桌面标签取游戏自带标题
        nacp[0x200:0x205] = b'S2Arm'
        struct.pack_into('<Q', nacp, 0x3038, int(TITLE, 16))
        nacp[0x3060:0x3063] = b'0.1'
        return bytes(nacp)

    def module_images(self):
        return {
            'modules/main.patched.bin': b'synthetic module',
            'modules/main.fixups.tsv': b'# TARGET\tandroid\n# REWRITE_ABI\tandroid-sp-safe-v1\n',
            'modules/main.gates.tsv': b'# fixture\n',
        }

    def write_pack(self, out, extra_romfs=b'data'):
        """最小普通包（不带直连描述）：包内容与 package.py 里 direct_pack 同形。"""
        sources = self.base / ('sources-' + out.name)
        sources.mkdir(exist_ok=True)
        files = {'ctl/control.nacp': self.nacp(), 'romfs/data.bin': extra_romfs,
                 'exefs/main.npdm': b'META' + bytes(0x94),
                 'exefs/addr_need.tsv': b'# fixture\n'}
        files.update(self.module_images())
        entries = []
        for relative, data in files.items():
            path = sources / relative.replace('/', '_')
            path.write_bytes(data)
            entries.append((relative, str(path)))
        make_pack.write_pack(str(out), entries, False, None)
        return Path(out)

    def bake_pack(self, out, payload=b'program-record-v1', key=PROFILE_KEY):
        """合成的 S2A.ShBake --vulkan-profile 产物根：恰一个 vulkan/generic/<key>/，
        manifest 绑定的 contentRoot 与 attach_shaders 对安装 revision 算出的期望一致。"""
        out = Path(out)
        profile = out / 'vulkan' / 'generic' / key
        profile.mkdir(parents=True)
        (profile / 'profile.json').write_text(json.dumps({'schema': 's2a-vulkan-profile-v2'}))
        (profile / 'shcache' / TITLE.lower()).mkdir(parents=True)
        (profile / 'shcache' / TITLE.lower() / '0001.vkpb').write_bytes(payload)
        expected = bake_shaders.package_content_root(str(self.pack))
        (profile / 'manifest.json').write_text(json.dumps(
            {'schema': 's2a-vulkan-pack-v1', 'contentRoot': expected, 'profile': key}))
        return out

    def make_apk(self, game_dir, out=None):
        """假 APK：Gradle 会把 assets/ 原样打进 APK，这里复刻同一路径。"""
        apk = out or self.base / 'input.apk'
        with zipfile.ZipFile(apk, 'w') as archive:
            archive.writestr('assets/game/game.properties',
                             f'titleId={TITLE}\nversionCode=2\n')
            for relative, data in self.module_images().items():
                archive.writestr('assets/game/' + relative, data)
            shaders_zip = Path(game_dir) / 'assets/game/shaders.zip'
            if shaders_zip.is_file():
                archive.write(shaders_zip, 'assets/game/shaders.zip')
        return apk

    def run_recipe(self, shader_pack=None, tag=''):
        """package.py 里 shaders 阶段的三个接点，按同一顺序跑：
        game_apk --shader-pack →（假 APK）→ --resources → attach_shaders。"""
        game_dir = self.base / ('game-dir' + tag)
        command = [sys.executable, str(TOOLS / 'game_apk.py'), str(self.pack), str(game_dir),
                   '--version-code', '2']
        if shader_pack is not None:
            command += ['--shader-pack', str(shader_pack)]
        completed = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        apk = self.make_apk(game_dir, out=self.base / ('input' + tag + '.apk'))
        resources = self.base / ('resources' + tag)
        with patch.object(game_apk, 'apk_signer_sha256', return_value='a' * 64), \
             patch.object(game_apk, 'apk_identity',
                          return_value=('org.s2arm.game.t' + TITLE.lower(), 2, False)):
            game_apk.resources(str(self.pack), str(apk), str(resources))
        if shader_pack is not None:
            completed = subprocess.run([sys.executable, str(TOOLS / 'attach_shaders.py'),
                                        str(resources), str(shader_pack)],
                                       capture_output=True, text=True)
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        return game_dir, apk, resources

    # -- assertions shared by positive / negative runs ---------------------------------
    def assert_shader_pack_shipped(self, game_dir, apk, resources):
        """「离线包随包交付」的口径：APK 资产有 shaders.zip，安装包有 shaders/vulkan/generic/ 行。"""
        shaders_zip = Path(game_dir) / 'assets/game/shaders.zip'
        self.assertTrue(shaders_zip.is_file(), 'assets/game/shaders.zip 没进 APK 资产目录')
        with zipfile.ZipFile(apk) as archive:
            self.assertIn('assets/game/shaders.zip', archive.namelist())
            members = zipfile.ZipFile(io.BytesIO(archive.read('assets/game/shaders.zip')))
        names = members.namelist()
        self.assertIn(f'vulkan/generic/{PROFILE_KEY}/manifest.json', names)
        self.assertIn(f'vulkan/generic/{PROFILE_KEY}/profile.json', names)
        self.assertTrue(any(name.endswith('.vkpb') for name in names))
        rows = direct_library.read_index(Path(resources) / 'index.tsv')
        generic = [row for row in rows if row[0].startswith('shaders/vulkan/generic/')]
        self.assertTrue(generic, '资源包 index 没有 shaders/vulkan/generic/ 行')
        self.assertTrue(all(row[0].startswith(f'shaders/vulkan/generic/{PROFILE_KEY}/')
                            for row in generic))

    # -- tests -------------------------------------------------------------------------
    def test_pack_ships_shader_pack_in_apk_and_resources(self):
        shader_pack = self.bake_pack(self.base / 'bake-out')
        game_dir, apk, resources = self.run_recipe(shader_pack)
        self.assert_shader_pack_shipped(game_dir, apk, resources)
        rows = direct_library.read_index(resources / 'index.tsv')
        artifact = json.loads((resources / 'game-build-artifact.json').read_text())
        manifest = json.loads((resources / 'manifest.json').read_text())
        # 包 manifest 的 index_sha256 必须覆盖挂完后的全部行；artifact.contentRoot 是同一个值。
        self.assertEqual(manifest['index_sha256'], artifact['package']['indexSha256'])
        self.assertEqual('sha256-' + manifest['index_sha256'], artifact['contentRoot'])
        # 安装 revision 的 GameContentRoot（去 shaders/ 行）与烘焙时绑定的包内容根一致。
        pack_manifest = json.loads((Path(shader_pack) / 'vulkan/generic' / PROFILE_KEY
                                    / 'manifest.json').read_text())
        self.assertEqual(direct_library.index_content_root(rows), pack_manifest['contentRoot'])
        # 直连库验证不拒这份带通用离线包的 revision。
        direct_library.read_index(resources / 'index.tsv')

    def test_identity_reproducible_for_identical_inputs(self):
        """同一包 + 同一烘焙产物根跑两遍：交付身份逐位相同（identity 字段与 zip 字节）。"""
        shader_pack = self.bake_pack(self.base / 'bake-out')
        _, _, resources_a = self.run_recipe(shader_pack, tag='-a')
        _, _, resources_b = self.run_recipe(shader_pack, tag='-b')
        index_a = (resources_a / 'index.tsv').read_bytes()
        index_b = (resources_b / 'index.tsv').read_bytes()
        self.assertEqual(index_a, index_b, '同一输入的资源包 index 必须逐位相同')
        artifact_a = json.loads((resources_a / 'game-build-artifact.json').read_text())
        artifact_b = json.loads((resources_b / 'game-build-artifact.json').read_text())
        for field in ('contentRoot', 'package'):
            self.assertEqual(artifact_a[field], artifact_b[field])
        pack2 = self.bake_pack(self.base / 'bake-out2')
        out_a, out_b = self.base / 'a.zip', self.base / 'b.zip'
        game_apk.write_shader_zip(str(shader_pack), str(out_a))
        game_apk.write_shader_zip(str(pack2), str(out_b))
        self.assertEqual(out_a.read_bytes(), out_b.read_bytes(),
                         '同一烘焙产物根两次打 zip 必须逐位相同')

    def test_identity_changes_when_shader_pack_changes(self):
        pack_v1 = self.bake_pack(self.base / 'bake-v1', payload=b'records-v1')
        pack_v2 = self.bake_pack(self.base / 'bake-v2', payload=b'records-v2-changed')
        _, _, res_v1 = self.run_recipe(pack_v1, tag='-v1')
        _, _, res_v2 = self.run_recipe(pack_v2, tag='-v2')
        index_v1 = (res_v1 / 'index.tsv').read_bytes()
        index_v2 = (res_v2 / 'index.tsv').read_bytes()
        self.assertNotEqual(index_v1, index_v2, '着色器包变了，资源包 index 必须跟着变')
        artifact_v1 = json.loads((res_v1 / 'game-build-artifact.json').read_text())
        artifact_v2 = json.loads((res_v2 / 'game-build-artifact.json').read_text())
        self.assertNotEqual(artifact_v1['contentRoot'], artifact_v2['contentRoot'],
                            '着色器包变了，交付身份必须跟着变')
        self.assertNotEqual(artifact_v1['package']['indexSha256'],
                            artifact_v2['package']['indexSha256'])
        # 游戏内容没动：安装 revision 的 GameContentRoot（去 shaders/ 行）必须不变——
        #   包 manifest 只认游戏内容身份，不认着色器代次。
        rows_v1 = direct_library.read_index(res_v1 / 'index.tsv')
        rows_v2 = direct_library.read_index(res_v2 / 'index.tsv')
        self.assertEqual(direct_library.index_content_root(rows_v1),
                         direct_library.index_content_root(rows_v2))
        zip_v1, zip_v2 = self.base / 'v1.zip', self.base / 'v2.zip'
        game_apk.write_shader_zip(str(pack_v1), str(zip_v1))
        game_apk.write_shader_zip(str(pack_v2), str(zip_v2))
        self.assertNotEqual(sha256(zip_v1.read_bytes()), sha256(zip_v2.read_bytes()))

    def test_skipping_the_stage_ships_no_shader_pack(self):
        """负对照：同一配方去掉 shaders 阶段后，「包里有着色器」的断言必须失败——
        不是断言恒真，是阶段真的把包放进去了。"""
        game_dir, apk, resources = self.run_recipe(shader_pack=None)
        self.assertFalse((Path(game_dir) / 'assets/game/shaders.zip').exists())
        with zipfile.ZipFile(apk) as archive:
            self.assertNotIn('assets/game/shaders.zip', archive.namelist())
        rows = direct_library.read_index(resources / 'index.tsv')
        self.assertFalse(any(row[0].startswith('shaders/vulkan/generic/') for row in rows))
        with self.assertRaises(AssertionError):
            self.assert_shader_pack_shipped(game_dir, apk, resources)

    def test_attach_refuses_a_pack_bound_to_another_revision(self):
        """包 manifest 的 contentRoot 对不上本 revision：挂接必须拒——身份不能糊。"""
        bad = self.base / 'bake-bad'
        profile = bad / 'vulkan/generic/other-key'
        profile.mkdir(parents=True)
        (profile / 'manifest.json').write_text(json.dumps(
            {'schema': 's2a-vulkan-pack-v1', 'contentRoot': 'sha256-' + '0' * 64}))
        completed = subprocess.run([sys.executable, str(TOOLS / 'attach_shaders.py'),
                                    str(self.pack), str(bad)],
                                   capture_output=True, text=True)
        self.assertNotEqual(completed.returncode, 0)

    def test_target_recipe_declares_the_stage_and_its_contacts(self):
        """配方声明与真实接点不脱节：stage 在 rewrite 与 bundle.apk 之间，
        实现字段指向本测试覆盖的三个工具。"""
        target = json.loads((REPO / 'pack/targets/android/target.json').read_text())
        recipe = next(item for item in target['recipes'] if item['id'] == 'android')
        stages = recipe['stages']
        self.assertEqual(stages.index('shaders'), stages.index('rewrite') + 1)
        self.assertEqual(stages.index('bundle.apk'), stages.index('shaders') + 1)
        entry = next(item for item in target['stages'] if item['id'] == 'shaders')
        for needle in ('bake_shaders.py', 'attach_shaders.py', 'game_apk.py'):
            self.assertIn(needle, entry['implementation'])
        self.assertIn('S2A_VULKAN_PROFILE', entry['condition'])

    # -- bake_shaders.py host-side units -------------------------------------------------
    def test_build_environment_preserves_both_main_and_shader_inputs(self):
        """变基冲突两侧都必须生效，且无关环境变量不能流入子构建。"""
        # 独立进程避免本套件的 tools/pack.py 与仓库 pack 包同名污染 sys.modules。
        script = """
import importlib.util, json, sys
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location('android_package', sys.argv[2])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.android_sdk_home = lambda _: '/sdk'
source = {'S2A_VULKAN_PROFILE': '/profile.json',
          'S2A_VULKAN_REFS': '/ref', 'UNRELATED_SECRET': 'not-forwarded'}
print(json.dumps(module.build_environment(source)))
"""
        result = subprocess.run([sys.executable, '-c', script, str(REPO),
                                 str(REPO / 'pack/targets/android/package.py')],
                                check=True, capture_output=True, text=True)
        env = json.loads(result.stdout)
        self.assertEqual(env['S2A_VULKAN_PROFILE'], '/profile.json')
        self.assertEqual(env['S2A_VULKAN_REFS'], '/ref')
        self.assertNotIn('UNRELATED_SECRET', env)

    def test_bake_binds_to_the_installed_content_root(self):
        """package_content_root = index_content_root(index)：与安装 revision 同值。"""
        rows = direct_library.read_index(self.pack / 'index.tsv')
        self.assertEqual(bake_shaders.package_content_root(str(self.pack)),
                         direct_library.index_content_root(rows))
        self.assertEqual(bake_shaders.package_title(str(self.pack)), TITLE)

    def test_bake_returns_no_pack_when_extraction_finds_zero_programs(self):
        """0 支可抽：早退、pack=null、不出空包——调用方据此跳过挂接（同共享阶段口径）。"""
        extract = self.base / 'extract'
        (extract / 'src').mkdir(parents=True)
        (extract / 'rows.tsv').write_text('# nxsh_extract rows\n# 唯一键 0\n')
        (self.base / 'profile.json').write_text('{"schema": "s2a-vulkan-profile-v2"}')
        out = self.base / 'bake-zero'
        completed = subprocess.run(
            [sys.executable, str(TOOLS / 'bake_shaders.py'), str(self.pack),
             '--root', str(self.base), '--profile', str(self.base / 'profile.json'),
             '--extract', str(extract), '--out', str(out)],
            capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        summary = json.loads((out / 'bake.json').read_text())
        self.assertIsNone(summary['pack'])
        self.assertFalse((out / 'pack').exists())

    def test_bake_reuses_the_staged_extraction(self):
        """<root>/extract/ok + extract/s2x/rows.tsv 存在就复用，不重抽（抽着色器只做一次）。"""
        root = self.base / 'product-root'
        staged = root / 'extract' / 's2x'
        (staged / 'src').mkdir(parents=True)
        (staged / 'rows.tsv').write_text('# staged rows\n')
        (root / 'extract' / 'ok').write_text('ok')
        extract = self.base / 'reuse' / 'extract'
        bake_shaders.extract_shaders(str(root), str(extract), dict(os.environ))
        self.assertEqual((extract / 'rows.tsv').read_text(), '# staged rows\n')

    def test_bake_requires_a_real_profile_file(self):
        """没给真机 profile 就拒绝：host 不能手写 profile 伪造命中。"""
        completed = subprocess.run(
            [sys.executable, str(TOOLS / 'bake_shaders.py'), str(self.pack),
             '--root', str(self.base), '--profile', str(self.base / 'missing.json'),
             '--extract', str(self.base / 'extract'), '--out', str(self.base / 'bake-miss')],
            capture_output=True, text=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn('profile', completed.stderr + completed.stdout)


if __name__ == '__main__':
    unittest.main()
