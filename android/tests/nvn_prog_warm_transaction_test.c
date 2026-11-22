/* Standalone cache transaction tests. Valid bytes come ONLY from production save.
 * Profile mismatch is session-facts validation, not structural parser coverage. */
#define _POSIX_C_SOURCE 200809L
#include "nvn_vk_prog_warm.h"
#include "nvn_plat.h"
#include "direct/compile_request.h"
#include "direct/sha256.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static char directory[512], file_path[600];
static const char *profile = "profile-A", *case_name;
static const char closure[] = "closure-A";
static int fail_read, read_failures, checks, failures;
static int reset_during_read, read_resets;
static struct nvk_prog_rec fresh_session_record;
static void require(int ok, const char *why) { if (!ok) { fprintf(stderr,"SETUP FAIL %s\n",why); exit(2); } }
static void check(int ok,const char *why) { checks++; if(!ok){ failures++;printf("FAIL %s: %s\n",case_name,why); } }
const char *nvn_plat_dir(int which) { return which==NVN_PLAT_DIR_CACHE ? directory : NULL; }
int nvn_plat_flag(const char *name,int def) { (void)name;return def; }
void nvn_plat_log(int level,const char *cls,const char *text) { (void)level;(void)cls;(void)text; }
int s2a_direct_provider_compile_context(struct s2a_direct_compile_context *out) {
 memset(out,0,sizeof *out);out->session=1;out->generation=1;out->profile_json=profile;
 out->profile_bytes=strlen(profile);out->direct_abi=7;out->translator_closure=closure;return 0;
}
/* Only production TU redirects read. No data bytes are modified by the seam. */
ssize_t nvk_warm_transaction_test_read(int fd,void *data,size_t size) {
 if(fail_read){read_failures++;errno=EIO;return -1;}
 ssize_t result=read(fd,data,size);
 if(reset_during_read && result>0){
  reset_during_read=0;read_resets++;
  /* Model the allowed lifecycle interleaving while load holds no state lock.
   * Bytes are the unmodified output of the real production writer. */
  nvk_prog_warm_reset();nvk_prog_warm_note(&fresh_session_record);
 }
 return result;
}
static struct nvk_prog_rec record(unsigned id) {
 struct nvk_prog_rec r;memset(&r,0,sizeof r);memset(r.identity,(int)id,sizeof r.identity);
 static uint8_t c1buf[256][NVK_PROG_REC_C1_MIN];   /* c1 整段：记录只带指针，按 id 各用一块，note 时清单拷自己的副本 */
 memset(c1buf[id&255],(int)(id+10),NVK_PROG_REC_C1_MIN);
 r.stage_mask=1;r.c1_ok=1;r.c1[0]=c1buf[id&255];r.c1_len[0]=NVK_PROG_REC_C1_MIN;r.uses=1;return r;
}
/* 记录里的 c1 是清单自己的副本：比长度与内容，不比指针。 */
static int same_c1(const struct nvk_prog_rec *a,const struct nvk_prog_rec *b){
 if(a->c1_ok!=b->c1_ok)return 0;
 for(int st=0;st<NVK_PROG_REC_STAGES;st++)if(a->c1_ok&(1u<<st)){
  if(a->c1_len[st]!=b->c1_len[st]||!a->c1[st]||!b->c1[st]||memcmp(a->c1[st],b->c1[st],a->c1_len[st]))return 0;}
 return 1;
}
static void remove_file(void) { if(unlink(file_path)) require(errno==ENOENT,"remove owned cache file"); }
static void write_trusted(const struct nvk_prog_rec *disk) {
 nvk_prog_warm_reset();profile="profile-A";fail_read=0;remove_file();
 nvk_prog_warm_note(disk);nvk_prog_warm_save();
 struct stat st;require(stat(file_path,&st)==0 && S_ISREG(st.st_mode) && st.st_size>0,"production writer created trusted fixture");
 nvk_prog_warm_reset();
}
static void seed_session(const struct nvk_prog_rec *live) {
 nvk_prog_warm_note(live);nvk_prog_warm_stat_build(0);nvk_prog_warm_stat_build(1);
 nvk_prog_warm_stat_build(-1);nvk_prog_warm_stat_draw_hit();nvk_prog_warm_stat_draw_miss();
}
static void check_session_stats(void) {
 struct nvk_prog_warm_stats s;nvk_prog_warm_stats(&s);
 check(s.recorded==1,"note count retained");check(s.built==1,"built count retained");
 check(s.failed==1,"failed count retained");check(s.retried==1,"retry count retained");
 check(s.draw_hits==1,"draw hit count retained");check(s.draw_miss==1,"draw miss count retained");
}
static void test_load(int mode) {
 const char *names[]={"missing file","ordinary read EIO","profile validation rejection","successful merge"};
 case_name=names[mode];struct nvk_prog_rec disk=record(22),live=record(11);
 write_trusted(&disk);if(mode==0)remove_file();seed_session(&live);
 profile=mode==2?"profile-B":"profile-A";read_failures=0;fail_read=mode==1;
 int result=nvk_prog_warm_load();fail_read=0;
 printf("RESULT %s: load=%d read_failures=%d live=%d disk=%d\n",case_name,result,read_failures,nvk_prog_warm_contains(live.identity),nvk_prog_warm_contains(disk.identity));
 check(result==(mode==3?1:0),"load reports accepted disk count");
 check(nvk_prog_warm_contains(live.identity),"same-session note retained");
 check(nvk_prog_warm_contains(disk.identity)==(mode==3),"only accepted disk record merged");
 if(mode==1)check(read_failures==1,"ordinary read failure seam exercised");
 check_session_stats();nvk_prog_warm_reset();profile="profile-A";remove_file();
}
static void test_reset(void) {
 case_name="explicit cross-session reset";struct nvk_prog_rec disk=record(22),live=record(11);
 write_trusted(&disk);require(nvk_prog_warm_load()==1,"load trusted reset control");seed_session(&live);
 nvk_prog_warm_reset();check(!nvk_prog_warm_contains(live.identity),"old live note gone");
 check(!nvk_prog_warm_contains(disk.identity),"old disk note gone");
 struct nvk_prog_rec out;check(nvk_prog_warm_take(&out)==0,"old plan gone");check(nvk_prog_warm_pending()==0,"pending empty");
 struct nvk_prog_warm_stats s;nvk_prog_warm_stats(&s);
 check(!s.loaded&&!s.rejected&&!s.recorded&&!s.built&&!s.failed&&!s.retried&&!s.pending&&!s.draw_hits&&!s.draw_miss,"all session stats reset");remove_file();
}
static void test_duplicate(int live_uses) {
 case_name=live_uses<5?"duplicate disk uses higher":"duplicate live uses higher";
 struct nvk_prog_rec disk=record(22),live=record(22),out;
 disk.uses=5;write_trusted(&disk);
 live.uses=(uint32_t)live_uses;live.stage_mask=3;live.c1_ok=3;live.lp_ok=1;
 static uint8_t c99[NVK_PROG_REC_C1_MIN];memset(c99,99,sizeof c99);
 memset(live.keys,77,sizeof live.keys);for(int st=0;st<2;st++){live.c1[st]=c99;live.c1_len[st]=sizeof c99;}
 nvk_prog_warm_note(&live);
 check(nvk_prog_warm_load()==1,"one disk record accepted");
 int have=nvk_prog_warm_take(&out);check(have==1,"one merged record planned");
 if(have){
  check(!memcmp(out.identity,live.identity,32),"duplicate identity unchanged");
  check(out.uses==(uint32_t)(live_uses>5?live_uses:5),"uses is max, not sum");
  check(out.stage_mask==live.stage_mask && out.c1_ok==live.c1_ok && out.lp_ok==live.lp_ok,
        "current session metadata retained");
  check(!memcmp(out.keys,live.keys,sizeof live.keys),"current keys retained");
  check(same_c1(&out,&live),"current constants retained");
 }
 check(nvk_prog_warm_take(&out)==0,"duplicate scheduled only once");
 struct nvk_prog_warm_stats stats;nvk_prog_warm_stats(&stats);
 check(stats.recorded==1,"duplicate merge does not count as note");
 nvk_prog_warm_reset();remove_file();
}
static void test_disk_plan(void) {
 case_name="disk-only immutable hot plan";
 struct nvk_prog_rec hot=record(33),cold=record(22),live=record(11),late=record(44),out;
 hot.uses=9;cold.uses=2;live.uses=100;late.uses=200;
 nvk_prog_warm_reset();profile="profile-A";remove_file();
 nvk_prog_warm_note(&cold);nvk_prog_warm_note(&hot);nvk_prog_warm_save();
 struct stat st;require(stat(file_path,&st)==0 && st.st_size>0,"production plan writer");
 nvk_prog_warm_reset();nvk_prog_warm_note(&live);
 check(nvk_prog_warm_load()==2,"two disk records accepted");
 check(nvk_prog_warm_contains(live.identity),"high-use live-only note retained");
 check(nvk_prog_warm_pending()==2,"plan excludes live-only note");
 /* Neither new notes nor metadata updates may rewrite the frozen plan. */
 nvk_prog_warm_note(&late);struct nvk_prog_rec updated=hot;
 static uint8_t c88[NVK_PROG_REC_C1_MIN];memset(c88,88,sizeof c88);updated.c1[0]=c88;updated.c1_len[0]=sizeof c88;nvk_prog_warm_note(&updated);
 int have=nvk_prog_warm_take(&out);check(have==1,"first plan entry exists");
 if(have){check(!memcmp(out.identity,hot.identity,32),"disk hot entry first");
 check(out.uses==9 && same_c1(&out,&hot),"plan unchanged by later note");}
 have=nvk_prog_warm_take(&out);check(have==1,"second plan entry exists");
 if(have)check(!memcmp(out.identity,cold.identity,32),"disk cold entry second");
 check(nvk_prog_warm_take(&out)==0,"no live-only or late note in plan");
 check(nvk_prog_warm_pending()==0,"plan fully consumed");
 nvk_prog_warm_reset();remove_file();
}
static void test_reset_during_read(void) {
 case_name="new session during trusted read";
 struct nvk_prog_rec disk=record(22),old_live=record(11),out;
 write_trusted(&disk);seed_session(&old_live);
 fresh_session_record=record(55);read_resets=0;reset_during_read=1;
 int result=nvk_prog_warm_load();reset_during_read=0;
 printf("RESULT %s: load=%d resets=%d\n",case_name,result,read_resets);
 check(read_resets==1,"reset interleaving actually exercised");
 check(nvk_prog_warm_contains(fresh_session_record.identity),"fresh session note survives old load");
 check(!nvk_prog_warm_contains(old_live.identity),"old session note remains cleared");
 check(!nvk_prog_warm_contains(disk.identity),"old transaction disk record not installed");
 check(nvk_prog_warm_pending()==0,"old transaction plan not installed");
 check(nvk_prog_warm_take(&out)==0,"no old transaction plan entry");
 struct nvk_prog_warm_stats stats;nvk_prog_warm_stats(&stats);
 check(stats.recorded==1,"only fresh session note recorded");
 check(!stats.loaded&&!stats.rejected&&!stats.built&&!stats.failed&&!stats.retried&&
       !stats.draw_hits&&!stats.draw_miss,"old transaction cannot restore old statistics");
 nvk_prog_warm_reset();remove_file();
}
int main(void) {
 char tmp[]="/tmp/nvk-warm-transaction.XXXXXX";char *p=mkdtemp(tmp);require(p!=NULL,"temporary directory");
 require(snprintf(directory,sizeof directory,"%s",p)>0,"directory name");
 s2a_sha256 hash; uint8_t digest[32]; char hex[17];
 s2a_sha256_init(&hash);s2a_sha256_update(&hash,closure,strlen(closure));s2a_sha256_final(&hash,digest);
 for(size_t i=0;i<8;i++) snprintf(hex+i*2,3,"%02x",(unsigned)digest[i]);
 int len=snprintf(file_path,sizeof file_path,"%s/programs-v1-%s.bin",p,hex);
 require(len>0&&(size_t)len<sizeof file_path,"fixture name");
 for(int mode=0;mode<4;mode++) { test_load(mode); }
 test_reset();test_duplicate(3);test_duplicate(8);test_disk_plan();test_reset_during_read();nvk_prog_warm_reset();
 require(rmdir(directory)==0,"remove owned temporary directory");
 printf("TOTAL cases=9 checks=%d failures=%d\n",checks,failures);return failures?1:0;
}
