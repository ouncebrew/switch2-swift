/* SPDX-License-Identifier: MIT */
#include "include/ounce_mitm_shim.h"

/* ---- mitm.h -------------------------------------------------------------- */

bool ounce_mitmResultIsForward(Result rc) {
    return mitmResultIsForward(rc);
}

void ounce_mitmServiceCreate(MitmService *s, Handle session, Handle forward_session,
                             const MitmProcessInfo *client_info) {
    mitmServiceCreate(s, session, forward_session, client_info);
}

void ounce_mitmServiceClose(MitmService *s) {
    mitmServiceClose(s);
}

MitmRequest ounce_mitmServiceParseRequest(MitmService *s) {
    return mitmServiceParseRequest(s);
}

void ounce_mitmRequestSetPid(const MitmRequest *req, u64 pid) {
    mitmRequestSetPid(req, pid);
}

void *ounce_mitmTipcBeginResponse(void *base, Result rc, u32 payload_size,
                                  u32 num_handles, Handle **out_handles) {
    return mitmTipcBeginResponse(base, rc, payload_size, num_handles, out_handles);
}

void *ounce_mitmCmifBeginResponse(void *base, Result rc, u32 payload_size,
                                  u32 num_handles, u32 token, Handle **out_handles) {
    return mitmCmifBeginResponse(base, rc, payload_size, num_handles, token, out_handles);
}

void *ounce_mitmServiceBeginResponse(MitmService *s, Result rc, u32 payload_size,
                                     u32 num_handles, Handle **out_handles) {
    return mitmServiceBeginResponse(s, rc, payload_size, num_handles, out_handles);
}

Result ounce_mitmServiceReply(MitmService *s) {
    return mitmServiceReply(s);
}

Result ounce_mitmServiceForward(MitmService *s) {
    return mitmServiceForward(s);
}

/* ---- Hook handlers ------------------------------------------------------- */

static OunceMitmHandler g_ounce_mitm_handler = NULL;

void ounce_mitmSetHandler(OunceMitmHandler handler) {
    g_ounce_mitm_handler = handler;
}

static Result ounce_mitm_trampoline(MitmHookContext *ctx) {
    if (g_ounce_mitm_handler == NULL) {
        return MAKERESULT(Module_Libnx, LibnxError_MitmHookNotSupported);
    }
    return g_ounce_mitm_handler(ctx, ctx->user);
}

MitmHookHandler ounce_mitmHandlerTrampoline(void) {
    return ounce_mitm_trampoline;
}

Result ounce_mitmErrorHookNotSupported(void) {
    return MAKERESULT(Module_Libnx, LibnxError_MitmHookNotSupported);
}

Result ounce_mitmResultForwardToSession(void) {
    return MITM_RESULT_FORWARD_TO_SESSION;
}
