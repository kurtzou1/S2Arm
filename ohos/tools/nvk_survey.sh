#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Collect an already launched OHOS session; the host owns launch, debug settings and cleanup.
# Usage: HDC_TARGET=<target> NVK_HOST_LOG=<session-log-in-sandbox> bash nvk_survey.sh <title-id> [seconds] [out]
# Offline report: NVK_INPUT_LOG=<local-log> bash nvk_survey.sh <title-id> 0 <new-out>
set -euo pipefail
title=${1:?Usage: nvk_survey.sh <16-hex-title-id> [seconds=60] [new-output-directory]}
seconds=${2:-60}
[[ $title =~ ^[0-9A-Fa-f]{16}$ ]] || { echo 'Invalid title ID' >&2; exit 2; }
[[ $seconds =~ ^[0-9]+$ && ${#seconds} -le 5 ]] || { echo 'Invalid duration' >&2; exit 2; }
out=${3:-./nvk-survey-$title-$(date +%Y%m%d-%H%M%S)}
mkdir "$out" # Never overwrite a previous session's evidence.
notes="$out/notes.txt"
: > "$notes"
note() { printf '%s\n' "$*" >> "$notes"; }
alive=unknown
shot=unavailable
model=unknown
chip=unknown
system=unknown
refresh=unknown
if [[ -n ${NVK_INPUT_LOG:-} ]]; then
  cp "$NVK_INPUT_LOG" "$out/host.log"
  note 'Offline report only: device, process, crash and screenshot were not measured.'
else
  : "${HDC_TARGET:?Set HDC_TARGET explicitly; acquire the device lock first}"
  : "${NVK_HOST_LOG:?Set the exact current session log path; do not use a previous session}"
  [[ $NVK_HOST_LOG =~ ^[a-zA-Z0-9_./-]+$ ]] || { echo 'Invalid log path' >&2; exit 2; }
  hdc=${HDC:-hdc}
  bundle=${NVK_BUNDLE:-com.xiaoboluo.s2arm.probe}
  [[ $bundle =~ ^[a-zA-Z0-9_.]+$ ]] || exit 2
  export MSYS_NO_PATHCONV=1
  h() { "$hdc" -t "$HDC_TARGET" "$@" < /dev/null; }
  collect() {
    local file=$1; shift
    if ! h "$@" > "$out/$file" 2>&1 || grep -aqE '\[Fail\]|Permission denied' "$out/$file"; then
      note "Collection failed: $file (see local raw output)."
      return 1
    fi
  }
  prop() {
    local value
    value=$(h shell param get "$1" 2>/dev/null | tr -d '\r' || true)
    if [[ -z $value || $value == *'fail!'* ]]; then printf 'unknown'; else printf '%s' "$value"; fi
  }
  model=$(prop const.product.model)
  chip=$(prop const.product.hardware)
  system=$(prop const.ohos.fullname)
  collect pid-before.txt shell pidof "$bundle" || true
  sleep "$seconds"
  if collect pid-after.txt shell pidof "$bundle"; then
    if grep -Eq '^[0-9]+( [0-9]+)*\r?$' "$out/pid-after.txt"; then alive=yes; else alive=no; fi
  fi
  if [[ -n ${NVK_SESSION_PID:-} ]]; then
    [[ $NVK_SESSION_PID =~ ^[0-9]+$ ]] || exit 2
    if [[ $alive != unknown ]] && ! tr -d '\r' < "$out/pid-after.txt" | tr ' ' '\n' | grep -qx "$NVK_SESSION_PID"; then
      alive=no
      note 'Expected session PID is absent; another process does not establish session survival.'
    fi
  fi
  # Shell output may be truncated by hdc even with a successful exit status.
  # Use the file-transfer channel for the evidence that drives this report.
  if ! h file recv -b "$bundle" "$NVK_HOST_LOG" "$out/host.log" > "$out/host-transfer.txt" 2>&1 ||
    grep -aq '\[Fail\]' "$out/host-transfer.txt" || [[ ! -s $out/host.log ]]; then
    note 'Collection failed: host.log (see host-transfer.txt).'
    : > "$out/host.log"
  fi
  # System buffers can contain other sessions. They are local context, never the report's counters.
  collect hilog.txt shell hilog -x || true
  collect crash.txt shell ls -lt /data/log/faultlog/faultlogger || true
  collect display.txt shell hidumper -s RenderService -a screen || true
  refresh=$(grep -aiE 'refresh|fps' "$out/display.txt" | head -1 || true)
  remote=/data/local/tmp/nvk-survey-$(date +%Y%m%d-%H%M%S)-$$.jpeg
  if collect screenshot-command.txt shell snapshot_display -f "$remote"; then
    if h file recv "$remote" "$out/screen.jpeg" > "$out/screenshot-transfer.txt" 2>&1 &&
      [[ $(od -An -tx1 -N3 "$out/screen.jpeg" | tr -d ' \n\r') == ffd8ff ]]; then
      shot='screen.jpeg (local only; do not upload)'
    else
      note 'Screenshot unavailable or invalid; transfer output is local evidence only.'
    fi
  fi
  note 'Caller must clear its debug-env settings and stop its session after collection.'
fi
grep -a -v 'prev|' "$out/host.log" > "$out/current.log" || true
g() { grep -a "$@" "$out/current.log" || true; }
session=$(g -E 'nvk session: backend open|graphics selection' | tail -2)
unimpl=$(g -E 'nvk unimpl|未接：')
red=$(g '【红】' | grep -v '未接：' | sort | uniq -c || true)
fatal=$(g -E 'fatal signal|Fatal signal|SIGABRT|SIGSEGV')
progress=$(g -F '[OHOS fpslog]' | tail -3)
present=$(g -E 'nvk present: 分时：|nvk session: presents' | tail -1)
[[ -n $present ]] || present=$(g 'nvk present:' | tail -1)
g 'nvk session: backend open' | grep -q . || note 'No backend-open evidence: this report does not establish that the new backend ran.'
{
  echo '# 新图形层设备普查（OHOS）'
  echo
  echo '| 项 | 值 |'
  echo '|---|---|'
  printf '| 机型 | %s |\n| 芯片 | %s |\n| 系统 | %s |\n| 刷新率 | %s |\n' "${model:-unknown}" "${chip:-unknown}" "${system:-unknown}" "${refresh:-unknown}"
  printf '| 程序号 | %s |\n| 观察秒数 | %s |\n| 进程还在 | %s |\n' "$title" "$seconds" "$alive"
  for section in session unimpl red fatal present progress; do
    case $section in
      session) echo '## 选路与会话';;
      unimpl) echo '## 未接清单（没有行不等于零种）';;
      red) echo '## 其它红行';;
      fatal) echo '## 本会话致命信号（没有行不等于没有崩溃）';;
      present) echo '## 最后一行呈现读数';;
      progress) echo '## 最近宿主帧进展（用于识别停止上屏后的旧读数）';;
    esac
    echo '```'
    printf '%s\n' "${!section:-未取得读数}"
    echo '```'
  done
  echo '## 截图'
  echo "$shot"
  echo '## 进程与崩溃'
  echo "进程状态：${alive}。若采集了 crash.txt，它只是故障文件目录，不代表已证明无崩溃；由采集者补充本进程对应日志。"
  echo '## 提示'
  cat "$notes"
  echo '发布前人工检查本页：删除本机路径、设备标识、程序名称及敏感信息。原始日志和截图仅留本地。'
} > "$out/report.md"
cat "$out/report.md"
