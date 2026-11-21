#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Pinned OHOS codec inputs and builds. --prepare-only never invokes a compiler.

Only public sources are downloaded. Versions/hashes come from the shared service
build scripts; downloaded code, object files and archives stay outside the repo.
"""
from pathlib import Path
import sys,argparse,ctypes,hashlib,json,os,re,shlex,shutil,subprocess,tarfile,time,urllib.request
EXE='.exe' if sys.platform=='win32' else ''

ROOT=Path(__file__).resolve().parents[2]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def ensure_patch(source, patch_file):
    # Check the complete patch, not one header: partial/stale applications fail.
    def apply(*args):
        return subprocess.run(['git', 'apply', *args, str(patch_file)], cwd=source,
                              capture_output=True, text=True)
    if apply('--reverse', '--check').returncode == 0:
        return
    check = apply('--check')
    if check.returncode:
        raise RuntimeError('Codec patch does not match source: ' + check.stderr)
    result = apply('--whitespace=nowarn')
    if result.returncode:
        raise RuntimeError('Codec patch failed: ' + result.stderr)
def source_pin(name):
    source=ROOT/'services'/name/'build.sh'
    match=re.search(r'^VER=([0-9.]+); SHA=([a-f0-9]{64})$',source.read_text(encoding="utf-8"),re.M)
    if not match:raise RuntimeError('No shared pin in '+str(source))
    ver,digest=match.groups()
    archive=('opus-' if name=='opus' else 'libvpx-')+ver+'.tar.gz'
    url=('https://downloads.xiph.org/releases/opus/opus-'+ver+'.tar.gz' if name=='opus'
         else 'https://github.com/webmproject/libvpx/archive/refs/tags/v'+ver+'.tar.gz')
    return {'name':name,'version':ver,'sha256':digest,'url':url,'archive':archive,'pin_file':str(source)}

def prepare(pin,deps):
    archive=deps/pin['archive'];source=deps/(pin['name']+'-'+pin['version'])
    receipt=source/'s2arm-source-receipt.json'
    if archive.exists():
        if sha(archive)!=pin['sha256']:raise RuntimeError('Existing archive hash differs: '+str(archive))
    else:
        partial=deps/(pin['archive']+'.download-'+str(time.time_ns()))
        with urllib.request.urlopen(pin['url'],timeout=60) as response,partial.open('xb') as output:
            while chunk:=response.read(1024*1024):output.write(chunk)
        if sha(partial)!=pin['sha256']:raise RuntimeError('Downloaded archive hash differs; retained '+str(partial))
        partial.rename(archive)
    if receipt.exists():
        old=json.loads(receipt.read_text())
        if old['sha256']!=pin['sha256']:raise RuntimeError('Source provenance mismatch '+str(source))
        for rel,digest in old['files'].items():
            if sha(source/rel)!=digest:raise RuntimeError('Source modified: '+str(source/rel))
    elif source.exists():raise RuntimeError('Unverified existing source directory: '+str(source))
    else:
        staging=deps/(pin['name']+'-'+pin['version']+'.extract-'+str(time.time_ns()))
        staging.mkdir()
        with tarfile.open(archive,'r:gz') as tar:
            members=tar.getmembers()
            tops={Path(m.name).parts[0] for m in members if m.name}
            if len(tops)!=1:raise RuntimeError('Unexpected archive roots')
            tar.extractall(staging,filter='data')
        extracted=staging/next(iter(tops))
        extracted.rename(source)
        staging.rmdir()  # only our now-empty staging directory
        files={str(p.relative_to(source)).replace('\\','/'):sha(p) for p in source.rglob('*') if p.is_file()}
        receipt.write_text(json.dumps(dict(pin,files=files),indent=2),encoding='utf-8')
    return dict(pin,path=str(source),archive_path=str(archive))

def main():
    parser=argparse.ArgumentParser()
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--prepare-only',action='store_true')
    mode.add_argument('--build',action='store_true')
    parser.add_argument('--codec',choices=['all','opus','vpx'],default='all')
    parser.add_argument('--deps',type=Path,default=ROOT.parent/'deps'/'codecs-20261024')
    parser.add_argument('--out',type=Path,default=ROOT.parent/'build-ohos-codecs-20261024')
    parser.add_argument('--native-sdk',type=Path,required=True)
    parser.add_argument('--bash',type=Path,required=True)
    parser.add_argument('--make',type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=2)
    args=parser.parse_args()
    if args.jobs<1 or args.jobs>8:parser.error('--jobs must be in 1..8')
    args.deps=args.deps.resolve();args.out=args.out.resolve()
    if args.deps==ROOT or ROOT in args.deps.parents or args.out==ROOT or ROOT in args.out.parents:
        parser.error('Source and build directories must be outside the Git worktree')
    args.deps.mkdir(parents=True,exist_ok=True)
    sources=[prepare(source_pin(name),args.deps) for name in (['opus','vpx'] if args.codec=='all' else [args.codec])]
    manifest={'mode':'prepare-only','sources':sources,'script_sha256':sha(Path(__file__))}
    (args.deps/'prepared.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    if args.build:build_all(args,sources)
    print(json.dumps(manifest,indent=2))

def short_path(path):
    # GNU configure stores command strings, so use the existing Windows short
    # path only for tools/SDK. Source/build dirs are deliberately ASCII paths.
    if os.name!='nt':return str(path)
    buf=ctypes.create_unicode_buffer(32768)
    if not ctypes.windll.kernel32.GetShortPathNameW(str(path),buf,len(buf)):
        raise OSError('Cannot resolve installed tool path '+str(path))
    return buf.value.replace('\\','/')

def build_all(args,sources):
    llvm=args.native_sdk/'llvm/bin'
    cmake=args.native_sdk/('build-tools/cmake/bin/cmake'+EXE)
    ninja=args.native_sdk/('build-tools/cmake/bin/ninja'+EXE)
    toolchain=args.native_sdk/'build/cmake/ohos.toolchain.cmake'
    sdk_meta=args.native_sdk/'oh-uni-package.json'
    tool_names=['clang'+EXE,'llvm-ar'+EXE,'llvm-ranlib'+EXE,'llvm-nm'+EXE,'llvm-strip'+EXE]
    for tool in [cmake,ninja,toolchain,sdk_meta,*[llvm/n for n in tool_names]]:
        if not tool.exists():raise RuntimeError('Missing installed tool '+str(tool))
    args.out.mkdir(parents=True,exist_ok=True)
    identity={'script_sha256':sha(Path(__file__)),'sdk':json.loads(sdk_meta.read_text()),
              'clang_sha256':sha(llvm/('clang'+EXE)),'target':'aarch64-linux-ohos'}
    report={'identity':identity,'sources':sources,'libraries':[],'commands':[]}
    def run(argv,cwd,log,env=None):
        print('Running '+log.name,flush=True)
        with log.open('wb') as output:
            result=subprocess.run([str(x) for x in argv],cwd=cwd,env=env,stdout=output,stderr=subprocess.STDOUT)
        report['commands'].append({'argv':[str(x) for x in argv],'cwd':str(cwd),'exit_code':result.returncode,'log':str(log)})
        (args.out/'build-report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
        if result.returncode:
            raise RuntimeError(log.read_text(encoding='utf-8',errors='replace')[-6000:])
    try:
        for pin in sources:
            name=pin['name'];source=Path(pin['path'])
            shim=ROOT/'services'/name/('s2a_opus.c' if name=='opus' else 's2a_vp8.c')
            key_data=dict(identity,source_sha256=pin['sha256'],shim_sha256=sha(shim),patch_sha256=(sha(ROOT/'services/vpx/patches/0001-s2a-vp9-nvdec-hook.patch') if name=='vpx' else ''))
            key=hashlib.sha256(json.dumps(key_data,sort_keys=True).encode()).hexdigest()[:12]
            work=args.out/(name+'-'+pin['version']+'-'+key);work.mkdir(exist_ok=True)
            obj=work/'obj';obj.mkdir(exist_ok=True)
            if name=='opus':
                # Same floating-point/reference implementation as shared builds.
                # AArch64 guarantees baseline NEON; no per-device CPU assumptions.
                flags=['-DOPUS_BUILD_SHARED_LIBRARY=OFF','-DBUILD_SHARED_LIBS=OFF',
                       '-DOPUS_BUILD_TESTING=OFF','-DOPUS_BUILD_PROGRAMS=OFF','-DOPUS_FIXED_POINT=OFF',
                       '-DOPUS_ENABLE_FLOAT_API=ON','-DOPUS_DISABLE_INTRINSICS=OFF',
                       '-DOPUS_MAY_HAVE_NEON=OFF','-DOPUS_PRESUME_NEON=ON',
                       '-DOPUS_DRED=OFF','-DOPUS_OSCE=OFF','-DOPUS_DEEP_PLC=OFF',
                       '-DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF','-DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF']
                run([cmake,'-S',source,'-B',obj,'-G','Ninja','-DCMAKE_TOOLCHAIN_FILE='+str(toolchain),
                     '-DCMAKE_MAKE_PROGRAM='+str(ninja),'-DOHOS_ARCH=arm64-v8a',
                     '-DCMAKE_BUILD_TYPE=Release','-DCMAKE_C_FLAGS_RELEASE=-O2 -DNDEBUG -fPIC',
                     '-DCMAKE_POSITION_INDEPENDENT_CODE=ON','-DCMAKE_EXPORT_COMPILE_COMMANDS=ON',*flags],work,work/'configure.log')
                run([cmake,'--build',obj,'--parallel',str(args.jobs),'--target','opus'],work,work/'build.log')
                original=obj/'libopus.a';includes=source/'include';licenses=['COPYING']
            else:
                if not args.bash.exists() or not args.make.exists():raise RuntimeError('Git bash and GNU make required for official libvpx build')
                # Same S2Arm libvpx patch as services/vpx/build.sh: s2a_vp9.c needs vpx/s2a_vp9_nvdec.h from it.
                patch_file=ROOT/'services/vpx/patches/0001-s2a-vp9-nvdec-hook.patch'
                # prepare() verifies pristine source receipts on every invocation.
                # Patch a build-owned copy so a second invocation still verifies.
                patched = work/'source'
                if not patched.exists():shutil.copytree(source,patched)
                source = patched
                ensure_patch(source,patch_file)
                for path in [source,obj]:
                    if any(c.isspace() for c in str(path)):raise RuntimeError('libvpx configure/make requires source/build paths without spaces')
                sdk=short_path(args.native_sdk);tool=short_path(llvm)
                cc=tool+'/clang'+EXE+' --target=aarch64-linux-ohos --sysroot='+sdk+'/sysroot'
                env=os.environ.copy()
                env.update(CC=cc,CXX=tool+'/clang++'+EXE+' --target=aarch64-linux-ohos --sysroot='+sdk+'/sysroot',
                           AS=cc,LD=cc,AR=tool+'/llvm-ar'+EXE,NM=tool+'/llvm-nm'+EXE,STRIP=tool+'/llvm-strip'+EXE,
                           RANLIB=tool+'/llvm-ranlib'+EXE,CFLAGS='-O2 -fPIC',CXXFLAGS='-O2 -fPIC')
                env['PATH']=str(args.bash.parent.parent/'usr/bin')+os.pathsep+str(llvm)+os.pathsep+env.get('PATH','')
                flags=['--target=arm64-linux-gcc','--disable-vp9-encoder','--enable-vp9-decoder','--disable-vp8-encoder','--enable-vp8-decoder',
                       '--disable-examples','--disable-tools','--disable-docs','--disable-unit-tests',
                       '--disable-webm-io','--disable-libyuv','--enable-pic','--enable-static','--disable-shared','--size-limit=8192x8192']
                # $0 remains C:/.../configure, which GNU make on Windows can stat.
                run([args.bash,source.as_posix()+'/configure',*flags],obj,work/'configure.log',env)
                run([args.make,'-j'+str(args.jobs),'SHELL='+short_path(args.bash),'libvpx.a'],obj,work/'build.log',env)
                original=obj/'libvpx.a';includes=source;licenses=['LICENSE','PATENTS']
            if not original.is_file():raise RuntimeError('Official build produced no archive: '+str(original))
            shim_object=work/(shim.stem+'.o')
            run([llvm/('clang'+EXE),'--target=aarch64-linux-ohos','--sysroot='+str(args.native_sdk/'sysroot'),
                 '-O2','-fPIC','-I'+str(includes),'-c',shim,'-o',shim_object],work,work/'shim.log')
            combined=work/('libs2a_'+name+'.a')
            # Always create a fresh temporary archive; q must never append a
            # second set of members after an interrupted build.
            temp=work/('archive-'+str(time.time_ns())+'.a')
            extra_objects=[]
            if name=='vpx':
                # Switch 2 video decoders need VP9 as well (graphics/nvn/gfx/nvn/nvn2_codec.c).
                vp9_object=work/'s2a_vp9.o'
                run([llvm/('clang'+EXE),'--target=aarch64-linux-ohos','--sysroot='+str(args.native_sdk/'sysroot'),
                     '-O2','-fPIC','-I'+str(includes),'-c',ROOT/'services'/'vpx'/'s2a_vp9.c','-o',vp9_object],work,work/'shim-vp9.log')
                extra_objects.append(vp9_object)
            run([llvm/('llvm-ar'+EXE),'qcL',temp,original,shim_object,*extra_objects],work,work/'archive.log')
            run([llvm/('llvm-ranlib'+EXE),temp],work,work/'ranlib.log')
            temp.replace(combined)  # generated output in this script-owned directory
            linked=work/('libs2a_'+name+'-link-check.so')
            run([llvm/('clang'+EXE),'--target=aarch64-linux-ohos','--sysroot='+str(args.native_sdk/'sysroot'),
                 '-shared','-Wl,--no-undefined','-Wl,--whole-archive',combined,'-Wl,--no-whole-archive','-lm','-o',linked],work,work/'link.log')
            license_dir=work/'licenses';license_dir.mkdir(exist_ok=True)
            license_records=[]
            for name_in_source in licenses:
                dest=license_dir/(name+'-'+name_in_source+'.txt');shutil.copyfile(source/name_in_source,dest)
                license_records.append({'path':str(dest),'sha256':sha(dest)})
            record={'name':name,'archive':str(combined),'bytes':combined.stat().st_size,'sha256':sha(combined),
                    'upstream_archive_sha256':sha(original),'shim_sha256':sha(shim),'link_check_sha256':sha(linked),
                    'licenses':license_records,'build_inputs':key_data}
            report['libraries'].append(record)
            (work/'manifest.json').write_text(json.dumps(record,indent=2),encoding='utf-8')
    finally:
        (args.out/'build-report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps({'libraries':report['libraries'],'report':str(args.out/'build-report.json')},indent=2))


if __name__=='__main__':main()
