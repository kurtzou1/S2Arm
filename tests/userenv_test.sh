#!/bin/bash
# 用户机口径冒烟（10-25 启动器在用户机上出 iPhone 包从没成功过：作业 PATH 只有 App 自带 Runtime + /usr/bin:/bin，没有 Homebrew，/bin/bash 是 3.2，
#   私有目录 ~/Library/Application Support 带空格；维护机有 Homebrew、路径不带空格，门禁全绿、用户机挂）：bash tests/userenv_test.sh（约 15 秒）
# 期望（按规则手写）：
#   ① 出包链脚本（pack、services、graphics/tools、graphics/nvn/tools）里 command -v 声明要的每个命令，用户机都有：App 运行环境自带
#      （launchers/macos/bundle_runtime.py 的 TOOLS：拷进 Runtime/bin 的那张表，加 Runtime/python/bin 的 python3、作业指定的 .NET SDK dotnet），或系统自带（/usr/bin、/bin、/usr/sbin、/sbin）
#   ② 运行环境表里有 bash，按启动器作业的 PATH（pack/jobs/core.py：Runtime/python/bin、Runtime/bin、/usr/bin、/bin…）找到的 bash 是 5 以上
#   ③ 引擎、输出、Runtime 全在「带 空格 中文」目录，env -i 只给启动器作业那套 PATH：一键出包（播种 / 刷新 / 出包换成桩）rc=0、出了 IPA，
#      输出里没有「command not found」「unbound variable」
#   ⑤ 改写入口（10-26 #420 C 改写器缺省、不回退先合，#425 App 自带改写器没同批，用户机没有 cmake，出包全红）：按启动器作业真实环境（pack/jobs/core.py Context.env，
#      Runtime 仿 App 自带 s2a-rewrite + .source 源码指纹）、HOME 换成空目录（没有共享依赖）、PATH 里没有 cmake，pack/rewriter.py c-path 选中 Runtime/bin/s2a-rewrite、rc=0
#   ⑥ 对照：同一环境不带自带二进制（即只有 #420 时的用户机）→ 报【红】改写器（缺固定依赖 / CMake；证明 ⑤ 的环境真没有、测得到这类依赖缺口）
# 门禁覆盖：pack/*.sh services/*.sh graphics/tools/*.sh graphics/nvn/tools/*.sh launchers/macos/bundle_runtime.py pack/jobs/core.py pack/rewriter.py runtime/rewriter/*
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
SHIP=$(python3 - "$H/launchers/macos/bundle_runtime.py" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r"^TOOLS = \[(.*?)\]$", s, re.M)
print(" ".join(n for _, n in re.findall(r"\('([^']+)','([^']+)'\)", m.group(1))) if m else "")
PY
)
miss=$(cd "$H" && python3 - "$SHIP" <<'PY'
import os, re, subprocess, sys
ok = set(sys.argv[1].split()) | {"python3", "dotnet"}
files = [f for f in subprocess.run(["git", "ls-files", "pack", "services", "graphics/tools", "graphics/nvn/tools"], capture_output=True, text=True, check=True).stdout.split("\n")
         if re.search(r"(\.sh|\.mk|Makefile)$", f) and not re.search(r"/tests?/", f)]
need = {}
print(f"扫 {len(files)} 个脚本；", end="")
for f in files:
    for n, l in enumerate(open(f, errors="replace"), 1):
        if l.lstrip().startswith("#"):
            continue
        for c in re.findall(r"command -v ([A-Za-z][\w.+-]*)", l):
            need.setdefault(c, f"{f}:{n}")
        for m in re.finditer(r"for (\w+) in ([\w .+-]+); do[^;]*command -v \$\1", l):
            for c in m.group(2).split():
                need.setdefault(c, f"{f}:{n}")
print(f"声明 {len(need)} 个命令；缺：" + " ".join(f"{c}（{w}）" for c, w in sorted(need.items())
               if c not in ok and not any(os.access(f"{d}/{c}", os.X_OK) for d in ("/usr/bin", "/bin", "/usr/sbin", "/sbin"))))
PY
)
ck "① 出包链 command -v 要的命令用户机都有（运行环境自带：${SHIP}；${miss}）" '[ -n "$SHIP" ] && [[ "$miss" == 扫\ [1-9]*"缺："* ]] && [ -z "${miss#*缺：}" ]'
# 仿 App：Runtime/bin 按运行环境表链到本机同名命令，Runtime/python/bin/python3 链到出包用的 Python（启动器把它作 S2A_PYTHON 传给作业）
B="$T/带 空格/S2Arm 应用"; RT="$B/Runtime"; mkdir -p "$RT/bin" "$RT/python/bin" "$B/引擎 树" "$B/输出 区"
for n in $SHIP; do p=$(command -v "$n") && ln -s "$p" "$RT/bin/$n"; done
PY=${S2A_PYTHON:-}; [ -n "$PY" ] || { [ -x "$HOME/.s2arm/venv/bin/python3" ] && PY=$HOME/.s2arm/venv/bin/python3; } || PY=$(command -v python3)
printf '#!/bin/sh\nexec "%s" "$@"\n' "$PY" > "$RT/python/bin/python3"; chmod +x "$RT/python/bin/python3"   # 包一层而不是软链：venv 的 python 经软链调用找不到 pyvenv.cfg，包就丢了
JP="$RT/python/bin:$RT/bin:/usr/bin:/bin:/usr/sbin:/sbin"
bv=$(env -i HOME="$HOME" PATH="$JP" bash -c 'echo "${BASH_VERSINFO[0]} $(command -v bash)"' 2>&1)
ck "② 运行环境表有 bash、作业 PATH 找到的 bash：${bv}" '[[ " $SHIP " == *" bash "* ]] && [ "${bv%% *}" -ge 5 ] 2> /dev/null && [ "${bv#* }" = "$RT/bin/bash" ]'
# 引擎：一键出包本体 + 它 source 的工具，播种 / 刷新 / 出包换成桩（同 tests/oneclick_census_test.sh）
R="$B/引擎 树"; mkdir -p "$R/pack/oneclick" "$R/tools" "$R/x/exefs" "$B/字体"
cp "$H/pack/oneclick/oneclick.sh" "$H/pack/oneclick/cachehits.py" "$H/pack/oneclick/titles.tsv" "$H/pack/oneclick/ipa_mode.py" "$H/pack/oneclick/deliver_pack.py" "$R/pack/oneclick/"
cp "$H/pack/direct_profile_input.py" "$R/pack/"   # 一键出包写直连版本旁注调它
mkdir -p "$R/pack/jobs" "$R/compat/tree"; cp "$H"/pack/jobs/*.py "$R/pack/jobs/"; cp "$H/compat/tree/global.json" "$R/compat/tree/"   # 一键出包判 .NET SDK 调 pack/jobs/ipa.py dotnet_sdk()（版本按 global.json，全仓一处判法）
cp "$H/pack/roots.sh" "$H/pack/srcs.sh" "$H/pack/build_id.sh" "$R/pack/"
for f in cores.sh progress.sh machine.sh nospace.sh; do cp "$H/tools/$f" "$R/tools/"; done
mkdir -p "$R/graphics/nvn/tools"; cp "$H/graphics/nvn/tools/romfs_list.py" "$R/graphics/nvn/tools/"   # --from-extract 播种键盘点 romfs/ aoc/（审计 #1534 P1-54）
printf '#!/bin/bash\nr=$S2A_ROOTS/$1@$2; mkdir -p "$r" && cp -R "$3/exefs" "$r/" && cp "$3"/*.tsv "$r/" 2> /dev/null; ln -sfn "$1@$2" "$S2A_ROOTS/$1@现行"; echo "🟢 播种桩 $r"\n' > "$R/pack/seed_root.sh"
printf '#!/bin/bash\necho "🟢 刷新桩"\n' > "$R/pack/refresh.sh"
cat > "$R/pack/ipa.sh" <<'EOF'
#!/bin/bash
c=$(cd -P "$S2A_ROOTS/$1@现行" && pwd); mkdir -p "$c/pkg/pack"; python3 -c "import plistlib,sys,zipfile; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('Payload/S2Arm.app/Info.plist', plistlib.dumps({'S2AGraphicsMode': 'direct', 'S2AGraphicsModeReason': ''})); z.close()" "$c/pkg/$1.ipa"; echo "{}" > "$c/pkg/pack/manifest.json"; : > "$c/pkg/pack/index.tsv"; echo "🟢 出包桩"
EOF
chmod +x "$R"/pack/*.sh
{ head -c 64 /dev/zero; printf 'BUILDIDBUILDID01'; head -c 32 /dev/zero; } > "$R/x/exefs/main"
python3 -c "import sys; open(sys.argv[1], 'wb').write(b'META' + bytes(8) + bytes([1]) + bytes(3))" "$R/x/exefs/main.npdm"
# 位数工具桩（审计 P2-29：--from-extract 读不出位数就报红停，原先 /usr/bin/false 被静默当 64 位）：放带空格目录里，只答 --npdm-isa
printf '#!/bin/bash\n[ "$1" = --npdm-isa ] && [ -f "$2" ] && { echo aarch64; exit 0; }\nexit 1\n' > "$R/nxu 桩"; chmod +x "$R/nxu 桩"
printf 'title_id\t0100abcd00001000\nname\tUser Env Fixture\ndisplay_version\t1.0.0\nupdate\t0\n' > "$R/x/unpack.tsv"; : > "$B/字体/x.bfttf"
DN=${DOTNET:-$(command -v dotnet || echo "$HOME/.dotnet/dotnet")}   # 启动器 iPhone 作业把确认过的 .NET SDK 作 DOTNET 传进来、目录排 PATH 最前（pack/jobs/ipa.py）
OC() { env -i HOME="$HOME" LC_ALL=C TMPDIR="${TMPDIR:-/tmp}" PATH="$(dirname "$DN"):$JP" DOTNET="$DN" S2A_PYTHON="$RT/python/bin/python3" \
  S2A_NX_UNPACK="$R/nxu 桩" S2A_MACHINE_NO_LOCAL=1 S2A_BEAT_S=3600 S2A_ROOTS_NO_BOOT=1 \
  bash "$R/pack/oneclick/oneclick.sh" --from-extract "$R/x" --target ios --fonts "$B/字体" --sign adhoc --out "$1" 2>&1; }
o3=$(OC "$B/输出 区/甲"); r3=$?; ipa=$(ls "$B/输出 区/甲"/*.ipa 2> /dev/null | head -1)
ck "③ 带空格目录 + 启动器作业 PATH 一键出包：rc=${r3}、IPA $([ -n "$ipa" ] && echo 有 || echo 没有)$(echo "$o3" | grep -m1 -E 'not found|unbound variable|🔴' | sed 's/^/；/' | cut -c1-160)" \
  '[ $r3 = 0 ] && [ -n "$ipa" ] && ! grep -qE "command not found|unbound variable" <<< "$o3"'
# ⑤ ⑥：Runtime 仿 App 自带 C 改写器（维护机按本树源码编一份，同 bundle_runtime.py：拷进 Runtime/bin、旁边 .source 记源码指纹），作业环境取自 core.py
CB=$(S2A_REWRITER=c "$PY" "$H/pack/rewriter.py" c-path 2> "$T/cbuild.log") && cp "$CB" "$RT/bin/s2a-rewrite" \
  && "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); import rewriter; print(rewriter.source_digest())' "$H/pack" > "$RT/bin/s2a-rewrite.source"
printf '{"runtimeSchema": 4}\n' > "$RT/versions.json"; mkdir -p "$T/空家"
RW() { "$PY" - "$H" "$B" "$T" "$1" <<'PY'
import os, subprocess, sys
h, b, t, keep = sys.argv[1:]
sys.path.insert(0, os.path.join(h, "pack/jobs")); os.environ.pop("S2A_REWRITER_BUNDLED", None)
from core import Context
env = Context(dict(schema=1, taskId="userenv", operation="setup", engineDir=h, privateRoot=os.path.join(t, "私有 区"), resources=b)).env()
env["HOME"] = os.path.join(t, "空家")   # 没有 ~/.s2arm/run/s2arm/deps 这类共享依赖
env["S2A_REWRITER_CACHE"] = os.path.join(t, "空缓存")   # 用户机 App 里的引擎没有现编缓存（本树 build/rewriter-cli 有维护机编过的）
if keep != "1":
    env.pop("S2A_REWRITER_BUNDLED", None)
r = subprocess.run([os.path.join(b, "Runtime/python/bin/python3"), os.path.join(h, "pack/rewriter.py"), "c-path"], env=env, capture_output=True, text=True)
cm = subprocess.run(["/bin/sh", "-c", "command -v cmake"], env=env, capture_output=True, text=True).stdout.strip()
print(f"rc={r.returncode} cmake={cm or '无'} out={r.stdout.strip()} err={r.stderr.strip()[:160]}")
PY
}
o5=$(RW 1); o6=$(RW 0)
ck "⑤ 用户机改写入口（作业环境、无 cmake、无共享依赖）选中 App 自带改写器：${o5}" \
  '[ -n "${CB:-}" ] && [[ "$o5" == "rc=0 cmake=无 out=$(cd -P "$RT/bin" && pwd)/s2a-rewrite "* ]]'
ck "⑥ 对照：不带自带改写器 → 报红：$(cut -c1-120 <<< "$o6")" '[[ "$o6" == "rc=1 cmake=无 "*"【红】改写器"* ]]'
[ $bad = 0 ] && echo "userenv 单测全过" || { echo "userenv 单测有不通"; exit 1; }
