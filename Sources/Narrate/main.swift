import AppKit

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}
if CommandLine.arguments.contains("--selftest-stream") {
    exit(MainActor.assumeIsolated { StreamSelfTest.run() })
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
    app.run()
}
