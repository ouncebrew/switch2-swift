/* A small fts(3) for devkitA64's newlib. See fts.h for the subset and why the
 * structure layout matters.
 *
 * The walker is a stack of open directories. fts_read returns the root, then
 * each child in pre-order, descending into directories as it meets them, and
 * returns FTS_DP for a directory after its children. That is the order
 * Foundation's remove and copy loops expect, and it is what makes "rmdir after
 * visiting the children" work.
 */
#include <fts.h>

#include <errno.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct _FTSDir {
    DIR *dir;
    char *path;
    short level;
    int skip;
    struct _FTSDir *next;
};

static int fts_info_from_mode(mode_t mode) {
    if (S_ISDIR(mode)) {
        return FTS_D;
    }
    if (S_ISLNK(mode)) {
        return FTS_SL;
    }
    if (S_ISREG(mode)) {
        return FTS_F;
    }
    return FTS_DEFAULT;
}

static FTSENT *fts_alloc_entry(const char *path, const char *name,
                               int info, short level, int error) {
    size_t pathlen = strlen(path);
    size_t namelen = strlen(name);
    size_t name_offset = offsetof(FTSENT, fts_name);

    FTSENT *entry = calloc(1, name_offset + namelen + 1);
    if (entry == NULL) {
        return NULL;
    }
    entry->fts_path = malloc(pathlen + 1);
    if (entry->fts_path == NULL) {
        free(entry);
        return NULL;
    }
    memcpy(entry->fts_path, path, pathlen + 1);
    memcpy((char *)entry + name_offset, name, namelen + 1);
    entry->fts_pathlen = pathlen;
    entry->fts_accpath = entry->fts_path;
    entry->fts_namelen = namelen;
    entry->fts_info = info;
    entry->fts_level = level;
    entry->fts_errno = error;
    entry->fts_parent = NULL;
    return entry;
}

static FTSENT *fts_make_entry(const char *path, int info,
                              short level, int error) {
    const char *slash = strrchr(path, '/');
    const char *name = (slash == NULL) ? path : slash + 1;
    if (*name == '\0' && slash != NULL) {
        /* A trailing slash: use the last component before it. */
        size_t len = (size_t)(slash - path);
        while (len > 0 && path[len - 1] == '/') {
            len--;
        }
        size_t start = len;
        while (start > 0 && path[start - 1] != '/') {
            start--;
        }
        static char component[256];
        size_t copy = len - start;
        if (copy >= sizeof(component)) {
            copy = sizeof(component) - 1;
        }
        memcpy(component, path + start, copy);
        component[copy] = '\0';
        name = component;
    }
    return fts_alloc_entry(path, name, info, level, error);
}

static void fts_free_entry(FTSENT *entry) {
    if (entry == NULL) {
        return;
    }
    free(entry->fts_path);
    free(entry);
}

static void fts_push_dir(FTS *fts, DIR *dir, const char *path, short level) {
    FTSDir *frame = malloc(sizeof(FTSDir));
    if (frame == NULL) {
        closedir(dir);
        fts->finished = 1;
        errno = ENOMEM;
        return;
    }
    frame->dir = dir;
    frame->path = strdup(path);
    if (frame->path == NULL) {
        closedir(dir);
        free(frame);
        fts->finished = 1;
        errno = ENOMEM;
        return;
    }
    frame->level = level;
    frame->skip = 0;
    frame->next = fts->stack;
    fts->stack = frame;
}

static void fts_pop_dir(FTS *fts) {
    FTSDir *frame = fts->stack;
    if (frame == NULL) {
        return;
    }
    fts->stack = frame->next;
    closedir(frame->dir);
    free(frame->path);
    free(frame);
}

static char *fts_join_path(const char *dir, const char *name) {
    size_t dirlen = strlen(dir);
    size_t namelen = strlen(name);
    int needs_slash = dirlen > 0 && dir[dirlen - 1] != '/';
    size_t total = dirlen + (needs_slash ? 1 : 0) + namelen + 1;

    char *path = malloc(total);
    if (path == NULL) {
        return NULL;
    }
    memcpy(path, dir, dirlen);
    if (needs_slash) {
        path[dirlen] = '/';
    }
    memcpy(path + dirlen + (needs_slash ? 1 : 0), name, namelen + 1);
    return path;
}

FTS *fts_open(char *const *path_argv, int options,
              int (*compar)(const FTSENT **, const FTSENT **)) {
    (void)compar;

    if (path_argv == NULL || path_argv[0] == NULL) {
        errno = EINVAL;
        return NULL;
    }

    FTS *fts = calloc(1, sizeof(FTS));
    if (fts == NULL) {
        errno = ENOMEM;
        return NULL;
    }
    fts->root = strdup(path_argv[0]);
    if (fts->root == NULL) {
        free(fts);
        errno = ENOMEM;
        return NULL;
    }
    fts->options = options;
    return fts;
}

FTSENT *fts_read(FTS *fts) {
    if (fts == NULL || fts->finished) {
        errno = 0;
        return NULL;
    }

    fts_free_entry(fts->current);
    fts->current = NULL;

    if (!fts->started) {
        struct stat st;
        int error = 0;

        fts->started = 1;
        if (lstat(fts->root, &st) != 0) {
            error = errno;
        }

        int info = (error != 0) ? FTS_NS : fts_info_from_mode(st.st_mode);
        FTSENT *entry = fts_make_entry(fts->root, info, 0, error);
        if (entry == NULL) {
            fts->finished = 1;
            errno = ENOMEM;
            return NULL;
        }

        if (info == FTS_D) {
            DIR *dir = opendir(fts->root);
            if (dir == NULL) {
                entry->fts_info = FTS_DNR;
                entry->fts_errno = errno;
            } else {
                fts_push_dir(fts, dir, fts->root, 0);
            }
        }

        fts->current = entry;
        errno = 0;
        return entry;
    }

    for (;;) {
        FTSDir *top = fts->stack;
        if (top == NULL) {
            fts->finished = 1;
            errno = 0;
            return NULL;
        }

        if (top->skip) {
            /* fts_set(FTS_SKIP) was called for this directory: no children,
             * but FTS_D still has to be balanced by FTS_DP. */
            FTSENT *entry = fts_make_entry(top->path, FTS_DP, top->level, 0);
            fts_pop_dir(fts);
            if (entry == NULL) {
                fts->finished = 1;
                errno = ENOMEM;
                return NULL;
            }
            fts->current = entry;
            errno = 0;
            return entry;
        }

        errno = 0;
        struct dirent *dirent = readdir(top->dir);
        if (dirent == NULL) {
            int error = errno;
            FTSENT *entry = fts_make_entry(top->path, error ? FTS_ERR : FTS_DP,
                                           top->level, error);
            fts_pop_dir(fts);
            if (entry == NULL) {
                fts->finished = 1;
                errno = ENOMEM;
                return NULL;
            }
            fts->current = entry;
            errno = 0;
            return entry;
        }

        if (strcmp(dirent->d_name, ".") == 0 ||
            strcmp(dirent->d_name, "..") == 0) {
            continue;
        }

        char *path = fts_join_path(top->path, dirent->d_name);
        if (path == NULL) {
            fts->finished = 1;
            errno = ENOMEM;
            return NULL;
        }

        struct stat st;
        int error = 0;
        if (lstat(path, &st) != 0) {
            error = errno;
        }
        int info = (error != 0) ? FTS_NS : fts_info_from_mode(st.st_mode);

        FTSENT *entry = fts_make_entry(path, info, top->level + 1, error);
        if (entry == NULL) {
            free(path);
            fts->finished = 1;
            errno = ENOMEM;
            return NULL;
        }

        if (info == FTS_D) {
            DIR *dir = opendir(path);
            if (dir == NULL) {
                entry->fts_info = FTS_DNR;
                entry->fts_errno = errno;
            } else {
                fts_push_dir(fts, dir, path, top->level + 1);
            }
        }
        free(path);

        fts->current = entry;
        errno = 0;
        return entry;
    }
}

int fts_set(FTS *fts, FTSENT *entry, int instr) {
    if (fts == NULL || entry == NULL) {
        errno = EINVAL;
        return 1;
    }
    if (instr != FTS_SKIP) {
        errno = EINVAL;
        return 1;
    }

    FTSDir *top = fts->stack;
    if (top != NULL && strcmp(top->path, entry->fts_path) == 0) {
        top->skip = 1;
    }
    return 0;
}

int fts_close(FTS *fts) {
    if (fts == NULL) {
        return 0;
    }
    while (fts->stack != NULL) {
        fts_pop_dir(fts);
    }
    fts_free_entry(fts->current);
    free(fts->root);
    free(fts);
    return 0;
}
