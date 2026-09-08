import SwiftUI
import Combine
import Sparkle

@MainActor final class UpdateService: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateService()
    @Published private(set) var canCheck = false
    @Published private(set) var available = false
    @Published var channel: UpdateChannel {
        didSet { preferences.channel = channel; controller?.updater.resetUpdateCycle() }
    }
    @Published var automaticallyChecks = false {
        didSet { if controller?.updater.automaticallyChecksForUpdates != automaticallyChecks { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks } }
    }
    let identity = ReleaseIdentity.from(info: Bundle.main.infoDictionary ?? [:])
    private let preferences: UpdatePreferences
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    override init() {
        preferences = UpdatePreferences(defaults: .standard)
        channel = preferences.channel
        super.init()
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:]) != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        // Keep Sparkle's native preference as the single source of truth for automatic checking.
        observations = [controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor [weak self] in self?.canCheck = updater.canCheckForUpdates }
        }, controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor [weak self] in self?.automaticallyChecks = updater.automaticallyChecksForUpdates }
        }]
        do { try controller.updater.start(); available = true }
        catch { self.controller = nil; observations = []; canCheck = false }
    }
    func feedURLString(for updater: SPUUpdater) -> String? { UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:])?.feed.absoluteString }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { channel.sparkleChannels }
    func check() { guard available, canCheck else { return }; controller?.checkForUpdates(nil) }
}

struct UpdatesSettings: View {
    @ObservedObject private var updates = UpdateService.shared
    var body: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: $updates.automaticallyChecks).disabled(!updates.available)
            Picker("Update Channel", selection: $updates.channel) {
                ForEach(UpdateChannel.allCases) { Text($0.title).tag($0) }
            }
            Button("Check for Updates…") { updates.check() }.disabled(!updates.available || !updates.canCheck)
            if !updates.available { Text("Updates are not configured for this build.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct AboutSettings: View {
    private let identity = ReleaseIdentity.from(info: Bundle.main.infoDictionary ?? [:])
    private var version: String {
        if let identity { return String(identity.displayVersion.dropFirst("Origami ".count)) }
        let marketingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        return "\(marketingVersion) — Development"
    }
    var body: some View {
        Section("About") {
            HStack(spacing: 16) {
                if let icon = NSApplication.shared.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Origami").font(.headline)
                    Text(version).foregroundStyle(.secondary)
                    Text("Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
        }
    }
}

struct UpdateCommands: Commands {
    @ObservedObject private var updates = UpdateService.shared
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.check() }.disabled(!updates.available || !updates.canCheck)
        }
    }
}
