/* newlib has no linux/futex.h. The values match the Linux ABI so that
 * libdispatch's lock encoding is unchanged; the operations themselves are
 * emulated over pthread mutexes and condition variables in futex_shim.c. */
#ifndef DISPATCH_SHIM_LINUX_FUTEX_H
#define DISPATCH_SHIM_LINUX_FUTEX_H

#define FUTEX_WAIT 0
#define FUTEX_WAKE 1
#define FUTEX_LOCK_PI 6
#define FUTEX_UNLOCK_PI 7

#define FUTEX_PRIVATE_FLAG 128

#define FUTEX_TID_MASK 0x3fffffff
#define FUTEX_WAITERS 0x80000000
#define FUTEX_OWNER_DIED 0x40000000

#endif
