#!/bin/bash
export S2A_CAPS_OWN=1   # 本测的是我方 60 帧 / 满屏旧口径（11-13 起发布缺省只用社区补丁，见 tests/caps_patch_only_test.py）
# F7 #1574 单测（安卓能力清单与实现哈希按平台独立，#996 防重演；合成根 + 合成仓库 / 合成实现集，不出真机 / 游戏文件，约 10 秒）：bash tests/android_caps_test.sh
# 期望：
#   ① 安卓（S2A_PACK_PLAT=android）不需要 .stage_rewrite 也出能力清单；首行 plat<TAB>android，发布 / --all-caps 两份同头
#   ② 发布口径：无安卓验证行 → widen 0「发布缺省关」、根里没有 widen_verified.tsv；--all-caps 口径 widen 1（有来源即开，区分两种口径）
#   ③ 已验证名单只有 apple 行 → 安卓根不写标记、widen 仍缺省关；补安卓行 → 写标记（整行原样）、widen 1
#   ④ 平台盐 + 按平台的实现集：cap_hashes 同一份根，apple ≠ android；signal-files --target android 列出安卓实现集（含未落库的 F2 文件名）；
#     只改出图适配文件 AndroidPresentFit.cs → 安卓哈希变、苹果哈希不变
#   ⑤ make_pack 负控：plat apple 头 / 无 plat 行的苹果清单进安卓包 → 报红退出；widen_verified.tsv 只收安卓行
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
v() { awk -F'\t' -v k="$2" '$1 == k {print $2}' "$1"; }
why() { awk -F'\t' -v k="$2" '$1 == k {sub(/^# /, "", $3); print $3}' "$1"; }
PROG=0100000000000F00; BID=$(printf 'a%.0s' {1..32})
# 合成产物根（不带 .stage_rewrite）：exefs/main 头 0x40 起 16 字节 Build ID；main.npdm META + ACI0@0x80 + 程序号@0x90；unpack.tsv title_id
R1=$T/roots/mk7@v1; mkdir -p $R1/exefs $R1/romfs $R1/ctl
printf 'title_id\t%s\n' "$PROG" > $R1/unpack.tsv
python3 - "$R1/exefs/main" "$R1/exefs/main.npdm" "$PROG" "$BID" <<'EOF'
import struct, sys
main, npdm, pid, bid = sys.argv[1], sys.argv[2], int(sys.argv[3], 16), bytes.fromhex(sys.argv[4])
open(main, 'wb').write(b'NSO0' + bytes(0x3C) + bid + bytes(0x60))
n = bytearray(0x100); n[:4] = b'META'; struct.pack_into('<I', n, 0x70, 0x80); n[0x80:0x84] = b'ACI0'; struct.pack_into('<Q', n, 0x90, pid)
open(npdm, 'wb').write(n)
EOF
ln -s mk7@v1 $T/roots/mk7@现行
RW=$T/fake_rewriter; printf '#!/bin/sh\nexit 0\n' > $RW; chmod +x $RW   # 安卓改写键只要后端键：桩个可执行文件给 S2A_REWRITER_C，不真编
export S2A_ROOTS=$T/roots S2A_ROOTS_SHARED=$T/roots_shared S2A_REWRITER_C=$RW S2A_CAPS_REPO=$T/synrepo   # 私有根：分支树不许改共享现行（roots.sh _root_tree_ok）
mkdir -p $T/synrepo/docs $T/widen_tables
# 合成仓库：名单表都不存在 = 没登记强信号 / 验证账；宽屏已验证表先只放 apple 行（程序号 + 构建号同本款）
printf '# 程序号\t构建号\t款\t平台\t登记日期\t依据\n%s\t%s\tmk7\tapple\t2026-11-01\t合成 apple 验过\n' "$PROG" "$BID" > $T/widen_tables/verified.tsv
run() { S2A_PACK_PLAT=$1 S2A_WIDEN_DIR=$T/widen_tables bash $H/pack/stage_caps.sh mk7 > $T/caps-$2.log 2>&1; echo $?; }
# 现行根已有苹果验证标记：安卓生成不得把它当成安卓验证。
printf '%s\t%s\tmk7\tapple\t2026-11-01\t合成 apple 验过\n' "$PROG" "$BID" > "$R1/widen_verified.tsv"
r=$(run android a1); C=$T/roots/mk7@现行
ck "① 安卓无 .stage_rewrite 也出清单（rc=${r}；$(tail -1 $T/caps-a1.log)）" '[ $r = 0 ] && [ -f $C/s2a_caps.tsv ]'
ck "① 安卓清单首行 plat<TAB>android；--all-caps 那份同头" '[ "$(head -1 $C/s2a_caps.tsv)" = "plat	android" ] && [ "$(head -1 $C/s2a_caps.all.tsv)" = "plat	android" ]'
ck "② 发布缺省关：只有 apple 验过行 → widen 0「发布缺省关」、根里不写 widen_verified.tsv" \
  '[ "$(v $C/s2a_caps.tsv widen)" = 0 ] && [[ "$(why $C/s2a_caps.tsv widen)" == *发布缺省关* ]] && [ ! -e $C/widen_verified.tsv ]'
ck "② --all-caps 口径区分：同根 widen 1（有来源即开，不看缺省关）" '[ "$(v $C/s2a_caps.all.tsv widen)" = 1 ]'
printf '%s\t%s\tmk7\tandroid\t2026-11-01\t合成安卓验过\n' "$PROG" "$BID" >> $T/widen_tables/verified.tsv
r=$(run android a2); C=$(cd $T/roots && pwd -P)/mk7@现行   # 第二次出了新版根，重取现行
ck "③ 补安卓行 → 标记整行原样写进根、widen 1（rc=${r}）" \
  '[ $r = 0 ] && [ "$(v $C/s2a_caps.tsv widen)" = 1 ] && [ "$(cat $C/widen_verified.tsv)" = "0100000000000F00	aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa	mk7	android	2026-11-01	合成安卓验过" ]'
# 验证账撤销后，克隆出的旧安卓标记不能参与本次判定，也不能留在新根。
printf '# 程序号\t构建号\t款\t平台\t登记日期\t依据\n%s\t%s\tmk7\tapple\t2026-11-01\t合成 apple 验过\n' "$PROG" "$BID" > "$T/widen_tables/verified.tsv"
r=$(run android a3); C=$(cd "$T/roots" && pwd -P)/mk7@现行
ck "③ 撤销安卓验证行 → 清除旧标记并关闭发布宽屏（rc=${r}）" \
  '[ $r = 0 ] && [ "$(v $C/s2a_caps.tsv widen)" = 0 ] && [ ! -e $C/widen_verified.tsv ]'
# 清理旧标记失败必须中止，不得发布沿用旧根或继续生成清单。
mkdir "$C/widen_verified.tsv"; printf 'force-rebuild\n' > "$C/.stage_caps"
OLD=$(readlink "$T/roots/mk7@现行")
r=$(run android blocked)
ck "③ 旧标记无法清除 → 报红退出、现行根不变（rc=${r}）" \
  '[ "$r" != 0 ] && [ "$(readlink "$T/roots/mk7@现行")" = "$OLD" ] && grep -q "清除旧宽屏验证标记失败" "$T/caps-blocked.log"'
rmdir "$C/widen_verified.tsv"
# ④ 平台盐 + 按平台实现集（合成实现仓库：IMPL 两域文件的并集各建一份 v1）
python3 - "$T" "$H" <<'EOF'
import importlib.util, os, sys
t, repo_root = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location('caps_policy', repo_root + '/tools/caps_policy.py')
cp = importlib.util.module_from_spec(spec); spec.loader.exec_module(cp)
root = t + '/hroot'; os.makedirs(root, exist_ok=True)
q = t + '/implrepo'
names = sorted({n for dom in cp.IMPL.values() for v in dom.values() for n in v})
for n in names:
    f = os.path.join(q, n); os.makedirs(os.path.dirname(f), exist_ok=True); open(f, 'w').write('v1\n')
a = cp.cap_hashes(root, q, 'apple'); d = cp.cap_hashes(root, q, 'android')
assert a['widen'] != d['widen'] and a['fps60'] != d['fps60'], '同一根同一实现集，两平台哈希竟相同（平台盐没生效）'
open(os.path.join(q, 'graphics/vulkan/wsi/AndroidPresentFit.cs'), 'w').write('v2\n')
a2 = cp.cap_hashes(root, q, 'apple'); d2 = cp.cap_hashes(root, q, 'android')
assert a2['widen'] == a['widen'], '改安卓出图适配文件不该动苹果哈希'
assert d2['widen'] != d['widen'], '改安卓出图适配文件安卓哈希没变'
assert d2['fps60'] == d['fps60'], '宽屏实现改动不该动 60 帧哈希'
sf = cp.SIGNAL_IMPL['android']['widen']
for n in ('android/native/screen_metrics.c', 'graphics/vulkan/wsi/AndroidPresentFit.cs',
          'graphics/vulkan/runtime/AndroidWidenComposition.cs', 'graphics/vulkan/runtime/AndroidWidenProgramCache.cs',
          'android/tools/make_pack.py', 'pack/stage_caps.sh'):
    assert n in sf, f'安卓宽屏实现 / 数据选择集缺 {n}'
assert 'graphics/vulkan/runtime/AndroidVulkanRuntime.cs' not in cp.IMPL['android']['widen'], '安卓实现集不能装整个 AndroidVulkanRuntime'
assert 'graphics/widen/gal/WidenRenderer.cs' not in cp.IMPL['apple']['widen'], '苹果维持原哈希，GAL 包装层另定'
sa, sd = cp.signal_hashes(cp.repo_reader(q), 'apple'), cp.signal_hashes(cp.repo_reader(q), 'android')
assert sa['widen'] != sd['widen'], '两平台强信号失效键竟相同'
print('哈希断言全过')
EOF
ck "④ 平台盐 + 实现集（cap / signal 哈希与文件集断言）" '[ $? = 0 ]'
ck "④ signal-files --target android 列出安卓集（含未落库 F2 名）" \
  'python3 $H/tools/caps_policy.py signal-files --target android | grep -q "AndroidPresentFit.cs" && python3 $H/tools/caps_policy.py signal-files --target android | grep -q "AndroidWidenComposition.cs" && python3 $H/tools/caps_policy.py signal-hash --target android >/dev/null'
# ⑤ make_pack 负控：苹果清单 → 红；安卓清单 → 过；verified 只收安卓行
python3 - "$T" "$H" <<'EOF'
import importlib.util, os, sys, unittest.mock
t, repo_root = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location('make_pack', repo_root + '/android/tools/make_pack.py')
mp = importlib.util.module_from_spec(spec); spec.loader.exec_module(mp)

def fixture(caps_first):
    root = t + '/proot'; stage = t + '/pmods'
    for d in ('exefs', 'romfs', 'ctl'): os.makedirs(root + '/' + d, exist_ok=True)
    open(root + '/exefs/main.npdm', 'wb').write(b'x')
    open(root + '/ctl/control.nacp', 'wb').write(b'x')
    if os.path.exists(root + '/s2a_caps.tsv'): os.remove(root + '/s2a_caps.tsv')   # fixture 复用同一根：None = 清单缺失场景
    if caps_first is not None:
        open(root + '/s2a_caps.tsv', 'w').write(caps_first + '\nwiden\t1\nfps60\t1\n')
    open(root + '/widen_verified.tsv', 'w').write('0100000000000F00\t' + 'a' * 32 + '\tmk7\tapple\t2026-11-01\tx\n')
    os.makedirs(stage, exist_ok=True)
    return root, stage

for bad in ('plat\tapple', 'widen\t1', '# 包内能力清单（老格式）', None):
    root, stage = fixture(bad)
    try:
        with unittest.mock.patch.object(mp, 'rewrite'), unittest.mock.patch.object(mp, 'stage_address_requirements', return_value='n'), \
             unittest.mock.patch.object(mp, 'stage_system_data', return_value=None):
            mp.entries_from_root(root, stage)
    except SystemExit as e:
        assert e.code and ('不是安卓清单' in str(e.code) or '没有 s2a_caps.tsv' in str(e.code)), f'报红文案不对：{e.code}'
    else:
        raise AssertionError(f'清单首行 {bad!r} 竟被安卓包收下')
root, stage = fixture('plat\tandroid')
with unittest.mock.patch.object(mp, 'rewrite'), unittest.mock.patch.object(mp, 'stage_address_requirements', return_value='n'), \
     unittest.mock.patch.object(mp, 'stage_system_data', return_value=None):
    entries = mp.entries_from_root(root, stage)
assert ('s2a_caps.tsv', root + '/s2a_caps.tsv') in entries, '安卓清单没进包'
assert not os.path.exists(stage + '/widen_verified.tsv'), '只含 apple 行的标记被拷进安卓包'
open(root + '/widen_verified.tsv', 'w').write('0100000000000F00\t' + 'a' * 32 + '\tmk7\tandroid\t2026-11-01\tx\n')
os.makedirs(t + '/pmods2')
with unittest.mock.patch.object(mp, 'rewrite'), unittest.mock.patch.object(mp, 'stage_address_requirements', return_value='n'), \
     unittest.mock.patch.object(mp, 'stage_system_data', return_value=None):
    mp.entries_from_root(root, t + '/pmods2')
assert os.path.exists(t + '/pmods2/widen_verified.tsv'), '安卓行标记没进包'
print('make_pack 断言全过')
EOF
ck "⑤ make_pack 负控：苹果头 / 无头清单被拒；verified 只收安卓行" '[ $? = 0 ]'
# ⑧ 静态核：refresh.sh 安卓分支在提前返回前调 caps；stage_rewrite 只取 apple 行；widen_root 只认 apple 行
ck "⑧ refresh 安卓分支提前返回前调 stage_caps.sh" 'awk "/S2A_PACK_PLAT.*= android/,/exit 0/" $H/pack/refresh.sh | grep -q stage_caps.sh'
ck "⑧ stage_rewrite 按平台列取 apple 行" 'grep -q "tolower(\$4) == \"apple\"" $H/pack/stage_rewrite.sh'
[ $bad = 0 ] && echo "android_caps 单测全过" || { echo "android_caps 单测有不通"; exit 1; }
