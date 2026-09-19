import Foundation

struct MigrationAccessRequired: Error {
    let root: URL
}
enum MigrationAccess {
    static func denied(_ error: Error, depth: Int = 0) -> Bool {
        guard depth < 8 else { return false }
        if error is MigrationAccessRequired { return true }
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoPermissionError { return true }
        if value.domain == NSPOSIXErrorDomain && [1, 13].contains(value.code) { return true }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { return denied(underlying, depth: depth + 1) }
        return false
    }
    /// A missing alternate location must not overwrite an earlier privacy denial.
    static func readRoots(_ roots: [URL], read: (URL) throws -> [MigrationProfile]) throws -> [MigrationProfile] {
        var blocked: URL?
        var last: Error = MigrationFailure.unsupported
        for root in roots {
            do { return try read(root) }
            catch {
                if denied(error), blocked == nil { blocked = root }
                last = error
            }
        }
        if let blocked { throw MigrationAccessRequired(root: blocked) }
        throw last
    }
}
