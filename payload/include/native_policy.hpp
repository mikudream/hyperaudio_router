#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

namespace ha {

inline bool in_range(uint64_t off, uint64_t len, uint64_t total) {
    return off <= total && len <= total - off;
}

// PT_NOTE entries start at an offset aligned to p_align (usually 4; the
// separate GNU property segment can be 8). ELF notes use a 12-byte header.
inline bool verify_notes(const uint8_t *p, size_t n, uint64_t alignment,
                         const uint8_t (&id)[16], bool &found) {
    if (alignment != 4 && alignment != 8) return false;
    const uint64_t mask = alignment - 1;
    uint64_t off = 0;
    while (off != n) {
        uint32_t fields[3];
        if (!in_range(off, sizeof(fields), n)) return false;
        memcpy(fields, p + off, sizeof(fields));
        const uint64_t name = off + sizeof(fields);
        const auto [namesz, descsz, type] = fields;
        if (!in_range(name, namesz, n) || name + namesz > UINT64_MAX - mask) return false;
        const uint64_t desc = (name + namesz + mask) & ~mask;
        if (!in_range(desc, descsz, n) || desc + descsz > UINT64_MAX - mask) return false;
        if (type == 3 && namesz == 4 && !memcmp(p + name, "GNU", 4)) { // NT_GNU_BUILD_ID
            if (found || descsz != sizeof(id) || memcmp(p + desc, id, sizeof(id))) return false;
            found = true;
        }
        off = (desc + descsz + mask) & ~mask;
        if (off > n) return false;
    }
    return true;
}

inline uintptr_t first_page(uintptr_t lo, uintptr_t hi, size_t size) {
    if (!size || (size & (size - 1)) || lo > UINTPTR_MAX - (size - 1)) return 0;
    const uintptr_t p = (lo + size - 1) & ~(size - 1);
    return p <= hi && size <= hi - p ? p : 0;
}

inline bool branch(uintptr_t from, uintptr_t to, uint32_t &out) {
    if ((from | to) & 3) return false;
    constexpr uintptr_t reach = 1u << 27;
    const uintptr_t dist = from <= to ? to - from : from - to;
    if (dist > reach || (from <= to && dist == reach)) return false;
    uint32_t words = static_cast<uint32_t>(dist / 4);
    if (from > to) words = 0u - words;
    out = 0x14000000u | (words & 0x03ffffffu);
    return true;
}

inline bool space(char c) { return c == ' ' || c == '\t' || c == '\r'; }
inline bool digit(char c) { return c >= '0' && c <= '9'; }
inline bool valid_package(const char *s, size_t n) {
    if (!n || n > 120 || digit(s[0])) return false;
    bool dot = false;
    for (size_t i = 0; i < n; ++i) {
        char c = s[i];
        if (c == '.') {
            if (!i || i + 1 == n || s[i - 1] == '.') return false;
            dot = true;
        } else if (!(digit(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_')) {
            return false;
        }
    }
    return dot;
}

inline bool csv_lists_package(const char *b, size_t n, const char *pkg) {
    bool found = false;
    const size_t pn = strlen(pkg);
    if (!n || (n == 1 && b[0] == '-')) return false;
    for (size_t start = 0; start < n;) {
        size_t stop = start;
        while (stop < n && b[stop] != ',') ++stop;
        if (!valid_package(b + start, stop - start)) return false;
        if (stop - start == pn && !memcmp(b + start, pkg, pn)) found = true;
        if (stop != n && stop + 1 == n) return false;
        start = stop + 1;
    }
    return found;
}

inline bool file_lists_package(const char *b, size_t n, const char *pkg, bool sound) {
    bool found = false, setting_seen = false;
    const size_t pn = strlen(pkg);
    for (size_t i = 0; i < n;) {
        size_t start = i;
        while (i < n && b[i] != '\n') ++i;
        size_t end = i++;
        while (start < end && space(b[start])) ++start;
        while (end > start && space(b[end - 1])) --end;
        if (start == end || b[start] == '#') continue;
        size_t sep = start;
        while (sep < end && b[sep] != '=') ++sep;
        if (sep == end) continue;
        size_t keyend = sep, val = sep + 1;
        while (keyend > start && space(b[keyend - 1])) --keyend;
        while (val < end && space(b[val])) ++val;
        const size_t keylen = keyend - start;
        // perapp's legacy enabled field no longer controls the list.
        if (sound && keylen == 3 && !memcmp(b + start, "app", 3)) {
            if (!valid_package(b + val, end - val)) return false;
            if (end - val == pn && !memcmp(b + val, pkg, pn)) found = true;
        } else if (!sound && keylen == 9 && !memcmp(b + start, "whitelist", 9)) {
            if (setting_seen) return false;
            setting_seen = true;
            found = csv_lists_package(b + val, end - val, pkg);
        }
    }
    return found;
}

inline int active_bank(const char *value, size_t n) {
    if (n < 3 || n > 22 || value[n - 2] != '.' || (value[n - 1] != '0' && value[n - 1] != '1')) return -1;
    if (value[0] == '0') return -1;
    for (size_t i = 0; i < n - 2; ++i) if (!digit(value[i])) return -1;
    return value[n - 1] - '0';
}

template<class Getter>
bool property_lists_package(const char *prefix, const char *pkg, Getter get) {
    constexpr size_t kPropValue = 92, kChunkSize = 80, kSlots = 32;
    char key[64], active_key[64], gen_key[64], active[kPropValue], val[kPropValue];
    snprintf(active_key, sizeof(active_key), "ha.%s.active", prefix);
    snprintf(gen_key, sizeof(gen_key), "ha.%s.gen", prefix);
    int active_len = get(active_key, active);
    if (active_len <= 0) {
        // Read unversioned migration slots only before any v2 publication.
        if (get(gen_key, val) > 0) return false;
        bool found = false;
        for (int i = 0; i < 8; ++i) {
            snprintf(key, sizeof(key), "ha.%s.%d", prefix, i);
            const int n = get(key, val);
            if (n > 0 && n < static_cast<int>(sizeof(val)) && csv_lists_package(val, n, pkg)) found = true;
        }
        return get(active_key, val) <= 0 && get(gen_key, val) <= 0 && found;
    }
    char csv[kSlots * kChunkSize];
    for (int attempt = 0; attempt < 3; ++attempt) {
        const int bank = active_bank(active, active_len);
        if (bank < 0) return false;
        bool ended = false, valid = true;
        size_t len = 0;
        for (size_t i = 0; i < kSlots; ++i) {
            snprintf(key, sizeof(key), "ha.%s.%d.%zu", prefix, bank, i);
            const int n = get(key, val);
            if (n == 1 && val[0] == '-') ended = true;
            else if (ended || n <= 0 || n > static_cast<int>(kChunkSize)) { valid = false; break; }
            else { memcpy(csv + len, val, n); len += n; }
        }
        const int after = get(active_key, val);
        if (after == active_len && !memcmp(active, val, after)) return valid && csv_lists_package(csv, len, pkg);
        if (after <= 0 || after >= static_cast<int>(sizeof(active))) return false;
        memcpy(active, val, after);
        active_len = after;
    }
    return false;
}

inline bool whitelist_override(uintptr_t off, const char16_t *a, size_t na,
                                const char16_t *b, size_t nb, const char *pkg) {
    // Each comparison's first operand is the literal; x2/x3 come from
    // this stream's attribution package. Match both exact operands.
    const char16_t *literal = nullptr;
    switch (off) {
        case 0x5ed4: literal = u"com.google.sample.oboe.manualtest"; break;
        case 0x5f18: literal = u"com.miphone.audiotestteam.multimediatest"; break;
        case 0x5f5c: literal = u"android.media.metrics.cts"; break;
        default: return false;
    }
    if (!a || !b || !pkg || !*pkg || strlen(pkg) != nb) return false;
    size_t len = 0;
    while (literal[len]) ++len;
    if (na != len || memcmp(a, literal, len * sizeof(*a))) return false;
    for (size_t i = 0; i < nb; ++i) if (b[i] != static_cast<unsigned char>(pkg[i])) return false;
    return true;
}

} // namespace ha
