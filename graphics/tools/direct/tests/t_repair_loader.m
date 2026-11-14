// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// The test exercises the production container reader, reflection and shader_build/ulibs cache.
// It supplies only a real Metal device, not the native host or the NVN command-recording layer.
// Unused host paths are dead-stripped or dynamically linked; the raster flag is never accessed here.
#pragma weak s2a_nvn_rast_flip
#ifndef NVN_REPAIR_SOURCE
#define NVN_REPAIR_SOURCE "../../../nvn/gfx/nvn/nvn_mtl.m"
#endif
#include NVN_REPAIR_SOURCE

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3 || (strcmp(argv[2], "0") && strcmp(argv[2], "1"))) return 2;
        g_dev = MTLCreateSystemDefaultDevice();
        g_msl_dir = @(argv[1]);
        if (!g_dev) return 2;
        const char *keys[] = {"1111111111111111_b", "2222222222222222_b"};
        int order = atoi(argv[2]);
        for (int n = 0; n < 2; n++) {
            int key = order ? 1 - n : n;
            NvShader *shader = shader_build(@(keys[key]), 5, 0, 0);
            if (!shader || !shader->fn) {
                fprintf(stderr, "loader failed key=%s\n", keys[key]);
                return 1;
            }
            NSError *error = nil;
            id<MTLComputePipelineState> pipeline = [g_dev newComputePipelineStateWithFunction:shader->fn error:&error];
            if (!pipeline) {
                fprintf(stderr, "pipeline failed: %s\n", error.description.UTF8String);
                return 2;
            }
            id<MTLBuffer> output = [g_dev newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
            id<MTLCommandQueue> queue = [g_dev newCommandQueue];
            if (!output || !queue) return 2;
            *(uint32_t *)output.contents = 0;
            id<MTLCommandBuffer> command = [queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            if (!command || !encoder) return 2;
            [encoder setComputePipelineState:pipeline];
            [encoder setBuffer:output offset:0 atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            [encoder endEncoding];
            [command commit];
            [command waitUntilCompleted];
            if (command.status != MTLCommandBufferStatusCompleted) return 2;
            uint32_t expected = key ? 22 : 33, actual = *(uint32_t *)output.contents;
            printf("order=%d key=%s function=%s expected=%u actual=%u\n", order, keys[key], shader->fn.name.UTF8String, expected, actual);
            if (actual != expected) return 1;
        }
    }
    return 0;
}
