/* newlib has no sys/timerfd.h. libdispatch uses timerfds for dispatch_source
 * timers; the emulation in epoll_shim.c backs them with the system tick. */
#ifndef DISPATCH_SHIM_SYS_TIMERFD_H
#define DISPATCH_SHIM_SYS_TIMERFD_H

#include <sys/timespec.h>

#define TFD_CLOEXEC 1
#define TFD_NONBLOCK 2
#define TFD_TIMER_ABSTIME 1

int timerfd_create(int clockid, int flags);
int timerfd_settime(int fd, int flags, const struct itimerspec *new_value,
                    struct itimerspec *old_value);
int timerfd_gettime(int fd, struct itimerspec *current_value);

#endif
