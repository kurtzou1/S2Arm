// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Uses the production classifier, loader module registry and ELF segment scan.
// This executable is a bounded device test; no game assets or runtime stubs.
#include "native.h"
#include <dlfcn.h>

static unsigned checks;

static void check(int good, const char *label) {
    if (!good) {
        fprintf(stderr, "FAIL %s\n", label);
        exit(1);
    }
    ++checks;
    printf("PASS %s\n", label);
}

static void *symbol(void *handle, const char *name) {
    dlerror();
    void *result = dlsym(handle, name);
    const char *error = dlerror();
    if (error || !result) {
        fprintf(stderr, "FAIL dlsym %s: %s\n", name, error ? error : "null symbol");
        exit(2);
    }
    return result;
}

static int classify(const void *address) {
    return sw_is_host_code((uint64_t)(uintptr_t)address);
}

__attribute__((noinline)) static int host_function(void) {
    return 29;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <absolute fixture DSO path>\n", argv[0]);
        return 2;
    }
    check(g_nmod == 0, "registry initially empty");
    check(classify((void *)host_function) == 1, "executable host function is host");
    check(classify((void *)puts) == 1, "libc function is host");
    check(classify(&checks) == 0, "executable data is not host code");
    check(classify(NULL) == 0, "null is not host code");
    check(sw_is_host_code(UINT64_MAX) == 0, "maximum address is not host code");

    void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        fprintf(stderr, "FAIL dlopen: %s\n", dlerror());
        return 2;
    }
    uintptr_t begin = (uintptr_t)symbol(handle, "s2a_fixture_begin");
    uintptr_t end = (uintptr_t)symbol(handle, "s2a_fixture_end");
    void *entry = symbol(handle, "s2a_fixture_entry");
    void *patch = symbol(handle, "s2a_fixture_patch");
    void *data = symbol(handle, "s2a_fixture_data");
    void *rodata = symbol(handle, "s2a_fixture_rodata");
    check(end > begin && (uintptr_t)entry == begin &&
          (uintptr_t)patch > begin && (uintptr_t)patch < end,
          "fixture has text and near patch inside bounded image");
    check(((int (*)(void))entry)() == 73 && ((int (*)(void))patch)() == 19,
          "real dynamically loaded fixture code executes");
    check(classify(entry) == 1, "unregistered DSO text is host");
    check(classify(patch) == 1, "unregistered DSO patch is host");
    check(classify(data) == 0 && classify(rodata) == 0,
          "DSO non-executable segments are not host code");
    check(classify((void *)(begin - 1)) == 1 && classify((void *)end) == 1,
          "fixture boundary neighbours remain executable");

    module_t *module = &g_mod[0];
    memset(module, 0, sizeof *module);
    strcpy(module->name, "fixture");
    module->base = (uint8_t *)begin;
    module->size = end - begin;
    module->patch_off = (int64_t)((uintptr_t)patch - begin);
    module->patch_len = end - (uintptr_t)patch;
    g_nmod = 1;
    check(module_of(entry) == module && module_of(patch) == module,
          "actual loader registry owns text and near patch");
    check(classify(entry) == 0, "registered text is guest");
    check(classify(patch) == 0, "registered near patch is guest");
    check(module_of((void *)begin) == module && classify((void *)begin) == 0,
          "module start is inclusive");
    check(module_of((void *)(end - 1)) == module && classify((void *)(end - 1)) == 0,
          "module last byte is inclusive");
    check(module_of((void *)(begin - 1)) == NULL && classify((void *)(begin - 1)) == 1,
          "byte before module remains host");
    check(module_of((void *)end) == NULL && classify((void *)end) == 1,
          "module end is exclusive");
    check(classify((void *)host_function) == 1 && classify((void *)puts) == 1,
          "registration preserves executable and libc host classification");
    check(classify(data) == 0 && classify(rodata) == 0 && classify(&checks) == 0,
          "registration does not turn non-code into host code");

    // A filled slot beyond g_nmod must not classify an unrelated host address.
    g_mod[1].base = (uint8_t *)(uintptr_t)host_function;
    g_mod[1].size = 1;
    check(module_of((void *)host_function) == NULL && classify((void *)host_function) == 1,
          "only published module slots affect classification");
    memset(&g_mod[1], 0, sizeof g_mod[1]);
    module->size = 0;
    check(module_of(entry) == NULL && classify(entry) == 1,
          "empty near image owns no code");
    module->size = end - begin;
    g_nmod = 0;
    check(module_of(entry) == NULL && classify(entry) == 1,
          "unregistration restores normal ELF classification");
    memset(module, 0, sizeof *module);
    check(dlclose(handle) == 0, "fixture closes after registry retirement");
    printf("PASS guest classifier: %u checks; actual xstack + module_of + dlopen ELF\n", checks);
    return 0;
}
