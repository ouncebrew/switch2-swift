import COunce

/// Filesystem devices.
///
/// The console has no descriptor table, so there is no `open`/`read`/`write`.
/// libnx instead mounts a filesystem under a device name, and the C library's
/// `fopen` and friends work on paths under that name. Mounting the SD card
/// makes `sdmc:/...` paths usable.
public enum FileSystem {
    /// Mounts the SD card as `sdmc:`.
    ///
    /// ```swift
    /// try FileSystem.mountSdCard()
    /// let file = fopen("sdmc:/hello.txt", "w")
    /// ```
    public static func mountSdCard() throws {
        let rc = ounce_fsdev_mount_sdmc()
        guard ounce_result_succeeded(rc) else {
            throw OunceError("mounting sdmc:", rc)
        }
    }

    /// Unmounts every device.
    public static func unmountAll() throws {
        let rc = ounce_fsdev_unmount_all()
        guard ounce_result_succeeded(rc) else {
            throw OunceError("unmounting devices", rc)
        }
    }
}
