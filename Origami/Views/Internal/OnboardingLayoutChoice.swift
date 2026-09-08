import SwiftUI

/// Small browser diagrams show tab placement without introducing another toolbar.
struct OnboardingLayoutChoice: View {
    let layout: TabLayout
    let selected: Bool
    let select: () -> Void
    private var vertical: Bool { layout == .vertical }

    var body: some View {
        Button(action: select) {
            VStack(spacing: 12) {
                diagram
                    .frame(height: 126)
                    .background(.primary.opacity(0.025))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(selected ? Personalization.shared.accent : Color.primary.opacity(0.18), lineWidth: selected ? 2 : 1)
                    }
                Text(vertical ? "Vertical" : "Horizontal")
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(vertical ? "Vertical tabs" : "Horizontal tabs")
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var diagram: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3) { _ in Circle().fill(.secondary.opacity(0.4)).frame(width: 4, height: 4) }
                Spacer()
                if !vertical { Capsule().fill(.secondary.opacity(0.12)).frame(width: 80, height: 8) }
            }.padding(10)
            HStack(spacing: 0) {
                if vertical {
                    VStack(spacing: 5) {
                        Capsule().fill(.secondary.opacity(0.12)).frame(height: 7).padding(.bottom, 4)
                        ForEach(0..<3) { index in tab(selected: index == 0).frame(height: 10) }
                        Spacer(minLength: 4)
                        HStack(spacing: 4) {
                            ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.18)).frame(width: 9, height: 9) }
                        }
                    }.padding(7).frame(width: 54)
                }
                VStack(spacing: 0) {
                    if !vertical {
                        HStack(spacing: 3) { ForEach(0..<3) { index in tab(selected: index == 0) } }
                            .frame(height: 12).padding(.horizontal, 5)
                    }
                    Rectangle().fill(.background.opacity(0.8))
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 6) {
                                Capsule().fill(.secondary.opacity(0.12)).frame(width: 45, height: 5)
                                Capsule().fill(.secondary.opacity(0.08)).frame(height: 4)
                                Capsule().fill(.secondary.opacity(0.08)).frame(height: 4).padding(.trailing, 18)
                            }.padding(12)
                        }
                }
            }
        }.accessibilityHidden(true)
    }
    private func tab(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(selected ? Personalization.shared.accent.opacity(0.3) : Color.primary.opacity(0.08))
    }
}
