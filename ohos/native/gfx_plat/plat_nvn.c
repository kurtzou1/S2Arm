// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "nvn_plat.h"
#include "plat_ohos.h"
#include <hilog/log.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

void nvn_plat_log(int level, const char* cls, const char* text) {
  LogLevel priority = level == NVN_PLAT_LOG_RED    ? LOG_ERROR
                      : level == NVN_PLAT_LOG_WARN ? LOG_WARN
                                                   : LOG_INFO;
  const char* red = level == NVN_PLAT_LOG_RED ? "【红】" : "";
  cls = cls ? cls : "";
  text = text ? text : "";
  OH_LOG_Print(LOG_APP, priority, 0x5332, "S2Arm", "%{public}snvk %{public}s: %{public}s", red, cls,
               text);
  fprintf(stderr, "[s2a] %snvk %s: %s\n", red, cls, text);
}

int nvn_plat_flag(const char* name, int dflt) {
  if (!name || !*name)
    return dflt;
  char key[256] = "DEBUG_S2A_";
  size_t prefix = strlen(key), n = strlen(name);
  if (n >= sizeof key - prefix)
    return dflt;
  for (size_t i = 0; i < n; ++i) {
    unsigned char c = (unsigned char)name[i];
    key[prefix + i] = c == '.' ? '_' : c >= 'a' && c <= 'z' ? (char)(c - 'a' + 'A') : (char)c;
  }
  key[prefix + n] = 0;
  const char* value = getenv(key);
  if (!value || !*value)
    return dflt;
  char* end;
  errno = 0;
  long parsed = strtol(value, &end, 10);
  if (errno || *end || parsed < INT_MIN || parsed > INT_MAX)
    return dflt;
  return (int)parsed;
}

// Interned paths satisfy the shared API's process-lifetime pointer contract.
typedef struct Path {
  struct Path* next;
  char text[];
} Path;
static Path* paths;
static const char* dirs[2];
static pthread_mutex_t dir_lock = PTHREAD_MUTEX_INITIALIZER;

static const char* make_dir(const char* root, const char* suffix) {
  if (!root)
    return NULL;
  size_t a = strlen(root), b = strlen(suffix);
  if (!a || a > SIZE_MAX - b - sizeof(Path) - 2)
    return NULL;
  Path* p = malloc(sizeof *p + a + b + 2);
  if (!p)
    return NULL;
  snprintf(p->text, a + b + 2, "%s/%s", root, suffix);
  for (Path* old = paths; old; old = old->next) {
    if (!strcmp(old->text, p->text)) {
      free(p);
      p = NULL;
      struct stat st;
      return !stat(old->text, &st) && S_ISDIR(st.st_mode) ? old->text : NULL;
    }
  }
#ifdef _WIN32
  int rc = mkdir(p->text);
#else
  int rc = mkdir(p->text, 0700);
#endif
  struct stat st;
  if ((rc && errno != EEXIST) || stat(p->text, &st) || !S_ISDIR(st.st_mode)) {
    free(p);
    return NULL;
  }
  p->next = paths;
  paths = p;
  return p->text;
}

int nvn_ohos_set_dirs(const char* state_root, const char* files_root) {
  pthread_mutex_lock(&dir_lock);
  const char* cache = make_dir(state_root, "nvk-cache");
  const char* diag = make_dir(files_root, "diag");
  int ok = (!state_root || cache) && (!files_root || diag);
  if (ok) {
    dirs[NVN_PLAT_DIR_CACHE] = cache;
    dirs[NVN_PLAT_DIR_DIAG] = diag;
  }
  pthread_mutex_unlock(&dir_lock);
  if (!ok)
    nvn_plat_log(NVN_PLAT_LOG_RED, "platform", "cannot create output directories");
  return ok ? 0 : -1;
}

const char* nvn_plat_dir(int which) {
  if (which != NVN_PLAT_DIR_CACHE && which != NVN_PLAT_DIR_DIAG)
    return NULL;
  pthread_mutex_lock(&dir_lock);
  const char* p = dirs[which];
  pthread_mutex_unlock(&dir_lock);
  return p;
}

static _Atomic(void (*)(void)) safepoint;
void nvn_ohos_set_safepoint(void (*fn)(void)) {
  atomic_store_explicit(&safepoint, fn, memory_order_release);
}
void nvn_plat_safepoint(void) {
  void (*fn)(void) = atomic_load_explicit(&safepoint, memory_order_acquire);
  if (fn)
    fn();
}
