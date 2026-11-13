// C half of the Switch 2 Swift toolchain test suite.
//
// libdispatch and pthreads are C libraries, and the Swift Dispatch overlay is
// not built for this target, so these tests are written in C. They report
// through the callback that main.swift passes in, so everything lands in one
// log.
//
// This file also holds the pad shim: padInitializeDefault and padGetButtonsDown
// are inline in the libnx headers and have no symbol to bind to from Swift.

#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <switch.h>

typedef void (*report_fn)(const char *name, int ok, const char *detail);

static report_fn g_report;

static void report(const char *name, int ok, const char *detail) {
    if (g_report) g_report(name, ok, detail);
}

static char g_detail[160];

static void pass(const char *name) {
    report(name, 1, "");
}

static void fail(const char *name, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(g_detail, sizeof(g_detail), fmt, args);
    va_end(args);
    report(name, 0, g_detail);
}

//---------------------------------------------------------------------------------
// Pad shim
//---------------------------------------------------------------------------------

static PadState g_pad;

void testpad_init(void) {
    padInitializeDefault(&g_pad);
}

bool testpad_plus_pressed(void) {
    padUpdate(&g_pad);
    return (padGetButtonsDown(&g_pad) & HidNpadButton_Plus) != 0;
}

//---------------------------------------------------------------------------------
// libdispatch
//---------------------------------------------------------------------------------

static void test_dispatch_sync(void) {
    const char *name = "dispatch/sync";
    __block int ran = 0;
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_sync(queue, ^{
        ran = 1;
    });
    if (ran == 1) pass(name);
    else fail(name, "block did not run before dispatch_sync returned");
}

static void test_dispatch_async(void) {
    const char *name = "dispatch/async";
    __block int ran = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    dispatch_async(queue, ^{
        ran = 1;
        dispatch_semaphore_signal(done);
    });

    long waited = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (waited != 0) fail(name, "block never signalled within 5s");
    else if (ran != 1) fail(name, "block ran but did not set the flag");
    else pass(name);

    dispatch_release(done);
}

static void test_dispatch_serial_order(void) {
    const char *name = "dispatch/serial-order";
    static int order[8];
    static int count = 0;
    count = 0;

    dispatch_queue_t queue = dispatch_queue_create("test.serial", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    for (int i = 0; i < 8; i++) {
        dispatch_async(queue, ^{
            order[count++] = i;
            if (count == 8) dispatch_semaphore_signal(done);
        });
    }

    long waited = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (waited != 0) {
        fail(name, "only %d of 8 blocks ran within 5s", count);
    } else {
        int bad = -1;
        for (int i = 0; i < 8; i++) {
            if (order[i] != i) { bad = i; break; }
        }
        if (bad >= 0) fail(name, "block %d ran out of order (saw %d)", bad, order[bad]);
        else pass(name);
    }

    dispatch_release(done);
    dispatch_release(queue);
}

static void test_dispatch_concurrent(void) {
    const char *name = "dispatch/concurrent";
    static int counter = 0;
    counter = 0;

    dispatch_queue_t queue = dispatch_queue_create("test.concurrent", DISPATCH_QUEUE_CONCURRENT);
    dispatch_group_t group = dispatch_group_create();

    for (int i = 0; i < 16; i++) {
        dispatch_group_async(group, queue, ^{
            __atomic_fetch_add(&counter, 1, __ATOMIC_SEQ_CST);
        });
    }

    long waited = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (waited != 0) fail(name, "group did not finish within 5s (counter=%d)", counter);
    else if (counter != 16) fail(name, "expected 16 increments, got %d", counter);
    else pass(name);

    dispatch_release(group);
    dispatch_release(queue);
}

static void test_dispatch_group(void) {
    const char *name = "dispatch/group";
    static int counter = 0;
    counter = 0;

    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_group_t group = dispatch_group_create();

    for (int i = 0; i < 8; i++) {
        dispatch_group_async(group, queue, ^{
            __atomic_fetch_add(&counter, 1, __ATOMIC_SEQ_CST);
        });
    }

    long waited = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (waited != 0) fail(name, "group wait timed out (counter=%d)", counter);
    else if (counter != 8) fail(name, "expected 8, got %d", counter);
    else pass(name);

    dispatch_release(group);
}

static void test_dispatch_group_enter_leave(void) {
    const char *name = "dispatch/group-enter-leave";
    static int counter = 0;
    counter = 0;

    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_group_t group = dispatch_group_create();

    for (int i = 0; i < 4; i++) {
        dispatch_group_enter(group);
        dispatch_async(queue, ^{
            __atomic_fetch_add(&counter, 1, __ATOMIC_SEQ_CST);
            dispatch_group_leave(group);
        });
    }

    long waited = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (waited != 0) fail(name, "group wait timed out (counter=%d)", counter);
    else if (counter != 4) fail(name, "expected 4, got %d", counter);
    else pass(name);

    dispatch_release(group);
}

static void test_dispatch_semaphore(void) {
    const char *name = "dispatch/semaphore";
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    dispatch_async(queue, ^{
        dispatch_semaphore_signal(sem);
    });

    long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (waited != 0) fail(name, "wait timed out");
    else pass(name);

    dispatch_release(sem);
}

static void test_dispatch_after(void) {
    const char *name = "dispatch/after";
    __block int fired = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), queue, ^{
        fired = 1;
        dispatch_semaphore_signal(done);
    });

    long waited = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (waited != 0) fail(name, "timer never fired within 5s");
    else if (fired != 1) fail(name, "timer fired but did not set the flag");
    else pass(name);

    dispatch_release(done);
}

static void test_dispatch_apply(void) {
    const char *name = "dispatch/apply";
    static int hits[32];
    memset(hits, 0, sizeof(hits));

    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_apply(32, queue, ^(size_t index) {
        hits[index] = 1;
    });

    int missing = 0;
    for (int i = 0; i < 32; i++) {
        if (!hits[i]) missing++;
    }

    if (missing) fail(name, "%d of 32 indices were never visited", missing);
    else pass(name);
}

static void test_dispatch_barrier(void) {
    const char *name = "dispatch/barrier";
    static int before = 0;
    static int barrier_saw = -1;
    before = 0;
    barrier_saw = -1;

    dispatch_queue_t queue = dispatch_queue_create("test.barrier", DISPATCH_QUEUE_CONCURRENT);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    for (int i = 0; i < 8; i++) {
        dispatch_async(queue, ^{
            __atomic_fetch_add(&before, 1, __ATOMIC_SEQ_CST);
        });
    }

    dispatch_barrier_async(queue, ^{
        barrier_saw = __atomic_load_n(&before, __ATOMIC_SEQ_CST);
        dispatch_semaphore_signal(done);
    });

    long waited = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (waited != 0) fail(name, "barrier never ran within 5s");
    else if (barrier_saw != 8) fail(name, "barrier saw %d of 8 prior blocks", barrier_saw);
    else pass(name);

    dispatch_release(done);
    dispatch_release(queue);
}

static void test_dispatch_once(void) {
    const char *name = "dispatch/once";
    static dispatch_once_t once;
    static int runs = 0;

    for (int i = 0; i < 10; i++) {
        dispatch_once(&once, ^{
            runs++;
        });
    }

    if (runs != 1) fail(name, "block ran %d times, expected 1", runs);
    else pass(name);
}

static void test_dispatch_specific(void) {
    const char *name = "dispatch/specific";
    static int marker = 1234;

    dispatch_queue_t queue = dispatch_queue_create("test.specific", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(queue, "test.key", &marker, NULL);

    __block int seen = 0;
    dispatch_sync(queue, ^{
        int *value = dispatch_get_specific("test.key");
        seen = value ? *value : -1;
    });

    if (seen != 1234) fail(name, "queue-specific value was %d, expected 1234", seen);
    else pass(name);

    dispatch_release(queue);
}

static void test_dispatch_label(void) {
    const char *name = "dispatch/label";
    dispatch_queue_t queue = dispatch_queue_create("test.label", DISPATCH_QUEUE_SERIAL);
    const char *label = dispatch_queue_get_label(queue);

    if (!label) fail(name, "label was NULL");
    else if (strcmp(label, "test.label") != 0) fail(name, "label was \"%s\"", label);
    else pass(name);

    dispatch_release(queue);
}

void run_dispatch_tests(report_fn report_callback) {
    g_report = report_callback;

    test_dispatch_sync();
    test_dispatch_async();
    test_dispatch_serial_order();
    test_dispatch_concurrent();
    test_dispatch_group();
    test_dispatch_group_enter_leave();
    test_dispatch_semaphore();
    test_dispatch_after();
    test_dispatch_apply();
    test_dispatch_barrier();
    test_dispatch_once();
    test_dispatch_specific();
    test_dispatch_label();
}

//---------------------------------------------------------------------------------
// pthreads
//---------------------------------------------------------------------------------

static void *thread_return_value(void *arg) {
    return (void *)((intptr_t)arg * 2);
}

static void test_pthread_create_join(void) {
    const char *name = "pthread/create-join";
    pthread_t thread;
    int rc = pthread_create(&thread, NULL, thread_return_value, (void *)21);

    if (rc != 0) {
        fail(name, "pthread_create returned %d", rc);
        return;
    }

    void *result = NULL;
    rc = pthread_join(thread, &result);
    if (rc != 0) fail(name, "pthread_join returned %d", rc);
    else if ((intptr_t)result != 42) fail(name, "thread returned %ld, expected 42", (long)(intptr_t)result);
    else pass(name);
}

static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
static int g_shared_counter = 0;

static void *increment_worker(void *arg) {
    (void)arg;
    for (int i = 0; i < 1000; i++) {
        pthread_mutex_lock(&g_mutex);
        g_shared_counter++;
        pthread_mutex_unlock(&g_mutex);
    }
    return NULL;
}

static void test_pthread_mutex(void) {
    const char *name = "pthread/mutex";
    enum { THREADS = 4 };
    pthread_t threads[THREADS];

    g_shared_counter = 0;

    for (int i = 0; i < THREADS; i++) {
        if (pthread_create(&threads[i], NULL, increment_worker, NULL) != 0) {
            fail(name, "pthread_create failed for thread %d", i);
            return;
        }
    }

    for (int i = 0; i < THREADS; i++) {
        pthread_join(threads[i], NULL);
    }

    if (g_shared_counter != THREADS * 1000) {
        fail(name, "counter is %d, expected %d", g_shared_counter, THREADS * 1000);
    } else {
        pass(name);
    }
}

static pthread_mutex_t g_cond_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cond = PTHREAD_COND_INITIALIZER;
static int g_ready = 0;

static void *cond_worker(void *arg) {
    (void)arg;
    pthread_mutex_lock(&g_cond_mutex);
    g_ready = 1;
    pthread_cond_signal(&g_cond);
    pthread_mutex_unlock(&g_cond_mutex);
    return NULL;
}

static void test_pthread_condvar(void) {
    const char *name = "pthread/condvar";
    pthread_t thread;

    g_ready = 0;

    if (pthread_create(&thread, NULL, cond_worker, NULL) != 0) {
        fail(name, "pthread_create failed");
        return;
    }

    pthread_mutex_lock(&g_cond_mutex);
    while (!g_ready) {
        pthread_cond_wait(&g_cond, &g_cond_mutex);
    }
    pthread_mutex_unlock(&g_cond_mutex);

    pthread_join(thread, NULL);

    if (!g_ready) fail(name, "condition was never signalled");
    else pass(name);
}

static pthread_key_t g_tls_key;
static int g_tls_ok = 1;

static void *tls_worker(void *arg) {
    intptr_t value = (intptr_t)arg;
    pthread_setspecific(g_tls_key, (void *)value);

    // Yield a little so the other thread has a chance to clobber a shared slot
    // if the implementation is not really per-thread.
    for (volatile int i = 0; i < 10000; i++) {
    }

    if ((intptr_t)pthread_getspecific(g_tls_key) != value) {
        g_tls_ok = 0;
    }
    return NULL;
}

static void test_pthread_tls(void) {
    const char *name = "pthread/tls";

    if (pthread_key_create(&g_tls_key, NULL) != 0) {
        fail(name, "pthread_key_create failed");
        return;
    }

    g_tls_ok = 1;

    pthread_t a, b;
    if (pthread_create(&a, NULL, tls_worker, (void *)111) != 0 ||
        pthread_create(&b, NULL, tls_worker, (void *)222) != 0) {
        fail(name, "pthread_create failed");
        return;
    }

    pthread_join(a, NULL);
    pthread_join(b, NULL);

    if (!g_tls_ok) fail(name, "thread-local value was not per-thread");
    else pass(name);
}

void run_thread_tests(report_fn report_callback) {
    g_report = report_callback;

    test_pthread_create_join();
    test_pthread_mutex();
    test_pthread_condvar();
    test_pthread_tls();
}
