// 着色器补料（11-15 维护者定：从回收的诊断包补抽取能力，不靠我们自己有这款游戏）：玩家局里遇到库里没有 / 现编失败的着色器，
//   把补救所需的最小材料存进 <文档根>/wire/<程序号>/shader_miss/：<键>.ctl（控制段）+ <键>.code（代码区）+ index.tsv（每键一行）。
//   诊断包原样带走（pack/jobs/library.py、ios/diag.m 收 shader_miss/），取件按程序号归档进管线种子目录的 rt_shaders/，
//   出包时 graphics/tools/direct/direct_lib.sh 经 translator/rt_dump_merge.py 编进那款的直连库（同 DM_NVN_SHDUMP 转储件的格式与去处）。
//   按键去重：同一键一局只计一次「出现次数」，跨局累加；每款总量上限 S2A_SHADER_SALVAGE_MB（缺省 8 MB，诊断包整包压缩后 ≤ 30 MB），
//   超了先淘汰出现次数最少、其中最早的（本局见过的不淘汰）；放不下就不存、只计数。不进玩家日常日志：收局汇总一行。
//   位置：S2A_SHADER_SALVAGE=<目录> 指定；否则跟兜底现编目录（DM_MSL_FALLBACK = <…>/wire/<号>/shaders）同级的 shader_miss；都没有就不存
//   kind 位：1 不在映射表（库里没有），2 现编失败，4 管线建不起来，8 补齐变体做不了
enum { DSV_NOMAP = 1, DSV_COMPFAIL = 2, DSV_PSOFAIL = 4, DSV_VPADFAIL = 8 };
typedef struct { char key[17]; int st; unsigned kinds, count; uint32_t nctl, ncode; char build[17]; char why[160]; uint8_t run, isnew; } dsv_ent;
static struct { pthread_mutex_t mu; int init, off; char dir[1100]; size_t cap, bytes; dsv_ent *e; size_t n, nalloc; uint64_t new_run, dropped, kinds_run[4]; } g_dsv = { .mu = PTHREAD_MUTEX_INITIALIZER };
static void dsv_tsv_clean(char *s) { for (; *s; s++) if (*s == '\t' || *s == '\n' || *s == '\r') *s = ' '; }
static void dsv_load(void) {   // 调用方持锁
    g_dsv.init = 1;
    const char *d = getenv("S2A_SHADER_SALVAGE");
    if (d && *d) snprintf(g_dsv.dir, sizeof g_dsv.dir, "%s", d);
    else { const char *fb = getenv("DM_MSL_FALLBACK"); size_t n = fb ? strlen(fb) : 0;
        if (n > 8 && !strcmp(fb + n - 8, "/shaders")) snprintf(g_dsv.dir, sizeof g_dsv.dir, "%.*s/shader_miss", (int)(n - 8), fb); else { g_dsv.off = 1; return; } }
    const char *mb = getenv("S2A_SHADER_SALVAGE_MB"); long m = mb && *mb ? atol(mb) : 8; if (m <= 0) { g_dsv.off = 1; return; }
    g_dsv.cap = (size_t)m << 20;
    char p[1200]; snprintf(p, sizeof p, "%s/index.tsv", g_dsv.dir); FILE *f = fopen(p, "r"); if (!f) return;
    char ln[512];
    while (fgets(ln, sizeof ln, f)) {
        if (ln[0] == '#') continue;
        dsv_ent x; memset(&x, 0, sizeof x); char kd[8] = "", bd[17] = "";
        int got = sscanf(ln, "%16[0-9a-f]\t%d\t%7[0-9]\t%u\t%u\t%u\t%16[0-9a-fA-F-]", x.key, &x.st, kd, &x.count, &x.nctl, &x.ncode, bd);
        if (got < 6 || strlen(x.key) != 16) continue;
        x.kinds = (unsigned)atoi(kd); snprintf(x.build, sizeof x.build, "%s", strcmp(bd, "-") ? bd : "");
        char *w = ln; for (int t = 0; t < 7 && w; t++) { w = strchr(w, '\t'); if (w) w++; }
        if (w) { snprintf(x.why, sizeof x.why, "%s", w); x.why[strcspn(x.why, "\n")] = 0; if (!strcmp(x.why, "-")) x.why[0] = 0; }
        if (g_dsv.n == g_dsv.nalloc) { size_t na = g_dsv.nalloc ? g_dsv.nalloc * 2 : 256; dsv_ent *ne = realloc(g_dsv.e, na * sizeof *ne); if (!ne) break; g_dsv.e = ne; g_dsv.nalloc = na; }
        g_dsv.e[g_dsv.n++] = x; g_dsv.bytes += (size_t)x.nctl + x.ncode;
    }
    fclose(f);
}
static void dsv_write_index(void) {   // 调用方持锁；整份重写（临时文件 + 改名，取件 / 诊断导出读到的总是完整一份）
    char p[1200], t[1200]; snprintf(p, sizeof p, "%s/index.tsv", g_dsv.dir); snprintf(t, sizeof t, "%s/.index.tsv.tmp", g_dsv.dir);
    FILE *f = fopen(t, "w"); if (!f) return;
    fprintf(f, "# key\tstage\tkinds\tcount\tnctl\tncode\tbuild\twhy\n");
    for (size_t i = 0; i < g_dsv.n; i++) { dsv_ent *x = &g_dsv.e[i];
        fprintf(f, "%s\t%d\t%u\t%u\t%u\t%u\t%s\t%s\n", x->key, x->st, x->kinds, x->count, x->nctl, x->ncode, x->build[0] ? x->build : "-", x->why[0] ? x->why : "-"); }
    fclose(f); rename(t, p);
}
static void dsv_unlink(const char *k) { char p[1200]; snprintf(p, sizeof p, "%s/%s.ctl", g_dsv.dir, k); unlink(p); snprintf(p, sizeof p, "%s/%s.code", g_dsv.dir, k); unlink(p); }
static int dsv_write(const char *k, const void *ctl, uint32_t nctl, const void *code, uint32_t ncode) {
    char p[1200]; FILE *f; int ok = 1;
    snprintf(p, sizeof p, "%s/%s.ctl", g_dsv.dir, k); if ((f = fopen(p, "wb"))) { ok &= fwrite(ctl, 1, nctl, f) == nctl; fclose(f); } else ok = 0;
    snprintf(p, sizeof p, "%s/%s.code", g_dsv.dir, k); if ((f = fopen(p, "wb"))) { ok &= fwrite(code, 1, ncode, f) == ncode; fclose(f); } else ok = 0;
    if (!ok) dsv_unlink(k);
    return ok;
}
// 补料里这个键的控制段 + 代码区（翻译器换了之后按单支重译用，dsh_miss.inc dm_shader_refresh）：0 取到（*buf = 控制段紧跟代码区，调用方 free），1 没有
static int dsv_material(const char *k, uint8_t **buf, uint32_t *nctl, uint32_t *ncode) {
    char dir[1100];
    pthread_mutex_lock(&g_dsv.mu); if (!g_dsv.init) dsv_load(); int off = g_dsv.off; snprintf(dir, sizeof dir, "%s", g_dsv.dir); pthread_mutex_unlock(&g_dsv.mu);
    if (off || !dir[0]) return 1;
    char pc[1200], pd[1200]; struct stat a, b;
    snprintf(pc, sizeof pc, "%s/%.16s.ctl", dir, k); snprintf(pd, sizeof pd, "%s/%.16s.code", dir, k);
    if (stat(pc, &a) || stat(pd, &b) || !a.st_size || !b.st_size || a.st_size >= (1 << 20) || b.st_size >= (1 << 24)) return 1;
    uint8_t *m = malloc((size_t)a.st_size + (size_t)b.st_size); if (!m) return 1;
    FILE *f = fopen(pc, "rb"); size_t got = f ? fread(m, 1, (size_t)a.st_size, f) : 0; if (f) fclose(f);
    f = fopen(pd, "rb"); size_t got2 = f ? fread(m + a.st_size, 1, (size_t)b.st_size, f) : 0; if (f) fclose(f);
    if (got != (size_t)a.st_size || got2 != (size_t)b.st_size) { free(m); return 1; }   // 读的当口被淘汰了
    *buf = m; *nctl = (uint32_t)a.st_size; *ncode = (uint32_t)b.st_size; return 0;
}
// k：16 位十六进制键；st：dsh_stage 的阶段号（< 0 = 认不出：只记索引不存字节）；ctl / code：此刻有效的控制段 / 代码区（调用方保证）；why：失败原文（可空）
static void dsh_salvage_put(const char *k, int kind, int st, const void *ctl, uint32_t nctl, const void *code, uint32_t ncode, const char *why) {
    if (!k || strlen(k) < 16) return;
    pthread_mutex_lock(&g_dsv.mu);
    if (!g_dsv.init) dsv_load();
    if (g_dsv.off) { pthread_mutex_unlock(&g_dsv.mu); return; }
    for (int b = 0; b < 4; b++) if (kind >> b & 1) g_dsv.kinds_run[b]++;
    dsv_ent *x = NULL; for (size_t i = 0; i < g_dsv.n; i++) if (!strncmp(g_dsv.e[i].key, k, 16)) { x = &g_dsv.e[i]; break; }
    int have_bytes = st >= 0 && ctl && code && nctl && ncode && nctl < (1u << 20) && ncode < (1u << 24);
    size_t need = have_bytes ? (size_t)nctl + ncode : 0;
    int dirty = 0;
    if (x) {
        if (!x->run) { x->run = 1; x->count++; dirty = 1; }
        if ((x->kinds | (unsigned)kind) != x->kinds) { x->kinds |= (unsigned)kind; dirty = 1; }
        if (why && *why && !x->why[0]) { snprintf(x->why, sizeof x->why, "%s", why); dsv_tsv_clean(x->why); dirty = 1; }
        if (!x->ncode && need && g_dsv.bytes + need <= g_dsv.cap) {   // 上次只记了索引，这次拿得到字节
            mkdir(g_dsv.dir, 0755);
            if (dsv_write(x->key, ctl, nctl, code, ncode)) { x->st = st; x->nctl = nctl; x->ncode = ncode; g_dsv.bytes += need; dirty = 1; }
        }
    } else {
        // 放不下：先淘汰出现次数最少、其中最早的（本局见过的不动）；淘汰完还放不下就不存
        while (g_dsv.bytes + need > g_dsv.cap) {
            size_t v = (size_t)-1; for (size_t i = 0; i < g_dsv.n; i++) if (!g_dsv.e[i].run && (v == (size_t)-1 || g_dsv.e[i].count < g_dsv.e[v].count)) v = i;
            if (v == (size_t)-1) break;
            dsv_unlink(g_dsv.e[v].key); g_dsv.bytes -= (size_t)g_dsv.e[v].nctl + g_dsv.e[v].ncode;
            memmove(&g_dsv.e[v], &g_dsv.e[v + 1], (g_dsv.n - v - 1) * sizeof *g_dsv.e); g_dsv.n--; dirty = 1;
        }
        if (g_dsv.bytes + need > g_dsv.cap) { g_dsv.dropped++; if (dirty) dsv_write_index(); pthread_mutex_unlock(&g_dsv.mu); return; }
        if (g_dsv.n == g_dsv.nalloc) { size_t na = g_dsv.nalloc ? g_dsv.nalloc * 2 : 256; dsv_ent *ne = realloc(g_dsv.e, na * sizeof *ne); if (!ne) { pthread_mutex_unlock(&g_dsv.mu); return; } g_dsv.e = ne; g_dsv.nalloc = na; }
        x = &g_dsv.e[g_dsv.n]; memset(x, 0, sizeof *x);
        snprintf(x->key, sizeof x->key, "%.16s", k); x->st = st; x->kinds = (unsigned)kind; x->count = 1; x->run = 1; x->isnew = 1;
        if (why && *why) { snprintf(x->why, sizeof x->why, "%s", why); dsv_tsv_clean(x->why); }
        { const char *(*bid)(void) = (const char *(*)(void))dlsym(RTLD_DEFAULT, "s2a_main_build_id"); const char *b = bid ? bid() : NULL; if (b) snprintf(x->build, sizeof x->build, "%.16s", b); }
        mkdir(g_dsv.dir, 0755);
        if (need && dsv_write(x->key, ctl, nctl, code, ncode)) { x->nctl = nctl; x->ncode = ncode; g_dsv.bytes += need; }
        g_dsv.n++; g_dsv.new_run++; dirty = 1;
    }
    if (dirty) dsv_write_index();
    pthread_mutex_unlock(&g_dsv.mu);
}
static void dsh_salvage_summary(void) {   // dsh_summary 收局时调（不另登记汇总回调）
    pthread_mutex_lock(&g_dsv.mu);
    if (g_dsv.init && !g_dsv.off && (g_dsv.new_run || g_dsv.dropped || g_dsv.kinds_run[0] || g_dsv.kinds_run[1] || g_dsv.kinds_run[2] || g_dsv.kinds_run[3]))
        LOG("着色器补料：本局新存 %llu 支（不在映射表 %llu、现编失败 %llu、管线建不起来 %llu、补齐做不了 %llu 次），满额没存 %llu 支；本款累计 %zu 支 %zu KB（上限 %zu MB，%s）",
            (unsigned long long)g_dsv.new_run, (unsigned long long)g_dsv.kinds_run[0], (unsigned long long)g_dsv.kinds_run[1], (unsigned long long)g_dsv.kinds_run[2], (unsigned long long)g_dsv.kinds_run[3],
            (unsigned long long)g_dsv.dropped, g_dsv.n, g_dsv.bytes >> 10, g_dsv.cap >> 20, g_dsv.dir);
    pthread_mutex_unlock(&g_dsv.mu);
}
