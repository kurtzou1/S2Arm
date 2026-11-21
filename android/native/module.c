#include "module.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__OHOS__)
#define S2A_MODULE_TARGET "ohos"
#define S2A_MODULE_ABI "ohos-sp-safe-v1"
#else
#define S2A_MODULE_TARGET "android"
#define S2A_MODULE_ABI "android-sp-safe-v1"
#endif
#if defined(__ANDROID__) || defined(__OHOS__)
#include "../../runtime/src/native.h"
int s2a_key_page_writable(module_t *m) {
    if (!m || !m->base || !m->key_page_size) return -1;
    return mprotect(m->base + m->key_page_off, m->key_page_size, PROT_READ | PROT_WRITE);
}
#endif
#if defined(__OHOS__)
#include "../../ohos/native/tsd_ohos.h"
#include "../../ohos/native/signed_module.h"
#include <dlfcn.h>
#endif

#define PAGE16 0x4000ull
#define UP16(x) (((x) + PAGE16 - 1) & ~(PAGE16 - 1))

static const char *const key_name[S2A_KEY_N] = {"K18", "KTLS", "KTLR", "KGATE"};

static int fail(char *err, size_t n, int error, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    if (err && n) vsnprintf(err, n, fmt, ap);
    va_end(ap);
    return error;
}

static int slurp(const char *path, uint8_t **out, size_t *size, char *err, size_t n);

int s2a_module_layout(const char *path, struct s2a_module_layout *l, char *err, size_t n) {
    uint8_t *text; size_t len;
    int e = slurp(path, &text, &len, err, n);
    if (e) return e;
    e = s2a_module_layout_mem((const char *)text, len, path, l, err, n);
    free(text);
    return e;
}

int s2a_module_layout_mem(const char *text, size_t len, const char *what, struct s2a_module_layout *l, char *err, size_t n) {
    const char *path = what;
    if (!l || !text || !len) return fail(err, n, EINVAL, "%s: empty fixups", what);
    memset(l, 0, sizeof *l);
    char line[256], key[32];
    unsigned seen = 0, target = 0, abi = 0;
    int has_data_off = 0;
#if defined(__OHOS__)
    unsigned tsdoff = 0, fps_abi = 0, fps_sha = 0, code_sha = 0;
#endif
    for (size_t at = 0; at < len;) {
        size_t end = at;
        while (end < len && text[end] != '\n') end++;
        size_t line_len = end - at;
        if (line_len >= sizeof line || memchr(text + at, 0, line_len))
            return fail(err, n, EINVAL, "%s: malformed fixups line", path);
        memcpy(line, text + at, line_len); line[line_len] = 0;
        at = end < len ? end + 1 : end;
        if (strncmp(line, "# ", 2)) return fail(err, n, EINVAL, "%s: non-header fixups row", path);
        char *tab = strchr(line, '\t');
        if (!tab || sscanf(line, "# %31s", key) != 1) return fail(err, n, EINVAL, "%s: malformed fixups header", path);
        const char *v = tab + 1;
        if (!strcmp(key, "TARGET")) {
            if (target++ || strcspn(v, "\r\n") != sizeof(S2A_MODULE_TARGET) - 1 || memcmp(v, S2A_MODULE_TARGET, sizeof(S2A_MODULE_TARGET) - 1))
                return fail(err, n, ENOEXEC, "%s: expected one TARGET " S2A_MODULE_TARGET, path);
            continue;
        }
        if (!strcmp(key, "REWRITE_ABI")) {
            static const char expected[] = S2A_MODULE_ABI;
            if (abi++ || strcspn(v, "\r\n") != sizeof expected - 1 || memcmp(v, expected, sizeof expected - 1))
                return fail(err, n, ENOEXEC, "%s: expected one REWRITE_ABI " S2A_MODULE_ABI, path);
            continue;
        }
        if (!strcmp(key, "BUILD_ID") || !strcmp(key, "TRAP")) continue;   // TRAP 行（brk 兜底点）由 runtime/src/loader.c 读
#if defined(__OHOS__)
        // Enhancement headers are authenticated with the signed carrier's
        // complete fixups bytes. They are strings, not layout integers.
        if (!strcmp(key, "FPS_ABI")) {
            static const char expected_fps[] = "s2a.ohos.fps.v1";
            if (fps_abi++ || strcspn(v, "\r\n") != sizeof expected_fps - 1 ||
                memcmp(v, expected_fps, sizeof expected_fps - 1))
                return fail(err, n, ENOEXEC, "%s: invalid or duplicate FPS_ABI", path);
            continue;
        }
        if (!strcmp(key, "FPS_SHA256") || !strcmp(key, "CODE_PATCH_SHA256")) {
            unsigned *seen_digest = !strcmp(key, "FPS_SHA256") ? &fps_sha : &code_sha;
            if ((*seen_digest)++ || strcspn(v, "\r\n") != 64)
                return fail(err, n, EINVAL, "%s: invalid or duplicate digest %s", path, key);
            for (unsigned i = 0; i < 64; ++i)
                if (!((v[i] >= '0' && v[i] <= '9') || (v[i] >= 'a' && v[i] <= 'f')))
                    return fail(err, n, EINVAL, "%s: invalid digest %s", path, key);
            continue;
        }
#endif
        char *value_end;
        errno = 0;
        if (!strcmp(key, "PATCH_OFF") || !strcmp(key, "PATCH2_OFF")) (void)strtoll(v, &value_end, 16);
        else (void)strtoull(v, &value_end, !strncmp(key, "KEY_", 4) && strstr(key, "_IDX") ? 10 : 16);
        if (errno || value_end == v || (*value_end && strcmp(value_end, "\r")))
            return fail(err, n, EINVAL, "%s: invalid numeric header %s", path, key);
#if defined(__OHOS__)
        if (!strcmp(key, "KEY_TSDOFF_IDX")) {
            if (tsdoff++ || strtoul(v, NULL, 10) != S2A_OHOS_TSDOFF_IDX)
                return fail(err, n, ENOEXEC, "%s: expected one KEY_TSDOFF_IDX 4", path);
            continue;
        }
#endif
        if (!strcmp(key, "LOAD_BIAS")) {
            if (strtoull(v, NULL, 16)) return fail(err, n, ENOEXEC, "%s: Android mapper does not support nonzero LOAD_BIAS", path);
        }
        else if (!strcmp(key, "PATCH_OFF")) l->patch_off = strtoll(v, NULL, 16);
        else if (!strcmp(key, "PATCH2_OFF")) l->patch2_off = strtoll(v, NULL, 16);
        else if (!strcmp(key, "PATCH2_LEN")) l->patch2_len = strtoull(v, NULL, 16);
        else if (!strcmp(key, "IMAGE_SIZE")) l->image_size = strtoull(v, NULL, 16);
        else if (!strcmp(key, "FILE_IMAGE_LEN")) l->file_image_len = strtoull(v, NULL, 16);
        else if (!strcmp(key, "KEY_PAGE_OFF")) l->key_page_off = strtoull(v, NULL, 16);
        else if (!strcmp(key, "KEY_PAGE_SIZE")) l->key_page_size = strtoull(v, NULL, 16);
        else if (!strcmp(key, "TEXT_END")) l->text_end = strtoull(v, NULL, 16);
        else if (!strcmp(key, "DATA_OFF")) { l->data_off = strtoull(v, NULL, 16); has_data_off = 1; }
        else for (unsigned k = 0; k < S2A_KEY_N; k++) {
            char want[32];
            snprintf(want, sizeof want, "KEY_%s_IDX", key_name[k]);
            if (!strcmp(key, want)) {
                unsigned long index = strtoul(v, NULL, 10);
                if ((seen & (1u << k)) || index >= PAGE16 / 8
#if defined(__OHOS__)
                    || index == S2A_OHOS_TSDOFF_IDX
#endif
                )
                    return fail(err, n, EINVAL, "%s: duplicate or invalid key index", path);
                l->key_idx[k] = (unsigned)index; seen |= 1u << k;
            }
        }
    }
    if (!target || !abi)
        return fail(err, n, ENOEXEC, "%s: missing " S2A_MODULE_TARGET " target or rewrite ABI", path);
#if defined(__OHOS__)
    if (!tsdoff) return fail(err, n, ENOEXEC, "%s: missing KEY_TSDOFF_IDX", path);
    if (fps_abi != fps_sha) return fail(err, n, ENOEXEC, "%s: incomplete FPS ABI/digest binding", path);
#endif
    if (!l->patch_off || l->patch_off == INT64_MIN || l->key_page_off > SIZE_MAX - PAGE16 || l->key_page_off % PAGE16 || l->key_page_size != PAGE16 || seen != (1u << S2A_KEY_N) - 1
        || !l->text_end || l->text_end > l->key_page_off || !has_data_off || l->data_off < l->text_end)
        return fail(err, n, EINVAL, "%s: incomplete header (PATCH_OFF / key page / four keys / TEXT_END / DATA_OFF)", path);
    for (unsigned k = 0; k < S2A_KEY_N; k++)
        for (unsigned j = 0; j < k; j++) if (l->key_idx[k] == l->key_idx[j])
            return fail(err, n, EINVAL, "%s: key indices overlap", path);
    if (l->patch_off < 0 && (!l->image_size || !l->file_image_len || l->file_image_len % PAGE16
        || l->patch_off % (int64_t)PAGE16 || l->key_page_off + PAGE16 > l->image_size || l->file_image_len > l->image_size))
        return fail(err, n, EINVAL, "%s: patch area before the base but IMAGE_SIZE / FILE_IMAGE_LEN missing or wrong", path);
    if (l->patch_off > 0 && ((uint64_t)l->patch_off < l->key_page_off + PAGE16))
        return fail(err, n, EINVAL, "%s: patch area overlaps the key page", path);
    // Dual patch islands: the second island sits on the other side of the base
    // (before it for the near layout, after the key page for FAR), page aligned.
    if (l->patch2_off && ((l->patch2_off < 0) == (l->patch_off < 0) || l->patch2_off == INT64_MIN || l->patch2_off % (int64_t)PAGE16
                          || l->patch2_len % 4 || l->patch2_len > SIZE_MAX - PAGE16
                          || (l->patch2_off > 0 && (uint64_t)l->patch2_off < l->image_size)))
        return fail(err, n, EINVAL, "%s: PATCH2_OFF / PATCH2_LEN invalid", path);
    if (!l->patch2_off && l->patch2_len) return fail(err, n, EINVAL, "%s: PATCH2_LEN without PATCH2_OFF", path);
    return 0;
}

static int slurp(const char *path, uint8_t **out, size_t *size, char *err, size_t n) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return fail(err, n, errno, "cannot open %s", path);
    struct stat st;
    if (fstat(fd, &st) || st.st_size <= 0) { int e = errno ? errno : EINVAL; close(fd); return fail(err, n, e, "cannot size %s", path); }
    uint8_t *p = malloc((size_t)st.st_size);
    size_t got = 0;
    while (p && got < (size_t)st.st_size) {
        ssize_t r = read(fd, p + got, (size_t)st.st_size - got);
        if (r <= 0) break;
        got += (size_t)r;
    }
    close(fd);
    if (!p || got != (size_t)st.st_size) { free(p); return fail(err, n, EIO, "short read of %s", path); }
    *out = p; *size = got;
    return 0;
}

// Code pages: copy is done, so publish it to the instruction side, then drop write.
static int seal_rx(uint8_t *a, size_t len, const char *what, char *err, size_t n) {
    __builtin___clear_cache((char *)a, (char *)a + len);
    if (mprotect(a, len, PROT_READ | PROT_EXEC)) return fail(err, n, errno, "mprotect %s R|X", what);
    return 0;
}

int s2a_module_map(const char *dir, const char *name, const uint64_t slot_off[S2A_KEY_N],
                   struct s2a_module *m, char *err, size_t n) {
    memset(m, 0, sizeof *m);
    char fixups_path[1024], image_path[1024];
    snprintf(fixups_path, sizeof fixups_path, "%s/%s.fixups.tsv", dir, name);
    snprintf(image_path, sizeof image_path, "%s/%s.patched.bin", dir, name);
    uint8_t *fixups, *image; size_t fixups_len, image_len;
    int e = slurp(fixups_path, &fixups, &fixups_len, err, n);
    if (e) return e;
    // The header decides first (another target is refused before its image is read).
    if ((e = s2a_module_layout_mem((const char *)fixups, fixups_len, fixups_path, &m->l, err, n))
        || (e = slurp(image_path, &image, &image_len, err, n))) { free(fixups); return e; }
    e = s2a_module_map_mem(image_path, (const char *)fixups, fixups_len, image, image_len, slot_off, m, err, n);
    free(fixups);
    free(image);
    return e;
}

int s2a_module_map_mem(const char *what, const char *fixups, size_t fixups_len, const uint8_t *raw, size_t sz,
                       const uint64_t slot_off[S2A_KEY_N], struct s2a_module *m, char *err, size_t n) {
    const char *path = what;
    memset(m, 0, sizeof *m);
    for (unsigned k = 0; k < S2A_KEY_N; k++)
        if (!slot_off[k]) return fail(err, n, EINVAL, "slot offset for %s is 0", key_name[k]);
    int e = s2a_module_layout_mem(fixups, fixups_len, what, &m->l, err, n);
    if (e) return e;
    if (!raw || !sz || sz > SIZE_MAX - (PAGE16 - 1)) return fail(err, n, EINVAL, "%s: invalid image size", path);
#if defined(__OHOS__)
    return s2a_ohos_signed_module_map(what, fixups, fixups_len, raw, sz, slot_off, m, err, n);
#else
    const struct s2a_module_layout *l = &m->l;
    // Dual patch islands: the last PATCH2_LEN bytes of the file are the second island.
    uint64_t l2 = l->patch2_len, up2 = UP16(l2);
    if (sz < l2) return fail(err, n, EINVAL, "%s shorter than PATCH2_LEN", path);
    const size_t sz_all = sz;
    sz -= l2;
    uint64_t pre = 0, patch_len = 0, size, span;
    if (l->patch_off < 0) {   // file = text + ro + data, then the patch area mapped before the base
        pre = (uint64_t)-l->patch_off;
        if (sz < l->file_image_len) return fail(err, n, EINVAL, "%s shorter than FILE_IMAGE_LEN", path);
        patch_len = UP16(sz - l->file_image_len);
        if ((!patch_len && !l2) || patch_len > pre) return fail(err, n, EINVAL, "%s: patch area does not fit before the base", path);
        size = l->image_size;
        span = l->patch2_off > 0 ? (uint64_t)l->patch2_off + up2 : size;   // FAR dual: up to the end of the island after the key page
    } else {
        size = UP16(sz);
        if (l->patch2_off < 0) {   // near dual: the front island lies FRONT bytes before the base
            pre = (uint64_t)-l->patch2_off;
            if (up2 > pre) return fail(err, n, EINVAL, "%s: front island does not fit before the base", path);
        }
        span = size;
        if (l->key_page_off + PAGE16 > size || (uint64_t)l->patch_off >= size)
            return fail(err, n, EINVAL, "%s: key page or patch area outside the file", path);
    }
    if (span > SIZE_MAX - pre) return fail(err, n, EOVERFLOW, "%s: mapping size overflow", path);
    if (l->data_off > size) return fail(err, n, EINVAL, "%s: DATA_OFF outside image", path);
    // Reserve the complete contiguous image privately. Only writable data/bss
    // backing is remapped shared, excluding the text, key and patch pages.
    // Replacing mappings is safe here: this range was just reserved by us and
    // no bytes, pointers or executable pages have been published yet.
    uint8_t *a = mmap(NULL, pre + span, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (a == MAP_FAILED) { e = errno; return fail(err, n, e, "mmap %#llx bytes", (unsigned long long)(pre + span)); }
    m->map = a; m->map_size = pre + span; m->base = a + pre;
    uint64_t shared_lo = l->data_off & ~(PAGE16 - 1);
    uint64_t text_end = UP16(l->text_end);
    if (shared_lo < text_end) shared_lo = text_end;
    uint64_t shared_hi = l->patch_off < 0 ? size : (uint64_t)l->patch_off & ~(PAGE16 - 1);
    uint64_t key_end = l->key_page_off + PAGE16;
    uint64_t parts[4] = {shared_lo, l->key_page_off < shared_hi ? l->key_page_off : shared_hi,
                         key_end > shared_lo ? key_end : shared_lo, shared_hi};
    for (int i = 0; i < 4; i += 2) {
        if (parts[i] >= parts[i + 1]) continue;
        size_t length = (size_t)(parts[i + 1] - parts[i]);
        void *segment = mmap(m->base + parts[i], length, PROT_READ | PROT_WRITE,
                             MAP_SHARED | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
        if (segment == MAP_FAILED) {
            e = errno; s2a_module_unmap(m);
            return fail(err, n, e, "%s: mmap shared data/bss", path);
        }
    }
    const int far = l->patch_off < 0;
    m->patch_size = far ? patch_len : size - ((uint64_t)l->patch_off & ~(PAGE16 - 1));
    m->patch2_size = l2;
    if (far) { memcpy(m->base, raw, l->file_image_len); memcpy(a, raw + l->file_image_len, sz - l->file_image_len); }
    else memcpy(m->base, raw, sz);
    if (l2) memcpy(m->base + l->patch2_off, raw + sz, sz_all - sz);
    uint64_t *page = (uint64_t *)(m->base + l->key_page_off);
    memset(page, 0, PAGE16);
    for (unsigned k = 0; k < S2A_KEY_N; k++) page[l->key_idx[k]] = slot_off[k];
#if defined(__OHOS__)
    int64_t tsd_offset;
    e = s2a_ohos_tsd_pointer_offset(&tsd_offset);
    if (e) { s2a_module_unmap(m); return fail(err, n, e, "OHOS TSD probe is not ready"); }
    page[S2A_OHOS_TSDOFF_IDX] = (uint64_t)tsd_offset;
#endif
    if (mprotect(page, PAGE16, PROT_READ)) e = fail(err, n, errno, "mprotect key page");
    if (!e) e = seal_rx(m->base, UP16(l->text_end), "text", err, n);
    if (!e && far) {
        if (patch_len) e = seal_rx(a, patch_len, "patch area", err, n);
        if (!e && pre > patch_len && mprotect(a + patch_len, pre - patch_len, PROT_NONE)) e = fail(err, n, errno, "mprotect gap");
    } else if (!e) {
        uint64_t po = (uint64_t)l->patch_off & ~(PAGE16 - 1);
        e = seal_rx(m->base + po, size - po, "patch area", err, n);
    }
    if (!e && l->patch2_off) {   // second island R|X; the rest of its reserved side stays inaccessible
        uint8_t *i2 = m->base + l->patch2_off;
        if (up2) e = seal_rx(i2, up2, "patch island 2", err, n);
        if (!e && l->patch2_off < 0 && pre > up2 && mprotect(a + up2, pre - up2, PROT_NONE)) e = fail(err, n, errno, "mprotect gap2");
        if (!e && l->patch2_off > 0 && (uint64_t)l->patch2_off > size && mprotect(m->base + size, (uint64_t)l->patch2_off - size, PROT_NONE))
            e = fail(err, n, errno, "mprotect gap2");
    }
    if (e) s2a_module_unmap(m);
    return e;
#endif
}

int s2a_module_map_path(const char *image, const uint64_t slot_off[S2A_KEY_N],
                        struct s2a_module *m, char *err, size_t n) {
    if (!image || !*image) return fail(err, n, EINVAL, "empty module image path");
    const char *file = strrchr(image, '/');
    file = file ? file + 1 : image;
    static const char suffix[] = ".patched.bin";
    const size_t flen = strlen(file), slen = sizeof suffix - 1;
    if (flen <= slen || strcmp(file + flen - slen, suffix))
        return fail(err, n, EINVAL, "%s is not a *.patched.bin image", image);
    char dir[4096], name[4096];
    if (file == image) {
        snprintf(dir, sizeof dir, ".");
    } else {
        const size_t dlen = (size_t)(file - image - 1);
        if (dlen >= sizeof dir) return fail(err, n, ENAMETOOLONG, "module directory is too long");
        memcpy(dir, image, dlen);
        dir[dlen] = 0;
    }
    const size_t nlen = flen - slen;
    if (nlen >= sizeof name) return fail(err, n, ENAMETOOLONG, "module name is too long");
    memcpy(name, file, nlen);
    name[nlen] = 0;
    return s2a_module_map(dir, name, slot_off, m, err, n);
}

void s2a_module_unmap(struct s2a_module *m) {
#if defined(__OHOS__)
    if (m->platform_owner) { dlclose(m->platform_owner); m->platform_owner = NULL; }
    else if (m->map) munmap(m->map, m->map_size);
#else
    if (m->map) munmap(m->map, m->map_size);
#endif
    m->map = m->base = NULL; m->map_size = m->patch_size = 0;
}
