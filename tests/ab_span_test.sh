#!/bin/bash
# MARK 后改出帧状态的段（逻辑速度同局 A/B）不进判据（tools/ab_span.py 及读它的 game_fps / score_cells.fps_window / census native_rate、smooth；合成局目录，约 1 秒）：bash tests/ab_span_test.sh
# 门禁覆盖：tools/ab_span.py tools/game_fps.py tools/score_cells.py tools/census/census.py tools/frame_gate.py
# 合成局（期望手算，不跑被测实现推）：MARK 帧 100；A/B 段 #0 帧 101–700 每帧 16.667 ms（60 帧开段）；照常帧 701–1900 每帧 33.333 ms（30 帧）；
#   另有旁观段 #1（声音稳态，不改出帧状态）帧 800–900，不剔。host.log：段前帧节拍「交换间隔 2」，段内一行「交换间隔 1」，段后没有新帧节拍行；
#   没有 timing 行（native_rate 走 frames.tsv 兜底）
#   ① spans = [(101, 700)]（旁观段不收）；strip 去掉段内行；keep(100) 真、keep(101) 假、keep(701) 真
#   ② game_fps.target → 30（段内那行不算；旧实现取最后一行 = 60）
#   ③ score_cells.fps_window → 1200 帧、平均 30.0（剔掉段内 600 帧；旧实现 1800 帧、36.0）
#   ④ census.native_rate → 30.0（frames.tsv 剔段）
#   ⑤ census.smooth → 实测 30
#   ⑥ 开了没结束（局在段内收了）→ (101, ∞)；旧日志段行没有帧号 → 不收段（退回旧口径）
# 进程内重启（11-04 Duo 实测 rtv_job/out_1104121251：MARK 帧 3767 在重启前，frames.tsv 被新会话重写成 1..2089，五问 / 分配闸门窗口 0 帧）：
#   合成局 rs：host.log 同上（MARK 100、A/B 段 101–700）+「[心跳] 帧 3000」+ 重启提示行 +「[心跳] 帧 300」；frames.tsv = 重启后那段 1..1900，首行起点 wall 0、其余 16.667 ms
#   ⑦ frames_mark → (1, [])；fps_window → 1899 帧、平均 60.0（旧实现按重启前 MARK 100 与段 101–700 剔：1200 帧）
#   ⑧ 重启后那段又打了 MARK 帧 50 → (50, [])；fps_window 1850 帧
#   ⑨ Mac 形态（没有提示行，只有心跳帧号 3000 → 300 变小）→ 同 ⑦
#   ⑩ frame_gate.py --fps=60 读 rs → 「MARK 后 32 秒 1899 帧」（1899 × 16.667 ms = 31.65 秒；旧实现 MARK 100：30 秒 1800 帧）
set -u
R=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PYTHON:-python3}; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p $T/lg
"$PY" - "$T" <<'PY'
import sys, os, json
T = sys.argv[1]
h = ['[gal] 帧节拍：交换间隔 2，每帧 33.3 ms（30 帧/秒）', 'S2A 标记 MARK：帧 100',
     '自动玩家：MARK 后段开始「逻辑速度同局 A/B」（#0，改出帧状态，帧 101）', '[gal] 帧节拍：交换间隔 1，每帧 16.7 ms（60 帧/秒）',
     '自动玩家：MARK 后段结束「逻辑速度同局 A/B」（#0，帧 700）',
     '自动玩家：MARK 后段开始「声音稳态窗口」（#1，帧 800）', '自动玩家：MARK 后段结束「声音稳态窗口」（#1，帧 900）']
rows = ['frame\twall_us'] + [f'{f}\t{16667 if 101 <= f <= 700 else 33333}' for f in range(1, 1901)]
open(os.path.join(T, 'lg/host.log'), 'w').write('\n'.join(h) + '\n')
open(os.path.join(T, 'lg/frames.tsv'), 'w').write('\n'.join(rows) + '\n')
json.dump({'marked': True, 'mark_frame': 100}, open(os.path.join(T, 'lg/ap_summary.json'), 'w'))
PY
"$PY" - "$R" "$T" <<'PY'
import sys, os
R, T = sys.argv[1:]; sys.path[:0] = [os.path.join(R, 'tools'), os.path.join(R, 'tools/census')]
import ab_span, game_fps, score_cells, census
bad = 0
def ck(name, ok, got):
    global bad; print(('通 ' if ok else '不通 ') + f'{name}（实得 {got}）'); bad += 0 if ok else 1
hl = open(os.path.join(T, 'lg/host.log')).read()
sp = ab_span.spans(hl); st = ab_span.strip(hl)
ck('① spans = [(101, 700)]、旁观段不收、strip 去掉段内帧节拍、keep 边界', sp == [(101, 700)] and '交换间隔 1' not in st and '声音稳态窗口' in st
   and ab_span.keep(100, sp) and not ab_span.keep(101, sp) and ab_span.keep(701, sp), (sp, '交换间隔 1' in st))
f = game_fps.target(hl)[0]; ck('② 帧节拍按段外最后一行 → 30', f == 30.0, f)
w = score_cells.fps_window(os.path.join(T, 'lg'), 100)[2]; avg = len(w) * 1000 / sum(w)
ck('③ fps_window 剔掉段内 → 1200 帧、平均 30.0', len(w) == 1200 and abs(avg - 30.0) < 0.05, (len(w), round(avg, 2)))
n = census.native_rate(os.path.join(T, 'lg')); ck('④ native_rate（frames.tsv 兜底）剔段 → 30.0', n.startswith('30.0'), n)
s = census.smooth(os.path.join(T, 'lg')); ck('⑤ smooth 实测 30', s.endswith('实测 30'), s)
h2 = hl.replace('自动玩家：MARK 后段结束「逻辑速度同局 A/B」（#0，帧 700）\n', '')
h3 = hl.replace('，改出帧状态，帧 101）', '，改出帧状态）')
ck('⑥ 开了没结束 → (101, ∞)；旧日志没帧号 → 不收', ab_span.spans(h2) == [(101, float('inf'))] and ab_span.spans(h3) == [], (ab_span.spans(h2), ab_span.spans(h3)))
import subprocess
rsd = os.path.join(T, 'rs'); os.makedirs(rsd, exist_ok=True)
RL = '[s2a] iOS 重启：provider 已就绪，guest 首启前时钟/线程/GPU hold 已建立'
def mkrs(extra_after='', restart_line=True):
    h = hl + '[心跳] 帧 3000，热状态 0\n' + (RL + '\n' if restart_line else '') + '[心跳] 帧 300，热状态 0\n' + extra_after + '[s2a] 图形模式：直连\n'
    open(os.path.join(rsd, 'host.log'), 'w').write(h)
    open(os.path.join(rsd, 'frames.tsv'), 'w').write('frame\twall_us\talloc_b\tgc0\tgc1\n' + ''.join(f'{f}\t{0 if f == 1 else 16667}\t0\t0\t0\n' for f in range(1, 1901)))
    return h
def win(): w = score_cells.fps_window(rsd, score_cells.frame_mark(rsd, 100))[2]; return len(w), round(len(w) * 1000 / sum(w), 2) if w else None
h = mkrs(); ck('⑦ 重启后没 MARK → frames_mark (1, [])、fps_window 1899 帧 60.0', ab_span.frames_mark(h) == (1, []) and win() == (1899, 60.0), (ab_span.frames_mark(h), win()))
h = mkrs('S2A 标记 MARK：帧 50\n'); ck('⑧ 重启后那段 MARK 50 → (50, [])、1850 帧', ab_span.frames_mark(h) == (50, []) and win()[0] == 1850, (ab_span.frames_mark(h), win()))
h = mkrs(restart_line=False); ck('⑨ Mac 形态（心跳帧号变小）→ 同 ⑦', ab_span.frames_mark(h) == (1, []) and win() == (1899, 60.0), (ab_span.frames_mark(h), win()))
mkrs(); g = subprocess.run([sys.executable, os.path.join(R, 'tools/frame_gate.py'), rsd, '--fps=60'], capture_output=True, text=True).stdout
ck('⑩ frame_gate 重启局 → MARK 后 32 秒 1899 帧', 'MARK 后 32 秒 1899 帧' in g, g.strip()[:120])
print('ab_span 单测全过' if not bad else 'ab_span 单测有不通'); sys.exit(1 if bad else 0)
PY
# 11-26 门禁搬到另一台协调机后的派活验证：本行只改键、不改行为
