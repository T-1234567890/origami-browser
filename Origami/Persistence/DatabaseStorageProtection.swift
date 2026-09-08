import Foundation
import Darwin

/// Tighten only the dedicated database directory and its owned regular files.
/// Refuse symlinks/unowned storage rather than silently opening it insecurely.
enum DatabaseStorageProtection {
    enum Failure: LocalizedError {
        case inaccessible
        var errorDescription: String? { "Origami could not secure its database storage. Check the storage location and permissions." }
    }
    static func prepare(_ file: URL) throws {
        guard file.isFileURL else { throw Failure.inaccessible }
        let directory = file.deletingLastPathComponent()
        let sharedRoots = [URL(fileURLWithPath: "/"), FileManager.default.homeDirectoryForCurrentUser,
                           FileManager.default.temporaryDirectory, URL.applicationSupportDirectory]
        guard !sharedRoots.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL }) else { throw Failure.inaccessible }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try secure(directory, directory: true)
            try secure(file, create: true)
            try sidecars(file)
        } catch { throw Failure.inaccessible }
    }
    static func sidecars(_ file: URL) throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            try secure(URL(fileURLWithPath: file.path + suffix), optional: true)
        }
    }
    private static func secure(_ url: URL, directory: Bool = false, create: Bool = false, optional: Bool = false) throws {
        let flags = (directory ? O_RDONLY | O_DIRECTORY : O_RDWR) | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0)
        let fd = url.withUnsafeFileSystemRepresentation { Darwin.open($0!, flags, mode_t(0o600)) }
        if fd < 0 { if optional && errno == ENOENT { return }; throw Failure.inaccessible }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1,
              fchmod(fd, mode_t(directory ? 0o700 : 0o600)) == 0 else { throw Failure.inaccessible }
    }
}
