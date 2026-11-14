/* A small fts(3) for devkitA64's newlib.
 *
 * Foundation uses fts for everything that walks a directory tree: removeItem,
 * copyItem and directory enumeration. newlib has no fts at all, and the
 * functions are not in libc.a, so this header and fts.c supply them.
 *
 * The layout matters. Foundation reads fts_name through
 * `MemoryLayout<FTSENT>.offset(of: \.fts_name)`, which the Clang importer
 * computes from this declaration, and the name is stored inline after the
 * struct, the way BSD's fts.h does it. fts_name must therefore stay the last
 * field.
 *
 * The subset is the one Foundation uses: one path, depth-first order, pre-order
 * FTS_D/FTS_F/... entries and post-order FTS_DP entries, FTS_SKIP through
 * fts_set, and the error entries FTS_DNR, FTS_NS and FTS_ERR. FTS_LOGICAL,
 * sorting and fts_children are not implemented; the console port only needs
 * FTS_PHYSICAL, FTS_NOCHDIR, FTS_NOSTAT and FTS_XDEV.
 */
#ifndef SWITCH2_FTS_H
#define SWITCH2_FTS_H

#include <stddef.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <dirent.h>

#define FTS_COMFOLLOW 0x0001
#define FTS_LOGICAL 0x0002
#define FTS_NOCHDIR 0x0004
#define FTS_NOSTAT 0x0008
#define FTS_PHYSICAL 0x0010
#define FTS_SEEDOT 0x0020
#define FTS_XDEV 0x0040

#define FTS_D 1        /* directory, pre-order */
#define FTS_DC 2       /* directory that causes a cycle */
#define FTS_DEFAULT 3  /* anything not covered below */
#define FTS_DNR 4      /* directory that cannot be read */
#define FTS_DOT 5      /* . or .. */
#define FTS_DP 6       /* directory, post-order */
#define FTS_ERR 7      /* error, errno is meaningful */
#define FTS_F 8        /* regular file */
#define FTS_INIT 9     /* internal */
#define FTS_NS 10      /* stat failed, errno is meaningful */
#define FTS_NSOK 11    /* no stat requested */
#define FTS_SL 12      /* symbolic link */
#define FTS_SLNONE 13  /* symbolic link with no target */
#define FTS_W 14       /* whiteout */

#define FTS_SKIP 1

typedef struct _FTSENT {
    char *fts_path;        /* full path to this entry */
    size_t fts_pathlen;    /* strlen(fts_path) */
    char *fts_accpath;     /* same as fts_path, and unused here */
    size_t fts_namelen;    /* strlen(fts_name) */
    int fts_info;          /* FTS_D, FTS_F, ...; int, like the constants */
    short fts_level;       /* 0 for the root */
    int fts_errno;
    struct _FTSENT *fts_parent;
    char fts_name[1];      /* inline, allocation is longer */
} FTSENT;

/* The stream. Defined here rather than in fts.c because Foundation names the
 * type: `UnsafeMutablePointer<FTS>`. An opaque typedef would import as
 * OpaquePointer and that name would not exist. */
typedef struct _FTSDir FTSDir;

typedef struct _FTS {
    char *root;
    int options;
    FTSDir *stack;
    FTSENT *current;
    int started;
    int finished;
} FTS;

FTS *fts_open(char *const *path_argv, int options,
              int (*compar)(const FTSENT **, const FTSENT **));
FTSENT *fts_read(FTS *ftsp);
int fts_close(FTS *ftsp);
int fts_set(FTS *ftsp, FTSENT *f, int instr);

#endif /* SWITCH2_FTS_H */
