// 云端管线种子（手机直导 .s2arm 的款补预热种子）：实现与说明见 ios/cloud_seed.m，单测 runtime/tests/t_cloud_seed.m
#pragma once
#ifdef __OBJC__
#import <Foundation/Foundation.h>
// 统一包 g/<程序号>.json.gz 的字节 → pso_cloud.tsv 的内容（表头 + 各 pso 条目原样拼接，每条核 sha256）；*items = 收下的条数。解不开 = -1
int s2a_cloud_seed_build(NSData *gz, const char *gid, NSData **out, int *items);
#endif
// 后台取这款的云端管线种子，写 <docs>/games/<程序号>/wire/<程序号>/pso_cloud.tsv。docs = 容器 Documents；force = 0 时表已在就不取（开局），1 总是重取（导入）。立即返回
void s2a_cloud_seed_fetch(const char *docs, const char *gid, int force);
