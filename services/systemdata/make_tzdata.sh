#!/bin/bash
# 生成时区系统数据目录（Switch 010000000000080E TimeZoneBinary 的内容布局）：zoneinfo/<区名> TZif 文件 + binaryList.txt + version.txt。
# 来源：钉版 IANA 公开源码，显式准备后离线生成。格式：Switch 的区文件是「TZif 头 + 64 位数据」
# （Ryujinx 解析器第一个数据块就按 8 字节读时间），宿主 TZif2 文件第一块是 32 位 v1 数据，所以取其第二个头起的 64 位段（含尾部 POSIX 规则行）。
# 准备：make_tzdata.sh --prepare-sources [包含两个钉版归档的本地目录]；不指定目录时显式联网。
# 生成：make_tzdata.sh <输出目录> [旧宿主目录参数（忽略）]。过程离线，绝不读宿主时区库。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/tzdata-pins.sh"
BUNDLED=$(cd "$HERE/../.." && pwd)/Binaries/Prepare/Tzdata
USE_BUNDLE=0
if [ -z "${S2A_TZDATA_CACHE:-}" ] && [ "${1:-}" != --prepare-sources ] && [ -d "$BUNDLED" ]; then
  CACHE=$BUNDLED; USE_BUNDLE=1
else
  CACHE=${S2A_TZDATA_CACHE:-${HOME:?请设置 HOME 或 S2A_TZDATA_CACHE}/.cache/s2arm-build/tzdata}
fi
CODE=tzcode${TZ_VERSION}.tar.gz; DATA=tzdata${TZ_VERSION}.tar.gz
check() {
  local file=$1 expected=$2
  [ -f "$file" ] || { echo "【红】缺少钉版时区源码 ${file}；请运行 bash $HERE/make_tzdata.sh --prepare-sources [本地目录]" >&2; return 1; }
  [ "$(shasum -a 512 "$file" | cut -d' ' -f1)" = "$expected" ] || { echo "【红】钉版时区源码 SHA-512 不符：$file" >&2; return 1; }
}
verify_tree() {
"${S2A_PYTHON:-/usr/bin/python3}" - "$1" "$TZ_OUTPUT_SHA256" <<'PY'
import hashlib, json, os, sys
root, expected = sys.argv[1:]
# 系统自动生成的附属文件不算内容（#816：库在 exFAT 上时 macOS 给每个新文件旁边生成 ._<名>，拷过去的 599 个文件变成 1219 个、哈希必不符）。
#   名单同作业层 pack/jobs/layout.py OS_JUNK / OS_JUNK_PREFIX（tests/os_junk_sync_test.sh 核一致）
OS_JUNK = {".DS_Store", "desktop.ini", "Thumbs.db"}
rows = []
for directory, dirs, files in os.walk(root):
    files = [name for name in files if name not in OS_JUNK and not name.startswith("._")]
    if any(os.path.islink(os.path.join(directory, name)) for name in dirs + files):
        sys.exit('【红】时区目录不得含软链')
    dirs.sort()
    for name in sorted(files):
        path = os.path.join(directory, name)
        with open(path, 'rb') as stream:
            data = stream.read()
        rows.append({'path': os.path.relpath(path, root).replace(os.sep, '/'),
                     'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
rows.sort(key=lambda entry: entry['path'])
actual = hashlib.sha256(json.dumps(rows, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
if actual != expected:
    sys.exit(f'【红】生成的时区目录 SHA-256 不符：{actual}（期望 {expected}）')
PY

}
prepare() {
  local name=$1 sha=$2 local_dir=${3:-} tmp
  if [ -e "$CACHE/$name" ]; then check "$CACHE/$name" "$sha"; return; fi
  mkdir -p "$CACHE"
  tmp=$(mktemp "$CACHE/.tz-prepare.XXXXXXXX")
  if [ -n "$local_dir" ]; then
    if ! cp "$local_dir/$name" "$tmp"; then rm -f "$tmp"; return 1; fi
  else
    if ! curl --fail --location --connect-timeout 20 --max-time 300 --retry 2 -o "$tmp" "https://www.iana.org/time-zones/repository/releases/$name"; then rm -f "$tmp"; return 1; fi
  fi
  if ! check "$tmp" "$sha"; then rm -f "$tmp"; return 1; fi
  mv "$tmp" "$CACHE/$name"
}
case ${1:-} in
  --source-id) printf '%s %s %s %s\n' "$TZ_VERSION" "$TZ_CODE_SHA512" "$TZ_DATA_SHA512" "$TZ_OUTPUT_SHA256"; exit 0;;
  --prepare-sources) prepare "$CODE" "$TZ_CODE_SHA512" "${2:-}"; prepare "$DATA" "$TZ_DATA_SHA512" "${2:-}"; exit 0;;
  --check-sources) check "$CACHE/$CODE" "$TZ_CODE_SHA512"; check "$CACHE/$DATA" "$TZ_DATA_SHA512"; [ "$USE_BUNDLE" = 0 ] || verify_tree "$BUNDLED/output"; exit 0;;
  --bundle-to)
    DEST=${2:?内置时区目录}; check "$CACHE/$CODE" "$TZ_CODE_SHA512"; check "$CACHE/$DATA" "$TZ_DATA_SHA512"
    mkdir -p "$(dirname "$DEST")"; mkdir "$DEST" || { echo '【红】内置时区目录已存在' >&2; exit 1; }
    trap 'rm -rf "$DEST"' EXIT
    cp "$CACHE/$CODE" "$CACHE/$DATA" "$DEST/"
    check "$DEST/$CODE" "$TZ_CODE_SHA512"; check "$DEST/$DATA" "$TZ_DATA_SHA512"
    S2A_TZDATA_CACHE="$CACHE" bash "$0" "$DEST/output"
    verify_tree "$DEST/output"
    trap - EXIT
    exit 0;;
esac
OUT=${1:?输出目录}; case $OUT in /*) ;; *) OUT=$PWD/$OUT;; esac
check "$CACHE/$CODE" "$TZ_CODE_SHA512"
check "$CACHE/$DATA" "$TZ_DATA_SHA512"
if [ "$USE_BUNDLE" = 1 ]; then
  verify_tree "$BUNDLED/output"
  trap 'rm -rf "$OUT.tmp"' EXIT
  rm -rf "$OUT.tmp"; mkdir -p "$OUT.tmp"
  cp -R "$BUNDLED/output/." "$OUT.tmp/"
  verify_tree "$OUT.tmp"
  rm -rf "$OUT"; mv "$OUT.tmp" "$OUT"
  echo "时区数据：App 钉版 ${TZ_VERSION}，→ $OUT"
  exit 0
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/s2a-tzdata.XXXXXXXX")
trap 'rm -rf "$WORK" "$OUT.tmp"' EXIT
mkdir -p "$WORK/src" "$WORK/zoneinfo"
tar -xzf "$CACHE/$CODE" -C "$WORK/src"
tar -xzf "$CACHE/$DATA" -C "$WORK/src"
[ "$(cat "$WORK/src/version")" = "$TZ_VERSION" ] || { echo '【红】时区源码版本与钉版不符' >&2; exit 1; }
( unset CFLAGS CPPFLAGS LDFLAGS MAKEFLAGS; make -C "$WORK/src" CFLAGS=-DHAVE_GETTEXT=0 zic >/dev/null )
"$WORK/src/zic" -b fat -d "$WORK/zoneinfo" \
  "$WORK/src/africa" "$WORK/src/antarctica" "$WORK/src/asia" "$WORK/src/australasia" \
  "$WORK/src/europe" "$WORK/src/northamerica" "$WORK/src/southamerica" "$WORK/src/etcetera" "$WORK/src/backward"
printf '%s\n' "$TZ_VERSION" > "$WORK/zoneinfo/+VERSION"
SRC=$WORK/zoneinfo
rm -rf "$OUT.tmp"; mkdir -p "$OUT.tmp/zoneinfo"
cd "$SRC"
# 只收区名文件：首字母大写的路径（排除 posix/ right/ 副本、+VERSION、*.tab、posixrules 等）
find -L . -type f | sed 's|^\./||' | grep -E '^[A-Z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$' | grep -vE '^(posix|right)/' | LC_ALL=C sort > "$OUT.tmp/binaryList.txt"
"${S2A_PYTHON:-/usr/bin/python3}" - "$SRC" "$OUT.tmp/zoneinfo" "$OUT.tmp/binaryList.txt" <<'PY'
import os, struct, sys
src, dst, lst = sys.argv[1:4]
for z in open(lst).read().split():
    b = open(os.path.join(src, z), 'rb').read()
    if b[:4] != b'TZif' or b[4:5] < b'2':
        continue                                   # 只有 v1 的文件没有 64 位段，不收
    isut, isstd, leap, time, typ, char = struct.unpack('>6l', b[20:44])
    v1 = time * 5 + typ * 6 + char + leap * 8 + isstd + isut
    v2 = b[44 + v1:]
    if v2[:4] != b'TZif':
        continue
    os.makedirs(os.path.join(dst, os.path.dirname(z)), exist_ok=True)
    open(os.path.join(dst, z), 'wb').write(v2)
PY
# binaryList 只留真拷进去的
(cd "$OUT.tmp/zoneinfo" && find . -type f ! -name '._*' ! -name .DS_Store ! -name desktop.ini ! -name Thumbs.db | sed 's|^\./||' | LC_ALL=C sort) > "$OUT.tmp/binaryList.txt"   # 系统附属文件不进区名表（同 verify_tree）
cat "$SRC/+VERSION" 2>/dev/null > "$OUT.tmp/version.txt" || true
verify_tree "$OUT.tmp"
rm -rf "$OUT"; mv "$OUT.tmp" "$OUT"
echo "时区数据：$(wc -l < "$OUT/binaryList.txt" | tr -d ' ') 个区，版本 $(cat "$OUT/version.txt" 2>/dev/null)，→ $OUT"
