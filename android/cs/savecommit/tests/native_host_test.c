// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 S2Arm contributors
#define _GNU_SOURCE
#include "../../../native/s2a_savecommit.h"
#include <dirent.h>
#include <grp.h>
#include <sys/prctl.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/xattr.h>
#include <unistd.h>

static int failures, checks, force_copy, fail_write, partial_write, fake_exchange, forced_clones, forced_writes, exchange_errno, force_no_xattr, fail_readonly_sync;
static int observed_reflink_calls, observed_reflink_errno, write_errno, fail_token_file_sync, fail_token_directory_sync;
static pthread_mutex_t probe_lock = PTHREAD_MUTEX_INITIALIZER;
static char probe_names[128][100];
static int probe_count, probe_bad;
#define CHECK(x) do { ++checks; if (!(x)) { ++failures; fprintf(stderr,"FAIL line %d: %s (errno=%d)\n",__LINE__,#x,errno); } } while (0)
static void path(char *out,const char *a,const char *b) { if(snprintf(out,4096,"%s/%s",a,b)>=4096) abort(); }
static void mkdir_ok(const char *p) { if(mkdir(p,0700)) {perror(p);abort();} }
static void put(const char *p,const void *v,size_t n) { int fd=open(p,O_CREAT|O_EXCL|O_WRONLY,0600);if(fd<0)abort();if(write(fd,v,n)!=(ssize_t)n)abort();if(close(fd))abort(); }
static uint64_t hash_bytes(const unsigned char *v,size_t n) { uint64_t h=UINT64_C(14695981039346656037); for(size_t i=0;i<n;i++) h=(h^v[i])*UINT64_C(1099511628211); return h; }
static int equals(const char *p,const void *v,size_t n) { unsigned char b[8192]; int fd=open(p,O_RDONLY|O_NOFOLLOW);if(fd<0)return 0;ssize_t got=read(fd,b,sizeof b);close(fd);return got==(ssize_t)n && !memcmp(b,v,n) && hash_bytes(b,n)==hash_bytes(v,n); }
static int absent(const char *p) {struct stat st;return lstat(p,&st)<0&&errno==ENOENT;}
static int entries(const char *p) {DIR*d=opendir(p);if(!d)return -1;int n=0;struct dirent*e;while((e=readdir(d)))if(strcmp(e->d_name,".")&&strcmp(e->d_name,".."))n++;closedir(d);return n;}
/* This only traverses mkdtemp-owned fixtures, never follows links. */
static void cleanup(const char *p) {struct stat st;if(lstat(p,&st))return;if(!S_ISDIR(st.st_mode)){unlink(p);return;}DIR*d=opendir(p);if(!d)abort();struct dirent*e;while((e=readdir(d))){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;char q[4096];path(q,p,e->d_name);cleanup(q);}closedir(d);if(rmdir(p))abort();}
int __real_ioctl(int,unsigned long,...);
int __wrap_ioctl(int fd,unsigned long req,...) {va_list ap;va_start(ap,req);unsigned long arg=va_arg(ap,unsigned long);va_end(ap);if(force_copy&&req==FICLONE){++forced_clones;errno=EOPNOTSUPP;return -1;}int rc=__real_ioctl(fd,req,arg);if(req==FICLONE){observed_reflink_calls++;observed_reflink_errno=rc<0?errno:0;}return rc;}
ssize_t __real_write(int,const void*,size_t);
ssize_t __wrap_write(int fd,const void*b,size_t n) {if(fail_write){++forced_writes;errno=write_errno?write_errno:EIO;return -1;}if(partial_write&&n>7)n=7;return __real_write(fd,b,n);}
int __real_s2a_savecommit_exchange(const char*,const char*);
int __wrap_s2a_savecommit_exchange(const char*a,const char*b){if(fake_exchange)return 0;return __real_s2a_savecommit_exchange(a,b);}

long __real_syscall(long,...);
long __wrap_syscall(long number,...) {
 if(number!=SYS_renameat2) { fprintf(stderr,"unexpected syscall wrapper number %ld\n",number);abort(); }
 va_list ap;va_start(ap,number);int a=va_arg(ap,int);const char *an=va_arg(ap,const char*);int b=va_arg(ap,int);const char *bn=va_arg(ap,const char*);int flags=va_arg(ap,int);va_end(ap);
 if(exchange_errno){errno=exchange_errno;return -1;}
 return __real_syscall(number,a,an,b,bn,flags);
}

int __real_fsetxattr(int,const char*,const void*,size_t,int);
int __wrap_fsetxattr(int fd,const char*n,const void*v,size_t z,int f) {
 if(force_no_xattr){errno=ENOTSUP;return -1;}
 return __real_fsetxattr(fd,n,v,z,f);
}
ssize_t __real_fgetxattr(int,const char*,void*,size_t);
ssize_t __wrap_fgetxattr(int fd,const char*n,void*v,size_t z) {
 if(force_no_xattr){errno=ENOTSUP;return -1;}
 return __real_fgetxattr(fd,n,v,z);
}
int __real_mkdirat(int,const char*,mode_t);
int __wrap_mkdirat(int fd,const char *name,mode_t mode) {
 if(!strncmp(name,".s2a_probe_",11)) {
  pthread_mutex_lock(&probe_lock);
  char prefix[80];snprintf(prefix,sizeof prefix,".s2a_probe_%ld_",(long)getpid());
  if(strncmp(name,prefix,strlen(prefix))||strlen(name)<=strlen(prefix))probe_bad=1;
  for(int i=0;i<probe_count;i++)if(!strcmp(name,probe_names[i]))probe_bad=1;
  if(probe_count>=128||strlen(name)>=100)probe_bad=1;
  else strcpy(probe_names[probe_count++],name);
  pthread_mutex_unlock(&probe_lock);
 }
 return __real_mkdirat(fd,name,mode);
}
static void test_token_fallback(const char *root) {
 char d[4096],p[4096];path(d,root,"fallback-token");mkdir_ok(d);
 unsigned char in[64],out[64];for(size_t i=0;i<64;i++)in[i]=(unsigned char)(255-i);
 size_t n=999;force_no_xattr=1;
 CHECK(s2a_savecommit_read_token(d,out,64,&n)==0&&n==0);
 CHECK(s2a_savecommit_write_token(d,in,64)==0);
 CHECK(s2a_savecommit_read_token(d,out,64,&n)==0&&n==64&&!memcmp(in,out,64));
 CHECK(s2a_savecommit_read_token(d,out,2,&n)==ERANGE&&n==64);
 path(p,d,".s2a_token.tmp");CHECK(absent(p));
 fail_write=1;int rc=s2a_savecommit_write_token(d,(const unsigned char*)"bad",3);fail_write=0;
 CHECK(rc==EIO);CHECK(absent(p));
 CHECK(s2a_savecommit_read_token(d,out,64,&n)==0&&n==64&&!memcmp(in,out,64));
 char cloned[4096];path(cloned,root,"fallback-token-clone");CHECK(s2a_savecommit_clone_tree(d,cloned)==0);path(p,cloned,".s2a_token");CHECK(equals(p,in,64));CHECK(s2a_savecommit_read_token(cloned,out,64,&n)==0&&n==64&&!memcmp(in,out,64));
 CHECK(s2a_savecommit_write_token(d,in,0)==0);
 CHECK(s2a_savecommit_read_token(d,out,64,&n)==0&&n==0);
 force_no_xattr=0;
}
/* Reserved temporary metadata may survive a killed writer. Only ordinary
 * files may be replaced; rejected entries and the committed token must survive. */
static void test_token_stale_file(const char *root)
{
 const unsigned char old[] = {1, 0, 2}, next[] = {3, 0, 4, 5};
 const char stale[] = "interrupted token";
 force_no_xattr=1;
 for (int kind=0; kind<4; kind++) {
  char name[64],d[4096],tmp[4096],final[4096],alias[4096];
  snprintf(name,sizeof name,"stale-token-file-%d",kind);path(d,root,name);mkdir_ok(d);
  path(tmp,d,".s2a_token.tmp");path(final,d,".s2a_token");path(alias,d,"alias");
  CHECK(s2a_savecommit_write_token(d,old,sizeof old)==0);
  if(kind==2) { put(alias,stale,sizeof stale);CHECK(link(alias,tmp)==0); }
  else put(tmp,stale,kind==0?0:sizeof stale);
  size_t length=kind==3?0:sizeof next;
  int rc=s2a_savecommit_write_token(d,next,length);
  CHECK(rc==0);CHECK(absent(tmp));CHECK(equals(final,next,length));
  unsigned char out[64];size_t n=999;
  CHECK(s2a_savecommit_read_token(d,out,sizeof out,&n)==0&&n==length&&!memcmp(out,next,n));
  if(kind==2) { struct stat st;CHECK(equals(alias,stale,sizeof stale));CHECK(lstat(alias,&st)==0&&st.st_nlink==1); }
 }
 force_no_xattr=0;
}
static void test_token_stale_nonregular(const char *root)
{
 const unsigned char old[] = {9, 0, 8}, next[] = {7, 0, 6};
 const char keep[] = "must survive";
 force_no_xattr=1;
 for(int kind=0;kind<4;kind++) {
  char name[64],d[4096],tmp[4096],final[4096],target[4096],child[4096];
  snprintf(name,sizeof name,"stale-token-other-%d",kind);path(d,root,name);mkdir_ok(d);
  path(tmp,d,".s2a_token.tmp");path(final,d,".s2a_token");path(target,d,"target");
  CHECK(s2a_savecommit_write_token(d,old,sizeof old)==0);
  if(kind==0) { put(target,keep,sizeof keep);CHECK(symlink("target",tmp)==0); }
  else if(kind==1) CHECK(symlink("missing",tmp)==0);
  else if(kind==2) CHECK(mkfifo(tmp,0600)==0);
  else { mkdir_ok(tmp);path(child,tmp,"child");put(child,keep,sizeof keep); }
  struct stat before,after;CHECK(lstat(tmp,&before)==0);
  CHECK(s2a_savecommit_write_token(d,next,sizeof next)==EEXIST);
  CHECK(lstat(tmp,&after)==0&&before.st_dev==after.st_dev&&before.st_ino==after.st_ino&&before.st_mode==after.st_mode);
  CHECK(equals(final,old,sizeof old));
  if(kind==0) CHECK(equals(target,keep,sizeof keep));
  else if(kind==1) { path(target,d,"missing");CHECK(absent(target)); }
  else if(kind==3) CHECK(equals(child,keep,sizeof keep));
 }
 force_no_xattr=0;
}
static void test_token_stale_failure(const char *root)
{
 const unsigned char old[] = {11, 0, 12}, next[] = {13, 0, 14};
 force_no_xattr=1;
 for(int kind=0;kind<3;kind++) {
  char name[64],d[4096],tmp[4096],final[4096];
  snprintf(name,sizeof name,"stale-token-failure-%d",kind);path(d,root,name);mkdir_ok(d);
  path(tmp,d,".s2a_token.tmp");path(final,d,".s2a_token");
  CHECK(s2a_savecommit_write_token(d,old,sizeof old)==0);put(tmp,"stale",5);
  int writes_before=forced_writes;
  if(kind==0) fail_write=1;
  else if(kind==1) fail_token_file_sync=1;
  else fail_token_directory_sync=1;
  int rc=s2a_savecommit_write_token(d,next,sizeof next);
  if(kind==0) CHECK(forced_writes>writes_before);
  if(kind==1) CHECK(fail_token_file_sync==0);
  if(kind==2) CHECK(fail_token_directory_sync==0);
  fail_write=fail_token_file_sync=fail_token_directory_sync=0;
  CHECK(rc==EIO);CHECK(absent(tmp));
  /* Directory sync is after rename: error propagation is not rollback. */
  CHECK(kind==2?equals(final,next,sizeof next):equals(final,old,sizeof old));
  CHECK(s2a_savecommit_write_token(d,next,sizeof next)==0);CHECK(equals(final,next,sizeof next));
 }
 force_no_xattr=0;
}
static void test_metadata(const char *root) {
 char a[4096],b[4096],p[4096];path(a,root,"metadata-source");path(b,root,"metadata-clone");mkdir_ok(a);
 path(p,a,"value");put(p,"metadata",8);CHECK(chmod(p,0640)==0);
 const struct timespec stamp[2]={{1234567890,123456789},{1234567891,987654321}};
 CHECK(utimensat(AT_FDCWD,p,stamp,0)==0);CHECK(chmod(a,0750)==0);CHECK(utimensat(AT_FDCWD,a,stamp,0)==0);
 CHECK(s2a_savecommit_clone_tree(a,b)==0);struct stat st;
 CHECK(stat(b,&st)==0);CHECK((st.st_mode&0777)==0750);CHECK(st.st_mtim.tv_sec==stamp[1].tv_sec&&st.st_mtim.tv_nsec==stamp[1].tv_nsec);
 path(p,b,"value");CHECK(stat(p,&st)==0);CHECK((st.st_mode&0777)==0640);CHECK(st.st_mtim.tv_sec==stamp[1].tv_sec&&st.st_mtim.tv_nsec==stamp[1].tv_nsec);
}

int __real_fsync(int);
int __wrap_fsync(int fd) {
 struct stat st;
 if(fail_token_file_sync && fstat(fd,&st)==0 && S_ISREG(st.st_mode)){fail_token_file_sync=0;errno=EIO;return -1;}
 if(fail_token_directory_sync && fstat(fd,&st)==0 && S_ISDIR(st.st_mode)){fail_token_directory_sync=0;errno=EIO;return -1;}
 if(fail_readonly_sync && fstat(fd,&st)==0 && S_ISDIR(st.st_mode) && (st.st_mode&0777)==0550){fail_readonly_sync=0;errno=EIO;return -1;}
 return __real_fsync(fd);
}
static void test_readonly_rollback(const char *root) {
 char a[4096],b[4096],p[4096],q[4096];path(a,root,"readonly-source");path(b,root,"readonly-clone");mkdir_ok(a);
 path(p,a,"readonly-child");mkdir_ok(p);path(q,p,"data");put(q,"safe",4);CHECK(chmod(p,0550)==0);
 fail_readonly_sync=1;int rc=s2a_savecommit_clone_tree(a,b);CHECK(fail_readonly_sync==0);fail_readonly_sync=0;
 CHECK(rc==EIO);CHECK(absent(b));CHECK(equals(q,"safe",4));CHECK(chmod(p,0700)==0);
}

static void test_clone(const char *root) {
 char src[4096],dst[4096],p[4096],q[4096],nested[4096];path(src,root,"source");mkdir_ok(src);path(nested,src,"nested");mkdir_ok(nested);unsigned char data[4096];for(size_t i=0;i<sizeof data;i++)data[i]=(unsigned char)(i*37u+11u);path(p,nested,"binary");put(p,data,sizeof data);path(p,src,"empty");put(p,"",0);
 path(dst,root,"clone");CHECK(s2a_savecommit_clone_tree(src,dst)==0);path(p,dst,"nested/binary");CHECK(equals(p,data,sizeof data));path(p,dst,"empty");CHECK(equals(p,"",0));CHECK(s2a_savecommit_clone_tree(src,dst)==EEXIST);path(p,dst,"nested/binary");CHECK(equals(p,data,sizeof data));
 path(p,root,"destination-link");CHECK(symlink(src,p)==0);CHECK(s2a_savecommit_clone_tree(src,p)==EEXIST);struct stat linkstat;CHECK(lstat(p,&linkstat)==0&&S_ISLNK(linkstat.st_mode));
 CHECK(s2a_savecommit_clone_tree(src,nested)==EEXIST);
 path(p,src,"inside");CHECK(s2a_savecommit_clone_tree(src,p)>0);CHECK(absent(p));CHECK(s2a_savecommit_clone_tree(src,src)>0);CHECK(s2a_savecommit_clone_tree(src,root)>0);
 path(p,root,"source-link");CHECK(symlink(src,p)==0);path(q,root,"linked-clone");CHECK(s2a_savecommit_clone_tree(p,q)>0);CHECK(absent(q));
 path(p,src,"bad-link");CHECK(symlink("nested/binary",p)==0);path(q,root,"bad-clone");CHECK(s2a_savecommit_clone_tree(src,q)>0);CHECK(absent(q));CHECK(unlink(p)==0);path(p,src,"fifo");CHECK(mkfifo(p,0600)==0);CHECK(s2a_savecommit_clone_tree(src,q)>0);CHECK(absent(q));CHECK(unlink(p)==0);
 path(q,root,"copy-fallback");force_copy=1;partial_write=1;int rc=s2a_savecommit_clone_tree(src,q);partial_write=0;force_copy=0;CHECK(rc==0);CHECK(forced_clones==0);path(p,q,"nested/binary");CHECK(equals(p,data,sizeof data));
 path(q,root,"copy-error");force_copy=1;fail_write=1;rc=s2a_savecommit_clone_tree(src,q);fail_write=0;force_copy=0;CHECK(rc==EIO);CHECK(forced_writes>0);CHECK(absent(q));path(p,src,"nested/binary");CHECK(equals(p,data,sizeof data));
}
static void test_exchange(const char *root) {char a[4096],b[4096],p[4096],q[4096];path(a,root,"exchange-a");path(b,root,"exchange-b");mkdir_ok(a);mkdir_ok(b);path(p,a,"value");put(p,"OLD\0A",5);path(q,b,"value");put(q,"NEW\0B",5);CHECK(s2a_savecommit_exchange(a,b)==0);CHECK(equals(p,"NEW\0B",5));CHECK(equals(q,"OLD\0A",5));path(q,root,"missing");CHECK(s2a_savecommit_exchange(a,q)==ENOENT);CHECK(equals(p,"NEW\0B",5));CHECK(absent(q));
 const int errors[]={EXDEV,ENOSYS,EOPNOTSUPP};for(size_t i=0;i<sizeof errors/sizeof errors[0];i++){exchange_errno=errors[i];int rc=s2a_savecommit_exchange(a,b);exchange_errno=0;CHECK(rc==errors[i]);CHECK(equals(p,"NEW\0B",5));path(q,b,"value");CHECK(equals(q,"OLD\0A",5));}
}
static void test_token_sync(const char*root) {char d[4096],link[4096];path(d,root,"token");mkdir_ok(d);unsigned char token[65],out[65];for(size_t i=0;i<sizeof token;i++)token[i]=(unsigned char)(i*3);size_t len=999;CHECK(s2a_savecommit_read_token(d,out,sizeof out,&len)==0);CHECK(len==0);CHECK(s2a_savecommit_write_token(d,token,0)==0);len=999;CHECK(s2a_savecommit_read_token(d,out,sizeof out,&len)==0&&len==0);CHECK(s2a_savecommit_write_token(d,token,64)==0);memset(out,255,sizeof out);len=999;CHECK(s2a_savecommit_read_token(d,out,sizeof out,&len)==0);CHECK(len==64&&!memcmp(out,token,64));len=999;CHECK(s2a_savecommit_read_token(d,out,3,&len)==ERANGE);CHECK(len==64);CHECK(s2a_savecommit_write_token(d,token,65)==EINVAL);len=999;CHECK(s2a_savecommit_read_token(d,out,sizeof out,&len)==0);CHECK(len==64&&!memcmp(out,token,64));CHECK(s2a_savecommit_sync_directory(d)==0);path(link,root,"token-link");CHECK(symlink(d,link)==0);CHECK(s2a_savecommit_sync_directory(link)>0);CHECK(s2a_savecommit_write_token(link,token,1)>0);CHECK(s2a_savecommit_read_token(link,out,sizeof out,&len)>0);len=999;CHECK(s2a_savecommit_read_token(d,out,sizeof out,&len)==0&&len==64&&!memcmp(out,token,64));}
struct worker {char dir[4096];int result;};
static void *work(void *v) {struct worker*w=v;unsigned char in[64],out[64];memset(in,(unsigned char)w->dir[strlen(w->dir)-1],64);w->result=0;for(int i=0;i<20;i++){size_t n=0;int s=s2a_savecommit_supported(w->dir);if((s!=0&&s!=1)||s2a_savecommit_write_token(w->dir,in,64)||s2a_savecommit_read_token(w->dir,out,64,&n)||n!=64||memcmp(in,out,64)||s2a_savecommit_sync_directory(w->dir))w->result=1;}return NULL;}
static void test_supported_concurrent(const char*root) {char d[4096],p[4096];path(d,root,"probe");mkdir_ok(d);path(p,d,"sentinel");put(p,"keep",4);for(int i=0;i<5;i++){int s=s2a_savecommit_supported(d);CHECK(s==0||s==1);CHECK(entries(d)==1);CHECK(equals(p,"keep",4));}exchange_errno=EXDEV;int supported=s2a_savecommit_supported(d);exchange_errno=0;CHECK(supported==0);CHECK(entries(d)==1);struct worker workers[4];pthread_t threads[4];for(int i=0;i<4;i++){char name[32];snprintf(name,sizeof name,"thread-%d",i);path(workers[i].dir,root,name);mkdir_ok(workers[i].dir);if(pthread_create(&threads[i],NULL,work,&workers[i]))abort();}for(int i=0;i<4;i++){CHECK(pthread_join(threads[i],NULL)==0);CHECK(workers[i].result==0);DIR*dir=opendir(workers[i].dir);if(!dir)abort();struct dirent*e;while((e=readdir(dir)))CHECK(strncmp(e->d_name,".s2a_probe_",11)!=0);closedir(dir);}}
/* Platform policy is ordinary copying, not probing a forbidden optimization.
 * Real I/O errors must retain their errno, preserve the original and roll back. */
static void test_copy_errors(const char *root)
{
    char src[4096], dst[4096], original[4096];
    path(src, root, "copy-errors-source"); mkdir_ok(src);
    path(original, src, "value"); put(original, "original-data", 13);
    const int errors[] = { EACCES, EPERM, EIO, ENOSPC };
    int before = entries("/proc/self/fd");
    CHECK(before >= 0);
    for (size_t i = 0; i < sizeof errors / sizeof errors[0]; ++i) {
        char name[32]; snprintf(name, sizeof name, "copy-error-%d", errors[i]);
        path(dst, root, name);
        int writes_before = forced_writes;
        fail_write = 1; write_errno = errors[i];
        int rc = s2a_savecommit_clone_tree(src, dst);
        fail_write = 0; write_errno = 0;
        CHECK(rc == errors[i]);
        CHECK(forced_writes > writes_before);
        CHECK(equals(original, "original-data", 13));
        CHECK(absent(dst));
        CHECK(entries("/proc/self/fd") == before);
    }
}
/* Ancestor identity checks need search permission, not directory listing.
 * Verify DAC really denies read: privileged hosts must not fake this regression. */
static int test_search_only_ancestor(const char *root)
{
    char gate[4096], workdir[4096], src[4096], dst[4096], other[4096];
    char child[4096], nested[4096], alias[4096], link[4096], p[4096], q[4096];
    path(gate, root, "search-only"); mkdir_ok(gate);
    path(workdir, gate, "owned"); mkdir_ok(workdir);
    path(src, workdir, "source"); mkdir_ok(src);
    path(other, workdir, "other"); mkdir_ok(other);
    path(child, src, "child"); mkdir_ok(child);
    path(p, src, "value"); put(p, "source", 6);
    path(q, other, "value"); put(q, "other", 5);
    path(dst, workdir, "clone");
    path(nested, child, "forbidden-clone");
    path(alias, src, "../source");
    path(link, workdir, "final-link"); CHECK(symlink(src, link) == 0);
    CHECK(chmod(gate, 0100) == 0);
    int fd = open(gate, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    int denied = fd < 0 && errno == EACCES;
    if (fd >= 0) close(fd);
    if (!denied) {
        chmod(gate, 0700);
        fprintf(stderr, "ENV_NOT_READY: uid=%ld can read search-only ancestor; DAC regression untested\n", (long)geteuid());
        return 75;
    }
    printf("search-only ancestor: uid=%ld read denied EACCES, child accessible\n", (long)geteuid());
    int before = entries("/proc/self/fd");
    CHECK(before >= 0);
    CHECK(equals(p, "source", 6));
    CHECK(s2a_savecommit_clone_tree(src, dst) == 0);
    path(q, dst, "value"); CHECK(equals(q, "source", 6));
    CHECK(s2a_savecommit_clone_tree(src, dst) == EEXIST);
    CHECK(s2a_savecommit_clone_tree(src, child) == EEXIST);
    CHECK(s2a_savecommit_clone_tree(src, nested) == EINVAL);
    CHECK(absent(nested));
    CHECK(s2a_savecommit_clone_tree(link, nested) != 0);
    for (int i = 0; i < 8; ++i) {
        CHECK(s2a_savecommit_exchange(src, alias) == EINVAL);
        CHECK(s2a_savecommit_exchange(src, child) == EINVAL);
        CHECK(s2a_savecommit_exchange(child, src) == EINVAL);
        CHECK(s2a_savecommit_exchange(src, link) != 0);
    }
    CHECK(s2a_savecommit_exchange(src, other) == 0);
    CHECK(equals(p, "other", 5));
    path(q, other, "value"); CHECK(equals(q, "source", 6));
    CHECK(entries("/proc/self/fd") == before);
    CHECK(chmod(gate, 0700) == 0);
    return 0;
}
/* root 跑（只有 root 的 Linux 容器 / WSL 门禁机）：DAC 用例在 root 下验不了（root 无视读权限）。夹具改建在 /tmp（构建目录
 * 可能在 0700 的 /root 下，降权后进不去），交给 nobody 后整进程永久降权，再照常跑全部用例——与普通用户宿主同一套断言。
 * setuid 后进程变成不可转储，/proc/self/fd 归 root、nobody 读不了，所以重新置可转储。 */
static int drop_root(const char *root)
{
    const uid_t nobody = 65534;
    if (chown(root, nobody, nobody) != 0 || setgroups(0, NULL) != 0 || setgid(nobody) != 0 || setuid(nobody) != 0) return -1;
    if (prctl(PR_SET_DUMPABLE, 1, 0, 0, 0) != 0 || geteuid() == 0) return -1;
    printf("root host: fixture moved to %s, dropped to uid=%ld for DAC checks\n", root, (long)geteuid());
    return 0;
}
int main(int argc,char**argv) {char root[4096];if(argc<2){fprintf(stderr,"usage: test ABSOLUTE_FIXTURE_PARENT [fake-exchange]\n");return 2;}const int as_root=geteuid()==0;if(snprintf(root,sizeof root,"%s/native-fixture-XXXXXX",as_root?"/tmp":argv[1])>=(int)sizeof root)return 2;if(!mkdtemp(root)){perror("mkdtemp");return 2;}if(as_root&&drop_root(root)){fprintf(stderr,"ENV_NOT_READY: root host could not drop to nobody (errno=%d); DAC regression untested\n",errno);cleanup(root);return 75;}fake_exchange=argc>2&&!strcmp(argv[2],"fake-exchange");int search_rc=test_search_only_ancestor(root);if(search_rc){cleanup(root);return search_rc;}test_clone(root);test_copy_errors(root);test_exchange(root);test_token_sync(root);test_token_fallback(root);test_token_stale_file(root);test_token_stale_nonregular(root);test_token_stale_failure(root);test_metadata(root);test_readonly_rollback(root);test_supported_concurrent(root);CHECK(observed_reflink_calls==0);CHECK(forced_clones==0);CHECK(probe_count==86);CHECK(probe_bad==0);cleanup(root);printf("real FICLONE calls=%d last errno=%d (host observation only)\n",observed_reflink_calls,observed_reflink_errno);printf("native host: %d checks, %d failures; negative-control=%d\n",checks,failures,fake_exchange);return failures?1:0;}
