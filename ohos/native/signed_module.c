// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// HAP-signed code is mapped only by the system ELF loader. This module never
// allocates executable memory, copies code to anonymous pages, or rewrites RX.
#define _GNU_SOURCE 1
#include "signed_module.h"
#include "tsd_ohos.h"
#include <dlfcn.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <link.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define PAGE16 UINT64_C(0x4000)
#define MAGIC UINT64_C(0x5332415349473031)
#define CARRIER_LIMIT 64
_Static_assert(sizeof(struct s2a_ohos_signed_descriptor) == 80, "signed descriptor ABI");

// A consumed carrier is never reset, including after a late initialization
// failure or a caller's pre-adoption dlclose. The runtime is process-scoped.
static pthread_mutex_t carrier_lock = PTHREAD_MUTEX_INITIALIZER;
static char consumed[CARRIER_LIMIT][33];
static size_t consumed_count;

static int fail(char *err, size_t cap, int error, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    if (err && cap) vsnprintf(err, cap, fmt, ap);
    va_end(ap);
    return error;
}

static int build_id(const char *text, size_t length, char id[33], char *err, size_t cap) {
    unsigned seen = 0;
    for (size_t at = 0; at < length;) {
        size_t end = at;
        while (end < length && text[end] != '\n') end++;
        size_t n = end - at;
        if (n && text[at + n - 1] == '\r') n--;
        if (n >= 256 || memchr(text + at, 0, n)) return fail(err, cap, EINVAL, "invalid fixups line");
        char line[256], key[32];
        memcpy(line, text + at, n); line[n] = 0;
        if (sscanf(line, "# %31s", key) == 1 && !strcmp(key, "BUILD_ID")) {
            if (seen++ || n != 43 || memcmp(line, "# BUILD_ID\t", 11))
                return fail(err, cap, ENOEXEC, "expected one 32-hex BUILD_ID");
            for (unsigned i = 0; i < 32; i++) {
                char c = line[11 + i];
                if (c >= 'A' && c <= 'F') c = (char)(c - 'A' + 'a');
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
                    return fail(err, cap, ENOEXEC, "BUILD_ID is not hexadecimal");
                id[i] = c;
            }
            id[32] = 0;
        }
        at = end < length ? end + 1 : end;
    }
    return seen == 1 ? 0 : fail(err, cap, ENOEXEC, "missing BUILD_ID");
}

struct loaded_image {
    uintptr_t bias;
    const ElfW(Phdr) *phdr;
    size_t count;
};

static int find_loaded(struct dl_phdr_info *info, size_t size, void *context) {
    (void)size;
    struct loaded_image *out = context;
    if ((uintptr_t)info->dlpi_addr != out->bias) return 0;
    out->phdr = info->dlpi_phdr; out->count = info->dlpi_phnum;
    return 1;
}

static int segment_bounds(const struct loaded_image *image, const ElfW(Phdr) *p,
                          uintptr_t *lo, uintptr_t *hi) {
    if (p->p_vaddr > UINTPTR_MAX - image->bias) return 0;
    *lo = image->bias + (uintptr_t)p->p_vaddr;
    if (p->p_memsz > UINTPTR_MAX - *lo) return 0;
    *hi = *lo + (uintptr_t)p->p_memsz;
    return 1;
}

// Return the unique matching LOAD. Zero-sized gates are a valid exported label
// inside the read-only metadata segment; their file must also be empty.
static const ElfW(Phdr) *range(const struct loaded_image *image, const void *address,
                              uint64_t length, unsigned flags, int exact) {
    uintptr_t a = (uintptr_t)address;
    if (length > UINTPTR_MAX - a) return NULL;
    const ElfW(Phdr) *found = NULL;
    for (size_t i = 0; i < image->count; i++) {
        const ElfW(Phdr) *p = &image->phdr[i]; uintptr_t lo, hi;
        if (p->p_type != PT_LOAD || !segment_bounds(image, p, &lo, &hi)) continue;
        if (a >= lo && a + length <= hi && (length || a < hi)) {
            if (p->p_flags != flags || found || (exact && (a != lo || a + length != hi))) return NULL;
            found = p;
        }
    }
    return found;
}

static int validate_loads(const struct loaded_image *image, char *err, size_t cap) {
    if (!image->phdr || !image->count || image->count > 64)
        return fail(err, cap, ENOEXEC, "carrier program headers unavailable");
    unsigned loads = 0;
    for (size_t i = 0; i < image->count; i++) {
        const ElfW(Phdr) *p = &image->phdr[i]; uintptr_t lo, hi;
        if (p->p_type == PT_GNU_STACK && (p->p_flags & PF_X))
            return fail(err, cap, ENOEXEC, "carrier requests executable stack");
        if (p->p_type != PT_LOAD) continue;
        loads++;
        if (!segment_bounds(image, p, &lo, &hi) || !p->p_memsz || p->p_filesz > p->p_memsz ||
            p->p_align != PAGE16 || (p->p_vaddr & (PAGE16 - 1)) != (p->p_offset & (PAGE16 - 1)) ||
            (p->p_flags & (PF_W | PF_X)) == (PF_W | PF_X))
            return fail(err, cap, ENOEXEC, "invalid carrier LOAD bounds, alignment or permissions");
        for (size_t j = 0; j < i; j++) {
            const ElfW(Phdr) *q = &image->phdr[j]; uintptr_t qlo, qhi;
            if (q->p_type == PT_LOAD && segment_bounds(image, q, &qlo, &qhi) && lo < qhi && qlo < hi)
                return fail(err, cap, ENOEXEC, "overlapping carrier LOAD ranges");
        }
    }
    if (loads != 4) return fail(err, cap, ENOEXEC, "expected metadata plus three guest LOADs");
    return 0;
}

static int zero_bytes(const uint8_t *bytes, size_t length) {
    static const uint8_t zeros[4096];
    while (length) {
        size_t count = length < sizeof zeros ? length : sizeof zeros;
        if (memcmp(bytes, zeros, count)) return 0;
        bytes += count; length -= count;
    }
    return 1;
}

static int match_gates(const char *path, const uint8_t *expected, size_t length, char *err, size_t cap) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return fail(err, cap, errno, "cannot open gates sidecar");
    int result = 0; struct stat st;
    if (fstat(fd, &st)) result = fail(err, cap, errno, "cannot stat gates sidecar");
    else if (!S_ISREG(st.st_mode) || st.st_size < 0 || (uint64_t)st.st_size != length)
        result = fail(err, cap, ENOEXEC, "gates sidecar size differs from signed metadata");
    uint8_t buf[16384]; size_t at = 0;
    while (!result && at < length) {
        size_t want = length - at; if (want > sizeof buf) want = sizeof buf;
        ssize_t n = read(fd, buf, want);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { result = fail(err, cap, n < 0 ? errno : EIO, "short gates sidecar read"); break; }
        if (memcmp(buf, expected + at, (size_t)n)) { result = fail(err, cap, ENOEXEC, "gates sidecar bytes differ from signed metadata"); break; }
        at += (size_t)n;
    }
    if (!result) {
        ssize_t n; do { n = read(fd, buf, 1); } while (n < 0 && errno == EINTR);
        if (n != 0) result = fail(err, cap, n < 0 ? errno : ENOEXEC, "gates sidecar changed while reading");
    }
    close(fd);
    return result;
}

int s2a_ohos_signed_module_map(const char *what, const char *fixups, size_t fixups_len,
    const uint8_t *raw, size_t raw_len, const uint64_t slot_off[S2A_KEY_N],
    struct s2a_module *m, char *err, size_t cap) {
    if (!what || !fixups || !fixups_len || !raw || !raw_len || !slot_off || !m)
        return fail(err, cap, EINVAL, "missing signed module input");
    if (m->map || m->base || m->platform_owner)
        return fail(err, cap, EALREADY, "module already owns a mapping");
    const struct s2a_module_layout *l = &m->l;
    if (!l->text_end || l->text_end > UINT64_MAX - (PAGE16 - 1) || raw_len > SIZE_MAX - (PAGE16 - 1))
        return fail(err, cap, EINVAL, "signed image size overflow");
    uint64_t x0 = (l->text_end + PAGE16 - 1) & ~(PAGE16 - 1);
    int far = l->patch_off < 0;
    uint64_t pre = 0, file_size = raw_len, image_size = ((uint64_t)raw_len + PAGE16 - 1) & ~(PAGE16 - 1);
    uint64_t patch_size, patch_bytes;
    if (!l->patch_off || l->patch_off == INT64_MIN || l->patch_off % (int64_t)PAGE16 || l->key_page_size != PAGE16 ||
        l->key_page_off % PAGE16 || l->key_page_off < x0 || l->key_page_off > UINT64_MAX - PAGE16 ||
        l->key_page_off + PAGE16 > SIZE_MAX)
        return fail(err, cap, ENOEXEC, "invalid signed image boundaries");
    if (far) {
        pre = (uint64_t)-l->patch_off;
        file_size = l->file_image_len; image_size = l->image_size;
        if (!file_size || file_size % PAGE16 || file_size < x0 || file_size > l->key_page_off ||
            image_size != l->key_page_off + PAGE16 || file_size >= raw_len || image_size > SIZE_MAX - pre)
            return fail(err, cap, ENOEXEC, "invalid signed FAR file or BSS boundaries");
        patch_bytes = raw_len - file_size;
        patch_size = (patch_bytes + PAGE16 - 1) & ~(PAGE16 - 1);
        if (patch_size > pre) return fail(err, cap, ENOEXEC, "signed FAR patch exceeds reserved prefix");
    } else {
        if (l->key_page_off + PAGE16 > (uint64_t)l->patch_off || (uint64_t)l->patch_off >= raw_len ||
            l->image_size || l->file_image_len)
            return fail(err, cap, ENOEXEC, "invalid signed near layout");
        patch_bytes = raw_len - (uint64_t)l->patch_off;
        patch_size = image_size - (uint64_t)l->patch_off;
    }
    uint64_t mapped_size = pre + image_size;
    for (unsigned i = 0; i < S2A_KEY_N; i++) {
        if (!slot_off[i] || (slot_off[i] & 7) || l->key_idx[i] >= PAGE16 / 8 || l->key_idx[i] == S2A_OHOS_TSDOFF_IDX)
            return fail(err, cap, EINVAL, "invalid key slot or index");
        for (unsigned j = 0; j < i; j++) if (l->key_idx[i] == l->key_idx[j] || slot_off[i] == slot_off[j])
            return fail(err, cap, EINVAL, "overlapping key slots or indices");
    }
    char id[33], library[64], gates_path[PATH_MAX];
    int error = build_id(fixups, fixups_len, id, err, cap);
    if (error) return error;
    size_t path_len = strnlen(what, sizeof gates_path);
    static const char suffix[] = ".patched.bin";
    if (path_len == sizeof gates_path || path_len <= sizeof suffix - 1 ||
        strcmp(what + path_len - (sizeof suffix - 1), suffix))
        return fail(err, cap, EINVAL, "signed mapper needs an exact .patched.bin path");
    size_t prefix = path_len - (sizeof suffix - 1);
    memcpy(gates_path, what, prefix); memcpy(gates_path + prefix, ".gates.tsv", sizeof ".gates.tsv");
    snprintf(library, sizeof library, "libs2a_guest_%s.so", id);
    int64_t tsd_offset;
    error = s2a_ohos_tsd_pointer_offset(&tsd_offset);
    if (error) return fail(err, cap, error, "OHOS TSD probe is not ready");

    int locked = pthread_mutex_lock(&carrier_lock);
    if (locked) return fail(err, cap, locked, "signed carrier lock failed");
    void *owner = NULL;
    for (size_t i = 0; i < consumed_count; i++) if (!strcmp(consumed[i], id)) {
        error = fail(err, cap, EALREADY, "signed carrier already initialized in this process"); goto done;
    }
    if (consumed_count == CARRIER_LIMIT) { error = fail(err, cap, ENOSPC, "signed carrier registry is full"); goto done; }
    owner = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!owner) { const char *why = dlerror(); error = fail(err, cap, ENOEXEC, "dlopen %s: %s", library, why ? why : "failed"); goto done; }
    uint8_t *image = dlsym(owner, "s2a_guest_image");
    const struct s2a_ohos_signed_descriptor *exported = dlsym(owner, "s2a_guest_descriptor");
    const uint8_t *signed_fixups = dlsym(owner, "s2a_guest_fixups");
    const uint8_t *signed_gates = dlsym(owner, "s2a_guest_gates");
    Dl_info image_info, symbol_info;
    if (!image || !exported || !signed_fixups || !signed_gates || ((uintptr_t)image & (PAGE16 - 1)) ||
        !dladdr(image, &image_info)) { error = fail(err, cap, ENOEXEC, "missing or unaligned signed carrier exports"); goto done; }
    const void *symbols[] = {exported, signed_fixups, signed_gates};
    for (unsigned i = 0; i < sizeof symbols / sizeof symbols[0]; i++)
        if (!dladdr(symbols[i], &symbol_info) || symbol_info.dli_fbase != image_info.dli_fbase) {
            error = fail(err, cap, ENOEXEC, "carrier exports belong to different DSOs"); goto done;
        }
    struct loaded_image loaded = {.bias = (uintptr_t)image_info.dli_fbase};
    dl_iterate_phdr(find_loaded, &loaded);
    if ((error = validate_loads(&loaded, err, cap))) goto done;
    const ElfW(Phdr) *meta = range(&loaded, exported, sizeof *exported, PF_R, 0);
    if (!meta) { error = fail(err, cap, ENOEXEC, "descriptor is outside read-only metadata"); goto done; }
    struct s2a_ohos_signed_descriptor d; memcpy(&d, exported, sizeof d);
    if (d.magic != MAGIC || d.version != (far ? 2u : 1u) || d.raw_size != raw_len || d.mapped_size != mapped_size ||
        d.text_end != l->text_end || d.patch_off != (uint64_t)l->patch_off ||
        d.key_page_off != l->key_page_off || d.key_page_size != PAGE16 || d.fixups_size != fixups_len ||
        d.gates_size > SIZE_MAX || pre > (uintptr_t)image || image_size > UINTPTR_MAX - (uintptr_t)image) {
        error = fail(err, cap, ENOEXEC, "signed descriptor does not match module layout"); goto done;
    }
    uint8_t *mapping = (uint8_t *)((uintptr_t)image - pre);
    uint8_t *patch = far ? mapping : image + l->patch_off;
    uint64_t writable_size = far ? image_size - x0 : (uint64_t)l->patch_off - x0;
    const ElfW(Phdr) *text_load = range(&loaded, image, x0, PF_R | PF_X, 1);
    const ElfW(Phdr) *data_load = range(&loaded, image + x0, writable_size, PF_R | PF_W, 1);
    const ElfW(Phdr) *patch_load = range(&loaded, patch, patch_size, PF_R | PF_X, 1);
    if (range(&loaded, signed_fixups, d.fixups_size, PF_R, 0) != meta ||
        range(&loaded, signed_gates, d.gates_size, PF_R, 0) != meta ||
        !text_load || !data_load || !patch_load || text_load == patch_load ||
        meta->p_filesz != meta->p_memsz || text_load->p_filesz != x0 || patch_load->p_filesz != patch_size ||
        data_load->p_filesz != (far ? file_size - x0 : writable_size)) {
        error = fail(err, cap, ENOEXEC, "signed carrier LOADs do not match text, data/BSS and patch ranges"); goto done;
    }
    // No metadata LOAD may occupy the virtual gap reserved for a FAR module.
    uintptr_t meta_lo, meta_hi;
    if (!segment_bounds(&loaded, meta, &meta_lo, &meta_hi) ||
        (meta_lo < (uintptr_t)image + image_size && (uintptr_t)mapping < meta_hi)) {
        error = fail(err, cap, ENOEXEC, "metadata overlaps the guest reservation"); goto done;
    }
    if (memcmp(signed_fixups, fixups, fixups_len) || memcmp(image, raw, (size_t)file_size) ||
        (far && memcmp(patch, raw + file_size, (size_t)patch_bytes))) {
        error = fail(err, cap, ENOEXEC, "signed image or fixups bytes differ from selected input"); goto done;
    }
    if (!zero_bytes(image + file_size, (size_t)(image_size - file_size)) ||
        (far && !zero_bytes(patch + patch_bytes, (size_t)(patch_size - patch_bytes))) ||
        !zero_bytes(image + l->key_page_off, PAGE16)) {
        error = fail(err, cap, ENOEXEC, "nonzero carrier padding, BSS or key page"); goto done;
    }
    if ((error = match_gates(gates_path, signed_gates, (size_t)d.gates_size, err, cap))) goto done;

    // Reserve the one-shot identity before changing permissions or the key page.
    // The loader owns the full DSO reservation; enforce the original FAR hole
    // semantics without allocating memory or granting execute permission.
    memcpy(consumed[consumed_count++], id, sizeof id);
    if (far && pre > patch_size && mprotect(mapping + patch_size, (size_t)(pre - patch_size), PROT_NONE)) {
        error = fail(err, cap, errno, "mprotect signed FAR gap NONE"); goto done;
    }
    uint64_t *page = (uint64_t *)(image + l->key_page_off);
    memset(page, 0, PAGE16);
    for (unsigned i = 0; i < S2A_KEY_N; i++) page[l->key_idx[i]] = slot_off[i];
    page[S2A_OHOS_TSDOFF_IDX] = (uint64_t)tsd_offset;
    if (mprotect(page, PAGE16, PROT_READ)) { error = fail(err, cap, errno, "mprotect signed key page R"); goto done; }
    m->map = mapping; m->base = image;
    m->map_size = (size_t)mapped_size;
    m->patch_size = (size_t)patch_size;
    m->platform_owner = owner;
    owner = NULL; // Reference transfers to the caller; no unload after adoption.
    error = 0;
done:
    if (owner) dlclose(owner); // No guest registration or instruction occurred.
    pthread_mutex_unlock(&carrier_lock);
    return error;
}
