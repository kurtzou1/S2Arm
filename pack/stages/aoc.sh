#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/stage_keyfiles.sh"; stage_deps_on || exit 1; SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")   # 用 BASH_SOURCE：本脚本也被单测当库 source（$0 那时是 bash）；实际读入进键（pack/stage_keyfiles.sh）：放最前（下面函数里有 Python 调用）
# 出包·共享·追加内容阶段（J07 #183）：pack/stages/aoc.sh <款>
# 与目标无关：产物是产物根里的 aoc/ + aoc.tsv + aoc.log + .stage_aoc，相对路径不含 ios / android / ohos；
#   DLC 是游戏内容，跟出到哪个平台无关，各目标插件只是把它带上（pack/ipa.sh、Android make_pack.py 各自取用）。
# 实现搬自 pack/stage_aoc.sh（对外命令行与行为不变，旧入口只剩一层转发）。
# 九款通用、零配置：按现行产物根的程序号在原始包目录里按内容认包（pack/srcs.sh：程序号对上的卡带 / 安装包 +
#   读不出程序号的单独更新 / DLC 包），交给 nx_unpack --aoc-only：它按内容清单只取本游戏的追加内容
#   （标题号去掉低 12 位 = 程序号 + 0x1000），解到产物根 aoc/<序号>/，写 aoc.tsv
#   （序号、标题号、版本、文件数、字节；文件数 -1 = 仅授权，数据解不开或不在给的文件里）。
#   服务层按 aoc.tsv 报已拥有 DLC、挂 aoc/<序号>/。
# 10-20 维护者：暗黑2 出包没带术士君临 DLC——播种（seed_root.sh）只克隆 exefs / romfs，aoc 一直没进产物根。
# 键 = 候选原始包「路径 大小 修改时间」+ nx_unpack 程序内容哈希（只取哈希列，不带工具路径：换检出 / 家目录键不变）+ 产物根 main 构建号；与现行 .stage_aoc 相同就跳过。
#   本机没有原始包（gate-host / 别的机器）→ 黄、跳过、现行不动。目标名 / ABI / 工具链不进键。
# 解不出不拦本体出包，但不许静默（审计 P2-30）：整份解不出时逐份兜底，能解的照常进产物根，解不出的每份在 aoc.log 记一行「追加内容缺<TAB>文件名<TAB>原因」，
#   出包完成行 / 登记说明 / 一键出包 result 经 pack/roots.sh root_aoc_note / root_aoc_missing 读它点名（见 pack/stages/README.md「追加内容」）
# 解出的 DLC 按键缓存在 S2A_AOC_CACHE（缺省 run/s2arm/cache/aoc/<款>-<键>/），各产物根（共享 / 私有、新版本）
#   从缓存克隆，同一份 DLC 全机只解一次（10-20 暗黑3 5.2 GB 的 DLC 在共享根和服务接入私有根各解了一份）。
# 完成的同级临时目录发布到缓存；可 source 以直接测试生产入口。
aoc_cache_publish() {
  python3 - "$1" "$2" <<'PY'
import errno
import os
from pathlib import Path
import shutil
import sys
import time

stage, cache = (Path(os.path.abspath(p)) for p in sys.argv[1:])
try:
    # 清理权只限调用者自己的同级临时目录；不删除获胜缓存或任意其他路径。
    if (stage.parent != cache.parent or not stage.name.startswith(cache.name + '.tmp.')
            or stage.name == cache.name + '.tmp.' or stage.is_symlink()
            or not (stage / 'aoc.tsv').is_file()):
        raise ValueError('待发布目录不是完整的同级追加内容临时目录')
    try:
        # 直接系统 rename，不用会把源目录嵌入已有目标目录的 mv；同盘原子发布。
        os.rename(stage, cache)
    except OSError as error:
        if (error.errno not in (errno.EEXIST, errno.ENOTEMPTY)
                or cache.is_symlink() or not (cache / 'aoc.tsv').is_file()):
            raise
        # 已有完整缓存说明另一发布者获胜；只丢弃自己的结果，正常返回。
        shutil.rmtree(stage)
except (OSError, ValueError) as error:
    print('【红】追加内容缓存发布失败：' + str(error), file=sys.stderr)
    sys.exit(1)
# 同款旧键回收（11-13 一台出包机系统盘：键随工具代码变，同款旧键从没人删，58 份 39 GB 把系统盘挤到 18 GB；玩家机器每次更新后出包同样只增不减）：
#   新键发布后，同款（名字同前缀「<款>-」）别的完整缓存只留最新 1 份，其余 AOC_CACHE_KEEP_S（缺省 6 小时）内没动过的删掉——
#   产物根是克隆出去的独立副本，删缓存不影响已出的包；6 小时内动过的可能有旧版工具的出包正在从它克隆，不碰。回收失败只记黄，不拦出包。
keep_s = float(os.environ.get('AOC_CACHE_KEEP_S', '21600'))
prefix = cache.name.rsplit('-', 1)[0] + '-'
try:
    old = sorted((p for p in cache.parent.iterdir()
                  if p.name.startswith(prefix) and p.name != cache.name and '.tmp.' not in p.name
                  and not p.is_symlink() and (p / 'aoc.tsv').is_file()),
                 key=lambda p: p.stat().st_mtime, reverse=True)[1:]
    now = time.time()
    for p in old:
        if now - p.stat().st_mtime > keep_s:
            shutil.rmtree(p)
except OSError as error:
    print('🟡 追加内容旧缓存回收失败（不影响出包）：' + str(error), file=sys.stderr)
PY
}
# 逐份兜底解出的各份结果并进 <目标>（审计 P2-30）：aoc_merge_parts <目标> <分份目录…>；各份 aoc.tsv 按序号去重（卡带里自带的 DLC 每份都会解出一遍，留第一份），
#   aoc/<序号>/ 从分份目录挪过去，清单按序号的字符串序写（同 nx_unpack 的顺序），各份 aoc.log 接在目标 aoc.log 后
aoc_merge_parts() {
  python3 - "$@" <<'PY'
import os, shutil, sys
dst, parts = sys.argv[1], sys.argv[2:]
rows, head = {}, 'idx\ttitle_id\tversion\tfiles\tbytes\n'
os.makedirs(os.path.join(dst, 'aoc'), exist_ok=True)
with open(os.path.join(dst, 'aoc.log'), 'a', encoding='utf-8') as log:
    for p in parts:
        lines = open(os.path.join(p, 'aoc.tsv'), encoding='utf-8').read().splitlines()
        head = lines[0] + '\n' if lines else head
        for line in lines[1:]:
            idx = line.split('\t', 1)[0]
            if not line.strip() or idx in rows: continue
            rows[idx] = line
            src = os.path.join(p, 'aoc', idx)
            if os.path.isdir(src): shutil.move(src, os.path.join(dst, 'aoc', idx))
        log.write(open(os.path.join(p, 'aoc.log'), encoding='utf-8', errors='replace').read())
with open(os.path.join(dst, 'aoc.tsv'), 'w', encoding='utf-8') as f:
    f.write(head + ''.join(rows[k] + '\n' for k in sorted(rows)))
PY
}
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

set -u
G=${1:?款}; H=$(cd "$(dirname "$0")/.." && pwd); R=$(cd "$H/.." && pwd); source "$H/roots.sh"; source "$H/srcs.sh"
CUR=$(root_cur "$G"); [ -n "$CUR" ] && [ -f "$CUR/exefs/main" ] || { echo "【红】$G 现行产物根没有 exefs/main"; exit 1; }
[ -x "$SRC_N" ] || { echo "【红】没有 ${SRC_N}（dotnet build -c Release pack/nx_unpack -o $(dirname "$SRC_N")）"; exit 1; }
TID=$(prog_id "$CUR"); [ -n "$TID" ] || { echo "【红】$G 现行产物根取不到程序号"; exit 1; }
L=$(src_ids) || { echo "【红】$G 原件探测出错（见上一行，机器原因），追加内容阶段停：不能当「没有这个程序号的包」跳过 DLC"; exit 1; }
L=$(printf '%s\n' "$L" | awk -F'\t' -v t="$TID" 'toupper($4) == t || $4 == "-"')
echo "$L" | awk -F'\t' -v t="$TID" 'toupper($4) == t {f=1} END {exit !f}' || { echo "🟡 $G 本机 ${SRC_DIR} 下没有程序号 $TID 的原始包，追加内容阶段跳过（现行不动）"; exit 0; }
# 工具只按内容进键：shasum 带文件名（完整检出 / 家目录路径）时换目录键就变，只取哈希列（同 pack/stage_rewrite.sh 10-23 那处）
# 原件身份（pack/srcs.sh src_ident：大小 修改时间 ctime inode；审计 P1-54：src_ids 那行只有路径 / 大小 / 修改时间，保住这三样换了 DLC 原件照用旧的）。不读内容：原件可能软链在机械盘上
SI=$(f=(); while IFS=$'\t' read -r x _; do [ -n "$x" ] && f+=("$x"); done <<< "$L"; [ ${#f[@]} = 0 ] || src_ident "${f[@]}") || { echo "【红】$G 读不出追加内容原件的身份（stat）"; exit 1; }
# main 构建号用 od 读（P2-278：不依赖 xxd；输出与原 xxd -p 逐字节相同，键不变）
BID=$(od -An -v -tx1 -j 64 -N 16 "$CUR/exefs/main" | tr -d ' \n')
[[ "$BID" =~ ^[0-9a-f]{32}$ ]] || { echo "【红】$G 读不出 exefs/main 的构建号（0x40 起 16 字节，读到「${BID}」）"; exit 1; }
K=$( { echo "$L"; echo "$SI"; for t in "$SRC_N.dll" "$SRC_N"; do [ -f "$t" ] && shasum -a 256 < "$t"; done; printf '%s\n' "$BID"; } | shasum -a 256 | cut -c1-16)
KB=$K; K=$(stage_deps_key "$CUR" aoc "$KB" "$SELF") || exit 1
root_stage_done "$CUR" aoc "$K" && { echo "🟢 $G 现行已是追加内容 ${K}，跳过"; exit 0; }
fs=(); while IFS=$'\t' read -r f _; do fs+=("$f"); done <<< "$L"
C=${S2A_AOC_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/aoc}/$G-$K
MISS=(); FROM=$C; KEEP=0   # MISS：「文件名<TAB>原因」；FROM：克隆来源（全部解出 = 共享缓存）；KEEP=1：一份都没解出，aoc/ 与 aoc.tsv 沿用现行
miss() { MISS+=("$(basename "$1")	$(printf '%s' "$2" | tr '\t\n' '  ' | cut -c1-160)"); echo "🟡 ${G} 追加内容 $(basename "$1") 未能解出（$(printf '%s' "$2" | cut -c1-160)），跳过"; }
if [ ! -f "$C/aoc.tsv" ]; then   # 缓存没有：解到 C.tmp.<pid>（带一份 main 供版本核对，解完删），再改名；并发时后到的丢弃自己那份
  S=$C.tmp.$$; rm -rf "$S"; mkdir -p "$S/exefs" && _root_cp "$CUR/exefs/main" "$S/exefs/main" || { echo "【红】$G 建追加内容缓存失败"; exit 1; }
  # 解不出（原始包与产物根程序版本不符、密钥缺等）只跳过不拦出包：DLC 是附加内容，拦住会让整款出不了包（10-20 01006F8002326000：产物根 exefs 与本机 3.0.3 卡带版本不符，刷新全红）
  if ! ${S2A_HDD_READ:-} "$SRC_N" "$SRC_K" "$S" --aoc-only --title-id="$TID" "${fs[@]}" > "$S/aoc.log" 2>&1; then   # S2A_HDD_READ：读原件锁前缀（见 pack/stages/unpack.sh）
    # 整份解不出时逐份兜底（审计 P2-30：原先一份解不出连带其余能解的全部跳过）。--aoc-only 要本体 + 更新做版本核对，所以每次给「上下文 + 一份纯 DLC 包」：
    #   上下文 = 程序号对上的包 + 内容清单里有本体 / 更新的单独包（nx_unpack --inspect 按内容分，不看文件名）；内容清单都读不出的那份直接记缺
    WHY=$(tail -1 "$S/aoc.log"); _root_rm "$S/aoc"; rm -f "$S/aoc.tsv"   # aoc.log 留着整份那次的日志，逐份的接在后面
    ctx=(); dl=(); while IFS=$'\t' read -r f _ _ id; do
      [ "$id" = - ] || { ctx+=("$f"); continue; }
      ty=$("$SRC_N" "$SRC_K" --inspect "$f" 2> /dev/null | python3 -c 'import json, sys; print(" ".join(sorted({p["type"] for p in json.load(sys.stdin)["packages"]})))' 2> /dev/null) || { miss "$f" "读不出内容清单（nx_unpack --inspect）"; continue; }
      if [ "$ty" = dlc ]; then dl+=("$f"); else ctx+=("$f"); fi
    done <<< "$L"
    if [ ${#dl[@]} = 0 ]; then for f in "${ctx[@]}"; do miss "$f" "$WHY"; done   # 没有单独的 DLC 包：DLC 在上下文包里，整份失败就是它们失败
    else ok=(); i=0
      for f in "${dl[@]}"; do i=$((i + 1)); P=$S/part$i; mkdir -p "$P/exefs" && _root_cp "$S/exefs/main" "$P/exefs/main" || { echo "【红】$G 建追加内容分份目录失败"; exit 1; }
        if ${S2A_HDD_READ:-} "$SRC_N" "$SRC_K" "$P" --aoc-only --title-id="$TID" "${ctx[@]}" "$f" > "$P/aoc.log" 2>&1; then ok+=("$P"); else miss "$f" "$(tail -1 "$P/aoc.log")"; fi
      done
      [ ${#ok[@]} = 0 ] || aoc_merge_parts "$S" "${ok[@]}" || { echo "【红】$G 合并逐份解出的追加内容失败"; exit 1; }
      for P in "$S"/part*; do _root_rm "$P"; done
    fi
    [ -f "$S/aoc.tsv" ] || KEEP=1
  fi
  rm -rf "$S/exefs"
  # 缺的每份一行固定格式「追加内容缺<TAB>文件名<TAB>原因」进 aoc.log（运行区出包队列按它登记解码缺陷，格式别改）；有缺的结果不进共享缓存（同键别的根再试一次）
  for m in "${MISS[@]}"; do printf '追加内容缺\t%s\n' "$m" >> "$S/aoc.log"; done
  if [ ${#MISS[@]} = 0 ]; then aoc_cache_publish "$S" "$C" || exit 1; else FROM=$S; trap '_root_rm "$S"' EXIT; fi
fi
TAG=$(root_tag "$G" "aoc-${K:0:8}"); W=$(root_begin "$G" "$TAG") || exit 1
if [ $KEEP = 1 ]; then   # 一份都没解出：aoc/ 与 aoc.tsv 沿用现行（与原先「现行不动」一致，键不记，下次刷新再试），只换 aoc.log 让出包收尾点名缺的包
  if cmp -s <(grep -a '^追加内容缺	' "$CUR/aoc.log" 2> /dev/null) <(grep -a '^追加内容缺	' "$FROM/aoc.log"); then root_abort "$G" "$TAG"
  else _root_cp "$FROM/aoc.log" "$W/" || { echo "【红】$G 写追加内容日志失败"; root_abort "$G" "$TAG"; exit 1; }
    ROOT_REPLAY='aoc.log' root_commit "$G" "$TAG" || exit 1; fi
  echo "🟡 $G 追加内容 ${#MISS[@]} 份都没解出（$(printf '%s\n' "${MISS[@]}" | cut -f1 | tr '\n' ' ')），本体照常出包、现行追加内容不动"; exit 0
fi
_root_rm "$W/aoc"; rm -f "$W/aoc.tsv" "$W/aoc.log"
{ [ ! -d "$FROM/aoc" ] || python3 "$R/tools/clonedir.py" "$FROM/aoc" "$W/aoc"; } && _root_cp "$FROM/aoc.tsv" "$FROM/aoc.log" "$W/" || { echo "【红】$G 从追加内容缓存克隆失败"; root_abort "$G" "$TAG"; exit 1; }
K=$(stage_deps_save "$W" aoc "$KB" "$SELF") || { root_abort "$G" "$TAG"; exit 1; }
echo "$K" > "$W/.stage_aoc"
ROOT_REPLAY='aoc aoc.tsv aoc.log .stage_aoc .stage_aoc.deps' root_commit "$G" "$TAG" || exit 1   # 与改写 / 系统数据 / 界面布局并行：本阶段只写这些
if [ ${#MISS[@]} = 0 ]; then echo "🟢 $G 追加内容：$(grep -av '^追加内容缺	' "$(root_cur "$G")/aoc.log" | tail -1 | cut -c1-200)"
else echo "🟡 $G 追加内容 ${#fs[@]} 份原始包中 ${#MISS[@]} 份没解出（$(printf '%s\n' "${MISS[@]}" | cut -f1 | tr '\n' ' ')），其余已进产物根"; fi
