# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
import importlib.util,unittest
from pathlib import Path
path=Path(__file__).resolve().parents[1]/'build_signed_modules.py'
spec=importlib.util.spec_from_file_location('signed_modules',path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
def fixture():
    values={'BUILD_ID':'0123456789abcdef0123456789abcdef','TARGET':'ohos','REWRITE_ABI':'ohos-sp-safe-v1',
            'TEXT_END':'0x1000','RO_OFF':'0x1000','DATA_OFF':'0x4000','KEY_PAGE_OFF':'0x8000','KEY_PAGE_SIZE':'0x4000','PATCH_OFF':'0xc000',
            'KEY_K18_IDX':'0','KEY_KTLS_IDX':'1','KEY_KTLR_IDX':'2','KEY_KGATE_IDX':'3','KEY_TSDOFF_IDX':'4'}
    return values,bytes(0xc004)
def encoded(values):return ''.join('# '+k+'\t'+v+'\n' for k,v in values.items()).encode()
class Contract(unittest.TestCase):
    def test_valid(self):
        v,b=fixture();ident,layout=module.read_layout(encoded(v),b);self.assertEqual(ident,v['BUILD_ID']);self.assertEqual(layout['PATCH_OFF'],0xc000)
    def test_incompatible_inputs(self):
        for key,value in [('TARGET','android'),('REWRITE_ABI','ohos-below-sp-v1'),('BUILD_ID','../bad'),('PATCH_OFF','-0x2000000'),('PATCH_OFF','0xc001'),('KEY_TSDOFF_IDX','3'),('KEY_K18_IDX','4'),('KEY_PAGE_OFF','0xc000'),('TEXT_END','0x5000')]:
            with self.subTest(key=key,value=value):
                v,b=fixture();v[key]=value
                with self.assertRaises(ValueError):module.read_layout(encoded(v),b)
    def test_duplicate_header(self):
        v,b=fixture()
        with self.assertRaises(ValueError):module.read_layout(encoded(v)+b'# TARGET\tohos\n',b)
    def test_prepopulated_keypage(self):
        v,b=fixture();b=bytearray(b);b[0x8000]=1
        with self.assertRaises(ValueError):module.read_layout(encoded(v),b)
if __name__=='__main__':unittest.main()
