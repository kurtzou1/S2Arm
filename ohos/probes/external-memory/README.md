# 原创外部内存测试夹具

只包含原创合成输入与探针源码，不含游戏着色器。make_shader.py生成transform_spv.h，transform.comp描述同一合成操作。
构建入口：python build.py --help；通过--sdk、--validator、--out传入工具与新输出目录。
探针不属于正常应用入口；不证明游戏首帧、真实设备画面或性能。
