import Foundation

enum SidebarBehavior: String, CaseIterable, Identifiable {
    case visible, compact
    var id: Self { self }
    var title: String { rawValue.capitalized }
    func contentInset(layout: TabLayout, width: CGFloat) -> CGFloat {
        layout == .vertical && self == .visible ? width : 0
    }
}

/// Transient hover state is window-local; only the selected behavior is persisted.
struct SidebarHoverState {
    enum Transition: Hashable {
        case reveal, hide
        var delay: Duration { self == .reveal ? .milliseconds(160) : .milliseconds(350) }
    }
    private(set) var isRevealed = false
    private(set) var pending: Transition?
    private var atEdge = false
    private var inside = false
    private var interacting = false

    mutating func edgeChanged(_ entered: Bool) {
        atEdge = entered
        if entered && !isRevealed { pending = .reveal }
        else if !entered && pending == .reveal { pending = nil }
    }
    mutating func sidebarChanged(_ entered: Bool) {
        inside = entered
        updateHide()
    }
    mutating func interactionChanged(_ active: Bool) {
        interacting = active
        updateHide()
    }
    private mutating func updateHide() {
        if inside || interacting { pending = nil }
        else if isRevealed { pending = .hide }
    }
    mutating func finish(_ transition: Transition) {
        guard pending == transition else { return }
        pending = nil
        switch transition {
        case .reveal: if atEdge { isRevealed = true }
        case .hide: if !inside && !interacting { isRevealed = false }
        }
    }
    mutating func revealForKeyboard() { pending = nil; isRevealed = true }
    mutating func reset() { self = Self() }
}
