import Foundation

enum GeckoMigrationSession {
    static func decode(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.starts(with: Array("mozLz40\0".utf8)) else { return data }
        guard bytes.count >= 12 else { throw MigrationFailure.invalid }
        let size = (0..<4).reduce(0) { $0 | Int(bytes[8 + $1]) << ($1 * 8) }
        guard size > 0, size <= 32_000_000 else { throw MigrationFailure.tooLarge }
        var i = 12, output: [UInt8] = []; output.reserveCapacity(size)
        func length(_ initial: Int) throws -> Int {
            var n = initial
            if initial == 15 {
                var byte = 255
                while byte == 255 {
                    guard i < bytes.count else { throw MigrationFailure.invalid }
                    byte = Int(bytes[i]); i += 1; n += byte
                    guard n <= size else { throw MigrationFailure.invalid }
                }
            }
            return n
        }
        while i < bytes.count {
            let token = Int(bytes[i]); i += 1
            let literal = try length(token >> 4)
            guard literal <= bytes.count - i, literal <= size - output.count else { throw MigrationFailure.invalid }
            output += bytes[i..<i + literal]; i += literal
            if i == bytes.count { break }
            guard i + 2 <= bytes.count else { throw MigrationFailure.invalid }
            let distance = Int(bytes[i]) | Int(bytes[i + 1]) << 8; i += 2
            let match = try length(token & 15) + 4
            guard distance > 0, distance <= output.count, match <= size - output.count else { throw MigrationFailure.invalid }
            for _ in 0..<match { output.append(output[output.count - distance]) }
        }
        guard output.count == size else { throw MigrationFailure.invalid }
        return Data(output)
    }
    static func read(_ data: Data) throws -> [MigrationTab] {
        guard let root = try JSONSerialization.jsonObject(with: decode(data)) as? [String: Any],
              let windows = root["windows"] as? [[String: Any]], windows.count <= 500 else { throw MigrationFailure.invalid }
        var result: [MigrationTab] = []
        for (windowIndex, window) in windows.enumerated() where window["isPrivate"] as? Bool != true {
            let groups = window["groups"] as? [[String: Any]] ?? []
            for tab in window["tabs"] as? [[String: Any]] ?? [] where tab["isPrivate"] as? Bool != true {
                guard let entries = tab["entries"] as? [[String: Any]], !entries.isEmpty else { continue }
                let index = (tab["index"] as? Int ?? entries.count) - 1
                guard entries.indices.contains(index), let url = MigrationInput.url(entries[index]["url"] as? String) else { continue }
                let id = (tab["groupId"] as? String) ?? (tab["groupId"] as? Int).map(String.init)
                let group = groups.first { (($0["id"] as? String) ?? ($0["id"] as? Int).map(String.init)) == id && id != nil }
                let title = group?["name"] as? String ?? group?["title"] as? String
                result.append(.init(url: url, title: String((entries[index]["title"] as? String ?? url.absoluteString).prefix(2000)), pinned: tab["pinned"] as? Bool == true, group: title.map { "Window \(windowIndex + 1): " + String($0.prefix(100)) }))
                guard result.count <= 5000 else { throw MigrationFailure.tooLarge }
            }
        }
        return result
    }
}

/// Conservative reader for unencrypted Chromium SNSS v1/v3 snapshots. Unknown navigation
/// pruning formats reject this category rather than reopening an incorrect navigation.
enum ChromiumMigrationSession {
    struct Tab {
        var window = -1, position = 0, selected = -1
        var pinned = false
        var entries: [Int: MigrationTab] = [:]
    }
    static func read(_ folder: URL) throws -> [MigrationTab]? {
        if let directory = try MigrationInput.child("Sessions", in: folder) {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard files.count <= 500 else { throw MigrationFailure.tooLarge }
            if let file = files.filter({ $0.lastPathComponent.hasPrefix("Session_") }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first {
                return try parse(MigrationInput.read(file))
            }
        }
        for name in ["Current Session", "Last Session"] {
            if let file = try MigrationInput.child(name, in: folder) { return try parse(MigrationInput.read(file)) }
        }
        return nil
    }
    static func parse(_ data: Data) throws -> [MigrationTab] {
        let bytes = [UInt8](data)
        func integer(_ start: Int, _ count: Int, in b: [UInt8]) throws -> Int {
            guard start >= 0, start + count <= b.count else { throw MigrationFailure.invalid }
            return (0..<count).reduce(0) { $0 | Int(b[start + $1]) << ($1 * 8) }
        }
        guard bytes.count >= 8, Array(bytes.prefix(4)) == Array("SNSS".utf8) else { throw MigrationFailure.unsupported }
        let version = try integer(4, 4, in: bytes)
        guard [1, 3].contains(version) else { throw MigrationFailure.unsupported }
        var hasMarker = version == 1
        var offset = 8, tabs: [Int: Tab] = [:], closedWindows = Set<Int>()
        while offset < bytes.count {
            let length = try integer(offset, 2, in: bytes); offset += 2
            guard length >= 1, offset + length <= bytes.count else { throw MigrationFailure.invalid }
            let command = bytes[offset], payload = Array(bytes[(offset + 1)..<(offset + length)]); offset += length
            switch command {
            case 255: hasMarker = true
            case 0:
                let window = try integer(0, 4, in: payload), tab = try integer(4, 4, in: payload)
                tabs[tab, default: Tab()].window = window
            case 2, 7:
                let id = try integer(0, 4, in: payload), value = try integer(4, 4, in: payload)
                if command == 2 { tabs[id, default: Tab()].position = value } else { tabs[id, default: Tab()].selected = value }
            case 12:
                let id = try integer(0, 4, in: payload)
                guard payload.count >= 5 else { throw MigrationFailure.invalid }
                tabs[id, default: Tab()].pinned = payload[4] != 0
            case 16: tabs.removeValue(forKey: try integer(0, 4, in: payload))
            case 17: closedWindows.insert(try integer(0, 4, in: payload))
            case 5, 11, 24: throw MigrationFailure.unsupported
            case 6:
                // Pickle header, tab ID, navigation index, UTF-8 URL, UTF-16 title.
                let size = try integer(0, 4, in: payload)
                guard size <= payload.count - 4 else { throw MigrationFailure.invalid }
                let id = try integer(4, 4, in: payload), index = try integer(8, 4, in: payload)
                let count = try integer(12, 4, in: payload)
                guard count <= 16384, 16 + count <= payload.count else { throw MigrationFailure.invalid }
                let urlText = String(bytes: payload[16..<16 + count], encoding: .utf8)
                let titleStart = 16 + ((count + 3) / 4) * 4
                let titleCount = try integer(titleStart, 4, in: payload)
                guard titleCount <= 2000, titleStart + 4 + titleCount * 2 <= payload.count else { throw MigrationFailure.invalid }
                let title = String(data: Data(payload[(titleStart + 4)..<(titleStart + 4 + titleCount * 2)]), encoding: .utf16LittleEndian) ?? ""
                if let url = MigrationInput.url(urlText) { tabs[id, default: Tab()].entries[index] = .init(url: url, title: title, pinned: false) }
            default: break // Unused window presentation/metadata commands do not affect URLs.
            }
            guard tabs.count <= 5000, tabs.values.reduce(0, { $0 + $1.entries.count }) <= 50000 else { throw MigrationFailure.tooLarge }
        }
        guard hasMarker else { throw MigrationFailure.invalid }
        return tabs.sorted { ($0.value.window, $0.value.position, $0.key) < ($1.value.window, $1.value.position, $1.key) }.compactMap { _, tab in
            guard tab.window >= 0, !closedWindows.contains(tab.window), var selected = tab.entries[tab.selected] else { return nil }
            selected.pinned = tab.pinned; return selected
        }
    }
}
