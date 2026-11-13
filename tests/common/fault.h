#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Arms the fault handler. Call once, early in main(), after consoleInit().
//
// log_path is where the register report is written; pass NULL to report to the
// console only. The file is opened here rather than in the handler so that a
// fault inside the allocator or stdio cannot stop the report from being written.
void fault_install(const char *log_path);

#ifdef __cplusplus
}
#endif
