import AppKit
import CoreText
import Metal

struct CellMetrics {
    let width: Int
    let height: Int
    let baseline: Int
}

struct GlyphSlot {
    let origin: SIMD2<UInt16>
    let size: SIMD2<UInt16>
    /// Offset of the bitmap's top-left from the cell's top-left, in pixels.
    let offset: SIMD2<Int16>
}

/// Rasterizes glyphs with CoreText into one R8 texture, packed in shelves.
/// One slot per (codepoint, bold, italic); a codepoint the primary font lacks
/// is drawn from CoreText's fallback for it, which is how CJK gets a face.
final class GlyphAtlas {
    let texture: MTLTexture
    let metrics: CellMetrics
    let size: Int
    private let fonts: [CTFont]  // regular, bold, italic, bold italic
    private var slots: [UInt64: GlyphSlot?] = [:]
    private var shelfX = 0
    private var shelfY = 0
    private var shelfHeight = 0
    private(set) var misses = 0

    init(device: MTLDevice, fontName: String, pointSize: CGFloat, scale: CGFloat, size: Int = 4096) {
        let base = CTFontCreateWithName(fontName as CFString, pointSize * scale, nil)
        func variant(_ traits: CTFontSymbolicTraits) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
        }
        fonts = [base, variant(.traitBold), variant(.traitItalic), variant([.traitBold, .traitItalic])]
        var glyph = CGGlyph(0)
        var m: UniChar = 0x4D
        CTFontGetGlyphsForCharacters(base, &m, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(base, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(base), descent = CTFontGetDescent(base), leading = CTFontGetLeading(base)
        metrics = CellMetrics(
            width: Int(advance.width.rounded(.up)),
            height: Int((ascent + descent + leading).rounded(.up)),
            baseline: Int(ascent.rounded(.up)))
        self.size = size
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { fatalError("atlas texture") }
        self.texture = texture
    }

    func slot(codepoint: UInt32, bold: Bool, italic: Bool) -> GlyphSlot? {
        let key = UInt64(codepoint) | (bold ? 1 << 32 : 0) | (italic ? 1 << 33 : 0)
        if let cached = slots[key] { return cached }
        misses += 1
        let rendered = rasterize(codepoint: codepoint, font: fonts[(bold ? 1 : 0) + (italic ? 2 : 0)])
        slots[key] = rendered
        return rendered
    }

    private func rasterize(codepoint: UInt32, font primary: CTFont) -> GlyphSlot? {
        guard let scalar = Unicode.Scalar(codepoint) else { return nil }
        let utf16 = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        var font = primary
        if !CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) {
            font = CTFontCreateForString(primary, String(Character(scalar)) as CFString,
                                         CFRange(location: 0, length: utf16.count))
            guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) else { return nil }
        }
        var glyph = glyphs[0]
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        if bounds.width <= 0 || bounds.height <= 0 { return nil }
        let pad = 1
        let width = Int(bounds.width.rounded(.up)) + 2 * pad
        let height = Int(bounds.height.rounded(.up)) + 2 * pad
        guard let origin = allocate(width: width, height: height) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.setFillColor(gray: 1, alpha: 1)
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(false)
            var position = CGPoint(x: CGFloat(pad) - bounds.minX, y: CGFloat(pad) - bounds.minY)
            CTFontDrawGlyphs(font, &glyph, &position, 1, context)
        }
        texture.replace(region: MTLRegionMake2D(origin.x, origin.y, width, height),
                        mipmapLevel: 0, withBytes: pixels, bytesPerRow: width)
        // CoreGraphics' origin is bottom-left: the bitmap's top sits at
        // baseline - (maxY + pad) below the cell's top.
        let top = metrics.baseline - Int(bounds.maxY.rounded(.up)) - pad
        let left = Int(bounds.minX.rounded(.down)) - pad
        return GlyphSlot(origin: SIMD2(UInt16(origin.x), UInt16(origin.y)),
                         size: SIMD2(UInt16(width), UInt16(height)),
                         offset: SIMD2(Int16(left), Int16(top)))
    }

    private func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
        if shelfX + width > size {
            shelfY += shelfHeight
            shelfX = 0
            shelfHeight = 0
        }
        guard shelfY + height <= size else { return nil }
        let origin = (shelfX, shelfY)
        shelfX += width
        shelfHeight = max(shelfHeight, height)
        return origin
    }
}
