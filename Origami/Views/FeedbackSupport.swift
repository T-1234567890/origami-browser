import SwiftUI
import AppKit

/// A deliberately small allowlist; never collect browser state or environment diagnostics.
enum SupportInfo {
    static func text(info: [String: Any], system: OperatingSystemVersion, architecture: String) -> String {
        let identity = ReleaseIdentity.from(info: info)
        let version = identity?.displayVersion
            ?? "Origami \(info["CFBundleShortVersionString"] as? String ?? "Unknown") — Development"
        let build = info["CFBundleVersion"] as? String ?? "Unknown"
        let channel = identity.map { $0.stage == .beta ? "Beta" : "Stable" } ?? "Development"
        return """
        \(version)
        Build \(build)
        macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)
        Architecture: \(architecture)
        Channel: \(channel)
        """
    }

    static var current: String {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "Unknown"
        #endif
        return text(info: Bundle.main.infoDictionary ?? [:],
                    system: ProcessInfo.processInfo.operatingSystemVersion, architecture: architecture)
    }
}

enum SupportDestination: String, CaseIterable, Identifiable {
    case bug = "Report a Bug"
    case feature = "Request a Feature"
    case issues = "View Known Issues"
    case roadmap = "View Roadmap"
    case security = "Security Issue"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .bug: "ladybug"
        case .feature: "lightbulb"
        case .issues: "list.bullet.rectangle"
        case .roadmap: "map"
        case .security: "lock.shield"
        }
    }
    var url: URL {
        switch self {
        case .bug, .feature:
            // No issue templates are currently distributed in this repository.
            var components = URLComponents(url: OrigamiLinks.repository.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "title", value: self == .bug ? "Bug: " : "Feature request: ")]
            return components.url!
        case .issues: return OrigamiLinks.repository.appending(path: "issues")
        case .roadmap: return OrigamiLinks.repository.appending(path: "blob/main/roadmap.md")
        case .security: return OrigamiLinks.repository.appending(path: "blob/main/SECURITY.md")
        }
    }
}

struct FeedbackSupportPopover: View {
    let open: (URL) -> Void
    @State private var copied = false
    @State private var copyID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Feedback & Support").font(.headline).padding(.horizontal, 8).padding(.vertical, 6)
            ForEach(SupportDestination.allCases) { destination in
                Button { open(destination.url) } label: {
                    row(destination.rawValue, symbol: destination.symbol, link: true)
                }
            }
            Divider().padding(.vertical, 4)
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                copied = pasteboard.setString(SupportInfo.current, forType: .string)
                copyID = UUID()
            } label: {
                row(copied ? "Copied" : "Copy Info", symbol: copied ? "checkmark" : "doc.on.doc", link: false)
            }
            .help("Copy app version, build, macOS version, architecture, and release channel only.")
        }
        .buttonStyle(.plain)
        .padding(10)
        .frame(width: 260)
        .task(id: copyID) {
            guard copyID != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }

    private func row(_ title: String, symbol: String, link: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(title)
            Spacer(minLength: 8)
            if link {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}
