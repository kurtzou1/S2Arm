// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// OHOS platform capability implementation for .NET NativeAOT's NUMA boundary.
// ABI: dotnet/runtime src/coreclr/gc/unix/numasupport.h (10.0.x).
// The standard single-node GC path remains in use. OHOS application sandboxes
// reject get_mempolicy with SIGSYS; do not probe it or report NUMA as available.
#include <errno.h>
#include <stdio.h>

extern "C" {
int g_highestNumaNode = 0;
bool g_numaAvailable = false;
}

void NUMASupportInitialize() {
    g_highestNumaNode = 0;
    g_numaAvailable = false;
    fputs("[s2a] OHOS NativeAOT: NUMA policy unavailable; standard non-NUMA GC\n", stderr);
}

int GetNumaNodeNumByCpu(int) {
    errno = ENOTSUP;
    return -1;
}

long BindMemoryPolicy(void *, unsigned long, const unsigned long *, unsigned long) {
    errno = ENOTSUP;
    return -1;
}
