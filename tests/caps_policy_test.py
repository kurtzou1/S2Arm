#!/usr/bin/env python3
"""tools/caps_policy.py 引擎通用第一层来源单测（10-29 60 帧泛化；引擎推导替成假的，不读游戏数据）：
  ① 没有帧率表 / 社区帧率补丁，引擎推导可放开（Unity / UE4）→ fps60 1、来源「引擎通用第一层」
  ② 已有帧率表 → 来源只记 fps.tsv，不叠引擎通用（我方表优先，免两套）
  ③ 引擎推导不可放开（非 Unity / UE）→ fps60 1、来源「引擎通用：放开出图间隔（全引擎）」、fps60_display 1（11-02 60 帧扩到所有引擎）
  ④ 引擎可放开但强信号表有逻辑速度红 → fps60 0（强信号压过来源）
  ⑤ 产物根没有 exefs / romfs → engine_l1 为 False、不抛异常
  ⑥–⑫ 实测退回（10-29 维护者）：验证账同程序号 + 构建号 + fps60 内容哈希、60 帧开着的局，持续 < 57 帧或 > 4.8 W → fps60 0；
      哈希不同（实现 / 数据改了）、实测两列为 -（那局 60 帧关）、--all-caps → 照开；能耗线常量与 score_cells 一致"""
import os, sys, tempfile
os.environ['S2A_CAPS_OWN'] = '1'   # 本测的是我方 60 帧 / 满屏旧口径（11-13 起发布缺省只用社区补丁，见 tests/caps_patch_only_test.py）
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
import caps_policy as cp

bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f'{"🟢" if ok else "🔴"} {name}' + ('' if ok else f'：期望「{want}」→ 真结果「{got}」'))

T = tempfile.mkdtemp(); root = os.path.join(T, 'root'); repo = os.path.join(T, 'repo'); os.makedirs(os.path.join(root, 'exefs')); os.makedirs(os.path.join(repo, 'docs'))
open(os.path.join(root, 'unpack.tsv'), 'w').write('title_id\t0100000000ABC000\n')
b = bytearray(0x100); b[0:4] = b'NSO0'; b[0x40:0x50] = bytes.fromhex('aa' * 16); open(os.path.join(root, 'exefs', 'main'), 'wb').write(b)
real = cp.engine_l1
cp.engine_l1 = lambda r: True
d = cp.decide(repo, root)
chk('① 引擎可放开、无别的来源 → fps60 1 引擎通用第一层', (1, True), (d['fps60'][0], '引擎通用第一层' in d['fps60'][1]))
open(os.path.join(root, 'fps.tsv'), 'w').write('build aa\n')
d = cp.decide(repo, root)
chk('② 已有帧率表 → 只记 fps.tsv', '默认开：来源 fps.tsv', d['fps60'][1]); os.remove(os.path.join(root, 'fps.tsv'))
cp.engine_l1 = lambda r: False
d = cp.decide(repo, root)
chk('③ 非 Unity / UE → fps60 1 引擎通用全引擎档 + fps60_display 1', (1, True, 1), (d['fps60'][0], '引擎通用：放开出图间隔（全引擎' in d['fps60'][1], d['fps60_display']))
d = cp.decide(repo, root); cp.engine_l1 = lambda r: True; d1 = cp.decide(repo, root)
chk('③b Unity / UE 推导放开 → 宿主自己放开，不写 fps60_display', 0, d1['fps60_display'])
# ③c 满屏发布缺省关（维护者 11-02 19:0x）。期望手算：夹具只有第三层（无逐款表）→ 发布 widen 0「发布缺省关」、fps60 照开 1；--all-caps → widen 1；
#   带 widen_verified.tsv（真机验过）→ 发布 widen 1。之后 ⑭–⑳ 测满屏强信号机制，夹具保留 widen_verified.tsv（新口径下只有这类款满屏会开）
d = cp.decide(repo, root)
chk('③c 发布、只有第三层 → widen 0 发布缺省关、fps60 1', (0, True, 1), (d['widen'][0], d['widen'][1].startswith('发布缺省关'), d['fps60'][0]))
chk('③c --all-caps → widen 1', 1, cp.decide(repo, root, all_caps=True)['widen'][0])
open(os.path.join(root, 'widen_verified.tsv'), 'w').write('0100000000ABC000\t' + 'aa' * 16 + '\n')
chk('③c 带 widen_verified.tsv → 发布 widen 1', 1, cp.decide(repo, root)['widen'][0])
cp.engine_l1 = lambda r: True
import reglist, shutil   # 强信号表按款登记目录（10-30）：夹具经 reglist.write 拆成 docs/名单_能力强信号/<程序号>.tsv
SH = lambda cap, h: reglist.write(repo, '名单_能力强信号', 
    '程序号\t构建号\t能力\t内容哈希\t信号\t依据\t日期\n0100000000ABC000\t' + 'aa' * 16 + f'\t{cap}\t{h}\t' + ('逻辑速度红' if cap == 'fps60' else '宽屏画面坏') + '\t对照局\t2026-10-29\n')
SH('fps60', cp.signal_hashes(cp.repo_reader(repo))['fps60'])
d = cp.decide(repo, root)
chk('④ 逻辑速度红压过引擎通用 → fps60 0', (0, True), (d['fps60'][0], '逻辑速度红' in d['fps60'][1]))
reglist.write(repo, '名单_能力强信号', '程序号\t构建号\t能力\t内容哈希\t信号\t依据\t日期\n0100000000ABC000\t' + 'aa' * 16 + '\tfps60\t' + cp.signal_hashes(cp.repo_reader(repo))['fps60'] + '\t帧率达不到\t60 帧档 52 帧、提交线程 20 ms\t2026-10-31\n')
d = cp.decide(repo, root)
chk('④b 登记「帧率达不到」（10-31）→ fps60 0、原因带信号与依据', (0, True, True), (d['fps60'][0], '帧率达不到' in d['fps60'][1], '提交线程 20 ms' in d['fps60'][1]))
cp.engine_l1 = real
chk('⑤ 没有 romfs 的根 → engine_l1 False、不抛', False, cp.engine_l1(root))
# ⑤b 推导本身出错（exefs/main 是目录、读不了）→ 照旧 False 不中断出包，但错误输出要有【红】行（审计 P1-138：原先静默当「不是 Unity / UE」）
import io, contextlib
bad_root = tempfile.mkdtemp(); os.makedirs(os.path.join(bad_root, 'exefs', 'main')); os.makedirs(os.path.join(bad_root, 'romfs'))
err = io.StringIO()
with contextlib.redirect_stderr(err): r5 = cp.engine_l1(bad_root)
chk('⑤b 推导出错 → engine_l1 False、错误输出带【红】', (False, True), (r5, '【红】' in err.getvalue()))
shutil.rmtree(bad_root)
# ⑥–⑫ 实测退回：期望按规则手算（< 57 帧或 > 4.8 W 才关），不跑被测实现推期望
import caps_ledger, score_cells
shutil.rmtree(os.path.join(repo, 'docs', '名单_能力强信号')); open(os.path.join(root, 'fps.tsv'), 'w').write('build aa\n')
H = cp.cap_hashes(root, repo)['fps60']
def ledger(*rows):
    with open(os.path.join(repo, caps_ledger.LEDGER), 'w', encoding='utf-8') as f:
        f.write('\t'.join(caps_ledger.HEAD) + '\n')
        for x in rows: h, fps, w = x[:3]; f.write('\t'.join(['0100000000ABC000', 'aa' * 16, 'fps60', h, 'iPhone17,2', '不过', '贡献者验证', 'fp01', 'me', '2026-10-29', fps, w, x[3] if len(x) > 3 else '-']) + '\n')
ledger((H, '32.00', '7.29')); d = cp.decide(repo, root)
chk('⑥ 32 帧 / 7.29 W → fps60 0，两条原因都写', (0, True, True, True), (d['fps60'][0], '实测未达标' in d['fps60'][1], '持续 32.0 帧 < 57' in d['fps60'][1], '7.29 W > 4.8 W' in d['fps60'][1]))
ledger((H, '58.00', '4.50')); chk('⑦ 58 帧 / 4.50 W → 照开', 1, cp.decide(repo, root)['fps60'][0])
ledger((H, '59.50', '5.10')); d = cp.decide(repo, root)
chk('⑧ 59.5 帧 / 5.10 W → 只因能耗关', (0, False, True), (d['fps60'][0], '帧 <' in d['fps60'][1], '5.10 W > 4.8 W' in d['fps60'][1]))
ledger(('0' * 16, '32.00', '7.29')); chk('⑨ 内容哈希不同（实现 / 数据改了）→ 照开、重新实测', 1, cp.decide(repo, root)['fps60'][0])
ledger((H, '-', '-')); chk('⑩ 实测两列为 -（那局 60 帧关）→ 照开', 1, cp.decide(repo, root)['fps60'][0])
ledger((H, '32.00', '7.29')); chk('⑪ --all-caps 不看实测 → 开', 1, cp.decide(repo, root, all_caps=True)['fps60'][0])
chk('⑫ 能耗线常量与 score_cells.W_MAX60 一致', score_cells.W_MAX60, cp.W60_MAX)
# ⑫b 自适应款（帧率表带 speed 行）：平均帧率低不退回，只看能耗线。期望手算：32 帧 / 4.5 W → 开；32 帧 / 7.29 W → 关、原因只写能耗
open(os.path.join(root, 'fps.tsv'), 'w').write('build aa\nspeed 2040 0.5 2.0\n'); H = cp.cap_hashes(root, repo)['fps60']
ledger((H, '32.00', '4.50')); chk('⑫b 自适应款 32 帧 / 4.50 W → 照开（撑不住落 30、速度不变，不整个退回）', 1, cp.decide(repo, root)['fps60'][0])
ledger((H, '32.00', '7.29')); d = cp.decide(repo, root)
chk('⑫b 自适应款 32 帧 / 7.29 W → 关、原因只写能耗', (0, False, True), (d['fps60'][0], '帧 <' in d['fps60'][1], '7.29 W > 4.8 W' in d['fps60'][1]))
# ⑫c 自适应款按主档位选能耗线（10-29 维护者）。期望手算：60 档占比 0.2（主要稳 30）、4.2 W > 3.7 → 关；占比 0.8、4.2 W ≤ 4.8 → 开；占比未知（-）、4.2 W → 按 60 线开
ledger((H, '35.00', '4.20', '0.200')); d = cp.decide(repo, root)
chk('⑫c 自适应 60 档 20%、4.20 W → 按 30 帧线 3.7 关、原因带占比', (0, True), (d['fps60'][0], '4.20 W > 3.7 W（自适应，60 档占比 20%）' in d['fps60'][1]))
ledger((H, '52.00', '4.20', '0.800')); chk('⑫c 自适应 60 档 80%、4.20 W → 按 60 帧线开', 1, cp.decide(repo, root)['fps60'][0])
ledger((H, '35.00', '4.20')); chk('⑫c 自适应 占比未知、4.20 W → 按 60 帧线开（不误关）', 1, cp.decide(repo, root)['fps60'][0])
chk('⑫c 30 帧能耗线常量与 score_cells.W_MAX 一致', score_cells.W_MAX, cp.W30_MAX)
open(os.path.join(root, 'fps.tsv'), 'w').write('build aa\n')
# ⑬–⑯ 强信号按内容哈希自动失效（10-29 维护者：马车8 轮胎页残留在 a3a855b78 修好后仍关满屏）。期望按规则手算：登记哈希 = 本包哈希才生效
os.remove(os.path.join(repo, caps_ledger.LEDGER)); HW = cp.signal_hashes(cp.repo_reader(repo))['widen']
SH('widen', HW); d = cp.decide(repo, root)
chk('⑬ 登记哈希 = 本包 widen 哈希 → widen 0、原因是强信号', (0, True), (d['widen'][0], d['widen'][1].startswith('强信号：宽屏画面坏')))
SH('widen', '0123456789abcdef'); d = cp.decide(repo, root)
chk('⑭ 登记哈希 ≠ 本包（实现改过）→ 照旧 widen 0（10-30：保持关、过时·待重新实测）、原因注明可能过时', (0, True), (d['widen'][0], '强信号可能过时：登记哈希 0123456789abcdef' in d['widen'][1] and '待重新实测' in d['widen'][1]))
# ⑭b–⑭e 过时·待重新实测（10-30 维护者定 (B)）。期望按规则手算：验证账同程序号 + 构建号 + widen + 本包内容哈希、结论过、没冲突 → 放开；
#   只在旧内容哈希下过 → 仍关；本包哈希下过但信任冲突 → 仍关；复测清单列出这条（登记 0123…、当前 = 本包实现哈希）
def wledger(h, res='过', trust='贡献者验证'):
    with open(os.path.join(repo, caps_ledger.LEDGER), 'w', encoding='utf-8') as f:
        f.write('\t'.join(caps_ledger.HEAD) + '\n' + '\t'.join(['0100000000ABC000', 'aa' * 16, 'widen', h, 'iPhone17,2', res, trust, 'fpw1', 'me', '2026-10-30']
                + ['-'] * (len(caps_ledger.HEAD) - 10)) + '\n')
HCW = cp.cap_hashes(root, repo)['widen']
chk('⑭a 过时 → 原因带「过时·待重新实测」', True, cp.decide(repo, root)['widen'][1].startswith('强信号（过时·待重新实测）'))
wledger(HCW); d = cp.decide(repo, root)
chk('⑭b 本包内容哈希下实测过 → widen 1、原因提示删登记行', (1, True), (d['widen'][0], '请删掉这行登记' in d['widen'][1]))
wledger('ffffffffffffffff'); chk('⑭c 只在旧内容哈希下过 → 仍 widen 0', 0, cp.decide(repo, root)['widen'][0])
wledger(HCW, trust='冲突'); chk('⑭d 本包哈希下过但信任冲突 → 仍 widen 0', 0, cp.decide(repo, root)['widen'][0])
wledger(HCW, res='不过'); chk('⑭d 本包哈希下实测不过 → 仍 widen 0', 0, cp.decide(repo, root)['widen'][0])
os.remove(os.path.join(repo, caps_ledger.LEDGER))
chk('⑭e 复测清单列出过时的这条', [('0100000000ABC000', 'widen', '0123456789abcdef', cp.signal_hashes(cp.repo_reader(repo))['widen'])],
    [(x[0], x[2], x[4], x[5]) for x in cp.retest_list(repo)])
SH('widen', ''); err = ''
try: cp.decide(repo, root)
except ValueError as e: err = str(e)
chk('⑮ 内容哈希空着 → 报错（必填，不悄悄当永久强信号）', True, '内容哈希' in err)
SH('widen', HW); w0 = cp.signal_hashes(cp.repo_reader(repo))['widen']
os.makedirs(os.path.join(repo, 'graphics', 'widen'), exist_ok=True); open(os.path.join(repo, 'graphics', 'widen', 'WidenSession.cs'), 'w').write('// 改了\n')
d = cp.decide(repo, root)
chk('⑯ 改 C# 宽屏层 WidenSession.cs → 实现哈希变、强信号照旧生效 widen 0（10-30：不再按哈希自动撤）', (True, 0), (cp.signal_hashes(cp.repo_reader(repo))['widen'] != w0, d['widen'][0]))
open(os.path.join(root, 'widen_enable.handheld.tsv'), 'w').write('x\n'); SH('widen', cp.signal_hashes(cp.repo_reader(repo))['widen'])
chk('⑰ 只改包里数据（加宽屏表）→ 实现哈希不变、强信号照旧生效（能力卡看不到包里数据，两边一致）', 0, cp.decide(repo, root)['widen'][0])
# ⑱–⑳ 宽屏开 / 关实测对照自动强信号（10-30 #996）。期望手算：账里同构建「开宽屏、widen 哈希 = 本包」的报告画面不过 + 「关宽屏」的报告画面过 → widen 0、
#   原因带两份报告指纹；只有开着不过、没有关着的对照 → 照开；开着那份哈希不同（宽屏实现改过）→ 照开
shutil.rmtree(os.path.join(repo, 'docs', '名单_能力强信号'), ignore_errors=True)   # 清掉 ⑬–⑰ 的登记（按款登记目录，10-30；过时的强信号照旧关，不清会压过本段的对照）
HWD = cp.cap_hashes(root, repo)['widen']
def wl(*reps):   # (指纹, 本局满屏, 画面结论, widen 哈希)
    with open(os.path.join(repo, caps_ledger.LEDGER), 'w', encoding='utf-8') as f:
        f.write('\t'.join(caps_ledger.HEAD) + '\n')
        for fp, wd, pic, h in reps:
            base = ['0100000000ABC000', 'aa' * 16]
            for cap, hh, res in (('画面', '-', pic), ('widen', h, '过')):
                row = dict.fromkeys(caps_ledger.HEAD, '-'); row.update(zip(['程序号', '构建号', '能力', '内容哈希', '机型', '结论', '信任', '报告指纹', '贡献者', '日期'],
                                                                         base + [cap, hh, 'iPhone16,1', res, '贡献者验证', fp, 'x', '2026-10-30']))
                row['本局满屏'] = wd; f.write('\t'.join(row[k] for k in caps_ledger.HEAD) + '\n')
wl(('fpon', '开', '不过', HWD), ('fpoff', '关', '过', HWD)); d = cp.decide(repo, root)
chk('⑱ 开宽屏画面不过（同哈希）+ 关宽屏画面过 → widen 0、原因带两份报告', (0, True), (d['widen'][0], 'fpon' in d['widen'][1] and 'fpoff' in d['widen'][1]))
wl(('fpon', '开', '不过', HWD)); chk('⑲ 只有开宽屏不过、没有关宽屏对照 → 照开', 1, cp.decide(repo, root)['widen'][0])
wl(('fpon', '开', '不过', '0' * 16), ('fpoff', '关', '过', HWD)); chk('⑳ 开着那份报告的 widen 哈希不同（宽屏实现改过）→ 照开、重新实测', 1, cp.decide(repo, root)['widen'][0])
os.remove(os.path.join(repo, caps_ledger.LEDGER))
# ㉑ 日志文本和判定逻辑分开（10-30 维护者：只剔日志调用实参）。期望手写：只改日志调用里的文本 / 注释 / 空白 → 规范文本相同；
#   改比较符、改环境变量名、改含空格的 MSL 模板、改 printf / 往文件写的格式串、改 Python 常量 / stdout 输出格式 → 不同
C0 = ('static int f(int v) {\n    const char *e = getenv("S2A_X"); // 开关\n    if (v > 1920) { LOG("宽屏：放开（来源：%s）", e); MLOG("w %d", v); return 1; }\n'
      '    fprintf(stderr, "dbg %d\\n", v); fprintf(f, "%d %d\\n", v, v);\n    printf("ok %d", v);\n'
      '    NSString *src = @"fragment float4 main0(float4 c [[stage_in]]) { return c * 0.5; }";\n    return 0;\n}\n')
cv = lambda t: cp.impl_text('a.c', t.encode())
chk('㉑ C：只改日志调用文本（LOG / MLOG / fprintf(stderr)）→ 规范文本不变', True,
    cv(C0) == cv(C0.replace('宽屏：放开（来源：%s）', '宽屏放开了，来源是 %s').replace('"w %d"', '"宽 = %d"').replace('dbg %d', 'debug: %d')))
chk('㉑ C：只改注释 / 空白 → 不变', True, cv(C0) == cv(C0.replace('// 开关', '/* 换个说法 */').replace('    ', '  ')))
chk('㉑ C：改判定（> 改 >=）→ 变', False, cv(C0) == cv(C0.replace('v > 1920', 'v >= 1920')))
chk('㉑ C：改环境变量名 → 变', False, cv(C0) == cv(C0.replace('"S2A_X"', '"S2A_Y"')))
chk('㉑ C：改含空格的 MSL 模板字符串 → 变', False, cv(C0) == cv(C0.replace('return c * 0.5;', 'return c * 0.25;')))
chk('㉑ C：改往文件写的 fprintf 格式串 → 变', False, cv(C0) == cv(C0.replace('"%d %d\\n"', '"%d\\t%d\\n"')))
chk('㉑ C：改 printf（stdout）格式串 → 变', False, cv(C0) == cv(C0.replace('"ok %d"', '"ok: %d"')))
S0 = 'void g(int w) { Console.Error.WriteLine($"[宽屏] 目标 {w}"); var k = $"key {w}"; }\n'
sv = lambda t: cp.impl_text('a.cs', t.encode())
chk('㉑ C#：改 Console.Error 日志文本 → 不变；改普通插值字符串 → 变', (True, False),
    (sv(S0) == sv(S0.replace('[宽屏] 目标', '[宽屏·核心] 目标宽')), sv(S0) == sv(S0.replace('"key {w}"', '"k {w}"'))))
P0 = ('import sys\ndef f(x):\n    """说明"""\n    print(f"读数 {x} 帧", file=sys.stderr)  # 注释\n    logging.info("实测 %s", x)\n'
      '    print(f"{x}\\t{x}")\n    return x > 57\n')
pv = lambda t: cp.impl_text('a.py', t.encode())
chk('㉑ Python：改 stderr print / logging 文本 / 注释 → 不变', True, pv(P0) == pv(P0.replace('读数', '实测读数').replace('# 注释', '# 改了').replace('实测 %s', '读到 %s')))
chk('㉑ Python：改常量 → 变', False, pv(P0) == pv(P0.replace('57', '55')))
chk('㉑ Python：改 stdout print 的输出格式（数据）→ 变', False, pv(P0) == pv(P0.replace('{x}\\t{x}', '{x},{x}')))
chk('㉑ Python：改文档字符串 → 变（只剔日志调用，其余字符串都算）', False, pv(P0) == pv(P0.replace('说明', '新说明')))
print('caps_policy 单测全绿' if not bad else 'caps_policy 单测有红'); sys.exit(1 if bad else 0)
