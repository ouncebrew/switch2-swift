/* SPDX-License-Identifier: MIT
 *
 * Stubs for libdispatch on Switch 2.
 *
 * These cover the parts of libdispatch that cannot work on the console:
 * dispatch I/O and disk sources need a descriptor table, the workqueue
 * registration hooks are for pthread workqueues, and the block runtime
 * helpers come from the Swift overlay. The symbols are defined so the library
 * links; calling the corresponding APIs reports failure rather than crashing.
 */
#include "internal.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*---------------------------------------------------------------------------------
 * Process name
 *---------------------------------------------------------------------------------*/
const char *getprogname(void) {
    return "dispatch";
}

/*---------------------------------------------------------------------------------
 * Signals
 *---------------------------------------------------------------------------------*/
int pthread_kill(pthread_t thread, int signal_number) {
    (void)thread;
    (void)signal_number;
    return 0;
}

/*---------------------------------------------------------------------------------
 * Workqueue registration
 *
 * The console has no pthread workqueues; libdispatch runs its own worker
 * threads through pthread_create.
 *---------------------------------------------------------------------------------*/
void _dispatch_workq_worker_register(dispatch_queue_global_t root_q) {
    (void)root_q;
}

void _dispatch_workq_worker_unregister(dispatch_queue_global_t root_q) {
    (void)root_q;
}

/*---------------------------------------------------------------------------------
 * Blocks
 *
 * The block runtime helpers live in the Swift overlay, which is not built.
 *---------------------------------------------------------------------------------*/
void _dispatch_block_special_invoke_stub(void *block) {
    (void)block;
}

void (*const _dispatch_block_special_invoke)(void *) =
    _dispatch_block_special_invoke_stub;

dispatch_block_t _dispatch_block_create(dispatch_block_flags_t flags,
                                        voucher_t voucher,
                                        pthread_priority_t priority,
                                        dispatch_block_t block) {
    (void)flags;
    (void)voucher;
    (void)priority;
    return block;
}

/*---------------------------------------------------------------------------------
 * Vouchers
 *
 * Vouchers are a mach feature. The console has none, so the hooks are empty.
 *---------------------------------------------------------------------------------*/
void _voucher_init(void) {}

void _voucher_atfork_child(void) {}

void _voucher_thread_cleanup(void *voucher) {
    (void)voucher;
}
