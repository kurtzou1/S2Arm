// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include "../../android/native/module.h"

#ifdef __cplusplus
extern "C" {
#endif

// Both versions contain ten little-endian uint64_t values. Version 1 is the
// unchanged near layout. Version 2 is FAR: patch_off encodes a signed negative
// offset from s2a_guest_image, and mapped_size is -patch_off + IMAGE_SIZE.
// FILE_IMAGE_LEN/IMAGE_SIZE remain in the byte-matched fixups. The image export
// always names the original text base, never the leading patch mapping.
struct s2a_ohos_signed_descriptor {
    uint64_t magic, version, raw_size, mapped_size, text_end, patch_off;
    uint64_t key_page_off, key_page_size, fixups_size, gates_size;
};

// m->l is already validated by the shared module parser. what is the exact
// *.patched.bin path, used only to find its signed-matched gates.tsv sidecar.
// No guest instruction or initializer runs here. Only the RW key page is written;
// a FAR gap is sealed PROT_NONE without ever requesting executable permission.
// Success transfers the dlopen reference to m->platform_owner; normal adoption
// keeps it until process exit. A carrier can be initialized only once per process.
int s2a_ohos_signed_module_map(const char *what, const char *fixups, size_t fixups_len,
    const uint8_t *raw, size_t raw_len, const uint64_t slot_off[S2A_KEY_N],
    struct s2a_module *m, char *err, size_t cap);

#ifdef __cplusplus
}
#endif
