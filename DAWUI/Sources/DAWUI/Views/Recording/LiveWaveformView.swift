import SwiftUI
import AppKit
import Combine
import DAWCore

// MARK: - Live Waveform View (using CALayer for performance)

public struct LiveWaveformView: NSViewRepresentable {
    let waveformSamples: [Float]
    let color: Color
    let isRecording: Bool
    
    public init(waveformSamples: [Float], color: Color = .green, isRecording: Bool = false) {
        self.waveformSamples = waveformSamples
        self.color = color
        self.isRecording = isRecording
    }
    
    public func makeNSView(context: Context) -> LiveWaveformNSView {
        let view = LiveWaveformNSView()
        view.waveformColor = NSColor(color)
        return view
    }
    
    public func updateNSView(_ nsView: LiveWaveformNSView, context: Context) {
        nsView.waveformColor = NSColor(color)
        nsView.isRecording = isRecording
        nsView.updateWaveform(waveformSamples)
    }
}

// MARK: - Live Waveform NSView (CALayer-based)

public class LiveWaveformNSView: NSView {
    
    private var waveformLayer: CAShapeLayer!
    private var backgroundLayer: CALayer!
    private var recordingIndicatorLayer: CALayer!
    
    var waveformColor: NSColor = .green {
        didSet {
            waveformLayer?.strokeColor = waveformColor.cgColor
            waveformLayer?.fillColor = waveformColor.withAlphaComponent(0.3).cgColor
        }
    }
    
    var isRecording: Bool = false {
        didSet {
            updateRecordingIndicator()
        }
    }
    
    private var samples: [Float] = []
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }
    
    private func setupLayers() {
        wantsLayer = true
        
        // Background layer
        backgroundLayer = CALayer()
        backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        backgroundLayer.cornerRadius = 4
        layer?.addSublayer(backgroundLayer)
        
        // Waveform layer
        waveformLayer = CAShapeLayer()
        waveformLayer.strokeColor = waveformColor.cgColor
        waveformLayer.fillColor = waveformColor.withAlphaComponent(0.3).cgColor
        waveformLayer.lineWidth = 1
        layer?.addSublayer(waveformLayer)
        
        // Recording indicator
        recordingIndicatorLayer = CALayer()
        recordingIndicatorLayer.backgroundColor = NSColor.red.cgColor
        recordingIndicatorLayer.cornerRadius = 4
        recordingIndicatorLayer.isHidden = true
        layer?.addSublayer(recordingIndicatorLayer)
    }
    
    public override func layout() {
        super.layout()
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        backgroundLayer?.frame = bounds
        waveformLayer?.frame = bounds
        recordingIndicatorLayer?.frame = CGRect(x: bounds.width - 12, y: 4, width: 8, height: 8)
        
        CATransaction.commit()
        
        redrawWaveform()
    }
    
    func updateWaveform(_ newSamples: [Float]) {
        samples = newSamples
        redrawWaveform()
    }
    
    private func redrawWaveform() {
        guard !samples.isEmpty, bounds.width > 0, bounds.height > 0 else {
            waveformLayer?.path = nil
            return
        }
        
        let path = CGMutablePath()
        let midY = bounds.height / 2
        let width = bounds.width
        let height = bounds.height
        
        // Calculate how many samples to show
        let visibleSamples = min(samples.count, Int(width))
        let startIndex = max(0, samples.count - visibleSamples)
        
        // Create waveform path
        path.move(to: CGPoint(x: 0, y: midY))
        
        for i in 0..<visibleSamples {
            let sampleIndex = startIndex + i
            let sample = samples[sampleIndex]
            let x = CGFloat(i) * width / CGFloat(visibleSamples)
            let amplitude = CGFloat(sample) * (height / 2) * 0.9
            
            // Draw top half
            path.addLine(to: CGPoint(x: x, y: midY - amplitude))
        }
        
        // Close the path by going back along the bottom
        for i in stride(from: visibleSamples - 1, through: 0, by: -1) {
            let sampleIndex = startIndex + i
            let sample = samples[sampleIndex]
            let x = CGFloat(i) * width / CGFloat(visibleSamples)
            let amplitude = CGFloat(sample) * (height / 2) * 0.9
            
            path.addLine(to: CGPoint(x: x, y: midY + amplitude))
        }
        
        path.closeSubpath()
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        waveformLayer.path = path
        CATransaction.commit()
    }
    
    private func updateRecordingIndicator() {
        recordingIndicatorLayer?.isHidden = !isRecording
        
        if isRecording {
            // Pulse animation
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.3
            pulse.duration = 0.5
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            recordingIndicatorLayer?.add(pulse, forKey: "pulse")
        } else {
            recordingIndicatorLayer?.removeAllAnimations()
        }
    }
}

// MARK: - Recording Waveform Track Overlay

public struct RecordingWaveformOverlay: View {
    @ObservedObject var viewModel: ProjectViewModel
    let track: Track
    let pixelsPerBeat: Double
    let height: CGFloat
    
    public init(viewModel: ProjectViewModel, track: Track, pixelsPerBeat: Double, height: CGFloat) {
        self.viewModel = viewModel
        self.track = track
        self.pixelsPerBeat = pixelsPerBeat
        self.height = height
    }
    
    public var body: some View {
        if viewModel.isRecording && viewModel.recordingTrackID == track.id {
            GeometryReader { geometry in
                let recordingStartBeat = viewModel.recordingStartBeat
                let currentBeat = viewModel.transportState.playheadBeats
                let recordingWidth = max(10, (currentBeat - recordingStartBeat) * pixelsPerBeat)
                let xOffset = recordingStartBeat * pixelsPerBeat
                
                ZStack(alignment: .leading) {
                    // Recording region background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.red.opacity(0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.red, lineWidth: 2)
                        )
                        .frame(width: recordingWidth, height: height - 6)
                    
                    // Live waveform
                    LiveWaveformView(
                        waveformSamples: viewModel.audioRecorder.waveformSamples,
                        color: Color(hex: track.color.hex) ?? .green,
                        isRecording: true
                    )
                    .frame(width: recordingWidth - 4, height: height - 10)
                    .padding(.horizontal, 2)
                    
                    // Recording label
                    VStack {
                        HStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                            Text("REC")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.red)
                            Spacer()
                        }
                        .padding(4)
                        Spacer()
                    }
                }
                .offset(x: xOffset, y: 3)
            }
        }
    }
}
