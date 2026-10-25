import AppKit
import GhosttyTerminal
import SwiftUI

// usage: EmbeddedSpike <workload> [chunk-bytes] [repeat]
// The control: the same window size and workload through the embedded surface
// termio ships today, fed the way termio feeds it from termiod
// (InMemoryTerminalSession.receive → ghostty_surface_write_buffer).
let arguments = CommandLine.arguments
guard arguments.count >= 2, let workload = FileManager.default.contents(atPath: arguments[1]) else {
    FileHandle.standardError.write("usage: EmbeddedSpike <workload> [chunk-bytes] [repeat]\n".data(using: .utf8)!)
    exit(2)
}
let chunk = arguments.count >= 3 ? Int(arguments[2]) ?? 65536 : 65536
let repeats = arguments.count >= 4 ? Int(arguments[3]) ?? 1 : 1

let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
let app = NSApplication.shared
// Top-level code runs on the main thread; the view state is main-actor bound.
let window = MainActor.assumeIsolated { () -> NSWindow in
    let state = TerminalViewState()
    state.configuration = TerminalSurfaceOptions(backend: .inMemory(session), fontSize: 13)
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1600, height: 1000),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "EmbeddedSpike"
    window.contentView = NSHostingView(rootView: TerminalSurfaceView(context: state))
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    return window
}

let feeder = Thread {
    Thread.sleep(forTimeInterval: 2.0)  // the surface is built on first layout
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<max(repeats, 1) {
        var offset = 0
        while offset < workload.count {
            let end = min(offset + chunk, workload.count)
            session.receive(workload.subdata(in: offset..<end))
            offset = end
        }
    }
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    // repeat 0 is the visual check: draw the workload once and stay open.
    if repeats == 0 { return }
    Thread.sleep(forTimeInterval: 1.0)
    let megabytes = Double(workload.count * repeats) / 1_048_576
    print(String(format: "EmbeddedSpike %@: %.1f MB in %.3f s = %.1f MB/s (chunk %d, x%d)",
                 (arguments[1] as NSString).lastPathComponent, megabytes, seconds, megabytes / seconds, chunk, repeats))
    exit(0)
}
feeder.start()
app.run()
