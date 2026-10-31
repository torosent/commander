import AppKit
import SwiftUI

/// Tokens from DESIGN.md. Each colour resolves for the current appearance.
enum Palette {
    // Ink, lines and rims go further apart under Increase Contrast. Everything else already clears 4.5:1.
    static let caseColor = adaptive(dark: 0x262523, light: 0xDDD9CF)
    static let deck = adaptive(dark: 0x1E1D1C, light: 0xF3F1EB)
    static let rim = adaptive(dark: 0x000000, light: 0xB9B4A7, darkContrast: 0x8A877F, lightContrast: 0x5E5A51)
    static let line = adaptive(dark: 0x3A3936, light: 0xCFCABD, darkContrast: 0x6E6C65, lightContrast: 0x8A877F)
    /// A row's background, which stays put under Increase Contrast so the text on it gains rather than loses.
    static let band = adaptive(dark: 0x3A3936, light: 0xCFCABD)
    static let ink = adaptive(dark: 0xECE8DE, light: 0x1E1D1B, darkContrast: 0xFFFFFF, lightContrast: 0x000000)
    static let dim = adaptive(dark: 0xA7A296, light: 0x5E5A51, darkContrast: 0xD6D2C8, lightContrast: 0x3A3833)
    static let cursor = adaptive(dark: 0xD9D5CA, light: 0x2B2A27)
    static let cursorInk = adaptive(dark: 0x1A1917, light: 0xF3F1EB)
    static let key = adaptive(dark: 0x3A3834, light: 0xC9C5BA)
    static let keyHigh = adaptive(dark: 0x55524C, light: 0xECE9E1)
    static let keyInk = adaptive(dark: 0xECE8DE, light: 0x1E1D1B)
    static let goText = adaptive(dark: 0x86DC94, light: 0x1B6A28)
    static let moveText = adaptive(dark: 0xF7CF58, light: 0x6E5000)
    static let removeText = adaptive(dark: 0xF6A094, light: 0xA02719)
    static let goWash = color(0x3FA34D).withAlphaComponent(0.2)
    static let moveWash = color(0xF2B705).withAlphaComponent(0.2)
    static let removeWash = color(0xD23C2A).withAlphaComponent(0.2)

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
            green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func adaptive(dark: UInt32, light: UInt32, darkContrast: UInt32? = nil, lightContrast: UInt32? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            // Asked directly, because a theme forced in Settings is a plain appearance that wouldn't say.
            let isHigh = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            return color((isHigh ? (isDark ? darkContrast : lightContrast) : nil) ?? (isDark ? dark : light))
        }
    }
}

enum Theme {
    static let caseColor = Color(nsColor: Palette.caseColor)
    static let deck = Color(nsColor: Palette.deck)
    static let rim = Color(nsColor: Palette.rim)
    static let line = Color(nsColor: Palette.line)
    static let band = Color(nsColor: Palette.band)
    static let ink = Color(nsColor: Palette.ink)
    static let dim = Color(nsColor: Palette.dim)
    static let cursor = Color(nsColor: Palette.cursor)
    static let key = Color(nsColor: Palette.key)
    static let keyHigh = Color(nsColor: Palette.keyHigh)
    static let keyInk = Color(nsColor: Palette.keyInk)
    static let removeText = Color(nsColor: Palette.removeText)
    static let goFill = rgb(0x3FA34D)
    static let moveFill = rgb(0xB88A00)
    static let removeFill = rgb(0xD23C2A)

    static let body = Font.system(size: 12).monospacedDigit()
    static let label = Font.system(size: 11).monospacedDigit()

    static func rgb(_ hex: UInt32) -> Color {
        Color(nsColor: Palette.color(hex))
    }
}
