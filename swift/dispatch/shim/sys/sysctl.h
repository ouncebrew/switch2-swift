/* newlib has no sys/sysctl.h. libdispatch only calls sysctlbyname to read the
 * CPU count, and the console reports that through sysconf instead. */
#ifndef DISPATCH_SHIM_SYS_SYSCTL_H
#define DISPATCH_SHIM_SYS_SYSCTL_H

#include <stddef.h>

int sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                 void *newp, size_t newlen);

#endif
