/* Hand-written configuration for aarch64-none-elf with newlib and libounce. */
#ifndef __DISPATCH_CONFIG_H__
#define __DISPATCH_CONFIG_H__

#define DISPATCH_USE_INTERNAL_WORKQUEUE 1

/* Thread-local storage is fine, but only because the build passes
 * -mtp=tpidrro_el0. devkitA64's gcc uses -mtp=soft, which reads the thread
 * pointer from tpidrro_el0; clang's default is tpidr_el0, which on the console
 * holds the kernel's thread control block instead. Mixing the two makes every
 * TLS access read garbage and _libdispatch_init dies before main. clang has no
 * -mtp=soft, but -mtp=tpidrro_el0 produces the same base register. */
#define DISPATCH_USE_THREAD_LOCAL_STORAGE 1

#define HAVE_DECL_CLOCK_MONOTONIC 1
#define HAVE_DECL_CLOCK_REALTIME 1
#define HAVE_DECL_CLOCK_UPTIME 0
#define HAVE_DECL_CLOCK_UPTIME_FAST 0
#define HAVE_CLOCK_MONOTONIC_COARSE 0
#define HAVE_DECL_FD_COPY 0
#define HAVE_DECL_NOTE_LOWAT 0
#define HAVE_DECL_NOTE_NONE 0
#define HAVE_DECL_NOTE_REAP 0
#define HAVE_DECL_NOTE_REVOKE 0
#define HAVE_DECL_NOTE_SIGNAL 0
#define HAVE_DECL_POSIX_SPAWN_START_SUSPENDED 0
#define HAVE_DECL_PROGRAM_INVOCATION_SHORT_NAME 0
#define HAVE_DECL_SIGEMT 0
#define HAVE_DECL_VQ_DESIRED_DISK 0
#define HAVE_DECL_VQ_NEARLOWDISK 0
#define HAVE_DECL_VQ_QUOTA 0
#define HAVE_DECL_VQ_UPDATE 0
#define HAVE_DECL_VQ_VERYLOWDISK 0
#define HAVE_DECL_VQ_FREE_SPACE_CHANGE 0

#define HAVE_DLFCN_H 0
#define HAVE_FCNTL_H 1
#define HAVE_GETPROGNAME 1
#define HAVE_INTTYPES_H 1
#define HAVE_MEMORY_H 1
#define HAVE_NORETURN_BUILTIN_TRAP 1
#define HAVE_POSIX_FADVISE 0
#define HAVE_POSIX_SPAWNP 0
#define HAVE_PTHREAD_KEY_INIT_NP 0
#define HAVE_PTHREAD_ATTR_SETCPUPERCENT_NP 0
#define HAVE_PTHREAD_MACHDEP_H 0
#define HAVE_PTHREAD_MAIN_NP 0
#define HAVE_PTHREAD_YIELD_NP 0
#define HAVE_PTHREAD_NP_H 0
#define HAVE_PTHREAD_QOS_H 0
#define HAVE_PTHREAD_WORKQUEUES 0
#define HAVE_PTHREAD_WORKQUEUE_H 0
#define HAVE_PTHREAD_WORKQUEUE_PRIVATE_H 0
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_STRLCPY 1
#define HAVE_SYSCONF 0
#define HAVE_SYS_GUARDED_H 0
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_TARGETCONDITIONALS_H 0
#define HAVE__PTHREAD_WORKQUEUE_INIT 0

#define USE_LIBDISPATCH_INIT_CONSTRUCTOR 1
#define USE_POSIX_SEM 1
#define USE_MACH_SEM 0

/* _GNU_SOURCE is deliberately not defined: it forces _XOPEN_SOURCE 700 in
 * newlib, which declares encrypt(char *__block, ...) and collides with the
 * __block keyword that -fblocks introduces. */
#define VERSION "6.0.3"

#endif
