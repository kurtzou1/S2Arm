#!/usr/bin/env python3
"""能力清单「只用社区补丁」口径（tools/caps_policy.py decide，11-13 维护者撤掉我方 60 帧与通用满屏）。临时产物根，期望按规则手写：
  ① 有社区帧率补丁（cpatch.tsv 编号 fps:）+ 我方帧率表 fps.tsv + 我方宽屏表 → fps60 1（原因含「社区帧率补丁」，宿主 caps.c 据此认已验证）、widen 0、fps60_display 0
  ② 只有我方帧率表与宽屏表、没有社区补丁 → fps60 0、widen 0、fps60_display 0
  ③ 只有社区宽屏补丁 → fps60 0、widen 0（社区宽屏补丁走自己的开关，不看这一键）
  反证：S2A_CAPS_OWN=1 时 ② 的 fps60 回到 1（我方帧率表算来源）"""
import os, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
import caps_policy as cp

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
bad = n = 0
def ck(name, ok):
    global bad, n
    n += 1; bad += 0 if ok else 1; print(('✓ ' if ok else '✗ ') + name)

def root(t, fps_patch=False, ws_patch=False, own=False):
    os.makedirs(t, exist_ok=True)
    rows = ['编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅']
    if fps_patch: rows.append('fps:aaaa\tsdk\t0\tfps\tx\t\to\t\t1\t120\t')
    if ws_patch: rows.append('widescreen:bbbb\tmain\t1\twidescreen\tx\t\to\t\t1\t\t2.3333')
    open(os.path.join(t, 'cpatch.tsv'), 'w').write('\n'.join(rows) + '\n')
    if own:
        open(os.path.join(t, 'fps.tsv'), 'w').write('# x\npresent\tdisplay\n')
        open(os.path.join(t, 'widen_enable.handheld.tsv'), 'w').write('a\t1\n')
    return t

os.environ.pop('S2A_CAPS_OWN', None)
with tempfile.TemporaryDirectory() as d:
    r1 = cp.decide(REPO, root(os.path.join(d, 'r1'), fps_patch=True, own=True))
    ck(f'① 帧率补丁 + 我方表 → fps60 1 带「社区帧率补丁」、widen 0、display 0（{r1}）',
       r1['fps60'][0] == 1 and '社区帧率补丁' in r1['fps60'][1] and r1['widen'][0] == 0 and r1['fps60_display'] == 0)
    r2 = cp.decide(REPO, root(os.path.join(d, 'r2'), own=True))
    ck(f'② 只有我方表 → 全 0（{r2}）', r2['fps60'][0] == 0 and r2['widen'][0] == 0 and r2['fps60_display'] == 0)
    r3 = cp.decide(REPO, root(os.path.join(d, 'r3'), ws_patch=True))
    ck(f'③ 只有宽屏补丁 → fps60 0、widen 0（{r3}）', r3['fps60'][0] == 0 and r3['widen'][0] == 0)
    os.environ['S2A_CAPS_OWN'] = '1'
    try:
        r4 = cp.decide(REPO, os.path.join(d, 'r2'), all_caps=True)
        ck(f'反证：S2A_CAPS_OWN=1 → ② 的 fps60 回到 1（{r4["fps60"]}）', r4['fps60'][0] == 1)
    finally:
        os.environ.pop('S2A_CAPS_OWN', None)
print(f'caps_patch_only：{n} 项，红 {bad}'); sys.exit(1 if bad else 0)
