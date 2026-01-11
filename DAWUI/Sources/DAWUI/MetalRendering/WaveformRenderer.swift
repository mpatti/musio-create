import SwiftUI
import MetalKit
import DAWCore

// MARK: - Waveform Metal View

/// High-performance waveform rendering using Metal
public struct WaveformMetalView: NSViewRepresentable {
    let waveformData: WaveformData?
    let color: Color
    let backgroundColor: Color
    let zoomLevel: Double
    let scrollOffset: Double
    
    public init(
        waveformData: WaveformData?,
        color: Color = .blue,
        backgroundColor: Color = .clear,
        zoomLevel: Double = 1.0,
        scrollOffset: Double = 0
    ) {
        self.waveformData = waveformData
        self.color = color
        self.backgroundColor = backgroundColor
        self.zoomLevel = zoomLevel
        self.scrollOffset = scrollOffset
    }
    
    public func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.layer?.isOpaque = false
        return mtkView
    }
    
    public func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.waveformData = waveformData
        context.coordinator.color = NSColor(color)
        context.coordinator.zoomLevel = zoomLevel
        context.coordinator.scrollOffset = scrollOffset
        nsView.setNeedsDisplay(nsView.bounds)
    }
    
    public func makeCoordinator() -> WaveformMetalCoordinator {
        WaveformMetalCoordinator(waveformData: waveformData, color: NSColor(color))
    }
}

// MARK: - Metal Coordinator

public class WaveformMetalCoordinator: NSObject, MTKViewDelegate {
    var waveformData: WaveformData?
    var color: NSColor
    var zoomLevel: Double = 1.0
    var scrollOffset: Double = 0
    
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    
    init(waveformData: WaveformData?, color: NSColor) {
        self.waveformData = waveformData
        self.color = color
        super.init()
        setupMetal()
    }
    
    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        
        // Create shader library
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        struct VertexIn {
            float2 position [[attribute(0)]];
        };
        
        struct VertexOut {
            float4 position [[position]];
            float4 color;
        };
        
        struct Uniforms {
            float4 color;
        };
        
        vertex VertexOut vertex_main(
            VertexIn in [[stage_in]],
            constant Uniforms& uniforms [[buffer(1)]]
        ) {
            VertexOut out;
            out.position = float4(in.position, 0.0, 1.0);
            out.color = uniforms.color;
            return out;
        }
        
        fragment float4 fragment_main(VertexOut in [[stage_in]]) {
            return in.color;
        }
        """
        
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let vertexFunction = library.makeFunction(name: "vertex_main")
            let fragmentFunction = library.makeFunction(name: "fragment_main")
            
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            
            // Vertex descriptor
            let vertexDescriptor = MTLVertexDescriptor()
            vertexDescriptor.attributes[0].format = .float2
            vertexDescriptor.attributes[0].offset = 0
            vertexDescriptor.attributes[0].bufferIndex = 0
            vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
            pipelineDescriptor.vertexDescriptor = vertexDescriptor
            
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create Metal pipeline: \(error)")
        }
    }
    
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pipelineState = pipelineState,
              let commandQueue = commandQueue,
              let device = device else { return }
        
        // Generate vertices from waveform data
        let vertices = generateWaveformVertices(for: view.bounds.size)
        guard !vertices.isEmpty else { return }
        
        // Create vertex buffer
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        )
        
        // Create uniforms
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        
        var uniforms = SIMD4<Float>(Float(red), Float(green), Float(blue), Float(alpha))
        
        let renderPassDescriptor = view.currentRenderPassDescriptor!
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
        
        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    private func generateWaveformVertices(for size: CGSize) -> [SIMD2<Float>] {
        guard let data = waveformData, !data.minValues.isEmpty else {
            return []
        }
        
        var vertices: [SIMD2<Float>] = []
        
        let pointCount = data.pointCount
        let width = Float(size.width)
        let height = Float(size.height)
        let midY = height / 2
        
        // Calculate visible range based on zoom and scroll
        let visiblePoints = Int(Double(pointCount) / zoomLevel)
        let startPoint = Int(scrollOffset * Double(pointCount))
        let endPoint = min(startPoint + visiblePoints, pointCount)
        
        guard startPoint < endPoint else { return [] }
        
        let pointsToRender = endPoint - startPoint
        let pixelsPerPoint = width / Float(pointsToRender)
        
        // Generate triangle strip for waveform
        for i in 0..<pointsToRender {
            let dataIndex = startPoint + i
            guard dataIndex < data.minValues.count else { break }
            
            let x = Float(i) * pixelsPerPoint
            let normalizedX = (x / width) * 2.0 - 1.0  // Convert to NDC (-1 to 1)
            
            let minVal = data.minValues[dataIndex]
            let maxVal = data.maxValues[dataIndex]
            
            // Convert to NDC
            let topY = 1.0 - (Float(maxVal) + 1.0)  // Invert Y for Metal
            let bottomY = 1.0 - (Float(minVal) + 1.0)
            
            vertices.append(SIMD2<Float>(normalizedX, topY))
            vertices.append(SIMD2<Float>(normalizedX, bottomY))
        }
        
        return vertices
    }
}

// MARK: - CPU Fallback Waveform View

/// SwiftUI waveform view using Canvas (CPU-based fallback)
public struct WaveformCanvasView: View {
    let waveformData: WaveformData?
    let color: Color
    let zoomLevel: Double
    
    public init(
        waveformData: WaveformData?,
        color: Color = .blue,
        zoomLevel: Double = 1.0
    ) {
        self.waveformData = waveformData
        self.color = color
        self.zoomLevel = zoomLevel
    }
    
    public var body: some View {
        Canvas { context, size in
            guard let data = waveformData, !data.minValues.isEmpty else { return }
            
            let width = size.width
            let height = size.height
            let midY = height / 2
            
            let pointCount = data.pointCount
            let pixelsPerPoint = width / CGFloat(pointCount) * zoomLevel
            
            var path = Path()
            
            // Draw top half (max values)
            path.move(to: CGPoint(x: 0, y: midY))
            
            for i in 0..<pointCount {
                let x = CGFloat(i) * pixelsPerPoint
                let amplitude = CGFloat(data.maxValues[i]) * midY
                path.addLine(to: CGPoint(x: x, y: midY - amplitude))
            }
            
            // Draw bottom half (min values) in reverse
            for i in (0..<pointCount).reversed() {
                let x = CGFloat(i) * pixelsPerPoint
                let amplitude = CGFloat(data.minValues[i]) * midY
                path.addLine(to: CGPoint(x: x, y: midY - amplitude))
            }
            
            path.closeSubpath()
            
            context.fill(path, with: .color(color.opacity(0.6)))
            
            // Draw center line
            var centerLine = Path()
            centerLine.move(to: CGPoint(x: 0, y: midY))
            centerLine.addLine(to: CGPoint(x: width, y: midY))
            context.stroke(centerLine, with: .color(color.opacity(0.3)), lineWidth: 0.5)
        }
    }
}

// MARK: - Waveform View (Auto-selects Metal or CPU)

/// Smart waveform view that uses Metal when available, falls back to CPU
public struct WaveformView: View {
    let waveformData: WaveformData?
    let color: Color
    let zoomLevel: Double
    let useMetalWhenAvailable: Bool
    
    @State private var metalAvailable: Bool = false
    
    public init(
        waveformData: WaveformData?,
        color: Color = .blue,
        zoomLevel: Double = 1.0,
        useMetalWhenAvailable: Bool = true
    ) {
        self.waveformData = waveformData
        self.color = color
        self.zoomLevel = zoomLevel
        self.useMetalWhenAvailable = useMetalWhenAvailable
    }
    
    public var body: some View {
        Group {
            if useMetalWhenAvailable && metalAvailable {
                WaveformMetalView(
                    waveformData: waveformData,
                    color: color,
                    zoomLevel: zoomLevel
                )
            } else {
                WaveformCanvasView(
                    waveformData: waveformData,
                    color: color,
                    zoomLevel: zoomLevel
                )
            }
        }
        .onAppear {
            metalAvailable = MTLCreateSystemDefaultDevice() != nil
        }
    }
}

// MARK: - Waveform Cache

/// Caches waveform data for quick access
public actor WaveformCache {
    private var cache: [UUID: WaveformData] = [:]
    private let maxCacheSize: Int
    
    public init(maxCacheSize: Int = 100) {
        self.maxCacheSize = maxCacheSize
    }
    
    public func get(_ fileID: UUID) -> WaveformData? {
        cache[fileID]
    }
    
    public func set(_ fileID: UUID, data: WaveformData) {
        // Evict if at capacity
        if cache.count >= maxCacheSize {
            cache.removeValue(forKey: cache.keys.first!)
        }
        cache[fileID] = data
    }
    
    public func remove(_ fileID: UUID) {
        cache.removeValue(forKey: fileID)
    }
    
    public func clear() {
        cache.removeAll()
    }
}
