# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Exercise actual probe_thread with synthetic TCB/stack memory, no SDK needed."""
import os
from pathlib import Path
import subprocess
import tempfile

s = Path(__file__).with_name('tsd_ohos.c').read_text(encoding='utf8')
s = s[s.index('static int probe_thread('):s.index('struct probe_work')]
harness = r'''
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <errno.h>
#define O_CLOEXEC 0
typedef int pthread_key_t;
typedef int pthread_attr_t;
static int test;
static uintptr_t value;
static uintptr_t thread_pointer(void) { return 0x10000; }
static int pipe2(int *p,int flags) { (void)flags;p[0]=1;p[1]=2;return 0; }
static int close(int p) { (void)p;return 0; }
static int pthread_setspecific(int k,void *p) { (void)k;value=(uintptr_t)p;return 0; }
static int pthread_self(void) { return 1; }
static int pthread_getattr_np(int p,int *a) { (void)p;*a=1;return test==4?11:0; }
static int pthread_attr_getstack(int *a,void **addr,size_t *size) { (void)a;*addr=(void*)0xf000;*size=3584;return test==5?22:0; }
static int pthread_attr_destroy(int *a) { (void)a;return 0; }
static int read_word(int *pipe,uintptr_t addr,uintptr_t *out) {
    (void)pipe;
    if(addr==0x20008) {*out=value;return 0;}
    int64_t off=(int64_t)addr-0x10000;
    if((off==-272&&test!=2)||(test==3&&off==-280)||((test==1||test==2)&&(off==-1024||off==-2048||off==-3072))) {*out=0x20000;return 0;}
    return EFAULT;
}
FUNCTION
int main(void) {
    int expected[]={0,0,ENOTSUP,ENOTSUP,11,22},bad=0;
    for(test=0;test<6;test++) {
        int64_t offset=123;int rc=probe_thread(1,&offset);
        int ok=rc==expected[test] && (rc?offset==123:offset==-272) && value==0;
        printf("case %d: %s rc=%d offset=%lld\n",test,ok?"PASS":"FAIL",rc,(long long)offset);bad+=!ok;
    }
    return bad?1:0;
}
'''.replace('FUNCTION', s)
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    src, exe = tmp / 'tsd.c', tmp / ('tsd.exe' if os.name == 'nt' else 'tsd')
    src.write_text(harness, encoding='utf8')
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', str(src), '-o', str(exe)], check=True)
    raise SystemExit(subprocess.run([str(exe)]).returncode)
