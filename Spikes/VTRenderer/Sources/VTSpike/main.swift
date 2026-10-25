import AppKit

// usage: VTSpike <workload> [chunk-bytes] [repeat]
// Opens a 1600x1000pt window, streams the workload into the terminal as fast
// as the terminal takes it while the renderer draws at display rate, then
// prints throughput and frame statistics and exits.
let arguments = CommandLine.arguments
guard arguments.count >= 2, let workload = FileManager.default.contents(atPath: arguments[1]) else {
    FileHandle.standardError.write("usage: VTSpike <workload> [chunk-bytes] [repeat]\n".data(using: .utf8)!)
    exit(2)
}
let chunk = arguments.count >= 3 ? Int(arguments[2]) ?? 65536 : 65536
let repeats = arguments.count >= 4 ? Int(arguments[3]) ?? 1 : 1

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let scale = NSScreen.main?.backingScaleFactor ?? 2
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1600, height: 1000),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "VTSpike"
let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000), scale: scale)
window.contentView = view
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

let feeder = Thread {
    Thread.sleep(forTimeInterval: 1.0)  // let the window and display link settle
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<max(repeats, 1) { workload.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            view.vt.write(UnsafeRawBufferPointer(rebasing: bytes[offset..<end]))
            offset = end
        }
    } }
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    // repeat 0 is the visual check: draw the workload once and stay open.
    if repeats == 0 { return }
    Thread.sleep(forTimeInterval: 1.0)
    let megabytes = Double(workload.count * repeats) / 1_048_576
    print(String(format: "VTSpike %@: %.1f MB in %.3f s = %.1f MB/s (chunk %d, x%d)",
                 (arguments[1] as NSString).lastPathComponent, megabytes, seconds, megabytes / seconds, chunk, repeats))
    print(view.stats.summary())
    exit(0)
}
feeder.start()
app.run()
