/* newlib has no syslog.h. libdispatch uses it only for its diagnostic log,
 * which is routed to stderr by the shim implementation. */
#ifndef DISPATCH_SHIM_SYSLOG_H
#define DISPATCH_SHIM_SYSLOG_H
#include <stdarg.h>
#define LOG_NOTICE 5
void syslog(int priority, const char *format, ...);
void vsyslog(int priority, const char *format, va_list ap);
#endif
