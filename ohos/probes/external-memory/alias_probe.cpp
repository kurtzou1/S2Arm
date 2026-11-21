// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <csignal>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
extern "C" {
#include "track_platform.h"
}
extern "C" int plat_vm_alias(void *dst, const void *src, size_t size, uint32_t prot);
// v0.1.0 track_platform has no retarget entry; the probe keeps its own on top of plat_vm_alias.
static int s2a_track_platform_realias(void *alias, uintptr_t address, size_t size, int protection) {
    size_t page=(size_t)sysconf(_SC_PAGESIZE);
    uintptr_t target=(uintptr_t)alias;
    if(!alias || !page || !size || address%page || target%page || size%page
        || size>UINTPTR_MAX-address || size>UINTPTR_MAX-target
        || (target<address+size && address<target+size)
        || (protection!=PROT_READ && protection!=(PROT_READ|PROT_WRITE))) return EINVAL;
    return plat_vm_alias(alias,(const void*)address,size,1u|(protection&PROT_WRITE?2u:0u));
}
static void timeout(int) { const char s[]="ALIAS_PROBE result=TIMEOUT\n"; write(2,s,sizeof(s)-1); _exit(124); }
static uint64_t now() { timespec t{};clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000+t.tv_nsec; }
static unsigned char value(unsigned page,size_t byte,unsigned epoch) { return (unsigned char)(page*31+byte*7+epoch*19); }
int s2a_alias_read_probe() {
    signal(SIGALRM,timeout);alarm(15);
    size_t pg=(size_t)sysconf(_SC_PAGESIZE);
    if(pg<4096 || pg>65536 || (pg&(pg-1))) return 2;
    constexpr unsigned N=64, Rounds=16;
    void* source[N]{};
    for(unsigned j=0;j<N;j++) {
        // Independently allocated shared backings, never a single cross-VMA remap.
        source[j]=mmap(nullptr,pg,PROT_READ|PROT_WRITE,MAP_SHARED|MAP_ANONYMOUS,-1,0);
        if(source[j]==MAP_FAILED) return 3;
        for(size_t k=0;k<pg;k++) ((unsigned char*)source[j])[k]=value(j,k,0);
        if(mprotect(source[j],pg,PROT_NONE)) return 4;
    }
    uint64_t elapsed[2]{};unsigned reserves[2]{},retargets[2]{},releases[2]{};
    for(unsigned round=0;round<Rounds;round++) for(unsigned order=0;order<2;order++) {
        unsigned reuse=(round+order)&1; // Alternate order to avoid one fixed warmup advantage.
        void* alias=nullptr;uint64_t start=now();
        for(unsigned j=0;j<N;j++) {
            int rc;
            if(alias) {rc=s2a_track_platform_realias(alias,(uintptr_t)source[j],pg,PROT_READ);retargets[reuse]++;}
            else {rc=s2a_track_platform_alias((uintptr_t)source[j],pg,PROT_READ,&alias);reserves[reuse]++;}
            if(rc) {std::printf("ALIAS_PROBE result=FAIL step=map mode=%u page=%u errno=%d\n",reuse,j,rc);return 5;}
            for(size_t k=0;k<pg;k++) if(((unsigned char*)alias)[k]!=value(j,k,0)) return 6;
            if(!reuse) {if(s2a_track_platform_unalias(alias,pg)) return 7;alias=nullptr;releases[reuse]++;}
        }
        if(alias) {if(s2a_track_platform_unalias(alias,pg)) return 8;releases[reuse]++;}
        elapsed[reuse]+=now()-start;
    }
    // Source permissions and byte contents stay unchanged. A later call sees new bytes.
    for(unsigned j=0;j<N;j++) {
        if(s2a_track_platform_protection((uintptr_t)source[j])!=PROT_NONE) return 9;
        if(mprotect(source[j],pg,PROT_READ|PROT_WRITE)) return 10;
        for(size_t k=0;k<pg;k++) {if(((unsigned char*)source[j])[k]!=value(j,k,0)) return 11;((unsigned char*)source[j])[k]=value(j,k,1);}
        if(mprotect(source[j],pg,PROT_NONE)) return 12;
    }
    void* alias=nullptr;
    if(s2a_track_platform_alias((uintptr_t)source[0],pg,PROT_READ,&alias)) return 13;
    if(s2a_track_platform_realias(alias,(uintptr_t)source[N-1],pg,PROT_READ)) return 14;
    for(size_t k=13;k<pg-29;k++) if(((unsigned char*)alias)[k]!=value(N-1,k,1)) return 15;
    // A private source is unsupported; failure must leave owned scratch reserved, source intact.
    void* privatePage=mmap(nullptr,pg,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    if(privatePage==MAP_FAILED) return 16;
    memset(privatePage,0x5a,pg);
    int failRc=s2a_track_platform_realias(alias,(uintptr_t)privatePage,pg,PROT_READ);
    if(!failRc || s2a_track_platform_protection((uintptr_t)alias)!=PROT_NONE || ((unsigned char*)privatePage)[0]!=0x5a) return 17;
    if(s2a_track_platform_unalias(alias,pg)) return 18;
    munmap(privatePage,pg);
    for(void* p:source) munmap(p,pg);
    if(reserves[0]!=N*Rounds || releases[0]!=N*Rounds || reserves[1]!=Rounds || releases[1]!=Rounds || retargets[1]!=(N-1)*Rounds) return 19;
    std::printf("ALIAS_PROBE result=PASS independentBackings=%u page=%zu rounds=%u freshBytes=pass sourceProtection=pass privateFailure=pass baselineNs=%llu reuseNs=%llu reserves=%u/%u retargets=%u/%u releases=%u/%u scope=actual-platform-VM-not-game-FPS\n",N,pg,Rounds,(unsigned long long)elapsed[0],(unsigned long long)elapsed[1],reserves[0],reserves[1],retargets[0],retargets[1],releases[0],releases[1]);
    return 0;
}
