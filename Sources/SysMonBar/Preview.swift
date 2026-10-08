import AppKit

/// Renders the panel and the menu bar icon to PNG files.
///
/// `SysMonBar --render-preview <dir>` — handy for eyeballing the layout without
/// hovering, and for checking changes to the drawing code.
enum Preview {
    static func renderAll(to directory: String) {
        let base = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        renderPanel(to: base.appendingPathComponent("panel.png"))
        renderIcons(to: base.appendingPathComponent("icons.png"))
    }

    private static func renderPanel(to url: URL) {
        let controller = DetailViewController()
        let sampler = SystemSampler()

        // Prime the CPU delta so the first reading is not zero.
        _ = sampler.cpuPercent()
        Thread.sleep(forTimeInterval: 0.2)
        var snapshot = sampler.snapshot(topProcesses: SystemSampler.topProcesses(limit: 4))
        snapshot.cpuPercent = sampler.cpuPercent()
        controller.apply(snapshot)

        let content = controller.view
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: DetailViewController.contentWidth, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container

        guard let size = fit(window: window, container: container) else { return }
        write(container, size: size, to: url)
    }

    /// Grid of every icon style × health level: enlarged on top, actual menu bar
    /// size underneath, so the chosen shape can be judged at the size it ships at.
    private static func renderIcons(to url: URL) {
        let scale: CGFloat = 5
        let cell: CGFloat = 19 * scale
        let styles = IconStyleChoice.allCases
        let samples: [(HealthLevel, Double)] = [(.ok, 0.42), (.warn, 0.78), (.critical, 0.97)]

        let width = CGFloat(styles.count) * cell + 24
        let height = CGFloat(samples.count) * cell + 60
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        for (row, sample) in samples.enumerated() {
            for (column, style) in styles.enumerated() {
                let image = IconRenderer.make(style: style, level: sample.0, fraction: sample.1)
                let originX = 12 + CGFloat(column) * cell
                let originY = height - CGFloat(row + 1) * cell

                let large = NSImageView(frame: NSRect(
                    x: originX, y: originY + 14, width: 16 * scale, height: 16 * scale
                ))
                large.image = image
                large.imageScaling = .scaleProportionallyUpOrDown
                canvas.addSubview(large)

                // Actual size, exactly as the menu bar draws it.
                let actual = NSImageView(frame: NSRect(x: originX, y: originY, width: 16, height: 16))
                actual.image = image
                actual.imageScaling = .scaleProportionallyDown
                canvas.addSubview(actual)
            }
        }

        for (column, style) in styles.enumerated() {
            let label = NSTextField(labelWithString:
                style == .ring ? "\(style.label) (default)" : style.label)
            label.font = .systemFont(ofSize: 9, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 12 + CGFloat(column) * cell, y: 6, width: cell - 8, height: 12)
            canvas.addSubview(label)
        }

        write(canvas, size: canvas.frame.size, to: url)
    }

    // MARK: - Helpers

    private static func fit(window: NSWindow, container: NSView) -> NSSize? {
        guard let content = container.subviews.first else { return nil }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.height > 0, size.width > 0 else { return nil }
        window.setContentSize(size)
        container.frame = NSRect(origin: .zero, size: size)
        container.layoutSubtreeIfNeeded()
        return size
    }

    private static func write(_ view: NSView, size: NSSize, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("preview: could not create bitmap for \(url.lastPathComponent)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        print("preview: wrote \(url.path) (\(Int(size.width))x\(Int(size.height)))")
    }
}
