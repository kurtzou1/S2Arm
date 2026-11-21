// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Loaded only in an official AbilityKit native child process.
// The standalone probe's process watchdog must never run inside the game process.
#include <AbilityKit/native_child_process.h>
#include <cstdio>
#include <cstring>
#include <unistd.h>
#include <sys/stat.h>
int s2a_v0_probe_main(int argc, char** argv);
int s2a_h264_synthetic_probe();
int s2a_alias_read_probe();

extern "C" __attribute__((visibility("default"))) void S2AV0Main(NativeChildProcess_Args args) {
    int log=-1, count=0;
    for (auto* f=args.fdList.head; f && count++<8; f=f->next)
        if (f->fdName && std::strcmp(f->fdName,"v0_log")==0) log=f->fd;
    struct stat st{};
    if (log<0 || fstat(log,&st) || !S_ISREG(st.st_mode)) _exit(2);
    if (dup2(log,STDOUT_FILENO)<0 || dup2(log,STDERR_FILENO)<0) _exit(2);
    if (log>2) close(log);
    setvbuf(stdout,nullptr,_IOLBF,0);
    if (!args.entryParams || (std::strcmp(args.entryParams,"host") && std::strcmp(args.entryParams,"native-metadata") && std::strcmp(args.entryParams,"h264") && std::strcmp(args.entryParams,"alias-read"))) {
        std::puts("V0 result=FAIL reason=invalid_child_mode"); _exit(2);
    }
    std::printf("V0 child pid=%d ppid=%d sandbox=normal gameRuntime=not_loaded\n",getpid(),getppid());
    char name[]="v0_child", host[]="--host", native[]="--native-metadata";
    char* argv[]={name,std::strcmp(args.entryParams,"host")==0?host:native,nullptr};
    int rc=std::strcmp(args.entryParams,"alias-read")==0?s2a_alias_read_probe():std::strcmp(args.entryParams,"h264")==0?s2a_h264_synthetic_probe():s2a_v0_probe_main(2,argv);
    alarm(0);
    std::printf("V0 childExit=%d\n",rc); std::fflush(stdout);
    _exit(rc);
}
