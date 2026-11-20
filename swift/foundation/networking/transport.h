/* SPDX-License-Identifier: MIT
 *
 * The C half of the FoundationNetworking port.
 *
 * The Swift module does not import a Clang module: it calls these functions
 * through @_silgen_name. That keeps the Swift module free of a module-map
 * dependency, so a program that imports FoundationNetworking needs no extra
 * -Xcc flags. The API is deliberately small -- connect, read, write, close --
 * and all of the HTTP work is done in Swift.
 *
 * TCP is libnx's BSD socket service. HTTPS is libnx's ssl service, which is
 * the console's own TLS client: certificate and host-name verification are
 * done by the service against the console certificate store, so no CA bundle
 * has to be shipped. Both are initialized lazily on the first connection.
 */

#ifndef SWITCH2_FOUNDATION_TRANSPORT_H
#define SWITCH2_FOUNDATION_TRANSPORT_H

#include <stddef.h>

/* Results. Negative values are errors; sfn_read and sfn_write also return a
 * byte count, so an error is any negative value. Keep these in sync with
 * Swift's TransportErrorCode. */
#define SFN_OK 0
#define SFN_ERR_INIT -1
#define SFN_ERR_DNS -2
#define SFN_ERR_CONNECT -3
#define SFN_ERR_TIMEOUT -4
#define SFN_ERR_TLS -5
#define SFN_ERR_IO -6
#define SFN_ERR_BADURL -7

/* Starts libnx's socket service if it is not running. Returns SFN_OK or an
 * SFN_ERR_* value. Safe to call more than once. */
int sfn_net_initialize(void);

/* Opens host:port. use_tls selects the ssl service. timeout_milliseconds
 * bounds connect, each read and each write. Returns an opaque connection on
 * success, or NULL with *error set to an SFN_ERR_* value. */
void *sfn_connect(const char *host, unsigned short port, int use_tls,
                  int timeout_milliseconds, int *error);

/* Reads up to length bytes. Returns the count, 0 at end of stream, or an
 * SFN_ERR_* value. */
long sfn_read(void *connection, void *buffer, size_t length);

/* Writes all of buffer. Returns length on success or an SFN_ERR_* value. */
long sfn_write(void *connection, const void *buffer, size_t length);

/* Closes a connection and frees it. NULL is accepted. */
void sfn_close(void *connection);

#endif
