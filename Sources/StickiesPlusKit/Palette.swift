import AppKit

/// Note colors. The first six are Stickies' own, copied from Stickies.app's asset
/// catalog (macOS 26). White and the gray ramp after them are Stickies+ additions.
/// paper = note background, spine = top bar while the note is active,
/// control = the little window buttons and checkboxes, highlight = a pressed button.
enum StickyColor: String, CaseIterable, Codable {
    case yellow, blue, green, pink, purple, gray
    case white, silver, slate, graphite, charcoal

    var title: String { rawValue.capitalized }

    /// Stickies' own six (⌘1–⌘6); the rest sit below a separator in the Color menu.
    var isStickiesOriginal: Bool { StickyColor.allCases.firstIndex(of: self)! < 6 }

    private var values: (paper: NSColor, spine: NSColor, control: NSColor, highlight: NSColor) {
        switch self {
        case .yellow:
            return (rgb(0.996078, 0.956863, 0.611765), rgb(0.996078, 0.917647, 0.239216),
                    rgb(0.858824, 0.772549, 0.011765), rgb(0.737255, 0.662745, 0.007843))
        case .blue:
            return (rgb(0.678431, 0.956863, 1.0), rgb(0.537255, 0.941176, 1.0),
                    rgb(0.141176, 0.815686, 0.913725), rgb(0.007843, 0.737255, 0.843137))
        case .green:
            return (rgb(0.698039, 1.0, 0.631373), rgb(0.513725, 0.996078, 0.513725),
                    rgb(0.317647, 0.733333, 0.317647), rgb(0.282353, 0.635294, 0.282353))
        case .pink:
            return (rgb(1.0, 0.780392, 0.780392), rgb(1.0, 0.698039, 0.698039),
                    rgb(0.972549, 0.498039, 0.498039), rgb(0.886275, 0.458824, 0.458824))
        case .purple:
            return (rgb(0.713725, 0.792157, 1.0), rgb(0.607843, 0.713725, 0.996078),
                    rgb(0.490196, 0.607843, 0.921569), rgb(0.458824, 0.568627, 0.862745))
        case .gray: return (neutral(0.933333), neutral(0.854902), neutral(0.658824), neutral(0.619608))
        case .white: return (neutral(1.0), neutral(0.925), neutral(0.62), neutral(0.50))
        case .silver: return (neutral(0.84), neutral(0.76), neutral(0.55), neutral(0.45))
        case .slate: return (neutral(0.66), neutral(0.58), neutral(0.40), neutral(0.32))
        case .graphite: return (neutral(0.36), neutral(0.29), neutral(0.68), neutral(0.80))
        case .charcoal: return (neutral(0.17), neutral(0.11), neutral(0.58), neutral(0.72))
        }
    }

    var paper: NSColor { values.paper }
    var spine: NSColor { values.spine }
    var control: NSColor { values.control }
    var highlight: NSColor { values.highlight }

    /// Dark notes get light text.
    var isDark: Bool { self == .graphite || self == .charcoal }
    var text: NSColor { isDark ? NSColor(white: 0.94, alpha: 1) : .black }
    /// The tick inside a filled checkbox.
    var checkMark: NSColor { isDark ? paper : .white }
    /// Scroller knob: a darker shade of the note itself.
    var knob: NSColor { control.withAlphaComponent(0.6) }

    /// The back of the note (done pile): the paper pulled a little toward the spine color.
    var backPaper: NSColor { paper.blended(withFraction: 0.35, of: spine) ?? paper }

    static func nearest(to color: NSColor) -> StickyColor {
        guard let c = color.usingColorSpace(.sRGB) else { return .yellow }
        func distance(_ s: StickyColor) -> CGFloat {
            let p = s.paper
            return pow(p.redComponent - c.redComponent, 2)
                + pow(p.greenComponent - c.greenComponent, 2)
                + pow(p.blueComponent - c.blueComponent, 2)
        }
        return allCases.min { distance($0) < distance($1) } ?? .yellow
    }
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

private func neutral(_ white: CGFloat) -> NSColor { rgb(white, white, white) }
