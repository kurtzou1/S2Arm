#!/bin/bash
# 产物根播种：pack/seed_root.sh <款> <版本标签> <游戏数据目录>   例：pack/seed_root.sh 01006F8002326000 seed1019 ~/.s2arm/data/01006F8002326000
# 把游戏原始输入（exefs/ romfs/ systemdata/ upd/，有哪个克隆哪个；外加 ctl/control.nacp）整目录 clonefile 进新产物根 <款>@<标签>，并原子切现行（pack/roots.sh）。
# 只取原始输入：ctl/ 只取 control.nacp（游戏元数据），旧库按游戏写的路线与 *_overlay 一概不带（零专用配置）。源数据里有软链 → 报红不播（克隆后写入会顺链改到源）。
# 之后出包各阶段在新版本根里加产物（改写后的模块、着色器库、资源包…），读方读 <款>@现行。
set -u
G=${1:?款}; TAG=${2:?版本标签}; SRC=$(cd "${3:?游戏数据目录}" && pwd -P) || exit 1
H=$(cd "$(dirname "$0")" && pwd); source "$H/roots.sh"
[ -d "$SRC/exefs" ] || { echo "【红】$SRC 下没有 exefs/"; exit 1; }
# Only private frontend roots opt in. The default dedicated stage_aoc.sh cache
# and extraction path remain unchanged; that stage may replace these files later.
SEED_DIRS=(exefs romfs systemdata upd rt_shaders)   # rt_shaders：真机转储的、游戏文件里抽不到的着色器（<键>.ctl / .code），抽取阶段并进直连库（translator/rt_dump_merge.py）
[ "${S2A_SEED_AOC:-0}" != 1 ] || SEED_DIRS+=(aoc)
for d in "${SEED_DIRS[@]}"; do   # 子目录本身是软链没关系（先解析成实际目录再克隆），里面不许有软链
  [ -d "$SRC/$d" ] && find "$(cd -P "$SRC/$d" && pwd)" -mindepth 1 -type l -print -quit | grep -q . && { echo "【红】$SRC/$d 里有软链，不播（克隆后写入会顺链改到源）"; exit 1; }
done
TAG=$(root_tag "$G" "$TAG"); W=$(root_begin "$G" "$TAG") || exit 1
# 开了 S2A_SEED_AOC 且源目录带追加内容：先清掉从现行克隆来的追加内容阶段产物与键（aoc/ 下面循环会清），播源目录那份；
#   不清的话 .stage_aoc 键照旧对得上、stage_aoc 跳过，aoc/ 是源的而 aoc.log / 旧 aoc.tsv 是阶段的，来源混搭
if [ "${S2A_SEED_AOC:-0}" = 1 ] && { [ -d "$SRC/aoc" ] || [ -f "$SRC/aoc.tsv" ]; }; then rm -f "$W/aoc.tsv" "$W/aoc.log" "$W/.stage_aoc"; fi
for d in "${SEED_DIRS[@]}"; do
  [ -d "$SRC/$d" ] || continue
  _root_rm "${W:?}/$d"
  python3 "$H/../tools/clonedir.py" "$(cd -P "$SRC/$d" && pwd)" "$W/$d" || { root_abort "$G" "$TAG"; echo "【红】克隆 $d 失败"; exit 1; }
done
# RomFS 镜像（romfs.std，标准 RomFS，与 romfs/ 同级，graphics/nvn/tools/romfs_list.py image_of）：源只有镜像、没有 romfs/ 时克隆这一个文件（APFS 不占新空间）；
#   RomFS 只留源的那一种形态：播镜像就删现行克隆来的 romfs（存储软链），播目录就删现行克隆来的旧镜像
if [ -f "$SRC/romfs.std" ] && [ ! -d "$SRC/romfs" ]; then
  _root_rm "$W/romfs"; _root_rm "$W/romfs.std"; root_copy 播种 "$SRC/romfs.std" "$W/romfs.std" || { root_abort "$G" "$TAG"; echo "【红】克隆 romfs.std 失败：$(printf '%s' "$COPY_ERR" | tr '\n' ' ')"; exit 1; }
elif [ -d "$SRC/romfs" ]; then _root_rm "$W/romfs.std"; fi
if [ "${S2A_SEED_AOC:-0}" = 1 ] && [ -f "$SRC/aoc.tsv" ]; then
  root_copy 播种 "$SRC/aoc.tsv" "$W/aoc.tsv" || { root_abort "$G" "$TAG"; echo "【红】拷 aoc.tsv 失败：$(printf '%s' "$COPY_ERR" | tr '\n' ' ')"; exit 1; }
fi
if [ -f "$SRC/ctl/control.nacp" ]; then mkdir -p "$W/ctl" && root_copy 播种 "$SRC/ctl/control.nacp" "$W/ctl/" || { root_abort "$G" "$TAG"; echo "【红】拷 control.nacp 失败：$(printf '%s' "$COPY_ERR" | tr '\n' ' ')"; exit 1; }   # 游戏元数据（标题 / 存档参数），服务层读；ctl/ 里别的不带
else echo "【黄】$SRC/ctl/control.nacp 没有：服务层读不到 NACP 会报红"; fi
# 游戏图标：nx_unpack 解在源目录顶层的 icon.jpg 也要播进产物根。不播的话 pack/ipa.sh 的两条图标来源（S2A_ICONS/<款>.jpg、
#   产物根 icon.jpg）都落空，app_bundle.py write_icons 跳过，包内没有 AppIcon*.png 也没有 CFBundleIcons，装出来是系统缺省白图标
[ -s "$SRC/icon.jpg" ] && { root_copy 播种 "$SRC/icon.jpg" "$W/" || { root_abort "$G" "$TAG"; echo "【红】拷 icon.jpg 失败：$(printf '%s' "$COPY_ERR" | tr '\n' ' ')"; exit 1; }; } \
  || echo "【黄】$SRC/icon.jpg 没有：出包不带 App 图标（补：tools/game_icons.sh ${G}）"
# #172 build-stage metadata: do not inherit an old extraction's identity/version.
# unpack.tsv（解包写的程序号 / 名称 / 版本，#459）与直连零配置推导要的元数据（direct-profile-input.json）
rm -f "$W/unpack.tsv"; [ ! -f "$SRC/unpack.tsv" ] || root_copy 播种 "$SRC/unpack.tsv" "$W/unpack.tsv" || { root_abort "$G" "$TAG"; echo "【红】拷 unpack.tsv 失败：$(printf '%s' "$COPY_ERR" | tr '\n' ' ')"; exit 1; }
rm -f "$W/direct-profile-input.json" "$W/.stage_direct_profile"
[ ! -f "$SRC/direct-profile-input.json" ] || root_copy 播种 "$SRC/direct-profile-input.json" "$W/direct-profile-input.json" || { root_abort "$G" "$TAG"; echo "【红】拷 direct-profile-input.json 失败：$(printf '%s' "$COPY_ERR" | tr '\n' ' ')"; exit 1; }
rm -f "$W/.stage_uilayout" "$W/.stage_romfsidx" "$W/.stage_pkg" "$W/ui_overlay.tsv" "$W/romfs.s2aidx"   # 原始输入重播了：覆盖在 romfs 上的阶段与包都要重做
_root_rm "$W/ui_overlay"   # 界面布局覆盖层（pack/stage_uilayout.sh）同清单一起作废：原先就地改的 romfs 随重播换掉，覆盖层同理
# 原始模块 / NRO 已换新：旧补丁、返回点/入口表和索引不能再配这份输入；其他阶段与 exefs/romfs 原件保留。
rm -f "${W:?}/.stage_rewrite" "$W/.stage_rewrite.deps" "$W"/*.patched.bin "$W"/*.fixups.tsv "$W"/*.gates.tsv "$W"/*.sites.tsv "$W"/*.gaps.tsv "$W/nro_modules.tsv" || { root_abort "$G" "$TAG"; echo "【红】清除旧改写产物失败" >&2; exit 1; }
printf 'src=%s\ntag=%s\nat=%s\n' "$SRC" "$TAG" "$(date '+%F %T')" > "$W/seed.txt"
root_commit "$G" "$TAG" || exit 1
# 提交后现行必须解析得出（11-04 c1104_r2 010015100B514000：停批漏掉的旧 one_game 收尾 rm -rf 工作目录，把刚提交的版本删了，这里取到空串照打 🟢 退 0）
CUR=$(root_cur "$G"); [ -n "$CUR" ] && [ -d "$CUR" ] || { echo "【红】$G 播种已提交，但现行 $S2A_ROOTS/$G@现行 解析不出产物根（版本目录在提交后被删）：查是不是有另一个出包在同一产物根目录上跑"; exit 1; }
echo "🟢 $G 产物根 → ${CUR}：$(ls "$CUR" | tr '\n' ' ')"
