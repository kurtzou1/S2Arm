// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#if __has_include(<graphics_game_sdk/opengtx_base.h>) && __has_include(<GameServiceKit/game_performance.h>)
#define S2A_HAS_HMS_HINTS 1
#include <graphics_game_sdk/opengtx_base.h>
#include <GameServiceKit/game_performance.h>
#else
#define S2A_HAS_HMS_HINTS 0
#endif
#include <qos/qos.h>
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <time.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <atomic>

extern "C" void rp_present_stats(uint64_t *, uint64_t *) __attribute__((weak));
extern "C" uint64_t s2a_ohos_present_count(void);

namespace {
pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
#if S2A_HAS_HMS_HINTS
OpenGTX_Context *context;
decltype(&HMS_OpenGTX_CreateContext) create_context;
decltype(&HMS_OpenGTX_SetConfiguration) configure;
decltype(&HMS_OpenGTX_Activate) activate;
decltype(&HMS_OpenGTX_Deactivate) deactivate;
decltype(&HMS_OpenGTX_DestroyContext) destroy;
decltype(&HMS_OpenGTX_DispatchGameSceneInfo) scene;
#endif
int width=1280,height=720,main_thread;
bool foreground=true;
#if S2A_HAS_HMS_HINTS
OpenGTX_GameSceneInfo game_scene(OpenGTX_SceneID id, const char *description) {
    OpenGTX_GameSceneInfo info{};
    info.sceneID=id;info.description=const_cast<char*>(description);
    info.recommendFPS=60;info.minFPS=30;info.maxFPS=60;
    info.resolutionCurValue.height=height;info.resolutionCurValue.width=width;
    return info;
}
#endif
std::atomic<bool> first_frame{false};
// Presented-frame counter for the optional in-game FPS readout (both graphics paths call perf_present).
std::atomic<uint64_t> presented{0};
int render_thread,draw_thread;
#if S2A_HAS_HMS_HINTS
OpenGTX_ConfigDescription g_config;
void temperature(OpenGTX_TempLevel level) { std::fprintf(stderr,"[OHOS game hints] thermalLevel=%d; system thermal policy retained\n",(int)level); }
#endif
}
// Game Service Kit：上报“这是游戏”、场景与关键线程，系统据此调度；同时每 10 秒记一次系统给的温控和负载。
// 运行时 dlopen，缺库或失败只记日志。DEBUG_S2A_NO_GAMEPERF=1 关。
#if S2A_HAS_HMS_HINTS
using E=GamePerformance_ErrorCode;
#define GP(name) reinterpret_cast<decltype(&HMS_GamePerformance_##name)>(dlsym(lib,"HMS_GamePerformance_" #name))
static const int initial_scene_fps=30;   // 第一个 10 秒窗口之前还没有测量值，只作占位
// SceneInfo 是一次性对象，字段全量上报：每次都带齐，只有当前帧率会变。
static int game_perf_scene(void *lib,int fps) {
    auto create_scene=GP(CreateSceneInfo);
    GamePerformance_SceneInfo *si=nullptr;
    if(!create_scene||create_scene(&si)!=GAME_PERFORMANCE_SUCCESS)return -1;
    char keys[33];snprintf(keys,sizeof keys,"render|%d|logic|%d",render_thread,draw_thread?draw_thread:main_thread);
    GP(SceneInfo_SetSceneID)(si,7);GP(SceneInfo_SetDescription)(si,"playing");
    GP(SceneInfo_SetImportanceLevel)(si,GAME_PERFORMANCE_SIL_LEVEL5);
    GP(SceneInfo_SetRecommendedCpuLevel)(si,GAME_PERFORMANCE_CPU_LEVEL_HIGH);
    GP(SceneInfo_SetRecommendedGpuLevel)(si,GAME_PERFORMANCE_GPU_LEVEL_HIGH);
    GP(SceneInfo_SetRecommendedDdrLevel)(si,GAME_PERFORMANCE_DDR_LEVEL_HIGH);
    GP(SceneInfo_SetMaxFrameRate)(si,60);GP(SceneInfo_SetCurrentFrameRate)(si,fps);
    E kr=GP(SceneInfo_SetKeyThread)(si,keys);
    int rc=(int)GP(UpdateSceneInfo)(si);
    std::fprintf(stderr,"[OHOS gameperf] scene=%d fps=%d keyThread=%s(%d)\n",rc,fps,keys,(int)kr);
    GP(DestroySceneInfo)(&si);
    return rc;
}
void *game_perf_watch(void *arg) {
    void *lib=arg; pthread_setname_np(pthread_self(),"s2a-gameperf");
    auto create=GP(CreateThermalInfoQueryParameters);auto query=GP(QueryThermalInfo);auto destroy=GP(DestroyThermalInfo);
    auto level=GP(ThermalInfo_GetThermalLevel);auto margin=GP(ThermalInfo_GetThermalMargin);auto trend=GP(ThermalInfo_GetThermalTrend);
    auto qgpu=GP(QueryGpuInfo);auto dgpu=GP(DestroyGpuInfo);auto gload=GP(GpuInfo_GetGpuLoadLevel);auto gfreq=GP(GpuInfo_GetCurrentFrequency);
    auto qcpu=GP(QueryCpuInfo);auto dcpu=GP(DestroyCpuInfo);auto cload=GP(CpuInfo_GetCpuLoadLevel);auto csingle=GP(CpuInfo_GetSingleThreadLoadLevel);
    GamePerformance_ThermalInfoQueryParameters *q=nullptr;
    if(create)create(&q);
    // 当前帧率：按本轮实际 present 数算，变化够大才重报。不呈现（后台、加载中）的窗口不报，保留上一次的值。
    // DEBUG_S2A_NO_SCENE_FPS=1 关，退回启动时那一次上报。
    const bool report_fps=!getenv("DEBUG_S2A_NO_SCENE_FPS");
    uint64_t last_presented=s2a_ohos_present_count();
    timespec last_time;clock_gettime(CLOCK_MONOTONIC,&last_time);
    int reported_fps=initial_scene_fps;
    for(;;) {
        int32_t lv=-1,mg=-1,tr=0,gl=-1,gf=-1,cl=-1,cs=-1;
        GamePerformance_ThermalInfo *t=nullptr;
        if(query&&query(q,&t)==GAME_PERFORMANCE_SUCCESS&&t) { if(level)level(t,&lv);if(margin)margin(t,&mg);if(trend)trend(t,&tr);if(destroy)destroy(&t); }
        GamePerformance_GpuInfo *g=nullptr;
        if(qgpu&&qgpu(&g)==GAME_PERFORMANCE_SUCCESS&&g) { if(gload)gload(g,&gl);if(gfreq)gfreq(g,&gf);if(dgpu)dgpu(&g); }
        GamePerformance_CpuInfo *c=nullptr;
        if(qcpu&&qcpu(&c)==GAME_PERFORMANCE_SUCCESS&&c) { if(cload)cload(c,&cl);if(csingle)csingle(c,&cs);if(dcpu)dcpu(&c); }
        std::fprintf(stderr,"[OHOS gameperf] thermal=%d margin=%d trend=%d gpu=%d gpu_freq=%d cpu=%d single=%d\n",lv,mg,tr,gl,gf,cl,cs);
        sleep(10);
        uint64_t now_presented=s2a_ohos_present_count();
        timespec now_time;clock_gettime(CLOCK_MONOTONIC,&now_time);
        double sec=(now_time.tv_sec-last_time.tv_sec)+(now_time.tv_nsec-last_time.tv_nsec)/1e9;
        uint64_t frames=now_presented>=last_presented?now_presented-last_presented:0;
        last_presented=now_presented;last_time=now_time;
        if(report_fps&&frames&&sec>0) {
            int fps=(int)(frames/sec+0.5);
            fps=fps<1?1:fps>144?144:fps;   // 接口取值 [1, 144]
            if(fps-reported_fps>=2||reported_fps-fps>=2) { game_perf_scene(lib,fps);reported_fps=fps; }
        }
    }
    return nullptr;
}
static void *g_perf_lib;
void game_perf_begin(void) {
    if(getenv("DEBUG_S2A_NO_GAMEPERF"))return;
    void *lib=dlopen("libgame_performance.z.so",RTLD_NOW|RTLD_LOCAL);
    if(!lib) { std::fprintf(stderr,"[OHOS gameperf] library unavailable\n");return; }
    auto create_init=GP(CreateInitParameters);auto set_bundle=GP(InitParameters_SetBundleName);auto set_ver=GP(InitParameters_SetAppVersion);
    auto init=GP(Init);auto destroy_init=GP(DestroyInitParameters);
    if(!create_init||!set_bundle||!init)return;
    GamePerformance_InitParameters *ip=nullptr;
    E rc=create_init(&ip);
    if(rc==GAME_PERFORMANCE_SUCCESS) { set_bundle(ip,"com.xiaoboluo.s2arm.probe");if(set_ver)set_ver(ip,"0.3.9");rc=init(ip);if(destroy_init)destroy_init(&ip); }
    std::fprintf(stderr,"[OHOS gameperf] init=%d\n",(int)rc);
    if(rc!=GAME_PERFORMANCE_SUCCESS)return;
    GamePerformance_PackageInfo *pi=nullptr;
    auto create_pkg=GP(CreatePackageInfo);
    if(create_pkg&&create_pkg(&pi)==GAME_PERFORMANCE_SUCCESS) {
        GP(PackageInfo_SetBundleName)(pi,"com.xiaoboluo.s2arm.probe");GP(PackageInfo_SetAppVersion)(pi,"0.3.9");
        GP(PackageInfo_SetEngineType)(pi,GAME_PERFORMANCE_ENGINE_TYPE_OTHERS);GP(PackageInfo_SetEngineVersion)(pi,"S2Arm");
        GP(PackageInfo_SetGameType)(pi,GAME_PERFORMANCE_GAME_TYPE_RPG);GP(PackageInfo_SetVulkanSupported)(pi,true);
        std::fprintf(stderr,"[OHOS gameperf] package=%d\n",(int)GP(UpdatePackageInfo)(pi));
        GP(DestroyPackageInfo)(&pi);
    }
    render_thread=gettid();
    game_perf_scene(lib,initial_scene_fps);
    g_perf_lib=lib;
    pthread_t t;
    if(!pthread_create(&t,nullptr,game_perf_watch,lib))pthread_detach(t);
}
// 拆出绘制线程后把它报成关键线程，顶替 logic（系统对三段式返回 401）。DEBUG_S2A_DRAW_KEY=0 不报。
extern "C" void s2a_ohos_report_draw_thread(int tid) {
    const char *m=getenv("DEBUG_S2A_DRAW_KEY");
    if(!g_perf_lib||(m&&*m=='0'))return;
    draw_thread=tid;
    game_perf_scene(g_perf_lib,initial_scene_fps);
}
#else
extern "C" void s2a_ohos_report_draw_thread(int) {}
#endif
// DEBUG_S2A_QOS_PROBE=<延迟秒>：游戏运行中逐档量一条新线程的计算速度，看 QoS / 绑核能不能拿到大核。
struct QosProbeArg { int qos; unsigned long mask; double rate; int cpu; };
static void *qos_probe_worker(void *p) {
    auto *a=static_cast<QosProbeArg *>(p);
    if(a->qos>=0)OH_QoS_SetThreadQoS(static_cast<QoS_Level>(a->qos));
    if(a->mask) { cpu_set_t set;CPU_ZERO(&set);for(int i=0;i<64;i++)if(a->mask>>i&1)CPU_SET(i,&set);sched_setaffinity(0,sizeof set,&set); }
    static thread_local unsigned buffer[1<<14];
    timespec t0,t1;clock_gettime(CLOCK_MONOTONIC,&t0);
    unsigned long n=0,x=1;int hist[32]={0};double sec=0;
    while(sec<3.0) {
        for(int i=0;i<4096;i++) { x=x*0x9E3779B97F4A7C15ul+buffer[x>>50&16383];buffer[x>>40&16383]=(unsigned)x; }
        n++;
        if(!(n&63)) { int c=sched_getcpu();if(c>=0&&c<32)hist[c]++;clock_gettime(CLOCK_MONOTONIC,&t1);sec=(t1.tv_sec-t0.tv_sec)+(t1.tv_nsec-t0.tv_nsec)/1e9; }
    }
    int best=0;for(int i=1;i<32;i++)if(hist[i]>hist[best])best=i;
    a->rate=n/sec/1000.0;a->cpu=best;
    return nullptr;
}
static void *qos_probe(void *p) {
    sleep(static_cast<unsigned>(reinterpret_cast<long>(p)));
    static const struct { const char *name;int qos;unsigned long mask;int threads; } modes[]={
        {"default",-1,0,1},{"qos-background",0,0,1},{"qos-default",2,0,1},{"qos-initiated",3,0,1},{"qos-deadline",4,0,1},{"qos-interactive",5,0,1},
        {"pin-hi",-1,0xfc00,1},{"pin-hi+interactive",5,0xfc00,1},{"pin-mid",-1,0x03f0,1},{"pair-interactive",5,0,2},{"triple-interactive",5,0,3},{"pair-pin-hi",5,0xfc00,2},{"default",-1,0,1}};
    for(auto &m:modes) {
        QosProbeArg arg[3];pthread_t t[3];
        for(int i=0;i<m.threads;i++) { arg[i]={m.qos,m.mask,0,-1};pthread_create(&t[i],nullptr,qos_probe_worker,&arg[i]); }
        for(int i=0;i<m.threads;i++)pthread_join(t[i],nullptr);
        for(int i=0;i<m.threads;i++)std::fprintf(stderr,"[OHOS qos probe] %s #%d rate=%.1f cpu=%d\n",m.name,i,arg[i].rate,arg[i].cpu);
    }
    return nullptr;
}
// DEBUG_S2A_PGO_DUMP=<秒>：插桩包每隔这么久写一次 profile（进程总被直接结束，等不到 atexit）。
// 计数是累积的，所以最后一份覆盖整局；两份做差就是这段时间的稳态计数。先写临时文件再改名，拉取时不会读到半份。
extern "C" int __llvm_profile_write_file(void) __attribute__((weak));
extern "C" void __llvm_profile_set_filename(const char *) __attribute__((weak));
static void *pgo_dump(void *p) {
    const unsigned period = static_cast<unsigned>(reinterpret_cast<long>(p));
    if(!__llvm_profile_write_file||!period)return nullptr;
    static char path[1200],tmp[1210];
    std::snprintf(path,sizeof path,"%s/../pgo.profraw",std::getenv("S2A_DIRECT_CACHE_DIR")?std::getenv("S2A_DIRECT_CACHE_DIR"):".");
    std::snprintf(tmp,sizeof tmp,"%s.tmp",path);
    __llvm_profile_set_filename(tmp);
    for(;;) {
        sleep(period);
        const int rc=__llvm_profile_write_file();
        if(rc==0)std::rename(tmp,path);
        else std::fprintf(stderr,"[OHOS pgo] write %s rc=%d\n",tmp,rc);
    }
    return nullptr;
}
// DEBUG_S2A_GTX_KEYS=1: 进局后按 3 秒 CPU 时间挑最忙的三条其他线程追加为 OpenGTX 关键线程（小菠萝同法）。
#if S2A_HAS_HMS_HINTS
static unsigned long long task_ticks(int tid) {
    char path[64],buf[512];std::snprintf(path,sizeof path,"/proc/self/task/%d/stat",tid);
    FILE *f=std::fopen(path,"r");if(!f)return 0;
    size_t n=std::fread(buf,1,sizeof buf-1,f);std::fclose(f);buf[n]=0;
    char *q=std::strrchr(buf,')');if(!q)return 0;
    unsigned long long ut=0,st=0;
    if(std::sscanf(q+2,"%*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %llu %llu",&ut,&st)!=2)return 0;
    return ut+st;
}
static void *gtx_keys_main(void *) {
    sleep(90);
    enum { MAXT=256 };
    int tids[MAXT],n=0;unsigned long long start[MAXT];
    DIR *d=opendir("/proc/self/task");
    if(!d)return nullptr;
    while(dirent *e=readdir(d)) {
        int t=std::atoi(e->d_name);
        if(t>0&&t!=main_thread&&t!=render_thread&&n<MAXT) { tids[n]=t;start[n++]=task_ticks(t); }
    }
    closedir(d);
    sleep(3);
    int best[3]={0,0,0};unsigned long long top[3]={0,0,0};
    for(int i=0;i<n;i++) {
        unsigned long long now=task_ticks(tids[i]),dt=now>start[i]?now-start[i]:0;
        for(int k=0;k<3;k++) if(dt>top[k]) {
            for(int m=2;m>k;m--) { top[m]=top[m-1];best[m]=best[m-1]; }
            top[k]=dt;best[k]=tids[i];break;
        }
    }
    pthread_mutex_lock(&mutex);
    int rc=-1;
    if(context) {
        g_config.gameKeyThreadIds[2]=best[0];g_config.gameKeyThreadIds[3]=best[1];g_config.gameKeyThreadIds[4]=best[2];
        rc=configure(context,&g_config);
    }
    pthread_mutex_unlock(&mutex);
    std::fprintf(stderr,"[OHOS game hints] extra key threads %d(%llu) %d(%llu) %d(%llu) configure=%d\n",best[0],top[0],best[1],top[1],best[2],top[2],rc);
    return nullptr;
}
#endif
extern "C" void s2a_ohos_perf_session(int w,int h) {
    width=w;height=h;main_thread=gettid();
}
extern "C" void s2a_ohos_perf_begin(void) {
    // Scheduling hint for the actual GPU owner, not affinity/frequency forcing.
    int qos=OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE);
    std::fprintf(stderr,"[OHOS game hints] renderTid=%d qosInteractiveResult=%d\n",gettid(),qos);
    if(const char *e=std::getenv("DEBUG_S2A_QOS_PROBE")) {
        pthread_t t;
        if(!pthread_create(&t,nullptr,qos_probe,reinterpret_cast<void *>(static_cast<long>(std::atoi(e)))))pthread_detach(t);
    }
    if(const char *e=std::getenv("DEBUG_S2A_PGO_DUMP")) {
        pthread_t t;
        if(!pthread_create(&t,nullptr,pgo_dump,reinterpret_cast<void *>(static_cast<long>(std::atoi(e)))))pthread_detach(t);
    }
#if S2A_HAS_HMS_HINTS
    game_perf_begin();
    void *library=dlopen("libopengtx.so",RTLD_NOW|RTLD_LOCAL);
    if(!library) { std::fprintf(stderr,"[OHOS game hints] OpenGTX unavailable; normal scheduling\n");return; }
#define LOAD(field,name) field=reinterpret_cast<decltype(field)>(dlsym(library,name)); if(!field)return
    LOAD(create_context,"HMS_OpenGTX_CreateContext");LOAD(configure,"HMS_OpenGTX_SetConfiguration");
    LOAD(activate,"HMS_OpenGTX_Activate");LOAD(deactivate,"HMS_OpenGTX_Deactivate");
    LOAD(destroy,"HMS_OpenGTX_DestroyContext");LOAD(scene,"HMS_OpenGTX_DispatchGameSceneInfo");
#undef LOAD
    pthread_mutex_lock(&mutex);
    context=create_context(temperature);
    if(context) {
        OpenGTX_ConfigDescription &config=g_config;
        config.mode=SCENE_MODE; config.targetFPS=60; // Host ceiling; does not change guest timing or claim 60 FPS.
        config.packageName=const_cast<char*>("com.xiaoboluo.s2arm.probe");
        config.appVersion=const_cast<char*>("0.3.9");config.engineType=OTHERS_ENGINE;
        config.engineVersion=const_cast<char*>("S2Arm OHOS Vulkan");config.gameType=OTHERS_TYPE;
        config.pictureQualityMaxLevel=QHD;
        config.resolutionMaxValue={height,width};config.gameMainThreadId=main_thread;config.gameRenderThreadId=gettid();
        config.gameKeyThreadIds[0]=main_thread;config.gameKeyThreadIds[1]=gettid();config.vulkanSupport=true;
        int rc=configure(context,&config);
        if(const char *e=std::getenv("DEBUG_S2A_GTX_KEYS"); e&&e[0]=='1'&&!e[1]) { pthread_t t;if(!pthread_create(&t,nullptr,gtx_keys_main,nullptr))pthread_detach(t); }
        if(rc==0&&foreground)rc=activate(context);
        std::fprintf(stderr,"[OHOS game hints] OpenGTX configure/activate=%d targetCeiling=60 actualFPS=unmeasured\n",rc);
        if(rc!=0)destroy(&context);
        else { auto loading=game_scene(LOADING,"shader-cache-and-game-start");int sr=scene(context,&loading);std::fprintf(stderr,"[OHOS game hints] loading scene=%d size=%dx%d\n",sr,width,height); }
    } else std::fprintf(stderr,"[OHOS game hints] OpenGTX context unavailable\n");
    pthread_mutex_unlock(&mutex);
#else
    std::fprintf(stderr,"[OHOS game hints] built without HMS headers; public QoS and frame counters retained\n");
#endif
}
extern "C" __attribute__((visibility("default"))) uint64_t s2a_ohos_present_count(void) {
    // The replay backend does not call the legacy perf_present hook. Its count
    // means accepted presents (not physical scanout); it also gates the shell's
    // loading overlay. Never infer a first frame from runtime-started alone.
    uint64_t replay=0;
    if(rp_present_stats) rp_present_stats(&replay,nullptr);
    return replay+presented.load(std::memory_order_relaxed);
}
// OpenGTX scene FPS fields describe a target (minimum nonzero 30). Carry an
// observation in description; GamePerformance has the actual numeric FPS field.
static uint64_t g_gtx_frames;
static timespec g_gtx_time{};
static void gtx_measured_sample(uint64_t total) {
#if S2A_HAS_HMS_HINTS
    pthread_mutex_lock(&mutex);
    if (context && foreground) {
        timespec now;
        clock_gettime(CLOCK_MONOTONIC,&now);
        double sec = now.tv_sec-g_gtx_time.tv_sec + (now.tv_nsec-g_gtx_time.tv_nsec)/1e9;
        if (g_gtx_frames && total > g_gtx_frames && sec > 0) {
            char desc[96];
            std::snprintf(desc,sizeof desc,"game-frames-visible measured_fps=%.2f",(total-g_gtx_frames)/sec);
            auto info=game_scene(PLAYING,desc);
            int rc=scene(context,&info);
            std::fprintf(stderr,"[OHOS OpenGTX] %s frames=%llu sec=%.3f scene_rc=%d\n",desc,
                         (unsigned long long)(total-g_gtx_frames),sec,rc);
        }
        g_gtx_frames=total;g_gtx_time=now;
    }
    pthread_mutex_unlock(&mutex);
#else
    (void)total;
#endif
}
// 逐帧记账：设了 S2A_FRAMES_TSV 就写 frames.tsv（frame、wall_us 两列，读法同 tools/quicktest/verdict.py）。
// 攒够一块才写盘，上屏线程平时只做一次格式化。没设时只有一次判断。
static int g_frames_fd=-2;
static char g_frames_buf[8192];
static size_t g_frames_used;
static uint64_t g_frames_last_us;
static uint64_t g_boot_us;
static uint64_t mono_us() { timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000u+t.tv_nsec/1000; }
__attribute__((constructor)) static void note_boot_time() { g_boot_us=mono_us(); }
static void frames_tsv(uint64_t frame) {
    if(g_frames_fd==-2) {
        const char *p=std::getenv("S2A_FRAMES_TSV");
        g_frames_fd=p&&*p?open(p,O_CREAT|O_TRUNC|O_WRONLY|O_CLOEXEC,0644):-1;
        if(g_frames_fd>=0) { static const char head[]="frame\twall_us\n";(void)!write(g_frames_fd,head,sizeof head-1); }
        else if(p&&*p) std::fprintf(stderr,"[OHOS] 【红】frames.tsv 打不开（%s）\n",p);
    }
    if(g_frames_fd<0)return;
    const uint64_t now=mono_us();
    const uint64_t wall=g_frames_last_us?now-g_frames_last_us:0;
    g_frames_last_us=now;
    g_frames_used+=(size_t)std::snprintf(g_frames_buf+g_frames_used,sizeof g_frames_buf-g_frames_used,"%llu\t%llu\n",(unsigned long long)frame,(unsigned long long)wall);
    if(g_frames_used>sizeof g_frames_buf-64) { (void)!write(g_frames_fd,g_frames_buf,g_frames_used);g_frames_used=0; }
}
extern "C" void s2a_ohos_perf_present(void) {
    const uint64_t total=presented.fetch_add(1,std::memory_order_relaxed)+1;
    if(total==1) std::fprintf(stderr,"[OHOS] nnMain → 首帧上屏（自引擎加载）+%.1f ms\n",(mono_us()-g_boot_us)/1000.0);
    frames_tsv(total);
    // No C++ runtime in the engine link: a function-local static guard would need __cxa_guard_*.
    static std::atomic<int> report{-1};
    int on=report.load(std::memory_order_relaxed);
    if(on<0) { const char *v=std::getenv("DEBUG_S2A_GTX_MEASURED");on=v&&!std::strcmp(v,"1");report.store(on,std::memory_order_relaxed); }
    if (on && !(total % 128)) gtx_measured_sample(total);
    if(first_frame.exchange(true))return;
    pthread_mutex_lock(&mutex);
#if S2A_HAS_HMS_HINTS
    if(context&&foreground) { auto info=game_scene(PLAYING,"game-frames-visible");int rc=scene(context,&info);std::fprintf(stderr,"[OHOS game hints] visible rendering scene=%d\n",rc); }
#endif
    pthread_mutex_unlock(&mutex);
}
extern "C" void s2a_ohos_perf_foreground(int active) {
    pthread_mutex_lock(&mutex);foreground=active!=0;g_gtx_frames=0;
#if S2A_HAS_HMS_HINTS
    if(context) { int rc=foreground?activate(context):deactivate(context);std::fprintf(stderr,"[OHOS game hints] foreground=%d result=%d\n",active,rc); }
#endif
    pthread_mutex_unlock(&mutex);
}
