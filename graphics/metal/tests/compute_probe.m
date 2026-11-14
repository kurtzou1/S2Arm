// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// Standalone diagnostic executable, not an engine source.
// Match nvn/pso_archive.h par_compute_: a compute function, default descriptor, no archives.
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSError *error = nil;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&error];
        id<MTLFunction> function = [library newFunctionWithName:@(argv[2])];
        if (!function) { fprintf(stderr, "Cannot load compute function: %s\n", error.description.UTF8String); return 2; }
        MTLComputePipelineDescriptor *descriptor = [MTLComputePipelineDescriptor new];
        descriptor.computeFunction = function;
        fprintf(stderr, "compute begin: %s, no archives\n", function.name.UTF8String);
        uint64_t start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error];
        fprintf(stderr, "compute end: success=%d seconds=%.6f error=%s\n", pipeline != nil,
                (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start) / 1e9, error ? error.description.UTF8String : "none");
        return pipeline ? 0 : 1;
    }
}
