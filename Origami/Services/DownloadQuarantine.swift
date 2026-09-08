import Foundation
import CoreServices
import Darwin

/// Public Launch Services quarantine properties, independent of WKDownload's implementation.
struct DownloadQuarantine {
    enum Failure: LocalizedError {
        case invalidDestination, verificationFailed
        var errorDescription: String? {
            "Origami could not verify quarantine protection for this download. The file was not marked complete and cannot be opened from Origami. Choose a local destination and retry."
        }
    }
    static func metadataURL(_ url: URL?) -> URL? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.user = nil; parts.password = nil; parts.fragment = nil
        // Signed URLs and search parameters can contain credentials. Keep the source path only.
        parts.query = nil
        return parts.url
    }
    static func properties(at file: URL) throws -> [String: Any] {
        let fresh = NSURL(fileURLWithPath: file.path)
        return try fresh.resourceValues(forKeys: [.quarantinePropertiesKey])[.quarantinePropertiesKey] as? [String: Any] ?? [:]
    }
    static func enforce(at file: URL, downloadURL: URL?, originURL: URL?) throws {
        guard file.isFileURL else { throw Failure.invalidDestination }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let type = attributes[.type] as? FileAttributeType, type == .typeRegular || type == .typeDirectory else { throw Failure.invalidDestination }
        var properties = try self.properties(at: file)
        // Preserve existing quarantine properties; never clear flags or grant user approval.
        properties[kLSQuarantineTypeKey as String] = kLSQuarantineTypeWebDownload as String
        if properties[kLSQuarantineAgentNameKey as String] == nil { properties[kLSQuarantineAgentNameKey as String] = "Origami" }
        if properties[kLSQuarantineAgentBundleIdentifierKey as String] == nil {
            properties[kLSQuarantineAgentBundleIdentifierKey as String] = Bundle.main.bundleIdentifier ?? "dev.1234567890.Origami"
        }
        if properties[kLSQuarantineTimeStampKey as String] == nil { properties[kLSQuarantineTimeStampKey as String] = Date() }
        for key in [kLSQuarantineDataURLKey as String, kLSQuarantineOriginURLKey as String] {
            let old = (properties[key] as? URL) ?? (properties[key] as? String).flatMap(URL.init(string:))
            if let old { properties[key] = metadataURL(old) }
        }
        let dataURL = metadataURL(downloadURL)
        if let dataURL { properties[kLSQuarantineDataURLKey as String] = dataURL }
        if let origin = metadataURL(originURL), origin != dataURL {
            properties[kLSQuarantineOriginURLKey as String] = origin
        }
        try (file as NSURL).setResourceValue(properties, forKey: .quarantinePropertiesKey)
        // A fresh URL avoids validating Foundation's cached resource values after the write.
        let verified = try self.properties(at: file)
        // Launch Services may omit optional type/URL fields on readback. Verify its
        // public quarantine identity and the on-disk attribute, without interpreting private flags.
        // Timestamp can also be absent when Launch Services reads an application bundle.
        guard try !attribute("com.apple.quarantine", at: file).isEmpty,
              !(verified[kLSQuarantineAgentNameKey as String] as? String ?? "").isEmpty else { throw Failure.verificationFailed }
        try preserveOrigins(at: file, urls: [dataURL, metadataURL(originURL)].compactMap { $0 })
    }
    static func attribute(_ name: String, at file: URL) throws -> Data {
        let size = file.withUnsafeFileSystemRepresentation { getxattr($0!, name, nil, 0, 0, XATTR_NOFOLLOW) }
        if size < 0 {
            if errno == ENOATTR { return Data() }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard size <= 65_536 else { throw Failure.verificationFailed }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { buffer in
            file.withUnsafeFileSystemRepresentation { getxattr($0!, name, buffer.baseAddress, size, 0, XATTR_NOFOLLOW) }
        }
        guard read == size else { throw Failure.verificationFailed }
        return data
    }
    private static func preserveOrigins(at file: URL, urls: [URL]) throws {
        guard !urls.isEmpty else { return }
        let key = "com.apple.metadata:kMDItemWhereFroms"
        let existing = try attribute(key, at: file)
        let previous = (try? PropertyListSerialization.propertyList(from: existing, format: nil)) as? [String] ?? []
        var seen = Set<String>()
        let sanitizedPrevious = previous.compactMap { metadataURL(URL(string: $0))?.absoluteString }
        let values = (urls.map(\.absoluteString) + sanitizedPrevious).filter { seen.insert($0).inserted }
        let encoded = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        let result = encoded.withUnsafeBytes { buffer in
            file.withUnsafeFileSystemRepresentation { setxattr($0!, key, buffer.baseAddress, encoded.count, 0, XATTR_NOFOLLOW) }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard try attribute(key, at: file) == encoded else { throw Failure.verificationFailed }
    }
}
