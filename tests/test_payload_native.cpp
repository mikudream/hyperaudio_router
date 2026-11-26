// Host tests for the production payload's dependency-free native policy.
#include "native_policy.hpp"
#include <assert.h>
#include <string>
#include <unordered_map>

using namespace ha;
using Props = std::unordered_map<std::string, std::string>;

static auto reader(Props &props) {
    return [&](const char *key, char *out) -> int {
        auto it = props.find(key);
        if (it == props.end()) return 0;
        memcpy(out, it->second.c_str(), it->second.size() + 1);
        return static_cast<int>(it->second.size());
    };
}

static void properties() {
    Props p{{"ha.mmap_gate.0", "com.old.app"}};
    assert(property_lists_package("mmap_gate", "com.old.app", reader(p)));
    assert(!property_lists_package("mmap_gate", "com.old", reader(p)));
    p["ha.mmap_gate.gen"] = "1";
    assert(!property_lists_package("mmap_gate", "com.old.app", reader(p)));
    p["ha.mmap_gate.active"] = "1.1";
    for (int i = 0; i < 32; ++i) p["ha.mmap_gate.1." + std::to_string(i)] = "-";
    const std::string pkg = "com.example." + std::string(108, 'a');
    p["ha.mmap_gate.1.0"] = pkg.substr(0, 80);
    p["ha.mmap_gate.1.1"] = pkg.substr(80) + ",com.current";
    assert(property_lists_package("mmap_gate", pkg.c_str(), reader(p)));
    assert(property_lists_package("mmap_gate", "com.current", reader(p)));
    assert(!property_lists_package("mmap_gate", "com.old.app", reader(p)));
    auto get = reader(p);
    assert(!property_lists_package("mmap_gate", "com.current", [&](const char *key, char *out) {
        if (!strcmp(key, "ha.mmap_gate.1.31")) p["ha.mmap_gate.active"] = "2.0";
        return get(key, out);
    }));
    p["ha.mmap_gate.active"] = "3.1";
    p["ha.mmap_gate.1.0"] = "-";
    assert(!property_lists_package("mmap_gate", "com.current", reader(p)));
    p["ha.mmap_gate.active"] = "3.1oops";
    assert(!property_lists_package("mmap_gate", "com.current", reader(p)));
}

int main() {
    assert(in_range(16, 2, 18));
    assert(!in_range(UINT64_MAX, 1, 18));
    assert(!in_range(16, UINT64_MAX, 18));
    assert(first_page(0x4001, 0xc000, 0x4000) == 0x8000);
    assert(first_page(0x4001, 0xbfff, 0x4000) == 0);
    assert(first_page(UINTPTR_MAX, UINTPTR_MAX, 0x4000) == 0);
    uint32_t insn = 0;
    assert(branch(0x8000000, 0, insn) && insn == 0x16000000);
    assert(branch(0, 0x7fffffc, insn) && insn == 0x15ffffff);
    assert(!branch(0, 0x8000000, insn));
    assert(!branch(UINTPTR_MAX - 3, 0, insn));
    assert(!branch(0, 2, insn));
    const uint8_t id[16] = {1, 2};
    uint8_t note[32] = {4,0,0,0,16,0,0,0,3,0,0,0,'G','N','U',0,1,2};
    bool found = false;
    assert(verify_notes(note, sizeof(note), 4, id, found) && found);
    assert(!verify_notes(note, sizeof(note), 4, id, found));
    found = false;
    assert(!verify_notes(note, sizeof(note) - 1, 4, id, found));
    note[7] = 255;
    assert(!verify_notes(note, sizeof(note), 4, id, found));
    auto file = [](const char *buf, bool sound) { return file_lists_package(buf, strlen(buf), "com.app", sound); };
    assert(file("enabled=1\r\napp = com.app\r\n", true));
    assert(file("app=com.app\nenabled=0\n", true));
    assert(!file("# app=com.app\napp=com.app.remote", true));
    assert(!file("", true));
    assert(file("revision=5\nwhitelist=com.other,com.app\n", false));
    assert(!file("arbitrary=com.app\nwhitelist=-", false));
    assert(!file("whitelist=com.app,", false));
    assert(!file("whitelist=com.app\nwhitelist=com.other", false));
    properties();
    constexpr char16_t allow[] = u"com.google.sample.oboe.manualtest", pkg[] = u"com.app";
    constexpr size_t len = sizeof(allow) / sizeof(*allow) - 1;
    assert(whitelist_override(0x5ed4, allow, len, pkg, 7, "com.app"));
    assert(!whitelist_override(0x5e4c, allow, len, pkg, 7, "com.app"));
    assert(!whitelist_override(0x5f18, allow, len, pkg, 7, "com.app"));
    assert(!whitelist_override(0x5ed4, pkg, 7, allow, len, "com.app"));
    assert(!whitelist_override(0x5ed4, allow, len, u"com.app.extra", 13, "com.app"));
    puts("payload native policy: PASS");
}
