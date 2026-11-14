/* Extended attributes, which the console does not have.
 *
 * Foundation reads extended attributes on Linux to find quarantine flags and
 * similar. There is no equivalent on the Switch, and Foundation treats a
 * failure from fgetxattr as "this attribute is absent", which is the truthful
 * answer here.
 *
 * These are static inline rather than declared and defined in a C file: the
 * shim is header-only, so a plain declaration would leave the symbol
 * undefined and fail at link time, and a definition outside the header would
 * need somewhere to live in the module. Returning -1 and setting errno is
 * what the callers already handle -- returning success with an empty value
 * would claim the attribute exists.
 *
 * The signature follows glibc, including ssize_t, because Foundation
 * compares the result against -1.
 */
#ifndef SWITCH2_SYS_XATTR_H
#define SWITCH2_SYS_XATTR_H

#include <sys/types.h>
#include <errno.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline ssize_t fgetxattr(int fd, const char *name, void *value, size_t size) {
    (void)fd;
    (void)name;
    (void)value;
    (void)size;
    errno = ENOTSUP;
    return -1;
}

static inline ssize_t getxattr(const char *path, const char *name, void *value, size_t size) {
    (void)path;
    (void)name;
    (void)value;
    (void)size;
    errno = ENOTSUP;
    return -1;
}

/* The l* forms follow symlinks differently: they act on the link itself. On a
 * filesystem with no xattrs the distinction does not exist, so both answer
 * the same way. Foundation calls these two directly and calls the others
 * through this header, which is why they are here rather than in a separate
 * module: two declarations of the same C function make the call ambiguous in
 * Swift when both modules are imported. */
static inline ssize_t lgetxattr(const char *path, const char *name, void *value, size_t size) {
    return getxattr(path, name, value, size);
}

static inline int fsetxattr(int fd, const char *name, const void *value, size_t size, int flags) {
    (void)fd;
    (void)name;
    (void)value;
    (void)size;
    (void)flags;
    errno = ENOTSUP;
    return -1;
}

static inline int setxattr(const char *path, const char *name, const void *value, size_t size, int flags) {
    (void)path;
    (void)name;
    (void)value;
    (void)size;
    (void)flags;
    errno = ENOTSUP;
    return -1;
}

static inline int lsetxattr(const char *path, const char *name, const void *value, size_t size, int flags) {
    return setxattr(path, name, value, size, flags);
}

static inline int fremovexattr(int fd, const char *name) {
    (void)fd;
    (void)name;
    errno = ENOTSUP;
    return -1;
}

static inline int removexattr(const char *path, const char *name) {
    (void)path;
    (void)name;
    errno = ENOTSUP;
    return -1;
}

static inline ssize_t flistxattr(int fd, char *list, size_t size) {
    (void)fd;
    (void)list;
    (void)size;
    errno = ENOTSUP;
    return -1;
}

static inline ssize_t listxattr(const char *path, char *list, size_t size) {
    (void)path;
    (void)list;
    (void)size;
    errno = ENOTSUP;
    return -1;
}

#ifdef __cplusplus
}
#endif

#endif
