/* A Glibc-shaped face for devkitA64's newlib.
 *
 * Foundation and its dependencies import Glibc on Linux and Darwin on macOS,
 * and select between them with canImport(). A bare-metal target matches
 * neither, so none of those imports resolve and every C library call in
 * Foundation -- floor, labs, malloc, clock_gettime -- is unresolved.
 *
 * Rather than patch forty files, this module is named Glibc and re-exports
 * what newlib provides, so Foundation's existing `#elseif canImport(Glibc)`
 * arms select it. It is a shim in the same sense as the ones libdispatch
 * uses: it does not imitate glibc, it points at what the console has.
 */
#ifndef SWITCH2_GLIBC_SHIM_H
#define SWITCH2_GLIBC_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <time.h>
#include <errno.h>
#include <ctype.h>
#include <wchar.h>
#include <locale.h>
#include <signal.h>
#include <setjmp.h>
#include <limits.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/mman.h>
#include <pwd.h>
#include <grp.h>
#include <fts.h>

/* Constants whose spelling differs between newlib and glibc.
 *
 * Foundation's Linux branches use glibc's names and types. newlib's are close
 * but not identical, and the differences are of two kinds: a constant that
 * does not exist at all here, and a type that is unsigned where glibc's is
 * signed. Both are fixed by naming the value rather than by changing
 * Foundation.
 */
#ifndef MAP_FAILED
#define MAP_FAILED ((void *)-1)
#endif

/* ---- Clock ids ----------------------------------------------------------
 *
 * newlib declares CLOCK_MONOTONIC and friends as plain integer macros, which
 * Swift imports as Int32, but its clockid_t is `unsigned long` (UInt). Every
 * call of the form
 *
 *     clock_gettime(CLOCK_MONOTONIC, &ts)
 *
 * therefore fails with "cannot convert value of type 'Int32' to expected
 * argument type 'clockid_t'". The macros are undefined here and redefined as
 * clockid_t constants, which makes Foundation's call sites type-check
 * unchanged. The values are the console's own: clock_gettime in swift_shim.c
 * ignores the id and reads the system tick, so the numbers only have to be
 * distinct, and these are the conventional ones.
 *
 * The constants are named SWITCH_CLOCK_* in C and given the glibc names in
 * Sources/Glibc/Glibc.swift, because Swift does not expand macros.
 */
#undef CLOCK_REALTIME
#undef CLOCK_MONOTONIC
#undef CLOCK_MONOTONIC_RAW

extern const clockid_t SWITCH_CLOCK_REALTIME;
extern const clockid_t SWITCH_CLOCK_MONOTONIC;
extern const clockid_t SWITCH_CLOCK_MONOTONIC_RAW;

/* ---- Fixed-arity open ---------------------------------------------------
 *
 * Swift refuses to call a C variadic function: the error it reports is
 * "'open' is unavailable: Variadic function is unavailable". newlib declares
 *
 *     extern int open(const char *, int, ...);
 *
 * and Foundation calls it both ways -- `open(path, O_RDONLY)` in some places
 * and `open(path, O_WRONLY | O_CREAT, 0o666)` in others. Dropping either form
 * would break call sites.
 *
 * A wrapper is defined with the glibc three-argument signature and a
 * different name, and then given the name `open` by a macro. That works for
 * both languages: C expands the macro, and Swift, which does not expand
 * macros, sees the function through the module's export as __switch_open and
 * reaches it by that name.
 *
 * The swift_name attributes are what make Foundation's call sites work
 * unmodified. Swift does not read C macros, so the macro trick alone would
 * leave it seeing __switch_open2 and __switch_open3; swift_name gives each
 * the Swift name open(_:_:) and open(_:_:_:), which are different Swift
 * names and therefore overload legally. Swift's own call sites -- open(path,
 * flags) and open(path, flags, mode) -- then resolve to them, with no change
 * to Foundation at all.
 *
 * Newlib's variadic open is still declared, and Swift marks it unavailable.
 * An unavailable declaration does not take part in overload resolution, so it
 * does not make these ambiguous.
 */
static inline int __switch_open2(const char *path, int oflag)
    __attribute__((swift_name("open(_:_:)")));
static inline int __switch_open3(const char *path, int oflag, mode_t mode)
    __attribute__((swift_name("open(_:_:_:)")));

static inline int __switch_open2(const char *path, int oflag) {
    return open(path, oflag);
}

static inline int __switch_open3(const char *path, int oflag, mode_t mode) {
    return open(path, oflag, (int)mode);
}

/* Defined in shim.c. The address of newlib's errno, so that Swift can define
 * a computed property over it under the name errno; see shim.c for why a
 * definition is needed rather than another inline. */
int *__switch_errno_address(void);

/* The file-type bits, retyped for Swift. Undefining newlib's macros is what
 * makes the names visible: Swift cannot use a macro, but it imports a global
 * of the same name. The values are identical to newlib's; only the type
 * differs, and mode_t is what Foundation's expressions need. See shim.c. */
#undef S_IFMT
#undef S_ISVTX
#undef S_IFDIR
#undef S_IFCHR
#undef S_IFBLK
#undef S_IFREG
#undef S_IFLNK
#undef S_IFSOCK
#undef S_IFIFO

extern const mode_t SWITCH_S_IFMT;
extern const mode_t SWITCH_S_ISVTX;
extern const mode_t SWITCH_S_IWUSR;
extern const mode_t SWITCH_S_IFDIR;
extern const mode_t SWITCH_S_IFCHR;
extern const mode_t SWITCH_S_IFBLK;
extern const mode_t SWITCH_S_IFREG;
extern const mode_t SWITCH_S_IFLNK;
extern const mode_t SWITCH_S_IFSOCK;
extern const mode_t SWITCH_S_IFIFO;

/* Extended attributes are declared in <sys/xattr.h>, which is a header of this
 * shim rather than one from newlib. Foundation's own C shims include it, so
 * the names reach Swift through _FoundationCShims; declaring them here as well
 * would make every call ambiguous. */

#endif /* SWITCH2_GLIBC_SHIM_H */
