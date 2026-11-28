#!/bin/bash
# 门禁覆盖：graphics/nvn/gfx/nvn/*.m graphics/nvn/gfx/nvn/*.inc
# 回放借用守卫单测（约 1 秒）：bash tests/borrow_release_lint_test.sh
# 回放线程借用（不持有）这些表里的对象：纹理 ID 的视图（treg_t view / ar / im / alt）、视图缓存（vc_set view[]）、包贴图视图（rp->view）、序号表 g_by_serial、
#   管线缓存 g_pso（perf/replay-borrow）。借用安全的前提：持有者放手时走延迟释放（defer_obj_unref / defer_obj_release：记 g_fence + 1，本次提交做完才真放）。
#   有人改成直接 CFRelease 不经延迟，正在编码的这次提交就会拿着已释放的对象（释放后使用）。期望（按规则手写）：
#   ① nvn_mtl.m 里 CFRelease 这些持有字段的每一行，同一行在它之前先有 defer_obj_unref(
#   ② 从 g_by_serial 删条目（hm_del_id(&g_by_serial，或带反向索引的 ser_map_del_locked(SR_LIVE, &g_by_serial，#2299）的每一行，同一行有 defer_obj_ 或写明「borrow-safe:」与谁持有
#   ③ 整表清空 g_by_serial / g_pso、从 g_pso 删条目只出现在会话重置 nvn_session.inc（会话重置时没有在编码的提交）
#   ④ 正对照：规则对手写的坏行都报、好行都不报（规则真能红）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); cd "$H" || exit 1
python3 - <<'PY'
import re, glob, sys
HOLD = re.compile(r'CFRelease\(\s*(?:\(__bridge [^)]*\)\s*)?(?:r|rp|s)->(?:view|ar|im|alt)(?:\[[^\]]*\])?\s*\)')
def bad_release(line):   # ①：持有字段的 CFRelease 前面同一行没有 defer_obj_unref(
    m = HOLD.search(line); return bool(m) and 'defer_obj_unref(' not in line[:m.start()]
SDEL = re.compile(r'hm_del_id\(\s*&g_by_serial\b|ser_map_del_locked\(\s*SR_LIVE\s*,\s*&g_by_serial\b')   # ② 两种删法：裸表、带反向索引（ser_map_del_locked 里 CFRelease 表的那份引用）
def bad_serial_del(line):   # ②
    return bool(SDEL.search(line)) and 'defer_obj_' not in line and 'borrow-safe:' not in line
CLR = re.compile(r'nvn_hm_clear\(\s*&g_(?:by_serial|pso)\b|nvn_hm_del\(\s*&g_pso\b|hm_del_id\(\s*&g_pso\b')
def bad_clear(path, line): return bool(CLR.search(line)) and not path.endswith('nvn_session.inc')   # ③
fails = []
def ck(what, ok):
    print(('通 ' if ok else '不通 ') + what); fails.append(what) if not ok else None
files = sorted(glob.glob('graphics/nvn/gfx/nvn/*.m') + glob.glob('graphics/nvn/gfx/nvn/*.inc'))
hits = {1: [], 2: [], 3: []}; n1 = n2 = 0
for p in files:
    for i, l in enumerate(open(p, encoding='utf-8', errors='replace'), 1):
        if HOLD.search(l): n1 += 1
        if SDEL.search(l): n2 += 1
        if bad_release(l): hits[1].append(f'{p}:{i}')
        if bad_serial_del(l): hits[2].append(f'{p}:{i}')
        if bad_clear(p, l): hits[3].append(f'{p}:{i}')
ck(f'① 持有字段的 CFRelease {n1} 处，前面都先 defer_obj_unref（违规：{hits[1][:5]}）', n1 > 0 and not hits[1])
ck(f'② 从 g_by_serial 删条目 {n2} 处，都经延迟释放或写明 borrow-safe（违规：{hits[2][:5]}）', n2 > 0 and not hits[2])
ck(f'③ 整表清空 g_by_serial / g_pso 只在会话重置（违规：{hits[3][:5]}）', not hits[3])
bad = ['    if (r->view) { CFRelease(r->view); r->view = NULL; }', 'CFRelease(s->view[i]); defer_obj_unref((__bridge id)s->view[i]);', 'if (x) CFRelease((__bridge CFTypeRef)rp->view);']
good = ['    if (r->view) { defer_obj_unref((__bridge id)r->view); CFRelease(r->view); r->view = NULL; }', 'CFRelease(old);']
ck('④ 正对照：手写坏行（直接释放、先释放后延迟、带桥接）都报，好行不报',
   all(bad_release(b) for b in bad) and not any(bad_release(g) for g in good)
   and bad_serial_del('hm_del_id(&g_by_serial, &k);') and not bad_serial_del('defer_obj_unref(old); hm_del_id(&g_by_serial, &k);')
   and bad_serial_del('ser_map_del_locked(SR_LIVE, &g_by_serial, k);') and not bad_serial_del('defer_obj_release(old); ser_map_del_locked(SR_LIVE, &g_by_serial, k);')
   and bad_clear('x/nvn_mtl.m', 'nvn_hm_clear(&g_pso, hm_rel);') and not bad_clear('x/nvn_session.inc', 'nvn_hm_clear(&g_pso, hm_rel);'))
print('回放借用守卫单测：' + ('全过' if not fails else f'不通 {len(fails)} 项'))
sys.exit(1 if fails else 0)
PY
