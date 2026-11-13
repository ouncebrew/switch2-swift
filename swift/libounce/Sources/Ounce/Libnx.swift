/// The whole of libnx, re-exported.
///
/// `COunce` re-exports `<switch.h>` and `<ouncehen.h>`, so importing `Ounce`
/// also brings in every libnx type, constant and function — `hidInitialize`,
/// `svcSleepThread`, `HidNpadButton_A`, `AccountUid`, all of it.
///
/// The one thing Swift cannot call on its own is the declarations libnx marks
/// `NX_INLINE` or `NX_CONSTEXPR`, because those are `static inline` in C and
/// produce no symbol. Every one of them is re-exported from the shim as a real
/// function with an `ounce_` prefix, so `padGetButtons` is
/// `ounce_padGetButtons`, `smGetService` is `ounce_smGetService`, and so on.
/// Dropping the prefix gives the libnx name.
///
/// libnx's `Result` is a `u32` typedef and shadows the standard library's
/// `Result`; write `Swift.Result` when you need the latter.
@_exported import COunce
