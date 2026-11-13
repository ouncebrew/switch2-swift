/* newlib has no sys/eventfd.h. The eventfd is emulated over a semaphore in
 * epoll_shim.c; the descriptor is a handle into a small table. */
#ifndef DISPATCH_SHIM_SYS_EVENTFD_H
#define DISPATCH_SHIM_SYS_EVENTFD_H

#include <stdint.h>

#define EFD_CLOEXEC 1
#define EFD_NONBLOCK 2

typedef uint64_t eventfd_t;

int eventfd(unsigned int initval, int flags);
int eventfd_read(int fd, eventfd_t *value);
int eventfd_write(int fd, eventfd_t value);

#endif
