import UniformTypeIdentifiers
import SwiftUI
import AppKit
import Observation

@MainActor @Observable final class Personalization {
    static let shared = Personalization()
    private let defaults: UserDefaults
    var mode: String { didSet { defaults.set(mode, forKey: "appearance.mode") } }
    var hex: String { didSet { defaults.set(hex, forKey: "appearance.accent") } }
    var gradientEnabled: Bool { didSet { defaults.set(gradientEnabled, forKey: "appearance.gradient") } }
    var gradientHex: String { didSet { defaults.set(gradientHex, forKey: "appearance.gradientEnd") } }
    var frameFill: Bool { didSet { defaults.set(frameFill, forKey: "appearance.frameFill") } }
    var density: String { didSet { defaults.set(density, forKey: "appearance.density") } }
    var frame: String { didSet { defaults.set(frame, forKey: "appearance.frame") } }
    var glass: String { didSet { defaults.set(glass, forKey: "appearance.glass") } }
    var defaultAsk: Bool { didSet { defaults.set(defaultAsk, forKey: "newTab.defaultAsk") } }
    var favorites: Bool { didSet { defaults.set(favorites, forKey: "appearance.favorites") } }
    var titleImage: Data? { didSet { defaults.set(titleImage, forKey: "appearance.titleImage") } }
    var wallpaper: Data? { didSet { defaults.set(wallpaper, forKey: "appearance.wallpaper"); wallpaperIsDark = Self.isDark(wallpaper) } }
    var wallpaperIsDark = false
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultAsk = defaults.bool(forKey: "newTab.defaultAsk")
        mode = defaults.string(forKey: "appearance.mode") ?? "System"
        hex = defaults.string(forKey: "appearance.accent") ?? "55D4B3"
        gradientEnabled = defaults.bool(forKey: "appearance.gradient")
        gradientHex = defaults.string(forKey: "appearance.gradientEnd") ?? "84A9F5"
        let combinedFill = defaults.bool(forKey: "appearance.frameFill") || defaults.bool(forKey: "appearance.sidebarTint")
        frameFill = combinedFill
        // Fold the former sidebar-only preference into the single background control.
        defaults.set(combinedFill, forKey: "appearance.frameFill")
        defaults.removeObject(forKey: "appearance.sidebarTint")
        density = defaults.string(forKey: "appearance.density") ?? "Standard"
        frame = defaults.string(forKey: "appearance.frame") ?? (defaults.object(forKey: "browser.contentFrame") as? Bool == false ? "Off" : "Subtle")
        glass = defaults.string(forKey: "appearance.glass") ?? "Standard"
        favorites = defaults.object(forKey: "appearance.favorites") as? Bool ?? true
        titleImage = defaults.data(forKey: "appearance.titleImage")
        wallpaper = defaults.data(forKey: "appearance.wallpaper")
        wallpaperIsDark = Self.isDark(wallpaper)
    }
    private static func isDark(_ data: Data?) -> Bool {
        guard let data, let image = NSImage(data: data), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let value: Double = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 255 }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            let bytes = buffer.bindMemory(to: UInt8.self)
            var total = 0.0
            for y in 8..<24 { for x in 6..<26 { let i = (y * 32 + x) * 4; total += 0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i+1]) + 0.0722 * Double(bytes[i+2]) } }
            return total / 320
        }
        return value < 145
    }
    var accent: Color {
        let value = UInt32(hex, radix: 16) ?? 0x55D4B3
        return Color(red: Double((value >> 16) & 255)/255, green: Double((value >> 8) & 255)/255, blue: Double(value & 255)/255)
    }
    var secondaryAccent: Color {
        let n = UInt32(gradientHex, radix: 16) ?? 0x84A9F5
        return Color(red: Double((n >> 16) & 255)/255, green: Double((n >> 8) & 255)/255, blue: Double(n & 255)/255)
    }
    var accentFill: LinearGradient { LinearGradient(colors: gradientEnabled ? [accent, secondaryAccent] : [accent, accent], startPoint: .topLeading, endPoint: .bottomTrailing) }
    func setSecondaryAccent(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        gradientHex = String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
    var scheme: ColorScheme? { mode == "System" ? nil : mode == "Dark" ? .dark : .light }
    var tabHeight: CGFloat { density == "Compact" ? 24 : density == "Comfortable" ? 32 : 26 }
    func setAccent(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        hex = String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}

struct AppearanceSettings: View {
    let layout: TabLayout
    @Bindable private var settings = Personalization.shared
    @State private var error: String?
    var body: some View {
        Section("Appearance") {
            Picker("Appearance", selection: $settings.mode) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }
            LabeledContent("Main accent") {
                HStack {
                    Button { settings.hex = "55D4B3"; settings.gradientEnabled = false } label: {
                        HStack(spacing: 5) { Circle().fill(color("55D4B3")).frame(width: 18, height: 18); Text("Origami") }
                    }.buttonStyle(.plain).help("Restore the default Origami accent")
                    Divider().frame(height: 20)
                    ForEach(["3478F6", "9B59B6", "D65F78", "BC741B", "687785"], id: \.self) { hex in
                        Button { settings.hex = hex } label: {
                            Circle().fill(color(hex)).frame(width: 18, height: 18)
                                .overlay { if settings.hex == hex { Image(systemName: "checkmark").font(.system(size: 9).bold()).foregroundStyle(.white) } }
                        }.buttonStyle(.plain).accessibilityLabel(hex == "55D4B3" ? "Origami default" : "Accent " + hex)
                }
                ColorPicker("Custom", selection: Binding(get: { settings.accent }, set: { settings.setAccent($0) }), supportsOpacity: false).labelsHidden()
                }
            }
            Toggle("Gradient accent", isOn: $settings.gradientEnabled)
            if settings.gradientEnabled {
                ColorPicker("Second color", selection: Binding(get: { settings.secondaryAccent }, set: { settings.setSecondaryAccent($0) }), supportsOpacity: false)
                settings.accentFill.frame(height: 12).clipShape(Capsule()).accessibilityLabel("Accent gradient preview")
                Text("The main accent is used for buttons and selection. The gradient is used for background fills.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Fill frame and sidebar background with accent (Vertical tabs only)", isOn: $settings.frameFill)
                .disabled(layout == .horizontal)
            Picker("Tab density", selection: $settings.density) { ForEach(["Compact", "Standard", "Comfortable"], id: \.self) { Text($0) } }
            Picker("Glass", selection: $settings.glass) { ForEach(["Reduced", "Standard"], id: \.self) { Text($0) } }
        }
        Section("New Tab") {
            Toggle("Show pinned and favorite sites", isOn: $settings.favorites)
            LabeledContent("New Tab title image") {
                HStack {
                    Button("Choose PNG or SVG…", action: chooseTitleImage)
                    if settings.titleImage != nil { Button("Reset") { settings.titleImage = nil } }
                }
            }
            LabeledContent("Background") {
                HStack {
                    Button("Choose Image…", action: chooseWallpaper)
                    if settings.wallpaper != nil { Button("Remove") { settings.wallpaper = nil } }
                }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
        }
    }
    private func color(_ hex: String) -> Color {
        let n = UInt32(hex, radix: 16) ?? 0
        return Color(red: Double(n >> 16)/255, green: Double((n >> 8)&255)/255, blue: Double(n&255)/255)
    }
    private func chooseTitleImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .svg]; panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 4_000_000 else { error = "Choose an image smaller than 4 MB."; return }
                let data = try Data(contentsOf: url)
                guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { error = "This PNG or SVG could not be opened."; return }
                settings.titleImage = data; error = nil
            } catch { self.error = "This image could not be read." }
        }
    }
    private func chooseWallpaper() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { error = "This image could not be opened."; return }
            // Store a bounded thumbnail, never an arbitrary original image in preferences.
            let scale = min(1, 1600 / max(image.size.width, image.size.height))
            let resized = NSImage(size: NSSize(width: image.size.width*scale, height: image.size.height*scale))
            resized.lockFocus(); image.draw(in: NSRect(origin: .zero, size: resized.size)); resized.unlockFocus()
            guard let tiff = resized.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return }
            settings.wallpaper = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75]); error = nil
        }
    }
}

// Set the containing AppKit window directly: resetting a SwiftUI preference to nil
// can leave the previous explicit appearance cached until the window reactivates.
struct WindowAppearanceBridge: NSViewRepresentable {
    let mode: String
    func makeNSView(context: Context) -> AppearanceView { AppearanceView() }
    func updateNSView(_ view: AppearanceView, context: Context) { view.mode = mode; view.apply() }
    final class AppearanceView: NSView {
        var mode = "System"
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            let name: NSAppearance.Name? = mode == "Dark" ? .darkAqua : mode == "Light" ? .aqua : nil
            guard window?.appearance?.name != name else { return }
            window?.appearance = name.flatMap(NSAppearance.init(named:))
            window?.contentView?.needsDisplay = true
        }
    }
}
