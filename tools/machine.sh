# 读本机私有标识（tools/machine.local，不进仓库）。找不到该文件就什么都不设。
# 仓库脚本只认下面这些名字，调用方已经 export 的同名变量不会被这里改掉：
#   S2A_GATE_HOST_DEFAULT      sched / oneshot 连 gate-host 的 ssh 目标
#   S2A_REMOTE_HOSTS      维护方工具 按顺序试的 ssh 目标（空格分隔）
#   S2A_REMOTE_DEFAULT    都连不上时 维护方工具 用的目标
#   S2A_REMOTE_SPARE        维护方工具 --host spare-host 的 ssh 目标（缺省 ssh 别名 spare-host）
#   S2A_REMOTE_MAC_POOL   Mac 游戏局分流的机器池（如「gate-host spare-host」；空 = 不分流，Mac 局照旧 gate-host）
#   （已并入 维护方工具：远端同步 / 派活下限统一 S2A_REMOTE_MIN_FREE_GB，缺省 30）
#   S2A_TEAM_DEFAULT      pack/ipa.sh 的签名团队
#   S2A_DEVICES_LOCAL     测试设备名单（格式同 tools/devices.sh 的缺省）
#   S2A_DAILY_PHONE_LOCAL 拒绝碰的日常手机硬件标识
#   S2A_CPU_LEDGER        1 = 我方共享机器；不设 = 用户机器（审计 #1534 P1-54 起出库不再据此读 ~/Documents/wire：Mac 局收局拷进 pso_seed/，tools/pso_seed_keep.sh）
#   S2A_PY                出包 / 门禁 / Mac 局用的 Python（开发机钉版 venv）。没设：S2A_PYTHON → PATH 上的 python3（11-07 启动器零配置：代码里不再探开发机 venv）
#   S2A_COMMUNITY_DIR     社区补丁库根（*/full/*/INDEX.tsv）；没设 = 没有社区补丁（不再缺省读开发机数据盘）
#   S2A_REFLIB_ROOT       社区着色器参考库根（pack/stages/shaders.sh）；没设 = 不用
#   S2A_UW_PATCHES        宽屏自动出表的社区超宽补丁目录（graphics/widen/scan/auto_table.sh）；没设 = 不用
# 出包链脚本不 source 本文件（会把 S2A_CPU_LEDGER 等我方机器设定带进出包），只按名取一项（下面的执行模式，子进程里读，不污染调用方）：
#   bash tools/machine.sh get <名>   → 调用方环境里非空就打印它，否则打印 machine.local 里的值（S2A_MACHINE_NO_LOCAL=1 时不读），都没有打印空行、退出 0
# 单测设 S2A_MACHINE_NO_LOCAL=1 就不读本机文件。
# 找文件的顺序：S2A_MACHINE_LOCAL（显式给路径）→ 本脚本同目录的 machine.local → 主检出 tools/machine.local（按 git 公共目录找，11-12：原先写成相对路径 tools/machine.local，
#   只有当前目录是主检出时才找得到，各线工作树里静默退到占位标识）→ 当前目录的 tools/machine.local。
#   第三项不能省：各线工作树、列车落地树、常驻调度的冻结副本（sched/auto/tools_*，git archive / cp 出来的）都没有这份未跟踪文件，
#   只认同目录时它们会静默退到占位标识（选不中真机），ssh 目标为空。读到的文件路径留在 S2A_MACHINE_FILE（维护方工具 派 gate-host 时随 tools 一起推）。
[ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = get ] && [ -n "${2:-}" ] && [ -n "${!2:-}" ] && { printf '%s\n' "${!2}"; exit 0; }   # 执行模式：环境优先
S2A_MACHINE_FILE=
if [ "${S2A_MACHINE_NO_LOCAL:-0}" != 1 ]; then
  for _S2A_MACHINE_F in ${S2A_MACHINE_LOCAL:+"$S2A_MACHINE_LOCAL"} "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/machine.local" "$(_d=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --path-format=absolute --git-common-dir 2> /dev/null) && echo "${_d%/.git}/tools/machine.local")" "tools/machine.local"; do
    # machine.local 只是一组赋值：它最后一条命令的退出码（如末行「[ -f X ] && . X」X 不在时为 1）不代表出错，不许传给调用方——
    #   调用方多是 set -e 且 2> /dev/null 地 source 本文件（tools/toolchain.sh），原先整条脚本在这里无声退出（launchers/macos/test.sh 空日志 rc=1）
    [ -f "$_S2A_MACHINE_F" ] && { S2A_MACHINE_FILE=$_S2A_MACHINE_F; . "$_S2A_MACHINE_F" || :; break; }
  done
  unset _S2A_MACHINE_F
fi
if [ "${BASH_SOURCE[0]}" = "$0" ]; then   # 执行模式（见文件头）：环境里没有，取 machine.local 的值
  [ "${1:-}" = get ] && [ -n "${2:-}" ] || { echo "用法：bash tools/machine.sh get <变量名>" >&2; exit 2; }
  printf '%s\n' "${!2:-}"
fi
