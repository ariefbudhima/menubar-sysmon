import AppKit

/// The hover panel: everything you cannot fit in the menu bar.
///
/// Built once with plain AppKit views, then only the text values are updated on
/// each tick, so a refresh costs a handful of string assignments instead of a
/// view hierarchy rebuild.
final class DetailViewController: NSViewController {
    private enum Key {
        static let used = "used"
        static let app = "app"
        static let wired = "wired"
        static let compressed = "compressed"
        static let cached = "cached"
        static let free = "free"
        static let swap = "swap"
        static let cpu = "cpu"
        static let load = "load"
        static let uptime = "uptime"
        static let thermal = "thermal"
        static let disk = "disk"
        static let cpuTemp = "cpuTemp"
        static let gpuTemp = "gpuTemp"
    }

    static let contentWidth: CGFloat = 320

    var onQuit: (() -> Void)?
    var onPrefsChanged: (() -> Void)?

    private let prefs = Prefs.shared
    private var values: [String: NSTextField] = [:]

    private var rootStack: NSStackView!
    private var dot: DotView!
    private var statusLabel: NSTextField!
    private var percentLabel: NSTextField!
    private var bar: BarView!
    private var captionLabel: NSTextField!

    private var topSection: NSStackView?
    private var topRows: [NSView] = []
    private var topNames: [NSTextField] = []
    private var topValues: [NSTextField] = []

    private var refreshButton: NSButton!
    private var styleButton: NSButton!
    private var iconButton: NSButton!
    private var loginCheckbox: NSButton!
    private var topCheckbox: NSButton!

    // MARK: - Layout

    override func loadView() {
        let root = NSView()
        root.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        rootStack = stack

        buildHeader()
        buildMemorySection()
        buildSwapSection()
        buildTemperatureSection()
        buildSystemSection()
        buildTopProcessSection()
        buildFooter()
    }

    private func buildHeader() {
        dot = DotView()
        statusLabel = makeLabel("Memory pressure: NORMAL", size: 12, weight: .semibold, color: .labelColor)
        percentLabel = makeLabel("0%", size: 13, weight: .semibold, color: .labelColor)
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        percentLabel.alignment = .right

        let header = NSView()
        let headerViews: [NSView] = [dot, statusLabel, percentLabel]
        for subview in headerViews {
            subview.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            statusLabel.topAnchor.constraint(equalTo: header.topAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            percentLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            percentLabel.firstBaselineAnchor.constraint(equalTo: statusLabel.firstBaselineAnchor),
            percentLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 8)
        ])
        rootStack.addArrangedSubview(header)

        bar = BarView()
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        rootStack.addArrangedSubview(bar)

        // Says *why* the colour is what it is: the kernel's own free-memory level
        // and whether the machine is actually paging right now.
        captionLabel = makeLabel("", size: 9, color: .tertiaryLabelColor)
        rootStack.addArrangedSubview(captionLabel)
        rootStack.setCustomSpacing(3, after: bar)
    }

    private func buildMemorySection() {
        let rows = addSection("MEMORY")
        addRow(Key.used, "Used", in: rows)
        addRow(Key.app, "App memory", in: rows)
        addRow(Key.wired, "Wired", in: rows)
        addRow(Key.compressed, "Compressed", in: rows)
        addRow(Key.cached, "Cached files", in: rows)
        addRow(Key.free, "Free", in: rows)
    }

    private func buildSwapSection() {
        let rows = addSection("SWAP")
        addRow(Key.swap, "Used", in: rows)
    }

    private func buildTemperatureSection() {
        let rows = addSection("TEMPERATURE")
        addRow(Key.cpuTemp, "CPU", in: rows)
        addRow(Key.gpuTemp, "GPU", in: rows)
    }

    private func buildSystemSection() {
        let rows = addSection("CPU & SYSTEM")
        addRow(Key.cpu, "CPU", in: rows)
        addRow(Key.load, "Load avg", in: rows)
        addRow(Key.uptime, "Uptime", in: rows)
        addRow(Key.thermal, "Thermal", in: rows)
        addRow(Key.disk, "Disk free", in: rows)
    }

    private func buildTopProcessSection() {
        let rows = addSection("TOP MEMORY")
        topSection = rows.superview as? NSStackView
        for _ in 0..<4 {
            let name = makeLabel("--", size: 11, color: .secondaryLabelColor)
            let value = makeValueLabel()
            let row = makeRow(left: name, right: value)
            rows.addArrangedSubview(row)
            topRows.append(row)
            topNames.append(name)
            topValues.append(value)
        }
    }

    private func buildFooter() {
        let note = makeLabel(
            "Used = app + wired + compressed. Colour follows macOS memory pressure, so a high "
                + "\"used\" with swap and cached files is not by itself a problem.",
            size: 9,
            color: .tertiaryLabelColor
        )
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 3
        rootStack.addArrangedSubview(note)

        refreshButton = makeButton("Refresh: 3s", action: #selector(cycleRefreshRate))
        styleButton = makeButton("Menu bar: RAM %", action: #selector(cycleMenuBarStyle))
        rootStack.addArrangedSubview(horizontalRow([refreshButton, styleButton]))

        loginCheckbox = makeCheckbox("Launch at login", action: #selector(toggleLaunchAtLogin))
        topCheckbox = makeCheckbox("Top processes", action: #selector(toggleTopProcesses))
        rootStack.addArrangedSubview(horizontalRow([loginCheckbox, topCheckbox]))

        iconButton = makeButton("Icon: ring", action: #selector(cycleIconStyle))
        let quit = makeButton("Quit", action: #selector(quit))
        rootStack.addArrangedSubview(horizontalRow([iconButton, quit], alignRight: true))

        updatePreferenceControls()
    }

    // MARK: - Building blocks

    private func makeLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func makeValueLabel() -> NSTextField {
        let field = NSTextField(labelWithString: "--")
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.textColor = .labelColor
        field.alignment = .right
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    private func makeCheckbox(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    /// A label / value line. Constraints are explicit rather than stack based so
    /// the value column is always flush right.
    private func makeRow(left: NSView, right: NSView) -> NSView {
        let row = NSView()
        for subview in [left, right] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            left.topAnchor.constraint(equalTo: row.topAnchor),
            left.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            right.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            right.firstBaselineAnchor.constraint(equalTo: left.firstBaselineAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 8)
        ])
        return row
    }

    private func horizontalRow(_ views: [NSView], alignRight: Bool = false) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        if alignRight {
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            stack.addArrangedSubview(spacer)
        }
        for item in views { stack.addArrangedSubview(item) }
        if !alignRight {
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            stack.addArrangedSubview(spacer)
        }
        return stack
    }

    @discardableResult
    private func addSection(_ title: String) -> NSStackView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 2

        // Pinned by hand: a bare label in a vertical stack does not reliably hug
        // the leading edge once it is stretched to the stack's width.
        let header = makeLabel(title, size: 9, weight: .semibold, color: .tertiaryLabelColor)
        header.alignment = .left
        let headerRow = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor),
            header.topAnchor.constraint(equalTo: headerRow.topAnchor),
            header.bottomAnchor.constraint(equalTo: headerRow.bottomAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: headerRow.trailingAnchor)
        ])

        let section = NSStackView(views: [separator(), headerRow, rows])
        section.orientation = .vertical
        section.alignment = .width
        section.spacing = 5
        section.setCustomSpacing(4, after: headerRow)
        rootStack.addArrangedSubview(section)
        return rows
    }

    @discardableResult
    private func addRow(_ key: String, _ title: String, in section: NSStackView) -> NSTextField {
        let name = makeLabel(title, size: 11, color: .secondaryLabelColor)
        let value = makeValueLabel()
        section.addArrangedSubview(makeRow(left: name, right: value))
        values[key] = value
        return value
    }

    // MARK: - Data

    func apply(_ snapshot: SystemSnapshot) {
        _ = view // make sure loadView ran

        let memory = snapshot.memory
        let level = memory.level

        dot.color = level.color
        statusLabel.stringValue = "Memory pressure: \(level.title)"
        statusLabel.textColor = level.color
        percentLabel.stringValue = Fmt.pct(memory.usedFraction * 100)
        percentLabel.textColor = level.color
        bar.color = level.color
        bar.fraction = CGFloat(min(1, max(0, memory.usedFraction)))

        let availableText = memory.availableFraction > 0
            ? "\(Fmt.pct(memory.availableFraction * 100)) available"
            : "availability unknown"
        let caption = "\(availableText) · \(Self.pagingText(memory.pageOutRate))"
        if captionLabel.stringValue != caption { captionLabel.stringValue = caption }

        set(Key.used, "\(Fmt.bytes(memory.usedBytes)) / \(Fmt.bytes(memory.totalBytes))")
        set(Key.app, Fmt.bytes(memory.appBytes))
        set(Key.wired, Fmt.bytes(memory.wiredBytes))
        set(Key.compressed, "\(Fmt.bytes(memory.compressedBytes))  \(Fmt.pct(memory.compressedFraction * 100))")
        set(Key.cached, Fmt.bytes(memory.cachedFileBytes))
        set(Key.free, Fmt.bytes(memory.freeBytes))
        set(Key.swap, memory.swapTotalBytes > 0
            ? "\(Fmt.bytes(memory.swapUsedBytes)) / \(Fmt.bytes(memory.swapTotalBytes))  \(Fmt.pct(memory.swapFraction * 100))"
            : "not in use")
        set(Key.cpu, Fmt.pct(snapshot.cpuPercent))
        set(Key.load, snapshot.loadAverage.isEmpty
            ? "-"
            : snapshot.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
        set(Key.uptime, Fmt.uptime(snapshot.uptime))
        set(Key.thermal, snapshot.thermal)
        set(Key.disk, snapshot.diskTotalBytes > 0
            ? "\(Fmt.bytes(snapshot.diskFreeBytes)) / \(Fmt.bytes(snapshot.diskTotalBytes))"
            : "-")

        applyTemperatures(snapshot.temperatures)
        applyTopProcesses(snapshot.topProcesses)
        updatePreferenceControls()
    }

    /// Temperature rows carry their own colour: a number alone does not tell you
    /// whether it is a problem.
    private func applyTemperatures(_ readings: TemperatureReading) {
        setReading(Key.cpuTemp, readings.cpuCelsius)
        setReading(Key.gpuTemp, readings.gpuCelsius)
    }

    private func setReading(_ key: String, _ celsius: Double?) {
        guard let celsius else {
            set(key, "n/a", color: .tertiaryLabelColor)
            return
        }
        set(key, String(format: "%.1f °C", celsius), color: Self.temperatureColor(celsius))
    }

    private static func temperatureColor(_ celsius: Double) -> NSColor {
        if celsius >= 95 { return .systemRed }    // thermal throttling territory
        if celsius >= 80 { return .systemOrange } // hot under sustained load
        return .labelColor
    }

    /// Swap *used* never shrinks, so it is a poor "right now" signal. Pageout
    /// rate is the one that actually tells you whether you are being paged.
    private static func pagingText(_ rate: Double) -> String {
        rate < 1 ? "paging idle" : String(format: "paging %.0f pages/s", rate)
    }

    /// Skips no-op writes: setting `stringValue` invalidates layout and forces a
    /// redraw, and most rows (uptime, thermal, disk) rarely change.
    private func set(_ key: String, _ text: String, color: NSColor? = nil) {
        guard let label = values[key] else { return }
        if label.stringValue != text { label.stringValue = text }
        if let color, label.textColor != color { label.textColor = color }
    }

    private func applyTopProcesses(_ processes: [ProcessUsage]) {
        guard let section = topSection else { return }
        let wanted = prefs.showTopProcesses ? processes : []
        section.isHidden = wanted.isEmpty
        for (index, row) in topRows.enumerated() {
            guard index < wanted.count else {
                row.isHidden = true
                continue
            }
            row.isHidden = false
            topNames[index].stringValue = wanted[index].name
            topValues[index].stringValue = Fmt.bytes(wanted[index].footprintBytes)
        }
    }

    private func updatePreferenceControls() {
        refreshButton?.title = "Refresh: \(prefs.refreshInterval.label)"
        styleButton?.title = "Menu bar: \(prefs.style.label)"
        iconButton?.title = "Icon: \(prefs.iconStyle.label)"
        loginCheckbox?.state = LoginItem.isEnabled ? .on : .off
        topCheckbox?.state = prefs.showTopProcesses ? .on : .off
    }

    // MARK: - Actions

    @objc private func cycleIconStyle() {
        prefs.iconStyle = prefs.iconStyle.next
        updatePreferenceControls()
        onPrefsChanged?()
    }

    @objc private func cycleRefreshRate() {
        prefs.refreshInterval = prefs.refreshInterval.next
        updatePreferenceControls()
        onPrefsChanged?()
    }

    @objc private func cycleMenuBarStyle() {
        prefs.style = prefs.style.next
        updatePreferenceControls()
        onPrefsChanged?()
    }

    @objc private func toggleTopProcesses() {
        prefs.showTopProcesses = topCheckbox.state == .on
        updatePreferenceControls()
        onPrefsChanged?()
    }

    @objc private func toggleLaunchAtLogin() {
        let wanted = loginCheckbox.state == .on
        do {
            try LoginItem.setEnabled(wanted)
        } catch {
            loginCheckbox.state = wanted ? .off : .on
            report(error)
        }
        updatePreferenceControls()
    }

    @objc private func quit() {
        onQuit?()
    }

    /// Used by `--self-test` to confirm the panel actually got real numbers.
    func debugValues() -> [String: String] {
        values.mapValues { $0.stringValue }
    }

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not update the login item"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
