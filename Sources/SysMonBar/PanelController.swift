import AppKit

/// Borderless panel that can take mouse events *without* activating the app.
///
/// This matters for a hover widget: activating on hover would steal focus while
/// you are typing in another app. `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded`
/// lets the checkboxes and buttons inside still work.
final class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelController {
    private let panel: HoverPanel
    private let detail: DetailViewController
    private let container = NSVisualEffectView()

    init(detail: DetailViewController) {
        self.detail = detail

        panel = HoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: DetailViewController.contentWidth, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        let content = detail.view
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container
    }

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    /// `anchor` is the status item's rect in screen coordinates. The screen is
    /// resolved from the anchor rather than from the status bar window, because
    /// that window's frame is unreliable on multi-display setups.
    func show(below anchor: NSRect) {
        let size = fittingSize()

        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 8)
        // NSScreen.main is nil for an accessory app that has no key window, so it
        // must not be the only fallback - an unclamped panel lands off-screen.
        if let screen = screen(containing: anchor)
            ?? screen(containing: NSRect(origin: NSEvent.mouseLocation, size: .zero))
            ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let maxX = max(visible.minX + 6, visible.maxX - size.width - 6)
            let maxY = max(visible.minY + 6, visible.maxY - size.height - 6)
            origin.x = min(max(visible.minX + 6, origin.x), maxX)
            origin.y = min(max(visible.minY + 6, origin.y), maxY)
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) }
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Keeps the top edge anchored while the content grows or shrinks.
    func resizeIfNeeded() {
        guard panel.isVisible else { return }
        let size = fittingSize()
        guard abs(size.height - panel.frame.height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y -= size.height - frame.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    private func fittingSize() -> NSSize {
        container.layoutSubtreeIfNeeded()
        var size = container.fittingSize
        if size.width < 200 { size.width = DetailViewController.contentWidth }
        if size.height < 80 { size.height = 220 }
        return size
    }
}
