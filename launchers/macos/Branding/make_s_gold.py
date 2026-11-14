# 用法：python3 launchers/macos/Branding/make_s_gold.py launchers/macos/Branding/AppIcon-1024.png launchers/macos/Branding/s-gold.png
#   生成后同一份拷到 shell/Sources/ShellUI/Resources/s-gold.png（iOS 游戏设置的 S 级优化专区用）
# 金色 S（毛玻璃 · 双色拼接）：按图标底色把每个像素还原成「半透明颜色 + 透明度」（去掉底色），原图的玻璃质感、亮边、中缝原样保留；
#   再按原图红 / 蓝两半分别换色（色相、饱和度换成目标两色，明度不动）
import sys, numpy as np
from PIL import Image
src, out = sys.argv[1], sys.argv[2]
# 上半（原红）香槟金、下半（原蓝）玫瑰金：两半都是金色系，整体仍是金色 S；明暗差保住中缝（11-13 定稿）
a_hsv, b_hsv = (sys.argv[3], sys.argv[4]) if len(sys.argv) > 4 else ('42,0.72,1.02', '14,0.62,0.95')
A = [float(v) for v in a_hsv.split(',')]; B = [float(v) for v in b_hsv.split(',')]   # 色相 0–360、饱和度 0–1、明度倍率
px = np.asarray(Image.open(src).convert('RGB')).astype(np.float32) / 255
h, w, _ = px.shape
# 逐行底色：图标底是上紫灰 → 下蓝灰的竖向渐变，S 碰不到左右边：每行取这一行左右两边各 24 像素的中位数当底色
edge = np.concatenate([px[:, 4:28], px[:, -28:-4]], axis=1)
bg = np.median(edge, axis=1)[:, None, :].repeat(w, axis=1)
# 去底色：最小的 a 使 color = (px - bg(1-a)) / a 落在 [0,1]
up = np.where(px > bg, (px - bg) / np.maximum(1 - bg, 1e-3), 0); dn = np.where(px < bg, (bg - px) / np.maximum(bg, 1e-3), 0)
a = np.clip(up.max(axis=2), 0, 1)   # 只认比底色亮的部分：S 本体与光晕都比底亮；比底暗的是图标内框暗角，不算进来（否则浅一点的卡片上露出一圈黑方框）
a = np.clip((a - 0.07) / 0.93, 0, 1)   # 底色噪点与四周暗角归零                      # 底色噪点归零
col = np.clip((px - bg * (1 - a[..., None])) / np.maximum(a[..., None], 1e-4), 0, 1)
# 红半 / 蓝半的归属（0 = 原红，1 = 原蓝），中缝处自然过渡
r, g, b = col[..., 0], col[..., 1], col[..., 2]
k = np.clip(((b - r) / (r + b + 1e-4)) * 0.9 + 0.5, 0, 1)
mx = col.max(axis=2); mn = col.min(axis=2); s0 = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-4), 0)
import colorsys
cA = np.array(colorsys.hsv_to_rgb(A[0] / 360, A[1], 1.0)) * A[2]; cB = np.array(colorsys.hsv_to_rgb(B[0] / 360, B[1], 1.0)) * B[2]
tint = cA * (1 - k[..., None]) + cB * k[..., None]
white = np.clip((mx - 0.0) * (1 - s0), 0, 1)[..., None]   # 原图偏白的高光（亮边、接缝）保持偏白
rgb = np.clip(mx[..., None] * (tint * (1 - white * 0.7) + white * 0.7), 0, 1)
img = Image.fromarray((np.dstack([rgb, a]) * 255).astype(np.uint8), 'RGBA')
box = img.getchannel('A').point(lambda x: 255 if x > 10 else 0).getbbox(); pad = 28
box = (max(0, box[0] - pad), max(0, box[1] - pad), min(w, box[2] + pad), min(h, box[3] + pad)); img = img.crop(box)
side = max(img.size); sq = Image.new('RGBA', (side, side), (0, 0, 0, 0)); sq.paste(img, ((side - img.size[0]) // 2, (side - img.size[1]) // 2))
sq.resize((512, 512), Image.LANCZOS).save(out, optimize=True)
