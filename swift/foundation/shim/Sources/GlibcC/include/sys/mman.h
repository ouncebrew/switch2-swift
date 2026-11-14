/* Memory mapping, which the console does not have.
 *
 * Foundation maps files into memory to avoid copying them: Data's
 * read-from-file path calls mmap with MAP_PRIVATE and reads through the
 * result. The Switch has no demand paging, so there is nothing to map, and
 * the honest answer is to fail. Foundation checks the result against
 * MAP_FAILED before using it and falls back to reading the file, so a
 * failure here costs a copy and nothing else.
 *
 * MAP_FAILED is (void *)-1 on every platform that has mmap, and the caller's
 * comparison depends on that, so it is defined the same way.
 *
 * As with xattr, these are static inline: the shim is header-only, and a
 * plain declaration would leave the symbol undefined at link time.
 */
#ifndef SWITCH2_SYS_MMAN_H
#define SWITCH2_SYS_MMAN_H

#include <sys/types.h>
#include <errno.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PROT_NONE  0x0
#define PROT_READ  0x1
#define PROT_WRITE 0x2
#define PROT_EXEC  0x4

#define MAP_SHARED    0x01
#define MAP_PRIVATE   0x02
#define MAP_FIXED     0x10
#define MAP_ANONYMOUS 0x20
#define MAP_ANON      MAP_ANONYMOUS

#define MAP_FAILED ((void *)-1)

static inline void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    (void)addr;
    (void)length;
    (void)prot;
    (void)flags;
    (void)fd;
    (void)offset;
    errno = ENOTSUP;
    return MAP_FAILED;
}

static inline int munmap(void *addr, size_t length) {
    (void)addr;
    (void)length;
    errno = ENOTSUP;
    return -1;
}

static inline int mprotect(void *addr, size_t len, int prot) {
    (void)addr;
    (void)len;
    (void)prot;
    errno = ENOTSUP;
    return -1;
}

#ifdef __cplusplus
}
#endif

#endif
