# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Build local, HAP-signable OHOS module carriers from generic rewriter output.

Generated libraries contain game-derived code: keep them outside the repository.
Near carriers retain descriptor v1. FAR carriers use descriptor v2, with the
same fields, a signed patch offset and mapped_size covering the leading gap.
Executable bytes and relative addresses are preserved exactly, with no RWX LOAD.
"""
from pathlib import Path
import argparse,hashlib,json,re,struct,subprocess,sys

PAGE=0x4000
MAGIC=0x5332415349473031
def up(n):return (n+PAGE-1)&-PAGE
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read_layout(fixups,raw):
    fields={}
    for line in fixups.decode('utf-8').splitlines():
        match=re.fullmatch(r'# ([A-Z0-9_]+)\t([^\t]+)',line)
        if not match or match[1] in fields:raise ValueError('Malformed or duplicate fixups header')
        fields[match[1]]=match[2]
    if fields.get('TARGET')!='ohos' or fields.get('REWRITE_ABI')!='ohos-sp-safe-v1':raise ValueError('Wrong target or rewrite ABI')
    build=fields.get('BUILD_ID','')
    if not re.fullmatch('[a-f0-9]{32}',build):raise ValueError('Invalid build identity')
    required=['TEXT_END','PATCH_OFF','KEY_PAGE_OFF','KEY_PAGE_SIZE','RO_OFF','DATA_OFF']
    n={k:int(fields[k],16) for k in required}
    if not -(1<<63)<n['PATCH_OFF']<(1<<63) or not n['PATCH_OFF']:raise ValueError('Invalid patch offset')
    if any(not 0<=v<(1<<64) for k,v in n.items() if k!='PATCH_OFF'):raise ValueError('Invalid unsigned layout value')
    if n['PATCH_OFF']%PAGE or n['KEY_PAGE_OFF']%PAGE or n['KEY_PAGE_SIZE']!=PAGE:raise ValueError('Unaligned carrier layout')
    if not (0<n['TEXT_END']<=n['RO_OFF']<=n['DATA_OFF']<=n['KEY_PAGE_OFF']):raise ValueError('Invalid segment boundaries')
    if up(n['TEXT_END'])>n['KEY_PAGE_OFF']:raise ValueError('Text overlaps key page')
    if n['PATCH_OFF']<0:
        if not all(k in fields for k in ('IMAGE_SIZE','FILE_IMAGE_LEN')):raise ValueError('FAR image sizes are missing')
        n.update({k:int(fields[k],16) for k in ('IMAGE_SIZE','FILE_IMAGE_LEN')})
        size,fl,pre=n['IMAGE_SIZE'],n['FILE_IMAGE_LEN'],-n['PATCH_OFF']
        if not (0<fl<=n['KEY_PAGE_OFF'] and up(n['TEXT_END'])<=fl and n['DATA_OFF']<=fl and
                fl%PAGE==0 and size==n['KEY_PAGE_OFF']+PAGE and pre+size<(1<<64) and
                fl<len(raw) and up(len(raw)-fl)<=pre):raise ValueError('Invalid FAR file, BSS or patch boundaries')
    elif up(n['TEXT_END'])>n['KEY_PAGE_OFF'] or n['KEY_PAGE_OFF']+PAGE>n['PATCH_OFF'] or n['PATCH_OFF']>=len(raw):
        raise ValueError('Overlapping or absent segments')
    keys=[int(fields['KEY_'+k+'_IDX']) for k in ('K18','KTLS','KTLR','KGATE','TSDOFF')]
    if keys[-1]!=4 or len(set(keys))!=5 or any(k<0 or k>=PAGE//8 for k in keys):raise ValueError('Invalid key indices')
    if n['PATCH_OFF']>0 and any(raw[n['KEY_PAGE_OFF']:n['KEY_PAGE_OFF']+PAGE]):raise ValueError('Key page must be zero before binding')
    return build,n

def build_one(module,inputs,out,ndk):
    if not re.fullmatch('[A-Za-z0-9_]{1,15}',module):raise ValueError('Invalid module name')
    raw_path=inputs/(module+'.patched.bin');raw=raw_path.read_bytes()
    fix_path=inputs/(module+'.fixups.tsv');fix=fix_path.read_bytes()
    gate_path=inputs/(module+'.gates.tsv');gates=gate_path.read_bytes()
    build_id,layout=read_layout(fix,raw)
    # Reject invalid layouts before creating a candidate directory.
    dest=out/module;dest.mkdir(parents=True,exist_ok=False)
    x0=up(layout['TEXT_END']);po=layout['PATCH_OFF'];far=po<0
    pre=-po if far else 0
    image_size=layout['IMAGE_SIZE'] if far else up(len(raw))
    end=pre+image_size
    fl=layout['FILE_IMAGE_LEN'] if far else len(raw)
    patch_size=up(len(raw)-fl) if far else image_size-po
    lib=dest/('libs2a_guest_'+build_id+'.so')
    asm=[]
    sections=([('x1','ax',fl,fl+patch_size),('x0','ax',0,x0),('w','aw',x0,fl)] if far else
              [('x0','ax',0,x0),('w','aw',x0,po),('x1','ax',po,end)])
    for section,flags,lo,hi in sections:
        asm.extend([f'.section .guest.{section},"{flags}",@progbits','.balign 16384'])
        if lo==0:asm.extend(['.global s2a_guest_image','.type s2a_guest_image,@object','s2a_guest_image:'])
        count=min(hi,len(raw))-lo
        asm.append(f'.incbin "{raw_path.as_posix()}", {lo}, {count}')
        if hi-lo>count:asm.append(f'.zero {hi-lo-count}')
    if far:asm.extend(['.section .guest.bss,"aw",@nobits','.balign 16384',f'.zero {image_size-fl}'])
    asm.extend([f'.size s2a_guest_image,{image_size}', '.section .rodata.guest.meta,"a",@progbits','.balign 8',
                '.global s2a_guest_descriptor','.type s2a_guest_descriptor,@object','s2a_guest_descriptor:'])
    fields=[MAGIC,2 if far else 1,len(raw),end,layout['TEXT_END'],po,layout['KEY_PAGE_OFF'],PAGE,len(fix),len(gates)]
    asm.extend(f'.quad {v}' for v in fields)
    asm.append('.size s2a_guest_descriptor,.-s2a_guest_descriptor')
    for name,p in [('fixups',fix_path),('gates',gate_path)]:
        asm.extend([f'.global s2a_guest_{name}',f'.type s2a_guest_{name},@object',f's2a_guest_{name}:',f'.incbin "{p.as_posix()}"',f'.size s2a_guest_{name},.-s2a_guest_{name}'])
    asm.append('.section .note.GNU-stack,"",@progbits')
    source=dest/(module+'.S');source.write_text('\n'.join(asm)+'\n',encoding='utf-8')
    script='''PHDRS {
 phdr PT_PHDR PHDRS FLAGS(4); meta PT_LOAD FILEHDR PHDRS FLAGS(4);
 x0 PT_LOAD FLAGS(5); w PT_LOAD FLAGS(6); x1 PT_LOAD FLAGS(5);
 dynamic PT_DYNAMIC FLAGS(4); stack PT_GNU_STACK FLAGS(6);
}
SECTIONS {
 . = SIZEOF_HEADERS;
 .note.gnu.build-id : { *(.note.gnu.build-id) } :meta
 .hash : { *(.hash) } :meta
 .gnu.hash : { *(.gnu.hash) } :meta
 .dynsym : { *(.dynsym) } :meta
 .dynstr : { *(.dynstr) } :meta
 .guest.meta : { KEEP(*(.rodata.guest.meta)) } :meta
 .dynamic : { *(.dynamic) } :meta :dynamic
 . = ALIGN(0x4000);
 .guest.x0 : { KEEP(*(.guest.x0)) } :x0
 .guest.w : { KEEP(*(.guest.w)) } :w
 .guest.x1 : { KEEP(*(.guest.x1)) } :x1
 /DISCARD/ : { *(.comment) *(.note.GNU-stack) }
}
'''
    if far:
        script=script.replace('x0 PT_LOAD FLAGS(5); w PT_LOAD FLAGS(6); x1 PT_LOAD FLAGS(5);',
                              'x1 PT_LOAD FLAGS(5); x0 PT_LOAD FLAGS(5); w PT_LOAD FLAGS(6);')
        script=script.replace(' .guest.x0 : { KEEP(*(.guest.x0)) } :x0\n .guest.w : { KEEP(*(.guest.w)) } :w\n .guest.x1 : { KEEP(*(.guest.x1)) } :x1',
                              ' .guest.x1 : { KEEP(*(.guest.x1)) } :x1\n'+f' . = ADDR(.guest.x1) + {pre};\n'+
                              ' .guest.x0 : { KEEP(*(.guest.x0)) } :x0\n .guest.w : { KEEP(*(.guest.w)) } :w\n'+
                              ' .guest.bss (NOLOAD) : { KEEP(*(.guest.bss)) } :w')
        script+=f'ASSERT(ADDR(.guest.bss) == ADDR(.guest.x0) + {fl}, "BSS offset changed")\n'
        script+=f'ASSERT(ADDR(.guest.x0) == ADDR(.guest.x1) + {pre}, "FAR patch offset changed")\n'
    else:
        script+=f'ASSERT(ADDR(.guest.x1) == ADDR(.guest.x0) + {po}, "patch offset changed")\n'
    script+=f'ASSERT(ADDR(.guest.w) == ADDR(.guest.x0) + {x0}, "data offset changed")\n'
    linker=dest/(module+'.ld');linker.write_text(script,encoding='utf-8')
    commands=[]
    def run(label,args):
        args=[str(x) for x in args];p=subprocess.run(args,capture_output=True)
        (dest/(label+'.stdout.txt')).write_bytes(p.stdout);(dest/(label+'.stderr.txt')).write_bytes(p.stderr)
        commands.append({'command':args,'exitCode':p.returncode})
        (dest/'commands.json').write_text(json.dumps(commands,indent=2),encoding='utf-8')
        if p.returncode:raise RuntimeError(p.stderr.decode(errors='replace'))
    exe='.exe' if sys.platform=='win32' else ''
    obj=dest/(module+'.o')
    run('assemble',[ndk/('llvm/bin/clang'+exe),'--target=aarch64-linux-ohos','-c',source,'-o',obj])
    run('link',[ndk/('llvm/bin/ld.lld'+exe),'-shared','--build-id=sha1','--hash-style=both','-z','max-page-size=16384','-T',linker,'-soname',lib.name,obj,'-o',lib])
    run('readelf',[ndk/('llvm/bin/llvm-readelf'+exe),'-h','-l','-d','-s',lib])
    elf=lib.read_bytes();eh=struct.unpack_from('<16sHHIQQQIHHHHHH',elf)
    if eh[1:4]!=(3,183,1):raise ValueError('Wrong ELF machine/type')
    loads=[]
    for i in range(eh[10]):
        ph=struct.unpack_from('<IIQQQQQQ',elf,eh[5]+i*eh[9])
        if ph[0]==1:loads.append(ph)
    permissions=[4,5,5,6] if far else [4,5,6,5]
    if [p[1] for p in loads]!=permissions:raise ValueError('Unexpected ELF permissions')
    for i,p in enumerate(loads):
        if not (p[5]<=p[6] and p[2]+p[5]<=len(elf) and p[7]==PAGE and p[2]%PAGE==p[3]%PAGE):
            raise ValueError('Invalid ELF LOAD size or alignment')
        if i and loads[i-1][3]+loads[i-1][6]>p[3]:raise ValueError('Overlapping ELF LOADs')
    if far:
        meta,patch,text,data=loads;base=text[3]
        if ([p[3]-base for p in loads[1:]]!=[po,0,x0] or
                patch[5]!=patch_size or patch[6]!=patch_size or text[5]!=x0 or text[6]!=x0 or
                data[5]!=fl-x0 or data[6]!=image_size-x0 or meta[5]!=meta[6]):
            raise ValueError('Signed FAR carrier changed addresses or BSS extent')
        for p,expected in [(patch,raw[fl:]+bytes(patch_size-(len(raw)-fl))),
                           (text,raw[:x0]),(data,raw[x0:fl])]:
            if elf[p[2]:p[2]+p[5]]!=expected:raise ValueError('Signed FAR carrier changed image or patch bytes')
    else:
        image=bytearray(end);base=loads[1][3]
        for p in loads[1:]:
            if p[5]!=p[6]:raise ValueError('Unexpected near BSS')
            image[p[3]-base:p[3]-base+p[5]]=elf[p[2]:p[2]+p[5]]
        if image[:len(raw)]!=raw or any(image[len(raw):]):raise ValueError('Signed carrier changed image bytes')
        if [p[3]-base for p in loads[1:]]!=[0,x0,po]:raise ValueError('Signed carrier changed relative addresses')
    return {'module':module,'buildId':build_id,'library':str(lib),'librarySha256':sha(lib),
            'bytes':lib.stat().st_size,'rawSha256':sha(raw_path),'fixupsSha256':sha(fix_path),'gatesSha256':sha(gate_path),
            'originalBytesAndRelativeAddressesPreserved':True,'loadPermissions':permissions,'descriptorVersion':2 if far else 1,
            'patchOffset':po,'patchBytes':patch_size,'imageBytes':image_size,'mappedBytes':end,
            'zeroFillBytes':image_size-fl if far else 0,'deviceExecutionVerified':False}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--native-sdk',type=Path,required=True);p.add_argument('--modules',nargs='+',required=True)
    a=p.parse_args();a.input=a.input.resolve();a.output=a.output.resolve();a.native_sdk=a.native_sdk.resolve()
    repo=Path(__file__).resolve().parents[1]
    if (repo/'AGENTS.md').exists() and (a.output==repo or repo in a.output.parents):p.error('Game-derived output must stay outside the Git repository')
    results=[build_one(m,a.input,a.output,a.native_sdk) for m in a.modules]
    (a.output/'manifest.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
    print(json.dumps(results,indent=2))
if __name__=='__main__':main()
