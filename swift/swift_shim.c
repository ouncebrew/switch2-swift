/* SPDX-License-Identifier: MIT
 *
 * C functions that the Swift runtime calls but newlib does not provide.
 *
 * The embedded Swift runtime allocates class instances and heap boxes with
 * posix_memalign. devkitA64's newlib has memalign but not posix_memalign, so
 * every Swift program links this file. It is compiled by the Swift rules and
 * added to the link through SWIFT_SHIM_OBJ.
 *
 * The concurrency runtime reads the monotonic clock. newlib declares
 * clock_gettime but does not implement it, so it is built here on the
 * console's system tick counter.
 */
#include <errno.h>
#include <malloc.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#include <switch/arm/counter.h>

/* The standard library seeds its hash randomisation from the system entropy
 * source. On the console there is none: getrandom is not implemented and there
 * is no /dev/urandom, so the upstream implementation in
 * libswiftStdlibStubs.a calls fatalError during global initialisation, before
 * main, and the program exits to the launcher with no output.
 *
 * This definition replaces that one. It mixes the system tick with the address
 * of a local, which is enough to make hash seeds differ between runs. It is not
 * a cryptographic source and does not need to be. */
void swift_stdlib_random(void *buf, size_t nbytes) {
    uint8_t *out = (uint8_t *)buf;
    uint64_t state = armGetSystemTick() ^ (uint64_t)(uintptr_t)&state;

    for (size_t i = 0; i < nbytes; i++) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        out[i] = (uint8_t)(state >> 24);
    }
}

/* Weak, because libdispatch's libc_shim.c defines the same function. A program
 * that links both would otherwise fail with a multiple definition error. A weak
 * definition is used when nothing else provides one, which is the case for a
 * Swift program that does not use libdispatch. */
__attribute__((weak))
int posix_memalign(void **memptr, size_t alignment, size_t size) {
    void *block = memalign(alignment, size);

    if (block == NULL) {
        return ENOMEM;
    }

    *memptr = block;
    return 0;
}

int clock_getres(clockid_t clock_id, struct timespec *tp) {
    (void)clock_id;

    if (tp == NULL) {
        return EINVAL;
    }

    u64 frequency = armGetSystemTickFreq();

    if (frequency == 0) {
        return EINVAL;
    }

    tp->tv_sec = 0;
    tp->tv_nsec = (long)(1000000000ULL / frequency);
    return 0;
}

int clock_gettime(clockid_t clock_id, struct timespec *tp) {
    (void)clock_id;

    if (tp == NULL) {
        return EINVAL;
    }

    u64 frequency = armGetSystemTickFreq();
    u64 ticks = armGetSystemTick();

    if (frequency == 0) {
        return EINVAL;
    }

    tp->tv_sec = (time_t)(ticks / frequency);
    tp->tv_nsec = (long)((ticks % frequency) * 1000000000ULL / frequency);
    return 0;
}

/* ---- Thread-local storage ------------------------------------------------ */

/* The loader sets tpidrro_el0 to a block of its own. switch.ld's .main.tls
 * reservation at __tls_start is never used: nothing in the program writes
 * tpidrro_el0, and `msr tpidrro_el0` traps at EL0, so it cannot be repointed.
 * The compiler emits [tpidrro_el0 + offset] for every thread_local, so the
 * offsets are relative to the loader's block, not to __tls_start.
 *
 * That block is large enough and writable, but by the time main runs its tail
 * holds garbage that changes between runs, and the Swift libraries' variables
 * live exactly there:
 *
 *   0x430  ActiveTask::Value
 *   0x438  ExecutorTrackingInfo::ActiveInfoInThread
 *   0x440  FallbackTaskLocalStorage::Value
 *   0x448  SwiftTLSContext::TLSContext
 *
 * swift_task_getCurrent then returns that garbage as the current task, and
 * Task { } dies dereferencing it. Clearing those slots fixes it: with them
 * zeroed, Task { } creates, runs and completes.
 *
 * Only the Swift range is cleared. libnx's own entries occupy the start of the
 * block -- fsdev_last_result, g_fsPriority and __nx_dev_path_buf (1025 bytes)
 * -- and zeroing those breaks fsdev, which kills the program in a constructor
 * before main.
 *
 * Since SDK 20261113 libounce links mimalloc, and mimalloc's own thread_locals
 * come first in link order:
 *
 *   0x000  __mi_thread_locals, __mi_theap_cached, __mi_theap_default,
 *          __mi_slot_fast                    (mimalloc, 0x20 bytes)
 *   0x020  fsdev_last_result                  (4 bytes)
 *   0x024  g_fsPriority                       (4 bytes)
 *   0x028  __nx_dev_path_buf                  (1025 bytes, ends at 0x429)
 *   0x430  the Swift entries
 *
 * Before that, libnx's part started at 0x000, __nx_dev_path_buf ran to 0x409
 * and the Swift entries began at 0x410. A stale 0x410 on the new SDK clears
 * the last 25 bytes of the dev path buffer, which is why this number has to be
 * re-derived for every SDK release; scripts/verify-tls-boundary.py does that
 * from a linked ELF and prints the value to use.
 *
 * SWIFT_TLS_START is the size of everything before the Swift entries, and it is
 * the one number here that depends on the console SDK rather than on Swift. It
 * cannot be derived from the block size alone, because the region after the
 * boundary differs depending on whether a program links the concurrency runtime
 * and libdispatch. It is therefore a named, overridable constant rather than a
 * literal, so a libnx that adds a thread_local can be accommodated without
 * editing this file:
 *
 *   -DSWIFT_TLS_START=0x440
 *
 * The value is checked against the block size below, so a block that is too
 * small is left alone rather than cleared past its end. */

#ifndef SWIFT_TLS_START
#define SWIFT_TLS_START 0x430
#endif

extern char __tls_start[], __tls_end[];

__attribute__((constructor)) static void swift_clear_tls(void) {
    size_t size = (size_t)(__tls_end - __tls_start);
    if (size <= SWIFT_TLS_START) {
        return;
    }

    uint64_t tp;
    __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(tp));

    volatile char *block = (volatile char *)(uintptr_t)(tp + SWIFT_TLS_START);
    for (size_t i = 0; i < size - SWIFT_TLS_START; i++) {
        block[i] = 0;
    }
}

/* ---- Image registration -------------------------------------------------- */

/* The runtime resolves a mangled name by demangling it and then looking the
 * nominal type up in the images registered with swift_addNewDSOImage. Upstream
 * registers the main image from a constructor in SwiftRT-ELF-WASM.cpp, but that
 * file compiles to an archive member that defines no global symbol, so the
 * linker never pulls it in and the call never happens. Nothing else references
 * it either: nm on a linked program shows swift_addNewDSOImage with no callers.
 *
 * With no registered image _findContextDescriptor finds nothing, so
 * swift_getTypeByMangledNameInContext2 returns null for every mangled name.
 * __swift_instantiateConcreteTypeFromMangledName caches that null and the
 * caller passes a null metadata to swift_allocObject. Array growth, string
 * interpolation, Task creation and protocol existentials all go through it,
 * which is why they all failed together.
 *
 * This is that constructor, rewritten here so it is always linked. The layout
 * is from stdlib/public/SwiftShims/swift/shims/MetadataSections.h and the
 * version is CurrentSectionMetadataVersion from ImageInspectionCommon.h.
 *
 * It takes no lock, so it does not need C11ThreadingHelper to be constructed
 * first, and a plain constructor runs after the init_priority(101) ones. */

typedef struct {
    uintptr_t start;
    size_t length;
} MetadataSectionRange;

typedef struct {
    uintptr_t version;
    const void *baseAddress;
    void *unused0;
    void *unused1;
    MetadataSectionRange swift5_protocols;
    MetadataSectionRange swift5_protocol_conformances;
    MetadataSectionRange swift5_type_metadata;
    MetadataSectionRange swift5_typeref;
    MetadataSectionRange swift5_reflstr;
    MetadataSectionRange swift5_fieldmd;
    MetadataSectionRange swift5_assocty;
    MetadataSectionRange swift5_replace;
    MetadataSectionRange swift5_replac2;
    MetadataSectionRange swift5_builtin;
    MetadataSectionRange swift5_capture;
    MetadataSectionRange swift5_mpenum;
    MetadataSectionRange swift5_accessible_functions;
    MetadataSectionRange swift5_runtime_attributes;
    MetadataSectionRange swift5_tests;
} MetadataSections;

/* The linker only synthesises __start_/__stop_ for a section that some input
 * object actually has. Every one of these is absent from a program that uses
 * none of the features it describes, so each is created empty here. An empty
 * section merges with a real one when the program does have content, so the
 * bounds still span everything.
 *
 * This has to cover all of them, not just the ones a given program happens to
 * miss: a package that allocates pulls this object in for posix_memalign, and
 * then every symbol below is referenced. Leaving one out makes the link fail
 * with "undefined reference to __start_swift5_<name>" for any program that
 * does not use that feature. */
__asm__("\t.section swift5_protocols,\"aR\"\n");
__asm__("\t.section swift5_protocol_conformances,\"aR\"\n");
__asm__("\t.section swift5_type_metadata,\"aR\"\n");
__asm__("\t.section swift5_typeref,\"aR\"\n");
__asm__("\t.section swift5_reflstr,\"aR\"\n");
__asm__("\t.section swift5_fieldmd,\"aR\"\n");
__asm__("\t.section swift5_assocty,\"aR\"\n");
__asm__("\t.section swift5_replace,\"aR\"\n");
__asm__("\t.section swift5_replac2,\"aR\"\n");
__asm__("\t.section swift5_builtin,\"aR\"\n");
__asm__("\t.section swift5_capture,\"aR\"\n");
__asm__("\t.section swift5_mpenum,\"aR\"\n");
__asm__("\t.section swift5_accessible_functions,\"aR\"\n");
__asm__("\t.section swift5_runtime_attributes,\"aR\"\n");
__asm__("\t.section swift5_tests,\"aR\"\n");
__asm__("\t.text\n");

#define SWIFT_SECTION_BOUNDS(name) \
    extern const char __start_##name[], __stop_##name[]

SWIFT_SECTION_BOUNDS(swift5_protocols);
SWIFT_SECTION_BOUNDS(swift5_protocol_conformances);
SWIFT_SECTION_BOUNDS(swift5_type_metadata);
SWIFT_SECTION_BOUNDS(swift5_typeref);
SWIFT_SECTION_BOUNDS(swift5_reflstr);
SWIFT_SECTION_BOUNDS(swift5_fieldmd);
SWIFT_SECTION_BOUNDS(swift5_assocty);
SWIFT_SECTION_BOUNDS(swift5_replace);
SWIFT_SECTION_BOUNDS(swift5_replac2);
SWIFT_SECTION_BOUNDS(swift5_builtin);
SWIFT_SECTION_BOUNDS(swift5_capture);
SWIFT_SECTION_BOUNDS(swift5_mpenum);
SWIFT_SECTION_BOUNDS(swift5_accessible_functions);
SWIFT_SECTION_BOUNDS(swift5_runtime_attributes);
SWIFT_SECTION_BOUNDS(swift5_tests);

#define SWIFT_SECTION_RANGE(name) \
    { (uintptr_t)__start_##name, (size_t)(__stop_##name - __start_##name) }

/* Weak, because embedded Swift does not link libswiftRuntime and so has no
 * swift_addNewDSOImage. Embedded Swift resolves no metadata by name, so it
 * does not need the image registered; the constructor skips the call when the
 * symbol is absent. */
extern void swift_addNewDSOImage(MetadataSections *sections)
    __attribute__((weak));

static MetadataSections g_sections;

__attribute__((constructor)) static void swift_image_constructor(void) {
    g_sections.version = 4;
    g_sections.baseAddress = NULL;
    g_sections.unused0 = NULL;
    g_sections.unused1 = NULL;
    g_sections.swift5_protocols = (MetadataSectionRange)SWIFT_SECTION_RANGE(swift5_protocols);
    g_sections.swift5_protocol_conformances = (MetadataSectionRange)SWIFT_SECTION_RANGE(swift5_protocol_conformances);
    g_sections.swift5_type_metadata = (MetadataSectionRange)SWIFT_SECTION_RANGE(swift5_type_metadata);
    g_sections.swift5_typeref = (MetadataSectionRange)SWIFT_SECTION_RANGE(swift5_typeref);
    g_sections.swift5_reflstr = (MetadataSectionRange)SWIFT_SECTION_RANGE(swift5_reflstr);
    g_sections.swift5_fieldmd = (MetadataSectionRange)SWIFT_SECTION_RANGE(swift5_fieldmd);
    g_sections.swift5_assocty = (MetadataSectionRange)SWIFT_SECTION_RANGE(swift5_assocty);
    g_sections.swift5_replace = (MetadataSectionRange)SWIFT_SECTION_RANGE(swift5_replace);
    g_sections.swift5_replac2 = (MetadataSectionRange)SWIFT_SECTION_RANGE(swift5_replac2);
    g_sections.swift5_builtin = (MetadataSectionRange)SWIFT_SECTION_RANGE(swift5_builtin);
    g_sections.swift5_capture = (MetadataSectionRange)SWIFT_SECTION_RANGE(swift5_capture);
    g_sections.swift5_mpenum = (MetadataSectionRange)SWIFT_SECTION_RANGE(swift5_mpenum);
    g_sections.swift5_accessible_functions = (MetadataSectionRange)SWIFT_SECTION_RANGE(swift5_accessible_functions);
    g_sections.swift5_runtime_attributes = (MetadataSectionRange)SWIFT_SECTION_RANGE(swift5_runtime_attributes);
    g_sections.swift5_tests = (MetadataSectionRange)SWIFT_SECTION_RANGE(swift5_tests);

    if (swift_addNewDSOImage != NULL) {
        swift_addNewDSOImage(&g_sections);
    }
}
