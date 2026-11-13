import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-qa") {
    let out = i + 1 < args.count ? args[i + 1] : "qa-out"
    exit(QARenderer.run(outDir: out) ? 0 : 1)
}

if let i = args.firstIndex(of: "--ax-probe") {
    // Pairs of Cocoa screen coordinates: --ax-probe x1 y1 x2 y2 …
    let nums = args[(i + 1)...].compactMap(Double.init)
    _ = NSApplication.shared
    AX.setGlobalTimeout(0.3)
    Trace.log("probe start ax=\(Permissions.shared.ax)")
    let loc = TextLocator()
    stride(from: 0, to: nums.count - 1, by: 2).forEach { loc.probe(CGPoint(x: nums[$0], y: nums[$0 + 1])) }
    Thread.sleep(forTimeInterval: 0.3)
    exit(0)
}

if let i = args.firstIndex(of: "--demo"), i + 3 < args.count,
   let x = Double(args[i + 1]), let y = Double(args[i + 2]) {
    // Reads at a point and saves a strip of screenshots (overlay included) to check the motion.
    let out = URL(fileURLWithPath: args[i + 3], isDirectory: true)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let reader = ReaderController()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let p = CGPoint(x: x, y: y)
        reader.readAtPointer(at: p)
        reader.overlay.setCapturable(true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            reader.overlay.setCapturable(true)
            guard let screen = Coords.screen(containing: p).map(ScreenInfo.init) else { exit(1) }
            let region = CGRect(x: p.x - 260, y: p.y - 70, width: 520, height: 140).intersection(screen.frame)
            for k in 0..<14 {
                if let img = try? await ScreenCapture.image(of: region, screen: screen, excludeSelf: false),
                   let d = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                    try? d.write(to: out.appendingPathComponent(String(format: "f%02d.png", k)))
                }
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
            Trace.log("demo done: \(reader.sourceName), \(reader.lastLatency)")
            exit(0)
        }
    }
    app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
