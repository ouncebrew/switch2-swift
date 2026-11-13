/* SPDX-License-Identifier: MIT
 *
 * C surface for the mitm and hook framework.
 *
 * This is a separate target from COunce because the framework is not part of
 * every libounce: it comes from the libounce-mitm patch set. A package that
 * does not install that patch set must still be able to build Ounce, so the
 * dependency is opt-in through the OunceMitm product.
 *
 * <switch.h> already pulls in <switch/sf/mitm.h>, <switch/sf/mitm_hook.h>,
 * <switch/sf/mitm_hook_loader.h> and <switch/services/fs_hook.h> once the
 * patch set is applied. As in COunce, the only declarations Swift cannot call
 * are the NX_INLINE and NX_CONSTEXPR ones, re-exported below.
 */
#pragma once

#include <switch.h>

/* ---- mitm.h -------------------------------------------------------------- */

bool ounce_mitmResultIsForward(Result rc);

void ounce_mitmServiceCreate(MitmService *s, Handle session, Handle forward_session,
                             const MitmProcessInfo *client_info);
void ounce_mitmServiceClose(MitmService *s);
MitmRequest ounce_mitmServiceParseRequest(MitmService *s);
void ounce_mitmRequestSetPid(const MitmRequest *req, u64 pid);

void *ounce_mitmTipcBeginResponse(void *base, Result rc, u32 payload_size,
                                  u32 num_handles, Handle **out_handles);
void *ounce_mitmCmifBeginResponse(void *base, Result rc, u32 payload_size,
                                  u32 num_handles, u32 token, Handle **out_handles);
void *ounce_mitmServiceBeginResponse(MitmService *s, Result rc, u32 payload_size,
                                     u32 num_handles, Handle **out_handles);

Result ounce_mitmServiceReply(MitmService *s);
Result ounce_mitmServiceForward(MitmService *s);

/* ---- Hook handlers ------------------------------------------------------- */

/// A Swift hook handler. `user` is the per-hook pointer from MitmHookEntry.
typedef Result (*OunceMitmHandler)(MitmHookContext *ctx, void *user);

/// Installs the handler the trampoline calls. Pass NULL to clear it.
void ounce_mitmSetHandler(OunceMitmHandler handler);

/// The C function pointer to hand to mitmHookInstall.
MitmHookHandler ounce_mitmHandlerTrampoline(void);

/// MAKERESULT(Module_Libnx, LibnxError_MitmHookNotSupported), for the Swift
/// trampoline to return when no handler is installed.
Result ounce_mitmErrorHookNotSupported(void);

/// MITM_RESULT_FORWARD_TO_SESSION, which is a MAKERESULT macro and so does not
/// import into Swift.
Result ounce_mitmResultForwardToSession(void);
