import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Prefs.shared
    private let sampler = SystemSampler()
    private let processQueue = DispatchQueue(label: "com.arief.sysmonbar.processes", qos: .utility)

    private var statusItem: NSStatusItem!
    private var detail: DetailViewController!
    private var panelController: PanelController!

    private var iconTimer: Timer?
    private var detailTimer: Timer?
    private var hoverTimer: Timer?

    private var snapshot = SystemSnapshot()
    private var topProcesses: [ProcessUsage] = []
    private var processesInFlight = false
    private var ticksSinceProcessSample = 0
    private var pointerLeftAt: Date?
    private var pointerEnteredAt: Date?
    private var suppressUntilPointerLeaves = false
    private var paused = false
    private var selfTestTicks = 0
    private var lastStatusKey: String?

    /// Set by `--self-test` before the app starts.
    static var selfTest = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp])
        }

        detail = DetailViewController()
        detail.onQuit = { NSApp.terminate(nil) }
        detail.onPrefsChanged = { [weak self] in self?.preferencesChanged() }
        panelController = PanelController(detail: detail)

        refresh()
        startIconTimer()

        let hover = Timer(
            timeInterval: 0.15, target: self, selector: #selector(hoverTick), userInfo: nil, repeats: true
        )
        RunLoop.main.add(hover, forMode: .common)
        hoverTimer = hover

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification
        ] {
            workspace.addObserver(self, selector: #selector(systemWillSleep), name: name, object: nil)
        }
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ] {
            workspace.addObserver(self, selector: #selector(systemDidWake), name: name, object: nil)
        }

        // Rearranging or unplugging displays invalidates the hit rects, so drop
        // the panel and let the next hover rebuild them.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        if Self.selfTest { scheduleSelfTest() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        iconTimer?.invalidate()
        detailTimer?.invalidate()
        hoverTimer?.invalidate()
    }

    // MARK: - Ticking

    private func startIconTimer() {
        iconTimer?.invalidate()
        let timer = Timer(
            timeInterval: prefs.refreshInterval.rawValue,
            target: self,
            selector: #selector(iconTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        iconTimer = timer
    }

    private func startDetailTimer() {
        guard detailTimer == nil else { return }
        let timer = Timer(
            timeInterval: 1.0, target: self, selector: #selector(detailTick), userInfo: nil, repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        detailTimer = timer
    }

    private func stopDetailTimer() {
        detailTimer?.invalidate()
        detailTimer = nil
    }

    @objc private func iconTick() {
        refresh()
    }

    @objc private func detailTick() {
        refresh()
        // Scanning every process is the only genuinely costly part, so it runs at
        // a third of the panel's refresh rate and only while the panel is open.
        ticksSinceProcessSample += 1
        if ticksSinceProcessSample >= 3 {
            ticksSinceProcessSample = 0
            sampleProcesses()
        }
    }

    private func refresh() {
        snapshot = sampler.snapshot(topProcesses: topProcesses)
        updateStatusItem()
        guard panelController.isVisible else { return }
        detail.apply(snapshot)
        // No resize here on purpose: values change, but the layout does not.
        // Forcing an autolayout pass every tick was the single biggest cost of
        // having the panel open.
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let memory = snapshot.memory
        let percentText = Fmt.pct(memory.usedFraction * 100)

        let title: String
        switch prefs.style {
        case .ram:
            title = percentText
        case .ramAndCPU:
            title = "\(percentText) · \(Fmt.pct(snapshot.cpuPercent))"
        case .iconOnly:
            title = ""
        }

        // Redrawing the icon and re-setting the title is only worth it when the
        // rendered result actually changes; the gauge is ~13 px across, so a whole
        // percent is far finer than the eye can resolve anyway.
        let key = "\(prefs.iconStyle.label)|\(memory.level.title)|\(percentText)|\(title)"
        guard key != lastStatusKey else { return }
        lastStatusKey = key

        button.image = IconRenderer.make(
            style: prefs.iconStyle, level: memory.level, fraction: memory.usedFraction
        )
        button.title = title
    }

    // MARK: - Hover handling

    /// Where the status item actually is, as a list of candidate rects.
    ///
    /// The frame AppKit reports for the status item window cannot be trusted as
    /// soon as a second display is attached. Measured on this machine, with the
    /// item visible in the menu bar, one run reported y = 1254 (inside the menu
    /// bar strip, which ends at 1280) and another reported y = 1284 - 30pt too
    /// high, outside the menu bar entirely. Hover was then checked against empty
    /// space and never matched the icon the eye could see.
    ///
    /// So the search area is rebuilt from first principles instead: take the
    /// screen's *real* menu bar strip, and slide the item's x range into it. Two
    /// x candidates are used per screen because each display's menu bar carries
    /// the same set of items, so the item sits the same distance from the right
    /// edge on every display.
    private func statusItemHitRects() -> [NSRect] {
        guard let button = statusItem.button, let window = button.window else { return [] }
        let reported = window.convertToScreen(button.convert(button.bounds, to: nil))
        var rects: [NSRect] = [reported]

        let distanceFromRight = window.screen.map { $0.frame.maxX - reported.maxX }
        let tolerance: CGFloat = 4

        for screen in NSScreen.screens {
            let stripHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
            let stripBottom = screen.frame.maxY - stripHeight

            var xs: [CGFloat] = [reported.minX - tolerance]
            if let distanceFromRight {
                xs.append(screen.frame.maxX - distanceFromRight - reported.width - tolerance)
            }

            for x in xs {
                rects.append(NSRect(
                    x: x,
                    y: stripBottom,
                    width: reported.width + tolerance * 2,
                    height: stripHeight + 2
                ))
            }
        }
        return rects
    }

    /// The rect the pointer is currently over, if any. Also matches the panel
    /// itself so the pointer can travel into it without closing it.
    private func hoverTarget(for mouse: NSPoint) -> NSRect? {
        statusItemHitRects().first { $0.contains(mouse) }
    }

    /// Cursor polling instead of tracking areas: a couple of rect comparisons at
    /// 6 Hz cost nothing, and it behaves identically no matter how the menu bar
    /// window is hosted.
    @objc private func hoverTick() {
        guard !paused else { return }
        let mouse = NSEvent.mouseLocation
        let hit = hoverTarget(for: mouse)

        if suppressUntilPointerLeaves {
            if hit == nil { suppressUntilPointerLeaves = false }
            return
        }

        var inside = hit != nil
        if !inside, panelController.isVisible {
            inside = panelController.frame.contains(mouse)
        }

        if Self.selfTest, selfTestTicks < 24 {
            selfTestTicks += 1
            print("self-test tick \(selfTestTicks): mouse = \(mouse) hit = "
                + "\(hit.map(NSStringFromRect) ?? "none") inside = \(inside) "
                + "visible = \(panelController.isVisible)")
        }

        if inside {
            pointerLeftAt = nil
            if !panelController.isVisible {
                // Small dwell time so the panel does not flash open when the
                // pointer merely crosses the menu bar on its way somewhere else.
                if let enteredAt = pointerEnteredAt {
                    if Date().timeIntervalSince(enteredAt) >= 0.15 { showPanel(anchoredTo: hit) }
                } else {
                    pointerEnteredAt = Date()
                }
            }
        } else {
            pointerEnteredAt = nil
            guard panelController.isVisible else { return }
            if let leftAt = pointerLeftAt {
                if Date().timeIntervalSince(leftAt) > 0.3 { hidePanel() }
            } else {
                pointerLeftAt = Date()
            }
        }
    }

    /// `anchor` is the hit rect the pointer matched, so the panel lands under the
    /// display the user is actually looking at. When there is no hit rect (a
    /// programmatic show, or a click whose geometry could not be resolved), the
    /// pointer itself is used as the anchor - it is on the item by definition.
    private func showPanel(anchoredTo hit: NSRect? = nil) {
        detail.apply(snapshot)
        let mouse = NSEvent.mouseLocation
        let anchor = hit ?? hoverTarget(for: mouse) ?? menuBarStripRect(containing: mouse)
        panelController.show(below: anchor)
        startDetailTimer()
        sampleProcesses()
    }

    /// Fallback anchor: the menu bar strip of whichever screen holds the point.
    private func menuBarStripRect(containing point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let screen else { return NSRect(x: point.x - 30, y: point.y, width: 60, height: 24) }
        let stripHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return NSRect(
            x: point.x - 30,
            y: screen.frame.maxY - stripHeight,
            width: 60,
            height: stripHeight
        )
    }

    private func hidePanel() {
        panelController.hide()
        stopDetailTimer()
        pointerLeftAt = nil
    }

    @objc private func statusItemClicked() {
        if panelController.isVisible {
            hidePanel()
            suppressUntilPointerLeaves = true
        } else {
            showPanel()
        }
    }

    // MARK: - Processes

    private func sampleProcesses() {
        guard prefs.showTopProcesses, !processesInFlight else { return }
        processesInFlight = true

        processQueue.async { [weak self] in
            let processes = SystemSampler.topProcesses(limit: 4)
            DispatchQueue.main.async {
                guard let self else { return }
                self.processesInFlight = false
                self.topProcesses = processes
                guard self.panelController.isVisible else { return }
                self.snapshot.topProcesses = processes
                self.detail.apply(self.snapshot)
                self.panelController.resizeIfNeeded()
            }
        }
    }

    private func preferencesChanged() {
        startIconTimer()
        updateStatusItem()

        if prefs.showTopProcesses {
            if panelController.isVisible { sampleProcesses() }
        } else {
            topProcesses = []
            snapshot.topProcesses = []
            if panelController.isVisible {
                detail.apply(snapshot)
                panelController.resizeIfNeeded()
            }
        }
    }

    // MARK: - Sleep / wake

    @objc private func systemWillSleep() {
        paused = true
        iconTimer?.invalidate()
        iconTimer = nil
        hidePanel()
    }

    @objc private func systemDidWake() {
        guard paused else { return }
        paused = false
        refresh()
        startIconTimer()
    }

    /// Displays added, removed or rearranged: every cached position is stale.
    @objc private func screenParametersChanged() {
        hidePanel()
        lastStatusKey = nil // force the icon to redraw at the new backscale
        refresh()
    }

    // MARK: - Self test

    /// `--self-test` drives the real hover path: it warps the pointer onto the
    /// status item, waits for the hover timer, reports what happened, then puts
    /// the pointer back where it was.
    private func scheduleSelfTest() {
        let originalPointer = NSEvent.mouseLocation

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let button = self.statusItem.button, let window = button.window else {
                print("self-test: FAIL - status item has no window")
                exit(1)
            }
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let memory = self.snapshot.memory
            let screenIndex = NSScreen.screens.firstIndex { $0 == window.screen } ?? -1
            print("self-test: screens = " + NSScreen.screens.enumerated().map { index, screen in
                "[\(index)] frame=\(NSStringFromRect(screen.frame)) "
                    + "visible=\(NSStringFromRect(screen.visibleFrame))"
            }.joined(separator: " | "))
            print("self-test: status item window = \(NSStringFromRect(window.frame)) "
                + "on screen \(screenIndex)/\(NSScreen.screens.count)")
            print("self-test: reported status item frame = \(rect)")
            let hitRects = self.statusItemHitRects()
            for (index, candidate) in hitRects.enumerated() {
                print("self-test: hit rect [\(index)] = \(NSStringFromRect(candidate))")
            }
            print("self-test: title = \"\(button.title)\" icon = \(button.image?.size ?? .zero)")
            print("self-test: level = \(memory.level.title) "
                + "used = \(Fmt.pct(memory.usedFraction * 100)) "
                + "swap = \(Fmt.pct(memory.swapFraction * 100)) "
                + "available = \(Fmt.pct(memory.availableFraction * 100)) "
                + "pressure_sysctl = \(memory.pressureRaw) "
                + "pageout = \(String(format: "%.1f", memory.pageOutRate))/s")

            let temps = self.snapshot.temperatures
            func celsius(_ value: Double?) -> String {
                value.map { String(format: "%.1f C", $0) } ?? "n/a"
            }
            let start = Date()
            _ = self.sampler.temperatures.readNow()
            let ms = Date().timeIntervalSince(start) * 1000
            print("self-test: temperature cpu = \(celsius(temps.cpuCelsius)) "
                + "gpu = \(celsius(temps.gpuCelsius)) "
                + String(format: "(read costs %.1f ms)", ms))

            // Aim at the rect the app will actually test against, which is the
            // whole point of the multi-display fix.
            let target = hitRects.first ?? rect
            self.warp(to: NSPoint(x: target.midX, y: target.midY))

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self else { return }
                print("self-test: panel visible after hover = \(self.panelController.isVisible)")
                print("self-test: panel frame = \(self.panelController.frame)")
                for (key, value) in self.detail.debugValues().sorted(by: { $0.key < $1.key }) {
                    print("self-test:   \(key) = \(value)")
                }

                // Hold the panel open and measure what it actually costs.
                let cpuStart = self.selfCPUSeconds()
                let wallStart = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self else { return }
                    let cpu = self.selfCPUSeconds() - cpuStart
                    let wall = Date().timeIntervalSince(wallStart)
                    print(String(
                        format: "self-test: cost while panel is open = %.2f%% of one core over %.1fs",
                        cpu / wall * 100, wall
                    ))

                    // Park the pointer somewhere that is neither the status item
                    // nor the panel, so the assertion is not affected by wherever
                    // the real pointer happened to be.
                    self.warp(to: self.neutralPointerPoint())
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                        guard let self else { exit(1) }
                        let closed = !self.panelController.isVisible
                        print("self-test: panel hidden after pointer left = \(closed)")
                        print("self-test: \(self.processScanTiming())")
                        print("self-test: cpu over 800ms of one busy core = \(self.busyCPUProbe())")
                        self.warp(to: originalPointer)
                        exit(closed ? 0 : 1)
                    }
                }
            }
        }
    }

    /// Total CPU seconds burned by this process so far.
    private func selfCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ time: timeval) -> Double {
            Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// How long a full process scan costs. It runs every few seconds while the
    /// panel is open, so this number is the app's real cost driver.
    private func processScanTiming() -> String {
        let start = Date()
        let processes = SystemSampler.topProcesses(limit: 4)
        let ms = Date().timeIntervalSince(start) * 1000
        return String(format: "process scan = %.1f ms for %d processes", ms, processes.count)
    }

    /// Centre of the screen: far from the status item and from the panel.
    private func neutralPointerPoint() -> NSPoint {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return NSPoint(x: visible.midX, y: visible.midY - 200)
    }

    /// Pegs one core for 800ms and reports what the sampler made of it; on an
    /// n-core machine the answer should be roughly `100 / n`.
    private func busyCPUProbe() -> String {
        _ = sampler.cpuPercent()
        let start = Date()
        var accumulator = 0.0
        while Date().timeIntervalSince(start) < 0.8 {
            accumulator += sin(accumulator + 1)
        }
        return Fmt.pct(sampler.cpuPercent())
    }

    private func warp(to point: NSPoint) {
        guard let screen = NSScreen.screens.first else { return }
        CGWarpMouseCursorPosition(CGPoint(x: point.x - screen.frame.minX, y: screen.frame.maxY - point.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
