/* newlib has no sys/signalfd.h. libdispatch uses it only to watch for
 * SIGINFO, which the console does not raise. */
#ifndef DISPATCH_SHIM_SYS_SIGNALFD_H
#define DISPATCH_SHIM_SYS_SIGNALFD_H

#include <signal.h>

#define SFD_CLOEXEC 1
#define SFD_NONBLOCK 2

struct signalfd_siginfo {
    unsigned int ssi_signo;
    int ssi_errno;
    int ssi_code;
    unsigned int ssi_pid;
    unsigned int ssi_uid;
    int ssi_fd;
    unsigned int ssi_tid;
    unsigned int ssi_band;
    unsigned int ssi_overrun;
    unsigned int ssi_trapno;
    int ssi_status;
    int ssi_int;
    unsigned long long ssi_ptr;
    unsigned long long ssi_utime;
    unsigned long long ssi_stime;
    unsigned long long ssi_addr;
    unsigned char pad[48];
};

int signalfd(int fd, const sigset_t *mask, int flags);

#endif
