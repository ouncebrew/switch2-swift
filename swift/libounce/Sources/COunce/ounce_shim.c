/* SPDX-License-Identifier: MIT
 *
 * The real functions behind ounce_shim.h. Each one is a thin wrapper over a
 * libnx or OunceHEN inline, so that Swift can call it.
 */
#include "include/ounce_shim.h"

#include <stdio.h>

/* ---- Result -------------------------------------------------------------- */

bool ounce_result_succeeded(Result rc) {
    return R_SUCCEEDED(rc);
}

/* ---- Console ------------------------------------------------------------- */

PrintConsole *ounce_console_init(void) {
    return consoleInit(NULL);
}

void ounce_console_update(void) {
    consoleUpdate(NULL);
}

void ounce_console_clear(void) {
    consoleClear();
}

void ounce_console_exit(void) {
    consoleExit(NULL);
}

void ounce_console_puts(const char *text) {
    if (text != NULL) {
        puts(text);
    }
}

/* ---- Applet -------------------------------------------------------------- */

bool ounce_applet_main_loop(void) {
    return appletMainLoop();
}

/* ---- Pad ----------------------------------------------------------------- */

void ounce_pad_init_default(PadState *pad) {
    padInitializeDefault(pad);
}

void ounce_pad_update(PadState *pad) {
    padUpdate(pad);
}

u64 ounce_pad_buttons(const PadState *pad) {
    return padGetButtons(pad);
}

u64 ounce_pad_buttons_down(const PadState *pad) {
    return padGetButtonsDown(pad);
}

u64 ounce_pad_buttons_up(const PadState *pad) {
    return padGetButtonsUp(pad);
}

bool ounce_pad_connected(const PadState *pad) {
    return padIsConnected(pad);
}

HidAnalogStickState ounce_pad_stick(const PadState *pad, unsigned index) {
    return padGetStickPos(pad, index);
}

/* ---- Filesystem ---------------------------------------------------------- */

Result ounce_fsdev_mount_sdmc(void) {
    return fsdevMountSdmc();
}

Result ounce_fsdev_unmount_all(void) {
    return fsdevUnmountAll();
}

/* ---- Hosversion ---------------------------------------------------------- */

bool ounce_hosversion_is_ouncehen(void) {
    return hosversionIsOunceHEN();
}

/* ---- OunceHEN ------------------------------------------------------------ */

Result ounce_hen_open(Service *out) {
    Service ro;
    Result rc = ouncehenGetRoSession(&ro);

    if (R_FAILED(rc)) {
        return rc;
    }

    /* The ldr:ro session is borrowed from the service override, so it is not
     * closed here; ouncehenGetRoSession clears own_handle for that reason. */
    return ouncehenOpenHomebrewSession(&ro, out);
}

Result ounce_hen_status(Service *s, HenStatus *out) {
    return henGetStatus(s, out);
}

Result ounce_hen_filesystem_root(Service *s, Handle *out) {
    return henGetFilesystemRoot(s, out);
}

Result ounce_hen_settings_session(Service *s, Handle *out) {
    return henGetSettingsSession(s, out);
}

Result ounce_hen_process_handle(Service *s, Handle *out) {
    return henGetProcessHandle(s, out);
}

Result ounce_hen_service_manager(Service *s, Handle *out) {
    return henGetServiceManager(s, out);
}

void ounce_service_close(Service *s) {
    serviceClose(s);
}

/* ---- Complete re-export of libnx's inline API ---------------------------- */
void ounce_serviceRequestFormatProcessBuffer(CmifRequestFormat* fmt, u32 attr) {
    _serviceRequestFormatProcessBuffer(fmt, attr);
}

void ounce_serviceRequestProcessBuffer(CmifRequest* req, const SfBuffer* buf, u32 attr) {
    _serviceRequestProcessBuffer(req, buf, attr);
}

void ounce_serviceResponseGetHandle(CmifResponse* res, SfOutHandleAttr type, Handle* out) {
    _serviceResponseGetHandle(res, type, out);
}

void ounce_tipcRequestFormatProcessBuffer(TipcRequestFormat* fmt, u32 attr) {
    _tipcRequestFormatProcessBuffer(fmt, attr);
}

void ounce_tipcRequestProcessBuffer(HipcRequest* req, const SfBuffer* buf, u32 attr) {
    _tipcRequestProcessBuffer(req, buf, attr);
}

void ounce_tipcResponseGetHandle(HipcResponse* res, SfOutHandleAttr type, Handle* out) {
    _tipcResponseGetHandle(res, type, out);
}

bool ounce_accountUidIsValid(const AccountUid *Uid) {
    return accountUidIsValid(Uid);
}

Event * ounce_appletHolderGetExitEvent(AppletHolder *h) {
    return appletHolderGetExitEvent(h);
}

size_t ounce_audrenGetInputParamSize(const AudioRendererConfig* config) {
    return audrenGetInputParamSize(config);
}

int ounce_audrenGetMemPoolCount(const AudioRendererConfig* config) {
    return audrenGetMemPoolCount(config);
}

size_t ounce_audrenGetOutputParamSize(const AudioRendererConfig* config) {
    return audrenGetOutputParamSize(config);
}

u32 ounce_btdevGattAttributeGetConnectionHandle(BtdevGattAttribute *a) {
    return btdevGattAttributeGetConnectionHandle(a);
}

u16 ounce_btdevGattAttributeGetHandle(BtdevGattAttribute *a) {
    return btdevGattAttributeGetHandle(a);
}

u8 ounce_btdevGattAttributeGetType(BtdevGattAttribute *a) {
    return btdevGattAttributeGetType(a);
}

void ounce_btdevGattAttributeGetUuid(BtdevGattAttribute *a, BtdrvGattAttributeUuid *out) {
    btdevGattAttributeGetUuid(a, out);
}

u16 ounce_btdevGattCharacteristicGetInstanceId(BtdevGattCharacteristic *c) {
    return btdevGattCharacteristicGetInstanceId(c);
}

u8 ounce_btdevGattCharacteristicGetProperties(BtdevGattCharacteristic *c) {
    return btdevGattCharacteristicGetProperties(c);
}

u16 ounce_btdevGattServiceGetEndGroupHandle(BtdevGattService *s) {
    return btdevGattServiceGetEndGroupHandle(s);
}

u16 ounce_btdevGattServiceGetInstanceId(BtdevGattService *s) {
    return btdevGattServiceGetInstanceId(s);
}

u16 ounce_btdevGattServiceIsPrimaryService(BtdevGattService *s) {
    return btdevGattServiceIsPrimaryService(s);
}

Result ounce_cmifCloneCurrentObject(Handle h, Handle* out_h) {
    return cmifCloneCurrentObject(h, out_h);
}

Result ounce_cmifCloneCurrentObjectEx(Handle h, u32 tag, Handle* out_h) {
    return cmifCloneCurrentObjectEx(h, tag, out_h);
}

Result ounce_cmifConvertCurrentObjectToDomain(Handle h, u32* out_object_id) {
    return cmifConvertCurrentObjectToDomain(h, out_object_id);
}

Result ounce_cmifCopyFromCurrentDomain(Handle h, u32 object_id, Handle* out_h) {
    return cmifCopyFromCurrentDomain(h, object_id, out_h);
}

void* ounce_cmifGetAlignedDataStart(u32* data_words, void* base) {
    return cmifGetAlignedDataStart(data_words, base);
}

void ounce_cmifMakeCloseRequest(void* base, u32 object_id) {
    cmifMakeCloseRequest(base, object_id);
}

void* ounce_cmifMakeControlRequest(void* base, u32 request_id, u32 size) {
    return cmifMakeControlRequest(base, request_id, size);
}

CmifRequest ounce_cmifMakeRequest(void* base, CmifRequestFormat fmt) {
    return cmifMakeRequest(base, fmt);
}

Result ounce_cmifParseResponse(CmifResponse* res, void* base, bool is_domain, u32 size) {
    return cmifParseResponse(res, base, is_domain, size);
}

Result ounce_cmifQueryPointerBufferSize(Handle h, u16* out_size) {
    return cmifQueryPointerBufferSize(h, out_size);
}

void ounce_cmifRequestHandle(CmifRequest* req, Handle handle) {
    cmifRequestHandle(req, handle);
}

void ounce_cmifRequestInAutoBuffer(CmifRequest* req, const void* buffer, size_t size, HipcBufferMode mode) {
    cmifRequestInAutoBuffer(req, buffer, size, mode);
}

void ounce_cmifRequestInBuffer(CmifRequest* req, const void* buffer, size_t size, HipcBufferMode mode) {
    cmifRequestInBuffer(req, buffer, size, mode);
}

void ounce_cmifRequestInOutBuffer(CmifRequest* req, void* buffer, size_t size, HipcBufferMode mode) {
    cmifRequestInOutBuffer(req, buffer, size, mode);
}

void ounce_cmifRequestInPointer(CmifRequest* req, const void* buffer, size_t size) {
    cmifRequestInPointer(req, buffer, size);
}

void ounce_cmifRequestObject(CmifRequest* req, u32 object_id) {
    cmifRequestObject(req, object_id);
}

void ounce_cmifRequestOutAutoBuffer(CmifRequest* req, void* buffer, size_t size, HipcBufferMode mode) {
    cmifRequestOutAutoBuffer(req, buffer, size, mode);
}

void ounce_cmifRequestOutBuffer(CmifRequest* req, void* buffer, size_t size, HipcBufferMode mode) {
    cmifRequestOutBuffer(req, buffer, size, mode);
}

void ounce_cmifRequestOutFixedPointer(CmifRequest* req, void* buffer, size_t size) {
    cmifRequestOutFixedPointer(req, buffer, size);
}

void ounce_cmifRequestOutPointer(CmifRequest* req, void* buffer, size_t size) {
    cmifRequestOutPointer(req, buffer, size);
}

Handle ounce_cmifResponseGetCopyHandle(CmifResponse* res) {
    return cmifResponseGetCopyHandle(res);
}

Handle ounce_cmifResponseGetMoveHandle(CmifResponse* res) {
    return cmifResponseGetMoveHandle(res);
}

u32 ounce_cmifResponseGetObject(CmifResponse* res) {
    return cmifResponseGetObject(res);
}

bool ounce_detectDebugger(void) {
    return detectDebugger();
}

bool ounce_detectMesosphere(void) {
    return detectMesosphere();
}

Result ounce_friendsGetFriendInvitationNotificationEvent(Event *out_event) {
    return friendsGetFriendInvitationNotificationEvent(out_event);
}

FsDirectoryEntry* ounce_fsdevDirGetEntries(fsdev_dir_t *dir) {
    return fsdevDirGetEntries(dir);
}

bool ounce_hidKeyboardStateGetKey(const HidKeyboardState *state, HidKeyboardKey key) {
    return hidKeyboardStateGetKey(state, key);
}

HipcRequest ounce_hipcCalcRequestLayout(HipcMetadata meta, void* base) {
    return hipcCalcRequestLayout(meta, base);
}

void* ounce_hipcGetBufferAddress(const HipcBufferDescriptor* desc) {
    return hipcGetBufferAddress(desc);
}

size_t ounce_hipcGetBufferSize(const HipcBufferDescriptor* desc) {
    return hipcGetBufferSize(desc);
}

void* ounce_hipcGetStaticAddress(const HipcStaticDescriptor* desc) {
    return hipcGetStaticAddress(desc);
}

size_t ounce_hipcGetStaticSize(const HipcStaticDescriptor* desc) {
    return hipcGetStaticSize(desc);
}

HipcBufferDescriptor ounce_hipcMakeBuffer(const void* buffer, size_t size, HipcBufferMode mode) {
    return hipcMakeBuffer(buffer, size, mode);
}

HipcRecvListEntry ounce_hipcMakeRecvStatic(void* buffer, size_t size) {
    return hipcMakeRecvStatic(buffer, size);
}

HipcRequest ounce_hipcMakeRequest(void* base, HipcMetadata meta) {
    return hipcMakeRequest(base, meta);
}

HipcStaticDescriptor ounce_hipcMakeSendStatic(const void* buffer, size_t size, u8 index) {
    return hipcMakeSendStatic(buffer, size, index);
}

HipcParsedRequest ounce_hipcParseRequest(void* base) {
    return hipcParseRequest(base);
}

HipcResponse ounce_hipcParseResponse(void* base) {
    return hipcParseResponse(base);
}

void ounce_irsGetIrLedProcessorDefaultConfig(IrsIrLedProcessorConfig *config) {
    irsGetIrLedProcessorDefaultConfig(config);
}

void* ounce_jitGetRwAddr(Jit* j) {
    return jitGetRwAddr(j);
}

void* ounce_jitGetRxAddr(Jit* j) {
    return jitGetRxAddr(j);
}

void ounce_leventInit(LEvent* le, bool signaled, bool autoclear) {
    leventInit(le, signaled, autoclear);
}

void ounce_lp2pGroupInfoSetFrequencyChannel(Lp2pGroupInfo *info, u16 frequency, s16 channel) {
    lp2pGroupInfoSetFrequencyChannel(info, frequency, channel);
}

void ounce_lp2pGroupInfoSetMemberCountMax(Lp2pGroupInfo *info, size_t count) {
    lp2pGroupInfoSetMemberCountMax(info, count);
}

void ounce_lp2pGroupInfoSetStealthEnabled(Lp2pGroupInfo *info, bool flag) {
    lp2pGroupInfoSetStealthEnabled(info, flag);
}

void ounce_ncmContentInfoSizeToU64(const NcmContentInfo *info, u64 *out) {
    ncmContentInfoSizeToU64(info, out);
}

void ounce_ncmU64ToContentInfoSize(const u64 size, NcmContentInfo *info) {
    ncmU64ToContentInfoSize(size, info);
}

void ounce_notifAlarmSettingSetIsMuted(NotifAlarmSetting *alarm_setting, bool flag) {
    notifAlarmSettingSetIsMuted(alarm_setting, flag);
}

void ounce_notifAlarmSettingSetUid(NotifAlarmSetting *alarm_setting, AccountUid uid) {
    notifAlarmSettingSetUid(alarm_setting, uid);
}

Result ounce_notifGetNotificationSystemEvent(Event *out_event) {
    return notifGetNotificationSystemEvent(out_event);
}

int ounce_nxlinkStdio(void) {
    return nxlinkStdio();
}

int ounce_nxlinkStdioForDebug(void) {
    return nxlinkStdioForDebug();
}

u32 ounce_padGetAttributes(const PadState* pad) {
    return padGetAttributes(pad);
}

u64 ounce_padGetButtons(const PadState* pad) {
    return padGetButtons(pad);
}

u64 ounce_padGetButtonsDown(const PadState* pad) {
    return padGetButtonsDown(pad);
}

u64 ounce_padGetButtonsUp(const PadState* pad) {
    return padGetButtonsUp(pad);
}

u32 ounce_padGetGcTriggerPos(const PadState* pad, unsigned i) {
    return padGetGcTriggerPos(pad, i);
}

HidAnalogStickState ounce_padGetStickPos(const PadState* pad, unsigned i) {
    return padGetStickPos(pad, i);
}

u32 ounce_padGetStyleSet(const PadState* pad) {
    return padGetStyleSet(pad);
}

void ounce_padInitializeAny(PadState* pad) {
    padInitializeAny(pad);
}

void ounce_padInitializeDefault(PadState* pad) {
    padInitializeDefault(pad);
}

bool ounce_padIsConnected(const PadState* pad) {
    return padIsConnected(pad);
}

bool ounce_padIsHandheld(const PadState* pad) {
    return padIsHandheld(pad);
}

bool ounce_padIsNpadActive(const PadState* pad, HidNpadIdType id) {
    return padIsNpadActive(pad, id);
}

u64 ounce_padRepeaterGetButtons(const PadRepeater* r) {
    return padRepeaterGetButtons(r);
}

void ounce_padRepeaterInitialize(PadRepeater* r, u16 delay, u16 repeat) {
    padRepeaterInitialize(r, delay, repeat);
}

void ounce_pselUiSetAllowUserCreation(PselUiSettings *ui, bool flag) {
    pselUiSetAllowUserCreation(ui, flag);
}

void ounce_pselUiSetNetworkServiceRequired(PselUiSettings *ui, bool flag) {
    pselUiSetNetworkServiceRequired(ui, flag);
}

void ounce_pselUiSetSkipButtonEnabled(PselUiSettings *ui, bool flag) {
    pselUiSetSkipButtonEnabled(ui, flag);
}

bool ounce_ringconGetErrorFlag(RingCon *c, RingConErrorFlag flag) {
    return ringconGetErrorFlag(c, flag);
}

u32 ounce_ringconGetErrorFlags(RingCon *c) {
    return ringconGetErrorFlags(c);
}

RingConFwVersion ounce_ringconGetFwVersion(RingCon *c) {
    return ringconGetFwVersion(c);
}

void ounce_ringconGetId(RingCon *c, u64 *id_l, u64 *id_h) {
    ringconGetId(c, id_l, id_h);
}

void ounce_ringconGetManuCal(RingCon *c, RingConManuCal *out) {
    ringconGetManuCal(c, out);
}

s32 ounce_ringconGetTotalPushCount(RingCon *c) {
    return ringconGetTotalPushCount(c);
}

s16 ounce_ringconGetUnkCal(RingCon *c) {
    return ringconGetUnkCal(c);
}

void ounce_ringconGetUserCal(RingCon *c, RingConUserCal *out) {
    ringconGetUserCal(c, out);
}

Result ounce_serviceClone(Service* s, Service* out_s) {
    return serviceClone(s, out_s);
}

Result ounce_serviceCloneEx(Service* s, u32 tag, Service* out_s) {
    return serviceCloneEx(s, tag, out_s);
}

void ounce_serviceClose(Service* s) {
    serviceClose(s);
}

Result ounce_serviceConvertToDomain(Service* s) {
    return serviceConvertToDomain(s);
}

void ounce_serviceCreate(Service* s, Handle h) {
    serviceCreate(s, h);
}

void ounce_serviceCreateDomainSubservice(Service* s, Service* parent, u32 object_id) {
    serviceCreateDomainSubservice(s, parent, object_id);
}

void ounce_serviceCreateNonDomainSubservice(Service* s, Service* parent, Handle h) {
    serviceCreateNonDomainSubservice(s, parent, h);
}

Result ounce_serviceDispatchImpl(Service* s, u32 request_id, const void* in_data, u32 in_data_size, void* out_data, u32 out_data_size, SfDispatchParams disp) {
    return serviceDispatchImpl(s, request_id, in_data, in_data_size, out_data, out_data_size, disp);
}

u32 ounce_serviceGetObjectId(Service* s) {
    return serviceGetObjectId(s);
}

bool ounce_serviceIsActive(Service* s) {
    return serviceIsActive(s);
}

bool ounce_serviceIsDomain(Service* s) {
    return serviceIsDomain(s);
}

bool ounce_serviceIsDomainSubservice(Service* s) {
    return serviceIsDomainSubservice(s);
}

bool ounce_serviceIsOverride(Service* s) {
    return serviceIsOverride(s);
}

void* ounce_serviceMakeRequest(Service* s, u32 request_id, u32 context, u32 data_size, bool send_pid, const SfBufferAttrs buffer_attrs, const SfBuffer* buffers, u32 num_objects, const Service* const* objects, u32 num_handles, const Handle* handles) {
    return serviceMakeRequest(s, request_id, context, data_size, send_pid, buffer_attrs, buffers, num_objects, objects, num_handles, handles);
}

Result ounce_serviceParseResponse(Service* s, u32 out_size, void** out_data, u32 num_out_objects, Service* out_objects, const SfOutHandleAttrs out_handle_attrs, Handle* out_handles) {
    return serviceParseResponse(s, out_size, out_data, num_out_objects, out_objects, out_handle_attrs, out_handles);
}

Handle ounce_sessionmgrGetClientSession(SessionMgr* mgr, int slot) {
    return sessionmgrGetClientSession(mgr, slot);
}

SmServiceName ounce_smEncodeName(const char* name) {
    return smEncodeName(name);
}

Result ounce_smGetService(Service* service_out, const char* name) {
    return smGetService(service_out, name);
}

SmServiceName ounce_smServiceNameFromU64(u64 name) {
    return smServiceNameFromU64(name);
}

u64 ounce_smServiceNameToU64(SmServiceName name) {
    return smServiceNameToU64(name);
}

bool ounce_smServiceNamesAreEqual(SmServiceName a, SmServiceName b) {
    return smServiceNamesAreEqual(a, b);
}

Result ounce_socketInitializeDefault(void) {
    return socketInitializeDefault();
}

void ounce_swkbdInlineGetWindowSize(s32 *width, s32 *height) {
    swkbdInlineGetWindowSize(width, height);
}

void ounce_tipcClose(TipcService* s) {
    tipcClose(s);
}

void ounce_tipcCreate(TipcService* s, Handle h) {
    tipcCreate(s, h);
}

Result ounce_tipcDispatchImpl(TipcService* s, u32 request_id, const void* in_data, u32 in_data_size, void* out_data, u32 out_data_size, TipcDispatchParams disp) {
    return tipcDispatchImpl(s, request_id, in_data, in_data_size, out_data, out_data_size, disp);
}

void* ounce_tipcMakeRequest(u32 request_id, u32 data_size, bool send_pid, const SfBufferAttrs buffer_attrs, const SfBuffer* buffers, u32 num_handles, const Handle* handles) {
    return tipcMakeRequest(request_id, data_size, send_pid, buffer_attrs, buffers, num_handles, handles);
}

Result ounce_tipcParseResponse(u32 out_size, void** out_data, u32 num_out_objects, TipcService* out_objects, const SfOutHandleAttrs out_handle_attrs, Handle* out_handles) {
    return tipcParseResponse(out_size, out_data, num_out_objects, out_objects, out_handle_attrs, out_handles);
}

void ounce_tipcRequestHandle(HipcRequest* req, Handle handle) {
    tipcRequestHandle(req, handle);
}

void ounce_tipcRequestInBuffer(HipcRequest* req, const void* buffer, size_t size, HipcBufferMode mode) {
    tipcRequestInBuffer(req, buffer, size, mode);
}

void ounce_tipcRequestInOutBuffer(HipcRequest* req, void* buffer, size_t size, HipcBufferMode mode) {
    tipcRequestInOutBuffer(req, buffer, size, mode);
}

void ounce_tipcRequestOutBuffer(HipcRequest* req, void* buffer, size_t size, HipcBufferMode mode) {
    tipcRequestOutBuffer(req, buffer, size, mode);
}

Handle ounce_tipcResponseGetCopyHandle(HipcResponse* res) {
    return tipcResponseGetCopyHandle(res);
}

Handle ounce_tipcResponseGetMoveHandle(HipcResponse* res) {
    return tipcResponseGetMoveHandle(res);
}

u32 ounce_usbHsEpGetReportRingSize(UsbHsClientEpSession* s) {
    return usbHsEpGetReportRingSize(s);
}

Event* ounce_usbHsEpGetXferEvent(UsbHsClientEpSession* s) {
    return usbHsEpGetXferEvent(s);
}
