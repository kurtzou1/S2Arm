# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
from pathlib import Path
import subprocess, json, hashlib, sys

import argparse
parser=argparse.ArgumentParser(description="Link the real OHOS native core and NativeAOT services; never insert ABI stubs")
parser.add_argument('--ndk',type=Path,required=True)
parser.add_argument('--aot-object',type=Path,required=True,help='NativeAOT S2A.Ohos.o')
parser.add_argument('--hms-include',type=Path,help='HMS native include root for performance hints')
parser.add_argument('--out',type=Path,required=True)
parser.add_argument('--native',type=Path,required=True)
parser.add_argument('--audio',type=Path,required=True)
parser.add_argument('--opus',type=Path,required=True)
parser.add_argument('--vpx',type=Path,required=True)
parser.add_argument('--dav1d',type=Path)
parser.add_argument('--aot-link-inputs',type=Path,required=True)
parser.add_argument('--direct',type=Path,help='libs2arm_ohos_direct.a: shared NVN frontend + Vulkan direct backend; routing still follows the per-session graphics selection')
args=parser.parse_args()
repo=Path(__file__).resolve().parents[1]
ndk=args.ndk.resolve();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
exe='.exe' if sys.platform=='win32' else ''
cc=str(ndk/('llvm/bin/clang'+exe))
native=repo/'ohos/native'
base=[cc,'--target=aarch64-linux-ohos','--sysroot='+str(ndk/'sysroot'),'-O2','-g','-fPIC','-ffunction-sections','-fdata-sections','-D_GNU_SOURCE','-fno-emulated-tls']
includes=[repo/'runtime/include',repo/'android/native',native]
base += ['-I'+str(x) for x in includes]
if args.hms_include: base += ['-I'+str(args.hms_include.resolve())]
commands=[]
def run(name,args):
    p=subprocess.run(args,capture_output=True)
    (out/(name+'.stdout.txt')).write_bytes(p.stdout);(out/(name+'.stderr.txt')).write_bytes(p.stderr)
    commands.append({'name':name,'argv':args,'exitCode':p.returncode})
    (out/'commands.json').write_text(json.dumps(commands,indent=2),encoding='utf-8')
    print(name,p.returncode,flush=True)
    if p.returncode: print(p.stderr.decode('utf-8',errors='replace')[-14000:]);sys.exit(p.returncode)

# Provide the OHOS NUMA capability boundary before NativeAOT archives: the
# generic GC selects its supported non-NUMA path. No denied syscall is retried.
sources=[repo/'ohos/host/host_ohos.c',repo/'ohos/host/ohos_feedback.c',repo/'ohos/host/performance_ohos.cpp',native/'nativeaot_numa_ohos.cpp']+[repo/'android/native'/n for n in ['hostapi.c','host_android.c','host_ui.c','input.c','wsi_lease.c']]
objects=[]
for p in sources:
    obj=out/(p.stem+'.o');run('compile-'+p.stem,base+['-c',str(p),'-o',str(obj)]);objects.append(str(obj))
aot_object=args.aot_object.resolve()
if not aot_object.is_file(): raise SystemExit('Missing NativeAOT object: '+str(aot_object))
runtime=[x.strip() for x in args.aot_link_inputs.read_text(encoding='utf-8-sig').splitlines() if x.strip()]
exports=out/'exports.map';exports.write_text('V1.0 { global: s2a_*; S2A_*; DotNetRuntimeDebugHeader; local: *; };\n')
sections=out/'sections.ld';sections.write_text('OVERWRITE_SECTIONS { __modules : { KEEP(*(__modules)) } swnvn : { KEEP(*(swnvn)) } }\n')
archives=[str(p.resolve()) for p in (args.native,args.audio,args.opus,args.vpx)]
if args.dav1d: archives.append(str(args.dav1d.resolve()))
if args.direct: archives.append(str(args.direct.resolve()))
for p in archives:
    if not Path(p).is_file(): raise SystemExit('Missing real native input: '+p)
args=base+['-fuse-ld=lld','-shared','-o',str(out/'libS2AEngine.so'),str(aot_object)]+objects+[
    '-Wl,--whole-archive']+archives+['-Wl,--no-whole-archive','-Wl,--start-group']+runtime+[
    '-Wl,--end-group','-Wl,--version-script='+str(exports),'-pthread','-lhilog_ndk.z','-lqos','-lvulkan','-lnative_window','-lohaudio','-lnative_media_vdec','-lnative_media_codecbase','-lnative_media_core',
    '-Wl,--wrap=vkDestroyImageView','-Wl,--wrap=vkDestroySampler','-Wl,--wrap=vkDestroyBuffer','-Wl,--wrap=vkDestroyDescriptorSetLayout','-Wl,-z,relro','-Wl,-z,now','-Wl,--eh-frame-hdr','-Wl,--gc-sections','-Wl,-T,'+str(sections),'-Wl,--no-undefined','-Wl,--error-limit=0']
run('link-engine',args)
run('strip-engine',[str(ndk/('llvm/bin/llvm-strip'+exe)),'-o',str(out/'libS2AEngine.stripped.so'),str(out/'libS2AEngine.so')])
manifest={'artifacts':[{'path':str(p),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in [out/'libS2AEngine.so',out/'libS2AEngine.stripped.so']]}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8');print(json.dumps(manifest))
