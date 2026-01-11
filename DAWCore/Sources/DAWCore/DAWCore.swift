// DAWCore - Core Audio Engine and Models
// No UI dependencies in this module

// MARK: - Module Exports

// Models
@_exported import struct Foundation.UUID
@_exported import struct Foundation.Date
@_exported import struct Foundation.URL
@_exported import struct Foundation.Data

// Re-export all public types for convenience
// (Swift Package Manager handles visibility automatically)

/// DAWCore version information
public enum DAWCoreInfo {
    public static let version = "1.0.0"
    public static let buildNumber = 1
    public static let minimumMacOSVersion = "14.0"
}
