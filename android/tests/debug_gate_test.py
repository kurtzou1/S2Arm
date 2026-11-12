#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""调试入口两道门（DebugGate.java + native/debug_gate.h）：真 JVM 跑剥参数逻辑（Android 类用最小替身），再核入口接线。
设备上属性门的正反对照见 android/README.md「调试入口」一节（本单测在宿主上，getprop 不存在 = 属性没开）。"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ANDROID = Path(__file__).resolve().parents[1]
JAVA = ANDROID / 'app/src/main/java/org/s2arm/android'

STUBS = {
    'android/os/Bundle.java': '''package android.os;
public class Bundle { public final java.util.LinkedHashMap<String,Object> m = new java.util.LinkedHashMap<>();
  public java.util.Set<String> keySet() { return m.keySet(); } }''',
    'android/content/Intent.java': '''package android.content;
public class Intent { public final android.os.Bundle b = new android.os.Bundle();
  public android.os.Bundle getExtras() { return b.m.isEmpty() ? null : b; }
  public void removeExtra(String k) { b.m.remove(k); } public Intent putExtra(String k, Object v) { b.m.put(k, v); return this; } }''',
    'android/util/Log.java': '''package android.util;
public class Log { public static int i(String t, String m) { System.out.println(m); return 0; } }''',
}
PROBE = '''package org.s2arm.android;
public class GateProbe { public static void main(String[] a) {
  android.content.Intent i = new android.content.Intent();
  String[] debug = {"s2arm.experimental_inline_sme_context", "s2arm.experimental_revision", "s2arm.diag_ssbo_oob",
    "s2arm.debug_env", "s2arm.lifecycle_test", "s2arm.release_stall_ms", "s2arm.stop_stall_ms", "s2arm.request_stop",
    "s2arm.dev_runtime", "s2arm.threaded_renderer", "s2arm.bounded_readonly_check", "s2arm.touchlog"};
  String[] production = {"s2arm.title_id", "s2arm.resume_session", "s2arm.gamemap", "s2arm.graphics_mode", "s2arm.finish", "s2arm.draw_log"};
  for (String k : debug) i.putExtra(k, "1");
  for (String k : production) i.putExtra(k, "1");
  int removed = DebugGate.scrub(i);
  System.out.println("removed=" + removed + " left=" + String.join(",", i.getExtras().keySet()));
  System.out.println("open=" + DebugGate.open());
} }'''


def javac():
    found = subprocess.run(['bash', str(ANDROID / 'tools/jdk17.sh')], capture_output=True, text=True)
    if found.returncode == 0 and found.stdout.strip():
        return Path(found.stdout.strip())
    which = shutil.which('javac')
    return Path(which) if which else None


class DebugGateTest(unittest.TestCase):
    def run_probe(self, debug):
        tool = javac()
        if tool is None:
            self.skipTest('需要 JDK 17（android/tools/jdk17.sh）')
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            sources = []
            for rel, text in STUBS.items():
                path = out / 'src' / rel; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text); sources.append(path)
            (out / 'src/BuildConfig.java').write_text('package org.s2arm.android; final class BuildConfig { static final boolean DEBUG = %s; }' % str(debug).lower())
            (out / 'src/GateProbe.java').write_text(PROBE)
            sources += [out / 'src/BuildConfig.java', out / 'src/GateProbe.java', JAVA / 'DebugGate.java']
            subprocess.run([str(tool), '-d', str(out / 'cls')] + list(map(str, sources)), check=True)
            return subprocess.run([str(tool.parent / 'java'), '-cp', str(out / 'cls'), 'org.s2arm.android.GateProbe'],
                                  check=True, capture_output=True, text=True).stdout

    def test_release_and_unset_property_strip_every_debug_extra(self):
        # 正式构建（玩家包）与「调试构建但属性没开」都必须剥干净调试参数、保留生产参数；门不开
        for debug in (False, True):
            with self.subTest(debug=debug):
                out = self.run_probe(debug)
                self.assertIn('removed=12 left=s2arm.title_id,s2arm.resume_session,s2arm.gamemap,s2arm.graphics_mode,s2arm.finish,s2arm.draw_log', out)
                self.assertIn('open=false', out)
                self.assertIn('Debug extras ignored: 12', out)

    def test_entry_points_scrub_before_any_read(self):
        activity = (JAVA / 'MainActivity.java').read_text()
        create = activity[activity.index('    @Override public void onCreate(Bundle state) {'):]
        self.assertTrue(create.split('\n')[2].strip().startswith('DebugGate.scrub(getIntent());'), '冷启动第一件事就剥参数')
        hot = activity[activity.index('    @Override protected void onNewIntent'):]
        self.assertTrue(hot.split('\n')[1].strip().startswith('DebugGate.scrub(intent);'), '热 intent 先剥参数再交给 super')

    def test_draw_log_extra_is_parsed_then_bridged_before_game_start(self):
        # s2arm.draw_log 是生产通道（debug.* 属性在 user 版设备上 app 读不到）：
        # 解析只认 "1"/"0"，其余与缺省都回 -1（不动、继续看属性），且在起局前落到 NativeBridge。
        activity = (JAVA / 'MainActivity.java').read_text()
        parse = activity[activity.index('private static int drawLogFromIntent'):]
        self.assertIn('"s2arm.draw_log"', parse)
        self.assertIn('return -1;', parse)
        self.assertIn('"1".equals(value)', parse)
        self.assertIn('"0".equals(value)', parse)
        start = activity[activity.index('    private void tryStartGame() {'):]
        bridge_call = start.index('NativeBridge.setDrawLog(drawLogFromIntent(getIntent()));')
        self.assertLess(bridge_call, start.index('exportPreviousShaderCache()'))
        bridge = (JAVA / 'NativeBridge.java').read_text()
        self.assertIn('static native void setDrawLog(int value);', bridge)

    def test_native_side_refuses_non_default_values_when_closed(self):
        bridge = (ANDROID / 'native/bridge.cpp').read_text()
        def body(name):
            return bridge.split('Java_org_s2arm_android_NativeBridge_' + name + '(')[1].split('extern "C"')[0]
        self.assertIn('if (!s2a_debug_entries_open()) return ENOTSUP;', body('configureDebugEnvironment'))
        self.assertIn('if (!s2a_debug_entries_open()) return EPERM;', body('configureDmaPreserveRead'))
        for name, cond in [('configureInlineSmeContext', '!enabled'), ('configureBufferReadScratch', 'enabled'),
                           ('configureSsboOobDiag', 'enabled'), ('configureProfileFreeze', 'enabled'),
                           ('configureReadonlyRangeCheck', '!enabled')]:
            self.assertIn(f'if ({cond} && !s2a_debug_entries_open()) return EPERM;', body(name), name)
        self.assertIn('if (value != "1" && !s2a_debug_entries_open()) return EPERM;', body('configureThreadedRenderer'))
        gate = (ANDROID / 'native/debug_gate.h').read_text()
        self.assertRegex(gate, r'#if defined\(S2A_ANDROID_DEBUG_ENV\) && defined\(__ANDROID__\)')
        self.assertIn('__system_property_get("debug.s2a.debug_env", value) == 1 && value[0] == \'1\'', gate)
        self.assertIn('$<$<CONFIG:Debug>:S2A_ANDROID_DEBUG_ENV=1>', (ANDROID / 'CMakeLists.txt').read_text())

    def test_frame_log_property_read_is_behind_debug_gate(self):
        # debug.s2a.frame_log 同属调试入口：读属性前必须先过 s2a_debug_entries_open()
        # （同 nvn_vk_compute_bridge.c 的 debug.s2a.compute_trace 写法），否则正式包也能被 adb 打开。
        src = (ANDROID / 'native/nvn/nvn_vk_frame_log.c').read_text()
        self.assertIn('#include "debug_gate.h"', src)
        body = src[src.index('static int s2a_fl_enabled'):src.index('int nvn_vk_frame_log_on')]
        self.assertLess(body.index('s2a_debug_entries_open()'), body.index('"debug.s2a.frame_log"'),
                        '读 debug.s2a.frame_log 前必须先调 s2a_debug_entries_open()')

    def test_release_build_type_is_signed_and_not_debuggable(self):
        gradle = (ANDROID / 'app/build.gradle').read_text()
        release = re.search(r'buildTypes \{ release \{([^}]*)\} \}', gradle).group(1)
        for want in ('debuggable false', 'jniDebuggable false', 'signingConfig signingConfigs.release'):
            self.assertIn(want, release)
        self.assertIn("'-storepass:file', releasePassFile.path", gradle)   # 口令不上命令行
        self.assertNotRegex(gradle, r'storePassword\s+[\'"][^\'"]+[\'"]')   # 口令不写死进仓库


if __name__ == '__main__':
    unittest.main()
