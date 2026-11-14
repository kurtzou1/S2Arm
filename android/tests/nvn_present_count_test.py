#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Compile the production NVN present path with fake Vulkan/window dependencies."""
from pathlib import Path
import argparse
import os
import re
import shlex
import subprocess
import sys
import tempfile

import host_link

root = Path(__file__).resolve().parents[2]
shim_path = 'android/native/nvn/mtl_vk_shim.c'
parser = argparse.ArgumentParser()
source_group = parser.add_mutually_exclusive_group()
source_group.add_argument('--source-ref', help='read the production shim at this git revision')
source_group.add_argument('--source', type=Path, help='read the production shim from this source file')
args = parser.parse_args()
if args.source_ref:
    shim_text = subprocess.check_output(
        ['git', 'show', f'{args.source_ref}:{shim_path}'], cwd=root, text=True
    )
elif args.source:
    shim_text = args.source.read_text(encoding='utf-8')
else:
    shim_text = (root / shim_path).read_text(encoding='utf-8')


def function(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    pos = opening + 1
    state = 'code'
    while depth:
        char = text[pos]
        following = text[pos + 1] if pos + 1 < len(text) else ''
        if state == 'line-comment':
            if char == '\n':
                state = 'code'
        elif state == 'block-comment':
            if char == '*' and following == '/':
                state = 'code'
                pos += 1
        elif state in ('string', 'character'):
            if char == '\\':
                pos += 1
            elif (state == 'string' and char == '"') or (state == 'character' and char == "'"):
                state = 'code'
        elif char == '/' and following == '/':
            state = 'line-comment'
            pos += 1
        elif char == '/' and following == '*':
            state = 'block-comment'
            pos += 1
        elif char == '"':
            state = 'string'
        elif char == "'":
            state = 'character'
        elif char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
        pos += 1
    return text[start:pos]


counter_decl_match = re.search(r'(?m)^static (?:_Atomic )?uint64_t g_present_n;$', shim_text)
if not counter_decl_match:
    raise SystemExit('FAIL: production g_present_n declaration was not found')
counter_decl = counter_decl_match.group(0)
present_body = function(shim_text, 'uint64_t mtl_present(const tex_t *t, double period_s, const int crop[4])')
getter = function(shim_text, 'uint64_t mtl_present_count(void)')
window_header = (root / 'android/native/nvn/nvn_vk_first_draw.h').read_text(encoding='utf-8')
window_struct = function(window_header, 'struct nvn_vk_open_window {') + ';'

PRELUDE = r'''
#include <pthread.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>
#include <time.h>

#define OP_DRAW 25
#define OP_DRAW_IDX 26
#define OP_SET_RT 1
#define OP_CLEAR_COLOR 2
#define OP_CLEAR_DS 3
#define OP_CLEAR_TEX 4
#define OP_CLEAR_BUF 5
#define OP_COPY_B2B 6
#define OP_COPY_T2B 7
#define OP_COPY_B2T 8
#define OP_COPY_T2T 9
#define OP_DISPATCH 10
#define OP_BARRIER 11
#define OP_FENCE_SYNC 12
#define OP_SIGNAL_EVENT 13
#define OP_REPORT_COUNTER 14
#define S2A_OW_SEG_ENTRY_MODULES 0
#define S2A_OW_SEG_PASS 1
#define S2A_OW_SEG_PIPE 2
#define S2A_OW_SEG_RES 3
#define S2A_OW_SEG_VBUF 4
#define S2A_OW_SEG_DESC_CMD 5
#define S2A_OW_SEG_MAX 6

typedef struct { uint32_t width, height; } present_tex_desc;
typedef struct { present_tex_desc d; } tex_t;
PRODUCTION_WINDOW_STRUCT

static _Atomic uint64_t g_frame_seq, g_replayed_fence;
static uint64_t g_lost_from_fence;
static double g_present_at[256];
static uint64_t g_frame_exec_ns, g_frame_cmds, g_op_ns[256], g_op_n[256];
static int fixture_window = 1, fixture_present_result;
static int fixture_jump_ready;
static jmp_buf fixture_error_jump;

extern void nvn_vk_pcprof_tick(void) __attribute__((weak));
extern void s2a_adpf_discard(void) __attribute__((weak));
extern void s2a_adpf_invisible(void) __attribute__((weak));
extern void s2a_adpf_frame_end(int64_t, uint64_t) __attribute__((weak));
extern int s2a_direct_vk_sync_window(void) __attribute__((weak));
extern int s2a_direct_vk_try_attach_window(void) __attribute__((weak));

static void info(const char *fmt, ...) { (void)fmt; }
static void red(const char *fmt, ...) {
    (void)fmt;
    if (fixture_jump_ready) longjmp(fixture_error_jump, 1);
}
static void nvk_require(void) {}
static void shim_frame_settle(void) {}
static void shim_drain(void) {}
static uint64_t shim_now_ns(void) { static uint64_t now; return ++now; }
static double shim_ticks_ns(uint64_t ticks) { return (double)ticks; }
static int shim_win_stats_on(void) { return 0; }
static int shim_is_draw_op(uint32_t op) { return op == OP_DRAW || op == OP_DRAW_IDX; }
static void shim_note_completed(uint64_t fence) { (void)fence; }
static int mtl_has_window(void) { return fixture_window; }
static int s2a_vk_adapter_present_tex(const tex_t *t, const int crop[4], char *why, size_t why_size) {
    (void)t; (void)crop; (void)why; (void)why_size;
    return fixture_present_result;
}
static int s2a_vk_adapter_skip_present(void) { return 0; }
static void s2a_vk_adapter_exec_lock_stats(uint64_t *wait_ns, uint64_t *calls) {
    if (wait_ns) *wait_ns = 0;
    if (calls) *calls = 0;
}
static void nvn_vk_first_draw_take_open_window(struct nvn_vk_open_window *out) {
    memset(out, 0, sizeof *out);
}
static void nvn_vk_first_draw_take_cmd_stats(uint64_t *reset, uint64_t *alloc) {
    if (reset) *reset = 0;
    if (alloc) *alloc = 0;
}
'''

HARNESS = r'''
static int failures;
#define CHECK(condition, label) do { \
    if (!(condition)) { fprintf(stderr, "FAIL %s\n", label); failures++; } \
} while (0)
static tex_t fixture_tex;

static void run_case(const char *scenario) {
    fixture_window = 1;
    fixture_present_result = 0;
    if (!strcmp(scenario, "success")) {
        CHECK(mtl_present(&fixture_tex, 1.0 / 60.0, NULL) == 1, "success ticket is one");
        CHECK(mtl_present_count() == 1, "success present increments exactly once");
    } else if (!strcmp(scenario, "window")) {
        fixture_window = 0;
        CHECK(mtl_present(&fixture_tex, 1.0 / 60.0, NULL) == 0, "missing window is skipped");
        CHECK(mtl_present_count() == 0, "missing window does not increment");
    } else if (!strcmp(scenario, "timeout")) {
        fixture_present_result = 1;
        CHECK(mtl_present(&fixture_tex, 1.0 / 60.0, NULL) == 0, "acquire timeout is skipped");
        CHECK(mtl_present_count() == 0, "acquire timeout does not increment");
    } else if (!strcmp(scenario, "error")) {
        fixture_present_result = -7;
        fixture_jump_ready = 1;
        if (setjmp(fixture_error_jump) == 0) {
            (void)mtl_present(&fixture_tex, 1.0 / 60.0, NULL);
            CHECK(0, "adapter error takes the production red path");
        }
        fixture_jump_ready = 0;
        CHECK(mtl_present_count() == 0, "adapter error does not increment");
    } else {
        CHECK(0, "unknown scenario");
    }
}

struct readers_state {
    _Atomic int ready;
    _Atomic int done;
    _Atomic int regressed;
};
static void *read_present_count(void *opaque) {
    struct readers_state *state = opaque;
    uint64_t previous = 0;
    atomic_fetch_add_explicit(&state->ready, 1, memory_order_relaxed);
    do {
        uint64_t current = mtl_present_count();
        if (current < previous) atomic_store_explicit(&state->regressed, 1, memory_order_relaxed);
        previous = current;
    } while (!atomic_load_explicit(&state->done, memory_order_relaxed));
    uint64_t final = mtl_present_count();
    if (final < previous) atomic_store_explicit(&state->regressed, 1, memory_order_relaxed);
    return NULL;
}

static int run_concurrent(void) {
    enum { READER_COUNT = 4, PRESENT_COUNT = 5000 };
    struct readers_state state = {0};
    pthread_t readers[READER_COUNT];
    for (int i = 0; i < READER_COUNT; i++) {
        if (pthread_create(&readers[i], NULL, read_present_count, &state) != 0) return 2;
    }
    while (atomic_load_explicit(&state.ready, memory_order_relaxed) != READER_COUNT) { }
    for (int i = 0; i < PRESENT_COUNT; i++)
        (void)mtl_present(&fixture_tex, 1.0 / 60.0, NULL);
    atomic_store_explicit(&state.done, 1, memory_order_relaxed);
    for (int i = 0; i < READER_COUNT; i++) pthread_join(readers[i], NULL);
    CHECK(!atomic_load_explicit(&state.regressed, memory_order_relaxed), "concurrent reads are monotonic");
    CHECK(mtl_present_count() == PRESENT_COUNT, "concurrent producer reaches exact count");
    return failures ? 1 : 0;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (!strcmp(argv[1], "concurrent")) return run_concurrent();
    run_case(argv[1]);
    return failures ? 1 : 0;
}
'''


def compile_present_fixture(directory, name, body):
    source = PRELUDE.replace('PRODUCTION_WINDOW_STRUCT', window_struct) + '\n' + counter_decl + '\n' + body + '\n' + getter + '\n' + HARNESS
    c_file = directory / f'{name}.c'
    exe = directory / name
    c_file.write_text(source, encoding='utf-8')
    command = shlex.split(os.environ.get('CC', 'cc')) + [
        '-std=gnu11', '-O1', '-Wall', '-Wextra', '-Werror', '-pthread',
        str(c_file), '-o', str(exe),
    ]
    result = host_link.run(command, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f'{name}: fixture compile failed (not a behavior result)\n{result.stdout}{result.stderr}')
    return exe


def run_expected(executable, scenario, expected_failure=None):
    result = subprocess.run([str(executable), scenario], capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    if expected_failure is None:
        if result.returncode:
            raise RuntimeError(f'{scenario}: production behavior failed\n{output}')
    elif result.returncode != 1 or expected_failure not in output:
        raise RuntimeError(
            f'{scenario}: expected functional assertion failure {expected_failure!r}, '
            f'got rc={result.returncode}\n{output}'
        )




def export_fixture(direct_text, directory, producer_kind, withdraw_replay=False):
    weak_decls = [
        'extern uint64_t mtl_present_count(void) __attribute__((weak));',
        'extern void rp_present_stats(uint64_t *shown, uint64_t *dropped) __attribute__((weak));',
    ]
    for declaration in weak_decls:
        if direct_text.count(declaration) != 1:
            raise RuntimeError('production weak producer declaration is absent or duplicated')
    export = function(direct_text, 'uint64_t s2a_android_nvn_present_count(void)')
    if withdraw_replay:
        original = 'if (rp_present_stats)'
        if export.count(original) != 1:
            raise RuntimeError('production replay priority mutation anchor changed')
        export = export.replace(original, 'if (0 && rp_present_stats)')
    main = r"""
int main(void) {
    fixture_legacy_count = 11; fixture_replay_count = 31;
    if (s2a_android_nvn_present_count() != EXPECT_FIRST) { fprintf(stderr, "FAIL replay priority/count\n"); return 1; }
    fixture_legacy_count = 22; fixture_replay_count = 42;
    if (s2a_android_nvn_present_count() != EXPECT_SECOND) { fprintf(stderr, "FAIL replay priority/count\n"); return 1; }
    if (legacy_calls != EXPECT_LEGACY_CALLS || replay_calls != EXPECT_REPLAY_CALLS) return 1;
#ifdef WITH_REPLAY
    fixture_replay_count = 0;
    if (s2a_android_nvn_present_count() != 0 || legacy_calls != 0 || replay_calls != 3) {
        fprintf(stderr, "FAIL replay zero must not use legacy\n"); return 1;
    }
#endif
    return 0;
}
"""
    source = '#include <stdint.h>\n#include <stddef.h>\n#include <stdio.h>\n' + '\n'.join(weak_decls) + r"""
uint64_t fixture_legacy_count, fixture_replay_count;
int legacy_calls, replay_calls;
""" + export + main
    provider = r"""
#include <stdint.h>
extern uint64_t fixture_legacy_count, fixture_replay_count;
extern int legacy_calls, replay_calls;
#ifdef WITH_LEGACY
uint64_t mtl_present_count(void) { legacy_calls++; return fixture_legacy_count; }
#endif
#ifdef WITH_REPLAY
void rp_present_stats(uint64_t *shown, uint64_t *dropped) {
    replay_calls++;
    if (shown) *shown = fixture_replay_count;
    if (dropped) *dropped = 0;
}
#endif
"""
    kind = {'absent': (0, 0, 0, 0), 'legacy': (11, 22, 2, 0),
            'replay': (31, 42, 0, 2), 'both': (31, 42, 0, 2)}[producer_kind]
    first, second, old_calls, new_calls = kind
    c_file = directory / f'export-{producer_kind}.c'
    producer_file = directory / f'producer-{producer_kind}.c'
    exe = directory / f'export-{producer_kind}'
    c_file.write_text(source, encoding='utf-8')
    producer_file.write_text(provider, encoding='utf-8')
    command = shlex.split(os.environ.get('CC', 'cc')) + [
        '-std=gnu11', '-Wall', '-Wextra', '-Werror',
        f'-DEXPECT_FIRST={first}', f'-DEXPECT_SECOND={second}',
        f'-DEXPECT_LEGACY_CALLS={old_calls}', f'-DEXPECT_REPLAY_CALLS={new_calls}',
    ]
    if producer_kind in ('legacy', 'both'): command.append('-DWITH_LEGACY')
    if producer_kind in ('replay', 'both'): command.append('-DWITH_REPLAY')
    command.extend([str(c_file), str(producer_file), '-o', str(exe)])
    result = host_link.run(command, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f'{producer_kind}: fixture compile failed (not a behavior result)\n{result.stdout}{result.stderr}')
    run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
    if withdraw_replay:
        if run.returncode != 1 or 'FAIL replay priority/count' not in run.stderr:
            raise RuntimeError('withdraw replay priority did not fail its behavior assertion')
        print('withdraw replay priority: expected assertion failure')
    elif run.returncode:
        raise RuntimeError(f'FAIL: {producer_kind} producer result/priority mismatch\n{run.stdout}{run.stderr}')


DIRECT_SOURCE = (root / 'android/native/direct_session.c').read_text(encoding='utf-8')
with tempfile.TemporaryDirectory(prefix='nvn-present-count-', dir=os.environ.get('S2A_TEST_TMP')) as tmp:
    temp = Path(tmp)
    production = compile_present_fixture(temp, 'production', present_body)
    for case in ('success', 'window', 'timeout', 'error'):
        run_expected(production, case)

    if '_Atomic uint64_t' in counter_decl:
        run_expected(production, 'concurrent')
    count_read = 'atomic_load_explicit(&g_present_n, memory_order_relaxed)' if '_Atomic' in counter_decl else 'g_present_n'
    count_add = 'atomic_fetch_add_explicit(&g_present_n, 1, memory_order_relaxed);' if '_Atomic' in counter_decl else '++g_present_n;'

    increment = re.search(r'(?m)^\s*uint64_t n = [^;]*g_present_n[^;]*;$', present_body)
    timeout_boundary = re.search(
        r'(\n\s*shim_frame_settle\(\);   // 帧边界：acquire 超时也结清本帧\n)(\s*return 0;)',
        present_body,
    )
    if not increment or not timeout_boundary:
        raise RuntimeError('production present mutation anchors changed')
    no_success_increment = present_body[:increment.start()] + \
        f'    uint64_t n = {count_read};' + \
        present_body[increment.end():]
    removed_increment = compile_present_fixture(temp, 'removed-success-increment', no_success_increment)
    run_expected(removed_increment, 'success', 'FAIL success present increments exactly once')

    wrong_path = present_body[:increment.start()] + \
        f'    uint64_t n = {count_read};' + \
        present_body[increment.end():]
    timeout_boundary = re.search(
        r'(\n\s*shim_frame_settle\(\);   // 帧边界：acquire 超时也结清本帧\n)(\s*return 0;)',
        wrong_path,
    )
    wrong_path = wrong_path[:timeout_boundary.start(2)] + \
        f'\n        {count_add}' + \
        wrong_path[timeout_boundary.start(2):]
    wrong_increment = compile_present_fixture(temp, 'wrong-path-increment', wrong_path)
    run_expected(wrong_increment, 'timeout', 'FAIL acquire timeout does not increment')

    for kind in ('absent', 'legacy', 'replay', 'both'):
        export_fixture(DIRECT_SOURCE, temp, kind)
    export_fixture(DIRECT_SOURCE, temp, 'both', withdraw_replay=True)

print('PASS: production mtl_present/getter/declaration behavior; 4 present paths; '
      + ('4 concurrent readers / 5000 successful submissions; ' if '_Atomic' in counter_decl else 'baseline non-atomic concurrency NOT RUN; ')
      + '3 functional mutation controls; weak producers absent/legacy/replay/both')
