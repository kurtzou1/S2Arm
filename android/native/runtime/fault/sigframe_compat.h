// Signal-frame records newer than some libc kernel headers (Ubuntu 24.04 lacks FPMR / POE).
// Layouts are the Linux arm64 UAPI ones (arch/arm64/include/uapi/asm/sigcontext.h). Include after <asm/sigcontext.h>.
#pragma once
#include <asm/sigcontext.h>
#ifndef FPMR_MAGIC
#define FPMR_MAGIC 0x46504d52
struct fpmr_context { struct _aarch64_ctx head; __u64 fpmr; };
#endif
#ifndef POE_MAGIC
#define POE_MAGIC 0x504f4530
struct poe_context { struct _aarch64_ctx head; __u64 por_el0; };
#endif
#ifndef SVE_SIG_FLAG_SM
#define SVE_SIG_FLAG_SM 0x1
#endif
