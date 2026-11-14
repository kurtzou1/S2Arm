#!/bin/bash
# Mac 局收局把本机见过的管线拷进管线种子来源目录（审计 #1534 P1-54 B4）：
#   source 后 pso_seed_keep_mac <模块目录（含 main.npdm）>   runtime/run_mac.sh 每局收局调：本局那一款
#   bash tools/pso_seed_keep.sh --all                        一次性迁移：~/Documents/wire/<程序号>/pso_user.tsv 每一款都并进来（合入本改动、出包改读 pso_seed/ 时跑一次，
#                                                            否则本机以前 Mac 局攒下、只在文稿里的知识，出包就读不到了；11-07 起 Mac 局不再写 ~/Documents，这里只剩旧数据）
#   宿主直连层把本机见过的管线 / 配对 / 变体记在 ${DM_PSO_USER:-<文档根>/wire/<程序号>/pso_user.tsv}（graphics/nvn/host_adapt.m，只追加）；
#   文档根 = S2A_DOCS（runtime/run_mac.sh 缺省局目录），没有才 ~/Documents（runtime/include/s2a_docs.h 同口径）。
#   出包不再实时读这份活文件（不同机器读到的不同、出库途中还会被追加），改由这里并进 <种子目录>/<程序号>/mac_<本机名>.tsv（本机名见 pso_seed_mac_name）：
#   先原有行、再补新行，按整行去重、不改原有行序（tmp + mv 写；没有新行不动文件）。种子目录 = S2A_PSO_SEED_DIR（缺省 <运行根>/s2arm/pso_seed，同 tools/dev_run.sh 的 pso_keep）。
#   出包（graphics/tools/direct/run_knowledge.py）只读种子目录：Windows 出包机同步这一个目录就和 Mac 出同一个根。每款只打一行结果；读不到程序号 / 没有这份表只记一行、不判红。
pso_seed_mac_name() {   # 本机名：macOS 的本地主机名（LocalHostName，不随网络变；hostname -s 换网会变成 bogon 之类），取不到退回 hostname -s；只留 [A-Za-z0-9_-]
  { scutil --get LocalHostName 2> /dev/null || hostname -s; } | head -1 | tr -c 'A-Za-z0-9_\n-' _
}
pso_seed_merge() {   # pso_seed_merge <程序号（16 位十六进制）> <本机 pso_user.tsv>
  local tid=$1 src=$2 d dst n0 n1
  [ -s "$src" ] || { echo "管线种子来源：本机没有 ${src}（通用模式局 / 没建过管线），不拷"; return 0; }
  d=${S2A_PSO_SEED_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/pso_seed}/$tid; dst=$d/mac_$(pso_seed_mac_name).tsv
  mkdir -p "$d" || { echo "管线种子来源：建不了 ${d}，不拷"; return 0; }
  n0=$(grep -ac . "$dst" 2> /dev/null); n0=${n0:-0}
  { [ ! -f "$dst" ] || cat "$dst"; cat "$src"; } | awk 'length($0) && !s[$0]++' > "$dst.tmp.$$" || { rm -f "$dst.tmp.$$"; echo "管线种子来源：写不了 ${dst}，不拷"; return 0; }
  n1=$(grep -ac . "$dst.tmp.$$")
  if [ "$n1" = "$n0" ]; then rm -f "$dst.tmp.$$"; echo "管线种子来源：${dst} 已含本机全部 ${n1} 行，没有新行"
  else mv "$dst.tmp.$$" "$dst" && echo "管线种子来源：本机 pso_user.tsv 并进 ${dst}（${n0} → ${n1} 行）"; fi
}
pso_seed_keep_mac() {
  local m=${1:?模块目录} tid
  tid=$("${S2A_PY:-python3}" -c 'import sys; sys.path.insert(0, sys.argv[1]); import addr_need; print(addr_need.npdm_program(sys.argv[2]).upper())' \
        "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" "$m/main.npdm" 2> /dev/null) || { echo "管线种子来源：读不出程序号（$m/main.npdm），不拷"; return 0; }
  local docs=${S2A_DOCS:-$HOME/Documents}   # 文档根，同宿主 runtime/include/s2a_docs.h
  pso_seed_merge "$tid" "${DM_PSO_USER:-$docs/wire/$tid/pso_user.tsv}"
  pso_seed_vk_spv "$tid" "$docs/wire/$tid/shaders/vk"
}
pso_seed_vk_spv() {   # pso_seed_vk_spv <程序号> <本机 vk/ 目录>：Vulkan 首遇现编存下的游戏 SPIR-V（<键>.spv）并进 <种子目录>/<程序号>/vk_spv/（已有同名不覆盖，11-05）
  local tid=$1 src=$2 d f n=0
  d=${S2A_PSO_SEED_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/pso_seed}/$tid/vk_spv
  for f in "$src"/*.spv; do [ -s "$f" ] || continue; mkdir -p "$d" || return 0; [ -e "$d/${f##*/}" ] || { cp "$f" "$d/${f##*/}.tmp.$$" && mv "$d/${f##*/}.tmp.$$" "$d/${f##*/}" && n=$((n + 1)); }; done
  [ "$n" = 0 ] || echo "Vulkan 现编 SPIR-V：本机新收 ${n} 支 → ${d}"
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case ${1:-} in
    --one)
      [ "$#" = 3 ] || { echo "用法：bash tools/pso_seed_keep.sh --one <程序号> <pso_user.tsv>" >&2; exit 2; }
      t=$(tr 'a-f' 'A-F' <<< "$2"); [[ "$t" =~ ^[0-9A-F]{16}$ ]] || { echo "程序号不是 16 位十六进制：$2" >&2; exit 2; }
      pso_seed_merge "$t" "$3"
      ;;
    --all)
      for f in "$HOME"/Documents/wire/*/pso_user.tsv; do
        t=$(basename "$(dirname "$f")"); [[ "$t" =~ ^[0-9A-F]{16}$ ]] || continue   # 只认程序号目录（不收 .bak_* 之类的手工备份）
        pso_seed_merge "$t" "$f"
      done
      ;;
    *) echo "用法：bash tools/pso_seed_keep.sh --all | --one <程序号> <pso_user.tsv>（或 source 后调 pso_seed_keep_mac <模块目录>）" >&2; exit 2;;
  esac
fi
