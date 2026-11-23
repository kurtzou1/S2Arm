#!/bin/bash
# 门禁覆盖：services/systemdata/make_tzdata.sh services/systemdata/tzdata-pins.sh pack/stages/sysdata.sh
# 不联网：小型合成钉版输入，通过真实命令入口验证时区生成及出包阶段。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/services/systemdata" "$T/code" "$T/data" "$T/cache" "$T/host-a/Etc" "$T/host-b/Etc"
cp "$H/services/systemdata/make_tzdata.sh" "$T/repo/services/systemdata/"
cat > "$T/code/Makefile" <<'MAKE'
zic: zic.c
	$(CC) -o zic zic.c
MAKE
cat > "$T/code/zic.c" <<'C'
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
int main(int n, char **v) {
    const char *out = 0; char p[4096];
    for (int i = 1; i + 1 < n; i++) if (!strcmp(v[i], "-d")) out = v[i+1];
    if (!out) return 1;
    mkdir(out, 0700); snprintf(p, sizeof(p), "%s/Etc", out); mkdir(p, 0700);
    snprintf(p, sizeof(p), "%s/Etc/Test", out); FILE *f = fopen(p, "wb"); if (!f) return 2;
    unsigned char b[44] = {0}; memcpy(b, "TZif2", 5); fwrite(b, 1, 44, f); fwrite(b, 1, 44, f);
    fputs("PINNED", f); return fclose(f) != 0;
}
C
printf '2026f\n' > "$T/data/version"
for n in africa antarctica asia australasia europe northamerica southamerica etcetera backward; do : > "$T/data/$n"; done
tar -czf "$T/cache/tzcode2026f.tar.gz" -C "$T/code" .
tar -czf "$T/cache/tzdata2026f.tar.gz" -C "$T/data" .
fixture_tree_sha() {
  python3 - "$1" <<'PYHASH'
import hashlib, json, sys
files = {'binaryList.txt': b'Etc/Test\n', 'version.txt': (sys.argv[1]+'\n').encode(),
         'zoneinfo/Etc/Test': b'TZif2'+bytes(39)+b'PINNED'}
rows = [{'path': k, 'size': len(v), 'sha256': hashlib.sha256(v).hexdigest()} for k,v in sorted(files.items())]
print(hashlib.sha256(json.dumps(rows, sort_keys=True, separators=(',', ':')).encode()).hexdigest())
PYHASH
}
CODE_SHA=$(shasum -a 512 "$T/cache/tzcode2026f.tar.gz" | cut -d' ' -f1)
DATA_SHA=$(shasum -a 512 "$T/cache/tzdata2026f.tar.gz" | cut -d' ' -f1)
printf 'TZ_VERSION=2026f\nTZ_CODE_SHA512=%s\nTZ_DATA_SHA512=%s\nTZ_OUTPUT_SHA256=%s\n' "$CODE_SHA" "$DATA_SHA" "$(fixture_tree_sha 2026f)" > "$T/repo/services/systemdata/tzdata-pins.sh"
python3 - "$T" <<'PY'
import pathlib, sys
p=pathlib.Path(sys.argv[1]); h=b'TZif2'+bytes(39)
for name, payload in [('host-a',b'A'),('host-b',b'B')]:
    (p/name/'Etc/Test').write_bytes(h+h+payload)
    (p/name/'+VERSION').write_text(name+'\n')
PY
export S2A_TZDATA_CACHE="$T/cache"
script="$T/repo/services/systemdata/make_tzdata.sh"
bash "$script" "$T/a" "$T/host-a" > "$T/a.log" 2>&1
bash "$script" "$T/b" "$T/host-b" > "$T/b.log" 2>&1
if ! diff -rq "$T/a" "$T/b" >/dev/null; then
    echo '不通：宿主时区库变化导致产物变化'
    exit 1
fi
[ "$(cat "$T/a/version.txt")" = 2026f ] || { echo '不通：version.txt 未使用钉版'; exit 1; }
echo '通：宿主库变化不影响钉版时区输出'
# 缺失 / 错误摘要均报红，不能悄悄读取旧宿主库或破坏已有输出。
mkdir -p "$T/empty"; mkdir -p "$T/existing"; echo sentinel > "$T/existing/keep"
if S2A_TZDATA_CACHE="$T/empty" bash "$script" "$T/existing" "$T/host-a" > "$T/missing.log" 2>&1; then
    echo '不通：缺钉版源码却成功'; exit 1
fi
grep -q -- '--prepare-sources' "$T/missing.log"
[ "$(cat "$T/existing/keep")" = sentinel ]
mkdir -p "$T/corrupt"; cp "$T/cache/"* "$T/corrupt/"; printf bad >> "$T/corrupt/tzdata2026f.tar.gz"
if S2A_TZDATA_CACHE="$T/corrupt" bash "$script" "$T/corrupt-out" "$T/host-a" > "$T/corrupt.log" 2>&1; then
    echo '不通：损坏的钉版源码却成功'; exit 1
fi
grep -q 'SHA-512 不符' "$T/corrupt.log"; [ ! -e "$T/corrupt-out" ]
# 本地准备不能在目录缺文件时退回联网；成功准备后可离线使用。
mkdir -p "$T/local-incomplete" "$T/fake-bin" "$T/prepared"
cp "$T/cache/tzcode2026f.tar.gz" "$T/local-incomplete/"
printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$T/network-used" > "$T/fake-bin/curl"; chmod +x "$T/fake-bin/curl"
if PATH="$T/fake-bin:$PATH" S2A_TZDATA_CACHE="$T/prepared" bash "$script" --prepare-sources "$T/local-incomplete" > "$T/prepare-missing.log" 2>&1; then
    echo '不通：本地源码缺失却准备成功'; exit 1
fi
[ ! -e "$T/network-used" ]
S2A_TZDATA_CACHE="$T/prepared" bash "$script" --prepare-sources "$T/cache" >/dev/null
S2A_TZDATA_CACHE="$T/prepared" bash "$script" --check-sources
S2A_TZDATA_CACHE="$T/prepared" bash "$script" "$T/prepared-out" "$T/host-b" >/dev/null
cmp "$T/a/zoneinfo/Etc/Test" "$T/prepared-out/zoneinfo/Etc/Test"
echo '通：缺失、损坏及本地准备均按离线契约处理'
# 模拟已安装 App 的引擎布局，预编目录与源码同封装，无本机编译器或外部缓存。
bundle="$T/repo/Binaries/Prepare/Tzdata"
if ! S2A_TZDATA_CACHE="$T/cache" python3 - "$H" "$T/repo" "$bundle" "$T" > "$T/bundle.log" 2>&1 <<'PYBUNDLE'
import os, pathlib, subprocess, sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / 'launchers/macos'))
import bundle_engine
class Context:
    private = pathlib.Path(sys.argv[4])
    logs = private   # 作业日志目录（core.Context.logs）
    def env(self): return dict(os.environ)
    def run(self, args, log, env): subprocess.run(list(map(str,args)), env=env, check=True)
bundle_engine.bundle_tzdata(Context(), pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[2]))
PYBUNDLE
then
    echo '不通：App 制包入口没有产出经校验的内置时区'; exit 1
fi
[ -f "$bundle/output/version.txt" ]
[ -f "$bundle/tzcode2026f.tar.gz" ] && [ -f "$bundle/tzdata2026f.tar.gz" ]
printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$T/compiler-used" > "$T/fake-bin/make"; chmod +x "$T/fake-bin/make"
if ! (unset S2A_TZDATA_CACHE; PATH="$T/fake-bin:$PATH" bash "$script" "$T/from-app" > "$T/from-app.log" 2>&1); then
    echo '不通：App 无外部缓存或编译器时不能生成钉版时区'; exit 1
fi
[ ! -e "$T/compiler-used" ] && diff -rq "$T/a" "$T/from-app" >/dev/null
# App 真实内置引擎安装器克隆后，仍从引擎自身的 Binaries 消费，不依赖开发机路径。
python3 - "$H" "$T/repo" "$T" <<'PYEMBED'
import hashlib, json, os, pathlib, subprocess, sys, types
h, source, tmp = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(h/'pack/jobs'))
import embedded
env=dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1',
         GIT_AUTHOR_NAME='fixture', GIT_AUTHOR_EMAIL='fixture@invalid',
         GIT_COMMITTER_NAME='fixture', GIT_COMMITTER_EMAIL='fixture@invalid')
def git(*args): subprocess.run(['git','-C',str(source),*args],env=env,check=True,stdout=subprocess.DEVNULL)
git('init','-q','--template='); git('add','services'); git('commit','-qm','fixture')
files={p.relative_to(source).as_posix():[p.stat().st_size,hashlib.sha256(p.read_bytes()).hexdigest()]
       for p in source.rglob('*') if p.is_file() and not p.is_symlink()}
(source/'engine.json').write_text(json.dumps({'schema':1,'id':'a'*64,'files':files}))
private=tmp/'app-private'; private.mkdir()
c=types.SimpleNamespace(r={'engineBundle':str(source)}, private=private, library=None, begin=lambda *_:None,   # 还没建库：引擎副本放私有目录（embedded.engines_root）
                        check=lambda:None, progress=lambda *_:None, require_source=lambda:None)
embedded.install(c)
runenv=dict(env); runenv.pop('S2A_TZDATA_CACHE',None)
runenv['PATH']=str(tmp/'fake-bin')+os.pathsep+runenv['PATH']
subprocess.run(['bash',str(c.engine/'services/systemdata/make_tzdata.sh'),str(tmp/'from-installed')],
               env=runenv,check=True,stdout=subprocess.DEVNULL)
assert (tmp/'from-installed/zoneinfo/Etc/Test').read_bytes() == (tmp/'a/zoneinfo/Etc/Test').read_bytes()
assert not (tmp/'compiler-used').exists()
PYEMBED
printf corrupt >> "$bundle/output/zoneinfo/Etc/Test"
if (unset S2A_TZDATA_CACHE; PATH="$T/fake-bin:$PATH" bash "$script" "$T/bad-app" > "$T/bad-app.log" 2>&1); then
    echo '不通：App 时区被篡改仍可使用'; exit 1
fi
[ ! -e "$T/compiler-used" ] && [ ! -e "$T/bad-app" ]
rm -f "$bundle/output/zoneinfo/Etc/Test"
ln -s "$T/a/zoneinfo/Etc/Test" "$bundle/output/zoneinfo/Etc/Test"
if (unset S2A_TZDATA_CACHE; PATH="$T/fake-bin:$PATH" bash "$script" "$T/linked-app" > "$T/linked-app.log" 2>&1); then
    echo '不通：App 输出含软链仍可使用'; exit 1
fi
grep -q '不得含软链' "$T/linked-app.log"
[ ! -e "$T/compiler-used" ] && [ ! -e "$T/linked-app" ]
rm -rf "$bundle"
rm -f "$T/fake-bin/make"
echo '通：App 内置来源离线使用，篡改拒绝'
# 用最小根目录适配器测试系统数据阶段的键及缓存复用，生成器本身仍真实运行。
mkdir -p "$T/repo/pack/stages" "$T/roots/game@seed/systemdata" "$T/fonts"
cp "$H/pack/stages/sysdata.sh" "$T/repo/pack/stages/"
cat > "$T/repo/pack/roots.sh" <<'ROOTS'
root_cur() { cd -P "$S2A_ROOTS/$(cat "$S2A_ROOTS/$1@现行")" && pwd; }
root_tag() { local tag=$2 n=1; while [ -e "$S2A_ROOTS/$1@$tag" ] || [ -e "$S2A_ROOTS/$1@$tag.tmp" ]; do n=$((n+1)); tag="$2-$n"; done; echo "$tag"; }
root_begin() { local w="$S2A_ROOTS/$1@$2.tmp"; cp -R "$(root_cur "$1")" "$w"; echo "$w"; }
root_abort() { rm -rf "$S2A_ROOTS/$1@$2.tmp"; }
root_stage_done() { if [ -n "${S2A_STAGE_KEYS:-}" ]; then printf '%s\t%s\n' "$2" "$3" >> "$S2A_STAGE_KEYS"; return 0; fi; [ "$(cat "$1/.stage_$2" 2>/dev/null)" = "$3" ]; }
_root_rm() { rm -rf "$1"; }
_root_cp() { cp "$@"; }
root_copy() { shift; _root_cp "$@"; }   # 真 roots.sh 的共用拷贝（克隆不了退回普通复制，D-F9WY）；这里只测时区
root_commit() { mv "$S2A_ROOTS/$1@$2.tmp" "$S2A_ROOTS/$1@$2"; printf '%s\n' "$1@$2" > "$S2A_ROOTS/$1@现行"; }
ROOTS
printf '#!/usr/bin/env python3\n' > "$T/repo/pack/sysdata_need.py"
printf 'font\n' > "$T/fonts/a.bfttf"
printf '%s\n' game@seed > "$T/roots/game@现行"
export S2A_ROOTS="$T/roots" S2A_FONTS="$T/fonts"
if [ "$(uname -s)" = Linux ]; then
  # 主线根/字体复制仍用 macOS cp -c；这里仅为验证时区阶段行为替换这个外部工具。
  cat > "$T/fake-bin/cp" <<'COPY'
#!/bin/bash
args=(); for arg in "$@"; do case "$arg" in -c) ;; -cR) args+=(-R);; *) args+=("$arg");; esac; done
exec /bin/cp "${args[@]}"
COPY
  chmod +x "$T/fake-bin/cp"; export PATH="$T/fake-bin:$PATH"
fi
stage="$T/repo/pack/stages/sysdata.sh"
bash "$stage" game > "$T/stage-first.log" 2>&1
first=$(cat "$T/roots/game@现行")
if [ ! -s "$T/roots/$(cat "$T/roots/game@现行")/.stage_sysdata" ]; then
    echo '不通：生成时区未登记系统数据阶段键'; exit 1
fi
# 只算键不应需要字体、归档或编译器，也不能写产物根。
if ! S2A_STAGE_KEYS="$T/sysdata.keys" S2A_FONTS="$T/no-fonts" S2A_TZDATA_CACHE="$T/empty" bash "$stage" game > "$T/key-only.log" 2>&1; then
    echo '不通：系统数据只算键依赖字体或源码归档'; exit 1
fi
[ "$(cut -f1 "$T/sysdata.keys")" = sysdata ] && [ "$(cut -f2 "$T/sysdata.keys")" = "$(cat "$T/roots/$(cat "$T/roots/game@现行")/.stage_sysdata")" ]
cp "$H/pack/stage_keys.sh" "$H/pack/stage_sysdata.sh" "$T/repo/pack/"
for item in rewrite uilayout aoc romfsidx shaders; do
    printf '#!/bin/bash\nprintf "%%s\t%%s\n" "%s" fixed >> "$S2A_STAGE_KEYS"\n' "$item" > "$T/repo/pack/stage_$item.sh"
    printf 'fixed\n' > "$T/roots/$(cat "$T/roots/game@现行")/.stage_$item"
done
S2A_FONTS="$T/no-fonts" S2A_TZDATA_CACHE="$T/empty" bash "$T/repo/pack/stage_keys.sh" game "$T/roots/$(cat "$T/roots/game@现行")" > "$T/keys-first"
if ! awk -F '\t' '$1=="sysdata" && $2==$3 && $2!="" {found=1} END {exit !found}' "$T/keys-first"; then
    echo '不通：只出程序快道没有读取系统数据阶段键'; exit 1
fi
# 真实只换程序入口 + 真实 stage_keys；其它阶段和 IPA 构建为合成桩。
mkdir -p "$T/repo/tools" "$T/sched/pkgs" "$T/shared" "$T/snapshot/pack"
ln -s "$T/roots/$(cat "$T/roots/game@现行")" "$T/shared/game@pkg-base"
printf 'COMMIT=base\nPKG=%q\n' "$T/snapshot" > "$T/sched/pkgs/game.env"
printf old > "$T/snapshot/game.ipa"; printf 'old-resource' > "$T/snapshot/pack/data"
cat > "$T/ipa" <<'IPA'
#!/bin/bash
mkdir -p "$S2A_APP_ONLY_OUT"; printf new > "$S2A_APP_ONLY_OUT/$1.ipa"
: > "$S2A_APP_ONLY_OUT/timing.tsv"; : > "$S2A_APP_ONLY_OUT/build.log"; echo fixture
IPA
chmod +x "$T/ipa"
export S2A_SCHED_DIR="$T/sched" S2A_ROOTS_SHARED="$T/shared" S2A_APP_ONLY_DIR="$T/app-only" S2A_APP_ONLY_IPA="$T/ipa"
mv "$T/repo/services/systemdata/tzdata-pins.sh" "$T/pins.backup"
rc=0; bash "$T/repo/pack/stage_keys.sh" game "$T/roots/$(cat "$T/roots/game@现行")" > "$T/keys-missing.log" 2>&1 || rc=$?
mv "$T/pins.backup" "$T/repo/services/systemdata/tzdata-pins.sh"
[ "$rc" != 0 ] && grep -q '时区来源键无法计算' "$T/keys-missing.log"
bash "$stage" game > "$T/stage-repeat.log" 2>&1
[ "$(cat "$T/roots/game@现行")" = "$first" ] || { echo '不通：来源不变时重复生成'; exit 1; }
# 一个不同版本、内容的第二份经验证合成来源，必须形成新键并重生成。
printf '2026g\n' > "$T/data/version"
tar -czf "$T/cache/tzdata2026g.tar.gz" -C "$T/data" .
cp "$T/cache/tzcode2026f.tar.gz" "$T/cache/tzcode2026g.tar.gz"
DATA2_SHA=$(shasum -a 512 "$T/cache/tzdata2026g.tar.gz" | cut -d' ' -f1)
printf 'TZ_VERSION=2026g\nTZ_CODE_SHA512=%s\nTZ_DATA_SHA512=%s\nTZ_OUTPUT_SHA256=%s\n' "$CODE_SHA" "$DATA2_SHA" "$(fixture_tree_sha 2026g)" > "$T/repo/services/systemdata/tzdata-pins.sh"
S2A_FONTS="$T/no-fonts" S2A_TZDATA_CACHE="$T/empty" bash "$T/repo/pack/stage_keys.sh" game "$T/roots/$(cat "$T/roots/game@现行")" > "$T/keys-changed"
awk -F '\t' '$1=="sysdata" && $2!=$3 && $3!="" {found=1} END {exit !found}' "$T/keys-changed" || { echo '不通：快道没有感知时区来源变更'; exit 1; }
bash "$stage" game > "$T/stage-changed.log" 2>&1
second=$(cat "$T/roots/game@现行")
if [ "$first" = "$second" ] || [ "$(cat "$T/roots/$(cat "$T/roots/game@现行")/systemdata/010000000000080E/version.txt")" != 2026g ]; then
    echo '不通：钉版来源变化后系统数据阶段未失效'
    exit 1
fi
echo '通：时区来源不变复用，版本及摘要改变后阶段失效'
# 同一版本仅变源码摘要也必须失效；结果未变时仍保留来源键变化。
printf '\n/* second compiler source */\n' >> "$T/code/zic.c"
tar -czf "$T/cache/tzcode2026g.tar.gz" -C "$T/code" .
CODE2_SHA=$(shasum -a 512 "$T/cache/tzcode2026g.tar.gz" | cut -d' ' -f1)
printf 'TZ_VERSION=2026g\nTZ_CODE_SHA512=%s\nTZ_DATA_SHA512=%s\nTZ_OUTPUT_SHA256=%s\n' "$CODE2_SHA" "$DATA2_SHA" "$(fixture_tree_sha 2026g)" > "$T/repo/services/systemdata/tzdata-pins.sh"
bash "$stage" game > "$T/stage-sha-changed.log" 2>&1
third=$(cat "$T/roots/game@现行")
[ "$second" != "$third" ] || { echo '不通：源码摘要变化后阶段键未变化'; exit 1; }
# 缓存里的输入丢失：已生成过的产物也不能当成钉版来源已经备齐。
if S2A_TZDATA_CACHE="$T/empty" bash "$stage" game > "$T/stage-missing.log" 2>&1; then
    echo '不通：缺少钉版来源时阶段仍成功'; exit 1
fi
[ "$(cat "$T/roots/game@现行")" = "$third" ]
# 真系统数据不被钉版生成器覆盖，也无需借用宿主时区。
mkdir -p "$T/roots/real@seed/systemdata/010000000000080E"
printf 'real-user-data\n' > "$T/roots/real@seed/systemdata/010000000000080E/version.txt"
printf '%s\n' real@seed > "$T/roots/real@现行"
S2A_TZDATA_CACHE="$T/empty" bash "$stage" real > "$T/stage-real.log" 2>&1
[ "$(cat "$T/roots/$(cat "$T/roots/real@现行")/systemdata/010000000000080E/version.txt")" = real-user-data ]
# 历史真系统数据无键时保留兼容；错误键需要下一次普通阶段自修。
rm -f "$T/roots/$(cat "$T/roots/real@现行")/.stage_sysdata"
S2A_FONTS="$T/no-fonts" S2A_TZDATA_CACHE="$T/empty" bash "$T/repo/pack/stage_keys.sh" real "$T/roots/$(cat "$T/roots/real@现行")" > "$T/keys-real"
awk -F '\t' '$1=="sysdata" && $2=="real" && $3=="real" {found=1} END {exit !found}' "$T/keys-real"
printf 'tz-stale\n' > "$T/roots/$(cat "$T/roots/real@现行")/.stage_sysdata"
S2A_TZDATA_CACHE="$T/empty" bash "$stage" real > "$T/stage-real-repair.log" 2>&1
[ "$(cat "$T/roots/$(cat "$T/roots/real@现行")/.stage_sysdata")" = real ]
[ "$(cat "$T/roots/$(cat "$T/roots/real@现行")/systemdata/010000000000080E/version.txt")" = real-user-data ]
echo '通：摘要变化、来源缺失和真实系统数据保留'
# 数据 SHA 独立变更、版本不变也必须重新生成。
printf 'second data source\n' > "$T/data/additional"
tar -czf "$T/cache/tzdata2026g.tar.gz" -C "$T/data" .
DATA3_SHA=$(shasum -a 512 "$T/cache/tzdata2026g.tar.gz" | cut -d' ' -f1)
printf 'TZ_VERSION=2026g\nTZ_CODE_SHA512=%s\nTZ_DATA_SHA512=%s\nTZ_OUTPUT_SHA256=%s\n' "$CODE2_SHA" "$DATA3_SHA" "$(fixture_tree_sha 2026g)" > "$T/repo/services/systemdata/tzdata-pins.sh"
bash "$stage" game > "$T/stage-data-sha.log" 2>&1
fourth=$(cat "$T/roots/game@现行")
[ "$third" != "$fourth" ] || { echo '不通：数据摘要变化后阶段键未变化'; exit 1; }
# 旧生成器的 tz.log 证明来自宿主库时，不能当成玩家真实系统数据沿用。
mkdir -p "$T/roots/legacy@seed/systemdata/010000000000080E"
printf 'host-old\n' > "$T/roots/legacy@seed/systemdata/010000000000080E/version.txt"
printf '时区数据：1 个区，版本 old\n' > "$T/roots/legacy@seed/tz.log"
printf '%s\n' legacy@seed > "$T/roots/legacy@现行"
bash "$stage" legacy > "$T/stage-legacy.log" 2>&1
[ "$(cat "$T/roots/$(cat "$T/roots/legacy@现行")/systemdata/010000000000080E/version.txt")" = 2026g ]
python3 - "$T/a/zoneinfo/Etc/Test" <<'PY'
import pathlib, sys
assert pathlib.Path(sys.argv[1]).read_bytes() == b'TZif2' + bytes(39) + b'PINNED'
PY
echo '通：数据摘要单独变化、旧宿主生成目录迁移与 TZif 64 位段'
# 即使源码归档身份被相应更新，非预期的编译输出也不能被发布。
python3 - "$T/code/zic.c" <<'PY'
import pathlib, sys
p=pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace('PINNED', 'MUTANT'))
PY
tar -czf "$T/cache/tzcode2026g.tar.gz" -C "$T/code" .
BAD_CODE_SHA=$(shasum -a 512 "$T/cache/tzcode2026g.tar.gz" | cut -d' ' -f1)
printf 'TZ_VERSION=2026g\nTZ_CODE_SHA512=%s\nTZ_DATA_SHA512=%s\nTZ_OUTPUT_SHA256=%s\n' "$BAD_CODE_SHA" "$DATA3_SHA" "$(fixture_tree_sha 2026g)" > "$T/repo/services/systemdata/tzdata-pins.sh"
mkdir -p "$T/output-preserved"; echo keep > "$T/output-preserved/sentinel"
if bash "$script" "$T/output-preserved" > "$T/bad-output.log" 2>&1; then
    echo '不通：不同工具链输出被接受'; exit 1
fi
grep -q '生成的时区目录 SHA-256 不符' "$T/bad-output.log"
[ "$(cat "$T/output-preserved/sentinel")" = keep ] && [ ! -e "$T/output-preserved.tmp" ]
echo '通：生成目录摘要不符时拒绝并保留原输出'
# App 制包时若生成校验失败，不留半成品目录。
if bash "$script" --bundle-to "$T/invalid-bundle" > "$T/invalid-bundle.log" 2>&1; then
    echo '不通：App 制包接受错误的生成目录'; exit 1
fi
[ ! -e "$T/invalid-bundle" ]
echo '通：App 制包失败不留下半成品'
