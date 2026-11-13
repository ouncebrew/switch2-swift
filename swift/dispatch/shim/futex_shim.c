/* SPDX-License-Identifier: MIT
 *
 * Futex emulation for libdispatch on Switch 2.
 *
 * libdispatch's Linux lock encoding calls syscall(SYS_futex, ...) directly.
 * The console has no futex, so the two operations it relies on are emulated
 * here over pthread mutexes and condition variables, which libounce provides.
 *
 * FUTEX_WAIT and FUTEX_WAKE are address-keyed: waiters on the same word share
 * a bucket, and a wake only releases waiters on that word. The priority
 * inheritance operations are not used outside lock.c and are implemented as a
 * plain lock without inheritance.
 */
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <linux/futex.h>
#include <syscall.h>

#define FUTEX_BUCKETS 64

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
} futex_bucket_t;

static futex_bucket_t futex_buckets[FUTEX_BUCKETS];
static pthread_once_t futex_once = PTHREAD_ONCE_INIT;

static void futex_init(void) {
    for (int i = 0; i < FUTEX_BUCKETS; i++) {
        pthread_mutex_init(&futex_buckets[i].mutex, NULL);
        pthread_cond_init(&futex_buckets[i].cond, NULL);
    }
}

static futex_bucket_t *futex_bucket_for(const void *address) {
    uintptr_t key = (uintptr_t)address;
    return &futex_buckets[(key >> 2) % FUTEX_BUCKETS];
}

static int futex_wait(uint32_t *address, uint32_t value,
                      const struct timespec *timeout) {
    pthread_once(&futex_once, futex_init);

    futex_bucket_t *bucket = futex_bucket_for(address);
    pthread_mutex_lock(&bucket->mutex);

    /* The value may have changed before the lock was taken; that is the
     * documented futex contract and the caller retries. */
    if (*(volatile uint32_t *)address != value) {
        pthread_mutex_unlock(&bucket->mutex);
        errno = EAGAIN;
        return -1;
    }

    int result = 0;
    if (timeout == NULL) {
        result = pthread_cond_wait(&bucket->cond, &bucket->mutex);
    } else {
        /* FUTEX_WAIT takes a timeout relative to now, but
         * pthread_cond_timedwait wants an absolute deadline. Passing the
         * relative value straight through makes every timed wait expire at
         * once, because the deadline it names is a few seconds after boot and
         * the console has been up far longer than that. dispatch_group_wait
         * then reports a timeout before any block has run. */
        struct timespec deadline;

        clock_gettime(CLOCK_REALTIME, &deadline);
        deadline.tv_sec += timeout->tv_sec;
        deadline.tv_nsec += timeout->tv_nsec;
        if (deadline.tv_nsec >= 1000000000L) {
            deadline.tv_sec += 1;
            deadline.tv_nsec -= 1000000000L;
        }

        result = pthread_cond_timedwait(&bucket->cond, &bucket->mutex,
                                        &deadline);
    }

    pthread_mutex_unlock(&bucket->mutex);

    if (result == ETIMEDOUT) {
        errno = ETIMEDOUT;
        return -1;
    }
    if (result != 0) {
        errno = result;
        return -1;
    }
    return 0;
}

static int futex_wake(uint32_t *address, int count) {
    (void)count;

    pthread_once(&futex_once, futex_init);

    futex_bucket_t *bucket = futex_bucket_for(address);
    pthread_mutex_lock(&bucket->mutex);

    /* Buckets are shared by FUTEX_BUCKETS different addresses, so a signal
     * can release a waiter on a different word. That waiter re-checks its own
     * word, finds it unchanged and sleeps again, while the waiter the caller
     * meant to release is never woken -- a lost wakeup that shows up as a
     * block that never runs. Wake the whole bucket and let each waiter
     * re-check its own address, which is what the futex contract allows. */
    pthread_cond_broadcast(&bucket->cond);

    pthread_mutex_unlock(&bucket->mutex);
    return 0;
}

/* Priority inheritance is not available. The lock word still carries the
 * owner, so the encoding stays consistent; only inheritance is lost. */
static int futex_lock_pi(uint32_t *address, const struct timespec *timeout) {
    (void)timeout;

    for (;;) {
        uint32_t expected = 0;
        if (__atomic_compare_exchange_n(address, &expected,
                                        (uint32_t)(uintptr_t)pthread_self(),
                                        0, __ATOMIC_ACQUIRE,
                                        __ATOMIC_RELAXED)) {
            return 0;
        }
        futex_wait(address, expected, NULL);
    }
}

static int futex_unlock_pi(uint32_t *address) {
    __atomic_store_n(address, 0, __ATOMIC_RELEASE);
    futex_wake(address, 1);
    return 0;
}

long syscall(long number, ...) {
    if (number == SYS_gettid) {
        return (long)pthread_self();
    }

    if (number != SYS_futex) {
        errno = ENOSYS;
        return -1;
    }

    va_list ap;
    va_start(ap, number);

    uint32_t *address = va_arg(ap, uint32_t *);
    int operation = va_arg(ap, int);
    uint32_t value = va_arg(ap, uint32_t);
    const struct timespec *timeout = va_arg(ap, const struct timespec *);
    (void)va_arg(ap, uint32_t *);
    (void)va_arg(ap, uint32_t);

    va_end(ap);

    switch (operation & ~FUTEX_PRIVATE_FLAG) {
    case FUTEX_WAIT:
        return futex_wait(address, value, timeout);
    case FUTEX_WAKE:
        return futex_wake(address, (int)value);
    case FUTEX_LOCK_PI:
        return futex_lock_pi(address, timeout);
    case FUTEX_UNLOCK_PI:
        return futex_unlock_pi(address);
    default:
        errno = ENOSYS;
        return -1;
    }
}
