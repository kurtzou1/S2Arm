// 即时快照的删除（0.6.0）：游戏库 / 游戏里长按「删除这一刻」删掉这一款的快照，空间真腾出来。
//   快照目录连同缩略图、清单、内存块一起删；存到一半留下的 <目录>.new、旧版换上新快照时可能留下的 <目录>.old 也一并删。
//   删整棵目录的 s2a_snap_rmtree 也给存档引擎（snapshot.c）删临时 / 旧目录用，同一份实现。不依赖引擎其余部分，单测只链本文件
#include <errno.h>
#include <fts.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

// 删整棵目录；不存在不算错；不跟符号链接（链接本身删掉，指向的东西不碰）
void s2a_snap_rmtree(const char *path) {
    char *av[] = {(char *)path, NULL}; FTS *fs = fts_open(av, FTS_PHYSICAL | FTS_NOCHDIR, NULL); if (!fs) return;
    for (FTSENT *e; (e = fts_read(fs));) { if (e->fts_info == FTS_DP) rmdir(e->fts_path); else if (e->fts_info == FTS_F || e->fts_info == FTS_SL || e->fts_info == FTS_SLNONE || e->fts_info == FTS_DEFAULT) unlink(e->fts_path); }
    fts_close(fs);
}

// 把写完的新快照 neu 换到 final（snapshot.c 存档最后一步）：0 换上了，-1 没换上（final 原样不动）。
//   有旧快照时一次 RENAME_SWAP 原子交换两个目录，再删换下来的旧目录（此时在 neu 名下）。原先是两次改名：final → final.old、neu → final，
//   进程死在两次之间时 final 不存在（玩家看不到快照），下一次存档开头还会删掉 final.old，旧快照就丢了。
//   没有旧快照（首存）时交换报 ENOENT，退回普通改名
int s2a_snap_swap_in(const char *neu, const char *final) {
    if (!renamex_np(neu, final, RENAME_SWAP)) { s2a_snap_rmtree(neu); return 0; }
    if (errno == ENOENT && !rename(neu, final)) return 0;
    return -1;
}

// 换上没走完留下的 <目录>.old（旧版两次改名，进程死在两次之间：正式目录不在、旧快照在 .old 名下）：正式目录不在就把 .old 改回正式目录；
//   两个都在时 .old 是换下来没删掉的那份，删掉。读快照（s2a_snap_exists）与存档开头都先调，旧快照不会因为下一次存档被删。回 1 = 恢复了一份
int s2a_snap_recover(const char *final) {
    char old[2100]; struct stat st;
    if (!final || !*final || snprintf(old, sizeof old, "%s.old", final) >= (int)sizeof old || lstat(old, &st)) return 0;
    if (lstat(final, &st)) return !rename(old, final);
    s2a_snap_rmtree(old); return 0;
}

// 引擎正在存档时为 1（snapshot.c）；单测只链本文件、没有它 = 当作没在存
// 弱链接[host]：s2a_snap_busy（runtime/src/snapshot.c 提供；snapdel 单测只链本文件）
int s2a_snap_busy(void) __attribute__((weak_import));
// 删掉一款的快照：0 删干净了（三个目录都不在了）；-2 引擎正在存（存到一半往 <目录>.new 写、最后挪名换上，这时删会和它互相踩），不删；
//   -1 参数不对（相对路径也不收：调用方都给 s2a_snap_dir_for 的绝对路径，相对路径会按进程当前目录去删）或还有删不掉的
int s2a_snap_delete(const char *dir) {
    if (!dir || dir[0] != '/') return -1;
    if (s2a_snap_busy && s2a_snap_busy()) return -2;
    char p[2100]; struct stat st; int left = 0;
    const char *suffix[] = {"", ".new", ".old"};
    for (int i = 0; i < 3; i++) {
        if (snprintf(p, sizeof p, "%s%s", dir, suffix[i]) >= (int)sizeof p) return -1;
        s2a_snap_rmtree(p); left |= lstat(p, &st) == 0;
    }
    return left ? -1 : 0;
}
