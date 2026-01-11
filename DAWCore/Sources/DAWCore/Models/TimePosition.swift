import Foundation

// MARK: - Time Position

/// Represents a position in musical time.
/// Supports both sample-accurate timing and musical beat/bar notation.
public struct TimePosition: Hashable, Codable, Sendable, Comparable {
    /// Position in samples (sample-accurate timing)
    public var samples: Int64
    
    /// Sample rate used for conversion
    public var sampleRate: Double
    
    public init(samples: Int64 = 0, sampleRate: Double = 44100) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
    
    public init(seconds: Double, sampleRate: Double = 44100) {
        self.samples = Int64(seconds * sampleRate)
        self.sampleRate = sampleRate
    }
    
    public init(beats: Double, tempo: Double, sampleRate: Double = 44100) {
        let seconds = (beats / tempo) * 60.0
        self.samples = Int64(seconds * sampleRate)
        self.sampleRate = sampleRate
    }
    
    // MARK: - Conversions
    
    public var seconds: Double {
        Double(samples) / sampleRate
    }
    
    public func beats(atTempo tempo: Double) -> Double {
        (seconds / 60.0) * tempo
    }
    
    public func bars(atTempo tempo: Double, timeSignature: TimeSignature) -> Double {
        beats(atTempo: tempo) / Double(timeSignature.beatsPerBar)
    }
    
    /// Returns a formatted string like "1.2.3" (bar.beat.tick)
    public func formatted(atTempo tempo: Double, timeSignature: TimeSignature, ticksPerBeat: Int = 480) -> String {
        let totalBeats = beats(atTempo: tempo)
        let bar = Int(totalBeats / Double(timeSignature.beatsPerBar)) + 1
        let beatInBar = Int(totalBeats.truncatingRemainder(dividingBy: Double(timeSignature.beatsPerBar))) + 1
        let tickFraction = totalBeats.truncatingRemainder(dividingBy: 1.0)
        let tick = Int(tickFraction * Double(ticksPerBeat))
        return String(format: "%d.%d.%03d", bar, beatInBar, tick)
    }
    
    // MARK: - Comparable
    
    public static func < (lhs: TimePosition, rhs: TimePosition) -> Bool {
        lhs.samples < rhs.samples
    }
    
    // MARK: - Arithmetic
    
    public static func + (lhs: TimePosition, rhs: TimePosition) -> TimePosition {
        TimePosition(samples: lhs.samples + rhs.samples, sampleRate: lhs.sampleRate)
    }
    
    public static func - (lhs: TimePosition, rhs: TimePosition) -> TimePosition {
        TimePosition(samples: lhs.samples - rhs.samples, sampleRate: lhs.sampleRate)
    }
}

// MARK: - Time Range

/// Represents a range of time with start and duration
public struct TimeRange: Hashable, Codable, Sendable {
    public var start: TimePosition
    public var duration: TimePosition
    
    public init(start: TimePosition, duration: TimePosition) {
        self.start = start
        self.duration = duration
    }
    
    public init(start: TimePosition, end: TimePosition) {
        self.start = start
        self.duration = end - start
    }
    
    public var end: TimePosition {
        start + duration
    }
    
    public func contains(_ position: TimePosition) -> Bool {
        position >= start && position < end
    }
    
    public func overlaps(_ other: TimeRange) -> Bool {
        start < other.end && end > other.start
    }
}

// MARK: - Time Signature

public struct TimeSignature: Hashable, Codable, Sendable {
    public var numerator: Int      // Beats per bar (e.g., 4)
    public var denominator: Int    // Beat unit (e.g., 4 for quarter note)
    
    public init(numerator: Int = 4, denominator: Int = 4) {
        self.numerator = numerator
        self.denominator = denominator
    }
    
    public var beatsPerBar: Int { numerator }
    
    /// Standard 4/4 time
    public static let common = TimeSignature(numerator: 4, denominator: 4)
    
    /// 3/4 waltz time
    public static let waltz = TimeSignature(numerator: 3, denominator: 4)
    
    /// 6/8 compound time
    public static let sixEight = TimeSignature(numerator: 6, denominator: 8)
}

// MARK: - Tempo

/// Represents tempo information with optional time-varying tempo changes
public struct Tempo: Hashable, Codable, Sendable {
    public var bpm: Double
    
    public init(bpm: Double = 120.0) {
        self.bpm = max(20.0, min(999.0, bpm))
    }
    
    /// Seconds per beat
    public var secondsPerBeat: Double {
        60.0 / bpm
    }
    
    /// Samples per beat at given sample rate
    public func samplesPerBeat(sampleRate: Double) -> Double {
        secondsPerBeat * sampleRate
    }
}

// MARK: - Time Utilities

public enum TimeUtilities {
    /// Quantize a beat position to the nearest grid division
    public static func quantize(
        beats: Double,
        gridDivision: Double,
        mode: QuantizeMode = .nearest
    ) -> Double {
        switch mode {
        case .nearest:
            return (beats / gridDivision).rounded() * gridDivision
        case .floor:
            return (beats / gridDivision).rounded(.down) * gridDivision
        case .ceil:
            return (beats / gridDivision).rounded(.up) * gridDivision
        }
    }
    
    public enum QuantizeMode {
        case nearest
        case floor
        case ceil
    }
    
    /// Common grid divisions (in beats)
    public enum GridDivision: Double, CaseIterable {
        case whole = 4.0
        case half = 2.0
        case quarter = 1.0
        case eighth = 0.5
        case sixteenth = 0.25
        case thirtySecond = 0.125
        case tripletQuarter = 0.6666666666666666
        case tripletEighth = 0.3333333333333333
        case tripletSixteenth = 0.16666666666666666
    }
}
