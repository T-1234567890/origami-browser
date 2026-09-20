import Foundation

enum PageZoom {
    static let levels: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]
    static func step(from value: Double, increasing: Bool) -> Double {
        if increasing { return levels.first { $0 > value + 0.001 } ?? levels.last! }
        return levels.last { $0 < value - 0.001 } ?? levels.first!
    }
    static func symbol(for value: Double) -> String {
        value > 1.001 ? "plus.magnifyingglass" : value < 0.999 ? "minus.magnifyingglass" : "magnifyingglass"
    }
}
