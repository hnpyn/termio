# VTRenderer spike

Phase 1 of `docs/design/20261024-client-vt-follows-the-stream.md`: a renderer of
termio's own on libghostty-vt, measured against the embedded surface termio
ships today. Throwaway code; it is not part of the app.

## Run it

```sh
# libghostty-vt at the pinned ghostty (cec8b92), Zig 0.17:
zig build -Demit-lib-vt -Doptimize=ReleaseFast   # in a ghostty checkout
cp -R zig-out/lib/ghostty-vt.xcframework Spikes/VTRenderer/Vendor/
swift build -c release
.build/release/VTSpike workloads/log.bin 65536 10        # new renderer
.build/release/EmbeddedSpike workloads/log.bin 65536 10  # control
.build/release/VTSpike workloads/screen.bin 65536 0      # stays open, for a screenshot
```

`workloads/` is generated (see the commit that added this file) and not committed.
Computer Use only captures app bundles, so wrap a binary in a minimal `.app`
before asking for a screenshot.

## Results, 2026-10-25, MacBook Pro (Apple silicon), 1600x1000pt window

Throughput while the renderer draws at display rate, 5 interleaved runs each,
640 MB per run, median (range):

| workload | VTSpike | EmbeddedSpike |
|---|---|---|
| `log.bin` scrolling coloured log | 276 MB/s (214–305) | 201 MB/s (149–248) |
| `tui.bin` full-screen redraws in mode 2026 | 769 MB/s (417–928) | 581 MB/s (259–665) |

VTSpike frame cost during the log flood, after the writer yields to a waiting
renderer: CPU build+encode p50 0.5 ms, p99 1.2–1.9 ms; terminal lock p99
0.3–0.4 ms; GPU p99 ~5 ms. Without the yield, NSLock let the writer starve the
renderer for up to 34 ms.

The screenshot test (`screen.bin`) matches the embedded surface in layout:
rows, CJK widths, box drawing and the cursor position.

## What the spike does not do

These make the comparison favour the spike, and each is work for phase 3:
underline and strikethrough, colour emoji (the atlas is R8), ligatures and
grapheme shaping beyond the first codepoint, the mode 2026 render hold, themes,
font configuration, selection, IME, cursor styles, Kitty images, scrollback and
viewport scrolling, resize.
