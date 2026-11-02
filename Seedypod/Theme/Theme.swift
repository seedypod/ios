import SwiftUI
import UIKit

/// The warm botanical palette from seedypod/core's web/src/globals.css (`--lp-*`),
/// dark by default with the light theme's values for light appearance. oklch
/// tokens are converted to sRGB.
enum Theme {
    static let app = dynamic(dark: 0x11100C, light: 0xF5F1E8)
    static let card = dynamic(dark: 0x17150F, light: 0xFDFAF3)
    static let active = dynamic(dark: 0x25221A, light: 0xEBE5D8)
    static let line1 = dynamic(dark: 0x2A271F, light: 0xE2DBCB)
    static let line2 = dynamic(dark: 0x3A362D, light: 0xD3CAB6)
    static let text1 = dynamic(dark: 0xEFE8DA, light: 0x1C1A14)
    static let text2 = dynamic(dark: 0xB8AF9C, light: 0x6B6455)
    static let text3 = dynamic(dark: 0x847C6B, light: 0x958C78)
    static let inverse = dynamic(dark: 0x11100C, light: 0xFDFAF3)

    static let water = dynamic(dark: 0x8FB4C4, light: 0x3F7489)
    static let light = dynamic(dark: 0xE5BF6D, light: 0xA97416)
    static let podOK = dynamic(dark: 0x96BE8E, light: 0x547E4B)
    static let podReady = dynamic(dark: 0xE5BF6D, light: 0xA97416)
    static let podAttention = dynamic(dark: 0xE2805E, light: 0xBA5530)
    static let podEmpty = dynamic(dark: 0x5B5548, light: 0xB3AA96)
    static let link = dynamic(dark: 0x9DC494, light: 0x547E4B)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = switch weight {
        case .medium, .semibold, .bold: "IBMPlexMono-Medm"
        case .light: "IBMPlexMono-Light"
        default: "IBMPlexMono"
        }
        return .custom(name, size: size)
    }

    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .light ? UIColor(hex: light) : UIColor(hex: dark) })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// A rounded card on the app's ink, as the web's `Card`.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line1))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}
