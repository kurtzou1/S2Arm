#!/bin/bash
# 共享出包阶段单测（J07 #183）：bash tests/pack_stages_test.sh
# 合成夹具：假 nx_unpack / 假 services/romfs_index.sh；不联网、不用游戏文件、不需要 dotnet。（11-07 只服务通用模式的着色器阶段已删，本片不再测它）
# 每个阶段都断言四件事（issue #183 验收）：
#   ① 产物落在约定相对路径，且「旧入口 pack/stage_*.sh」与「共享入口 pack/stages/*.sh」逐字节一致；
#   ② 键只由本阶段输入决定：换目标名 / ABI / 宿主工具链环境变量，键不变；
#   ③ 输入变一个字节，键变；
#   ④ 失败输入退出非 0、现行 / <out> 不动、不留 .tmp / 半成品。
# 另外检查共享产物相对路径里没有 ios / android / ohos（目标隔离）。
#
# 为什么要并行：各阶段互不依赖（解包用 $T/src 与 x*、系统数据用 s*、索引用 r* 等互不相交的款名），
#   各阶段自己的 root_begin / root_commit 也按款加锁；串行跑每个阶段都要整棵产物根克隆 + 提交，几十次下来一两分钟。
#   四组并行后墙钟≈最慢的一组，仍在 60 秒内跑完（本机 10 核实测约 30–40 秒）。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); T=$(cd "$T" && pwd -P); bad=0; n=0
ck() { n=$((n + 1)); if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
same_tree() {   # same_tree <a> <b>：忽略顶层 .stage_*（阶段键单独断言）后逐字节比较
  python3 - "$1" "$2" <<'PY'
import hashlib, os, sys
def snap(r):
    out = {}
    for d, ds, fs in os.walk(r):
        for f in fs:
            p = os.path.join(d, f); rel = os.path.relpath(p, r)
            if os.sep not in rel and rel.startswith('.stage_'): continue
            with open(p, 'rb') as fh: out[rel] = hashlib.sha256(fh.read()).hexdigest()
    return out
sys.exit(0 if snap(sys.argv[1]) == snap(sys.argv[2]) else 1)
PY
}
no_target_path() {   # 相对路径里不许出现目标名
  python3 - "$1" <<'PY'
import os, sys
bad = {'ios', 'android', 'ohos'}
for d, ds, fs in os.walk(sys.argv[1]):
    for x in ds + fs:
        if x.lower() in bad: sys.exit(1)
sys.exit(0)
PY
}
tagof() { local x; x=$(basename "$1"); case $x in *@*) echo "${x#*@}";; *) echo "$x";; esac; }

R=$T/repo; mkdir -p $R/pack $R/tools $R/services/S2A.Services $R/services/romfs_index $R/compat/tree $R/graphics/tools/shbake $R/graphics/nvn/tools $R/fake $T/roots $T/fonts $T/src $T/sd/0100000000000801
cp "$H/pack/stage_keyfiles.sh" $R/pack/; cp "$H/tools/stage_deps.py" $R/tools/; cp -R "$H/tools/stage_deps_hook" $R/tools/   # 各阶段实际读入进键（pack/stage_keyfiles.sh，10-30）
cp "$H/pack/roots.sh" "$H/pack/srcs.sh" "$H/pack/stage_sysdata.sh" "$H/pack/stage_romfsidx.sh" \
   "$H/pack/stage_nacp.sh" "$H/pack/stage_aoc.sh" "$H/pack/direct_profile_input.py" \
   "$H/pack/sysdata_need.py" "$H/pack/sysdata_synth.py" "$H/pack/sysdata_mii.py" $R/pack/
mkdir -p "$R/pack/orch" && cp "$H/pack/orch/current.py" "$R/pack/orch/"   # roots.sh 写现行指针 / 迁移老库（pack/orch/current.py）
cp -R "$H/pack/stages" $R/pack/
cp "$H/tools/clonedir.py" "$H/tools/safe_killpg.sh" "$H/tools/plock.sh" "$H/tools/flock_hold.py" $R/tools/   # roots.sh 提交锁用 tools/plock.sh（审计 P1-27）
# romfs_list.py：仓库里唯一的 RomFS 遍历（11-03），被测脚本经它列 RomFS
cp "$H/graphics/tools/timeout_snap.sh" $R/graphics/tools/; cp "$H/graphics/nvn/tools/gfx_api.py" "$H/graphics/nvn/tools/romfs_list.py" $R/graphics/nvn/tools/
mkdir -p "$R/tools"; cp "$H/tools/pool_workers.py" "$R/tools/"   # romfs_list / pak_crypto 经它取核数（#1332：核数唯一来源）
printf 'import sys\nprint("nvn\\tfake")\n' > $R/graphics/nvn/tools/gfx_api.py
printf '#!/bin/bash\nshift 2\nexec "$@"\n' > $R/graphics/tools/timeout_snap.sh
chmod +x $R/graphics/tools/timeout_snap.sh
printf '// fake\n' > $R/services/S2A.Services/RomFsIndex.cs; printf 'x\n' > $R/services/romfs_index/index.txt
printf 'placeholder\n' > $R/compat/tree/Directory.Packages.props

# 假 nx_unpack：--nacp-only 按内容（这里用文件名代表内容）给程序号 + 写 ctl/control.nacp；
# --aoc-only 写 aoc/<序号>/ + aoc.tsv + aoc.log（追加内容阶段要的产物）；完整解包写一棵最小但齐全的树
cat > $R/fake/nx_unpack <<'EOF'
#!/bin/bash
# --inspect（追加内容逐份兜底按内容分包）：文件名 dlc* = 纯 DLC 包、upd* = 更新包、其余 = 本体
if [ "${2:-}" = --inspect ]; then case $(basename "$3") in dlc*) t=dlc;; upd*) t=update;; *) t=base;; esac; printf '{"packages":[{"type":"%s"}]}\n' "$t"; exit 0; fi
KEYS=$1; OUT=$2; shift 2; NACP=0; AOC=0; TID=; SRC=()
for a in "$@"; do case $a in
  --nacp-only) NACP=1;; --aoc-only) AOC=1;; --aoc-index) ;;
  --title-id=*) TID=${a#--title-id=};; *) SRC+=("$a");;
esac; done
if [ "$NACP" = 1 ]; then
  [ "${FAKE_NX_FAIL:-0}" = 1 ] && { echo "假解包失败" >&2; exit 1; }
  [ -n "${FAKE_PROBE_RC:-}" ] && { echo "假：You must install .NET to run this application." >&2; exit "$FAKE_PROBE_RC"; }   # 工具本身没跑成（131 = 没有 .NET 运行时）
  mkdir -p "$OUT/ctl"; id=-
  case $(basename "${SRC[0]}") in base.nsp) id=0100AAAA00000000;; other.nsp) id=0100BBBB00000000;; esac
  printf 'title_id\t%s\n' "$id" > "$OUT/unpack.tsv"
  printf 'nacp:%s\n' "$(basename "${SRC[0]}")" > "$OUT/ctl/control.nacp"; exit 0; fi
if [ "$AOC" = 1 ]; then
  [ -n "${FAKE_NX_LOG:-}" ] && echo "AOC $*" >> "$FAKE_NX_LOG"
  { [ "${FAKE_NX_FAIL:-0}" = 1 ] || [ "${FAKE_AOC_FAIL:-0}" = 1 ]; } && { echo "假追加内容失败" >&2; exit 1; }   # FAKE_AOC_FAIL：只追加内容解不出、认包探测照常
  if [ -n "${FAKE_AOC_BAD+x}" ]; then   # 逐份模式：给的文件里有 FAKE_AOC_BAD 点名的（逗号分隔）就整份失败；否则每个 dlc<N>.nsp 解出序号 N
    for f in "${SRC[@]}"; do case ",$FAKE_AOC_BAD," in *",$(basename "$f"),"*) echo "🔴 假：$(basename "$f") 数据分区解不开" >&2; exit 1;; esac; done
    printf 'idx\ttitle_id\tversion\tfiles\tbytes\n' > "$OUT/aoc.tsv"
    for f in "${SRC[@]}"; do b=$(basename "$f" .nsp); case $b in dlc*) i=${b#dlc}; mkdir -p "$OUT/aoc/$i"; printf '%s\n' "$b" > "$OUT/aoc/$i/x.bin"
      printf '%s\t%016x\t0\t1\t5\n' "$i" $((0x0100AAAA00001000 + i)) >> "$OUT/aoc.tsv";; esac; done
    echo "🟢 假追加内容：$(grep -c . "$OUT/aoc.tsv") 行"; exit 0; fi
  mkdir -p "$OUT/aoc/000"; printf 'dlc\n' > "$OUT/aoc/000/x.bin"
  printf '000\t0100000000001000\t65536\t1\t4\n' > "$OUT/aoc.tsv"; echo "假追加内容完成" > "$OUT/aoc.log"; exit 0; fi
[ "${FAKE_NX_FAIL:-0}" = 1 ] && { echo "假解包失败" >&2; exit 1; }
mkdir -p "$OUT/exefs" "$OUT/romfs/data" "$OUT/ctl" "$OUT/aoc/000"
printf 'main:%s\n' "${TID:-none}" > "$OUT/exefs/main"; printf 'npdm\n' > "$OUT/exefs/main.npdm"
printf 'romfs\n' > "$OUT/romfs/data/blob.bin"; printf 'nacp\n' > "$OUT/ctl/control.nacp"
# 与真 nx_unpack 同形：update 无更新时为空，base 记本体 CNMT 版本（直连配置版本旁注取它，显示版本不能替代）
#   FAKE_NO_VER=1 模拟旧版工具：只有 title_id，没有 update 也没有 base（旁注写不出来，阶段该报红）
if [ "${FAKE_NO_VER:-0}" = 1 ]; then printf 'title_id\t%s\n' "${TID:-0100000000000000}" > "$OUT/unpack.tsv"
else printf 'title_id\t%s\ndisplay_version\t9.9\nupdate\t%s\nbase\t%s\n' "${TID:-0100000000000000}" "${FAKE_UPD:-}" "${FAKE_BASE:-4096}" > "$OUT/unpack.tsv"; fi
printf 'aoc\n' > "$OUT/aoc.tsv"; printf 'dlc\n' > "$OUT/aoc/000/x.bin"
[ -n "${FAKE_NX_LOG:-}" ] && echo "EXTRACT $*" >> "$FAKE_NX_LOG"
echo "假解包完成"
EOF
chmod +x $R/fake/nx_unpack
printf 'fake-dll\n' > $R/fake/nx_unpack.dll   # 追加内容阶段的键里含 nx_unpack.dll 的哈希
# 假 RomFS 索引：内容只由 romfs 清单决定（真实实现是服务层 C#，本机 dotnet 缺失）
cat > $R/services/romfs_index.sh <<'EOF'
#!/bin/bash
ROOT=$1; [ "${FAKE_RX_FAIL:-0}" = 1 ] && { echo "假索引失败" >&2; exit 1; }
# 带 --list（出包期）：索引 = 清单原文（字节数 + 路径，真索引器只认这两样）；不带：目录里的文件名
{ echo "S2ARM-ROXIDX1"; if [ "${2:-}" = --list ]; then LC_ALL=C sort "$3"; else (cd "$ROOT/romfs" && find . -type f -print | LC_ALL=C sort); fi; } > "$ROOT/romfs.s2aidx"
EOF
chmod +x $R/services/romfs_index.sh
printf 'k\n' > $T/keys
(cd $R && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm fixture)

export S2A_ROOTS=$T/roots S2A_ROOTS_SHARED=$T/shared S2A_FONTS=$T/fonts S2A_SYSDATA=$T/sd S2A_SRC_IDS=$T/ids.tsv
export S2A_SCHED_DIR=$T/sched S2A_MEM_BAKE_GB=12
printf '# 程序号\t构建号\t版本\t系统数据号\t用途\t依据\n0100AAAA00000000\t11223344\t1.0\t0100000000000801\t错误信息文本\t单测\n' > $T/need.tsv
printf 'font' > $T/fonts/a.bfttf; printf 'errmsg-v1' > $T/sd/0100000000000801/version.dat
# 原始包夹具（内容用文件名代表）：选包 / 解包、元数据两个阶段共用，各组只读不写（避免并行时互相改输入）
for f in base upd dlc other; do printf '%s' "$f" > $T/src/$f.nsp; done
touch -t 202601010101 $T/src/*.nsp

mkroot() {   # mkroot <款> <exefs/main 内容> <romfs 文件内容>
  local d=$T/roots/$1@s0; mkdir -p "$d/exefs" "$d/romfs"; printf '%s\n' "$2" > "$d/exefs/main"; printf '%s\n' "$3" > "$d/romfs/f"
  printf '%s\n' "$1@s0" > "$T/roots/$1@现行"
}
mksys() {   # mksys <款>：带程序号 / 构建号 / 时区的产物根（系统数据阶段要）
  local d=$T/roots/$1@s0; mkdir -p "$d/exefs" "$d/systemdata/010000000000080E"
  printf 'title_id\t0100AAAA00000000\ndisplay_version\t9.9\n' > "$d/unpack.tsv"
  python3 -c "import sys;open(sys.argv[1],'wb').write(b'\0'*0x40+bytes.fromhex('11223344')+b'\0'*44)" "$d/exefs/main"
  echo tz > "$d/systemdata/010000000000080E/binaryList.txt"; printf '%s\n' "$1@s0" > "$T/roots/$1@现行"
}
mknacp() {   # mknacp <款>：只有 exefs/main（0x40 处是构建号 11223344），没有 ctl/control.nacp
  local d=$T/roots/$1@s0; mkdir -p "$d/exefs"
  python3 -c "import sys;open(sys.argv[1],'wb').write(b'\0'*0x40+bytes.fromhex('11223344')+b'\0'*44)" "$d/exefs/main"
  printf '%s\n' "$1@s0" > "$T/roots/$1@现行"
}
cur() { cd -P "$T/roots/$(cat "$T/roots/$1@现行")" && pwd; }

# ── A. 选包 / 解包 ────────────────────────────────────────────────────────────
sec_unpack() {
  local f o r kk k1 e i
  : > $T/nxlog
  # 第一批（并行）：① 只看不写 ② 两款本体不给 --title-id → 拒绝 ③ 正常解包（记日志）
  ( o=$(U inspect --src $T/src 2>&1); r=$?; printf '%s\n' "$o" > $T/A1.inspect.out; echo $r > $T/A1.inspect.rc ) &
  ( o=$(U extract --src $T/src --out $T/x0 2>&1); r=$?; printf '%s\n' "$o" > $T/A1.x0.out; echo $r > $T/A1.x0.rc ) &
  ( FAKE_NX_LOG=$T/nxlog U extract --src $T/src --title-id 0100AAAA00000000 --out $T/x1 > $T/A1.x1.out 2>&1; echo $? > $T/A1.x1.rc ) &
  wait
  o=$(cat $T/A1.inspect.out); r=$(cat $T/A1.inspect.rc)
  ck "解包① inspect 4 行：base=AAAA、other=BBBB、upd/dlc 记 -（真结果 $(printf '%s' "$o" | awk -F'\t' '{printf "%s=%s ", $1, $4}')）" \
     '[ $r = 0 ] && [ "$(printf "%s\n" "$o" | grep -c .)" = 4 ] && [ "$(printf "%s\n" "$o" | awk -F"\t" "\$1 ~ /base.nsp$/ {print \$4}")" = 0100AAAA00000000 ] && [ "$(printf "%s\n" "$o" | awk -F"\t" "\$1 ~ /other.nsp$/ {print \$4}")" = 0100BBBB00000000 ] && [ "$(printf "%s\n" "$o" | awk -F"\t" "\$1 ~ /upd.nsp$/ {print \$4}")" = - ] && [ "$(printf "%s\n" "$o" | awk -F"\t" "\$1 ~ /dlc.nsp$/ {print \$4}")" = - ]'
  o=$(cat $T/A1.x0.out); r=$(cat $T/A1.x0.rc)
  ck "解包① 目录里两款本体、没给 --title-id → 拒绝（rc=${r}），不写 ${T}/x0" '[ $r != 0 ] && [ ! -e $T/x0 ] && [[ "$o" == *恰好*1*款* ]]'
  # 主游戏 + 同系列小工具（10-26 #456）：本体包字节 5000 ≥ 100 × 4 → 不给 --title-id 也自动认 AAAA、黄字点名跳过 BBBB（期望按规则手写）
  mkdir -p $T/src2; head -c 5000 /dev/zero > $T/src2/base.nsp; head -c 100 /dev/zero > $T/src2/other.nsp
  o=$(U extract --src $T/src2 --out $T/x2 2>&1); r=$?
  ck "解包① 游戏 + 小工具、没给 --title-id → 按大小认 AAAA、黄字点名跳过 BBBB（rc=${r}）" '[ $r = 0 ] && [[ "$o" == *"按大小认 0100AAAA00000000 是主游戏，跳过 0100BBBB00000000"* ]] && [ -f $T/x2/.stage_unpack ]'
  r=$(cat $T/A1.x1.rc); kk=$(cat $T/x1/.stage_unpack 2> /dev/null)
  ck "解包① extract 写出约定路径（rc=${r}）" '[ $r = 0 ] && [ -f $T/x1/exefs/main ] && [ -f $T/x1/romfs/data/blob.bin ] && [ -f $T/x1/ctl/control.nacp ] && [ -f $T/x1/aoc/000/x.bin ] && [ -f $T/x1/unpack.tsv ] && [ ${#kk} = 16 ]'
  ck "解包① 按内容选包：传 --aoc-index / --title-id，只给 base + upd + dlc（不含 other）" 'grep -q -- "--aoc-index --title-id=0100AAAA00000000" $T/nxlog && grep -q "base.nsp" $T/nxlog && grep -q "upd.nsp" $T/nxlog && grep -q "dlc.nsp" $T/nxlog && ! grep -q "other.nsp" $T/nxlog'
  "$R/fake/nx_unpack" $T/keys $T/x_old --aoc-index --title-id=0100AAAA00000000 $T/src/base.nsp $T/src/upd.nsp $T/src/dlc.nsp > /dev/null 2>&1
  ck "解包① 产物相对路径不含目标名" 'no_target_path $T/x1'
  # 直连配置版本旁注（11-03 根修）：本阶段自己写，任何出包路径都从解包目录拿到。期望手算：
  #   假 nx_unpack 给的 unpack.tsv 是 update 空、base 4096 → content_version = 本体 4096（不是显示版本 9.9、不是 0）
  dp=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["format"], d["title_id"], d["content_version"], d["display"], d["name"])' $T/x1/direct-profile-input.json 2> /dev/null)
  ck "解包① 写出直连版本旁注、没有更新取本体版本（实得「${dp:-没有}」，期望「1 0100AAAA00000000 4096 9.9 」）" '[ "$dp" = "1 0100AAAA00000000 4096 9.9 " ]'
  # 有更新时取最新更新的版本（期望手算：假解包器给 update 65536 → 取 65536，不看 base 4096）
  rm -rf $T/x1u; FAKE_UPD=65536 U extract --src $T/src --title-id 0100AAAA00000000 --out $T/x1u > /dev/null 2>&1
  dp=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["content_version"])' $T/x1u/direct-profile-input.json 2> /dev/null)
  ck "解包① 有更新取更新版本（实得 ${dp:-没有}）" '[ "$dp" = 65536 ]'
  # 解包产物太旧（nx_unpack 没给本体版本、也没有更新）：报红停，不写 0 顶替（期望手算：无 update / base → 没有内容版本）
  rm -rf $T/x1n; FAKE_NO_VER=1 U extract --src $T/src --title-id 0100AAAA00000000 --out $T/x1n > $T/A1.x1n.out 2>&1; r=$?
  ck "解包④ 产物没有内容版本 → 报红、不写旁注、不留解包目录（rc=${r}，输出「$(tr '\n' ' ' < $T/A1.x1n.out | cut -c1-120)」）" '[ $r != 0 ] && [ ! -e $T/x1n ] && [[ "$(cat $T/A1.x1n.out)" =~ "没有更新也没有本体内容版本" ]]'
  rm -f $T/x1/direct-profile-input.json   # 旁注是本阶段新加的产物（上面单独断言），不属于「nx_unpack 原样产物」，下面的 same_tree 不比它
  ck "解包① 与「直接调 nx_unpack」的旧路径逐字节一致（旁注除外）" 'same_tree $T/x1 $T/x_old'
  k1=$(cat $T/x1/.stage_unpack)
  : > $T/nxlog   # 上一批的解包日志清空：下面「再跑必须复用」按「没有新的 EXTRACT 行」判
  # 第二批（并行）：换目标名 / ABI / 工具链各解一次（键必须不变）+ 同一输入再跑（必须复用、不重解）
  i=0; for e in "S2A_TARGET=android" "S2A_TARGET=ohos S2A_REWRITE_ABI=android-sp-safe-v1" "CC=clang CXX=clang++ MACOSX_DEPLOYMENT_TARGET=13.0"; do
    i=$((i + 1))
    ( env $e S2A_NX_UNPACK=$R/fake/nx_unpack S2A_SRC_IDS=$T/ids.tsv bash $R/pack/stages/unpack.sh extract --src $T/src --title-id 0100AAAA00000000 --out $T/xk$i > /dev/null 2>&1 ) &
  done
  ( o=$(U extract --src $T/src --title-id 0100AAAA00000000 --out $T/x1 2>&1); r=$?; printf '%s\n' "$o" > $T/A2.reuse.out; echo $r > $T/A2.reuse.rc ) &
  wait
  i=0; for e in "S2A_TARGET=android" "S2A_TARGET=ohos S2A_REWRITE_ABI=android-sp-safe-v1" "CC=clang CXX=clang++ MACOSX_DEPLOYMENT_TARGET=13.0"; do
    i=$((i + 1))
    ck "解包② 换「${e}」→ 键不变（$(cat $T/xk$i/.stage_unpack 2> /dev/null)）" '[ "$(cat $T/xk'"$i"'/.stage_unpack 2> /dev/null)" = "$k1" ]'
  done
  o=$(cat $T/A2.reuse.out); r=$(cat $T/A2.reuse.rc)
  ck "解包① 同一输入再跑 → 复用、不重解（rc=${r}，EXTRACT 行 $(grep -c '^EXTRACT' $T/nxlog)）" '[ $r = 0 ] && [[ "$o" == *复用* ]] && [ "$(grep -c "^EXTRACT" $T/nxlog)" = 0 ]'
  # 第三批（并行）：改一个字节后键变 / 解包失败 / 源不存在 / 已存在没 --force——四者互不依赖
  printf 'x' >> $T/src/base.nsp; touch -t 202601020202 $T/src/base.nsp
  mkdir -p $T/xbusy && echo bogus > $T/xbusy/.stage_unpack
  ( U extract --src $T/src --title-id 0100AAAA00000000 --out $T/x2 > /dev/null 2>&1 ) &
  ( FAKE_NX_FAIL=1 U extract --src $T/src --title-id 0100AAAA00000000 --out $T/x3 > $T/A3.x3.out 2>&1; echo $? > $T/A3.x3.rc ) &
  ( o=$(U extract --src $T/no-such --out $T/x4 2>&1); r=$?; printf '%s\n' "$o" > $T/A3.x4.out; echo $r > $T/A3.x4.rc ) &
  ( o=$(U extract --src $T/src --title-id 0100AAAA00000000 --out $T/xbusy 2>&1); r=$?; printf '%s\n' "$o" > $T/A3.busy.out; echo $r > $T/A3.busy.rc ) &
  wait
  ck "解包③ base.nsp 变一个字节 → 键变（${k1} → $(cat $T/x2/.stage_unpack 2> /dev/null)）" '[ "$(cat $T/x2/.stage_unpack 2> /dev/null)" != "$k1" ]'
  o=$(cat $T/A3.x3.out); r=$(cat $T/A3.x3.rc)
  ck "解包④ 解包失败 → 退出非 0、不留 ${T}/x3、不留 .tmp（rc=${r}）" '[ $r != 0 ] && [ ! -e $T/x3 ] && [ -z "$(ls -d $T/x3.tmp.* 2> /dev/null)" ] && [[ "$o" == *【红】* ]]'
  o=$(cat $T/A3.x4.out); r=$(cat $T/A3.x4.rc)
  ck "解包④ 源目录不存在 → 退出非 0、不建 ${T}/x4（rc=${r}）" '[ $r != 0 ] && [ ! -e $T/x4 ]'
  o=$(cat $T/A3.busy.out); r=$(cat $T/A3.busy.rc)
  ck "解包④ 输出目录已存在且键不同、没给 --force → 拒绝（rc=${r}）、旧目录不动" '[ $r != 0 ] && [[ "$o" == *--force* ]] && [ "$(cat $T/xbusy/.stage_unpack)" = bogus ]'
  # 探测失败不进程序号缓存（10-26 gate-host 偶发红的根因）：换 mtime 后先失败一次，再正常解应认得出程序号；旧 srcs.sh 记「-」，第二次报没有这个程序号
  touch -t 202601030303 $T/src/base.nsp
  o=$(FAKE_NX_FAIL=1 U inspect --src $T/src 2>&1); r=$?
  # 退出 1 = nx_unpack 按内容下的结论（真 nx_unpack 对单独的更新 / DLC 包 --nacp-only 就回 1「基础程序应恰好 1 个，实际 0」）：照旧记「-」、不报机器原因
  ck "解包④ 探测退出 1（按内容的结论）→ inspect 照列（rc=${r}）、base.nsp 记 -、不报机器原因" '[ $r = 0 ] && [ "$(printf "%s\n" "$o" | awk -F"\t" "\$1 ~ /base.nsp$/ {print \$4}")" = - ] && [[ "$o" != *机器原因* ]]'
  FAKE_NX_FAIL=1 U extract --src $T/src --title-id 0100AAAA00000000 --out $T/x5f > /dev/null 2>&1
  # 探测出错 ≠ 没有程序号（11-05 after_r2 v4：没 .NET 运行时探测全回 131，15 款被记成游戏「失败 解包」）：期望按假 nx_unpack 手写——
  #   --nacp-only 在 FAKE_PROBE_RC=131 下 stderr「假：You must install .NET…」、退出 131 → 一行「机器原因：原件探测出错（…退出 131…）：假：You must…（…base.nsp）」，不出「没有程序号」
  touch -t 202601030304 $T/src/base.nsp
  o=$(FAKE_PROBE_RC=131 U extract --src $T/src --title-id 0100AAAA00000000 --out $T/x5g 2>&1); r=$?
  ck "解包④ 工具没跑成（退出 131）→ 退出非 0（rc=${r}）、报机器原因带 nx_unpack 原话与文件、不判没有程序号" \
     '[ $r != 0 ] && [[ "$o" == *"【红】机器原因：原件探测出错（nx_unpack --nacp-only 退出 131"*"You must install .NET"*"base.nsp）"* ]] && [[ "$o" != *没有程序号* ]] && [ ! -e $T/x5g ]'
  o=$(U extract --src $T/src --title-id 0100AAAA00000000 --out $T/x5 2>&1); r=$?
  ck "解包④ 探测失败不进缓存：失败一次后再解照样认出程序号（rc=${r}）" '[ $r = 0 ] && [ -f $T/x5/exefs/main ]'
  # ⑥ .NET 运行时由 pack/srcs.sh 入口自己补（11-05 after_r2 v4 由 launchctl submit 起、环境只有系统 PATH，nx_unpack 启动壳 rc=131）：期望按规则手写——
  #   干净环境（env -i，PATH 只有 /usr/bin:/bin）、家目录下 .dotnet/dotnet + .dotnet/host/fxr → DOTNET_ROOT = <家>/.dotnet、PATH 上的 dotnet 就是它；
  #   已设 DOTNET_ROOT → 原样不动；.dotnet 里没有 host/fxr（不是运行时根）→ 不设
  mkdir -p $T/dnh/.dotnet/host/fxr $T/dnh2/.dotnet; printf '#!/bin/sh\n' > $T/dnh/.dotnet/dotnet; cp $T/dnh/.dotnet/dotnet $T/dnh2/.dotnet/dotnet; chmod +x $T/dnh/.dotnet/dotnet $T/dnh2/.dotnet/dotnet
  dn() { env -i HOME="$1" PATH=/usr/bin:/bin ${2:+DOTNET_ROOT=$2} S2A_NX_UNPACK=/bin/true bash -c 'source "$0/pack/srcs.sh"; printf "%s|%s" "${DOTNET_ROOT:-}" "$(command -v dotnet)"' "$R"; }
  ck "解包⑥ .NET 入口自补：干净环境 → $(dn $T/dnh)；已设不动 → $(dn $T/dnh /preset)；没有 host/fxr 不设 → $(dn $T/dnh2)" \
     '[ "$(dn $T/dnh)" = "$T/dnh/.dotnet|$T/dnh/.dotnet/dotnet" ] && [ "$(dn $T/dnh /preset)" = "/preset|" ] && [ "$(dn $T/dnh2)" = "|" ]'
  # ⑤ 全机解包缓存（11-02 维护者：解包结果共用）：手算期望——第一次（缓存空）调 1 次 nx_unpack、缓存里出现 <程序号>-<键>/；
  #   第二次换一个输出目录 → 不调 nx_unpack（调用记录仍 1 行）、打「缓存命中」、产物与第一次逐字节一致；缓存目录写不了 → 照样解完、只打黄
  : > $T/nxlog5
  FAKE_NX_LOG=$T/nxlog5 S2A_UNPACK_CACHE=$T/uc U extract --src $T/src --title-id 0100AAAA00000000 --out $T/x6 > $T/x6.out 2>&1; r=$?
  k6=$(cat $T/x6/.stage_unpack 2> /dev/null); n1=$(grep -c "^EXTRACT" $T/nxlog5)
  o=$(FAKE_NX_LOG=$T/nxlog5 S2A_UNPACK_CACHE=$T/uc U extract --src $T/src --title-id 0100AAAA00000000 --out $T/x7 2>&1); r2=$?
  ck "解包⑤ 缓存：首次解（rc=${r}，nx_unpack ${n1} 次）存进 uc/0100AAAA00000000-<内容键>；再解另一目录命中（rc=${r2}，nx_unpack 累计 $(grep -c "^EXTRACT" $T/nxlog5) 次）、产物一致" \
     '[ $r = 0 ] && [ $r2 = 0 ] && [ "$n1" = 1 ] && [ -f "$(ls -d $T/uc/0100AAAA00000000-*/ | head -1)exefs/main" ] && [ "$(grep -c "^EXTRACT" $T/nxlog5)" = 1 ] && [[ "$o" == *缓存命中* ]] && same_tree $T/x6 $T/x7 && [ -z "$(ls -d $T/uc/*.tmp.* 2> /dev/null)" ]'
  # 同一份原件换个目录、修改时间不同（普查拷到暂存目录 / 出包队列软链；假 nx_unpack 按文件名认程序号，文件名不换）→ 仍命中（缓存键只看内容）；原件变一个字节 → 不命中、重解
  mkdir -p $T/srcB; for f in $T/src/*.nsp; do cp "$f" "$T/srcB/"; done; touch -t 202601040404 $T/srcB/*.nsp
  o=$(FAKE_NX_LOG=$T/nxlog5 S2A_UNPACK_CACHE=$T/uc U extract --src $T/srcB --title-id 0100AAAA00000000 --out $T/x9 2>&1); r=$?
  ck "解包⑤ 换目录 / 修改时间的同一份原件 → 命中（rc=${r}，nx_unpack 累计 $(grep -c "^EXTRACT" $T/nxlog5) 次）" '[ $r = 0 ] && [[ "$o" == *缓存命中* ]] && [ "$(grep -c "^EXTRACT" $T/nxlog5)" = 1 ] && same_tree $T/x6/exefs $T/x9/exefs'
  printf 'x' >> $T/srcB/base.nsp; o=$(FAKE_NX_LOG=$T/nxlog5 S2A_UNPACK_CACHE=$T/uc U extract --src $T/srcB --title-id 0100AAAA00000000 --out $T/x10 2>&1); r=$?
  ck "解包⑤ 原件变一个字节 → 不命中、重解（rc=${r}，nx_unpack 累计 $(grep -c "^EXTRACT" $T/nxlog5) 次）" '[ $r = 0 ] && [[ "$o" != *缓存命中* ]] && [ "$(grep -c "^EXTRACT" $T/nxlog5)" = 2 ]'
  : > $T/ucro; o=$(S2A_UNPACK_CACHE=$T/ucro/sub U extract --src $T/src --title-id 0100AAAA00000000 --out $T/x8 2>&1); r=$?
  ck "解包⑤ 缓存目录建不了 → 照样解完（rc=${r}）、打黄不挡" '[ $r = 0 ] && [ -f $T/x8/exefs/main ] && [[ "$o" == *没存进缓存* ]]'
}
U() { env S2A_NX_UNPACK=$R/fake/nx_unpack S2A_SRC_IDS=$T/ids.tsv S2A_KEYS=$T/keys S2A_UNPACK_CACHE=${S2A_UNPACK_CACHE:-off} bash $R/pack/stages/unpack.sh "$@"; }   # 缺省关全机解包缓存：不往本机真缓存写夹具

# ── B. 系统数据 ────────────────────────────────────────────────────────────────
sec_sysdata() {
  local r1 r2 o1 o2 r3 o3 r5 o5 bs
  # 共享阶段之间只共享 $S2A_ROOTS 的「按款」目录：不同款的 root_begin / commit 互不冲突，可以并行跑。
  mksys s1; mksys s2; mksys s4; mksys s5
  # 四个款互不依赖，一轮全跑：s1 旧入口（顺带判跳过）、s2 共享入口、s4 换字体、s5 缺字体（早退）。
  # 每个阶段的 root_begin / commit 都要整棵克隆 + 提交，能并一轮就并一轮（墙钟）。
  cp -R $T/fonts $T/fonts2; printf 'x' >> $T/fonts2/a.bfttf
  ( S2A_SYSDATA_NEED=$T/need.tsv bash $R/pack/stage_sysdata.sh s1 > $T/s1.out 2>&1; echo $? > $T/s1.rc ) &
  ( S2A_SYSDATA_NEED=$T/need.tsv bash $R/pack/stages/sysdata.sh s2 > $T/s2.out 2>&1; echo $? > $T/s2.rc ) &
  ( S2A_FONTS=$T/fonts2 S2A_SYSDATA_NEED=$T/need.tsv bash $R/pack/stages/sysdata.sh s4 > $T/s4.out 2>&1; echo $? > $T/s4.rc ) &
  ( S2A_FONTS=$T/no-fonts S2A_SYSDATA_NEED=$T/need.tsv bash $R/pack/stages/sysdata.sh s5 > $T/s5.out 2>&1; echo $? > $T/s5.rc ) &
  wait
  r1=$(cat $T/s1.rc); r2=$(cat $T/s2.rc); o1=$(cat $T/s1.out); o2=$(cat $T/s2.out)
  ck "系统数据① 旧入口 / 共享入口都成功（rc=${r1}/${r2}）" '[ $r1 = 0 ] && [ $r2 = 0 ]'
  ck "系统数据① 产物 systemdata/ 逐字节一致、版本标签一致（$(tagof "$(cur s1)")）" 'same_tree "$(cur s1)/systemdata" "$(cur s2)/systemdata" && [ "$(tagof "$(cur s1)")" = "$(tagof "$(cur s2)")" ]'
  ck "系统数据① 字体 / 时区 / 玩家目录的 0801 都在、来源不动" '[ -f "$(cur s1)/systemdata/fonts/a.bfttf" ] && [ -f "$(cur s1)/systemdata/010000000000080E/binaryList.txt" ] && [ "$(cat "$(cur s1)/systemdata/0100000000000801/version.dat")" = errmsg-v1 ]'
  # s1 再跑一次（换目标名 / ABI / 工具链）：键必须仍是 s1 已做过的那个 → 跳过、标签不变
  bs=$(basename "$(cur s1)")
  ( S2A_TARGET=android S2A_REWRITE_ABI=x CC=clang S2A_SYSDATA_NEED=$T/need.tsv bash $R/pack/stages/sysdata.sh s1 > $T/s3.out 2>&1; echo $? > $T/s3.rc ) &
  wait
  r3=$(cat $T/s3.rc); o3=$(cat $T/s3.out); r5=$(cat $T/s5.rc); o5=$(cat $T/s5.out)
  ck "系统数据② 换目标名 / ABI / 工具链 → 仍判已齐、标签不变（rc=${r3}）" '[ $r3 = 0 ] && [[ "$o3" == *跳过* ]] && [ "$(basename "$(cur s1)")" = "$bs" ]'
  ck "系统数据③ 字体变一个字节 → 标签变（$(tagof "$(cur s1)") → $(tagof "$(cur s4)")）" '[ "$(tagof "$(cur s4)")" != "$(tagof "$(cur s1)")" ]'
  ck "系统数据④ 缺字体目录 → 退出非 0、现行不动（rc=${r5}）" '[ $r5 != 0 ] && [ "$(basename "$(cur s5)")" = s5@s0 ] && [[ "$o5" == *【红】* ]]'
  ck "系统数据① 产物相对路径不含目标名" 'no_target_path "$(cur s1)"'
}

# ── C. RomFS 索引 ─────────────────────────────────────────────────────────────
sec_romfsidx() {
  local r1c r2c k1 b6 r3c o3 r5c o r o6
  mkroot r1 same r1; mkroot r2 same r1; mkroot r4 same r1; mkroot r5 same r1
  mkdir -p $T/roots/r1@s0/romfs/data; printf 'b\n' > $T/roots/r1@s0/romfs/data/b.bin
  mkdir -p $T/roots/r2@s0/romfs/data; printf 'b\n' > $T/roots/r2@s0/romfs/data/b.bin
  mkdir -p $T/roots/r4@s0/romfs/data; printf 'b\n' > $T/roots/r4@s0/romfs/data/b.bin
  rm -rf $T/roots/r5@s0/romfs
  printf 'c\n' > $T/roots/r4@s0/romfs/c.txt   # r4 比 r1 多一个文件：键必须变
  mkroot r6 same r1; mkdir -p $T/roots/r6@s0/romfs/data; printf 'e\n' > $T/roots/r6@s0/romfs/e.txt
  b6=$(basename "$(cur r6)")
  # 界面布局覆盖层（pack/stage_uilayout.sh 写 ui_overlay/romfs/）：r7 旧形态就地改了 data/b.bin，r8 RomFS 原版 + 覆盖层里同一份改过的 b.bin → 读到的一样，索引与键都要一样；
  #   r9 覆盖层有 RomFS 没有的文件 → 报红（覆盖层只许替换）
  for g in r7 r8 r9; do mkroot $g same r1; mkdir -p $T/roots/$g@s0/romfs/data; printf 'b\n' > $T/roots/$g@s0/romfs/data/b.bin; done
  printf 'wide-b\n' > $T/roots/r7@s0/romfs/data/b.bin
  mkdir -p $T/roots/r8@s0/ui_overlay/romfs/data $T/roots/r9@s0/ui_overlay/romfs/data; printf 'wide-b\n' > $T/roots/r8@s0/ui_overlay/romfs/data/b.bin; printf 'x\n' > $T/roots/r9@s0/ui_overlay/romfs/data/new.bin
  # 五个款互不依赖，一轮全跑（r1 的「换环境变量 → 跳过」要等 r1 提交完，放第二轮）
  ( bash $R/pack/stage_romfsidx.sh r1 > $T/r1.out 2>&1; echo $? > $T/r1.rc ) &
  ( bash $R/pack/stages/romfsidx.sh r2 > $T/r2.out 2>&1; echo $? > $T/r2.rc ) &
  ( bash $R/pack/stages/romfsidx.sh r4 > $T/r4.out 2>&1; echo $? > $T/r4.rc ) &
  ( bash $R/pack/stages/romfsidx.sh r5 > $T/r5.out 2>&1; echo $? > $T/r5.rc ) &
  ( FAKE_RX_FAIL=1 bash $R/pack/stages/romfsidx.sh r6 > $T/r6.out 2>&1; echo $? > $T/r6.rc ) &
  for g in r7 r8 r9; do ( bash $R/pack/stages/romfsidx.sh $g > $T/$g.out 2>&1; echo $? > $T/$g.rc ) & done
  wait
  r1c=$(cat $T/r1.rc); r2c=$(cat $T/r2.rc)
  ck "RomFS 索引① 旧 / 共享入口都成功（rc=${r1c}/${r2c}）" '[ $r1c = 0 ] && [ $r2c = 0 ] && [ -s "$(cur r1)/romfs.s2aidx" ]'
  k1=$(cat "$(cur r1)/.stage_romfsidx")
  ck "RomFS 索引① 产物字节一致、键一致（${k1}）" 'cmp -s "$(cur r1)/romfs.s2aidx" "$(cur r2)/romfs.s2aidx" && [ "${k1}" = "$(cat "$(cur r2)/.stage_romfsidx")" ]'
  ( S2A_TARGET=android S2A_REWRITE_ABI=x CC=clang bash $R/pack/stages/romfsidx.sh r1 > $T/r3.out 2>&1; echo $? > $T/r3.rc ) &
  wait
  r3c=$(cat $T/r3.rc); o3=$(cat $T/r3.out); r5c=$(cat $T/r5.rc); o=$(cat $T/r5.out); r=$(cat $T/r6.rc); o6=$(cat $T/r6.out)
  ck "RomFS 索引② 换目标名 / ABI / 工具链 → 键不变、跳过（rc=${r3c}）" '[ $r3c = 0 ] && [[ "$o3" == *跳过* ]] && [ "${k1}" = "$(cat "$(cur r1)/.stage_romfsidx")" ]'
  ck "RomFS 索引③ romfs 多一个文件 → 键变（${k1} → $(cat "$(cur r4)/.stage_romfsidx")）" '[ "$(cat "$(cur r4)/.stage_romfsidx")" != "${k1}" ]'
  ck "RomFS 索引④ 没有 romfs/ → 退出非 0、现行不动（rc=${r5c}）" '[ $r5c != 0 ] && [ "$(basename "$(cur r5)")" = r5@s0 ] && [[ "$o" == *【红】* ]]'
  ck "RomFS 索引④ 生成失败 → 退出非 0、现行不动、不留 .tmp（rc=${r}）" '[ $r != 0 ] && [ "$(basename "$(cur r6)")" = "$b6" ] && [ -z "$(ls -d $T/roots/r6@*.tmp 2> /dev/null)" ] && [[ "$o6" == *【红】* ]]'
  ck "RomFS 索引① 产物相对路径不含目标名" 'no_target_path "$(cur r1)"'
  ck "RomFS 索引⑤ 覆盖层形态与就地改形态读到的一样 → 索引逐字节同、键同（rc=$(cat $T/r7.rc)/$(cat $T/r8.rc)，键 $(cat "$(cur r8)/.stage_romfsidx" 2> /dev/null)）" \
     '[ "$(cat $T/r7.rc)" = 0 ] && [ "$(cat $T/r8.rc)" = 0 ] && cmp -s "$(cur r7)/romfs.s2aidx" "$(cur r8)/romfs.s2aidx" && [ "$(cat "$(cur r7)/.stage_romfsidx")" = "$(cat "$(cur r8)/.stage_romfsidx")" ] && grep -q "^7	data/b.bin" "$(cur r8)/romfs.s2aidx"'
  ck "RomFS 索引⑤ 有覆盖层 → 键与没覆盖层的不同（$(cat "$(cur r8)/.stage_romfsidx" 2> /dev/null) / $(cat "$(cur r9)/.stage_romfsidx" 2> /dev/null)）" '[ "$(cat "$(cur r8)/.stage_romfsidx")" != "$(cat "$(cur r1)/.stage_romfsidx")" ]'
  ck "RomFS 索引⑤ 覆盖层有 RomFS 没有的文件 → 报红、退出非 0、现行不动（rc=$(cat $T/r9.rc)）" '[ "$(cat $T/r9.rc)" != 0 ] && [ "$(basename "$(cur r9)")" = r9@s0 ] && [[ "$(cat $T/r9.out)" == *只许替换* ]]'
}

# ── E. 元数据（nacp）──────────────────────────────────────────────────────────
sec_nacp() {
  local E="env S2A_NX_UNPACK=$R/fake/nx_unpack S2A_KEYS=$T/keys"   # 两个入口都只认这两个环境变量
  local r1 r2 r3 o3 r4 r5 o5 r6 r7 b1
  mknacp p1; mknacp p2; mknacp p4; mknacp p5; mknacp p7; mknacp p8; mknacp p9
  mkdir -p $T/noxxd && printf '#!/bin/sh\nexit 127\n' > $T/noxxd/xxd && chmod +x $T/noxxd/xxd   # P2-278：玩家机没装 xxd
  head -c 66 "$(cur p9)/exefs/main" > $T/p9main && mv $T/p9main "$(cur p9)/exefs/main"          # 构建号只有 2 字节
  mkdir -p $T/roots/p6@s0 && printf '%s\n' p6@s0 > $T/roots/p6@现行   # p6 没有 exefs/main
  # p1 旧入口 / p2 共享入口（同款不同名、同一份输入）→ 产物与标签必须一致
  ( $E bash $R/pack/stage_nacp.sh p1 $T/src/base.nsp > $T/p1.out 2>&1; echo $? > $T/p1.rc ) &
  ( $E bash $R/pack/stages/nacp.sh p2 $T/src/base.nsp > $T/p2.out 2>&1; echo $? > $T/p2.rc ) &
  ( $E bash $R/pack/stages/nacp.sh p4 $T/src/other.nsp > $T/p4.out 2>&1; echo $? > $T/p4.rc ) &
  ( $E FAKE_NX_FAIL=1 bash $R/pack/stages/nacp.sh p5 $T/src/base.nsp > $T/p5.out 2>&1; echo $? > $T/p5.rc ) &
  ( $E bash $R/pack/stages/nacp.sh p6 $T/src/base.nsp > $T/p6.out 2>&1; echo $? > $T/p6.rc ) &
  ( $E bash $R/pack/stages/nacp.sh p7 > $T/p7.out 2>&1; echo $? > $T/p7.rc ) &
  ( $E PATH=$T/noxxd:$PATH bash $R/pack/stages/nacp.sh p8 $T/src/base.nsp > $T/p8.out 2>&1; echo $? > $T/p8.rc ) &
  ( $E bash $R/pack/stages/nacp.sh p9 $T/src/base.nsp > $T/p9.out 2>&1; echo $? > $T/p9.rc ) &
  wait
  r1=$(cat $T/p1.rc); r2=$(cat $T/p2.rc)
  ck "元数据① 旧 / 共享入口都成功（rc=${r1}/${r2}）" '[ $r1 = 0 ] && [ $r2 = 0 ] && [ -s "$(cur p1)/ctl/control.nacp" ]'
  ck "元数据① control.nacp 逐字节一致、标签都是 nacp-<构建号>（$(tagof "$(cur p1)")）" \
     'cmp -s "$(cur p1)/ctl/control.nacp" "$(cur p2)/ctl/control.nacp" && [ "$(tagof "$(cur p1)")" = "nacp-11223344" ] && [ "$(tagof "$(cur p1)")" = "$(tagof "$(cur p2)")" ]'
  ck "元数据③ 换一个包 → 抽出的元数据不同（另一个程序号）" '! cmp -s "$(cur p1)/ctl/control.nacp" "$(cur p4)/ctl/control.nacp"'
  b1=$(basename "$(cur p1)")
  ( $E bash $R/pack/stages/nacp.sh p1 $T/src/base.nsp > $T/p3.out 2>&1; echo $? > $T/p3.rc ) &
  ( $E S2A_TARGET=android S2A_REWRITE_ABI=x CC=clang bash $R/pack/stages/nacp.sh p1 $T/src/base.nsp > $T/p3b.out 2>&1 ) &
  wait
  r3=$(cat $T/p3.rc); o3=$(cat $T/p3.out)
  ck "元数据① 同一款再跑 → 已有 control.nacp 跳过（rc=${r3}，现行仍是 $(basename "$(cur p1)")）" '[ $r3 = 0 ] && [[ "$o3" == *跳过* ]] && [ "$(basename "$(cur p1)")" = "$b1" ]'
  ck "元数据② 换目标名 / ABI / 工具链 → 结论不变、标签不变" '[ "$(basename "$(cur p1)")" = "$b1" ] && [ "$(tagof "$(cur p1)")" = "nacp-11223344" ]'
  r4=$(cat $T/p4.rc)
  ck "元数据④ 包内容不同 → 产物不同（rc=${r4}）" '[ $r4 = 0 ] && ! cmp -s "$(cur p1)/ctl/control.nacp" "$(cur p4)/ctl/control.nacp"'
  r5=$(cat $T/p5.rc); o5=$(cat $T/p5.out); r6=$(cat $T/p6.rc); r7=$(cat $T/p7.rc)
  ck "元数据④ 抽不出 → 退出非 0、现行不动、不留 .tmp（rc=${r5}）" '[ $r5 != 0 ] && [ "$(basename "$(cur p5)")" = p5@s0 ] && [ -z "$(ls -d $T/roots/p5@*.tmp 2> /dev/null)" ] && [[ "$o5" == *【红】* ]]'
  ck "元数据④ 现行没有 exefs/main → 退出非 0（rc=${r6}）、现行不动" '[ $r6 != 0 ] && [ "$(basename "$(cur p6)")" = p6@s0 ] && [ ! -e "$(cur p6)/ctl" ]'
  ck "元数据④ 没给 xci / nsp → 退出非 0（rc=${r7}）" '[ $r7 != 0 ] && [ ! -e "$(cur p7)/ctl" ]'
  local r8 r9; r8=$(cat $T/p8.rc); r9=$(cat $T/p9.rc)
  ck "元数据⑤ 没装 xxd → 照常成功、标签仍是 nacp-11223344（rc=${r8}，$(tagof "$(cur p8)")）" '[ $r8 = 0 ] && [ "$(tagof "$(cur p8)")" = "nacp-11223344" ]'
  ck "元数据⑤ exefs/main 短到读不出 4 字节构建号 → 退出非 0、报红、现行不动（rc=${r9}）" '[ $r9 != 0 ] && [ "$(basename "$(cur p9)")" = p9@s0 ] && grep -q 【红】 $T/p9.out'
  ck "元数据① 产物相对路径不含目标名" 'no_target_path "$(cur p1)"'
}

# ── F. 追加内容（aoc）─────────────────────────────────────────────────────────
sec_aoc() {
  local r1 r2 k1 r3 o3 r4 r5 o5 r6 r7 o7 r8 b1 r9 o9 r10 o10
  mksys a1; mksys a2; mksys a3; mksys a4; mksys a5; mksys a7
  mkdir -p $T/roots/a6@s0 && printf '%s\n' a6@s0 > $T/roots/a6@现行   # a6 没有 exefs/main
  mkdir -p $T/games $T/nogames
  for f in base dlc other; do printf '%s' "$f" > $T/games/$f.nsp; done
  touch -t 202601010101 $T/games/*.nsp
  export S2A_AOC_CACHE=$T/aoccache S2A_KEYS=$T/keys
  : > $T/aoclog
  # a1 旧入口 / a2 共享入口：同一份输入，产物与键必须一致；a4 解不出 / a5 本机没原始包 / a6 没有 exefs/main
  ( FAKE_NX_LOG=$T/aoclog S2A_NX_UNPACK=$R/fake/nx_unpack S2A_GAME_SRC=$T/games S2A_SRC_IDS=$T/id1.tsv bash $R/pack/stage_aoc.sh a1 > $T/a1.out 2>&1; echo $? > $T/a1.rc ) &
  ( S2A_NX_UNPACK=$R/fake/nx_unpack S2A_GAME_SRC=$T/games S2A_SRC_IDS=$T/id2.tsv bash $R/pack/stages/aoc.sh a2 > $T/a2.out 2>&1; echo $? > $T/a2.rc ) &
  ( FAKE_AOC_FAIL=1 S2A_NX_UNPACK=$R/fake/nx_unpack S2A_GAME_SRC=$T/games S2A_SRC_IDS=$T/id4.tsv bash $R/pack/stages/aoc.sh a4 > $T/a4.out 2>&1; echo $? > $T/a4.rc ) &
  ( FAKE_PROBE_RC=131 S2A_NX_UNPACK=$R/fake/nx_unpack S2A_GAME_SRC=$T/games S2A_SRC_IDS=$T/id7.tsv bash $R/pack/stages/aoc.sh a7 > $T/a7.out 2>&1; echo $? > $T/a7.rc ) &
  ( S2A_NX_UNPACK=$R/fake/nx_unpack S2A_GAME_SRC=$T/nogames S2A_SRC_IDS=$T/id5.tsv bash $R/pack/stages/aoc.sh a5 > $T/a5.out 2>&1; echo $? > $T/a5.rc ) &
  ( S2A_NX_UNPACK=$R/fake/nx_unpack S2A_GAME_SRC=$T/games S2A_SRC_IDS=$T/id6.tsv bash $R/pack/stages/aoc.sh a6 > $T/a6.out 2>&1; echo $? > $T/a6.rc ) &
  wait
  r1=$(cat $T/a1.rc); r2=$(cat $T/a2.rc)
  ck "追加内容① 旧 / 共享入口都成功（rc=${r1}/${r2}）" '[ $r1 = 0 ] && [ $r2 = 0 ] && [ -s "$(cur a1)/aoc.tsv" ]'
  k1=$(cat "$(cur a1)/.stage_aoc" 2> /dev/null)
  ck "追加内容① aoc/ 逐字节一致、清单一致、键一致（${k1}）、标签一致（$(tagof "$(cur a1)")）" \
     'same_tree "$(cur a1)/aoc" "$(cur a2)/aoc" && cmp -s "$(cur a1)/aoc.tsv" "$(cur a2)/aoc.tsv" && [ ${#k1} = 16 ] && [ "${k1}" = "$(cat "$(cur a2)/.stage_aoc")" ] && [ "$(tagof "$(cur a1)")" = "$(tagof "$(cur a2)")" ]'
  ck "追加内容① 按内容选包：只给程序号对上的 + 读不出程序号的包（base / dlc，不含 other）" \
     'grep -q "base.nsp" $T/aoclog && grep -q "dlc.nsp" $T/aoclog && ! grep -q "other.nsp" $T/aoclog'
  ck "追加内容① 产物相对路径不含目标名" 'no_target_path "$(cur a1)"'
  b1=$(basename "$(cur a1)")
  # 第二轮（并行）：同款再跑（键相同 → 跳过）+ 换目标名 / ABI / 工具链（键必须不变）
  ( S2A_NX_UNPACK=$R/fake/nx_unpack S2A_GAME_SRC=$T/games S2A_SRC_IDS=$T/id1.tsv bash $R/pack/stages/aoc.sh a1 > $T/a3.out 2>&1; echo $? > $T/a3.rc ) &
  ( S2A_TARGET=android S2A_REWRITE_ABI=x CC=clang S2A_NX_UNPACK=$R/fake/nx_unpack S2A_GAME_SRC=$T/games S2A_SRC_IDS=$T/id1.tsv bash $R/pack/stages/aoc.sh a1 > $T/a3b.out 2>&1 ) &
  wait
  r3=$(cat $T/a3.rc); o3=$(cat $T/a3.out)
  ck "追加内容① 同一输入再跑 → 键相同、跳过（rc=${r3}）" '[ $r3 = 0 ] && [[ "$o3" == *跳过* ]] && [ "${k1}" = "$(cat "$(cur a1)/.stage_aoc")" ]'
  ck "追加内容② 换目标名 / ABI / 工具链 → 键不变、跳过、标签不变（$(basename "$(cur a1)")）" '[ "${k1}" = "$(cat "$(cur a1)/.stage_aoc")" ] && [ "$(basename "$(cur a1)")" = "$b1" ]'
  # ⑤ 同一份工具换到另一个目录（内容相同、路径不同）→ 键不变、跳过、不新增缓存（键里不许有工具路径）
  mkdir -p $T/fake2 && cp $R/fake/nx_unpack $R/fake/nx_unpack.dll $T/fake2/; : > $T/aoclog
  S2A_NX_UNPACK=$T/fake2/nx_unpack S2A_GAME_SRC=$T/games S2A_SRC_IDS=$T/id1.tsv bash $R/pack/stages/aoc.sh a1 > $T/a5b.out 2>&1; r5b=$?
  o5b=$(cat $T/a5b.out)
  ck "追加内容⑤ 工具换目录、内容不变 → 键不变、跳过（rc=${r5b}，缓存 $(ls $T/aoccache 2> /dev/null | tr '\n' ' ')）" '[ $r5b = 0 ] && [[ "$o5b" == *跳过* ]] && [ "${k1}" = "$(cat "$(cur a1)/.stage_aoc")" ] && [ "$(ls -d $T/aoccache/a1-* 2> /dev/null | wc -l | tr -d " ")" = 1 ] && [ ! -s $T/aoclog ]'
  r4=$(cat $T/a4.rc); o5=$(cat $T/a5.out); r5=$(cat $T/a5.rc); r6=$(cat $T/a6.rc)
  # 认包照常、只追加内容解不出（FAKE_AOC_FAIL）：按审计 P2-30 逐份兜底，全坏 → 仍退 0、不写追加内容与键（同 追加内容缺②）。
  #   原先这项用 FAKE_NX_FAIL（认包探测也挂），其实走的是「没有程序号 → 黄字跳过」那条路，11-05 起探测出错改报红，另立 a7
  ck "追加内容④ 解不出 → 不拦出包（rc=${r4}）、没有追加内容与清单、不记键、不留缓存 .tmp" '[ $r4 = 0 ] && [ ! -e "$(cur a4)/.stage_aoc" ] && [ -z "$(ls -d $T/aoccache/*.tmp.* 2> /dev/null)" ] && [ ! -e "$(cur a4)/aoc.tsv" ] && [ ! -e "$(cur a4)/aoc" ]'
  o7=$(cat $T/a7.out); r7=$(cat $T/a7.rc)
  ck "追加内容④ 认包探测出错 → 报红停（rc=${r7}）、不当没有程序号跳过、现行不动" '[ $r7 != 0 ] && [[ "$o7" == *"机器原因：原件探测出错"* ]] && [[ "$o7" == *追加内容阶段停* ]] && [[ "$o7" != *没有程序号* ]] && [ "$(basename "$(cur a7)")" = a7@s0 ]'
  ck "追加内容④ 本机没原始包 → 黄、跳过（rc=${r5}）、现行不动" '[ $r5 = 0 ] && [[ "$o5" == *🟡* ]] && [ "$(basename "$(cur a5)")" = a5@s0 ]'
  ck "追加内容④ 现行没有 exefs/main → 退出非 0（rc=${r6}）" '[ $r6 != 0 ]'
  # 第三轮：原始包变一个字节 → 键必须变（缓存目录也跟着变）
  printf 'x' >> $T/games/base.nsp; touch -t 202601020202 $T/games/base.nsp
  ( S2A_NX_UNPACK=$R/fake/nx_unpack S2A_GAME_SRC=$T/games S2A_SRC_IDS=$T/id3.tsv bash $R/pack/stages/aoc.sh a3 > $T/a3c.out 2>&1; echo $? > $T/a3c.rc ) &
  wait
  r7=$(cat $T/a3c.rc)
  ck "追加内容③ 原始包变一个字节 → 键变（${k1} → $(cat "$(cur a3)/.stage_aoc" 2> /dev/null)）" '[ $r7 = 0 ] && [ "$(cat "$(cur a3)/.stage_aoc" 2> /dev/null)" != "${k1}" ]'
  ck "追加内容③ 缓存按新键另存一份（$(ls $T/aoccache 2> /dev/null | tr '\n' ' ')）" '[ -n "$(ls -d $T/aoccache/a3-* 2> /dev/null)" ]'
}

# 审计 P2-30：追加内容整份解不出时逐份兜底。三份纯 DLC 包第二份坏 → 另两份进产物根、坏的那份点名（aoc.log 一行「追加内容缺<TAB>dlc2.nsp<TAB>原因」）；
#   三份都坏 → 仍退 0、本体不拦、现行追加内容不动（不写 .stage_aoc，下次刷新再试），aoc.log 三行缺；出包完成行后缀（pack/roots.sh root_aoc_note）点名
sec_aocmiss() {
  local r1 r2 o1 o2 c1 c2
  mksys m1; mksys m2; mkdir -p $T/gm; for f in base dlc1 dlc2 dlc3; do printf '%s' "$f" > $T/gm/$f.nsp; done; touch -t 202601010101 $T/gm/*.nsp
  o1=$(FAKE_AOC_BAD=dlc2.nsp S2A_AOC_CACHE=$T/aocm S2A_KEYS=$T/keys S2A_NX_UNPACK=$R/fake/nx_unpack S2A_GAME_SRC=$T/gm S2A_SRC_IDS=$T/idm1.tsv bash $R/pack/stages/aoc.sh m1 2>&1); r1=$?
  c1=$(cur m1)
  ck "追加内容缺① 第二份坏：rc=${r1}、序号 1 / 3 在、2 不在、清单 $(tail -n +2 "$c1/aoc.tsv" 2> /dev/null | cut -f1 | tr '\n' ' ')" \
     '[ $r1 = 0 ] && [ -s "$c1/aoc/1/x.bin" ] && [ -s "$c1/aoc/3/x.bin" ] && [ ! -e "$c1/aoc/2" ] && [ "$(tail -n +2 "$c1/aoc.tsv" | cut -f1 | tr "\n" " ")" = "1 3 " ] && [ -s "$c1/.stage_aoc" ]'
  ck "追加内容缺① aoc.log 固定格式一行点名 dlc2.nsp、原因取它的日志末行；输出点名" \
     '[ "$(grep -a "^追加内容缺	" "$c1/aoc.log")" = "追加内容缺	dlc2.nsp	🔴 假：dlc2.nsp 数据分区解不开" ] && [[ "$o1" == *"追加内容 dlc2.nsp 未能解出"* ]]'
  ck "追加内容缺① 完成行后缀：$(bash -c 'source "$1/pack/roots.sh"; root_aoc_note "$2"' _ "$R" "$c1")" \
     '[ "$(bash -c "source \"\$1/pack/roots.sh\"; root_aoc_note \"\$2\"" _ "$R" "$c1")" = "；🟡 追加内容 dlc2.nsp 未能解出，包内不含" ]'
  ck "追加内容缺① 有缺的结果不进共享缓存、不留 .tmp" '[ -z "$(ls -A $T/aocm 2> /dev/null)" ]'
  o2=$(FAKE_AOC_BAD=dlc1.nsp,dlc2.nsp,dlc3.nsp S2A_AOC_CACHE=$T/aocm S2A_KEYS=$T/keys S2A_NX_UNPACK=$R/fake/nx_unpack S2A_GAME_SRC=$T/gm S2A_SRC_IDS=$T/idm2.tsv bash $R/pack/stages/aoc.sh m2 2>&1); r2=$?
  c2=$(cur m2)
  ck "追加内容缺② 三份都坏：rc=${r2}（不拦本体）、没有 aoc/ 与清单、不记键、aoc.log 三行缺" \
     '[ $r2 = 0 ] && [ ! -e "$c2/aoc" ] && [ ! -e "$c2/aoc.tsv" ] && [ ! -e "$c2/.stage_aoc" ] && [ "$(grep -ac "^追加内容缺	dlc[123].nsp	" "$c2/aoc.log")" = 3 ]'
}

# 各组并行：每组把自己的输出与「断言数 / 是否红」写到 $T/log/<组>，最后按固定顺序汇总打印（子 shell 里的计数要带出来）。
mkdir -p $T/log
for s in unpack sysdata romfsidx nacp aoc aocmiss; do
  ( "sec_$s"; printf '%s\t%s\n' "$n" "$bad" > "$T/log/$s.cnt" ) > "$T/log/$s.out" 2>&1 &
done
wait
n=0; bad=0
for s in unpack sysdata romfsidx nacp aoc aocmiss; do
  cat "$T/log/$s.out"
  if [ -f "$T/log/$s.cnt" ]; then
    read -r a b < "$T/log/$s.cnt"; n=$((n + a)); [ "$b" = 0 ] || bad=1
  else echo "不通 ${s} 组没跑完（中途退出，见上）"; bad=1; fi
done

chmod -R u+w $T; rm -rf $T
[ $bad = 0 ] && echo "pack_stages 单测全过（${n} 项）" || { echo "pack_stages 单测有不通"; exit 1; }
