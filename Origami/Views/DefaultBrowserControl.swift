import SwiftUI
import AppKit

struct DefaultBrowserControl: View {
    var compact = false
    @Environment(\.profileAppearance) private var appearance
    @State private var isDefault = false
    @State private var requesting = false
    @State private var error: String?
    @State private var useSystemSettings = false

    private var actionTitle: String {
        L10n.string(useSystemSettings ? "Open System Settings…" : "Set as Default…")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if compact {
                Button { Task { await request() } } label: {
                    Group {
                        if isDefault {
                            Label(L10n.string("Origami is your default browser"), systemImage: "checkmark")
                        } else {
                            Label(actionTitle, systemImage: "globe")
                        }
                    }
                    .fontWeight(.medium)
                    .foregroundStyle(Color(white: 0.25))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(appearance.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(requesting || isDefault)
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                HStack {
                    Label(L10n.string("Default Browser"), systemImage: "globe")
                    Spacer()
                    if isDefault {
                        Label(L10n.string("Origami is your default browser"), systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Button(actionTitle) { Task { await request() } }
                            .disabled(requesting)
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }
    private func refresh() {
        isDefault = ["http", "https"].allSatisfy { scheme in
            guard let url = URL(string: scheme + "://example.invalid"),
                  let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
            return app.resolvingSymlinksInPath().standardizedFileURL == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        }
        if isDefault {
            error = nil
            useSystemSettings = false
        }
    }
    @MainActor private func request() async {
        guard !requesting else { return }
        requesting = true; error = nil
        defer { requesting = false; refresh() }
        if useSystemSettings {
            await openSystemSettings()
            return
        }
        do {
            for scheme in ["http", "https"] {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
            refresh()
            if !isDefault { await openSystemSettings() }
        } catch {
            // A cancelled consent prompt must not trigger another flow. Sandboxed
            // requests can instead fail with Launch Services permErr (-54).
            var failure = error as NSError
            for _ in 0..<8 {
                if (failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError)
                    || (failure.domain == NSOSStatusErrorDomain && failure.code == -128) { return }
                guard let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
                failure = underlying
            }
            await openSystemSettings()
        }
    }

    @MainActor private func openSystemSettings() async {
        useSystemSettings = true
        error = L10n.string("In System Settings, choose Desktop & Dock → Default web browser → Origami.")
        // Open the system app through the public workspace API. Do not depend on
        // undocumented preference-pane URL schemes or relax the app sandbox.
        guard let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else {
            error = L10n.string("Open System Settings from the Apple menu, then choose Desktop & Dock → Default web browser → Origami.")
            return
        }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: settings, configuration: .init())
        } catch {
            self.error = L10n.string("Open System Settings from the Apple menu, then choose Desktop & Dock → Default web browser → Origami.")
        }
    }
}
