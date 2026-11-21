#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Android-local mapping of S2A_TARGET=android rewriter output, following
// runtime/src/loader.c's non-iOS path until the shared loader runs on Android
// through platform/plat.h. No relocation, imports or gate dispatch here.

enum { S2A_KEY_K18, S2A_KEY_KTLS, S2A_KEY_KTLR, S2A_KEY_KGATE, S2A_KEY_N };

struct s2a_module_layout {
    int64_t patch_off, patch2_off;   // patch2_off：双补丁岛的另一个岛（0 = 单岛）；近布局在基址前，FAR 在键页后
    uint64_t image_size, file_image_len, key_page_off, key_page_size, text_end, data_off, patch2_len;
    unsigned key_idx[S2A_KEY_N];
};

struct s2a_module {
    struct s2a_module_layout l;
    uint8_t *map, *base;   // map: whole mapping (starts with the patch area when patch_off < 0)
    size_t map_size;
    size_t patch_size; // 实际 RX 补丁区长度；FAR 前置保留空洞不算补丁。
    size_t patch2_size; // 双补丁岛另一个岛的长度（= PATCH2_LEN；映像文件末尾那段）
#if defined(__OHOS__)
    void *platform_owner; // HAP-signed DSO; never munmap a loader-owned range.
#endif
};

// Parses a fixups.tsv header. Output without "# TARGET android" is refused:
// its thread-slot code reads Apple's tpidrro_el0. Returns 0 or an errno value
// with a message in err.
int s2a_module_layout(const char *path, struct s2a_module_layout *l, char *err, size_t n);

// Maps <dir>/<name>.patched.bin into anonymous memory (never PROT_EXEC on the
// file), writes the key page from per-key slot offsets (bionic: table offset +
// 16 * index + 8, all non-zero), then seals the text and patch areas R|X.
int s2a_module_map(const char *dir, const char *name, const uint64_t slot_off[S2A_KEY_N],
                   struct s2a_module *m, char *err, size_t n);

// Maps exactly the image path the caller validated (e.g. <revision>/other/main.patched.bin).
// The directory / module name are derived from the path; fixups.tsv and gates.tsv must be
// next to the image, as with s2a_module_map.
int s2a_module_map_path(const char *image, const uint64_t slot_off[S2A_KEY_N],
                        struct s2a_module *m, char *err, size_t n);
void s2a_module_unmap(struct s2a_module *m);

// The same from bytes already in memory (APK assets: the signed APK is the only copy, nothing
// is written to storage). what names the source in error messages. The buffers are only read
// and can be freed once the call returns.
int s2a_module_layout_mem(const char *text, size_t len, const char *what, struct s2a_module_layout *l, char *err, size_t n);
int s2a_module_map_mem(const char *what, const char *fixups, size_t fixups_len, const uint8_t *image, size_t image_len,
                       const uint64_t slot_off[S2A_KEY_N], struct s2a_module *m, char *err, size_t n);

#ifdef __cplusplus
}
#endif
