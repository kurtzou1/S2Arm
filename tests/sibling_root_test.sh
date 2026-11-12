#!/bin/bash
# 门禁覆盖：tools/clonedir.py pack/roots.sh pack/jobs/build.py
# 兄弟平台根起步单测（11-02 多平台导出平台无关阶段只做一次：pack/jobs/build.py seed_from_sibling 用 tools/clonedir.py --report 克隆别的平台的现行根；约 10 秒）：
#   bash tests/sibling_root_test.sh。期望按规则手写：
#   ① 同一 APFS 卷克隆：最后一行「克隆路线：APFS 克隆 N 项」，内容与阶段戳原样
#   ② 克隆来的根阶段戳 = 本树算出的键 → root_stage_done 判已完成（跳过）；戳是旧提交的键 → 判没完成（照常重做），不因克隆就跳过
#   ③ 目标在 exFAT 卷（hdiutil 临时盘）：卷不支持 RENAME_EXCL，clonedir 先确认目标不存在再普通改名发布（11-11 起；原先失败关闭，
#      解包 / 产物根 / 播种几个调用方在外接盘上全停，只有本处会退回播种）→ 退出 0、报「普通拷贝」、内容原样；③b 同一目标再发布一次 → 失败、不覆盖
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; M=
trap '[ -n "$M" ] && hdiutil detach -quiet "$M" 2> /dev/null; rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
[ "$(uname -s)" = Darwin ] || { echo "非 macOS：本单测要 APFS / hdiutil，环境未就绪"; exit 75; }
S=$T/sib; mkdir -p "$S/party@pkg-a/romfs"; echo a > "$S/party@pkg-a/romfs/x"; echo K-new > "$S/party@pkg-a/.stage_romfsidx"; echo K-old > "$S/party@pkg-a/.stage_rewrite"
R=$T/mac; mkdir -p "$R"
o=$(python3 "$H/tools/clonedir.py" --report "$S/party@pkg-a" "$R/G@sib-pkg-a" 2>&1); r=$?; ln -s G@sib-pkg-a "$R/G@现行"
ck "① 同卷克隆：退出 0、「${o##*$'\n'}」、内容与阶段戳原样" '[ $r = 0 ] && [[ "$o" == *"克隆路线：APFS 克隆 3 项"* ]] && [ "$(cat "$R/G@现行/romfs/x")" = a ] && [ "$(cat "$R/G@现行/.stage_romfsidx")" = K-new ]'
done_() { ( export S2A_ROOTS=$R; source "$H/pack/roots.sh"; root_stage_done "$R/G@现行" "$1" "$2" ); }
done_ romfsidx K-new; a=$?; done_ rewrite K-new; b=$?
ck "② 戳 = 本树键 → 跳过（romfsidx ${a}）；戳是旧提交的键 → 重做（rewrite ${b}）" '[ $a = 0 ] && [ $b != 0 ]'
hdiutil create -quiet -size 40m -fs ExFAT -volname S2ASIBT "$T/x.dmg" && M=$(hdiutil attach -nobrowse -noverify "$T/x.dmg" | tail -1 | awk -F'\t' '{print $NF}')
if [ -n "$M" ] && [ -d "$M" ]; then
  o=$(python3 "$H/tools/clonedir.py" --report "$S/party@pkg-a" "$M/G@sib-pkg-a" 2>&1); r=$?
  ck "③ exFAT：普通拷贝发布、退出 0（${r}）、「${o##*$'\n'}」、内容与阶段戳原样" '[ $r = 0 ] && [[ "$o" == *"普通拷贝"* ]] && [ "$(cat "$M/G@sib-pkg-a/romfs/x")" = a ] && [ "$(cat "$M/G@sib-pkg-a/.stage_romfsidx")" = K-new ]'
  o=$(python3 "$H/tools/clonedir.py" --report "$S/party@pkg-a" "$M/G@sib-pkg-a" 2>&1); r=$?
  ck "③b exFAT 上目标已在 → 再发布失败、不覆盖（${r}）" '[ $r != 0 ] && [ "$(cat "$M/G@sib-pkg-a/romfs/x")" = a ]'
else echo "不通 ③ hdiutil 建不了 exFAT 临时盘"; bad=1; fi
[ $bad = 0 ] && echo "sibling_root 单测全过" || { echo "sibling_root 单测有不通"; exit 1; }
