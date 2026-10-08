import AppKit

/// How the menu bar indicator is drawn.
///
/// The original design was a rounded rectangle with a proportional fill, which
/// is exactly the macOS battery glyph - understandable mistake, but it reads as
/// a second battery next to the real one. Every style below avoids that: the
/// fill ratio is carried by a gauge arc or a bar meter instead of a cell.
enum IconStyleChoice: String, CaseIterable {
    case ring
    case bars
    case dot

    var label: String {
        switch self {
        case .ring: return "ring"
        case .bars: return "bars"
        case .dot: return "dot"
        }
    }

    var next: IconStyleChoice {
        let all = IconStyleChoice.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

/// Draws the menu bar indicator.
///
/// Intentionally *not* a template image - the system would force it to
/// monochrome and throw away the colour that carries the whole message. The
/// neutral parts use `labelColor` so they still flip with light and dark menu bars.
enum IconRenderer {
    static let canvas = NSSize(width: 16, height: 16)

    static func make(
        style: IconStyleChoice,
        level: HealthLevel,
        fraction: Double,
        size: NSSize = IconRenderer.canvas
    ) -> NSImage {
        // No need to force an appearance here: the drawing handler runs lazily
        // when the image is painted, which is already inside the menu bar's
        // appearance, so the dynamic colours resolve on their own.
        let image = NSImage(size: size, flipped: false) { rect in
            let clamped = min(1, max(0, fraction))
            switch style {
            case .ring: drawRing(level: level, fraction: clamped, in: rect)
            case .bars: drawBars(level: level, fraction: clamped, in: rect)
            case .dot: drawDot(level: level, in: rect)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Styles

    /// Circular gauge: a faint full ring with a coloured arc sweeping clockwise
    /// from the top. Continuous, so it shows the real percentage.
    private static func drawRing(level: HealthLevel, fraction: Double, in rect: NSRect) {
        let lineWidth: CGFloat = 2.2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - lineWidth / 2 - 1

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        track.stroke()

        guard fraction > 0.01 else { return }
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - 360 * CGFloat(fraction),
            clockwise: true
        )
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        level.color.setStroke()
        arc.stroke()
    }

    /// Bar meter, tallest on the right. Deliberately vertical so it cannot be
    /// confused with the horizontal battery cell.
    private static func drawBars(level: HealthLevel, fraction: Double, in rect: NSRect) {
        let count = 4
        let barWidth: CGFloat = 2.5
        let gap: CGFloat = 1.6
        let minHeight: CGFloat = 4
        let maxHeight: CGFloat = rect.height - 1
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * gap

        let filled = Int((fraction * Double(count)).rounded(.up))
        var x = rect.midX - totalWidth / 2

        for index in 0..<count {
            let height = minHeight + (maxHeight - minHeight) * CGFloat(index) / CGFloat(count - 1)
            let bar = NSBezierPath(
                roundedRect: NSRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height),
                xRadius: 1.2,
                yRadius: 1.2
            )
            if index < filled {
                level.color.setFill()
            } else {
                NSColor.labelColor.withAlphaComponent(0.22).setFill()
            }
            bar.fill()
            x += barWidth + gap
        }
    }

    /// Just a filled dot: the compact option, colour only, no ratio.
    private static func drawDot(level: HealthLevel, in rect: NSRect) {
        let diameter: CGFloat = 10
        let dot = NSRect(
            x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter
        )
        level.color.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}

/// Small filled status dot.
final class DotView: NSView {
    var color: NSColor = .systemGreen {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 9, height: 9) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

/// Horizontal usage bar.
final class BarView: NSView {
    var fraction: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    var color: NSColor = .systemGreen {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let width = bounds.width * min(1, max(0, fraction))
        guard width > 1 else { return }
        color.setFill()
        let fill = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
