import AppKit

let app = NSApplication.shared
// Belt and braces: the bundled Info.plist already sets LSUIElement, but this
// keeps the binary from grabbing a Dock icon when run straight from .build.
app.setActivationPolicy(.accessory)

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--render-preview"), flag + 1 < arguments.count {
    Preview.renderAll(to: arguments[flag + 1])
    exit(0)
}

AppDelegate.selfTest = arguments.contains("--self-test")

// `--cpu-probe <seconds>`: prints the sampler's CPU reading once a second so it
// can be lined up against `top` when tuning.
if let flag = arguments.firstIndex(of: "--cpu-probe"), flag + 1 < arguments.count {
    let seconds = Int(arguments[flag + 1]) ?? 5
    let sampler = SystemSampler()
    _ = sampler.cpuPercent()
    for _ in 0..<seconds {
        Thread.sleep(forTimeInterval: 1)
        print(String(format: "sampler cpu = %.1f%%", sampler.cpuPercent()))
    }
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
