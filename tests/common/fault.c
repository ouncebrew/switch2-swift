// Fault handler for the Switch 2 probes.
//
// libnx routes every EL0 fault through __libnx_exception_entry, which copies the
// register state into __nx_exceptiondump and resumes the thread at
// __libnx_exception_returnentry. That stub calls the weak __libnx_exception_handler
// and then svcBreak()s, which shows the crash screen and loses the registers.
// Defining the handler here turns a silent crash into a PC/LR/ESR/FAR report on
// the console and in a log file.
//
// The fault may have happened inside the allocator or stdio, so the handler uses
// no malloc, no printf, no fopen and no FILE locks: the log fd is opened once at
// startup and the report is formatted into a static buffer.

#include <switch.h>
#include <switch/arm/thread_context.h>

#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "fault.h"

// libnx defines these weak with a 1 KiB stack. A strong definition here gives the
// handler room to run even when the fault was a stack overflow.
__attribute__((aligned(16))) u8 __nx_exception_stack[0x4000];
u64 __nx_exception_stack_size = sizeof(__nx_exception_stack);

extern ThreadExceptionDump __nx_exceptiondump;

// Copied, not stored by pointer: callers pass a withCString temporary that dies
// with the call, so keeping the pointer would leave this dangling.
static char g_log_path[256];
static int g_console_fd = -1;
static int g_handling;
static char g_report[2048];

static char *put_str(char *p, const char *s) {
    while (*s != '\0') {
        *p++ = *s++;
    }
    return p;
}

static char *put_hex(char *p, u64 v) {
    static const char digits[] = "0123456789abcdef";
    *p++ = '0';
    *p++ = 'x';
    for (int shift = 60; shift >= 0; shift -= 4) {
        *p++ = digits[(v >> shift) & 0xf];
    }
    return p;
}

static char *put_field(char *p, const char *name, u64 v) {
    p = put_str(p, name);
    *p++ = ' ';
    p = put_hex(p, v);
    *p++ = '\n';
    return p;
}

// Swift hands these over as raw bytes and a length, never as a String, so they
// can be copied out even when the String machinery is what failed.
static char *put_bytes(char *p, const unsigned char *s, int len, int max) {
    if (len > max) {
        len = max;
    }
    for (int i = 0; i < len; i++) {
        *p++ = (char)s[i];
    }
    return p;
}

static char *put_u32(char *p, uint32_t v) {
    char tmp[10];
    int n = 0;

    do {
        tmp[n++] = (char)('0' + v % 10);
        v /= 10;
    } while (v != 0);

    while (n > 0) {
        *p++ = tmp[--n];
    }
    return p;
}

// Opens the log, writes, commits and closes, every time.
//
// The fd is deliberately not kept open. A file that a running process still has
// open reads back over FTP as an I/O error, and a program that never faults
// would hold this one open for its whole life, which is exactly the case where
// you most want to read it. open/write/fsync/close is four syscalls on a path
// that runs once.
static void emit(const char *buf, int len) {
    if (g_log_path[0] != '\0') {
        int fd = open(g_log_path, O_WRONLY | O_APPEND);
        if (fd >= 0) {
            write(fd, buf, len);
            fsync(fd);
            close(fd);
        }
    }
    if (g_console_fd >= 0) {
        write(g_console_fd, buf, len);
    }
}

void __libnx_exception_handler(void) {
    if (g_handling) {
        // Faulted again while reporting. Say so and stop rather than loop.
        static const char again[] = "*** FAULT: recursive, giving up ***\n";
        emit(again, (int)sizeof(again) - 1);
        for (;;) {
            svcSleepThread(1000000000ULL);
        }
    }
    g_handling = 1;

    const ThreadExceptionDump *d = &__nx_exceptiondump;
    char *p = g_report;

    p = put_str(p, "\n*** FAULT");
    if (g_log_path[0] != '\0') {
        p = put_str(p, " in ");
        p = put_str(p, g_log_path);
    }
    p = put_str(p, " ***\n");
    p = put_field(p, "desc  ", d->error_desc);
    p = put_field(p, "pc    ", d->pc.x);
    p = put_field(p, "lr    ", d->lr.x);
    p = put_field(p, "sp    ", d->sp.x);
    p = put_field(p, "fp    ", d->fp.x);
    p = put_field(p, "esr   ", d->esr);
    p = put_field(p, "far   ", d->far.x);
    p = put_field(p, "pstate", d->pstate);
    p = put_field(p, "x0    ", d->cpu_gprs[0].x);
    p = put_field(p, "x1    ", d->cpu_gprs[1].x);
    p = put_field(p, "x2    ", d->cpu_gprs[2].x);
    p = put_field(p, "x3    ", d->cpu_gprs[3].x);
    p = put_field(p, "x8    ", d->cpu_gprs[8].x);

    // Frame-pointer walk. Only follow pointers that stay inside the faulting
    // thread's stack, so a bogus fp cannot fault us again.
    u64 fp = d->fp.x;
    u64 sp = d->sp.x;
    p = put_str(p, "trace ");
    for (int i = 0; i < 8; i++) {
        if (fp < sp || fp >= sp + 0x10000 || (fp & 7) != 0) {
            break;
        }
        u64 next = *(const u64 *)fp;
        u64 ret = *(const u64 *)(fp + 8);
        p = put_hex(p, ret);
        *p++ = ' ';
        if (next <= fp) {
            break;
        }
        fp = next;
    }
    *p++ = '\n';

    emit(g_report, (int)(p - g_report));

    // Flush the console to the screen. Done last: if the fault happened inside
    // gfx this may hang, and the log above is already on the SD card.
    consoleUpdate(NULL);

    // Nothing sane to return to: the stub would svcBreak() and show the crash
    // screen, which hides the report. Park the thread instead.
    for (;;) {
        svcSleepThread(1000000000ULL);
    }
}

void fault_install(const char *log_path) {
    g_console_fd = fileno(stdout);

    if (log_path == NULL) {
        return;
    }

    // Truncate any log from a previous run, then close it again. The handler
    // reopens it when it has something to say, so the file is never held open
    // while the program is running.
    int fd = open(log_path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd < 0) {
        // __appInit normally mounts sdmc before constructors run, but mount here
        // if it did not: a second mount just fails harmlessly.
        fsdevMountSdmc();
        fd = open(log_path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    }
    if (fd >= 0) {
        close(fd);
    }

    size_t i = 0;
    for (; log_path[i] != '\0' && i < sizeof g_log_path - 1; i++) {
        g_log_path[i] = log_path[i];
    }
    g_log_path[i] = '\0';
}

// Swift traps do not reach the handler above.
//
// fatalError, a failed precondition and an out-of-bounds Array access all
// compile to `brk`, and the kernel terminates the process on a breakpoint
// without ever forwarding it to the EL0 vector. libnx's own
// ThreadExceptionDesc_Other is documented as "EC <= 0x34 and not a breakpoint",
// which is the same statement from the other side.
//
// They do all funnel through the four reporting functions below first, which
// libswiftStdlibStubs.a's Assert.o defines as stubs that print to a debugger and
// abort. Defining all four here keeps Assert.o out of the link, so there is no
// duplicate symbol, and turns a silent exit into a message with a file and line.
//
// The signatures are from stdlib/public/SwiftShims/swift/shims/AssertionReporting.h.

__attribute__((noreturn)) static void fatal_report(char *p) {
    emit(g_report, (int)(p - g_report));

    // Flush to the screen and park. Returning would let the caller abort, which
    // returns to the launcher and takes the message with it.
    consoleUpdate(NULL);
    for (;;) {
        svcSleepThread(1000000000ULL);
    }
}

// newlib's assert() and the C++ runtime both funnel through __assert_func, which
// calls abort(). abort() on the console returns to the launcher with no output,
// so an assertion failure is indistinguishable from a bare brk. The Swift
// runtime asserts its own invariants this way -- _swift_getGenericMetadata, for
// one, checks that the generic context header matches the descriptor -- so
// overriding it turns another silent death into a file and line.
static char *put_str_n(char *p, const char *s, int max) {
    for (int i = 0; i < max && s[i] != '\0'; i++) {
        *p++ = s[i];
    }
    return p;
}

void __assert_func(const char *file, int line, const char *func,
                   const char *expr) {
    char *p = g_report;
    p = put_str(p, "\n*** ASSERT FAILED ***\n");
    p = put_str(p, "file: ");
    p = put_str_n(p, file ? file : "?", 160);
    p = put_str(p, "\nline: ");
    p = put_u32(p, (uint32_t)line);
    p = put_str(p, "\nexpr: ");
    p = put_str_n(p, expr ? expr : "?", 160);
    p = put_str(p, "\nfunc: ");
    p = put_str_n(p, func ? func : "?", 96);
    p = put_str(p, "\n");
    fatal_report(p);
}

// abort() returns to the launcher with no output, so anything that reaches it
// looks exactly like a bare brk. The concurrency runtime's own fatal errors go
// through swift_Concurrency_fatalErrorv, which formats a message with vfprintf
// and then calls abort(); on the console the message is lost and the program
// just disappears. Overriding abort() at least names the path.
//
// swift_Concurrency_fatalErrorv itself cannot be overridden: it lives in
// libswift_Concurrency.a's Error.o, which the linker pulls in for the callers,
// so a second definition is a duplicate symbol.
void abort(void) {
    char *p = g_report;
    p = put_str(p, "\n*** ABORT ***\n");
    fatal_report(p);
}

void _swift_stdlib_reportFatalErrorInFile(
    const unsigned char *prefix, int prefixLength,
    const unsigned char *message, int messageLength,
    const unsigned char *file, int fileLength,
    uint32_t line, uint32_t flags) {
    (void)flags;

    char *p = g_report;
    p = put_str(p, "\n*** SWIFT FATAL ***\n");
    p = put_bytes(p, file, fileLength, 200);
    *p++ = ':';
    p = put_u32(p, line);
    p = put_str(p, ": ");
    p = put_bytes(p, prefix, prefixLength, 200);
    if (messageLength > 0) {
        p = put_str(p, ": ");
        p = put_bytes(p, message, messageLength, 800);
    }
    *p++ = '\n';
    p = put_field(p, "lr    ", (u64)(uintptr_t)__builtin_return_address(0));
    fatal_report(p);
}

void _swift_stdlib_reportFatalError(
    const unsigned char *prefix, int prefixLength,
    const unsigned char *message, int messageLength,
    uint32_t flags) {
    (void)flags;

    char *p = g_report;
    p = put_str(p, "\n*** SWIFT FATAL ***\n");
    p = put_bytes(p, prefix, prefixLength, 200);
    if (messageLength > 0) {
        p = put_str(p, ": ");
        p = put_bytes(p, message, messageLength, 800);
    }
    *p++ = '\n';
    p = put_field(p, "lr    ", (u64)(uintptr_t)__builtin_return_address(0));
    fatal_report(p);
}

void _swift_stdlib_reportUnimplementedInitializerInFile(
    const unsigned char *className, int classNameLength,
    const unsigned char *initName, int initNameLength,
    const unsigned char *file, int fileLength,
    uint32_t line, uint32_t column, uint32_t flags) {
    (void)flags;

    char *p = g_report;
    p = put_str(p, "\n*** SWIFT FATAL: unimplemented initializer ***\n");
    p = put_bytes(p, file, fileLength, 200);
    *p++ = ':';
    p = put_u32(p, line);
    *p++ = ':';
    p = put_u32(p, column);
    p = put_str(p, ": ");
    p = put_bytes(p, initName, initNameLength, 200);
    p = put_str(p, " for class ");
    p = put_bytes(p, className, classNameLength, 200);
    *p++ = '\n';
    p = put_field(p, "lr    ", (u64)(uintptr_t)__builtin_return_address(0));
    fatal_report(p);
}

void _swift_stdlib_reportUnimplementedInitializer(
    const unsigned char *className, int classNameLength,
    const unsigned char *initName, int initNameLength,
    uint32_t flags) {
    (void)flags;

    char *p = g_report;
    p = put_str(p, "\n*** SWIFT FATAL: unimplemented initializer ***\n");
    p = put_bytes(p, initName, initNameLength, 200);
    p = put_str(p, " for class ");
    p = put_bytes(p, className, classNameLength, 200);
    *p++ = '\n';
    p = put_field(p, "lr    ", (u64)(uintptr_t)__builtin_return_address(0));
    fatal_report(p);
}
