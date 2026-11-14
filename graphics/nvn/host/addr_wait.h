// Sleep on / wake a 64-bit word (Apple os_sync_wait_on_address, macOS 14.4 / iOS 17.4): the kernel compares the word before sleeping, so a change made before the sleep is
// not lost. The shared direct layer reaches the Apple call only through here (layer rule R-02: shared files do not include Apple system headers). Used by nvn_rec.h ubc_*. Kept out of graphics/metal/: files there are libnxgal sources, part of the translation cache key.
#pragma once
#include <stdint.h>
#include <os/os_sync_wait_on_address.h>

// Returns at once if *w is no longer v; spurious returns and EINTR are the caller's loop
static inline void addr_wait64(void *w, uint64_t v) { os_sync_wait_on_address(w, v, sizeof(uint64_t), OS_SYNC_WAIT_ON_ADDRESS_NONE); }
static inline void addr_wake_one64(void *w) { os_sync_wake_by_address_any(w, sizeof(uint64_t), OS_SYNC_WAKE_BY_ADDRESS_NONE); }
static inline void addr_wake_all64(void *w) { os_sync_wake_by_address_all(w, sizeof(uint64_t), OS_SYNC_WAKE_BY_ADDRESS_NONE); }
