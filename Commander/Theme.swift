import AppKit
import SwiftUI

/// Tokens from DESIGN.md. Each colour resolves for the current appearance.
enum Palette {
    static let caseColor = adaptive(dark: 0x262523, light: 0xDDD9CF)
    static let deck = adaptive(dark: 0x1E1D1C, light: 0xF3F1EB)
    static let rim = adaptive(dark: 0x000000, light: 0xB9B4A7)
    static let line = adaptive(dark: 0x3A3936, light: 0xCFCABD)
    static let ink = adaptive(dark: 0xECE8DE, light: 0x1E1D1B)
    static let dim = adaptive(dark: 0xA7A296, light: 0x5E5A51)
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
    static let removeWash = color(0xD8412F).withAlphaComponent(0.2)

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
            green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func adaptive(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            color(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }
}

enum Theme {
    static let caseColor = Color(nsColor: Palette.caseColor)
    static let deck = Color(nsColor: Palette.deck)
    static let rim = Color(nsColor: Palette.rim)
    static let line = Color(nsColor: Palette.line)
    static let ink = Color(nsColor: Palette.ink)
    static let dim = Color(nsColor: Palette.dim)
    static let cursor = Color(nsColor: Palette.cursor)
    static let key = Color(nsColor: Palette.key)
    static let keyHigh = Color(nsColor: Palette.keyHigh)
    static let keyInk = Color(nsColor: Palette.keyInk)
    static let removeText = Color(nsColor: Palette.removeText)
    static let goFill = rgb(0x3FA34D)
    static let moveFill = rgb(0xB88A00)
    static let removeFill = rgb(0xD8412F)

    static let body = Font.system(size: 12).monospacedDigit()
    static let label = Font.system(size: 11).monospacedDigit()

    static func rgb(_ hex: UInt32) -> Color {
        Color(nsColor: Palette.color(hex))
    }
}
