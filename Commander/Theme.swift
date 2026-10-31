import AppKit
import SwiftUI

/// Tokens from DESIGN.md. Each colour resolves for the current appearance.
enum Theme {
    static let caseColor = adaptive(dark: 0x262523, light: 0xDDD9CF)
    static let deck = adaptive(dark: 0x1E1D1C, light: 0xF3F1EB)
    static let rim = adaptive(dark: 0x000000, light: 0xB9B4A7)
    static let line = adaptive(dark: 0x3A3936, light: 0xCFCABD)
    static let ink = adaptive(dark: 0xECE8DE, light: 0x1E1D1B)
    static let dim = adaptive(dark: 0xA7A296, light: 0x5E5A51)
    static let cursor = adaptive(dark: 0xD9D5CA, light: 0x2B2A27)
    static let key = adaptive(dark: 0x3A3834, light: 0xC9C5BA)
    static let keyHigh = adaptive(dark: 0x55524C, light: 0xECE9E1)
    static let keyInk = adaptive(dark: 0xECE8DE, light: 0x1E1D1B)

    static let body = Font.system(size: 12).monospacedDigit()
    static let label = Font.system(size: 11).monospacedDigit()

    static func rgb(_ hex: UInt32) -> Color {
        Color(nsColor: nsColor(hex))
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
            green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? nsColor(dark) : nsColor(light)
        })
    }
}
