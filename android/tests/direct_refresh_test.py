#!/usr/bin/env python3
"""Production refresh functions + real WSI lease; host-only, no Vulkan/device."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
def function(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

shim = (root / 'android/native/nvn/mtl_vk_shim.c').read_text()
provider = (root / 'android/native/direct/provider_vk.c').read_text()
# Production links these as two objects: the shim keeps a weak reference to the
# provider's refresh function and tests it for null. Pasted into one unit, GCC
# sees the definition and rejects that test (-Werror=address), so build two.
declarations = r'''
int mtl_has_window(void);
double mtl_display_refresh(void);
int mtl_display_hz(void);
'''
shim_unit = declarations + 'extern double s2a_direct_vk_display_refresh(void) __attribute__((weak));\n'
shim_unit += function(shim, 'double mtl_display_refresh(void)')
shim_unit += '\n' + function(shim, 'int mtl_display_hz(void)') + '\n'
test = r'''
#include <stdio.h>
#include "wsi_lease.h"
''' + declarations + r'''
struct s2a_direct_vk_context { const char *game_data_dir, *state_dir; double display_hz; const void *lease_api; };
static struct s2a_direct_vk_context g_context;
static int window_attached;
int mtl_has_window(void) { return window_attached; }
static void retain(void *window) { (void)window; }
static void release(void *window) { (void)window; }
'''
test += function(provider, 'double s2a_direct_vk_display_refresh(void)')
test += r'''
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); return 1; } } while (0)
int main(void) {
 struct s2a_wsi_window_ops ops = {retain, release};
 s2a_wsi_lease *lease = s2a_wsi_create(1, &ops);
 struct s2a_wsi_api api; s2a_wsi_api_fill(lease, &api); g_context.lease_api = &api;
 int window, insets[4] = {0};
 CHECK(mtl_display_hz() == 0);
 s2a_wsi_offer(lease, &window); window_attached = 1;
 CHECK(mtl_display_hz() == 0);
 s2a_wsi_update(lease, 100, 100, 0, insets, 119.88f);
 CHECK(mtl_display_hz() == 120);
 s2a_wsi_update(lease, 100, 100, 0, insets, 60.0f);
 CHECK(mtl_display_hz() == 60);
 s2a_wsi_update(lease, 100, 100, 0, insets, 0.0f); CHECK(mtl_display_hz() == 0);
 s2a_wsi_update(lease, 100, 100, 0, insets, -1.0f); CHECK(mtl_display_hz() == 0);
 s2a_wsi_update(lease, 100, 100, 0, insets, 60.0f);
 api.abi_version = 0; CHECK(mtl_display_hz() == 0); api.abi_version = S2A_WSI_ABI_VERSION;
 window_attached = 0; CHECK(mtl_display_hz() == 0); window_attached = 1;
 CHECK(s2a_wsi_revoke(lease, 0) == 0); CHECK(mtl_display_hz() == 0);
 s2a_wsi_offer(lease, &window); CHECK(mtl_display_hz() == 0);
 s2a_wsi_update(lease, 100, 100, 0, insets, 90.0f);
 CHECK(mtl_display_hz() == 90);
 s2a_wsi_stop(lease); CHECK(mtl_display_hz() == 0);
 s2a_wsi_destroy(lease);
 puts("direct refresh: real lease and production callbacks passed");
 return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='s2a-refresh-', dir=os.environ.get('S2A_TEST_TMP')) as tmp:
    source = Path(tmp) / 'refresh.c'; shim_source = Path(tmp) / 'shim.c'; binary = Path(tmp) / 'refresh'
    source.write_text(test); shim_source.write_text(shim_unit)
    # Darwin has no pthread_condattr_setclock; this test never blocks on a
    # timed wait, so only that unrelated clock-selection call is stubbed.
    clock_stub = Path(tmp) / 'clock_stub.h'
    clock_stub.write_text('''#ifdef __APPLE__\n#include <pthread.h>\n#include <time.h>\nstatic inline int s2a_test_condattr_setclock(pthread_condattr_t *a, clockid_t c) { (void)a; (void)c; return 0; }\n#define pthread_condattr_setclock s2a_test_condattr_setclock\n#endif\n''')
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-D_GNU_SOURCE', '-Wall', '-Wextra', '-Werror',
                    '-include', str(clock_stub), '-I' + str(root / 'android/native'), str(source), str(shim_source),
                    str(root / 'android/native/wsi_lease.c'), '-pthread', '-o', str(binary)], check=True)
    sys.exit(subprocess.run([str(binary)], timeout=10).returncode)
