import AppKit

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}
if let i = CommandLine.arguments.firstIndex(of: "--render-styles") {
    let dir = CommandLine.arguments.dropFirst(i + 1).first ?? "style-renders"
    exit(MainActor.assumeIsolated { StyleRender.run(outDir: dir) })
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
