// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// OHOS port of iOS native/fps.c's slot and dynamic-step contract. The table is
// local, explicit and build-pinned; this source contains no game-specific facts.
// Strict all-or-nothing parsing precedes writable-page changes or data writes.
#include "fps_ohos.h"
#ifndef S2A_OHOS_FPS_CORE_TEST
#include "../../runtime/src/native.h"
#include <errno.h>
#include <sys/mman.h>
#include <time.h>
#endif

#define FPS_EXPORT __attribute__((visibility("default")))
#define FPS_ABI "s2a.ohos.fps.v1"
#define SLOT_LOW 2032u
#define SLOT_HIGH 2047u
#define SLOT_COUNT (SLOT_HIGH - SLOT_LOW + 1u)
#define MAX_WRITES 32u

typedef struct { uint32_t *address, bits; } fps_write;
typedef struct {
    unsigned prepared, active, slots[SLOT_COUNT], values[SLOT_COUNT];
    uint32_t *slot_ptr[SLOT_COUNT];
    int speed_slot, condition_slot, condition_equal;
    uint32_t condition_value;
    float speed_low, speed_high;
    float diagnostic_step_cap;
    fps_write writes[MAX_WRITES];
    unsigned write_count;
    uint64_t last, last_write;
} fps_state;
static fps_state state;

static int equal(const char *a, const char *b) {
    while (*a && *a == *b) { ++a; ++b; }
    return *a == *b;
}
static unsigned text_length(const char *s) { unsigned n = 0; while (s[n]) ++n; return n; }
static uint32_t float_bits(float value) { union { float f; uint32_t u; } x = { .f = value }; return x.u; }
static int number(const char *s, uint64_t *out) {
    unsigned base = 10; uint64_t n = 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { s += 2; base = 16; }
    if (!*s) return 0;
    for (; *s; ++s) {
        unsigned v = *s >= '0' && *s <= '9' ? (unsigned)(*s - '0') :
                     *s >= 'a' && *s <= 'f' ? (unsigned)(*s - 'a') + 10 :
                     *s >= 'A' && *s <= 'F' ? (unsigned)(*s - 'A') + 10 : 99;
        if (v >= base || n > (UINT64_MAX - v) / base) return 0;
        n = n * base + v;
    }
    *out = n; return 1;
}
static int int_bits(const char *s, uint32_t *out) {
    int neg = *s == '-'; uint64_t n;
    if (neg) ++s;
    if (!number(s, &n) || n > (neg ? 2147483648ull : 2147483647ull)) return 0;
    *out = neg ? 0u - (uint32_t)n : (uint32_t)n; return 1;
}
static int decimal(const char *s, float *out) {
    int neg = *s == '-', dot = 0, digits = 0; double n = 0, scale = 1;
    if (neg || *s == '+') ++s;
    for (; *s; ++s) {
        if (*s == '.' && !dot) { dot = 1; continue; }
        if (*s < '0' || *s > '9' || ++digits > 18) return 0;
        n = n * 10 + (*s - '0'); if (dot) scale *= 10;
    }
    if (!digits || n / scale > 1000000000.0) return 0;
    *out = (float)((neg ? -n : n) / scale); return 1;
}
static int slot_number(const char *s) {
    uint64_t n;
    return number(s, &n) && n >= SLOT_LOW && n <= SLOT_HIGH ? (int)(n - SLOT_LOW) : -1;
}
static const s2a_ohos_fps_module *named(const s2a_ohos_fps_module *modules, size_t count, const char *name) {
    for (size_t i = 0; i < count; ++i) if (equal(modules[i].name, name)) return modules + i;
    return NULL;
}
static int build_equal(const char *a, const char *b) {
    if (text_length(a) != 32 || text_length(b) < 32) return 0;
    for (unsigned i = 0; i < 32; ++i) {
        unsigned x = (unsigned char)a[i], y = (unsigned char)b[i];
        if (x >= 'A' && x <= 'F') x += 'a' - 'A';
        if (y >= 'A' && y <= 'F') y += 'a' - 'A';
        if (!((x >= '0' && x <= '9') || (x >= 'a' && x <= 'f')) || x != y) return 0;
    }
    return 1;
}

FPS_EXPORT unsigned s2a_ohos_fps_abi_v1(void) { return 1; }
void s2a_ohos_fps_clear(void) {
    // Called only before guest threads start or after they have fully stopped.
    unsigned char *bytes = (unsigned char *)&state;
    for (size_t i = 0; i < sizeof state; ++i) bytes[i] = 0;
    state.speed_slot = state.condition_slot = -1;
}

int s2a_ohos_fps_prepare_text(const char *text, size_t length, const char *build_id,
                            const s2a_ohos_fps_module *modules, size_t count) {
    if (__atomic_load_n(&state.active, __ATOMIC_ACQUIRE)) return -1;
    s2a_ohos_fps_clear();
    if (!text || !length || length > 65536 || !build_id || !modules || !count || count > 16) return -2;
    const s2a_ohos_fps_module *main = named(modules, count, "main");
    if (!main || !main->base || main->key_size != 0x4000 || main->key_offset % 0x4000 ||
        main->key_offset > main->size || main->key_size > main->size - main->key_offset ||
        ((uintptr_t)main->base + main->key_offset) % 4) return -3;
    for (unsigned i = 0; i < SLOT_COUNT; ++i)
        state.slot_ptr[i] = (uint32_t *)(void *)(main->base + main->key_offset + (i + SLOT_LOW) * 8u);
    unsigned controls = 0, code_count = 0; size_t at = 0;
    while (at < length) {
        char token[10][64]; unsigned n = 0;
        while (at < length && text[at] != '\n') {
            char ch = text[at];
            if (ch == '#') { while (at < length && text[at] != '\n') ++at; break; }
            if (ch == ' ' || ch == '\t' || ch == '\r') { ++at; continue; }
            if (n == 10) return -4;
            unsigned k = 0;
            while (at < length && text[at] != '\n' && text[at] != '\r' && text[at] != ' ' && text[at] != '\t' && text[at] != '#') {
                if (k == 63 || (unsigned char)text[at] < 32 || (unsigned char)text[at] > 126) return -5;
                token[n][k++] = text[at++];
            }
            token[n++][k] = 0;
        }
        if (at < length) ++at;
        if (!n) continue;
        const char *kind = token[0];
        if (equal(kind, "abi") && n == 2 && equal(token[1], FPS_ABI) && !(controls & 1)) { controls |= 1; continue; }
        if (equal(kind, "build") && n == 2 && build_equal(token[1], build_id) && !(controls & 2)) { controls |= 2; continue; }
        if (equal(kind, "target") && n == 2 && equal(token[1], "60") && !(controls & 4)) { controls |= 4; continue; }
        if (equal(kind, "present") && n == 2 && equal(token[1], "display") && !(controls & 8)) { controls |= 8; continue; }
        if (equal(kind, "c") && n >= 6 && equal(token[1], "main")) {
            // Signed rewrite metadata binds this exact table. Decoder guard
            // checking and generation are completed offline, before signing.
            unsigned valid = (equal(token[3], "word") && n == 6) ||
                             (equal(token[3], "adrp_slot") && n == 6) ||
                             (equal(token[3], "ldr_slot") && n == 8) ||
                             (equal(token[3], "bl_rec") && n == 7);
            if (!valid || ++code_count > 128) return -6;
            continue;
        }
        if ((equal(kind, "slot") || equal(kind, "speed")) && n == 4) {
            int slot = slot_number(token[1]); float value;
            if (slot < 0 || state.slots[slot]) return -7;
            if (equal(kind, "speed")) {
                float high;
                if (state.speed_slot >= 0 || !decimal(token[2], &value) || !decimal(token[3], &high) ||
                    !(value > 0 && value <= 1 && high >= 1 && high <= 4)) return -8;
                state.speed_slot = slot; state.speed_low = value; state.speed_high = high;
                state.values[slot] = float_bits(1.0f); state.slots[slot] = 1;
            } else if (equal(token[2], "f32") && decimal(token[3], &value)) {
                state.values[slot] = float_bits(value); state.slots[slot] = 1;
            } else if (equal(token[2], "i32") && int_bits(token[3], &state.values[slot])) state.slots[slot] = 2;
            else return -9;
            continue;
        }
        if (equal(kind, "present30") && n == 6 && equal(token[1], "if") && equal(token[2], "slot") && state.condition_slot < 0) {
            state.condition_slot = slot_number(token[3]);
            if (state.condition_slot < 0 || (!equal(token[4], "==") && !equal(token[4], "!=")) ||
                !int_bits(token[5], &state.condition_value)) return -10;
            state.condition_equal = equal(token[4], "=="); continue;
        }
        if (equal(kind, "w") && n == 5 && state.write_count < MAX_WRITES) {
            const s2a_ohos_fps_module *m = named(modules, count, token[1]);
            uint64_t offset; uint32_t bits; float value;
            if (!m || !number(token[2], &offset) || offset % 4 || offset < m->data_offset ||
                m->data_end > m->key_offset || m->data_end > m->size || offset > m->data_end || 4 > m->data_end - offset) return -11;
            if (equal(token[3], "f32") && decimal(token[4], &value)) bits = float_bits(value);
            else if (!(equal(token[3], "i32") && int_bits(token[4], &bits))) return -12;
            uint32_t *address = (uint32_t *)(void *)(m->base + offset);
            for (unsigned i = 0; i < state.write_count; ++i) if (state.writes[i].address == address) return -13;
            state.writes[state.write_count++] = (fps_write){ address, bits }; continue;
        }
        return -14;
    }
    if (controls != 15 || !code_count || (state.condition_slot >= 0 && state.slots[state.condition_slot] != 2)) return -15;
    state.prepared = 1; return 0;
}

static void write_data(void) {
    for (unsigned i = 0; i < state.write_count; ++i)
        __atomic_store_n(state.writes[i].address, state.writes[i].bits, __ATOMIC_RELAXED);
}
int s2a_ohos_fps_activate(void) {
    if (!state.prepared || __atomic_load_n(&state.active, __ATOMIC_ACQUIRE)) return -1;
    for (unsigned i = 0; i < SLOT_COUNT; ++i)
        if (state.slots[i]) __atomic_store_n(state.slot_ptr[i], state.values[i], __ATOMIC_RELAXED);
    write_data();
    __atomic_store_n(&state.active, 1u, __ATOMIC_RELEASE); return 0;
}
FPS_EXPORT void s2a_ohos_fps_reset_clock(void) {
    __atomic_store_n(&state.last, 0ull, __ATOMIC_RELAXED);
    __atomic_store_n(&state.last_write, 0ull, __ATOMIC_RELAXED);
}
FPS_EXPORT unsigned s2a_ohos_fps_present_at(uint64_t now) {
    if (!__atomic_load_n(&state.active, __ATOMIC_ACQUIRE)) return 0;
    uint64_t last = __atomic_exchange_n(&state.last, now, __ATOMIC_RELAXED);
    // An idle/loading/background gap is not a rendered frame. Never convert it
    // into a large simulation step; the next normal cadence re-establishes time.
    if (state.speed_slot >= 0 && last && now > last && now - last < 1000000000ull) {
        float value = (float)((double)(now - last) * (30.0 / 1000000000.0));
        if (value < state.speed_low) value = state.speed_low;
        if (value > state.speed_high) value = state.speed_high;
        // Opt-in A/B probe only: keep the signed table and all other patches
        // intact while isolating large simulation steps at low render rates.
        if (state.diagnostic_step_cap > 0 && value > state.diagnostic_step_cap)
            value = state.diagnostic_step_cap;
        __atomic_store_n(state.slot_ptr[state.speed_slot], float_bits(value), __ATOMIC_RELAXED);
    }
    uint64_t written = __atomic_load_n(&state.last_write, __ATOMIC_RELAXED);
    if (!written || now < written || now - written >= 100000000ull) {
        write_data(); __atomic_store_n(&state.last_write, now, __ATOMIC_RELAXED);
    }
    if (state.condition_slot >= 0) {
        uint32_t value = __atomic_load_n(state.slot_ptr[state.condition_slot], __ATOMIC_RELAXED);
        if ((value == state.condition_value) == state.condition_equal) return 30;
    }
    return 60;
}

// Small SHA-256 implementation for the signed fixups -> runtime-table binding.
// Hashing untrusted input is bounded to 64 KiB. This does not implement signing.
static uint32_t rotate(uint32_t x, unsigned n) { return (x >> n) | (x << (32 - n)); }
static void sha_block(uint32_t h[8], const unsigned char block[64]) {
    static const uint32_t k[64] = {
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 };
    uint32_t w[64];
    for (unsigned i=0;i<16;++i) w[i]=(uint32_t)block[i*4]<<24|(uint32_t)block[i*4+1]<<16|(uint32_t)block[i*4+2]<<8|block[i*4+3];
    for (unsigned i=16;i<64;++i) {
        uint32_t a=w[i-15],b=w[i-2];
        w[i]=(rotate(a,7)^rotate(a,18)^(a>>3))+w[i-16]+(rotate(b,17)^rotate(b,19)^(b>>10))+w[i-7];
    }
    uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],v=h[7];
    for (unsigned i=0;i<64;++i) {
        uint32_t t1=v+(rotate(e,6)^rotate(e,11)^rotate(e,25))+((e&f)^(~e&g))+k[i]+w[i];
        uint32_t t2=(rotate(a,2)^rotate(a,13)^rotate(a,22))+((a&b)^(a&c)^(b&c));
        v=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
    }
    h[0]+=a;h[1]+=b;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=v;
}
void s2a_ohos_fps_digest(const void *input, size_t size, char out[65]) {
    uint32_t h[8]={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
    const unsigned char *data=input; size_t at=0;
    while (size-at>=64) { sha_block(h,data+at);at+=64; }
    unsigned char tail[64];size_t rem=size-at;
    for (unsigned i=0;i<64;++i) tail[i]=i<rem?data[at+i]:i==rem?0x80:0;
    if (rem>=56) { sha_block(h,tail);for(unsigned i=0;i<64;++i)tail[i]=0; }
    uint64_t bits=(uint64_t)size*8;
    for(unsigned i=0;i<8;++i)tail[63-i]=(unsigned char)(bits>>(i*8));
    sha_block(h,tail);
    static const char hex[]="0123456789abcdef";
    for(unsigned i=0;i<32;++i){unsigned v=(h[i/4]>>(24-(i%4)*8))&255;out[i*2]=hex[v>>4];out[i*2+1]=hex[v&15];}out[64]=0;
}

#ifndef S2A_OHOS_FPS_CORE_TEST
// Upstream runtime/src/fps.c slot writes (via android/native/fps_provider.c): a key-page
// address is written in place; the page is host memory made writable by fps.c key_rw.
int s2a_ohos_key_page_store32(uint64_t address, uint32_t value) {
    if (address & 3) return EINVAL;
    for (int i = 0; i < g_nmod; ++i) {
        module_t *m = &g_mod[i];
        uint64_t begin = (uint64_t)(uintptr_t)m->base + m->key_page_off;
        if (!m->base || !m->key_page_size || address < begin || address + 4 > begin + m->key_page_size) continue;
        __atomic_store_n((uint32_t *)(uintptr_t)address, value, __ATOMIC_RELEASE);
        return 0;
    }
    // fps.c's host frame-step page (dm_fps_state, 4 KB static in fps.c) is host memory, not guest.
    extern uint8_t *dm_fps_state;
    uint64_t page = (uint64_t)(uintptr_t)dm_fps_state;
    if (page && address >= page && address + 4 <= page + 4096) {
        __atomic_store_n((uint32_t *)(uintptr_t)address, value, __ATOMIC_RELAXED);
        return 0;
    }
    return ENOENT;
}
// 模块数据页上的运行表写（塞尔达 1.8.2：main+0x1c4ba40 f32 1→0.5）：OHOS 模块页是签名载体的私有映射，
// checked 写建不出共享别名（EINVAL/EOPNOTSUPP）。调用方已由 checked 核过「游戏视角可写」，这里只确认
// 地址落在已装模块映像内，直接原子写：页若被写跟踪保护，缺页走与游戏自己写同一条处理路径。
int s2a_ohos_module_store32(uint64_t address, uint32_t value) {
    if (address & 3) return EINVAL;
    for (int i = 0; i < g_nmod; ++i) {
        module_t *m = &g_mod[i];
        uint64_t begin = (uint64_t)(uintptr_t)m->base;
        // 只接数据段（data_off 起）：代码 / 只读段是可执行或只读映射，直接写会缺页。
        if (!m->base || !m->size || !m->data_off || address < begin + m->data_off || address + 4 > begin + m->size) continue;
        __atomic_store_n((uint32_t *)(uintptr_t)address, value, __ATOMIC_RELEASE);
        return 0;
    }
    return ENOENT;
}
FPS_EXPORT unsigned s2a_ohos_fps_present_hook(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) return 0;
    return s2a_ohos_fps_present_at((uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec);
}
FPS_EXPORT int s2a_ohos_fps_start(const char *dir) {
    if (!dir || !*dir || __atomic_load_n(&state.active, __ATOMIC_ACQUIRE)) return -EINVAL;
    char path[1200], line[256], expected[65] = "", abi[48] = "";
    if (snprintf(path,sizeof path,"%s/main.fixups.tsv",dir)>=(int)sizeof path) return -ENAMETOOLONG;
    FILE *f=fopen(path,"r");if(!f)return -errno;
    while(fgets(line,sizeof line,f)) {
        char key[64],value[96];
        if(sscanf(line,"# %63s %95s",key,value)!=2)continue;
        if(equal(key,"FPS_ABI")){if(*abi || strlen(value)>=sizeof abi){fclose(f);return -EINVAL;}strcpy(abi,value);}
        if(equal(key,"FPS_SHA256")){if(*expected || strlen(value)!=64){fclose(f);return -EINVAL;}strcpy(expected,value);}
    }
    int failure=ferror(f);fclose(f);if(failure)return -EIO;
    if(!*abi && !*expected) { s2a_ohos_fps_clear(); return 0; }
    if(!equal(abi,FPS_ABI)||!*expected)return -EINVAL;
    const char *requested=getenv("S2A_FPS");
    if(requested && equal(requested,"30")) { LOG("【红】本载体已包含60帧代码；切回原生帧率需对应原生载体，不能单关运行表");return -EINVAL; }
    if(snprintf(path,sizeof path,"%s/fps.tsv",dir)>=(int)sizeof path)return -ENAMETOOLONG;
    f=fopen(path,"rb");if(!f){LOG("【红】签名载体要求帧率表，缺失 %s",path);return -errno;}
    char *text=malloc(65537);if(!text){fclose(f);return -ENOMEM;}
    size_t size=fread(text,1,65537,f);failure=ferror(f);fclose(f);
    if(failure||size>65536){free(text);return -EIO;}
    char actual[65];s2a_ohos_fps_digest(text,size,actual);
    if(!equal(expected,actual)){free(text);LOG("【红】帧率表与已验证签名载体摘要不符");return -EINVAL;}
    s2a_ohos_fps_module modules[g_nmod];
    for(int i=0;i<g_nmod;++i) {
        module_t *m=&g_mod[i];
        modules[i]=(s2a_ohos_fps_module){m->name,m->base,m->size,m->data_off,m->key_page_off,m->key_page_off,m->key_page_size};
    }
    int rc=s2a_ohos_fps_prepare_text(text,size,s2a_main_build_id(),modules,(size_t)g_nmod);free(text);
    if(rc){LOG("【红】帧率表整组拒绝 rc=%d",rc);return rc;}
    const char *step_cap=getenv("DEBUG_S2A_FPS_STEP_CAP");
    if(step_cap && *step_cap) {
        float cap;
        if(state.speed_slot<0 || !decimal(step_cap,&cap) ||
           cap<state.speed_low || cap>state.speed_high) {
            LOG("【红】无效 FPS 步长诊断上限");return -EINVAL;
        }
        state.diagnostic_step_cap=cap;
        LOG("FPS diagnostic step cap=%g (experimental; not native/unpatched mode)",(double)cap);
    }
    const s2a_ohos_fps_module *main=named(modules,(size_t)g_nmod,"main");
    long page=sysconf(_SC_PAGESIZE);
    if(page<=0 || ((unsigned long)page&((unsigned long)page-1)) || (unsigned long)page>main->key_size)return -EINVAL;
    uintptr_t start=(uintptr_t)main->base+main->key_offset+SLOT_LOW*8u;
    uintptr_t begin=start&~((uintptr_t)page-1);
    size_t bytes=(size_t)((uintptr_t)main->base+main->key_offset+main->key_size-begin);
    if(mprotect((void *)begin,bytes,PROT_READ|PROT_WRITE)) { rc=-errno;s2a_ohos_fps_clear();return rc; }
    rc=s2a_ohos_fps_activate();
    if(!rc)LOG("帧率表已载入：build=%s target=60 动态步长=%d 过场门=%d 数据写入=%u；帧率尚待实测",s2a_main_build_id(),state.speed_slot>=0,state.condition_slot>=0,state.write_count);
    return rc;
}
#endif
