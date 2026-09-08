import SwiftUI

struct AISetupPrompt: View {
    let store: BrowserStore
    var body: some View {

            if store.showingAISetup {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea().contentShape(Rectangle())
                    VStack(spacing: 16) {
                        Image(systemName: "text.magnifyingglass").font(.title)
                        Text("Connect a service to Ask the Web").font(.headline)
                        Text("Verify your API key and choose a default model to continue.").foregroundStyle(.secondary)
                        Button("Configure Service") { store.showingAISetup = false; store.openAISettings() }
                        Button { store.showingAISetup = false } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }.buttonStyle(.plain).accessibilityLabel("Close")
                    }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }.onExitCommand { store.showingAISetup = false }
            }

    }
}
