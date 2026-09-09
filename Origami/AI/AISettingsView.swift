import SwiftUI

struct AISettingsView: View {
    let store: BrowserStore
    @Bindable private var settings = AISettings.shared
    @State private var credential = ""
    @State private var saved = false
    @State private var status = ""
    @State private var models: [String] = []
    @State private var busy = false
    @State private var showingKey = false
    @State private var confirmingUpdate = false
    @State private var confirmingDisconnect = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Service")
                    Picker("Service", selection: $settings.provider) { ForEach(AIProviderID.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 180, alignment: .leading)
                    Spacer()
                    Label(settings.setupComplete && saved ? "Ready" : saved ? "Setup incomplete" : "Not connected", systemImage: settings.setupComplete && saved ? "checkmark.circle" : "circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(saved ? "Update API key" : "API key").font(.callout)
                    HStack(spacing: 8) {
                        APIKeyField(value: $credential, revealed: showingKey).id(showingKey).frame(height: 22)
                        Button { showingKey.toggle() } label: {
                            Image(systemName: showingKey ? "eye.slash" : "eye").frame(width: 24, height: 24)
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(showingKey ? "Hide API key" : "Show API key")
                            .accessibilityLabel(showingKey ? "Hide API key" : "Show API key")
                    }.padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button(saved ? "Update & Verify" : "Connect Service") {
                            if saved { showingKey = false; confirmingUpdate = true }
                            else { saveCredential() }
                        }.disabled(credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                        if saved {
                            Button("Verify Connection") { loadModels() }.disabled(busy)
                            Spacer()
                            Button("Disconnect", role: .destructive) {
                                showingKey = false; confirmingDisconnect = true
                            }.disabled(busy)
                        }
                        if busy { ProgressView().controlSize(.small) }
                    }.buttonStyle(.plain).foregroundStyle(Personalization.shared.accent)
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                if saved && settings.verified {
                    Divider()
                    HStack {
                        Text("Choose your models").font(.headline)
                        Spacer()
                    }
                    if settings.provider == .openRouter {
                        Text("Free model pricing covers tokens. Web search is billed separately.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("Web search"); Spacer()
                            Menu {
                                Picker("Web search", selection: $settings.searchEngine) {
                                    Text("Automatic").tag("auto")
                                    Text("Native").tag("native")
                                    Text("Exa").tag("exa")
                                }
                            } label: {
                                AISettingsSelectionLabel(title: settings.searchEngine == "native" ? "Native" : settings.searchEngine == "exa" ? "Exa" : "Automatic")
                            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                    }
                    modelRow("Default model", "primary")
                    HStack { Text("Fallback model"); Spacer(); ModelSearchControl(selection: Binding(get: { settings.model("fallback") }, set: { settings.setModel($0, role: "fallback") }), placeholder: "Choose fallback model…", allowsDefault: true, clearLabel: "No fallback", settingsStyle: true)
                        .frame(width: 220, alignment: .leading) }
                    Toggle("Automatically use fallback when the default model is unavailable", isOn: $settings.automaticFallback)
                    Text("Fallback uses only your configured model when its required capabilities are confirmed. Model and search charges may apply.").font(.caption).foregroundStyle(.secondary)
                    modelRow("Lightweight model", "lightweight")
                    modelRow("Research model", "research")
                    Text("Choose a default model with web search support. Other models are optional.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                if AISettings.aiPeekAvailable {
                VStack(alignment: .leading, spacing: 10) {
                    Text("AI Peek").font(.headline)
                    Toggle("Enable AI Peek (experimental)", isOn: $settings.aiPeekEnabled)
                    Toggle("Automatically summarize previews", isOn: $settings.aiPeekSummary).disabled(!settings.aiPeekEnabled)
                    Toggle("Automatically evaluate preview credibility", isOn: $settings.aiPeekCredibility).disabled(!settings.aiPeekEnabled)
                    Text("When enabled, every Peek sends page excerpts to your configured lightweight model. Credibility also uses web search. Provider charges may apply, including in private windows. These preferences apply to future previews until switched off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                }
                Text("Keys are stored in Keychain. Requests go to your provider and may incur charges.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Private requests aren’t saved locally. Your provider’s retention policy still applies.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 680, alignment: .leading)
        }
        .alert("Replace API key for \(settings.provider.rawValue)?", isPresented: $confirmingUpdate) {
            Button("Cancel", role: .cancel) { }
            Button("Update Key") { saveCredential() }
        } message: {
            Text("This replaces the saved key in Keychain and verifies the new key.")
        }
        .alert("Disconnect \(settings.provider.rawValue)?", isPresented: $confirmingDisconnect) {
            Button("Cancel", role: .cancel) { }
            Button("Disconnect", role: .destructive) {
                do {
                    try AICredentialStore().forget(settings.provider)
                    saved = false; credential = ""; settings.setVerified(false); models = []; status = ""
                    store.application?.stores.values.forEach { $0.services?.ai.stop() }
                } catch { status = error.localizedDescription }
            }
        } message: {
            Text("This removes the API key from Keychain and stops active AI requests. To use this service again, reconnect it.")
        }
        .onAppear { saved = AICredentialStore().contains(settings.provider); models = settings.availableModels }
        .onChange(of: settings.provider) { confirmingUpdate = false; confirmingDisconnect = false; showingKey = false; credential = ""; models = settings.availableModels; status = ""; saved = AICredentialStore().contains(settings.provider) }
        .onDisappear { credential = ""; showingKey = false; confirmingUpdate = false; confirmingDisconnect = false }
    }
    private func saveCredential() {
        do {
            try AICredentialStore().save(credential, provider: settings.provider)
            credential = ""; showingKey = false; saved = true; settings.setVerified(false); loadModels()
        } catch { status = error.localizedDescription }
    }
    private func modelRow(_ title: String, _ role: String) -> some View {
        HStack {
            Text(title); Spacer()
            ModelSearchControl(selection: Binding(get: { settings.model(role) }, set: { settings.setModel($0, role: role) }), placeholder: role == "primary" ? "Search models…" : "Use default", allowsDefault: role != "primary", settingsStyle: true)
                .frame(width: 220, alignment: .leading)
        }
    }
    private func loadModels() {
        let provider = settings.provider; busy = true
        Task {
            let network = AINetwork(); defer { network.stop(); busy = false }
            do {
                let key = try AICredentialStore().read(provider)
                let url: URL
                switch provider {
                case .gemini: url = provider.endpoint
                case .openRouter: url = URL(string: "https://openrouter.ai/api/v1/models")!
                case .openAI: url = URL(string: "https://api.openai.com/v1/models")!
                case .xAI: url = URL(string: "https://api.x.ai/v1/models")!
                }
                var request = URLRequest(url: url)
                request.setValue(provider == .gemini ? key : "Bearer " + key, forHTTPHeaderField: provider == .gemini ? "x-goog-api-key" : "Authorization")
                let root = try JSONSerialization.jsonObject(with: await network.data(for: request)) as? [String: Any] ?? [:]
                guard settings.provider == provider else { return }
                let rows = (root["data"] ?? root["models"]) as? [[String: Any]] ?? []
                settings.storeCatalog(rows)
                models = rows.compactMap { ($0["id"] as? String ?? $0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }.sorted()
                settings.setCatalog(models); settings.setVerified(true); status = settings.model("primary").isEmpty ? "Connected. Choose a default model below to complete setup." : "Connection verified."
            } catch { guard settings.provider == provider else { return }; settings.setVerified(false); status = (error as? AIError)?.localizedDescription ?? "Could not check the provider connection." }
        }
    }
}

/// A full-width native secure editor without SwiftUI's trailing form-value layout.
private struct APIKeyField: NSViewRepresentable {
    @Binding var value: String
    let revealed: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = revealed ? NSTextField() : NSSecureTextField()
        field.placeholderString = "Paste your API key"
        field.alignment = .left; field.isBezeled = false; field.isBordered = false
        field.drawsBackground = false; field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular); field.delegate = context.coordinator
        field.setAccessibilityLabel("API key")
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != value { field.stringValue = value }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: APIKeyField
        init(_ parent: APIKeyField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) { if let field = notification.object as? NSTextField { parent.value = field.stringValue } }
    }
}
