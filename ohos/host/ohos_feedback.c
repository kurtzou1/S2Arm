// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include <stdint.h>
#include <pthread.h>
#include <math.h>
#include <time.h>

typedef struct { float low_amp, low_hz, high_amp, high_hz; } pad_vibration;
_Static_assert(sizeof(pad_vibration)==16,"HID vibration ABI");
static pthread_mutex_t feedback_lock=PTHREAD_MUTEX_INITIALIZER;
static uint64_t generation=1, sequence, expires;
static int feedback_enabled, feedback_active;
static float amplitude;
static uint64_t now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000+t.tv_nsec/1000000; }
void s2a_ohos_feedback_state(int enabled,int active) {
    pthread_mutex_lock(&feedback_lock);
    if(feedback_enabled!=!!enabled || feedback_active!=!!active) { generation++; sequence++; amplitude=0; expires=0; }
    feedback_enabled=!!enabled; feedback_active=!!active;
    pthread_mutex_unlock(&feedback_lock);
}
uint64_t s2a_pad_rumble_session(void) {
    pthread_mutex_lock(&feedback_lock);
    uint64_t value=feedback_enabled&&feedback_active?generation:0;
    pthread_mutex_unlock(&feedback_lock); return value;
}
void s2a_pad_set_rumble_pair(uint64_t session,const pad_vibration values[2]) {
    if(!values) return;
    pthread_mutex_lock(&feedback_lock);
    if(session==generation && feedback_enabled && feedback_active) {
        float a=0;
        for(int i=0;i<2;i++) {
            float lo=values[i].low_amp,hi=values[i].high_amp;
            if(isfinite(lo)&&lo>a) a=lo;
            if(isfinite(hi)&&hi>a) a=hi;
        }
        amplitude=a>1?1:a; expires=now_ms()+1000; sequence++;
    }
    pthread_mutex_unlock(&feedback_lock);
}
void s2a_pad_stop_rumble(uint64_t session) {
    pthread_mutex_lock(&feedback_lock);
    if(session==generation) { amplitude=0; expires=0; sequence++; }
    pthread_mutex_unlock(&feedback_lock);
}
float s2a_ohos_feedback_read(void) {
    pthread_mutex_lock(&feedback_lock);
    float a=feedback_enabled&&feedback_active&&now_ms()<expires?amplitude:0;
    pthread_mutex_unlock(&feedback_lock); return a;
}
