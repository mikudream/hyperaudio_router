// AAudio MMAP Gate — 按名单放行 AAudio 的 MMAP 白名单校验
//
// 机制：在名单内应用的进程里，把 libaaudio_internal*.so 的 strzcmp16
// 入口替换成我们的实现；当比较对象是 AOSP 那 5 个白名单包名之一时返回 0，
// 使 AudioStreamBuilder 的 MMAP 白名单检查通过。名单外应用完全不动。
//
// 不依赖原作者的源码：自己实现 strzcmp16 与入口跳转（16 字节 trampoline），
// 不需要 Dobby。

#include <jni.h>
#include <android/log.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <elf.h>
#include <link.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/system_properties.h>

#include "zygisk.hpp"

// 不链接 libc++：Zygisk 会在 app 进程里 dlopen 本模块，不能依赖 libc++_shared
void *operator new(size_t n) { return malloc(n); }
void operator delete(void *p) noexcept { free(p); }
void operator delete(void *p, size_t) noexcept { free(p); }

#define TAG "AAudioMmapGate"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace {

constexpr size_t kMaxList = 8192;
char g_list[kMaxList];
size_t g_list_len = 0;
bool g_target = false;
char g_pkg[256];
bool g_patched = false;

const char16_t *kWhitelist[] = {
    u"android.nativemedia.aaudio",
    u"com.android.cts.verifier",
    u"com.google.sample.oboe.manualtest",
    u"com.miphone.audiotestteam.multimediatest",
    u"android.media.metrics.cts",
};

// 真实签名是 strzcmp16(s1, n1, s2, n2)（见 builder 反汇编：
// x0=ptr, x1=len, x2=ptr, x3=len）
int cmp16(const char16_t *a, size_t na, const char16_t *b, size_t nb) {
    size_t n = na < nb ? na : nb;
    for (size_t i = 0; i < n; i++) {
        if (a[i] != b[i]) return (int)a[i] - (int)b[i];
    }
    if (na == nb) return 0;
    return na < nb ? -1 : 1;
}

bool eq_name(const char16_t *s, size_t n, const char16_t *name) {
    size_t i = 0;
    for (; name[i]; i++) {
        if (i >= n || s[i] != name[i]) return false;
    }
    return i == n;
}

bool starts_with(const char16_t *s, size_t n, const char *ascii) {
    for (size_t i = 0; ascii[i]; i++) {
        if (i >= n || s[i] != (char16_t)(unsigned char)ascii[i]) return false;
    }
    return true;
}

// 被 patch 进去的实现
extern "C" int ha_strzcmp16(const char16_t *s1, size_t n1,
                            const char16_t *s2, size_t n2) {
    for (const char16_t *w : kWhitelist) {
        size_t len = 0;
        while (w[len]) len++;
        if (eq_name(s1, n1, w) || eq_name(s2, n2, w)) return 0;
    }
    if (g_pkg[0]) {
        if (starts_with(s1, n1, g_pkg) || starts_with(s2, n2, g_pkg)) return 0;
    }
    return cmp16(s1, n1, s2, n2);
}

// 只改 aaaudio 库自己的 GOT 表项（strzcmp16 在 builder/core/mmap 里是导入符号）。
// 之前用 dlsym 会解析到 libc 的全局 strzcmp16，等于改坏整个进程。
static uintptr_t g_find_base = 0;
static const char *g_find_name = nullptr;

static int find_base_cb(struct dl_phdr_info *info, size_t, void *) {
    if (info->dlpi_name && g_find_name && strstr(info->dlpi_name, g_find_name)) {
        g_find_base = (uintptr_t)info->dlpi_addr;
        return 1;
    }
    return 0;
}

static uintptr_t lib_base(const char *soname) {
    g_find_base = 0;
    g_find_name = soname;
    dl_iterate_phdr(find_base_cb, nullptr);
    return g_find_base;
}

bool patch_got(const char *path, const char *symname, void *fn) {
    void *h = dlopen(path, RTLD_NOW);
    if (!h) {
        LOGI("%s: dlopen failed (%s)", path, dlerror());
        return false;
    }
    const char *slash = strrchr(path, '/');
    uintptr_t base = lib_base(slash ? slash + 1 : path);
    if (!base) {
        LOGI("%s: base not found", path);
        return false;
    }

    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat st{};
    if (fstat(fd, &st) != 0 || st.st_size <= 0) { close(fd); return false; }
    void *map = mmap(nullptr, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return false;
    const Elf64_Ehdr *eh = (const Elf64_Ehdr *)map;
    if (memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0 || eh->e_shoff == 0) {
        munmap(map, (size_t)st.st_size);
        return false;
    }
    const Elf64_Shdr *sh = (const Elf64_Shdr *)((const char *)map + eh->e_shoff);
    size_t shnum = eh->e_shnum;
    int patched = 0;
    for (size_t i = 0; i < shnum; i++) {
        if (sh[i].sh_type != SHT_RELA) continue;
        if (sh[i].sh_link >= shnum) continue;
        const Elf64_Shdr &symsh = sh[sh[i].sh_link];
        if (symsh.sh_link >= shnum) continue;
        const Elf64_Sym *syms = (const Elf64_Sym *)((const char *)map + symsh.sh_offset);
        const char *strs = (const char *)map + sh[symsh.sh_link].sh_offset;
        const Elf64_Rela *rel = (const Elf64_Rela *)((const char *)map + sh[i].sh_offset);
        size_t n = sh[i].sh_size / sizeof(Elf64_Rela);
        for (size_t k = 0; k < n; k++) {
            size_t si = (size_t)ELF64_R_SYM(rel[k].r_info);
            if (si == 0) continue;
            const char *name = strs + syms[si].st_name;
            if (strcmp(name, symname) != 0) continue;
            uintptr_t slot = base + (uintptr_t)rel[k].r_offset;
            uintptr_t page = slot & ~(uintptr_t)0xFFF;
            if (mprotect((void *)page, 0x1000, PROT_READ | PROT_WRITE) != 0) continue;
            *(uintptr_t *)slot = (uintptr_t)fn;
            __builtin___clear_cache((char *)slot, (char *)slot + sizeof(uintptr_t));
            LOGI("%s: GOT patched at base=0x%zx off=0x%zx", path, base,
                 (size_t)rel[k].r_offset);
            patched++;
        }
    }
    munmap(map, (size_t)st.st_size);
    if (!patched) LOGI("%s: no GOT entry for %s", path, symname);
    return patched > 0;
}

void load_gate_list() {
    if (g_list_len) return;
    // 1) 优先读文件（zygote 命名空间可见时）
    const char *paths[] = {
        "/data/adb/modules/hyperaudio/lowlat.conf",
        "/data/adb/modules/aaudio_mmap_gate/whitelist.conf",
    };
    for (const char *p : paths) {
        int fd = open(p, O_RDONLY | O_CLOEXEC);
        if (fd < 0) continue;
        ssize_t n = read(fd, g_list, kMaxList - 1);
        close(fd);
        if (n <= 0) continue;
        g_list[n] = 0;
        g_list_len = (size_t)n;
        LOGI("gate list loaded from %s (%zd bytes)", p, n);
        break;
    }
    // 2) 再合并系统属性通道：hyperaudio 以 root 写入 ha.mmap_gate.0..7
    for (int i = 0; i < 8; i++) {
        char key[32], val[PROP_VALUE_MAX];
        snprintf(key, sizeof(key), "ha.mmap_gate.%d", i);
        int n = __system_property_get(key, val);
        if (n <= 0) continue;
        if (g_list_len + (size_t)n + 2 >= kMaxList) break;
        if (g_list_len) g_list[g_list_len++] = ',';
        memcpy(g_list + g_list_len, val, (size_t)n);
        g_list_len += (size_t)n;
        g_list[g_list_len] = 0;
    }
    if (g_list_len) {
        LOGI("gate list merged (%zu bytes)", g_list_len);
    } else {
        LOGI("no gate list found; module will not hook anything");
    }
}

bool in_list(const char *pkg) {
    load_gate_list();
    if (!g_list_len) return false;
    const char *p = g_list;
    const char *end = g_list + g_list_len;
    while (p < end) {
        // 跳过到下一个候选包名：以字母或下划线开头
        while (p < end && !((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || *p == '_')) p++;
        const char *s = p;
        while (p < end && ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
                           (*p >= '0' && *p <= '9') || *p == '.' || *p == '_')) p++;
        size_t len = (size_t)(p - s);
        if (len && strncmp(s, pkg, len) == 0 && pkg[len] == 0) return true;
    }
    return false;
}

char g_sound_list[kMaxList];
size_t g_sound_len = 0;
bool g_sound_target = false;
bool g_logged_flags = false;
void *g_orig_create = nullptr;

void load_sound_list() {
    if (g_sound_len) return;
    const char *path = "/data/adb/modules/hyperaudio/perapp.conf";
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        ssize_t n = read(fd, g_sound_list, kMaxList - 1);
        close(fd);
        if (n > 0) {
            g_sound_list[n] = 0;
            g_sound_len = (size_t)n;
        }
    }
    // 再合并属性通道，避免文件与属性短暂不一致时漏掉名单
    for (int i = 0; i < 8; i++) {
        char key[32], val[PROP_VALUE_MAX];
        snprintf(key, sizeof(key), "ha.perapp.app.%d", i);
        int n = __system_property_get(key, val);
        if (n <= 0) continue;
        if (g_sound_len + (size_t)n + 2 >= kMaxList) break;
        if (g_sound_len) g_sound_list[g_sound_len++] = ',';
        memcpy(g_sound_list + g_sound_len, val, (size_t)n);
        g_sound_len += (size_t)n;
        g_sound_list[g_sound_len] = 0;
    }
    if (g_sound_len) LOGI("sound list merged (%zu bytes)", g_sound_len);
}

bool csv_has(const char *buf, size_t len, const char *pkg) {
    const char *p = buf, *end = buf + len;
    while (p < end) {
        while (p < end && !((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || *p == '_')) p++;
        const char *s = p;
        while (p < end && ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
                           (*p >= '0' && *p <= '9') || *p == '.' || *p == '_')) p++;
        size_t n = (size_t)(p - s);
        if (n && strncmp(s, pkg, n) == 0 && pkg[n] == 0) return true;
    }
    return false;
}

// 在目标 ±120MB 内分配一页，保证直接 b 指令可达。
// 按 /proc/self/maps 的真实空隙找，而不是盲试固定地址。
void *mmap_near(uintptr_t target, size_t size) {
    struct Map { uintptr_t s, e; };
    static Map maps[512];
    int nm = 0;
    FILE *f = fopen("/proc/self/maps", "re");
    if (f) {
        char line[512];
        while (nm < 512 && fgets(line, sizeof(line), f)) {
            unsigned long a = 0, b = 0;
            if (sscanf(line, "%lx-%lx", &a, &b) == 2) {
                maps[nm].s = a;
                maps[nm].e = b;
                nm++;
            }
        }
        fclose(f);
    }
#ifdef MAP_FIXED_NOREPLACE
    const int fixed = MAP_FIXED_NOREPLACE;
#else
    const int fixed = 0x100000;
#endif
    const uintptr_t window = 120UL << 20;
    uintptr_t lo = target > window ? target - window : 0x10000;
    uintptr_t hi = target + window;
    auto try_at = [&](uintptr_t cand) -> void * {
        if (cand < 0x10000) return MAP_FAILED;
        void *p = mmap((void *)cand, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                       MAP_PRIVATE | MAP_ANONYMOUS | fixed, -1, 0);
        if (p == MAP_FAILED) return MAP_FAILED;
        int64_t d = (int64_t)((uintptr_t)p - target);
        if (d > -(int64_t)window && d < (int64_t)window) return p;
        munmap(p, size);
        return MAP_FAILED;
    };
    uintptr_t prev_end = lo;
    for (int i = 0; i < nm; i++) {
        uintptr_t gs = maps[i].s > prev_end ? maps[i].s : prev_end;
        uintptr_t ge = maps[i].s;   // gap is [prev_end, maps[i].s)
        if (ge > hi) ge = hi;
        if (ge > gs + size) {
            uintptr_t cand = (gs + 0xFFF) & ~(uintptr_t)0xFFF;
            if (cand + size <= ge) {
                void *p = try_at(cand);
                if (p != MAP_FAILED) return p;
            }
        }
        if (maps[i].e > prev_end) prev_end = maps[i].e;
    }
    if (hi > prev_end + size) {
        uintptr_t cand = (prev_end + 0xFFF) & ~(uintptr_t)0xFFF;
        if (cand < hi) {
            void *p = try_at(cand);
            if (p != MAP_FAILED) return p;
        }
    }
    // 最后退回内核提示地址
    for (int i = 1; i < 60; i++) {
        for (int dir = -1; dir <= 1; dir += 2) {
            uintptr_t cand = (target & ~(uintptr_t)0xFFFFF) +
                             (uintptr_t)(dir * i) * 0x200000;
            void *p = try_at(cand);
            if (p != MAP_FAILED) return p;
        }
    }
    return MAP_FAILED;
}

extern "C" int ha_create_track(void *thiz) {
    // 在 createTrack_l 入口就清掉 FAST|PRIMARY：set() 已完成参数校验，
    // 这里改 mFlags 才会影响它后面选择 FastMixer / normal mixer 的判断。
    if (thiz) {
        uint32_t *f = (uint32_t *)((char *)thiz + 0x3c0);
        uint32_t before = *f;
        *f = before & ~0x4u;   // 只清 AUDIO_OUTPUT_FLAG_FAST（与 AOSP 的 mFlags &= ~FAST 一致）
        if (!g_logged_flags) {
            g_logged_flags = true;
            LOGI("mFlags before=0x%x after=0x%x", before, *f);
        }
    }
    auto fn = (int (*)(void *))g_orig_create;
    return fn(thiz);
}

bool install_create_hook() {
    void *h = dlopen("libaudioclient.so", RTLD_NOW);
    if (!h) return false;
    void *target = dlsym(h, "_ZN7android10AudioTrack13createTrack_lEv");
    if (!target) {
        LOGI("createTrack_l not found");
        return false;
    }
    void *page = mmap_near((uintptr_t)target, 0x1000);
    if (page == MAP_FAILED) {
        LOGE("mmap_near failed");
        return false;
    }
    uint8_t *base = (uint8_t *)page;
    uint32_t *hook = (uint32_t *)base;
    hook[0] = 0x58000050u;   // ldr x16, #8
    hook[1] = 0xD61F0200u;   // br x16
    uint64_t fnaddr = (uint64_t)(uintptr_t)&ha_create_track;
    memcpy(&hook[2], &fnaddr, sizeof(fnaddr));

    uint32_t *orig = (uint32_t *)(base + 0x100);
    orig[0] = 0xD503233Fu;   // paciasp
    int64_t delta = (int64_t)(((uintptr_t)target + 4) - (uintptr_t)&orig[1]);
    orig[1] = 0x14000000u | (uint32_t)((delta >> 2) & 0x3FFFFFF);
    g_orig_create = orig;

    uintptr_t tpage = (uintptr_t)target & ~(uintptr_t)0xFFF;
    if (mprotect((void *)tpage, 0x1000, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) return false;
    int64_t d = (int64_t)((uintptr_t)page - (uintptr_t)target);
    uint32_t b = 0x14000000u | (uint32_t)((d >> 2) & 0x3FFFFFF);
    *(uint32_t *)target = b;
    __builtin___clear_cache((char *)target, (char *)target + 4);
    mprotect((void *)tpage, 0x1000, PROT_READ | PROT_EXEC);
    LOGI("createTrack_l hooked: target=%p tramp=%p", target, page);
    return true;
}

class MmapGateModule : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override {
        this->api = api;
        this->env = env;
        LOGI("module loaded");
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        g_target = false;
        g_sound_target = false;
        g_pkg[0] = 0;
        if (!args || !env || !args->nice_name) return;
        if (args->uid < 10000) return;   // 只处理普通应用
        const char *name = env->GetStringUTFChars(args->nice_name, nullptr);
        if (!name) return;
        size_t i = 0;
        for (; name[i] && i < sizeof(g_pkg) - 1; i++) {
            if (name[i] == ':') break;   // com.foo:remote -> com.foo
            g_pkg[i] = name[i];
        }
        g_pkg[i] = 0;
        env->ReleaseStringUTFChars(args->nice_name, name);
        load_sound_list();
        if (g_sound_len && csv_has(g_sound_list, g_sound_len, g_pkg)) {
            g_sound_target = true;
            LOGI("sound hook on: %s", g_pkg);
            return;
        }
        if (in_list(g_pkg)) {
            g_target = true;
            LOGI("mmap gate on: %s", g_pkg);
        }
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *) override {
        if (g_sound_target) {
            if (!g_patched) {
                g_patched = true;
                if (!install_create_hook()) LOGE("%s: createTrack_l hook failed", g_pkg);
            }
            return;
        }
        if (!g_target || g_patched) return;
        g_patched = true;
        const char *libs[] = {
            "/system/lib64/libaaudio_internal_builder.so",
            "/system/lib64/libaaudio_internal_core.so",
            "/system/lib64/libaaudio_internal_mmap.so",
        };
        bool any = false;
        for (const char *l : libs) any |= patch_got(l, "strzcmp16", (void *)&ha_strzcmp16);
        if (!any) LOGE("%s: no aaudio GOT patched", g_pkg);
    }

private:
    zygisk::Api *api = nullptr;
    JNIEnv *env = nullptr;
};

} // namespace

REGISTER_ZYGISK_MODULE(MmapGateModule)
