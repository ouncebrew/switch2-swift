import COunceMitm
import Ounce

/// The fsp-srv interfaces a hook can be attached to.
///
/// The hook table itself is service-agnostic: an interface is a caller-defined
/// `UInt32`. These are the values the fsp-srv specialization uses.
public enum FsHookInterface: UInt32, Sendable {
    /// fsp-srv itself.
    case root = 0

    /// `IFileSystem` objects.
    case fileSystem = 1

    /// `IFile` objects.
    case file = 2

    /// `IDirectory` objects.
    case directory = 3

    /// `IStorage` objects.
    case storage = 4
}

/// The fsp-srv command IDs the FS layer names.
///
/// Object interfaces have their own command spaces, so their IDs are not here:
/// they belong to the interface, not to fsp-srv.
public enum FsHookCommand: UInt32, Sendable {
    case openFileSystemWithPatch = 7
    case openFileSystemWithId = 10
    case openBisStorage = 12
    case openSdCardFileSystem = 18
    case openSaveDataFileSystem = 51
    case openDataStorageByCurrentProcess = 200
    case openDataStorageByProgramID = 201
    case openDataStorageByDataID = 202
    case openDataStorageWithProgramIndex = 205
    case openDataStorageByPath = 206
}

/// The fsp-srv specialization of ``MitmHookTable``.
public typealias FsHookTable = MitmHookTable

/// The fsp-srv specialization of ``MitmHookContext``.
public typealias FsHookContext = MitmHookContext

/// The fsp-srv specialization of ``MitmHookOverride``.
public typealias FsHookOverride = MitmHookOverride

/// The fsp-srv specialization of ``MitmHookLoaderServer``.
public typealias FsHookLoaderServer = MitmHookLoaderServer
