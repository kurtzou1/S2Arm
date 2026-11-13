#!/bin/bash
# 出包·共享·系统数据阶段（J07 #183）：pack/stages/sysdata.sh <款>
# 对外入口只转发；阶段逻辑与 main 同步，只有 H 改为 pack/ 父目录。
# 把服务层要的系统数据放进产物根 systemdata/（游戏数据目录的一部分，iOS 上随资源包走）：
#   systemdata/fonts/   共享字体 .bfttf（文件名同 Ryujinx），缺省开源替代字体（来源规则见下面 open_fonts 处）；任天堂原版只在显式给 S2A_FONTS 时用，不进仓库、只进包
#   systemdata/010000000000080E/   时区数据：已有真系统数据就保留，否则从钉版 IANA 源码生成；来源变化时重新生成
#   systemdata/<号>/   其它系统数据（Mii 资源 0802、屏蔽词 0823 等）：每款都提供，不按款判断（10-25 维护者：逐款需求表漏登 0823，数码宝贝港版起局 Break）。
#                      pack/sysdata_need.py 逐号：产物根有真的就留；玩家系统数据目录 S2A_SYSDATA（一键出包 --sysdata）有就拷真的；都没有就由 pack/sysdata_synth.py
#                      合成空但格式合法的一份（旁边记 <号>.synth，以后有真的就换；10-25 维护者：玩家不面对缺系统数据）。pack/sysdata_need.tsv 只作统计，出包不读
# 新版本键包含字体清单与生成时区的版本/源码摘要；已有真时区不依赖 IANA 来源。
set -u
G=${1:?款}; H=$(cd "$(dirname "$0")/.." && pwd); R=$(cd "$H/.." && pwd); source "$H/roots.sh"
CUR=$(root_cur "$G"); [ -n "$CUR" ] || { echo "【红】$G 没有现行产物根"; exit 1; }
tz() { ls -d "$1"/systemdata/010000000000080[eE] 2>/dev/null | head -1; }
# 旧生成器留下 tz.log 的「时区数据：」行；没有这条记录的现有目录视为玩家真实系统数据。
tz_generated=0; [ -z "$(tz "$CUR")" ] || ! grep -q '^时区数据：' "$CUR/tz.log" 2>/dev/null || tz_generated=1
TZ_ID=; TZ_KEY=real; tz_stale=0
if [ -z "$(tz "$CUR")" ] || [ "$tz_generated" = 1 ]; then
  TZ_ID=$(bash "$R/services/systemdata/make_tzdata.sh" --source-id) || { echo '【红】无法读取钉版时区来源'; exit 1; }
  TZ_KEY=$(printf '%s\n' "$TZ_ID" | shasum -a 256 | cut -d' ' -f1)
  if [ "$tz_generated" = 1 ] && ! grep -Fxq "s2a-tzdata-source $TZ_ID" "$CUR/tz.log"; then tz_stale=1; fi
fi
TZ_STAGE_KEY=$([ "$TZ_KEY" = real ] && echo real || printf 'tz-%s\n' "$TZ_KEY")
if [ -n "${S2A_STAGE_KEYS:-}" ]; then root_stage_done "$CUR" sysdata "$TZ_STAGE_KEY"; exit $?; fi
# 钉版时区源码（a829b6303 起生成要它、生成过程离线）：本机缓存没有就在这里按钉版准备一次（make_tzdata.sh --prepare-sources：IANA 固定地址、SHA-512 核），
#   再核；准备不成才红。10-30 出包线：这一步原先没人做，各机器缓存都空，凌晨每款正式包都 1 秒红在 sysdata
if [ -n "$TZ_ID" ] && ! bash "$R/services/systemdata/make_tzdata.sh" --check-sources 2> /dev/null; then
  tzp=$(bash "$R/services/systemdata/make_tzdata.sh" --prepare-sources 2>&1) || { echo "【红】$G 钉版时区源码准备失败（$(printf '%s\n' "$tzp" | grep -a '【红】\|curl' | tail -1)）"; exit 1; }
  echo "  $G 钉版时区源码已按钉版准备（$(bash "$R/services/systemdata/make_tzdata.sh" --source-id | cut -d' ' -f1)）"
fi
[ -z "$TZ_ID" ] || bash "$R/services/systemdata/make_tzdata.sh" --check-sources || exit 1
# 共享字体（维护者 10-30 拍板：缺省用开源替代字体，任天堂原版只在显式给 S2A_FONTS / 一键出包 --fonts 时用）：
#   S2A_FONTS → 装着的 S2Arm.app 自带 Contents/Resources/Fonts（S2A_APP_FONTS_DIRS 可换，单测用）→ 开源字体产物目录 S2A_OPENFONTS_DIR（缺省 <运行根>/s2arm/openfonts，运行根 = S2A_RUN_ROOT，缺省 ~/.s2arm/run）；
#   产物目录的生成器戳（.generator.sha256，同 launchers/macos/build_app.py）与 pack/fonts/make_open_fonts.py 不符或不满 7 个就现做：临时目录做完再换进位，并发出包不撞
open_fonts() {
  local d=${S2A_OPENFONTS_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/openfonts} gen=$R/pack/fonts/make_open_fonts.py h t
  h=$(shasum -a 256 "$gen" | cut -d' ' -f1)
  ok() { [ "$(cat "$d/.generator.sha256" 2> /dev/null)" = "$h" ] && [ "$(ls "$d"/*.bfttf 2> /dev/null | wc -l)" -eq 7 ]; }
  ok && { echo "$d"; return 0; }
  t=$d.tmp.$$; rm -rf "$t"; echo "  共享字体：现做开源替代字体（${d}，生成器 ${h:0:8}）" >&2
  "${S2A_PYTHON:-python3}" "$gen" "$t" >&2 || { rm -rf "$t"; return 1; }
  echo "$h" > "$t/.generator.sha256"
  ok && { rm -rf "$t"; echo "$d"; return 0; }   # 并发的另一份出包先做好了
  rm -rf "$d" && mv "$t" "$d" || { rm -rf "$t"; return 1; }; echo "$d"; }
if [ -n "${S2A_FONTS:-}" ]; then FS=$S2A_FONTS
else FS=$(for f in ${S2A_APP_FONTS_DIRS:-/Applications/S2Arm.app/Contents/Resources/Fonts "$HOME/Applications/S2Arm.app/Contents/Resources/Fonts"}; do ls "$f"/*.bfttf > /dev/null 2>&1 && { echo "$f"; break; }; done)
  [ -n "$FS" ] || FS=$(open_fonts) || { echo "【红】$G 开源替代字体做不出来：生成器依赖装好再出（${S2A_PYTHON:-python3} -m pip install -r pack/fonts/requirements.txt），或一键出包给 --fonts <目录>"; exit 1; }
fi
F=$(cd "$FS" && pwd -P) || { echo "【红】没有共享字体目录（${FS}）"; exit 1; }
ls "$F"/*.bfttf > /dev/null 2>&1 || { echo "【红】$F 里没有 .bfttf"; exit 1; }
NEED=$(python3 "$H/sysdata_need.py" "$CUR" "${S2A_SYSDATA:-}"); rc=$?
echo "$NEED" | grep -v -e '^COPY	' -e '^SYNTH	'
[ $rc = 0 ] || { echo "【红】$G 系统数据核对失败（pack/sysdata_need.py rc=${rc}）"; exit 1; }
CP=$(echo "$NEED" | grep '^COPY	' | cut -f2-)   # 「号<TAB>来源目录」，每行一个要拷进产物根的
SY=$(echo "$NEED" | grep '^SYNTH	' | cut -f2)   # 要合成的号，每行一个
fonts_ok() { [ -d "$1/systemdata/fonts" ] && [ "$(cd "$F" && shasum *.bfttf)" = "$(cd "$1/systemdata/fonts" && shasum *.bfttf 2> /dev/null)" ]; }   # 只比 .bfttf（拷的就是它们；开源字体目录另有许可文本 / 清单）
tz_up() { [ "$(basename "$(tz "$1")")" = 010000000000080E ]; }   # iPhone 文件系统不保证不分大小写：目录名一律大写（服务层按大写拼路径）
fonts_ok "$CUR" && tz_up "$CUR" && [ "$tz_stale" = 0 ] && [ -z "$CP$SY" ] \
  && { [ "$(cat "$CUR/.stage_sysdata" 2>/dev/null)" = "$TZ_STAGE_KEY" ] \
       || { [ "$tz_generated" = 0 ] && [ ! -s "$CUR/.stage_sysdata" ]; }; } \
  && { echo "🟢 $G 系统数据已齐，跳过"; exit 0; }
TAG=sys-$(cd "$F" && ls *.bfttf | xargs shasum -a 256 | shasum -a 256 | cut -c1-8)-tz${TZ_KEY}${CP:+-sd}${SY:+-syn}
TAG=$(root_tag "$G" "$TAG"); W=$(root_begin "$G" "$TAG") || exit 1
# 先按宿主惯例复制。macOS 上克隆失败就以 -X 普通复制一次，避免扩展属性再次阻止复制。
# 递归克隆失败可能留下目标目录。清掉它再重试，避免把源目录嵌进目标。
clone_or_copy() {
  local label=$1 dst=${!#} clone_err copy_err
  shift
  clone_err=$(_root_cp "$@" 2>&1) && return 0
  COPY_ERR=$clone_err
  [ "$(uname -s)" = Darwin ] || return 1
  if [ "$1" = -R ] && ! copy_err=$(_root_rm_red "$dst" 2>&1); then
    COPY_ERR="$clone_err / 清理克隆残留：$copy_err"
    return 1
  fi
  if copy_err=$(cp -X "$@" 2>&1 || exit $?); then
    echo "【黄】$G $label 克隆复制失败，已改用普通复制：$(printf '%s' "$clone_err" | tr '\n' ' ')"
    return 0
  fi
  COPY_ERR="$clone_err / 普通复制：$copy_err"
  return 1
}
_root_rm "$W/systemdata/fonts"
COPY_ERR=
if ! mkdir -p "$W/systemdata/fonts" || ! clone_or_copy 字体 "$F"/*.bfttf "$W/systemdata/fonts/"; then
  root_abort "$G" "$TAG"
  echo "【红】拷字体失败：$(printf '%s' "${COPY_ERR:-建字体目录失败}" | tr '\n' ' ')"
  exit 1
fi
if [ "$tz_stale" = 1 ]; then _root_rm "$(tz "$W")"; fi
if [ -z "$(tz "$W")" ]; then
  bash "$R/services/systemdata/make_tzdata.sh" "$W/systemdata/010000000000080E" > "$W/tz.log" 2>&1 || { e=$(tail -1 "$W/tz.log" 2> /dev/null); root_abort "$G" "$TAG"; echo "【红】生成时区数据失败（${e}）"; exit 1; }   # 先取原因再撤根（#816：撤根删了 tz.log，原先括号里总是空的）
  printf 's2a-tzdata-source %s\n' "$TZ_ID" >> "$W/tz.log"
  how=生成
else
  how=沿用; o=$(tz "$W")
  if [ "$(basename "$o")" != 010000000000080E ]; then mv "$o" "$o.up" && mv "$o.up" "$W/systemdata/010000000000080E" || { root_abort "$G" "$TAG"; echo "【红】时区目录改大写失败"; exit 1; }; how="沿用（目录名改大写）"; fi
fi
while IFS=$'\t' read -r id src; do
  [ -n "$id" ] || continue
  dst=$W/systemdata/$id
  _root_rm "$dst"
  rm -f "$dst.synth"
  if ! clone_or_copy "系统数据 $id" -R "$src" "$dst"; then
    root_abort "$G" "$TAG"
    echo "【红】拷系统数据 $id 失败：$(printf '%s' "$COPY_ERR" | tr '\n' ' ')"
    exit 1
  fi
done <<< "$CP"
for id in $SY; do
  _root_rm "$W/systemdata/$id"; e=$(python3 "$H/sysdata_synth.py" "$id" "$W/systemdata/$id" 2>&1) && echo "合成：pack/sysdata_synth.py $id" > "$W/systemdata/$id.synth" \
    || { root_abort "$G" "$TAG"; echo "【红】合成系统数据 $id 失败（$(tail -1 < <(printf '%s\n' "$e"))）"; exit 1; }
done
printf '%s\n' "$TZ_STAGE_KEY" > "$W/.stage_sysdata"
ROOT_REPLAY='systemdata tz.log .stage_sysdata' root_commit "$G" "$TAG" || exit 1   # 与改写 / 界面布局并行：本阶段只写这些
echo "🟢 $G 系统数据：字体 $(ls "$F"/*.bfttf | wc -l | tr -d ' ') 个，${CP:+拷进 $(echo "$CP" | cut -f1 | tr '\n' ' ')，}${SY:+合成 $(echo $SY)，}时区${how}（$(basename "$(tz "$(root_cur "$G")")")），现行 → $(basename "$(root_cur "$G")")"
