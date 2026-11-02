import AppKit

/// PLAN §6.2's palette, in sRGB. The page is always black on white (PLAN §4.7), so these
/// are fixed colors rather than dynamic system colors.
extension PaletteColor {
    public var nsColor: NSColor {
        NSColor(sRGB: hex)
    }

    private var hex: UInt32 {
        switch self {
        case .black: 0x000000
        case .purple: 0x7B2FBE
        case .red: 0xC62828
        case .blue: 0x1E5BC6
        case .green: 0x2E7D32
        case .gray: 0x757575
        case .pink: 0xD81B7A
        }
    }
}

extension HighlightColor {
    public var nsColor: NSColor {
        NSColor(sRGB: hex)
    }

    private var hex: UInt32 {
        switch self {
        case .purple: 0xE9DDF7
        case .red: 0xF8D7D7
        case .blue: 0xD7E4F8
        case .green: 0xD9EDDA
        case .gray: 0xE6E6E6
        case .pink: 0xF8D5E7
        }
    }
}

extension NSColor {
    fileprivate convenience init(sRGB hex: UInt32) {
        func channel(_ shift: UInt32) -> CGFloat {
            CGFloat((hex >> shift) & 0xFF) / 255
        }
        self.init(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }
}
