#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 外接显示器原生全屏的接线单测（ios/extdisplay.m、ios/app.m、graphics/nvn/host_adapt.m）：bash runtime/tests/t_ext_display.sh
# 真机行为（系统连不连外接屏场景、出图层挪不挪）要显示器和设备，这里只守接线不被改丢。期望手写（不跑被测实现）：
# ① iOS 27 起系统只对登记了场景配件的控制器连外接屏场景：extdisplay.m 在 @available(iOS 27.0) 下用外接屏非交互角色、指到本文件里的场景代理类登记；
# ② 游戏界面控制器 S2AGameVC 建好就登记并持有（游戏库界面不登记）；
# ③ 出图层挂 / 重摆都经出图视图（外接屏窗口的视图或根视图），重摆的后台判据走 pf_relayout_wait；
# ④ 枚举场景找「最上层界面 / 手机朝向」的三处跳过外接屏场景（那块屏点不到）；
# ⑤ 屏幕比例优先取外接屏的（#301 起屏幕比例在 ios/play_layout.m 的 screen_ratio，分屏布局与外接屏同一处）。
set -u; H=$(cd "$(dirname "$0")/../.." && pwd); bad=0
ck() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; bad=1; fi; }
cd "$H"
E=ios/extdisplay.m; A=ios/app.m; P=ios/play_layout.m; G=graphics/nvn/host_adapt.m; ROLE=UIWindowSceneSessionRoleExternalDisplayNonInteractive
ck "① extdisplay.m 有场景代理类 S2AExternalSceneDelegate" 'grep -q "^@implementation S2AExternalSceneDelegate" $E'
ck "① 登记场景配件：iOS 27 可用性判断 + 外接屏非交互角色 + 委托类 + registerSceneAccessory" \
   'grep -q "@available(iOS 27.0, \*)" $E && grep -q "sessionRole:$ROLE" $E && grep -q "delegateClass = S2AExternalSceneDelegate.class" $E && grep -q "registerSceneAccessory:\[UISceneAccessory externalNonInteractiveSceneAccessoryWithConfiguration:" $E'
ck "① S2A_EXT_DISPLAY=0 不登记（开关在登记入口判）" 'sed -n "/^id s2a_ios_ext_register/,/^}/p" $E | grep -q "ext_on()"'
gv=$(sed -n '/^@implementation S2AGameVC/,/^@end/p' $A)
ck "② S2AGameVC viewDidLoad 登记并持有" 'echo "$gv" | grep -q "viewDidLoad.*self.extDisplay = s2a_ios_ext_register(self)"'
ck "② 登记只在 S2AGameVC 里调（app.m 共 1 处调用）" '[ "$(grep -c "= s2a_ios_ext_register(" $A)" = 1 ]'
ck "③ 出图层建时挂到出图视图" 'sed -n "/^void \*front_metal_layer/,/^}/p" $G | grep -q "UIView \*v = present_view();"'
ck "③ 重摆取出图视图、层不在该视图的层子树里就挪（Duo 倒影把层包进容器层，只比直接父层会每次误挪）" 'sed -n "/^void s2a_direct_relayout/,/^}/p" $G | grep -q "UIView \*v = g_layer ? present_view() : nil" && sed -n "/^void s2a_direct_relayout/,/^}/p" $G | grep -qF "for (CALayer *q = g_layer.superlayer; q; q = q.superlayer) if (q == v.layer) { moved = 0; break; }"'
ck "③ 重摆的后台判据走 pf_relayout_wait" 'sed -n "/^void s2a_direct_relayout/,/^}/p" $G | grep -q "if (pf_relayout_wait(ext, app_bg, moved, scene_fg))"'
for f in ios/lan_permission.m ios/textinput.m ios/phone_motion.m; do
  ck "④ $f 枚举场景跳过外接屏场景" 'grep -q "session.role isEqualToString:$ROLE" $f'
done
ck "⑤ 屏幕比例优先取外接屏" 'sed -n "/^static double screen_ratio/,/^}/p" $P | grep -q "double x = s2a_ios_ext_ratio(); if (x > 0) return x;"'
[ $bad = 0 ] && echo "外接显示器接线单测全过" || exit 1
