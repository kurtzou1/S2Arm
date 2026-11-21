# native-test-present_hdr_gal：PR7 gal 通用路径 HDR 策略一致性闭环（graphics/metal/tests/t_present_hdr.m；评审稿 v3 §4 PR7 / §2.2 接缝 / §2.3 判定次序 / §2.4 模式矩阵）。
#   生产 gal 全链路（render_to = 上屏同一段编码，真 Metal 设备）+ 生产策略存储（graphics/nvn/gfx/nvn/nvn2.c，经
#   graphics/metal/Makefile 的 t_present_hdr 单测线链进单测可执行文件——gal 生产代码经 dlsym 接缝命中的就是这份生产强定义）。
#   构建走 graphics/metal 的通用单测规则（同一份旗标：工具链 / SDK 映射 / 生成头 / 离线辅助库 / libdsx，不在此重复）；
#   跑全 36 项闭环（① off 不变量对改前 trivial 采样逐字节 / ② PQ 层进入 / ③ mode 2 对拍 CPU 双精度复算 ±1 /
#   ④ 排空切回 sRGB 显式重设 / ⑤ off 回归）。三态流：test-only / negctl 态退出码 1（29 / 36，7 ✗）。
#   通用 gal 单测套（gfx-test-metal）同样自动收编本测试；本目标单独构建 + 直跑（门禁三态用，比整套 gal 快）。
NATIVE_TEST_OWN += present_hdr_gal
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-present_hdr_gal
native-test-present_hdr_gal:
	$(MAKE) -C graphics/metal $(CURDIR)/build/gal/t_present_hdr
	$(CURDIR)/build/gal/t_present_hdr
TEST_TARGETS += native-test-present_hdr_gal
endif
