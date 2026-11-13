/* SPDX-License-Identifier: MIT
 *
 * C library functions that libdispatch calls but newlib does not implement.
 *
 * newlib declares most of these in its headers and leaves them unimplemented,
 * because they need a kernel. The console has no descriptor table, no signals
 * and no memory mapping, so the ones that need those report failure and the
 * rest are answered from the system tick or a constant.
 */
#include <errno.h>
#include <malloc.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <sys/signalfd.h>
#include <sys/timerfd.h>

/*---------------------------------------------------------------------------------
 * Memory
 *---------------------------------------------------------------------------------*/
int posix_memalign(void **memptr, size_t alignment, size_t size) {
    void *block = memalign(alignment, size);

    if (block == NULL) {
        return ENOMEM;
    }

    *memptr = block;
    return 0;
}

int getpagesize(void) {
    return 4096;
}

/*---------------------------------------------------------------------------------
 * Files
 *
 * The console has no descriptor table, so positional I/O and advisory calls
 * report failure.
 *---------------------------------------------------------------------------------*/
ssize_t pread(int fd, void *buffer, size_t count, off_t offset) {
    (void)fd;
    (void)buffer;
    (void)count;
    (void)offset;
    errno = ENOSYS;
    return -1;
}

ssize_t pwrite(int fd, const void *buffer, size_t count, off_t offset) {
    (void)fd;
    (void)buffer;
    (void)count;
    (void)offset;
    errno = ENOSYS;
    return -1;
}

int posix_fadvise(int fd, off_t offset, off_t length, int advice) {
    (void)fd;
    (void)offset;
    (void)length;
    (void)advice;
    return 0;
}

/*---------------------------------------------------------------------------------
 * Signals
 *
 * There is no signal delivery. The calls succeed so that libdispatch's
 * initialisation completes, and nothing is ever delivered.
 *---------------------------------------------------------------------------------*/
int sigaction(int signal_number, const struct sigaction *action,
              struct sigaction *old_action) {
    (void)signal_number;
    (void)action;
    (void)old_action;
    return 0;
}

int pthread_sigmask(int how, const sigset_t *set, sigset_t *old_set) {
    (void)how;
    (void)set;
    (void)old_set;
    return 0;
}

int sigsuspend(const sigset_t *mask) {
    (void)mask;
    errno = EINTR;
    return -1;
}

int signalfd(int fd, const sigset_t *mask, int flags) {
    (void)fd;
    (void)mask;
    (void)flags;
    errno = ENOSYS;
    return -1;
}

/* Timers live in epoll_shim.c, next to the epoll set that waits on them. */

/*---------------------------------------------------------------------------------
 * Logging
 *---------------------------------------------------------------------------------*/
void vsyslog(int priority, const char *format, va_list ap) {
    (void)priority;
    (void)format;
    (void)ap;
}

void syslog(int priority, const char *format, ...) {
    (void)priority;
    (void)format;
}

/*---------------------------------------------------------------------------------
 * Sockets and device control
 *
 * The console has no sockets and no device nodes. libdispatch asks whether a
 * descriptor is a listening socket and how much data is queued; both answers
 * are "none".
 *---------------------------------------------------------------------------------*/
int getsockopt(int socket, int level, int option_name, void *option_value,
               socklen_t *option_len) {
    (void)socket;
    (void)level;
    (void)option_name;
    (void)option_value;
    (void)option_len;
    errno = ENOSYS;
    return -1;
}

int ioctl(int fd, unsigned long request, ...) {
    (void)fd;
    (void)request;
    errno = ENOSYS;
    return -1;
}
