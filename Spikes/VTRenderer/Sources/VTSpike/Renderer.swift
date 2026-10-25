import AppKit
import Metal
import QuartzCore

/// Compiled at runtime from source: a SwiftPM resource bundle is the thing
/// termio must never ship (AGENTS.md, "Dependencies").
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms { float2 viewport; float2 cell; float2 atlas; float2 origin; };
struct Background { ushort2 cell; uchar4 color; };
struct Glyph { ushort2 cell; ushort2 atlasOrigin; ushort2 atlasSize; short2 offset; uchar4 color; };
struct VertexOut { float4 position [[position]]; float2 uv; float4 color; };

constant float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

static float4 clip(float2 pixel, float2 viewport) {
    return float4(pixel / viewport * float2(2, -2) + float2(-1, 1), 0, 1);
}

vertex VertexOut background_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   const device Background* items [[buffer(0)]],
                                   constant Uniforms& u [[buffer(1)]]) {
    Background b = items[iid];
    VertexOut out;
    out.position = clip(u.origin + (float2(b.cell) + corners[vid]) * u.cell, u.viewport);
    out.uv = float2(0);
    out.color = float4(b.color) / 255.0;
    return out;
}

fragment float4 background_fragment(VertexOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}

vertex VertexOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device Glyph* items [[buffer(0)]],
                              constant Uniforms& u [[buffer(1)]]) {
    Glyph g = items[iid];
    float2 size = float2(g.atlasSize);
    float2 pixel = u.origin + float2(g.cell) * u.cell + float2(g.offset) + corners[vid] * size;
    VertexOut out;
    out.position = clip(pixel, u.viewport);
    out.uv = (float2(g.atlasOrigin) + corners[vid] * size) / u.atlas;
    out.color = float4(g.color) / 255.0;
    return out;
}

fragment float4 glyph_fragment(VertexOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::nearest);
    float coverage = atlas.sample(s, in.uv).r;
    return float4(in.color.rgb * coverage, coverage);
}
"""

private struct Uniforms {
    var viewport: SIMD2<Float>
    var cell: SIMD2<Float>
    var atlas: SIMD2<Float>
    var origin: SIMD2<Float>
}

final class Stats {
    private(set) var buildMs: [Double] = []
    private(set) var lockMs: [Double] = []
    private(set) var gpuMs: [Double] = []
    private(set) var frames = 0
    private(set) var cleanFrames = 0
    private let lock = NSLock()

    func record(build: Double, lockHeld: Double) { lock.lock(); buildMs.append(build); lockMs.append(lockHeld); frames += 1; lock.unlock() }
    func recordClean() { lock.lock(); cleanFrames += 1; lock.unlock() }
    func recordGPU(_ ms: Double) { lock.lock(); gpuMs.append(ms); lock.unlock() }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        func f(_ v: [Double]) -> String {
            String(format: "p50 %.2f p99 %.2f max %.2f ms", Self.percentile(v, 0.5), Self.percentile(v, 0.99), v.max() ?? .nan)
        }
        return "frames \(frames) (+\(cleanFrames) clean)\n  cpu build+encode: \(f(buildMs))\n  terminal lock held: \(f(lockMs))\n  gpu: \(f(gpuMs))"
    }
}

final class TerminalView: NSView {
    let vt: VT
    let stats = Stats()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let metalLayer = CAMetalLayer()
    private let atlas: GlyphAtlas
    private let builder = FrameBuilder()
    private let backgroundPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private var backgrounds: [BackgroundInstance] = []
    private var glyphs: [GlyphInstance] = []
    private var link: CADisplayLink?
    private var needsDraw = false
    private let padding: Float = 8
    private let inFlight = DispatchSemaphore(value: 3)
    let cellMetrics: CellMetrics

    init(frame: NSRect, scale: CGFloat) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("no Metal") }
        self.device = device
        self.queue = queue
        atlas = GlyphAtlas(device: device, fontName: "Menlo", pointSize: 13, scale: scale)
        cellMetrics = atlas.metrics
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: shaderSource, options: nil) } catch { fatalError("shaders: \(error)") }
        func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            let a = d.colorAttachments[0]!
            a.pixelFormat = .bgra8Unorm
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do { return try device.makeRenderPipelineState(descriptor: d) } catch { fatalError("pipeline: \(error)") }
        }
        backgroundPipeline = pipeline("background_vertex", "background_fragment")
        glyphPipeline = pipeline("glyph_vertex", "glyph_fragment")

        let pixelWidth = Float(frame.width * scale), pixelHeight = Float(frame.height * scale)
        let cols = UInt16(max(1, (pixelWidth - 2 * padding * Float(scale)) / Float(cellMetrics.width)))
        let rows = UInt16(max(1, (pixelHeight - 2 * padding * Float(scale)) / Float(cellMetrics.height)))
        vt = VT(cols: cols, rows: rows)
        vt.resize(cols: cols, rows: rows, cellWidth: UInt32(cellMetrics.width), cellHeight: UInt32(cellMetrics.height))
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = scale
        metalLayer.maximumDrawableCount = 3
        layer = metalLayer
        print("grid \(cols)x\(rows), cell \(cellMetrics.width)x\(cellMetrics.height)px")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, link == nil else { return }
        metalLayer.drawableSize = CGSize(width: bounds.width * metalLayer.contentsScale,
                                         height: bounds.height * metalLayer.contentsScale)
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        let start = DispatchTime.now().uptimeNanoseconds
        let lockHeld = vt.updateRenderState()
        // build() cleans the render state, so a frame skipped below must still
        // be drawn on the next tick even though that tick will see it clean.
        if builder.build(from: vt.renderState, atlas: atlas) { needsDraw = true }
        guard needsDraw else { stats.recordClean(); return }
        guard inFlight.wait(timeout: .now()) == .success else { stats.recordClean(); return }
        guard let drawable = metalLayer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { inFlight.signal(); return }
        needsDraw = false
        builder.flatten(into: &backgrounds, glyphs: &glyphs)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let bg = builder.background
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.r) / 255, green: Double(bg.g) / 255, blue: Double(bg.b) / 255, alpha: 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return }
        let scale = Float(metalLayer.contentsScale)
        var uniforms = Uniforms(
            viewport: SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height)),
            cell: SIMD2(Float(cellMetrics.width), Float(cellMetrics.height)),
            atlas: SIMD2(Float(atlas.size), Float(atlas.size)),
            origin: SIMD2(padding * scale, padding * scale))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        if !backgrounds.isEmpty, let data = device.makeBuffer(bytes: backgrounds, length: backgrounds.count * MemoryLayout<BackgroundInstance>.stride) {
            encoder.setRenderPipelineState(backgroundPipeline)
            encoder.setVertexBuffer(data, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: backgrounds.count)
        }
        if !glyphs.isEmpty, let data = device.makeBuffer(bytes: glyphs, length: glyphs.count * MemoryLayout<GlyphInstance>.stride) {
            encoder.setRenderPipelineState(glyphPipeline)
            encoder.setVertexBuffer(data, offset: 0, index: 0)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: glyphs.count)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        let stats = self.stats, semaphore = inFlight
        buffer.addCompletedHandler { done in
            stats.recordGPU((done.gpuEndTime - done.gpuStartTime) * 1000)
            semaphore.signal()
        }
        buffer.commit()
        stats.record(build: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6, lockHeld: lockHeld)
    }
}
