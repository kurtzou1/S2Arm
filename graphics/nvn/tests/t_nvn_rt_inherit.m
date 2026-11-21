// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Real public NVN -> Metal: binding survives completion and recycling of its command record.
// Present advances the production frame counter; no fake clock or command-shadow writes.
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
extern uint64_t dm_nvn_frame_count(void);
extern int nvn_be_xq_owed(const void *sync, void **q);
static NVNdevice device;
static NVNqueue queue, other_queue;
static NVNmemoryPool texture_pool, command_pool;
static NVNcommandBuffer commands;
static int command_initialized;
static void *texture_storage, *command_storage;
static unsigned checks, texels, failures, readbacks;
static const char *phase="setup";
enum { N=32, SEGMENT=65536, POOL_SIZE=4*SEGMENT, READ_OFFSET=3*SEGMENT };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL [%s] %s:%d: %s\n",phase,__FILE__,__LINE__,#x); exit(1); } } while (0)
static void *load(const char *name) { void *p=h_nvnBootstrapLoader(name); REQUIRE(p!=NULL); return p; }
#define API(name) ((NVNT_##name)load(#name))
static void make_pool(NVNmemoryPool *pool, void **storage) {
    REQUIRE(posix_memalign(storage,SEGMENT,POOL_SIZE)==0); memset(*storage,0,POOL_SIZE);
    NVNmemoryPoolBuilder b; API(nvnMemoryPoolBuilderSetDefaults)(&b); API(nvnMemoryPoolBuilderSetDevice)(&b,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&b,*storage,POOL_SIZE);
    API(nvnMemoryPoolBuilderSetFlags)(&b,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(pool,&b));
}
static void setup(void) {
    NVNdeviceBuilder d; API(nvnDeviceBuilderSetDefaults)(&d); REQUIRE(API(nvnDeviceInitialize)(&device,&d));
    NVNqueueBuilder q; API(nvnQueueBuilderSetDefaults)(&q); API(nvnQueueBuilderSetDevice)(&q,&device);
    REQUIRE(API(nvnQueueInitialize)(&queue,&q)); REQUIRE(API(nvnQueueInitialize)(&other_queue,&q));
    make_pool(&texture_pool,&texture_storage); make_pool(&command_pool,&command_storage);
}
static void make_texture_shape(NVNtexture *t, size_t offset, NVNformat format, int size, int levels) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device);
    API(nvnTextureBuilderSetTarget)(&b,NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&b,size,size);
    API(nvnTextureBuilderSetLevels)(&b,levels); API(nvnTextureBuilderSetFormat)(&b,format);
    size_t alignment=API(nvnTextureBuilderGetStorageAlignment)(&b), bytes=API(nvnTextureBuilderGetStorageSize)(&b);
    REQUIRE(alignment && offset%alignment==0 && bytes && offset+bytes<=POOL_SIZE);
    API(nvnTextureBuilderSetStorage)(&b,&texture_pool,(ptrdiff_t)offset); REQUIRE(API(nvnTextureInitialize)(t,&b));
}
static void make_texture(NVNtexture *t, size_t offset) { make_texture_shape(t,offset,NVN_FORMAT_RGBA8,N,1); }
static void begin(size_t offset) {
    // A fresh CB makes the allocator's first host-block class the same for each recording.
    if (command_initialized) API(nvnCommandBufferFinalize)(&commands);
    REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device)); command_initialized=1;
    static uint8_t control[4096]; API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
    API(nvnCommandBufferAddCommandMemory)(&commands,&command_pool,(ptrdiff_t)offset,SEGMENT);
    API(nvnCommandBufferBeginRecording)(&commands);
}
static NVNcommandHandle end(void) { NVNcommandHandle h=API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h!=0); return h; }
static void run_handle(NVNqueue *q, NVNcommandHandle h) {
    API(nvnQueueSubmitCommands)(q,1,&h); API(nvnQueueFinish)(q); REQUIRE(mtl_last_commit_error()==0);
}
static NVNcommandHandle submit(void) { NVNcommandHandle h=end(); run_handle(&queue,h); return h; }
static void readback_view(NVNtexture *t, const NVNtextureView *view) {
    memset((uint8_t *)command_storage+READ_OFFSET,0xa5,N*N*4);
    NVNcopyRegion whole={0,0,0,N,N,1};
    API(nvnCommandBufferCopyTextureToBuffer)(&commands,t,view,&whole,API(nvnMemoryPoolGetBufferAddress)(&command_pool)+READ_OFFSET,0);
}
static void expect(const uint8_t rgba[4]) {
    readbacks++; const uint8_t *pixels=(const uint8_t *)command_storage+READ_OFFSET; unsigned wrong=0;
    for (int i=0; i<N*N; i++,texels++) if (memcmp(pixels+4*i,rgba,4)) wrong++;
    if (wrong) { failures++; fprintf(stderr,"FAIL [%s] %u/%d GPU texels differ; first=%02x %02x %02x %02x expected=%02x %02x %02x %02x\n",phase,wrong,N*N,
        pixels[0],pixels[1],pixels[2],pixels[3],rgba[0],rgba[1],rgba[2],rgba[3]); }
    else printf("PASS [%s] %d GPU texels\n",phase,N*N);
    fflush(stdout);
}
static void read_expect(NVNtexture *t, const NVNtextureView *view, const uint8_t rgba[4]) {
    begin(2*SEGMENT); readback_view(t,view); submit(); expect(rgba);
}
static void retire_source(NVNtexture *presented) {
    // Re-record over the source's device interval: only this releases its host shadow. It must write command memory
    // (a barrier, 8 bytes): EndRecording takes none (#1904), so an empty recording covers nothing and is shared by content.
    begin(0); API(nvnCommandBufferBarrier)(&commands,0); end();
    // Production shadow blocks wait two presented frames before reuse. A real NVN window
    // in windowless mode drives that same present path; merely nvn_be_set_frame would not.
    NVNwindowBuilder b; NVNwindow w; NVNtexture *textures[]={presented};
    API(nvnWindowBuilderSetDefaults)(&b); API(nvnWindowBuilderSetDevice)(&b,&device);
    API(nvnWindowBuilderSetTextures)(&b,1,textures); API(nvnWindowBuilderSetPresentInterval)(&b,0);
    REQUIRE(API(nvnWindowInitialize)(&w,&b));
    uint64_t before=dm_nvn_frame_count();
    API(nvnQueuePresentTexture)(&queue,&w,0); API(nvnQueuePresentTexture)(&queue,&w,0);
    REQUIRE(dm_nvn_frame_count()==before+2);
    int acquired=-1;
    REQUIRE(API(nvnWindowAcquireTexture)(&w,NULL,&acquired)==NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && acquired==0);
    // Acquire waits for the final present ticket before the window/texture is released.
    API(nvnWindowFinalize)(&w);
}
static void unload(void) { begin(2*SEGMENT); API(nvnCommandBufferSetRenderTargets)(&commands,0,NULL,NULL,NULL,NULL); submit(); }
static void run(int reuse) {
    NVNtexture a; make_texture(&a,0);
    const NVNtexture *targets[]={&a}; const float red[4]={1,0,0,1}, green[4]={0,1,0,1};
    static const uint8_t red_bytes[4]={255,0,0,255}, green_bytes[4]={0,255,0,255};
    phase=reuse?"reuse: SetRT/clear red":"control: SetRT/clear red";
    begin(0); API(nvnCommandBufferSetRenderTargets)(&commands,1,targets,NULL,NULL,NULL);
    API(nvnCommandBufferSetScissor)(&commands,0,0,N,N); API(nvnCommandBufferSetViewport)(&commands,0,0,N,N);
    API(nvnCommandBufferClearColor)(&commands,0,red,15); NVNcommandHandle source=submit();
    read_expect(&a,NULL,red_bytes);
    if (reuse) retire_source(&a);
    phase=reuse?"reuse: reclaimed host record; inherited RT/clear green":"control: preserved host record; inherited RT/clear green";
    begin(reuse?0:SEGMENT); API(nvnCommandBufferClearColor)(&commands,0,green,15);
    NVNcommandHandle inherited=end();
    // Public handles are host-record addresses. Equality proves the old record really was
    // recycled and written, rather than merely overwriting the game's now-shadowed bytes.
    REQUIRE(reuse ? inherited==source : inherited!=source); run_handle(&queue,inherited);
    read_expect(&a,NULL,green_bytes); unload(); API(nvnTextureFinalize)(&a);
}
static void sparse_depth(void) {
    NVNtexture a,b,depth; make_texture_shape(&a,0,NVN_FORMAT_RGBA8,2*N,2);
    make_texture_shape(&b,SEGMENT,NVN_FORMAT_RGBA8,2*N,2); make_texture_shape(&depth,2*SEGMENT,NVN_FORMAT_DEPTH32F,2*N,2);
    NVNtextureView view; API(nvnTextureViewSetDefaults)(&view); API(nvnTextureViewSetLevels)(&view,1,1);
    const NVNtexture *targets[]={&a,NULL,&b}; const NVNtextureView *views[]={&view,NULL,&view};
    const float red[4]={1,0,0,1}, blue[4]={0,0,1,1}, green[4]={0,1,0,1}, yellow[4]={1,1,0,1};
    static const uint8_t initial[3][4]={{255,0,0,255},{0,0,255,255},{0,0,0x40,0x3f}};
    static const uint8_t inherited[3][4]={{0,255,0,255},{255,255,0,255},{0,0,0x80,0x3e}};
    NVNtexture *textures[]={&a,&b,&depth};
    phase="sparse RT: color slots 0/2, depth, mip-1 views";
    begin(0); API(nvnCommandBufferSetRenderTargets)(&commands,3,targets,views,&depth,&view);
    API(nvnCommandBufferSetScissor)(&commands,0,0,N,N); API(nvnCommandBufferSetViewport)(&commands,0,0,N,N);
    API(nvnCommandBufferClearColor)(&commands,0,red,15); API(nvnCommandBufferClearColor)(&commands,2,blue,15);
    API(nvnCommandBufferClearDepthStencil)(&commands,0.75f,1,0,0); NVNcommandHandle source=submit();
    for (int i=0; i<3; i++) read_expect(textures[i],&view,initial[i]);
    retire_source(&a);
    phase="sparse RT: reclaimed host record; inherit color/depth mip-1 views";
    begin(0); API(nvnCommandBufferClearColor)(&commands,0,green,15); API(nvnCommandBufferClearColor)(&commands,2,yellow,15);
    API(nvnCommandBufferClearDepthStencil)(&commands,0.25f,1,0,0); NVNcommandHandle reused=end();
    REQUIRE(reused==source); run_handle(&queue,reused);
    for (int i=0; i<3; i++) read_expect(textures[i],&view,inherited[i]);
    unload(); API(nvnTextureFinalize)(&a); API(nvnTextureFinalize)(&b); API(nvnTextureFinalize)(&depth);
}
static void parked_inheritance(void) {
    phase="parked inherited RT survives another queue rebinding";
    NVNtexture a,b; make_texture(&a,0); make_texture(&b,SEGMENT);
    const NVNtexture *ta[]={&a}, *tb[]={&b};
    const float red[4]={1,0,0,1}, green[4]={0,1,0,1}, blue[4]={0,0,1,1};
    static const uint8_t rb[4]={255,0,0,255}, gb[4]={0,255,0,255}, bb[4]={0,0,255,255};
    begin(0); API(nvnCommandBufferSetRenderTargets)(&commands,1,ta,NULL,NULL,NULL);
    API(nvnCommandBufferSetScissor)(&commands,0,0,N,N); API(nvnCommandBufferSetViewport)(&commands,0,0,N,N);
    API(nvnCommandBufferClearColor)(&commands,0,red,15); submit(); read_expect(&a,NULL,rb);
    NVNeventBuilder eb; NVNevent e; API(nvnEventBuilderSetDefaults)(&eb);
    API(nvnEventBuilderSetStorage)(&eb,&command_pool,POOL_SIZE-64); REQUIRE(API(nvnEventInitialize)(&e,&eb));
    // Storage was zeroed with the real pool. A CPU EventSignal would mark this as a
    // CPU-written event, selecting the GPU-ticket wait instead of cross-queue parking.
    REQUIRE(API(nvnEventGetValue)(&e)==0);
    // Record the producer first, so the backend knows the unmet event will be GPU-signalled.
    begin(SEGMENT); API(nvnCommandBufferSetRenderTargets)(&commands,1,tb,NULL,NULL,NULL);
    API(nvnCommandBufferClearColor)(&commands,0,blue,15);
    API(nvnCommandBufferSignalEvent)(&commands,&e,NVN_EVENT_SIGNAL_MODE_WRITE,NVN_EVENT_SIGNAL_LOCATION_BOTTOM,0,1);
    NVNcommandHandle producer=end();
    // No SetRenderTargets in this submission: its parked R already points at retained state.
    begin(0); API(nvnCommandBufferWaitEvent)(&commands,&e,NVN_EVENT_WAIT_MODE_EQUAL,1);
    API(nvnCommandBufferClearColor)(&commands,0,green,15); NVNcommandHandle consumer=end();
    API(nvnQueueSubmitCommands)(&queue,1,&consumer);
    NVNsync sync; REQUIRE(API(nvnSyncInitialize)(&sync,&device));
    API(nvnQueueFenceSync)(&queue,&sync,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    void *owner=NULL; REQUIRE(nvn_be_xq_owed(&sync,&owner) && owner==&queue);
    REQUIRE(API(nvnSyncWait)(&sync,0)==NVN_SYNC_WAIT_RESULT_TIMEOUT_EXPIRED);
    run_handle(&other_queue,producer); API(nvnQueueFinish)(&queue);
    NVNsyncWaitResult waited=API(nvnSyncWait)(&sync,5000000000ull);
    REQUIRE(waited==NVN_SYNC_WAIT_RESULT_ALREADY_SIGNALED || waited==NVN_SYNC_WAIT_RESULT_CONDITION_SATISFIED);
    REQUIRE(!nvn_be_xq_owed(&sync,NULL));
    REQUIRE(API(nvnEventGetValue)(&e)==1);
    read_expect(&a,NULL,gb); read_expect(&b,NULL,bb);
    unload(); API(nvnSyncFinalize)(&sync); API(nvnEventFinalize)(&e);
    API(nvnTextureFinalize)(&a); API(nvnTextureFinalize)(&b);
}
int main(void) { @autoreleasepool {
    setup(); run(0); run(1); sparse_depth(); parked_inheritance();
    if (command_initialized) API(nvnCommandBufferFinalize)(&commands);
    API(nvnQueueFinalize)(&other_queue); API(nvnQueueFinalize)(&queue);
    API(nvnMemoryPoolFinalize)(&texture_pool); API(nvnMemoryPoolFinalize)(&command_pool); API(nvnDeviceFinalize)(&device);
    free(texture_storage); free(command_storage);
    printf("%s t_nvn_rt_inherit: %u GPU readbacks, %u texels, %u API/status checks, %u failures\n",failures?"✗":"✓",readbacks,texels,checks,failures);
    return failures?1:0;
}}
