---
title: The client VT follows the stream
status: draft
type: design
created: 2026-10-24
updated: 2026-10-25
related:
  - 20260730-termiod-session-protocol.md
  - 20260901-pty-size-is-not-the-write-token.md
  - 20260902-superlogical-server-memory-parking.md
---

# The client VT follows the stream

> Move termio's client terminal to Rex's architecture: the client owns a
> libghostty-vt terminal, its size changes only at a marker in the byte stream,
> and every attach decodes a snapshot into a fresh terminal.

## Why

Every client must parse at the PTY's authoritative size (§C.5 of the session
protocol). termio meets that requirement with timing, not with structure:

- The daemon's resize is a **barrier**. It buffers each client's `D` frames,
  sends a full-screen keyframe, then releases the buffer.
- The client's VT belongs to ghostty's embedded surface, and its size comes from
  the view's pixels: `ghostty_surface_set_size` → IO-thread mailbox → a 25 ms
  coalesce → `terminal.resize`. Bytes enter on another path,
  `ghostty_surface_write_buffer`, which parses at once. Nothing orders the two.
- `TerminalKeyframeHold` bridges the gap with guesses: a 30 ms wait, a 250 ms
  deadline, a 1.75 s grace for a surface that never reports, a 500 ms backstop,
  a 400 ms declaration debounce and a 150 ms drag throttle.

Each guess has a failure mode, and each fix adds a state. #755 fixed input boxes
scrambled after an app update. It needed three review rounds and four extra
states. A session that was not selected at relaunch still reads 15 rows for a
few seconds after it is shown.

Rex (Superlogical) has none of this machinery. Its ordering comes from structure.

## What Rex does

This section records what the shipped binaries show. Evidence was gathered on
2026-10-24 from `Rex Beta.app` build 1408 and its server. **Observed** means read
in the binary; **inferred** means not traced to the end.

| Claim | Evidence | Level |
|---|---|---|
| The client uses libghostty-vt, not ghostty's embedded surface | 0 `ghostty_surface_*` / `ghostty_app_*` / `GHOSTTY_ACTION_*` strings (termio's binary has 6). The embedded `abi.json` is libghostty-vt's own type export (`src/terminal/c/types.zig`) | observed |
| It is upstream libghostty-vt, not a fork | All 187 ABI types appear in upstream ghostty history. Its terminfo names upstream commit `36ec90a07`. Several types it uses landed upstream on 2026-10-21 (`GhosttyTerminalWriteStop`, snapshot Kitty data) | observed |
| The client renders with its own Metal renderer | `swift-ghostty_GhosttyRender.bundle/default.metallib` (`cell_bg_fragment`, `text_vertex`, `image_vertex`, …); types `GlyphCache`, `GlyphAtlasTextures`, `CellFontSet`, `ImageStore`, `CursorPlan`. `swift-ghostty` is Superlogical's package and is not public | observed |
| The client splits the stream at `ESC _ rex1;` | `FUN_100f4a7ac` scans with `memchr(…, 0x1b, …)` against a 7-byte literal `1b 5f 72 65 78 31 3b` and the terminator `1b 5c` | observed |
| The control is applied in place, between the bytes before and after it | The splitter is synchronous. Bytes before the marker go to the sink first, then the control handler `FUN_100f4bd08` runs, then the rest | observed |
| A resize control resizes the client VT | `FUN_100f4bd08` takes the resize branch (enum tag 0, two packed `UInt16`) after flushing pending bytes. The call into libghostty is indirect and was not traced | inferred |
| Attach decodes a snapshot into a fresh terminal | upstream `ghostty_snapshot_decoder_decode` returns a new terminal through an out parameter (`snapshot.h:781`); Rex's `SnapshotDecoder` holds `decodedTerminal: GhosttyVT.Terminal?` | observed |
| The view does not resize the VT for server blocks | `automaticallyResizesTerminal` and `onGridSizeChange` exist on the render view and surface. The value Rex sets was not found | inferred |
| Server order: wait for ground → VT resize → `TIOCSWINSZ` → APC in the stream | Go pclntab: `scheduleGroundMutationsLocked` calls `VTGround`; `term.(*Terminal).Resize` calls `libghostty.(*Terminal).Resize`, then `pty.resize`; `applyGroundMutationsLocked` calls `enqueueEncodableLocked` after the mutation | observed |

Rex's own protocol document states the contract: "Program bytes before it were
written at the old size, and bytes after it at the new size."

## The design

### Daemon

The session actor already serialises both halves. `fan_out` of PTY bytes and
`apply_size_policy` run on the same task, and `Data` and `Event` share each
client's ordered `out` channel. The sidecar already receives `Resize` in its FIFO
before the ioctl that raises SIGWINCH.

1. A client that negotiates a new capability, `vt_stream`, gets no resize
   barrier. It receives `E resized {rows, cols, mode}` at the exact position in
   its stream where the PTY changed size, with no keyframe.
2. `mode` is the operation the sidecar applied: `reflow`, `truncate`, or
   `shell` (`resize_for_shell`: clear from the prompt row down, then reflow).
   The client applies the identical operation.
3. The attach snapshot for a `vt_stream` client is libghostty's native
   snapshot (`ghostty_snapshot_encode`), not VT bytes rendered by
   `TermioSnapshot.render`. It carries modes, the Kitty keyboard stack, scroll
   region, charsets, both screens, scrollback and the unfinished parser input.
4. Resize stays a ground-state mutation: the marker is placed only where the
   sidecar parser is in the ground state, so it never lands inside an escape
   sequence.
5. Clients without `vt_stream` keep today's barrier and keyframes.

The anti-100× invariant is unchanged. The daemon still delivers bytes without
waiting on the sidecar parse; only the marker's position is new.

### Client (Mac first, then iOS)

1. A new terminal stack replaces the embedded surface for termiod sessions: a
   libghostty-vt terminal plus termio's own renderer, as Rex does.
2. One reader thread owns the terminal. It writes `D` bytes with `vt_write`
   and, on `E resized`, calls `ghostty_terminal_resize` before the next byte.
   The VT size has no other writer.
3. The view never resizes the VT. A view larger than the grid shows blank space
   to the right and bottom; a smaller one clips. The view reports the grid it
   could hold, and that report is the viewport declaration the §12 size policy
   already consumes.
4. Attach decodes the snapshot into a new terminal and swaps it in. Nothing is
   reset in place.
5. Input goes through libghostty-vt's key, mouse, paste and focus encoders
   against the terminal's live modes.

### What gets deleted

`TerminalKeyframeHold` and every timer listed under *Why*; `noteSurfaceGrid` and
the surface-report plumbing; the letterbox's half-cell slack;
`TermioSnapshot.render` for `vt_stream` clients; the resize barrier for
`vt_stream` clients; the settle nudge, if parity tests show the in-band reflow
leaves nothing for it to repair.

### What stays

The sidecar VT, the `execve` handoff, the §12 size policy and the write token.
Rex's size owner rule is not adopted: it hands the size away when the owner's
connection drops, which is the phone-lock reflow §12 removed.

## The renderer is the cost

libghostty-vt provides the terminal, a render state with dirty rows, snapshots,
key and mouse encoders, selection gestures, search, a formatter and Kitty image
placements. It does not provide font shaping or GPU drawing. Rex wrote those as
`GhosttyRender`, and that package is not public.

termio's embedded surface gives all of the following today, and the new stack
must reach parity before it can be the default:

- text: CoreText shaping, ligatures, wide and combining characters, emoji,
  bold and italic faces, the font-size shortcuts;
- cursor styles and blinking, selection and copy, ⌘F search;
- IME preedit and its candidate-window position;
- mouse reporting, scroll and the alternate-scroll mode;
- links: hover detection, ⌘-click, path clicks inside mouse-capturing TUIs;
- the actions termio consumes today: title, PWD, progress (OSC 9;4), bell,
  desktop notifications, command finished, clipboard read and write;
- Kitty graphics;
- themes and the dark/light switch.

## Phases

Each phase ends at a gate. A failed gate stops the work.

0. **Engine bump.** Move both forks to a ghostty at or after 2026-10-21, so the
   client and the daemon get `vt_write_until`, snapshot Kitty data and the
   current render-state API. Follow the three-repo bump procedure. Gate: the
   existing test suites pass.
   **Done 2026-10-25 (#761):** ghostty cec8b92 everywhere. ghostty needs Zig
   0.17 since 2026-10-20, and stock Zig 0.17 cannot build iOS without
   ghostty's own patch to its std, which libghostty-swift CI now applies.
1. **Renderer spike.** A test window that decodes a snapshot taken by termiod
   and draws it, then streams `cat` of a large file. Gate: frame time and
   throughput within 20% of the embedded surface on the same machine.
   **Passed 2026-10-25** (branch `spike/vt-renderer`, numbers in its README).
   Throughput while rendering, median of 5: 276 vs 201 MB/s on a scrolling
   log, 769 vs 581 MB/s on full-screen redraws. Frame CPU p99 1.2–1.9 ms. The
   spike draws less than a real renderer (no shaping, decorations, colour
   emoji or render hold), so these are a ceiling, not a forecast. One finding
   carries into phase 3: NSLock let a writer looping over chunks starve the
   renderer for up to 34 ms, so the writer must yield when the renderer is
   waiting. libghostty-vt for Swift is one upstream command,
   `zig build -Demit-lib-vt`, which emits an xcframework for macOS and iOS.
2. **Daemon `vt_stream`.** Capability, in-place `E resized` with `mode`, native
   snapshot on attach. Gate: a parity test feeds one recorded PTY stream with
   resizes to the sidecar and to a second libghostty-vt terminal that applies
   the markers; the two screens must be byte-identical after every marker.
3. **Mac client stack behind a setting.** Gate: the parity list above, plus the
   relaunch and resize harnesses used for #755 (app VT against termiod's VT).
4. **Default on the Mac.** Delete the hold machinery.
5. **iOS.** The phone's mirror is a live surface fed through the companion
   bridge, so the marker must cross the bridge in order.
6. **Resume by byte offset**, as Rex's `RESUME` does: a reconnect continues the
   stream with no snapshot.

## Risks

- **Renderer parity is the largest risk.** It is a full terminal renderer for
  two platforms. Phase 1's gate exists to fail early.
- libghostty's C API is unversioned and still moving; snapshot format version 1
  has no compatibility promise. The daemon and the clients already pin one
  engine together, which holds as long as that rule does.
- Client and daemon apply resizes with different cell pixel sizes (termiod_vt
  uses 8×16). Anything that depends on pixel size, such as Kitty placements and
  size reports, must be checked by the parity test.
- Both the client and the daemon can answer terminal queries. Today only the
  writer's surface answers (`TerminalDeviceReport`); the new client must keep
  that rule.

## Open questions

- Whether Rex sets `automaticallyResizesTerminal = false` for server blocks was
  not found. The design does not depend on it.
- How a grid larger than the view should look: clip, scale, or follow the
  cursor.
- Whether `swift-ghostty` will be published. If it is, phases 1 and 3 shrink to
  an adoption.
