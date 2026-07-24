import MetalKit
import RommpleTVKit

final class MetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private var textureSize: (w: Int, h: Int) = (0, 0)
    private var aspect: Double = 4.0 / 3.0
    private let frameLock = NSLock()
    private var pendingFrame: (data: [UInt8], w: Int, h: Int, pitch: Int,
                               format: CorePixelFormat)?

    init(view: MTKView) {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true            // we drive draws from the display link
        view.enableSetNeedsDisplay = false
        let lib = device.makeDefaultLibrary()!
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "fullscreen_vertex")
        desc.fragmentFunction = lib.makeFunction(name: "frame_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)
        super.init()
        view.delegate = self
    }

    func setAspect(_ a: Double) { aspect = a }

    /// Called on the emulation thread: copy the frame out of core memory.
    func submitFrame(_ data: UnsafeRawPointer, width: Int, height: Int,
                     pitchBytes: Int, format: CorePixelFormat) {
        let bytes = [UInt8](UnsafeRawBufferPointer(start: data,
                                                   count: pitchBytes * height))
        frameLock.lock()
        pendingFrame = (bytes, width, height, pitchBytes, format)
        frameLock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        frameLock.lock(); let frame = pendingFrame; pendingFrame = nil; frameLock.unlock()
        if let frame { upload(frame) }
        guard let texture,
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        // Letterbox: center the largest aspect-correct rect.
        let dw = Double(view.drawableSize.width), dh = Double(view.drawableSize.height)
        let scale = min(dw / aspect, dh)
        let vw = scale * aspect, vh = scale
        enc.setViewport(MTLViewport(originX: (dw - vw) / 2, originY: (dh - vh) / 2,
                                    width: vw, height: vh, znear: 0, zfar: 1))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func upload(_ frame: (data: [UInt8], w: Int, h: Int, pitch: Int,
                                  format: CorePixelFormat)) {
        let pixelFormat: MTLPixelFormat = frame.format == .rgb565 ? .b5g6r5Unorm : .bgra8Unorm
        if texture == nil || textureSize != (frame.w, frame.h)
            || texture?.pixelFormat != pixelFormat {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: frame.w, height: frame.h,
                mipmapped: false)
            d.usage = .shaderRead
            texture = device.makeTexture(descriptor: d)
            textureSize = (frame.w, frame.h)
        }
        frame.data.withUnsafeBytes { buf in
            texture?.replace(region: MTLRegionMake2D(0, 0, frame.w, frame.h),
                             mipmapLevel: 0, withBytes: buf.baseAddress!,
                             bytesPerRow: frame.pitch)
        }
    }
}
