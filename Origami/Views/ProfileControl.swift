import SwiftUI
import AppKit

extension ProfileColor {
    @MainActor var menuSwatch: NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(tint).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    var tint: Color {
        switch self {
        case .mint: Color(red: 85.0/255, green: 212.0/255, blue: 179.0/255)
        case .purple: .purple
        case .pink: .pink
        case .orange: .orange
        case .green: .green
        case .blue: .blue
        }
    }
}

struct ProfileControl: View {
    let store: BrowserStore
    var actionSelected: () -> Void = {}
    @State private var profiles: [BrowserProfile] = []
    var body: some View {
        Menu {
            ForEach(profiles) { profile in
                Button {
                    actionSelected()
                    do { _ = try store.application?.switchProfile(profile.id, in: store) }
                    catch { store.persistenceError = error.localizedDescription }
                } label: {
                    Label {
                        Text(profile.name + (profile.id == store.session.profileID ? " ✓" : ""))
                    } icon: {
                        Image(nsImage: profile.color.menuSwatch).renderingMode(.original)
                    }
                }
            }
            Divider()
            Button("New Profile…") { actionSelected(); store.openInternal(.profiles) }
            Button("Manage Profiles…") { actionSelected(); store.openInternal(.profiles) }
        } label: {
            Label {
                Text(profiles.first { $0.id == store.session.profileID }?.name ?? "Personal")
                    .lineLimit(1).truncationMode(.tail)
            } icon: {
                Image(nsImage: (profiles.first { $0.id == store.session.profileID }?.color ?? .mint).menuSwatch)
                    .renderingMode(.original)
            }.labelStyle(.titleAndIcon).frame(height: 24)

        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(maxWidth: 180, alignment: .leading)
        .accessibilityLabel("Profile: " + (profiles.first { $0.id == store.session.profileID }?.name ?? "Personal"))
        .help("Switch or manage profiles")
        .task(id: store.application?.profileRevision) {
            profiles = (try? store.services?.profiles.list()) ?? []
        }
    }
}
