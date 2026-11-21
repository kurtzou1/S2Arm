# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁手动：只能 Windows 宿主（ctypes 调 msvcrt 跑编出的解析函数）且要传 --cc；单跑：python3 ohos/tests/test_module_enhancement_headers.py --repo . --cc <clang.exe> --out <新目录>
"""Exercise the actual OHOS layout-parser body on a Windows host.

Only unrelated mapping code is excluded. Scalar/string CRT calls use the host's
real msvcrt functions through pointers, so no third-party compiler runtime or
device is required. This verifies parsing, not OHOS mapping or game execution.
"""
from pathlib import Path
import argparse,ctypes as C,hashlib,json,subprocess

def function(source,signature):
    start=source.index(signature);begin=source.index('{',start);depth=1;at=begin+1
    while depth:
        if source[at]=='{':depth+=1
        elif source[at]=='}':depth-=1
        at+=1
    return source[start:at]

def main():
    p=argparse.ArgumentParser();p.add_argument('--repo',type=Path,required=True);p.add_argument('--cc',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--actual',type=Path);p.add_argument('--before',type=Path);p.add_argument('--before-outer',type=Path);a=p.parse_args();a.out.mkdir(parents=True,exist_ok=False)
    crt=C.CDLL('msvcrt.dll');keep=[];records=[]
    declarations=[
        ('memset','void *','void *, int, size_t','memset'),('memcpy','void *','void *, const void *, size_t','memcpy'),
        ('memcmp','int','const void *, const void *, size_t','memcmp'),('memchr','void *','const void *, int, size_t','memchr'),
        ('strchr','char *','const char *, int','strchr'),('strcmp','int','const char *, const char *','strcmp'),
        ('strncmp','int','const char *, const char *, size_t','strncmp'),('strstr','char *','const char *, const char *','strstr'),
        ('strlen','size_t','const char *','strlen'),('strrchr','char *','const char *, int','strrchr'),
        ('strcspn','size_t','const char *, const char *','strcspn'),('sscanf','int','const char *, const char *, ...','sscanf'),
        ('strtoull','unsigned long long','const char *, char **, int','_strtoui64'),('strtoll','long long','const char *, char **, int','_strtoi64'),
        ('strtoul','unsigned long','const char *, char **, int','strtoul'),('snprintf','int','char *, size_t, const char *, ...','_snprintf'),
        ('vsnprintf','int','char *, size_t, const char *, va_list','_vsnprintf'),('get_errno','int *','void','_errno')]
    class Layout(C.Structure):
        _fields_=[('patch_off',C.c_int64)]+[(k,C.c_uint64) for k in ['image_size','file_image_len','key_page_off','key_page_size','text_end']]+[('key_idx',C.c_uint*4)]
    def compile(path,name,outer=False):
        original=path.read_text(encoding='utf-8')
        fail='' if outer else function(original,'static int fail(')
        body=function(original,'static void read_layout_text(' if outer else 'int s2a_module_layout_mem(')
        text='#include <stddef.h>\n#include <stdint.h>\n#include <stdarg.h>\n#include <limits.h>\n#include "'+(a.repo/'android/native/module.h').as_posix()+'"\n'
        text+='#define __OHOS__ 1\n#define S2A_MODULE_TARGET "ohos"\n#define S2A_MODULE_ABI "ohos-sp-safe-v1"\n#define S2A_OHOS_TSDOFF_IDX 4\n#define PAGE16 0x4000ull\n#define EINVAL 22\n#define ENOEXEC 8\n'
        for name_,ret,args,_ in declarations:text+=f'static {ret} (*crt_{name_})({args});\n#define {name_} crt_{name_}\n'
        text+='#define errno (*crt_get_errno())\nstatic const char *const key_name[S2A_KEY_N]={"K18","KTLS","KTLR","KGATE"};\n'
        text+='__declspec(dllexport) void configure(void **functions) {\n'
        for i,(name_,ret,args,_) in enumerate(declarations):text+=f'crt_{name_}=({ret} (*)({args}))functions[{i}];\n'
        text+='}\n'
        if outer:
            text+='''
enum { KEY_N=4 };
static const char *const k_keyname[KEY_N]={"K18","KTLS","KTLR","KGATE"};
static char g_main_build_id[64];static int test_error;
#define die(...) do { test_error=__LINE__;return; } while(0)
typedef struct {char name[16];int64_t patch_off;uint64_t image_size,file_image_len,key_page_off,key_page_size,text_end,ro_off,data_off;unsigned key_idx[4];} module_t;
struct loader_text {const unsigned char *bytes;size_t length,cursor;const char *what;};
// Supply bounded in-memory lines; file I/O is outside this parser exercise.
static int text_line(struct loader_text*t,char*line,size_t cap){if(t->cursor==t->length)return 0;size_t start=t->cursor,end=start;while(end<t->length&&t->bytes[end]!='\\n')++end;size_t n=end-start;if(n>=cap)return 0;memcpy(line,t->bytes+start,n);line[n]=0;t->cursor=end<t->length?end+1:end;return 1;}
static size_t strlcpy(char*d,const char*s,size_t cap){size_t n=strlen(s);size_t take=n<cap-1?n:cap-1;if(cap){memcpy(d,s,take);d[take]=0;}return n;}
'''+body+'''
__declspec(dllexport) int test_layout(const char*t,size_t n,struct s2a_module_layout*l,char*err,size_t cap){
 module_t m={0};memcpy(m.name,"main",5);struct loader_text input={(const unsigned char*)t,n,0,"CPU"};test_error=0;read_layout_text(&m,&input);
 if(test_error){snprintf(err,cap,"outer loader rejected at line %d",test_error);return EINVAL;}
 l->patch_off=m.patch_off;l->image_size=m.image_size;l->file_image_len=m.file_image_len;l->key_page_off=m.key_page_off;l->key_page_size=m.key_page_size;l->text_end=m.text_end;memcpy(l->key_idx,m.key_idx,sizeof m.key_idx);return 0;
}
'''
        else:text+=fail+'\n'+body+'\n__declspec(dllexport) int test_layout(const char*t,size_t n,struct s2a_module_layout*l,char*err,size_t cap){return s2a_module_layout_mem(t,n,"CPU",l,err,cap);}\n'
        c=a.out/(name+'.c');dll=a.out/(name+'.dll');c.write_text(text,encoding='utf-8')
        cmd=[str(a.cc),'--target=x86_64-pc-windows-msvc','-nostdlib','-shared','-fuse-ld=lld','-Wl,/noentry','-fno-stack-protector','-fno-builtin','-O1',str(c),'-o',str(dll)]
        r=subprocess.run(cmd,capture_output=True);records.append({'command':cmd,'exitCode':r.returncode,'stdout':r.stdout.decode(errors='replace'),'stderr':r.stderr.decode(errors='replace'),'sourceSha256':hashlib.sha256(path.read_bytes()).hexdigest()})
        (a.out/'commands.json').write_text(json.dumps(records,indent=2),encoding='utf-8');assert r.returncode==0,records[-1]
        lib=C.CDLL(str(dll));pointers=(C.c_void_p*len(declarations))(*[C.c_void_p.from_address(C.addressof(getattr(crt,actual))).value for _,_,_,actual in declarations]);lib.configure.argtypes=[C.POINTER(C.c_void_p)];lib.configure(pointers);keep.append(lib)
        f=lib.test_layout;f.argtypes=[C.c_char_p,C.c_size_t,C.POINTER(Layout),C.c_char_p,C.c_size_t];f.restype=C.c_int
        def run(data):
            error=C.create_string_buffer(512);layout=Layout();rc=f(data,len(data),C.byref(layout),error,len(error));return rc,error.value.decode(errors='replace'),layout
        return run
    current=compile(a.repo/'android/native/module.c','current')
    baseline=b'# BUILD_ID\t0123456789abcdef0123456789abcdef\n# TARGET\tohos\n# REWRITE_ABI\tohos-sp-safe-v1\n# PATCH_OFF\t0xc000\n# KEY_PAGE_OFF\t0x8000\n# KEY_PAGE_SIZE\t0x4000\n# TEXT_END\t0x1000\n# RO_OFF\t0x4000\n# DATA_OFF\t0x4000\n# KEY_K18_IDX\t0\n# KEY_KTLS_IDX\t1\n# KEY_KTLR_IDX\t2\n# KEY_KGATE_IDX\t3\n# KEY_TSDOFF_IDX\t4\n'
    fps=b'# FPS_ABI\ts2a.ohos.fps.v1\n# FPS_SHA256\t'+b'5'*64+b'\n';wide=b'# CODE_PATCH_SHA256\t'+b'a'*64+b'\n'
    checks=[]
    def check(data,valid,label):
        rc,error,layout=current(data);assert (rc==0)==valid,(label,rc,error)
        checks.append({'label':label,'exit':rc,'expectedSuccess':valid,'diagnostic':error});print('PASS',label)
    check(baseline,True,'original layout unchanged');check(baseline+fps,True,'FPS binding accepted');check(baseline+wide,True,'code binding accepted');check(baseline+fps+wide,True,'combined enhancement binding accepted')
    check(baseline+fps+fps,False,'duplicate FPS ABI rejected');check(baseline+wide+wide,False,'duplicate code digest rejected')
    check(baseline+fps.replace(b'v1',b'v2'),False,'unknown FPS ABI rejected')
    check(baseline+b'# FPS_ABI\ts2a.ohos.fps.v1\n',False,'missing FPS digest rejected');check(baseline+b'# FPS_SHA256\t'+b'5'*64+b'\n',False,'missing FPS ABI rejected')
    check(baseline+wide.replace(b'a'*64,b'a'*63),False,'short digest rejected');check(baseline+wide.replace(b'a'*64,b'g'*64),False,'non-hex digest rejected')
    check(baseline+b'# UNKNOWN\tnot-numeric\n',False,'unknown string header still rejected');check(baseline.replace(b'0xc000',b'0x4000'),False,'overlapping patch still rejected')
    if a.actual:
        for name in ('main','subsdk0','sdk'):check((a.actual/(name+'.fixups.tsv')).read_bytes(),True,'actual candidate '+name+' headers')
    if a.before:
        old=compile(a.before,'before');rc,error,_=old((a.actual/'main.fixups.tsv').read_bytes() if a.actual else baseline+fps+wide)
        assert rc!=0 and 'FPS_ABI' in error,(rc,error);checks.append({'label':'old parser reproduces rejection','exit':rc,'expectedSuccess':False,'diagnostic':error});print('PASS old parser reproduces rejection')
    outer=compile(a.repo/'runtime/src/loader.c','outer',True)
    for label,data in [('original outer layout',baseline),('enhanced outer layout',baseline+fps+wide)]+([(name+' actual outer layout',(a.actual/(name+'.fixups.tsv')).read_bytes()) for name in ('main','subsdk0','sdk')] if a.actual else []):
        rc,error,layout=outer(data);assert rc==0,(label,rc,error);_,_,strict=current(data)
        assert (layout.patch_off,layout.key_page_off,list(layout.key_idx))==(strict.patch_off,strict.key_page_off,list(strict.key_idx))
        checks.append({'label':label,'exit':rc,'expectedSuccess':True,'diagnostic':error});print('PASS',label)
    if a.before_outer:
        old=compile(a.before_outer,'outer-before',True);rc,error,_=old(baseline+fps+wide);assert rc!=0,(rc,error)
        checks.append({'label':'old outer parser reproduces rejection','exit':rc,'expectedSuccess':False,'diagnostic':error});print('PASS old outer parser reproduces rejection')
    (a.out/'result.json').write_text(json.dumps({'checks':checks,'count':len(checks),'actualParserSourceSha256':hashlib.sha256((a.repo/'android/native/module.c').read_bytes()).hexdigest(),'deviceOrMappingExecuted':False},indent=2),encoding='utf-8')
    print(len(checks),'checks PASS; parser only, no device/game execution')
if __name__=='__main__':main()
