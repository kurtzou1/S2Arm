from pathlib import Path
import sys,hashlib
root=Path(sys.argv[1]);out=Path(sys.argv[2])
w=(root/'android/native/nvn/backend_vulkan_wsi.inc').read_text();e=(root/'android/native/nvn/backend_vulkan_easu.inc').read_text()
def func(s,name):
 start=s.index('static int '+name+'(');end=s.index('\n}',start)+2
 return s[start:end]+'\n'
start=e.index('struct easu_rects {');end=e.index('\n',e.index('enum easu_rect_fit',start))
parts=e[start:end]+'\n'+func(e,'easu_rects_prepare')
parts+='\n'+func(w,'wsi_compose_blit')+func(w,'wsi_compose_easu')+func(w,'wsi_compose_selected')
# Test exactly the production functions, unmodified; no copied test dispatch.
# Exact production functions; standalone definition boundaries must remain recognizable.
needle='if (fit == EASU_RECT_SKIP) return -1;'
assert parts.count(needle)==1
negative=parts.replace(needle,'/* negative control: omit only preflight */')
for name,body in [('candidate',parts),('omit_preflight',negative)]:
 directory=out/name
 directory.mkdir(parents=True,exist_ok=True)
 (directory/'nvn_wsi_easu_production.inc').write_text(body)
print('WSI_SHA256',hashlib.sha256(w.encode()).hexdigest());print('EASU_SHA256',hashlib.sha256(e.encode()).hexdigest())
