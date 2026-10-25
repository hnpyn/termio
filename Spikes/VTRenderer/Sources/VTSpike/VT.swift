import Foundation
import GhosttyVt
import os

/// One libghostty-vt terminal behind one lock. The IO thread writes under it;
/// the renderer holds it only for `beginUpdate`, the half of a render-state
/// update that needs the terminal (render.h, "Two-Phase Updates").
final class VT: @unchecked Sendable {
    let terminal: GhosttyTerminal
    let renderState: GhosttyRenderState
    private let lock = NSLock()
    /// The renderer raises this before it asks for `lock`. NSLock is not fair:
    /// a writer looping over chunks re-takes it before a waiting renderer
    /// wakes, which starved frames for up to 34 ms during a flood.
    private var rendererWaiting = os_unfair_lock_s()
    private var rendererWaitingFlag = false

    init(cols: UInt16, rows: UInt16) {
        var terminal: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &terminal, cols, rows) == GHOSTTY_SUCCESS, let terminal else {
            fatalError("ghostty_terminal_new failed")
        }
        var renderState: GhosttyRenderState?
        guard ghostty_render_state_new(nil, &renderState) == GHOSTTY_SUCCESS, let renderState else {
            fatalError("ghostty_render_state_new failed")
        }
        self.terminal = terminal
        self.renderState = renderState
    }

    func write(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        lock.lock()
        ghostty_terminal_vt_write(terminal, base.assumingMemoryBound(to: UInt8.self), bytes.count)
        lock.unlock()
        while isRendererWaiting() { sched_yield() }
    }

    private func isRendererWaiting() -> Bool {
        os_unfair_lock_lock(&rendererWaiting)
        defer { os_unfair_lock_unlock(&rendererWaiting) }
        return rendererWaitingFlag
    }

    private func setRendererWaiting(_ value: Bool) {
        os_unfair_lock_lock(&rendererWaiting)
        rendererWaitingFlag = value
        os_unfair_lock_unlock(&rendererWaiting)
    }

    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        lock.lock()
        _ = ghostty_terminal_resize(terminal, cols, rows, cellWidth, cellHeight)
        lock.unlock()
    }

    /// Captures the terminal into the render state. Returns how long the
    /// terminal lock was held, which is what the IO thread waits on.
    @discardableResult
    func updateRenderState() -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        setRendererWaiting(true)
        lock.lock()
        setRendererWaiting(false)
        _ = ghostty_render_state_begin_update(renderState, terminal)
        lock.unlock()
        let held = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        _ = ghostty_render_state_end_update(renderState)
        return held
    }
}
