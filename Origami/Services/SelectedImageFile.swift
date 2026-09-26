import Foundation

/// Read a user-selected image only after its file provider has materialized it.
/// Call off the main thread: coordination may wait for an iCloud download.
enum SelectedImageFile {
    enum Failure: Error { case oversized, unavailable }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        // An offline provider must not leave an import waiting indefinitely.
        let timeout = DispatchWorkItem { coordinator.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60, execute: timeout)
        defer { timeout.cancel() }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { availableURL in
            timeout.cancel()
            result = Result {
                let values = try availableURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { throw Failure.unavailable }
                if let size = values.fileSize, size > maximumBytes { throw Failure.oversized }
                let file = try FileHandle(forReadingFrom: availableURL)
                defer { try? file.close() }
                var data = Data()
                while true {
                    let chunk = try file.read(upToCount: min(1_048_576, maximumBytes + 1 - data.count)) ?? Data()
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    guard data.count <= maximumBytes else { throw Failure.oversized }
                }
                guard !data.isEmpty else { throw Failure.unavailable }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure.unavailable }
        return try result.get()
    }
}
