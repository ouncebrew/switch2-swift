/* SPDX-License-Identifier: MIT
 *
 * TCP and TLS transport for the FoundationNetworking port. See transport.h.
 *
 * Plain sockets are libnx's bsd service through the standard <sys/socket.h>
 * interface. TLS is the console's ssl service through <switch/services/ssl.h>;
 * it verifies the peer certificate and host name against the console store.
 *
 * Every wait is bounded. connect() uses a non-blocking socket plus poll(2),
 * and reads and writes poll first. The ssl connection has its own timeout,
 * set with sslConnectionSetIoTimeout, because its internal socket is
 * non-blocking regardless of the descriptor's flags.
 */

#include "transport.h"

#include <switch.h>

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* libnx's socket header has the SO_* options but not the level they belong
 * to; BSDs use 0xffff. */
#ifndef SOL_SOCKET
#define SOL_SOCKET 0xffff
#endif

struct SfnConnection {
    int fd;
    int tls;
    int timeout_ms;
    int ssl_context_open;
    int ssl_connection_open;
    int ssl_fd;
    int ssl_owns_socket;
    SslContext ssl_context;
    SslConnection ssl_connection;
};

static int g_socket_ready;
static int g_ssl_ready;

int sfn_net_initialize(void) {
    if (g_socket_ready) {
        return SFN_OK;
    }

    Result rc = socketInitializeDefault();
    if (R_FAILED(rc)) {
        return SFN_ERR_INIT;
    }

    g_socket_ready = 1;
    return SFN_OK;
}

static int wait_for(int fd, short events, int timeout_ms) {
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = events;
    pfd.revents = 0;

    int rc;
    do {
        rc = poll(&pfd, 1, timeout_ms);
    } while (rc < 0 && errno == EINTR);

    if (rc == 0) {
        return SFN_ERR_TIMEOUT;
    }
    if (rc < 0) {
        return SFN_ERR_IO;
    }
    if (pfd.revents & (POLLERR | POLLNVAL)) {
        return SFN_ERR_IO;
    }

    return SFN_OK;
}

static int socket_error(int fd) {
    int value = 0;
    socklen_t size = sizeof(value);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &value, &size) < 0) {
        return SFN_ERR_CONNECT;
    }
    return value == 0 ? SFN_OK : SFN_ERR_CONNECT;
}

/* Connects one addrinfo. Returns a descriptor, or an SFN_ERR_* value. */
static int connect_one(const struct addrinfo *address, int timeout_ms) {
    int fd = socket(address->ai_family, address->ai_socktype,
                    address->ai_protocol);
    if (fd < 0) {
        return SFN_ERR_CONNECT;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    int nonblocking = 0;
    if (flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0) {
        nonblocking = 1;
    }

    int rc;
    if (nonblocking) {
        rc = connect(fd, address->ai_addr, address->ai_addrlen);
        if (rc < 0 && errno == EINPROGRESS) {
            rc = wait_for(fd, POLLOUT, timeout_ms);
            if (rc != SFN_OK) {
                close(fd);
                return rc;
            }
            rc = socket_error(fd);
            if (rc != SFN_OK) {
                close(fd);
                return rc;
            }
            rc = 0;
        }

        /* Restore the blocking flag. A failure here is not fatal: the
         * descriptor still works, and libnx's ssl service sets its own
         * non-blocking mode internally. */
        (void)fcntl(fd, F_SETFL, flags);

        if (rc < 0) {
            close(fd);
            return SFN_ERR_CONNECT;
        }
    } else {
        rc = connect(fd, address->ai_addr, address->ai_addrlen);
        if (rc < 0) {
            close(fd);
            return SFN_ERR_CONNECT;
        }
    }

    return fd;
}

static int start_tls(struct SfnConnection *connection, const char *host) {
    if (!g_ssl_ready) {
        Result rc = sslInitialize(3);
        if (R_FAILED(rc)) {
            return SFN_ERR_TLS;
        }
        g_ssl_ready = 1;
    }

    memset(&connection->ssl_context, 0, sizeof(connection->ssl_context));
    memset(&connection->ssl_connection, 0, sizeof(connection->ssl_connection));

    if (R_FAILED(sslCreateContext(&connection->ssl_context, SslVersion_Auto))) {
        return SFN_ERR_TLS;
    }
    connection->ssl_context_open = 1;

    if (R_FAILED(sslContextCreateConnection(&connection->ssl_context,
                                            &connection->ssl_connection))) {
        return SFN_ERR_TLS;
    }
    connection->ssl_connection_open = 1;

    /* The wrapper documents that -1 with errno ENOENT means the socket was
     * accepted but no output descriptor was returned; that is success, and
     * there is simply no descriptor to close later. */
    errno = 0;
    int ssl_fd = socketSslConnectionSetSocketDescriptor(
        &connection->ssl_connection, connection->fd);
    if (ssl_fd < 0 && errno != ENOENT) {
        return SFN_ERR_TLS;
    }
    connection->ssl_fd = ssl_fd;
    connection->ssl_owns_socket = 1;

    size_t host_length = strlen(host);
    if (host_length == 0 || host_length > 0xff) {
        return SFN_ERR_TLS;
    }
    if (R_FAILED(sslConnectionSetHostName(&connection->ssl_connection, host,
                                          (u32)host_length))) {
        return SFN_ERR_TLS;
    }

    /* These are the service's defaults; setting them explicitly means a
     * future default cannot silently turn verification off. */
    if (R_FAILED(sslConnectionSetVerifyOption(
            &connection->ssl_connection,
            SslVerifyOption_PeerCa | SslVerifyOption_HostName))) {
        return SFN_ERR_TLS;
    }

    if (R_FAILED(sslConnectionSetIoTimeout(&connection->ssl_connection,
                                           (u32)connection->timeout_ms))) {
        return SFN_ERR_TLS;
    }

    u32 certificate_size = 0;
    u32 certificate_count = 0;
    if (R_FAILED(sslConnectionDoHandshake(
            &connection->ssl_connection, &certificate_size, &certificate_count,
            NULL, 0))) {
        return SFN_ERR_TLS;
    }

    connection->tls = 1;
    return SFN_OK;
}

static void destroy_connection(struct SfnConnection *connection) {
    if (connection == NULL) {
        return;
    }

    /* Once the ssl service has taken the descriptor, closing ssl_fd is what
     * the libnx documentation requires; the original descriptor must not be
     * closed a second time. */
    if (connection->ssl_fd >= 0) {
        close(connection->ssl_fd);
        connection->ssl_fd = -1;
    }
    if (connection->ssl_connection_open) {
        sslConnectionClose(&connection->ssl_connection);
        connection->ssl_connection_open = 0;
    }
    if (connection->ssl_context_open) {
        sslContextClose(&connection->ssl_context);
        connection->ssl_context_open = 0;
    }
    if (!connection->ssl_owns_socket && connection->fd >= 0) {
        close(connection->fd);
        connection->fd = -1;
    }

    free(connection);
}

void *sfn_connect(const char *host, unsigned short port, int use_tls,
                  int timeout_milliseconds, int *error) {
    if (error != NULL) {
        *error = SFN_OK;
    }
    if (host == NULL || host[0] == '\0' || port == 0) {
        if (error != NULL) {
            *error = SFN_ERR_BADURL;
        }
        return NULL;
    }

    int rc = sfn_net_initialize();
    if (rc != SFN_OK) {
        if (error != NULL) {
            *error = rc;
        }
        return NULL;
    }

    char service[8];
    snprintf(service, sizeof(service), "%u", (unsigned)port);

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    struct addrinfo *addresses = NULL;
    if (getaddrinfo(host, service, &hints, &addresses) != 0 ||
        addresses == NULL) {
        if (error != NULL) {
            *error = SFN_ERR_DNS;
        }
        return NULL;
    }

    int fd = SFN_ERR_CONNECT;
    for (struct addrinfo *address = addresses; address != NULL;
         address = address->ai_next) {
        fd = connect_one(address, timeout_milliseconds);
        if (fd >= 0) {
            break;
        }
    }
    freeaddrinfo(addresses);

    if (fd < 0) {
        if (error != NULL) {
            *error = fd;
        }
        return NULL;
    }

    struct SfnConnection *connection = calloc(1, sizeof(*connection));
    if (connection == NULL) {
        close(fd);
        if (error != NULL) {
            *error = SFN_ERR_INIT;
        }
        return NULL;
    }

    connection->fd = fd;
    connection->timeout_ms = timeout_milliseconds;
    connection->ssl_fd = -1;

    if (use_tls) {
        rc = start_tls(connection, host);
        if (rc != SFN_OK) {
            destroy_connection(connection);
            if (error != NULL) {
                *error = rc;
            }
            return NULL;
        }
    }

    return connection;
}

long sfn_read(void *opaque, void *buffer, size_t length) {
    struct SfnConnection *connection = opaque;
    if (connection == NULL || buffer == NULL || length == 0) {
        return 0;
    }

    if (connection->tls) {
        u32 read = 0;
        u32 wanted = length > 0xffffffffu ? 0xffffffffu : (u32)length;
        if (R_FAILED(sslConnectionRead(&connection->ssl_connection, buffer,
                                       wanted, &read))) {
            return SFN_ERR_IO;
        }
        return (long)read;
    }

    for (;;) {
        int rc = wait_for(connection->fd, POLLIN, connection->timeout_ms);
        if (rc != SFN_OK) {
            return rc;
        }

        ssize_t count = recv(connection->fd, buffer, length, 0);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return SFN_ERR_IO;
        }
        return (long)count;
    }
}

long sfn_write(void *opaque, const void *buffer, size_t length) {
    struct SfnConnection *connection = opaque;
    if (connection == NULL || buffer == NULL || length == 0) {
        return 0;
    }

    const unsigned char *bytes = buffer;
    size_t written = 0;

    while (written < length) {
        if (connection->tls) {
            size_t remaining = length - written;
            u32 wanted = remaining > 0xffffffffu ? 0xffffffffu : (u32)remaining;
            u32 count = 0;
            if (R_FAILED(sslConnectionWrite(&connection->ssl_connection,
                                            bytes + written, wanted, &count)) ||
                count == 0) {
                return SFN_ERR_IO;
            }
            written += count;
            continue;
        }

        int rc = wait_for(connection->fd, POLLOUT, connection->timeout_ms);
        if (rc != SFN_OK) {
            return rc;
        }

        ssize_t count = send(connection->fd, bytes + written,
                             length - written, 0);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return SFN_ERR_IO;
        }
        if (count == 0) {
            return SFN_ERR_IO;
        }
        written += (size_t)count;
    }

    return (long)written;
}

void sfn_close(void *opaque) {
    destroy_connection(opaque);
}
