/* newlib has no sys/syscall.h. Only SYS_futex is used, and it is emulated. */
#ifndef DISPATCH_SHIM_SYS_SYSCALL_H
#define DISPATCH_SHIM_SYS_SYSCALL_H

#define SYS_futex 98
#define SYS_gettid 178

long syscall(long number, ...);

#endif
