/* SPDX-License-Identifier: MIT
 *
 * epoll, eventfd and timerfd emulation for libdispatch on Switch 2.
 *
 * libdispatch's Linux event backend drives its manager thread from an epoll
 * set that holds two kinds of descriptor: one eventfd that other threads
 * write to wake the manager, and one timerfd per clock that the manager arms
 * for the next timer deadline. The console has none of the three, so all of
 * them are emulated here in userspace:
 *
 * - An eventfd is a counter plus a semaphore, identified by a handle.
 * - A timerfd is an absolute deadline, identified by a handle.
 * - An epoll set is a list of registered handles plus a wakeup semaphore.
 *
 * epoll_wait scans every registered handle for readiness and, when none is
 * ready, sleeps on the set's semaphore until a write arrives or the earliest
 * armed timer expires. Waiting on only the first registered descriptor is not
 * enough: the manager eventfd is registered first and the timerfd second, so
 * a timer wakeup would be lost.
 *
 * Dispatch sources that watch real file descriptors cannot work, because the
 * console has no descriptor table. Queues, timers and the manager thread do.
 */
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#include <semaphore.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>

#include <switch/arm/counter.h>

#define EVENTFD_MAX 16
#define TIMERFD_MAX 8
#define EPOLL_MAX 8
#define EPOLL_MAX_FDS 16

#define EVENTFD_HANDLE_BASE 0x1000
#define EPOLL_HANDLE_BASE 0x2000
#define TIMERFD_HANDLE_BASE 0x3000

typedef struct {
    int in_use;
    uint64_t counter;
    sem_t semaphore;
} eventfd_slot_t;

typedef struct {
    int in_use;
    int armed;
    uint64_t deadline_ns;
} timerfd_slot_t;

typedef struct {
    int in_use;
    int fds[EPOLL_MAX_FDS];
    struct epoll_event events[EPOLL_MAX_FDS];
    int count;
    sem_t wakeup;
} epoll_slot_t;

static eventfd_slot_t eventfds[EVENTFD_MAX];
static timerfd_slot_t timerfds[TIMERFD_MAX];
static epoll_slot_t epolls[EPOLL_MAX];

static uint64_t platform_now_ns(void) {
    uint64_t frequency = armGetSystemTickFreq();
    uint64_t ticks;

    if (frequency == 0) {
        return 0;
    }

    ticks = armGetSystemTick();

    /* Divide before multiplying. ticks * 1e9 overflows after about sixteen
     * minutes at 19.2 MHz, and the console may have been up for hours before
     * the program starts, so the product is not safe to form. */
    return (ticks / frequency) * 1000000000ULL +
           ((ticks % frequency) * 1000000000ULL) / frequency;
}

static eventfd_slot_t *eventfd_slot(int fd) {
    int index = fd - EVENTFD_HANDLE_BASE;

    if (index < 0 || index >= EVENTFD_MAX || !eventfds[index].in_use) {
        return NULL;
    }
    return &eventfds[index];
}

static timerfd_slot_t *timerfd_slot(int fd) {
    int index = fd - TIMERFD_HANDLE_BASE;

    if (index < 0 || index >= TIMERFD_MAX || !timerfds[index].in_use) {
        return NULL;
    }
    return &timerfds[index];
}

static epoll_slot_t *epoll_slot(int epfd) {
    int index = epfd - EPOLL_HANDLE_BASE;

    if (index < 0 || index >= EPOLL_MAX || !epolls[index].in_use) {
        return NULL;
    }
    return &epolls[index];
}

/* Wakes every epoll set that has this descriptor registered. */
static void epoll_notify(int fd) {
    for (int index = 0; index < EPOLL_MAX; index++) {
        epoll_slot_t *slot = &epolls[index];

        if (!slot->in_use) {
            continue;
        }

        for (int position = 0; position < slot->count; position++) {
            if (slot->fds[position] == fd) {
                sem_post(&slot->wakeup);
                break;
            }
        }
    }
}

/*---------------------------------------------------------------------------------
 * eventfd
 *---------------------------------------------------------------------------------*/
int eventfd(unsigned int initval, int flags) {
    (void)flags;

    for (int index = 0; index < EVENTFD_MAX; index++) {
        if (eventfds[index].in_use) {
            continue;
        }

        eventfds[index].in_use = 1;
        eventfds[index].counter = initval;
        if (sem_init(&eventfds[index].semaphore, 0, 0) != 0) {
            eventfds[index].in_use = 0;
            return -1;
        }
        return EVENTFD_HANDLE_BASE + index;
    }

    errno = EMFILE;
    return -1;
}

int eventfd_write(int fd, eventfd_t value) {
    eventfd_slot_t *slot = eventfd_slot(fd);

    if (slot == NULL) {
        errno = EBADF;
        return -1;
    }

    slot->counter += value;
    sem_post(&slot->semaphore);
    epoll_notify(fd);
    return 0;
}

int eventfd_read(int fd, eventfd_t *value) {
    eventfd_slot_t *slot = eventfd_slot(fd);

    if (slot == NULL || value == NULL) {
        errno = EBADF;
        return -1;
    }

    while (sem_wait(&slot->semaphore) != 0) {
        if (errno != EINTR) {
            return -1;
        }
    }

    *value = slot->counter;
    slot->counter = 0;
    return 0;
}

/*---------------------------------------------------------------------------------
 * timerfd
 *---------------------------------------------------------------------------------*/
int timerfd_create(int clockid, int flags) {
    (void)clockid;
    (void)flags;

    for (int index = 0; index < TIMERFD_MAX; index++) {
        if (timerfds[index].in_use) {
            continue;
        }

        timerfds[index].in_use = 1;
        timerfds[index].armed = 0;
        timerfds[index].deadline_ns = 0;
        return TIMERFD_HANDLE_BASE + index;
    }

    errno = EMFILE;
    return -1;
}

int timerfd_gettime(int fd, struct itimerspec *current_value) {
    timerfd_slot_t *slot = timerfd_slot(fd);

    if (slot == NULL || current_value == NULL) {
        errno = EINVAL;
        return -1;
    }

    memset(current_value, 0, sizeof(*current_value));

    if (slot->armed) {
        uint64_t now = platform_now_ns();
        uint64_t remaining =
            slot->deadline_ns > now ? slot->deadline_ns - now : 0;

        current_value->it_value.tv_sec = (time_t)(remaining / 1000000000ULL);
        current_value->it_value.tv_nsec = (long)(remaining % 1000000000ULL);
    }
    return 0;
}

int timerfd_settime(int fd, int flags, const struct itimerspec *new_value,
                    struct itimerspec *old_value) {
    timerfd_slot_t *slot = timerfd_slot(fd);
    uint64_t value;

    if (slot == NULL || new_value == NULL) {
        errno = EINVAL;
        return -1;
    }

    if (old_value != NULL) {
        timerfd_gettime(fd, old_value);
    }

    if (new_value->it_value.tv_sec == 0 && new_value->it_value.tv_nsec == 0) {
        slot->armed = 0;
        slot->deadline_ns = 0;
        return 0;
    }

    value = (uint64_t)new_value->it_value.tv_sec * 1000000000ULL +
            (uint64_t)new_value->it_value.tv_nsec;

    slot->deadline_ns =
        (flags & TFD_TIMER_ABSTIME) ? value : platform_now_ns() + value;
    slot->armed = 1;
    return 0;
}

/*---------------------------------------------------------------------------------
 * epoll
 *---------------------------------------------------------------------------------*/
int epoll_create(int size) {
    (void)size;
    return epoll_create1(0);
}

int epoll_create1(int flags) {
    (void)flags;

    for (int index = 0; index < EPOLL_MAX; index++) {
        if (epolls[index].in_use) {
            continue;
        }

        epolls[index].in_use = 1;
        epolls[index].count = 0;
        if (sem_init(&epolls[index].wakeup, 0, 0) != 0) {
            epolls[index].in_use = 0;
            return -1;
        }
        return EPOLL_HANDLE_BASE + index;
    }

    errno = EMFILE;
    return -1;
}

int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event) {
    epoll_slot_t *slot = epoll_slot(epfd);

    if (slot == NULL) {
        errno = EBADF;
        return -1;
    }

    int position = -1;
    for (int index = 0; index < slot->count; index++) {
        if (slot->fds[index] == fd) {
            position = index;
            break;
        }
    }

    switch (op) {
    case EPOLL_CTL_ADD:
        if (position != -1) {
            errno = EEXIST;
            return -1;
        }
        if (slot->count == EPOLL_MAX_FDS) {
            errno = ENOSPC;
            return -1;
        }
        slot->fds[slot->count] = fd;
        slot->events[slot->count] = *event;
        slot->count++;
        return 0;

    case EPOLL_CTL_MOD:
        if (position == -1) {
            errno = ENOENT;
            return -1;
        }
        slot->events[position] = *event;
        return 0;

    case EPOLL_CTL_DEL:
        if (position == -1) {
            errno = ENOENT;
            return -1;
        }
        slot->fds[position] = slot->fds[slot->count - 1];
        slot->events[position] = slot->events[slot->count - 1];
        slot->count--;
        return 0;

    default:
        errno = EINVAL;
        return -1;
    }
}

/* Reports one registered descriptor if it is ready. A timerfd is disarmed as
 * it is reported, which is the EPOLLONESHOT behaviour libdispatch asks for:
 * the manager re-arms it with timerfd_settime and EPOLL_CTL_MOD. */
static int epoll_check(int fd, const struct epoll_event *registration,
                       struct epoll_event *out) {
    eventfd_slot_t *event = eventfd_slot(fd);

    if (event != NULL) {
        if (event->counter == 0) {
            return 0;
        }
        out->events = registration->events & EPOLLIN;
        out->data = registration->data;
        return 1;
    }

    timerfd_slot_t *timer = timerfd_slot(fd);

    if (timer != NULL) {
        if (!timer->armed || timer->deadline_ns > platform_now_ns()) {
            return 0;
        }
        out->events = registration->events & EPOLLIN;
        out->data = registration->data;
        timer->armed = 0;
        return 1;
    }

    return 0;
}

int epoll_wait(int epfd, struct epoll_event *events, int maxevents,
               int timeout) {
    epoll_slot_t *slot = epoll_slot(epfd);
    uint64_t caller_deadline;

    if (slot == NULL || events == NULL || maxevents <= 0) {
        errno = EINVAL;
        return -1;
    }

    if (slot->count == 0) {
        errno = EINVAL;
        return -1;
    }

    caller_deadline = (timeout < 0)
                          ? UINT64_MAX
                          : platform_now_ns() + (uint64_t)timeout * 1000000ULL;

    for (;;) {
        int reported = 0;

        for (int index = 0; index < slot->count && reported < maxevents;
             index++) {
            if (epoll_check(slot->fds[index], &slot->events[index],
                            &events[reported])) {
                reported++;
            }
        }

        if (reported > 0) {
            return reported;
        }

        uint64_t now = platform_now_ns();

        if (now >= caller_deadline) {
            return 0;
        }

        /* Sleep until a descriptor is written or the earliest armed timer
         * expires, whichever comes first. */
        uint64_t wait_ns = caller_deadline - now;

        for (int index = 0; index < slot->count; index++) {
            timerfd_slot_t *timer = timerfd_slot(slot->fds[index]);

            if (timer == NULL || !timer->armed) {
                continue;
            }

            uint64_t remaining =
                timer->deadline_ns > now ? timer->deadline_ns - now : 0;

            if (remaining < wait_ns) {
                wait_ns = remaining;
            }
        }

        if (wait_ns == UINT64_MAX) {
            while (sem_wait(&slot->wakeup) != 0) {
                if (errno != EINTR) {
                    return -1;
                }
            }
            continue;
        }

        struct timespec deadline;
        uint64_t target = now + wait_ns;

        deadline.tv_sec = (time_t)(target / 1000000000ULL);
        deadline.tv_nsec = (long)(target % 1000000000ULL);

        if (sem_timedwait(&slot->wakeup, &deadline) != 0) {
            if (errno == ETIMEDOUT) {
                /* Either a timer expired or the caller's timeout ran out.
                 * Both are handled by the next pass. */
                continue;
            }
            return -1;
        }
    }
}
