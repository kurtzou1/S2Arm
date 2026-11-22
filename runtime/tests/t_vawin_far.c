// Mac 地址模拟与生产远端围栏：复用 t_layout 的 300 MiB 模块 / 80 MiB 系统资源布局参数，
// 不生成 NPDM、不装载游戏。真实 mmap 和 vm_region 验证唯一的 512 MiB 高区房间在 far_set 后仍可用。
#include "../src/native.h"
#include <mach/mach.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
int s2a_host_hi_range(uint64_t *lo, uint64_t *hi);   // vawin.c（不进 native.h：它是抽取阶段的冷输入）

#define GB (1ull << 30)
#define MB (1ull << 20)
static int bad, checks;
#define CHECK(ok, ...) do { checks++; if (!(ok)) { bad++; printf("✗ " __VA_ARGS__); putchar('\n'); } } while (0)

// 全扫描 512–577 GiB：原围栏与新围栏都只应留一个 512 MiB 空洞，其余地址仍受约束。
static uint64_t high_holes(const char *when, uint64_t *first) {
    const uint64_t end = 577 * GB;
    uint64_t prev = 512 * GB, holes = 0;
    vm_address_t a = prev; *first = 0;
    while (a < end) {
        vm_size_t size = 0; vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t object = MACH_PORT_NULL;
        int ok = vm_region_64(mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object) == KERN_SUCCESS;
        if (MACH_PORT_VALID(object)) mach_port_deallocate(mach_task_self(), object);
        uint64_t next = ok && a < end ? a : end;
        if (next > prev) { if (!*first) *first = prev; holes += next - prev; }
        if (!ok || a >= end) break;
        prev = a + size; a += size;
    }
    printf("高区空洞 [%s]：首址 %#llx、合计 %llu MiB\n", when, (unsigned long long)*first, (unsigned long long)(holes / MB));
    return holes;
}

static int room_maps(uint64_t at) {
    void *p = mmap((void *)at, 512 * MB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    int exact = p == (void *)at;
    if (exact) { ((volatile uint8_t *)p)[0] = 0x35; ((volatile uint8_t *)p)[512 * MB - 1] = 0x79; }
    if (p != MAP_FAILED && munmap(p, 512 * MB)) die("回归测试 munmap 失败");
    return exact;
}

static int reserved_none(uint64_t at) {
    vm_address_t a = at; vm_size_t size = 0; vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t object = MACH_PORT_NULL;
    int ok = vm_region_64(mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object) == KERN_SUCCESS;
    if (MACH_PORT_VALID(object)) mach_port_deallocate(mach_task_self(), object);
    return ok && a <= at && at - a < size && info.protection == VM_PROT_NONE;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    uint64_t base, size, room_before, room_after;
    s2a_window_get(&base, &size);
    CHECK(s2a_window_ok(), "窗口应已在构造期占到");
    CHECK(high_holes("far 前", &room_before) == 512 * MB, "far 前高区仅保留 512 MiB");
    if (!room_before) return 1;
    CHECK(room_maps(room_before), "far 前整块 512 MiB 应能精确映射并写首尾页");

    s2a_layout layout; uint64_t mod_base, shadow;
    int rc = s2a_layout_compute(3, 80 * MB, 300 * MB, 0, base, size, &layout, &mod_base, &shadow);
    CHECK(rc == 0 && shadow != 0, "生产乙布局应成功且启用影子区");
    if (rc || !shadow) return 1;
    s2a_window_trim(layout.win_size);
    uint64_t lo = layout.win_base + layout.win_size, hi = layout.alias_base + layout.alias_size;
    int maximum = argc == 2 && !strcmp(argv[1], "max-span");
    if (maximum) { lo = 512 * GB; hi = lo + 64 * GB + 2 * MB; } // 独立覆盖生产 far_set 的 64 GiB 截断，不称游戏布局。
    s2a_far_set(lo, hi, layout.heap_base, layout.heap_base + layout.heap_size);

    CHECK(high_holes("far 后", &room_after) == 512 * MB, "far 后高区仍应保留同样的 512 MiB，不能被远端收回");
    CHECK(room_maps(room_before), "far 后原房间仍应能精确映射 512 MiB 并写首尾页");
    CHECK(room_after == room_before && room_before == 576 * GB, "房间须在 512 GiB + 最大远端 64 GiB 边界处");
    CHECK(s2a_far_has(lo, 0x4000) && reserved_none(lo), "远端起点仍应属于 far 且保持 PROT_NONE");
    CHECK(!s2a_far_has(room_before, 1), "malloc 房间不能属于远端");
    CHECK(reserved_none(512 * GB) && reserved_none(576 * GB - 0x4000) && reserved_none(576 * GB + 512 * MB), "原房间、房间前后高区仍受围栏约束");
    if (maximum) CHECK(s2a_far_has(576 * GB - 0x4000, 0x4000) && !s2a_far_has(576 * GB, 1), "超长远端须截到 576 GiB，不侵入房间");
    if (!maximum) {   // 宿主高位区（乙：窗口放不下标准布局，赤痕 / 轩辕剑柒同形）= 窗口下方留给宿主的 6 GiB（宿主下限，11-06 由 1 GiB 改 3 GiB、11-22 改 6 GiB）；不碰远端、不进窗口。
        //   直连库段（graphics/nvn/lib_pack.inc lp_map）带提示映射落在这里；对照 mmap(NULL) 落 0x1_8000_0000 以下的低区（GC 新段只能落那里，11-05 托管 OOM 的根因）
        uint64_t hl = 0, hh = 0; int hr = s2a_host_hi_range(&hl, &hh);
        CHECK(hr == 1 && hh == base && hh - hl == 6 * GB, "乙布局高位区应为窗口下方 6 GiB [%#llx, %#llx)，得 rc=%d [%#llx, %#llx)", (unsigned long long)(base - 6 * GB), (unsigned long long)base, hr, (unsigned long long)hl, (unsigned long long)hh);
        CHECK(hh <= lo && !s2a_far_has(hl, hh - hl), "高位区不与远端 / 窗口重叠");
        char tf[] = "/tmp/t_vawin_far_f.XXXXXX"; int fd = mkstemp(tf); const size_t L = 4 * MB;
        CHECK(fd >= 0 && !ftruncate(fd, L), "建临时文件");
        if (fd >= 0) { void *m = mmap((void *)hl, L, PROT_READ, MAP_PRIVATE, fd, 0), *z = mmap(NULL, L, PROT_READ, MAP_PRIVATE, fd, 0);
            CHECK(m != MAP_FAILED && (uint64_t)m >= hl && (uint64_t)m + L <= hh, "带提示的文件映射落在高位区（得 %p）", m);
            CHECK(z != MAP_FAILED && (uint64_t)z < 0x180000000ull, "对照：mmap(NULL) 落在 0x1_8000_0000 以下的低区（得 %p）", z);
            if (m != MAP_FAILED) munmap(m, L); if (z != MAP_FAILED) munmap(z, L); close(fd); unlink(tf); }
    }
    printf("%s t_vawin_far（%s）：%d 项、%d 处不符\n", bad ? "✗" : "✓", maximum ? "最大跨度截断" : "生产布局", checks, bad);
    return bad != 0;
}
