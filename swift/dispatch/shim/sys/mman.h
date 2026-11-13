/* newlib has no sys/mman.h. Only src/allocator.c uses mmap, and that source
 * is not built for this target. */
#ifndef DISPATCH_SHIM_SYS_MMAN_H
#define DISPATCH_SHIM_SYS_MMAN_H
#endif
