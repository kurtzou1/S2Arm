// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3 && argc != 4) return 2;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!device || !queue) return 2;
        for (int k = 1; k <= 2; k++) {
            NSError *error = nil;
            id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:@(argv[k])] error:&error];
            id<MTLComputePipelineState> pipeline = library ? [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"main0"] error:&error] : nil;
            if (!pipeline) { fprintf(stderr, "%s\n", error.description.UTF8String); return 2; }
            id<MTLBuffer> output = [device newBufferWithLength:256 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
            memset(output.contents, 0, output.length);
            id<MTLCommandBuffer> command = [queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:pipeline];
            [encoder setBuffer:output offset:0 atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(256, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
            [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
            if (command.status != MTLCommandBufferStatusCompleted) return 2;
            const uint32_t *values = output.contents;
            for (uint32_t gid = 0; gid < 256; gid++) {
                uint32_t expected = gid + 1;
                // Three of each four branches execute; uint arithmetic wraps modulo 2^32.
                for (int i = 0; i < 64 * 3 / 4 * 130; i++) expected = expected * 1664525u + 1013904226u;
                if (argc == 4) expected = gid;
                if (values[gid] != expected) { fprintf(stderr, "GPU mismatch: variant=%d gid=%u expected=%u actual=%u\n", k, gid, expected, values[gid]); return 1; }
            }
        }
        puts("✓ GPU oracle: 2 libraries x 256 invocations, 0 mismatches");
    }
    return 0;
}
