/* The parts of the shim that need a definition rather than a declaration.
 *
 * errno is the reason this file exists. newlib declares it as a macro over
 * __errno(), and Swift cannot use the macro; it reports "macro 'errno'
 * unavailable: structure not supported" and never looks for a name of its own.
 * Declaring a variable called errno in a header does not help either, because
 * the macro rewrites that declaration before the compiler sees it.
 *
 * A definition in a .c file is out of the macro's reach: <errno.h> is included
 * here for __errno(), and this file then defines a variable of its own with
 * the same name and the same storage. Swift imports it as `errno` of type
 * Int32, which is what Foundation's reads expect.
 *
 * A pointer rather than a plain int: errno must track whatever the last failed
 * call set, and a copy would freeze at its initial value. The getter keeps
 * that true for reads, and errno_set covers the few places that clear it.
 *
 * Every other declaration in Glibc.h is static inline in a header, which is
 * all that is needed to call it. This is the one case where a symbol has to
 * exist, because a variable has to live somewhere.
 */
#include <errno.h>
#include <grp.h>
#include <pwd.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <unistd.h>

/* Extended attributes live in <sys/xattr.h>, which is a header of this shim
 * and is included by Foundation's own C shims. There is nothing to define
 * here. */

/* ---- The POSIX calls newlib declares but devkitPro does not link ---------
 *
 * newlib's headers describe a full POSIX environment, but the console is not
 * one: there are no user accounts, no host name service and no chown. The
 * declarations are enough for Foundation to compile; the definitions below
 * are what let it link, and they answer the way a console should.
 *
 * getuid and friends return 0, which is what a process with no account is.
 * The passwd and group lookups return ENOENT with a null result, which
 * Foundation already treats as "no such user" and falls back from.
 */

uid_t getuid(void) { return 0; }
uid_t geteuid(void) { return 0; }
gid_t getgid(void) { return 0; }
gid_t getegid(void) { return 0; }

int chown(const char *path, uid_t owner, gid_t group) {
    (void)path;
    (void)owner;
    (void)group;
    errno = ENOTSUP;
    return -1;
}

long sysconf(int name) {
    switch (name) {
#ifdef _SC_PAGESIZE
    case _SC_PAGESIZE:
        return 4096;
#elif defined(_SC_PAGE_SIZE)
    case _SC_PAGE_SIZE:
        return 4096;
#endif
#ifdef _SC_GETPW_R_SIZE_MAX
    case _SC_GETPW_R_SIZE_MAX:
        return 4096;
#endif
#ifdef _SC_GETGR_R_SIZE_MAX
    case _SC_GETGR_R_SIZE_MAX:
        return 4096;
#endif
#ifdef _SC_PHYS_PAGES
    case _SC_PHYS_PAGES:
        return 0;
#endif
    default:
        return -1;
    }
}

int getpagesize(void) { return 4096; }

int gethostname(char *name, size_t length) {
    static const char host[] = "switch2";

    if (name == NULL || length == 0) {
        errno = EINVAL;
        return -1;
    }
    size_t copy = sizeof(host) - 1;
    if (copy >= length) {
        copy = length - 1;
    }
    memcpy(name, host, copy);
    name[copy] = '\0';
    return 0;
}

/* glibc's secure_getenv, which Foundation calls to read the environment
 * without trusting it when the process is set-user-ID. There is no setuid on
 * the console, so it is getenv. */
char *secure_getenv(const char *name) { return getenv(name); }

static int no_passwd_entry(struct passwd **result, char *buffer, size_t length) {
    (void)buffer;
    (void)length;
    if (result != NULL) {
        *result = NULL;
    }
    return ENOENT;
}

int getpwnam_r(const char *name, struct passwd *pwd, char *buffer,
               size_t length, struct passwd **result) {
    (void)name;
    (void)pwd;
    return no_passwd_entry(result, buffer, length);
}

int getpwuid_r(uid_t uid, struct passwd *pwd, char *buffer, size_t length,
               struct passwd **result) {
    (void)uid;
    (void)pwd;
    return no_passwd_entry(result, buffer, length);
}

static int no_group_entry(struct group **result, char *buffer, size_t length) {
    (void)buffer;
    (void)length;
    if (result != NULL) {
        *result = NULL;
    }
    return ENOENT;
}

int getgrnam_r(const char *name, struct group *grp, char *buffer,
               size_t length, struct group **result) {
    (void)name;
    (void)grp;
    return no_group_entry(result, buffer, length);
}

int getgrgid_r(gid_t gid, struct group *grp, char *buffer, size_t length,
               struct group **result) {
    (void)gid;
    (void)grp;
    return no_group_entry(result, buffer, length);
}

int *__switch_errno_address(void) {
    return __errno();
}

/* The file-type bits, with glibc's type rather than newlib's.
 *
 * Both spellings name the same values -- 0170000 for the mask, 0040000 for a
 * directory -- but newlib defines them as plain integer literals, which Swift
 * imports as Int32, while newlib's st_mode is mode_t and therefore UInt32.
 * Foundation writes the glibc idiom `st_mode & S_IFMT == S_IFDIR`, where
 * glibc's st_mode is Int32 and the comparison type-checks, so against newlib
 * it fails with "binary operator '&' cannot be applied to operands of type
 * 'mode_t' (aka 'UInt32') and 'Int32'".
 *
 * Defining them here as mode_t makes the whole expression UInt32 and it
 * type-checks unchanged. The macros are undefined in Glibc.h before these
 * declarations so that Swift sees the names.
 */
const mode_t SWITCH_S_IFMT = 0170000;
const mode_t SWITCH_S_IFDIR = 0040000;
const mode_t SWITCH_S_IFCHR = 0020000;
const mode_t SWITCH_S_IFBLK = 0060000;
const mode_t SWITCH_S_IFREG = 0100000;
const mode_t SWITCH_S_IFLNK = 0120000;
const mode_t SWITCH_S_IFSOCK = 0140000;
const mode_t SWITCH_S_IFIFO = 0010000;

/* S_ISVTX has the same problem as the S_IF bits: newlib spells it as an Int32
 * macro while st_mode is mode_t. Foundation's "can I delete this" check does
 * `st_mode & S_ISVTX`. */
const mode_t SWITCH_S_ISVTX = 0001000;

/* S_IWUSR, for the same reason: newlib's is an Int32 macro, st_mode and
 * mode_t(mode) are UInt32. Foundation tests `mode_t(mode) & S_IWUSR`. */
const mode_t SWITCH_S_IWUSR = 0200;

/* The clock ids, with newlib's clockid_t rather than its Int32 macros.
 *
 * Foundation passes CLOCK_MONOTONIC and CLOCK_REALTIME straight to
 * clock_gettime, whose newlib parameter is clockid_t (`unsigned long`). The
 * macros are Int32, so the call does not type-check; these constants give the
 * names the type the call expects. The numbers are newlib's own; the clock
 * implementation in swift_shim.c ignores the id and reads the system tick. */
const clockid_t SWITCH_CLOCK_REALTIME = 1;
const clockid_t SWITCH_CLOCK_MONOTONIC = 4;
const clockid_t SWITCH_CLOCK_MONOTONIC_RAW = 5;
