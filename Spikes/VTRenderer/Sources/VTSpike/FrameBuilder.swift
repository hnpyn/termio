import GhosttyVt

/// Layouts shared with the Metal shaders; every field is 2 or 4 bytes wide and
/// 4-byte aligned in Metal, so Swift's layout matches.
struct BackgroundInstance {
    var cellX: UInt16, cellY: UInt16
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8
}

struct GlyphInstance {
    var cellX: UInt16, cellY: UInt16
    var atlasX: UInt16, atlasY: UInt16
    var atlasWidth: UInt16, atlasHeight: UInt16
    var offsetX: Int16, offsetY: Int16
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8
}

/// Turns the render state into instance lists, rebuilding only dirty rows.
final class FrameBuilder {
    private(set) var background = GhosttyColorRgb(r: 0, g: 0, b: 0)
    private var rowBackgrounds: [[BackgroundInstance]] = []
    private var rowGlyphs: [[GlyphInstance]] = []
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var cells: GhosttyRenderStateRowCells?
    private var codepoints = [UInt32](repeating: 0, count: 16)
    private(set) var rowsRebuilt = 0
    var cursor: BackgroundInstance?

    init() {
        _ = ghostty_render_state_row_iterator_new(nil, &rowIterator)
        _ = ghostty_render_state_row_cells_new(nil, &cells)
    }

    /// Returns false when the frame is clean and nothing needs drawing.
    func build(from state: GhosttyRenderState, atlas: GlyphAtlas) -> Bool {
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        if dirty == GHOSTTY_RENDER_STATE_DIRTY_FALSE { return false }

        var rows: UInt16 = 0
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows)
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        background = colors.background
        let full = dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL || rowBackgrounds.count != Int(rows)
        if rowBackgrounds.count != Int(rows) {
            rowBackgrounds = Array(repeating: [], count: Int(rows))
            rowGlyphs = Array(repeating: [], count: Int(rows))
        }

        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator)
        rowsRebuilt = 0
        var y: UInt16 = 0
        while next(full: full, y: &y) {
            rebuildRow(Int(y), colors: colors, atlas: atlas)
            rowsRebuilt += 1
        }
        cursor = cursorInstance(state, colors: colors)
        _ = ghostty_render_state_clean(state)
        return true
    }

    private var plainRow: UInt16 = 0
    private func next(full: Bool, y: inout UInt16) -> Bool {
        // No overscan is requested, so the iterator visits viewport rows 0..<rows in order.
        if full {
            guard ghostty_render_state_row_iterator_next(rowIterator) else { plainRow = 0; return false }
            y = plainRow
            plainRow &+= 1
            return true
        }
        return ghostty_render_state_row_iterator_next_dirty(rowIterator, &y)
    }

    private func rebuildRow(_ y: Int, colors: GhosttyRenderStateColors, atlas: GlyphAtlas) {
        guard y < rowBackgrounds.count else { return }
        var backgrounds: [BackgroundInstance] = []
        var glyphs: [GlyphInstance] = []
        _ = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)
        var x: UInt16 = 0
        while ghostty_render_state_row_cells_next(cells) {
            defer { x &+= 1 }
            var raw: GhosttyCell = 0
            _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
            var wide = GHOSTTY_CELL_WIDE_NARROW
            _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
            if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }

            var bold = false, italic = false, inverse = false
            var hasStyling = false
            _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &hasStyling)
            if hasStyling {
                var style = GhosttyStyle()
                style.size = MemoryLayout<GhosttyStyle>.size
                _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
                bold = style.bold; italic = style.italic; inverse = style.inverse
            }
            var fg = colors.foreground
            var bg = colors.background
            var hasBackground = false
            if hasStyling {
                var resolved = GhosttyColorRgb()
                if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &resolved) == GHOSTTY_SUCCESS { fg = resolved }
                if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &resolved) == GHOSTTY_SUCCESS { bg = resolved; hasBackground = true }
            }
            if inverse { swap(&fg, &bg); hasBackground = true }
            if hasBackground {
                backgrounds.append(BackgroundInstance(cellX: x, cellY: UInt16(y), r: bg.r, g: bg.g, b: bg.b, a: 255))
                if wide == GHOSTTY_CELL_WIDE_WIDE {
                    backgrounds.append(BackgroundInstance(cellX: x + 1, cellY: UInt16(y), r: bg.r, g: bg.g, b: bg.b, a: 255))
                }
            }

            var length: UInt32 = 0
            _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length)
            guard length > 0 else { continue }
            codepoints.withUnsafeMutableBufferPointer { buffer in
                _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, buffer.baseAddress)
            }
            let codepoint = codepoints[0]
            if codepoint == 0x20 { continue }
            guard let slot = atlas.slot(codepoint: codepoint, bold: bold, italic: italic) else { continue }
            glyphs.append(GlyphInstance(
                cellX: x, cellY: UInt16(y),
                atlasX: slot.origin.x, atlasY: slot.origin.y,
                atlasWidth: slot.size.x, atlasHeight: slot.size.y,
                offsetX: slot.offset.x, offsetY: slot.offset.y,
                r: fg.r, g: fg.g, b: fg.b, a: 255))
        }
        rowBackgrounds[y] = backgrounds
        rowGlyphs[y] = glyphs
    }

    private func cursorInstance(_ state: GhosttyRenderState, colors: GhosttyRenderStateColors) -> BackgroundInstance? {
        var visible = false, hasValue = false
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &hasValue)
        guard visible, hasValue else { return nil }
        var x: UInt16 = 0, y: UInt16 = 0
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y)
        let c = colors.foreground
        return BackgroundInstance(cellX: x, cellY: y, r: c.r, g: c.g, b: c.b, a: 160)
    }

    func flatten(into backgrounds: inout [BackgroundInstance], glyphs: inout [GlyphInstance]) {
        backgrounds.removeAll(keepingCapacity: true)
        glyphs.removeAll(keepingCapacity: true)
        for row in rowBackgrounds { backgrounds.append(contentsOf: row) }
        for row in rowGlyphs { glyphs.append(contentsOf: row) }
        if let cursor { backgrounds.append(cursor) }
    }
}
