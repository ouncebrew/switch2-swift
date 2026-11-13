/* Forced-include shim for libdispatch on Switch 2.
 *
 * sysctlbyname is declared here because internal.h only includes sys/sysctl.h
 * on non-Linux targets, and this build takes the Linux paths.
 */
#ifndef DISPATCH_BLOCKS_SHIM_H
#define DISPATCH_BLOCKS_SHIM_H

#include <stddef.h>
#include <time.h>

/* newlib has CLOCK_MONOTONIC but not CLOCK_BOOTTIME. The clock_gettime
 * implementation ignores the clock id and reads the system tick. */
#ifndef CLOCK_BOOTTIME
#define CLOCK_BOOTTIME 7
#endif

/* newlib implements asprintf but only declares it with _GNU_SOURCE, which
 * this build cannot use. */
int asprintf(char **strp, const char *format, ...);

/* newlib declares __socklen_t but not the POSIX spelling. */
typedef __socklen_t socklen_t;

/* newlib's signal.h has no SA_RESTART. */
#ifndef SA_RESTART
#define SA_RESTART 0x10000000
#endif

/* newlib declares ioctl in sys/ioctl.h, which libdispatch does not include. */
int ioctl(int fd, unsigned long request, ...);

/* newlib has no sys/sysmacros.h. */
#ifndef major
#define major(device) ((unsigned int)(((device) >> 8) & 0xfff))
#endif
#ifndef minor
#define minor(device) ((unsigned int)((device) & 0xff) | (((device) >> 12) & 0xfff00))
#endif

/* newlib declares posix_fadvise only with _GNU_SOURCE. */
#define POSIX_FADV_NORMAL 0
#define POSIX_FADV_WILLNEED 3
#define POSIX_FADV_DONTNEED 4
int posix_fadvise(int fd, long offset, long len, int advice);

int sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                 void *newp, size_t newlen);

const char *getprogname(void);

#endif
