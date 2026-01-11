import Foundation

// MARK: - Automation Lane

/// Represents an automation lane for a single parameter
public struct AutomationLane: Identifiable, Codable, Sendable {
    public var id: UUID
    public var parameter: AutomationParameter
    public var points: [AutomationPoint]
    public var isEnabled: Bool
    public var isVisible: Bool
    public var height: Double  // UI height
    
    public init(
        id: UUID = UUID(),
        parameter: AutomationParameter,
        points: [AutomationPoint] = [],
        isEnabled: Bool = true,
        isVisible: Bool = false
    ) {
        self.id = id
        self.parameter = parameter
        self.points = points
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.height = 60.0
    }
    
    // MARK: - Point Management
    
    /// Points sorted by time
    public var sortedPoints: [AutomationPoint] {
        points.sorted { $0.beatPosition < $1.beatPosition }
    }
    
    /// Get value at a specific beat position
    public func value(atBeat beat: Double) -> Float {
        let sorted = sortedPoints
        
        guard !sorted.isEmpty else {
            return parameter.defaultValue
        }
        
        // Before first point
        if beat <= sorted.first!.beatPosition {
            return sorted.first!.value
        }
        
        // After last point
        if beat >= sorted.last!.beatPosition {
            return sorted.last!.value
        }
        
        // Find surrounding points
        var previousPoint: AutomationPoint?
        var nextPoint: AutomationPoint?
        
        for (index, point) in sorted.enumerated() {
            if point.beatPosition > beat {
                nextPoint = point
                if index > 0 {
                    previousPoint = sorted[index - 1]
                }
                break
            }
        }
        
        guard let prev = previousPoint, let next = nextPoint else {
            return parameter.defaultValue
        }
        
        // Interpolate based on curve type
        let t = Float((beat - prev.beatPosition) / (next.beatPosition - prev.beatPosition))
        return prev.curveType.interpolate(from: prev.value, to: next.value, at: t)
    }
    
    /// Add or update a point
    public mutating func setPoint(at beatPosition: Double, value: Float, curveType: AutomationCurve = .linear) {
        // Check if point exists at this position
        if let index = points.firstIndex(where: { abs($0.beatPosition - beatPosition) < 0.001 }) {
            points[index].value = value
            points[index].curveType = curveType
        } else {
            let newPoint = AutomationPoint(
                beatPosition: beatPosition,
                value: value,
                curveType: curveType
            )
            points.append(newPoint)
        }
    }
    
    /// Remove point by ID
    public mutating func removePoint(id: UUID) {
        points.removeAll { $0.id == id }
    }
    
    /// Remove points in beat range
    public mutating func removePoints(inRange range: ClosedRange<Double>) {
        points.removeAll { range.contains($0.beatPosition) }
    }
}

// MARK: - Automation Point

public struct AutomationPoint: Identifiable, Codable, Sendable {
    public var id: UUID
    public var beatPosition: Double
    public var value: Float  // Normalized 0.0 to 1.0
    public var curveType: AutomationCurve
    
    public init(
        id: UUID = UUID(),
        beatPosition: Double,
        value: Float,
        curveType: AutomationCurve = .linear
    ) {
        self.id = id
        self.beatPosition = beatPosition
        self.value = max(0, min(1, value))
        self.curveType = curveType
    }
}

// MARK: - Automation Curve

public enum AutomationCurve: String, Codable, Sendable, CaseIterable {
    case step       // No interpolation, instant jump
    case linear     // Linear interpolation
    case exponential
    case logarithmic
    case sCurve
    
    /// Interpolate between two values
    public func interpolate(from start: Float, to end: Float, at t: Float) -> Float {
        let clamped = max(0, min(1, t))
        let factor: Float
        
        switch self {
        case .step:
            factor = clamped < 1.0 ? 0.0 : 1.0
        case .linear:
            factor = clamped
        case .exponential:
            factor = clamped * clamped
        case .logarithmic:
            factor = sqrt(clamped)
        case .sCurve:
            // Smooth step
            factor = clamped * clamped * (3 - 2 * clamped)
        }
        
        return start + (end - start) * factor
    }
}

// MARK: - Automation Parameter

public enum AutomationParameter: Codable, Sendable, Hashable {
    case volume
    case pan
    case mute
    case send(index: Int)
    case plugin(slotIndex: Int, parameterID: String)
    
    public var name: String {
        switch self {
        case .volume: return "Volume"
        case .pan: return "Pan"
        case .mute: return "Mute"
        case .send(let index): return "Send \(index + 1)"
        case .plugin(_, let paramID): return paramID
        }
    }
    
    public var defaultValue: Float {
        switch self {
        case .volume: return 0.7937  // -2 dB
        case .pan: return 0.5        // Center (normalized)
        case .mute: return 0.0       // Not muted
        case .send: return 0.0       // No send
        case .plugin: return 0.5     // Middle (plugin-dependent)
        }
    }
    
    public var minValue: Float { 0.0 }
    public var maxValue: Float { 1.0 }
    
    /// Format value for display
    public func format(value: Float) -> String {
        switch self {
        case .volume:
            let db = 20 * log10(value)
            if db == -.infinity { return "-∞ dB" }
            return String(format: "%.1f dB", db)
            
        case .pan:
            let pan = (value - 0.5) * 2  // Convert to -1...1
            if abs(pan) < 0.01 { return "C" }
            if pan < 0 { return String(format: "%.0fL", -pan * 100) }
            return String(format: "%.0fR", pan * 100)
            
        case .mute:
            return value > 0.5 ? "On" : "Off"
            
        case .send:
            let db = 20 * log10(value)
            if db == -.infinity { return "-∞ dB" }
            return String(format: "%.1f dB", db)
            
        case .plugin:
            return String(format: "%.2f", value)
        }
    }
}

// MARK: - Automation Recording Mode

public enum AutomationMode: String, Sendable, CaseIterable {
    case off         // Automation disabled
    case read        // Read automation during playback
    case touch       // Record while touching, then return to existing
    case latch       // Record while touching, hold last value
    case write       // Overwrite all automation during playback
    
    public var description: String {
        switch self {
        case .off: return "Off"
        case .read: return "Read"
        case .touch: return "Touch"
        case .latch: return "Latch"
        case .write: return "Write"
        }
    }
}
