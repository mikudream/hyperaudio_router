// HyperAudioRouter's arm64 Zygisk payload. The two hooks are pinned to
// independently verified device builds, not portable Android ABIs.
#include <jni.h>
#include <android/log.h>
#include <asm/hwcap.h>
#include <asm/mman.h>
#include <atomic>
#include <dlfcn.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <link.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/system_properties.h>
#include <unistd.h>

#include "zygisk.hpp"
#include "native_policy.hpp"

void *operator new(size_t n) { return malloc(n); }
void operator delete(void *p) noexcept { free(p); }
void operator delete(void *p, size_t) noexcept { free(p); }

#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "AAudioMmapGate", __VA_ARGS__)

namespace {
using namespace ha;

constexpr char kClient[] = "/system/lib64/libaudioclient.so";
constexpr char kBuilder[] = "/system/lib64/libaaudio_internal_builder.so";
constexpr char kCreateSymbol[] = "_ZN7android10AudioTrack13createTrack_lEv";
constexpr char kCompareSymbol[] = "strzcmp16";
constexpr size_t kConfigCapacity = 16384;

// mmap-gate/analysis/libaudioclient.so: createTrack_l and the instruction
// sequence proving the mFlags offset and FAST bit on this exact build.
constexpr uint8_t kClientId[] = {0xa4,0x3d,0xdc,0x03,0x29,0x1a,0x3e,0x68,
                                  0x9d,0x58,0x8c,0xed,0xaa,0x4e,0x5b,0x88};
constexpr uintptr_t kCreateOffset = 0x68c08;
constexpr size_t kCreateSize = 10308;
constexpr uint32_t kEntry[] = {0xd503233f,0xfc190fe8,0xa9017bfd,0xa9026ffc};
constexpr uint32_t kFlagsProof[] = {0xb943c268,0x121d7908,0xb903c268};
constexpr size_t kFlagsOffset = 0x3c0;

// mmap-gate/analysis/builder.so. Core and mmap import strzcmp16 too, but
// their calls compare attribution data, not the builder's MMAP allowlist.
constexpr uint8_t kBuilderId[] = {0xdf,0x59,0x35,0x09,0x99,0x0d,0xf2,0x5f,
                                   0x97,0xda,0x0a,0x7a,0xda,0xca,0x59,0x1c};
constexpr uintptr_t kCompareSlot = 0xc558;
constexpr size_t kCompareIndex = 0x31;

char g_pkg[256];
using Compare = int (*)(const char16_t *, size_t, const char16_t *, size_t);
using Create = int (*)(void *);
std::atomic<Create> g_create{nullptr};
std::atomic<bool> g_clear_fast{false};
std::atomic<Compare> g_compare{nullptr};
std::atomic<uintptr_t> g_builder{0};
std::atomic_flag g_logged = ATOMIC_FLAG_INIT;

struct Library {
    const char *path;
    uintptr_t base = 0;
    const Elf64_Phdr *ph = nullptr;
    size_t nph = 0;
    bool duplicate = false;

    const void *at(uint64_t off, uint64_t len, unsigned need, unsigned reject = 0) const {
        if (!len || off > UINTPTR_MAX - base || len - 1 > UINTPTR_MAX - base - off)
            return nullptr;
        for (size_t i = 0; i < nph; ++i) {
            const auto &p = ph[i];
            if (p.p_type == PT_LOAD && (p.p_flags & need) == need && !(p.p_flags & reject) &&
                off >= p.p_vaddr && in_range(off - p.p_vaddr, len, p.p_memsz)) {
                return reinterpret_cast<const void *>(base + off);
            }
        }
        return nullptr;
    }

    template <typename T>
    const T *table(uint64_t off, size_t count, unsigned flags = PF_R) const {
        if (off % alignof(T) || count > SIZE_MAX / sizeof(T)) return nullptr;
        return static_cast<const T *>(at(off, count * sizeof(T), flags));
    }

    bool build_id(const uint8_t (&id)[16]) const {
        bool found = false;
        for (size_t i = 0; i < nph; ++i) {
            const auto &p = ph[i];
            if (p.p_type != PT_NOTE) continue;
            auto *notes = static_cast<const uint8_t *>(at(p.p_vaddr, p.p_filesz, PF_R, PF_W));
            if (!notes || !verify_notes(notes, p.p_filesz, p.p_align, id, found)) return false;
        }
        return found;
    }
};

int find_library(dl_phdr_info *info, size_t, void *arg) {
    auto &lib = *static_cast<Library *>(arg);
    if (!info->dlpi_name || strcmp(info->dlpi_name, lib.path)) return 0;
    if (lib.ph) {
        lib.duplicate = true;
        return 1;
    }
    lib.base = info->dlpi_addr;
    lib.ph = info->dlpi_phdr;
    lib.nph = info->dlpi_phnum;
    return 0;
}

bool load_library(Library &lib, const uint8_t (&id)[16]) {
    dl_iterate_phdr(find_library, &lib);
    auto *eh = lib.table<Elf64_Ehdr>(0, 1);
    return !lib.duplicate && eh && !memcmp(eh->e_ident, ELFMAG, SELFMAG) &&
           eh->e_ident[EI_CLASS] == ELFCLASS64 && eh->e_ident[EI_DATA] == ELFDATA2LSB &&
           eh->e_ident[EI_VERSION] == EV_CURRENT && eh->e_version == EV_CURRENT &&
           eh->e_type == ET_DYN && eh->e_machine == EM_AARCH64 &&
           eh->e_ehsize == sizeof(*eh) && eh->e_phnum == lib.nph &&
           eh->e_phentsize == sizeof(Elf64_Phdr) && lib.build_id(id);
}

struct MapLine {
    uintptr_t start, end;
    int prot;
};

bool next_map(FILE *f, MapLine &map) {
    char buf[256], mode[5];
    unsigned long start, end;
    while (fgets(buf, sizeof(buf), f)) {
        if (!strchr(buf, '\n')) {
            int ch;
            do { ch = fgetc(f); } while (ch != EOF && ch != '\n');
        }
        if (sscanf(buf, "%lx-%lx %4s", &start, &end, mode) != 3 || start >= end) continue;
        map = {start, end, (mode[0] == 'r' ? PROT_READ : 0) |
                           (mode[1] == 'w' ? PROT_WRITE : 0) |
                           (mode[2] == 'x' ? PROT_EXEC : 0)};
        return true;
    }
    return false;
}

int page_protection(uintptr_t page, size_t size) {
    FILE *f = fopen("/proc/self/maps", "re");
    if (!f) return -1;
    MapLine m{};
    int prot = -1;
    while (next_map(f, m)) {
        if (m.start > page) break;
        if (m.start <= page && page < m.end && size <= m.end - page) {
            prot = m.prot;
            break;
        }
    }
    fclose(f);
    return prot;
}

size_t runtime_page_size() {
    long n = sysconf(_SC_PAGESIZE);
    return n >= 4096 && (n & (n - 1)) == 0 ? static_cast<size_t>(n) : 0;
}

// Hint-only mmap never overwrites existing maps, even when /proc races. If
// the returned address differs, still require both B immediates to fit.
void *map_trampoline(uintptr_t target, size_t size) {
    constexpr uintptr_t window = 120UL << 20;
    if (target <= window || target > UINTPTR_MAX - window) return MAP_FAILED;
    const uintptr_t limit = target + window;
    uintptr_t cursor = target - window;
    FILE *f = fopen("/proc/self/maps", "re");
    if (!f) return MAP_FAILED;
    MapLine m{};
    void *result = MAP_FAILED;
    auto try_gap = [&](uintptr_t end) {
        uintptr_t hint = first_page(cursor, end, size);
        if (!hint) return;
        void *page = mmap(reinterpret_cast<void *>(hint), size, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (page == MAP_FAILED) return;
        uint32_t ignored;
        uintptr_t p = reinterpret_cast<uintptr_t>(page);
        if (branch(target + 4, p, ignored) && branch(p + 0x108, target + 8, ignored)) result = page;
        else munmap(page, size);
    };
    while (next_map(f, m)) {
        if (m.end <= cursor) continue;
        try_gap(m.start < limit ? m.start : limit);
        if (result != MAP_FAILED || m.start >= limit) break;
        cursor = m.end;
        if (cursor >= limit) break;
    }
    if (result == MAP_FAILED && !ferror(f) && feof(f)) try_gap(limit);
    fclose(f);
    return result;
}

struct Dynamic {
    uint64_t sym = 0, syment = 0, str = 0, strsz = 0, rel = 0, relsz = 0, relkind = 0;
    uint64_t versym = 0;
};

bool read_dynamic(const Library &lib, Dynamic &d) {
    for (size_t i = 0; i < lib.nph; ++i) {
        const auto &p = lib.ph[i];
        if (p.p_type != PT_DYNAMIC) continue;
        if (p.p_filesz % sizeof(Elf64_Dyn)) return false;
        size_t count = p.p_filesz / sizeof(Elf64_Dyn);
        auto *table = lib.table<Elf64_Dyn>(p.p_vaddr, count);
        if (!table) return false;
        for (size_t n = 0; n < count; ++n) {
            const Elf64_Dyn &e = table[n];
            uint64_t v = e.d_un.d_val;
            switch (e.d_tag) {
                case DT_NULL: return true;
                case DT_SYMTAB: d.sym = v; break;
                case DT_SYMENT: d.syment = v; break;
                case DT_STRTAB: d.str = v; break;
                case DT_STRSZ: d.strsz = v; break;
                case DT_JMPREL: d.rel = v; break;
                case DT_PLTRELSZ: d.relsz = v; break;
                case DT_PLTREL: d.relkind = v; break;
                case DT_VERSYM: d.versym = v; break;
            }
        }
        return false;
    }
    return false;
}

const Elf64_Sym *checked_symbol(const Library &lib, const Dynamic &d, size_t index,
                                const char *wanted) {
    // The supported images place DT_VERSYM directly after .dynsym. Do not
    // infer the symbol count from DT_STRTAB, which is separated by other data.
    if (!d.sym || d.syment != sizeof(Elf64_Sym) || d.versym <= d.sym || d.str <= d.versym ||
        (d.versym - d.sym) % sizeof(Elf64_Sym) || index >= (d.versym - d.sym) / sizeof(Elf64_Sym) ||
        !lib.table<Elf64_Half>(d.versym, (d.versym - d.sym) / sizeof(Elf64_Sym))) return nullptr;
    auto *syms = lib.table<Elf64_Sym>(d.sym, index + 1);
    auto *strs = static_cast<const char *>(lib.at(d.str, d.strsz, PF_R, PF_W));
    if (!syms || !strs || !in_range(syms[index].st_name, strlen(wanted) + 1, d.strsz) ||
        memcmp(strs + syms[index].st_name, wanted, strlen(wanted) + 1) ||
        ELF64_ST_TYPE(syms[index].st_info) != STT_FUNC) return nullptr;
    return &syms[index];
}

extern "C" __attribute__((noinline)) int ha_strzcmp16(const char16_t *a, size_t na,
                                                       const char16_t *b, size_t nb) {
    const uintptr_t base = g_builder.load(std::memory_order_acquire);
    const uintptr_t lr = reinterpret_cast<uintptr_t>(__builtin_return_address(0));
    if (base && lr >= base && whitelist_override(lr - base, a, na, b, nb, g_pkg)) return 0;
    return g_compare.load(std::memory_order_acquire)(a, na, b, nb);
}

bool patch_builder(const Library &lib, size_t pagesize) {
    Dynamic d;
    if (!read_dynamic(lib, d) || !d.rel || d.relkind != DT_RELA ||
        d.relsz % sizeof(Elf64_Rela)) return false;
    const auto *sym = checked_symbol(lib, d, kCompareIndex, kCompareSymbol);
    if (!sym || sym->st_shndx != SHN_UNDEF || sym->st_value != 0) return false;
    size_t count = d.relsz / sizeof(Elf64_Rela);
    auto *rels = lib.table<Elf64_Rela>(d.rel, count);
    if (!rels) return false;
    bool found = false;
    for (size_t i = 0; i < count; ++i) {
        if (rels[i].r_offset != kCompareSlot && ELF64_R_SYM(rels[i].r_info) != kCompareIndex) continue;
        if (found || rels[i].r_offset != kCompareSlot || rels[i].r_addend != 0 ||
            ELF64_R_TYPE(rels[i].r_info) != R_AARCH64_JUMP_SLOT ||
            ELF64_R_SYM(rels[i].r_info) != kCompareIndex) return false;
        found = true;
    }
    if (!found) return false;
    auto *slot = static_cast<const uintptr_t *>(lib.at(kCompareSlot, sizeof(uintptr_t), PF_R | PF_W, PF_X));
    if (!slot || reinterpret_cast<uintptr_t>(slot) % alignof(uintptr_t)) return false;
    uintptr_t addr = reinterpret_cast<uintptr_t>(slot);
    uintptr_t page = addr & ~(pagesize - 1);
    int prot = page_protection(page, pagesize);
    if ((prot != PROT_READ && prot != (PROT_READ | PROT_WRITE)) ||
        sizeof(*slot) > pagesize - (addr - page)) return false;
    auto *write_slot = const_cast<uintptr_t *>(slot);
    uintptr_t original = __atomic_load_n(slot, __ATOMIC_ACQUIRE);
    Dl_info owner{};
    if (!original || !dladdr(reinterpret_cast<void *>(original), &owner) || !owner.dli_sname ||
        strcmp(owner.dli_sname, kCompareSymbol) || owner.dli_saddr != reinterpret_cast<void *>(original))
        return false;
    auto *p = reinterpret_cast<void *>(page);
    if (prot == PROT_READ && mprotect(p, pagesize, PROT_READ | PROT_WRITE) != 0) return false;
    g_compare.store(reinterpret_cast<Compare>(original), std::memory_order_release);
    g_builder.store(lib.base, std::memory_order_release);
    uintptr_t replacement = reinterpret_cast<uintptr_t>(&ha_strzcmp16);
    bool changed = __atomic_compare_exchange_n(write_slot, &original, replacement, false,
                                               __ATOMIC_RELEASE, __ATOMIC_RELAXED);
    if (prot == PROT_READ && mprotect(p, pagesize, prot) != 0) {
        if (changed) {
            g_builder.store(0, std::memory_order_release);
            __atomic_store_n(write_slot, original, __ATOMIC_RELEASE);
        }
        LOGE("GOT page protection restore failed; patch rolled back");
        if (mprotect(p, pagesize, prot) != 0) LOGE("GOT page protection retry failed");
        // A thread may already have read the replacement. Leave its code
        // and forwarding pointer mapped even though the slot was rolled back.
        return changed;
    }
    return changed;
}

extern "C" int ha_create_track(void *thiz) {
    if (thiz && g_clear_fast.load(std::memory_order_acquire)) {
        // createTrack_l is called with AudioTrack's lock held.
        auto *flags = reinterpret_cast<uint32_t *>(static_cast<char *>(thiz) + kFlagsOffset);
        uint32_t before = *flags;
        *flags = before & ~0x4u;
        if (before != *flags && !g_logged.test_and_set(std::memory_order_relaxed)) {
            __android_log_print(ANDROID_LOG_INFO, "AAudioMmapGate", "FAST flag cleared");
        }
    }
    return g_create.load(std::memory_order_acquire)(thiz);
}

bool patch_create(const Library &lib, void *handle, size_t pagesize) {
    const auto *entry = static_cast<const uint32_t *>(lib.at(kCreateOffset, kCreateSize, PF_R | PF_X, PF_W));
    const auto *proof = lib.at(0x68db0, sizeof(kFlagsProof), PF_R | PF_X, PF_W);
    Dynamic d;
    if (!read_dynamic(lib, d)) return false;
    const auto *sym = checked_symbol(lib, d, 1103, kCreateSymbol);
    if (!sym || sym->st_shndx == SHN_UNDEF || sym->st_value != kCreateOffset || sym->st_size != kCreateSize ||
        !entry || !proof || dlsym(handle, kCreateSymbol) != entry || memcmp(entry, kEntry, sizeof(kEntry)) ||
        memcmp(proof, kFlagsProof, sizeof(kFlagsProof))) return false;
    uintptr_t target = reinterpret_cast<uintptr_t>(entry);
    uintptr_t page = (target + 4) & ~(pagesize - 1);
    const int prot = page_protection(page, pagesize);
    if (prot != (PROT_READ | PROT_EXEC)) return false;
    // The fingerprinted ELF advertises BTI; preserve it on hardware that
    // supports guarded pages. The original PACIASP remains the landing pad.
    int restore = prot | ((getauxval(AT_HWCAP2) & HWCAP2_BTI) ? PROT_BTI : 0);
    void *tramp = map_trampoline(target, pagesize);
    if (tramp == MAP_FAILED) return false;
    uintptr_t p = reinterpret_cast<uintptr_t>(tramp);
    auto *jump = static_cast<uint32_t *>(tramp);
    auto *original = reinterpret_cast<uint32_t *>(p + 0x100);
    uint32_t patch;
    if (!branch(target + 4, p, patch) || !branch(p + 0x108, target + 8, original[2])) {
        munmap(tramp, pagesize);
        return false;
    }
    jump[0] = 0xd50323bf; // AUTIASP: undo the original entry PAC before dispatching.
    jump[1] = 0x58000070; // LDR x16, #12 (literal at trampoline +16).
    jump[2] = 0xd61f0200; // BR x16; compiled hook provides its own BTI entry.
    uintptr_t hook = reinterpret_cast<uintptr_t>(&ha_create_track);
    memcpy(jump + 4, &hook, sizeof(hook));
    original[0] = kEntry[0]; // PACIASP is also the indirect-call landing instruction.
    original[1] = kEntry[1]; // Replay the displaced stack store before resuming.
    auto *code = static_cast<char *>(tramp);
    __builtin___clear_cache(code, reinterpret_cast<char *>(original + 3));
    auto *text = reinterpret_cast<void *>(page);
    const int writable = PROT_READ | PROT_WRITE | PROT_EXEC | ((restore & PROT_BTI) ? PROT_BTI : 0);
    if (mprotect(tramp, pagesize, restore) != 0 || mprotect(text, pagesize, writable) != 0) {
        munmap(tramp, pagesize);
        return false;
    }
    g_create.store(reinterpret_cast<Create>(original), std::memory_order_release);
    g_clear_fast.store(true, std::memory_order_release);
    auto *insn = const_cast<uint32_t *>(entry + 1);
    uint32_t expected = kEntry[1];
    bool changed = __atomic_compare_exchange_n(insn, &expected, patch, false, __ATOMIC_RELEASE, __ATOMIC_RELAXED);
    __builtin___clear_cache(reinterpret_cast<char *>(insn), reinterpret_cast<char *>(insn + 1));
    if (mprotect(text, pagesize, restore) != 0) {
        g_clear_fast.store(false, std::memory_order_release);
        if (changed) {
            __atomic_store_n(insn, kEntry[1], __ATOMIC_RELEASE);
            __builtin___clear_cache(reinterpret_cast<char *>(insn), reinterpret_cast<char *>(insn + 1));
        }
        if (mprotect(text, pagesize, restore) != 0) LOGE("AudioTrack text protection rollback failed");
        // The branch might already be in flight on another core. Do not
        // unmap its trampoline (or unload our module) after publication.
        if (changed) return true;
    }
    if (!changed) {
        g_create.store(nullptr, std::memory_order_release);
        munmap(tramp, pagesize);
    }
    return changed;
}

bool install(const char *path, const uint8_t (&id)[16], bool sound) {
    size_t pagesize = runtime_page_size();
    if (!pagesize) return false;
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) return false;
    Library lib{path};
    const bool ok = load_library(lib, id) &&
                    (sound ? patch_create(lib, h, pagesize) : patch_builder(lib, pagesize));
    if (!ok) dlclose(h); // On success keep the patched object and its dependencies loaded.
    return ok;
}

enum class FileStatus { Unavailable, Invalid, Read };
FileStatus read_config(const char *path, char (&buf)[kConfigCapacity], size_t &len) {
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) {
        if (errno == EACCES || errno == EPERM || errno == ENOENT) return FileStatus::Unavailable;
        return FileStatus::Invalid;
    }
    struct stat st{};
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != 0 || (st.st_mode & 022)) {
        close(fd);
        return FileStatus::Invalid;
    }
    len = 0;
    while (len < sizeof(buf)) {
        ssize_t n = read(fd, buf + len, sizeof(buf) - len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            close(fd);
            return n == 0 && !memchr(buf, 0, len) ? FileStatus::Read : FileStatus::Invalid;
        }
        len += static_cast<size_t>(n);
    }
    close(fd);
    return FileStatus::Invalid; // Never act on a truncated file.
}

bool listed(bool sound) {
    char buf[kConfigCapacity];
    size_t len = 0;
    const char *prefix = sound ? "perapp.app" : "mmap_gate";
    FileStatus st = read_config(sound ? "/data/adb/modules/hyperaudio/perapp.conf"
                                       : "/data/adb/modules/hyperaudio/lowlat.conf", buf, len);
    if (st == FileStatus::Read) return file_lists_package(buf, len, g_pkg, sound);
    if (st == FileStatus::Invalid) return false;
    return property_lists_package(prefix, g_pkg, [](const char *key, char *out) {
        return __system_property_get(key, out);
    });
}

class MmapGateModule : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override { this->api = api; this->env = env; }
    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        if (!args || !env || !args->nice_name || args->uid % 100000 < 10000 ||
            args->uid % 100000 > 19999 || (api && (api->getFlags() & zygisk::PROCESS_ON_DENYLIST))) {
            unload();
            return;
        }
        const char *name = env->GetStringUTFChars(args->nice_name, nullptr);
        if (!name) { unload(); return; }
        size_t n = strcspn(name, ":");
        const bool valid = n < sizeof(g_pkg) && valid_package(name, n);
        if (valid) { memcpy(g_pkg, name, n); g_pkg[n] = 0; }
        env->ReleaseStringUTFChars(args->nice_name, name);
        if (valid) {
            sound = listed(true);
            gate = !sound && listed(false);
        }
        if (!sound && !gate) unload();
    }
    void postAppSpecialize(const zygisk::AppSpecializeArgs *) override {
        if (!sound && !gate) return;
        if (!(sound ? install(kClient, kClientId, true) : install(kBuilder, kBuilderId, false))) {
            LOGE("%s: no compatible %s hook installed", g_pkg, sound ? "AudioTrack" : "AAudio builder");
            unload();
        }
    }
private:
    void unload() { if (api) api->setOption(zygisk::DLCLOSE_MODULE_LIBRARY); }
    zygisk::Api *api = nullptr;
    JNIEnv *env = nullptr;
    bool sound = false;
    bool gate = false;
};
} // namespace

REGISTER_ZYGISK_MODULE(MmapGateModule)
