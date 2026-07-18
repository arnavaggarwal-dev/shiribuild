import SwiftUI
import Network
import Combine
import UIKit
import AVFoundation

// MARK: - Palette

/// Exact hex values from the Tkinter build's cosmic nebula theme, so this
/// still feels like the same game.
enum Palette {
    static let bg        = Color(hex: 0x07050F)
    static let card       = Color(hex: 0x0D0818)
    static let card2      = Color(hex: 0x130E24)
    static let border      = Color(hex: 0x2D1B54)
    static let borderActive = Color(hex: 0x6D28D9)
    static let accent      = Color(hex: 0xA855F7)
    static let glow        = Color(hex: 0xC084FC)
    static let red         = Color(hex: 0xF472B6)
    static let redBright   = Color(hex: 0xEC4899)
    static let green       = Color(hex: 0x34D399)
    static let orange      = Color(hex: 0xFB923C)
    static let dim         = Color(hex: 0x5B4D7A)
    static let text        = Color(hex: 0xEDE9FE)
    static let deepOut     = Color(hex: 0x3D0000)
    static let forbiddenBorder = Color(hex: 0x7C2D2D)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Type scale

/// Small type namespace so the whole app draws from one font family
/// (SF Rounded) instead of ad-hoc sizes scattered through the views.
enum GameFont {
    static func display(_ size: CGFloat = 34) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func title(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func headline(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func body(_ size: CGFloat = 14) -> Font { .system(size: size, weight: .regular, design: .rounded) }
    static func caption(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .medium, design: .rounded) }
    static func mono(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .bold, design: .rounded).monospacedDigit() }
}

extension Color {
    /// Round-trips through UIColor to get sRGB components for wire transfer,
    /// as a "#RRGGBB" string — the exact format the Python build sends.
    func toHexString() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// Parses "#RRGGBB" or "RRGGBB" (any case). Returns nil for anything else.
    init?(hexString: String?) {
        guard let hexString else { return nil }
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(hex: v)
    }
}

