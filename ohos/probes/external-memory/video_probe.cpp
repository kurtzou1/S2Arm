// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Original 1280x720 baseline I_PCM image, no game or third-party media.
#include <cstdint>
#include <cstdio>
#include <vector>
#include <csignal>
#include <unistd.h>
extern "C" {
struct s2a_h264;
s2a_h264 *s2a_ohos_h264_open(int,int,int*);
int s2a_ohos_h264_decode(s2a_h264*,const uint8_t*,int,uint8_t*,int);
void s2a_ohos_h264_close(s2a_h264*);
}
struct Bits {
    std::vector<uint8_t> bytes; unsigned bit=0;
    void u(uint32_t v,unsigned n) { for(unsigned i=n;i>0;i--) { if(bit==0) bytes.push_back(0); bytes.back()|=((v>>(i-1))&1u)<<(7-bit);bit=(bit+1)&7; } }
    void ue(uint32_t v) {v++;unsigned n=0;for(uint32_t x=v;x>1;x>>=1)n++;u(0,n);u(v,n+1);}
    void se(int v) {ue(v<=0?static_cast<uint32_t>(-2*v):static_cast<uint32_t>(2*v-1));}
    void align() {if(bit)u(0,8-bit);}
    void finish() {u(1,1);align();}
};
static void nal(std::vector<uint8_t>& out,uint8_t header,const Bits& b) {
    out.insert(out.end(),{0,0,0,1,header});unsigned zeros=0;
    for(uint8_t x:b.bytes) {if(zeros>=2 && x<=3) {out.push_back(3);zeros=0;}out.push_back(x);zeros=x==0?zeros+1:0;}
}
static void timeout(int) {const char msg[]="H264_PROBE result=TIMEOUT watchdog=15s\n";write(2,msg,sizeof(msg)-1);_exit(124);}
int s2a_h264_synthetic_probe() {
    signal(SIGALRM,timeout);alarm(15);
    constexpr int w=1280,h=720;
    Bits s;s.u(66,8);s.u(0,8);s.u(31,8);s.ue(0);s.ue(0);s.ue(2);s.ue(1);s.u(0,1);s.ue(w/16-1);s.ue(h/16-1);s.u(1,1);s.u(1,1);s.u(0,1);s.u(0,1);s.finish();
    Bits p;p.ue(0);p.ue(0);p.u(0,1);p.u(0,1);p.ue(0);p.ue(0);p.ue(0);p.u(0,1);p.u(0,2);p.se(0);p.se(0);p.se(0);p.u(1,1);p.u(0,1);p.u(0,1);p.finish();
    Bits f;f.ue(0);f.ue(2);f.ue(0);f.u(0,4);f.ue(0);f.u(0,1);f.u(0,1);f.se(0);f.ue(1);
    for(int mb=0;mb<w*h/256;mb++) {f.ue(25);f.align();for(int i=0;i<384;i++)f.u(i<256?80:i<320?90:160,8);}f.finish();
    std::vector<uint8_t> packet;nal(packet,0x67,s);nal(packet,0x68,p);nal(packet,0x65,f);
    int hardware=0;s2a_h264* decoder=s2a_ohos_h264_open(w,h,&hardware);
    if(!decoder){std::puts("H264_PROBE result=UNSUPPORTED");return 77;}
    std::vector<uint8_t> output(w*h*3/2,0xcc);
    int rc=s2a_ohos_h264_decode(decoder,packet.data(),packet.size(),output.data(),output.size());
    if(rc){std::puts("H264_PROBE result=FAIL step=decode");s2a_ohos_h264_close(decoder);return 1;}
    unsigned bad=0;for(unsigned i=0;i<output.size();i++)if(output[i]!=(i<w*h?80:i<w*h*5/4?90:160))bad++;
    std::printf("H264_PROBE result=%s mismatches=%u bytes=%zu hardware=%d scope=one_original_I_PCM_frame_not_game_sequence\n",bad?"FAIL":"PASS",bad,output.size(),hardware);
    s2a_ohos_h264_close(decoder);alarm(0);return bad?1:0;
}
