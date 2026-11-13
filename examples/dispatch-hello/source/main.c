// A Switch 2 program that uses libdispatch.
//
// The console has no descriptor table, so dispatch I/O and dispatch sources
// that watch file descriptors do not work. Queues, dispatch_async,
// dispatch_sync, dispatch_group, dispatch_after and semaphores do.

#include <dispatch/dispatch.h>
#include <stdio.h>

#include <switch.h>

static int total = 0;

int main(int argc, char **argv) {
    consoleInit(NULL);

    dispatch_queue_t queue = dispatch_get_global_queue(
        DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    printf("libdispatch on Switch 2\n");

    dispatch_sync(queue, ^{
        printf("dispatch_sync ran\n");
    });

    dispatch_group_t group = dispatch_group_create();
    for (int index = 1; index <= 4; index++) {
        dispatch_group_async(group, queue, ^{
            printf("task %d\n", index);
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    dispatch_release(group);

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    dispatch_async(queue, ^{
        total = 42;
        dispatch_semaphore_signal(semaphore);
    });
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    dispatch_release(semaphore);

    printf("total = %d\n", total);
    printf("done\n");

    consoleExit(NULL);
    return 0;
}
