// Link with the real host and NativeAOT service library (native-graphics-session-probe).
// No replacement host symbols: exercises real Metal and production stop/reset APIs.
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include "../gfx/nvn/nvn_obj.h"
#include "../gfx/nvn/nvn_mtl.h"
#include "../gfx/tex/nvn_deswizzle.h"
#include "../../metal/gal_abi.h"
#include "../graphics_session.h"

uint64_t nvn_new_serial(void);
int s2a_test_gl_session_resources(unsigned rounds);
int s2a_test_vk_session_resources(unsigned rounds);
int s2a_test_vk_bc(void);   // 块压缩贴图上传（S2A_TEST_VK_BC=1 时只跑它；再配 DM_TEST_NO_BC=1 走解码路径）

int main(void) {
    @autoreleasepool {
        if (getenv("S2A_TEST_VK_BC")) return s2a_test_vk_bc();
        // Deliberately reuse this exact guest address in every generation.
        // A prior GPU-write page mark must not suppress the next run's initial bytes.
        uint8_t *pool = mmap(NULL, 1 << 20, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        assert(pool != MAP_FAILED);
        for (int round = 1; round <= 10; round++) {
            assert(s2a_graphics_native_begin_session() == 0);
            memset(pool, 0, 1 << 20);
            for (int i = 0; i < 4096; i++) pool[i] = (uint8_t)(i * 131 + round);
            nvn_be_pool_add(pool, 1 << 20);
            volatile uint32_t completed = 0;
            nvn_be_sub_begin();
            mtl_sub_copy((uintptr_t)pool, (uintptr_t)pool + 16384, 4096);
            mtl_sub_event(&completed, 0, (uint32_t)round);
            uint64_t f = nvn_be_sub_commit();
            assert(nvn_be_wait(f, 5000000000ull));
            assert(completed == (uint32_t)round && !memcmp(pool, pool + 16384, 4096));

            pool_t descriptor = {MAGIC('P', 'O', 'O', 'L'), NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, pool, 1 << 20};
            tex_t texture = {0}; texture.magic = MAGIC('T', 'E', 'X', 0);
            texture.d = (nvn_texdesc){NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA8, 0, 0, 32, 32, 1, 1, 0, 0};
            nvn_tex_layout(&texture.d, &texture.L);
            texture.pool = &descriptor; texture.mem = pool; texture.serial = nvn_new_serial();
            nvn_be_tex_init(&texture); nvn_be_reg_tex(7, &texture, NULL);
            uint8_t got[4096], expected[4096];
            NVNcopyRegion r = {0, 0, 0, 32, 32, 1};
            nvn_be_sub_begin();
            nvn_be_read_texels(&texture, 0, 0, &r, got, 32 * 4, sizeof got);
            f = nvn_be_sub_commit(); assert(nvn_be_wait(f, 5000000000ull));
            assert(nvn_deswizzle(&texture.d, 0, 0, pool, expected, 32 * 4) == 0);
            assert(!memcmp(got, expected, sizeof got));

            struct { op_hdr header; p_clear_tex payload; op_hdr end; } clear = {
                .header = {OP_CLEAR_TEX, sizeof(op_hdr) + sizeof(p_clear_tex)},
                .payload = {.tex = &texture, .r = {0, 0, 0, 32, 32, 1}, .mask = 15, .c.f = {1, 0, 0, 1}},
                .end = {OP_END, sizeof(op_hdr)}
            };
            _Static_assert(offsetof(__typeof__(clear), end) == sizeof(op_hdr) + sizeof(p_clear_tex), "record alignment");
            nvn_be_sub_begin(); nvn_be_exec((const uint8_t *)&clear);
            f = nvn_be_sub_commit(); assert(nvn_be_wait(f, 5000000000ull));
            nvn_be_sub_begin(); nvn_be_read_texels(&texture, 0, 0, &r, got, 32 * 4, sizeof got);
            f = nvn_be_sub_commit(); assert(nvn_be_wait(f, 5000000000ull));
            for (size_t pixel = 0; pixel < sizeof got; pixel += 4)
                assert(got[pixel] == 255 && got[pixel + 1] == 0 && got[pixel + 2] == 0 && got[pixel + 3] == 255);

            assert(s2a_graphics_native_restart_check() == 0);
            assert(s2a_graphics_native_request_stop() == 0);
            assert(s2a_graphics_native_shutdown_session() == 0);
            mtl_res_count counts; mtl_res_snapshot(&counts);
            assert(!counts.pools && !counts.live_tex && !counts.view_nonnull && !counts.view_slots && !counts.sview_nonnull);

            // Same process now creates a generic renderer session. Native
            // resource tables must coexist empty and rebuild in either order.
            assert(s2a_graphics_native_begin_session() == 0);
            assert(nxgal_init(0) == 0);
            uint32_t buffer = nxgal_buf_create(4096, 0); assert(buffer);
            nxgal_buf_set_data(buffer, 0, expected, sizeof expected);
            memset(got, 0, sizeof got);
            assert(nxgal_buf_get_data(buffer, 0, sizeof got, got) == 0 && !memcmp(got, expected, sizeof got));
            assert(s2a_graphics_native_request_stop() == 0); nxgal_request_stop();
            assert(nxgal_shutdown_session() == 0);
            assert(s2a_graphics_native_shutdown_session() == 0);
            fprintf(stderr, "[graphics-session] %d/10 NVN + GAL readback/reset passed\n", round);
        }
        assert(munmap(pool, 1 << 20) == 0);
    }
    assert(s2a_test_gl_session_resources(10) == 0);
    assert(s2a_test_vk_session_resources(10) == 0);
    // A terminal process-exit choice cannot later become a restart, even with
    // empty tables. This process creates no guest and has retired its resources.
    s2a_graphics_native_seal_process_exit();
    assert(s2a_graphics_native_begin_session() != 0);
    assert(s2a_graphics_native_restart_check() != 0);
    assert(s2a_graphics_native_shutdown_session() != 0);
    return 0;
}
