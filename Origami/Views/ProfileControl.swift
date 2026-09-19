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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var profiles: [BrowserProfile] = []
    var body: some View {
        Menu {
            ForEach(profiles) { profile in
                Button {
                    actionSelected()
                    do { try withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { _ = try store.application?.switchProfile(profile.id, in: store) } }
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
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1).truncationMode(.tail)
            } icon: {
                Image(nsImage: (profiles.first { $0.id == store.session.profileID }?.color ?? .mint).menuSwatch)
                    .renderingMode(.original)
            }.labelStyle(.titleAndIcon).frame(height: 24)

        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(maxWidth: 180, alignment: .leading)
        .accessibilityLabel("Profile: " + (profiles.first { $0.id == store.session.profileID }?.name ?? "Personal"))
        .help("Switch or manage profiles. Swipe left or right to cycle through profiles.")
        .background(PeekSwipeMonitor(activity: { _ in }) { x, y, ended in
            if ended { cycle(x: x, y: y) }
        })
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { cycle(x: $0.translation.width, y: $0.translation.height) })
        .task(id: store.application?.profileRevision) {
            profiles = (try? store.services?.profiles.list()) ?? []
        }
    }
    private func cycle(x: CGFloat, y: CGFloat) {
        guard abs(x) >= 30, abs(x) > abs(y) * 1.4,
              let id = ProfileCycle.next(profiles.map(\.id), current: store.session.profileID, forward: x < 0) else { return }
        do {
            try withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                _ = try store.application?.switchProfile(id, in: store, keepPreferencesOpen: true)
            }
        } catch { store.persistenceError = error.localizedDescription }
    }

}

enum ProfileCycle {
    static func next(_ ids: [UUID], current: UUID, forward: Bool) -> UUID? {
        guard ids.count > 1, let index = ids.firstIndex(of: current) else { return nil }
        return ids[(index + (forward ? 1 : ids.count - 1)) % ids.count]
    }
}
