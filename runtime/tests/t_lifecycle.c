#define S2A_LOGCON_IMPL
#include "../src/native.h"
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec; }
#include <unistd.h>
void s2a_host_shutdown(const char *why);
void s2a_term_install(void);
static int timeout_case;
static int early_stall;   // 11-14：收尾早期一步卡死（游戏卡死时的样子）；2 = 兜底里的冲日志也卡
static void event(char c) { write(1, &c, 1); }
void s2a_logcon_flush(void) { if(early_stall==2)for(;;)pause(); event('F'); }
void s2a_logcon_push(const char *p, size_t n) { (void)p;(void)n; }
void s2a_cs_shutdown(const char *why) { (void)why;if(timeout_case)sleep(3); }
void nxgal_gpu_hold(int on, const char *why) { (void)on;(void)why; }
void s2a_trap_report(const char *when) { (void)when; }   // 双补丁岛 brk 兜底汇总（traps.c）
void s2a_guest_freeze(int on) {(void)on;}
void s2a_track_stat_log(const char *s){(void)s;if(early_stall)for(;;)pause();}
uint64_t s2a_track_protected_pages(void){return 0;}
void s2a_direct_res_report(void){}
void s2a_direct_summary(int normal){event(normal?'N':'T');}
void s2a_sched_stat_log(const char *s){(void)s;}
int s2a_handle_peak(void){return 0;}
void s2a_yield_stat_log(const char *s){(void)s;}
void s2a_diag_stamp_report(void){}
void s2a_lockwake_report(void){}
void s2a_svc_count_report(const char *s){(void)s;}
void s2a_guest_va_report(const char *s){(void)s;}
void s2a_vm_low(const char *s){(void)s;}
void s2a_lowva_peak_report(const char *s){(void)s;}
int s2a_svc_park_all(int ms){(void)ms;return 0;}
void s2a_widen_scan(void){}
void s2a_svc_red_summary(void){}
void s2a_det_summary(void){}
void s2a_punch_summary(void){}   // svc_mem.c（#258 收局读数）；本测只链 lifecycle.c
unsigned s2a_unresolved_count(void){return 0;}
static void late(void){event('A');}
int main(void){
 int bad=0;
 // 期望（手算）：0 正常「NF」；1 C# 收尾超时 → 1.5 秒兜底「TF」；2 SIGTERM「NF」；
 //   3 早期统计一步永远卡住 → 兜底照样在 1.5 秒打汇总冲日志退出「TF」（兜底原先排在这一步之后，永远不开，alarm 10 秒杀掉 = 红）；
 //   4 同 3 且兜底里冲日志也卡 → 2.5 秒无条件退出「T」。退出码都是 0
 for(int k=0;k<5;k++){
  int fd[2];pipe(fd);pid_t p=fork();
  if(!p){alarm(10);close(fd[0]);dup2(fd[1],1);close(fd[1]);g_s2a_logfd=open("/dev/null",O_WRONLY);timeout_case=(k==1);early_stall=k==3?1:k==4?2:0;atexit(late);if(k==2){s2a_term_install();kill(getpid(),SIGTERM);for(;;)pause();}s2a_host_shutdown("fixture");_exit(50);}
  close(fd[1]);char buf[32];ssize_t at=0,n;while(at<(ssize_t)sizeof buf-1&&(n=read(fd[0],buf+at,sizeof buf-1-at))>0)at+=n;buf[at]=0;close(fd[0]);int st;waitpid(p,&st,0);
  int ok=WIFEXITED(st)&&WEXITSTATUS(st)==0&&!strcmp(buf,k==1||k==3?"TF":k==4?"T":"NF");printf("%s lifecycle %s：%s\n",ok?"✓":"✗",k==1?"watchdog":k==2?"SIGTERM":k==3?"early stall":k==4?"early stall + flush stall":"normal",buf);if(!ok)bad++;
 }
 printf("%s t_lifecycle：%d 处不符\n",bad?"✗":"✓",bad);return bad!=0;
}
