<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 S2Arm contributors -->
# OHOS replay platform

Compile `plat_nvn.c`, `plat_nvn_vk.c`, and `vsync.c` with the OHOS SDK. Include
`graphics/nvn/replay` and `graphics/nvn/gfx/nvn`; link `hilog_ndk.z`, Vulkan and
the system C/thread library. Do **not** add `stub/` to a production include path.
This directory implements the shared platform API, including version 2's safepoint.
It does not ship a launcher, runtime, signed modules or session assembly copies.

The host must wire the private declarations in `plat_ohos.h`:

1. Before opening each session, call `nvn_ohos_set_dirs(state_root, files_root)`
   with existing per-title state and application files directories; check its result.
   It creates `nvk-cache` and `diag` respectively. NULL disables that output.
   Previously returned directory strings remain valid until process exit. Reusing
   the same roots reuses their strings; one allocation is retained per unique path.
2. Publish the leased native window and physical pixel size through
   `nvn_ohos_set_window`; update on resize, clear before releasing the window.
   Window size reads never query or dereference a released window. Surface creation
   still requires the caller to hold the native window lease.
3. If the runtime performs stop-the-world memory mapping transactions, register
   its host safepoint through `nvn_ohos_set_safepoint` before replay starts. A NULL
   callback is only appropriate for hosts without those transactions. No runtime
   headers or weak platform-name aliases are hidden in this implementation.

Use the existing `nvk_session.c`, `provider_nvk.c` and `nvk_shader.c` from
`android/native/gfx_plat/` directly in the host's build; do not copy them here.
Do not compile that directory's platform or display-tick implementations alongside
these replacements. Additional frontend host symbols (profile, operation mode,
diagnostic path) remain the host integration's responsibility. This syntax gate
does not prove that the session assembly links on OHOS.

`nvn_plat_flag` maps `nvk_drawlog` to `DEBUG_S2A_NVK_DRAWLOG`, converts ASCII
letters to uppercase and dots to underscores. Unset, empty, invalid or overflowing
integer values return the caller's default. The host loads debug-env before session
start and must not mutate the environment while replay is active. Logs use
`nvk <class>: <text>` in hilog and stderr, with `【红】` for errors.

The initial display tick implementation returns -1 and explains why; no callback is
registered, so stop has nothing to drain. The core's timed pacing fallback remains
responsible for scheduling. Surface creation requests `VK_KHR_surface` and
`VK_OHOS_surface`, resolves `vkCreateSurfaceOHOS` through the actual instance and
returns failures with a null output handle.

## Offline gate

Run `bash ohos/native/gfx_plat/gate.sh` with a host C11 compiler (`CC` selects the
executable). It syntax-checks all three production sources against the actual
shared API headers. The small stubs supply only OHOS declarations and a Vulkan
umbrella; Vulkan core types come from the vendored Khronos headers. No download,
GPU, device, linking or SDK is needed. Separately compile with the real OHOS SDK;
host stubs cannot validate the SDK ABI or rendering.

## Survey

The host owns launching an imported program and restoring its debug settings.
After acquiring the device, start a session and use its **exact fresh host log**:

```sh
HDC_TARGET='<target>' NVK_HOST_LOG='<sandbox-session-log>' \
  bash ohos/tools/nvk_survey.sh '<16-hex-program-id>' 60 '<new-output-directory>'
```

Set `HDC` for an executable outside PATH. `NVK_BUNDLE` defaults to the probe package.
Set `NVK_SESSION_PID` to the launched session's PID to avoid counting a restarted
process as survival. Host logs use file transfer: a device run returned only
137742 bytes through shell output from a 209986-byte closed log; file transfer
matched the complete log byte-for-byte, including its fatal-signal tail.
The collector does not install, launch, change debug settings, clear log buffers or
delete data. It observes the running session, reads hilog as context, collects a
local screenshot and writes the seven survey items. Missing readings remain
unknown, including an empty unimplemented list. System-wide hilog and fault file
listings are not attributed to this session as proof. Stop the session and restore
debug settings in the host harness afterwards. Never upload screenshots or raw logs;
review/redact report text before publication.
The last presentation timing can predate a stalled renderer. Check the recent
host frame-progress samples and fatal signals as well as process existence.

For offline parser checks, set `NVK_INPUT_LOG` to a local session log and pass a
duration of 0. Device fields are explicitly unknown in this mode. A report without
`backend open` is not evidence of a successful new-backend session.
