/* SPDX-License-Identifier: MIT
 *
 * C surface for the Swift wrapper.
 *
 * libnx marks its small accessors NX_INLINE or NX_CONSTEXPR, which are
 * `static inline` in C. Swift's Clang importer cannot call those, so every one
 * the wrapper needs is re-exported here as a real function. Everything else --
 * consoleInit, padUpdate, fsdevMountSdmc, appletMainLoop, jitCreate and the
 * rest -- is a real symbol and is used directly from <switch.h>.
 *
 * <ouncehen.h> is included for its types and for the one non-inline function,
 * ouncehenJitPublishRanges. Its client functions are all NX_INLINE, so the
 * ones the wrapper exposes are re-exported below as well.
 */
#pragma once

#include <switch.h>
#include <ouncehen.h>

/* ---- Result -------------------------------------------------------------- */

/// True when the result is success. libnx's R_SUCCEEDED is `(res) == 0`.
bool ounce_result_succeeded(Result rc);

/* ---- Console ------------------------------------------------------------- */

/// Initialises the default console and returns it.
PrintConsole *ounce_console_init(void);

/// Draws the console. Nothing appears until this runs.
void ounce_console_update(void);

/// Clears the console.
void ounce_console_clear(void);

/// Restores the console and releases it.
void ounce_console_exit(void);

/// Writes a line to the console buffer. Call ounce_console_update to draw it.
void ounce_console_puts(const char *text);

/* ---- Applet -------------------------------------------------------------- */

/// False once the system has asked the program to exit.
bool ounce_applet_main_loop(void);

/* ---- Pad ----------------------------------------------------------------- */

void ounce_pad_init_default(PadState *pad);
void ounce_pad_update(PadState *pad);
u64 ounce_pad_buttons(const PadState *pad);
u64 ounce_pad_buttons_down(const PadState *pad);
u64 ounce_pad_buttons_up(const PadState *pad);
bool ounce_pad_connected(const PadState *pad);
HidAnalogStickState ounce_pad_stick(const PadState *pad, unsigned index);

/* ---- Filesystem ---------------------------------------------------------- */

Result ounce_fsdev_mount_sdmc(void);
Result ounce_fsdev_unmount_all(void);

/* ---- Hosversion ---------------------------------------------------------- */

/// True when the program is running under OunceHEN.
bool ounce_hosversion_is_ouncehen(void);

/* ---- OunceHEN ------------------------------------------------------------ */

/// Opens a HEN homebrew session through RO's ldr:ro override. The caller owns
/// *out and closes it with ounce_service_close.
Result ounce_hen_open(Service *out);

Result ounce_hen_status(Service *s, HenStatus *out);
Result ounce_hen_filesystem_root(Service *s, Handle *out);
Result ounce_hen_settings_session(Service *s, Handle *out);
Result ounce_hen_process_handle(Service *s, Handle *out);
Result ounce_hen_service_manager(Service *s, Handle *out);

void ounce_service_close(Service *s);

/* ---- Complete re-export of libnx's inline API ---------------------------- */
/*
 * Every NX_INLINE and NX_CONSTEXPR function in the headers, re-exported as a
 * real symbol. The Clang importer already reaches every type, constant and
 * non-inline function through <switch.h>; these are the only declarations it
 * cannot call, because they are `static inline` in C.
 *
 * The names are the libnx ones with an `ounce_` prefix, so a Swift caller can
 * find the original by dropping the prefix.
 */
void ounce_serviceRequestFormatProcessBuffer(CmifRequestFormat* fmt, u32 attr);
void ounce_serviceRequestProcessBuffer(CmifRequest* req, const SfBuffer* buf, u32 attr);
void ounce_serviceResponseGetHandle(CmifResponse* res, SfOutHandleAttr type, Handle* out);
void ounce_tipcRequestFormatProcessBuffer(TipcRequestFormat* fmt, u32 attr);
void ounce_tipcRequestProcessBuffer(HipcRequest* req, const SfBuffer* buf, u32 attr);
void ounce_tipcResponseGetHandle(HipcResponse* res, SfOutHandleAttr type, Handle* out);
bool ounce_accountUidIsValid(const AccountUid *Uid);
Event * ounce_appletHolderGetExitEvent(AppletHolder *h);
size_t ounce_audrenGetInputParamSize(const AudioRendererConfig* config);
int ounce_audrenGetMemPoolCount(const AudioRendererConfig* config);
size_t ounce_audrenGetOutputParamSize(const AudioRendererConfig* config);
u32 ounce_btdevGattAttributeGetConnectionHandle(BtdevGattAttribute *a);
u16 ounce_btdevGattAttributeGetHandle(BtdevGattAttribute *a);
u8 ounce_btdevGattAttributeGetType(BtdevGattAttribute *a);
void ounce_btdevGattAttributeGetUuid(BtdevGattAttribute *a, BtdrvGattAttributeUuid *out);
u16 ounce_btdevGattCharacteristicGetInstanceId(BtdevGattCharacteristic *c);
u8 ounce_btdevGattCharacteristicGetProperties(BtdevGattCharacteristic *c);
u16 ounce_btdevGattServiceGetEndGroupHandle(BtdevGattService *s);
u16 ounce_btdevGattServiceGetInstanceId(BtdevGattService *s);
u16 ounce_btdevGattServiceIsPrimaryService(BtdevGattService *s);
Result ounce_cmifCloneCurrentObject(Handle h, Handle* out_h);
Result ounce_cmifCloneCurrentObjectEx(Handle h, u32 tag, Handle* out_h);
Result ounce_cmifConvertCurrentObjectToDomain(Handle h, u32* out_object_id);
Result ounce_cmifCopyFromCurrentDomain(Handle h, u32 object_id, Handle* out_h);
void* ounce_cmifGetAlignedDataStart(u32* data_words, void* base);
void ounce_cmifMakeCloseRequest(void* base, u32 object_id);
void* ounce_cmifMakeControlRequest(void* base, u32 request_id, u32 size);
CmifRequest ounce_cmifMakeRequest(void* base, CmifRequestFormat fmt);
Result ounce_cmifParseResponse(CmifResponse* res, void* base, bool is_domain, u32 size);
Result ounce_cmifQueryPointerBufferSize(Handle h, u16* out_size);
void ounce_cmifRequestHandle(CmifRequest* req, Handle handle);
void ounce_cmifRequestInAutoBuffer(CmifRequest* req, const void* buffer, size_t size, HipcBufferMode mode);
void ounce_cmifRequestInBuffer(CmifRequest* req, const void* buffer, size_t size, HipcBufferMode mode);
void ounce_cmifRequestInOutBuffer(CmifRequest* req, void* buffer, size_t size, HipcBufferMode mode);
void ounce_cmifRequestInPointer(CmifRequest* req, const void* buffer, size_t size);
void ounce_cmifRequestObject(CmifRequest* req, u32 object_id);
void ounce_cmifRequestOutAutoBuffer(CmifRequest* req, void* buffer, size_t size, HipcBufferMode mode);
void ounce_cmifRequestOutBuffer(CmifRequest* req, void* buffer, size_t size, HipcBufferMode mode);
void ounce_cmifRequestOutFixedPointer(CmifRequest* req, void* buffer, size_t size);
void ounce_cmifRequestOutPointer(CmifRequest* req, void* buffer, size_t size);
Handle ounce_cmifResponseGetCopyHandle(CmifResponse* res);
Handle ounce_cmifResponseGetMoveHandle(CmifResponse* res);
u32 ounce_cmifResponseGetObject(CmifResponse* res);
bool ounce_detectDebugger(void);
bool ounce_detectMesosphere(void);
Result ounce_friendsGetFriendInvitationNotificationEvent(Event *out_event);
FsDirectoryEntry* ounce_fsdevDirGetEntries(fsdev_dir_t *dir);
bool ounce_hidKeyboardStateGetKey(const HidKeyboardState *state, HidKeyboardKey key);
HipcRequest ounce_hipcCalcRequestLayout(HipcMetadata meta, void* base);
void* ounce_hipcGetBufferAddress(const HipcBufferDescriptor* desc);
size_t ounce_hipcGetBufferSize(const HipcBufferDescriptor* desc);
void* ounce_hipcGetStaticAddress(const HipcStaticDescriptor* desc);
size_t ounce_hipcGetStaticSize(const HipcStaticDescriptor* desc);
HipcBufferDescriptor ounce_hipcMakeBuffer(const void* buffer, size_t size, HipcBufferMode mode);
HipcRecvListEntry ounce_hipcMakeRecvStatic(void* buffer, size_t size);
HipcRequest ounce_hipcMakeRequest(void* base, HipcMetadata meta);
HipcStaticDescriptor ounce_hipcMakeSendStatic(const void* buffer, size_t size, u8 index);
HipcParsedRequest ounce_hipcParseRequest(void* base);
HipcResponse ounce_hipcParseResponse(void* base);
void ounce_irsGetIrLedProcessorDefaultConfig(IrsIrLedProcessorConfig *config);
void* ounce_jitGetRwAddr(Jit* j);
void* ounce_jitGetRxAddr(Jit* j);
void ounce_leventInit(LEvent* le, bool signaled, bool autoclear);
void ounce_lp2pGroupInfoSetFrequencyChannel(Lp2pGroupInfo *info, u16 frequency, s16 channel);
void ounce_lp2pGroupInfoSetMemberCountMax(Lp2pGroupInfo *info, size_t count);
void ounce_lp2pGroupInfoSetStealthEnabled(Lp2pGroupInfo *info, bool flag);
void ounce_ncmContentInfoSizeToU64(const NcmContentInfo *info, u64 *out);
void ounce_ncmU64ToContentInfoSize(const u64 size, NcmContentInfo *info);
void ounce_notifAlarmSettingSetIsMuted(NotifAlarmSetting *alarm_setting, bool flag);
void ounce_notifAlarmSettingSetUid(NotifAlarmSetting *alarm_setting, AccountUid uid);
Result ounce_notifGetNotificationSystemEvent(Event *out_event);
int ounce_nxlinkStdio(void);
int ounce_nxlinkStdioForDebug(void);
u32 ounce_padGetAttributes(const PadState* pad);
u64 ounce_padGetButtons(const PadState* pad);
u64 ounce_padGetButtonsDown(const PadState* pad);
u64 ounce_padGetButtonsUp(const PadState* pad);
u32 ounce_padGetGcTriggerPos(const PadState* pad, unsigned i);
HidAnalogStickState ounce_padGetStickPos(const PadState* pad, unsigned i);
u32 ounce_padGetStyleSet(const PadState* pad);
void ounce_padInitializeAny(PadState* pad);
void ounce_padInitializeDefault(PadState* pad);
bool ounce_padIsConnected(const PadState* pad);
bool ounce_padIsHandheld(const PadState* pad);
bool ounce_padIsNpadActive(const PadState* pad, HidNpadIdType id);
u64 ounce_padRepeaterGetButtons(const PadRepeater* r);
void ounce_padRepeaterInitialize(PadRepeater* r, u16 delay, u16 repeat);
void ounce_pselUiSetAllowUserCreation(PselUiSettings *ui, bool flag);
void ounce_pselUiSetNetworkServiceRequired(PselUiSettings *ui, bool flag);
void ounce_pselUiSetSkipButtonEnabled(PselUiSettings *ui, bool flag);
bool ounce_ringconGetErrorFlag(RingCon *c, RingConErrorFlag flag);
u32 ounce_ringconGetErrorFlags(RingCon *c);
RingConFwVersion ounce_ringconGetFwVersion(RingCon *c);
void ounce_ringconGetId(RingCon *c, u64 *id_l, u64 *id_h);
void ounce_ringconGetManuCal(RingCon *c, RingConManuCal *out);
s32 ounce_ringconGetTotalPushCount(RingCon *c);
s16 ounce_ringconGetUnkCal(RingCon *c);
void ounce_ringconGetUserCal(RingCon *c, RingConUserCal *out);
Result ounce_serviceClone(Service* s, Service* out_s);
Result ounce_serviceCloneEx(Service* s, u32 tag, Service* out_s);
void ounce_serviceClose(Service* s);
Result ounce_serviceConvertToDomain(Service* s);
void ounce_serviceCreate(Service* s, Handle h);
void ounce_serviceCreateDomainSubservice(Service* s, Service* parent, u32 object_id);
void ounce_serviceCreateNonDomainSubservice(Service* s, Service* parent, Handle h);
Result ounce_serviceDispatchImpl(Service* s, u32 request_id, const void* in_data, u32 in_data_size, void* out_data, u32 out_data_size, SfDispatchParams disp);
u32 ounce_serviceGetObjectId(Service* s);
bool ounce_serviceIsActive(Service* s);
bool ounce_serviceIsDomain(Service* s);
bool ounce_serviceIsDomainSubservice(Service* s);
bool ounce_serviceIsOverride(Service* s);
void* ounce_serviceMakeRequest(Service* s, u32 request_id, u32 context, u32 data_size, bool send_pid, const SfBufferAttrs buffer_attrs, const SfBuffer* buffers, u32 num_objects, const Service* const* objects, u32 num_handles, const Handle* handles);
Result ounce_serviceParseResponse(Service* s, u32 out_size, void** out_data, u32 num_out_objects, Service* out_objects, const SfOutHandleAttrs out_handle_attrs, Handle* out_handles);
Handle ounce_sessionmgrGetClientSession(SessionMgr* mgr, int slot);
SmServiceName ounce_smEncodeName(const char* name);
Result ounce_smGetService(Service* service_out, const char* name);
SmServiceName ounce_smServiceNameFromU64(u64 name);
u64 ounce_smServiceNameToU64(SmServiceName name);
bool ounce_smServiceNamesAreEqual(SmServiceName a, SmServiceName b);
Result ounce_socketInitializeDefault(void);
void ounce_swkbdInlineGetWindowSize(s32 *width, s32 *height);
void ounce_tipcClose(TipcService* s);
void ounce_tipcCreate(TipcService* s, Handle h);
Result ounce_tipcDispatchImpl(TipcService* s, u32 request_id, const void* in_data, u32 in_data_size, void* out_data, u32 out_data_size, TipcDispatchParams disp);
void* ounce_tipcMakeRequest(u32 request_id, u32 data_size, bool send_pid, const SfBufferAttrs buffer_attrs, const SfBuffer* buffers, u32 num_handles, const Handle* handles);
Result ounce_tipcParseResponse(u32 out_size, void** out_data, u32 num_out_objects, TipcService* out_objects, const SfOutHandleAttrs out_handle_attrs, Handle* out_handles);
void ounce_tipcRequestHandle(HipcRequest* req, Handle handle);
void ounce_tipcRequestInBuffer(HipcRequest* req, const void* buffer, size_t size, HipcBufferMode mode);
void ounce_tipcRequestInOutBuffer(HipcRequest* req, void* buffer, size_t size, HipcBufferMode mode);
void ounce_tipcRequestOutBuffer(HipcRequest* req, void* buffer, size_t size, HipcBufferMode mode);
Handle ounce_tipcResponseGetCopyHandle(HipcResponse* res);
Handle ounce_tipcResponseGetMoveHandle(HipcResponse* res);
u32 ounce_usbHsEpGetReportRingSize(UsbHsClientEpSession* s);
Event* ounce_usbHsEpGetXferEvent(UsbHsClientEpSession* s);
