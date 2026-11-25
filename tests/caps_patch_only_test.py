#!/usr/bin/env python3
"""能力清单「只用社区补丁」口径（tools/caps_policy.py decide，11-13 维护者撤掉我方 60 帧与通用满屏）。临时产物根，期望按规则手写：
  ① 有社区帧率补丁（cpatch.tsv 编号 fps:）+ 我方帧率表 fps.tsv + 我方宽屏表、本构建号没有逻辑速度同局 A/B 账 → fps60 0（原帧率，原因含「社区帧率补丁」好让开关照样出）、widen 0、fps60_display 0
  ⑤ 社区帧率补丁 + 本构建号同局 A/B（11-23 #2120，账在仓库 docs/名单_60帧逻辑速度/<程序号>.tsv）：绿且 ≥ 11-13 → fps60 1（原因含补丁与「逻辑速度同局 A/B 绿」）；
     绿但 11-07（那时 A/B 切的是我方 60 帧层，不是补丁）→ 0；红 → 0；别的构建号的绿 → 0
  ② 只有我方帧率表与宽屏表、没有社区补丁 → fps60 0、widen 0、fps60_display 0
  ③ 只有社区宽屏补丁 → fps60 0、widen 0（社区宽屏补丁走自己的开关，不看这一键）
  ④ 在宽屏已验证名单（产物根 widen_verified.tsv）、没有社区补丁 → widen 1（11-15 维护者「两者合成一套」：验过的款用我方通用满屏）
  反证：S2A_CAPS_OWN=1 时 ② 的 fps60 回到 1（我方帧率表算来源）；去掉 patch_ab_green 的日期门槛 → ⑤b 红；改回「有补丁就开」→ ①、⑤b、⑤c 红；去掉红那一档原因 → ⑤c 红"""
import os, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
import caps_policy as cp

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
bad = n = 0
def ck(name, ok):
    global bad, n
    n += 1; bad += 0 if ok else 1; print(('✓ ' if ok else '✗ ') + name)

def root(t, fps_patch=False, ws_patch=False, own=False, verified=False):
    os.makedirs(t, exist_ok=True)
    rows = ['编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅']
    if fps_patch: rows.append('fps:aaaa\tsdk\t0\tfps\tx\t\to\t\t1\t120\t')
    if ws_patch: rows.append('widescreen:bbbb\tmain\t1\twidescreen\tx\t\to\t\t1\t\t2.3333')
    open(os.path.join(t, 'cpatch.tsv'), 'w').write('\n'.join(rows) + '\n')
    if own:
        open(os.path.join(t, 'fps.tsv'), 'w').write('# x\npresent\tdisplay\n')
        open(os.path.join(t, 'widen_enable.handheld.tsv'), 'w').write('a\t1\n')
    if verified: open(os.path.join(t, 'widen_verified.tsv'), 'w').write('0100000000000000\t' + '0' * 32 + '\tx\tapple\n')
    return t

os.environ.pop('S2A_CAPS_OWN', None)
with tempfile.TemporaryDirectory() as d:
    r1 = cp.decide(REPO, root(os.path.join(d, 'r1'), fps_patch=True, own=True))
    ck(f'① 帧率补丁 + 我方表、没有 A/B 账 → fps60 0 带「社区帧率补丁」、widen 0、display 0（{r1}）',
       r1['fps60'][0] == 0 and '社区帧率补丁' in r1['fps60'][1] and r1['widen'][0] == 0 and r1['fps60_display'] == 0)
    # ⑤ 假仓库（只放 A/B 账）+ 带身份的产物根（unpack.tsv 程序号、exefs/main 0x40 处构建号）
    PID, BID = '0100AAAA00000000', bytes(range(16)).hex()
    def ab(conc, date, bid=BID):
        repo = os.path.join(d, 'repo_' + conc + date); os.makedirs(os.path.join(repo, 'docs', '名单_60帧逻辑速度'), exist_ok=True)
        open(os.path.join(repo, 'docs', '名单_60帧逻辑速度', PID + '.tsv'), 'w').write(
            '程序号\t构建号\t款\t结论\tρ\tq\t依据\t日期\t放行\n' + f'{PID}\t{bid}\t{PID}\t{conc}\t1.00\t1.00\t测\t{date}\t\n')
        r = root(os.path.join(d, 'id_' + conc + date + bid[:4]), fps_patch=True)
        open(os.path.join(r, 'unpack.tsv'), 'w').write(f'title_id\t{PID}\n'); os.makedirs(os.path.join(r, 'exefs'), exist_ok=True)
        open(os.path.join(r, 'exefs', 'main'), 'wb').write(b'\0' * 0x40 + bytes(range(16)) + b'\0' * 16)
        return cp.decide(repo, r)['fps60']
    a = ab('绿', '2026-11-20'); ck(f'⑤a 补丁 + 本构建号 A/B 绿（11-20）→ fps60 1、原因带 A/B 绿（{a}）', a[0] == 1 and '社区帧率补丁' in a[1] and '逻辑速度同局 A/B 绿' in a[1])
    b = ab('绿', '2026-11-07'); ck(f'⑤b 补丁 + A/B 绿但 11-07（测的是我方 60 帧层）→ 0（{b}）', b[0] == 0)
    c = ab('红', '2026-11-20'); ck(f'⑤c 补丁 + A/B 红 → 0、原因带「逻辑速度同局 A/B 红」（宿主据此不给再试 60 帧，{c}）', c[0] == 0 and '逻辑速度同局 A/B 红' in c[1])
    c2 = ab('红', '2026-11-07'); ck(f'⑤e 补丁 + A/B 红但 11-07（测的不是补丁）→ 0、原因不带「A/B 红」（{c2}）', c2[0] == 0 and '逻辑速度同局 A/B 红' not in c2[1])
    e = ab('绿', '2026-11-20', bid='ff' * 16); ck(f'⑤d 补丁 + 别的构建号的 A/B 绿 → 0（{e}）', e[0] == 0)
    r2 = cp.decide(REPO, root(os.path.join(d, 'r2'), own=True))
    ck(f'② 只有我方表 → 全 0（{r2}）', r2['fps60'][0] == 0 and r2['widen'][0] == 0 and r2['fps60_display'] == 0)
    r3 = cp.decide(REPO, root(os.path.join(d, 'r3'), ws_patch=True))
    ck(f'③ 只有宽屏补丁 → fps60 0、widen 0（{r3}）', r3['fps60'][0] == 0 and r3['widen'][0] == 0)
    r5 = cp.decide(REPO, root(os.path.join(d, 'r5'), verified=True))
    ck(f'④ 在宽屏已验证名单、没有补丁 → widen 1（{r5["widen"]}）', r5['widen'][0] == 1 and '已验证名单' in r5['widen'][1])
    os.environ['S2A_CAPS_OWN'] = '1'
    try:
        r4 = cp.decide(REPO, os.path.join(d, 'r2'), all_caps=True)
        ck(f'反证：S2A_CAPS_OWN=1 → ② 的 fps60 回到 1（{r4["fps60"]}）', r4['fps60'][0] == 1)
    finally:
        os.environ.pop('S2A_CAPS_OWN', None)
print(f'caps_patch_only：{n} 项，红 {bad}'); sys.exit(1 if bad else 0)
