/* newlib has no linux/sockios.h. libdispatch only uses SIOCGIFCONF to
 * enumerate interfaces, which the console does not have. */
#ifndef DISPATCH_SHIM_LINUX_SOCKIOS_H
#define DISPATCH_SHIM_LINUX_SOCKIOS_H

#define SIOCGIFCONF 0x8912
#define SIOCINQ 0x541B
#define SIOCOUTQ 0x5411

#endif
