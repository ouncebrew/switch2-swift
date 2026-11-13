/* newlib has no sys/socket.h. libdispatch uses it only to ask whether a
 * descriptor is a listening socket, which the console never has. */
#ifndef DISPATCH_SHIM_SYS_SOCKET_H
#define DISPATCH_SHIM_SYS_SOCKET_H

#include <sys/types.h>

#define SOL_SOCKET 1
#define SO_ACCEPTCONN 30

int getsockopt(int socket, int level, int option_name, void *option_value,
               socklen_t *option_len);

#endif
