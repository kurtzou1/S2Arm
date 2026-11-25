#pragma once
#import <Foundation/Foundation.h>
// 诊断包收成员（ios/diagcollect.m）：Documents 根 D 下该收的文件收进工作目录 W，files / sessions 追加 manifest 用的条目，crash / hang / exits 记 MetricKit 份数。
//   redact：文本脱敏（返回 nil = 失败）；summary：一份会话日志的摘要（nil = 不记）。返回 NO = 有文本文件脱敏或写出失败
BOOL s2a_diag_collect(NSString *D, NSString *W, NSUInteger cap, BOOL slim, NSString *(^redact)(NSString *),
                      NSDictionary *(^summary)(NSString *path, NSString *name, BOOL current),
                      NSMutableArray *files, NSMutableArray *sessions, int *crash, int *hang, int *exits);
// 出问题那款的资源包索引（D-JZRD 11-25：App 里直接报修的单子没有帖子，没法回头向玩家要机上的 index.tsv）：<root>/index.tsv 过脱敏、超 cap 截头尾，
//   放 logs/index_<游戏号>.tsv（游戏号空 = logs/index.tsv）。只这一款、只这一份：路径 / 大小 / 哈希，不含存档与个人数据。没有这份返回 YES（不算失败）；写失败返回 NO
BOOL s2a_diag_collect_index(NSString *root, NSString *gid, NSString *W, NSUInteger cap, NSString *(^redact)(NSString *), NSMutableArray *files);
